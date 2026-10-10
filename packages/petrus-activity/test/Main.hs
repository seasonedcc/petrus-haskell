-- | Behavior of the Activity values against the reference's
-- @petrus.motus.activity@ (vectors produced by the pinned Python package).
module Main (main) where

import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity
import Petrus.Json (Json (..))
import Test.Hspec
import Test.QuickCheck

policyWith :: (ExecutionPolicyFields -> ExecutionPolicyFields) -> Either Text ExecutionPolicy
policyWith f = executionPolicy (f (policyFields defaultExecutionPolicy))

retry :: Number -> Number -> Number -> Integer -> RetryPolicy
retry i c m a = either (error . T.unpack) id (retryPolicy (RetryPolicyFields i c m a 0))

executionContext :: IO ActivityExecutionContext
executionContext =
  pure (ActivityExecutionContext "attempt" "epoch" "claimant" Nothing (pure Null) (const (pure Null)))

main :: IO ()
main = hspec $ do
  describe "Number" $ do
    it "compares and adds like Python numbers" $ do
      IntNumber 1 `shouldBe` FloatNumber 1.0
      compare (IntNumber 1) (FloatNumber 1.5) `shouldBe` LT
      IntNumber 2 + IntNumber 3 `shouldSatisfy` isIntegral
      show (IntNumber 2 + FloatNumber 0.5) `shouldBe` "2.5"
      show (FloatNumber 10) `shouldBe` "10.0"
    it "orders exactly across int and float" $
      property $ \(a :: Integer) (b :: Double) ->
        compare (IntNumber a) (FloatNumber b) == compare (toRational a) (toRational b)

  describe "ExecutionPolicy" $ do
    it "accepts the defaults" $ policyWith id `shouldBe` Right defaultExecutionPolicy
    it "refuses every invalid field with the reference message" $ do
      policyWith (\f -> f {attempts = 0})
        `shouldBe` Left "ExecutionPolicy requires attempts >= 1, got 0: an invocation that may never execute is a wedge, not a policy"
      policyWith (\f -> f {heartbeatTimeout = 0}) `shouldBe` Left "ExecutionPolicy heartbeat_timeout must be a positive integer"
      policyWith (\f -> f {heartbeatTimeout = 10000000000})
        `shouldBe` Left "ExecutionPolicy heartbeat_timeout must be at most 1000000000 seconds for provider-neutral duration safety"
      policyWith (\f -> f {initialInterval = -1}) `shouldBe` Left "RetryPolicy initial_interval must be a non-negative number"
      policyWith (\f -> f {coefficient = FloatNumber 0.5}) `shouldBe` Left "RetryPolicy coefficient must be >= 1"
      policyWith (\f -> f {jitter = 1}) `shouldBe` Left "RetryPolicy jitter is unsupported; only deterministic jitter=0 is accepted"
      policyWith (\f -> f {maxInterval = FloatNumber 2e9})
        `shouldBe` Left "RetryPolicy max_interval must be at most 1000000000 seconds for provider-neutral duration safety"
      policyWith (\f -> f {startToClose = Just 0}) `shouldBe` Left "ExecutionPolicy start_to_close must be a positive number or None"
      policyWith (\f -> f {scheduleToClose = Just (FloatNumber 2e9)})
        `shouldBe` Left "ExecutionPolicy schedule_to_close must be at most 1000000000 seconds for provider-neutral duration safety"

  describe "RetryPolicy.delay" $
    it "matches the reference's float computation bit for bit" $ do
      let cases =
            [ (retry 0 2 60 3, 1, "0")
            , (retry 1 1 60 3, 2, "1")
            , (retry 1 2 60 3, 1, "1.0")
            , (retry 1 2 60 3, 4, "7.999999999999998")
            , (retry 1 2 60 3, 7, "60")
            , (retry 1 2 60 3, 8, "60")
            , (retry (FloatNumber 0.25) 3 100 3, 3, "2.2500000000000004")
            , (retry 5 2 3 3, 1, "3")
            ]
      mapM_ (\(p, attempt, expected) -> fmap show (retryDelay p attempt) `shouldBe` Right expected) cases
      retryDelay (retry 1 2 60 3) 0 `shouldBe` Left "RetryPolicy delay requires a failed attempt number >= 1"

  describe "ActivityInvocation" $ do
    it "requires a non-empty activity name" $
      activityInvocation (invocation "" Null) `shouldBe` Left "ActivityInvocation requires a non-empty string activity name, got ''"
    it "requires non-empty correlation and idempotency when supplied" $
      activityInvocation (invocation "a" Null) {correlation = Just ""}
        `shouldBe` Left "ActivityInvocation correlation must be a non-empty string, or None for the writer to derive at begin, got ''"

  describe "ActivityFailure" $ do
    let fields = ActivityFailureFields "boom" "ActivityError" Null False Nothing
    it "bounds error and kind" $ do
      activityFailure fields {failureError = ""}
        `shouldBe` Left "ActivityFailure error must be a non-empty string of at most 4096 characters"
      activityFailure fields {failureKind = T.replicate 129 "k"}
        `shouldBe` Left "ActivityFailure kind must be a non-empty string of at most 128 characters"
    it "requires JSON-faithful, bounded details" $ do
      activityFailure fields {failureDetails = Object [("a", Array [Float (-1 / 0)])]}
        `shouldBe` Left "Activity failure details must be JSON-faithful: Out of range float values are not JSON compliant: -inf"
      activityFailure fields {failureDetails = String (T.replicate 20000 "a")}
        `shouldBe` Left "Activity failure details must be JSON-faithful: Activity failure details exceed the 16384-byte limit"
    it "bounds retry_after" $
      activityFailure fields {failureRetryAfter = Just (-1)}
        `shouldBe` Left "ActivityFailure retry_after must be a non-negative number or None"

  describe "ActivityDeclaration" $
    it "validates name and heartbeat" $ do
      activityDeclaration "" Nothing `shouldBe` Left "ActivityDeclaration requires a non-empty string name"
      activityDeclaration "a" (Just 0) `shouldBe` Left "ActivityDeclaration heartbeat_timeout must be a positive integer or None"

  describe "callActivity" $ do
    let declaration = either (error . T.unpack) id (activityDeclaration "add" Nothing)
        definition = defineActivity declaration ["a", "b"] $ \arguments _ -> case (lookup "a" arguments, lookup "b" arguments) of
          (Just (Int a), Just (Int b)) -> pure (Int (a + b))
          _ -> pure Null
    it "executes with exactly the declared parameters" $ do
      ctx <- executionContext
      callActivity definition (invocation "add" (Object [("b", Int 2), ("a", Int 1)])) ctx `shouldReturn` Right (Int 3)
    it "refuses a different activity or parameter set" $ do
      ctx <- executionContext
      callActivity definition (invocation "sub" (Object [])) ctx
        `shouldReturn` Left "Activity 'add' cannot execute invocation for 'sub'"
      callActivity definition (invocation "add" (Object [("a", Int 1)])) ctx
        `shouldReturn` Left "Activity 'add' requires parameters ['a', 'b'], got ['a']"

  describe "heartbeat details" $
    it "require finite JSON within the byte limit" $ do
      snapshotHeartbeatDetails (Float (0 / 0)) `shouldBe` Left "heartbeat details require finite JSON numbers"
      snapshotHeartbeatDetails (String (T.replicate 70000 "x")) `shouldSatisfy` isLeft
      snapshotHeartbeatDetails (Object [("k", Int 1)]) `shouldBe` Right (Object [("k", Int 1)])
