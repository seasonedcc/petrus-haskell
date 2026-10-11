{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Shared plumbing of the joined History/Dispatch transaction-fault worlds
-- (the reference's @tests/dst/joined_*world.py@).
--
-- * 'FaultConnection' and 'faultSession': the reference's
--   @JoinedFaultConnection@, a provider connection that records the
--   semantic record types inserted inside the current transaction, notes a
--   task spawn or a task cancellation, and may refuse the commit (before
--   the delegate commits) or lose its acknowledgement (after it commits)
--   for exactly one armed boundary. The reference wraps the psycopg
--   connection's @execute@/@commit@/@rollback@; here the same cuts are the
--   'AbsurdSession' seams: the Dispatch statements ('Session.run'), the
--   History store's batches ('observeHistory'), and the transaction's fate
--   ('commit', 'rollback').
-- * Probes: the durable PostgreSQL facts every observation reads through a
--   fresh autocommit connection.
-- * Python value semantics for the checkers ('pyEq' and friends): the
--   reference compares decoded JSON with Python's @==@, where dict member
--   order is irrelevant and @True == 1@.
module Petrus.Testing.Dst.Joined.Support
  ( -- * Faults
    Arm (..)
  , armedMessage
  , armCounter
  , FaultConnection (..)
  , newFaultConnection
  , armFault
  , faultSession
    -- * Probes
  , withProbe
  , probeRecords
  , probeTasks
  , probeFrontier
    -- * Python value semantics
  , pyEq
  , pyIn
  , pyCount
  , pyNum
  , pyLe
  , pyLt
  , listOf
  , countName
  , object
  , mergeObject
  , strs
  , isPyObject
  , payloadAbsent
  ) where

import Control.Exception (bracket, finally, throwIO)
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.IORef
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Engine.Absurd (AbsurdSession (..))
import Petrus.HistoryStore.Postgres (loadPostgresHistory)
import Petrus.Impetus.History.Records (Record, recordName)
import Petrus.Impetus.HistoryStore (HistoryStore (..))
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch.Absurd (Session (..))
import Petrus.Postgres (Connection, quoteIdentifier, sql, sqlSource, textParam)
import Petrus.Postgres qualified as Pg
import Petrus.Testing.Dst.Engine.Common (PyException (..), strs)

-- ---------------------------------------------------------------------------
-- Faults

-- | One armable boundary of @JoinedFaultConnection@.
data Arm
  = CommitRefusal
  | DispatchRefusal
  | DeliveryRefusal
  | DeliveryAckLoss
  | ScopedDropRefusal
  | ScopedDropAckLoss
  | ScopedQuarantineRefusal
  | ScopedQuarantineAckLoss
  | TerminalRefusal
  | ProjectionRefusal
  | ProjectionAckLoss
  | CommitAckLoss
  | TerminalAckLoss
  | ResetRefusal
  | ResetAckLoss
  | CloseRefusal
  | CloseAckLoss
  | OpenRefusal
  | OpenAckLoss
  | SealRefusal
  | SealAckLoss
  | CancellationRefusal
  | CancellationAckLoss
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The reference's @RuntimeError@ when a boundary is armed twice.
armedMessage :: Arm -> Text
armedMessage = \case
  CommitRefusal -> "joined commit refusal is already armed"
  DispatchRefusal -> "joined Dispatch refusal is already armed"
  DeliveryRefusal -> "joined delivery refusal is already armed"
  DeliveryAckLoss -> "joined delivery acknowledgement loss is already armed"
  ScopedDropRefusal -> "joined scoped-drop refusal is already armed"
  ScopedDropAckLoss -> "joined scoped-drop acknowledgement loss is already armed"
  ScopedQuarantineRefusal -> "joined scoped-quarantine refusal is already armed"
  ScopedQuarantineAckLoss -> "joined scoped-quarantine acknowledgement loss is already armed"
  TerminalRefusal -> "joined terminal refusal is already armed"
  ProjectionRefusal -> "joined projection refusal is already armed"
  ProjectionAckLoss -> "joined projection acknowledgement loss is already armed"
  CommitAckLoss -> "joined commit acknowledgement loss is already armed"
  TerminalAckLoss -> "joined terminal acknowledgement loss is already armed"
  ResetRefusal -> "joined scope-reset refusal is already armed"
  ResetAckLoss -> "joined scope-reset acknowledgement loss is already armed"
  CloseRefusal -> "joined scope-close refusal is already armed"
  CloseAckLoss -> "joined scope-close acknowledgement loss is already armed"
  OpenRefusal -> "joined scope-open refusal is already armed"
  OpenAckLoss -> "joined scope-open acknowledgement loss is already armed"
  SealRefusal -> "joined source-seal refusal is already armed"
  SealAckLoss -> "joined source-seal acknowledgement loss is already armed"
  CancellationRefusal -> "joined cancellation refusal is already armed"
  CancellationAckLoss -> "joined cancellation acknowledgement loss is already armed"

-- | The profile counter the boundary's callback bumps when it fires.
armCounter :: Arm -> Text
armCounter = \case
  CommitRefusal -> "commit_refusals"
  DispatchRefusal -> "dispatch_refusals"
  DeliveryRefusal -> "delivery_refusals"
  DeliveryAckLoss -> "delivery_ack_losses"
  ScopedDropRefusal -> "scoped_drop_refusals"
  ScopedDropAckLoss -> "scoped_drop_ack_losses"
  ScopedQuarantineRefusal -> "scoped_quarantine_refusals"
  ScopedQuarantineAckLoss -> "scoped_quarantine_ack_losses"
  TerminalRefusal -> "terminal_refusals"
  ProjectionRefusal -> "projection_refusals"
  ProjectionAckLoss -> "projection_ack_losses"
  CommitAckLoss -> "commit_ack_losses"
  TerminalAckLoss -> "terminal_ack_losses"
  ResetRefusal -> "reset_refusals"
  ResetAckLoss -> "reset_ack_losses"
  CloseRefusal -> "close_refusals"
  CloseAckLoss -> "close_ack_losses"
  OpenRefusal -> "open_refusals"
  OpenAckLoss -> "open_ack_losses"
  SealRefusal -> "seal_refusals"
  SealAckLoss -> "seal_ack_losses"
  CancellationRefusal -> "cancellation_refusals"
  CancellationAckLoss -> "cancellation_ack_losses"

-- | @JoinedFaultConnection@'s per-connection transaction facts, plus the
-- profile-owned lists and counters it reports into.
data FaultConnection = FaultConnection
  { recordTypes :: IORef [Text]
  , dispatchAttempted :: IORef Bool
  , cancellationAttempted :: IORef Bool
  , armed :: IORef (Map Arm Text)
  , trackScopeOpen :: Bool
  , attempts :: IORef [Json]
  -- ^ The profile's @transaction_attempts@.
  , lifecycleAttempts :: IORef [Json]
  -- ^ The profile's @lifecycle_attempts@.
  , bump :: Text -> IO ()
  -- ^ Increment one profile counter.
  }

newFaultConnection :: Bool -> IORef [Json] -> IORef [Json] -> (Text -> IO ()) -> IO FaultConnection
newFaultConnection trackScopeOpen attempts lifecycleAttempts bump = do
  recordTypes <- newIORef []
  dispatchAttempted <- newIORef False
  cancellationAttempted <- newIORef False
  armed <- newIORef Map.empty
  pure FaultConnection {recordTypes, dispatchAttempted, cancellationAttempted, armed, trackScopeOpen, attempts, lifecycleAttempts, bump}

-- | @refuse_*@ / @lose_*@: arm one boundary with its message.
armFault :: FaultConnection -> Arm -> Text -> IO ()
armFault fc arm message = do
  current <- readIORef fc.armed
  when (Map.member arm current) $ throwIO (PyException "RuntimeError" (armedMessage arm))
  writeIORef fc.armed (Map.insert arm message current)

-- | Disarm and return one boundary's message.
takeArm :: FaultConnection -> Arm -> IO (Maybe Text)
takeArm fc arm = do
  current <- readIORef fc.armed
  case Map.lookup arm current of
    Nothing -> pure Nothing
    Just message -> do
      writeIORef fc.armed (Map.delete arm current)
      pure (Just message)

-- | @_attempt(accepted)@.
transactionAttempt :: FaultConnection -> Bool -> IO Json
transactionAttempt fc accepted = do
  types <- readIORef fc.recordTypes
  spawned <- readIORef fc.dispatchAttempted
  pure (Object [("accepted", Bool accepted), ("dispatch_attempted", Bool spawned), ("record_types", strs types)])

-- | @_lifecycle_attempt(accepted, phase)@.
lifecycleAttempt :: FaultConnection -> Bool -> Text -> IO Json
lifecycleAttempt fc accepted phase = do
  types <- readIORef fc.recordTypes
  pure (Object [("accepted", Bool accepted), ("phase", String phase), ("record_types", strs types)])

appendTo :: IORef [Json] -> Json -> IO ()
appendTo ref value = modifyIORef' ref (<> [value])

-- | @_clear_transaction()@.
clearTransaction :: FaultConnection -> IO ()
clearTransaction fc = do
  writeIORef fc.recordTypes []
  writeIORef fc.dispatchAttempted False
  writeIORef fc.cancellationAttempted False

-- | Where a refused boundary reports its attempt.
data Report = TransactionReport | LifecycleReport Text

-- | Wrap a session's statements, History batches, and transaction fate
-- exactly as @JoinedFaultConnection@ wraps @execute@, @commit@, and
-- @rollback@.
faultSession :: FaultConnection -> AbsurdSession -> AbsurdSession
faultSession fc session =
  session
    { commit = faultCommit fc session.commit
    , rollback = session.rollback `finally` clearTransaction fc
    , dispatchSession = session.dispatchSession {run = faultRun fc session.dispatchSession.run}
    , observeHistory = recordingHistory fc . session.observeHistory
    }

-- | @execute@: a spawn notes the attempt and may be refused before it
-- reaches the server; a cancellation notes the attempt.
faultRun :: FaultConnection -> (Pg.Sql -> [Pg.Param] -> IO a) -> Pg.Sql -> [Pg.Param] -> IO a
faultRun fc delegate statement params = do
  let source = sqlSource statement
  when ("SELECT task_id, run_id, attempt, created FROM absurd.spawn_task" `T.isPrefixOf` source) $ do
    writeIORef fc.dispatchAttempted True
    takeArm fc DispatchRefusal >>= \case
      Nothing -> pure ()
      Just message -> do
        transactionAttempt fc False >>= appendTo fc.attempts
        fc.bump (armCounter DispatchRefusal)
        throwIO (PyException "OSError" message)
  when ("SELECT absurd.cancel_task" `T.isPrefixOf` source) $
    writeIORef fc.cancellationAttempted True
  delegate statement params

-- | The @INSERT INTO impetus.semantic_events@ observation: every record of
-- an accepted batch, in order.
recordingHistory :: FaultConnection -> HistoryStore -> HistoryStore
recordingHistory fc store =
  store
    { extend = \batch -> do
        store.extend batch
        modifyIORef' fc.recordTypes (<> map recordName batch)
    }

-- | @commit()@ in the reference's exact order: refusals before the
-- delegate commit, then accepted attempts, the clear, and acknowledgement
-- losses.
faultCommit :: FaultConnection -> IO () -> IO ()
faultCommit fc delegate = do
  types <- readIORef fc.recordTypes
  cancellation <- readIORef fc.cancellationAttempted
  let has name = name `elem` types
      sourceDelivery = has "ExternalEventDelivered"
      scopedDrop = has "ScopedDeliveryDropped"
      scopedQuarantine = has "ScopedDeliveryQuarantined"
      joinedBegin = has "ActivityRequested"
      activityTerminal = has "ActivityCompleted" || has "ActivityFailed"
      projectionCompleted = has "FiringCompleted" || has "FiringFailed"
      scopeReset = has "ScopeReset"
      scopeClose = has "ScopeClosed"
      scopeOpen = fc.trackScopeOpen && has "ScopeOpened"
      sourceSeal = not (null types) && all (== "DeliveryRegistrationClosed") types
      tracked =
        sourceDelivery
          || joinedBegin
          || scopedDrop
          || scopedQuarantine
          || any has ["ActivityCompleted", "ActivityFailed", "FiringCompleted", "FiringFailed"]
      refusals =
        [ (sourceDelivery, DeliveryRefusal, TransactionReport)
        , (scopedDrop, ScopedDropRefusal, TransactionReport)
        , (scopedQuarantine, ScopedQuarantineRefusal, TransactionReport)
        , (joinedBegin, CommitRefusal, TransactionReport)
        , (activityTerminal, TerminalRefusal, TransactionReport)
        , (projectionCompleted, ProjectionRefusal, TransactionReport)
        , (scopeReset, ResetRefusal, LifecycleReport "scope_reset")
        , (scopeClose, CloseRefusal, LifecycleReport "scope_close")
        , (scopeOpen, OpenRefusal, LifecycleReport "scope_open")
        , (sourceSeal, SealRefusal, LifecycleReport "source_seal")
        , (cancellation, CancellationRefusal, LifecycleReport "cancellation")
        ]
      phases =
        [ (scopeReset, "scope_reset")
        , (scopeClose, "scope_close")
        , (scopeOpen, "scope_open")
        , (sourceSeal, "source_seal")
        , (cancellation, "cancellation")
        ]
      losses =
        [ (sourceDelivery, DeliveryAckLoss)
        , (scopedDrop, ScopedDropAckLoss)
        , (scopedQuarantine, ScopedQuarantineAckLoss)
        , (joinedBegin, CommitAckLoss)
        , (activityTerminal, TerminalAckLoss)
        , (projectionCompleted, ProjectionAckLoss)
        , (scopeReset, ResetAckLoss)
        , (scopeClose, CloseAckLoss)
        , (scopeOpen, OpenAckLoss)
        , (sourceSeal, SealAckLoss)
        , (cancellation, CancellationAckLoss)
        ]
  current <- readIORef fc.armed
  case find (\(applies, arm, _) -> applies && Map.member arm current) refusals of
    Just (_, arm, report) -> do
      message <- maybe (pure "") pure =<< takeArm fc arm
      case report of
        TransactionReport -> transactionAttempt fc False >>= appendTo fc.attempts
        LifecycleReport phase -> lifecycleAttempt fc False phase >>= appendTo fc.lifecycleAttempts
      fc.bump (armCounter arm)
      throwIO (PyException "OSError" message)
    Nothing -> pure ()
  delegate
  when tracked $ transactionAttempt fc True >>= appendTo fc.attempts
  mapM_ (\(applies, phase) -> when applies (lifecycleAttempt fc True phase >>= appendTo fc.lifecycleAttempts)) phases
  clearTransaction fc
  afterCommit <- readIORef fc.armed
  case find (\(applies, arm) -> applies && Map.member arm afterCommit) losses of
    Just (_, arm) -> do
      message <- maybe (pure "") pure =<< takeArm fc arm
      fc.bump (armCounter arm)
      throwIO (PyException "OSError" message)
    Nothing -> pure ()

-- ---------------------------------------------------------------------------
-- Probes

-- | @with psycopg.connect(dsn, autocommit=True) as probe@.
withProbe :: ByteString -> (Connection -> IO a) -> IO a
withProbe dsn = bracket (Pg.connect dsn True) Pg.close

-- | @PostgresHistoryStore(probe, instance).records@.
probeRecords :: Connection -> Text -> IO [Record]
probeRecords probe instanceId = toList <$> loadPostgresHistory probe instanceId

-- | @len(PostgresHistoryStore(probe, instance))@ on a fresh probe.
probeFrontier :: ByteString -> Text -> IO Integer
probeFrontier dsn instanceId = withProbe dsn $ \probe -> toInteger . length <$> probeRecords probe instanceId

-- | The queue's durable tasks: @[{idempotency, state}]@ ordered by key, or
-- @[]@ while the queue does not exist.
probeTasks :: Connection -> Text -> IO Json
probeTasks probe queue = do
  exists <- Pg.query probe (sql "SELECT 1 FROM absurd.list_queues() WHERE queue_name = %s") [textParam queue]
  if null exists
    then pure (Array [])
    else do
      rows <-
        Pg.query
          probe
          (sql ("SELECT idempotency_key, state FROM absurd." <> quoteIdentifier ("t_" <> queue) <> " ORDER BY idempotency_key"))
          []
      pure (Array (mapMaybe taskRow rows))
  where
    taskRow = \case
      [key, state] -> Just (Object [("idempotency", textOrNull key), ("state", textOrNull state)])
      _ -> Nothing
    textOrNull = maybe Null (String . TE.decodeUtf8Lenient)

-- ---------------------------------------------------------------------------
-- Python value semantics

-- | Python @==@ over decoded JSON: dict member order is irrelevant, and
-- @bool@ is an @int@ (@True == 1@, @3 == 3.0@).
pyEq :: Json -> Json -> Bool
pyEq a b = case (a, b) of
  (Null, Null) -> True
  (String x, String y) -> x == y
  (Array xs, Array ys) -> length xs == length ys && and (zipWith pyEq xs ys)
  (Object xs, Object ys) ->
    length xs == length ys && all (\(k, v) -> maybe False (pyEq v) (lookup k ys)) xs
  _ -> case (pyNum a, pyNum b) of
    (Just x, Just y) -> x == y
    _ -> False

-- | @x in candidates@.
pyIn :: Json -> [Json] -> Bool
pyIn x = any (pyEq x)

-- | @values.count(x)@.
pyCount :: Json -> [Json] -> Integer
pyCount x = toInteger . length . filter (pyEq x)

-- | A Python number (@bool@ counts as @int@).
pyNum :: Json -> Maybe Rational
pyNum = \case
  Bool True -> Just 1
  Bool False -> Just 0
  Int n -> Just (fromInteger n)
  Float d -> Just (toRational d)
  _ -> Nothing

-- | @a <= b@ over numbers; a non-number never satisfies the comparison
-- (the reference would raise @TypeError@ on such malformed evidence).
pyLe :: Json -> Json -> Bool
pyLe a b = case (pyNum a, pyNum b) of
  (Just x, Just y) -> x <= y
  _ -> False

pyLt :: Json -> Json -> Bool
pyLt a b = case (pyNum a, pyNum b) of
  (Just x, Just y) -> x < y
  _ -> False

-- | The items of a JSON list (@[]@ for anything else).
listOf :: Json -> [Json]
listOf = \case
  Array xs -> xs
  _ -> []

-- | @records.count(name)@.
countName :: Text -> [Json] -> Integer
countName name = pyCount (String name)

object :: [(Text, Json)] -> Json
object = Object

-- | @{**base, **extra}@: the extra members override.
mergeObject :: Json -> [(Text, Json)] -> Json
mergeObject base extra = case base of
  Object members -> Object ([(k, v) | (k, v) <- members, k `notElem` map fst extra] <> extra)
  _ -> Object extra

isPyObject :: Json -> Bool
isPyObject = \case
  Object _ -> True
  _ -> False

-- | @payload in (None, {})@.
payloadAbsent :: Json -> Bool
payloadAbsent payload = payload == Null || pyEq payload (Object [])
