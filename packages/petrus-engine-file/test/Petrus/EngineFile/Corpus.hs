-- | The differential corpus (@differential/corpus.json@): reading cases,
-- materializing their files, running their operations through this package,
-- and spelling the results exactly as @differential/reference.py@ does.
module Petrus.EngineFile.Corpus
  ( Case (..)
  , Op (..)
  , readCorpus
  , readCorpusBytes
  , runCase
  , runOp
  , opResultText
  , encode
  ) where

import Control.Monad (forM, forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.EngineFile
import Petrus.EngineFile.Duration (Timedelta (..))
import Petrus.EngineFile.PyText (readText)
import Petrus.Json.Encode (defaultDumps, dumps)
import Petrus.Json.Encode qualified as E
import Petrus.Json.Parse (parseJson, surrogateRefusingLoads)
import Petrus.Json.Python.Exception (pythonExceptionStr)
import Petrus.Json.Value (Json)
import Petrus.Json.Value qualified as J
import System.Directory (createDirectoryIfMissing, withCurrentDirectory)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)

-- | One corpus case.
data Case = Case
  { name :: Text
  , files :: [(Text, ByteString)]
  , dirs :: [Text]
  , ops :: [Op]
  , expect :: [Text]
  -- ^ The reference's results: each one's compact @json.dumps@.
  }

-- | One operation (see @differential/reference.py@).
data Op
  = FileOp Text Int Int
  | FormatOp Text Int Int
  | LoadOp Text
  | DictOp Text [(Text, Maybe Text)]
  deriving stock (Show)

-- | Read @corpus.json@.
readCorpus :: FilePath -> IO [Case]
readCorpus path = BS.readFile path >>= either fail pure . readCorpusBytes

readCorpusBytes :: ByteString -> Either String [Case]
readCorpusBytes bytes = do
  top <- parseJson surrogateRefusingLoads bytes
  cases <- field "cases" top >>= array
  traverse decodeCase cases
  where
    decodeCase c = do
      name <- field "name" c >>= string
      files <- field "files" c >>= object >>= traverse decodeFile
      dirs <- maybe (Right []) (\d -> array d >>= traverse string) (J.lookupMember "dirs" c)
      ops <- field "ops" c >>= array >>= traverse decodeOp
      expect <- maybe (Right []) (\e -> array e >>= traverse string) (J.lookupMember "expect" c)
      Right Case {name, files, dirs, ops, expect}
    decodeFile (path, content) = case (J.lookupMember "text" content, J.lookupMember "base64" content) of
      (Just t, _) -> (path,) . TE.encodeUtf8 <$> string t
      (_, Just b) -> string b >>= \s -> (path,) <$> Base64.decode (TE.encodeUtf8 s)
      _ -> Left "file content without text or base64"
    decodeOp o = do
      kind <- field "op" o >>= string
      case kind of
        "file" -> FileOp <$> (field "path" o >>= string) <*> (field "indent" o >>= int) <*> (field "max_inline" o >>= int)
        "format" -> FormatOp <$> (field "path" o >>= string) <*> (field "indent" o >>= int) <*> (field "max_inline" o >>= int)
        "load" -> LoadOp <$> (field "path" o >>= string)
        "dict" -> do
          root <- field "root" o >>= string
          deps <- field "deps" o >>= object
          DictOp root <$> traverse (\(k, v) -> (k,) <$> nullable string v) deps
        other -> Left ("unknown op " <> T.unpack other)
    field k o = maybe (Left ("missing " <> T.unpack k)) Right (J.lookupMember k o)
    array = \case
      J.Array xs -> Right xs
      _ -> Left "expected an array"
    object = \case
      J.Object ms -> Right ms
      _ -> Left "expected an object"
    string = \case
      J.String s -> Right s
      _ -> Left "expected a string"
    int = \case
      J.Int i -> Right (fromInteger i)
      _ -> Left "expected an integer"
    nullable f = \case
      J.Null -> Right Nothing
      v -> Just <$> f v

-- | Materialize a case's files in a fresh directory and run its operations
-- there; one result text per operation.
runCase :: Case -> IO [Text]
runCase c = withSystemTempDirectory "petrus-engine-file" $ \dir -> do
  forM_ c.dirs $ \d -> createDirectoryIfMissing True (dir </> T.unpack d)
  forM_ c.files $ \(path, bytes) -> do
    let target = dir </> T.unpack path
    createDirectoryIfMissing True (takeDirectory target)
    BS.writeFile target bytes
  withCurrentDirectory dir (forM c.ops (fmap encode . runOp))

-- | The result of one operation, as @reference.py@ builds it.
runOp :: Op -> IO Json
runOp = \case
  FileOp path indent maxInline -> do
    file <- fromFilename path
    pure (outcome (file >>= fmap (J.String . TE.decodeLatin1) . toJsonBytes indent maxInline))
  FormatOp path indent maxInline -> do
    text <- readText path
    pure
      ( outcome
          ( text
              >>= reformatContent indent maxInline
              >>= \(changed, formatted) -> Right (J.Array [J.Bool changed, J.String (TE.decodeLatin1 formatted)])
          )
      )
  LoadOp path -> outcome . fmap resolved <$> loadFile path
  DictOp root deps -> do
    rootValue <- readValue root
    depValues <-
      forM deps $ \(ref, source) -> case source of
        Nothing -> pure (Right (ref, VNull))
        Just p -> fmap (ref,) <$> readValue p
    pure (outcome (resolved <$> (sequenceFirst rootValue depValues >>= \(r, ds) -> loadDict r ds)))
  where
    readValue p = (>>= loads) <$> readText p
    sequenceFirst r ds = do
      root <- r
      deps <- sequence ds
      Right (root, deps)

-- | Encode one result as @reference.py@'s @json.dumps(..., separators=(",", ":"))@.
encode :: Json -> Text
encode j = either (error . show) TE.decodeUtf8 (dumps defaultDumps {E.itemSeparator = Just ",", E.keySeparator = ":"} j)

-- | One operation's result text.
opResultText :: Op -> IO Text
opResultText op = encode <$> runOp op

outcome :: Either PythonException Json -> Json
outcome = \case
  Right j -> J.Object [("ok", j)]
  Left e -> J.Object [("error", J.Array [J.String e.name, J.String (pythonExceptionStr e)])]

resolved :: FlatNet -> Json
resolved net = J.Object [("net", netValue net), ("schema", outcome (schemaValue <$> toSchema net))]

netValue :: FlatNet -> Json
netValue net =
  J.Object
    [ ("net", J.String net.net)
    , ("arcs", J.Array [arcValue a.source a.target a.kind a.weight a.metadata | a <- net.arcs])
    , ("places", J.Array (map placeValue net.places))
    , ("transitions", J.Array (map transitionValue net.transitions))
    , ("view_states", J.Array [J.Array [J.String n, viewStateValue v] | (n, v) <- net.viewStates])
    , ("ref_origins", J.Array [J.Array [J.String n, J.Array (map pathValue ps)] | (n, ps) <- net.refOrigins])
    ]

schemaValue :: FlatSchema -> Json
schemaValue s =
  J.Object
    [ ("name", J.String s.name)
    , ("places", J.Array (map placeValue s.places))
    , ("transitions", J.Array (map transitionValue s.transitions))
    , ("arcs", J.Array [arcValue d.source d.target d.kind d.weight d.metadata | (_, d) <- s.arcs])
    , ("ref_to_subnets", J.Array [J.Array [J.String n, J.Array (map pathValue ps)] | (n, ps) <- s.refToSubnets])
    ]

arcValue :: NetPath -> NetPath -> ArcKind -> Integer -> Maybe Metadata -> Json
arcValue s t kind weight metadata =
  J.Array [pathValue s, pathValue t, J.String (arcKindText kind), J.Int weight, metadataValue metadata]

placeValue :: (NetPath, PlaceDef) -> Json
placeValue (p, d) =
  J.Array
    [ pathValue p
    , J.Int d.initial
    , maybe J.Null J.String d.label
    , maybe J.Null (J.String . interfaceText) d.interface
    , metadataValue d.metadata
    ]

transitionValue :: (NetPath, TransitionDef) -> Json
transitionValue (p, d) =
  J.Array
    [ pathValue p
    , maybe J.Null J.String d.handler
    , maybe J.Null J.String d.guard
    , maybe J.Null J.String d.label
    , metadataValue d.metadata
    , maybe J.Null (\td -> J.Array [J.Int td.days, J.Int td.seconds, J.Int td.microseconds]) d.delay
    ]

viewStateValue :: ViewState -> Json
viewStateValue v =
  J.Array
    [ maybe J.Null (\w -> J.Array [J.Array [J.String k, J.Array (map point ps)] | (k, ps) <- w]) v.arcWaypoints
    , J.Array [J.Array [pathValue p, point xy] | (p, xy) <- v.layout]
    , J.Float v.zoom
    , point v.pan
    , J.Array (map pathValue v.selected)
    ]
  where
    point (x, y) = J.Array [J.Float x, J.Float y]

pathValue :: NetPath -> Json
pathValue (NetPath segments) =
  J.Array
    [ case s of
        SegText t -> J.String t
        SegOther v -> valueJson v
    | s <- segments
    ]

metadataValue :: Maybe Metadata -> Json
metadataValue = maybe J.Null (\m -> J.Object [(k, valueJson v) | (k, v) <- m])

valueJson :: Value -> Json
valueJson = \case
  VNull -> J.Null
  VBool b -> J.Bool b
  VInt i _ -> J.Int i
  VFloat d -> J.Float d
  VStr s -> J.String s
  VList xs -> J.Array (map valueJson xs)
  VDict ms -> J.Object [(k, valueJson v) | (k, v) <- ms]
