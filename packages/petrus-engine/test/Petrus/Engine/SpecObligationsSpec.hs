-- | Normative statements of @upstream/petrus/spec@ that no ported upstream
-- test checks through an Engine. 'SPEC.md' maps every statement of the
-- Engine's sections to the examples that check it; these are the ones it
-- had to add.
module Petrus.Engine.SpecObligationsSpec (spec) where

import Control.Exception (SomeException, throwIO, try)
import Data.Char (toLower)
import Data.IORef
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity
  ( ActivityFailure
  , ActivityFailureFields (..)
  , ActivityInvocationFields (..)
  , activityInvocation
  , ExecutionPolicyFields (..)
  , activityError
  , defaultExecutionPolicy
  , executionPolicy
  , failureFields
  , policyFields
  )
import Petrus.Engine qualified as Engine
import Petrus.Engine.BoundarySpec (exportedNames)
import Petrus.Engine.TestSupport (advanceUntilRest, inlineOf, mkScopedDelivery, symbols)
import Petrus.Impetus.Binding
import Petrus.Impetus.History.Records
import Petrus.Impetus.HistoryStore (inMemoryHistoryStore)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance (DeliveryScope (..))
import Petrus.Impetus.Petrinet hiding (token)
import Petrus.Impetus.TestSupport (netOf, np, tok, tokD)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch.InMemory (inMemoryDispatch, newInMemoryDispatch)
import Petrus.TestSupport.Boundary (exportList)
import Test.Hspec

a, b, c, d, src, t, timed, u :: NetPath
a = np "a"
b = np "b"
c = np "c"
d = np "d"
src = np "src"
t = np "t"
timed = np "timed"
u = np "u"

-- | @a -> t -> b@, @t@ bound to the symbol @charge@.
chargeNet :: Net
chargeNet = netOf [place a, place b] [Transition t (Just (HandlerSymbol "charge")) [] []] [arc a t, arc t b]

charge :: ExecutionPolicyFields -> Maybe (Binding -> ActivityFailure -> Either Text HandlerResult) -> ActivityHandler
charge fields failureProjection =
  ActivityHandler
    { prepare = \_ ->
        activityInvocation
          ActivityInvocationFields
            { activity = "charge"
            , input = Object [("n", Int 1)]
            , policy = either (error . T.unpack) id (executionPolicy fields)
            , correlation = Nothing
            , idempotency = Nothing
            }
    , project = \_ result -> Right (handlerTokens [(b, [tokD "Done" result])])
    , projectFailure = failureProjection
    }

occurrenceIdentity :: ActivityRequested -> Text
occurrenceIdentity r = "occurrence-" <> T.pack (show r.occurrence)

count :: (Record -> Bool) -> [Record] -> Int
count matches = length . filter matches

isRequested, isCompleted, isActivityFailed, isFiringCompleted, isFiringFailed :: Record -> Bool
isRequested = \case RActivityRequested _ -> True; _ -> False
isCompleted = \case RActivityCompleted _ -> True; _ -> False
isActivityFailed = \case RActivityFailed _ -> True; _ -> False
isFiringCompleted = \case RFiringCompleted _ -> True; _ -> False
isFiringFailed = \case RFiringFailed _ -> True; _ -> False

spec :: Spec
spec = describe "spec obligations (SPEC.md)" $ do
  it "firing-semantics.md Scheduling: a custom policy that first chooses an immature wall-clock action is asked once more without it, and the turn applies one action" $ do
    let net = netOf [place a, place b, place c, place d] [Transition timed Nothing [] [Delay 5], transition u] [arc a timed, arc timed b, arc c u, arc u d]
    seen <- newIORef []
    let policy snapshot = do
          modifyIORef' seen (<> [snapshot])
          pure $ case ([x | x@(Engine.AdvanceTime _) <- snapshot.actions], [x | x@(Engine.BeginCandidate _) <- snapshot.actions]) of
            (advance : _, _) -> advance
            ([], begin : _) -> begin
            _ -> Engine.Stop
        immature = Engine.Clock {now = pure 0, observe = \_ -> pure Nothing}
    port <- inMemoryDispatch <$> newInMemoryDispatch
    store <- inMemoryHistoryStore
    engine <-
      Engine.create net "immature-recall" store port
        Engine.defaultEngineOptions
          { Engine.marking = markingFromList [(a, [tok "X"]), (c, [tok "Y"])]
          , Engine.policy = policy
          , Engine.clock = Just immature
          }
    outcome <- Engine.advance engine
    outcome.ready `shouldBe` True
    snapshots <- readIORef seen
    case snapshots of
      [first, second] -> do
        [x | x@(Engine.AdvanceTime _) <- first.actions] `shouldBe` [Engine.AdvanceTime 5]
        second `shouldBe` Engine.Snapshot (filter (/= Engine.AdvanceTime 5) first.actions) first.inFlight first.previous
      other -> expectationFailure ("the policy was asked " <> show (length other) <> " times in one turn")
    records <- Engine.records engine
    [m | RTimerMatured m <- records] `shouldBe` []
    [f.transition | RFiringBegun f <- records] `shouldBe` [u]

  it "event-history.md Deterministic records vs activity records: an intermediate retryable failure stays Dispatch state, and History holds the request and the one accepted terminal" $ do
    calls <- newIORef []
    let flaky inv _ = do
          n <- atomicModifyIORef' calls (\seen -> (seen <> [inv], length seen + 1))
          if n == 1 then throwIO (userError "transient outage") else pure (Object [("ok", Bool True)])
    port <- inlineOf [("charge", flaky)]
    history <- inMemoryHistoryStore
    engine <-
      Engine.create chargeNet "retry-in-dispatch" history port
        Engine.defaultEngineOptions
          { Engine.marking = markingFromList [(a, [tok "X"])]
          , Engine.handlers = symbols [("charge", ActivityBound (charge (policyFields defaultExecutionPolicy) {attempts = 2} Nothing))]
          }
    _ <- advanceUntilRest engine
    attempts' <- readIORef calls
    length attempts' `shouldBe` 2
    -- One logical execution: both Attempts carry the same frozen identities.
    map (\inv -> (inv.correlation, inv.idempotency)) attempts' `shouldBe` replicate 2 (Just "occurrence-1", Just "occurrence-1")
    records <- Store.records history
    map (`count` records) [isRequested, isCompleted, isActivityFailed, isFiringFailed, isFiringCompleted] `shouldBe` [1, 1, 0, 0, 1]
    Engine.marking engine `shouldReturn` markingFromList [(b, [tokD "Done" (Object [("ok", Bool True)])])]

  it "handler-contract.md activity/projection split: an opted-in failure projection freezes ActivityFailed first, and a projection crash reloads to projection only, never another attempt" $ do
    calls <- newIORef (0 :: Int)
    let declined _ _ = do
          modifyIORef' calls (+ 1)
          activityError (ActivityFailureFields "card declined" "Declined" Null False Nothing)
        broken _ _ = Left "KeyError('projection bug')"
        routed _ failure = Right (handlerTokens [(b, [tokD "Declined" (String (failureFields failure).failureError)])])
        options projector =
          Engine.defaultEngineOptions
            { Engine.marking = markingFromList [(a, [tok "X"])]
            , Engine.handlers = symbols [("charge", ActivityBound (charge (policyFields defaultExecutionPolicy) (Just projector)))]
            }
    history <- inMemoryHistoryStore
    port <- inlineOf [("charge", declined)]
    engine <- Engine.create chargeNet "failure-projection" history port (options broken)
    crashed <- try (advanceUntilRest engine)
    case crashed of
      Left (_ :: SomeException) -> pure ()
      Right _ -> expectationFailure "the failure projection's crash must surface"
    frozen <- Store.records history
    map (`count` frozen) [isActivityFailed, isFiringCompleted, isFiringFailed] `shouldBe` [1, 0, 0]
    readIORef calls `shouldReturn` 1

    port' <- inlineOf [("charge", declined)]
    resumed <- Engine.load chargeNet "failure-projection" history port' (options routed)
    _ <- advanceUntilRest resumed
    readIORef calls `shouldReturn` 1
    records <- Store.records history
    map (`count` records) [isRequested, isActivityFailed, isFiringCompleted, isFiringFailed] `shouldBe` [1, 1, 1, 0]
    Engine.marking resumed `shouldReturn` markingFromList [(b, [tokD "Declined" (String "card declined")])]

  it "event-history.md Lifecycle scopes: scope provenance reaches the Activity request, and generation identity never replaces its correlation or idempotency" $ do
    let net =
          netOf
            [place a, place b]
            [transition src, Transition t (Just (HandlerSymbol "charge")) [] []]
            [arc src a, arc a t, arc t b]
    holder <- newIORef []
    port <- inlineOf [("charge", \_ _ -> pure (Object [("ok", Bool True)]))]
    history <- inMemoryHistoryStore
    engine <-
      Engine.create net "scoped-correlation" history port
        Engine.defaultEngineOptions
          { Engine.handlers = symbols [("charge", ActivityBound (charge (policyFields defaultExecutionPolicy) Nothing))]
          , Engine.sensor = Just (atomicModifyIORef' holder (\queued -> ([], queued)))
          }
    first <- Engine.openScope engine "draft"
    writeIORef holder [mkScopedDelivery src [tok "X"] "delivery-1" (Just (ScopeGeneration first))]
    _ <- advanceUntilRest engine
    second <- Engine.resetScope engine first
    writeIORef holder [mkScopedDelivery src [tok "Y"] "delivery-2" (Just (ScopeGeneration second))]
    _ <- advanceUntilRest engine
    records <- Store.records history
    let requests = [r | RActivityRequested r <- records]
    map (\r -> (r.scope, r.correlation, r.idempotency)) requests
      `shouldBe` [ (Just scope', occurrenceIdentity r, occurrenceIdentity r)
                 | (r, scope') <- zip requests [first, second]
                 ]
    length requests `shouldBe` 2

  it "event-history.md Lifecycle scopes: quarantine is an audit disposition, so the Engine surface offers no release, retarget or retry operation" $ do
    exports <- exportedNames <$> exportList "petrus-engine" "src/Petrus/Engine.hs"
    exports `shouldSatisfy` elem "advance"
    filter (\name -> any (`isInfixOf` map toLower name) ["release", "retarget", "retry", "requeue", "reprocess"]) exports `shouldBe` []
