-- | The qualification setup's cleanup removes its private root with
-- @shutil.rmtree@; "Hamsterdan.Operator.Posix.rmtree" is CPython's
-- descriptor-relative walk. Each tree here is built twice, removed once by
-- each side, and both the outcome (removed, @FileNotFoundError@, another
-- @OSError@) and what is left on disk must agree.
module RmtreeSpec (spec) where

import Control.Exception (IOException, try)
import Control.Monad (forM, forM_, when)
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.List (sort)
import Hamsterdan.Operator.Posix qualified as Posix
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import System.Directory (createDirectory, createDirectoryIfMissing, doesDirectoryExist, getPermissions, listDirectory, pathIsSymbolicLink, setOwnerWritable, setPermissions)
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (createSymbolicLink)
import System.Process.Typed (proc, readProcessStdout_)
import Test.Hspec

-- | A tree under a side's directory: @root@ is what gets removed, @outside@
-- is a sibling the tree may link to.
data Scenario = Scenario {name :: String, build :: FilePath -> IO (), unlock :: FilePath -> IO ()}

scenarios :: [Scenario]
scenarios =
  [ plain "nested directories, files and empty directories" \side -> do
      createDirectoryIfMissing True (side </> "root" </> "a" </> "b" </> "c")
      createDirectoryIfMissing True (side </> "root" </> "empty")
      forM_ ["f", "a/g", "a/b/h", "a/b/c/i"] \file -> writeFile (side </> "root" </> file) file
  , plain "a symbolic link inside is removed, never followed" \side -> do
      outside side
      createDirectory (side </> "root")
      createSymbolicLink (side </> "outside") (side </> "root" </> "link")
      createSymbolicLink "missing" (side </> "root" </> "dangling")
  , plain "a top that is a symbolic link is refused" \side -> do
      outside side
      createSymbolicLink (side </> "outside") (side </> "root")
  , plain "a missing top raises FileNotFoundError" \_ -> pure ()
  , plain "a top that is a regular file raises" \side -> writeFile (side </> "root") "file"
  , Scenario
      { name = "an entry that cannot be unlinked stops the walk"
      , build = \side -> do
          createDirectoryIfMissing True (side </> "root" </> "locked")
          writeFile (side </> "root" </> "locked" </> "f") "f"
          writeFile (side </> "root" </> "top") "top"
          lock (side </> "root" </> "locked")
      , unlock = \side -> do
          exists <- doesDirectoryExist (side </> "root" </> "locked")
          when exists $ getPermissions (side </> "root" </> "locked") >>= setPermissions (side </> "root" </> "locked") . setOwnerWritable True
      }
  ]
  where
    plain label construct = Scenario {name = label, build = construct, unlock = \_ -> pure ()}
    outside side = do
      createDirectory (side </> "outside")
      writeFile (side </> "outside" </> "keep") "keep"
    lock path = getPermissions path >>= setPermissions path . setOwnerWritable False

-- | What is left under a side's directory, without following links.
contents :: FilePath -> IO [String]
contents side = sort . concat <$> walk ""
  where
    walk relative = do
      names <- listDirectory (side </> relative)
      forM names \entry -> do
        let path = if null relative then entry else relative </> entry
        link <- pathIsSymbolicLink (side </> path)
        directory <- if link then pure False else doesDirectoryExist (side </> path)
        if directory then ((path <> "/") :) . concat <$> walk path else pure [if link then path <> "@" else path]

haskellOutcome :: FilePath -> IO String
haskellOutcome path =
  try (Posix.rmtree path) >>= \case
    Right () -> pure "removed"
    Left (e :: IOException)
      | isDoesNotExistError e -> pure "FileNotFoundError"
      | otherwise -> pure "OSError"

pythonRmtree :: String
pythonRmtree =
  unlines
    [ "import shutil, sys"
    , "try:"
    , "    shutil.rmtree(sys.argv[1])"
    , "    print('removed')"
    , "except FileNotFoundError:"
    , "    print('FileNotFoundError')"
    , "except OSError:"
    , "    print('OSError')"
    ]

spec :: Spec
spec = describe "shutil.rmtree, as the setup cleanup runs it, against CPython's" do
  forM_ scenarios \scenario -> it scenario.name do
    python <- upstreamPythonExecutable "hamsterdan"
    withSystemTempDirectory "hamsterdan-rmtree" \tmp -> do
      let hs = tmp </> "hs"
          py = tmp </> "py"
      forM_ [hs, py] \side -> createDirectory side >> scenario.build side
      mine <- haskellOutcome (hs </> "root")
      theirs <- BLC.unpack <$> readProcessStdout_ (proc python ["-I", "-B", "-c", pythonRmtree, py </> "root"])
      forM_ [hs, py] scenario.unlock
      left <- contents hs
      expected <- contents py
      (mine, left) `shouldBe` (takeWhile (/= '\n') theirs, expected)
