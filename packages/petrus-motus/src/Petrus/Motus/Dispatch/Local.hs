-- | SQLite-backed, single-host Activity custody (a port of
-- @petrus.motus.dispatch.local@).
--
-- Import qualified:
--
-- > import Petrus.Motus.Dispatch.Local qualified as Local
-- >
-- > custody <- Local.openLocalDispatch "app/dispatch.db" "order-1" Local.defaultLocalDispatchOptions
-- > engine <- Engine.create net "order-1" store (Local.toDispatch custody) options
-- > worker <- Local.worker custody ["default"] (Just "worker")
-- > Local.claim worker >>= traverse_ (\attempt -> Local.complete worker attempt result)
--
-- = Shared file
--
-- The database is the default clock and always the serialization
-- authority. Every operation runs on a connection of its own, configured
-- with the reference's pragmas, and finishes its short @BEGIN IMMEDIATE@
-- transaction before any Activity code runs. The DDL, every statement, the
-- pragmas, the JSON encodings (sorted keys, compact separators, no ASCII
-- escaping), and the telemetry events are the reference's, byte for byte, so
-- Haskell and Python engines and workers can share one database file in any
-- combination.
--
-- = Connections
--
-- The reference opens a new connection for every operation. A session keeps
-- a few of those connections open between operations instead
-- ("Petrus.Sqlite.Pool"), shared with the workers constructed from it, so
-- that closing an operation's connection is never the last close of the
-- file, which would checkpoint the WAL. 'closeLocalDispatch' (or
-- 'withLocalDispatch') closes them, and a worker opened on its own closes
-- its connections in 'close'. A session that is dropped without being closed
-- closes them when it is garbage collected, as the reference's lingering
-- connections close. 'LocalConnections' shares one set of connections among
-- independent workers.
--
-- = Sessions and workers
--
-- A 'LocalDispatch' is the Engine-facing session for one Instance: it
-- publishes, cancels, and collects; 'toDispatch' gives the Engine's
-- 'Dispatch' port. Which occurrences it published and collected is session
-- state, not durable: a restarted Engine re-dispatches its outbox, which is
-- idempotent and re-registers interest. A 'LocalWorkerDispatch' claims across
-- every Instance in the file for its queues and reports fenced terminals;
-- 'toWorkerDispatch' gives the provider-neutral 'WorkerDispatch' surface.
--
-- = Errors
--
-- Every refusal the reference raises as @ValueError@ (and the one private
-- @TypeError@) is a 'DispatchError' carrying the reference's exact message.
-- SQLite failures surface as @direct-sqlite@'s 'Database.SQLite3.SQLError'
-- (the reference's @sqlite3@ exceptions).
module Petrus.Motus.Dispatch.Local
  ( -- * Provider clock
    LocalDispatchClock (..)
  , ClockReader
  , newClockReader
  , sampleClock
    -- * Engine-facing session
  , LocalDispatch (path, instance')
  , LocalDispatchOptions (..)
  , defaultLocalDispatchOptions
  , openLocalDispatch
  , closeLocalDispatch
  , withLocalDispatch
  , toDispatch
  , dispatch
  , cancel
  , collect
  , worker
  , workerWith
  , waitForResults
  , defaultQueueOf
  , activityQueuesOf
  , clockReaderOf
    -- * Worker-side custody
  , LocalWorkerDispatch (path, queues, claimant)
  , LocalWorkerOptions (..)
  , defaultLocalWorkerOptions
  , openLocalWorkerDispatch
  , LocalConnections
  , newLocalConnections
  , closeLocalConnections
  , openLocalWorkerDispatchOn
  , toWorkerDispatch
  , claim
  , heartbeat
  , complete
  , fail
  , wait
  , close
    -- * Wire formats
  , schemaVersion
  , tablePrefix
  , ddl
  , encodeInvocation
  , decodeInvocation
  , attemptIdOf
  , decodeOutcome
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Control.Exception (bracket, catch, onException, throw)
import Control.Monad (forM, forM_, unless, void, when)
import Data.ByteString qualified as BS
import Data.Char (isDigit)
import Data.IORef
import Data.Int (Int64)
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.SQLite3 (SQLData (..))
import GHC.Clock (getMonotonicTime)
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
import Petrus.Json.Python (pythonRepr, pythonStrRepr, uuid4)
import Petrus.Motus.PythonException (pythonException, pythonExceptionRepr)
import Petrus.Motus.PythonException qualified as Python (PythonException (..))
import Petrus.Sqlite.Connection (Connection)
import Petrus.Sqlite.Connection qualified as C
import Petrus.Sqlite.Pool (Pool, closePool, newPool, poolPath, withPooledConnection)
import Petrus.Telemetry (TelemetryLogger, getLogger)
import Petrus.Telemetry qualified as Telemetry
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)
import Prelude hiding (fail)

-- ---------------------------------------------------------------------------
-- Provider clock

-- | Monotone provider time in milliseconds, sampled inside SQLite
-- transactions (the reference's @LocalDispatchClock@ protocol).
newtype LocalDispatchClock = LocalDispatchClock {nowMs :: IO Integer}

-- | The reference's @_ClockReader@: samples a provider clock under a lock,
-- refusing values outside the signed 64-bit range and any rewind against
-- this reader's previous sample. A 'LocalDispatch' shares its reader with
-- the workers it constructs ('worker').
data ClockReader = ClockReader
  { readerClock :: LocalDispatchClock
  , readerLast :: MVar (Maybe Integer)
  }

-- | A reader with no previous sample.
newClockReader :: LocalDispatchClock -> IO ClockReader
newClockReader source = ClockReader source <$> newMVar Nothing

-- | One validated, monotone sample.
sampleClock :: ClockReader -> IO Integer
sampleClock reader = modifyMVar reader.readerLast $ \previous -> do
  instant <- reader.readerClock.nowMs
  unless (0 <= instant && instant <= 2 ^ (63 :: Int) - 1) $
    dispatchError "Local Dispatch clock must return a nonnegative signed-64-bit millisecond integer"
  case previous of
    Just last' | instant < last' -> dispatchError "Local Dispatch clock must not rewind"
    _ -> pure (Just instant, instant)

-- ---------------------------------------------------------------------------
-- Schema

-- | @_VERSION@.
schemaVersion :: Int
schemaVersion = 3

-- | @_PREFIX@.
tablePrefix :: Text
tablePrefix = "impetus_local_dispatch_"

-- | @_DDL@, byte for byte: the reference's opener compares
-- @sqlite_master.sql@ against these texts.
ddl :: [Text]
ddl = [schemaTable, schemaRow, tasksTable, claimableIndex, terminalsTable, cancellationsTable]

schemaTable, schemaRow, tasksTable, claimableIndex, terminalsTable, cancellationsTable :: Text
schemaTable =
  "CREATE TABLE impetus_local_dispatch_schema (\n\
  \ component TEXT PRIMARY KEY CHECK(component='dispatch'), version INTEGER NOT NULL)"
schemaRow = "INSERT INTO impetus_local_dispatch_schema VALUES ('dispatch', 3)"
tasksTable =
  "CREATE TABLE impetus_local_dispatch_tasks (\n\
  \ sequence INTEGER PRIMARY KEY AUTOINCREMENT,\n\
  \ instance TEXT NOT NULL, occurrence INTEGER NOT NULL CHECK(occurrence>0),\n\
  \ queue TEXT NOT NULL, invocation TEXT NOT NULL CHECK(json_valid(invocation)),\n\
  \ epoch INTEGER NOT NULL DEFAULT 0 CHECK(epoch>=0), claimant TEXT, deadline INTEGER,\n\
  \ schedule_start INTEGER NOT NULL, attempt_start INTEGER, attempt_deadline INTEGER, available_at INTEGER NOT NULL,\n\
  \ details TEXT CHECK(details IS NULL OR json_valid(details)),\n\
  \ CHECK((epoch=0 AND claimant IS NULL AND deadline IS NULL) OR\n\
  \       (epoch>0 AND claimant IS NOT NULL AND deadline IS NOT NULL)),\n\
  \ UNIQUE(instance, occurrence))"
claimableIndex =
  "CREATE INDEX impetus_local_dispatch_claimable\n\
  \ ON impetus_local_dispatch_tasks(queue, sequence)"
terminalsTable =
  "CREATE TABLE impetus_local_dispatch_terminals (\n\
  \ sequence INTEGER PRIMARY KEY AUTOINCREMENT,\n\
  \ instance TEXT NOT NULL, occurrence INTEGER NOT NULL, epoch INTEGER NOT NULL CHECK(epoch>=0),\n\
  \ claimant TEXT, outcome TEXT NOT NULL CHECK(json_valid(outcome)),\n\
  \ CHECK((epoch=0 AND claimant IS NULL) OR (epoch>0 AND claimant IS NOT NULL)),\n\
  \ UNIQUE(instance, occurrence),\n\
  \ FOREIGN KEY(instance, occurrence) REFERENCES impetus_local_dispatch_tasks(instance, occurrence))"
cancellationsTable =
  "CREATE TABLE impetus_local_dispatch_cancellations (\n\
  \ instance TEXT NOT NULL, occurrence INTEGER NOT NULL CHECK(occurrence>0),\n\
  \ history_position INTEGER NOT NULL CHECK(history_position>0),\n\
  \ invocation TEXT NOT NULL CHECK(json_valid(invocation)),\n\
  \ PRIMARY KEY(instance, occurrence))"

-- ---------------------------------------------------------------------------
-- Engine-facing session

-- | Engine-facing session over one SQLite custody domain, scoped to one
-- Instance.
data LocalDispatch = LocalDispatch
  { path :: FilePath
  , instance' :: Text
  , defaultQueue :: Text
  , activityQueues :: Map Text Text
  , clockReader :: Maybe ClockReader
  , published :: IORef (Set Int)
  , collected :: IORef (Set Int)
  , connections :: Pool
  -- ^ Shared with the workers constructed from this session.
  }

-- | The keyword arguments of @LocalDispatch(path, *, instance, ...)@ other
-- than the instance.
data LocalDispatchOptions = LocalDispatchOptions
  { defaultQueue :: Text
  , activityQueues :: [(Text, Text)]
  -- ^ Activity name to queue; a later entry for the same name wins, as in a
  -- @dict@.
  , clock :: Maybe LocalDispatchClock
  -- ^ 'Nothing': the database clock.
  }

-- | @default_queue="default", activity_queues=None, clock=None@.
defaultLocalDispatchOptions :: LocalDispatchOptions
defaultLocalDispatchOptions = LocalDispatchOptions {defaultQueue = "default", activityQueues = [], clock = Nothing}

-- | @LocalDispatch(path, instance=instance, ...)@: validate the names,
-- create the parent directory, and create, migrate, or validate the schema.
openLocalDispatch :: FilePath -> Text -> LocalDispatchOptions -> IO LocalDispatch
openLocalDispatch given inst options = do
  Telemetry.validateTelemetryEnvironment
  let file = T.unpack (pathText given)
  inst' <- name inst "instance"
  queue <- name options.defaultQueue "queue"
  forM_ options.activityQueues $ \(activity, routed) -> do
    _ <- name activity "activity"
    name routed "queue"
  reader <- traverse newClockReader options.clock
  publishedRef <- newIORef Set.empty
  collectedRef <- newIORef Set.empty
  createDirectoryIfMissing True (takeDirectory file)
  pool <- connectionPool file
  initialize pool file reader `onException` closePool pool
  pure
    LocalDispatch
      { path = file
      , instance' = inst'
      , defaultQueue = queue
      , activityQueues = Map.fromList options.activityQueues
      , clockReader = reader
      , published = publishedRef
      , collected = collectedRef
      , connections = pool
      }

-- | Close the session's idle connections, and with them those of the
-- workers constructed from it ('worker'). The last connection to the file
-- to close checkpoints the WAL. The session stays usable: each later
-- operation opens and closes a connection of its own, as the reference's
-- operations do. Closing twice is harmless.
closeLocalDispatch :: LocalDispatch -> IO ()
closeLocalDispatch d = closePool d.connections

-- | 'openLocalDispatch', run the action, 'closeLocalDispatch'.
withLocalDispatch :: FilePath -> Text -> LocalDispatchOptions -> (LocalDispatch -> IO a) -> IO a
withLocalDispatch file inst options = bracket (openLocalDispatch file inst options) closeLocalDispatch

-- | The session's default queue.
defaultQueueOf :: LocalDispatch -> Text
defaultQueueOf d = d.defaultQueue

-- | The session's activity routes.
activityQueuesOf :: LocalDispatch -> Map Text Text
activityQueuesOf d = d.activityQueues

-- | The provider clock reader the session (and its workers) sample, if any.
clockReaderOf :: LocalDispatch -> Maybe ClockReader
clockReaderOf d = d.clockReader

-- | The Engine's 'Dispatch' port over this session, with recoverable
-- cancellation.
toDispatch :: LocalDispatch -> Dispatch
toDispatch d = Dispatch {Port.dispatch = dispatch d, Port.collect = collect d, Port.cancel = Just (cancel d)}

-- | Take custody of one occurrence's invocation. Re-dispatch is idempotent;
-- pending or expired work moves to the current route, while a live claim or
-- a terminal keeps its custody route. An occurrence whose cancellation fence
-- is installed is acknowledged without creating work.
dispatch :: LocalDispatch -> Int -> ActivityInvocation -> IO ()
dispatch d occurrence inv = do
  checkOccurrence occurrence
  let queue = Map.findWithDefault d.defaultQueue inv.activity d.activityQueues
  encoded <- orRefuse (encodeInvocation inv)
  let key = [SQLText d.instance', intData occurrence]
      conflict = dispatchError ("Local Dispatch publication conflict for occurrence " <> showT occurrence)
  fenced <- withTransaction d.connections $ \db -> do
    cancelled <-
      query db "SELECT history_position,invocation FROM impetus_local_dispatch_cancellations WHERE instance=? AND occurrence=?" key
    case cancelled of
      [_, stored] : _ -> do
        unless (stored == SQLText encoded) conflict
        pure True
      _ -> do
        now <- currentTime db d.clockReader
        execute
          db
          "INSERT INTO impetus_local_dispatch_tasks(instance,occurrence,queue,invocation,schedule_start,available_at) VALUES(?,?,?,?,?,?) ON CONFLICT(instance,occurrence) DO NOTHING"
          (key <> [SQLText queue, SQLText encoded, bigint now, bigint now])
        rows <- query db "SELECT queue,invocation,epoch,deadline FROM impetus_local_dispatch_tasks WHERE instance=? AND occurrence=?" key
        case rows of
          [oldQueue, storedInvocation, epoch, deadline] : _ | storedInvocation == SQLText encoded -> do
            terminal <- query db "SELECT 1 FROM impetus_local_dispatch_terminals WHERE instance=? AND occurrence=?" key
            let expired = epoch == SQLInteger 0 || maybe False (<= now) (integerOf deadline)
            when (null terminal && oldQueue /= SQLText queue && expired) $
              execute db "UPDATE impetus_local_dispatch_tasks SET queue=? WHERE instance=? AND occurrence=?" (SQLText queue : key)
          _ -> conflict
        pure False
  modifyIORef' d.published (Set.insert occurrence)
  unless fenced $
    emit
      "dispatch_published"
      [ ("instance", String d.instance')
      , ("occurrence", intJson occurrence)
      , ("queue", String queue)
      , ("activity", String inv.activity)
      ]

-- | Install one durable fence, including when publication never happened.
cancel :: LocalDispatch -> CancellationInstruction -> IO CancellationDisposition
cancel d instruction = do
  encoded <- orRefuse (encodeInvocation instruction.invocation)
  let occurrence = instruction.occurrence
      key = [SQLText d.instance', intData occurrence]
      conflict = dispatchError ("Local Dispatch cancellation conflict for occurrence " <> showT occurrence)
  disposition <- withTransaction d.connections $ \db -> do
    execute
      db
      "INSERT INTO impetus_local_dispatch_cancellations(instance,occurrence,history_position,invocation) VALUES(?,?,?,?) ON CONFLICT(instance,occurrence) DO NOTHING"
      (key <> [intData instruction.historyPosition, SQLText encoded])
    inserted <- C.changes db
    cancellation <-
      query db "SELECT history_position,invocation FROM impetus_local_dispatch_cancellations WHERE instance=? AND occurrence=?" key
    unless (map (map pyData) cancellation `takeFirstIs` [PyInt (toInteger instruction.historyPosition), PyText encoded]) conflict
    task <- query db "SELECT invocation,epoch FROM impetus_local_dispatch_tasks WHERE instance=? AND occurrence=?" key
    terminal <- query db "SELECT 1 FROM impetus_local_dispatch_terminals WHERE instance=? AND occurrence=?" key
    case task of
      (stored : _) : _ | stored /= SQLText encoded -> conflict
      _ -> pure ()
    pure $ case task of
      _ | inserted == 0 -> Acknowledged
      _ | not (null terminal) -> Terminal
      [] -> Tombstoned
      [_, epoch] : _ | pyData epoch == PyInt 0 -> Retired
      _ -> Fenced
  modifyIORef' d.published (Set.insert occurrence)
  emit
    "dispatch_cancelled"
    [ ("instance", String d.instance')
    , ("occurrence", intJson occurrence)
    , ("history_position", intJson instruction.historyPosition)
    , ("disposition", String (dispositionText disposition))
    ]
  pure disposition

-- | Drain the terminal outcomes of occurrences this session published and
-- has not yet collected, in terminal insertion order.
collect :: LocalDispatch -> IO [(Int, ActivityOutcome)]
collect d = do
  eligible <- eligibleOccurrences d
  if null eligible
    then pure []
    else do
      rows <-
        withConnection d.connections $ \db ->
          query
            db
            ( "SELECT occurrence,outcome FROM impetus_local_dispatch_terminals WHERE instance=? AND occurrence IN ("
                <> marks eligible
                <> ") ORDER BY sequence"
            )
            (SQLText d.instance' : map intData eligible)
      terminals <- forM rows $ \case
        [SQLInteger occurrence, SQLText outcome] -> pure (fromIntegral occurrence, outcome)
        other -> dispatchError ("unexpected Local Dispatch terminal row " <> showT other)
      modifyIORef' d.collected (\seen -> foldr (Set.insert . fst) seen terminals)
      forM_ terminals $ \(occurrence, outcome) ->
        emit
          "dispatch_collected"
          [ ("instance", String d.instance')
          , ("occurrence", intJson occurrence)
          , ("outcome", maybe Null id (parseText outcome >>= lookupMember "kind"))
          ]
      forM terminals $ \(occurrence, outcome) -> (occurrence,) <$> orRefuse (decodeOutcome outcome)

eligibleOccurrences :: LocalDispatch -> IO [Int]
eligibleOccurrences d = do
  publishedSet <- readIORef d.published
  collectedSet <- readIORef d.collected
  pure (Set.toAscList (Set.difference publishedSet collectedSet))

-- | Construct a Worker-side provider over this database (not this
-- Instance), sharing this session's provider clock reader:
-- @dispatch.worker(queues, worker_id=...)@.
worker :: LocalDispatch -> [Text] -> Maybe Text -> IO LocalWorkerDispatch
worker d queues' label = workerWith d defaultLocalWorkerOptions {workerQueues = queues', workerId = label}

-- | 'worker' with every Worker option, such as an explicit claimant. A
-- 'workerClock' is refused when the session already has a provider clock
-- (the reference's "either clock or its dispatch clock reader").
workerWith :: LocalDispatch -> LocalWorkerOptions -> IO LocalWorkerDispatch
workerWith d options = case (options.workerClock, d.clockReader) of
  (Just _, Just _) -> dispatchError "Local Worker Dispatch accepts either clock or its dispatch clock reader"
  (Just source, Nothing) -> newClockReader source >>= openWorker (Borrowed d.connections) d.path options . Just
  (Nothing, reader) -> openWorker (Borrowed d.connections) d.path options reader

-- | Wait up to the timeout (seconds) for a collectable terminal, polling
-- every 50 ms.
waitForResults :: LocalDispatch -> Double -> IO Bool
waitForResults d timeout = do
  seconds <- checkTimeout timeout
  start <- getMonotonicTime
  let deadline = start + seconds
      loop = do
        ready <- terminalReady d
        if ready
          then pure True
          else do
            now <- getMonotonicTime
            let remaining = deadline - now
            if remaining <= 0 then pure False else sleepSeconds (min 0.05 remaining) >> loop
  loop

terminalReady :: LocalDispatch -> IO Bool
terminalReady d = do
  eligible <- eligibleOccurrences d
  if null eligible
    then pure False
    else withConnection d.connections $ \db ->
      not . null
        <$> query
          db
          ("SELECT 1 FROM impetus_local_dispatch_terminals WHERE instance=? AND occurrence IN (" <> marks eligible <> ") LIMIT 1")
          (SQLText d.instance' : map intData eligible)

-- ---------------------------------------------------------------------------
-- Worker-side custody

-- | Concrete Worker-side claims and fenced reporting across all Instances.
data LocalWorkerDispatch = LocalWorkerDispatch
  { path :: FilePath
  , queues :: [Text]
  , claimant :: Text
  , workerReader :: Maybe ClockReader
  , connections :: Pool
  , ownsConnections :: Bool
  -- ^ Whether 'close' closes the connections: a worker constructed from a
  -- session ('worker') or over shared 'LocalConnections' borrows them.
  }

-- | The keyword arguments of @LocalWorkerDispatch(path, ...)@.
data LocalWorkerOptions = LocalWorkerOptions
  { workerQueues :: [Text]
  -- ^ Validated and de-duplicated in order; at least one.
  , workerId :: Maybe Text
  -- ^ The claimant label; 'Nothing' is @"worker"@.
  , workerClock :: Maybe LocalDispatchClock
  -- ^ 'Nothing': the database clock (or the dispatch's reader, for 'workerWith').
  , explicitClaimant :: Maybe Text
  -- ^ The reference's private @_claimant@: a fixed claimant instead of
  -- @label:uuid4@, for deterministic tests. An empty text is ignored, like
  -- the reference's @_claimant or ...@.
  }

-- | @queues=("default",), worker_id=None, clock=None, _claimant=None@.
defaultLocalWorkerOptions :: LocalWorkerOptions
defaultLocalWorkerOptions =
  LocalWorkerOptions {workerQueues = ["default"], workerId = Nothing, workerClock = Nothing, explicitClaimant = Nothing}

-- | @LocalWorkerDispatch(path, ...)@.
openLocalWorkerDispatch :: FilePath -> LocalWorkerOptions -> IO LocalWorkerDispatch
openLocalWorkerDispatch file options = do
  Telemetry.validateTelemetryEnvironment
  reader <- traverse newClockReader options.workerClock
  openWorker Owned file options reader

-- | Connections to one Local Dispatch file that several workers share, such
-- as the providers a ZeroMQ Dispatch server keeps for its clients. Whoever
-- creates them closes them ('closeLocalConnections'); closing a worker
-- opened over them ('openLocalWorkerDispatchOn') leaves them open.
newtype LocalConnections = LocalConnections Pool

-- | Connections to the file, none open yet.
newLocalConnections :: FilePath -> IO LocalConnections
newLocalConnections file = LocalConnections <$> connectionPool (T.unpack (pathText file))

-- | Close the idle connections. Workers opened over them stay usable, each
-- later operation on a connection of its own. Closing twice is harmless.
closeLocalConnections :: LocalConnections -> IO ()
closeLocalConnections (LocalConnections pool) = closePool pool

-- | @LocalWorkerDispatch(path, ...)@ over shared connections to @path@.
openLocalWorkerDispatchOn :: LocalConnections -> LocalWorkerOptions -> IO LocalWorkerDispatch
openLocalWorkerDispatchOn (LocalConnections pool) options = do
  Telemetry.validateTelemetryEnvironment
  reader <- traverse newClockReader options.workerClock
  openWorker (Borrowed pool) (poolPath pool) options reader

-- | Where a worker's connections come from.
data Connections = Owned | Borrowed Pool

openWorker :: Connections -> FilePath -> LocalWorkerOptions -> Maybe ClockReader -> IO LocalWorkerDispatch
openWorker connections' given options reader = do
  let file = T.unpack (pathText given)
  validated <- mapM (`name` "queue") options.workerQueues
  let deduplicated = nub validated
  when (null deduplicated) $ dispatchError "Local Worker Dispatch requires at least one queue"
  label <- maybe (pure "worker") (`name` "worker label") options.workerId
  who <- case options.explicitClaimant of
    Just fixed | not (T.null fixed) -> pure fixed
    _ -> ((label <> ":") <>) <$> uuid4
  createDirectoryIfMissing True (takeDirectory file)
  (pool, owned) <- case connections' of
    Owned -> (,True) <$> connectionPool file
    Borrowed shared -> pure (shared, False)
  initialize pool file reader `onException` when owned (closePool pool)
  pure
    LocalWorkerDispatch
      { path = file
      , queues = deduplicated
      , claimant = who
      , workerReader = reader
      , connections = pool
      , ownsConnections = owned
      }

-- | The provider-neutral 'WorkerDispatch' surface over this provider.
toWorkerDispatch :: LocalWorkerDispatch -> WorkerDispatch
toWorkerDispatch w =
  WorkerDispatch
    { Port.claim = claim w
    , Port.heartbeat = heartbeat w
    , Port.complete = complete w
    , Port.fail = fail w
    , Port.wait = wait w
    , Port.close = close w
    }

claimableFilter :: Text
claimableFilter =
  "FROM impetus_local_dispatch_tasks t LEFT JOIN impetus_local_dispatch_terminals x \
  \USING(instance,occurrence) LEFT JOIN impetus_local_dispatch_cancellations c \
  \USING(instance,occurrence) WHERE x.occurrence IS NULL AND c.occurrence IS NULL "

-- | Claim the oldest eligible work in this worker's queues (FIFO by
-- publication across Instances), after sweeping expired and exhausted
-- leases. 'Nothing' when nothing is claimable now.
claim :: LocalWorkerDispatch -> IO (Maybe ActivityAttempt)
claim w = do
  (expired, attempt) <- withTransaction w.connections $ \db -> do
    now <- currentTime db w.workerReader
    expired <- terminalizeExhausted db now w.queues
    rows <-
      query
        db
        ( "SELECT t.instance,t.occurrence,t.queue,t.invocation,t.epoch,t.details "
            <> claimableFilter
            <> "AND t.queue IN ("
            <> marks w.queues
            <> ") AND t.epoch < json_extract(t.invocation,'$.policy.attempts') AND t.available_at<=? AND (t.epoch=0 OR t.deadline<=?) ORDER BY t.sequence LIMIT 1"
        )
        (map SQLText w.queues <> [bigint now, bigint now])
    attempt <- case rows of
      [] -> pure Nothing
      [SQLText inst, SQLInteger occurrence, SQLText queue, SQLText encoded, SQLInteger prior, details] : _ -> do
        inv <- orRefuse (decodeInvocation encoded)
        let epoch = toInteger prior + 1
            fields = policyFields inv.policy
            key = [SQLText inst, SQLInteger occurrence]
        scheduleDeadline <- case fields.scheduleToClose of
          Nothing -> pure Nothing
          Just limit -> do
            start <- query db "SELECT schedule_start FROM impetus_local_dispatch_tasks WHERE instance=? AND occurrence=?" key
            case start of
              [SQLInteger s] : _ -> pure (Just (toInteger s + milliseconds limit))
              _ -> dispatchError "Local Dispatch task lost its schedule start"
        let hardLimits = catMaybes [(now +) . milliseconds <$> fields.startToClose, scheduleDeadline]
            attemptDeadline = if null hardLimits then Nothing else Just (minimum hardLimits)
            deadline = minimum ((now + fields.heartbeatTimeout * 1000) : hardLimits)
        execute
          db
          "UPDATE impetus_local_dispatch_tasks SET epoch=?,claimant=?,deadline=?,attempt_start=?,attempt_deadline=? WHERE instance=? AND occurrence=?"
          ([bigint epoch, SQLText w.claimant, bigint deadline, bigint now, maybe SQLNull bigint attemptDeadline] <> key)
        latest <- orRefuse (jsonColumn details)
        attempt <-
          orRefuse
            ( activityAttempt
                (attemptIdOf inst (fromIntegral occurrence))
                (showT epoch)
                w.claimant
                queue
                inv
                latest
                (Just inst)
            )
        pure (Just attempt)
      other : _ -> dispatchError ("unexpected Local Dispatch task row " <> showT other)
    pure (expired, attempt)
  emitExpired expired
  forM_ attempt $ \a -> emitAttempt "dispatch_claimed" a []
  pure attempt

-- | Renew the lease (capped by the attempt's hard deadline) and, when
-- details are supplied, replace the latest heartbeat details. 'Nothing' is
-- the reference's omitted @details@ and preserves them; @Just Null@
-- replaces them with JSON null. Answers the latest details.
heartbeat :: LocalWorkerDispatch -> ActivityAttempt -> Maybe Json -> IO Json
heartbeat w attempt details = do
  encoded <- forM details $ \value -> do
    snapshot <- orRefuse (snapshotHeartbeatDetails value)
    orRefuse (encodeJson "heartbeat details" snapshot)
  latest <- withTransaction w.connections $ \db -> do
    now <- currentTime db w.workerReader
    task <- active db attempt now
    inv <- orRefuse (decodeInvocation task.storedInvocation)
    (inst, occurrence) <- attemptKey attempt
    let timeout = (policyFields inv.policy).heartbeatTimeout
        renewed = now + timeout * 1000
        deadline = case task.attemptDeadline of
          SQLInteger hard -> min renewed (toInteger hard)
          _ -> renewed
        key = [SQLText inst, intData occurrence]
    case encoded of
      Nothing -> do
        execute db "UPDATE impetus_local_dispatch_tasks SET deadline=? WHERE instance=? AND occurrence=?" (bigint deadline : key)
        orRefuse (jsonColumn task.details)
      Just text -> do
        execute db "UPDATE impetus_local_dispatch_tasks SET deadline=?,details=? WHERE instance=? AND occurrence=?" ([bigint deadline, SQLText text] <> key)
        orRefuse (parseColumn text)
  emitAttempt "dispatch_heartbeat" attempt []
  pure latest

-- | Report a completed result. An exact repeat of an accepted terminal is
-- acknowledged; a different one is a conflict. A fenced claimant's report
-- for a cancelled occurrence is accepted once, for canonical quarantine.
complete :: LocalWorkerDispatch -> ActivityAttempt -> Json -> IO ()
complete w attempt result = do
  faithful <- orRefuse (faithfulJson "Activity result" result)
  terminalReport w attempt (Object [("kind", String "completed"), ("value", faithful)])

-- | Report a failure. A message is a non-retryable @ActivityError@ that
-- nevertheless retries (the reference's legacy string behavior); a caught
-- exception is retryable, spelled as its @repr@ with its type name as the
-- kind; a classified failure is used as-is. A retryable failure with
-- attempts left (and before the schedule deadline) ends the lease and
-- schedules the retry after the policy delay or @retry_after@, whichever
-- is longer; otherwise the failure is terminal.
fail :: LocalWorkerDispatch -> ActivityAttempt -> AttemptFailure -> IO ()
fail w attempt report = do
  let legacyRetryable = case report of
        FailureMessage _ -> True
        _ -> False
  failure <- case report of
    FailureClassified classified -> pure classified
    FailureMessage message -> orRefuse (activityFailure (ActivityFailureFields message "ActivityError" Null False Nothing))
    FailureException err ->
      let python = pythonException err
       in orRefuse (activityFailure (ActivityFailureFields (pythonExceptionRepr python) python.name Null True Nothing))
  let outcome = failedOutcome failure
  disposition <- withTransaction w.connections $ \db -> do
    acknowledged <- acknowledgeTerminalRetry db attempt outcome
    if acknowledged
      then pure "terminal-retry"
      else do
        cancelled <- cancelledAttempt db attempt
        if cancelled
          then insertTerminal db attempt outcome >> pure "cancelled-report"
          else do
            now <- currentTime db w.workerReader
            _ <- active db attempt now
            (inst, occurrence) <- attemptKey attempt
            let key = [SQLText inst, intData occurrence]
            attemptsRows <-
              query db "SELECT json_extract(invocation,'$.policy.attempts') FROM impetus_local_dispatch_tasks WHERE instance=? AND occurrence=?" key
            taskRows <- query db "SELECT schedule_start FROM impetus_local_dispatch_tasks WHERE instance=? AND occurrence=?" key
            let fields = policyFields attempt.invocation.policy
                failureInfo = failureFields failure
            epoch <- orRefuse (pyInt attempt.epoch)
            scheduleDeadline <- case fields.scheduleToClose of
              Nothing -> pure Nothing
              Just limit -> case taskRows of
                [SQLInteger s] : _ -> pure (Just (toInteger s + milliseconds limit))
                _ -> dispatchError "Local Dispatch task lost its schedule start"
            policyDelay <- orRefuse (retryDelay (policyRetryPolicy attempt.invocation.policy) epoch)
            let floor' = maybe 0 (\after -> if after == 0 then 0 else after) failureInfo.failureRetryAfter
                delay = if floor' > policyDelay then floor' else policyDelay
                available = now + milliseconds delay
                attemptsLeft = case attemptsRows of
                  [SQLInteger n] : _ -> epoch < toInteger n
                  _ -> False
                beforeSchedule = maybe True (available <) scheduleDeadline
            if (failureInfo.failureRetryable || legacyRetryable) && attemptsLeft && beforeSchedule
              then do
                -- Keep epoch as the fence and make the failed lease
                -- immediately claimable. The next claim increments it.
                execute
                  db
                  "UPDATE impetus_local_dispatch_tasks SET deadline=?,available_at=? WHERE instance=? AND occurrence=?"
                  ([bigint now, bigint available] <> key)
                pure "retryable"
              else insertTerminal db attempt outcome >> pure "terminal"
  emitAttempt "dispatch_failed" attempt [("outcome", String disposition)]

terminalReport :: LocalWorkerDispatch -> ActivityAttempt -> Json -> IO ()
terminalReport w attempt outcome = do
  disposition <- withTransaction w.connections $ \db -> do
    acknowledged <- acknowledgeTerminalRetry db attempt outcome
    if acknowledged
      then pure "terminal-retry"
      else do
        cancelled <- cancelledAttempt db attempt
        if cancelled
          then insertTerminal db attempt outcome >> pure "cancelled-report"
          else do
            now <- currentTime db w.workerReader
            _ <- active db attempt now
            insertTerminal db attempt outcome
            pure "terminal"
  emitAttempt "dispatch_completed" attempt [("outcome", String disposition)]

insertTerminal :: Connection -> ActivityAttempt -> Json -> IO ()
insertTerminal db attempt outcome = do
  (inst, occurrence) <- attemptKey attempt
  epoch <- orRefuse (pyInt attempt.epoch)
  encoded <- orRefuse (encodeJson "outcome" outcome)
  execute
    db
    "INSERT INTO impetus_local_dispatch_terminals(instance,occurrence,epoch,claimant,outcome) VALUES(?,?,?,?,?)"
    [SQLText inst, intData occurrence, bigint epoch, SQLText attempt.claimant, SQLText encoded]

-- | Wait up to the timeout (seconds) for claimable work in this worker's
-- queues, sweeping expired leases on every poll (every 50 ms).
wait :: LocalWorkerDispatch -> Double -> IO Bool
wait w timeout = do
  seconds <- checkTimeout timeout
  start <- getMonotonicTime
  let deadline = start + seconds
      loop = do
        (expired, ready) <- withTransaction w.connections $ \db -> do
          now <- currentTime db w.workerReader
          expired <- terminalizeExhausted db now w.queues
          rows <-
            query
              db
              ( "SELECT 1 "
                  <> claimableFilter
                  <> "AND t.queue IN ("
                  <> marks w.queues
                  <> ") AND t.epoch < json_extract(t.invocation,'$.policy.attempts') AND t.available_at<=? AND (t.epoch=0 OR t.deadline<=?) LIMIT 1"
              )
              (map SQLText w.queues <> [bigint now, bigint now])
          pure (expired, not (null rows))
        emitExpired expired
        if ready
          then pure True
          else do
            now <- getMonotonicTime
            let remaining = deadline - now
            if remaining <= 0 then pure False else sleepSeconds (min 0.05 remaining) >> loop
  loop

-- | Close the worker's idle connections, unless it borrows them from a
-- session or from shared 'LocalConnections'. The worker stays usable, as
-- the reference's does after @close()@: each later operation opens and
-- closes a connection of its own.
close :: LocalWorkerDispatch -> IO ()
close w = when w.ownsConnections (closePool w.connections)

-- ---------------------------------------------------------------------------
-- Fences

-- | @_active@: the exact live lease, or "stale Activity attempt".
-- | The columns of a live attempt's task row its callers read.
data ActiveTask = ActiveTask
  { storedInvocation :: Text
  , details :: SQLData
  , attemptDeadline :: SQLData
  }

active :: Connection -> ActivityAttempt -> Integer -> IO ActiveTask
active db attempt now = do
  (inst, occurrence) <- attemptKey attempt
  let key = [SQLText inst, intData occurrence]
  rows <-
    query
      db
      "SELECT queue,invocation,epoch,claimant,deadline,details,attempt_deadline FROM impetus_local_dispatch_tasks WHERE instance=? AND occurrence=?"
      key
  terminal <- query db "SELECT 1 FROM impetus_local_dispatch_terminals WHERE instance=? AND occurrence=?" key
  cancelled <- query db "SELECT 1 FROM impetus_local_dispatch_cancellations WHERE instance=? AND occurrence=?" key
  encoded <- orRefuse (encodeInvocation attempt.invocation)
  case rows of
    [queue, SQLText stored, epoch, who, deadline, details, attemptDeadline] : _
      | null terminal
      , null cancelled
      , queue == SQLText attempt.queue
      , stored == encoded
      , dataStr epoch == attempt.epoch
      , who == SQLText attempt.claimant
      , Just expiry <- integerOf deadline
      , expiry > now ->
          pure ActiveTask {storedInvocation = stored, details, attemptDeadline}
    _ -> stale attempt

-- | @_cancelled_attempt@: validate the exact fenced claimant before
-- accepting its report for canonical quarantine (lease expiry is not
-- checked).
cancelledAttempt :: Connection -> ActivityAttempt -> IO Bool
cancelledAttempt db attempt = do
  (inst, occurrence) <- attemptKey attempt
  let key = [SQLText inst, intData occurrence]
  cancelled <- query db "SELECT 1 FROM impetus_local_dispatch_cancellations WHERE instance=? AND occurrence=?" key
  if null cancelled
    then pure False
    else do
      rows <- query db "SELECT queue,invocation,epoch,claimant FROM impetus_local_dispatch_tasks WHERE instance=? AND occurrence=?" key
      encoded <- orRefuse (encodeInvocation attempt.invocation)
      epoch <- orRefuse (pyInt attempt.epoch)
      case rows of
        row : _
          | map pyData row == [PyText attempt.queue, PyText encoded, PyInt epoch, PyText attempt.claimant] ->
              pure True
        _ -> stale attempt

-- | @_acknowledge_terminal_retry@.
acknowledgeTerminalRetry :: Connection -> ActivityAttempt -> Json -> IO Bool
acknowledgeTerminalRetry db attempt outcome = do
  (inst, occurrence) <- attemptKey attempt
  rows <-
    query
      db
      "SELECT epoch,claimant,outcome FROM impetus_local_dispatch_terminals WHERE instance=? AND occurrence=?"
      [SQLText inst, intData occurrence]
  case rows of
    [] -> pure False
    row : _ -> do
      encoded <- orRefuse (encodeJson "outcome" outcome)
      epoch <- orRefuse (pyInt attempt.epoch)
      if map pyData row == [PyInt epoch, PyText attempt.claimant, PyText encoded]
        then pure True
        else dispatchError ("conflicting terminal report for Activity attempt " <> attempt.attemptId)

stale :: ActivityAttempt -> IO a
stale attempt = dispatchError ("stale Activity attempt " <> attempt.attemptId)

-- | @_attempt_id@: @["instance",occurrence]@, compact, not ASCII-escaped.
attemptIdOf :: Text -> Int -> Text
attemptIdOf inst occurrence =
  either (const "") id (dumpsText compact (Array [String inst, intJson occurrence]))

-- | @_attempt_key@.
attemptKey :: ActivityAttempt -> IO (Text, Int)
attemptKey attempt =
  case parseText attempt.attemptId of
    Just (Array [String inst, Int occurrence])
      | not (T.null inst)
      , not (T.any (== '\NUL') inst)
      , occurrence >= 1
      , occurrence <= toInteger (maxBound :: Int)
      , attempt.instance' == Just inst ->
          pure (inst, fromInteger occurrence)
    _ -> dispatchError ("invalid Local Activity attempt identity " <> pythonStrRepr attempt.attemptId)

-- | @_terminalize_exhausted@: the lease sweep every claim and wait runs.
-- An expired retryable lease becomes delayed work (backoff anchored at the
-- durable lease expiry) before another claimant can see it; an exhausted or
-- schedule-expired task becomes a @DeadlineExceeded@ terminal.
terminalizeExhausted :: Connection -> Integer -> [Text] -> IO [(Text, Int64, Int64, Maybe Text)]
terminalizeExhausted db now queues' = do
  let queueParams = map SQLText queues'
  retryable <-
    query
      db
      ( "SELECT t.instance,t.occurrence,t.epoch,t.deadline,t.invocation FROM impetus_local_dispatch_tasks t \
        \LEFT JOIN impetus_local_dispatch_terminals x USING(instance,occurrence) \
        \LEFT JOIN impetus_local_dispatch_cancellations c USING(instance,occurrence) \
        \WHERE x.occurrence IS NULL AND c.occurrence IS NULL AND t.queue IN ("
          <> marks queues'
          <> ") AND t.epoch>0 AND t.deadline<=? AND t.epoch<json_extract(t.invocation,'$.policy.attempts')"
      )
      (queueParams <> [bigint now])
  forM_ retryable $ \case
    [inst, occurrence, SQLInteger epoch, SQLInteger expiry, SQLText encoded] -> do
      inv <- orRefuse (decodeInvocation encoded)
      delay <- orRefuse (retryDelay (policyRetryPolicy inv.policy) (toInteger epoch))
      let available = toInteger expiry + milliseconds delay
      execute db "UPDATE impetus_local_dispatch_tasks SET available_at=? WHERE instance=? AND occurrence=?" [bigint available, inst, occurrence]
    other -> dispatchError ("unexpected Local Dispatch task row " <> showT other)
  rows <-
    query
      db
      ( "SELECT t.instance,t.occurrence,t.epoch,t.claimant FROM impetus_local_dispatch_tasks t \
        \LEFT JOIN impetus_local_dispatch_terminals x USING(instance,occurrence) \
        \LEFT JOIN impetus_local_dispatch_cancellations c USING(instance,occurrence) \
        \WHERE x.occurrence IS NULL AND c.occurrence IS NULL AND t.queue IN ("
          <> marks queues'
          <> ") AND ((t.epoch>0 AND t.deadline<=? AND t.epoch>=json_extract(t.invocation,'$.policy.attempts')) OR \
             \(json_extract(t.invocation,'$.policy.schedule_to_close') IS NOT NULL AND \
             \t.schedule_start + CAST(json_extract(t.invocation,'$.policy.schedule_to_close')*1000 AS INTEGER) + \
             \(json_extract(t.invocation,'$.policy.schedule_to_close')*1000 > \
             \CAST(json_extract(t.invocation,'$.policy.schedule_to_close')*1000 AS INTEGER)) <= ?))"
      )
      (queueParams <> [bigint now, bigint now])
  forM rows $ \case
    [SQLText inst, SQLInteger occurrence, SQLInteger epoch, who] -> do
      let noun = if epoch == 1 then "attempt" else "attempts"
      failure <-
        orRefuse
          ( activityFailure
              (ActivityFailureFields ("Local Dispatch deadline exhausted after " <> showT epoch <> " " <> noun) "DeadlineExceeded" Null False Nothing)
          )
      encoded <- orRefuse (encodeJson "outcome" (failedOutcome failure))
      execute
        db
        "INSERT OR IGNORE INTO impetus_local_dispatch_terminals(instance,occurrence,epoch,claimant,outcome) VALUES(?,?,?,?,?)"
        [SQLText inst, SQLInteger occurrence, SQLInteger epoch, who, SQLText encoded]
      pure (inst, occurrence, epoch, case who of SQLText t -> Just t; _ -> Nothing)
    other -> dispatchError ("unexpected Local Dispatch task row " <> showT other)

-- ---------------------------------------------------------------------------
-- Opening, migration, shape validation

-- | @_initialize@: create, migrate, or validate the schema on a raw
-- connection, then make sure the file is in WAL mode (@with _connect(path)@),
-- leaving that connection in the pool. As in the reference, the raw
-- connection is still open while the WAL connection opens, so closing it is
-- not the last close of the file.
initialize :: Pool -> FilePath -> Maybe ClockReader -> IO ()
initialize pool file reader = do
  createDirectoryIfMissing True (takeDirectory file)
  C.withConnection rawProfile file $ \db -> do
    C.withImmediateTransaction db (opening db)
    withConnection pool (\_ -> pure ())
  where
    shown = pathText file
    refuse message = dispatchError (shown <> ": " <> message)
    opening db = do
      objectRows <- query db "SELECT name,type FROM sqlite_master WHERE name LIKE ?" [SQLText (tablePrefix <> "%")]
      let objects = Map.fromList [(k, v) | [SQLText k, SQLText v] <- objectRows] :: Map Text Text
      if Map.null objects
        then mapM_ (\statement -> execute db statement []) ddl
        else do
          let v2Objects =
                Map.fromList
                  [ ("impetus_local_dispatch_schema", "table")
                  , ("impetus_local_dispatch_tasks", "table")
                  , ("impetus_local_dispatch_claimable", "index")
                  , ("impetus_local_dispatch_terminals", "table")
                  ]
              currentObjects = Map.insert "impetus_local_dispatch_cancellations" "table" v2Objects
          unless (objects == v2Objects || objects == currentObjects) $
            refuse "foreign or unversioned Local Dispatch schema; migration is not supported"
          rows0 <- query db "SELECT component,version FROM impetus_local_dispatch_schema" []
          let isVersion n rows = map (map pyData) rows == [[PyText "dispatch", PyInt n]]
              versionRows n = [[SQLText "dispatch", SQLInteger n]]
          rows1 <-
            if isVersion 1 rows0
              then do
                migrateV1 db reader
                execute db "UPDATE impetus_local_dispatch_schema SET version=2 WHERE component='dispatch'" []
                pure (versionRows 2)
              else pure rows0
          rows2 <-
            if isVersion 2 rows1
              then do
                when (objects /= v2Objects) $ refuse "foreign Local Dispatch schema-2 shape"
                execute db cancellationsTable []
                execute db "UPDATE impetus_local_dispatch_schema SET version=3 WHERE component='dispatch'" []
                pure (versionRows 3)
              else pure rows1
          unless (isVersion (toInteger schemaVersion) rows2) $
            refuse ("unsupported Local Dispatch schema " <> reprRows rows2 <> "; migration is not supported")
          validateShape db shown

validateShape :: Connection -> Text -> IO ()
validateShape db shown = do
  let expectedSql =
        Map.fromList
          [ ("impetus_local_dispatch_schema", schemaTable)
          , ("impetus_local_dispatch_tasks", tasksTable)
          , ("impetus_local_dispatch_claimable", claimableIndex)
          , ("impetus_local_dispatch_terminals", terminalsTable)
          , ("impetus_local_dispatch_cancellations", cancellationsTable)
          ]
      refuse message = dispatchError (shown <> ": " <> message)
      normalize = T.toLower . T.unwords . T.words
  actualRows <- query db "SELECT name,sql FROM sqlite_master WHERE name IN (?,?,?,?,?)" (map SQLText (Map.keys expectedSql))
  let actualSql = Map.fromList [(k, case v of SQLText s -> Just (normalize s); _ -> Nothing) | [SQLText k, v] <- actualRows]
  unless (actualSql == Map.map (Just . normalize) expectedSql) $
    refuse "foreign current-version Local Dispatch DDL shape"
  let column n t notnull dflt pk = [PyText n, PyText t, PyInt notnull, maybe PyNone PyText dflt, PyInt pk]
      expectedColumns =
        [ ("impetus_local_dispatch_schema", [column "component" "TEXT" 0 Nothing 1, column "version" "INTEGER" 1 Nothing 0])
        ,
          ( "impetus_local_dispatch_tasks"
          ,
            [ column "sequence" "INTEGER" 0 Nothing 1
            , column "instance" "TEXT" 1 Nothing 0
            , column "occurrence" "INTEGER" 1 Nothing 0
            , column "queue" "TEXT" 1 Nothing 0
            , column "invocation" "TEXT" 1 Nothing 0
            , column "epoch" "INTEGER" 1 (Just "0") 0
            , column "claimant" "TEXT" 0 Nothing 0
            , column "deadline" "INTEGER" 0 Nothing 0
            , column "schedule_start" "INTEGER" 1 Nothing 0
            , column "attempt_start" "INTEGER" 0 Nothing 0
            , column "attempt_deadline" "INTEGER" 0 Nothing 0
            , column "available_at" "INTEGER" 1 Nothing 0
            , column "details" "TEXT" 0 Nothing 0
            ]
          )
        ,
          ( "impetus_local_dispatch_terminals"
          ,
            [ column "sequence" "INTEGER" 0 Nothing 1
            , column "instance" "TEXT" 1 Nothing 0
            , column "occurrence" "INTEGER" 1 Nothing 0
            , column "epoch" "INTEGER" 1 Nothing 0
            , column "claimant" "TEXT" 0 Nothing 0
            , column "outcome" "TEXT" 1 Nothing 0
            ]
          )
        ,
          ( "impetus_local_dispatch_cancellations"
          ,
            [ column "instance" "TEXT" 1 Nothing 1
            , column "occurrence" "INTEGER" 1 Nothing 2
            , column "history_position" "INTEGER" 1 Nothing 0
            , column "invocation" "TEXT" 1 Nothing 0
            ]
          )
        ]
  forM_ expectedColumns $ \(table, expected) -> do
    info <- query db ("PRAGMA table_info(" <> table <> ")") []
    let actual = [map pyData (take 5 (drop 1 row)) | row <- info]
    unless (actual == expected) $
      refuse ("foreign current-version Local Dispatch table shape for " <> table)
  index <- query db "PRAGMA index_info(impetus_local_dispatch_claimable)" []
  foreign' <- query db "PRAGMA foreign_key_list(impetus_local_dispatch_terminals)" []
  let foreignRow from' to' = map PyText ["impetus_local_dispatch_tasks", from', to', "NO ACTION", "NO ACTION", "NONE"]
      indexColumns = [map pyData (take 1 (drop 2 row)) | row <- index]
      foreignColumns = [map pyData (take 6 (drop 2 row)) | row <- foreign']
  unless
    ( indexColumns == [[PyText "queue"], [PyText "sequence"]]
        && foreignColumns == [foreignRow "instance" "instance", foreignRow "occurrence" "occurrence"]
    )
    $ refuse "foreign current-version Local Dispatch constraint or index shape"

-- | @_migrate_v1@: transactionally rebuild the real v1 column order into
-- the exact v2 DDL.
migrateV1 :: Connection -> Maybe ClockReader -> IO ()
migrateV1 db reader = do
  now <- currentTime db reader
  tasks <-
    query db "SELECT sequence,instance,occurrence,queue,invocation,epoch,claimant,deadline,details FROM impetus_local_dispatch_tasks ORDER BY sequence" []
  terminalRows <-
    query db "SELECT sequence,instance,occurrence,epoch,claimant,outcome FROM impetus_local_dispatch_terminals ORDER BY sequence" []
  terminals <- forM terminalRows $ \case
    [sequence', inst, occurrence, epoch, who, SQLText encoded] -> do
      outcome <- orRefuse (parseColumn encoded)
      rewritten <- case outcome of
        Object _
          | lookupMember "kind" outcome == Just (String "failed")
          , Just err <- lookupMember "error" outcome -> do
              message <- case err of
                String m -> pure m
                _ -> dispatchError "ActivityFailure error must be a non-empty string of at most 4096 characters"
              failure <- orRefuse (activityFailure (ActivityFailureFields message "ActivityError" Null False Nothing))
              pure (failedOutcome failure)
        _ -> pure outcome
      text <- orRefuse (encodeJson "outcome" rewritten)
      pure [sequence', inst, occurrence, epoch, who, SQLText text]
    other -> dispatchError ("unexpected Local Dispatch v1 terminal row " <> showT other)
  execute db "DROP TABLE impetus_local_dispatch_terminals" []
  execute db "DROP INDEX impetus_local_dispatch_claimable" []
  execute db "DROP TABLE impetus_local_dispatch_tasks" []
  execute db tasksTable []
  execute db claimableIndex []
  execute db terminalsTable []
  forM_ tasks $ \case
    [sequence', inst, occurrence, queue, SQLText encoded, epoch, who, deadline, details] -> do
      canonical <- orRefuse (decodeInvocation encoded >>= encodeInvocation)
      let claimed = case epoch of
            SQLInteger 0 -> False
            SQLNull -> False
            _ -> True
      execute
        db
        "INSERT INTO impetus_local_dispatch_tasks(sequence,instance,occurrence,queue,invocation,epoch,claimant,deadline,schedule_start,attempt_start,attempt_deadline,available_at,details) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)"
        [ sequence'
        , inst
        , occurrence
        , queue
        , SQLText canonical
        , epoch
        , who
        , deadline
        , bigint now
        , if claimed then bigint now else SQLNull
        , SQLNull
        , bigint now
        , details
        ]
    other -> dispatchError ("unexpected Local Dispatch v1 task row " <> showT other)
  forM_ terminals $
    execute db "INSERT INTO impetus_local_dispatch_terminals(sequence,instance,occurrence,epoch,claimant,outcome) VALUES(?,?,?,?,?,?)"

-- ---------------------------------------------------------------------------
-- Connections

-- | @_raw_connect@: a connection with the reference's pragmas, before WAL.
rawProfile :: C.Profile
rawProfile = C.localDispatchProfile {C.setup = [step | step@(C.Pragma _) <- C.localDispatchProfile.setup]}

-- | @_connect@: a raw connection switched to WAL, retrying a locked
-- database every 10 ms for up to 5 s.
connect :: FilePath -> IO Connection
connect file =
  C.open C.localDispatchProfile file `catch` \(_ :: C.WalRefused) ->
    dispatchError (pathText file <> ": SQLite refused WAL mode")

-- | How many idle connections a session keeps open between operations.
idleConnections :: Int
idleConnections = 4

-- | A pool of '_connect' connections to the file.
connectionPool :: FilePath -> IO Pool
connectionPool file = newPool idleConnections file (connect file)

-- | One operation's connection: a pooled @_connect@ connection with the
-- reference's pragmas, used by this operation alone.
withConnection :: Pool -> (Connection -> IO a) -> IO a
withConnection = withPooledConnection

-- | @_transaction@: one @BEGIN IMMEDIATE@ transaction on the operation's
-- connection, committed on success and rolled back on any exception.
withTransaction :: Pool -> (Connection -> IO a) -> IO a
withTransaction pool body =
  withConnection pool $ \db -> C.withImmediateTransaction db (body db)

query :: Connection -> Text -> [SQLData] -> IO [[SQLData]]
query = C.query

execute :: Connection -> Text -> [SQLData] -> IO ()
execute db sql params = void (C.execute db sql params)

marks :: [a] -> Text
marks items = T.intercalate "," (map (const "?") items)

-- | @_now@: the provider clock when one is configured, else the database
-- clock, sampled inside the transaction.
currentTime :: Connection -> Maybe ClockReader -> IO Integer
currentTime db = \case
  Just reader -> sampleClock reader
  Nothing ->
    query db "SELECT CAST(strftime('%s','now') AS INTEGER) * 1000 + CAST(substr(strftime('%f','now'),4,3) AS INTEGER)" [] >>= \case
      [SQLInteger now] : _ -> pure (toInteger now)
      other -> dispatchError ("unexpected database clock " <> showT other)

-- ---------------------------------------------------------------------------
-- Encodings

-- | @_encode_json@: sorted keys, compact separators, no ASCII escaping;
-- what @json.dumps@ refuses (non-finite numbers, integers past CPython's
-- 4300-digit limit) is refused with the reference's message.
encodeJson :: Text -> Json -> Either Text Text
encodeJson noun value = case canonicalText value of
  Right text -> Right text
  Left refusal -> Left (noun <> " must be JSON-faithful: " <> T.pack (encodeErrorMessage refusal))

-- | @_faithful@: the value as it round-trips through its canonical text.
faithfulJson :: Text -> Json -> Either Text Json
faithfulJson noun value = encodeJson noun value >>= parseColumn

-- | @_encode_invocation@.
encodeInvocation :: ActivityInvocation -> Either Text Text
encodeInvocation = encodeJson "Activity invocation" . invocationJson

-- | @_decode_invocation@ ('invocationFromJson'); every refusal is prefixed
-- "corrupt durable Activity invocation: ".
decodeInvocation :: Text -> Either Text ActivityInvocation
decodeInvocation text = either (Left . ("corrupt durable Activity invocation: " <>)) Right $ do
  value <- either (Left . T.pack) Right (parseJson surrogateRefusingLoads (TE.encodeUtf8 text))
  either (Left . refusal) Right (invocationFromJson value)
  where
    refusal problem = flip fromMaybe (invocationRefusal pythonRepr problem) $ case problem of
      InvocationFieldsNotExact -> "expected exact fields ['activity', 'correlation', 'idempotency', 'input', 'policy']"
      PolicyFieldsNotExact -> "policy expected exact legacy or current fields"
      _ -> "policy fields must be integers"

-- | @_decode_outcome@: a completed value, or the classified failure (the
-- legacy @{"kind":"failed","error":E}@ shape included).
decodeOutcome :: Text -> Either Text ActivityOutcome
decodeOutcome text = do
  value <- parseColumn text
  case lookupMember "kind" value of
    Just (String "completed") -> Right (Succeeded (maybe Null id (lookupMember "value" value)))
    _ -> case lookupMember "failure" value of
      Just (Object members) -> Failed <$> failureFromMembers members
      Just _ -> Left "ActivityFailure fields must be a mapping"
      Nothing -> Failed <$> failureFromMembers [("error", maybe Null id (lookupMember "error" value))]

failureFromMembers :: [(Text, Json)] -> Either Text ActivityFailure
failureFromMembers members = do
  forM_ members $ \(key, _) ->
    unless (key `elem` ["error", "kind", "details", "retryable", "retry_after"]) $
      Left ("ActivityFailure.__init__() got an unexpected keyword argument " <> pythonStrRepr key)
  let errorText = case lookup "error" members of
        Just (String e) -> e
        _ -> ""
      kindText = case lookup "kind" members of
        Nothing -> Just "ActivityError"
        Just (String k) -> Just k
        Just _ -> Nothing
  retryable <- case lookup "retryable" members of
    Nothing -> Right False
    Just (Bool r) -> Right r
    Just _ -> Left "ActivityFailure retryable must be bool"
  retryAfter <- case lookup "retry_after" members of
    Nothing -> Right Nothing
    Just Null -> Right Nothing
    Just raw -> Right (Just (maybe (FloatNumber (0 / 0)) id (numberFromJson raw)))
  activityFailure
    ActivityFailureFields
      { failureError = errorText
      , failureKind = maybe "" id kindText
      , failureDetails = maybe Null id (lookup "details" members)
      , failureRetryable = retryable
      , failureRetryAfter = retryAfter
      }

failedOutcome :: ActivityFailure -> Json
failedOutcome failure = Object [("kind", String "failed"), ("failure", failureJson failure)]

parseColumn :: Text -> Either Text Json
parseColumn text = either (Left . T.pack) Right (parseJson surrogateRefusingLoads (TE.encodeUtf8 text))

parseText :: Text -> Maybe Json
parseText = either (const Nothing) Just . parseColumn

-- | @_json@: SQL NULL is JSON null.
jsonColumn :: SQLData -> Either Text Json
jsonColumn = \case
  SQLNull -> Right Null
  SQLText text -> parseColumn text
  other -> Left ("unexpected Local Dispatch details " <> showT other)

-- | @_milliseconds@: seconds to milliseconds, sub-millisecond values
-- rounding up.
milliseconds :: Number -> Integer
milliseconds = \case
  IntNumber seconds -> if seconds > 0 then seconds * 1000 else 0
  FloatNumber seconds -> if seconds > 0 then ceiling (seconds * 1000) else 0

-- ---------------------------------------------------------------------------
-- Validation

-- | @_name@.
name :: Text -> Text -> IO Text
name value noun
  | T.null value || T.any (== '\NUL') value =
      dispatchError ("Local Dispatch " <> noun <> " must be a non-empty string without NUL")
  | otherwise = pure value

-- | @_occurrence@.
checkOccurrence :: Int -> IO ()
checkOccurrence occurrence =
  when (occurrence < 1) $ dispatchError "Local Dispatch occurrence must be a positive integer"

-- | @_timeout@.
checkTimeout :: Double -> IO Double
checkTimeout value
  | value < 0 = dispatchError "wait timeout must be a non-negative number"
  | otherwise = pure value

-- | Python's @int(text)@ for an attempt epoch.
pyInt :: Text -> Either Text Integer
pyInt text =
  let stripped = T.strip text
      (sign, digits) = case T.uncons stripped of
        Just ('-', rest) -> (-1, rest)
        Just ('+', rest) -> (1, rest)
        _ -> (1, stripped)
      groups = T.splitOn "_" digits
   in if not (T.null digits) && all (\g -> not (T.null g) && T.all isDigit g) groups
        then Right (sign * read (T.unpack (T.concat groups)))
        else Left ("invalid literal for int() with base 10: " <> pythonStrRepr text)

orRefuse :: Either Text a -> IO a
orRefuse = either dispatchError pure

-- ---------------------------------------------------------------------------
-- Values

-- | A Python value as @sqlite3@ answers it, compared with Python equality.
data PyValue = PyInt Integer | PyFloat Double | PyText Text | PyBytes BS.ByteString | PyNone
  deriving stock (Show)

instance Eq PyValue where
  PyInt a == PyInt b = a == b
  PyFloat a == PyFloat b = a == b
  PyInt a == PyFloat b = not (isNaN b || isInfinite b) && toRational b == fromInteger a
  PyFloat a == PyInt b = PyInt b == PyFloat a
  PyText a == PyText b = a == b
  PyBytes a == PyBytes b = a == b
  PyNone == PyNone = True
  _ == _ = False

pyData :: SQLData -> PyValue
pyData = \case
  SQLInteger i -> PyInt (toInteger i)
  SQLFloat d -> PyFloat d
  SQLText t -> PyText t
  SQLBlob b -> PyBytes b
  SQLNull -> PyNone

takeFirstIs :: [[PyValue]] -> [PyValue] -> Bool
takeFirstIs rows expected = case rows of
  row : _ -> row == expected
  [] -> False

-- | @repr(rows)@ of a list of @sqlite3@ row tuples.
reprRows :: [[SQLData]] -> Text
reprRows rows = "[" <> T.intercalate ", " (map tuple rows) <> "]"
  where
    tuple = \case
      [single] -> "(" <> value single <> ",)"
      items -> "(" <> T.intercalate ", " (map value items) <> ")"
    value = \case
      SQLInteger i -> showT i
      SQLFloat d -> pythonRepr (Float d)
      SQLText t -> pythonStrRepr t
      SQLBlob b -> "b" <> pythonStrRepr (TE.decodeLatin1 b)
      SQLNull -> "None"

-- | The integer value of a column, if it holds one.
integerOf :: SQLData -> Maybe Integer
integerOf = \case
  SQLInteger i -> Just (toInteger i)
  _ -> Nothing

-- | @str(column)@ for an integer epoch.
dataStr :: SQLData -> Text
dataStr = \case
  SQLInteger i -> showT i
  SQLText t -> t
  other -> showT other

intData :: Int -> SQLData
intData = SQLInteger . fromIntegral

-- | A Python int bound as a SQLite INTEGER (Python refuses one that does
-- not fit in 64 bits).
bigint :: Integer -> SQLData
bigint value
  | value < toInteger (minBound :: Int64) || value > toInteger (maxBound :: Int64) =
      throw (Port.DispatchError "Python int too large to convert to SQLite INTEGER")
  | otherwise = SQLInteger (fromInteger value)

intJson :: Int -> Json
intJson = Int . toInteger

showT :: (Show a) => a -> Text
showT = T.pack . show

-- | @str(Path(path))@: repeated separators and @.@ components collapse, a
-- trailing separator is dropped.
pathText :: FilePath -> Text
pathText file =
  let raw = T.pack file
      parts = filter (\p -> not (T.null p) && p /= ".") (T.splitOn "/" raw)
      body = T.intercalate "/" parts
      root
        | "//" `T.isPrefixOf` raw && not ("///" `T.isPrefixOf` raw) = "//"
        | "/" `T.isPrefixOf` raw = "/"
        | otherwise = ""
   in if T.null root && T.null body then "." else root <> body

sleepSeconds :: Double -> IO ()
sleepSeconds seconds = threadDelay (max 0 (round (seconds * 1000000)))

-- ---------------------------------------------------------------------------
-- Telemetry

impetus :: TelemetryLogger
impetus = getLogger "impetus" Nothing

emit :: Text -> [(Text, Json)] -> IO ()
emit = Telemetry.emit impetus

-- | @_emit_attempt@.
emitAttempt :: Text -> ActivityAttempt -> [(Text, Json)] -> IO ()
emitAttempt event attempt extra = do
  (inst, occurrence) <- attemptKey attempt
  emit
    event
    ( [ ("instance", String inst)
      , ("occurrence", intJson occurrence)
      , ("attempt", String attempt.attemptId)
      , ("epoch", String attempt.epoch)
      , ("claimant", String attempt.claimant)
      , ("queue", String attempt.queue)
      , ("activity", String attempt.invocation.activity)
      ]
        <> extra
    )

emitExpired :: [(Text, Int64, Int64, Maybe Text)] -> IO ()
emitExpired expired =
  forM_ expired $ \(inst, occurrence, epoch, who) ->
    emit
      "dispatch_lease_expired"
      [ ("instance", String inst)
      , ("occurrence", Int (toInteger occurrence))
      , ("attempt", String (attemptIdOf inst (fromIntegral occurrence)))
      , ("epoch", Int (toInteger epoch))
      , ("claimant", maybe Null String who)
      , ("outcome", String "failed")
      ]
