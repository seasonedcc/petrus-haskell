-- | Fabric benchmarks, the twins of @bench/python_bench.py@ (same names,
-- same values, same store operations). The store rows run against a scratch
-- database created on the server named by PETRUS_TEST_POSTGRES and dropped
-- afterwards.
--
-- * @envelope.build@: construct and validate an envelope around a nested
--   payload (strict-JSON check, canonical size measurement).
-- * @envelope.digest@: build that envelope and take its SHA-256 digest
--   (the reference recomputes it on each access, so both sides build fresh).
-- * @envelope.roundtrip@: @Envelope.from_data(item.to_data())@.
-- * @canonical.16KiB@: canonical bytes of a 250-row payload (~16 KiB).
-- * @postgres.submit@: submit a new delivery (authenticate, grant check,
--   insert, commit), each with a fresh delivery id.
-- * @postgres.submit-duplicate@: an exact retransmission of a stored
--   delivery (answered as a duplicate).
-- * @postgres.send-drain@: send one delivery, then drain the recipient's
--   inbox through a door that answers a firing outcome (pending, deliver,
--   acknowledge).
-- * @postgres.discover@: a capability-filtered discovery.
module Main (main) where

import Control.Exception (bracket)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Fabric
import Petrus.Fabric.Postgres
import Petrus.Impetus.Instance.Firing (FiringOutcome (..))
import Petrus.Impetus.Petrinet (netPath)
import Petrus.Json (Json (..))
import Petrus.Postgres qualified as Pg
import Petrus.TestSupport (PostgresTarget (..), withScratchDatabase)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Test.Tasty (localOption)
import Test.Tasty.Bench

payload :: Json
payload =
  Object
    [ ("command", String "go")
    , ("args", Object [("items", Array (map Int [1 .. 5])), ("flag", Bool True), ("ratio", Float 0.5)])
    , ("text", String "hello world")
    , ("nested", Object [("a", Object [("b", Object [("c", Array [Null, String "x"])])])])
    ]

large :: Json
large =
  Object
    [ ( "rows"
      , Array
          [ Object
              [ ("id", Int i)
              , ("name", String ("row-" <> T.pack (show i)))
              , ("tags", Array [String "a", String "b"])
              , ("score", Float (fromIntegral i * 0.5))
              ]
          | i <- [0 .. 249]
          ]
      )
    ]

route :: ReplyRoute
route = either (error . show) id (replyRoute "sender" "replies/finish")

build :: Text -> Text -> Json -> Either FabricError Envelope
build deliveryId recipient p = envelope deliveryId "sender" recipient "commands/start" "conversation-1" p (Just route)

forced :: Either FabricError Envelope -> ()
forced = either (error . show) (`seq` ())

main :: IO ()
main =
  lookupEnv "PETRUS_TEST_POSTGRES" >>= \case
    Just url | not (null url) -> withScratchDatabase (BC.pack url) (\target -> bracket (Pg.connect target.targetUrl True) Pg.close run)
    _ -> hPutStrLn stderr "PETRUS_TEST_POSTGRES is unset: the petrus-fabric store benchmarks need a server" >> exitFailure

run :: Pg.Connection -> IO ()
run connection = do
  ensureFabricSchema connection
  let register name = do
        credential <- issueCredential
        registerProcess connection name credential
        postgresFabric connection name credential
  sender <- register "sender"
  recipient <- register "recipient"
  drainer <- register "drain-recipient"
  mapM_
    ( \r -> do
        exposeSource r "commands/start"
        grant r "sender" "commands/start"
    )
    [recipient, drainer]
  offerService recipient "commands/start" "worker" (Object [("model", String "large"), ("region", String "eu")])
  item <- orThrow (build "delivery-1" "recipient" payload)
  stored <- orThrow (build "stored" "recipient" payload)
  _ <- submit sender stored
  counter <- newIORef (0 :: Int)
  let next = atomicModifyIORef' counter (\n -> (n + 1, n))
      fresh to = do
        n <- next
        orThrow (build ("d-" <> T.pack (show n)) to payload)
      door = DeliveryDoor $ \source _ _ -> do
        path <- either (fail . T.unpack) pure (netPath source)
        n <- next
        pure (DoorFired (FiringOutcome path (n + 1) [] [] []))
      inbox = FabricInbox (inboxClient drainer) door
      required = Just (Object [("model", String "large")])
  -- Wall-clock time for every benchmark, as the Python twins measure it
  -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
  -- time spent waiting on the kernel, servers and child processes.
  defaultMain . map (localOption WallTime) $
    [ bgroup
        "envelope"
        [ bench "build" (whnf (forced . build "delivery-1" "recipient") payload)
        , bench "digest" (whnf (either (error . show) (T.length . (.digest)) . build "delivery-1" "recipient") payload)
        , bench "roundtrip" (whnf (forced . envelopeFromData . envelopeToData) item)
        ]
    , bgroup "canonical" [bench "16KiB" (whnf (either (error . show) BS.length . canonicalBytes) large)]
    , bgroup
        "postgres"
        [ bench "submit" (whnfIO (fresh "recipient" >>= submit sender >>= \s -> pure s.duplicate))
        , bench "submit-duplicate" (whnfIO (submit sender stored >>= \s -> pure s.duplicate))
        , bench "send-drain" (whnfIO (fresh "drain-recipient" >>= send sender >> length <$> drain inbox 1))
        , bench "discover" (whnfIO (length <$> discover sender "worker" required))
        ]
    ]
