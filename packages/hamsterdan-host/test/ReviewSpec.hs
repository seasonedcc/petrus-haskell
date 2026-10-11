-- | @tests/unit/host/test_v5_review.py@: the provider-backed V5
-- review-agent gate and its durable request custody.
module ReviewSpec
  ( spec
  , FakeRunner (..)
  , newRunner
  , stubAgentRunner
  ) where

import Control.Exception (SomeException, throwIO, toException)
import Control.Monad (forM_)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Agents.Protocol
import Hamsterdan.Contracts.Codec (Object, validate)
import Hamsterdan.Contracts.ReadinessV5
  ( AgentReview (..)
  , Phase (..)
  , ReviewUnableCategory (..)
  , RoundDeferred (..)
  , RoundMoved (..)
  , RoundOpen (..)
  , RoundUnable (..)
  )
import Hamsterdan.Sqlite (SQLData (..))
import Hamsterdan.Sqlite qualified as Sql
import Hamsterdan.Host.Python (RuntimeError (..), sha256HexText)
import Hamsterdan.Host.V5.Claim (CurrentClaim (..))
import Hamsterdan.Host.V5.Review
import Hamsterdan.Readiness.NetV5.Gating (Variant (..), variantOf)
import Petrus.Json (Json (..))
import System.FilePath ((</>))
import Test.Hspec
import TestSupport (withTempRoot)

headSha, baseSha, operation :: Text
headSha = T.replicate 40 "a"
baseSha = T.replicate 40 "b"
operation = "review:github:12:34:pr:7:" <> headSha <> ":i3"

provisional, lineage0 :: [Object]
provisional = [[("id", String "old"), ("note", String "old"), ("blocking", Bool True)]]
lineage0 = [[("finding_id", String "old"), ("state", String "still_open"), ("supersedes", Null)]]

mem :: Object
mem =
  [ ("subject", String "github:12:34:pr:7")
  , ("head", String headSha)
  , ("incarnation", Int 3)
  , ("status", String "pending")
  , ("reviewed", Array [])
  , ("provisional", Array (map Object provisional))
  , ("findings", Array [Object [("id", String "landed"), ("note", String "landed"), ("blocking", Bool True)]])
  , ("lineage", Array (map Object lineage0))
  , ("dismissed", Array [])
  , ("pub", Object [("phase", String "idle")])
  ]

work :: RoundOpen
work =
  RoundOpen
    { operation
    , head = headSha
    , base = baseSha
    , policy = "policy-1"
    , incarnation = 3
    , priorFindings = provisional
    , priorLineage = lineage0
    , mem
    , attempt = 1
    }

claim3 :: CurrentClaim
claim3 = CurrentClaim "running" 3 headSha baseSha "policy-1"

data FakeAuthority = FakeAuthority {readable :: IORef Bool, reads :: IORef Int, commentBody :: IORef Text}

newAuthority :: IO FakeAuthority
newAuthority = FakeAuthority <$> newIORef True <*> newIORef 0 <*> newIORef "context"

authorityOf :: FakeAuthority -> ReviewAuthority
authorityOf a =
  ReviewAuthority
    { comments = do
        modifyIORef' a.reads (+ 1)
        ok <- readIORef a.readable
        if not ok
          then fail "recovered V5 review read current provider comments"
          else do
            body <- readIORef a.commentBody
            pure
              [ [ ("id", Int 9)
                , ("html_url", String "https://example.test/comments/9")
                , ("body", String body)
                , ("user", Object [("login", String "reviewer")])
                ]
              ]
    , selectRun = \workflow h -> do
        modifyIORef' a.reads (+ 1)
        ok <- readIORef a.readable
        if not ok
          then fail "recovered V5 review read current provider checks"
          else do
            (workflow, h) `shouldBe` ("ci.yml", headSha)
            pure Nothing
    }

data RunnerCall = RunnerCall {url :: Text, request :: ReviewRequest, operation :: Text, attempt :: Integer, isCurrent :: Maybe (IO Bool)}

data FakeRunner = FakeRunner {calls :: IORef [RunnerCall], runner :: AgentRunner}

-- | An 'AgentRunner' whose every capability refuses: the stub the host
-- uses where no agent is configured.
stubAgentRunner :: AgentRunner
stubAgentRunner =
  AgentRunner
    { review = \_ _ _ -> throwIO (protocolError "no agent runner is configured")
    , converse = \_ _ _ -> throwIO (protocolError "no agent runner is configured")
    , code = \_ _ _ -> throwIO (protocolError "no agent runner is configured")
    }

newRunner :: (IO ()) -> Either SomeException ReviewResult -> IO FakeRunner
newRunner sideEffect outcome = do
  calls <- newIORef []
  pure
    FakeRunner
      { calls
      , runner =
          stubAgentRunner
            { review = \url request inv -> do
                modifyIORef' calls (++ [RunnerCall url request inv.operation inv.attempt inv.isCurrent])
                sideEffect
                either throwIO pure outcome
            }
      }

runnerOf :: Either SomeException ReviewResult -> IO FakeRunner
runnerOf = newRunner (pure ())

result :: Text -> [Object] -> [Object] -> ReviewResult
result status findings lineage =
  ReviewResult
    { repository = "owner/repo"
    , pullRequest = 7
    , epoch = 3
    , head = headSha
    , base = baseSha
    , status
    , findings
    , lineage
    }

clear :: Either SomeException ReviewResult
clear = Right (result "clear" [] [])

data Passthrough = Passthrough {claims :: IORef Int, custody :: ReviewRequestCustody}

passthrough :: IO Passthrough
passthrough = do
  claims <- newIORef 0
  pure
    Passthrough
      { claims
      , custody =
          ReviewRequestCustody
            { lookup = \_ _ -> pure Nothing
            , claim = \_ request _ -> modifyIORef' claims (+ 1) >> pure request
            }
      }

gateWith :: FakeRunner -> CurrentClaim -> FakeAuthority -> ReviewRequestCustody -> IO (Maybe Text) -> V5ReviewGate
gateWith r c a requests unstaged =
  V5ReviewGate
    { repository = "owner/repo"
    , pullRequest = 7
    , authority = authorityOf a
    , runner = r.runner
    , publicCloneUrl = "https://example.test/owner/repo.git"
    , workflowPath = "ci.yml"
    , claim = pure c
    , requests
    , unstagedCustody = unstaged
    }

simpleGate :: FakeRunner -> IO V5ReviewGate
simpleGate r = do
  a <- newAuthority
  p <- passthrough
  pure (gateWith r claim3 a p.custody (pure Nothing))

storeGate :: FakeRunner -> FakeAuthority -> V5ReviewRequestStore -> V5ReviewGate
storeGate r a store = gateWith r claim3 a (storeCustody store) (pure Nothing)

unableOf :: Variant -> IO ReviewUnableCategory
unableOf v = do
  v.name `shouldBe` "RoundUnable"
  out <- either (fail . show) pure (validate @RoundUnable v.fields)
  pure out.category

protocolFailure :: AgentProtocolError -> Either SomeException ReviewResult
protocolFailure = Left . toException

firstCall :: FakeRunner -> IO RunnerCall
firstCall r =
  readIORef r.calls >>= \case
    c : _ -> pure c
    [] -> fail "the runner was not called"

withAttempt :: Integer -> RoundOpen -> RoundOpen
withAttempt n w = RoundOpen w.operation w.head w.base w.policy w.incarnation w.priorFindings w.priorLineage w.mem n

withHead :: Text -> RoundOpen -> RoundOpen
withHead h w = RoundOpen w.operation h w.base w.policy w.incarnation w.priorFindings w.priorLineage w.mem w.attempt

spec :: Spec
spec = describe "test_v5_review" $ do
  describe "TestReviewAgentGate" $ do
    it "test_forwards_global_operation_and_net_selected_lineage_without_credentials" $ do
      let fresh = [("id", String "fresh"), ("note", String "fresh"), ("blocking", Bool False)]
          lineage =
            [ [("finding_id", String "old"), ("state", String "resolved"), ("supersedes", Null)]
            , [("finding_id", String "fresh"), ("state", String "new"), ("supersedes", Null)]
            ]
      r <- runnerOf (Right (result "clear" [fresh] lineage))
      out <- simpleGate r >>= (`reviewAgent` work)
      out.name `shouldBe` "AgentReview"
      review <- either (fail . show) pure (validate @AgentReview out.fields)
      review.findings `shouldBe` [fresh]
      review.lineage `shouldBe` lineage
      calls <- readIORef r.calls
      length calls `shouldBe` 1
      call <- firstCall r
      call.url `shouldBe` "https://example.test/owner/repo.git"
      (call.operation, call.attempt) `shouldBe` (operation, 1)
      call.request.priorFindings `shouldBe` work.priorFindings
      call.request.appliedChanges `shouldBe` work.priorLineage
      (call.request.repository, call.request.pullRequest) `shouldBe` ("owner/repo", 7)
      call.request.policy `shouldBe` [("digest", String "policy-1")]
      call.request.priorComments
        `shouldBe` [ [ ("id", Int 9)
                     , ("url", String "https://example.test/comments/9")
                     , ("body", String "context")
                     , ("author", String "reviewer")
                     ]
                   ]
      case call.isCurrent of
        Just current -> current >>= (`shouldBe` True)
        Nothing -> expectationFailure "is_current is missing"
    it "test_unstaged_custody_defers_before_claim_request_or_agent_entry" $ do
      let blocker = "9adff0dc-4784-4eed-9c78-047d6952efed"
      r <- runnerOf clear
      a <- newAuthority
      p <- passthrough
      out <- reviewAgent (gateWith r claim3 a p.custody (pure (Just blocker))) work
      out
        `shouldBe` variantOf
          RoundDeferred
            { operation
            , head = headSha
            , base = baseSha
            , policy = "policy-1"
            , incarnation = 3
            , priorFindings = work.priorFindings
            , priorLineage = work.priorLineage
            , mem
            , attempt = 1
            , blocker
            }
      length <$> readIORef r.calls >>= (`shouldBe` 0)
      readIORef a.reads >>= (`shouldBe` 0)
      readIORef p.claims >>= (`shouldBe` 0)
    it "test_cleanup_verified_cancellation_defers_when_custody_arrives_in_flight" $ do
      blocker <- newIORef Nothing
      r <-
        newRunner
          (writeIORef blocker (Just "9adff0dc-4784-4eed-9c78-047d6952efed"))
          (protocolFailure (protocolError "superseded") {canceled = True})
      a <- newAuthority
      p <- passthrough
      out <- reviewAgent (gateWith r claim3 a p.custody (readIORef blocker)) work
      out.name `shouldBe` "RoundDeferred"
      deferred <- either (fail . show) pure (validate @RoundDeferred out.fields)
      deferred.attempt `shouldBe` 1
      Just deferred.blocker `shouldBe` Just "9adff0dc-4784-4eed-9c78-047d6952efed"
    it "test_cleanup_uncertainty_remains_unable_even_when_custody_arrives" $ do
      blocker <- newIORef Nothing
      r <-
        newRunner
          (writeIORef blocker (Just "9adff0dc-4784-4eed-9c78-047d6952efed"))
          (protocolFailure (protocolError "superseded") {canceled = True, cleanupCategory = Just CleanupUnverified})
      a <- newAuthority
      p <- passthrough
      out <- reviewAgent (gateWith r claim3 a p.custody (readIORef blocker)) work
      unableOf out >>= (`shouldBe` UnableCanceled)
    it "test_moved_claim_cancels_before_request_custody_provider_reads_or_agent_entry" $ do
      r <- runnerOf clear
      let moved = CurrentClaim "running" 4 headSha baseSha "policy-1"
      a <- newAuthority
      p <- passthrough
      out <- reviewAgent (gateWith r moved a p.custody (pure Nothing)) work
      out
        `shouldBe` variantOf
          RoundMoved
            { head = headSha
            , incarnation = 3
            , observed = moved.head
            , observedBase = moved.base
            , observedPolicy = moved.policy
            , observedIncarnation = moved.incarnation
            , observedPhase = PhaseRunning
            , mem
            }
      length <$> readIORef r.calls >>= (`shouldBe` 0)
      readIORef a.reads >>= (`shouldBe` 0)
      readIORef p.claims >>= (`shouldBe` 0)
    it "test_validated_unable_result_is_a_clean_round_outcome" $ do
      r <- runnerOf (Right (result "unable" [[("ignored", Bool True)]] []))
      out <- simpleGate r >>= (`reviewAgent` work)
      out `shouldBe` variantOf RoundUnable {head = headSha, incarnation = 3, category = UnableUnable, mem}
    let categories =
          [ (RuntimeLifecycle, UnableRuntimeLifecycle, "runtime_lifecycle")
          , (OutputSchema, UnableOutputSchema, "output_schema")
          , (Correlation, UnableCorrelation, "correlation")
          , (Unchanged, UnableUnchanged, "unchanged")
          , (Unable, UnableUnable, "unable")
          , (WorkspaceReconciliation, UnableWorkspaceReconciliation, "workspace_reconciliation")
          ]
    forM_ categories $ \(c, expected, label) ->
      it ("test_closed_agent_result_categories_map_exhaustively[" <> label <> "]") $ do
        r <- runnerOf (protocolFailure (protocolError "classified") {resultCategory = Just c})
        out <- simpleGate r >>= (`reviewAgent` work)
        unableOf out >>= (`shouldBe` expected)
    let others =
          [ ("timed_out", (protocolError "timeout") {timedOut = True}, UnableTimedOut)
          , ("canceled", (protocolError "cancel") {canceled = True}, UnableCanceled)
          , ("cleanup_unverified", (protocolError "cleanup") {cleanupCategory = Just CleanupUnverified}, UnableCleanupUnverified)
          , ("protocol", protocolError "protocol", UnableProtocol)
          ]
    forM_ others $ \(label, e, expected) ->
      it ("test_other_protocol_outcomes_use_the_closed_unable_vocabulary[" <> label <> "]") $ do
        r <- runnerOf (protocolFailure e)
        out <- simpleGate r >>= (`reviewAgent` work)
        unableOf out >>= (`shouldBe` expected)
    it "test_unexpected_runner_failure_remains_a_genuine_activity_failure" $ do
      r <- runnerOf (Left (toException (RuntimeError "bug")))
      g <- simpleGate r
      reviewAgent g work `shouldThrow` (\(RuntimeError m) -> m == "bug")

  describe "TestReviewRequestRecovery" $ do
    it "test_restart_reuses_the_exact_frozen_request_before_any_provider_read" $ withTempRoot $ \tmp -> do
      let path = tmp </> "review-requests.sqlite3"
      a <- newAuthority
      first <- runnerOf clear
      firstStore <- openReviewRequestStore path
      _ <- reviewAgent (storeGate first a firstStore) work
      frozen <- (.request) <$> firstCall first
      readIORef a.reads >>= (`shouldBe` 2)
      closeReviewRequestStore firstStore
      writeIORef a.commentBody "changed after the lost Activity terminal"
      writeIORef a.readable False
      second <- runnerOf clear
      secondStore <- openReviewRequestStore path
      _ <- reviewAgent (storeGate second a secondStore) work
      replayed <- (.request) <$> firstCall second
      replayed `shouldBe` frozen
      readIORef a.reads >>= (`shouldBe` 2)
      closeReviewRequestStore secondStore
    it "test_same_operation_cannot_select_a_different_round" $ withTempRoot $ \tmp -> do
      store <- openReviewRequestStore (tmp </> "review-requests.sqlite3")
      a <- newAuthority
      r <- runnerOf clear
      _ <- reviewAgent (storeGate r a store) work
      r2 <- runnerOf clear
      reviewAgent (storeGate r2 a store) (withHead (T.replicate 40 "c") work)
        `shouldThrow` (\(RuntimeError m) -> "operation" `T.isInfixOf` m && "different review request" `T.isInfixOf` m)
      closeReviewRequestStore store
    it "test_fresh_attempt_gets_fresh_request_custody_under_the_same_operation" $ withTempRoot $ \tmp -> do
      let path = tmp </> "review-requests.sqlite3"
      a <- newAuthority
      store <- openReviewRequestStore path
      first <- runnerOf clear
      _ <- reviewAgent (storeGate first a store) work
      writeIORef a.commentBody "context after deferred custody cleared"
      second <- runnerOf clear
      _ <- reviewAgent (storeGate second a store) (withAttempt 2 work)
      c1 <- firstCall first
      c2 <- firstCall second
      map (lookup "body") c1.request.priorComments `shouldBe` [Just (String "context")]
      map (lookup "body") c2.request.priorComments `shouldBe` [Just (String "context after deferred custody cleared")]
      [c1.attempt, c2.attempt] `shouldBe` [1, 2]
      db <- Sql.open (T.pack path)
      rows <- Sql.query db "SELECT attempt FROM v5_review_requests WHERE operation=? ORDER BY attempt" [SQLText operation]
      Sql.close db
      rows `shouldBe` [[SQLInteger 1], [SQLInteger 2]]
      closeReviewRequestStore store
    it "test_legacy_operation_keyed_request_migrates_as_attempt_one" $ withTempRoot $ \tmp -> do
      let path = tmp </> "review-requests.sqlite3"
      store <- openReviewRequestStore path
      a <- newAuthority
      r <- runnerOf clear
      _ <- reviewAgent (storeGate r a store) work
      closeReviewRequestStore store
      db <- Sql.open (T.pack path)
      Sql.script db "ALTER TABLE v5_review_requests RENAME TO v5_review_requests_v2"
      Sql.script db "CREATE TABLE v5_review_requests (operation TEXT PRIMARY KEY,request_json TEXT NOT NULL,digest TEXT NOT NULL)"
      Sql.script db "INSERT INTO v5_review_requests SELECT operation,request_json,digest FROM v5_review_requests_v2"
      Sql.script db "DROP TABLE v5_review_requests_v2"
      Sql.close db
      reopened <- openReviewRequestStore path
      found <- lookupRequest reopened operation 1
      found `shouldSatisfy` maybe False (const True)
      check <- Sql.open (T.pack path)
      columns <- Sql.query check "PRAGMA table_info(v5_review_requests)" []
      Sql.close check
      [name | _ : SQLText name : _ <- columns] `shouldMatchList` ["operation", "attempt", "request_json", "digest"]
      closeReviewRequestStore reopened
    it "test_stored_request_digest_is_verified_before_replay" $ withTempRoot $ \tmp -> do
      let path = tmp </> "review-requests.sqlite3"
      store <- openReviewRequestStore path
      a <- newAuthority
      r <- runnerOf clear
      _ <- reviewAgent (storeGate r a store) work
      closeReviewRequestStore store
      db <- Sql.open (T.pack path)
      rows <- Sql.query db "SELECT request_json FROM v5_review_requests WHERE operation = ?" [SQLText operation]
      raw <- case rows of
        [SQLText text] : _ -> pure text
        _ -> fail "no stored request"
      let corrupted = T.replace "\"diff_path\":\"diff.patch\"" "\"diff_path\":\"other.patch\"" raw
      sha256HexText corrupted `shouldNotBe` sha256HexText raw
      _ <- Sql.execute db "UPDATE v5_review_requests SET request_json = ? WHERE operation = ?" [SQLText corrupted, SQLText operation]
      Sql.close db
      reopened <- openReviewRequestStore path
      lookupRequest reopened operation 1 `shouldThrow` (\(RuntimeError m) -> "digest" `T.isInfixOf` m)
      closeReviewRequestStore reopened
