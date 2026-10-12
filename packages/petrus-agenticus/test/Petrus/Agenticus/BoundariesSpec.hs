-- | Port of @tests/petrus/agenticus/test_boundaries.py@: executable
-- ownership and dependency boundaries, checked over the Haskell sources and
-- cabal files of every agenticus package. Also the agenticus half of
-- @tests/project/test_package_boundaries.py@'s
-- @test_activity_worker_and_runtime_service_do_not_own_retained_territory_lifecycle@
-- (the Worker half is petrus-motus's).
module Petrus.Agenticus.BoundariesSpec (spec) where

import Control.Monad (filterM, forM, forM_)
import Data.Char (isAlphaNum, isLower)
import Data.List (isSuffixOf, sort)
import Data.Set (Set)
import Data.Set qualified as Set
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
spec = projectBoundariesSpec >> agenticusBoundariesSpec >> validatedValuesSpec

agenticusBoundariesSpec :: Spec
agenticusBoundariesSpec = describe "test_boundaries.py" $ do
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

-- ---------------------------------------------------------------------------
-- tests/project/test_package_boundaries.py, the runtime-service half

-- | The reference forbids these calls inside @_CodexGondolinActivityAdapter@
-- and @_CodexGondolinRuntimeService@ (@_release_to@, @begin_release@,
-- @create@, @destroy@, @export@, @lookup@, @reclaim@, @release@, @retire@,
-- @settle@), as the Haskell operations they are: the Episode attachment's
-- release and settlement, the binding's, the territory custody ledger's,
-- and the Motus provider's lease lifecycle.
forbiddenLifecycle :: Set Text
forbiddenLifecycle =
  Set.fromList
    [ "releaseTo"
    , "beginRelease"
    , "providerCreate"
    , "providerDestroy"
    , "providerExport"
    , "providerLookup"
    , "lookupCustody"
    , "reclaim"
    , "reclaimExactMotusBinding"
    , "release"
    , "retire"
    , "settle"
    , "retrySettlement"
    , "bindingSettle"
    , "bindingRelease"
    ]

-- | The source without comments, string and character literals: what is
-- left is code.
codeOnly :: Text -> Text
codeOnly = T.pack . go 0 . T.unpack
  where
    go :: Int -> String -> String
    go depth = \case
      [] -> []
      '{' : '-' : rest -> go (depth + 1) rest
      '-' : '}' : rest | depth > 0 -> go (depth - 1) rest
      c : rest | depth > 0 -> (if c == '\n' then ('\n' :) else id) (go depth rest)
      '-' : '-' : rest | not (startsOperator rest) -> go depth (dropWhile (/= '\n') rest)
      '"' : rest -> ' ' : go depth (skipString rest)
      '\'' : _ : '\'' : rest -> ' ' : go depth rest
      '\'' : '\\' : rest -> ' ' : go depth (drop 1 (dropWhile (/= '\'') rest))
      c : rest -> c : go depth rest
    startsOperator rest = case rest of
      c : _ -> c `elem` ("!#$%&*+./<=>?@\\^|~:" :: String)
      [] -> False
    skipString = \case
      [] -> []
      '\\' : _ : rest -> skipString rest
      '"' : rest -> rest
      _ : rest -> skipString rest

-- | Every identifier the code names, qualified ones by their last component
-- (@Episode.releaseTo@ is @releaseTo@), record dot fields included.
identifiers :: Text -> [Text]
identifiers code = concatMap components (T.split (not . identifierChar) code)
  where
    identifierChar c = isAlphaNum c || c == '_' || c == '\'' || c == '.'
    components token = [part | part <- T.splitOn "." token, Just (c, _) <- [T.uncons part], isLower c || c == '_']

-- | The module's top-level bindings, each with its code (signature and
-- equations), in source order.
topLevel :: Text -> [(Text, Text)]
topLevel code = go (T.lines code)
  where
    go [] = []
    go (line : rest)
      | Just name <- definedName line =
          let (body, rest') = span continues rest
           in (name, T.unlines (line : body)) : go rest'
      | otherwise = go rest
    -- A binding runs on over blank and indented lines.
    continues line = T.null (T.strip line) || " " `T.isPrefixOf` line
    definedName line = case T.uncons line of
      Just (c, _)
        | isLower c || c == '_'
        , name <- T.takeWhile (\x -> isAlphaNum x || x == '_' || x == '\'') line
        , name `notElem` keywords ->
            Just name
      _ -> Nothing
    keywords = ["module", "import", "data", "newtype", "type", "class", "instance", "deriving", "where", "infixl", "infixr", "infix", "foreign", "pattern"]

-- | The bindings a section of the module reaches through the module's own
-- top-level bindings, and the identifiers they name.
reachedFrom :: [(Text, Text)] -> [Text] -> Set Text
reachedFrom bindings roots = go Set.empty (Set.fromList roots)
  where
    defined = Set.fromList (map fst bindings)
    bodies name = [body | (n, body) <- bindings, n == name]
    go seen frontier
      | Set.null frontier = Set.unions [Set.fromList (identifiers body) | name <- Set.toList seen, body <- bodies name]
      | otherwise =
          let seen' = Set.union seen frontier
              named = Set.fromList [i | name <- Set.toList frontier, body <- bodies name, i <- identifiers body, i `Set.member` defined]
           in go seen' (Set.difference named seen')

-- | The top-level bindings between two section headers of the module (a
-- header is a top-level comment line of its own, not the export list's
-- @-- *@ heading).
sectionBindings :: Text -> Text -> Text -> [Text]
sectionBindings source from to =
  let header title = "\n-- " <> title <> "\n"
      afterFrom = snd (T.breakOn (header from) source)
      section = fst (T.breakOn (header to) afterFrom)
   in if T.null afterFrom then [] else map fst (topLevel (codeOnly section))

-- | What the adapter and the service reach that the reference forbids.
lifecycleCalls :: Text -> (Set Text, Set Text)
lifecycleCalls source =
  let bindings = topLevel (codeOnly source)
      adapter = sectionBindings source "The host-local Activity adapter" "The runtime service"
      service = sectionBindings source "The runtime service" "The Worker-side Activity client"
      named roots = Set.intersection forbiddenLifecycle (reachedFrom bindings roots)
   in (named adapter, named service)

projectBoundariesSpec :: Spec
projectBoundariesSpec = describe "tests/project/test_package_boundaries.py" $
  it "test_activity_worker_and_runtime_service_do_not_own_retained_territory_lifecycle (runtime-service half)" $ do
    let path = "../petrus-agenticus-runtime/src/Petrus/Agenticus/Runtime/CodexGondolin.hs"
    source <- TIO.readFile path
    -- Neither the Codex Gondolin Activity adapter nor the runtime service
    -- (nor any binding of the module they reach) calls a retained-territory
    -- lifecycle operation.
    let adapter = sectionBindings source "The host-local Activity adapter" "The runtime service"
        service = sectionBindings source "The runtime service" "The Worker-side Activity client"
    -- The sections were found, or the check below is vacuous.
    ["runCodexGondolinActivityAdapter"] `shouldSatisfy` all (`elem` adapter)
    ["newCodexGondolinRuntimeService", "execute", "request"] `shouldSatisfy` all (`elem` service)
    lifecycleCalls source `shouldBe` (Set.empty, Set.empty)
    -- The lane's module does not import the territory custody ledger at all.
    imported <- importsOf path
    [m | m <- imported, m == "Petrus.Agenticus.Attachment.Retention"] `shouldBe` []
    -- The check sees a call through a helper, qualified or not, and ignores
    -- comments and strings.
    let planted =
          T.unlines
            [ "module M where"
            , "-- The host-local Activity adapter"
            , "runCodexGondolinActivityAdapter a = helper a -- not settle"
            , "helper a = Episode.releaseTo a \"retire\""
            , "-- The runtime service"
            , "execute s = do"
            , "  x <- providerLookup p \"o\""
            , "  pure x"
            , "-- The Worker-side Activity client"
            , "client = retire"
            ]
    lifecycleCalls planted `shouldBe` (Set.fromList ["releaseTo"], Set.fromList ["providerLookup"])

-- | The export entries of a module that name record fields or class
-- methods: @T (a, b)@, as @(T, [a, b])@. An entry exporting a field lets any
-- importer update a value with record syntax, past the type's validating
-- constructor.
fieldExports :: Text -> [(Text, [Text])]
fieldExports source = go header
  where
    -- The export list: the module header up to @where@, comments dropped.
    header =
      T.unwords
        [ fst (T.breakOn "--" l)
        | l <- takeWhile (not . (" where" `T.isSuffixOf`) . T.stripEnd) (T.lines source)
        ]
    -- An innermost parenthesized group and the word before it.
    go text = case T.breakOn "(" text of
      (_, rest) | T.null rest -> []
      (preceding, rest) ->
        let following = T.drop 1 rest
            (inner, close) = T.break (\c -> c == '(' || c == ')') following
         in if ")" `T.isPrefixOf` close
              then entry preceding inner <> go (T.drop 1 close)
              else go following
    entry preceding inner =
      let owner = case reverse (T.words (T.map (\c -> if c == ',' then ' ' else c) preceding)) of
            w : _ -> w
            [] -> ""
          members = filter (not . T.null) (map T.strip (T.splitOn "," inner))
          named m = isLower (T.head m) || T.head m == '_'
       in [(owner, members) | startsUpper owner, not (null members), all named members]
    startsUpper t = maybe False (\(c, _) -> c >= 'A' && c <= 'Z') (T.uncons t)

-- | Haskell-specific: values that only a validating constructor builds stay
-- that way outside their module. The reference's frozen dataclasses refuse
-- assignment and @dataclasses.replace@ re-runs @__post_init__@; here the
-- types are exported abstractly with read-only fields ('GHC.Records.HasField'),
-- so record-update syntax does not compile (divergences/catalog.md item 4).
validatedValuesSpec :: Spec
validatedValuesSpec = describe "Haskell: validated values" $ do
  it "exports no LoopState field, so loopState {phaseLimit = 0} does not compile and the runner's EpisodeBudget cannot fail" $ do
    source <- TIO.readFile "src/Petrus/Agenticus/Program/AgentNet.hs"
    [(owner, members) | (owner, members) <- fieldExports source, owner == "LoopState"] `shouldBe` []
    -- The check sees a planted field export.
    fieldExports "module M\n  ( LoopState (episodeId, phaseLimit)\n  , mkLoopState\n  , Kind (..)\n  ) where\n"
      `shouldBe` [("LoopState", ["episodeId", "phaseLimit"])]

  it "exports the fields of no agenticus type but outcome records and class methods" $ do
    sources <- agenticusSources
    sources `shouldNotBe` []
    exported <- concat <$> forM sources (\path -> map ((,) path) . fieldExports <$> TIO.readFile path)
    -- Transition outcomes pair an already validated value with a
    -- disposition and have no invariant of their own; the rest are classes.
    let allowed =
          [ "EpisodeCancellation"
          , "EpisodeSettlement"
          , "ThreadCancellation"
          , "ThreadSettlement"
          , "StrEnum"
          , "LifecycleId"
          ]
    [(path, owner) | (path, (owner, _)) <- exported, owner `notElem` allowed] `shouldBe` []
