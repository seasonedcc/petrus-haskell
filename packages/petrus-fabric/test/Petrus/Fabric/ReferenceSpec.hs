-- | The reference's own tests, ported one for one:
-- upstream/petrus/tests/petrus/fabric/test_fabric.py (12 tests). Each
-- example is named after its Python test. Assertions the port's types make
-- unrepresentable are noted where they fall (DIVERGENCES.md, "Type-enforced
-- refusals"); TypedSpec holds their evidence.
module Petrus.Fabric.ReferenceSpec (spec) where

import Control.Exception (bracket)
import Control.Monad (forM_, void)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (addUTCTime, getCurrentTime)
import Petrus.Fabric
import Petrus.Fabric.Conformance.Setup (neutralLibrary, refusal)
import Petrus.Fabric.DemoSpec (demoRun)
import Petrus.Fabric.Postgres
import Petrus.Impetus.Instance (PriorAcknowledgement (..))
import Petrus.Impetus.Instance.Firing (FiringOutcome (..))
import Petrus.Impetus.Petrinet (Token (..), netPath)
import Petrus.Json (Json (..))
import Petrus.Postgres qualified as Pg
import Petrus.TestSupport (PostgresTarget (..), postgresSpec)
import System.Directory (findExecutable)
import Test.Hspec hiding (pending)

spec :: Spec
spec = describe "upstream tests/petrus/fabric/test_fabric.py" $ do
  it "test_neutral_fabric_import_does_not_attempt_psycopg" (neutralLibrary "petrus-fabric")
  it "test_envelope_is_exact_versioned_detached_strict_json_and_bounded" envelopeContract
  postgresSpec $ do
    it "test_two_authority_process_fabric_acceptance_demo" $ \target -> do
      exe <- findExecutable "cv5-fabric-demo" >>= maybe (fail "cv5-fabric-demo is not on PATH (build-tool-depends)") pure
      void (demoRun exe ["--dsn", BC.unpack target.targetUrl])
    it "test_registration_stores_only_digest_is_idempotent_and_authenticates" (withSchema registration)
    it "test_schema_provisioning_refuses_unknown_or_mismatched_versions" (withSchema schemaVersions)
    it "test_fabric_operations_join_a_caller_transaction_without_committing" $ \target ->
      withSchema (joinedTransaction target) target
    it "test_discovery_and_send_are_deny_by_default_and_capability_filtered" (withParties denyByDefault)
    it "test_exact_retransmission_precedes_current_grant_and_changed_content_conflicts" (withParties retransmission)
    it "test_same_delivery_id_from_distinct_senders_has_distinct_ingress_identity" (withParties distinctSenders)
    it "test_inbox_delivery_acceptance_and_prior_acknowledgement_crash_recovery" (withParties inboxRecovery)
    it "test_acknowledgement_occurrence_conflicts" (withParties occurrenceConflicts)
    it "test_pruning_removes_envelope_but_preserves_receipt_dedup_and_conflict" $ \target ->
      withSchema (\admin -> partiesOn admin >>= pruning admin) target

-- | The autouse fixture: an admin autocommit connection on a schema
-- dropped, then provisioned twice.
withSchema :: (Pg.Connection -> IO a) -> PostgresTarget -> IO a
withSchema action target =
  bracket (Pg.connect target.targetUrl True) Pg.close $ \admin -> do
    Pg.execute_ admin "DROP SCHEMA IF EXISTS impetus_fabric CASCADE" []
    ensureFabricSchema admin
    ensureFabricSchema admin
    action admin

type Parties = Map.Map Text PostgresFabric

partiesOn :: Pg.Connection -> IO Parties
partiesOn admin =
  Map.fromList <$> mapM party ["sender-a", "sender-b", "recipient"]
  where
    party name = do
      credential <- issueCredential
      registerProcess admin name credential
      (name,) <$> postgresFabric admin name credential

withParties :: (Parties -> IO a) -> PostgresTarget -> IO a
withParties action = withSchema (\admin -> partiesOn admin >>= action)

envelopeWith :: Text -> Text -> Json -> IO Envelope
envelopeWith sender deliveryId payload = do
  route <- orThrow (replyRoute sender "replies/finish")
  orThrow (envelope deliveryId sender "recipient" "commands/start" "conversation-1" payload (Just route))

defaultPayload :: Json
defaultPayload = Object [("command", String "go")]

defaultEnvelope :: IO Envelope
defaultEnvelope = envelopeWith "sender-a" "delivery-1" defaultPayload

openRoute :: Parties -> IO ()
openRoute ps = do
  let recipient = ps Map.! "recipient"
  exposeSource recipient "commands/start"
  offerService recipient "commands/start" "worker" (Object [("model", String "large"), ("tools", Array [String "shell"])])
  grant recipient "sender-a" "commands/start"

envelopeContract :: Expectation
envelopeContract = do
  -- Detached and immutable: a Haskell value cannot be mutated after the
  -- envelope is built, nor through the envelope (F-011); rebuilding the
  -- caller's payload leaves the envelope's unchanged.
  let payload = Object [("nested", Array [Int 1, Object [("ok", Bool True)]])]
  item <- envelopeWith "sender-a" "delivery-1" payload
  lookupMember "payload" (envelopeToData item) `shouldBe` Just payload
  envelopeFromData (envelopeToData item) `shouldBe` Right item
  lookupMember "version" (envelopeToData item) `shouldBe` Just (Int 1)
  T.length item.digest `shouldBe` 64
  item.ingressIdentity `shouldBe` "fabric:8:sender-a:delivery-1"
  members <- case envelopeToData item of
    Object ms -> pure ms
    other -> fail ("not an object: " <> show other)
  let changes =
        [ Object (replace "version" (Int 2) members)
        , Object (filter ((/= "source") . fst) members)
        , Object (members <> [("extra", Bool True)])
        , Object (replace "source" (Int 3) members)
        ]
  forM_ changes $ \changed -> case envelopeFromData changed of
    Left e -> errorCategory e `shouldBe` Invalid
    Right _ -> expectationFailure ("accepted " <> show changed)
  -- {7: "non-text key"}: JSON object keys are Text in the port (F-008).
  refusal Invalid ["strict JSON"] (orThrow (envelope "delivery-1" "sender-a" "recipient" "commands/start" "conversation-1" (Object [("bad", Float (0 / 0))]) Nothing))
  -- object() inside a payload: payloads are Json in the port (F-007).
  refusal Invalid ["artifact protocol"] (envelopeWith "sender-a" "delivery-1" (Object [("bytes", String (T.replicate (maxInlinePayloadBytes + 1) "x"))]))
  where
    replace key value = map (\(k, v) -> if k == key then (k, value) else (k, v))

lookupMember :: Text -> Json -> Maybe Json
lookupMember key = \case
  Object members -> lookup key members
  _ -> Nothing

countRows :: Pg.Connection -> Pg.Sql -> IO Int
countRows admin sql =
  Pg.query admin sql [] >>= \case
    [[Just n]] -> either fail (pure . fromIntegral) (Pg.decodeInt n)
    rows -> fail ("unexpected rows " <> show rows)

registration :: Pg.Connection -> Expectation
registration admin = do
  credential <- issueCredential
  BS.length (TE.encodeUtf8 credential) `shouldSatisfy` (>= 32)
  registerProcess admin "process" credential
  registerProcess admin "process" credential
  [[Just stored]] <- Pg.query admin "SELECT credential_digest FROM impetus_fabric.processes WHERE instance_id = 'process'" []
  BS.isInfixOf (TE.encodeUtf8 credential) stored `shouldBe` False
  BS.length stored `shouldBe` 64
  other <- issueCredential
  refusal ConflictCategory ["different credential"] (registerProcess admin "process" other)
  refusal Invalid ["high-entropy"] (registerProcess admin "weak" (T.replicate 40 "x"))
  stranger <- issueCredential
  refusal DeniedCategory ["authentication failed"] (postgresFabric admin "process" stranger >>= \f -> discover f "anything" Nothing)

schemaVersions :: Pg.Connection -> Expectation
schemaVersions admin = do
  Pg.execute_ admin "DROP SCHEMA impetus_fabric CASCADE" []
  Pg.execute_ admin "CREATE SCHEMA impetus_fabric" []
  Pg.execute_ admin "CREATE TABLE impetus_fabric.processes (unknown_shape text)" []
  refusal SchemaRefusedCategory ["unversioned table", "refusing"] (ensureFabricSchema admin)
  Pg.execute_ admin "DROP SCHEMA impetus_fabric CASCADE" []
  ensureFabricSchema admin
  Pg.execute_ admin "UPDATE impetus_fabric.schema_metadata SET version = 999 WHERE component = 'fabric'" []
  refusal SchemaRefusedCategory ["version 999", "migrate deliberately"] (ensureFabricSchema admin)

joinedTransaction :: PostgresTarget -> Pg.Connection -> Expectation
joinedTransaction target admin = do
  credential <- issueCredential
  registerProcess admin "joined" credential
  let exposed = countRows admin "SELECT count(*) FROM impetus_fabric.exposed_sources WHERE instance_id = 'joined'"
  bracket (Pg.connect target.targetUrl False) Pg.close $ \joined -> do
    postgresFabric joined "joined" credential >>= \f -> exposeSource f "inbox"
    exposed `shouldReturn` 0
    Pg.rollback joined
    exposed `shouldReturn` 0
    postgresFabric joined "joined" credential >>= \f -> exposeSource f "inbox"
    Pg.commit joined
    exposed `shouldReturn` 1

denyByDefault :: Parties -> Expectation
denyByDefault ps = do
  let sender = ps Map.! "sender-a"
      recipient = ps Map.! "recipient"
      capabilities = Object [("model", String "large"), ("region", String "eu")]
  exposeSource recipient "commands/start"
  offerService recipient "commands/start" "worker" capabilities
  discover sender "worker" Nothing `shouldReturn` []
  refusal DeniedCategory ["not exposed and granted"] (defaultEnvelope >>= submit sender)
  grant recipient "sender-a" "commands/start"
  expected <- orThrow (endpoint "recipient" "commands/start" capabilities)
  discover sender "worker" (Just (Object [("model", String "large")])) `shouldReturn` [expected]
  discover sender "worker" (Just (Object [("model", String "small")])) `shouldReturn` []
  (defaultEnvelope >>= submit sender) `shouldReturn` Submission "sender-a" "delivery-1" Pending False Nothing Nothing

retransmission :: Parties -> Expectation
retransmission ps = do
  openRoute ps
  let sender = ps Map.! "sender-a"
      recipient = ps Map.! "recipient"
  first <- defaultEnvelope >>= send sender
  revoke recipient "sender-a" "commands/start"
  first.duplicate `shouldBe` False
  (defaultEnvelope >>= send sender) `shouldReturn` Submission "sender-a" "delivery-1" Pending True Nothing Nothing
  refusal ConflictCategory ["identity conflict"] (envelopeWith "sender-a" "delivery-1" (Object [("command", String "changed")]) >>= send sender)
  refusal DeniedCategory [] (envelopeWith "sender-a" "delivery-2" defaultPayload >>= send sender)

distinctSenders :: Parties -> Expectation
distinctSenders ps = do
  let recipient = ps Map.! "recipient"
  exposeSource recipient "commands/start"
  grant recipient "sender-a" "commands/start"
  grant recipient "sender-b" "commands/start"
  _ <- envelopeWith "sender-a" "same" defaultPayload >>= send (ps Map.! "sender-a")
  _ <- envelopeWith "sender-b" "same" defaultPayload >>= send (ps Map.! "sender-b")
  identities <- map (.ingressIdentity) <$> pending recipient 100
  identities `shouldMatchList` ["fabric:8:sender-a:same", "fabric:8:sender-b:same"]

inboxRecovery :: Parties -> Expectation
inboxRecovery ps = do
  openRoute ps
  _ <- defaultEnvelope >>= send (ps Map.! "sender-a")
  let recipient = ps Map.! "recipient"
  calls <- newIORef []
  prior <- newIORef False
  let door = DeliveryDoor $ \source tokens identity -> do
        modifyIORef' calls (<> [(source, tokens, identity)])
        isPrior <- readIORef prior
        path <- either (fail . T.unpack) pure (netPath source)
        pure $
          if isPrior
            then DoorPrior (PriorAcknowledgement identity 7)
            else DoorFired (FiringOutcome path 7 [] [] [])
      inbox = FabricInbox (inboxClient recipient) door
  -- The crash window: the semantic delivery happened, the Fabric
  -- acknowledgement did not.
  [waiting] <- pending recipient 100
  door.deliver waiting.source [envelopeToken waiting] waiting.ingressIdentity >>= \case
    DoorFired outcome -> outcome.occurrence `shouldBe` 7
    other -> expectationFailure (show other)
  writeIORef prior True
  [accepted] <- drain inbox 100
  accepted.state `shouldBe` Accepted
  accepted.occurrence `shouldBe` Just 7
  pending recipient 100 `shouldReturn` []
  (source, tokens, identity) <- last <$> readIORef calls
  (source, map (.color) tokens, identity) `shouldBe` ("commands/start", [Just fabricEnvelopeColor], "fabric:8:sender-a:delivery-1")

occurrenceConflicts :: Parties -> Expectation
occurrenceConflicts ps = do
  openRoute ps
  _ <- defaultEnvelope >>= send (ps Map.! "sender-a")
  let recipient = ps Map.! "recipient"
  ((.occurrence) <$> acknowledge recipient "sender-a" "delivery-1" 4) `shouldReturn` Just 4
  ((.occurrence) <$> acknowledge recipient "sender-a" "delivery-1" 4) `shouldReturn` Just 4
  refusal ConflictCategory ["already accepted by occurrence 4"] (acknowledge recipient "sender-a" "delivery-1" 5)
  refusal Invalid ["positive integer"] (acknowledge recipient "sender-a" "delivery-1" 0)

pruning :: Pg.Connection -> Parties -> Expectation
pruning admin ps = do
  openRoute ps
  let sender = ps Map.! "sender-a"
      recipient = ps Map.! "recipient"
  item <- envelopeWith "sender-a" "delivery-1" (Object [("secret-inline-bytes", String "do-not-retain")])
  _ <- send sender item
  _ <- acknowledge recipient "sender-a" "delivery-1" 9
  -- prune_accepted(datetime.now()), a naive cutoff: the cutoff is a UTCTime
  -- in the port (F-091).
  now <- getCurrentTime
  pruneAccepted recipient (addUTCTime 1 now) `shouldReturn` 1
  Just stored <- receipt sender "delivery-1"
  stored `shouldBe` Receipt "sender-a" "delivery-1" "recipient" "commands/start" item.digest Accepted (Just 9) stored.acceptedAt False
  rows <- Pg.query admin "SELECT envelope, digest FROM impetus_fabric.deliveries WHERE sender = 'sender-a' AND delivery_id = 'delivery-1'" []
  rows `shouldBe` [[Nothing, Just (TE.encodeUtf8 item.digest)]]
  duplicate <- send sender item
  (duplicate.state, duplicate.duplicate, duplicate.occurrence) `shouldBe` (Accepted, True, Just 9)
  refusal ConflictCategory ["identity conflict"] (envelopeWith "sender-a" "delivery-1" (Object [("secret-inline-bytes", String "changed")]) >>= send sender)
