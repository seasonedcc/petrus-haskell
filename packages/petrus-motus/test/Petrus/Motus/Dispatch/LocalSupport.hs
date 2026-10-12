-- | Fixtures shared by the Local Dispatch specs: the reference test
-- module's @invocation@, @require_claim@, and manual provider clock, plus
-- scratch directories and raw SQLite access (the reference tests mutate rows
-- with @sqlite3.connect@).
module Petrus.Motus.Dispatch.LocalSupport
  ( -- * Values
    callWith
  , call
  , instruction
  , failure
  , attemptWith
  , obj
    -- * Custody
  , requireClaim
  , fixedWorker
  , fixedWorkerOn
  , clockedWorker
  , manualClock
  , refusal
  , refusalMatching
    -- * Files
  , withScratch
  , openScratchDispatch
  , openScratchWorker
  , closingScratch
  , rawExec
  , rawQuery
  , rawScalar
    -- * The v1 schema
  , v1Ddl
  , legacyInvocation
  , writeV1
    -- * The reference
  , Python
  , withReference
  , runPython
  , startPython
  , finishPython
  , parsedJson
  ) where

import Control.Exception (bracket, finally, mask_)
import Control.Monad (void)
import Data.IORef
import Data.List (isPrefixOf, partition)
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite3 (SQLData (..), StepResult (..))
import Database.SQLite3 qualified as Sql
import Petrus.Activity
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch
import Petrus.Motus.Dispatch.Local (LocalDispatch, LocalDispatchClock (..), LocalDispatchOptions, LocalWorkerDispatch, closeLocalDispatch, openLocalDispatch, LocalWorkerOptions (..), defaultLocalWorkerOptions, openLocalWorkerDispatch)
import Petrus.Motus.Dispatch.Local qualified as Local
import Data.ByteString qualified as BS
import Petrus.Json (parseJson, surrogateRefusingLoads)
import Petrus.TestSupport.Python (pythonExecutable)
import Petrus.TestSupport.Repo (upstreamPetrus)
import System.Directory (createDirectory, getTemporaryDirectory, makeAbsolute, removeDirectoryRecursive, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath (splitDirectories, (</>))
import System.IO (Handle, hClose, hSetBinaryMode, openTempFile)
import System.IO.Unsafe (unsafePerformIO)
import System.Process
import Test.Hspec

-- | The reference's @invocation(activity, *, attempts=2, timeout=30,
-- value=1, **policy)@, the policy tweaks applied to the resolved fields.
callWith :: Text -> Integer -> Integer -> Json -> (ExecutionPolicyFields -> ExecutionPolicyFields) -> ActivityInvocation
callWith activity attempts' timeout value tweak =
  ActivityInvocation
    { activity = activity
    , input = Object [("value", value)]
    , policy =
        either
          (error . T.unpack)
          id
          (executionPolicy (tweak (policyFields defaultExecutionPolicy) {attempts = attempts', heartbeatTimeout = timeout}))
    , correlation = Just "correlation"
    , idempotency = Just "idempotency"
    }

-- | @invocation()@.
call :: ActivityInvocation
call = callWith "work" 2 30 (Int 1) id

instruction :: Int -> ActivityInvocation -> Int -> CancellationInstruction
instruction o inv p = either (error . T.unpack) id (cancellationInstruction o inv p)

failure :: ActivityFailureFields -> ActivityFailure
failure = either (error . T.unpack) id . activityFailure

-- | @ActivityAttempt(...)@ (the reference's @replace(attempt, ...)@ too).
attemptWith :: Text -> Text -> Text -> Text -> ActivityInvocation -> Json -> Maybe Text -> ActivityAttempt
attemptWith a e c q inv details inst = either (error . T.unpack) id (activityAttempt a e c q inv details inst)

obj :: [(Text, Json)] -> Json
obj = Object

-- | @require_claim(custody)@.
requireClaim :: LocalWorkerDispatch -> IO ActivityAttempt
requireClaim custody =
  Local.claim custody >>= \case
    Just attempt -> pure attempt
    Nothing -> do
      expectationFailure ("expected " <> show custody.claimant <> " to claim work from " <> show custody.queues)
      error "unreachable"

-- | @LocalWorkerDispatch(path, _claimant=claimant)@.
fixedWorker :: FilePath -> Text -> IO LocalWorkerDispatch
fixedWorker path who = fixedWorkerOn path ["default"] who

-- | @LocalWorkerDispatch(path, queues=queues, _claimant=claimant)@.
fixedWorkerOn :: FilePath -> [Text] -> Text -> IO LocalWorkerDispatch
fixedWorkerOn path queues' who =
  openScratchWorker path defaultLocalWorkerOptions {workerQueues = queues', explicitClaimant = Just who}

-- | @LocalWorkerDispatch(path, _claimant=claimant, clock=clock)@.
clockedWorker :: FilePath -> Text -> LocalDispatchClock -> IO LocalWorkerDispatch
clockedWorker path who source =
  openScratchWorker path defaultLocalWorkerOptions {explicitClaimant = Just who, workerClock = Just source}

-- | @_ManualProviderClock(at)@: the clock and the cell that sets it.
manualClock :: Integer -> IO (LocalDispatchClock, IORef Integer)
manualClock at = do
  ref <- newIORef at
  pure (LocalDispatchClock (readIORef ref), ref)

-- | A 'DispatchError' with exactly this message.
refusal :: Text -> Selector DispatchError
refusal expected (DispatchError message) = message == expected

-- | A 'DispatchError' whose message contains the fragment (for messages
-- that embed a temporary path or a generated value).
refusalMatching :: Text -> Selector DispatchError
refusalMatching fragment (DispatchError message) = fragment `T.isInfixOf` message

-- | A fresh scratch directory, removed afterwards, once the Local Dispatch
-- sessions and workers opened in it through 'openScratchDispatch' and
-- 'openScratchWorker' (and the worker fixtures above) are closed.
withScratch :: (FilePath -> IO a) -> IO a
withScratch =
  bracket
    ( do
        base <- getTemporaryDirectory
        (path, handle) <- openTempFile base "petrus-motus-local"
        hClose handle
        removeFile path
        createDirectory path
        pure path
    )
    (\dir -> closeOpenedIn dir >> removeDirectoryRecursive dir)

-- | Run the action, then close what it opened in the directory through
-- 'openScratchDispatch' and 'openScratchWorker': for a scratch directory
-- that another module's @withScratch@ removes.
closingScratch :: FilePath -> IO a -> IO a
closingScratch dir action = action `finally` closeOpenedIn dir

-- | 'openLocalDispatch', closed when the enclosing 'withScratch' ends.
--
-- The reference's sessions and workers hold no connection between
-- operations; the port's keep a pool, and one left open closes it when the
-- garbage collector finalizes it. The last of those closes deletes
-- @dispatch.db-wal@, at an arbitrary moment: during the scratch directory's
-- removal, that removal fails on the vanished file. Keeping each one
-- reachable until 'withScratch' closes it removes that moment.
openScratchDispatch :: FilePath -> Text -> LocalDispatchOptions -> IO LocalDispatch
openScratchDispatch path identity options = mask_ $ do
  dispatch <- openLocalDispatch path identity options
  remember path (closeLocalDispatch dispatch)
  pure dispatch

-- | 'openLocalWorkerDispatch', closed when the enclosing 'withScratch' ends
-- (see 'openScratchDispatch').
openScratchWorker :: FilePath -> LocalWorkerOptions -> IO LocalWorkerDispatch
openScratchWorker path options = mask_ $ do
  worker <- openLocalWorkerDispatch path options
  remember path (Local.close worker)
  pure worker

-- | What 'openScratchDispatch' and 'openScratchWorker' opened, by path, with
-- what closes it. Keyed by path, so examples running side by side close only
-- their own. unsafePerformIO (NOINLINE): one registry per test process,
-- reached from helpers that share no argument.
opened :: IORef [([FilePath], IO ())]
opened = unsafePerformIO (newIORef [])
{-# NOINLINE opened #-}

remember :: FilePath -> IO () -> IO ()
remember path closer = atomicModifyIORef' opened (\entries -> ((splitDirectories path, closer) : entries, ()))

-- | Close what was opened under the directory, most recent first.
closeOpenedIn :: FilePath -> IO ()
closeOpenedIn dir = do
  let inside (path, _) = splitDirectories dir `isPrefixOf` path
  mine <- atomicModifyIORef' opened (\entries -> let (here, elsewhere) = partition inside entries in (elsewhere, here))
  mapM_ snd mine

-- | @with sqlite3.connect(path) as connection: connection.execute(sql)@.
rawExec :: FilePath -> Text -> IO ()
rawExec path sql = () <$ rawQuery path sql []

-- | Rows of one statement on a plain connection.
rawQuery :: FilePath -> Text -> [SQLData] -> IO [[SQLData]]
rawQuery path sql params =
  bracket (Sql.open (T.pack path)) Sql.close $ \db ->
    bracket (Sql.prepare db sql) Sql.finalize $ \statement -> do
      Sql.bind statement params
      let loop acc =
            Sql.step statement >>= \case
              Row -> Sql.columns statement >>= \row -> loop (row : acc)
              Done -> pure (reverse acc)
      loop []

-- | The first column of the first row.
rawScalar :: FilePath -> Text -> IO SQLData
rawScalar path sql =
  rawQuery path sql [] >>= \case
    (value : _) : _ -> pure value
    _ -> pure SQLNull

v1Ddl :: [Text]
v1Ddl =
  [ "CREATE TABLE impetus_local_dispatch_schema (\n\
    \  component TEXT PRIMARY KEY CHECK(component='dispatch'), version INTEGER NOT NULL)"
  , "INSERT INTO impetus_local_dispatch_schema VALUES ('dispatch', 1)"
  , "CREATE TABLE impetus_local_dispatch_tasks (\n\
    \  sequence INTEGER PRIMARY KEY AUTOINCREMENT,\n\
    \  instance TEXT NOT NULL, occurrence INTEGER NOT NULL CHECK(occurrence>0),\n\
    \  queue TEXT NOT NULL, invocation TEXT NOT NULL CHECK(json_valid(invocation)),\n\
    \  epoch INTEGER NOT NULL DEFAULT 0 CHECK(epoch>=0), claimant TEXT, deadline INTEGER,\n\
    \  details TEXT CHECK(details IS NULL OR json_valid(details)),\n\
    \  CHECK((epoch=0 AND claimant IS NULL AND deadline IS NULL) OR\n\
    \        (epoch>0 AND claimant IS NOT NULL AND deadline IS NOT NULL)),\n\
    \  UNIQUE(instance, occurrence))"
  , "CREATE INDEX impetus_local_dispatch_claimable\n\
    \  ON impetus_local_dispatch_tasks(queue, sequence)"
  , "CREATE TABLE impetus_local_dispatch_terminals (\n\
    \  sequence INTEGER PRIMARY KEY AUTOINCREMENT,\n\
    \  instance TEXT NOT NULL, occurrence INTEGER NOT NULL, epoch INTEGER NOT NULL CHECK(epoch>0),\n\
    \  claimant TEXT NOT NULL, outcome TEXT NOT NULL CHECK(json_valid(outcome)),\n\
    \  UNIQUE(instance, occurrence),\n\
    \  FOREIGN KEY(instance, occurrence)\n\
    \    REFERENCES impetus_local_dispatch_tasks(instance, occurrence))"
  ]

legacyInvocation :: Text
legacyInvocation =
  "{\"activity\":\"work\",\"correlation\":\"correlation\",\"idempotency\":\"idempotency\",\"input\":{\"value\":1},\"policy\":{\"attempts\":2,\"heartbeat_timeout\":30}}"

-- | The reference test's v1 database: one pending, one active, one
-- terminal task, the terminal in the legacy failure shape. The active
-- leases' deadline is the given SQL expression (the reference uses
-- @unixepoch('now')*1000+30000@; the interop suite a constant).
writeV1 :: FilePath -> Text -> IO ()
writeV1 path deadline = do
  mapM_ (rawExec path) v1Ddl
  void $ rawQuery path "INSERT INTO impetus_local_dispatch_tasks(instance,occurrence,queue,invocation) VALUES('one',1,'default',?)" [SQLText legacyInvocation]
  void $
    rawQuery
      path
      ("INSERT INTO impetus_local_dispatch_tasks(instance,occurrence,queue,invocation,epoch,claimant,deadline,details) VALUES('one',2,'default',?,1,'active'," <> deadline <> ",'{\"progress\":1}')")
      [SQLText legacyInvocation]
  void $
    rawQuery
      path
      ("INSERT INTO impetus_local_dispatch_tasks(instance,occurrence,queue,invocation,epoch,claimant,deadline) VALUES('one',3,'default',?,1,'done'," <> deadline <> ")")
      [SQLText legacyInvocation]
  rawExec
    path
    "INSERT INTO impetus_local_dispatch_terminals(instance,occurrence,epoch,claimant,outcome) VALUES('one',3,1,'done','{\"kind\":\"failed\",\"error\":\"broken\"}')"

-- ---------------------------------------------------------------------------
-- The reference

-- | The reference interpreter and the upstream root it runs in.
type Python = (FilePath, FilePath)

-- | Run the example against the pinned reference: its interpreter
-- (provisioned by @scripts/upstream-python@ on first use) and the upstream
-- root. Fails loudly, never skips, when the reference cannot be provisioned.
withReference :: (Python -> IO ()) -> IO ()
withReference body = do
  python <- pythonExecutable
  root <- upstreamPetrus
  body (python, root)

-- | The interop script's absolute path (the suite runs from the package).
interopScript :: IO FilePath
interopScript = makeAbsolute ("test" </> "interop" </> "local_interop.py")

-- | Start @local_interop.py@ with these arguments (cwd = the upstream root),
-- its stdout captured as bytes.
startPython :: Python -> [String] -> IO (ProcessHandle, Handle)
startPython (python, root) arguments = do
  script <- interopScript
  (_, Just out, _, handle) <-
    createProcess (proc python (script : arguments)) {cwd = Just root, std_out = CreatePipe}
  hSetBinaryMode out True
  pure (handle, out)

-- | Wait for a started script; fail the example on a non-zero exit, and
-- answer its stdout.
finishPython :: [String] -> (ProcessHandle, Handle) -> IO BS.ByteString
finishPython arguments (handle, out) = do
  bytes <- BS.hGetContents out
  waitForProcess handle >>= \case
    ExitSuccess -> pure bytes
    ExitFailure n -> do
      expectationFailure ("local_interop.py " <> unwords arguments <> " exited " <> show n)
      pure bytes

-- | Run @local_interop.py@ to completion and answer its stdout.
runPython :: Python -> [String] -> IO BS.ByteString
runPython python arguments = startPython python arguments >>= finishPython arguments

-- | The script's JSON output, parsed as the reference's @json.loads@ would.
parsedJson :: BS.ByteString -> Json
parsedJson = either error id . parseJson surrogateRefusingLoads
