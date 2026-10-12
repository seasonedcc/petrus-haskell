# Parity: Agenticus Hands

Upstream slice: `petrus/agenticus/hands/{contract,grants,gateway,conformance}.py`
and their tests under `tests/petrus/agenticus/hands/`.

| upstream module | Haskell module |
|---|---|
| `hands/contract.py` | `Petrus.Agenticus.Hands.Contract` |
| `hands/grants.py` | `Petrus.Agenticus.Hands.Grants` |
| `hands/gateway.py` | `Petrus.Agenticus.Hands.Gateway` |
| `hands/conformance.py` | `Petrus.Agenticus.Hands.Conformance` |
| `hands/workspace.py` | ported in `petrus-agenticus` as `Petrus.Agenticus.Hands.Workspace` (it spawns processes and Docker, so it is not core) |

## Unit tests

Every upstream test function is ported under a `describe` named after its
file, with an `it` labelled by the upstream function name and, for a
parametrised case, its pytest id in brackets.

### `test_contract_and_gateway.py`: 20 functions / 29 cases, all ported

`test/Petrus/Agenticus/HandsSpec.hs`

| upstream test | cases |
|---|---:|
| `test_closed_v1_requests_are_exact_strict_and_json_safe[method]` | 5 |
| `test_capability_scoped_hands_descriptor_is_host_registerable_and_exact` | 1 |
| `test_paths_fail_closed_before_policy[path]` | 6 |
| `test_unknown_malformed_and_bounds_are_safe` | 1 |
| `test_workspace_write_accepts_exact_1024_character_boundary` | 1 |
| `test_grants_are_exact_finite_monotonic_and_budgeted` | 1 |
| `test_write_roots_are_bounded_and_denied_roots_take_precedence` | 1 |
| `test_write_root_matching_uses_segments_and_denial_overrides_exact_path` | 1 |
| `test_all_direct_rejections_are_pre_crossing_and_flat` | 1 |
| `test_foreign_episode_is_rejected_before_adapter_crossing` | 1 |
| `test_staged_write_commits_once_and_post_fence_discards` | 1 |
| `test_provider_exception_is_sanitized_and_evidence_is_bounded` | 1 |
| `test_model_projection_preserves_semantics_without_attachment_custody` | 1 |
| `test_exact_retransmission_is_terminal_and_conflict_fails_loud` | 1 |
| `test_concurrent_exact_duplicates_single_flight` | 1 |
| `test_call_ledger_and_grant_exhaustion_are_budget_not_stale` | 1 |
| `test_malformed_adapter_result_is_a_typed_provider_error` | 1 |
| `test_abandoned_primary_allows_an_exact_waiter_to_reclaim_without_key_error` | 1 |
| `test_authority_target_deadline_abort_and_grant_postchecks_fail_closed` | 1 |
| `test_claimed_call_is_drained_before_attachment_cleanup_can_start` | 1 |

The concurrency tests use real threads (`async`) and `MVar` rendezvous
points in place of upstream's `threading.Event`s.  Upstream's drained-cleanup
test opens its race window inside the adapter.  The Haskell twin opens the
window inside the call's first fence snapshot instead: that is the earliest
point after the claim at which the test can observe the in-flight call, and
it is still before adapter entry.  The assertions match upstream's: `drain`
has not returned while the call is claimed; it returns `True` once the call
publishes; and the adapter was entered exactly once.

### `test_conformance.py`: 4 functions / 5 cases, all ported

`test/Petrus/Agenticus/Hands/ConformanceSpec.hs`

| upstream test | cases |
|---|---:|
| `test_es049_two_episode_trace_and_gateway_report_are_exact` | 1 |
| `test_premature_marker_is_a_step_and_never_crosses_hands` | 1 |
| `test_abort_and_deadline_fail_policy_closed_while_stale_results_are_ignored[aborted\|deadline]` | 2 |
| `test_turn_and_append_budgets_are_independently_finite` | 1 |

The ES-049 report is compared exactly: the trace, counters and evidence.

### `test_workspace.py`: 3 functions, ported in `petrus-agenticus`

`test_local_workspace_adapter_runs_complete_public_motus_route`,
`test_binary_output_preserves_the_public_utf8_byte_bound` and
`test_docker_workspace_adapter_and_binding_run_the_same_public_hands_route`
exercise `hands/workspace.py`, which needs the Motus execution layer. It
lives in `petrus-agenticus` as `Petrus.Agenticus.Hands.Workspace`. The
mapping and its differential corpus are in that package's PARITY.md.

## Differential corpus

`differential/hands_corpus.py` writes `differential/hands_corpus.json`
(format `petrus-haskell.agenticus.hands-differential` v1, seed
`random.Random(49)`, deterministic, about 2.3 MB).
`test/Petrus/Agenticus/Hands/DifferentialSpec.hs` replays it exactly, as four
examples:

| section | size | compared |
|---|---:|---|
| `requests` | 943 | `parse_tool_request` normalised request, or rejection category + detail, plus the salvaged `(call_id, attachment_id)` of an unparsed request |
| `results` | 177 | `ToolResult`/`ToolError` `to_data` and `to_model_data` bytes (`json.dumps` default), or the refusal class + message |
| `grants` | 131 cases × 14 write probes | `CapabilityGrant` construction or refusal, `permits` for every method, `permits_write_path` per probe |
| `sessions` | 50 sessions, 2 250 steps | scripted `HandsGateway` sessions; each step's result bytes or raised class + message, then final counters and evidence |

Session steps mix `submit` (fresh, exact replay and conflicting replay),
grant open/close, fence changes, clock moves, target-currency flips, ledger
closes and stage cleanup.  The session adapter has deterministic side effects
keyed by path prefix: raising, oversize and malformed outputs, a digest skew,
failed discards, and late, closing, aborting and regranting writes.  Every
detail string the gateway can emit appears in the corpus.  During
development, deliberate mutations of the gateway were confirmed to make the
differential fail, and each was reverted.

Regenerate:

```sh
cd upstream/petrus && .venv/bin/python ../../packages/petrus-agenticus-core/differential/hands_corpus.py
```

## Benchmarks

`bench/Bench/Hands.hs` and `bench/python_hands.py`, benchmark id
`agenticus-hands`.  Results and rerun commands are in
`bench/results-hands.md`.

## Gaps

- `workspace.py` and `test_workspace.py` are ported in `petrus-agenticus` (see above).
- Upstream `isinstance` checks on already-typed arguments have no Haskell
  equivalent; see `divergences/hands.md`.
