{-# LANGUAGE ScopedTypeVariables #-}

-- | Operational telemetry: the wall-clock shadow of the semantic trace.
--
-- The event history is Impetus's /semantic/ trace: every fact, replayable,
-- appended by the single writer. What it deliberately cannot say is how the
-- run felt from the outside: how long a durable commit took, how long an
-- activity ran on its substrate, how many turns a drive loop spent, how much
-- memory the process held. This module is that second, operational trace:
-- structured JSON events emitted beside the appends, correlated to the
-- semantic one by the fields the records carry, and never consulted by any
-- semantics. Telemetry failure must never break a run.
--
-- __Layer zero.__ This package depends on no other Petrus package except the
-- JSON value model, so every instrumented package may depend on it.
--
-- __Process-global by design.__ The reference implementation keeps the level
-- and the default sink as module globals, and its tests rely on that:
-- 'capture' must reach a logger created /before/ the capture (a module's
-- import-time logger) without any injection. That is only possible if the
-- sink is resolved at emit time from shared state, so both live in
-- @NOINLINE@ 'IORef's here. Explicit sinks ('getLogger' with 'Just') bypass
-- the global sink entirely, which is what concurrent tests should use.
--
-- Usage, at a module that instruments:
--
-- > log = getLogger "impetus" Nothing
-- > emit log "thing_happened" [("occurrence", Int 7)]
-- > withSpan log "commit" [("records", Int 3)] $ \s ->
-- >   increment s "bytes" 512
--
-- Tests observe emission with 'capture', which swaps the process-default sink
-- for a recorder:
--
-- > events <- capture Nothing Nothing $ \recorder -> step instance >> recorded recorder
module Petrus.Telemetry
  ( -- * Levels
    Level (..)
  , levels
  , levelText
  , parseLevel
  , levelEnvVar
  , levelFromEnv
  , validateTelemetryEnvironment
  , level
  , setLevel
  , atLevel

    -- * Payloads and sinks
  , Payload
  , EventSink (..)
  , telemetryLoggerName
  , telemetryLine
  , jsonLogger
  , jsonLoggerWith
  , wallClockMs
  , routedSink
  , setRoute
  , stderrRoute

    -- ** Recorder
  , TelemetryRecorder
  , newRecorder
  , recorderSink
  , recorded

    -- * Loggers
  , TelemetryLogger (..)
  , getLogger
  , bind
  , emit
  , eventName
  , exceptionJson

    -- * Spans
  , Span
  , spanName
  , spanLogger
  , withSpan
  , withSpanClassifying
  , pythonErrorType
  , withChildSpan
  , spanEmit
  , milestone
  , spanSet
  , increment
  , accumulateTime
  , spanElapsedMs

    -- * Clocks
  , Clock
  , monotonicClock
  , elapsedMs

    -- * Memory gauges
  , maxRssMb
  , currentRssMb
  , currentRssMbAt
  , statmRssMb

    -- * Capture
  , capture

    -- * Errors
  , TelemetryError (..)
  , telemetryErrorMessage
  ) where

import Control.Exception
  ( Exception (..)
  , IOException
  , SomeAsyncException
  , SomeException (..)
  , bracket
  , catch
  , finally
  , mask
  , throwIO
  , try
  )
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (for_, traverse_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub, sort)
import Data.Maybe (fromMaybe)
import Data.Ratio ((%))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Read qualified as TR
import Data.Time.Clock.POSIX (getPOSIXTime)
import Foreign.C.Error (throwErrnoIfMinus1)
import Foreign.C.Types (CLong (..))
import GHC.Clock (getMonotonicTimeNSec)
import Petrus.Json (Json (..), defaultDumps, dumps)
import Petrus.Json.PythonText (pythonStrRepr)
import Petrus.Telemetry.ErrorType (pythonErrorType)
import System.Environment (lookupEnv)
import System.IO (stderr)
import System.IO.Unsafe (unsafePerformIO)
import System.Info (os)

-- ---------------------------------------------------------------------------
-- Levels

-- | The verbosity ladder, least to most. 'Off' silences every emit; 'Facts' is
-- the default (the per-fact door events and the driver spans); 'Profile' adds
-- what costs something to gather (per-turn gauges: history size, queue
-- depths, RSS); 'Debug' is reserved for per-candidate detail. The derived
-- 'Ord' is the ladder, so 'atLevel' is a comparison.
data Level = Off | Facts | Profile | Debug
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Every level, in ladder order (the reference's @LEVELS@).
levels :: [Level]
levels = [minBound .. maxBound]

-- | The level's spelling in @$IMPETUS_TELEMETRY_LEVEL@ and in error messages.
levelText :: Level -> Text
levelText = \case
  Off -> "off"
  Facts -> "facts"
  Profile -> "profile"
  Debug -> "debug"

-- | Parse a level spelling, refusing anything else with the reference's
-- message (the offending value is quoted the way Python's @repr@ quotes it).
parseLevel :: Text -> Either Text Level
parseLevel raw = case lookup raw [(levelText l, l) | l <- levels] of
  Just l -> Right l
  Nothing -> Left (telemetryErrorMessage (UnknownTelemetryLevel raw))

-- | The environment variable that sets the initial process-wide level.
levelEnvVar :: String
levelEnvVar = "IMPETUS_TELEMETRY_LEVEL"

-- | The initial level for a given value of 'levelEnvVar': 'Facts' when unset,
-- the parsed level otherwise. Exposed so the refusal is testable without
-- poisoning the process-wide level.
levelFromEnv :: Maybe Text -> Either Text Level
levelFromEnv = maybe (Right Facts) parseLevel

-- | What 'levelEnvVar' asks for, read once per process: the initial level,
-- or the refusal for a value outside the ladder.
environmentLevel :: Either TelemetryError Level
environmentLevel = unsafePerformIO $ do
  raw <- lookupEnv levelEnvVar
  pure $ case levelFromEnv (T.pack <$> raw) of
    Right initial -> Right initial
    Left _ -> Left (UnknownTelemetryLevel (maybe "" T.pack raw))
{-# NOINLINE environmentLevel #-}

-- | Refuse an invalid 'levelEnvVar' with 'UnknownTelemetryLevel'; return
-- at once otherwise. The reference validates the variable when
-- @petrus.telemetry@ is imported, so a bad value aborts every program that
-- loads an instrumented module before it can write anything. Haskell has no
-- import-time effects, so each constructor of an instrumented runtime (the
-- History stores, the Instance, the Engine and its Coordinator, the
-- dispatches, the Worker, the PostgreSQL fabric and processes) calls this
-- first, before any I/O: a misconfigured process is refused before its
-- first durable write, never half way through a transition.
validateTelemetryEnvironment :: IO ()
validateTelemetryEnvironment = either throwIO (const (pure ())) environmentLevel

-- | The process-wide level, starting from 'environmentLevel'. Reading it is
-- total: an invalid environment value reads as 'Off' here, so 'emit' and
-- 'withSpan' never throw for configuration after an effect has happened
-- ("telemetry failure must never break a run"); the refusal belongs to
-- 'validateTelemetryEnvironment', which every instrumented constructor
-- runs before it touches anything.
levelRef :: IORef Level
levelRef = unsafePerformIO (newIORef (either (const Off) id environmentLevel))
{-# NOINLINE levelRef #-}

-- | The process-wide telemetry level.
level :: IO Level
level = readIORef levelRef

-- | Set the process-wide telemetry level. Unknown spellings are refused by
-- 'parseLevel' before they can get here.
setLevel :: Level -> IO ()
setLevel = writeIORef levelRef

-- | Whether the process-wide level admits emission gated at @minimum@: how a
-- profile-grade site asks before gathering what only it would pay for.
atLevel :: Level -> IO Bool
atLevel minimum' = (>= minimum') <$> level

-- ---------------------------------------------------------------------------
-- Payloads and sinks

-- | An event's fields, in order. Order matters only for the routed JSON line,
-- but there it is the contract: @event@, then bound context in bind order,
-- then emitted fields, then @ts@. Keys behave like a Python dict: writing an
-- existing key replaces its value in place.
type Payload = [(Text, Json)]

-- | Where emitted payloads land: 'routedSink' in production, a
-- 'TelemetryRecorder' under 'capture'.
newtype EventSink = EventSink {info :: Payload -> IO ()}

-- | The reference's stdlib logger name. There is no logging hierarchy here,
-- but routes that label or filter lines should use this identity so
-- operators see the same source on both implementations.
telemetryLoggerName :: Text
telemetryLoggerName = "impetus.telemetry"

-- | The routed line for a payload stamped at @ts@ milliseconds:
-- @json.dumps({**payload, "ts": ts}, default=str)@, byte for byte (CPython's
-- default separators and ASCII escaping). A payload that already has @ts@
-- keeps it in its original position with the new value, like the dict merge.
telemetryLine :: Integer -> Payload -> Either String ByteString
telemetryLine ts payload =
  either (Left . show) Right $
    dumps defaultDumps (Object (dictUnion payload [("ts", Int ts)]))

-- | The production sink shape: one JSON line per event, handed to @write@.
-- @ts@ (wall-clock ms) is stamped only on the routed line: it is the
-- analysis-side time axis, while the logical event (the recorder, the tests)
-- stays pure of wall clocks, exactly like the kernel.
jsonLogger :: (ByteString -> IO ()) -> EventSink
jsonLogger = jsonLoggerWith wallClockMs

-- | 'jsonLogger' with an injectable wall clock, so byte-exact comparisons
-- can pin @ts@.
jsonLoggerWith :: IO Integer -> (ByteString -> IO ()) -> EventSink
jsonLoggerWith wallClock write = EventSink $ \payload -> do
  ts <- wallClock
  -- 'defaultDumps' allows non-finite numbers, so encoding cannot fail; the
  -- branch stays total, and a sink failure is swallowed by 'emit' anyway.
  either (throwIO . userError) write (telemetryLine ts payload)

-- | @int(time.time() * 1000)@: wall-clock milliseconds, truncated.
wallClockMs :: IO Integer
wallClockMs = do
  now <- getPOSIXTime
  pure (truncate (realToFrac now * 1000 :: Double))

-- | Where 'routedSink' writes; 'Nothing' (the default) drops every line,
-- mirroring the reference's unconfigured stdlib logger, which drops INFO.
routeRef :: IORef (Maybe (ByteString -> IO ()))
routeRef = unsafePerformIO (newIORef Nothing)
{-# NOINLINE routeRef #-}

-- | The process-default production sink: a 'jsonLogger' writing to the
-- current route. With no route set, the line is not even formatted.
routedSink :: EventSink
routedSink = EventSink $ \payload ->
  readIORef routeRef >>= traverse_ (\write -> info (jsonLogger write) payload)

-- | Route the default sink's lines (the host application's equivalent of
-- configuring a handler on the reference's logger); 'Nothing' drops them.
setRoute :: Maybe (ByteString -> IO ()) -> IO ()
setRoute = writeIORef routeRef

-- | A route writing each line, newline-terminated, to standard error.
stderrRoute :: ByteString -> IO ()
stderrRoute = BC.hPutStrLn stderr

-- | The process-default sink, resolved at every emit by loggers built without
-- an explicit sink. 'capture' swaps it.
defaultSinkRef :: IORef EventSink
defaultSinkRef = unsafePerformIO (newIORef routedSink)
{-# NOINLINE defaultSinkRef #-}

-- | The test sink: the emitted payloads, in order, without @ts@. Equality is
-- identity, like the reference's @captured is recorder@.
newtype TelemetryRecorder = TelemetryRecorder (IORef [Payload])
  deriving stock (Eq)

-- | An empty recorder.
newRecorder :: IO TelemetryRecorder
newRecorder = TelemetryRecorder <$> newIORef []

-- | The recorder as a sink.
recorderSink :: TelemetryRecorder -> EventSink
recorderSink (TelemetryRecorder ref) =
  EventSink $ \payload -> atomicModifyIORef' ref (\stored -> (payload : stored, ()))

-- | Everything recorded so far, oldest first.
recorded :: TelemetryRecorder -> IO [Payload]
recorded (TelemetryRecorder ref) = reverse <$> readIORef ref

-- ---------------------------------------------------------------------------
-- Loggers

-- | A namespaced emitter with bound context.
--
-- 'sink' 'Nothing' resolves the process-default sink /at emit/, so a
-- module's long-lived logger still lands in a test's 'capture' recorder.
-- 'clock' is the monotonic clock spans read; the reference monkeypatches
-- @time.perf_counter@ in tests, and a field is the Haskell equivalent that
-- does not leak across tests.
data TelemetryLogger = TelemetryLogger
  { namespace :: Text
  , sink :: Maybe EventSink
  , context :: Payload
  , clock :: Clock
  }

-- | A logger with no bound context, reading 'monotonicClock'.
getLogger :: Text -> Maybe EventSink -> TelemetryLogger
getLogger ns target =
  TelemetryLogger {namespace = ns, sink = target, context = [], clock = monotonicClock}

-- | A child whose context every later event inherits. A field bound twice is
-- refused: a silent overwrite would let two sites disagree about one fact's
-- value. The parent is untouched.
bind :: Payload -> TelemetryLogger -> Either Text TelemetryLogger
bind fields logger = either (Left . duplicateMessage) Right (bindFields fields logger)

bindFields :: Payload -> TelemetryLogger -> Either [Text] TelemetryLogger
bindFields fields logger = (\merged -> logger {context = merged}) <$> mergeContext (context logger) fields

-- | Emit @{"event": namespace_name, **context, **fields}@.
--
-- Returns at once when the level is 'Off' (no duplicate check then, as in
-- the reference). A field that collides with the bound context throws
-- 'DuplicateTelemetryFields': the reference raises from @emit@, and a
-- collision is a programming error at the call site, not an operational
-- failure, so it is not hidden in an 'Either' every call site would ignore.
-- Synchronous exceptions from the sink are swallowed: observation has no
-- semantic authority, and a damaged or misconfigured sink may lose evidence
-- but must never stop History or execution. Asynchronous exceptions
-- (cancellation, timeouts) still propagate, like Python's @except Exception@
-- letting @KeyboardInterrupt@ through.
emit :: TelemetryLogger -> Text -> Payload -> IO ()
emit logger name fields = do
  current <- level
  unless (current == Off) $ do
    target <- maybe (readIORef defaultSinkRef) pure (sink logger)
    case mergeContext (context logger) fields of
      Left duplicates -> throwIO (DuplicateTelemetryFields duplicates)
      Right merged ->
        info target (dictUnion [("event", String (eventName logger name))] merged)
          `catch` swallowSynchronous

swallowSynchronous :: SomeException -> IO ()
swallowSynchronous e = case fromException e :: Maybe SomeAsyncException of
  Just _ -> throwIO e
  Nothing -> pure ()

-- | @namespace_name@.
eventName :: TelemetryLogger -> Text -> Text
eventName logger name = namespace logger <> "_" <> name

-- | The reference's @default=str@ spelling of an exception value (its
-- message), for call sites that report one. Payload values are already
-- 'Json', so stringification happens at the call site rather than in the
-- encoder.
exceptionJson :: (Exception e) => e -> Json
exceptionJson = String . T.pack . displayException

-- | @{**context, **fields}@, refusing keys present in both (sorted, for a
-- stable message).
mergeContext :: Payload -> Payload -> Either [Text] Payload
mergeContext bound fields =
  case sort (nub [key | (key, _) <- fields, key `elem` map fst bound]) of
    [] -> Right (dictUnion bound fields)
    duplicates -> Left duplicates

-- | @{**a, **b}@: an existing key keeps its position and takes the new value.
dictUnion :: Payload -> Payload -> Payload
dictUnion = foldl' insertField

insertField :: Payload -> (Text, Json) -> Payload
insertField fields (key, value) = case break ((== key) . fst) fields of
  (before, _ : after) -> before ++ (key, value) : after
  _ -> fields ++ [(key, value)]

-- ---------------------------------------------------------------------------
-- Spans

-- | A timed operation: @{name}_started@ on entry, @{name}_finished@ on exit
-- with @status@ and @elapsed_ms@ (and @error_type@ when the body threw; the
-- exception always propagates: telemetry observes, never swallows). Between
-- the two, 'milestone' marks progress with elapsed time, and 'spanSet',
-- 'increment' and 'accumulateTime' build the result fields the finish event
-- carries, in first-set order.
--
-- A span exists only once it has started (DIVERGENCES 13): it is made by
-- 'withSpan', so its elapsed time is always defined.
data Span = Span
  { spanLogger :: TelemetryLogger
  -- ^ The parent logger with the span's fields bound; child spans and
  -- 'spanEmit' inherit them.
  , spanName :: Text
  , spanResult :: IORef Payload
  , spanStartedAt :: Double
  , spanErrorType :: SomeException -> Text
  -- ^ The @error_type@ of an exception escaping the body.
  }

-- | @with log.span(name, **fields) as span:@. The fields are bound first,
-- so a collision with the logger's context throws 'DuplicateTelemetryFields'
-- before any event. Then the span stamps its start, emits @{name}_started@,
-- runs the body and emits @{name}_finished@. On an exception (asynchronous
-- ones included, as Python's @__exit__@ sees @KeyboardInterrupt@) the
-- finish event carries @status = "failed"@ and @error_type@, and the
-- exception is rethrown.
--
-- @error_type@ is the Python class the reference reports for the exception
-- ('pythonErrorType', or 'withSpanClassifying''s classifier); a Haskell
-- exception with no Python counterpart is named by its type constructor
-- (@ErrorCall@). If the finish emit itself throws (a result field colliding
-- with the context), that exception replaces the body's, as in the
-- reference.
withSpan :: TelemetryLogger -> Text -> Payload -> (Span -> IO a) -> IO a
withSpan = withSpanClassifying (const Nothing)

-- | 'withSpan' whose @error_type@ is named by the classifier first, then as
-- 'pythonErrorType' does. A runtime whose own failures stand for Python
-- exceptions (the Engine's @ValueError@/@RuntimeError@, a handler's
-- recorded failure) names them here.
withSpanClassifying :: (SomeException -> Maybe Text) -> TelemetryLogger -> Text -> Payload -> (Span -> IO a) -> IO a
withSpanClassifying classify logger name fields body = case bindFields fields logger of
  Left duplicates -> throwIO (DuplicateTelemetryFields duplicates)
  Right bound -> do
    result <- newIORef []
    mask $ \restore -> do
      started <- clock bound
      let s = Span bound name result started (\e -> fromMaybe (pythonErrorType e) (classify e))
      emit bound (name <> "_started") []
      value <-
        restore (body s) `catch` \(e :: SomeException) -> do
          finish s (Just e)
          throwIO e
      finish s Nothing
      pure value
  where
    finish s failure = do
      results <- readIORef (spanResult s)
      elapsed <- spanElapsedMs s
      let succeeded = dictUnion results [("status", String "success"), ("elapsed_ms", Int elapsed)]
          finished = case failure of
            Nothing -> succeeded
            Just e -> dictUnion succeeded [("status", String "failed"), ("error_type", String (spanErrorType s e))]
      emit (spanLogger s) (spanName s <> "_finished") finished

-- | A child span inheriting this span's bound fields (@span.span(...)@).
withChildSpan :: Span -> Text -> Payload -> (Span -> IO a) -> IO a
withChildSpan = withSpan . spanLogger

-- | Emit through the span's logger, inheriting its bound fields.
spanEmit :: Span -> Text -> Payload -> IO ()
spanEmit = emit . spanLogger

-- | Emit @{span}_{name}@ with the fields plus @elapsed_ms@ since the span
-- started. (The reference rejects an @elapsed_ms@ field with a @TypeError@;
-- here the measured value replaces it.)
milestone :: Span -> Text -> Payload -> IO ()
milestone s name fields = do
  elapsed <- spanElapsedMs s
  spanEmit s (spanName s <> "_" <> name) (dictUnion fields [("elapsed_ms", Int elapsed)])

-- | Set result fields for the finish event (@dict.update@).
spanSet :: Span -> Payload -> IO ()
spanSet s fields = atomicModifyIORef' (spanResult s) (\results -> (dictUnion results fields, ()))

-- | Add to a counter result field, starting from 0.
increment :: Span -> Text -> Integer -> IO ()
increment s field amount = addToResult s field amount

-- | Run a block and add its elapsed milliseconds to a result field, even when
-- the block throws: a partial phase still cost the time it took.
accumulateTime :: Span -> Text -> IO a -> IO a
accumulateTime s field body = do
  let tick = clock (spanLogger s)
  started <- tick
  body `finally` (elapsedMs tick started >>= addToResult s field)

-- | @result[field] = result.get(field, 0) + amount@ with Python's numeric
-- promotion (bools count as integers, floats stay floats).
addToResult :: Span -> Text -> Integer -> IO ()
addToResult s field amount = do
  results <- readIORef (spanResult s)
  let added = case lookup field results of
        Nothing -> Right (Int amount)
        Just (Int n) -> Right (Int (n + amount))
        Just (Bool b) -> Right (Int (toInteger (fromEnum b) + amount))
        Just (Float d) -> Right (Float (d + fromInteger amount))
        Just _ -> Left (NonNumericTelemetryField field)
  either throwIO (\value -> writeIORef (spanResult s) (insertField results (field, value))) added

-- | Milliseconds since the span started.
spanElapsedMs :: Span -> IO Integer
spanElapsedMs s = elapsedMs (clock (spanLogger s)) (spanStartedAt s)

-- ---------------------------------------------------------------------------
-- Clocks

-- | A monotonic clock in fractional seconds (the reference's
-- @time.perf_counter@). Seconds as 'Double' keep the reference's float
-- arithmetic, so injected readings round exactly as they do there.
type Clock = IO Double

-- | The process's monotonic clock.
monotonicClock :: Clock
monotonicClock = (\ns -> fromIntegral ns / 1e9) <$> getMonotonicTimeNSec

-- | @round((now - started) * 1000)@; 'round' on 'Double' is banker's
-- rounding, like Python's.
elapsedMs :: Clock -> Double -> IO Integer
elapsedMs tick started = (\now -> round ((now - started) * 1000)) <$> tick

-- ---------------------------------------------------------------------------
-- Memory gauges

foreign import ccall unsafe "petrus_telemetry_max_rss" c_maxRss :: IO CLong

foreign import ccall unsafe "petrus_telemetry_page_size" c_pageSize :: IO CLong

-- | The process's peak resident set in MB, to one decimal: @ru_maxrss@ is
-- bytes on Darwin and kilobytes elsewhere. (Not "GHC.Stats", which reports
-- the heap, not the resident set.)
maxRssMb :: IO Double
maxRssMb = do
  raw <- throwErrnoIfMinus1 "getrusage" c_maxRss
  let divisor = if os == "darwin" then 1024 * 1024 else 1024
  pure (pythonRound1 (fromRational (toInteger raw % divisor)))

-- | The current resident set from @/proc/self/statm@, in MB: 'Nothing' where
-- /proc does not exist (macOS). Absent, never wrong.
currentRssMb :: IO (Maybe Double)
currentRssMb = currentRssMbAt "/proc/self/statm"

-- | 'currentRssMb' reading a given statm file; any read or parse failure is
-- 'Nothing'.
currentRssMbAt :: FilePath -> IO (Maybe Double)
currentRssMbAt path =
  try (BS.readFile path) >>= \case
    Left (_ :: IOException) -> pure Nothing
    Right contents -> do
      pageSize <- c_pageSize
      pure $ if pageSize < 0 then Nothing else statmRssMb (toInteger pageSize) contents

-- | Parse statm contents (@size resident shared text lib data dt@, in pages)
-- into resident MB for a page size, to one decimal; 'Nothing' when the
-- second field is missing or not an integer.
statmRssMb :: Integer -> ByteString -> Maybe Double
statmRssMb pageSize contents = do
  text <- either (const Nothing) Just (TE.decodeUtf8' contents)
  field <- case T.words text of
    _ : resident : _ -> Just resident
    _ -> Nothing
  pages <- case TR.signed TR.decimal field of
    Right (n, rest) | T.null rest -> Just n
    _ -> Nothing
  pure (pythonRound1 (fromRational ((pages * pageSize) % (1024 * 1024))))

-- | Python's @round(x, 1)@: half-even on the exact binary value.
pythonRound1 :: Double -> Double
pythonRound1 x
  | isNaN x || isInfinite x = x
  | otherwise = fromRational (fromInteger (round (toRational x * 10)) / 10)

-- ---------------------------------------------------------------------------
-- Capture

-- | Swap the process-default sink for a recorder (a fresh one when
-- 'Nothing'), and optionally the level, for the duration of the body;
-- restore both afterwards, even on exceptions. This is how a test observes any
-- module's long-lived logger without injection. Like the reference it is
-- process-wide, not thread-scoped: an emit from any thread lands in the
-- recorder, so specs using it must not run in parallel.
capture :: Maybe TelemetryRecorder -> Maybe Level -> (TelemetryRecorder -> IO a) -> IO a
capture provided override body = do
  recorder <- maybe newRecorder pure provided
  bracket (swap recorder) restore (const (body recorder))
  where
    swap recorder = do
      previous <- (,) <$> readIORef defaultSinkRef <*> readIORef levelRef
      writeIORef defaultSinkRef (recorderSink recorder)
      for_ override setLevel
      pure previous
    restore (previousSink, previousLevel) = do
      writeIORef defaultSinkRef previousSink
      writeIORef levelRef previousLevel

-- ---------------------------------------------------------------------------
-- Errors

-- | Programming errors telemetry refuses loudly. Operational failures (a
-- broken sink) are never raised.
data TelemetryError
  = -- | A level spelling outside the ladder (the raw value).
    UnknownTelemetryLevel Text
  | -- | Fields bound twice, sorted.
    DuplicateTelemetryFields [Text]
  | -- | 'increment' or 'accumulateTime' onto a non-numeric result field
    -- (the reference's @TypeError@).
    NonNumericTelemetryField Text
  deriving stock (Eq, Show)

instance Exception TelemetryError where
  displayException = T.unpack . telemetryErrorMessage

-- | The reference's message for each error.
telemetryErrorMessage :: TelemetryError -> Text
telemetryErrorMessage = \case
  UnknownTelemetryLevel raw ->
    "unknown telemetry level "
      <> pythonRepr raw
      <> ": one of "
      <> T.intercalate ", " (map levelText levels)
  DuplicateTelemetryFields names -> duplicateMessage names
  NonNumericTelemetryField field ->
    "unsupported operand type(s) for +: telemetry field '" <> field <> "' is not numeric"

duplicateMessage :: [Text] -> Text
duplicateMessage names = "Telemetry context already has field(s): " <> T.intercalate ", " names <> "."

-- | CPython's @repr(str)@, so the level refusal quotes the value identically
-- (CPython 3.14's printability for every code point: "Petrus.Json.PythonText").
pythonRepr :: Text -> Text
pythonRepr = pythonStrRepr
