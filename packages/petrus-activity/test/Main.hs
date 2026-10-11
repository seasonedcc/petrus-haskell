-- | Behavior of the Activity values against the reference's
-- @petrus.motus.activity@ (vectors produced by the pinned Python package).
module Main (main) where

import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity
import Petrus.Activity.DifferentialSpec qualified as DifferentialSpec
import Petrus.Activity.HeartbeatSpec qualified as HeartbeatSpec
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
    it "spells names with Python's repr" $ do
      ctx <- executionContext
      callActivity definition (invocation "it's" Null) ctx
        `shouldReturn` Left "Activity 'add' cannot execute invocation for \"it's\""
      callActivity definition (invocation "add" (Array [])) ctx
        `shouldReturn` Left "Activity 'add' parameter payload must be a mapping, got list"
    it "refuses a result json.dumps refuses, with its message" $ do
      ctx <- executionContext
      let nan = defineActivity declaration [] (\_ _ -> pure (Array [Float (0 / 0)]))
      callActivity nan (invocation "add" (Object [])) ctx
        `shouldReturn` Left "Activity payload is not JSON-faithful: Out of range float values are not JSON compliant: nan"
      let huge = defineActivity declaration [] (\_ _ -> pure (Int (10 ^ (4300 :: Int))))
      callActivity huge (invocation "add" (Object [])) ctx
        `shouldReturn` Left "Activity payload is not JSON-faithful: Exceeds the limit (4300 digits) for integer string conversion; use sys.set_int_max_str_digits() to increase the limit"

  describe "heartbeat details" $ do
    it "require finite JSON within the byte limit" $ do
      snapshotHeartbeatDetails (Float (0 / 0)) `shouldBe` Left "heartbeat details require finite JSON numbers"
      snapshotHeartbeatDetails (String (T.replicate 70000 "x")) `shouldSatisfy` isLeft
      snapshotHeartbeatDetails (Object [("k", Int 1)]) `shouldBe` Right (Object [("k", Int 1)])
    it "refuse an integer past 4300 digits with json.dumps's own message, after any non-finite float" $ do
      snapshotHeartbeatDetails (Array [Int (10 ^ (4300 :: Int))])
        `shouldBe` Left "Exceeds the limit (4300 digits) for integer string conversion; use sys.set_int_max_str_digits() to increase the limit"
      snapshotHeartbeatDetails (Array [Int (10 ^ (4300 :: Int)), Float (1 / 0)])
        `shouldBe` Left "heartbeat details require finite JSON numbers"

  describe "CPython's numeric exceptions" $ do
    it "an int too large to convert to float is refused as math.isfinite refuses it" $ do
      let overflow = 2 ^ (1024 :: Int) - 2 ^ (970 :: Int)
      policyWith (\f -> f {coefficient = IntNumber overflow}) `shouldBe` Left "int too large to convert to float"
      policyWith (\f -> f {coefficient = IntNumber (overflow - 1)}) `shouldSatisfy` (not . isLeft)
      policyWith (\f -> f {startToClose = Just (IntNumber (negate overflow))}) `shouldBe` Left "int too large to convert to float"
    it "a refused attempts count past 4300 digits cannot be spelled in the message" $
      policyWith (\f -> f {attempts = negate (10 ^ (4300 :: Int))})
        `shouldBe` Left "Exceeds the limit (4300 digits) for integer string conversion; use sys.set_int_max_str_digits() to increase the limit"

  HeartbeatSpec.spec
  DifferentialSpec.spec
