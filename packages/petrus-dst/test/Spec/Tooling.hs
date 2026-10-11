-- | Helpers for the DST tooling specs: the @petrus-dst-world@ executable
-- (the reference's @python -m tests.dst.*@ routes) and JSON edits.
module Spec.Tooling
  ( worldExecutable
  , runWorldCommand
  , Step (..)
  , editAt
  , setMember
  , upstreamPath
  ) where

import Data.ByteString (ByteString)
import Data.List (sortOn)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Json (Json (..))
import System.Directory
import System.Environment (lookupEnv)
import System.Exit (ExitCode)
import System.FilePath ((</>))
import System.Process

-- | The built @petrus-dst-world@: @PETRUS_DST_WORLD@, else the one
-- @cabal test@ puts on @PATH@ (the suite's @build-tool-depends@), else the
-- newest one under the checkout's @dist-newstyle@.
worldExecutable :: IO FilePath
worldExecutable = located >>= makeAbsolute

located :: IO FilePath
located =
  lookupEnv "PETRUS_DST_WORLD" >>= \case
    Just exe -> pure exe
    Nothing -> do
      built <- builtUnder "../../dist-newstyle/build"
      onPath <- findExecutable "petrus-dst-world"
      case (built, onPath) of
        (_, Just exe) -> pure exe
        (exe : _, Nothing) -> pure exe
        ([], Nothing) -> fail "petrus-dst-world is not built; run cabal build petrus-dst:exe:petrus-dst-world"
  where
    target = "x" </> "petrus-dst-world" </> "build" </> "petrus-dst-world" </> "petrus-dst-world"
    builtUnder root = do
      found <- search root (5 :: Int)
      stamped <- mapM (\f -> (,f) <$> getModificationTime f) found
      pure (map snd (sortOn (Down . fst) stamped))
    search dir depth = do
      present <- doesDirectoryExist dir
      if not present || depth < 0
        then pure []
        else do
          let candidate = dir </> target
          hit <- doesFileExist candidate
          if hit
            then pure [candidate]
            else do
              children <- listDirectory dir
              concat <$> mapM (\c -> search (dir </> c) (depth - 1)) [c | c <- children, c `notElem` ["t", "x", "cache", "setup-config"]]

-- | Run @petrus-dst-world ARGS@ from the package directory.
runWorldCommand :: [String] -> IO (ExitCode, ByteString, ByteString)
runWorldCommand arguments = do
  exe <- worldExecutable
  (code, out, err) <- readCreateProcessWithExitCode (proc exe arguments) ""
  pure (code, TE.encodeUtf8 (T.pack out), TE.encodeUtf8 (T.pack err))

-- | One step into a JSON value.
data Step = K Text | I Int

-- | Apply @f@ at a path.
editAt :: [Step] -> (Json -> Json) -> Json -> Json
editAt steps f value = case (steps, value) of
  ([], v) -> f v
  (K k : rest, Object members) -> Object [(k', if k' == k then editAt rest f v else v) | (k', v) <- members]
  (I i : rest, Array items) -> Array [if j == i then editAt rest f v else v | (j, v) <- zip [0 ..] items]
  (_, v) -> error ("cannot edit through " <> show v)

-- | @value.update({key: new})@.
setMember :: Text -> Json -> Json -> Json
setMember key new = \case
  Object members
    | any ((== key) . fst) members -> Object [(k, if k == key then new else v) | (k, v) <- members]
    | otherwise -> Object (members <> [(key, new)])
  other -> error ("not an object: " <> show other)

-- | A path inside the pinned reference checkout.
upstreamPath :: FilePath -> FilePath
upstreamPath relative = "../../upstream/petrus" </> relative
