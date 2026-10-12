# Live-provider acceptance tests

The reference ships nine opt-in tests that drive real providers: real
`codex`, Claude, Amp and Pi installations, real accounts and paid model
calls, and for one of them a real Gondolin VM image. They live in
`tests/petrus/agenticus/runtime/*_real.py`. The port has all nine, in
`packages/petrus-agenticus-runtime/test/Petrus/Agenticus/Runtime/Live/`,
behind the same environment variables.

Without its variable, each test is **pending**, and its message names the
variable to set. With the variable set to exactly `1`, the test runs, and
every missing prerequisite **fails** it. That includes the cases where the
reference calls `pytest.skip` inside a running test: no `codex` CLI, no
`OPENAI_API_KEY`, no handoff file, or another Gondolin image build. An
opted-in run therefore never passes without reaching the provider.

## The tests

| Haskell module | Test | Gate | Also needs |
| --- | --- | --- | --- |
| `Live.CodexSpec` | `test_exact_codex_a2_local_fresh_then_native_resume` | `PETRUS_CV16_CODEX_LIVE=1` | `codex` 0.145.0 on `PATH` or at `PETRUS_CV16_CODEX_BIN`; `OPENAI_API_KEY` (used once for `codex login --with-api-key` into a private home); `node`; `python3` on `PATH` (the private Codex helper) |
| `Live.CodexSpec` | `test_exact_codex_a3_gondolin_fresh_then_native_resume` | `PETRUS_CV16_CODEX_GONDOLIN_LIVE=1` | `PETRUS_REAL_GONDOLIN_SDK_MODULE`; `PETRUS_REAL_GONDOLIN_IMAGE` equal to `codexGondolinImageRef`; `PETRUS_REAL_GONDOLIN_BUILD_ID` equal to `codexGondolinBuildId`; `PETRUS_CV16_CODEX_AUTH_FILE`, a Codex `auth.json` (mode 0600, one link, at most 1 MB) that the test **consumes** |
| `Live.ClaudeSpec` | `test_exact_claude_a2_sdk_and_bundled_client` | `PETRUS_CV16_CLAUDE_QUALIFY=1` | `claude-agent-sdk` 0.2.128 with its bundled Claude Code 2.1.220, importable by the `python3` on `PATH` (the Claude sidecar); optional `PETRUS_CV16_CLAUDE_MODEL` (default `claude-sonnet-4-5`). No credential. |
| `Live.ClaudeSpec` | `test_exact_claude_a2_fresh_then_native_resume` | `PETRUS_CV16_CLAUDE_LIVE=1` | as above, plus `PETRUS_CV16_CLAUDE_AUTH_FILE`: an Anthropic API key (mode 0600, one link, at most 8192 bytes, no surrounding whitespace) that the test consumes |
| `Live.AmpSpec` | `test_amp_a1_new_and_continue_in_provider_managed_orb` | `PETRUS_RUN_CV16_AMP_A1=1` | the `amp` CLI and `amp_sdk` (importable by the `python3` on `PATH`), signed in to an Amp account; optional `PETRUS_AMP_PROJECT` (default `henriquebastos/petrus`) |
| `Live.PiSpec` | `test_exact_pi_a2_sdk_ai_and_node` | `PETRUS_CV16_PI_QUALIFY=1` | `pi` and `node` (22.19.0 or later) on `PATH` with `@earendil-works/pi-coding-agent` and `pi-ai` 0.83.0 (and `pi-cc-patch` 1.0.1 for that profile); `PETRUS_CV16_PI_PROVIDER`, `PETRUS_CV16_PI_MODEL`; optional `PETRUS_CV16_PI_AUTH_PROFILE` (`api-key`, `subscription` or `cc-patch-subscription`; default `api-key`). No credential. |
| `Live.PiSpec` | `test_exact_pi_a2_fresh_then_native_resume` | `PETRUS_CV16_PI_LIVE=1` | as above, plus `PETRUS_CV16_PI_AUTH_FILE`: the provider key (8192 bytes at most) or, for a subscription profile, the OAuth credential file (1 MB at most); consumed |
| `Live.AgentNetSpec` | `test_exact_agent_net_pi_installation_and_public_phase` | `PETRUS_CV16_AGENT_NET_QUALIFY=1` | `PETRUS_CV16_AGENT_NET_NODE`: a `node` reporting exactly `v22.19.0`; `PETRUS_CV16_AGENT_NET_PACKAGE_ROOT`: a `@earendil-works/pi-coding-agent` 0.83.0 package with `pi-ai` and `pi-agent-core` 0.83.0 under its `node_modules`. No credential. |
| `Live.AgentNetSpec` | `test_agent_net_direct_anthropic_key_runs_one_bounded_local_task` | `PETRUS_CV16_AGENT_NET_LIVE=1` | as above, plus `PETRUS_CV16_AGENT_NET_AUTH_FILE`: an absolute path to an `sk-ant-` key (mode 0600, at most 8192 bytes); consumed |

"Consumed" means what it means in the reference: after the credential is in
Agent Connection custody, the test unlinks the handoff file. Use a
disposable copy. Each test revokes and erases its connection before it
ends, also when it fails.

## Running them

Build as usual, then select the group and set the gates you want. For
example, the two credential-free probes:

```sh
export PATH=$HOME/.ghcup/bin:$PATH
PETRUS_CV16_CLAUDE_QUALIFY=1 PETRUS_CV16_PI_QUALIFY=1 \
PETRUS_CV16_PI_PROVIDER=anthropic PETRUS_CV16_PI_MODEL=claude-sonnet-4-5 \
  cabal test petrus-agenticus-runtime:test:petrus-agenticus-runtime-test \
  --test-options='--match "live providers (opt-in)"'
```

A paid cell, with a disposable handoff:

```sh
cp ~/secrets/anthropic-key /tmp/claude-handoff && chmod 600 /tmp/claude-handoff
PETRUS_CV16_CLAUDE_LIVE=1 PETRUS_CV16_CLAUDE_AUTH_FILE=/tmp/claude-handoff \
  cabal test petrus-agenticus-runtime:test:petrus-agenticus-runtime-test \
  --test-options='--match test_claude_real'
```

The paid cells take minutes (the reference allows 900 s each) and spend a
few model calls each.

The default suite (`scripts/check-all`, CI) sets none of the gates, so the
nine tests show as pending there. They are declared opt-ins in
`scripts/check-pending`, by their exact pending messages, next to the other
`real_provider_acceptance`, `real_gondolin_acceptance` and
`qualification_installation` tests.

## The pinned Claude and Amp SDKs, without a credential

`scripts/upstream-python petrus-sdks` provisions the exact SDKs the
reference pins: upstream/petrus synced from its frozen `uv.lock` with the
`agenticus-claude` and `agenticus-amp` extras, in
`dist-newstyle/upstream-python/petrus-sdks/.venv`. The default suite's
`PinnedSdkSpec` (group "the pinned provider SDKs (credential-free)") uses
it with no gate, so it runs locally and in CI, which provisions it next to
the other reference environments. It covers three things:

- the body of `test_exact_claude_a2_sdk_and_bundled_client`;
- a Claude SDK client and the Hands MCP server, built from production's
  option keys and tools, and released without connecting;
- `amp-sdk`'s version and its `AmpOptions`/`execute` protocol.

To run the gated Claude probe itself over that environment:

```sh
sdk=$(scripts/upstream-python petrus-sdks)
PATH=$(dirname "$sdk"):$PATH PETRUS_CV16_CLAUDE_QUALIFY=1 \
  cabal test petrus-agenticus-runtime:test:petrus-agenticus-runtime-test \
  --test-options='--match test_exact_claude_a2_sdk_and_bundled_client'
```

The Pi and Agent-as-a-Net probes remain opt-ins. Their npm packages are
pinned by no upstream lock and come from the network, and Agent-as-a-Net
needs a `node` of exactly v22.19.0.

## Recorded runs

| Date | Commit | Installed | Cells | Outcome |
| --- | --- | --- | --- | --- |
| 2026-10-11 | `f72a800` plus the change that added `petrus-sdks` | `claude-agent-sdk` 0.2.128, bundled Claude Code 2.1.220, `amp-sdk` 0.1.20260729121202, CPython 3.14.6 (macOS arm64) | `test_exact_claude_a2_sdk_and_bundled_client` (`PETRUS_CV16_CLAUDE_QUALIFY=1`), and `PinnedSdkSpec` | passed |

TODO: no paid live run has been recorded yet. The paid cells need the
accounts, the credentials and the Gondolin image listed above. When one is
made, record here the date, the commit, the installed versions, which cells
ran and their outcome, and update the "live-provider tests" note in
`PARITY.md`.
