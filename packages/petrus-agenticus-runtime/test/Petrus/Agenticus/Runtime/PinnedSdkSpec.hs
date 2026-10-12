{-# LANGUAGE OverloadedRecordDot #-}

-- | The Claude and Amp sidecars against the real, pinned provider SDKs, with
-- no credential and no provider call.
--
-- The rest of the suite drives the sidecars against fake SDK packages
-- (@test/fixtures/claude@, @test/fixtures/amp@) with the pinned public
-- surfaces. Here the interpreter is @scripts/upstream-python petrus-sdks@:
-- upstream/petrus synced from its frozen @uv.lock@ with the
-- @agenticus-claude@ and @agenticus-amp@ extras, so @claude-agent-sdk@
-- 0.2.128 (with its bundled Claude Code 2.1.220) and @amp-sdk@
-- 0.1.20260729121202 are exactly the reference's. Like every other
-- reference environment, it is provisioned on first use and its absence
-- fails, never skips.
--
-- * The credential-free Claude A2 qualification
--   (@test_exact_claude_a2_sdk_and_bundled_client@, which the reference
--   gates on @PETRUS_CV16_CLAUDE_QUALIFY@) runs ungated here, over that
--   interpreter, with the same body as "Live.ClaudeSpec".
-- * The Claude sidecar builds a @ClaudeSDKClient@ from the options a turn
--   passes ('claudeTurnOptions') and the Hands MCP server from production's
--   tools ('claudeHandsTools'), then releases it without connecting:
--   @ClaudeAgentOptions(**options)@, @tool(...)@ and
--   @create_sdk_mcp_server(...)@ on the real SDK.
-- * The Amp sidecar reads @amp-sdk@'s installed version and checks the
--   @AmpOptions@ / @execute@ protocol (the SDK half of @_protocol_ready@).
--   Starting an Amp stream runs the @amp@ CLI against Amp's service, so it
--   stays with the opt-in @test_amp_real.py@.
module Petrus.Agenticus.Runtime.PinnedSdkSpec (spec) where

import Petrus.Agenticus.Runtime.Amp (AmpProbeHooks (..), AmpSidecar (..), ampSdkVersion, ampSidecar, officialProbeHooks)
import Petrus.Agenticus.Runtime.Claude
import Petrus.Agenticus.Runtime.Live.ClaudeSpec (qualifyClaude)
import Petrus.Json (Json (..))
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

sdkPython :: IO FilePath
sdkPython = upstreamPythonExecutable "petrus-sdks"

-- | The official sidecars, on that interpreter instead of @python3@.
claudeOn :: FilePath -> ClaudeSidecar
claudeOn python = ClaudeSidecar python claudeSidecar.searchPath claudeSidecar.grace claudeSidecar.pool

ampOn :: FilePath -> AmpSidecar
ampOn python = AmpSidecar python ampSidecar.searchPath ampSidecar.grace ampSidecar.pool

spec :: Spec
spec = describe "the pinned provider SDKs (credential-free)" $ do
  it "qualifies claude-agent-sdk 0.2.128 and its bundled Claude Code as the Claude A2 probe does" $ do
    python <- sdkPython
    options <- claudeAdapterOptions
    qualifyClaude options {hooks = officialClaudeProbeHooks (claudeOn python), interpreter = python}

  it "builds a Claude SDK client and the Hands MCP server, and releases it unconnected" $
    withSystemTempDirectory "claude-sdk-smoke" $ \tmp -> do
      python <- sdkPython
      let config = claudeRuntimeConfig "claude-sonnet-4-5" tmp tmp
      store <- newSessionStore config.maxMessages config.maxTranscriptBytes Nothing Nothing
      client <-
        (sidecarSdk (claudeOn python)).newClient
          ClaudeSdkRequest
            { options = claudeTurnOptions config store tmp "/nonexistent/claude" "" Nothing
            , serverName = "petrus_hands"
            , tools = claudeHandsTools (\_ _ _ -> pure Null)
            , preToolUse = \_ -> pure Null
            }
      client.release `shouldReturn` True

  it "reads amp-sdk 0.1.20260729121202 and its AmpOptions/execute protocol" $ do
    python <- sdkPython
    let hooks = officialProbeHooks (ampOn python)
    hooks.installedSdkVersion `shouldReturn` Just ampSdkVersion
    hooks.sdkProtocolReady `shouldReturn` True
