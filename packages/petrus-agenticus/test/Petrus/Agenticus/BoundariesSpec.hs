-- | Port of @tests/petrus/agenticus/test_boundaries.py@: executable
-- ownership and dependency boundaries, checked over the Haskell sources and
-- cabal files of every agenticus package.
module Petrus.Agenticus.BoundariesSpec (spec) where

import Control.Monad (filterM, forM, forM_)
import Data.List (isSuffixOf, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (takeExtension, (</>))
import Test.Hspec

-- | The reference's ownership packages, as Haskell namespaces.
ownershipNamespaces :: [FilePath]
ownershipNamespaces = ["Attachment", "Catalog", "Connection", "Effect", "Hands", "Program", "Runtime", "Thread"]

-- | The agenticus packages, relative to this package's root (the working
-- directory of @cabal test@).
agenticusPackages :: [FilePath]
agenticusPackages = ["../petrus-agenticus-core", ".", "../petrus-agenticus-runtime"]

existing :: [FilePath] -> IO [FilePath]
existing = filterM doesDirectoryExist

sourcesUnder :: FilePath -> IO [FilePath]
sourcesUnder root = do
  isDir <- doesDirectoryExist root
  if not isDir
    then pure []
    else do
      entries <- listDirectory root
      concat <$> forM entries (\e -> let path = root </> e in doesDirectoryExist path >>= \d -> if d then sourcesUnder path else pure [path | takeExtension path == ".hs"])

agenticusSources :: IO [FilePath]
agenticusSources = do
  packages <- existing agenticusPackages
  concat <$> mapM (\pkg -> sourcesUnder (pkg </> "src")) packages

importsOf :: FilePath -> IO [Text]
importsOf path = do
  source <- TIO.readFile path
  pure [m | line <- T.lines source, Just rest <- [T.stripPrefix "import " line], m : _ <- [filter (/= "qualified") (T.words rest)]]

cabalFile :: FilePath -> IO Text
cabalFile pkg = do
  entries <- listDirectory pkg
  case [e | e <- entries, ".cabal" `isSuffixOf` e] of
    [file] -> TIO.readFile (pkg </> file)
    other -> fail ("expected one cabal file in " <> pkg <> ", found " <> show other)

-- | The package names a cabal file's @build-depends@ fields mention.
dependencies :: Text -> [Text]
dependencies cabal = go False (T.lines cabal)
  where
    go _ [] = []
    go inside (line : rest)
      | "build-depends:" `T.isInfixOf` line = names (snd (T.breakOnEnd "build-depends:" line)) <> go True rest
      | inside && ("  " `T.isPrefixOf` line) && (", " `T.isPrefixOf` T.stripStart line) = names (T.drop 2 (T.stripStart line)) <> go True rest
      | otherwise = go False rest
    names text = [T.takeWhile (\c -> c /= ' ' && c /= ',') (T.strip piece) | piece <- T.splitOn "," text, not (T.null (T.strip piece))]

spec :: Spec
spec = describe "test_boundaries.py" $ do
  it "test_exact_ownership_packages_have_empty_namespaces" $ do
    packages <- existing agenticusPackages
    forM_ packages $ \pkg -> do
      let root = pkg </> "src" </> "Petrus" </> "Agenticus"
      present <- doesDirectoryExist root
      if not present
        then pure ()
        else do
          entries <- listDirectory root
          directories <- filterM (doesDirectoryExist . (root </>)) entries
          [d | d <- directories, d /= "Internal"] `shouldSatisfy` all (`elem` ownershipNamespaces)
          -- The only top-level module is the shared error model; there is
          -- no namespace facade module for any ownership package.
          [f | f <- entries, takeExtension f == ".hs"] `shouldSatisfy` all (== "Error.hs")
    -- No root facade: there is no @Petrus.Agenticus@ module.
    facades <- filterM doesFileExist [pkg </> "src" </> "Petrus" </> "Agenticus.hs" | pkg <- packages]
    facades `shouldBe` []

  it "test_root_import_has_no_facade_or_optional_provider_side_effects" $ do
    -- Haskell imports have no side effects. What remains is the dependency
    -- graph: core is kernel-free, and no agenticus library depends on a
    -- provider SDK binding.
    core <- dependencies <$> cabalFile "../petrus-agenticus-core"
    -- The parser must see real dependencies, or the checks below are vacuous.
    ("petrus-json" `elem` core) `shouldBe` True
    own <- dependencies <$> cabalFile "."
    ("petrus-engine" `elem` own) `shouldBe` True
    forM_ ["petrus-engine", "petrus-impetus", "petrus-dsl", "petrus-motus", "petrus-execution"] $ \kernel ->
      (kernel `elem` core) `shouldBe` False
    packages <- existing agenticusPackages
    forM_ packages $ \pkg -> do
      deps <- dependencies <$> cabalFile pkg
      [d | d <- deps, any (`T.isInfixOf` T.toLower d) ["anthropic", "openai", "claude", "e2b"]] `shouldBe` []

  it "test_impetus_and_motus_do_not_depend_on_agenticus" $ do
    owners <- existing ["../petrus-impetus", "../petrus-motus", "../petrus-execution", "../petrus-activity", "../petrus-dsl", "../petrus-engine"]
    (length owners >= 4) `shouldBe` True
    forM_ owners $ \pkg -> do
      deps <- dependencies <$> cabalFile pkg
      [d | d <- deps, "petrus-agenticus" `T.isPrefixOf` d] `shouldBe` []
      sources <- sourcesUnder (pkg </> "src")
      forM_ sources $ \path -> do
        imported <- importsOf path
        (path, [m | m <- imported, "Petrus.Agenticus" `T.isPrefixOf` m]) `shouldBe` (path, [])

  it "test_agenticus_does_not_import_private_motus_or_its_own_root_facade" $ do
    sources <- agenticusSources
    (length sources > 5) `shouldBe` True
    forM_ sources $ \path -> do
      imported <- importsOf path
      (path, [m | m <- imported, "Petrus.Motus.Execution.Internal" `T.isPrefixOf` m || m == "Petrus.Agenticus"])
        `shouldBe` (path, [])

  it "test_forbidden_universal_concepts_are_not_defined" $ do
    sources <- agenticusSources
    forM_ sources $ \path -> do
      source <- TIO.readFile path
      let defined =
            [ name
            | line <- T.lines source
            , keyword : name : _ <- [T.words line]
            , keyword `elem` ["data", "newtype", "type", "class"]
            ]
          functions = [T.takeWhile (/= ' ') line | line <- T.lines source, " ::" `T.isInfixOf` line, not (" " `T.isPrefixOf` line)]
      (path, sort [n | n <- defined <> functions, n `elem` ["Agent", "Session", "agent", "session"]]) `shouldBe` (path, [])
