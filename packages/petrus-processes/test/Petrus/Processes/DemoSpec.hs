-- | The Engine-level lifecycle checks, on the CV5.DS2 demo's nets:
--
-- * P-032 … P-036 and P-075 … P-078 are the demo's own assertions and
--   printed lines; the demo runs here as the Haskell executable, under the
--   reference's orchestrator with Haskell parts, and under the Haskell
--   orchestrator with reference parts (P-038 at Engine level: callers and
--   callees of either implementation; P-079: a parent Engine's
--   @process.spawn@ executed by the other implementation's worker).
-- * P-037 runs against both implementations through the harness.
module Petrus.Processes.DemoSpec (spec, lifecycleLines) where

import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Fabric.Conformance.Haskell (fabricOps)
import Petrus.Fabric.Conformance.Impl
import Petrus.Fabric.Conformance.Setup
import Petrus.Json (Json (..), typeExactEq)
import Petrus.Processes.Conformance.Haskell (processOps)
import Petrus.Processes.Conformance.Lifecycle (lifecycleOps)
import Petrus.TestSupport (PostgresTarget (..), lookupPostgresUrl, pythonExecutable, repoRoot, skipMessage, withScratchDatabase)
import System.Directory (findExecutable)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (proc, readCreateProcessWithExitCode)
import Test.Hspec

haskell :: Launcher
haskell = haskellLauncher (\h -> [fabricOps h, processOps h, lifecycleOps h])

spec :: Spec
spec = describe "CV5.DS2 lifecycle demo: Engine-level checks (spec/processes-conformance.md)" $ do
  describe "Haskell port" (dbGroup haskell engineChecks)
  describe "Python reference" (dbGroup pythonLauncher engineChecks)
  describe "the demo across implementations (P-032..P-038, P-075..P-079)" mixedRuns

shouldBeJson :: Json -> Json -> Expectation
shouldBeJson actual expected =
  if typeExactEq actual expected
    then pure ()
    else expectationFailure ("expected " <> showJson expected <> "\n but got " <> showJson actual)

engineChecks :: SpecWith Ctx
engineChecks =
  it "P-037 a reply on a reply source with no armed registration is refused, stays pending, and blocks the inbox" $ \ctx -> do
    suffix <- T.take 8 . T.filter (`elem` ['a' .. 'z']) . T.toLower . textOf <$> ok ctx.impl "issue_credential" []
    answer <- ok ctx.impl "lifecycle_unarmed_reply" [("dsn", String (T.pack (BC.unpack ctx.target.targetUrl))), ("suffix", String suffix)]
    case member "attempts" answer of
      Array [first, second] -> do
        first `shouldSatisfy` (/= Null)
        second `shouldSatisfy` (/= Null)
      other -> expectationFailure ("attempts: " <> showJson other)
    member "pending" answer `shouldBeJson` Int 1
    member "appended" answer `shouldBeJson` Int 0
    member "status" answer `shouldBeJson` "running"
  where
    textOf = \case
      String s -> s
      _ -> ""

-- | The lines a passing run prints (the reference test's assertions plus
-- the remaining fixed lines).
lifecycleLines :: [Text]
lifecycleLines = map (\(_, _, line) -> line) lineChecks

-- | Each printed line with the check it evidences. The demo asserts each
-- condition before printing its line and exits nonzero otherwise.
lineChecks :: [(String, String, Text)]
lineChecks =
  [ ("P-077", "a lost spawn completion re-dispatches: 1 claim, 2 ensure calls, prior_claim recorded", "spawn retry: claims=1 ensure_calls=2 prior_claim=true")
  , ("P-076", "after a spawn and before any host opens, the child's History is empty", "child history before host open: 0")
  , ("P-032", "with the callee host down the request is pending and the caller AWAITING", "offline call: pending=1 parent=awaiting")
  , ("P-033", "a reply for an unrelated call_id is accepted and the caller stays AWAITING", "unrelated correlation: parent=awaiting")
  , ("P-034 P-078", "a correlated result completes caller and callee once the child host opens", "correlated result: parent=completed child=completed")
  , ("P-035", "a correlated error completes the caller with outcome error", "correlated error: parent=completed outcome=error")
  , ("P-036", "reopening both Engines after completion appends and dispatches nothing", "replay: parent appends=0 dispatches=0; child appends=0 dispatches=0")
  , ("P-075", "child credentials appear in no outcome, envelope, or History record", "credential absent from outcomes/envelopes/history: true")
  , ("demo", "the run passes as a whole", "overall: PASS")
  ]

type Run = (ExitCode, String, String)

runDemo :: FilePath -> [String] -> IO Run
runDemo exe arguments = readCreateProcessWithExitCode (proc exe arguments) ""

-- | One run of a configuration, then one example per check its output
-- evidences.
checksOf :: SpecWith Run
checksOf = do
  it "exits 0 and prints exactly the reference's lines" $ \run@(code, out, _) ->
    if code == ExitSuccess && T.lines (T.pack out) == lifecycleLines then pure () else evidence run
  mapM_
    ( \(index, (ids, what, line)) -> it (ids <> " " <> what) $ \run@(_, out, _) ->
        if drop index (T.lines (T.pack out)) `startsWith` line then pure () else evidence run
    )
    (zip [0 :: Int ..] lineChecks)
  where
    startsWith (x : _) line = x == line
    startsWith [] _ = False
    evidence (code, out, err) = expectationFailure (show code <> "\n" <> out <> "\n--- stderr ---\n" <> err)

mixedRuns :: Spec
mixedRuns = do
  url <- runIO lookupPostgresUrl
  case url of
    Nothing -> it "runs" (pendingWith skipMessage)
    Just configured -> aroundAll (withScratchDatabase configured) $ do
      let haskellExe = findExecutable "cv5-lifecycle-demo" >>= maybe (fail "cv5-lifecycle-demo is not on PATH (build-tool-depends)") pure
          inRepo path = (</> path) <$> repoRoot
          dsn target = BC.unpack target.targetUrl
          json xs = "[" <> concatMap id (zipWith (\i x -> (if i == (0 :: Int) then "" else ",") <> show x) [0 ..] xs) <> "]"
          pythonChild = do
            python <- pythonExecutable
            script <- inRepo ("upstream" </> "petrus" </> "scripts" </> "cv5-lifecycle-demo.py")
            pure (json [python, "-B", script, "--internal-child"])
          pythonWorker = do
            python <- pythonExecutable
            script <- inRepo ("packages" </> "petrus-processes" </> "test" </> "interop" </> "lifecycle_spawn_worker.py")
            pure (json [python, "-B", script])
          mixed extra target = do
            python <- pythonExecutable
            script <- inRepo ("packages" </> "petrus-processes" </> "test" </> "interop" </> "lifecycle_demo_mixed.py")
            exe <- haskellExe
            runDemo python (["-B", script, "--dsn", dsn target] <> concatMap (\flag -> [flag, exe]) extra)
          configuration name start = describe name (beforeAllWith start checksOf)
      configuration "the Haskell executable alone" $ \target -> do
        exe <- haskellExe
        runDemo exe ["--dsn", dsn target]
      configuration "P-038 Haskell parent, Python child host" $ \target -> do
        exe <- haskellExe
        child <- pythonChild
        runDemo exe ["--dsn", dsn target, "--child-command", child]
      configuration "P-079 Haskell parent Engine, process.spawn executed by the Python worker" $ \target -> do
        exe <- haskellExe
        worker <- pythonWorker
        runDemo exe ["--dsn", dsn target, "--spawn-worker-command", worker]
      configuration "P-038 Python parent, Haskell child host" (mixed ["--haskell-child"])
      configuration "P-079 Python parent Engine, process.spawn executed by the Haskell worker" (mixed ["--haskell-spawn-worker"])
      configuration "P-038 P-079 Python parent with a Haskell child host and a Haskell spawn worker" (mixed ["--haskell-child", "--haskell-spawn-worker"])
