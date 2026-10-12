-- | A refused @fabric.send@ or @process.spawn@ is recorded by Local custody
-- exactly as the reference records it, in both directions
-- (test/interop/worker_refusals.py holds the reference's half):
--
-- * the reference's LocalDispatch publishes the invocations, the
--   reference's Worker and then the port's Worker execute them in separate
--   scratch files, and the reference's LocalDispatch collects both;
-- * the port's LocalDispatch publishes the same invocations (decoded from
--   the reference's JSON), the reference's Worker executes them, and the
--   port's LocalDispatch collects what it recorded.
--
-- The refusals are 'Petrus.Fabric.Error.FabricError's, recorded through the
-- one Python exception hierarchy (@repr(error)@, @type(error).__name__@).
module Petrus.Processes.WorkerRefusalSpec (spec) where

import Control.Exception (throwIO)
import Control.Monad (zipWithM_)
import Data.ByteString.Char8 qualified as BC
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Petrus.Activity (ActivityFailureFields (..), failureFields, invocationFromJson)
import Petrus.Fabric.Postgres (postgresFabric, submit)
import Petrus.Fabric.Send (sendActivity)
import Petrus.Json (Json (..), parseJson, pythonLoads)
import Petrus.Motus.Dispatch (ActivityOutcome (..))
import Petrus.Motus.Dispatch.Local (collect, defaultLocalDispatchOptions, defaultLocalWorkerOptions, dispatch, openLocalWorkerDispatch, toWorkerDispatch, withLocalDispatch)
import Petrus.Motus.Worker (WorkerOptions (..), closeWorker, defaultWorkerOptions, newWorker, runAvailable)
import Petrus.Postgres (withConnection)
import Petrus.Processes.Spawn (ProcessProvisioner (..), SpawnRegistry (..), spawnActivity)
import Petrus.TestSupport (PostgresTarget (..), postgresSpec, pythonExecutable, repoRoot)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (proc, readCreateProcessWithExitCode)
import Test.Hspec

spec :: Spec
spec =
  describe "Worker refusals under Local custody" $
    postgresSpec $ do
      it "a refused fabric.send or process.spawn is recorded as the reference Worker records it" $ \target -> do
        let dsn = BC.unpack target.targetUrl
        python <- referenceRun dsn
        haskell <- withSystemTempDirectory "petrus-refusals" $ \dir -> do
          let path = dir </> "dispatch.db"
          _ <- reference ["publish", path, dsn]
          haskellWorker path target
          reference ["collect", path]
        python `shouldContain` "PermissionError('envelope sender must match the authenticated fabric client')"
        haskell `shouldBe` python

      it "the port's LocalDispatch collects the reference Worker's refusals as the reference collects them" $ \target -> do
        let dsn = BC.unpack target.targetUrl
        python <- jsonOf =<< referenceRun dsn
        haskell <- withSystemTempDirectory "petrus-refusals" $ \dir -> do
          let path = dir </> "dispatch.db"
          printed <- jsonOf =<< reference ["cases"]
          invocations <- case printed of
            Array items -> either (throwIO . userError . show) pure (traverse invocationFromJson items)
            other -> throwIO (userError ("cases printed " <> show other))
          withLocalDispatch path "interop" defaultLocalDispatchOptions $ \custody -> do
            zipWithM_ (dispatch custody) [1 ..] invocations
            _ <- reference ["work", path, dsn]
            outcomes <- collect custody
            pure (Array [Array [Int (toInteger occurrence), outcomeJson outcome] | (occurrence, outcome) <- sortOn fst outcomes])
        haskell `shouldBe` python

-- | The reference's dispatcher and Worker end to end: the collected outcomes.
referenceRun :: String -> IO String
referenceRun dsn =
  withSystemTempDirectory "petrus-refusals" $ \dir -> do
    let path = dir </> "dispatch.db"
    _ <- reference ["publish", path, dsn]
    _ <- reference ["work", path, dsn]
    reference ["collect", path]

-- | The script's @outcome_json@.
outcomeJson :: ActivityOutcome -> Json
outcomeJson = \case
  Succeeded value -> Object [("completed", value)]
  Failed failure ->
    let fields = failureFields failure
     in Object [("failed", Object [("error", String fields.failureError), ("kind", String fields.failureKind), ("retryable", Bool fields.failureRetryable)])]

jsonOf :: String -> IO Json
jsonOf printed = either (throwIO . userError) pure (parseJson pythonLoads (BC.pack printed))

-- | Run a subcommand of the reference's half and return its stdout.
reference :: [String] -> IO String
reference arguments = do
  interpreter <- pythonExecutable
  script <- (</> ("packages" </> "petrus-processes" </> "test" </> "interop" </> "worker_refusals.py")) <$> repoRoot
  (code, out, err) <- readCreateProcessWithExitCode (proc interpreter (["-B", script] <> arguments)) ""
  case code of
    ExitSuccess -> pure out
    ExitFailure _ -> expectationFailure (unwords arguments <> " failed:\n" <> out <> "\n--- stderr ---\n" <> err) >> pure ""

-- | The script's @work@, by the port: the same Activities (a client bound
-- to an unregistered @mallory@; a spawn registry that is never reached)
-- over Local custody.
haskellWorker :: FilePath -> PostgresTarget -> IO ()
haskellWorker path target =
  withConnection target.targetUrl True $ \connection -> do
    client <- postgresFabric connection "mallory" "abcdefghijklmnopqrstuvwxyz0123456789"
    custody <- openLocalWorkerDispatch path defaultLocalWorkerOptions
    let unreached :: IO a
        unreached = throwIO (userError "the spawn registry is never reached by a refused invocation")
        registry =
          SpawnRegistry
            { claim = const unreached
            , childOf = \_ _ -> unreached
            , childrenOf = const unreached
            , parentOf = const unreached
            }
        activities =
          Map.fromList
            [ ("fabric.send", \inv _ -> sendActivity (submit client) inv)
            , ("process.spawn", \inv _ -> spawnActivity registry (ProcessProvisioner (const unreached)) inv)
            ]
    worker <- newWorker (toWorkerDispatch custody) activities defaultWorkerOptions {output = const (pure ())}
    ran <- runAvailable worker 7
    closeWorker worker
    ran `shouldBe` 7
