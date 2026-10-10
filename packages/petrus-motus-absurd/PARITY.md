# petrus-motus-absurd: parity with the Python reference

This package ports `petrus.motus.dispatch.absurd` at the pin in [UPSTREAM.md](../../UPSTREAM.md):
the optional durable Dispatch over Absurd 0.4.0, hash-pinned and never forked.

- `ensure_absurd_schema` (`ensureAbsurdSchema`): the vendored release script, byte-identical
  to the reference's and compiled in, re-verified by SHA-256 before every apply.
- `AbsurdDispatch` (`absurdDispatch`): the Engine-facing Dispatch on the authority's joined
  transaction, with the keyed spawn, the `impetus_dispatch` doorbell, lookup-first recovery,
  durable cancellation tombstones and completion-order `collect`.
- `GuardedDispatch`, `_ReconnectableGuardedDispatch` and `AbsurdWorkerDispatch`: the
  lease-fenced Worker side.
- The Worker CLI's `--provider absurd` branch (`Petrus.Motus.Worker.Absurd.absurdPlugins`),
  plugged into `Petrus.Motus.Worker.Cli`'s provider slot.

**Status: at parity.** Every upstream test of the Absurd Dispatch is ported, interop runs in
both directions against the pinned reference, and Haskell is at least as fast as Python on
every benchmark row ([bench/RESULTS.md](bench/RESULTS.md)). API differences are in
[DIVERGENCES.md](DIVERGENCES.md); wire formats, schemas and behavior do not diverge.

## Running the tests

```sh
PETRUS_TEST_POSTGRES=postgresql://postgres:postgres@localhost:5432/postgres \
  cabal test petrus-motus-absurd --test-options='+RTS -M2G -RTS'
```

`cabal test petrus-motus-absurd` runs 127 examples. With `PETRUS_TEST_POSTGRES` set (CI sets
it), all 127 pass. Without it, the 98 examples that need a server are pending and say why, the
way upstream's `postgres` marker skips. The suite provisions one scratch database with the
pinned schema and drops it afterwards. The interop examples run the pinned reference's
environment (`upstream/petrus/.venv` on CPython 3.14.6), which `scripts/upstream-python`
provisions on first use; they fail, never skip, when it cannot be provisioned.

## Ledger

| upstream file | Haskell spec | upstream count | status |
| --- | --- | --- | --- |
| `tests/petrus/motus/dispatch/test_absurd_adapter.py` | `Petrus.Motus.Dispatch.AbsurdSpec` | 78 functions, 103 cases | all 103 cases ported |
| `tests/petrus/motus/dispatch/test_attempt_heartbeats.py`, the Absurd part | `Petrus.Motus.Dispatch.Absurd.HeartbeatSpec` | 3 functions, 9 cases | all 9 cases ported |
| `tests/project/test_package_boundaries.py`, the 4 Absurd rows | `Petrus.Motus.Dispatch.Absurd.BoundarySpec` | 4 functions | ported over Cabal metadata and module sources |
| `tests/petrus/motus/worker/test_worker_topology.py` | `packages/petrus-engine-absurd` (`AbsurdSpec`, `Absurd.WorkerTopologySpec`) | 36 functions, 40 cases | see [petrus-engine-absurd's PARITY](../petrus-engine-absurd/PARITY.md) |

The other five tests of `test_attempt_heartbeats.py` (declarations, the inline context, detail
normalization) are ported in `petrus-activity` and `petrus-motus`
([petrus-motus PARITY](../petrus-motus/PARITY.md)).

### `test_absurd_adapter.py`, by class

Every example is named after the upstream test it ports; parametrized tests run one example per
upstream case, named after the parameter.

| upstream class | functions | cases | Haskell describe | notes |
| --- | ---: | ---: | --- | --- |
| module level: `test_absurd_scope_*` | 3 | 8 | `publication identity scope` | `rejects_noncanonical_publication_identity` is parametrized over 4 identities, `leaves_foreign_tasks_unscoped_for_default_workers` over 3 task keys |
| module level: `test_async_worker_integrates_distinct_absurd_lane_claimants_and_terminals` | 1 | 1 | `distinct Absurd lane claimants claim, heartbeat and terminate concurrently` | the reference's async worker becomes Haskell threads, one `AbsurdWorkerDispatch` per lane |
| `TestSchemaPin` | 7 | 7 | `TestSchemaPin` | the tampered-copy tests pass a modified script to `ensureAbsurdSchemaWith` where the reference monkeypatches the file read |
| `TestQueueMapping` | 3 | 3 | `TestQueueMapping` | |
| `TestInvocationWire` | 4 | 4 | `TestInvocationWire` | |
| `TestDispatch` | 11 | 12 | `TestDispatch` | `refuses_deadlines_it_cannot_enforce_exactly` is parametrized over `start_to_close` and `schedule_to_close` |
| `TestCollect` | 4 | 4 | `TestCollect` | |
| `TestLookupFirstRedispatch` | 26 | 29 | `TestLookupFirstRedispatch` | three parametrized tests: route A→B→A survival, the malformed terminal last attempt, and non-pending custody that is never moved |
| `TestWaitForResults` | 3 | 3 | `TestWaitForResults` | |
| `TestAdapterShape` | 3 | 3 | `TestAdapterShape` | the `isinstance(adapter, Dispatch)` protocol check becomes `toDispatch`, which must also offer cancellation (`isCancellable`) |
| `TestGuardedAttemptDispatch` | 13 | 29 | `TestGuardedAttemptDispatch` | two parametrized tests: duplicate classified failures, and every attempt operation against every stale custody cause |
| total | 78 | 103 | | |

### `test_attempt_heartbeats.py`, the Absurd part

| upstream test | Haskell example | status |
| --- | --- | --- |
| `test_attempt_state_model_covers_renewal_expiry_reassignment_terminal_and_stale_refusal` | `the attempt state model` / covers renewal, expiry, reassignment, terminal and stale refusal | ported |
| `test_reconnectable_heartbeat_replaces_closed_transport_once_and_never_retries_replacement` (2 cases) | `the reconnectable heartbeat` / replaces a closed transport once on `OperationalError` / `InterfaceError` … | ported. The rule is `reconnectOnce`, driven with the reference's fakes |
| `test_reconnectable_heartbeat_does_not_replace_or_retry_semantic_errors` (6 cases) | `the reconnectable heartbeat` / does not replace or retry … (one per error class) | ported. The psycopg classes map to SQLSTATE classes (`errorClassForState`); `RuntimeError` is `AbsurdError` |

### `test_package_boundaries.py`, the Absurd rows

| upstream test | Haskell example | how |
| --- | --- | --- |
| `test_dispatch_import_is_optional_dependency_safe_and_absurd_is_canonical` | dispatch import is optional-dependency safe and absurd is canonical | `petrus-motus` depends on no Absurd, PostgreSQL or ZeroMQ package; this package exposes `Petrus.Motus.Dispatch.Absurd` |
| `test_absurd_dispatch_removed_name_has_no_deep_compatibility_alias` | absurd dispatch removed name has no deep compatibility alias | the export list has no `AbsurdExecutionAdapter` or `AbsurdEngine`; `createEngine` and `loadEngine` return the plain `Engine` |
| `test_absurd_deep_import_preserves_missing_extra_guidance` | absurd deep import preserves missing extra guidance | the optional extra is this package, which brings the PostgreSQL layer; without the dependency the module cannot be imported, and the build names the missing package |
| `test_worker_import_does_not_require_absurd_extra` | worker import does not require absurd extra | the Worker and its CLI (`petrus-motus`) import nothing from this package; the provider arrives through `ProviderPlugins` |

## Interop with the reference

`Petrus.Motus.Dispatch.Absurd.InteropSpec` (11 examples) drives
[`test/interop/absurd_dispatch_interop.py`](test/interop/absurd_dispatch_interop.py) under the
pinned reference's interpreter, against the same scratch database. Every direction is
exercised:

- both sides pin the same Absurd release, vendored bytes, channel names and checkpoint name;
- both decode the same publication keys and task payloads, and refuse the same ones;
- each accepts the other's provisioned schema, and the catalogs are identical;
- a Haskell and a reference authority write the same task rows, idempotency keys and dispatch
  doorbells;
- a Haskell Worker executes a reference-dispatched task, and the reference collects its result;
- a reference Worker executes a Haskell-dispatched task, and Haskell collects it, woken by the
  results doorbell;
- classified and exception failures cross both ways with the same `failure_reason` rows;
- a retry crosses languages: the next attempt sees the other side's latest details;
- cancellation fences cross languages both ways;
- an authority crash is recovered across languages, lookup-first, without a double enqueue;
- a Worker killed mid-lease is recovered by the other language with its latest details.

The Engine-level interop (Engines and Worker processes of both languages over one database) is in
[petrus-engine-absurd](../petrus-engine-absurd/PARITY.md).

## Beyond upstream

- `BoundarySpec` checks the package graph that replaces the reference's import-time guards.
- The bench's `calibration.select-1` row measures the bare round trip both clients build on.
