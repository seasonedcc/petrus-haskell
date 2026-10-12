{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The identified source delivery world: a port of the reference's
-- @tests/dst/delivery_world.py@. One accepted external identity survives a
-- crash; exact redelivery is idempotent, changed content is refused, and a
-- distinct identity with an equal payload is a distinct fact.
module Petrus.Testing.Dst.Engine.Delivery
  ( instanceId
  , scenarioId
  , profileIdentity
  , checkerIdentity
  , worldBudget
  , applicationNet
  , DeliveryGeneration (..)
  , DeliveryProfile (..)
  , deliveryEngineProfile
  , deliveryAuthorityChecker
  , executeDeliveryStory
  , buildDeliveryArtifact
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Foldable (toList)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Engine (Engine)
import Petrus.Engine qualified as Engine
import Petrus.HistoryStore.Jsonl (openJsonlHistoryStore)
import Petrus.Impetus.History.Records (ExternalEventDelivered (..), Record (..))
import Petrus.Impetus.HistoryStore (HistoryStore (..))
import Petrus.Impetus.Instance (statusText)
import Petrus.Impetus.Petrinet
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch.InMemory (inMemoryDispatch, newInMemoryDispatch)
import Petrus.Testing.Dst
import Petrus.Testing.Dst.Engine.Common
import Petrus.Json.Python (pythonStrRepr)
import Petrus.Testing.Dst.Timeline qualified as Timeline
import Petrus.Testing.Dst.World qualified as World

source, output :: NetPath
source = either (error . T.unpack) id (netPath "source")
output = either (error . T.unpack) id (netPath "output")

instanceId, scenarioId :: Text
instanceId = "dst-world-identified-delivery"
scenarioId = "identified-delivery-redelivery-world-v3"

profileIdentity :: ProfileIdentity
profileIdentity =
  Identity
    { name = "petrus.engine.identified-delivery"
    , version = 1
    , digest =
        digestOf
          ( Object
              [ ("commands", Object [("source.deliver", strs ["identity", "value"])])
              , ("instance", String instanceId)
              , ("net", Object [("output", String "output"), ("source", String "source")])
              , ( "observations"
                , strs
                    [ "conflict-recovered"
                    , "conflict-refused"
                    , "delivery-accepted"
                    , "distinct-identity-accepted"
                    , "engine.delivery-authority"
                    , "redelivery-stable"
                    ]
                )
              ]
          )
    }

checkerIdentity :: CheckerIdentity
checkerIdentity =
  Identity
    { name = "petrus.engine.delivery-authority"
    , version = 1
    , digest =
        digestOf
          ( Object
              [ ( "properties"
                , strs
                    [ "one canonical delivery per accepted external identity"
                    , "exact redelivery is idempotent and changed content is refused"
                    , "distinct identities preserve equal payloads as distinct facts"
                    ]
                )
              ]
          )
    }

worldBudget :: SomeBudget
worldBudget =
  SomeBudget
    Budget
      { actions = 24
      , queuedCommands = 1
      , timerAdvances = 0
      , logicalInstant = 0
      , reloads = 2
      , predicatePolls = 8
      , artifactBytes = 262144
      }

applicationNet :: Net
applicationNet =
  either (error . T.unpack) id $
    mkNet
      NetSpec
        { places = [place output]
        , transitions = [transition source]
        , arcs = [arc source output]
        , completion = Nothing
        , name = Just "dst-world-identified-delivery"
        }

-- | @DeliveryGeneration@.
data DeliveryGeneration = DeliveryGeneration
  { engine :: Engine
  , history :: HistoryStore
  , markingValues :: IORef [Json]
  , status :: IORef Text
  , poisoned :: IORef Bool
  }

-- | A @DeliveryEngineProfile@ and its authored attempts.
data DeliveryProfile = DeliveryProfile
  { profile :: Profile IO DeliveryGeneration
  , deliveryAttempts :: IORef [Json]
  , drops :: IORef Int
  , closes :: IORef Int
  }

debugFields :: [Text]
debugFields = ["canonical_deliveries", "delivery_attempts", "firing_completed", "frontier", "marking_values", "status"]

observationFields :: [(Text, [Text])]
observationFields =
  [ ("conflict-recovered", debugFields)
  , ("conflict-refused", debugFields)
  , ("delivery-accepted", debugFields)
  , ("distinct-identity-accepted", debugFields)
  , ("engine.delivery-authority", ["canonical_deliveries", "delivery_attempts", "firing_completed", "marking_values"])
  , ("redelivery-stable", debugFields)
  ]

-- | @DeliveryEngineProfile(history_path)@.
deliveryEngineProfile :: FilePath -> IO DeliveryProfile
deliveryEngineProfile historyPath = do
  time <- newWorldTime
  attempts <- newIORef []
  drops <- newIORef (0 :: Int)
  closes <- newIORef (0 :: Int)
  let refresh g = do
        current <- engineCurrent g.engine
        let values = case member "marking" current of
              Array places ->
                concat
                  [ [member "data" t | t <- tokensOf p]
                  | p <- places
                  , member "place" p == String "output"
                  ]
              _ -> []
        writeIORef g.markingValues values
        s <- Engine.status g.engine
        writeIORef g.status (statusText s)
      tokensOf p = case member "tokens" p of
        Array ts -> ts
        _ -> []
      open load = do
        history <- openJsonlHistoryStore historyPath
        pool <- newInMemoryDispatch
        let options = Engine.defaultEngineOptions {Engine.clock = Just (worldClock time)}
        engine <-
          if load
            then Engine.load applicationNet instanceId history (inMemoryDispatch pool) options
            else Engine.create applicationNet instanceId history (inMemoryDispatch pool) options
        g <- DeliveryGeneration engine history <$> newIORef [] <*> newIORef "" <*> newIORef False
        refresh g
        pure g
      state g = do
        isPoisoned <- readIORef g.poisoned
        if isPoisoned then pure () else refresh g
        records <- toList <$> g.history.snapshot
        recorded <- readIORef attempts
        values <- readIORef g.markingValues
        s <- readIORef g.status
        let deliveries =
              [ Object
                  [ ("identity", String r.identity)
                  , ("occurrence", jsonInt r.occurrence)
                  , ("value", case r.tokens of t : _ -> t.payload; [] -> Null)
                  ]
              | RExternalEventDelivered r <- records
              ]
            completed = length [() | RFiringCompleted _ <- records]
        pure
          [ ("canonical_deliveries", Array deliveries)
          , ("delivery_attempts", Array recorded)
          , ("firing_completed", jsonInt completed)
          , ("frontier", jsonInt (length records))
          , ("marking_values", Array values)
          , ("status", String (if isPoisoned then "poisoned" else s))
          ]
      profile =
        Profile
          { identity = profileIdentity
          , validate = \c ->
              if c.name /= "source.deliver"
                then throwError (ProfileError "ValueError" ("unknown delivery Engine profile command " <> pythonStrRepr c.name))
                else
                  if not (exactKeys ["identity", "value"] c.payload)
                    then throwError (ProfileError "ValueError" "source.deliver requires exact identity and value fields")
                    else case (member "identity" c.payload, member "value" c.payload) of
                      (String i, _) | T.null i -> throwError (ProfileError "ValueError" "source.deliver identity must be a non-empty string")
                      (String _, Int _) -> pure c
                      (String _, _) -> throwError (ProfileError "ValueError" "source.deliver value must be an integer")
                      _ -> throwError (ProfileError "ValueError" "source.deliver identity must be a non-empty string")
          , validateFault = \f -> throwError (ProfileError "ValueError" ("delivery Engine profile has no fault named " <> pythonStrRepr f.name))
          , create = do
              _ <- syncTime time
              g <- ioScenario (open False)
              pure GenerationStart {generation = g, scheduled = []}
          , load = do
              _ <- syncTime time
              g <- ioScenario (open True)
              pure GenerationStart {generation = g, scheduled = []}
          , apply = \g c -> do
              _ <- syncTime time
              let identity = case member "identity" c.payload of
                    String i -> i
                    _ -> ""
                  value = member "value" c.payload
              outcome <- liftIO (try (Engine.deliver g.engine source [Token (Just "External") value] identity Nothing))
              disposition <- case outcome of
                Left (e :: SomeException) -> do
                  let (cls, message) = pythonError e
                  if cls == "ValueError" && "identity conflict" `T.isInfixOf` message
                    then do
                      liftIO (writeIORef g.poisoned True)
                      pure RefusedExpected
                    else raise cls message
                Right delivered -> do
                  ioScenario (refresh g)
                  pure $ case delivered of
                    Engine.DeliveryPrior _ -> Idempotent
                    _ -> Applied
              let attempt =
                    Object
                      [ ("disposition", String (actionDispositionText disposition))
                      , ("identity", String identity)
                      , ("value", value)
                      ]
              liftIO (modifyIORef' attempts (<> [attempt]))
              frontier <- ioScenario (historyLength g.history)
              pure ApplyResult {disposition, value = Object [("attempt", attempt), ("frontier", Int frontier)], scheduled = []}
          , observe = \g request -> do
              _ <- syncTime time
              fields <- case lookup request.name observationFields of
                Nothing -> raise "ValueError" ("unknown delivery Engine profile observation " <> pythonStrRepr request.name)
                Just fs -> pure fs
              if request.payload == Null || request.payload == Object []
                then pure ()
                else raise "ValueError" "delivery Engine profile observations do not accept parameters"
              select fields <$> ioScenario (state g)
          , dropGeneration = \g -> ioDoor (modifyIORef' drops (+ 1) >> Engine.close g.engine)
          , closeGeneration = \g -> ioDoor (modifyIORef' closes (+ 1) >> Engine.close g.engine)
          , resourceUsage = Nothing
          }
  pure DeliveryProfile {profile, deliveryAttempts = attempts, drops, closes}

-- | @DeliveryAuthorityChecker@.
deliveryAuthorityChecker :: Checker
deliveryAuthorityChecker =
  Checker
    { identity = checkerIdentity
    , request = ObservationRequest {name = "engine.delivery-authority", payload = Object []}
    , check = pureCheck $ \o -> do
        let attempts = listOf "delivery_attempts" o.value
            canonical = listOf "canonical_deliveries" o.value
            step (accepted, deliveries, dispositions) attempt =
              let identity = member "identity" attempt
                  payload = member "value" attempt
               in case lookup identity accepted of
                    Nothing ->
                      ( accepted <> [(identity, payload)]
                      , deliveries <> [Object [("identity", identity), ("value", payload)]]
                      , dispositions <> [String "applied"]
                      )
                    Just prior
                      | prior == payload -> (accepted, deliveries, dispositions <> [String "idempotent"])
                      | otherwise -> (accepted, deliveries, dispositions <> [String "refused_expected"])
            (_, expectedDeliveries, expectedDispositions) = foldl step ([], [], []) attempts
            actualDeliveries = [Object [("identity", member "identity" d), ("value", member "value" d)] | d <- canonical]
            reported = [member "disposition" a | a <- attempts]
            expectedValues = [member "value" d | d <- expectedDeliveries]
            firingCompleted = member "firing_completed" o.value
            markingValues = listOf "marking_values" o.value
            passed =
              actualDeliveries == expectedDeliveries
                && reported == expectedDispositions
                && firingCompleted == jsonInt (length expectedDeliveries)
                && markingValues == expectedValues
        Right
          CheckResult
            { passed
            , detail =
                Object
                  [ ("actual_deliveries", Array actualDeliveries)
                  , ("expected_deliveries", Array expectedDeliveries)
                  , ("expected_dispositions", Array expectedDispositions)
                  , ("firing_completed", firingCompleted)
                  , ("marking_values", Array markingValues)
                  , ("reported_dispositions", Array reported)
                  ]
            }
    }

deliveriesCount :: Observation -> Int
deliveriesCount o = case memberOf "canonical_deliveries" o of
  Array xs -> length xs
  _ -> 0

deliverCommand :: Timeline -> Text -> Integer -> WorldT IO DeliveryGeneration ApplyResult
deliverCommand timeline identity value =
  Timeline.command timeline "source.deliver" (Object [("identity", String identity), ("value", Int value)])

-- | @execute_delivery_story(history_path)@: the authoring body.
executeDeliveryStory :: WorldT IO DeliveryGeneration ()
executeDeliveryStory = do
  timeline <- World.timeline
  accepted <- deliverCommand timeline "event-3" 3
  ensure (accepted.disposition == Applied) "accepted"
  first <- Timeline.runUntil timeline "delivery-accepted" ((== 1) . deliveriesCount)
  ensure (memberOf "marking_values" first == Array [Int 3]) "first marking"
  let acceptedFrontier = memberOf "frontier" first
  Timeline.crash timeline "source_delivery_committed_before_redelivery"
  _ <- World.restart
  timeline2 <- World.timeline
  duplicate <- deliverCommand timeline2 "event-3" 3
  ensure (duplicate.disposition == Idempotent) "duplicate"
  stable <- Timeline.observe timeline2 "redelivery-stable"
  ensure (memberOf "frontier" stable == acceptedFrontier) "stable frontier"
  ensure (memberOf "marking_values" stable == Array [Int 3]) "stable marking"
  distinct <- deliverCommand timeline2 "event-3-copy" 3
  ensure (distinct.disposition == Applied) "distinct"
  preserved <- Timeline.runUntil timeline2 "distinct-identity-accepted" ((== 2) . deliveriesCount)
  ensure (memberOf "marking_values" preserved == Array [Int 3, Int 3]) "preserved marking"
  ensure (memberOf "status" preserved == String "awaiting") "preserved status"
  let distinctFrontier = memberOf "frontier" preserved
  conflict <- deliverCommand timeline2 "event-3" 4
  ensure (conflict.disposition == RefusedExpected) "conflict"
  refused <- Timeline.observe timeline2 "conflict-refused"
  ensure (memberOf "frontier" refused == distinctFrontier) "refused frontier"
  ensure (memberOf "marking_values" refused == Array [Int 3, Int 3]) "refused marking"
  ensure (memberOf "status" refused == String "poisoned") "refused status"
  Timeline.crash timeline2 "source_identity_conflict_before_reload"
  _ <- World.restart
  timeline3 <- World.timeline
  recoveredDuplicate <- deliverCommand timeline3 "event-3-copy" 3
  ensure (recoveredDuplicate.disposition == Idempotent) "recovered duplicate"
  recovered <- Timeline.observe timeline3 "conflict-recovered"
  ensure (memberOf "frontier" recovered == distinctFrontier) "recovered frontier"
  ensure (memberOf "marking_values" recovered == Array [Int 3, Int 3]) "recovered marking"
  ensure (memberOf "status" recovered == String "awaiting") "recovered status"
  Timeline.finish timeline3 ExternalWait

-- | @build_delivery_artifact(history_path)@.
buildDeliveryArtifact :: FilePath -> IO (Either DstFailure AnyArtifact)
buildDeliveryArtifact historyPath = do
  p <- deliveryEngineProfile historyPath
  World.withWorld
    WorldConfig {profile = p.profile, budget = worldBudget, checkers = [deliveryAuthorityChecker], seed = Nothing, progress = Nothing}
    (executeDeliveryStory >> World.artifact scenarioId)
