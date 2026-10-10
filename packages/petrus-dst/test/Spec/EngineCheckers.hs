{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The Engine checker unit tests (@test_*_checker_*@ of the reference's
-- world test files): every hand-built observation runs through the Haskell
-- twin of its checker class, and the whole verdict (@passed@ and every
-- @detail@ field) must equal the reference's, recorded by
-- @scripts/engine_checker_vectors.py@ in @test/data/engine-checkers.json@.
module Spec.EngineCheckers (spec, engineCheckers) where

import Control.Monad (forM_)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..), lookupMember)
import Petrus.Testing.Dst
import Petrus.Testing.Dst.Engine.Delayed qualified as Delayed
import Petrus.Testing.Dst.Engine.Delivery qualified as Delivery
import Petrus.Testing.Dst.Engine.GeneratedRuntime qualified as GeneratedRuntime
import Petrus.Testing.Dst.Engine.Lifecycle qualified as Lifecycle
import Petrus.Testing.Dst.Engine.Projection qualified as Projection
import Petrus.Testing.Dst.Engine.Retry qualified as Retry
import Petrus.Testing.Dst.Engine.Timer qualified as Timer
import Spec.Support
import Test.Hspec

-- | Every stateless Engine checker, by identity name.
engineCheckers :: [Checker]
engineCheckers =
  [ Projection.engineHistoryChecker
  , Projection.commitAuthorityChecker
  , Projection.acceptedCommitAuthorityChecker
  , Projection.dispatchAuthorityChecker
  , Projection.terminalRefusalChecker
  , Delayed.delayedAuthorityChecker
  , Delivery.deliveryAuthorityChecker
  , Lifecycle.lifecycleAuthorityChecker
  , Lifecycle.cancellationAuthorityChecker
  , Timer.timerAuthorityChecker
  , Retry.retryAuthorityChecker
  , Retry.delayedRetryAuthorityChecker
  , Retry.terminalAuthorityChecker
  ]

-- | A fresh checker instance by identity name (the generated-runtime
-- checker keeps state across the checks of one instance).
checkerNamed :: Text -> IO (Maybe Checker)
checkerNamed name = case [c | c <- engineCheckers, c.identity.name == name] of
  c : _ -> pure (Just c)
  []
    | name == GeneratedRuntime.checkerIdentity.name -> Just <$> GeneratedRuntime.newGeneratedRuntimeChecker
    | otherwise -> pure Nothing

int :: Text -> Json -> Integer
int key value = case member key value of
  Int n -> n
  other -> error ("not an integer: " <> show other)

observationOf :: Json -> Observation
observationOf o =
  Observation
    { name = memberText "name" o
    , value = member "value" o
    , instant = int "instant" o
    , generation = int "generation" o
    , sequence = int "sequence" o
    }

spec :: Spec
spec = describe "Engine checker classes (Python-recorded verdicts)" $ do
  vectors <- runIO (memberList "vectors" <$> readJson (dataFile "engine-checkers.json"))
  forM_ vectors $ \vector ->
    it (T.unpack (memberText "name" vector)) $ do
      checker <- checkerNamed (memberText "checker" vector) >>= maybe (fail "unknown checker") pure
      let prior = case lookupMember "prior" vector of
            Just (Array xs) -> xs
            _ -> []
      forM_ prior $ \earlier -> either (expectationFailure . show) (const (pure ())) (checker.check (observationOf earlier))
      case checker.check (observationOf (member "observation" vector)) of
        Left failure -> expectationFailure (show failure)
        Right result ->
          Object [("detail", result.detail), ("passed", Bool result.passed)] `shouldBeJson` member "result" vector
