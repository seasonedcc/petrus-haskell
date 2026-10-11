-- | E2B VM territories (upstream @E2bEnvironment@).
--
-- The provider is written against 'E2bSdk', a record mirroring exactly the
-- SDK surface upstream uses (@Sandbox.list/create/connect@,
-- @files.write/read/remove@, @commands.run@, command handles).  The default
-- loader is the native client of E2B's REST and envd APIs
-- ("Petrus.Motus.Execution.Providers.E2b.Http"), playing the part of
-- upstream's @importlib.import_module("e2b")@.  SDK objects and provider
-- credentials stay host-side.
module Petrus.Motus.Execution.Providers.E2b
  ( E2bEnvironment
  , E2bConfig (..)
  , defaultE2bConfig
  , newE2bEnvironment
  , e2bProvider
  , e2bCapabilities
  , provision
  , e2bWorkspace
    -- * SDK seam
  , E2bSdk (..)
  , E2bOptions (..)
  , E2bSandboxInfo (..)
  , E2bPaginator (..)
  , E2bSandbox (..)
  , E2bRunOptions (..)
  , E2bCommandResult (..)
  , E2bHandle (..)
  , missingSdk
  , httpSdkLoader
  , shlexQuote
  , shlexJoin
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (SomeAsyncException, SomeException, finally, fromException, throwIO, try)
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Petrus.Motus.Execution
import Petrus.Motus.Execution.Archive (extractWorkspaceArchive, workspaceArchive)
import Petrus.Motus.Execution.Internal.Common
import Petrus.Motus.Execution.Internal.PyText (pyStrRepr)
import Petrus.Motus.Execution.Providers.E2b.Http (httpSdkLoader)
import Petrus.Motus.Execution.Providers.E2b.Sdk
import System.Environment (lookupEnv)
import System.IO.Temp (withSystemTempDirectory)

data E2bConfig = E2bConfig
  { e2bApiKey :: Maybe Text
  , e2bSdkLoader :: IO E2bSdk
  , e2bLeaseTimeout :: Int
  }

-- | A loader that fails like upstream's when the @e2b@ module is not
-- installed, for configurations that must never reach E2B.
missingSdk :: IO E2bSdk
missingSdk = throwExecution (OtherError "ModuleNotFoundError") "No module named 'e2b'"

-- | Upstream's defaults: the API key from @E2B_API_KEY@, the real SDK
-- ('httpSdkLoader') and a 900-second lease timeout.
defaultE2bConfig :: E2bConfig
defaultE2bConfig = E2bConfig Nothing httpSdkLoader 900

data E2bEnvironment = E2bEnvironment
  { e2bConfig :: E2bConfig
  , e2bSandboxes :: IORef (Map Text E2bSandbox)
  , e2bCommands :: IORef (Map Text E2bHandle)
  }

providerLabel :: Text
providerLabel = "e2b"

e2bWorkspace :: Text
e2bWorkspace = "/home/user/workspace"

e2bCapabilities :: Set Capability
e2bCapabilities = Set.fromList [capCommandCancellation, capExplicitEnvironment, capRecreatableLookup, capVm, capWorkspace]

newE2bEnvironment :: E2bConfig -> IO E2bEnvironment
newE2bEnvironment config = do
  when (e2bLeaseTimeout config <= 0) (throwExecution ValueError "E2B lease timeout must be positive")
  E2bEnvironment config <$> newIORef Map.empty <*> newIORef Map.empty

e2bProvider :: E2bEnvironment -> EnvironmentProvider
e2bProvider env =
  EnvironmentProvider
    { providerName = providerLabel
    , providerCapabilities = e2bCapabilities
    , providerCreate = create env
    , providerLookup = lookupLease env
    , providerAttach = attach env
    , providerExecute = execute env
    , providerExport = export env
    , providerCancel = cancel env
    , providerReconcile = reconcile env
    , providerDestroy = destroy env
    , providerPrivateFiles = Nothing
    }

provision :: E2bEnvironment -> Text -> EnvironmentSpec -> IO EnvironmentLease
provision = create

sdk :: E2bEnvironment -> IO E2bSdk
sdk = e2bSdkLoader . e2bConfig

opts :: E2bEnvironment -> IO E2bOptions
opts env = case e2bApiKey (e2bConfig env) of
  Just key -> pure (E2bOptions (Just key))
  Nothing -> E2bOptions . fmap T.pack <$> lookupEnv "E2B_API_KEY"

sandboxFor :: E2bEnvironment -> EnvironmentLease -> IO E2bSandbox
sandboxFor env lease =
  Map.lookup (leaseId lease) <$> readIORef (e2bSandboxes env) >>= \case
    Just sandbox -> pure sandbox
    Nothing -> do
      client <- sdk env
      options <- opts env
      sandbox <- sdkConnect client options (leaseId lease) (Just (e2bLeaseTimeout (e2bConfig env)))
      modifyIORef' (e2bSandboxes env) (Map.insert (leaseId lease) sandbox)
      pure sandbox

listByOperation :: E2bEnvironment -> Text -> Int -> IO E2bPaginator
listByOperation env operation limit = do
  client <- sdk env
  options <- opts env
  sdkList client options (Map.singleton operationLabel operation) limit

lookupLease :: E2bEnvironment -> Text -> IO (Maybe EnvironmentLease)
lookupLease env operation = do
  checkOperationId operation
  paginator <- listByOperation env operation 2
  options <- opts env
  let collect found = do
        more <- paginatorHasNext paginator
        if more && length found < 2
          then paginatorNextItems paginator options >>= collect . (found <>)
          else pure found
  found <- collect []
  case found of
    [] -> pure Nothing
    [info] -> do
      let state = T.toLower (infoState info)
          leaseStateValue = if state `elem` ["running", "paused"] then Ready else Terminal
      Just <$> either throwIO pure (mkEnvironmentLease operation providerLabel (infoSandboxId info) e2bCapabilities leaseStateValue)
    _ -> throwExecution RuntimeError (T.pack ("operation " <> pyStrRepr (T.unpack operation) <> " resolves to multiple E2B sandboxes"))

create :: E2bEnvironment -> Text -> EnvironmentSpec -> IO EnvironmentLease
create env operation spec = do
  checkOperationId operation
  template <- maybe (throwExecution ValueError "E2B requires a template image") pure (specImage spec)
  requireSupportedCapabilities e2bCapabilities spec
  existing <- lookupLease env operation
  case existing of
    Just lease -> do
      paginator <- listByOperation env operation 1
      options <- opts env
      items <- paginatorNextItems paginator options
      info <- case items of
        item : _ -> pure item
        [] -> throwExecution (OtherError "IndexError") "list index out of range"
      when (Map.lookup specLabel (infoMetadata info) /= Just (specFingerprint spec)) $
        throwExecution ValueError "operation id collides with a materially different environment spec"
      when (leaseState lease == Terminal) $
        throwExecution RuntimeError "operation has a terminal prior VM; reconcile before retrying"
      pure lease
    Nothing -> do
      client <- sdk env
      options <- opts env
      sandbox <-
        sdkCreate client options template (e2bLeaseTimeout (e2bConfig env)) $
          Map.fromList [(operationLabel, operation), (specLabel, specFingerprint spec)]
      modifyIORef' (e2bSandboxes env) (Map.insert (sandboxId sandbox) sandbox)
      found <- try (lookupLease env operation)
      let forget = modifyIORef' (e2bSandboxes env) (Map.delete (sandboxId sandbox))
      case found of
        Left (failure :: SomeException) -> do
          _ <- try (sandboxKill sandbox) :: IO (Either SomeException ())
          forget
          throwIO failure
        Right (Just lease) -> pure lease
        Right Nothing -> do
          sandboxKill sandbox `finally` forget
          throwExecution RuntimeError "created E2B lease could not be looked up"

currentReady :: E2bEnvironment -> EnvironmentLease -> IO Bool
currentReady env lease
  | leaseProvider lease /= providerLabel = pure False
  | otherwise = do
      current <- lookupLease env (leaseOperationId lease)
      pure (current == Just lease && leaseState lease == Ready)

attach :: E2bEnvironment -> EnvironmentLease -> ByteString -> Text -> IO ExecutionAttachment
attach env lease archive digest = do
  ready <- currentReady env lease
  unless ready (throwExecution ValueError "attachment lease is not a current ready E2B VM")
  active <- Map.member (leaseId lease) <$> readIORef (e2bCommands env)
  when active (throwExecution RuntimeError "E2B territory still has an active command")
  withSystemTempDirectory "petrus-e2b-validate" (extractWorkspaceArchive archive)
  sandbox <- sandboxFor env lease
  suffix <- newUuid4
  let archivePath = "/tmp/petrus-input-" <> suffix <> ".tar"
      workspace = shlexQuote e2bWorkspace
  sandboxWriteFile sandbox archivePath archive
  runForeground
    sandbox
    ("rm -rf " <> workspace <> " && mkdir -p " <> workspace <> " && tar -xf " <> shlexQuote archivePath <> " -C " <> workspace)
    `finally` sandboxRemoveFile sandbox archivePath
  identifier <- newUuid4
  either throwIO pure (mkExecutionAttachment identifier lease digest (T.unpack e2bWorkspace))

execute :: E2bEnvironment -> ExecutionAttachment -> Command -> IO CommandResult
execute env attachment command = do
  unless (null (commandPrivateRoots command)) $
    throwExecution ValueError "E2B does not support the private-file-transfer capability"
  let lease = attachmentLease attachment
      provenance = leaseProvenance lease
      limit = commandOutputLimit command
  ready <- currentReady env lease
  unless ready (throwExecution ValueError "execution attachment is not a current ready E2B VM")
  active <- Map.member (leaseId lease) <$> readIORef (e2bCommands env)
  when active (throwExecution RuntimeError "E2B territory already has an active command")
  current <- fromMaybe (pure True) (commandIsCurrent command)
  if not current
    then either throwIO pure (mkCommandResult (-15) "" "" False True False provenance)
    else do
      cwd <- checkedGuestCwd (T.pack (attachmentWorkspace attachment)) (commandCwd command)
      sandbox <- sandboxFor env lease
      let timeoutSeconds = max 1 (maybe (fromIntegral (e2bLeaseTimeout (e2bConfig env))) secondsToDouble (commandTimeout command))
      handle <-
        sandboxRunBackground sandbox (shlexJoin (commandArgv command)) $
          E2bRunOptions (commandEnvironment command) (Just cwd) (Just timeoutSeconds)
      modifyIORef' (e2bCommands env) (Map.insert (leaseId lease) handle)
      ( do
          stdoutParts <- newIORef []
          stderrParts <- newIORef []
          completed <- newEmptyMVar
          let append ref part = atomicModifyIORef' ref (\parts -> (part : parts, ()))
          _ <- forkIO (try (handleWait handle (append stdoutParts) (append stderrParts)) >>= putMVar completed)
          start <- getMonotonicTime
          let deadline = fmap ((start +) . secondsToDouble) (commandTimeout command)
              waitFor seconds = do
                finishAt <- (+ seconds) <$> getMonotonicTime
                let loop =
                      tryReadMVar completed >>= \case
                        Just _ -> pure True
                        Nothing -> do
                          now <- getMonotonicTime
                          if now >= finishAt then pure False else threadDelay 2000 >> loop
                loop
              poll = do
                done <- isJust' <$> tryReadMVar completed
                if done
                  then pure (False, False, False)
                  else do
                    size <- outputSize stdoutParts stderrParts
                    let overflow = size > limit
                    superseded <- case commandIsCurrent command of
                      Nothing -> pure False
                      Just isCurrent -> do
                        observed <- try isCurrent
                        case observed of
                          Right value -> pure (not value)
                          Left (failure :: SomeException) -> do
                            handleKill handle
                            _ <- waitFor 5
                            throwIO failure
                    now <- getMonotonicTime
                    let timedOut = maybe False (now >=) deadline
                    if overflow || superseded || timedOut
                      then handleKill handle >> pure (timedOut, superseded, overflow)
                      else waitFor 0.05 >> poll
          (timedOut, superseded, overflowSeen) <- poll
          finished <- waitFor 5
          unless finished (throwExecution RuntimeError "E2B command did not terminate after cancellation")
          value <- readMVar completed
          let cancelled = overflowSeen || superseded || timedOut
          (code, resultOut, resultErr) <- case value of
            Right result -> pure (commandExitCode result, Just (commandStdout result), Just (commandStderr result))
            Left (failure :: SomeException)
              | cancelled -> pure (-9, Nothing, Nothing)
              | otherwise -> throwIO failure
          outParts <- reverse <$> readIORef stdoutParts
          errParts <- reverse <$> readIORef stderrParts
          let pick parts fallback = if null parts then maybe [] (\t -> [t | not (T.null t)]) fallback else parts
              stdoutBytes = TE.encodeUtf8 (T.concat (pick outParts resultOut))
              stderrBytes = TE.encodeUtf8 (T.concat (pick errParts resultErr))
              overflow = overflowSeen || B.length stdoutBytes + B.length stderrBytes > limit
              out = B.take limit stdoutBytes
              err = B.take (max 0 (limit - B.length out)) stderrBytes
          either throwIO pure (mkCommandResult code out err timedOut superseded overflow provenance)
        )
        `finally` modifyIORef' (e2bCommands env) (Map.delete (leaseId lease))
  where
    isJust' = maybe False (const True)
    outputSize stdoutParts stderrParts = do
      outParts <- readIORef stdoutParts
      errParts <- readIORef stderrParts
      pure (sum (map (B.length . TE.encodeUtf8) (outParts <> errParts)))

export :: E2bEnvironment -> ExecutionAttachment -> IO ByteString
export env attachment = do
  let lease = attachmentLease attachment
  current <- lookupLease env (leaseOperationId lease)
  when (current /= Just lease) (throwExecution ValueError "execution attachment is no longer current")
  sandbox <- sandboxFor env lease
  suffix <- newUuid4
  let archivePath = "/tmp/petrus-output-" <> suffix <> ".tar"
  runForeground sandbox ("tar -cf " <> shlexQuote archivePath <> " -C " <> shlexQuote e2bWorkspace <> " .")
  raw <- sandboxReadFile sandbox archivePath `finally` sandboxRemoveFile sandbox archivePath
  withSystemTempDirectory "petrus-e2b-export" $ \root -> do
    extractWorkspaceArchive raw root
    workspaceArchive root

-- | @sandbox.commands.run(command, timeout=60)@, which raises the SDK's
-- @CommandExitException@ for a non-zero exit.
runForeground :: E2bSandbox -> Text -> IO ()
runForeground sandbox command = do
  result <- sandboxRun sandbox command (E2bRunOptions [] Nothing (Just 60))
  unless (commandExitCode result == 0) $
    throwExecution
      (OtherError "CommandExitException")
      ("Command exited with code " <> T.pack (show (commandExitCode result)) <> " and error:\n" <> commandStderr result)

-- | Upstream catches every @Exception@ here; asynchronous exceptions still
-- propagate.
catchingAll :: IO a -> IO (Either SomeException a)
catchingAll action =
  try action >>= \case
    Left failure | isAsync failure -> throwIO failure
    other -> pure other
  where
    isAsync failure = case fromException failure :: Maybe SomeAsyncException of
      Just _ -> True
      Nothing -> False

cancel :: E2bEnvironment -> EnvironmentLease -> Text -> IO ()
cancel env lease _reason =
  catchingAll (lookupLease env (leaseOperationId lease)) >>= \case
    Right (Just current) | leaseIdentity current == leaseIdentity lease -> do
      handle <- Map.lookup (leaseId lease) <$> readIORef (e2bCommands env)
      mapM_ handleKill handle
    _ -> pure ()

destroy :: E2bEnvironment -> EnvironmentLease -> IO CleanupResult
destroy env lease
  | leaseProvider lease /= providerLabel = pure (result Unverified "lease belongs to a different provider")
  | otherwise =
      catchingAll (lookupLease env (leaseOperationId lease)) >>= \case
        Left _ -> pure (result Unverified "E2B lookup failed before destroy")
        Right Nothing -> pure (result NotCreated "no E2B VM")
        Right (Just current)
          | leaseIdentity current /= leaseIdentity lease -> pure (result Unverified "operation resolves to a different E2B lease")
          | otherwise -> do
              cancel env lease "destroy"
              known <- Map.lookup (leaseId lease) <$> readIORef (e2bSandboxes env)
              reached <- case known of
                Just sandbox -> pure (Right sandbox)
                Nothing -> catchingAll $ do
                  client <- sdk env
                  options <- opts env
                  sdkConnect client options (leaseId lease) Nothing
              case reached of
                Left _ -> pure (result Unverified "E2B VM could not be reached for destroy")
                Right sandbox -> do
                  remaining <- catchingAll $ do
                    sandboxKill sandbox
                    modifyIORef' (e2bSandboxes env) (Map.delete (leaseId lease))
                    lookupLease env (leaseOperationId lease)
                  pure $ case remaining of
                    Left _ -> result Unverified "E2B cleanup could not be independently verified"
                    Right Nothing -> result Clean ""
                    Right (Just _) -> result Unverified "E2B VM remains after destroy"
  where
    result = CleanupResult (leaseIdentity lease)

reconcile :: E2bEnvironment -> Text -> IO ReconcileResult
reconcile env operation =
  catchingAll (lookupLease env operation) >>= \case
    Left failure -> pure (uncertainResult Nothing (exceptionText failure))
    Right Nothing -> pure (retryableResult "no E2B VM")
    Right (Just lease)
      | leaseState lease == Terminal -> pure (terminalResult lease "")
      | otherwise -> pure (uncertainResult (Just lease) "VM readiness does not prove operation outcome")
  where
    exceptionText failure = maybe (T.pack (show failure)) errorMessage (fromException failure)

-- | @shlex.quote@.
shlexQuote :: Text -> Text
shlexQuote value
  | T.null value = "''"
  | T.all safe value = value
  | otherwise = "'" <> T.replace "'" "'\"'\"'" value <> "'"
  where
    safe c = isAsciiUpper c || isAsciiLower c || isDigit c || c `elem` ("_@%+=:,./-" :: String)

-- | @shlex.join@.
shlexJoin :: [Text] -> Text
shlexJoin = T.unwords . map shlexQuote
