-- | Engine interop with the pinned reference: the same Engine scenario over
-- JSONL writes byte-identical History in both implementations, and an
-- Instance one implementation left mid-flight (a crash with a dispatched
-- Activity outstanding) resumes in the other — reconcile redispatches the
-- recorded outbox, prepare never re-runs — to the same bytes.
--
-- Runs @test/interop/engine_interop.py@ under @upstream/petrus/.venv@; the
-- examples are pending when that environment is not synced.
module Petrus.Engine.InteropSpec
  ( spec
    -- * The scenario (shared with the benchmarks)
  , orderNet
  , orderOptions
  , orderActivities
  , deliverOrders
  , identity
  ) where

import Control.Monad (forM_, void)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (ActivityInvocation (..), invocation)
import Petrus.Engine qualified as Engine
import Petrus.Engine.TestSupport (advanceUntilRest, counting, inlineOf, symbols)
import Petrus.HistoryStore.Jsonl (openJsonlHistoryStore)
import Petrus.HistoryStore.Support (pythonOrPending, runPython, withScratch)
import Petrus.Impetus.Binding
import Petrus.Impetus.Petrinet
import Petrus.Impetus.TestSupport (netOf, np, tokD)
import Petrus.Json (Json (..), lookupMember)
import Petrus.Motus.Dispatch (Dispatch)
import Petrus.Motus.Dispatch.InMemory (inMemoryDispatch, newInMemoryDispatch)
import System.Directory (copyFile)
import System.FilePath ((</>))
import Test.Hspec

script :: FilePath
script = "test/interop/engine_interop.py"

identity :: Text
identity = "order-interop"

intake, orders, validate, queue, charge, charged, settle, done :: NetPath
intake = np "intake"
orders = np "orders"
validate = np "validate"
queue = np "queue"
charge = np "charge"
charged = np "charged"
settle = np "settle"
done = np "done"

-- | The reference script's @order_net()@.
orderNet :: Net
orderNet =
  netOf
    [place orders, place queue, place charged, place done]
    [ transition intake
    , Transition validate (Just (HandlerSymbol "validate")) [] []
    , Transition charge (Just (HandlerSymbol "charge")) [] []
    , Transition settle (Just (HandlerSymbol "settle")) [] [Delay 5]
    ]
    [arc intake orders, arc orders validate, arc validate queue, arc queue charge, arc charge charged, arc charged settle, arc settle done]

member :: Text -> Json -> Either Text Json
member key value = maybe (Left ("KeyError(" <> T.pack (show key) <> ")")) Right (lookupMember key value)

firstData :: Binding -> Either Text Json
firstData b = case bindingTokens b of
  t : _ -> Right t.payload
  [] -> Left "IndexError('tuple index out of range')"

validateHandler :: Handler
validateHandler b _ = do
  order <- firstData b
  orderId <- member "id" order
  amount <- member "amount" order
  cents <- case amount of
    Int n -> Right (Int (n * 100))
    other -> Left ("TypeError(" <> T.pack (show other) <> ")")
  Right (handlerTokens [(queue, [tokD "Valid" (Object [("id", orderId), ("amount", cents)])])])

settleHandler :: Handler
settleHandler b _ = do
  receipt <- firstData b
  orderId <- member "id" receipt
  status <- member "status" receipt
  Right (handlerTokens [(done, [tokD "Settled" (Object [("id", orderId), ("status", status)])])])

-- | The reference's @Charge@ ActivityHandler; @prepared@ counts prepares.
chargeHandler :: IORef Int -> ActivityHandler
chargeHandler prepared =
  ActivityHandler
    { prepare = counting prepared $ \b -> do
        valid <- firstData b
        orderId <- member "id" valid
        cents <- member "amount" valid
        Right (invocation "charge_card" (Object [("id", orderId), ("cents", cents)]))
    , project = \_ result -> Right (handlerTokens [(charged, [tokD "Receipt" result])])
    , projectFailure = Nothing
    }

-- | The scenario's Engine options (handlers bound by symbol).
orderOptions :: IORef Int -> Engine.EngineOptions
orderOptions prepared =
  Engine.defaultEngineOptions
    { Engine.handlers =
        symbols
          [ ("validate", PureHandler validateHandler)
          , ("charge", ActivityBound (chargeHandler prepared))
          , ("settle", PureHandler settleHandler)
          ]
    }

-- | The reference's @charge_card@ activity.
orderActivities :: IO Dispatch
orderActivities =
  inlineOf
    [ ( "charge_card"
      , \inv _ -> pure $ case (lookupMember "id" inv.input, lookupMember "cents" inv.input) of
          (Just orderId, Just cents) -> Object [("id", orderId), ("status", String "captured"), ("cents", cents)]
          _ -> Null
      )
    ]

-- | Deliver the scenario's orders @o-1@ … @o-n@ with identities @evt_k@.
deliverOrders :: Engine.Engine -> Int -> IO ()
deliverOrders engine n =
  forM_ [1 .. n] $ \k ->
    Engine.deliver
      engine
      intake
      [tokD "Order" (Object [("id", String ("o-" <> T.pack (show k))), ("amount", Int (fromIntegral k))])]
      ("evt_" <> T.pack (show k))
      Nothing

created :: FilePath -> Dispatch -> IO (Engine.Engine, IORef Int)
created path port = do
  prepared <- newIORef 0
  store <- openJsonlHistoryStore path
  engine <- Engine.create orderNet identity store port (orderOptions prepared)
  deliverOrders engine 3
  pure (engine, prepared)

-- | @run PATH@.
runScenario :: FilePath -> IO ()
runScenario path = do
  (engine, _) <- orderActivities >>= created path
  void (advanceUntilRest engine)
  Engine.close engine

-- | @crash PATH@: the process "dies" with the first charge in flight.
crashScenario :: FilePath -> IO ()
crashScenario path = do
  pool <- newInMemoryDispatch
  (engine, _) <- created path (inMemoryDispatch pool)
  void (advanceUntilRest engine)
  length <$> Engine.inFlight engine `shouldReturn` 1

-- | @resume PATH@; answers how many times prepare ran.
resumeScenario :: FilePath -> IO Int
resumeScenario path = do
  prepared <- newIORef 0
  store <- openJsonlHistoryStore path
  port <- orderActivities
  engine <- Engine.load orderNet identity store port (orderOptions prepared)
  void (advanceUntilRest engine)
  Engine.close engine
  readIORef prepared

settledMarking :: Marking
settledMarking =
  markingFromList
    [ ( done
      , [ tokD "Settled" (Object [("id", String ("o-" <> T.pack (show k))), ("status", String "captured")])
        | k <- [1 :: Int .. 3]
        ]
      )
    ]

inspected :: String
inspected =
  "{\"done\": [[\"Settled\", {\"id\": \"o-1\", \"status\": \"captured\"}], [\"Settled\", {\"id\": \"o-2\", \"status\": \"captured\"}], [\"Settled\", {\"id\": \"o-3\", \"status\": \"captured\"}]]}\n66\n"

loadedMarking :: FilePath -> IO Marking
loadedMarking path = do
  store <- openJsonlHistoryStore path
  port <- inMemoryDispatch <$> newInMemoryDispatch
  prepared <- newIORef 0
  engine <- Engine.load orderNet identity store port (orderOptions prepared)
  m <- Engine.marking engine
  Engine.close engine
  pure m

spec :: Spec
spec = describe "Engine interop with the reference" $ do
  it "the same scenario writes byte-identical JSONL History in both implementations" $ pythonOrPending $ \python -> withScratch $ \dir -> do
    let reference = dir </> "reference.jsonl"
        ours = dir </> "haskell.jsonl"
    _ <- runPython python script ["run", reference]
    runScenario ours
    expected <- BS.readFile reference
    BS.readFile ours `shouldReturn` expected
    loadedMarking ours `shouldReturn` settledMarking
    runPython python script ["inspect", ours] `shouldReturn` inspected

  it "an Instance the reference left mid-flight resumes in Haskell to the reference's own resumed bytes" $ pythonOrPending $ \python -> withScratch $ \dir -> do
    let ours = dir </> "haskell-resumed.jsonl"
        reference = dir </> "reference-resumed.jsonl"
    _ <- runPython python script ["crash", ours]
    copyFile ours reference
    prepares <- resumeScenario ours
    prepares `shouldBe` 2 -- the in-flight charge's prepare never re-runs
    _ <- runPython python script ["resume", reference]
    expected <- BS.readFile reference
    BS.readFile ours `shouldReturn` expected
    runPython python script ["inspect", ours] `shouldReturn` inspected

  it "an Instance Haskell left mid-flight resumes in the reference to Haskell's own resumed bytes" $ pythonOrPending $ \python -> withScratch $ \dir -> do
    let theirs = dir </> "reference-resumed.jsonl"
        ours = dir </> "haskell-resumed.jsonl"
        referenceCrash = dir </> "reference-crash.jsonl"
    crashScenario theirs
    _ <- runPython python script ["crash", referenceCrash]
    crashed <- BS.readFile referenceCrash
    BS.readFile theirs `shouldReturn` crashed
    copyFile theirs ours
    _ <- runPython python script ["resume", theirs]
    _ <- resumeScenario ours
    expected <- BS.readFile ours
    BS.readFile theirs `shouldReturn` expected
    loadedMarking theirs `shouldReturn` settledMarking
