-- | The Worker process entry point (a port of @petrus.motus.worker._cli@).
--
-- Haskell cannot import an Activity registry by name at run time, so an
-- application builds its own worker executable around 'workerMain': it
-- passes the registries it was compiled with, keyed by the reference's
-- @module:attribute@ spelling (which @--registry@ selects), and the
-- providers it links. Local custody is built in; Absurd and ZeroMQ arrive
-- as 'ProviderPlugins' so this package never links libpq or libzmq.
--
-- Flags, defaults, validation order, messages, exit statuses (2 for usage
-- errors, 1 for refusals and uncaught errors, 0 for a clean stop), and
-- SIGTERM-as-stop are the reference's.
module Petrus.Motus.Worker.Cli
  ( -- * Arguments
    Provider (..)
  , ExecutionMode (..)
  , CustodyAccess (..)
  , WorkerArguments (..)
  , workerParser
  , subscribedQueues
  , validateProviderArguments
    -- * Registries and providers
  , Registries
  , ProviderPlugins (..)
  , noPlugins
    -- * Entry point
  , workerMain
  , workerMainWith
  ) where

import Control.Applicative ((<|>))
import Control.Monad (when)
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Motus.Dispatch (WorkerDispatch)
import Petrus.Motus.Dispatch.Local (LocalWorkerOptions (..), openLocalWorkerDispatch, toWorkerDispatch)
import Petrus.Argparse
  ( ArgumentParser (..)
  , appended
  , choice
  , defaulted
  , exitWithMessage
  , float
  , getArguments
  , help
  , int
  , option
  , required
  , runArgumentParser
  , str
  )
import Petrus.Json.Python (pythonStrRepr)
import Petrus.Motus.Worker
import System.Environment (lookupEnv)
import System.Posix.Signals (Handler (..), installHandler, sigTERM)

data Provider = LocalProvider | AbsurdProvider | ZeroMQProvider
  deriving stock (Eq, Show)

data ExecutionMode = SyncExecution | AsyncExecution
  deriving stock (Eq, Show)

data CustodyAccess = SyncBridge | NativeZeroMQ
  deriving stock (Eq, Show)

-- | The parsed command line (the reference's @argparse.Namespace@).
data WorkerArguments = WorkerArguments
  { provider :: Provider
  , registry :: Text
  , queue :: [Text]
  , workerId :: Maybe Text
  , executionMode :: ExecutionMode
  , custodyAccess :: CustodyAccess
  , concurrency :: Int
  , maxOperationSockets :: Int
  , claimTimeout :: Int
  , pollInterval :: Double
  , path :: Maybe Text
  , dsn :: Maybe Text
  , endpoint :: Maybe Text
  , clientSecretCertificate :: Maybe Text
  , serverPublicCertificate :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | The reference's parser, under the given program name, decoded;
-- @$IMPETUS_DSN@ (given) is @--dsn@'s default.
workerParser :: Text -> Maybe Text -> ArgumentParser WorkerArguments
workerParser prog environmentDsn =
  ArgumentParser
    { prog
    , description = Just "Provider and transport selection for the Worker process entry point."
    , arguments =
        WorkerArguments
          <$> required (choice [("local", LocalProvider), ("absurd", AbsurdProvider), ("zeromq", ZeroMQProvider)]) ["--provider"] []
          <*> required str ["--registry"] [help "module:attribute of the Activity registry"]
          <*> appended str ["--queue"] [help "subscribed queue (repeatable)"]
          <*> option str ["--worker-id"] [help "optional operational Worker label"]
          <*> defaulted (choice [("sync", SyncExecution), ("async", AsyncExecution)]) ["--execution-mode"] SyncExecution []
          <*> defaulted (choice [("sync-bridge", SyncBridge), ("native-zeromq", NativeZeroMQ)]) ["--custody-access"] SyncBridge []
          <*> (fromInteger <$> defaulted int ["--concurrency"] 1 [help "positive AsyncWorker Activity-slot concurrency"])
          <*> (fromInteger <$> defaulted int ["--max-operation-sockets"] 8 [help "native ZeroMQ in-flight socket bound"])
          <*> (fromInteger <$> defaulted int ["--claim-timeout"] 30 [help "Absurd initial claim lease in seconds"])
          <*> defaulted float ["--poll-interval"] 0.25 []
          <*> option str ["--path"] [help "Local SQLite Dispatch path"]
          <*> ((<|> environmentDsn) <$> option str ["--dsn"] [help "Absurd PostgreSQL DSN"])
          <*> option str ["--endpoint"] [help "ZeroMQ Dispatch server endpoint"]
          <*> option str ["--client-secret-certificate"] [help "ZeroMQ CURVE client .key_secret file"]
          <*> option str ["--server-public-certificate"] [help "ZeroMQ CURVE server public .key file"]
    }

-- | @tuple(dict.fromkeys(arguments.queue)) or ("default",)@.
subscribedQueues :: WorkerArguments -> [Text]
subscribedQueues arguments = case nub arguments.queue of
  [] -> ["default"]
  queues -> queues

-- | The reference's @_validate_provider_arguments@, message for message.
-- (An empty string counts as absent, as Python's truthiness does.)
validateProviderArguments :: WorkerArguments -> Either Text ()
validateProviderArguments arguments = do
  let given = maybe False (not . T.null)
      certificates = given arguments.clientSecretCertificate || given arguments.serverPublicCertificate
  case arguments.provider of
    LocalProvider -> do
      when (not (given arguments.path) || given arguments.dsn || given arguments.endpoint) $
        Left "Local provider requires --path and rejects --dsn/$IMPETUS_DSN and --endpoint"
      when certificates $ Left "Local provider rejects ZeroMQ CURVE certificates"
    AbsurdProvider -> do
      when (not (given arguments.dsn) || given arguments.path || given arguments.endpoint) $
        Left "Absurd provider requires --dsn (or $IMPETUS_DSN) and rejects --path and --endpoint"
      when certificates $ Left "Absurd provider rejects ZeroMQ CURVE certificates"
    ZeroMQProvider ->
      when (not (given arguments.endpoint) || given arguments.path || given arguments.dsn) $
        Left "ZeroMQ provider requires --endpoint and rejects --path and --dsn/$IMPETUS_DSN"
  when (arguments.custodyAccess == NativeZeroMQ && (arguments.executionMode /= AsyncExecution || arguments.provider /= ZeroMQProvider)) $
    Left "native-zeromq custody access requires async execution with the zeromq provider"
  when (arguments.custodyAccess == SyncBridge && arguments.maxOperationSockets /= 8) $
    Left "--max-operation-sockets applies only to native-zeromq custody access"

-- | The registries a worker executable was built with, keyed by the
-- @module:attribute@ spelling @--registry@ names; each yields its mapping
-- (the reference accepts a mapping or a zero-argument callable).
type Registries = Map Text (IO (Map Text Activity))

-- | Providers linked from other packages. A missing one is refused as the
-- reference refuses a missing optional extra.
data ProviderPlugins = ProviderPlugins
  { absurd :: Maybe (WorkerArguments -> [Text] -> IO WorkerDispatch)
  , zeromq :: Maybe (WorkerArguments -> [Text] -> IO WorkerDispatch)
  , zeromqNative :: Maybe (WorkerArguments -> [Text] -> IO WorkerAccess)
  }

-- | Local custody only.
noPlugins :: ProviderPlugins
noPlugins = ProviderPlugins {absurd = Nothing, zeromq = Nothing, zeromqNative = Nothing}

-- | @main()@ over the process's arguments and @$IMPETUS_DSN@.
workerMain :: Text -> Registries -> ProviderPlugins -> IO ()
workerMain prog registries plugins = do
  arguments <- getArguments
  environmentDsn <- fmap T.pack <$> lookupEnv "IMPETUS_DSN"
  workerMainWith prog registries plugins arguments environmentDsn

-- | @main(argv)@ with an explicit @$IMPETUS_DSN@.
workerMainWith :: Text -> Registries -> ProviderPlugins -> [Text] -> Maybe Text -> IO ()
workerMainWith prog registries plugins argv environmentDsn = do
  arguments <- runArgumentParser (workerParser prog environmentDsn) argv
  let queues = subscribedQueues arguments
  activities <- loadRegistry registries arguments.registry
  either exitWithMessage pure (validateProviderArguments arguments)
  let factory = providerFactory plugins arguments queues
      options = WorkerOptions {resolver = Nothing, workerId = arguments.workerId, output = stdoutEvents}
  case arguments.executionMode of
    AsyncExecution -> do
      worker <- case arguments.custodyAccess of
        NativeZeroMQ -> case plugins.zeromqNative of
          Nothing -> exitWithMessage "native-zeromq custody access is not linked into this worker"
          Just native -> asyncWorkerFromAccess (native arguments queues) activities arguments.concurrency options
        SyncBridge -> newAsyncWorker factory activities arguments.concurrency options
      _ <- installHandler sigTERM (Catch (stopAsyncWorker worker)) Nothing
      runAsyncWorker worker arguments.pollInterval
    SyncExecution -> do
      when (arguments.concurrency /= 1) $ exitWithMessage "--concurrency applies only to --execution-mode async"
      custody <- factory
      worker <- newWorker custody activities options
      _ <- installHandler sigTERM (Catch (stopWorker worker)) Nothing
      runWorker worker arguments.pollInterval

-- | The reference's @_load_registry@ over the compiled-in table.
loadRegistry :: Registries -> Text -> IO (Map Text Activity)
loadRegistry registries spec = do
  let (moduleName, rest) = T.breakOn ":" spec
      attribute = T.drop 1 rest
  when (T.null moduleName || T.null attribute) $
    exitWithMessage ("--registry must be 'module:attribute', got " <> pythonStrRepr spec)
  build <- maybe (exitWithMessage ("--registry " <> pythonStrRepr spec <> " names no registry linked into this worker")) pure (Map.lookup spec registries)
  activities <- build
  when (Map.null activities) $
    exitWithMessage ("--registry " <> pythonStrRepr spec <> " must yield a non-empty mapping of activity name -> Activity")
  when (any T.null (Map.keys activities)) $
    exitWithMessage ("--registry " <> pythonStrRepr spec <> " must yield non-empty string names mapped to callable Activities")
  pure activities

-- | The reference's @_provider_factory@.
providerFactory :: ProviderPlugins -> WorkerArguments -> [Text] -> IO WorkerDispatch
providerFactory plugins arguments queues = case arguments.provider of
  LocalProvider ->
    toWorkerDispatch
      <$> openLocalWorkerDispatch
        (T.unpack (fromMaybe "" arguments.path))
        LocalWorkerOptions {workerQueues = queues, workerId = arguments.workerId, workerClock = Nothing, explicitClaimant = Nothing}
  AbsurdProvider -> plugged "absurd" plugins.absurd
  ZeroMQProvider -> plugged "zeromq" plugins.zeromq
  where
    plugged label = \case
      Just build -> build arguments queues
      Nothing -> exitWithMessage ("the " <> label <> " provider is not linked into this worker")
