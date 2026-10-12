-- | Absurd Dispatch interop with the pinned reference: both languages pin
-- the same Absurd release and accept each other's provisioned schema; a
-- Haskell and a reference authority write the same task rows, idempotency
-- keys and doorbells; reference workers execute Haskell-dispatched tasks
-- and Haskell workers execute reference-dispatched ones, with heartbeat
-- details, classified failures, retries and cancellation fences crossing
-- the language boundary; and a crash on either side — an authority that
-- never collected, a worker killed mid-lease — is recovered by the other.
--
-- Runs @test/interop/absurd_dispatch_interop.py@ under the pinned
-- @upstream/petrus/.venv@ (provisioned by @scripts/upstream-python@; a
-- missing reference fails, never skips); pending without @PETRUS_TEST_POSTGRES@.
module Petrus.Motus.Dispatch.Absurd.InteropSpec (spec) where

import Control.Exception (finally, toException)
import Control.Monad (forM_, void)
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Petrus.Activity hiding (ActivityExecutionContext (..))
import Prelude hiding (fail)
import Petrus.Json (Json (..), defaultDumps, dumps, lookupMember)
import Petrus.Motus.Dispatch (ActivityOutcome (..), AttemptFailure (..), CancellationDisposition (..), DispatchError (..), cancellationInstruction)
import Petrus.Motus.Dispatch qualified as Port
import Petrus.Motus.Dispatch.Absurd
import Petrus.Motus.Dispatch.Absurd.Driver
import Petrus.Motus.Dispatch.Absurd.Support
import Petrus.Postgres (Connection, textParam)
import Petrus.Postgres qualified as Pg
import Petrus.TestSupport (PostgresTarget (..), withScratchDatabase)
import Test.Hspec hiding (after, before, pending)
import Petrus.TestSupport (valid)

script :: FilePath
script = "test/interop/absurd_dispatch_interop.py"

py :: [String] -> IO Json
py = runDriverJson script

dsnArg :: PostgresTarget -> String
dsnArg = BC.unpack . targetUrl

wireOf :: ActivityInvocation -> String
wireOf = BC.unpack . either (error . show) id . dumps defaultDumps . encodeInvocation

jsonArg :: Json -> String
jsonArg = BC.unpack . either (error . show) id . dumps defaultDumps

member :: Text -> Json -> Json
member key = maybe Null id . lookupMember key

str :: Json -> Text
str = \case
  String s -> s
  other -> T.pack (show other)

classified :: Text -> Text -> Json -> Bool -> Maybe Number -> ActivityFailure
classified message kind details retryable retryAfter =
  either (error . T.unpack) id (activityFailure (ActivityFailureFields message kind details retryable retryAfter))

-- | The reference's printed failure object for a failure.
failureObject :: ActivityFailure -> Json
failureObject failure =
  let f = failureFields failure
   in Object
        [ ("error", String f.failureError)
        , ("kind", String f.failureKind)
        , ("details", f.failureDetails)
        , ("retryable", Bool f.failureRetryable)
        , ("retry_after", maybe Null numberJson f.failureRetryAfter)
        ]

withWorker :: PostgresTarget -> Text -> (AbsurdWorkerDispatch -> IO a) -> IO a
withWorker target queue action = do
  w <- openAbsurdWorkerDispatch (dsnOf target) defaultAbsurdWorkerOptions {queues = [queue], workerId = Just "haskell-worker"}
  action w `finally` close w

claimWithin :: AbsurdWorkerDispatch -> Double -> IO Port.ActivityAttempt
claimWithin w seconds = do
  deadline <- (+ seconds) <$> getMonotonicTime
  let loop =
        claim w >>= \case
          Just attempt -> pure attempt
          Nothing -> do
            now <- getMonotonicTime
            if now > deadline then expectationFailure "nothing claimable" >> error "unreachable" else void (wait w 0.1) >> loop
  loop

policyWith :: Integer -> Integer -> ExecutionPolicy
policyWith attempts heartbeat' =
  either (error . T.unpack) id (executionPolicy (policyFields defaultExecutionPolicy) {attempts, heartbeatTimeout = heartbeat'})

spec :: Spec
spec = describe "interop with the pinned reference" $ do
  it "pins the same Absurd release, vendored bytes, channels and checkpoint name" $ do
    pin <- py ["pin"]
    member "version" pin `shouldBe` String absurdVersion
    member "commit" pin `shouldBe` String absurdCommit
    member "sha256" pin `shouldBe` String absurdSqlSha256
    member "vendored_sha256" pin `shouldBe` String absurdSqlSha256
    member "dispatch_channel" pin `shouldBe` String dispatchChannel
    member "results_channel" pin `shouldBe` String resultsChannel
    member "details_checkpoint" pin `shouldBe` String detailsCheckpoint

  it "decodes the same publication keys and task payloads (and refuses the same ones)" $ do
    forM_ [String ":occurrence-1", String "instance:occurrence-0", String "instance:occurrence-01", String "tenant:occurrence-segment:occurrence-17", String "foreign-task-key", String "", Null] $ \key -> do
      reference <- py ["key-instance", jsonArg key]
      let ours = instanceFromKey (case key of String s -> Just s; _ -> Nothing)
      case ours of
        Right found -> member "instance" reference `shouldBe` maybe Null String found
        Left refusal -> member "error" reference `shouldBe` String refusal
    let good = encodeInvocation (valid (invocation "check_issue" (String "goose")))
        replaced key value = case good of
          Object ms -> Object [(k, if k == key then value else v) | (k, v) <- ms]
          other -> other
    forM_
      [ good
      , replaced "policy" (Object [("attempts", Int 3), ("heartbeat_timeout", Int 7)])
      , replaced "policy" (Object [("attempts", Int 0), ("heartbeat_timeout", Int 7)])
      , replaced "policy" (Object [("attempts", Bool True)])
      , replaced "correlation" (Int 7)
      , replaced "activity" (String "")
      , Object [("task", String "nope")]
      ]
      $ \payload -> do
        reference <- py ["decode", jsonArg payload]
        case decodeInvocation payload of
          Right decoded -> member "wire" reference `shouldBe` encodeInvocation decoded
          Left refusal -> member "error" reference `shouldBe` String refusal

  postgresSpec' $ do
    it "accepts each other's provisioned schema, with identical catalogs" $ \target ->
      withScratchDatabase target.adminUrl $ \byReference ->
        withScratchDatabase target.adminUrl $ \byHaskell -> do
          provisioned <- py ["ensure", dsnArg byReference]
          member "version" provisioned `shouldBe` String absurdVersion
          withConn byReference True ensureAbsurdSchema
          withConn byHaskell True ensureAbsurdSchema
          accepted <- py ["ensure", dsnArg byHaskell]
          member "version" accepted `shouldBe` String absurdVersion
          let catalog c =
                rowsOf
                  c
                  "SELECT p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', md5(p.prosrc) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'absurd' ORDER BY 1, 2"
                  []
          left <- withConn byReference True catalog
          right <- withConn byHaskell True catalog
          length left `shouldSatisfy` (> 20)
          left `shouldBe` right

  absurdSpec $ do
    it "writes the same task rows, idempotency keys and dispatch doorbells" $ \target ->
      withObserver target $ \observer -> withObserver target $ \listener -> do
        queue <- freshQueue
        ours <- freshName "hs-"
        theirs <- freshName "py-"
        inv <- invocationFor 3 (Object [("k", Array [Int 1, Float 2.5, String "é"])])
        Pg.listen listener dispatchChannel
        withAuthority target $ \authority -> do
          adapter <- absurdDispatch authority ours defaultAbsurdDispatchOptions {defaultQueue = queue}
          publish adapter authority 1 inv
        void (py ["dispatch", dsnArg target, T.unpack theirs, T.unpack queue, "1", wireOf inv])
        notes <- mapM (const (Pg.waitForNotification listener 5)) [1 :: Int, 2]
        map (fmap (\n -> (Pg.notificationChannel n, Pg.notificationPayload n))) notes
          `shouldBe` replicate 2 (Just (dispatchChannel, queue))
        let row instanceId =
              rowsOf
                observer
                ( Pg.sql
                    ( "SELECT task_name, params::text, headers::text, retry_strategy::text, max_attempts, cancellation::text, state, attempts, "
                        <> "replace(idempotency_key, %s, '<instance>') FROM absurd.t_"
                        <> queue
                        <> " WHERE idempotency_key = %s"
                    )
                )
                [textParam instanceId, textParam (publicationKey instanceId 1)]
            runRow instanceId =
              rowsOf
                observer
                ( Pg.sql
                    ( "SELECT r.attempt, r.state, r.claimed_by, r.result::text, r.failure_reason::text FROM absurd.r_"
                        <> queue
                        <> " r JOIN absurd.t_"
                        <> queue
                        <> " t USING (task_id) WHERE t.idempotency_key = %s"
                    )
                )
                [textParam (publicationKey instanceId 1)]
        hs <- row ours
        pyRows <- row theirs
        length hs `shouldBe` 1
        hs `shouldBe` pyRows
        (,) <$> runRow ours <*> runRow theirs >>= \(a, b) -> a `shouldBe` b

    it "a Haskell worker executes a reference-dispatched task; the reference collects its result" $ \target -> do
      queue <- freshQueue
      instanceId <- freshName "py-authority-"
      inv <- invocationFor 1 (String "from python")
      void (py ["dispatch", dsnArg target, T.unpack instanceId, T.unpack queue, "1", wireOf inv])
      withWorker target queue $ \w -> do
        attempt <- claimWithin w 10
        attempt.invocation `shouldBe` inv
        attempt.instance' `shouldBe` Just instanceId
        attempt.latestDetails `shouldBe` Null
        heartbeat w attempt (Just (Object [("cursor", Int 3)])) `shouldReturn` Object [("cursor", Int 3)]
        complete w attempt (Object [("echo", String "from haskell")])
      collected <- py ["collect", dsnArg target, T.unpack instanceId, T.unpack queue, "1", wireOf inv, "5"]
      member "ready" collected `shouldBe` Bool True
      member "outcomes" collected `shouldBe` Array [Object [("occurrence", Int 1), ("result", Object [("echo", String "from haskell")])]]

    it "a reference worker executes a Haskell-dispatched task; Haskell collects, woken by its results doorbell" $ \target ->
      withAuthority target $ \authority -> withObserver target $ \listen' -> do
        queue <- freshQueue
        instanceId <- freshName "hs-authority-"
        inv <- invocationFor 1 (String "from haskell")
        adapter <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = queue, listen = Just listen', pollInterval = 30}
        publish adapter authority 1 inv
        waitForResults adapter 0 `shouldReturn` False -- LISTEN is now in place
        report <- py ["work", dsnArg target, T.unpack queue, "complete:" <> jsonArg (Object [("echo", String "from python")]), jsonArg (Object [("cursor", Int 9)])]
        let attempt = member "attempt" report
        member "instance" attempt `shouldBe` String instanceId
        member "invocation" attempt `shouldBe` encodeInvocation inv
        member "heartbeat" report `shouldBe` Object [("cursor", Int 9)]
        started <- getMonotonicTime
        waitForResults adapter 10 `shouldReturn` True
        elapsed <- subtract started <$> getMonotonicTime
        elapsed `shouldSatisfy` (< 5) -- the doorbell, not the 30 s poll
        collect adapter `shouldReturn` [(1, Succeeded (Object [("echo", String "from python")]))]

    it "classified and exception failures cross both ways with the same failure_reason rows" $ \target ->
      withObserver target $ \observer -> do
        queue <- freshQueue
        let failure = classified "invalid" "InvalidRequest" (Object [("field", String "name")]) False (Just (IntNumber 9))
            policy = policyWith 4 30
        pyAuthority <- freshName "py-fail-"
        let inv = valid (activityInvocation (defaultInvocationFields "probe_activity" Null) {policy})
        void (py ["dispatch", dsnArg target, T.unpack pyAuthority, T.unpack queue, "1", wireOf inv])
        withWorker target queue $ \w -> do
          attempt <- claimWithin w 10
          fail w attempt (FailureClassified failure)
        fromReference <- py ["collect", dsnArg target, T.unpack pyAuthority, T.unpack queue, "1", wireOf inv, "5"]
        member "outcomes" fromReference `shouldBe` Array [Object [("occurrence", Int 1), ("failure", failureObject failure)]]
        withAuthority target $ \authority -> do
          hsAuthority <- freshName "hs-fail-"
          adapter <- absurdDispatch authority hsAuthority defaultAbsurdDispatchOptions {defaultQueue = queue}
          publish adapter authority 1 inv
          void (py ["work", dsnArg target, T.unpack queue, "fail-classified:" <> jsonArg (failureObject failure)])
          waitForResults adapter 5 `shouldReturn` True
          collect adapter `shouldReturn` [(1, Failed failure)]
          let reasons instanceId =
                rowsOf
                  observer
                  (Pg.sql ("SELECT r.failure_reason::text, r.state, t.state, t.max_attempts FROM absurd.r_" <> queue <> " r JOIN absurd.t_" <> queue <> " t USING (task_id) WHERE t.idempotency_key = %s"))
                  [textParam (publicationKey instanceId 1)]
          left <- reasons pyAuthority
          right <- reasons hsAuthority
          left `shouldBe` right
          -- An exception from a reference Activity: retryable, named by its type.
          exceptionAuthority <- freshName "hs-exc-"
          once <- invocationFor 1 Null
          other <- absurdDispatch authority exceptionAuthority defaultAbsurdDispatchOptions {defaultQueue = queue}
          publish other authority 1 once
          void (py ["work", dsnArg target, T.unpack queue, "fail-exception:boom requested"])
          waitForResults other 5 `shouldReturn` True
          collect other `shouldReturn` [(1, Failed (classified "boom requested" "ValueError" Null True Nothing))]
          -- The same exception from a Haskell Activity (a DispatchError is the
          -- reference's ValueError) writes the same failure_reason row.
          haskellExceptionAuthority <- freshName "hs-exc-hs-"
          third <- absurdDispatch authority haskellExceptionAuthority defaultAbsurdDispatchOptions {defaultQueue = queue}
          publish third authority 1 once
          withWorker target queue $ \w -> do
            attempt <- claimWithin w 10
            fail w attempt (FailureException (toException (DispatchError "boom requested")))
          waitForResults third 5 `shouldReturn` True
          collect third `shouldReturn` [(1, Failed (classified "boom requested" "ValueError" Null True Nothing))]
          haskellReasons <- reasons haskellExceptionAuthority
          referenceReasons <- reasons exceptionAuthority
          haskellReasons `shouldBe` referenceReasons

    it "a retry crosses languages: the next attempt sees the other side's latest details" $ \target ->
      withAuthority target $ \authority -> do
        queue <- freshQueue
        instanceId <- freshName "retry-"
        let inv = valid (activityInvocation (defaultInvocationFields "probe_activity" (String "twice")) {policy = policyWith 2 30})
        adapter <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = queue}
        publish adapter authority 1 inv
        withWorker target queue $ \w -> do
          attempt <- claimWithin w 10
          void (heartbeat w attempt (Just (Object [("cursor", Int 1)])))
          fail w attempt (FailureClassified (classified "transient" "Unavailable" Null True (Just (IntNumber 0))))
        collect adapter `shouldReturn` []
        report <- py ["work", dsnArg target, T.unpack queue, "complete:" <> jsonArg (String "second time"), jsonArg (Object [("cursor", Int 2)])]
        member "latest_details" (member "attempt" report) `shouldBe` Object [("cursor", Int 1)]
        waitForResults adapter 5 `shouldReturn` True
        collect adapter `shouldReturn` [(1, Succeeded (String "second time"))]
        -- And the reverse: the reference fails first, a Haskell worker retries.
        reverseId <- freshName "retry-rev-"
        second <- absurdDispatch authority reverseId defaultAbsurdDispatchOptions {defaultQueue = queue}
        publish second authority 1 inv
        void (py ["work", dsnArg target, T.unpack queue, "fail-exception:first try", jsonArg (Object [("cursor", Int 5)])])
        withWorker target queue $ \w -> do
          attempt <- claimWithin w 10
          attempt.latestDetails `shouldBe` Object [("cursor", Int 5)]
          complete w attempt (String "haskell retry")
        waitForResults second 5 `shouldReturn` True
        collect second `shouldReturn` [(1, Succeeded (String "haskell retry"))]

    it "cancellation fences cross languages both ways" $ \target ->
      withAuthority target $ \authority -> do
        queue <- freshQueue
        -- Reference authority cancels a Haskell worker's claimed Attempt.
        pyAuthority <- freshName "py-cancel-"
        inv <- invocationFor 1 (String "fenced")
        void (py ["dispatch", dsnArg target, T.unpack pyAuthority, T.unpack queue, "1", wireOf inv])
        withWorker target queue $ \w -> do
          attempt <- claimWithin w 10
          py ["cancel", dsnArg target, T.unpack pyAuthority, T.unpack queue, "1", wireOf inv, "11"] `shouldReturn` String "fenced"
          heartbeat w attempt Nothing `shouldThrow` runtimeMatching ["stale Activity Attempt"]
          complete w attempt (String "late") `shouldThrow` runtimeMatching ["stale Activity Attempt"]
        -- Haskell authority cancels a reference worker's claimed Attempt.
        hsAuthority <- freshName "hs-cancel-"
        adapter <- absurdDispatch authority hsAuthority defaultAbsurdDispatchOptions {defaultQueue = queue}
        publish adapter authority 1 inv
        withDriver script ["hold", dsnArg target, T.unpack queue] $ \holder -> do
          held <- receiveJson holder
          member "instance" held `shouldBe` String hsAuthority
          sendLine holder ("heartbeat " <> BC.pack (jsonArg (Object [("cursor", Int 1)])))
          receiveJson holder `shouldReturn` Object [("ok", Object [("cursor", Int 1)])]
          let instruction = either (error . T.unpack) id (cancellationInstruction 1 inv 12)
          cancel adapter instruction `shouldReturn` Fenced
          Pg.commit authority
          sendLine holder "heartbeat {}"
          refused <- receiveJson holder
          member "error" refused `shouldBe` String "RuntimeError"
          str (member "message" refused) `shouldSatisfy` T.isInfixOf "stale Activity Attempt"
          sendLine holder "complete \"late\""
          member "error" <$> receiveJson holder `shouldReturn` String "RuntimeError"
          sendLine holder "close"
        -- A pending task tombstoned by one side is acknowledged by the other.
        pendingId <- freshName "tomb-"
        pending' <- absurdDispatch authority pendingId defaultAbsurdDispatchOptions {defaultQueue = queue}
        publish pending' authority 1 inv
        py ["cancel", dsnArg target, T.unpack pendingId, T.unpack queue, "1", wireOf inv, "13"] `shouldReturn` String "retired"
        repaired <- absurdDispatch authority pendingId defaultAbsurdDispatchOptions {defaultQueue = queue}
        cancel repaired (either (error . T.unpack) id (cancellationInstruction 1 inv 13)) `shouldReturn` Acknowledged
        Pg.commit authority

    it "an authority crash is recovered across languages, lookup-first, without double enqueue" $ \target ->
      withAuthority target $ \authority -> withObserver target $ \observer -> do
        queue <- freshQueue
        -- The reference dispatches and exits without collecting; a Haskell
        -- authority resumes the same Instance and redispatches.
        instanceId <- freshName "crash-py-"
        inv <- invocationFor 1 (String "resume me")
        [String _, String pyTask] <- (\case Array xs -> xs; _ -> []) <$> py ["dispatch", dsnArg target, T.unpack instanceId, T.unpack queue, "1", wireOf inv]
        resumed <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = queue}
        publish resumed authority 1 inv
        fmap snd <$> dispatchedTask resumed 1 `shouldReturn` Just pyTask
        scalar observer (Pg.sql ("SELECT count(*) FROM absurd.t_" <> queue <> " WHERE idempotency_key = %s")) [textParam (publicationKey instanceId 1)]
          `shouldReturn` Just "1"
        void (py ["work", dsnArg target, T.unpack queue, "complete:" <> jsonArg (String "resumed")])
        waitForResults resumed 5 `shouldReturn` True
        collect resumed `shouldReturn` [(1, Succeeded (String "resumed"))]
        -- Haskell dispatches on an old route and "crashes"; the reference
        -- resumes on a new route and moves the never-started custody.
        old <- freshName "old_"
        new <- freshName "new_"
        moved <- freshName "crash-hs-"
        first' <- absurdDispatch authority moved defaultAbsurdDispatchOptions {defaultQueue = old}
        publish first' authority 1 inv
        transfer <- py ["collect", dsnArg target, T.unpack moved, T.unpack new, "1", wireOf inv, "0"]
        member "ready" transfer `shouldBe` Bool False
        (\case Array (q : _) -> q; other -> other) (member "task" transfer) `shouldBe` String new
        stateRows <- mapM (\q -> scalar observer (Pg.sql ("SELECT state FROM absurd." <> Pg.quoteIdentifier ("t_" <> q) <> " WHERE idempotency_key = %s")) [textParam (publicationKey moved 1)]) [old, new]
        stateRows `shouldBe` [Just "cancelled", Just "pending"]
        -- A Haskell authority resuming on the new route keeps that custody.
        again <- absurdDispatch authority moved defaultAbsurdDispatchOptions {defaultQueue = new}
        publish again authority 1 inv
        fmap fst <$> dispatchedTask again 1 `shouldReturn` Just new

    it "a worker killed mid-lease is recovered by the other language with its latest details" $ \target ->
      withAuthority target $ \authority -> do
        queue <- freshQueue
        let inv = valid (activityInvocation (defaultInvocationFields "probe_activity" (String "crash")) {policy = policyWith 3 1})
        -- A reference worker is SIGKILLed after a heartbeat; a Haskell worker
        -- reclaims once the lease lapses.
        killed <- freshName "kill-py-"
        a <- absurdDispatch authority killed defaultAbsurdDispatchOptions {defaultQueue = queue}
        publish a authority 1 inv
        withDriver script ["hold", dsnArg target, T.unpack queue] $ \holder -> do
          void (receiveJson holder)
          sendLine holder ("heartbeat " <> BC.pack (jsonArg (Object [("cursor", Int 41)])))
          void (receiveJson holder)
          killHard holder
        withWorker target queue $ \w -> do
          attempt <- claimWithin w 15
          attempt.instance' `shouldBe` Just killed
          attempt.latestDetails `shouldBe` Object [("cursor", Int 41)]
          complete w attempt (String "after python crash")
        waitForResults a 5 `shouldReturn` True
        collect a `shouldReturn` [(1, Succeeded (String "after python crash"))]
        -- A Haskell worker abandons its lease (its connection closes without
        -- a terminal report); a reference worker reclaims it.
        abandoned <- freshName "kill-hs-"
        b <- absurdDispatch authority abandoned defaultAbsurdDispatchOptions {defaultQueue = queue}
        publish b authority 1 inv
        withWorker target queue $ \w -> do
          attempt <- claimWithin w 10
          void (heartbeat w attempt (Just (Object [("cursor", Int 42)])))
        report <- py ["work", dsnArg target, T.unpack queue, "complete:" <> jsonArg (String "after haskell crash")]
        member "latest_details" (member "attempt" report) `shouldBe` Object [("cursor", Int 42)]
        waitForResults b 5 `shouldReturn` True
        collect b `shouldReturn` [(1, Succeeded (String "after haskell crash"))]
  where
    postgresSpec' = absurdSpec

_unusedConnection :: Maybe Connection
_unusedConnection = Nothing

_unusedText :: Text -> Text
_unusedText = TE.decodeUtf8 . TE.encodeUtf8
