-- | petrus-postgres hot paths against the server named by
-- PETRUS_TEST_POSTGRES (session-local temporary tables only). Each
-- benchmark has a same-named counterpart in @bench/python_bench.py@ that
-- runs the upstream psycopg code path; run both with
-- @scripts/bench petrus-postgres@.
module Main (main) where

import Control.Exception (finally)
import Control.Monad (forM_)
import Data.ByteString.Char8 qualified as BC
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text qualified as T
import Petrus.Postgres
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Test.Tasty (localOption)
import Test.Tasty.Bench

insertEvent :: Sql
insertEvent =
  "INSERT INTO bench_events (event_id, net_instance_id, record_type, occurrence, payload) VALUES (%s, %s, %s, %s, %s::jsonb) ON CONFLICT DO NOTHING"

payload :: T.Text
payload = "{\"type\": \"FiringStarted\", \"occurrence\": 7, \"transition\": \"t\", \"instant\": \"2026-01-01T00:00:00+00:00\", \"tokens\": [1, 2, 3]}"

createEvents :: Sql
createEvents =
  "CREATE TEMPORARY TABLE bench_events (sequence bigserial PRIMARY KEY, event_id text UNIQUE NOT NULL, net_instance_id text NOT NULL, record_type text NOT NULL, occurrence bigint, payload jsonb NOT NULL)"

main :: IO ()
main =
  lookupEnv "PETRUS_TEST_POSTGRES" >>= \case
    Just url | not (null url) -> run (BC.pack url)
    _ -> hPutStrLn stderr "PETRUS_TEST_POSTGRES is unset: the petrus-postgres benchmarks need a server" >> exitFailure

run :: BC.ByteString -> IO ()
run url = do
  auto <- connect url True
  joined <- connect url False
  listener <- connect url True
  sender <- connect url True
  execute_ auto createEvents []
  execute_ joined createEvents []
  commit joined
  execute_ auto "CREATE TEMPORARY TABLE bench_rows (n int PRIMARY KEY, label text, payload jsonb)" []
  execute_ auto "INSERT INTO bench_rows SELECT n, 'label-' || n, jsonb_build_object('n', n, 'tags', jsonb_build_array('a', 'b'), 'ok', true) FROM generate_series(1, 1000) AS n" []
  listen listener "petrus_bench"
  next <- newIORef (0 :: Int)
  let fresh = atomicModifyIORef' next (\n -> (n + 1, n))
      event connection prefix = do
        n <- fresh
        execute connection insertEvent [textParam (prefix <> T.pack (show n)), textParam "bench", textParam "FiringStarted", intParam 7, textParam payload]
      decodeRow = \case
        [n, label, json] -> do
          a <- column decodeInt n
          b <- column decodeText label
          c <- column decodeJson json
          pure (a, b, c)
        _ -> Left "unexpected row shape"
  flip finally (mapM_ close [auto, joined, listener, sender]) $
    -- Wall-clock time for every benchmark, as the Python twins measure it
    -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
    -- time spent waiting on the kernel, servers and child processes.
    defaultMain . map (localOption WallTime) $
      [ -- Everything that crosses to the server rides on the scheduler of a
        -- possibly loaded machine, and commits wait for the WAL flush: allow
        -- a wider spread than the global --stdev, or a busy machine never
        -- converges.
        localOption (RelStDev 0.2) $
          bgroup
            "roundtrip"
            [ bench "select-1" (nfIO (query auto "SELECT 1" []))
            , bench "select-param" (nfIO (query auto "SELECT %s::int8 + 1" [intParam 41]))
            ]
      , localOption (RelStDev 0.2) $
          bgroup
            "query"
            [ bench "select-1000-decoded" (nfIO (either error length . traverse decodeRow <$> query auto "SELECT n, label, payload FROM bench_rows ORDER BY n" []))
            ]
      , localOption (RelStDev 0.2) $
          bgroup
            "tx"
            [ bench "join-insert-commit" (whnfIO (event joined "j" >> commit joined))
            , bench "owned-insert-10" (whnfIO (withTransaction auto (forM_ [1 .. 10 :: Int] (\_ -> event auto "o"))))
            ]
      , localOption (RelStDev 0.2) $
          bgroup
            "fence"
            [ bench "acquire-release" (whnfIO (acquireAuthorityFence auto "petrus-bench-fence" >>= releaseAuthorityFence))
            ]
      , -- A notification crosses two server processes: wider still.
        localOption (RelStDev 0.25) $
          bgroup
            "notify"
            [ bench "roundtrip" (nfIO (notify sender "petrus_bench" "q" >> fmap notificationPayload <$> waitForNotification listener 5))
            ]
      , bgroup
          "params"
          [ bench "convert-placeholders" (nf (fmap fst . convertPlaceholders) (sqlSource insertEvent))
          ]
      ]
