-- | Durable V5 ingress manifests and host-owned authority grants
-- (@host/v5/ingress.py@).
--
-- The three tables live in @webhooks.sqlite3@ beside the webhook inbox and
-- are written with the reference's exact DDL, statements, and JSON
-- spellings (@json.dumps(..., sort_keys=True, separators=(",", ":"))@).
module Hamsterdan.Host.V5.Ingress
  ( -- * Entries
    ProjectedEntry (..)
  , IngressEntry (..)
  , IngressManifest (..)
  , projectedFrom
  , bindEntry
  , ingressFrom
  , entryJson
  , projectedJson
  , loadEntry

    -- * Normalizer
  , IngressAuthority (..)
  , gitHubIngressAuthority
  , V5IngressNormalizer (..)
  , project
  , projectReconciliation

    -- * Store
  , V5IngressStore
  , openIngressStore
  , stage
  , latestReconciliation
  , stageReconciliation
  , manifest
  , claim
  , detachedClaim
  , hasPendingCustody
  , hasUnstagedCustody
  , unstagedCustodyId
  , custodyTerminal
  , preview
  , reduceClaim
  , projectionDigest
  , close
  , setWriteClaimFault

    -- * Doors
  , doorOrder
  , doorColor
  ) where

import Control.Exception (SomeException, mask, onException, throwIO, try)
import Control.Monad (forM, forM_, unless, void, when)
import Data.Char (isDigit)
import Data.IORef
import Data.List (nub, sort)
import Data.Maybe (fromMaybe, isNothing)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Contracts.Codec (Contract, colorOf, dump, spelling, unspelling, validate)
import Hamsterdan.Contracts.ReadinessV5
import Hamsterdan.GitHub.Gateway qualified as Gateway
import Hamsterdan.GitHub.Models
  ( ActionsConclusion (..)
  , ActionsEvidence (..)
  , ActionsRunSnapshot (..)
  , HumanReviewSnapshot (..)
  , PullRequestSnapshot (..)
  , RepositoryPolicy (..)
  )
import Hamsterdan.GitHub.Python (canonicalUuid, casefold, utf8Length)
import Hamsterdan.GitHub.Python qualified as Py
import Hamsterdan.Sqlite (Connection, SQLData (..))
import Hamsterdan.Sqlite qualified as Sql
import Hamsterdan.Host.Python
import Hamsterdan.Host.V5.Claim
import Petrus.Json (Json (..), parseJson, pythonLoads)

-- ---------------------------------------------------------------------------
-- Doors

-- | @_DOOR_ORDER@.
doorOrder :: Text -> Maybe Int
doorOrder = \case
  "on_head" -> Just 0
  "on_draft" -> Just 1
  "on_ready" -> Just 1
  "on_close" -> Just 1
  "on_human" -> Just 2
  "on_runs" -> Just 3
  "on_comment" -> Just 4
  _ -> Nothing

-- | @_DOOR_COLORS@.
doorColor :: Text -> Maybe Text
doorColor = \case
  "on_head" -> Just "HeadSeen"
  "on_draft" -> Just "DraftSeen"
  "on_ready" -> Just "ReadySeen"
  "on_close" -> Just "CloseSeen"
  "on_human" -> Just "HumanSeen"
  "on_runs" -> Just "RunSeen"
  "on_comment" -> Just "CommentSeen"
  _ -> Nothing

lifecycleDoor :: Text -> Bool
lifecycleDoor source = source `elem` ["on_draft", "on_ready", "on_close"]

-- | @TypeAdapter(_DOOR_TYPES[source]).validate_json(...).dump()@.
doorCanonical :: Text -> Json -> Maybe Json
doorCanonical source payload = case source of
  "on_head" -> via (Proxy @HeadSeen)
  "on_draft" -> via (Proxy @DraftSeen)
  "on_ready" -> via (Proxy @ReadySeen)
  "on_close" -> via (Proxy @CloseSeen)
  "on_human" -> via (Proxy @HumanSeen)
  "on_runs" -> via (Proxy @RunSeen)
  "on_comment" -> via (Proxy @CommentSeen)
  _ -> Nothing
  where
    via :: forall a. (Contract a) => Proxy a -> Maybe Json
    via _ = either (const Nothing) (Just . dump) (validate @a payload)

-- ---------------------------------------------------------------------------
-- Entries

-- | @ProjectedEntry@: one canonical door value before a custody source binds
-- its identity.
data ProjectedEntry = ProjectedEntry
  { source :: Text
  , color :: Text
  , payload :: Json
  }
  deriving stock (Eq, Show)

-- | @IngressEntry@: one exact identified delivery frozen by custody.
data IngressEntry = IngressEntry
  { source :: Text
  , color :: Text
  , payload :: Json
  , identity :: Text
  }
  deriving stock (Eq, Show)

-- | @IngressManifest@.
data IngressManifest = IngressManifest
  { sourceId :: Text
  , subject :: Text
  , revision :: Integer
  , entries :: [IngressEntry]
  }
  deriving stock (Eq, Show)

-- | @ProjectedEntry.from_value(source, value)@.
projectedFrom :: forall a. (Contract a) => Text -> a -> ProjectedEntry
projectedFrom source value = ProjectedEntry {source, color = colorOf value, payload = dump value}

-- | @IngressEntry.from_value(source, value, identity)@.
ingressFrom :: forall a. (Contract a) => Text -> a -> Text -> IngressEntry
ingressFrom source value identity = IngressEntry {source, color = colorOf value, payload = dump value, identity}

-- | @ProjectedEntry.bind(source_id)@.
bindEntry :: Text -> ProjectedEntry -> IngressEntry
bindEntry sourceId p = IngressEntry {source = p.source, color = p.color, payload = p.payload, identity = sourceId <> ":" <> p.source}

-- | @IngressEntry.dump()@.
entryJson :: IngressEntry -> Json
entryJson e = Object [("source", String e.source), ("color", String e.color), ("payload", e.payload), ("identity", String e.identity)]

-- | @ProjectedEntry.dump()@.
projectedJson :: ProjectedEntry -> Json
projectedJson p = Object [("source", String p.source), ("color", String p.color), ("payload", p.payload)]

unbind :: IngressEntry -> ProjectedEntry
unbind e = ProjectedEntry {source = e.source, color = e.color, payload = e.payload}

-- | @IngressEntry.load(value)@.
loadEntry :: Json -> IO IngressEntry
loadEntry = \case
  Object members
    | sort (map fst members) == ["color", "identity", "payload", "source"]
    , Just (String source) <- lookup "source" members
    , Just _ <- doorOrder source
    , Just (String color) <- lookup "color" members
    , not (T.null color)
    , Just payload@(Object _) <- lookup "payload" members
    , Just (String identity) <- lookup "identity" members
    , not (T.null identity) ->
        pure IngressEntry {source, color, payload, identity}
  _ -> throwIO (RuntimeError "V5 ingress manifest entry is malformed")

-- ---------------------------------------------------------------------------
-- Normalizer

-- | @IngressAuthority@: the provider reads the normalizer freezes.
data IngressAuthority = IngressAuthority
  { pullRequest :: IO PullRequestSnapshot
  , policy :: Text -> IO RepositoryPolicy
  , baseCurrent :: PullRequestSnapshot -> IO Bool
  , humanReview :: IO HumanReviewSnapshot
  , workflowRuns :: Text -> Text -> IO [ActionsRunSnapshot]
  , actionsEvidence :: ActionsRunSnapshot -> [Text] -> IO ActionsEvidence
  }

-- | The production authority over the GitHub gateway.
gitHubIngressAuthority :: Gateway.GitHubAuthority -> IngressAuthority
gitHubIngressAuthority authority =
  IngressAuthority
    { pullRequest = Gateway.pullRequest authority
    , policy = Gateway.policy authority
    , baseCurrent = Gateway.baseCurrent authority
    , humanReview = Gateway.humanReview authority
    , workflowRuns = Gateway.workflowRuns authority
    , actionsEvidence = Gateway.actionsEvidence authority
    }

-- | @V5IngressNormalizer(authority, workflow_path)@.
data V5IngressNormalizer = V5IngressNormalizer
  { authority :: IngressAuthority
  , workflowPath :: Text
  }

-- | @project(delivery_id, event=..., action=..., comment=...)@.
project :: V5IngressNormalizer -> Text -> Maybe Text -> Maybe Text -> Maybe CommentSeen -> IO [IngressEntry]
project normalizer deliveryId event action comment =
  map (bindEntry ("github-delivery:" <> deliveryId)) <$> projectWith normalizer event action comment

-- | @project_reconciliation()@.
projectReconciliation :: V5IngressNormalizer -> IO [ProjectedEntry]
projectReconciliation normalizer = projectWith normalizer Nothing Nothing Nothing

projectWith :: V5IngressNormalizer -> Maybe Text -> Maybe Text -> Maybe CommentSeen -> IO [ProjectedEntry]
projectWith normalizer event action comment = do
  let authority = normalizer.authority
  pull <- authority.pullRequest
  let closedEdge = event == Just "pull_request" && action == Just "closed"
  if closedEdge || pull.closed || pull.merged
    then pure [projectedFrom "on_close" CloseSeen {reason = if pull.merged then "merged" else "closed"}]
    else do
      policy <- authority.policy pull.baseRef
      current <- authority.baseCurrent pull
      let lifecycle
            | event == Just "pull_request" && action == Just "converted_to_draft" = "on_draft"
            | event == Just "pull_request" && action == Just "ready_for_review" = "on_ready"
            | pull.draft = "on_draft"
            | otherwise = "on_ready" :: Text
          headEntry =
            projectedFrom
              "on_head"
              HeadSeen
                { head = pull.head
                , base = pull.base
                , mergeable = pull.mergeable == Bool True
                , policy = policy.digest
                , strictBase = policy.strict || policy.updateRequired
                , baseCurrent = current
                }
          lifecycleEntry = if lifecycle == "on_draft" then projectedFrom "on_draft" DraftSeen else projectedFrom "on_ready" ReadySeen
      review <- authority.humanReview
      let author = casefold pull.author
          approvals = nub [casefold name | name <- review.approvals, casefold name /= author]
          unresolved = fromMaybe (if policy.conversationResolution then 1 else 0) review.unresolvedThreads
          humanEntry =
            projectedFrom
              "on_human"
              HumanSeen
                { approval = toInteger (length approvals) >= policy.requiredApprovals && null review.requestedReviewers
                , changesRequested = not (null review.changesRequested)
                , unresolved = toInteger unresolved
                }
      runs <- authority.workflowRuns normalizer.workflowPath pull.head
      runEntries <- case runs of
        [] -> pure []
        _ -> do
          let newest = foldr1 (\a b -> if (a.id, a.attempt) >= (b.id, b.attempt) then a else b) runs
          evidence <- authority.actionsEvidence newest policy.requiredChecks
          let fingerprint
                | evidence.conclusion == Failure =
                    sha256Hex . dumpsSorted $
                      Array [Array [String name, maybe Null String conclusion] | (name, conclusion) <- evidence.failedRequiredJobs]
                | otherwise = ""
          pure
            [ projectedFrom
                "on_runs"
                RunSeen
                  { head = evidence.run.head
                  , runId = evidence.run.id
                  , attempt = evidence.run.attempt
                  , conclusion = conclusionOf evidence.conclusion
                  , fingerprint
                  }
            ]
      let commentEntries = maybe [] (\c -> [projectedFrom "on_comment" c]) comment
      pure ([headEntry, lifecycleEntry, humanEntry] <> runEntries <> commentEntries)
  where
    conclusionOf = \case
      Queued -> RunQueued
      InProgress -> RunInProgress
      Success -> RunSuccess
      Failure -> RunFailure

-- ---------------------------------------------------------------------------
-- Store

data StoredGrant = StoredGrant
  { claim :: CurrentClaim
  , revision :: Integer
  , sourceKind :: Maybe Text
  , sourceId :: Maybe Text
  }

-- | @V5IngressStore(path)@.
data V5IngressStore = V5IngressStore
  { db :: Connection
  , legacySourceDelivery :: Bool
  , writeClaimFault :: IORef (Maybe SomeException)
  }

-- | A test seam standing in for the reference's monkeypatched
-- @_write_claim@: the next grant write raises this exception.
setWriteClaimFault :: V5IngressStore -> Maybe SomeException -> IO ()
setWriteClaimFault store = writeIORef store.writeClaimFault

columnNames :: Connection -> Text -> IO [Text]
columnNames db table = do
  rows <- Sql.query db ("PRAGMA table_info(" <> table <> ")") []
  pure [name | _ : SQLText name : _ <- rows]

-- | Open (and migrate) the ingress tables of @webhooks.sqlite3@.
openIngressStore :: FilePath -> IO V5IngressStore
openIngressStore path = do
  db <- Sql.open (T.pack path)
  flip onException (Sql.close db) $ do
    Sql.script
      db
      "\n\
      \                PRAGMA journal_mode=WAL;\n\
      \                CREATE TABLE IF NOT EXISTS v5_ingress_manifests (\n\
      \                  delivery_id TEXT PRIMARY KEY,\n\
      \                  subject TEXT NOT NULL,\n\
      \                  revision INTEGER NOT NULL,\n\
      \                  topology TEXT NOT NULL,\n\
      \                  schema_version INTEGER NOT NULL,\n\
      \                  entries TEXT NOT NULL,\n\
      \                  UNIQUE(subject, revision)\n\
      \                );\n\
      \                CREATE TABLE IF NOT EXISTS v5_authority_grants (\n\
      \                  subject TEXT PRIMARY KEY,\n\
      \                  phase TEXT NOT NULL,\n\
      \                  incarnation INTEGER NOT NULL,\n\
      \                  head TEXT NOT NULL,\n\
      \                  base TEXT NOT NULL,\n\
      \                  policy TEXT NOT NULL,\n\
      \                  revision INTEGER NOT NULL,\n\
      \                  source_kind TEXT NOT NULL,\n\
      \                  source_id TEXT NOT NULL\n\
      \                );\n\
      \                CREATE TABLE IF NOT EXISTS v5_reconciliation_manifests (\n\
      \                  source_id TEXT PRIMARY KEY,\n\
      \                  subject TEXT NOT NULL,\n\
      \                  revision INTEGER NOT NULL,\n\
      \                  digest TEXT NOT NULL,\n\
      \                  topology TEXT NOT NULL,\n\
      \                  schema_version INTEGER NOT NULL,\n\
      \                  entries TEXT NOT NULL,\n\
      \                  UNIQUE(subject, revision)\n\
      \                );\n\
      \                "
    grantColumns <- columnNames db "v5_authority_grants"
    manifestColumns <- columnNames db "v5_ingress_manifests"
    let hasKind = "source_kind" `elem` grantColumns
        hasId = "source_id" `elem` grantColumns
        legacyPointer = not hasKind && not hasId
        legacyManifest = "revision" `notElem` manifestColumns
        partial = throwIO (RuntimeError "V5 source pointer migration is partial")
    when (hasKind /= hasId || legacyPointer /= legacyManifest) partial
    when legacyPointer $ do
      unless ("source_delivery" `elem` grantColumns) partial
      -- The reference's legacy-mode connection autocommits the DDL and
      -- opens its implicit transaction at the first UPDATE.
      Sql.script db "ALTER TABLE v5_ingress_manifests ADD COLUMN revision INTEGER"
      Sql.script db "BEGIN"
      flip onException (void (try @SomeException (Sql.script db "ROLLBACK"))) $ do
        void $
          Sql.execute
            db
            "UPDATE v5_ingress_manifests AS current SET revision=(SELECT COUNT(*) FROM v5_ingress_manifests AS prior WHERE prior.subject=current.subject AND prior.rowid<=current.rowid)"
            []
        malformed <-
          Sql.query
            db
            "SELECT 1 FROM v5_authority_grants AS grant_row LEFT JOIN v5_ingress_manifests AS manifest ON manifest.delivery_id=grant_row.source_delivery AND manifest.subject=grant_row.subject AND manifest.revision=grant_row.revision WHERE manifest.delivery_id IS NULL OR grant_row.revision!=(SELECT COUNT(*) FROM v5_ingress_manifests WHERE subject=grant_row.subject) LIMIT 1"
            []
        orphan <-
          Sql.query
            db
            "SELECT 1 FROM v5_ingress_manifests AS manifest LEFT JOIN v5_authority_grants AS grant_row ON grant_row.subject=manifest.subject WHERE grant_row.subject IS NULL LIMIT 1"
            []
        unless (null malformed && null orphan) $ throwIO (RuntimeError "V5 legacy authority lineage is malformed")
        Sql.script db "ALTER TABLE v5_authority_grants ADD COLUMN source_kind TEXT"
        Sql.script db "ALTER TABLE v5_authority_grants ADD COLUMN source_id TEXT"
        void $ Sql.execute db "UPDATE v5_authority_grants SET source_kind='github-delivery',source_id=source_delivery" []
        Sql.script db "CREATE UNIQUE INDEX IF NOT EXISTS v5_ingress_manifest_subject_revision ON v5_ingress_manifests(subject,revision)"
        Sql.script db "COMMIT"
    unless legacyPointer $
      Sql.script db "CREATE UNIQUE INDEX IF NOT EXISTS v5_ingress_manifest_subject_revision ON v5_ingress_manifests(subject,revision)"
    fault <- newIORef Nothing
    pure V5IngressStore {db, legacySourceDelivery = "source_delivery" `elem` grantColumns, writeClaimFault = fault}

-- | A deferred @BEGIN@ ... @COMMIT@ under the lock.
deferred :: Connection -> IO a -> IO a
deferred db action = Sql.withLock db $ mask $ \restore -> do
  Sql.script db "BEGIN"
  result <- restore action `onException` void (try @SomeException (Sql.script db "ROLLBACK"))
  Sql.script db "COMMIT"
  pure result

encodeEntries :: [IngressEntry] -> Text
encodeEntries = dumpsSortedText . Array . map entryJson

-- | @stage(delivery_id, subject, entries)@.
stage :: V5IngressStore -> Text -> Text -> [IngressEntry] -> IO IngressManifest
stage store deliveryId subject entries = do
  canonical <- validateDelivery deliveryId subject entries False
  let db = store.db
  immediate db $ do
    row <- Sql.query db "SELECT subject,revision,topology,schema_version,entries FROM v5_ingress_manifests WHERE delivery_id=?" [SQLText canonical]
    case row of
      stored : _ -> do
        existing <- loadManifest canonical stored
        when (existing.subject /= subject) $ throwIO (RuntimeError "V5 ingress delivery belongs to a different subject")
        void (claimRow store subject True)
        pure existing
      [] -> do
        current <- claimRow store subject False
        let revision = current.revision + 1
        void $
          Sql.execute
            db
            "INSERT INTO v5_ingress_manifests(delivery_id,subject,revision,topology,schema_version,entries) VALUES(?,?,?,?,?,?)"
            [SQLText canonical, SQLText subject, int revision, SQLText "v5", SQLInteger 1, SQLText (encodeEntries entries)]
        reduced <- either throwIO pure (reduceClaim current.claim entries)
        writeClaim store subject reduced revision "github-delivery" canonical
        pure IngressManifest {sourceId = canonical, subject, revision, entries}

-- | @latest_reconciliation(subject)@.
latestReconciliation :: V5IngressStore -> Text -> IO (Maybe IngressManifest)
latestReconciliation store subject = do
  validateSubject subject
  deferred store.db $ do
    current <- claimRow store subject False
    case (current.sourceKind, current.sourceId) of
      (Just "host-reconcile", Just sourceId) -> Just <$> reconciliationManifest store sourceId subject
      _ -> pure Nothing

-- | @stage_reconciliation(subject, projected)@: 'Nothing' when webhook
-- custody is pending for the subject.
stageReconciliation :: V5IngressStore -> Text -> [ProjectedEntry] -> IO (Maybe IngressManifest)
stageReconciliation store subject projected = do
  validateSubject subject
  digest <- either throwIO pure (projectionDigest projected False)
  let db = store.db
  immediate db $ do
    pending <- pendingCustodyRow store subject
    if pending
      then pure Nothing
      else do
        current <- claimRow store subject False
        reused <- case (current.sourceKind, current.sourceId) of
          (Just "host-reconcile", Just sourceId) -> do
            latest <- reconciliationManifest store sourceId subject
            row <- Sql.query db "SELECT digest FROM v5_reconciliation_manifests WHERE source_id=?" [SQLText sourceId]
            pure (if row == [[SQLText digest]] then Just latest else Nothing)
          _ -> pure Nothing
        case reused of
          Just latest -> pure (Just latest)
          Nothing -> do
            let revision = current.revision + 1
                sourceId = "host-reconcile:" <> subject <> ":" <> tshow revision <> ":" <> digest
                entries = map (bindEntry sourceId) projected
            validateReconciliation sourceId subject revision digest entries False
            void $
              Sql.execute
                db
                "INSERT INTO v5_reconciliation_manifests(source_id,subject,revision,digest,topology,schema_version,entries) VALUES(?,?,?,?,?,?,?)"
                [SQLText sourceId, SQLText subject, int revision, SQLText digest, SQLText "v5", SQLInteger 1, SQLText (encodeEntries entries)]
            reduced <- either throwIO pure (reduceClaim current.claim entries)
            writeClaim store subject reduced revision "host-reconcile" sourceId
            pure (Just IngressManifest {sourceId, subject, revision, entries})

canonicalDelivery :: Text -> Either ValueError Text
canonicalDelivery deliveryId = case canonicalUuid deliveryId of
  Just canonical | canonical == deliveryId -> Right canonical
  _ -> Left (ValueError "V5 ingress delivery identity is malformed")

-- | @manifest(delivery_id, subject)@.
manifest :: V5IngressStore -> Text -> Text -> IO (Maybe IngressManifest)
manifest store deliveryId subject = do
  canonical <- either throwIO pure (canonicalDelivery deliveryId)
  let db = store.db
  deferred db $ do
    row <- Sql.query db "SELECT subject,revision,topology,schema_version,entries FROM v5_ingress_manifests WHERE delivery_id=?" [SQLText canonical]
    case row of
      stored : _ -> do
        loaded <- loadManifest canonical stored
        when (loaded.subject /= subject) $ throwIO (RuntimeError "V5 ingress delivery belongs to a different subject")
        void (claimRow store subject True)
        pure (Just loaded)
      [] -> pure Nothing

-- | @claim(subject)@.
claim :: V5IngressStore -> Text -> IO CurrentClaim
claim store subject = Sql.withLock store.db $ (.claim) <$> claimRow store subject True

-- | @detached_claim(subject)@.
detachedClaim :: V5IngressStore -> Text -> IO (Maybe CurrentClaim)
detachedClaim store subject = Sql.withLock store.db $ do
  stored <- claimRow store subject False
  pure (if stored.revision == 0 then Nothing else Just stored.claim)

-- | @has_pending_custody(subject)@.
hasPendingCustody :: V5IngressStore -> Text -> IO Bool
hasPendingCustody store subject = do
  validateSubject subject
  Sql.withLock store.db (pendingCustodyRow store subject)

-- | @has_unstaged_custody(subject)@.
hasUnstagedCustody :: V5IngressStore -> Text -> IO Bool
hasUnstagedCustody store subject = (/= Nothing) <$> unstagedCustodyId store subject

subjectParts :: Text -> Maybe (Integer, Integer, Integer)
subjectParts subject = case T.splitOn ":" subject of
  ["github", a, b, "pr", c] -> (,,) <$> positive a <*> positive b <*> positive c
  _ -> Nothing
  where
    positive t = case T.uncons t of
      Just (first, _) | first >= '1' && first <= '9', T.all (\ch -> ch >= '0' && ch <= '9') t -> Just (read (T.unpack t))
      _ -> Nothing

subjectPartsIO :: Text -> IO (Integer, Integer, Integer)
subjectPartsIO subject = maybe (throwIO (ValueError "V5 ingress subject is malformed")) pure (subjectParts subject)

inboxExists :: Connection -> IO Bool
inboxExists db = not . null <$> Sql.query db "SELECT 1 FROM sqlite_master WHERE type='table' AND name='inbox'" []

-- | @unstaged_custody_id(subject)@.
unstagedCustodyId :: V5IngressStore -> Text -> IO (Maybe Text)
unstagedCustodyId store subject = do
  (installation, repository, pull) <- subjectPartsIO subject
  let db = store.db
  row <- Sql.withLock db $ do
    present <- inboxExists db
    if not present
      then pure []
      else
        Sql.query
          db
          "SELECT i.delivery_id FROM inbox i LEFT JOIN v5_ingress_manifests m ON m.delivery_id=i.delivery_id AND m.subject=? WHERE i.status='pending' AND m.delivery_id IS NULL AND json_extract(i.observation,'$.installation_id')=? AND json_extract(i.observation,'$.repository_id')=? AND json_extract(i.observation,'$.pull_request_number')=? ORDER BY i.rowid LIMIT 1"
          [SQLText subject, int installation, int repository, int pull]
  case row of
    [] -> pure Nothing
    (SQLText deliveryId : _) : _
      | Just canonical <- canonicalUuid deliveryId
      , canonical == deliveryId ->
          pure (Just canonical)
    _ -> throwIO (RuntimeError "V5 unstaged custody identity is malformed")

-- | @custody_terminal(subject, delivery_id)@.
custodyTerminal :: V5IngressStore -> Text -> Text -> IO Bool
custodyTerminal store subject deliveryId = do
  (installation, repository, pull) <- subjectPartsIO subject
  canonical <- either throwIO pure (canonicalDelivery deliveryId)
  let db = store.db
  row <- Sql.withLock db $ do
    present <- inboxExists db
    unless present $ throwIO (RuntimeError "V5 deferred custody row is unavailable")
    Sql.query
      db
      "SELECT status,json_extract(observation,'$.installation_id'),json_extract(observation,'$.repository_id'),json_extract(observation,'$.pull_request_number') FROM inbox WHERE delivery_id=?"
      [SQLText canonical]
  case row of
    (status : rest) : _
      | rest == [int installation, int repository, int pull] -> case status of
          SQLText "pending" -> pure False
          SQLText "terminal" -> pure True
          _ -> throwIO (RuntimeError "V5 deferred custody status is malformed")
    _ -> throwIO (RuntimeError "V5 deferred custody row differs from its subject")

-- | @preview(subject, entries)@.
preview :: V5IngressStore -> Text -> [IngressEntry] -> IO CurrentClaim
preview store subject entries = Sql.withLock store.db $ do
  current <- claimRow store subject False
  either throwIO pure (reduceClaim current.claim entries)

claimRow :: V5IngressStore -> Text -> Bool -> IO StoredGrant
claimRow store subject required = do
  let db = store.db
      legacyColumn = if store.legacySourceDelivery then ",source_delivery" else ""
  rows <-
    Sql.query
      db
      ("SELECT phase,incarnation,head,base,policy,revision,source_kind,source_id" <> legacyColumn <> " FROM v5_authority_grants WHERE subject=?")
      [SQLText subject]
  case rows of
    [] -> do
      prior <- Sql.query db "SELECT 1 FROM v5_ingress_manifests WHERE subject=? UNION ALL SELECT 1 FROM v5_reconciliation_manifests WHERE subject=? LIMIT 1" [SQLText subject, SQLText subject]
      when (required || not (null prior)) $ throwIO (RuntimeError "V5 authority grant is missing")
      pure StoredGrant {claim = CurrentClaim PhaseRunning 0 "" "" "", revision = 0, sourceKind = Nothing, sourceId = Nothing}
    row : _ -> do
      let malformed = throwIO (RuntimeError "V5 authority grant is malformed")
      case row of
        SQLText spelled : SQLInteger incarnation : SQLText head' : SQLText base : SQLText policy : SQLInteger revision : SQLText sourceKind : SQLText sourceId : legacy
          | Just phase <- unspelling spelled
          , incarnation >= 0
          , revision >= 1
          , sourceKind `elem` ["github-delivery", "host-reconcile"]
          , not store.legacySourceDelivery || legacy == [SQLText sourceId] -> do
              validateLineage db subject (toInteger revision) sourceKind sourceId
              if sourceKind == "github-delivery"
                then do
                  canonicalSource <- maybe malformed pure (canonicalUuid sourceId)
                  source <- Sql.query db "SELECT subject,revision,topology,schema_version,entries FROM v5_ingress_manifests WHERE delivery_id=?" [SQLText sourceId]
                  case source of
                    stored : _ -> do
                      loaded <- loadManifest sourceId stored
                      when (canonicalSource /= sourceId || loaded.subject /= subject || loaded.revision /= toInteger revision) malformed
                    [] -> malformed
                else do
                  loaded <- reconciliationManifest store sourceId subject
                  when (loaded.sourceId /= sourceId || loaded.revision /= toInteger revision) malformed
              pure
                StoredGrant
                  { claim = CurrentClaim phase (toInteger incarnation) head' base policy
                  , revision = toInteger revision
                  , sourceKind = Just sourceKind
                  , sourceId = Just sourceId
                  }
        _ -> malformed

validateLineage :: Connection -> Text -> Integer -> Text -> Text -> IO ()
validateLineage db subject revision sourceKind sourceId = do
  lineage <-
    Sql.query
      db
      "SELECT revision,'github-delivery',delivery_id FROM v5_ingress_manifests WHERE subject=? UNION ALL SELECT revision,'host-reconcile',source_id FROM v5_reconciliation_manifests WHERE subject=? ORDER BY revision"
      [SQLText subject, SQLText subject]
  let malformed = throwIO (RuntimeError "V5 authority grant is malformed")
  when (toInteger (length lineage) /= revision) malformed
  forM_ (zip [1 :: Integer ..] lineage) $ \(expected, item) -> case item of
    [SQLInteger observed, SQLText kind, SQLText _]
      | toInteger observed == expected
      , kind `elem` ["github-delivery", "host-reconcile"] ->
          pure ()
    _ -> malformed
  case reverse lineage of
    (_ : rest) : _ | rest == [SQLText sourceKind, SQLText sourceId] -> pure ()
    _ -> malformed

pendingCustodyRow :: V5IngressStore -> Text -> IO Bool
pendingCustodyRow store subject = do
  (installation, repository, pull) <- subjectPartsIO subject
  let db = store.db
  present <- inboxExists db
  if not present
    then pure False
    else
      not . null
        <$> Sql.query
          db
          "SELECT 1 FROM inbox WHERE status='pending' AND json_extract(observation,'$.installation_id')=? AND json_extract(observation,'$.repository_id')=? AND json_extract(observation,'$.pull_request_number')=? LIMIT 1"
          [int installation, int repository, int pull]

writeClaim :: V5IngressStore -> Text -> CurrentClaim -> Integer -> Text -> Text -> IO ()
writeClaim store subject c revision sourceKind sourceId = do
  fault <- readIORef store.writeClaimFault
  forM_ fault throwIO
  let values =
        [ SQLText subject
        , SQLText (spelling c.phase)
        , int c.incarnation
        , SQLText c.head
        , SQLText c.base
        , SQLText c.policy
        , int revision
        , SQLText sourceKind
        , SQLText sourceId
        ]
  if store.legacySourceDelivery
    then
      void $
        Sql.execute
          store.db
          "INSERT INTO v5_authority_grants(subject,phase,incarnation,head,base,policy,revision,source_kind,source_id,source_delivery) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(subject) DO UPDATE SET phase=excluded.phase,incarnation=excluded.incarnation,head=excluded.head,base=excluded.base,policy=excluded.policy,revision=excluded.revision,source_kind=excluded.source_kind,source_id=excluded.source_id,source_delivery=excluded.source_delivery"
          (values <> [SQLText sourceId])
    else
      void $
        Sql.execute
          store.db
          "INSERT INTO v5_authority_grants(subject,phase,incarnation,head,base,policy,revision,source_kind,source_id) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(subject) DO UPDATE SET phase=excluded.phase,incarnation=excluded.incarnation,head=excluded.head,base=excluded.base,policy=excluded.policy,revision=excluded.revision,source_kind=excluded.source_kind,source_id=excluded.source_id"
          values

-- | @V5IngressStore._reduce(claim, entries)@.
reduceClaim :: CurrentClaim -> [IngressEntry] -> Either ValueError CurrentClaim
reduceClaim = go
  where
    go current [] = Right current
    go current (entry : rest) = case entry.source of
      "on_head" -> do
        (h, b, p) <- case entry.payload of
          Object members
            | Just h <- lookup "head" members
            , Just b <- lookup "base" members
            , Just p <- lookup "policy" members ->
                Right (Py.str h, Py.str b, Py.str p)
          _ -> Left (ValueError "V5 head ingress payload is malformed")
        let next
              | current.phase == PhaseTerminal = current
              | current.phase == PhaseQuiescent || h == current.head = CurrentClaim current.phase current.incarnation h b p
              | otherwise = CurrentClaim PhaseRunning (current.incarnation + 1) h b p
        go next rest
      "on_draft" | current.phase == PhaseRunning -> go (CurrentClaim PhaseQuiescent current.incarnation current.head current.base current.policy) rest
      "on_ready" | current.phase == PhaseQuiescent -> go (CurrentClaim PhaseRunning (current.incarnation + 1) current.head current.base current.policy) rest
      "on_close" -> go (CurrentClaim PhaseTerminal current.incarnation current.head current.base current.policy) rest
      _ -> go current rest

validateDelivery :: Text -> Text -> [IngressEntry] -> Bool -> IO Text
validateDelivery deliveryId subject entries allowLegacyHead = do
  canonical <- either throwIO pure (canonicalDelivery deliveryId)
  validateSubject subject
  when (canonical /= deliveryId) $ throwIO (ValueError "V5 ingress subject is malformed")
  either throwIO pure (validateValues (map unbind entries) True allowLegacyHead)
  when (any (\e -> e.identity /= "github-delivery:" <> canonical <> ":" <> e.source) entries) $
    throwIO (ValueError "V5 ingress door order or identity is malformed")
  pure canonical

validateSubject :: Text -> IO ()
validateSubject subject =
  when (utf8Length subject > 900 || isNothing (subjectParts subject)) $
    throwIO (ValueError "V5 ingress subject is malformed")

validateValues :: [ProjectedEntry] -> Bool -> Bool -> Either ValueError ()
validateValues entries allowComment allowLegacyHead = do
  let sources = map (.source) entries
      order = map (fromMaybe (-1) . doorOrder) sources
      closedBatches = if allowComment then [["on_close"], ["on_close", "on_comment"]] else [["on_close"]]
      openTails = if allowComment then [[], ["on_runs"], ["on_comment"], ["on_runs", "on_comment"]] else [[], ["on_runs"]]
      complete =
        sources `elem` closedBatches
          || ( case sources of
                 first : second : third : tailSources ->
                   first == "on_head" && second `elem` ["on_draft", "on_ready"] && third == "on_human" && tailSources `elem` openTails
                 _ -> False
             )
      orderError = Left (ValueError "V5 ingress door order or identity is malformed")
  when
    ( null entries
        || any (< 0) order
        || order /= sort order
        || length sources /= length (nub sources)
        || length (filter lifecycleDoor sources) > 1
        || any (\e -> doorColor e.source /= Just e.color) entries
    )
    orderError
  unless complete $ Left (ValueError "V5 ingress manifest is not a complete batch")
  forM_ entries $ \entry -> do
    dumped <- maybe (Left (ValueError "V5 ingress door payload is malformed")) Right (doorCanonical entry.source entry.payload)
    let legacyHead =
          allowLegacyHead
            && entry.source == "on_head"
            && ( case (entry.payload, dumped) of
                   (Object members, Object canonicalMembers) ->
                     sort (map fst members) == ["base", "head", "mergeable", "policy"]
                       && all (\(k, v) -> lookup k canonicalMembers == Just v) members
                       && lookup "strict_base" canonicalMembers == Just (Bool True)
                       && lookup "base_current" canonicalMembers == Just (Bool False)
                   _ -> False
               )
    when (dumped /= entry.payload && not legacyHead) $ Left (ValueError "V5 ingress door payload is not canonical")

-- | @V5IngressStore._projection_digest(projected)@.
projectionDigest :: [ProjectedEntry] -> Bool -> Either ValueError Text
projectionDigest projected allowLegacyHead = do
  validateValues projected False allowLegacyHead
  pure . sha256Hex . dumpsSorted $
    Object
      [ ("topology", String "v5")
      , ("schema_version", Int 1)
      , ("entries", Array (map projectedJson projected))
      ]

validateReconciliation :: Text -> Text -> Integer -> Text -> [IngressEntry] -> Bool -> IO ()
validateReconciliation sourceId subject revision digest entries allowLegacyHead = do
  validateSubject subject
  let malformed = throwIO (RuntimeError "V5 reconciliation manifest is malformed")
  when
    ( revision < 1
        || not (T.length digest == 64 && T.all (\c -> isDigit c || (c >= 'a' && c <= 'f')) digest)
        || sourceId /= "host-reconcile:" <> subject <> ":" <> tshow revision <> ":" <> digest
        || any (\e -> e.identity /= sourceId <> ":" <> e.source) entries
    )
    malformed
  case projectionDigest (map unbind entries) allowLegacyHead of
    Right computed | computed == digest -> pure ()
    _ -> malformed

reconciliationManifest :: V5IngressStore -> Text -> Text -> IO IngressManifest
reconciliationManifest store sourceId subject = do
  rows <- Sql.query store.db "SELECT subject,revision,digest,topology,schema_version,entries FROM v5_reconciliation_manifests WHERE source_id=?" [SQLText sourceId]
  case rows of
    [] -> throwIO (RuntimeError "V5 reconciliation manifest is missing")
    row : _ -> case row of
      [SQLText storedSubject, SQLInteger revision, SQLText digest, SQLText "v5", SQLInteger 1, SQLText encoded]
        | storedSubject == subject -> do
            raw <- case parseJson pythonLoads (TE.encodeUtf8 encoded) of
              Left _ -> throwIO (RuntimeError "V5 reconciliation manifest is malformed")
              Right value -> pure value
            values <- case raw of
              Array values -> pure values
              _ -> throwIO (TypeError "V5 reconciliation manifest is malformed")
            entries <- forM values loadEntry
            validateReconciliation sourceId subject (toInteger revision) digest entries True
            pure IngressManifest {sourceId, subject, revision = toInteger revision, entries}
      _ -> throwIO (RuntimeError "V5 reconciliation manifest is incompatible")

loadManifest :: Text -> [SQLData] -> IO IngressManifest
loadManifest deliveryId = \case
  [SQLText subject, SQLInteger revision, SQLText "v5", SQLInteger 1, SQLText encoded]
    | revision >= 1 -> do
        raw <- case parseJson pythonLoads (TE.encodeUtf8 encoded) of
          Left _ -> throwIO (RuntimeError "V5 ingress manifest is malformed")
          Right value -> pure value
        values <- case raw of
          Array values -> pure values
          _ -> throwIO (TypeError "V5 ingress manifest is malformed")
        entries <- forM values loadEntry
        void (validateDelivery deliveryId subject entries True)
        pure IngressManifest {sourceId = deliveryId, subject, revision = toInteger revision, entries}
  _ -> throwIO (RuntimeError "V5 ingress manifest is incompatible")

close :: V5IngressStore -> IO ()
close store = Sql.close store.db

int :: Integer -> SQLData
int = SQLInteger . fromInteger

tshow :: (Show a) => a -> Text
tshow = T.pack . show
