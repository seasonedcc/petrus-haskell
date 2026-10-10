-- | Connection custody benchmark, the twin of @bench/python_custody.py@
-- (benchmark id @agenticus-custody@).
--
-- Workload: a fresh installation (SQLite store plus materialization root)
-- with 3 enrolled hosts and 10 authorized connections; then N
-- materialize(read)/release cycles, cycle @i@ on connection @i mod 10@ and
-- host @i mod 3@.  Each operation is one full custody commit (load, decode,
-- validate, transform, encode, CAS) plus the private-file work, so the cost
-- per operation grows with the audit log.  Reported: the median wall time of
-- each operation kind and the total time of the N cycles, for the reference
-- pragmas (@synchronous = FULL@) and with @synchronous = OFF@ (CPU cost
-- without fsync).
--
-- Run: @cabal bench petrus-agenticus-core --benchmark-options='custody [FULL|OFF] [N ...]'@
-- (default: both modes, N = 100, 1000, 5000).
module Bench.Custody (run) where

import Control.Exception (bracket, evaluate)
import Control.Monad (forM, forM_)
import Crypto.Cipher.AES (AES256)
import Crypto.Cipher.Types (AEADMode (AEAD_GCM), AuthTag (..), aeadInit, aeadSimpleDecrypt, aeadSimpleEncrypt, cipherInit)
import Crypto.Error (CryptoFailable (..))
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.IORef
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Petrus.Agenticus.Connection.Custody
import Petrus.Agenticus.Connection.Key
import Petrus.Agenticus.Connection.Materialization
import Petrus.Agenticus.Connection.Storage
import Petrus.Agenticus.Error
import System.Directory (createDirectory, getTemporaryDirectory, removeDirectoryRecursive, removeFile)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Text.Printf (printf)

run :: [String] -> IO ()
run arguments = do
  let (modes, rest) = case arguments of
        "FULL" : more -> ([full], more)
        "OFF" : more -> ([off], more)
        more -> ([full, off], more)
      full = ("FULL", [])
      off = ("OFF", ["PRAGMA synchronous = OFF"])
      sizes = if null rest then [100, 1000, 5000] else map read rest
  forM_ modes $ \(label, tuning) ->
    forM_ sizes $ \n -> session label tuning n

session :: String -> [Text] -> Int -> IO ()
session label tuning n = withScratch $ \scratch -> do
  let root = scratch </> "installation"
  keys <- benchKeys
  storage <- openSqliteConnectionStorageWith tuning (root </> "connections.sqlite3")
  materializer <- newPrivateFileMaterializer (root </> "materialized")
  let custody = agentConnectionCustody storage keys materializer (pure 1000)
      hosts = ["host-" <> tshow h | h <- [0 .. 2 :: Int]]
      connections = ["connection-" <> tshow c | c <- [0 .. 9 :: Int]]
  forM_ hosts $ \host -> enrollHost custody host ("enroll-" <> host)
  forM_ connections $ \connection -> do
    state <- newOpaqueState (providerState connection)
    identity <- either (fail . show) pure (mkConnectionIdentity connection "fake-rotating-oauth" (sha256Hex connection) "subscription_oauth")
    authorize custody identity state ("authorize-" <> connection)
  started <- getMonotonicTimeNSec
  samples <- forM [0 .. n - 1] $ \i -> do
    let suffix = tshow i
    (materialization, materializing) <-
      timed (materialize custody (connections !! (i `mod` 10)) (hosts !! (i `mod` 3)) LeaseRead 60 ("materialize-" <> suffix))
    (_, releasing) <- timed (release custody materialization ("release-" <> suffix))
    pure (materializing, releasing)
  finished <- getMonotonicTimeNSec
  closeCustody custody
  printf
    "custody sync=%-4s N=%-5d materialize p50 %10.1f us   release p50 %10.1f us   total %9.3f s\n"
    label
    n
    (median (map fst samples))
    (median (map snd samples))
    (fromIntegral (finished - started) / 1e9 :: Double)

timed :: IO a -> IO (a, Double)
timed action = do
  start <- getMonotonicTimeNSec
  value <- action >>= evaluate
  end <- getMonotonicTimeNSec
  pure (value, fromIntegral (end - start :: Word64) / 1e3)

median :: [Double] -> Double
median samples = case sort samples of
  [] -> 0
  sorted -> sorted !! (length sorted `div` 2)

-- | AES-256-GCM with a counter nonce, as the reference's test keys.
benchKeys :: IO KeyOperations
benchKeys = do
  counter <- newIORef (0 :: Integer)
  let key = sha256 "agenticus-custody-bench-key"
  pure
    KeyOperations
      { seal = \context plaintext -> do
          next <- atomicModifyIORef' counter (\c -> (c + 1, c + 1))
          let nonce = B.pack [fromIntegral (next `div` (256 ^ k)) | k <- [11, 10 .. 0 :: Int]]
              aead = expectCrypto (cipherInit key >>= \cipher -> aeadInit AEAD_GCM (cipher :: AES256) nonce)
              (AuthTag tag, ciphertext) = aeadSimpleEncrypt aead (authenticatedData context) plaintext 16
          evaluate (nonce <> BA.convert ciphertext <> BA.convert tag)
      , open = \context sealed -> do
          let (nonce, rest) = B.splitAt 12 sealed
              (body, tag) = B.splitAt (B.length rest - 16) rest
              aead = expectCrypto (cipherInit key >>= \cipher -> aeadInit AEAD_GCM (cipher :: AES256) nonce)
          case aeadSimpleDecrypt aead (authenticatedData context) (BA.convert body :: ScrubbedBytes) (AuthTag (BA.convert tag)) of
            Just plaintext -> pure plaintext
            Nothing -> throwAgenticus KeyOperationError "encrypted connection state failed integrity verification"
      , erase = \connectionId -> either (fail . show) pure (mkKeyErasureEvidence connectionId True)
      }

providerState :: Text -> ByteString
providerState connection =
  TE.encodeUtf8 ("{\"access_token\":\"access-" <> connection <> "\",\"refresh_token\":\"refresh-" <> connection <> "\"}")

sha256 :: ByteString -> ByteString
sha256 bytes = BA.convert (hash bytes :: Digest SHA256)

sha256Hex :: Text -> Text
sha256Hex text = T.pack (show (hash (TE.encodeUtf8 text) :: Digest SHA256))

expectCrypto :: CryptoFailable a -> a
expectCrypto = \case
  CryptoPassed value -> value
  CryptoFailed failure -> error (show failure)

tshow :: (Show a) => a -> Text
tshow = T.pack . show

withScratch :: (FilePath -> IO a) -> IO a
withScratch action = do
  base <- getTemporaryDirectory
  bracket
    ( do
        (path, handle) <- openTempFile base "petrus-custody-bench"
        hClose handle
        removeFile path
        createDirectory path
        pure path
    )
    removeDirectoryRecursive
    action
