# Codex host parity

Upstream modules: `petrus/agenticus/runtime/codex.py` (the A2 Local lane,
the A3 Gondolin lane and the Gondolin Activity adapter) and
`petrus/agenticus/runtime/_codex_gondolin_service.py` (the A3 runtime
service and its Activity client), pinned at `upstream/petrus` 3f85fc2.

Haskell modules:

- `Petrus.Agenticus.Runtime.Codex`: pins, descriptors, the continuation
  payload and codec, `_parse_helper`, `_parse_jsonl`, the operation, and the
  Local and Gondolin adapters.
- `Petrus.Agenticus.Runtime.CodexGondolin`: the Gondolin Activity adapter,
  the runtime service, its ledger and its Activity client.
- `data/codex_helper.py`: the reference's `_HELPER_SOURCE`, byte for byte.

Spec: `test/Petrus/Agenticus/Runtime/CodexSpec.hs`. Each `it` label is the
upstream test name; parametrized cases keep pytest's ids.

## Fixtures

The reference builds its fake `codex` CLI with `fake_codex(tmp_path,
version)` and its fake Gondolin SDK module with `fake_gondolin_sdk(tmp_path,
executable)`. `test/fixtures/codex/extract.py` calls those exact functions
and saves their output as templates (`fake_codex.py`,
`fake_gondolin_codex.mjs`) with placeholders for the per-run paths and
version. The spec fills the placeholders in each temporary directory. A spec
example re-runs `extract.py` and checks that the committed templates are
unchanged.

The other fakes:

| Reference fake | Haskell |
| --- | --- |
| `Continuations`, `BlockingContinuations` | `Continuations` (an optional entered/release gate) over `CodexContinuationOperations` |
| `Turns` | `Turns` over `CodexTurnOperations` |
| `Custody`, `PublishingCustody` | `Custody` (an optional admit gate) as a `HostConnectionCustody` record |
| `ActivityContext(stale=...)` | `activityContext stale`, which also counts heartbeats |
| `RecordingLocal`, `UncertainCleanupLocal`, provider monkeypatching | `Hooked`: a wrapper over a real Motus provider that records commands and lets a test swap each private-file operation and the workspace export, even after the binding is open |
| `monkeypatch` of `shutil.which` and `subprocess.run` | `CodexProbeHooks` behind `IORef`s |
| assigning `adapter.start` | `CodexAdapterOptions.startWrapper`, switched through the rig's `wrapStart` |
| `monkeypatch` of `_helper_executable` | `CodexAdapterOptions.guestInterpreter` |
| `python -m petrus.motus.worker` with `codex_worker_support` | this test binary re-executed as a Local Worker (`PETRUS_CODEX_TEST_WORKER`), with the same registry name and the same withhold-reply marker |

The fake `codex` runs under the pinned CPython (`pythonExecutable`). The
fake Gondolin SDK runs under the system `node`. As upstream, the guest
helper in the Gondolin lane runs under `/usr/bin/python3`.

## `tests/petrus/agenticus/runtime/test_codex.py` (41 functions, 54 cases)

| Upstream test | Notes |
| --- | --- |
| `test_exact_descriptors_and_opaque_values_hide_provider_bodies` | `__all__` becomes the module export list: the spec checks that `Petrus.Agenticus.Runtime.Codex` does not export the Gondolin Activity name or adapter. |
| `test_invocation_hides_prompt_and_requires_exact_file_auth_profile` | |
| `test_jsonl_protocol_fails_closed` `[events0-0-codex-lifecycle]`, `[events1-0-exit-inconsistent]`, `[events2-0-missing-agent-message]`, `[events3-1-codex-lifecycle]` | |
| `test_jsonl_uses_latest_sanitized_completed_agent_message` | |
| `test_jsonl_rejects_protocol_drift_and_malformed_items` `[middle0-unknown-event]`, `[middle1-malformed-error]`, `[middle2-malformed-item]`, `[middle3-duplicate-item-terminal]` | |
| `test_private_helper_stages_collects_and_scrubs_one_rollout` | Runs the shipped `_HELPER_SOURCE` under the pinned CPython. |
| `test_helper_rejects_foreign_thread_symlinks_and_oversize_rollout` | |
| `test_scrub_removes_but_reports_symlink_invariant_violation` | |
| `test_probe_freezes_exact_installation_and_resolved_executable` | |
| `test_probe_reports_absence_version_drift_and_protocol_drift` | |
| `test_snapshot_mismatch_rejects_before_connection_materialization` | |
| `test_fresh_turn_uses_real_local_private_roots_and_publication_order` | |
| `test_hyphen_prefixed_prompt_cannot_be_reparsed_as_a_codex_option` | |
| `test_native_rollout_continues_in_replacement_local_attachment` | |
| `test_provider_failure_checkpoints_auth_and_returns_native_continuation` | |
| `test_ambiguous_or_malformed_turn_releases_without_publication` (5 ids) | Same ids: `[timeout-2-1000000-command-timeout]`, `[command-signal-…]`, `[output-overflow-2-512-…]`, `[malformed-jsonl-…]`, `[oversize-rollout-…-collect-failed]`. |
| `test_cancellation_wins_before_candidate_publication` | |
| `test_cancellation_wins_while_candidate_bodies_are_still_being_stored` | |
| `test_publication_claim_makes_later_cancellation_too_late` | |
| `test_lookup_first_duplicate_and_changed_request_conflict` | |
| `test_operation_identity_includes_the_exact_claimed_continuation_envelope` | |
| `test_real_connection_custody_and_local_motus_route_refresh_and_cleanup` | Real `AgentConnectionCustody` over SQLite storage and a private-file materializer. |
| `test_stale_connection_fence_releases_before_provider_execution` | |
| `test_connection_cleanup_uncertainty_blocks_candidate_result` | |
| `test_private_cleanup_uncertainty_blocks_candidate_result` | |
| `test_expired_deadline_creates_no_connection_or_runtime_state` | |
| `test_codex_runtime_import_has_no_optional_provider_dependency` | The import blocker becomes a check that the library's `build-depends` names no optional provider SDK. |
| `test_gondolin_lane_reuses_one_episode_territory_across_replacement_operation_and_resume` | |
| `test_gondolin_episode_releases_to_reconstructed_host_custody_then_reclaims_exact_lease` | |
| `test_gondolin_retained_lease_is_reclaimed_and_released_by_a_replacement_host_process` | The replacement host process is the reference itself: the pinned CPython runs the upstream snippet against the Haskell-written retention ledger and Gondolin registry. This is a cross-language interop test. |
| `test_gondolin_activity_inline_retry_keeps_host_owned_episode_territory` | |
| `test_gondolin_runtime_service_replays_terminal_to_replacement_local_worker` | The first Worker is killed by its exact PID after the terminal is durable and the reply is withheld. A replacement Worker collects the replayed terminal. |
| `test_gondolin_activity_refuses_unfenced_or_stale_requests_before_runtime_start` | `EqualityString` is a plain string here (see divergences). |
| `test_gondolin_lane_rejects_guest_version_drift_before_materialization` | |
| `test_gondolin_lane_requires_its_exact_guest_helper_before_materialization` | |
| `test_gondolin_lane_private_probe_failure_cleans_and_never_qualifies_or_materializes` `[import]`, `[export]`, `[delete]`, `[cleanup]` | |
| `test_gondolin_private_probe_cleanup_drains_before_host_retention_export` | The waits for the probe to enter cleanup and for the fence are 10 s, not 1 s, so a loaded machine cannot fail them; the ordering asserted is the same. |
| `test_gondolin_lane_failed_reprobe_revokes_only_that_exact_attachment` | |
| `test_gondolin_lane_cancellation_closes_the_vm_discards_output_and_still_settles` | |
| `test_gondolin_runtime_service_fences_frames_conflicts_restart_and_redacts` | |
| `test_gondolin_runtime_activity_client_renews_custody_and_rejects_malformed_terminal` | |

### Verbatim and interop examples (not in the reference)

- `ships the reference's exact _HELPER_SOURCE`: `data/codex_helper.py`
  equals `codex._HELPER_SOURCE`.
- `ships the reference's exact fake codex and fake Gondolin SDK`: re-running
  `extract.py` reproduces the committed templates.
- `keeps the reference's exact runtime service DDL and error set`: `_DDL`,
  `_ERRORS`, the Activity name, the environment variable names and the frame
  bounds.
- `interop: the reference validates a Haskell runtime ledger and its
  terminals, and the reverse`: the Haskell service writes a ledger
  (`operation-failed` from a live request, plus one inserted success
  terminal). The reference's `_validate_ledger` accepts the file, and its
  `_parse_terminal` accepts every stored terminal. In the other direction,
  the reference creates a ledger with its own `_DDL`, a terminal row and an
  `executing` row. The Haskell service opens it, validates it and rewrites
  the interrupted row to the reference's exact `operation-indeterminate`
  terminal bytes.
- `interop: the reference's Activity client and Worker replay through the
  Haskell runtime service`: the replacement-Worker scenario again, with the
  reference's own `python -m petrus.motus.worker` and
  `codex_worker_support` registry as both Workers. The Haskell side runs
  the runtime service and Local Dispatch.

## Differential corpus

`differential/hosts_corpus.py` (seed 4242) writes the `codex` section of
`differential/hosts_corpus.json`. `HostsDifferentialSpec` replays it. Every
case must give the same value or the same `{class, message}` refusal:

| Section | Cases | What it covers |
| --- | ---: | --- |
| `text` | 308 | `_text` |
| `uuid` | 308 | `_uuid`, including braces, `urn:`, upper case and mutations |
| `rollout_path` | 208 | `_rollout_path` |
| `final_text` | 310 | `_final_text`, including three oversized messages |
| `payload` | 104 | `CodexContinuationPayloadV1` |
| `helper` | 214 | `_parse_helper`, both modes |
| `jsonl` | 712 | `_parse_jsonl` over generated and mutated streams and exit codes |
| `json_bytes` | 310 | `_json_bytes` wire bytes |
| `terminal` | 414 | `_parse_terminal`, with and without correlation |

The one tolerated difference is a lone surrogate escape (see
divergences, item 5).

Rerun:

```sh
cd upstream/petrus
.venv/bin/python -I -B ../../packages/petrus-agenticus-runtime/differential/hosts_corpus.py \
  ../../packages/petrus-agenticus-runtime/differential/hosts_corpus.json
```

## Benchmarks

See `bench/results-hosts.md`: `codex-jsonl-parse`, `codex-helper-parse`,
`codex-terminal-encode` and `codex-terminal-parse` are faster than the
reference, and so is a whole Local Turn (`codex-turn`), over interleaved
rounds. The A3 runtime service's round trip (`codex-a3-service-turn`) is
the thinnest row, close to level, with single rounds on either side.

## `tests/petrus/agenticus/runtime/test_codex_real.py` (2 functions)

Ported in `test/Petrus/Agenticus/Runtime/Live/CodexSpec.hs`, behind the
same gates (`PETRUS_CV16_CODEX_LIVE=1`, `PETRUS_CV16_CODEX_GONDOLIN_LIVE=1`).
Both run the real `codex` CLI against a real OpenAI account, and the A3 test
also boots a real Gondolin VM image. Without the gate they are pending;
with it, a missing CLI, `OPENAI_API_KEY`, Gondolin selection or auth file
fails where the reference skips. See
[docs/live-provider-acceptance.md](../../../docs/live-provider-acceptance.md);
no live run is recorded yet.
