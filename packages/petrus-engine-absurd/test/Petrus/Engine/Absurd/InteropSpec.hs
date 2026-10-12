-- | Absurd Engine interop with the pinned reference, on one scratch
-- database: the reference's @petrus.engine.absurd@ Engines (driven by
-- @test/interop/absurd_engine_interop.py@) and Haskell Engines take turns on
-- one Instance, with Workers of either language executing the Attempts.
--
-- * A reference Engine with a Haskell Worker, and a Haskell Engine with the
--   reference's Worker process.
-- * Authority crash recovery across languages: an Engine of one language
--   dispatches and dies after the commit; an Engine of the other resumes
--   lookup-first (one task across both lives), completes, and the first
--   language reads back the same History.
-- * Retries across languages: a Worker of one language is killed
--   mid-lease after its effect committed; a Worker of the other language
--   takes the retry after lease expiry, with exactly one effect.
-- * Cancellation across languages: an Engine of one language closes a
--   scope while a Worker of the other holds the claimed Attempt; the
--   Worker's terminal report is refused and the tombstone holds.
--
-- (The Engine-with-reference-Worker direction is also exercised by every
-- Worker-backed example of "Petrus.Engine.AbsurdSpec".) Pending without
-- @PETRUS_TEST_POSTGRES@.
module Petrus.Engine.Absurd.InteropSpec (spec) where

import Control.Exception (throwIO)
import Control.Monad (void)
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Engine qualified as Engine
import Petrus.Engine.Absurd.Helpers
import Petrus.Engine.Absurd.Support
import Petrus.Impetus.History.Codec (encodeRecord)
import Petrus.Impetus.History.Records (ActivityRequested (..))
import Petrus.Impetus.Instance (DeliveryScope (..), ScopeClosure (..), Status (..))
import Petrus.Json (Json (..), defaultDumps, dumpsText, lookupMember, parseJson, surrogateRefusingLoads)
import Petrus.Postgres (textParam)
import Petrus.TestSupport (PythonFailure (..), pythonExecutable, upstreamPetrus)
import System.Directory (makeAbsolute)
import System.Exit (ExitCode (..))
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Test.Hspec

script :: FilePath
script = "test/interop/absurd_engine_interop.py"

-- | Run one subcommand of the reference's driver under the pinned
-- environment (from the upstream root, isolated) and parse its one JSON
-- document; a non-zero exit raises 'PythonFailure' with both streams.
py :: Fixture -> String -> [String] -> IO Json
py fixture command arguments = do
  exe <- pythonExecutable
  root <- upstreamPetrus
  path <- makeAbsolute script
  (code, out, err) <- readCreateProcessWithExitCode (proc exe ("-I" : path : command : BC.unpack fixture.dsn : arguments)) {cwd = Just root} ""
  case code of
    ExitFailure n -> throwIO (PythonFailure (script <> " " <> command <> " exited " <> show n) (BC.pack out) (BC.pack err))
    ExitSuccess -> either (\problem -> throwIO (PythonFailure ("invalid JSON: " <> problem) (BC.pack out) (BC.pack err))) pure (parseJson surrogateRefusingLoads (BC.pack out))

jsonArg :: Json -> String
jsonArg value = either (error . show) T.unpack (dumpsText defaultDumps value)

issueJson :: Text -> [(Text, Json)] -> String
issueJson issueId extra = jsonArg (Object (("id", String issueId) : extra))

sparked :: Text -> Json
sparked issueId = Object [("id", String issueId), ("spark", String ("sparked " <> issueId))]

taskCount :: Fixture -> Text -> IO (Maybe Text)
taskCount fixture key = scalarText fixture (sqlOf ["SELECT count(*) FROM absurd.t_", capability, " WHERE idempotency_key = %s"]) [textParam key]

taskRuns :: Fixture -> Text -> IO [[Text]]
taskRuns fixture key =
  rowsText
    fixture
    (sqlOf ["SELECT r.attempt, r.state FROM absurd.r_", capability, " r JOIN absurd.t_", capability, " t USING (task_id) WHERE t.idempotency_key = %s ORDER BY r.attempt"])
    [textParam key]

keyOf :: Json -> Text
keyOf report = case lookupMember "key" report of
  Just (String k) -> k
  _ -> error ("no task key in " <> show report)

refusedEvent :: Json -> Bool
refusedEvent event = lookupMember "refused" event /= Nothing

spec :: Spec
spec = absurdEngineSpec $ do
  describe "Engines and Workers of the other language" $ do
    it "a reference Engine dispatches, a Haskell Worker executes, and the reference Engine completes" $ \fixture -> do
      lane <- startWorker fixture HaskellWorker workerOptions
      instanceId <- freshTopo "interop-py-engine"
      issueId <- freshIssue
      dispatched <- py fixture "dispatch" [T.unpack instanceId, T.unpack capability, issueJson issueId [], "1", "30"]
      lookupMember "waiting" dispatched `shouldBe` Just (Bool True)
      finished <- py fixture "finish" [T.unpack instanceId, T.unpack capability, T.unpack issueId, "1"]
      lookupMember "status" finished `shouldBe` Just (String "completed")
      lookupMember "done" finished `shouldBe` Just (Array [sparked issueId])
      void (awaitEvent lane completedEvent)
      effectsFor fixture issueId `shouldReturn` 1
      ours <- map encodeRecord <$> freshRecords fixture instanceId
      Just (Array ours) `shouldBe` lookupMember "records" finished

  describe "authority crash recovery across languages" $ do
    it "a Haskell Engine dispatches and dies; the reference resumes without a double spawn; Haskell reads the same History" $ \fixture -> do
      instanceId <- freshTopo "interop-hs-dies"
      issueId <- freshIssue
      first <- openSession fixture instanceId sessionOptions
      deliverIssue first issueId [] ("ingress-" <> issueId)
      (.waiting) <$> advanceUntilBlocked first `shouldReturn` True
      [outstanding] <- requestedOf <$> Engine.records first
      closeSession first

      void (startWorker fixture PythonWorker workerOptions)
      finished <- py fixture "finish" [T.unpack instanceId, T.unpack capability, T.unpack issueId, "1"]
      lookupMember "status" finished `shouldBe` Just (String "completed")
      lookupMember "done" finished `shouldBe` Just (Array [sparked issueId])
      taskCount fixture (keyFor instanceId outstanding.occurrence) `shouldReturn` Just "1"
      effectsFor fixture issueId `shouldReturn` 1

      resumed <- openSession fixture instanceId sessionOptions {load = True}
      Engine.status resumed `shouldReturn` Completed
      ours <- map encodeRecord <$> Engine.records resumed
      Just (Array ours) `shouldBe` lookupMember "records" finished
      closeSession resumed

    it "the reference dispatches and dies; a Haskell Engine resumes without a double spawn and completes; the reference reads the same History" $ \fixture -> do
      instanceId <- freshTopo "interop-py-dies"
      issueId <- freshIssue
      dispatched <- py fixture "dispatch" [T.unpack instanceId, T.unpack capability, issueJson issueId [], "1", "30"]
      let key = keyOf dispatched
      void (startWorker fixture HaskellWorker workerOptions)
      session <- openSession fixture instanceId sessionOptions {load = True}
      length <$> Engine.inFlight session `shouldReturn` 1
      driveUntilRest session
      deliverApproval session issueId
      driveUntilRest session
      Engine.status session `shouldReturn` Completed
      doneTokens session `shouldReturn` [issue (sparked issueId)]
      taskCount fixture key `shouldReturn` Just "1"
      effectsFor fixture issueId `shouldReturn` 1
      ours <- map encodeRecord <$> Engine.records session
      closeSession session
      py fixture "records" [T.unpack instanceId] `shouldReturn` Array ours

  describe "retries across languages" $ do
    it "a reference Worker killed mid-lease is retried by a Haskell Worker, for a reference Engine" $ \fixture -> do
      armKillSwitch fixture
      doomed <- startWorker fixture PythonWorker workerOptions {claimTimeout = 1, workerId = Just "doomed-py"}
      instanceId <- freshTopo "interop-retry-py"
      issueId <- freshIssue
      dispatched <- py fixture "dispatch" [T.unpack instanceId, T.unpack capability, issueJson issueId [], "2", "1"]
      let key = keyOf dispatched
      waitFor 15 "the reference Worker never reached the effect" ((/= 0) <$> effectsFor fixture issueId)
      taskRuns fixture key `shouldReturn` [["1", "running"]]
      killWorker doomed

      void (startWorker fixture HaskellWorker workerOptions {claimTimeout = 1, workerId = Just "successor-hs"})
      finished <- py fixture "finish" [T.unpack instanceId, T.unpack capability, T.unpack issueId, "2"]
      lookupMember "status" finished `shouldBe` Just (String "completed")
      lookupMember "done" finished `shouldBe` Just (Array [sparked issueId])
      effectsFor fixture issueId `shouldReturn` 1
      taskRuns fixture key `shouldReturn` [["1", "failed"], ["2", "completed"]]

    it "a Haskell Worker killed mid-lease is retried by a reference Worker, for a Haskell Engine" $ \fixture -> do
      armKillSwitch fixture
      doomed <- startWorker fixture HaskellWorker workerOptions {claimTimeout = 1, workerId = Just "doomed-hs"}
      instanceId <- freshTopo "interop-retry-hs"
      issueId <- freshIssue
      session <- openSession fixture instanceId sessionOptions {attempts = 2, defaultHeartbeatTimeout = 1}
      deliverIssue session issueId [] ("ingress-" <> issueId)
      (.waiting) <$> advanceUntilBlocked session `shouldReturn` True
      [requested] <- requestedOf <$> Engine.records session
      let key = keyFor instanceId requested.occurrence
      waitFor 15 "the Haskell Worker never reached the effect" ((/= 0) <$> effectsFor fixture issueId)
      taskRuns fixture key `shouldReturn` [["1", "running"]]
      killWorker doomed

      void (startWorker fixture PythonWorker workerOptions {claimTimeout = 1, workerId = Just "successor-py"})
      driveUntilRestWithin 30 session
      deliverApproval session issueId
      driveUntilRest session
      Engine.status session `shouldReturn` Completed
      doneTokens session `shouldReturn` [issue (sparked issueId)]
      effectsFor fixture issueId `shouldReturn` 1
      taskRuns fixture key `shouldReturn` [["1", "failed"], ["2", "completed"]]

  describe "cancellation across languages" $ do
    it "a reference Engine's scope close fences a Haskell Worker's claimed Attempt" $ \fixture -> do
      lane <- startWorker fixture HaskellWorker workerOptions
      instanceId <- freshTopo "interop-cancel-py"
      issueId <- freshIssue
      dispatched <- py fixture "scope-dispatch" [T.unpack instanceId, T.unpack capability, issueJson issueId [("nap", Float 2.0)]]
      let key = keyOf dispatched
      waitFor 15 "the Haskell Worker never claimed" ((== [["1", "running"]]) <$> taskRuns fixture key)
      closed <- py fixture "scope-close" [T.unpack instanceId, T.unpack capability]
      lookupMember "cancelled" closed `shouldBe` (Array . pure <$> lookupMember "occurrence" dispatched)
      void (awaitEvent lane refusedEvent)
      scalarText fixture (sqlOf ["SELECT state FROM absurd.t_", capability, " WHERE idempotency_key = %s"]) [textParam key] `shouldReturn` Just "cancelled"

      resumed <- openSession fixture instanceId sessionOptions {load = True}
      (.waiting) <$> Engine.advance resumed `shouldReturn` False
      taskCount fixture key `shouldReturn` Just "1"
      closeSession resumed

    it "a Haskell Engine's scope close fences a reference Worker's claimed Attempt" $ \fixture -> do
      worker <- startWorker fixture PythonWorker workerOptions
      instanceId <- freshTopo "interop-cancel-hs"
      issueId <- freshIssue
      session <- openSession fixture instanceId sessionOptions
      scope <- Engine.openScope session "interop-lifecycle"
      void (Engine.deliver session ingress [issue (Object [("id", String issueId), ("nap", Float 2.0)])] ("issue-" <> issueId) (Just (ScopeGeneration scope)))
      (.waiting) <$> advanceUntilBlocked session `shouldReturn` True
      [requested] <- requestedOf <$> Engine.records session
      let key = keyFor instanceId requested.occurrence
      waitFor 15 "the reference Worker never claimed" ((== [["1", "running"]]) <$> taskRuns fixture key)
      closure <- Engine.closeScope session scope
      closure.cancelled `shouldBe` [requested.occurrence]
      closeSession session
      void (awaitEvent worker refusedEvent)
      scalarText fixture (sqlOf ["SELECT state FROM absurd.t_", capability, " WHERE idempotency_key = %s"]) [textParam key] `shouldReturn` Just "cancelled"

      reloaded <- py fixture "load-advance" [T.unpack instanceId, T.unpack capability]
      lookupMember "waiting" reloaded `shouldBe` Just (Bool False)
      taskCount fixture key `shouldReturn` Just "1"
