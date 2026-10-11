-- | Kernel benchmarks, the twins of @bench/python_bench.py@: the same nets,
-- markings, and sizes, so @bench/RESULTS.md@ can set the two side by side.
--
-- Workloads: candidate enumeration on a wide fan-in, a long FIFO queue, and a
-- weight-3 arc; whole Instance runs (begin, complete, durable append, mirror)
-- on a wide fan-out and a long FIFO; History encode, decode, and replay of a
-- 20 002-record History; Net definition v3 parse and serialize of a 200-place
-- chain.
module Main (main) where


import Data.ByteString qualified as BS
import Data.Either (fromRight)
import Data.Text qualified as T
import Petrus.Impetus.History (Record)
import Petrus.Impetus.History.Codec (decodeRecord, encodeHistory)
import Petrus.Impetus.History.Replay (replayMarking)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance hiding (candidates)
import Petrus.Impetus.NetDefinition (NetDefinitionV3 (..), NetDefinitionBody (..), parseNetDefinition, projectNetDefinition, serializeNetDefinition)
import Petrus.Impetus.Petrinet
import Petrus.Json
import Test.Tasty (localOption)
import Test.Tasty.Bench

fanInPlaces, fanInTokens, fifoTokens, weightTokens, fanOutPlaces, fanOutTokens, runFifoTokens, historyFifoTokens, chainLength :: Int
fanInPlaces = 6
fanInTokens = 3
fifoTokens = 10000
weightTokens = 30
fanOutPlaces = 50
fanOutTokens = 200
runFifoTokens = 1000
historyFifoTokens = 4000
chainLength = 200

path :: String -> NetPath
path = either (error . T.unpack) id . netPath . T.pack

item :: Int -> Token
item n = Token (Just "Item") (Object [("seq", Int (fromIntegral n))])

built :: [Place] -> [Transition] -> [Arc] -> Net
built ps ts as = either (error . T.unpack) id (mkNet (netSpec ps ts as))

wideFanIn :: (Net, Marking)
wideFanIn =
  ( built
      (map (place . inbound) [0 .. fanInPlaces - 1] <> [place (path "out")])
      [transition (path "t")]
      ([arc (inbound i) (path "t") | i <- [0 .. fanInPlaces - 1]] <> [arc (path "t") (path "out")])
  , markingFromList [(inbound i, map item [0 .. fanInTokens - 1]) | i <- [0 .. fanInPlaces - 1]]
  )
  where
    inbound i = path ("in" <> show i)

fifo :: Int -> Int -> (Net, Marking)
fifo tokens w =
  ( built
      [place queue, place (path "taken")]
      [transition (path "take")]
      [(arc queue (path "take")) {weight = w}, arc (path "take") (path "taken")]
  , markingFromList [(queue, map item [0 .. tokens - 1])]
  )
  where
    queue = path "queue"

wideFanOut :: (Net, Marking)
wideFanOut =
  ( built
      (place (path "src") : [place (outbound i) | i <- [0 .. fanOutPlaces - 1]])
      [transition (path "t")]
      (arc (path "src") (path "t") : [arc (path "t") (outbound i) | i <- [0 .. fanOutPlaces - 1]])
  , markingFromList [(path "src", map item [0 .. fanOutTokens - 1])]
  )
  where
    outbound i = path ("out" <> show i)

chain :: Net
chain =
  either (error . T.unpack) id $
    mkNet (NetSpec [coloredPlace (p i) "Item" | i <- [0 .. chainLength - 1]] [transition (t i) | i <- [0 .. chainLength - 2]] arcs Nothing (Just "chain"))
  where
    p i = path ("p" <> show i)
    t i = path ("t" <> show i)
    arcs = concat [[arc (p i) (t i), arc (t i) (p (i + 1))] | i <- [0 .. chainLength - 2]]

-- | Construct and run an Instance to quiescence; the number of firings.
runInstance :: (Net, Marking) -> IO Int
runInstance (net, initial) = do
  inst <- either (fail . T.unpack . renderInstanceError) pure =<< newInstance net defaultInstanceConfig {initialMarking = initial, suppliedIdentity = Just "bench"}
  either (fail . T.unpack . renderInstanceError) (pure . length) =<< run inst

drainedHistory :: Int -> IO [Record]
drainedHistory tokens = do
  let (net, initial) = fifo tokens 1
  inst <- either (fail . T.unpack . renderInstanceError) pure =<< newInstance net defaultInstanceConfig {initialMarking = initial, suppliedIdentity = Just "bench"}
  _ <- run inst
  Store.records (instanceHistory inst)

enumerate :: (Net, Marking) -> Int
enumerate (net, m) = either (error . show) length (candidates net m noImplementations Nothing)

tokenCount :: Marking -> Int
tokenCount m = sum [length ts | (_, ts) <- markingToList m]

-- | The parsed definition's element counts, which force every list spine.
definitionSize :: NetDefinitionV3 -> Int
definitionSize d = length d.definition.places + length d.definition.transitions + length d.definition.arcs

-- | Visit every node of a parsed value (numbers and strings included), so
-- the parse-only row pays for every value it produces.
jsonWeight :: Json -> Int
jsonWeight = \case
  Null -> 1
  Bool b -> if b then 1 else 2
  Int i -> if i == 0 then 1 else 2
  Float d -> if d == 0 then 1 else 2
  String s -> if T.null s then 1 else 2
  Array xs -> foldr (\x acc -> jsonWeight x + acc) 1 xs
  Object ms -> foldr (\(k, v) acc -> (if T.null k then 1 else 2) + jsonWeight v + acc) 1 ms

main :: IO ()
main = do
  history <- drainedHistory historyFifoTokens
  let recordValues = Array (encodeHistory history)
      encoded = fromRight (error "encode") (dumps defaultDumps (Array (encodeHistory history)))
      definition = fromRight (error "project") (projectNetDefinition chain)
      payload = fromRight (error "serialize") (serializeNetDefinition definition)
      decodeAll raw = case parseJson pythonLoads raw of
        Right (Array xs) -> either (error . T.unpack) length (traverse decodeRecord xs)
        _ -> error "decode"
  -- Wall-clock time for every benchmark, as the Python twins measure it
  -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
  -- time spent waiting on the kernel, servers and child processes.
  defaultMain . map (localOption WallTime) $
    [ bgroup
        "candidates"
        [ bench "wide-fanin" (nf enumerate wideFanIn)
        , bench "long-fifo" (nf enumerate (fifo fifoTokens 1))
        , bench "weight-3" (nf enumerate (fifo weightTokens 3))
        ]
    , bgroup
        "instance-run"
        [ bench "wide-fanout" (nfIO (runInstance wideFanOut))
        , bench "long-fifo" (nfIO (runInstance (fifo runFifoTokens 1)))
        ]
    , bgroup
        "history"
        [ bench "encode" (nf (\h -> either (error "encode") BS.length (dumps defaultDumps (Array (encodeHistory h)))) history)
        , bench "dumps-only" (nf (either (error "encode") BS.length . dumps defaultDumps) recordValues)
        , bench "parse-only" (nf (either error jsonWeight . parseJson pythonLoads) encoded)
        , bench "decode" (nf decodeAll encoded)
        , bench "records-only" (nf (either (error . T.unpack) length . traverse decodeRecord) (encodeHistory history))
        , bench "replay-marking" (nf (either (error . T.unpack) tokenCount . replayMarking) history)
        ]
    , bgroup
        "net-definition"
        [ bench "serialize" (nf (either (error . T.unpack) BS.length . serializeNetDefinition) definition)
        , bench "parse" (nf (either (error . T.unpack) definitionSize . parseNetDefinition) payload)
        ]
    ]
