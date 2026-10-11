-- | Parity: the Absurd part of
-- @tests/petrus/motus/dispatch/test_attempt_heartbeats.py@ — the attempt
-- state model (1 case) and the reconnectable heartbeat's replace-once rule
-- (2 functions, 8 cases). The reference monkeypatches a facade over fake
-- connections; here the rule is 'reconnectOnce' itself, driven with the
-- same fakes: a dead/alive transport flag, a replacement counter and a
-- heartbeat that always raises the given error.
module Petrus.Motus.Dispatch.Absurd.HeartbeatSpec (spec) where

import Control.Exception (Exception, SomeException, throwIO, try)
import Control.Monad (forM_)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Motus.Dispatch.Absurd (AbsurdError (..), reconnectOnce)
import Petrus.Postgres (ErrorClass (..), PostgresError (..), errorClassForState)
import Test.Hspec hiding (after, before, pending)

spec :: Spec
spec = do
  describe "the attempt state model" $
    it "covers renewal, expiry, reassignment, terminal and stale refusal" attemptModel
  describe "the reconnectable heartbeat" $ do
    forM_ [(OperationalError, "closed"), (InterfaceError, "broken")] $ \(cls, message) ->
      it ("replaces a closed transport once on " <> show cls <> " and never retries the replacement") $ do
        calls <- newIORef (0 :: Int)
        replacements <- newIORef (0 :: Int)
        let failure = clientFailure cls message
            beat = modifyIORef' calls (+ 1) >> throwIO failure :: IO ()
        result <- try (reconnectOnce (pure True) (modifyIORef' replacements (+ 1)) beat)
        either (\e -> (e :: PostgresError).errorClass) (const DatabaseError) result `shouldBe` cls
        readIORef calls `shouldReturn` 2
        readIORef replacements `shouldReturn` 1
    let semantic :: [(String, IO ())]
        semantic =
          [ ("QueryCanceled", throwIO (serverFailure "57014" "cancelled"))
          , ("DeadlockDetected", throwIO (serverFailure "40P01" "deadlock"))
          , ("DataError", throwIO (serverFailure "22000" "bad data"))
          , ("ProgrammingError", throwIO (serverFailure "42000" "bad query"))
          , ("IntegrityError", throwIO (serverFailure "23000" "constraint"))
          , ("RuntimeError", throwIO (AbsurdError "stale Activity Attempt"))
          ]
    forM_ semantic $ \(name, raise) ->
      it ("does not replace or retry the semantic error " <> name) $ do
        calls <- newIORef (0 :: Int)
        replacements <- newIORef (0 :: Int)
        result <- try @SomeException (reconnectOnce (pure False) (modifyIORef' replacements (+ 1)) (modifyIORef' calls (+ 1) >> raise))
        either (const True) (const False) result `shouldBe` True
        readIORef calls `shouldReturn` 1
        readIORef replacements `shouldReturn` 0

clientFailure :: ErrorClass -> Text -> PostgresError
clientFailure cls message = PostgresError cls Nothing message Nothing Nothing Nothing Nothing

serverFailure :: Text -> Text -> PostgresError
serverFailure state message = PostgresError (errorClassForState state) (Just state) message Nothing Nothing Nothing Nothing

-- ---------------------------------------------------------------------------
-- The reference's test-local AttemptModel

data AttemptModel = AttemptModel
  { epoch :: Int
  , claimant :: Maybe Text
  , deadline :: Maybe Int
  , state :: Text
  }

newtype Stale = Stale Text
  deriving stock (Show)

instance Exception Stale

claimModel :: AttemptModel -> Text -> Int -> Int -> IO AttemptModel
claimModel m who now timeout
  | m.state == "terminal" || (m.state == "running" && maybe False (now <) m.deadline) = throwIO (Stale "not claimable")
  | otherwise = pure (AttemptModel (m.epoch + 1) (Just who) (Just (now + timeout)) "running")

heartbeatModel :: AttemptModel -> Text -> Int -> Int -> Int -> IO AttemptModel
heartbeatModel m who epoch' now timeout = do
  guardModel m who epoch' now
  pure (AttemptModel epoch' (Just who) (Just (now + timeout)) "running")

terminalModel :: AttemptModel -> Text -> Int -> Int -> IO AttemptModel
terminalModel m who epoch' now = do
  guardModel m who epoch' now
  pure (AttemptModel epoch' (Just who) m.deadline "terminal")

guardModel :: AttemptModel -> Text -> Int -> Int -> IO ()
guardModel m who epoch' now =
  if m.state /= "running" || Just who /= m.claimant || epoch' /= m.epoch || maybe True (now >=) m.deadline
    then throwIO (Stale "stale Attempt")
    else pure ()

stale :: Selector Stale
stale (Stale message) = "stale Attempt" `T.isInfixOf` message

attemptModel :: IO ()
attemptModel = do
  first' <- claimModel (AttemptModel 0 Nothing Nothing "pending") "worker-a" 0 10
  renewed <- heartbeatModel first' "worker-a" 1 5 20
  renewed.deadline `shouldBe` Just 25
  second <- claimModel renewed "worker-b" 25 10
  (second.epoch, second.claimant, second.deadline) `shouldBe` (2, Just "worker-b", Just 35)
  heartbeatModel renewed "worker-a" 1 25 10 `shouldThrow` stale
  terminalModel renewed "worker-a" 1 25 `shouldThrow` stale
  terminal <- terminalModel second "worker-b" 2 30
  heartbeatModel terminal "worker-b" 2 30 10 `shouldThrow` stale
  terminalModel terminal "worker-b" 2 30 `shouldThrow` stale
