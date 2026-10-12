-- | The canonical writer: @FlatNetFile.to_json(indent, max_inline)@, which
-- dumps the model (@model_dump(exclude_none=True, exclude_defaults=True)@
-- with the models' custom serializers) and lays it out with
-- @petrus.json_formatter.compact_json@.
module Petrus.EngineFile.Encode
  ( toJson
  , toJsonBytes
  , dumpFile
  , compactJson
  , compactJsonWith
  , pathString
  , flatNetFileKeyOrder
  ) where

import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.List (sortBy)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.EngineFile.Duration (totalSeconds)
import Petrus.EngineFile.Types
import Petrus.Json.Python.Exception (PythonException (..), pythonError)
import Petrus.EngineFile.Value (Value (..), pyTypeName)
import Petrus.Json.Encode (EncodeError, defaultDumps, dumps, encodeErrorMessage)
import Petrus.Json.Value (Json)
import Petrus.Json.Value qualified as J

-- | @FLAT_NET_FILE_KEY_ORDER@.
flatNetFileKeyOrder :: [Text]
flatNetFileKeyOrder = ["fileVersion", "net", "arcs", "places", "transitions", "refs", "viewState"]

-- | @ARC_KEY_ORDER@.
arcKeyOrder :: [Text]
arcKeyOrder = ["source", "target"]

-- | @to_json(indent, max_inline)@ as text (always ASCII).
toJson :: Int -> Int -> FlatNetFile -> Either PythonException Text
toJson indent maxInline file = TE.decodeLatin1 <$> toJsonBytes indent maxInline file

-- | @to_json(indent, max_inline)@ as bytes.
toJsonBytes :: Int -> Int -> FlatNetFile -> Either PythonException ByteString
toJsonBytes indent maxInline file = do
  dumped <- dumpFile file
  compactJson indent maxInline dumped

-- | @str(path)@ as the path's plain serializer runs it.
pathString :: NetPath -> Either PythonException Text
pathString (NetPath segments) = case [(i, v) | (i, SegOther v) <- zip [0 :: Int ..] segments] of
  [] -> Right (T.intercalate "." [t | SegText t <- segments])
  (index, bad) : _ ->
    Left
          ( pythonError
              "PydanticSerializationError"
              ( "Error calling function `str`: TypeError: sequence item "
                  <> T.pack (show index)
                  <> ": expected str instance, "
                  <> pyTypeName bad
                  <> " found"
              )
          )

-- | The dict @to_json@ formats: the model dump with @fileVersion@ and
-- @net@ set.
dumpFile :: FlatNetFile -> Either PythonException Value
dumpFile file = do
  arcsDump <- traverse arc file.arcs
  placesDump <- traverse (keyed place) file.places
  transitionsDump <- traverse (keyed transition) file.transitions
  refsDump <- traverse (keyed (\r -> Right (VDict [("ref", VStr r.ref)]))) file.refs
  viewDump <- traverse viewState file.viewState
  Right
    ( VDict
        ( [("arcs", VList arcsDump) | not (null arcsDump)]
            ++ [("places", VDict placesDump) | not (null placesDump)]
            ++ [("transitions", VDict transitionsDump) | not (null transitionsDump)]
            ++ [("refs", VDict refsDump) | not (null refsDump)]
            ++ [("viewState", v) | Just v <- [viewDump]]
            ++ [("fileVersion", VStr file.fileVersion), ("net", VStr file.net)]
        )
    )
  where
    keyed f (path, x) = (,) <$> pathString path <*> f x
    arc a = do
      s <- pathString a.source
      t <- pathString a.target
      Right
        ( VDict
            ( [("source", VStr s), ("target", VStr t)]
                ++ [("kind", VStr (arcKindText a.kind)) | a.kind /= Normal]
                ++ [("weight", VInt a.weight False) | a.weight /= 1]
                ++ [("metadata", VDict m) | Just m <- [a.metadata]]
            )
        )
    place p =
      Right
        ( VDict
            ( [("initial", VInt p.initial False) | p.initial /= 0]
                ++ [("label", VStr l) | Just l <- [p.label]]
                ++ [("interface", VStr (interfaceText i)) | Just i <- [p.interface]]
                ++ [("metadata", VDict m) | Just m <- [p.metadata]]
            )
        )
    transition t =
      Right
        ( VDict
            ( [("handler", VStr h) | Just h <- [t.handler]]
                ++ [("guard", VStr g) | Just g <- [t.guard]]
                ++ [("label", VStr l) | Just l <- [t.label]]
                ++ [("metadata", VDict m) | Just m <- [t.metadata]]
                ++ [("delay", VFloat (totalSeconds d)) | Just d <- [t.delay]]
            )
        )
    pair (x, y) = VList [VFloat x, VFloat y]
    viewState v = do
      layoutDump <- traverse (\(p, xy) -> (,pair xy) <$> pathString p) v.layout
      selectedDump <- traverse (fmap VStr . pathString) v.selected
      Right
        ( VDict
            ( [("arcWaypoints", VDict [(k, VList (map pair ps)) | (k, ps) <- w]) | Just w <- [v.arcWaypoints]]
                ++ [("layout", VDict layoutDump) | not (null layoutDump)]
                ++ [("zoom", VFloat v.zoom) | v.zoom /= 1]
                ++ [("pan", pair v.pan) | not (fst v.pan == 0 && snd v.pan == 0)]
                ++ [("selected", VList selectedDump) | not (null selectedDump)]
            )
        )

-- | @compact_json(value, indent, max_inline, FLAT_NET_FILE_KEY_ORDER,
-- ARC_KEY_ORDER)@.
compactJson :: Int -> Int -> Value -> Either PythonException ByteString
compactJson indent maxInline = compactJsonWith indent maxInline flatNetFileKeyOrder arcKeyOrder

-- | @compact_json(value, indent, max_inline, key_order, item_key_order)@
-- (an empty order is Python's @None@).
compactJsonWith :: Int -> Int -> [Text] -> [Text] -> Value -> Either PythonException ByteString
compactJsonWith indent maxInline keyOrder itemKeyOrder top = do
  -- @clean@ and @json.dumps@ recurse once per nesting level; under
  -- @python -m petrus.cli.format_json@ a value nested more than
  -- 'recursionDepth' containers deep exhausts Python's recursion limit.
  when (containerDepth top > recursionDepth) $
    Left (pythonError "RecursionError" "maximum recursion depth exceeded")
  body <- format 0 top
  Right (BL.toStrict (B.toLazyByteString (body <> B.char7 '\n')))
  where
    format :: Int -> Value -> Either PythonException B.Builder
    format depth value
      | not (isContainer value) || not (hasNested value) = do
          compact <- encode (toJsonValue (clean value))
          if not (isContainer value) || BS.length compact <= maxInline
            then Right (B.byteString compact)
            else multiline depth value
      | otherwise = multiline depth value
    multiline depth value = do
      let pad = B.string7 (replicate (indent * depth) ' ')
          innerPad = B.string7 (replicate (indent * (depth + 1)) ' ')
      case value of
        VList items -> do
          rendered <- traverse (format (depth + 1)) items
          Right ("[\n" <> joinLines [innerPad <> r | r <- rendered] <> "\n" <> pad <> "]")
        VDict members -> do
          rendered <-
            traverse
              ( \(k, v) -> do
                  key <- encode (J.String k)
                  r <- format (depth + 1) v
                  Right (innerPad <> B.byteString key <> ": " <> r)
              )
              (sortMembers depth members)
          Right ("{\n" <> joinLines rendered <> "\n" <> pad <> "}")
        -- 'format' calls 'multiline' only for containers.
        _ -> error "multiline: not a container"
    joinLines = mconcat . zipWith (\i b -> (if i == (0 :: Int) then mempty else ",\n") <> b) [0 ..]
    sortMembers :: Int -> [(Text, Value)] -> [(Text, Value)]
    sortMembers depth members
      | depth == 0 && not (null keyOrder) = sortBy (comparing (orderKey keyOrder)) members
      | otherwise = sortBy (comparing (orderKey itemKeyOrder)) members
    orderKey order (k, _) = (maybe (length order) id (lookup k (zip order [0 ..])), k)
    -- @clean@: whole floats become ints, dict keys sorted (item order).
    clean = \case
      VFloat d
        | not (isNaN d || isInfinite d) && d == fromInteger (truncate d) -> VInt (truncate d) False
      VDict members -> VDict [(k, clean v) | (k, v) <- sortMembers (-1) members]
      VList items -> VList (map clean items)
      v -> v
    encode :: Json -> Either PythonException ByteString
    encode j = either (Left . encodeFailure) Right (dumps defaultDumps j)

-- | The deepest container nesting (the top value counting as 1) that
-- @compact_json@ formats inside @python -m petrus.cli.format_json@ before
-- @RecursionError@ (1000 frames, less the CLI's own). Measured on CPython
-- 3.14 for lists, objects and mixtures, at every place metadata can sit;
-- see DIVERGENCES.md for callers with other stack depths.
recursionDepth :: Int
recursionDepth = 990

containerDepth :: Value -> Int
containerDepth = \case
  VList items -> 1 + maximum (0 : map containerDepth items)
  VDict members -> 1 + maximum (0 : map (containerDepth . snd) members)
  _ -> 0

encodeFailure :: EncodeError -> PythonException
encodeFailure e = pythonError "ValueError" (T.pack (encodeErrorMessage e))

isContainer :: Value -> Bool
isContainer = \case
  VList _ -> True
  VDict _ -> True
  _ -> False

hasNested :: Value -> Bool
hasNested = \case
  VList items -> any isContainer items
  VDict members -> any (isContainer . snd) members
  _ -> False

toJsonValue :: Value -> Json
toJsonValue = \case
  VNull -> J.Null
  VBool b -> J.Bool b
  VInt i _ -> J.Int i
  VFloat d -> J.Float d
  VStr s -> J.String s
  VList items -> J.Array (map toJsonValue items)
  VDict members -> J.Object [(k, toJsonValue v) | (k, v) <- members]
