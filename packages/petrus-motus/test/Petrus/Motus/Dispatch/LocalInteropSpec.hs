-- | Local Dispatch interop with the pinned reference: both implementations
-- share one SQLite file, so each direction of publish -> claim/complete ->
-- collect crosses the language boundary, a deterministic provider-clock
-- scenario writes identical rows and telemetry in both, a v1 file migrates
-- to identical rows, schema initialization and claim contention mix
-- reference processes with Haskell threads, and the reference's
-- @SqliteHistoryStore@ co-resides untouched.
--
-- Runs @test/interop/local_interop.py@ under @upstream/petrus/.venv@, provisioned
-- by @scripts/upstream-python@ on first use; the examples fail, never skip,
-- when that environment cannot be provisioned.
module Petrus.Motus.Dispatch.LocalInteropSpec (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM, forM_, void)
import Data.IORef
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.SQLite3 (SQLData (..))
import Petrus.Activity
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch
import Petrus.Motus.Dispatch.Local
  ( LocalDispatchOptions (..)
  , LocalWorkerOptions (..)
  , defaultLocalDispatchOptions
  , defaultLocalWorkerOptions
  )
import Petrus.Motus.Dispatch.Local qualified as Local
import Petrus.Motus.Dispatch.LocalSupport
import Petrus.Telemetry (capture, recorded)
import System.Directory (copyFile)
import System.FilePath ((</>))
import Test.Hspec
import Petrus.TestSupport (valid)

-- | The script's @work(value, attempts=2)@.
work :: Integer -> ActivityInvocation
work value = callWith "work" 2 30 (Int value) id

-- | The script's @outcome_json@.
outcomeJson :: ActivityOutcome -> Json
outcomeJson = \case
  Succeeded value -> Object [("completed", value)]
  Failed f ->
    let fields = failureFields f
     in Object
          [ ( "failed"
            , Object
                [ ("error", String fields.failureError)
                , ("kind", String fields.failureKind)
                , ("details", fields.failureDetails)
                , ("retryable", Bool fields.failureRetryable)
                , ("retry_after", maybe Null numberJson fields.failureRetryAfter)
                ]
            )
          ]

outcomesJson :: [(Int, ActivityOutcome)] -> Json
outcomesJson outcomes = Array [Array [Int (toInteger occurrence), outcomeJson outcome] | (occurrence, outcome) <- outcomes]

-- | The script's @attempt_json@.
attemptJson :: ActivityAttempt -> Json
attemptJson attempt =
  Object
    [ ("attempt_id", String attempt.attemptId)
    , ("epoch", String attempt.epoch)
    , ("claimant", String attempt.claimant)
    , ("queue", String attempt.queue)
    , ("instance", maybe Null String attempt.instance')
    , ("latest_details", attempt.latestDetails)
    , ("activity", String attempt.invocation.activity)
    , ("input", attempt.invocation.input)
    , ("correlation", maybe Null String attempt.invocation.correlation)
    , ("idempotency", maybe Null String attempt.invocation.idempotency)
    , ("attempts", Int (policyFields attempt.invocation.policy).attempts)
    ]

-- | The script's @scenario_invocation@.
scenarioInvocation :: Text -> Json -> Integer -> (ExecutionPolicyFields -> ExecutionPolicyFields) -> ActivityInvocation
scenarioInvocation name value attempts' tweak =
  valid . activityInvocation $
    ActivityInvocationFields
      { activity = name
      , input = Object [("value", value), ("label", String "ünïcode ✓")]
      , policy =
          either (error . T.unpack) id (executionPolicy (tweak (policyFields defaultExecutionPolicy) {attempts = attempts', heartbeatTimeout = 30}))
      , correlation = Just ("corr-" <> name)
      , idempotency = Nothing
      }

-- | The Haskell twin of the script's @scenario PATH@, step for step.
scenario :: FilePath -> IO Json
scenario path = do
  (source, at) <- manualClock 1000
  dispatch <-
    openScratchDispatch
      path
      "interop"
      defaultLocalDispatchOptions {defaultQueue = "general", activityQueues = [("cpu_work", "cpu")], clock = Just source}
  w1 <- Local.workerWith dispatch defaultLocalWorkerOptions {workerQueues = ["general", "cpu"], explicitClaimant = Just "w1"}
  w2 <- Local.workerWith dispatch defaultLocalWorkerOptions {workerQueues = ["cpu", "general"], explicitClaimant = Just "w2"}
  let one = scenarioInvocation "work" (Int 1) 2 (\p -> p {initialInterval = 1})
      two = scenarioInvocation "work" (Object [("z", String "café"), ("a", Float 1.5)]) 1 id
      three = scenarioInvocation "cpu_work" (Int 3) 3 (\p -> p {startToClose = Just (FloatNumber 0.25), scheduleToClose = Just 10})
      four = scenarioInvocation "work" (Int 4) 2 id
      five = scenarioInvocation "work" (Int 5) 1 id
      six = scenarioInvocation "work" (Int 6) 1 (\p -> p {scheduleToClose = Just 1})
      okResult = Object [("ok", Bool True), ("note", String "é"), ("n", Float 2.0)]
  results <- newIORef []
  let push value = modifyIORef results (value :)
  events <- capture Nothing Nothing $ \recorder -> do
    forM_ [(1, one), (2, two), (3, three), (4, four), (5, five)] $ uncurry (Local.dispatch dispatch)
    a1 <- requireClaim w1
    Local.fail
      w1
      a1
      (FailureClassified (failure (ActivityFailureFields "later" "Unavailable" (Object [("b", Int 1), ("a", Int 2)]) True (Just (FloatNumber 0.5)))))
    a2 <- requireClaim w1
    Local.heartbeat w1 a2 (Just (Object [("z", Int 1), ("a", Array [Int 1, Int 2])])) >>= push
    Local.heartbeat w1 a2 Nothing >>= push
    Local.complete w1 a2 okResult
    Local.complete w1 a2 okResult
    a3 <- requireClaim w1
    Local.fail w1 a3 (FailureMessage "broken")
    Local.cancel dispatch (instruction 4 four 9) >>= push . String . dispositionText
    Local.dispatch dispatch 4 four
    requireClaim w1 >>= push . attemptJson
    writeIORef at 1300
    a3c <- requireClaim w2
    push (attemptJson a3c)
    Local.complete w2 a3c (String "third time")
    requireClaim w2 >>= push . attemptJson
    writeIORef at 40000
    Local.wait w2 0 >>= push . Bool
    a1b <- requireClaim w1
    push (attemptJson a1b)
    Local.complete w1 a1b (Array [Int 1, String "two", Null])
    Local.collect dispatch >>= push . outcomesJson
    Local.cancel dispatch (instruction 2 two 10) >>= push . String . dispositionText
    Local.dispatch dispatch 6 six
    writeIORef at 42000
    Local.claim w1 >>= push . maybe Null attemptJson
    Local.collect dispatch >>= push . outcomesJson
    Local.collect dispatch >>= push . outcomesJson
    -- A refused heartbeat's exception (the reference's ValueError),
    -- reported as the exception itself, is stored as its repr and class.
    Local.dispatch dispatch 7 (scenarioInvocation "work" (Int 7) 1 id)
    a7 <- requireClaim w1
    try (Local.heartbeat w1 a7 (Just (Object [("x", Float (0 / 0))]))) >>= \case
      Left (refused :: SomeException) -> Local.fail w1 a7 (FailureException refused)
      Right _ -> expectationFailure "non-finite heartbeat details were accepted"
    Local.collect dispatch >>= push . outcomesJson
    recorded recorder
  pushed <- reverse <$> readIORef results
  pure (Object [("events", Array (map Object events)), ("results", Array pushed)])

-- | Claim and complete everything claimable in @default@, as the script's
-- @work@ does; answer the claimed occurrences.
workAll :: FilePath -> Text -> IO [Integer]
workAll path who = do
  custody <- fixedWorker path who
  let loop acc =
        Local.claim custody >>= \case
          Nothing -> pure (reverse acc)
          Just attempt -> do
            let value = case attempt.invocation.input of
                  Object members | Just v <- lookup "value" members -> v
                  _ -> Null
            Local.complete custody attempt (Object [("by", String who), ("value", value)])
            loop (occurrenceOf attempt.attemptId : acc)
  loop []

occurrenceOf :: Text -> Integer
occurrenceOf attemptId = case parsedJson (TE.encodeUtf8 attemptId) of
  Array [_, Int occurrence] -> occurrence
  other -> error ("unexpected attempt id " <> show other)

completedBy :: Text -> Integer -> Json
completedBy who count =
  Array [Array [Int i, Object [("completed", Object [("by", String who), ("value", Int i)])]] | i <- [1 .. count]]

spec :: Spec
spec = describe "Local Dispatch interop with the reference" $ do
  it "the reference publishes, a Haskell worker claims and completes, the reference collects" $ withReference $ \python -> withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
    void (runPython python ["publish", path, "one", "5"])
    workAll path "haskell" `shouldReturn` [1 .. 5]
    parsedJson <$> runPython python ["collect", path, "one", "5"] `shouldReturn` completedBy "haskell" 5

  it "Haskell publishes, a reference worker claims and completes, Haskell collects" $ withReference $ \python -> withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
    published <- openScratchDispatch path "one" defaultLocalDispatchOptions
    forM_ [1 .. 5] $ \i -> Local.dispatch published i (work (toInteger i))
    claimed <- parsedJson <$> runPython python ["work", path, "python"]
    claimed
      `shouldBe` Array
        [ Object
            [ ("attempt_id", String ("[\"one\"," <> T.pack (show i) <> "]"))
            , ("epoch", String "1")
            , ("claimant", String "python")
            , ("queue", String "default")
            , ("instance", String "one")
            , ("latest_details", Null)
            , ("activity", String "work")
            , ("input", Object [("value", Int i)])
            , ("correlation", String "correlation")
            , ("idempotency", String "idempotency")
            , ("attempts", Int 2)
            ]
        | i <- [1 .. 5 :: Integer]
        ]
    fresh <- openScratchDispatch path "one" defaultLocalDispatchOptions
    forM_ [1 .. 5] $ \i -> Local.dispatch fresh i (work (toInteger i))
    outcomesJson <$> Local.collect fresh `shouldReturn` completedBy "python" 5

  it "the provider-clock scenario yields identical telemetry, results, and rows in both implementations" $ withReference $ \python -> withScratch $ \dir -> do
    let reference = dir </> "reference.db"
        ours = dir </> "haskell.db"
    expected <- parsedJson <$> runPython python ["scenario", reference]
    scenario ours `shouldReturn` expected
    referenceRows <- runPython python ["dump", reference]
    runPython python ["dump", ours] `shouldReturn` referenceRows

  it "a v1 file migrates to identical rows in both implementations" $ withReference $ \python -> withScratch $ \dir -> do
    let reference = dir </> "reference.db"
        ours = dir </> "haskell.db"
    writeV1 reference "100000"
    copyFile reference ours
    void (runPython python ["migrate", reference])
    (source, _) <- manualClock 5000
    void (openScratchDispatch ours "one" defaultLocalDispatchOptions {clock = Just source})
    referenceRows <- runPython python ["dump", reference]
    runPython python ["dump", ours] `shouldReturn` referenceRows

  it "a file Haskell created and the reference opens (and the converse) have identical schema rows" $ withReference $ \python -> withScratch $ \dir -> do
    let reference = dir </> "reference.db"
        ours = dir </> "haskell.db"
    void (runPython python ["open", reference, "one"])
    void (openScratchDispatch ours "one" defaultLocalDispatchOptions)
    referenceRows <- runPython python ["dump", reference]
    runPython python ["dump", ours] `shouldReturn` referenceRows
    -- Each validates the other's file as its own current version.
    void (runPython python ["open", ours, "two"])
    void (openScratchDispatch reference "two" defaultLocalDispatchOptions)

  it "schema initialization is atomic under mixed reference-process and Haskell-thread startup" $ withReference $ \python -> withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
        arguments n = ["open", path, "python-" <> show n]
    processes <- forM [0 :: Int .. 3] $ \n -> (,) (arguments n) <$> startPython python (arguments n)
    threads <- forM [0 :: Int .. 3] $ \n -> do
      done <- newEmptyMVar
      _ <- forkIO $ do
        outcome <- try (openScratchDispatch path ("haskell-" <> T.pack (show n)) defaultLocalDispatchOptions)
        putMVar done (either (\e -> Just (show (e :: SomeException))) (const Nothing) outcome)
      pure done
    forM_ processes $ \(args, started) -> finishPython args started
    mapM takeMVar threads `shouldReturn` replicate 4 Nothing
    void (openScratchDispatch path "reopened" defaultLocalDispatchOptions)
    rawScalar path "SELECT version FROM impetus_local_dispatch_schema" `shouldReturn` SQLInteger 3

  it "claim contention between reference processes and Haskell threads distributes distinct work once" $ withReference $ \python -> withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
    published <- openScratchDispatch path "one" defaultLocalDispatchOptions
    forM_ [1 .. 24] $ \i -> Local.dispatch published i (work (toInteger i))
    processes <- forM [0 :: Int .. 1] $ \n ->
      let args = ["work", path, "python-" <> show n] in (,) args <$> startPython python args
    threads <- forM [0 :: Int .. 1] $ \n -> do
      done <- newEmptyMVar
      _ <- forkIO (try (workAll path ("haskell-" <> T.pack (show n))) >>= putMVar done)
      pure done
    fromPython <- forM processes $ \(args, started) ->
      finishPython args started >>= \bytes -> case parsedJson bytes of
        Array claimed -> pure [occurrenceOf attemptId | Object members <- claimed, Just (String attemptId) <- [lookup "attempt_id" members]]
        other -> expectationFailure ("unexpected work output " <> show other) >> pure []
    fromHaskell <- forM threads $ \done -> takeMVar done >>= either (\e -> throwIO (e :: SomeException)) pure
    sort (concat fromPython <> concat fromHaskell) `shouldBe` [1 .. 24]
    outcomes <- Local.collect published
    map fst outcomes `shouldMatchList` [1 .. 24]

  it "sqlite history tables coexist untouched" $ withReference $ \python -> withScratch $ \dir -> do
    -- The reference's SqliteHistoryStore owns the History tables; the
    -- Haskell Local Dispatch shares the file and leaves them untouched.
    let path = dir </> "application.db"
    void (runPython python ["history-write", path])
    shared <- openScratchDispatch path "one" defaultLocalDispatchOptions
    Local.dispatch shared 1 call
    parsedJson <$> runPython python ["history-check", path]
      `shouldReturn` Object
        [ ("records_match", Bool True)
        , ("names", Array [String "impetus_history_events", String "impetus_local_dispatch_tasks"])
        ]
