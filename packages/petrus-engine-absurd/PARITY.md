# petrus-engine-absurd: parity with the Python reference

This package ports `petrus.engine.absurd` at the pin in [UPSTREAM.md](../../UPSTREAM.md):
`create_engine` and `load_engine` (`createEngine`, `loadEngine`, `openAbsurdEngine`), which
host one Instance over PostgreSQL History (`petrus-history-postgres`) and the Absurd Dispatch
(`petrus-motus-absurd`).

- The two share the authority's joined transaction: a semantic begin, its `absurd.spawn_task`
  and its `impetus_dispatch` doorbell commit or vanish together.
- The authority fence is taken before any History is read.
- `wait` blocks only on the dedicated autocommit listen connection.
- Both connections are closed on every construction failure and by `close`.

The composition reuses `Petrus.Engine.Postgres.Joined` from `petrus-engine-postgres`.

**Status: at parity.** Every upstream test is ported:

- The Engine side of `test_worker_topology.py` runs against both the reference's Worker process
  and a Haskell Worker process.
- Interop runs Engines and Workers of both languages on one Instance.
- Haskell is faster than Python on every benchmark row ([bench/RESULTS.md](bench/RESULTS.md)).

API differences are in [DIVERGENCES.md](DIVERGENCES.md). History rows, Absurd rows, doorbells
and behavior do not diverge.

## Running the tests

```sh
PETRUS_TEST_POSTGRES=postgresql://postgres:postgres@localhost:5432/postgres \
  cabal test petrus-engine-absurd --test-options='+RTS -M2G -RTS'
```

`cabal test petrus-engine-absurd` runs 58 examples. With `PETRUS_TEST_POSTGRES` set (CI sets it),
all 58 pass. Without it, every example is pending and says why, the way upstream's `postgres`
marker skips.

The suite provisions one scratch database with both schemas and the fixture tables of
`tests/absurd_support.py`. Every Engine and Worker an example starts is torn down after it, and
Worker processes are killed by exact PID.

The reference's Worker process (`python -m petrus.motus.worker --provider absurd`) and the
interop driver run under the pinned reference's environment (`upstream/petrus/.venv` on
CPython 3.14.6), which `scripts/upstream-python` provisions on first use. An example that needs
it fails, never skips, when it cannot be provisioned.

### The Haskell Worker process

The Haskell Worker process is this suite's own executable, re-run with
`PETRUS_ENGINE_ABSURD_TEST_WORKER=1`. Its `main` then becomes
`workerMain "python -m petrus.motus.worker" topologyRegistries absurdPlugins`:

- the real Worker entry point of `petrus-motus`;
- the Absurd provider from `petrus-motus-absurd`'s `ProviderPlugins` slot;
- `tests.absurd_support:activities` ported as `sparkWorkActivity`, with the same effects
  table, kill switch, `nap`, `boom`, heartbeat and checkpoint modes.

It takes the same command line as the reference's Worker and prints the same JSON event lines on
stdout.

## Ledger

`tests/petrus/motus/worker/test_worker_topology.py` has 36 test functions and 40 cases. All are
accounted for: 36 cases are ported as examples, and 4 are enforced by the types (one of those
keeps an example that says so).

| upstream class | functions | cases | Haskell | status |
| --- | ---: | ---: | --- | --- |
| `TestEndToEnd` | 1 | 1 | `Petrus.Engine.AbsurdSpec` | ported; runs once per Worker kind |
| `TestLifecycleScopeCancellation` | 1 | 1 | `Petrus.Engine.AbsurdSpec` | ported (no Worker) |
| `TestWorkerKill` | 4 | 4 | `Petrus.Engine.AbsurdSpec` | ported; each runs once per Worker kind, with real SIGKILL and SIGTERM |
| `TestAuthorityKill` | 2 | 2 | `Petrus.Engine.AbsurdSpec` | ported; each runs once per Worker kind |
| `TestAbsurdProviderEngineConstruction` | 19 | 19 | `Petrus.Engine.Absurd.ConstructionSpec` (run from `AbsurdSpec`) | 18 ported (3 Worker-backed, once per Worker kind); 1 enforced by the types |
| `TestActivityRegistry` | 7 | 11 | `Petrus.Engine.Absurd.WorkerTopologySpec` | 8 ported (the unregistered Activity once per Worker kind); 3 enforced by the types |
| `TestDispatchDoorbell` | 2 | 2 | `Petrus.Engine.Absurd.WorkerTopologySpec` | ported; each runs once per Worker kind |
| total | 36 | 40 | | 36 ported, 4 enforced by the types |

`TestActivityRegistry`'s 11 cases are:

- the claimant reuse;
- the queue snapshot;
- the invalid registries, parametrized over 4 values;
- the empty subscription;
- the `main` defaults, parametrized over 2 flag lists;
- the unregistered Activity, run once per Worker kind;
- the mutable-registry snapshot.

### Enforced by the types

- `TestAbsurdProviderEngineConstruction.test_the_session_hands_out_no_writer_and_its_accessors_are_read_only`:
  `Engine` is abstract and its reads are functions, so there is no writer attribute to hand out
  and no accessor to assign. The example is kept, named after the test, and says so.
- `TestActivityRegistry.test_worker_refuses_invalid_activity_registries`, the `{7: ...}` and
  `{"work": object()}` cases: a registry is a `Map Text Activity`, so a non-string name or a
  non-callable implementation cannot be written. The `{}` and `{"": ...}` cases are ported.
- `TestActivityRegistry.test_worker_and_loader_snapshot_mutable_registries`: a registry is an
  immutable `Map`, and a worker executable compiles its registries in instead of importing them
  by name, so there is nothing to mutate after the snapshot.

### How the Worker-side tests are ported

- `test_main_defaults_queue_and_preserves_deduplicated_flag_order` drives the real entry point
  (`workerMainWith`) with a fake Absurd provider in the plugin slot. The reference monkeypatches
  `AbsurdWorkerDispatch` to the same end.
- `test_the_worker_refuses_an_unregistered_activity` spawns the task with a raw
  `absurd.spawn_task`, as the reference does, and reads the failed run's `failure_reason`.
- `test_the_doorbell_wakes_a_worker_whose_poll_could_not_have` gives the Worker a 30 s poll
  floor, commits a dispatch through `AbsurdDispatch`, and requires completion within 8 s.

## Interop with the reference

`Petrus.Engine.Absurd.InteropSpec` (7 examples) drives
[`test/interop/absurd_engine_interop.py`](test/interop/absurd_engine_interop.py) under the pinned
reference's interpreter. Engines of the two languages take turns on one Instance in one
database:

- a reference Engine dispatches, a Haskell Worker executes, and the reference Engine completes;
- a Haskell Engine dispatches and dies after the commit; the reference resumes lookup-first
  without a double spawn, and Haskell reads back the same History;
- the reference dispatches and dies; a Haskell Engine resumes without a double spawn and
  completes, and the reference reads back the same History;
- a reference Worker killed mid-lease is retried by a Haskell Worker, for a reference Engine, with
  exactly one effect;
- a Haskell Worker killed mid-lease is retried by a reference Worker, for a Haskell Engine;
- a reference Engine's scope close fences a Haskell Worker's claimed Attempt;
- a Haskell Engine's scope close fences a reference Worker's claimed Attempt.

A Haskell Engine with the reference's Worker process also runs every Worker-backed example of
`AbsurdSpec`.

The 33 joined worlds of `petrus-dst` exercise this Engine further. Their profiles host it under
fault injection at every History and Dispatch commit boundary, and replay to the reference's
exact result bytes ([petrus-dst PARITY](../petrus-dst/PARITY.md)).

## Beyond upstream

- `TestAbsurdProviderEngineConstruction` / the listen connection must not be the joined
  connection. The reference refuses this case in `_validate_connections`, but its tests never
  pass the joined connection as the listener.
