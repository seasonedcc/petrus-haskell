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
-- * @engine.advance-chain@: petrus-engine's order scenario
--   ("Petrus.Engine.Scenario") through the joined transaction: one
--   identified order delivered, then one-action turns to rest — the pure
--   validation, the inline @charge_card@ Activity round trip (request,
--   result, projection), the 'Delay 5' maturation and the settlement, each
--   committed. The Engine rotates every 256 orders, as for @engine.deliver@.
-- * @engine.load@: connect, take the fence, load and replay the History of
--   an Instance that settled 100 orders, one reconciling turn, close.
module Main (main) where

import Control.Exception (finally)
import Control.Monad (forM_, void, when)
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Engine (Engine)
import Petrus.Engine qualified as Engine
import Petrus.Engine.Postgres (createEngine, loadEngine)
import Petrus.Engine.Scenario (orderActivities, orderIdentity, orderNet, orderOptions)
import Petrus.HistoryStore.Postgres (ensureSchema)
import Petrus.Impetus.Petrinet
import Petrus.Impetus.TestSupport (tokD)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch (Dispatch)
import Petrus.Motus.Dispatch.Inline (inlineDispatch, newInlineDispatch)
import Petrus.Postgres (Connection, close, connect)
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

-- | The settled orders behind @engine.load@.
loadedOrders :: Int
loadedOrders = 100

intake :: NetPath
intake = path "intake"

advanceUntilRest :: Engine -> IO ()
advanceUntilRest engine = do
  outcome <- Engine.advance engine
  when outcome.ready (advanceUntilRest engine)

-- | Deliver order @o-k@ (amount 1) as @evt_k@ and drive it to rest.
settleOrder :: Engine -> Int -> IO ()
settleOrder engine k = do
  let key = T.pack (show k)
  void (Engine.deliver engine intake [tokD "Order" (Object [("id", String ("o-" <> key)), ("amount", Int 1)])] ("evt_" <> key) Nothing)
  advanceUntilRest engine

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
      openOrders :: (Connection -> Net -> Text -> Dispatch -> Engine.EngineOptions -> IO Engine) -> Text -> IO Engine
      openOrders door instanceId = do
        connection <- connect url False
        port <- orderActivities
        prepared <- newIORef 0
        door connection orderNet instanceId port (orderOptions prepared)
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
  chain <- fresh (orderIdentity <> "-") >>= openOrders createEngine >>= newIORef
  settled <- newIORef (0 :: Int)
  let advanceChain = do
        n <- atomicModifyIORef' settled (\c -> (c + 1, c + 1))
        when (n `mod` rotation == 0) $ do
          readIORef chain >>= Engine.close
          fresh (orderIdentity <> "-") >>= openOrders createEngine >>= writeIORef chain
        engine <- readIORef chain
        settleOrder engine n
  loaded <- openOrders createEngine "load-existing"
  forM_ [1 .. loadedOrders] (settleOrder loaded)
  loadedRecords <- length <$> Engine.records loaded
  settledTokens <- length . placeTokens (path "done") <$> Engine.marking loaded
  Engine.close loaded
  -- What python_bench.py prints too, as a check that both sides time the
  -- same work.
  putStrLn ("sizes: engine.load " <> show loadedRecords <> " records, " <> show settledTokens <> " settled")
  let loadOne = do
        engine <- openOrders loadEngine "load-existing"
        _ <- Engine.advance engine
        Engine.close engine
  flip finally (readIORef current >>= Engine.close >> Engine.close prior >> readIORef chain >>= Engine.close) $
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
            , bench "advance-chain" (whnfIO advanceChain)
            , bench "load" (whnfIO loadOne)
            ]
      ]
