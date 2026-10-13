{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The Engine checker unit tests (@test_*_checker_*@ of the reference's
-- world test files): every hand-built observation runs through the Haskell
-- twin of its checker class, and the whole verdict (@passed@ and every
-- @detail@ field) must equal the reference's, recorded by
-- @scripts/engine_checker_vectors.py@ in @test/data/engine-checkers.json@,
-- and likewise every joined-world checker test (@test_joined_*world.py@),
-- recorded by @scripts/joined_checker_vectors.py@ in
-- @test/data/joined-checkers.json@. The joined checkers' Python @==@ over
-- decoded JSON (petrus-json's 'pythonEq', also through 'Support.pyIn' and
-- 'Support.pyCount') is compared with the pinned CPython's, live.
module Spec.EngineCheckers (spec, engineCheckers) where

import Control.Monad (forM_)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..), lookupMember, pythonEq)
import Petrus.TestSupport.Python (pythonJson)
import Petrus.Testing.Dst
import Petrus.Testing.Dst.Engine.Delayed qualified as Delayed
import Petrus.Testing.Dst.Engine.Delivery qualified as Delivery
import Petrus.Testing.Dst.Engine.GeneratedRuntime qualified as GeneratedRuntime
import Petrus.Testing.Dst.Engine.Lifecycle qualified as Lifecycle
import Petrus.Testing.Dst.Engine.Projection qualified as Projection
import Petrus.Testing.Dst.Engine.Retry qualified as Retry
import Petrus.Testing.Dst.Engine.Timer qualified as Timer
import Petrus.Testing.Dst.Joined.Checkers qualified as Joined
import Petrus.Testing.Dst.Joined.Support qualified as Support
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
    | name == GeneratedRuntime.checkerIdentity.name -> pure (Just GeneratedRuntime.generatedRuntimeChecker)
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
spec = do
  describe "Engine checker classes (Python-recorded verdicts)" $
    vectorSpec "engine-checkers.json" checkerNamed
  describe "Joined checker classes (Python-recorded verdicts)" $
    vectorSpec "joined-checkers.json" $ \name ->
      pure (case [c | c <- Joined.joinedCheckers, c.identity.name == name] of
        c : _ -> Just c
        [] -> Nothing)
  describe "Joined checkers' Python == over decoded JSON" $
    it "agrees with CPython's ==, in and count on NaN, infinities, signed zeros, big integers and nested values" $ do
      -- Each side is evaluated afresh, so no two NaNs are one object (whose
      -- identity CPython's container comparisons would short-cut).
      expected <-
        pythonJson
          ( T.unlines
              [ "import json, sys"
              , "values = sys.argv[1:]"
              , "print(json.dumps({"
              , "    'eq': [[eval(a) == eval(b) for b in values] for a in values],"
              , "    'in': [eval(a) in [eval(b) for b in values] for a in values],"
              , "    'count': [[eval(b) for b in values].count(eval(a)) for a in values],"
              , "}))"
              ]
          )
          (map fst pythonValues)
      let values = map snd pythonValues
      Object
        [ ("eq", Array [Array [Bool (pythonEq a b) | b <- values] | a <- values])
        , ("in", Array [Bool (Support.pyIn a values) | a <- values])
        , ("count", Array [Int (Support.pyCount a values) | a <- values])
        ]
        `shouldBeJson` expected

-- | Python expressions, each with the decoded JSON it stands for.
pythonValues :: [(String, Json)]
pythonValues =
  [ ("None", Null)
  , ("True", Bool True)
  , ("False", Bool False)
  , ("0", Int 0)
  , ("1", Int 1)
  , ("0.0", Float 0)
  , ("-0.0", Float (-0.0))
  , ("1.0", Float 1)
  , ("float('nan')", Float nan)
  , ("float('inf')", Float inf)
  , ("float('-inf')", Float (negate inf))
  , ("2**1024", Int (2 ^ (1024 :: Int)))
  , ("2**53 + 1", Int (2 ^ (53 :: Int) + 1))
  , ("float(2**53)", Float (2 ^ (53 :: Int)))
  , ("'nan'", String "nan")
  , ("[float('nan')]", Array [Float nan])
  , ("[1, {'a': True}]", Array [Int 1, Object [("a", Bool True)]])
  , ("[1.0, {'a': 1}]", Array [Float 1, Object [("a", Int 1)]])
  , ("{'a': float('inf'), 'b': 0}", Object [("a", Float inf), ("b", Int 0)])
  , ("{'b': False, 'a': float('inf')}", Object [("b", Bool False), ("a", Float inf)])
  , ("{'a': float('nan')}", Object [("a", Float nan)])
  ]
  where
    nan = 0 / 0
    inf = 1 / 0

-- | Every recorded vector of one file, checked by its named checker.
vectorSpec :: FilePath -> (Text -> IO (Maybe Checker)) -> Spec
vectorSpec file named = do
  vectors <- runIO (memberList "vectors" <$> readJson (dataFile file))
  forM_ vectors $ \vector ->
    it (T.unpack (memberText "name" vector)) $ do
      checker <- named (memberText "checker" vector) >>= maybe (fail "unknown checker") pure
      let prior = case lookupMember "prior" vector of
            Just (Array xs) -> xs
            _ -> []
      -- The prior observations build the checker's memory, as the
      -- reference's vectors call @check@ on one instance in order.
      let advance current earlier = current >>= fmap snd . (`runChecker` observationOf earlier)
      case foldl' advance (Right checker) prior >>= (`runChecker` observationOf (member "observation" vector)) of
        Left failure -> expectationFailure (show failure)
        Right (result, _) ->
          Object [("detail", result.detail), ("passed", Bool result.passed)] `shouldBeJson` member "result" vector
