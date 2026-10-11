-- | The container runtime contract (PARITY.md, "Container runtime
-- contract"): @deployment/tests/test_container_contract.py@ ported to this
-- repository's image, plus static checks of its definition (no container
-- runtime is used here; CI builds and runs the image with
-- scripts/container-smoke): the runtime inputs are byte-identical copies
-- of the reference's, the Containerfile keeps every runtime-stage
-- instruction of the reference's except the two that install the
-- application, and the interpreter-path shim answers the deployment
-- tooling's invocations as the reference interpreter does.
module ContainerSpec (spec) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Json (Json (..), parseJson, pythonLoads)
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import Petrus.TestSupport.Repo (repoRoot)
import System.Directory (canonicalizePath, createDirectoryIfMissing, createFileLink, findExecutable, getPermissions, executable)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Process.Typed (nullStream, proc, readProcess, setEnv, setStdin)
import Test.Hspec

-- ---------------------------------------------------------------------------
-- The Containerfile as instructions

-- | Logical instructions (continuation lines joined, comments dropped),
-- grouped by stage: each group starts with its FROM.
stages :: Text -> [[Text]]
stages = group . instructions
  where
    group = \case
      [] -> []
      first : rest -> let (body, more) = break ("FROM " `T.isPrefixOf`) rest in (first : body) : group more

instructions :: Text -> [Text]
instructions = go . filter keep . T.lines
  where
    keep line = not (T.null (T.strip line)) && not ("#" `T.isPrefixOf` T.stripStart line)
    go = \case
      [] -> []
      line : rest
        | "\\" `T.isSuffixOf` line ->
            let (continued, more) = span ("\\" `T.isSuffixOf`) rest
                final = take 1 more
             in T.intercalate "\n" (line : continued <> final) : go (drop 1 more)
        | otherwise -> line : go rest

stageNamed :: Text -> [[Text]] -> [Text]
stageNamed name groups = case [g | g@(from : _) <- groups, (" AS " <> name) `T.isSuffixOf` from] of
  g : _ -> g
  [] -> error ("no stage " <> T.unpack name)

-- | The @&&@-separated commands of a RUN instruction.
commands :: Text -> [Text]
commands = map (T.unwords . T.words . T.replace "\\\n" " ") . T.splitOn "&&" . T.drop 4

-- | The packages an @apt-get install@ command installs.
aptPackages :: Text -> Set.Set Text
aptPackages command = Set.fromList [w | w <- drop 1 (dropWhile (/= "install") (T.words command)), not ("-" `T.isPrefixOf` w)]

readText :: FilePath -> IO Text
readText path = TE.decodeUtf8 <$> BS.readFile path

-- ---------------------------------------------------------------------------
-- The shim

-- | An image-shaped directory: the shim at the reference interpreter path,
-- the given binaries in @/opt/hamsterdan/bin@.
withImageLayout :: [(String, FilePath)] -> (FilePath -> IO a) -> IO a
withImageLayout binaries action = do
  root <- repoRoot
  withSystemTempDirectory "operator-container" \temporary -> do
    directory <- canonicalizePath temporary
    let venv = directory </> "opt" </> "hamsterdan" </> ".venv" </> "bin" -- lint-skips: allow the image's own interpreter path, which the shim occupies
        shim = venv </> "python"
    createDirectoryIfMissing True venv
    createDirectoryIfMissing True (directory </> "opt" </> "hamsterdan" </> "bin")
    BS.readFile (root </> "deployment" </> "python-shim") >>= BS.writeFile shim
    setFileMode shim 0o755
    forM_ binaries \(name, target) -> createFileLink target (directory </> "opt" </> "hamsterdan" </> "bin" </> name)
    action shim

data Run = Run {code :: Int, out :: Text, err :: Text}
  deriving stock (Eq, Show)

run :: FilePath -> [String] -> IO Run
run program arguments = do
  (status, o, e) <- readProcess (setStdin nullStream (setEnv [("COLUMNS", "80"), ("PATH", "/usr/bin:/bin")] (proc program arguments)))
  pure
    Run
      { code = case status of
          ExitSuccess -> 0
          ExitFailure n -> n
      , out = TE.decodeUtf8 (BL.toStrict o)
      , err = lastLine (TE.decodeUtf8 (BL.toStrict e))
      }
  where
    lastLine text
      | "Traceback (most recent call last):" `T.isInfixOf` text = case reverse (filter (not . T.null) (T.lines text)) of
          line : _ -> line <> "\n"
          [] -> text
      | otherwise = text

versionProbe :: String
versionProbe = "from importlib.metadata import version; print(version('hamsterdan'))"

assertProbe :: String -> String
assertProbe version = "from importlib.metadata import version; import hamsterdan; assert version('hamsterdan') == '" <> version <> "'"

binary :: String -> IO FilePath
binary name = findExecutable name >>= maybe (fail (name <> " is not on PATH (cabal test puts it there)")) pure

-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "deployment/tests/test_container_contract.py" do
    it "test_build_context_admits_only_declared_image_inputs" do
      root <- repoRoot
      ignore <- T.lines <$> readText (root </> ".dockerignore")
      take 1 ignore `shouldBe` ["**"]
      Set.fromList (drop 1 ignore)
        `shouldBe` Set.fromList
          [ "!deployment/Containerfile"
          , "!cabal.project.freeze"
          , "!deployment/pi/"
          , "!deployment/pi/package-lock.json"
          , "!deployment/pi/package.json"
          , "!deployment/python-shim"
          , "!cabal.project"
          , "!LICENSE"
          , "!NOTICE"
          , "!packages/"
          , "!packages/**"
          , "!scripts/"
          , "!scripts/with-runtime-secrets"
          ]
      -- Every file a COPY takes from the context is admitted.
      containerfile <- readText (root </> "deployment" </> "Containerfile")
      let admitted = [T.drop 1 p | p <- drop 1 ignore, not ("/" `T.isSuffixOf` p)]
          sources =
            concat
              [ init operands
              | instruction <- instructions containerfile
              , Just rest <- [T.stripPrefix "COPY " instruction]
              , let operands = filter (not . ("--" `T.isPrefixOf`)) (T.words rest)
              , not ("--from=" `T.isInfixOf` rest)
              , length operands >= 2
              ]
          admits source = source `elem` admitted || any (\p -> maybe False (\directory -> source == directory || (directory <> "/") `T.isPrefixOf` source) (T.stripSuffix "/**" p)) admitted
      filter (not . admits) sources `shouldBe` []

    it "test_container_build_has_pinned_runtime_without_build_credentials" do
      root <- repoRoot
      containerfile <- readText (root </> "deployment" </> "Containerfile")
      ("# syntax=docker/dockerfile:1.7@sha256:" `T.isPrefixOf` containerfile) `shouldBe` True
      T.count "FROM " containerfile `shouldSatisfy` (>= 2)
      [line | line <- T.lines containerfile, "FROM " `T.isPrefixOf` line, not ("@sha256:" `T.isInfixOf` line)] `shouldBe` []
      forM_ ["--mount=type=secret", "PETRUS_GITHUB_TOKEN", "ARG PETRUS_GITHUB_TOKEN"] \forbidden ->
        (forbidden `T.isInfixOf` containerfile) `shouldBe` False
      -- uv sync --frozen --no-dev: the frozen plan, without test or benchmark components.
      ("COPY cabal.project.freeze ./cabal.project.freeze" `T.isInfixOf` containerfile) `shouldBe` True
      ("cabal build --disable-tests --disable-benchmarks" `T.isInfixOf` containerfile) `shouldBe` True
      ("npm ci" `T.isInfixOf` containerfile) `shouldBe` True
      ("USER hamsterdan" `T.isInfixOf` containerfile) `shouldBe` True
      ("ENTRYPOINT [\"/opt/hamsterdan/.venv/bin/python\", \"-m\", \"hamsterdan.host\"]" `T.isInfixOf` containerfile) `shouldBe` True -- lint-skips: allow the image's ENTRYPOINT text, not an interpreter this test runs

    it "test_public_petrus_revision_is_exact_and_locked: the Haskell dependency plan is frozen" do
      root <- repoRoot
      freeze <- T.lines <$> readText (root </> "cabal.project.freeze")
      filter ("index-state: hackage.haskell.org " `T.isPrefixOf`) freeze `shouldSatisfy` ((== 1) . length)
      let pins = mapMaybe (\line -> T.stripPrefix "any." (T.dropWhile (== ' ') (T.dropWhile (/= ' ') line))) freeze
          names = [T.takeWhile (/= ' ') p | p <- pins]
      -- Petrus and Hamsterdan come from this tree at the image's commit;
      -- every Hackage package of the plan is pinned to one version.
      filter (\n -> any (`T.isPrefixOf` n) ["petrus-", "hamsterdan-"]) names `shouldBe` []
      forM_ ["warp", "wai", "direct-sqlite", "crypton", "typed-process", "text", "bytestring"] \package ->
        (package `elem` names) `shouldBe` True
      filter (\p -> not (" ==" `T.isInfixOf` p)) pins `shouldBe` []

    it "test_pi_runtime_is_locked_to_the_qualified_node_and_agent_versions" do
      root <- repoRoot
      Right package <- parseJson pythonLoads <$> BS.readFile (root </> "deployment" </> "pi" </> "package.json")
      Right lock <- parseJson pythonLoads <$> BS.readFile (root </> "deployment" </> "pi" </> "package-lock.json")
      let at key = \case
            Object members -> maybe Null id (lookup key members)
            _ -> Null
          expected = Object [("@earendil-works/pi-coding-agent", String "0.83.0"), ("node", String "22.19.0")]
      at "dependencies" package `shouldBe` expected
      at "dependencies" (at "" (at "packages" lock)) `shouldBe` at "dependencies" package
      at "version" (at "node_modules/@earendil-works/pi-coding-agent" (at "packages" lock)) `shouldBe` String "0.83.0"
      at "version" (at "node_modules/node" (at "packages" lock)) `shouldBe` String "22.19.0"

  describe "Container runtime contract (Haskell port)" do
    it "copies the reference's runtime inputs byte for byte" do
      root <- repoRoot
      forM_
        [ "scripts/with-runtime-secrets"
        , "deployment/config/installations.toml"
        , "deployment/config/runtime.env"
        , "deployment/pi/package.json"
        , "deployment/pi/package-lock.json"
        ]
        \path -> do
          ours <- BS.readFile (root </> path)
          reference <- BS.readFile (root </> "upstream" </> "hamsterdan" </> path)
          (path, ours == reference) `shouldBe` (path, True)
      launcher <- getPermissions (root </> "scripts" </> "with-runtime-secrets")
      executable launcher `shouldBe` True

    it "keeps the reference's syntax, Pi stage and runtime base image" do
      root <- repoRoot
      ours <- readText (root </> "deployment" </> "Containerfile")
      reference <- readText (root </> "upstream" </> "hamsterdan" </> "deployment" </> "Containerfile")
      take 1 (T.lines ours) `shouldBe` take 1 (T.lines reference)
      stageNamed "pi" (stages ours) `shouldBe` stageNamed "pi" (stages reference)
      take 1 (stageNamed "runtime" (stages ours)) `shouldBe` take 1 (stageNamed "runtime" (stages reference))

    it "keeps every runtime-stage instruction except the two that install the application" do
      root <- repoRoot
      ours <- stageNamed "runtime" . stages <$> readText (root </> "deployment" </> "Containerfile")
      reference <- stageNamed "runtime" . stages <$> readText (root </> "upstream" </> "hamsterdan" </> "deployment" </> "Containerfile")
      let isVenvCopy = ("COPY --from=build" `T.isPrefixOf`)
          isRun = ("RUN " `T.isPrefixOf`)
          kept = filter (\i -> not (isVenvCopy i || isRun i)) reference
      -- Order and text of everything else: labels, user, workdir, Pi,
      -- launcher, environment, port, entrypoint and command.
      filter (`elem` kept) ours `shouldBe` kept
      -- The reference's virtual environment becomes the binaries, the shim
      -- at its interpreter path, and petrus-agenticus-runtime's data files
      -- (the Pi helpers) with the variable that points the binaries at them.
      filter isVenvCopy reference `shouldBe` ["COPY --from=build --chown=hamsterdan:hamsterdan /opt/hamsterdan/.venv ./.venv"] -- lint-skips: allow the reference Containerfile's text, not an interpreter
      filter (\i -> not (i `elem` kept || isRun i)) ours
        `shouldBe` [ "COPY --from=build --chown=hamsterdan:hamsterdan /opt/hamsterdan/bin ./bin"
                   , "COPY --chown=hamsterdan:hamsterdan --chmod=0755 deployment/python-shim ./.venv/bin/python" -- lint-skips: allow the image path the shim is installed at
                   , "COPY --chown=hamsterdan:hamsterdan packages/petrus-agenticus-runtime/data/*.mjs ./share/petrus-agenticus-runtime/data/"
                   , "ENV petrus_agenticus_runtime_datadir=\"/opt/hamsterdan/share/petrus-agenticus-runtime\""
                   ]
      -- That COPY takes exactly the package's declared data files.
      cabal <- readText (root </> "packages" </> "petrus-agenticus-runtime" </> "petrus-agenticus-runtime.cabal")
      [T.strip (T.drop (T.length "data-files:") line) | line <- T.lines cabal, "data-files:" `T.isPrefixOf` line] `shouldBe` ["data/*.mjs"]
      -- One RUN: the reference's commands, with a superset of its packages.
      case (filter isRun reference, filter isRun ours) of
        ([theirs], [mine]) -> do
          let install = any ("apt-get install" `T.isInfixOf`)
              split = span (not . ("apt-get install" `T.isInfixOf`))
              (theirsBefore, theirsRest) = split (commands theirs)
              (mineBefore, mineRest) = split (commands mine)
          install (commands mine) `shouldBe` True
          mineBefore `shouldBe` theirsBefore
          drop 1 mineRest `shouldBe` drop 1 theirsRest
          (aptPackages (head' theirsRest) `Set.isSubsetOf` aptPackages (head' mineRest)) `shouldBe` True
          Set.toList (aptPackages (head' mineRest) Set.\\ aptPackages (head' theirsRest)) `shouldBe` ["libffi8", "libgmp10", "zlib1g"]
        other -> expectationFailure ("expected one RUN in each runtime stage: " <> show other)

    describe "the interpreter-path shim answers as the reference interpreter" do
      it "reports the package version" do
        python <- upstreamPythonExecutable "hamsterdan"
        withImageLayout [] \shim -> do
          reference <- run python ["-c", versionProbe]
          ported <- run shim ["-c", versionProbe]
          ported `shouldBe` reference
          reference.code `shouldBe` 0
      forM_ [("the matching version", "0.1.0", 0), ("another version", "9.9.9", 1)] \(label, version, expected) ->
        it ("asserts " <> label) do
          python <- upstreamPythonExecutable "hamsterdan"
          withImageLayout [] \shim -> do
            reference <- run python ["-c", assertProbe version]
            ported <- run shim ["-c", assertProbe version]
            ported `shouldBe` reference
            reference.code `shouldBe` expected
      it "refuses an unknown module" do
        python <- upstreamPythonExecutable "hamsterdan"
        withImageLayout [] \shim -> do
          reference <- run python ["-m", "hamsterdan.unknown"]
          ported <- run shim ["-m", "hamsterdan.unknown"]
          ported {err = T.replace (T.pack shim) "PYTHON" ported.err}
            `shouldBe` reference {err = T.replace (T.pack python) "PYTHON" reference.err}
      it "refuses any other invocation" do
        withImageLayout [] \shim -> do
          refused <- run shim ["-c", "import os; os.system('id')"]
          refused.code `shouldBe` 2
          refused.out `shouldBe` ""
      forM_
        [ ("hamsterdan.host", "hamsterdan-host")
        , ("hamsterdan.operator", "hamsterdan-operator")
        , ("hamsterdan.host.export", "hamsterdan-export")
        ]
        \(module', name) -> forM_ [["--help"], ["--no-such-option"]] \arguments ->
          it ("runs -m " <> module' <> " " <> unwords arguments <> " as the reference does") do
            python <- upstreamPythonExecutable "hamsterdan"
            port <- binary name
            withImageLayout [(name, port)] \shim -> do
              reference <- run python (["-m", module'] <> arguments)
              ported <- run shim (["-m", module'] <> arguments)
              ported `shouldBe` reference
  where
    head' = \case
      x : _ -> x
      [] -> ""

