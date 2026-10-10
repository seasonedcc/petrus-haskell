-- | Kernel-wide QuickCheck properties over random nets and markings. They go
-- beyond the upstream suite (whose kernel tests are example-based) and pin
-- the invariants every History-derived view depends on:
--
-- * the marking an Instance holds is always the replay of its History;
-- * resume over that History rebuilds the same marking, watermark,
--   occurrence counter, and candidates;
-- * the History survives the schema-5 codec through JSON text unchanged;
-- * a run conserves tokens on a net whose transitions move one token in to
--   one token out, and the scheduler always fires the first candidate.
module Petrus.Impetus.KernelPropertiesSpec (spec) where

import Control.Monad (forM)
import Data.Text qualified as T
import Petrus.Impetus.History.Codec (decodeRecord, encodeHistory)
import Petrus.Impetus.History.Replay (replayMarking)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet hiding (candidates, inputs, nextMaturation, outputs)
import Petrus.Impetus.TestSupport (np)
import Petrus.Json
import Test.Hspec hiding (after, before)
import Test.QuickCheck
import Test.QuickCheck.Monadic (assert, monadicIO, monitor)
import Test.QuickCheck.Monadic qualified as M

-- | A random net: places @p0..pN@, transitions with one to three consume or
-- read arcs (weights 1–2), an optional inhibitor, and zero to two outputs;
-- plus a marking of small integer-carrying tokens.
data Scenario = Scenario {net :: Net, initial :: Marking, description :: String}

instance Show Scenario where
  show = (.description)

genScenario :: Gen Scenario
genScenario = do
  placeCount <- chooseInt (2, 5)
  let places = [np (T.pack ("p" <> show i)) | i <- [0 .. placeCount - 1]]
  transitionCount <- chooseInt (1, 4)
  transitions <- forM [0 .. transitionCount - 1] $ \t -> do
    let path = np (T.pack ("t" <> show t))
    inputs <- sublistOf places `suchThat` (not . null)
    inArcs <- forM (take 3 inputs) $ \p -> do
      mode' <- frequency [(6, pure Consume), (2, pure Read), (1, pure Inhibit)]
      w <- if mode' == Inhibit then pure 1 else chooseInt (1, 2)
      pure (Arc p path mode' w Nothing Nothing)
    outputs <- take 2 <$> sublistOf places
    pure (transition path, inArcs <> [arc path o | o <- outputs])
  tokens <- forM places $ \p -> do
    n <- chooseInt (0, 4)
    values <- vectorOf n (chooseInteger (0, 9))
    pure (p, [Token Nothing (Object [("n", Int v)]) | v <- values])
  case mkNet (netSpec (map place places) (map fst transitions) (concatMap snd transitions)) of
    Left _ -> genScenario
    Right built ->
      pure
        Scenario
          { net = built
          , initial = markingFromList tokens
          , description = show (netArcs built) <> " / " <> show (markingToList (markingFromList tokens))
          }

-- | Run a fresh Instance to quiescence (bounded: the nets can cycle).
runBounded :: Scenario -> IO (Instance, [FiringOutcome])
runBounded scenario = do
  inst <- newInstance scenario.net defaultInstanceConfig {initialMarking = scenario.initial, suppliedIdentity = Just "property"} >>= either (fail . show) pure
  let go :: Int -> [FiringOutcome] -> IO [FiringOutcome]
      go 0 acc = pure (reverse acc)
      go n acc = do
        -- A cycling net can pile tokens up, and the candidate bindings of a
        -- transition grow combinatorially with them (three weight-2 inputs
        -- on 30 tokens each are 10^8 bindings): stop while every place is
        -- still small, so each property stays within modest memory.
        held <- markingToList <$> marking inst
        if any ((> maxTokensPerPlace) . length . snd) held then pure (reverse acc) else continue n acc
      continue n acc = do
        firstCandidate <- take 1 <$> candidates inst
        step inst Nothing >>= \case
          Left e -> fail (T.unpack (renderInstanceError e))
          Right Nothing -> pure (reverse acc)
          Right (Just outcome) -> do
            -- The conservative scheduler fires the first candidate.
            case firstCandidate of
              [b] | b.transition == outcome.transition -> pure ()
              _ -> fail "the scheduler did not fire the first candidate"
            go (n - 1) (outcome : acc)
  outcomes <- go 40 []
  pure (inst, outcomes)

-- | The most tokens a place may hold before 'runBounded' stops stepping.
maxTokensPerPlace :: Int
maxTokensPerPlace = 8

spec :: Spec
spec = describe "kernel properties" $ do
  it "the Instance marking is always the replay of its History" $
    property $ forAll genScenario $ \scenario -> monadicIO $ do
      (inst, outcomes) <- M.run (runBounded scenario)
      history <- M.run (Store.records (instanceHistory inst))
      current <- M.run (marking inst)
      monitor (classify (null outcomes) "nothing enabled")
      assert (fmap markingToList (replayMarking history) == Right (markingToList current))

  it "resume rebuilds the marking, watermark, occurrence counter, and candidates" $
    property $ forAll genScenario $ \scenario -> monadicIO $ do
      (inst, outcomes) <- M.run (runBounded scenario)
      resumed <- M.run (resume scenario.net (instanceHistory inst) defaultInstanceConfig >>= either (fail . show) pure)
      before <- M.run ((,,) <$> marking inst <*> watermark inst <*> candidates inst)
      after <- M.run ((,,) <$> marking resumed <*> watermark resumed <*> candidates resumed)
      assert (before == after)
      next <- M.run (step resumed Nothing)
      case next of
        Right (Just outcome) -> assert (outcome.occurrence == length outcomes + 1)
        Right Nothing -> pure ()
        Left e -> fail (show e)

  it "the History round-trips the schema-5 codec through JSON text" $
    property $ forAll genScenario $ \scenario -> monadicIO $ do
      (inst, _) <- M.run (runBounded scenario)
      history <- M.run (Store.records (instanceHistory inst))
      let text = either (error . show) id (dumps compact (Array (encodeHistory history)))
      decoded <- case parseJson strictLoads text of
        Right (Array values) -> pure (traverse decodeRecord values)
        _ -> fail "not an array"
      assert (decoded == Right history)

  it "a run on one-in, one-out transitions conserves the token count" $
    property $ forAll genConserving $ \scenario -> monadicIO $ do
      (inst, _) <- M.run (runBounded scenario)
      current <- M.run (marking inst)
      assert (count current == count scenario.initial)
  where
    count m = sum [length ts | (_, ts) <- markingToList m]

-- | Nets whose every transition consumes exactly one token and produces
-- exactly one, so the total token count is invariant.
genConserving :: Gen Scenario
genConserving = do
  placeCount <- chooseInt (2, 5)
  let places = [np (T.pack ("p" <> show i)) | i <- [0 .. placeCount - 1]]
  transitionCount <- chooseInt (1, 4)
  edges <- forM [0 .. transitionCount - 1] $ \t -> do
    from <- elements places
    to <- elements places
    pure (np (T.pack ("t" <> show t)), from, to)
  tokens <- forM places $ \p -> do
    n <- chooseInt (0, 3)
    pure (p, replicate n black)
  let built = either (error . T.unpack) id (mkNet (netSpec (map place places) [transition t | (t, _, _) <- edges] (concat [[arc f t, arc t o] | (t, f, o) <- edges])))
  pure Scenario {net = built, initial = markingFromList tokens, description = show edges <> " / " <> show (markingToList (markingFromList tokens))}
