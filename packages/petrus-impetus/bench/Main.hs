-- | Kernel benchmarks, the twins of @bench/python_bench.py@: the same nets,
-- markings, and sizes, so @bench/RESULTS.md@ can set the two side by side.
--
-- Workloads: candidate enumeration on a wide fan-in, a long FIFO queue, and a
-- weight-3 arc; whole Instance runs (begin, complete, durable append, mirror)
-- on a wide fan-out and a long FIFO; History encode, decode, and replay of a
-- 20 002-record History; Net definition v3 parse, serialize, and compile of a
-- 200-place chain; Net document v1 parse and serialize of that chain with a
-- full view and a 50-entry lineage; a delayed self-loop driven through
-- maturation and wake; a lifecycle scope filled by 200 scoped deliveries,
-- then closed or reset.
module Main (main) where

import Control.Monad (forM_, void)
import Data.ByteString qualified as BS
import Data.Either (fromRight)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Petrus.Impetus.History (Record)
import Petrus.Impetus.History.Codec (decodeRecord, encodeHistory)
import Petrus.Impetus.History.Replay (replayMarking)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance hiding (candidates)
import Petrus.Impetus.NetDefinition (NetDefinitionV3 (..), NetDefinitionBody (..), compileNetDefinition, parseNetDefinition, projectNetDefinition, serializeNetDefinition)
import Petrus.Impetus.NetDocument (ExecutionLineage (..), NetDocumentV1 (..), netDocumentFromJson, netDocumentToJson, parseNetDocument, projectNetDocument, serializeNetDocument)
import Petrus.Impetus.Petrinet hiding (nextMaturation)
import Petrus.Impetus.Scope (LifecycleScope, scopeGeneration)
import Petrus.Json
import Test.Tasty (localOption)
import Test.Tasty.Bench

fanInPlaces, fanInTokens, fifoTokens, weightTokens, fanOutPlaces, fanOutTokens, runFifoTokens, historyFifoTokens, chainLength, timerTokens, timerFirings, scopeDeliveries, lineageEntries :: Int
fanInPlaces = 6
fanInTokens = 3
fifoTokens = 10000
weightTokens = 30
fanOutPlaces = 50
fanOutTokens = 200
runFifoTokens = 1000
historyFifoTokens = 4000
chainLength = 200
timerTokens = 50
timerFirings = 500
scopeDeliveries = 200
lineageEntries = 50

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

-- | The chain with a position for every node and a 50-entry lineage (the
-- Python twin's @chain_document@).
chainDocument :: NetDocumentV1
chainDocument = either (error . T.unpack) id $ do
  base <- projectNetDocument chain (Just positions) Nothing
  case netDocumentToJson base of
    Object members -> netDocumentFromJson (Object ([m | m@(k, _) <- members, k /= "lineage"] <> [("lineage", lineage)]))
    _ -> Left "a document is an object"
  where
    positions =
      [(T.pack ("p" <> show i), (IntNumber (fromIntegral (i * 10)), IntNumber 0)) | i <- [0 .. chainLength - 1]]
        <> [(T.pack ("t" <> show i), (IntNumber (fromIntegral (i * 10 + 5)), FloatNumber 1.5)) | i <- [0 .. chainLength - 2]]
    lineage = Object [("head", Int (fromIntegral (lineageEntries - 1))), ("entries", Array (map entry [0 .. lineageEntries - 1]))]
    entry n =
      Object
        [ ("id", Int (fromIntegral n))
        , ("parent", if n == 0 then Null else Int (fromIntegral (n - 1)))
        , ("provenance", String "simulated")
        , ("marking", Array [Object [("place", String (T.pack ("p" <> show n))), ("tokens", Array [Object [("color", String "Item"), ("data", Object [("seq", Int (fromIntegral n))])]])]])
        , ("metadata", Object [("step", Int (fromIntegral n))])
        ]

-- | A delayed self-loop: every firing re-enters its token, maturing a second
-- later.
timerRing :: (Net, Marking)
timerRing =
  ( built [place ring] [(transition tick) {timers = [Delay (IntNumber 1)]}] [arc ring tick, arc tick ring]
  , markingFromList [(ring, map item [0 .. timerTokens - 1])]
  )
  where
    ring = path "ring"
    tick = path "tick"

orFail :: Either InstanceError a -> IO a
orFail = either (fail . T.unpack . renderInstanceError) pure

-- | Fire 'timerFirings' matured bindings, waking at each next maturation;
-- the firings plus the wakes.
driveTimers :: (Net, Marking) -> IO Int
driveTimers (net, initial) = do
  inst <- orFail =<< newInstance net defaultInstanceConfig {initialMarking = initial, suppliedIdentity = Just "bench"}
  let loop fired wakes
        | fired >= timerFirings = pure (fired + wakes)
        | otherwise =
            (orFail =<< step inst Nothing) >>= \case
              Just _ -> loop (fired + 1) wakes
              Nothing -> do
                next <- maybe (fail "nothing left to mature") pure =<< nextMaturation inst
                _ <- orFail =<< wake inst next
                loop fired (wakes + 1)
  loop 0 (0 :: Int)

scopeSource, scopeQueue :: NetPath
scopeSource = path "source"
scopeQueue = path "queue"

-- | An Instance whose scope holds 'scopeDeliveries' delivered entries.
filledScope :: IO (Instance, LifecycleScope)
filledScope = do
  inst <- orFail =<< newInstance (built [place scopeQueue] [transition scopeSource] [arc scopeSource scopeQueue]) defaultInstanceConfig {suppliedIdentity = Just "bench"}
  scope <- orFail =<< openScope inst "batch" (Just (IntNumber 1))
  forM_ [0 .. scopeDeliveries - 1] $ \n ->
    (orFail =<< acceptDelivery inst scopeSource [item n] (T.pack ("d" <> show n)) (Just (ScopeGeneration scope)) (Just (IntNumber 2))) >>= \case
      DeliveryAccepted accepted -> void (orFail =<< completeDelivery inst accepted (Just (IntNumber 2)))
      other -> fail (show other)
  pure (inst, scope)

-- | The compiled net's places, transitions, arcs, and the characters of its
-- arc URIs, so the row pays for the derived indices as Python's eager
-- constructor does.
netWeight :: Net -> Int
netWeight net = Map.size (netPlaces net) + Map.size (netTransitions net) + length (netArcs net) + sum (map (T.length . netUriText) (arcUris net))

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
      documentPayload = fromRight (error "serialize document") (serializeNetDocument chainDocument)
      decodeAll raw = case parseJson surrogateRefusingLoads raw of
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
        , bench "parse-only" (nf (either error jsonWeight . parseJson surrogateRefusingLoads) encoded)
        , bench "decode" (nf decodeAll encoded)
        , bench "records-only" (nf (either (error . T.unpack) length . traverse decodeRecord) (encodeHistory history))
        , bench "replay-marking" (nf (either (error . T.unpack) tokenCount . replayMarking) history)
        ]
    , bgroup
        "net-definition"
        [ bench "serialize" (nf (either (error . T.unpack) BS.length . serializeNetDefinition) definition)
        , bench "parse" (nf (either (error . T.unpack) definitionSize . parseNetDefinition) payload)
        , bench "compile" (nf (either (error . T.unpack) netWeight . compileNetDefinition) definition)
        ]
    , bgroup
        "net-document"
        [ bench "serialize" (nf (either (error . T.unpack) BS.length . serializeNetDocument) chainDocument)
        , bench "parse" (nf (either (error . T.unpack) (\d -> maybe 0 (\l -> length l.entries) d.lineage) . parseNetDocument) documentPayload)
        ]
    , bgroup
        "timers"
        [bench "delay-ring" (nfIO (driveTimers timerRing))]
    , bgroup
        "lifecycle-scope"
        [ bench "fill" (nfIO (filledScope >>= \(inst, _) -> length . placeTokens scopeQueue <$> marking inst))
        , bench "close" (nfIO (filledScope >>= \(inst, scope) -> length . (.discarded) <$> (orFail =<< closeScope inst scope (Just (IntNumber 3)))))
        , bench "reset" (nfIO (filledScope >>= \(inst, scope) -> scopeGeneration <$> (orFail =<< resetScope inst scope (Just (IntNumber 3)))))
        ]
    ]
