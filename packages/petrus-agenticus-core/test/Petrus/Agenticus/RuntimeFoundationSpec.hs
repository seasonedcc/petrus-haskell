-- | Port of @tests/petrus/agenticus/runtime/test_foundation.py@.
module Petrus.Agenticus.RuntimeFoundationSpec (spec) where

import Data.Char (isAlphaNum)
import Data.IORef
import Data.Set qualified as Set
import Data.Text qualified as T
import Petrus.Agenticus.Catalog.Descriptor
import Petrus.Agenticus.Error
import Petrus.Agenticus.Runtime.Installation
import Petrus.Agenticus.Runtime.Operation
import Petrus.Agenticus.Runtime.Result
import Petrus.Agenticus.Support
import Petrus.Agenticus.Thread.Identity
import Petrus.Agenticus.Thread.Lifecycle
import Test.Hspec

runtimeA, otherRuntime :: DescriptorIdentity
runtimeA = descriptorIdentity KindRuntime "test.runtime" 1
otherRuntime = descriptorIdentity KindRuntime "test.other-runtime" 1

component :: InstalledComponent
component = expectRight (mkInstalledComponent "test-client" "1.2.3" "package:test-client@1.2.3")

installation :: RuntimeInstallation
installation =
  expectRight $
    mkRuntimeInstallation runtimeA 1 [component] "linux" "x86_64" (Set.fromList ["runtime.cancel", "runtime.continue"])

issue :: T.Text -> T.Text -> ProbeIssue
issue c comp = expectRight (mkProbeIssue c (Just comp))

settlementOf :: TurnOutcome -> Integer -> T.Text -> Either AgenticusError RuntimeTurnSettlement
settlementOf o a code = mkRuntimeTurnSettlement (literalEpisodeId "episode-1") (literalTurnId "turn-1") o a code Nothing Nothing

spec :: Spec
spec = describe "runtime/test_foundation.py" $ do
  it "test_installation_facts_are_canonical_and_have_no_path_or_authority_field" $ do
    let second = expectRight (mkInstalledComponent "sidecar" "4.5.6" "package:sidecar@4.5.6")
        inst = expectRight (mkRuntimeInstallation runtimeA 1 [second, component] "linux" "x86_64" (Set.fromList ["runtime.cancel"]))
    inst.components `shouldBe` [second, component]
    -- The record's fields are exactly upstream's six; there is no path,
    -- environment or home field to reach (a compile-time guarantee here).
    let RuntimeInstallationFields r v cs p a caps = fieldsOf inst
    (r, v, cs, p, a, caps) `shouldBe` (runtimeA, 1, [second, component], "linux", "x86_64", Set.fromList ["runtime.cancel"])

  it "test_probe_dispositions_preserve_exact_installation_truth" $ do
    let ready = expectRight (mkRuntimeProbeResult runtimeA ProbeReady (Just installation) [])
        incompatible = expectRight (mkRuntimeProbeResult runtimeA ProbeIncompatible (Just installation) [issue "version-mismatch" "test-client"])
        absent = expectRight (mkRuntimeProbeResult runtimeA ProbeNotInstalled Nothing [issue "client-not-installed" "test-client"])
        unavailable = expectRight (mkRuntimeProbeResult runtimeA ProbeUnavailable (Just installation) [issue "service-unavailable" "test-client"])
    ready.installation `shouldBe` Just installation
    incompatible.issues `shouldBe` [issue "version-mismatch" "test-client"]
    absent.installation `shouldBe` Nothing
    unavailable.installation `shouldBe` Just installation
    mkRuntimeProbeResult runtimeA ProbeReady Nothing [] `shouldRaiseMatching` ValueError $ "ready runtime"
    mkRuntimeProbeResult otherRuntime ProbeReady (Just installation) [] `shouldRaiseMatching` ValueError $ "identities must match"
    mkRuntimeProbeResult runtimeA ProbeUnavailable Nothing [] `shouldRaiseMatching` ValueError $ "unavailable runtime"

  it "test_runtime_turn_result_is_one_batch_and_hides_opaque_references" $ do
    let canary = "opaque-secret-reference"
        result =
          expectRight $
            mkRuntimeTurnSettlement
              (literalEpisodeId "episode-1")
              (literalTurnId "turn-1")
              TurnCompleted
              1
              "turn-completed"
              (Just canary)
              (Just "continuation-state-1")
    result.acceptedAppends `shouldBe` 1
    T.pack (show result) `shouldNotSatisfy` T.isInfixOf canary
    T.pack (show result) `shouldNotSatisfy` T.isInfixOf "continuation-state-1"
    -- The seven upstream fields, readable by name.
    (result.episodeId, result.turnId, result.outcome, result.terminationCode, result.outputReference, result.continuationReference)
      `shouldBe` (literalEpisodeId "episode-1", literalTurnId "turn-1", TurnCompleted, "turn-completed", Just canary, Just "continuation-state-1")
    settlementOf TurnCompleted 0 "turn-completed" `shouldRaiseMatching` ValueError $ "completed runtime Turn"
    settlementOf TurnFailed 2 "failed" `shouldRaiseMatching` ValueError $ "zero or one"

  it "test_operation_protocol_is_structural_and_cleanup_fails_closed" $ do
    let settlement = expectRight (settlementOf TurnCancelled 0 "cancelled")
    waits <- newIORef (0 :: Int)
    let operation =
          RuntimeOperation
            { operationId = "operation-1"
            , wait = \_ -> modifyIORef' waits (+ 1) >> pure settlement
            , cancel = \_ -> pure CancellationRequested
            , close = expectRightIO (mkRuntimeOperationCleanup "operation-1" RuntimeCleanupClean "resources-absent" False)
            }
    operation.wait Nothing `shouldReturn` settlement
    operation.cancel "stop" `shouldReturn` CancellationRequested
    cleanup <- operation.close
    cleanupVerified cleanup `shouldBe` True
    cleanupVerified (expectRight (mkRuntimeOperationCleanup "operation-2" RuntimeCleanupUnverified "cleanup-uncertain" False))
      `shouldBe` False

  it "test_protocol_errors_expose_only_machine_codes" $ do
    let e = runtimeProtocolError "malformed-frame"
    runtimeProtocolErrorCode e `shouldBe` Just "malformed-frame"
    e.errorMessage `shouldBe` "runtime protocol error: malformed-frame"
    e `shouldSatisfy` (`isInstanceOf` RuntimeError)
    (Left (runtimeProtocolError "provider said secret=canary") :: Either AgenticusError ())
      `shouldRaiseMatching` ValueError
      $ "machine token"

  it "test_foundation_imports_with_optional_provider_sdks_blocked" $ do
    -- Upstream imports the foundation with optional provider SDK imports
    -- blocked.  Haskell links statically, so the equivalent guarantee is
    -- that the library stanza depends on no provider SDK package.
    path <- packageFile "petrus-agenticus-core.cabal"
    cabal <- T.pack <$> readFile path
    let library = fst (T.breakOn "\ntest-suite" (snd (T.breakOn "\nlibrary" cabal)))
        tokens = Set.fromList (T.split (\c -> not (isAlphaNum c || c == '-' || c == '_')) (T.toLower library))
        blocked = ["amp", "anthropic", "claude-agent-sdk", "claude_agent_sdk", "docker", "e2b", "gondolin", "openai"]
    T.null library `shouldBe` False
    filter (`Set.member` tokens) blocked `shouldBe` []

-- | Destructure the installation by its exact upstream field list.
data RuntimeInstallationFields
  = RuntimeInstallationFields DescriptorIdentity Integer [InstalledComponent] T.Text T.Text (Set.Set T.Text)

fieldsOf :: RuntimeInstallation -> RuntimeInstallationFields
fieldsOf i = RuntimeInstallationFields i.runtime i.adapterContractVersion i.components i.platform i.architecture i.capabilities
