# petrus-agenticus parity

This package covers the kernel-composed layers of `petrus.agenticus`, as
pinned at `upstream/petrus` 3f85fc2: Agent-as-a-Net, the Motus attachment
binding, the Episode attachment and its retention ledger, and the Hands
workspace adapter.

Each `it` label in the Haskell specs is the upstream test name. Parametrized
tests also carry the pytest parameter id.

## `tests/petrus/agenticus/program/test_agent_net.py` (21 functions, 35 cases)

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

## Benchmarks

See `bench/RESULTS.md`. Agent-as-a-Net end-to-end runs are 6.9 times faster
than the reference, and LoopState round-trips are 2.4 times faster.
