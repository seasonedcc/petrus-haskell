{-# LANGUAGE CApiFFI #-}

-- | Local-process provider: ports of the local halves of
-- @test_execution_contract.py@, @test_private_execution_substrate.py@ and
-- all of @test_private_file_transfer.py@.
module LocalSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (bracket, bracket_, finally, throwIO, try)
import Control.Monad (unless, when)
import Data.ByteString qualified as B
import Data.IORef
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (allocaBytes, allocaBytesAligned)
import Foreign.Ptr (FunPtr, Ptr, castPtr, nullPtr)
import Foreign.Storable (peek)
import GHC.Clock (getMonotonicTime)
import Petrus.Motus.Execution
import Petrus.Motus.Execution.Archive (extractWorkspaceArchive, workspaceArchive)
import Petrus.Motus.Execution.Internal.Process (RunOutcome (..), communicate, pollExit, runCaptured, runningPid, spawnCaptured, spawnSpec, waitExitWithin)
import Petrus.Motus.Execution.Providers.Local
import Support
import System.Directory
import System.Environment (setEnv, unsetEnv)
import System.Posix.Files (createNamedPipe, createSymbolicLink, removeLink)
import System.Posix.IO (OpenMode (ReadOnly), closeFd, defaultFileFlags, fdReadBuf, openFd)
import System.Posix.Signals (openEndedPipe, sigKILL, signalProcess)
import System.Posix.Types (Fd (..))
import System.Posix.Process (getProcessID)
import Test.Hspec

rightOr :: (Show e) => Either e a -> a
rightOr = either (error . show) id

cmd :: [Text] -> Command
cmd argv = rightOr (mkCommand (commandSpec argv))

cmdWith :: [Text] -> (CommandSpec -> CommandSpec) -> Command
cmdWith argv f = rightOr (mkCommand (f (commandSpec argv)))

spec_ :: [Capability] -> EnvironmentSpec
spec_ capabilities = rightOr (mkEnvironmentSpec Nothing capabilities)

privateOps :: LocalProcessEnvironment -> PrivateFileTransfer
privateOps env = fromJust (providerPrivateFiles (localProvider env))

pfile :: Text -> B.ByteString -> PrivateFile
pfile name content = rightOr (mkPrivateFile name content)

-- | @_local(tmp_path, operation)@.
localFixture :: FilePath -> Text -> IO (LocalProcessEnvironment, EnvironmentLease, ExecutionAttachment)
localFixture tmp operation = do
  env <- newLocalProcessEnvironment
  let provider = localProvider env
  lease <- providerCreate provider operation (spec_ [capPrivateFileTransfer])
  let source = tmp <> "/source-" <> T.unpack operation
  createDirectory source
  archive <- workspaceArchive source
  attachment <- providerAttach provider lease archive "input-digest"
  pure (env, lease, attachment)

spec :: Spec
spec = do
  describe "test_execution_contract (local)" $ do
    it "test_local_public_lifecycle_transfers_workspace_and_returns_verified_cleanup" $ withTempDir $ \tmp -> do
      let source = tmp <> "/source"
      createDirectory source
      writeFile (source <> "/input.txt") "host"
      env <- newLocalProcessEnvironment
      let provider = localProvider env
      pid <- getProcessID
      let operation = "cv16-local-" <> T.pack (show pid)
          wanted = spec_ [capWorkspace]
      lease <- providerCreate provider operation wanted
      providerCreate provider operation wanted `shouldReturn` lease
      attachment <- attachDir provider lease source "input-digest"
      result <- providerExecute provider attachment (cmd ["/bin/sh", "-c", "cat input.txt; printf territory > output.txt"])
      resultReturncode result `shouldBe` 0
      resultStdout result `shouldBe` "host"
      provenanceIdentity (resultProvenance result) `shouldBe` leaseIdentity lease
      let restored = tmp <> "/restored"
      exported <- providerExport provider attachment
      extractWorkspaceArchive exported restored
      readFile (restored <> "/output.txt") `shouldReturn` "territory"

      cleaned <- providerDestroy provider lease
      cleaned `shouldBe` CleanupResult (leaseIdentity lease) Clean ""
      cleanupVerified cleaned `shouldBe` True
      providerLookup provider operation `shouldReturn` Nothing
      absent <- providerDestroy provider lease
      cleanupDisposition absent `shouldBe` NotCreated
      cleanupVerified absent `shouldBe` True
      other <- newLocalProcessEnvironment
      unknown <- providerDestroy (localProvider other) lease
      cleanupDisposition unknown `shouldBe` Unverified
      cleanupVerified unknown `shouldBe` False

    it "test_local_destroy_refuses_stale_identity_and_retains_uncertain_custody" $ do
      env <- newLocalProcessEnvironment
      let provider = localProvider env
      lease <- providerCreate provider "cv16-local-stale" defaultSpec
      let stale = rightOr (mkEnvironmentLease (leaseOperationId lease) (leaseProvider lease) "different-lease" (leaseCapabilities lease) Ready)
      (cleanupDisposition <$> providerDestroy provider stale) `shouldReturn` Unverified
      providerLookup provider (leaseOperationId lease) `shouldReturn` Just lease
      localSetRemoveTree env (\_ -> ioError (userError "denied"))
      failed <- providerDestroy provider lease
      cleanupDisposition failed `shouldBe` Unverified
      cleanupDetail failed `shouldBe` "local workspace removal could not be verified"
      providerLookup provider (leaseOperationId lease) `shouldReturn` Just lease
      localSetRemoveTree env removeDirectoryRecursive
      (cleanupVerified <$> providerDestroy provider lease) `shouldReturn` True

    it "test_create_checks_capabilities_before_reusing_an_existing_operation" $ do
      env <- newLocalProcessEnvironment
      let provider = localProvider env
      lease <- providerCreate provider "cv16-capability-check" defaultSpec
      ( providerCreate provider (leaseOperationId lease) (spec_ [capContainer])
          `shouldThrowMessage` (ValueError, "unsupported capabilities: ['container']")
        )
        `finally` providerDestroy provider lease

    it "rejects images, unsafe operation ids, and colliding specs" $ do
      env <- newLocalProcessEnvironment
      let provider = localProvider env
      providerCreate provider "image" (rightOr (mkEnvironmentSpec (Just "alpine") []))
        `shouldThrowMessage` (ValueError, "local process environments do not accept an image")
      providerCreate provider "../bad" defaultSpec
        `shouldThrowMessage` (ValueError, "operation id must be a safe non-empty provider label")
      providerCreate provider "multi" (spec_ [capVm, capContainer, Capability "zeta"])
        `shouldThrowMessage` (ValueError, "unsupported capabilities: ['container', 'vm', 'zeta']")
      lease <- provision env "reuse" defaultSpec
      provision env "reuse" (spec_ [capWorkspace]) `shouldReturn` lease
      _ <- providerDestroy provider lease
      pure ()

  describe "test_private_execution_substrate (local)" $ do
    it "test_provider_neutral_lifecycle_and_environment_custody[local]" $ withTempDir $ \tmp -> do
      env <- newLocalProcessEnvironment
      let provider = localProvider env
      pid <- getProcessID
      lease <- provision env ("cv10-lifecycle-" <> T.pack (show pid)) (spec_ [capExplicitEnvironment])
      let source = tmp <> "/source"
      createDirectory source
      attachment <- attachDir provider lease source "input-digest"
      bracket_ (setEnv "GITHUB_TOKEN" "should-never-cross-the-door") (unsetEnv "GITHUB_TOKEN") $ do
        leaseState lease `shouldBe` Ready
        providerLookup provider (leaseOperationId lease) `shouldReturn` Just lease
        result <-
          providerExecute provider attachment $
            cmdWith
              ["/bin/sh", "-c", "printf '%s|%s' \"$ALLOWED\" \"${GITHUB_TOKEN-unset}\" > result; cat result"]
              (\c -> c {specEnvironment = [("ALLOWED", "yes")]})
        resultReturncode result `shouldBe` 0
        resultStdout result `shouldBe` "yes|unset"
        let restored = tmp <> "/restored"
        extractWorkspaceArchive <$> providerExport provider attachment >>= \f -> f restored
        readFile (restored <> "/result") `shouldReturn` "yes|unset"
        provenanceOperationId (resultProvenance result) `shouldBe` leaseOperationId lease
        superseded <-
          providerExecute provider attachment (cmdWith ["/bin/sh", "-c", "exit 99"] (\c -> c {specIsCurrent = Just (pure False)}))
        resultSuperseded superseded `shouldBe` True
        resultReturncode superseded `shouldBe` -15
        timedOut <- providerExecute provider attachment (cmdWith ["/bin/sh", "-c", "sleep 10"] (\c -> c {specTimeout = Just 0.1}))
        resultTimedOut timedOut `shouldBe` True
      _ <- providerDestroy provider lease
      _ <- providerDestroy provider lease
      providerLookup provider (leaseOperationId lease) `shouldReturn` Nothing

    it "test_capabilities_and_reconciliation_are_truthful" $ do
      env <- newLocalProcessEnvironment
      let provider = localProvider env
      (reconcileClassification <$> providerReconcile provider "absent") `shouldReturn` ReconcileRetryable
      errorMatching (provision env "unsupported" (spec_ [capContainer])) ValueError "unsupported"
      lease <- provision env "known" defaultSpec
      reconciled <- providerReconcile provider "known"
      reconcileClassification reconciled `shouldBe` ReconcileUncertain
      reconcileLease reconciled `shouldBe` Just lease
      reconcileDetail reconciled `shouldBe` "local process completion is not durably recorded"
      _ <- providerDestroy provider lease
      pure ()

    it "test_local_cwd_still_resolves_symlinks_before_containment" $ withTempDir $ \tmp -> do
      env <- newLocalProcessEnvironment
      let provider = localProvider env
      lease <- provision env "local-cwd-symlink" defaultSpec
      attachment <- attachDir provider lease tmp "digest"
      let outside = tmp <> "/outside"
      createDirectory outside
      createSymbolicLink outside (attachmentWorkspace attachment <> "/escape")
      ( providerExecute provider attachment (cmdWith ["true"] (\c -> c {specCwd = "escape"}))
          `shouldThrowMessage` (ValueError, "command cwd escapes the workspace")
        )
        `finally` providerDestroy provider lease

    it "test_local_collection_drains_large_output_and_kills_sigterm_ignoring_process" $ withTempDir $ \tmp -> do
      env <- newLocalProcessEnvironment
      let provider = localProvider env
      lease <- provision env "collection" defaultSpec
      attachment <- attachDir provider lease tmp "digest"
      ( do
          -- The reference's collector checks an unfinished command against
          -- its output limit every 50 ms and terminates it once over (both
          -- languages do), so the reference's own assertion of exit status
          -- 0 holds only when the writer finishes within the first 50 ms:
          -- on a loaded runner it exits -15 (upstream carries this as debt
          -- 2026-09-08T0300Z, "process tests assume short wall-clock
          -- budgets"). Here the writer waits on a FIFO until the first tick
          -- has passed with nothing written, and that tick's currentness
          -- check (made after the overflow check, before any signal) holds
          -- the collector until the FIFO reports that every writer process
          -- has exited, while the collector's readers keep draining. The
          -- command then completes on its own every time: status 0, the
          -- whole 2 MB read, 1000 bytes kept.
          let gate = tmp <> "/writer-gate"
          createNamedPipe gate 0o600
          checks <- newIORef (0 :: Int)
          let current = do
                check <- atomicModifyIORef' checks (\n -> (n + 1, n))
                -- Check 0 precedes the launch; check 1 is the first tick's.
                -- Plain blocking reads (not a Handle): the IO manager's
                -- kqueue misses a FIFO's end-of-file on macOS.
                when (check == 1) $
                  bracket (openFd gate ReadOnly defaultFileFlags) closeFd $ \fd ->
                    allocaBytes 4096 $ \buffer ->
                      let untilEof = fdReadBuf fd buffer 4096 >>= \n -> unless (n == 0) untilEof
                       in untilEof
                pure True
          large <-
            providerExecute provider attachment $
              cmdWith
                ["/bin/sh", "-c", "exec 3>\"$1\"; head -c 2000000 /dev/zero", "sh", T.pack gate]
                (\c -> c {specOutputLimit = 1000, specTimeout = Just 5, specIsCurrent = Just current})
          readIORef checks >>= (`shouldSatisfy` (>= 2))
          resultReturncode large `shouldBe` 0
          resultOutputTruncated large `shouldBe` True
          B.length (resultStdout large) `shouldBe` 1000
          timedOut <-
            providerExecute provider attachment $
              cmdWith ["/bin/sh", "-c", "trap '' TERM; while :; do sleep 1; done"] (\c -> c {specTimeout = Just 0.1})
          resultTimedOut timedOut `shouldBe` True
          resultReturncode timedOut `shouldBe` -9
        )
        `finally` providerDestroy provider lease

    it "reports a missing executable like Popen" $ withTempDir $ \tmp -> do
      env <- newLocalProcessEnvironment
      let provider = localProvider env
      lease <- provision env "missing-executable" defaultSpec
      attachment <- attachDir provider lease tmp "digest"
      ( providerExecute provider attachment (cmd ["definitely-not-a-petrus-command"])
          `shouldThrowMessage` (OSError, "[Errno 2] No such file or directory: 'definitely-not-a-petrus-command'")
        )
        `finally` providerDestroy provider lease
      -- The territory is idle again after a failed launch.
      lease2 <- provision env "missing-executable-2" defaultSpec
      attachment2 <- attachDir provider lease2 tmp "digest"
      _ <- try (providerExecute provider attachment2 (cmd ["definitely-not-a-petrus-command"])) :: IO (Either ExecutionError CommandResult)
      (resultReturncode <$> providerExecute provider attachment2 (cmd ["/bin/sh", "-c", "exit 3"])) `shouldReturn` 3
      _ <- providerDestroy provider lease2
      pure ()

    it "cancel terminates the active process group" $ withTempDir $ \tmp -> do
      env <- newLocalProcessEnvironment
      let provider = localProvider env
      lease <- provision env "cancel" defaultSpec
      attachment <- attachDir provider lease tmp "digest"
      done <- newEmptyMVar
      _ <- forkIO (providerExecute provider attachment (cmd ["/bin/sh", "-c", "sleep 30"]) >>= putMVar done)
      waitUntil (localHasActiveCommand env (leaseId lease))
      providerCancel provider lease "operator"
      result <- takeMVar done
      resultReturncode result `shouldBe` -15
      _ <- providerDestroy provider lease
      pure ()

  describe "child processes (Popen close_fds and restore_signals semantics)" $ do
    it "never lets a child inherit a parent descriptor that lacks close-on-exec" $
      bracket (openFd "/dev/null" ReadOnly defaultFileFlags) closeFd $ \(Fd fd) -> do
        let probe = "if [ -e /dev/fd/" <> show fd <> " ]; then echo leaked; else echo closed; fi"
        outcome <- runCaptured (spawnSpec ["/bin/sh", "-c", probe]) 5
        (outcomeCode outcome, outcomeStdout outcome) `shouldBe` (0, "closed\n")

    it "restores SIGPIPE to its default even when the parent ignores it" $ do
      -- An ignored SIGPIPE survives exec; then `yes` would see EPIPE and
      -- complain on stderr instead of dying quietly.
      original <- sigpipeDisposition
      outcome <- withSigpipeIgnored (runCaptured (spawnSpec ["/bin/sh", "-c", "yes | head -c 4"]) 5)
      (outcomeCode outcome, outcomeStdout outcome, outcomeStderr outcome) `shouldBe` (0, "y\ny\n", "")
      -- The rest of the suite needs the RTS's own SIGPIPE handler back.
      sigpipeDisposition `shouldReturn` original

    it "wakes a waiter as soon as the child exits, reaping it once" $ do
      running <- spawnCaptured (spawnSpec ["/bin/sh", "-c", "sleep 0.2; exit 7"])
      start <- getMonotonicTime
      code <- waitExitWithin running (Just 5)
      elapsed <- subtract start <$> getMonotonicTime
      code `shouldBe` Just 7
      elapsed `shouldSatisfy` (< 1)
      -- The status is cached: later polls and waits answer the same code.
      pollExit running `shouldReturn` Just 7
      waitExitWithin running Nothing `shouldReturn` Just 7

    it "answers Nothing at the limit and still sees a later exit and signal" $ do
      running <- spawnCaptured (spawnSpec ["/bin/sh", "-c", "sleep 10"])
      start <- getMonotonicTime
      waitExitWithin running (Just 0.1) `shouldReturn` Nothing
      waitExitWithin running (Just 0) `shouldReturn` Nothing
      elapsed <- subtract start <$> getMonotonicTime
      elapsed `shouldSatisfy` (\e -> e >= 0.1 && e < 2)
      signalProcess sigKILL (runningPid running)
      waitExitWithin running Nothing `shouldReturn` Just (-9)
      _ <- communicate running
      pollExit running `shouldReturn` Just (-9)

    it "lets concurrent waiters share one exit" $ do
      running <- spawnCaptured (spawnSpec ["/bin/sh", "-c", "sleep 0.1; exit 3"])
      results <- newEmptyMVar
      mapM_ (\_ -> forkIO (waitExitWithin running (Just 5) >>= putMVar results)) [1 :: Int .. 4]
      codes <- mapM (const (takeMVar results)) [1 :: Int .. 4]
      codes `shouldBe` replicate 4 (Just 3)

  describe "test_private_file_transfer" $ do
    it "test_local_private_file_full_custody_route_is_bounded_and_workspace_free" $ withTempDir $ \tmp -> do
      (env, lease, attachment) <- localFixture tmp "private-file"
      let provider = localProvider env
          ops = privateOps env
          canary = "private-canary-never-in-workspace"
      reference <- importPrivateFile ops attachment (pfile "auth.json" canary)
      refAttachmentId reference `shouldBe` attachmentId attachment
      provenanceIdentity (refProvenance reference) `shouldBe` leaseIdentity lease
      result <-
        providerExecute provider attachment $
          cmdWith
            ["/bin/sh", "-c", "printf -- \"-updated\" >> \"$CODEX_HOME/auth.json\"; printf \"%s\" \"$CODEX_HOME\""]
            (\c -> c {specPrivateRoots = [("CODEX_HOME", reference)]})
      resultReturncode result `shouldBe` 0
      resultStdout result `shouldBe` "[PRIVATE_ROOT]"
      (canary `B.isInfixOf` (resultStdout result <> resultStderr result)) `shouldBe` False
      exportPrivateFile ops attachment reference `shouldReturn` pfile "auth.json" (canary <> "-updated")

      archive <- providerExport provider attachment
      (canary `B.isInfixOf` archive) `shouldBe` False
      let restored = tmp <> "/restored"
      extractWorkspaceArchive archive restored
      listDirectory restored >>= (`shouldSatisfy` notElem "auth.json")

      deleted <- deletePrivateFile ops attachment reference
      privateCleanupDisposition deleted `shouldBe` Clean
      privateCleanupRemoved deleted `shouldBe` 1
      privateCleanupVerified deleted `shouldBe` True
      repeated <- deletePrivateFile ops attachment reference
      privateCleanupDisposition repeated `shouldBe` NotCreated
      privateCleanupRemoved repeated `shouldBe` 0
      privateCleanupVerified repeated `shouldBe` True
      privateCleanupPhysicalErasureGuaranteed repeated `shouldBe` False
      (privateCleanupVerified <$> cleanupPrivateFiles ops attachment) `shouldReturn` True

      territory <- fromJust <$> localTerritory env (leaseId lease)
      (cleanupVerified <$> providerDestroy provider lease) `shouldReturn` True
      doesPathExist territory `shouldReturn` False

    it "test_local_private_refs_are_exactly_attachment_and_lease_fenced" $ withTempDir $ \tmp -> do
      (env, lease, first) <- localFixture tmp "private-fences"
      let provider = localProvider env
          ops = privateOps env
      reference <- importPrivateFile ops first (pfile "auth.json" "secret")
      let forged = rightOr (mkPrivateFileRef "missing" "auth.json" (attachmentId first) (refProvenance reference))
      (privateCleanupDisposition <$> deletePrivateFile ops first forged) `shouldReturn` Unverified
      (privateCleanupDetail <$> deletePrivateFile ops first forged) `shouldReturn` "private file reference is not registered"

      let staleLease = rightOr (mkEnvironmentLease (leaseOperationId lease) (leaseProvider lease) "stale" (leaseCapabilities lease) Ready)
          staleAttachment = rightOr (mkExecutionAttachment "stale" staleLease "digest" (attachmentWorkspace first))
          staleRef = rightOr (mkPrivateFileRef "missing" "auth.json" "stale" (leaseProvenance staleLease))
      staleResult <- deletePrivateFile ops staleAttachment staleRef
      privateCleanupDisposition staleResult `shouldBe` Unverified
      privateCleanupDetail staleResult `shouldBe` "private-file attachment is stale, foreign, or active"

      let secondSource = tmp <> "/second"
      createDirectory secondSource
      second <- attachDir provider lease secondSource "second-digest"
      attachmentId second `shouldNotBe` attachmentId first
      exportPrivateFile ops first reference `shouldThrowMessage` (ValueError, "private-file attachment is not current")
      (privateCleanupDisposition <$> deletePrivateFile ops first reference) `shouldReturn` Unverified
      (cleanupVerified <$> providerDestroy provider lease) `shouldReturn` True

    it "test_local_private_symlink_replacement_never_reads_or_unlinks_target" $ withTempDir $ \tmp -> do
      (env, lease, attachment) <- localFixture tmp "private-symlink"
      let provider = localProvider env
          ops = privateOps env
      reference <- importPrivateFile ops attachment (pfile "auth.json" "private")
      root <- fromJust <$> localPrivateRoot env (leaseId lease) (refFileId reference)
      let victim = tmp <> "/victim"
      B.writeFile victim "victim"
      removeLink (root <> "/auth.json")
      createSymbolicLink victim (root <> "/auth.json")

      exportPrivateFile ops attachment reference
        `shouldThrowMessage` (RuntimeError, "private file export could not be verified")
      cleanup <- deletePrivateFile ops attachment reference
      privateCleanupDisposition cleanup `shouldBe` Unverified
      privateCleanupVerified cleanup `shouldBe` False
      B.readFile victim `shouldReturn` "victim"
      let replacement = tmp <> "/replacement"
      createDirectory replacement
      (attachDir provider lease replacement "replacement")
        `shouldThrowMessage` (RuntimeError, "prior attachment private-file cleanup could not be verified")
      (cleanupVerified <$> providerDestroy provider lease) `shouldReturn` True

    it "test_local_private_operations_are_excluded_while_command_is_active" $ withTempDir $ \tmp -> do
      (env, lease, attachment) <- localFixture tmp "private-active"
      let provider = localProvider env
          ops = privateOps env
      reference <- importPrivateFile ops attachment (pfile "auth.json" "private")
      done <- newEmptyMVar
      _ <-
        forkIO $
          ( providerExecute provider attachment $
              cmdWith ["/bin/sh", "-c", "sleep 0.4"] (\c -> c {specPrivateRoots = [("CODEX_HOME", reference)]})
          )
            >>= putMVar done . Right
      waitUntil (localHasActiveCommand env (leaseId lease))
      importPrivateFile ops attachment (pfile "other" "private")
        `shouldThrowMessage` (RuntimeError, "private-file operation requires an idle territory")
      exportPrivateFile ops attachment reference
        `shouldThrowMessage` (RuntimeError, "private-file operation requires an idle territory")
      (privateCleanupDisposition <$> deletePrivateFile ops attachment reference) `shouldReturn` Unverified
      outcome <- takeMVar done
      case outcome of
        Right result -> resultReturncode result `shouldBe` 0
        Left (failure :: ExecutionError) -> throwIO failure
      (privateCleanupVerified <$> cleanupPrivateFiles ops attachment) `shouldReturn` True
      (cleanupVerified <$> providerDestroy provider lease) `shouldReturn` True

    it "test_local_private_file_count_and_total_bounds_are_attachment_scoped" $ withTempDir $ \tmp -> do
      env <- newLocalProcessEnvironmentWith defaultLocalConfig {configMaxPrivateFiles = 2, configMaxPrivateTotalBytes = 5}
      let provider = localProvider env
          ops = privateOps env
      lease <- providerCreate provider "private-bounds" (spec_ [capPrivateFileTransfer])
      createDirectory (tmp <> "/source")
      attachment <- attachDir provider lease (tmp <> "/source") "input-digest"
      _ <- importPrivateFile ops attachment (pfile "one" "12")
      _ <- importPrivateFile ops attachment (pfile "two" "345")
      importPrivateFile ops attachment (pfile "three" "")
        `shouldThrowMessage` (ValueError, "private file attachment bounds would be exceeded")
      (privateCleanupRemoved <$> cleanupPrivateFiles ops attachment) `shouldReturn` 2
      -- A second cleanup is memoized as not-created.
      (privateCleanupDisposition <$> cleanupPrivateFiles ops attachment) `shouldReturn` NotCreated
      (cleanupVerified <$> providerDestroy provider lease) `shouldReturn` True

    it "private files live outside the workspace with owner-only modes" $ withTempDir $ \tmp -> do
      (env, lease, attachment) <- localFixture tmp "private-modes"
      let ops = privateOps env
      reference <- importPrivateFile ops attachment (pfile "auth.json" "secret")
      root <- fromJust <$> localPrivateRoot env (leaseId lease) (refFileId reference)
      territory <- fromJust <$> localTerritory env (leaseId lease)
      root `shouldBe` territory <> "/private/" <> T.unpack (refFileId reference)
      (T.pack (attachmentWorkspace attachment) `T.isPrefixOf` T.pack root) `shouldBe` False
      unknown <- try (exportPrivateFile ops attachment (rightOr (mkPrivateFileRef "nope" "auth.json" (attachmentId attachment) (refProvenance reference))))
      either (\e -> errorMessage e `shouldBe` "private file reference is not registered to the current attachment") (\_ -> expectationFailure "expected failure") unknown
      providerExecute (localProvider env) attachment (cmdWith ["true"] (\c -> c {specPrivateRoots = [("ROOT", rightOr (mkPrivateFileRef "nope" "auth.json" (attachmentId attachment) (refProvenance reference)))]}))
        `shouldThrowMessage` (ValueError, "command private root is not registered to the current attachment")
      _ <- providerDestroy (localProvider env) lease
      pure ()

    it "rejects foreign providers on destroy" $ do
      env <- newLocalProcessEnvironment
      let foreignLease = rightOr (mkEnvironmentLease "foreign-cleanup" "foreign-provider" "foreign-lease" Set.empty Ready)
      result <- providerDestroy (localProvider env) foreignLease
      cleanupDisposition result `shouldBe` Unverified
      cleanupDetail result `shouldBe` "lease belongs to a different provider"

-- | Run with SIGPIPE ignored, as in a parent that ignores it, then put back
-- the exact disposition SIGPIPE had. 'System.Posix.Signals.installHandler'
-- cannot do that: the RTS installs its SIGPIPE handler from C, so
-- installHandler reports it as 'Default', and restoring that leaves SIGPIPE
-- fatal for the rest of the suite. The RTS interrupts an @interruptible@
-- foreign call by sending its thread SIGPIPE, and a write to a closed pipe
-- or socket raises it too, so either then killed the test binary silently
-- (status 141): petrus-execution-test died that way in GondolinSpec (CI run
-- 38147286527, attempt 1).
withSigpipeIgnored :: IO a -> IO a
withSigpipeIgnored action =
  allocaBytesAligned sigactionRoom 16 $ \saved -> do
    throwErrnoIfMinus1_ "sigaction" (c_sigaction openEndedPipe nullPtr saved)
    bracket_
      (c_signal openEndedPipe c_sigIgn)
      (throwErrnoIfMinus1_ "sigaction" (c_sigaction openEndedPipe saved nullPtr))
      action

-- | SIGPIPE's handler: the first member of @struct sigaction@ on Linux and
-- macOS alike. (Only that: glibc leaves most of the returned @sa_mask@
-- unwritten.)
sigpipeDisposition :: IO (FunPtr (CInt -> IO ()))
sigpipeDisposition =
  allocaBytesAligned sigactionRoom 16 $ \buffer -> do
    throwErrnoIfMinus1_ "sigaction" (c_sigaction openEndedPipe nullPtr buffer)
    peek (castPtr buffer)

-- | More than any platform's @sizeof (struct sigaction)@ (152 on Linux,
-- 16 on macOS).
sigactionRoom :: Int
sigactionRoom = 1024

foreign import capi unsafe "signal.h sigaction"
  c_sigaction :: CInt -> Ptr () -> Ptr () -> IO CInt

foreign import capi unsafe "signal.h signal"
  c_signal :: CInt -> FunPtr (CInt -> IO ()) -> IO (FunPtr (CInt -> IO ()))

foreign import capi "signal.h value SIG_IGN"
  c_sigIgn :: FunPtr (CInt -> IO ())

attachDir :: EnvironmentProvider -> EnvironmentLease -> FilePath -> Text -> IO ExecutionAttachment
attachDir provider lease directory digest = do
  archive <- workspaceArchive directory
  providerAttach provider lease archive digest

waitUntil :: IO Bool -> IO ()
waitUntil condition = do
  start <- getMonotonicTime
  let loop = do
        ok <- condition
        now <- getMonotonicTime
        unless (ok || now - start > 2) (threadDelay 10000 >> loop)
  loop
  ok <- condition
  when (not ok) (expectationFailure "condition never became true")
  pure ()
