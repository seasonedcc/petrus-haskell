# hamsterdan-readiness parity

This file lists what this package ports from `upstream/hamsterdan` (pinned in
[UPSTREAM.md](../../UPSTREAM.md) at `5d382467`) and the evidence for each
piece.

Every expectation in the corpora was produced by the pinned Python running the
committed generator scripts in `scripts/`:

- `upstream/hamsterdan/.venv`
- Python 3.14.6
- pydantic 2.13.4

The Haskell suite compares bytes.

## Upstream source → Haskell

| Upstream | Haskell | Evidence |
| --- | --- | --- |
| `net_v5/topology.py` (`build_net_v5`, `seed_marking`, `GATES`, `DERIVED`) | `Hamsterdan.Readiness.NetV5.Topology`, re-exported by `Hamsterdan.Readiness.NetV5` | **Fingerprint gate:** `test/corpus/net_definition.json` and `net_definition.sha256`. The serialized net definition matches byte for byte, with sha256 `7e7d437b…9744`. The net has 111 places and 141 transitions. `seed_marking.jsonl` covers 16 subjects and delays, refusals included. `gates.json` holds every gate, its activity and its variants, in loop order. |
| `net_v5/folding.py` (hydration, `emit`, `route`, the error texts) | `Hamsterdan.Readiness.NetV5.Folding`, plus `NetV5.Py`, which reproduces the Python operator semantics and error texts the folds rely on | **Fold corpus:** `test/corpus/folds.jsonl`. It has 3292 fold calls over 109 transitions and all ten loops. 270 of them are refusals whose `firing_failure_text` must match. |
| `net_v5/{life,ci,esc,review,mutation,conversation,dashboard,reminders,readiness,startup}.py` | `NetV5.{Life,Ci,Esc,Review,Mutation,Conversation,Dashboard,Reminders,Readiness,Startup}`, which share the arc-order shorthands in `NetV5.Wiring` | The per-loop suites below and the fold corpus, grouped per loop. |
| `net_v5/gating.py` (`VariantPayloadConverter`, `VariantRoutingActivityHandler`, `DurablePublicationActivityHandler`, `IdentifiedInlineActivityHandler`, `wire_gates`) | `Hamsterdan.Readiness.NetV5.Gating` | **Gate-handler corpus:** the fold corpus also holds 221 `prepare`, 240 `project` and 4 `project_failure` calls. The produced invocation or tokens must match byte for byte. The 240 `project` rows route on `$variant`. Behavior is tested in `GatingSpec` and `InlineRecoverySpec`. |
| `net_v5/board.py` (`render_board`, `gate_facts`) | `Hamsterdan.Readiness.NetV5.Board` | **Board corpus:** `test/corpus/board.jsonl`. It has 1569 entry logs: the upstream scenarios plus seeded random and hostile logs. `render_board` and `repr(gate_facts(...))` must match byte for byte, and refusals must match their `firing_failure_text`. |
| `readiness/payloads.py` (`PydanticPayloadConverter`) | `Hamsterdan.Readiness.Payloads` (`decodeModel`, `encodeModel`, `pydanticPayloadConverter`) | `PayloadsSpec`. The contracts' admission and spelling are covered by the hamsterdan-contracts corpus. |

## Upstream tests

Every test module under `tests/unit/readiness/net_v5/` is ported, along with
the converter half of `tests/unit/readiness/test_payloads.py`.

- **Upstream counts:** a "function" is a `test_*` definition. A "case" is a
  collected test after `pytest.mark.parametrize`.
- **Haskell examples:** these are the hspec examples in the named spec file.
- **Harness:** the upstream test harness, `harness.py`, is ported as
  `test/Harness.hs`. Its fake world, gate activities, spawn, drive and pump
  helpers are all there.

| Upstream file | Functions | Cases | Haskell spec | Examples | Parametrization |
| --- | ---: | ---: | --- | ---: | --- |
| `test_startup.py` | 5 | 7 | `StartupSpec` | 7 | Two functions run with retryable and with unknown failures. |
| `test_lifecycle_loop.py` | 16 | 16 | `LifecycleSpec` | 16 | none |
| `test_ci_loop.py` | 21 | 21 | `CiSpec` | 21 | none |
| `test_escalation_loop.py` | 23 | 23 | `EscalationSpec` | 23 | none |
| `test_review_loop.py` | 33 | 36 | `ReviewSpec` | 36 | The seed-subject refusal runs over 4 subjects. |
| `test_mutation_loop.py` | 32 | 32 | `MutationSpec` | 32 | none |
| `test_conversation_loop.py` | 21 | 21 | `ConversationSpec` | 21 | none |
| `test_dashboard_loop.py` | 16 | 17 | `DashboardSpec` | 17 | Dormant recovery runs as retryable/blocked and as unknown/faulted. |
| `test_reminders_loop.py` | 20 | 20 | `RemindersSpec` | 20 | The mail-ordering tests loop over both delivery orders inside one case, as upstream does. |
| `test_readiness_loop.py` | 38 | 38 | `ReadinessSpec` | 38 | none |
| `test_board.py` | 22 | 22 | `BoardSpec` | 22 | none |
| `test_gating.py` | 3 | 5 | `GatingSpec` | 5 | The expired-claim scenario runs over the 3 publication gates. It uses the JSONL history store and the SQLite Local dispatch, as upstream does. |
| `test_inline_recovery.py` | 9 | 35 | `InlineRecoverySpec` | 35 | Five convergence cases, plus 6 + 20 + 3 identity-contract cases. See the note below. |
| `test_payloads.py` (converter tests) | 8 of 10 | 9 of 12 | `PayloadsSpec` | 10 | Coercion runs over 2 inputs. One more example covers a refusal the reference raises but never tests. Two tests need no converter: the field partition and the concern projection. They are ported only in hamsterdan-contracts' `CodecSpec`. |
| **Total** | **267** | **302** | | **303** | |

### Corpus and gate suites (no upstream counterpart)

| Spec | Examples | What it checks |
| --- | ---: | --- |
| `TopologySpec` | 11 | The fingerprint gate: bytes, sha256, size, gate list and handler binding. It also checks the seed-marking corpus, the subject refusals and the 900-byte subject bound. |
| `FoldCorpusSpec` | 18 | Every row of `folds.jsonl`, grouped by loop and by call kind (folds, gate handlers). |
| `BoardCorpusSpec` | 3 | Every row of `board.jsonl`, for both `render_board` and `gate_facts`, and that refusals are covered. |

**Suite total:** 335 examples, 0 failures.

### Inline recovery and the host gates

Upstream proves convergence in `test_inline_recovery.py` with the real
`hamsterdan.host.v5` gates: `V5ReviewGate`, `V5PublicationGates`,
`V5RerunGate` and `V5MutationGate`. Those gates belong to `hamsterdan-host`.

The five convergence cases here instead wrap the harness gate in a ledger
test double. They drive the same restart protocol: a crash-cut dispatch, a
fresh Engine, and the exact redispatch of the frozen request. They then
assert the net-side contract:

- the redispatch is exact;
- the provider applies the effect once;
- there are three calls;
- a reload is stable.

`hamsterdan-host` reruns the five cases against the real gates, with the
reference's provider-ledger doubles, in
[`../hamsterdan-host/test/InlineRecoverySpec.hs`](../hamsterdan-host/test/InlineRecoverySpec.hs)
(5 examples, 0 failures).

## Benchmarks

See [bench/RESULTS.md](bench/RESULTS.md). The Haskell and Python runs were
interleaved, and the load average is noted. Haskell is faster on every row:

- folding: 4.0–11.0× per loop, 6.0× for the whole corpus;
- `render_board`: 3.7×;
- `gate_facts`: 4.7×.

## Gaps

- **Closed by `hamsterdan-host`:** the real `host.v5` gates rerun the five
  convergence cases; `wireGates` runs with real `GateDefinition`s; each gate
  uses `variantPayloadConverter` with `encodeVariant` on its result.
- **Out of scope:** `readiness/__init__.py` holds only a docstring, so it
  has no Haskell counterpart.
