-- | Host-custodied, content-addressed artifacts for private execution
-- evidence (upstream @_execution/artifacts.py@ @ArtifactStore@).
--
-- Each blob lives at @root/<digest[:2]>/<digest>.data@ beside its
-- reference metadata @<digest>.json@ (@json.dumps(asdict(ref),
-- sort_keys=True)@, byte-identical to upstream).  Both are written with
-- @mkstemp@-style 0600 files, fsynced and atomically replaced.  Reads are
-- integrity-checked against the reference's size and SHA-256.
module Petrus.Motus.Execution.Artifacts
  ( ProducerCorrelation (..)
  , ArtifactRef (..)
  , artifactRefJson
  , ArtifactStore
  , artifactStoreRoot
  , newArtifactStore
  , putArtifact
  , readArtifact
  , deleteArtifact
  , pruneArtifacts
  ) where

import Control.Exception (IOException, catch, throwIO, try)
import Control.Monad (forM, unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.List (isSuffixOf, sortOn)
import Data.Maybe (catMaybes)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (EncodeOptions (..), Json (..), defaultDumps, dumps)
import Petrus.Motus.Execution.Error
import Petrus.Motus.Execution.Internal.Common (uuidHex)
import Petrus.Motus.Execution.Internal.Posix (atomicWriteFile, toRawPath)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, listDirectory, removeFile)
import System.FilePath (dropExtension, (</>))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (getFileStatus, isDirectory, modificationTimeHiRes)

-- | Which lease produced an artifact.
data ProducerCorrelation = ProducerCorrelation
  { producerOperationId :: Text
  , producerProvider :: Text
  , producerLeaseId :: Text
  }
  deriving stock (Eq, Ord, Show)

-- | A portable, provider-neutral reference to one stored blob.
data ArtifactRef = ArtifactRef
  { artifactDigest :: Text
  , artifactSize :: Int
  , artifactMediaType :: Text
  , artifactRetentionClass :: Text
  , artifactProducer :: ProducerCorrelation
  }
  deriving stock (Eq, Ord, Show)

-- | @asdict(reference)@.
artifactRefJson :: ArtifactRef -> Json
artifactRefJson ref =
  Object
    [ ("digest", String (artifactDigest ref))
    , ("size", Int (fromIntegral (artifactSize ref)))
    , ("media_type", String (artifactMediaType ref))
    , ("retention_class", String (artifactRetentionClass ref))
    ,
      ( "producer"
      , Object
          [ ("operation_id", String (producerOperationId (artifactProducer ref)))
          , ("provider", String (producerProvider (artifactProducer ref)))
          , ("lease_id", String (producerLeaseId (artifactProducer ref)))
          ]
      )
    ]

newtype ArtifactStore = ArtifactStore {artifactStoreRoot :: FilePath}

-- | @ArtifactStore(root)@: creates the root (and parents).
newArtifactStore :: FilePath -> IO ArtifactStore
newArtifactStore root = do
  createDirectoryIfMissing True root
  pure (ArtifactStore root)

hexDigest :: ByteString -> Text
hexDigest bytes = T.pack (show (hash bytes :: Digest SHA256))

blobDirectory :: ArtifactStore -> Text -> FilePath
blobDirectory store digest = artifactStoreRoot store </> T.unpack (T.take 2 digest)

-- | Store a blob and its reference metadata; idempotent per content.
putArtifact :: ArtifactStore -> ByteString -> Text -> Text -> ProducerCorrelation -> IO ArtifactRef
putArtifact store bytes mediaType retentionClass producer = do
  when (T.null mediaType || T.null retentionClass) $
    throwExecution ValueError "artifact media type and retention class must be non-empty"
  let digest = hexDigest bytes
      reference = ArtifactRef digest (B.length bytes) mediaType retentionClass producer
      directory = blobDirectory store digest
  existsDir <- doesDirectoryExist directory
  unless existsDir (createDirectoryIfMissing False directory)
  metadata <-
    either (const (throwExecution ValueError "artifact metadata is not encodable")) pure $
      dumps defaultDumps {sortKeys = True} (artifactRefJson reference)
  atomic (directory </> (T.unpack digest <> ".data")) bytes
  atomic (directory </> (T.unpack digest <> ".json")) metadata
  pure reference
  where
    atomic path contents = do
      target <- toRawPath path
      let temporary = uuidHex >>= \hex -> toRawPath (blobDirectory store (hexDigest bytes) </> ("tmp" <> T.unpack (T.take 8 hex)))
      atomicWriteFile temporary target contents

-- | Read a blob, failing closed when its size or digest changed.
readArtifact :: ArtifactStore -> ArtifactRef -> IO ByteString
readArtifact store reference = do
  bytes <-
    B.readFile (blobDirectory store (artifactDigest reference) </> (T.unpack (artifactDigest reference) <> ".data"))
      `catch` \(e :: IOException) -> throwIO (osErrorFromIO e)
  when (B.length bytes /= artifactSize reference || hexDigest bytes /= artifactDigest reference) $
    throwExecution ValueError "artifact integrity check failed"
  pure bytes

-- | Remove a blob and its metadata (missing files are fine).
deleteArtifact :: ArtifactStore -> ArtifactRef -> IO ()
deleteArtifact store reference = do
  let directory = blobDirectory store (artifactDigest reference)
      digest = T.unpack (artifactDigest reference)
  removeIfExists (directory </> (digest <> ".data"))
  removeIfExists (directory </> (digest <> ".json"))

removeIfExists :: FilePath -> IO ()
removeIfExists path =
  removeFile path `catch` \(e :: IOException) -> unless (isDoesNotExistError e) (throwIO (osErrorFromIO e))

-- | Bound host evidence by blob count, oldest first (by mtime, then name),
-- never removing a protected digest.  Returns the removed digests.
pruneArtifacts :: ArtifactStore -> Int -> Set Text -> IO [Text]
pruneArtifacts store retain protected = do
  when (retain <= 0) $ throwExecution ValueError "artifact retention must be a positive integer"
  entries <- dataFiles
  let ordered = map snd (sortOn fst entries)
      surplus = max 0 (length ordered - retain)
  go surplus ordered
  where
    go 0 _ = pure []
    go _ [] = pure []
    go remaining (path : rest) = do
      let digest = T.pack (dropExtension (fileName path))
      if digest `Set.member` protected
        then go remaining rest
        else do
          removeIfExists path
          removeIfExists (dropExtension path <> ".json")
          (digest :) <$> go (remaining - 1) rest
    fileName = reverse . takeWhile (/= '/') . reverse
    -- @root.glob("*/*.data")@: non-hidden directories, non-hidden files.
    dataFiles = do
      let root = artifactStoreRoot store
      tops <- visible <$> listDirectory root
      fmap concat . forM tops $ \top -> do
        let directory = root </> top
        isDir <- either (\(_ :: IOException) -> False) isDirectory <$> try (getFileStatus directory)
        if not isDir
          then pure []
          else do
            names <- visible <$> listDirectory directory
            fmap catMaybes . forM [n | n <- names, ".data" `isSuffixOf` n] $ \name -> do
              let path = directory </> name
              status <- try (getFileStatus path)
              pure $ case status of
                Right s -> Just ((modificationTimeHiRes s, name), path)
                Left (_ :: IOException) -> Nothing
    visible = filter (\n -> take 1 n /= ".")
