{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The joined worlds' authored stories: ports of every
-- @execute_joined_*_story@ / @build_joined_*_artifact@ of the reference's
-- @tests/dst/joined_world.py@, @joined_registration_world.py@ and
-- @joined_seal_world.py@ (the creation stories live in
-- "Petrus.Testing.Dst.Joined.Creation").
--
-- Each story issues exactly the reference's commands, faults, crash cuts,
-- restarts, polls and finish, and keeps every one of its assertions (a
-- failed assertion refuses the story as @AssertionError@).
module Petrus.Testing.Dst.Joined.Stories
  ( buildBeginArtifact
  , buildDispatchArtifact
  , buildAckLossArtifact
  , buildDeliveryRefusalArtifact
  , buildDeliveryAckLossArtifact
  , buildTerminalRefusalArtifact
  , buildFailureRefusalArtifact
  , buildFailureAckLossArtifact
  , buildTerminalAckLossArtifact
  , buildProjectionArtifact
  , buildProjectionAckLossArtifact
  , buildResetRefusalArtifact
  , buildResetAckLossArtifact
  , buildCancellationArtifact
  , buildCancellationAckLossArtifact
  , buildCloseRefusalArtifact
  , buildCloseAckLossArtifact
  , buildOpenRefusalArtifact
  , buildOpenAckLossArtifact
  , buildFailureProjectionRefusalArtifact
  , buildFailureProjectionAckLossArtifact
  , buildScopedDropRefusalArtifact
  , buildScopedDropAckLossArtifact
  , buildScopedQuarantineRefusalArtifact
  , buildScopedQuarantineAckLossArtifact
  , buildRegistrationRefusalArtifact
  , buildRegistrationAckLossArtifact
  , buildSealRefusalArtifact
  , buildSealAckLossArtifact
  ) where

import Control.Monad (forM_, void)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.IORef (readIORef)
import Data.Text (Text)
import Petrus.Json (Json (..))
import Petrus.Testing.Dst
import Petrus.Testing.Dst.Engine.Common (atKey, ensure, memberOf)
import Petrus.Testing.Dst.Joined.Checkers qualified as C
import Petrus.Testing.Dst.Joined.Support (listOf, pyEq, strs)
import Petrus.Testing.Dst.Joined.World
import Petrus.Testing.Dst.Timeline qualified as Timeline
import Petrus.Testing.Dst.World qualified as World

type Story = WorldT IO JoinedGeneration

-- ---------------------------------------------------------------------------
-- Helpers

-- | @assert observation.value[key] == expected@ (Python equality).
is :: Observation -> Text -> Json -> Story ()
is o key expected = ensure (pyEq (memberOf key o) expected) ("observation " <> o.name <> " " <> key)

-- | Several @is@ assertions.
are :: Observation -> [(Text, Json)] -> Story ()
are o = mapM_ (uncurry (is o))

-- | @assert observation.value[key][-n:] == expected@.
endsWith :: Observation -> Text -> [Json] -> Story ()
endsWith o key expected =
  let xs = listOf (memberOf key o)
   in ensure (pyEq (Array (drop (length xs - length expected) xs)) (Array expected)) ("observation " <> o.name <> " tail of " <> key)

-- | @assert name not in observation.value[key]@.
excludes :: Observation -> Text -> Text -> Story ()
excludes o key name = ensure (String name `notElem` listOf (memberOf key o)) ("observation " <> o.name <> " excludes " <> name)

-- | @assert observation.value[key] == other.value[key]@.
same :: Observation -> Observation -> Text -> Story ()
same o other key = is o key (memberOf key other)

int :: Integer -> Json
int = Int

disposed :: ApplyResult -> ActionDisposition -> Story ()
disposed result expected = ensure (result.disposition == expected) ("command disposition " <> actionDispositionText expected)

tx :: Bool -> Bool -> [Text] -> Json
tx accepted dispatched types =
  Object [("accepted", Bool accepted), ("dispatch_attempted", Bool dispatched), ("record_types", strs types)]

lc :: Bool -> Text -> [Text] -> Json
lc accepted phase types = Object [("accepted", Bool accepted), ("phase", String phase), ("record_types", strs types)]

task :: Integer -> Text -> Json
task occurrence state =
  Array
    [ Object
        [ ("idempotency", String (instanceId <> ":occurrence-" <> (if occurrence == 1 then "1" else "2")))
        , ("state", String state)
        ]
    ]

beginBatch :: [Text]
beginBatch = ["CandidateSelected", "FiringBegun", "TokensConsumed", "ActivityRequested"]

initialRecords, begunRecords :: [Text]
initialRecords = ["InstanceCreated", "TokensInitialized"]
begunRecords = initialRecords <> beginBatch

records :: [Text] -> Json
records = strs

empty :: Json
empty = Object []

draft :: Json
draft = Object [("name", String "draft")]

fault :: Text -> Text -> FaultDisposition -> Text -> Timeline.FaultSpec
fault name target disposition message =
  (Timeline.fault name target) {Timeline.disposition = disposition, Timeline.payload = Object [("message", String message)]}

refuse, loseAck :: Text -> Text -> Timeline.FaultSpec
refuse target = fault "history.commit-refuse" target Refuse
loseAck target = fault "history.lose-ack" target Raise

hasRecord :: Text -> Observation -> Bool
hasRecord name o = String name `elem` listOf (memberOf "record_types" o)

countRecord :: Text -> Observation -> Int
countRecord name o = length (filter (== String name) (listOf (memberOf "record_types" o)))

-- | Crash at a cut, restart, and return the new timeline.
crashAndRestart :: Timeline -> Text -> Story Timeline
crashAndRestart timeline cut = do
  Timeline.crash timeline cut
  void World.restart
  World.timeline

-- | @World(profile, budget, checkers=(checker,))@, the story, and
-- @world.artifact(scenario_id)@ (closing the World either way).
build :: Family -> SomeBudget -> Checker -> Text -> (JoinedProfile -> Story ()) -> ByteString -> IO (Either DstFailure AnyArtifact)
build family budget checker scenarioId story dsn = do
  p <- joinedProfile family dsn
  World.withWorld
    WorldConfig {profile = p.profile, budget, checkers = [checker], seed = Nothing, progress = Nothing}
    (story p >> World.artifact scenarioId)

-- ---------------------------------------------------------------------------
-- Begin

-- | The shared body of @execute_joined_begin_story@ and
-- @execute_joined_dispatch_story@.
beginStory :: Timeline.FaultSpec -> Text -> Text -> Text -> Text -> Story ()
beginStory spec refusedName counter cut recoveredName = do
  timeline <- World.timeline
  Timeline.activateFault timeline spec
  void (Timeline.command timeline "engine.drive" empty)
  refused <- Timeline.observe timeline refusedName
  are
    refused
    [ ("frontier", int 2)
    , ("record_types", records initialRecords)
    , ("durable_tasks", Array [])
    , ("prepare_calls", int 1)
    , (counter, int 1)
    , ("status", String "poisoned")
    ]
  timeline' <- crashAndRestart timeline cut
  recovered <- Timeline.runUntil timeline' recoveredName (\o -> length (listOf (memberOf "durable_tasks" o)) == 1)
  are
    recovered
    [ ("frontier", int 6)
    , ("record_types", records begunRecords)
    , ("prepare_calls", int 2)
    , ("transaction_attempts", Array [tx False True beginBatch, tx True True beginBatch])
    ]
  Timeline.finish timeline' ExternalWait

-- | @build_joined_begin_artifact(dsn)@.
buildBeginArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildBeginArtifact =
  build FBegin worldBudget C.commitAuthorityChecker "joined-begin-commit-refusal-world-v3" $ \_ ->
    beginStory
      (refuse "activity_requested" "dst joined begin commit refused")
      "joined-begin-refused"
      "commit_refusals"
      "semantic_batch_refused"
      "joined-begin-recovered"

-- | @build_joined_dispatch_artifact(dsn)@.
buildDispatchArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildDispatchArtifact =
  build FDispatch worldBudget C.commitAuthorityChecker "joined-dispatch-refusal-world-v3" $ \_ ->
    beginStory
      (fault "dispatch.refuse" "activity_requested" Refuse "dst joined Dispatch spawn refused")
      "joined-dispatch-refused"
      "dispatch_refusals"
      "joined_dispatch_refused"
      "joined-dispatch-recovered"

-- | @build_joined_ack_loss_artifact(dsn)@.
buildAckLossArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildAckLossArtifact =
  build FBeginAckLoss worldBudget C.acceptedBeginAuthorityChecker "joined-begin-ack-loss-world-v3" $ \_ -> do
    timeline <- World.timeline
    Timeline.activateFault timeline (loseAck "activity_requested_committed" "dst joined begin acknowledgement lost")
    void (Timeline.command timeline "engine.drive" empty)
    lost <- Timeline.observe timeline "joined-begin-ack-lost"
    are
      lost
      [ ("frontier", int 6)
      , ("record_types", records begunRecords)
      , ("durable_tasks", task 1 "pending")
      , ("prepare_calls", int 1)
      , ("commit_ack_losses", int 1)
      , ("drive_calls", int 1)
      , ("status", String "poisoned")
      ]
    timeline' <- crashAndRestart timeline "joined_begin_committed_ack_lost"
    recovered <- Timeline.runUntil timeline' "joined-begin-ack-recovered" (\o -> pyEq (memberOf "drive_calls" o) (int 2))
    is recovered "frontier" (int 6)
    same recovered lost "record_types"
    same recovered lost "durable_tasks"
    are
      recovered
      [ ("prepare_calls", int 1)
      , ("commit_ack_losses", int 1)
      , ("transaction_attempts", Array [tx True True beginBatch])
      ]
    Timeline.finish timeline' ExternalWait

-- ---------------------------------------------------------------------------
-- Delivery

deliveryPayload :: Json
deliveryPayload = Object [("identity", String "event-3"), ("value", int 3)]

acceptanceBatch, completionBatch :: [Text]
acceptanceBatch = ["ExternalEventDelivered", "FiringBegun"]
completionBatch = ["TokensProduced", "FiringCompleted"]

canonicalEvent :: Json
canonicalEvent = Array [Object [("identity", String "event-3"), ("occurrence", int 1), ("value", int 3)]]

dispositions :: [ActionDisposition] -> Json
dispositions = Array . map (String . actionDispositionText)

attemptDispositions :: Json -> Json
attemptDispositions = Array . map (atKey "disposition") . listOf

-- | @build_joined_delivery_refusal_artifact(dsn)@.
buildDeliveryRefusalArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildDeliveryRefusalArtifact =
  build FDeliveryRefusal worldBudget C.deliveryAuthorityChecker "joined-delivery-commit-refusal-world-v3" $ \_ -> do
    timeline <- World.timeline
    Timeline.activateFault timeline (refuse "delivery_accepted" "dst joined delivery commit refused")
    refusedCommand <- Timeline.command timeline "source.deliver" deliveryPayload
    disposed refusedCommand RefusedExpected
    refused <- Timeline.observe timeline "joined-delivery-refused"
    are
      refused
      [ ("canonical_deliveries", Array [])
      , ("produced_values", Array [])
      , ("frontier", int 2)
      , ("delivery_refusals", int 1)
      , ("delivery_ack_losses", int 0)
      , ("transaction_attempts", Array [tx False False acceptanceBatch])
      , ("status", String "poisoned")
      ]
    timeline' <- crashAndRestart timeline "joined_delivery_commit_refused"
    acceptedCommand <- Timeline.command timeline' "source.deliver" deliveryPayload
    disposed acceptedCommand Applied
    recovered <- Timeline.observe timeline' "joined-delivery-recovered"
    are
      recovered
      [ ("canonical_deliveries", canonicalEvent)
      , ("produced_values", Array [int 3])
      , ("firing_completed", int 1)
      ,
        ( "transaction_attempts"
        , Array [tx False False acceptanceBatch, tx True False acceptanceBatch, tx True False completionBatch]
        )
      ]
    duplicate <- Timeline.command timeline' "source.deliver" deliveryPayload
    disposed duplicate Idempotent
    redelivered <- Timeline.observe timeline' "joined-delivery-redelivered"
    same redelivered recovered "frontier"
    same redelivered recovered "canonical_deliveries"
    ensure
      (pyEq (attemptDispositions (memberOf "delivery_attempts" redelivered)) (dispositions [RefusedExpected, Applied, Idempotent]))
      "redelivered dispositions"
    Timeline.finish timeline' ExternalWait

-- | @build_joined_delivery_ack_loss_artifact(dsn)@.
buildDeliveryAckLossArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildDeliveryAckLossArtifact =
  build FDeliveryAckLoss worldBudget C.deliveryAuthorityChecker "joined-delivery-ack-loss-world-v3" $ \p -> do
    timeline <- World.timeline
    Timeline.activateFault timeline (loseAck "delivery_accepted_committed" "dst joined delivery acknowledgement lost")
    lostCommand <- Timeline.command timeline "source.deliver" deliveryPayload
    disposed lostCommand RefusedExpected
    lost <- Timeline.observe timeline "joined-delivery-ack-lost"
    are
      lost
      [ ("canonical_deliveries", canonicalEvent)
      , ("produced_values", Array [])
      , ("firing_completed", int 0)
      , ("frontier", int 4)
      , ("delivery_refusals", int 0)
      , ("delivery_ack_losses", int 1)
      , ("transaction_attempts", Array [tx True False acceptanceBatch])
      , ("status", String "poisoned")
      ]
    timeline' <- crashAndRestart timeline "joined_delivery_committed_ack_lost"
    duplicate <- Timeline.command timeline' "source.deliver" deliveryPayload
    disposed duplicate Applied
    recovered <- Timeline.observe timeline' "joined-delivery-ack-recovered"
    is recovered "frontier" (int 6)
    same recovered lost "canonical_deliveries"
    are
      recovered
      [ ("produced_values", Array [int 3])
      , ("firing_completed", int 1)
      , ("transaction_attempts", Array [tx True False acceptanceBatch, tx True False completionBatch])
      ]
    acknowledged <- Timeline.command timeline' "source.deliver" deliveryPayload
    disposed acknowledged Idempotent
    ensure
      (pyEq (attemptDispositions (memberOf "delivery_attempts" recovered)) (dispositions [RefusedExpected, Applied]))
      "recovered dispositions"
    attempts <- liftIO (readIORef p.deliveryAttempts)
    ensure
      (pyEq (attemptDispositions (Array attempts)) (dispositions [RefusedExpected, Applied, Idempotent]))
      "profile delivery attempts"
    Timeline.finish timeline' ExternalWait

-- ---------------------------------------------------------------------------
-- Terminal, failure and projection

-- | drive, claim, and complete (or fail) the one Activity.
settle :: Timeline -> Bool -> Story ()
settle timeline failing = do
  void (Timeline.command timeline "engine.drive" empty)
  void (Timeline.command timeline "worker.claim" empty)
  if failing
    then void (Timeline.command timeline "worker.fail" (Object [("error", String "dst joined terminal failure")]))
    else void (Timeline.command timeline "worker.complete" (Object [("result", Object [("value", int 3)])]))

completedRecords, projectedRecords, failedRecords, firingFailedRecords :: [Text]
completedRecords = begunRecords <> ["ActivityCompleted"]
projectedRecords = completedRecords <> ["TokensProduced", "FiringCompleted"]
failedRecords = begunRecords <> ["ActivityFailed"]
firingFailedRecords = failedRecords <> ["FiringFailed"]

-- | @build_joined_terminal_refusal_artifact(dsn)@.
buildTerminalRefusalArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildTerminalRefusalArtifact =
  build FTerminalRefusal worldBudget C.terminalAuthorityChecker "joined-terminal-commit-refusal-world-v3" $ \_ -> do
    timeline <- World.timeline
    settle timeline False
    Timeline.activateFault timeline (refuse "activity_completed" "dst joined terminal commit refused")
    void (Timeline.command timeline "engine.drive" empty)
    refused <- Timeline.observe timeline "joined-terminal-refused"
    are
      refused
      [ ("record_types", records begunRecords)
      , ("durable_tasks", task 1 "completed")
      , ("frontier", int 6)
      , ("prepare_calls", int 1)
      , ("terminal_refusals", int 1)
      , ("status", String "poisoned")
      , ("worker_completions", int 1)
      ]
    timeline' <- crashAndRestart timeline "joined_terminal_commit_refused"
    recovered <- Timeline.runUntil timeline' "joined-terminal-recovered" (hasRecord "FiringCompleted")
    are
      recovered
      [ ("record_types", records projectedRecords)
      , ("frontier", int 9)
      , ("prepare_calls", int 1)
      , ("worker_completions", int 1)
      , ("terminal_refusals", int 1)
      ,
        ( "transaction_attempts"
        , Array
            [ tx True True beginBatch
            , tx False False ["ActivityCompleted"]
            , tx True False ["ActivityCompleted"]
            , tx True False completionBatch
            ]
        )
      ]
    Timeline.finish timeline' Converged

-- | @build_joined_failure_refusal_artifact(dsn)@.
buildFailureRefusalArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildFailureRefusalArtifact =
  build FFailureRefusal worldBudget C.failureAuthorityChecker "joined-failure-commit-refusal-world-v3" $ \_ -> do
    timeline <- World.timeline
    settle timeline True
    Timeline.activateFault timeline (refuse "activity_failed" "dst joined failure commit refused")
    void (Timeline.command timeline "engine.drive" empty)
    refused <- Timeline.observe timeline "joined-failure-refused"
    are
      refused
      [ ("record_types", records begunRecords)
      , ("durable_tasks", task 1 "failed")
      , ("frontier", int 6)
      , ("prepare_calls", int 1)
      , ("terminal_refusals", int 1)
      , ("status", String "poisoned")
      , ("worker_failures", int 1)
      ]
    timeline' <- crashAndRestart timeline "joined_failure_commit_refused"
    recovered <- Timeline.runUntil timeline' "joined-failure-recovered" (hasRecord "FiringFailed")
    are
      recovered
      [ ("record_types", records firingFailedRecords)
      , ("frontier", int 8)
      , ("prepare_calls", int 1)
      , ("worker_failures", int 1)
      , ("terminal_refusals", int 1)
      ,
        ( "transaction_attempts"
        , Array
            [ tx True True beginBatch
            , tx False False ["ActivityFailed"]
            , tx True False ["ActivityFailed"]
            , tx True False ["FiringFailed"]
            ]
        )
      ]
    Timeline.finish timeline' Quarantined

-- | @build_joined_failure_ack_loss_artifact(dsn)@.
buildFailureAckLossArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildFailureAckLossArtifact =
  build FFailureAckLoss worldBudget C.acceptedFailureAuthorityChecker "joined-failure-ack-loss-world-v3" $ \_ -> do
    timeline <- World.timeline
    settle timeline True
    Timeline.activateFault timeline (loseAck "activity_failed_committed" "dst joined failure acknowledgement lost")
    void (Timeline.command timeline "engine.drive" empty)
    lost <- Timeline.observe timeline "joined-failure-ack-lost"
    are
      lost
      [ ("record_types", records failedRecords)
      , ("durable_tasks", task 1 "failed")
      , ("frontier", int 7)
      , ("prepare_calls", int 1)
      , ("terminal_ack_losses", int 1)
      , ("status", String "poisoned")
      , ("worker_failures", int 1)
      ]
    timeline' <- crashAndRestart timeline "joined_failure_committed_ack_lost"
    recovered <- Timeline.runUntil timeline' "joined-failure-ack-recovered" (hasRecord "FiringFailed")
    are
      recovered
      [ ("record_types", records firingFailedRecords)
      , ("frontier", int 8)
      , ("prepare_calls", int 1)
      , ("worker_failures", int 1)
      , ("terminal_ack_losses", int 1)
      ,
        ( "transaction_attempts"
        , Array [tx True True beginBatch, tx True False ["ActivityFailed"], tx True False ["FiringFailed"]]
        )
      ]
    Timeline.finish timeline' Quarantined

-- | @build_joined_terminal_ack_loss_artifact(dsn)@.
buildTerminalAckLossArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildTerminalAckLossArtifact =
  build FTerminalAckLoss worldBudget C.acceptedTerminalAuthorityChecker "joined-terminal-ack-loss-world-v3" $ \_ -> do
    timeline <- World.timeline
    settle timeline False
    Timeline.activateFault timeline (loseAck "activity_completed_committed" "dst joined terminal acknowledgement lost")
    void (Timeline.command timeline "engine.drive" empty)
    lost <- Timeline.observe timeline "joined-terminal-ack-lost"
    are
      lost
      [ ("record_types", records completedRecords)
      , ("durable_tasks", task 1 "completed")
      , ("frontier", int 7)
      , ("prepare_calls", int 1)
      , ("terminal_ack_losses", int 1)
      , ("status", String "poisoned")
      , ("worker_completions", int 1)
      ]
    timeline' <- crashAndRestart timeline "joined_terminal_committed_ack_lost"
    recovered <- Timeline.runUntil timeline' "joined-terminal-ack-recovered" (hasRecord "FiringCompleted")
    are
      recovered
      [ ("record_types", records projectedRecords)
      , ("frontier", int 9)
      , ("prepare_calls", int 1)
      , ("worker_completions", int 1)
      , ("terminal_ack_losses", int 1)
      ,
        ( "transaction_attempts"
        , Array [tx True True beginBatch, tx True False ["ActivityCompleted"], tx True False completionBatch]
        )
      ]
    Timeline.finish timeline' Converged

-- | @build_joined_projection_artifact(dsn)@.
buildProjectionArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildProjectionArtifact =
  build FProjection worldBudget C.projectionAuthorityChecker "joined-projection-commit-refusal-world-v3" $ \_ -> do
    timeline <- World.timeline
    settle timeline False
    Timeline.activateFault timeline (refuse "projection_committed" "dst joined projection commit refused")
    void (Timeline.command timeline "engine.drive" empty)
    refused <- Timeline.observe timeline "joined-projection-refused"
    are
      refused
      [ ("record_types", records completedRecords)
      , ("durable_tasks", task 1 "completed")
      , ("frontier", int 7)
      , ("prepare_calls", int 1)
      , ("projection_refusals", int 1)
      , ("status", String "poisoned")
      , ("worker_completions", int 1)
      ]
    timeline' <- crashAndRestart timeline "projection_batch_refused"
    recovered <- Timeline.runUntil timeline' "joined-projection-recovered" (hasRecord "FiringCompleted")
    are
      recovered
      [ ("record_types", records projectedRecords)
      , ("frontier", int 9)
      , ("prepare_calls", int 1)
      , ("worker_completions", int 1)
      ,
        ( "transaction_attempts"
        , Array
            [ tx True True beginBatch
            , tx True False ["ActivityCompleted"]
            , tx False False completionBatch
            , tx True False completionBatch
            ]
        )
      ]
    Timeline.finish timeline' Converged

-- | @build_joined_projection_ack_loss_artifact(dsn)@.
buildProjectionAckLossArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildProjectionAckLossArtifact =
  build FProjectionAckLoss worldBudget C.acceptedProjectionAuthorityChecker "joined-projection-ack-loss-world-v3" $ \_ -> do
    timeline <- World.timeline
    settle timeline False
    Timeline.activateFault timeline (loseAck "projection_committed" "dst joined projection acknowledgement lost")
    void (Timeline.command timeline "engine.drive" empty)
    lost <- Timeline.observe timeline "joined-projection-ack-lost"
    are
      lost
      [ ("record_types", records projectedRecords)
      , ("durable_tasks", task 1 "completed")
      , ("frontier", int 9)
      , ("prepare_calls", int 1)
      , ("projection_ack_losses", int 1)
      , ("status", String "poisoned")
      , ("worker_completions", int 1)
      ]
    timeline' <- crashAndRestart timeline "joined_projection_committed_ack_lost"
    recovered <- Timeline.runUntil timeline' "joined-projection-ack-recovered" (\o -> pyEq (memberOf "drive_calls" o) (int 3))
    same recovered lost "record_types"
    same recovered lost "durable_tasks"
    are
      recovered
      [ ("frontier", int 9)
      , ("prepare_calls", int 1)
      , ("worker_completions", int 1)
      , ("projection_ack_losses", int 1)
      ,
        ( "transaction_attempts"
        , Array [tx True True beginBatch, tx True False ["ActivityCompleted"], tx True False completionBatch]
        )
      ]
    Timeline.finish timeline' Converged

-- | @build_joined_failure_projection_artifact(dsn)@.
buildFailureProjectionRefusalArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildFailureProjectionRefusalArtifact =
  build
    FFailureProjectionRefusal
    worldBudget
    C.failureProjectionAuthorityChecker
    "joined-failure-projection-commit-refusal-world-v3"
    $ \_ -> do
      timeline <- World.timeline
      settle timeline True
      Timeline.activateFault timeline (refuse "firing_failed" "dst joined failed projection commit refused")
      void (Timeline.command timeline "engine.drive" empty)
      refused <- Timeline.observe timeline "joined-failure-projection-refused"
      endsWith refused "record_types" [String "ActivityFailed"]
      excludes refused "record_types" "FiringFailed"
      are refused [("frontier", int 7), ("projection_refusals", int 1), ("worker_failures", int 1)]
      timeline' <- crashAndRestart timeline "joined_failure_projection_commit_refused"
      recovered <- Timeline.runUntil timeline' "joined-failure-projection-recovered" (hasRecord "FiringFailed")
      is recovered "frontier" (int 8)
      endsWith recovered "record_types" [String "ActivityFailed", String "FiringFailed"]
      endsWith recovered "transaction_attempts" [tx False False ["FiringFailed"], tx True False ["FiringFailed"]]
      Timeline.finish timeline' Quarantined

-- | @build_joined_failure_projection_ack_loss_artifact(dsn)@.
buildFailureProjectionAckLossArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildFailureProjectionAckLossArtifact =
  build
    FFailureProjectionAckLoss
    worldBudget
    C.acceptedFailureProjectionAuthorityChecker
    "joined-failure-projection-ack-loss-world-v3"
    $ \_ -> do
      timeline <- World.timeline
      settle timeline True
      Timeline.activateFault timeline (loseAck "firing_failed_committed" "dst joined failed projection acknowledgement lost")
      void (Timeline.command timeline "engine.drive" empty)
      lost <- Timeline.observe timeline "joined-failure-projection-ack-lost"
      is lost "frontier" (int 8)
      endsWith lost "record_types" [String "ActivityFailed", String "FiringFailed"]
      are lost [("projection_ack_losses", int 1), ("worker_failures", int 1)]
      timeline' <- crashAndRestart timeline "joined_failure_projection_committed_ack_lost"
      recovered <-
        Timeline.runUntil timeline' "joined-failure-projection-ack-recovered" (\o -> pyEq (memberOf "drive_calls" o) (int 3))
      is recovered "frontier" (int 8)
      same recovered lost "record_types"
      same recovered lost "transaction_attempts"
      Timeline.finish timeline' Quarantined

-- ---------------------------------------------------------------------------
-- Reset, cancellation and close

-- | open the scope, deliver into it, wait for the pending Activity, and
-- claim it.
claimDraftActivity :: Timeline -> Text -> Bool -> Story Observation
claimDraftActivity timeline readyName observeClaim = do
  void (Timeline.command timeline "scope.open" draft)
  void (Timeline.command timeline "source.deliver" (Object [("identity", String "draft-input-3"), ("scope", String "draft"), ("value", int 3)]))
  ready <- Timeline.runUntil timeline readyName (\o -> pyEq (memberOf "durable_tasks" o) (task 2 "pending"))
  is ready "frontier" (int 11)
  if observeClaim
    then do
      is ready "prepare_calls" (int 1)
      void (Timeline.command timeline "worker.claim" empty)
      claimed <- Timeline.observe timeline readyName
      are claimed [("durable_tasks", task 2 "running"), ("worker_claims", int 1)]
      pure claimed
    else do
      void (Timeline.command timeline "worker.claim" empty)
      pure ready

-- | Complete the still-live Worker and wait for its projection.
completeLiveWorker :: Timeline -> Text -> Story Observation
completeLiveWorker timeline name = do
  void (Timeline.command timeline "worker.complete" empty)
  completed <- Timeline.runUntil timeline name (\o -> countRecord "FiringCompleted" o == 2)
  endsWith completed "record_types" (map String ["ActivityCompleted", "TokensProduced", "FiringCompleted"])
  is completed "durable_tasks" (task 2 "completed")
  pure completed

-- | Present the stale Worker's completion and check it was fenced.
fenceStaleWorker :: Timeline -> Text -> Observation -> [(Text, Json)] -> Story ()
fenceStaleWorker timeline name recovered expected = do
  void (Timeline.command timeline "worker.complete-stale" empty)
  fenced <- Timeline.observe timeline name
  same fenced recovered "durable_tasks"
  are fenced expected
  excludes fenced "record_types" "ActivityCompleted"

finishQuiescent :: Timeline -> Story ()
finishQuiescent timeline = do
  Timeline.beginFair timeline
  Timeline.finish timeline Quiescent

-- | @build_joined_reset_refusal_artifact(dsn)@.
buildResetRefusalArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildResetRefusalArtifact =
  build FResetRefusal cancellationWorldBudget C.resetRefusalAuthorityChecker "joined-reset-commit-refusal-world-v3" $ \_ -> do
    timeline <- World.timeline
    claimed <- claimDraftActivity timeline "joined-reset-ready" True
    Timeline.activateFault timeline (refuse "scope_reset" "dst joined scope reset commit refused")
    void (Timeline.command timeline "scope.reset" draft)
    refused <- Timeline.observe timeline "joined-reset-refused"
    is refused "frontier" (int 11)
    excludes refused "record_types" "ScopeReset"
    same refused claimed "durable_tasks"
    are
      refused
      [ ("lifecycle_attempts", Array [lc False "scope_reset" ["ScopeReset"]])
      , ("reset_refusals", int 1)
      , ("scope_resets", int 1)
      , ("cancellation_refusals", int 0)
      , ("status", String "poisoned")
      ]
    timeline' <- crashAndRestart timeline "joined_scope_reset_commit_refused"
    recovered <- Timeline.runUntil timeline' "joined-reset-recovered" (\o -> pyEq (memberOf "drive_calls" o) (int 2))
    is recovered "frontier" (int 11)
    same recovered refused "record_types"
    same recovered claimed "durable_tasks"
    is recovered "prepare_calls" (int 1)
    same recovered refused "lifecycle_attempts"
    completed <- completeLiveWorker timeline' "joined-reset-terminal-recovered"
    is completed "frontier" (int 14)
    are
      completed
      [ ("prepare_calls", int 1)
      , ("worker_claims", int 1)
      , ("worker_completions", int 1)
      , ("reset_refusals", int 1)
      ,
        ( "transaction_attempts"
        , Array
            [ tx True False acceptanceBatch
            , tx True False completionBatch
            , tx True True beginBatch
            , tx True False ["ActivityCompleted"]
            , tx True False completionBatch
            ]
        )
      ]
    same completed refused "lifecycle_attempts"
    finishQuiescent timeline'

-- | @build_joined_reset_ack_loss_artifact(dsn)@.
buildResetAckLossArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildResetAckLossArtifact =
  build FResetAckLoss cancellationWorldBudget C.acceptedResetAuthorityChecker "joined-reset-ack-loss-world-v3" $ \_ -> do
    timeline <- World.timeline
    claimed <- claimDraftActivity timeline "joined-reset-ack-ready" True
    Timeline.activateFault timeline (loseAck "scope_reset_committed" "dst joined scope reset acknowledgement lost")
    void (Timeline.command timeline "scope.reset" draft)
    lost <- Timeline.observe timeline "joined-reset-ack-lost"
    is lost "frontier" (int 12)
    endsWith lost "record_types" [String "ScopeReset"]
    same lost claimed "durable_tasks"
    are
      lost
      [ ("lifecycle_attempts", Array [lc True "scope_reset" ["ScopeReset"]])
      , ("reset_ack_losses", int 1)
      , ("scope_resets", int 1)
      , ("cancellation_refusals", int 0)
      , ("status", String "poisoned")
      ]
    timeline' <- crashAndRestart timeline "joined_scope_reset_committed_ack_lost"
    recovered <- Timeline.runUntil timeline' "joined-reset-ack-recovered" (\o -> pyEq (memberOf "durable_tasks" o) (task 2 "cancelled"))
    are
      recovered
      [ ("frontier", int 12)
      , ("prepare_calls", int 1)
      , ("lifecycle_attempts", Array [lc True "scope_reset" ["ScopeReset"], lc True "cancellation" []])
      ]
    fenceStaleWorker timeline' "joined-reset-ack-worker-fenced" recovered [("reset_ack_losses", int 1), ("stale_worker_refusals", int 1)]
    finishQuiescent timeline'

-- | @build_joined_cancellation_artifact(dsn)@.
buildCancellationArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildCancellationArtifact =
  build FCancellation cancellationWorldBudget C.cancellationAuthorityChecker "joined-cancellation-commit-refusal-world-v3" $ \_ -> do
    timeline <- World.timeline
    claimed <- claimDraftActivity timeline "joined-cancellation-ready" True
    Timeline.activateFault timeline (refuse "cancellation_committed" "dst joined cancellation commit refused")
    void (Timeline.command timeline "scope.reset" draft)
    refused <- Timeline.observe timeline "joined-cancellation-refused"
    is refused "frontier" (int 12)
    endsWith refused "record_types" [String "ScopeReset"]
    same refused claimed "durable_tasks"
    are
      refused
      [ ("lifecycle_attempts", Array [lc True "scope_reset" ["ScopeReset"], lc False "cancellation" []])
      , ("cancellation_refusals", int 1)
      , ("scope_resets", int 1)
      , ("status", String "poisoned")
      ]
    timeline' <- crashAndRestart timeline "joined_cancellation_commit_refused"
    recovered <-
      Timeline.runUntil timeline' "joined-cancellation-recovered" (\o -> pyEq (memberOf "durable_tasks" o) (task 2 "cancelled"))
    are
      recovered
      [ ("frontier", int 12)
      , ("prepare_calls", int 1)
      ,
        ( "lifecycle_attempts"
        , Array [lc True "scope_reset" ["ScopeReset"], lc False "cancellation" [], lc True "cancellation" []]
        )
      ]
    fenceStaleWorker timeline' "joined-late-worker-fenced" recovered [("stale_worker_refusals", int 1)]
    finishQuiescent timeline'

-- | @build_joined_cancellation_ack_loss_artifact(dsn)@.
buildCancellationAckLossArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildCancellationAckLossArtifact =
  build
    FCancellationAckLoss
    cancellationWorldBudget
    C.acceptedCancellationAuthorityChecker
    "joined-cancellation-ack-loss-world-v3"
    $ \_ -> do
      timeline <- World.timeline
      _ <- claimDraftActivity timeline "joined-cancellation-ack-ready" True
      Timeline.activateFault timeline (loseAck "cancellation_committed" "dst joined cancellation acknowledgement lost")
      void (Timeline.command timeline "scope.reset" draft)
      lost <- Timeline.observe timeline "joined-cancellation-ack-lost"
      is lost "frontier" (int 12)
      endsWith lost "record_types" [String "ScopeReset"]
      are
        lost
        [ ("durable_tasks", task 2 "cancelled")
        , ("lifecycle_attempts", Array [lc True "scope_reset" ["ScopeReset"], lc True "cancellation" []])
        , ("cancellation_ack_losses", int 1)
        , ("scope_resets", int 1)
        , ("status", String "poisoned")
        ]
      timeline' <- crashAndRestart timeline "joined_cancellation_committed_ack_lost"
      recovered <-
        Timeline.runUntil timeline' "joined-cancellation-ack-recovered" (\o -> pyEq (memberOf "drive_calls" o) (int 2))
      are recovered [("frontier", int 12), ("prepare_calls", int 1)]
      same recovered lost "durable_tasks"
      same recovered lost "lifecycle_attempts"
      fenceStaleWorker timeline' "joined-cancellation-ack-worker-fenced" recovered [("stale_worker_refusals", int 1)]
      finishQuiescent timeline'

-- | @build_joined_close_refusal_artifact(dsn)@.
buildCloseRefusalArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildCloseRefusalArtifact =
  build FCloseRefusal cancellationWorldBudget C.closeRefusalAuthorityChecker "joined-close-commit-refusal-world-v3" $ \_ -> do
    timeline <- World.timeline
    _ <- claimDraftActivity timeline "joined-close-ready" False
    Timeline.activateFault timeline (refuse "scope_close" "dst joined scope close commit refused")
    void (Timeline.command timeline "scope.close" draft)
    refused <- Timeline.observe timeline "joined-close-refused"
    is refused "frontier" (int 11)
    excludes refused "record_types" "ScopeClosed"
    are
      refused
      [ ("lifecycle_attempts", Array [lc False "scope_close" ["ScopeClosed"]])
      , ("close_refusals", int 1)
      , ("scope_closes", int 1)
      ]
    timeline' <- crashAndRestart timeline "joined_scope_close_commit_refused"
    recovered <- Timeline.runUntil timeline' "joined-close-recovered" (\o -> pyEq (memberOf "drive_calls" o) (int 2))
    same recovered refused "record_types"
    same recovered refused "durable_tasks"
    completed <- completeLiveWorker timeline' "joined-close-terminal-recovered"
    are completed [("worker_completions", int 1), ("close_refusals", int 1)]
    finishQuiescent timeline'

-- | @build_joined_close_ack_loss_artifact(dsn)@.
buildCloseAckLossArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildCloseAckLossArtifact =
  build FCloseAckLoss cancellationWorldBudget C.acceptedCloseAuthorityChecker "joined-close-ack-loss-world-v3" $ \_ -> do
    timeline <- World.timeline
    _ <- claimDraftActivity timeline "joined-close-ack-ready" False
    Timeline.activateFault timeline (loseAck "scope_close_committed" "dst joined scope close acknowledgement lost")
    void (Timeline.command timeline "scope.close" draft)
    lost <- Timeline.observe timeline "joined-close-ack-lost"
    is lost "frontier" (int 12)
    endsWith lost "record_types" [String "ScopeClosed"]
    are
      lost
      [ ("lifecycle_attempts", Array [lc True "scope_close" ["ScopeClosed"]])
      , ("close_ack_losses", int 1)
      , ("scope_closes", int 1)
      , ("status", String "poisoned")
      ]
    timeline' <- crashAndRestart timeline "joined_scope_close_committed_ack_lost"
    recovered <-
      Timeline.runUntil timeline' "joined-close-ack-recovered" (\o -> pyEq (memberOf "durable_tasks" o) (task 2 "cancelled"))
    are
      recovered
      [ ("frontier", int 12)
      , ("lifecycle_attempts", Array [lc True "scope_close" ["ScopeClosed"], lc True "cancellation" []])
      ]
    fenceStaleWorker timeline' "joined-close-ack-worker-fenced" recovered [("close_ack_losses", int 1), ("stale_worker_refusals", int 1)]
    finishQuiescent timeline'

-- ---------------------------------------------------------------------------
-- Open

draftGeneration :: Json
draftGeneration = Array [Object [("generation", int 1), ("name", String "draft")]]

-- | @build_joined_open_refusal_artifact(dsn)@.
buildOpenRefusalArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildOpenRefusalArtifact =
  build FOpenRefusal worldBudget C.openAuthorityChecker "joined-open-commit-refusal-world-v3" $ \_ -> do
    timeline <- World.timeline
    Timeline.activateFault timeline (refuse "scope_open" "dst joined scope open commit refused")
    refusedCommand <- Timeline.command timeline "scope.open" draft
    disposed refusedCommand RefusedExpected
    refused <- Timeline.observe timeline "joined-open-refused"
    are
      refused
      [ ("frontier", int 2)
      , ("canonical_scopes", Array [])
      , ("lifecycle_attempts", Array [lc False "scope_open" ["ScopeOpened"]])
      ]
    ensure (memberOf "active_scopes" refused == Null) "refused active scopes"
    timeline' <- crashAndRestart timeline "joined_scope_open_commit_refused"
    absent <- Timeline.observe timeline' "joined-open-absent"
    are absent [("frontier", int 2), ("canonical_scopes", Array []), ("active_scopes", Object [])]
    acceptedCommand <- Timeline.command timeline' "scope.open" draft
    disposed acceptedCommand Applied
    recovered <- Timeline.observe timeline' "joined-open-recovered"
    are
      recovered
      [ ("frontier", int 3)
      , ("canonical_scopes", draftGeneration)
      , ("active_scopes", Object [("draft", int 1)])
      ]
    endsWith recovered "lifecycle_attempts" [lc True "scope_open" ["ScopeOpened"]]
    Timeline.finish timeline' ExternalWait

-- | @build_joined_open_ack_loss_artifact(dsn)@.
buildOpenAckLossArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildOpenAckLossArtifact =
  build FOpenAckLoss worldBudget C.openAuthorityChecker "joined-open-ack-loss-world-v3" $ \_ -> do
    timeline <- World.timeline
    Timeline.activateFault timeline (loseAck "scope_open_committed" "dst joined scope open acknowledgement lost")
    lostCommand <- Timeline.command timeline "scope.open" draft
    disposed lostCommand RefusedExpected
    lost <- Timeline.observe timeline "joined-open-ack-lost"
    are
      lost
      [ ("frontier", int 3)
      , ("canonical_scopes", draftGeneration)
      , ("lifecycle_attempts", Array [lc True "scope_open" ["ScopeOpened"]])
      ]
    ensure (memberOf "active_scopes" lost == Null) "lost active scopes"
    timeline' <- crashAndRestart timeline "joined_scope_open_committed_ack_lost"
    recovered <- Timeline.observe timeline' "joined-open-ack-recovered"
    is recovered "frontier" (int 3)
    same recovered lost "canonical_scopes"
    are recovered [("active_scopes", Object [("draft", int 1)]), ("scope_opens", int 1), ("open_ack_losses", int 1)]
    Timeline.finish timeline' ExternalWait

-- ---------------------------------------------------------------------------
-- Scoped drops and quarantines

staleDelivery, futureDelivery :: Json
staleDelivery = Object [("identity", String "stale-draft-3"), ("scope_generation", int 1), ("value", int 3)]
futureDelivery = Object [("identity", String "future-draft-3"), ("scope_generation", int 2), ("value", int 3)]

lastDisposition :: Observation -> Json
lastDisposition o = case reverse (listOf (memberOf "scoped_delivery_attempts" o)) of
  attempt : _ -> atKey "disposition" attempt
  [] -> Null

-- | The refusal story shared by the stale drop and the future quarantine.
scopedRefusalStory :: Bool -> Story ()
scopedRefusalStory quarantine = do
  let (noun, target, message, command, delivery, canonicalKey, counter, recordName, frontier, canonical)
        | quarantine =
            ( "quarantine" :: Text
            , "scoped_delivery_quarantined"
            , "dst joined scoped delivery quarantine commit refused"
            , "source.deliver-future"
            , futureDelivery
            , "canonical_quarantines"
            , "scoped_quarantine_refusals"
            , "ScopedDeliveryQuarantined"
            , 3
            , scopedCanonical "future-draft-3" 2
            )
        | otherwise =
            ( "drop"
            , "scoped_delivery_dropped"
            , "dst joined scoped delivery drop commit refused"
            , "source.deliver-stale"
            , staleDelivery
            , "canonical_drops"
            , "scoped_drop_refusals"
            , "ScopedDeliveryDropped"
            , 4
            , scopedCanonical "stale-draft-3" 1
            )
      name suffix = "joined-scoped-" <> noun <> "-" <> suffix
  timeline <- World.timeline
  void (Timeline.command timeline "scope.open" draft)
  if quarantine then pure () else void (Timeline.command timeline "scope.reset" draft)
  Timeline.activateFault timeline (refuse target message)
  void (Timeline.command timeline command delivery)
  refused <- Timeline.observe timeline (name "refused")
  are
    refused
    [ ("frontier", int frontier)
    , (canonicalKey, Array [])
    , (counter, int 1)
    , ("transaction_attempts", Array [tx False False [recordName]])
    ]
  timeline' <- crashAndRestart timeline ("joined_scoped_" <> noun <> "_commit_refused")
  recovered <- Timeline.observe timeline' (name "recovered")
  is recovered canonicalKey (Array [])
  same recovered refused "record_types"
  void (Timeline.command timeline' command delivery)
  accepted <- Timeline.observe timeline' (name "recovered")
  are accepted [("frontier", int (frontier + 1)), (canonicalKey, canonical)]
  endsWith accepted "transaction_attempts" [tx True False [recordName]]
  void (Timeline.command timeline' command delivery)
  redelivered <- Timeline.observe timeline' (name "redelivered")
  same redelivered accepted canonicalKey
  same redelivered accepted "transaction_attempts"
  ensure (lastDisposition redelivered == String (actionDispositionText Idempotent)) "redelivered idempotent"
  Timeline.finish timeline' ExternalWait

-- | The acknowledgement-loss story shared by the drop and the quarantine.
scopedAckLossStory :: Bool -> Story ()
scopedAckLossStory quarantine = do
  let (noun, target, message, command, delivery, canonicalKey, counter, recordName, frontier)
        | quarantine =
            ( "quarantine" :: Text
            , "scoped_delivery_quarantined_committed"
            , "dst joined scoped delivery quarantine acknowledgement lost"
            , "source.deliver-future"
            , futureDelivery
            , "canonical_quarantines"
            , "scoped_quarantine_ack_losses"
            , "ScopedDeliveryQuarantined"
            , 4
            )
        | otherwise =
            ( "drop"
            , "scoped_delivery_dropped_committed"
            , "dst joined scoped delivery drop acknowledgement lost"
            , "source.deliver-stale"
            , staleDelivery
            , "canonical_drops"
            , "scoped_drop_ack_losses"
            , "ScopedDeliveryDropped"
            , 5
            )
      name suffix = "joined-scoped-" <> noun <> "-" <> suffix
  timeline <- World.timeline
  void (Timeline.command timeline "scope.open" draft)
  if quarantine then pure () else void (Timeline.command timeline "scope.reset" draft)
  Timeline.activateFault timeline (loseAck target message)
  void (Timeline.command timeline command delivery)
  lost <- Timeline.observe timeline (name "ack-lost")
  is lost "frontier" (int frontier)
  endsWith lost "record_types" [String recordName]
  are lost [(counter, int 1), ("transaction_attempts", Array [tx True False [recordName]])]
  timeline' <- crashAndRestart timeline ("joined_scoped_" <> noun <> "_committed_ack_lost")
  recovered <- Timeline.observe timeline' (name "ack-recovered")
  same recovered lost canonicalKey
  same recovered lost "record_types"
  void (Timeline.command timeline' command delivery)
  redelivered <- Timeline.observe timeline' (name "ack-recovered")
  same redelivered lost canonicalKey
  same redelivered lost "transaction_attempts"
  ensure (lastDisposition redelivered == String (actionDispositionText Idempotent)) "redelivered idempotent"
  Timeline.finish timeline' ExternalWait

scopedCanonical :: Text -> Integer -> Json
scopedCanonical identity generation =
  Array
    [ Object
        [ ("identity", String identity)
        , ("scope_generation", int generation)
        , ("scope_name", String "draft")
        , ("source", String "source")
        , ("value", int 3)
        ]
    ]

buildScopedDropRefusalArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildScopedDropRefusalArtifact =
  build FScopedDropRefusal worldBudget C.scopedDropAuthorityChecker "joined-scoped-drop-commit-refusal-world-v3" $
    const (scopedRefusalStory False)

buildScopedDropAckLossArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildScopedDropAckLossArtifact =
  build FScopedDropAckLoss worldBudget C.acceptedScopedDropAuthorityChecker "joined-scoped-drop-ack-loss-world-v3" $
    const (scopedAckLossStory False)

buildScopedQuarantineRefusalArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildScopedQuarantineRefusalArtifact =
  build
    FScopedQuarantineRefusal
    worldBudget
    C.scopedQuarantineAuthorityChecker
    "joined-scoped-quarantine-commit-refusal-world-v3"
    (const (scopedRefusalStory True))

buildScopedQuarantineAckLossArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildScopedQuarantineAckLossArtifact =
  build
    FScopedQuarantineAckLoss
    worldBudget
    C.acceptedScopedQuarantineAuthorityChecker
    "joined-scoped-quarantine-ack-loss-world-v3"
    (const (scopedAckLossStory True))

-- ---------------------------------------------------------------------------
-- joined_registration_world.py

registrationTail :: [Json]
registrationTail = map String ["TokensProduced", "DeliveryRegistrationClosed", "DeliveryRegistrationOpened", "FiringCompleted"]

registration :: Text -> Text -> Json -> Json
registration key kind occurrence =
  Object [("key", String key), ("kind", String kind), ("occurrence", occurrence), ("source", String "source")]

armed :: [Text] -> Json
armed keys = Array [Object [("key", String key), ("source", String "source")] | key <- keys]

-- | @build_joined_registration_projection_refusal_artifact(dsn)@.
buildRegistrationRefusalArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildRegistrationRefusalArtifact =
  build
    FRegistrationRefusal
    worldBudget
    C.registrationProjectionAuthorityChecker
    "joined-registration-projection-commit-refusal-world-v3"
    $ \_ -> do
      timeline <- World.timeline
      settle timeline False
      Timeline.activateFault timeline (refuse "projection_committed" "dst joined registration projection commit refused")
      void (Timeline.command timeline "engine.drive" empty)
      refused <- Timeline.observe timeline "joined-registration-projection-refused"
      is refused "frontier" (int 8)
      endsWith refused "record_types" [String "ActivityCompleted"]
      are
        refused
        [ ("canonical_registrations", Array [registration "default" "opened" Null])
        , ("projection_refusals", int 1)
        , ("worker_completions", int 1)
        ]
      ensure (memberOf "engine_armed" refused == Null) "refused engine armed"
      timeline' <- crashAndRestart timeline "joined_registration_projection_commit_refused"
      recovered <-
        Timeline.runUntil timeline' "joined-registration-projection-recovered" (\o -> pyEq (memberOf "engine_armed" o) (armed ["replacement"]))
      is recovered "frontier" (int 12)
      endsWith recovered "record_types" registrationTail
      are
        recovered
        [
          ( "canonical_registrations"
          , Array
              [ registration "default" "opened" Null
              , registration "default" "closed" (int 1)
              , registration "replacement" "opened" (int 1)
              ]
          )
        , ("status", String "awaiting")
        ]
      Timeline.finish timeline' ExternalWait

-- | @build_joined_registration_projection_ack_loss_artifact(dsn)@.
buildRegistrationAckLossArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildRegistrationAckLossArtifact =
  build
    FRegistrationAckLoss
    worldBudget
    C.registrationProjectionAuthorityChecker
    "joined-registration-projection-ack-loss-world-v3"
    $ \_ -> do
      timeline <- World.timeline
      settle timeline False
      Timeline.activateFault timeline (loseAck "projection_committed" "dst joined registration projection acknowledgement lost")
      void (Timeline.command timeline "engine.drive" empty)
      lost <- Timeline.observe timeline "joined-registration-projection-ack-lost"
      is lost "frontier" (int 12)
      endsWith lost "record_types" registrationTail
      ensure (memberOf "engine_armed" lost == Null) "lost engine armed"
      are lost [("projection_ack_losses", int 1), ("worker_completions", int 1)]
      timeline' <- crashAndRestart timeline "joined_registration_projection_committed_ack_lost"
      recovered <-
        Timeline.runUntil
          timeline'
          "joined-registration-projection-ack-recovered"
          (\o -> pyEq (memberOf "drive_calls" o) (int 3))
      is recovered "frontier" (int 12)
      forM_ ["record_types", "canonical_registrations"] (same recovered lost)
      are recovered [("engine_armed", armed ["replacement"]), ("status", String "awaiting")]
      ensure (length (listOf (memberOf "transaction_attempts" recovered)) == 3) "three transactions"
      Timeline.finish timeline' ExternalWait

-- ---------------------------------------------------------------------------
-- joined_seal_world.py

-- | @_prepare_two_registrations(timeline)@.
prepareTwoRegistrations :: Timeline -> Story ()
prepareTwoRegistrations timeline = do
  settle timeline False
  void (Timeline.command timeline "engine.drive" empty)
  ready <- Timeline.observe timeline "joined-seal-ready"
  are ready [("engine_armed", armed ["default", "subscription"]), ("status", String "awaiting")]

-- | @build_joined_seal_refusal_artifact(dsn)@.
buildSealRefusalArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildSealRefusalArtifact =
  build FSealRefusal worldBudget C.sealAuthorityChecker "joined-seal-commit-refusal-world-v3" $ \_ -> do
    timeline <- World.timeline
    prepareTwoRegistrations timeline
    Timeline.activateFault timeline (refuse "source_sealed" "dst joined source seal commit refused")
    refusedResult <- Timeline.command timeline "source.seal" empty
    disposed refusedResult RefusedExpected
    refused <- Timeline.observe timeline "joined-seal-refused"
    is refused "frontier" (int 11)
    endsWith refused "canonical_registrations" [registration "subscription" "opened" (int 1)]
    ensure (memberOf "engine_armed" refused == Null) "refused engine armed"
    are refused [("seal_calls", int 1), ("seal_refusals", int 1)]
    timeline' <- crashAndRestart timeline "joined_source_seal_commit_refused"
    reloaded <-
      Timeline.runUntil timeline' "joined-seal-reloaded" (\o -> pyEq (memberOf "engine_armed" o) (armed ["default", "subscription"]))
    is reloaded "status" (String "awaiting")
    void (Timeline.command timeline' "source.seal" empty)
    recovered <- Timeline.observe timeline' "joined-seal-recovered"
    are recovered [("frontier", int 13), ("engine_armed", Array []), ("seal_calls", int 2), ("status", String "terminated")]
    endsWith recovered "record_types" [String "DeliveryRegistrationClosed", String "DeliveryRegistrationClosed"]
    Timeline.finish timeline' Converged

-- | @build_joined_seal_ack_loss_artifact(dsn)@.
buildSealAckLossArtifact :: ByteString -> IO (Either DstFailure AnyArtifact)
buildSealAckLossArtifact =
  build FSealAckLoss worldBudget C.sealAuthorityChecker "joined-seal-ack-loss-world-v3" $ \_ -> do
    timeline <- World.timeline
    prepareTwoRegistrations timeline
    Timeline.activateFault timeline (loseAck "source_sealed_committed" "dst joined source seal acknowledgement lost")
    lostResult <- Timeline.command timeline "source.seal" empty
    disposed lostResult RefusedExpected
    lost <- Timeline.observe timeline "joined-seal-ack-lost"
    is lost "frontier" (int 13)
    ensure (memberOf "engine_armed" lost == Null) "lost engine armed"
    are lost [("seal_ack_losses", int 1), ("seal_calls", int 1), ("seal_refusals", int 0)]
    timeline' <- crashAndRestart timeline "joined_source_seal_committed_ack_lost"
    recovered <- Timeline.runUntil timeline' "joined-seal-ack-recovered" (\o -> pyEq (memberOf "engine_armed" o) (Array []))
    is recovered "frontier" (int 13)
    forM_ ["canonical_registrations", "lifecycle_attempts"] (same recovered lost)
    are recovered [("seal_calls", int 1), ("status", String "terminated")]
    Timeline.finish timeline' Converged
