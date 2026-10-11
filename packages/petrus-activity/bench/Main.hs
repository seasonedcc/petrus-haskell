-- | The Activity value doors against the pinned @petrus.motus.activity@. Each
-- benchmark has a same-named twin in @bench/python_bench.py@ doing the same
-- work on the same inputs; run both with @scripts/bench petrus-activity@ or
-- interleave them with @scripts/bench-compare petrus-activity N@.
--
-- Every row runs a door over 100 distinct inputs, so a row's time is per
-- 100 calls.
module Main (main) where

import Control.Monad (foldM)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity
import Petrus.Json
import Test.Tasty (localOption)
import Test.Tasty.Bench

-- | Touch every node of a value.
size :: Json -> Int
size = \case
  Null -> 1
  Bool b -> b `seq` 1
  Int i -> i `seq` 1
  Float d -> d `seq` 1
  String s -> T.length s `seq` 1
  Array items -> foldl' (\n item -> n + size item) 1 items
  Object members -> foldl' (\n (key, item) -> key `seq` n + size item) 1 members

accepted :: Either Text a -> Int
accepted = either (error . T.unpack) (const 1)

indices :: [Integer]
indices = [0 .. 99]

tshow :: Integer -> Text
tshow = T.pack . show

-- | @ExecutionPolicy(attempts=1 + k % 10, heartbeat_timeout=30 + k,
-- initial_interval=0.5, coefficient=2, max_interval=60, jitter=0,
-- start_to_close=10 + k, schedule_to_close=3600)@.
policyInputs :: [ExecutionPolicyFields]
policyInputs =
  [ ExecutionPolicyFields (1 + k `mod` 10) (30 + k) (FloatNumber 0.5) 2 60 0 (Just (IntNumber (10 + k))) (Just 3600)
  | k <- indices
  ]

retry :: RetryPolicy
retry = either (error . T.unpack) id (retryPolicy (RetryPolicyFields (FloatNumber 0.5) 2 60 10 0))

order :: Integer -> Json
order k =
  Object
    [ ("order", Int k)
    , ("customer", Object [("name", String "Jo\xe3o"), ("email", String ("c" <> tshow k <> "@example.com"))])
    , ("items", Array [Object [("sku", String ("SKU-" <> tshow (k * 7))), ("quantity", Int 2), ("price", Float 12.5)], Object [("sku", String "SKU-2"), ("quantity", Int 1), ("price", Float 3.25)]])
    , ("total", Float 28.25)
    , ("coupon", Null)
    ]

invocationInputs :: [ActivityInvocation]
invocationInputs =
  [ ActivityInvocation "charge_card" (order k) policy (Just ("c-" <> tshow k)) Nothing
  | (k, fields) <- zip indices policyInputs
  , let policy = either (error . T.unpack) id (executionPolicy fields)
  ]

failureInputs :: [ActivityFailureFields]
failureInputs =
  [ ActivityFailureFields
      "card declined"
      "PaymentDeclined"
      (Object [("code", String "insufficient_funds"), ("attempt", Int k), ("amounts", Array [Float 1.5, Float 2.25]), ("message", String "cart\xe3o recusado \x2014 tente novamente")])
      True
      (Just (FloatNumber 1.5))
  | k <- indices
  ]

heartbeatInputs :: [Json]
heartbeatInputs =
  [ Object
      [ ("progress", Float (fromInteger k / 100))
      , ("processed", Int (k * 10))
      , ("cursor", String ("page-" <> tshow k))
      , ("log", Array [String ("step " <> tshow i <> " ok") | i <- [1 .. 10 :: Integer]])
      ]
  | k <- indices
  ]

charge :: ActivityDefinition
charge = defineActivity declaration ["order", "amount", "currency"] run
  where
    declaration = either (error . T.unpack) id (activityDeclaration "charge" Nothing)
    run arguments _ =
      pure (Object [("charged", maybe Null id (lookup "amount" arguments)), ("currency", maybe Null id (lookup "currency" arguments)), ("receipt", String "r-1")])

callInputs :: [ActivityInvocation]
callInputs =
  [ invocation "charge" (Object [("order", order k), ("amount", Float 28.25), ("currency", String "BRL")])
  | k <- indices
  ]

context :: ActivityExecutionContext
context = ActivityExecutionContext "attempt-1" "1" "worker" Nothing (pure Null) (const (pure Null))

main :: IO ()
main = do
  sum (map size heartbeatInputs) `seq` sum (map (size . (.input)) invocationInputs) `seq` pure ()
  -- Wall-clock time, as the Python twin measures it (time.perf_counter_ns).
  defaultMain . map (localOption WallTime) $
    [ bgroup
        "policy"
        [ bench "construct" (whnf (foldl' (\n fields -> n + accepted (executionPolicy fields)) 0) policyInputs)
        , bench "delay" (whnf (foldl' (\n attempt -> n + either (error . T.unpack) (\d -> numberValue d `seq` 1) (retryDelay retry attempt)) (0 :: Int)) [1 .. 100])
        ]
    , bgroup
        "invocation"
        [bench "construct" (whnf (foldl' (\n value -> n + accepted (activityInvocation value)) 0) invocationInputs)]
    , bgroup
        "failure"
        [bench "construct" (whnf (foldl' (\n fields -> n + accepted (activityFailure fields)) 0) failureInputs)]
    , bgroup
        "heartbeat"
        [bench "snapshot" (whnf (foldl' (\n value -> n + either (error . T.unpack) size (snapshotHeartbeatDetails value)) 0) heartbeatInputs)]
    , bgroup
        "payload"
        [bench "convert" (whnf (foldl' (\n value -> n + either (error . T.unpack) size (jsonPayloadConverter.decodePayload value)) 0) (map (.input) invocationInputs))]
    , bgroup
        "definition"
        [ bench "call" $
            whnfAppIO
              (foldM (\n inv -> either (error . T.unpack) ((n +) . size) <$> callActivity charge inv context) 0)
              callInputs
        ]
    ]
