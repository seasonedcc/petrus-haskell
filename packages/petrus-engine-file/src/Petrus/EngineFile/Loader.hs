-- | @petrus.loader@: reading the mounted source files of a multi-file net
-- ('mountedSources', @NetLoader.mounted_sources@), inlining them into one
-- 'FlatNet' ('resolve', @NetResolver.resolve@), and the executable
-- projection ('toSchema', @FlatNet.to_schema@).
module Petrus.EngineFile.Loader
  ( -- * Sources
    Source (..)
  , readFileNet
  , readDictNet
  , mountedSources
  , mountedDict
  , validateJsonText

    -- * Resolution
  , resolve
  , toSchema
  , sortArcs
  ) where

import Data.ByteString (ByteString)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Functor.Identity (Identity (..))
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.EngineFile.Jiter (errorDescription, parseJson)
import Petrus.EngineFile.PyText (joinPath, parentPath, pathText, purePath, readText)
import Petrus.EngineFile.Types
import Petrus.EngineFile.Validate
import Petrus.EngineFile.Value
import Petrus.Json (pythonDict)
import Petrus.Json.Python.Exception (PythonException, pythonError)
import Petrus.Json.PythonText (pythonStrRepr)

-- | Where the root net and its refs come from.
data Source
  = -- | @NetFileSource(root_filename)@: refs are file names relative to the
    -- root file's directory.
    FileSource Text
  | -- | @NetDictSource(root, deps)@: the root object and the dependency
    -- objects by ref, as @json.loads@ built them.
    DictSource Value [(Text, Value)]
  deriving stock (Show)

-- | @FlatNetFile.from_filename(path)@ (@model_validate_json@ of
-- @Path(path).read_text()@).
readFileNet :: Text -> IO (Either PythonException FlatNetFile)
readFileNet path = do
  text <- readText path
  pure (text >>= validateJsonText)

-- | @model_validate_json@ of a decoded text (UTF-8 bytes).
validateJsonText :: ByteString -> Either PythonException FlatNetFile
validateJsonText bytes = case parseJson bytes of
  Left err ->
    Left
      ( validationError
          JsonMode
          [LineError [] (JsonInvalid (errorDescription bytes err)) (VStr (TE.decodeUtf8 bytes))]
      )
  Right value -> validateFile JsonMode value

-- | @FlatNetFile.from_dict(source)@ (@model_validate@).
readDictNet :: Value -> Either PythonException FlatNetFile
readDictNet = validateFile PythonMode

-- | @NetLoader(source).mounted_sources()@: every mounted file by mount
-- path, the root at the empty path, in visiting order.
mountedSources :: Source -> IO (Either PythonException [(NetPath, FlatNetFile)])
mountedSources source = case source of
  FileSource path ->
    mountedWith
      False
      (readFileNet (pathText (purePath path)))
      (\ref -> readFileNet (pathText (joinPath (parentPath (purePath path)) ref)))
  DictSource root deps -> pure (mountedDict root deps)

-- | 'mountedSources' of a 'DictSource', which reads nothing from disk.
mountedDict :: Value -> [(Text, Value)] -> Either PythonException [(NetPath, FlatNetFile)]
mountedDict root deps = runIdentity (mountedWith True (Identity (readDictNet root)) (Identity . child))
  where
    child ref = case lookup ref (pythonDict deps) of
      Just value | not (isNull value) -> readDictNet value
      _ -> Left (pythonError "ValueError" ("Unknown ref: " <> pythonStrRepr ref))
    isNull = \case
      VNull -> True
      _ -> False

-- | The walk of @mounted_sources@ over a root reader and a ref reader.
mountedWith
  :: Monad m
  => Bool
  -> m (Either PythonException FlatNetFile)
  -> (Text -> m (Either PythonException FlatNetFile))
  -> m (Either PythonException [(NetPath, FlatNetFile)])
mountedWith nanShared readRoot readChild = do
  rootRead <- readRoot
  case rootRead of
    Left e -> pure (Left e)
    Right root -> do
      result <- visit (Map.singleton root.net root) [] root rootPath []
      pure (fmap (\(_, mounted) -> reverse mounted) result)
  where
    catalogSource catalog file = case Map.lookup file.net catalog of
      Just existing
        | pyEqFile nanShared existing file -> Right (catalog, existing)
        | otherwise ->
            Left (pythonError "ValueError" ("Net name " <> pythonStrRepr file.net <> " is declared by multiple sources"))
      Nothing -> Right (Map.insert file.net file catalog, file)
    -- The mounted list is kept reversed.
    visit catalog mounted file prefix ancestors
      | file.net `elem` ancestors =
          pure (Left (pythonError "ValueError" ("Cyclic net reference: " <> T.intercalate " -> " (ancestors ++ [file.net]))))
      | any ((== prefixKey prefix) . prefixKey . fst) mounted =
          pure (Left (pythonError "ValueError" ("Duplicate mount NetPath: " <> T.intercalate "." (prefixKey prefix))))
      | otherwise = children catalog ((prefix, file) : mounted) file.refs
      where
        children cat acc [] = pure (Right (cat, acc))
        children cat acc ((mount, entry) : rest) = do
          childRead <- readChild entry.ref
          case childRead >>= catalogSource cat of
            Left e -> pure (Left e)
            Right (cat', child) -> do
              visited <- visit cat' acc child (appendPath prefix mount) (ancestors ++ [file.net])
              case visited of
                Left e -> pure (Left e)
                Right (cat'', acc') -> children cat'' acc' rest

-- | @NetResolver(loaded).resolve()@ over mounted sources (from
-- 'mountedSources'); the flag says whether NaNs are one shared object.
resolve :: Bool -> [(NetPath, FlatNetFile)] -> Either PythonException FlatNet
resolve nanShared loaded = do
  let rootNet = maybe "" (.net) (lookup' rootPath)
  (places, transitions, arcs) <- go [] [] [] loaded
  sorted <- sortArcs nanShared arcs
  Right
    FlatNet
      { net = rootNet
      , arcs = [FlatArc {source = s, target = t, kind = arc.kind, weight = arc.weight, metadata = arc.metadata} | (s, t, arc) <- sorted]
      , places = orderedDict (map (\(p, v) -> (prefixKey p, (p, v))) places)
      , transitions = orderedDict (map (\(p, v) -> (prefixKey p, (p, v))) transitions)
      , viewStates =
          (orderedDict [(file.net, (file.net, v)) | (_, file) <- loaded, Just v <- [file.viewState]])
      , refOrigins = groupOrigins [(file.net, prefix) | (prefix, file) <- loaded, not (isRoot prefix)]
      }
  where
    lookup' p = lookup (prefixKey p) [(prefixKey k, v) | (k, v) <- loaded]
    isRoot (NetPath segments) = null segments
    go places transitions arcs [] = Right (reverse places, reverse transitions, reverse arcs)
    go places transitions arcs ((prefix, file) : rest) = do
      places' <- foldl (\acc (path, p) -> acc >>= \ps -> (\q -> (q, p) : ps) <$> append prefix path) (Right places) file.places
      transitions' <-
        foldl (\acc (path, t) -> acc >>= \ts -> (\q -> (q, t) : ts) <$> append prefix path) (Right transitions) file.transitions
      arcs' <-
        foldl
          ( \acc arc -> do
              as <- acc
              s <- append prefix arc.source
              t <- append prefix arc.target
              Right ((s, t, arc) : as)
          )
          (Right arcs)
          file.arcs
      go places' transitions' arcs' rest
    append (NetPath a) (NetPath b) = newNetPath (a ++ b)
    groupOrigins pairs =
      [ (net, [p | (n, p) <- pairs, n == net])
      | net <- firstOccurrences (map fst pairs)
      ]
    firstOccurrences = go' mempty
      where
        go' _ [] = []
        go' seen (x : xs)
          | x `elem` seen = go' seen xs
          | otherwise = x : go' (x : seen) xs

-- | A Python dict built by assignments in order: a repeated key keeps its
-- first position and takes the last value.
orderedDict :: Ord k => [(k, v)] -> [v]
orderedDict assignments = [lastValue Map.! k | k <- order]
  where
    lastValue = Map.fromList assignments
    order = firstKeys Map.empty assignments
    firstKeys _ [] = []
    firstKeys seen ((k, _) : rest)
      | Map.member k seen = firstKeys seen rest
      | otherwise = k : firstKeys (Map.insert k () seen) rest

prefixKey :: NetPath -> [Text]
prefixKey (NetPath segments) = [t | SegText t <- segments]

-- | @sorted(arcs, key=lambda a: (a.source, a.target))@. When every segment
-- is a string the order is the plain lexicographic one; otherwise Python's
-- comparisons (which can raise) are replayed in the order CPython's sort
-- makes them, exactly for fewer than 64 arcs (one natural run extended by
-- binary insertion) and with a stable merge sort beyond.
sortArcs :: Bool -> [(NetPath, NetPath, a)] -> Either PythonException [(NetPath, NetPath, a)]
sortArcs nanShared arcs
  | all (\(s, t, _) -> allText s && allText t) arcs =
      Right (sortOn (\(s, t, _) -> (prefixKey s, prefixKey t)) arcs)
  | length arcs < 2 = Right arcs
  | length arcs < 64 = timsortSmall lt arcs
  | otherwise = mergeSortBy lt arcs
  where
    lt (s1, t1, _) (s2, t2, _)
      | not (pathEq nanShared s1 s2) = pathLt nanShared s1 s2
      | not (pathEq nanShared t1 t2) = pathLt nanShared t1 t2
      | otherwise = Right False

-- | Tuple @<@ between two paths.
pathLt :: Bool -> NetPath -> NetPath -> Either PythonException Bool
pathLt nanShared (NetPath a) (NetPath b) =
  case [(x, y) | (x, y) <- zip a b, not (segEq x y)] of
    [] -> Right (length a < length b)
    (x, y) : _ -> valueLt nanShared (segmentValue x) (segmentValue y)
  where
    segEq x y = pathEq nanShared (NetPath [x]) (NetPath [y])
    segmentValue = \case
      SegText t -> VStr t
      SegOther v -> v

-- | Python @<@ between two objects @json@ can build.
valueLt :: Bool -> Value -> Value -> Either PythonException Bool
valueLt nanShared a b = case (a, b) of
  (VStr x, VStr y) -> Right (x < y)
  (VList xs, VList ys) -> case [(x, y) | (x, y) <- zip xs ys, not (pyEqWith nanShared x y)] of
    [] -> Right (length xs < length ys)
    (x, y) : _ -> valueLt nanShared x y
  _ -> case (numeric a, numeric b) of
    (Just x, Just y) -> Right (numLt x y)
    _ ->
      Left
        ( pythonError
            "TypeError"
            ("'<' not supported between instances of '" <> pyTypeName a <> "' and '" <> pyTypeName b <> "'")
        )
  where
    numeric = \case
      VBool t -> Just (Left (if t then 1 else 0))
      VInt i _ -> Just (Left i)
      VFloat d -> Just (Right d)
      _ -> Nothing
    numLt (Left x) (Left y) = x < y
    numLt (Right x) (Right y) = x < y
    numLt (Left x) (Right y) = not (isNaN y) && (isInfinite y && y > 0 || not (isInfinite y) && fromInteger x < toRational y)
    numLt (Right x) (Left y) = not (isNaN x) && (isInfinite x && x < 0 || not (isInfinite x) && toRational x < fromInteger y)

-- | CPython's @list.sort@ for fewer than 64 items: @count_run@, then
-- @binarysort@ extending the run to the whole list.
timsortSmall :: (a -> a -> Either e Bool) -> [a] -> Either e [a]
timsortSmall lt items = do
  (run, arranged) <- countRun lt (Seq.fromList items)
  sorted <-
    if run < Seq.length arranged
      then binarySort lt arranged run
      else Right arranged
  Right (foldr (:) [] sorted)

countRun :: (a -> a -> Either e Bool) -> Seq a -> Either e (Int, Seq a)
countRun lt lo0 = ascending 1
  where
    total = Seq.length lo0
    at s i = Seq.index s i
    ascending n
      | n >= total = Right (n, lo0)
      | otherwise = do
          smaller <- lt (at lo0 n) (at lo0 (n - 1))
          if smaller then afterAscending n else ascending (n + 1)
    afterAscending n
      | n > 1 = do
          increased <- lt (at lo0 0) (at lo0 (n - 1))
          if increased then Right (n, lo0) else descending (n + 1) 0 (reverseSlice 0 n lo0)
      | otherwise = descending (n + 1) 0 lo0
    descending n neq lo
      | n >= total = finish n neq lo
      | otherwise = do
          smaller <- lt (at lo n) (at lo (n - 1))
          if smaller
            then descending (n + 1) 0 (reverseLastNeq n neq lo)
            else do
              larger <- lt (at lo (n - 1)) (at lo n)
              if larger then finish n neq lo else descending (n + 1) (neq + 1) lo
    finish n neq lo = suffix n (reverseSlice 0 n (reverseLastNeq n neq lo))
    suffix n lo
      | n >= total = Right (n, lo)
      | otherwise = do
          smaller <- lt (at lo n) (at lo (n - 1))
          if smaller then Right (n, lo) else suffix (n + 1) lo
    reverseLastNeq n neq lo
      | neq == 0 = lo
      | otherwise = reverseSlice (n - (neq + 1)) (neq + 1) lo

-- | Reverse @count@ items starting at @start@.
reverseSlice :: Int -> Int -> Seq a -> Seq a
reverseSlice start count s =
  let (before, rest) = Seq.splitAt start s
      (middle, after) = Seq.splitAt count rest
   in before <> Seq.reverse middle <> after

binarySort :: (a -> a -> Either e Bool) -> Seq a -> Int -> Either e (Seq a)
binarySort lt a0 ok0 = loop (max 1 ok0) a0
  where
    n = Seq.length a0
    loop ok a
      | ok >= n = Right a
      | otherwise = do
          let pivot = Seq.index a ok
          l <- search pivot a 0 ok
          loop (ok + 1) (Seq.insertAt l pivot (Seq.deleteAt ok a))
    search pivot a l r
      | l >= r = Right l
      | otherwise = do
          let m = (l + r) `div` 2
          less <- lt pivot (Seq.index a m)
          if less then search pivot a l m else search pivot a (m + 1) r

-- | A stable merge sort over a comparison that can fail.
mergeSortBy :: (a -> a -> Either e Bool) -> [a] -> Either e [a]
mergeSortBy lt = go
  where
    go xs = case xs of
      [] -> Right []
      [_] -> Right xs
      _ -> do
        let (l, r) = splitAt (length xs `div` 2) xs
        l' <- go l
        r' <- go r
        merge l' r'
    merge [] ys = Right ys
    merge xs [] = Right xs
    merge (x : xs) (y : ys) = do
      yFirst <- lt y x
      if yFirst then (y :) <$> merge (x : xs) ys else (x :) <$> merge xs (y : ys)

-- | @FlatNet.to_schema()@.
toSchema :: FlatNet -> Either PythonException FlatSchema
toSchema flat = do
  let prefix = netPathFromText flat.net
      toPath (NetPath segments) = let NetPath p = prefix in newNetPath (p ++ segments)
  places <- traverse (\(p, v) -> (,v) <$> toPath p) flat.places
  transitions <- traverse (\(p, v) -> (,v) <$> toPath p) flat.transitions
  arcs <-
    traverse
      ( \arc -> do
          s <- toPath arc.source
          t <- toPath arc.target
          hashable s
          hashable t
          Right
            ( (s, t)
            , ArcDef {source = s, target = t, weight = arc.weight, kind = arc.kind, metadata = arc.metadata}
            )
      )
      flat.arcs
  refs <- traverse (\(name, paths) -> (name,) <$> traverse toPath paths) flat.refOrigins
  Right
    FlatSchema
      { name = flat.net
      , places = orderedDict [(prefixKey p, (p, v)) | (p, v) <- places]
      , transitions = orderedDict [(prefixKey p, (p, v)) | (p, v) <- transitions]
      , arcs = orderedDict [((prefixKey s, prefixKey t), ((s, t), d)) | ((s, t), d) <- arcs]
      , refToSubnets = refs
      }
  where
    hashable (NetPath segments) = case [v | SegOther v <- segments] of
      [] -> Right ()
      v : _ ->
        Left (pythonError "TypeError" ("cannot use 'tuple' as a dict key (unhashable type: '" <> pyTypeName v <> "')"))
