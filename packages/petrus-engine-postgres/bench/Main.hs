-- | PostgreSQL Engine benchmarks, the twins of @bench/python_bench.py@
-- (same names, same net, same doors), against a scratch database created
-- on the server named by PETRUS_TEST_POSTGRES and dropped afterwards.
--
-- * @engine.deliver@: one identified delivery through the provider's
--   joined transaction — accept (CandidateSelected, ExternalEventDelivered,
--   FiringBegun, commit) and complete (TokensProduced, FiringCompleted,
--   commit). Every 256 deliveries the Engine is closed and a fresh one is
--   created on a fresh connection (fence, empty load, construction commit),
--   so the in-memory History and marking stay bounded on both sides; that
--   cost is amortized into the figure on both sides alike.
-- * @engine.redeliver-prior@: an exact redelivery of a completed identity —
--   the door answers the prior acknowledgement from memory, commits nothing.
-- * @engine.create-close@: connect, take the fence, load the (absent)
--   History, create the Instance, commit, close (unlock, close).
module Main (main) where

import Control.Exception (finally)
import Control.Monad (void, when)
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Engine (Engine)
import Petrus.Engine qualified as Engine
import Petrus.Engine.Postgres (createEngine)
import Petrus.HistoryStore.Postgres (ensureSchema)
import Petrus.Impetus.Petrinet
import Petrus.Motus.Dispatch.Inline (inlineDispatch, newInlineDispatch)
import Petrus.Postgres (close, connect)
import Petrus.TestSupport (PostgresTarget (..), withScratchDatabase)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Test.Tasty (localOption)
import Test.Tasty.Bench

path :: String -> NetPath
path = either (error . T.unpack) id . netPath . T.pack

source', output :: NetPath
source' = path "source"
output = path "output"

providerNet :: Net
providerNet = either (error . T.unpack) id (mkNet (netSpec [place output] [transition source'] [arc source' output]))

rotation :: Int
rotation = 256

main :: IO ()
main =
  lookupEnv "PETRUS_TEST_POSTGRES" >>= \case
    Just url | not (null url) -> withScratchDatabase (BC.pack url) (run' . targetUrl)
    _ -> hPutStrLn stderr "PETRUS_TEST_POSTGRES is unset: the petrus-engine-postgres benchmarks need a server" >> exitFailure

run' :: BC.ByteString -> IO ()
run' url = do
  setup <- connect url True
  ensureSchema setup
  close setup
  counter <- newIORef (0 :: Int)
  let fresh prefix = do
        n <- atomicModifyIORef' counter (\c -> (c + 1, c))
        pure (prefix <> T.pack (show n))
      open :: Text -> IO Engine
      open instanceId = do
        connection <- connect url False
        port <- inlineDispatch <$> newInlineDispatch mempty
        createEngine connection providerNet instanceId port Engine.defaultEngineOptions
  current <- fresh "deliver-" >>= open >>= newIORef
  delivered <- newIORef (0 :: Int)
  prior <- fresh "prior-" >>= open
  void (Engine.deliver prior source' [black] "known" Nothing)
  let deliverOne = do
        n <- atomicModifyIORef' delivered (\c -> (c + 1, c + 1))
        when (n `mod` rotation == 0) $ do
          readIORef current >>= Engine.close
          fresh "deliver-" >>= open >>= writeIORef current
        engine <- readIORef current
        identity <- fresh "d"
        Engine.deliver engine source' [black] identity Nothing
      createClose = fresh "create-" >>= open >>= Engine.close
  flip finally (readIORef current >>= Engine.close >> Engine.close prior) $
    -- Wall-clock time for every benchmark, as the Python twins measure it
    -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
    -- time spent waiting on the kernel, servers and child processes.
    defaultMain . map (localOption WallTime) $
      [ localOption (RelStDev 0.2) $
          bgroup
            "engine"
            [ bench "deliver" (whnfIO deliverOne)
            , bench "redeliver-prior" (whnfIO (Engine.deliver prior source' [black] "known" Nothing))
            , bench "create-close" (whnfIO createClose)
            ]
      ]
