{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Generated toy scripts: authored actions over the queue toys, their
-- QuickCheck generators, the Python corpus's script format
-- (@scripts/generated_stories.py@), and the author/settle/replay driver
-- the differential test, the properties, and the benchmarks share.
module Generated
  ( Action (..)
  , Script (..)
  , author
  , settle
  , authorScript
  , replayFresh
  , scriptOf
  , withoutReport
  , profileFor
  , checkersFor
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..))
import Petrus.Testing.Dst
import Petrus.Testing.Dst.Timeline qualified as Timeline
import Petrus.Testing.Dst.World qualified as World
import Spec.Support
import Test.QuickCheck (Arbitrary (..), choose, elements, frequency, shrinkList, vectorOf)
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
