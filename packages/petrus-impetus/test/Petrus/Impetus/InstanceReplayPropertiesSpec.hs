-- | Parity: @tests/petrus/impetus/instance/test_instance_replay_properties.py@
-- — bounded generative checks that live Instance state stays replayable and
-- resumable.
--
-- Translation notes. The reference's Hypothesis property becomes a QuickCheck
-- property, mapped setting by setting (the ledger row is in PARITY.md):
--
-- * @max_examples=300@ is 'maxSuccess' 300;
-- * @derandomize=True@ is a fixed 'replay' seed ('derandomizedSeed'): every
--   run, locally and on CI, draws the same 300 scenarios and action
--   sequences, as Hypothesis' derandomized run does (hspec's @--seed@ does
--   not move it);
-- * @deadline=None@ needs nothing (QuickCheck has no per-example deadline);
-- * the @_scenario_specs@ composite strategy is 'genScenario', drawing the
--   same shape: two ordinary transitions with a consume arc (weight 1–2), an
--   output arc, and an optional read/inhibit gate (weight 1–2) on another
--   place; a source output place; an initial marking of up to three tokens
--   per place from the same four tokens; up to 20 actions;
-- * the interleaved @data.draw@ calls (Hypothesis' @st.data()@) become
--   'QCM.pick' inside 'monadicIO', so each action, delivered token, begun
--   candidate and completed occurrence is drawn from what is legal /at that
--   point/, the reference's stateful structure;
-- * @note(...)@ is 'counterexample': a failure prints the drawn scenario
--   (via 'forAll') and every drawn action, as the reference's notes do.
--
-- The reference has no @\@example@ cases for this property.
module Petrus.Impetus.InstanceReplayPropertiesSpec (spec) where

import Control.Monad (forM_)
import Data.Text qualified as T
import Petrus.Impetus.Binding
import Petrus.Impetus.DoorSupport
import Petrus.Impetus.History
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet hiding (candidates, candidatesWithDiagnostics, nextMaturation)
import Petrus.Impetus.TestSupport (expectRight, np, tokD)
import Petrus.Impetus.TestSupport qualified as TS
import Petrus.Json (Json (..))
import Test.Hspec
import Test.Hspec.QuickCheck (modifyArgs)
import Test.QuickCheck (Args (..), Gen, chooseInt, counterexample, elements, forAll, property, vectorOf)
import Test.QuickCheck.Random (mkQCGen)
import Test.QuickCheck.Monadic qualified as QCM

placesP :: [NetPath]
placesP = [np ("p" <> T.pack (show i)) | i <- [0 .. 2 :: Int]]

transitionsP :: [NetPath]
transitionsP = [np ("t" <> T.pack (show i)) | i <- [0 .. 1 :: Int]]

sourceP :: NetPath
sourceP = np "source"

tokensP :: [Token]
tokensP = [black, tokD "A" (Int 0), tokD "A" (Int 1), tokD "B" (Int 0)]

-- | One ordinary transition's drawn shape (the reference's six-tuple).
data Ordinary = Ordinary
  { consumedAt :: Int
  , consumeWeight :: Int
  , producedAt :: Int
  , gateMode :: Maybe ArcMode
  , gateAt :: Int
  , gateWeight :: Int
  }
  deriving stock (Show)

data Scenario = Scenario
  { ordinary :: [Ordinary]
  , sourceOutput :: Int
  , initial :: [[Token]]
  , actionCount :: Int
  }
  deriving stock (Show)

genOrdinary :: Gen Ordinary
genOrdinary = do
  c <- chooseInt (0, 2)
  cw <- chooseInt (1, 2)
  p <- chooseInt (0, 2)
  m <- elements [Nothing, Just Read, Just Inhibit]
  g <- elements [i | i <- [0 .. 2], i /= c]
  gw <- chooseInt (1, 2)
  pure (Ordinary c cw p m g gw)

genScenario :: Gen Scenario
genScenario =
  Scenario
    <$> vectorOf (length transitionsP) genOrdinary
    <*> chooseInt (0, 2)
    <*> vectorOf (length placesP) (chooseInt (0, 3) >>= \n -> vectorOf n (elements tokensP))
    <*> chooseInt (0, 20)

nth :: [a] -> Int -> a
nth xs i = case drop i xs of
  x : _ -> x
  [] -> error "index out of range"

scenarioNet :: Scenario -> Net
scenarioNet sc =
  TS.netOf
    (map place placesP)
    (map transition transitionsP <> [transition sourceP])
    (arc sourceP (placesP `nth` sc.sourceOutput) : concat (zipWith arcsOf transitionsP sc.ordinary))
  where
    arcsOf t o =
      [(arc (placesP `nth` o.consumedAt) t) {weight = o.consumeWeight}, arc t (placesP `nth` o.producedAt)]
        <> [(arc (placesP `nth` o.gateAt) t) {mode = m, weight = o.gateWeight} | Just m <- [o.gateMode]]

-- | The reference's @_assert_replay_and_resume@: the live marking is the
-- replayed one, and a resume over a cloned store agrees on marking,
-- watermark, candidates, and in-flight ids.
assertReplayAndResume :: Instance -> Net -> IO ()
assertReplayAndResume inst net = do
  rs <- historyRecords inst
  live <- marking inst
  replayMarking rs `shouldBe` Right live
  cloned <- storeOf rs
  resumed <- resume net cloned defaultInstanceConfig >>= expectRight
  marking resumed >>= (`shouldBe` live)
  (,) <$> watermark resumed <*> watermark inst >>= uncurry shouldBe
  (,) <$> candidates resumed <*> candidates inst >>= uncurry shouldBe
  let ids = fmap (map (.occurrence)) . inFlight
  (,) <$> ids resumed <*> ids inst >>= uncurry shouldBe

-- | The fixed seed standing for Hypothesis' @derandomize=True@.
derandomizedSeed :: Int
derandomizedSeed = 300

data Action = Deliver | Step | Begin | Complete
  deriving stock (Eq, Show)

spec :: Spec
spec = describe "Instance replay properties" $
  modifyArgs (\args -> args {maxSuccess = 300, replay = Just (mkQCGen derandomizedSeed, 0)}) $
    -- test_legal_instance_actions_remain_replayable_and_resumable
    it "keeps legal instance actions replayable and resumable" $
      property $ forAll genScenario $ \sc -> QCM.monadicIO $ do
        let net = scenarioNet sc
        inst <-
          QCM.run $
            mkInstance
              net
              defaultInstanceConfig
                { initialMarking = markingFromList (zip placesP sc.initial)
                , suppliedIdentity = Just "property-instance"
                }
        QCM.run (assertReplayAndResume inst net)
        forM_ [0 .. sc.actionCount - 1] $ \actionNumber -> do
          cs <- QCM.run (candidates inst)
          flying <- QCM.run (inFlight inst)
          let legal = [Deliver] <> (if null cs then [] else [Step, Begin]) <> [Complete | not (null flying)]
          action <- QCM.pick (elements legal)
          QCM.monitor (counterexample ("action[" <> show actionNumber <> "]=" <> show action))
          case action of
            Deliver -> do
              t <- QCM.pick (elements tokensP)
              _ <- QCM.run (deliver inst sourceP [t] ("delivery-" <> T.pack (show actionNumber)))
              pure ()
            Step -> QCM.run (step inst Nothing >>= expectRight) >> pure ()
            Begin -> do
              candidate <- QCM.pick (elements cs)
              QCM.run (begin inst candidate Nothing >>= expectRight) >> pure ()
            Complete -> do
              o <- QCM.pick (elements flying)
              let index = length (takeWhile (/= o.binding.transition) transitionsP)
                  output = placesP `nth` (sc.ordinary `nth` index).producedAt
              _ <- QCM.run (complete inst o (Just (HandlerResult [(output, bindingTokens o.binding)] [] [])) Nothing >>= expectRight)
              pure ()
          QCM.run (assertReplayAndResume inst net)
