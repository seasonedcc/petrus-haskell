-- | The body of upstream's @test_live_e2b_vm_provider_is_explicitly_opt_in@,
-- shared by the opt-in live run (real E2B) and the in-suite run against the
-- fake E2B server, so both drive exactly the same lifecycle.
module E2bLive (liveLifecycle) where

import Control.Exception (bracket_, finally)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Motus.Execution
import Petrus.Motus.Execution.Archive (extractWorkspaceArchive, workspaceArchive)
import Petrus.Motus.Execution.Internal.Common (uuidHex)
import Petrus.Motus.Execution.Providers.E2b
import System.Directory (createDirectory)
import System.Environment (setEnv, unsetEnv)
import Test.Hspec

rightOr :: (Show e) => Either e a -> a
rightOr = either (error . show) id

-- | Run the live lifecycle with two providers built from this configuration
-- (upstream: @E2bEnvironment(lease_timeout=900)@ twice), in a fresh temp
-- directory, against a template with @sh@ and @tar@.
liveLifecycle :: E2bConfig -> Text -> FilePath -> IO ()
liveLifecycle config template tmp = do
  let source = tmp <> "/source"
  createDirectory source
  writeFile (source <> "/probe.txt") "host-to-vm"
  operation <- ("cv10-live-e2b-" <>) . T.take 16 <$> uuidHex
  provider <- e2bProvider <$> newE2bEnvironment config {e2bLeaseTimeout = 900}
  recreated <- e2bProvider <$> newE2bEnvironment config {e2bLeaseTimeout = 900}
  lease <- providerCreate provider operation (rightOr (mkEnvironmentSpec (Just template) [capVm, capExplicitEnvironment]))
  cleanupRef <- newIORef Nothing
  absentRef <- newIORef Nothing
  let destroyBoth =
        (providerDestroy recreated lease >>= writeIORef cleanupRef . Just)
          `finally` (providerDestroy provider lease >>= writeIORef absentRef . Just)
  ( do
      archive <- workspaceArchive source
      attachment <- providerAttach provider lease archive "live-input"
      providerLookup recreated operation `shouldReturn` Just lease
      providerCreate recreated operation (rightOr (mkEnvironmentSpec (Just template) [])) `shouldReturn` lease
      result <-
        bracket_ (setEnv "GITHUB_TOKEN" "must-remain-on-host") (unsetEnv "GITHUB_TOKEN") $
          providerExecute recreated attachment $
            command
              [ "/bin/sh"
              , "-c"
              , "test \"$(cat probe.txt)\" = host-to-vm && printf vm-to-host > result.txt && printf '%s|%s' \"$ALLOWED\" \"${GITHUB_TOKEN-unset}\""
              ]
              (\c -> c {specEnvironment = [("ALLOWED", "yes")], specTimeout = Just 30})
      (resultReturncode result, resultStdout result) `shouldBe` (0, "yes|unset")
      let restored = tmp <> "/restored"
      exported <- providerExport recreated attachment
      extractWorkspaceArchive exported restored
      readFile (restored <> "/probe.txt") `shouldReturn` "host-to-vm"
      readFile (restored <> "/result.txt") `shouldReturn` "vm-to-host"
      (reconcileClassification <$> providerReconcile recreated operation) `shouldReturn` ReconcileUncertain
      timedOut <- providerExecute recreated attachment (command ["/bin/sh", "-c", "sleep 30"] (\c -> c {specTimeout = Just 0.5}))
      (resultTimedOut timedOut, resultSuperseded timedOut) `shouldBe` (True, False)
      observations <- newIORef [True, False]
      let current = atomicModifyIORef' observations (\case x : xs -> (xs, x); [] -> ([], False))
      superseded <-
        providerExecute recreated attachment $
          command ["/bin/sh", "-c", "sleep 30"] (\c -> c {specTimeout = Just 30, specIsCurrent = Just current})
      (resultSuperseded superseded, resultTimedOut superseded) `shouldBe` (True, False)
    )
    `finally` destroyBoth
  Just cleanup <- readIORef cleanupRef
  Just absent <- readIORef absentRef
  (cleanupDisposition cleanup, cleanupIdentity cleanup) `shouldBe` (Clean, leaseIdentity lease)
  (cleanupDisposition absent, cleanupVerified absent) `shouldBe` (NotCreated, True)
  providerLookup recreated operation `shouldReturn` Nothing
  (reconcileClassification <$> providerReconcile recreated operation) `shouldReturn` ReconcileRetryable
  where
    command argv f = rightOr (mkCommand (f (commandSpec argv)))
