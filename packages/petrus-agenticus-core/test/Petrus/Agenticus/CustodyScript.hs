{-# LANGUAGE RecordWildCards #-}

-- | The step interpreter of @differential/custody_corpus.py@: one custody
-- installation under a work directory, deterministic stateless key
-- operations, and a pure fake provider, so a scripted session replays
-- byte-for-byte and can move between implementations mid-run.
module Petrus.Agenticus.CustodyScript
  ( runSteps
  , observeStore
  , canonical
  , member
  , members
  , corpusKeys
  , compareRecords
  ) where

import Control.Exception (SomeException, evaluate, finally, fromException, try)
import Control.Monad (unless, zipWithM_)
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.IORef
import Data.List (sort, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Agenticus.Connection.Custody
import Petrus.Agenticus.Connection.Key
import Petrus.Agenticus.Connection.Materialization
import Petrus.Agenticus.Connection.Storage
import Petrus.Agenticus.ConnectionSupport (aesGcmOpen, aesGcmSeal, keyCanary)
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Sqlite qualified as Sql
import Petrus.Agenticus.Internal.Validate (sha256Hex)
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import System.Directory (doesFileExist, listDirectory, pathIsSymbolicLink)
import System.FilePath ((</>))
import Test.Hspec (Expectation, expectationFailure, shouldBe)

-- | Recursively sort object members, so values compare independently of
-- member order (the corpus is written with @sort_keys=True@).
canonical :: Json -> Json
canonical = \case
  Object fields -> Object (sortOn fst [(name, canonical value) | (name, value) <- fields])
  Array items -> Array (map canonical items)
  other -> other

member :: Text -> Json -> Json
member name value = fromMaybe (error ("missing member " <> T.unpack name)) (J.lookupMember name value)

members :: Json -> [Json]
members = \case
  Array items -> items
  other -> error ("expected an array, got " <> show other)

text :: Text -> Json -> Text
text name value = case member name value of
  String t -> t
  other -> error ("expected a string at " <> T.unpack name <> ", got " <> show other)

integer :: Text -> Json -> Integer
integer name value = case member name value of
  Int n -> n
  other -> error ("expected an integer at " <> T.unpack name <> ", got " <> show other)

boolean :: Text -> Json -> Bool
boolean name value = case member name value of
  Bool b -> b
  other -> error ("expected a boolean at " <> T.unpack name <> ", got " <> show other)

-- | @number()@: ints and floats as floats, and the strings @nan@ and @inf@.
number :: Text -> Json -> Double
number name value = case member name value of
  Int n -> fromInteger n
  Float d -> d
  String "nan" -> 0 / 0
  String "inf" -> 1 / 0
  other -> error ("expected a number at " <> T.unpack name <> ", got " <> show other)

-- ---------------------------------------------------------------------------
-- Keys and provider

sha256 :: ByteString -> ByteString
sha256 bytes = BA.convert (hash bytes :: Digest SHA256)

-- | @CorpusKeys@: AES-GCM under the key canary with a nonce derived from the
-- authenticated context and the plaintext, so sealing is a pure function.
corpusKeys :: IORef Bool -> KeyOperations
corpusKeys failErasure =
  KeyOperations
    { seal = \context plaintext -> do
        let aad = authenticatedData context
            nonce = B.take 12 (sha256 ("petrus-custody-corpus-nonce\0" <> aad <> "\0" <> BA.convert plaintext))
        evaluate (aesGcmSeal keyCanary nonce aad plaintext)
    , open = \context ciphertext -> case aesGcmOpen keyCanary (authenticatedData context) ciphertext of
        Just plaintext -> pure plaintext
        Nothing -> throwAgenticus KeyOperationError "encrypted connection state failed integrity verification"
    , erase = \connectionId -> do
        failing <- readIORef failErasure
        if failing
          then throwAgenticus KeyOperationError "synthetic key erasure failed"
          else throwLeft (mkKeyErasureEvidence connectionId True)
    }

providerState :: Text -> Integer -> ByteString
providerState account generation =
  TE.encodeUtf8 $
    T.concat
      [ "{\"access_token\":\"access-"
      , account
      , "-"
      , g
      , "\",\"account\":\""
      , account
      , "\",\"generation\":"
      , g
      , ",\"refresh_token\":\"refresh-"
      , account
      , "-"
      , g
      , "\"}"
      ]
  where
    g = T.pack (show generation)

fingerprint :: Text -> Text
fingerprint account = sha256Hex (TE.encodeUtf8 ("fp-" <> account))

-- ---------------------------------------------------------------------------
-- Sessions

data Session = Session
  { root :: FilePath
  , instant :: IORef Double
  , failErasure :: IORef Bool
  , storage :: ConnectionStorage
  , materializer :: PrivateFileMaterializer
  , custody :: AgentConnectionCustody
  , slots :: IORef (Map Text Materialization)
  }

openSession :: FilePath -> IO Session
openSession workdir = do
  let root = workdir </> "installation"
  instant <- newIORef 1000
  failErasure <- newIORef False
  storage <- openSqliteConnectionStorage (root </> "connections.sqlite3")
  materializer <- newPrivateFileMaterializer (root </> "materialized")
  slots <- newIORef Map.empty
  let custody = agentConnectionCustody storage (corpusKeys failErasure) materializer (readIORef instant)
  pure Session {root, instant, failErasure, storage, materializer, custody, slots}

-- | Rebuild the clock and the live materializations of earlier steps.
resume :: Session -> [Json] -> IO ()
resume session earlier = do
  snapshot <- session.storage.load
  let leases = Map.fromList [(lease.leaseId, lease) | lease <- snapshot.leases]
  mapM_ (restore leases) earlier
  where
    restore leases step = case text "op" step of
      "advance" -> modifyIORef' session.instant (+ number "seconds" step)
      "materialize" -> do
        let operationId = text "operation_id" step
            leaseId = "lease-" <> T.take 32 (sha256Hex (TE.encodeUtf8 operationId))
        current <- readIORef session.slots
        case Map.lookup leaseId leases of
          Just lease
            | not (Map.member operationId current)
            , Just mode <- parseLeaseMode lease.mode ->
                modifyIORef' session.slots $
                  Map.insert operationId $
                    Materialization
                      { fence = fenceOf lease
                      , mode
                      , expiresAt = lease.expiresAt
                      , home = materializedState session.materializer lease.attachmentId
                      }
          _ -> pure ()
      _ -> pure ()

-- | The store as @observe()@ sees it: revision, payload digest (and the full
-- payload on every tenth step and the last), and materialized file names.
observeStore :: FilePath -> Bool -> IO Json
observeStore root full = do
  database <- Sql.openDatabase (root </> "connections.sqlite3")
  row <-
    ( do
        statement <- Sql.prepareStatement database "SELECT revision, payload FROM connection_custody WHERE singleton = 1"
        Sql.queryRow statement [] `finally` Sql.finalizeStatement statement
    )
      `finally` Sql.closeDatabase database
  (revision, payload) <- case row of
    Just [Sql.SQLInteger revision, Sql.SQLText payload] -> pure (toInteger revision, payload)
    other -> fail ("unexpected custody row: " <> show other)
  files <- sort <$> listDirectory (root </> "materialized")
  pure $
    Object $
      [ ("revision", Int revision)
      , ("payload_sha256", String (sha256Hex (TE.encodeUtf8 payload)))
      , ("files", Array (map (String . T.pack) files))
      ]
        <> [("payload", String payload) | full]

-- | @run_steps@: run @steps[start:stop]@ against the installation under the
-- work directory (resuming whatever an earlier run left there) and return
-- one canonical record per step.
runSteps :: FilePath -> [Json] -> Int -> Int -> IO [Json]
runSteps workdir steps start stop = do
  session <- openSession workdir
  ( do
      resume session (take start steps)
      let lastIndex = length steps - 1
      mapM
        ( \(index, step) -> do
            outcome <- runStep session step
            observation <- observeStore session.root (index == lastIndex || (index + 1) `mod` 10 == 0)
            pure (canonical (merge (Object [("outcome", outcome)]) observation))
        )
        (take (stop - start) (drop start (zip [0 ..] steps)))
    )
    `finally` closeCustody session.custody
  where
    merge (Object left) (Object right) = Object (left <> right)
    merge left _ = left

runStep :: Session -> Json -> IO Json
runStep session step =
  try (interpret session step) >>= \case
    Right value -> pure (Object [("ok", value)])
    Left failure -> pure (Object [("error", refusal failure)])
  where
    refusal :: SomeException -> Json
    refusal failure = case fromException failure of
      Just (AgenticusError cls message) -> Object [("class", String (errorClassName cls)), ("message", String message)]
      Nothing -> Object [("class", String "HaskellException"), ("message", String (T.pack (show failure)))]

interpret :: Session -> Json -> IO Json
interpret session step = case text "op" step of
  "advance" -> Null <$ modifyIORef' session.instant (+ number "seconds" step)
  "enroll" -> Null <$ enrollHost custody (text "host" step) operationId
  "remove" -> do
    removal <- removeHost custody (text "host" step) operationId
    pure $
      Object
        [ ("host_id", String removal.hostId)
        , ("canceled_leases", Int (toInteger removal.canceledLeases))
        , ("cleanup", summaryJson removal.cleanup)
        , ("offline_erasure_limit", Bool removal.offlineErasureLimit)
        ]
  op
    | op == "authorize" || op == "rotate" -> do
        state <- newOpaqueState (providerState (text "account" step) (integer "generation" step))
        view <-
          if op == "authorize"
            then do
              identity <-
                throwLeft $
                  mkConnectionIdentity
                    (text "connection" step)
                    "fake-rotating-oauth"
                    (fingerprint (text "account" step))
                    "subscription_oauth"
              authorize custody identity state operationId
            else rotate custody (text "connection" step) state operationId
        erased <- opaqueStateErased state
        pure (Object [("view", viewJson view), ("opaque_erased", Bool erased)])
  "materialize" -> do
    mode <- maybe (fail "unknown lease mode") pure (parseLeaseMode (text "mode" step))
    materialization <- materialize custody (text "connection" step) (text "host" step) mode (number "ttl" step) operationId
    modifyIORef' session.slots (Map.insert operationId materialization)
    home <- readMaterialized materialization.home
    pure $
      Object
        [ ("fence", fenceJson materialization.fence)
        , ("mode", String (leaseModeText materialization.mode))
        , ("expires_at", Float materialization.expiresAt)
        , ("home", String (TE.decodeUtf8 home))
        ]
  "activate" -> do
    m <- slot
    Null <$ activate custody m operationId
  "renew" -> do
    m <- slot
    renewal <- renew custody m (number "ttl" step) operationId
    pure (Object [("expires_at", Float renewal.expiresAt)])
  "refresh_home" -> do
    m <- slot
    current <- readMaterialized m.home
    if B.null current
      then pure (String "empty")
      else do
        state <- either fail pure (J.parseJson J.pythonLoads current)
        let generation = integer "generation" state + 1
        replaceMaterialized m.home (providerState (text "account" state) generation)
        pure (Int generation)
  "empty_home" -> do
    m <- slot
    let path = materializedPath m.home
    exists <- doesFileExist path
    link <- if exists then pathIsSymbolicLink path else pure False
    if exists && not link
      then Bool True <$ B.writeFile path ""
      else pure (Bool False)
  "checkpoint" -> do
    m <- slot
    publication <- checkpoint custody m operationId
    pure (Object [("view", viewJson publication.connection), ("cleanup", evidenceJson publication.cleanup)])
  "release" -> do
    m <- slot
    released <- release custody m operationId
    pure (Object [("cleanup", evidenceJson released.cleanup)])
  "revoke" -> do
    revocation <- revoke custody (text "connection" step) operationId
    pure $
      Object
        [ ("view", viewJson revocation.connection)
        , ("cleanup", summaryJson revocation.cleanup)
        , ("provider_revocation", String revocation.providerRevocation)
        , ("offline_erasure_limit", Bool revocation.offlineErasureLimit)
        ]
  "erase" -> do
    writeIORef session.failErasure (boolean "fail" step)
    erasure <- erase custody (text "connection" step) operationId `finally` writeIORef session.failErasure False
    pure $
      Object
        [ ("view", viewJson erasure.connection)
        ,
          ( "key_erasure"
          , Object
              [ ("connection_id", String erasure.keyErasure.connectionId)
              , ("erased", Bool erasure.keyErasure.erased)
              ]
          )
        , ("cleanup", summaryJson erasure.cleanup)
        , ("physical_media_erasure_guaranteed", Bool erasure.physicalMediaErasureGuaranteed)
        ]
  op
    | op == "admit_result" || op == "admit_effect" -> do
        m <- slot
        let fence
              | boolean "forge" step = forged m.fence
              | otherwise = m.fence
            admit = if op == "admit_result" then admitResult else admitEffect
        admission <- admit custody fence operationId
        pure $
          Object
            [ ("operation_id", String admission.operationId)
            , ("purpose", String admission.purpose)
            , ("attachment_id", String admission.attachmentId)
            ]
  "recover" -> do
    recovery <- recover custody operationId
    pure $
      Object
        [ ("expired_leases", Int (toInteger recovery.expiredLeases))
        , ("ambiguous_connections", Array (map String recovery.ambiguousConnections))
        , ("cleanup", summaryJson recovery.cleanup)
        ]
  "lookup" ->
    lookupOperation custody operationId >>= \case
      Nothing -> pure Null
      Just view ->
        pure $
          Object
            [ ("operation_id", String view.operationId)
            , ("event_kind", String view.eventKind)
            , ("connection_id", maybe Null String view.connectionId)
            , ("host_id", maybe Null String view.hostId)
            , ("lease_id", maybe Null String view.leaseId)
            , ("details", Array [Array [String name, auditValueJson value] | (name, value) <- view.details])
            ]
  "connection" -> viewJson <$> lookupConnection custody (text "connection" step)
  other -> fail ("unknown step " <> T.unpack other)
  where
    custody = session.custody
    operationId = text "operation_id" step
    slot = do
      current <- readIORef session.slots
      maybe (fail "step names a missing materialization") pure (Map.lookup (text "slot" step) current)

forged :: AttachmentFence -> AttachmentFence
forged AttachmentFence {..} = AttachmentFence {attachmentId = "attachment-forged", ..}

viewJson :: ConnectionView -> Json
viewJson view =
  Object
    [ ("connection_id", String view.identity.connectionId)
    , ("provider", String view.identity.provider)
    , ("account_fingerprint", String view.identity.accountFingerprint)
    , ("profile", String view.identity.profile)
    , ("status", String (connectionStatusText view.status))
    , ("authority_epoch", Int view.authorityEpoch)
    , ("state_version", Int view.stateVersion)
    , ("state_digest", maybe Null String view.stateDigest)
    ]

evidenceJson :: CleanupEvidence -> Json
evidenceJson evidence =
  Object
    [ ("attachment_id", String evidence.attachmentId)
    , ("removed", Bool evidence.removed)
    , ("already_absent", Bool evidence.alreadyAbsent)
    , ("bytes_overwritten", Int evidence.bytesOverwritten)
    , ("physical_erasure_guaranteed", Bool evidence.physicalErasureGuaranteed)
    , ("security_violation", Bool evidence.securityViolation)
    ]

summaryJson :: CleanupSummary -> Json
summaryJson summary =
  Object
    [ ("attempted", Int (toInteger summary.attempted))
    , ("removed", Int (toInteger summary.removed))
    , ("already_absent", Int (toInteger summary.alreadyAbsent))
    , ("unresolved", Int (toInteger summary.unresolved))
    , ("security_violations", Int (toInteger summary.securityViolations))
    , ("physical_erasure_guaranteed", Bool summary.physicalErasureGuaranteed)
    ]

fenceJson :: AttachmentFence -> Json
fenceJson fence =
  Object
    [ ("attachment_id", String fence.attachmentId)
    , ("lease_id", String fence.leaseId)
    , ("connection_id", String fence.connectionId)
    , ("host_id", String fence.hostId)
    , ("host_epoch", Int fence.hostEpoch)
    , ("authority_epoch", Int fence.authorityEpoch)
    , ("base_version", Int fence.baseVersion)
    ]

-- | Compare per-step records, reporting the first divergent step.
compareRecords :: [Json] -> Int -> [Json] -> [Json] -> Expectation
compareRecords steps start expected actual = do
  length actual `shouldBe` length expected
  zipWithM_
    ( \index (want, got) ->
        unless (J.exactEq (canonical want) got) $
          expectationFailure $
            "step "
              <> show index
              <> " "
              <> show (steps !! index)
              <> "\nexpected: "
              <> show (canonical want)
              <> "\n  actual: "
              <> show got
    )
    [start ..]
    (zip expected actual)
