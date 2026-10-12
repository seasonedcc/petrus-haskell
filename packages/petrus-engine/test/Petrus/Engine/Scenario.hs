-- | The Engine workloads shared by the interop suite and the benchmarks,
-- the twins of @test/interop/engine_interop.py@ and @bench/python_bench.py@.
--
-- * The order scenario: identified deliveries into a source, a pure
--   validation, an Activity charge, and a delayed (@Delay 5@) settlement.
-- * The pure chain: tokens pumped through a chain of passthrough
--   transitions.
module Petrus.Engine.Scenario
  ( -- * Orders
    orderIdentity
  , orderNet
  , orderOptions
  , orderOptionsWith
  , orderActivities
  , chargeReceipt
  , deliverOrders
  , settledMarking
    -- * Chain
  , chainNet
  , chainMarking
  ) where

import Control.Monad (forM_)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (ActivityInvocation, invocation)
import Petrus.Engine qualified as Engine
import Petrus.Engine.TestSupport (counting, inlineOf, symbols)
import Petrus.Impetus.Binding
import Petrus.Impetus.Petrinet
import Petrus.Impetus.TestSupport (netOf, np, tokD)
import Petrus.Json (Json (..), lookupMember)
import Petrus.Motus.Dispatch (Dispatch)

-- | The order scenario's Instance identity.
orderIdentity :: Text
orderIdentity = "order-interop"

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

-- | The reference's @Charge@ ActivityHandler; @prepared@ counts prepares,
-- and the prepared invocation is adjusted (a policy, for the Worker
-- topology's lease tests).
chargeHandler :: (ActivityInvocation -> ActivityInvocation) -> IORef Int -> ActivityHandler
chargeHandler adjust prepared =
  ActivityHandler
    { prepare = counting prepared $ \b -> do
        valid <- firstData b
        orderId <- member "id" valid
        cents <- member "amount" valid
        adjust <$> invocation "charge_card" (Object [("id", orderId), ("cents", cents)])
    , project = \_ result -> Right (handlerTokens [(charged, [tokD "Receipt" result])])
    , projectFailure = Nothing
    }

-- | The scenario's Engine options (handlers bound by symbol); the counter
-- counts the charge's prepares.
orderOptions :: IORef Int -> Engine.EngineOptions
orderOptions = orderOptionsWith id

-- | 'orderOptions' with the charge's prepared invocation adjusted.
orderOptionsWith :: (ActivityInvocation -> ActivityInvocation) -> IORef Int -> Engine.EngineOptions
orderOptionsWith adjust prepared =
  Engine.defaultEngineOptions
    { Engine.handlers =
        symbols
          [ ("validate", PureHandler validateHandler)
          , ("charge", ActivityBound (chargeHandler adjust prepared))
          , ("settle", PureHandler settleHandler)
          ]
    }

-- | The reference's @charge_card@ activity, inline.
orderActivities :: IO Dispatch
orderActivities = inlineOf [("charge_card", \inv _ -> pure (chargeReceipt inv))]

-- | @charge_card@'s result.
chargeReceipt :: ActivityInvocation -> Json
chargeReceipt inv = case (lookupMember "id" inv.input, lookupMember "cents" inv.input) of
  (Just orderId, Just cents) -> Object [("id", orderId), ("status", String "captured"), ("cents", cents)]
  _ -> Null

-- | Deliver orders @o-1@ … @o-n@ with identities @evt_k@.
deliverOrders :: Engine.Engine -> Int -> IO ()
deliverOrders engine n =
  forM_ [1 .. n] $ \k ->
    Engine.deliver
      engine
      intake
      [tokD "Order" (Object [("id", String ("o-" <> T.pack (show k))), ("amount", Int (fromIntegral k))])]
      ("evt_" <> T.pack (show k))
      Nothing

-- | The marking after @n@ orders settle.
settledMarking :: Int -> Marking
settledMarking n =
  markingFromList
    [ ( done
      , [ tokD "Settled" (Object [("id", String ("o-" <> T.pack (show k))), ("status", String "captured")])
        | k <- [1 .. n]
        ]
      )
    ]

-- | @p0 -> t0 -> p1 -> … -> p{length}@: passthrough transitions.
chainNet :: Int -> Net
chainNet len =
  netOf
    [place (p i) | i <- [0 .. len]]
    [transition (t i) | i <- [0 .. len - 1]]
    (concat [[arc (p i) (t i), arc (t i) (p (i + 1))] | i <- [0 .. len - 1]])
  where
    p i = np ("p" <> T.pack (show i))
    t i = np ("t" <> T.pack (show i))

-- | @tokens@ items at @p0@.
chainMarking :: Int -> Marking
chainMarking tokens = markingFromList [(np "p0", [tokD "Item" (Object [("seq", Int (fromIntegral k))]) | k <- [0 .. tokens - 1]])]
