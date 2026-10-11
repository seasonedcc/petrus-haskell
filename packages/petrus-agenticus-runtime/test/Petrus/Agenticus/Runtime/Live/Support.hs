-- | What the live-provider acceptance tests (the reference's @*_real.py@)
-- share: their opt-in gates, the private handoff of an approved credential
-- into Agent Connection custody, live erasable keys, and the in-memory
-- Continuation and Turn stores.
--
-- Each test runs only when its variable is exactly @1@, as the reference's
-- @skipif@ does; otherwise it is pending and names the variable to set.
-- Once a test runs, every missing prerequisite fails it. Where the
-- reference calls @pytest.skip@ inside a running test (a missing CLI,
-- credential or handoff), the port fails, so an opted-in run never passes
-- without reaching the provider. docs/live-provider-acceptance.md says how
-- to run them.
module Petrus.Agenticus.Runtime.Live.Support
  ( -- * Gates and failures
    live
  , failWith
  , check
  , required
  , withCleanup
  , tryAny
    -- * Credential handoff
  , FileIdentity
  , HandoffMessages (..)
  , readHandoff
  , consumeHandoff
  , readNoFollow
  , fileIdentity
    -- * Custody
  , liveKeys
  , perConnectionKeys
  , LiveCustody (..)
  , openLiveCustody
  , authorizeLive
  , finishConnection
  , leasesReleased
    -- * Stores
  , Store
  , newStore
  , remember
  , stored
  , storedCount
    -- * Values
  , ok
  , marker
  , sha256Text
  , hostFencedEffect
  , settleVerified
  , settledAfter
  , isEmptyDirectory
  , ordered
  ) where

import Control.Exception (SomeException, displayException, finally, throwIO, try)
import Control.Monad (unless, when)
import Crypto.Cipher.AES (AES256)
import Crypto.Cipher.Types (AEADMode (..), AuthTag (..), aeadInit, aeadSimpleDecrypt, aeadSimpleEncrypt, cipherInit)
import Crypto.Error (throwCryptoErrorIO)
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random (getRandomBytes)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.Char (toUpper)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock.POSIX (POSIXTime)
import GHC.Clock (getMonotonicTime)
import Petrus.Agenticus.Attachment.Binding (BindingSettlement (..))
import Petrus.Agenticus.Attachment.Episode (AttachmentSettlement (..), EpisodeAttachment)
import Petrus.Agenticus.Attachment.Episode qualified as Episode
import Petrus.Agenticus.Catalog.Descriptor (CapabilityDescriptor, DescriptorKind (..), capabilityDescriptor, descriptorIdentity)
import Petrus.Agenticus.Connection.Custody
  ( AgentConnectionCustody
  , ConnectionIdentity
  , ConnectionStatus (..)
  , ConnectionView (..)
  , agentConnectionCustody
  , authorize
  , enrollHost
  , erase
  , lookupConnection
  , newOpaqueState
  , opaqueStateErased
  , revoke
  )
import Petrus.Agenticus.Connection.Key (KeyContext (..), KeyOperations (..), authenticatedData, mkKeyErasureEvidence)
import Petrus.Agenticus.Connection.Materialization (materializerRoot, newPrivateFileMaterializer)
import Petrus.Agenticus.Connection.Storage (ConnectionStorage (..), StorageSnapshot (..), StoredLease (..), openSqliteConnectionStorage)
import Petrus.Agenticus.Error
import System.Directory (listDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO (hClose, hPutStrLn, stderr)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileID
  , fileMode
  , fileOwner
  , fileSize
  , getFdStatus
  , getSymbolicLinkStatus
  , intersectFileModes
  , isRegularFile
  , linkCount
  , modificationTimeHiRes
  , removeLink
  )
import System.Posix.IO (OpenFileFlags (..), OpenMode (..), defaultFileFlags, fdToHandle, openFd)
import System.Posix.Types (DeviceID, FileID, FileMode, FileOffset, LinkCount, UserID)
import System.Posix.User (getRealUserID)
import Test.Hspec

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

-- ---------------------------------------------------------------------------
-- Gates and failures

-- | One reference test behind its opt-in variable: it runs when the
-- variable is exactly @1@ and is pending otherwise.
live :: String -> String -> String -> IO () -> Spec
live name variable cell body =
  it name $
    lookupEnv variable >>= \case
      Just "1" -> body
      _ -> pendingWith ("skipped: set " <> variable <> "=1 for " <> cell <> "; see docs/live-provider-acceptance.md")

-- | @pytest.fail(message)@; also what @pytest.skip(message)@ inside an
-- opted-in test becomes.
failWith :: String -> IO a
failWith message = expectationFailure message >> throwIO (userError message)

-- | @if not condition: pytest.fail(message)@.
check :: Bool -> String -> IO ()
check condition message = unless condition (failWith message)

-- | A variable the opted-in test needs; an absent or empty value fails it.
required :: String -> String -> IO String
required name message =
  lookupEnv name >>= \case
    Just value | not (null value) -> pure value
    _ -> failWith message

-- | The body, then the reference's finalizer. A failing body keeps its own
-- failure; a finalizer failing after it is reported on stderr, as pytest
-- reports a teardown error next to the test's failure.
withCleanup :: IO a -> IO () -> IO a
withCleanup body cleanup = do
  result <- try body
  cleaned <- try cleanup
  case (result, cleaned) of
    (Right value, Right ()) -> pure value
    (Right _, Left (e :: SomeException)) -> throwIO e
    (Left (e :: SomeException), Right ()) -> throwIO e
    (Left e, Left c) -> do
      hPutStrLn stderr ("the live test's cleanup also failed: " <> displayException c)
      throwIO e

-- | @try@ over every exception, for the reference's @try: ... finally:@ and
-- @except Exception@.
tryAny :: IO a -> IO (Either SomeException a)
tryAny = try

-- ---------------------------------------------------------------------------
-- Credential handoff

-- | @(st_dev, st_ino, st_mode, st_uid, st_nlink, st_size, st_mtime_ns)@.
type FileIdentity = (DeviceID, FileID, FileMode, UserID, LinkCount, FileOffset, POSIXTime)

fileIdentity :: FileStatus -> FileIdentity
fileIdentity s = (deviceID s, fileID s, fileMode s, fileOwner s, linkCount s, fileSize s, modificationTimeHiRes s)

-- | The messages one reference file's handoff readers fail with.
data HandoffMessages = HandoffMessages
  { missing :: String
  -- ^ The handoff does not exist (the reference skips in some files).
  , inspect :: String
  , custodyInvariant :: String
  , open :: String
  , read :: String
  , changedDuringTransfer :: String
  , notAuthority :: String
  , changedBeforeCustody :: String
  , notConsumed :: String
  , consume :: String
  }

-- | @os.open(path, O_RDONLY | O_NOFOLLOW)@, @fstat@, @os.read(fd, limit)@
-- and @fstat@ again.
readNoFollow :: FilePath -> Int -> IO (FileStatus, ByteString, FileStatus)
readNoFollow path limit = do
  fd <- openFd path ReadOnly defaultFileFlags {nofollow = True}
  handle <- fdToHandle fd
  ( do
      first <- getFdStatus fd
      value <- B.hGetSome handle limit
      second <- getFdStatus fd
      pure (first, value, second)
    )
    `finally` hClose handle

-- | @_read_handoff@ / @_opaque_file_auth@: one private regular file of the
-- current user, read without following links, unchanged while it was read,
-- non-empty and at most @maximum'@ bytes. With @apiKeyText@ it must also be
-- strict UTF-8 starting with @prefix@, without surrounding whitespace or
-- control characters.
readHandoff :: HandoffMessages -> FilePath -> Int -> Bool -> Text -> IO (ByteString, FileIdentity)
readHandoff messages source maximum' apiKeyText prefix = do
  metadata <-
    try (getSymbolicLinkStatus source) >>= \case
      Right m -> pure m
      Left e
        | isDoesNotExistError e -> failWith messages.missing
        | otherwise -> failWith messages.inspect
  uid <- getRealUserID
  check
    ( isRegularFile metadata
        && fileMode metadata `intersectFileModes` 0o7777 == 0o600
        && fileOwner metadata == uid
        && linkCount metadata == 1
    )
    messages.custodyInvariant
  (first, value, second) <-
    try (readNoFollow source (maximum' + 1)) >>= \case
      Right r -> pure r
      Left (_ :: IOError) -> failWith messages.read
  let identity = fileIdentity first
  check (identity == fileIdentity second && not (B.null value) && B.length value <= maximum') messages.changedDuringTransfer
  when apiKeyText $ case TE.decodeUtf8' value of
    Right text ->
      check (prefix `T.isPrefixOf` text && text == T.strip text && T.all (>= ' ') text) messages.notAuthority
    Left _ -> failWith messages.notAuthority
  pure (value, identity)

-- | @_consume_handoff@: the handoff is unchanged since it was read; it is
-- unlinked and must be gone.
consumeHandoff :: HandoffMessages -> FilePath -> FileIdentity -> IO ()
consumeHandoff messages source expected =
  try go >>= \case
    Right () -> pure ()
    Left (_ :: IOError) -> failWith messages.consume
  where
    go = do
      current <- getSymbolicLinkStatus source
      check (fileIdentity current == expected) messages.changedBeforeCustody
      removeLink source
      try (getSymbolicLinkStatus source) >>= \case
        Left (_ :: IOError) -> pure ()
        Right _ -> failWith messages.notConsumed

-- ---------------------------------------------------------------------------
-- Custody

-- | AES-GCM nonce, ciphertext and tag, as @AESGCM.encrypt@ lays them out.
sealWith :: ByteString -> Integer -> KeyContext -> ByteString -> IO ByteString
sealWith key n sealing plaintext = do
  cipher :: AES256 <- throwCryptoErrorIO (cipherInit key)
  let iv = B.pack [fromIntegral (n `div` (256 ^ i) `mod` 256) | i <- [11, 10 .. 0 :: Int]]
  aead <- throwCryptoErrorIO (aeadInit AEAD_GCM cipher iv)
  let (AuthTag tag, ciphertext) = aeadSimpleEncrypt aead (authenticatedData sealing) plaintext 16
  pure (iv <> ciphertext <> BA.convert tag)

openWith :: ByteString -> KeyContext -> ByteString -> IO ByteString
openWith key sealing sealed = do
  cipher :: AES256 <- throwCryptoErrorIO (cipherInit key)
  let (iv, rest) = B.splitAt 12 sealed
      (ciphertext, tag) = B.splitAt (B.length rest - 16) rest
  aead <- throwCryptoErrorIO (aeadInit AEAD_GCM cipher iv)
  case aeadSimpleDecrypt aead (authenticatedData sealing) ciphertext (AuthTag (BA.convert tag)) of
    Just plaintext -> pure plaintext
    Nothing -> throwAgenticus (OtherError "InvalidTag") ""

-- | The reference's @_Keys@: one random 32-byte AES-GCM key, a counting
-- nonce, and an erased set that refuses @open@ until the next @seal@.
liveKeys :: Text -> IO KeyOperations
liveKeys unavailable = do
  key <- getRandomBytes 32
  nonce <- newIORef (0 :: Integer)
  erased <- newIORef (Set.empty :: Set Text)
  pure
    KeyOperations
      { seal = \sealing plaintext -> do
          modifyIORef' erased (Set.delete sealing.connectionId)
          n <- atomicModifyIORef' nonce (\x -> (x + 1, x + 1))
          sealWith key n sealing (BA.convert plaintext)
      , open = \sealing sealed -> do
          gone <- Set.member sealing.connectionId <$> readIORef erased
          when gone (throwAgenticus RuntimeError unavailable)
          BA.convert <$> openWith key sealing sealed
      , erase = \connectionId -> do
          modifyIORef' erased (Set.insert connectionId)
          either throwIO pure (mkKeyErasureEvidence connectionId True)
      }

-- | The Agent-as-a-Net file's @_Keys@: one random key per connection,
-- dropped by @erase@; the action counts the keys still retained.
perConnectionKeys :: IO (KeyOperations, IO Int)
perConnectionKeys = do
  keys <- newIORef (Map.empty :: Map Text ByteString)
  nonce <- newIORef (0 :: Integer)
  let keyFor connectionId =
        Map.lookup connectionId <$> readIORef keys >>= \case
          Just key -> pure key
          Nothing -> do
            key <- getRandomBytes 32
            modifyIORef' keys (Map.insert connectionId key)
            pure key
  pure
    ( KeyOperations
        { seal = \sealing plaintext -> do
            key <- keyFor sealing.connectionId
            n <- atomicModifyIORef' nonce (\x -> (x + 1, x + 1))
            sealWith key n sealing (BA.convert plaintext)
        , open = \sealing sealed ->
            Map.lookup sealing.connectionId <$> readIORef keys >>= \case
              Nothing -> throwAgenticus RuntimeError "Agent-as-a-Net connection key is unavailable"
              Just key -> BA.convert <$> openWith key sealing sealed
        , erase = \connectionId -> do
            modifyIORef' keys (Map.delete connectionId)
            either throwIO pure (mkKeyErasureEvidence connectionId True)
        }
    , Map.size <$> readIORef keys
    )

-- | Production custody over @root/installation@: a SQLite ledger and a
-- private-file materializer, on the monotonic clock.
data LiveCustody = LiveCustody
  { custody :: AgentConnectionCustody
  , storage :: ConnectionStorage
  , materialized :: FilePath
  }

openLiveCustody :: FilePath -> KeyOperations -> IO LiveCustody
openLiveCustody root keys = do
  storage <- openSqliteConnectionStorage (root </> "installation" </> "connections.sqlite3")
  materializer <- newPrivateFileMaterializer (root </> "installation" </> "materialized")
  pure LiveCustody {custody = agentConnectionCustody storage keys materializer getMonotonicTime, storage, materialized = materializerRoot materializer}

-- | Enroll the host and authorize the connection with the handed-off
-- authority, whose opaque state custody must erase.
authorizeLive :: LiveCustody -> Text -> Text -> ConnectionIdentity -> ByteString -> Text -> IO ConnectionView
authorizeLive c host enrollment identity authority operation = do
  enrollHost c.custody host enrollment
  opaque <- newOpaqueState authority
  view <- authorize c.custody identity opaque operation
  opaqueStateErased opaque `shouldReturn` True
  pure view

-- | The finalizers' connection settlement: revoke a ready connection, erase
-- one not yet reauthorization-required, and require that state.
finishConnection :: LiveCustody -> Text -> Text -> Text -> String -> IO ()
finishConnection c connectionId revocation erasure message = do
  current <- lookupConnection c.custody connectionId
  current' <-
    if current.status == StatusReady
      then revoke c.custody connectionId revocation >> lookupConnection c.custody connectionId
      else pure current
  unless (current'.status == StatusReauthorizationRequired) $
    () <$ erase c.custody connectionId erasure
  final <- lookupConnection c.custody connectionId
  check (final.status == StatusReauthorizationRequired) message

-- | @all(lease.released for lease in storage.load().leases)@.
leasesReleased :: LiveCustody -> IO Bool
leasesReleased c = all (.released) . (.leases) <$> c.storage.load

-- ---------------------------------------------------------------------------
-- Stores

-- | The reference's in-memory @_Continuations@ / @_Turns@: one value per
-- reference, refusing a conflicting second store.
data Store v = Store
  { prefix :: Text
  , conflict :: Text
  , values :: IORef (Map Text v)
  }

newStore :: Text -> Text -> IO (Store v)
newStore prefix conflict = Store prefix conflict <$> newIORef Map.empty

remember :: (Eq v) => Store v -> Text -> v -> IO Text
remember s operationId value = do
  let reference = s.prefix <> operationId
  Map.lookup reference <$> readIORef s.values >>= \case
    Just current | current /= value -> throwAgenticus RuntimeError s.conflict
    _ -> modifyIORef' s.values (Map.insert reference value)
  pure reference

-- | @values[reference or ""]@: a missing reference is a @KeyError@.
stored :: Store v -> Maybe Text -> IO v
stored s reference =
  Map.lookup (maybe "" id reference) <$> readIORef s.values >>= \case
    Just value -> pure value
    Nothing -> throwAgenticus KeyError (maybe "" id reference)

storedCount :: Store v -> IO Int
storedCount s = Map.size <$> readIORef s.values

-- ---------------------------------------------------------------------------
-- Values

-- | @f"{prefix}{secrets.token_hex(n).upper()}"@.
marker :: Text -> Int -> IO Text
marker prefix n = do
  bytes <- getRandomBytes n :: IO ByteString
  pure (prefix <> T.pack (map toUpper (concatMap byte (B.unpack bytes))))
  where
    byte b = [digits !! fromIntegral (b `div` 16), digits !! fromIntegral (b `mod` 16)]
    digits = "0123456789abcdef"

-- | @sha256(value).hexdigest()@.
sha256Text :: ByteString -> Text
sha256Text value = T.pack (show (hash value :: Digest SHA256))

hostFencedEffect :: CapabilityDescriptor
hostFencedEffect = capabilityDescriptor (descriptorIdentity KindEffect "host.fenced" 1) ["effect.host-fenced"] []

-- | @attachment.settle(drain_timeout=...)@, whose settlement must verify.
settleVerified :: EpisodeAttachment -> Double -> IO AttachmentSettlement
settleVerified attachment drain = do
  settlement <- Episode.settle attachment drain
  settlement.settlement.verified `shouldBe` True
  pure settlement

-- | @try: ... finally: settled = attachment.settle(drain_timeout=15)@: the
-- body's failure, if any, after the settlement.
settledAfter :: EpisodeAttachment -> IO a -> IO (a, AttachmentSettlement)
settledAfter attachment body = do
  outcome <- tryAny body
  settlement <- Episode.settle attachment 15
  either throwIO (\a -> pure (a, settlement)) outcome

-- | @not tuple(path.iterdir())@.
isEmptyDirectory :: FilePath -> IO Bool
isEmptyDirectory path = null <$> listDirectory path

-- | @text.index(a) < text.index(b)@ for each consecutive pair, every one
-- present.
ordered :: Text -> [Text] -> Bool
ordered text needles =
  let positions = [if T.null rest then Nothing else Just (T.length before') | n <- needles, let (before', rest) = T.breakOn n text]
   in all (/= Nothing) positions && and (zipWith (<) positions (drop 1 positions))
