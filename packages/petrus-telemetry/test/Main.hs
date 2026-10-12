{-# LANGUAGE ScopedTypeVariables #-}

-- | Behavioral tests for the telemetry module itself: the emitter, the span,
-- the sinks, the capture swap. One @it@ per upstream test in
-- @tests/petrus/telemetry/test_telemetry.py@, in upstream order, followed by
-- Haskell-specific checks. The level and the default sink are process-global,
-- so the whole spec runs sequentially.
module Main (main) where

import Control.Exception (ArithException (..), AsyncException (..), ErrorCall (..), Exception, SomeException, fromException, throwIO, try)
import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Petrus.Json (Json (..), exactEq, parseJson, surrogateRefusingLoads)
import Foreign.C.Error (eACCES, eAGAIN, eNOENT, eNOSPC, ePIPE, errnoToIOError)
import Petrus.Telemetry
import System.Exit (ExitCode (..))
import Test.Hspec

-- | The upstream tests raise @RuntimeError@; a Haskell exception with the
-- same type name makes @error_type@ comparable verbatim.
newtype RuntimeError = RuntimeError String
  deriving stock (Show)

instance Exception RuntimeError

makeLogger :: IO (TelemetryLogger, TelemetryRecorder)
makeLogger = do
  recorder <- newRecorder
  pure (getLogger "impetus" (Just (recorderSink recorder)), recorder)

-- | Upstream's @log.bind(...)@ in test setup: a refusal here is a test bug.
bound :: Payload -> TelemetryLogger -> TelemetryLogger
bound fields logger = either (error . T.unpack) id (bind fields logger)

-- | The monkeypatched @perf_counter@: each read takes the next value.
fakeClock :: [Double] -> IO Clock
fakeClock values = do
  ref <- newIORef values
  pure $ atomicModifyIORef' ref $ \case
    next : rest -> (rest, next)
    [] -> error "fake clock exhausted"

-- | caplog: route the default sink's lines into a list for the block.
withRoutedLines :: IO () -> IO [ByteString]
withRoutedLines block = do
  ref <- newIORef []
  setRoute (Just (\line -> modifyIORef' ref (line :)))
  block
  setRoute Nothing
  reverse <$> readIORef ref

loggedPayloads :: [ByteString] -> [[(T.Text, Json)]]
loggedPayloads = map $ \line -> case parseJson surrogateRefusingLoads line of
  Right (Object members) -> members
  other -> error ("not a JSON object line: " <> show other)

field :: T.Text -> [(T.Text, Json)] -> Json
field key payload = maybe (error ("missing field " <> T.unpack key)) id (lookup key payload)

events :: TelemetryRecorder -> IO [Json]
events recorder = map (field "event") <$> recorded recorder

isInt :: Json -> Bool
isInt = \case
  Int _ -> True
  _ -> False

shouldThrowMessage :: IO a -> T.Text -> Expectation
shouldThrowMessage action message =
  try action >>= \case
    Left (e :: TelemetryError) -> telemetryErrorMessage e `shouldSatisfy` T.isInfixOf message
    Right _ -> expectationFailure ("expected a TelemetryError mentioning " <> show message)

main :: IO ()
main = hspec . sequential $ do
  -- Adapted: there is no stdlib logging hierarchy; the identity survives as
  -- the constant routes use to label lines.
  it "stdlib logger preserves its operational identity" $
    telemetryLoggerName `shouldBe` "impetus.telemetry"

  describe "TelemetryLogger emit" $ do
    -- Adapted: caplog on the stdlib logger becomes a route on the default
    -- production sink ('routedSink', the JsonLogger(python_logger) analogue).
    it "json logger writes namespaced json log line stamped with wall clock ts" $ do
      let logger = getLogger "impetus" (Just routedSink)
      lines' <- withRoutedLines (emit logger "thing" [("occurrence", Int 1)])
      case loggedPayloads lines' of
        [payload] -> do
          field "ts" payload `shouldSatisfy` isInt
          filter ((/= "ts") . fst) payload
            `shouldBe` [("event", String "impetus_thing"), ("occurrence", Int 1)]
        other -> expectationFailure ("expected one line, got " <> show other)

    -- Adapted (enforced by types): payload values are 'Json', so a value with
    -- no JSON spelling cannot reach the encoder; call sites stringify, and
    -- 'exceptionJson' is the reference's str(exception).
    it "json logger spells non json values as strings" $ do
      let logger = getLogger "impetus" (Just routedSink)
      lines' <- withRoutedLines (emit logger "thing" [("error", exceptionJson (ErrorCall "boom"))])
      case loggedPayloads lines' of
        [payload] -> do
          field "event" payload `shouldBe` String "impetus_thing"
          field "error" payload `shouldBe` String "boom"
        other -> expectationFailure ("expected one line, got " <> show other)

    it "recorder payloads carry no wall clock ts" $ do
      (logger, recorder) <- makeLogger
      emit logger "thing" []
      recorded recorder `shouldReturn` [[("event", String "impetus_thing")]]

    it "injected recorder receives bound structured payloads" $ do
      (logger, recorder) <- makeLogger
      emit (bound [("instance", String "order-7")] logger) "thing" [("occurrence", Int 1)]
      recorded recorder
        `shouldReturn` [[("event", String "impetus_thing"), ("instance", String "order-7"), ("occurrence", Int 1)]]

    it "capture replaces default sink for existing loggers" $ do
      let logger = getLogger "impetus" Nothing
      recorder <- capture Nothing Nothing $ \recorder -> do
        emit logger "thing" [("occurrence", Int 1)]
        pure recorder
      recorded recorder `shouldReturn` [[("event", String "impetus_thing"), ("occurrence", Int 1)]]

    it "capture restores the previous sink on exit" $ do
      let logger = getLogger "impetus" Nothing
      outer <- newRecorder
      inner <- capture (Just outer) Nothing $ \_ -> do
        inner <- capture Nothing Nothing $ \inner -> emit logger "thing" [] >> pure inner
        emit logger "after" []
        pure inner
      events inner `shouldReturn` [String "impetus_thing"]
      events outer `shouldReturn` [String "impetus_after"]

    it "capture uses provided empty recorder" $ do
      let logger = getLogger "impetus" Nothing
      recorder <- newRecorder
      captured <- capture (Just recorder) Nothing $ \captured -> do
        emit logger "thing" [("occurrence", Int 1)]
        pure captured
      (captured == recorder) `shouldBe` True
      recorded recorder `shouldReturn` [[("event", String "impetus_thing"), ("occurrence", Int 1)]]

    it "bound context is inherited without mutating parent" $ do
      (logger, recorder) <- makeLogger
      let runLog = bound [("run", Int 7)] logger
      emit runLog "run_started" []
      emit logger "unbound" []
      recorded recorder
        `shouldReturn` [ [("event", String "impetus_run_started"), ("run", Int 7)]
                       , [("event", String "impetus_unbound")]
                       ]

    it "rebinding existing context field fails loudly" $ do
      (logger, _) <- makeLogger
      let logger' = bound [("backend", String "jsonl")] logger
      either id (const "") (bind [("backend", String "postgres")] logger')
        `shouldBe` "Telemetry context already has field(s): backend."

    it "emit cannot override bound context field" $ do
      (logger, _) <- makeLogger
      let logger' = bound [("backend", String "jsonl")] logger
      emit logger' "thing" [("backend", String "postgres")] `shouldThrowMessage` "backend"

    -- Adapted: Python's OSError becomes an IOException thrown by the sink.
    it "a failing sink never gates execution" $ do
      let broken = EventSink (\_ -> throwIO (userError "observability unavailable"))
      emit (getLogger "impetus" (Just broken)) "thing" [("occurrence", Int 1)]

  describe "TelemetrySpan" $ do
    it "span emits started and finished events with result fields" $ do
      (logger, recorder) <- makeLogger
      let logger' = bound [("backend", String "jsonl")] logger
      withSpan logger' "commit" [("batch", Bool True)] $ \s -> spanSet s [("records", Int 2)]
      payloads <- recorded recorder
      case payloads of
        [started, finished] -> do
          started
            `shouldBe` [("event", String "impetus_commit_started"), ("backend", String "jsonl"), ("batch", Bool True)]
          field "event" finished `shouldBe` String "impetus_commit_finished"
          field "backend" finished `shouldBe` String "jsonl"
          field "batch" finished `shouldSatisfy` exactEq (Bool True)
          field "records" finished `shouldBe` Int 2
          field "status" finished `shouldBe` String "success"
          field "elapsed_ms" finished `shouldSatisfy` \case
            Int ms -> ms >= 0
            _ -> False
        other -> expectationFailure ("expected two events, got " <> show other)

    it "failed span emits failed status and reraises" $ do
      (logger, recorder) <- makeLogger
      let logger' = bound [("backend", String "jsonl")] logger
      outcome <- try $ withSpan logger' "commit" [] $ \s -> do
        spanSet s [("records", Int 1)]
        throwIO (RuntimeError "boom")
      case outcome of
        Left (RuntimeError message) -> message `shouldBe` "boom"
        Right () -> expectationFailure "the span swallowed the exception"
      finished <- last <$> recorded recorder
      field "event" finished `shouldBe` String "impetus_commit_finished"
      field "backend" finished `shouldBe` String "jsonl"
      field "records" finished `shouldBe` Int 1
      field "status" finished `shouldBe` String "failed"
      field "error_type" finished `shouldBe` String "RuntimeError"

    it "child span inherits parent span context" $ do
      (logger, recorder) <- makeLogger
      let logger' = bound [("worker", String "worker-1")] logger
      withSpan logger' "drain" [("queues", Int 2)] $ \drain ->
        withChildSpan drain "activity" [("task", String "t-9")] $ \activity ->
          spanSet activity [("outcome", String "completed")]
      payloads <- recorded recorder
      let childStarted = payloads !! 1
          childFinished = payloads !! 2
      childStarted
        `shouldBe` [ ("event", String "impetus_activity_started")
                   , ("worker", String "worker-1")
                   , ("queues", Int 2)
                   , ("task", String "t-9")
                   ]
      field "event" childFinished `shouldBe` String "impetus_activity_finished"
      field "worker" childFinished `shouldBe` String "worker-1"
      field "queues" childFinished `shouldBe` Int 2
      field "task" childFinished `shouldBe` String "t-9"
      field "outcome" childFinished `shouldBe` String "completed"

    it "span emit inherits span context" $ do
      (logger, recorder) <- makeLogger
      let logger' = bound [("worker", String "worker-1")] logger
      withSpan logger' "drain" [("queues", Int 2)] $ \drain ->
        spanEmit drain "drain_claimed" [("task", String "t-9")]
      payloads <- recorded recorder
      payloads !! 1
        `shouldBe` [ ("event", String "impetus_drain_claimed")
                   , ("worker", String "worker-1")
                   , ("queues", Int 2)
                   , ("task", String "t-9")
                   ]

    -- Adapted: monkeypatching perf_counter becomes the logger's clock field.
    it "span accumulate time sums repeated timing fields" $ do
      tick <- fakeClock [0.0, 0.1, 0.3, 0.4, 0.7, 1.0]
      (logger, recorder) <- makeLogger
      withSpan logger {clock = tick} "drive" [] $ \drive -> do
        accumulateTime drive "collect_ms" (pure ())
        accumulateTime drive "collect_ms" (pure ())
      finished <- last <$> recorded recorder
      field "collect_ms" finished `shouldBe` Int 500
      field "elapsed_ms" finished `shouldBe` Int 1000

    it "span accumulate time is retained when block fails" $ do
      tick <- fakeClock [0.0, 0.1, 0.4, 1.0]
      (logger, recorder) <- makeLogger
      outcome <- try $ withSpan logger {clock = tick} "drive" [] $ \drive ->
        accumulateTime drive "collect_ms" (throwIO (RuntimeError "boom") :: IO ())
      outcome `shouldSatisfy` \case
        Left (RuntimeError "boom") -> True
        _ -> False
      finished <- last <$> recorded recorder
      field "collect_ms" finished `shouldBe` Int 300
      field "elapsed_ms" finished `shouldBe` Int 1000
      field "status" finished `shouldBe` String "failed"

    it "span increments counter fields" $ do
      (logger, recorder) <- makeLogger
      withSpan logger "drive" [] $ \drive -> do
        increment drive "turns" 1
        increment drive "turns" 2
      finished <- last <$> recorded recorder
      field "turns" finished `shouldBe` Int 3

    it "span milestone emits elapsed time since span started" $ do
      tick <- fakeClock [0.0, 0.25, 1.0]
      (logger, recorder) <- makeLogger
      withSpan logger {clock = tick} "run" [] $ \run ->
        milestone run "first_firing" [("occurrence", Int 1)]
      payloads <- recorded recorder
      payloads !! 1
        `shouldBe` [("event", String "impetus_run_first_firing"), ("occurrence", Int 1), ("elapsed_ms", Int 250)]

  describe "Levels" $ do
    it "default level is facts" $
      level `shouldReturn` Facts

    -- Adapted (enforced by types): 'setLevel' takes a 'Level'; spellings are
    -- refused by 'parseLevel' with the reference's message.
    it "unknown level is refused loud" $
      parseLevel "verbose"
        `shouldBe` Left "unknown telemetry level 'verbose': one of off, facts, profile, debug"

    it "off silences every emit" $ do
      let logger = getLogger "impetus" Nothing
      recorder <- capture Nothing (Just Off) $ \recorder -> do
        emit logger "thing" []
        withSpan logger "run" [] (\_ -> pure ())
        pure recorder
      recorded recorder `shouldReturn` []

    it "at level orders the ladder" $
      capture Nothing (Just Profile) $ \_ -> do
        atLevel Facts `shouldReturn` True
        atLevel Profile `shouldReturn` True
        atLevel Debug `shouldReturn` False

    it "capture restores the previous level" $ do
      capture Nothing (Just Profile) $ \_ -> level `shouldReturn` Profile
      level `shouldReturn` Facts

  describe "MaxRss" $
    it "reports positive megabytes" $
      maxRssMb >>= (`shouldSatisfy` (> 0))

  describe "CurrentRss" $ do
    -- Adapted: mocking open/sysconf becomes the pure statm parser with an
    -- explicit page size.
    it "parses resident pages from statm" $
      statmRssMb 4096 "300000 262144 5000 100 0 50000 0" `shouldBe` Just 1024.0

    -- Adapted: open raising OSError becomes reading a path that does not exist.
    it "returns none when statm unavailable" $
      currentRssMbAt "/nonexistent/petrus-telemetry/statm" `shouldReturn` Nothing

  describe "Haskell-specific" $ do
    it "routes byte-identical CPython json.dumps lines" $ do
      ref <- newIORef []
      let sink' = jsonLoggerWith (pure 1700000000123) (\line -> modifyIORef' ref (line :))
          logger = bound [("instance", String "é")] (getLogger "impetus" (Just sink'))
      emit logger "thing" [("ratio", Float 0.5), ("ok", Bool True), ("none", Null), ("emoji", String "\x1F600")]
      readIORef ref
        `shouldReturn` [ "{\"event\": \"impetus_thing\", \"instance\": \"\\u00e9\", \"ratio\": 0.5, \"ok\": true, \"none\": null, \"emoji\": \"\\ud83d\\ude00\", \"ts\": 1700000000123}"
                       ]

    it "a payload ts keeps its position with the stamped value" $
      telemetryLine 99 [("event", String "x"), ("ts", Int 3), ("a", Int 1)]
        `shouldBe` Right "{\"event\": \"x\", \"ts\": 99, \"a\": 1}"

    it "the default route drops lines" $ do
      setRoute Nothing
      emit (getLogger "impetus" (Just routedSink)) "thing" []

    it "names duplicate fields sorted" $ do
      (logger, _) <- makeLogger
      let logger' = bound [("b", Int 1), ("a", Int 2)] logger
      either id (const "") (bind [("a", Int 1), ("b", Int 3)] logger')
        `shouldBe` "Telemetry context already has field(s): a, b."

    it "result fields keep first-set order ahead of status" $ do
      (logger, recorder) <- makeLogger
      withSpan logger {clock = pure 0} "s" [] $ \s -> do
        spanSet s [("status", String "x")]
        increment s "n" 1
      finished <- last <$> recorded recorder
      finished
        `shouldBe` [("event", String "impetus_s_finished"), ("status", String "success"), ("n", Int 1), ("elapsed_ms", Int 0)]

    it "error_type names the Python class the reference reports" $ do
      let failedWith :: Exception e => (SomeException -> Maybe T.Text) -> e -> IO Json
          failedWith classify e = do
            (logger, recorder) <- makeLogger
            void (try (withSpanClassifying classify logger "s" [] (\_ -> throwIO e)) :: IO (Either SomeException ()))
            field "error_type" . last <$> recorded recorder
      -- An errno-carrying IOException is CPython's OSError subclass for it.
      failedWith (const Nothing) (errnoToIOError "open" eNOENT Nothing (Just "x")) `shouldReturn` String "FileNotFoundError"
      failedWith (const Nothing) (errnoToIOError "open" eACCES Nothing Nothing) `shouldReturn` String "PermissionError"
      failedWith (const Nothing) (errnoToIOError "read" eAGAIN Nothing Nothing) `shouldReturn` String "BlockingIOError"
      failedWith (const Nothing) (errnoToIOError "send" ePIPE Nothing Nothing) `shouldReturn` String "BrokenPipeError"
      failedWith (const Nothing) (errnoToIOError "write" eNOSPC Nothing Nothing) `shouldReturn` String "OSError"
      failedWith (const Nothing) (userError "boom") `shouldReturn` String "OSError"
      failedWith (const Nothing) UserInterrupt `shouldReturn` String "KeyboardInterrupt"
      failedWith (const Nothing) DivideByZero `shouldReturn` String "ZeroDivisionError"
      failedWith (const Nothing) (ExitFailure 3) `shouldReturn` String "SystemExit"
      -- No Python counterpart: the Haskell type constructor.
      failedWith (const Nothing) (ErrorCall "boom") `shouldReturn` String "ErrorCall"
      -- A runtime names its own failures first.
      let classify e = if fmap (\(ErrorCall m) -> m) (fromException e) == Just "refused" then Just "ValueError" else Nothing
      failedWith classify (ErrorCall "refused") `shouldReturn` String "ValueError"
      failedWith classify (ErrorCall "other") `shouldReturn` String "ErrorCall"
      failedWith classify (userError "boom") `shouldReturn` String "OSError"

    it "quotes unknown levels like Python's repr" $ do
      levelFromEnv Nothing `shouldBe` Right Facts
      levelFromEnv (Just "profile") `shouldBe` Right Profile
      parseLevel "it's" `shouldBe` Left "unknown telemetry level \"it's\": one of off, facts, profile, debug"
      parseLevel "a\"b'" `shouldBe` Left "unknown telemetry level 'a\"b\\'': one of off, facts, profile, debug"
      parseLevel "\233\n\0\x200b"
        `shouldBe` Left "unknown telemetry level '\233\\n\\x00\\u200b': one of off, facts, profile, debug"

    it "statm parsing refuses malformed contents" $ do
      statmRssMb 4096 "300000" `shouldBe` Nothing
      statmRssMb 4096 "300000 abc" `shouldBe` Nothing
      statmRssMb 4096 "\xff\xfe 1" `shouldBe` Nothing
