-- | The Activity-value tests of the reference's
-- @tests/petrus/motus/dispatch/test_attempt_heartbeats.py@, under their
-- upstream names. The file's other tests run in @petrus-motus@ (the inline
-- context) and @petrus-motus-absurd@ (the reconnectable heartbeat).
--
-- Python inputs the Haskell types cannot express are recorded where they
-- occur: @True@ and @1.5@ as a timeout (the timeouts are 'Integer'), a
-- non-string mapping key, a tuple and an arbitrary object as heartbeat
-- details ('Json' has string keys and one sequence type), and the mutation
-- after a snapshot that "detach" guards against ('Json' is immutable).
module Petrus.Activity.HeartbeatSpec (spec) where

import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity
import Petrus.Json (Json (..))
import Test.Hspec

-- | The test-local Attempt model of the reference test.
data AttemptModel = AttemptModel
  { epoch :: Integer
  , claimant :: Maybe Text
  , deadline :: Maybe Integer
  , state :: Text
  }
  deriving stock (Eq, Show)

pending' :: AttemptModel
pending' = AttemptModel 0 Nothing Nothing "pending"

claim :: Text -> Integer -> Integer -> AttemptModel -> Either String AttemptModel
claim who now timeout model
  | model.state == "terminal" || (model.state == "running" && maybe False (now <) model.deadline) = Left "not claimable"
  | otherwise = Right (AttemptModel (model.epoch + 1) (Just who) (Just (now + timeout)) "running")

beat :: Text -> Integer -> Integer -> Integer -> AttemptModel -> Either String AttemptModel
beat who at now timeout model = do
  guard' who at now model
  Right (AttemptModel at (Just who) (Just (now + timeout)) "running")

terminal :: Text -> Integer -> Integer -> AttemptModel -> Either String AttemptModel
terminal who at now model = do
  guard' who at now model
  Right (AttemptModel at (Just who) model.deadline "terminal")

guard' :: Text -> Integer -> Integer -> AttemptModel -> Either String ()
guard' who at now model
  | model.state /= "running" || Just who /= model.claimant || at /= model.epoch || maybe True (now >=) model.deadline = Left "stale Attempt"
  | otherwise = Right ()

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\e -> expectationFailure (show e) >> error "unreachable") pure

spec :: Spec
spec = describe "test_attempt_heartbeats.py (the Activity values)" $ do
  it "attempt state model covers renewal expiry reassignment terminal and stale refusal" $ do
    first <- expectRight (claim "worker-a" 0 10 pending')
    renewed <- expectRight (beat "worker-a" 1 5 20 first)
    renewed.deadline `shouldBe` Just 25

    second <- expectRight (claim "worker-b" 25 10 renewed)
    (second.epoch, second.claimant, second.deadline) `shouldBe` (2, Just "worker-b", Just 35)
    beat "worker-a" 1 25 10 renewed `shouldBe` Left "stale Attempt"
    terminal "worker-a" 1 25 renewed `shouldBe` Left "stale Attempt"

    finished <- expectRight (terminal "worker-b" 2 30 second)
    beat "worker-b" 2 30 10 finished `shouldBe` Left "stale Attempt"
    terminal "worker-b" 2 30 finished `shouldBe` Left "stale Attempt"

  it "activity declaration and execution policy require positive integer timeouts" $ do
    fmap declarationHeartbeatTimeout (activityDeclaration "work" Nothing) `shouldBe` Right Nothing
    fmap declarationHeartbeatTimeout (activityDeclaration "work" (Just 7)) `shouldBe` Right (Just 7)
    (policyFields defaultExecutionPolicy).heartbeatTimeout `shouldBe` 30
    -- True and 1.5 are unrepresentable: both timeouts are Integers.
    let mentionsTimeout = either (T.isInfixOf "heartbeat_timeout") (const False)
    mapM_
      ( \invalid -> do
          activityDeclaration "work" (Just invalid) `shouldSatisfy` mentionsTimeout
          executionPolicy (policyFields defaultExecutionPolicy) {heartbeatTimeout = invalid} `shouldSatisfy` mentionsTimeout
      )
      [0, -1]

  describe "details accept every JSON-faithful shape and detach" $
    mapM_
      (\value -> it (show value) (snapshotHeartbeatDetails value `shouldBe` Right value))
      [ Object [("s", String "\xe9"), ("items", Array [Bool True, Null, Int 4, Float 1.5])]
      , Array [Int 1]
      , String "text"
      , Int 2
      , Float 2.5
      , Bool True
      , Null
      ]

  it "details normalize arbitrary nested mappings and detach" $
    -- A custom Mapping and a MappingProxyType are both an Object here; the
    -- snapshot is a plain value that later mutation cannot reach.
    snapshotHeartbeatDetails (Object [("custom", Object [("nested", Array [Int 1])])])
      `shouldBe` Right (Object [("custom", Object [("nested", Array [Int 1])])])

  it "details enforce JSON faithfulness finite numbers and UTF-8 byte limit" $ do
    -- {1: "non-string key"}, (1, 2) and object() are unrepresentable in Json.
    mapM_
      ( \invalid ->
          snapshotHeartbeatDetails invalid `shouldSatisfy` either (T.isInfixOf "heartbeat details") (const False)
      )
      [Object [("n", Float (0 / 0))], Object [("n", Float (1 / 0))]]
    snapshotHeartbeatDetails (String (T.replicate (heartbeatDetailsLimit - 2) "x")) `shouldSatisfy` (not . isLeft)
    snapshotHeartbeatDetails (String (T.replicate (heartbeatDetailsLimit - 1) "x"))
      `shouldSatisfy` either (T.isInfixOf "limit") (const False)
