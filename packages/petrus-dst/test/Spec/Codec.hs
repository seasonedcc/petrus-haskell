{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The artifact codec against the pinned reference: every committed
-- fixture, a structural mutation corpus, and a raw-bytes corpus for the
-- strict JSON loader (@scripts/codec_vectors.py@), plus the
-- Engine-independent codec tests of @tests/dst/test_world.py@.
module Spec.Codec (spec) where

import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.List (sort)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Json (Json (..))
import Petrus.Testing.Dst
import Petrus.Testing.Dst.Decode (LocPart (..), SchemaError (..))
import Spec.Support
import System.Directory (listDirectory)
import System.FilePath ((</>))
import Test.Hspec

vectors :: IO Json
vectors = readJson (dataFile "codec-vectors.json")

-- | The lone-surrogate inputs CPython admits and this port refuses (see
-- DIVERGENCES.md).
loneSurrogateRefusal :: Text
loneSurrogateRefusal = "invalid strict DST JSON: the payload contains a lone UTF-16 surrogate, which this port cannot represent"

-- | Compare one decode outcome with a Python verdict; 'Nothing' when they
-- agree.
mismatch :: BS.ByteString -> Json -> Maybe Text
mismatch payload expected = case (decodeArtifact payload, expected) of
  (Right artifact, _)
    | Just (String digest) <- lookupKey "encoded" expected ->
        case encodeArtifact artifact of
          Right bytes
            | sha bytes == digest && Int (toInteger (BS.length bytes)) == member "bytes" expected -> Nothing
          other -> Just ("encoding differs: " <> T.pack (show (fmap sha other)))
  (Left (DecodeRefused message), _)
    | Just (String m) <- lookupKey "value_error" expected, m == message -> Nothing
  (Left (DecodeInvalid modelName e), _)
    | Just errors <- lookupKey "validation" expected
    , String modelName == member "title" expected
    , Array items <- errors
    , any (sameError e) items ->
        Nothing
  (outcome, _) -> Just ("observed " <> T.pack (show (either (Left . decodeErrorMessage) (Right . artifactScenarioId) outcome)) <> "; expected " <> canonText expected)
  where
    lookupKey key = \case
      Object members -> lookup key members
      _ -> Nothing
    sameError e = \case
      Array [Array loc, String t, String m] -> t == e.errorType && m == e.message && loc == map locJson e.loc
      _ -> False
    locJson = \case
      LKey k -> String k
      LIndex i -> Int (toInteger i)

sha :: BS.ByteString -> Text
sha bytes = "sha256:" <> T.pack (show (hash bytes :: Digest SHA256))

-- | Apply one recorded mutation to a parsed fixture.
applyMutation :: [Json] -> Text -> Json -> Json -> Json
applyMutation path operation replacement = go path
  where
    go [] value = case (operation, value) of
      ("extra", Object members) -> Object (members ++ [("zz_extra", Bool True)])
      _ -> value
    go [step] value | operation /= "extra" = case (step, value) of
      (String key, Object members)
        | operation == "delete" -> Object [(k, v) | (k, v) <- members, k /= key]
        | otherwise -> Object [(k, if k == key then replacement else v) | (k, v) <- members]
      (Int index, Array items) -> Array [if toInteger i == index then replacement else v | (i, v) <- zip [0 :: Int ..] items]
      _ -> value
    go (step : rest) value = case (step, value) of
      (String key, Object members) -> Object [(k, if k == key then go rest v else v) | (k, v) <- members]
      (Int index, Array items) -> Array [if toInteger i == index then go rest v else v | (i, v) <- zip [0 :: Int ..] items]
      _ -> value

report :: [Text] -> Expectation
report = \case
  [] -> pure ()
  problems -> expectationFailure (T.unpack (T.unlines (take 10 problems) <> "(" <> T.pack (show (length problems)) <> " mismatches)"))

fixturePayload :: FilePath -> IO BS.ByteString
fixturePayload name = BS.readFile (fixturesDir </> name)

spec :: Spec
spec = describe "artifact codec" $ do
  it "decodes every committed fixture exactly as the reference does" $ do
    v <- vectors
    let expected = case member "fixtures" v of
          Object members -> members
          _ -> []
    names <- sort . filter (".json" `T.isSuffixOf`) . map T.pack <$> listDirectory fixturesDir
    map fst expected `shouldBe` names
    problems <- fmap concat . mapM (\(name, verdict) -> do
      payload <- fixturePayload (T.unpack name)
      pure [name <> ": " <> m | Just m <- [mismatch payload verdict]]) $ expected
    report problems

  it "re-encodes the 51 world fixtures byte-identically and refuses the two foreign formats" $ do
    names <- sort . filter (".json" `T.isSuffixOf`) . map T.pack <$> listDirectory fixturesDir
    outcomes <- mapM (\name -> (name,) <$> fmap decodeArtifact (fixturePayload (T.unpack name))) names
    let world = [(n, a) | (n, Right a) <- outcomes]
        refused = [n | (n, Left _) <- outcomes]
    length world `shouldBe` 51
    refused `shouldBe` ["generated-runtime-semantic-coverage-v1.json", "projection-crash-recovery-v1.json"]
    problems <- fmap concat . mapM (\(name, artifact) -> do
      payload <- fixturePayload (T.unpack name)
      pure [name | fmap (<> "\n") (encodeArtifact artifact) /= Right payload]) $ world
    problems `shouldBe` []

  it "agrees with the reference on the structural mutation corpus" $ do
    v <- vectors
    let cases = memberList "mutations" v
    fixtures <- mapM (\name -> (name,) <$> readJson (fixturesDir </> T.unpack name)) (unique (map (memberText "fixture") cases))
    let problems =
          mapMaybe
            ( \c ->
                let base = maybe Null id (lookup (memberText "fixture" c) fixtures)
                    mutated = applyMutation (memberList "path" c) (memberText "operation" c) (member "value" c) base
                 in fmap
                      (\m -> memberText "fixture" c <> " " <> canonText (member "path" c) <> " " <> memberText "operation" c <> " " <> canonText (member "value" c) <> ": " <> m)
                      (mismatch (canon mutated) (member "verdict" c))
            )
            cases
    length cases `shouldSatisfy` (> 5000)
    report problems

  it "agrees with the reference's strict JSON loader on the raw-bytes corpus" $ do
    v <- vectors
    let problems =
          mapMaybe
            ( \c ->
                let payload = either (error . show) id (B16.decode (TE.encodeUtf8 (memberText "hex" c)))
                    expected = member "verdict" c
                    divergent = BS.isInfixOf "\xed\xa0\x80" payload
                 in if divergent
                      then case decodeArtifact payload of
                        Left (DecodeRefused m) | m == loneSurrogateRefusal -> Nothing
                        other -> Just ("lone surrogate: " <> T.pack (show (either (Left . decodeErrorMessage) (Right . artifactScenarioId) other)))
                      else fmap (\m -> memberText "hex" c <> ": " <> m) (mismatch payload expected)
            )
            (memberList "raw" v)
    report problems

  it "refuses unknown, mismatched, or non-strict legacy artifacts" $ do
    value <- readJson (fixturesDir </> "projection-crash-recovery-world-v1.json")
    let mutations =
          [ applyMutation [] "extra" Null value
          , applyMutation [String "api"] "replace" (String "petrus.testing.dst/v2") value
          , applyMutation [String "profile", String "digest"] "replace" (String ("sha256:" <> T.replicate 64 "0")) value
          , applyMutation [String "operations", Int 0, String "position"] "replace" (Int 99) value
          , applyMutation [String "operations", Int 0, String "observation", String "generation"] "replace" (Bool True) value
          , applyMutation [String "budget", String "actions"] "replace" (Bool True) value
          ]
    mapM_ (\m -> decodeArtifact (canon m) `shouldSatisfy` either (const True) (const False)) mutations

  it "refuses duplicate fields and non-finite numbers before validation" $ do
    fmap artifactScenarioId (decodeArtifact "{\"format\":\"petrus-dst-world\",\"format\":\"other\"}")
      `shouldBe` Left (DecodeRefused "invalid strict DST JSON: duplicate JSON field 'format'")
    fmap artifactScenarioId (decodeArtifact "{\"value\":NaN}")
      `shouldBe` Left (DecodeRefused "invalid strict DST JSON: non-finite JSON number NaN")

  it "requires one exact terminal failure in version-2 failure artifacts" $ do
    invariant <- readJson (fixturesDir </> "terminal-checker-failure-world-v2.json")
    let popped = case invariant of
          Object members -> Object [(k, if k == "operations" then dropLast v else v) | (k, v) <- members]
          other -> other
        dropLast = \case
          Array items -> Array (take (length items - 1) items)
          other -> other
    fmap artifactScenarioId (decodeArtifact (canon popped)) `shouldSatisfy` refusedWith "exactly one failure operation"
    budgetFailure <- readJson (fixturesDir </> "action-budget-exhaustion-world-v2.json")
    let accepted = applyMutation [String "operations", Int 1, String "accepted_operations"] "replace" (Int 1) budgetFailure
    fmap artifactScenarioId (decodeArtifact (canon accepted)) `shouldSatisfy` refusedWith "does not identify its accepted operation"

  it "keeps the legacy version-1 artifact byte-exact" $ do
    payload <- fixturePayload "projection-crash-recovery-world-v1.json"
    case decodeArtifact payload of
      Right artifact@(ArtifactV1 a) -> do
        a.scenarioId `shouldBe` "projection-crash-recovery-world-v1"
        fmap (<> "\n") (encodeArtifact artifact) `shouldBe` Right payload
      other -> expectationFailure (show (fmap artifactScenarioId other))
  where
    unique = foldr (\x acc -> if x `elem` acc then acc else x : acc) []
    refusedWith needle = \case
      Left e -> needle `T.isInfixOf` decodeErrorMessage e
      Right _ -> False
