-- | The Dispatch adapters against the reference's tests:
-- @tests/petrus/engine/test_coordinator.py@ (TestInMemoryDispatch,
-- TestInlineDispatch), @tests/integration/test_activity_seam.py@
-- (TestInlineDispatch), and
-- @tests/petrus/motus/dispatch/test_attempt_heartbeats.py@ (the inline
-- context).
module Main (main) where

import Control.Exception (Exception (..), throwIO, try)
import Data.Either (isLeft)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch
import Petrus.Motus.Dispatch.InMemory
import Petrus.Motus.Dispatch.Inline
import Test.Hspec hiding (context, pending)

-- Python's built-in exception types, so classification names them alike.
newtype RuntimeError = RuntimeError String deriving stock (Show)

instance Exception RuntimeError where displayException (RuntimeError m) = m

newtype LookupError = LookupError String deriving stock (Show)

instance Exception LookupError where displayException (LookupError m) = m

newtype TimeoutError = TimeoutError String deriving stock (Show)

instance Exception TimeoutError where displayException (TimeoutError m) = m

work :: Text -> Json -> Maybe Text -> Maybe Text -> ActivityInvocation
work name payload correlation idempotency = (invocation name payload) {correlation, idempotency}

withAttempts :: Integer -> ActivityInvocation -> ActivityInvocation
withAttempts n inv =
  inv {policy = either (error . T.unpack) id (executionPolicy (policyFields defaultExecutionPolicy) {attempts = n})}

failure :: ActivityFailureFields -> ActivityFailure
failure = either (error . T.unpack) id . activityFailure

retryableFailure :: Text -> Text -> ActivityFailure
retryableFailure message kind = failure (ActivityFailureFields message kind Null True Nothing)

obj :: [(Text, Json)] -> Json
obj = Object

instruction :: Int -> ActivityInvocation -> Int -> CancellationInstruction
instruction o inv p = either (error . T.unpack) id (cancellationInstruction o inv p)

cancelOf :: Dispatch -> CancellationInstruction -> IO CancellationDisposition
cancelOf port = maybe (\_ -> error "not cancellable") id port.cancel

dispatchErrorWith :: Text -> Selector DispatchError
dispatchErrorWith fragment (DispatchError message) = fragment `T.isInfixOf` message

main :: IO ()
main = hspec $ do
  describe "TestInMemoryDispatch" $ do
    it "dispatch acknowledges and the invocation waits in the pool" $ do
      pool <- newInMemoryDispatch
      let inv = work "work" (Int 1) (Just "c") (Just "i")
      (inMemoryDispatch pool).dispatch 7 inv
      pending pool `shouldReturn` [(7, inv)]
      (inMemoryDispatch pool).collect `shouldReturn` []

    it "completions collect in completion order and drain" $ do
      pool <- newInMemoryDispatch
      let port = inMemoryDispatch pool
      port.dispatch 1 (work "work" Null (Just "c") (Just "i"))
      port.dispatch 2 (work "work" Null (Just "c2") (Just "i2"))
      completeOccurrence pool 2 (obj [("ok", Bool True)])
      completeOccurrence pool 1 (obj [("ok", Bool False)])
      port.collect `shouldReturn` [(2, Succeeded (obj [("ok", Bool True)])), (1, Succeeded (obj [("ok", Bool False)]))]
      port.collect `shouldReturn` []
      pending pool `shouldReturn` []

    it "fail completes with an activity failure" $ do
      pool <- newInMemoryDispatch
      (inMemoryDispatch pool).dispatch 1 (work "work" Null (Just "c") (Just "i"))
      failOccurrence pool 1 "boom"
      (inMemoryDispatch pool).collect `shouldReturn` [(1, Failed (either (error . T.unpack) id (simpleFailure "boom")))]

    it "completing an undispatched occurrence fails loud" $ do
      pool <- newInMemoryDispatch
      completeOccurrence pool 9 (obj []) `shouldThrow` dispatchErrorWith "not pending"

    it "a second dispatch of a pending occurrence fails loud" $ do
      pool <- newInMemoryDispatch
      let inv = work "work" Null (Just "c") (Just "i")
      (inMemoryDispatch pool).dispatch 1 inv
      (inMemoryDispatch pool).dispatch 1 inv `shouldThrow` dispatchErrorWith "already pending"

    it "keeps pending work in dispatch order, not occurrence order" $ do
      pool <- newInMemoryDispatch
      let inv = work "work" Null Nothing Nothing
      mapM_ (\o -> (inMemoryDispatch pool).dispatch o inv) [5, 2, 9]
      map fst <$> pending pool `shouldReturn` [5, 2, 9]

  describe "InMemoryDispatch cancellation" $ do
    let inv = work "work" Null (Just "c") (Just "i")
        other = work "other" Null (Just "c") (Just "i")
    it "retires pending work, acknowledges a repeat, and conflicts on a different instruction" $ do
      pool <- newInMemoryDispatch
      let port = inMemoryDispatch pool
          cancelPort = cancelOf port
      port.dispatch 3 inv
      cancelPort (instruction 3 inv 4) `shouldReturn` Retired
      pending pool `shouldReturn` []
      cancelPort (instruction 3 inv 4) `shouldReturn` Acknowledged
      cancelPort (instruction 3 inv 5) `shouldThrow` dispatchErrorWith "cancellation conflict for occurrence 3"
    it "refuses to retire pending work under a different invocation" $ do
      pool <- newInMemoryDispatch
      let port = inMemoryDispatch pool
          cancelPort = cancelOf port
      port.dispatch 3 inv
      cancelPort (instruction 3 other 4) `shouldThrow` dispatchErrorWith "cancellation conflict"
    it "reports a buffered terminal outcome and tombstones unknown work" $ do
      pool <- newInMemoryDispatch
      let port = inMemoryDispatch pool
          cancelPort = cancelOf port
      port.dispatch 1 inv
      completeOccurrence pool 1 Null
      cancelPort (instruction 1 inv 2) `shouldReturn` Terminal
      cancelPort (instruction 2 inv 2) `shouldReturn` Tombstoned
    it "drops a fenced redispatch of the same invocation and refuses a different one" $ do
      pool <- newInMemoryDispatch
      let port = inMemoryDispatch pool
          cancelPort = cancelOf port
      _ <- cancelPort (instruction 4 inv 2)
      port.dispatch 4 inv
      pending pool `shouldReturn` []
      port.dispatch 4 other `shouldThrow` dispatchErrorWith "cancellation conflict for occurrence 4"
    it "settles a fenced occurrence without it being pending" $ do
      pool <- newInMemoryDispatch
      let cancelPort = cancelOf (inMemoryDispatch pool)
      _ <- cancelPort (instruction 4 inv 2)
      completeOccurrence pool 4 (Int 1)
      (inMemoryDispatch pool).collect `shouldReturn` [(4, Succeeded (Int 1))]

  describe "CancellationInstruction" $ do
    let inv = invocation "work" Null
    it "requires a positive occurrence and history position" $ do
      cancellationInstruction 0 inv 1 `shouldBe` Left "Cancellation Instruction occurrence must be a positive integer"
      cancellationInstruction 1 inv 0 `shouldBe` Left "Cancellation Instruction history_position must be a positive integer"
      isLeft (cancellationInstruction 1 inv 1) `shouldBe` False
    it "spells the dispositions as the reference's StrEnum" $
      map dispositionText [minBound .. maxBound] `shouldBe` ["tombstoned", "retired", "fenced", "terminal", "acknowledged"]

  describe "ActivityAttempt" $ do
    it "refuses an empty instance and snapshots details" $ do
      let inv = invocation "work" Null
      fmap (const ()) (activityAttempt "a" "1" "w" "q" inv Null (Just ""))
        `shouldBe` Left "Activity Attempt instance must be a non-empty string or None"
      fmap (.latestDetails) (activityAttempt "a" "1" "w" "q" inv (Array [Int 1]) Nothing) `shouldBe` Right (Array [Int 1])
      isLeft (activityAttempt "a" "1" "w" "q" inv (Float (1 / 0)) Nothing) `shouldBe` True

  describe "TestInlineDispatch (coordinator)" $ do
    it "dispatch executes immediately and completion waits for collect" $ do
      adapter <- newInlineDispatch (Map.fromList [("work", \inv _ -> pure (obj [("echo", inv.input)]))])
      (inlineDispatch adapter).dispatch 1 (work "work" (Int 5) (Just "c") (Just "i"))
      (inlineDispatch adapter).collect `shouldReturn` [(1, Succeeded (obj [("echo", Int 5)]))]
      (inlineDispatch adapter).collect `shouldReturn` []

    it "a raising runtime completes with an activity failure" $ do
      adapter <- newInlineDispatch (Map.fromList [("work", \_ _ -> throwIO (RuntimeError "provider down"))])
      (inlineDispatch adapter).dispatch 1 (work "work" Null (Just "c") (Just "i"))
      (inlineDispatch adapter).collect `shouldReturn` [(1, Failed (retryableFailure "provider down" "RuntimeError"))]

  describe "TestInlineDispatch (activity seam)" $ do
    it "registry is snapshotted and the adapter remains frozen" $ do
      -- A Haskell Map is an immutable snapshot: later registry edits cannot
      -- reach the adapter, and there is no mutable field to reassign.
      let registry = Map.fromList [("charge_card", \inv _ -> pure inv.input)]
      adapter <- newInlineDispatch registry
      let _edited = Map.insert "refund" (\inv _ -> pure inv.input) registry
      Map.keys (inlineActivities adapter) `shouldBe` ["charge_card"]

    it "classified retries are immediate and never sleep" $ do
      calls <- newIORef []
      let flaky called context = do
            modifyIORef' calls (++ [(called, context.epoch)])
            n <- length <$> readIORef calls
            if n < 3
              then activityError (ActivityFailureFields "temporary" "Unavailable" Null True (Just 60))
              else pure (String "done")
          policy =
            either (error . T.unpack) id $
              executionPolicy (policyFields defaultExecutionPolicy) {attempts = 3, initialInterval = 30}
          inv = (work "flaky" Null (Just "operation") (Just "effect")) {policy}
      adapter <- newInlineDispatch (Map.fromList [("flaky", flaky)])
      runInline adapter inv `shouldReturn` String "done"
      recorded <- readIORef calls
      map snd recorded `shouldBe` ["1", "2", "3"]
      all ((== inv) . fst) recorded `shouldBe` True

    it "generic exception keeps precise retryable metadata when budget exhausts" $ do
      adapter <- newInlineDispatch (Map.fromList [("broken", \_ _ -> throwIO (LookupError "missing account"))])
      (inlineDispatch adapter).dispatch 7 (withAttempts 2 (invocation "broken" Null))
      (inlineDispatch adapter).collect `shouldReturn` [(7, Failed (retryableFailure "missing account" "LookupError"))]

    it "an empty exception message is spelled by the exception's type name" $ do
      adapter <- newInlineDispatch (Map.fromList [("broken", \_ _ -> throwIO (LookupError ""))])
      (inlineDispatch adapter).dispatch 7 (invocation "broken" Null)
      (inlineDispatch adapter).collect `shouldReturn` [(7, Failed (retryableFailure "LookupError" "LookupError"))]

    it "executes the named activity with the whole invocation" $ do
      let charge inv _ = case inv.input of
            Object members -> pure (obj [("status", String "captured"), ("amount", maybe Null id (lookup "amount" members))])
            _ -> pure Null
      adapter <- newInlineDispatch (Map.fromList [("charge_card", charge)])
      runInline adapter (invocation "charge_card" (obj [("amount", Int 100)]))
        `shouldReturn` obj [("status", String "captured"), ("amount", Int 100)]

    it "an unknown activity fails loud" $ do
      adapter <- newInlineDispatch Map.empty
      runInline adapter (invocation "charge_card" Null)
        `shouldThrow` (\(DispatchError m) -> m == "no activity implementation for 'charge_card': this InlineDispatch implements []")

    it "an unknown activity dispatched is buffered as a ValueError failure" $ do
      adapter <- newInlineDispatch (Map.fromList [("b", \_ _ -> pure Null), ("a", \_ _ -> pure Null)])
      (inlineDispatch adapter).dispatch 1 (invocation "charge_card" Null)
      (inlineDispatch adapter).collect
        `shouldReturn` [ ( 1
                         , Failed
                             ( retryableFailure
                                 "no activity implementation for 'charge_card': this InlineDispatch implements ['a', 'b']"
                                 "ValueError"
                             )
                         )
                       ]

    it "the conservative policy makes an exception terminal" $ do
      calls <- newIORef (0 :: Int)
      adapter <- newInlineDispatch (Map.fromList [("charge_card", \_ _ -> modifyIORef' calls (+ 1) >> throwIO (TimeoutError "provider gone"))])
      runInline adapter (invocation "charge_card" Null) `shouldThrow` (\(TimeoutError m) -> m == "provider gone")
      readIORef calls `shouldReturn` 1

    it "a declared attempts policy is honored" $ do
      answers <- newIORef [Left (TimeoutError "blip"), Right (obj [("status", String "captured")])]
      let flaky _ _ = do
            next <- atomicModifyIORef' answers (\xs -> (drop 1 xs, take 1 xs))
            case next of
              [answer] -> either throwIO pure answer
              _ -> expectationFailure "consulted past its script" >> pure Null
      adapter <- newInlineDispatch (Map.fromList [("charge_card", flaky)])
      runInline adapter (withAttempts 2 (invocation "charge_card" Null)) `shouldReturn` obj [("status", String "captured")]

    it "a non-retryable classified failure is terminal despite remaining attempts" $ do
      calls <- newIORef (0 :: Int)
      let refuse _ _ = modifyIORef' calls (+ 1) >> activityError (ActivityFailureFields "declined" "CardDeclined" Null False Nothing)
      adapter <- newInlineDispatch (Map.fromList [("charge_card", refuse)])
      (inlineDispatch adapter).dispatch 1 (withAttempts 5 (invocation "charge_card" Null))
      (inlineDispatch adapter).collect `shouldReturn` [(1, Failed (failure (ActivityFailureFields "declined" "CardDeclined" Null False Nothing)))]
      readIORef calls `shouldReturn` 1

  describe "InlineDispatch cancellation" $ do
    let inv = work "work" Null (Just "c") (Just "i")
    it "tombstones, reports buffered terminal outcomes, acknowledges repeats, and drops fenced work" $ do
      ran <- newIORef (0 :: Int)
      adapter <- newInlineDispatch (Map.fromList [("work", \_ _ -> modifyIORef' ran (+ 1) >> pure Null)])
      let port = inlineDispatch adapter
          cancelPort = cancelOf port
      cancelPort (instruction 2 inv 3) `shouldReturn` Tombstoned
      port.dispatch 2 inv
      readIORef ran `shouldReturn` 0
      port.dispatch 2 (work "other" Null Nothing Nothing) `shouldThrow` dispatchErrorWith "cancellation conflict for occurrence 2"
      port.dispatch 1 inv
      cancelPort (instruction 1 inv 3) `shouldReturn` Terminal
      cancelPort (instruction 1 inv 3) `shouldReturn` Acknowledged
      cancelPort (instruction 1 inv 4) `shouldThrow` dispatchErrorWith "cancellation conflict for occurrence 1"
      Map.keys <$> inlineCancelled adapter `shouldReturn` [1, 2]

  describe "inline heartbeat context" $ do
    it "has synthetic identity and detached omitted/null details" $ do
      observed <- newIORef []
      let record key value = modifyIORef' observed (++ [(key, value)])
          activity _ context = do
            record "attempt_id" (String context.attemptId)
            record "epoch" (String context.epoch)
            record "claimant" (String context.claimant)
            record "instance" (maybe Null String context.instance')
            context.latestDetails >>= record "initial"
            first <- context.heartbeat (Just (obj [("nested", Array [Int 1])]))
            context.heartbeat Nothing >>= record "preserved"
            context.heartbeat (Just Null) >>= record "null"
            pure first
      adapter <- newInlineDispatch (Map.fromList [("work", activity)])
      runInline adapter (invocation "work" Null) `shouldReturn` obj [("nested", Array [Int 1])]
      readIORef observed
        `shouldReturn` [ ("attempt_id" :: Text, String "inline-1")
                       , ("epoch", String "1")
                       , ("claimant", String "inline")
                       , ("instance", Null)
                       , ("initial", Null)
                       , ("preserved", obj [("nested", Array [Int 1])])
                       , ("null", Null)
                       ]
    it "refuses non-finite heartbeat details" $ do
      adapter <- newInlineDispatch (Map.fromList [("work", \_ context -> context.heartbeat (Just (Float (0 / 0))))])
      result <- try (runInline adapter (invocation "work" Null))
      case result of
        Left (DispatchError message) -> message `shouldBe` "heartbeat details require finite JSON numbers"
        Right value -> expectationFailure ("expected a refusal, got " <> show value)
