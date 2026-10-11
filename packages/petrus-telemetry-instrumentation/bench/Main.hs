-- | Telemetry overhead, the twin of @bench/python_bench.py@:
--
-- * __emit__: 1 000 emits of one 6-field payload through a logger with bound
--   context (@instance@, @net@), with the level 'Off'; at 'Facts' with no
--   route (the default: the line is not even formatted); at 'Facts' with a
--   null route (the line is formatted, then dropped: the reference's
--   @NullHandler@); and under 'capture' (a recorder).
-- * __chain__: 50 tokens through 20 passthrough transitions (1 000
--   firings), driven by 'run' on an Instance and by one-action
--   'Engine.advance' turns, with telemetry off, facts with no route, and
--   facts with a null route.
-- * __line__: where the routed emit's time goes: 'telemetryLine' alone
--   on the full 9-field payload, and 'wallClockMs' alone (1 000 each).
--
-- On start-up it prints the routed line for the emit payload with @ts@
-- pinned; @python_bench.py@ prints the same bytes, and the differential
-- test checks them.
module Main (main) where

import Control.Exception (evaluate)
import Control.Monad (forM_, void, when)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text qualified as T
import Petrus.Engine qualified as Engine
import Petrus.Engine.Scenario (chainMarking, chainNet)
import Petrus.Impetus.HistoryStore (inMemoryHistoryStore)
import Petrus.Impetus.Instance (InstanceConfig (..), defaultInstanceConfig, newInstance, run)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch.InMemory (inMemoryDispatch, newInMemoryDispatch)
import Petrus.Telemetry
import Test.Tasty (localOption)
import Test.Tasty.Bench

emits, chainLength, chainTokens :: Int
emits = 1000
chainLength = 20
chainTokens = 50

-- | @get_logger("impetus").bind(instance="i-1", net="n")@.
logger :: TelemetryLogger
logger = either (error . T.unpack) id (bind [("instance", String "i-1"), ("net", String "n")] (getLogger "impetus" Nothing))

payload :: Int -> Payload
payload occurrence =
  [ ("transition", String "t")
  , ("occurrence", Int (fromIntegral occurrence))
  , ("instant", Int 7)
  , ("records", Int 3)
  , ("impure", Bool False)
  , ("source", String "s")
  ]

-- | The payload 'emit' hands the sink: event, bound context, fields.
fullPayload :: Int -> Payload
fullPayload occurrence = [("event", String "impetus_firing_completed"), ("instance", String "i-1"), ("net", String "n")] ++ payload occurrence

emitBatch :: IO ()
emitBatch = forM_ [0 .. emits - 1] $ \occurrence -> emit logger "firing_completed" (payload occurrence)

-- | A route that forces the formatted line, then drops it.
nullRoute :: BS.ByteString -> IO ()
nullRoute line = void (evaluate (BS.length line))

data Configuration = Configuration String Level (Maybe (BS.ByteString -> IO ()))

configurations :: [Configuration]
configurations =
  [ Configuration "off" Off Nothing
  , Configuration "facts-no-route" Facts Nothing
  , Configuration "facts-null-route" Facts (Just nullRoute)
  ]

configured :: Configuration -> IO a -> IO a
configured (Configuration _ lvl route) action = setLevel lvl >> setRoute route >> action

instanceChain :: IO Int
instanceChain = do
  created <- newInstance (chainNet chainLength) defaultInstanceConfig {initialMarking = chainMarking chainTokens, suppliedIdentity = Just "chain"}
  inst <- either (fail . show) pure created
  outcomes <- run inst >>= either (fail . show) pure
  pure (length outcomes)

engineChain :: IO Int
engineChain = do
  store <- inMemoryHistoryStore
  port <- inMemoryDispatch <$> newInMemoryDispatch
  engine <- Engine.create (chainNet chainLength) "chain" store port Engine.defaultEngineOptions {Engine.marking = chainMarking chainTokens}
  let loop = Engine.advance engine >>= \outcome -> when outcome.ready loop
  loop
  size <- length <$> Engine.records engine
  Engine.close engine
  pure size

pinnedLine :: IO BS.ByteString
pinnedLine = do
  captured <- capture Nothing (Just Facts) $ \recorder -> emit logger "firing_completed" (payload 1) >> recorded recorder
  case captured of
    [one] -> either fail pure (telemetryLine 1700000000123 one)
    other -> fail ("expected one payload, got " <> show other)

main :: IO ()
main = do
  BC.putStrLn . ("pinned line: " <>) =<< pinnedLine
  -- The result sizes python_bench.py prints, as a check that both sides time
  -- the same work.
  firings <- instanceChain
  records' <- engineChain
  putStrLn ("sizes: instance-run " <> show firings <> ", engine-advance " <> show records')
  -- Wall-clock time for every benchmark, as the Python twins measure it
  -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
  -- time spent waiting on the kernel, servers and child processes.
  defaultMain . map (localOption WallTime) $
    [ bgroup
        "emit-x1000"
        ( [bench name (whnfIO (configured c emitBatch)) | c@(Configuration name _ _) <- configurations]
            ++ [bench "recorder" (whnfIO (capture Nothing (Just Facts) (const emitBatch)))]
        )
    , -- Where the routed emit's time goes: formatting the line alone, and
      -- reading the wall clock alone.
      bgroup
        "line-x1000"
        [ bench "telemetryLine" (whnfIO (forM_ [0 .. emits - 1] $ \occurrence -> either fail (void . evaluate . BS.length) (telemetryLine 1700000000123 (fullPayload occurrence))))
        , bench "wallClockMs" (whnfIO (forM_ [1 .. emits] $ \_ -> void (evaluate =<< wallClockMs)))
        ]
    , bgroup
        "chain"
        [ bgroup "instance-run" [bench name (whnfIO (configured c instanceChain)) | c@(Configuration name _ _) <- configurations]
        , bgroup "engine-advance" [bench name (whnfIO (configured c engineChain)) | c@(Configuration name _ _) <- configurations]
        ]
    ]
