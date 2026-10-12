-- | The Absurd Dispatch (@petrus.motus.dispatch.absurd@): the optional
-- durable Dispatch over Absurd 0.4.0 — hash-pinned, never forked.
--
-- Absurd sits entirely on the adapter side of the Activity invocation seam:
-- tasks, runs, claims, leases and retries are operational state, never
-- canonical truth. The authority stays the sole canonical writer; workers
-- never touch @impetus.semantic_events@.
--
-- = The joined transaction (D11)
--
-- 'AbsurdDispatch' runs on the authority's join-mode connection
-- (@autocommit=False@): the Engine's begin batch, @absurd.spawn_task@ and
-- the @pg_notify('impetus_dispatch', queue)@ doorbell ride one transaction
-- and commit or vanish together. The spawn is keyed on the occurrence
-- (@"{instance}:occurrence-{id}"@), so a redispatch after a crash never
-- double-enqueues, and the keyed lookup is the substrate half of K4's
-- lookup-first recovery: a live or terminal task is left alone (and
-- collected when terminal), a definitely absent one is respawned under the
-- same key, a never-started pending task on another route moves atomically
-- (guarded by @FOR UPDATE NOWAIT@), and anything ambiguous is refused.
--
-- = Workers
--
-- 'GuardedDispatch' is the worker-side door over Absurd custody, fenced by
-- the active run lease: every heartbeat and terminal report locks the run
-- row and checks the claimant, the run state and the lease deadline first.
-- 'AbsurdWorkerDispatch' adapts it to the provider-neutral
-- 'WorkerDispatch' surface, reconnecting one failed transport heartbeat
-- with the same claimant, and rings @impetus_results@ after each terminal
-- commit.
--
-- = Errors
--
-- The reference's @ValueError@ is 'DispatchError'; its @RuntimeError@ is
-- 'AbsurdError'; database failures surface as 'PostgresError'.
module Petrus.Motus.Dispatch.Absurd
  ( -- * The pin and the schema
    module Petrus.Motus.Dispatch.Absurd.Schema

    -- * Channels and names
  , dispatchChannel
  , resultsChannel
  , detailsCheckpoint
  , queuePattern
  , validateQueue
  , publicationKey

    -- * The task payload
  , encodeInvocation
  , decodeInvocation
  , canonicalJson
  , instanceFromKey

    -- * Failure reasons
  , failureReason
  , spellFailure
  , decodeFailure

    -- * Sessions
  , Session (..)
  , sessionOf

    -- * Guarded worker custody
  , GuardedDispatch (session, claimant)
  , guardedDispatch
  , ClaimedTask (..)
  , guardedClaim
  , guardedHeartbeat
  , TerminalReport (..)
  , guardedTerminal
  , latestDetails

    -- * Reconnecting heartbeats
  , ReconnectableGuardedDispatch
  , reconnectableGuardedDispatch
  , reconnectableConnection
  , reconnectableClaimant
  , reconnectableGuard
  , reconnectableClaim
  , reconnectableHeartbeat
  , reconnectableTerminal
  , reconnectableClose
  , reconnectOnce

    -- * The Worker-facing adapter
  , AbsurdWorkerDispatch (dsn, claimant)
  , workerQueues
  , AbsurdWorkerOptions (..)
  , defaultAbsurdWorkerOptions
  , openAbsurdWorkerDispatch
  , workerConnection
  , toWorkerDispatch
  , claim
  , heartbeat
  , complete
  , fail
  , wait
  , close

    -- * The Engine-facing Dispatch
  , AbsurdDispatch (instance')
  , defaultQueueOf
  , AbsurdDispatchOptions (..)
  , defaultAbsurdDispatchOptions
  , absurdDispatch
  , absurdDispatchOver
  , toDispatch
  , queueFor
  , dispatch
  , cancel
  , collect
  , waitForResults
  , dispatchedTask
  ) where

import Control.Exception (catch, onException, throwIO, try)
import Control.Monad (forM, forM_, unless, void, when)
import Data.ByteString (ByteString)
import Data.Char (isAsciiLower, isDigit)
import Data.IORef
import Data.Int (Int64)
import Data.List (nub, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Petrus.Activity hiding (ActivityExecutionContext (..))
import Petrus.Json
import Petrus.Motus.Dispatch
  ( ActivityAttempt
  , ActivityOutcome (..)
  , AttemptFailure (..)
  , CancellationDisposition (..)
  , CancellationInstruction
  , Dispatch (Dispatch)
  , WorkerDispatch (WorkerDispatch)
  , activityAttempt
  , dispatchError
  , dispositionText
  )
import Petrus.Motus.Dispatch qualified as Port
import Petrus.Motus.Dispatch.Absurd.Schema
import Petrus.Json.Python (pythonRepr, pythonStrRepr, uuid4)
import Petrus.Motus.PythonException (pythonException, pythonExceptionStr)
import Petrus.Motus.PythonException qualified as Python (PythonException (..))
import Petrus.Postgres
  ( Connection
  , ErrorClass (..)
  , Param
  , PostgresError (..)
  , Sql
  , autocommit
  , hasSqlState
  , intParam
  , isBroken
  , isClosed
  , jsonbParam
  , lockNotAvailable
  , nullParam
  , pollWithDoorbell
  , quoteIdentifier
  , sql
  , textArrayParam
  , textParam
  , timestamptzParam
  , waitForNotification
  )
import Petrus.Postgres qualified as Pg
import Petrus.Telemetry (TelemetryLogger, getLogger)
import Petrus.Telemetry qualified as Telemetry
import System.Posix.Process (getProcessID)
import Prelude hiding (fail)

-- ---------------------------------------------------------------------------
-- Channels and names

-- | The dispatch doorbell (authority to workers), rung inside the spawning
-- transaction; the payload is the queue.
dispatchChannel :: Text
dispatchChannel = "impetus_dispatch"

-- | The results doorbell (workers to authority), rung after a worker's
-- terminal commit; the payload is the queue.
resultsChannel :: Text
resultsChannel = "impetus_results"

-- | The checkpoint name the latest heartbeat details live under.
detailsCheckpoint :: Text
detailsCheckpoint = "__impetus_latest_activity_details_v1"

-- | The configured queue vocabulary, @^[a-z][a-z0-9_]{0,56}$@.
queuePattern :: Text
queuePattern = "^[a-z][a-z0-9_]{0,56}$"

-- | @validate_queue@: a configured queue name becomes a table suffix, so it
-- must match 'queuePattern' (with Python's @re.match@ semantics, where @$@
-- also matches before one final newline).
validateQueue :: Text -> Either Text Text
validateQueue queue
  | matches = Right queue
  | otherwise =
      Left
        ( "queue "
            <> pythonStrRepr queue
            <> " is invalid: a queue name must match "
            <> queuePattern
            <> " (it becomes the t_/r_/c_/e_/w_ table suffix)"
        )
  where
    body = fromMaybe queue (T.stripSuffix "\n" queue)
    matches = case T.uncons body of
      Just (initial, rest) ->
        isAsciiLower initial && T.length rest <= 56 && T.all (\c -> isAsciiLower c || isDigit c || c == '_') rest
      Nothing -> False

-- | The durable publication key of one occurrence: @"{instance}:occurrence-{n}"@.
publicationKey :: Text -> Int -> Text
publicationKey instanceId occurrence = instanceId <> ":occurrence-" <> showT occurrence

-- ---------------------------------------------------------------------------
-- The task payload

-- | @encode_invocation@: the invocation's wire spelling for the task
-- payload, field for field like the canonical @ActivityRequested@.
encodeInvocation :: ActivityInvocation -> Json
encodeInvocation = invocationJson

-- | @_canonical_json@: the deterministic, type-sensitive spelling used for
-- conflict judgments (sorted keys, compact, non-ASCII kept, non-finite
-- numbers refused).
canonicalJson :: Json -> Either Text Text
canonicalJson value = either (Left . T.pack . encodeErrorMessage) Right (canonicalText value)

-- | @decode_invocation@: the strict inverse of 'encodeInvocation'
-- ('invocationFromJson'). Every refusal starts with "task payload does not
-- decode as an activity invocation".
decodeInvocation :: Json -> Either Text ActivityInvocation
decodeInvocation payload = either (Left . ((rejection <> ": ") <>) . refusal) Right (invocationFromJson payload)
  where
    rejection = "task payload does not decode as an activity invocation"
    refusal problem = flip fromMaybe (invocationRefusal pythonRepr problem) $ case problem of
      InvocationFieldsNotExact ->
        "expected exactly the fields ['activity', 'correlation', 'idempotency', 'input', 'policy'], got " <> pythonRepr payload
      _ -> "policy must be exactly {'attempts': int, 'heartbeat_timeout': int}, got " <> pythonRepr (fromMaybe Null (lookupMember "policy" payload))

-- | @_instance_from_key@: the Petrus Instance a publication key scopes, if
-- the key is one (@"{instance}:occurrence-{n}"@, split at the last
-- separator, @n@ a canonical positive decimal). A missing or foreign key is
-- 'Nothing'; a malformed Petrus key is refused.
instanceFromKey :: Maybe Text -> Either Text (Maybe Text)
instanceFromKey = \case
  Nothing -> Right Nothing
  Just value -> case T.breakOnEnd separator value of
    (prefix, occurrence)
      | T.null prefix -> Right Nothing
      | otherwise ->
          let instanceId = T.dropEnd (T.length separator) prefix
           in if T.null instanceId
                || T.null occurrence
                || not (T.all isDigit occurrence)
                || T.all (== '0') occurrence
                || T.head occurrence == '0'
                then Left ("invalid Petrus Absurd publication identity " <> pythonStrRepr value)
                else Right (Just instanceId)
  where
    separator = ":occurrence-"

-- ---------------------------------------------------------------------------
-- Failure reasons

-- | The @failure_reason@ object a guarded failure stores.
failureReason :: ActivityFailure -> Json
failureReason failure =
  let f = failureFields failure
   in Object
        [ ("petrus_failure", Int 1)
        , ("name", String f.failureKind)
        , ("message", String f.failureError)
        , ("details", f.failureDetails)
        , ("retryable", Bool f.failureRetryable)
        , ("retry_after", maybe Null numberJson f.failureRetryAfter)
        ]

-- | @_spell_failure@: @"name: message"@ when the SDK shape is there (just
-- the name when the message is falsy), the raw JSON otherwise.
spellFailure :: Json -> Text
spellFailure reason = case reason of
  Object members | Just name <- lookup "name" members ->
    let message = fromMaybe Null (lookup "message" members)
     in if truthy message then strOf name <> ": " <> strOf message else strOf name
  _ -> either (const (pythonRepr reason)) TE.decodeUtf8 (dumps defaultDumps reason)
  where
    strOf = \case
      String s -> s
      other -> pythonRepr other

-- | @_decode_failure@: a guarded failure reason back into its
-- 'ActivityFailure'; any other reason as a plain failure spelling it.
decodeFailure :: Json -> Either Text ActivityFailure
decodeFailure reason = case lookupMember "petrus_failure" reason of
  Just marker | marker == Int 1 -> do
    let member key = fromMaybe Null (lookupMember key reason)
        text = \case
          String s -> s
          _ -> ""
    retryable <- case member "retryable" of
      Bool b -> Right b
      _ -> Left "ActivityFailure retryable must be bool"
    retryAfter <- case member "retry_after" of
      Null -> Right Nothing
      Bool _ -> Left "ActivityFailure retry_after must be a non-negative number or None"
      other -> maybe (Left "ActivityFailure retry_after must be a non-negative number or None") (Right . Just) (numberFromJson other)
    activityFailure
      ActivityFailureFields
        { failureError = text (member "message")
        , failureKind = text (member "name")
        , failureDetails = member "details"
        , failureRetryable = retryable
        , failureRetryAfter = retryAfter
        }
  _ -> simpleFailure (spellFailure reason)

truthy :: Json -> Bool
truthy = \case
  Null -> False
  Bool b -> b
  Int i -> i /= 0
  Float d -> d /= 0
  String s -> not (T.null s)
  Array xs -> not (null xs)
  Object ms -> not (null ms)

-- ---------------------------------------------------------------------------
-- Sessions

-- | The connection an adapter speaks through, with its statement, commit
-- and rollback doors. 'session' is the plain connection; tests wrap these
-- doors to inject failures at exact statements (the reference wraps the
-- connection object).
data Session = Session
  { connection :: Connection
  , run :: Sql -> [Param] -> IO [[Maybe ByteString]]
  -- ^ Run one statement and return its rows.
  , commit :: IO ()
  , rollback :: IO ()
  }

-- | The plain session over a connection.
sessionOf :: Connection -> Session
sessionOf connection =
  Session
    { connection
    , run = Pg.query connection
    , commit = Pg.commit connection
    , rollback = Pg.rollback connection
    }

-- | Run a statement and return its first row.
first :: Session -> Sql -> [Param] -> IO (Maybe [Maybe ByteString])
first s statement params =
  s.run statement params >>= \case
    row : _ -> pure (Just row)
    [] -> pure Nothing

-- | Run a statement for its effect.
run_ :: Session -> Sql -> [Param] -> IO ()
run_ s statement params = void (s.run statement params)

-- | On any exception: roll back (a rollback failure is swallowed, so the
-- original exception propagates), then rethrow.
rollingBack :: Session -> IO a -> IO a
rollingBack s action = action `onException` void (try @PostgresError s.rollback)

-- ---------------------------------------------------------------------------
-- Guarded worker custody

-- | The exclusive Worker-side door over Absurd custody (@GuardedDispatch@),
-- fenced by the active run lease. Every operation runs in its own
-- transaction on the session, committed on success and rolled back on any
-- failure.
data GuardedDispatch = GuardedDispatch
  { session :: Session
  , claimant :: Text
  }

-- | @GuardedDispatch(connection, claimant=...)@: refuses an autocommit
-- connection; a missing or empty claimant is a fresh UUID.
guardedDispatch :: Session -> Maybe Text -> IO GuardedDispatch
guardedDispatch s claimant' = do
  mode <- autocommit s.connection
  when mode $ dispatchError "GuardedDispatch requires autocommit=False for atomic guarded operations"
  name <- case claimant' of
    Just c | not (T.null c) -> pure c
    _ -> uuid4
  pure GuardedDispatch {session = s, claimant = name}

-- | One claimed task: @claim_task@'s row, plus the Petrus Instance its
-- publication key scopes.
data ClaimedTask = ClaimedTask
  { runId :: Text
  , taskId :: Text
  , attempt :: Int
  , taskName :: Text
  , params :: Json
  , petrusInstance :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | @claim(queue, timeout=...)@: claim at most one task, extend its lease to
-- the policy's heartbeat timeout, and read its latest heartbeat details
-- ('Null' when none were recorded), all in one committed transaction.
guardedClaim :: GuardedDispatch -> Text -> Int -> IO (Maybe (ClaimedTask, Json))
guardedClaim g queue timeout = do
  _ <- refuse (validateQueue queue)
  let s = g.session
  rollingBack s $ do
    row <- first s "SELECT * FROM absurd.claim_task(%s, %s, %s, 1)" [textParam queue, textParam g.claimant, int timeout]
    case row of
      Nothing -> s.commit >> pure Nothing
      Just columns -> do
        task <- case columns of
          Just run' : Just task' : Just attempt' : Just name : Just params' : _ -> do
            parsedParams <- refuse (jsonColumn params')
            attemptNumber <- intColumn attempt'
            pure
              ClaimedTask
                { runId = utf8 run'
                , taskId = utf8 task'
                , attempt = fromIntegral attemptNumber
                , taskName = utf8 name
                , params = parsedParams
                , petrusInstance = Nothing
                }
          _ -> throwIO (AbsurdError "absurd.claim_task returned an unexpected row")
        policyTimeout <- (.policy) <$> refuse (decodeInvocation task.params)
        identity <-
          first
            s
            (sql ("SELECT idempotency_key FROM absurd." <> quoteIdentifier ("t_" <> queue) <> " WHERE task_id=%s"))
            [textParam task.taskId]
        scope <- refuse (instanceFromKey (fmap utf8 =<< (headMay =<< identity)))
        run_ s "SELECT absurd.extend_claim(%s, %s, %s)" [textParam queue, textParam task.runId, integer (policyFields policyTimeout).heartbeatTimeout]
        details <-
          first
            s
            "SELECT state FROM absurd.get_task_checkpoint_state(%s, %s, %s)"
            [textParam queue, textParam task.taskId, textParam detailsCheckpoint]
        latest <- maybe (pure Null) (refuse . optionalJson) details
        s.commit
        pure (Just (task {petrusInstance = scope}, latest))

-- | @heartbeat(queue, task_id=..., run_id=..., timeout=..., details=...)@:
-- under the lease guard, store the new details (extending the lease) or
-- just extend it, and answer the details now on record. 'Nothing' is the
-- reference's omitted @details@; invalid details are refused before any
-- statement.
guardedHeartbeat :: GuardedDispatch -> Text -> Text -> Text -> Int -> Maybe Json -> IO Json
guardedHeartbeat g queue taskId' runId' timeout details = do
  snapshot <- traverse (refuse . snapshotHeartbeatDetails) details
  let s = g.session
  rollingBack s $ do
    guard g queue taskId' runId'
    case snapshot of
      Just value -> do
        stored <- refuse (jsonb value)
        run_
          s
          "SELECT absurd.set_task_checkpoint_state(%s, %s, %s, %s, %s, %s)"
          [textParam queue, textParam taskId', textParam detailsCheckpoint, stored, textParam runId', int timeout]
      Nothing -> run_ s "SELECT absurd.extend_claim(%s, %s, %s)" [textParam queue, textParam runId', int timeout]
    accepted <- maybe (latestDetails g queue taskId') pure snapshot
    s.commit
    pure accepted

-- | A terminal report: the result, or the failure.
data TerminalReport
  = ReportResult Json
  | ReportFailure AttemptFailure

-- | @terminal(queue, task_id=..., run_id=..., result=... | error=...)@.
--
-- A failure that is not already classified becomes a retryable failure
-- named after the exception type (a bare message is a @RuntimeError@, as
-- the Worker-facing adapter wraps it). Under the lease guard, an identical
-- repeated report is acknowledged and a different one refused; otherwise a
-- result completes the run, and a failure fails it — retryable failures
-- retry at provider time plus the larger of the policy's backoff and
-- @retry_after@, a non-retryable one first caps @max_attempts@ at this
-- attempt.
guardedTerminal :: GuardedDispatch -> Text -> Text -> Text -> TerminalReport -> IO ()
guardedTerminal g queue taskId' runId' report = do
  failure <- case report of
    ReportResult _ -> pure Nothing
    ReportFailure (FailureClassified classified) -> pure (Just classified)
    ReportFailure (FailureMessage message) -> Just <$> refuse (retryableFailure message "RuntimeError")
    ReportFailure (FailureException err) ->
      let python = pythonException err
       in Just <$> refuse (retryableFailure (pythonExceptionStr python) python.name)
  let reason = failureReason <$> failure
      s = g.session
      tq = "absurd.t_" <> queue
      rq = "absurd.r_" <> queue
  rollingBack s $ do
    acknowledged <- guardTerminal g queue taskId' runId' (case report of ReportResult r | Nothing <- failure -> Just r; _ -> Nothing) reason
    if acknowledged
      then s.commit
      else do
        case (report, failure, reason) of
          (ReportResult result, Nothing, _) -> do
            stored <- refuse (jsonb result)
            run_ s "SELECT absurd.complete_run(%s, %s, %s)" [textParam queue, textParam runId', stored]
          (_, Just classified, Just reason') -> do
            runRow <-
              first
                s
                (sql ("SELECT attempt, (extract(epoch FROM absurd.current_time()) * 1000000)::int8 FROM " <> rq <> " WHERE run_id=%s"))
                [textParam runId']
            (attempt', nowMicros) <- case runRow of
              Just [Just a, Just micros] -> (,) <$> (fromIntegral <$> intColumn a) <*> intColumn micros
              _ -> throwIO (AbsurdError "stale Activity Attempt: run disappeared while guarded")
            paramsRow <-
              first
                s
                (sql ("SELECT t.params FROM " <> tq <> " t JOIN " <> rq <> " r USING(task_id) WHERE r.run_id=%s"))
                [textParam runId']
            stored <- case paramsRow of
              Just (Just raw : _) -> refuse (jsonColumn raw)
              _ -> pure Null
            policy' <- (.policy) <$> refuse (decodeInvocation stored)
            backoff <- refuse (retryDelay (policyRetryPolicy policy') (toInteger attempt'))
            let f = failureFields classified
                floor' = fromMaybe (IntNumber 0) f.failureRetryAfter
                delay = if floor' > backoff then floor' else backoff
                retryAt
                  | f.failureRetryable = timestamptzParam (microsTime (nowMicros + delayMicros delay))
                  | otherwise = nullParam
            unless f.failureRetryable $
              run_
                s
                (sql ("UPDATE " <> tq <> " t SET max_attempts=%s FROM " <> rq <> " r WHERE r.run_id=%s AND t.task_id=r.task_id"))
                [int attempt', textParam runId']
            reasonParam <- refuse (jsonb reason')
            run_ s "SELECT absurd.fail_run(%s, %s, %s, %s)" [textParam queue, textParam runId', reasonParam, retryAt]
          _ -> pure ()
        s.commit
  where
    retryableFailure message kind = activityFailure (ActivityFailureFields message kind Null True Nothing)

-- | @_guard_terminal@: lock the run, check its identity and custody, and
-- decide whether this report repeats the recorded terminal outcome.
guardTerminal :: GuardedDispatch -> Text -> Text -> Text -> Maybe Json -> Maybe Json -> IO Bool
guardTerminal g queue taskId' runId' result reason = do
  _ <- refuse (validateQueue queue)
  row <-
    first
      g.session
      ( sql
          ( "SELECT r.task_id,r.state,r.claimed_by,r.claim_expires_at,"
              <> "r.claim_expires_at > absurd.current_time(),r.result,r.failure_reason,t.state FROM absurd."
              <> quoteIdentifier ("r_" <> queue)
              <> " r JOIN absurd."
              <> quoteIdentifier ("t_" <> queue)
              <> " t USING(task_id) WHERE r.run_id=%s FOR UPDATE OF r"
          )
      )
      [textParam runId']
  case row of
    Just [Just task', state, claimedBy, deadline, unexpired, storedResult, storedFailure, taskState]
      | utf8 task' == taskId' -> do
          let state' = utf8 <$> state
          when (fmap utf8 claimedBy /= Just g.claimant) stale
          case state' of
            Just "completed" -> do
              when (fmap utf8 taskState /= Just "completed") stale
              case result of
                Just r -> do
                  storedJson <- refuse (optionalJsonColumn storedResult)
                  same <- (==) <$> refuse (canonicalJson storedJson) <*> refuse (canonicalJson r)
                  if same then pure True else conflicting
                Nothing -> conflicting
            Just "failed" -> do
              storedJson <- refuse (optionalJsonColumn storedFailure)
              case lookupMember "petrus_failure" storedJson of
                Just marker | marker == Int 1 -> pure ()
                _ -> stale
              case reason of
                Just r -> do
                  same <- (==) <$> refuse (canonicalJson storedJson) <*> refuse (canonicalJson r)
                  if same then pure True else conflicting
                Nothing -> conflicting
            _ -> do
              when (state' /= Just "running" || not (isJust deadline) || fmap utf8 unexpired /= Just "t") stale
              pure False
    _ -> throwIO (AbsurdError "stale Activity Attempt: task/run identity is not current")
  where
    stale = throwIO (AbsurdError "stale Activity Attempt: claimant, state, or lease deadline is no longer current")
    conflicting = dispatchError "conflicting terminal report"

-- | @latest_details(queue, task_id)@: the details on record ('Null' when
-- none).
latestDetails :: GuardedDispatch -> Text -> Text -> IO Json
latestDetails g queue taskId' = do
  row <-
    first
      g.session
      "SELECT state FROM absurd.get_task_checkpoint_state(%s, %s, %s)"
      [textParam queue, textParam taskId', textParam detailsCheckpoint]
  maybe (pure Null) (refuse . optionalJson) row

-- | @_guard@: lock the run row and require the same task, the running
-- state, this claimant and an unexpired lease.
guard :: GuardedDispatch -> Text -> Text -> Text -> IO ()
guard g queue taskId' runId' = do
  _ <- refuse (validateQueue queue)
  row <-
    first
      g.session
      ( sql
          ( "SELECT task_id, state, claimed_by, claim_expires_at, "
              <> "claim_expires_at > absurd.current_time() FROM absurd."
              <> quoteIdentifier ("r_" <> queue)
              <> " WHERE run_id = %s FOR UPDATE"
          )
      )
      [textParam runId']
  case row of
    Just [Just task', state, claimedBy, deadline, unexpired]
      | utf8 task' == taskId' ->
          when
            ( fmap utf8 state /= Just "running"
                || fmap utf8 claimedBy /= Just g.claimant
                || not (isJust deadline)
                || fmap utf8 unexpired /= Just "t"
            )
            (throwIO (AbsurdError "stale Activity Attempt: claimant, state, or lease deadline is no longer current"))
    _ -> throwIO (AbsurdError "stale Activity Attempt: task/run identity is not current")

-- ---------------------------------------------------------------------------
-- Reconnecting heartbeats

-- | The provider-local custody facade that reconnects one failed transport
-- heartbeat (@_ReconnectableGuardedDispatch@): same claimant, a fresh
-- join-mode connection listening on the dispatch doorbell.
data ReconnectableGuardedDispatch = ReconnectableGuardedDispatch
  { dsnOf :: ByteString
  , current :: IORef GuardedDispatch
  }

-- | Wrap a join-mode connection with its claimant.
reconnectableGuardedDispatch :: ByteString -> Connection -> Text -> IO ReconnectableGuardedDispatch
reconnectableGuardedDispatch dsn' connection claimant' = do
  g <- guardedDispatch (sessionOf connection) (Just claimant')
  ReconnectableGuardedDispatch dsn' <$> newIORef g

-- | The connection currently in use.
reconnectableConnection :: ReconnectableGuardedDispatch -> IO Connection
reconnectableConnection r = (.session.connection) <$> readIORef r.current

-- | The claimant (stable across reconnects).
reconnectableClaimant :: ReconnectableGuardedDispatch -> IO Text
reconnectableClaimant r = (.claimant) <$> readIORef r.current

-- | The guarded door currently in use.
reconnectableGuard :: ReconnectableGuardedDispatch -> IO GuardedDispatch
reconnectableGuard r = readIORef r.current

reconnectableClaim :: ReconnectableGuardedDispatch -> Text -> Int -> IO (Maybe (ClaimedTask, Json))
reconnectableClaim r queue timeout = readIORef r.current >>= \g -> guardedClaim g queue timeout

-- | A heartbeat that, when it fails with an @OperationalError@ or
-- @InterfaceError@ on a connection that is now closed or broken, replaces
-- the connection once and retries once.
reconnectableHeartbeat :: ReconnectableGuardedDispatch -> Text -> Text -> Text -> Int -> Maybe Json -> IO Json
reconnectableHeartbeat r queue taskId' runId' timeout details =
  reconnectOnce
    (reconnectableConnection r >>= transportDead)
    (replaceConnection r)
    (readIORef r.current >>= \g -> guardedHeartbeat g queue taskId' runId' timeout details)

reconnectableTerminal :: ReconnectableGuardedDispatch -> Text -> Text -> Text -> TerminalReport -> IO ()
reconnectableTerminal r queue taskId' runId' report = readIORef r.current >>= \g -> guardedTerminal g queue taskId' runId' report

reconnectableClose :: ReconnectableGuardedDispatch -> IO ()
reconnectableClose r = reconnectableConnection r >>= Pg.close

-- | The reconnect rule on its own: run the action; on a 'PostgresError' of
-- class @OperationalError@ or @InterfaceError@, when the transport is dead,
-- replace it and run the action once more (a second failure propagates);
-- any other failure, or one on a live transport, propagates untouched.
reconnectOnce :: IO Bool -> IO () -> IO a -> IO a
reconnectOnce dead replace action =
  action `catch` \(failure :: PostgresError) ->
    if failure.errorClass `elem` [OperationalError, InterfaceError]
      then do
        gone <- dead
        if gone then replace >> action else throwIO failure
      else throwIO failure

transportDead :: Connection -> IO Bool
transportDead connection = (||) <$> isClosed connection <*> isBroken connection

replaceConnection :: ReconnectableGuardedDispatch -> IO ()
replaceConnection r = do
  old <- readIORef r.current
  Pg.close old.session.connection
  connection <- Pg.connect r.dsnOf False
  replacement <-
    ( do
        Pg.execute_ connection (sql ("LISTEN " <> dispatchChannel)) []
        Pg.commit connection
        guardedDispatch (sessionOf connection) (Just old.claimant)
    )
      `onException` Pg.close connection
  writeIORef r.current replacement

-- ---------------------------------------------------------------------------
-- The Worker-facing adapter

-- | @AbsurdWorkerDispatch@: the Worker-facing adapter over one join-mode
-- connection; PostgreSQL values never cross it.
data AbsurdWorkerDispatch = AbsurdWorkerDispatch
  { dsn :: ByteString
  , subscribed :: [Text]
  , claimant :: Text
  , leaseTimeout :: Int
  , custody :: ReconnectableGuardedDispatch
  }

-- | The reference's keyword options.
data AbsurdWorkerOptions = AbsurdWorkerOptions
  { queues :: [Text]
  , workerId :: Maybe Text
  , claimTimeout :: Int
  }

-- | @queues=("default",)@, no worker id (@worker-{pid}@), a 30 s claim
-- timeout.
defaultAbsurdWorkerOptions :: AbsurdWorkerOptions
defaultAbsurdWorkerOptions = AbsurdWorkerOptions {queues = ["default"], workerId = Nothing, claimTimeout = 30}

-- | Validate and deduplicate the queues (first occurrence wins), mint the
-- claimant (@"{worker_id or worker-{pid}}:{uuid4}"@), connect in join mode,
-- create every queue (committed), and LISTEN on the dispatch doorbell
-- (committed). The connection is closed if any of it fails.
openAbsurdWorkerDispatch :: ByteString -> AbsurdWorkerOptions -> IO AbsurdWorkerDispatch
openAbsurdWorkerDispatch dsn' options = do
  Telemetry.validateTelemetryEnvironment
  validated <- mapM (refuse . validateQueue) options.queues
  let queues' = nub validated
  when (null queues') $ dispatchError "Absurd Worker Dispatch requires at least one queue"
  base <- case options.workerId of
    Just w | not (T.null w) -> pure w
    _ -> ("worker-" <>) . showT <$> getProcessID
  suffix <- uuid4
  let claimant' = base <> ":" <> suffix
  connection <- Pg.connect dsn' False
  ( do
      forM_ queues' $ \q -> Pg.execute_ connection "SELECT absurd.create_queue(%s)" [textParam q]
      Pg.commit connection
      Pg.execute_ connection (sql ("LISTEN " <> dispatchChannel)) []
      Pg.commit connection
      custody' <- reconnectableGuardedDispatch dsn' connection claimant'
      pure
        AbsurdWorkerDispatch
          { dsn = dsn'
          , subscribed = queues'
          , claimant = claimant'
          , leaseTimeout = options.claimTimeout
          , custody = custody'
          }
    )
    `onException` Pg.close connection

-- | The validated, deduplicated queue subscription, in order.
workerQueues :: AbsurdWorkerDispatch -> [Text]
workerQueues w = w.subscribed

-- | The connection the worker currently uses (it changes when a heartbeat
-- reconnects).
workerConnection :: AbsurdWorkerDispatch -> IO Connection
workerConnection w = reconnectableConnection w.custody

-- | The provider-neutral surface.
toWorkerDispatch :: AbsurdWorkerDispatch -> WorkerDispatch
toWorkerDispatch w =
  WorkerDispatch
    { Port.claim = claim w
    , Port.heartbeat = heartbeat w
    , Port.complete = complete w
    , Port.fail = fail w
    , Port.wait = wait w
    , Port.close = close w
    }

-- | Claim from the queues in order; the first claimed task becomes an
-- 'ActivityAttempt' (task id, run id as the epoch, the latest details, the
-- scoped Instance).
claim :: AbsurdWorkerDispatch -> IO (Maybe ActivityAttempt)
claim w = go w.subscribed
  where
    go [] = pure Nothing
    go (q : rest) =
      reconnectableClaim w.custody q w.leaseTimeout >>= \case
        Nothing -> go rest
        Just (task, details) -> do
          inv <- refuse (decodeInvocation task.params)
          Just <$> refuse (activityAttempt task.taskId task.runId w.claimant q inv details task.petrusInstance)

-- | Heartbeat with the policy's heartbeat timeout.
heartbeat :: AbsurdWorkerDispatch -> ActivityAttempt -> Maybe Json -> IO Json
heartbeat w attempt' details =
  reconnectableHeartbeat
    w.custody
    attempt'.queue
    attempt'.attemptId
    attempt'.epoch
    (fromInteger (policyFields attempt'.invocation.policy).heartbeatTimeout)
    details

-- | Report the result, then ring the results doorbell.
complete :: AbsurdWorkerDispatch -> ActivityAttempt -> Json -> IO ()
complete w attempt' result = do
  reconnectableTerminal w.custody attempt'.queue attempt'.attemptId attempt'.epoch (ReportResult result)
  notifyResults w attempt'.queue

-- | Report the failure, then ring the results doorbell.
fail :: AbsurdWorkerDispatch -> ActivityAttempt -> AttemptFailure -> IO ()
fail w attempt' failure = do
  reconnectableTerminal w.custody attempt'.queue attempt'.attemptId attempt'.epoch (ReportFailure failure)
  notifyResults w attempt'.queue

-- | Wait for one dispatch doorbell.
wait :: AbsurdWorkerDispatch -> Double -> IO Bool
wait w seconds = do
  connection <- workerConnection w
  isJust <$> waitForNotification connection seconds

close :: AbsurdWorkerDispatch -> IO ()
close w = reconnectableClose w.custody

notifyResults :: AbsurdWorkerDispatch -> Text -> IO ()
notifyResults w queue = do
  connection <- workerConnection w
  Pg.execute_ connection "SELECT pg_notify(%s, %s)" [textParam resultsChannel, textParam queue]
  Pg.commit connection

-- ---------------------------------------------------------------------------
-- The Engine-facing Dispatch

-- | The 'Dispatch' over Absurd (@AbsurdDispatch@), derived over the
-- authority's join-mode session: a rollback retracts spawns its state
-- already advanced on, so it shares the Engine's whole-runtime rollback
-- fate.
data AbsurdDispatch = AbsurdDispatch
  { session :: Session
  , instance' :: Text
  , listenOn :: Maybe Connection
  , pollEvery :: Double
  , routeDefault :: Text
  , routes :: Map Text Text
  , tasks :: IORef (Map Int (Text, Text))
  , cancelled :: IORef (Map Int CancellationInstruction)
  , collected :: IORef (Set Int)
  , knownQueues :: IORef (Set Text)
  , listening :: IORef Bool
  }

-- | The reference's keyword options.
data AbsurdDispatchOptions = AbsurdDispatchOptions
  { listen :: Maybe Connection
  -- ^ The dedicated autocommit connection the results doorbell and the
  -- wait-time probes ride.
  , pollInterval :: Double
  , defaultQueue :: Text
  , activityQueues :: [(Text, Text)]
  -- ^ Exact Activity-name overrides, in the caller's order.
  }

-- | No listen connection, a 0.25 s poll, the @default@ queue, no overrides.
defaultAbsurdDispatchOptions :: AbsurdDispatchOptions
defaultAbsurdDispatchOptions =
  AbsurdDispatchOptions {listen = Nothing, pollInterval = 0.25, defaultQueue = "default", activityQueues = []}

-- | @AbsurdDispatch(connection, instance=..., ...)@ over a plain connection.
absurdDispatch :: Connection -> Text -> AbsurdDispatchOptions -> IO AbsurdDispatch
absurdDispatch connection = absurdDispatchOver (sessionOf connection)

-- | @AbsurdDispatch(...)@ over a session.
absurdDispatchOver :: Session -> Text -> AbsurdDispatchOptions -> IO AbsurdDispatch
absurdDispatchOver s instanceId options = do
  Telemetry.validateTelemetryEnvironment
  when (T.null instanceId) $ dispatchError "AbsurdDispatch requires a non-empty string instance id, got ''"
  forM_ options.listen $ \l -> do
    mode <- autocommit l
    unless mode $
      dispatchError
        ( "the listen connection must be autocommit: PostgreSQL delivers notifications between "
            <> "transactions, and the joined authority transaction must never own the notification wire"
        )
  default' <- refuse (validateQueue options.defaultQueue)
  overrides <- forM options.activityQueues $ \(activity', q) -> (activity',) <$> refuse (validateQueue q)
  when (any (T.null . fst) overrides) $ dispatchError "activity queue overrides require non-empty string Activity names"
  tasks' <- newIORef Map.empty
  cancelled' <- newIORef Map.empty
  collected' <- newIORef Set.empty
  known <- newIORef Set.empty
  listening' <- newIORef False
  pure
    AbsurdDispatch
      { session = s
      , instance' = instanceId
      , listenOn = options.listen
      , pollEvery = options.pollInterval
      , routeDefault = default'
      , routes = Map.fromList overrides
      , tasks = tasks'
      , cancelled = cancelled'
      , collected = collected'
      , knownQueues = known
      , listening = listening'
      }

-- | The Dispatch port over this adapter, with recoverable cancellation.
toDispatch :: AbsurdDispatch -> Dispatch
toDispatch d = Dispatch {Port.dispatch = dispatch d, Port.collect = collect d, Port.cancel = Just (cancel d)}

-- | @queue_for@: an exact Activity override, otherwise the default queue.
queueFor :: AbsurdDispatch -> Text -> Either Text Text
queueFor d activity'
  | T.null activity' = Left "queue routing requires a non-empty Activity name"
  | otherwise = Right (Map.findWithDefault d.routeDefault activity' d.routes)

-- | The validated default queue.
defaultQueueOf :: AbsurdDispatch -> Text
defaultQueueOf d = d.routeDefault

-- | The (queue, task id) this session holds for an occurrence.
dispatchedTask :: AbsurdDispatch -> Int -> IO (Maybe (Text, Text))
dispatchedTask d occurrence = Map.lookup occurrence <$> readIORef d.tasks

-- | Durably enqueue one invocation, keyed by the occurrence, and ring the
-- dispatch doorbell — all inside the caller's open transaction. Refuses
-- autocommit, a conflicting redispatch of a cancelled occurrence, and the
-- deadlines the pinned provider cannot enforce; recovers existing custody
-- first (lookup-first).
dispatch :: AbsurdDispatch -> Int -> ActivityInvocation -> IO ()
dispatch d occurrence inv = do
  mode <- autocommit d.session.connection
  when mode $
    throwIO
      ( AbsurdError
          ( "Absurd dispatch publication cannot run in autocommit mode; it requires a joined transaction "
              <> "(autocommit=False): occurrence "
              <> "discovery, custody reconciliation, spawn, and notification must commit or roll back together"
          )
      )
  fenced <- Map.lookup occurrence <$> readIORef d.cancelled
  case fenced of
    Just prior -> when (prior.invocation /= inv) $ dispatchError ("Absurd cancellation conflict for occurrence " <> showT occurrence)
    Nothing -> do
      let fields = policyFields inv.policy
      when (isJust fields.startToClose || isJust fields.scheduleToClose) $
        dispatchError
          ( "AbsurdDispatch does not support start_to_close or schedule_to_close with the pinned provider; "
              <> "exact deadlines require cancellation tombstones and are therefore refused"
          )
      queue <- refuse (queueFor d inv.activity)
      existing <- recoverCustody d occurrence queue inv
      case existing of
        Just custody' -> modifyIORef' d.tasks (Map.insert occurrence custody')
        Nothing -> do
          known <- readIORef d.knownQueues
          unless (Set.member queue known) $ do
            run_ d.session "SELECT absurd.create_queue(%s)" [textParam queue]
            modifyIORef' d.knownQueues (Set.insert queue)
          let options =
                Object
                  [ ("idempotency_key", String (publicationKey d.instance' occurrence))
                  , ("max_attempts", Int fields.attempts)
                  , ("retry_strategy", Object [("kind", String "none")])
                  ]
          payload <- refuse (jsonb (encodeInvocation inv))
          optionsParam <- refuse (jsonb options)
          row <-
            first
              d.session
              "SELECT task_id, run_id, attempt, created FROM absurd.spawn_task(%s, %s, %s, %s)"
              [textParam queue, textParam inv.activity, payload, optionsParam]
          taskId' <- case row of
            Just (Just t : _) -> pure (utf8 t)
            _ -> throwIO (AbsurdError "absurd.spawn_task returned no task")
          modifyIORef' d.tasks (Map.insert occurrence (queue, taskId'))
          run_ d.session "SELECT pg_notify(%s, %s)" [textParam dispatchChannel, textParam queue]
          emit
            "absurd_dispatched"
            [ ("occurrence", Int (toInteger occurrence))
            , ("activity", String inv.activity)
            , ("queue", String queue)
            , ("task", String taskId')
            ]

-- | One custody row ('custodySelect'), decoded once. States are Absurd's
-- stored state names, compared as the reference compares them.
data Custody = Custody
  { queue :: Text
  , taskId :: Text
  , state :: Text
  , firstStarted :: Maybe Text
  -- ^ @first_started_at@, as text.
  , lastRun :: Maybe Text
  -- ^ @last_attempt_run@.
  , runState :: Maybe Text
  -- ^ The state of 'lastRun'.
  }

isTombstone :: Custody -> Bool
isTombstone custody = custody.state == "cancelled"

isTerminalState :: Text -> Bool
isTerminalState = (`elem` ["completed", "failed"])

-- | Fence one exact invocation with Absurd's durable task tombstone.
cancel :: AbsurdDispatch -> CancellationInstruction -> IO CancellationDisposition
cancel d instruction = do
  mode <- autocommit d.session.connection
  when mode $
    throwIO
      ( AbsurdError
          ( "Absurd cancellation cannot run in autocommit mode; its task tombstone must commit as one "
              <> "recoverable operational instruction"
          )
      )
  let occurrence = instruction.occurrence
  prior <- Map.lookup occurrence <$> readIORef d.cancelled
  case prior of
    Just previous
      | previous /= instruction -> dispatchError ("Absurd cancellation conflict for occurrence " <> showT occurrence)
      | otherwise -> pure Acknowledged
    Nothing -> do
      let key = publicationKey d.instance' occurrence
      run_ d.session "SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))" [textParam key]
      found <- custodies d key
      let live = filter (not . isTombstone) found
      when (length live > 1) $
        throwIO
          ( AbsurdError
              ("ambiguous Absurd custody for " <> key <> ": found " <> showT (length live) <> " live tasks across provider queues")
          )
      resolved <-
        if null live
          then do
            let tombstones = filter isTombstone found
            if not (null tombstones)
              then do
                forM_ tombstones $ \row -> verifyCustodyInvocation d key row instruction.invocation
                modifyIORef' d.cancelled (Map.insert occurrence instruction)
                pure Nothing
              else do
                -- The canonical outbox may have committed before split-store
                -- publication: materialize and cancel in this one transaction
                -- so no worker can observe the synthetic pending interval.
                dispatch d occurrence instruction.invocation
                Map.lookup occurrence <$> readIORef d.tasks >>= \case
                  Just (queue, taskId') -> Just <$> custodyOf d queue taskId'
                  Nothing -> throwIO (AbsurdError ("Absurd custody for occurrence " <> showT occurrence <> " was not materialized"))
          else pure (case live of { row : _ -> Just row; [] -> Nothing })
      case resolved of
        Nothing -> pure Acknowledged
        Just custody' -> do
          let queue = custody'.queue
              taskId' = custody'.taskId
              state = custody'.state
          verifyCustodyInvocation d key custody' instruction.invocation
          if isTerminalState state
            then do
              modifyIORef' d.tasks (Map.insert occurrence (queue, taskId'))
              modifyIORef' d.cancelled (Map.insert occurrence instruction)
              pure Terminal
            else do
              let disposition = if state == "pending" then Retired else Fenced
              run_ d.session "SELECT absurd.cancel_task(%s, %s)" [textParam queue, textParam taskId']
              modifyIORef' d.tasks (Map.delete occurrence)
              modifyIORef' d.cancelled (Map.insert occurrence instruction)
              emit
                "absurd_cancelled"
                [ ("occurrence", Int (toInteger occurrence))
                , ("history_position", Int (toInteger instruction.historyPosition))
                , ("disposition", String (dispositionText disposition))
                , ("queue", String queue)
                , ("task", String taskId')
                ]
              pure disposition

custodySelect :: Text -> Text -> Sql
custodySelect queue predicate =
  sql
    ( "SELECT task_id::text, state, first_started_at, last_attempt_run::text, "
        <> "(SELECT state FROM absurd."
        <> quoteIdentifier ("r_" <> queue)
        <> " r WHERE r.run_id = t.last_attempt_run) "
        <> "FROM absurd."
        <> quoteIdentifier ("t_" <> queue)
        <> " t WHERE "
        <> predicate
    )

custodyRow :: Text -> [Maybe ByteString] -> IO Custody
custodyRow queue = \case
  [Just task', Just state, started, run', runState] ->
    pure
      Custody
        { queue
        , taskId = utf8 task'
        , state = utf8 state
        , firstStarted = utf8 <$> started
        , lastRun = utf8 <$> run'
        , runState = utf8 <$> runState
        }
  other -> throwIO (AbsurdError ("unexpected Absurd custody row " <> showT other))

-- | Every task under the key, across every provider queue.
custodies :: AbsurdDispatch -> Text -> IO [Custody]
custodies d key = do
  queues' <- map (\row -> maybe "" utf8 (headMay row >>= id)) <$> d.session.run "SELECT queue_name FROM absurd.list_queues()" []
  concat <$> forM queues' (\q -> d.session.run (custodySelect q "idempotency_key = %s") [textParam key] >>= mapM (custodyRow q))

custodyOf :: AbsurdDispatch -> Text -> Text -> IO Custody
custodyOf d queue taskId' =
  first d.session (custodySelect queue "task_id = %s") [textParam taskId'] >>= \case
    Just row -> custodyRow queue row
    Nothing -> throwIO (AbsurdError ("Absurd custody for task " <> taskId' <> " disappeared during cancellation"))

-- | The stored task's name and params against the instruction's invocation.
verifyCustodyInvocation :: AbsurdDispatch -> Text -> Custody -> ActivityInvocation -> IO ()
verifyCustodyInvocation d key custody inv = do
  (name, stored) <- taskIdentity d custody.queue custody.taskId
  recovered <- case decodeInvocation stored of
    Right decoded -> pure (encodeInvocation decoded)
    Left _ -> dispatchError ("Absurd cancellation conflict for " <> key <> ": stored invocation params are invalid")
  same <- sameWire recovered inv
  unless (name == inv.activity && same) $
    dispatchError ("Absurd cancellation conflict for " <> key <> ": activity or invocation params differ")

taskIdentity :: AbsurdDispatch -> Text -> Text -> IO (Text, Json)
taskIdentity d queue taskId' =
  first d.session (sql ("SELECT task_name,params FROM absurd." <> quoteIdentifier ("t_" <> queue) <> " WHERE task_id=%s")) [textParam taskId'] >>= \case
    Just [Just name, Just stored] -> (utf8 name,) <$> refuse (jsonColumn stored)
    Just [Just name, Nothing] -> pure (utf8 name, Null)
    _ -> throwIO (AbsurdError ("Absurd custody for task " <> taskId' <> " disappeared"))

sameWire :: Json -> ActivityInvocation -> IO Bool
sameWire recovered inv = (==) <$> refuse (canonicalJson recovered) <*> refuse (canonicalJson (encodeInvocation inv))

-- | @_recover_custody@: find and, when safe, atomically transfer one
-- provider custody to the current route.
recoverCustody :: AbsurdDispatch -> Int -> Text -> ActivityInvocation -> IO (Maybe (Text, Text))
recoverCustody d occurrence target inv = do
  let key = publicationKey d.instance' occurrence
      s = d.session
      refuseRuntime = throwIO . AbsurdError
  -- One transaction-scoped mutex per canonical occurrence, held from
  -- discovery through any cancel, replacement spawn, and notification.
  run_ s "SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))" [textParam key]
  found <- custodies d key
  let live = filter (not . isTombstone) found
      targetTombstones = filter (\custody -> custody.queue == target && isTombstone custody) found
      tombstoned =
        refuseRuntime ("cannot establish Absurd custody for " <> key <> ": target queue " <> pythonStrRepr target <> " has a cancelled tombstone")
  case live of
    []
      | not (null targetTombstones) -> tombstoned
      | otherwise -> pure Nothing
    [Custody {queue, taskId = taskId', state = taskState, lastRun = runId', runState}] -> do
      (name, stored) <- taskIdentity d queue taskId'
      recovered <- case decodeInvocation stored of
        Right decoded -> pure (encodeInvocation decoded)
        Left _ -> dispatchError ("Absurd publication conflict for " <> key <> ": stored invocation params are invalid")
      same <- sameWire recovered inv
      unless (name == inv.activity && same) $
        dispatchError ("Absurd publication conflict for " <> key <> ": activity or invocation params differ")
      if isTerminalState taskState
        then do
          when (runId' == Nothing || runState /= Just taskState) $
            refuseRuntime
              ( "cannot reconcile terminal Absurd custody for "
                  <> key
                  <> ": task/run terminal state is invalid (task="
                  <> pythonStrRepr taskState
                  <> ", last_attempt_run="
                  <> maybe "None" pythonStrRepr runId'
                  <> ", run="
                  <> maybe "None" pythonStrRepr runState
                  <> ")"
              )
          pure (Just (queue, taskId'))
        else
          if not (null targetTombstones)
            then tombstoned
            else
              if queue == target
                then pure (Just (queue, taskId'))
                else case runId' of
                  Nothing -> refuseRuntime ("cannot transfer Absurd custody for " <> key <> ": task has no active run")
                  Just activeRun -> do
                    locks <-
                      try @PostgresError $ do
                        lockedRun <-
                          first s (sql ("SELECT state FROM absurd." <> quoteIdentifier ("r_" <> queue) <> " WHERE run_id = %s FOR UPDATE NOWAIT")) [textParam activeRun]
                        lockedTask <-
                          first
                            s
                            ( sql
                                ( "SELECT state, first_started_at, last_attempt_run::text FROM absurd."
                                    <> quoteIdentifier ("t_" <> queue)
                                    <> " WHERE task_id = %s FOR UPDATE NOWAIT"
                                )
                            )
                            [textParam taskId']
                        pure (lockedRun, lockedTask)
                    (lockedRun, lockedTask) <- case locks of
                      Left failure
                        | hasSqlState lockNotAvailable failure ->
                            refuseRuntime ("cannot transfer Absurd custody for " <> key <> ": custody is currently locked")
                        | otherwise -> throwIO failure
                      Right found' -> pure found'
                    let runText = fmap (map (fmap utf8)) lockedRun
                        taskText = fmap (map (fmap utf8)) lockedTask
                    unless (runText == Just [Just "pending"] && taskText == Just [Just "pending", Nothing, Just activeRun]) $
                      refuseRuntime
                        ( "cannot transfer Absurd custody for "
                            <> key
                            <> ": only one pending/pending never-started task may move (run="
                            <> reprRow runText
                            <> ", task="
                            <> reprRow taskText
                            <> ")"
                        )
                    run_ s "SELECT absurd.cancel_task(%s, %s)" [textParam queue, textParam taskId']
                    pure Nothing
    _ ->
      refuseRuntime ("ambiguous Absurd custody for " <> key <> ": found " <> showT (length live) <> " live tasks across provider queues")

-- | @repr@ of a fetched row tuple (values as their text output).
reprRow :: Maybe [Maybe Text] -> Text
reprRow = \case
  Nothing -> "None"
  Just [single] -> "(" <> value single <> ",)"
  Just values -> "(" <> T.intercalate ", " (map value values) <> ")"
  where
    value = maybe "None" pythonStrRepr

-- | @collect()@: the terminal outcomes of dispatched, not yet collected
-- occurrences, in completion order (the last run's terminal instant, then
-- the occurrence). A cancelled task is refused: a custody tombstone is not
-- an Activity outcome.
collect :: AbsurdDispatch -> IO [(Int, ActivityOutcome)]
collect d = do
  owned <- readIORef d.tasks
  done <- readIORef d.collected
  let pending =
        Map.fromListWith
          Map.union
          [(queue, Map.singleton taskId' occurrence) | (occurrence, (queue, taskId')) <- Map.toList owned, not (Set.member occurrence done)]
  arrived <- fmap concat . forM (Map.toAscList pending) $ \(queue, ids) -> do
    rows' <-
      d.session.run
        ( sql
            ( "SELECT t.task_id::text, t.state, t.completed_payload, r.failure_reason, "
                <> "(extract(epoch FROM coalesce(r.completed_at, r.failed_at, r.created_at)) * 1000000)::int8 FROM absurd."
                <> quoteIdentifier ("t_" <> queue)
                <> " t LEFT JOIN absurd."
                <> quoteIdentifier ("r_" <> queue)
                <> " r ON r.run_id = t.last_attempt_run "
                <> "WHERE t.task_id = ANY(%s::uuid[]) AND t.state IN ('completed', 'failed', 'cancelled')"
            )
        )
        [textArrayParam (Map.keys ids)]
    forM rows' $ \case
      [Just task', Just state, payload, failure, terminalAt] -> do
        let taskId' = utf8 task'
            occurrence = Map.findWithDefault 0 taskId' ids
        outcome <- case utf8 state of
          "cancelled" ->
            throwIO
              ( AbsurdError
                  ( "task "
                      <> taskId'
                      <> " (occurrence "
                      <> showT occurrence
                      <> ") is cancelled in Absurd: a custody tombstone "
                      <> "is not an activity outcome, refusing to fold a guess"
                  )
              )
          "completed" -> Succeeded <$> refuse (optionalJsonColumn payload)
          _ -> do
            reason <- refuse (optionalJsonColumn failure)
            Failed <$> refuse (decodeFailure reason)
        at' <- traverse intColumn terminalAt
        pure (at', occurrence, outcome)
      other -> throwIO (AbsurdError ("unexpected Absurd collect row " <> showT other))
  let ordered = sortOn (\(at', occurrence, _) -> (at', occurrence)) arrived
  modifyIORef' d.collected (Set.union (Set.fromList [occurrence | (_, occurrence, _) <- ordered]))
  unless (null ordered) $
    emit
      "absurd_collected"
      [ ("results", Int (toInteger (length ordered)))
      , ("failures", Int (toInteger (length [() | (_, _, Failed _) <- ordered])))
      ]
  pure [(occurrence, outcome) | (_, occurrence, outcome) <- ordered]

-- | @wait_for_results(timeout)@: block until a dispatched, uncollected
-- occurrence has a terminal outcome, or the timeout elapses. Wakes on the
-- results doorbell when a listen connection was supplied (LISTEN is issued
-- on first use) and polls every 'pollInterval' regardless — NOTIFY is
-- lossy, so the poll is the safety net. The probe runs on the listen
-- connection when there is one, so the joined transaction stays untouched
-- while a driver waits.
waitForResults :: AbsurdDispatch -> Double -> IO Bool
waitForResults d seconds = do
  forM_ d.listenOn $ \l -> do
    already <- readIORef d.listening
    unless already $ do
      Pg.execute_ l (sql ("LISTEN " <> resultsChannel)) []
      writeIORef d.listening True
  pollWithDoorbell d.pollEvery d.listenOn seconds (terminalReady d)

terminalReady :: AbsurdDispatch -> IO Bool
terminalReady d = do
  owned <- readIORef d.tasks
  done <- readIORef d.collected
  let probe statement params = case d.listenOn of
        Just l -> Pg.query l statement params
        Nothing -> d.session.run statement params
      pending =
        Map.fromListWith
          (flip (<>))
          [(queue, [taskId']) | (occurrence, (queue, taskId')) <- Map.toList owned, not (Set.member occurrence done)]
      go [] = pure False
      go ((queue, ids) : rest) = do
        found <-
          probe
            ( sql
                ( "SELECT 1 FROM absurd."
                    <> quoteIdentifier ("t_" <> queue)
                    <> " WHERE task_id = ANY(%s::uuid[]) "
                    <> "AND state IN ('completed', 'failed', 'cancelled') LIMIT 1"
                )
            )
            [textArrayParam ids]
        if null found then go rest else pure True
  go (Map.toList pending)

-- ---------------------------------------------------------------------------
-- Helpers

refuse :: Either Text a -> IO a
refuse = either dispatchError pure

int :: Int -> Param
int = intParam . fromIntegral

integer :: Integer -> Param
integer = Pg.integerParam

jsonb :: Json -> Either Text Param
jsonb value = either (Left . T.pack . encodeErrorMessage) Right (jsonbParam value)

utf8 :: ByteString -> Text
utf8 = TE.decodeUtf8Lenient

headMay :: [a] -> Maybe a
headMay = \case
  x : _ -> Just x
  [] -> Nothing

jsonColumn :: ByteString -> Either Text Json
jsonColumn raw = either (Left . T.pack) Right (parseJson pythonLoads raw)

optionalJsonColumn :: Maybe ByteString -> Either Text Json
optionalJsonColumn = maybe (Right Null) jsonColumn

-- | The first column of a fetched row as JSON ('Null' for SQL NULL).
optionalJson :: [Maybe ByteString] -> Either Text Json
optionalJson = \case
  value : _ -> optionalJsonColumn value
  [] -> Right Null

-- | An integer column, decoded as psycopg loads it. A value that is not
-- an integer raises a 'DataError' instead of being read as 0.
intColumn :: ByteString -> IO Int64
intColumn raw = either (throwIO . undecodable) pure (Pg.decodeInt raw)
  where
    undecodable problem =
      PostgresError
        { errorClass = DataError
        , errorSqlState = Nothing
        , errorMessage = T.pack problem
        , errorSeverity = Nothing
        , errorPrimary = Nothing
        , errorDetail = Nothing
        , errorHint = Nothing
        }

-- | @timedelta(seconds=delay)@ in microseconds: an int exactly; a float as
-- its whole seconds plus the fraction's microseconds rounded half to even.
delayMicros :: Number -> Int64
delayMicros = \case
  IntNumber seconds -> fromInteger (seconds * 1000000)
  FloatNumber seconds ->
    let whole = truncate seconds :: Integer
        fraction = seconds - fromInteger whole
     in fromInteger (whole * 1000000 + round (fraction * 1e6))

-- | Microseconds since the epoch as a UTC time.
microsTime :: Int64 -> UTCTime
microsTime micros = posixSecondsToUTCTime (fromRational (toRational micros / 1000000))

showT :: (Show a) => a -> Text
showT = T.pack . show

-- ---------------------------------------------------------------------------
-- Telemetry

impetus :: TelemetryLogger
impetus = getLogger "impetus" Nothing

emit :: Text -> [(Text, Json)] -> IO ()
emit = Telemetry.emit impetus
