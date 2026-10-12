-- | The server's process entry point (@python -m
-- petrus.motus.transport.zeromq@) and the Worker CLI's ZeroMQ provider
-- plugins.
module Petrus.Motus.Transport.ZeroMQ.Cli
  ( serverParser
  , serverMain
  , serverMainWith
  , zeromqPlugins
  ) where

import Control.Concurrent (forkIO)
import Control.Exception (SomeAsyncException, SomeException, catch, fromException, throwIO, try)
import Control.Monad (void)
import Data.ByteString qualified as BS
import Data.List (nub)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..), defaultDumps, dumps)
import Petrus.Argparse (ArgumentParser (..), appended, defaulted, float, help, option, required, runArgumentParser, str)
import Petrus.Motus.PythonException (PythonException (..))
import Petrus.Motus.Transport.ZeroMQ.Errors (zeromqPythonException)
import Petrus.Motus.Transport.ZeroMQ.Client
import Petrus.Motus.Transport.ZeroMQ.Server
import Petrus.Motus.Worker.Cli (ProviderPlugins (..), WorkerArguments (..), noPlugins)
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (hFlush, hPutStrLn, stderr, stdout)
import System.Posix.Process (getProcessID)
import System.Posix.Signals (Handler (..), installHandler, sigTERM)

-- | The server's command line.
data ServerArguments = ServerArguments
  { path :: Text
  , bind :: Text
  , queue :: [Text]
  , serverSecretCertificate :: Maybe Text
  , allowedClientKeys :: Maybe Text
  , drainTimeout :: Double
  }

-- | The reference's server parser, under the given program name, decoded.
serverParser :: Text -> ArgumentParser ServerArguments
serverParser prog =
  ArgumentParser
    { prog
    , description = Just "Optional ZeroMQ transport for the synchronous Worker Dispatch contract."
    , arguments =
        ServerArguments
          <$> required str ["--path"] [help "Local SQLite Dispatch path owned by this execution host"]
          <*> required str ["--bind"] [help "ipc:// or tcp:// bind endpoint"]
          <*> appended str ["--queue"] [help "allowed Worker queue (repeatable)"]
          <*> option str ["--server-secret-certificate"] [help "CURVE server .key_secret file (TCP)"]
          <*> option str ["--allowed-client-keys"] [help "directory of allowed client public .key files (TCP)"]
          <*> defaulted float ["--drain-timeout"] 30.0 []
    }

-- | @main()@ with the process arguments.
serverMain :: Text -> IO ()
serverMain prog = getArgs >>= serverMainWith prog

-- | @main(argv)@: serve a Local SQLite Dispatch until SIGTERM's drain
-- ends (exit 0). The readiness line is printed once bound. A failure (a
-- refused configuration, an owned endpoint) ends the process with status 1
-- after the last line of the reference's traceback, @Type: message@.
serverMainWith :: Text -> [String] -> IO ()
serverMainWith prog argv = serve prog argv `catch` uncaught

uncaught :: SomeException -> IO ()
uncaught e
  | Just (_ :: ExitCode) <- fromException e = throwIO e
  | Just (_ :: SomeAsyncException) <- fromException e = throwIO e
  | otherwise = do
      let PythonException {className, message} = zeromqPythonException e
      hPutStrLn stderr (T.unpack (className <> if T.null message then "" else ": " <> message))
      exitWith (ExitFailure 1)

serve :: Text -> [String] -> IO ()
serve prog argv = do
  arguments <- runArgumentParser (serverParser prog) argv
  let queues = case nub arguments.queue of
        [] -> ["default"]
        given -> given
  server <-
    localServer
      arguments.bind
      (T.unpack arguments.path)
      queues
      (T.unpack <$> arguments.serverSecretCertificate)
      (T.unpack <$> arguments.allowedClientKeys)
  _ <- installHandler sigTERM (Catch (void (try @SomeException (requestDrain server arguments.drainTimeout)))) Nothing
  _ <- forkIO (announce server)
  serveForever server

announce :: ZeroMQDispatchServer -> IO ()
announce server =
  try @SomeException (waitReady server 5.0) >>= \case
    Left _ -> pure ()
    Right endpoint -> do
      pid <- getProcessID
      case dumps defaultDumps (Object [("ready", Bool True), ("endpoint", String endpoint), ("pid", Int (toInteger (fromEnum pid)))]) of
        Right line -> BS.putStr (line <> "\n") >> hFlush stdout
        Left _ -> pure ()

-- | The ZeroMQ provider and native access for the Worker CLI
-- (@--provider zeromq@, @--custody-access native-zeromq@), with the
-- reference's fixed request and terminal timeouts (5 s and 30 s).
zeromqPlugins :: ProviderPlugins
zeromqPlugins =
  noPlugins
    { zeromq = Just $ \arguments queues ->
        toWorkerDispatch <$> newZeroMQWorkerDispatch (fromMaybe "" arguments.endpoint) (clientOptions arguments queues)
    , zeromqNative = Just $ \arguments queues ->
        toWorkerAccess
          <$> newAsyncZeroMQWorkerAccess
            (fromMaybe "" arguments.endpoint)
            (clientOptions arguments queues) {maxInFlightOperations = arguments.maxOperationSockets}
    }
  where
    clientOptions arguments queues =
      defaultClientOptions
        { queues = queues
        , workerId = arguments.workerId
        , clientSecretCertificate = T.unpack <$> arguments.clientSecretCertificate
        , serverPublicCertificate = T.unpack <$> arguments.serverPublicCertificate
        }
