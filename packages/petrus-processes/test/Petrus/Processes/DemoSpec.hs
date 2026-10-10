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
lifecycleLines =
  [ "spawn retry: claims=1 ensure_calls=2 prior_claim=true"
  , "child history before host open: 0"
  , "offline call: pending=1 parent=awaiting"
  , "unrelated correlation: parent=awaiting"
  , "correlated result: parent=completed child=completed"
  , "correlated error: parent=completed outcome=error"
  , "replay: parent appends=0 dispatches=0; child appends=0 dispatches=0"
  , "credential absent from outcomes/envelopes/history: true"
  , "overall: PASS"
  ]

passes :: FilePath -> [String] -> Expectation
passes exe arguments = do
  (code, out, err) <- readCreateProcessWithExitCode (proc exe arguments) ""
  if code == ExitSuccess && T.lines (T.pack out) == lifecycleLines
    then pure ()
    else expectationFailure (show code <> "\n" <> out <> "\n--- stderr ---\n" <> err)

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
            passes python (["-B", script, "--dsn", dsn target] <> concatMap (\flag -> [flag, exe]) extra)
      it "the Haskell executable alone" $ \target -> do
        exe <- haskellExe
        passes exe ["--dsn", dsn target]
      it "Haskell parent, Python child host" $ \target -> do
        exe <- haskellExe
        child <- pythonChild
        passes exe ["--dsn", dsn target, "--child-command", child]
      it "Haskell parent Engine, process.spawn executed by the Python worker" $ \target -> do
        exe <- haskellExe
        worker <- pythonWorker
        passes exe ["--dsn", dsn target, "--spawn-worker-command", worker]
      it "Python parent, Haskell child host" $ mixed ["--haskell-child"]
      it "Python parent Engine, process.spawn executed by the Haskell worker" $ mixed ["--haskell-spawn-worker"]
      it "Python parent with both a Haskell child host and a Haskell spawn worker" $ mixed ["--haskell-child", "--haskell-spawn-worker"]
