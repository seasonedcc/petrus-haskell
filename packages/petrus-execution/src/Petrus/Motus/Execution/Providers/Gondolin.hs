
-- | Gondolin micro-VM territories (upstream @_execution/gondolin.py@).
--
-- Every lease owns one authenticated Node sidecar running the verbatim
-- upstream @gondolin_sidecar.mjs@ against an explicitly named Gondolin SDK.
-- The provider talks to it over a private Unix socket, one compact JSON
-- line each way, with eleven actions (@handshake@, @status@, @attach@,
-- @export@, @close@, @execute@ and the five @private_*@ actions).  Every
-- request carries the lease id and a boot token that never appears in a
-- process command line.
--
-- Durable custody lives in a per-operation directory
-- @root/sha256(operation_id)[:24]@ holding a @lock@ (BSD @flock@,
-- re-validated against the path after acquisition), the @registry.json@
-- record (sorted-key @json.dumps@, mode 0600, atomically replaced) and the
-- @workspace@ transfer directory mounted into the VM.  The sidecar's
-- runtime directory (@/tmp/petrus-g-*@, socket, stderr, session registry)
-- is removed only after its process group is verified empty; process
-- groups are signalled only when every member is attributable to the
-- lease, so a reused PID or process group fails closed.
module Petrus.Motus.Execution.Providers.Gondolin
  ( -- * Provider
    GondolinEnvironment
  , GondolinConfig (..)
  , gondolinConfig
  , GondolinHooks (..)
  , noHooks
  , newGondolinEnvironment
  , gondolinProvider
  , gondolinCapabilities
  , gondolinVersion
  , gondolinRoot
  , provision
  , gondolinLookup
    -- * Custody state
  , Registry (..)
  , Identity (..)
  , operationDirectory
  , readRegistry
  , withOperationLock
  , sidecarRequest
    -- * Process identity
  , GroupMember (..)
  , ProcessInspector (..)
  , systemInspector
  , processIdentity
  , processIdentityWith
  , psIdentity
  , groupMembers
  , groupIdentities
  , cleanupGroup
    -- * The embedded sidecar
  , sidecarSource
  , sidecarSha256
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception
  ( Handler (..)
  , IOException
  , SomeException
  , bracket
  , catch
  , catches
  , finally
  , onException
  , throwIO
  , try
  )
import Control.Monad (forM, forM_, unless, void, when)
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random (getRandomBytes)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Base64.URL qualified as B64URL
import Data.ByteString.Char8 qualified as BC
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, isSpace)
import Data.IORef
import Data.List (isPrefixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import Data.Void (Void, absurd)
import GHC.Clock (getMonotonicTime)
import Network.Socket (Family (AF_UNIX), SockAddr (SockAddrUnix), Socket, SocketType (Stream), close, connect, defaultProtocol, socket, withFdSocket)
import Network.Socket.ByteString (recv, sendAll)
import Petrus.Json (EncodeOptions (..), Json (..), defaultDumps, dumps, lookupMember, pythonFloatRepr, pythonTruthy)
import Petrus.Motus.Execution
import Petrus.Motus.Execution.Archive (extractWorkspaceArchive, maxWorkspaceArchiveBytes, workspaceArchive)
import Petrus.Motus.Execution.Internal.Common (checkedGuestCwd, newUuid4, replaceFile, requireSupportedCapabilities, specFingerprint, uuidHex)
import Petrus.Posix.At (FileStat (..), fdStat)
import Petrus.Posix.Flock (LockKind (..), lock)
import Petrus.Posix.Poll qualified as Poll
import Petrus.Motus.Execution.Internal.Process (Child, StdioFd (..), childExitCode, childPid, resolveExecutable, signalChild, spawnChild)
import Petrus.Json.Python (jsonTypeName, loadsBytes, loadsText, pythonExceptionStr, pythonStr, pythonStrRepr)
import Petrus.Motus.Execution.Internal.PyText (textModeDecode)
import Data.Bifunctor qualified as Bifunctor
import Petrus.Motus.Execution.Internal.Sidecar (sidecarSha256, sidecarSource)
import System.Directory (doesDirectoryExist, doesPathExist, listDirectory, removeDirectory, removeDirectoryRecursive, removeFile)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO (Handle, hClose)
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Directory (createDirectory)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileAccess
  , fileExist
  , fileID
  , fileOwner
  , fileSize
  , getFileStatus
  , getSymbolicLinkStatus
  , isDirectory
  , isRegularFile
  , isSymbolicLink
  , setFileMode
  )
import System.Posix.IO (OpenFileFlags (..), OpenMode (..), closeFd, defaultFileFlags, fdToHandle, openFd)
import System.Posix.Process (getProcessStatus)
import System.Posix.Signals (Signal, sigKILL, sigTERM, signalProcessGroup)
import System.Posix.Temp (mkdtemp)
import System.Posix.Types (Fd (..))
import System.Posix.User (getRealUserID)
import System.Process (proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)

-- ---------------------------------------------------------------------------
-- Configuration

-- | The SDK version the sidecar pins.
gondolinVersion :: Text
gondolinVersion = "0.12.0"

maxFrame :: Int
maxFrame = 8 * 1024 * 1024

providerLabel :: Text
providerLabel = "gondolin"

gondolinCapabilities :: Set Capability
gondolinCapabilities =
  Set.fromList
    [ capExplicitEnvironment
    , capMicrovm
    , capPrivateFileTransfer
    , capRecreatableLookup
    , capTerritoryCancellation
    , capVm
    , capWorkspace
    ]

-- | Injection points standing in for upstream tests' monkeypatching.  Each
-- may throw to simulate a failure at that point.
data GondolinHooks = GondolinHooks
  { hookRequest :: Text -> IO ()
  -- ^ Before every control request, with its action.
  , hookWriteRegistry :: IO ()
  -- ^ Before every registry write.
  , hookRuntimeCreated :: FilePath -> IO ()
  -- ^ After each sidecar runtime directory is created.
  , hookLockOpened :: IO ()
  -- ^ After the lock file is opened, before it is locked.
  }

noHooks :: GondolinHooks
noHooks = GondolinHooks (const (pure ())) (pure ()) (const (pure ())) (pure ())

data GondolinConfig = GondolinConfig
  { gondolinSdkModule :: Text
  -- ^ Explicit Gondolin SDK module URL or path (required).
  , gondolinNode :: FilePath
  -- ^ The Node executable (default @node@, searched in @PATH@).
  , gondolinLeaseTtl :: Seconds
  -- ^ Sidecar lease TTL (default 900); rendered with Python @str()@.
  , gondolinStartupTimeout :: Double
  -- ^ Readiness deadline in seconds (default 120).
  , gondolinSidecar :: Maybe FilePath
  -- ^ Run this sidecar file instead of the embedded verbatim copy.
  , gondolinInspector :: ProcessInspector
  , gondolinHooks :: GondolinHooks
  }

-- | Upstream defaults for an SDK module.
gondolinConfig :: Text -> GondolinConfig
gondolinConfig sdk = GondolinConfig sdk "node" 900 120 Nothing systemInspector noHooks

data GondolinEnvironment = GondolinEnvironment
  { gondolinRoot :: FilePath
  , environmentConfig :: GondolinConfig
  }

newGondolinEnvironment :: FilePath -> GondolinConfig -> IO GondolinEnvironment
newGondolinEnvironment root config = pythonic $ do
  when (secondsToDouble (gondolinLeaseTtl config) <= 0) $
    throwExecution ValueError "Gondolin lease TTL must be positive"
  when (gondolinStartupTimeout config <= 0) $
    throwExecution ValueError "Gondolin startup timeout must be positive"
  when (T.null (gondolinSdkModule config)) $
    throwExecution ValueError "Gondolin requires an explicit SDK module URL or path"
  mkdirParents root
  setFileMode root 0o700
  pure (GondolinEnvironment root config)
  where
    mkdirParents path = do
      exists <- doesDirectoryExist path
      unless exists $ do
        let parent = takeDirectory path
        when (parent /= path) (mkdirParents parent)
        createDirectory path 0o700 `catch` \(e :: IOException) -> do
          now <- doesDirectoryExist path
          unless now (throwIO e)

gondolinProvider :: GondolinEnvironment -> EnvironmentProvider
gondolinProvider env =
  EnvironmentProvider
    { providerName = providerLabel
    , providerCapabilities = gondolinCapabilities
    , providerCreate = create env
    , providerLookup = gondolinLookup env
    , providerAttach = attach env
    , providerExecute = execute env
    , providerExport = export env
    , providerCancel = cancel env
    , providerReconcile = reconcile env
    , providerDestroy = destroy env
    , providerPrivateFiles =
        Just
          PrivateFileTransfer
            { importPrivateFile = importPrivate env
            , exportPrivateFile = exportPrivate env
            , deletePrivateFile = deletePrivate env
            , cleanupPrivateFiles = cleanupPrivate env
            }
    }

-- | Compatibility spelling of 'providerCreate'.
provision :: GondolinEnvironment -> Text -> EnvironmentSpec -> IO EnvironmentLease
provision = create

inspector :: GondolinEnvironment -> ProcessInspector
inspector = gondolinInspector . environmentConfig

hooks :: GondolinEnvironment -> GondolinHooks
hooks = gondolinHooks . environmentConfig

-- ---------------------------------------------------------------------------
-- Error plumbing

-- | Surface @IOException@s as the @OSError@ upstream raises.
pythonic :: IO a -> IO a
pythonic action = action `catch` \(e :: IOException) -> throwIO (osErrorFromIO e)

attempt :: IO a -> IO (Either ExecutionError a)
attempt action =
  (Right <$> action)
    `catches` [Handler (pure . Left), Handler (\(e :: IOException) -> pure (Left (osErrorFromIO e)))]

-- | @try: ... except (kinds): ...@ — other failures propagate.
catching :: (ErrorKind -> Bool) -> IO a -> IO (Either ExecutionError a)
catching wanted action =
  attempt action >>= \case
    Left failure
      | wanted (errorKind failure) -> pure (Left failure)
      | otherwise -> throwIO failure
    Right value -> pure (Right value)

-- | @OSError@ and its subclasses @ConnectionError@ and @TimeoutError@.
osFamily :: ErrorKind -> Bool
osFamily kind = kind `elem` [OSError, ConnectionError, TimeoutError]

-- | @KeyError, OSError, RuntimeError, TypeError, ValueError,
-- subprocess.SubprocessError@.
custodyFailure :: ErrorKind -> Bool
custodyFailure kind =
  osFamily kind
    || kind `elem` [KeyError, RuntimeError, TypeError, ValueError, OtherError "CalledProcessError", OtherError "TimeoutExpired"]

ignoring :: forall a. IO a -> IO ()
ignoring action = void (try action :: IO (Either SomeException a))

removeIfExists :: FilePath -> IO ()
removeIfExists path = removeFile path `catch` \(e :: IOException) -> unless (isDoesNotExistError e) (throwIO e)

sleepSeconds :: Double -> IO ()
sleepSeconds seconds = threadDelay (round (seconds * 1000000))

-- ---------------------------------------------------------------------------
-- Operation directories, lock and registry

-- | @_operation@: a non-empty label of at most 128 safe characters.
checkOperation :: Text -> IO ()
checkOperation value =
  when (T.null value || T.length value > 128 || T.any (not . allowed) value) $
    throwExecution ValueError "operation id must be a safe non-empty provider label"
  where
    allowed c = isAsciiUpper c || isAsciiLower c || isDigit c || c `elem` ("_.-" :: String)

-- | @root / sha256(operation_id)[:24]@.
operationDirectory :: GondolinEnvironment -> Text -> FilePath
operationDirectory env operation =
  gondolinRoot env </> take 24 (show (hash (TE.encodeUtf8 operation) :: Digest SHA256))

-- | Run with the operation's exclusive lock held.  The lock is re-validated
-- after acquisition: when a concurrent destroy unlinked the inode this
-- waiter locked, it starts over on the fresh lock file.
withOperationLock :: GondolinEnvironment -> Text -> (FilePath -> IO a) -> IO a
withOperationLock env operation body = bracket acquire closeFd (const (body directory))
  where
    directory = operationDirectory env operation
    lockPath = directory </> "lock"
    acquire :: IO Fd
    acquire = do
      createDirectory directory 0o700 `catch` \(e :: IOException) -> do
        exists <- doesDirectoryExist directory
        unless exists (throwIO e)
      fd <- openFd lockPath ReadWrite defaultFileFlags {creat = Just 0o600, cloexec = True}
      held <-
        ( do
            hookLockOpened (hooks env)
            lock fd Exclusive
            held <- fdStat fd
            now <- try (getFileStatus lockPath)
            pure (either (\(_ :: IOException) -> False) (sameInode held) now)
        )
          `onException` closeFd fd
      if held then pure fd else closeFd fd >> acquire
    sameInode :: FileStat -> FileStatus -> Bool
    sameInode held status = (statDevice held, statInode held) == (fromIntegral (deviceID status), fromIntegral (fileID status))

-- | A process identity snapshot (upstream's @_identity@ dict).
data Identity = Identity
  { identityState :: Text
  -- ^ @present@, @missing@ or @uninspectable@.
  , identityMarker :: Maybe Text
  , identityCommand :: Maybe Text
  }
  deriving stock (Eq, Show)

missingIdentity :: Identity
missingIdentity = Identity "missing" Nothing Nothing

identityJson :: Identity -> Json
identityJson identity =
  Object
    ( [("state", String (identityState identity))]
        <> maybe [] (\m -> [("marker", String m)]) (identityMarker identity)
        <> maybe [] (\c -> [("command", String c)]) (identityCommand identity)
    )

identityFromJson :: Json -> Identity
identityFromJson value = Identity (fromMaybe "" (text "state")) (text "marker") (text "command")
  where
    text key = case lookupMember key value of
      Just (String t) -> Just t
      _ -> Nothing

-- | The persisted @registry.json@ record.  'Show' never renders the boot
-- token.
data Registry = Registry
  { registryOperationId :: Text
  , registryLeaseId :: Text
  , registrySpecFingerprint :: Text
  , registryBootToken :: Text
  , registryPid :: Int
  , registryPgid :: Int
  , registryStartIdentity :: Identity
  , registrySocket :: Text
  , registryRuntime :: Text
  , registryWorkspace :: Text
  , registrySdkModule :: Text
  , registrySdkVersion :: Text
  , registryImage :: Text
  , registryGroupIdentities :: Maybe (Map Text Text)
  , registryPrivateFileTransfer :: Bool
  }
  deriving stock (Eq)

instance Show Registry where
  showsPrec d r =
    showParen (d > 10) $
      showString "Registry {operation_id = "
        . shows (registryOperationId r)
        . showString ", lease_id = "
        . shows (registryLeaseId r)
        . showString ", pid = "
        . shows (registryPid r)
        . showString ", runtime = "
        . shows (registryRuntime r)
        . showString "}"

registryJson :: Registry -> Json
registryJson r =
  Object
    ( [ ("operation_id", String (registryOperationId r))
      , ("lease_id", String (registryLeaseId r))
      , ("spec_fingerprint", String (registrySpecFingerprint r))
      , ("boot_token", String (registryBootToken r))
      , ("pid", Int (fromIntegral (registryPid r)))
      , ("pgid", Int (fromIntegral (registryPgid r)))
      , ("start_identity", identityJson (registryStartIdentity r))
      , ("socket", String (registrySocket r))
      , ("runtime", String (registryRuntime r))
      , ("workspace", String (registryWorkspace r))
      , ("sdk_module", String (registrySdkModule r))
      , ("sdk_version", String (registrySdkVersion r))
      , ("image", String (registryImage r))
      ]
        <> maybe [] (\ids -> [("group_identities", Object [(k, String v) | (k, v) <- Map.toList ids])]) (registryGroupIdentities r)
        <> [("private_file_transfer", Bool True) | registryPrivateFileTransfer r]
    )

registryFromJson :: Json -> Either ExecutionError Registry
registryFromJson value = case value of
  Object _ ->
    Registry
      <$> text "operation_id"
      <*> text "lease_id"
      <*> text "spec_fingerprint"
      <*> text "boot_token"
      <*> int "pid"
      <*> int "pgid"
      <*> (identityFromJson <$> member "start_identity")
      <*> text "socket"
      <*> text "runtime"
      <*> text "workspace"
      <*> text "sdk_module"
      <*> text "sdk_version"
      <*> text "image"
      <*> pure groups
      <*> pure (maybe False pythonTruthy (lookupMember "private_file_transfer" value))
  _ -> Left (typeError "Gondolin registry must be a JSON object")
  where
    member key = maybe (Left (ExecutionError KeyError (pythonStrRepr key))) Right (lookupMember key value)
    text key =
      member key >>= \case
        String t -> Right t
        _ -> Left (typeError ("Gondolin registry field " <> key <> " must be a string"))
    int key =
      member key >>= \case
        Int n -> Right (fromInteger n)
        _ -> Left (typeError ("Gondolin registry field " <> key <> " must be an integer"))
    groups = case lookupMember "group_identities" value of
      Just (Object members) -> Just (Map.fromList [(k, v) | (k, String v) <- members])
      _ -> Nothing

-- | @_read@: the operation's registry record, if any.
readRegistry :: FilePath -> IO (Maybe Registry)
readRegistry directory = do
  contents <- try (B.readFile (directory </> "registry.json"))
  case contents of
    Left e
      | isDoesNotExistError e -> pure Nothing
      | otherwise -> throwIO (osErrorFromIO e)
    Right bytes -> case textModeDecode bytes >>= Bifunctor.first pythonExceptionStr . loadsText of
      Left problem -> throwExecution ValueError problem
      Right value -> either throwIO (pure . Just) (registryFromJson value)

-- | @_write@: @json.dumps(record, sort_keys=True)@, 0600, fsync, replace.
writeRegistry :: GondolinEnvironment -> FilePath -> Registry -> IO ()
writeRegistry env directory record = do
  hookWriteRegistry (hooks env)
  bytes <- either (const (throwExecution ValueError "Gondolin registry is not encodable")) pure (dumps defaultDumps {sortKeys = True} (registryJson record))
  replaceFile ((\hex -> "registry." <> T.unpack hex <> ".tmp") <$> uuidHex) (directory </> "registry.json") bytes

-- | @_remove_runtime@: remove a sidecar runtime only when it is provably
-- ours (a real directory directly under @/tmp@, named @petrus-g-*@, owned
-- by this user).
removeRuntime :: Registry -> IO ()
removeRuntime record = do
  let runtime = T.unpack (registryRuntime record)
  status <- try (getSymbolicLinkStatus runtime)
  case status of
    Left e
      | isDoesNotExistError e -> pure ()
      | otherwise -> throwIO e
    Right metadata -> do
      uid <- getRealUserID
      when
        ( takeDirectory runtime /= "/tmp"
            || not ("petrus-g-" `isPrefixOf` takeFileName runtime)
            || isSymbolicLink metadata
            || not (isDirectory metadata)
            || fileOwner metadata /= uid
        )
        (throwExecution RuntimeError "Gondolin runtime custody is uncertain; registry retained")
      removeDirectoryRecursive runtime

-- ---------------------------------------------------------------------------
-- Sidecar protocol

-- | Connect, send one request line and read one response line (at most
-- 8 MiB).  Every socket operation waits at most @tick@ seconds; when a
-- receive times out, @onTick@ either keeps waiting ('Nothing') or ends the
-- exchange with its value. The connect needs no timer: a Unix-socket
-- connect never waits (the kernel connects or refuses at once, and
-- @connect@ waits only on @EINPROGRESS@), as under CPython's
-- @settimeout@. A timer costs about 0.6 µs of a 30 µs handshake
-- (bench/RESULTS.md).
exchange :: FilePath -> Double -> ByteString -> IO (Maybe a) -> IO (Either a Json)
exchange path tick payload onTick =
  bracket (socket AF_UNIX Stream defaultProtocol) close $ \client -> do
    connect client (SockAddrUnix path)
    within (sendAll client payload)
    receive client [] 0
  where
    micros = max 1 (round (tick * 1000000))
    within action = timeout micros action >>= maybe (throwExecution TimeoutError "timed out") pure
    receive client chunks size = do
      ready <- waitReadable client micros
      chunk <- if ready then Just <$> recv client (min 65536 (maxFrame + 1 - size)) else pure Nothing
      case chunk of
        Nothing -> onTick >>= maybe (receive client chunks size) (pure . Left)
        Just bytes
          | B.null bytes -> throwExecution ConnectionError "Gondolin sidecar closed without a response"
          | otherwise -> do
              let size' = size + B.length bytes
                  chunks' = bytes : chunks
              when (size' > maxFrame) (throwExecution RuntimeError "Gondolin sidecar response is too large")
              if B.elem 10 bytes
                then Right <$> decodeResponse (BC.takeWhile (/= '\n') (B.concat (reverse chunks')))
                else receive client chunks' size'

-- | Wait for the control socket to become readable for at most @micros@,
-- in @poll@ on the calling thread like CPython's socket timeouts
-- ("Petrus.Posix.Poll"). 'False' means the tick elapsed.
waitReadable :: Socket -> Int -> IO Bool
waitReadable client micros = withFdSocket client $ \fd -> Poll.waitReadable (Fd fd) (Just (fromIntegral micros / 1000000))

-- | @json.loads(frame)@ of the response line (its @JSONDecodeError@ or
-- @UnicodeDecodeError@, both @ValueError@s, with CPython's text), which
-- must then answer @.get@.
decodeResponse :: ByteString -> IO Json
decodeResponse line = case loadsBytes line of
  Left failure -> throwExecution ValueError (pythonExceptionStr failure)
  Right value@(Object _) -> pure value
  Right other -> throwExecution (OtherError "AttributeError") ("'" <> jsonTypeName other <> "' object has no attribute 'get'")

-- | Raise @RuntimeError(response.get("error", fallback))@ unless @ok@: the
-- exception's text is @str()@ of the error value, whatever its type.
requireOk :: Text -> Json -> IO Json
requireOk fallback response
  | maybe False pythonTruthy (lookupMember "ok" response) = pure response
  | otherwise = throwExecution RuntimeError (maybe fallback pythonStr (lookupMember "error" response))

-- | @_request@: one authenticated control request (compact JSON).
sidecarRequest :: GondolinEnvironment -> Registry -> [(Text, Json)] -> Double -> IO Json
sidecarRequest env record request seconds = do
  case lookup "action" request of
    Just (String action) -> hookRequest (hooks env) action
    _ -> pure ()
  let full = Object (request <> [("lease_id", String (registryLeaseId record)), ("boot_token", String (registryBootToken record))])
      compact = defaultDumps {itemSeparator = Just ",", keySeparator = ":"}
  payload <- either (const (throwExecution ValueError "request is not encodable")) pure (dumps compact full)
  outcome <- exchange (T.unpack (registrySocket record)) seconds (payload <> "\n") (throwExecution TimeoutError "timed out" :: IO (Maybe Void))
  either absurd (requireOk "Gondolin sidecar request failed") outcome

control :: GondolinEnvironment -> Registry -> Text -> IO Json
control env record action = sidecarRequest env record [("action", String action)] 2

handshake :: GondolinEnvironment -> Registry -> IO ()
handshake env record = do
  response <- control env record "handshake"
  let versionOk = case lookupMember "version" response of
        Just (String v) -> v == gondolinVersion
        _ -> False
      leaseOk = case lookupMember "lease_id" response of
        Just (String l) -> l == registryLeaseId record
        _ -> False
      closing = maybe False pythonTruthy (lookupMember "closing" response)
  unless (versionOk && leaseOk && not closing) $
    throwExecution RuntimeError "Gondolin sidecar identity or SDK version mismatch"

leaseFor :: Registry -> LeaseState -> IO EnvironmentLease
leaseFor record state =
  either throwIO pure (mkEnvironmentLease (registryOperationId record) providerLabel (registryLeaseId record) capabilities state)
  where
    capabilities
      | registryPrivateFileTransfer record = gondolinCapabilities
      | otherwise = Set.delete capPrivateFileTransfer gondolinCapabilities

-- ---------------------------------------------------------------------------
-- Process identity

-- | One member of a process group as @ps@ reports it.
data GroupMember = GroupMember
  { memberPid :: Int
  , memberCommand :: Text
  }
  deriving stock (Eq, Show)

-- | How the provider observes and signals process groups (upstream's
-- module-level @_group_members@, @_identity@ and @os.killpg@, which its
-- tests monkeypatch).
data ProcessInspector = ProcessInspector
  { inspectGroupMembers :: Int -> IO [GroupMember]
  , inspectIdentity :: Int -> IO Identity
  , inspectKillGroup :: Int -> Signal -> IO Bool
  -- ^ 'False' when the group no longer exists (@ProcessLookupError@).
  }

systemInspector :: ProcessInspector
systemInspector = ProcessInspector groupMembers processIdentity killGroup
  where
    killGroup pgid signal =
      (True <$ signalProcessGroup signal (fromIntegral pgid)) `catch` \(e :: IOException) ->
        if isDoesNotExistError e then pure False else throwIO (osErrorFromIO e)

runPs :: [String] -> IO (ExitCode, Text)
runPs arguments = do
  (code, out, _) <- readCreateProcessWithExitCode (proc "ps" arguments) ""
  pure (code, T.pack out)

-- | @_ps_identity@: @ps -o lstart= -o command= -p PID@.
psIdentity :: Int -> IO Identity
psIdentity pid = do
  (code, out) <- runPs ["-o", "lstart=", "-o", "command=", "-p", show pid]
  let line = T.strip out
  pure $
    if code /= ExitSuccess || T.null line
      then missingIdentity
      else Identity "present" (Just (T.strip (T.take 24 line))) (Just (T.strip (T.drop 24 line)))

-- | @_identity@ on this host (@/proc@ when present, else @ps@).
processIdentity :: Int -> IO Identity
processIdentity = processIdentityWith (doesDirectoryExist "/proc") psIdentity

-- | @_identity@ with the @/proc@ probe and @ps@ fallback injected.
processIdentityWith :: IO Bool -> (Int -> IO Identity) -> Int -> IO Identity
processIdentityWith procAvailable viaPs pid = do
  hasProc <- procAvailable
  if not hasProc
    then fallback
    else do
      outcome <- try $ do
        fields <- BC.words <$> B.readFile ("/proc/" <> show pid <> "/stat")
        boot <- either (\(_ :: IOException) -> "") (T.strip . lenient) <$> try (B.readFile "/proc/sys/kernel/random/boot_id")
        command <- T.strip . lenient . BC.map (\c -> if c == '\0' then ' ' else c) <$> B.readFile ("/proc/" <> show pid <> "/cmdline")
        pure (fields, boot, command)
      case outcome of
        Left e
          | isDoesNotExistError e -> pure missingIdentity
          | otherwise -> fallback
        Right (fields, boot, command) -> case drop 21 fields of
          start : _ -> pure (Identity "present" (Just (boot <> ":" <> lenient start)) (Just command))
          [] -> fallback
  where
    lenient = TE.decodeUtf8With TE.lenientDecode
    fallback = viaPs pid `catch` \(_ :: IOException) -> pure (Identity "uninspectable" Nothing Nothing)

-- | @_group_members@: every process whose process group is @pgid@.
groupMembers :: Int -> IO [GroupMember]
groupMembers pgid = do
  (code, out) <- runPs ["-axo", "pid=,pgid=,command="]
  case code of
    ExitFailure n ->
      throwExecution
        (OtherError "CalledProcessError")
        ("Command '('ps', '-axo', 'pid=,pgid=,command=')' returned non-zero exit status " <> T.pack (show n) <> ".")
    ExitSuccess -> pure (concatMap member (T.lines out))
  where
    member line =
      let (first, rest) = T.break isSpace (T.strip line)
          (second, remainder) = T.break isSpace (T.stripStart rest)
       in case (decimal first, decimal second) of
            (Just pid, Just group) | group == pgid -> [GroupMember pid (T.strip remainder)]
            _ -> []
    decimal t
      | not (T.null t) && T.all isDigit t = Just (read (T.unpack t))
      | otherwise = Nothing

-- | @_group_identities@: the start markers of the group's live members,
-- which must include the unchanged leader.
groupIdentities :: ProcessInspector -> Registry -> IO (Map Text Text)
groupIdentities processes record = do
  members <- inspectGroupMembers processes (registryPgid record)
  pairs <- fmap catMaybes . forM members $ \member -> do
    identity <- inspectIdentity processes (memberPid member)
    case (identityState identity, identityMarker identity) of
      ("missing", _) -> pure Nothing
      ("present", Just marker) | not (T.null marker) -> pure (Just (T.pack (show (memberPid member)), marker))
      _ -> throwExecution RuntimeError "Gondolin process group identity could not be recorded"
  let identities = Map.fromList pairs
  when (Map.lookup (T.pack (show (registryPid record))) identities /= identityMarker (registryStartIdentity record)) $
    throwExecution RuntimeError "Gondolin sidecar identity changed during startup"
  pure identities

-- | @_cleanup_group@: signal the lease's process group only when every
-- member is attributable to it (live original leader, a recorded member
-- identity, or a command naming the private runtime); otherwise fail
-- closed without sending any signal.
cleanupGroup :: ProcessInspector -> Registry -> IO ()
cleanupGroup processes record = do
  members <- inspectGroupMembers processes pgid
  unless (null members) $ do
    leader <- inspectIdentity processes (registryPid record)
    let start = registryStartIdentity record
        leaderOwned =
          identityState leader == "present"
            && identityState start == "present"
            && identityMarker leader == identityMarker start
        recorded = fromMaybe Map.empty (registryGroupIdentities record)
    forM_ members $ \member -> do
      identity <- inspectIdentity processes (memberPid member)
      let recordedMember =
            identityState identity == "present"
              && Map.lookup (T.pack (show (memberPid member))) recorded == identityMarker identity
          attributed = registryRuntime record `T.isInfixOf` memberCommand member
      unless (leaderOwned || recordedMember || attributed) $
        throwExecution RuntimeError "Gondolin process group identity is uncertain; registry retained"
    escalate [(sigTERM, 0.5), (sigKILL, 0.2)]
  where
    pgid = registryPgid record
    escalate [] = pure ()
    escalate ((signal, delay) : rest) = do
      delivered <- inspectKillGroup processes pgid signal
      when delivered $ do
        deadline <- (+ delay) <$> getMonotonicTime
        let wait = do
              remaining <- inspectGroupMembers processes pgid
              now <- getMonotonicTime
              when (not (null remaining) && now < deadline) (threadDelay 20000 >> wait)
        wait
        remaining <- inspectGroupMembers processes pgid
        unless (null remaining) (escalate rest)

-- | @os.waitpid(pid, WNOHANG)@, ignoring @ChildProcessError@.
reap :: Int -> IO ()
reap pid = ignoring (getProcessStatus False False (fromIntegral pid))

-- | Wait up to @seconds@ for the group to empty, reaping the leader.
awaitEmptyGroup :: GondolinEnvironment -> Registry -> Double -> IO ()
awaitEmptyGroup env record seconds = do
  deadline <- (+ seconds) <$> getMonotonicTime
  let loop = do
        members <- inspectGroupMembers (inspector env) (registryPgid record)
        now <- getMonotonicTime
        when (not (null members) && now < deadline) $ do
          reap (registryPid record)
          sleepSeconds 0.03
          loop
  loop

hasMembers :: GondolinEnvironment -> Registry -> IO Bool
hasMembers env record = not . null <$> inspectGroupMembers (inspector env) (registryPgid record)

-- ---------------------------------------------------------------------------
-- Lifecycle

gondolinLookup :: GondolinEnvironment -> Text -> IO (Maybe EnvironmentLease)
gondolinLookup env operation = pythonic $ do
  checkOperation operation
  readRegistry (operationDirectory env operation) >>= \case
    Nothing -> pure Nothing
    Just record -> do
      reachable <- catching (\k -> osFamily k || k == RuntimeError) (handshake env record)
      Just <$> leaseFor record (either (const Uncertain) (const Ready) reachable)

-- | @secrets.token_urlsafe(32)@.
tokenUrlsafe :: IO Text
tokenUrlsafe = TE.decodeUtf8 . B64URL.encodeUnpadded <$> (getRandomBytes 32 :: IO ByteString)

-- | Python @str()@ of the TTL.
secondsText :: Seconds -> String
secondsText = \case
  WholeSeconds n -> show n
  FractionalSeconds d -> pythonFloatRepr d

waitWithin :: Child -> Double -> IO (Maybe Int)
waitWithin handle seconds = do
  deadline <- (+ seconds) <$> getMonotonicTime
  let loop = do
        code <- childExitCode handle
        now <- getMonotonicTime
        case code of
          Just done -> pure (Just done)
          Nothing
            | now >= deadline -> pure Nothing
            | otherwise -> threadDelay 10000 >> loop
  loop

create :: GondolinEnvironment -> Text -> EnvironmentSpec -> IO EnvironmentLease
create env operation spec = pythonic $ do
  checkOperation operation
  requireSupportedCapabilities gondolinCapabilities spec
  image <- maybe (throwExecution ValueError "Gondolin requires an image") pure (specImage spec)
  withOperationLock env operation $ \directory ->
    readRegistry directory >>= \case
      Just record -> do
        when (registrySpecFingerprint record /= specFingerprint spec) $
          throwExecution ValueError "operation id collides with a materially different environment spec"
        reachable <- attempt (handshake env record)
        case reachable of
          Left _ -> throwExecution RuntimeError "registered Gondolin lease is uncertain; destroy it before retrying"
          Right () -> pure ()
        lease <- leaseFor record Ready
        unless (specRequiredCapabilities spec `Set.isSubsetOf` leaseCapabilities lease) $
          throwExecution RuntimeError "registered Gondolin lease lacks required capabilities; destroy it before retrying"
        pure lease
      Nothing -> launch env operation spec image directory

launch :: GondolinEnvironment -> Text -> EnvironmentSpec -> Text -> FilePath -> IO EnvironmentLease
launch env operation spec image directory = do
  let config = environmentConfig env
      workspace = directory </> "workspace"
      private = capPrivateFileTransfer `Set.member` specRequiredCapabilities spec
  existing <- fileExist workspace
  when existing (throwExecution RuntimeError "unregistered Gondolin workspace has uncertain custody")
  createDirectory workspace 0o700
  runtime <-
    ( do
        runtime <- mkdtemp "/tmp/petrus-g-"
        setFileMode runtime 0o700
        pure runtime
    )
      `onException` removeDirectoryRecursive workspace
  hookRuntimeCreated (hooks env) runtime
  token <- tokenUrlsafe
  leaseIdent <- newUuid4
  let socketPath = runtime </> "s"
      stderrPath = runtime </> "stderr"
  handle <-
    spawnSidecar env runtime workspace socketPath stderrPath leaseIdent token image private
      `onException` do
        removeDirectoryRecursive runtime
        removeDirectoryRecursive workspace
        removeFile (directory </> "lock")
        removeDirectory directory
  let pid = fromIntegral (childPid handle)
  startIdentity <- inspectIdentity (inspector env) pid
  let record =
        Registry
          { registryOperationId = operation
          , registryLeaseId = leaseIdent
          , registrySpecFingerprint = specFingerprint spec
          , registryBootToken = token
          , registryPid = pid
          , registryPgid = pid
          , registryStartIdentity = startIdentity
          , registrySocket = T.pack socketPath
          , registryRuntime = T.pack runtime
          , registryWorkspace = T.pack workspace
          , registrySdkModule = gondolinSdkModule config
          , registrySdkVersion = gondolinVersion
          , registryImage = image
          , registryGroupIdentities = Nothing
          , registryPrivateFileTransfer = False
          }
  written <- try (writeRegistry env directory record)
  case written of
    Left (failure :: SomeException) -> do
      ignoring (signalChild handle sigTERM)
      exited <- waitWithin handle 1
      when (isNothing exited) $ do
        cleanupGroup (inspector env) record
        void (waitWithin handle 1)
      remaining <- hasMembers env record
      when remaining (throwExecution RuntimeError "Gondolin registry write failed and process cleanup is uncertain")
      removeRuntime record
      removeDirectoryRecursive directory
      throwIO failure
    Right () -> pure ()
  awaitStart env directory record handle stderrPath
  state <- newIORef record
  identified <- try $ do
    identities <- groupIdentities (inspector env) record
    let updated = record {registryGroupIdentities = Just identities}
    writeIORef state updated
    writeRegistry env directory updated
  case identified of
    Left (_ :: SomeException) -> do
      rolledBack <- rollbackLocked env directory =<< readIORef state
      throwExecution RuntimeError $
        if rolledBack
          then "Gondolin process identity registration failed"
          else "Gondolin process identity registration failed; rollback is unverified and registry custody is retained"
    Right () -> pure ()
  when private $ do
    probed <- try $ do
      _ <- sidecarRequest env record [("action", String "private_probe")] 60
      latest <- readIORef state
      more <- groupIdentities (inspector env) latest
      let updated =
            latest
              { registryGroupIdentities = Just (Map.union more (fromMaybe Map.empty (registryGroupIdentities latest)))
              , registryPrivateFileTransfer = True
              }
      writeIORef state updated
      writeRegistry env directory updated
    case probed of
      Left (_ :: SomeException) -> do
        rolledBack <- rollbackLocked env directory =<< readIORef state
        throwExecution RuntimeError $
          if rolledBack
            then "Gondolin private-file security probe failed"
            else "Gondolin private-file probe failed; rollback is unverified and registry custody is retained"
      Right () -> pure ()
  final <- readIORef state
  leaseFor final Ready

-- | Start the sidecar in its own session with a scrubbed environment;
-- stdin and stdout are @/dev/null@ and stderr goes to the private runtime.
spawnSidecar
  :: GondolinEnvironment -> FilePath -> FilePath -> FilePath -> FilePath -> Text -> Text -> Text -> Bool -> IO Child
spawnSidecar env runtime workspace socketPath stderrPath leaseIdent token image private = do
  let config = environmentConfig env
  host <- getEnvironment
  let inherited = [(key, value) | key <- ["GONDOLIN_IMAGE_STORE", "HOME", "PATH", "XDG_CACHE_HOME"], Just value <- [lookup key host]]
      environment =
        inherited
          <> [ ("TMPDIR", runtime)
             , ("GONDOLIN_SESSIONS_DIR", runtime </> "sessions")
             , ("PETRUS_GONDOLIN_BOOT_TOKEN", T.unpack token)
             , ("PETRUS_GONDOLIN_SDK", T.unpack (gondolinSdkModule config))
             ]
  bracket (openPrivateFd stderrPath) closeFd $ \errors -> do
    sidecar <- case gondolinSidecar config of
      Just path -> pure path
      Nothing -> do
        let path = runtime </> "sidecar.mjs"
        bracket (openPrivate path) hClose (`B.hPut` sidecarSource)
        pure path
    executable <- resolveExecutable [(T.pack k, T.pack v) | (k, v) <- environment] (T.pack (gondolinNode config))
    present <- fileExist executable
    unless present $ throwExecution OSError (T.pack (pythonErrnoMessage 2 (Just executable)))
    usable <- fileAccess executable False False True
    unless usable $ throwExecution OSError (T.pack (pythonErrnoMessage 13 (Just executable)))
    let devNull mode = openFd "/dev/null" mode defaultFileFlags {cloexec = True}
    bracket (devNull ReadOnly) closeFd $ \input ->
      bracket (devNull WriteOnly) closeFd $ \output ->
        spawnChild
          [ executable
          , sidecar
          , socketPath
          , T.unpack leaseIdent
          , workspace
          , T.unpack image
          , secondsText (gondolinLeaseTtl config)
          , if private then "private" else "standard"
          ]
          Nothing
          (Just environment)
          True
          (UseFd input, UseFd output, UseFd errors)
  where
    openPrivate :: FilePath -> IO Handle
    openPrivate path = openPrivateFd path >>= fdToHandle
    openPrivateFd :: FilePath -> IO Fd
    openPrivateFd path = do
      fd <- openFd path WriteOnly defaultFileFlags {creat = Just 0o600, trunc = True, cloexec = True}
      setFileMode path 0o600
      pure fd

-- | @_await_start@: poll the handshake until ready; on any failure stop
-- the group and remove the runtime and operation directory.
awaitStart :: GondolinEnvironment -> FilePath -> Registry -> Child -> FilePath -> IO ()
awaitStart env directory record handle stderrPath = do
  deadline <- (+ gondolinStartupTimeout (environmentConfig env)) <$> getMonotonicTime
  let loop = do
        now <- getMonotonicTime
        if now >= deadline
          then throwExecution RuntimeError "Gondolin sidecar readiness timed out"
          else do
            exited <- childExitCode handle
            case exited of
              Just _ -> do
                detail <- B.readFile stderrPath
                let tailBytes = B.drop (B.length detail - 1000) detail
                throwExecution RuntimeError ("Gondolin sidecar failed to start: " <> TE.decodeUtf8With TE.lenientDecode tailBytes)
              Nothing -> do
                ready <- catching osFamily (handshake env record)
                case ready of
                  Right () -> pure ()
                  Left _ -> sleepSeconds 0.03 >> loop
  loop `catch` \(failure :: SomeException) -> do
    cleanupGroup (inspector env) record
    void (waitWithin handle 1)
    remaining <- hasMembers env record
    when remaining (throwExecution RuntimeError "Gondolin startup failed and cleanup is uncertain; registry retained")
    removeRuntime record
    removeDirectoryRecursive directory
    throwIO failure

-- | @_rollback_locked@: remove a newly registered territory while the
-- operation lock is still held.
rollbackLocked :: GondolinEnvironment -> FilePath -> Registry -> IO Bool
rollbackLocked env directory record =
  either (const False) id <$> catching custodyFailure (do
    _ <- catching (\k -> osFamily k || k == RuntimeError) (control env record "close")
    awaitEmptyGroup env record 5
    remaining <- hasMembers env record
    when remaining (cleanupGroup (inspector env) record)
    stillRunning <- hasMembers env record
    if stillRunning
      then pure False
      else do
        removeRuntime record
        removeDirectoryRecursive directory
        runtimeLeft <- doesPathExist (T.unpack (registryRuntime record))
        directoryLeft <- doesPathExist directory
        membersLeft <- hasMembers env record
        pure (not runtimeLeft && not directoryLeft && not membersLeft))

-- | @_current@: the lease must still be the registered, reachable one.
currentRecord :: GondolinEnvironment -> EnvironmentLease -> IO Registry
currentRecord env lease = do
  found <- readRegistry (operationDirectory env (leaseOperationId lease))
  case found of
    Just record | leaseProvider lease == providerLabel -> do
      expected <- leaseFor record Ready
      unless (expected == lease) notCurrent
      handshake env record
      pure record
    _ -> notCurrent
  where
    notCurrent :: IO a
    notCurrent = throwExecution ValueError "lease is not a current Gondolin territory"

-- | Re-pack an archive through the codec so only normalized bytes cross.
normalizeArchive :: ByteString -> IO ByteString
normalizeArchive archive =
  withSystemTempDirectory "petrus-gondolin" $ \temporary -> do
    extractWorkspaceArchive archive temporary
    workspaceArchive temporary

attach :: GondolinEnvironment -> EnvironmentLease -> ByteString -> Text -> IO ExecutionAttachment
attach env lease archive digest = pythonic $ do
  record <- currentRecord env lease
  identifier <- newUuid4
  let transfer = T.unpack (registryWorkspace record)
  children <- listDirectory transfer
  forM_ children $ \name -> do
    let path = transfer </> name
    status <- getSymbolicLinkStatus path
    if isDirectory status then removeDirectoryRecursive path else removeFile path
  normalized <- normalizeArchive archive
  let input = transfer </> "input.tar"
  B.writeFile input normalized
  setFileMode input 0o600
  void (sidecarRequest env record [("action", String "attach"), ("attachment_id", String identifier)] 60)
    `finally` removeIfExists input
  either throwIO pure (mkExecutionAttachment identifier lease digest "/workspace")

provenanceOf :: ExecutionAttachment -> ExecutionProvenance
provenanceOf = leaseProvenance . attachmentLease

privateRecord :: GondolinEnvironment -> ExecutionAttachment -> IO Registry
privateRecord env attachment = do
  record <- currentRecord env (attachmentLease attachment)
  unless (capPrivateFileTransfer `Set.member` leaseCapabilities (attachmentLease attachment)) $
    throwExecution ValueError "lease does not grant private-file transfer"
  pure record

privateReference :: ExecutionAttachment -> PrivateFileRef -> IO ()
privateReference attachment reference =
  when (refAttachmentId reference /= attachmentId attachment || refProvenance reference /= provenanceOf attachment) $
    throwExecution ValueError "private file reference is not from this attachment"

unverifiedPrivateCleanup :: ExecutionAttachment -> IO PrivateFileCleanupResult
unverifiedPrivateCleanup attachment =
  either throwIO pure (mkPrivateFileCleanupResult (attachmentId attachment) (provenanceOf attachment) Unverified 0 "private cleanup unavailable" False)

privateCleanupResponse :: ExecutionAttachment -> Json -> IO PrivateFileCleanupResult
privateCleanupResponse attachment response =
  maybe (unverifiedPrivateCleanup attachment) pure $ do
    disposition <- case lookupMember "disposition" response of
      Just (String "clean") -> Just Clean
      Just (String "not-created") -> Just NotCreated
      Just (String "unverified") -> Just Unverified
      _ -> Nothing
    removed <- case lookupMember "removed" response of
      Nothing -> Just 0
      Just (Int n) -> Just (fromInteger n)
      _ -> Nothing
    detail <- case lookupMember "detail" response of
      Nothing -> Just ""
      Just (String t) -> Just t
      _ -> Nothing
    either (const Nothing) Just $
      mkPrivateFileCleanupResult (attachmentId attachment) (provenanceOf attachment) disposition removed detail False

importPrivate :: GondolinEnvironment -> ExecutionAttachment -> PrivateFile -> IO PrivateFileRef
importPrivate env attachment value = pythonic $ do
  record <- privateRecord env attachment
  fileId <- uuidHex
  _ <-
    sidecarRequest
      env
      record
      [ ("action", String "private_import")
      , ("attachment_id", String (attachmentId attachment))
      , ("file_id", String fileId)
      , ("name", String (privateFileName value))
      , ("content", String (TE.decodeUtf8 (B64.encode (privateFileContent value))))
      ]
      60
  either throwIO pure (mkPrivateFileRef fileId (privateFileName value) (attachmentId attachment) (provenanceOf attachment))

exportPrivate :: GondolinEnvironment -> ExecutionAttachment -> PrivateFileRef -> IO PrivateFile
exportPrivate env attachment reference = pythonic $ do
  privateReference attachment reference
  record <- privateRecord env attachment
  response <- sidecarRequest env record (referenceRequest "private_export" attachment reference) 60
  content <- case lookupMember "content" response of
    Just (String encoded) | Right bytes <- B64.decode (TE.encodeUtf8 encoded) -> pure bytes
    _ -> throwExecution RuntimeError "Gondolin private export returned invalid content"
  when (B.length content > maxPrivateFileBytes) $
    throwExecution RuntimeError "Gondolin private export violated its bound"
  either throwIO pure (mkPrivateFile (refName reference) content)

referenceRequest :: Text -> ExecutionAttachment -> PrivateFileRef -> [(Text, Json)]
referenceRequest action attachment reference =
  [ ("action", String action)
  , ("attachment_id", String (attachmentId attachment))
  , ("file_id", String (refFileId reference))
  , ("name", String (refName reference))
  ]

deletePrivate :: GondolinEnvironment -> ExecutionAttachment -> PrivateFileRef -> IO PrivateFileCleanupResult
deletePrivate env attachment reference = do
  outcome <- catching (\k -> osFamily k || k `elem` [RuntimeError, ValueError]) $ do
    privateReference attachment reference
    record <- privateRecord env attachment
    sidecarRequest env record (referenceRequest "private_delete" attachment reference) 60
  either (const (unverifiedPrivateCleanup attachment)) (privateCleanupResponse attachment) outcome

cleanupPrivate :: GondolinEnvironment -> ExecutionAttachment -> IO PrivateFileCleanupResult
cleanupPrivate env attachment = do
  outcome <- catching (\k -> osFamily k || k `elem` [KeyError, TypeError, ValueError, RuntimeError]) $ do
    record <- privateRecord env attachment
    sidecarRequest env record [("action", String "private_cleanup"), ("attachment_id", String (attachmentId attachment))] 60
  either (const (unverifiedPrivateCleanup attachment)) (privateCleanupResponse attachment) outcome

-- | Replace every occurrence of a non-empty needle.
replaceAll :: ByteString -> ByteString -> ByteString -> ByteString
replaceAll needle replacement haystack
  | B.null needle = haystack
  | otherwise = go haystack
  where
    go bytes =
      let (before, after) = B.breakSubstring needle bytes
       in if B.null after then before else before <> replacement <> go (B.drop (B.length needle) after)

execute :: GondolinEnvironment -> ExecutionAttachment -> Command -> IO CommandResult
execute env attachment command = pythonic $ do
  let lease = attachmentLease attachment
      provenance = leaseProvenance lease
      roots = commandPrivateRoots command
      superseded = do
        cancel env lease "superseded"
        either throwIO pure (mkCommandResult (-15) "" "" False True False provenance)
  when (not (null roots) && not (capPrivateFileTransfer `Set.member` leaseCapabilities lease)) $
    throwExecution ValueError "lease does not grant private-file transfer"
  record <- currentRecord env lease
  fresh <- fromMaybe (pure True) (commandIsCurrent command)
  if not fresh
    then superseded
    else do
      cwd <- checkedGuestCwd "/workspace" (commandCwd command)
      let timeoutJson = case commandTimeout command of
            Nothing -> Null
            Just (WholeSeconds n) -> Int n
            Just (FractionalSeconds d) -> Float d
          request =
            Object
              [ ("action", String "execute")
              , ("argv", Array (map String (commandArgv command)))
              , ("cwd", String cwd)
              , ("environment", Object [(k, String v) | (k, v) <- commandEnvironment command])
              , ("attachment_id", String (attachmentId attachment))
              , ("private_roots", Object [(name, Object [("file_id", String (refFileId r)), ("name", String (refName r))]) | (name, r) <- roots])
              , ("timeout", timeoutJson)
              , ("output_limit", Int (fromIntegral (commandOutputLimit command)))
              , ("lease_id", String (registryLeaseId record))
              , ("boot_token", String (registryBootToken record))
              ]
      mapM_ (privateReference attachment . snd) roots
      payload <- either (const (throwExecution ValueError "request is not encodable")) pure (dumps defaultDumps request)
      let onTick = case commandIsCurrent command of
            Nothing -> pure Nothing
            Just check -> do
              still <- check `onException` cancel env lease "currency check failed"
              if still then pure Nothing else Just <$> superseded
      outcome <- exchange (T.unpack (registrySocket record)) 0.05 (payload <> "\n") onTick
      case outcome of
        Left result -> pure result
        Right raw -> do
          response <- requireOk "Gondolin command failed" raw
          out <- decoded "stdout" response
          err <- decoded "stderr" response
          let redact bytes = foldl (\b (_, r) -> replaceAll ("/tmp/.petrus-private/" <> TE.encodeUtf8 (refFileId r)) "[private-root]" b) bytes roots
              stdout' = redact out
              stderr' = redact err
          when (B.length stdout' + B.length stderr' > commandOutputLimit command) $
            throwExecution RuntimeError "Gondolin sidecar violated the command output bound"
          code <- required "returncode" response >>= \case
            Int n -> pure (fromInteger n)
            _ -> throwExecution TypeError "Gondolin returncode must be an integer"
          timedOut <- pythonTruthy <$> required "timed_out" response
          truncated <- pythonTruthy <$> required "output_truncated" response
          either throwIO pure (mkCommandResult code stdout' stderr' timedOut False truncated provenance)
  where
    required key response =
      maybe (throwExecution KeyError (pythonStrRepr key)) pure (lookupMember key response)
    decoded key response =
      required key response >>= \case
        String encoded | Right bytes <- B64.decode (TE.encodeUtf8 encoded) -> pure bytes
        _ -> throwExecution ValueError "Gondolin returned invalid base64 output"

export :: GondolinEnvironment -> ExecutionAttachment -> IO ByteString
export env attachment = pythonic $ do
  record <- currentRecord env (attachmentLease attachment)
  let output = T.unpack (registryWorkspace record) </> "output.tar"
  removeIfExists output
  raw <-
    ( do
        _ <- sidecarRequest env record [("action", String "export")] 60
        status <- try (getSymbolicLinkStatus output)
        case status of
          Right s
            | isRegularFile s && fromIntegral (fileSize s) <= maxWorkspaceArchiveBytes -> B.readFile output
          Left (e :: IOException) | not (isDoesNotExistError e) -> throwIO e
          _ -> throwExecution RuntimeError "Gondolin returned an invalid workspace archive"
    )
      `finally` removeIfExists output
  normalizeArchive raw

cancel :: GondolinEnvironment -> EnvironmentLease -> Text -> IO ()
cancel env lease _reason = pythonic $ do
  found <- readRegistry (operationDirectory env (leaseOperationId lease))
  case found of
    Just record
      | leaseProvider lease == providerLabel && registryLeaseId record == leaseId lease ->
          void (control env record "close")
    _ -> pure ()

destroy :: GondolinEnvironment -> EnvironmentLease -> IO CleanupResult
destroy env lease
  | leaseProvider lease /= providerLabel = pure (result Unverified "lease belongs to a different provider")
  | otherwise = do
      outcome <- catching custodyFailure $ withOperationLock env (leaseOperationId lease) $ \directory ->
        readRegistry directory >>= \case
          Nothing -> do
            removed <- try (removeFile (directory </> "lock") >> removeDirectory directory)
            case removed of
              Left e | not (isDoesNotExistError e) -> throwIO e
              _ -> pure ()
            pure (result NotCreated "no registered Gondolin territory")
          Just record
            | registryLeaseId record /= leaseId lease ->
                pure (result Unverified "operation resolves to a different Gondolin lease")
            | otherwise -> do
                _ <- catching (\k -> osFamily k || k == RuntimeError) (control env record "close")
                awaitEmptyGroup env record 5
                running <- hasMembers env record
                when running (cleanupGroup (inspector env) record)
                stillRunning <- hasMembers env record
                if stillRunning
                  then pure (result Unverified "Gondolin process cleanup could not be verified; registry retained")
                  else do
                    removeRuntime record
                    removeDirectoryRecursive directory
                    pure (result Clean "")
      pure (either (const (result Unverified "Gondolin cleanup could not be independently verified")) id outcome)
  where
    result = CleanupResult (leaseIdentity lease)

reconcile :: GondolinEnvironment -> Text -> IO ReconcileResult
reconcile env operation =
  gondolinLookup env operation >>= \case
    Nothing -> pure (retryableResult "no Gondolin lease")
    Just lease
      | leaseState lease == Uncertain -> pure (uncertainResult (Just lease) "registered sidecar is unreachable")
      | otherwise -> pure (uncertainResult (Just lease) "VM readiness does not prove operation outcome")
