-- | E2B provider against a port of upstream's fake SDK
-- (@_FakeE2bSandbox@ and friends in @test_private_execution_substrate.py@).
module E2bSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import Control.Exception (finally)
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.IORef
import Data.List (elemIndex)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import E2bLive (liveLifecycle)
import Petrus.Motus.Execution
import Petrus.Motus.Execution.Archive (workspaceArchive)
import Petrus.Motus.Execution.Providers.E2b
import Support
import System.Directory (createDirectory)
import System.Environment (lookupEnv)
import Test.Hspec

rightOr :: (Show e) => Either e a -> a
rightOr = either (error . show) id

data FakeHandle = FakeHandle
  { fakeHandleKilled :: MVar ()
  }

data FakeSandbox = FakeSandbox
  { fakeId :: Text
  , fakeMetadata :: Map Text Text
  , fakeState :: IORef Text
  , fakeWorkspace :: IORef ByteString
  , fakeHandles :: IORef [FakeHandle]
  , fakeFiles :: IORef (Map Text ByteString)
  , fakeExecutions :: IORef [(Text, E2bRunOptions)]
  }

data FakeWorld = FakeWorld
  { worldEntries :: IORef [FakeSandbox]
  , worldCounter :: IORef Int
  , worldListCalls :: IORef Int
  , worldFailListAt :: IORef (Maybe Int)
  }

newWorld :: IO FakeWorld
newWorld = FakeWorld <$> newIORef [] <*> newIORef 0 <*> newIORef 0 <*> newIORef Nothing

entry :: FakeWorld -> Text -> IO FakeSandbox
entry world identifier = do
  entries <- readIORef (worldEntries world)
  case [s | s <- entries, fakeId s == identifier] of
    s : _ -> pure s
    [] -> throwExecution KeyError (T.pack (show identifier))

killHandle :: FakeHandle -> IO ()
killHandle handle = () <$ tryPutMVar (fakeHandleKilled handle) ()

asSandbox :: FakeSandbox -> E2bSandbox
asSandbox s =
  E2bSandbox
    { sandboxId = fakeId s
    , sandboxKill = do
        writeIORef (fakeState s) "killed"
        readIORef (fakeHandles s) >>= mapM_ killHandle
    , sandboxWriteFile = \path bytes -> modifyIORef' (fakeFiles s) (Map.insert path bytes)
    , sandboxReadFile = \path -> fromJust . Map.lookup path <$> readIORef (fakeFiles s)
    , sandboxRemoveFile = \path -> modifyIORef' (fakeFiles s) (Map.delete path)
    , sandboxRun = \command options -> do
        modifyIORef' (fakeExecutions s) (<> [(command, options)])
        let parts = T.words command
        if "rm -rf /home/user/workspace" `T.isPrefixOf` command
          then do
            let path = parts !! (fromJust (elemIndex "-xf" parts) + 1)
            files <- readIORef (fakeFiles s)
            writeIORef (fakeWorkspace s) (fromJust (Map.lookup path files))
          else when ("tar -cf" `T.isPrefixOf` command) $ do
            workspace <- readIORef (fakeWorkspace s)
            modifyIORef' (fakeFiles s) (Map.insert (parts !! 2) workspace)
        pure (E2bCommandResult 0 "" "")
    , sandboxRunBackground = \command options -> do
        modifyIORef' (fakeExecutions s) (<> [(command, options)])
        killed <- newEmptyMVar
        let handle = FakeHandle killed
        modifyIORef' (fakeHandles s) (<> [handle])
        pure
          E2bHandle
            { handleWait = \onStdout _onStderr -> case command of
                "sleep forever" -> do
                  waitKilled killed 2
                  pure (E2bCommandResult (-9) "" "")
                "transport failure" -> throwExecution RuntimeError "E2B command transport failed"
                "large output" -> do
                  onStdout (T.replicate 100 "x")
                  pure (E2bCommandResult 0 (T.replicate 100 "x") "")
                _ -> do
                  onStdout "vm-output"
                  pure (E2bCommandResult 0 "vm-output" "")
            , handleKill = killHandle handle
            }
    }
  where
    waitKilled killed seconds = do
      let loop :: Int -> IO ()
          loop 0 = pure ()
          loop n = tryReadMVar killed >>= maybe (threadDelay 10000 >> loop (n - 1)) (const (pure ()))
      loop (round (seconds * 100 :: Double))

fakeSdk :: FakeWorld -> E2bSdk
fakeSdk world =
  E2bSdk
    { sdkList = \options query limit -> do
        options `shouldBe` E2bOptions Nothing
        calls <- atomicModifyIORef' (worldListCalls world) (\n -> (n + 1, n + 1))
        failAt <- readIORef (worldFailListAt world)
        when (failAt == Just calls) (throwExecution RuntimeError "lookup failed after creation")
        entries <- readIORef (worldEntries world)
        matching <- fmap concat . mapM (matches query) $ entries
        let items = take limit matching
        hasNext <- newIORef (not (null items))
        pure
          E2bPaginator
            { paginatorHasNext = readIORef hasNext
            , paginatorNextItems = \_ -> writeIORef hasNext False >> pure items
            }
    , sdkCreate = \options _template _timeout metadata -> do
        options `shouldBe` E2bOptions Nothing
        n <- atomicModifyIORef' (worldCounter world) (\c -> (c + 1, c + 1))
        sandbox <-
          FakeSandbox ("sandbox-" <> T.pack (show n)) metadata
            <$> newIORef "running"
            <*> newIORef ""
            <*> newIORef []
            <*> newIORef Map.empty
            <*> newIORef []
        modifyIORef' (worldEntries world) (<> [sandbox])
        pure (asSandbox sandbox)
    , sdkConnect = \_ identifier _ -> asSandbox <$> entry world identifier
    }
  where
    matches query s = do
      state <- readIORef (fakeState s)
      pure
        [ E2bSandboxInfo (fakeId s) (fakeMetadata s) state
        | state /= "killed"
        , all (\(k, v) -> Map.lookup k (fakeMetadata s) == Just v) (Map.toList query)
        ]

withWorld :: (FakeWorld -> E2bEnvironment -> EnvironmentProvider -> IO a) -> IO a
withWorld action = do
  world <- newWorld
  env <- newE2bEnvironment defaultE2bConfig {e2bSdkLoader = pure (fakeSdk world)}
  action world env (e2bProvider env)

template :: EnvironmentSpec
template = rightOr (mkEnvironmentSpec (Just "petrus-agent-template") [])

cmdWith :: [Text] -> (CommandSpec -> CommandSpec) -> Command
cmdWith argv f = rightOr (mkCommand (f (commandSpec argv)))

lastExecution :: FakeWorld -> Text -> IO (Text, E2bRunOptions)
lastExecution world identifier = last <$> (readIORef . fakeExecutions =<< entry world identifier)

attachDir :: EnvironmentProvider -> EnvironmentLease -> FilePath -> Text -> IO ExecutionAttachment
attachDir provider lease directory digest = do
  archive <- workspaceArchive directory
  providerAttach provider lease archive digest

spec :: Spec
spec = describe "e2b provider (fake SDK)" $ do
  it "test_e2b_vm_lifecycle_is_lookup_first_artifact_based_and_recoverable" $ withTempDir $ \tmp -> do
    world <- newWorld
    let operation = "cv10-e2b-recovery"
        source = tmp <> "/source"
        wanted = rightOr (mkEnvironmentSpec (Just "petrus-agent-template") [capVm])
    createDirectory source
    writeFile (source <> "/evidence") "portable"
    first <- e2bProvider <$> newE2bEnvironment defaultE2bConfig {e2bSdkLoader = pure (fakeSdk world)}
    lease <- providerCreate first operation wanted
    attachment <- attachDir first lease source "digest"

    recreated <- e2bProvider <$> newE2bEnvironment defaultE2bConfig {e2bSdkLoader = pure (fakeSdk world)}
    providerCreate recreated operation wanted `shouldReturn` lease
    errorMatching (providerCreate recreated operation (rightOr (mkEnvironmentSpec (Just "other-template") []))) ValueError "collides"
    exported <- providerExport recreated attachment
    recovered <- providerAttach recreated lease exported "recovered"
    result <- providerExecute recreated recovered $
      cmdWith ["tool", "argument with spaces; $(unsafe)"] (\c -> c {specEnvironment = [("ALLOWED", "yes")]})
    resultStdout result `shouldBe` "vm-output"
    provenanceProvider (resultProvenance result) `shouldBe` "e2b"
    (command, options) <- lastExecution world (leaseId lease)
    command `shouldBe` "tool 'argument with spaces; $(unsafe)'"
    runEnvs options `shouldBe` [("ALLOWED", "yes")]
    runCwd options `shouldBe` Just "/home/user/workspace"
    executions <- readIORef . fakeExecutions =<< entry world (leaseId lease)
    all (not . T.isInfixOf " /workspace" . fst) executions `shouldBe` True
    (reconcileClassification <$> providerReconcile recreated operation) `shouldReturn` ReconcileUncertain
    let stale = rightOr (mkEnvironmentLease operation (leaseProvider lease) "different-vm" (leaseCapabilities lease) (leaseState lease))
    (cleanupDisposition <$> providerDestroy recreated stale) `shouldReturn` Unverified
    providerLookup recreated operation `shouldReturn` Just lease
    cleanup <- providerDestroy recreated lease
    cleanupDisposition cleanup `shouldBe` Clean
    cleanupIdentity cleanup `shouldBe` leaseIdentity lease
    providerLookup recreated operation `shouldReturn` Nothing
    (reconcileClassification <$> providerReconcile recreated operation) `shouldReturn` ReconcileRetryable

  it "test_e2b_vm_cwd_remains_a_guest_path_when_the_host_remaps_home" $ withTempDir $ \tmp -> withWorld $ \world _ provider -> do
    -- The guest cwd is computed lexically, so no host path resolution
    -- (upstream patches Path.resolve to prove it) can influence it.
    lease <- providerCreate provider "e2b-guest-cwd" template
    attachment <- attachDir provider lease tmp "digest"
    ( do
        _ <- providerExecute provider attachment (cmdWith ["tool"] (\c -> c {specCwd = "."}))
        (runCwd . snd <$> lastExecution world (leaseId lease)) `shouldReturn` Just "/home/user/workspace"
        _ <- providerExecute provider attachment (cmdWith ["tool"] (\c -> c {specCwd = "nested/.."}))
        (runCwd . snd <$> lastExecution world (leaseId lease)) `shouldReturn` Just "/home/user/workspace"
        errorMatching (providerExecute provider attachment (cmdWith ["tool"] (\c -> c {specCwd = "../escape"}))) ValueError "escapes"
      )
      `finally` providerDestroy provider lease

  it "test_e2b_vm_creation_lookup_failure_kills_uncertain_sandbox" $ withWorld $ \world _ provider -> do
    writeIORef (worldFailListAt world) (Just 2)
    errorMatching (providerCreate provider "e2b-uncertain-create" template) RuntimeError "lookup failed after creation"
    entries <- readIORef (worldEntries world)
    case entries of
      [only] -> readIORef (fakeState only) `shouldReturn` "killed"
      _ -> expectationFailure ("expected one sandbox, got " <> show (length entries))

  it "test_e2b_vm_transport_failure_is_not_mislabeled_as_command_failure" $ withTempDir $ \tmp -> withWorld $ \_ _ provider -> do
    lease <- providerCreate provider "e2b-transport-failure" template
    ( do
        attachment <- attachDir provider lease tmp "digest"
        errorMatching (providerExecute provider attachment (cmdWith ["transport", "failure"] id)) RuntimeError "transport failed"
      )
      `finally` providerDestroy provider lease

  it "test_e2b_vm_output_is_bounded" $ withTempDir $ \tmp -> withWorld $ \_ _ provider -> do
    lease <- providerCreate provider "e2b-output-bound" template
    ( do
        attachment <- attachDir provider lease tmp "digest"
        result <- providerExecute provider attachment (cmdWith ["large", "output"] (\c -> c {specOutputLimit = 10}))
        resultOutputTruncated result `shouldBe` True
        resultStdout result `shouldBe` "xxxxxxxxxx"
        resultStderr result `shouldBe` ""
      )
      `finally` providerDestroy provider lease

  describe "test_e2b_vm_command_timeout_and_supersession_kill_remote_command" $ do
    let run label seconds superseding flag = it label $ withTempDir $ \tmp -> withWorld $ \world _ provider -> do
          lease <- providerCreate provider ("e2b-" <> T.pack label) template
          attachment <- attachDir provider lease tmp "digest"
          observations <- newIORef [True, False]
          let current = atomicModifyIORef' observations (\case x : xs -> (xs, x); [] -> ([], False))
          ( do
              result <-
                providerExecute provider attachment $
                  cmdWith
                    ["sleep", "forever"]
                    (\c -> c {specTimeout = Just seconds, specIsCurrent = if superseding then Just current else Nothing})
              flag result `shouldBe` True
              resultReturncode result `shouldBe` -9
              handles <- readIORef . fakeHandles =<< entry world (leaseId lease)
              (fmap (const True) <$> tryReadMVar (fakeHandleKilled (last handles))) `shouldReturn` Just True
            )
            `finally` providerDestroy provider lease
    run "timed_out" 0.02 False resultTimedOut
    run "superseded" 2 True resultSuperseded

  it "test_noncapable_providers_reject_private_roots_before_lookup_or_allocation (e2b)" $ do
    env <- newE2bEnvironment defaultE2bConfig {e2bSdkLoader = expectationFailure "private roots must reject before SDK lookup" >> missingSdk}
    let provenance = rightOr (mkExecutionProvenance "operation" "docker" "lease")
        reference = rightOr (mkPrivateFileRef "file" "auth.json" "attachment" provenance)
        lease = rightOr (mkEnvironmentLease "operation" "docker" "lease" Set.empty Ready)
        attachment = rightOr (mkExecutionAttachment "attachment" lease "digest" "/workspace")
    providerExecute (e2bProvider env) attachment (cmdWith ["true"] (\c -> c {specPrivateRoots = [("CODEX_HOME", reference)]}))
      `shouldThrowMessage` (ValueError, "E2B does not support the private-file-transfer capability")

  it "test_destroy_never_verifies_absence_for_a_foreign_provider (e2b)" $ do
    env <- newE2bEnvironment defaultE2bConfig {e2bSdkLoader = expectationFailure "foreign cleanup must not load the E2B SDK" >> missingSdk}
    let foreignLease = rightOr (mkEnvironmentLease "foreign-cleanup" "foreign-provider" "foreign-lease" Set.empty Ready)
    result <- providerDestroy (e2bProvider env) foreignLease
    cleanupDisposition result `shouldBe` Unverified
    cleanupVerified result `shouldBe` False

  it "validates construction and reports a missing SDK as uncertain" $ do
    newE2bEnvironment defaultE2bConfig {e2bLeaseTimeout = 0}
      `shouldThrowMessage` (ValueError, "E2B lease timeout must be positive")
    env <- newE2bEnvironment defaultE2bConfig {e2bSdkLoader = missingSdk}
    result <- providerReconcile (e2bProvider env) "op"
    reconcileClassification result `shouldBe` ReconcileUncertain
    reconcileDetail result `shouldBe` "No module named 'e2b'"
    providerCreate (e2bProvider env) "op" defaultSpec `shouldThrowMessage` (ValueError, "E2B requires a template image")

  it "quotes like shlex" $ do
    map shlexQuote ["", "safe-_@%+=:,./", "it's", "a b", "$(x)", "\233"]
      `shouldBe` ["''", "safe-_@%+=:,./", "'it'\"'\"'s'", "'a b'", "'$(x)'", "'\233'"]

  -- Opt-in exactly as upstream: the same three gates and skip reasons, then
  -- the same lifecycle against real E2B through the default loader (the
  -- native client).  E2bHttpSpec runs this body against the fake E2B server
  -- on every run.
  it "test_live_e2b_vm_provider_is_explicitly_opt_in" $ do
    enabled <- lookupEnv "PETRUS_RUN_CV10_E2B"
    key <- lookupEnv "E2B_API_KEY"
    liveTemplate <- lookupEnv "PETRUS_CV10_E2B_TEMPLATE"
    case (enabled, key, liveTemplate) of
      (Just "1", Just k, Just t) | not (null k), not (null t) -> withTempDir (liveLifecycle defaultE2bConfig (T.pack t))
      (Just "1", Just k, _) | not (null k) -> pendingWith "set PETRUS_CV10_E2B_TEMPLATE to a template with sh and tar"
      (Just "1", _, _) -> pendingWith "live E2B lifecycle acceptance requires E2B_API_KEY"
      _ -> pendingWith "set PETRUS_RUN_CV10_E2B=1 to run live E2B lifecycle acceptance"
