-- | Host-owned policy and authority boundaries for Petrus Pi native A2
-- Local (@hamsterdan.host.pi_a2@): the installation configuration and its
-- durable provider/model binding, the erasable one-shot API-key supplier,
-- the persistent AES-GCM connection keys, and the production composition.
--
-- Every file is the reference's, byte for byte: @pi-a2/installation@ is
-- @"{provider}\\n{model}\\n"@, each key is 32 raw bytes at
-- @pi-a2/keys/{sha256(connection)}.key@, and sealed state is
-- @\\x01 + nonce(12) + ciphertext + tag(16)@ with the Petrus authenticated
-- data, so either host opens the other's sealed connection state.
module Hamsterdan.Host.PiA2
  ( -- * Installation
    PiA2InstallationConfig (..)
  , mkPiA2InstallationConfig
  , installationFromEnvironment

    -- * Authority
  , newOneShotApiKeySupplier
  , persistentKeyOperations
  , persistentKeyOperationsWith
  , keyPath

    -- * Composition
  , OwnedPiA2 (..)
  , composeOwnedPiA2
  , composeOwnedPiA2With
  , connectionId
  , accountFingerprint
  , ownedCapabilities

    -- * Seams (the reference tests' monkeypatches)
  , PiA2Hooks (..)
  , defaultPiA2Hooks
  , bindInstallation
  , verifyInstallationBinding
  , privateDirectory
  , installationValue
  ) where

import Control.Concurrent.MVar
import Control.Exception (IOException, bracket, finally, onException, throwIO, try)
import Control.Monad (forM, unless, void, when)
import Crypto.Cipher.AES (AES256)
import Crypto.Cipher.Types (AEADMode (AEAD_GCM), AuthTag (..), aeadInit, aeadSimpleDecrypt, aeadSimpleEncrypt, cipherInit)
import Crypto.Error (CryptoFailable (..))
import Crypto.Hash.SHA256 qualified as SHA256
import Hamsterdan.Host.Random (urandom)
import Data.Bits ((.&.))
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.List (isPrefixOf)
import Data.Maybe (isJust)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Hamsterdan.Host.Agenticus (piModel, piProvider)
import Petrus.Agenticus.Connection.Custody (mkConnectionIdentity)
import Petrus.Agenticus.Connection.Key
  ( KeyContext (..)
  , KeyOperations (..)
  , ScrubbedBytes
  , authenticatedData
  , keyOperationError
  , mkKeyErasureEvidence
  )
import Petrus.Agenticus.Error (AgenticusError, throwLeft, valueError)
import Petrus.Agenticus.Hands.Contract (ToolMethod (..))
import Petrus.Agenticus.Runtime.Pi (piApiKeyCatalog)
import Petrus.Agenticus.Runtime.PiA2Host
  ( PiA2DirectAuthority
  , PiA2RuntimeHost
  , PiA2RuntimeHostConfig (..)
  , composePiA2Runtime
  , mkPiA2DirectAuthority
  , piA2RuntimeHostConfig
  )
import Petrus.Motus.Worker (RuntimeError (..), ValueError (..))
import Petrus.Posix.File (fsyncFd, makeDirectories, writeAll)
import System.Directory (canonicalizePath, listDirectory)
import System.FilePath ((</>))
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import GHC.Foreign qualified as GHC
import GHC.IO.Encoding (getFileSystemEncoding)
import System.Posix.ByteString.FilePath (RawFilePath)
import System.Posix.Files qualified as Posix
import System.Posix.Files.ByteString qualified as PosixB
import System.Posix.IO (OpenFileFlags (..), OpenMode (..), closeFd, defaultFileFlags, openFd)
import System.Posix.IO.ByteString (fdRead)
import System.Posix.IO.ByteString qualified as PosixIOB
import System.Posix.Types (Fd)
import System.Posix.User (getEffectiveUserID)

-- ---------------------------------------------------------------------------
-- Constants

keyVersion :: ByteString
keyVersion = "\x01"

keyBytes, nonceBytes, maxApiKeyBytes :: Int
keyBytes = 32
nonceBytes = 12
maxApiKeyBytes = 512

-- | @_CONNECTION_ID@ and @_ACCOUNT_FINGERPRINT@.
connectionId, accountFingerprint :: Text
connectionId = "hamsterdan-pi-a2-direct-v1"
accountFingerprint = "hamsterdan-direct-authority-v1"

-- | @_CAPABILITIES@.
ownedCapabilities :: Set ToolMethod
ownedCapabilities = Set.fromList [WorkspaceRead, WorkspaceSearch, WorkspaceWrite]

-- ---------------------------------------------------------------------------
-- Seams

-- | The process operations the reference tests replace with
-- @monkeypatch@: @os.fsync@, @os.link@, @pi_a2._sync_directory@ (as a
-- wrapper around the real one), and the runtime composition (which the
-- cross-language interop replaces with Petrus's scripted runtime).
data PiA2Hooks = PiA2Hooks
  { fsync :: Fd -> IO ()
  , link :: FilePath -> FilePath -> IO ()
  , syncDirectory :: (FilePath -> IO ()) -> FilePath -> IO ()
  , composeRuntime :: PiA2RuntimeHostConfig -> PiA2DirectAuthority -> IO PiA2RuntimeHost
  }

defaultPiA2Hooks :: PiA2Hooks
defaultPiA2Hooks =
  PiA2Hooks
    { fsync = fsyncFd
    , link = Posix.createLink
    , syncDirectory = id
    , composeRuntime = \config authority -> composePiA2Runtime config authority getMonotonicTime
    }

-- | @_sync_directory(path)@.
syncDirectoryWith :: PiA2Hooks -> FilePath -> IO ()
syncDirectoryWith hooks = hooks.syncDirectory real
  where
    real path = bracket (openFd path ReadOnly defaultFileFlags {directory = True}) closeFd hooks.fsync

-- ---------------------------------------------------------------------------
-- Installation configuration

-- | @PiA2InstallationConfig@: installation-owned runtime paths and redacted
-- direct authority.
data PiA2InstallationConfig = PiA2InstallationConfig
  { provider :: Text
  , model :: Text
  , directKey :: Text
  , cliPath :: FilePath
  , nodePath :: FilePath
  , packageRoot :: FilePath
  }
  deriving stock (Eq)

-- | @field(repr=False)@: the direct key never appears.
instance Show PiA2InstallationConfig where
  show c =
    "PiA2InstallationConfig(provider="
      <> show c.provider
      <> ", model="
      <> show c.model
      <> ", cli_path="
      <> show c.cliPath
      <> ", node_path="
      <> show c.nodePath
      <> ", package_root="
      <> show c.packageRoot
      <> ")"

-- | The dataclass constructor with its @__post_init__@ checks.
mkPiA2InstallationConfig :: Text -> Text -> Text -> FilePath -> FilePath -> FilePath -> Either Text PiA2InstallationConfig
mkPiA2InstallationConfig provider model directKey cliPath nodePath packageRoot
  | (provider, model) `notElem` piApiKeyCatalog = Left "Agenticus requires an exact qualified Pi provider/model pair"
  | T.length directKey < 16 || T.length directKey > maxApiKeyBytes || T.any (\c -> c < '\x21' || c > '\x7e') directKey =
      Left "Pi API-key material is malformed"
  | otherwise = Right PiA2InstallationConfig {provider, model, directKey, cliPath, nodePath, packageRoot}

-- | @str(Path(value))@: POSIX pure-path normalization.
purePosixPath :: Text -> FilePath
purePosixPath value =
  let leading
        | "//" `T.isPrefixOf` value && not ("///" `T.isPrefixOf` value) = "//"
        | "/" `T.isPrefixOf` value = "/"
        | otherwise = ""
      parts = [part | part <- T.splitOn "/" value, not (T.null part), part /= "."]
      joined = leading <> T.intercalate "/" parts
   in T.unpack (if T.null joined then "." else joined)

-- | @PiA2InstallationConfig.from_environment(environment, state_path=...)@.
installationFromEnvironment :: [(Text, Text)] -> Maybe FilePath -> IO PiA2InstallationConfig
installationFromEnvironment environment statePath = do
  let get name = lookup name environment
  when (isJust (get "HAMSTERDAN_PI_API_KEY_FILE")) $
    throwIO (ValueError "retired Pi credential-file configuration is present")
  let names =
        [ "HAMSTERDAN_PI_PROVIDER"
        , "HAMSTERDAN_PI_MODEL"
        , "HAMSTERDAN_PI_API_KEY"
        , "HAMSTERDAN_PI_CLI_PATH"
        , "HAMSTERDAN_PI_NODE_PATH"
        , "HAMSTERDAN_PI_PACKAGE_ROOT"
        ]
  values <- forM names $ \name -> case get name of
    Just value | not (T.null value) -> pure value
    _ -> throwIO (ValueError "Agenticus requires explicit direct-key and Pi runtime paths")
  config <- case values of
    [provider, model, key, cli, node, package] ->
      either (throwIO . ValueError) pure $
        mkPiA2InstallationConfig provider model key (purePosixPath cli) (purePosixPath node) (purePosixPath package)
    _ -> throwIO (ValueError "Agenticus requires explicit direct-key and Pi runtime paths")
  when (any (not . ("/" `isPrefixOf`)) [config.cliPath, config.nodePath, config.packageRoot]) $
    throwIO (ValueError "Agenticus installation paths must be absolute")
  mapM_ (\state -> verifyInstallationBinding (state </> "pi-a2") config.provider config.model) statePath
  pure config

-- ---------------------------------------------------------------------------
-- Authority

-- | @OneShotApiKeySupplier(loader)@: transfer one erasable direct-key buffer
-- at most once.
newOneShotApiKeySupplier :: IO ScrubbedBytes -> IO (IO ScrubbedBytes)
newOneShotApiKeySupplier loader = do
  spent <- newMVar False
  pure $ do
    already <- modifyMVar spent (\value -> pure (True, value))
    when already $ throwIO (RuntimeError "Pi A2 authority supplier is already spent")
    value <- loader
    when (BA.null value) $ throwIO (RuntimeError "Pi A2 authority supplier returned invalid material")
    pure value

-- | @PersistentKeyOperations(root)@.
persistentKeyOperations :: FilePath -> IO KeyOperations
persistentKeyOperations = persistentKeyOperationsWith defaultPiA2Hooks

-- | The key file for one connection: @{root}/{sha256(connection)}.key@.
keyPath :: FilePath -> Text -> IO FilePath
keyPath root connection
  | T.null connection = throwIO (valueError "connection identity must not be empty")
  | otherwise = pure (root </> T.unpack (TE.decodeLatin1 (B16.encode (SHA256.hash (TE.encodeUtf8 connection)))) <> ".key")

-- | The file system's spelling of a path (@os.fsencode@).
rawPath :: FilePath -> IO RawFilePath
rawPath path = do
  encoding <- getFileSystemEncoding
  GHC.withCStringLen encoding path BS.packCStringLen

persistentKeyOperationsWith :: PiA2Hooks -> FilePath -> IO KeyOperations
persistentKeyOperationsWith hooks selected = do
  root <- privateDirectory selected
  -- Every load stats and opens the key file by its encoded path: encode
  -- the root once, the hexadecimal file name is ASCII.
  rawRoot <- (<> "/") <$> rawPath root
  lock <- newMVar ()
  let locked :: IO a -> IO a
      locked action = withMVar lock (const action)
      unavailable = keyOperationError "opaque connection key is unavailable"
      load connection = do
        when (T.null connection) $ throwIO (valueError "connection identity must not be empty")
        let path = rawRoot <> B16.encode (SHA256.hash (TE.encodeUtf8 connection)) <> ".key"
        outcome <- try @IOException $ do
          metadata <- PosixB.getSymbolicLinkStatus path
          euid <- getEffectiveUserID
          when
            ( Posix.isSymbolicLink metadata
                || not (Posix.isRegularFile metadata)
                || Posix.fileMode metadata .&. 0o7777 /= 0o600
                || Posix.fileOwner metadata /= euid
                || Posix.fileSize metadata /= fromIntegral keyBytes
            )
            $ throwIO unavailable
          bracket (PosixIOB.openFd path ReadOnly defaultFileFlags {nofollow = True}) closeFd $ \fd -> do
            current <- Posix.getFdStatus fd
            when ((Posix.deviceID current, Posix.fileID current) /= (Posix.deviceID metadata, Posix.fileID metadata)) $
              throwIO (keyOperationError "opaque connection key changed while opening")
            fdRead fd (fromIntegral keyBytes + 1)
        key <- either (const (throwIO unavailable)) pure outcome
        when (BS.length key /= keyBytes) $ throwIO unavailable
        pure key
      loadOrCreate connection = do
        existing <- try (load connection)
        case existing of
          Right key -> pure key
          Left (_ :: AgenticusError) -> do
            path <- keyPath root connection
            key <- urandom keyBytes
            created <- try (openFd path WriteOnly defaultFileFlags {creat = Just 0o600, exclusive = True})
            case created of
              Left e
                | isAlreadyExistsError e -> load connection
                | otherwise -> throwIO e
              Right fd -> do
                ( (writeAll fd key >> hooks.fsync fd) `finally` closeFd fd
                  )
                  `onException` ( do
                                    void (try @IOException (Posix.removeLink path))
                                    syncDirectoryWith hooks root
                                )
                syncDirectoryWith hooks root
                load connection
  pure
    KeyOperations
      { seal = \context plaintext -> locked $ do
          key <- loadOrCreate context.connectionId
          nonce <- urandom nonceBytes
          case aesGcmSeal key nonce (authenticatedData context) plaintext of
            Just sealed -> pure (keyVersion <> nonce <> sealed)
            Nothing -> throwIO (keyOperationError "opaque connection state could not be sealed")
      , open = \context ciphertext -> do
          when (BS.length ciphertext <= 1 + nonceBytes || not (keyVersion `BS.isPrefixOf` ciphertext)) $
            throwIO (keyOperationError "opaque connection state is malformed")
          locked $ do
            key <- load context.connectionId
            let nonce = BS.take nonceBytes (BS.drop 1 ciphertext)
                body = BS.drop (1 + nonceBytes) ciphertext
            case aesGcmOpen key nonce (authenticatedData context) body of
              Just plaintext -> pure plaintext
              Nothing -> throwIO (keyOperationError "opaque connection state failed authentication")
      , erase = \connection -> do
          path <- keyPath root connection
          locked $ do
            outcome <- try @IOException $ do
              Posix.removeLink path
              bracket (openFd root ReadOnly defaultFileFlags {directory = True}) closeFd hooks.fsync
            case outcome of
              Left e
                | isDoesNotExistError e -> pure ()
                | otherwise -> throwIO (keyOperationError "opaque connection key could not be erased")
              Right () -> pure ()
          throwLeft (mkKeyErasureEvidence connection True)
      }

-- | @AESGCM(key).encrypt(nonce, plaintext, aad)@: ciphertext then tag.
aesGcmSeal :: ByteString -> ByteString -> ByteString -> ScrubbedBytes -> Maybe ByteString
aesGcmSeal key nonce aad plaintext = case cipherInit key >>= \cipher -> aeadInit AEAD_GCM (cipher :: AES256) nonce of
  CryptoFailed _ -> Nothing
  CryptoPassed aead ->
    let (AuthTag tag, ciphertext) = aeadSimpleEncrypt aead aad (BA.convert plaintext :: ByteString) 16
     in Just (ciphertext <> BA.convert tag)

-- | @AESGCM(key).decrypt(nonce, data, aad)@; 'Nothing' is @InvalidTag@.
aesGcmOpen :: ByteString -> ByteString -> ByteString -> ByteString -> Maybe ScrubbedBytes
aesGcmOpen key nonce aad sealed
  | BS.length sealed < 16 = Nothing
  | otherwise = case cipherInit key >>= \cipher -> aeadInit AEAD_GCM (cipher :: AES256) nonce of
      CryptoFailed _ -> Nothing
      CryptoPassed aead ->
        let (body, tag) = BS.splitAt (BS.length sealed - 16) sealed
         in aeadSimpleDecrypt aead aad (BA.convert body :: ScrubbedBytes) (AuthTag (BA.convert tag))

-- ---------------------------------------------------------------------------
-- Composition

-- | The composed host and the authority it was given (the reference's
-- @host.authority@).
data OwnedPiA2 = OwnedPiA2
  { host :: PiA2RuntimeHost
  , authority :: PiA2DirectAuthority
  }

-- | @compose_owned_pi_a2(state_path, installation)@: compose the
-- production A2 boundary without consulting ambient authority.
composeOwnedPiA2 :: FilePath -> Maybe PiA2InstallationConfig -> IO PiA2RuntimeHost
composeOwnedPiA2 statePath installation = (.host) <$> composeOwnedPiA2With defaultPiA2Hooks statePath installation

composeOwnedPiA2With :: PiA2Hooks -> FilePath -> Maybe PiA2InstallationConfig -> IO OwnedPiA2
composeOwnedPiA2With hooks statePath installation = do
  root <- privateDirectory (statePath </> "pi-a2")
  let provider = maybe piProvider (.provider) installation
      model = maybe piModel (.model) installation
  bindInstallationWith hooks root provider model
  workspace <- privateDirectory (root </> "workspace")
  identity <- throwLeft (mkConnectionIdentity connectionId provider accountFingerprint "api-key")
  keys <- persistentKeyOperationsWith hooks (root </> "keys")
  supplier <-
    newOneShotApiKeySupplier $ case installation of
      Nothing -> throwIO (RuntimeError "Pi A2 direct authority is not enabled")
      -- @bytearray(installation.direct_key, "ascii")@: a fresh buffer.
      Just selected -> BA.copy (BA.convert (TE.encodeUtf8 selected.directKey) :: ScrubbedBytes) (\_ -> pure ())
  authority <- throwLeft (mkPiA2DirectAuthority identity keys supplier)
  let config =
        (piA2RuntimeHostConfig (root </> "runtime-host") workspace provider model "hamsterdan-pi-a2" ownedCapabilities)
          { maxToolCalls = 32
          , cliPath = T.pack . (.cliPath) <$> installation
          , nodePath = T.pack . (.nodePath) <$> installation
          , packageRoot = T.pack . (.packageRoot) <$> installation
          }
  host <- hooks.composeRuntime config authority
  pure OwnedPiA2 {host, authority}

-- | @_private_directory(path)@.
privateDirectory :: FilePath -> IO FilePath
privateDirectory selected = do
  linked <- isSymlink selected
  when linked $ throwIO (ValueError "Pi A2 host directory must not be a symlink")
  makeDirectories selected 0o700
  Posix.setFileMode selected 0o700
  metadata <- Posix.getSymbolicLinkStatus selected
  euid <- getEffectiveUserID
  unless
    ( Posix.isDirectory metadata
        && Posix.fileMode metadata .&. 0o7777 == 0o700
        && Posix.fileOwner metadata == euid
    )
    $ throwIO (ValueError "Pi A2 host directory must be owned and private")
  canonicalizePath selected

isSymlink :: FilePath -> IO Bool
isSymlink path = either (const False) Posix.isSymbolicLink <$> try @IOException (Posix.getSymbolicLinkStatus path)

-- | @_installation_value(provider, model)@.
installationValue :: Text -> Text -> ByteString
installationValue provider model = TE.encodeUtf8 (provider <> "\n" <> model <> "\n")

-- | @_read_installation_binding(path)@: 'Nothing' is the reference's
-- @FileNotFoundError@.
readInstallationBinding :: FilePath -> IO (Maybe ByteString)
readInstallationBinding path = do
  outcome <- try @IOException $ do
    metadata <- Posix.getSymbolicLinkStatus path
    euid <- getEffectiveUserID
    when
      ( Posix.isSymbolicLink metadata
          || not (Posix.isRegularFile metadata)
          || Posix.fileMode metadata .&. 0o7777 /= 0o600
          || Posix.fileOwner metadata /= euid
          || not (Posix.fileSize metadata > 0 && Posix.fileSize metadata <= 256)
      )
      $ throwIO (ValueError "Pi A2 installation binding is unsafe")
    (opened, value, current) <-
      bracket (openFd path ReadOnly defaultFileFlags {nofollow = True}) closeFd $ \fd -> do
        opened <- Posix.getFdStatus fd
        value <- fdRead fd 257
        current <- Posix.getFdStatus fd
        pure (opened, value, current)
    pure (metadata, opened, value, current)
  case outcome of
    Left e
      | isDoesNotExistError e -> pure Nothing
      | otherwise -> throwIO (ValueError "Pi A2 installation binding cannot be inspected safely")
    Right (metadata, opened, value, current) -> do
      let facts status = (Posix.deviceID status, Posix.fileID status, Posix.fileSize status, Posix.modificationTimeHiRes status)
      when (facts opened /= facts metadata || facts current /= facts opened || fromIntegral (BS.length value) /= Posix.fileSize metadata) $
        throwIO (ValueError "Pi A2 installation binding changed during inspection")
      pure (Just value)

-- | @_verify_installation_binding(root, provider, model)@.
verifyInstallationBinding :: FilePath -> Text -> Text -> IO ()
verifyInstallationBinding root provider model = do
  linked <- isSymlink root
  when linked $ throwIO (ValueError "Pi A2 host directory must not be a symlink")
  status <- try @IOException (Posix.getFileStatus root)
  case status of
    Left _ -> pure ()
    Right _ -> do
      metadata <- Posix.getSymbolicLinkStatus root
      euid <- getEffectiveUserID
      unless
        ( Posix.isDirectory metadata
            && Posix.fileMode metadata .&. 0o7777 == 0o700
            && Posix.fileOwner metadata == euid
        )
        $ throwIO (ValueError "Pi A2 host directory must be owned and private")
      let expected = installationValue provider model
          different = ValueError "existing Pi A2 state is bound to a different provider/model"
      actual <- readInstallationBinding (root </> "installation")
      case actual of
        Nothing -> do
          entries <- listDirectory root
          let retained = filter (not . (".installation-" `isPrefixOf`)) entries
          when (not (null retained) && expected /= installationValue piProvider piModel) $ throwIO different
        Just value -> when (value /= expected) $ throwIO different

-- | @_bind_installation(root, provider, model)@.
bindInstallation :: FilePath -> Text -> Text -> IO ()
bindInstallation = bindInstallationWith defaultPiA2Hooks

bindInstallationWith :: PiA2Hooks -> FilePath -> Text -> Text -> IO ()
bindInstallationWith hooks root provider model = do
  verifyInstallationBinding root provider model
  let binding = root </> "installation"
      value = installationValue provider model
  actual <- readInstallationBinding binding
  case actual of
    Just existing ->
      when (existing /= value) $ throwIO (ValueError "existing Pi A2 state is bound to a different provider/model")
    Nothing -> do
      (temporary, fd) <- makeTemporary root
      ( do
          ( do
              Posix.setFdMode fd 0o600
              writeAll fd value
              hooks.fsync fd
            )
            `finally` closeFd fd
          linked <- try (hooks.link temporary binding)
          case linked of
            Left e
              | isAlreadyExistsError e -> verifyInstallationBinding root provider model
              | otherwise -> throwIO e
            Right () -> syncDirectoryWith hooks root
        )
        `finally` void (try @IOException (Posix.removeLink temporary))

-- | @tempfile.mkstemp(prefix=".installation-", dir=root)@.
makeTemporary :: FilePath -> IO (FilePath, Fd)
makeTemporary root = go (100 :: Int)
  where
    alphabet = "abcdefghijklmnopqrstuvwxyz0123456789_" :: String
    go attempts = do
      random <- urandom 8
      let name = ".installation-" <> [alphabet !! (fromIntegral byte `mod` length alphabet) | byte <- BS.unpack random]
          path = root </> name
      created <- try (openFd path ReadWrite defaultFileFlags {creat = Just 0o600, exclusive = True, nofollow = True, cloexec = True})
      case created of
        Right fd -> pure (path, fd)
        Left e
          | isAlreadyExistsError e && attempts > 1 -> go (attempts - 1)
          | otherwise -> throwIO e

