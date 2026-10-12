-- | @net_file_schema.json@, the JSON Schema petrus-engine exports from its
-- @FlatNetFile@ model (@petrus-cli gen-json-schema@), read from the pinned
-- submodule, against this package:
--
-- * the models: the properties each model declares are the members
--   'toJsonBytes' writes for a file that sets every field (@to_json@ writes
--   arcs and places in its own order, so order aside); a file
--   without a member loads exactly when the schema does not require it;
--   the enums are 'ArcKind' and 'Interface';
-- * every file of the differential corpus that this package accepts, as it
--   writes the file back, conforms to the schema, but for one disagreement
--   inside the reference: petrus-engine writes a transition's @delay@ as a
--   number of seconds (@FlatNetFile.to_json@, @model_dump_json@), while the
--   schema it exports allows only an ISO 8601 string there. This package
--   writes the reference's bytes, so exactly those violations are expected
--   ('secondsDelays'), and any other fails.
--
-- The validator below implements the JSON Schema keywords the file uses
-- and fails on any other, so a schema that grows a keyword fails here
-- instead of passing unchecked. It types values as Python's @jsonschema@
-- types what @json.loads@ builds: a non-finite float (Python writes
-- @Infinity@ and @NaN@) is a number, and not an integer. "Petrus.EngineFile.LiveSpec" checks that
-- the committed schema is what the pinned generator writes.
module Petrus.EngineFile.SchemaSpec (spec, schemaPath) where

import Control.Monad (forM_, unless)
import Data.ByteString qualified as BS
import Data.Char (isDigit)
import Data.Either (isRight)
import Data.List (sort)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.EngineFile
import Petrus.EngineFile.Corpus (Case (..))
import Petrus.EngineFile.CorpusSpec (corpusPath)
import Petrus.EngineFile.Corpus qualified as Corpus
import Petrus.EngineFile.LiveSpec (repoRoot)
import Petrus.Json.Parse (parseJson, surrogateRefusingLoads)
import Petrus.Json.Value (Json (..), exactEq, lookupMember)
import System.FilePath ((</>))
import Test.Hspec

-- | The schema in the pinned petrus-engine checkout.
schemaPath :: IO FilePath
schemaPath = (</> "upstream" </> "petrus-engine" </> "src" </> "petrus" </> "net_file_schema.json") <$> repoRoot

readJson :: BS.ByteString -> Json
readJson = either error id . parseJson surrogateRefusingLoads

-- Validation -------------------------------------------------------------------

-- | The violations of @value@ against @schema@ (empty when it conforms);
-- @root@ resolves @$ref@s.
violations :: Json -> Json -> Json -> [Text]
violations root = go "$"
  where
    go path schema value = case schema of
      Bool True -> []
      Bool False -> [path <> ": no value is allowed here"]
      Object kws -> concatMap (keyword path kws value) kws
      _ -> [path <> ": not a schema"]

    keyword path kws value (k, arg) = case k of
      "$ref" -> case arg of
        String ref | Just name <- T.stripPrefix "#/$defs/" ref, Just def <- lookupMember "$defs" root >>= lookupMember name -> go path def value
        _ -> [path <> ": unresolvable $ref " <> showJ arg]
      "anyOf" -> case arg of
        Array branches
          | any (null . (\b -> go path b value)) branches -> []
          | otherwise -> [path <> ": matches no anyOf branch: " <> showJ value]
        _ -> bad
      "type" -> case arg of
        String t | hasType t value -> []
        String t -> [path <> ": not " <> t <> ": " <> showJ value]
        _ -> bad
      "enum" -> case arg of
        Array allowed | any (exactEq value) allowed -> []
        Array _ -> [path <> ": not one of " <> showJ arg <> ": " <> showJ value]
        _ -> bad
      "properties" -> case (arg, value) of
        (Object props, Object members) ->
          concat [go (path <> "." <> name) sub v | (name, sub) <- props, Just v <- [lookup name members]]
        (Object _, _) -> []
        _ -> bad
      "required" -> case (arg, value) of
        (Array names, Object members) ->
          [path <> ": missing " <> n | String n <- names, n `notElem` map fst members]
        (Array _, _) -> []
        _ -> bad
      "additionalProperties" -> case value of
        Object members ->
          let declared = maybe [] (\case Object ps -> map fst ps; _ -> []) (lookup "properties" kws)
           in concat [go (path <> "." <> name) arg v | (name, v) <- members, name `notElem` declared]
        _ -> []
      "propertyNames" -> case value of
        Object members -> concat [go (path <> "{key}") arg (String name) | (name, _) <- members]
        _ -> []
      "items" -> case value of
        Array xs ->
          let skip = maybe 0 (\case Array ps -> length ps; _ -> 0) (lookup "prefixItems" kws)
           in concat [go (path <> "[" <> tshow i <> "]") arg x | (i, x) <- drop skip (zip [0 :: Int ..] xs)]
        _ -> []
      "prefixItems" -> case (arg, value) of
        (Array subs, Array xs) -> concat [go (path <> "[" <> tshow i <> "]") sub x | (i, sub, x) <- zip3 [0 :: Int ..] subs xs]
        (Array _, _) -> []
        _ -> bad
      "minItems" -> case (arg, value) of
        (Int n, Array xs) | fromIntegral (length xs) < n -> [path <> ": fewer than " <> tshow n <> " items"]
        (Int _, _) -> []
        _ -> bad
      "maxItems" -> case (arg, value) of
        (Int n, Array xs) | fromIntegral (length xs) > n -> [path <> ": more than " <> tshow n <> " items"]
        (Int _, _) -> []
        _ -> bad
      "format" -> case (arg, value) of
        (String "duration", String s) | isoDuration s -> []
        (String "duration", String s) -> [path <> ": not an ISO 8601 duration: " <> s]
        (String "duration", _) -> []
        _ -> [path <> ": unsupported format " <> showJ arg]
      -- annotations
      _ | k `elem` ["title", "description", "default", "$comment", "$defs"] -> []
      _ -> [path <> ": unsupported keyword " <> k]
      where
        bad = [path <> ": malformed " <> k <> ": " <> showJ arg]

    hasType t v = case (t, v) of
      ("object", Object _) -> True
      ("array", Array _) -> True
      ("string", String _) -> True
      ("integer", Int _) -> True
      ("integer", Float d) -> not (isNaN d || isInfinite d) && d == fromInteger (round d)
      ("number", Int _) -> True
      ("number", Float _) -> True
      ("boolean", Bool _) -> True
      ("null", Null) -> True
      _ -> False

-- | ISO 8601 durations as pydantic writes @timedelta@s:
-- @[-]P[nD][T[nH][nM][n[.n]S]]@, with at least one field.
isoDuration :: Text -> Bool
isoDuration s0 = case T.stripPrefix "P" (fromMaybe s0 (T.stripPrefix "-" s0)) of
  Nothing -> False
  Just body ->
    let (date, time) = T.breakOn "T" body
     in not (T.null body)
          && fields "D" date
          && maybe True (\t -> not (T.null t) && fields "HMS" t) (T.stripPrefix "T" time)
  where
    fields allowed t
      | T.null t = True
      | otherwise =
          let (n, rest) = T.span (\c -> isDigit c || c == '.') t
           in case T.uncons rest of
                Just (u, rest') | not (T.null n), _ : later <- dropWhile (/= u) allowed -> fields later rest'
                _ -> False

showJ :: Json -> Text
showJ = T.pack . show

tshow :: Show a => a -> Text
tshow = T.pack . show

-- The models -------------------------------------------------------------------

-- | A file that sets every field of every model.
fullFile :: Json
fullFile =
  Object
    [ ("fileVersion", String "2")
    , ("net", String "everything")
    , ("arcs", Array [Object [("source", String "p"), ("target", String "t"), ("kind", String "read"), ("weight", Int 2), ("metadata", Object [("a", Int 1)])]])
    , ("places", Object [("p", Object [("initial", Int 1), ("label", String "P"), ("interface", String "input"), ("metadata", Object [("a", Int 1)])])])
    , ( "transitions"
      , Object [("t", Object [("handler", String "h"), ("guard", String "g"), ("label", String "T"), ("metadata", Object [("a", Int 1)]), ("delay", String "PT1.5S")])]
      )
    , ("refs", Object [("sub", Object [("ref", String "other.json")])])
    , ( "viewState"
      , Object
          [ ("arcWaypoints", Object [("p->t", Array [Array [Float 1.5, Int 2]])])
          , ("layout", Object [("p", Array [Int 10, Int 20])])
          , ("zoom", Float 1.5)
          , ("pan", Array [Int 1, Int 2])
          , ("selected", Array [String "p"])
          ]
      )
    ]

-- | Where each model sits in 'fullFile'.
modelPaths :: [(Text, [Text])]
modelPaths =
  [ ("FlatArc", ["arcs", "0"])
  , ("PlaceDef", ["places", "p"])
  , ("TransitionDef", ["transitions", "t"])
  , ("RefEntry", ["refs", "sub"])
  , ("ViewState", ["viewState"])
  ]

at :: [Text] -> Json -> Maybe Json
at [] v = Just v
at (k : ks) v = case v of
  Object ms -> lookup k ms >>= at ks
  Array xs | T.all isDigit k, let i = read (T.unpack k), i < length xs -> at ks (xs !! i)
  _ -> Nothing

-- | Remove the member at a path.
without :: [Text] -> Json -> Json
without path v = case (path, v) of
  ([k], Object ms) -> Object (filter ((/= k) . fst) ms)
  (k : ks, Object ms) -> Object [(n, if n == k then without ks m else m) | (n, m) <- ms]
  (k : ks, Array xs) | T.all isDigit k -> Array [if i == read (T.unpack k) then without ks x else x | (i, x) <- zip [0 :: Int ..] xs]
  _ -> v

keysOf :: Json -> [Text]
keysOf = \case
  Object ms -> map fst ms
  _ -> []

-- | The violations a written file has because its delays are seconds.
secondsDelays :: Json -> [Text]
secondsDelays written = case at ["transitions"] written of
  Just (Object ts) ->
    [ "$.transitions." <> t <> ".delay: matches no anyOf branch: " <> showJ d
    | (t, Object members) <- ts
    , Just d <- [lookup "delay" members]
    , isNumber d
    ]
  _ -> []
  where
    isNumber = \case
      Int _ -> True
      Float _ -> True
      _ -> False

encodeJson :: Json -> BS.ByteString
encodeJson = TE.encodeUtf8 . Corpus.encode

spec :: Spec
spec = describe "net_file_schema.json (petrus-cli gen-json-schema)" $ do
  schema <- runIO (schemaPath >>= fmap readJson . BS.readFile)
  let defs = fromMaybe (Object []) (lookupMember "$defs" schema)
      def name = fromMaybe (error ("no $defs." <> T.unpack name)) (lookupMember name defs)
      properties s = maybe [] keysOf (lookupMember "properties" s)
      required s = case lookupMember "required" s of
        Just (Array ns) -> [n | String n <- ns]
        _ -> []
      models = ("FlatNetFile", [], schema) : [(name, path, def name) | (name, path) <- modelPaths]
      accepts = isRight . fromJson . encodeJson

  it "covers the models this package reads, and only those" $
    keysOf defs `shouldBe` ["ArcKind", "FlatArc", "PlaceDef", "RefEntry", "TransitionDef", "ViewState"]

  it "declares the members this package writes" $ do
    written <- either (fail . show) (pure . readJson) (fromJson (encodeJson fullFile) >>= toJsonBytes defaultIndent defaultMaxInline)
    secondsDelays written `shouldSatisfy` (not . null)
    violations schema schema written `shouldBe` secondsDelays written
    forM_ models $ \(name, path, model) ->
      (name, sort (maybe [] keysOf (at path written))) `shouldBe` (name, sort (properties model))

  it "requires exactly the members a file cannot do without" $ do
    accepts fullFile `shouldBe` True
    forM_ models $ \(name, path, model) -> forM_ (properties model) $ \member ->
      (name, member, accepts (without (path ++ [member]) fullFile)) `shouldBe` (name, member, member `notElem` required model)

  it "enumerates the arc kinds and place interfaces this package knows" $ do
    lookupMember "enum" (def "ArcKind") `shouldBe` Just (Array (map (String . arcKindText) [minBound .. maxBound]))
    let interfaces = lookupMember "properties" (def "PlaceDef") >>= lookupMember "interface" >>= lookupMember "anyOf"
        enums = case interfaces of
          Just (Array branches) -> mapMaybe (lookupMember "enum") branches
          _ -> []
    enums `shouldBe` [Array (map (String . interfaceText) [minBound .. maxBound])]

  it "is met by every corpus file this package accepts, as written back" $ do
    cases <- corpusPath >>= Corpus.readCorpus
    let inputs = [(c.name <> ":" <> path, bytes) | c <- cases, (path, bytes) <- c.files]
        accepted = [(n, w) | (n, bytes) <- inputs, Right w <- [fromJson bytes >>= toJsonBytes defaultIndent defaultMaxInline]]
    length accepted `shouldSatisfy` (> 500)
    forM_ accepted $ \(n, w) -> do
      let written = readJson w
          problems = violations schema schema written
      unless (problems == secondsDelays written) $
        expectationFailure (T.unpack (n <> ": " <> T.intercalate "; " problems))
