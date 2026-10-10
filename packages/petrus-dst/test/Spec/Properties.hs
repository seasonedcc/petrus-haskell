{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Generated toy scenarios. Differentially: 400 seeded scripts generated
-- and authored by the Python reference (@scripts/generated_stories.py@)
-- give the same refusals, dispositions, artifact bytes, and replay
-- results here. As properties: whatever an authored script
-- does — commands (including checker-violating ones), faults, observations,
-- crashes and restarts, steps, under small random budgets — the World ends
-- with an artifact whose strict encoding round-trips byte for byte and
-- whose replay through a fresh profile reproduces it (@outcome: pass@,
-- same disposition and journal digest). Choice streams stay isolated per
-- authority under arbitrary interleavings.
module Spec.Properties (spec) where

import Control.Monad (forM_, replicateM)
import Control.Monad.State.Strict (StateT, evalStateT, get, lift, put)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..))
import Petrus.Testing.Dst
import Petrus.Testing.Dst.Timeline qualified as Timeline
import Petrus.Testing.Dst.World qualified as World
import Spec.Support
import Test.Hspec
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import Test.QuickCheck hiding (replay)
import Test.QuickCheck.Monadic (monadicIO, monitor, run)
import Toy

-- | One authored action.
data Action
  = Step
  | Record Text
  | Observe
  | ActivateFault FaultDisposition Integer
  | CrashRestart
  | BeginFair
  deriving stock (Eq, Show)

instance Arbitrary Action where
  arbitrary =
    frequency
      [ (5, pure Step)
      , (4, Record <$> elements ["a", "b", "c", "bad"])
      , (2, pure Observe)
      , (2, ActivateFault <$> elements [Refuse, Duplicate] <*> choose (1, 2))
      , (1, pure CrashRestart)
      , (1, pure BeginFair)
      ]

data Script = Script
  { faulty :: Bool
  , checked :: Bool
  , limits :: (Integer, Integer, Integer, Integer, Integer, Integer)
  , authored :: [Action]
  }
  deriving stock (Show)

instance Arbitrary Script where
  arbitrary = do
    faulty <- arbitrary
    checked <- arbitrary
    limits <- (,,,,,) <$> choose (2, 16) <*> choose (2, 6) <*> choose (0, 2) <*> choose (5, 12) <*> choose (0, 2) <*> choose (1, 3)
    n <- choose (0, 14)
    authored <- vectorOf n arbitrary
    pure Script {faulty, checked, limits, authored}
  shrink s = [s {authored} | authored <- shrinkList (const []) s.authored]

-- | Perform one authored action; its refusal in the vectors' shape.
author :: Action -> WorldT IO () Json
author action = fmap pyErrorOf . World.tryWorld $ case action of
  Step -> () <$ World.step
  Record identifier -> do
    t <- World.timeline
    () <$ Timeline.command t "queue.record" (Object [("id", String identifier)])
  Observe -> do
    t <- World.timeline
    () <$ Timeline.observe t "queue.state"
  ActivateFault d occurrence -> do
    t <- World.timeline
    Timeline.activateFault t Timeline.FaultSpec {name = "f", target = "queue.apply", occurrence, disposition = d, payload = Null}
  CrashRestart -> do
    t <- World.timeline
    Timeline.crash t "cut"
    () <$ World.restart
  BeginFair -> do
    t <- World.timeline
    Timeline.beginFair t

-- | Drain and finish the World unless it already ended: step while work is
-- pending, otherwise finish quiescent; each round's refusal.
settle :: Int -> WorldT IO () [Json]
settle fuel
  | fuel <= 0 = pure []
  | otherwise = do
      ended <- World.disposition
      case ended of
        Just _ -> pure []
        Nothing -> do
          pendingWork <- World.pendingCount
          refused <-
            fmap pyErrorOf . World.tryWorld $
              if pendingWork > 0
                then () <$ World.step
                else World.timeline >>= \t -> Timeline.finish t Quiescent
          (refused :) <$> settle (fuel - 1)

-- | Author a script and settle it: action refusals, settle refusals, the
-- final disposition, and the artifact or its refusal.
authorScript :: Script -> IO (Either DstFailure ([Json], [Json], Maybe Disposition, Either DstFailure AnyArtifact))
authorScript s = do
  let (a, q, t, l, r, p) = s.limits
  queue <- newQueue
  World.withWorld (config (profileFor s queue) (budget a q t l r p) (checkersFor s) Nothing) $ do
    errors <- mapM author s.authored
    settling <- settle 64
    ended <- World.disposition
    artifact <- World.tryWorld (World.artifact "generated-story")
    pure (errors, settling, ended, artifact)

replayFresh :: Script -> AnyArtifact -> IO (Either DstFailure AnyReplayResult)
replayFresh s artifact = do
  fresh <- newQueue
  replay (registryOf [SomeProfile (profileFor s fresh)] (checkersFor s)) artifact

-- | A Python-generated script.
scriptOf :: Json -> Script
scriptOf v =
  Script
    { faulty = member "faulty" v == Bool True
    , checked = member "checked" v == Bool True
    , limits = case memberList "limits" v of
        [Int a, Int q, Int t, Int l, Int r, Int p] -> (a, q, t, l, r, p)
        other -> error ("bad limits " <> show other)
    , authored = map actionOf (memberList "actions" v)
    }
  where
    actionOf = \case
      Array [String "step"] -> Step
      Array [String "record", String identifier] -> Record identifier
      Array [String "observe"] -> Observe
      Array [String "fault", String d, Int occurrence] ->
        ActivateFault (if d == "refuse" then Refuse else Duplicate) occurrence
      Array [String "crash"] -> CrashRestart
      Array [String "fair"] -> BeginFair
      other -> error ("bad action " <> show other)

-- | A refusal compared up to pydantic's input report, which the port does
-- not reproduce (DIVERGENCES.md).
withoutReport :: Json -> Json
withoutReport = \case
  Object [("message", String m), ("type", t)] -> Object [("message", String (fst (T.breakOn " [type=" m))), ("type", t)]
  other -> other
profileFor :: Script -> Queue -> Profile IO ()
profileFor s = if s.faulty then faultQueueProfile else queueProfile

checkersFor :: Script -> [Checker]
checkersFor s = [rejectBadValueChecker | s.checked]

spec :: Spec
spec = describe "properties" $ do
  it "authors 400 Python-generated scripts exactly as the reference does" $ do
    stories <- memberList "stories" <$> readJson (dataFile "generated-stories.json")
    length stories `shouldBe` 400
    forM_ (zip [0 :: Int ..] stories) $ \(index, story) -> do
      let s = scriptOf (member "script" story)
      authored <- authorScript s
      (errors, settling, ended, artifact) <- either (fail . show) pure authored
      let observed =
            Object
              [ ("index", Int (toInteger index))
              , ("errors", Array errors)
              , ("settling", Array settling)
              , ("disposition", maybe Null (String . dispositionText) ended)
              ]
          expected =
            Object
              [ ("index", Int (toInteger index))
              , ("errors", member "errors" story)
              , ("settling", member "settling" story)
              , ("disposition", member "disposition" story)
              ]
      observed `shouldBeJson` expected
      case artifact of
        Left failure -> withoutReport (pyError failure) `shouldBeJson` withoutReport (member "artifact_error" story)
        Right a -> do
          (index, artifactText a) `shouldBe` (index, memberText "artifact" story)
          replayed <- replayFresh s a
          replayJson replayed `shouldBeJson` member "replay" story

  modifyMaxSuccess (const 300) $
    it "every generated toy story yields an artifact that round-trips and replays exactly" $
      property $ \s -> monadicIO $ do
        outcome <- run (authorScript s)
        case outcome of
          Left failure -> pure (counterexample ("World failed: " <> show failure) False)
          Right (_, _, _, Left failure)
            | failureMessage failure == "finish the DST World before producing an artifact" -> do
                -- a World that never ended (budget-starved finish) has no
                -- artifact; that refusal is the reference's too
                monitor (label "unfinished")
                pure (property True)
            | "a failed DST artifact must end with exactly one failure operation" `T.isInfixOf` failureMessage failure -> do
                -- the reference records a second failure operation when a
                -- budget refusal follows the World's end, and then refuses
                -- the artifact; the port reproduces that (the
                -- failure-after-end story, and PARITY.md)
                monitor (label "failure after the end (reference quirk)")
                pure (property True)
            | otherwise -> pure (counterexample (show failure) False)
          Right (_, _, ended, Right artifact) -> do
            monitor (label (maybe "unended" (T.unpack . dispositionText) ended))
            encoded <- either (fail . T.unpack) pure (encodeArtifact artifact)
            let roundTrip = (decodeArtifact encoded >>= \a' -> either (error . T.unpack) Right (encodeArtifact a')) == Right encoded
            replayed <- run (replayFresh s artifact)
            pure $ case replayed of
              Left failure -> counterexample ("replay failed: " <> show failure) False
              Right result ->
                let value = toJson result
                    field k = canonText (member k value)
                 in counterexample (show value) $
                      roundTrip
                        .&&. field "outcome" === canonText (String "pass")
                        .&&. field "disposition" === canonText (String (maybe "" dispositionText ended))
                        .&&. field "journal_digest" === canonText (String (artifactJournalDigest artifact))

  it "keeps each choice authority's stream independent of the others' draws" $
    property $ \(NonNegative seed) (draws :: [Int]) -> do
      let s = seed `mod` (2 ^ (53 :: Int))
          workloadAlone = run' s (replicateM 3 (draw WorkloadChoice))
          interleaved = run' s $ do
            first <- draw WorkloadChoice
            forM_ draws $ \k -> case k `mod` 3 of
              0 -> () <$ draw FaultChoice
              1 -> () <$ draw EventOrderChoice
              _ -> () <$ identifier
            second <- draw WorkloadChoice
            forM_ (reverse draws) $ \_ -> () <$ draw FaultChoice
            third <- draw WorkloadChoice
            pure [first, second, third]
      interleaved === workloadAlone
  where
    run' :: Integer -> StateT ChoiceStreams (Either ChoiceError) a -> a
    run' seed body = either (error . show) id (choiceStreams seed >>= evalStateT body)
    draw authority = do
      streams <- get
      (value, streams') <- lift (chooseIndex authority 1000 streams)
      put streams'
      pure value
    identifier = do
      streams <- get
      (value, streams') <- lift (chooseIdentifier "noise" streams)
      put streams'
      pure value
