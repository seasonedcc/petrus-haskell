-- | Readers over this repository's package metadata and module sources, for
-- the ports of the reference's @tests/project/test_package_boundaries.py@.
--
-- A Python import graph becomes a Cabal dependency graph, and an optional
-- extra becomes a package that must be depended on explicitly, so the
-- boundary rows are checked over @.cabal@ files and module headers.
module Petrus.TestSupport.Boundary
  ( packageNames
  , packageFile
  , libraryDepends
  , exposedModules
  , libraryField
  , exportList
  , haskellSources
  , importedModules
  ) where

import Control.Monad (filterM, forM)
import Data.Char (isSpace)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, sort)
import Petrus.TestSupport.Repo (repoRoot)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))

-- | Every package under @packages/@ (a directory holding @<name>.cabal@).
packageNames :: IO [String]
packageNames = do
  root <- repoRoot
  entries <- sort <$> listDirectory (root </> "packages")
  filterM (\p -> doesFileExist (root </> "packages" </> p </> (p <> ".cabal"))) entries

-- | A file of a package, relative to its directory.
packageFile :: String -> FilePath -> IO String
packageFile package relative = do
  root <- repoRoot
  readFile (root </> "packages" </> package </> relative)

-- | The main library stanza's lines (the unnamed @library@, up to the next
-- stanza), with comment lines dropped.
libraryStanza :: String -> IO [String]
libraryStanza package = do
  text <- packageFile package (package <> ".cabal")
  let body = takeWhile (not . isStanza) (drop 1 (dropWhile (not . isMainLibrary) (lines text)))
  pure [l | l <- body, not ("--" `isPrefixOf` dropWhile isSpace l)]
  where
    isMainLibrary l = words l == ["library"]
    isStanza l = case l of
      c : _ -> not (isSpace c)
      [] -> False

-- | One field of a stanza, raw: the text after @field:@ and its
-- continuation lines (indented deeper than the field's own line).
fieldText :: String -> [String] -> String
fieldText name stanza = case dropWhile (not . (key `isInfixOf`)) stanza of
  [] -> ""
  first : rest -> unwords (afterNeedle key first : takeWhile (continues first) rest)
  where
    key = name <> ":"
    indent = length . takeWhile isSpace
    continues first l = not (all isSpace l) && indent l > indent first

-- | One field of a stanza, as its comma- or space-separated words.
field :: String -> [String] -> [String]
field name = words . map (\c -> if c == ',' then ' ' else c) . fieldText name

-- | The library stanza's @build-depends@ package names (version bounds dropped).
libraryDepends :: String -> IO [String]
libraryDepends package = do
  stanza <- libraryStanza package
  let entries = splitDepends (fieldText "build-depends" stanza)
  pure [takeWhile (`notElem` (" ><=^" :: String)) (dropWhile isSpace e) | e <- entries, not (all isSpace e)]
  where
    splitDepends s = case break (== ',') s of
      (e, []) -> [e]
      (e, _ : rest) -> e : splitDepends rest

-- | The library stanza's @exposed-modules@.
exposedModules :: String -> IO [String]
exposedModules package = libraryField package "exposed-modules"

-- | The words of one field of a package's main library stanza.
libraryField :: String -> String -> IO [String]
libraryField package name = field name <$> libraryStanza package

-- | A module's export list: the text between @module X@ and @where@.
exportList :: String -> FilePath -> IO String
exportList package relative = do
  text <- packageFile package relative
  pure (maybe "" (untilNeedle "where") (afterMaybe "\nmodule " text))
  where
    untilNeedle needle s
      | needle `isPrefixOf` s = ""
      | null s = ""
      | otherwise = take 1 s <> untilNeedle needle (drop 1 s)

-- | Every @.hs@ file under a package's directory, as a path relative to the
-- repository root (build output excluded).
haskellSources :: String -> IO [FilePath]
haskellSources package = walk ("packages" </> package)
  where
    walk relative = do
      root <- repoRoot
      entries <- sort <$> listDirectory (root </> relative)
      concat
        <$> forM
          [e | e <- entries, e `notElem` ["dist-newstyle", "node_modules", ".venv"]]
          ( \e -> do
              let path = relative </> e
              isDir <- doesDirectoryExist (root </> path)
              if isDir
                then walk path
                else pure [path | ".hs" `isSuffixOf` e]
          )

-- | The modules a source file (relative to the repository root) imports.
importedModules :: FilePath -> IO [String]
importedModules relative = do
  root <- repoRoot
  text <- readFile (root </> relative)
  pure
    [ takeWhile (\c -> not (isSpace c) && c /= '(') (dropQualified (dropWhile isSpace (drop (length ("import" :: String)) l)))
    | l <- lines text
    , "import " `isPrefixOf` l
    ]
  where
    dropQualified s
      | "qualified " `isPrefixOf` s = dropWhile isSpace (drop (length ("qualified" :: String)) s)
      | "{-# SOURCE #-} " `isPrefixOf` s = dropQualified (drop (length ("{-# SOURCE #-} " :: String)) s)
      | otherwise = s

afterNeedle :: String -> String -> String
afterNeedle needle hay = maybe hay id (afterMaybe needle hay)

-- | The text after the first occurrence of a needle.
afterMaybe :: String -> String -> Maybe String
afterMaybe needle hay
  | needle `isPrefixOf` hay = Just (drop (length needle) hay)
  | null hay = Nothing
  | otherwise = afterMaybe needle (drop 1 hay)
