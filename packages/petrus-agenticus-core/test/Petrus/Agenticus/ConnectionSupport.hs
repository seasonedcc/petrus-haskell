-- | The fixtures of @tests/petrus/agenticus/connection/test_custody.py@: a
-- fake clock at 1000.0, test-only AES-GCM key operations, the fake rotating
-- OAuth provider (the only component that parses opaque state), and a rig
-- over a real SQLite file and materializer in a scratch directory.
module Petrus.Agenticus.ConnectionSupport
  ( -- * Canaries
    accessCanary
  , refreshCanary
  , keyCanary
    -- * Scratch directories
  , withScratch
    -- * Key operations
  , SyntheticKeys (..)
  , newSyntheticKeys
  , aesGcmSeal
  , aesGcmOpen
    -- * Provider
  , FakeProvider (..)
  , newFakeProvider
  , providerAuthorize
  , providerRefresh
  , providerRotateForOperator
  , providerInspect
  , providerId
    -- * Rig
  , Rig (..)
  , withRig
  , identityFor
  , mainIdentity
  , authorizeMain
  , authorizeWith
  , reopen
  , advance
    -- * Expectations
  , raises
  , raisesMatching
  , raisesWith
  ) where

import Control.Concurrent.MVar (modifyMVar, newMVar)
import Control.Exception (bracket, try)
import Crypto.Cipher.AES (AES256)
import Crypto.Cipher.Types (AEADMode (AEAD_GCM), AuthTag (..), aeadInit, aeadSimpleDecrypt, aeadSimpleEncrypt, cipherInit)
import Crypto.Error (CryptoFailable (..))
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.IORef
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Connection.Custody
import Petrus.Agenticus.Connection.Key
import Petrus.Agenticus.Connection.Materialization
import Petrus.Agenticus.Connection.Storage
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Validate (sha256Hex)
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import System.Directory (createDirectory, getTemporaryDirectory, removeDirectoryRecursive, removeFile)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Test.Hspec hiding (context)

accessCanary, refreshCanary :: Text
accessCanary = "synthetic-access-canary-never-render"
refreshCanary = "synthetic-refresh-canary-never-render"

-- | @sha256(b"synthetic-installation-key-canary").digest()@.
keyCanary :: ByteString
keyCanary = BA.convert (hash ("synthetic-installation-key-canary" :: ByteString) :: Digest SHA256)

-- | A fresh scratch directory (pytest's @tmp_path@), removed afterwards.
withScratch :: (FilePath -> IO a) -> IO a
withScratch action = do
  base <- getTemporaryDirectory
  bracket
    ( do
        (path, handle) <- openTempFile base "petrus-agenticus-custody"
        hClose handle
        removeFile path
        createDirectory path
        pure path
    )
    removeDirectoryRecursive
    action

-- ---------------------------------------------------------------------------
-- Key operations

-- | @SyntheticKeyOperations@: a test-only AEAD key boundary with a counter
-- nonce; production receives host key operations.
data SyntheticKeys = SyntheticKeys
  { operations :: KeyOperations
  , failErasure :: IORef Bool
  }

newSyntheticKeys :: IO SyntheticKeys
newSyntheticKeys = do
  state <- newMVar (0 :: Integer, Set.empty :: Set Text)
  failErasure <- newIORef False
  let operations =
        KeyOperations
          { seal = \keyContext plaintext -> do
              nonce <- modifyMVar state $ \(counter, erased) ->
                let next = counter + 1
                 in pure ((next, Set.delete keyContext.connectionId erased), bigEndian12 next)
              pure (aesGcmSeal keyCanary nonce (authenticatedData keyContext) plaintext)
          , open = \keyContext ciphertext -> do
              erased <- modifyMVar state (\current -> pure (current, snd current))
              if Set.member keyContext.connectionId erased
                then throwAgenticus KeyOperationError "connection key is unavailable"
                else case aesGcmOpen keyCanary (authenticatedData keyContext) ciphertext of
                  Just plaintext -> pure plaintext
                  Nothing -> throwAgenticus KeyOperationError "encrypted connection state failed integrity verification"
          , erase = \connectionId -> do
              failing <- readIORef failErasure
              if failing
                then throwAgenticus KeyOperationError "synthetic key erasure failed"
                else do
                  modifyMVar state (\(counter, erased) -> pure ((counter, Set.insert connectionId erased), ()))
                  throwLeft (mkKeyErasureEvidence connectionId True)
          }
  pure SyntheticKeys {operations, failErasure}

bigEndian12 :: Integer -> ByteString
bigEndian12 n = B.pack [fromInteger ((n `div` (256 ^ k)) `mod` 256) | k <- [11, 10 .. 0 :: Int]]

-- | @nonce + AESGCM(key).encrypt(nonce, plaintext, aad)@.
aesGcmSeal :: ByteString -> ByteString -> ByteString -> ScrubbedBytes -> ByteString
aesGcmSeal key nonce aad plaintext =
  let aead = expectCrypto (cipherInit key >>= \cipher -> aeadInit AEAD_GCM (cipher :: AES256) nonce)
      (AuthTag tag, ciphertext) = aeadSimpleEncrypt aead aad plaintext 16
   in nonce <> BA.convert ciphertext <> BA.convert tag

-- | @AESGCM(key).decrypt(ciphertext[:12], ciphertext[12:], aad)@.
aesGcmOpen :: ByteString -> ByteString -> ByteString -> Maybe ScrubbedBytes
aesGcmOpen key aad sealed
  | B.length sealed < 12 + 16 = Nothing
  | otherwise =
      let (nonce, rest) = B.splitAt 12 sealed
          (body, tag) = B.splitAt (B.length rest - 16) rest
          aead = expectCrypto (cipherInit key >>= \cipher -> aeadInit AEAD_GCM (cipher :: AES256) nonce)
       in aeadSimpleDecrypt aead aad (BA.convert body :: ScrubbedBytes) (AuthTag (BA.convert tag))

expectCrypto :: CryptoFailable a -> a
expectCrypto = \case
  CryptoPassed value -> value
  CryptoFailed failure -> error (show failure)

-- ---------------------------------------------------------------------------
-- Provider

providerId :: Text
providerId = "fake-rotating-oauth"

-- | @FakeRotatingProvider@.
data FakeProvider = FakeProvider
  { authorizeCalls :: IORef Int
  , refreshCalls :: IORef Int
  , current :: IORef (Maybe [(Text, Json)])
  }

newFakeProvider :: IO FakeProvider
newFakeProvider = FakeProvider <$> newIORef 0 <*> newIORef 0 <*> newIORef Nothing

providerEncode :: [(Text, Json)] -> ByteString
providerEncode state =
  either (error . show) id $
    J.dumps J.defaultDumps {J.itemSeparator = Just ",", J.keySeparator = ":", J.sortKeys = True} (Object state)

providerParse :: ByteString -> [(Text, Json)]
providerParse bytes = case J.parseJson J.surrogateRefusingLoads bytes of
  Right (Object members) -> members
  other -> error ("provider state is not an object: " <> show other)

providerAuthorize :: FakeProvider -> Text -> IO ByteString
providerAuthorize provider account = do
  modifyIORef' provider.authorizeCalls (+ 1)
  let state =
        [ ("account", String account)
        , ("generation", Int 0)
        , ("access_token", String accessCanary)
        , ("refresh_token", String refreshCanary)
        ]
  writeIORef provider.current (Just state)
  pure (providerEncode state)

providerRefresh :: FakeProvider -> ByteString -> IO ByteString
providerRefresh provider opaqueState = do
  let state = providerParse opaqueState
  known <- readIORef provider.current
  case known of
    Just currentState | lookup "refresh_token" state == lookup "refresh_token" currentState -> pure ()
    _ -> throwAgenticus RuntimeError "provider rejected stale refresh state"
  modifyIORef' provider.refreshCalls (+ 1)
  calls <- readIORef provider.refreshCalls
  let generation = case lookup "generation" state of
        Just (Int g) -> g + 1
        _ -> error "generation"
      suffix = T.pack (show calls) <> "-" <> T.pack (show generation)
      updated =
        [ ("account", maybe Null id (lookup "account" state))
        , ("generation", Int generation)
        , ("access_token", String ("rotated-access-" <> suffix))
        , ("refresh_token", String ("rotated-refresh-" <> suffix))
        ]
  writeIORef provider.current (Just updated)
  pure (providerEncode updated)

providerRotateForOperator :: FakeProvider -> IO ByteString
providerRotateForOperator provider =
  readIORef provider.current >>= \case
    Nothing -> throwAgenticus RuntimeError "provider is not authorized"
    Just state -> providerRefresh provider (providerEncode state)

providerInspect :: FakeProvider -> ByteString -> (Text, Integer)
providerInspect _ opaqueState =
  let state = providerParse opaqueState
   in case (lookup "account" state, lookup "generation" state) of
        (Just (String account), Just (Int generation)) -> (account, generation)
        _ -> error "malformed provider state"

-- ---------------------------------------------------------------------------
-- Rig

data Rig = Rig
  { scratch :: FilePath
  -- ^ pytest's @tmp_path@.
  , root :: FilePath
  , clock :: IORef Double
  , keys :: SyntheticKeys
  , provider :: FakeProvider
  , storage :: ConnectionStorage
  , materializer :: PrivateFileMaterializer
  , custody :: AgentConnectionCustody
  , logs :: IORef [Text]
  }

-- | The @rig@ fixture; its custody logs into 'logs' (pytest's @caplog@).
withRig :: (Rig -> IO a) -> IO a
withRig action = withScratch $ \scratch -> do
  let root = scratch </> "installation"
  clock <- newIORef 1000.0
  keys <- newSyntheticKeys
  provider <- newFakeProvider
  storage <- openSqliteConnectionStorage (root </> "connections.sqlite3")
  materializer <- newPrivateFileMaterializer (root </> "materialized")
  logs <- newIORef []
  let custody =
        withCustodyLogger (\line -> modifyIORef' logs (<> [line])) $
          agentConnectionCustody storage keys.operations materializer (readIORef clock)
  action Rig {scratch, root, clock, keys, provider, storage, materializer, custody, logs}

-- | @_identity(connection_id)@.
identityFor :: Text -> ConnectionIdentity
identityFor connectionId =
  either (error . show) id $
    mkConnectionIdentity
      connectionId
      providerId
      (sha256Hex "fake-rotating-oauth\0account-1")
      "subscription_oauth"

mainIdentity :: ConnectionIdentity
mainIdentity = identityFor "connection-main"

-- | @_authorize(rig)@.
authorizeMain :: Rig -> IO ByteString
authorizeMain rig = authorizeWith rig "connection-main" "authorize-main"

authorizeWith :: Rig -> Text -> Text -> IO ByteString
authorizeWith rig connectionId operationId = do
  opaqueState <- providerAuthorize rig.provider "account-1"
  state <- newOpaqueState opaqueState
  _ <- authorize rig.custody (identityFor connectionId) state operationId
  pure opaqueState

-- | @_reopen(rig)@.
reopen :: Rig -> IO AgentConnectionCustody
reopen rig = do
  storage <- openSqliteConnectionStorage (rig.root </> "connections.sqlite3")
  materializer <- newPrivateFileMaterializer (rig.root </> "materialized")
  pure (agentConnectionCustody storage rig.keys.operations materializer (readIORef rig.clock))

advance :: Rig -> Double -> IO ()
advance rig seconds = modifyIORef' rig.clock (+ seconds)

-- ---------------------------------------------------------------------------
-- Expectations

-- | @pytest.raises(cls)@: the error, for further checks.
raisesWith :: IO a -> ErrorClass -> IO AgenticusError
raisesWith action cls = do
  outcome <- try action
  case outcome of
    Left failure
      | failure `isInstanceOf` cls -> pure failure
      | otherwise -> expectationFailure ("expected " <> show cls <> ", got " <> show failure) >> pure failure
    Right _ -> do
      expectationFailure ("expected " <> show cls <> ", got success")
      pure (AgenticusError cls "")

raises :: IO a -> ErrorClass -> Expectation
raises action cls = () <$ raisesWith action cls

-- | @pytest.raises(cls, match=fragment)@ for literal fragments.
raisesMatching :: IO a -> ErrorClass -> Text -> Expectation
raisesMatching action cls fragment = do
  failure <- raisesWith action cls
  unless' (fragment `T.isInfixOf` failure.errorMessage) $
    expectationFailure ("message " <> show failure.errorMessage <> " does not match " <> show fragment)
  where
    unless' condition failureAction = if condition then pure () else failureAction
