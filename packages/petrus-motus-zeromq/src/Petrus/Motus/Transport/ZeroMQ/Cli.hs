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
import Petrus.Motus.Internal.Argparse
import Petrus.Motus.Internal.Repr (exceptionMessage, exceptionTypeName)
import Petrus.Motus.Transport.ZeroMQ.Client
import Petrus.Motus.Transport.ZeroMQ.Server
import Petrus.Motus.Worker.Cli (ProviderPlugins (..), WorkerArguments (..), noPlugins)
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (hFlush, hPutStrLn, stderr, stdout)
import System.Posix.Process (getProcessID)
import System.Posix.Signals (Handler (..), installHandler, sigTERM)

-- | The reference's server parser, under the given program name.
serverParser :: Text -> ArgumentParser
serverParser prog =
  ArgumentParser
    { prog
    , description = Just "Optional ZeroMQ transport for the synchronous Worker Dispatch contract."
    , options =
        [ (option "--path") {required = True, help = Just "Local SQLite Dispatch path owned by this execution host"}
        , (option "--bind") {required = True, help = Just "ipc:// or tcp:// bind endpoint"}
        , (option "--queue") {repeatable = True, help = Just "allowed Worker queue (repeatable)"}
        , (option "--server-secret-certificate") {help = Just "CURVE server .key_secret file (TCP)"}
        , (option "--allowed-client-keys") {help = Just "directory of allowed client public .key files (TCP)"}
        , (option "--drain-timeout") {kind = FloatOption}
        ]
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
      let message = exceptionMessage e
      hPutStrLn stderr (T.unpack (exceptionTypeName e <> if T.null message then "" else ": " <> message))
      exitWith (ExitFailure 1)

serve :: Text -> [String] -> IO ()
serve prog argv = do
  parsed <- runParser (serverParser prog) argv
  let required key = fromMaybe "" (value key parsed)
      queues = case nub (values "--queue" parsed) of
        [] -> ["default"]
        given -> given
      drainTimeout = maybe 30.0 (fromMaybe 30.0 . pythonFloat) (value "--drain-timeout" parsed)
  server <-
    localServer
      (required "--bind")
      (T.unpack (required "--path"))
      queues
      (T.unpack <$> value "--server-secret-certificate" parsed)
      (T.unpack <$> value "--allowed-client-keys" parsed)
  _ <- installHandler sigTERM (Catch (void (try @SomeException (requestDrain server drainTimeout)))) Nothing
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
