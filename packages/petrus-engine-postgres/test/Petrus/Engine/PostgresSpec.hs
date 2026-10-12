-- | Parity: @tests/petrus/engine/test_postgres_engine.py@ (12 test
-- functions, 13 cases: the commit-fault test is parametrized over
-- @fault in ["refused", "acknowledgement-lost"]@), plus the provider's own
-- edges beyond upstream (fence released on close, telemetry routed to the
-- Engine's sink, the poisoned writer's fence gone while its connection is
-- closed).
--
-- Every example runs against one scratch database ("Petrus.TestSupport");
-- without @PETRUS_TEST_POSTGRES@ they are pending, saying so (upstream's
-- @postgres@ marker).
module Petrus.Engine.PostgresSpec (spec) where

import Control.Exception (IOException, finally, throwIO)
import Control.Monad (when)
import Data.Foldable (toList)
import Data.IORef
import Data.List (isInfixOf, isPrefixOf)
import Data.Text (Text)
import Petrus.Engine (DeliveryAnswer (..), Engine)
import Petrus.Engine qualified as Engine
import Petrus.Engine.Postgres
import Petrus.Engine.Provider (OpenMode (..))
import Petrus.Engine.TestSupport (handlerFailed, inlineOf, mkDelivery, scripted, symbols, valueError)
import Petrus.HistoryStore.Postgres (ensureSchema, openPostgresHistoryStore)
import Petrus.HistoryStore.Postgres.Support (connectTo, freshInstance, valueErrorMatching, withPg, withPgConnection)
import Petrus.Impetus.Binding (BoundHandler (..), handlerTokens)
import Petrus.Impetus.History.Records
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance (AcceptedDelivery (..), FiringOutcome (..), PriorAcknowledgement (..), firingOccurrenceIdInt)
import Petrus.Impetus.Petrinet
import Petrus.Impetus.TestSupport (netOf, np, tokD)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch (Dispatch)
import Petrus.Postgres (Connection, FenceError (..), isClosed)
import Petrus.Postgres qualified as Pg
import Petrus.Telemetry (newRecorder, recorded, recorderSink)
import Petrus.TestSupport (PostgresTarget, postgresSpec, repoRoot)
import System.FilePath ((</>))
import Test.Hspec

source', output :: NetPath
source' = np "source"
output = np "output"

-- | @_provider_net()@.
providerNet :: Net
providerNet = netOf [place output] [transition source'] [arc source' output]

-- | The handler-bearing net of the projection tests.
projectNet :: Net
projectNet = netOf [place output] [(transition source') {handler = Just (HandlerSymbol "project")}] [arc source' output]

eventToken :: Token
eventToken = tokD "Event" (Int 7)

-- | @raise RuntimeError("projection failed")@ from a pure handler.
explode :: Text -> BoundHandler
explode rendered = PureHandler (\_ _ -> Left rendered)

-- | @lambda binding, outputs: {OUTPUT: binding.tokens}@.
forward :: BoundHandler
forward = PureHandler (\binding _ -> Right (handlerTokens [(output, bindingTokens binding)]))

inline :: IO Dispatch
inline = inlineOf []

joined :: PostgresTarget -> IO Connection
joined target = connectTo target False

-- | @PostgresHistoryStore(probe, instance_id).records@ over a fresh
-- autocommit connection.
probeRecords :: PostgresTarget -> Text -> IO [Record]
probeRecords target instanceId =
  withPg target True $ \probe -> openPostgresHistoryStore probe instanceId >>= Store.records

createOn :: Connection -> Net -> Text -> Engine.EngineOptions -> IO Engine
createOn connection net instanceId options = do
  port <- inline
  createEngine connection net instanceId port options

loadOn :: Connection -> Net -> Text -> Engine.EngineOptions -> IO Engine
loadOn connection net instanceId options = do
  port <- inline
  loadEngine connection net instanceId port options

projecting :: BoundHandler -> Engine.EngineOptions
projecting h = Engine.defaultEngineOptions {Engine.handlers = symbols [("project", h)]}

outputTokens :: Engine -> IO [Token]
outputTokens engine = toList . placeTokens output <$> Engine.marking engine

accepted' :: DeliveryAnswer AcceptedDelivery -> IO AcceptedDelivery
accepted' = \case
  DeliveryAccepted a -> pure a
  other -> expectationFailure ("expected an acceptance, got " <> show other) >> fail "unreachable"

-- | A session whose commits are counted (upstream's @_CountCommits@).
countingSession :: Connection -> IO (PostgresSession, IORef Int)
countingSession connection = do
  commits <- newIORef 0
  let session = postgresSession connection
  pure (session {commit = modifyIORef' commits (+ 1) >> session.commit}, commits)

-- | @OSError(message)@.
osError :: String -> IO a
osError = throwIO . userError

ioErrorMatching :: String -> Selector IOException
ioErrorMatching fragment e = fragment `isInfixOf` show e

isDelivered, isBegun, isFailed, isCompleted :: Record -> Bool
isDelivered = \case RExternalEventDelivered _ -> True; _ -> False
isBegun = \case RFiringBegun _ -> True; _ -> False
isFailed = \case RFiringFailed _ -> True; _ -> False
isCompleted = \case RFiringCompleted _ -> True; _ -> False

-- | @records[-2:] == (ExternalEventDelivered(SOURCE, (token,), identity="event-7", occurrence=1), FiringBegun(SOURCE, occurrence=1))@.
endsDeliveredThenBegun :: [Record] -> Expectation
endsDeliveredThenBegun recs = case reverse recs of
  RFiringBegun b : RExternalEventDelivered d : _ -> do
    (d.source, d.tokens, d.identity, d.occurrence, d.scope) `shouldBe` (source', [eventToken], "event-7", 1, Nothing)
    (b.transition, b.occurrence, b.scope) `shouldBe` (source', 1, Nothing)
  _ -> expectationFailure ("expected ExternalEventDelivered then FiringBegun last, got " <> show (take 2 (reverse recs)))

-- | @records[-1] == FiringFailed(SOURCE, rendered, occurrence=1)@.
endsFailed :: Text -> [Record] -> Expectation
endsFailed rendered recs = case reverse recs of
  RFiringFailed f : _ -> (f.transition, f.error, f.occurrence) `shouldBe` (source', rendered, 1)
  _ -> expectationFailure ("expected a trailing FiringFailed, got " <> show (take 1 (reverse recs)))

fenceHeld :: Selector FenceError
fenceHeld = \case FenceHeld _ -> True; _ -> False

spec :: Spec
spec = do
  postgresSpec $
    aroundWith (\action target -> withPgConnection target (\_ -> action target)) $ do
      providerSpec
      beyondUpstreamSpec
  boundarySpec

-- | Parity: @tests/project/test_package_boundaries.py@'s PostgreSQL provider
-- row. The doors' return type is the neutral 'Engine' (checked by the
-- compiler below); the fence stays out of the provider's export list.
boundarySpec :: Spec
boundarySpec = describe "package boundaries" $
  it "postgres history provider returns only the neutral engine" $ do
    let doors :: [Connection -> Net -> Text -> Dispatch -> Engine.EngineOptions -> IO Engine]
        doors = [createEngine, loadEngine]
    length doors `shouldBe` 2
    root <- repoRoot
    source <- readFile (root </> "packages/petrus-engine-postgres/src/Petrus/Engine/Postgres.hs")
    let exports = takeWhile (not . ("  ) where" `isPrefixOf`)) (dropWhile (not . ("module Petrus.Engine.Postgres" `isPrefixOf`)) (lines source))
    filter (\w -> "Fence" `isInfixOf` w || w `elem` ["PostgresEngine", "Coordinator"]) (concatMap (words . map (\c -> if c `elem` ("(),." :: String) then ' ' else c)) exports) `shouldBe` []

-- ---------------------------------------------------------------------------
-- TestPostgresEngineProvider

providerSpec :: SpecWith PostgresTarget
providerSpec = describe "TestPostgresEngineProvider" $ do
  it "sensed_projection_failure_commits_terminal_failure_and_acknowledges_exactly" $ \target -> do
    instanceId <- freshInstance "pg-only"
    sensor <- scripted [[mkDelivery source' [eventToken] "event-7"]]
    connection <- joined target
    engine <- createOn connection projectNet instanceId (projecting (explode "RuntimeError('projection failed')")) {Engine.sensor = Just sensor}
    Engine.advance engine `shouldThrow` handlerFailed "projection failed"

    acceptedRecords <- probeRecords target instanceId
    case reverse acceptedRecords of
      failed : begun : delivered : _ -> do
        isDelivered delivered `shouldBe` True
        isBegun begun `shouldBe` True
        isFailed failed `shouldBe` True
      _ -> expectationFailure "expected at least three records"
    any isCompleted acceptedRecords `shouldBe` False

    resumedConnection <- joined target
    resumed <- loadOn resumedConnection projectNet instanceId (projecting forward)
    Engine.acceptDelivery resumed source' [eventToken] "event-7" Nothing
      `shouldReturn` DeliveryPrior (PriorAcknowledgement "event-7" 1)
    outputTokens resumed `shouldReturn` []
    Engine.close resumed

  it "direct_projection_failure_commits_terminal_failure_and_acknowledges_exactly" $ \target -> do
    -- Upstream's ProjectionError.__repr__ raising proves the durable text is
    -- not rendered through repr; a Haskell handler returns its rendered
    -- failure text itself, so the recorded text is checked verbatim.
    instanceId <- freshInstance "pg-only"
    connection <- joined target
    engine <- createOn connection projectNet instanceId (projecting (explode "ProjectionError('projection failed')"))
    accepted <- Engine.acceptDelivery engine source' [eventToken] "event-7" Nothing >>= accepted'
    Engine.completeDelivery engine accepted `shouldThrow` handlerFailed "projection failed"

    probeRecords target instanceId >>= endsFailed "ProjectionError('projection failed')"

    resumedConnection <- joined target
    resumed <- loadOn resumedConnection projectNet instanceId (projecting forward)
    Engine.acceptDelivery resumed source' [eventToken] "event-7" Nothing
      `shouldReturn` DeliveryPrior (PriorAcknowledgement "event-7" 1)
    Engine.close resumed

  it "exact_redelivery_does_not_commit_an_empty_joined_transaction" $ \target -> do
    instanceId <- freshInstance "pg-only"
    (session, commits) <- joined target >>= countingSession
    port <- inline
    engine <- openPostgresEngine session CreateInstance providerNet instanceId port Engine.defaultEngineOptions
    accepted <- Engine.acceptDelivery engine source' [eventToken] "event-7" Nothing >>= accepted'
    afterAcceptance <- readIORef commits

    reconstructed <- Engine.acceptDelivery engine source' [eventToken] "event-7" Nothing >>= accepted'
    reconstructed `shouldBe` accepted
    readIORef commits `shouldReturn` afterAcceptance

    _ <- Engine.completeDelivery engine reconstructed
    afterCompletion <- readIORef commits
    Engine.acceptDelivery engine source' [eventToken] "event-7" Nothing
      `shouldReturn` DeliveryPrior (PriorAcknowledgement "event-7" (firingOccurrenceIdInt accepted.occurrence))
    readIORef commits `shouldReturn` afterCompletion
    Engine.close engine

  it "sensed_exact_redelivery_does_not_commit_an_empty_joined_transaction" $ \target -> do
    instanceId <- freshInstance "pg-only"
    let d = mkDelivery source' [eventToken] "event-7"
    sensor <- scripted [[d], [d]]
    (session, commits) <- joined target >>= countingSession
    port <- inline
    engine <- openPostgresEngine session CreateInstance providerNet instanceId port Engine.defaultEngineOptions {Engine.sensor = Just sensor}
    _ <- Engine.advance engine
    afterFirstDelivery <- readIORef commits

    outcome <- Engine.advance engine
    outcome.firings `shouldBe` []
    readIORef commits `shouldReturn` afterFirstDelivery
    Engine.close engine

  describe "projection_failure_commit_fault_propagates_storage_fate_and_fresh_load_decides" $
    mapM_ commitFaultCase ["refused", "acknowledgement-lost"]

  it "joined_completion_commit_refusal_leaves_acceptance_unfinished_for_exact_retry" $ \target -> do
    instanceId <- freshInstance "pg-only"
    connection <- joined target
    refuse <- newIORef False
    let session = postgresSession connection
        refusing =
          session
            { commit = do
                refusing' <- readIORef refuse
                if refusing'
                  then writeIORef refuse False >> osError "joined completion commit refused"
                  else session.commit
            }
    port <- inline
    engine <- openPostgresEngine refusing CreateInstance providerNet instanceId port Engine.defaultEngineOptions
    accepted <- Engine.acceptDelivery engine source' [eventToken] "event-7" Nothing >>= accepted'
    writeIORef refuse True

    Engine.completeDelivery engine accepted `shouldThrow` ioErrorMatching "joined completion commit refused"
    isClosed connection `shouldReturn` True

    refusedRecords <- probeRecords target instanceId
    endsDeliveredThenBegun refusedRecords
    any (\r -> isCompleted r || isFailed r) refusedRecords `shouldBe` False

    resumedConnection <- joined target
    resumed <- loadOn resumedConnection providerNet instanceId Engine.defaultEngineOptions
    reconstructed <- Engine.acceptDelivery resumed source' [eventToken] "event-7" Nothing >>= accepted'
    reconstructed `shouldBe` accepted
    outcome <- Engine.completeDelivery resumed reconstructed
    outcome.occurrence `shouldBe` firingOccurrenceIdInt accepted.occurrence
    Engine.close resumed

  it "create_load_and_idempotent_close_own_the_joined_connection" $ \target -> do
    -- @type(created) is Engine@ holds by the door's type.
    instanceId <- freshInstance "pg-only"
    writer <- joined target
    created <- createOn writer providerNet instanceId Engine.defaultEngineOptions
    _ <- Engine.deliver created source' [black] "first" Nothing
    recs <- Engine.records created
    Engine.close created
    Engine.close created
    isClosed writer `shouldReturn` True

    resumedWriter <- joined target
    resumed <- loadOn resumedWriter providerNet instanceId Engine.defaultEngineOptions
    Engine.records resumed `shouldReturn` recs
    length <$> outputTokens resumed `shouldReturn` 1
    Engine.close resumed
    isClosed resumedWriter `shouldReturn` True

  it "autocommit_and_invalid_options_close_the_supplied_connection" $ \target -> do
    instanceId <- freshInstance "pg-only"
    autocommit' <- connectTo target True
    createOn autocommit' providerNet instanceId Engine.defaultEngineOptions `shouldThrow` valueError "autocommit=False"
    isClosed autocommit' `shouldReturn` True

    -- An unknown keyword cannot be spelled against a record of options; an
    -- option the Engine refuses at construction is the same failure path.
    invalid <- joined target
    createOn invalid providerNet instanceId Engine.defaultEngineOptions {Engine.defaultHeartbeatTimeout = 0}
      `shouldThrow` valueError "default_heartbeat_timeout"
    isClosed invalid `shouldReturn` True

  it "create_and_load_preconditions_close_without_changing_history" $ \target -> do
    instanceId <- freshInstance "pg-only"
    first <- joined target
    created <- createOn first providerNet instanceId Engine.defaultEngineOptions
    recs <- Engine.records created
    Engine.close created

    duplicateWriter <- joined target
    createOn duplicateWriter providerNet instanceId Engine.defaultEngineOptions `shouldThrow` valueError "already exists"
    isClosed duplicateWriter `shouldReturn` True

    missingWriter <- joined target
    loadOn missingWriter providerNet ("missing-" <> instanceId) Engine.defaultEngineOptions `shouldThrow` valueError "does not exist"
    isClosed missingWriter `shouldReturn` True

    probeRecords target instanceId `shouldReturn` recs

  it "held_fence_refuses_before_history_load_and_closes_the_second_writer" $ \target -> do
    instanceId <- freshInstance "pg-only"
    firstWriter <- joined target
    first <- createOn firstWriter providerNet instanceId Engine.defaultEngineOptions
    secondWriter <- joined target
    loadOn secondWriter providerNet instanceId Engine.defaultEngineOptions `shouldThrow` fenceHeld
    isClosed secondWriter `shouldReturn` True

    Engine.close first
    resumedWriter <- joined target
    resumed <- loadOn resumedWriter providerNet instanceId Engine.defaultEngineOptions
    Engine.close resumed

  it "missing_schema_releases_fence_closes_and_allows_retry" $ \target ->
    withPg target True $ \pgConnection -> do
      instanceId <- freshInstance "pg-only"
      Pg.execute_ pgConnection "DROP SCHEMA impetus CASCADE" []
      writer <- joined target
      ( do
          createOn writer providerNet instanceId Engine.defaultEngineOptions `shouldThrow` valueErrorMatching ["ensure_schema"]
          isClosed writer `shouldReturn` True
        )
        `finally` ensureSchema pgConnection

      retriedWriter <- joined target
      retried <- createOn retriedWriter providerNet instanceId Engine.defaultEngineOptions
      Engine.close retried

  it "writing_failure_poison_releases_fence_for_fresh_load" $ \target -> do
    instanceId <- freshInstance "pg-only"
    poisonedWriter <- joined target
    poisoned <- createOn poisonedWriter providerNet instanceId Engine.defaultEngineOptions
    committed <- Engine.records poisoned
    Engine.deliver poisoned (np "unknown") [black] "bad" Nothing `shouldThrow` anyValueError ["unknown", "source", "transition"]

    resumedWriter <- joined target
    resumed <- loadOn resumedWriter providerNet instanceId Engine.defaultEngineOptions
    Engine.records resumed `shouldReturn` committed
    Engine.close poisoned
    isClosed poisonedWriter `shouldReturn` True
    Engine.close resumed
  where
    anyValueError fragments e = any (\f -> valueError f e) fragments

commitFaultCase :: String -> SpecWith PostgresTarget
commitFaultCase fault = it ("[" <> fault <> "]") $ \target -> do
  instanceId <- freshInstance "pg-only"
  connection <- joined target
  pendingFaultRef <- newIORef Nothing
  let session = postgresSession connection
      faulty =
        session
          { commit = do
              pendingFault <- atomicModifyIORef' pendingFaultRef (Nothing,)
              when (pendingFault == Just "refused") $ osError "failure commit refused"
              session.commit
              when (pendingFault == Just "acknowledgement-lost") $ osError "failure commit acknowledgement lost"
          }
  port <- inline
  engine <- openPostgresEngine faulty CreateInstance projectNet instanceId port (projecting (explode "RuntimeError('projection failed')"))
  accepted <- Engine.acceptDelivery engine source' [eventToken] "event-7" Nothing >>= accepted'
  writeIORef pendingFaultRef (Just (fault :: String))

  Engine.completeDelivery engine accepted `shouldThrow` ioErrorMatching "failure commit"
  isClosed connection `shouldReturn` True
  recs <- probeRecords target instanceId

  resumedConnection <- joined target
  resumed <- loadOn resumedConnection projectNet instanceId (projecting forward)
  redelivered <- Engine.acceptDelivery resumed source' [eventToken] "event-7" Nothing
  if fault == "refused"
    then do
      endsDeliveredThenBegun recs
      redelivered `shouldBe` DeliveryAccepted accepted
      _ <- Engine.completeDelivery resumed accepted
      outputTokens resumed `shouldReturn` [eventToken]
    else do
      endsFailed "RuntimeError('projection failed')" recs
      redelivered `shouldBe` DeliveryPrior (PriorAcknowledgement "event-7" (firingOccurrenceIdInt accepted.occurrence))
      outputTokens resumed `shouldReturn` []
  Engine.close resumed

-- ---------------------------------------------------------------------------
-- Beyond upstream

beyondUpstreamSpec :: SpecWith PostgresTarget
beyondUpstreamSpec = describe "beyond upstream" $ do
  it "close releases the authority fence (another session can take it at once)" $ \target -> do
    instanceId <- freshInstance "pg-only"
    writer <- joined target
    engine <- createOn writer providerNet instanceId Engine.defaultEngineOptions
    withPg target True $ \other -> do
      Pg.acquireAuthorityFence other instanceId `shouldThrow` fenceHeld
      Engine.close engine
      fence <- Pg.acquireAuthorityFence other instanceId
      Pg.releaseAuthorityFence fence

  it "a poisoned Engine has already released its fence and closed its connection" $ \target -> do
    instanceId <- freshInstance "pg-only"
    writer <- joined target
    engine <- createOn writer providerNet instanceId Engine.defaultEngineOptions
    Engine.deliver engine (np "unknown") [black] "bad" Nothing `shouldThrow` valueError "unknown"
    isClosed writer `shouldReturn` True
    withPg target True $ \other -> Pg.acquireAuthorityFence other instanceId >>= Pg.releaseAuthorityFence

  it "the History store reports postgres_commit to the Engine's telemetry sink" $ \target -> do
    instanceId <- freshInstance "pg-only"
    recorder <- newRecorder
    writer <- joined target
    engine <- createOn writer providerNet instanceId Engine.defaultEngineOptions {Engine.telemetrySink = Just (recorderSink recorder)}
    _ <- Engine.deliver engine source' [black] "first" Nothing
    Engine.close engine
    events <- recorded recorder
    any (\e -> "postgres_commit" `isInfixOf` show e) events `shouldBe` True

  it "a construction refused by the Engine (unknown instance) leaves the fence free" $ \target -> do
    instanceId <- freshInstance "pg-only"
    writer <- joined target
    loadOn writer providerNet instanceId Engine.defaultEngineOptions `shouldThrow` valueError "does not exist"
    withPg target True $ \other -> Pg.acquireAuthorityFence other instanceId >>= Pg.releaseAuthorityFence

  it "withEngine closes the Engine and its connection" $ \target -> do
    instanceId <- freshInstance "pg-only"
    writer <- joined target
    port <- inline
    n <- withEngine CreateInstance writer providerNet instanceId port Engine.defaultEngineOptions $ \engine -> do
      _ <- Engine.deliver engine source' [black] "first" Nothing
      length <$> outputTokens engine
    n `shouldBe` 1
    isClosed writer `shouldReturn` True
