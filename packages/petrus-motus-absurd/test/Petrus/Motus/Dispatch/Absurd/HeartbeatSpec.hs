-- | Parity: the Absurd part of
-- @tests/petrus/motus/dispatch/test_attempt_heartbeats.py@: the
-- reconnectable heartbeat's replace-once rule (2 functions, 8 cases). The
-- file's test-local attempt state model is ported once, in petrus-activity's
-- @Petrus.Activity.HeartbeatSpec@. The reference monkeypatches a facade over fake
-- connections; here the rule is 'reconnectOnce' itself, driven with the
-- same fakes: a dead/alive transport flag, a replacement counter and a
-- heartbeat that always raises the given error.
module Petrus.Motus.Dispatch.Absurd.HeartbeatSpec (spec) where

import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM_)
import Data.IORef
import Data.Text (Text)
import Petrus.Motus.Dispatch.Absurd (AbsurdError (..), reconnectOnce)
import Petrus.Postgres (ErrorClass (..), PostgresError (..), errorClassForState)
import Test.Hspec hiding (after, before, pending)

spec :: Spec
spec = do
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
