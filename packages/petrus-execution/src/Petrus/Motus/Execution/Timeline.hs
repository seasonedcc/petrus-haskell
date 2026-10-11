-- | Best-effort operational Timeline for private execution evidence
-- (upstream @_execution/timeline.py@).
--
-- The Timeline is write-only and non-canonical: runtime code mints
-- producer-ordered observations into a JSON-lines file (mode 0600, one
-- fsynced append per event) and never reads them back for authority.
-- Secrets are redacted recursively by key name and by value shape before
-- anything reaches disk.  Restarting re-reads the file only to continue
-- each producer's sequence; optional retention trims the file to the most
-- recent lines with hysteresis.
module Petrus.Motus.Execution.Timeline
  ( -- * Events
    TimelineEvent (..)
  , timelineEventJson
  , isoformat
  , phaseOf
    -- * Redaction
  , isSecretKey
  , redactSecretValues
  , redactJson
    -- * The sink
  , Timeline
  , timelinePath
  , newTimeline
  , observe
  , ObserveSpec (..)
  , observeSpec
  , appendEvent
  , deleteTimeline
    -- * Telemetry mirror
  , TelemetryTimelineHandler (..)
  , telemetryTimelineHandler
  , emitTelemetry
  , correlationFields
  ) where

import Control.Applicative ((<|>))
import Control.Concurrent.MVar
import Control.Exception (IOException, SomeAsyncException, SomeException, bracket, catch, fromException, throwIO)
import Control.Monad (foldM, guard, unless, when)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.Char (isAsciiLower, isDigit, toLower)
import Data.Fixed (Pico)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), getCurrentTime, toGregorian, timeToTimeOfDay, TimeOfDay (..))
import Petrus.Json (EncodeOptions (..), Json (..), defaultDumps, dumps, lookupMember, parseJson, pythonLoads)
import Petrus.Motus.Execution.Error
import Petrus.Motus.Execution.Internal.Common (newUuid4, uuidHex)
import Petrus.Motus.Execution.Internal.Posix (atomicWriteFile, fsyncFd, toRawPath)
import Petrus.Json.Python (isPythonSpace, pythonRepr, pythonStr, pythonStrRepr)
import Petrus.Motus.Execution.Internal.PyText (pyInt)
import System.Directory (createDirectoryIfMissing, doesPathExist, removeFile)
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (setFileMode)
import System.Posix.IO.ByteString (OpenFileFlags (..), OpenMode (..), closeFd, defaultFileFlags, fdWrite, openFd)
import Text.Printf (printf)

-- ---------------------------------------------------------------------------
-- Events

-- | One observation.  @observed_at@ is always timezone-aware (UTC).
data TimelineEvent = TimelineEvent
  { eventId :: Text
  , eventKind :: Text
  , eventSchemaVersion :: Int
  , eventProducer :: Text
  , eventProducerSequence :: Int
  , eventObservedAt :: UTCTime
  , eventPhase :: Text
  , eventOutcome :: Text
  , eventCorrelation :: [(Text, Text)]
  , eventCausalRefs :: [Text]
  , eventMetadata :: [(Text, Json)]
  , eventRetentionPolicy :: Text
  }
  deriving stock (Eq, Show)

-- | @datetime.isoformat()@ of an aware UTC datetime (microseconds).
isoformat :: UTCTime -> Text
isoformat time =
  let (year, month, day) = toGregorian (utctDay time)
      TimeOfDay hour minute seconds = timeToTimeOfDay (utctDayTime time)
      whole = floor seconds :: Int
      micros = floor ((seconds - fromIntegral whole) * 1000000 :: Pico) :: Int
      fraction = if micros == 0 then "" else printf ".%06d" micros
   in T.pack (printf "%04d-%02d-%02dT%02d:%02d:%02d" year month day hour minute whole <> fraction <> "+00:00")

truncateToMicros :: UTCTime -> UTCTime
truncateToMicros time =
  let picos = utctDayTime time
      micros = fromIntegral (floor (picos * 1000000) :: Integer) / 1000000
   in time {utctDayTime = micros}

-- | The on-disk record (redacted, @asdict@ field set).
timelineEventJson :: TimelineEvent -> Json
timelineEventJson event =
  Object
    [ ("event_id", String (eventId event))
    , ("event_kind", String (eventKind event))
    , ("schema_version", Int (fromIntegral (eventSchemaVersion event)))
    , ("producer", String (eventProducer event))
    , ("producer_sequence", Int (fromIntegral (eventProducerSequence event)))
    , ("observed_at", String (isoformat (eventObservedAt event)))
    , ("phase", String (eventPhase event))
    , ("outcome", String (eventOutcome event))
    , ("correlation", redactJson "" (Object [(k, String v) | (k, v) <- eventCorrelation event]))
    , ("causal_refs", Array (map String (eventCausalRefs event)))
    , ("metadata", redactJson "" (Object (eventMetadata event)))
    , ("retention_policy", String (eventRetentionPolicy event))
    ]

-- | @_phase@: the lifecycle phase implied by an event kind's suffix.
phaseOf :: Text -> Text
phaseOf kind =
  case [phase | (suffix, phase) <- suffixes, suffix `T.isSuffixOf` kind] of
    phase : _ -> phase
    [] -> "observe"
  where
    suffixes =
      [ ("_started", "start")
      , ("_finished", "finish")
      , ("_accepted", "accept")
      , ("_claimed", "claim")
      , ("_heartbeat", "heartbeat")
      , ("_completed", "complete")
      , ("_failed", "fail")
      , ("_destroyed", "destroy")
      ]

-- ---------------------------------------------------------------------------
-- Redaction (the upstream regular expressions, matched by hand)

-- | Python @re.IGNORECASE@ folding for the ASCII patterns used here.
fold :: Char -> Char
fold c = case toLower c of
  '\x131' -> 'i'
  '\x17f' -> 's'
  other -> other

-- | Case-insensitive prefix: the rest of the input after it.
prefixCI :: String -> String -> Maybe String
prefixCI [] rest = Just rest
prefixCI (p : ps) (c : cs) | fold c == p = prefixCI ps cs
prefixCI _ _ = Nothing

-- | @_SECRET.search(key)@:
-- @secret|token|password|credential|authorization|auth.?headers?|cookie|private.?key|process.?env|reasoning@.
isSecretKey :: Text -> Bool
isSecretKey key = any matchesAt (suffixesOf (T.unpack key))
  where
    suffixesOf s = s : case s of
      [] -> []
      _ : rest -> suffixesOf rest
    matchesAt s =
      any (\word -> prefixCI word s /= Nothing) ["secret", "token", "password", "credential", "authorization", "cookie", "reasoning"]
        || gap "auth" "header" s
        || gap "private" "key" s
        || gap "process" "env" s
    gap first second s = case prefixCI first s of
      Nothing -> False
      Just rest -> prefixCI second rest /= Nothing || case rest of
        c : more | c /= '\n' -> prefixCI second more /= Nothing
        _ -> False

-- | @_SECRET_VALUE.sub("[REDACTED]", value)@:
-- @(?i)(?:bearer\\s+)[A-Za-z0-9._~+/=-]+|(?:github_pat_|gh[opsu]_|sk-(?:or-)?)[A-Za-z0-9_-]{8,}@.
redactSecretValues :: Text -> Text
redactSecretValues = T.pack . go . T.unpack
  where
    go [] = []
    go s@(c : cs) = case bearer s <|> tokenLike s of
      Just rest -> "[REDACTED]" <> go rest
      Nothing -> c : go cs
    alnum c = let f = fold c in isAsciiLower f || isDigit f
    bearerClass c = alnum c || c `elem` ("._~+/=-" :: String)
    tokenClass c = alnum c || c `elem` ("_-" :: String)
    bearer s = do
      rest <- prefixCI "bearer" s
      let (spaces, afterSpaces) = span isPythonSpace rest
          (body, afterBody) = span bearerClass afterSpaces
      guard (not (null spaces) && not (null body))
      pure afterBody
    tokenBody rest =
      let (body, after) = span tokenClass rest
       in if length body >= 8 then Just after else Nothing
    tokenLike s =
      (prefixCI "github_pat_" s >>= tokenBody)
        <|> (gh s >>= tokenBody)
        <|> (prefixCI "sk-or-" s >>= tokenBody)
        <|> (prefixCI "sk-" s >>= tokenBody)
    gh s = do
      rest <- prefixCI "gh" s
      case rest of
        c : '_' : more | fold c `elem` ("opsu" :: String) -> Just more
        _ -> Nothing

-- | @_redact(value, key)@: secret-named keys become @[REDACTED]@ whatever
-- their value; strings lose secret-shaped substrings; containers recurse.
redactJson :: Text -> Json -> Json
redactJson key value
  | isSecretKey key = String "[REDACTED]"
  | otherwise = case value of
      Object members -> Object [(k, redactJson k v) | (k, v) <- members]
      Array items -> Array (map (redactJson "") items)
      String t -> String (redactSecretValues t)
      other -> other

-- ---------------------------------------------------------------------------
-- The sink

data TimelineState = TimelineState
  { stateSequences :: Map Text Int
  , stateLineCount :: Int
  }

data Timeline = Timeline
  { timelinePath :: FilePath
  , timelineRetain :: Maybe Int
  , timelineState :: MVar TimelineState
  }

-- | @str.splitlines()@ line boundaries.
pySplitLines :: Text -> [Text]
pySplitLines text
  | T.null text = []
  | otherwise =
      let (line, rest) = T.break boundary text
       in line : case T.uncons rest of
            Nothing -> []
            Just ('\r', more) | Just ('\n', after) <- T.uncons more -> pySplitLines after
            Just (_, more) -> pySplitLines more
  where
    boundary c = c `elem` ("\n\r\v\f\x1c\x1d\x1e\x85\x2028\x2029" :: String)

-- | @bytes.splitlines(keepends=True)@.
splitLinesKeepEnds :: B.ByteString -> [B.ByteString]
splitLinesKeepEnds bytes
  | B.null bytes = []
  | otherwise =
      let (line, rest) = BC.break (\c -> c == '\n' || c == '\r') bytes
          endLength
            | "\r\n" `B.isPrefixOf` rest = 2
            | B.null rest = 0
            | otherwise = 1
       in B.take (B.length line + endLength) bytes : splitLinesKeepEnds (B.drop (B.length line + endLength) bytes)

-- | @Timeline(path, retain=...)@: re-reads an existing file to continue
-- every producer's sequence.
newTimeline :: FilePath -> Maybe Int -> IO Timeline
newTimeline path retain = do
  case retain of
    Just n | n <= 0 -> throwExecution ValueError "Timeline retention must be a positive integer or None"
    _ -> pure ()
  createDirectoryIfMissing True (takeDirectory path)
  exists <- doesPathExist path
  state <-
    if not exists
      then pure (TimelineState Map.empty 0)
      else do
        setFileMode path 0o600
        bytes <- B.readFile path
        text <- either (const (throwExecution ValueError "Timeline is not valid UTF-8")) pure (TE.decodeUtf8' bytes)
        let lines' = pySplitLines text
        sequences <- foldM (flip register) Map.empty lines'
        pure (TimelineState sequences (length lines'))
  Timeline path retain <$> newMVar state
  where
    register line sequences = do
      record <- either (throwExecution ValueError . T.pack) pure (parseJson pythonLoads (TE.encodeUtf8 line))
      producer <- pythonStr <$> member "producer" record
      nextSequence <- member "producer_sequence" record >>= pythonInt
      pure (Map.insertWith max producer nextSequence sequences)
    member key record = case record of
      Object _ -> maybe (throwExecution KeyError (pythonStrRepr key)) pure (lookupMember key record)
      _ -> throwExecution TypeError "list indices must be integers or slices, not str"
    pythonInt = \case
      Int n -> pure (fromInteger n)
      Bool b -> pure (if b then 1 else 0)
      Float d -> pure (truncate d)
      String t | Just n <- pyInt (T.unpack t) -> pure (fromInteger n)
      other -> throwExecution ValueError ("invalid literal for int() with base 10: " <> pythonRepr other)

-- | The keyword arguments of @Timeline.observe@.
data ObserveSpec = ObserveSpec
  { observeProducer :: Text
  , observePhase :: Text
  , observeOutcome :: Text
  , observeCorrelation :: [(Text, Text)]
  , observeCausalRefs :: [Text]
  , observeMetadata :: [(Text, Json)]
  , observeRetentionPolicy :: Text
  }

-- | Required fields with upstream defaults for the rest.
observeSpec :: Text -> Text -> Text -> [(Text, Text)] -> ObserveSpec
observeSpec producer phase outcome correlation = ObserveSpec producer phase outcome correlation [] [] "operational"

-- | Mint one producer-ordered observation.
observe :: Timeline -> Text -> ObserveSpec -> IO TimelineEvent
observe timeline kind spec =
  modifyMVar (timelineState timeline) $ \state -> do
    let nextSequence = Map.findWithDefault 0 (observeProducer spec) (stateSequences state) + 1
    identifier <- newUuid4
    now <- truncateToMicros <$> getCurrentTime
    let event =
          TimelineEvent
            { eventId = identifier
            , eventKind = kind
            , eventSchemaVersion = 1
            , eventProducer = observeProducer spec
            , eventProducerSequence = nextSequence
            , eventObservedAt = now
            , eventPhase = observePhase spec
            , eventOutcome = observeOutcome spec
            , eventCorrelation = dictPairs (observeCorrelation spec)
            , eventCausalRefs = observeCausalRefs spec
            , eventMetadata = dictPairs (observeMetadata spec)
            , eventRetentionPolicy = observeRetentionPolicy spec
            }
    lineCount <- appendRecord timeline (stateLineCount state) event
    pure (TimelineState (Map.insert (observeProducer spec) nextSequence (stateSequences state)) lineCount, event)

-- | Python @dict(pairs)@: first position, last value.
dictPairs :: [(Text, a)] -> [(Text, a)]
dictPairs pairs = Map.elems (Map.fromListWith (\_ old -> old) indexed)
  where
    lastValue = Map.fromList pairs
    firstIndex = Map.fromListWith (\_ old -> old) (zip (map fst pairs) [0 :: Int ..])
    indexed = [(firstIndex Map.! k, (k, lastValue Map.! k)) | (k, _) <- pairs]

-- | @Timeline.append@: the event must be the producer's next sequence number.
appendEvent :: Timeline -> TimelineEvent -> IO ()
appendEvent timeline event =
  modifyMVar_ (timelineState timeline) $ \state -> do
    let expected = Map.findWithDefault 0 (eventProducer event) (stateSequences state) + 1
    when (eventProducerSequence event /= expected) $
      throwExecution
        ValueError
        ( "Timeline producer "
            <> pythonStrRepr (eventProducer event)
            <> " expected sequence "
            <> T.pack (show expected)
            <> ", got "
            <> T.pack (show (eventProducerSequence event))
        )
    lineCount <- appendRecord timeline (stateLineCount state) event
    pure (TimelineState (Map.insert (eventProducer event) (eventProducerSequence event) (stateSequences state)) lineCount)

-- | @_append@: validate, redact, append one fsynced line, then apply the
-- retention policy.  Returns the new line count.
appendRecord :: Timeline -> Int -> TimelineEvent -> IO Int
appendRecord timeline lineCount event = do
  when
    ( eventSchemaVersion event /= 1
        || any T.null [eventId event, eventKind event, eventProducer event, eventPhase event, eventOutcome event]
    )
    (throwExecution ValueError "Timeline event has an invalid envelope")
  encoded <-
    either (const (throwExecution TypeError "Timeline metadata is not JSON serializable")) pure $
      dumps defaultDumps {itemSeparator = Just ",", keySeparator = ":", sortKeys = True} (timelineEventJson event)
  rawPath <- toRawPath (timelinePath timeline)
  ( bracket (openFd rawPath WriteOnly defaultFileFlags {append = True, creat = Just 0o600, cloexec = True}) closeFd $ \fd -> do
      writeFully fd (encoded <> "\n")
      fsyncFd fd
    )
    `catch` \(e :: IOException) -> throwIO (osErrorFromIO e)
  let count = lineCount + 1
  case timelineRetain timeline of
    Nothing -> pure count
    Just retain -> do
      let slack = if retain < 100 then 0 else max 100 (retain `div` 10)
      if count <= retain + slack
        then pure count
        else do
          bytes <- B.readFile (timelinePath timeline)
          let kept = lastN retain (splitLinesKeepEnds bytes)
              directory = takeDirectory (timelinePath timeline)
          atomicWriteFile (uuidHex >>= \hex -> toRawPath (directory </> ("tmp" <> T.unpack (T.take 8 hex)))) rawPath (B.concat kept)
          setFileMode (timelinePath timeline) 0o600
          pure (length kept)
  where
    lastN n items = drop (length items - n) items
    writeFully fd bytes = unless (B.null bytes) $ do
      written <- fdWrite fd bytes
      writeFully fd (B.drop (fromIntegral written) bytes)

-- | Remove the Timeline file.
deleteTimeline :: Timeline -> IO ()
deleteTimeline timeline =
  removeFile (timelinePath timeline) `catch` \(e :: IOException) -> unless (isDoesNotExistError e) (throwIO (osErrorFromIO e))

-- ---------------------------------------------------------------------------
-- Telemetry mirror

-- | Mirrors JSON telemetry log messages into a Timeline (upstream's
-- @logging.Handler@ subclass; here 'emitTelemetry' takes the formatted
-- message directly).
data TelemetryTimelineHandler = TelemetryTimelineHandler
  { handlerTimeline :: Timeline
  , handlerProducer :: Text
  }

telemetryTimelineHandler :: Timeline -> TelemetryTimelineHandler
telemetryTimelineHandler timeline = TelemetryTimelineHandler timeline "petrus.telemetry"

-- | Telemetry keys that become string correlation instead of metadata.
correlationFields :: Set Text
correlationFields =
  Set.fromList
    [ "activity", "artifact_digest", "attachment_id", "attempt", "claimant", "delivery_id", "effect_id", "epoch"
    , "head", "history_position", "identity", "input_artifact_digest", "instance", "lease_id", "net", "occurrence"
    , "operation", "operation_id", "pull_request", "queue", "repository", "request_id", "run_attempt", "run_id"
    , "transition", "worker"
    ]

-- | Mirror one telemetry message.  Never throws (synchronously): a
-- malformed payload or a failing sink must not escape into execution.
emitTelemetry :: TelemetryTimelineHandler -> Text -> IO ()
emitTelemetry handler message =
  mirror `catch` \(failure :: SomeException) -> case fromException failure of
    Just (async :: SomeAsyncException) -> throwIO async
    Nothing -> pure ()
  where
    mirror = case parseJson pythonLoads (TE.encodeUtf8 message) of
      Right (Object members) | Just (String kind) <- lookup "event" members -> do
        let payload = [(k, v) | (k, v) <- dictPairs members, k /= "event", k /= "ts"]
            correlation =
              [ (k, pythonStr v)
              | (k, v) <- payload
              , k `Set.member` correlationFields
              , not (isNull v)
              , not (T.null (pythonStr v))
              ]
            metadata = [(k, v) | (k, v) <- payload, not (k `Set.member` correlationFields)]
            outcome = pythonStr (maybe (maybe (String "observed") id (lookup "status" payload)) id (lookup "outcome" payload))
        _ <-
          observe
            (handlerTimeline handler)
            kind
            (observeSpec (handlerProducer handler) (phaseOf kind) outcome correlation)
              { observeMetadata = metadata
              , observeRetentionPolicy = "bounded-operational"
              }
        pure ()
      _ -> pure ()
    isNull = \case
      Null -> True
      _ -> False

