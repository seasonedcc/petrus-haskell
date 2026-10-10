{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Generated toy scenarios. Differentially: 400 seeded scripts generated
-- and authored by the Python reference (@scripts/generated_stories.py@)
-- give the same refusals, dispositions, artifact bytes, and replay
-- results here. As properties: whatever an authored script
-- does — commands (including checker-violating ones), faults, observations,
-- crashes and restarts, steps, under small random budgets — the World ends
-- with an artifact whose strict encoding round-trips byte for byte and
-- whose replay through a fresh profile reproduces it (@outcome: pass@,
-- same disposition and journal digest). Choice streams stay isolated per
-- authority under arbitrary interleavings.
module Spec.Properties (spec) where

import Control.Monad (forM_, replicateM)
import Control.Monad.State.Strict (StateT, evalStateT, get, lift, put)
import Data.Text qualified as T
import Data.Text (Text)
import Petrus.Json (EncodeError (..), Json (..), dumps)
import Petrus.Testing.Dst
import Petrus.Testing.Dst.Internal.Canonical (canonicalStrict)
import Generated
import Spec.Support
import Test.Hspec
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import Test.QuickCheck hiding (replay)
import Test.QuickCheck.Monadic (monadicIO, monitor, run)

spec :: Spec
spec = describe "properties" $ do
  it "authors 400 Python-generated scripts exactly as the reference does" $ do
    stories <- memberList "stories" <$> readJson (dataFile "generated-stories.json")
    length stories `shouldBe` 400
    forM_ (zip [0 :: Int ..] stories) $ \(index, story) -> do
      let s = scriptOf (member "script" story)
      authored <- authorScript s
      (errors, settling, ended, artifact) <- either (fail . show) pure authored
      let observed =
            Object
              [ ("index", Int (toInteger index))
              , ("errors", Array errors)
              , ("settling", Array settling)
              , ("disposition", maybe Null (String . dispositionText) ended)
              ]
          expected =
            Object
              [ ("index", Int (toInteger index))
              , ("errors", member "errors" story)
              , ("settling", member "settling" story)
              , ("disposition", member "disposition" story)
              ]
      observed `shouldBeJson` expected
      case artifact of
        Left failure -> withoutReport (pyError failure) `shouldBeJson` withoutReport (member "artifact_error" story)
        Right a -> do
          (index, artifactText a) `shouldBe` (index, memberText "artifact" story)
          replayed <- replayFresh s a
          replayJson replayed `shouldBeJson` member "replay" story

  modifyMaxSuccess (const 300) $
    it "every generated toy story yields an artifact that round-trips and replays exactly" $
      property $ \s -> monadicIO $ do
        outcome <- run (authorScript s)
        case outcome of
          Left failure -> pure (counterexample ("World failed: " <> show failure) False)
          Right (_, _, _, Left failure)
            | failureMessage failure == "finish the DST World before producing an artifact" -> do
                -- a World that never ended (budget-starved finish) has no
                -- artifact; that refusal is the reference's too
                monitor (label "unfinished")
                pure (property True)
            | "a failed DST artifact must end with exactly one failure operation" `T.isInfixOf` failureMessage failure -> do
                -- the reference records a second failure operation when a
                -- budget refusal follows the World's end, and then refuses
                -- the artifact; the port reproduces that (the
                -- failure-after-end story, and PARITY.md)
                monitor (label "failure after the end (reference quirk)")
                pure (property True)
            | otherwise -> pure (counterexample (show failure) False)
          Right (_, _, ended, Right artifact) -> do
            monitor (label (maybe "unended" (T.unpack . dispositionText) ended))
            encoded <- either (fail . T.unpack) pure (encodeArtifact artifact)
            let roundTrip = (decodeArtifact encoded >>= \a' -> either (error . T.unpack) Right (encodeArtifact a')) == Right encoded
            replayed <- run (replayFresh s artifact)
            pure $ case replayed of
              Left failure -> counterexample ("replay failed: " <> show failure) False
              Right result ->
                let value = toJson result
                    field k = canonText (member k value)
                 in counterexample (show value) $
                      roundTrip
                        .&&. field "outcome" === canonText (String "pass")
                        .&&. field "disposition" === canonText (String (maybe "" dispositionText ended))
                        .&&. field "journal_digest" === canonText (String (artifactJournalDigest artifact))

  modifyMaxSuccess (const 2000) $
    it "writes canonical bytes exactly as petrus-json's general encoder does" $
      property $ \(Canonical value) ->
        let general = either (Left . errorText) Right (dumps canonicalOptions value)
            errorText = \case
              NonFiniteNumber d -> show d
              other -> show other
         in either (Left . show) Right (canonicalStrict value) === general

  it "keeps each choice authority's stream independent of the others' draws" $
    property $ \(NonNegative seed) (draws :: [Int]) -> do
      let s = seed `mod` (2 ^ (53 :: Int))
          workloadAlone = run' s (replicateM 3 (draw WorkloadChoice))
          interleaved = run' s $ do
            first <- draw WorkloadChoice
            forM_ draws $ \k -> case k `mod` 3 of
              0 -> () <$ draw FaultChoice
              1 -> () <$ draw EventOrderChoice
              _ -> () <$ identifier
            second <- draw WorkloadChoice
            forM_ (reverse draws) $ \_ -> () <$ draw FaultChoice
            third <- draw WorkloadChoice
            pure [first, second, third]
      interleaved === workloadAlone
  where
    run' :: Integer -> StateT ChoiceStreams (Either ChoiceError) a -> a
    run' seed body = either (error . show) id (choiceStreams seed >>= evalStateT body)
    draw authority = do
      streams <- get
      (value, streams') <- lift (chooseIndex authority 1000 streams)
      put streams'
      pure value
    identifier = do
      streams <- get
      (value, streams') <- lift (chooseIdentifier "noise" streams)
      put streams'
      pure value

-- | Arbitrary JSON, weighted toward what the canonical encoder must get
-- right: escapes, control characters, non-ASCII and astral text, key
-- order, extreme numbers, and non-finite floats.
newtype Canonical = Canonical Json
  deriving stock (Show)

instance Arbitrary Canonical where
  arbitrary = Canonical <$> sized json
    where
      json :: Int -> Gen Json
      json n
        | n <= 0 = scalar
        | otherwise =
            frequency
              [ (4, scalar)
              , (1, Array <$> (choose (0, 4) >>= \k -> vectorOf k (json (n `div` 3))))
              , (1, Object <$> (choose (0, 4) >>= \k -> vectorOf k ((,) <$> text <*> json (n `div` 3))))
              ]
      scalar =
        oneof
          [ pure Null
          , Bool <$> arbitrary
          , Int <$> oneof [arbitrary, choose (-(2 ^ (70 :: Int)), 2 ^ (70 :: Int))]
          , Float <$> oneof [arbitrary, elements [0 / 0, 1 / 0, -1 / 0, -0.0, 1e16, 1e-5, 1.5e300]]
          , String <$> text
          ]
      text :: Gen Text
      text =
        T.pack
          <$> listOf
            ( frequency
                [ (6, choose (' ', '~'))
                , (1, elements "\"\\\n\r\t\b\f\0\x1f\x7f")
                , (1, choose ('\x80', '\xffff'))
                , (1, choose ('\x10000', '\x10ffff'))
                ]
            )
