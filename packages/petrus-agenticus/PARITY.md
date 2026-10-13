# petrus-agenticus parity

This package covers the kernel-composed layers of `petrus.agenticus`, as
pinned at `upstream/petrus` 3f85fc2: Agent-as-a-Net, the Motus attachment
binding, the Episode attachment and its retention ledger, and the Hands
workspace adapter.

Each `it` label in the Haskell specs is the upstream test name. Parametrized
tests also carry the pytest parameter id.

## `tests/petrus/agenticus/program/test_agent_net.py` (21 functions, 34 cases)

Module: `Petrus.Agenticus.Program.AgentNet`. Spec: `test/Petrus/Agenticus/AgentNetSpec.hs`.

The `run(script, hands, initial=...)` fixture is ported as `run`. It drives
the real Engine (`Petrus.Engine`) with an in-memory History, inline
dispatch and scripted model and Hands Activities. It collects every quiescent
prefix in the same way upstream does.

| Upstream test | Haskell | Notes |
| --- | --- | --- |
| `test_exact_descriptors_capabilities_and_serializable_envelopes` | same label | Checks `agentAsNetProgram` (Net-owned, fresh start, accepted and produced Continuation, no steering or evaluation), both capability descriptors and the envelope round trips. |
| `test_fresh_and_resumed_state_reference_contracts` | same label | |
| `test_exact_topology_activity_separation_and_done_token_completion` | same label | |
| `test_multi_tool_batch_is_sequential_and_one_activity_per_actual_call` | same label | |
| `test_unsupported_and_not_granted_are_pure_ordered_rejections` | same label | |
| `test_length_rejects_whole_batch_without_hands_and_returns_ordered_results` | same label | |
| `test_length_without_proposals_is_a_completed_provider_phase` | same label | |
| `test_proposals_are_discovered_from_content_not_the_stop_reason` | same label | |
| `test_provider_terminal_routes[error-failed, aborted-cancelled]` | same labels | |
| `test_hands_abort_cancels_after_current_call` | same label | |
| `test_phase_and_tool_budget_terminals` | same label | |
| `test_mid_batch_tool_budget_stops_before_a_second_hands_dispatch` | same label | |
| `test_blocked_then_allowed_batch_preserves_result_order` | same label | |
| `test_failed_hands_result_is_model_data_and_not_an_escaped_failure` | same label | |
| `test_results_are_supplied_to_exactly_one_following_model_phase` | same label | |
| `test_model_result_projection_has_exact_shape_and_known_error_categories[×13]` | same labels | |
| `test_model_result_error_vocabulary_is_the_hands_contract` | same label | |
| `test_payloads_and_all_loop_dimensions_are_bounded` | same label | Exact classes and messages, including the 4096-byte JSON bound and every dimension limit. |
| `test_history_has_model_and_hands_facts_without_custody_data` | same label | |
| `test_reconstruction_matches_every_committed_quiescent_prefix` | same label | The stored History must equal the Engine's records. Each quiescent prefix is then reloaded with `Engine.load`, and the reload must have no in-flight work and the same marking and status. |
| `test_static_net_module_has_no_provider_or_runtime_dependency` | same label | Reads the module source and forbids imports of provider bindings and of `Petrus.Agenticus.Runtime`. |

### Differential corpus

`differential/agent_net_corpus.py` writes `differential/agent_net_corpus.json`,
and the "differential/agent_net_corpus.json" block of `AgentNetSpec` replays
it. It checks the following:

- **Definition.** The net-definition bytes (`serialize_net_definition(project_net_definition(AGENT_AS_NET))`)
  and every handler and guard implementation URI.
- **Runs.** 16 named scripted runs plus 60 random ones (seed 20260). For
  each run, the Activity call sequence must match, every History record must
  match byte for byte (`json.dumps(encode_record(r))` against `encodeLine`),
  and the final status and terminal token must match.
- **Envelopes.** 2,469 `from_data` cases across Proposal, ModelResult (both
  shapes), LoopState, ModelSettlement, ToolWork and Terminal (seed 4049). Each
  case is a valid base or a mutation of one: a removed key, an extra key, or a
  weird value at each path. Each must produce the same `to_data` bytes or the
  same `{class, message}` refusal.

Rerun:

```sh
cd upstream/petrus
.venv/bin/python ../../packages/petrus-agenticus/differential/agent_net_corpus.py \
  ../../packages/petrus-agenticus/differential/agent_net_corpus.json
```

## `tests/petrus/agenticus/attachment/test_binding.py` (5 functions, 6 cases)

Module: `Petrus.Agenticus.Attachment.Binding`. Spec: `test/Petrus/Agenticus/BindingSpec.hs`.
These tests run against the real local process provider
(`Petrus.Motus.Execution.Providers.Local`).

| Upstream test | Haskell | Notes |
| --- | --- | --- |
| `test_outer_binding_shape_does_not_assume_motus` | same label | `ProviderManagedBinding` becomes an `AttachmentBinding` record with `motus = Nothing`. |
| `test_motus_binding_is_lookup_first_and_settles_exact_lease` | same label | |
| `test_motus_binding_discards_interrupted_output_but_still_destroys_the_territory[cancel, timeout]` | same labels | |
| `test_foreign_cleanup_evidence_never_verifies` | same label | The `monkeypatch` of `destroy` becomes a record override (`provider {providerDestroy = ...}`). |
| `test_open_attach_failure_cleans_the_claimed_lease_or_fails_uncertain` | same label | The `monkeypatch` of `attach` becomes a record override. The test checks that the secret canary never appears in the refusal. |

## `tests/petrus/agenticus/test_boundaries.py` (5 functions)

Spec: `test/Petrus/Agenticus/BoundariesSpec.hs`. These are structural checks
over the Haskell sources and cabal files of all three agenticus packages.

| Upstream test | Haskell | Notes |
| --- | --- | --- |
| `test_exact_ownership_packages_have_empty_namespaces` | same label | Every directory under `Petrus/Agenticus/` must be an ownership package (or `Internal`). The only top-level module allowed is `Error.hs`, and there is no `Petrus.Agenticus` facade module. |
| `test_root_import_has_no_facade_or_optional_provider_side_effects` | same label | Haskell imports have no side effects, so the check moves to the dependency graph. Core must not depend on the kernel (Engine, Impetus, DSL, Motus, execution), and no agenticus package may depend on a provider SDK binding. The test also asserts that the parser sees real dependencies, so the check cannot pass vacuously. |
| `test_impetus_and_motus_do_not_depend_on_agenticus` | same label | Checks both the cabal dependencies and the imports of every kernel package. |
| `test_agenticus_does_not_import_private_motus_or_its_own_root_facade` | same label | |
| `test_forbidden_universal_concepts_are_not_defined` | same label | No type, class or top-level function may be named `Agent` or `Session`. |

## `tests/project/test_package_boundaries.py` (1 of 20 functions, its runtime-service half)

Spec: `test/Petrus/Agenticus/BoundariesSpec.hs`, under the describe
`tests/project/test_package_boundaries.py`.

| Upstream test | Haskell | Notes |
| --- | --- | --- |
| `test_activity_worker_and_runtime_service_do_not_own_retained_territory_lifecycle` | same label, "(runtime-service half)" | Upstream walks the AST of `_CodexGondolinActivityAdapter` and `_CodexGondolinRuntimeService` and forbids calls named `_release_to`, `begin_release`, `create`, `destroy`, `export`, `lookup`, `reclaim`, `release`, `retire` and `settle`. The port reads `Petrus.Agenticus.Runtime.CodexGondolin`, takes the top-level bindings of its "host-local Activity adapter" and "runtime service" sections, and follows them transitively through the module's other bindings. Comments and literals are stripped first. The Haskell names of the forbidden operations must not appear: attachment/binding `releaseTo`, `settle`, `release`, `retrySettlement`; custody `beginRelease`, `lookupCustody`, `reclaim`, `reclaimExactMotusBinding`, `retire`; provider `providerCreate`/`Destroy`/`Export`/`Lookup`. The module must also not import `Petrus.Agenticus.Attachment.Retention`. A planted source checks that the scanner sees a call made through a helper or with a qualified name, and ignores comments and strings. The Worker half (`petrus.motus.worker` never imports retention) belongs to petrus-motus. |

## `tests/petrus/agenticus/hands/test_workspace.py` (3 functions)

Module: `Petrus.Agenticus.Hands.Workspace`. Spec: `test/Petrus/Agenticus/WorkspaceSpec.hs`.
The adapter runs against the real local process provider and the real Hands
gateway.

| Upstream test | Haskell | Notes |
| --- | --- | --- |
| `test_local_workspace_adapter_runs_complete_public_motus_route` | same label | read, search, shell, staged write (commit and discard), run test, and the lease fence, all through `HandsGateway.submit`. |
| `test_binary_output_preserves_the_public_utf8_byte_bound` | same label | |
| `test_docker_workspace_adapter_and_binding_run_the_same_public_hands_route` | `[fake docker CLI]` and `[real docker, PETRUS_TEST_DOCKER=1]` | The reference skips the test unless Docker is reachable. The Haskell spec always runs the same route against `petrus-execution`'s fake Docker CLI (`test/fixtures/fake_docker.py`). The real-daemon variant is **pending** unless `PETRUS_TEST_DOCKER=1` is set. |
| (extra) | `constructor refusals` | Pins the constructor and operation refusal messages that the reference only reaches indirectly. |

### Differential corpus

`differential/workspace_corpus.py` writes `differential/workspace_corpus.json`.
The "differential/workspace_corpus.json" block of `WorkspaceSpec` replays:

- every bound constant (stage directory, read, search, stream and output limits);
- 1,508 `_bounded_text(data, limit)` cases over UTF-8 edge cases (truncated
  sequences, surrogates, overlongs, bytes above U+10FFFF);
- 200 `search` projections of raw grep output;
- 7 stage names and staged digests.

Rerun:

```sh
cd upstream/petrus
.venv/bin/python ../../packages/petrus-agenticus/differential/workspace_corpus.py \
  ../../packages/petrus-agenticus/differential/workspace_corpus.json
```

## `tests/petrus/agenticus/attachment/test_episode.py` (9 functions, 11 cases)

Module: `Petrus.Agenticus.Attachment.Episode`. Spec: `test/Petrus/Agenticus/EpisodeSpec.hs`.

| Upstream test | Haskell | Notes |
| --- | --- | --- |
| `test_settlement_is_ordered_and_successor_is_a_new_episode_attachment` | same label | |
| `test_unverified_custody_blocks_progress_until_destroy_retry_verifies` | same label | |
| `test_raising_binding_settlement_records_uncertain_custody_and_can_retry` | same label | |
| `test_settlement_waits_for_every_claimed_call_before_export_and_destroy` | same label | The reference delays `GrantLedger.consume` with a monkeypatch. The Haskell ledger cannot be patched, so the claimed call blocks inside the scripted adapter instead. Either way the call is in flight when settlement starts, and the assertions are the same. The reference releases the call without waiting for settlement to close admission; the port waits until the attachment fence reports admission closed before releasing, because otherwise the call can finish first and succeed (the CI flake this fixed: on a busy runner, or always on `-N4`). |
| `test_concurrent_settlement_cannot_export_or_destroy_one_binding_twice` | same label | |
| `test_cancellation_is_serialized_before_settlement_and_is_too_late_afterward` | same label | |
| `test_cancellation_cannot_enter_after_settlement_has_started` | same label | |
| `test_local_episode_attachment_composes_gateway_archive_cleanup_and_successor_fences` | same label | Runs against the real local process provider. |
| `test_attachment_epoch_is_exactly_positive[0, -1, True]` | `[0]`, `[-1]` | The `True` case cannot be written: the epoch is an `Integer`, so the type checker refuses a `Bool`. |

## `tests/petrus/agenticus/attachment/test_retention.py` (15 functions, 18 cases)

Module: `Petrus.Agenticus.Attachment.Retention`. Spec: `test/Petrus/Agenticus/RetentionSpec.hs`.
These tests run against the real local process provider and a real SQLite
ledger on disk.

| Upstream test | Haskell | Notes |
| --- | --- | --- |
| `test_retained_lease_reclaims_into_a_distinct_episode_and_retires_exactly` | same label | |
| `test_recovery_retires_incomplete_release_instead_of_reusing_it` | same label | |
| `test_corrupt_archive_never_reclaims_and_preserves_exact_cleanup_obligation` | same label | |
| `test_missing_retained_lease_never_falls_through_to_creation` | same label | `provider.create` is replaced by a record override (`providerCreate`). |
| `test_foreign_lookup_remains_retryable_until_exact_retirement_is_verified` | same label | `provider.lookup` is replaced by a record override (`providerLookup`). |
| `test_expired_custody_moves_to_exact_retirement_instead_of_reclaim` | same label | |
| `test_expiry_during_export_never_acknowledges_retention` | same label | `export` is replaced by a record override (`providerExport`). |
| `test_custody_database_has_one_live_writer` | same label | The second open in the same process is refused by the `flock` writer fence. |
| `test_release_closes_operation_admission_and_waits_before_export` | same label | |
| `test_one_provider_operation_cannot_have_two_live_custody_ids` | same label | |
| `test_reclaim_refuses_source_identities_without_changing_retained_custody[episode, attachment]` | same labels | |
| `test_malformed_nonidentity_state_becomes_retirable_but_malformed_identity_quarantines` | same label | |
| `test_nontext_destruction_identity_quarantines_without_provider_cleanup[operation_id, provider, lease_id]` | same labels | |
| `test_recovery_fences_an_attached_lease_instead_of_reconstructing_active_work` | same label | |
| `test_retirement_retries_unverified_cleanup_and_destroy_before_commit` | same label | The reference swaps the private `custody._write` for one that raises `OSError("crash")` after the real destroy. The Haskell ledger has no patchable method, so the overriding `providerDestroy` holds `BEGIN EXCLUSIVE` on a second connection after the real destroy. The tombstone write then really fails, as `OperationalError`, after the 5-second busy timeout. The rest of the test (the lease is gone and a retry reaches `retired`) is unchanged. |

### Differential corpus

`differential/retention_corpus.py` (seed 6062) writes
`differential/retention_corpus.json` and `differential/retention_fixture.db`.
`test/Petrus/Agenticus/RetentionDifferentialSpec.hs` replays them:

- **Schema.** A fresh Haskell ledger's `sqlite_master` rows (the exact DDL
  text) and the `table_info` of `territory_custody` (column order, types,
  `NOT NULL` and primary key) equal the reference's.
- **Cross-open.** The Haskell custody opens the reference-written fixture
  ledger (one row in each of five phases) and decodes every record the way
  the reference does.
- **Capability JSON.** A Haskell `release` stores the same compact, sorted
  capability JSON as the reference.
- **Rows.** 1,156 mutated rows, each with typed cells (`null`, `int`,
  `real`, `text`, `blob`) as SQLite returns them. Each row covers a wrong
  storage class, an out-of-range value, a bad digest, an inconsistent phase,
  and so on. For each one, `_decode` must give the same record or the same
  `{class, message}` refusal, and `_salvage_corrupt` must give the same phase.

### Live ledger interop, both directions

`differential/retention_interop.py` is the reference's half of a live
exchange (`RetentionDifferentialSpec`, "live interop"), run under the pinned
interpreter on every test run:

- **Haskell writes, Python reads.** The Haskell ledger writes, over a real
  local provider, a record in every durable phase (`releasing`, `retained`,
  `claiming`, `attached`, `retiring` through an expired reclaim, `retired`),
  a retained record that expires before the reader's clock, and a retained
  record whose capability column is then corrupted. The reference opens a
  private copy and prints its `lookup` of every row, `records()`,
  `recover()` and `records()` again; these must equal the Haskell ledger's
  own reading of another copy of the same bytes (every record field, and
  the `StorageError` text where decoding refuses: the corrupt row's lookup
  and the first `records()`; `recover()` then salvages it to `retiring`).
- **Python writes, Haskell reads.** The reference writes the same records
  into a fresh ledger with `SqliteTerritoryCustody` and prints its own
  reading; the Haskell ledger opens the file and must read it identically.

So the reference's strict `_decode` (storage classes included) accepts every
row the Haskell ledger writes, and the reverse, beyond the committed
fixture.

Rerun:

```sh
cd upstream/petrus
.venv/bin/python ../../packages/petrus-agenticus/differential/retention_corpus.py \
  ../../packages/petrus-agenticus/differential
```

## Benchmarks

See `bench/RESULTS.md`. Haskell is faster than the reference on every row:
Agent-as-a-Net end-to-end runs, LoopState round-trips, and the retention
ledger's row decoding, `lookup` and `recover`. The last two are dominated
by SQLite itself, so their margins are the smallest. RESULTS.md gives the
figures.

## Gaps

- The real-Docker variant of the workspace route is pending unless
  `PETRUS_TEST_DOCKER=1` is set. The fake Docker CLI variant always runs.
- `test_attachment_epoch_is_exactly_positive[True]` has no Haskell
  counterpart; the type system rules it out.
