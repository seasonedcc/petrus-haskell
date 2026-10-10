-- | Port of @tests/petrus/motus/dispatch/test_local_dispatch.py@ (the
-- Engine-level tests live in @petrus-engine@'s LocalDispatchSpec; the
-- SQLite History co-residence test runs against the reference's
-- @SqliteHistoryStore@ in LocalInteropSpec), plus the telemetry events.
module Petrus.Motus.Dispatch.LocalSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (Exception (..), SomeException, throwIO, try)
import Control.Monad (forM, forM_, replicateM, void)
import Data.IORef
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite3 (SQLData (..), SQLError)
import Petrus.Activity
import Petrus.Json (Json (..), parseJson, pythonLoads)
import Petrus.Motus.Dispatch
import Petrus.Motus.Dispatch.Local (LocalDispatchClock (..), LocalDispatchOptions (..), defaultLocalDispatchOptions, openLocalDispatch)
import Petrus.Motus.Dispatch.Local qualified as Local
import Petrus.Motus.Dispatch.LocalSupport
import Petrus.Telemetry (capture, recorded)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Test.Hspec
import Data.Text.Encoding qualified as TE

open :: FilePath -> Text -> IO Local.LocalDispatch
open path inst = openLocalDispatch path inst defaultLocalDispatchOptions

openWith :: FilePath -> Text -> (LocalDispatchOptions -> LocalDispatchOptions) -> IO Local.LocalDispatch
openWith path inst tweak = openLocalDispatch path inst (tweak defaultLocalDispatchOptions)

completed :: Json -> ActivityOutcome
completed = Succeeded

activityFailureOf :: Text -> ActivityOutcome
activityFailureOf message = Failed (failure (ActivityFailureFields message "ActivityError" Null False Nothing))

kindOf :: ActivityOutcome -> Maybe Text
kindOf = \case
  Failed f -> Just (failureFields f).failureKind
  Succeeded _ -> Nothing

-- | @replace(attempt, ...)@ helpers.
withQueue :: Text -> ActivityAttempt -> ActivityAttempt
withQueue q a = attemptWith a.attemptId a.epoch a.claimant q a.invocation a.latestDetails a.instance'

withInvocation :: ActivityInvocation -> ActivityAttempt -> ActivityAttempt
withInvocation inv a = attemptWith a.attemptId a.epoch a.claimant a.queue inv a.latestDetails a.instance'

withClaimant :: Text -> ActivityAttempt -> ActivityAttempt
withClaimant c a = attemptWith a.attemptId a.epoch c a.queue a.invocation a.latestDetails a.instance'

withEpoch :: Text -> ActivityAttempt -> ActivityAttempt
withEpoch e a = attemptWith a.attemptId e a.claimant a.queue a.invocation a.latestDetails a.instance'

retryableFailure :: Text -> Text -> Json -> Maybe Number -> ActivityFailure
retryableFailure message kind details delay = failure (ActivityFailureFields message kind details True delay)

parsed :: Text -> Json
parsed = either error id . parseJson pythonLoads . TE.encodeUtf8

spec :: Spec
spec = do
  it "schema reopens and refuses unsupported or unversioned shape" $ withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
    d <- open path "one"
    isCancellable (Local.toDispatch d) `shouldBe` True
    _ <- open path "two"
    rawExec path "UPDATE impetus_local_dispatch_schema SET version=99"
    open path "one"
      `shouldThrow` refusal (T.pack path <> ": unsupported Local Dispatch schema [('dispatch', 99)]; migration is not supported")
    let unversioned = dir </> "old.db"
    rawExec unversioned "CREATE TABLE impetus_local_dispatch_tasks(value)"
    open unversioned "one"
      `shouldThrow` refusal (T.pack unversioned <> ": foreign or unversioned Local Dispatch schema; migration is not supported")

  it "schema initialization is atomic under spawned process startup" $ withScratch $ \dir -> do
    -- Eight concurrent openers on separate connections (threads here; the
    -- interop suite mixes reference processes in).
    let path = dir </> "dispatch.db"
    gate <- newEmptyMVar
    results <- forM [0 :: Int .. 7] $ \number -> do
      done <- newEmptyMVar
      _ <- forkIO $ do
        readMVar gate
        outcome <- try (open path ("instance-" <> T.pack (show number)))
        putMVar done (either (\e -> Just (show (e :: SomeException))) (const Nothing) outcome)
      pure done
    putMVar gate ()
    mapM takeMVar results `shouldReturn` replicate 8 Nothing
    void (open path "reopened")

  it "v1 schema migrates pending active and terminal custody without losing fences" $ withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
    writeV1 path "unixepoch('now')*1000+30000"
    d <- open path "one"
    Local.dispatch d 1 call
    Local.dispatch d 2 call
    Local.dispatch d 3 call
    let activeAttempt = attemptWith "[\"one\",2]" "1" "active" "default" call (obj [("progress", Int 1)]) (Just "one")
    activeWorker <- fixedWorker path "active"
    Local.heartbeat activeWorker activeAttempt Nothing `shouldReturn` obj [("progress", Int 1)]
    Local.collect d `shouldReturn` [(3, activityFailureOf "broken")]
    let done = attemptWith "[\"one\",3]" "1" "done" "default" call Null (Just "one")
    doneWorker <- fixedWorker path "done"
    Local.fail doneWorker done (FailureMessage "broken")
    rawScalar path "SELECT version FROM impetus_local_dispatch_schema" `shouldReturn` SQLInteger 3
    SQLText stored <- rawScalar path "SELECT invocation FROM impetus_local_dispatch_tasks WHERE occurrence=1"
    case parsed stored of
      Object members | Just (Object policy) <- lookup "policy" members ->
        sort (map fst policy)
          `shouldBe` sort ["attempts", "heartbeat_timeout", "initial_interval", "coefficient", "max_interval", "jitter", "start_to_close", "schedule_to_close"]
      other -> expectationFailure ("unexpected invocation " <> show other)

  it "v2 schema migrates to durable cancellation tombstones" $ withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
    d <- open path "one"
    Local.dispatch d 1 call
    rawExec path "DROP TABLE impetus_local_dispatch_cancellations"
    rawExec path "UPDATE impetus_local_dispatch_schema SET version=2"
    resumed <- open path "one"
    Local.cancel resumed (instruction 1 call 17) `shouldReturn` Retired
    (fixedWorker path "worker" >>= Local.claim) `shouldReturn` Nothing
    rawScalar path "SELECT version FROM impetus_local_dispatch_schema" `shouldReturn` SQLInteger 3
    rawQuery path "SELECT occurrence,history_position FROM impetus_local_dispatch_cancellations" []
      `shouldReturn` [[SQLInteger 1, SQLInteger 17]]

  it "pending and absent cancellation are durable idempotent tombstones" $ withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
    d <- open path "one"
    Local.dispatch d 1 call
    let pendingFence = instruction 1 call 11
        absent = instruction 2 call 12
    Local.cancel d pendingFence `shouldReturn` Retired
    Local.cancel d absent `shouldReturn` Tombstoned
    Local.cancel d pendingFence `shouldReturn` Acknowledged
    -- Recovery publication cannot resurrect either exact logical invocation.
    open path "one" >>= \r -> Local.dispatch r 1 call
    open path "one" >>= \r -> Local.dispatch r 2 call
    (fixedWorker path "worker" >>= Local.claim) `shouldReturn` Nothing
    Local.cancel d (instruction 1 call 99) `shouldThrow` refusal "Local Dispatch cancellation conflict for occurrence 1"

  it "claimed cancellation fences heartbeat and transports exact late terminal" $ withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
    d <- open path "one"
    Local.dispatch d 1 call
    custody <- fixedWorker path "worker"
    attempt <- requireClaim custody
    Local.cancel d (instruction 1 call 11) `shouldReturn` Fenced
    Local.heartbeat custody attempt Nothing `shouldThrow` refusal "stale Activity attempt [\"one\",1]"
    let late = obj [("effect", String "may-have-happened")]
    Local.complete custody attempt late
    Local.complete custody attempt late
    Local.complete custody attempt (obj [("effect", String "different")])
      `shouldThrow` refusal "conflicting terminal report for Activity attempt [\"one\",1]"
    Local.collect d `shouldReturn` [(1, completed late)]
    (fixedWorker path "other" >>= Local.claim) `shouldReturn` Nothing

  it "running cancellation fences future custody and reports ambiguous effect for quarantine" $ withScratch $ \dir -> do
    -- The reference drives a real Worker thread (run_available(limit=1));
    -- Workers are not ported yet, so the thread performs the same
    -- claim -> run -> complete custody sequence over dispatch.worker().
    let path = dir </> "dispatch.db"
    d <- open path "one"
    Local.dispatch d 1 call
    entered <- newEmptyMVar
    release <- newEmptyMVar
    finished <- newEmptyMVar
    custody <- Local.worker d ["default"] (Just "worker")
    _ <- forkIO $ do
      outcome <- try $ do
        attempt <- requireClaim custody
        putMVar entered ()
        takeMVar release
        Local.complete custody attempt (obj [("effect", String "may-have-happened")])
      putMVar finished (outcome :: Either SomeException ())
    takeMVar entered
    Local.cancel d (instruction 1 call 11) `shouldReturn` Fenced
    putMVar release ()
    takeMVar finished >>= either throwIO pure
    Local.collect d `shouldReturn` [(1, completed (obj [("effect", String "may-have-happened")]))]
    (fixedWorker path "other" >>= Local.claim) `shouldReturn` Nothing

  it "terminal before cancellation is reported as terminal not erased" $ withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
    d <- open path "one"
    Local.dispatch d 1 call
    custody <- fixedWorker path "worker"
    requireClaim custody >>= \a -> Local.complete custody a (obj [("done", Bool True)])
    Local.cancel d (instruction 1 call 11) `shouldReturn` Terminal
    Local.collect d `shouldReturn` [(1, completed (obj [("done", Bool True)]))]

  it "current version foreign shape and invalid custody states are refused" $ withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
    _ <- open path "one"
    rawExec path "INSERT INTO impetus_local_dispatch_tasks(instance,occurrence,queue,invocation,epoch) VALUES('x',1,'q','{}',1)"
      `shouldThrow` (\(_ :: SQLError) -> True)
    rawExec path "DROP INDEX impetus_local_dispatch_claimable"
    rawExec path "CREATE INDEX impetus_local_dispatch_claimable ON impetus_local_dispatch_tasks(sequence)"
    open path "one" `shouldThrow` refusal (T.pack path <> ": foreign current-version Local Dispatch DDL shape")

  it "routes and instances share domain but claim by queue" $ withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
    one <- openWith path "one" (\o -> o {defaultQueue = "general", activityQueues = [("work", "cpu")]})
    two <- openWith path "two" (\o -> o {defaultQueue = "general"})
    Local.dispatch one 1 call
    Local.dispatch two 1 (callWith "other" 2 30 (Int 1) id)
    cpu <- fixedWorkerOn path ["cpu"] "worker-cpu"
    general <- fixedWorkerOn path ["general"] "worker-general"
    ((.instance') <$> requireClaim cpu) `shouldReturn` Just "one"
    ((.instance') <$> requireClaim general) `shouldReturn` Just "two"
    Local.claim cpu `shouldReturn` Nothing

  it "keeps connections open between operations until the session or an independent worker closes" $ withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
        wal = path <> "-wal"
    session <- openLocalDispatch path "one" defaultLocalDispatchOptions
    Local.dispatch session 1 call
    borrowing <- Local.worker session ["default"] (Just "worker")
    attempt <- requireClaim borrowing
    Local.complete borrowing attempt (Int 1)
    -- A worker constructed from the session borrows its connections.
    Local.close borrowing
    doesFileExist wal `shouldReturn` True
    independent <- fixedWorker path "solo"
    Local.claim independent `shouldReturn` Nothing
    Local.close independent
    doesFileExist wal `shouldReturn` True
    -- The session's connections were the last ones open: closing them
    -- checkpointed the WAL and removed it.
    Local.closeLocalDispatch session
    doesFileExist wal `shouldReturn` False
    -- Both stay usable, each later operation on a connection of its own.
    (map fst <$> Local.collect session) `shouldReturn` [1]
    Local.claim borrowing `shouldReturn` Nothing
    doesFileExist wal `shouldReturn` False

  it "exact publication route recovery and live route preservation" $ withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
        trueValue = callWith "work" 2 30 (Bool True) id
    first <- openWith path "one" (\o -> o {defaultQueue = "a"})
    Local.dispatch first 1 trueValue
    moved <- openWith path "one" (\o -> o {defaultQueue = "b"})
    Local.dispatch moved 1 trueValue
    attempt <- fixedWorkerOn path ["b"] "worker" >>= requireClaim
    attempt.queue `shouldBe` "b"
    openWith path "one" (\o -> o {defaultQueue = "c"}) >>= \c -> Local.dispatch c 1 trueValue
    (fixedWorkerOn path ["c"] "other" >>= Local.claim) `shouldReturn` Nothing
    -- JSON true and 1 are exact conflicts.
    Local.dispatch moved 1 (callWith "work" 2 30 (Int 1) id)
      `shouldThrow` refusal "Local Dispatch publication conflict for occurrence 1"

  it "expired retryable route moves and terminal collection ignores current route" $ withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
    original <- openWith path "one" (\o -> o {defaultQueue = "a"})
    Local.dispatch original 1 call
    first <- fixedWorkerOn path ["a"] "old" >>= requireClaim
    rawExec path "UPDATE impetus_local_dispatch_tasks SET deadline=unixepoch('now') * 1000 WHERE instance='one'"
    moved <- openWith path "one" (\o -> o {defaultQueue = "b"})
    Local.dispatch moved 1 call
    newCustody <- fixedWorkerOn path ["b"] "new"
    second <- requireClaim newCustody
    second.epoch `shouldBe` T.pack (show (read (T.unpack first.epoch) + 1 :: Int))
    Local.complete newCustody second (String "done")
    openWith path "one" (\o -> o {defaultQueue = "c"}) >>= \c -> Local.dispatch c 1 call
    Local.collect moved `shouldReturn` [(1, completed (String "done"))]

  it "heartbeat details are detached and omitted preserves but none replaces" $ withScratch $ \dir -> do
    d <- open (dir </> "dispatch.db") "one"
    Local.dispatch d 1 call
    custody <- fixedWorker d.path "worker"
    attempt <- requireClaim custody
    -- Haskell values are immutable: the reference's mutation after the call
    -- has no analogue, so detachment holds by construction.
    replaced <- Local.heartbeat custody attempt (Just (obj [("at", Array [Int 1])]))
    preserved <- Local.heartbeat custody attempt Nothing
    replaced `shouldBe` obj [("at", Array [Int 1])]
    preserved `shouldBe` obj [("at", Array [Int 1])]
    Local.heartbeat custody attempt (Just Null) `shouldReturn` Null

  it "heartbeat refuses detached queue or policy tampering without renewing lease" $ withScratch $ \dir -> do
    d <- open (dir </> "dispatch.db") "one"
    Local.dispatch d 1 (callWith "work" 2 1 (Int 1) id)
    custody <- fixedWorker d.path "worker"
    attempt <- requireClaim custody
    originalDeadline <- rawScalar d.path "SELECT deadline FROM impetus_local_dispatch_tasks"
    let tamperedPolicy =
          either (error . T.unpack) id (executionPolicy (policyFields defaultExecutionPolicy) {attempts = 2, heartbeatTimeout = 3600})
    forM_ [withQueue "other" attempt, withInvocation attempt.invocation {policy = tamperedPolicy} attempt] $ \tampered ->
      Local.heartbeat custody tampered Nothing `shouldThrow` refusal "stale Activity attempt [\"one\",1]"
    rawScalar d.path "SELECT deadline FROM impetus_local_dispatch_tasks" `shouldReturn` originalDeadline

  it "one second lease survives the next wall clock second boundary" $ withScratch $ \dir -> do
    let waitForLateSecond = do
          now <- getPOSIXTime
          let fraction = realToFrac now - fromInteger (floor now) :: Double
          if fraction < 0.85 then threadDelay 10000 >> waitForLateSecond else pure ()
    waitForLateSecond
    d <- open (dir </> "dispatch.db") "one"
    Local.dispatch d 1 (callWith "work" 2 1 (Int 1) id)
    custody <- fixedWorker d.path "worker"
    attempt <- requireClaim custody
    threadDelay 200000
    Local.heartbeat custody attempt Nothing `shouldReturn` Null

  it "heartbeat renews without a hard attempt deadline" $ withScratch $ \dir -> do
    d <- open (dir </> "dispatch.db") "one"
    Local.dispatch d 1 (callWith "work" 2 1 (Int 1) id)
    custody <- fixedWorker d.path "worker"
    attempt <- requireClaim custody
    [[SQLInteger original, hard]] <- rawQuery d.path "SELECT deadline,attempt_deadline FROM impetus_local_dispatch_tasks" []
    threadDelay 20000
    _ <- Local.heartbeat custody attempt Nothing
    SQLInteger renewed <- rawScalar d.path "SELECT deadline FROM impetus_local_dispatch_tasks"
    hard `shouldBe` SQLNull
    renewed `shouldSatisfy` (> original)

  it "subsecond deadlines and retry delays round up from millisecond clock" $ withScratch $ \dir -> do
    d <- open (dir </> "dispatch.db") "one"
    Local.dispatch d 1 (callWith "work" 2 30 (Int 1) (\p -> p {startToClose = Just (FloatNumber 0.0001), scheduleToClose = Just (FloatNumber 1.0001)}))
    custody <- fixedWorker d.path "worker"
    _ <- requireClaim custody
    [[scheduleStart, availableAt, SQLInteger attemptStart, SQLInteger attemptDeadline]] <-
      rawQuery d.path "SELECT schedule_start,available_at,attempt_start,attempt_deadline FROM impetus_local_dispatch_tasks" []
    scheduleStart `shouldBe` availableAt
    attemptDeadline `shouldBe` attemptStart + 1

    retryDispatch <- open (dir </> "retry.db") "one"
    Local.dispatch retryDispatch 2 (callWith "work" 2 30 (Int 1) (\p -> p {initialInterval = FloatNumber 0.0001}))
    retryCustody <- fixedWorker retryDispatch.path "worker"
    retry <- requireClaim retryCustody
    Local.fail retryCustody retry (FailureClassified (retryableFailure "later" "ActivityError" Null Nothing))
    [[SQLInteger deadline, SQLInteger available]] <-
      rawQuery retryDispatch.path "SELECT deadline,available_at FROM impetus_local_dispatch_tasks WHERE occurrence=2" []
    available `shouldBe` deadline + 1

  it "oversized heartbeat details are rejected before persistence" $ withScratch $ \dir -> do
    d <- open (dir </> "dispatch.db") "one"
    Local.dispatch d 1 call
    custody <- fixedWorker d.path "worker"
    attempt <- requireClaim custody
    Local.heartbeat custody attempt (Just (String (T.replicate 65536 "x")))
      `shouldThrow` refusal "heartbeat details encode to 65538 UTF-8 bytes; limit is 65536"
    Local.heartbeat custody attempt (Just (obj [("still", String "usable")])) `shouldReturn` obj [("still", String "usable")]

  it "failure retries then terminal success is exact and session redelivers" $ withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
    d <- open path "one"
    Local.dispatch d 1 call
    custody <- fixedWorker path "worker"
    first <- requireClaim custody
    Local.fail custody first (FailureMessage "transient")
    second <- requireClaim custody
    second.epoch `shouldBe` "2"
    let result = obj [("tuple canonicalizes", Array [Int 1, Bool True, Null])]
    Local.complete custody second result
    Local.collect d `shouldReturn` [(1, completed result)]
    Local.collect d `shouldReturn` []
    restarted <- open path "one"
    Local.collect restarted `shouldReturn` []
    Local.dispatch restarted 1 call
    Local.collect restarted `shouldReturn` [(1, completed result)]

  it "two retryable failures then success keep one logical invocation" $ withScratch $ \dir -> do
    d <- open (dir </> "dispatch.db") "one"
    let inv = callWith "work" 3 30 (Int 1) id
    Local.dispatch d 1 inv
    custody <- fixedWorker d.path "worker"
    attempts' <- forM [1 :: Integer, 2] $ \number -> do
      attempt <- requireClaim custody
      Local.fail
        custody
        attempt
        (FailureClassified (retryableFailure ("transient-" <> T.pack (show number)) "Unavailable" (obj [("attempt", Int number)]) Nothing))
      pure attempt
    final <- requireClaim custody
    Local.complete custody final (String "done")
    let all' = attempts' <> [final]
    map (.epoch) all' `shouldBe` ["1", "2", "3"]
    all (\a -> a.invocation == inv) all' `shouldBe` True
    map (\a -> (a.invocation.correlation, a.invocation.idempotency)) all'
      `shouldSatisfy` all (== (Just "correlation", Just "idempotency"))
    Local.collect d `shouldReturn` [(1, completed (String "done"))]

  it "delayed retry schedule survives restart under the provider clock" $ withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
    (source, at) <- manualClock 1000
    d <- openWith path "one" (\o -> o {clock = Just source})
    let inv = callWith "work" 2 30 (Int 1) (\p -> p {initialInterval = 60})
    Local.dispatch d 1 inv
    firstWorker <- clockedWorker path "first" source
    a <- requireClaim firstWorker
    Local.fail firstWorker a (FailureClassified (retryableFailure "later" "Unavailable" Null (Just 30)))
    restarted <- openWith path "one" (\o -> o {clock = Just source})
    Local.dispatch restarted 1 inv
    replacement <- clockedWorker path "replacement" source
    Local.claim replacement `shouldReturn` Nothing
    writeIORef at 60999
    Local.claim replacement `shouldReturn` Nothing
    writeIORef at 61000
    ((.epoch) <$> requireClaim replacement) `shouldReturn` "2"

  describe "provider clock refuses non integer negative and out of range values" $ do
    forM_ [("-1", -1), ("2**63", 2 ^ (63 :: Int))] $ \(label, value) ->
      it ("[" <> label <> "]") $ withScratch $ \dir -> do
        d <- openWith (dir </> "dispatch.db") "one" (\o -> o {clock = Just (LocalDispatchClock (pure value))})
        Local.dispatch d 1 call
          `shouldThrow` refusal "Local Dispatch clock must return a nonnegative signed-64-bit millisecond integer"
    -- [True], [1.5] and ["1"] are values a 'LocalDispatchClock' (IO Integer)
    -- cannot produce: enforced by the types.

  it "dispatch worker shares provider clock monotonicity guard" $ withScratch $ \dir -> do
    (source, at) <- manualClock 1000
    d <- openWith (dir </> "dispatch.db") "one" (\o -> o {clock = Just source})
    Local.dispatch d 1 call
    w <- Local.worker d ["default"] (Just "worker")
    attempt <- requireClaim w
    writeIORef at 999
    Local.heartbeat w attempt Nothing `shouldThrow` refusal "Local Dispatch clock must not rewind"

  it "nonretryable failure terminalizes without spending remaining attempts" $ withScratch $ \dir -> do
    d <- open (dir </> "dispatch.db") "one"
    Local.dispatch d 1 (callWith "work" 5 30 (Int 1) id)
    custody <- fixedWorker d.path "worker"
    let invalid = failure (ActivityFailureFields "invalid" "InvalidRequest" (obj [("field", String "name")]) False Nothing)
    requireClaim custody >>= \a -> Local.fail custody a (FailureClassified invalid)
    Local.claim custody `shouldReturn` Nothing
    Local.collect d `shouldReturn` [(1, Failed invalid)]

  it "schedule to close can expire before first claim" $ withScratch $ \dir -> do
    d <- open (dir </> "dispatch.db") "one"
    Local.dispatch d 1 (callWith "work" 3 30 (Int 1) (\p -> p {scheduleToClose = Just 10}))
    rawExec d.path "UPDATE impetus_local_dispatch_tasks SET schedule_start=0"
    (fixedWorker d.path "worker" >>= Local.claim) `shouldReturn` Nothing
    [(occurrence, outcome)] <- Local.collect d
    occurrence `shouldBe` 1
    kindOf outcome `shouldBe` Just "DeadlineExceeded"

  it "start to close deadline fences the attempt and terminalizes when exhausted" $ withScratch $ \dir -> do
    d <- open (dir </> "dispatch.db") "one"
    Local.dispatch d 1 (callWith "work" 1 30 (Int 1) (\p -> p {startToClose = Just 10}))
    custody <- fixedWorker d.path "worker"
    attempt <- requireClaim custody
    rawExec d.path "UPDATE impetus_local_dispatch_tasks SET deadline=0,attempt_deadline=0 WHERE instance='one'"
    Local.heartbeat custody attempt Nothing `shouldThrow` refusal "stale Activity attempt [\"one\",1]"
    Local.claim custody `shouldReturn` Nothing
    [(occurrence, outcome)] <- Local.collect d
    occurrence `shouldBe` 1
    kindOf outcome `shouldBe` Just "DeadlineExceeded"
    outcome `shouldBe` Failed (failure (ActivityFailureFields "Local Dispatch deadline exhausted after 1 attempt" "DeadlineExceeded" Null False Nothing))

  describe "exact terminal report retry acknowledges and conflict is refused" $ do
    let cases :: [(String, Local.LocalWorkerDispatch -> ActivityAttempt -> Bool -> IO ())]
        cases =
          [ ("complete", \w a conflict -> Local.complete w a (obj [("ok", Bool (not conflict))]))
          , ("fail", \w a conflict -> Local.fail w a (FailureMessage (if conflict then "other" else "broken")))
          ]
    forM_ cases $ \(label, report) ->
      it ("[" <> label <> "]") $ withScratch $ \dir -> do
        d <- open (dir </> "dispatch.db") "one"
        Local.dispatch d 1 (callWith "work" 1 30 (Int 1) id)
        custody <- fixedWorker d.path "worker"
        attempt <- requireClaim custody
        let conflicting = refusal "conflicting terminal report for Activity attempt [\"one\",1]"
        report custody attempt False
        report custody attempt False
        report custody attempt True `shouldThrow` conflicting
        report custody (withClaimant "other" attempt) False `shouldThrow` conflicting
        report custody (withEpoch "2" attempt) False `shouldThrow` conflicting

  it "final activity failure and expired final attempt are durable" $ withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
    d <- open path "one"
    Local.dispatch d 1 (callWith "work" 1 30 (Int 1) id)
    custody <- fixedWorker path "worker"
    requireClaim custody >>= \a -> Local.fail custody a (FailureMessage "broken")
    Local.collect d `shouldReturn` [(1, activityFailureOf "broken")]

    other <- open path "two"
    Local.dispatch other 1 (callWith "work" 1 30 (Int 1) id)
    expired <- fixedWorker path "old" >>= requireClaim
    rawExec path "UPDATE impetus_local_dispatch_tasks SET deadline=unixepoch('now') * 1000 WHERE instance='two'"
    (fixedWorker path "poller" >>= Local.claim) `shouldReturn` Nothing
    [(occurrence, outcome)] <- Local.collect other
    occurrence `shouldBe` 1
    kindOf outcome `shouldBe` Just "DeadlineExceeded"
    Local.complete custody expired (String "late")
      `shouldThrow` refusal "conflicting terminal report for Activity attempt [\"two\",1]"

  it "corrupt durable invocation is refused contextually" $ withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
    d <- open path "one"
    Local.dispatch d 1 call
    void $
      rawQuery
        path
        "UPDATE impetus_local_dispatch_tasks SET invocation=?"
        [SQLText "{\"activity\":\"work\",\"input\":null,\"policy\":{\"attempts\":true,\"heartbeat_timeout\":30},\"correlation\":null,\"idempotency\":null}"]
    (fixedWorker path "worker" >>= Local.claim)
      `shouldThrow` refusal "corrupt durable Activity invocation: policy fields must be integers"

  it "spawned claim contention distributes distinct work once" $ withScratch $ \dir -> do
    -- Four concurrent claimers on separate connections (threads here; the
    -- interop suite mixes reference processes in).
    let path = dir </> "dispatch.db"
    d <- open path "one"
    forM_ [1 .. 24] $ \occurrence -> Local.dispatch d occurrence (callWith "work" 2 30 (Int (toInteger occurrence)) id)
    gate <- newEmptyMVar
    results <- forM [0 :: Int .. 3] $ \number -> do
      done <- newEmptyMVar
      _ <- forkIO $ do
        readMVar gate
        outcome <- try $ do
          let who = "worker-" <> T.pack (show number)
          custody <- fixedWorker path who
          let loop acc =
                Local.claim custody >>= \case
                  Nothing -> pure (reverse acc)
                  Just attempt -> do
                    Local.complete custody attempt (String who)
                    loop (attempt.attemptId : acc)
          loop []
        putMVar done (outcome :: Either SomeException [Text])
      pure done
    putMVar gate ()
    distributions <- mapM (\m -> takeMVar m >>= either throwIO pure) results
    let occurrences = [T.unpack (T.dropEnd 1 (T.drop 7 aid)) | aid <- concat distributions]
    sort (map read occurrences :: [Int]) `shouldBe` [1 .. 24]

  it "stale operations are fenced after reassignment and heartbeat preserves details" $ withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
    d <- open path "one"
    Local.dispatch d 1 (callWith "work" 2 1 (Int 1) id)
    oldCustody <- fixedWorker path "old"
    old <- requireClaim oldCustody
    Local.heartbeat oldCustody old (Just (obj [("progress", Int 3)])) `shouldReturn` obj [("progress", Int 3)]
    (fixedWorker path "early" >>= Local.claim) `shouldReturn` Nothing
    rawExec path "UPDATE impetus_local_dispatch_tasks SET deadline=unixepoch('now') * 1000 WHERE instance='one'"
    replacementCustody <- fixedWorker path "replacement"
    replacement <- requireClaim replacementCustody
    replacement.latestDetails `shouldBe` obj [("progress", Int 3)]
    let staleRefusal = refusal "stale Activity attempt [\"one\",1]"
    void (Local.heartbeat oldCustody old Nothing) `shouldThrow` staleRefusal
    Local.complete oldCustody old (String "late") `shouldThrow` staleRefusal
    Local.fail oldCustody old (FailureMessage "late") `shouldThrow` staleRefusal

  it "wait terminalizes exhausted row then settles" $ withScratch $ \dir -> do
    d <- open (dir </> "dispatch.db") "one"
    Local.dispatch d 1 (callWith "work" 1 30 (Int 1) id)
    _ <- fixedWorker d.path "old" >>= requireClaim
    rawExec d.path "UPDATE impetus_local_dispatch_tasks SET deadline=unixepoch('now') * 1000"
    custody <- fixedWorker d.path "waiter"
    Local.wait custody 0 `shouldReturn` False
    Local.wait custody 0 `shouldReturn` False
    [(_, outcome)] <- Local.collect d
    kindOf outcome `shouldBe` Just "DeadlineExceeded"

  describe "beyond upstream" $ do
    it "refuses invalid names, occurrences, queues and timeouts with the reference's messages" $ withScratch $ \dir -> do
      let path = dir </> "n.db"
      open path "" `shouldThrow` refusal "Local Dispatch instance must be a non-empty string without NUL"
      openWith path "x" (\o -> o {defaultQueue = "a\NULb"}) `shouldThrow` refusal "Local Dispatch queue must be a non-empty string without NUL"
      openWith path "x" (\o -> o {activityQueues = [("", "q")]}) `shouldThrow` refusal "Local Dispatch activity must be a non-empty string without NUL"
      fixedWorkerOn path [] "w" `shouldThrow` refusal "Local Worker Dispatch requires at least one queue"
      Local.openLocalWorkerDispatch path Local.defaultLocalWorkerOptions {Local.workerId = Just ""}
        `shouldThrow` refusal "Local Dispatch worker label must be a non-empty string without NUL"
      d <- open path "x"
      Local.dispatch d 0 call `shouldThrow` refusal "Local Dispatch occurrence must be a positive integer"
      Local.waitForResults d (-1) `shouldThrow` refusal "wait timeout must be a non-negative number"
      (fixedWorker path "w" >>= \w -> Local.wait w (-0.5)) `shouldThrow` refusal "wait timeout must be a non-negative number"
      (source, _) <- manualClock 0
      Local.workerWith d Local.defaultLocalWorkerOptions {Local.workerClock = Just source} >>= \w -> w.claimant `shouldSatisfy` T.isPrefixOf "worker:"
      clocked <- openWith path "x" (\o -> o {clock = Just source})
      Local.workerWith clocked Local.defaultLocalWorkerOptions {Local.workerClock = Just source}
        `shouldThrow` refusal "Local Worker Dispatch accepts either clock or its dispatch clock reader"

    it "refuses the reference's other corrupt invocation shapes with its messages" $ withScratch $ \dir -> do
      let path = dir </> "dispatch.db"
          corrupt = "corrupt durable Activity invocation: "
      d <- open path "one"
      Local.dispatch d 1 call
      forM_
        [ ("{\"activity\":\"\",\"input\":null,\"policy\":{\"attempts\":1,\"heartbeat_timeout\":30},\"correlation\":null,\"idempotency\":null}", "ActivityInvocation requires a non-empty string activity name, got ''")
        , ("{\"activity\":\"w\",\"input\":null,\"policy\":{\"attempts\":1,\"heartbeat_timeout\":30,\"initial_interval\":\"x\",\"coefficient\":2,\"max_interval\":60,\"jitter\":0,\"start_to_close\":null,\"schedule_to_close\":null},\"correlation\":null,\"idempotency\":null}", "RetryPolicy initial_interval must be a non-negative number")
        , ("{\"activity\":\"w\",\"input\":null,\"policy\":{\"attempts\":1,\"heartbeat_timeout\":30},\"correlation\":null}", "expected exact fields ['activity', 'correlation', 'idempotency', 'input', 'policy']")
        , ("{\"activity\":\"w\",\"input\":null,\"policy\":{\"attempts\":1},\"correlation\":null,\"idempotency\":null}", "policy expected exact legacy or current fields")
        , ("{\"activity\":\"w\",\"input\":null,\"policy\":{\"attempts\":1,\"heartbeat_timeout\":30},\"correlation\":\"\",\"idempotency\":null}", "ActivityInvocation correlation must be a non-empty string, or None for the writer to derive at begin, got ''")
        ]
        $ \(stored, message) -> do
          void $ rawQuery path "UPDATE impetus_local_dispatch_tasks SET invocation=?" [SQLText stored]
          (fixedWorker path "worker" >>= Local.claim) `shouldThrow` refusal (corrupt <> message)

    it "refuses a non-faithful result and an invalid failure before touching custody" $ withScratch $ \dir -> do
      d <- open (dir </> "dispatch.db") "one"
      Local.dispatch d 1 call
      custody <- fixedWorker d.path "worker"
      attempt <- requireClaim custody
      Local.complete custody attempt (Float (0 / 0))
        `shouldThrow` refusal "Activity result must be JSON-faithful: Out of range float values are not JSON compliant: nan"
      Local.complete custody attempt (Int (10 ^ (4300 :: Int)))
        `shouldThrow` refusal "Activity result must be JSON-faithful: Exceeds the limit (4300 digits) for integer string conversion; use sys.set_int_max_str_digits() to increase the limit"
      Local.fail custody attempt (FailureMessage "")
        `shouldThrow` refusal "ActivityFailure error must be a non-empty string of at most 4096 characters"
      Local.heartbeat custody attempt Nothing `shouldReturn` Null

    it "a caught exception fails retryably, spelled as its repr" $ withScratch $ \dir -> do
      d <- open (dir </> "dispatch.db") "one"
      Local.dispatch d 1 (callWith "work" 1 30 (Int 1) id)
      custody <- fixedWorker d.path "worker"
      attempt <- requireClaim custody
      Local.fail custody attempt (FailureException (toException (ValueError "it's")))
      Local.collect d
        `shouldReturn` [(1, Failed (failure (ActivityFailureFields "ValueError(\"it's\")" "ValueError" Null True Nothing)))]

    it "wait reports claimable work and waitForResults reports a collectable terminal" $ withScratch $ \dir -> do
      d <- open (dir </> "dispatch.db") "one"
      custody <- fixedWorker d.path "worker"
      Local.wait custody 0 `shouldReturn` False
      Local.waitForResults d 0 `shouldReturn` False
      Local.dispatch d 1 call
      Local.wait custody 0.2 `shouldReturn` True
      attempt <- requireClaim custody
      Local.waitForResults d 0 `shouldReturn` False
      Local.complete custody attempt (String "ok")
      Local.waitForResults d 0.2 `shouldReturn` True
      _ <- Local.collect d
      Local.waitForResults d 0 `shouldReturn` False

    it "the WorkerDispatch surface drives the same custody" $ withScratch $ \dir -> do
      d <- open (dir </> "dispatch.db") "one"
      Local.dispatch d 1 call
      surface <- Local.toWorkerDispatch <$> fixedWorker d.path "worker"
      Just attempt <- surface.claim
      surface.heartbeat attempt (Just (Int 1)) `shouldReturn` Int 1
      surface.complete attempt (String "ok")
      surface.close
      (Local.toDispatch d).collect `shouldReturn` [(1, completed (String "ok"))]

    it "emits the reference's telemetry events, fields and field order" $ withScratch $ \dir -> do
      let path = dir </> "dispatch.db"
      events <- capture Nothing Nothing $ \recorder -> do
        d <- open path "one"
        Local.dispatch d 1 (callWith "work" 1 30 (Int 1) id)
        Local.dispatch d 2 call
        custody <- fixedWorker path "worker"
        first <- requireClaim custody
        _ <- Local.heartbeat custody first Nothing
        Local.fail custody first (FailureMessage "broken")
        second <- requireClaim custody
        Local.complete custody second (String "ok")
        Local.complete custody second (String "ok")
        _ <- Local.cancel d (instruction 3 call 4)
        _ <- Local.collect d
        recorded recorder
      let attemptFields occurrence epoch extra =
            [ ("instance", String "one")
            , ("occurrence", Int occurrence)
            , ("attempt", String ("[\"one\"," <> T.pack (show occurrence) <> "]"))
            , ("epoch", String epoch)
            , ("claimant", String "worker")
            , ("queue", String "default")
            , ("activity", String "work")
            ]
              <> extra
      events
        `shouldBe` [ [("event", String "impetus_dispatch_published"), ("instance", String "one"), ("occurrence", Int 1), ("queue", String "default"), ("activity", String "work")]
                   , [("event", String "impetus_dispatch_published"), ("instance", String "one"), ("occurrence", Int 2), ("queue", String "default"), ("activity", String "work")]
                   , ("event", String "impetus_dispatch_claimed") : attemptFields 1 "1" []
                   , ("event", String "impetus_dispatch_heartbeat") : attemptFields 1 "1" []
                   , ("event", String "impetus_dispatch_failed") : attemptFields 1 "1" [("outcome", String "terminal")]
                   , ("event", String "impetus_dispatch_claimed") : attemptFields 2 "1" []
                   , ("event", String "impetus_dispatch_completed") : attemptFields 2 "1" [("outcome", String "terminal")]
                   , ("event", String "impetus_dispatch_completed") : attemptFields 2 "1" [("outcome", String "terminal-retry")]
                   , [("event", String "impetus_dispatch_cancelled"), ("instance", String "one"), ("occurrence", Int 3), ("history_position", Int 4), ("disposition", String "tombstoned")]
                   , [("event", String "impetus_dispatch_collected"), ("instance", String "one"), ("occurrence", Int 1), ("outcome", String "failed")]
                   , [("event", String "impetus_dispatch_collected"), ("instance", String "one"), ("occurrence", Int 2), ("outcome", String "completed")]
                   ]

    it "emits lease expiry with the integer epoch and the last claimant" $ withScratch $ \dir -> do
      let path = dir </> "dispatch.db"
      d <- open path "one"
      Local.dispatch d 1 (callWith "work" 1 30 (Int 1) id)
      _ <- fixedWorker path "old" >>= requireClaim
      rawExec path "UPDATE impetus_local_dispatch_tasks SET deadline=0"
      events <- capture Nothing Nothing $ \recorder -> do
        _ <- fixedWorker path "poller" >>= Local.claim
        recorded recorder
      events
        `shouldBe` [ [ ("event", String "impetus_dispatch_lease_expired")
                     , ("instance", String "one")
                     , ("occurrence", Int 1)
                     , ("attempt", String "[\"one\",1]")
                     , ("epoch", Int 1)
                     , ("claimant", String "old")
                     , ("outcome", String "failed")
                     ]
                   ]

    it "a generated claimant is the label and a version-4 UUID" $ withScratch $ \dir -> do
      d <- open (dir </> "dispatch.db") "one"
      claimants <- replicateM 3 ((.claimant) <$> Local.worker d ["default"] (Just "dst-worker"))
      forM_ claimants $ \c -> do
        let (label, uuid) = T.breakOn ":" c
        label `shouldBe` "dst-worker"
        T.length uuid `shouldBe` 37
        T.index uuid 15 `shouldBe` '4'
      length (sort claimants) `shouldBe` length claimants
      claimants `shouldSatisfy` (\cs -> length cs == length (foldr (\c acc -> if c `elem` acc then acc else c : acc) [] cs))

-- | A stand-in for the reference test's @ValueError@.
newtype ValueError = ValueError String deriving stock (Show)

instance Exception ValueError where
  displayException (ValueError message) = message
