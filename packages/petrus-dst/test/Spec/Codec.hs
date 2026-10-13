{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The artifact codec against the pinned reference: every committed
-- fixture, a structural mutation corpus, and a raw-bytes corpus for the
-- strict JSON loader (@scripts/codec_vectors.py@), plus the
-- Engine-independent codec tests of @tests/dst/test_world.py@.
module Spec.Codec (spec) where

import Control.Monad (forM_)
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

-- | The refusal of a lone surrogate in an object key, which CPython admits
-- (see DIVERGENCES.md).
surrogateKeyRefusal :: Text
surrogateKeyRefusal = "invalid strict DST JSON: the payload contains a lone UTF-16 surrogate in an object key, which the reference's pydantic re-encoding rewrites"

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
                    -- The corpus's one lone-surrogate key.
                    divergent = BS.isInfixOf "\"record\\ud800types\"" payload
                 in if divergent
                      then case decodeArtifact payload of
                        Left (DecodeRefused m) | m == surrogateKeyRefusal -> Nothing
                        other -> Just ("lone surrogate key: " <> T.pack (show (either (Left . decodeErrorMessage) (Right . artifactScenarioId) other)))
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

  -- The strict loader is petrus-json's CPython layer; the copy this package
  -- carried named a signature-selected codec "utf-16" (CPython names the
  -- endian codec), refused a lone surrogate escape with petrus-json's own
  -- text, compared lone-surrogate keys as U+FFFD (a false duplicate), and
  -- refused surrogate bytes before CPython's scanner could report a
  -- syntax error.
  it "refuses what CPython's strict loader refuses, with its text" $ do
    let refusal = fmap artifactScenarioId . decodeArtifact
    refusal "\xff\xfe{\x00}"
      `shouldBe` Left (DecodeRefused "invalid strict DST JSON: 'utf-16-le' codec can't decode byte 0x7d in position 4: truncated data")
    refusal "{\"a\":\"\xed\xa0\x80\""
      `shouldBe` Left (DecodeRefused "invalid strict DST JSON: Expecting ',' delimiter: line 1 column 9 (char 8)")
    refusal "{\"a\":\"\\ud800\"}" `shouldBe` Left (DecodeRefused "unsupported DST artifact version None")
    refusal "{\"\\ud800\":1,\"\\ud801\":2}" `shouldBe` Left (DecodeRefused surrogateKeyRefusal)

  -- repr() keeps characters Unicode 16.0 assigned (CPython 3.14) and
  -- escapes the space separators: the copy this package carried used GHC's
  -- Unicode 15.1 general categories and escaped U+105C0.
  it "spells refused versions with CPython 3.14's repr" $ do
    fmap artifactScenarioId (decodeArtifact (TE.encodeUtf8 "{\"version\":\"v\x105C0\\u00a0\"}"))
      `shouldBe` Left (DecodeRefused "unsupported DST artifact version 'v\x105C0\\xa0'")

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

  it "agrees with the reference's recursion guard on the nesting corpus" $ do
    v <- vectors
    let cases = memberList "nesting" v
    fixtures <- mapM (\name -> (name,) <$> readJson (fixturesDir </> T.unpack name)) (unique (map (memberText "fixture") cases))
    let problems =
          mapMaybe
            ( \c ->
                let base = maybe Null id (lookup (memberText "fixture" c) fixtures)
                    depth = case member "depth" c of
                      Int d -> fromInteger d
                      other -> error (show other)
                    mutated = applyMutation (memberList "path" c) "replace" (nestedJson (memberText "kind" c) depth) base
                 in fmap
                      (\m -> memberText "fixture" c <> " " <> canonText (member "path" c) <> " " <> memberText "kind" c <> " " <> T.pack (show depth) <> ": " <> m)
                      (mismatch (canon mutated) (member "verdict" c))
            )
            cases
    length cases `shouldSatisfy` (> 100)
    report problems

  it "refuses JSON values nested past pydantic's recursion guard, however deep" $ do
    -- A command payload {"x": [[...]]} of a version-1 artifact: 254 nested
    -- lists inside the object are the most pydantic admits there. From
    -- about 993 levels the reference's own recursive _strict_json raises
    -- RecursionError instead (DIVERGENCES.md); either way it refuses.
    payload <- fixturePayload "projection-crash-recovery-world-v1.json"
    let deep depth =
          let (prefix, suffix) = BS.breakSubstring "\"payload\":{}" payload
           in prefix <> "\"payload\":{\"x\":" <> BS.replicate depth 91 <> BS.replicate depth 93 <> "}" <> BS.drop 12 suffix
    case decodeArtifact (deep 254) of
      Right artifact -> fmap (<> "\n") (encodeArtifact artifact) `shouldBe` Right (deep 254)
      Left e -> expectationFailure (T.unpack (decodeErrorMessage e))
    forM_ [255, 993, 5000] $ \depth -> case decodeArtifact (deep depth) of
      Left (DecodeInvalid "ScenarioArtifactV1" e) -> do
        e.errorType `shouldBe` "recursion_loop"
        e.message `shouldBe` "Recursion error - cyclic reference detected"
        e.loc
          `shouldBe` [LKey "operations", LIndex 1, LKey "execute", LKey "command", LKey "payload", LKey "dict", LKey "x"]
            ++ concat (replicate 254 [LKey "list", LIndex 0])
      other -> expectationFailure (show (fmap artifactScenarioId other))
  where
    nestedJson :: Text -> Int -> Json
    nestedJson kind depth = go 0
      where
        go level
          | level >= depth = Int 0
          | kind == "list" || (kind == "mixed" && even level) = Array [go (level + 1)]
          | otherwise = Object [("k", go (level + 1))]
    unique =foldr (\x acc -> if x `elem` acc then acc else x : acc) []
    refusedWith needle = \case
      Left e -> needle `T.isInfixOf` decodeErrorMessage e
      Right _ -> False
