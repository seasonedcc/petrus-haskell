-- | Docker container territories driven through the @docker@ CLI
-- (upstream @DockerEnvironment@).
--
-- Lookup is by container label, so a recreated adapter (or another
-- process) finds the same lease.  Workspaces move in and out only as
-- archives over @docker exec@ stdin/stdout; containers never get bind
-- mounts, and command secrets travel in the CLI's environment rather than
-- its argv.
module Petrus.Motus.Execution.Providers.Docker
  ( DockerEnvironment
  , DockerConfig (..)
  , defaultDockerConfig
  , newDockerEnvironment
  , newDockerEnvironmentWith
  , dockerProvider
  , dockerCapabilities
  , provision
  , dockerLookup
  ) where

import Control.Exception (SomeException, finally, fromException, throwIO, try)
import Control.Monad (forM_, unless, when)
import Data.ByteString (ByteString)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Json (Json (..))
import Petrus.Motus.Execution
import Petrus.Motus.Execution.Archive (extractWorkspaceArchive, workspaceArchive)
import Petrus.Motus.Execution.Internal.Common
import Petrus.Motus.Execution.Internal.Process
import Petrus.Json.Python (decodeUtf8Python, jsonTypeName, loadsText, pythonExceptionStr, pythonSplit, pythonStrRepr, pythonStrip)
import Petrus.Motus.Execution.Internal.PyText (pyStrRepr)
import System.Environment (getEnvironment)
import System.IO.Temp (withSystemTempDirectory)

data DockerConfig = DockerConfig
  { dockerExecutable :: FilePath
  -- ^ The CLI (upstream always runs @docker@ from @PATH@).
  , dockerTimeout :: Double
  -- ^ Per-invocation timeout of control commands (upstream: 120 s).
  }

defaultDockerConfig :: DockerConfig
defaultDockerConfig = DockerConfig "docker" 120

data DockerEnvironment = DockerEnvironment
  { dockerConfig :: DockerConfig
  , dockerProcesses :: IORef (Map Text Running)
  }

providerLabel :: Text
providerLabel = "docker"

dockerCapabilities :: Set Capability
dockerCapabilities = Set.fromList [capContainer, capExplicitEnvironment, capRecreatableLookup, capTerritoryCancellation, capWorkspace]

newDockerEnvironment :: IO DockerEnvironment
newDockerEnvironment = newDockerEnvironmentWith defaultDockerConfig

newDockerEnvironmentWith :: DockerConfig -> IO DockerEnvironment
newDockerEnvironmentWith config = DockerEnvironment config <$> newIORef Map.empty

dockerProvider :: DockerEnvironment -> EnvironmentProvider
dockerProvider env =
  EnvironmentProvider
    { providerName = providerLabel
    , providerCapabilities = dockerCapabilities
    , providerCreate = create env
    , providerLookup = dockerLookup env
    , providerAttach = attach env
    , providerExecute = execute env
    , providerExport = export env
    , providerCancel = cancel env
    , providerReconcile = reconcile env
    , providerDestroy = destroy env
    , providerPrivateFiles = Nothing
    }

provision :: DockerEnvironment -> Text -> EnvironmentSpec -> IO EnvironmentLease
provision = create

-- | The @(argv)@ tuple repr used by @CalledProcessError@ / @TimeoutExpired@.
argvRepr :: [String] -> String
argvRepr [single] = "(" <> pyStrRepr single <> ",)"
argvRepr items = "(" <> joinWith ", " (map pyStrRepr items) <> ")"
  where
    joinWith _ [] = ""
    joinWith _ [x] = x
    joinWith sep (x : xs) = x <> sep <> joinWith sep xs

-- | @subprocess.run(("docker", *args), capture_output=True, check=check, ...)@.
-- Raises @CalledProcessError@ / @TimeoutExpired@ (as 'OtherError') and
-- @FileNotFoundError@ (as 'OSError') like upstream.
docker :: DockerEnvironment -> [Text] -> Bool -> Maybe ByteString -> Double -> IO RunOutcome
docker env args check input seconds = do
  let config = dockerConfig env
      shown = "docker" : map T.unpack args
  host <- getEnvironment
  executable <- resolveExecutable [(T.pack k, T.pack v) | (k, v) <- host] (T.pack (dockerExecutable config))
  outcome <-
    try (runCaptured (spawnSpec (executable : map T.unpack args)) {spawnStdin = input} seconds)
  case outcome of
    Left (failure :: ExecutionError)
      | errorKind failure == TimeoutError ->
          throwExecution
            (OtherError "TimeoutExpired")
            (T.pack ("Command '" <> argvRepr shown <> "' timed out after " <> showSeconds seconds <> " seconds"))
      | otherwise -> throwIO failure
    Right result -> do
      -- @text=True@ (no input) decodes both streams in @communicate@,
      -- before the exit status is checked.
      when (isNothing input) $
        forM_ [outcomeStdout result, outcomeStderr result] $
          either (throwExecution ValueError) (const (pure ())) . decodeUtf8Python
      when (check && outcomeCode result /= 0) $
        throwExecution
          (OtherError "CalledProcessError")
          ( T.pack
              ( "Command '"
                  <> argvRepr shown
                  <> "' returned non-zero exit status "
                  <> show (outcomeCode result)
                  <> "."
              )
          )
      pure result
  where
    showSeconds s = if s == fromIntegral (round s :: Integer) then show (round s :: Integer) else show s

-- | Errors upstream treats as Docker transport failures
-- (@OSError, SubprocessError, ValueError@).
isTransportError :: SomeException -> Bool
isTransportError failure = case fromException failure of
  Just e -> errorKind e `elem` [OSError, ValueError, OtherError "CalledProcessError", OtherError "TimeoutExpired"]
  Nothing -> False

-- | @CompletedProcess.stdout@ of a text-mode run ('docker' has checked it
-- is UTF-8), with universal newlines.
stdoutText :: RunOutcome -> Text
stdoutText = T.replace "\r" "\n" . T.replace "\r\n" "\n" . TE.decodeUtf8 . outcomeStdout

-- | @json.loads(stdout)@: its @JSONDecodeError@ (a @ValueError@) with
-- CPython's text.
decodeJson :: Text -> IO Json
decodeJson text = either (throwExecution ValueError . pythonExceptionStr) pure (loadsText text)

-- | @value[key]@ on a decoded value, raising what CPython raises.
index :: Text -> Json -> IO Json
index key = \case
  Object members -> maybe (throwExecution KeyError (pythonStrRepr key)) pure (lookup key members)
  Array _ -> throwExecution TypeError "list indices must be integers or slices, not str"
  String _ -> throwExecution TypeError "string indices must be integers, not 'str'"
  other -> notSubscriptable other

-- | @value[0]@.
firstItem :: Json -> IO Json
firstItem = \case
  Array (item : _) -> pure item
  Array [] -> throwExecution (OtherError "IndexError") "list index out of range"
  Object _ -> throwExecution KeyError "0"
  String text
    | T.null text -> throwExecution (OtherError "IndexError") "string index out of range"
    | otherwise -> pure (String (T.take 1 text))
  other -> notSubscriptable other

notSubscriptable :: Json -> IO a
notSubscriptable value = throwExecution TypeError ("'" <> jsonTypeName value <> "' object is not subscriptable")

-- | @iter(value)@: a list's items, a dict's keys, a string's characters.
iterate' :: Json -> IO [Json]
iterate' = \case
  Array items -> pure items
  Object members -> pure (map (String . fst) members)
  String text -> pure (map String (T.chunksOf 1 text))
  other -> throwExecution TypeError ("'" <> jsonTypeName other <> "' object is not iterable")

-- | @any(...)@: stops at the first true item.
anyM :: (a -> IO Bool) -> [a] -> IO Bool
anyM predicate = \case
  [] -> pure False
  item : rest -> predicate item >>= \found -> if found then pure True else anyM predicate rest

truthy :: Json -> Bool
truthy = \case
  Null -> False
  Bool b -> b
  Int n -> n /= 0
  Float d -> d /= 0
  String t -> not (T.null t)
  Array items -> not (null items)
  Object members -> not (null members)

inspect :: DockerEnvironment -> Text -> IO Json
inspect env container = do
  result <- docker env ["inspect", container] True Nothing (dockerTimeout (dockerConfig env))
  firstItem =<< decodeJson (stdoutText result)

dockerLookup :: DockerEnvironment -> Text -> IO (Maybe EnvironmentLease)
dockerLookup env operation = do
  checkOperationId operation
  listed <-
    docker env ["ps", "--all", "--quiet", "--filter", "label=" <> operationLabel <> "=" <> operation] True Nothing (dockerTimeout (dockerConfig env))
  case pythonSplit (stdoutText listed) of
    [] -> pure Nothing
    [container] -> do
      info <- inspect env container
      mounts <- iterate' =<< index "Mounts" info
      bind <- anyM (fmap (== String "bind") . index "Type") mounts
      when bind (throwExecution RuntimeError "execution container unexpectedly has a bind mount")
      running <- truthy <$> (index "Running" =<< index "State" info)
      Just <$> either throwIO pure (mkEnvironmentLease operation providerLabel container dockerCapabilities (if running then Ready else Terminal))
    _ -> throwExecution RuntimeError (T.pack ("operation " <> pyStrRepr (T.unpack operation) <> " resolves to multiple containers"))

create :: DockerEnvironment -> Text -> EnvironmentSpec -> IO EnvironmentLease
create env operation spec = do
  checkOperationId operation
  image <- maybe (throwExecution ValueError "Docker requires an image") pure (specImage spec)
  requireSupportedCapabilities dockerCapabilities spec
  existing <- dockerLookup env operation
  case existing of
    Just lease -> do
      info <- inspect env (leaseId lease)
      labels <- index "Labels" =<< index "Config" info
      recorded <- case labels of
        Object members -> pure (lookup specLabel members)
        other -> throwExecution (OtherError "AttributeError") ("'" <> jsonTypeName other <> "' object has no attribute 'get'")
      when (recorded /= Just (String (specFingerprint spec))) $
        throwExecution ValueError "operation id collides with a materially different environment spec"
      when (leaseState lease == Terminal) $
        throwExecution RuntimeError "operation has a terminal prior territory; reconcile before retrying"
      pure lease
    Nothing -> do
      created <-
        docker
          env
          [ "run"
          , "--detach"
          , "--label"
          , operationLabel <> "=" <> operation
          , "--label"
          , specLabel <> "=" <> specFingerprint spec
          , "--workdir"
          , "/workspace"
          , "--entrypoint"
          , "/bin/sh"
          , image
          , "-c"
          , "mkdir -p /workspace; while :; do sleep 3600; done"
          ]
          True
          Nothing
          (dockerTimeout (dockerConfig env))
      dockerLookup env operation >>= \case
        Just lease -> pure lease
        Nothing -> do
          _ <- docker env ["rm", "--force", pythonStrip (stdoutText created)] False Nothing (dockerTimeout (dockerConfig env))
          throwExecution RuntimeError "created Docker lease could not be looked up"

currentReady :: DockerEnvironment -> EnvironmentLease -> IO Bool
currentReady env lease
  | leaseProvider lease /= providerLabel = pure False
  | otherwise = do
      current <- dockerLookup env (leaseOperationId lease)
      pure (current == Just lease && leaseState lease == Ready)

attach :: DockerEnvironment -> EnvironmentLease -> ByteString -> Text -> IO ExecutionAttachment
attach env lease archive digest = do
  ready <- currentReady env lease
  unless ready (throwExecution ValueError "attachment lease is not a current ready Docker territory")
  active <- Map.member (leaseId lease) <$> readIORef (dockerProcesses env)
  when active (throwExecution RuntimeError "Docker territory still has an active command")
  withSystemTempDirectory "petrus-docker-validate" (extractWorkspaceArchive archive)
  _ <-
    docker
      env
      ["exec", "-i", leaseId lease, "sh", "-c", "rm -rf /workspace && mkdir /workspace && tar -xf - -C /workspace"]
      True
      (Just archive)
      (dockerTimeout (dockerConfig env))
  identifier <- newUuid4
  either throwIO pure (mkExecutionAttachment identifier lease digest "/workspace")

execute :: DockerEnvironment -> ExecutionAttachment -> Command -> IO CommandResult
execute env attachment command = do
  unless (null (commandPrivateRoots command)) $
    throwExecution ValueError "Docker does not support the private-file-transfer capability"
  let lease = attachmentLease attachment
      provenance = leaseProvenance lease
  ready <- currentReady env lease
  unless ready (throwExecution ValueError "execution attachment is not a current ready Docker territory")
  active <- Map.member (leaseId lease) <$> readIORef (dockerProcesses env)
  when active (throwExecution RuntimeError "Docker territory already has an active command")
  current <- maybe (pure True) id (commandIsCurrent command)
  if not current
    then either throwIO pure (mkCommandResult (-15) "" "" False True False provenance)
    else do
      cwd <- checkedGuestCwd (T.pack (attachmentWorkspace attachment)) (commandCwd command)
      let names = map fst (commandEnvironment command)
          assignments = T.unwords [name <> "=\"${" <> name <> "}\"" | name <- names]
          wrapper = "exec env -i " <> assignments <> " \"$@\""
      host <- getEnvironment
      let inherited =
            [ (T.pack k, T.pack v)
            | (k, v) <- host
            , k `elem` ["HOME", "PATH"] || "DOCKER_" `T.isPrefixOf` T.pack k
            ]
          cliEnvironment =
            [(k, v) | (k, v) <- inherited, isNothing (lookup k (commandEnvironment command))] <> commandEnvironment command
          arguments =
            ["exec", "--workdir", cwd]
              <> concat [["--env", name] | name <- names]
              <> [leaseId lease, "sh", "-c", wrapper, "petrus-command"]
              <> commandArgv command
      executable <- resolveExecutable cliEnvironment (T.pack (dockerExecutable (dockerConfig env)))
      running <-
        spawnCaptured
          SpawnSpec
            { spawnArgv = executable : map T.unpack arguments
            , spawnCwd = Nothing
            , spawnEnv = Just [(T.unpack k, T.unpack v) | (k, v) <- cliEnvironment]
            , spawnNewSession = False
            , spawnStdin = Nothing
            , spawnRetain = commandOutputLimit command
            }
      modifyIORef' (dockerProcesses env) (Map.insert (leaseId lease) running)
      let quiet args = () <$ docker env args False Nothing (dockerTimeout (dockerConfig env))
          terminate = quiet ["kill", "--signal", "TERM", leaseId lease]
          kill = quiet ["kill", leaseId lease]
      ( do
          (capture, timedOut, superseded, overflow) <- collect running command terminate kill
          code <- maybe (-9) id <$> pollExit running
          let (out, err, truncated) = boundedResult (commandOutputLimit command) overflow capture
          either throwIO pure (mkCommandResult code out err timedOut superseded truncated provenance)
        )
        `finally` ( do
                      exited <- pollExit running
                      when (isNothing exited) $ do
                        _ <- try kill :: IO (Either SomeException ())
                        _ <- waitExitWithin running Nothing
                        pure ()
                      modifyIORef' (dockerProcesses env) (Map.delete (leaseId lease))
                  )

export :: DockerEnvironment -> ExecutionAttachment -> IO ByteString
export env attachment = do
  let lease = attachmentLease attachment
  current <- dockerLookup env (leaseOperationId lease)
  when (current /= Just lease) (throwExecution ValueError "execution attachment is no longer current")
  result <- docker env ["exec", leaseId lease, "tar", "-cf", "-", "-C", "/workspace", "."] True Nothing 60
  withSystemTempDirectory "petrus-docker-export" $ \root -> do
    extractWorkspaceArchive (outcomeStdout result) root
    workspaceArchive root

cancel :: DockerEnvironment -> EnvironmentLease -> Text -> IO ()
cancel env lease _reason = do
  outcome <- try (dockerLookup env (leaseOperationId lease))
  case outcome of
    Left failure
      | isTransportError failure -> pure ()
      | otherwise -> throwIO failure
    Right (Just current)
      | leaseIdentity current == leaseIdentity lease ->
          () <$ docker env ["kill", leaseId lease] False Nothing (dockerTimeout (dockerConfig env))
    Right _ -> pure ()

destroy :: DockerEnvironment -> EnvironmentLease -> IO CleanupResult
destroy env lease
  | leaseProvider lease /= providerLabel = pure (result Unverified "lease belongs to a different provider")
  | otherwise = do
      found <- try (dockerLookup env (leaseOperationId lease))
      case found of
        Left failure
          | isTransportError failure -> pure (result Unverified "Docker lookup failed before destroy")
          | otherwise -> throwIO failure
        Right Nothing -> pure (result NotCreated "no Docker container")
        Right (Just current)
          | leaseIdentity current /= leaseIdentity lease ->
              pure (result Unverified "operation resolves to a different Docker lease")
          | otherwise -> do
              remaining <- try $ do
                _ <- docker env ["rm", "--force", leaseId lease] False Nothing (dockerTimeout (dockerConfig env))
                dockerLookup env (leaseOperationId lease)
              case remaining of
                Left failure
                  | isTransportError failure -> pure (result Unverified "Docker cleanup could not be independently verified")
                  | otherwise -> throwIO failure
                Right Nothing -> pure (result Clean "")
                Right (Just _) -> pure (result Unverified "Docker container remains after destroy")
  where
    result = CleanupResult (leaseIdentity lease)

reconcile :: DockerEnvironment -> Text -> IO ReconcileResult
reconcile env operation = do
  found <- try (dockerLookup env operation)
  case found of
    Left failure
      | isTransportError failure -> pure (uncertainResult Nothing (maybe "" errorMessage (fromException failure)))
      | otherwise -> throwIO failure
    Right Nothing -> pure (retryableResult "no container")
    Right (Just lease)
      | leaseState lease == Terminal -> pure (terminalResult lease "")
      | otherwise -> pure (uncertainResult (Just lease) "container readiness does not prove operation outcome")
