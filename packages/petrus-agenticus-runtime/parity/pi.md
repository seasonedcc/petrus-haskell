## `tests/petrus/agenticus/runtime/test_pi.py` (61 functions, 105 cases)

Modules: `Petrus.Agenticus.Runtime.Pi` (`pi.py`) and
`Petrus.Agenticus.Runtime.PiRecovery` (`pi_recovery.py`). Spec:
`test/Petrus/Agenticus/Runtime/PiSpec.hs`. Fixtures:
`test/Petrus/Agenticus/Runtime/PiSupport.hs`.

Every pytest id is an `it` label, parameters included. All 105 cases pass.

**Helpers and fixtures.**

- The verbatim helpers `pi_helper.mjs`, `pi_application_helper.mjs` and
  `pi_model_phase_helper.mjs` ship under `data/` as `data-files`.
- `test/fixtures/pi/extract.py` extracts the JavaScript fixtures that
  `test_pi.py` embeds as strings: the fake SDKs and the forged helpers.
- The fixtures run on the system `node` without any npm package. When `node`
  is absent, those cases are pending, not failed.

**Ported fixtures.** Each fixture is ported one to one:

- the continuation and Turn stores;
- connection custody, with crypton AES-256-GCM key operations;
- the scripted helper clients and the factory;
- the Territory wrapper;
- the rig and the invocation builder.

Where the reference monkeypatches a private method, the port installs the
same behaviour through an explicit hook. Item 2 of `divergences/pi.md` lists
them.

| Upstream test | Cases | Notes |
| --- | ---: | --- |
| `test_import_has_no_node_or_npm_dependency` | 1 | The reference imports the module in a subprocess whose `subprocess.run` raises. Haskell imports have no effects, so the spec checks the equivalent: a freshly built adapter has no `node`, SDK, installation or helper factory until `probe` runs. |
| `test_invalid_subscription_authority_is_rejected_before_activation` | 5 |  |
| `test_native_resume_preserves_identity_and_extends_opaque_jsonl` | 1 |  |
| `test_payload_rejects_noncanonical_identity` | 3 |  |
| `test_private_node_helper_advertises_only_the_fresh_or_resumed_operations_current_grant` | 4 | Real `node`, fake SDK. |
| `test_private_node_helper_imports_and_exports_native_subscription_auth` | 12 | Real `node` over `subscription_sdk.mjs`. |
| `test_recovery_atomically_classifies_every_preexisting_execution` | 1 |  |
| `test_uncertain_subscription_run_releases_activated_lease_without_checkpoint` | 1 |  |
| `test_cancel_deadline_redelivery_conflict_and_too_late_claim` | 2 |  |
| `test_native_jsonl_is_complete_strict_and_has_one_matching_header` | 4 |  |
| `test_framed_native_a4_resume_excludes_episode_custody_from_exact_jsonl_prefix` | 1 | Real `node`; the installation is swapped through `modifyAdapterRuntime`. |
| `test_private_node_helper_routes_the_provider_tool_identity_through_hands` | 3 | Real `node` over the verbatim `pi_helper.mjs` and the fake SDK `framed_tool_sdk.mjs`. |
| `test_clean_subscription_provider_failure_checkpoints_auth_without_turn_publication` | 1 |  |
| `test_invalid_returned_subscription_authority_requires_reauthorization` | 4 |  |
| `test_subscription_storage_or_checkpoint_failure_publishes_no_references` | 1 |  |
| `test_native_a4_rechecks_publication_admission_after_remote_lookup` | 4 | The stall goes through `PiAdapterHooks` and the clock through `setAdapterClock`. |
| `test_helper_construction_refuses_a_grant_replaced_after_initial_validation` | 1 | The factory is replaced through `modifyAdapterRuntime`. |
| `test_canaries_never_render_log_or_error` | 1 | The port has no logging, so `caplog` has no counterpart. The renders of the adapter, the invocation, the operation and its result are checked for every canary. |
| `test_native_a4_publication_claim_makes_later_cancellation_too_late` | 1 | The custody fake's `beforeAdmit` hook replaces the patched `admit`. |
| `test_private_client_rejects_auth_on_the_wrong_terminal_frame` | 3 | Real `node` over `wrong_auth_helper.mjs`. |
| `test_native_a4_resumes_only_continuation_after_settled_gondolin_replacement` | 1 |  |
| `test_private_node_helper_rejects_empty_or_unknown_advertised_tool_sets` | 2 | Real `node`. The reference rewrites `client._start`; the port calls `setSubprocessStartFrame`. |
| `test_provider_and_cleanup_failures_publish_no_references` | 2 |  |
| `test_subscription_reserves_publication_time_before_materializing_authority` | 1 | The config is replaced through `setAdapterConfig`. |
| `test_thread_start_failure_rolls_back_registration` | 1 | `PiAdapterHooks` replaces the monkeypatch. |
| `test_private_node_helper_rejects_custody_bearing_model_result` | 1 | Real `node`, fake SDK. |
| `test_cc_patch_lane_requires_qualified_extension_before_authority` | 1 | The installation is replaced through `modifyAdapterRuntime`. |
| `test_fresh_success_has_exact_custody_and_private_invocation` | 1 |  |
| `test_native_territory_profile_defaults_local_and_rejects_unknown` | 1 |  |
| `test_private_client_keeps_unknown_tools_outside_the_closed_protocol` | 1 | Real `node` over `forged_unknown_tool_helper.mjs`. |
| `test_native_territory_profile_selects_exact_descriptor_and_capabilities` | 3 |  |
| `test_subscription_stale_attachment_after_run_prevents_checkpoint_and_result_publication` | 1 | `PiAdapterHooks` replaces the monkeypatch. |
| `test_stale_or_malformed_subscription_checkpoint_publishes_no_result` | 2 | The reference's malformed checkpoint is `object()`. A typed checkpoint cannot be another type, so the malformed case returns a publication for another operation id (`<id>.malformed`), which the adapter refuses the same way. |
| `test_lost_ledger_acknowledgements_retry_without_changing_the_result` | 1 | A wrapping ledger persists the armed call, then throws, losing the acknowledgement. |
| `test_native_a4_post_run_lease_drift_releases_authority_without_publication` | 1 | The drift is armed from the scripted client's `afterRun` hook. |
| `test_close_persists_a_naturally_settled_result_before_cleanup` | 1 |  |
| `test_subscription_spawn_failure_releases_before_activation` | 1 | The factory's `failCreate` flag. |
| `test_replayed_operation_obeys_close_then_wait_contract` | 1 |  |
| `test_private_client_keeps_gateway_authoritative_for_a_forged_known_tool` | 1 | Real `node` over `forged_known_tool_helper.mjs`. |
| `test_native_a4_rejects_cross_profile_resolution_and_lease_before_authority` | 1 | The reference mutates a frozen lease with `object.__setattr__`. The test Territory relabels its leases and attachments and can drift its lookup (`Territory.drift`). |
| `test_subscription_success_checkpoints_rotated_native_auth_after_verified_cleanup` | 2 |  |
| `test_native_auth_protocol_rejects_noncanonical_or_oversized_frames` | 3 |  |
| `test_native_a4_rejects_cross_territory_resume_with_a_different_project_binding` | 1 |  |
| `test_native_a4_cancellation_wins_while_remote_publication_lookup_is_stalled` | 2 | The reference monkeypatches `_binding_current`. The port installs the same stall through `PiAdapterHooks`. |
| `test_cc_patch_lane_rejects_native_subscription_descriptor_before_authority` | 1 |  |
| `test_operation_ledger_refuses_a_second_live_writer` | 1 |  |
| `test_restart_classifies_execution_and_replays_without_adapter_access` | 1 |  |
| `test_subscription_missing_returned_auth_requires_reauthorization` | 1 |  |
| `test_durable_fingerprint_ignores_reconstructed_fences_but_rejects_stable_route_change` | 1 |  |
| `test_descriptors_pins_and_reprs_are_exact_and_opaque` | 1 |  |
| `test_resolution_stale_lease_provider_and_expired_deadline_fail_before_authority` | 1 | The Territory's `lookupOverride` replaces a patched provider lookup. |
| `test_recovered_runtime_persists_before_dispatch_and_wait_publication` | 1 | `newPiRecoveredRuntimeWith` and a `PiAdapterSurface` override replace the patched adapter methods. |
| `test_real_refresh_custody_checkpoints_or_requires_reauthorization_after_activation` | 1 |  |
| `test_native_jsonl_is_preserved_without_rewriting` | 1 |  |
| `test_subscription_auth_export_with_uncertain_helper_cleanup_is_not_checkpointed` | 2 |  |
| `test_cancelled_close_without_a_local_receipt_is_durably_indeterminate` | 1 | `PiAdapterSurface` override. |
| `test_adapter_evicts_only_closed_operation_receipts` | 1 |  |
| `test_completed_replay_conflict_acknowledgement_watermark_and_eviction` | 1 |  |
| `test_output_storage_failure_and_release_uncertainty_remove_candidate_refs` | 1 |  |
| `test_subscription_deadline_after_activation_releases_without_checkpoint` | 1 |  |
| `test_start_failure_and_ledger_cleanup_recovery_are_safe_and_secret_free` | 1 | `PiAdapterSurface` override. |

`test_pi_real.py` (2 functions) calls real provider APIs. It is out of scope.

### Differential corpus

`differential/pi_corpus.py` writes two files:

- `differential/pi_corpus.json`;
- `differential/pi_reference_ledger.sqlite3`, the ledger file the reference
  wrote.

`test/Petrus/Agenticus/Runtime/PiDifferentialSpec.hs` replays the corpus in
eight examples:

- **Validators.** 226 cases over `_uuid`, `_text`, strict base64,
  `_validate_native_auth`, `_decode_native_auth`, `_validate_session`,
  `_strict_load`, `_working_binding` and `PiContinuationPayloadV1`. There
  are 62 accepted inputs and 164 refusals: 139 `ValueError`, 11
  `binascii.Error`, 11 `JSONDecodeError` and 3 `UnicodeDecodeError`. Each
  case must give the same value, or the same class and message. A
  `JSONDecodeError` only needs a `ValueError`-family refusal.
- **Wire frames.** These are the exact bytes `_SubprocessClient._write`
  sends:
  - 80 `start` frames: api-key and subscription, fresh and resumed, five
    prompts that include control characters, U+2028, U+FEFF and astral
    characters, and four grant sets;
  - 10 `tool_result`, `abort` and arbitrary frames, including floats, big
    integers, escapes, and NaN and infinity refusals;
  - 4 frames against a 64-byte bound (`frame-overflow`).
- **Fingerprints.** 13 `pi_durable_work_fingerprint` cases over every
  identity input. Three of them are refused: the empty, the NUL-bearing and
  the oversized prompt.
- **Records.** 198 `PiOperationRecord` constructions (seed 9091): 72
  accepted and 126 `ValueError`. They mutate one field or two of the
  settled and executing bases, including Unicode-digit and signed or
  prefixed fingerprints, which `int(value, 16)` accepts.
- **Ledger.**
  - A 33-step scripted session. Its records and refusals must match, and it
    must leave the same `sqlite_master` (DDL text), `table_info`, rows,
    `sqlite_sequence` and journal mode.
  - A 9-step reopen-and-recover script, with the same post-recovery dump.
  - The reference-written file must cross-open, dump and recover
    identically.
  - 20 raw row mutations of that file (bad enums, codes, fingerprints,
    `BLOB` and `REAL` cells, deleted and renumbered rows) must give the same
    `lookup` and `records` refusal or projection.

The corpus found four port bugs, all now fixed: lone surrogate escapes in
`_strict_load`, the `UnicodeDecodeError` message, the order of the
non-ASCII base64 check, and `BLOB` and `REAL` ledger cells. One known
divergence remains, item 6 of `divergences/pi.md`.

Rerun:

```sh
cd upstream/petrus
.venv/bin/python ../../packages/petrus-agenticus-runtime/differential/pi_corpus.py \
  ../../packages/petrus-agenticus-runtime/differential/pi_corpus.json \
  ../../packages/petrus-agenticus-runtime/differential/pi_reference_ledger.sqlite3
```

### Benchmarks

See `bench/results-pi.md`:

- Strict frame decoding is 4.5 times faster than the reference.
- The SQLite ledger cycle is 1.1 times faster.
- Session validation and the fingerprint are on par.
- `start`-frame encoding is half the reference's speed, because of
  `petrus-json`'s encoder.

## `tests/petrus/agenticus/runtime/test_pi_model_phase.py` (25 functions, 45 cases)

Module: `Petrus.Agenticus.Runtime.PiModelPhase` (`pi_model_phase.py`), with
the verbatim `data/pi_model_phase_helper.mjs`. Spec:
`test/Petrus/Agenticus/Runtime/PiModelPhaseSpec.hs`.

Every pytest id is an `it` label, parameters included. 44 cases pass.
`test_exact_installed_model_phase_probe` is pending, because it needs the
exact Pi packages under `/tmp/petrus-pi-a2-probe`. The reference skips it for
the same reason. When those packages are present, the case runs in full.

**Fixtures.**

- `Custody`, `Operations`, the scripted `Client` and `Factory`, and the `Rig`
  are ported one to one. The custody and operation flags are `IORef`s.
- `test/fixtures/pi/extract_model_phase.py` extracts `write_fake_coding`'s
  fake SDK verbatim, as `test/fixtures/pi/model_phase_coding.mjs`.
- The subprocess cases run the system `node` over the reference's inline
  helper scripts, which are written to a temporary directory.
- `RealFactory` is `subprocessPhaseFactory {isSubprocess = False}`, so the
  adapter does not require a probe. The reference gets the same effect
  because its `RealFactory` is not an instance of `_SubprocessFactory`.

**Notes on individual tests.**

| Function | Cases | Notes |
| --- | ---: | --- |
| `test_payloads_publication_and_config_are_strict_and_bounded` | 1 | The reference passes `timeout=True`. The `Double` field cannot hold a bool, so 0, -1, NaN and infinity are refused with the same message instead. |
| `test_candidate_preserves_stop_optional_private_fields_and_source_order` | 5 | |
| `test_candidate_rejects_unsupported_terminal_stops` | 3 | |
| `test_success_cleans_and_releases_before_atomic_private_publication` | 1 | |
| `test_phase_one_resume_adds_observation_after_prior_continuation` | 1 | |
| `test_phase_two_injects_exact_ordered_results_without_observation` | 1 | |
| `test_result_identity_mismatch_fails_before_authority_use` | 1 | |
| `test_failures_release_authority_and_publish_nothing` | 6 | |
| `test_materialization_fence_mismatch_releases_without_provider_use` | 3 | |
| `test_not_ready_connection_is_rejected_at_construction` | 2 | |
| `test_private_load_failure_and_state_mismatch_are_sanitized_pre_authority` | 1 | `object.__setattr__(rig.config, ...)` becomes `modifyModelPhaseConfig`. |
| `test_stale_activity_claim_rejects_before_authority` | 1 | |
| `test_malformed_candidate_and_proposal_overflow_publish_nothing` | 1 | |
| `test_candidate_rejects_malformed_public_assistant` | 5 | |
| `test_duplicate_tool_call_identity_is_rejected_before_publication` | 1 | |
| `test_subprocess_rejects_duplicate_post_terminal_and_noncanonical_frames` | 3 | Real `node`. |
| `test_subprocess_rejects_a_relative_node_before_launch` | 1 | |
| `test_subprocess_deadline_kills_the_helper_group_and_discards_stderr` | 1 | Real `node`. |
| `test_subprocess_heartbeat_refusal_stops_before_the_wall_deadline` | 1 | Real `node`. |
| `test_real_helper_runs_one_public_stream_with_declarations_and_no_tool_executor` | 1 | Real `node`, the verbatim helper and the fake SDK. The adapter attributes are set with `setModelPhaseNode`, `setModelPhaseSdkEntrypoint` and `setModelPhaseFactory`. |
| `test_real_helper_accepts_bounded_multiline_observation` | 1 | Same as the previous row. |
| `test_real_subprocess_requires_the_exact_installed_probe_before_authority` | 1 | |
| `test_activity_adapter_drives_the_real_static_net_to_completion` | 1 | `Petrus.Engine` with `agentNet`, an in-memory history store and the inline dispatch. |
| `test_helper_syntax_and_exact_hands_bounds` | 1 | `node --check` over the shipped helper. |
| `test_exact_installed_model_phase_probe` | 1 | Pending unless the qualification packages are installed. |

## `tests/petrus/agenticus/runtime/test_pi_application.py` (25 functions, 41 cases)

Module: `Petrus.Agenticus.Runtime.PiApplication` (`pi_application.py`), with
the verbatim `data/pi_application_helper.mjs`. Spec:
`test/Petrus/Agenticus/Runtime/PiApplicationSpec.hs`.

Every pytest id is an `it` label, parameters included. 39 cases pass. Two are
pending for the same reason the reference skips them:

- `test_exact_helper_core_loop_fake_stream_is_one_turn_delta_only_and_authority_free`
  needs the exact Pi packages under `/tmp/petrus-pi-a2-probe`;
- `test_exact_installed_application_package_probe` needs them too, and also
  `PETRUS_CV16_PI_APPLICATION_QUALIFY=1`.

**Fixtures.**

- `Continuations`, `Turns`, `Plan`, `Client`, `Factory`, `snapshot`, `Rig`
  and `claimed` are ported one to one. The custody is the shared
  `PiSupport.FakeCustody` (api-key, `anthropic`), seen through
  `applicationCustody`. Its `beforeAdmit` cell plays the reference's `admit`
  flag and its stalled `admit_result`.
- The rig relabels a local process provider to `gondolin` or `e2b` with
  `PiSupport.newTerritory`. As in the reference, it keeps one Episode
  attachment, the production Motus workspace adapter (test command
  `/bin/sh verify.sh`) and the real gateway.
- The reference's `object.__setattr__(lease, "provider", "e2b")` becomes the
  territory's `drift` cell, which makes the provider lookup report `e2b`.
  Either way `_binding_current` turns false. The wrapped `Client.run` is
  `Factory.afterRun`. The monkeypatched `_binding_current` is
  `ApplicationAdapterHooks.bindingCurrent`.
- `test/fixtures/pi/extract_application.py` extracts the seven JavaScript
  fixtures verbatim. Two of them are f-strings over
  `delta = base64.b64encode(b"[]")` and are rendered with that value.
- Upstream, the three framed-protocol tests (`test_real_*`) need
  `/tmp/petrus-pi-a2-probe/node_modules/node/bin/node` and skip without it.
  The port runs them under the system `node` (v22.22.0 here) with the
  verbatim helper, so they run by default.

**Notes on individual tests.**

| Function | Cases | Notes |
| --- | ---: | --- |
| `test_exact_identities_capabilities_ownership_and_snapshots` | 1 | |
| `test_api_key_direct_catalog_is_exact` | 3 | |
| `test_subscription_and_codex_profiles_are_rejected` | 3 | |
| `test_seven_separate_operations_drive_policy_and_real_gateway` | 1 | `Petrus.Agenticus.Hands.Conformance.SevenStepEpisodePolicy` over the real gateway. |
| `test_gondolin_settles_before_e2b_and_continuation_crosses_without_authority_leak` | 1 | `dataclasses.replace(e2.adapter._config, ...)` becomes `setApplicationAdapterConfig`. |
| `test_closed_write_is_synthetic_and_crossing_flat` | 1 | |
| `test_shared_model_tool_result_projection_excludes_attachment_custody` | 1 | |
| `test_real_framed_helper_blocks_write_and_round_trips_permitted_read` | 1 | System `node`. The monkeypatched `to_model_data` becomes `ApplicationSubprocessOptions {modelData = toolResultToData}`. |
| `test_real_framed_tool_projection_preserves_prefix_without_attachment_custody` | 1 | System `node`. |
| `test_real_protocol_rejects_post_terminal_and_post_abort_frames_before_gateway` | 1 | System `node`. |
| `test_immutable_prior_transcript_plus_delta_and_payload_bounds` | 1 | `is raw` becomes byte equality. |
| `test_foreign_continuation_project_binding_and_claim_state_rejected` | 1 | |
| `test_resolution_grant_runtime_and_connection_bindings_reject_stale` | 1 | |
| `test_application_a5_post_run_lease_drift_releases_authority_without_publication` | 1 | |
| `test_helper_failures_do_not_publish` | 5 | |
| `test_cancellation_deadline_and_cleanup_failure_prevent_publication` | 1 | |
| `test_application_a5_cancellation_wins_while_remote_publication_lookup_is_stalled` | 2 | |
| `test_application_a5_rechecks_publication_admission_after_remote_lookup` | 4 | `adapter._clock` becomes `setApplicationAdapterClock`. |
| `test_application_a5_publication_claim_makes_later_cancellation_too_late` | 1 | |
| `test_publication_failures_return_no_references_and_release_authority` | 3 | |
| `test_idempotent_redelivery_and_operation_conflict` | 1 | `is first` becomes the operation's identity equality. |
| `test_unsupported_provider_model_or_territory` | 3 | |
| `test_package_source_versions_node_syntax_and_credential_free_probe_shape` | 1 | Runs `node --check` over the shipped helper. |
| `test_exact_helper_core_loop_fake_stream_is_one_turn_delta_only_and_authority_free` | 1 | Pending unless the qualification packages are installed. |
| `test_exact_installed_application_package_probe` | 1 | Pending, as upstream, unless the packages and the opt-in variable are present. |

No differential corpus or benchmark covers the application runtime. Its pure
pieces (the strict loader, base64 and the transcript bound) are the ones the
`test_pi.py` corpus already pins.

## `tests/petrus/agenticus/runtime/test_pi_a2_host.py` (24 functions, 27 cases)

Module: `Petrus.Agenticus.Runtime.PiA2Host` (`pi_a2_host.py`). Spec:
`test/Petrus/Agenticus/Runtime/PiA2HostSpec.hs`.

Every pytest id is an `it` label, parameters included. All 27 cases pass,
and none is pending.

**Fixtures.**

- `Keys`, `Plan`, `Client`, `Factory` and `Authority` are ported one to one.
  `Keys` wraps the shared AES-GCM `PiSupport.aesKeys` and counts `erase`.
  `Authority.supply` returns a `ScrubbedBytes`, and the completed-operation
  test checks that every supplied buffer is zeroed afterwards, as the
  reference checks its `bytearray`s.
- `_config` and `_start` take their keyword changes as small records
  (`Changes`, `StartOptions`). `_tar_with` writes the one-member ustar
  archive that `tarfile` writes, padded to a 10240-byte record.
- The reference's `/bin/true` (the allowed argv, the test command and the
  scripted shell call) becomes `/usr/bin/true` when `/bin/true` is absent,
  as it is on macOS. Upstream, those tests fail on macOS for that reason.
- `AttachFailure` and `UnverifiedDestroy` are record overrides of the local
  provider's `providerAttach` and `providerDestroy`. The reference's
  `monkeypatch.setattr(host._bodies, "publish", ...)` becomes
  `setPiA2HostHooks`.
- `host._provider`, `host._adapter`, `host._ledger`, `host._bodies`,
  `host._storage`, `host._fingerprint` and `host._territory_operation` are
  `hostProvider`, `hostAdapter`, `hostLedger`, `hostBodies`, `hostStorage`,
  `hostFingerprint` and `piA2TerritoryOperation`. `type(host._adapter._factory)`
  becomes `hostFactoryKind`.
- The two process tests run `python -c` against the test module upstream.
  Here they re-execute the test binary with `PETRUS_PI_A2_HOST_CHILD` set
  (`test/Main.hs` dispatches to `PiA2HostSpec.child`). The killed child is
  stopped with `SIGKILL` on its exact PID and must exit with `-9`. The
  reconstructed child ends with `exitImmediately`, the twin of `os._exit(0)`.

**Notes on individual tests.**

| Function | Cases | Notes |
| --- | ---: | --- |
| `test_config_and_composition_are_exactly_direct_pi_a2_local` | 1 | `LocalProcessEnvironment.provider = "foreign"` is the record update `providerName = "foreign"`. |
| `test_public_host_construction_boundaries_exclude_arbitrary_collaborators` | 1 | The `inspect.signature` and Protocol-instantiation checks are fixed by the Haskell types; the rest runs. |
| `test_start_requires_exact_safe_workspace_and_operation_policy` | 1 | The `bytearray` archive `TypeError` has no counterpart (the field is a `ByteString`). |
| `test_probe_is_authority_free_and_nonready_start_fails_before_admission` | 1 | |
| `test_completed_operation_commits_bodies_only_after_verified_cleanup` | 1 | |
| `test_start_archive_not_global_working_directory_is_episode_input` | 1 | |
| `test_per_start_policy_is_exact_attachment_authority` | 1 | |
| `test_policy_ceiling_rejection_does_not_burn_operation_identity` | 1 | |
| `test_continuation_and_second_operation_reuse_one_host_authorization` | 1 | |
| `test_continuation_workspace_mismatch_precedes_admission_and_can_be_corrected` | 1 | |
| `test_terminal_replay_precedes_probe_authority_and_territory` | 1 | |
| `test_concurrent_starts_serialize_one_shot_authority_and_dedupe_live_work` | 1 | Two `forkIO` threads in place of the thread pool; `is` becomes the operation's identity equality. |
| `test_close_fences_new_starts_and_cancels_active_operation` | 1 | |
| `test_indeterminate_close_prevents_late_waiter_publication` | 1 | |
| `test_changed_work_conflicts_before_probe_or_authority` | 1 | |
| `test_surviving_executing_record_becomes_indeterminate_without_authority` | 1 | |
| `test_killed_host_process_reopens_admitted_work_without_redispatch` | 1 | Child process: the test binary itself. |
| `test_reconstructed_host_requires_current_authority_for_new_work` | 4 | Child process: the test binary itself. |
| `test_pre_workspace_fingerprint_conflicts_without_authority_or_provider_work` | 1 | |
| `test_invalid_authority_is_consumed_once_and_replays_terminal_failure` | 1 | |
| `test_partial_attachment_construction_rolls_back_and_replays_clean_failure` | 1 | |
| `test_body_publication_failure_leaves_output_unreadable_and_operation_indeterminate` | 1 | `setPiA2HostHooks` replaces the monkeypatch. |
| `test_unverified_territory_cleanup_never_publishes_success` | 1 | |
| `test_private_state_root_rejects_unsafe_existing_mode` | 1 | |

**Storage.** The body store's nine SQL statements, the `pi_a2_bodies` DDL
among them, are byte-identical to the reference's. The comparison was made
with the reference's AST against the port's literals.

No differential corpus covers the host: its pure pieces are the fingerprint
(benchmarked as `pi-a2-fingerprint`) and the inner Pi pieces that the
`test_pi.py` corpus already pins. `bench/PiA2Bench.hs` and
`bench/python_pi_a2.py` are twins; see `bench/results-pi.md`.
