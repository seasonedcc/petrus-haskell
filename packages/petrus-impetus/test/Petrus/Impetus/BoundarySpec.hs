-- | Parity: the seven Impetus rows of @tests/project/test_package_boundaries.py@.
--
-- Upstream checks Python import graphs: what a module loads at import time,
-- and which names a facade re-exports. Here the same boundaries are checked
-- two ways. Facade names are checked by type: a re-exported type has the same
-- 'TypeRep' as the type in its defining module, which is Python's @is@. The
-- layering is checked by walking the @import@ declarations of the library
-- sources of every package, so a Haskell module that imports a forbidden
-- layer fails here even though it would still compile.
--
-- Laziness itself (upstream's "without optional imports" and "does not load")
-- has no Haskell counterpart, since a module loads nothing at import time.
-- Its structural content does: no root @Petrus@ module, no optional driver in
-- the kernel's dependencies, and no forbidden module in the Petrinet layer's
-- import closure.
module Petrus.Impetus.BoundarySpec (spec) where

import Control.Monad (filterM, forM)
import Data.ByteString qualified as ByteString
import Data.Char (isSpace)
import Data.List (isPrefixOf, isSuffixOf, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Proxy (Proxy (..))
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import Data.Typeable (TypeRep, tyConModule, tyConName, typeOf, typeRep, typeRepTyCon)
import Petrus.Impetus.Binding qualified as Binding
import Petrus.Impetus.Instance qualified as Instance
import Petrus.Impetus.Instance.Firing qualified as InstanceFiring
import Petrus.Impetus.Petrinet qualified as Petrinet
import Petrus.TestSupport (repoRoot)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (dropExtension, makeRelative, splitDirectories, takeExtension, (</>))
import Test.Hspec

spec :: Spec
spec = describe "package boundaries (test_package_boundaries.py)" $ do
  -- test_lazy_root_surface_remains_discoverable_without_optional_imports
  it "lazy root surface remains discoverable without optional imports" $ do
    -- The project namespace is empty: no library defines a root @Petrus@
    -- module, so nothing (removed exports included) is reachable through it.
    index <- libraryModules
    Map.lookup "Petrus" index `shouldBe` Nothing
    -- The kernel never pulls in an optional driver: neither PostgreSQL (the
    -- reference's psycopg and history_store.postgres) nor Absurd dispatch.
    depends <- libraryDepends "petrus-impetus"
    depends `shouldSatisfy` elem "petrus-json"
    filter (`elem` optionalDrivers) depends `shouldBe` []

  -- test_implementation_and_maintained_consumers_import_defining_modules_not_project_root
  it "implementation and maintained consumers import defining modules not project root" $ do
    files <- haskellSources
    length files `shouldSatisfy` (> 100)
    rootImports <- fmap concat . forM files $ \file -> do
      imported <- importsOf file
      pure [file | "Petrus" `elem` imported]
    rootImports `shouldBe` []

  -- test_canonical_petrinet_and_binding_facades
  it "canonical petrinet and binding facades" $ do
    map
      definedIn
      [ typeRep (Proxy :: Proxy Petrinet.Binding)
      , typeRep (Proxy :: Proxy Petrinet.Marking)
      , typeRep (Proxy :: Proxy Petrinet.Net)
      , typeRep (Proxy :: Proxy Petrinet.Token)
      , typeRep (Proxy :: Proxy Binding.ActivityHandler)
      , typeRep (Proxy :: Proxy Binding.HandlerResult)
      ]
      `shouldBe` [ ("Petrus.Impetus.Petrinet.Enabledness", "Binding")
                 , ("Petrus.Impetus.Petrinet.Marking", "Marking")
                 , ("Petrus.Impetus.Petrinet.Schema", "Net")
                 , ("Petrus.Impetus.Petrinet.Marking", "Token")
                 , ("Petrus.Impetus.Binding", "ActivityHandler")
                 , ("Petrus.Impetus.Binding", "HandlerResult")
                 ]
    show (typeOf Petrinet.candidates)
      `shouldBe` "Net -> Marking -> Implementations -> Maybe Clock -> Either EnablednessError [Binding]"
    show (typeOf Binding.passthrough) `shouldBe` "Binding -> [Arc] -> Either Text HandlerResult"
  -- The binding.cel half (compile_completion, compile_filter, compile_guard)
  -- is petrus-cel's Petrus.Cel.Binding, exercised by its port of
  -- binding/test_cel.py.

  -- test_canonical_instance_facade_has_no_root_or_deep_compatibility_alias
  it "canonical instance facade has no root or deep compatibility alias" $ do
    typeRep (Proxy :: Proxy Instance.FiringOccurrence) `shouldBe` typeRep (Proxy :: Proxy InstanceFiring.FiringOccurrence)
    typeRep (Proxy :: Proxy Instance.FiringOutcome) `shouldBe` typeRep (Proxy :: Proxy InstanceFiring.FiringOutcome)
    definedIn (typeRep (Proxy :: Proxy Instance.Instance)) `shouldBe` ("Petrus.Impetus.Instance", "Instance")
    -- No NetInstance alias anywhere in a library, and no flat module.
    index <- libraryModules
    aliases <- filterM (fmap (elem "NetInstance" . identifiers) . readSource) (Map.elems index)
    aliases `shouldBe` []
    filter flatImpetus (Map.keys index) `shouldBe` []

  -- test_petrinet_import_does_not_load_forbidden_layers
  it "petrinet import does not load forbidden layers" $ do
    reached <- petrinetClosure
    -- The walk reached the layer and its dependencies (not a vacuous pass).
    reached `shouldSatisfy` Set.isSubsetOf (Set.fromList ["Petrus.Impetus.Petrinet", "Petrus.Impetus.Petrinet.Dot", "Petrus.Impetus.Petrinet.Schema", "Petrus.Json"])
    -- Upstream's forbidden layers: history, instance, binding, the worker.
    filter (\m -> any (`within` m) ["Petrus.Impetus.History", "Petrus.Impetus.HistoryStore", "Petrus.Impetus.Instance", "Petrus.Impetus.Binding", "Petrus.Motus"]) (Set.toList reached)
      `shouldBe` []
    -- The allow-list, which is stricter than upstream: the Petrinet modules
    -- reach only their own layer, lifecycle scopes, two internal helpers,
    -- Activity numbers (a schema timer's duration) and petrus-json.
    filter (\m -> not (any (`within` m) petrinetMayReach)) (Set.toList reached) `shouldBe` []

  -- test_petrinet_owns_binding_and_history_independent_firing
  it "petrinet owns binding and history independent firing" $ do
    show (typeOf Petrinet.beginFiring) `shouldBe` "Marking -> Binding -> Either Text ([BeginEffect],Marking)"
    show (typeOf Petrinet.completeFiring)
      `shouldBe` "Net -> Marking -> NetPath -> [(NetPath,[Token])] -> ([ProducedTokens],Marking)"
    show (typeOf Petrinet.ConsumedTokens) `shouldBe` "NetPath -> [Token] -> BeginEffect"
    show (typeOf Petrinet.ReadTokens) `shouldBe` "NetPath -> [Token] -> BeginEffect"
    show (typeOf Petrinet.ProducedTokens) `shouldBe` "NetPath -> [Token] -> ProducedTokens"
    map definedIn [typeRep (Proxy :: Proxy Petrinet.BeginEffect), typeRep (Proxy :: Proxy Petrinet.ProducedTokens)]
      `shouldBe` [("Petrus.Impetus.Petrinet.Firing", "BeginEffect"), ("Petrus.Impetus.Petrinet.Firing", "ProducedTokens")]
    reached <- petrinetClosure
    filter (\m -> any (`within` m) ["Petrus.Impetus.History", "Petrus.Impetus.HistoryStore", "Petrus.Impetus.Instance"]) (Set.toList reached)
      `shouldBe` []

  -- test_removed_flat_deep_modules_are_not_speculative_shims
  it "removed flat deep modules are not speculative shims" $ do
    index <- libraryModules
    Map.size index `shouldSatisfy` (> 100)
    filter flatImpetus (Map.keys index) `shouldBe` []

optionalDrivers :: [String]
optionalDrivers = ["petrus-postgres", "postgresql-libpq", "petrus-history-postgres", "petrus-motus-absurd"]

-- | The library modules the Petrinet layer may reach, as module prefixes.
petrinetMayReach :: [String]
petrinetMayReach =
  [ "Petrus.Impetus.Petrinet"
  , "Petrus.Impetus.Scope"
  , "Petrus.Impetus.Internal.OMap"
  , "Petrus.Impetus.Internal.Repr"
  , "Petrus.Activity.Number"
  , "Petrus.Json"
  ]

-- | A module, or one under it.
within :: String -> String -> Bool
within prefix m = m == prefix || (prefix <> ".") `isPrefixOf` m

-- | The flat @impetus@ package upstream removed.
flatImpetus :: String -> Bool
flatImpetus = within "Impetus"

definedIn :: TypeRep -> (String, String)
definedIn r = let c = typeRepTyCon r in (tyConModule c, tyConName c)

-- | Every @Petrus.*@ library module the @Petrus.Impetus.Petrinet*@ modules
-- import, transitively, the roots included. An import that resolves to no
-- library source fails, so a parsing slip cannot shrink the closure.
petrinetClosure :: IO (Set String)
petrinetClosure = do
  index <- libraryModules
  let roots = [m | m <- Map.keys index, within "Petrus.Impetus.Petrinet" m]
      go seen [] = pure seen
      go seen (m : rest)
        | m `Set.member` seen = go seen rest
        | otherwise = case Map.lookup m index of
            Nothing -> expectationFailure ("no library source defines " <> m) >> pure seen
            Just file -> do
              imported <- importsOf file
              go (Set.insert m seen) (filter (within "Petrus") imported <> rest)
  length roots `shouldSatisfy` (>= 7)
  go Set.empty roots

-- | Every library module of every package, by module name.
libraryModules :: IO (Map String FilePath)
libraryModules = do
  root <- repoRoot
  packages <- sort <$> listDirectory (root </> "packages")
  entries <- forM packages $ \package -> do
    let cabal = root </> "packages" </> package </> (package <> ".cabal")
    present <- doesFileExist cabal
    if not present
      then pure []
      else do
        text <- readSource cabal
        let dirs = concatMap words (libraryField "hs-source-dirs" text)
        fmap concat . forM dirs $ \dir -> do
          let base = root </> "packages" </> package </> dir
          files <- filesUnder base
          pure [(moduleName base file, file) | file <- files, takeExtension file == ".hs"]
  let collisions = Map.filter ((> 1) . length) (Map.fromListWith (<>) [(m, [f]) | (m, f) <- concat entries])
  collisions `shouldBe` Map.empty
  pure (Map.fromList (concat entries))
  where
    moduleName base file = Text.unpack (Text.intercalate (Text.pack ".") (map Text.pack (splitDirectories (dropExtension (makeRelative base file)))))

-- | The library stanza's @build-depends@ package names.
libraryDepends :: String -> IO [String]
libraryDepends package = do
  root <- repoRoot
  text <- readSource (root </> "packages" </> package </> (package <> ".cabal"))
  pure
    [ takeWhile (`notElem` (" ><=^:" :: String)) name
    | value <- libraryField "build-depends" text
    , entry <- splitOn ',' value
    , name : _ <- [words entry]
    ]

-- | The values of a field in a cabal file's library stanzas (named
-- sublibraries included), continuation lines joined.
libraryField :: String -> String -> [String]
libraryField field text = concat [values body | (header, body) <- stanzas, "library" `isPrefixOf` header]
  where
    stanzas = group (filter (not . ("--" `isPrefixOf`) . dropWhile isSpace) (lines text))
    group [] = []
    group (header : rest) = let (body, more) = span indented rest in (header, body) : group more
    indented l = case l of
      c : _ -> isSpace c
      [] -> True
    values [] = []
    values (l : ls)
      | (field <> ":") `isPrefixOf` dropWhile isSpace l =
          let depth = indentOf l
              (continuation, rest) = span (\x -> all isSpace x || indentOf x > depth) ls
           in unwords (drop (length field + 1) (dropWhile isSpace l) : continuation) : values rest
      | otherwise = values ls
    indentOf = length . takeWhile isSpace

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (chunk, []) -> [chunk]
  (chunk, _ : rest) -> chunk : splitOn c rest

-- | The modules a source file imports (one name per top-level @import@).
importsOf :: FilePath -> IO [String]
importsOf file = do
  text <- readSource file
  pure [name | l <- lines text, "import " `isPrefixOf` l, name <- take 1 (moduleOf (words (drop 7 l)))]
  where
    moduleOf ws = [takeWhile (/= '(') w | w <- ws, w `notElem` ["qualified", "safe", "{-#", "SOURCE", "#-}"], not ("\"" `isPrefixOf` w)]

-- | The identifiers of a source, split on everything but identifier characters.
identifiers :: String -> [String]
identifiers = words . map (\c -> if c `elem` ("_'" :: String) || c `elem` ['a' .. 'z'] || c `elem` ['A' .. 'Z'] || c `elem` ['0' .. '9'] then c else ' ')

-- | Every Haskell source under @packages/@, outside build output.
haskellSources :: IO [FilePath]
haskellSources = do
  root <- repoRoot
  filter (".hs" `isSuffixOf`) <$> filesUnder (root </> "packages")

filesUnder :: FilePath -> IO [FilePath]
filesUnder dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else do
      names <- sort <$> listDirectory dir
      fmap concat . forM [n | n <- names, n `notElem` ["dist-newstyle", "node_modules"], not ("." `isPrefixOf` n)] $ \name -> do
        let path = dir </> name
        isDir <- doesDirectoryExist path
        if isDir then filesUnder path else pure [path]

readSource :: FilePath -> IO String
readSource file = Text.unpack . decodeUtf8With lenientDecode <$> ByteString.readFile file
