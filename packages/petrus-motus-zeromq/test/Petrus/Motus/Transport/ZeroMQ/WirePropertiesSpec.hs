-- | Port-only: the wire codecs' round-trip laws over generated values (the
-- reference's tests pin examples; these state what every example shares).
module Petrus.Motus.Transport.ZeroMQ.WirePropertiesSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Petrus.Activity
import Petrus.Json (Json (..))
import Petrus.Motus.Transport.ZeroMQ.Wire (decodeFailure, decodeInvocation, decodeMessage, encodeFailure, encodeInvocation, encodeMessage)
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = describe "ZeroMQ wire codecs (properties)" $ do
  it "decodeInvocation . encodeInvocation is Right" $
    property $ \(Positive attempts') (Positive heartbeat) (NonNegative interval) start name' correlation' idempotency' payload ->
      let policy' =
            either (error . T.unpack) id $
              executionPolicy
                (policyFields defaultExecutionPolicy)
                  { attempts = attempts'
                  , heartbeatTimeout = min heartbeat 1000
                  , initialInterval = IntNumber (min interval 60)
                  , startToClose = fmap (\(Positive s) -> IntNumber (min s 1000)) start
                  }
          value =
            ActivityInvocation
              { activity = "a" <> nonNul name'
              , input = Int payload
              , policy = policy'
              , correlation = fmap (("c" <>) . nonNul) correlation'
              , idempotency = fmap (("i" <>) . nonNul) idempotency'
              }
       in decodeInvocation (encodeInvocation value) === Right value

  it "decodeFailure . encodeFailure is Right" $
    property $ \message kind (details :: Integer) retryable retryAfter ->
      let fields =
            ActivityFailureFields
              { failureError = "e" <> nonNul message
              , failureKind = "k" <> nonNul kind
              , failureDetails = Int details
              , failureRetryable = retryable
              , failureRetryAfter = fmap (\(NonNegative s) -> IntNumber s) retryAfter
              }
       in case activityFailure fields of
            Right failure -> decodeFailure (encodeFailure failure) === Right failure
            Left refusal -> counterexample (T.unpack refusal) False

  it "decodeMessage . encodeMessage gives back the object" $
    property $ \(members :: [(String, Integer)]) ->
      let object = Map.toList (Map.fromList [(T.pack key, Int n) | (key, n) <- members])
       in (Object <$> either (Left . show) Right (decodeMessage =<< encodeMessage (Object object)))
            === Right (Object object)
  where
    nonNul = T.filter (/= '\NUL') . T.pack
