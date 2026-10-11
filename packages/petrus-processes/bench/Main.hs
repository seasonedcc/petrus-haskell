-- | Process lifecycle benchmarks, the twins of @bench/python_bench.py@ (same
-- names, same values, same registry operations). The registry rows run
-- against a scratch database created on the server named by
-- PETRUS_TEST_POSTGRES and dropped afterwards.
--
-- * @model.child-identity@: @child_identity(parent, spawn_id)@.
-- * @model.spawn-spec-digest@: build a spawn spec and take its digest.
-- * @model.spawn-spec-roundtrip@: @SpawnSpec.from_data(spec.to_data())@.
-- * @call.request-envelope@: a call request and its request envelope.
-- * @call.result-envelope@: the correlated result envelope for a request.
-- * @call.reply-from-envelope@: validate a result envelope against its
--   request.
-- * @spawn.activity@: the @process.spawn@ Activity over an in-memory
--   registry and a no-op provisioner.
-- * @postgres.claim-prior@: claim an already-claimed spec again.
-- * @postgres.child-of@: a parent-bound lineage lookup.
-- * @postgres.claim-new@: build a spec with a fresh spawn id and claim it
--   (authenticate, insert, read back).
-- * @postgres.spawn-activity@: the @process.spawn@ Activity over the
--   PostgreSQL registry, each with a fresh spawn id.
-- * @call.roundtrip-postgres@: one whole call over the PostgreSQL Fabric
--   (spec/processes.md §6), caller and callee each on its own connection.
--   The caller sends a fresh request envelope; the callee drains it through
--   a door that validates the request and sends the correlated result; the
--   caller drains the reply through a door that validates it against the
--   request.
module Main (main) where

import Control.Exception (bracket)
import Control.Monad (void)
import Data.ByteString.Char8 qualified as BC
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (ActivityInvocation (..), defaultExecutionPolicy)
import Petrus.Fabric (DeliveryDoor (..), DoorAnswer (..), Envelope, FabricError, FabricInbox (..), ReplyRoute, drain, envelopeFromData, replyRoute)
import Petrus.Fabric.Postgres (ensureFabricSchema, exposeSource, grant, inboxClient, issueCredential, postgresFabric, registerProcess, send)
import Petrus.Impetus.Instance.Firing (FiringOutcome (..))
import Petrus.Impetus.Petrinet (Token (..), netPath)
import Petrus.Json (Json (..))
import Petrus.Postgres qualified as Pg
import Petrus.Processes
import Petrus.Processes.Postgres
import Petrus.TestSupport (PostgresTarget (..), withScratchDatabase)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Test.Tasty (localOption)
import Test.Tasty.Bench

capabilities :: Json
capabilities = Object [("tools", Array [String "search", String "fetch"]), ("tier", String "standard")]

config :: Json
config = Object [("prompt", String "summarise"), ("temperature", Float 0.25), ("limits", Object [("tokens", Int 4096)])]

route :: ReplyRoute
route = orError (replyRoute "parent" "replies")

orError :: Either FabricError a -> a
orError = either (error . show) id

spec :: Text -> Either FabricError SpawnSpec
spec spawnId = spawnSpec "parent" spawnId "analysis-agent" "calls" capabilities config (Just route)

callEnvelope :: Text -> Either FabricError Envelope
callEnvelope callId = do
  request <- callRequest callId "answer" (Object [("question", Int 42), ("context", Array [String "a", String "b"])])
  requestEnvelope request "parent" "child" "calls" route Nothing

answer :: CallResult
answer = orError (callResult "call-1" (Object [("answer", Int 42)]))

invocation :: SpawnSpec -> ActivityInvocation
invocation item =
  ActivityInvocation spawnActivityName (spawnSpecToData item) defaultExecutionPolicy Nothing (Just (orError (spawnIdempotency item.parent item.spawnId)))

memoryRegistry :: SpawnRegistry
memoryRegistry =
  SpawnRegistry
    { claim = \v -> either (fail . show) pure (spawnClaim v.parent v.spawnId v.child False)
    , childOf = \_ _ -> pure Nothing
    , childrenOf = \_ -> pure []
    , parentOf = \_ -> pure Nothing
    }

noProvisioning :: ProcessProvisioner
noProvisioning = ProcessProvisioner (\_ -> pure ())

-- | Every node of a value, so a lazily built result is fully evaluated (the
-- reference returns a finished dict).
nodes :: Json -> Int
nodes = \case
  Array items -> 1 + sum (map nodes items)
  Object members -> 1 + sum [T.length key + nodes item | (key, item) <- members]
  String text -> T.length text
  _ -> 1

forced :: Either FabricError a -> ()
forced = either (error . show) (`seq` ())

main :: IO ()
main =
  lookupEnv "PETRUS_TEST_POSTGRES" >>= \case
    Just url | not (null url) -> withScratchDatabase (BC.pack url) (\target -> bracket (Pg.connect target.targetUrl True) Pg.close (run target.targetUrl))
    _ -> hPutStrLn stderr "PETRUS_TEST_POSTGRES is unset: the petrus-processes registry benchmarks need a server" >> exitFailure

run :: BC.ByteString -> Pg.Connection -> IO ()
run url connection = do
  ensureFabricSchema connection
  ensureLifecycleSchema connection
  credential <- issueCredential
  registerProcess connection "parent" credential
  registry <- postgresSpawnRegistry connection "parent" credential
  bracket (Pg.connect url True) Pg.close $ \callerConnection ->
    bracket (Pg.connect url True) Pg.close $ \calleeConnection ->
      benchmarks connection registry callerConnection calleeConnection

-- | Envelope of the delivery a Fabric door received.
delivered :: [Token] -> IO Envelope
delivered = \case
  [t] -> either (fail . show) pure (envelopeFromData t.payload)
  tokens -> fail ("a Fabric delivery is one token, not " <> show (length tokens))

benchmarks :: Pg.Connection -> PostgresSpawnRegistry -> Pg.Connection -> Pg.Connection -> IO ()
benchmarks connection registry callerConnection calleeConnection = do
  let register on name = do
        secret <- issueCredential
        registerProcess connection name secret
        postgresFabric on name secret
  caller <- register callerConnection "caller"
  callee <- register calleeConnection "callee"
  exposeSource callee "calls"
  grant callee "caller" "calls"
  exposeSource caller "replies"
  grant caller "callee" "replies"
  occurrences <- newIORef (0 :: Int)
  outstanding <- newIORef Nothing
  let fired source = do
        path <- either (fail . T.unpack) pure (netPath source)
        n <- atomicModifyIORef' occurrences (\c -> (c + 1, c + 1))
        pure (DoorFired (FiringOutcome path n [] [] []))
      calleeDoor = DeliveryDoor $ \source tokens _ -> do
        request <- delivered tokens
        call <- either (fail . show) pure (requestFromEnvelope request)
        reply <- either (fail . show) pure (callResult call.callId (Object [("answer", Int 42)]) >>= \r -> resultEnvelope r request "callee" Nothing)
        void (send callee reply)
        fired source
      callerDoor = DeliveryDoor $ \source tokens _ -> do
        reply <- delivered tokens
        readIORef outstanding >>= \case
          Just request -> either (fail . show) (`seq` pure ()) (replyFromEnvelope reply request)
          Nothing -> fail "a reply without an outstanding request"
        fired source
      calleeInbox = FabricInbox (inboxClient callee) calleeDoor
      callerInbox = FabricInbox (inboxClient caller) callerDoor
      roundTrip = do
        n <- atomicModifyIORef' occurrences (\c -> (c + 1, c))
        request <- either (fail . show) pure $ do
          call <- callRequest ("call-" <> T.pack (show n)) "answer" (Object [("question", Int 42), ("context", Array [String "a", String "b"])])
          requestEnvelope call "caller" "callee" "calls" (orError (replyRoute "caller" "replies")) Nothing
        writeIORef outstanding (Just request)
        void (send caller request)
        served <- drain calleeInbox 1
        answered <- drain callerInbox 1
        pure (length served + length answered)
  let item = orError (spec "spawn-1")
      request = orError (callEnvelope "call-1")
      result = orError (resultEnvelope answer request "child" Nothing)
  _ <- claim registry item
  counter <- newIORef (0 :: Int)
  let fresh = do
        n <- atomicModifyIORef' counter (\n -> (n + 1, n))
        pure (orError (spec ("spawn-" <> T.pack (show n) <> "-fresh")))
      activityOver = spawnActivity (spawnRegistry registry) noProvisioning
  -- Wall-clock time for every benchmark, as the Python twins measure it
  -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
  -- time spent waiting on the kernel, servers and child processes.
  defaultMain . map (localOption WallTime) $
    [ bgroup
        "model"
        [ bench "child-identity" (whnf (either (error . show) T.length . childIdentity "parent") "spawn-1")
        , bench "spawn-spec-digest" (whnf (either (error . show) (T.length . (.digest)) . spec) "spawn-1")
        , bench "spawn-spec-roundtrip" (whnf (forced . spawnSpecFromData . spawnSpecToData) item)
        ]
    , bgroup
        "call"
        [ bench "request-envelope" (whnf (forced . callEnvelope) "call-1")
        , bench "result-envelope" (whnf (\r -> forced (resultEnvelope answer r "child" Nothing)) request)
        , bench "reply-from-envelope" (whnf (\r -> forced (replyFromEnvelope r request)) result)
        , -- Four commits and two drains against the server: as for the
          -- postgres rows, 5% precision does not converge under load.
          localOption (RelStDev 0.2) (bench "roundtrip-postgres" (whnfIO roundTrip))
        ]
    , bgroup "spawn" [bench "activity" (whnfAppIO (\it -> nodes <$> spawnActivity memoryRegistry noProvisioning (invocation it)) item)]
    , -- Each row is a round trip to the server, and the rows that insert grow
      -- the table they read: 5% precision does not converge under load.
      localOption (RelStDev 0.2) $
        bgroup
          "postgres"
          [ bench "claim-prior" (whnfIO (claim registry item >>= \c -> pure c.priorClaim))
          , bench "child-of" (whnfIO (maybe 0 (T.length . (.child)) <$> childOf registry "parent" "spawn-1"))
          , bench "claim-new" (whnfIO (fresh >>= claim registry >>= \c -> pure c.priorClaim))
          , bench "spawn-activity" (whnfIO (nodes <$> (fresh >>= activityOver . invocation)))
          ]
    ]
