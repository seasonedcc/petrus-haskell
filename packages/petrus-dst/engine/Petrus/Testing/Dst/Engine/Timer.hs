{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The timer crash and reconstruction world: a port of the reference's
-- @tests/dst/timer_world.py@. One delayed transition is armed, the process
-- crashes before maturation, and the reloaded Engine matures it exactly
-- once at the authored deadline.
module Petrus.Testing.Dst.Engine.Timer
  ( instanceId
  , scenarioId
  , maturationInstant
  , profileIdentity
  , checkerIdentity
  , worldBudget
  , applicationNet
  , TimerGeneration (..)
  , TimerProfile (..)
  , timerEngineProfile
  , timerAuthorityChecker
  , executeTimerStory
  , buildTimerArtifact
  ) where

import Control.Monad.Except (throwError)
import Data.Foldable (toList)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Engine (DriveOutcome (..), Engine)
import Petrus.Engine qualified as Engine
import Petrus.HistoryStore.Jsonl (openJsonlHistoryStore)
import Petrus.Impetus.History.Records (Record (..), TimerMatured (..), recordName)
import Petrus.Impetus.HistoryStore (HistoryStore (..))
import Petrus.Impetus.Instance (FiringOutcome (..))
import Petrus.Impetus.Petrinet
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch.InMemory (inMemoryDispatch, newInMemoryDispatch)
import Petrus.Testing.Dst hiding (Delay)
import Petrus.Testing.Dst.Engine.Common
import Petrus.Json.Python (pythonStrRepr)
import Petrus.Testing.Dst.Timeline qualified as Timeline
import Petrus.Testing.Dst.World qualified as World

waiting, done, release :: NetPath
waiting = either (error . T.unpack) id (netPath "waiting")
done = either (error . T.unpack) id (netPath "done")
release = either (error . T.unpack) id (netPath "release")

instanceId, scenarioId :: Text
instanceId = "dst-world-timer-recovery"
scenarioId = "timer-crash-recovery-world-v3"

maturationInstant :: Integer
maturationInstant = 5

profileIdentity :: ProfileIdentity
profileIdentity =
  Identity
    { name = "petrus.engine.timer-recovery"
    , version = 1
    , digest =
        digestOf
          ( Object
              [ ("commands", Object [("engine.drive", Array [])])
              , ("instance", String instanceId)
              , ( "net"
                , Object
                    [ ("delay", Int maturationInstant)
                    , ("places", strs ["done", "waiting"])
                    , ("transition", String "release")
                    ]
                )
              , ("observations", strs ["engine.timer-authority", "timer-armed", "timer-recovered", "timer-terminal"])
              ]
          )
    }

checkerIdentity :: CheckerIdentity
checkerIdentity =
  Identity
    { name = "petrus.engine.timer-authority"
    , version = 1
    , digest =
        digestOf
          ( Object
              [ ( "properties"
                , strs
                    [ "timer maturation never precedes its authored deadline"
                    , "one authored timer matures and fires at most once"
                    , "a delayed firing requires its canonical maturation fact"
                    ]
                )
              ]
          )
    }

worldBudget :: SomeBudget
worldBudget =
  SomeBudget
    Budget
      { actions = 32
      , queuedCommands = 8
      , timerAdvances = 1
      , logicalInstant = maturationInstant
      , reloads = 1
      , predicatePolls = 16
      , artifactBytes = 262144
      }

applicationNet :: Net
applicationNet =
  either (error . T.unpack) id $
    mkNet
      NetSpec
        { places = [place waiting, place done]
        , transitions = [(transition release) {timers = [Delay (IntNumber maturationInstant)]}]
        , arcs = [arc waiting release, arc release done]
        , completion = Nothing
        , name = Just "dst-world-timer-recovery"
        }

-- | @TimerGeneration@.
data TimerGeneration = TimerGeneration
  { engine :: Engine
  , history :: HistoryStore
  , drives :: IORef Int
  }

-- | A @TimerEngineProfile@.
data TimerProfile = TimerProfile
  { profile :: Profile IO TimerGeneration
  , drops :: IORef Int
  , closes :: IORef Int
  }

debugFields :: [Text]
debugFields =
  [ "current_instant"
  , "drives"
  , "drops"
  , "frontier"
  , "marking"
  , "next_maturation"
  , "record_types"
  , "status"
  , "timer_maturations"
  ]

observationFields :: [(Text, [Text])]
observationFields =
  [ ("engine.timer-authority", ["authored_maturation_instant", "current_instant", "record_types", "timer_maturations"])
  , ("timer-armed", debugFields)
  , ("timer-recovered", debugFields)
  , ("timer-terminal", debugFields)
  ]

numberJson :: Number -> Json
numberJson = \case
  IntNumber i -> Int i
  FloatNumber d -> Float d

-- | The World instant of a scheduled drive (an Engine maturation instant is
-- an exact integer in this world).
instantOf :: Number -> Integer
instantOf = \case
  IntNumber i -> i
  FloatNumber d -> ceiling d

-- | @TimerEngineProfile(history_path)@.
timerEngineProfile :: FilePath -> IO TimerProfile
timerEngineProfile historyPath = do
  time <- newWorldTime
  drops <- newIORef (0 :: Int)
  closes <- newIORef (0 :: Int)
  let scheduledAt instant =
        ScheduledCommand {instant, command = Command {profile = profileIdentity, name = "engine.drive", payload = Object []}}
      open load = do
        history <- openJsonlHistoryStore historyPath
        pool <- newInMemoryDispatch
        let options = Engine.defaultEngineOptions {Engine.clock = Just (worldClock time)}
        engine <-
          if load
            then Engine.load applicationNet instanceId history (inMemoryDispatch pool) options
            else
              Engine.create
                applicationNet
                instanceId
                history
                (inMemoryDispatch pool)
                options {Engine.marking = markingFromList [(waiting, [Token (Just "Waiting") Null])]}
        TimerGeneration engine history <$> newIORef 0
      start load = do
        current <- syncTime time
        g <- ioScenario (open load)
        pure GenerationStart {generation = g, scheduled = [scheduledAt current]}
      state g current = do
        records <- toList <$> g.history.snapshot
        snapshot <- engineCurrent g.engine
        d <- readIORef g.drives
        dropped <- readIORef drops
        pure
          [ ("authored_maturation_instant", Int maturationInstant)
          , ("current_instant", Int current)
          , ("drives", jsonInt d)
          , ("drops", jsonInt dropped)
          , ("frontier", jsonInt (length records))
          , ("marking", member "marking" snapshot)
          , ("next_maturation", member "next_maturation" snapshot)
          , ("record_types", Array (map (String . recordName) records))
          , ("status", member "status" snapshot)
          , ( "timer_maturations"
            , Array
                [ Object [("instant", numberJson r.instant), ("maturation_instant", numberJson r.maturationInstant)]
                | RTimerMatured r <- records
                ]
            )
          ]
      profile =
        Profile
          { identity = profileIdentity
          , validate = \c ->
              if c.name /= "engine.drive" || c.payload /= Object []
                then throwError (ProfileError "ValueError" "timer Engine profile accepts only engine.drive with an empty payload")
                else pure c
          , validateFault = \f -> throwError (ProfileError "ValueError" ("timer Engine profile has no fault named " <> pythonStrRepr f.name))
          , create = start False
          , load = start True
          , apply = \g _ -> do
              current <- syncTime time
              (outcome, snapshot, frontier) <- ioScenario $ do
                outcome <- Engine.advance g.engine
                modifyIORef' g.drives (+ 1)
                snapshot <- engineCurrent g.engine
                frontier <- historyLength g.history
                pure (outcome, snapshot, frontier)
              let status = member "status" snapshot
                  scheduled
                    | status `elem` [String "completed", String "terminated"] = []
                    | outcome.ready = [scheduledAt current]
                    | Just next <- outcome.nextMaturation = [scheduledAt (instantOf next)]
                    | otherwise = []
              pure
                ApplyResult
                  { disposition = Applied
                  , value =
                      Object
                        [ ("firings", Array [String (netPathText f.transition) | f <- outcome.firings])
                        , ("frontier", Int frontier)
                        , ("next_maturation", maybe Null numberJson outcome.nextMaturation)
                        , ("ready", Bool outcome.ready)
                        , ("status", status)
                        , ("waiting", Bool outcome.waiting)
                        ]
                  , scheduled
                  }
          , observe = \g request -> do
              current <- syncTime time
              fields <- case lookup request.name observationFields of
                Nothing -> raise "ValueError" ("unknown timer Engine profile observation " <> pythonStrRepr request.name)
                Just fs -> pure fs
              if request.payload == Null || request.payload == Object []
                then pure ()
                else raise "ValueError" "timer Engine profile observations do not accept parameters"
              select fields <$> ioScenario (state g current)
          , dropGeneration = \g -> ioDoor (modifyIORef' drops (+ 1) >> Engine.close g.engine)
          , closeGeneration = \g -> ioDoor (modifyIORef' closes (+ 1) >> Engine.close g.engine)
          , resourceUsage = Nothing
          }
  pure TimerProfile {profile, drops, closes}

-- | @TimerAuthorityChecker@.
timerAuthorityChecker :: Checker
timerAuthorityChecker =
  Checker
    { identity = checkerIdentity
    , request = ObservationRequest {name = "engine.timer-authority", payload = Object []}
    , check = pureCheck $ \o -> do
        let deadline = maybe 0 id (lookupInt "authored_maturation_instant" o.value)
            current = maybe 0 id (lookupInt "current_instant" o.value)
            records = case member "record_types" o.value of
              Array xs -> xs
              _ -> []
            maturations = case member "timer_maturations" o.value of
              Array xs -> xs
              _ -> []
            firingCompleted = countOf "FiringCompleted" records
            validMaturations =
              and
                [ member "maturation_instant" m == Int deadline
                    && case member "instant" m of
                      Int i -> deadline <= i && i <= current
                      _ -> False
                | m <- maturations
                ]
            passed =
              length maturations <= 1
                && validMaturations
                && firingCompleted <= length maturations
                && (current >= deadline || null maturations && firingCompleted == 0)
        Right
          CheckResult
            { passed
            , detail =
                Object
                  [ ("authored_maturation_instant", Int deadline)
                  , ("current_instant", Int current)
                  , ("firing_completed", jsonInt firingCompleted)
                  , ("timer_maturations", Array maturations)
                  ]
            }
    }

-- | @execute_timer_story(history_path)@: the authoring body.
executeTimerStory :: WorldT IO TimerGeneration ()
executeTimerStory = do
  timeline <- World.timeline
  armed <-
    Timeline.runUntil
      timeline
      "timer-armed"
      (\o -> memberOf "drives" o == Int 1 && memberOf "next_maturation" o == Int maturationInstant)
  ensure (memberOf "current_instant" armed == Int 0) "armed instant"
  ensure (memberOf "timer_maturations" armed == Array []) "armed maturations"
  ensure (memberOf "marking" armed == markingJson "waiting") "armed marking"
  Timeline.crash timeline "timer_observed_before_maturation"
  _ <- World.restart
  timeline' <- World.timeline
  recovered <- Timeline.runUntil timeline' "timer-recovered" (\o -> memberOf "drives" o == Int 1)
  ensure (memberOf "current_instant" recovered == Int 0) "recovered instant"
  ensure (memberOf "drops" recovered == Int 1) "recovered drops"
  ensure (memberOf "next_maturation" recovered == Int maturationInstant) "recovered maturation"
  ensure (memberOf "timer_maturations" recovered == Array []) "recovered maturations"
  Timeline.beginFair timeline'
  terminal <- Timeline.runUntil timeline' "timer-terminal" (\o -> memberOf "status" o == String "terminated")
  ensure (memberOf "current_instant" terminal == Int maturationInstant) "terminal instant"
  ensure
    ( memberOf "timer_maturations" terminal
        == Array [Object [("instant", Int maturationInstant), ("maturation_instant", Int maturationInstant)]]
    )
    "terminal maturations"
  ensure (memberOf "marking" terminal == markingJson "done") "terminal marking"
  Timeline.finish timeline' Converged
  where
    markingJson p = Array [Object [("place", String p), ("tokens", Array [Object [("color", String "Waiting"), ("data", Null)]])]]

-- | @build_timer_artifact(history_path)@.
buildTimerArtifact :: FilePath -> IO (Either DstFailure AnyArtifact)
buildTimerArtifact historyPath = do
  p <- timerEngineProfile historyPath
  World.withWorld
    WorldConfig {profile = p.profile, budget = worldBudget, checkers = [timerAuthorityChecker], seed = Nothing, progress = Nothing}
    (executeTimerStory >> World.artifact scenarioId)
