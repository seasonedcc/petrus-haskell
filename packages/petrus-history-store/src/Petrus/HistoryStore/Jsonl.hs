-- | The event History persisted as JSONL (the reference's
-- @petrus.impetus.history_store.jsonl@).
--
-- = Format
--
-- One encoded record per line, in append order: the line is exactly
-- @json.dumps(encode_record(record), allow_nan=False)@ — CPython's default
-- separators (@", "@ and @": "@) and ASCII escaping — followed by @"\\n"@.
-- The bytes are identical to the reference's, so a file written by either
-- implementation loads in the other and resumes there.
--
-- = Durability posture
--
-- Split from the format as its own policy, 'DurableAppend': each append
-- makes the parent directory once needed, opens the file for appending,
-- writes the whole batch of already-encoded lines, and closes it — no held
-- handle and no lock (the Instance is its History's single writer; JSONL has
-- no multi-writer coordination at this pin). That is durable across a
-- process crash, the reference's posture. 'PowerFailure' durability (an
-- @fsync@ of the file after each batch, and of the parent directory when the
-- file was created) is an opt-in swap at the same seam; the default matches
-- the reference.
--
-- The whole batch is encoded before any IO: a record that cannot be spelled
-- (a non-finite float in an instant, token data, or activity payload) fails
-- loud before the file is even opened, so a refused batch never lands a
-- valid prefix. An OS failure mid-write is the crash posture: a torn final
-- line fails loud at the next load, naming the line; recovery is the
-- operator's call.
--
-- = Loading
--
-- A missing file is an empty History (construction never creates it). An
-- existing file is read with universal newlines, and every line must decode
-- as a record — a blank line or a torn tail refuses the whole load with
-- @"<path>: line <n> does not decode as an event history record: <error>"@,
-- where @<error>@ is CPython's own diagnostic text.
module Petrus.HistoryStore.Jsonl
  ( -- * The store
    openJsonlHistoryStore
  , openJsonlHistoryStoreWith
  , JsonlOptions (..)
  , defaultJsonlOptions
  , Durability (..)
    -- * The durability policy
  , DurableAppend
  , durableAppend
  , appendLines
  , appendPayload
    -- * The format
  , encodeLine
  , encodeBatch
  , encodePayload
  , loadJsonlHistory
  , decodeLines
    -- * Errors
  , HistoryStoreError (..)
  ) where

import Control.Exception (bracket, throwIO)
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Unsafe qualified as BU
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Foreign.Ptr (plusPtr)
import Petrus.Impetus.History.Codec (encodeRecord)
import Petrus.Impetus.History.Records (Record, recordName)
import Petrus.Impetus.HistoryStore
import Petrus.HistoryStore.Internal (HistoryStoreError (..), decodeStored, pythonDiagnostic)
import Petrus.Json (EncodeOptions (..), Json (..), defaultDumps, dumpsBuilder, parseJson, pythonLoads)
import Petrus.Telemetry (EventSink, emit, getLogger)
import Petrus.Telemetry qualified as Telemetry
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory)
import System.Posix.IO
  ( OpenFileFlags (..)
  , OpenMode (..)
  , closeFd
  , defaultFileFlags
  , fdWriteBuf
  , openFd
  )
import System.Posix.Types (Fd)
import System.Posix.Unistd (fileSynchronise)

-- ---------------------------------------------------------------------------
-- Options

-- | How durable one append is when it returns.
data Durability
  = -- | Open, append, close: durable across a process crash (the reference).
    ProcessCrash
  | -- | Also @fsync@ the file (and its directory when the append created it).
    PowerFailure
  deriving stock (Eq, Show)

-- | Store options.
data JsonlOptions = JsonlOptions
  { durability :: Durability
  , telemetry :: Maybe EventSink
  -- ^ Where the @jsonl_commit@ events go ('Nothing': the routed default).
  }

-- | The reference's posture.
defaultJsonlOptions :: JsonlOptions
defaultJsonlOptions = JsonlOptions {durability = ProcessCrash, telemetry = Nothing}

-- ---------------------------------------------------------------------------
-- The durability policy

-- | Append whole batches of lines to one file (the reference's
-- @DurableAppend@). It never inspects what it appends.
data DurableAppend = DurableAppend
  { path :: FilePath
  , durability :: Durability
  }

-- | The policy for a path.
durableAppend :: Durability -> FilePath -> DurableAppend
durableAppend durability path = DurableAppend {path, durability}

-- | Append the batch, each line terminated by @"\\n"@, through one file
-- descriptor opened for appending (created @0666@ before the umask, as
-- Python's @open(path, "a")@).
appendLines :: DurableAppend -> [ByteString] -> IO ()
appendLines policy lines' = appendPayload policy (BS.concat (concatMap (\line -> [line, "\n"]) lines'))

-- | Append already-terminated lines as one write.
appendPayload :: DurableAppend -> ByteString -> IO ()
appendPayload policy payload = do
  let directory = takeDirectory policy.path
  createDirectoryIfMissing True directory
  existed <- if policy.durability == PowerFailure then doesFileExist policy.path else pure True
  let flags = defaultFileFlags {append = True, creat = Just 0o666}
  bracket (openFd policy.path WriteOnly flags) closeFd $ \fd -> do
    writeAll fd payload
    when (policy.durability == PowerFailure) (fileSynchronise fd)
  when (policy.durability == PowerFailure && not existed) $
    bracket (openFd directory ReadOnly defaultFileFlags) closeFd fileSynchronise

writeAll :: Fd -> ByteString -> IO ()
writeAll fd bytes = BU.unsafeUseAsCStringLen bytes $ \(start, total) ->
  let go offset = unless (offset >= total) $ do
        written <- fdWriteBuf fd (plusPtr start offset) (fromIntegral (total - offset))
        go (offset + fromIntegral written)
   in go 0

-- ---------------------------------------------------------------------------
-- The format

-- | @json.dumps(encode_record(record), allow_nan=False)@, or the reference's
-- refusal text.
encodeLine :: Record -> Either Text ByteString
encodeLine record = encodeRefusal record >> Right (BL.toStrict (B.toLazyByteString (lineBuilder record)))

-- | The reference's refusal for a record that is not JSON-faithful: the
-- first non-finite float, in the order @json.dumps@ visits values.
encodeRefusal :: Record -> Either Text ()
encodeRefusal record = case firstNonFinite (encodeRecord record) of
  Nothing -> Right ()
  Just value ->
    Left
      ( "cannot durably encode "
          <> recordName record
          <> ": Out of range float values are not JSON compliant: "
          <> floatRepr value
          <> " — durable instants and token data must be JSON-faithful values"
      )
  where
    floatRepr value
      | isNaN value = "nan"
      | value > 0 = "inf"
      | otherwise = "-inf"

firstNonFinite :: Json -> Maybe Double
firstNonFinite = \case
  Float d | isNaN d || isInfinite d -> Just d
  Array items -> firstJust (map firstNonFinite items)
  Object members -> firstJust (map (firstNonFinite . snd) members)
  _ -> Nothing
  where
    firstJust = \case
      [] -> Nothing
      Just d : _ -> Just d
      Nothing : rest -> firstJust rest

-- | One already-checked record's line, unterminated. (The check runs as a
-- separate streaming pass so no batch's values are held all at once.)
lineBuilder :: Record -> B.Builder
lineBuilder record = either (const mempty) id (dumpsBuilder defaultDumps {allowNan = True} (encodeRecord record))

-- | Encode a whole batch before any IO.
encodeBatch :: [Record] -> Either Text [ByteString]
encodeBatch = traverse encodeLine

-- | Encode a whole batch before any IO, as the one terminated payload the
-- append writes: every record is checked first, then the batch is written
-- through one builder run.
encodePayload :: [Record] -> Either Text ByteString
encodePayload batch = do
  mapM_ encodeRefusal batch
  Right (BL.toStrict (B.toLazyByteString (foldMap (\record -> lineBuilder record <> B.char7 '\n') batch)))

-- | Decode a file's bytes: universal newlines, one record per line, all or
-- nothing. The 'FilePath' only names the file in the refusal.
decodeLines :: FilePath -> ByteString -> Either Text (Seq Record)
decodeLines path content = go 1 Seq.empty (splitLines content)
  where
    go :: Int -> Seq Record -> [(ByteString, Bool)] -> Either Text (Seq Record)
    go !_ acc [] = Right acc
    go number acc ((line, terminated) : rest) = case decodeLine line terminated of
      Right record -> go (number + 1) (acc Seq.|> record) rest
      Left err ->
        Left
          ( T.pack path
              <> ": line "
              <> T.pack (show number)
              <> " does not decode as an event history record: "
              <> err
          )

-- | One line's record. The fast path parses with "Petrus.Json"; only a
-- refused line is rescanned with the CPython-exact scanner, for the
-- reference's diagnostic text.
decodeLine :: ByteString -> Bool -> Either Text Record
decodeLine line terminated = case parseJson pythonLoads line of
  Right value -> decodeStored value
  Left fallback -> Left (pythonDiagnostic (if terminated then line <> "\n" else line) (T.pack fallback))

-- | Split on universal newlines (@\\r\\n@, @\\r@, @\\n@), keeping whether each
-- line was terminated; a file's final terminator ends the last line rather
-- than starting an empty one.
splitLines :: ByteString -> [(ByteString, Bool)]
splitLines content
  | BS.null content = []
  | otherwise =
      let normalized = if BC.elem '\r' content then universal content else content
          pieces = BC.split '\n' normalized
          terminatedFinal = BC.last normalized == '\n'
          body = if terminatedFinal then init pieces else pieces
          flags = replicate (length body - 1) True ++ [terminatedFinal]
       in zip body flags
  where
    universal = BC.intercalate "\n" . map (BC.intercalate "\n" . BC.split '\r') . splitOnCrLf
    splitOnCrLf bytes = case BS.breakSubstring "\r\n" bytes of
      (before, after)
        | BS.null after -> [before]
        | otherwise -> before : splitOnCrLf (BS.drop 2 after)

-- | Load a JSONL History: a missing file is empty.
loadJsonlHistory :: FilePath -> IO (Seq Record)
loadJsonlHistory path = do
  exists <- doesFileExist path
  if not exists
    then pure Seq.empty
    else do
      content <- BS.readFile path
      either (throwIO . HistoryStoreError) pure (decodeLines path content)

-- ---------------------------------------------------------------------------
-- The store

-- | @JsonlHistoryStore(path)@: load the file (if any) and write every batch
-- through, durable before it is in memory.
openJsonlHistoryStore :: FilePath -> IO HistoryStore
openJsonlHistoryStore = openJsonlHistoryStoreWith defaultJsonlOptions

-- | 'openJsonlHistoryStore' with options.
openJsonlHistoryStoreWith :: JsonlOptions -> FilePath -> IO HistoryStore
openJsonlHistoryStoreWith options path = do
  loaded <- loadJsonlHistory path
  let policy = durableAppend options.durability path
      logger = getLogger "impetus" options.telemetry
      write batch = do
        started <- Telemetry.monotonicClock
        payload <- either (throwIO . HistoryStoreError) pure (encodePayload batch)
        appendPayload policy payload
        elapsed <- Telemetry.elapsedMs Telemetry.monotonicClock started
        emit
          logger
          "jsonl_commit"
          [ ("records", Int (fromIntegral (length batch)))
          , ("bytes", Int (fromIntegral (BS.length payload)))
          , ("elapsed_ms", Int elapsed)
          ]
        pure (map (const Entered) batch)
  mirroredHistoryStore BackendOwned loaded write
