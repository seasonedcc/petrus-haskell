-- | Shared helpers for the Net-definition and Net-document specs: locating
-- the pinned reference's @spec/@ fixtures, editing JSON values the way the
-- upstream tests mutate dicts, and spelling them the way @json.dumps@ does.
module Petrus.Impetus.WireSupport
  ( specFile
  , readSpec
  , findExisting
  , Step (..)
  , editAt
  , setAt
  , deleteAt
  , getAt
  , pyDumps
  , pyDumpsUnicode
  , writerBytes
  , mustJson
  , richNet
  , richNetNamed
  ) where

import Control.Monad (filterM)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Petrus.Impetus.Petrinet
import Petrus.Impetus.TestSupport (mustNet, np)
import Petrus.Json
import System.Directory (doesPathExist)
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)

-- | The first existing path among the candidates.
findExisting :: [FilePath] -> IO FilePath
findExisting options =
  filterM doesPathExist options >>= \case
    found : _ -> pure found
    [] -> fail ("none of these paths exist: " <> show options)

-- | The reference's @spec/@ directory. @cabal test@ runs with the package
-- directory as working directory; running the binary from the repository
-- root works too.
specDirectory :: FilePath
specDirectory = unsafePerformIO (findExisting ["../../upstream/petrus/spec", "upstream/petrus/spec"])
{-# NOINLINE specDirectory #-}

-- | A path under the reference's @spec/@ directory.
specFile :: FilePath -> FilePath
specFile name = specDirectory </> name

readSpec :: FilePath -> IO ByteString
readSpec = BS.readFile . specFile

-- | One step of a path into a JSON value: a member name or an array index.
data Step = K Text | I Int

-- | Apply a function at a path (the path must exist).
editAt :: [Step] -> (Json -> Json) -> Json -> Json
editAt [] f value = f value
editAt (K key : rest) f (Object members) = Object [(k, if k == key then editAt rest f v else v) | (k, v) <- members]
editAt (I index : rest) f (Array items) = Array [if i == index then editAt rest f v else v | (i, v) <- zip [0 ..] items]
editAt _ _ value = error ("editAt: path does not fit " <> show value)

-- | Python's @value[...][key] = new@: replace a member in place or append it.
setAt :: [Step] -> Text -> Json -> Json -> Json
setAt path key new = editAt path $ \case
  Object members
    | any ((== key) . fst) members -> Object [(k, if k == key then new else v) | (k, v) <- members]
    | otherwise -> Object (members <> [(key, new)])
  other -> error ("setAt: not an object: " <> show other)

-- | Python's @del value[...][key]@.
deleteAt :: [Step] -> Text -> Json -> Json
deleteAt path key = editAt path $ \case
  Object members -> Object (filter ((/= key) . fst) members)
  other -> error ("deleteAt: not an object: " <> show other)

getAt :: [Step] -> Json -> Json
getAt [] value = value
getAt (K key : rest) (Object members) = maybe (error "getAt: missing member") (getAt rest) (lookup key members)
getAt (I index : rest) (Array items) = getAt rest (items !! index)
getAt _ value = error ("getAt: path does not fit " <> show value)

-- | @json.dumps(value).encode()@.
pyDumps :: Json -> ByteString
pyDumps = either (error . show) id . dumps defaultDumps

-- | @json.dumps(value, ensure_ascii=False).encode()@.
pyDumpsUnicode :: Json -> ByteString
pyDumpsUnicode = either (error . show) id . dumps defaultDumps {ensureAscii = False}

-- | @(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\\n").encode()@.
writerBytes :: Json -> ByteString
writerBytes value = either (error . show) id (dumps indented value) <> "\n"

-- | @json.loads(bytes)@ for bytes known to be valid JSON.
mustJson :: ByteString -> Json
mustJson = either error id . parseJson pythonLoads

-- | The upstream tests' feature-complete net: every declaration kind, every
-- arc mode, timers, a completion condition, and a name.
richNet :: Net
richNet = richNetNamed (Just "portable-review")

-- | 'richNet' with another name.
richNetNamed :: Maybe Text -> Net
richNetNamed name' =
  mustNet
    NetSpec
      { places = [coloredPlace pending "Work", coloredPlace context "Context", coloredPlace blocked "Block", coloredPlace done "Done"]
      , transitions =
          [ transition source
          , Transition
              { path = review
              , handler = Just (HandlerAnonymous anonymous)
              , guards = [GuardSymbol "ready", GuardCel (unsafeCel "size(review.pending) > 0"), GuardAnonymous anonymous]
              , timers = [Delay (IntNumber 3), Until (IntNumber 11)]
              }
          ]
      , arcs =
          [ arc source pending
          , Arc {source = pending, target = review, mode = Consume, weight = 1, color = Nothing, filter = Just (FilterCel (unsafeCel "priority >= 1"))}
          , Arc {source = context, target = review, mode = Read, weight = 1, color = Nothing, filter = Just (FilterSymbol "visible")}
          , Arc {source = blocked, target = review, mode = Inhibit, weight = 1, color = Nothing, filter = Nothing}
          , arc review done
          ]
      , completion = Just (CompletionCel (unsafeCel "size(review.done) > 0"))
      , name = name'
      }
  where
    source = np "source"
    pending = np "review.pending"
    context = np "review.context"
    blocked = np "review.blocked"
    done = np "review.done"
    review = np "review.run"
