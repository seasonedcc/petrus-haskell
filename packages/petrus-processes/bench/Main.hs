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
module Main (main) where

import Control.Exception (bracket)
import Data.ByteString.Char8 qualified as BC
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (ActivityInvocation (..), defaultExecutionPolicy)
import Petrus.Fabric (Envelope, FabricError, ReplyRoute, replyRoute)
import Petrus.Fabric.Postgres (ensureFabricSchema, issueCredential, registerProcess)
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
    Just url | not (null url) -> withScratchDatabase (BC.pack url) (\target -> bracket (Pg.connect target.targetUrl True) Pg.close run)
    _ -> hPutStrLn stderr "PETRUS_TEST_POSTGRES is unset: the petrus-processes registry benchmarks need a server" >> exitFailure

run :: Pg.Connection -> IO ()
run connection = do
  ensureFabricSchema connection
  ensureLifecycleSchema connection
  credential <- issueCredential
  registerProcess connection "parent" credential
  registry <- postgresSpawnRegistry connection "parent" credential
  let item = orError (spec "spawn-1")
      request = orError (callEnvelope "call-1")
      result = orError (resultEnvelope answer request "child" Nothing)
  _ <- claim registry item
  counter <- newIORef (0 :: Int)
  let fresh = do
        n <- atomicModifyIORef' counter (\n -> (n + 1, n))
        pure (orError (spec ("spawn-" <> T.pack (show n) <> "-fresh")))
      activityOver = spawnActivity (spawnRegistry registry) noProvisioning
  defaultMain
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
