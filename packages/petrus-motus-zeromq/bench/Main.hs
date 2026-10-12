-- | ZeroMQ Dispatch benchmarks, the twins of @bench/python_bench.py@:
-- request latency and throughput through a server process over IPC, each
-- side's client against its own side's server (this executable re-executed
-- as the server, as the reference's bench runs its own). Every row is the
-- median of several runs after one warm-up, in the Python bench's format,
-- so @bench/RESULTS.md@ can set them side by side.
--
-- Three server set-ups:
--
-- * @local@: the server CLI over a fresh Local SQLite Dispatch, as
--   deployed.
-- * @local-held-open@: the same, while the bench holds a co-resident
--   connection to the file, so no close during the run is the last close of
--   the file (see RESULTS.md).
-- * @memory@: the server over in-memory custody (the private factory
--   door), which leaves only the transport: framing, JSON, routing, and
--   the IPC hops. Worker @empty@ never gets an Attempt; any other Worker
--   always gets the same one.
module Main (main) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, bracket, finally, throwIO, try)
import Control.Monad (forM, forM_, replicateM_, void)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite3 qualified as Sql
import GHC.Clock (getMonotonicTime)
import Petrus.Activity
import Petrus.Json (Json (..), defaultDumps, dumps, lookupMember, parseJson, pythonLoads)
import Petrus.Motus.Dispatch (ActivityAttempt, WorkerDispatch (..), activityAttempt)
import Petrus.Motus.Dispatch.Local (defaultLocalDispatchOptions, withLocalDispatch)
import Petrus.Motus.Dispatch.Local qualified as Local
import Petrus.Motus.Transport.ZeroMQ
  ( ClientOptions (..)
  , defaultClientOptions
  , fromFactory
  , maxMessageBytes
  , newAsyncZeroMQWorkerAccess
  , newZeroMQWorkerDispatch
  , serveForever
  , waitReady
  )
import Petrus.Motus.Transport.ZeroMQ qualified as Z
import Petrus.Motus.Transport.ZeroMQ.Cli (serverMainWith)
import Petrus.Motus.Worker (WorkerAccess (..))
import System.Directory (createDirectory, getTemporaryDirectory, removeDirectoryRecursive, removeFile)
import System.Environment (getArgs, getEnvironment, getExecutablePath, lookupEnv)
import System.FilePath ((</>))
import System.IO (hClose, hFlush, hGetLine, openTempFile, stdout)
import System.Posix.Signals (sigTERM, signalProcess)
import System.Process
import Text.Printf (printf)

serverMode :: String
serverMode = "PETRUS_ZEROMQ_BENCH_SERVER"

-- | The Python bench's @work(value)@.
work :: Int -> ActivityInvocation
work value =
  either (error . T.unpack) id . activityInvocation $
    ActivityInvocationFields
      { activity = "work"
      , input = Object [("value", Int (toInteger value))]
      , policy = either (error . T.unpack) id (executionPolicy (policyFields defaultExecutionPolicy) {attempts = 2, heartbeatTimeout = 30})
      , correlation = Just "correlation"
      , idempotency = Just "idempotency"
      }

-- | Print the median wall time of the runs after one warm-up, and append
-- it to the CSV sink (@scripts/bench@'s @--csv@ file) when there is one.
timed :: Csv -> String -> Int -> IO Int -> IO ()
timed csv name repeats action = do
  size <- action
  samples <- forM [1 .. repeats] $ \_ -> do
    start <- getMonotonicTime
    void action
    end <- getMonotonicTime
    pure (end - start)
  let sorted = sort samples
      middle = repeats `div` 2
      median = if even repeats then (sorted !! (middle - 1) + sorted !! middle) / 2 else sorted !! middle
  printf "%-42s %12.3f ms   (size %d, n=%d)\n" name (median * 1000) size repeats
  hFlush stdout
  mapM_ (\path -> appendFile path (name <> "," <> show (round (median * 1e12) :: Integer) <> "\n")) csv

-- | Where @--csv PATH@ asked the rows to go, in tasty-bench's columns.
type Csv = Maybe FilePath

csvSink :: [String] -> IO Csv
csvSink = \case
  "--csv" : path : _ -> writeFile path "Name,Mean (ps)\n" >> pure (Just path)
  _ : rest -> csvSink rest
  [] -> pure Nothing

client :: Text -> Text -> IO Z.ZeroMQWorkerDispatch
client endpoint worker = newZeroMQWorkerDispatch endpoint defaultClientOptions {Z.workerId = Just worker}

-- | n sequential claims on an empty queue: request latency.
claimEmpty :: Text -> Int -> IO Int
claimEmpty endpoint n =
  bracket (client endpoint "empty") Z.close $ \c -> do
    replicateM_ n (void (Z.claim c))
    pure n

-- | Claim, heartbeat, and complete one Attempt through the server.
custody :: Z.ZeroMQWorkerDispatch -> ActivityAttempt -> IO ()
custody c attempt = do
  void (Z.heartbeat c attempt (Just (Object [("progress", Int 1)])))
  Z.complete c attempt (Object [("ok", Bool True)])

-- | Dispatch n, then claim, heartbeat, and complete each through the server;
-- collect: custody throughput.
roundTrip :: Local.LocalDispatch -> Text -> Int -> Int -> IO Int
roundTrip dispatch endpoint base n = do
  forM_ [base + 1 .. base + n] $ \occurrence -> Local.dispatch dispatch occurrence (work occurrence)
  bracket (client endpoint "busy") Z.close $ \c -> do
    let drain = Z.claim c >>= maybe (pure ()) (\attempt -> custody c attempt >> drain)
    drain
  length <$> Local.collect dispatch

-- | n claim, heartbeat, complete cycles against in-memory custody.
memoryCustody :: Text -> Int -> IO Int
memoryCustody endpoint n =
  bracket (client endpoint "busy") Z.close $ \c -> do
    replicateM_ n (Z.claim c >>= mapM_ (custody c))
    pure n

-- | n claims on an empty queue through the native asynchronous access,
-- spread over c concurrent requesters (at most 8 sockets in flight).
asyncClaimEmpty :: Text -> Int -> Int -> IO Int
asyncClaimEmpty endpoint concurrency n = do
  access <- newAsyncZeroMQWorkerAccess endpoint defaultClientOptions {maxInFlightOperations = 8, Z.workerId = Just "empty"}
  let port = Z.toWorkerAccess access
  ( do
      finished <- forM [1 .. concurrency] $ \slot -> do
        done <- newEmptyMVar
        let share = n `div` concurrency + (if slot <= n `mod` concurrency then 1 else 0)
        _ <- forkIO (try @SomeException (replicateM_ share (void (port.claim slot))) >>= putMVar done)
        pure done
      forM_ finished $ \done -> takeMVar done >>= either throwIO pure
    )
    `finally` Z.closeAccess access
  pure n

-- | The memory server: custody that never touches a disk.
memoryServer :: [String] -> IO ()
memoryServer = \case
  [endpoint] -> do
    let attempt = either (error . T.unpack) id (activityAttempt "a1" "1" "bench" "default" (work 1) Null Nothing)
        factory _ worker =
          pure
            WorkerDispatch
              { claim = pure (if worker == "empty" then Nothing else Just attempt)
              , heartbeat = \_ details -> pure (maybe Null id details)
              , complete = \_ _ -> pure ()
              , fail = \_ _ -> pure ()
              , wait = \_ -> pure False
              , close = pure ()
              }
    server <- fromFactory (T.pack endpoint) factory maxMessageBytes
    void . forkIO $ do
      bound <- waitReady server 5
      case dumps defaultDumps (Object [("ready", Bool True), ("endpoint", String bound)]) of
        Right line -> BS.putStr (line <> "\n") >> hFlush stdout
        Left _ -> pure ()
    serveForever server
  arguments -> fail ("memory server arguments: " <> show arguments)

main :: IO ()
main =
  lookupEnv serverMode >>= \case
    Just "memory" -> getArgs >>= memoryServer
    Just _ -> getArgs >>= serverMainWith "petrus-zeromq-dispatch"
    Nothing -> getArgs >>= csvSink >>= benchmarks

-- | Start this executable as a server in the mode, run the action with its
-- endpoint, then stop it (SIGTERM) and wait for it.
withServer :: String -> [String] -> (Text -> IO a) -> IO a
withServer mode arguments action = do
  self <- getExecutablePath
  environment <- getEnvironment
  (_, Just out, _, server) <-
    createProcess
      (proc self (arguments ++ ["+RTS", "-M2G", "-RTS"])) {std_out = CreatePipe, env = Just ((serverMode, mode) : environment)}
  let stop = do
        getPid server >>= mapM_ (signalProcess sigTERM)
        void (waitForProcess server)
        hClose out
  ( do
      line <- hGetLine out
      endpoint <- case parseJson pythonLoads (BC.pack line) of
        Right event | Just (String e) <- lookupMember "endpoint" event -> pure e
        other -> throwIO (userError ("no readiness line: " <> show other))
      action endpoint
    )
    `finally` stop

-- | Run the action over a fresh Local Dispatch file in its own directory.
withLocal :: FilePath -> String -> (FilePath -> String -> IO a) -> IO a
withLocal base name action = do
  let directory = base </> name
  createDirectory directory
  action (directory </> "dispatch.db") ("ipc://" <> directory </> "dispatch.sock")

benchmarks :: Csv -> IO ()
benchmarks csv = do
  temporary <- getTemporaryDirectory
  (base, handle) <- openTempFile temporary "pzb"
  hClose handle
  removeFile base
  createDirectory base
  let localRows label held =
        withLocal base label $ \path bind ->
          withLocalDispatch path "bench" defaultLocalDispatchOptions $ \dispatch -> do
            let hold body
                  | held = bracket (Sql.open (T.pack path)) Sql.close $ \connection -> do
                      Sql.exec connection "SELECT count(*) FROM impetus_local_dispatch_tasks"
                      body
                  | otherwise = body
            hold . withServer "local" ["--path", path, "--bind", bind, "--drain-timeout", "0.1"] $ \endpoint -> do
              occurrences <- newIORef 0
              let roundTrips n = do
                    offset <- atomicModifyIORef' occurrences (\o -> (o + n, o))
                    roundTrip dispatch endpoint offset n
              timed csv ("zeromq/" <> label <> "/claim-empty-100") 10 (claimEmpty endpoint 100)
              timed csv ("zeromq/" <> label <> "/roundtrip-20") 10 (roundTrips 20)
  ( do
      localRows "local" False
      localRows "local-held-open" True
      withServer "memory" ["ipc://" <> base </> "memory.sock"] $ \endpoint -> do
        timed csv "zeromq/memory/claim-empty-100" 10 (claimEmpty endpoint 100)
        timed csv "zeromq/memory/custody-20" 10 (memoryCustody endpoint 20)
        forM_ [1, 8] $ \c ->
          timed csv ("zeromq/memory/async-claim-empty-100-c" <> show c) 10 (asyncClaimEmpty endpoint c 100)
    )
    `finally` removeDirectoryRecursive base
