# Audit: Engine, motus, Fabric and processes

Slice audited against `henriquebastos/petrus` at the pin
`3f85fc2094e50ece48bcf6bf9ace19cb0a22a544` (UPSTREAM.md), on local `main` at
`3bfb6c9`. Audited on 2026-10-11.

The slice covers:

- the Engine and its backends: SQLite, Postgres and Absurd;
- `motus` in full: Activities, Workers and the Worker CLI, dispatch (inline,
  in-memory, Local and Absurd), the ZeroMQ transport, and execution (Local,
  Docker, E2B and Gondolin);
- `fabric` and `processes`;
- the shared OS and database layers they use: `petrus-posix`,
  `petrus-sqlite` and `petrus-postgres`;
- all upstream tests and spec documents for these.

Method: a mechanical inventory (upstream ASTs, name matching against the
Haskell sources and test labels, every package ledger), then reading of the
code and tests where the inventory left questions. The audit also used the
CI logs of the last runs on `main` and the committed benchmark results. One
targeted test was rerun locally (EMF-1). No benchmarks were run.

## 1 Scope covered

### Upstream source

There are 36 Python modules in the slice:

| Area | Modules |
| --- | --- |
| `engine` | `__init__`, `_coordination`, `sqlite`, `postgres`, `_postgres`, `absurd` (`observation_http.py` belongs to the observation slice) |
| `fabric` | `__init__`, `ingress`, `model`, `postgres` |
| `processes` | `__init__`, `call`, `model`, `postgres`, `spawn` |
| `motus` | 21 modules: `activity`, `dispatch/{__init__,local,absurd}`, `transport/{__init__,zeromq}`, `worker/{__init__,__main__,_cli}`, `execution/{__init__,archive,gondolin,providers}`, `_execution/{__init__,artifacts,gondolin,model,providers,timeline}` |

The slice also holds two non-Python artifacts: `gondolin_sidecar.mjs` and the
vendored `absurd-0.4.0.sql`.

### Public names

There are **388** top-level public names and public methods in the 31
non-empty modules. 379 of them have a Haskell counterpart with the
camel-cased name. The other 9 are all documented:

- `Engine.history_page` is on the observation seam (petrus-engine
  DIVERGENCES 3).
- The five async Activity names and `DataclassPayloadConverter` are not
  ported, because Haskell has no function colours (petrus-activity
  DIVERGENCES 1 and 3).
- `EnvironmentCapability` is the `Capability` newtype.
- `MAX_ARCHIVE_BYTES` is `maxWorkspaceArchiveBytes`.

The CLIs are ported too:

- `python -m petrus.motus.worker` is `Petrus.Motus.Worker.Cli.workerMain`,
  with byte-identical help, usage errors and refusals (WorkerCliSpec).
- `python -m petrus.motus.transport.zeromq` is the
  `petrus-motus-zeromq` app (InteropSpec "the server CLI answers as …").

These schemas are byte-checked against the reference:

- the Local Dispatch DDL;
- the Absurd 0.4.0 script, SHA-256 pinned;
- the `impetus_fabric` and `impetus_lifecycle` DDL;
- the SQLite and Postgres History DDL.

### Upstream tests

There are 20 files and **665** test functions. 656 of them are in the slice:
all the non-boundary files, plus 11 of the 20 `test_package_boundaries.py`
rows.

| Upstream file | Functions | Haskell home |
| --- | ---: | --- |
| engine/test_engine.py | 28 | petrus-engine EngineSpec |
| engine/test_coordinator.py | 42 | petrus-engine CoordinatorSpec (35), petrus-motus (7) |
| engine/test_execution.py | 134 | petrus-engine ExecutionSpec, DeliveryPhasesA/B/C (108 ported, 26 enforced by types) |
| engine/test_sqlite_engine.py | 5 | petrus-engine-sqlite |
| engine/test_postgres_engine.py | 12 (13 cases) | petrus-engine-postgres |
| fabric/test_fabric.py | 12 | petrus-fabric |
| processes/test_processes.py | 19 | petrus-processes |
| motus/dispatch/test_local_dispatch.py | 36 | petrus-motus (33), petrus-engine (3) |
| motus/dispatch/test_absurd_adapter.py | 78 (103 cases) | petrus-motus-absurd AbsurdSpec |
| motus/dispatch/test_attempt_heartbeats.py | 8 | petrus-motus-absurd (3), petrus-activity and petrus-motus (5) |
| motus/transport/test_zeromq_dispatch_transport.py | 26 (30 cases) | petrus-motus-zeromq |
| motus/worker/test_worker_runtime.py | 12 | petrus-motus, petrus-engine |
| motus/worker/test_async_worker.py | 26 | petrus-motus (23, plus 3 with no function colours) |
| motus/worker/test_worker_topology.py | 36 (40 cases) | petrus-engine-absurd (all 36), petrus-engine (4 over Local) |
| motus/test_execution_contract.py | 10 | petrus-execution |
| motus/test_gondolin_environment.py | 32 | petrus-execution |
| motus/test_private_execution_substrate.py | 23 | petrus-execution |
| motus/test_private_file_transfer.py | 6 | petrus-execution |
| integration/test_activity_seam.py | 100 | petrus-impetus `parity-activity-seam.md`, petrus-motus |
| project/test_package_boundaries.py | 11 in slice | 7 ported; **4 unaccounted** (EMF-3) |

### Spec documents

- **Upstream:** `upstream/petrus/spec` has no Fabric, processes or motus
  spec. The Engine is constrained by prose in `firing-semantics.md`
  (§Scheduling, lines 145–201), `event-history.md` (Activities and Dispatch)
  and `handler-contract.md` (EMF-5).
- **This repository:** `spec/fabric.md` (1055 lines, protocol v1) and its
  108-check list `spec/fabric-conformance.md`; `spec/processes.md` (749
  lines) and its 80-check list `spec/processes-conformance.md`.

### Haskell side

CI run 38134729883 ran 1 633 examples in the slice's 14 packages:

| Package | Examples |
| --- | ---: |
| petrus-activity | 40 |
| petrus-engine | 209 |
| petrus-engine-absurd | 58 |
| petrus-engine-postgres | 31 |
| petrus-engine-sqlite | 20 |
| petrus-execution | 404 |
| petrus-fabric | 242 |
| petrus-motus | 139 |
| petrus-motus-absurd | 127 |
| petrus-motus-zeromq | 43 |
| petrus-posix | 30 |
| petrus-postgres | 36 |
| petrus-processes | 223 |
| petrus-sqlite | 31 |

The PostgreSQL suites ran: none of them went pending. Only 2 examples were
pending, both opt-in upstream too: the real-Gondolin run and live E2B.

The committed benchmarks have 105 rows across these 14 packages, each with a
Python twin.

## 2 Mapping summary

- **Tests.** Every upstream test function in the slice except the 4
  boundary rows of EMF-3 is in a package ledger.
  - 619 are ported under a label carrying the upstream name or its prose
    form, checked by name matching against the test sources.
  - The rest are ledgered as enforced by types, partial, or not applicable,
    and each such entry has a reason. Most of them are `str`, `int` or
    record subclasses, or Python function colours.
  - Spot checks (CoordinatorSpec's conservative policy, ZeroMQ's protocol
    refusals, Absurd's lookup-first redispatch, Worker topology) found the
    same scenario and assertions as upstream.
  - `packages/petrus-engine/scripts/parity_check.py` is stale (EMF-9).
- **Conformance.** All 108 F-checks and all 80 P-checks appear in the
  conformance sources. Each check is written once and run against both the
  Haskell twin and the pinned reference's driver
  (`test/interop/conformance_driver.py`, which calls `petrus.fabric` and
  `petrus.processes` directly). Only 4 Fabric checks accept a typed
  "unsupported" from Haskell, and `TypedSpec` covers those at compile time.
- **Interop.** These suites run against the pinned reference in both
  directions:

  | Area | Suite |
  | --- | --- |
  | Engine, JSONL | `petrus-engine` InteropSpec |
  | Engine, SQLite | `SqliteInteropSpec`: rows, crash and resume, the fence |
  | Engine, Postgres | `Postgres.InteropSpec`: turns, the fence, failure fates, doorbells |
  | Engine, Absurd | `Absurd.InteropSpec`: authority crash, Worker kill, scope-close fences |
  | Local Dispatch | `LocalInteropSpec` |
  | Absurd Dispatch | `Absurd.InteropSpec` |
  | ZeroMQ | both servers and both clients, an 80-request raw corpus, the CLI |
  | Worker topology | the Engine × Worker pairings write byte-identical History |
  | Fabric | `InteropSpec`, plus `DemoSpec` with split roles |
  | Processes | `InteropSpec` (call and spawn both ways), plus `DemoSpec` (six mixed configurations) |

  `scripts/lint-skips` enforces that a missing reference fails a test and
  never skips it. The shared `withReference` helpers go through
  `pythonExecutable` and `upstreamPetrus`.

## 3 Findings

Severity: **blocker** means an outcome does not hold, **major** is a
significant gap, and **minor** is the rest.

| ID | Outcome | Severity | Evidence | Suggested fix |
| --- | --- | --- | --- | --- |
| EMF-1 | 7 | major | `main` CI is red. Run 38134729883 on `10c9c7a` failed in `petrus-execution`: `test_private_execution_substrate (local) test_local_collection_drains_large_output_and_kills_sigterm_ignoring_process` expected return code 0 but got -15. The previous run 38129412600 failed in an out-of-slice agenticus test. Haskell side: `packages/petrus-execution/test/LocalSpec.hs:193-208` and `src/Petrus/Motus/Execution/Internal/Process.hs:392-420`. `collect` terminates the child as soon as a 50 ms tick sees more than `output_limit` bytes, so on a loaded runner `head -c 2000000` is SIGTERMed before it exits. Upstream: `_execution/providers.py:112-143` has the same rule, and `tests/petrus/motus/test_private_execution_substrate.py:368-382` asserts `returncode == 0`, so the race is inherent in the upstream test. It reproduces only on CI: 0 of 44 failures locally, 20 runs in sequence and 24 with 8 in parallel. | Make the example robust without weakening it: assert `output_truncated` and 1 000 retained bytes, and accept `0` or `-SIGTERM` for the large-output half, recording the race in the ledger. Alternatively, run this example under `sequential` with a widened first tick, documented as test-only. Get `main` green, and add a flake ledger or retry policy that CI reports rather than hides. |
| EMF-2 | 3, 5 | major | The Haskell E2B provider cannot reach a real E2B backend. The default loader always fails with `No module named 'e2b'`: `src/Petrus/Motus/Execution/Providers/E2b.hs:117-121`. The live example is permanently pending: `test/E2bSpec.hs:301-302`. Upstream's `E2bEnvironment` (`_execution/providers.py:992-1019`) works with the `e2b` SDK. DIVERGENCES.md:16 records this as an API divergence, but it is a missing capability: a Haskell Worker cannot run E2B-backed Activities at all. | Implement the `E2bSdk` record with a real client, either a Haskell client for E2B's REST and envd API, or a sidecar around the official SDK (the pattern `petrus-agenticus-runtime` uses for its hosts). Then run the opt-in live test the way upstream does, and mark the Execution row "at parity except E2B" until then. |
| EMF-3 | 2 | major | Four slice-relevant upstream tests have no Haskell check and no ledger entry in any `PARITY.md`. They are in `tests/project/test_package_boundaries.py`: `test_engine_is_canonical_public_and_optional_dependency_safe` (:141: Engine export set, no `queue_for`, no psycopg or Absurd load), `test_dispatch_is_canonical_and_coordination_remains_private` (:356: the exact `petrus.engine.__all__`, `Coordinator` private, removed names absent), `test_zeromq_transport_base_import_is_optional_and_deep_import_has_guidance` (:492), and the Worker half of `test_activity_worker_and_runtime_service_do_not_own_retained_territory_lifecycle` (:157). The project-wide rows (:90, :113, :298) have no owner either. petrus-motus-absurd shows the expected pattern: it ported its 4 rows as `BoundarySpec` over Cabal metadata and module sources. | Add a BoundarySpec to petrus-engine (the export list of `Petrus.Engine`, with no Coordinator export and no dependency on Postgres or Absurd), one to petrus-motus-zeromq (the base package without libzmq, and the Cabal guidance), and one to petrus-motus (the Worker imports no retention module). Ledger each one, and assign the project-wide rows to a package. |
| EMF-4 | 3 | major | The Execution row claims "registries, archives, Timeline JSONL and artifact metadata are the upstream formats" (`packages/petrus-execution/PARITY.md:13`). Archives, Timeline and metadata have byte fixtures. The durable custody state that a crashed Worker of one language would leave for the other has no cross-language test: Gondolin's `registry.json` (`_execution/gondolin.py:199-217` against `Providers/Gondolin.hs:468-490`), the Local and private-file registries, and Docker's `run.petrus.*` labels used by lookup-first reconcile (`providers.py:785`). | Add an interop group: the reference provisions (Local, Docker against `fake_docker.py`, Gondolin against the fake SDK) and dies, Haskell reconciles, executes and destroys. Then the converse. |
| EMF-5 | 2 | major | No executable trace links the Engine and Dispatch obligations in `upstream/petrus/spec` to checks. Those obligations are `firing-semantics.md:145-201` (selection versus DrivingPolicy, one action per turn, `ready`/`waiting`/`next_maturation`, no sleeping), `event-history.md` §Activities (lines 160-241) and `handler-contract.md` (the activity and projection split). No package ledger cites these documents (`grep` finds them only in `docs/runtime.md` planning notes). They are probably covered by the ported upstream tests, but "everything specified in petrus/spec/ holds" cannot be confirmed for the Engine. This may be shared with the kernel slice. | Write a spec ledger, for example `packages/petrus-engine/SPEC.md`, that lists each normative statement of those sections with the Haskell example(s) checking it, and add checks for any statement left uncovered. |
| EMF-6 | 6 | minor | Some real-use paths have no benchmark row. The Postgres Engine bench (`packages/petrus-engine-postgres/bench/python_bench.py`) times only source `deliver`, `redeliver-prior` and `create-close`: no internal-transition firing, Activity round trip or `load`. Execution times `runCaptured` of `/usr/bin/true`, but not `LocalProcessEnvironment.execute` (attach, cwd containment, collect) or Docker execute. Processes times envelopes and store rows, but no full call round trip (request, drain, reply, drain). | Add `engine.advance-chain` and `engine.load` rows to petrus-engine-postgres, a `local/execute` row to petrus-execution, and a `call.roundtrip-postgres` row to petrus-processes, each with its Python twin. |
| EMF-7 | 6 | minor | Several medians at or above 1.0× rest on noisy repetitions. Absurd `roundtrip.dispatch-claim-complete-collect`: 1.20×, but lowest repetition 0.59×, Haskell ahead in 4 of 6. Absurd `dispatch.spawn-commit`: lowest 0.68×. Fabric `postgres.send-drain` and `submit-duplicate`: lowest 0.68×. Execution `sidecar/execute-round-trip`: 1.00×, lowest 0.97×. | Rerun these rows with more interleaved repetitions on a quiet machine, and report the share of repetitions won next to the median (most files already do). |
| EMF-8 | 3, 5 | minor | The Haskell archive reader refuses bzip2, xz and zstd workspace archives, which `tarfile.open("r:*")` accepts. It also caps gzip at 3 GiB and reports gzip errors as truncation (`packages/petrus-execution/DIVERGENCES.md:26`). The divergence is documented with a rationale ("producers only ever emit uncompressed"), but it is an accepted-input difference on an exchanged format. | Either decode the three codecs, or restate the workspace-archive format (uncompressed or gzip) as the contract in a spec note and show that no upstream producer emits the others. |
| EMF-9 | 7 | minor | `packages/petrus-engine/scripts/parity_check.py` reports "441 in-scope upstream tests, 29 unaccounted" (all Absurd `test_worker_topology.py` tests, which are ledgered in petrus-engine-absurd). The package PARITY said it reported "275 … 0 unaccounted". | The doc was corrected in this commit. Teach the script petrus-engine-absurd's ledger (or retire it in favour of a repo-wide ledger check), and run it from `scripts/check-all`. |
| EMF-10 | 7 | minor | Stale ledger statements. `PARITY.md` row "Dispatch port…" cited nonexistent upstream files `motus/dispatch/{inline,memory}.py`; they are in `__init__.py`. `packages/petrus-engine/PARITY.md` said the interop examples go "pending only when `.venv` is not synced", but they fail. `packages/petrus-execution/PARITY.md` claimed 397 examples; CI runs 404 and macOS 400. | Corrected in this commit. |
| EMF-11 | 4 | minor | Some spec sections are cited by no conformance check: `spec/fabric.md` §3.4 (digest), §4.4 and §4.5 (Submission and Receipt fields), §5.3 (acceptance identity), §10 and §13 (versioning), and `spec/processes.md` §2, §13.2 and §16. Most are covered transitively (for example the F-checks on digests and receipts), but the lists do not show it. | Cite these sections from the checks that cover them. Add a check for §13 and §16: envelope version ≠ 1 and schema version ≠ 1 refused, and the `fabric:` prefix and `FabricEnvelope` color fixed, if none exists. |
| EMF-12 | 1, 7 | minor | `scripts/check-pins` reports `pin mismatch … checkout=<superproject HEAD>` for a submodule that is not initialized. `git -C upstream/x rev-parse HEAD` in an empty directory resolves the superproject. | Check `git -C "$submodule" rev-parse --show-toplevel` against the submodule path, and say "not checked out". |

## 4 Divergences reviewed (outcome 5)

Every entry in the 14 `DIVERGENCES.md` files of the slice has a rationale.
None changes a schema or DDL. On the wire, the remaining differences are
message texts on malformed input:

- ZeroMQ answers lone-surrogate escapes and nesting beyond 100 000 levels
  with a `protocol` error of the same kind but different text.
- Exception type names come from Haskell types unless an exception is
  declared under the Python name. This is inherent, and stored values match
  wherever the port declares the reference's names.

Wire-level behavior otherwise matches, with these exceptions:

- the archive codec (EMF-8);
- E2B (EMF-2), which is a missing capability rather than a divergence;
- the PostgreSQL isolation level: an explicit `READ COMMITTED` instead of
  the server default. This is safer, and it only differs on a server
  reconfigured away from the default.

The "Haskell way" choices look well judged:

- typed errors;
- closed sum types that replace 26 subclass-attack tests;
- connection pooling for Local Dispatch;
- `posix_spawn` and a `poll()` wait for execution;
- the sidecar embedded and hash-pinned.

## 5 Verdicts per outcome (this slice)

| Outcome | Verdict |
| --- | --- |
| 1 Pinned parity | **Holds.** Pins are recorded and gitlinked, `check-pins` runs in CI, and the Absurd and Gondolin artifacts are hash-pinned (EMF-12 is cosmetic). |
| 2 Conformance | **Holds except the majors.** Every behavioral upstream test and all 188 Fabric and process checks pass against both implementations. Not yet complete: 4 boundary tests (EMF-3), and no traceability for the Engine obligations of `upstream/petrus/spec` (EMF-5). |
| 3 Interoperability | **Holds for every format and protocol the outcome names in this slice:** History through the JSONL, SQLite, Postgres and Absurd Engines, Local, Absurd and ZeroMQ dispatch, Workers and the Worker CLI, all in both directions. **Gaps:** E2B cannot run (EMF-2), and execution custody state has no cross-language test (EMF-4). |
| 4 Fabric and processes | **Holds.** Language-neutral contracts with CONTRACT/ACCIDENT/OPEN classification, 108 + 80 executable checks run against both implementations, and message, call and spawn between Python and Haskell instances in both directions. Minor cross-reference gaps (EMF-11). |
| 5 Better the Haskell way | **Holds, with the E2B gap (EMF-2) recorded as a divergence it should not be.** Every divergence has a rationale, and no schema or specified behavior diverges (EMF-8 minor). |
| 6 Performance | **Holds on committed medians.** All 105 rows are ≥ 1.00×, each with a Python twin. Coverage gaps (EMF-6) and noisy rows (EMF-7) are minor. |
| 7 Verifiability | **Does not currently hold on `main`.** CI checks every push and runs the PostgreSQL and Docker suites, but `main` is red. In this slice, a flaky `petrus-execution` example failed run 38134729883 (EMF-1). Ledger tooling is stale (EMF-9, EMF-10; the docs are fixed). |
