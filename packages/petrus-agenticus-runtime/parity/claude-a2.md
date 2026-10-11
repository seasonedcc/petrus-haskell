# Claude host parity

Upstream module: `petrus/agenticus/runtime/claude.py` (the exact Claude A2
Local lane), pinned at `upstream/petrus` 3f85fc2.

Haskell:

- `Petrus.Agenticus.Runtime.Claude`: pins, descriptors, the continuation
  payload and codec, the session-store mirror, the operation, the adapter,
  `_OfficialFactory` (`officialFactory`) and the private CLI wrapper.
- `data/claude_sidecar.py`: hosts the optional Python Claude Agent SDK. The
  Haskell adapter keeps admission, custody, the PreToolUse hook, the MCP
  tool handlers, the session-store mirror, publication and cleanup evidence.
  The sidecar forwards every hook, tool and session-store call the SDK makes
  back to the Haskell process over a JSON-lines pipe, so every persisted
  transcript byte is produced in Haskell.

Spec: `test/Petrus/Agenticus/Runtime/ClaudeSpec.hs`. Each `it` label is the
upstream test name; parametrized cases keep pytest's ids.

## Fixtures

| Reference fake | Haskell |
| --- | --- |
| `Client`, `Factory` | `ClaudeClient`, `ClaudeClientFactory` records driven by per-test plans |
| `ToolSdk` | a capturing `ClaudeSdk` |
| `monkeypatch` of `importlib.metadata.version` and `importlib.import_module` | `ClaudeProbeHooks` |
| continuation, Turn and custody fakes | records over `ClaudeContinuationOperations`, `ClaudeTurnOperations` and `PiConnectionCustody` |

`test/fixtures/claude/claude_agent_sdk` is a fake SDK package with the pinned
SDK's public protocol surface (the attributes and `ClaudeAgentOptions`
fields the probe requires). Its `ClaudeSDKClient` drives everything the
adapter hands the SDK: the PreToolUse hook, the in-process MCP tool handler,
and the session store. The sidecar tests run it under the pinned CPython
(`pythonExecutable`).

## `tests/petrus/agenticus/runtime/test_claude.py` (32 functions, 46 cases)

| Upstream test | Notes |
| --- | --- |
| `test_exact_descriptors_and_opaque_values_hide_provider_bodies` | |
| `test_continuation_rejects_noncanonical_session` (3 ids) | `[AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA]`, `[]`, `[not-a-uuid]` |
| `test_session_store_empty_append_and_unknown_load_are_protocol_noops` | |
| `test_session_store_deduplicates_uuid_and_rejects_conflict` | |
| `test_official_client_requires_child_and_resume_temp_absence` | `_OfficialClient.disconnect` lives in the sidecar, so this test drives `claude_sidecar.py` against the fake SDK: a clean disconnect, and one whose child survives (`client-cleanup-uncertain`). |
| `test_probe_reports_absent_sdk_before_materialization` | |
| `test_probe_rejects_version_drift` (2 ids) | `[0.2.127-2.1.220-incompatible]`, `[0.2.128-2.1.219-incompatible]` |
| `test_probe_requires_exact_public_protocol` | |
| `test_probe_records_exact_ready_installation` | |
| `test_fresh_turn_is_one_append_with_isolated_options_and_ordered_custody` | |
| `test_cli_wrapper_drops_ambient_environment_before_provider_exec` | The wrapper runs under the pinned CPython. |
| `test_multiline_prompt_and_unicode_result_are_preserved_without_controls` | |
| `test_invalid_prompt_rejects_before_materialization` (3 ids) | `[]`, `[nul\x00prompt]`, `[x*65537]` |
| `test_native_continuation_resumes_only_accepted_transcript` | |
| `test_disconnect_final_flush_is_included_before_continuation_publication` | |
| `test_provider_terminal_failures_never_append` (4 ids) | `[plan0]` … `[plan3]` |
| `test_malformed_or_incomplete_streams_fail_closed` (5 ids) | `[plan0-result-cardinality]`, `[plan1-result-cardinality]`, `[plan2-session-store-failed]`, `[plan3-session-store-failed]`, `[plan4-message-overflow]` |
| `test_snapshot_and_grant_mismatch_reject_before_materialization` | |
| `test_stale_local_lease_rejects_before_authority_materialization` | |
| `test_stale_continuation_project_rejects_before_materialization` | |
| `test_client_failures_clean_or_report_uncertainty` (3 ids) | `[plan0-provider-failed]`, `[plan1-provider-failed]`, `[plan2-cleanup-unverified]` |
| `test_stale_connection_fence_releases_without_client_start` | |
| `test_release_uncertainty_downgrades_completed_candidate` | |
| `test_cancel_interrupts_and_drains_without_publication` | |
| `test_response_timeout_interrupts_then_fails_after_bounded_grace` | |
| `test_response_completing_after_timeout_interrupt_never_publishes` | |
| `test_candidate_store_failure_returns_no_public_references` | |
| `test_result_first_and_publication_claim_make_cancellation_too_late` | |
| `test_operation_redelivery_is_idempotent_and_conflicts_fail` | |
| `test_output_and_authority_canaries_never_render_or_log` | Checks every rendering (`render…` and `Show`) instead of log records. |
| `test_official_mcp_bridge_denies_unknown_and_uses_provider_tool_identity` | |
| `test_runtime_module_import_has_no_optional_sdk_dependency` | The import blocker becomes an adapter built over a sidecar whose interpreter does not exist: building the adapter and descriptors never runs it. |

### Sidecar examples (not in the reference)

These drive `claude_sidecar.py` against the fake SDK under the pinned
CPython. They are the cross-language checks for this host: the SDK's hook,
tool and session-store calls cross the pipe, and the transcript bytes the
Continuation keeps are produced on the Haskell side.

- `probes the fake SDK, its version and bundled CLI READY`
- `runs a fresh and a resumed turn through the official client`
- `interrupts a blocked official response on cancel`
- `reports an official client whose child survives disconnect as
  unverified`

## Differential corpus

The `claude` section of `differential/hosts_corpus.json` (seed 4242),
replayed by `HostsDifferentialSpec`:

| Section | Cases | What it covers |
| --- | ---: | --- |
| `text` | 200 | `_text` |
| `uuid` | 306 | `_uuid`, including non-v1–5 versions and variants |
| `encode_transcript` | 307 | `_encode_transcript` bytes, entry and total bounds |
| `decode_transcript` | 319 | `_decode_transcript`, including non-canonical spacing |
| `canonical_input` | 208 | `_canonical_input` bytes |
| `sanitize` | 205 | `_sanitize` |
| `payload` | 104 | `ClaudeContinuationPayloadV1` |

The transcript bytes are the Continuation's persisted body. Every encoding
the reference accepts or refuses is matched byte for byte.

## Benchmarks

See `bench/results-hosts.md`: `claude-transcript-encode` 2.0×,
`claude-transcript-decode` 2.4×, `claude-canonical-input` 2.4× and
`claude-sanitize` 2.2× the reference's speed. A whole Turn through the
official client and the shared sidecar (`claude-turn`) is 1.20× (lowest
of nine interleaved rounds 1.18×).

## `tests/petrus/agenticus/runtime/test_claude_real.py` (2 functions)

Ported in `test/Petrus/Agenticus/Runtime/Live/ClaudeSpec.hs`, behind the
same gates (`PETRUS_CV16_CLAUDE_QUALIFY=1`, `PETRUS_CV16_CLAUDE_LIVE=1`).
Both run the real Claude Agent SDK and its bundled Claude Code CLI through
the production sidecar; the live cell also needs an approved credential
handoff. Without the gate they are pending; with it, a missing handoff
fails where the reference skips. See
[docs/live-provider-acceptance.md](../../../docs/live-provider-acceptance.md);
no live run is recorded yet.
