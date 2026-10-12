-- | The standalone host command line (@host/__main__.py@):
-- @serve@, @validate@, @inbox@, @requeue@ and @inspect-instance@.
--
-- The reference's @argparse@ parser is declared with "Petrus.Argparse"
-- (CPython 3.14's parsing, messages, usage and help, wrapped to @COLUMNS@,
-- else the terminal, else 80, minus 2, and colored as @_colorize@ decides;
-- help on stdout with 0, errors on stderr with 2). The declaration decodes
-- to a 'HostCommand', with the reference's checks after @parse_args@ as
-- its refusals.
module Hamsterdan.Host.Cli
  ( -- * The command line
    HostCommand (..)
  , hostParser
  , pythonFloat

    -- * @inspect-instance@
  , inspectInstance

    -- * Running
  , CliEnvironment (..)
  , productionEnvironment
  , runCli
  , handledMessage
  ) where

import Control.Exception (Exception (..), IOException, SomeException (..), finally, fromException, throwIO, try)
import Control.Monad (forM, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Agents.Protocol (AgentRunner (..))
import Petrus.Argparse
  ( ArgumentParser (..)
  , Arg
  , Outcome (..)
  , choice
  , defaulted
  , errorText
  , formattingOf
  , help
  , int
  , option
  , parse
  , positional
  , str
  , terminalColumns
  )
import Hamsterdan.Host.Agenticus (AgentCompositionError (..))
import Hamsterdan.Host.Agents (OwnedAgent, closeOwnedAgent, composeHostAgent, newOwnedAgent, productionAgentSeams)
import Petrus.Agenticus.Error (AgenticusError (..), isSubclassOf)
import Petrus.Agenticus.Error qualified as AE
import Hamsterdan.GitHub.Client (AppCredentials (..), ClientOptions, defaultClientOptions, newAppClients)
import Hamsterdan.GitHub.Config (ConfigurationError (..), HostConfig (..), fromEnvironment, revealSecret)
import Hamsterdan.GitHub.Http (ClientError (..), ClientErrorKind (..))
import Hamsterdan.GitHub.Models (ContractRefused (..), GitHubBoundaryError (..), InvalidRequest (..))
import Hamsterdan.Python (intText, isAscii, isPrintable, pythonExceptionStr, splitlines, strRepr, utf8Encode)
import Hamsterdan.Python.Object (errorLine, tracebackName)
import Hamsterdan.Host.ExceptionClass (exceptionClass)
import Hamsterdan.GitHub.Webhooks (Failure (..))
import Hamsterdan.GitHub.Webhooks qualified as Custody
import Hamsterdan.Host.Api (ServeOptions (..), Served (..), serve)
import Hamsterdan.Host.Uvicorn (UvicornLog (..))
import Hamsterdan.Host.Binding (InstanceBinding (..), parseInstanceBinding, preflightV5State, topologyText)
import Hamsterdan.Host.Service
  ( AgentCustody
  , HostService (..)
  , ServiceOptions (..)
  , gitHubHostClients
  , openHostService
  , qualificationFaultFromEnvironment
  , reconcileRegistration
  , serviceOptions
  )
import Hamsterdan.Host.Service qualified as Service
import Petrus.Impetus.Instance.FailureText (PyObject (..), PythonException (..))
import Petrus.Json (Json (..), defaultDumps, dumpsText, parseJson, pythonJsonLoads)
import Petrus.Json qualified as Json
import Petrus.Json.Python (parsePythonFloat)
import Petrus.Motus.Worker (RuntimeError (..), ValueError (..))
import System.Environment (unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (Handle, hFlush, hIsTerminalDevice, stderr, stdout)
import System.IO.Error (catchIOError, isEOFError)
import System.Posix.Files qualified as Posix
import System.Posix.IO qualified as PosixIO
import System.Posix.IO.ByteString qualified as PosixBS
import System.Posix.Signals (Handler (Default), Signal, installHandler, raiseSignal, sigTERM)

-- ---------------------------------------------------------------------------
-- The parser

-- | The decoded command line: each command with what it reads.
data HostCommand
  = -- | @serve@ on @--host@ and @--port@.
    Serve Text Integer
  | Validate
  | Inbox
  | -- | @requeue --delivery@.
    Requeue Text
  | -- | @inspect-instance --installation --repository --pr@.
    InspectInstance Integer Integer Integer
  deriving stock (Eq, Show)

-- | The @command@ choices, in the reference's order.
data CommandName = ServeName | ValidateName | InboxName | RequeueName | InspectInstanceName
  deriving stock (Eq)

-- | @parser()@, decoded. The @--host@ default is @HAMSTERDAN_HOST@ or
-- @127.0.0.1@; the @--port@ default, @int(HAMSTERDAN_PORT or "8000")@, is
-- passed in already converted. A 'Left' is the reference's
-- @parser().error(...)@ after @parse_args@.
hostParser :: Text -> Integer -> ArgumentParser (Either Text HostCommand)
hostParser hostDefault portDefault =
  ArgumentParser
    { prog = "python -m hamsterdan.host"
    , description = Just "Run or validate the Hamsterdan GitHub App host. Credentials are supplied by the selected Environment."
    , arguments
    }
  where
    arguments :: Arg (Either Text HostCommand)
    arguments =
      decode
        <$> positional
          (choice [("serve", ServeName), ("validate", ValidateName), ("inbox", InboxName), ("requeue", RequeueName), ("inspect-instance", InspectInstanceName)])
          "command"
          []
        <*> option str ["--delivery"] [help "canonical failed GitHub delivery UUID to requeue"]
        <*> option int ["--installation"] []
        <*> option int ["--repository"] []
        <*> option int ["--pr"] []
        <*> defaulted str ["--host"] hostDefault []
        <*> defaulted int ["--port"] portDefault []
    decode name delivery installation repository pr host port = case name of
      ServeName -> Right (Serve host port)
      ValidateName -> Right Validate
      InboxName -> Right Inbox
      -- An absent @--delivery@ is @None@, which the reference's @not
      -- args.delivery@ refuses like the empty string.
      RequeueName -> case delivery of
        Just given | not (T.null given) -> Right (Requeue given)
        _ -> Left "requeue requires --delivery"
      InspectInstanceName ->
        maybe (Left "inspect-instance requires --installation, --repository, and --pr") Right $
          InspectInstance <$> installation <*> repository <*> pr

-- | @float(text)@: 'Left' with CPython's message when it does not convert
-- (petrus-json's 'parsePythonFloat', the one @float()@ emulation).
pythonFloat :: Text -> Either Text Double
pythonFloat original = maybe (Left ("could not convert string to float: " <> strRepr original)) Right (parsePythonFloat original)

-- ---------------------------------------------------------------------------
-- inspect-instance

maxHistoryBytes, maxBindingBytes, maxIdentifierBytes :: Int
maxHistoryBytes = 16 * 1024 * 1024
maxBindingBytes = 4096
maxIdentifierBytes = 1024

-- | @_read_bounded_regular(path, limit)@.
readBoundedRegular :: FilePath -> Int -> IO ByteString
readBoundedRegular path limit = do
  outcome <- try @IOException $ do
    info <- Posix.getSymbolicLinkStatus path
    let size = fromIntegral (Posix.fileSize info) :: Integer
    when (Posix.isSymbolicLink info || not (Posix.isRegularFile info) || not (0 < size && size <= toInteger limit)) $
      throwIO (ValueError "Instance state file is not a bounded regular file")
    fd <- PosixIO.openFd path PosixIO.ReadOnly PosixIO.defaultFileFlags {PosixIO.nofollow = True}
    ( do
        before <- Posix.getFdStatus fd
        let readLoop chunks total = do
              let wanted = min 65536 (limit + 1 - total)
              chunk <- if wanted <= 0 then pure "" else readChunk fd wanted
              if BS.null chunk
                then pure (BS.concat (reverse chunks))
                else do
                  let total' = total + BS.length chunk
                  when (total' > limit) $ throwIO (ValueError "Instance state file is not a bounded regular file")
                  readLoop (chunk : chunks) total'
        bytes <- readLoop [] 0
        after <- Posix.getFdStatus fd
        pure (before, after, bytes)
      )
      `finally` PosixIO.closeFd fd
  case outcome of
    Left _ -> throwIO (ValueError "Instance state cannot be inspected safely")
    Right (before, after, bytes) -> do
      let identity s = (Posix.deviceID s, Posix.fileID s, Posix.fileSize s, Posix.modificationTimeHiRes s)
      when (identity before /= identity after || toInteger (BS.length bytes) /= toInteger (Posix.fileSize before)) $
        throwIO (ValueError "Instance state changed during inspection")
      pure bytes
  where
    -- @os.read@: an empty read at end of file.
    readChunk fd wanted = PosixBS.fdRead fd (fromIntegral wanted) `catchIOError` \e -> if isEOFError e then pure "" else throwIO e

-- | @_require_real_directories(paths)@.
requireRealDirectories :: [FilePath] -> IO ()
requireRealDirectories paths = do
  outcome <- try @IOException $ forM paths $ \path -> do
    info <- Posix.getSymbolicLinkStatus path
    pure (Posix.isSymbolicLink info || not (Posix.isDirectory info))
  case outcome of
    Left _ -> throwIO (ValueError "Instance state cannot be inspected safely")
    Right flags -> when (or flags) $ throwIO (ValueError "Instance state path is not a real directory")

-- | @_identifier(value, error)@.
identifier :: Json -> Text -> IO Text
identifier value message = case value of
  String text -> do
    -- @value.encode()@ raises @UnicodeEncodeError@ for a lone surrogate
    -- @json.loads@ kept, before any check.
    encoded <- either throwIO pure (utf8Encode text)
    if 0 < BS.length encoded && BS.length encoded <= maxIdentifierBytes && isAscii text && isPrintable text
      then pure text
      else throwIO (ValueError message)
  _ -> throwIO (ValueError message)



-- | A History instant: an @int@ or a finite @float@ (never a @bool@).
data Instant = IntInstant Integer | FloatInstant Double

instantValue :: Instant -> Rational
instantValue = \case
  IntInstant i -> fromInteger i
  FloatInstant d -> toRational d

instantJson :: Instant -> Json
instantJson = \case
  IntInstant i -> Int i
  FloatInstant d -> Float d

-- | @inspect_instance(state_path, installation_id, repository_id,
-- pull_request)@: a bounded, payload-free summary of one Instance's state.
inspectInstance :: FilePath -> Integer -> Integer -> Integer -> IO Json
inspectInstance statePath installationId repositoryId pullRequest = do
  when (minimum [installationId, repositoryId, pullRequest] <= 0) $
    throwIO (ValueError "Instance identifiers must be positive")
  let applications = statePath </> "applications"
      installationPath = applications </> show installationId
      repositoryPath = installationPath </> show repositoryId
      root = repositoryPath </> show pullRequest
  requireRealDirectories [statePath, applications, installationPath, repositoryPath, root]
  raw <- readBoundedRegular (root </> "history.jsonl") maxHistoryBytes
  boundBytes <- readBoundedRegular (root </> "binding.json") maxBindingBytes
  let unsafe = ValueError "Instance state cannot be inspected safely"
      decode bytes = either (const (throwIO unsafe)) pure (TE.decodeUtf8' bytes)
      loads text = either (const (throwIO unsafe)) pure (parseJson pythonJsonLoads (TE.encodeUtf8 text))
  boundValue <- decode boundBytes >>= loads
  records <- decode raw >>= mapM loads . splitlines
  bound <- either (const (throwIO (ValueError "Instance state binding is malformed"))) pure (parseInstanceBinding boundValue)
  let wellFormed = \case
        Object members | Just (String _) <- lookup' "record" members -> True
        _ -> False
  when (bound.pullRequest /= pullRequest || null records || not (all wellFormed records)) $
    throwIO (ValueError "Instance state binding or History is malformed")
  let expected = "github:" <> tshow installationId <> ":" <> tshow repositoryId <> ":pr:" <> tshow pullRequest
  instanceId <- identifier (String bound.instanceId) "Instance identity is malformed"
  repository <- identifier (String bound.repository) "Instance repository is malformed"
  when (instanceId /= expected) $
    throwIO (ValueError "Instance state binding does not match its selected path")
  requested <- newIORef Map.empty
  completed <- newIORef Set.empty
  failed <- newIORef Set.empty
  firingFailed <- newIORef Set.empty
  lastInstant <- newIORef (IntInstant 0)
  let malformedInstant = throwIO (ValueError "Instance History instant is malformed")
  mapM_
    ( \case
        Object members -> do
          instant <- case fromMaybe (Int 0) (lookup' "instant" members) of
            Int i
              | abs i >= floatOverflowInteger -> throwIO (PythonException "OverflowError" [PyStr "int too large to convert to float"])
              | otherwise -> pure (IntInstant i)
            Float d
              | isNaN d || isInfinite d -> malformedInstant
              | otherwise -> pure (FloatInstant d)
            _ -> malformedInstant
          modifyIORef' lastInstant (\current -> if instantValue instant > instantValue current then instant else current)
          let occurrence = case lookup' "occurrence" members of
                Just (Int i) -> Just i
                _ -> Nothing
              recordName = case lookup' "record" members of
                Just (String name) -> name
                _ -> ""
          case recordName of
            "ActivityRequested" -> do
              key <- case occurrence of
                Just i | i > 0 -> pure i
                _ -> throwIO (ValueError "Instance Activity identity is malformed")
              let input = lookup' "input" members
                  work = case input of
                    Just (Object fields) -> case lookup' "work" fields of
                      Just value -> Just value
                      Nothing -> lookup' "command" fields
                    _ -> Nothing
                  operation = case work of
                    Just (Object fields) -> fromMaybe Null (lookup' "operation" fields)
                    _ -> Null
              transition <- identifier (fromMaybe Null (lookup' "transition" members)) "Activity identifiers are malformed"
              activity <- identifier (fromMaybe Null (lookup' "activity" members)) "Activity identifiers are malformed"
              operation' <- identifier operation "Activity operation is malformed"
              modifyIORef'
                requested
                ( Map.insert
                    key
                    ( Object
                        [ ("occurrence", Int key)
                        , ("transition", String transition)
                        , ("activity", String activity)
                        , ("operation", String operation')
                        ]
                    )
                )
            "ActivityCompleted" | Just i <- occurrence -> modifyIORef' completed (Set.insert i)
            "ActivityFailed" | Just i <- occurrence -> modifyIORef' failed (Set.insert i)
            "FiringFailed" | Just i <- occurrence -> modifyIORef' firingFailed (Set.insert i)
            _ -> pure ()
        _ -> pure ()
    )
    records
  requestedMap <- readIORef requested
  completedSet <- readIORef completed
  failedSet <- readIORef failed
  firingSet <- readIORef firingFailed
  final <- readIORef lastInstant
  let unresolved =
        [ entry
        | (key, entry) <- Map.toAscList requestedMap
        , not (Set.member key completedSet || Set.member key failedSet)
        ]
  when (length unresolved > 1000) $
    throwIO (ValueError "Instance unresolved Activity inventory exceeds its bound")
  pure $
    Object
      [ ("command", String "inspect-instance")
      , ("instance_id", String instanceId)
      , ("repository", String repository)
      , ("pull_request", Int pullRequest)
      , ("topology", String (topologyText bound.topology))
      , ("record_count", Int (toInteger (length records)))
      , ("last_instant", instantJson final)
      ,
        ( "activities"
        , Object
            [ ("requested", Int (toInteger (Map.size requestedMap)))
            , ("completed", Int (toInteger (Set.size completedSet)))
            , ("failed", Int (toInteger (Set.size failedSet)))
            , ("firing_failed", Int (toInteger (Set.size firingSet)))
            , ("unresolved", Array unresolved)
            ]
        )
      , ("ok", Bool True)
      ]
  where
    -- The smallest magnitude CPython's int-to-float conversion refuses with
    -- @OverflowError@: 2^1024 - 2^970, the halfway point between DBL_MAX
    -- (2^1024 - 2^971) and 2^1024. Below it the integer rounds (half to
    -- even) to a finite double, at it the rounding reaches 2^1024.
    floatOverflowInteger = 2 ^ (1024 :: Int) - 2 ^ (970 :: Int) :: Integer

-- | @dict.get@: duplicate members resolve to the last one, as
-- @json.loads@ builds the dict.
lookup' :: Text -> [(Text, Json)] -> Maybe Json
lookup' key members = lookup key (reverse members)

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- ---------------------------------------------------------------------------
-- Running

-- | Everything the command line takes from its process, as seams.
data CliEnvironment = CliEnvironment
  { environment :: Map String String
  -- ^ @os.environ@.
  , forgetSecrets :: IO ()
  -- ^ @os.environ.pop@ of the two GitHub secrets once the configuration
  -- holds them.
  , loadConfig :: IO HostConfig
  -- ^ @HostConfig.from_environment()@.
  , clientOptions :: IO ClientOptions
  -- ^ The GitHub network (@GitHubAppClients(config)@'s transport).
  , composeAgent :: OwnedAgent -> FilePath -> IO (AgentRunner, AgentCustody)
  -- ^ The agent composition over the state path (the Pi installation,
  -- @compose_agent@, the route store, the workspace receiver and the Pi
  -- runtime); called only for the commands that open the service. Each
  -- resource is recorded in the 'OwnedAgent' as soon as it exists, so
  -- startup cleanup releases it when the service never opens.
  , columns :: IO Int
  -- ^ @shutil.get_terminal_size().columns@.
  , output :: Handle
  , errors :: Handle
  , onServing :: Int -> IO ()
  -- ^ Called once @serve@ listens, with the bound port.
  , reraise :: Signal -> IO ()
  -- ^ After SIGTERM stopped @serve@ gracefully: uvicorn's
  -- @signal.raise_signal@ with the previous (default) handler restored. In
  -- the process ('productionEnvironment') the default action, so the
  -- process ends by SIGTERM as the reference's does. It returns only when
  -- the kernel ignores that default action, as it does for PID 1 of a
  -- container; then @uvicorn.run@ returns, as the reference's does there,
  -- and 'runCli' ends with status 0.
  }

-- | The process's own environment: the real network, the real Pi A2
-- composition, standard streams.
productionEnvironment :: Map String String -> CliEnvironment
productionEnvironment environment =
  CliEnvironment
    { environment
    , forgetSecrets = mapM_ unsetEnv ["HAMSTERDAN_GITHUB_PRIVATE_KEY", "HAMSTERDAN_GITHUB_WEBHOOK_SECRET"]
    , loadConfig = fromEnvironment environment
    , clientOptions = defaultClientOptions
    , composeAgent = \owned ->
        composeHostAgent
          productionAgentSeams
          owned
          [ (T.pack name, T.pack value)
          | (name, value) <- Map.toList environment
          , name `notElem` ["HAMSTERDAN_GITHUB_PRIVATE_KEY", "HAMSTERDAN_GITHUB_WEBHOOK_SECRET"]
          ]
          (unsetEnv "HAMSTERDAN_PI_API_KEY")
    , columns = terminalColumns environment
    , output = stdout
    , errors = stderr
    , onServing = \_ -> pure ()
    , reraise = \signal -> installHandler signal Default Nothing >> raiseSignal signal
    }

-- | Why the reference's @except (ConfigurationError, RuntimeError,
-- ValueError)@ catches a failure, as @str(error)@; 'Nothing' for the
-- failures it lets escape.
handledMessage :: SomeException -> Maybe Text
handledMessage e
  | Just (ConfigurationError m) <- fromException e = Just m
  | Just (RuntimeError m) <- fromException e = Just m
  | Just (ValueError m) <- fromException e = Just m
  | Just (AgentCompositionError m) <- fromException e = Just m
  | Just (failure :: AgenticusError) <- fromException e
  , any (failure.errorClass `isSubclassOf`) [AE.ValueError, AE.RuntimeError] =
      Just failure.errorMessage
  | Just (boundaryError :: GitHubBoundaryError) <- fromException e = Just boundaryError.message
  | Just (ContractRefused m) <- fromException e = Just m
  | Just (InvalidRequest m) <- fromException e = Just m
  | Just (failure :: ClientError) <- fromException e
  , failure.kind `elem` [ValueKind, RuntimeKind] =
      Just failure.detail
  | Just failure@(PythonException name _) <- fromException e
  , name `elem` ["ValueError", "RuntimeError", "UnicodeError", "UnicodeDecodeError", "UnicodeEncodeError", "JSONDecodeError"] =
      Just (pythonExceptionStr failure)
  | otherwise = Nothing

-- | @main()@ with @sys.argv[1:]@; the exit status.
runCli :: CliEnvironment -> [Text] -> IO ExitCode
runCli env argv = do
  formatting <- formattingOf env.environment <$> env.columns <*> hIsTerminalDevice env.output
  let say handle text = BS.hPut handle (TE.encodeUtf8 text) >> hFlush handle
      escaped e = do
        say env.errors (uncaughtText e)
        pure (ExitFailure 1)
      hostDefault = maybe "127.0.0.1" T.pack (Map.lookup "HAMSTERDAN_HOST" env.environment)
      portText = maybe "8000" T.pack (Map.lookup "HAMSTERDAN_PORT" env.environment)
  case intText portText of
    Left failure -> escaped (toException failure)
    Right portDefault -> do
      let parser = hostParser hostDefault portDefault
          -- @parser().error(message)@.
          usageError message = do
            say env.errors (errorText formatting parser message)
            pure (ExitFailure 2)
          run command = do
            service <- newIORef Nothing
            owned <- newOwnedAgent
            let body = do
                  config <- env.loadConfig
                  env.forgetSecrets
                  case command of
                    InspectInstance i r p -> do
                      result <- inspectInstance config.statePath i r p
                      say env.output (dumpsSorted result <> "\n")
                      pure ExitSuccess
                    Validate -> do
                      opened <- open config
                      result <- reconcileRegistration opened
                      say env.output (dumpsSorted result <> "\n")
                      pure ExitSuccess
                    Inbox -> do
                      opened <- open config
                      counts <- Custody.counts opened.custody
                      failures <- Custody.failures opened.custody 100
                      let failureJson failure =
                            Object
                              [ ("delivery_id", String failure.deliveryId)
                              , ("event", String failure.event)
                              , ("attempts", Int (toInteger failure.attempts))
                              , ("error_class", maybe Null String failure.errorClass)
                              , ("reason", maybe Null String failure.reason)
                              ]
                      say env.output $
                        dumpsSorted
                          ( Object
                              [ ("counts", Object [(name, Int (toInteger count)) | (name, count) <- Map.toList counts])
                              , ("failures", Array (map failureJson failures))
                              ]
                          )
                          <> "\n"
                      pure ExitSuccess
                    Requeue deliveryId -> do
                      opened <- open config
                      requeued <- Custody.requeue opened.custody deliveryId
                      say env.output (dumpsSorted (Object [("delivery_id", String deliveryId), ("requeued", Bool requeued)]) <> "\n")
                      pure (if requeued then ExitSuccess else ExitFailure 1)
                    Serve host port -> do
                      opened <- open config
                      colors <- hIsTerminalDevice env.output
                      served <-
                        serve
                          opened
                          ServeOptions
                            { host = T.unpack host
                            , port = fromInteger port
                            , log = UvicornLog {errors = env.errors, access = env.output, colors}
                            , forwardedAllowIps = maybe "127.0.0.1" T.pack (Map.lookup "FORWARDED_ALLOW_IPS" env.environment)
                            , failureLine = tracebackLine
                            , onStarted = env.onServing
                            }
                      case served of
                        -- @sys.exit(STARTUP_FAILURE)@.
                        StartupFailed -> pure (ExitFailure 3)
                        -- SIGTERM, raised again: the default action, at once
                        -- (the @finally@ never runs; the lifespan has already
                        -- closed the service). When the process survives it
                        -- (PID 1 of a container, where the kernel ignores a
                        -- signal's default action), @uvicorn.run@ returns,
                        -- the @finally@ runs, status 0, as for SIGINT.
                        ShutDown (Just signal)
                          | signal == sigTERM -> do
                              env.reraise signal
                              pure ExitSuccess
                        -- SIGINT, raised again under @asyncio.run@'s own
                        -- handler, which only cancels uvicorn's main task, by
                        -- then finished: @uvicorn.run@ returns, the @finally@
                        -- runs, status 0.
                        ShutDown _ -> pure ExitSuccess
                -- Everything after @inspect-instance@'s early return: the
                -- topology check, the agent composition and @HostService@.
                open config = do
                  when (Map.member "HAMSTERDAN_READINESS_TOPOLOGY" env.environment) $
                    throwIO (ValueError "HAMSTERDAN_READINESS_TOPOLOGY is retired; remove it to run the V5 topology")
                  preflightV5State config.statePath
                  (runner, agents) <- env.composeAgent owned config.statePath
                  options <- env.clientOptions
                  appClients <-
                    newAppClients
                      AppCredentials {appId = config.appId, clientId = config.clientId, privateKey = revealSecret config.privateKey}
                      options
                  let workflowPath = maybe ".github/workflows/ci.yml" T.pack (Map.lookup "HAMSTERDAN_WORKFLOW_PATH" env.environment)
                  reminderDelay <-
                    either (throwIO . ValueError) pure $
                      pythonFloat (maybe "259200" T.pack (Map.lookup "HAMSTERDAN_REMINDER_SECONDS" env.environment))
                  qualificationFault <- qualificationFaultFromEnvironment (T.pack <$> Map.lookup "HAMSTERDAN_QUALIFICATION_FAULT" env.environment)
                  opened <-
                    openHostService
                      config
                      (serviceOptions runner agents)
                        { clients = Just (gitHubHostClients appClients)
                        , workflowPath
                        , reminderDelay
                        , qualificationFault
                        }
                  writeIORef service (Just opened)
                  pure opened
                -- @finally: _close_owned_resources(service, pi_runtime,
                -- route_store)@, after the @except@ clause has printed its
                -- usage error.
                cleanup = do
                  opened <- readIORef service
                  try @SomeException (closeOwnedAgent (Service.close <$> opened) owned)
            outcome <- try @SomeException body
            settled <- case outcome of
              Right code -> pure (Right code)
              Left e
                | Just message <- handledMessage e -> Right <$> usageError message
                | Just (code :: ExitCode) <- fromException e -> pure (Right code)
                | otherwise -> pure (Left e)
            closing <- cleanup
            case closing of
              Left failure -> escaped failure
              Right () -> either escaped pure settled
      case parse formatting parser argv of
        Exited status printed problems -> do
          say env.output printed
          say env.errors problems
          pure (if status == 0 then ExitSuccess else ExitFailure status)
        Parsed decoded -> either usageError run decoded
  where
    dumpsSorted value = either (const "null") id (dumpsText defaultDumps {Json.sortKeys = True} value)

-- | What an uncaught exception prints (the reference prints a traceback
-- ending in this line).
uncaughtText :: SomeException -> Text
uncaughtText e = tracebackLine e <> "\n"

-- | The last line of the traceback the reference prints for an exception
-- (@traceback.format_exception_only@): its class ('exceptionClass'),
-- qualified by its module unless it is a builtin, then @": "@ and
-- @str(error)@ when that is not empty.
tracebackLine :: SomeException -> Text
tracebackLine e@(SomeException inner)
  | Just failure <- fromException e = errorLine failure
  | otherwise = qualified (exceptionClass e) <> (if T.null message then "" else ": " <> message)
  where
    message
      | Just (failure :: AgenticusError) <- fromException e = failure.errorMessage
      | Just (failure :: ClientError) <- fromException e = failure.detail
      | otherwise = T.pack (displayException inner)
    qualified name = case lookup name modules of
      Just owner -> owner <> "." <> name
      Nothing
        | Just (failure :: ClientError) <- fromException e
        , failure.kind `elem` [TransportKind, HttpKind] ->
            "httpx." <> name
        | Just (failure :: ClientError) <- fromException e
        , failure.kind == GitHubKind ->
            "githubkit.exception." <> name
        | otherwise -> tracebackName name
    modules =
      [ ("GitHubBoundaryError", "hamsterdan.github_app.models")
      , ("RerunRefusedError", "hamsterdan.github_app.models")
      , ("GitHubObjectWriteError", "hamsterdan.github_app.gateway")
      , ("ConfigurationError", "hamsterdan.github_app.config")
      , ("WebhookRejected", "hamsterdan.github_app.webhooks")
      , ("UnstagedCustodyError", "hamsterdan.host.v5.gates")
      , ("AgentCompositionError", "hamsterdan.host.agenticus")
      , ("GitPublishError", "hamsterdan.host.git_publish")
      , ("AgentProtocolError", "hamsterdan.agents.protocol")
      , ("PiWorkspaceError", "hamsterdan.agents.pi")
      , ("PiWorkspaceCleanupError", "hamsterdan.agents.pi")
      , ("ActivityError", "petrus.motus.activity")
      ]
