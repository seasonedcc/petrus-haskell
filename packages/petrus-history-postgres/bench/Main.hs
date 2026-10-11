-- | PostgreSQL History store benchmarks, the twins of
-- @bench/python_bench.py@ (same names, same records, same statements),
-- against a scratch database created on the server named by
-- PETRUS_TEST_POSTGRES and dropped afterwards.
--
-- The records are a drained FIFO's History, built identically by both
-- sides: appends write its non-terminal records (so repeated appends never
-- meet the one-terminal indexes), loads read 1 002 and 10 002 of them.
--
-- * @append.autocommit-1@ / @-8@: one batch of 1 or 8 records on an
--   autocommit connection — one owned transaction per batch.
-- * @append.joined-1-commit@ / @-8-commit@: the same batch joined to the
--   caller's transaction, then @COMMIT@ (the Engine's shape).
-- * @load.1k@ / @load.10k@: construct the store over an existing Instance
--   (the load query and decoding every payload into the mirror).
-- * @verify.conflict-acknowledge@: a stale writer appends a fact another
--   writer already recorded value-equal at its position: insert conflicts,
--   re-read, compare, acknowledge.
module Main (main) where

import Control.Exception (finally)
import Data.ByteString.Char8 qualified as BC
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.HistoryStore.Postgres
import Petrus.Impetus.History (Record (..))
import Petrus.Impetus.History.Records (recordName, recordOccurrence)
import Petrus.Impetus.HistoryStore (HistoryStore (..))
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet
import Petrus.Json (Json (..))
import Petrus.Postgres (close, commit, connect, execute_, intParam, nullParam, textParam)
import Petrus.TestSupport (PostgresTarget (..), withScratchDatabase)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Test.Tasty (localOption)
import Test.Tasty.Bench

path :: String -> NetPath
path = either (error . T.unpack) id . netPath . T.pack

item :: Int -> Token
item n = Token (Just "Item") (Object [("seq", Int (fromIntegral n))])

-- | A drained FIFO of @tokens@ items: 5 records per firing plus two.
drained :: Int -> IO [Record]
drained tokens = do
  let queue = path "queue"
      net =
        either (error . T.unpack) id $
          mkNet (netSpec [place queue, place (path "taken")] [transition (path "take")] [arc queue (path "take"), arc (path "take") (path "taken")])
  inst <-
    newInstance net defaultInstanceConfig {initialMarking = markingFromList [(queue, map item [0 .. tokens - 1])], suppliedIdentity = Just "bench"}
      >>= either (error . show) pure
  _ <- run inst >>= either (error . show) pure
  Store.records (instanceHistory inst)

terminal :: Record -> Bool
terminal = \case
  RFiringCompleted _ -> True
  RFiringFailed _ -> True
  RActivityCompleted _ -> True
  RActivityFailed _ -> True
  _ -> False

main :: IO ()
main =
  lookupEnv "PETRUS_TEST_POSTGRES" >>= \case
    Just url | not (null url) -> withScratchDatabase (BC.pack url) (run' . targetUrl)
    _ -> hPutStrLn stderr "PETRUS_TEST_POSTGRES is unset: the petrus-history-postgres benchmarks need a server" >> exitFailure

run' :: BC.ByteString -> IO ()
run' url = do
  auto <- connect url True
  joined <- connect url False
  writer <- connect url True
  ensureSchema auto
  small <- drained 200
  large <- drained 2000
  let appendable = filter (not . terminal) small
      one = take 1 appendable
      eight = take 8 appendable
      ackRecord = case appendable of
        r : _ -> r
        [] -> error "no appendable record"
  -- Existing Instances for the load benchmarks.
  openPostgresHistoryStore writer "load-1k" >>= \s -> s.extend small
  openPostgresHistoryStore writer "load-10k" >>= \s -> s.extend large
  -- A stale writer, opened over an empty Instance before another writer
  -- recorded the same fact at every position it will append to.
  stale <- openPostgresHistoryStore auto "verify"
  payload <- either (error . T.unpack) pure (encodePayload ackRecord)
  execute_
    writer
    "INSERT INTO impetus.semantic_events (event_id, net_instance_id, record_type, occurrence, payload) SELECT 'verify:' || n, 'verify', %s, %s, %s::jsonb FROM generate_series(0, 299999) AS n"
    [textParam (recordName ackRecord), maybe nullParam (intParam . fromIntegral) (recordOccurrence ackRecord), textParam (TE.decodeUtf8 payload)]
  -- Fresh Instances for the appends.
  autoStore <- openPostgresHistoryStore auto "append-auto"
  joinedStore <- openPostgresHistoryStore joined "append-joined"
  commit joined
  flip finally (mapM_ close [auto, joined, writer]) $
    -- Wall-clock time for every benchmark, as the Python twins measure it
    -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
    -- time spent waiting on the kernel, servers and child processes.
    defaultMain . map (localOption WallTime) $
      [ localOption (RelStDev 0.2) $
          bgroup
            "append"
            [ bench "autocommit-1" (whnfIO (autoStore.extend one))
            , bench "autocommit-8" (whnfIO (autoStore.extend eight))
            , bench "joined-1-commit" (whnfIO (joinedStore.extend one >> commit joined))
            , bench "joined-8-commit" (whnfIO (joinedStore.extend eight >> commit joined))
            ]
      , localOption (RelStDev 0.2) $
          bgroup
            "load"
            [ bench "1k" (nfIO (openPostgresHistoryStore auto "load-1k" >>= (.count)))
            , bench "10k" (nfIO (openPostgresHistoryStore auto "load-10k" >>= (.count)))
            ]
      , localOption (RelStDev 0.2) $
          bgroup
            "verify"
            [ bench "conflict-acknowledge" (whnfIO (stale.extend [ackRecord]))
            ]
      ]
