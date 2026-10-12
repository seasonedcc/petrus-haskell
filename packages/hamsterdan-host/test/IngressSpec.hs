-- | @tests/unit/host/test_v5_ingress.py@: the store and normalizer cases.
-- The application cases live in "IngressApplicationSpec".
module IngressSpec
  ( spec
  , subject
  , newDelivery
  , headEntry
  , lifecycleEntry
  , humanEntry
  , projection
  , reconciliationProjection
  , FakeAuthority (..)
  , newFakeAuthority
  , fakeIngressAuthority
  ) where

import Control.Exception (toException)
import Control.Monad (forM_)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite3 qualified as S
import Hamsterdan.Contracts.ReadinessV5
import Hamsterdan.GitHub.Models
import Hamsterdan.Sqlite (SQLData (..))
import Hamsterdan.Host.Python (RuntimeError (..), dumpsSortedText, sha256Hex, dumpsSorted)
import Hamsterdan.Host.V5.Claim
import Hamsterdan.Host.V5.Ingress qualified as I
import Petrus.Json (Json (..), parseJson, surrogateRefusingLoads)
import Data.Text.Encoding qualified as TE
import Petrus.Posix.File (uuid4Hex)
import System.FilePath ((</>))
import Test.Hspec hiding (pending)
import TestSupport

subject :: Text
subject = "github:44:31:pr:7"

-- | @str(uuid.uuid4())@.
newDelivery :: IO Text
newDelivery = do
  hex <- T.pack <$> uuid4Hex
  pure (T.intercalate "-" [T.take 8 hex, T.take 4 (T.drop 8 hex), T.take 4 (T.drop 12 hex), T.take 4 (T.drop 16 hex), T.drop 20 hex])

headSeen :: Text -> HeadSeen
headSeen value = HeadSeen {head = value, base = T.replicate 40 "b", mergeable = True, policy = "policy-1", strictBase = True, baseCurrent = False}

headEntry :: Text -> Text -> I.IngressEntry
headEntry identity value = I.ingressFrom "on_head" (headSeen value) ("github-delivery:" <> identity <> ":on_head")

lifecycleEntry :: Text -> Text -> I.IngressEntry
lifecycleEntry identity source
  | source == "on_draft" = I.ingressFrom source DraftSeen ("github-delivery:" <> identity <> ":" <> source)
  | otherwise = I.ingressFrom source ReadySeen ("github-delivery:" <> identity <> ":" <> source)

humanEntry :: Text -> I.IngressEntry
humanEntry identity = I.ingressFrom "on_human" HumanSeen {approval = False, changesRequested = False, unresolved = 0} ("github-delivery:" <> identity <> ":on_human")

projection :: Text -> Text -> Text -> [I.IngressEntry]
projection identity source value = [headEntry identity value, lifecycleEntry identity source, humanEntry identity]

aaa :: Text
aaa = T.replicate 40 "a"

reconciliationProjection :: Text -> Text -> [I.ProjectedEntry]
reconciliationProjection source value =
  [ I.projectedFrom "on_head" (headSeen value)
  , if source == "on_draft" then I.projectedFrom source DraftSeen else I.projectedFrom source ReadySeen
  , I.projectedFrom "on_human" HumanSeen {approval = False, changesRequested = False, unresolved = 0}
  ]

withDb :: FilePath -> (S.Database -> IO a) -> IO a
withDb path use = do
  db <- S.open (T.pack path)
  result <- use db
  S.close db
  pure result

rows :: S.Database -> Text -> [SQLData] -> IO [[SQLData]]
rows db sql params = do
  statement <- S.prepare db sql
  S.bind statement params
  let go acc =
        S.step statement >>= \case
          S.Done -> pure (reverse acc)
          S.Row -> S.columns statement >>= \row -> go (row : acc)
  result <- go []
  S.finalize statement
  pure result

exec :: S.Database -> Text -> [SQLData] -> IO ()
exec db sql params = () <$ rows db sql params

encodedEntries :: [I.IngressEntry] -> Text
encodedEntries = dumpsSortedText . Array . map I.entryJson

stripLegacy :: Json -> Json
stripLegacy = \case
  Object members -> Object [(k, if k == "payload" then dropKeys v else v) | (k, v) <- members]
  other -> other
  where
    dropKeys = \case
      Object ms -> Object [(k, v) | (k, v) <- ms, k `notElem` ["strict_base", "base_current"]]
      other -> other

createInbox :: S.Database -> IO ()
createInbox db = S.exec db "CREATE TABLE inbox (delivery_id TEXT PRIMARY KEY, status TEXT NOT NULL, observation TEXT NOT NULL)"

pendingObservation :: Text
pendingObservation = "{\"installation_id\": 44, \"repository_id\": 31, \"pull_request_number\": 7}"

payloadMember :: Text -> I.IngressEntry -> Maybe Json
payloadMember key entry = case entry.payload of
  Object ms -> lookup key ms
  _ -> Nothing

firstOf :: [a] -> a
firstOf = \case
  x : _ -> x
  [] -> error "empty list"

-- ---------------------------------------------------------------------------
-- Fake provider authority (the test's @Authority@)

data FakeAuthority = FakeAuthority
  { pull :: IORef PullRequestSnapshot
  , repoPolicy :: IORef RepositoryPolicy
  , review :: IORef HumanReviewSnapshot
  , runs :: IORef [ActionsRunSnapshot]
  , evidenceCalls :: IORef [(Integer, Integer)]
  , baseCurrentCalls :: IORef [PullRequestSnapshot]
  , pullCalls :: IORef Int
  }

newFakeAuthority :: Bool -> Bool -> Bool -> IO FakeAuthority
newFakeAuthority draft closed merged = do
  pull <-
    newIORef
      PullRequestSnapshot
        { repository = "owner/repo"
        , number = 7
        , state = if closed then "closed" else "open"
        , draft
        , head = aaa
        , base = T.replicate 40 "b"
        , headRef = "feature"
        , baseRef = "main"
        , mergeable = Bool True
        , merged
        , closed
        , author = "author"
        , mergeableState = "clean"
        , url = "https://example.test/pr/7"
        , headRepository = "owner/repo"
        }
  repoPolicy <- newIORef (RepositoryPolicy True True ["test"] 1 True "rules" "policy-1")
  review <- newIORef (HumanReviewSnapshot [] [] ["reviewer"] [] (Just 0) "available")
  runs <-
    newIORef
      [ ActionsRunSnapshot 9 aaa ".github/workflows/ci.yml" 5 "completed" (Just "failure") []
      , ActionsRunSnapshot 10 aaa ".github/workflows/ci.yml" 1 "completed" (Just "success") []
      ]
  FakeAuthority pull repoPolicy review runs <$> newIORef [] <*> newIORef [] <*> newIORef 0

fakeIngressAuthority :: FakeAuthority -> I.IngressAuthority
fakeIngressAuthority fake =
  I.IngressAuthority
    { pullRequest = modifyIORef' fake.pullCalls (+ 1) >> readIORef fake.pull
    , policy = \baseRef -> do
        baseRef `shouldBe` "main"
        readIORef fake.repoPolicy
    , baseCurrent = \p -> modifyIORef' fake.baseCurrentCalls (<> [p]) >> pure True
    , humanReview = readIORef fake.review
    , workflowRuns = \workflow head' -> do
        (workflow, head') `shouldBe` (".github/workflows/ci.yml", aaa)
        readIORef fake.runs
    , actionsEvidence = \run _ -> do
        modifyIORef' fake.evidenceCalls (<> [(run.id, run.attempt)])
        pure (ActionsEvidence run Success [])
    }

-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "test_v5_ingress (store and normalizer)" $ do
  it "test_manifest_and_authority_grant_commit_together_before_replay" . withTempRoot $ \tmp -> do
    identity <- newDelivery
    let path = tmp </> "webhooks.sqlite3"
    store <- I.openIngressStore path
    m <- I.stage store identity subject (projection identity "on_draft" aaa)
    map (.source) m.entries `shouldBe` ["on_head", "on_draft", "on_human"]
    c <- I.claim store subject
    claimAsMap c `shouldBe` Object [("phase", String "quiescent"), ("incarnation", Int 1), ("head", String aaa), ("base", String (T.replicate 40 "b")), ("policy", String "policy-1")]
    stored <- withDb path $ \db -> rows db "SELECT topology,schema_version,entries FROM v5_ingress_manifests WHERE delivery_id=?" [SQLText identity]
    case stored of
      [[SQLText "v5", SQLInteger 1, SQLText encoded]] -> do
        let values = case parseJson surrogateRefusingLoads (TE.encodeUtf8 encoded) of
              Right (Array vs) -> vs
              _ -> []
        [i | Object ms <- values, Just (String i) <- [lookup "identity" ms]]
          `shouldBe` ["github-delivery:" <> identity <> ":on_head", "github-delivery:" <> identity <> ":on_draft", "github-delivery:" <> identity <> ":on_human"]
      other -> expectationFailure (show other)
    I.close store

  it "test_replay_uses_frozen_manifest_even_when_fresh_projection_differs" . withTempRoot $ \tmp -> do
    identity <- newDelivery
    store <- I.openIngressStore (tmp </> "webhooks.sqlite3")
    original <- I.stage store identity subject (projection identity "on_draft" aaa)
    replayed <- I.stage store identity subject (projection identity "on_ready" (T.replicate 40 "c"))
    replayed `shouldBe` original
    ((.phase) <$> I.claim store subject) `shouldReturn` PhaseQuiescent
    ((.head) <$> I.claim store subject) `shouldReturn` aaa
    I.close store

  it "test_legacy_webhook_manifest_replays_then_fresh_reconciliation_adds_base_evidence" . withTempRoot $ \tmp -> do
    let path = tmp </> "webhooks.sqlite3"
    identity <- newDelivery
    let values = case map I.entryJson (projection identity "on_ready" aaa) of
          first : rest -> stripLegacy first : rest
          [] -> []
    store <- I.openIngressStore path
    withDb path $ \db -> do
      exec db "INSERT INTO v5_ingress_manifests(delivery_id,subject,revision,topology,schema_version,entries) VALUES(?,?,?,?,?,?)" [SQLText identity, SQLText subject, SQLInteger 1, SQLText "v5", SQLInteger 1, SQLText (dumpsSortedText (Array values))]
      exec db "INSERT INTO v5_authority_grants(subject,phase,incarnation,head,base,policy,revision,source_kind,source_id) VALUES(?,?,?,?,?,?,?,?,?)" [SQLText subject, SQLText "running", SQLInteger 1, SQLText aaa, SQLText (T.replicate 40 "b"), SQLText "policy-1", SQLInteger 1, SQLText "github-delivery", SQLText identity]
    Just legacy <- I.manifest store identity subject
    Just refreshed <- I.stageReconciliation store subject (reconciliationProjection "on_ready" aaa)
    case (firstOf legacy.entries).payload of
      Object ms -> map fst ms `shouldMatchList` ["head", "base", "mergeable", "policy"]
      other -> expectationFailure (show other)
    refreshed.revision `shouldBe` 2
    payloadMember "strict_base" (firstOf refreshed.entries) `shouldBe` Just (Bool True)
    payloadMember "base_current" (firstOf refreshed.entries) `shouldBe` Just (Bool False)
    I.close store

  it "test_legacy_reconciliation_manifest_keeps_its_digest_then_refreshes_base_evidence" . withTempRoot $ \tmp -> do
    let path = tmp </> "webhooks.sqlite3"
        projected = case map I.projectedJson (reconciliationProjection "on_ready" aaa) of
          first : rest -> stripLegacy first : rest
          [] -> []
        digest = sha256Hex (dumpsSorted (Object [("topology", String "v5"), ("schema_version", Int 1), ("entries", Array projected)]))
        sourceId = "host-reconcile:" <> subject <> ":1:" <> digest
        entries = [Object (ms <> [("identity", String (sourceId <> ":" <> src))]) | Object ms <- projected, Just (String src) <- [lookup "source" ms]]
    store <- I.openIngressStore path
    withDb path $ \db -> do
      exec db "INSERT INTO v5_reconciliation_manifests(source_id,subject,revision,digest,topology,schema_version,entries) VALUES(?,?,?,?,?,?,?)" [SQLText sourceId, SQLText subject, SQLInteger 1, SQLText digest, SQLText "v5", SQLInteger 1, SQLText (dumpsSortedText (Array entries))]
      exec db "INSERT INTO v5_authority_grants(subject,phase,incarnation,head,base,policy,revision,source_kind,source_id) VALUES(?,?,?,?,?,?,?,?,?)" [SQLText subject, SQLText "running", SQLInteger 1, SQLText aaa, SQLText (T.replicate 40 "b"), SQLText "policy-1", SQLInteger 1, SQLText "host-reconcile", SQLText sourceId]
    Just legacy <- I.latestReconciliation store subject
    Just refreshed <- I.stageReconciliation store subject (reconciliationProjection "on_ready" aaa)
    legacy.sourceId `shouldBe` sourceId
    case (firstOf legacy.entries).payload of
      Object ms -> map fst ms `shouldMatchList` ["head", "base", "mergeable", "policy"]
      other -> expectationFailure (show other)
    refreshed.revision `shouldBe` 2
    refreshed.sourceId `shouldNotBe` sourceId
    payloadMember "strict_base" (firstOf refreshed.entries) `shouldBe` Just (Bool True)
    payloadMember "base_current" (firstOf refreshed.entries) `shouldBe` Just (Bool False)
    I.close store

  it "test_unchanged_reconciliation_reuses_one_lineaged_manifest_and_grant_revision" . withTempRoot $ \tmp -> do
    let path = tmp </> "webhooks.sqlite3"
        projected = reconciliationProjection "on_ready" aaa
    store <- I.openIngressStore path
    Just first <- I.stageReconciliation store subject projected
    second <- I.stageReconciliation store subject projected
    second `shouldBe` Just first
    let digest = sha256Hex (dumpsSorted (Object [("topology", String "v5"), ("schema_version", Int 1), ("entries", Array (map I.projectedJson projected))]))
    first.sourceId `shouldBe` "host-reconcile:" <> subject <> ":1:" <> digest
    all (\e -> e.identity == first.sourceId <> ":" <> e.source) first.entries `shouldBe` True
    withDb path $ \db -> do
      rows db "SELECT COUNT(*) FROM v5_reconciliation_manifests" [] `shouldReturn` [[SQLInteger 1]]
      rows db "SELECT revision,source_kind,source_id FROM v5_authority_grants WHERE subject=?" [SQLText subject]
        `shouldReturn` [[SQLInteger 1, SQLText "host-reconcile", SQLText first.sourceId]]
    I.close store

  it "test_intervening_webhook_makes_byte_identical_reconciliation_a_new_lifecycle_occurrence" . withTempRoot $ \tmp -> do
    store <- I.openIngressStore (tmp </> "webhooks.sqlite3")
    Just first <- I.stageReconciliation store subject (reconciliationProjection "on_draft" aaa)
    readied <- newDelivery
    _ <- I.stage store readied subject (projection readied "on_ready" aaa)
    Just second <- I.stageReconciliation store subject (reconciliationProjection "on_draft" aaa)
    second.sourceId `shouldNotBe` first.sourceId
    (first.entries !! 1).identity `shouldNotBe` (second.entries !! 1).identity
    c <- I.claim store subject
    (c.phase, c.incarnation) `shouldBe` (PhaseQuiescent, 2)
    I.close store

  it "test_pending_webhook_custody_wins_reconciliation_stage_without_manifest_or_grant" . withTempRoot $ \tmp -> do
    let path = tmp </> "webhooks.sqlite3"
    store <- I.openIngressStore path
    pending <- newDelivery
    withDb path $ \db -> do
      createInbox db
      exec db "INSERT INTO inbox VALUES (?, 'pending', ?)" [SQLText pending, SQLText pendingObservation]
    I.stageReconciliation store subject (reconciliationProjection "on_ready" aaa) `shouldReturn` Nothing
    withDb path $ \db -> do
      rows db "SELECT COUNT(*) FROM v5_reconciliation_manifests" [] `shouldReturn` [[SQLInteger 0]]
      rows db "SELECT COUNT(*) FROM v5_authority_grants" [] `shouldReturn` [[SQLInteger 0]]
    I.close store

  it "test_legacy_webhook_grant_migrates_to_a_discriminated_source_before_reconciliation" . withTempRoot $ \tmp -> do
    let path = tmp </> "webhooks.sqlite3"
    identity <- newDelivery
    let encoded = encodedEntries (projection identity "on_ready" aaa)
    withDb path $ \db -> do
      S.exec
        db
        "CREATE TABLE v5_ingress_manifests (delivery_id TEXT PRIMARY KEY, subject TEXT NOT NULL, topology TEXT NOT NULL, schema_version INTEGER NOT NULL, entries TEXT NOT NULL);\
        \CREATE TABLE v5_authority_grants (subject TEXT PRIMARY KEY, phase TEXT NOT NULL, incarnation INTEGER NOT NULL, head TEXT NOT NULL, base TEXT NOT NULL, policy TEXT NOT NULL, revision INTEGER NOT NULL, source_delivery TEXT NOT NULL);"
      exec db "INSERT INTO v5_ingress_manifests VALUES(?,?,?,?,?)" [SQLText identity, SQLText subject, SQLText "v5", SQLInteger 1, SQLText encoded]
      exec db "INSERT INTO v5_authority_grants VALUES(?,?,?,?,?,?,?,?)" [SQLText subject, SQLText "running", SQLInteger 1, SQLText aaa, SQLText (T.replicate 40 "b"), SQLText "policy-1", SQLInteger 1, SQLText identity]
    store <- I.openIngressStore path
    ((.head) <$> I.claim store subject) `shouldReturn` aaa
    Just reconciled <- I.stageReconciliation store subject (reconciliationProjection "on_ready" aaa)
    (":" <> subject <> ":2:") `T.isInfixOf` reconciled.sourceId `shouldBe` True
    I.close store
    reopened <- I.openIngressStore path
    I.latestReconciliation reopened subject `shouldReturn` Just reconciled
    withDb path $ \db ->
      rows db "SELECT revision,source_kind,source_id,source_delivery FROM v5_authority_grants WHERE subject=?" [SQLText subject]
        `shouldReturn` [[SQLInteger 2, SQLText "host-reconcile", SQLText reconciled.sourceId, SQLText reconciled.sourceId]]
    I.close reopened
    withDb path $ \db -> exec db "UPDATE v5_authority_grants SET source_delivery=? WHERE subject=?" [SQLText identity, SQLText subject]
    divergent <- I.openIngressStore path
    I.claim divergent subject `shouldThrow` runtimeError "grant is malformed"
    I.close divergent

  it "test_reconciliation_manifest_and_grant_corruption_fail_closed" . withTempRoot $ \tmp -> do
    let path = tmp </> "webhooks.sqlite3"
    store <- I.openIngressStore path
    Just m <- I.stageReconciliation store subject (reconciliationProjection "on_ready" aaa)
    withDb path $ \db -> exec db "UPDATE v5_reconciliation_manifests SET digest=? WHERE source_id=?" [SQLText (T.replicate 64 "0"), SQLText m.sourceId]
    I.latestReconciliation store subject `shouldThrow` runtimeError "manifest is malformed"
    I.claim store subject `shouldThrow` runtimeError "manifest is malformed"
    I.close store

  it "test_current_webhook_grant_validates_its_manifest_and_exact_revision" . withTempRoot $ \tmp -> do
    let path = tmp </> "webhooks.sqlite3"
    identity <- newDelivery
    store <- I.openIngressStore path
    _ <- I.stage store identity subject (projection identity "on_ready" aaa)
    withDb path $ \db -> exec db "UPDATE v5_ingress_manifests SET entries='[]' WHERE delivery_id=?" [SQLText identity]
    I.claim store subject `shouldThrow` valueError "door order"
    withDb path $ \db -> do
      exec db "UPDATE v5_ingress_manifests SET entries=? WHERE delivery_id=?" [SQLText (encodedEntries (projection identity "on_ready" aaa)), SQLText identity]
      exec db "UPDATE v5_authority_grants SET revision=7 WHERE subject=?" [SQLText subject]
    I.claim store subject `shouldThrow` runtimeError "grant is malformed"
    I.close store

  it "test_cross_kind_revision_collision_fails_closed" . withTempRoot $ \tmp -> do
    let path = tmp </> "webhooks.sqlite3"
    store <- I.openIngressStore path
    Just _ <- I.stageReconciliation store subject (reconciliationProjection "on_ready" aaa)
    identity <- newDelivery
    withDb path $ \db ->
      exec db "INSERT INTO v5_ingress_manifests(delivery_id,subject,revision,topology,schema_version,entries) VALUES(?,?,?,?,?,?)" [SQLText identity, SQLText subject, SQLInteger 1, SQLText "v5", SQLInteger 1, SQLText (encodedEntries (projection identity "on_ready" aaa))]
    I.claim store subject `shouldThrow` runtimeError "grant is malformed"
    I.close store

  it "test_partial_source_pointer_migration_fails_closed_instead_of_repairing" . withTempRoot $ \tmp -> do
    let path = tmp </> "webhooks.sqlite3"
    identity <- newDelivery
    withDb path $ \db -> do
      S.exec
        db
        "CREATE TABLE v5_ingress_manifests (delivery_id TEXT PRIMARY KEY, subject TEXT NOT NULL, topology TEXT NOT NULL, schema_version INTEGER NOT NULL, entries TEXT NOT NULL);\
        \CREATE TABLE v5_authority_grants (subject TEXT PRIMARY KEY, phase TEXT NOT NULL, incarnation INTEGER NOT NULL, head TEXT NOT NULL, base TEXT NOT NULL, policy TEXT NOT NULL, revision INTEGER NOT NULL, source_delivery TEXT NOT NULL, source_kind TEXT);"
      exec db "INSERT INTO v5_ingress_manifests VALUES(?,?,?,?,?)" [SQLText identity, SQLText subject, SQLText "v5", SQLInteger 1, SQLText (encodedEntries (projection identity "on_ready" aaa))]
      exec db "INSERT INTO v5_authority_grants VALUES(?,?,?,?,?,?,?,?,?)" [SQLText subject, SQLText "running", SQLInteger 1, SQLText aaa, SQLText (T.replicate 40 "b"), SQLText "policy-1", SQLInteger 1, SQLText identity, SQLText "github-delivery"]
    I.openIngressStore path `shouldThrow` runtimeError "source pointer migration is partial"

  it "test_draft_ready_same_claim_mints_a_new_host_incarnation" . withTempRoot $ \tmp -> do
    store <- I.openIngressStore (tmp </> "webhooks.sqlite3")
    drafted <- newDelivery
    readied <- newDelivery
    _ <- I.stage store drafted subject (projection drafted "on_draft" aaa)
    _ <- I.stage store readied subject (projection readied "on_ready" aaa)
    I.claim store subject `shouldReturn` CurrentClaim PhaseRunning 2 aaa (T.replicate 40 "b") "policy-1"
    I.close store

  it "test_manifest_and_grant_roll_back_as_one_transaction" . withTempRoot $ \tmp -> do
    identity <- newDelivery
    let path = tmp </> "webhooks.sqlite3"
    store <- I.openIngressStore path
    I.setWriteClaimFault store (Just (toException (RuntimeError "grant write interrupted")))
    I.stage store identity subject (projection identity "on_ready" aaa) `shouldThrow` runtimeError "grant write interrupted"
    withDb path $ \db -> do
      rows db "SELECT 1 FROM v5_ingress_manifests WHERE delivery_id=?" [SQLText identity] `shouldReturn` []
      rows db "SELECT 1 FROM v5_authority_grants WHERE subject=?" [SQLText subject] `shouldReturn` []
    I.close store

  it "test_reconciliation_manifest_and_grant_roll_back_as_one_transaction" . withTempRoot $ \tmp -> do
    let path = tmp </> "webhooks.sqlite3"
    store <- I.openIngressStore path
    I.setWriteClaimFault store (Just (toException (RuntimeError "grant write interrupted")))
    I.stageReconciliation store subject (reconciliationProjection "on_ready" aaa) `shouldThrow` runtimeError "grant write interrupted"
    withDb path $ \db -> do
      rows db "SELECT 1 FROM v5_reconciliation_manifests" [] `shouldReturn` []
      rows db "SELECT 1 FROM v5_authority_grants WHERE subject=?" [SQLText subject] `shouldReturn` []
    I.close store

  forM_
    [ ("0", \identity -> [headEntry identity aaa, headEntry identity aaa])
    , ("1", \identity -> [lifecycleEntry identity "on_draft", headEntry identity aaa])
    ]
    $ \(label, entries) ->
      it ("test_manifest_rejects_duplicate_or_out_of_order_doors[" <> label <> "]") . withTempRoot $ \tmp -> do
        identity <- newDelivery
        store <- I.openIngressStore (tmp </> "webhooks.sqlite3")
        I.stage store identity subject (entries identity) `shouldThrow` valueError "door order"
        I.close store

  it "test_manifest_rejects_a_door_payload_that_does_not_match_its_strict_color" . withTempRoot $ \tmp -> do
    identity <- newDelivery
    store <- I.openIngressStore (tmp </> "webhooks.sqlite3")
    let malformed =
          I.IngressEntry
            { source = "on_head"
            , color = "HeadSeen"
            , payload = Object [("head", Int 7), ("base", String (T.replicate 40 "b")), ("mergeable", Bool True), ("policy", String "policy-1")]
            , identity = "github-delivery:" <> identity <> ":on_head"
            }
    I.stage store identity subject [malformed, lifecycleEntry identity "on_ready", humanEntry identity] `shouldThrow` valueError "payload"
    I.close store

  it "test_manifest_rejects_an_incomplete_open_projection" . withTempRoot $ \tmp -> do
    identity <- newDelivery
    store <- I.openIngressStore (tmp </> "webhooks.sqlite3")
    I.stage store identity subject [lifecycleEntry identity "on_ready"] `shouldThrow` valueError "complete batch"
    I.close store

  it "test_manifest_replay_requires_its_subject_grant" . withTempRoot $ \tmp -> do
    identity <- newDelivery
    let path = tmp </> "webhooks.sqlite3"
    store <- I.openIngressStore path
    _ <- I.stage store identity subject (projection identity "on_ready" aaa)
    withDb path $ \db -> exec db "DELETE FROM v5_authority_grants WHERE subject=?" [SQLText subject]
    I.manifest store identity subject `shouldThrow` runtimeError "grant is missing"
    I.close store

  it "test_new_delivery_cannot_replace_a_missing_grant_from_prior_custody" . withTempRoot $ \tmp -> do
    first <- newDelivery
    second <- newDelivery
    let path = tmp </> "webhooks.sqlite3"
    store <- I.openIngressStore path
    _ <- I.stage store first subject (projection first "on_ready" aaa)
    withDb path $ \db -> exec db "DELETE FROM v5_authority_grants WHERE subject=?" [SQLText subject]
    I.stage store second subject (projection second "on_draft" aaa) `shouldThrow` runtimeError "grant is missing"
    withDb path $ \db -> rows db "SELECT 1 FROM v5_ingress_manifests WHERE delivery_id=?" [SQLText second] `shouldReturn` []
    I.close store

  forM_ [("incarnation", SQLFloat 1.5, "incarnation-1.5"), ("head", SQLBlob "not-text", "head-value1")] $ \(column, value, label) ->
    it ("test_manifest_and_claim_reject_persisted_grant_type_coercion[" <> label <> "]") . withTempRoot $ \tmp -> do
      identity <- newDelivery
      let path = tmp </> "webhooks.sqlite3"
      store <- I.openIngressStore path
      _ <- I.stage store identity subject (projection identity "on_ready" aaa)
      withDb path $ \db -> exec db ("UPDATE v5_authority_grants SET " <> column <> "=? WHERE subject=?") [value, SQLText subject]
      I.manifest store identity subject `shouldThrow` runtimeError "grant is malformed"
      I.claim store subject `shouldThrow` runtimeError "grant is malformed"
      I.close store

  it "test_existing_delivery_cannot_be_staged_for_a_different_subject" . withTempRoot $ \tmp -> do
    identity <- newDelivery
    store <- I.openIngressStore (tmp </> "webhooks.sqlite3")
    _ <- I.stage store identity subject (projection identity "on_ready" aaa)
    I.stage store identity "github:44:31:pr:8" (projection identity "on_ready" aaa) `shouldThrow` runtimeError "different subject"
    I.close store

  it "test_unstaged_inbox_custody_fences_the_claim_until_its_manifest_commits" . withTempRoot $ \tmp -> do
    let path = tmp </> "webhooks.sqlite3"
    store <- I.openIngressStore path
    initial <- newDelivery
    pending <- newDelivery
    _ <- I.stage store initial subject (projection initial "on_ready" aaa)
    withDb path $ \db -> do
      createInbox db
      exec db "INSERT INTO inbox VALUES (?, 'pending', ?)" [SQLText pending, SQLText pendingObservation]
    I.hasUnstagedCustody store subject `shouldReturn` True
    _ <- I.stage store pending subject (projection pending "on_draft" aaa)
    I.hasUnstagedCustody store subject `shouldReturn` False
    I.close store

  it "test_normalizer_freezes_fixed_door_order_and_newest_run_by_v5_identity" $ do
    identity <- newDelivery
    fake <- newFakeAuthority False False False
    let comment = CommentSeen {id = "comment-9", kind = "change", arg = "fix it", authorized = True}
    entries <- I.project (I.V5IngressNormalizer (fakeIngressAuthority fake) ".github/workflows/ci.yml") identity Nothing Nothing (Just comment)
    map (.source) entries `shouldBe` ["on_head", "on_ready", "on_human", "on_runs", "on_comment"]
    readIORef fake.evidenceCalls `shouldReturn` [(10, 1)]
    pullValue <- readIORef fake.pull
    readIORef fake.baseCurrentCalls `shouldReturn` [pullValue]
    payloadMember "strict_base" (firstOf entries) `shouldBe` Just (Bool True)
    payloadMember "base_current" (firstOf entries) `shouldBe` Just (Bool True)
    (entries !! 3).payload `shouldBe` Object [("head", String aaa), ("run_id", Int 10), ("attempt", Int 1), ("conclusion", String "success"), ("fingerprint", String "")]
    all (\e -> e.identity == "github-delivery:" <> identity <> ":" <> e.source) entries `shouldBe` True

  it "test_normalizer_preserves_authenticated_draft_and_ready_edges_after_provider_state_collapses" . withTempRoot $ \tmp -> do
    fake <- newFakeAuthority False False False
    let normalizer = I.V5IngressNormalizer (fakeIngressAuthority fake) ".github/workflows/ci.yml"
    drafted <- newDelivery
    readied <- newDelivery
    draftEntries <- I.project normalizer drafted (Just "pull_request") (Just "converted_to_draft") Nothing
    readyEntries <- I.project normalizer readied (Just "pull_request") (Just "ready_for_review") Nothing
    take 2 (map (.source) draftEntries) `shouldBe` ["on_head", "on_draft"]
    take 2 (map (.source) readyEntries) `shouldBe` ["on_head", "on_ready"]
    store <- I.openIngressStore (tmp </> "webhooks.sqlite3")
    _ <- I.stage store drafted subject draftEntries
    _ <- I.stage store readied subject readyEntries
    c <- I.claim store subject
    (c.phase, c.incarnation) `shouldBe` (PhaseRunning, 2)
    I.close store

  forM_ [(True, False, "closed"), (True, True, "merged")] $ \(closed, merged, reason) ->
    it ("test_normalizer_closes_without_opening_new_work[" <> T.unpack reason <> "]") $ do
      identity <- newDelivery
      fake <- newFakeAuthority False closed merged
      entries <- I.project (I.V5IngressNormalizer (fakeIngressAuthority fake) ".github/workflows/ci.yml") identity Nothing Nothing Nothing
      [(e.source, e.color, e.payload) | e <- entries] `shouldBe` [("on_close", "CloseSeen", Object [("reason", String reason)])]
      readIORef fake.evidenceCalls `shouldReturn` []
