{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The delayed external terminal world: a port of the reference's
-- @tests/dst/delayed_world.py@. The projection profile of
-- "Petrus.Testing.Dst.Engine.Projection" retains one modeled external
-- terminal while the World owns its delivery instant; a crash before
-- delivery loses nothing because @load@ reschedules it.
module Petrus.Testing.Dst.Engine.Delayed
  ( scenarioId
  , terminalInstant
  , profileIdentity
  , checkerIdentity
  , worldBudget
  , DelayedProfile (..)
  , delayedEngineProfile
  , delayedAuthorityChecker
  , executeDelayedStory
  , buildDelayedArtifact
  ) where

import Control.Monad (when)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.IORef
import Data.Text (Text)
import Petrus.Json (Json (..))
import Petrus.Testing.Dst
import Petrus.Testing.Dst.Engine.Common
import Petrus.Testing.Dst.Engine.Projection (Base (..), EngineProfile (..), Generation (..))
import Petrus.Testing.Dst.Engine.Projection qualified as Projection
import Petrus.Testing.Dst.Timeline qualified as Timeline
import Petrus.Testing.Dst.World qualified as World

scenarioId :: Text
scenarioId = "delayed-terminal-recovery-world-v3"

terminalInstant :: Integer
terminalInstant = 5

strs :: [Text] -> Json
strs = Array . map String

profileIdentity :: ProfileIdentity
profileIdentity =
  Identity
    { name = "petrus.engine.delayed-terminal"
    , version = 1
    , digest =
        digestOf
          ( Object
              [ ( "commands"
                , Object
                    [ ("engine.complete", strs ["occurrence", "result"])
                    , ("engine.drive", Array [])
                    , ("provider.schedule-terminal", strs ["instant", "occurrence", "result"])
                    ]
                )
              , ("instance", String "dst-world-projection-recovery")
              , ( "observations"
                , strs
                    [ "activity-requested"
                    , "delayed-recovered"
                    , "delayed-scheduled"
                    , "delayed-terminal"
                    , "engine.delayed-authority"
                    ]
                )
              ]
          )
    }

checkerIdentity :: CheckerIdentity
checkerIdentity =
  Identity
    { name = "petrus.engine.delayed-terminal-authority"
    , version = 1
    , digest =
        digestOf
          ( Object
              [ ( "properties"
                , strs
                    [ "no canonical terminal precedes its authored external delivery"
                    , "a delivered external terminal produces at most one canonical terminal and projection"
                    , "canonical completion cannot precede the authored logical delivery instant"
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
      , queuedCommands = 4
      , timerAdvances = 1
      , logicalInstant = terminalInstant
      , reloads = 1
      , predicatePolls = 16
      , artifactBytes = 262144
      }

-- | A @DelayedEngineProfile@ and its retained external truth.
data DelayedProfile = DelayedProfile
  { engine :: EngineProfile
  , scheduledTerminal :: IORef (Maybe Json)
  , terminalDeliveries :: IORef Int
  }

-- | @DelayedEngineProfile(history_path)@.
delayedEngineProfile :: FilePath -> IO DelayedProfile
delayedEngineProfile historyPath = do
  b0 <- Projection.newBase historyPath
  scheduledRef <- newIORef Nothing
  deliveries <- newIORef (0 :: Int)
  let debug =
        [ "bridge"
        , "frontier"
        , "marking"
        , "pending"
        , "record_types"
        , "scheduled_terminal"
        , "status"
        , "terminal_deliveries"
        ]
      b =
        b0
          { identity = profileIdentity
          , observationFields =
              [ ("activity-requested", ["frontier", "pending", "record_types", "scheduled_terminal", "status", "terminal_deliveries"])
              , ("delayed-recovered", debug)
              , ("delayed-scheduled", debug)
              , ("delayed-terminal", debug)
              , ("engine.delayed-authority", ["record_types", "scheduled_terminal", "terminal_deliveries"])
              ]
          , extraState = do
              scheduled <- readIORef scheduledRef
              d <- readIORef deliveries
              pure [("scheduled_terminal", maybe Null id scheduled), ("terminal_deliveries", jsonInt d)]
          }
      p = Projection.baseProfile b
      terminalCommand :: Scenario IO ScheduledCommand
      terminalCommand =
        liftIO (readIORef scheduledRef) >>= \case
          Nothing -> raise "RuntimeError" "no delayed external terminal has been scheduled"
          Just proposal ->
            pure
              ScheduledCommand
                { instant = maybe 0 id (lookupInt "instant" proposal)
                , command =
                    Command
                      { profile = profileIdentity
                      , name = "engine.complete"
                      , payload = Object [("occurrence", member "occurrence" proposal), ("result", member "result" proposal)]
                      }
                }
      validate' c
        | c.name /= "provider.schedule-terminal" = p.validate c
        | not (exactKeys ["instant", "occurrence", "result"] c.payload) =
            throwError (ProfileError "ValueError" "provider.schedule-terminal requires exact instant, occurrence, and result fields")
        | member "instant" c.payload /= Int terminalInstant =
            throwError (ProfileError "ValueError" "provider.schedule-terminal requires the supported logical instant")
        | not (isPositiveInt (member "occurrence" c.payload)) =
            throwError (ProfileError "ValueError" "provider.schedule-terminal occurrence must be a positive integer")
        | otherwise = pure c
      load' = do
        started <- p.load
        scheduled <- liftIO (readIORef scheduledRef)
        d <- liftIO (readIORef deliveries)
        extra <- case scheduled of
          Just _ | d == 0 -> (: []) <$> terminalCommand
          _ -> pure []
        pure GenerationStart {generation = started.generation, scheduled = started.scheduled <> extra}
      apply' generation c
        | c.name == "provider.schedule-terminal" = do
            let proposal =
                  Object
                    [ ("instant", member "instant" c.payload)
                    , ("occurrence", member "occurrence" c.payload)
                    , ("result", member "result" c.payload)
                    ]
            existing <- liftIO (readIORef scheduledRef)
            when (existing /= Nothing) $ raise "ValueError" "the delayed-terminal profile accepts one external terminal schedule"
            liftIO (writeIORef scheduledRef (Just proposal))
            frontier <- ioScenario (historyLength generation.history)
            next <- terminalCommand
            pure
              ApplyResult
                { disposition = Applied
                , value = Object [("frontier", Int frontier), ("scheduled_terminal", proposal)]
                , scheduled = [next]
                }
        | otherwise = do
            result <- p.apply generation c
            when (c.name == "engine.complete") $ liftIO (modifyIORef' deliveries (+ 1))
            pure result
  pure
    DelayedProfile
      { engine = EngineProfile {base = b, profile = p {validate = validate', load = load', apply = apply'}}
      , scheduledTerminal = scheduledRef
      , terminalDeliveries = deliveries
      }

-- | @DelayedAuthorityChecker@.
delayedAuthorityChecker :: Checker
delayedAuthorityChecker =
  Checker
    { identity = checkerIdentity
    , request = ObservationRequest {name = "engine.delayed-authority", payload = Object []}
    , check = \o -> do
        let records = case member "record_types" o.value of
              Array xs -> xs
              _ -> []
            scheduled = member "scheduled_terminal" o.value
            deliveries = maybe 0 id (lookupInt "terminal_deliveries" o.value)
            completed = toInteger (countOf "ActivityCompleted" records)
            failed = toInteger (countOf "ActivityFailed" records)
            projected = toInteger (countOf "FiringCompleted" records)
            terminal = completed + failed
            scheduledInstant = case scheduled of
              Null -> Nothing
              _ -> lookupInt "instant" scheduled
            passed =
              deliveries <= (if scheduled == Null then 0 else 1)
                && terminal <= deliveries
                && failed == 0
                && projected == completed
                && (terminal == 0 || maybe False (o.instant >=) scheduledInstant)
        Right
          CheckResult
            { passed
            , detail =
                Object
                  [ ("activity_completed", Int completed)
                  , ("activity_failed", Int failed)
                  , ("firing_completed", Int projected)
                  , ("scheduled_instant", maybe Null Int scheduledInstant)
                  , ("terminal_deliveries", Int deliveries)
                  ]
            }
    }

-- | @execute_delayed_story(history_path)@: the authoring body.
executeDelayedStory :: WorldT IO Generation ()
executeDelayedStory = do
  timeline <- World.timeline
  requested <- Timeline.runUntil timeline "activity-requested" (\o -> memberOf "pending" o == Array [Int 1])
  ensure (memberOf "frontier" requested == Int 6) "requested frontier"
  scheduled <-
    Timeline.command
      timeline
      "provider.schedule-terminal"
      (Object [("instant", Int terminalInstant), ("occurrence", Int 1), ("result", Object [("value", Int 3)])])
  ensure (scheduled.disposition == Applied) "schedule applied"
  held <- Timeline.observe timeline "delayed-scheduled"
  ensure (held.instant == 0) "held instant"
  ensure (memberOf "terminal_deliveries" held == Int 0) "held deliveries"
  Timeline.crash timeline "external_terminal_scheduled_before_delivery"
  _ <- World.restart
  timeline' <- World.timeline
  recovered <- Timeline.runUntil timeline' "delayed-recovered" (\o -> memberOf "pending" o == Array [Int 1])
  ensure (recovered.instant == 0) "recovered instant"
  ensure (memberOf "bridge" recovered == bridgeJson 0 0) "recovered bridge"
  ensure (memberOf "terminal_deliveries" recovered == Int 0) "recovered deliveries"
  Timeline.beginFair timeline'
  terminal <- Timeline.runUntil timeline' "delayed-terminal" (\o -> memberOf "status" o == String "terminated")
  ensure (terminal.instant == terminalInstant) "terminal instant"
  ensure (memberOf "terminal_deliveries" terminal == Int 1) "terminal deliveries"
  ensure (memberOf "bridge" terminal == bridgeJson 0 1) "terminal bridge"
  ensure
    ( memberOf "marking" terminal
        == Array [Object [("place", String "done"), ("tokens", Array [Object [("color", String "Done"), ("data", Object [("value", Int 3)])]])]]
    )
    "terminal marking"
  Timeline.finish timeline' Converged
  where
    bridgeJson :: Integer -> Integer -> Json
    bridgeJson a c = Object [("prepared", Int a), ("projected", Int c)]

-- | @build_delayed_artifact(history_path)@.
buildDelayedArtifact :: FilePath -> IO (Either DstFailure AnyArtifact)
buildDelayedArtifact historyPath = do
  p <- delayedEngineProfile historyPath
  Projection.authorArtifact
    WorldConfig {profile = p.engine.profile, budget = worldBudget, checkers = [delayedAuthorityChecker], seed = Nothing, progress = Nothing}
    executeDelayedStory
    scenarioId

