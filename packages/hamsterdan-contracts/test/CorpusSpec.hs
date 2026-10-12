{-# LANGUAGE OverloadedRecordDot #-}

-- | Differential checks against the corpora the pinned Python produced
-- (scripts/gen_corpus.py). Every expectation is byte-exact.
module CorpusSpec (spec, readCorpus, member) where

import Control.Monad (forM_, unless)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Float (castWord64ToDouble)
import Hamsterdan.Contracts.Codec (Contract, DecodeError, Model (..), dump, renderDecodeError, validate)
import Hamsterdan.Contracts.Readiness qualified as Legacy
import Hamsterdan.Contracts.ReadinessProjection
import Hamsterdan.Contracts.ReadinessV5 qualified as V5
import Hamsterdan.PyLiteral
import Petrus.Json (Json (..), compact, dumps, parseJson, pythonJsonLoads, surrogateRefusingLoads)
import Test.Hspec

-- | The rows of a JSONL corpus.
readCorpus :: FilePath -> IO [Json]
readCorpus path = do
  bytes <- BS.readFile ("test/corpus/" <> path)
  traverse row (filter (not . BS.null) (BS8.split '\n' bytes))
  where
    row line = either (fail . ("corpus row: " <>)) pure (parseJson pythonJsonLoads line)

member :: Text -> Json -> Maybe Json
member key = \case
  Object members -> lookup key members
  _ -> Nothing

text :: Text -> Json -> Text
text key value = case member key value of
  Just (String found) -> found
  other -> error ("corpus: missing text " <> show key <> ": " <> show other)

-- Mismatches are collected and the first few reported, so one failing
-- behavior does not drown the report.
expectNone :: [String] -> Expectation
expectNone mismatches = unless (null mismatches) $
  expectationFailure (show (length mismatches) <> " mismatches, first:\n" <> unlines (take 8 mismatches))

spec :: Spec
spec = describe "differential corpora" $ do
  contractsSpec
  projectionSpec
  reprSpec
  literalEvalSpec

-- * Contracts

allModels :: Map.Map Text Model
allModels = Map.fromList [(m.modelName, m) | m <- V5.models <> Legacy.models]

roundTrip :: Model -> BS.ByteString -> Either Text Json
roundTrip model input = case parseJson surrogateRefusingLoads input of
  Left problem -> Left ("json: " <> T.pack problem)
  Right value -> either (Left . renderDecodeError) Right (model.modelRoundTrip value)

contractsSpec :: Spec
contractsSpec = describe "contracts.jsonl (TypeAdapter validate_json / dump_python)" $ do
  rows <- runIO (readCorpus "contracts.jsonl")
  it "covers every upstream dataclass exactly once per name" $ do
    Map.size allModels `shouldBe` 159
    length V5.models `shouldBe` 116
    length Legacy.models `shouldBe` 43
    Map.keysSet allModels `shouldBe` Map.keysSet (Map.fromList [(text "model" r, ()) | r <- rows])
  let grouped = Map.fromListWith (flip (<>)) [(text "model" r, [r]) | r <- rows]
  forM_ (Map.toList grouped) $ \(name, cases) ->
    it (T.unpack name <> " (" <> show (length cases) <> " cases)") $ do
      model <- maybe (fail ("no Haskell model " <> T.unpack name)) pure (Map.lookup name allModels)
      expectNone (concatMap (check model) cases)
  where
    check model row =
      let input = TE.encodeUtf8 (text "input" row)
          outcome = roundTrip model input
          -- pydantic ignores member order; reversing the members also
          -- moves the input off the positional fast path ('recordWith').
          reordered = case parseJson surrogateRefusingLoads input of
            Right (Object members) -> Just (model.modelRoundTrip (Object (reverse members)))
            _ -> Nothing
       in case (member "ok" row, outcome) of
            (Just (Bool True), Right value) ->
              let expected = TE.encodeUtf8 (text "dump" row)
                  actual = either (const "<unencodable>") id (dumps compact value)
               in [ "dump of " <> show input <> "\n  expected " <> show expected <> "\n  actual   " <> show actual
                  | actual /= expected
                  ]
                    <> [ "reordered " <> show input <> " decoded differently"
                       | Just other <- [reordered]
                       , either (const True) (\v -> dumps compact v /= dumps compact value) other
                       ]
            (Just (Bool True), Left problem) -> ["refused " <> show input <> ": " <> T.unpack problem]
            (Just (Bool False), Right value) -> ["admitted " <> show input <> " as " <> show value]
            (Just (Bool False), Left _) -> []
            _ -> ["malformed corpus row " <> show row]

-- * Readiness projection

projectionSpec :: Spec
projectionSpec = describe "projection.jsonl (project_readiness and friends)" $ do
  rows <- runIO (readCorpus "projection.jsonl")
  it ("projects " <> show (length rows) <> " concern sets byte-identically") $
    expectNone (concatMap check rows)
  where
    check row = case member "tokens" row of
      Just (Array [a, b, c, d, e, f, g, h, i]) ->
        case Concerns <$> v a <*> v b <*> v c <*> v d <*> v e <*> v f <*> v g <*> v h <*> v i of
          Left problem -> ["tokens refused: " <> show problem]
          Right concerns ->
            let snapshot = projectReadiness concerns
                spelled = either (const "") id (dumps compact (encodeSnapshot snapshot))
             in concat
                  [ ["snapshot " <> show spelled <> " /= " <> show (text "snapshot" row) | spelled /= TE.encodeUtf8 (text "snapshot" row)]
                  , ["digest" | dashboardProjectionDigest concerns /= text "digest" row]
                  , ["wait" | workflowWait snapshot /= text "wait" row]
                  , ["gates" | Just (Bool (workflowGatesReady snapshot)) /= member "gates_ready" row]
                  ]
      _ -> ["malformed row"]
    v :: (Contract x) => Json -> Either DecodeError x
    v = validate
    encodeSnapshot :: Legacy.ReadinessSnapshot -> Json
    encodeSnapshot = dump

-- * repr

decodeTagged :: Json -> PyValue
decodeTagged = \case
  Null -> PyNone
  Bool value -> PyBool value
  Int value -> PyInt value
  String value -> PyStr value
  Object [("float", Int bits)] -> PyFloat (castWord64ToDouble (fromInteger bits))
  Object [("list", Array items)] -> PyList (map decodeTagged items)
  Object [("tuple", Array items)] -> PyTuple (map decodeTagged items)
  Object [("dict", Array pairs)] -> PyDict [(decodeTagged k, decodeTagged x) | Array [k, x] <- pairs]
  other -> error ("corpus: bad tagged value " <> show other)

reprSpec :: Spec
reprSpec = describe "repr.jsonl (CPython repr)" $ do
  rows <- runIO (readCorpus "repr.jsonl")
  let values = [r | r <- rows, Just _ <- [member "value" r]]
      entries = [r | r <- rows, Just _ <- [member "entry" r]]
  it ("spells " <> show (length values) <> " values as repr() does") $
    expectNone
      [ "repr " <> show value <> ": expected " <> show expected <> ", got " <> show actual
      | row <- values
      , Just tagged <- [member "value" row]
      , let value = decodeTagged tagged
            expected = text "repr" row
            actual = repr value
      , actual /= expected
      ]
  it ("spells " <> show (length entries) <> " dashboard entries and digests") $
    expectNone (concatMap checkEntry entries)
  where
    checkEntry row = case parseJson surrogateRefusingLoads (TE.encodeUtf8 (text "body" row)) of
      Right (Object body) ->
        let kind = text "kind" row
         in concat
              [ ["entry " <> show (dictEntry kind body) <> " /= " <> show (text "entry" row) | dictEntry kind body /= text "entry" row]
              , ["digest " <> show (sortedItemsDigest kind body) <> " /= " <> show (text "digest" row) | sortedItemsDigest kind body /= text "digest" row]
              ]
      other -> ["bad body " <> show other]

-- * literal_eval

literalEvalSpec :: Spec
literalEvalSpec = describe "literal_eval.jsonl (ast.literal_eval)" $ do
  rows <- runIO (readCorpus "literal_eval.jsonl")
  it ("evaluates " <> show (length rows) <> " sources as ast.literal_eval does") $
    expectNone (concatMap check rows)
  where
    check row =
      let source = text "source" row
          actual = literalEval source
          describeIt expected = "literal_eval " <> show source <> ": expected " <> expected <> ", got " <> show actual
          -- Documented divergence: a well-formed \N{name} escape needs
          -- CPython's Unicode name database, so it is reported Unsupported
          -- whether or not the name exists.
          namedEscape = case actual of
            Left (LiteralError Unsupported message) -> "\\N{" `T.isInfixOf` source && "\\N{" `T.isInfixOf` message
            _ -> False
       in if namedEscape && member "unsupported" row == Nothing && member "error" row /= Just (String "TypeError") then [] else case (member "repr" row, member "error" row, member "unsupported" row) of
            (Just (String expected), _, _) -> case actual of
              Right value | repr value == expected -> []
              _ -> [describeIt (show expected)]
            (_, Just (String "TypeError"), _) -> case actual of
              Left (LiteralError Unhashable _) -> []
              _ -> [describeIt "TypeError"]
            (_, Just (String name), _) -> case actual of
              Left (LiteralError Malformed _) -> []
              _ -> [describeIt (T.unpack name)]
            (_, _, Just (String name)) -> case actual of
              Left (LiteralError Unsupported _) -> []
              _ -> [describeIt ("unsupported " <> T.unpack name)]
            _ -> ["malformed row"]

