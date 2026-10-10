{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The @sha256-counter-v1@ choice streams against Python golden vectors
-- (@scripts/choice_vectors.py@) and the choice tests of
-- @tests/dst/test_world.py@.
module Spec.Choice (spec) where

import Control.Monad (foldM, replicateM)
import Control.Monad.State.Strict (StateT, evalStateT, get, lift, put)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Petrus.Json (Json (..))
import Petrus.Testing.Dst
import Petrus.Testing.Dst.Decode (LocPart (..), SchemaError (..), pChoiceProvenance)
import Spec.Support
import Test.Hspec

authorityOf :: Text -> IndexAuthority
authorityOf = \case
  "workload" -> WorkloadChoice
  "fault" -> FaultChoice
  _ -> EventOrderChoice

choiceErrorJson :: ChoiceError -> Json
choiceErrorJson e = Object [("message", String e.message), ("type", String e.errorType)]

orFail :: Either ChoiceError a -> a
orFail = either (error . show) id

type Draws = StateT ChoiceStreams (Either ChoiceError)

index :: IndexAuthority -> Integer -> Draws Integer
index authority stop = do
  streams <- get
  (value, streams') <- lift (chooseIndex authority stop streams)
  put streams'
  pure value

identifier :: Text -> Draws Text
identifier namespace = do
  streams <- get
  (value, streams') <- lift (chooseIdentifier namespace streams)
  put streams'
  pure value

run :: Integer -> Draws a -> a
run seed draws = orFail (evalStateT draws (orFail (choiceStreams seed)))

spec :: Spec
spec = describe "choice streams" $ do
  it "reproduces the Python golden scripts draw for draw" $ do
    v <- readJson (dataFile "choice-vectors.json")
    let scripts = memberList "scripts" v
    length scripts `shouldBe` 6
    mapM_
      ( \script -> do
          let seed = case member "seed" script of
                Int s -> s
                other -> error ("bad seed " <> show other)
              step streams = \case
                Array [String "index", String authority, Int stop, expected] -> do
                  (value, streams') <- chooseIndex (authorityOf authority) stop streams
                  pure (if Int value == expected then streams' else error ("index differs at " <> show (seed, authority, stop)))
                Array [String "identifier", String namespace, Null, expected] -> do
                  (value, streams') <- chooseIdentifier namespace streams
                  pure (if String value == expected then streams' else error ("identifier differs at " <> show (seed, namespace)))
                other -> error ("bad vector " <> show other)
          final <- either (fail . show) pure (choiceStreams seed >>= \s -> foldM step s (memberList "draws" script))
          toJson (provenance final) `shouldBeJson` member "provenance" script
      )
      scripts

  it "refuses implicit or malformed inputs with the reference's messages" $ do
    v <- readJson (dataFile "choice-vectors.json")
    let errors = member "errors" v
        streams = orFail (choiceStreams 1729)
        refused :: Text -> Either ChoiceError a -> Expectation
        refused key outcome = either choiceErrorJson (const Null) outcome `shouldBeJson` member key errors
    refused "seed_negative" (choiceStreams (-1))
    refused "seed_too_large" (choiceStreams (2 ^ (53 :: Int)))
    refused "stop_zero" (chooseIndex WorkloadChoice 0 streams)
    refused "stop_too_large" (chooseIndex WorkloadChoice (2 ^ (53 :: Int)) streams)
    refused "namespace_empty" (chooseIdentifier "" streams)
    refused "namespace_space" (chooseIdentifier "bad name" streams)

  it "validates choice provenance exactly as the reference model does" $ do
    v <- readJson (dataFile "choice-vectors.json")
    mapM_
      ( \c -> do
          let outcome = pChoiceProvenance [] (member "value" c)
          case (outcome, member "errors" c) of
            (Right _, Null) -> pure ()
            (Left e, Array expected) ->
              Array [Array (map locJson e.loc), String e.errorType, String e.message] `shouldSatisfy` (`elem` expected)
            (other, expected) -> expectationFailure (show (fmap (const ()) other) <> " vs " <> show expected)
      )
      (memberList "provenance" v)

  it "is repeatable and isolates each authority's stream (test_world)" $ do
    let workload = run 1729 (replicateM 4 (index WorkloadChoice 1000))
    workload `shouldBe` [584, 541, 292, 147]
    run 1729 (identifier "scenario") `shouldBe` "scenario-4a6cb3d68a08da140c56fd1ed8bcbce2"
    let baseline = run 1729 (replicateM 2 (index WorkloadChoice 1000))
        (perturbed, draws) = run 1729 $ do
          first <- index WorkloadChoice 1000
          _ <- replicateM 8 (index FaultChoice 17)
          _ <- identifier "diagnostic"
          _ <- index EventOrderChoice 5
          second <- index WorkloadChoice 1000
          streams <- get
          pure ([first, second], streamsDraws streams)
    perturbed `shouldBe` baseline
    draws `shouldBe` Map.fromList [("event_order", 1), ("fault", 8), ("identifier:diagnostic", 1), ("workload", 2)]
    let expectedIds = run 1729 (replicateM 2 (identifier "scenario"))
        perturbedIds = run 1729 $ do
          first <- identifier "scenario"
          _ <- replicateM 8 (identifier "diagnostic")
          second <- identifier "scenario"
          pure [first, second]
    perturbedIds `shouldBe` expectedIds
  where
    locJson = \case
      LKey k -> String k
      LIndex i -> Int (toInteger i)
