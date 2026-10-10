-- | Shared fixtures for the PostgreSQL History store specs: the reference's
-- @postgres_dsn@ / @pg_connection@ / @instance_id@ fixtures and its @_rows@
-- helper.
module Petrus.HistoryStore.Postgres.Support
  ( -- * Connections
    withPg
  , withPgConnection
  , connectTo
    -- * Identities
  , freshInstance
    -- * Rows
  , Row (..)
  , rows
    -- * Selectors
  , valueErrorMatching
  , matchesInOrder
    -- * A barrier
  , Barrier
  , newBarrier
  , awaitBarrier
    -- * The reference's driver scripts
  , runScript
  , runScriptJson
  , Interactive (..)
  , withScript
  , send
  , receive
  , receiveJson
  , killHard
  , dsnArgument
  ) where

import Control.Concurrent.MVar
import Control.Exception (bracket, throwIO)
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTimeNSec)
import Numeric (showHex)
import Petrus.HistoryStore.Postgres (HistoryStoreError (..), ensureSchema)
import Petrus.Json (Json, parseJson, pythonLoads)
import Petrus.Postgres (Connection, close, connect, query, textParam)
import Petrus.TestSupport (PostgresTarget (..), PythonFailure (..), pythonExecutable, upstreamPetrus)
import System.Directory (makeAbsolute)
import System.Exit (ExitCode (..))
import System.IO (BufferMode (..), Handle, hClose, hFlush, hSetBinaryMode, hSetBuffering)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Process (getProcessID)
import System.Posix.Signals (sigKILL, signalProcess)
import System.Process
  ( CreateProcess (..)
  , ProcessHandle
  , StdStream (..)
  , cleanupProcess
  , createProcess
  , getPid
  , proc
  , waitForProcess
  )
import System.Timeout (timeout)
import Test.Hspec (Selector)

-- | @psycopg.connect(postgres_dsn, autocommit=...)@.
connectTo :: PostgresTarget -> Bool -> IO Connection
connectTo target = connect (targetUrl target)

-- | A connection for the duration of an action.
withPg :: PostgresTarget -> Bool -> (Connection -> IO a) -> IO a
withPg target mode = bracket (connectTo target mode) close

-- | @pg_connection@: a fresh autocommit connection with the schema ensured.
withPgConnection :: PostgresTarget -> (Connection -> IO a) -> IO a
withPgConnection target action = withPg target True $ \connection -> do
  ensureSchema connection
  action connection

counter :: IORef Int
counter = unsafePerformIO (newIORef 0)
{-# NOINLINE counter #-}

-- | @f"{prefix}-{uuid4()}"@: unique per call and per process.
freshInstance :: Text -> IO Text
freshInstance prefix = do
  n <- atomicModifyIORef' counter (\c -> (c + 1, c))
  pid <- getProcessID
  now <- getMonotonicTimeNSec
  pure (prefix <> "-" <> T.pack (show pid) <> "-" <> T.pack (showHex now "") <> "-" <> T.pack (show n))

-- | One @_rows@ row.
data Row = Row
  { rowEvent :: Text
  , rowType :: Text
  , rowOccurrence :: Maybe Integer
  , rowPayload :: Json
  }
  deriving stock (Eq, Show)

-- | @_rows(connection, instance_id)@.
rows :: Connection -> Text -> IO [Row]
rows connection instanceId = do
  raw <-
    query
      connection
      "SELECT event_id, record_type, occurrence, payload FROM impetus.semantic_events WHERE net_instance_id = %s ORDER BY sequence"
      [textParam instanceId]
  pure (map decode raw)
  where
    decode = \case
      [Just e, Just t, o, Just p] ->
        Row (TE.decodeUtf8 e) (TE.decodeUtf8 t) (fmap (read . BC.unpack) o) (either error id (parseJson pythonLoads p))
      other -> error ("unexpected row " <> show other)

-- | @re.search@ of a pattern made of literal pieces joined by @.*@.
matchesInOrder :: [Text] -> Text -> Bool
matchesInOrder [] _ = True
matchesInOrder (piece : rest) haystack = case T.breakOn piece haystack of
  (_, found)
    | T.null found && not (T.null piece) -> False
    | otherwise -> matchesInOrder rest (T.drop (T.length piece) found)

-- | @pytest.raises(ValueError, match=".*".join(pieces))@.
valueErrorMatching :: [Text] -> Selector HistoryStoreError
valueErrorMatching pieces (HistoryStoreError message) = matchesInOrder pieces message

-- | @threading.Barrier(n)@.
data Barrier = Barrier Int (MVar Int) (MVar ())

newBarrier :: Int -> IO Barrier
newBarrier n = Barrier n <$> newMVar 0 <*> newEmptyMVar

-- | Wait until all parties arrived.
awaitBarrier :: Barrier -> IO ()
awaitBarrier (Barrier n arrived gate) = do
  count' <- modifyMVar arrived (\c -> pure (c + 1, c + 1))
  when (count' == n) (putMVar gate ())
  readMVar gate

-- ---------------------------------------------------------------------------
-- The reference's driver scripts

-- | The scratch database's connection string, as the scripts' first
-- argument.
dsnArgument :: PostgresTarget -> String
dsnArgument target = BC.unpack (targetUrl target)

-- | @python -I SCRIPT ARGS@ under the pinned upstream environment (synced
-- with the @postgres@ extra on first use), from the upstream root; the
-- script path is relative to the package directory the suite runs in.
scriptProcess :: FilePath -> [String] -> IO CreateProcess
scriptProcess script arguments = do
  exe <- pythonExecutable
  root <- upstreamPetrus
  path <- makeAbsolute script
  pure (proc exe ("-I" : path : arguments)) {cwd = Just root}

-- | Run a script to completion and answer its stdout; a non-zero exit
-- raises 'PythonFailure' with both streams.
runScript :: FilePath -> [String] -> IO ByteString
runScript script arguments = do
  process <- scriptProcess script arguments
  bracket (createProcess process {std_out = CreatePipe}) cleanupProcess $ \case
    (_, Just output, _, handle) -> do
      hSetBinaryMode output True
      out <- BS.hGetContents output
      waitForProcess handle >>= \case
        ExitSuccess -> pure out
        ExitFailure n ->
          throwIO (PythonFailure (script <> " " <> unwords (drop 1 arguments) <> " exited " <> show n <> " (its stderr is above)") out "")
    _ -> error "createProcess did not return a stdout pipe"

-- | 'runScript', its stdout parsed as one JSON document.
runScriptJson :: FilePath -> [String] -> IO Json
runScriptJson script arguments = runScript script arguments >>= parsed

parsed :: ByteString -> IO Json
parsed bytes = either (\problem -> throwIO (PythonFailure ("invalid JSON: " <> problem) bytes "")) pure (parseJson pythonLoads bytes)

-- | A running interactive script.
data Interactive = Interactive
  { stdinOf :: Handle
  , stdoutOf :: Handle
  , handleOf :: ProcessHandle
  }

-- | Run an interactive script for the duration of an action; afterwards
-- its stdin is closed and the exact process is terminated and reaped.
withScript :: FilePath -> [String] -> (Interactive -> IO a) -> IO a
withScript script arguments action = do
  process <- scriptProcess script arguments
  bracket
    (createProcess process {std_in = CreatePipe, std_out = CreatePipe})
    cleanupProcess
    ( \case
        (Just input, Just output, _, handle) -> do
          hSetBuffering input LineBuffering
          hSetBinaryMode output True
          action (Interactive input output handle)
        _ -> error "createProcess did not return pipes"
    )

-- | Write one line to the script.
send :: Interactive -> ByteString -> IO ()
send running line = BS.hPut running.stdinOf (line <> "\n") >> hFlush running.stdinOf

-- | Read one line the script printed (30 s at most).
receive :: Interactive -> IO ByteString
receive running =
  timeout 30000000 (BC.hGetLine running.stdoutOf) >>= \case
    Just line -> pure line
    Nothing -> throwIO (PythonFailure "the reference script printed nothing for 30 s" "" "")

-- | Read one JSON line.
receiveJson :: Interactive -> IO Json
receiveJson running = receive running >>= parsed

-- | @SIGKILL@ the script's exact process (no cleanup runs in it: its
-- PostgreSQL session simply drops) and reap it.
killHard :: Interactive -> IO ()
killHard running = do
  hClose running.stdinOf
  getPid running.handleOf >>= mapM_ (signalProcess sigKILL)
  _ <- waitForProcess running.handleOf
  pure ()
