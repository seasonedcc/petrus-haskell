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
  , parseWorkerArguments
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

import Control.Monad (when)
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Motus.Dispatch (WorkerDispatch)
import Petrus.Motus.Dispatch.Local (LocalWorkerOptions (..), openLocalWorkerDispatch, toWorkerDispatch)
import Petrus.Motus.Internal.Argparse
import Petrus.Motus.Internal.Repr (pyStr)
import Petrus.Motus.Worker
import System.Environment (getArgs, lookupEnv)
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

-- | The reference's parser, under the given program name.
workerParser :: Text -> ArgumentParser
workerParser prog =
  ArgumentParser
    { prog
    , description = Just "Provider and transport selection for the Worker process entry point."
    , options =
        [ (option "--provider") {choices = Just ["local", "absurd", "zeromq"], required = True}
        , (option "--registry") {required = True, help = Just "module:attribute of the Activity registry"}
        , (option "--queue") {repeatable = True, help = Just "subscribed queue (repeatable)"}
        , (option "--worker-id") {help = Just "optional operational Worker label"}
        , (option "--execution-mode") {choices = Just ["sync", "async"]}
        , (option "--custody-access") {choices = Just ["sync-bridge", "native-zeromq"]}
        , (option "--concurrency") {kind = IntOption, help = Just "positive AsyncWorker Activity-slot concurrency"}
        , (option "--max-operation-sockets") {kind = IntOption, help = Just "native ZeroMQ in-flight socket bound"}
        , (option "--claim-timeout") {kind = IntOption, help = Just "Absurd initial claim lease in seconds"}
        , (option "--poll-interval") {kind = FloatOption}
        , (option "--path") {help = Just "Local SQLite Dispatch path"}
        , (option "--dsn") {help = Just "Absurd PostgreSQL DSN"}
        , (option "--endpoint") {help = Just "ZeroMQ Dispatch server endpoint"}
        , (option "--client-secret-certificate") {help = Just "ZeroMQ CURVE client .key_secret file"}
        , (option "--server-public-certificate") {help = Just "ZeroMQ CURVE server public .key file"}
        ]
    }

-- | Build the namespace from parsed values; @$IMPETUS_DSN@ is @--dsn@'s
-- default.
parseWorkerArguments :: Maybe Text -> Parsed -> WorkerArguments
parseWorkerArguments environmentDsn parsed =
  WorkerArguments
    { provider = case value "--provider" parsed of
        Just "absurd" -> AbsurdProvider
        Just "zeromq" -> ZeroMQProvider
        _ -> LocalProvider
    , registry = fromMaybe "" (value "--registry" parsed)
    , queue = values "--queue" parsed
    , workerId = value "--worker-id" parsed
    , executionMode = if value "--execution-mode" parsed == Just "async" then AsyncExecution else SyncExecution
    , custodyAccess = if value "--custody-access" parsed == Just "native-zeromq" then NativeZeroMQ else SyncBridge
    , concurrency = intOr 1 "--concurrency"
    , maxOperationSockets = intOr 8 "--max-operation-sockets"
    , claimTimeout = intOr 30 "--claim-timeout"
    , pollInterval = maybe 0.25 (fromMaybe 0.25 . pythonFloat) (value "--poll-interval" parsed)
    , path = value "--path" parsed
    , dsn = maybe environmentDsn Just (value "--dsn" parsed)
    , endpoint = value "--endpoint" parsed
    , clientSecretCertificate = value "--client-secret-certificate" parsed
    , serverPublicCertificate = value "--server-public-certificate" parsed
    }
  where
    intOr fallback key = maybe fallback (maybe fallback fromInteger . pythonInt) (value key parsed)

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
  arguments <- getArgs
  environmentDsn <- fmap T.pack <$> lookupEnv "IMPETUS_DSN"
  workerMainWith prog registries plugins arguments environmentDsn

-- | @main(argv)@ with an explicit @$IMPETUS_DSN@.
workerMainWith :: Text -> Registries -> ProviderPlugins -> [String] -> Maybe Text -> IO ()
workerMainWith prog registries plugins argv environmentDsn = do
  parsed <- runParser (workerParser prog) argv
  let arguments = parseWorkerArguments environmentDsn parsed
      queues = subscribedQueues arguments
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
    exitWithMessage ("--registry must be 'module:attribute', got " <> pyStr spec)
  build <- maybe (exitWithMessage ("--registry " <> pyStr spec <> " names no registry linked into this worker")) pure (Map.lookup spec registries)
  activities <- build
  when (Map.null activities) $
    exitWithMessage ("--registry " <> pyStr spec <> " must yield a non-empty mapping of activity name -> Activity")
  when (any T.null (Map.keys activities)) $
    exitWithMessage ("--registry " <> pyStr spec <> " must yield non-empty string names mapped to callable Activities")
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
