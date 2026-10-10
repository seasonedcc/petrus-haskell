-- | Port of @tests/petrus/engine/test_engine.py@: the provider-neutral
-- one-Instance Engine composition.
module Petrus.Engine.EngineSpec (spec) where

import Data.IORef
import Petrus.Activity (ActivityInvocation (..))
import Petrus.Engine qualified as Engine
import Petrus.Engine.TestSupport
import Petrus.Impetus.History.Records
import Petrus.Impetus.HistoryStore (inMemoryHistoryStore)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance (Status (..))
import Petrus.Impetus.Petrinet
import Petrus.Impetus.TestSupport (netOf, np, tokD)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch (Dispatch)
import Test.Hspec

a, b, work :: NetPath
a = np "a"
b = np "b"
work = np "work"

activityNet :: Net
activityNet =
  netOf
    [place a, place b]
    [Transition work (Just (HandlerSymbol "bridge")) [] []]
    [arc a work, arc work b]

inlineActivity :: IO Dispatch
inlineActivity = inlineOf [("activity", \inv _ -> pure (Object [("value", inv.input)]))]

spec :: Spec
spec = describe "TestNeutralEngineSurface" $ do
  it "create, advance, close, and load preserve one canonical history" $ do
    history <- inMemoryHistoryStore
    bridge <- newBridge "activity" b
    port <- inlineActivity
    engine <-
      Engine.create activityNet "neutral" history port
        Engine.defaultEngineOptions
          { Engine.marking = markingFromList [(a, [tokD "Input" (Int 3)])]
          , Engine.handlers = symbols [("bridge", bridge.handler)]
          }
    (created : RTokensInitialized initialized : _) <- Engine.records engine
    created `shouldBe` RInstanceCreated (InstanceCreated "neutral" Nothing 0)
    (initialized.place, initialized.tokens) `shouldBe` (a, [tokD "Input" (Int 3)])
    outcome <- advanceUntilRest engine
    outcome.waiting `shouldBe` False
    Engine.marking engine `shouldReturn` markingFromList [(b, [tokD "Done" (Object [("value", Int 3)])])]
    Engine.status engine `shouldReturn` Terminated
    recorded <- Engine.records engine
    Engine.close engine

    loadedBridge <- newBridge "activity" b
    port' <- inlineActivity
    loaded <- Engine.load activityNet "neutral" history port' Engine.defaultEngineOptions {Engine.handlers = symbols [("bridge", loadedBridge.handler)]}
    Engine.records loaded `shouldReturn` recorded
    Store.records history `shouldReturn` recorded
    Engine.marking loaded `shouldReturn` markingFromList [(b, [tokD "Done" (Object [("value", Int 3)])])]
    readIORef loadedBridge.prepared `shouldReturn` 0
    readIORef loadedBridge.projected `shouldReturn` 0
    Engine.close loaded

  it "advance yields after each whole action" $ do
    bridge <- newBridge "activity" b
    port <- inlineActivity
    history <- inMemoryHistoryStore
    engine <-
      Engine.create activityNet "one-action" history port
        Engine.defaultEngineOptions
          { Engine.marking = markingFromList [(a, [tokD "Input" (Int 3)])]
          , Engine.handlers = symbols [("bridge", bridge.handler)]
          }
    begun <- Engine.advance engine
    begun.ready `shouldBe` True
    begun.waiting `shouldBe` False
    length <$> Engine.inFlight engine `shouldReturn` 1
    readIORef bridge.prepared `shouldReturn` 1
