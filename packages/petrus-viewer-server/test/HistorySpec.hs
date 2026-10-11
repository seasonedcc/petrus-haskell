-- | History replay and live watching end to end, from real producers: the
-- viewer server's @/temporal@ routes over observation-protocol-v1 from
--
-- * a Haskell Petrus Engine (petrus-engine + petrus-observation-http, the
--   "ChainProducer" fixture, run as this executable's @--chain-producer@
--   mode), and
-- * the pinned upstream Python reference Engine and observation server
--   (@test/chain_producer.py@, run through petrus-test-support's
--   'withPython', which provisions the interpreter with
--   @scripts/upstream-python@),
--
-- in the same scenario. Replay is what the UI's "Load State" does
-- (@get_schema@ + @get_state@); live watching is what "Watch Live" does:
-- poll @get_state@ and append @states.slice(currentLength)@ until the
-- workflow reports a terminal state. The two producers must give the
-- viewer the same answers at every step, including for a workflow they do
-- not have. This is also petrus-observation-http's end-to-end test against
-- the viewer (it lives here so that package does not depend on this one).
module HistorySpec (spec) where

import Control.Exception (bracket)
import Control.Monad (forM)
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.TestSupport.Python (readLine, sendLine, withPython)
import Petrus.Viewer.Json
import Petrus.Viewer.Server (ServerConfig (..), ServerHandle (..))
import System.Environment (getExecutablePath)
import System.IO (BufferMode (..), hClose, hGetLine, hPutStrLn, hSetBuffering)
import System.Process
import System.Timeout (timeout)
import Test.Hspec
import TestSupport

-- | A running producer: its observation port and one-step driver (the
-- number of firings the step applied).
data Producer = Producer
  { producerPort :: Int
  , producerAdvance :: IO Int
  }

instanceId :: Text
instanceId = "chain-1"

withHaskellProducer :: (Producer -> IO a) -> IO a
withHaskellProducer action = do
  exe <- getExecutablePath
  let cfg = (proc exe ["--chain-producer", T.unpack instanceId]) {std_in = CreatePipe, std_out = CreatePipe}
  bracket (createProcess cfg) stop $ \case
    (Just hin, Just hout, _, _) -> do
      hSetBuffering hin LineBuffering
      port <- read <$> line hout
      action (Producer port (hPutStrLn hin "advance" >> read <$> line hout))
    _ -> fail "chain producer: no pipes"
  where
    -- the exact process we started: close its input (it shuts down on end
    -- of file) and wait for it
    stop (hin, _, _, ph) = do
      mapM_ hClose hin
      _ <- timeout 10000000 (waitForProcess ph)
      terminateProcess ph
      _ <- waitForProcess ph
      pure ()
    line h = timeout 30000000 (hGetLine h) >>= maybe (fail "chain producer: no output within 30 s") pure

withPythonProducer :: (Producer -> IO a) -> IO a
withPythonProducer action = do
  script <- T.pack <$> readFile "test/chain_producer.py"
  withPython script [T.unpack instanceId] $ \p -> do
    let line = read . BC.unpack <$> readLine p
    port <- line
    action (Producer port (sendLine p "advance" >> line))

-- | What the viewer answered at one step: the workflow list, the schema,
-- the runtime state, and a @get_state@ for a workflow the producer does not
-- have (status and parsed body).
data Step = Step {stepList :: JsValue, stepSchema :: JsValue, stepState :: JsValue, stepMissing :: (Int, Either String JsValue)}
  deriving stock (Eq, Show)

-- | Replay and then live-watch the producer's instance to completion
-- through the viewer, checking each answer as the UI consumes it; returns
-- every step's answers for the cross-producer comparison.
watch :: Producer -> IO [Step]
watch producer =
  withViewer (\c -> c {serverObservation = ["http://127.0.0.1:" <> T.pack (show (producerPort producer))]}) $ \h -> do
    let base = "http://127.0.0.1:" <> show (handlePort h) <> "/temporal/api/v1/namespaces/default/workflows"
        query q = do
          r <- httpRequest "POST" (base <> "/" <> T.unpack instanceId <> "/query/" <> q) (Just "{}")
          httpStatus r `shouldBe` 200
          case parseJ (httpBody r) of
            Right v | Just (JsArr [result]) <- field "queryResult" v -> pure result
            other -> fail (q <> ": " <> show other)
        step = do
          l <- httpRequest "GET" base Nothing
          httpStatus l `shouldBe` 200
          list <- either fail pure (parseJ (httpBody l))
          missing <- httpRequest "POST" (base <> "/nope/query/get_state") (Just "{}")
          httpStatus missing `shouldNotBe` 200
          Step list <$> query "get_schema" <*> query "get_state" <*> pure (httpStatus missing, parseJ (httpBody missing))

    -- replay ("Load State")
    first <- step
    executions (stepList first) `shouldBe` [(instanceId, "viewer-chain", "WORKFLOW_EXECUTION_STATUS_RUNNING")]
    textField "net" (stepSchema first) `shouldBe` Just "viewer-chain"
    keysOf (field "places" (stepSchema first)) `shouldBe` ["a", "b", "c", "d"]
    keysOf (field "transitions" (stepSchema first)) `shouldBe` ["t1", "t2", "t3"]
    arcCount (stepSchema first) `shouldBe` 6
    terminal (stepState first) `shouldBe` False
    lastMarking (stepState first) `shouldBe` Just (obj [("viewer-chain.a", int 1)])

    -- live watching ("Watch Live"): one step at a time; every poll extends
    -- the states the UI already holds (it appends states.slice(length))
    -- and appends the new firing. Only the head entry carries the
    -- producer's @observation@ annotation (status, watermark), so earlier
    -- states are compared without it.
    let live prev acc = do
          fired <- producerAdvance producer
          next <- step
          let old = states (stepState prev)
              new = states (stepState next)
          map settled (take (length old) new) `shouldBe` map settled old
          if fired == 0
            then do
              new `shouldBe` old
              pure (reverse (next : acc))
            else do
              length new `shouldSatisfy` (> length old)
              live next (next : acc)
    steps <- live first [first]

    let final = last steps
        fireds = [t | s <- states (stepState final), Just (JsStr t) <- [field "fired" s]]
    -- each transition fired once, in order
    map jsStringText (dedupe fireds) `shouldBe` ["viewer-chain.t1", "viewer-chain.t2", "viewer-chain.t3"]
    lastMarking (stepState final) `shouldBe` Just (obj [("viewer-chain.d", int 1)])
    (field "history" (stepState final) >>= field "current") `shouldBe` Just (int (length (states (stepState final)) - 1))
    -- the quiescent Engine reports a terminal status, so the UI leaves live
    -- mode after stepping through the appended states
    (terminal (stepState final), map (\(_, _, s) -> s) (executions (stepList final)))
      `shouldBe` (True, ["WORKFLOW_EXECUTION_STATUS_TERMINATED"])
    pure steps
  where
    executions v = case field "executions" v of
      Just (JsArr es) ->
        [ (w, t, s)
        | e <- es
        , Just w <- [field "execution" e >>= textField "workflowId"]
        , Just t <- [field "type" e >>= textField "name"]
        , Just s <- [textField "status" e]
        ]
      _ -> []
    keysOf v = maybe [] (map jsStringText . objectKeys) (v >>= asObject)
    arcCount v = case field "arcs" v of
      Just (JsArr as) -> length as
      _ -> 0
    states v = case field "history" v >>= field "states" of
      Just (JsArr xs) -> xs
      _ -> []
    terminal v = field "terminal" v == Just (JsBool True)
    settled s = (field "fired" s, field "marking" s, field "context" s >>= field "entry", field "context" s >>= field "tokens", field "context" s >>= field "metadata" >>= field "history_record")
    lastMarking v = case states v of
      [] -> Nothing
      xs -> field "marking" (last xs) >>= nonZero
    nonZero m = obj . filter ((/= int 0) . snd) . map (\(k, x) -> (jsStringText k, x)) . objectToList <$> asObject m
    dedupe (x : y : rest) | x == y = dedupe (y : rest)
    dedupe (x : rest) = x : dedupe rest
    dedupe [] = []

spec :: Spec
spec = describe "replay and live watching from real producers" $ do
  it "a Haskell Engine (petrus-engine + petrus-observation-http)" $ do
    steps <- withHaskellProducer watch
    -- the replayed start, one step per firing, and the quiescent step
    length steps `shouldBe` 5

  it "the Python reference Engine, with the same answers at every step" $ do
    ours <- withHaskellProducer watch
    theirs <- withPythonProducer watch
    length theirs `shouldBe` length ours
    _ <- forM (zip3 [0 :: Int ..] ours theirs) $ \(i, o, t) -> (i, t) `shouldBe` (i, o)
    pure ()
