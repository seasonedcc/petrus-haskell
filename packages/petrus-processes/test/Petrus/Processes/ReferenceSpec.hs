-- | The reference's own tests, ported one for one:
-- upstream/petrus/tests/petrus/processes/test_processes.py (19 tests). Each
-- example is named after its Python test. Assertions the port's types make
-- unrepresentable are noted where they fall (DIVERGENCES.md, "Type-enforced
-- refusals"); TypedSpec holds their evidence.
module Petrus.Processes.ReferenceSpec (spec) where

import Control.Concurrent.Async (replicateConcurrently)
import Control.Exception (IOException, TypeError (..), bracket, finally, throwIO)
import Control.Monad (unless)
import Data.ByteString.Char8 qualified as BC
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Activity (ActivityInvocation (..), defaultExecutionPolicy)
import Petrus.Fabric
import Petrus.Fabric.Conformance.Setup (neutralLibrary, publicEngineDoorsOnly, refusal)
import Petrus.Fabric.Postgres (ensureFabricSchema, exposeSource, grant, issueCredential, postgresFabric, registerProcess, submit)
import Petrus.Json (Json (..))
import Petrus.Postgres qualified as Pg
import Petrus.Processes
import Petrus.Processes.DemoSpec (lifecycleLines)
import Petrus.Processes.Postgres
import Petrus.Processes.TypedSpec (liveProvisioner)
import Petrus.TestSupport (PostgresTarget (..), postgresSpec)
import System.Directory (findExecutable)
import System.Exit (ExitCode (..))
import System.Process (proc, readCreateProcessWithExitCode)
import Test.Hspec

spec :: Spec
spec = do
  testFile
  describe "upstream tests/project/test_package_boundaries.py" $
    it "test_cv5_demos_host_only_through_public_engine_doors (cv5-lifecycle-demo)" (publicEngineDoorsOnly "packages/petrus-processes/demo/Petrus/Processes/Demo.hs")

testFile :: Spec
testFile = describe "upstream tests/petrus/processes/test_processes.py" $ do
  it "test_neutral_process_import_attempts_neither_psycopg_nor_runtime_layers" (neutralLibrary "petrus-processes")
  it "test_spawn_spec_is_exact_detached_strict_and_fully_digested" spawnSpecContract
  it "test_child_identity_is_stable_parent_scoped_and_not_spec_scoped" childIdentityContract
  it "test_spawn_outcome_and_provisioning_refuse_cross_identity_values" crossIdentity
  it "test_call_values_are_exact_detached_and_provider_neutral" callValues
  it "test_call_envelopes_are_correlated_addressed_and_share_one_terminal_reply_identity" callEnvelopes
  it "test_call_helpers_refuse_mismatched_correlation_sender_and_reply_owner" callRefusals
  it "test_spawn_activity_claims_before_ensure_and_reensures_an_exact_retry" claimsBeforeEnsure
  it "test_spawn_activity_refuses_wrong_activity_idempotency_or_registry_identity" activityRefusals
  -- The provisioner returning object(): ensure's type is
  -- Provisioning -> IO () in the port (P-055), so that provisioner is
  -- ill-typed; the example runs TypedSpec's deferred-type-error binding.
  it "test_spawn_activity_refuses_a_live_object_from_the_provisioner" $ do
    item <- spawn []
    inv <- retryInvocation item
    spawnActivity memoryRegistry liveProvisioner inv `shouldThrow` \(TypeError _) -> True
  postgresSpec $ do
    it "test_lifecycle_schema_is_mapping_only_versioned_and_refuses_unknown_shapes" (withAdmin schemaShapes)
    it "test_lifecycle_schema_provisioning_does_not_commit_the_callers_transaction" $ \target ->
      withAdmin (schemaJoined target) target
    it "test_postgres_registry_requires_autocommit_and_authentication" $ \target ->
      withLifecycle (registryAuthentication target) target
    it "test_postgres_claim_is_durable_exact_conflict_detecting_and_queryable" (withLifecycle durableClaim)
    it "test_lineage_queries_are_parent_bound" (withLifecycle parentBound)
    it "test_concurrent_exact_claims_converge_on_one_row" $ \target ->
      withLifecycle (concurrentClaims target) target
    it "test_failed_provision_after_claim_retries_the_same_claim" (withLifecycle failedProvision)
    it "test_call_result_and_error_share_fabric_conflict_identity" (withLifecycle terminalIdentity)
    it "test_process_lifecycle_acceptance_demo" $ \target -> do
      exe <- findExecutable "cv5-lifecycle-demo" >>= maybe (fail "cv5-lifecycle-demo is not on PATH (build-tool-depends)") pure
      (code, out, err) <- readCreateProcessWithExitCode (proc exe ["--dsn", BC.unpack target.targetUrl]) ""
      unless (code == ExitSuccess && all (`T.isInfixOf` T.pack out) lifecycleLines) $
        expectationFailure (show code <> "\n" <> out <> "\n--- stderr ---\n" <> err)

-- ---------------------------------------------------------------------------
-- Values: spec(parent, spawn_id, **changes) and call_request(call_id)

data Change
  = Parent Text
  | Kind Text
  | Source Text
  | Capabilities Json
  | Config Json
  | Route ReplyRoute

spawnE :: [Change] -> Either FabricError SpawnSpec
spawnE changes = do
  defaultRoute <- replyRoute parent "replies"
  let route = last (defaultRoute : [r | Route r <- changes])
  spawnSpec
    parent
    "spawn-1"
    (pick "analysis-agent" [k | Kind k <- changes])
    (pick "calls" [o | Source o <- changes])
    (pick capabilities [c | Capabilities c <- changes])
    (pick config [c | Config c <- changes])
    (Just route)
  where
    parent = pick "parent" [p | Parent p <- changes]
    pick fallback values = last (fallback : values)
    capabilities = Object [("protocol", String "call-v1"), ("features", Array [String "reply"])]
    config = Object [("model", String "deterministic"), ("tools", Array [String "read"])]

spawn :: [Change] -> IO SpawnSpec
spawn = orThrow . spawnE

callRequestEnvelope :: IO Envelope
callRequestEnvelope = do
  request <- orThrow (callRequest "call-1" "answer" (Object [("question", Int 42)]))
  route <- orThrow (replyRoute "parent" "replies")
  orThrow (requestEnvelope request "parent" "child" "calls" route Nothing)

nullResult :: Text -> IO CallResult
nullResult callId = orThrow (callResult callId Null)

retryInvocation :: SpawnSpec -> IO ActivityInvocation
retryInvocation item = do
  idempotency <- orThrow (spawnIdempotency item.parent item.spawnId)
  pure (plainInvocation spawnActivityName (spawnSpecToData item) (Just idempotency))

plainInvocation :: Text -> Json -> Maybe Text -> ActivityInvocation
plainInvocation name input = ActivityInvocation name input defaultExecutionPolicy Nothing

-- | A registry whose lineage queries the tests never reach.
registryWith :: (SpawnSpec -> IO SpawnClaim) -> SpawnRegistry
registryWith claimWith =
  SpawnRegistry
    { claim = claimWith
    , childOf = \_ _ -> fail "unused"
    , childrenOf = \_ -> fail "unused"
    , parentOf = \_ -> fail "unused"
    }

memoryRegistry :: SpawnRegistry
memoryRegistry = registryWith (\v -> orThrow (spawnClaim v.parent v.spawnId v.child False))

memberOf :: Text -> Json -> Maybe Json
memberOf key = \case
  Object members -> lookup key members
  _ -> Nothing

withMember :: Text -> Json -> Json -> Json
withMember key value = \case
  Object members -> Object (filter ((/= key) . fst) members <> [(key, value)])
  other -> other

-- ---------------------------------------------------------------------------
-- Unit tests

spawnSpecContract :: Expectation
spawnSpecContract = do
  -- The caller's config cannot be mutated afterwards, nor item.config:
  -- Haskell values are immutable.
  item <- spawn [Config (Object [("nested", Array [Int 1])])]
  memberOf "config" (spawnSpecToData item) `shouldBe` Just (Object [("nested", Array [Int 1])])
  spawnSpecFromData (spawnSpecToData item) `shouldBe` Right item
  T.length item.digest `shouldBe` 64
  mapM_
    (\change -> ((.digest) <$> spawn [change]) >>= (`shouldNotBe` item.digest))
    [Config (Object [("nested", Array [Int 2])]), Source "other", Capabilities (Object [("protocol", String "call-v2")])]
  refusal Invalid ["exact version-1"] (orThrow (spawnSpecFromData (withMember "credential" (String "forbidden-field") (spawnSpecToData item))))
  refusal Invalid ["strict JSON"] (spawn [Config (Object [("bad", Float (0 / 0))])])
  someoneElse <- orThrow (replyRoute "someone-else" "replies")
  refusal Invalid ["belong to the parent"] (spawn [Route someoneElse])

childIdentityContract :: Expectation
childIdentityContract = do
  item <- spawn []
  childIdentity "parent" "spawn-1" `shouldBe` Right item.child
  ((.child) <$> spawn [Kind "other"]) `shouldReturn` item.child
  childIdentity "parent-2" "spawn-1" `shouldNotBe` Right item.child
  childIdentity "parent" "spawn-2" `shouldNotBe` Right item.child
  T.isPrefixOf "process-v1-" item.child `shouldBe` True
  T.length item.child `shouldBe` T.length "process-v1-" + 64

crossIdentity :: Expectation
crossIdentity = do
  item <- spawn []
  ep <- orThrow (endpoint item.child item.source item.capabilities)
  prov <- orThrow (provisioning item.parent item.spawnId item.child item.processKind ep item.config item.replyRoute)
  prov.config `shouldBe` item.config
  outcome <- orThrow (spawnOutcome item.parent item.spawnId item.child ep False)
  spawnOutcomeFromData (spawnOutcomeToData outcome) `shouldBe` Right outcome
  refusal Invalid ["parent-scoped"] (orThrow (provisioning item.parent item.spawnId "wrong" item.processKind ep (Object []) item.replyRoute))
  wrong <- orThrow (endpoint "wrong" item.source (Object []))
  refusal Invalid ["address the child"] (orThrow (spawnOutcome item.parent item.spawnId item.child wrong False))
  refusal Invalid ["exact version-1"] (orThrow (spawnOutcomeFromData (withMember "credential" (String "not-public") (spawnOutcomeToData outcome))))

callValues :: Expectation
callValues = do
  request <- orThrow (callRequest "call-1" "answer" (Object [("nested", Array [Int 1])]))
  memberOf "input" (callRequestToData request) `shouldBe` Just (Object [("nested", Array [Int 1])])
  callRequestFromData (callRequestToData request) `shouldBe` Right request
  result <- orThrow (callResult "call-1" (Array [Int 1, Object [("ok", Bool True)]]))
  ((.callId) <$> callResultFromData (callResultToData result)) `shouldBe` Right "call-1"
  failure <- orThrow (callError "call-1" "refused" "no" (Object [("retry", Bool False)]))
  ((.code) <$> callErrorFromData (callErrorToData failure)) `shouldBe` Right "refused"
  refusal Invalid ["exact version-1"] (orThrow (callRequestFromData (withMember "provider" (String "claude") (callRequestToData request))))
  refusal Invalid ["strict JSON"] (orThrow (callResult "call-1" (Float (1 / 0))))

callEnvelopes :: Expectation
callEnvelopes = do
  request <- callRequestEnvelope
  answer <- orThrow (callResult "call-1" (Object [("answer", Int 42)]))
  result <- orThrow (resultEnvelope answer request "child" Nothing)
  failure <- orThrow (callError "call-1" "failed" "delegated work failed" Null)
  failed <- orThrow (errorEnvelope failure request "child" Nothing)
  map (.correlation) [request, result, failed] `shouldBe` ["call-1", "call-1", "call-1"]
  (result.recipient, result.source) `shouldBe` ("parent", "replies")
  result.deliveryId `shouldBe` failed.deliveryId
  result.digest `shouldNotBe` failed.digest
  ((.result) <$> callResultFromData result.payload) `shouldBe` Right (Object [("answer", Int 42)])
  ((.message) <$> callErrorFromData failed.payload) `shouldBe` Right "delegated work failed"
  replyFromEnvelope result request `shouldSatisfy` \case
    Right (ReplyResult _) -> True
    _ -> False
  replyFromEnvelope failed request `shouldSatisfy` \case
    Right (ReplyError _) -> True
    _ -> False

callRefusals :: Expectation
callRefusals = do
  request <- callRequestEnvelope
  other <- nullResult "other"
  same <- nullResult "call-1"
  refusal Invalid ["correlate"] (orThrow (resultEnvelope other request "child" Nothing))
  refusal Invalid ["correlate"] (orThrow (resultEnvelope same request "other-child" Nothing))
  malformed <- orThrow (envelope request.deliveryId request.sender request.recipient request.source "other" request.payload request.replyRoute)
  refusal Invalid ["payload", "correlation"] (orThrow (resultEnvelope other malformed "child" Nothing))
  malformedReply <- orThrow (envelope "reply" "child" "parent" "replies" "other" (callResultToData same) Nothing)
  refusal Invalid ["payload", "correlation"] (orThrow (replyFromEnvelope malformedReply request))
  terminal <- orThrow (resultEnvelope same request "child" Nothing)
  siblingReply <- orThrow (envelope terminal.deliveryId "sibling" "parent" "replies" "call-1" (callResultToData same) Nothing)
  refusal Invalid ["request callee"] (orThrow (replyFromEnvelope siblingReply request))
  bare <- orThrow (callRequest "call-1" "answer" (Object []))
  otherRoute <- orThrow (replyRoute "other" "replies")
  refusal Invalid ["belong to the sender"] (orThrow (requestEnvelope bare "parent" "child" "calls" otherRoute Nothing))

claimsBeforeEnsure :: Expectation
claimsBeforeEnsure = do
  events <- newIORef []
  prior <- newIORef False
  item <- spawn []
  let record event = modifyIORef' events (<> [event :: Text])
      registry = registryWith $ \v -> do
        record "claim"
        wasPrior <- atomicModifyIORef' prior (True,)
        orThrow (spawnClaim v.parent v.spawnId v.child wasPrior)
      -- Python also asserts the value has no credential attribute:
      -- Provisioning has no such field in the port.
      provisioner = ProcessProvisioner (\_ -> record "ensure")
  inv <- retryInvocation item
  first <- spawnActivity registry provisioner inv >>= orThrow . spawnOutcomeFromData
  second <- spawnActivity registry provisioner inv >>= orThrow . spawnOutcomeFromData
  (first.priorClaim, second.priorClaim) `shouldBe` (False, True)
  (first.child, second.child) `shouldBe` (item.child, item.child)
  readIORef events `shouldReturn` ["claim", "ensure", "claim", "ensure"]

activityRefusals :: Expectation
activityRefusals = do
  item <- spawn []
  otherChild <- orThrow (childIdentity "other-parent" "other-spawn")
  let registry = registryWith (\_ -> orThrow (spawnClaim "other-parent" "other-spawn" otherChild False))
      provisioner = ProcessProvisioner (\_ -> fail "invalid claim reached provisioning")
  refusal Invalid ["only implements"] (spawnActivity registry provisioner (plainInvocation "other" (spawnSpecToData item) Nothing))
  refusal Invalid ["idempotency"] (spawnActivity registry provisioner (plainInvocation spawnActivityName (spawnSpecToData item) (Just "wrong")))
  inv <- retryInvocation item
  refusal Invalid ["different identity"] (spawnActivity registry provisioner inv)

-- ---------------------------------------------------------------------------
-- PostgreSQL tests

withAdmin :: (Pg.Connection -> IO a) -> PostgresTarget -> IO a
withAdmin action target = bracket (Pg.connect target.targetUrl True) Pg.close action

-- | The @lifecycle@ fixture: both schemas recreated, "parent" registered.
withLifecycle :: (Pg.Connection -> Text -> PostgresSpawnRegistry -> IO a) -> PostgresTarget -> IO a
withLifecycle action = withAdmin $ \admin -> do
  Pg.execute_ admin "DROP SCHEMA IF EXISTS impetus_lifecycle CASCADE" []
  Pg.execute_ admin "DROP SCHEMA IF EXISTS impetus_fabric CASCADE" []
  ensureFabricSchema admin
  ensureLifecycleSchema admin
  credential <- issueCredential
  registerProcess admin "parent" credential
  postgresSpawnRegistry admin "parent" credential >>= action admin credential

scalarOf :: Pg.Connection -> Pg.Sql -> IO (Maybe Text)
scalarOf admin sql =
  Pg.query admin sql [] >>= \case
    [[value]] -> pure (TE.decodeUtf8 <$> value)
    rows -> fail ("unexpected rows " <> show rows)

schemaShapes :: Pg.Connection -> Expectation
schemaShapes admin = body `finally` restore
  where
    restore = do
      Pg.execute_ admin "DROP SCHEMA IF EXISTS impetus_lifecycle CASCADE" []
      ensureLifecycleSchema admin
    body = do
      Pg.execute_ admin "DROP SCHEMA IF EXISTS impetus_lifecycle CASCADE" []
      ensureLifecycleSchema admin
      columns <-
        Pg.query
          admin
          "SELECT column_name FROM information_schema.columns WHERE table_schema = 'impetus_lifecycle' AND table_name = 'spawns' ORDER BY ordinal_position"
          []
      columns `shouldBe` map (\c -> [Just c]) ["parent", "spawn_id", "child", "spec_digest", "created_at"]
      Pg.execute_ admin "DROP SCHEMA impetus_lifecycle CASCADE" []
      Pg.execute_ admin "CREATE SCHEMA impetus_lifecycle" []
      Pg.execute_ admin "CREATE TABLE impetus_lifecycle.spawns (unknown text)" []
      refusal SchemaRefusedCategory ["unversioned", "refusing"] (ensureLifecycleSchema admin)
      Pg.execute_ admin "DROP SCHEMA impetus_lifecycle CASCADE" []
      ensureLifecycleSchema admin
      Pg.execute_ admin "UPDATE impetus_lifecycle.schema_metadata SET version = 999 WHERE component = 'lifecycle'" []
      refusal SchemaRefusedCategory ["version 999", "migrate deliberately"] (ensureLifecycleSchema admin)

schemaJoined :: PostgresTarget -> Pg.Connection -> Expectation
schemaJoined target admin = body `finally` ensureLifecycleSchema admin
  where
    namespace = scalarOf admin "SELECT to_regnamespace('impetus_lifecycle')"
    body = do
      Pg.execute_ admin "DROP SCHEMA IF EXISTS impetus_lifecycle CASCADE" []
      bracket (Pg.connect target.targetUrl False) Pg.close $ \joined -> do
        ensureLifecycleSchema joined
        namespace `shouldReturn` Nothing
        Pg.rollback joined
        namespace `shouldReturn` Nothing

registryAuthentication :: PostgresTarget -> Pg.Connection -> Text -> PostgresSpawnRegistry -> Expectation
registryAuthentication target admin _ registry = do
  item <- spawn []
  bracket (Pg.connect target.targetUrl False) Pg.close $ \joined ->
    refusal Invalid ["autocommit"] (issueCredential >>= postgresSpawnRegistry joined "parent")
  stranger <- issueCredential
  refusal DeniedCategory ["lifecycle authentication"] (postgresSpawnRegistry admin "parent" stranger >>= \r -> claim r item)
  elsewhere <- spawn [Parent "other"]
  refusal DeniedCategory ["authenticated registry"] (claim registry elsewhere)

durableClaim :: Pg.Connection -> Text -> PostgresSpawnRegistry -> Expectation
durableClaim admin _ registry = do
  item <- spawn []
  first <- claim registry item
  second <- claim registry item
  orThrow (spawnClaim "parent" "spawn-1" item.child False) >>= (first `shouldBe`)
  orThrow (spawnClaim "parent" "spawn-1" item.child True) >>= (second `shouldBe`)
  expected <- orThrow (lineage "parent" "spawn-1" item.child)
  childOf registry "parent" "spawn-1" `shouldReturn` Just expected
  childrenOf registry "parent" `shouldReturn` [expected]
  parentOf registry item.child `shouldReturn` Just expected
  rows <- Pg.query admin "SELECT parent, spawn_id, child, spec_digest FROM impetus_lifecycle.spawns" []
  rows `shouldBe` [map (Just . TE.encodeUtf8) ["parent", "spawn-1", item.child, item.digest]]
  changed <- spawn [Config (Object [("changed", Bool True)])]
  refusal ConflictCategory ["content changed"] (claim registry changed)
  scalarOf admin "SELECT count(*) FROM impetus_lifecycle.spawns" `shouldReturn` Just "1"

parentBound :: Pg.Connection -> Text -> PostgresSpawnRegistry -> Expectation
parentBound admin _ registry = do
  otherCredential <- issueCredential
  registerProcess admin "other" otherCredential
  item <- spawn []
  _ <- claim registry item
  other <- postgresSpawnRegistry admin "other" otherCredential
  refusal DeniedCategory ["parent must match"] (childOf other "parent" "spawn-1")
  refusal DeniedCategory ["does not belong"] (parentOf other item.child)

concurrentClaims :: PostgresTarget -> Pg.Connection -> Text -> PostgresSpawnRegistry -> Expectation
concurrentClaims target _ credential _ = do
  item <- spawn []
  claims <- replicateConcurrently 2 $
    Pg.withConnection target.targetUrl True $ \connection ->
      postgresSpawnRegistry connection "parent" credential >>= \r -> claim r item
  Set.fromList (map (.priorClaim) claims) `shouldBe` Set.fromList [False, True]
  Set.fromList (map (.child) claims) `shouldBe` Set.fromList [item.child]

failedProvision :: Pg.Connection -> Text -> PostgresSpawnRegistry -> Expectation
failedProvision _ _ registry = do
  item <- spawn []
  attempts <- newIORef []
  let provisioner = ProcessProvisioner $ \value -> do
        made <- atomicModifyIORef' attempts (\xs -> (xs <> [value.child], length xs + 1))
        unless (made > 1) $ throwIO (userError "lost after claim")
  inv <- retryInvocation item
  spawnActivity (spawnRegistry registry) provisioner inv `shouldThrow` \(e :: IOException) -> "lost after claim" `T.isInfixOf` T.pack (show e)
  outcome <- spawnActivity (spawnRegistry registry) provisioner inv >>= orThrow . spawnOutcomeFromData
  outcome.priorClaim `shouldBe` True
  readIORef attempts `shouldReturn` [item.child, item.child]

terminalIdentity :: Pg.Connection -> Text -> PostgresSpawnRegistry -> Expectation
terminalIdentity admin _ _ = do
  parentCredential <- issueCredential
  childCredential <- issueCredential
  registerProcess admin "caller" parentCredential
  registerProcess admin "callee" childCredential
  caller <- postgresFabric admin "caller" parentCredential
  callee <- postgresFabric admin "callee" childCredential
  exposeSource caller "replies"
  grant caller "callee" "replies"
  secondCredential <- issueCredential
  registerProcess admin "second-caller" secondCredential
  secondCaller <- postgresFabric admin "second-caller" secondCredential
  exposeSource secondCaller "replies"
  grant secondCaller "callee" "replies"
  call <- orThrow (callRequest "terminal-call" "answer" (Object []))
  callerRoute <- orThrow (replyRoute "caller" "replies")
  secondRoute <- orThrow (replyRoute "second-caller" "replies")
  request <- orThrow (requestEnvelope call "caller" "callee" "calls" callerRoute Nothing)
  answer <- orThrow (callResult "terminal-call" (Object [("ok", Bool True)]))
  result <- orThrow (resultEnvelope answer request "callee" Nothing)
  failure <- orThrow (callError "terminal-call" "failed" "changed terminal outcome" Null)
  failed <- orThrow (errorEnvelope failure request "callee" Nothing)
  secondRequest <- orThrow (requestEnvelope call "second-caller" "callee" "calls" secondRoute Nothing)
  secondResult <- orThrow (resultEnvelope answer secondRequest "callee" Nothing)
  ((.duplicate) <$> submit callee result) `shouldReturn` False
  refusal ConflictCategory ["identity conflict"] (submit callee failed)
  result.deliveryId `shouldNotBe` secondResult.deliveryId
  ((.duplicate) <$> submit callee secondResult) `shouldReturn` False
