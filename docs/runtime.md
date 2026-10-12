# Runtime port plan

> **Historical plan.** This document is the plan the runtime port was built
> from, kept for its decisions and rationale; it describes the state before
> the work started. The current status of every component is in
> [PARITY.md](../PARITY.md), and each package's intentional differences from
> upstream are in its own `DIVERGENCES.md`.

This is the plan of record for porting everything in `upstream/petrus/src/petrus`
that sits **outside the kernel**: the durable History stores, observation, the
net DSL, `motus` (Activities, Dispatch, execution, Workers, transports), the
Engine and its providers, simulation and its HTTP service, telemetry,
deterministic simulation testing, `agenticus`, and the way `fabric` and
`processes` plug into the Engine. The kernel (`impetus`: petrinet, history and
the schema-5 codec, binding, selection, instance, scope, net definition v3, net
document v1, the in-memory store) and CEL are planned and ported separately; this
document states exactly what each component here needs from them.

It is a research and planning document. No Haskell code exists yet for anything
it covers. It is meant to be read by the engineers who will build these
packages, and it is the place where decisions about interop, package layout and
parallel work are recorded.

- **Pin.** Every statement is about `henriquebastos/petrus` at
  `3f85fc2094e50ece48bcf6bf9ace19cb0a22a544` (see [UPSTREAM.md](../UPSTREAM.md)).
  File references are relative to `upstream/petrus/` and carry line numbers at
  that pin. When the pin moves, `scripts/upstream-diff` lists the files whose
  sections here must be re-checked.
- **Normative sources.** Where this document and upstream disagree, upstream
  wins: the specs in `upstream/petrus/spec/`, then the upstream tests, then the
  upstream code. This document quotes SQL, wire shapes and error texts
  verbatim so that porters rarely need to go back to the Python, but the
  conformance and interop suites must check against the real thing.
- **"Must" versus "suggest".** Anything under *Wire formats*, *Concurrency &
  durability* and *quirks to preserve* is a requirement for parity (README:
  byte-identical wire formats; Python and Haskell share stores and talk to each
  other). Anything under *Better the Haskell way* is a suggestion to be decided
  case by case; every divergence that is adopted must be recorded next to the
  package that makes it, as the README requires.

## Contents

1. [How to read the component sections](#1-how-to-read-the-component-sections)
2. [Upstream map](#2-upstream-map)
3. [Cross-cutting interop rules](#3-cross-cutting-interop-rules)
4. [History stores, Fabric, processes](#4-history-stores-fabric-and-processes)
5. [Observation and simulation](#5-observation-and-simulation)
6. [Engine](#6-engine)
7. [Activities and Dispatch](#7-activities-and-dispatch)
8. [Workers and the ZeroMQ transport](#8-workers-and-the-zeromq-transport)
9. [Private execution and Gondolin](#9-private-execution-and-gondolin)
10. [DSL, telemetry, deterministic simulation testing, project checks](#10-dsl-telemetry-deterministic-simulation-testing-and-project-checks)
11. [Agenticus core](#11-agenticus-core)
12. [Agenticus runtime adapters](#12-agenticus-runtime-adapters)
13. [Inventories](#13-inventories)
14. [Package decomposition and build order](#14-package-decomposition-and-build-order)
15. [Risks and open questions](#15-risks-and-open-questions)

## 1. How to read the component sections

Sections 4 to 12 have one `###` heading per component, each with the same
eight numbered sub-sections:

1. **Responsibility & public API**, including the exact kernel APIs it uses.
2. **Wire formats, durable schemas, protocols**: verbatim SQL, JSON spellings,
   file layouts, HTTP, framing, and the spec documents it must honor.
3. **Concurrency & durability semantics**: transactions, locks, LISTEN/NOTIFY,
   leases, retries, idempotency, crash recovery.
4. **External dependencies**, with suggested Hackage packages and the gaps.
5. **Upstream tests**: organization, counts, and what each needs to run.
6. **Performance**: hot paths and a fair Python-versus-Haskell benchmark.
7. **Better the Haskell way**: suggestions, plus upstream quirks that must be
   kept for interop.
8. **Packaging**: where it goes, what it needs, and what it can be built in
   parallel with.

Sections 13 to 15 are the cross-component summaries: inventories of every
durable store, protocol, dependency, test suite and benchmark; the package
graph and build order; and the risks.

## 2. Upstream map

### Size

| Area | Upstream files | Lines (src) | Test functions | Section |
| --- | --- | ---: | ---: | --- |
| History stores (JSONL, SQLite, Postgres) | `impetus/history_store/{jsonl,sqlite,postgres}.py` | 915 | 79 (4 files) | 4 |
| Fabric | `fabric/*` | 696 | 12 | 4 |
| Processes | `processes/*` | 637 | 19 | 4 |
| Observation | `impetus/observation.py`, `engine/observation_http.py` | 339 | 26 (2 files) | 5 |
| Simulation | `simulation.py`, `simulation_http.py` | 781 | 43 (2 files) | 5 |
| Engine and providers | `engine/{__init__,_coordination,sqlite,postgres,_postgres,absurd}.py` | 1,797 | 221 (5 files) | 6 |
| Activities | `motus/activity` | 493 | (via dispatch, worker, integration) | 7 |
| Dispatch | `motus/dispatch/{__init__,local,absurd}.py` + vendored `absurd-0.4.0.sql` | 2,243 (+3,086 SQL) | 122 (3 files) | 7 |
| Workers | `motus/worker/*` | 824 | 74 (3 files) | 8 |
| ZeroMQ transport | `motus/transport/*` | 1,075 | 26 | 8 |
| Execution, Gondolin | `motus/execution/*`, `motus/_execution/*` (incl. `gondolin_sidecar.mjs`) | 3,722 | 71 (4 files) | 9 |
| Net DSL | `impetus/dsl.py` | 881 | 42 | 10 |
| Telemetry | `telemetry.py` | 268 | 51 (2 files) | 10 |
| Deterministic simulation testing | `testing/dst.py` | 2,656 | 193 (23 files) + 53 fixtures | 10 |
| Project checks | `tests/project/*` | — | 30 (6 files) | 10 |
| Agenticus core | `agenticus/{attachment,catalog,connection,effect,hands,program,thread}` | 8,520 | 154 (16 files) | 11 |
| Agenticus runtime | `agenticus/runtime/*` (incl. 3 `.mjs` helpers) | 12,361 | 254 (15 files) | 12 |
| Integration seam | `tests/integration/test_activity_seam.py` | — | 100 | 7 (mostly kernel) |

Test-function counts are `def test_*` per file at the pin; parametrization and
Hypothesis multiply the executed cases (each component section gives the
expanded numbers where they matter).

### Dependency graph

Computed from the `import` statements at the pin, collapsed to the second package
level. Arrows read "imports".

```
impetus.petrinet      -> impetus.scope
impetus.history       -> impetus.petrinet, impetus.scope, motus.activity      (!)
impetus.binding       -> impetus.petrinet, motus.activity                     (!)
impetus.instance      -> impetus.{binding,history,history_store,petrinet,scope}, motus.activity, telemetry
impetus.history_store -> impetus.history, telemetry
impetus.selection     -> impetus.{history,petrinet}
impetus.observation   -> impetus.{history,instance,net_definition,net_document,petrinet}, motus.activity
impetus.dsl           -> impetus.{binding,petrinet}, motus.activity
motus.dispatch        -> motus.activity, telemetry
motus.execution      <-> motus._execution                                    (no kernel)
motus.transport       -> motus.{activity,dispatch}
motus.worker          -> motus.{activity,dispatch,transport}, telemetry
engine._coordination  -> impetus.{binding,history,instance,petrinet,scope,selection}, motus.{activity,dispatch}, telemetry
engine                -> engine._coordination, impetus.*, motus.{activity,dispatch}
engine.{sqlite,postgres,absurd} -> engine, impetus.history_store (+ motus.dispatch for absurd)
engine.observation_http -> engine
simulation            -> engine, impetus.{dsl,history,history_store,net_document,observation,petrinet}
simulation_http       -> simulation, impetus.{dsl,petrinet}
fabric                -> impetus.{instance,petrinet}, telemetry
processes             -> fabric, motus.activity, telemetry
agenticus.catalog     -> (nothing in petrus)
agenticus.hands       -> agenticus.catalog, motus.execution
agenticus.thread      -> agenticus.{catalog,program}
agenticus.program     -> agenticus.{catalog,hands,thread}, impetus.{binding,dsl,petrinet}, motus.activity
agenticus.attachment  -> agenticus.{catalog,connection,hands,thread}, motus.execution
agenticus.runtime     -> agenticus.*, engine, impetus.{history,history_store}, motus.{activity,dispatch,execution}
```

Three facts from this graph shape the whole plan:

1. **The kernel already depends on two things this document covers.**
   `impetus.history`, `binding`, `instance` and `observation` import value
   types from `motus.activity` (`ExecutionPolicy`, `ActivityInvocation`,
   `ActivityFailure`, `ActivityDefinition`, `PayloadConverter`,
   `DataclassPayloadConverter`), and `instance` and the stores import
   `petrus.telemetry`. In Haskell these must sit *below* the kernel: the
   Activity value types (with their exact JSON spellings, section 7) and a
   telemetry facade (section 10) are the first two packages to build, and the
   kernel porters need them now.
2. **Large parts have no kernel dependency at all**: Activity values, Dispatch
   protocols and the Local and Absurd providers, Workers, the ZeroMQ transport,
   the whole execution substrate and Gondolin, Fabric and processes models, the
   agenticus catalog/connection/effect/hands/thread layers, the HTTP cores, and
   the DST interpreter's artifact format. These can start immediately, in
   parallel with the kernel (section 14).
3. **The Engine is the one join point**: simulation, observation HTTP, the
   Engine providers, the agent-net runner and every integration test wait for
   it, and it waits for `Instance`.

## 3. Cross-cutting interop rules

These rules recur in many components. Each component section repeats the ones
that apply to it with the exact details; this section exists so that nobody
discovers them one component at a time.

### 3.1 There is no single JSON spelling

Python and Haskell processes must produce the same bytes wherever bytes are
hashed, compared as text, stored as text, or framed on a wire. Upstream uses at
least these `json.dumps` spellings, and every one is expressible with
`Petrus.Json.EncodeOptions`:

| Surface | `json.dumps` arguments | `petrus-json` | Section |
| --- | --- | --- | --- |
| JSONL History store lines | defaults (`", "`, `": "`, `ensure_ascii=True`), `allow_nan=False`, `\n` per record | `defaultDumps {allowNan = False}` | 4 |
| SQLite History store `payload` | `separators=(",",":")`, `ensure_ascii=True`, `allow_nan=False` | `compact {ensureAscii = True}` (not `compact`) | 4 |
| Postgres History store | sent as `::jsonb`; Postgres normalizes, so bytes do not matter on write; **read the column as text** and parse with `surrogateRefusingLoads` | — | 4 |
| Fabric envelope digest, process child ids, canonical conflict text | `sort_keys=True, separators=(",",":"), ensure_ascii=False, allow_nan=False` | `canonicalText` | 4 |
| Local Dispatch stored JSON (compared as text) | same as canonical | `canonicalText` | 7 |
| ZeroMQ Worker transport frames | same as canonical, UTF-8 | `canonicalText` | 8 |
| Observation HTTP bodies (all routes, incl. `/v1/document`) | compact, `sort_keys=True`, `ensure_ascii=True` | `compact {sortKeys = True, ensureAscii = True}` | 5 |
| Simulation HTTP profile and errors | compact, sorted, `ensure_ascii=False` | `canonicalText` | 5 |
| Simulation HTTP `200` body | the Net document writer: `indent=2`, insertion order, `ensure_ascii=False`, trailing `\n` | `indented` | 5 |
| Gondolin `registry.json` | `sort_keys=True`, default separators, no trailing newline, atomic replace + fsync | `defaultDumps {sortKeys = True}` | 9 |
| Gondolin sidecar socket frames | one JSON line per connection, `\n`-terminated, 8 MiB cap | see section 9 | 9 |
| Codex Gondolin service frames | `sort_keys=True`, `ensure_ascii=True`, compact, `\n`-terminated | `compact {sortKeys = True, ensureAscii = True}` | 12 |
| Worker / dispatch-server readiness and event lines on stdout | defaults (spaces after separators) | `defaultDumps` | 8 |
| Agent-net `thread.json` | canonical, no trailing newline, atomic replace | `canonicalText` | 12 |
| DST world artifacts (`petrus-dst-world` v1–v4) | compact, `sort_keys=True`, `ensure_ascii=True`, trailing `\n` | `compact {sortKeys = True, ensureAscii = True}` | 10 |
| Telemetry event lines (logger `impetus.telemetry`) | defaults, insertion order, `ts` (int ms) last | `defaultDumps` | 10 |
| Docker labels / E2B metadata spec fingerprint | sha256 of canonical `{"image": …}` | `canonicalText` | 9 |

Decoding is just as specific:

- Stores and wire readers use CPython `json.loads` defaults (`surrogateRefusingLoads`):
  NaN and Infinity accepted, last duplicate key wins. Strict decoders (net
  documents, simulation requests) use `strictLoads`.
- CPython refuses integers longer than 4,300 digits when *parsing* (and
  printing). The simulation HTTP request body and the observation history query
  depend on that limit; `petrus-json` does not implement it yet.
- **Equality differs by surface.** Most verify-on-conflict paths (History store
  re-append, identified delivery redelivery, late Activity results) use Python
  value equality, where `1 == 1.0 == True` (`pythonEq`), except where upstream
  first compares canonical text, which distinguishes `1`, `1.0` and `true`
  (Local Dispatch, Engine delivery identity, ZeroMQ custody). The simulation
  definition-mismatch check (409) needs a member-order-insensitive equality that
  treats `0.0 == -0.0`, which `exactEq` does not provide. Each section names
  which one applies.
- PostgreSQL `jsonb` reorders keys, may print large floats such as `1e16` as
  integers, and rejects `\u0000`. Code that reads `jsonb` back and compares it
  must use the same Python semantics as upstream does after psycopg decodes it.
- Never decode a wire value into a lossy Haskell record and re-encode it. Several
  paths (ZeroMQ custody, Local Dispatch conflict checks) compare the canonical
  re-encoding of what was received, so `0` versus `0.0` and CPython's float
  repr must survive the round trip. Keep `Petrus.Json.Json` (or a type that
  embeds it) at those boundaries.

**Gaps to add to `petrus-json`** (reported by the section 5 research): the
CPython integer-digit limit on parse; an order-insensitive structural equality
with `0.0 == -0.0`; a recursion-depth guard so deeply nested input fails like
CPython instead of exhausting the stack.

### 3.2 Hash-derived identities

Several durable keys are derived by hashing. They must be bit-identical, and each
has golden vectors in its section.

| Identity | Derivation | Section |
| --- | --- | --- |
| Postgres writer fence (advisory lock key) | first 8 bytes of `sha256(b"impetus-authority\0" + utf8(instance))`, big-endian **signed** int64 | 6 |
| SQLite writer fence file | `<resolved db dir>/.impetus-sqlite-locks/<sha256(resolved db path)>.<sha256(instance)>.lock` | 4, 6 |
| History event id | `"{instance}:{position}"` (0-based) | 4 |
| Absurd idempotency key | `"{instance}:occurrence-{occurrence}"` | 7 |
| Fabric ingress identity | `fabric:{len(sender) in code points}:{sender}:{delivery_id}` | 4 |
| Fabric envelope digest | sha256 of the canonical envelope | 4 |
| Process child id | `"process-v1-" + sha256(b"impetus-process-child\0" + canonical{version, parent, spawn_id})` | 4 |
| Process spawn idempotency | `"process.spawn:" + child id` | 4 |
| Gondolin operation directory | first 24 hex chars of the operation's sha256 | 9 |
| Docker label / E2B metadata spec | `run.petrus.spec` = sha256 of canonical `{"image": …}` | 9 |
| Workspace archive digest (persisted by agenticus) | sha256 of the deterministic PAX tar | 9, 11 |

Path-derived hashes depend on Python's `Path.resolve()` output (on macOS `/tmp`
resolves to `/private/tmp`); Haskell must canonicalize the same way
(`canonicalizePath`) and the interop tests must cover a symlinked directory.

### 3.3 File locks are BSD `flock(2)`

Every cross-process file lock upstream is `fcntl.flock` (BSD `flock`), not
POSIX record locks: the SQLite writer fence (sections 4 and 6), the ZeroMQ IPC
ownership lock (section 8), the Gondolin operation lock (section 9), and the
agenticus SQLite ledgers' `.<db>.writer.lock` files (territory custody in
section 11, the Pi operation ledger in section 12). On Linux, GHC's `hLock`/`hTryLock` uses OFD
locks, and `unix`'s `setLock` uses POSIX record locks; **neither excludes a
`flock` holder**, so a Python and a Haskell process would both believe they
hold the lock. Use `lukko`'s `Lukko.FLock` or a three-line FFI to `flock`, and
add a cross-language exclusion test for every lock.

Upstream also re-checks the lock file's inode after acquiring (Gondolin) and
closes inherited fence descriptors after `fork` without unlocking (SQLite).
Haskell programs rarely fork, but the `ensure` check (refuse to use an Engine
inherited across `fork`) must exist.

### 3.4 SQLite DDL is compared as text

The SQLite History store, the Local Dispatch store and the Codex Gondolin
service validate an existing database by comparing `sqlite_master.sql`
(whitespace collapsed, lowercased) against their own DDL, and also check
`PRAGMA table_info`/`index_info`/`foreign_key_list`. A Haskell process that
creates a table with equivalent but differently written DDL produces a file
Python refuses. **Copy the DDL strings verbatim** (they are in sections 4, 7, 11
and 12). The same applies to the version tables and their migrations. The
agenticus ledgers decode rows positionally from `SELECT *`, so column order is
part of the format as well.

SQLite connection settings are shared too: WAL, `synchronous=FULL`,
`busy_timeout=5000`, `foreign_keys=ON`, `BEGIN IMMEDIATE` for writes (the Pi
ledger and the connection custody store use `journal_mode=DELETE`; territory
custody sets `secure_delete=ON`). A shared connection helper with these
PRAGMAs avoids drift.

### 3.5 PostgreSQL: one joined transaction, three channels

- The Engine's Postgres and Absurd providers run on a connection with
  `autocommit=False` and the Engine decides every commit point (section 6). The
  isolation level is psycopg's default, READ COMMITTED, which the
  verify-on-conflict logic relies on.
- In the Absurd composition, the begin batch, `absurd.spawn_task` and
  `pg_notify('impetus_dispatch', queue)` commit together; Workers ring
  `impetus_results` after their terminal commit; the Engine listens on a
  separate autocommit connection with a 0.25 s poll as a safety net. Fabric's
  `submit` notifies `impetus_fabric_delivery` with the recipient as payload, but
  nothing upstream listens (delivery is polled).
- Session advisory locks are the writer fence; there is no lease, TTL or
  fencing token behind them, so a lost connection must be treated as fatal.
- Library choice: `postgresql-libpq` directly, or `postgresql-simple` on top of
  it, gives explicit transaction control and `LISTEN`/`PQnotifies`. `hasql`
  lacks first-class LISTEN and pipelines statements in ways that make the
  commit-counting tests harder; avoid it for the joined connection. All
  Postgres-backed packages should share one small connection layer (join mode
  versus owned transactions, notification waiting, the fence), so that the
  History store, Absurd Dispatch, Fabric and processes can share one
  transaction exactly as upstream does.
- Tests use `postgres:17.5-alpine@sha256:6567bca8…` started by the root
  `conftest.py` in Docker, and fail rather than skip without Docker
  (`--forbid-skips`). The Haskell suites should use the same image digest.

### 3.6 Non-Haskell helpers stay

Following [SCOPE.md](../SCOPE.md), some helpers are kept and driven over their
existing protocol rather than rewritten:

| Helper | Language | Why it stays | Section |
| --- | --- | --- | --- |
| `motus/_execution/gondolin_sidecar.mjs` | Node (≥ 23.6, `@earendil-works/gondolin` 0.12.0) | Gondolin is a Node SDK | 9 |
| `agenticus/runtime/pi_helper.mjs`, `pi_application_helper.mjs`, `pi_model_phase_helper.mjs` | Node (≥ 22.19, Pi 0.83.0 libraries) | Pi is a set of Node libraries; the NDJSON bridge is Petrus-owned | 12 |
| Codex private helper (`_HELPER_SOURCE` in `codex.py`) | Python, run as `/usr/bin/python3` **inside the Gondolin guest** | It runs in the VM, not the host; bytes must match | 12 |
| Claude adapter sidecar (new) | Python, `claude-agent-sdk==0.2.128` | The SDK speaks the CLI's undocumented control protocol and upstream reaches into SDK private attributes | 12 |
| Amp adapter sidecar (new) | Python, `amp-sdk==0.1.20260729121202` | SDK-only; the `amp --stream-json` schema is not vendored | 12 |

Ship these as cabal `data-files`, verbatim from the pin, with a test asserting
their hash matches the upstream file. The two new Python sidecars are the only
places where the port adds a non-Haskell component; their protocol is ours to
define and must be documented next to the package that owns them.

### 3.7 Interop and benchmark harnesses

Both are shared infrastructure every component below relies on, so they should be
built once:

- **Interop harness.** A `uv`-managed environment from `upstream/petrus`
  (`uv sync --frozen --extra postgres --extra absurd --extra zeromq`) plus small
  Python driver scripts that act as the "other side": write a store, then the
  Haskell side reads it and vice versa; hold a lock and check exclusion; act as
  a ZeroMQ client or server; act as a Worker against a Haskell-dispatched
  queue. Upstream already contains two end-to-end demos
  (`scripts/cv5-fabric-demo.py`, `scripts/cv5-lifecycle-demo.py`) that its own
  acceptance tests run and match by stdout; they are the natural first
  cross-language scenarios (a Python parent spawning a Haskell child and the
  reverse). `scripts/check-all` already calls `scripts/interop` when present.
- **Benchmark harness.** For each benchmark, one workload definition (a net
  definition v3 file, an initial marking, a seed and a size), a Python runner
  using the pinned upstream via `uv run`, and a Haskell runner (`tasty-bench` or
  `criterion`), both writing the same result JSON. Equivalence is checked before
  timing is trusted: the final History, encoded with the schema-5 codec, must be
  byte-identical between the two runs. Durable benchmarks report fsyncs/commits
  per action alongside latency, because those counts are part of the
  behavior. Section 13.5 lists every proposed benchmark.

## 4. History stores, Fabric, and processes

### History Store contract and durable backends (`impetus/history_store`)

Upstream files: `src/petrus/impetus/history_store/{__init__,memory,jsonl,sqlite,postgres}.py`
(12 + 46 + 192 + 385 + 338 lines). The memory store is ported with the kernel (`petrus-impetus`)
and only appears here as the reference contract. The record codec is
`src/petrus/impetus/history/codec.py` (schema 5). The kernel port specifies it; this section only
says how the stores use it. Spec: `spec/event-history.md` (one append-only, uncompacted history per
net instance; single writer; "canonical close/reset MUST commit before any cancellation";
"first terminal Activity fact wins"; "exact redelivery … acknowledged, conflicting value fails loud";
schema 5 only, no schema-4 decode or migration). Decision records:
`docs/project/decisions/records/2026-07-10T1900Z-durable-history-is-a-history-backend.md` and
`2026-07-23T1356Z-history-store-and-dispatch-profile-convergence.md` define the profile names:
In-Memory, Local, and Transactional History Store.

#### 1. Responsibility & public API

**The contract.** `HistoryStore` is a structural `Protocol` (`memory.py:11-23`):

```python
class HistoryStore(Protocol):
    @property
    def records(self) -> tuple[Record, ...]: ...     # snapshot; InMemory copies the list each call (memory.py:38-40)
    def append(self, record: Record) -> None: ...      # == extend([record]) in every durable backend
    def extend(self, records: list[Record]) -> None: ...  # ONE commit batch
    def __iter__(self) -> Iterator[Record]: ...
    def __len__(self) -> int: ...
```

Contract semantics:

- **Batch.** One `extend` call is one commit batch. Every Instance door writes all of its records in
  a single `extend`, for example the construction records at `instance/__init__.py:898` and the begin
  batch at `:1510`. The batch is fully encoded before any IO. If encoding fails, the error is raised
  loudly and nothing reaches the sink or memory (`jsonl.py:162-179`, `sqlite.py:318`,
  `postgres.py:237`).
- **Durable before memory.** Memory is extended only after the durable write returns. Memory never
  holds more than durable storage. In joined-Postgres mode, "durable" means "visible in the caller's
  transaction".
- **No expected-length or optimistic-concurrency parameter.** The implicit expected length is
  `len(self)`, the in-memory count. Each record's event identity is `f"{instance}:{position}"` with
  `position = len(self)`, advanced per entered record (`sqlite.py:322-334`, `postgres.py:264-280`).
  A stale writer collides on that identity. The DB unique constraints act as the cross-process
  backstop, not as a coordination protocol. The real single-writer guarantee comes from the
  Engine-level fences (SQLite `flock`, Postgres advisory lock).
- **Acknowledgement (DB backends only).** When an insert conflicts, the store re-reads the row and
  compares payloads by **value** (Python `==` on `json.loads` results):
  - Equal at the same event identity: the record "fills the position". It enters memory and the
    position advances.
  - Equal at a different position, i.e. the conflict is the one-terminal partial index: the record is
    acknowledged elsewhere. It does **not** enter memory and the position does **not** advance
    (`postgres.py:283-338`, `sqlite.py:353-382`).
  - Different payload: `ValueError`.
  - Conflict with no explaining row: `RuntimeError`.
- **Reads.** The whole history is loaded at construction and kept in memory. There is **no paging in
  the store**. Paging is `petrus.impetus.observation.history_page` over `records`
  (`engine/__init__.py:370-374`), which belongs to the observation component.
- **Errors (exact Python types).**
  - `ValueError`: encode refusal (message contains the record class name and "JSON-faithful"), decode
    failure on load (names line or event), conflicting fact, schema refusal, empty or non-str instance.
  - `RuntimeError`: unexplained conflict; SQLite fence refusal; fork misuse.
  - `ImportError`: psycopg missing (`postgres.py:79-85`).
  - OS errors propagate unchanged.

**The kernel's use of the store** (`instance/__init__.py:871-876`):

- `Instance(...)` refuses a store whose `len(history) != 0` ("cannot construct an Instance over a
  recorded history").
- `Instance.resume(net, history, ...)` replays `history.records`.
- `Engine.create` requires `len(history) == 0`. `Engine.load` requires `len > 0` and requires the
  recorded `InstanceCreated` identity to equal the storage key exactly (`engine/__init__.py:164-187`).

Kernel APIs used: `petrus.impetus.history.Record` (the union), the record classes (via the codec),
`codec.encode_record`, `codec.decode_record`, and the `InMemoryHistoryStore` composition (each durable
store wraps one).

**Concrete classes.**

| Class | Ctor | Extra API |
| --- | --- | --- |
| `InMemoryHistoryStore()` | – | – |
| `DurableAppend(path)` | `jsonl.py:98-99` | `append(lines: list[str])` |
| `JsonlHistoryStore(path)` | `jsonl.py:127-142`; loads the existing file | – |
| `SqliteHistoryStore(path, instance: str)` | `sqlite.py:148-166` | `close()` |
| `PostgresHistoryStore(connection, instance: str)` | `postgres.py:174-196` | – (module function `ensure_schema(connection)`) |
| `_WriterFence(path, instance)` (private, SQLite hosting) | `sqlite.py:74-128` | `ensure()`, `close()` |
| `PostgresAuthorityFence(connection, instance)` (private, `engine/_postgres.py:36-62`) | – | `close()` |

Facade: `petrus.impetus.history_store` exports `DurableAppend, HistoryStore, InMemoryHistoryStore,
JsonlHistoryStore, SqliteHistoryStore`. Postgres is opt-in through
`petrus.impetus.history_store.postgres`. Importing the facade must never import psycopg
(`tests/project/test_package_boundaries.py:306-345`).

**How the stores plug into the Engine.** The Engine receives them through `history=`. First-party
providers also pass a private `_EngineResources(commit, rollback, release, close, ensure, wait)`
(`engine/__init__.py:63-71`):

- **SQLite** (`engine/sqlite.py:9-36`):
  1. Take `_WriterFence(path, instance)` **before** loading.
  2. Construct `SqliteHistoryStore(path, instance)`.
  3. Pass `resources = _EngineResources(release=fence.close, close=history.close, ensure=fence.ensure)`.
  4. `commit` is `None`, because every batch auto-commits.
- **Postgres** (`engine/postgres.py:26-64`):
  1. Require an `autocommit=False` connection.
  2. Take `PostgresAuthorityFence(connection, instance)` (`pg_try_advisory_lock`).
  3. Construct `PostgresHistoryStore(connection, instance)`, which joins the caller transaction.
  4. Pass `resources.commit = connection.commit`, `rollback = connection.rollback`
     (psycopg errors swallowed), `release = fence.close + rollback`, `close = connection.close`.
- **Absurd** (`engine/absurd.py:12-78`): same as Postgres, plus a separate autocommit LISTEN
  connection.
- **After every writing door**, `Engine._committed()` calls `resources.commit()`
  (`engine/__init__.py:543-545`). For Postgres this is the transaction boundary for each door. Any
  exception in a door "poisons" the Engine: it calls `rollback()` and then closes resources
  (`:547-560`). The only valid continuation is a fresh `load`.

#### 2. Wire formats, durable schemas, protocols

**Common record payload.** The payload is `encode_record(record)`, an ordered dict:
`{"record": <class name>, "schema": 5, <dataclass fields in declaration order>}` (`codec.py:29-32`).
Each backend serializes it with **different `json.dumps` options**. Byte-exactness matters for JSONL
(pinned by tests) and is advisory for SQLite. Postgres has no byte format because jsonb normalizes.

| Backend | Python call | petrus-json equivalent |
| --- | --- | --- |
| JSONL line | `json.dumps(enc, allow_nan=False)`: separators `", "`/`": "`, `ensure_ascii=True`, key order kept (`jsonl.py:187`) | `defaultDumps {allowNan = False}` |
| SQLite `payload` | `json.dumps(enc, allow_nan=False, separators=(",", ":"))`: **`ensure_ascii=True`** (`sqlite.py:345`) | `defaultDumps {itemSeparator = Just ",", keySeparator = ":", allowNan = False}`. NOT `compact`, which sets `ensureAscii = False`. |
| Postgres `payload` param | `json.dumps(enc, allow_nan=False)` sent as `%s::jsonb` (`postgres.py:249, 273-275`) | any; the server re-normalizes |

All three use `allow_nan=False`. NaN or ±Infinity raises
`ValueError("cannot durably encode <Type>: … JSON-faithful values")`. Non-JSON Python objects raise
the same (`TypeError` is wrapped). In Haskell, encode failure is mostly unrepresentable except
non-finite doubles. Keep the `NonFiniteNumber` path and the message shape (tests match
`"TokensInitialized"`, `"TokensProduced"` and `"JSON-faithful"`).

**JSONL file format** (`jsonl.py`):

- **File.** One record per line, append order. Each line is the JSONL spelling above plus `"\n"`
  (LF; text mode on POSIX does no translation). Written with `encoding="utf-8"`, but lines are pure
  ASCII because of `ensure_ascii=True`.
- **Byte fixture to reproduce exactly** (`tests/…/test_persistence.py:418-424` and `:444-454`):
  ```
  {"record": "TokensInitialized", "schema": 5, "place": "p", "tokens": [{"color": "issue", "data": {"id": "goose", "passed": true}}], "instant": 0, "entries": [], "scope": null}
  {"record": "CandidateSelected", "schema": 5, "transition": "t", "occurrence": 1, "instant": 2}
  ```
- **Write (`DurableAppend.append`, `jsonl.py:101-105`).**
  1. `mkdir -p` the parent directory.
  2. Open with `"a"`, call `writelines(line + "\n" …)`, close.
  3. There is **no fsync** and no held handle. The documented posture is "durable across a process
     crash, not power failure".
  4. The JSONL store calls this only after encoding the whole batch (`jsonl.py:171-173`). An encode
     failure means the file is never even opened, and it is **not created** if missing
     (test `test_unencodable_data_fails_loud_and_appends_nothing` asserts `not path.exists()`).
- **Load (`jsonl.py:131-142`).**
  1. A missing file means an empty history. Construction does not create the file; the first append
     does.
  2. Read text with `for number, line in enumerate(file, start=1)` and decode each line with
     `decode_record(json.loads(line))`.
  3. On `ValueError`/`TypeError`, raise `ValueError(f"{path}: line {number} does not decode as an
     event history record: {error}")`. The tests match `r"history\.jsonl.*2"` and
     `r"line 1.*no 'schema' version.*reads schema 5 only"`.
  4. Load is all-or-nothing: records are only added to memory after every line has decoded.
- **Quirks to preserve on load:**
  - Python text mode uses **universal newlines**, so `\r`, `\r\n` and `\n` all split lines. Lines
    never contain a raw CR, so splitting on `\n` with an optional `\r` strip is equivalent for valid
    files.
  - A blank line fails (`json.loads("")`).
  - A **complete final line with no trailing `\n` loads fine**. Torn detection only triggers when the
    JSON is invalid. The next append would then glue onto that line. Reproduce this posture; do not
    "repair".
  - Load uses `json.loads` **defaults**: `NaN`/`Infinity` literals are accepted and duplicate keys are
    last-wins. Use petrus-json `surrogateRefusingLoads`, not `strictLoads`.
  - A complete-line prefix that splits a commit batch loads, but resume refuses it later (replay
    divergence). That is a kernel concern.
- **Locking: none.** The instance is the single writer. Concurrent appends are out of scope
  (`jsonl.py:54-59`).
- **Schema versioning:** per record only (`"schema": 5`). The file has no header.

**SQLite schema** (`sqlite.py:43-69`). This is the verbatim DDL. `_SCHEMA_VERSION = 1`.

```sql
CREATE TABLE impetus_history_schema (
    component TEXT PRIMARY KEY CHECK (component = 'history'),
    version INTEGER NOT NULL
)
INSERT INTO impetus_history_schema (component, version) VALUES ('history', 1)
CREATE TABLE impetus_history_events (
    instance TEXT NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    event_id TEXT NOT NULL UNIQUE,
    record_type TEXT NOT NULL,
    occurrence INTEGER,
    payload TEXT NOT NULL,
    recorded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    PRIMARY KEY (instance, position)
)
CREATE UNIQUE INDEX impetus_history_one_firing_terminal
    ON impetus_history_events (instance, occurrence)
    WHERE record_type IN ('FiringCompleted', 'FiringFailed')
CREATE UNIQUE INDEX impetus_history_one_activity_terminal
    ON impetus_history_events (instance, occurrence)
    WHERE record_type IN ('ActivityCompleted', 'ActivityFailed')
```

The schema is never migrated. The checks below are **interop-critical**: Python validates
`sqlite_master.sql` text, so Haskell must create the objects with these exact DDL strings. Python
compares after normalizing with `re.sub(r"\s+", " ", sql.strip()).lower()` (`sqlite.py:258-264`).

| Step | SQL / check | Result |
| --- | --- | --- |
| Preflight, before any PRAGMA can touch the file (`sqlite.py:168-186`) | `SELECT name, type FROM sqlite_master WHERE name LIKE 'impetus_history_%'` | Empty: fresh. |
| | Otherwise `impetus_history_schema` must be a `table` | Else `ValueError "foreign or unversioned impetus_history schema; migration is not supported"`. |
| | `PRAGMA table_info(impetus_history_schema)` column names must be `["component","version"]` | Else error. |
| | `SELECT component, version FROM impetus_history_schema` must equal exactly `[("history", 1)]` | Else `ValueError "… unsupported impetus_history schema metadata [...]; this store reads version 1 only and does not migrate"`. The file bytes are left untouched; a test asserts this. |
| Configure (`sqlite.py:188-205`) | `PRAGMA busy_timeout = 5000`; `PRAGMA foreign_keys = ON`; `PRAGMA synchronous = FULL`; `PRAGMA journal_mode = WAL` | The WAL pragma is retried every 10 ms for up to 5 s while the error text contains "locked". The result must be `wal`, else `ValueError`. |
| Ensure (`sqlite.py:207-275`), inside `BEGIN IMMEDIATE` | Re-read `sqlite_master` | Empty: run the 5 DDL statements. Otherwise re-check the metadata as in preflight. |
| | The object set must equal exactly `{impetus_history_schema: table, impetus_history_events: table, impetus_history_one_firing_terminal: index, impetus_history_one_activity_terminal: index}` | Else "corrupt or foreign … shape". |
| | `SELECT name, sql FROM sqlite_master WHERE name IN (?, ?, ?, ?)` must equal the normalized DDL[0], [2], [3], [4] | Else "… DDL shape". A weakened index with the same name is refused (test). |
| | `PRAGMA table_info(impetus_history_events)` names must be exactly `instance, position, event_id, record_type, occurrence, payload, recorded_at` | Else "event shape". |

Other tables in the same DB are allowed and preserved, for example Dispatch state (test). Note that
`LIKE` treats `_` as a wildcard and is ASCII case-insensitive. Mirror the same query.

- **Connection.** Python opens with `sqlite3.connect(path, timeout=5.0, isolation_level=None)`, which
  is autocommit with explicit `BEGIN`. The parent directory is created first (`sqlite.py:152`).
- **Load (`sqlite.py:277-299`).**
  - Query: `SELECT position, event_id, record_type, occurrence, payload FROM impetus_history_events WHERE instance = ? ORDER BY position`
  - For row *i*, require `position == i` and `event_id == f"{instance}:{i}"`. Otherwise raise
    `ValueError "… non-dense or has corrupt event identity at position i"`.
  - Decode `json.loads(payload)`, then `decode_record`. On failure raise
    `ValueError "event <id> does not decode as an event history record: …"`.
  - Require `type(record).__name__ == record_type` and `encoded.get("occurrence") == occurrence`.
    Otherwise raise `"event <id> has corrupt indexing metadata"`.
- **Append (`sqlite.py:317-339`).**
  1. Encode the whole batch.
  2. `BEGIN IMMEDIATE`.
  3. Set `position = len(self)`. For each record, run
     `INSERT INTO impetus_history_events (instance, position, event_id, record_type, occurrence, payload) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING`.
     This is a target-less upsert that absorbs PK, `event_id` UNIQUE and partial-index conflicts.
  4. If `cursor.rowcount == 0`, verify:
     1. `SELECT record_type, payload FROM impetus_history_events WHERE event_id = ?`. If a row exists
        and the payloads are value-equal, the record enters. If it exists and differs, raise
        `ValueError "event <id> is already recorded as a different fact (stored X, appending Y)"`.
     2. Otherwise, for terminal families only:
        `SELECT event_id, record_type, payload FROM impetus_history_events WHERE instance = ? AND occurrence = ? AND record_type IN (?, ?)`.
        Equal means "acknowledged elsewhere": skip it, with no position advance. Different raises
        `ValueError "occurrence N of <inst> already holds its terminal fact (...)"`. No row raises
        `RuntimeError`.
  5. `COMMIT`. On any exception, `ROLLBACK` and re-raise.
  6. Memory is extended with the entered records only.
- **Columns.** `record_type` is the class name. `occurrence` is `encoded.get("occurrence")`: an
  integer, or NULL when the record has no `occurrence` field or it is `None`. `recorded_at` is wall
  clock from the DB, e.g. `2026-10-10T12:00:00.123Z`. It is audit-only and never read.
- **Equality** is Python `==` over `json.loads` values, so `1 == 1.0 == True`. Use petrus-json
  `Eq` (`pythonEq`), not `exactEq`.

**SQLite writer fence** (`sqlite.py:74-138`; used by `engine/sqlite.py`). It must interoperate
between Python and Haskell processes:

- Database path: `database = Path(path).expanduser().resolve()`. This is non-strict realpath, so on
  macOS `/tmp` becomes `/private/tmp`.
- Lock directory: `database.parent / ".impetus-sqlite-locks"`, created with mode `0o700`.
- Lock file:
  `"{sha256_hex(str(database).encode('utf-8'))}.{sha256_hex(instance.encode('utf-8'))}.lock"`,
  opened `O_RDWR|O_CREAT` with mode `0o600`. Example: instance `"one"` hashes to
  `7692c3ad…f431ed`.
- Locking: `fcntl.flock(fd, LOCK_EX | LOCK_NB)`. This is **BSD `flock(2)`**, not POSIX `fcntl`
  record locks. `EACCES`/`EAGAIN` raises
  `RuntimeError "refusing second canonical writer for Instance '<id>' in SQLite database <path>"`.
- The lock file is never deleted.
- Release: `LOCK_UN` + `close`.
- Fork safety: `os.register_at_fork(after_in_child=…)` closes inherited fds without unlocking.
  `ensure()` refuses use in a forked child (`"an Engine inherited across fork cannot be observed or
  driven; open a fresh Engine"`).
- Non-POSIX platforms raise `RuntimeError`.

**Postgres schema** (`postgres.py:116-145`). This is the verbatim DDL, run one statement per
`execute` by `ensure_schema(connection)`. It is idempotent, has **no version metadata table** and no
shape checks. It joins the caller's transaction if one is open.

```sql
CREATE SCHEMA IF NOT EXISTS impetus
CREATE TABLE IF NOT EXISTS impetus.semantic_events (
        sequence bigserial PRIMARY KEY,
        event_id text UNIQUE NOT NULL,
        net_instance_id text NOT NULL,
        record_type text NOT NULL,
        occurrence bigint,
        payload jsonb NOT NULL,
        recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
    )
CREATE INDEX IF NOT EXISTS semantic_events_by_instance
        ON impetus.semantic_events (net_instance_id, sequence)
CREATE UNIQUE INDEX IF NOT EXISTS semantic_events_one_terminal_per_firing_occurrence
        ON impetus.semantic_events (net_instance_id, occurrence)
        WHERE record_type IN ('FiringCompleted', 'FiringFailed')
CREATE UNIQUE INDEX IF NOT EXISTS semantic_events_one_terminal_activity_fact
        ON impetus.semantic_events (net_instance_id, occurrence)
        WHERE record_type IN ('ActivityCompleted', 'ActivityFailed')
```

Statements:

- **Load** (`postgres.py:181-196`):
  `SELECT event_id, payload FROM impetus.semantic_events WHERE net_instance_id = %s ORDER BY sequence`
  - `UndefinedTable` becomes `ValueError "impetus.semantic_events does not exist … provision it with
    petrus.impetus.history_store.postgres.ensure_schema(connection) — a deliberate act, never implied
    by construction"`.
  - A decode failure raises `ValueError "event <id> does not decode as an event history record: …"`.
  - Unlike SQLite there is **no** density, event_id or record_type validation on load.
- **Insert** (`postgres.py:272-276`):
  `INSERT INTO impetus.semantic_events (event_id, net_instance_id, record_type, occurrence, payload) VALUES (%s, %s, %s, %s, %s::jsonb) ON CONFLICT DO NOTHING`
- **Verify by identity**:
  `SELECT record_type, payload FROM impetus.semantic_events WHERE event_id = %s`
  A different payload raises `ValueError "event <id> is already recorded as a different fact:
  refusing to overwrite an appended fact (stored X, appending Y)"`.
- **Verify by terminal**:
  `SELECT event_id, record_type, payload FROM impetus.semantic_events WHERE net_instance_id = %s AND occurrence = %s AND record_type = ANY(%s)`
  Here `%s` is a text array, either `['FiringCompleted','FiringFailed']` or
  `['ActivityCompleted','ActivityFailed']`.
- The event identity is **globally unique across instances** (`event_id text UNIQUE`).
  `"{instance}:{position}"` is injective because position is an integer after the last colon.

Payload equality and jsonb fidelity:

- psycopg loads `jsonb` with `json.loads`. Stored and appended payloads are compared with Python
  `==`.
- **jsonb quirks the Haskell side will see identically** (they come from the server):
  - Key order on read is jsonb order (shorter keys first, then bytewise). `decode_record` must not
    depend on key order.
  - Duplicate keys collapse.
  - Numbers become `numeric`. An exponent float like `1e+16` reads back as the integer
    `10000000000000000`, which Python then treats as an int. It still compares equal.
  - **`\u0000` in any string is rejected by jsonb** (`unsupported Unicode escape sequence`). This
    aborts the transaction, and in joined mode it aborts the caller's transaction.
- **Haskell requirements:**
  - Read `payload` as text (`payload::text`, or the raw text result format) and parse it with
    petrus-json `surrogateRefusingLoads`, preserving the server's member order.
  - Do **not** decode it through aeson `Value`, which loses order and the int/float distinction.

**Engine fence for Postgres** (`engine/_postgres.py:29-56`), listed here because it is the store's
single-writer guarantee:

- Key: `int.from_bytes(sha256(b"impetus-authority\0" + instance.encode()).digest()[:8], "big", signed=True)`.
  For example, `"instance-1"` gives `155117918061411130`.
- Acquire with `SELECT pg_try_advisory_lock(%s)`. A false result raises `RuntimeError "authority
  fence for instance '<id>' is already held: refusing a second canonical writer"`.
- Release with `SELECT pg_advisory_unlock(%s)`. Errors are swallowed: a dead connection has already
  released the lock.

#### 3. Concurrency & durability semantics

| Property | JSONL | SQLite | Postgres |
| --- | --- | --- | --- |
| Batch atomicity | **No.** OS failure mid-batch can leave a prefix (torn line fails at load; a complete-line split batch fails at resume) | Yes, `BEGIN IMMEDIATE` … `COMMIT` | Yes in autocommit mode: `with connection.transaction()` (`postgres.py:238-241`). Joined mode: the caller's transaction |
| Durability | Process crash only (no fsync) | `synchronous=FULL` + WAL means power-safe | Server commit |
| Cross-process writers | Unsupported | Unique constraints are the backstop; the hosting fence is `flock` | Unique constraints plus `pg_try_advisory_lock` (session level) |
| Isolation assumption | – | SQLite serializes writers (RESERVED lock at `BEGIN IMMEDIATE`); busy timeout 5 s | **READ COMMITTED required.** `ON CONFLICT` waits for the concurrent inserter, then the verify `SELECT` must see its committed row (`postgres.py:298-301`). Under REPEATABLE READ the verify would find nothing and raise `RuntimeError` |
| Telemetry | `impetus_jsonl_commit {records, bytes, elapsed_ms}` per batch; `bytes = Σ(len(line)+1)` (`jsonl.py:174-179`) | none | `impetus_postgres_commit {records, entered, elapsed_ms}` (`postgres.py:226-231`) |

- **Joined-transaction obligations** (`postgres.py:14-30`):
  - Rows are invisible until the caller commits.
  - Memory mirrors the transaction's view.
  - On rollback, or after a refused append (the transaction then still holds the batch's earlier
    inserts: roll back, never commit around it), the caller must discard the store **and** every
    Instance/Engine built over it, then `resume` from a fresh load. A test proves that a rolled-back
    occurrence id is re-minted.
- **Racing writers.**
  - Two writers from the same base both target `inst:N`. The second blocks on the speculative insert
    and then verifies through the event-identity branch.
  - Identical payloads: both succeed with one row.
  - Different payloads: exactly one `ValueError`.
  - The divergent-position case (B loaded after A committed more rows) goes through the
    terminal-index branch.
- **Retries/backoff:** none, apart from the SQLite WAL-bootstrap retry (10 ms sleep, 5 s deadline)
  and the SQLite busy timeout.
- **Threading:**
  - The stores are not thread-safe. The Engine serializes access with an `RLock` monitor
    (`engine/__init__.py:142, 547-569`).
  - One `SqliteHistoryStore` per connection.
  - Concurrent first initialization of two instances in one DB file must succeed, under
    `BEGIN IMMEDIATE` plus the WAL retry (`test_concurrent_first_initialization_for_distinct_instances`).
- **Crash recovery.** Reload equals `records`. The Instance rebuilds its indexes (occurrence counter,
  accepted identities, terminal activity index, in-flight work, projection-pending work) purely from
  records (`test_history_backends.py:186-278`).

#### 4. External dependencies

| Python | Use | Haskell suggestion |
| --- | --- | --- |
| `json` (stdlib) | codec spelling, value equality | **`petrus-json`** (`defaultDumps` variants above, `surrogateRefusingLoads`, `Eq` = `pythonEq`). No aeson on these paths. |
| `sqlite3` (stdlib) | SQLite store | **`direct-sqlite`** (bundled amalgamation ≥ 3.24 for target-less `ON CONFLICT DO NOTHING`; `changes` gives rowcount; `exec` for PRAGMAs/BEGIN), optionally with `sqlite-simple` for row decoding. Verify the bundled SQLite has WAL and partial indexes (it does). |
| `fcntl.flock`, `os.register_at_fork` | writer fence | Direct FFI `flock(2)` (a 3-line `foreign import ccall "flock"`) plus `unix` `openFd` with mode 0600. The `filelock` package also uses `flock` on POSIX but does not control the file mode. **Do not use GHC's `hLock`** (`GHC.IO.Handle.Lock`): on Linux it uses OFD `fcntl` locks, which do **not** conflict with `flock`, so Python and Haskell writers would both "win". Fork handling is not needed: Haskell does not fork. Keep `ensure()` as a PID check only if a `forkProcess` API is exposed. |
| `hashlib.sha256` | lock names, fence key | `crypton` (`Crypto.Hash`) or `cryptohash-sha256`; `base16-bytestring` for hex |
| `pathlib.Path.resolve`, `expanduser` | lock path | `directory`: `canonicalizePath` (resolves symlinks; tolerates a non-existent tail like Python's non-strict resolve) and `getHomeDirectory` for `~`. Cross-check against Python on macOS `/tmp` in an interop test. |
| `psycopg` 3 (`psycopg[binary]>=3.2,<4`) | Postgres store, advisory fence | **`postgresql-simple`** (libpq based: `execute` returns affected rows; `withTransaction`; raw-text `FromField`) or plain **`postgresql-libpq`**. Avoid `hasql-transaction`: it auto-retries, which conflicts with poison semantics. Python's "autocommit vs caller transaction" is connection state. In Haskell, make the mode explicit (`data TxMode = OwnTransaction \| JoinCaller`) or read `PQtransactionStatus` (`TransIdle` vs `TransInTrans`). psycopg's implicit `BEGIN` on first statement of an `autocommit=False` connection must be an explicit `BEGIN` in the Haskell Engine. |
| `petrus.telemetry` | events | `petrus-telemetry` (section 10) |

#### 5. Upstream tests

There is no `conftest.py` under `tests/`. All Postgres fixtures live in the **repo-root
`conftest.py`**:

- `postgres_dsn` (session scope) runs `docker run --rm --detach --publish 127.0.0.1::5432 --tmpfs
  /var/lib/postgresql/data` on image
  `postgres:17.5-alpine@sha256:6567bca8d7bc8c82c5922425a0baee57be8402df92bae5eacad5f01ae9544daa`.
  Containers carry the label `petrus-cv3-test` (per xdist worker), and stale containers are removed.
  It waits for `pg_isready` and a host connect (60 s). DSN: `postgres://postgres:postgres@127.0.0.1:<port>/postgres`.
  It **fails rather than skips** without docker.
- `pg_connection` opens a fresh `autocommit=True` connection and runs `ensure_schema`.
- `absurd_dsn` runs `ensure_schema` and `ensure_absurd_schema`.
- There is a `--forbid-skips` option.

pytest config (`pyproject.toml`): `addopts = "--randomly-seed=1729"` (pytest-randomly), `timeout = 180`.

| File | Test fns | Cases | Needs | Covers |
| --- | --- | --- | --- | --- |
| `tests/petrus/impetus/history_store/test_history_backends.py` | 14 | 42 (`reopen` fixture param `jsonl`/`sqlite`/`postgres`) | docker for the 14 postgres cases only (fixture resolves `pg_connection` lazily) | **The shared backend contract.** Round trip of every record category; append/extend plus reload continuation; durable-before-memory; unencodable or NaN data enters nothing; mid-batch encode failure writes nothing; Instance over a recorded store refused; kill/resume identical (marking, watermark, status); occurrence counter, accepted-identity index and terminal-activity index rebuilt; kill windows after the begin batch and after the frozen result. The Haskell port should run one shared contract suite parametrized over every backend in the same way. |
| `…/test_persistence.py` | 33 | 36 (one parametrize ×4 on policy shapes) | none | 15 codec tests (`TestRecordCodec`; they belong to the kernel codec port but live here), plus `every_record_category()` (one of each of the 22 `Record` union members; imported by the other suites). `DurableAppend` (2). JSONL (10): **byte-stable fixtures** (2), immediate durability, continue file, missing file, schema-1/schema-2 lines refused naming the line, torn tail, unencodable leaves no file. Instance over JSONL (4). Raising-append-moves-nothing via a `RefusingHistory` double (2). |
| `…/test_postgres_history.py` | 21 | 21 | docker | ensure_schema idempotency; unprovisioned DB error; instance validation; co-resident instances; stored row (`event_id`, `record_type`, `occurrence`, payload == `encode_record`); schema-2 refused; batch atomicity; verify-on-conflict (identical twin acknowledged, different fails naming `inst:0`, terminal index acknowledged with no position advance, continuation after acknowledgement keeps ids dense, two-connection divergent positions both ways, activity terminal index); **real 2-thread races** (barrier) for identical and different terminals; caller-transaction join (invisible until commit, rollback, reload inside the transaction, rollback discards the derived Instance); undecodable row names its event. |
| `…/test_sqlite_history.py` | 11 | 14 (`version` ×2, `corruption` ×3) | none | idempotent init that preserves unrelated tables; refuses unsupported version **without mutating bytes**; unversioned shape; weakened index DDL; canonical payload; atomic failed batch; exact retry acknowledged, stale different refused (`r"one:1.*FiringBegun.*TokensProduced"`); terminal and instance isolation; corrupt rows (gap, payload, metadata); empty or non-str instance; 2-thread concurrent first init. |

Stores are also exercised by `tests/petrus/engine/test_{sqlite,postgres}_engine.py` (fences),
`tests/dst/*` and `tests/integration/test_activity_seam.py`. Those belong to the Engine and DST
sections (6 and 10).

#### 6. Performance

Hot paths:

- Encode per batch (codec plus `json.dumps`).
- One `INSERT` round trip per record for Postgres and SQLite. Python never multi-row batches.
- Full decode at load.
- `records` copies the whole list on every access (`memory.py:38-40`) and the Engine `deepcopy`s it.
  This is O(n) per read, quadratic over a drive.

Proposed benchmark (same machine, same records, identical options):

1. **Append throughput**: 10k records generated from `every_record_category()` cycling with
   increasing occurrences. Batch sizes 1 and 8, matching a typical begin batch. Run each backend
   (JSONL; SQLite in WAL with `synchronous=FULL`; Postgres 17.5 in the same docker image, autocommit
   and joined modes). Measure records/s and p50/p99 per batch.
2. **Load**: open over 1k, 10k and 100k records and measure time to `records`.
3. **Conflict path**: append identical terminals to measure verify cost.

Keep it equivalent:

- Same pragmas.
- No fsync for JSONL on both sides.
- One connection per writer.
- Python measured with `time.perf_counter` in-process. Haskell measured with `tasty-bench`/`criterion`
  over the same files.
- Verify outputs are byte-identical (JSONL) or row-identical (SQLite/Postgres) after each run.

Expected Haskell wins:

- Encode/decode speed.
- O(1) `records` (`Seq` or `Data.Vector` snapshot).
- Optionally pipelining the Postgres batch (see §7).

#### 7. Better-the-Haskell-way suggestions

**Design suggestions:**

- **Make the batch the primitive.** Expose `extend :: NonEmpty Record -> m ()` with
  `append = extend . pure`. An empty `extend([])` in Python is not a no-op: SQLite and Postgres run an
  empty `BEGIN`/`COMMIT`, and JSONL `mkdir`s and **creates an empty file**. Nothing relies on this, so
  a no-op is fine. Return an internal
  `[Entered | AcknowledgedHere | AcknowledgedElsewhere]` so that "an acknowledgement is not an
  append" is typed rather than a `continue`.
- **Pure encode before IO.** Use `encodeBatch :: [Record] -> Either EncodeError [ByteString]`. Run
  `either throw` before opening any file, transaction or handle. This makes the "nothing reaches the
  sink" property structural.
- **Store representation.** Suggested shape:
  `data HistoryStore = HistoryStore { records :: IO (Seq Record), extend :: NonEmpty Record -> IO (), size :: IO Int }`
  as a record of functions (the kernel decides; a class is also fine). Internally use an
  `IORef (Seq Record)`, or a `TVar` if observation reads need STM.
- **Scoped resources.** `withSqliteHistoryStore`, `withWriterFence` and `withAuthorityFence` as
  `bracket`-style functions, so fence-before-load ordering and release-on-exception (which
  `engine/sqlite.py` and `engine/postgres.py` do by hand) become structural.
- **Explicit transaction mode** for Postgres (see §4), plus `newtype JoinedTx` evidence that the
  caller holds `BEGIN`.
- **Optional Postgres batch fast path that keeps semantics.** Inside `SAVEPOINT`, run a multi-row
  `INSERT … VALUES (…),(…) ON CONFLICT DO NOTHING RETURNING event_id`. If every row returns, release
  the savepoint. Otherwise `ROLLBACK TO SAVEPOINT` and run the per-row verify loop. This is needed
  because acknowledged-elsewhere rows shift later event ids, so the fast path is valid only when no
  row conflicts. Benchmark it before adopting. libpq pipeline mode is the alternative.
- **Optional fsync flag** for JSONL. The default must stay "no fsync" to match the Python posture and
  performance. Adding fsync does not affect interop.
- **Typed errors.** Use `HistoryStoreError` constructors (`EncodeRefused`, `DecodeFailed {location}`,
  `ConflictingFact`, `TerminalConflict`, `UnexplainedConflict`, `SchemaRefused`) while keeping the
  message texts that tests match.

**Quirks to preserve for interop:**

- The three different `json.dumps` spellings (JSONL `", "`/`": "` with ASCII escaping; SQLite compact
  with ASCII escaping).
- The exact SQLite DDL text, which Python validates.
- The `LIKE 'impetus_history_%'` scan.
- Python value equality (`1 == 1.0 == true`) in verify.
- The final JSONL line without a newline is accepted.
- Load is permissive about NaN, while encode is strict.
- No Postgres metadata or version table: `ensure_schema` must stay purely `IF NOT EXISTS`.
- Positions are derived from in-memory length.
- `flock`, not `fcntl` locks.
- The lock file name derivation.
- The signed big-endian advisory key.

#### 8. Packaging

- `HistoryStore` and `InMemoryHistoryStore` go in **`petrus-impetus`** (kernel).
- **`petrus-history-store`** (proposed) holds the JSONL and SQLite backends plus the SQLite writer
  fence.
  - Depends on `petrus-impetus` (Record, codec), `petrus-json`, `direct-sqlite`, `unix`,
    `directory`, `crypton`/`cryptohash-sha256`, `bytestring`, `text`.
  - From the kernel it needs only `Record`, `encodeRecord`, `decodeRecord` (with exact error
    messages), and the record class name of a `Record` (`recordTypeName`) and its `occurrence`
    (`Maybe Integer`, read from the encoded object).
- **`petrus-postgres`** (proposed) holds the Postgres store, `ensureSchema` and the authority fence.
  It mirrors the optional `postgres` extra, so neutral packages never link libpq (the upstream tests
  assert "neutral import does not attempt psycopg"). Fabric, processes, engine-postgres and Absurd
  dispatch depend on it. An alternative is cabal public sub-libraries `petrus-history-store:sqlite`
  and `:postgres`.
- **Parallelism.** These can be built as soon as the codec exists, in parallel with Instance and
  Engine work. The JSONL store is the simplest first target and is needed early by
  `agenticus/runtime/agent_net_runner.py` and the tests. The SQLite fence and Postgres fence are
  consumed by the engine package.

### Fabric (`petrus/fabric`)

Upstream files:

- `src/petrus/fabric/__init__.py` (12 lines): exports `MAX_INLINE_PAYLOAD_BYTES, Endpoint, Envelope,
  Receipt, ReplyRoute, Submission`.
- `model.py` (241 lines): transport-neutral values.
- `ingress.py` (46 lines): the kernel ingress bridge.
- `postgres.py` (397 lines): the trusted-workspace PostgreSQL implementation.

Glossary (`docs/project/glossary/fabric.md`): "the inter-Instance protocol plane for
transport-neutral envelopes and reply routes, discovery, exposed-source grants, durable inboxes and
receipts, retry, and correlation. Fabric state is routing and protocol truth, not a global semantic
history." Decision: `docs/project/decisions/records/2026-07-20T1114Z-process-fabric-is-an-inter-authority-protocol-plane.md`.

- Inbound path: `Fabric row → FabricInbox → Engine.deliver → recipient history`.
- Outbound path: `ActivityRequested("fabric.send") → adapter → Fabric row`.
- Fabric must not import Engine, hosts or applications.
- There is no upstream spec file. This repo's README plans language-neutral Fabric/process specs
  under `spec/`, and the facts below are their source.

#### 1. Responsibility & public API

**Values** (`model.py`). All are frozen dataclasses; validation runs in `__post_init__`.

- `ReplyRoute(instance_id: str, source: str)`
  - `to_data()` returns `{"instance_id", "source"}`.
  - `from_data(obj)` requires an exact key set (`model.py:94-116`).
- `Envelope(delivery_id, sender, recipient, source, correlation: str, payload: Mapping[str, object], reply_route: ReplyRoute | None = None)` (`model.py:119-186`).
  - Text fields are validated with `_text`.
  - `payload` must be a `dict`. It is deep-copied through
    `json.loads(json.dumps(v, allow_nan=False, ensure_ascii=False, separators=(",", ":")))` after
    `_json_copy` validation (`model.py:50-71`), then frozen (`MappingProxyType` / tuples).
  - Size limit: `len(canonical(payload)) <= MAX_INLINE_PAYLOAD_BYTES = 65536`, else
    `ValueError "… use the artifact protocol and send a verified artifact reference"`.
  - Properties: `digest`, `ingress_identity`.
  - Methods: `to_data()`, `from_data(obj)`.
- `Endpoint(recipient: str, source: str, capabilities: Mapping)` (`model.py:189-218`).
- `Submission(sender, delivery_id, state: str, duplicate: bool, occurrence: int | None = None, accepted_at: datetime | None = None)` (`model.py:221-228`).
- `Receipt(sender, delivery_id, recipient, source, digest, state, occurrence: int | None, accepted_at: datetime | None, payload_retained: bool)` (`model.py:231-241`).
- Private helpers reused by `processes`: `_text`, `_exact_object`, `_json_object`, `_json_copy`,
  `_freeze_json`, `_thaw_json`, `_canonical`.

Validation helpers:

- `_text(v, name)` (`model.py:22-25`): `v` must be a non-empty `str` whose UTF-8 encoding is at most
  1024 bytes. Otherwise `ValueError "<name> must be a non-empty string of at most 1024 UTF-8 bytes"`.
- `_json_copy` (`model.py:50-71`):
  - Accepts only `None`/`str`/`bool`/`int`, finite `float`, `list`, and `dict` with `str` keys.
  - Errors carry the path: `TypeError "payload.items[0] contains object, which is not a JSON value"`
    and `ValueError "payload.bad must be strict JSON (NaN and Infinity are forbidden)"`.
  - Tuples are refused (they are not `list`).

**Ingress bridge** (`ingress.py:15-46`):

```python
FABRIC_ENVELOPE = "FabricEnvelope"
class DeliveryDoor(Protocol):
    def deliver(self, source: str, tokens: tuple[Token, ...], *, identity: str) -> FiringOutcome | PriorAcknowledgement: ...
class InboxClient(Protocol):
    def pending(self, limit: int = 100) -> tuple[Envelope, ...]: ...
    def acknowledge(self, sender: str, delivery_id: str, occurrence: int) -> Receipt: ...
@dataclass(frozen=True)
class FabricInbox:
    client: InboxClient
    delivery_door: DeliveryDoor
    def drain(self, limit: int = 100) -> tuple[Receipt, ...]
```

`drain` processes `client.pending(limit)` in order. For each envelope:

1. Call `door.deliver(env.source, (Token("FabricEnvelope", env.to_data()),), identity=env.ingress_identity)`.
2. The result must be a `FiringOutcome` or `PriorAcknowledgement`, else `TypeError`. A
   `ScopedDeliveryAcknowledgement` is therefore refused, but it cannot occur because no `scope` is
   passed.
3. Call `client.acknowledge(env.sender, env.delivery_id, result.occurrence)`.

The first exception aborts the drain; receipts already acknowledged stay acknowledged.

Kernel APIs used:

- `petrus.impetus.petrinet.Token(color, data)`.
- `petrus.impetus.instance.FiringOutcome` (`.occurrence`) and `PriorAcknowledgement(identity, occurrence)`.
- The Engine plugs in **only through its public `Engine.deliver(source, tokens, *, identity, scope=None)`**
  (`engine/__init__.py:388-405`): the Engine itself is the `DeliveryDoor`. Fabric adds no Engine hooks.

**PostgreSQL implementation** (`postgres.py`):

- `issue_credential() -> str`, which is `secrets.token_urlsafe(32)` (43 URL-safe base64 chars, no
  padding).
- `ensure_fabric_schema(connection)`.
- `register_process(connection, instance, credential)`, the trusted-operator bootstrap. It is
  **unauthenticated**.
- `class PostgresFabric(connection, instance, credential)` with:
  - `authenticate()`
  - `expose_source(source)`
  - `offer_service(source, service, capabilities: dict)`
  - `grant(sender, source)` and `revoke(sender, source)`
  - `discover(service, capabilities: dict | None = None) -> tuple[Endpoint, ...]`
  - `submit(envelope) -> Submission` (alias `send`)
  - `pending(limit=100) -> tuple[Envelope, ...]`
  - `acknowledge(sender, delivery_id, occurrence: int) -> Receipt`
  - `receipt(delivery_id) -> Receipt | None`
  - `prune_accepted(before: datetime) -> int`

**How Fabric plugs into a host.** Compare `scripts/cv5-fabric-demo.py:143-252`.

- **Receiving.** The host builds `FabricInbox(PostgresFabric(fabric_conn, authority_id, cred), engine)`
  and loops: `inbox.drain()`, then `engine.advance()` until not ready, then sleep 50 ms. This is
  **polling**. `submit` emits `pg_notify('impetus_fabric_delivery', recipient)`, but **no upstream
  code LISTENs**; a Haskell host may use it as a wake hint.
- **Recipient net.** The net has a **source transition** whose output arc filters on color
  `FabricEnvelope`. Sources must be armed. Reply sources are opened per correlation with
  `HandlerResult(opens=(DeliveryRegistration(REPLY_SOURCE, correlation),))` and closed on receipt.
- **Sending.** Sending is an *application* Activity (named `"fabric.send"` in the demos; not in
  `src`). An `ActivityHandler.prepare` returns
  `ActivityInvocation("fabric.send", input=envelope.to_data(), correlation=envelope.correlation, idempotency=envelope.ingress_identity)`.
  The Activity calls `Envelope.from_data(invocation.input)`, checks
  `idempotency == envelope.ingress_identity`, calls `PostgresFabric.submit`, and returns
  `{"state","duplicate","delivery_id","correlation"}`.

#### 2. Wire formats, durable schemas, protocols

**Envelope v1 JSON** (`to_data`, `model.py:166-176`). Key order:

```json
{"version": 1, "delivery_id": "...", "sender": "...", "recipient": "...", "source": "...",
 "correlation": "...", "payload": {...}, "reply_route": null | {"instance_id": "...", "source": "..."}}
```

`from_data` rules:

- The key set must be exactly these 8. Otherwise:
  `ValueError "envelope requires exact version-1 fields (missing=[...], unknown=[...])"`.
- `version` must satisfy `type(...) is int and == 1`. `True` and `1.0` are refused.
- `payload` must be an object (`TypeError` otherwise).
- `reply_route` must be null or an exact `{instance_id, source}` object.
- A non-str key is refused with "unknown".

Identities and hashes:

- **Canonical bytes**: `json.dumps(v, allow_nan=False, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()`.
  This is exactly petrus-json `canonicalText`, then UTF-8.
- **`digest`**: `sha256(canonical(to_data())).hexdigest()`, lowercase hex.
- **`ingress_identity`**: `f"fabric:{len(sender)}:{sender}:{delivery_id}"`. Here `len` counts
  **code points**, so use Haskell `Text.length`, not the byte length. It becomes the recipient's
  canonical delivery identity (`ExternalEventDelivered.identity`), so **it is stored in History**.
- **Token in recipient History**: `Token(color="FabricEnvelope", data=envelope.to_data())`, where
  `envelope` was parsed from the jsonb row.
  - The payload's key order is therefore jsonb order, as the server returns it. This affects JSONL
    bytes of the recipient history but not semantics.
  - Preserve server order by parsing jsonb text with petrus-json.

Golden vectors (computed from upstream code):

- The envelope from `tests/petrus/fabric/test_fabric.py:82-91` with
  `delivery_id="delivery-1"`, `sender="sender-a"`, `recipient="recipient"`,
  `source="commands/start"`, `correlation="conversation-1"`, `payload={"command":"go"}` and
  `reply_route=("sender-a","replies/finish")`:
  - canonical:
    `{"correlation":"conversation-1","delivery_id":"delivery-1","payload":{"command":"go"},"recipient":"recipient","reply_route":{"instance_id":"sender-a","source":"replies/finish"},"sender":"sender-a","source":"commands/start","version":1}`
  - digest: `1d283f31fa462422607bba9290e17f4573b3f7573b6daf9b2077548cae9c67c5`
  - ingress identity: `fabric:8:sender-a:delivery-1`

**Credentials** (`postgres.py:36-47`):

- `_credential(c)` requires a `str` with `len(c.encode()) >= 32` and `len(set(c)) >= 16` distinct
  characters. Otherwise `ValueError "credential must be a high-entropy opaque token of at least 32 UTF-8 bytes"`.
- Only `sha256(c.encode()).hexdigest()` is stored.
- Comparisons use `hmac.compare_digest` (constant time).
- Every client operation first runs `_auth()`:
  `SELECT credential_digest FROM impetus_fabric.processes WHERE instance_id = %s`.
  A missing row or a mismatch emits `fabric_denied` and raises
  `PermissionError "fabric authentication failed for '<id>'"`.

**Schema** (`postgres.py:50-79`). This is the verbatim DDL. `_SCHEMA_VERSION = 1`.

```sql
CREATE SCHEMA IF NOT EXISTS impetus_fabric
CREATE TABLE IF NOT EXISTS impetus_fabric.schema_metadata (
        component text PRIMARY KEY, version integer NOT NULL)
CREATE TABLE IF NOT EXISTS impetus_fabric.processes (
        instance_id text PRIMARY KEY, credential_digest text NOT NULL,
        registered_at timestamptz NOT NULL DEFAULT clock_timestamp())
CREATE TABLE IF NOT EXISTS impetus_fabric.exposed_sources (
        instance_id text NOT NULL REFERENCES impetus_fabric.processes(instance_id), source text NOT NULL,
        exposed_at timestamptz NOT NULL DEFAULT clock_timestamp(), PRIMARY KEY (instance_id, source))
CREATE TABLE IF NOT EXISTS impetus_fabric.service_offers (
        instance_id text NOT NULL, source text NOT NULL, service text NOT NULL, capabilities jsonb NOT NULL,
        offered_at timestamptz NOT NULL DEFAULT clock_timestamp(), PRIMARY KEY (instance_id, source, service),
        FOREIGN KEY (instance_id, source) REFERENCES impetus_fabric.exposed_sources(instance_id, source))
CREATE TABLE IF NOT EXISTS impetus_fabric.delivery_grants (
        sender text NOT NULL REFERENCES impetus_fabric.processes(instance_id), recipient text NOT NULL,
        source text NOT NULL, granted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
        PRIMARY KEY (sender, recipient, source),
        FOREIGN KEY (recipient, source) REFERENCES impetus_fabric.exposed_sources(instance_id, source))
CREATE TABLE IF NOT EXISTS impetus_fabric.deliveries (
        sender text NOT NULL REFERENCES impetus_fabric.processes(instance_id), delivery_id text NOT NULL,
        recipient text NOT NULL REFERENCES impetus_fabric.processes(instance_id), source text NOT NULL,
        correlation text NOT NULL, envelope jsonb, digest text NOT NULL, submitted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
        accepted_occurrence bigint, accepted_at timestamptz,
        PRIMARY KEY (sender, delivery_id),
        CHECK ((accepted_occurrence IS NULL) = (accepted_at IS NULL)),
        CHECK (envelope IS NOT NULL OR accepted_at IS NOT NULL))
CREATE INDEX IF NOT EXISTS fabric_pending_by_recipient ON impetus_fabric.deliveries (recipient, submitted_at) WHERE accepted_at IS NULL
CREATE INDEX IF NOT EXISTS fabric_offers_by_service ON impetus_fabric.service_offers (service, instance_id, source)
```

**`ensure_fabric_schema`** (`postgres.py:82-114`) never commits.

1. Run `SELECT 1 FROM pg_namespace WHERE nspname = 'impetus_fabric'`.
2. If the schema exists **and** `SELECT to_regclass('impetus_fabric.schema_metadata')` is NULL, run
   `SELECT table_name FROM information_schema.tables WHERE table_schema = 'impetus_fabric' AND table_name = ANY(%s) LIMIT 1`
   with the array `['processes','exposed_sources','service_offers','delivery_grants','deliveries']`.
   A hit raises `RuntimeError "the impetus_fabric schema contains unversioned table '<t>': refusing to bless an unknown shape — migrate or recreate the fabric schema deliberately"`.
3. Run all the DDL.
4. Run `INSERT INTO impetus_fabric.schema_metadata (component, version) VALUES ('fabric', %s) ON CONFLICT (component) DO NOTHING`
   with `1`.
5. Run `SELECT version FROM impetus_fabric.schema_metadata WHERE component = 'fabric'`. Anything
   other than 1 raises `RuntimeError "the database speaks impetus_fabric schema version 999, but this runtime requires version 1: migrate deliberately rather than upgrading implicitly at boot"`.

**Statements, verbatim** (all `%s` placeholders; `Jsonb(x)` means psycopg sends `json.dumps(x)` as jsonb):

| Operation | SQL |
| --- | --- |
| register | `INSERT INTO impetus_fabric.processes (instance_id, credential_digest) VALUES (%s, %s) ON CONFLICT DO NOTHING`. If rowcount is 0: `SELECT credential_digest FROM impetus_fabric.processes WHERE instance_id = %s`. A different digest raises `ValueError "process '<id>' is already registered with a different credential"`. |
| expose_source | `INSERT INTO impetus_fabric.exposed_sources (instance_id, source) VALUES (%s, %s) ON CONFLICT DO NOTHING` |
| offer_service | `INSERT INTO impetus_fabric.service_offers (instance_id, source, service, capabilities) VALUES (%s, %s, %s, %s) ON CONFLICT (instance_id, source, service) DO UPDATE SET capabilities = EXCLUDED.capabilities, offered_at = clock_timestamp()` (capabilities is `Jsonb(snapshot)`) |
| grant | `INSERT INTO impetus_fabric.delivery_grants (sender, recipient, source) VALUES (%s, %s, %s) ON CONFLICT DO NOTHING` (recipient is the client's own instance) |
| revoke | `DELETE FROM impetus_fabric.delivery_grants WHERE sender = %s AND recipient = %s AND source = %s` |
| discover | `SELECT o.instance_id, o.source, o.capabilities FROM impetus_fabric.service_offers o JOIN impetus_fabric.delivery_grants g ON (g.recipient, g.source) = (o.instance_id, o.source) WHERE g.sender = %s AND o.service = %s AND o.capabilities @> %s ORDER BY o.instance_id, o.source` (jsonb containment; `{}` matches everything) |
| submit: prior | `SELECT digest, accepted_occurrence, accepted_at FROM impetus_fabric.deliveries WHERE sender = %s AND delivery_id = %s FOR UPDATE` |
| submit: allowed | `SELECT 1 FROM impetus_fabric.exposed_sources e JOIN impetus_fabric.delivery_grants g ON (g.recipient, g.source) = (e.instance_id, e.source) WHERE e.instance_id = %s AND e.source = %s AND g.sender = %s` |
| submit: insert | `INSERT INTO impetus_fabric.deliveries (sender, delivery_id, recipient, source, correlation, envelope, digest) VALUES (%s, %s, %s, %s, %s, %s, %s) ON CONFLICT DO NOTHING` (envelope is `Jsonb(envelope.to_data())`). If rowcount is 0: re-run the prior `SELECT … FOR UPDATE` and judge. |
| submit: notify | `SELECT pg_notify('impetus_fabric_delivery', %s)`. The payload is the recipient instance id. It runs inside the transaction, so it is delivered on commit. |
| pending | `SELECT envelope FROM impetus_fabric.deliveries WHERE recipient = %s AND accepted_at IS NULL ORDER BY submitted_at, sender, delivery_id LIMIT %s`. Each row goes through `Envelope.from_data`. `limit` must satisfy `type(limit) is int` and `>= 1`. |
| acknowledge | `SELECT recipient, source, correlation, digest, accepted_occurrence, accepted_at, envelope IS NOT NULL FROM impetus_fabric.deliveries WHERE sender = %s AND delivery_id = %s AND recipient = %s FOR UPDATE`, then if not yet accepted: `UPDATE impetus_fabric.deliveries SET accepted_occurrence = %s, accepted_at = clock_timestamp() WHERE sender = %s AND delivery_id = %s RETURNING accepted_at` |
| receipt | `SELECT recipient, source, digest, accepted_occurrence, accepted_at, envelope IS NOT NULL FROM impetus_fabric.deliveries WHERE sender = %s AND delivery_id = %s` |
| prune_accepted | `UPDATE impetus_fabric.deliveries SET envelope = NULL WHERE recipient = %s AND accepted_at < %s AND envelope IS NOT NULL`. Returns rowcount. `before` must be timezone-aware, else `ValueError "pruning cutoff must be a timezone-aware datetime"`. |

**Submit and acknowledge semantics:**

- `submit` requires `envelope.sender == self.instance`, else
  `PermissionError "envelope sender must match the authenticated fabric client"`.
- An **exact retransmission is judged before the current grant**. If a prior row exists, digests are
  compared in constant time:
  - Equal returns `Submission(sender, id, "accepted" if accepted_at else "pending", True, accepted_occurrence, accepted_at)`.
    This holds even after a revoke or a prune.
  - Different raises `ValueError "fabric delivery identity conflict for ('<s>', '<id>'): content or address changed"`.
- With no prior row and no grant: `PermissionError "recipient source is not exposed and granted to this sender"`.
- A fresh insert returns `Submission(sender, id, "pending", False)` with `occurrence = None` and
  `accepted_at = None`.
- `acknowledge` requires `type(occurrence) is int and >= 1`, else `ValueError "occurrence must be a positive integer"`.
  - A missing row raises `LookupError`.
  - Already accepted with a different occurrence raises `ValueError "delivery was already accepted by occurrence N, not M"`.
  - Already accepted with the same occurrence is idempotent.
  - Returns `Receipt(sender, delivery_id, recipient, source, digest, "accepted", occurrence, accepted_at, payload_retained = envelope IS NOT NULL)`.
- `receipt` is from the sender's side. `state` is `"accepted"` if `accepted_at` is set, else `"pending"`.

**Telemetry events** (logger `impetus`, so the names arrive prefixed `impetus_`):

| Event | Fields |
| --- | --- |
| `fabric_registered` | `instance` |
| `fabric_conflict` | `operation` = `register`, `submit` or `acknowledge`, plus addressing fields |
| `fabric_denied` | `operation` = `authenticate` or `submit`, … |
| `fabric_exposed` | – |
| `fabric_offered` | – |
| `fabric_granted` | – |
| `fabric_redelivered` | `state` |
| `fabric_submitted` | – |
| `fabric_accepted` | `occurrence` |
| `fabric_pruned` | `deliveries` |

`revoke` emits nothing.

#### 3. Concurrency & durability semantics

- **Transactions.** `_transaction()` returns `connection.transaction()` (`BEGIN`/`COMMIT`, rollback
  on exception) **only when the connection is autocommit**. Otherwise it is `nullcontext`: the
  operation joins the caller's transaction and is never committed by Fabric (`postgres.py:156-157`;
  test `test_fabric_operations_join_a_caller_transaction_without_committing`).
  - Only `submit` and `acknowledge` are multi-statement.
  - Every other method is a single statement plus `_auth`, so in autocommit mode each statement
    commits on its own.
- **Row locks.** `SELECT … FOR UPDATE` on `(sender, delivery_id)` serializes submit/ack races.
- **Concurrent submits.** If a concurrent `submit` wins between the read and the insert, the insert's
  `ON CONFLICT DO NOTHING` waits for it. The re-read `FOR UPDATE` then verifies by digest. This
  relies on READ COMMITTED.
- **Exactly-once acceptance across a crash.** If the host crashes after `Engine.deliver` committed but
  before `acknowledge`:
  1. The next `drain` re-delivers the same `ingress_identity`.
  2. The Engine answers `PriorAcknowledgement(identity, occurrence)` without appending anything.
  3. The acknowledgement then lands with the original occurrence
     (test `test_inbox_delivery_acceptance_and_prior_acknowledgement_crash_recovery`).
- **Pruning.** It removes payload bytes but keeps `digest`, so retransmission dedup and conflict
  detection survive.
- **Delivery ordering.** Deliveries are ordered per recipient by `submitted_at`, which is
  `clock_timestamp()` at insert, not at commit. Ties are broken by `sender, delivery_id`.
  Visibility is at commit, so a later-committed but earlier-stamped row can appear after rows that
  were already drained. Consumers must not assume a gapless order.
- **No leases or heartbeats.** Retry is the sender re-running `submit` with the same `delivery_id`.
  Sender-side retry comes from the `fabric.send` Activity being at-least-once with
  `idempotency = ingress_identity`.
- **Security posture** (`postgres.py:1-6`): "API-level credentials prevent accidental cross-instance
  use; they do not protect against a hostile SQL principal."

#### 4. External dependencies

| Python | Haskell |
| --- | --- |
| `psycopg` (+ `Jsonb`) | `postgresql-simple` or `postgresql-libpq` (shared with the Postgres store). Send jsonb as text `$n::jsonb`, or with a jsonb type OID. Read jsonb as raw text and parse with petrus-json. |
| `hashlib.sha256` | `crypton` or `cryptohash-sha256` + `base16-bytestring` |
| `hmac.compare_digest` | `Data.ByteArray.constEq` (`memory`/`ram`, re-exported via crypton) |
| `secrets.token_urlsafe(32)` | `crypton` `getRandomBytes 32` (or `entropy`), then `base64-bytestring` `Data.ByteString.Base64.URL.encodeUnpadded` |
| `json` canonical | `petrus-json` `canonicalText` (`sort_keys`, `ensure_ascii=False`, compact); `allowNan = False` |
| `datetime` (tz-aware) | `time` `UTCTime`. Being tz-aware is then enforced by the type. |
| `types.MappingProxyType` freezing | Immutable `Json` values (no runtime freezing needed) |

#### 5. Upstream tests

`tests/petrus/fabric/test_fabric.py` has **12 test functions, all requiring docker**. The
`autouse` fixture `fabric_schema(pg_connection)` drops and recreates `impetus_fabric` around every
test, so even the pure tests need Postgres.

| Group | Tests |
| --- | --- |
| Neutral import | `test_neutral_fabric_import_does_not_attempt_psycopg` (subprocess, import guard) |
| Acceptance demo | `test_two_authority_process_fabric_acceptance_demo`. Runs `scripts/cv5-fabric-demo.py --dsn <dsn>` as a subprocess with `UV_FROZEN=1`, timeout 90 s. It spawns parent and child role subprocesses (env `IMPETUS_DEMO_DSN/ROLE/PARENT/CHILD/CREDENTIAL`) and checks stdout lines: `overall: PASS`, `offline pending count: 1`, `parent: awaiting -> completed`, `replay: parent appends=0 invocations=0; child appends=0 invocations=0`, `in-flight crash resume: occurrence=`, `dispatches=1 completed=true`, `local/split semantic-shape equality: true`. The Haskell port needs an equivalent demo; it is also a natural **cross-language interop test** (Python parent with Haskell child, and the reverse). |
| Envelope values | exact/versioned/detached/strict/bounded; digest length 64; `fabric:8:sender-a:delivery-1` |
| Registration | digest only, idempotent, weak credential refused, auth failure |
| Schema | unversioned table refused; version 999 refused |
| Caller transaction | join without commit; rollback |
| Discovery and send | deny by default; capability containment filter |
| Retransmission | precedes grant (after revoke); changed content conflicts; new id without grant is refused |
| Distinct senders | same delivery id gives distinct ingress identities |
| Inbox | crash recovery via `PriorAcknowledgement` (with a `FakeDoor`) |
| Acknowledgement | occurrence conflicts; `0` refused |
| Pruning | keeps receipt, dedup and conflict; refuses naive datetime |

#### 6. Performance

- Hot paths:
  - `_auth` adds one extra round trip to **every** call.
  - `submit` takes 4–5 round trips (auth, prior, allowed, insert, notify).
  - `pending` plus `Envelope.from_data` validation and digest hashing.
  - `drain` makes one Engine delivery and one acknowledgement per envelope.
- Benchmark: in one Postgres container, 1 sender and 1 recipient with an open route.
  1. Submit N = 10k distinct envelopes with a 1 KiB payload.
  2. Drain them in batches of 100 into a recipient Engine whose source transition just deposits
     tokens.
  3. Measure submits/s, drained/s, and end-to-end latency.
  4. Separately microbenchmark `Envelope` construction plus `digest` with a 64 KiB payload (canonical
     JSON plus sha256).
- Equivalence: same SQL (no batching), same isolation, same autocommit mode. Optionally add a
  Haskell-only variant that pipelines `_auth` with the statement.

#### 7. Better-the-Haskell-way suggestions

**Suggestions:**

- Smart constructors give validated newtypes:
  - `BoundedText` (non-empty, ≤ 1024 UTF-8 bytes).
  - `Credential` (≥ 32 bytes, ≥ 16 distinct chars; no `Show`, to avoid leaking it).
  - `CredentialDigest`.
  - `InlinePayload` (a JSON object ≤ 65536 canonical bytes).
  - `Occurrence` (positive).
- `SubmissionState = Pending | Accepted Occurrence UTCTime`. This makes the
  `(accepted_occurrence IS NULL) = (accepted_at IS NULL)` invariant unrepresentable when violated.
- Run the authenticated client in a `ReaderT FabricClient`, with `withTransactionIfAutocommit`
  expressed through the explicit `TxMode` from the History Store section.
- Ingress: `drain` should return a typed `DeliveryResult` from the door, with `ScopedDeliveryAcknowledgement`
  excluded by type, and should stream with bounded batches.
- The host loop can `LISTEN impetus_fabric_delivery` on a dedicated connection and block with
  `threadWaitRead` on the libpq socket instead of polling every 50 ms. This must stay optional:
  upstream has no listener, and a timeout-based poll must remain because notifications can be lost.

**Quirks to preserve:**

- `ingress_identity` counts code points.
- `version` must be a real integer (`true` refused).
- Exact retransmission succeeds even after revoke or prune.
- `register_process` is unauthenticated.
- `revoke` emits no telemetry.
- Error texts are matched by tests ("identity conflict", "not exposed and granted",
  "authentication failed", "different credential", "high-entropy", "already accepted by occurrence N",
  "positive integer", "timezone-aware", "artifact protocol", "strict JSON",
  "unversioned table.*refusing", "version 999.*migrate deliberately").
- `_json_copy` error paths include `payload.items[0]` and `payload.bad`.

#### 8. Packaging

- **`petrus-fabric`** (proposed), library `Petrus.Fabric.Model`. It is pure and depends only on
  `petrus-json`, `text`, `bytestring`, sha256 and hex. It can be built **now, in parallel with the
  kernel**.
- `Petrus.Fabric.Ingress` depends on `petrus-impetus` (`Token`, `FiringOutcome`,
  `PriorAcknowledgement`) and on an abstract `DeliveryDoor` record, so it needs no engine
  dependency.
- `Petrus.Fabric.Postgres` belongs in a sub-library or a separate `petrus-fabric-postgres` that
  depends on `petrus-postgres`'s connection and transaction-mode utilities. This keeps "the neutral
  import does not load libpq" true.
- The acceptance demo needs the engine-postgres provider, `InlineDispatch` (motus) and handlers. It
  comes last.

### Processes: call, spawn, lifecycle registry (`petrus/processes`)

Upstream files:

- `src/petrus/processes/__init__.py` (30 lines).
- `call.py` (211 lines): call payloads and Envelope builders.
- `model.py` (204 lines): spawn values and identities.
- `spawn.py` (63 lines): the `process.spawn` Activity.
- `postgres.py` (129 lines): the spawn-lineage registry.

Decision: `docs/project/decisions/records/2026-07-21T0030Z-call-and-spawn-are-distinct-process-lifecycle-protocols.md`.
Processes are layered strictly above Fabric. `petrus.processes` must import neither psycopg nor
runtime layers (test).

#### 1. Responsibility & public API

**Call** (`call.py`). All values are frozen and use `_text`/`_json_copy` validation.

- `CallRequest(call_id: str, operation: str, input: Mapping)`
  - `kind = "process.call.request"`.
  - `input` must be a dict.
- `CallResult(call_id: str, result: object)`
  - `kind = "process.call.result"`.
  - `result` is any strict JSON value, including null.
- `CallError(call_id: str, code: str, message: str, details: object = None)`
  - `kind = "process.call.error"`.

Each has `to_data()` and `from_data(obj)`. `from_data` runs `_exact` (`call.py:97-102`):

- The key set must be exact.
- `version` must satisfy `type is int` and `== 1`.
- `kind` must match.
- Otherwise: `ValueError "payload requires exact version-1 <kind> fields"`.

Envelope builders:

- `request_envelope(*, request, sender, recipient, source, reply_route, delivery_id=None) -> Envelope`
  (`call.py:156-177`).
  - `reply_route.instance_id` must equal `sender` ("call reply_route must belong to the sender process").
  - Correlation is `call_id`.
- `result_envelope(*, result, request: Envelope, sender, delivery_id=None)` and
  `error_envelope(*, error, request, sender, delivery_id=None)` (`call.py:180-211`).
  - The request must decode via `request_from_envelope`.
  - `call_id` must match and `sender` must equal `request.recipient`.
  - The reply goes to `route.instance_id` at `route.source` with no reply route.
- `request_from_envelope(envelope) -> CallRequest` (`call.py:123-131`). The payload `call_id` must
  equal the envelope correlation, and the reply route must belong to the envelope sender.
- `reply_from_envelope(envelope, *, request: Envelope) -> CallResult | CallError` (`call.py:134-153`).
  Dispatches on `payload["kind"]`, then checks:
  - correlation and `call_id` against the request;
  - `envelope.sender == request.recipient`;
  - `envelope.recipient == request.sender`;
  - `envelope.source == route.source`;
  - no `reply_route`.

**Spawn values** (`model.py`):

- `child_identity(parent, spawn_id) -> str` (`model.py:29-33`).
- `SpawnSpec(parent, spawn_id, process_kind, source, capabilities: Mapping, config: Mapping, reply_route: ReplyRoute | None = None)` (`model.py:42-98`).
  - `reply_route.instance_id` must equal `parent`.
  - Properties: `child`, `digest`.
  - Methods: `to_data()`, `from_data()`.
- `Provisioning(parent, spawn_id, child, process_kind, endpoint: Endpoint, config, reply_route=None)` (`model.py:101-126`).
  - `child` must equal `child_identity`.
  - `endpoint.recipient` must equal `child`.
- `SpawnClaim(parent, spawn_id, child, prior_claim: bool)` with `.lineage`.
- `SpawnOutcome(parent, spawn_id, child, endpoint, prior_claim)` with `to_data()` and `from_data()`.
- `Lineage(parent, spawn_id, child)`.
- Every type that carries a `child` re-checks `child == child_identity(parent, spawn_id)`.

**Spawn Activity** (`spawn.py`):

```python
SPAWN_ACTIVITY = "process.spawn"
class SpawnRegistry(Protocol):  claim(spec) -> SpawnClaim; child_of(parent, spawn_id) -> Lineage|None;
                                children_of(parent) -> tuple[Lineage, ...]; parent_of(child) -> Lineage|None
class ProcessProvisioner(Protocol):  ensure(provisioning: Provisioning) -> None
@dataclass(frozen=True) class SpawnActivity(registry, provisioner):
    def __call__(self, invocation: ActivityInvocation, *, context) -> dict[str, object]
def spawn_idempotency(parent, spawn_id) -> str   # "process.spawn:" + child_identity(parent, spawn_id)
```

`__call__` (`spawn.py:32-58`) runs these steps:

1. `invocation.activity` must be `"process.spawn"`, else `ValueError "SpawnActivity only implements 'process.spawn'"`.
2. `spec = SpawnSpec.from_data(invocation.input)`.
3. `invocation.idempotency` must equal `spawn_idempotency(...)`, else `ValueError "…idempotency must identify the parent and spawn_id"`.
4. `claim = registry.claim(spec)`. The claim's identity must match the spec ("different identity").
5. `endpoint = Endpoint(child, spec.source, capabilities)`.
6. `provisioner.ensure(Provisioning(...))` must return `None`, else
   `TypeError "process provisioner ensure must return None, never a live host or credential"`.
7. Return `SpawnOutcome(...).to_data()`.

The claim is made **before** ensure. An exact retry re-claims, gets `prior_claim=True`, and
re-ensures.

**Postgres registry** (`postgres.py`):

- `ensure_lifecycle_schema(connection)`.
- `PostgresSpawnRegistry(connection, parent, credential)`.
  - **Requires `connection.autocommit`**, else `ValueError "PostgresSpawnRegistry requires an autocommit connection"`.
  - Every claim is committed before it returns.
  - It authenticates through `PostgresFabric(connection, parent, credential).authenticate()`.
    `PermissionError` is re-raised as `"lifecycle authentication failed for '<parent>'"`.
  - Methods: `claim`, `child_of`, `children_of`, `parent_of`.

Kernel and motus APIs used:

- `petrus.motus.activity.ActivityInvocation(activity, *, input=None, policy=ExecutionPolicy(), correlation=None, idempotency=None)`
  (`motus/activity/__init__.py:354-362`).
- Fabric `Endpoint`, `Envelope`, `ReplyRoute`, and the private helpers.

**How processes plug into the Engine** (`scripts/cv5-lifecycle-demo.py:116-151, 238-320, 531-580`):

- **Parent side.**
  - The parent net has an `ActivityHandler` whose `prepare` returns
    `ActivityInvocation("process.spawn", input=spec.to_data(), correlation=spec.spawn_id, idempotency=spawn_idempotency(parent, spawn_id))`.
  - Its `project` decodes `SpawnOutcome.from_data(result)` into a token.
  - The Dispatch maps `"process.spawn"` to `SpawnActivity(PostgresSpawnRegistry(...), provisioner)`.
- **Provisioner.** It is application-owned (the demo `DemoProvisioner`):
  1. Derive the child credential, e.g. `base64url(HMAC-SHA256(workspace_key, child))`.
  2. Call `register_process(child)`.
  3. Have the child expose the endpoint source, offer the service `process_kind`, and grant it to the
     parent.
  4. Have the parent expose the reply source and grant it to the child.
  5. Credentials never enter protocol data or History (checked by the demo).
- **Calls.** Calls are `fabric.send` Activities carrying `request_envelope(...)`. Replies are
  received by a per-correlation reply source opened with `DeliveryRegistration(REPLY_SOURCE, call_id)`,
  and the handler validates them with `reply_from_envelope`.
- No Engine hooks are added; only public Engine and Dispatch seams are used.

#### 2. Wire formats, durable schemas, protocols

**Payload JSON shapes** (key order as `to_data`):

- `CallRequest`: `{"version": 1, "kind": "process.call.request", "call_id", "operation", "input": {...}}`
- `CallResult`: `{"version": 1, "kind": "process.call.result", "call_id", "result": <json>}`
- `CallError`: `{"version": 1, "kind": "process.call.error", "call_id", "code", "message", "details": <json|null>}`
- `SpawnSpec`: `{"version": 1, "parent", "spawn_id", "process_kind", "source", "capabilities": {...}, "config": {...}, "reply_route": null|{"instance_id","source"}}`
- `SpawnOutcome` (the Activity result, **stored in History** as `ActivityCompleted.result`):
  `{"version": 1, "parent", "spawn_id", "child", "endpoint": {"recipient","source","capabilities"}, "prior_claim": bool}`.
  `prior_claim` must be a real `bool`.

**Deterministic identities** (`call.py:112-120`, `model.py:29-33, 96-98`, `spawn.py:61-63`):

| Identity | Formula |
| --- | --- |
| request delivery id | `"process-call-v1-request-" + sha256_hex(call_id.encode())` |
| reply delivery id | `"process-call-v1-reply-" + sha256_hex(len(caller_utf8).to_bytes(4,"big") + caller_utf8 + call_id_utf8)`, where caller is `request.sender`. **Result and error share it**, so Fabric's digest conflict enforces one terminal reply per call. |
| child identity | `"process-v1-" + sha256_hex(b"impetus-process-child\x00" + canonical({"version":1,"parent":p,"spawn_id":s}))` |
| spec digest | `sha256_hex(canonical(spec.to_data()))`. Covers the full spec, while the child identity covers only `(parent, spawn_id)`. |
| spawn idempotency | `"process.spawn:" + child_identity` |

Golden vectors (computed from upstream formulas):

- Request id for `call-1`: `process-call-v1-request-5d7963c4f471e142f5a72214a9666fb164718f9ba1066a7862ac1c5041887940`.
- Reply id for caller `parent`, call `call-1`: `process-call-v1-reply-1d24e7fa5fa0267dac50d90c40d54cbf70aeb559afce4acbfd7c9a42e9cee16a`.
- Child identity for `("parent","spawn-1")`:
  - preimage JSON: `{"parent":"parent","spawn_id":"spawn-1","version":1}`
  - result: `process-v1-d2404af783c2bf50f6456e89c63e58067a6205fb5e23d3de79a411921c64ecad`
- Spec digest of the test `spec()` (`test_processes.py:37-48`):
  - canonical: `{"capabilities":{"features":["reply"],"protocol":"call-v1"},"config":{"model":"deterministic","tools":["read"]},"parent":"parent","process_kind":"analysis-agent","reply_route":{"instance_id":"parent","source":"replies"},"source":"calls","spawn_id":"spawn-1","version":1}`
  - digest: `aaecd4dec0dac39c094907371226d2748593e905638daa23629703224ed38584`

**Lifecycle schema** (`postgres.py:18-27`). This is the verbatim DDL. `_SCHEMA_VERSION = 1`.

```sql
CREATE SCHEMA IF NOT EXISTS impetus_lifecycle
CREATE TABLE IF NOT EXISTS impetus_lifecycle.schema_metadata (component text PRIMARY KEY, version integer NOT NULL)
CREATE TABLE IF NOT EXISTS impetus_lifecycle.spawns (
        parent text NOT NULL, spawn_id text NOT NULL, child text NOT NULL UNIQUE,
        spec_digest text NOT NULL, created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
        PRIMARY KEY (parent, spawn_id))
```

**`ensure_lifecycle_schema`** (`postgres.py:30-52`) never commits.

1. Run `SELECT 1 FROM pg_namespace WHERE nspname = 'impetus_lifecycle'`.
2. If the schema exists and `SELECT to_regclass('impetus_lifecycle.schema_metadata')` is NULL,
   check `SELECT to_regclass('impetus_lifecycle.spawns')`. If that is not NULL, raise
   `RuntimeError "the impetus_lifecycle schema contains an unversioned spawns table: refusing unknown shape"`.
3. Run the DDL.
4. Run `INSERT INTO impetus_lifecycle.schema_metadata (component, version) VALUES ('lifecycle', %s) ON CONFLICT DO NOTHING`.
5. Run `SELECT version FROM impetus_lifecycle.schema_metadata WHERE component = 'lifecycle'`.
   Anything other than 1 raises `RuntimeError "the database speaks impetus_lifecycle schema version 999, but this runtime requires version 1; migrate deliberately"`.

The test pins the column order: `parent, spawn_id, child, spec_digest, created_at`.

**Registry statements** (`postgres.py:72-129`):

- claim:
  1. `INSERT INTO impetus_lifecycle.spawns (parent, spawn_id, child, spec_digest) VALUES (%s, %s, %s, %s) ON CONFLICT DO NOTHING`
  2. Then `SELECT child, spec_digest FROM impetus_lifecycle.spawns WHERE parent = %s AND spawn_id = %s`.
  3. If the row is not `(spec.child, spec.digest)`, raise `ValueError "spawn identity conflict for ('<p>', '<s>'): content changed"`.
  4. `prior_claim` is `insert rowcount == 0`.
  5. `spec.parent` must equal the registry parent, else `PermissionError "spawn parent must match the authenticated registry"`.
- child_of: `SELECT child FROM impetus_lifecycle.spawns WHERE parent = %s AND spawn_id = %s`
- children_of: `SELECT spawn_id, child FROM impetus_lifecycle.spawns WHERE parent = %s ORDER BY spawn_id`
  - `child_of` and `children_of` raise `PermissionError "lineage parent must match the authenticated registry"` for a different parent.
- parent_of: `SELECT parent, spawn_id FROM impetus_lifecycle.spawns WHERE child = %s`
  - If the found parent is not the registry parent: `PermissionError "child does not belong to the authenticated parent"`.

Telemetry: `lifecycle_denied {operation, instance}`, `lifecycle_conflict {operation="spawn", parent, spawn_id}`,
`lifecycle_claimed {parent, spawn_id, child, prior_claim}`.

#### 3. Concurrency & durability semantics

- **Claims are autocommit-only**, so every claim is durable before `ensure` runs. If provisioning
  fails after the claim, the Activity retry re-claims (`prior_claim=True`) and re-ensures. The
  provisioner must therefore be **idempotent** (`test_failed_provision_after_claim_retries_the_same_claim`).
- **Concurrent exact claims converge on one row.** The second `INSERT … ON CONFLICT DO NOTHING`
  waits for the first. The follow-up `SELECT` (READ COMMITTED) then sees the committed row, so the
  two claims return `{False, True}`.
- **One terminal reply per call.** The result and error envelopes share a delivery id. The first to
  `submit` wins, and the other gets a Fabric "identity conflict".
- **At-least-once.** The `SpawnActivity` runs at least once under any Dispatch. Exactly-once
  identity comes from `(parent, spawn_id)`.
- No locks beyond row-level uniqueness. No heartbeats or leases.

#### 4. External dependencies

These are the same as Fabric's: sha256, petrus-json `canonicalText`, and the Postgres client. Building
the reply-id preimage needs `Data.ByteString.Builder.word32BE`. HMAC (demo provisioner only) is
available in `crypton` `Crypto.MAC.HMAC`.

#### 5. Upstream tests

`tests/petrus/processes/test_processes.py` has **19 test functions**. No parametrization.

- **10 pure tests (no docker):**
  - neutral import guard (subprocess)
  - spawn spec exact, detached, strict, and fully digested
  - child identity stable, parent-scoped and not spec-scoped (`process-v1-` + 64 hex)
  - outcome and provisioning cross-identity refusals
  - call values exact and detached
  - call envelopes correlated, with the shared reply identity (`result.delivery_id == error.delivery_id`, digests differ)
  - call helpers refuse mismatches
  - `SpawnActivity`: claim before ensure; re-ensure on exact retry (`events == ["claim","ensure","claim","ensure"]`)
  - `SpawnActivity`: wrong activity, idempotency or registry identity refused
  - `SpawnActivity`: refuses a live object from the provisioner
- **9 docker tests**, using the fixture `lifecycle(pg_connection)`, which drops and recreates
  `impetus_lifecycle` and `impetus_fabric`, registers `parent`, and yields
  `(connection, credential, registry)`:
  - lifecycle schema columns and version refusals
  - provisioning does not commit the caller's transaction (`to_regnamespace` check)
  - registry requires autocommit and authentication
  - claim durable, conflict-detecting and queryable
  - lineage parent-bound
  - **concurrent exact claims** (ThreadPoolExecutor, 2 connections)
  - failed provision retries the same claim
  - call result and error share the Fabric conflict identity (real `PostgresFabric` submits)
  - **acceptance demo**: `scripts/cv5-lifecycle-demo.py --dsn <dsn>` (subprocess, 90 s). Expected
    stdout lines include `spawn retry: claims=1 ensure_calls=2 prior_claim=true`,
    `child history before host open: 0`, `offline call: pending=1 parent=awaiting`,
    `unrelated correlation: parent=awaiting`, `correlated result: parent=completed child=completed`,
    `correlated error: parent=completed outcome=error`,
    `replay: parent appends=0 dispatches=0; child appends=0 dispatches=0`,
    `credential absent from outcomes/envelopes/history: true`, `overall: PASS`.

#### 6. Performance

The hot paths are cheap and pure: canonical JSON, then sha256 for the child identity, spec digest
and reply id; `from_data` validation. `claim` costs 3 round trips (auth, insert, select).

Benchmark:

- A microbenchmark of `SpawnSpec` construction plus `digest`, `child_identity` and
  `request_envelope`/`result_envelope` over 100k iterations with a 1 KiB config.
- `claim` throughput for 10k distinct `spawn_id`s on one autocommit connection.
- Compare under identical Postgres and no pooling.

#### 7. Better-the-Haskell-way suggestions

**Suggestions:**

- Express `ChildId` as a newtype that can only be built by `childIdentity parent spawnId`. Then the
  cross-identity checks in `Provisioning`, `SpawnClaim`, `SpawnOutcome` and `Lineage` become
  smart-constructor invariants, or are eliminated by storing `(parent, spawnId)` and deriving `child`.
- `CallReply = CallResult … | CallError …` as a sum type, with `replyFromEnvelope` returning
  `Either CallProtocolError CallReply`.
- `ProcessProvisioner.ensure :: Provisioning -> IO ()`. The "must return None, never a live host or
  credential" rule is then enforced by the type; that test becomes a type-level guarantee to record
  in PARITY.
- Make the registry's autocommit requirement a type, e.g. `AutocommitConnection`.

**Quirks to preserve:**

- `prior_claim` is reported from the insert rowcount, not from a `SELECT`.
- The spec digest covers `capabilities`, `config`, `process_kind`, `source` and `reply_route`, while
  the child identity covers only `(parent, spawn_id)`.
- The reply id length prefix is the UTF-8 **byte** length as 4 bytes big-endian. Contrast Fabric's
  `ingress_identity`, which counts code points.
- `CallResult.from_data` passes `data["result"]` through, so any JSON value is allowed, including
  `null`.

#### 8. Packaging

- **`petrus-processes`** (proposed). `Petrus.Processes.Call` and `Petrus.Processes.Model` are pure
  and depend on `petrus-fabric`'s model. They can be built in parallel with Fabric and the kernel.
- `Petrus.Processes.Spawn` depends on motus `ActivityInvocation` (activity package) and Fabric
  `Endpoint`.
- `Petrus.Processes.Postgres` (sub-library) depends on `petrus-fabric-postgres` for authentication,
  and on `petrus-postgres`.
- The demo and acceptance test need engine-postgres plus Dispatch. Build them last, and use them as
  the Python↔Haskell interop harness (Python parent spawning or calling a Haskell child, and the
  reverse).

## 5. Observation and simulation

### Observation projection (`impetus/observation.py` + Engine read doors)

Upstream: `src/petrus/impetus/observation.py` (194 lines), the three read doors in
`src/petrus/engine/__init__.py:362-374`, and the read/write lock discipline in
`src/petrus/engine/__init__.py:142,547-584`. Specs: `spec/observation-protocol-v1.md`,
`spec/observation/engine-snapshot-v1.json`, `spec/observation/engine-history-page-v1.json`,
`spec/net-document-v1.md` §1d/§1e, fixtures `spec/net-document-v1-observation.json` and
`spec/net-document-v1-inspection.json`.

#### 1. Responsibility & public API

Pure projections from one captured `(Instance, records)` pair to detached JSON values. No I/O.

| Python function | Signature | Notes |
| --- | --- | --- |
| `definition` | `(net: Net) -> dict` | `project_net_definition(net).definition.model_dump(mode="json")` — the **inner** v3 body (no `format`/`version` envelope). Any `ValueError` re-raised as `"observation data must be strict JSON-faithful: {error}"` (`observation.py:40-45`). Non-integer `Delay`/`Until` values raise here (test expects `Delay duration.*integer` / `Until instant.*integer` from the v3 projector). |
| `net_inspection` | `(net: Net) -> dict` | `json.loads(serialize_net_document(project_net_document(net)))` — definition-only Net document (`observation.py:48-50`). |
| `marking` | `(value: Marking) -> list` | `[{"place": str(p), "tokens": [{"color","data"}…]}]` sorted by `str(place)` (code-point order), FIFO tokens, then `_strict` (`observation.py:88-95`). Sparse: only places the `Marking` iterates (kernel `Marking` already omits empty queues). |
| `snapshot` | `(instance: Instance, records: tuple[Record, ...]) -> dict` | `observation.py:114-167`. |
| `history_page` | `(instance_id: str, records, after: int, limit: int) -> dict` | `observation.py:170-191`. |
| `net_document` | `(instance: Instance, records) -> dict` | Observed Timeline document (`observation.py:53-81`). |

Engine read doors (`engine/__init__.py:362-374`), each wrapped in `Engine._read` (lock, re-entry refusal, open/poison check):

```python
def snapshot(self) -> dict[str, object]       # _snapshot(self._instance, self._instance.history.records)
def net_document(self) -> dict[str, object]   # _net_document(self._instance, self._instance.history.records)
def history_page(self, after: int, limit: int) -> dict[str, object]
                                              # _history_page(self._instance.instance_id, self._instance.history.records, after, limit)
```

Kernel APIs consumed (the Haskell kernel must expose all of these):

- `Instance`: `instance_id`, `net`, `marking`, `status` (`Status` enum `.value`, may evaluate the current completion CEL), `watermark :: Instant`, `next_maturation :: Instant | None`, `in_flight :: tuple[FiringOccurrence, ...]` (begin order), `armed :: Mapping[NetPath, frozenset[str]]` (only non-empty key sets), and the private `_frozen_results: dict[int, object]` (occurrence id → frozen Activity result or `ActivityFailure`; presence ⇒ `projection_pending`). Haskell: expose a public `frozenResults`/`projectionPending` accessor instead of reaching into internals.
- `FiringOccurrence`: `.id :: int`, `.binding.transition`, `.binding.consumed`/`.binding.read` (ordered `[(NetPath, tuple[Token,...])]`), `.binding.delivered :: tuple[Token,...]`, `.invocation :: ActivityInvocation | None`.
- `ActivityInvocation` (`motus/activity/__init__.py:354-370`): `activity`, `input`, `policy: ExecutionPolicy`, `correlation`, `idempotency`.
- `ExecutionPolicy` dataclass field order (`motus/activity/__init__.py:306-317`): `attempts:int=1, heartbeat_timeout:int=30, initial_interval:float=0, coefficient:float=2, max_interval:float=60, jitter:float=0, start_to_close:float|None=None, schedule_to_close:float|None=None`. Emitted via `dataclasses.fields` order. **Int-vs-float spelling is preserved** (defaults are ints, fixture shows `"coefficient": 2`, a user-provided `2.0` would print `2.0`): the Haskell type must carry `Json`-style numbers (`Int Integer | Float Double`), not `Double`.
- `ActivityFailure` (`motus/activity/__init__.py:386-393`): `error, kind, details, retryable, retry_after`.
- History: `Record`, `replay_markings(records) -> tuple[Marking, ...]` (`impetus/history/__init__.py:1000`; one complete marking **after** each record), `codec.encode_record(record) -> dict` (schema-5).
- Net document: `ExecutionLineage`, `LineageEntry`, `PlaceMarking`, `project_net_document(net, lineage=…)`, `serialize_net_document(doc) -> bytes`; `project_net_definition`.

#### 2. Wire formats

**Snapshot** (`observation.py:149-166`; fixture `spec/observation/engine-snapshot-v1.json`). Python insertion order (matters when re-serialized un-sorted, e.g. inside an observed Net document's metadata):

```text
{ "protocol": 1,
  "instance": <str>,
  "definition": <v3 inner body: name, time_domain, places, transitions, arcs, completion>,
  "frontier": len(records),
  "current": {
    "marking":  [ {"place", "tokens":[{"color","data"}]} ]   # sorted by place, sparse
    "status":   instance.status.value                        # e.g. "running", "completed"
    "watermark": <int>
    "in_flight": [ {
        "occurrence": <int>, "transition": <str>,
        "phase": "pure_pending" | "activity_pending" | "projection_pending",
        "binding": {"consumed": [{"place","tokens"}], "read": [{"place","tokens"}], "delivered": [{"color","data"}]},
        "invocation": null | {"activity","input","policy":{attempts,heartbeat_timeout,initial_interval,coefficient,max_interval,jitter,start_to_close,schedule_to_close},"correlation","idempotency"},
        "result": null | <frozen result JSON> | {"error","kind","details","retryable","retry_after"} } ],
    "armed": [ {"source": <str>, "key": <str>} ]   # sorted by str(source), then key; one row per key
    "next_maturation": <int> | null } }
```

- Phase rule (`observation.py:122-123`): `projection_pending` if `occurrence.id in _frozen_results`, else `activity_pending` if `invocation` is not None, else `pure_pending`. `result` is non-null only for `projection_pending`.
- `consumed`/`read` keep binding order (not sorted); `marking` and `armed` are sorted with Python `str` ordering = Unicode code-point order (Haskell `Text` `compare` on text-2 is UTF-8 byte order = code-point order: OK).
- Integer checks (`observation.py:34-37,116-119`): `watermark` and `next_maturation` must be non-bool `int` → `ValueError("protocol 1 requires current watermark to be an integer, got …")`. In Haskell `Instant = Integer` makes this unrepresentable (record as "enforced by types" in PARITY).
- `_strict` (`observation.py:26-31`): `json.loads(json.dumps(value, allow_nan=False))` — detaches, refuses NaN/Inf and non-JSON objects with `ValueError("observation data must be strict JSON-faithful: …")`. In Haskell token data is already a `Json` value; only non-finite `Float`s can fail (if the kernel allows them in tokens at all).

**History page** (`observation.py:170-191`; fixture `engine-history-page-v1.json`), insertion order:
`{"protocol":1,"instance","after","next","frontier","records":[{"position":i,"record":encode_record(records[i])}]}` with `next = min(after+limit, frontier)`, positions dense in `[after,next)`.
Refusals (all `ValueError`, exact messages):
- `after` bool/non-int/negative → `"history after must be a non-negative integer, got {after!r}"`
- `limit` bool/non-int/≤0 → `"history limit must be a positive integer, got {limit!r}"`
- `after > frontier` → `"history after {after} exceeds captured frontier {frontier}"`; `after == frontier` → empty page.
No maximum limit at this layer (the HTTP adapter adds 1000).

**Observed Net document** (`observation.py:53-81`; spec `net-document-v1.md` §1d/§1e; fixture `net-document-v1-observation.json`):
- Requires non-empty records (`ValueError("an observed Net document requires nonempty canonical History")`).
- One `LineageEntry` per record `i`: `id=i`, `parent = null if i==0 else i-1`, `provenance="observed"`, `marking = marking(replay_markings(records)[i])` (complete marking **after** record `i`), `metadata` built in this exact key order: `instance` (only `i==0`) → `observation` (only `i==len-1`; it is `snapshot(...)["current"]` minus `marking`, i.e. keys `status, watermark, in_flight, armed, next_maturation`) → `history_record` (always, `encode_record(record)`). `head = len-1`.
- Built with `project_net_document(instance.net, lineage=…)`, serialized by `serialize_net_document` (UTF-8, `ensure_ascii=False`, `allow_nan=False`, `indent=2`, insertion order, one trailing `\n` — `net_document.py:283-294`) and returned as `json.loads(...)` of those bytes.
- `serialize_net_document` re-validates: strict JSON, Unicode scalars only, **integral numbers within ±(2^53−1)** (`net_document.py:76-84`), sorted unique definition-owned places, non-empty token arrays, colors. A token whose data holds an integer outside the safe range makes `Engine.snapshot()` succeed but `Engine.net_document()` raise `NetDocumentError` (a `ValueError` subclass, `net_document.py:23`). Preserve.

**Inspection document** = `serialize_net_document(project_net_document(net))` parsed back; definition-only (`view`/`lineage` omitted, never `null`). Fixture `net-document-v1-inspection.json` (built from a DSL `NetSpec` with stamps; no implementations, no `display_name`, no `<lambda>`).

#### 3. Concurrency & durability semantics

- One `threading.RLock` per Engine, `_monitor` (`engine/__init__.py:142`). Every writing door (`advance`, `deliver`, `accept_delivery`, `complete_delivery`, `open_scope`, `close_scope`, `reset_scope`, `seal`) runs inside `_guarded` (`:547-562`), which holds `_monitor` for the **whole** door: History append, Instance projection, provider commit. Readers (`_read`, `:564-569`) take the same lock, so `snapshot`/`history_page`/`net_document` always see `frontier == len(records)` coherent with `current`. A reader arriving mid-door blocks until the door ends and then sees the **after**-state (test `test_snapshot_blocks_between_append_and_projection_then_sees_coherent_after_state`).
- The whole projection (definition projection, deep copies, `_strict` JSON round trip, full `replay_markings` for documents) runs **while holding the lock** in Python.
- Re-entry: `_guarded` records `_write_thread = threading.get_ident()`; a same-thread call to `snapshot`/`history_page`/`net_document` during a writing door raises `RuntimeError("public Engine operation cannot re-enter while a writing door is active")` (`:571-573`). Property reads `marking`, `status`, `in_flight`, `active_scopes`, `records` pass `allow_reentry=True` (Sensors call them inside doors).
- `_ensure_open` (`:575-584`): calls provider `resources.ensure()` first (provider-defined; e.g. writer-fence checks), then poisoned → `RuntimeError("this Engine is poisoned after a writing door failed (…) …")`, closed → `RuntimeError("this Engine is closed; …")`. Any writing-door exception poisons the Engine permanently; observation of a poisoned Engine refuses (test: joined commit failure hides the uncommitted frontier even though the backend-owned History store kept the records).
- Cursor law: frontier only grows; pages from a frozen snapshot frontier remain valid while History keeps appending; reconnect with last `next` gives no gap/duplicate.

#### 4. External dependencies

None beyond the kernel and JSON. Haskell: `petrus-json` (`Json` with `Int`/`Float` distinction, `dumps` with `EncodeOptions`), `containers` (`Seq` for records), `stm` or `base` `MVar`.

#### 5. Upstream tests — `tests/petrus/engine/test_observation.py`

19 functions → 29 collected items (`test_protocol_strictly_refuses_non_integer_timer_values` ×6 params, `test_history_page_refuses_malformed_cursor_or_limit` ×6). No markers, no Docker/network; uses threads for the barrier test. Fixture paths resolved relative to the test file (`Path(__file__).parents[3] / "spec"`).

| Group | Tests |
| --- | --- |
| Definition shape: path-sorted places/transitions, authored arc `position`, duplicate parallel arcs distinct, declaration `kind` (`symbol`/`anonymous`/`cel`) + `uri` (`transition:/t#handler`, `transition:/t#guard:named_guard`, `…#guard:$1`), timer order, filters without `uri`, completion | `test_exact_definition_shape_…` |
| Exact fixtures (structural equality) | snapshot, history page, observed Net document, inspection document (DSL stamps; parallel arcs at positions `[1,5]`) |
| History schema-5 transport incl. scope fields (`ScopeOpened`, `ScopeClosed`, `scope.name`) | `test_protocol_v1_history_transports_…` |
| Cursor algebra, frozen frontier while appends continue (`engine.seal`), empty page at frontier, future cursor refused | 2 tests + parametrized refusals (`-1, True, 0.5` / `0, True, 1.5`) |
| Phases `pure_pending` (via private `Instance.begin`), `projection_pending` with frozen result and with `ActivityFailure` | 2 tests |
| Detachment (mutating inputs after snapshot does not change it) | 2 tests — **enforced by Haskell immutability**; port as trivial or record as type-enforced |
| Strictness: non-integer timers, non-JSON name, NaN / `object()` token data, bool watermark/next_maturation | 4 tests — mostly type-enforced in Haskell |
| Atomicity: reader blocks between History append and projection; same-thread re-entry refused while property reads allowed; poisoned Engine refuses observation | 3 tests |

Test helpers: `canonical_engine()` (Net `a:Input`, `b:Done`, `c`, transitions `work` (handler `bridge`, an Activity handler with `prepare`/`project`) and `source`; marking two `Input` tokens; `at=7`; one `advance()`), `PausingHistory` (InMemoryHistoryStore whose `extend` blocks on an Event).

#### 6. Performance

Hot paths: `snapshot` (recomputes `definition(net)` every call; deep-copies; JSON round trip), `history_page` (`encode_record` per record), `net_document` (O(N) `replay_markings` producing N complete markings ⇒ O(N·M) output, then pydantic validation + `indent=2` serialization). All under the Engine lock in Python, so observation latency directly stalls the writer.

Benchmark proposal (same Net/marking built in both languages from a shared JSON scenario; in-memory store; outputs compared byte-for-byte via the canonical encoder before timing):
- Engines with N ∈ {1k, 10k, 50k} records and M ∈ {10, 1k} live tokens (loop net driven N/≈5 actions).
- Measure: `snapshot()` latency, `history_page(0, 1000)` and a full paged scan, `net_document()` latency + allocated bytes; plus **writer stall**: throughput of `advance()` in one thread while another thread polls `snapshot()` in a tight loop.
- Haskell should win heavily by capturing an immutable state reference and projecting outside the critical section (see §7).

#### 7. Better-the-Haskell-way

- Represent Engine state as an immutable value (`EngineState { instance :: Instance, records :: Seq Record }`) published in a `TVar` together with a `writing :: Maybe ThreadId` flag. Readers: `atomically $ do s <- readTVar v; when (isJust (writing s)) retry; pure s`, then project **outside** STM. This keeps the upstream "block until the door finishes, then see the after-state" semantics while shrinking the critical section to a pointer read. Re-entry refusal: compare `writing` with `myThreadId` and throw the same `RuntimeError`-equivalent (`EngineReentry`) instead of deadlocking.
- Cache the projected `definition` (and its encoded bytes) per `Net`; Net is immutable.
- `net_document` can stream: markings can be folded incrementally (`scanl` over records) instead of materializing a tuple of all markings; the serializer can emit entries lazily via `Builder`.
- Typed result: `data Phase = PurePending | ActivityPending | ProjectionPending FrozenResult` (result only exists in the third case — invalid states unrepresentable); `data Snapshot`, `data HistoryPage` with `toJson` producing the **insertion order above** (sorted order is applied only by the HTTP encoder).
- `history_page` arguments become `Natural`/`Positive` at the Haskell API, but keep a `Json`-level validator for any language-neutral entry point; the "exceeds captured frontier" check stays a runtime error.
- Preserve quirks: snapshot accepts unsafe integers while the document refuses them; `armed` flattening; `observation` metadata excludes `marking`; key order of metadata (`instance`, `observation`, `history_record`).

#### 8. Packaging

- `Petrus.Impetus.Observation` in `petrus-impetus` (upstream places it in `impetus`), needs: Instance (incl. frozen results accessor), history codec + `replay_markings`, net definition v3 projection, net document v1 (`project`, `serialize`, lineage types), Activity types (`ActivityInvocation`, `ExecutionPolicy`, `ActivityFailure` — these are already needed by Instance). Note the upstream import of `petrus.motus.activity.ActivityFailure` from `impetus` — the Haskell kernel should own these value types (or a small `petrus-activity-types` module) to avoid a cycle.
- Engine read doors live with the Engine (`petrus-engine`).
- Can be built as soon as Instance/history/net-document land; parallel with the HTTP core (§ Observation HTTP) and the simulation admission logic.

---

### Observation HTTP adapter (`engine/observation_http.py`)

Upstream: `src/petrus/engine/observation_http.py` (145 lines); spec `spec/observation-protocol-v1.md:67-98` ("Standard-library HTTP transport profile").

#### 1. Responsibility & public API

```python
MAX_HISTORY_PAGE_LIMIT = 1000
class ObservationHTTPServer(ThreadingHTTPServer):      # daemon_threads = True
    def __init__(self, server_address: tuple[str, int], engine: Engine)
def create_observation_server(engine: Engine, host: str, port: int) -> ObservationHTTPServer
```

- Factory **binds and listens** (TCPServer constructor does `bind` + `listen(5)`) but starts **no thread** (test `test_factory_binds_without_starting_a_hidden_thread`). The application owns `serve_forever()`, `shutdown()`, `server_close()`; `server.server_port` exposes the bound port (port 0 ⇒ ephemeral). Closing the server never closes the Engine; the Engine keeps executing after shutdown.
- Engine APIs used: `engine.snapshot()`, `engine.net_document()`, `engine.history_page(after, limit)` only. Never a writing door.

#### 2. Wire protocol

Routes (`observation_http.py:37-62`), matched on `urlsplit(self.path).path` (exact string compare, no percent-decoding):

| Method | Path | Behavior |
| --- | --- | --- |
| GET | `/v1/snapshot` | non-empty query ⇒ 400 `"snapshot does not accept query parameters"`; else 200 snapshot |
| GET | `/v1/document` | non-empty query ⇒ 400 `"document does not accept query parameters"`; else 200 observed Net document |
| GET | `/v1/history` | query grammar below; 200 page |
| GET | anything else | 404 `not_found` / `"route not found"` |
| OPTIONS | **any path** (no route check) | 204, empty body, no `Content-Type`, `Allow: GET, OPTIONS` |
| POST, PUT, PATCH, DELETE, HEAD | **any path** (no route check, so `POST /unknown` is 405 not 404) | 405 `method_not_allowed` / `"method not allowed"`, `Allow: GET, OPTIONS`. **HEAD gets a JSON body written** (quirk: `_respond` does not suppress bodies for HEAD) |
| any other method token (TRACE, CONNECT, FROBNICATE…) | — | stdlib `send_error(501, "Unsupported method ('TRACE')")` HTML page (no `do_TRACE` defined) |

History query (`observation_http.py:85-103`), applied to the raw query string:
1. `parse_qsl(query, keep_blank_values=True, strict_parsing=True)`: split on `&` only (`;` is not a separator), `+`→space, percent-decode as UTF-8 with `errors="replace"`. Empty query ⇒ `[]`. A segment without `=` or an empty segment (`a&&b`, trailing `&`, bare `&`) ⇒ `ValueError("bad query field: 'after'")` (Python `repr` of the segment — single quotes unless it contains `'` and no `"`).
2. Name not in `{after, limit}` ⇒ `"unknown history query parameter: {name or '<empty>'}"`; repeated ⇒ `"history query parameter {name} must appear exactly once"`.
3. For `after` then `limit`: missing ⇒ `"history query parameter {name} is required exactly once"`; value not matching `[0-9]+\Z` (ASCII digits, non-empty; rejects `+1`, ` 1`, `-1`, `1.0`) ⇒ `"history query parameter {name} must be a non-empty unsigned decimal integer"`.
4. `int(after)`, `int(limit)` (in that order). CPython refuses > 4300 digits **including leading zeros** with `ValueError("Exceeds the limit (4300 digits) for integer string conversion: value has N digits; use sys.set_int_max_str_digits() to increase the limit")` ⇒ 400 with that message. Haskell must reproduce (petrus-json/`read` has no such limit).
5. `limit > 1000` ⇒ `"history limit must not exceed adapter maximum 1000"`. Then `Engine.history_page` semantic errors (`limit == 0` ⇒ `"history limit must be a positive integer, got 0"`, `after > frontier` ⇒ `"history after 999 exceeds captured frontier N"`).

Status / error mapping (`observation_http.py:55-62`):

| Exception from routing/Engine | Status | `code` | `message` |
| --- | --- | --- | --- |
| `ValueError` (query grammar, history semantics, `NetDocumentError`, snapshot strictness) | 400 | `invalid_request` | `str(error)` — **exception text crosses the wire** |
| `RuntimeError` (closed, poisoned, re-entry) | 503 | `engine_unavailable` | `"Engine is unavailable"` |
| `BrokenPipeError`, `ConnectionResetError` | — | — | swallowed |
| any other `Exception` | 500 | `internal_error` | `"internal server error"` |

Error body: `{"error":{"code":"…","message":"…"}}`.

Encoding (`observation_http.py:105-107`): `json.dumps(value, allow_nan=False, separators=(",", ":"), sort_keys=True).encode()` — compact, **sorted keys, `ensure_ascii=True`** (non-ASCII escaped `\uXXXX` lowercase hex, astral chars as surrogate pairs), CPython float `repr`. In `petrus-json` terms: `defaultDumps { itemSeparator = Just ",", keySeparator = ":", sortKeys = True, allowNan = False }` (ensureAscii stays True). Note `/v1/document` is therefore **not** the canonical Net-document bytes (`indent=2`, `ensure_ascii=False`, insertion order) — it is the same JSON value re-encoded compact+sorted+ASCII.

Response bytes (`observation_http.py:115-134` plus stdlib `send_response`), exact header order:

```text
HTTP/1.0 <code> <phrase>\r\n             # protocol_version default "HTTP/1.0"; phrase from http.HTTPStatus
Server: BaseHTTP/0.6 Python/3.14.x\r\n   # stdlib, version-specific
Date: <IMF-fixdate, GMT>\r\n             # stdlib (email.utils.formatdate(usegmt=True))
Content-Type: application/json; charset=utf-8\r\n     # omitted on 204
Content-Length: <len(body)>\r\n
Cache-Control: no-store\r\n
Access-Control-Allow-Origin: *\r\n
Access-Control-Allow-Methods: GET, OPTIONS\r\n
Access-Control-Allow-Headers: Content-Type\r\n
Allow: GET, OPTIONS\r\n                   # only on 204 OPTIONS and 405
\r\n<body>
```

Phrases (CPython 3.14): 200 `OK`, 204 `No Content`, 400 `Bad Request`, 404 `Not Found`, 405 `Method Not Allowed`, 500 `Internal Server Error`, 501 `Not Implemented`, 503 `Service Unavailable`. No credentials header. No access log (`log_message` overridden to no-op, which also silences `log_error`).

Request-target quirks inherited from stdlib (`parse_request` / `urlsplit`):
- Leading `//` is collapsed: `GET //v1/snapshot` is served as `/v1/snapshot` (CPython ≥3.12 security fix).
- Absolute-form `GET http://host/v1/snapshot` is accepted (`urlsplit(...).path == "/v1/snapshot"`).
- Fragments are dropped silently: `/v1/snapshot#x` ⇒ 200; `/v1/history?after=0&limit=1#f` works. `/v1/snapshot?` (empty query) ⇒ 200.
- Request body of POST etc. is never read.

Pre-handler stdlib behavior (shared with the simulation server; both are `BaseHTTPRequestHandler`, CPython 3.14):

| Condition | Stdlib response |
| --- | --- |
| Empty request line (connection closed) | close, no response |
| Request line > 65536 bytes | 414 `URI Too Long` HTML (`send_error`) |
| Not 2–3 words / malformed version (`HTTP/x.y` with non-digit or >10-digit components) | 400 HTML (`Bad request syntax`/`Bad request version`) |
| Two-word line (HTTP/0.9) with non-GET | 400 `Bad HTTP/0.9 request type`; `GET /path` 0.9 ⇒ response with **no status line/headers** |
| Version ≥ 2.0 | 505 `Invalid HTTP version` |
| Header line > 65536 or > 100 headers | 431 `Line too long` / `Too many headers` |
| `send_error` format | headers `Server`, `Date`, `Connection: close`, `Content-Type: text/html;charset=utf-8`, `Content-Length`; body = `DEFAULT_ERROR_MESSAGE` HTML template (omitted for HEAD and 1xx/204/205/304) |
| Socket `TimeoutError` while reading/writing | connection dropped silently (simulation only; observation has no timeout) |

Headers are parsed by `http.client.parse_headers` → `email` compat32 parser: names case-insensitive, duplicates kept (`get_all`), value leading whitespace stripped, **trailing whitespace kept** (`Content-Length:1 ` stays `"1 "`), obs-fold continuation lines joined, latin-1 decoding. Persistence: with `protocol_version = "HTTP/1.0"` the stdlib always sets `close_connection = True` ⇒ exactly one request per connection for **both** servers; remaining pipelined bytes are discarded; `shutdown_request` does `shutdown(SHUT_WR)` then `close()`.

#### 3. Concurrency

- `ThreadingHTTPServer`: one OS thread per accepted connection; `daemon_threads = True` ⇒ `server_close()` does **not** wait for in-flight handlers. `serve_forever(poll_interval=0.5)` selector loop; `shutdown()` blocks until the loop exits. Listen backlog 5; `allow_reuse_address = True` (SO_REUSEADDR), `allow_reuse_port = False`; `address_family = AF_INET` (IPv4 only).
- No socket timeout: a stalled client holds its thread indefinitely (daemon, so it never blocks shutdown).
- Engine atomicity comes entirely from `Engine._read` (see Observation projection §3); HTTP encoding happens after the lock is released. Mutation methods never reach the Engine (test compares History before/after).
- Disconnects (`BrokenPipeError`, `ConnectionResetError`) are swallowed and do not affect the Engine.

#### 4. External dependencies & Haskell stack

Python: stdlib only (`http.server`, `urllib.parse`, `json`, `re`).

Haskell recommendation — **a small shared HTTP/1.0 server core** (`Petrus.Http.StdlibServer`, ~400 lines) on `network` (`Network.Socket`, `Network.Socket.ByteString`), `bytestring`, `case-insensitive`, `time` (Date header), `async`/`stm`, `petrus-json`. Reasons warp/wai is a poor fit for byte- and behavior-compatibility:

| Upstream behavior | warp/wai reality | Custom core |
| --- | --- | --- |
| Status line always `HTTP/1.0` regardless of request version; one request per connection; pipelined second request ignored (test counts exactly one `HTTP/1.0 200 OK`) | warp answers with the request's version (`HTTP/1.1`), keep-alive + pipelining by default | trivial |
| Raw request target needed (simulation refuses `//x`, absolute-form, `#`, `?`; observation collapses `//` and accepts absolute-form) | warp normalizes absolute-form to a path (`extractPath`), `rawPathInfo` loses it | keep raw target, then apply per-server rule |
| Duplicate `Content-Length`/`Content-Type`/`Origin` must be visible; `Content-Length: 1, 2` must reach the app | warp rejects/merges some framing headers itself, de-chunks `Transfer-Encoding: chunked` | parse headers like `http.client.parse_headers` |
| `Expect: 100-continue` must be a 400 JSON error, never an interim `100 Continue` | warp auto-sends `100 Continue` when the body is read | no interim responses |
| Per-socket-operation 5 s timeout (simulation) | warp has a slowloris *activity* timeout manager with different semantics | `System.Timeout.timeout` around each `recv`/`sendAll` |
| `Server`/`Date` header order and custom header order | warp injects its own `Server`, `Date`, and may add `Transfer-Encoding` | write headers verbatim |
| Arbitrary method tokens dispatched (simulation) / 501 HTML for unknown methods (observation) | possible in wai but needs per-method handling | per-server `dispatch` table |
| Pre-handler malformed request errors (414/431/400/505 HTML) | warp produces its own 400 pages | emulate `send_error` table above |

Byte-compatibility caveats to accept and document: the `Server` header value is CPython-version-specific (`BaseHTTP/0.6 Python/3.14.6`); recommend emitting `Server: petrus-haskell/<version>` (do **not** impersonate) and treat it as non-normative, while keeping its position (first header) and keeping `Date` second. The `send_error` HTML page can be copied verbatim from CPython 3.14's `DEFAULT_ERROR_MESSAGE` if exact bytes are desired; it is not part of the Petrus spec ("Malformed pre-handler HTTP syntax remains the standard library server's territory", `spec/simulation-http-v1.md:80-82`). Compatibility target for pre-handler errors: same status codes.

Other Haskell libs: `http-types` (status phrases — but its phrases differ from CPython 3.14: e.g. 413 `Payload Too Large` vs `Content Too Large`, 422 `Unprocessable Entity` vs `Unprocessable Content`; keep an own phrase table), `http-client` (tests), `iproute` **not** for origin validation (see simulation HTTP §4).

#### 5. Upstream tests — `tests/petrus/engine/test_observation_http.py`

7 functions → 19 items (`test_history_query_grammar_is_exact` ×11 queries: `""`, `after=0`, `limit=1`, duplicate `after`, extra param, `after=`, `after=+1`, `after=%201`, `after=-1`, `after=1.0`, `limit=1001`; `test_mutation_methods_are_405_and_never_reach_engine` ×3 methods). Real loopback HTTP via `urllib.request` (HTTP/1.1 client) against `127.0.0.1:0`; server run in a thread with `serve_forever`. No Docker/network/credentials.

Covered: factory starts no thread; 200 bodies equal direct Engine calls; exact headers (`Content-Type`, `Cache-Control`, CORS trio) and `Content-Length` equal to compact-sorted encoding length; 400 grammar; future cursor 400; 405 + `Allow` + Engine untouched; 404; OPTIONS 204 with empty body and CORS; closed Engine ⇒ exact `503 {"error":{"code":"engine_unavailable","message":"Engine is unavailable"}}`; server shutdown leaves Engine usable (`advance()` still works).

Not covered upstream but must be ported deliberately (Haskell-side tests recommended): HEAD-with-body quirk, `//` collapse, absolute-form acceptance, 501 for unknown methods, `bad query field` message, 4300-digit limit.

#### 6. Performance

Hot path: per-request thread spawn + JSON encode of potentially large snapshots/documents (sorted-key compact encode). Benchmark: same Engine state (N ∈ {1k, 10k} records) served by both servers; drive with a load generator that speaks HTTP/1.0 without keep-alive (e.g. `oha --http-version 1.0 --disable-keepalive` or a small Haskell/Python client) at concurrency {1, 16, 64}; measure p50/p99 latency and requests/s for `/v1/snapshot`, `/v1/history?after=0&limit=1000`, `/v1/document`; verify response bodies byte-identical first. Also measure writer stall (Engine `advance` rate while the load runs).

#### 7. Better-the-Haskell-way

- `data ObservationError = InvalidRequest Text | EngineUnavailable | NotFound | MethodNotAllowed | Internal` with one total `toResponse`; Engine exceptions classified by type (`EngineClosed`, `EnginePoisoned`, `EngineReentry` ⇒ 503; `ObservationValueError`/`NetDocumentError` ⇒ 400; anything else ⇒ 500), never by catching `SomeException` broadly without re-throwing async exceptions (`catchAny` from `safe-exceptions`/`unliftio` semantics).
- Resource-safe lifecycle: `withObservationServer :: Engine -> HostName -> PortNumber -> (ObservationServer -> IO a) -> IO a`, plus the upstream-shaped `create`/`serveForever`/`shutdown`/`close` trio for hosts that want control. Handler threads via `forkIOWithUnmask`, tracked so `close` can optionally kill (daemon semantics) rather than wait.
- Optional hardening flagged as deviations (off by default for parity): socket timeout, connection cap, IPv6 bind.
- Quirks to preserve for interop: compact+sorted+ASCII JSON on every route (including `/v1/document`); `ValueError` text in 400 messages; 405 before route matching; OPTIONS on any path; CORS `*` on every response; `Allow` only on 204/405. HEAD-with-body: preserve (byte parity) unless upstream changes it — flag in PARITY as a known upstream oddity.

#### 8. Packaging

`petrus-engine` exposes the read doors; the adapter goes in `petrus-observation-http` (or a `Petrus.Engine.ObservationHttp` module in a `petrus-http` package) depending on `petrus-engine`, `petrus-json`, and the shared HTTP core. The HTTP core has no kernel dependency and can be built **now**, in parallel with the kernel; the adapter needs only `Engine.snapshot/netDocument/historyPage` and the Engine error types.

---

### Bounded simulation runner (`simulation.py`, profile `implementation-free-v1`)

Upstream: `src/petrus/simulation.py` (370 lines); spec `spec/simulation-http-v1.md`, `spec/observation/simulation-service-profile-v1.json`, `spec/net-document-v1.md` §1d/§1e, fixture `spec/net-document-v1-simulation.json`; test helper `tests/simulation_support.py`.

#### 1. Responsibility & public API

```python
class SimulationProfileError(ValueError)        # "outside implementation-free-v1"
def simulation_profile(built: BuiltNet) -> dict  # validates the fixed build, returns the profile document
def simulate(built: BuiltNet, initial_marking: Marking, *, max_actions: int) -> bytes
                                                 # one fresh bounded Engine run -> canonical Net document bytes
```

Bounds (`simulation.py:23-38`), all reported in the profile:

| Constant | Value | Profile key |
| --- | --- | --- |
| `MAX_PLACES` | 128 | `places` |
| `MAX_TRANSITIONS` | 128 | `transitions` |
| `MAX_ARCS` | 512 | `arcs` |
| `MAX_INITIAL_TOKENS` | 512 | `initial_tokens` |
| `MAX_INITIAL_PAYLOAD_BYTES` | 1_000_000 | `initial_payload_bytes` |
| `MAX_ACTIONS` | 256 | `actions` |
| `MAX_RETAINED_TOKENS` | 4_096 | `retained_tokens` |
| `MAX_RETAINED_PAYLOAD_BYTES` | 4_194_304 | `retained_payload_bytes` |
| `MAX_HISTORY_RECORDS` | 50_000 | `history_records` |
| `MAX_HISTORY_PAYLOAD_BYTES` | 4_194_304 | `history_payload_bytes` |
| `MAX_RESULT_BYTES` | 4_194_304 | `result_bytes` |
| `MAX_CANDIDATE_OFFERS` | 10_000 | `reachable_input_scans` |
| `MAX_CEL_BYTES` | 4_096 | `cel_bytes` |
| `MAX_DEFINITION_BYTES` | 1_000_000 | `definition_bytes` |
| `MAX_REQUEST_BODY_BYTES` | 1_048_576 | `request_body_bytes` |
| `CONNECTION_TIMEOUT_SECONDS` | 5 | `connection_timeout_seconds` |
| (literal) | 1 | `concurrent_simulations` |

Kernel/Engine APIs consumed: `BuiltNet {net, handlers, guards}` (`impetus/dsl.py:282-291`), `Net` (`places`, `transitions`, `arcs`, `completion`), `Transition` (`path`, `handler`, `guards`, `timers`), `Arc` (`source`, `target`, `mode: ArcMode{CONSUME,READ,INHIBIT}`, `weight`, `filter`), `Place.color`, `Cel.expression`, `Delay.duration`, `Until.instant`, `Marking` (iteration `(place, tokens)`, `.place(p)`), `Token(color, data)`, `NetPath(str)`; `Engine.create(net, "simulation", history=InMemoryHistoryStore(), dispatch=_ForbiddenDispatch(), marking=…, clock=SimulatedClock(at=0), at=0)` (defaults: `policy=choose_conservative`, `selection=SelectionPipeline()`, no handlers/guards/filters/completions maps, so only inline CEL evaluates), `engine.advance() -> DriveOutcome{ready, waiting}`, `engine.marking`, `engine.records`, `engine.in_flight`, `engine.status`, `engine.close()`; `replay_markings`, `encode_record`, `InstanceCreated`; `observation.definition` and `observation.marking`; `project_net_document`, `serialize_net_document`, `ExecutionLineage`, `LineageEntry`, `PlaceMarking`.

#### 2. Profile semantics and result format

**Admission** `_admit(built, initial_marking, max_actions)` (`simulation.py:74-213`) — field-complete, entirely **before** `Engine.create`; order of checks (first failure wins; messages exact):
1. `built` is a `BuiltNet` else `TypeError`; `initial_marking` is a `Marking` else `TypeError`.
2. `max_actions`: non-bool `int` in `1..256` else `"max_actions must be an integer from 1 through 256, got {max_actions!r}"`.
3. Graph sizes: places, transitions, arcs (`"implementation-free-v1 {label} limit is {limit}, found {actual}"`).
4. `built.handlers` non-empty ⇒ `"implementation-free-v1 forbids BuiltNet handler implementations"`; `built.guards` non-empty ⇒ `"… forbids BuiltNet guard implementations"`.
5. Per transition (dict order): `handler` must be `None` (named **and** anonymous refused: `"… requires transition {path} handler to be absent"`); every guard must be `Cel` (`"… guards to be inline Cel"`) with UTF-8 length ≤ 4096 (`"implementation-free-v1 CEL expression limit is 4096 UTF-8 bytes; transition {path} guard has {size}"`); every timer `Delay`/`Until` with non-bool non-negative `int` value (`"… {Delay|Until} value to be an exact non-boolean non-negative integer, got {value!r}"`).
6. Per arc (authored order, `position` index): weight exactly int `1` (`"… arc {position} weight to be exact non-boolean integer 1, got {weight!r}"`); filter `None` or `Cel` (`"… arc {position} filter to be inline Cel"`), CEL size check (`"arc {position} filter"`).
7. Per transition: **selecting inputs** = arcs `place→transition` with mode CONSUME or READ; more than one ⇒ `"… allows transition {path} at most one selecting input arc, found {n}"`; a single READ ⇒ `"… requires transition {path}'s selecting input arc to consume"`. **Outputs** = arcs `transition→place` (any mode); more than one ⇒ `"… at most one output arc, found {n}"`. Inhibitor arcs are unlimited.
8. Completion `None` or `Cel` (`"implementation-free-v1 requires completion to be inline Cel"`), CEL size check.
9. Canonical definition = `observation.definition(net)`; size = `_encoded_size` ≤ 1_000_000 (`"implementation-free-v1 canonical definition limit is 1000000 bytes, found {n}"`); projection errors ⇒ `"canonical definition must be strict JSON-faithful: …"`.
10. Initial token count ≤ 512.
11. Per marking entry: place must be in `net.places` (`"implementation-free-v1 initial marking names foreign place {place}"`); each item exactly `Token` type; color `None` or non-empty `str`; if the place declares a color the token color must equal it (`"implementation-free-v1 token color {color!r} does not match place {place} color {expected!r}"`); data detached by `_strict_detach` (`json.loads(json.dumps(v, ensure_ascii=False, allow_nan=False))`, failure ⇒ `"initial token data at {place} must be strict JSON-faithful: …"`).
12. Projected initial marking (`observation.marking`) encoded size ≤ 1_000_000 (`"implementation-free-v1 initial token payload limit is 1000000 bytes, found {n}"`).
13. **Reachable input-scan bound**: `initial_tokens × max_place_incidence` where incidence(place) = number of arcs `place→transition` of **any** mode (inhibitors count); > 10_000 ⇒ `"implementation-free-v1 reachable input-scan limit is 10000, found bound {b} from {t} initial tokens and maximum place incidence {i}"`.

`_encoded_size(v)` = `len(json.dumps(v, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode())` — UTF-8 bytes of the compact sorted spelling (`simulation.py:62-63`). In petrus-json: `canonicalText`/`compact {sortKeys = True}`.

**Run loop** `simulate` (`simulation.py:296-358`):

```text
projected_initial, frozen = _admit(...)
engine = Engine.create(net, "simulation", InMemoryHistoryStore, _ForbiddenDispatch, frozen, SimulatedClock(0), at=0)
_check_resources(engine)
actions = 0; reason = "action_limit"
while actions < max_actions:
    _check_input_scans(engine.marking)         # Σ over place→transition arcs (any mode) of len(marking.place(source)) ≤ 10000
    outcome = engine.advance()                 # one whole action (AdvanceTime, BeginCandidate+pure completion, …)
    if outcome.waiting: raise "implementation-free-v1 forbids waiting for external work"
    if not outcome.ready: reason = "rest"; break
    actions += 1
    _check_resources(engine)
finally: engine.close()
```

- No extra probe after the last action: hitting `max_actions` reports `action_limit` even if the net would have rested.
- `_check_resources` order (`simulation.py:263-293`): retained token count > 4096 (`"… retained token limit is 4096, found {n}"`) → retained payload (Σ per place `len(str(place).encode())` + Σ per token `_encoded_size({"color","data"})`, early exit, message `"… retained token payload limit is 4194304 bytes, found more than that limit"`) → History record count > 50_000 → History payload (Σ `_encoded_size(encode_record(r))` over **all** records, recomputed every action, early exit, `"… found more than that limit"`) → any in-flight ⇒ `"implementation-free-v1 forbids in-flight work"`.
- `_ForbiddenDispatch.dispatch` raises `SimulationProfileError("implementation-free-v1 forbids Dispatch use")`; `collect()` returns `()`. Structurally unreachable because handlers are refused.
- Completion does **not** halt: status `completed` may be reported while an enabled transition still fires (test `test_completion_reports_completed_without_halting_an_enabled_action`).
- Determinism: fixed instance id `"simulation"`, start instant 0, `SimulatedClock` jumps straight to requested maturation instants, deterministic default policy/selection, no wall clock, no randomness, no activities ⇒ identical bytes for identical inputs (the fixture test asserts byte equality).

**Result** = canonical Net document bytes (`serialize_net_document`: UTF-8, `ensure_ascii=False`, `indent=2`, insertion order, trailing `\n`), ≤ 4_194_304 bytes else `"implementation-free-v1 serialized result limit is 4194304 bytes, found {n}"`. Timeline per History record `i`: `id=i`, `parent=i-1|null`, `provenance="simulated"`, complete `marking` after record `i` (`replay_markings` + `observation.marking`), `metadata`: entry 0 gets the summary keys **in this order** then `history_record`; other entries only `history_record`:

```json
{"profile": "implementation-free-v1",
 "instance": "simulation",                       // records[0] InstanceCreated.instance
 "scenario": {"start_instant": 0, "initial_marking": <projected sorted marking>, "max_actions": <n>},
 "outcome": {"actions_applied": <n>, "reason": "rest" | "action_limit"},
 "status": <engine.status.value>,
 "history_record": <encode_record(records[0])>}
```

`head = len(entries)-1`. Fixture `spec/net-document-v1-simulation.json` (scenario from `tests/simulation_support.py`: places `pending`/`done` colored `SimulationItem`, transition `finish` with CEL guard `size(pending) > 0` and `Delay(5)`, filter `priority >= 1`, completion `size(done) > 0`; one token `{"id":"demo-1","priority":2,"typed":true}`; `max_actions=32`) has 8 entries: `InstanceCreated, TokensInitialized, TimerMatured, CandidateSelected, FiringBegun, TokensConsumed, TokensProduced, FiringCompleted`; `actions_applied: 2` (time advance + firing), `reason: "rest"`, `status: "completed"`.

**Profile document** `simulation_profile(built)` (`simulation.py:216-244`): runs `_admit(built, Marking(), 1)`, returns `{"format":"petrus-simulation-service-profile","version":1,"profile":"implementation-free-v1","definition":<inner v3 body>,"bounds":{…17 keys above…}}`. The fixture `spec/observation/simulation-service-profile-v1.json` is the sorted spelling (it is served sorted).

**Upstream quirk**: an initial token whose data contains an integral number outside ±(2^53−1) (or an integral float like `1e16`) passes admission (`_strict_detach` has no range check), the Engine runs, and `serialize_net_document` then raises `NetDocumentError` — **not** a `SimulationProfileError` — so the HTTP layer answers 500 `internal_error` instead of 422. Lone surrogates likewise pass `_strict_detach` (no UTF-8 encode) and fail at document serialization (HTTP input can't carry them). Preserve for parity; worth reporting upstream.

#### 3. Concurrency & durability

- Pure in-process, no persistence: fresh `InMemoryHistoryStore` and Engine per call, closed in `finally`. A separate live Engine is never touched (test).
- Single-threaded per call; concurrency control (one simulation at a time) lives in the HTTP layer.
- `tests/simulation_support.export` (test-owned application code) writes results atomically: `NamedTemporaryFile(dir=dest.parent, prefix=f".{dest.name}.", delete=False)` → `write` → `flush` → `os.fsync` → `os.replace(tmp, dest)`; on any failure the temp file is unlinked and the previous destination is untouched. No directory fsync.

#### 4. External dependencies

None besides the kernel/Engine. Haskell: `petrus-json`, `petrus-cel` (inline CEL guards/filters/completion), `bytestring`, `text`; for the export helper `directory` + `unix` (`fsync` via `System.Posix.IO`/`hFlush`+`fileSynchronise` from `unix` ≥2.8) or the `atomic-write` package (check it fsyncs before rename; otherwise hand-roll).

#### 5. Upstream tests — `tests/petrus/engine/test_simulation.py` (+ `tests/simulation_support.py`)

19 functions → 27 items (`max_actions` ×7: `True, False, 0, -1, 257, 1.5, "1"`; handlers ×2: `"named"`, `ANONYMOUS`; temp publication ×2: `write`, `fsync`). Fixture path is **relative** (`Path("spec/net-document-v1-simulation.json")`) ⇒ run from the repo root. Uses `monkeypatch` on module constants (`simulation.MAX_TRANSITIONS = 0`, etc.) and on `Engine.create`/`Engine.advance` to prove ordering ("refused before Engine creation", "before next advance").

| Group | Tests |
| --- | --- |
| Exact fixture bytes, strict JSON, dense ids, all `simulated`, one `TimerMatured`, status/outcome | 1 |
| `rest` vs exact `action_limit` (loop net, 3 actions ⇒ 3 `FiringCompleted`) | 1 |
| Admission refusals: max_actions, handlers (named/anonymous), implementation maps, non-JSON tokens, place/token bounds, transition/arc/CEL/definition/result bounds, malformed timer, foreign place, non-`Token` items, color mismatch, named/anonymous guards/filters/completion, weight `True`, multiple selecting inputs, READ selection, output fan-out, consume + 20 inhibits scan bound (`bound 10240` message), payload limit | 9 |
| Runtime bounds ordering: retained tokens, History records, retained payload, History payload, input scans before the first `advance` | 1 |
| Completion does not halt | 1 |
| Isolation from a live Engine; input mutation after `simulate` (type-enforced in Haskell); `_ForbiddenDispatch` | 3 |
| Atomic export helper (replace failure, write failure, fsync failure) | 3 (2 + param) |

Haskell port notes: tests that monkeypatch constants need the bounds as a record parameter (`SimulationBounds`) with the profile defaults, so a test can pass `bounds { maxTransitions = 0 }`. "Before Engine.create" assertions become structural if `simulate = runAdmitted <=< admit` with `admit` pure.

#### 6. Performance

Python hot spots: every action deep-copies `engine.marking` (twice) and **all** `engine.records`, re-encodes every History record for the payload check ⇒ O(A·N) encode work (quadratic over the run, up to 256 actions × thousands of records); `_check_input_scans` O(arcs) per action; final `replay_markings` + pydantic validation + `indent=2` dump of up to 4 MiB.

Benchmark (both sides must produce byte-identical results first):
- Fixture scenario (`max_actions=32`) — latency floor.
- Loop net `a→t→a` with 512 tokens, `max_actions=256` (maximal records).
- Scan-heavy net: 1 place × 19 consuming transitions × 512 tokens (bound 9728, just under 10_000), `max_actions=256`.
- Large payload: 512 tokens with ~1.9 KB data each (≈1 MB initial payload), `max_actions=256` (exercises retained/History payload accounting and the 4 MiB result bound).
Measure wall time per `simulate`, allocations, and result size; run each ≥30 times after warm-up (Python: `pyperf`; Haskell: `tasty-bench`/`criterion`).

#### 7. Better-the-Haskell-way

- Smart constructor: `admit :: SimulationBounds -> BuiltNet -> Marking -> MaxActions -> Either SimulationRejection AdmittedScenario`; `simulate :: AdmittedScenario -> Either SimulationRejection ByteString`. `MaxActions` a newtype validated to `1..256`. `ImplementationFreeNet` carries the evidence that no handler/guard implementations exist and only inline CEL appears; the Engine for simulation is instantiated with a dispatch type that has no constructors (`Void`) so Dispatch use is a type error rather than a runtime refusal (keep the error constructor for API parity).
- `data SimulationRejection` with one constructor per check, a `render :: SimulationRejection -> Text` that reproduces the Python messages exactly (Python `repr` of values where used: `{max_actions!r}`, `{weight!r}`, `{token.color!r}`).
- Incremental accounting: keep running totals of History payload bytes (records only append) and retained-token stats updated from each action's records instead of re-encoding everything; the messages for payload limits carry no numbers, so detection-point equivalence is enough. Keep the check **order** identical.
- Encoded-size computation via a size-only `Builder` fold (no materialized bytes) for `_encoded_size`.
- Stream the final document with a `Builder`, but enforce `MAX_RESULT_BYTES` on the total length (still need the full bytes for the HTTP `Content-Length`; fine at ≤ 4 MiB).
- Preserve quirks: `action_limit` without probe; scan bound counts inhibitor arcs; READ-only selection refused; unsafe-integer ⇒ non-profile error (500 over HTTP); summary key order; `instance` read from `records[0]`.

#### 8. Packaging

`petrus-simulation` (library): depends on `petrus-engine` (Engine.create with injected clock/dispatch/store, `advance`, `DriveOutcome`, `SimulatedClock`), `petrus-impetus` (Net, DSL `BuiltNet`, Marking, history codec, `replay_markings`, memory History store, net definition/document, observation `definition`/`marking`), `petrus-cel`, `petrus-json`. Admission and profile generation can be written as soon as Net/net-definition exist (no Engine needed); the run loop waits for the Engine + Coordinator port. Parallel with observation HTTP and the HTTP core.

---

### Simulation HTTP service (`simulation_http.py`, profile 1)

Upstream: `src/petrus/simulation_http.py` (411 lines); spec `spec/simulation-http-v1.md`; fixture `spec/observation/simulation-service-profile-v1.json`. Consumer: the petrus-viewer browser app (tests use origin `http://localhost:5173`).

#### 1. Responsibility & public API

```python
class SimulationHTTPServer(ThreadingHTTPServer):     # daemon_threads = False, block_on_close = True
    def __init__(self, address, built: BuiltNet, allowed_origin: str, profile: dict)
    profile: dict  (property; fresh detached copy each access via _strict_loads(self._profile_bytes))
    def acquire_simulation(self) -> "acquired" | "busy" | "shutting_down"
    def shutdown(self) -> None                         # sets _shutting_down under _admission_lock, then BaseServer.shutdown()
def create_simulation_server(built: BuiltNet, host: str, port: int, *, allowed_origin: str) -> SimulationHTTPServer
```

Factory order (`simulation_http.py:404-408`): validate origin → `simulation_profile(built)` (full admission, no Engine) → bind/listen. Server captures `_profile_bytes = _encoded(profile)` and `_definition = _strict_loads(_encoded(profile["definition"]))` at construction; the application "cedes" the immutable `BuiltNet`.

#### 2. Wire protocol

Routes: `GET, OPTIONS /v1/simulation-profile`; `POST, OPTIONS /v1/simulations`. **Every** method token is dispatched (`__getattr__` maps any `do_X`, `simulation_http.py:177-180`), so there is never a stdlib 501.

`_dispatch(method)` decision order (`simulation_http.py:203-235`):
1. `close_connection = True`.
2. `Origin` headers (`get_all`) must be exactly one and equal to the configured origin (byte-exact, case-sensitive) else **403** `origin_not_allowed` / `"origin is not allowed"`.
3. Raw request target (`_raw_target` = 2nd whitespace-split word of the latin-1 request line, captured in `parse_request` override before stdlib `//` collapsing, `:171-175`) must start with `/`, not with `//`, contain no `?` and no `#` else **400** `invalid_request` / `"an origin-form path without query is required"` (absolute-form, `*`, `//x`, `/x?`, `/x#y` all refused; empty query `?` too).
4. Route lookup on the raw target: unknown ⇒ **404** `not_found` / `"route not found"`.
5. Method not in route's allow list ⇒ **405** `method_not_allowed` / `"method not allowed"` with `Allow`, `Access-Control-Allow-Methods`, `Access-Control-Allow-Headers`.
6. `OPTIONS` ⇒ **204**, empty body, no `Content-Type`, with `Allow` + preflight headers.
7. `GET` profile ⇒ **200** `_profile_bytes`.
8. `POST` simulations ⇒ `_simulation()`.
Exceptions: `_RequestError` ⇒ its status; `ConnectionError`/`TimeoutError` ⇒ silent; any other `Exception` ⇒ **500** `internal_error` / `"internal server error"`.

`_body()` framing checks (`simulation_http.py:245-285`), in order:
1. Any `Expect` header (even empty) ⇒ **400** `invalid_request` / `"Expect is not supported"`.
2. Any `Transfer-Encoding` or `Content-Encoding` ⇒ **415** `unsupported_media_type` / `"encoded bodies are not supported"`.
3. `Content-Type` count ≠ 1 ⇒ **415** `"application/json is required"`. Value split on `;`, each part `strip().lower()`; first must be `application/json`, at most one more part and it must be exactly `charset=utf-8` ⇒ else **415** `"application/json utf-8 is required"` (`application/json;` with empty param ⇒ 415).
4. `Content-Length` count ≠ 1, or value not ASCII digits (`isascii() and isdigit()`; rejects `+1`, `-1`, `1 0`, `1 ` (trailing space kept by parser), `1, 1`, empty) ⇒ **411** `length_required` / `"exactly one valid Content-Length is required"`.
5. Lexical size check: strip leading zeros (`"0"` if empty); longer than `"1048576"` or equal length and lexically greater ⇒ **413** `payload_too_large` / `"request body exceeds 1048576 bytes"` (no integer overflow possible).
6. `rfile.read(length)`; socket timeout or fewer bytes (client half-closed) ⇒ **400** `"request body is shorter than Content-Length"`.

`_simulation()` (`simulation_http.py:287-318`), in order:
1. `_strict_loads(body)` (`:39-67`): strict UTF-8 decode; `json.loads` with duplicate-member refusal (any depth) and `NaN`/`Infinity`/`-Infinity` refusal; then re-dump `json.dumps(value, ensure_ascii=False, allow_nan=False).encode("utf-8", errors="strict")` to catch overflowed floats (`1e400` ⇒ inf) and lone surrogates (`"\ud800"`). Also caught: `RecursionError`, `MemoryError`, `OverflowError`, `ValueError` from >4300-digit integers, BOM (`JSONDecodeError`). Any ⇒ **400** `"request body must be strict JSON"`. JSON whitespace around the value allowed. Nesting depth: no fixed limit in CPython 3.14 (C-stack-dependent; ~100k+ levels OK in a worker thread, ~300k fails with `RecursionError` ⇒ 400) — Haskell must not stack-overflow; either accept or 400.
2. Top level must be a `dict` with exactly keys `{expected_definition, initial_marking, max_actions}` ⇒ else **400** `"request must contain exactly ['expected_definition', 'initial_marking', 'max_actions']"` (Python `sorted()` list repr — reproduce verbatim). Extra keys with any (strict) value ⇒ 400.
3. `expected_definition` must be an object ⇒ else **400** `"expected_definition must be an object"`.
4. `_decode_marking(initial_marking)` (`:93-126`): must be a list (`"initial_marking must be an array"`); each entry exactly `{place, tokens}` (`"marking entry must contain exactly ['place', 'tokens']"`); `place` non-empty str (`"marking place must be a nonempty string"`); strictly increasing by Python `str` order (`"initial_marking places must be unique and sorted"`); `tokens` non-empty list (`"marking token queues must be nonempty arrays"`); `NetPath(place)` parse (`"marking place is invalid"`); each token exactly `{color, data}` (`"token must contain exactly ['color', 'data']"`); color `null` or non-empty string (`"token color must be null or nonempty string"`). All **400**. Foreign places and color/place mismatch are **not** checked here (⇒ 422 later).
5. `max_actions` non-bool `int` in 1..256 else **400** `"max_actions must be an integer from 1 through 256"` (`1.0`, `true`, `1e400` all refused).
6. `_exact_json_equal(expected_definition, server._definition)` (`:70-82`): same Python type at every node (`int` ≠ `float` ≠ `bool`), objects compared as key **sets** (member order insignificant), arrays ordered, scalars by `==` (so `0.0 == -0.0`) ⇒ else **409** `definition_mismatch` / `"expected definition does not match fixed definition"`. Checked before any Engine/simulate.
7. Admission `server.acquire_simulation()` (`:149-154`) under `_admission_lock`: shutting down ⇒ **503** `server_shutting_down` / `"server is shutting down"`; slot busy ⇒ **429** `simulation_busy` / `"another simulation is running"` (no queue).
8. `simulate(built, marking, max_actions=…)`; `SimulationProfileError` ⇒ **422** `simulation_rejected` / `"simulation was rejected"` (details never leak); any other exception ⇒ 500. Slot released in `finally` **before** writing the response (test).
9. **200** with the exact `simulate` bytes (canonical Net document, `indent=2`, trailing newline) and `Content-Type: application/json; charset=utf-8`.

Encoding of profile and errors (`:35-36`): `json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":")).encode()` = petrus-json `canonicalText` bytes. Errors are exactly `{"error":{"code":"…","message":"…"}}`.

Response bytes (`:328-347` + stdlib), header order:

```text
HTTP/1.0 <code> <phrase>\r\n               # protocol_version = "HTTP/1.0" (:164)
Server: BaseHTTP/0.6 Python/3.14.x\r\n
Date: <IMF-fixdate>\r\n
Content-Type: application/json; charset=utf-8\r\n      # all JSON bodies (200/4xx/5xx); absent on 204
Content-Length: <len(body)>\r\n                         # body length even for HEAD
Cache-Control: no-store\r\n
Access-Control-Allow-Origin: <configured origin>\r\n    # on every response, including 403
Vary: Origin\r\n
Allow: <route allow>\r\n                                # only 204 and 405
Access-Control-Allow-Methods: <route allow>\r\n         # only 204 and 405
Access-Control-Allow-Headers: Content-Type\r\n          # only 204 and 405
\r\n<body unless command == HEAD>
```

No `Access-Control-Allow-Credentials` ever. HEAD on either route ⇒ 405 with `Content-Length` of the error JSON but **no body** (contrast: observation server writes it). Phrases (CPython 3.14): 403 `Forbidden`, 409 `Conflict`, 411 `Length Required`, 413 `Content Too Large`, 415 `Unsupported Media Type`, 422 `Unprocessable Content`, 429 `Too Many Requests`, 503 `Service Unavailable`.

Status summary (`spec/simulation-http-v1.md:69-78`): 400 strict JSON/shape/types/order/target/`Expect`; 403 origin; 404 route; 405 method; 409 definition mismatch; 411 Content-Length; 413 lexical size; 415 media/encoding; 422 profile rejection; 429 overlap; 500 unexpected; 503 shutting down.

`allowed_origin` validation (`_validate_origin`/`_validate_hostname`, `:353-401`), all `ValueError` mentioning `allowed_origin` (except a CPython `urlsplit` bracket error, see below):
- Not `str`, `*`, `null`, any `str.isspace()` char (Unicode whitespace) or code point < 32 ⇒ refused (DEL 0x7F not refused).
- `urlsplit`: scheme ∈ {`http`,`https`} (urlsplit lowercases the scheme; an uppercase scheme then fails the final exact-serialization check), non-empty netloc, empty path/query/fragment; no userinfo; `.port` parse errors (non-digit/non-ASCII/out of 0..65535) ⇒ `"allowed_origin port must be in range"`; hostname required, port 1..65535, netloc not ending in `:`.
- Host: netloc must not contain `%`, `\`, `,`; hostname ASCII; bracketed ⇒ `ipaddress.IPv6Address(hostname)`; otherwise `IPv4Address(hostname)` or, failing that, DNS labels each matching `[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?`, total ≤ 253 (trailing dot refused; `01.2.3.4` is refused as IPv4 by CPython but **accepted** as DNS labels).
- Finally `origin == f"{scheme}://{netloc}"` (so `http://host?`, `http://host#`, `http://host/` refused). Case of host is preserved (`http://Example.com` accepted but browsers send lowercase `Origin` ⇒ every request 403: quirk). Leading-zero ports (`:080`) accepted verbatim.
- CPython 3.14 `urlsplit` itself raises `ValueError` for malformed bracketed hosts (`http://[x]`) with a message lacking `allowed_origin`.

#### 3. Concurrency & timeouts

- `ThreadingHTTPServer`, one thread per connection, `daemon_threads = False`, `block_on_close = True` ⇒ `server_close()` **joins all handler threads** (waits for an active simulation; test `test_shutdown_and_close_wait_for_active_simulation`). `serve_forever(poll_interval=0.01)` in tests. Listen backlog 5, SO_REUSEADDR, IPv4 only.
- Per-connection socket timeout `CONNECTION_TIMEOUT_SECONDS = 5` set in `setup()` (`:167-169`) — read at connection time from the module global (tests patch it to 0.1). It is a **per socket operation** timeout (request line, header lines, body read, response write), not a total deadline: a client trickling one byte every <5 s can hold a thread. Timeout during request line/headers ⇒ stdlib drops the connection silently; during body ⇒ 400; during write ⇒ swallowed.
- Single-flight: `threading.BoundedSemaphore(1)` slot + `threading.Lock` admission lock linearizing `_shutting_down` vs acquisition. No queue; overlap ⇒ 429. Body reading, JSON parsing, and definition comparison happen **before** admission and concurrently across connections (unbounded thread count).
- Disconnect is not cancellation: an admitted simulation runs to completion; its result write fails silently.
- Shutdown: `shutdown()` sets `_shutting_down` (new admissions ⇒ 503), stops the accept loop; in-flight simulations finish; `server_close()` joins.
- One request per connection (HTTP/1.0); pipelined requests ignored.

#### 4. External dependencies & Haskell stack

Python: stdlib only (`http.server`, `socket` timeouts, `threading`, `json`, `ipaddress`, `urllib.parse`, `re`).

Haskell: the shared HTTP/1.0 core described in the observation-HTTP section (`network`, `bytestring`, `case-insensitive`, `time`, `async`, `stm`, `petrus-json`), plus:
- Timeouts: `System.Timeout.timeout (5 * 10^6)` around each `recv` and each `sendAll` chunk to mirror per-op semantics; configurable for tests.
- Single-flight: `TMVar ()` slot or `TVar SlotState` (`Idle | Running | ShuttingDown`) — one STM transaction replaces the lock + semaphore pair.
- Draining: track handler threads (`ki` structured concurrency, or an `async` set in a `TVar`) so `serverClose` can wait like `block_on_close`.
- Origin validation: hand-written parsers mirroring CPython `ipaddress.IPv4Address` (exactly 4 decimal octets, no leading zeros, ≤255) and `IPv6Address` (incl. `::`, embedded IPv4 tail, no zone ids since `%` is refused earlier) — `iproute`'s `Read` instances accept different spellings, so do not rely on them for parity.
- Strict JSON request parsing: petrus-json `strictLoads` (duplicate refusal, non-finite refusal, overflow-to-inf refusal, lone-surrogate refusal, BOM refusal). **Gaps to fill**: the 4300-digit integer limit; a deep-nesting-safe parser (GHC stacks grow, but bound memory by the 1 MiB body). Type-exact, **member-order-insensitive** equality for the 409 check — petrus-json's `exactEq` is order-sensitive and distinguishes `-0.0`, so add a dedicated `typeExactSetEq` (compare object members as maps; `Float` by `==`).
- warp/wai explicitly **not** recommended here (raw target, duplicate framing headers, `Expect`, HTTP/1.0 status line, per-op timeouts, HEAD body suppression rules — see the comparison table above).

#### 5. Upstream tests — `tests/petrus/engine/test_simulation_http.py`

24 functions → 71 items. Parametrized: strict JSON/type/mismatch ×5, nested non-strict ×3, expected_definition type ×3, raw framing refusals ×8, invalid origins ×5, Content-Length lexemes ×7, malformed color ×2, nested definition number type ×2, strict value failures ×5 (incl. `\xff`, 1200-deep array ⇒ 400 because the top level is not an object), ambiguous origin authorities ×17. Real loopback sockets: `urllib.request` for well-formed requests and **raw socket** writes (`raw`, `raw_parts`, `raw_post`) for framing edge cases; `monkeypatch` replaces `simulation_http.simulate` (blocking, failing, or returning `b"{}"`), `Engine.create`, `_SimulationHandler._respond`, and `CONNECTION_TIMEOUT_SECONDS`. Timing-sensitive assertions (`wait(0.2)`, `wait(2)`), threads for overlap/shutdown. Profile fixture path is relative (repo root cwd). No Docker/network/credentials.

| Group | Covered behavior |
| --- | --- |
| Factory | profile equals fixture; admission precedes bind; `Engine.create` never called by factory; invalid/ambiguous origins refused |
| Routing/CORS | 200 profile + exact `ACAO`/`Vary`; OPTIONS 204 with `Allow`/`ACAM`; GET on simulations 405; 404; query ⇒ 400; wrong origin ⇒ 403; duplicate `Origin` ⇒ 403 |
| Methods | HEAD/TRACE/CONNECT/FROBNICATE ⇒ 405 with `Allow`, `ACAO`, exact `Content-Length`, no credentials header, HEAD body empty |
| Success | POST bytes equal direct `simulate(...)` bytes |
| Strict body | malformed JSON, NaN, duplicates (top and nested), bool `max_actions`, `1e400`, `\ud800`, invalid UTF-8, non-object top level ⇒ 400 before `simulate`; `expected_definition` non-object ⇒ 400; malformed color ⇒ 400 |
| Semantics | `{}` definition ⇒ 409; nested `weight` `1.0`/`true` ⇒ 409 before Engine/simulate; foreign place and typed-color mismatch ⇒ 422; injected profile error ⇒ 422 exact body; injected `ValueError("secret")` ⇒ exact 500 body without the secret |
| Framing | missing Content-Type 415; missing/duplicate/comma/signed/spaced Content-Length 411; oversize lexeme 413 (also 27-digit); chunked/gzip 415; duplicate Content-Type 415; `Expect` 400; absolute-form / `http://[x]` / `//` / `#` targets 400; short body 400; pipelined second request ignored |
| Concurrency | overlap ⇒ exact 429 body, slot released after success and after profile error; slot released before response write (client disconnected early); shutdown+close wait for an active simulation; partial body times out (0.1 s) ⇒ 400 and close does not deadlock; `server.profile` copies are detached |

#### 6. Performance

Request path: header parse, ≤1 MiB strict JSON parse + re-dump (Python does it twice), type-exact deep compare of the definition (≤1 MB), simulation (see runner §6), response write ≤4 MiB. Benchmark: the four runner workloads wrapped as HTTP POSTs (bodies built once, identical for both servers), sequential latency (single-flight makes concurrency meaningless for POST), plus `GET /v1/simulation-profile` throughput at concurrency 16/64 with non-keep-alive HTTP/1.0 clients, and a "429 storm" (64 concurrent POSTs while one long simulation runs) to measure refusal latency. Verify byte-identical response bodies (and identical status/header sets modulo `Server`/`Date`) before timing.

#### 7. Better-the-Haskell-way

- `data SimulationHttpError = InvalidRequest Text | OriginNotAllowed | NotFound | MethodNotAllowed Allow | DefinitionMismatch | LengthRequired | PayloadTooLarge | UnsupportedMediaType Text | SimulationRejected | SimulationBusy | ServerShuttingDown | InternalError` with total `status`/`code`/`message` functions; `Allow` as a closed enum (`ProfileRoute | SimulationsRoute`).
- Parse, don't validate: `decodeRequest :: Json -> Either SimulationHttpError SimulationRequest` producing a typed `Marking` (sorted, non-empty queues by construction), `MaxActions`, and the expected-definition `Json`; the decision order stays exactly as upstream because the first error wins.
- `Origin` as a validated newtype from `validateOrigin`; `ServerConfig { allowedOrigin :: Origin, bounds :: SimulationBounds, connectionTimeout :: Microseconds }`.
- STM slot state `Idle | Running | ShuttingDown` makes the "busy vs shutting down" linearization one transaction; release with `bracket_`/`finally`, before the response write.
- Precompute `profileBytes` and the parsed definition once (upstream does too); `server.profile` copies are unnecessary with immutable values.
- Optional hardening (off by default, documented deviations): connection cap, total request deadline, IPv6 listen.
- Quirks to preserve: HTTP/1.0 status line, one request per connection, ACAO on 403, `Vary: Origin` everywhere, preflight headers only on 204/405, HEAD without body, Python-repr list text in `_exact_object` messages, hard-coded `"… 1 through 256"` message, lexical 413 before reading, 400 (not 411) for short bodies, 409 checked only after the marking/max_actions decode succeeds, 500 for unsafe-integer token data.

#### 8. Packaging

`petrus-simulation-http` (or `Petrus.Simulation.Http` in `petrus-simulation` behind a flag) depending on `petrus-simulation`, the shared HTTP core (`petrus-http`, also used by observation HTTP), `petrus-json`, `network`, `stm`, `async`/`ki`. It needs from the kernel only `NetPath` parsing, `Token`, `Marking`, and `BuiltNet`. The HTTP core, origin validator, request decoder, and error mapping can all be built and tested now against a stub `simulate`, in parallel with the Engine port; integration waits for `petrus-simulation`.

## 6. Engine

### Engine and Coordinator (`petrus.engine`, `petrus.engine._coordination`)

The Engine is the one live, motion-producing composition around exactly one durable `Instance`. It owns the
clock, the Dispatch, the whole-action driving loop (the private `Coordinator`), the joined-transaction commit
points, and the poison/close lifecycle. It holds **no durable state of its own**: every fact is a kernel History
record, every operational fence lives in the Dispatch provider, and the only engine-owned "durable" artifacts are
the writer fences (a POSIX `flock` file for SQLite, a session advisory lock for PostgreSQL) described in the next
component. Sources: `src/petrus/engine/__init__.py` (607 lines), `src/petrus/engine/_coordination.py` (904 lines).

#### 1. Responsibility & public API

**Public module surface** (`src/petrus/engine/__init__.py:587-607`, pinned by
`tests/petrus/engine/test_engine.py:112-135` and `tests/project/test_package_boundaries.py:361-390`):
`AcceptedDelivery` (re-export from kernel), `AcceptDelivery`, `AcceptResult`, `Action`, `AdvanceTime`,
`BeginCandidate`, `Clock`, `Delivery`, `DriveOutcome`, `DrivingPolicy`, `Engine`, `InFlightView`, `Sensor`,
`SimulatedClock`, `Snapshot`, `Stop`, `Wait`, `choose_conservative`, `choose_throughput`. `Coordinator` and
`Runner` are deliberately **not** exported; `_EngineResources` and `Engine._open` are the private provider seam.

**`Engine` public members** (exactly this set, `test_engine.py:84-110`):
`create`, `load`, `marking`, `status`, `in_flight`, `active_scopes`, `records`, `snapshot`, `net_document`,
`history_page`, `advance`, `wait`, `deliver`, `accept_delivery`, `complete_delivery`, `open_scope`,
`close_scope`, `reset_scope`, `seal`, `close`. No `queue_for`; no attribute exposes `coordinator`, `dispatch`,
`instance`, `history`, `resources` (`test_engine.py:664-667`). `Engine()` direct construction raises
`TypeError("Engine cannot be constructed directly; use Engine.create() or Engine.load()")` via a sentinel
(`__init__.py:55,138-139`).

```python
# src/petrus/engine/__init__.py
@classmethod
def create(cls, net: Net, instance: str, *, history: HistoryStore, dispatch: Dispatch,
           marking: Marking | None = None, at: Instant = 0, handlers=None, guards=None, filters=None,
           completions=None, policy: DrivingPolicy = choose_conservative,
           selection: SelectionPolicy = SelectionPipeline(), clock: Clock | None = None,
           sensor: Sensor | None = None, activities: Sequence[ActivityDeclaration] = (),
           default_heartbeat_timeout: int = 30) -> Engine            # :211-251
@classmethod
def load(cls, net, instance, *, history, dispatch, handlers=None, guards=None, filters=None,
         completions=None, policy=choose_conservative, selection=SelectionPipeline(), clock=None,
         sensor=None, activities=(), default_heartbeat_timeout=30) -> Engine   # :253-289 (no marking/at)
@classmethod
def _open(cls, ..., create: bool, ..., resources: _EngineResources = _EngineResources()) -> Engine  # :291-335

marking -> Marking            # deepcopy, allow_reentry        :337-340
status -> Status              # allow_reentry                   :342-345
in_flight -> tuple[FiringOccurrence, ...]   # deepcopy, begin order  :347-350
active_scopes -> Mapping[str, LifecycleScope]                   :352-355
records -> tuple[Record, ...]  # deepcopy of whole History      :357-360
snapshot() -> dict ; net_document() -> dict ; history_page(after: int, limit: int) -> dict   # :362-374 (observation protocol v1; section 5)
advance() -> DriveOutcome                                       # :376-378  (= _guarded(coordinator.drive))
wait(timeout: float) -> bool                                    # :380-386
deliver(source, tokens, *, identity: str, scope=None) -> FiringOutcome | PriorAcknowledgement | ScopedDeliveryAcknowledgement   # :388-406
accept_delivery(source, tokens, *, identity, scope=None) -> AcceptedDelivery | PriorAcknowledgement | ScopedDeliveryAcknowledgement  # :408-421
complete_delivery(accepted: AcceptedDelivery) -> FiringOutcome  # :439-447
open_scope(name: str) -> LifecycleScope                         # :465-473
close_scope(scope: LifecycleScope) -> ScopeClosure              # :475-487
reset_scope(scope: LifecycleScope) -> LifecycleScope            # :489-504
seal(source) -> None                                            # :516-523
close() -> None                                                 # :525-532
```

**Private resource seam** (`__init__.py:62-71`), the one hook every provider composition uses:

```python
@dataclass(frozen=True)
class _EngineResources:
    commit: Callable[[], None] | None = None   # None => backend-owned writes (already durable at append)
    rollback: Callable[[], None] = _nothing
    release: Callable[[], None] = _nothing     # writer fence release
    close: Callable[[], None] = _nothing       # connection/file close
    ensure: Callable[[], None] = _nothing      # pre-check on every door (SQLite fork check)
    wait: Callable[[float], bool] | None = None  # provider wake hint (Absurd LISTEN)
```

**Activity policy resolution** (`_ResolvedActivityHandler`, `__init__.py:74-99`): at construction every handler
that `hasattr(prepare) and hasattr(project)` is wrapped. `prepare(binding)` calls the user `prepare`, then
**always replaces** `invocation.policy.heartbeat_timeout` with the matching `ActivityDeclaration.heartbeat_timeout`
(by `invocation.activity` name) if non-None, else `default_heartbeat_timeout` (default 30). The resolved policy is
frozen into the `ActivityRequested` record (wire-visible; `test_engine.py:584-601` expects 7 from a declaration
over a default of 4). `project_failure` is forwarded if the wrapped handler has one, else `AttributeError`.
The wrapper exposes `.handler`; the Coordinator unwraps with `getattr(handler, "handler", handler)` to decide
whether failures are projectable. Validation: `default_heartbeat_timeout` must be a positive non-bool `int`;
declaration names must be unique (`ValueError`), `__init__.py:148-156`. Declarations are snapshotted into a dict at
construction (later mutation of the caller's list has no effect).

**Construction** (`__init__.py:115-209`):
1. `create=True`: refuse if `len(history) != 0` →
   `ValueError("cannot create Instance {instance!r}: canonical history already exists")`; else
   `Instance(net, marking, guards=, handlers=, filters=, completions=, history=, instance_id=instance, at=at)`
   (writes `InstanceCreated`, `TokensInitialized`, initial registrations…).
2. `create=False`: refuse if `len(history) == 0` → `"cannot load Instance {instance!r}: canonical history does
   not exist"`; else `Instance.resume(net, history, guards=, handlers=, filters=, completions=)`; then refuse if
   `instance_id != instance` → `"... canonical InstanceCreated identity is {id!r}; storage key and recorded
   identity must match exactly"`.
3. `clock = clock or SimulatedClock(at=instance.watermark)`.
4. `Coordinator(instance, dispatch, policy=, selection=, clock=, sensor=, commit=resources.commit)`.
5. `_committed()` — commit #1 (construction boundary).
6. On any `BaseException`: `resources.rollback()`, then `release()`, then `close()` (nested `finally`), mark
   closed, re-raise.

**Kernel APIs the Engine/Coordinator depend on** (all `petrus.impetus.*`):

| Kernel name | Used for |
| --- | --- |
| `instance.Instance(...)`, `Instance.resume(net, history, ...)` | create / load |
| `Instance.instance_id`, `.watermark`, `.history`, `.net`, `.marking`, `.status`, `.active_scopes` | observation, clock seed |
| `Instance.candidates()` | enabled bindings each turn (deterministic Petrinet order) |
| `Instance.begin(binding, at=)` → `FiringOccurrence` | `BeginCandidate` (appends `CandidateSelected`+begin batch, `ActivityRequested` if impure) |
| `Instance.bound_handler(transition)`, `Instance.net.outputs(transition)` | pure completion |
| `Instance._commit_completion(occ, result, at=)`, `_CompletionCommitRefused` | pure completion commit; refusal unwrapped |
| `Instance.fail(occ, error, at=)` | terminal failure (`FiringFailed`, plus `ActivityFailed` if not frozen) |
| `Instance.record_activity_completion(occ, result, at=)` / `record_activity_failure(occ, failure, at=)` | freeze (`ActivityCompleted`/`ActivityFailed`); also the ended-occurrence acknowledge/conflict/quarantine door |
| `Instance.complete(occ, at=)` | projection of a frozen result (or `project_failure`) |
| `Instance.in_flight`, `.projection_pending`, `.pending_activity_outcomes`, `.cancelled`, `.activity_occurrences` | reconcile & observe |
| `Instance.next_maturation`, `Instance.wake(at)` | timers (`TimerMatured`) |
| `Instance.armed` (`Mapping[NetPath, frozenset[str]]`) | sensor gating |
| `Instance.accept_delivery(source, tokens, at=, *, identity, scope)` / `complete_delivery(accepted, at=)` | identified ingress (2 phases) |
| `Instance.open_scope/close_scope/reset_scope(…, at=)`, `ScopeClosure`, `history.ScopeReset` | lifecycle scopes |
| `Instance.seal(source, at=)` | close default registration |
| `instance.AcceptedDelivery`, `PriorAcknowledgement`, `ScopedDeliveryAcknowledgement`, `FiringOutcome`, `FiringOccurrence`, `Status`, `DeliveryIdentity`, `_canonical_accepted_delivery`, `firing_failure_text` | value types |
| `history.FiringFailed`, `history.replay_cancellation_positions(history)` | delivery failure settlement; cancellation repair positions (1-based) |
| `selection.SelectionPipeline/SelectionPolicy/SelectionProposal/SelectionState/fold_history(selection, None, history)` | Transition Selection state (fold of committed `CandidateSelected` with matching `FiringBegun`) |
| `petrinet.Binding/Selection/Token/NetPath/Instant/Marking/Net`, `petrinet.schema.canonical_net_path` | values |
| `binding.ActivityHandler` (runtime-checkable: `prepare`+`project`), `FailureProjectingActivityHandler` | purity judgment |
| `observation.snapshot/net_document/history_page` | observation doors |
| `history_store.HistoryStore` protocol (`records`, `__len__`, `__iter__`, `append`, `extend`) | storage |
| `motus.activity.ActivityDeclaration/ActivityFailure/ActivityInvocation`, `motus.dispatch.Dispatch/CancellableDispatch/CancellationInstruction/CancellationDisposition` | execution seam |

**Coordinator vocabulary** (`_coordination.py`):

```python
@dataclass(frozen=True) class Delivery:          # :138-177
    source: NetPath; tokens: tuple[Token, ...]; identity: str; scope: LifecycleScope | str | None = None
type Sensor = Callable[[], Sequence[Delivery]]   # :190  nonblocking; [] declines
class Clock(Protocol):                           # :193-204
    def now(self) -> Instant: ...
    def observe(self, instant: Instant) -> Instant | None: ...   # None = still future; never < instant
class SimulatedClock:                            # :207-224  now() -> _now; observe(i): _now = max(_now, i); return _now
@dataclass(frozen=True) class AcceptResult:   occurrence: int; outcome: object        # :271-285
@dataclass(frozen=True) class AcceptDelivery: delivery: Delivery                        # :288-292
@dataclass(frozen=True) class BeginCandidate: binding: Binding; proposal: SelectionProposal  # :295-305
@dataclass(frozen=True) class AdvanceTime:    instant: Instant                          # :308-312
@dataclass(frozen=True) class Wait: ...                                                 # :315-317
@dataclass(frozen=True) class Stop: ...                                                 # :320-322
type Action = AcceptResult | AcceptDelivery | BeginCandidate | AdvanceTime | Wait | Stop # :328
@dataclass(frozen=True) class InFlightView:   occurrence: int; transition: NetPath; consumed: tuple[Selection, ...]; impure: bool  # :331-350
@dataclass(frozen=True) class Snapshot:       actions: tuple[Action, ...]; in_flight: tuple[InFlightView, ...]; previous: Action | None = None  # :353-370
type DrivingPolicy = Callable[[Snapshot], Action]                                       # :378
@dataclass(frozen=True) class DriveOutcome:   firings: tuple[FiringOutcome, ...]; waiting: bool; ready: bool = False; next_maturation: Instant | None = None  # :381-396
```

`Delivery.__post_init__` normalization/validation (`:160-177`): `source` → `canonical_net_path(source,
"delivery source")` (exact `NetPath` or built-in `str`; str subclasses refused: "delivery source must be an exact
NetPath or built-in string"); `tokens`: `str|bytes` refused (`ValueError "...tokens must be a Token or a sequence
of Tokens, found ..."`), a bare `Token` → 1-tuple, else `tuple(tokens)`; `identity`: a `DeliveryIdentity` is
converted to `str`, otherwise must be exact non-empty `str` (`ValueError`); `scope`: exact `LifecycleScope`, exact
`str`, or `None` (`TypeError`), a `str` scope must be non-empty and NUL-free (`ValueError`).

**Shipped policies**:
- `choose_conservative` (`:401-427`): (1) first `AcceptResult` in offer order; (2) the first `AcceptDelivery` if
  `previous` was not an `AcceptDelivery`; (3) if `Wait` offered: return the delivery if any else `Wait` (no
  second candidate begins while a result is outstanding); (4) first `BeginCandidate`, then first `AdvanceTime`;
  (5) the delivery; (6) `Stop`.
- `choose_throughput` (`:430-454`): (1) delivery if `previous` not a delivery; (2) first `BeginCandidate` none of
  whose consumed `(place, token)` pairs equals (by value) a pair consumed by any in-flight view; (3) first of
  `AcceptResult`, `AdvanceTime`, `AcceptDelivery`, `Wait`, `Stop` in that kind order.
- Both raise `ValueError("no available action: the coordinator always offers Stop")` if no `Stop`.

**Engine-facing extension points** (what other packages plug into):

| Hook | Contract as seen by the Engine |
| --- | --- |
| `Dispatch` (`motus/dispatch/__init__.py:178-184`, runtime-checkable) | `dispatch(occurrence: int, invocation: ActivityInvocation) -> None` — acknowledgement only; called from `BeginCandidate` (inside the joined transaction, before commit) and from reconcile (outbox republish of the *recorded* invocation, never re-`prepare`). Must tolerate re-dispatch of an occurrence it may already hold after restart (Absurd: idempotency key `"{instance}:occurrence-{id}"`). `collect() -> Sequence[tuple[int, object]]` — drains terminal outcomes in arrival order; outcome is the JSON-faithful result value or an `ActivityFailure`; called exactly once per `advance()` turn in `_observe`. |
| `CancellableDispatch` (`:187-191`, runtime-checkable `cancel`) | `cancel(CancellationInstruction(occurrence: int ≥1, invocation, history_position: int ≥1)) -> CancellationDisposition` (`"tombstoned"`, `"retired"`, `"fenced"`, `"terminal"`, `"acknowledged"`). Must be idempotent: identical instruction → `ACKNOWLEDGED`; different instruction for the same occurrence → `ValueError("cancellation conflict ...")`. After a cancel, a later `dispatch` of that occurrence with the identical invocation is a no-op. `history_position` is the 1-based History position of the `ScopeClosed`/`ScopeReset` record. |
| Provider wake hint (`_EngineResources.wait`) | `Callable[[float], bool]`; Absurd binds `AbsurdDispatch.wait_for_results`. Absent → `Engine.wait` does `time.sleep(timeout)` and returns `False`. |
| `ActivityHandler` (impetus.binding) | `prepare(binding) -> ActivityInvocation`, `project(binding, result)`, optional `project_failure(binding, failure)`; Engine wraps for heartbeat policy. |
| Pure `Handler` | `Callable[[Binding, tuple[Arc, ...]], Mapping[NetPath|str, Sequence[Token]] | HandlerResult]`, run inline at the writer. |
| `Sensor` | nonblocking local ingress; durable transports (fabric) must instead call `Engine.deliver`/`accept_delivery` themselves. |
| `Clock` | wall-clock adapters live outside the kernel; `observe` returning `None` makes `AdvanceTime` "not applied". |
| `DrivingPolicy` / `SelectionPolicy` | pure choosers; selection state installs only after the begin commit. |
| fabric `DeliveryDoor` (`fabric/ingress.py:18-21`) | structurally `Engine.deliver(source: str, tokens: tuple[Token, ...], *, identity: str) -> FiringOutcome | PriorAcknowledgement`. `FabricInbox.drain` delivers `Token("FabricEnvelope", envelope.to_data())` with `identity=envelope.ingress_identity`, then calls `client.acknowledge(sender, delivery_id, result.occurrence)` only after `deliver` returned (both durable phases done). |
| processes | no Engine hook: `SpawnActivity` (`processes/spawn.py:27-58`, activity `"process.spawn"`, idempotency `"process.spawn:{child_identity(parent, spawn_id)}"`) is an Activity implementation run by Workers behind a Dispatch; call/reply travel as fabric envelopes into `deliver`. |
| Other hosts | `petrus.simulation.simulate` (`simulation.py:295-335`: `Engine.create` + `advance()` loop with a forbidding Dispatch, `waiting` is an error) and `agenticus/runtime/agent_net_runner.py:417-650` (`Engine.create/load`, `advance`, `records`, `in_flight`, `marking`, `close`) use only public doors. |

**Canonical host loop** (README.md:64-68 and the spec's posture, `spec/firing-semantics.md:190-201`): call
`advance()`; if `ready` re-drive immediately; else if `waiting` call `engine.wait(timeout)` (or pump the in-memory
dispatch) and re-drive; else if `next_maturation is not None` schedule a wake at that instant; else idle (Stop at
quiescence / awaiting ingress). The Engine never sleeps inside `advance()`.

#### 2. Wire formats, durable schemas, protocols

The neutral Engine writes **no SQL and no files of its own**; everything durable goes through the kernel
History codec (schema 5 records via `HistoryStore.append/extend`). What it determines on the wire:

- **Record ordering and instants**: every record a door appends is stamped from `clock.now()` (or the observed
  instant for `TimerMatured`). `test_execution.py:376-389` (all firing records at clock 5), `:395-419` (float
  instant `0.5` survives create→accept→load→complete — keep `Instant` as a JSON int-or-float, never coerce).
- **Records per action** (in addition to those the kernel decides):
  - `BeginCandidate` (impure): `CandidateSelected`, `FiringBegun`, `TokensConsumed`, `TokensRead`,
    `ActivityRequested` (one `begin` batch). Pure: the same minus `ActivityRequested`, then the completion batch
    (`TokensProduced`…, `FiringCompleted`) or `FiringFailed`.
  - `AcceptResult` success: `ActivityCompleted` (own append, own commit), then `TokensProduced`…`FiringCompleted`.
    Failure: `ActivityFailed` (own append/commit), then `FiringFailed` (or projection via `project_failure`).
  - `AcceptDelivery`/`deliver`: `ExternalEventDelivered(source, tokens, identity=, occurrence=)` +
    `FiringBegun(source, occurrence=)` (acceptance cut), then `TokensProduced` + `FiringCompleted` (or
    `FiringFailed`) — `test_execution.py:421-439`, `:3485-3512`. Exact redelivery appends nothing
    (`:3558-3578`: 64 redeliveries cost 0 records; whole delivery = 4 records).
  - `AdvanceTime`: `TimerMatured(maturation_instant=m, instant=observed)` (late observation records the late
    instant, `test_execution.py:3634-3668`).
  - Late terminal for a scope-cancelled occurrence: `ActivityTerminalQuarantined` (appended from `_observe`).
  - `close_scope` → `ScopeClosed(scope, discarded, cancelled, instant)`; `reset_scope` → one `ScopeReset`
    record (`closed`, `discarded`, `cancelled`, `opened`), no gap generation (`test_engine.py:381-394`).
- **`FiringFailed.error` text** for a raising pure handler / projection is `firing_failure_text(error)`:
  `f"{type(error).__name__}({', '.join(argument_text)})"` truncated to 4096 chars, never calling `repr` of the
  exception; object arguments become a stable type marker (`test_execution.py:3015-3104`, e.g.
  `FiringFailed(SRC, "ProjectionError()", occurrence=1)`, `"RuntimeError('projection failed')"`). For an
  activity failure the text is `ActivityFailure.error`. **Interop note**: these strings are durable and Python
  `repr`-shaped; a Haskell writer cannot reproduce Python exception names for its own exceptions, so only the
  `ActivityFailure` path is cross-language comparable (exact-duplicate verification of failures compares these).
- **`CancellationInstruction.history_position`** = `len(history)` immediately after the close/reset append, i.e.
  the 1-based position of that record; on reload recomputed by `replay_cancellation_positions` (identical value).
  Absurd persists it in its tombstone, so it must match across languages.
- **Absurd LISTEN/NOTIFY** (Engine-side consumer only; the Absurd adapter is in section 7):
  channel `impetus_dispatch` (authority→workers, `SELECT pg_notify(%s, %s)` with payload = queue name, sent inside
  the spawning/joined transaction, `motus/dispatch/absurd.py:94-99,719`) and channel `impetus_results`
  (workers→authority, payload = queue, after the worker's terminal commit). `wait_for_results(timeout)`
  (`absurd.py:953-981`): on first call executes `LISTEN impetus_results` on the dedicated autocommit `listen`
  connection; loop: probe → if ready return `True`; if deadline passed return `False`; else wait for one
  notification for `min(poll_interval, remaining)` (default `poll_interval=0.25`), then re-probe. Probe SQL
  (`absurd.py:983-996`, on `listen`), per queue with `sql.Identifier(f"t_{queue}")`:
  `SELECT 1 FROM absurd.{t_queue} WHERE task_id = ANY(%s::uuid[]) AND state IN ('completed', 'failed', 'cancelled') LIMIT 1`.
- **Telemetry** (operational, not durable; ES-020): logger `"impetus"` bound with `instance=<id>` and
  `net=<net.name>` (`_coordination.py:103-113`); span `"drive"` per `advance()` with fields `reconciled_firings`
  (first turn), `firings`, `waiting`, `ready`, counter `actions`, accumulators `observe_ms`, `apply_ms`,
  `begin_ms`, `handler_ms`, `commit_ms`; events `"gauges"` (`history_records`, `places_occupied`,
  `tokens_total`, `in_flight`, `current_rss_mb`, `max_rss_mb`; only at level `profile`, `:116-135,593-594`),
  `"candidate_selection_declined"` (`enabled=n`, `:693`), `"activity_cancelled"` (`occurrence`,
  `history_position`, `disposition`, `:883-888`).
- **Specs to honor**: `spec/firing-semantics.md:145-201` (selection vs DrivingPolicy, one action per turn,
  `ready/waiting/next_maturation`, re-offer without immature wall-clock action), `spec/event-history.md:160-190`
  (close/reset commit before cancellation visible; first terminal wins; quarantine), `spec/OVERVIEW.md:110-118`
  (single writer, coordination private), `spec/handler-contract.md` (activity/projection split),
  `spec/observation-protocol-v1.md` (snapshot/history_page doors; HTTP maps closed/poisoned `RuntimeError` to 503).

#### 3. Concurrency & durability semantics

**Threading model.** One deterministic loop, never threads (`_coordination.py:14-27`). The Engine guards every
door with a re-entrant `threading.RLock` monitor (`__init__.py:142`):
- `_guarded(door)` (writing doors: `advance`, `deliver`, `accept_delivery`, `complete_delivery`, `open_scope`,
  `close_scope`, `reset_scope`, `seal`), `:547-562`: take monitor → refuse re-entry → `_ensure_open()` → record
  `_write_thread = get_ident()` → run. On **any** `BaseException`: `_broken = firing_failure_text(error)`,
  `resources.rollback()`, then `_close_resources()` (`release()` then `close()`, once), re-raise. Always clears
  `_write_thread`.
- `_read(op, allow_reentry=False)` (`:564-569`): monitor → (refuse re-entry unless allowed) → `_ensure_open()` →
  op. `marking`, `status`, `in_flight`, `active_scopes`, `records`, and the `wait` resource lookup allow
  re-entry (a handler running inside a writing door may read them on the same thread); `snapshot`,
  `net_document`, `history_page` refuse re-entry. Re-entry error:
  `RuntimeError("public Engine operation cannot re-enter while a writing door is active")`.
- `_ensure_open()` (`:575-584`): first `resources.ensure()` (SQLite fork check), then poisoned →
  `RuntimeError("this Engine is poisoned after a writing door failed ({text}): History, Instance, Dispatch, and
  the advancement lane may have advanced together — continue through a fresh Engine.load or provider load
  function")`; closed → `RuntimeError("this Engine is closed; create or load a new Engine before observing or
  driving")`.
- `close()` (`:525-541`): monitor, refuse re-entry, idempotent; `release()` then `close()`; does not change
  semantic status and does not call `ensure`.
- `wait(timeout)` (`:380-386`): looks up `resources.wait` under the monitor, then **calls it outside the monitor
  and unguarded** (a failing wait does not poison).

**Poisoning.** Every writing-door exception poisons the whole composition (History mirror, Instance, Coordinator
buffers, selection state, Dispatch session). The only coherent continuation is a fresh `load` over committed
History (`test_engine.py:633-661`; Postgres `test_postgres_engine.py:415-436`; SQLite `test_sqlite_engine.py:53-60`).
Poison releases the writer fence and closes the connection(s) immediately (`connection.closed` asserted).

**Commit points** (`Engine._committed` / `Coordinator._committed`, no-ops when `commit is None`, i.e. for
backend-owned stores where each append is already durable; with a joined PostgreSQL connection each is
`connection.commit()`):

| Door / action | Sequence (C = commit point) |
| --- | --- |
| construction | `Instance(...)` or `Instance.resume` → Coordinator ctor → **C** |
| `advance()` first call | reconcile legs → **C** (then the normal turn below) |
| observe | `dispatch.collect()`; late outcomes for ended occurrences → `record_activity_completion/failure` (ack, conflict raise, or `ActivityTerminalQuarantined` append); candidates; selection propose; maturation; sensor |
| `Wait`/`Stop` chosen | **C** (closes the observation's read txn; nothing idles in transaction across a Wait) → return |
| `AcceptResult` ok | unbuffer arrival → `record_activity_completion` → **C** (freeze survives projection crash) → `complete` → post-action **C** |
| `AcceptResult` failure | `record_activity_failure` → **C** → `complete` (if `project_failure`) else `fail` → **C** → raise `RuntimeError("activity for firing occurrence {id} ({transition}) failed terminally: {error}")` unless projected |
| `AcceptDelivery` | remove buffered parcel (by object identity) → `accept_delivery` → **C** iff History grew → `complete_delivery` (on exception: if exactly one new record and it is `FiringFailed` for that occurrence → **C**; re-raise) → post-action **C** iff History grew since `before_action` |
| `BeginCandidate` | `begin` → (backend-owned: install selection now) → pure: `_complete_pure` (handler, `_commit_completion`; on failure `fail` + **C** + raise) / impure: `dispatch.dispatch` → post-action **C** → (joined: install selection only after this commit returned) |
| `AdvanceTime` | `clock.observe(m)`; `None` → not applied (re-offer); `< m` → `ValueError("clock observed {o}, before the requested maturation {m}: ...")`; else `wake(observed)` → post-action **C** |
| `deliver` | accept (→ **C** iff grew) → complete (failure-settlement **C**) → **C** |
| `accept_delivery` | accept → **C** iff grew (exact redelivery commits nothing: `test_postgres_engine.py:134-181`) |
| `complete_delivery` | `_canonical_accepted_delivery` → `complete_delivery` → **C**; on exception, `FiringFailed` settlement **C** then raise |
| `open_scope`, `seal` | kernel door → **C** |
| `close_scope` / `reset_scope` | refuse if an in-flight Activity in that scope and Dispatch lacks `cancel` (`TypeError`, before any append) → kernel close/reset → `history_position = len(history)` → **C** (canonical close visible first) → `coordinator.cancel(closure, history_position)` → **C** (joined providers publish fences) |

The joined-boundary numbering is pinned by `test_engine.py:744-870`: commit 1 = construction, 2 = reconcile,
3 = begin; after a completion arrives, 4 = freeze, 5 = projection. A refused commit 3 leaves no
`CandidateSelected` and selection state `None`; a refused commit 5 keeps the frozen `ActivityCompleted`, and a
fresh load completes by projection alone.

**Ordering guarantees.** Results commit in Dispatch arrival order (`collect` order; buffered arrivals are
re-offered until chosen); sensed deliveries are FIFO, and a parcel whose source is no longer `armed` blocks
itself and everything behind it (not offered, not dropped; `_observe :717-723`,
`test_coordinator.py:919-955`). The sensor is consulted only when the delivery buffer is empty, a sensor exists,
and `instance.armed` is non-empty; `None` → `ValueError("sensor returned None: ...")`; non-exact `Delivery` items
→ `TypeError("sensor must return exact Delivery values")`; the answer is snapshotted with `tuple()`. Offer order
in a Snapshot: `AcceptResult…` (arrival order), at most one `BeginCandidate` (selection proposal; a proposal
outside the enabled set or with a stale `prior_state` is a `ValueError`), `AdvanceTime(next_maturation)`,
`AcceptDelivery…` (FIFO), `Wait` (iff an impure in-flight occurrence is neither arrived nor projection-pending),
`Stop` (always).

**One action per turn** (`drive`, `_coordination.py:543-596`): the policy result must be in
`snapshot.actions` (`ValueError("the policy chose an action the coordinator did not offer: ...")`). If an
`AdvanceTime` is not applied (wall clock not due), the policy is asked again with that action removed (same
`previous`), so a future timer can never hide buffered ingress (`test_coordinator.py:403-449`). Returns
`DriveOutcome(firings, waiting=False, ready=True, next_maturation)` after an applied action;
`DriveOutcome(firings, waiting=isinstance(Wait), ready=False, next_maturation)` on Wait/Stop. `firings`
includes reconciled completions. `previous` is updated only after an applied action.

**Selection durability.** `selection_state = fold_history(selection, None, history)` at construction. Backend-owned
store: install the proposal's `next_state` immediately after `begin` returns (begin is durable even if dispatch
or pure completion later fails, matching replay; `test_coordinator.py:584-634`). Joined store: install only after
the post-action commit returns. `_install_selection` raises `RuntimeError` if the live state no longer equals
`proposal.prior_state`. Selection is not invoked with an empty enabled set; filters admitting none → no action,
no History, event `candidate_selection_declined`. A shared `SelectionPolicy` value is isolated per Engine.

**Idempotent identified delivery.** Identity is mandatory (`TypeError` if omitted, `ValueError("delivery
requires a stable delivery identity")` for `None`). Exact redelivery of an unfinished acceptance reconstructs an
equal `AcceptedDelivery` (no append); after the occurrence ended, `PriorAcknowledgement(identity, occurrence)`;
reused identity with different source/content/scope → `ValueError` conflict before mutation (JSON scalar types
distinguished: `True` vs `1`, `1` vs `1.0`, `test_execution.py:2689-2704,3821-3850`). A sensor may redeliver the
identity of an acceptance made by a previous process; the resumed Engine completes it rather than re-accepting.

**Crash recovery sequence** (Engine.load + first `advance()`):
1. Provider acquires the writer fence **before** loading History (SQLite flock / PG advisory lock).
2. History store loads all rows for the instance; `Instance.resume` replays (refusing torn/forged prefixes — the 47
   `test_load_refuses_*` cases in `test_execution.py`).
3. Coordinator ctor: `selection_state = fold_history(...)`; `_dispatched = dict(instance.activity_occurrences)`
   (every Activity occurrence, ended included, so late redeliveries resolve); refuse load with
   `TypeError("cannot load lifecycle-cancelled Activities with this Dispatch: ...")` if any cancelled occurrence
   has an invocation and Dispatch lacks `cancel`.
4. Construction commit.
5. First `advance()` sets `_reconciled = True` **before** reconciling (never re-run in-process; a failure is
   "fix the code, resume fresh"), then `_reconcile` (`:598-642`), each leg over the resumed in-flight set in
   begin order:
   a. **Cancellation repair** (`:644-649`): for each `instance.cancelled` occurrence with an invocation,
      `dispatch.cancel(CancellationInstruction(id, invocation, positions[id]))` (idempotent →
      `ACKNOWLEDGED`); emits `activity_cancelled`.
   b. **Outbox republish**: each in-flight occurrence with an invocation and no frozen result →
      `dispatch.dispatch(id, occurrence.invocation)` (recorded invocation; `prepare` never re-runs;
      `test_coordinator.py:959-999`).
   c. **Projection-pending**: frozen `ActivityFailure` with no `project_failure` → `fail` + **C** + raise
      `RuntimeError(...failed terminally...)`; else `complete` by projection alone (Dispatch not consulted;
      `:1001-1037`).
   d. **Pure in-flight** (incl. accepted-but-uncompleted source deliveries): `_complete_pure` re-runs the pure
      handler over the recorded binding (`:1039-1071`).
6. **C**, then the normal observe→choose→apply turn.
7. Late Dispatch reports after restart: identical result for an ended occurrence → acknowledged silently (no
   append, loop continues); different → `ValueError("... different result ... operational conflict")`; for a
   scope-cancelled occurrence → `ActivityTerminalQuarantined` once, identical repeat acknowledged, different →
   `ValueError("conflicting terminal activity report")`; for an occurrence never dispatched by this coordinator
   (and not in `activity_occurrences`) → `ValueError("the Dispatch completed occurrence {id}, which is not in
   flight: ...")` (`test_engine.py:302-379`, `test_coordinator.py:681-764`).
8. Direct `complete_delivery` after load targets only the named source occurrence: it neither reconciles nor
   advances unrelated work (`test_execution.py:2388-2455`); the reconcile happens on the first `advance()`.

**Terminal failure policy**: stop-on-terminal-failure; the failure is committed before the raise, the Engine is
then poisoned, and in-flight siblings remain durable for the next load. A projection failure after a frozen result
is never converted into a failed firing (the occurrence stays projection-pending).

**Timeouts/retries**: none inside the Engine. Activity retries/heartbeats belong to Dispatch/Workers (policy
frozen in `ActivityRequested`); `wait` is bounded by its caller's timeout.

#### 4. External dependencies

The neutral Engine uses only the standard library (`threading`, `time`, `copy.deepcopy`, `dataclasses`) and
`petrus.telemetry`. Haskell mapping:

| Python | Haskell suggestion |
| --- | --- |
| `threading.RLock` + thread-id re-entry check | `MVar ()` (or `TMVar`) monitor + `IORef (Maybe ThreadId)` writer marker (`myThreadId`); allow-reentry reads skip the lock when the current thread is the writer. `base`/`stm`. |
| `time.sleep` in `wait` | `threadDelay` (bounded); provider hint via `stm` `registerDelay` + TVar doorbell |
| `deepcopy` detachment | unnecessary (immutable values); detached views are free |
| `petrus.telemetry` spans/events | `petrus-telemetry` (section 10: a JSON-line logger, not OpenTelemetry); keep event/field names |
| exceptions as control | `Control.Exception` (`mask`, `onException`, `try`); poisoning wraps `SomeException` |

#### 5. Upstream tests

All in `tests/petrus/engine/`, run with plain pytest (`--randomly-seed=1729` addopts, 180 s timeout); no markers;
**no Docker needed except `test_postgres_engine.py`**. No `conftest.py` under `tests/`; the root
`conftest.py` provides `postgres_dsn` (session Docker container `postgres:17.5-alpine@sha256:6567bca8…`, tmpfs,
fails loud without Docker), `absurd_dsn`, `pg_connection` (autocommit + `ensure_schema`). `tests/harness.py` is the
golden-trace replay helper (`spec/traces/*.json`, format `petrus-impetus-golden-trace` v2) used by
`impetus/petrinet/test_golden_replay.py` and `test_passthrough_chain.py`; it drives the kernel `Instance` directly
(step / accept+complete delivery / seal) and is relevant to the Engine only as the record-for-record oracle for
delivery semantics.

| File | Fns | Theme groups (counts) |
| --- | --- | --- |
| `test_engine.py` | 28 (2 parametrized: policy ×2, close/reset ×2) | Neutral surface 14: exact public member set & module `__all__`, no direct ctor; `create(at=)` vs load-derived instant; create→advance→close→load preserves History and never re-prepares/re-projects; one whole action per `advance()` (begin, then complete, then stop); future wall-clock time never hides buffered ingress; identifier delivery then separate fetch activity; create/load/identity preconditions refuse without mutation; Activity heartbeat policy resolved by Engine from declarations; `wait(0)` bounded without provider; two Engines isolated; writing failure poisons all doors (`fresh Engine.load`) and fresh load recovers; close idempotent, no collaborator handles. Lifecycle scopes 9: close commits before retiring pending Dispatch and late terminal is quarantined (`history_position` = 1-based close position); restart acknowledges exact ended redelivery / refuses conflict; quarantined redelivery ack/conflict; reset is one record; restart repairs committed cancellation idempotently; post-commit cancellation failure poisons and restart repairs (close/reset); close append failure never notifies Dispatch; non-cancellable Dispatch refused before canonical close; sensor preserves scope provenance. Joined-transaction fate 5 (hermetic `_TransactionalHistory` with commit/rollback counters): commit refusal rolls back and never installs selection; dispatch failure rolls back uncommitted begin and releases; selection installs only after begin commit; freeze commit survives projection-boundary commit failure; projection failure keeps frozen terminal, fresh load retries projection only. |
| `test_coordinator.py` | 42 (2 parametrized ×2) | InMemoryDispatch 5 & InlineDispatch 2 (pool semantics, completion order, failure classification). Policy units 8 (conservative: result first, one candidate while waiting, ingress interrupts once, wait doesn't block buffered ingress; throughput: begins independent work first, skips value-aliased collision, ingress precedence, forced aliased twin fails `stale selection`). One-action drive 3 (exact `DriveOutcome` values; future wall-clock maturation returns `ready=False,next_maturation=5`, later `TimerMatured(5, instant=7)`; timer cannot hide ingress). Concurrency 2 (out-of-order completion commits in arrival order; terminal failure records `ActivityFailed`+`FiringFailed` and halts). Selection durability 12 (no enabled → selection not called; RoundRobin recorded before dispatch; orphan `CandidateSelected` ignored on resume; backend-owned dispatch/pure failure leaves durable selection installed; refused append leaves no selection; Stop discards proposal; shared policy isolated; all-filtered no History; never-dispatched completion refused; non-offered action refused; policies see detached `InFlightView`s). Late completions 2 (identical ack continues, different conflicts). Parity 1 (same History under equivalent selections). Sensed ingress 4 (FIFO; redelivery ack; ingress/internal alternation `[SRC, spin, SRC, spin, SRC]`; parcel behind source close held). Reconcile 3 (outbox redispatch without prepare; projection-pending by projection alone; pure in-flight completed then drive continues) — use `JsonlHistoryStore` under `tmp_path`. |
| `test_execution.py` | 134 (several parametrized: fact_kind ×3, route ×3 × arguments ×2, etc.) | SimulatedClock 2. Engine drives the seam 11 (typed-place/initial-token validation before History write; opaque token data detach; pure chain to quiescence; activity via InlineDispatch; scalar-subclass refusals; noncanonical activity input refused on load before dispatch; pure projection never touches Dispatch; records stamped from clock). Identified delivery phases 97: two-phase accept/complete semantics & durability (~15: float instant, accept begins without completing, returned identity composes, visible from reopened store, hostile completion-store refusal leaves acceptance unfinished, identity required, completion targets only accepted occurrence, fresh completion does not reconcile, fresh-engine reconstruction, process interruption via `subprocess` `os._exit(23)` then resume, finite redelivery cost); 47 `test_load_refuses_*` (torn batches, forged/orphan registrations, foreign activity facts, boolean occurrences, disordered/interleaved/split completion batches, scope violations — exercising `Instance.resume` through `Engine.load`); 12 completion/carrier refusals (foreign/mismatched/mutated/subclass `AcceptedDelivery`, impure non-source); ~23 identity/content/aliasing/subclass/projection-failure-text cases. Timers 4 (simulated maturation, repeated delays anchor on production, `Until`, late observation harmless / early observation `ValueError`). Terminal failure 1 (pure handler failure records `FiringFailed` and poisons). Delivery value 5. Sensing 11 (subclass refusals, interleave with internal work, redelivery ack once, later-equal selection keeps earlier conflict, redeliver prior identity after load, decline returns control & sealed Engine never consults sensor, COMPLETED status does not disable armed sensor, ingress interrupts pending timer once, sensed == direct records, source projection failure poisons). Broken sensor 3 (`None`, generator snapshotted, raising sensor appends nothing and poisons). |
| `test_postgres_engine.py` | 12 (fault ×2) | **Docker Postgres required** (`postgres_dsn`, `pg_connection`). Sensed and direct projection failure commit `FiringFailed` and reload acknowledges `PriorAcknowledgement("event-7", 1)`; exact redelivery (direct and sensed) commits no empty joined transaction (commit counter); failure-settlement commit fault: `refused` → acceptance unfinished and reload completes / `acknowledgement-lost` → `FiringFailed` durable and reload acknowledges; joined completion commit refusal leaves acceptance for exact retry; create/load/idempotent close own and close the connection; autocommit or invalid kwargs close the supplied connection; create/load preconditions close without changing History; held fence refuses second writer before History load and closes it; missing schema (`DROP SCHEMA impetus CASCADE`) releases fence and allows retry; writing-door poison releases fence for fresh load. |
| `test_sqlite_engine.py` | 5 | Local only (tmp_path). Fence refuses same db+instance and releases on close (lock file exists in `.impetus-sqlite-locks`); authority scoped by (database, instance); poison releases resources; `multiprocessing` **spawn** contention + holder death (`terminate`) releases; **fork** (skipif no fork): child inheriting the Engine gets `RuntimeError("...inherited across fork...")` and does not retain the fence. |

Cross-coverage: `petrus.engine.absurd` has no dedicated unit file; it is exercised by `tests/dst/joined_*world.py`
(DST joined worlds, `test_joined_world.py` 67 fns etc.) and `tests/petrus/motus/worker/test_worker_topology.py`
(Docker + Absurd schema). `test_simulation*.py`, `test_observation*.py` (engine dir) belong to section 5.

#### 6. Performance

Hot paths per `advance()` turn: `dispatch.collect()`; `instance.candidates()` (full enabled enumeration every
turn, the dominant cost); `selection.propose`; `instance.next_maturation` (re-derived); `in_flight` scan to build
`InFlightView`s and the `outstanding` flag; `instance.armed`; one kernel door + commit; telemetry span timing.
Python overheads the port removes: `deepcopy` in `marking`/`in_flight`/`records` (`records` copies the whole
History — O(n) per call, O(n²) for hosts polling it), dataclass equality in `action not in snapshot.actions`,
list-index buffer removals.

Benchmark proposal (same net JSON via net-definition v3, same seed, `SimulatedClock(at=0)`, identical policies;
equivalence check = byte-identical `encode_record` JSONL of the final History):
1. **Pure chain**: line net of K∈{10,100} transitions, M∈{1,100,1000} tokens, `InMemoryHistoryStore`,
   `InlineDispatch({})`; measure turns/s and total time to rest.
2. **Activity round-trip**: N∈{100,10k} independent activity candidates, `InMemoryDispatch`, conservative and
   throughput policies, pump completions; measure begin+accept per second and per-turn latency p50/p99.
3. **Ingress**: sensor burst of N deliveries (unique identities) + 64× exact redelivery each; measure
   acceptances/s and redelivery cost.
4. **Timers**: chain with `Delay` maturations, simulated clock; turns/s.
5. **Durable**: SQLite fenced Engine (WAL, `synchronous=FULL` → fsync-bound; report commits/action and µs/action)
   and Postgres joined Engine against the pinned Docker image (count commits per action — must match Python's
   boundary counts exactly — and latency).
6. **Recovery**: load + first `advance()` over histories of 10k/100k records with K in-flight occurrences.
Report RSS too (Python's `gauges` event exposes comparable numbers).

#### 7. Better-the-Haskell-way suggestions

- **Lifecycle as a type**: `data EngineState = Open | Poisoned Text | Closed` in an `IORef`/`MVar`; writing doors
  `withWritingDoor :: Engine -> IO a -> IO a` doing `mask`+`onException` (rollback, release, close) — replaces the
  `try/finally` ladder and the provider `transferred` flags.
- **Resources record**: `data EngineResources = EngineResources { commit :: Maybe (IO ()), rollback, release,
  close, ensure :: IO (), waitHint :: Maybe (Double -> IO Bool) }`. Better: `data TxMode = BackendOwned |
  Joined (IO ())`, because selection install timing and "commit iff grew" depend on it.
- **Actions**: `data Action = AcceptResult OccurrenceId Outcome | AcceptDelivery Delivery | BeginCandidate Binding
  SelectionProposal | AdvanceTime Instant | Wait | Stop`. Make "policy chose an un-offered action"
  unrepresentable by having `Snapshot` carry opaque `Offered` handles (index into the offer list) that the policy
  returns; keep a raw `Action` entry point with the equality check for parity tests. Remove buffered deliveries by
  offer index, not by value — Python removes by object identity, and Haskell value equality would conflate two
  equal-by-value parcels (and must not conflate `True`/`1`/`1.0`, which Python's `==` does).
- **Sensor** `:: IO [Delivery]` (the `None`, generator and subclass refusals become type-enforced; record in PARITY).
  `Delivery` via smart constructor (`mkDelivery`) enforcing the `__post_init__` rules.
- **Clock** as a record `{ now :: IO Instant, observe :: Instant -> IO (Maybe Instant) }`; `Instant` must remain a
  JSON number preserving int vs float (`0.5` round-trips; `10` stays integral).
- **Policies are pure** `Snapshot -> Action`; handlers ideally pure too, which makes the re-entry check mostly
  moot (still keep the runtime check for IO handlers that capture the Engine).
- **STM wait**: provider wake via a `TVar Bool` doorbell set by a LISTEN thread plus `registerDelay` for the
  poll tick; `wait` stays outside the monitor and unguarded (preserve: a failing wait does not poison).
- **Streaming** `records`: expose a `Seq Record`/vector snapshot without copying; `history_page` can slice.
- **Quirks to preserve for interop/behavioral parity**:
  - Engine **overwrites** every Activity's `heartbeat_timeout` (declaration or default 30) before
    `ActivityRequested` is recorded.
  - Freeze and projection are separate commits; `ActivityFailed` and `FiringFailed` are separate appends on the
    coordinator path (crash between them is handled by reconcile leg c).
  - `history_position` is 1-based.
  - Exact redelivery never issues an empty commit (Postgres tests count commits).
  - Reconcile is attempted once per Engine; its flag is set before work.
  - Observe-time appends (`ActivityTerminalQuarantined`) are not committed in the same turn if the chosen action is
    an exact-redelivery `AcceptDelivery` (the post-action gate compares against `before_action` measured after
    observe); they ride the next commit point. Harmless but observable via commit counts — keep, or fix
    consciously and note in PARITY.
  - `FiringFailed.error` uses `firing_failure_text` (Python-repr-shaped, 4096-char cap) — reproduce the format
    for Haskell exceptions as `Name(args)` but accept that strings differ across languages.

#### 8. Packaging

Suggested package **`petrus-engine`** (modules `Petrus.Engine`, `Petrus.Engine.Coordination` (internal),
`Petrus.Engine.Policy`, `Petrus.Engine.Clock`). Depends on `petrus-impetus` (Instance, History, records,
selection, scope, observation, memory/JSONL stores), `petrus-motus` core (`ActivityInvocation`,
`ActivityFailure`, `ActivityDeclaration`, `Dispatch`/`CancellableDispatch` classes or records,
`CancellationInstruction`, `CancellationDisposition`), and the telemetry package. Needs from the kernel exactly the
`Instance` door set listed in §1 (including the "private" ones: `_commit_completion` with a distinguishable
commit-refused error, `_canonical_accepted_delivery`, `firing_failure_text`, `replay_cancellation_positions`,
`fold_history`). Can be built in parallel with the History-store backends and Absurd Dispatch once the
`Dispatch` interface and `InMemoryDispatch`/`InlineDispatch` exist (they are needed for nearly every test). The
provider doors (next component) can live in the same package behind cabal flags or in
`petrus-engine-sqlite`/`petrus-engine-postgres` to keep `postgresql-libpq` optional (mirrors Python extras
`postgres`/`absurd`).

### Engine provider compositions and writer fences (`petrus.engine.sqlite`, `.postgres`, `._postgres`, `.absurd`)

Construction doors that compose a durable History store (and for Absurd, the Dispatch) with the neutral Engine,
acquire a **single-writer fence before loading History**, and hand transaction/hosting fate to the Engine through
`_EngineResources`. Each returns the plain `Engine` type (`test_package_boundaries.py:192-197,426-432`).

#### 1. Responsibility & public API

```python
# src/petrus/engine/sqlite.py:29-36
def create_engine(path, net, instance: str, *, dispatch, **options) -> Engine
def load_engine(path, net, instance: str, *, dispatch, **options) -> Engine
# src/petrus/engine/postgres.py:57-64   (connection must be autocommit=False)
def create_engine(connection, net, instance: str, *, dispatch, **options) -> Engine
def load_engine(connection, net, instance: str, *, dispatch, **options) -> Engine
# src/petrus/engine/absurd.py:108-115   (joined autocommit=False connection + dedicated autocommit listen)
def create_engine(connection, net: Net, instance: str, *, listen, **options) -> Engine
def load_engine(connection, net: Net, instance: str, *, listen, **options) -> Engine
#   options additionally: poll_interval: float = 0.25, default_queue: str = "default",
#   activity_queues: Mapping[str, str] | None = None   (absurd.py:61-72); `dispatch` is built internally
# src/petrus/engine/_postgres.py:36-62 (private)
class PostgresAuthorityFence:
    def __init__(self, connection, instance: str)   # raises RuntimeError if held
    def close(self) -> None                          # idempotent
    __enter__/__exit__
# src/petrus/impetus/history_store/sqlite.py:74-138 (private, used by engine.sqlite)
class _WriterFence:
    def __init__(self, path, instance: str); def ensure(self) -> None; def close(self) -> None
```

`**options` are forwarded verbatim to `Engine._open` (so unknown keys raise `TypeError("... unexpected keyword
argument 'unknown_option'")` — after the connection was handed over, which is then closed;
`test_postgres_engine.py:322-339`).

**Resource wiring** (the Engine-facing hook):

| Provider | `commit` | `rollback` | `release` | `close` | `ensure` | `wait` |
| --- | --- | --- | --- | --- | --- | --- |
| SQLite (`sqlite.py:16`) | `None` (backend-owned `BEGIN IMMEDIATE` per append) | no-op | `fence.close` | `history.close` | `fence.ensure` (fork check) | `None` |
| Postgres (`postgres.py:37-42`) | `connection.commit` | rollback, swallowing `psycopg.Error` | `fence.close()` then rollback | `connection.close` | no-op | `None` |
| Absurd (`absurd.py:87-93`) | `connection.commit` | same | same | `listen.close()` then `connection.close()` | no-op | `dispatch.wait_for_results` |

Kernel/other APIs used: `SqliteHistoryStore(path, instance)`, `PostgresHistoryStore(connection, instance)`
(join mode when `connection.autocommit` is False), `AbsurdDispatch(connection, instance=, listen=, poll_interval=,
default_queue=, activity_queues=)`, `Engine._open(..., resources=)`.

#### 2. Wire formats, durable schemas, protocols

**PostgreSQL writer fence** (`_postgres.py:29-56`) — must be bit-identical so Python and Haskell writers exclude
each other on the same database:

```python
def _fence_key(instance: str) -> int:
    if not isinstance(instance, str) or not instance:
        raise ValueError(f"authority fence requires a non-empty string instance id, got {instance!r}")
    digest = hashlib.sha256(b"impetus-authority\0" + instance.encode()).digest()[:8]
    return int.from_bytes(digest, byteorder="big", signed=True)
```

i.e. key = first 8 bytes of `SHA-256("impetus-authority" ‖ 0x00 ‖ UTF-8(instance))` as a big-endian **signed**
int64 (single-argument bigint advisory-lock key space). Test vectors (computed with the above):

| instance | first 8 bytes (hex) | key (int64) |
| --- | --- | --- |
| `demo` | `7ddaf43b4eecc747` | `9068829335228303175` |
| `pg-only-x` | `0e3f418d1e22693e` | `1026611314415528254` |
| `é` | `86952f3cc96a13cd` | `-8749034762973604915` |

SQL statements, verbatim:

```sql
SELECT pg_try_advisory_lock(%s)      -- acquire (session-level); false => RuntimeError
SELECT pg_advisory_unlock(%s)        -- release; psycopg.Error swallowed (dead connection already released it)
```

Refusal text: `RuntimeError(f"authority fence for instance {instance!r} is already held: refusing a second
canonical writer")`. The same key/fence is used by both the Postgres and the Absurd compositions, so they are
mutually exclusive per instance.

**History SQL used by these doors** (owned by section 4; listed so the composition is complete):
- Postgres load: `SELECT event_id, payload FROM impetus.semantic_events WHERE net_instance_id = %s ORDER BY
  sequence`; `UndefinedTable` → `ValueError("impetus.semantic_events does not exist ... ensure_schema(connection)
  — a deliberate act, never implied by construction")`. Append: `INSERT INTO impetus.semantic_events (event_id,
  net_instance_id, record_type, occurrence, payload) VALUES (%s, %s, %s, %s, %s::jsonb) ON CONFLICT DO NOTHING`
  with `event_id = f"{instance}:{position}"`; in join mode no `transaction()` block (the Engine commits).
- SQLite: schema `impetus_history_schema` / `impetus_history_events` (+ two partial unique terminal indexes),
  `PRAGMA busy_timeout = 5000`, `foreign_keys = ON`, `synchronous = FULL`, `journal_mode = WAL`, `BEGIN IMMEDIATE`
  per append batch (`history_store/sqlite.py:44-67,186-202,312-336`).

**SQLite writer fence** (`history_store/sqlite.py:74-104`) — file layout that must match for cross-language
exclusion:
- `database = Path(path).expanduser().resolve()` (absolute, symlinks resolved — on macOS `/tmp` →
  `/private/tmp`);
- lock dir `database.parent / ".impetus-sqlite-locks"`, created with mode `0o700` (`parents=True, exist_ok=True`);
- lock file `f"{sha256(str(database).encode('utf-8')).hexdigest()}.{sha256(instance.encode('utf-8')).hexdigest()}.lock"`
  opened `O_RDWR | O_CREAT`, mode `0o600`; never deleted;
- lock: **BSD `flock(fd, LOCK_EX | LOCK_NB)`** (Python `fcntl.flock`, not POSIX `fcntl` record locks);
  `EACCES`/`EAGAIN` → `RuntimeError(f"refusing second canonical writer for Instance {instance!r} in SQLite
  database {database}")`; release `flock(fd, LOCK_UN)` + `close`.
- No `fcntl` (non-POSIX) → `RuntimeError("fenced SQLite Engine hosting requires POSIX advisory locks; ...")`;
  empty instance → `ValueError`.

**Absurd composition validation** (`absurd.py:16-34`), in order: joined `connection.autocommit` must be False;
`listen` must be supplied; `listen is not connection`; `listen.autocommit` must be True (each a `ValueError` with
the quoted rationale). Then fence → `PostgresHistoryStore` → `AbsurdDispatch`. LISTEN/NOTIFY channels:
`impetus_dispatch` / `impetus_results` (payload = queue name) as in the previous component §2.

#### 3. Concurrency & durability semantics

**Construction order and ownership transfer** (identical shape in all three):
1. (Postgres/Absurd) validate connections; refuse `autocommit=True` joined connection.
2. Acquire fence **before** constructing the History store (no History is read without authority;
   `test_postgres_engine.py:374-395`).
3. Construct store (loads all rows), (Absurd) Dispatch, resources.
4. `Engine._open(..., resources=...)`. On success `transferred = True`: the Engine now owns fence and connections.
5. On failure before transfer: SQLite closes history then fence (`finally`); Postgres/Absurd roll back, release
   the fence (unlock then rollback), close connection(s) — the caller's connection is **always closed** on any
   construction failure (`test_postgres_engine.py:322-372`, missing-schema `:397-413`). Double cleanup after the
   Engine ctor already cleaned up is idempotent.

**PostgreSQL transaction shape**: the joined connection is `autocommit=False`, so the fence `SELECT` opens a
transaction that also covers the History load and `Instance` construction/resume until the Engine's construction
commit. Session-level advisory locks survive commit/rollback and are released by `pg_advisory_unlock` or by session
end (connection close / death). The lock is a trusted-workspace coordination fence, not a lease: no TTL, no
heartbeat, no fencing token; a live coordinator must treat losing the connection as terminal (`_postgres.py:1-12`).
Isolation level: psycopg default (READ COMMITTED); none is set explicitly. The Engine commits at the boundaries
listed above; join-mode appends are visible in the in-memory mirror before commit, which is why any failure must
poison (a rollback retracts facts live state already advanced on).

**Absurd**: begin batch + `absurd.spawn_task` + `pg_notify('impetus_dispatch', queue)` share the one joined
transaction (commit-or-vanish together; NOTIFY delivered on commit, so no phantom wakes). The `listen` connection
never participates in the joined transaction; all wait-time probes ride it, so the joined connection never idles
in transaction while the host blocks.

**SQLite**: the History store owns short `BEGIN IMMEDIATE` transactions per append (`busy_timeout` 5 s), so the
Engine's `commit` is `None` and selection installs immediately after `begin`. The flock is the cross-process
single-writer authority; SQLite's own locking is only a backstop. **Fork safety**: `_WriterFence` records
`os.getpid()`; `ensure()` (called by every Engine door) raises `RuntimeError("an Engine inherited across fork cannot
be observed or driven; open a fresh Engine")` in a child; an `os.register_at_fork(after_in_child=...)` hook closes
every live fence's inherited fd in the child **without** `LOCK_UN` (flock belongs to the shared open file
description, so unlocking in the child would drop the parent's lock); a weak set tracks live fences
(`sqlite.py:71,106-138`). Holder death releases the flock (kernel), verified with `multiprocessing` spawn +
`terminate` (`test_sqlite_engine.py:63-79`).

**Poison** (all providers): writing-door exception → `rollback` → `release` (unlock fence; Postgres then
rollback) → `close` (connections or SQLite handle). The fence is free immediately for a fresh `load_engine`.

#### 4. External dependencies

| Python | Haskell suggestion |
| --- | --- |
| `psycopg` 3 (`psycopg[binary]>=3.2,<4`), `connection.autocommit`, `commit/rollback/close`, `notifies(timeout=, stop_after=1)` | `postgresql-libpq` (direct control of transactions, `PQnotifies`, `socketFd` + `threadWaitRead` with `System.Timeout`), or `postgresql-simple` (`Database.PostgreSQL.Simple.Notification.getNotification`, `withTransaction` not used — manual `BEGIN`/`COMMIT` to mirror the implicit psycopg transaction). `hasql` lacks first-class LISTEN (would need `hasql-notifications`); avoid it for the joined connection. Pass the fence key as `int8` explicitly. |
| `sqlite3` stdlib | `direct-sqlite` / `sqlite-simple` (`busy_timeout`, WAL, `BEGIN IMMEDIATE`) |
| `fcntl.flock` | **`lukko`** (`Lukko.FLock` = real `flock(2)`) or `filelock` (uses `flock` on Unix). **Do not** use `GHC.IO.Handle.Lock.hTryLock` (prefers OFD `fcntl` locks on Linux, which do not exclude `flock` holders) or `unix`'s `setLock` (POSIX record locks) — neither interoperates with Python's `flock`. |
| `hashlib.sha256` | `crypton` (`Crypto.Hash.SHA256`) or `cryptohash-sha256`; hex via `base16-bytestring` |
| `os.getpid`, `register_at_fork` | `System.Posix.Process.getProcessID`; Haskell programs rarely `forkProcess`, so a pid check in `ensure` suffices |
| `Path.resolve()` | `directory` `canonicalizePath` (resolves symlinks; must produce the same string as Python for the shared hash — test on macOS `/private/tmp`) |
| `absurd-sdk==0.4.0` | no Haskell SDK; the Engine side only needs SQL (`absurd.spawn_task`, queue tables) — covered by section 7 |

#### 5. Upstream tests

`test_sqlite_engine.py` (5) and `test_postgres_engine.py` (12) as tabulated in the previous component §5. Postgres
tests need Docker (root `conftest.py`, fail-loud fixtures); SQLite tests need POSIX (`fork` test skipped where
unavailable) and `multiprocessing` spawn. The Absurd composition is covered by the DST joined worlds and
`motus/worker/test_worker_topology.py` (Docker + vendored Absurd schema). A Haskell port should add cross-language
fence tests: Python holds → Haskell refused and vice versa, for both flock and advisory lock, using the vectors above.

#### 6. Performance

Construction cost = fence + full History load (+ resume replay). Steady state: SQLite pays one fsync'd
`BEGIN IMMEDIATE` transaction per append batch; Postgres joined pays one `COMMIT` per Engine commit point (≈2 per
activity completion, 1 per begin). Benchmark: per-action latency and commits/action for each provider on identical
workloads (component 1 §6, item 5); fence acquire/release latency (trivial); load time vs History size.

#### 7. Better-the-Haskell-way suggestions

- `withSqliteEngine` / `withPostgresEngine` / `withAbsurdEngine` bracket helpers on top of `create`/`load`
  (`bracket` with `close`), plus the plain door for long-lived hosts.
- Encode the connection-mode preconditions in types: `newtype JoinedConnection` (autocommit off) and
  `newtype ListenConnection` (autocommit on, distinct), constructed by smart constructors so the four Absurd
  `ValueError`s become construction-time errors.
- Fence as a resource value `data WriterFence = WriterFence { ensure :: IO (), release :: IO () }` shared by
  both backends.
- Preserve exactly: fence key derivation, lock path/file naming/modes, flock semantics, "fence before History",
  "connection always closed on failed construction", unlock-then-rollback order, the user-visible error texts used
  by tests (`second canonical writer`, `already held`, `autocommit=False`, `ensure_schema`, `inherited across fork`).

#### 8. Packaging

Either inside `petrus-engine` behind flags, or `petrus-engine-sqlite` (deps: `petrus-engine`, SQLite History store,
`direct-sqlite`, `lukko`, `crypton`) and `petrus-engine-postgres` (deps: `petrus-engine`, Postgres History store,
`postgresql-libpq`, `crypton`; Absurd composition additionally depends on the Absurd Dispatch package). Needs from
the kernel only the History store constructors and their join-mode semantics. Build in parallel with the History
store backends; the Absurd door lands after `AbsurdDispatch` (`wait_for_results`, idempotent `dispatch`,
`cancel`).

## 7. Activities and Dispatch

### Activities — `petrus.motus.activity`

Source: `src/petrus/motus/activity/__init__.py` (493 lines). A leaf package: it
imports only the stdlib (no Petri net, no history; `tests/integration/test_activity_seam.py:116-136`
asserts the import is a leaf in a fresh interpreter). Every other motus component
(dispatch, worker, transport) and the kernel's history records/`ActivityHandler`
bridge depend on these values.

#### 1. Responsibility & public API

Petri- and history-agnostic activity values, validation doors, and the
author-facing `@activity` declaration.

| Name | Signature / shape | Notes |
| --- | --- | --- |
| `HEARTBEAT_DETAILS_LIMIT` | `65_536` (`:14`) | UTF-8 byte limit of compact JSON details |
| `MAX_DURATION_SECONDS` | `1_000_000_000` (`:253`) | provider-neutral cap for every duration |
| `snapshot_heartbeat_details(value) -> object` | `:18-42` | normalize to detached JSON: `None/str/bool/int/finite float/list/Mapping[str,…]` only (tuples refused, non-str keys refused, NaN/Inf refused, any other type refused with `"heartbeat details are not JSON-faithful: <type>"`); encode `json.dumps(normalized, allow_nan=False, ensure_ascii=False, separators=(",", ":")).encode()`; `len > 65536` → `ValueError("heartbeat details encode to N UTF-8 bytes; limit is 65536")`; returns `json.loads(encoded)` (fresh `dict`/`list`, insertion order kept, NOT sorted). `"x"*65534` passes (65536 bytes incl. quotes), `"x"*65535` fails (`tests/petrus/motus/dispatch/test_attempt_heartbeats.py:139-145`). |
| `ActivityDeclaration(name: str, heartbeat_timeout: int|None=None)` | frozen, `:45-60` | name non-empty str; timeout positive non-bool int or None. Engine-side metadata (Engine resolves `policy.heartbeat_timeout = declaration.heartbeat_timeout or Engine.default_heartbeat_timeout (30)` in `src/petrus/engine/__init__.py:74-90` — engine agent's concern). |
| `PayloadConverter` (Protocol) | `decode(value, annotation)`, `encode(value, annotation)` `:63-68` | |
| `JsonPayloadConverter` | `:79-96` | both directions `json.loads(json.dumps(value, allow_nan=False))` — NOTE default `json.dumps` silently stringifies non-str dict keys (`{1:"a"}`→`{"1":"a"}`, `True`→`"true"`, `None`→`"null"`), tuples→lists; failure → `ValueError("Activity payload is not JSON-faithful: …")`. |
| `DataclassPayloadConverter(fallback=JsonPayloadConverter())` | `:99-120` | decode: if annotation is a dataclass type, payload must be a str-keyed mapping, **unknown keys are silently dropped** (`{"amount":100,"currency":"USD"}`→`PaymentInput(100)`, seam test `:207-242`); encode: value must be an instance of the annotation, then `asdict` → fallback. |
| `ActivityDefinition(function, declaration, converter, parameters: Mapping[str, annotation], result)` | `:123-153` | `__call__(invocation, *, context)`: refuses `invocation.activity != declaration.name`; `invocation.input` must be a str-keyed mapping whose **key set equals the parameter-name set exactly** (`"requires parameters [sorted] , got [sorted]"`); decodes each by annotation, calls with kwargs, encodes result. Context is ignored. |
| `activity(fn=None, *, name=None, heartbeat_timeout=None, converter=JsonPayloadConverter())` | `:175-194` | decorator; refuses coroutine functions; requires every parameter POSITIONAL_OR_KEYWORD/KEYWORD_ONLY and fully annotated incl. return (`get_type_hints`); name defaults to `__name__` (explicit `""` is refused, not replaced). |
| `AsyncActivityDefinition`, `async_activity(...)` | `:197-250` | same, awaiting the function; requires a coroutine function. |
| `RetryPolicy(initial_interval=0, coefficient=2, max_interval=60, max_attempts=1, jitter=0)` | `:257-303` | see 2. |
| `ExecutionPolicy(attempts=1, heartbeat_timeout=30, initial_interval=0, coefficient=2, max_interval=60, jitter=0, start_to_close=None, schedule_to_close=None)` | `:306-350` | `.retry_policy` property builds `RetryPolicy(initial_interval, coefficient, max_interval, attempts, jitter)`. |
| `ActivityInvocation(activity: str, *, input=None, policy=ExecutionPolicy(), correlation: str|None=None, idempotency: str|None=None)` | frozen, `:353-372` | non-empty activity; correlation/idempotency `None` (= "writer derives at begin") or non-empty str. Note: `input` is NOT validated here (canonicalized by the kernel at begin). |
| `ActivityFailure(error: str, kind="ActivityError", details=None, retryable=False, retry_after: float|None=None)` | frozen, `:385-413` | `error` 1..4096 **code points**; `kind` 1..128 code points; `retryable` must be `bool` (else `TypeError`); `retry_after` None or finite ≥0 ≤1e9 non-bool number; `details` canonicalized by `_failure_details` (`:375-382`): `json.dumps(allow_nan=False, ensure_ascii=False, separators=(",",":"))`, UTF-8 length ≤ 16384 bytes, then `json.loads` (so tuples→lists; non-str keys are coerced to strings here too). |
| `ActivityError(error, *, kind, details, retryable, retry_after)` | `:416-433` | exception carrying `.failure: ActivityFailure`. |
| `ActivityExecutionContext` / `AsyncActivityExecutionContext` (Protocols) | `:436-463` | attrs `attempt_id: str, epoch: str, claimant: str, instance: str|None, latest_details`; `heartbeat(*, details=_OMITTED) -> object` (omitted = keep details, renew lease; `None` = replace with JSON null). |
| `Activity`, `AsyncActivity` (Protocols) | `:448-469` | `(invocation, *, context) -> result`. |
| `_OMITTED` | `:15` | private sentinel shared with dispatch. |

Kernel APIs used: none. Consumers in the kernel: `petrus.impetus.history` records
`ActivityRequested(policy=ExecutionPolicy…)`, `ActivityFailed(error, kind, details,
retryable, retry_after)`; `petrus.impetus.history.codec` decodes `policy` requiring
**exactly the 8 current fields** (`src/petrus/impetus/history/codec.py:99-113`);
`petrus.impetus.binding.DerivedActivityHandler` consumes `ActivityDefinition.parameters/result`.

#### 2. Wire formats & value rules

- **Invocation wire spelling** (identical in Local, Absurd, ZeroMQ transport
  `src/petrus/motus/transport/zeromq.py:864ff`, and the history codec):
  `{"activity", "input", "policy": {"attempts", "heartbeat_timeout", "initial_interval", "coefficient", "max_interval", "jitter", "start_to_close", "schedule_to_close"}, "correlation", "idempotency"}`.
  Decoders additionally accept the **legacy 2-field policy** `{"attempts","heartbeat_timeout"}` (filled from defaults) — Local and Absurd only, not the history codec.
- **Numbers keep their Python type**: `initial_interval/coefficient/max_interval/jitter/start_to_close/schedule_to_close` are `int | float`; `1` encodes `1`, `1.0` encodes `1.0`. Local Dispatch compares durable invocation **text**, so `ExecutionPolicy(initial_interval=1)` and `(initial_interval=1.0)` are a publication conflict even though Python `==` says equal. Haskell must carry a JSON-number representation that preserves int-vs-float and CPython `repr(float)` (use `petrus-json`'s number type), never a bare `Double`.
- **RetryPolicy validation** (`:267-282`): the four float-ish fields non-bool, finite, ≥0; `initial_interval, max_interval ≤ 1e9`; `coefficient ≥ 1`; `max_attempts` int ≥1; `jitter` must be `0` ("RetryPolicy jitter is unsupported; only deterministic jitter=0 is accepted").
- **RetryPolicy.delay(failed_attempt)** (`:284-303`) — reproduce the float arithmetic exactly (it is *not* `initial * coefficient**n`):
  ```
  if failed_attempt is bool/not int/<1: ValueError("RetryPolicy delay requires a failed attempt number >= 1")
  if initial_interval == 0 or max_interval == 0: return 0
  if initial_interval >= max_interval: return max_interval
  if coefficient == 1: return initial_interval
  exponent = failed_attempt - 1
  saturation = ceil((log(max_interval) - log(initial_interval)) / log(coefficient))
  if exponent >= saturation: return max_interval
  return min(max_interval, exp(log(initial_interval) + exponent * log(coefficient)))
  ```
  e.g. `RetryPolicy(1,2,60,10).delay(1..8) == [1.0, 2.0, 4.0, 7.999999999999998, 15.999999999999998, 32.0, 60, 60]` (verified). Arbitrary-size ints (`delay(10**1000)`) must work → `Integer` in Haskell; uses libm `exp/log` (GHC's `exp`/`log` on `Double` call the same libm — run a golden table).
- **ExecutionPolicy validation** (`:319-346`): `attempts` int ≥1 (message mentions "a wedge, not a policy"); `heartbeat_timeout` positive int ≤1e9; retry fields via `RetryPolicy`; `start_to_close`/`schedule_to_close` None or finite >0 ≤1e9. Error texts contain `"at most 1000000000 seconds"`.
- No durable schema of its own.

#### 3. Concurrency & durability

Pure values; no I/O. `ActivityDefinition.parameters` is frozen (`MappingProxyType`).

#### 4. External dependencies

stdlib only (`json`, `math`, `inspect`, `typing.get_type_hints`). Haskell: `petrus-json`
(JSON value + CPython-faithful encoder, byte length), `text`, `containers`. The
reflection-based `@activity` (parameter names/annotations from type hints) has no
direct analogue — see 7.

#### 5. Upstream tests

- `tests/integration/test_activity_seam.py` — 100 functions (≈111 collected:
  `attempts`×2, `value`×3, `construct`×6, `first,second`×4). Only these groups are
  activity-contract tests: typed `@activity` + `DerivedActivityHandler` derivation
  and its refusals (`:207-569`, 13 tests; need kernel `binding`/`Engine`),
  `TestExecutionPolicy` (`:571-622`), `TestActivityInvocation` (`:625-648`),
  `TestInlineDispatch` (`:1251-1357`), `TestCanonicalPayloadSnapshot` (`:1782-1860`).
  The rest (begin batch, `record_activity_completion`, kill windows, replay guards,
  failure projection, K6) is kernel/instance behaviour — owned by the instance/engine
  port (section 6 and the kernel plan). No Postgres, no network.
- `tests/petrus/motus/dispatch/test_attempt_heartbeats.py:63-145` — declaration/policy timeout validation, inline context, `snapshot_heartbeat_details` shapes and byte limit.
- `tests/petrus/motus/test_execution_contract.py` (10 functions) does **not** touch the activity contract (it tests `petrus.motus.execution` environments); nothing to port here.

#### 6. Performance

Not a hot path by itself; `snapshot_heartbeat_details` and `_failure_details` run
per heartbeat/failure (encode+decode). Benchmark folded into the dispatch
benchmarks below (heartbeat with 1 KiB / 60 KiB details).

#### 7. Better-the-Haskell-way

- `ActivityInvocation`, `ExecutionPolicy`, `ActivityFailure` as records with smart constructors returning `Either ValidationError`; `NonEmptyText` for names; `Maybe NonEmptyText` for correlation/idempotency; `Jitter` as a unit (only 0 accepted) but **keep the original number literal** (`0` vs `0.0`) for byte parity.
- `PositiveSeconds` newtype bounded by `maxDurationSeconds`; a `JsonNumber` (int|float) for policy fields to preserve spelling.
- Replace decorator reflection with a typeclass: `class ActivityPayload a where decodePayload :: Value -> Either Text a; encodePayload :: a -> Value`, plus an `ActivityDefinition` built from an explicit name and a record of named arguments (`generics-sop`/`GHC.Generics` to derive the parameter-name set). Keep the "supplied key set == parameter set" check and DataclassPayloadConverter's "ignore unknown fields" behaviour for parity.
- Sync and async definitions collapse to one `ActivityInvocation -> ActivityContext -> IO Value` in Haskell (all IO is async-capable); keep an `async`-flavoured name only if worker topology needs it.
- `HeartbeatDetails` newtype whose constructor enforces the 65536-byte compact encoding.
- Quirks to preserve: error/kind length in code points (Python `len(str)`); JsonPayloadConverter key stringification; heartbeat snapshot keeps insertion order but Local stores details sort_keys'd.

#### 8. Packaging

Proposed `petrus-motus-activity` (or module `Petrus.Motus.Activity` in a
`petrus-motus` core package). Depends only on `petrus-json`. Can be built
immediately, in parallel with the kernel; the kernel history records depend on it
(so it should land early — `ActivityRequested`/`ActivityFailed` codecs need
`ExecutionPolicy`/`ActivityFailure`).

---

### Dispatch protocols, InlineDispatch, InMemoryDispatch — `petrus.motus.dispatch`

Source: `src/petrus/motus/dispatch/__init__.py` (266 lines).

#### 1. Responsibility & public API

| Name | Signature | Notes |
| --- | --- | --- |
| `ActivityAttempt(attempt_id: str, epoch: str, claimant: str, queue: str, invocation: ActivityInvocation, latest_details=None, instance: str|None=None)` | frozen, `:24-39` | provider-neutral fenced claim; `latest_details` passed through `snapshot_heartbeat_details`; `instance` None or non-empty str. Local: `attempt_id='["inst",occ]'`, `epoch=str(int)`. Absurd: `attempt_id=str(task_id uuid)`, `epoch=str(run_id uuid)`. |
| `CancellationInstruction(occurrence: int, invocation: ActivityInvocation, history_position: int)` | frozen, `:42-55` | occurrence/history_position positive non-bool ints. |
| `CancellationDisposition` (StrEnum) | `:58-65` | `"tombstoned"`, `"retired"`, `"fenced"`, `"terminal"`, `"acknowledged"`. |
| `WorkerDispatch` (runtime Protocol) | `:68-82` | `claim() -> ActivityAttempt|None`; `heartbeat(attempt, *, details=_OMITTED) -> object`; `complete(attempt, result)`; `fail(attempt, error: str|Exception|ActivityFailure)`; `wait(timeout: float) -> bool`; `close()`. |
| `Dispatch` (runtime Protocol) | `:178-184` | `dispatch(occurrence: int, invocation)`, `collect() -> Sequence[(occurrence, result_or_ActivityFailure)]`. Engine-side; providers also expose `wait_for_results(timeout) -> bool` (duck-typed). |
| `CancellableDispatch` (runtime Protocol) | `:187-191` | `cancel(instruction) -> CancellationDisposition`. |
| `InlineDispatch(activities: Mapping[str, Activity])` | frozen dataclass `:89-155` | see below. |
| `InMemoryDispatch()` | `:194-251` | explicit pump: `pending` (read-only view), `complete(occ, result)`, `fail(occ, error: str)` (→ `ActivityFailure(error)`), `cancel`. |
| re-exports | `LocalDispatch`, `LocalDispatchClock`, `LocalWorkerDispatch` (`:86`) | Absurd is opt-in import `petrus.motus.dispatch.absurd`. |

**InlineDispatch semantics** (`:104-161`):
- `__call__(invocation)`: unknown activity → `ValueError("no activity implementation for 'x': this InlineDispatch implements [sorted]")`. Loops `attempt in 1..policy.attempts` with a fresh `_InlineActivityExecutionContext(attempt_id=f"inline-{n}", epoch=str(n), claimant="inline", latest_details=None, instance=None)`; on exception classifies via `_classify_inline_failure` (`ActivityError` → its `.failure`; any other exception → `ActivityFailure(str(e) or type(e).__name__, kind=type(e).__name__, retryable=True)`); **re-raises the original exception** when not retryable, when `schedule_to_close` elapsed (`time.monotonic`), or on the last attempt. **Retries are immediate: never sleeps** (ignores backoff and `retry_after`, test `:1266-1285`). `start_to_close` ignored.
- `dispatch(occ, inv)`: if cancelled: same invocation → silently drop, else `ValueError("cancellation conflict for occurrence N")`. Otherwise runs inline and buffers `(occ, result)`; **any** exception (including the unknown-activity `ValueError`) is buffered as a classified `ActivityFailure`.
- `collect()` drains the buffer in completion order. `cancel`: prior equal → `ACKNOWLEDGED`, prior different → conflict; already buffered → `TERMINAL`; else `TOMBSTONED`.
- Value shape quirk (test `:1297-1306`): dataclass fields exactly `activities`, `_completed`; equality ignores `_completed`/cancellations; `activities` snapshotted to `MappingProxyType`.

**InMemoryDispatch** (`:194-251`): `dispatch` on a pending occurrence → `ValueError("occurrence N is already pending in this pool: one dispatch per occurrence")`; `cancel`: prior → ACKNOWLEDGED/conflict; pending with same invocation → `RETIRED` (removed); pending with different invocation → conflict; already completed → `TERMINAL`; else `TOMBSTONED`. `complete/fail` on a cancelled occurrence still appends (late report transported to the engine for quarantine); otherwise requires pending.

Kernel APIs used: none (pure motus). The engine passes `occurrence` (firing occurrence int) and `history_position`.

#### 2. Wire formats

None durable. The `CancellationDisposition` string values appear in telemetry/log fields (`disposition=`).

#### 3. Concurrency

Single-threaded, in-process. InlineDispatch runs the activity on the caller thread.

#### 4. External dependencies

None. Haskell: `containers`, `stm` (optional for InMemory).

#### 5. Upstream tests

`TestInlineDispatch` in `tests/integration/test_activity_seam.py:1251-1357` (8 tests),
`test_attempt_heartbeats.py:74-107` (inline context). InMemoryDispatch is exercised
by engine and DST tests (sections 6 and 10).

#### 6. Performance

Inline: one function call per attempt — compare Engine end-to-end activity firing
latency (owned by the engine benchmark).

#### 7. Better-the-Haskell-way

- `Dispatch` as a record of functions (`dispatch`, `collect`, `waitForResults`, optional `cancel :: Maybe (CancellationInstruction -> IO CancellationDisposition)`) rather than classes; `WorkerDispatch` likewise. `CancellationDisposition` as a sum type with a `toText`.
- `Outcome = Completed Value | Failed ActivityFailure` instead of `object | ActivityFailure`.
- InMemoryDispatch over `IORef`/`TVar` maps.
- Preserve: inline never sleeps; inline re-raises the original exception from `__call__`; generic exception classification `retryable=True`.

#### 8. Packaging

`petrus-motus-dispatch` core module (`Petrus.Motus.Dispatch`), depends on
`petrus-motus-activity` only. Parallel with kernel.

---

### Local Dispatch (SQLite) — `petrus.motus.dispatch.local`

Source: `src/petrus/motus/dispatch/local.py` (981 lines). Single-host durable
custody in a SQLite file, shareable by many processes (engines and workers), and
co-resident with `SqliteHistoryStore` tables in the same file
(`test_local_dispatch.py:888-898`). The database is the clock and serialization
authority by default.

#### 1. Responsibility & public API

- `LocalDispatchClock` (Protocol) `now_ms() -> int` (`:43-46`). `_ClockReader` (`:49-63`) samples under a `threading.Lock`; value must be `type(x) is int` and `0 ≤ x ≤ 2**63-1` (`"…nonnegative signed-64-bit millisecond integer"`), and must not decrease vs the previous sample of the same reader (`"Local Dispatch clock must not rewind"`). `LocalDispatch.worker()` shares its reader with the worker.
- `LocalDispatch(path, *, instance: str, default_queue="default", activity_queues: Mapping[str,str]|None=None, clock=None)` (`:97-271`) — engine-facing, scoped to one `instance`. Methods: `dispatch(occ, inv)`, `cancel(instruction)`, `collect()`, `worker(queues=("default",), *, worker_id=None) -> LocalWorkerDispatch`, `wait_for_results(timeout) -> bool`. Session state (not durable): `_published: set[int]`, `_collected: set[int]`.
- `LocalWorkerDispatch(path, *, queues=("default",), worker_id=None, clock=None, _claimant=None, _clock_reader=None)` (`:273-497`) — claims across **all instances** in the file for its queues. `claimant = _claimant or f"{worker_id or 'worker'}:{uuid4()}"`. Methods: `claim`, `heartbeat`, `complete`, `fail`, `wait`, `close` (no-op).
- Names (`instance`, queues, activity names, worker label) must be non-empty str without NUL (`_name`, `:875-878`); occurrence positive non-bool int; wait timeout non-negative number.
- Telemetry: `petrus.telemetry.get_logger("impetus").emit(...)` events `dispatch_published`, `dispatch_cancelled`, `dispatch_collected` (`outcome=` `"completed"|"failed"`), `dispatch_claimed`, `dispatch_heartbeat`, `dispatch_failed` (`outcome="retryable"|"terminal"|"terminal-retry"|"cancelled-report"`), `dispatch_completed` (`outcome="terminal"|"terminal-retry"|"cancelled-report"`), `dispatch_lease_expired` (`outcome="failed"`); attempt events carry `instance, occurrence, attempt, epoch, claimant, queue, activity` (`:570-582`).

#### 2. Durable schema & every statement (verbatim)

Connection setup (`:841-864`) — every operation opens a **new** connection:
```
sqlite3.connect(path, timeout=5, isolation_level=None)   -- autocommit; explicit BEGIN
PRAGMA busy_timeout=5000
PRAGMA foreign_keys=ON
PRAGMA synchronous=FULL
PRAGMA journal_mode=WAL      -- _connect only; retried every 10 ms for up to 5 s while the error text contains "locked"; result must be "wal" else ValueError("<path>: SQLite refused WAL mode")
```
Write operations: `BEGIN IMMEDIATE` … `COMMIT` (rollback on exception), then close (`_transaction`, `:826-838`). `collect`/`_terminal_ready` use `_connect` without an explicit transaction.

Default clock (`:867-872`), sampled inside the write transaction:
```sql
SELECT CAST(strftime('%s','now') AS INTEGER) * 1000 + CAST(substr(strftime('%f','now'),4,3) AS INTEGER)
```

DDL `_DDL` (`:66-94`), version `_VERSION = 3`, prefix `impetus_local_dispatch_`. **Must be issued byte-for-byte** (the opener compares `sqlite_master.sql` after whitespace-collapse + lowercase, `:694-715`; a Python process will refuse a Haskell-created file otherwise):
```sql
CREATE TABLE impetus_local_dispatch_schema (
 component TEXT PRIMARY KEY CHECK(component='dispatch'), version INTEGER NOT NULL)
```
```sql
INSERT INTO impetus_local_dispatch_schema VALUES ('dispatch', 3)
```
```sql
CREATE TABLE impetus_local_dispatch_tasks (
 sequence INTEGER PRIMARY KEY AUTOINCREMENT,
 instance TEXT NOT NULL, occurrence INTEGER NOT NULL CHECK(occurrence>0),
 queue TEXT NOT NULL, invocation TEXT NOT NULL CHECK(json_valid(invocation)),
 epoch INTEGER NOT NULL DEFAULT 0 CHECK(epoch>=0), claimant TEXT, deadline INTEGER,
 schedule_start INTEGER NOT NULL, attempt_start INTEGER, attempt_deadline INTEGER, available_at INTEGER NOT NULL,
 details TEXT CHECK(details IS NULL OR json_valid(details)),
 CHECK((epoch=0 AND claimant IS NULL AND deadline IS NULL) OR
       (epoch>0 AND claimant IS NOT NULL AND deadline IS NOT NULL)),
 UNIQUE(instance, occurrence))
```
```sql
CREATE INDEX impetus_local_dispatch_claimable
 ON impetus_local_dispatch_tasks(queue, sequence)
```
```sql
CREATE TABLE impetus_local_dispatch_terminals (
 sequence INTEGER PRIMARY KEY AUTOINCREMENT,
 instance TEXT NOT NULL, occurrence INTEGER NOT NULL, epoch INTEGER NOT NULL CHECK(epoch>=0),
 claimant TEXT, outcome TEXT NOT NULL CHECK(json_valid(outcome)),
 CHECK((epoch=0 AND claimant IS NULL) OR (epoch>0 AND claimant IS NOT NULL)),
 UNIQUE(instance, occurrence),
 FOREIGN KEY(instance, occurrence) REFERENCES impetus_local_dispatch_tasks(instance, occurrence))
```
```sql
CREATE TABLE impetus_local_dispatch_cancellations (
 instance TEXT NOT NULL, occurrence INTEGER NOT NULL CHECK(occurrence>0),
 history_position INTEGER NOT NULL CHECK(history_position>0),
 invocation TEXT NOT NULL CHECK(json_valid(invocation)),
 PRIMARY KEY(instance, occurrence))
```
All times are integer **milliseconds**. Column meaning: `epoch` = attempt number/fence (0 = never claimed); `deadline` = lease expiry; `schedule_start` = first publication time; `attempt_start/attempt_deadline` = current attempt start and hard (start/schedule-to-close) limit; `available_at` = earliest claim time (backoff); `details` = latest heartbeat details JSON.

**Opening / migration** (`_initialize`, `:649-691`), inside `BEGIN IMMEDIATE` on a raw connection (before WAL), then `_connect` once to set WAL:
```sql
SELECT name,type FROM sqlite_master WHERE name LIKE ?        -- ? = 'impetus_local_dispatch_%'
```
- no objects → run all `_DDL` in order.
- objects must equal the v2 set `{schema:table, tasks:table, claimable:index, terminals:table}` or that + `cancellations:table`, else `ValueError("<path>: foreign or unversioned Local Dispatch schema; migration is not supported")`.
- `SELECT component,version FROM impetus_local_dispatch_schema` — `[('dispatch',1)]` → `_migrate_v1` then `UPDATE impetus_local_dispatch_schema SET version=2 WHERE component='dispatch'`; `[('dispatch',2)]` → objects must be exactly the v2 set (`"foreign Local Dispatch schema-2 shape"`), execute `_DDL[5]` (cancellations) and `UPDATE impetus_local_dispatch_schema SET version=3 WHERE component='dispatch'`; anything other than `[('dispatch',3)]` → `"unsupported Local Dispatch schema …; migration is not supported"`.
- `_validate_shape` (`:694-763`): `SELECT name,sql FROM sqlite_master WHERE name IN (?,?,?,?,?)` vs `_DDL[0,2,3,4,5]` normalized (`re.sub(r"\s+"," ",s.strip()).lower()`); `PRAGMA table_info(<table>)` rows `(name,type,notnull,dflt_value,pk)` must equal exactly (e.g. tasks.epoch `("epoch","INTEGER",1,"0",0)`, cancellations pk `instance`=1,`occurrence`=2); `PRAGMA index_info(impetus_local_dispatch_claimable)` columns `["queue","sequence"]`; `PRAGMA foreign_key_list(impetus_local_dispatch_terminals)` `(table,from,to,on_update,on_delete,match)` = `("impetus_local_dispatch_tasks","instance","instance","NO ACTION","NO ACTION","NONE")`, same for occurrence. Failure → `"foreign current-version Local Dispatch … shape"`.
- **v1 → v2 migration** (`_migrate_v1`, `:766-823`) — v1 shape is reproduced in `test_local_dispatch.py:211-235` (tasks without `schedule_start/attempt_start/attempt_deadline/available_at`; terminals with `epoch>0`, `claimant NOT NULL`):
  ```sql
  SELECT sequence,instance,occurrence,queue,invocation,epoch,claimant,deadline,details FROM impetus_local_dispatch_tasks ORDER BY sequence
  SELECT sequence,instance,occurrence,epoch,claimant,outcome FROM impetus_local_dispatch_terminals ORDER BY sequence
  DROP TABLE impetus_local_dispatch_terminals
  DROP INDEX impetus_local_dispatch_claimable
  DROP TABLE impetus_local_dispatch_tasks
  -- then _DDL[2], _DDL[3], _DDL[4]
  INSERT INTO impetus_local_dispatch_tasks(sequence,instance,occurrence,queue,invocation,epoch,claimant,deadline,schedule_start,attempt_start,attempt_deadline,available_at,details) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
  INSERT INTO impetus_local_dispatch_terminals(sequence,instance,occurrence,epoch,claimant,outcome) VALUES(?,?,?,?,?,?)
  ```
  invocations re-encoded canonically (legacy 2-field policy → 8 fields); `schedule_start=available_at=now`, `attempt_start = now if epoch else NULL`, `attempt_deadline=NULL`; legacy terminal `{"kind":"failed","error":E}` rewritten to the current failure wire with `ActivityFailure(error=E)`.

**`LocalDispatch.dispatch(occ, inv)`** (`:123-173`), one `BEGIN IMMEDIATE`; `queue = activity_queues.get(inv.activity, default_queue)`:
```sql
SELECT history_position,invocation FROM impetus_local_dispatch_cancellations WHERE instance=? AND occurrence=?
-- if a cancellation exists: its invocation text must equal the encoding (else "Local Dispatch publication conflict for occurrence N"); mark published; return (no task created)
INSERT INTO impetus_local_dispatch_tasks(instance,occurrence,queue,invocation,schedule_start,available_at) VALUES(?,?,?,?,?,?) ON CONFLICT(instance,occurrence) DO NOTHING   -- schedule_start=available_at=now
SELECT queue,invocation,epoch,deadline FROM impetus_local_dispatch_tasks WHERE instance=? AND occurrence=?
-- stored invocation TEXT must equal the new encoding exactly (JSON true vs 1 conflict, test :411-422)
SELECT 1 FROM impetus_local_dispatch_terminals WHERE instance=? AND occurrence=?
-- re-route only when: no terminal AND old_queue != queue AND (epoch == 0 OR deadline <= now)
UPDATE impetus_local_dispatch_tasks SET queue=? WHERE instance=? AND occurrence=?
```
Re-dispatch is idempotent and is how a restarted engine re-registers interest (session `_published`).

**`LocalDispatch.cancel(instr)`** (`:175-221`):
```sql
INSERT INTO impetus_local_dispatch_cancellations(instance,occurrence,history_position,invocation) VALUES(?,?,?,?) ON CONFLICT(instance,occurrence) DO NOTHING
SELECT history_position,invocation FROM impetus_local_dispatch_cancellations WHERE instance=? AND occurrence=?   -- must equal (history_position, encoding) else "Local Dispatch cancellation conflict for occurrence N"
SELECT invocation,epoch FROM impetus_local_dispatch_tasks WHERE instance=? AND occurrence=?   -- task invocation must equal encoding
SELECT 1 FROM impetus_local_dispatch_terminals WHERE instance=? AND occurrence=?
```
Disposition: not inserted → `ACKNOWLEDGED`; terminal exists → `TERMINAL`; no task → `TOMBSTONED`; `epoch == 0` → `RETIRED`; else `FENCED`. The occurrence is added to `_published` (so a late terminal is collected for canonical quarantine).

**`LocalDispatch.collect()`** (`:223-242`): eligible = `sorted(_published - _collected)`; if empty return `()`.
```sql
SELECT occurrence,outcome FROM impetus_local_dispatch_terminals WHERE instance=? AND occurrence IN (?,?,…) ORDER BY sequence
```
Order = terminal insertion order (`sequence`). Decode (`_decode_outcome`, `:960-964`): `kind=="completed"` → `value`; else `ActivityFailure(**failure)` or legacy `ActivityFailure(error=…)`. `wait_for_results(timeout)` (`:248-270`) polls every `min(0.05, remaining)` s:
```sql
SELECT 1 FROM impetus_local_dispatch_terminals WHERE instance=? AND occurrence IN (?,…) LIMIT 1
```

**`LocalWorkerDispatch.claim()`** (`:297-355`), one `BEGIN IMMEDIATE`: `now`; `_terminalize_exhausted(now, queues)` (below); then
```sql
SELECT t.instance,t.occurrence,t.queue,t.invocation,t.epoch,t.details FROM impetus_local_dispatch_tasks t LEFT JOIN impetus_local_dispatch_terminals x USING(instance,occurrence) LEFT JOIN impetus_local_dispatch_cancellations c USING(instance,occurrence) WHERE x.occurrence IS NULL AND c.occurrence IS NULL AND t.queue IN (?,…) AND t.epoch < json_extract(t.invocation,'$.policy.attempts') AND t.available_at<=? AND (t.epoch=0 OR t.deadline<=?) ORDER BY t.sequence LIMIT 1
```
(the f-string concatenation yields exactly this one-space-separated text). If found: `epoch = prior+1`; hard limits: `now + ms(start_to_close)` and, if `schedule_to_close`,
```sql
SELECT schedule_start FROM impetus_local_dispatch_tasks WHERE instance=? AND occurrence=?
```
`+ ms(schedule_to_close)`; `attempt_deadline = min(hard) or NULL`; `deadline = min(now + heartbeat_timeout*1000, *hard)`;
```sql
UPDATE impetus_local_dispatch_tasks SET epoch=?,claimant=?,deadline=?,attempt_start=?,attempt_deadline=? WHERE instance=? AND occurrence=?
```
Returns `ActivityAttempt(attempt_id=json.dumps([instance, occurrence], ensure_ascii=False, separators=(",",":")), epoch=str(epoch), claimant, queue, invocation, latest_details=json(details), instance)`. FIFO by `sequence` across instances. A corrupt invocation raises `"corrupt durable Activity invocation: …"` and rolls back the claim (`:723-735`).

`ms(seconds) = ceil(seconds*1000) if seconds > 0 else 0` (`_milliseconds`, `:977-978`) — sub-millisecond values round **up** (`start_to_close=0.0001` → 1 ms).

**`_terminalize_exhausted(now, queues)`** (`:601-646`) — the lease sweep, run by every `claim` and `wait`:
```sql
SELECT t.instance,t.occurrence,t.epoch,t.deadline,t.invocation FROM impetus_local_dispatch_tasks t LEFT JOIN impetus_local_dispatch_terminals x USING(instance,occurrence) LEFT JOIN impetus_local_dispatch_cancellations c USING(instance,occurrence) WHERE x.occurrence IS NULL AND c.occurrence IS NULL AND t.queue IN (?,…) AND t.epoch>0 AND t.deadline<=? AND t.epoch<json_extract(t.invocation,'$.policy.attempts')
-- for each: available_at = deadline(expiry) + ms(retry_policy.delay(epoch))
UPDATE impetus_local_dispatch_tasks SET available_at=? WHERE instance=? AND occurrence=?
SELECT t.instance,t.occurrence,t.epoch,t.claimant FROM impetus_local_dispatch_tasks t LEFT JOIN impetus_local_dispatch_terminals x USING(instance,occurrence) LEFT JOIN impetus_local_dispatch_cancellations c USING(instance,occurrence) WHERE x.occurrence IS NULL AND c.occurrence IS NULL AND t.queue IN (?,…) AND ((t.epoch>0 AND t.deadline<=? AND t.epoch>=json_extract(t.invocation,'$.policy.attempts')) OR (json_extract(t.invocation,'$.policy.schedule_to_close') IS NOT NULL AND t.schedule_start + CAST(json_extract(t.invocation,'$.policy.schedule_to_close')*1000 AS INTEGER) + (json_extract(t.invocation,'$.policy.schedule_to_close')*1000 > CAST(json_extract(t.invocation,'$.policy.schedule_to_close')*1000 AS INTEGER)) <= ?))
-- for each: outcome = failed DeadlineExceeded, message f"Local Dispatch deadline exhausted after {epoch} attempt" / "attempts"
INSERT OR IGNORE INTO impetus_local_dispatch_terminals(instance,occurrence,epoch,claimant,outcome) VALUES(?,?,?,?,?)
```
(the SQL `CAST(x*1000) + (x*1000 > CAST(x*1000))` is the in-SQL ceil.) A never-claimed schedule-expired task terminalizes with `epoch=0, claimant=NULL` (allowed by the terminals CHECK).

**`heartbeat(attempt, *, details=_OMITTED)`** (`:357-382`): details snapshot+encode **before** the transaction (oversize/invalid details never renew, `:534-541`); `_active` fence (below); `deadline = now + heartbeat_timeout*1000`, capped by `attempt_deadline`;
```sql
UPDATE impetus_local_dispatch_tasks SET deadline=? WHERE instance=? AND occurrence=?            -- omitted details
UPDATE impetus_local_dispatch_tasks SET deadline=?,details=? WHERE instance=? AND occurrence=?  -- supplied (None → 'null' text)
```
Returns the latest details (stored, or decoded from the new sorted-key encoding). `heartbeat_timeout` is read from the **stored** invocation.

**`_active` fence** (`:500-528`):
```sql
SELECT queue,invocation,epoch,claimant,deadline,details,attempt_deadline FROM impetus_local_dispatch_tasks WHERE instance=? AND occurrence=?
SELECT 1 FROM impetus_local_dispatch_terminals WHERE instance=? AND occurrence=?
SELECT 1 FROM impetus_local_dispatch_cancellations WHERE instance=? AND occurrence=?
```
Stale (`ValueError("stale Activity attempt <attempt_id>")`) unless: row exists, no terminal, no cancellation, `queue == attempt.queue`, invocation text `== encode(attempt.invocation)` (tampered policy/queue refused, `:458-479`), `str(epoch) == attempt.epoch`, `claimant ==`, `deadline > now`. `_attempt_key` parses `attempt_id` as a 2-element JSON list and requires `attempt.instance` to match.

**`complete(attempt, result)`** (`:384-385, 442-453`): outcome `{"kind":"completed","value":_faithful(result)}`; in one transaction: `_acknowledge_terminal_retry` →
```sql
SELECT epoch,claimant,outcome FROM impetus_local_dispatch_terminals WHERE instance=? AND occurrence=?
```
if a terminal exists: exact `(int(epoch), claimant, encoded_outcome_text)` match → acknowledged (`"terminal-retry"`), else `ValueError("conflicting terminal report for Activity attempt …")`; elif cancelled (`_cancelled_attempt`, `:531-548`: `SELECT 1 FROM impetus_local_dispatch_cancellations …` then `SELECT queue,invocation,epoch,claimant FROM impetus_local_dispatch_tasks WHERE instance=? AND occurrence=?` must equal the attempt exactly — **lease expiry is not checked**) → insert terminal (`"cancelled-report"`: the late, possibly effectful result is transported for canonical `ActivityTerminalQuarantined`); else `_active` then insert:
```sql
INSERT INTO impetus_local_dispatch_terminals(instance,occurrence,epoch,claimant,outcome) VALUES(?,?,?,?,?)
```

**`fail(attempt, error)`** (`:387-440`): `str` → `ActivityFailure(error, kind="ActivityError", retryable=False)` but **legacy-retryable** (a bare string still retries); `Exception` → `ActivityFailure(repr(error), kind=type(error).__name__, retryable=True)` — note **`repr`**, e.g. `"ValueError('boom')"` (verified; Absurd uses `str`); `ActivityFailure` as-is. Outcome `{"kind":"failed","failure":_failure_wire(f)}`. Same ack/cancelled branches; else `_active`, then
```sql
SELECT json_extract(invocation,'$.policy.attempts') FROM impetus_local_dispatch_tasks WHERE instance=? AND occurrence=?
SELECT schedule_start FROM impetus_local_dispatch_tasks WHERE instance=? AND occurrence=?
```
`delay = max(retry_policy.delay(int(epoch)), retry_after or 0)` (policy from the **attempt's** invocation), `available = now + ms(delay)`; retry iff `(retryable or legacy_str) and epoch < attempts and (no schedule deadline or available < schedule_start + ms(schedule_to_close))`:
```sql
UPDATE impetus_local_dispatch_tasks SET deadline=?,available_at=? WHERE instance=? AND occurrence=?   -- deadline=now (lease ends), available_at=available; epoch kept as fence
```
else insert the terminal.

**`wait(timeout)`** (`:463-494`): loop: `BEGIN IMMEDIATE`, `_terminalize_exhausted`, then
```sql
SELECT 1 FROM impetus_local_dispatch_tasks t LEFT JOIN impetus_local_dispatch_terminals x USING(instance,occurrence) LEFT JOIN impetus_local_dispatch_cancellations c USING(instance,occurrence) WHERE x.occurrence IS NULL AND c.occurrence IS NULL AND t.queue IN (?,…) AND t.epoch < json_extract(t.invocation,'$.policy.attempts') AND t.available_at<=? AND (t.epoch=0 OR t.deadline<=?) LIMIT 1
```
true if claimable, else sleep `min(0.05, remaining)`.

**JSON encodings** (all stored TEXT; `_encode_json`, `:896-900`):
`json.dumps(v, allow_nan=False, ensure_ascii=False, sort_keys=True, separators=(",", ":"))`.
- invocation (`:903-922`), e.g. (verified): `{"activity":"w","correlation":null,"idempotency":null,"input":null,"policy":{"attempts":2,"coefficient":2,"heartbeat_timeout":30,"initial_interval":1,"jitter":0,"max_interval":60,"schedule_to_close":null,"start_to_close":null}}`
- outcome completed: `{"kind":"completed","value":<result>}`; failed: `{"failure":{"details":…,"error":…,"kind":…,"retry_after":…,"retryable":…},"kind":"failed"}` (verified: `{"failure":{"details":null,"error":"ValueError('boom')","kind":"ValueError","retry_after":null,"retryable":true},"kind":"failed"}`); legacy read-only `{"kind":"failed","error":E}`.
- details: sorted-key compact JSON; heartbeat `details=None` stores the text `null` (column NOT SQL NULL).
- attempt id: `["instance",occurrence]` compact, `ensure_ascii=False`, not sorted (a list).
- Decoder `_decode_invocation` (`:925-953`): exact 5 top-level fields; policy exactly legacy 2 or current 8 fields; `attempts`/`heartbeat_timeout` non-bool ints; errors prefixed `"corrupt durable Activity invocation: "`.

#### 3. Concurrency & durability semantics

- **Serialization**: every mutating operation is one `BEGIN IMMEDIATE` transaction (SQLite RESERVED lock, writers serialized across processes); `busy_timeout=5000` and Python `timeout=5`; WAL + `synchronous=FULL` (durable at commit). Connections are per-operation (fork/spawn safety: "no SQLite connection is inherited by a child", `:1-8`), so objects are safe to construct before `multiprocessing` spawn; schema init is atomic under 8 concurrent spawned processes (`:182-195`); 4 spawned claimers distribute 24 tasks exactly once (`:738-756`).
- **Lease/fencing**: fence = `(instance, occurrence, queue, exact invocation text, epoch, claimant)` + `deadline > now`. Epoch increments only on claim. A lease is re-claimable when `deadline <= now` (expiry is inclusive); a retryable fail sets `deadline=now` (immediately expired) and `available_at` for backoff.
- **Backoff anchoring**: expiry sweep sets `available_at = expiry + ms(delay(epoch))` for every expired, non-exhausted row, **on every sweep**. Upstream quirk (verified with a manual clock): after `fail(..., ActivityFailure(retryable=True, retry_after=100))` with `initial_interval=1`, `available_at` is first `now+100000` but the next `claim`/`wait` sweep rewrites it to `now+1000`, so a `retry_after` floor larger than the policy delay is lost in Local Dispatch. Must be preserved for parity (or reported upstream).
- **Deadlines**: `start_to_close` caps each lease (`attempt_deadline`); `schedule_to_close` is an aggregate deadline from `schedule_start` and terminalizes even a currently-held lease (the holder's later `complete` then gets "conflicting terminal report"). Exhausted attempts (`epoch >= attempts` and expired) terminalize as `DeadlineExceeded` with the last claimant.
- **Idempotency**: publication keyed `(instance, occurrence)`; terminal reports idempotent on exact `(epoch, claimant, outcome text)`; cancellation idempotent on `(instance, occurrence)` with exact `(history_position, invocation)`.
- **Cancellation**: durable tombstone row; a cancelled task is never claimable, heartbeats are stale, but the fenced claimant's terminal report is accepted once (quarantine path). Dispositions per 2.
- **Crash recovery**: session sets are in memory; a restarted engine re-`dispatch`es its outbox (`ActivityRequested` without terminal) — rows are reused, routes re-pointed only when not live, results re-collected (`:544-561`, `:795-821`, `:857-885`).
- **Clock**: default is the DB clock (ms from `strftime`); a custom clock is sampled under a lock and must be monotone per reader; the clock is sampled **inside** the transaction.
- **Threading**: synchronous; `wait`/`wait_for_results` poll at 50 ms. No NOTIFY equivalent.

#### 4. External dependencies

Python `sqlite3` (bundled SQLite with JSON1: `json_valid`, `json_extract`), `uuid`, telemetry. Haskell:
- `direct-sqlite` (exact statement text, `BEGIN IMMEDIATE`, `busy_timeout`, `changes`) — make sure the bundled amalgamation has JSON1 (it is built in from SQLite 3.38; direct-sqlite also has a `json1` flag) — or `sqlite-simple` over it. Avoid ORMs (`persistent`) that rewrite DDL.
- `uuid` (`Data.UUID.V4`) for claimants; `petrus-json` for every encoding (sort_keys, `ensure_ascii=False`, CPython float repr, int/float distinction); `time`/`clock` for monotonic waits.
- No gaps.

#### 5. Upstream tests

`tests/petrus/motus/dispatch/test_local_dispatch.py`: 36 functions (41 collected: clock `value`×5, terminal `operation`×2). No Postgres/network. Uses `multiprocessing.get_context("spawn")` (2 tests), `threading` with a real `Worker` (1), `Engine`/`JsonlHistoryStore`/`SqliteHistoryStore` (5 engine-level tests: reconciliation of a canonical request missing from custody, close-scope quarantine, re-collect after acceptance refusal, co-residence). Groups: schema create/reopen/refuse (unversioned, version 99, foreign index), v1→v3 and v2→v3 migrations, cancellation dispositions and fencing, routing/re-routing, heartbeat details semantics and tamper refusal, ms rounding, provider clock validation/monotonicity, retry/backoff/nonretryable/schedule/start-to-close deadlines, exact terminal retry/conflict, corrupt invocation, contention, stale fencing after reassignment, `wait` sweeping. Several tests mutate rows with raw SQL (`UPDATE … SET deadline=unixepoch('now')*1000`), so the Haskell suite needs the same direct table access. One test waits for a wall-clock second boundary (`:482-490`).
Also `test_attempt_heartbeats.py:22-60` (pure attempt state model).

#### 6. Performance

Hot paths: `claim` (sweep = two scans of all rows in the worker's queues, across every instance, with `json_extract` + one claim query; per-operation connection open + 4 PRAGMAs + WAL check), `heartbeat`, `complete`. `collect` builds an `IN (?,…)` list of all uncollected occurrences (watch SQLite's 32766 host-parameter limit for huge sessions — same limit applies to Haskell). Benchmark: one SQLite file on the same disk, `synchronous=FULL`, WAL; workload A: dispatch 10k invocations (1 instance, 1 queue) then 1/4/8 worker processes claim→complete until drained (throughput, p50/p99 claim latency); workload B: 1k leases heartbeating with 1 KiB details; workload C: collect 10k terminals. Keep statement text and per-operation transaction boundaries identical; report separately "per-op connection (parity)" vs "pooled connection" modes since connection reuse is the main legitimate Haskell win.

#### 7. Better-the-Haskell-way

- Keep one long-lived `Database` handle per object instead of reconnecting per operation (no fork hazard in Haskell; `forkProcess` is not used) but serialize use with an `MVar` and keep `BEGIN IMMEDIATE` boundaries; set PRAGMAs once.
- `Fence` record (`instance, occurrence, queue, invocationText, epoch, claimant`) and `AttemptId` parsed once (`Text` JSON `["i",n]` ↔ typed pair), so stale checks are a single comparison.
- `Clock` as `IO Int64` wrapped in a monotone reader (`IORef` + `atomicModifyIORef'`), not a lock.
- Precompute and cache the `IN (?,…)` statements per queue-count; prepared statements via `direct-sqlite` `prepare`/`reset`.
- `Outcome`/`FailureWire` ADTs with hand-written petrus-json encoders that reproduce `sort_keys` order (or rely on petrus-json's sorted-object encoder).
- Quirks to preserve: string `fail` is legacy-retryable; Exception failures use `repr`-style text (in Haskell define the analogous rendering for Haskell exceptions, but Python-produced rows must decode unchanged); the `retry_after` overwrite in the sweep; text-exact invocation comparison; `INSERT OR IGNORE` for deadline terminals; DeadlineExceeded message wording ("attempt"/"attempts").

#### 8. Packaging

`petrus-dispatch-local` (or module `Petrus.Motus.Dispatch.Local` in `petrus-motus-dispatch`), depends on `petrus-motus-activity`, `petrus-json`, `direct-sqlite`, telemetry facade. No kernel dependency (only the engine-level tests need the kernel/Engine/Worker). Shares the SQLite file with `SqliteHistoryStore` (kernel stores agent) — coordinate a common SQLite connection helper (same PRAGMAs) but separate tables. Can be built in parallel with the kernel.

---

### Absurd Dispatch (PostgreSQL) — `petrus.motus.dispatch.absurd` + `absurd_schema/`

Sources: `src/petrus/motus/dispatch/absurd.py` (996 lines),
`src/petrus/motus/dispatch/absurd_schema/absurd-0.4.0.sql` (3086 lines, vendored
verbatim), composed by `src/petrus/engine/absurd.py` (section 6).
Optional extra `absurd = ["absurd-sdk==0.4.0", "petrus-runtime[postgres]"]`
(`pyproject.toml:32-38`).

#### 1. Responsibility & public API

- Constants: `ABSURD_VERSION="0.4.0"`, `ABSURD_COMMIT="05282a40c8dddc378acdc6933adc4c221583808a"`, `ABSURD_SQL_SHA256="c2ed3a301aa2a4782257843e514e8057c3049de5998ea8dc632a1a159464b51c"` (`:90-92`; recomputed locally: matches); `DISPATCH_CHANNEL="impetus_dispatch"`, `RESULTS_CHANNEL="impetus_results"`, `DETAILS_CHECKPOINT="__impetus_latest_activity_details_v1"` (`:98-100`); `_QUEUE_NAME = ^[a-z][a-z0-9_]{0,56}$` (`:106`).
- `validate_queue(q) -> str` (`:115-122`) — error text `"queue 'X' is invalid: a queue name must match … (it becomes the t_/r_/c_/e_/w_ table suffix)"`. Provider-discovered names (from `absurd.list_queues()`, any ≤57-byte name, e.g. `GPU-jobs`) are NOT revalidated and are always quoted via `sql.Identifier`.
- `encode_invocation(inv) -> dict` / `decode_invocation(payload) -> ActivityInvocation` (`:125-206`) — same 5-field wire as Local; strict; legacy 2-field policy accepted; error prefix `"task payload does not decode as an activity invocation"`.
- `_instance_from_key(key) -> str|None` (`:209-224`): `rpartition(":occurrence-")`; non-str or no separator → `None` (foreign task, unscoped); else instance non-empty and occurrence ASCII digits, >0, canonical (no leading zeros) else `ValueError("invalid Petrus Absurd publication identity …")`. `"tenant:occurrence-segment:occurrence-17"` → `"tenant:occurrence-segment"`.
- `GuardedDispatch(connection, *, claimant=None)` (`:227-401`) — worker-side door; requires `autocommit=False`; `claimant` default `str(uuid4())`. `claim(queue, *, timeout)`, `heartbeat(queue, *, task_id, run_id, timeout, details=_OMITTED)`, `terminal(queue, *, task_id, run_id, result=_OMITTED, error=None)`, `latest_details(queue, task_id)`.
- `_ReconnectableGuardedDispatch(dsn, connection, *, claimant)` (`:404-442`) — on `heartbeat` only: if `psycopg.OperationalError`/`InterfaceError` **and** the connection is `closed or broken`, replace the connection once (new `psycopg.connect(dsn, autocommit=False)`, `LISTEN impetus_dispatch`, commit, same claimant) and retry once; semantic errors (QueryCanceled, DeadlockDetected, DataError, ProgrammingError, IntegrityError, stale RuntimeError) are never retried (`test_attempt_heartbeats.py:148-198`).
- `AbsurdWorkerDispatch(dsn, *, queues=("default",), worker_id=None, claim_timeout=30)` (`:445-521`) — implements `WorkerDispatch`; `claimant = f"{worker_id or f'worker-{os.getpid()}'}:{uuid4()}"`. Attempt mapping: `attempt_id=str(task_id)`, `epoch=str(run_id)`, `instance=_instance_from_key(idempotency_key)`. `fail(str)` wraps as `RuntimeError(str)` → kind `"RuntimeError"`, retryable `True` (differs from Local).
- `ensure_absurd_schema(connection)` (`:539-569`), `_pinned_schema()` (`:524-536`).
- `AbsurdDispatch(connection, *, instance, listen=None, poll_interval=0.25, default_queue="default", activity_queues=None)` (`:593-996`) — engine-facing `Dispatch` + `cancel` + `queue_for(activity)` + `wait_for_results`. `listen` must be autocommit. Session state: `_tasks: {occ: (queue, task_id_text)}`, `_cancelled`, `_collected`, `_known_queues`, `_listening`.
- Telemetry (`log = get_logger("impetus")`): `absurd_dispatched(occurrence, activity, queue, task)`, `absurd_cancelled(occurrence, history_position, disposition, queue, task)`, `absurd_collected(results, failures)` (only when non-empty).

**`absurd_sdk` is imported only to validate the optional extra is installed (`:58-67`); no SDK function is called anywhere in `src/` or `tests/`** (grep: only `rule-tests/…yml`, `tests/project/test_package_boundaries.py:464-469`, `tests/dst/boundaries.py:158`). The adapter speaks to Absurd purely through its SQL functions over psycopg. Therefore the Haskell port needs no Absurd SDK: it calls the same SQL functions directly, which is exactly upstream's behaviour. (There is, to my knowledge, no Haskell Absurd SDK — Absurd ships Python/TypeScript SDKs — but none is needed; not verifiable offline.)

#### 2. Wire formats, SQL (verbatim), schema

Identifiers: `sql.Identifier(f"t_{queue}")` renders as a double-quoted identifier (`absurd."t_q"`). Three statements in `GuardedDispatch.terminal` use Python `str.format` without quoting (`absurd.r_q`) — equivalent only because configured queues are lowercase-validated. psycopg sends Python `str` uuids as untyped (`unknown`) parameters that PostgreSQL coerces to `uuid`; a Haskell client must either send untyped (OID 0) text params or add `::uuid` casts. `Jsonb(x)` sends `json.dumps(x)` text typed jsonb; the server normalizes it.

**Schema provisioning** (`ensure_absurd_schema`): (1) read vendored file **bytes**, `sha256` must equal the pin on **every** call (`"vendored absurd-0.4.0.sql hash mismatch: …"`); (2)
```sql
SELECT 1 FROM pg_namespace WHERE nspname = 'absurd'
```
present → `SELECT absurd.get_schema_version()` must succeed (`"…does not answer absurd.get_schema_version()…"`) and equal `'0.4.0'` (`"…a re-pin is a deliberate act [D11]…"`); return. Absent → execute the whole file as one multi-statement text (psycopg with no params ⇒ simple-query protocol; atomic as one implicit transaction under autocommit, or inside the caller's transaction). The file uses plain `create function` (not `or replace`) for most functions, so it is not re-runnable — the namespace probe is what makes `ensure` idempotent. It requires `create extension if not exists "uuid-ossp"` privileges. Test fixture provisions with an **autocommit** connection beside `petrus.impetus.history_store.postgres.ensure_schema` (`conftest.py:166-177`).

**Engine side — `AbsurdDispatch.dispatch(occ, inv)`** (`:670-726`): refuses autocommit connections (`RuntimeError "…cannot run in autocommit mode…"`); cancelled occurrence → drop/conflict; refuses `start_to_close`/`schedule_to_close` (`ValueError "AbsurdDispatch does not support start_to_close or schedule_to_close with the pinned provider…"`); `queue = queue_for(activity)`; `_recover_custody` (below); if no live custody:
```sql
SELECT absurd.create_queue(%s)                     -- once per session per queue (_known_queues)
SELECT task_id, run_id, attempt, created FROM absurd.spawn_task(%s, %s, %s, %s)   -- (queue, inv.activity, Jsonb(encode_invocation(inv)), Jsonb(options))
SELECT pg_notify(%s, %s)                           -- ('impetus_dispatch', queue), inside the same open transaction
```
`options = {"idempotency_key": f"{instance}:occurrence-{occ}", "max_attempts": inv.policy.attempts, "retry_strategy": {"kind": "none"}}` (no `headers`, no `cancellation`). Task `params` = the invocation wire object; `task_name` = activity name.

**`_recover_custody(occ, target, inv)`** (`:826-908`) — K4 lookup-first, all in the caller's transaction:
```sql
SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))      -- key = "{instance}:occurrence-{occ}"
SELECT queue_name FROM absurd.list_queues()
-- for each queue:
SELECT task_id::text, state, first_started_at, last_attempt_run::text, (SELECT state FROM absurd."r_<q>" r WHERE r.run_id = t.last_attempt_run) FROM absurd."t_<q>" t WHERE idempotency_key = %s
SELECT task_name,params FROM absurd."t_<q>" WHERE task_id=%s       -- for the single live row
SELECT state FROM absurd."r_<q>" WHERE run_id = %s FOR UPDATE NOWAIT
SELECT state, first_started_at, last_attempt_run::text FROM absurd."t_<q>" WHERE task_id = %s FOR UPDATE NOWAIT
SELECT absurd.cancel_task(%s, %s)                              -- (old queue, task_id): the transfer tombstone
```
Decision table: live = non-`cancelled` rows across all queues. Target-queue tombstone and no live → `RuntimeError "cannot establish Absurd custody … cancelled tombstone"`; no live → `None` (spawn); >1 live → `"ambiguous Absurd custody for KEY: found N live tasks across provider queues"`; live row's `task_name`/canonical params must match (`"Absurd publication conflict for KEY: …"`, comparison `_canonical_json(encode(decode(params)))` so legacy policies normalize); live terminal (`completed`/`failed`) → requires `last_attempt_run` present and run state == task state (`"…terminal state is invalid…"`), returns it **wherever it lives** (terminal wins over routing); target tombstone with non-terminal live → refuse; same queue → keep; different queue → requires run `pending` and task `('pending', None, run_id)` (never started) under `NOWAIT` locks (`LockNotAvailable` 55P03 → `"…custody is currently locked"`; else `"…only one pending/pending never-started task may move…"`), then `cancel_task` old and return `None` so a new task is spawned on the target with the **same** idempotency key.

**`AbsurdDispatch.cancel(instr)`** (`:728-782`): refuses autocommit; session prior → ACKNOWLEDGED/conflict;
```sql
SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))
SELECT queue_name FROM absurd.list_queues()
SELECT task_id::text, state, first_started_at, last_attempt_run::text, (SELECT state FROM absurd."r_<q>" r WHERE r.run_id = t.last_attempt_run) FROM absurd."t_<q>" t WHERE idempotency_key = %s
SELECT task_name,params FROM absurd."t_<q>" WHERE task_id=%s           -- _verify_custody_invocation
SELECT task_id::text, state, first_started_at, last_attempt_run::text, (SELECT state FROM absurd."r_<q>" r WHERE r.run_id = t.last_attempt_run) FROM absurd."t_<q>" t WHERE task_id = %s   -- _custody after materializing
SELECT absurd.cancel_task(%s, %s)
```
>1 live → ambiguous; no live but tombstones → verify each, `ACKNOWLEDGED`; nothing at all → **materialize via `dispatch` then cancel** in the same transaction (so absent publication yields `RETIRED`, not Local's `TOMBSTONED`; test `:347-363`); live `completed`/`failed` → `TERMINAL` (kept collectable); `pending` → `RETIRED`; `running`/`sleeping` → `FENCED`. No NOTIFY on cancel.

**`collect()`** (`:910-951`) per queue (sorted) over this session's uncollected `_tasks`:
```sql
SELECT t.task_id::text, t.state, t.completed_payload, r.failure_reason, coalesce(r.completed_at, r.failed_at, r.created_at) FROM absurd."t_<q>" t LEFT JOIN absurd."r_<q>" r ON r.run_id = t.last_attempt_run WHERE t.task_id = ANY(%s::uuid[]) AND t.state IN ('completed', 'failed', 'cancelled')
```
`cancelled` → `RuntimeError` ("a custody tombstone is not an activity outcome"); `completed` → `completed_payload` verbatim; `failed` → `_decode_failure(failure_reason)`. Global sort by `(terminal_at, occurrence)` = completion order.

**Failure reason JSON** written by Petrus (`GuardedDispatch.terminal`, `:301-312`):
`{"petrus_failure": 1, "name": kind, "message": error, "details": …, "retryable": bool, "retry_after": number|null}` (jsonb ⇒ key order irrelevant). `_decode_failure` (`:581-590`): `reason.get("petrus_failure") == 1` (Python equality: `true`/`1.0` also match) → `ActivityFailure(message, name, details, retryable, retry_after)`; otherwise `ActivityFailure(_spell_failure(reason))` = `"name: message"` (or `name` if message falsy) when `"name"` in a mapping, else `json.dumps(reason)` with **default separators** (`", "`, `": "`). Absurd's own lease-expiry reason: `{"name":"$ClaimTimeout","message":"worker did not finish task within claim interval","workerId":…,"claimExpiredAt":…,"attempt":…}` → `"$ClaimTimeout: worker did not finish task within claim interval"`.

**`wait_for_results(timeout)`** (`:953-996`): first call `LISTEN impetus_results` on `listen`; loop: probe (on `listen` if given, else the joined connection)
```sql
SELECT 1 FROM absurd."t_<q>" WHERE task_id = ANY(%s::uuid[]) AND state IN ('completed', 'failed', 'cancelled') LIMIT 1
```
then block on `listen.notifies(timeout=min(poll_interval, remaining), stop_after=1)` or `sleep`. Payload ignored (wake hint).

**Worker side — `GuardedDispatch.claim(queue, *, timeout)`** (`:236-262`), one transaction, commit (or commit-on-empty), rollback on error:
```sql
SELECT * FROM absurd.claim_task(%s, %s, %s, 1)                 -- (queue, claimant, claim_timeout)
SELECT idempotency_key FROM absurd."t_<q>" WHERE task_id=%s
SELECT absurd.extend_claim(%s, %s, %s)                         -- (queue, run_id, policy.heartbeat_timeout): lease := now + heartbeat_timeout
SELECT state FROM absurd.get_task_checkpoint_state(%s, %s, %s) -- (queue, task_id, '__impetus_latest_activity_details_v1') → latest_details
```
`claim_task` columns: `run_id, task_id, attempt, task_name, params, retry_strategy, max_attempts, headers, wake_event, event_payload`. A params decode failure rolls the claim back (task stays pending; poison redelivered forever — quirk). `AbsurdWorkerDispatch.claim` tries queues in configured order.

**`GuardedDispatch.heartbeat`** (`:264-281`): details snapshot first (invalid/oversize fails before any lease change); `_guard`:
```sql
SELECT task_id, state, claimed_by, claim_expires_at, claim_expires_at > absurd.current_time() FROM absurd."r_<q>" WHERE run_id = %s FOR UPDATE
```
stale unless `task_id` matches, `state='running'`, `claimed_by == claimant`, unexpired → `RuntimeError("stale Activity Attempt: …")`. Then
```sql
SELECT absurd.set_task_checkpoint_state(%s, %s, %s, %s, %s, %s)   -- (queue, task_id, DETAILS_CHECKPOINT, Jsonb(snapshot), run_id, timeout): writes details AND extends the claim atomically
SELECT absurd.extend_claim(%s, %s, %s)                             -- omitted details: (queue, run_id, timeout)
SELECT state FROM absurd.get_task_checkpoint_state(%s, %s, %s)     -- omitted: return current details
```
`details=None` is stored as JSONB `null` (not SQL NULL; `status='committed'`, `owner_run_id=run_id`, test `:1444-1479`). Details and lease commit or roll back together (`:1347-1400`).

**`GuardedDispatch.terminal`** (`:283-351`): `error` → `ActivityFailure` (Exception → `ActivityFailure(str(e), kind=type name, retryable=True)`); `_guard_terminal`:
```sql
SELECT r.task_id,r.state,r.claimed_by,r.claim_expires_at,r.claim_expires_at > absurd.current_time(),r.result,r.failure_reason,t.state FROM absurd."r_<q>" r JOIN absurd."t_<q>" t USING(task_id) WHERE r.run_id=%s FOR UPDATE OF r
```
identity/claimant mismatch → stale; run `completed` (task must be `completed`) with canonically equal result → acknowledged; run `failed` with a `petrus_failure==1` reason canonically equal → acknowledged (also after a retry advanced the task); otherwise `ValueError("conflicting terminal report")`; non-running/expired → stale. Success:
```sql
SELECT absurd.complete_run(%s, %s, %s)            -- (queue, run_id, Jsonb(result))
```
Failure:
```sql
SELECT attempt, absurd.current_time() FROM absurd.r_<q> WHERE run_id=%s
SELECT t.params FROM absurd.t_<q> t JOIN absurd.r_<q> r USING(task_id) WHERE r.run_id=%s
UPDATE absurd.t_<q> t SET max_attempts=%s FROM absurd.r_<q> r WHERE r.run_id=%s AND t.task_id=r.task_id   -- only if NOT retryable: max_attempts := attempt (forces terminal)
SELECT absurd.fail_run(%s, %s, %s, %s)            -- (queue, run_id, Jsonb(reason), retry_at)
```
`delay = max(policy.retry_policy.delay(attempt), retry_after or 0)`; `retry_at = provider_now + timedelta(seconds=delay)` if retryable else `NULL` (Petrus backoff computed on provider time; `retry_strategy` stays `none`). Then `commit`. `AbsurdWorkerDispatch.complete/fail` then ring the results doorbell in a separate transaction:
```sql
SELECT pg_notify(%s, %s)        -- ('impetus_results', queue); commit
```
`AbsurdWorkerDispatch.__init__`: `SELECT absurd.create_queue(%s)` per queue, commit, `LISTEN impetus_dispatch`, commit. `wait(timeout)`: `connection.notifies(timeout, stop_after=1)` → True on any notification.

**Absurd 0.4.0 schema elements the adapter relies on** (`absurd-0.4.0.sql`):

| Object | Lines | Behaviour relied on |
| --- | --- | --- |
| `absurd.current_time()` | `:39-54` | `clock_timestamp()` unless session setting `absurd.fake_now` is set (tests can fake time). All lease checks use it. |
| `absurd.queues(queue_name pk, storage_mode 'unpartitioned'|'partitioned', …policy cols)` | `:56-77` | registry; `list_queues()` (`:381-386`) returns names ordered. |
| `get_schema_version()` → `'0.4.0'` | `:81-86` | version pin. |
| `validate_queue_name` (non-empty, ≤57 bytes) / `ensure_queue_tables` | `:92-289` | per queue: `t_<q>(task_id uuid pk, task_name, params jsonb not null, headers, retry_strategy jsonb, max_attempts int, cancellation jsonb, enqueue_at, first_started_at, state ∈ pending/running/sleeping/completed/failed/cancelled, attempts, last_attempt_run uuid, completed_payload jsonb, cancelled_at, idempotency_key text unique)`; `r_<q>(run_id uuid pk, task_id, attempt, state, claimed_by, claim_expires_at, available_at, wake_event, event_payload, started_at, completed_at, failed_at, result jsonb, failure_reason jsonb, created_at)`; `c_<q>(task_id, checkpoint_name, state jsonb, status default 'committed', owner_run_id, updated_at, pk(task_id, checkpoint_name))`; `e_<q>`, `w_<q>`; fillfactor 70; indexes `r_<q>_sai(state, available_at)`, `_ti`, `_cei` (partial on running claims). Partitioned mode adds `i_<q>` — Petrus only creates unpartitioned queues via `create_queue(name)` (`:331-340`). |
| `spawn_task(q, name, params, options)` | `:682-829` | ids from `portable_uuidv7()` (`:2223-2252`; native `uuidv7()` on PG ≥18); options keys `headers, retry_strategy, max_attempts (≥1), cancellation, idempotency_key`; idempotent via `insert … on conflict (idempotency_key) do nothing` → returns existing `(task_id, last_attempt_run, attempts, false)`; new task `pending` + run 1 `pending`, `available_at=now`. |
| `claim_task(q, worker, timeout=30, qty=1)` | `:832-994` | first cancels tasks past `cancellation.max_delay/max_duration`; sweeps ≤qty expired running runs (`for update skip locked`) via `fail_run(…, $ClaimTimeout reason, NULL)` (**a crashed worker spends an attempt and is retried immediately — Petrus backoff not applied**); then claims oldest `(available_at, run_id)` pending/sleeping run whose task is pending/sleeping/running (`for update skip locked`), sets run `running, claimed_by, claim_expires_at=now+timeout, started_at`, task `running, attempts, first_started_at, last_attempt_run`. |
| `complete_run(q, run, state)` | `:997-1056` | `for update` on run; non-running → error (`AB001` cancelled, `AB002` failed); run+task `completed`, `completed_payload`. |
| `fail_run(q, run, reason, retry_at)` | `:1105-1267` | run `failed` + `failure_reason`; if `max_attempts` null or `attempt+1 ≤ max_attempts`: new run (attempt+1) `sleeping` if `available > now` else `pending` at `retry_at` (or strategy delay; `none` → 0); else task `failed`. Lock order runs→task. |
| `extend_claim(q, run, secs)` | `:1482-1542` | requires running + active claim; `claim_expires_at = now + secs` (absolute, can shorten). |
| `set_task_checkpoint_state(q, task, step, state, owner_run, extend_by)` | `:1395-1479` | refuses cancelled task / failed run; optional claim extension; upsert unless an existing checkpoint belongs to a later attempt. |
| `get_task_checkpoint_state(q, task, step, include_pending=false)` | `:1545-1571` | committed row → `state`. |
| `cancel_task(q, task)` | `:1911-1976` | locks active runs then task; terminal states untouched (no-op); else task `cancelled`, active runs `cancelled` with `claimed_by/claim_expires_at` NULL (→ the claimant's guard sees a foreign claimant ⇒ stale). |

Not used: `drop_queue`, `get_task_result`, `schedule_run`, `retry_task`, events/`await_event`/`emit_event`, cleanup, partitions, cron.

Env/infra: none in production code (DSN passed in). Tests: `postgres:17.5-alpine@sha256:6567bca8d7bc8c82c5922425a0baee57be8402df92bae5eacad5f01ae9544daa` (tmpfs, per xdist worker, `conftest.py:23-160`).

#### 3. Concurrency & durability semantics

- **D11 joined transaction**: the engine's connection is `autocommit=False` and shared with the Postgres history store; begin batch + `spawn_task` + `pg_notify('impetus_dispatch', queue)` commit or vanish together; NOTIFY is delivered only on commit (no phantom wakes, test `:431-464`). The engine owns commit/rollback; any failure poisons the composition (section 6).
- **Per-occurrence mutex**: `pg_advisory_xact_lock(hashtextextended(key, 0))` in both dispatch-recovery and cancel; released at commit. Concurrent recoveries serialize to exactly one target custodian (`:1043-1067`).
- **Row locks**: custody transfer uses `FOR UPDATE NOWAIT` (run first, then task — same order as Absurd's own functions), so a concurrent `claim_task` either wins (recovery refuses "currently locked") or is skipped (`skip locked`) and finds nothing (`:976-1041`); no deadlock against task-first lockers (`:913-931`).
- **Leases/fencing**: fence = `(run_id, claimed_by == claimant, state running, claim_expires_at > absurd.current_time())`, checked under `FOR UPDATE` before every heartbeat/terminal. Initial lease from `claim_task(timeout=claim_timeout)` is immediately reset to `heartbeat_timeout` via `extend_claim`. Lease expiry is swept by later `claim_task` calls (`$ClaimTimeout` failure, immediate retry, counts as an attempt).
- **Retries**: Petrus-computed `retry_at` on provider time; non-retryable failures force `max_attempts = attempt`. Deadlines (`start_to_close`, `schedule_to_close`) are refused at dispatch.
- **Idempotency**: spawn keyed by `"{instance}:occurrence-{occ}"`; terminal reports acknowledged on canonical equality (`_canonical_json` = `json.dumps(allow_nan=False, ensure_ascii=False, sort_keys=True, separators=(",",":"))`, type-sensitive: `[True]` vs `[1]` conflict).
- **Doorbells**: `impetus_dispatch` (authority→workers, payload queue, inside spawn txn) and `impetus_results` (worker→authority, payload queue, after terminal commit). Both lossy hints; polling (`poll_interval` 0.25 s default; worker `AsyncWorker`/`Worker` poll loops) is the safety net.
- **Recovery**: Absurd state is operational and reconstructible; lost tasks are respawned from the canonical outbox under the same key (at-least-once; `:628-641`); completed tasks are collected, never re-run.
- **Threading**: each `AbsurdWorkerDispatch` owns one connection and is single-threaded; `AsyncWorker` uses N provider lanes each with its own `WorkerDispatch` (section 8). The heartbeat transport reconnects once on a dead connection, same claimant.
- **jsonb normalization quirk (by reasoning, not executed here)**: values cross jsonb and come back through `json.loads` of PostgreSQL's text output. Key order is lost (fine), and a float Python spells with a positive exponent (`1e+16`, any float ≥ 1e16) comes back as an integer (`10000000000000000`) — so results/inputs can change int/float type through Absurd, and a redispatch of such an invocation would hit "publication conflict". `\u0000` in strings is rejected by jsonb. A Haskell client must decode jsonb text with petrus-json's Python-`json.loads` semantics to reproduce exactly.

#### 4. External dependencies

Python: `psycopg` 3 (connections, `sql.Identifier`, `Jsonb`, `notifies()`, error classes `OperationalError`, `InterfaceError`, `errors.LockNotAvailable`), `absurd-sdk==0.4.0` (import-only), PostgreSQL (tests pin 17.5; the schema switches to native `uuidv7()` on 18+, no minimum is declared upstream), extension `uuid-ossp`.
Haskell:
- `postgresql-libpq` as the base (needed anyway for `PQexec` of the multi-statement schema, `LISTEN`/`notifies` with `threadWaitRead` on the socket, SQLSTATE inspection `55P03`, `AB001`, `AB002`, connection status for reconnect). On top, either `postgresql-simple` (has `Notification` helpers and `execute_` multi-statement) or `hasql` + `hasql-notifications`; pick whatever the Postgres history-store port uses, because **the engine's joined transaction must be the same connection object** for history and dispatch.
- Identifier quoting: a small `quoteIdent` (double quotes, doubled inner quotes) — postgresql-simple has `Identifier`/`QualifiedIdentifier`.
- `uuid`, `time` (`UTCTime`; `timedelta(seconds=float)` rounds to microseconds half-even — mirror when computing `retry_at`), `cryptohash-sha256` or `crypton` (`Crypto.Hash.SHA256`) for the pin, `file-embed` to embed the vendored SQL bytes (keep the file byte-identical; verify the hash at runtime on every ensure call, optionally also at compile time).
- No Haskell Absurd SDK exists to my knowledge, and none is needed (see 1). Keeping a Python helper is not warranted.

#### 5. Upstream tests

- `tests/petrus/motus/dispatch/test_absurd_adapter.py`: 78 functions (~103 collected: identity keys ×4/×3, deadline field ×2, terminal ×2, broken ×2, state ×2, retryable ×2, operation×cause 4×4). **All except the 3 `_instance_from_key` tests, `TestInvocationWire` (4), `test_a_capability_that_cannot_be_a_queue_name_is_refused_loud` and `test_the_vendored_schema_matches_the_triple_pin` need Docker Postgres** via the `absurd_dsn`/`postgres_dsn` session fixtures in root `conftest.py:73-177` (fails loud, never skips, when Docker is absent). Fixtures: `observer` (autocommit), `authority` (join mode), `listener` (autocommit), `queue` (`q_<10 hex>`), `scratch_database` (CREATE/DROP DATABASE). Groups (functions): module-level AsyncWorker integration + publication-identity parsing (4), `TestSchemaPin` (7), `TestQueueMapping` (3), `TestInvocationWire` (4), `TestDispatch` — dispatch, cancellation, doorbell/rollback (11), `TestCollect` (4), `TestLookupFirstRedispatch` — K4 lookup-first & custody transfer incl. real races with threads (26), `TestWaitForResults` (3), `TestAdapterShape` (3), `TestGuardedAttemptDispatch` (13, incl. the 4×4 stale-cause matrix). Tests mutate Absurd tables directly (`UPDATE absurd.t_… SET state…`) and call `absurd.claim_task/complete_run/fail_run` raw.
- `tests/petrus/motus/dispatch/test_attempt_heartbeats.py`: 8 functions (20 collected); no Docker, but imports `psycopg` and `_ReconnectableGuardedDispatch` (reconnect policy unit tests with fakes).
- `tests/absurd_support.py` (183 lines, not a test file): the DS4 topology net (`inbox → work(spark_work activity) → worked`, `operator → approvals`, `approve → done`, completion `size(done) != 0`), `SparkWork` handler (`prepare`: `ActivityInvocation("spark_work", input=dict(token.data), policy=ExecutionPolicy(attempts=N), idempotency=f"effect-{id}")`; `project` optionally poisoned), and the worker registry `activities()` for `python -m petrus.motus.worker --registry tests.absurd_support:activities`, configured by env `IMPETUS_TEST_DSN`; fixture DDL `CREATE SCHEMA IF NOT EXISTS impetus_test`, `CREATE TABLE IF NOT EXISTS impetus_test.effects (idempotency text PRIMARY KEY)`, `CREATE TABLE IF NOT EXISTS impetus_test.kill_switch (armed boolean NOT NULL)`; activity modes: `heartbeat-long` (2.5 s of 0.2 s heartbeats with `{"beats": n}`), `checkpoint-crash` (heartbeat `{"cursor":7,"first_claimant":…}`, write barrier file, sleep; on redelivery return `"resumed 7"`), `nap`, `boom` (`ValueError`), idempotent effect `INSERT INTO impetus_test.effects (idempotency) VALUES (%s) ON CONFLICT DO NOTHING`, kill switch `UPDATE impetus_test.kill_switch SET armed = FALSE WHERE armed RETURNING 1` then sleep 3600 for SIGKILL. Used by engine/worker kill tests (other fragments); a Haskell worker registry must offer the same activity for cross-language kill tests.

#### 6. Performance

Hot paths: `dispatch` (advisory lock + `list_queues` + one custody query **per existing queue** + spawn + notify — O(#queues) per dispatch), worker `claim` (4 round trips), `heartbeat` (2–3), `terminal` (2–5) — mostly PostgreSQL-bound; client overhead is JSON encode/decode and round-trip count. Benchmark (same PG container, same `postgres:17.5-alpine` digest, tmpfs): (a) dispatch 10k invocations in batches of 1/100 per transaction with 1 and 20 pre-existing queues; (b) 1/4/16 workers claim→heartbeat→complete until drained (throughput, p50/p99 per op, lease-renew latency); (c) collect latency with LISTEN vs pure polling. Keep identical SQL text and round-trip counts for the parity run; optionally measure pipelined (libpq pipeline mode) as a separate "Haskell way" run.

#### 7. Better-the-Haskell-way

- Types: `QueueName` smart constructor (configured, validated) vs `ProviderQueueName` (discovered, quoted-only); `TaskId`/`RunId` as `UUID`; `PublicationKey` with a parser identical to `_instance_from_key`; `Custody` ADT (`Pending | Running | Sleeping | Completed | Failed | Cancelled`) for the recovery decision table.
- Model the joined transaction as a capability (`JoinedTx` token) so `dispatch`/`cancel` cannot be called on an autocommit connection (upstream checks at runtime).
- Use `bracket`/`mask` for every claim/heartbeat/terminal transaction (commit or rollback, never leak an open transaction); `async` + `threadWaitRead` for `wait`/`wait_for_results` rather than polling sleeps (keep the poll as safety net).
- Embed the pinned schema with `file-embed` and verify `sha256` with `crypton`; expose `ensureAbsurdSchema` with the same refusals.
- Quirks to preserve: `fail(str)` → `RuntimeError`/retryable; Exception → `str(e)` (Local uses `repr`); `_spell_failure` uses `json.dumps` default separators; `petrus_failure == 1` Python-equality; absent-publication cancel returns `RETIRED`; collect refuses `cancelled`; `$ClaimTimeout` retries immediately; decode-failure poison loop; unquoted `absurd.r_<q>` in three statements.

#### 8. Packaging

`petrus-dispatch-absurd` (optional package, mirroring the optional extra), with the vendored `absurd-0.4.0.sql` as an embedded data file. Depends on `petrus-motus-activity`, `petrus-motus-dispatch` (values/protocols), `petrus-json`, and the shared Postgres connection layer used by the Postgres history store (kernel stores agent) — the only cross-component coupling, required for the D11 joined transaction. `petrus-engine-absurd` (engine fragment) composes it with the history store. Can be built in parallel with the kernel once the Postgres connection abstraction is agreed; the 6 schema-pin tests and the wire/identity tests can run before any kernel exists.

## 8. Workers and the ZeroMQ transport

### Workers (`motus/worker`)

Sources: `src/petrus/motus/worker/__init__.py` (673 lines), `src/petrus/motus/worker/_cli.py` (146), `src/petrus/motus/worker/__main__.py` (5). Design records: `docs/project/decisions/records/2026-07-28T1052Z-local-dispatch-and-worker-provider-boundary.md`, `2026-07-28T1907Z-async-worker-custody-stays-private.md`, `2026-08-10T1200Z-instance-identity-scopes-shared-activity-resolution.md`; user docs `docs/runtime-guide.md:100-131`.

The Worker is **Petri-agnostic**: it imports only `petrus.motus.activity`, `petrus.motus.dispatch` (values + `WorkerDispatch` protocol) and `petrus.telemetry`. `tests/project/test_package_boundaries.py:272-283` asserts that importing the petrinet never loads `petrus.motus.worker`; `:460-475` asserts that `import petrus.motus.worker` loads neither `zmq`, `absurd_sdk`, `petrus.motus.dispatch.absurd` nor `petrus.motus.transport.zeromq` (providers are imported lazily inside the CLI factory).

#### 1. Responsibility & public API

Exports (`__init__.py:673`): `Worker`, `AsyncWorker`, `ActivityExecutionContext`, `AsyncActivityExecutionContext`. Private but used elsewhere: `_validate_registry`, `_AsyncWorkerAccess` (the CLI and the ZeroMQ transport use them), `AsyncWorker._from_async_access`.

**Values consumed (owned by the Activities/Dispatch components, not the kernel):**

| Name | Source | Fields used |
|---|---|---|
| `ActivityAttempt` (frozen) | `src/petrus/motus/dispatch/__init__.py:24-40` | `attempt_id: str`, `epoch: str`, `claimant: str`, `queue: str`, `invocation: ActivityInvocation`, `latest_details: object = None` (normalised by `snapshot_heartbeat_details`), `instance: str \| None = None` (non-empty if present) |
| `WorkerDispatch` (`@runtime_checkable Protocol`) | `dispatch/__init__.py:68-82` | `claim() -> ActivityAttempt\|None`, `heartbeat(attempt, *, details=_OMITTED) -> object`, `complete(attempt, result) -> None`, `fail(attempt, error: str\|Exception\|ActivityFailure) -> None`, `wait(timeout: float) -> bool`, `close() -> None` |
| `ActivityInvocation` | `activity/__init__.py:353-372` | `activity: str`, `input`, `policy: ExecutionPolicy`, `correlation`, `idempotency` |
| `ActivityFailure`, `ActivityError` | `activity/__init__.py:385-433` | `ActivityError(...).failure: ActivityFailure` |
| `_OMITTED` sentinel | `activity/__init__.py:15` | "details not supplied" ≠ `details=None` |
| `snapshot_heartbeat_details` | `activity/__init__.py:18-42` | JSON-faithful detach; ≤ 65,536 UTF-8 bytes in `json.dumps(..., allow_nan=False, ensure_ascii=False, separators=(",", ":"))` |
| `AsyncActivityDefinition` | `activity/__init__.py:198-250` | sync/async classification |
| `telemetry.get_logger("impetus")`, `log.emit`, `log.span`, `telemetry.max_rss_mb()` | `src/petrus/telemetry.py:146-205,235-239,267` | events below |

No `petrus.impetus.*` API is used by the Worker.

**Registry helpers**

- `_is_async_activity(value) -> bool` (`__init__.py:32-39`): true for `AsyncActivityDefinition`, a coroutine function, or an object whose `__call__` is a coroutine function.
- `_validate_registry(activities, *, asynchronous) -> dict` (`:42-51`): snapshot copy (`dict(activities)`; later mutation of the caller's mapping is invisible — `test_worker_topology.py::test_worker_and_loader_snapshot_mutable_registries`); every key a non-empty `str` and every value callable, else `ValueError("Worker activities must map non-empty string names to callables")`; wrong-mode entries → `TypeError(f"Worker requires {asynchronous|synchronous} Activities{hint}; wrong-mode registry entries: {sorted(wrong)}")` where `hint = " (AsyncActivityDefinitions or async callables)"` only for async.
- `_resolve_activity(activities, resolver, attempt, *, asynchronous)` (`:54-71`): if a resolver exists: `attempt.instance is None` → `LookupError("Worker scoped resolver requires an Activity Attempt instance")` (**never** falls back to the default mapping — `test_worker_runtime.py::test_scoped_resolver_refuses_missing_scope_instead_of_falling_back_to_default`); `resolver(instance, activity_name)`; non-callable → `TypeError("Worker resolver must return an Activity callable or None")`; wrong mode → `TypeError("Worker resolver returned an Activity that is not {mode}")`; `None` → default mapping lookup.

**`ActivityExecutionContext`** (dataclass, `:74-88`): `attempt_id, epoch, claimant, instance, latest_details` + private provider/attempt. `heartbeat(*, details=_OMITTED) -> object` calls `provider.heartbeat(attempt, details=details)` and stores the returned value as `latest_details`.

**`Worker(provider: WorkerDispatch, activities: Mapping[str, Activity], *, resolver: Callable[[str, str], Activity|None]|None = None, worker_id: str|None = None)`** (`:91-229`)
- Constructor errors: provider not `WorkerDispatch` → `TypeError("Worker provider must implement WorkerDispatch")`; non-callable resolver → `TypeError("Worker resolver must be callable")`; empty registry and no resolver → `ValueError("Worker requires default Activities or a scoped resolver")`. Default `worker_id = f"worker-{os.getpid()}"` (label only; it is **not** passed to the provider — the provider has its own `worker_id`).
- `stop()`: sets a flag; the in-flight Activity still terminalizes.
- `run(*, poll_interval=0.25)` (`:120-136`): `poll_interval < 0` → `ValueError`. Acquires the non-blocking driving lock (`RuntimeError("Worker is already being driven")`; closed → `RuntimeError("Worker is closed")`), emits `worker_started(worker, concurrency=1)`, prints the ready line, loops `while not stop: _drain(); if not stop: provider.wait(poll_interval)`. `finally`: `_close()` (provider.close once) then release lock and emit `worker_stopped`. Exceptions from `claim`/`wait` propagate (the Worker dies; a supervisor restarts it).
- `run_available(*, limit: int) -> int` (`:138-146`): `limit` must be a non-bool `int >= 0` (`ValueError("Worker run_available limit must be a non-negative integer")`). Claims/executes at most `limit` immediately-claimable Attempts, never waits, **never closes** the provider.
- `close()` (`:148-155`): requires the driving lock (`RuntimeError("Worker is already being driven")` if held); idempotent; if `provider.close()` raises, the Worker is still marked closed and the lock is released (`test_worker_close_failure_releases_driver_guard_and_leaves_worker_closed`).
- `_drain(limit=None)` (`:169-177`): `while not stop and (limit is None or processed < limit)`: `claim()`; `None` → return; else `_execute`.
- `_execute(attempt)` (`:179-225`) — the per-Attempt algorithm (identical in `AsyncWorker._execute`):
  1. open telemetry span `worker_activity(worker, queue, activity, attempt=attempt_id, epoch, claimant)`;
  2. resolve implementation (missing → `LookupError(f"no activity implementation for {name!r}: this worker implements {sorted(self._activities)}")`);
  3. build context, call `implementation(invocation, context=context)`;
  4. normalise result: `json.loads(json.dumps(result, allow_nan=False))` (tuples→lists, non-str keys stringified, NaN/∞/non-JSON → `ValueError`/`TypeError` → failure);
  5. any `Exception` from 2–4 becomes the failure; `ActivityError` is unwrapped to its `.failure` (`ActivityFailure`), any other exception is passed as the `Exception` object (the provider classifies it — Local/ZeroMQ: `ActivityFailure(repr(e), kind=type(e).__name__, retryable=True)`);
  6. `provider.complete(attempt, result)` or `provider.fail(attempt, failure_or_exception)`;
  7. if step 6 raises `Exception`: print the **refused** line, span `outcome="refused"`, and **swallow** (sync Worker continues with the next claim); otherwise span `outcome="completed"|"failed"`, `max_rss_mb`, print the **processed** line.

**`AsyncWorker(provider_factory: Callable[[], WorkerDispatch], activities: Mapping[str, AsyncActivity], *, concurrency: int, resolver=None, worker_id=None)`** (`:413-670`)
- `concurrency` must be a non-bool positive `int` (`ValueError("AsyncWorker concurrency must be a positive integer")`; parametrized test rejects `0, -1, True, 1.5`). `provider_factory` must be callable (`TypeError`). Registry validated with `asynchronous=True` **before** the factory is touched (`test_sync_and_async_workers_cross_reject_before_custody`). Default `worker_id = f"async-worker-{os.getpid()}"`.
- `AsyncWorker._from_async_access(access_factory: Callable[[], Awaitable[_AsyncWorkerAccess]], activities, *, concurrency, resolver=None, worker_id=None)` (`:441-467`): native-async custody door (used for `AsyncZeroMQWorkerAccess`).
- `_AsyncWorkerAccess` protocol (`:331-346`): `ready()`, `claim(slot)`, `heartbeat(slot, attempt, *, details=_OMITTED)`, `complete(slot, attempt, result)`, `fail(slot, attempt, error)`, `wait(slot, timeout) -> bool`, `close()` — all `async`; `slot ∈ [0, concurrency)`.
- `_SynchronousWorkerAccess` (`:381-410`) + `_ProviderLane` (`:273-328`): the default bridge. One **dedicated non-daemon OS thread per slot** (`name=f"impetus-provider-{n}"`), each constructing **its own provider** via `provider_factory()` inside that thread and executing every call for that slot on that thread (queue of `_LaneCall(method, args, kwargs, future)`; `None` sentinel ends the thread). Providers are therefore thread-confined (`test_async_worker_runs_exact_concurrency_on_event_loop_and_owns_providers_by_lane`: N providers, each touched by exactly one non-loop thread). `ready()` starts lanes sequentially, then awaits all factory futures; on any failure (thread start or factory) it closes every *initialized* lane and re-raises the first error (`_start_lanes`, `:532-565`).
- `AsyncActivityExecutionContext` (`:232-262`): same fields; `async heartbeat(*, details=_OMITTED)` snapshots details on the loop thread first, then under a per-Attempt `asyncio.Lock` checks open/closing (`RuntimeError("Activity execution context is closed")`), awaits `_owned(access.heartbeat(...))`, stores `latest_details`. `_close()` sets `closing`, then acquires the lock (waits for an in-flight heartbeat), then sets closed. Effect: an in-flight heartbeat is always ordered before the terminal report; heartbeats queued behind it fail with "context is closed" (`test_context_close_orders_queued_heartbeats_before_terminal_without_detached_errors`).
- `run(*, poll_interval=0.25)` (`:487-530`): emits `worker_started(worker, concurrency)`; acquires access (shielded; a cancelled acquisition still settles and is closed); `await _owned(access.ready())`; prints `{"ready": true, "worker": ..., "concurrency": N}`; runs the coordinator as a shielded task. Cleanup precedence: on cancellation or error → `stop()`; always await the coordinator (which drains active Activities), then `_owned(access.close())`; emit `worker_stopped`. Raises the **first error** (chained `from` the cancellation if both), else re-raises the cancellation.
- `_coordinate(access, poll_interval)` (`:567-601`) — the admission loop:
  - `free = [0..N-1]` kept sorted; `active: dict[Task, slot]` in creation order.
  - loop while not stopped: reap done tasks (a task exception is re-raised immediately → stop, gather remaining active, re-raise); if no free slot → `asyncio.wait(active, FIRST_COMPLETED)`; else pop the **lowest** free slot, `attempt = await _owned(access.claim(slot))` (claims are strictly sequential, one at a time); on an Attempt spawn `_execute` task and immediately try the next slot (greedy fill); on `None` put the slot back at the front, reap, then `await _owned(access.wait(slot, poll_interval))` unless stopped.
  - after stop: gather all active; raise the first exception in task-creation order (`test_same_turn_terminal_failures_surface_first_created_slot_error`).
  - A claim that raises (e.g. ZeroMQ `OperationUncertain`) stops admission, drains, closes, and propagates (`test_uncertain_native_claim_stops_admission_and_closes`: exactly 1 claim, 1 close).
- `AsyncWorker._execute` (`:613-666`): as the sync algorithm, plus: `asyncio.CancelledError` raised by the Activity becomes `RuntimeError(f"Activity cancelled: {raised}")` reported via `fail` (`test_user_activity_cancelled_error_is_reported_as_failure_and_provider_closes`: message `"Activity cancelled: user cancellation"`); context is closed (`finally`) **before** the terminal; a terminal refusal prints the refused line and is **re-raised** (unlike sync `Worker`) — which stops the whole AsyncWorker.
- `_owned(awaitable)` (`:349-367`): runs the custody operation as a task, re-shields on every cancellation until it completes, then raises the operation's own error (chained from the cancellation) or the remembered cancellation, else returns the result. All custody calls (claim/heartbeat/complete/fail/wait/ready/close) go through it, so a started custody operation always reaches a definite result.

**stdout protocol** (`Worker._say`, `:227-229`; `AsyncWorker._say` delegates): one line per event, `print(json.dumps(event), flush=True)` = CPython **default** `json.dumps` (`", "` / `": "` separators, `ensure_ascii=True`, insertion order, NaN allowed). Exact shapes:

```
{"ready": true, "worker": "<worker_id>"}                                 # Worker.run
{"ready": true, "worker": "<worker_id>", "concurrency": <N>}             # AsyncWorker.run
{"worker": "<worker_id>", "processed": "<attempt_id>", "activity": "<name>", "outcome": "completed"|"failed"}
{"worker": "<worker_id>", "refused": "<attempt_id>", "error": "<str(exc).strip()>"}
```

Supervisors and tests barrier on these lines (`test_worker_topology.py:127-148 await_event`, `test_worker_runtime.py:44-66`). Haskell: `Petrus.Json.dumps defaultDumps` with members in this order. Telemetry (`petrus.telemetry`, namespace `"impetus"`, goes to stdlib logging, **not** stdout): `worker_started`, `worker_stopped` (fields `worker`, `concurrency`), span `worker_activity` (fields above + `outcome`, `max_rss_mb`).

**CLI** — `python -m petrus.motus.worker` (`__main__.py` → `_cli.main`), `_cli.py:30-47`:

| Flag | Type / choices | Default | Notes |
|---|---|---|---|
| `--provider` | `local` \| `absurd` \| `zeromq` | required | |
| `--registry` | `module:attribute` | required | attribute may be a mapping or a zero-arg callable returning one (`_load_registry`, `:17-27`) |
| `--queue` | repeatable | `[]` → `("default",)` | de-duplicated preserving first-seen order (`tuple(dict.fromkeys(...))`, `:106`; tested by `test_main_defaults_queue_and_preserves_deduplicated_flag_order`) |
| `--worker-id` | str | `None` | passed to both provider and Worker |
| `--execution-mode` | `sync` \| `async` | `sync` | |
| `--custody-access` | `sync-bridge` \| `native-zeromq` | `sync-bridge` | |
| `--concurrency` | int | 1 | async only |
| `--max-operation-sockets` | int | 8 | native-zeromq only |
| `--claim-timeout` | int seconds | 30 | Absurd initial claim lease |
| `--poll-interval` | float | 0.25 | |
| `--path` | str | — | Local SQLite path |
| `--dsn` | str | `$IMPETUS_DSN` | Absurd PostgreSQL DSN |
| `--endpoint` | str | — | ZeroMQ |
| `--client-secret-certificate` | path | — | CURVE `.key_secret` |
| `--server-public-certificate` | path | — | CURVE `.key` |

Environment: `IMPETUS_DSN` (default of `--dsn`; note it makes `--provider local|zeromq` fail validation if set!), plus `IMPETUS_TELEMETRY_LEVEL` read by telemetry. `--help` must start with `usage: python -m petrus.motus.worker`, contain `--queue` and `zeromq`, and not `--capability` (`test_package_boundaries.py:478-489`).

Validation order in `main` (`:104-143`) and exit codes:
1. argparse errors (missing required flag, bad choice, non-int) → **exit 2**, usage on stderr.
2. `_load_registry`: bad spec → `SystemExit("--registry must be 'module:attribute', got {spec!r}")`; empty / non-mapping → `SystemExit("--registry {spec!r} must yield a non-empty mapping of activity name -> Activity")`; bad entries → `SystemExit("--registry {spec!r} must yield non-empty string names mapped to callable Activities")`. Import errors propagate (traceback, exit 1).
3. `_validate_registry(..., asynchronous=mode=="async")` errors → `SystemExit(str(error))` — before any provider is built (`test_cli_rejects_wrong_mode_registry_before_provider_factory`).
4. `_validate_provider_arguments` (`:82-101`), messages verbatim:
   - local: `"Local provider requires --path and rejects --dsn/$IMPETUS_DSN and --endpoint"`; certs → `"Local provider rejects ZeroMQ CURVE certificates"`.
   - absurd: `"Absurd provider requires --dsn (or $IMPETUS_DSN) and rejects --path and --endpoint"`; certs → `"Absurd provider rejects ZeroMQ CURVE certificates"`.
   - zeromq: `"ZeroMQ provider requires --endpoint and rejects --path and --dsn/$IMPETUS_DSN"`.
   - `"native-zeromq custody access requires async execution with the zeromq provider"`.
   - sync-bridge with `--max-operation-sockets != 8` → `"--max-operation-sockets applies only to native-zeromq custody access"`.
5. sync mode with `--concurrency != 1` → `SystemExit("--concurrency applies only to --execution-mode async")`; this check precedes `Worker(provider_factory(), ...)` (`:136-138`), so the sync provider is only built (in the main thread) after it passes.
6. Provider import failures (`ImportError` of optional extras) → `SystemExit(str(error))`.
`SystemExit("message")` = message on stderr, **exit 1**. Clean stop → **exit 0**. Uncaught exceptions (e.g. ZeroMQ `ConnectionError` from `claim`, `AsyncWorker` terminal refusal, `ValueError` for `--concurrency 0` raised by the `AsyncWorker` constructor) → traceback, **exit 1**.

Signals: `SIGTERM` → `worker.stop()` (`:139`) — graceful drain: the in-flight Activity completes, terminal is reported, then exit 0 (`test_sigterm_drains_the_in_flight_local_activity_before_worker_exit`, `TestWorkerKill::test_sigterm_drains_gracefully_the_in_flight_activity_completes`). An ongoing `provider.wait(poll_interval)` is *not* interrupted (exit latency ≤ poll interval). `SIGINT` is not handled (Python `KeyboardInterrupt` → the process dies by SIGINT after unwinding). `SIGKILL` leaves leases to expire (tested in topology/runtime kill tests).

Provider construction (`_provider_factory`, `:50-79`): `LocalWorkerDispatch(path, queues=, worker_id=)`; `AbsurdWorkerDispatch(dsn, queues=, worker_id=, claim_timeout=)`; `ZeroMQWorkerDispatch(endpoint, queues=, worker_id=, client_secret_certificate=, server_public_certificate=)` (request/terminal timeouts are **not** exposed: 5.0 s / 30.0 s). native-zeromq: `AsyncZeroMQWorkerAccess.create(endpoint, queues=, worker_id=, client_secret_certificate=, server_public_certificate=, max_in_flight_operations=--max-operation-sockets)`. In async sync-bridge mode the factory is invoked once per slot inside each lane thread.

#### 2. Wire formats, durable schemas, protocols

The Worker owns no durable schema. Its external contracts are: (a) the CLI flags/exit codes/signals above; (b) the stdout JSON lines above; (c) result normalisation `json.loads(json.dumps(result, allow_nan=False))` before `complete`; (d) failure classification handed to the provider (`ActivityError.failure` vs raw exception; providers compute `repr(exception)` / `type(exception).__name__` — a Haskell port must define a stable textual "repr" for its exceptions, see §7). Everything durable is the provider's (`LocalWorkerDispatch` SQLite tables `impetus_local_dispatch_*`, Absurd tables) — see the Dispatch section. Specs: `docs/runtime-guide.md:100-131` (shared workers, resolver, `run_available`), decision `2026-08-10T1200Z` (instance scope).

#### 3. Concurrency & durability semantics

- **Sync `Worker`**: single thread; one Activity at a time; driving lock (`threading.Lock`, non-blocking acquire) forbids concurrent `run`/`run_available`/`close` (`test_bounded_worker_pump_does_not_wait_or_close_and_refuses_concurrent_driving`). Heartbeats are synchronous provider calls from inside the Activity.
- **`AsyncWorker`**: Activities run on one asyncio loop; custody runs on N lane threads (sync bridge) or natively (ZeroMQ). Exactly `concurrency` Activities may be in flight (`peak == concurrency` tests). Claims are sequential. `stop()` is a `threading.Event` (callable from the SIGTERM handler).
- **Custody operations are atomic w.r.t. cancellation** (`_owned`), and cancellation of `run()` never abandons a claimed Attempt: a claim already in progress when `run` is cancelled is executed and terminalized, then the provider closed, then `CancelledError` re-raised (`test_caller_cancellation_drains_claim_acquired_before_return_and_then_closes`). Factory blocked during cancellation → close after startup settles (`test_caller_cancellation_during_blocked_factory_closes_after_startup_settles`).
- **Error precedence**: first terminal error wins; errors raised in the same reaping turn surface in slot-creation order; a later cancellation is chained, not substituted.
- **Durability/recovery** is entirely the provider's: lease = `heartbeat_timeout` from the invocation policy; a killed Worker's Attempt is reclaimed after lease expiry with epoch+1 and the last durable heartbeat details (`test_killed_local_worker_reassigns_with_recovered_heartbeat_details`, `TestWorkerKill::test_replacement_process_receives_durable_details_and_resumes`). The Worker never retries itself.
- Polling: `provider.wait(poll_interval)` is the only idle wait; providers may wake earlier (Absurd LISTEN doorbell — `TestDispatchDoorbell`; Local polls SQLite; ZeroMQ just sleeps).
- Timeouts: none inside the Worker (start_to_close etc. are enforced by provider leases/deadlines, not by cancelling the Activity).

#### 4. External dependencies

| Python | Haskell suggestion |
|---|---|
| `asyncio` loop + `threading` lanes + `concurrent.futures` | `async` (`withAsync`, `waitAnyCatch`, `cancel`), `stm` (`TVar` free-slot set, `TMVar` stop flag), plain `forkIO` green threads; lane threads only if a provider needs OS-thread confinement (`forkOS`/`runInBoundThread`) — SQLite via `direct-sqlite` opened per operation does not |
| `argparse` | `optparse-applicative` — but note it exits **1** on parse errors by default; set `prefs`/use `execParserPure` + `exitWith (ExitFailure 2)` to keep argparse's exit 2, and reproduce the usage prefix `usage: python -m petrus.motus.worker` only if `--help` text parity is required (suggest: document divergence, keep flag names/semantics identical) |
| `importlib` registry `module:attribute` | no dynamic import in Haskell: expose `workerMain :: Map Text Registry -> IO ()` so applications build their own worker executable; `--registry NAME` selects from the compiled-in table (accept the `module:attribute` spelling as an opaque key for command-line parity) |
| `signal.signal(SIGTERM, ...)` | `unix` `installHandler sigTERM (Catch (atomically (writeTVar stop True)))` |
| `json` | `petrus-json` (`defaultDumps` for stdout lines, `surrogateRefusingLoads`/`compact` for result faithfulness) |
| `resource.getrusage` (max_rss_mb) | `GHC.Stats`/`unix` `getrusage` via `System.Posix.Resource` or a tiny FFI |

#### 5. Upstream tests

| File | Test functions (cases) | Needs |
|---|---|---|
| `tests/petrus/motus/worker/test_worker_runtime.py` | 12 | SQLite only; 2 spawn real `python -m petrus.motus.worker --provider local` subprocesses (`_start_local_worker`, `:44-66`) |
| `tests/petrus/motus/worker/test_async_worker.py` | 26 (29 cases: `concurrency` ∈ {0,-1,True,1.5}) | none (fakes + Local SQLite) |
| `tests/petrus/motus/worker/test_worker_topology.py` | 36 (39 cases) | **Docker PostgreSQL** (`fixture_db` ← `absurd_dsn` ← `postgres_dsn` in root `conftest.py:65-153`) for all but `test_main_defaults_queue_and_preserves_deduplicated_flag_order` (2 cases, pure monkeypatch); real worker subprocesses with `--provider absurd` |

Coverage groups:
- *runtime*: runtime-checkable `WorkerDispatch`; exact context fields and heartbeat; missing activity → `LookupError` failure; JSON-unfaithful result → `TypeError` failure; scoped resolver (no fallback without instance; per-instance modules; resolver reconstructed after restart resolves a delayed retry by durable instance); `run_available` bounded/no-wait/no-close + driving guard; close failure semantics; **byte-identical JSONL history** for Inline vs Local+Worker (`test_controlled_sequential_local_execution_is_byte_identical_to_inline_history` — needs Engine + `JsonlHistoryStore` + `tests/absurd_support.topology_net`); SIGKILL reassign with recovered details; SIGTERM drain with exit 0.
- *async*: decorators/typed payload conversion (Activities component), wrong-mode rejection both ways and in CLI before provider construction, CLI defaults/validation, exact concurrency and lane ownership, scoped resolution (bridge and native), startup failure cleanup (partial factory failure closes the 2 initialised providers; thread-start failure), cancellation matrix (`_owned`, repeated cancellation, blocked claim/close, factory failure after cancellation), heartbeat cancellation keeps the lane alive to fail the Attempt, context-close ordering, terminal failure drains siblings and closes every provider, same-turn error ordering, uncertain native claim.
- *topology* (Postgres+Absurd, owned mostly by the Absurd/Engine sections): end-to-end, lifecycle-scope cancellation, worker SIGKILL/SIGTERM, authority crashes, `AbsurdProvider` engine construction (19 tests), registry snapshotting, unregistered activity → failed with `"no activity implementation"` in `failure_reason.message`, doorbell vs poll latency.
- Markers: none specific; global `timeout = 180`, `--randomly-seed=1729` (`pyproject.toml:92-102`). `--forbid-skips` turns Docker-absent skips into failures. DST boundary profiles reference `TestWorkerKill`/`TestAuthorityKill` nodes (`tests/dst/boundaries.py:53-100`).

Port strategy: replicate runtime + async suites as Haskell unit tests against fake `WorkerAccess`; replicate the subprocess tests against the Haskell worker executable; and add **cross-language** runs (Python `LocalDispatch` publishing → Haskell worker → Python `collect`, and vice versa) on the same SQLite file.

#### 6. Performance

Hot path per Attempt: claim (provider transaction) → resolve → run → JSON round-trip of result → terminal (provider transaction) → one stdout line + telemetry span. Worker overhead is small relative to providers; Python costs are the asyncio↔thread hop per custody call (`wrap_future`), JSON dumps/loads of the result, and GIL contention with N lanes.

Benchmark proposal (`worker-throughput`): Local SQLite dispatch file pre-loaded with K ∈ {1k, 10k} no-op invocations (input `{"n": i}`, result = input), on one queue; measure wall-clock to drain, Attempts/s, p50/p99 claim→terminal latency, peak RSS. Matrix: sync worker; async worker concurrency ∈ {1, 8, 64}; activity variants: no-op, 1 heartbeat, 10 ms sleep (I/O-bound concurrency check). Equivalence: same SQLite schema/pragmas (provider owned), `poll_interval=0` (or identical), same stdout logging enabled (redirect to `/dev/null`), telemetry at `facts`. Run Python and Haskell workers against byte-identical pre-seeded DB copies and assert identical `collect()` output afterwards.

#### 7. Better-the-Haskell-way suggestions

- **One worker, two front doors.** Haskell has no sync/async colour: implement a single `runWorker :: WorkerConfig -> WorkerAccess -> Registry -> IO ()` with `concurrency ≥ 1` green threads; `Worker` = concurrency 1. Keep the observable differences that matter for parity: sync `Worker` **swallows** terminal refusals and continues; `AsyncWorker` **re-raises** and stops (`__init__.py:217-220` vs `:658-661`). Make it a config field (`OnTerminalRefusal = Continue | Stop`) chosen by `--execution-mode`. Keep accepting `--execution-mode`, `--custody-access` and their validation messages so supervisor command lines are portable.
- `WorkerAccess` as a record of `IO` functions indexed by `Slot` (newtype); `HeartbeatDetails = Omitted | Provide Json` instead of a sentinel (`Provide Null` is meaningful).
- `_owned` ≈ "run custody op uninterruptibly but cancellably-by-outcome": `withAsync op $ \a -> uninterruptibleMask_ (waitCatch a)` then rethrow a remembered `AsyncCancelled` — or simply `uninterruptibleMask_` around the IO call when it is bounded by its own timeout. Use `Control.Concurrent.Async` + `stm` for slot accounting; `bracket` provider/access lifetime (close exactly once even on startup failure).
- Activity results/inputs are `Petrus.Json.Json`; faithfulness check = `allFinite`. Since Haskell results are typed, a non-faithful result is a type error at compile time except NaN/∞ — keep the runtime check.
- **Exception text quirk:** providers record `repr(exception)` and `type(exception).__name__` for non-`ActivityError` failures (e.g. `LookupError("no activity implementation for 'x': this worker implements ['a']")`, kind `LookupError`). Durable failure rows written by a Haskell worker will differ textually. Recommend: Haskell activities signal failure through an explicit `ActivityFailure`; for unexpected Haskell exceptions use `kind = <exception type name>` and `error = displayException`, and for the *missing implementation* case emit exactly the Python string `LookupError("no activity implementation for '<name>': this worker implements [<python list repr>]")` with kind `LookupError` so mixed fleets look identical. Also `"Activity cancelled: "` + message → kind `RuntimeError`.
- `ActivityFailure.error` > 4096 chars makes the provider's `fail` raise → reported as *refused* (Attempt left to lease expiry). Preserve or truncate? Preserving is the parity choice; flag in PARITY.md.
- Snapshot registries/queues at construction (pure `Map` makes this automatic).

#### 8. Packaging

- Package `petrus-motus` (module `Petrus.Motus.Worker`, `Petrus.Motus.Worker.Cli`) alongside `Petrus.Motus.Activity` and `Petrus.Motus.Dispatch` (the Worker needs `ActivityAttempt`, `ActivityInvocation`, `ExecutionPolicy`, `ActivityFailure`, `snapshotHeartbeatDetails`, and the `WorkerDispatch` record). Local provider (`LocalWorkerDispatch`) can live there too (SQLite); Absurd provider in `petrus-motus-absurd`; ZeroMQ in `petrus-motus-zeromq` (below). The CLI library function takes provider constructors as a parameter so the core package does not depend on libzmq/libpq; an executable `petrus-worker` in a small aggregate package wires all three.
- Kernel needs: **none** (no `Petrus.Impetus.*` imports). Integration tests need Engine + JSONL history + a topology net (`tests/absurd_support.py`).
- Dependencies: `petrus-json`, telemetry module, `async`, `stm`, `unix`, `optparse-applicative`.
- Parallelism: can be built right after Activities/Dispatch values and in parallel with the whole kernel, Engine, and the ZeroMQ transport.

### ZeroMQ Dispatch transport (`motus/transport/zeromq`)

Sources: `src/petrus/motus/transport/zeromq.py` (1072 lines), `src/petrus/motus/transport/__init__.py` (empty `__all__`). Decision: `docs/project/decisions/records/2026-07-28T1223Z-zeromq-mediates-worker-dispatch-without-owning-custody.md`; v1→v2: `2026-08-10T1200Z-instance-identity-scopes-shared-activity-resolution.md:54-55,109`; user doc `docs/runtime-guide.md:130-131,182` ("Clients and servers must upgrade together; v1 peers are rejected explicitly"). Optional extra `zeromq = ["pyzmq>=27,<28"]` (`pyproject.toml:39-41`); importing without pyzmq raises `ImportError("ZeroMQ Dispatch Transport requires the optional 'zeromq' extra; install petrus-runtime[zeromq]")` (`zeromq.py:36-44`, tested in `test_package_boundaries.py:492-512`). Reference environment: pyzmq 27.1.0 (bundled libzmq 4.3.x).

ZeroMQ is a **transport, not a provider**: the server wraps `LocalWorkerDispatch` (SQLite remains the only authority), exposes only Worker-facing `claim/heartbeat/complete/fail`, and never stores correctness state (no dedup tables, no routing-identity state).

#### 1. Responsibility & public API

Constants (`zeromq.py:46-53`):

| Name | Value |
|---|---|
| `_VERSION` | `2` |
| `_MAX_MESSAGE_BYTES` | `1048576` (1 MiB) |
| `_HWM` | `4` (SNDHWM and RCVHWM, both sides) |
| `_MAX_CLIENTS` | `1000` (server provider cache) |
| `_MAX_IDENTITY_BYTES` | `256` (UTF-8 bytes) |
| `_MAX_QUEUE_COUNT` | `32` |
| `_MAX_ERROR_BYTES` | `1024` |
| `_ZAP_DOMAIN` | `"impetus.dispatch.worker.v2"` (asserted by `test_zap_domain_preserves_the_operational_protocol_identity`) |

Classes:
- `OperationUncertain(ConnectionError)` (`:62-63`): a sent custody operation lost its definitive response.
- `ZeroMQWorkerDispatch(endpoint, *, queues=("default",), worker_id=None, client_secret_certificate=None, server_public_certificate=None, request_timeout=5.0, terminal_timeout=30.0)` (`:251-390`) — implements `WorkerDispatch` (sync, **thread-confined** to the constructing thread: any call or `close()` from another thread → `RuntimeError("ZeroMQ Worker Dispatch sockets may only be used by their owning thread")`). Methods `claim`, `heartbeat(attempt, *, details=_OMITTED)`, `complete`, `fail`, `wait(timeout)` (= `time.sleep(timeout)`, returns `False`), `close()` (idempotent; `context.term()`). Closed → `RuntimeError("ZeroMQ Worker Dispatch is closed")`.
- `AsyncZeroMQWorkerAccess(...)` / `await AsyncZeroMQWorkerAccess.create(endpoint, *, queues, worker_id, client_secret_certificate, server_public_certificate, request_timeout=5.0, terminal_timeout=30.0, max_in_flight_operations=8)` (`:66-248`) — implements `_AsyncWorkerAccess`; bound to the running loop at construction (other loop → `RuntimeError("ZeroMQ Worker access may only be used by its owning event loop")`); `slot` ignored; `ready()` only checks owner/closed; `wait` = `asyncio.sleep`; `close()` waits for open sockets to drain, then `context.term()`; idempotent. `max_in_flight_operations` must be a non-bool positive int.
- `ZeroMQDispatchServer(endpoint, path, *, allowed_queues, server_secret_certificate=None, allowed_client_keys=None, max_message_bytes=1048576)` / `.local(endpoint, path, *, allowed_queues, server_secret_certificate=None, allowed_client_keys=None)` (`:393-757`). `max_message_bytes` must be an int in `[1, 1048576]`. Methods: `serve_forever()` (blocking; run on a thread), `wait_ready(timeout=5.0) -> str` (bound endpoint, e.g. `tcp://127.0.0.1:54321` for a `:*` bind, from `ZMQ_LAST_ENDPOINT`; startup failure → `RuntimeError(f"ZeroMQ Dispatch server failed to start: {error}")`; timeout → `TimeoutError("ZeroMQ Dispatch server did not become ready")`), `request_drain(timeout=30.0)`, `stop()`. `_from_factory(endpoint, provider_factory, *, max_message_bytes)` is a **private fault-injection door** (no CURVE; any `provider_factory(queues, worker_id) -> WorkerDispatch`).
- Local factory (`:442-456`): allowed queues validated with `_name`; empty → `ValueError("ZeroMQ Local Dispatch server requires at least one allowed queue")`; per client: `requested = tuple(dict.fromkeys(queues))`; not ⊆ allowlist → `ValueError(f"Worker requested queues outside the server allowlist: {requested!r}")` (Python tuple repr, e.g. `('admin',)`); else `LocalWorkerDispatch(path, queues=requested, worker_id=worker_id)` → its claimant is `f"{worker_id}:{uuid4()}"` generated **server-side**.
- `main(argv)` server CLI (`:1026-1061`), see §2.

Validation helpers (exact messages matter because tests match substrings):
- `_endpoint(value, bind=False)` (`:760-767`): non-empty str without NUL (`"ZeroMQ endpoint must be a non-empty string without NUL"`); only `ipc://`/`tcp://` (`"ZeroMQ Dispatch Transport supports only ipc:// and tcp:// endpoints"`); clients reject `tcp://host:*` and `tcp://host:0` (`"ZeroMQ Worker requires a connectable TCP endpoint, not a wildcard bind endpoint"`).
- `_name(value, noun)`: non-empty str without NUL → else `ValueError(f"ZeroMQ Dispatch {noun} must be a non-empty string without NUL")`. `_wire_name`: plus `len(utf8) <= 256` → else `f"ZeroMQ Dispatch {noun} exceeds the 256-byte protocol limit"`. Wire names: queue, worker id, request id, client id, operation. Attempt fields use `_name` only (no length limit).
- `_timeout(value, noun)`: non-bool int/float, finite, `>= 0` → else `ValueError(f"ZeroMQ {noun} must be a finite non-negative number")`. Clients additionally require request/terminal timeouts ≥ 0.001 s (`"ZeroMQ request and terminal timeouts must be at least one millisecond"`).
- Client queues: `tuple(dict.fromkeys(...))`, 1..32 (`"ZeroMQ Worker Dispatch requires from 1 to 32 queues"`; async: `"ZeroMQ Worker access requires ..."`). `worker_id` default `f"worker-{os.getpid()}"`. `client_id = str(uuid4())` per client object.

Dependencies on other components: `ActivityAttempt`, `WorkerDispatch` (`petrus.motus.dispatch`), `ActivityInvocation`, `ExecutionPolicy`, `ActivityFailure`, `snapshot_heartbeat_details`, `_OMITTED` (`petrus.motus.activity`), `LocalWorkerDispatch` (`petrus.motus.dispatch.local`, imported lazily by the local factory). **No kernel API.**

#### 2. Wire formats, durable schemas, protocols

**Topology & sockets**

| Side | Socket | Options (exact) |
|---|---|---|
| Server | `ROUTER`, `bind(endpoint)` | `LINGER=0`, `SNDHWM=4`, `RCVHWM=4`, `MAXMSGSIZE=1048576` (always the constant, even if `max_message_bytes` is smaller), `SNDTIMEO=1000` ms, `ROUTER_MANDATORY=1`; TCP: `ZAP_DOMAIN="impetus.dispatch.worker.v2"`, `CURVE_PUBLICKEY`, `CURVE_SECRETKEY`, `CURVE_SERVER=1` (`:535-548`) |
| Client (sync and async) | `DEALER`, `connect(endpoint)`, **fresh socket per RPC attempt** | `LINGER=0`, `SNDHWM=4`, `RCVHWM=4`, `MAXMSGSIZE=1048576`, `IMMEDIATE=1`, `SNDTIMEO=max(1, round(request_timeout*1000))` ms; TCP: `CURVE_PUBLICKEY` (client), `CURVE_SECRETKEY` (client), `CURVE_SERVERKEY` (pinned server public) (`:225-244`, `:357-376`) |

One `zmq.Context` per client object (sync) / `zmq.asyncio.Context` per async access / one per `serve_forever` call. If socket option setting fails, the new socket is closed with linger 0 before re-raising (`test_worker_socket_setup_failure_closes_new_socket`). The sync client discards the socket after every response or error (`_discard_socket`), so every RPC — and every retry — uses a brand-new connection (new ZMTP + CURVE handshake). The async client opens and closes one socket per RPC attempt inside a semaphore permit (`max_in_flight_operations`, default 8 → at most 8 live sockets).

**Multipart framing** (no REQ/REP empty delimiter!):
- Client → server: DEALER sends **exactly one frame**: the UTF-8 JSON request. ROUTER receives `[routing_id, body]`.
- Server → client: ROUTER sends `[routing_id, response_json]`; DEALER receives exactly one frame. A client receiving ≠ 1 frame raises `RuntimeError("ZeroMQ Dispatch server returned a multipart protocol violation")`.
- Server reception (`_receive_request`, `:580-595`): reads the route, then drains all remaining frames counting them; keeps the body only if it is the single frame and `<= max_message_bytes`. `frame_count != 1` → protocol error `"request must contain exactly one application frame"` (so a REQ peer, which prepends an empty delimiter, is refused); total > limit → `"request exceeds the maximum message size"`. Frames larger than 1 MiB are dropped by libzmq (`MAXMSGSIZE`) and the peer is disconnected — no reply.

**JSON encoding** (`_encode_message`, `:966-970`): `json.dumps(value, allow_nan=False, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()` (UTF-8) — **recursively sorted keys**, compact, raw non-ASCII, Python float repr (`1.0`, `1e-07`, `1e+16`), arbitrary ints; encoded size > 1 MiB → `ValueError("ZeroMQ Dispatch message exceeds the maximum size")` (raised client-side before sending; server-side it turns into a `refused` reply). Haskell: exactly `Petrus.Json.canonicalText` / `dumps compact{sortKeys=True}`.
**JSON decoding** (`_decode_message`, `:973-980`): `json.loads(payload.decode("utf-8"))` = CPython defaults (accepts `NaN`/`Infinity`/`-Infinity`, duplicate keys last-wins, BOM refused) → `Petrus.Json.parseJson surrogateRefusingLoads`. Errors → `ValueError(f"invalid ZeroMQ Dispatch JSON message: {error}")` with CPython's `JSONDecodeError` text (e.g. `Expecting value: line 1 column 1 (char 0)`); non-object → `"ZeroMQ Dispatch message must be a JSON object"`.

**Request envelope (v2)** — base fields, all required, no others except per-operation fields (exact-set check):

| Field | Type | Rule |
|---|---|---|
| `version` | int | must be `2` (not bool, not `2.0`, not `"2"`) |
| `request_id` | str | wire name; client uses fresh `uuid4()` per logical RPC, **reused verbatim on retries** |
| `client_id` | str | wire name; `uuid4()` per client object; server caches one provider per `client_id` |
| `worker_id` | str | wire name |
| `queues` | list[str] | 1..32 wire names, order as configured (dedup'd) |
| `operation` | str | wire name; `claim` \| `heartbeat` \| `complete` \| `fail` |

Per-operation fields (`_decode_operation`, `:674-704`):

| Operation | Exact extra fields | Success `value` |
|---|---|---|
| `claim` | none | `{"attempt": <Attempt> \| null}` |
| `heartbeat` | `attempt`, optional `details` (absent = lease extension only; present `null` = set details to null) | `{"details": <latest details>}` |
| `complete` | `attempt`, `result` | `{"completed": true}` |
| `fail` | `attempt`, `failure` (current) **or** `attempt`, `error: str` (legacy; server maps to `ActivityFailure(error, retryable=True)`, kind `"ActivityError"`) | `{"failed": true}` |

Clients always send `failure`. Clients check the acknowledgement exactly (`{"completed": true}` / `{"failed": true}`; else `RuntimeError("ZeroMQ Dispatch returned an invalid complete|fail acknowledgement")`).

**Attempt object** (`_encode_attempt`/`_decode_attempt`, `:822-853`) — exact 7 keys, `instance` **required but nullable** (the v2 change; `test_v2_attempt_wire_requires_and_preserves_nullable_instance`):
`attempt_id` (str, opaque — Local uses `json.dumps([instance, occurrence], ensure_ascii=False, separators=(",", ":"))`, e.g. `["inst",1]`), `epoch` (**string**, e.g. `"1"`), `claimant` (str), `queue` (str), `invocation` (object), `latest_details` (JSON, ≤ 64 KiB after snapshot), `instance` (str or null).

**Invocation object** (`:856-907`) — exact keys `activity` (non-empty str), `input` (any JSON), `policy`, `correlation` (str|null), `idempotency` (str|null). `policy` on encode always carries the 8 current keys `attempts, heartbeat_timeout, initial_interval, coefficient, max_interval, jitter, start_to_close, schedule_to_close`; on decode either exactly the legacy pair `{attempts, heartbeat_timeout}` or exactly all 8; `attempts`/`heartbeat_timeout` must be non-bool ints; then `ExecutionPolicy(**policy)` validation (Activities component).

**Failure object** (`:910-931`) — exact keys `type` (must be `"activity_failure"`), `error` (str 1..4096 chars), `kind` (str 1..128), `details` (JSON ≤ 16,384 bytes compact), `retryable` (bool), `retry_after` (non-negative finite number ≤ 1e9 or null). Client classification `_classified_failure` (`:934-941`): `ActivityFailure` as-is; `str` → `ActivityFailure(s, retryable=True)` (kind `ActivityError`); `Exception` → `ActivityFailure(repr(e), kind=type(e).__name__, retryable=True)`.

**Responses** (`_handle`, `:614-647`):
- success: `{"ok":true,"request_id":"<id>","value":<value>,"version":2}`
- error: `{"error":{"kind":"protocol"|"refused"|"service","message":"<text>"},"ok":false,"request_id":"<id or \"unknown\">","version":2}`

Verbatim example (sorted keys, generated from the reference):

```
{"attempt":{"attempt_id":"[\"inst\",1]","claimant":"worker-1:0b7e","epoch":"1","instance":"inst","invocation":{"activity":"work","correlation":"c","idempotency":"i","input":{"a":[1.0,"é"],"b":1},"policy":{"attempts":2,"coefficient":2,"heartbeat_timeout":2,"initial_interval":0,"jitter":0,"max_interval":60,"schedule_to_close":null,"start_to_close":null}},"latest_details":{"cursor":7},"queue":"default"},"client_id":"C","details":{"x":1},"operation":"heartbeat","queues":["default"],"request_id":"R","version":2,"worker_id":"W"}
{"ok":true,"request_id":"R","value":{"attempt":null},"version":2}
{"error":{"kind":"refused","message":"m"},"ok":false,"request_id":"R","version":2}
```

**Error kinds** (server classification):
- `protocol` = `_ProtocolError` (a `ValueError` subclass) from `_parse_request` / `_decode_operation` / frame checks.
- `refused` = any other `ValueError` (includes `UnicodeEncodeError`): queue allowlist, `"client identity cannot change Worker queues or identity"`, custody refusals from `LocalWorkerDispatch` (`"stale Activity attempt <id>"`, `"conflicting terminal report for Activity attempt <id>"`, `"invalid Local Activity attempt identity ..."`, non-faithful result/details), oversized response.
- `service` = any other `Exception` (e.g. `TypeError("ZeroMQ server factory must return WorkerDispatch")`, sqlite errors, and — quirk — `TypeError("ActivityFailure retryable must be bool")` when a `failure.retryable` is not a bool, because `_decode_operation` only converts `ValueError`).
- Message: `str(error).strip()` or the exception class name if empty, truncated to 1024 UTF-8 bytes, decoded with `errors="replace"` (`_error_message`, `:1014-1017`).
- `request_id` is `"unknown"` whenever the failure happens before `_parse_request` returns (frame/size/JSON/base-field/identity/queue/**version** errors); afterwards the real id (operation errors, refusals, service errors).

**Validation order** (`_parse_request`, `:649-672`) — first failure wins: frame count → size → JSON/object → base fields present (`f"request requires base fields {sorted(base)}"` → `['client_id', 'operation', 'queues', 'request_id', 'version', 'worker_id']`) → `request_id` → `client_id` → `worker_id` → `queues` list 1..32 (`"request queues must contain from 1 to 32 names"`) → each queue → version (`f"unsupported ZeroMQ Dispatch protocol version {request['version']!r}"`, Python repr: `1`, `'2'`, `2.0`, `True`). Then operation name (`_wire_name`, e.g. 300-byte operation → `"... exceeds the 256-byte protocol limit"`), unknown → `f"unknown Worker Dispatch operation {operation!r}"`; exact field set → `f"{operation} request requires exactly {sorted(fields)}"`; for `fail`: failure decoded **before** attempt; for heartbeat/complete: attempt decoded. `_exact` messages: `f"{noun} requires exactly {sorted(fields)}"` with nouns `Activity Attempt`, `Activity invocation`, `failure`, `claim result`, `heartbeat result`, `complete result`, `fail result`, `successful response`, `refused response`, `refused response error`; policy: `"execution policy requires exact legacy or current fields"`, `f"execution policy {field} must be an integer"`; failure type: `"unsupported failure payload type"`. Then provider lookup/creation (`_provider`, `:706-730`), then the operation.

**Version negotiation**: none. The client always sends `version: 2`; the server accepts only int `2`; v1 (or any other) peers receive `kind:"protocol"` with `request_id:"unknown"`. Clients validate `version == 2` (non-bool) and `request_id` match on every response (`RuntimeError("ZeroMQ Dispatch response version or request identity mismatch")` / `"... refusal version or request identity mismatch"`). So a client whose request was rejected pre-parse sees a *mismatch* `RuntimeError`, not the protocol message. Client mapping of error replies (`_decode_response`, `:944-963`): `refused` → `ValueError(f"ZeroMQ Dispatch refused request: {message}")`; `protocol`/`service` → `RuntimeError(f"ZeroMQ Dispatch {kind} error: {message}")`; malformed refusal → `RuntimeError("ZeroMQ Dispatch returned an invalid refusal")`. Success is detected by `response.get("ok") is True`.

**CURVE authentication (TCP only)** — `_client_security` (`:770-784`), `_server_security` (`:787-803`), `_open_server` (`:525-557`):
- TCP requires CURVE; IPC rejects any certificate argument. Messages: `"ZeroMQ TCP Worker requires client secret and server public certificates"`, `"ZeroMQ IPC Worker rejects TCP CURVE certificates"`, `"ZeroMQ TCP server requires a server secret certificate and allowed-client key directory"`, `"ZeroMQ TCP server allowed-client directory must contain at least one public .key"`, `"ZeroMQ client certificate must contain a public and secret key"`, `"ZeroMQ trusted server certificate must be public-only"`, `"ZeroMQ server certificate must contain a public and secret key"`, `f"allowed-client certificate must be public-only: {path}"`, `"ZeroMQ IPC server rejects TCP CURVE configuration"`. All checks happen in the constructor (before the authenticator starts — `test_public_only_server_certificate_fails_before_starting_authenticator`).
- Certificate files = pyzmq/czmq ZPL format (`zmq/auth/certs.py` 27.1.0). Writer (`create_certificates(dir, name)` → `name.key` public, `name.key_secret` secret):
  ```
  #   ****  Generated on <datetime> by pyzmq  ****
  #   ZeroMQ CURVE Public Certificate            (secret: "#   ZeroMQ CURVE **Secret** Certificate")
  ...banner comment lines...

  metadata
  curve
      public-key = "<40-char Z85>"
      secret-key = "<40-char Z85>"              (secret file only)
  ```
  Reader `load_certificate` (the parsing rule a Haskell port must copy): file must exist (`OSError`); for each line `strip()`; skip lines starting `#`; a line starting with `public-key` → value = text after the first `=`, stripped of `' \t\'"'`; same for `secret-key`; stop when both found; no public key → `ValueError(f"No public key found in {filename}")`. Keys stay Z85 text (40 chars) and are passed to libzmq as Z85 (`zmq_setsockopt` accepts 40-char Z85).
- Server authenticator: pyzmq `ThreadAuthenticator(context)` started *before* the ROUTER is created, `configure_curve(domain="impetus.dispatch.worker.v2", location=allowed_client_keys)`, which loads the Z85 public key of every `*.key` file (glob, non-recursive) **once at startup** (adding keys requires a restart). It is a ZAP handler: a `REP` socket bound to `inproc://zeromq.zap.01` in the server's context. ZAP request frames `[version="1.0", request_id, domain, address, identity, mechanism, credentials...]`; for `CURVE`, one credential = the client's 32-byte binary public key; allowed iff `z85(key)` is in the domain's set. Reply frames `[b"1.0", request_id, status_code, status_text, user_id, metadata=b""]` with `200 / "OK" / <z85 client key as user id>` or `400 / "Unknown key"` (other 400 texts: `"Invalid version"`, `"Not enough frames"`, `"Invalid credentials"`, `"Unknown domain"`). An unapproved client or a client pinning the wrong server key never completes the handshake; because clients set `IMMEDIATE=1` their send times out → `ConnectionError("... was not acknowledged")` (tested).
- All approved keys are authorized for the server's whole queue allowlist (no per-key policy).

**IPC endpoint ownership fence** (`_endpoint_lock`, `:806-819`): for `ipc://<path>`: `mkdir -p dirname(path)`; open `<dir>/.<basename>.impetus.lock` (mode `a+b`, never deleted); `flock(LOCK_EX | LOCK_NB)`; busy → `RuntimeError(f"ZeroMQ IPC endpoint is already owned: {endpoint}")` **before** binding (libzmq would otherwise silently unlink/steal the socket file — `test_ipc_second_server_is_refused_before_zeromq_can_steal_the_binding`). Held for the server lifetime. No fence on platforms without `fcntl` (RuntimeError suggesting TCP). A Haskell server must use the **same lock file name and `flock`** (not `fcntl` record locks) so mixed Python/Haskell servers exclude each other.

**Server CLI** — `python -m petrus.motus.transport.zeromq` (`:1026-1061`):

| Flag | Default | Notes |
|---|---|---|
| `--path` | required | Local SQLite Dispatch path |
| `--bind` | required | `ipc://` or `tcp://` (wildcards allowed) |
| `--queue` | repeatable, `[]` → `("default",)` | dedup'd allowlist |
| `--server-secret-certificate` | — | TCP |
| `--allowed-client-keys` | — | directory of `*.key` (TCP) |
| `--drain-timeout` | `30.0` (float) | used on SIGTERM |

Readiness: after bind a daemon thread prints one line with CPython **default** `json.dumps`: `{"ready": true, "endpoint": "<bound endpoint>", "pid": <pid>}` (tests read the first stdout line and check `ready`/`endpoint`). Startup failure → no line, traceback, exit 1. `SIGTERM` → `request_drain(drain_timeout)`; serving continues (claims answered `{"attempt": null}` without touching custody, all other operations served) until the deadline, then clean shutdown, **exit 0** (`test_dispatch_service_process_death_preserves_lease_details_and_restart_recovery` asserts `returncode == 0` with `--drain-timeout 0.1`). Note: drain always lasts the full timeout (no early exit when idle).

No environment variables are read by the transport.

#### 3. Concurrency & durability semantics

- **Server**: single thread; `poll(100 ms)` loop checking `stop`/drain deadline; requests handled strictly serially (a slow provider call delays every client — fault-injection tests rely on it). Provider cache `dict[client_id → (queues, worker_id, provider)]`, at most 1000; overflow evicts via `dict.popitem()` = **the most recently inserted** client (LIFO quirk) and closes its provider. A `client_id` may not change its queues/worker id (`refused`). Reply send failures (`EHOSTUNREACH` from `ROUTER_MANDATORY`, `EAGAIN` after `SNDTIMEO=1000`) are ignored — custody, not delivery, determines whether the operation happened. On exit: close all providers (errors ignored), socket, authenticator, context, then release the lock.
- **Client retry policy** (decision record: "only exact completion is automatically redelivered"):
  - `claim`, `heartbeat`, `fail`: **never retried**. Timeout/`zmq.Again`/`ZMQError` → sync: `ConnectionError(f"ZeroMQ Dispatch request {op!r} was not acknowledged")`; async: `OperationUncertain(f"ZeroMQ Dispatch request {op!r} was sent but not acknowledged")`. Recovery is via custody leases: a lost claim reply leaves the task leased at epoch 1 until `heartbeat_timeout` expires, then epoch 2 is claimable (`test_lost_claim_reply_is_not_blindly_replayed_and_recovers_by_lease_expiry`); a lost heartbeat reply has still persisted its details; a lost fail reply has still recorded the failure.
  - `complete`: retried with the **identical payload bytes** (same `request_id`) on a fresh socket until `terminal_timeout` (default 30 s) elapses since the first send; each attempt waits up to `request_timeout`. Correct because Local custody acknowledges an exact duplicate terminal (`_acknowledge_terminal_retry` compares `(epoch, claimant, canonical outcome JSON)`) and refuses a different one (`conflicting terminal report`). Survives server process death and restart (`test_uncertain_completion_redelivers_exactly_across_dispatch_process_death`).
  - Async cancellation after the send started → `OperationUncertain(f"ZeroMQ Dispatch request {op!r} outcome is uncertain")`; cancellation while waiting for a permit → plain `CancelledError` (`test_async_send_cancellation_boundary_and_permit_wait_are_distinct`).
  - Errors that are not transport errors (refusals, decode errors) propagate immediately and are not retried.
- **Fencing** is Local's: every custody op re-validates the attempt against the row (`queue`, canonical invocation JSON, `epoch`, `claimant`, lease deadline). The claimant on the wire comes from the Attempt payload, so a Worker keeps heartbeating its attempt across a server restart (new server provider, new server-side claimant for new claims, old attempt still valid). Changing `epoch`, `claimant`, `queue`, or any policy field in the payload yields `stale Activity attempt` (`test_stale_attempt_payload_cannot_change_claimant_or_epoch`). **Consequence for a Haskell client**: it must re-encode the invocation it received *byte-identically* under `canonicalText` — preserve int vs float (`0` vs `0.0`), Python float repr, key sets, and full input JSON. Decode into `Petrus.Json.Json` and never into lossy typed records.
- Readiness/timeouts: no client-side readiness handshake; with `IMMEDIATE=1` a send before the connection is up blocks until `SNDTIMEO` (= request timeout) then fails (debt item `docs/project/debt/items/2026-07-30T2309Z-zeromq-test-races-initial-server-readiness.md`, Paid: tests first perform an acknowledged `claim` returning `None`).
- **No heartbeat at the ZeroMQ level** and no ZMTP heartbeats configured; "heartbeat" is the custody operation. No reconnection logic beyond fresh sockets per RPC.
- Thread/loop ownership: sync client = owning thread only; async access = owning loop only; server = the thread calling `serve_forever` (`stop`/`request_drain` are thread-safe `threading.Event`s).
- Worker impact: a sync `Worker` over ZeroMQ dies (exit 1) on the first unacknowledged claim; an `AsyncWorker` (bridge or native) stops on uncertain claims. External supervisors restart (decision record: "External process supervisors own role health and restart").

#### 4. External dependencies

| Python | Haskell |
|---|---|
| pyzmq 27 (`zmq`, `zmq.asyncio`), bundled libzmq 4.3.x with libsodium/tweetnacl CURVE | **`zeromq4-haskell` 0.8.0** (Hackage, uploaded 2019-03-03, single revision r0; `pkgconfig-depends: libzmq >= 4.0 && < 5.0`; `ghc-prim` only under `impl(ghc < 7.6)`, so the bounds don't block GHC 9.10.3, but it is untested since GHC 8.2 — **verify it builds**, may need `allow-newer`/a fork). API covers everything used: `Dealer`/`Router`, `setLinger`, `setSendHighWM`, `setReceiveHighWM`, `setMaxMessageSize`, `setSendTimeout`, `setImmediate`, `setRouterMandatory :: Bool -> Socket Router -> IO ()`, `setZapDomain :: Restricted (N1,N254) ByteString -> ...`, `setCurveServer`, `setCurvePublicKey/SecretKey/ServerKey :: KeyFormat f -> Restricted f ByteString -> ...` (`TextFormat` = 40-char Z85), `curveKeyPair`, `z85Encode/z85Decode`, `lastEndpoint`, `sendMulti`, `receiveMulti`, `poll`, `waitRead`. libzmq must be built with CURVE (`zmq_has("curve")`) — Homebrew/Debian builds are. |
| `zmq.auth.ThreadAuthenticator` | **Gap: no ZAP authenticator in zeromq4-haskell.** Implement ~60 lines: a `Rep` socket bound to `inproc://zeromq.zap.01` in the same `Context`, started before the ROUTER binds, answering frames as in §2. |
| `zmq.auth.load_certificate`/`create_certificates` | Gap: implement the ZPL line parser of §2 (and a writer for tests); Z85 via `z85Decode` or pure code. |
| `zmq.asyncio` futures with `SNDTIMEO` / `asyncio.wait_for` | zeromq4-haskell send/receive use `ZMQ_DONTWAIT` + `threadWaitRead/Write` on `ZMQ_FD`, so they compose with the GHC IO manager (threaded RTS): wrap `receiveMulti` in `System.Timeout.timeout`; keep each socket used by one thread at a time. |
| `fcntl.flock` | `unix` ≥ 2.8 has no flock; use `lukko` (`Lukko.FLock`, OFD/flock) or a 5-line FFI to `flock(2)`; must be BSD `flock`, not `fcntl` locks, for cross-implementation exclusion. |
| `uuid.uuid4` | `uuid` (`Data.UUID.V4.nextRandom`), lowercase hyphenated `toText`. |
| `json` | `petrus-json`: `canonicalText`/`dumps compact{sortKeys=True}` to encode, `parseJson surrogateRefusingLoads` to decode, `defaultDumps` for the readiness line. |
| `argparse`, `signal` | `optparse-applicative` (exit code 2 on parse error to match), `unix` signal handlers. |

Alternative if zeromq4-haskell proves unbuildable: a thin hand-written FFI to the ~15 libzmq functions used (ctx, socket, setsockopt, bind/connect, msg send/recv, getsockopt RCVMORE/FD/EVENTS/LAST_ENDPOINT, z85). There is no reason to keep a Python helper here.

#### 5. Upstream tests

`tests/petrus/motus/transport/test_zeromq_dispatch_transport.py`: **26** test functions (**30** cases: `asynchronous` ∈ {False, True}; endpoint ∈ {tcp, ipc}; timeout ∈ {nan, inf, -inf}). No Docker, no network beyond `127.0.0.1` TCP; requires pyzmq/libzmq with CURVE; several spawn subprocess servers (`python -m petrus.motus.transport.zeromq` via `_start_server_process`, `:984-1013`, and an inline delayed server, `:778-817`) and read their readiness line. Fixtures: `RunningServer` thread wrapper (`:37-58`), `curve_certificates` (`:61-79`: server, client, stranger, other-server certs via `zmq.auth.create_certificates`; only `client.key` copied into `allowed/`), `DelayedProvider` (`:609-639`) for reply-loss injection after custody commit, `_assert_task` reads `SELECT epoch FROM impetus_local_dispatch_tasks`.

Groups:
- *Round trips over IPC* (sync + async): claim/heartbeat (`details` given, omitted, `null`)/complete twice (idempotent)/stale heartbeat/conflicting terminal; v2 policy + classified `ActivityFailure` for both clients; lifecycle cancellation fences (`dispatch.cancel` → `FENCED`; heartbeat stale; late complete accepted for quarantine); `AsyncWorker` over native access with concurrency 3 and heartbeats.
- *Ownership*: wrong loop, wrong thread, idempotent close, socket-setup failure closes the socket.
- *Async internals*: permit vs send cancellation boundary; completion retries identical payload with fresh, bounded sockets.
- *Wire*: nullable-but-required `instance`; protocol refusals (extra field, version 1, version `true`, 300-byte operation, oversized with `max_message_bytes=1000`, two frames) via a raw DEALER using `send_json` (CPython default `json.dumps` with spaces — the server must accept any valid JSON spelling).
- *Security/config*: queue allowlist refusal; drain returns `attempt: null` but completes in-flight work; IPC ownership fence; CURVE approved vs unapproved key vs wrong server key (sync + native async); public-only server cert rejected; TCP requires CURVE / IPC rejects CURVE; non-finite timeouts rejected.
- *Uncertainty*: lost claim/heartbeat/fail replies are not replayed (sync and async, call counters == 1); lost completion reply is redelivered until acknowledged; redelivery across real server process death (DST boundary profile `zeromq-uncertain-terminal-restart`); server process death preserves lease and details, restart allows heartbeat, epoch-2 reclaim after lease expiry with recovered details (`zeromq-lease-restart`).

Port strategy: replicate all 30 cases against the Haskell client and server, **plus a cross matrix** (Python client ↔ Haskell server, Haskell client ↔ Python server; both on IPC and CURVE TCP using pyzmq-generated certificate files) — the protocol's purpose is interop. Add golden byte tests for the request/response examples in §2 and the protocol-error table generated from the reference `_handle`.

#### 6. Performance

Hot paths: per RPC — socket create + connect (+ CURVE handshake on TCP: 2 round trips + curve25519 box ops) + canonical JSON encode of the full Attempt (invocation input can be up to ~1 MiB) + server decode/validate + one SQLite transaction + response encode/decode. The fresh-socket-per-RPC design makes connection setup the dominant cost for small payloads; the single-threaded server serialises all clients.

Benchmark proposal (`zeromq-dispatch-rpc`): pre-seed a Local SQLite file with K = 5,000 invocations (inputs 100 B and 64 KiB variants). Run server S ∈ {Python, Haskell} and W clients ∈ {1, 8, 32} of implementation C ∈ {Python sync, Python native async (8 permits), Haskell}; each client loops claim → 1 heartbeat (with details) → complete until empty. Transports: IPC and CURVE TCP on loopback. Measure total drain time, RPC/s, p50/p99 per-operation latency (client side), server CPU and RSS. Keep equivalent: same libzmq version for both (link Haskell against the same system libzmq pyzmq was built with, or pin both to system libzmq), same HWM/timeouts, same SQLite file and pragmas, telemetry level `facts`, results verified identical via `LocalDispatch.collect()`.

#### 7. Better-the-Haskell-way suggestions

- **Typed protocol**: `data Request = Request { reqId, clientId, workerId :: WireName, queues :: NonEmpty WireName (≤32), op :: Op }`, `data Op = Claim | Heartbeat Attempt HeartbeatDetails | Complete Attempt Json | Fail Attempt FailureReport`, `data FailureReport = Current ActivityFailure | LegacyError Text`, `data ErrorKind = Protocol | Refused | Service`; `newtype WireName` smart constructor enforcing non-empty/no-NUL/≤256 bytes. Keep the decoder order and messages of §2 so error replies match byte-for-byte (generate golden tests from the Python `_handle`).
- **Type-level retry discipline**: only `Complete` is `Redeliverable`; give the client `rpcOnce` vs `rpcRedeliver` so nobody adds blind retries to claim/fail. Model outcomes as `Acknowledged a | Refused Text | ServiceError ErrorKind Text | Uncertain` instead of exception subclasses (convert to exceptions at the `WorkerAccess` boundary).
- Server: `stop`/`drain` as STM `TVar`s; `bracket` for context/socket/ZAP thread/lock so shutdown order is guaranteed (close providers → socket → ZAP → context → lock). Provider cache as `Data.Map` with an explicit insertion counter to reproduce the LIFO eviction (or document a deliberate change to LRU; it only matters past 1000 clients).
- Possible improvement (opt-in, documented as divergence): treat `EAGAIN` on *send* with `IMMEDIATE=1` (message never queued) as "not sent" → safe to retry any operation; upstream folds it into "uncertain". Keep the default identical.
- Quirks to preserve for interop: v2 only, `request_id:"unknown"` for pre-parse errors; sorted-key compact UTF-8 JSON; legacy `error` field in `fail`; legacy policy pair accepted on decode, current 8 keys emitted; `epoch` is a string; `instance` key always present; `retryable` non-bool → `service`; oversized *response* → `refused` after custody already claimed (the lease then expires — preserve); claims during drain return `null` without touching custody; drain waits the full timeout; ZAP domain string; lock file `.<name>.impetus.lock` + `flock`; readiness line spelling with default separators; client wildcard-port rejection; the server's `MAXMSGSIZE` stays 1 MiB regardless of `max_message_bytes`.

#### 8. Packaging

- Separate package **`petrus-motus-zeromq`** (modules `Petrus.Motus.Transport.ZeroMQ`, `.Wire`, `.Curve` (cert files + ZAP), `.Server`, `.Client`), mirroring upstream's optional extra so the core never links libzmq; executable `petrus-zeromq-dispatch` (server CLI) and a `nativeZeroMQAccess` constructor plugged into the worker CLI.
- Depends on: `petrus-json`; `petrus-motus` (`ActivityAttempt`, `ActivityInvocation`, `ExecutionPolicy`, `ActivityFailure`, heartbeat snapshot, `WorkerDispatch`/`WorkerAccess`, `LocalWorkerDispatch` for the server); `zeromq4-haskell` (or own FFI), `async`, `stm`, `uuid`, `bytestring`, `text`, `lukko`/FFI flock, `optparse-applicative`, `unix`. **No kernel dependency.**
- Order: `Wire` (pure encode/decode + golden tests) can start immediately on `petrus-json`; client/server need the Activity/Dispatch values and `LocalWorkerDispatch`; buildable in parallel with the kernel, Engine, Absurd and the Worker runtime (only the `AsyncWorker`-over-native-access tests need the Worker).

## 9. Private execution and Gondolin

### Execution territory contract (`motus/execution`)

All paths below are relative to `upstream/petrus`. The execution substrate has no
dependency on the kernel. Nothing under `motus/execution` or `motus/_execution`
imports `petrus.impetus.*`, and `agenticus` is its only consumer
(`agenticus/attachment/{episode,binding,_retention}.py`, `agenticus/hands/workspace.py`,
`agenticus/runtime/{codex,pi,pi_a2_host,pi_application,claude}.py`).

#### 1. Responsibility & public API

`src/petrus/motus/execution/__init__.py` is the supported provider-neutral contract.
`src/petrus/motus/_execution/model.py` only re-exports it, and its types must stay
identity-equal (`test_private_model_location_is_identity_compatible_without_owning_types`).
The exact `__all__` is asserted by `test_public_surface_is_exact_optional_safe_and_owns_its_values`.

Constants (`execution/__init__.py:21-25`):

| Name | Value |
| --- | --- |
| `MAX_COMMAND_OUTPUT_BYTES` | `1_000_000` (stdout+stderr combined) |
| `MAX_PRIVATE_FILE_BYTES` | `1_000_000` |
| `MAX_PRIVATE_FILE_NAME_BYTES` | `64` |
| `MAX_PRIVATE_FILES_PER_ATTACHMENT` | `16` |
| `MAX_PRIVATE_FILE_TOTAL_BYTES` | `4_000_000` |

String enums (`:28-64`). Values are part of the contract because they are compared as strings:

- `EnvironmentCapability`: `command-cancellation`, `container`, `explicit-environment`, `microvm`,
  `private-file-transfer`, `process-group`, `recreatable-lookup`, `territory-cancellation`, `vm`,
  `workspace`. Capability sets are **open** `frozenset[str]` (providers "may additionally advertise
  extensions"), so the enum only names the shared keys.
- `LeaseState`: `ready | terminal | uncertain`.
- `ReconcileClass`: `terminal | retryable | uncertain`.
- `CleanupDisposition`: `clean | not-created | unverified`.

Frozen value types and their validation:

| Type | Fields | Invariants |
| --- | --- | --- |
| `EnvironmentSpec` (`:87-97`) | `image: str\|None`, `required_capabilities: frozenset[str]` | `_text`: non-empty, trimmed, no char < 0x20 (`:67-75`). A bare `str` is rejected as the capability iterable (`:78-84`). |
| `LeaseIdentity` (`:100-111`) | `operation_id, provider, lease_id` | all `_text` |
| `EnvironmentLease` (`:114-135`) | identity fields + `capabilities`, `state: LeaseState` | `.identity` property. Equality is full-field, **including state and capabilities**. |
| `ExecutionAttachment` (`:138-153`) | `attachment_id`, `lease`, `input_digest`, `workspace: Path` | the workspace is a provider-local or guest path |
| `Command` (`:156-213`) | `argv: tuple[str,...]`, `cwd: Path='.'`, `environment: Mapping[str,str]={}`, `timeout: float\|None`, `output_limit: int=1_000_000`, `is_current: Callable[[],bool]\|None` (excluded from eq/repr), `private_roots: Mapping[str, PrivateFileRef]` (excluded from repr) | argv must be non-empty and not one `str`, with no NUL. cwd is relative. timeout is `None` or a finite `>0` int/float that is not a bool. `0 <= output_limit <= 1_000_000`, not a bool. Env names match `[A-Za-z_][A-Za-z0-9_]*`, with no NUL in names or values. At most 16 private roots, each named by the env-name regex, not overlapping `environment`, with `PrivateFileRef` values. Mappings are snapshotted (`MappingProxyType` of a copy). |
| `ExecutionProvenance` (`:216-232`) | `operation_id, provider, lease_id` | `.identity` |
| `PrivateFile` (`:247-259`) | `name`, `content: bytes` (repr=False) | name rule `_private_file_name` (`:235-244`): ASCII only, `[A-Za-z0-9][A-Za-z0-9._-]*`, ≤64 bytes, not `.` or `..`. Content ≤1 MB. |
| `PrivateFileRef` (`:262-276`) | `file_id, name, attachment_id, provenance` | path-free (no `path`, `digest`, or `size` attributes) |
| `PrivateFileCleanupResult` (`:279-307`) | `attachment_id, provenance, disposition, removed=0, detail='', physical_erasure_guaranteed=False` | `removed >= 0` and not a bool. `verified` ⇔ disposition ∈ {clean, not-created}. |
| `CommandResult` (`:310-332`) | `returncode:int, stdout:bytes, stderr:bytes, timed_out, superseded, output_truncated, provenance` | `len(stdout)+len(stderr) <= 1_000_000` |
| `ReconcileResult` (`:335-353`) | `classification, lease=None, detail=''` | `terminal` requires a lease, and `retryable` forbids one |
| `CleanupResult` (`:356-376`) | `identity: LeaseIdentity, disposition, detail=''` | `verified` ⇔ disposition ∈ {clean, not-created} |

Protocols (`:379-417`, both `runtime_checkable`):

```python
class EnvironmentProvider(Protocol):
    provider: str; capabilities: frozenset[str]
    def create(self, operation_id: str, spec: EnvironmentSpec) -> EnvironmentLease: ...
    def lookup(self, operation_id: str) -> EnvironmentLease | None: ...
    def attach(self, lease, workspace_archive_bytes: bytes, input_digest: str) -> ExecutionAttachment: ...
    def execute(self, attachment, command: Command) -> CommandResult: ...
    def export(self, attachment) -> bytes: ...
    def cancel(self, lease, reason: str) -> None: ...
    def reconcile(self, operation_id: str) -> ReconcileResult: ...
    def destroy(self, lease) -> CleanupResult: ...
class PrivateFileTransfer(EnvironmentProvider, Protocol):
    def import_private_file(self, attachment, value: PrivateFile) -> PrivateFileRef: ...
    def export_private_file(self, attachment, reference) -> PrivateFile: ...
    def delete_private_file(self, attachment, reference) -> PrivateFileCleanupResult: ...
    def cleanup_private_files(self, attachment) -> PrivateFileCleanupResult: ...
```

Every concrete provider also has `provision(operation_id, spec)` as a
"compatibility spelling" for `create`. Tests use it heavily.

Cross-provider semantic rules (they hold for every provider and the Haskell port must keep them):

- **Lookup-first creation.** `create` checks `required_capabilities ⊆ provider.capabilities`
  first. A mismatch raises `ValueError("unsupported capabilities: [sorted list]")`, and this check
  runs *before* reusing an existing operation (`test_create_checks_capabilities_before_reusing_an_existing_operation`).
  The provider then looks up `operation_id`. If a lease exists with the same spec fingerprint it
  is returned. A different fingerprint raises `ValueError("operation id collides with a materially different environment spec")`.
- **Pre-launch supersession.** If `command.is_current` is set and returns `False` before launch,
  the result is `CommandResult(-SIGTERM (=-15), b"", b"", timed_out=False, superseded=True, output_truncated=False, provenance)`.
- **Fail-closed destroy.** A lease whose provider is foreign yields
  `CleanupResult(identity, UNVERIFIED, "lease belongs to a different provider")`. An
  identity mismatch yields `UNVERIFIED`. An absent lease yields `NOT_CREATED`, except in Local,
  where only a lease minted by the same adapter instance counts as not-created. Destroy never raises.
- **Provider-only cleanup.** Destroy removes the territory only. It never touches a Thread
  or Episode (`providers.py:683`, `:940`).
- **One active command per territory.** A second concurrent command raises a `RuntimeError`
  ("already has an active command", "command already active").

#### 2. Wire formats, durable schemas, protocols

The contract types have no wire format of their own: they are in-process values.
`agenticus` persists lease identity fields and capability strings elsewhere, so
**capability key strings, `LeaseState`, and `CleanupDisposition` values are durable strings**.
The spec fingerprint shared by Local, Docker, E2B, and Gondolin is the following
(`_execution/providers.py:77-79` and the duplicate at `_execution/gondolin.py:70-72`):

```python
material = json.dumps({"image": spec.image}, sort_keys=True, separators=(",", ":"))
fingerprint = hashlib.sha256(material.encode()).hexdigest()
```

That is, `sha256('{"image":"<image JSON-escaped, ensure_ascii=True>"}')` or
`sha256('{"image":null}')` as lowercase hex. Use `petrus-json` (`ensure_ascii` escapes
non-ASCII as `\uXXXX` and astral characters as surrogate pairs). Docker labels, E2B
metadata, and the Gondolin registry all store this value, so Python and Haskell
must compute identical fingerprints to adopt each other's leases.

Operation-id grammars differ by provider, and the difference must be kept:

- Local, Docker, and E2B use `[A-Za-z0-9][A-Za-z0-9_.-]{0,127}` (`providers.py:49`).
- Gondolin uses 1–128 characters from `[A-Za-z0-9_.-]` with **no leading-alphanumeric
  requirement** (`gondolin.py:58-67`).
- Local `create` validates with the strict regex. Local `lookup` does not validate at all.

#### 3. Concurrency & durability semantics

The values are immutable. The protocol itself is synchronous and blocking, and
providers are called from threads (agenticus hosts). `is_current` is a pull-based
currency predicate that providers poll at about 50 ms intervals while a command
runs. If it raises, the provider kills the command or closes the VM and
re-raises (`providers.py:127-132`, `gondolin.py:660-665`).

#### 4. External dependencies

Only the stdlib. Haskell: `text`, `bytestring`, `containers` (`Set Text` for capabilities),
and `petrus-json` for the fingerprint.

#### 5. Upstream tests

`tests/petrus/motus/test_execution_contract.py` has **10** functions:

- public surface and import hygiene: e2b, timeline, and agenticus are not imported. This runs in a subprocess.
- compat-module identity.
- per-provider capability sets, plus `isinstance` against both protocols. Gondolin is constructed with `sdk_module="unused.mjs"` and needs no node.
- foreign-lease destroy is `UNVERIFIED` for all four providers.
- Local lifecycle: create is idempotent; attach, execute, export, and destroy run in order; a second destroy is `NOT_CREATED`; a fresh adapter reports `UNVERIFIED`.
- Local stale identity, and an `rmtree` failure (monkeypatched) that keeps custody.
- the capability check runs before reuse.
- `Command` validation, including `inf` and bool timeouts and a bool or too-large output limit.
- private-file value bounds and the name grammar. Rejected names are `""`, `.`, `..`, `../auth.json`, `auth/json`, `auth\json`, ` auth`, `é`, and 65×`a`.
- one **Docker**-backed lifecycle (`test_docker_public_lifecycle_…`), which needs `docker info` and pulls `POSTGRES_IMAGE` from `conftest.py:27`.

#### 6. Performance

There is nothing to benchmark here beyond validation cost. Smart constructors are O(n) in argv and environment size.

#### 7. Better-the-Haskell-way suggestions

- Use smart constructors that return `Either ExecutionError`:
  - `NonEmpty Text` argv
  - `newtype RelDir` (a relative, NUL-free path)
  - `newtype EnvName` (regex-checked)
  - `newtype Timeout` (positive, finite)
  - `newtype OutputLimit` (0..1e6)
  - `newtype PrivateFileName`
  - `newtype OperationId` with two validators (strict and Gondolin)
- Make `ReconcileResult` a sum type so the invalid combinations cannot be represented:
  `Terminal EnvironmentLease | Retryable Text | Uncertain (Maybe EnvironmentLease) Text`.
- Keep `Capability` as `newtype Capability = Capability Text` with pattern synonyms for the 10 shared
  keys, because the set is open.
- `PrivateFile` content: give it a hand-written `Show` that redacts the content, matching `repr=False`.
  The test checks that the canary is absent from `repr`. The same applies to `Command`'s private roots.
- `is_current`: accept `IO Bool` for parity, and optionally an STM `TVar Bool` variant so a
  currency change wakes the provider immediately instead of waiting for the 50 ms poll.
- Model providers as a record of functions (`EnvironmentProvider IO`) plus an optional
  `Maybe (PrivateFileTransfer IO)`. That replaces `isinstance(provider, PrivateFileTransfer)`, which
  is structural in Python: Docker and E2B are *not* instances because they lack the methods.

#### 8. Packaging

Put this in a new package `petrus-motus-execution`, or in a module tree
`Petrus.Motus.Execution` inside `petrus-motus`. It depends only on `petrus-json`
(fingerprint and registry encoding) and on no part of the kernel, so it can be
built **in parallel with everything**. Keep the E2B adapter behind a cabal flag or
in a separate package, mirroring "the optional SDK loads only when the provider is used".

### Workspace archive codec (`motus/execution/archive.py`, `_execution/artifacts.py:14-208`)

#### 1. Responsibility & public API

`execution/archive.py:15-43` exposes the following:

- `workspace_archive(root: Path) -> bytes`: a deterministic tar of a directory.
- `validate_workspace_archive(data, *, allow_links=True, forbidden_roots=frozenset()) -> None`.
- `extract_workspace_archive(data, destination: Path) -> None`.
- `MAX_WORKSPACE_ARCHIVE_BYTES`.

Limits (`artifacts.py:14-16`): `MAX_ARCHIVE_BYTES = 512 MiB` (the transfer size),
`MAX_ARCHIVE_MEMBERS = 200_000`, and `MAX_EXTRACTED_BYTES = 2 GiB` (the sum of regular-file sizes).

Consumers:

- every provider's `attach` and `export`.
- `agenticus` records `sha256(archive).hexdigest()` as Episode and retention digests
  (`agenticus/attachment/episode.py:101,438,551`, `_retention.py:119,456`).
- `pi_a2_host.py:330-334` calls `validate_workspace_archive(..., allow_links=False, forbidden_roots={".git", STAGE_DIRECTORY})`.

#### 2. Wire formats: the exact deterministic tar layout

`workspace_archive` (`artifacts.py:101-132`) must be reproduced **byte for byte**. Archive
digests are persisted by agenticus and compared across processes. The algorithm:

1. `root` must be a directory, otherwise `ValueError("workspace archive root must be a directory")`.
2. Collect `paths = sorted(root.rglob("*"), key=relative_posix_str)`.
   - Ordering is code-point order of the relative POSIX path string, so `.hidden < a < a-b < a/x < b`.
   - Dotfiles are included. The root itself is excluded.
   - Symlinked directories are **not** followed, because Python 3.14 `rglob` has `recurse_symlinks=False`.
3. If there are more than `MAX_ARCHIVE_MEMBERS`, raise `ValueError("workspace archive has too many members")`.
4. For each path, a regular file that is not a symlink adds `st_size` to a total. Anything that
   is not a dir or symlink raises `ValueError("workspace archive contains an unsupported file")`.
   A total above 2 GiB raises `ValueError("workspace archive exceeds extracted size limit")`.
5. Write with `tarfile.PAX_FORMAT` and, per member, `gettarinfo(path, relative)`. Then set
   `uid = gid = 0`, `uname = gname = ""`, and `mtime = 0`. Regular-file content is streamed in.
6. If the result exceeds 512 MiB, raise `ValueError("workspace archive exceeds transfer size limit")`.

The byte layout below was verified empirically with CPython 3.14.6:

- **Header block (512 B), POSIX ustar.**

  | Field | Bytes | Encoding |
  | --- | --- | --- |
  | name | 100 | NUL-padded |
  | mode | 8 | `%07o\0` of `st_mode & 0o7777` |
  | uid, gid | 8 each | `0000000\0` |
  | size | 12 | `%011o\0` |
  | mtime | 12 | `00000000000\0` |
  | chksum | 8 | `%06o\0 ` (six octal digits, NUL, space) |
  | typeflag | 1 | see the member-type rules below |
  | linkname | 100 | NUL-padded |
  | magic | 8 | `ustar\0` then version `00` |
  | uname, gname | 32 each | all NUL |
  | devmajor, devminor | 8 each | all NUL |
  | prefix | 155 | **always empty**. Python's PAX writer never splits into the prefix. |
  | padding | 12 | NUL |

  Checksum computation follows ustar: the checksum field counts as 8 spaces.

- **Member types.**
  - Regular file: `'0'`.
  - Directory: `'5'`. The name gets a trailing `/` and the size is 0.
  - Symlink: `'2'`, with linkname from `readlink` and mode from `lstat`. The symlink mode is
    platform-dependent: `0o755` on macOS and `0o777` on Linux.
  - **Hard link:** `'1'`. `gettarinfo` keeps an `(st_ino, st_dev)` table per archive. A later
    path whose inode was already emitted, and whose `st_nlink > 1`, becomes `LNKTYPE`. Its
    linkname is the earlier arcname, its size is 0, and its mode comes from that inode.
- **PAX extended header.** One is emitted only for fields that cannot be stored in the ustar
  field: a name or linkname longer than 100 bytes, or any non-ASCII text.
  - The PAX block has name `././@PaxHeader`, typeflag `'x'`, mode `0000000`, uid and gid 0, mtime 0,
    and the same magic.
  - Its records are `"%d %s=%s\n"`, where the decimal length counts the whole record, with keys
    `path` and `linkpath`. Values are UTF-8.
  - The following ustar header stores the name ASCII-encoded with `errors="replace"`. For example,
    `ééé` is stored as `???`, and long names are truncated to 100 bytes.
  - Example: `130 path=nnn…(120 n)…\n`.
- File data is padded with NUL to a 512 multiple.
- **End of archive:** two 512-byte zero blocks, then NUL padding up to a multiple of
  `RECORDSIZE = 10240`. An empty workspace is therefore exactly 10240 zero bytes.
- Mode bits are preserved verbatim, setuid included (for example `0004755`).

Validation (`_validated_workspace_members`, `artifacts.py:135-170`) is one ordered gate
that runs over `tarfile.open(mode="r:*")`. Note that `r:*` transparently accepts gzip, bz2,
xz, and (3.14) zstd compression. The checks run in this order:

1. Reject if there are more than 200 000 members (`"workspace archive has too many members"`).
2. For each member, `name = PurePosixPath(member.name)` is lexically normalized: `//` collapses,
   `.` components drop, and a trailing `/` drops. Any `..` component is **not** collapsed.
   Then:
   1. Reject an absolute name, or any `..` part: `ValueError(f"unsafe archive member: {name!r}")`.
   2. Reject a duplicate normalized name: `"duplicate archive member: …"`.
   3. Reject if `parts[0] ∈ forbidden_roots`: `"forbidden archive member: …"`.
   4. Accept only file, dir, sym, or lnk (GNU `'7'` contiguous counts as a file). Anything else
      raises `"unsupported archive member: …"`.
   5. Sum file sizes. Above 2 GiB, raise `"workspace archive exceeds extracted size limit"`.
   6. For links: with `allow_links=False`, raise `"archive links are not permitted: …"`.
      Otherwise compute `target = PurePosixPath(linkname)`, and
      `resolved = target` for a hardlink or `name.parent / target` for a symlink. If the target
      is absolute, or **any `..` appears in `resolved.parts`**, raise `"unsafe archive link: …"`.
      This means even an in-tree `a/b -> ../c` is rejected. That strictness is an upstream
      quirk to preserve.
3. `validate_workspace_archive` checks `type(data) is bytes` and the 512 MiB limit, and maps
   `tarfile.TarError` to `ValueError("workspace archive is malformed")`.
   `extract_workspace_archive` does **not** wrap `TarError`. The difference matters only for
   error types.

Extraction (`artifacts.py:195-208`) runs `destination.mkdir(parents=True, exist_ok=True)`,
validates with `allow_links=True` and no forbidden roots, then calls
`archive.extractall(destination, members, filter="data")`. The CPython 3.14
`data_filter` semantics are `tarfile.py:781-853`:

- Strip a leading `/`. Reject a name that is still absolute.
- Reject when the `realpath(dest/name)` target falls outside `realpath(dest)`.
- Modes:
  - Every mode is reduced with `mode &= 0o755`, which drops setuid, setgid, sticky, and g/o write.
  - Regular files and hard links: when the owner exec bit is absent, clear all exec bits. Then OR in `0o600`.
  - Directories and symlinks: mode is set to `None`. Directories are created with plain
    `os.mkdir`, so they get the umask default.
  - Any other type raises `SpecialFileError`.
- uid, gid, uname, and gname are set to `None`, so no chown happens.
- Links: reject an absolute linkname, and reject a link whose target is the destination itself.
  The linkname is `normpath`-ed, and its realpath is checked for containment.
- mtime from the archive (0) is applied with `utime`.

**Normalization round trip.** The Docker, E2B, and Gondolin `export` paths, and Gondolin's
`attach`, run `workspace_archive(extract_workspace_archive(raw, tmp))`. So exported archives
always carry data-filtered modes: no setuid, files at least `0600`, and directories at umask defaults.

#### 3. Concurrency & durability

Archive operations are pure, apart from filesystem reads and writes. There is no locking
and no fsync on extraction. Archives are held fully in memory (≤512 MiB).

#### 4. External dependencies → Haskell

The Python side uses `tarfile`, `pathlib`, and `io`. In Haskell, **do not rely on the `tar`
Hackage package for either direction**:

- Its writer splits long names into the ustar `prefix`, writes no PAX headers, and does not pad
  to 10240. The bytes would differ.
- Its reader does not apply PAX `path` and `linkpath` records. A Python archive with a long or
  non-ASCII name would read back as the truncated or `???` ustar name.

Recommendation: write a small pure tar codec in the package, roughly 400 lines over `bytestring`:

- **Writer:** exactly the layout above.
- **Reader:** ustar, PAX `x` (`path`, `linkpath`, `size`), PAX global `g` (ignored, as in Python),
  and GNU `L`/`K` long names. Guest GNU and busybox tar emit these.

For `r:*` parity, add optional decompression via `zlib`, `lzma`, and `zstd`, sniffing magic
bytes. The alternative is the `libarchive` Hackage bindings, which pull in a C dependency and
make it harder to control writer determinism. `zip-archive` is irrelevant because the format is tar.

For extraction, use `unix` together with `directory`. Implement realpath containment with
`System.Directory.canonicalizePath`, but note that it resolves missing suffixes differently
from Python's `ALLOW_MISSING`. A hand-written resolver that resolves the existing prefix and
appends the rest is safer.

#### 5. Upstream tests

In `test_private_execution_substrate.py`:

- `test_tar_rejects_escape_links_and_special_files`: `../escape`, a symlink `../../escape`, a FIFO, and duplicate `same`.
- `test_workspace_archive_member_and_size_limits_are_enforced`, which monkeypatches the module limits.
  The Haskell port needs limits as parameters to test this.
- Indirectly, every lifecycle test round-trips archives.

`test_gondolin_environment.py` checks that mode `0755` survives a round trip
(`mode.sh`). There are no golden-byte tests upstream. **Add Haskell golden tests**: generate
fixtures with CPython 3.14 (`workspace_archive`) for dotfiles, nested dirs, setuid, hard links,
symlinks, 120-character names, non-ASCII names, and an empty dir. Compare SHA-256 values.

#### 6. Performance

This is the main hot path of the substrate. Every attach, and every Docker, E2B, or Gondolin export, does
a full extract and re-archive. Python streams through `tarfile` with per-member `stat` calls and Python-level header encoding.

Benchmark proposal: run the Python function and the Haskell function in the same process environment on
the same directory trees, warm cache, and report median and p95 wall time plus peak RSS:

- **(a)** 10 000 × 1 KiB files in 100 dirs.
- **(b)** 1 000 × 64 KiB files.
- **(c)** 1 × 256 MiB file.

Measure `workspace_archive`, `validate_workspace_archive`, and `extract_workspace_archive`
separately. Equivalence gate: the archive SHA-256 must be identical. Haskell can stream file
content with `hGetSome` into a `Builder`, and build only the final strict `ByteString`
because the API returns `bytes`.

#### 7. Better-the-Haskell-way suggestions

- Separate `newtype WorkspaceArchive = WorkspaceArchive ByteString` from a
  `newtype ValidatedArchive` produced only by the validator, so extraction can demand validated
  input in its type.
- Parse once into `[Member]`, then validate and extract from the same parsed list. Python
  re-opens the archive per call.
- Keep these quirks for interop: the `..` rule on links, the duplicate check on lexically
  normalized names, the 10240 padding, platform-dependent symlink modes (read from `lstat`,
  never hard-coded), and hard-link detection by inode.

#### 8. Packaging

The archive codec goes in the same package as the execution contract (`Petrus.Motus.Execution.Archive`).
It is reusable by agenticus. It needs no kernel and can be built in parallel immediately.

### Local, Docker, and E2B providers (`_execution/providers.py`)

#### 1. Responsibility & public API

Public subclasses live in `execution/providers.py:14-26`. The implementations are in `_execution/providers.py`.

| Provider | `provider` | Capabilities | Territory | `lease_id` |
| --- | --- | --- | --- | --- |
| `LocalProcessEnvironment()` (`:166-757`) | `local-process` | command-cancellation, explicit-environment, private-file-transfer, process-group, workspace | `tempfile.mkdtemp(prefix="impetus-execution-")`, with workspace `<territory>/workspace` | `f"{adapter_instance_uuid4}:{uuid4}"` |
| `DockerEnvironment()` (`:760-989`) | `docker` | container, explicit-environment, recreatable-lookup, territory-cancellation, workspace | container, with workspace `/workspace` | short container id from `docker ps -q` |
| `E2bEnvironment(*, api_key=None, sdk_loader=None, lease_timeout=900)` (`:992-1296`) | `e2b` | command-cancellation, explicit-environment, recreatable-lookup, vm, workspace | E2B sandbox, with workspace `/home/user/workspace` | `sandbox_id` |

**Local provider (state is in memory only: an `RLock` plus dicts, `:178-188`).**

Lease lifecycle:

- **create.** Rejects an image (`"local process environments do not accept an image"`). The
  in-memory lookup compares the stored fingerprint.
- **lookup.** A dict get. Leases do not survive the process, so reconcile always reports
  `UNCERTAIN` "local process completion is not durably recorded" for a known lease, and
  `RETRYABLE` "no local lease" otherwise.
- **attach.**
  1. Requires a current, idle lease.
  2. Verifies that cleanup of the prior attachment's private files is
     `verified`, otherwise `RuntimeError("prior attachment private-file cleanup could not be verified")`.
  3. Removes `<territory>/workspace` and extracts the archive there.
  4. Assigns a new `uuid4` attachment id.
- **export.** `workspace_archive(attachment.workspace)` with no normalization round trip.
- **cancel.** `killpg(SIGTERM)` on an active process with a matching identity.
- **destroy** (`:682-749`).
  1. Applies the identity gates. A lease absent from this adapter is `NOT_CREATED` only when the
     `lease_id` starts with this adapter's instance id, and `UNVERIFIED` otherwise.
  2. Sends `killpg SIGTERM`, waits 0.5 s, then sends `SIGKILL` and waits 1 s.
  3. Runs `rmtree(territory)`. A failure or a remaining territory yields `UNVERIFIED`, and the
     state is retained.
  4. Drops all state.

**Local execute** (`:618-664`):

1. Validate the attachment, then run the pre-launch currency check.
2. Under the lock, compute the private bindings. Each private root is re-read and verified first
   (`_private_bindings_locked`, `:579-590`).
3. **The environment is exactly** `command.environment ∪ {ROOT_NAME: "<territory>/private/<file_id>"}`.
   No host variables are inherited, not even `PATH`. Python's `Popen(env=…)` resolves `argv[0]`
   with `os.get_exec_path(env)`, which falls back to `os.defpath = "/bin:/usr/bin"`.
   **Haskell must resolve `argv[0]` against the command env's `PATH`, or `/bin:/usr/bin` when it
   is absent.** The libc `execvpe` used by `process` searches the *parent's* PATH.
4. `cwd = (workspace/cwd).resolve()` must be inside `workspace.resolve()`, so symlinks are
   followed (`_checked_host_cwd`, `:88-92`, and `test_local_cwd_still_resolves_symlinks_before_containment`).
5. Spawn with `start_new_session=True` (setsid). The process is registered in `_processes` so the territory is busy.
6. Collect output with `_collect` (`:112-143`):
   1. Loop on `communicate(timeout=min(0.05, remaining))`.
   2. On each timeout, compute the partial output size against `output_limit` (overflow),
      evaluate `is_current()` (superseded), and check the deadline (timed_out).
   3. On any trigger, run `killpg(SIGTERM)`, `communicate(timeout=0.5)`, and on expiry `killpg(SIGKILL)`.
7. Build the result in `_result` (`:146-163`):
   - `returncode` is `Popen.returncode` (`-signum` when signalled).
   - Truncation is **stdout-priority**: `stdout[:limit]`, then `stderr[:limit - len(stdout)]`.
   - `truncated = overflow or len(stdout)+len(stderr) > limit`.
8. Redact every private-root path in stdout and stderr to `b"[PRIVATE_ROOT]"` (`:592-616`).

Expected results for a TERM-ignoring process on timeout: `timed_out=True, returncode=-9`
(`test_local_collection_drains_large_output_and_kills_sigterm_ignoring_process`).

**Local private files** (`:253-590`). Each file lives at `<territory>/private/<file_id=uuid4().hex>/<name>`, with these invariants:

- Directories are mode `0700` and owned by the euid.
- The file is regular, mode `0600`, owned by the euid, with `nlink == 1`.
- Every access walks `O_RDONLY|O_DIRECTORY|O_NOFOLLOW` opens with `dir_fd`, which is openat-style.

Operations:

- **Import:** `O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW` with `0600`, then a write loop and `fsync`.
  Bounds are checked per attachment: 16 files and 4 MB in total. On failure the whole root is
  discarded, with `"private file import failed"` or `"…and cleanup could not be verified"`.
- **Export:** reads at most 1 MB + 1 bytes and compares the `fstat` identity tuple
  `(dev, ino, mode, uid, nlink, size, mtime_ns, ctime_ns)` before and after. A mismatch, or any
  `OSError` or invariant failure, raises `RuntimeError("private file export could not be verified")`.
- **Delete:** clean only if the leaf invariant held, the unlink and rmdir succeeded, and the root
  is absent. Repeating a delete gives `NOT_CREATED` if it was verified-absent before, otherwise
  `UNVERIFIED`. A stale, foreign, or active attachment gives `UNVERIFIED` with detail
  `"private-file attachment is stale, foreign, or active"`.
- **cleanup_private_files:**
  - The result is `CLEAN` if anything was removed, `NOT_CREATED` if nothing was, and `UNVERIFIED` otherwise.
  - It also removes the empty `private/` parent.
  - It is memoized per `(lease_id, attachment_id)` in `_private_cleaned`, so a repeat yields `NOT_CREATED`.

Every private operation requires an idle territory, otherwise `RuntimeError("private-file operation requires an idle territory")`.

**Docker** (`:760-989`) shells out to the `docker` CLI through `_docker(*args, check=True, input=None, timeout=120)`.

Calls used (the exact argv is the protocol):

| Operation | Command |
| --- | --- |
| lookup | `docker ps --all --quiet --filter label=run.petrus.operation=<op>`. More than one result raises `RuntimeError("operation … resolves to multiple containers")`. Then `docker inspect <id>`: any mount with `Type == "bind"` raises. The state is READY if `State.Running`, otherwise TERMINAL. |
| create | Check `Config.Labels["run.petrus.spec"]` against the fingerprint. An existing TERMINAL lease raises `RuntimeError("operation has a terminal prior territory; reconcile before retrying")`. Otherwise run `docker run --detach --label run.petrus.operation=<op> --label run.petrus.spec=<fingerprint> --workdir /workspace --entrypoint /bin/sh <image> -c "mkdir -p /workspace; while :; do sleep 3600; done"`, then look up again. If the lookup misses, run `docker rm --force <id>` and raise. |
| attach | First a host-side `extract_workspace_archive` into a temp dir (validation only). Then `docker exec -i <id> sh -c "rm -rf /workspace && mkdir /workspace && tar -xf - -C /workspace"` with the archive on stdin. |
| execute | Private roots raise `ValueError("Docker does not support the private-file-transfer capability")` **before any lookup**. Otherwise run `docker exec --workdir <guest cwd> [--env NAME]… <id> sh -c 'exec env -i NAME="${NAME}" … "$@"' petrus-command <argv…>`. The docker CLI's own env is `{HOME, PATH, DOCKER_*}` from the host plus `command.environment`, so **secret values never appear in argv** (`test_docker_command_credentials_are_not_exposed_in_host_argv`). Terminate with `docker kill --signal TERM <id>`, kill with `docker kill <id>`. Supersession or a timeout kills the *whole container*. |
| export | `docker exec <id> tar -cf - -C /workspace .` (timeout 60), followed by a host normalization round trip. |
| cancel / destroy | `docker kill <id>`, then `docker rm --force <id>` and a re-lookup to verify. |
| reconcile | No container gives RETRYABLE, TERMINAL gives TERMINAL, otherwise UNCERTAIN "container readiness does not prove operation outcome". A lookup error gives UNCERTAIN with `str(error)`. |

The guest cwd is computed by `_checked_guest_cwd(workspace, rel)` (`:95-109`). It is lexical,
pops on `..`, and raises `ValueError("command cwd escapes the workspace")` when it climbs above
the workspace. It never touches the host filesystem: tests monkeypatch `Path.resolve` to prove this.

**E2B** (`:992-1296`) uses the Python `e2b` SDK, loaded lazily through `sdk_loader`. The API key
comes from the `api_key` argument or the `E2B_API_KEY` environment variable, and is passed as `api_key=` only when set.

- **lookup:** `Sandbox.list(query=SandboxQuery(metadata={"run.petrus.operation": op}), limit=2)` with pagination.
  State `running` or `paused` maps to READY.
- **create:** `Sandbox.create(template=image, timeout=lease_timeout, metadata={op label, spec label}, envs={}, secure=True)`.
  A lookup failure after create kills the sandbox and re-raises.
- **attach:** writes `/tmp/petrus-input-<uuid4>.tar` and runs
  `rm -rf /home/user/workspace && mkdir -p … && tar -xf <path> -C …` (timeout 60), then removes the file.
- **execute:** `commands.run(shlex.join(argv), background=True, envs=command.environment, cwd=<guest cwd>, timeout=max(command.timeout or lease_timeout, 1))`.
  - A daemon thread runs `handle.wait(on_stdout, on_stderr)`, and the main thread polls every 50 ms
    for overflow, supersession, and the deadline. A trigger calls `handle.kill()` and joins for 5 s.
  - A transport exception without `exit_code` is re-raised (`"transport failed"`), unless a trigger fired.
  - Output arrives as text and is re-encoded as UTF-8, which is lossy for binary output.
- **export:** `tar -cf /tmp/petrus-output-<uuid>.tar -C /home/user/workspace .`, then `files.read(format="bytes")`, then normalization.
- **destroy:** `cancel`, `Sandbox.connect` if not cached, `sandbox.kill()`, then a re-lookup.

#### 2. Wire formats / protocols

These are the interop-relevant strings:

- **Docker labels and E2B metadata keys:** `run.petrus.operation` (the operation id) and `run.petrus.spec`
  (the fingerprint). A Haskell process must label containers identically for Python to adopt them, and vice versa.
- **Guest paths:** `/workspace` for Docker and Gondolin, `/home/user/workspace` for E2B.
- **Wrapper argv:** `petrus-command` is used as `$0`.
- **Local territory prefix:** `impetus-execution-`.
- **Redaction tokens:** Local uses `[PRIVATE_ROOT]`. Gondolin uses `[private-root]` in lowercase.
  The inconsistency is an upstream quirk to preserve.
- **E2B REST and envd protocols:** used only through the Python SDK. There is no Haskell SDK.

#### 3. Concurrency & durability semantics

| Provider | Concurrency | Durability |
| --- | --- | --- |
| Local | One `threading.RLock` serializes all state changes. `execute` holds it only around validation and launch. The territory is "busy" while the lease id is in `_launching` or `_processes`. | None. All state is lost when the process exits (by design). |
| Docker | No lock. `_processes` provides single-flight per adapter instance only. | Container labels are the store. Lookup-first recovery works across processes and restarts. |
| E2B | Same as Docker, plus a waiter thread. | Sandbox metadata is the store. |

Timeouts: Docker control commands 120 s, Docker export 60 s, E2B control commands 60 s, and the E2B lease timeout defaults to 900 s.

#### 4. External dependencies → Haskell

- **Process control:** `typed-process` or `process`, plus `unix` (`signalProcessGroup`, `createSession` via `setNewSession`).
  Read stdout and stderr concurrently with `async`, enforce deadlines with `timeout`, and use
  `System.Posix` for `-signum` exit codes. Note that `process` reports a signal death as
  `ExitFailure (-signum)`, which matches Python.
- **openat-family private-file operations:** `unix` ≥ 2.8 has `openFdAt`. For `mkdirat`,
  `unlinkat`, `fstatat(AT_SYMLINK_NOFOLLOW)`, `fchmod`, and `fdopendir`/`readdir`, plan for small FFI
  shims. Not all of these are exposed by `unix`, so verify against the version pinned for GHC 9.10.
- **Docker:** shell out to the `docker` CLI, exactly as upstream does. Do not use a Docker API library, because the argv is the contract.
- **E2B:** **no adequate Haskell package exists.** The options are:
  1. Implement the E2B REST control plane plus the envd Connect/gRPC protocol over `http-client`.
     This is sizeable and has no test parity beyond the fake SDK.
  2. Keep E2B out of the first Haskell release. It is `real_provider_acceptance`-only upstream.
  3. Wrap the Python SDK in a sidecar, the way Gondolin is wrapped.

  Recommendation: option 2 first. Keep the `EnvironmentProvider` record open so it can be added later.

#### 5. Upstream tests

- **`test_private_file_transfer.py` (6 functions, all hermetic):**
  - the full Local custody route: a canary never reaches the workspace or the export, and stdout is `[PRIVATE_ROOT]`.
  - attachment and lease fencing.
  - symlink replacement never reads or unlinks the target.
  - exclusion while a command is active (threaded).
  - bounds, using monkeypatched module constants.
  - Docker and E2B reject private roots before lookup.
- **`test_private_execution_substrate.py` (23 functions; 2 are parametrized, so 25 items):**
  - The `environment` fixture is parametrized over `("local","docker")`, so `test_provider_neutral_lifecycle…` runs twice.
  - `test_e2b_vm_command_timeout_and_supersession…` is parametrized `[(0.02,"timed_out"),(2,"superseded")]`.
  - Docker needed: the docker parameter, `test_docker_lookup_first…`, and `test_cross_provider_workspace_handoff…`.
    They call `docker info` with `check=True`, so they **fail rather than skip** without Docker.
    `test_docker_command_credentials…` monkeypatches `Popen` and needs no Docker.
  - E2B tests use an in-file fake SDK (`_FakeE2bSandbox` and friends). `test_live_e2b_vm_provider_is_explicitly_opt_in`
    is `@pytest.mark.real_provider_acceptance` and also needs `PETRUS_RUN_CV10_E2B=1`, `E2B_API_KEY`, and `PETRUS_CV10_E2B_TEMPLATE`.
  - Also covered here: Local, Timeline, and ArtifactStore tests, the cwd symlink test, and output draining or SIGKILL escalation.
- **`test_execution_contract.py`:** one Docker test (see the contract section).
- `scripts/check` deselects `not real_provider_acceptance and not real_gondolin_acceptance and not qualification_installation` for the routine suite.

#### 6. Performance

- Local `execute` latency: spawn plus collect. Python's 50 ms `communicate` polling adds no latency on
  normal exit, but checks currency and overflow at most every 50 ms.
- Benchmark proposal: 1 000 × `execute(Command(("/bin/true",)))` on one attached Local territory.
  Report p50 and p99 latency, and the throughput of `head -c 1000000 /dev/zero` with `output_limit=1_000_000`.
- In Haskell, read the pipes in `async` threads with a bounded retained buffer. Keep at most `limit`
  bytes of each stream, which is enough to reproduce the stdout-priority split exactly. Python
  buffers everything until the next poll.

#### 7. Better-the-Haskell-way suggestions

- Event-driven collection instead of polling: `race` the process wait against
  `timeout`, an overflow `MVar`, and the currency poll or `TVar`. Keep the observable precedence:
  `timed_out`, `superseded`, and `output_truncated` can all be true together.
- `bracket`/`ResourceT` for every fd in the private-file tree. Python manages a descriptor list by hand.
- Store Local state in a single `MVar LocalState`, or in `TVar`s, keeping the "busy" set inside the same transaction.
- Quirks to preserve:
  - Local destroy's `NOT_CREATED` versus `UNVERIFIED` depends on the adapter-instance prefix of `lease_id`.
  - Docker supersession kills the whole container.
  - Truncation is stdout-priority.
  - There is no PATH inheritance, and argv[0] resolves against `/bin:/usr/bin`.

#### 8. Packaging

- Local and Docker belong in the `Petrus.Motus.Execution.Providers.{Local,Docker}` modules of the execution package.
- E2B is deferred, or goes in a separate `petrus-motus-execution-e2b` package.
- Depends on the archive codec and `petrus-json`. Parallelizable with all kernel work.

### Gondolin provider and sidecar (`_execution/gondolin.py`, `_execution/gondolin_sidecar.mjs`)

#### 1. Responsibility & public API

```python
GondolinEnvironment(state_root: Path, *, sdk_module: str, node: str = "node",
                    lease_ttl: float = 900, startup_timeout: float = 120,
                    sidecar: Path | None = None)
```

(`gondolin.py:143-169`.) It implements `EnvironmentProvider` and `PrivateFileTransfer`.

- `provider = "gondolin"`.
- `capabilities = {explicit-environment, microvm, private-file-transfer, recreatable-lookup, territory-cancellation, vm, workspace}` (`:45-55`).
- `sdk_module` is required and must be non-empty. It is a `file:` URL or a path to the Gondolin SDK ESM entry.
- `state_root` is created with mode `0700`.
- The sidecar defaults to the packaged `gondolin_sidecar.mjs`. `tests/project/test_distribution.py:73` asserts that the file ships in the wheel.

One **Node sidecar process per lease** owns one Gondolin microVM (QEMU) and exposes a
**Unix-domain-socket JSON-lines** API. The provider is "durable": the registry on disk lets any
process, Python or Haskell, recreate the adapter, `lookup` the lease, and drive or destroy the
same sidecar. SCOPE.md requires that the Haskell port **keep the sidecar `.mjs` verbatim and
speak this protocol**.

#### 2. Wire formats, durable schemas, protocols

**2.1 State-root layout (the shared durable store).**

```
<state_root>/                                   mode 0700
  <sha256(operation_id.encode()).hexdigest()[:24]>/   mode 0700   (_directory, :171-172)
    lock              0600  flock(LOCK_EX) target (never deleted except on destroy/rollback)
    registry.json     0600  written atomically (see below)
    registry.<uuid4hex>.tmp   transient
    workspace/        0700  host transfer dir, mounted in guest at /petrus-transfer
      input.tar       0600 transient (attach)
      output.tar      transient (export, written by guest)
/tmp/petrus-g-XXXXXXXX/                         mode 0700  "runtime" (tempfile.mkdtemp(prefix="petrus-g-", dir="/tmp"))
  s                   0600 Unix socket (chmod after listen)
  stderr              0600 sidecar stderr
  sessions/           GONDOLIN_SESSIONS_DIR (SDK session registry)
  (TMPDIR for node + SDK)
```

The runtime path is stored **unresolved**. On macOS `/tmp` is a symlink, and
`_remove_runtime` (`:219-234`) refuses to delete unless all of the following hold, raising
`RuntimeError("Gondolin runtime custody is uncertain; registry retained")` otherwise:

- `Path(runtime).parent == Path("/tmp")` (lexical comparison).
- the name starts with `petrus-g-`.
- it is not a symlink and is a directory.
- it is owned by the current uid.

The socket path must stay short: macOS `sun_path` is 104 bytes, and the test asserts `< 100`.

**2.2 `registry.json`** (`_write`, `:206-217`). The encoding is
`json.dumps(record, sort_keys=True)`: default separators `", "` and `": "`, `ensure_ascii=True`,
and **no trailing newline**. It is written to `registry.<uuid4hex>.tmp` with `O_CREAT|O_EXCL|O_WRONLY` and mode `0600`,
then `fsync`ed and `os.replace`d. There is no directory fsync. Fields:

| Key | Type | Value |
| --- | --- | --- |
| `boot_token` | str | `secrets.token_urlsafe(32)`: 32 random bytes as base64url without padding (43 chars) |
| `group_identities` | {str(pid): marker} | Added after startup, and extended after the private probe |
| `image` | str | `spec.image` |
| `lease_id` | str | `str(uuid.uuid4())` |
| `operation_id` | str | |
| `pgid` | int | Equals `pid` (a new session) |
| `pid` | int | Sidecar node pid |
| `private_file_transfer` | bool | Present (`true`) only once the private probe succeeded |
| `runtime` | str | `/tmp/petrus-g-…` |
| `sdk_module` | str | |
| `sdk_version` | str | `"0.12.0"` |
| `socket` | str | `<runtime>/s` |
| `spec_fingerprint` | str | See the contract section |
| `start_identity` | {state, marker?, command?} | `_identity(pid)` at spawn |
| `workspace` | str | `<dir>/workspace` |

Readers (`_read`, `:199-204`) use plain `json.loads` and tolerate extra keys. Haskell must:

- tolerate a missing `group_identities` (the first write lacks it) and a missing `private_file_transfer`.
- emit the same key set, preferably with byte-identical `petrus-json` encoding (`sort_keys`, default separators).

**Process identity markers** (`_identity`, `:75-106`). These are durable values compared across processes:

- Linux (if `/proc` is a directory):
  - `marker = f"{boot_id}:{fields[21]}"`. The boot id is `/proc/sys/kernel/random/boot_id` stripped, or
    `""` if unreadable. `fields = /proc/<pid>/stat .read_text().split()`. This is naive whitespace
    splitting, so index 21 is the start time when `comm` has no spaces, and it must be replicated exactly.
  - `command` = `/proc/<pid>/cmdline` with NUL replaced by a space, decoded with `errors="replace"`, and stripped.
  - `FileNotFoundError` gives `{"state":"missing"}`. Other errors fall back to `ps`.
- Elsewhere, or on fallback (`_ps_identity`, `:75-82`): run `ps -o lstart= -o command= -p <pid>`.
  - A non-zero exit or empty output gives `{"state":"missing"}`.
  - Otherwise `line = stdout.strip()`, `marker = line[:24].strip()` (the lstart text, for example `Sat Oct 10 12:00:00 2026`), and `command = line[24:].strip()`.
  - An `OSError` gives `{"state":"uninspectable"}`.
- Group members (`_group_members`, `:109-116`): `ps -axo pid=,pgid=,command=`. Split each line
  with `maxsplit=2` and keep the rows whose pgid matches.
- `_group_identities` (`:119-132`) skips members that are `missing`. Any other non-present state, or an empty marker,
  raises. It requires `identities[str(pid)] == start_identity.marker`, otherwise
  `"Gondolin sidecar identity changed during startup"`.

**2.3 Sidecar spawn** (`create`, `:371-406`). Argv:

```
<node> <sidecar.mjs> <runtime>/s <lease_id> <state dir>/workspace <image> <str(lease_ttl)> <"private"|"standard">
```

- The last argument is `"private"` iff `private-file-transfer ∈ spec.required_capabilities`.
- `str(lease_ttl)` is Python's `str`, so `900` or `0.1`. JS parses it with `Number()`, so Haskell may
  emit `900.0`, but emitting `"900"` keeps argv identical.

Process setup:

- stdin and stdout go to `/dev/null`. stderr goes to `<runtime>/stderr` (opened `wb`, then chmod `0600`).
- `start_new_session=True`, so the sidecar is a session and group leader with pgid = pid.
- The sidecar **outlives** the spawning process (no kill on exit).

**Environment (exact allowlist):** `GONDOLIN_IMAGE_STORE`, `HOME`, `PATH`, and `XDG_CACHE_HOME` when
set in the host env, plus:

- `TMPDIR=<runtime>`
- `GONDOLIN_SESSIONS_DIR=<runtime>/sessions`
- `PETRUS_GONDOLIN_BOOT_TOKEN=<token>`. The sidecar deletes it from `process.env` at startup (`sidecar:11-12`).
  The test asserts the token is not in the process command line.
- `PETRUS_GONDOLIN_SDK=<sdk_module>`

Any other host secret (for example `GITHUB_TOKEN`) must not reach the sidecar or the guest.

**2.4 Sidecar startup** (`gondolin_sidecar.mjs:1-59, 582-586`). Node is **≥ 23.6**, which is
required unless the SDK exports `PETRUS_FAKE`.

1. Parse argv `[socketPath, leaseId, workspace, image, ttlText, startupMode]`.
2. Require the token and SDK env vars. `moduleUrl` is the `file:` URL as given, or `pathToFileURL(path.resolve(p))`. Then `await import(moduleUrl)`.
3. **Version gate:**
   - With `sdk.PETRUS_FAKE`, the version is `sdk.VERSION ?? sdk.version`.
   - Otherwise walk up from the module dir to a `package.json` whose `name === "@earendil-works/gondolin"` and take its `version`.
   - The version must equal `"0.12.0"`, otherwise it throws `Gondolin SDK 0.12.0 required, found X`.
4. Required public exports, each a function: `VM`, `RealFSProvider`, `createHttpHooks`, `resolveImageSelector`, `loadGuestAssets`.
5. **Gondolin SDK calls, in order:**
   1. `const { httpHooks } = sdk.createHttpHooks()`.
   2. `sdk.resolveImageSelector(image)` returns `{assetDir: string}`.
   3. `sdk.loadGuestAssets(assetDir)` returns `imageAssets`. Any failure in steps 2–3 becomes `Error("Gondolin local image is unavailable")`. The image-store path is sanitized out of the message, which the test checks.
   4. `await sdk.VM.create({ sandbox: { vmm: "qemu", imagePath: imageAssets, netEnabled: true }, vfs: { mounts: { "/petrus-transfer": new sdk.RealFSProvider(workspace) } }, httpHooks })`.
      The fake SDK asserts these exact keys.
6. Remove any stale socket, call `server.listen(socketPath)`, then `chmod 0600`.
7. **Lease timer:** `armLeaseTimer(startupMode === "private" ? max(ttl, 60) : ttl)` seconds, using `unref()`.
   - The TTL is **absolute from start, not idle-based**, and is never refreshed by requests.
   - The exception is `private_probe`, which re-arms to `max(ttl,60)` during the probe and to `ttl` after it succeeds.
   - On expiry the sidecar calls `close()`.
8. SIGTERM and SIGINT call `close()`. On `exit`, the socket file is removed.

A startup failure throws an uncaught error. Node exits non-zero with the stack on stderr.
Python reports it as `RuntimeError("Gondolin sidecar failed to start: " + last 1000 bytes of stderr decoded with errors="replace")` (`:302-304`).

**2.5 Socket framing (what the Haskell client must speak).**

- `AF_UNIX`, `SOCK_STREAM`, at `record["socket"]`. **One request per connection.**
- The client sends one UTF-8 JSON object followed by `\n`. The server parses the bytes up to the first
  `\n` (`sidecar:553-562`) and ignores anything after it.
- If the buffer exceeds `MAX_FRAME = 8 MiB` before a newline, the server replies `{"ok":false,"error":"request too large"}`.
- The server replies with exactly one line, `JSON.stringify(value) + "\n"`, then calls `connection.end()` (a half-close).
- The client reads until a `\n` appears, rejecting responses above 8 MiB (`RuntimeError("Gondolin sidecar response is too large")`).
  It parses the first line. EOF before a newline raises `ConnectionError("Gondolin sidecar closed without a response")`.
  `ok` false raises `RuntimeError(response.get("error", "Gondolin sidecar request failed"))` (`_request`, `:236-254`).
- Every request carries `"lease_id"` and `"boot_token"`. Python appends them after the action fields.
  The sidecar uses `JSON.parse`, so key order and spacing are irrelevant.
  - `_request` uses compact `separators=(",", ":")`. The `execute` path uses default `json.dumps`.
  - Both use `ensure_ascii=True`. Any valid JSON is accepted.
- Client socket timeouts: `_request` defaults to 2 s (handshake, status, close). `attach`, `export`, and all `private_*` actions use 60 s.
  `execute` uses a 0.05 s recv timeout as a poll tick with no overall timeout (`:641-668`).

Server dispatch order (`sidecar:548-580`):

1. Invalid JSON gives `invalid request`.
2. `validRequest` fails (an unknown action, or a malformed execute) gives `invalid request`.
3. `lease_id` or `boot_token` mismatch gives `authentication failed`.
4. `handshake` and `status` are always answered.
5. `close` is always answered `{ok:true}`, *then* the VM closes.
6. While `active`, any other request gets `command already active`.
7. `attach`/`export` go to `transferWorkspace`. `attach` requires a valid `attachment_id`, otherwise `invalid transfer request`.
8. `private_*` actions pass `validPrivateRequest` (otherwise `invalid private request`), then go to `privateAction`.
9. Anything else goes to `execute`.

**2.6 Message catalogue.** Every request also carries `lease_id` and `boot_token`. Every error reply is `{"ok":false,"error":<string>}`.

| action | request fields | success reply | notes |
| --- | --- | --- | --- |
| `handshake` / `status` | none | `{"ok":true,"lease_id":L,"version":"0.12.0","runtime":process.version (e.g. "v23.6.0"),"active":bool,"closing":bool}` | Python `_handshake` (`:256-264`) requires `version == "0.12.0"`, the same `lease_id`, and `closing` falsy. Otherwise it raises `"Gondolin sidecar identity or SDK version mismatch"`. `status` is used only by tests, to poll `active`. |
| `close` | none | `{"ok":true}` | Then `vm.close()`, server close, and socket removal. If `vm.close` throws, all connections are destroyed, a message goes to stderr, and the sidecar runs `process.kill(-pid,"SIGKILL")`, killing its own group (`sidecar:299-319`). Idempotent: a memoized promise. |
| `attach` | `attachment_id` (trimmed, non-empty, ≤128 UTF-8 bytes) | `{"ok":true}` | Precondition: the host wrote `input.tar` into the transfer dir. Guest steps: private cleanup must be `clean` or `not-created` (otherwise `"private attachment cleanup failed"`), then clear tombstones, `/bin/rm -rf /workspace`, `/bin/mkdir -p /workspace`, `/bin/tar -xf /petrus-transfer/input.tar -C /workspace`, and set the current attachment. Control output above 64 KiB closes the VM (`"workspace transfer produced excessive output"`). A non-zero exit gives `"workspace transfer failed"`. |
| `export` | none | `{"ok":true}` | Runs guest `/bin/tar -cf /petrus-transfer/output.tar -C /workspace .`. The host then reads `output.tar`. |
| `execute` | `argv` (non-empty, strings, no NUL), `cwd` (`"/workspace"` or starting with `"/workspace/"`), `environment` (object; keys `^[A-Za-z_][A-Za-z0-9_]*$`; string values without NUL), `attachment_id`, `private_roots` ({NAME: {"file_id","name"}}, ≤16, exact key set), `timeout` (null or a finite number > 0, in seconds), `output_limit` (a safe integer, 0 ≤ n ≤ 4 MiB) | `{"ok":true,"returncode":int,"stdout":b64,"stderr":b64,"timed_out":bool,"output_truncated":bool}` | See 2.7. Errors: `invalid private roots`, `attachment unavailable` (private roots for a non-current attachment), `private reference unavailable`, or an SDK error message. |
| `private_probe` | none | `{"ok":true}` | Allowed once, before any attachment. Tries `/usr/bin/python3`, then `/bin/python3`, running the embedded helper `probe`, which must print `PRIVATE_PROBE_OK`. Failure gives `"private helper probe unavailable"` or `"private helper probe failed"`. |
| `private_import` | `attachment_id`, `file_id` (`^[0-9a-f]{1,128}$`), `name` (`^[A-Za-z0-9][A-Za-z0-9._-]*$`, ≤64), `content` (**canonical** padded standard base64: regex `^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==\|[A-Za-z0-9+/]{3}=)?$`, length ≤ 1 400 000, re-encoding must round-trip) | `{"ok":true}` | Rejected when there are 16 or more files, the file_id is a duplicate, the content exceeds 1 MiB, or the total would exceed 4 MiB. Any failure marks `privateUncertain`. |
| `private_export` | `attachment_id`, `file_id`, `name` | `{"ok":true,"content":b64}` | |
| `private_delete` | `attachment_id`, `file_id`, `name` | `{"ok":true,"disposition":"clean"\|"unverified","removed":0\|1}`, or `{"ok":true,"disposition":"not-created","removed":0}` for a tombstoned file_id and name | A non-clean result sets `privateUncertain`. |
| `private_cleanup` | `attachment_id` | `{"ok":true,"disposition":…,"removed":n}` | |

Every `private_*` action other than the probe requires that the helper was probed and that
`attachment_id` is the current attachment. Otherwise it fails with `"private operation unavailable"`,
which the catch block masks as `"private operation failed"`. Once `privateUncertain` is set,
everything except cleanup fails. **Any thrown error inside `privateAction` is replied as the
generic `"private operation failed"`.** A name mismatch on export therefore surfaces as
`"private operation failed"`, while the same mismatch inside `execute` surfaces as
`"private reference unavailable"`. The tests match both strings.

**2.7 Execute semantics in the sidecar** (`sidecar:488-546`).

- The guest command is `vm.exec(["/bin/sh","-c",'exec "$@"',"petrus-command",...argv], {cwd, env, stdout:"pipe", stderr:"pipe", windowBytes: max(65536, min(8 MiB, output_limit+65536))})`.
  - `env` is exactly `request.environment`, plus `NAME=/tmp/.petrus-private/<file_id>` per private root. No host env is passed.
- `proc.output()` is an async iterator of `{stream, data}` chunks. A **single shared byte budget**
  applies in arrival order across both streams: a chunk that exceeds the remaining budget is cut,
  then `overflow=true` and `close()` is called.
- The timeout timer sets `timedOut` and calls `close()`. **A timeout or overflow closes the whole VM and lease**.
  A later `lookup` reports `UNCERTAIN` (`test_gondolin_timeout_destroys_lease`).
- If `proc.result` rejects after an owned cancellation, the reply is `ok:true` with `returncode:-15`.
  The sidecar never reports `superseded`.

Host-side handling (`gondolin.py:612-687`):

1. Private roots on a lease without the capability raise `ValueError("lease does not grant private-file transfer")`.
2. `_current` checks the registry, full lease equality (including READY state and capabilities), and the handshake.
3. Run the pre-launch currency check. On staleness, `cancel`, which sends `close`, and return superseded.
4. `cwd = _checked_guest_cwd(Path("/workspace"), command.cwd)`, giving an absolute string.
5. Each private ref must belong to this attachment.
6. Poll recv with a 50 ms timeout. On each tick, call `is_current()`:
   - `False`: send `close` and return `CommandResult(-15, b"", b"", False, True, False)`.
   - an exception: send `close` and re-raise.
7. Decode the response with non-validating `b64decode`. Replace each `/tmp/.petrus-private/<file_id>` with `[private-root]`.
8. If stdout+stderr exceed `output_limit`, raise `RuntimeError("Gondolin sidecar violated the command output bound")`.
9. Return `CommandResult(returncode, stdout, stderr, timed_out, superseded=False, output_truncated)`.

**2.8 Attach and export on the host** (`:484-504, 689-704`).

**Attach:**

1. Empty the transfer dir: `rmtree` dirs, `unlink` everything else.
2. Normalize the archive: extract it to a temp dir, then run `workspace_archive` on that dir.
3. Write `<transfer>/input.tar` (`write_bytes`, then chmod `0600`).
4. Request `{"action":"attach","attachment_id":uuid4}` with a 60 s timeout.
5. Always unlink `input.tar` afterwards.
6. Return `ExecutionAttachment(id, lease, input_digest, Path("/workspace"))`.

**Export:**

1. Unlink any stale `output.tar` and request `export` (60 s).
2. The output must be a regular non-symlink file of at most 512 MiB, otherwise `RuntimeError("Gondolin returned an invalid workspace archive")`.
3. Read it, unlink it, and normalize. The guest's GNU or busybox tar names (`./`, `./file`, GNU long names) must therefore parse correctly in Haskell.

**2.9 The embedded guest Python helper** (`sidecar:75-297`, the `PY` string). It runs in the guest as
`python3 -c PY <action> ...`, with a 1 MiB + 1 stdout window and a stderr cap of 64 KiB (exceeding it closes the VM).

| Action | Interface | Output |
| --- | --- | --- |
| `probe` | — | `PRIVATE_PROBE_OK` |
| `import <item> <name>` | content on stdin | — |
| `export <item> <name>` | — | raw bytes on stdout |
| `delete <item> <name>` | — | `clean` or `unverified` |
| `cleanup-all` | JSON `[[id,name],…]` on stdin | `{"disposition":…,"removed":n}`, compact |

Its custody root is `/tmp/.petrus-private/<file_id>/<name>`. Directories are mode `0700` and owned by the euid.
Leaves are regular files with mode `0600`, owned by the euid, and `nlink` 1. All access is openat-style with
`O_NOFOLLOW`. The probe verifies that `O_EXCL` works, that a symlink is refused on export, and that cleanup
reports `unverified` for a symlink without touching the victim file. The Haskell side never touches this
helper directly. It is listed here only because its strings surface in replies.

#### 3. Concurrency & durability semantics

- **Cross-process lock** (`_locked`, `:174-197`). Taken by `create` and `destroy` only:
  1. `mkdir(dir, 0700, exist_ok)`, then `os.open(dir/lock, O_CREAT|O_RDWR, 0600)`.
  2. **`fcntl.flock(fd, LOCK_EX)`**, which blocks.
  3. Revalidate that `fstat(fd).(st_dev,st_ino) == stat(dir/lock).(st_dev,st_ino)`. On a mismatch or `FileNotFoundError`, close and retry.
     This handles a destroyer having `rmtree`d the directory while a waiter held the old inode (`test_lock_revalidates_after_destroy_unlinks_a_waiters_inode`).
  4. Release by closing the fd.

  **Interop hazard:** Haskell must use real `flock(2)`. GHC's `hLock`
  (`GHC.IO.Handle.Lock`) prefers Linux OFD `fcntl` locks, which do **not** exclude `flock`
  locks held by a Python process. Use a direct FFI `flock` (`foreign import ccall interruptible "flock"`)
  on the fd so that you can also `fstat` it. The `filelock` package hides the fd.

  `lookup`, `attach`, `execute`, `export`, `cancel`, and the private operations take no host lock.
  The sidecar's single-flight `active` flag serializes them.
- **Single flight in the sidecar.** While one `attach`, `export`, `execute`, or `private_*` runs, every other non-control request gets
  `"command already active"`. `handshake`, `status`, and `close` always pass (`test_sidecar_enforces_single_flight_commands`).
- **Creation is a custody transition** (`:334-470`). The steps run in a fixed order under the lock:

  1. Check the operation id, then the capabilities, then require an image (`"Gondolin requires an image"`).
  2. If a registry exists:
     - A different fingerprint gives the "collides" `ValueError`.
     - A failed handshake gives `RuntimeError("registered Gondolin lease is uncertain; destroy it before retrying")`.
     - A required capability missing from the lease gives `"registered Gondolin lease lacks required capabilities; destroy it before retrying"`.
     - Otherwise return the lease.
  3. If `workspace/` exists without a registry, raise `"unregistered Gondolin workspace has uncertain custody"` before creating any runtime directory.
  4. Create `mkdir workspace 0700` and the runtime directory, generate the token and lease id, and spawn the sidecar.
     If the spawn fails, remove the runtime dir, the workspace, the lock file, and the directory, then re-raise.
     For example, a missing node binary raises `FileNotFoundError`.
  5. Write the registry for the first time. If the write fails, terminate the sidecar with up to 1 s waits and group cleanup,
     then remove everything and re-raise. If processes remain, raise `"…process cleanup is uncertain"`.
  6. `_await_start` polls the handshake every 30 ms until `startup_timeout`, which defaults to 120 s.
     - `OSError`, `TimeoutError`, and `ConnectionError` mean "not ready yet".
     - If the process exits, raise "failed to start".
     - On timeout, raise `"Gondolin sidecar readiness timed out"`.
     - On any failure, run `_cleanup_group` and remove everything. If group members remain, raise `"…cleanup is uncertain; registry retained"`.
  7. Compute `group_identities` and rewrite the registry.
  8. Private only: send `private_probe` (60 s), extend `group_identities`, set `private_file_transfer=true`, and rewrite the registry.
  9. If step 7 or 8 fails, `_rollback_locked` (`:272-296`) runs:
     1. Send `close`, waiting up to 5 s at 30 ms intervals for the group to disappear.
        The wait also runs `waitpid(pid, WNOHANG)` to reap the zombie child.
     2. `_cleanup_group`.
     3. `_remove_runtime`.
     4. `rmtree(dir)`.

     The resulting errors are:

     | Failure | Rollback | Error |
     | --- | --- | --- |
     | identity registration (step 7) | verified | `"Gondolin process identity registration failed"` |
     | identity registration (step 7) | unverified | `"…rollback is unverified and registry custody is retained"` |
     | private probe (step 8) | verified | `"Gondolin private-file security probe failed"` |
     | private probe (step 8) | unverified | `"…rollback is unverified…"` |

  10. Return the lease.
- **Destroy** (`:712-768`, under the lock):
  1. A missing registry: unlink the lock, rmdir, and return `NOT_CREATED` with "no registered Gondolin territory".
  2. A `lease_id` mismatch returns `UNVERIFIED`.
  3. Send `close`, ignoring errors, then wait up to 5 s for the group, reaping as above.
  4. `_cleanup_group`. If members remain, return `UNVERIFIED` "registry retained".
  5. `_remove_runtime`, then `rmtree(dir)`, then `CLEAN`.

  Any of `KeyError`, `OSError`, `RuntimeError`, `TypeError`, `ValueError`, or `SubprocessError` yields `UNVERIFIED`.
  After a TTL expiry, a hard `SIGKILL` of the sidecar, or a timeout, destroy is still `CLEAN`.
  `ps` no longer lists the reaped or orphaned group, and the runtime directory is removed.
- **`_cleanup_group`** (`:770-802`). This is an identity-checked process-group kill:
  1. If no member exists, return.
  2. Each member must satisfy at least one of the following, otherwise raise `RuntimeError("Gondolin process group identity is uncertain; registry retained")` **without signalling**:
     - **(a)** the leader is alive with `marker == start_identity.marker`.
     - **(b)** the member's current marker equals `group_identities[str(pid)]`.
     - **(c)** the member's command line contains the runtime path.
  3. `killpg(pgid, SIGTERM)`, polling every 20 ms for 0.5 s. If members remain, `killpg(SIGKILL)` and poll for 0.2 s.
     A `ProcessLookupError` returns.

  Five unit tests monkeypatch `_group_members`, `_identity`, and `os.killpg`. Make these three injectable in Haskell.
- **Lookup and reconcile** (`:323-332, 804-810`). With no registry, `lookup` returns `None`. When the handshake fails with `OSError`, `TimeoutError`, or `RuntimeError`, it returns `UNCERTAIN`. Otherwise it returns `READY`.
  Reconcile never returns `TERMINAL`:

  | Situation | Classification | Detail |
  | --- | --- | --- |
  | no registry | `RETRYABLE` | "no Gondolin lease" |
  | lookup gave `UNCERTAIN` | `UNCERTAIN` | "registered sidecar is unreachable" |
  | lookup gave `READY` | `UNCERTAIN` | "VM readiness does not prove operation outcome" |
- **Cancel** (`:706-710`). This sends `close` if the registry `lease_id` matches. It takes no lock, and errors propagate.
  Cancellation, supersession, timeout, overflow, and TTL all make the territory unusable.
  That is what `territory-cancellation` means: Gondolin does not have `command-cancellation`.
- **Private-file results.** `delete` and `cleanup` map any transport, `RuntimeError`, or `ValueError` failure to
  `UNVERIFIED` "private cleanup unavailable", as does a malformed reply (`:521-542`).
  `export` uses strict base64 (`validate=True`) and enforces the 1 MB bound.
- **Zombie reaping.** The Python creator is the sidecar's parent. Haskell must likewise reap it
  with `getProcessStatus False False pid`, catching `ECHILD`, so that `ps` stops listing a zombie.
  It must not use `withProcess*` helpers that kill the child on scope exit.

#### 4. External dependencies → Haskell

**Keep `gondolin_sidecar.mjs` verbatim.** Ship it with cabal `data-files`, or embed it with
`file-embed` and write it once to the state root. Mode `0600` is enough, because node reads it as a script.

- **Runtimes:** Node ≥ 23.6 and the `@earendil-works/gondolin@0.12.0` SDK, which drives QEMU.
  There is no Haskell substitute, and none should be attempted.
- **Haskell libraries:**

  | Need | Library |
  | --- | --- |
  | Spawning | `typed-process` (`setNewSession True`, `setStdin nullStream`, stderr to a file handle, env from the allowlist), or `process` with `new_session=True` |
  | Signals and process identity | `unix` (`signalProcessGroup`, `getProcessStatus`, `getRealUserID`, `setFileMode`, `getSymbolicLinkStatus`) |
  | Unix-domain socket client | `network` (`Network.Socket` with `AF_UNIX`, `SockAddrUnix`) |
  | Locking | `flock` via FFI |
  | Hashing | `crypton` (SHA-256) |
  | Random tokens | `crypton` `getRandomBytes` for `token_urlsafe` |
  | Base64 | `base64-bytestring`: strict decode for exports, lenient for execute output, base64url unpadded for the token |
  | UUIDs | `uuid` (v4) |
  | Temp directories | `temporary` (`createTempDirectory "/tmp" "petrus-g-"`), followed by an explicit chmod `0700` |
  | JSON | `petrus-json` for the registry, `aeson` acceptable for parsing replies |
  | Process inspection | `ps` invoked through `typed-process` |

- **`/proc` parsing:** use plain `ByteString` reads.

#### 5. Upstream tests

`tests/petrus/motus/test_gondolin_environment.py` has **32** functions, one of them parametrized
`("GONDOLIN_IMAGE_STORE","XDG_CACHE_HOME")`, which gives 33 items.

Fixtures: `fake_sdk` writes a fake `@earendil-works/gondolin` ESM module with `PETRUS_FAKE=true` and `VERSION="0.12.0"`.

- Its `VM.exec` maps `/workspace`, `/tmp/.petrus-private`, and `/petrus-transfer` to host directories, then spawns host processes (detached).
- So hermetic runs need `node` (v22 works with the fake, since the Node ≥ 23.6 gate is skipped), `ps`, host `tar` (`/bin/tar` or `/usr/bin/tar`),
  and **`/usr/bin/python3` or `/bin/python3`** for the private helper. See `docs/process/development-guide.md:40-44`.

**Port this fixture verbatim into the Haskell test suite.** It is test-side JS and tests the sidecar exactly as upstream does.

Coverage groups:

- `node --check` on the sidecar.
- full lifecycle:
  - an auth failure on a wrong token.
  - recreated-adapter lookup equality and the fingerprint collision.
  - VFS round trip and the `0755` mode.
  - `GITHUB_TOKEN` not leaking.
  - registry and socket modes `0600`, and socket path < 100 bytes.
  - destroy leaves the root empty.
- custom image store resolution, and sanitized missing-image errors.
- private-file route:
  - forged-name errors, persisted grant, and no canary in the registry, stderr, workspace, or repr.
  - a non-private lease cannot gain the private grant later.
  - probe failure rolls back with no residue.
  - a guest symlink swap is unverified, and the next attach fails.
  - cleanup is unverified while active.
  - sidecar death leads to unverified cleanup and then a verified destroy.
- timeout or overflow makes the lease `UNCERTAIN`; destroy is `CLEAN` and then `NOT_CREATED`.
- the lexical guest cwd.
- concurrency and custody:
  - concurrent provision makes one sidecar.
  - spawn failure, registry write failure, and an unregistered orphan workspace each fail closed.
  - the lock revalidation race.
- process-identity unit tests, five of them monkeypatched.
- single flight; currency-check failure closes; supersession closes.
- TTL expiry; private-probe startup grace; hard death followed by a verified cleanup.
- `test_real_gondolin_lifecycle_is_explicitly_opt_in`: `@pytest.mark.real_gondolin_acceptance`.
  It also needs `PETRUS_REAL_GONDOLIN_SDK_MODULE`, `PETRUS_REAL_GONDOLIN_IMAGE`, and a real QEMU-capable host.

`tests/petrus/agenticus/runtime/test_codex.py:1378-1628` also drives `GondolinEnvironment` through the fake SDK. That belongs to section 12.

#### 6. Performance

The hot paths are a fresh UDS connection per request (JSON plus base64), and archive normalization on attach and export.
Startup is dominated by node, the SDK import, and VM boot.

Benchmark proposal, using the fake SDK for hermetic equivalence:

- **(a)** 1 000 `lookup` handshakes. Measure the client-side latency distribution.
- **(b)** 200 `execute(("/bin/true",))` round trips.
- **(c)** attach and export of a 50 MiB workspace.

Run the Python and Haskell providers against the *same* sidecar, so only the client differs.
Expect gains only in (c), from the archive codec, and in (a) and (b), from client overhead.
The Python `execute` poll tick (50 ms) adds no latency to completion, because recv returns as soon as data arrives.

#### 7. Better-the-Haskell-way suggestions

- `data Registry = Registry {..}`, encoded with `petrus-json`. Make `group_identities :: Maybe (Map Text Text)`
  and `privateFileTransfer :: Bool`, with a missing key meaning `False`, and emit the key only when true.
- Make the custody transition a typed state machine:
  `Locked -> WorkspaceMade -> Spawned -> Registered -> Ready -> (Private)`, so that each stage has exactly
  one rollback action. Use `bracketOnError` per stage instead of the nested `try` blocks.
- Put the process-inspection seam in a record: `ProcessInspector { groupMembers :: Pid -> IO [Member], identity :: Pid -> IO Identity, killGroup :: Pid -> Signal -> IO () }`.
  This ports the five monkeypatch tests directly.
- Model the sidecar requests as an ADT, `data SidecarRequest = Handshake | Status | Close | Attach AttachmentId | ...`,
  with one encoder, and the replies as per-action decoders. Keep error strings as `Text`,
  because the tests and the Python side match on them.
- Run the execute currency poll as a `race` between socket recv and a 50 ms ticker or an STM currency variable.
- Quirks to preserve for interop:
  - TTL is absolute, not idle.
  - Timeout and supersession close the VM.
  - `[private-root]` is lowercase.
  - `-15` is reported for owned cancellation.
  - `superseded` is always false from the sidecar.
  - The registry has no trailing newline.
  - `str(lease_ttl)` argv formatting.
  - The runtime directory must be literally under `/tmp`.
  - `cancel` propagates connection errors.
  - The Gondolin operation-id grammar differs from the other providers.

#### 8. Packaging

Use `Petrus.Motus.Execution.Gondolin` in the execution package, with `data-files: gondolin_sidecar.mjs`, copied
verbatim from the pin and checked by a test that its hash matches upstream. It depends on the
contract, the archive codec, and `petrus-json`. It needs nothing from the kernel. It can be built in parallel with
everything else. Its consumer is agenticus (Codex/Pi Gondolin profiles).

### Private execution evidence: ArtifactStore and Timeline (`_execution/artifacts.py:19-98`, `_execution/timeline.py`)

#### 1. Responsibility & public API

Both are **private** and have **no runtime consumers** in `src/`. Only the tests use them, and
`petrus.motus._execution.timeline` must *not* be imported by `petrus.motus.execution`.
They are host-custodied execution evidence.

- `ProducerCorrelation(operation_id, provider, lease_id)` and
  `ArtifactRef(digest, size, media_type, retention_class, producer)`.
- `ArtifactStore(root)`:
  - `put(data, *, media_type, retention_class, producer) -> ArtifactRef`.
  - `read(ref) -> bytes`, which verifies size and SHA-256 and otherwise raises `ValueError("artifact integrity check failed")`.
  - `delete(ref)`.
  - `prune(retain, *, protected=frozenset()) -> tuple[digest,...]`.
- `TimelineEvent(event_id, event_kind, schema_version, producer, producer_sequence, observed_at, phase, outcome, correlation, causal_refs, metadata, retention_policy)`.
- `Timeline(path, *, retain=None)`. `observe(event_kind, *, producer, phase, outcome, correlation, causal_refs=(), metadata=None, retention_policy="operational") -> TimelineEvent` mints the event id and sequence.
  `append(event)` requires `producer_sequence == last+1`. `delete()`.
- `TelemetryTimelineHandler(timeline, *, producer="petrus.telemetry")`: a `logging.Handler` at INFO level.

#### 2. Wire formats

**ArtifactStore layout:**

- Data goes to `<root>/<digest[:2]>/<digest>.data`, where the digest is SHA-256 lowercase hex.
- Sidecar metadata goes to `<digest>.json`, encoded as `json.dumps(asdict(ref), sort_keys=True)` with default separators and no newline. For example:
  `{"digest": "…", "media_type": "text/plain", "producer": {"lease_id": "…", "operation_id": "…", "provider": "…"}, "retention_class": "…", "size": 15}`.
- Both are written atomically: `mkstemp` in the same dir (`0600`), write, flush, `fsync`, then `os.replace`. There is no directory fsync.
- `put` validates that the content is `bytes` and that the media type and retention class are non-empty.

**Timeline JSONL** (`timeline.py:167-205`):

- One record per line: `json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n"`, with `ensure_ascii=True`.
- Keys in order: `causal_refs` (array), `correlation`, `event_id` (uuid4 str), `event_kind`, `metadata`,
  `observed_at` (`datetime.isoformat()` of an aware UTC time), `outcome`, `phase`, `producer`, `producer_sequence`,
  `retention_policy`, `schema_version` (=1).
- `observed_at` looks like `2026-10-10T12:00:00.123456+00:00`. The **fraction is omitted when the microseconds are 0**.
- The file is opened with `O_APPEND|O_CREAT|O_WRONLY` and mode `0600`. There is one `os.write` and one `fsync` per event, and the file is closed each time.
- An event is rejected (`ValueError("Timeline event has an invalid envelope")`) unless `schema_version == 1`,
  the five string fields are non-empty, and `observed_at` is aware.
- **Redaction** is applied to `correlation` and `metadata` only (`:18-24, 73-82`):
  - A key matching `(?i)(?:secret|token|password|credential|authorization|auth.?headers?|cookie|private.?key|process.?env|reasoning)`
    (search, not full match) has its whole value replaced by `"[REDACTED]"`.
  - Recursion goes into mappings (keys stringified) and non-string sequences (which become lists).
  - In strings, `(?i)(?:bearer\s+)[A-Za-z0-9._~+/=-]+|(?:github_pat_|gh[opsu]_|sk-(?:or-)?)[A-Za-z0-9_-]{8,}` is replaced by `[REDACTED]`.
- **Retention:**
  - `slack = 0 if retain < 100 else max(100, retain // 10)`.
  - When `line_count > retain + slack`, the provider keeps the last `retain` lines and rewrites them atomically (`mkstemp`, `fsync`, `replace`, chmod `0600`).
- **Restart:** the constructor chmods `0600`, counts lines, and rebuilds `producer → max(producer_sequence)` from the *retained* lines only.
  This is a quirk: a producer whose lines were all pruned restarts at 1.
- **Telemetry mirroring** (`:211-245`):
  1. Parse `record.getMessage()` as JSON. It must be an object with a string `event`.
  2. Pop `event` and `ts`.
  3. `correlation` takes `str(v)` for keys in the 26-name `_CORRELATION_FIELDS` set (`:25-54`), skipping `None` and empty values.
     Python `str()` gives `True` and `2`.
  4. `metadata` holds every other key.
  5. `outcome = str(outcome ?? status ?? "observed")`.
  6. The phase comes from the suffix map (`_started` to start, `_finished` to finish, `_accepted` to accept, `_claimed` to claim, `_heartbeat` to heartbeat,
     `_completed` to complete, `_failed` to fail, `_destroyed` to destroy, anything else to observe).
  7. `retention_policy="bounded-operational"`.
  8. All exceptions are swallowed.

#### 3. Concurrency & durability

- **Timeline:** a `threading.Lock` per instance covers sequence minting and the append. There is no cross-process lock:
  two processes appending to the same file can mint duplicate sequences.
- **Durability:** every line is fsynced. An ArtifactStore blob is durable after `replace`, though the directory entry is not fsynced.
- **`prune`:**
  - It sorts `*/*.data` by `(st_mtime_ns, name)` and removes the oldest `len - retain`, skipping protected digests.
  - Protected entries do not consume the removal budget, so the protected file is kept and the next-oldest file is removed in its place.

#### 4. External dependencies → Haskell

The Python side uses only the stdlib. In Haskell:

| Need | Library |
| --- | --- |
| JSON encoding | `petrus-json`. Byte-identical encoding is needed if files are shared. |
| SHA-256 | `crypton` |
| Regexes | `regex-tdfa`, or hand-written matchers. The patterns are simple, but note the `(?i)` flag and the search semantics. |
| Atomic temp files | `unix` and `temporary` |
| Timestamps | `time`. Format `observed_at` by hand to match `isoformat`. |
| UUIDs | `uuid` |
| Logging bridge | A `co-log` or `katip` sink, or a plain callback. Define the bridge against the `petrus-telemetry` JSON log line (section 10). |

#### 5. Upstream tests

These are in `test_private_execution_substrate.py`. Seven are hermetic:

- `test_artifacts_are_host_custodied_integrity_checked_and_provider_neutral` (tamper detection)
- `test_artifact_retention_prunes_oldest_without_removing_current_authority`
- `test_timeline_redacts_recursively_correlates_and_has_no_authority`
- `test_timeline_mints_sequences_across_restart_and_retention_is_sink_policy` (retain=2 across two instances)
- `test_telemetry_handler_builds_one_redacted_correlated_noncanonical_stream`
- `test_telemetry_handler_failure_is_non_blocking`
- `test_cross_provider_workspace_handoff_has_no_shared_path`, which needs Docker and stores the Local export as `application/x-tar`, then attaches it in Docker.

#### 6. Performance

The bottleneck is fsync per line and per blob. Benchmark 10 000 `observe` calls and 1 000 × 1 MiB `put` calls on the same filesystem.
Compare throughput, and also run with fsync stubbed out (in both implementations) to isolate the encoding cost.

#### 7. Better-the-Haskell-way suggestions

- Make the timeline a write-only handle (`newtype TimelineSink`) with no read API, matching "runtime code has no read operation".
- Use `MVar`-guarded sequence minting.
- Make redaction a pure function over `petrus-json`'s value type.
- Low priority: nothing in the runtime depends on these, so port them after the providers, mainly for parity of the six hermetic tests.

#### 8. Packaging

Use `Petrus.Motus.Execution.Internal.{Artifacts,Timeline}`, unexported, or in an `internal` sublibrary.
They depend only on `petrus-json`. The telemetry bridge should eventually depend on the telemetry package.
They are fully parallelizable.

## 10. DSL, telemetry, deterministic simulation testing, and project checks

### Net authoring DSL (`impetus/dsl.py`)

Source: `src/petrus/impetus/dsl.py` (881 lines). Tests: `tests/petrus/impetus/dsl/test_petrinet_dsl.py` (42 test functions).
The Python decorator/operator surface cannot be ported byte for byte. What has to match is the canonical
`Net` it produces, along with the handler and guard implementation maps keyed by `NetUri`. The DSL has no wire
format: it is a front end that lowers through the kernel's `Net` constructor, and that constructor remains the
semantic validation boundary (`test_canonical_net_remains_the_semantic_validation_boundary`).

#### 1. Responsibility & public API

`__all__` (`dsl.py:864-881`): `ArcSpec, BuiltNet, ConnectionSpec, GuardSpec, HandlerSpec, NetBuilder, NetSpec,
NodeSpec, PlaceSpec, ScopeSpec, TransitionSpec, arc, direct, petri_guard, petri_handler, typed_guard`.

| Python | Lines | Behavior |
| --- | --- | --- |
| `NetSpec(name: str \| None = None, *, completion: CompletionDeclaration \| None = None)` | 353-707 | Mutable authored definition. An empty name raises `ValueError("... non-empty string or None")`. Properties: `.p` and `.t` return node proxies, `.s` returns the root `ScopeSpec`, `.connections` returns a tuple of `ConnectionSpec`. `copy()` (389) returns a flattened independent spec; `build()` (393) returns `NetBuilder(self).build()`. |
| `net.p.<name>` / `net.t.<name>` (`_NodeProxy.__getattr__`, 305-314) | | Returns a stable handle (`setdefault`) and, on first touch, registers the node in insertion order through `_node` (543-557). A bare reference creates the node, and so does a reference that only appears inside `>>`. Names that start with `_` raise `AttributeError`. |
| `net.s.<seg>` / `net.s[seg]` (`ScopeSpec`, 317-350) | | Builds a path prefix. `s[seg]` requires a `str` (`TypeError`) holding exactly one non-empty segment with no `.` (`ValueError "one non-empty path segment"`). It is how reserved names `p`, `t`, `s`, `stamp` are authored. `scope.stamp(source: NetSpec) -> ScopeSpec` (348). |
| `abs(node) -> NetPath` (`NodeSpec.__abs__`, 199) | | The node's absolute path. Node handles deliberately have no `.path` attribute. |
| `place(node, *, color=None)` / `PlaceSpec.__call__(color)` (397-410, 217) | | Normalizes the color: a `str`, or a Python `type` reduced to its `__name__`, or `None`; anything else raises `TypeError "nominal string, Python type, or None"`. Configuring the same value again is a no-op. A different value raises `ValueError "already configured with color 'X'"` and leaves the spec unchanged. Under a stamp it records a destination override. |
| `PlaceSpec.override(*, color)` (220, 412-422) | | Requires an explicit or inherited base (`ValueError "no explicit or inherited configuration to override"`). `None` clears the color. |
| `PlaceSpec.color` (223) | | The configured color, or `None`. |
| `transition(node, *, handler=None, guards=(), timers=())` / `TransitionSpec.__call__` (424-447, 233) | | Configuring an identical value is idempotent. A different value raises `ValueError "...use transition.override(...) to change it"`. |
| `TransitionSpec.override(*, handler=_UNSET, guards=_UNSET, timers=_UNSET)` (242-249, 449-477) | | Needs a base (`ValueError`) and at least one field (`TypeError "requires at least one of handler, guards, or timers"`). Omitted fields are kept. `None` / `()` clear. Validation completes before any mutation, so a failed call changes nothing. |
| `arc(*, weight=1, color=None, filter=None)`, `arc.read(...)`, `arc.inhibit(...)` (`_ArcFactory`, 158-189) | | Produce `ArcSpec(mode, weight, color, filter)` (141-155). The mode is never passed as a parameter (`arc(ArcMode.READ)` raises `TypeError`). |
| `>>` operators | 150-155, 202-210, 294-302 | `node >> node` adds a default consume arc (weight 1) and returns the right operand, so `a >> t >> b` chains. `node >> ArcSpec` and `tuple >> ArcSpec` produce a `_PendingConnection`, and `pending >> targets` connects then returns `targets`. `tuple >> node` uses `NodeSpec.__rrshift__`. Tuples expand as the cartesian product, source-major (`for s in sources for t in targets`, 588). Mixing specs raises `ValueError "different net specifications"` before anything is mutated. `>` is not supported (`TypeError`). |
| `petri_handler(fn)` / `petri_guard(fn)` (97-101, 134-138) | | Explicit Petri-aware callables (`Handler(binding, outputs)`, `Guard(binding)`), stored as given. |
| `@direct` / `direct(fn, *, converter=DataclassPayloadConverter())` (104-116) | | Typed pure transform. Lowered through `derive_typed_transform` (`impetus/binding/__init__.py:316-343`). |
| `@typed_guard` / `typed_guard(fn, *, converter=...)` (119-131) | | Typed predicate. Lowered through `derive_typed_guard` (`binding/__init__.py:346-362`). The callable must return exactly `bool`; otherwise the call raises `ValueError "must return bool, got str"`. |
| Bare callable as guard (`_normalize_guards`, 844-861) | | Implicitly a `typed_guard` with converter `None`, which lowering replaces with `DataclassPayloadConverter()`. A bare callable as **handler** is refused (`TypeError "handler callables require direct(...) or the advanced petri_handler(...)"`, 576-581). A NodeSpec used as handler or guard is a `TypeError`. A `list` or generator of guards is refused (`TypeError "guards must ..."`): only a tuple is accepted. |
| `NetBuilder(root).build() -> BuiltNet` (710-803) | | `BuiltNet(net: Net, handlers: Mapping[NetUri, Handler \| ActivityHandler], guards: Mapping[NetUri, Guard])` (281-291). Both maps are `MappingProxyType`, so they are immutable. |

**Composition semantics** (`NetBuilder._compose`, 728-756):

- An authored **event log** `_events` records first-touched nodes, connections, and stamps in order.
- Building replays the events depth-first into a fresh `effective` NetSpec. Paths of stamped children are
  rebased under their destination prefix.
- Destination overrides of places and transitions are applied after the events.
- A spec that appears on its own stack raises
  `ValueError "net specification stamp cycle: first at <root> -> second at second -> first at second.first"`.
- A stamped child that declares `completion` raises `ValueError "stamped net specification child at worker
  cannot declare root completion"`.
- Connections whose endpoints do not exist in the source raise `"net specification root at <root> connection
  references missing place worker.missing"` (786-803).

Stamping (`_stamp`, 592-634):

- Stamping at the root is refused: `"cannot stamp child at <root>: reusable definitions require a non-root scope"`.
- Stamping inside another stamp's territory is refused: `"cannot stamp <anonymous> at worker.nested: scope belongs
  to child stamped at worker"`.
- Stamping over direct content is refused, and the refusal mutates nothing: `"... destination already owns place
  worker.local"`.
- Restamping the same path replaces the source and clears every destination override under that path.
- Nodes addressed through a stamped scope do not register in the parent. Their configuration becomes an
  override, and a missing node raises `"stamp of child at worker has no transition missing requested as
  worker.missing"`.
- Stamps stay **live**: mutating the child after stamping shows up in later builds. `build()` takes immutable
  snapshots. `copy()` severs the link.

**Lowering to the canonical net** (`_canonical_net`, 479-502):

- `Place(path, color_name)` for each place, in first-touch order.
- `Transition(path, handler, guards, timers)` for each transition, in first-touch order. A `HandlerSpec` or
  `GuardSpec` is replaced by `AnonymousDeclaration(display_name=fn.__name__)` (91-94). The display name is
  `compare=False` and non-semantic, and the net-definition v3 projection drops it
  (`net_definition.py:339-346` emits `{"kind":"anonymous","uri":...}`).
- `Arc(source, target, mode, weight, color_name, filter)` for each connection, in connection order.
- `Net(places, transitions, arcs, completion=..., name=...)`.

Implementation maps:

- Handlers are keyed by `net.handler_uri(path)`.
- Guards are keyed by `net.guard_uris(path)[i]`, aligned with the authored position. Positional anonymous guards
  get URIs like `transition:/review#guard:$1`; named guards keep their name, e.g. `transition:/review#guard:named`
  (test at 447-475).
- Only `HandlerSpec` and `GuardSpec` entries get implementations. Symbols and `Cel` are resolved elsewhere.
- Reusing one spec on two transitions produces two declarations.

**Kernel APIs it depends on:**

- `petrus.impetus.petrinet.schema`: `AnonymousDeclaration, Arc, ArcMode, Cel, Color, CompletionDeclaration, Delay,
  FilterDeclaration, Net, NetPath (SEP, slicing, len), NetUri, Place, Transition, Until`, and `Net.handler_uri`,
  `Net.guard_uris`, `Net.inputs`, `Net.outputs`, `Net.is_source`.
- `petrus.impetus.petrinet.enabledness.Guard`.
- `petrus.impetus.binding`: `Handler, ActivityHandler, derive_typed_transform, derive_typed_guard`.
  - Typed matching is by **color**, not by parameter name: each parameter's dataclass `__name__` must match
    exactly one non-inhibitor, weight-1, colored input arc (`binding/__init__.py:250-295`).
  - Outputs must all carry the return type's color with weight 1.
- `petrus.motus.activity`: `PayloadConverter`, `DataclassPayloadConverter` (`motus/activity/__init__.py:63-120`).

Downstream users: `simulation.py:8`, `simulation_http.py:14` (`BuiltNet`), and
`agenticus/program/agent_net.py:18` (`NetSpec, arc, petri_guard, petri_handler`).

#### 2. Wire formats, durable schemas, protocols

The DSL has none of its own. Its observable output is the `Net`. The cross-implementation equivalence check is the
canonical **Net-definition v3** projection: `project_net_definition(net)` then `serialize_net_definition(doc)`
(`net_definition.py:360`, `:260-270`, which is `json.dumps(value, ensure_ascii=False, allow_nan=False, indent=2) +
"\n"`). The spec is `spec/net-definition-v3.md` plus its fixtures. Ordering is semantic and must match exactly:

- places and transitions in first-touch order;
- arcs in connection order, with tuple fan-out source-major;
- the guard tuple in authored order.

#### 3. Concurrency & durability semantics

None. The Python spec is single-threaded mutable state. Build failures are atomic: every validation runs before any
mutation.

#### 4. External dependencies

None beyond the kernel. In Haskell, payload conversion for `direct` and `typed_guard` uses the same converter
abstraction as Activity (owned by the Binding/Activity port), and JSON fidelity comes from `petrus-json`.

#### 5. Upstream tests

`tests/petrus/impetus/dsl/test_petrinet_dsl.py`: 42 functions. Three of them are parametrized (4 + 2 + 2 cases), so
the suite runs 47 cases. Everything is pure, with no Docker, network, or markers. Recommended Haskell treatment:

| Group | Tests (lines) | Haskell treatment |
| --- | --- | --- |
| Handles, navigation, reserved segments, name rules | 57-113 | Port. The "stable identity" and `is` assertions become handle equality. The `s[...]` validation stays a runtime check. |
| `>>` semantics, ordering, multiplicity, arc factory | 115-164 | Port the ordering assertions on the built `Net`. `arc(ArcMode.READ)` raising `TypeError` and `>` raising are enforced by types. |
| Snapshot independence, immutable maps | 166-178 | Enforced by types (immutable values). |
| Cross-spec atomicity | 180-188 | Enforced by types if handles carry a spec brand (see 7). |
| Configure idempotence, conflicts, overrides, atomic override | 191-273 | Port. |
| Late configuration after topology | 276-310 | Port. Order of configuration versus topology must not matter. |
| Node-as-handler/guard, raw-callable refusals | 313-320, 485-490 | Enforced by types (`HandlerSpec` is a sum type). |
| Canonical net is the validation boundary | 322-327 | Port: build must surface the kernel `Net` error (`"connect a place and a transition"`). |
| Typed lowering (`direct`, callable guard, custom converter, exact bool) | 344-444 | Port with Haskell typed functions. The "exact bool" check becomes a type-level `Bool`, so mark it type-enforced. Keep the converter-call-order assertion: decode runs per selected input in parameter order. |
| Guard forms, absolute URIs (`$0..$3`) | 447-475 | Port. These are interop-relevant NetUri spellings. |
| Petri-aware identity, reuse, build-time association | 492-531 | Port. Function identity becomes "the map holds the supplied implementation". |
| Stamping (rebase, compose, liveness, restamp, refusal diagnostics, cycles, copy, completion) | 534-719 | Port all diagnostics and rebase/restamp semantics. "Live stamp" and `copy()` are mutable-aliasing semantics. In an immutable Haskell DSL they are vacuous; record them as N/A, enforced by immutability. |

**Golden equivalence suite** (recommended, beyond the upstream tests): a small pinned Python script
(`scripts/`, run against `upstream/petrus`) authors N representative nets with the Python DSL, including
everything the tests above author plus `agenticus/program/agent_net.py`. For each net it emits:

- `serialize_net_definition(project_net_definition(built.net))`;
- `sorted(map(str, built.handlers))`;
- `sorted(map(str, built.guards))`.

The Haskell DSL authors the same nets, and the outputs are compared byte for byte.

#### 6. Performance

Python cost is dominated by `_stamp_for` (636-640). It scans every stamp for every node touch or lookup, which is
O(#stamps) per touch and roughly O(nodes × stamps) per build. Proposed benchmark:

- Workloads: (a) a flat chain of N places and N transitions with N ∈ {1k, 10k}; (b) a 10-node child stamped at
  K ∈ {10, 100, 1000} scopes, nested to depth 3.
- Measure: `build()` wall time and allocations, plus the size of the projected definition bytes, which must be
  equal across implementations.
- Python: `pytest-benchmark`-style timeit around `NetSpec(...)` construction plus `.build()`. Haskell: `tasty-bench`
  on the equivalent authoring program, forcing the `Net` (NFData) and the projected bytes.

Haskell should win easily by keeping stamps in a `Map NetPath Stamp` (or a trie) and doing longest-prefix lookup.

#### 7. Better-the-Haskell-way suggestions

- **Authoring monad with a spec brand.**

  ```haskell
  netSpec :: Maybe Text -> Maybe CompletionDeclaration -> (forall s. Author s ()) -> NetSpec
  data P s; data T s
  p :: Text -> Author s (P s)
  t :: Text -> Author s (T s)
  scope :: Text -> Author s a -> Author s a
  ```

  - `p` and `t` register on first use, which matches Python's first-touch ordering.
  - `scope` replaces `net.s.x` and `net.s["x"]`; `Text` segments are validated as single non-empty segments.
  - The ST-style rank-2 `s` makes cross-spec connections unrepresentable.
- **Connections** as a pure `Chain s` value built with an infix operator, plus an inscription form:

  ```haskell
  connect_ (pending ~> process ~> receipt)
  connectVia (readArc { weight = 2, color = Just "Order", filter = Just "current" }) [pending] [process]
  ```

  The inscription is an `ArcSpec` record with `consume` / `readArc` / `inhibit` smart constructors.
  - Lists stand in for Python tuples and keep the source-major product.
  - Use `NonEmpty` so "non-empty tuple" (`_nodes`, 837-841) is a type fact.
- **Configuration**:

  ```haskell
  colored :: P s -> ColorSpec -> Author s ()
  configure :: T s -> TransitionConfig -> Author s ()
  overrideT :: T s -> TransitionOverride -> Author s ()
  ```

  - Python's `_UNSET` vs `None` distinction becomes `data Change a = Keep | Set a`, with `Set Nothing` meaning clear.
  - An override with every field `Keep` stays a runtime `Left`, or use a non-empty override type.
- **`HandlerSpec`** is a closed sum: `HSymbol Text | HDirect DirectFn | HPetri Handler`.
- **`GuardSpec`** is a closed sum: `GSymbol Text | GCel Cel | GTyped TypedGuard | GPetri Guard`.
- A bare callable is not a handler. This removes the runtime `TypeError` paths.
- **Typed functions**: derive the parameter colors from types with a class `HasColor a` (`colorName :: Text`,
  defaulting to `tyConName` via `Typeable`, overridable).
  - Use an n-ary function class (`TypedFn f`) to enumerate argument types in order. Python's
    `converter.decode(value, annotation)` call order is per parameter, in declaration order.
  - The display name must be supplied explicitly (`direct' "process" f`), because Haskell has no `__name__`. It is
    non-semantic.
- **Make immutability the default:**
  - `NetSpec` is a value, so `copy` is identity and builds are trivially independent snapshots.
  - Stamping embeds a `NetSpec` value. The "live stamp" behavior (`test_stamped_specification_remains_live...`) is
    the one semantic that does not translate. It is not observable through the produced `Net`, so the produced-Net
    contract is preserved.
- Quirks to keep, because they change the produced `Net`:
  - a bare reference creates a node (`root.s.worker.p.local` alone adds a place);
  - first-touch order, including touches that happen inside a `>>` expression;
  - a restamp clears destination overrides;
  - arcs to nodes inside a stamp are recorded in the parent's event log at the moment of connection;
  - color normalization of types takes the bare type name;
  - a bare callable guard defaults to typed flavor;
  - a guard tuple holding the same callable twice produces two anonymous declarations at distinct positions.

#### 8. Packaging

- Module `Petrus.Impetus.Dsl` in `petrus-impetus`.
- Depends on the petrinet schema (`Net`, `NetUri`, `NetPath`), Binding's typed derivation, and the Activity
  payload-converter abstraction.
- Upstream rule `rules/dsl-boundary.yml` lets the DSL import only Petrinet, Binding, and Motus Activity. Binding
  itself imports Activity (`rules/binding-dependencies.yml`), so the Haskell Activity value/converter modules must
  sit **at or below** `petrus-impetus`, either as a leaf package or as modules inside it. That decision belongs to
  the packaging owner.
- Can be built once `Net`/`NetUri` and the typed binding derivation exist. Equivalence testing needs the
  net-definition v3 projection/serializer.

### Telemetry (`telemetry.py`)

Source: `src/petrus/telemetry.py` (268 lines). Tests: `tests/petrus/telemetry/test_telemetry.py` (29 functions) and
`test_telemetry_instrumentation.py` (22 functions).

> **Correction to the brief: upstream uses no OpenTelemetry at all.**
> - There is no `opentelemetry` import in `src/`, no OTel dependency in `pyproject.toml`, and zero `opentelemetry`
>   entries in `uv.lock`; `grep -i "opentelemetry|otel|otlp"` finds nothing in code.
> - Telemetry is a home-grown structured-event emitter that writes one JSON line per event to the stdlib logger
>   `impetus.telemetry`.
> - The repo's `SCOPE.md` "OpenTelemetry collectors" line is not backed by the pinned upstream. Parity therefore
>   means the **same event names, fields, levels, and JSON line**, not OTel spans.
> - hs-opentelemetry can be an optional, non-parity adapter (see 4).

#### 1. Responsibility & public API

The design rule (module docstring, 1-49; [ES-020]) is that telemetry is an operational shadow of the semantic
history:

- It is **never consulted by semantics**, and telemetry failure never breaks a run.
- The module is layer zero and imports no Petrus module. `tests/project/test_conventions.py` exempts it as an
  "orthogonal leaf".
- The kernel emits facts stamped with **virtual** instants, never wall-clock time. Wall-clock spans exist only in
  Engine coordination, history backends, Dispatch, and the Worker.

| API | Lines | Behavior |
| --- | --- | --- |
| `python_logger = logging.getLogger("impetus.telemetry")` | 63 | Logger name is fixed (tested). |
| `LEVELS = ("off", "facts", "profile", "debug")` | 72 | An ordered ladder. |
| `_level` initial value | 81 | `os.environ.get("IMPETUS_TELEMETRY_LEVEL", "facts")`, validated at **import**. An unknown value raises `ValueError("unknown telemetry level 'x': one of off, facts, profile, debug")`. |
| `level()`, `set_level(level)`, `at_level(minimum) -> bool` | 84-97 | Process-global. `at_level` compares ladder indices. |
| `EventSink` protocol `info(payload: dict) -> None` | 100-103 | |
| `JsonLogger(logger).info(payload)` | 106-116 | `logger.info(json.dumps({**payload, "ts": int(time.time() * 1000)}, default=str))`. |
| `TelemetryRecorder(list)` | 119-123 | Test sink. It appends the payload dict with **no `ts`**. |
| `_default_sink = JsonLogger(python_logger)` | 126 | Process-global. |
| `TelemetryLogger(namespace, logger=None, context=None)` | 129-170 | `bind(**fields)` returns a child; binding a field twice raises `ValueError("Telemetry context already has field(s): a, b.")`. `emit(name, **fields)` returns immediately when the level is `"off"`. The sink is resolved **at emit** (`logger is None` means the current default, which is how `capture()` reaches import-time loggers). The payload is `{"event": f"{namespace}_{name}", **context, **fields}`. Sink exceptions are swallowed (`except Exception: pass`). `span(name, **fields)` returns a `Span`. |
| `Span` | 173-228 | `__enter__` stamps `perf_counter()` and emits `{name}_started`. `__exit__` emits `{name}_finished` with `{**result, "status": "success"\|"failed", "elapsed_ms": int, ["error_type": exc_type.__name__]}`. It never suppresses (returns `False`). `milestone(name, **f)` emits `{span}_{name}` with `elapsed_ms`. `set(**f)`, `increment(field, amount=1)`, and `accumulate_time(field)` (a context manager that adds elapsed ms even when the block raises) build `result`. `elapsed_ms()` before entry raises `RuntimeError("span has not started")`. Child spans and emits inherit the span's bound fields (`logger.bind(**fields)`). |
| `elapsed_ms(started)` | 231-232 | `round((perf_counter() - started) * 1000)`. Python `round` is banker's rounding. |
| `max_rss_mb()` | 235-239 | `getrusage(RUSAGE_SELF).ru_maxrss` divided by `1024**2` on Darwin (bytes) or `1024` elsewhere (KB), then `round(x, 1)`. |
| `current_rss_mb()` | 242-249 | Field 2 of `/proc/self/statm` × `sysconf("SC_PAGE_SIZE")` / `1024**2`, `round(.., 1)`. Returns `None` on `OSError`, `ValueError`, or `IndexError` (macOS has no /proc). |
| `capture(recorder=None, level=None)` | 252-264 | A context manager. It swaps the global sink (and optionally the level) and restores both. |
| `get_logger(namespace, logger=None)` | 267-268 | |

**Event catalog.** Every production emitter uses `get_logger("impetus")`, so every event name starts with
`impetus_`. The Haskell port of each component must emit the same names and fields, in the same field order, at the
same points: after the durable append, with the virtual instant. Field order matters only for the JSON line.

| Event | Emitter | Fields (in order) |
| --- | --- | --- |
| `instance_created` | `impetus/instance/__init__.py:929` | `places, transitions, records, instant` |
| `instance_resumed` | `instance:1179` | `records, watermark, in_flight` |
| `firing_begun` | `instance:1518` | `transition, occurrence, instant, impure` |
| `activity_redelivery_acknowledged` | `instance:1599,1619` | `occurrence` |
| `activity_result_recorded` | `instance:1632` | `transition, occurrence, instant` |
| `firing_completed` | `instance:1855` | `transition, occurrence, instant, records` |
| `firing_failed` | `instance:1962` | `transition, occurrence, instant, error` |
| `delivery_conflicted` / `delivery_redelivered` | `instance:2094` / `:2105` | `source, identity, occurrence` (prior or `None`) |
| `delivery_accepted` | `instance:2179` | `source, identity, occurrence, tokens` |
| `registrations_sealed` | `instance:2270` | `source, closed, instant` |
| `timer_matured` | `instance:2289` | `maturation, instant` |
| `drive_started` / `drive_finished` (span `drive`) | `engine/_coordination.py:546-595` | finished: `reconciled_firings`, `observe_ms`, `apply_ms`, `begin_ms`, `handler_ms`, `commit_ms`, `actions`, `firings`, `waiting`, `ready`, then `status`, `elapsed_ms`, `[error_type]`. Result fields appear in the order they were first set. |
| `gauges` (only `at_level("profile")`) | `_coordination.py:117-135,593` | `history_records, places_occupied, tokens_total, in_flight, current_rss_mb, max_rss_mb` |
| `candidate_selection_declined` | `_coordination.py:693` | `enabled` |
| `activity_cancelled` | `_coordination.py:883` | `occurrence, history_position, disposition` |
| `jsonl_commit` | `impetus/history_store/jsonl.py:174` | `records, bytes` (Σ `len(line)+1` in *characters*), `elapsed_ms` |
| `postgres_commit` | `history_store/postgres.py:226` | `records, entered, elapsed_ms` |
| `dispatch_published` | `motus/dispatch/local.py:167` | `instance, occurrence, queue, activity` |
| `dispatch_cancelled` | `local.py:214` | `instance, occurrence, history_position, disposition` |
| `dispatch_collected` | `local.py:236` | `instance, occurrence, outcome` (outcome `kind`) |
| `dispatch_lease_expired` | `local.py:344,480` | `instance, occurrence, attempt, epoch, claimant, outcome="failed"` |
| `dispatch_claimed` / `dispatch_heartbeat` / `dispatch_failed` / `dispatch_completed` | `local.py:354,381,440,453` via `_emit_attempt` (570-582) | `instance, occurrence, attempt, epoch, claimant, queue, activity, [outcome]` |
| `absurd_dispatched` | `motus/dispatch/absurd.py:720` | `occurrence, activity, queue, task` |
| `absurd_cancelled` | `absurd.py:774` | `occurrence, history_position, disposition, queue, task` |
| `absurd_collected` | `absurd.py:946` | `results, failures` |
| `worker_started` / `worker_stopped` | `motus/worker/__init__.py:125,136,494,524` | `worker, concurrency` |
| `worker_activity_started` / `_finished` (span) | `worker:181-222, 615-663` | bound `worker, queue, activity, attempt, epoch, claimant`; finished adds `outcome`, `max_rss_mb` (or `outcome="refused"`) |
| `fabric_registered`, `fabric_conflict`, `fabric_denied`, `fabric_exposed`, `fabric_offered`, `fabric_granted`, `fabric_redelivered`, `fabric_submitted`, `fabric_accepted`, `fabric_pruned` | `fabric/postgres.py:126-396` | `operation` (`register`/`submit`/`acknowledge`/`authenticate`), `instance`/`sender`/`recipient`, `source`, `service`, `correlation`, `delivery_id`, `state`, `occurrence`, `deliveries`. See the lines for exact per-event sets. |
| `lifecycle_denied`, `lifecycle_conflict`, `lifecycle_claimed` | `processes/postgres.py:69,87,89` | `operation, instance` / `operation, parent, spawn_id` / `parent, spawn_id, child, prior_claim` |

**Bound context:**

- Instance events are bound with `instance=<instance_id>` and, when the net is named, `net=<net.name>`
  (`instance/__init__.py:181-188`). The instance id is always present because instances mint one.
- Engine `drive`, `gauges`, `candidate_selection_declined`, and `activity_cancelled` use the same binding
  (`_coordination.py:106-113`).
- History stores, Dispatch, Worker, Fabric, and processes emit unbound.

#### 2. Wire formats, durable schemas, protocols

- **The JSON line** (the only external format) is `json.dumps({**payload, "ts": <int ms>}, default=str)`. That
  means CPython default separators `", "` and `": "`, `ensure_ascii=True`, and `allow_nan=True` (`NaN`/`Infinity`
  are emitted as bare literals).
- **Key order** is insertion order: `event`, then bound context in bind order, then emit or span fields, then `ts`
  last. Quirk: if a payload already contains `ts`, its value is replaced but it keeps its original position.
- Non-JSON values are rendered with `str(...)`. `NetPath` becomes its dotted string; an exception becomes
  `str(e)`, which is only the message (tested: `ValueError("boom")` becomes `"boom"`).
- `ts = int(time.time()*1000)` truncates; it does not round.
- The line goes to `logging.getLogger("impetus.telemetry").info(...)`. Final framing (newline, prefix) is whatever
  handler and formatter the host configures. With no handler configured, Python's lastResort handler drops INFO,
  so nothing is printed.
- **Env var:** `IMPETUS_TELEMETRY_LEVEL` ∈ {off, facts (default), profile, debug}, read at module import.
- Telemetry is not part of any spec document. `docs/process/deterministic-simulation-testing.md:375` classifies
  telemetry clocks as "External" nondeterminism, not simulated.

#### 3. Concurrency & durability semantics

- Sink and level are unsynchronized process globals; under the GIL, assignment is atomic.
- `capture()` is not thread-scoped: an emit from any thread during the block lands in the recorder.
- Every emit is synchronous in the caller's thread.
- Sink failures are swallowed. However, `merged_fields` raises **before** the `try`, so a duplicate-field
  `ValueError` propagates to the caller, including from `Span.__exit__`, where it replaces the in-flight exception.
  With the level `off` there is no duplicate check, because emit returns first.
- No buffering and no durability.
- `perf_counter` is monotonic; `ts` is wall clock.

#### 4. External dependencies

Python uses only the stdlib (`logging`, `json`, `time`, `resource`, `os`, `sys`). Haskell:

| Need | Suggested |
| --- | --- |
| Exact JSON line | `petrus-json` (`dumps` with Python-default separators, `ensureAscii = True`, insertion-ordered objects, non-finite literals allowed). Not aeson: its key order and float spelling differ. |
| Monotonic clock | `GHC.Clock.getMonotonicTimeNSec` (base) |
| Wall clock `ts` | `Data.Time.Clock.POSIX.getPOSIXTime`, truncated |
| `getrusage` maxrss | `unix` does not expose `ru_maxrss`, so use a 5-line FFI to `getrusage(RUSAGE_SELF)` and keep the Darwin-bytes vs Linux-KB divisor. Do **not** use `GHC.Stats`, which reports heap, not RSS. |
| Page size, `/proc/self/statm` | FFI `sysconf(_SC_PAGESIZE)`; read `/proc/self/statm` with `bytestring` |
| Host routing ("handlers") | A pluggable `Sink` record (`emitLine :: ByteString -> IO ()`). Optionally provide adapters for `co-log-core` / `katip` / `fast-logger` / `monad-logger`; no package is required. |
| OpenTelemetry (non-parity extra) | `hs-opentelemetry-api` + `-sdk` + `-exporter-otlp` (iand675/hs-opentelemetry). These are mature enough for spans and attributes; their metrics API is still incomplete (flag). An optional `petrus-telemetry-otel` sink can map `Span` to an OTel span (attributes = bound + result fields) and `emit` to a span event. That is not required for parity because upstream has nothing comparable. |

#### 5. Upstream tests

- **`test_telemetry.py` (29):**
  - logger name;
  - `JsonLogger` line shape: `ts` is an int, and `ts` is absent from recorder payloads;
  - `default=str` stringification;
  - bind inheritance and immutability, duplicate-bind and duplicate-emit refusal;
  - a failing sink never raises;
  - span started/finished, failed status plus `error_type`, child-span and span-emit inheritance;
  - `accumulate_time` summing, including on exception (monkeypatched `perf_counter` sequences produce exact values
    500/1000 and 300/1000);
  - `increment`, and `milestone` elapsed (250);
  - levels: default `facts`, unknown refused, `off` silences, ladder order, `capture` restores the level;
  - `max_rss_mb > 0`;
  - `current_rss_mb` parses statm (`262144` pages × 4096 → `1024.0`) and returns `None` on `OSError`.
- **`test_telemetry_instrumentation.py` (22):**
  - kernel door events: created, begun→completed correlated by occurrence, a fruitless step emits nothing,
    firing_failed, the delivery lifecycle and redelivery, seal count, the wake-only-when-matured rule, and resume
    under the recorded identity;
  - JSONL commit events;
  - the Engine `drive` span bracketing door events, and a failed span on a raising handler;
  - identity binding (minted id, driver span, named net, resume, no emit before a refused resume);
  - phase timings present;
  - gauges only at `profile`;
  - drive outcome fields `actions=1`, `firings=1`, `waiting=False`.

  These tests depend on `Engine`, `Instance`, `InMemoryHistoryStore`, `JsonlHistoryStore`, and `InMemoryDispatch`,
  and must be ported alongside those components.
- None need Docker, network, or markers.
- Haskell tests need an injectable monotonic clock to reproduce the exact `perf_counter` sequences. Use a `Clock`
  field in the telemetry handle rather than monkeypatching.

#### 6. Performance

Hot path: `emit` on every committed fact batch. At `facts` level, Python runs `json.dumps` **even when no handler is
attached**: `JsonLogger.info` formats before calling `logger.info`, contrary to the docstring's "no-op string format
away from free".

Benchmark:

- (a) Per-emit cost with no handler, with a null handler, and with a recorder, using a 6-field payload with bound
  context.
- (b) `Instance.run()` over a 1k-firing chain net with telemetry `off` vs `facts`, to report overhead percentage.
- Python: `timeit`. Haskell: `tasty-bench`.
- For equivalence, both must produce byte-identical lines for a fixed payload. Pin `ts` with an injectable wall
  clock.

Haskell can stay lazy: build the line only when the sink is enabled, and add `isEnabled` to the sink. The bytes
stay the same when lines are emitted.

#### 7. Better-the-Haskell-way suggestions

- **Explicit handle instead of a global**:
  `data Telemetry = Telemetry { tSink :: Sink, tLevel :: Level, tClock :: Clock, tContext :: [(Text, Value)] }`,
  passed through the component's environment (a `ReaderT` or a record field).
  - Keep a process-default `IORef` (`NOINLINE`) only to mimic `capture()`.
  - Tests can then inject a recorder sink without global state, which is safer under `-threaded` and parallel tests.
- `data Level = Off | Facts | Profile | Debug deriving (Eq, Ord, Enum, Bounded)`; read `IMPETUS_TELEMETRY_LEVEL`
  once at startup and reject unknown values loudly.
- **Spans with `bracket`-like semantics:**
  - `withSpan :: Telemetry -> Text -> Fields -> (SpanH -> IO a) -> IO a`;
  - `SpanH` has an `IORef` result map that keeps insertion order (an ordered association list, not `Map`);
  - on exception it emits `status="failed"` and `error_type` = the exception's type constructor name
    (`show (typeRep)` of the inner exception), then rethrows. Note that Haskell type names differ from Python's
    (`RuntimeError`); operators matching on `error_type` must accept this;
  - `accumulateTime` uses `finally`.
- Duplicate bound fields: keep the runtime refusal for parity. Optionally add a typed-field API for internal call
  sites. Do not let a duplicate escape into semantic code paths: the Python quirk where emit can raise into the
  kernel on a duplicate is a programming error, so treat it as one.
- Never let sink exceptions escape. Catch synchronous exceptions only; rethrow async ones.
- Rounding must use banker's rounding: Haskell `round` on `Double` already rounds half to even, matching Python
  `round(x)`. For `round(x, 1)` on RSS, compute exactly (`fromRational`/decimal) or accept tiny drift; RSS is
  non-semantic.

#### 8. Packaging

- A new leaf package, `petrus-telemetry`. Dependencies: `base`, `text`, `bytestring`, `petrus-json`, `time`, and
  `petrus-posix` for the `getrusage`/`sysconf` gauges.
- **No Petrus dependencies above those two**, mirroring the layer-zero rule. Every instrumented package (`petrus-impetus`, engine,
  history stores, dispatch, worker, fabric, processes) depends on it.
- It can be built now, in parallel with everything. The kernel ports should take the `Telemetry` handle from the
  start, so instrumentation is not retrofitted.

### Deterministic simulation testing kit (`testing/dst.py`)

Source: `src/petrus/testing/dst.py` (2656 lines), the supported cross-project test kit `petrus.testing.dst/v4`.
Docs: `docs/process/deterministic-simulation-testing.md` (correctness contract), `dst-world.md` (interpreter
contract), `dst-world-v1..v4.md` (version deltas and fixture index), `dst-process-runner-v1.md` (watchdog),
`dst-scenario-v1.md` (the older internal `petrus-dst-scenario` envelope used by `tests/dst/replay.py`).

The kit is **runtime-neutral**: `rules/testing-dst-boundary.yml` forbids it from importing any `petrus` module. It
depends only on pydantic and the stdlib. Petrus semantics live entirely in test-owned **profiles**
(`tests/dst/*_world.py`, about 23k lines in total with tests).

#### 1. Responsibility & public API

Identities (`dst.py:26-48`):

- APIs `petrus.testing.dst/v1`…`/v4`;
- artifact format `petrus-dst-world`, versions 1, 2, 3, and 4 (current);
- result format `petrus-dst-world-replay-result`, version 2 (version 1 for v1 artifacts);
- runner API `petrus.testing.dst.runner/v1`;
- runner protocol `petrus-dst-process-runner` v1;
- run result `petrus-dst-process-run-result` v1;
- `MAX_ARTIFACT_BYTES = 4_194_304` and `MAX_PROCESS_PROGRESS_BYTES = 16_777_216`.

Regexes:

- `_NAME = ^[A-Za-z][A-Za-z0-9_.:-]*$`
- `_DIGEST = ^sha256:[0-9a-f]{64}$`
- `_ENTRYPOINT = ^[A-Za-z_][A-Za-z0-9_.]*:[A-Za-z_][A-Za-z0-9_]*$`
- portable integers are ≤ 2^53−1.

| Concept | Lines | Contract |
| --- | --- | --- |
| Enums | 58-94 | `Disposition` {converged, quiescent, external_wait, budget_exhausted, invariant_failure, quarantined}; `ActionDisposition` {applied, idempotent, refused_expected, quarantined}; `FaultDisposition` {refuse, raise, delay, drop, duplicate}; `ChoiceAuthority` {workload, fault, identifier, event_order}. |
| `_strict_json(value)`, `digest_json(value)` | 97-129 | Only `None`, `bool`, `int`, `str`, finite `float`, `list`, and `dict` with `str` keys, using **exact** `type()` checks, so subclasses are refused. Digest: `"sha256:" + sha256(json.dumps(v, allow_nan=False, separators=(",",":"), sort_keys=True).encode()).hexdigest()`. `ensure_ascii` defaults to `True`. |
| `ChoiceStreams(seed)` | 157-216 | See the algorithm in 2. `index(authority, stop)`, `identifier(namespace)`, `provenance() -> ChoiceProvenance{algorithm, seed, draws(sorted)}`. |
| `ComponentIdentity{name, version>=1, digest}` → `ProfileIdentity`, `CheckerIdentity` | 219-246 | Registry key `(name, version, digest)`. |
| `Command{profile, name, payload}` | 249-266 | The name may not start with `dst.`. |
| `Fault{profile, name, target, occurrence>=1, disposition, payload}` | 269-289 | |
| `Budget` (v1-v3) | 292-301 | `actions` 1..100000; `queued_commands` 1..10000; `timer_advances` 0..10000; `logical_instant` 0..2^53−1; `reloads` 0..1000; `predicate_polls` 1..100000; `artifact_bytes` 1..4194304. |
| `BudgetV4` | 313-328 | The same fields plus `profile_resources: dict[name, 0..2^53−1]`. |
| `ResourceUsage{values}` | 331-339 | |
| `ScheduledCommand{instant, command}`; `ApplyResult{disposition, value, scheduled: list}`; `GenerationStart(generation, scheduled: tuple)` | 342-373 | |
| `ObservationRequest{name, payload}`; `Observation{name, value, instant, generation>=1, sequence>=0}`; `CheckResult{passed, detail}` | 376-419 | |
| `ScenarioProfile[G]` protocol | 422-441 | `identity`, `validate(cmd)`, `validate_fault(f)`, `create(ctx)`, `load(ctx)`, `apply(g, cmd, ctx)`, `observe(g, req, ctx)`, `drop(g)`, `close(g)`. `ResourceScenarioProfile` adds `resource_usage(g \| None)` (444-447). |
| `Checker` protocol | 450-456 | `identity`, `request: ObservationRequest`, `check(observation) -> CheckResult`. |
| Attempts | 459-548 | `submit{generation, command}`, `step{}`, `activate_fault{generation, fault}`, `observe{generation, request, poll}`, `crash{generation, cut}`, `restart{}`, `begin_fair{generation}`, `finish{generation, disposition}`. The runner-only attempts are `construct{}` and `close{generation}`. |
| Failure details | 551-563 | `budget_exhausted{bound, limit, error}` and `invariant_failure{error}`. |
| Expanded operations | 566-651 | `execute{position, source: authored\|profile, queue_order, instant, generation, command, result}`; `activate_fault{position, instant, generation, fault}`; `observe{position, poll, observation, request}`; `crash{position, instant, generation, cut, discarded_commands}`; `restart{position, instant, generation}`; `begin_fair{…}`; `finish{…, disposition}`; `failure{position, instant, generation\|null, accepted_operations 0..1, attempt, failure}`. The last one is v2+ only. |
| `JournalEntry{position, instant, generation\|null, kind, name, value}` | 654-680 | Kinds: created, loaded, command, fault, observation, check, crash, fair, finish, budget, failure, resource. |
| Artifacts | 683-841 | `ScenarioArtifactV1` (no failure, `ScenarioExpectedV1`), V2, V3 (`origin: ChoiceProvenance\|null`), and `ScenarioArtifact` (v4, `budget: BudgetV4`). |
| Replay results | 843-863 | |
| Errors | 866-918 | `DstError(RuntimeError)`, `StaleGeneration`, `PendingWork`, `BudgetExhausted(bound, limit)` with message `"DST budget {bound!r} exhausted at limit {limit}"`, `InvariantViolation(AssertionError)`, `ReplayMismatch`, and `RunUntilFailed(name, disposition, observation, pending, journal, budget)`. |
| `ScenarioContext` | 935-954 | `now()`, `stable_id(ns)`, and `faults(target)`, usable only inside a profile call. |
| `ScenarioRegistry` | 957-989 | Fail-closed exact lookup. Duplicate registration raises `ValueError`. |
| `World(profile, budget, *, checkers=(), seed=None)` | 1000-1645 | Public methods: `submit`, `step`, `activate_fault`, `observe`, `crash`, `restart`, `begin_fair`, `finish`, `artifact(scenario_id)`, `close()`, `pending()`, `timeline()`, `choices`, `generation`, `operations`, `journal`, `disposition`. |
| `Timeline(world, generation)` | 1647-1710 | `command(name, payload)`, `activate_fault(name, target, *, occurrence=1, disposition=RAISE, payload=None)`, `observe`, `run_until(name, predicate, *, payload=None)`, `crash`, `begin_fair`, `finish`. |
| Process runner | 1716-2335 | `ProcessBudget`, `ProcessRunSpec`, `ProcessWorldMetadata`, `AcknowledgedPrefix`, `ProcessRunResult`, the frames, `_FileProgress`, `ProcessSession.world(...)`, `run_process_scenario(spec)`, `_process_child_main`. |
| Codec and replay | 2337-2575 | `encode_artifact`, `decode_artifact`, `load_artifact`, `replay(artifact, registry)`. |

Kernel APIs used: **none.** Profiles (test code) use `Engine`, `Instance`, `JsonlHistoryStore`, SQLite and Postgres
history, `InMemoryDispatch`, `LocalDispatch`, Absurd, `SimulatedClock`, and similar.

**Interpreter semantics.** Exact replay depends on these; reproduce them verbatim.

**Construction** (1003-1050):

1. Notify `construct`.
2. Sample resources (`None`, trigger `"before_create"`).
3. `create` through `_invoke`.
4. `_install_generation`: assign `generation_id = ++last` and enqueue the scheduled commands (source `profile`).
5. Record `created` with value `{"scheduled": [..]}`.
6. Sample `"create"`.
7. Run the checkers with trigger `"create"` and sequence `0`.

Any failure closes an installed generation, then re-raises. Constructor failures can never be retained as
artifacts.

**Queue:** a heap of `(instant, order)`. `order` is the global monotone `_queue_order` and is unique.

**`submit`** (1084-1094):

- Requires the live generation and not fair.
- Raises `PendingWork` if the queue head is due (`head.instant <= now`).
- Enqueues at `now` as `authored`, then `_step`s. That step must execute the authored command.

**`_step`** (1099-1138):

1. Requires a live generation and a non-empty queue, and the head must be of the live generation.
2. If the head is in the future, check `timer_advances`, then `logical_instant` (the `_exhaust` order matters).
3. `_reserve_action` checks `actions`.
4. Pop; advance time, incrementing `timer_advances`.
5. `apply`.
6. Append `ExecuteOperation` and record `command` (name = command name, value = the operation dump).
7. Enqueue follow-ups:
   - check that the total `queued_commands` ≥ len + new;
   - per item, refuse a past instant (`ValueError`, not a budget) and check the `logical_instant` ceiling;
   - validate via `profile.validate`.
8. Sample with trigger = command name.
9. Checkers.

**`_activate_fault`** (1144-1170):

1. Requires generation, unfinished, not fair, matching profile, and no due work (`PendingWork`).
2. `validate_fault`.
3. Reserve an action.
4. Append the operation and the active fault, and record `fault`.
5. Sample `fault:<name>`.
6. Checkers with trigger `fault:<name>`.

**`_observe`** (1176-1193):

1. Reserve an action, then check `predicate_polls` if `poll`.
2. Sequence = operation position.
3. Record `observation`.
4. Sample `observe:<name>`.

No checkers run.

**`_crash`** (1199-1226):

1. Requires not fair and a `_NAME` cut.
2. Reserve an action.
3. **Capture** the checker observations and results on the live generation (sequence = position) without recording
   them.
4. Count and clear the queue (`discarded_commands`) and revoke the generation.
5. `drop`.
6. Append `CrashOperation`.
7. Record `crash` with `generation=None`.
8. Sample `(None, "crash:<cut>")`.
9. Record the captured checks with their observation generation. A failed check raises here.

**`_restart`** (1231-1248):

1. Requires no live generation.
2. Check `reloads`, then reserve an action, then `reloads += 1`.
3. `load`, then install, which enqueues follow-ups before the operation exists.
4. Append `RestartOperation`.
5. Record `loaded` (name = profile name).
6. Sample `"load"`.
7. Checkers with trigger `"load"`.

**`_begin_fair`** (1254-1269):

1. Requires no unconsumed active fault and not already fair.
2. Reserve an action.
3. Set `fair`.
4. Record `fair` / `"begin"`.
5. Sample `"begin_fair"`.
6. Checkers with trigger `"begin_fair"`.

**`finish`** (1271-1302):

- Only the four authored dispositions are accepted.
- Fair plus `external_wait` is refused.
- Remaining queue entries raise `PendingWork`.
- Reserve an action, append, set the disposition, record `finish` / `<disposition>`, and sample
  `finish:<disposition>`. No checkers run.

**`_record_checks`** (1465-1483):

- One `check` journal entry per checker, named with the checker name, with value
  `{"checker", "trigger", "observation", "result"}` and generation = observation generation.
- If any check failed, the disposition becomes `invariant_failure` and the call raises
  `InvariantViolation(f"DST checker failure after atomic boundary: {failed}")`. `failed` is a **Python list
  repr**: `['a', 'b']`.

**`_sample_resources`** (1488-1515):

- v4 budgets only.
- The keys must equal the budget keys exactly, otherwise `ValueError` (a profile contract failure, not a budget).
- Record `resource` / trigger with `{"usage": sorted}` and generation = the current id, or `null` when the
  generation is `None`.
- Over-limit keys are sorted, and the first one exhausts `profile_resources:<name>`.

**`_exhaust`** (1551-1554) sets `budget_exhausted`, records `budget` / bound with `{"limit": n}`, and raises.

**`_attempt`** (1556-1592):

- Catches only `BudgetExhausted` / `InvariantViolation`, and only when the disposition was set by the World.
- Builds `FailureOperation{position, instant, generation: current id, accepted_operations: ops added (0 or 1), attempt, failure}`.
- Appends it, records `failure` / kind with the operation dump, notifies the boundary, and re-raises.
- Profile and checker exceptions pass through unclassified.

**Other rules:**

- `_invoke` forbids re-entering the World from a profile and sets `_inside_profile` for `ScenarioContext`.
- `stable_id(ns)` returns `f"{ns}-{n:08d}"`, with a per-namespace counter from 1.
- `faults(target)` increments `seen` on each active fault with that target. It returns and removes faults whose
  `seen == occurrence`.
- `Timeline.run_until` loops: `observe(poll=True)`, test the predicate, raise `RunUntilFailed(EXTERNAL_WAIT)` if
  the queue is empty, otherwise `step()`.
- `World.artifact(id)` requires a disposition and always authors **v4 when the budget is `BudgetV4`, otherwise
  v3**; it never authors v1 or v2. It sets `expected.checks` = all `check` entries and `journal_digest`, and
  enforces `artifact_bytes` via `encode_artifact`, raising `ValueError`.

**Replay** (2391-2500):

- Fresh `World(registry.profile(id), artifact.budget, checkers=registry.checkers(manifest))`. It is unseeded and
  never consults `origin`.
- Each expanded operation is driven through the public method:
  - `execute/authored` → `submit`;
  - `execute/profile` → `step`;
  - `failure` → its attempt.
- The produced operations must equal the expected slice. The pydantic model equality covers values.
- A failure must be the final operation. A non-failing operation followed by a `failure` with
  `accepted_operations=1` must reproduce it.
- Afterwards the disposition, the `check` entries, and the journal digest must all be equal.
- `ReplayResult{format, version (1 for a v1 artifact else 2), scenario_id, outcome:"pass", disposition, [failure], operations, journal_entries, journal_digest}`.
- Always `close()`.

#### 2. Wire formats, durable schemas, protocols

All DST bytes are CPython `json` output, so `petrus-json` is mandatory.

- **Canonical artifact bytes** (`encode_artifact`, 2344-2352):
  `json.dumps(model_dump(mode="json"), allow_nan=False, separators=(",",":"), sort_keys=True).encode()`.
  This means `ensure_ascii=True`, keys sorted by code point, and no trailing newline (retained fixture files add
  one `\n`). Floats use Python `repr`. Over `budget.artifact_bytes`, encoding raises `ValueError("DST artifact has N bytes; limit is L")`.
- **Decode** (`decode_artifact`, 2355-2379):
  1. Reject anything over 4 MiB.
  2. Strict parse: duplicate keys raise `"duplicate JSON field 'k'"`; `NaN`/`Infinity`/`-Infinity` raise
     `"non-finite JSON number X"`.
  3. Dispatch on `version` 1/2/3/4, else `"unsupported DST artifact version"`.
  4. Pydantic `strict=True`, `extra="forbid"`: bool is never accepted as int, float is never accepted as int,
     and unknown fields are refused.
  5. Check per-artifact `artifact_bytes`.
  6. Coherence validators (717-733, 769-817): dense zero-based positions; ordered unique `check`-kind expected
     entries; unique checker identities; command and fault profiles equal the artifact profile; failure
     artifacts end with exactly one `failure` whose `failure` equals `expected.failure`; `accepted_operations=1`
     requires the previous operation to be produced by the attempt (`_attempt_produced_operation`, 2503-2548);
     `failure.kind == expected.disposition`; successful artifacts carry no failure.

Top-level key sets:

| Version | Keys | Notes |
| --- | --- | --- |
| v1 | `api, budget, checkers, expected, format, operations, profile, scenario_id, version` | `expected = {checks, disposition, journal_digest}`; operations exclude `failure` |
| v2 | v1 keys | `expected = {checks, disposition, failure, journal_digest}`; `failure` operations allowed |
| v3 | v2 keys + `origin` (`null` or `{algorithm, draws, seed}`) | |
| v4 | v3 keys | `budget` gains `profile_resources` |

Other formats and rules:

- **Journal digest:** `digest_json([entry.model_dump(mode="json") for entry in journal])`. Only the `check` entries
  are retained in the artifact, but the digest covers **every** entry, including `resource` samples (whose values,
  for example `retained.history_bytes` = the JSONL file size, are produced by the runtime under test). A Haskell
  replay matches only if every journal entry is byte-identical.
- **Profile and checker identities** in the retained fixtures are `digest_json` of a declared definition dict, not
  of source code (e.g. `tests/dst/engine_world.py:65-238`). A Haskell profile can therefore claim the same identity
  by reproducing the dict.
- **Replay CLI output** (`tests/dst/replay_world.py:102-112`): one line,
  `json.dumps(result, allow_nan=False, separators=(",",":"), sort_keys=True)`.
- **Strings embedded in artifacts must match exactly:**
  - `BudgetFailure.error` = `"DST budget 'actions' exhausted at limit 1"` (Python `!r` with single quotes);
  - `InvariantFailure.error` = `"DST checker failure after atomic boundary: ['petrus.engine.deliberate-terminal-refusal']"`.
- **`ChoiceStreams` `sha256-counter-v1`** (157-216, `dst-world.md` §1k):
  - Hash input: `sha256(json.dumps(["sha256-counter-v1", seed, stream_key, ordinal, probe], separators=(",",":")).encode())`.
  - Index draw: `stream_key` = the authority value (`workload`, `fault`, `event_order`). Read the 32-byte digest
    as a big-endian unsigned integer `v`. With `ceiling = 2^256 − (2^256 mod stop)`, accept `v < ceiling` and
    return `v mod stop`. Otherwise `probe += 1`, failing loudly after 16 probes. The ordinal increments only on
    acceptance.
  - Identifier draw: key `identifier:<ns>`, probe 0, ordinal incremented each time. Return
    `f"{ns}-{digest.hex()[:32]}"`.
  - Golden values for seed 1729 (verified): workload `stop=1000` → `[584, 541, 292, 147]`; `identifier("scenario")`
    → `scenario-4a6cb3d68a08da140c56fd1ed8bcbce2`.
  - `provenance.draws` is a sorted map of `key → count`. Validation: names are authorities except `identifier`, or
    `identifier:<NAME>`; counts are 1..2^53−1.
- **Campaign seeds** (`tests/dst/campaign.py:162-171`): `int.from_bytes(sha256(json.dumps(["petrus-dst-campaign-report", 1, campaign_id, profile], separators=(",",":"))).digest()[:4])`.
- **Process runner protocol** (`dst-process-runner-v1.md`; 1716-2335):
  - The parent writes `spec.json` (canonical compact sorted bytes of `ProcessRunSpec{scenario_id, entrypoint, payload, budget}`) into
    `tempfile.TemporaryDirectory(prefix="petrus-dst-runner-")`. Over `input_bytes`, it raises `ValueError` before
    launch.
  - It spawns `sys.executable -c "...from petrus.testing.dst import _process_child_main; raise SystemExit(_process_child_main(Path(argv[1]), Path(argv[2])))" spec.json progress.jsonl`,
    with stdin, stdout, and stderr all on `DEVNULL` and `start_new_session=True` (a new session, so the pgid equals
    the pid).
  - The child opens `progress.jsonl` with mode `"xb"` (exclusive create, unbuffered). Each frame is
    `json.dumps(frame, allow_nan=False, separators=(",",":"), sort_keys=True) + "\n"`, written then `os.fsync`ed.
    The cumulative size is limited by `progress_bytes`.
  - Frames carry a dense `sequence` from 0:
    - `{"kind":"started","protocol":"petrus-dst-process-runner","version":1,"scenario_id",...}`;
    - `{"kind":"world","metadata":{profile, checkers, budget, seed}}`, emitted by `ProcessSession.world()`, which
      allows exactly one World;
    - `{"kind":"attempt","attempt":<ProcessAttempt>}`, before every World attempt including `construct` and
      `close`;
    - `{"kind":"boundary","operations":[delta],"journal":[delta],"instant","generation","disposition"}`, after
      each completed attempt, including failed attempts that were captured;
    - `{"kind":"complete","artifact":...}` or `{"kind":"failed","code":"scenario-failed"}`.
  - The child exits 0 after `complete`. On any `BaseException` it writes `failed` and exits **70**.
  - Parent waits use `wall_clock_ms` (≤ 30000). On timeout:
    1. `killpg(SIGTERM)` and wait `termination_grace_ms` (≤ 5000);
    2. if the child is still alive, `killpg(SIGKILL)` and wait.
    `termination` ∈ {exited, terminated, killed}. `returncode` is Python's (negative signal number when signalled).
  - Reading frames: a missing file gives `progress-missing`; oversize gives `progress-overflow`. A trailing
    partial line is dropped only after a timeout; otherwise it gives `partial-frame`. Malformed input gives
    `malformed-frame`.
  - Folding: an order violation gives `frame-order`; position gaps give `prefix-position`; no `started` frame gives
    `start-missing`; a disagreement between the artifact and the prefix gives `artifact-prefix-mismatch`; no
    terminal frame gives `terminal-missing`. Child codes are `scenario-failed` and `child-exited`.
  - `ProcessRunResult{format, version, api, scenario_id, outcome: completed|harness_failure, termination, returncode, prefix: AcknowledgedPrefix, unfinished_attempt, artifact, failure: wall_clock_timeout{bound:"wall_clock_ms",limit} | child_failure{code} | protocol_failure{code}}`,
    with coherence rules at 1855-1873.
  - Requires POSIX: on a non-POSIX host it raises `DstError`.
- **Test-infra formats** (Python-owned, not interop-critical):
  - `petrus-dst-scenario` v1 (`tests/dst/replay.py`; `dst-scenario-v1.md`; one fixture,
    `projection-crash-recovery-v1.json`, pretty-printed);
  - `petrus-dst-semantic-coverage` v1;
  - `petrus-dst-campaign-report` v1 (≤ 1 MiB; case summaries ≤ 16 KiB in JSONL);
  - `petrus-dst-failure-bundle` v1 (`scenario.json` + `manifest.json`; manifest ≤ 256 KiB; bundle ≤ 4,456,448 B);
  - `petrus-dst-production-boundary-report` v1 (≤ 256 KiB; child 120 s, 5 s grace, 8 KiB tail).
  - Env vars: `PETRUS_DST_CAMPAIGN_TIER`, `PETRUS_DST_CAMPAIGN_CASES`, `PETRUS_DST_CAMPAIGN_SEED`.
- **Fixtures** (`tests/dst/fixtures/`, 53 files): 51 `petrus-dst-world` artifacts (v1×1, v2×2, v3×45, v4×3), every
  one canonical (file bytes = `encode_artifact` + `"\n"`), plus the two pretty-printed test-infra files above.
  - 33 are `joined-*-world-v3.json` (Absurd/PostgreSQL profiles).
  - Operations across all fixtures: 224 execute, 222 observe, 48 crash, 48 restart, 47 finish, 39 activate_fault,
    19 begin_fair, 3 failure.

#### 3. Concurrency & durability semantics

- The World is single-threaded and synchronous: profile calls must return. Logical time only advances when a
  future-dated command is stepped; nothing sleeps.
- Atomicity unit: one public World call. It produces at most one accepted operation plus at most one failure
  operation.
- Crash is "revoke then `drop`" (non-settling). `close` is graceful and runs only for a live generation.
- Process runner durability: every acknowledgement line is `fsync`ed before execution continues, so a complete line
  is the unit of acknowledged progress.
- The parent deadline uses `subprocess.wait(timeout=...)` (monotonic). Escalation is process-group-wide. The direct
  child is always reaped.
- Wall-clock expiry is never turned into a deterministic artifact.

#### 4. External dependencies

| Python | Haskell |
| --- | --- |
| pydantic strict models | Hand-written ADTs with strict `petrus-json` decoders (`strictLoads`, `RejectDuplicates`, `finiteFloatsOnly`, `integerRange` = 2^53 bounds where the model bounds them; payload `JsonValue` integers are unbounded in Python, so keep `Integer`). Each `FromJSON`-like decoder must reject unknown keys, bool-as-int, and float-as-int. Field order in records is irrelevant because encoding is `sort_keys`. |
| `hashlib.sha256` | `crypton` (`Crypto.Hash.SHA256`) or `cryptohash-sha256`; lower-case hex via `base16-bytestring` |
| `heapq` | `Data.Set (Int, Int)` / `Data.Map` keyed by `(instant, order)` |
| `subprocess.Popen(start_new_session=True)`, `os.killpg` | `process` (`CreateProcess{new_session = True}`, `std_* = NoStream`) plus `unix` (`System.Posix.Signals.signalProcessGroup sigTERM/sigKILL pid`); the timeout via `System.Timeout.timeout` around `waitForProcess` (needs `-threaded`). `typed-process` is fine too (`setNewSession True`). |
| `open("xb")` + `os.fsync` | `unix` `openFd` with `exclusive=True, creat`; `fileSynchronise` (or FFI `fsync`) |
| `tempfile.TemporaryDirectory` | `temporary` (`withSystemTempDirectory "petrus-dst-runner-"`) |
| `importlib` entrypoint `module:function` | No dynamic import in Haskell. The child is the **same test executable** re-invoked with a hidden subcommand (`--dst-process-child SPEC PROGRESS`) and a static `Map Text Entrypoint` keyed by the same `dotted.module:function` strings. |
| Hypothesis state machines (`tests/dst/test_generated_*`) | `hedgehog` (`Hedgehog.Internal.State` sequential state machines) or `falsify`. Python seeds are discovery metadata only, so cross-language seed equality is not needed. |

#### 5. Upstream tests

`tests/dst/` holds 23 test files and 193 test functions. Parametrized:
`test_world.py` (5 parametrized tests), `test_failure.py`, `test_replay.py`, `test_resource_world.py`. The generated
ones run Hypothesis with `campaign_settings` (`derandomize=True` in the ordinary tier, `database=None`,
`deadline=None`).

| File (functions) | Covers | Needs |
| --- | --- | --- |
| `test_world.py` (39) | Interpreter kernel: stable ids, tie order, logical time; v4 resource accounting, exact key sets, overage retention; budgets (predicate polls, actions, timer advances, logical instant, queue, reloads, artifact bytes); constructor close-on-failure; finish refuses pending work; fair-phase drain; fault validation; `ChoiceStreams` golden vectors and isolation; seeded story; v1 byte-exactness (`encode(decode(f)) == f.rstrip("\n")`); failed-attempt artifacts and replay; no double application of accepted failed attempts; profile and checker exceptions not reclassified; crash-before-drop; checker cadence; `run_until` diagnostics; surface checks; strict refusals (unknown field, api mismatch, profile digest, position, bool-as-int, duplicate key, NaN); registry mismatch. | Local JSONL plus a toy `QueueProfile`. Roughly half use the public-Engine `EngineProfile`. |
| `test_replay.py` (5) | `petrus-dst-scenario` v1 strictness and fresh-Engine replay | Engine |
| `test_resource_world.py` (3), `test_delayed_world.py` (3), `test_delivery_world.py` (3), `test_dispatch_refusal_world.py` (3), `test_history_ack_loss_world.py` (3), `test_lifecycle_world.py` (3), `test_lifecycle_cancellation_world.py` (4), `test_local_terminal_world.py` (3), `test_retry_world.py` (6), `test_timer_world.py` (3) | Per profile: authored story equals the retained fixture, a manual CLI replay is deterministic (via `subprocess` `python -m tests.dst.replay_world`), and the checker refuses a deliberate violation. | Engine, JSONL, SQLite `LocalDispatch` |
| `test_generated_delivery_world.py` (2), `test_generated_runtime_world.py` (4), `test_generated_runtime_qualification.py` (5) | Hypothesis state machines through the World; fair convergence, livelock shrink, semantic coverage report | Engine, JSONL, SQLite (credential-free) |
| `test_joined_world.py` (67), `test_joined_creation_world.py` (10), `test_joined_registration_world.py` (5), `test_joined_seal_world.py` (5) | Absurd/PostgreSQL transaction cut pairs (commit refusal vs acknowledgement loss); retained-fixture replays | **Docker Postgres** (`absurd_dsn`) |
| `test_process_runner.py` (3) | Input budget refusal; complete fresh-process run plus replay; SIGTERM-ignoring hang escalated to SIGKILL with the acknowledged prefix | POSIX subprocess |
| `test_campaign.py` (6), `test_failure.py` (5), `test_dst_boundaries.py` (3) | Campaign tiers, seeds, caps; failure-bundle retention, credential scan, tamper refusal; real-boundary cohort | `test_dst_boundaries` runs real PG/Absurd, Worker SIGKILL, and ZeroMQ nodes in a child pytest (**Docker**, zmq) |

**What parity means here (recommendation).** There are three tiers.

1. **Kernel parity (required, standalone).** Port the World interpreter, models, codec, replay, `ChoiceStreams`,
   and the process runner into a runtime-neutral Haskell package. Conformance tests:
   - (a) decode→encode is byte-exact for all 51 world fixtures, and the strict refusal mutations are rejected;
   - (b) the `ChoiceStreams` golden vectors;
   - (c) a port of the kernel-only `test_world.py` cases using Haskell toy profiles (`QueueProfile`-like), including
     exact budget-exhaustion ordering and error strings;
   - (d) runner protocol tests. Cross-language: a Haskell parent folds a Python child's `progress.jsonl` and vice
     versa. The file protocol is language-neutral even though the entrypoints are not.
2. **Cross-runtime replay (strongly recommended; the best Python↔Haskell behavioral equivalence test available).**
   Port the test profiles and checkers with the **same identity dicts**, so their digests are equal, onto the
   Haskell Engine. Then replay the **Python-authored fixtures** through the Haskell World. A passing replay means
   the Haskell runtime produced identical observations, apply results, checker verdicts, and resource gauges at
   every boundary, including byte-identical JSONL history sizes.
   - Order of work: the 9 `engine_world.py` fixtures (projection v1, v3, seeded v3; the 2 v2 failures; the 2 v4
     resource fixtures; history refusal; ack loss; dispatch refusal), then the other 9 local fixtures (timer,
     retry×2, terminal, delayed, delivery, lifecycle×2, generated-runtime v4), then the 33 joined fixtures once the
     Haskell Absurd/PostgreSQL provider exists.
   - Also run the reverse direction: Haskell-authored artifacts replayed by Python.
3. **Generated campaigns (Haskell-native).** Use hedgehog state machines over the same interpreter; artifacts, not
   seeds, are the authority. The Python campaign, failure-bundle, and boundary report formats are test-infra and do
   not need byte parity. Recreate equivalent tiers with Haskell-native reports.

The internal `petrus-dst-scenario` v1 (`tests/dst/replay.py`, 1 fixture) is low priority. Port it last or record it
as N/A.

#### 6. Performance

Hot paths:

- canonical encoding of operation dumps on every record (`_strict_json` plus `model_dump` per journal entry);
- `digest_json` over the whole journal;
- pydantic validation on decode;
- runner `fsync` per frame.

Benchmark:

- (a) decode + encode + journal digest for every world fixture and for a synthetic 4 MiB artifact; MB/s.
- (b) Replay throughput of the toy-profile World (no runtime) for 10k operations: operations/s and allocations.
- (c) End-to-end replay of the local Engine fixtures; per-fixture wall time, with the identical profile semantics
  and a tmpfs JSONL path.
- (d) `ChoiceStreams.index` draws/s.

The Python baseline is `python -m tests.dst.replay_world <fixture>` timed in-process, excluding interpreter
startup. Haskell uses `tasty-bench`. The campaign doc's reference run (457 cases in 37.7 s,
`deterministic-simulation-testing.md:254-259`) gives a coarse whole-campaign target.

#### 7. Better-the-Haskell-way suggestions

- **Profiles as a record of functions with an existential generation:**

  ```haskell
  data Profile = forall g. Profile { identity :: ProfileIdentity, validate :: Command -> Either Text Command
           , create :: Ctx -> IO (GenerationStart g), load, apply :: g -> Command -> Ctx -> IO ApplyResult
           , observe :: g -> ObservationRequest -> Ctx -> IO Value, drop, close :: g -> IO ()
           , resourceUsage :: Maybe (Maybe g -> IO ResourceUsage) }
  ```

  The generation type can then never escape into checkers.
  - Make `Ctx` a capability record created only inside `invoke`. This removes the runtime "only during a profile
    operation" errors.
  - Detect re-entrancy with an `IORef Bool`, or structurally by giving profiles no access to the World.
- **Separate artifact versions:**
  - `data AnyArtifact = A1 ArtifactV1 | A2 ArtifactV2 | A3 ArtifactV3 | A4 ArtifactV4`;
  - `data ExpandedOp = ... | OpFailure FailureOp`, where `ArtifactV1`'s operation type excludes `OpFailure`, so the
    exclusion is a type fact;
  - `Budget` and `BudgetV4` as one record with `Maybe (Map Name Natural)` is tempting. Keep them distinct so the v3
    vs v4 authoring choice stays explicit, matching Python.
- `Timeline` holds `(World, GenerationId)`. Staleness remains a runtime check because generations are revoked
  dynamically. A rank-2 brand per generation would be overkill.
- **Exceptions vs results:** internally, return `Either WorldFailure a` from each step and rethrow only at the
  `Timeline` facade. That keeps "only World-originated failures are captured" explicit:
  `BudgetExhausted` / `InvariantViolation` are values, while profile exceptions are real exceptions.
- **Quirks to preserve exactly:**
  - Python `repr` spellings in error strings;
  - the exhaustion check order (timer_advances → logical_instant → actions in `_step`; actions → predicate_polls in
    `_observe`; reloads → actions in `_restart`; total queued_commands before per-item checks in `_enqueue_all`);
  - checker sequence `0` at create;
  - crash checks captured before drop but journaled after the crash and resource entries;
  - `resource` entries take generation `null` after a crash;
  - restart enqueues follow-ups before its operation exists, so a queue overflow during load is
    `accepted_operations=0` with a live generation;
  - `artifact()` emits only v3 or v4.
- A Haskell `World` can be pure: a `State` machine over `WorldState` with profile effects in `IO`. Exact replay is
  then easy to property-test: for any generated script, `replay(artifact(run(script)))` passes. That is the core
  property worth adding.
- **Process runner:** use `bracket` to guarantee reaping, and `Control.Concurrent.Async.race` (`async`) for the
  wall deadline instead of polling.

#### 8. Packaging

- New package `petrus-dst` (module `Petrus.Testing.Dst`, plus `Petrus.Testing.Dst.Runner`).
- Dependencies: `petrus-json`, `crypton` or `cryptohash-sha256`, `containers`, `text`, `bytestring`, `process`,
  `unix`, `temporary`, `async`, `directory`, `filepath`.
- **No dependency on any Petrus runtime package**, mirroring `rules/testing-dst-boundary.yml`.
- The kernel can be built **now**, in parallel with everything else.
- Profiles and checkers are test code, in a `petrus-dst-profiles` test suite or internal library that depends on
  the engine, history stores (JSONL first), and dispatch (InMemory and Local/SQLite). They come after those ports.
  The joined profiles depend on the Postgres history store and the Absurd provider.

### Project tests and test infrastructure (`tests/project`, `conftest.py`, `scripts/`, `rules/`)

#### 1. Responsibility & public API (what each check enforces)

| File (functions) | Checks | Haskell analogue |
| --- | --- | --- |
| `tests/project/test_conventions.py` (4) | (a) every `src/petrus/**/*.py` is listed in some `rules/*.yml` `files:` glob or in `STRUCTURAL_RULE_EXEMPTIONS` (`__init__.py`, `telemetry.py`); (b) the concept rules name their canonical forbidden dependencies; (c) `ast-grep scan` is clean; (d) `ast-grep test --skip-snapshot-tests` passes over `rule-tests/` (19 rule tests). | **Package boundaries via cabal `build-depends`** (strongest; a missing dependency is a compile error). For intra-package module boundaries, use either HLint `modules:` restrictions (`- {name: [Petrus.Engine.*], within: [...]}`) or a small test that parses each module's `import` lines against an allowlist per module glob. Keep the coverage test that every module is matched by a rule or exempted. `ast-grep` supports Haskell through tree-sitter and could be reused (`language: haskell`). |
| `test_package_boundaries.py` (20) | Python import hygiene: lazy root facade, no root re-exports or removed names, defining-module imports, and optional extras (psycopg, absurd-sdk, pyzmq) not loaded by base imports (`BlockPsycopg`/`BlockAbsurdExtra`/`BlockZeroMQExtra` meta-path finders); Engine canonical and optional-dependency safe; worker CLI contract; CV5 demos use only public Engine doors. | Mostly **N/A**, because Haskell has no lazy imports or runtime extras. Replacements: put optional drivers in **separate packages** (`petrus-history-postgres`, `petrus-dispatch-absurd`, `petrus-transport-zeromq`), and add a `cabal-plan`-based test asserting that the transitive dependency closure of `petrus-impetus` / `petrus-engine` excludes `postgresql-libpq`, `zeromq4-haskell`, etc. Use explicit export lists, with no re-export of removed names, checked by a doctest-style "exports" golden. |
| `test_check_command.py` (3) | `scripts/check` is valid bash and its help lists `quick/full/release/mutation`; it pins `UV_FROZEN=1`, the `flock` on `/tmp/petrus-check-full.lock`, `-n 4 --dist loadscope`, `--basetemp=/tmp/petrus-check`, and `--durations=20 --durations-min=0.5`; profiles reject paths (exit 2); an unknown profile prints usage (exit 2). | This repo's `scripts/check-all` / `check-parity` / `check-pins` can get an analogous self-test (shellcheck plus `--help` text). Optional. |
| `test_distribution.py` (1) | Builds sdist and wheel and checks them: no `.git`, `__pycache__`, `.db`/`.key`/`.sqlite*`/`.pyc`, `.env*`, or absolute or `..` paths; exact sdist top-level set; `gondolin_sidecar.mjs` shipped; `twine check`. | `cabal sdist` for each package, then inspect the tarball (same forbidden-member rules; `extra-source-files` include any non-Haskell helper such as the Gondolin sidecar), plus `cabal check`. |
| `test_exploration_identity.py` (1) | Upstream docs: ES-NNN exploration codes are contiguous. | N/A (upstream process docs). |
| `test_release_command.py` (1; 14 parametrized cases) | `scripts/check-release.py` enforces the 0.x PEP 440 policy, tag `v<version>`, prerelease flag, and no draft, from `GITHUB_EVENT_PATH`. | Later: a Hackage release guard (PVP version ↔ tag). Not needed for parity. |

#### 2. Wire formats, durable schemas, protocols (test harness)

**`conftest.py`:**

- `POSTGRES_IMAGE = "postgres:17.5-alpine@sha256:6567bca8d7bc8c82c5922425a0baee57be8402df92bae5eacad5f01ae9544daa"`
  (`conftest.py:27`).
- Label: `petrus-cv3-test`, with `-<worker>` appended for xdist workers other than `main`/`gw0`.
- Container `petrus-cv3-postgres-<worker>-<pid>`, started with
  `docker run --rm --detach --name … --label … --publish 127.0.0.1::5432 --env POSTGRES_PASSWORD=postgres --tmpfs /var/lib/postgresql/data <image>`.
- Port discovery via `docker port <name> 5432/tcp`.
- Readiness:
  1. `docker exec <name> pg_isready -U postgres`, polled every 0.2 s against a 60 s deadline;
  2. then `psycopg.connect(dsn, connect_timeout=3)` from the host, polled the same way.
- DSN: `postgres://postgres:postgres@127.0.0.1:<port>/postgres`.
- Stale containers carrying the label are force-removed first.
- If Docker is absent, the run **fails** (`pytest.fail`) rather than skipping.
- Fixtures:
  - `postgres_dsn` (session);
  - `absurd_dsn` (session; autocommit; `ensure_schema` + `ensure_absurd_schema`);
  - `pg_connection` (function; autocommit connection plus `ensure_schema`).
- `--forbid-skips` (35-57): any skipped node turns an OK exit into `TESTS_FAILED` and lists the skipped node ids.

**`pyproject.toml` `[tool.pytest.ini_options]`:**

- `addopts = "--randomly-seed=1729"`, from pytest-randomly. It shuffles order deterministically and reseeds
  `random`, factory_boy, Faker and NumPy per test. It does not seed Hypothesis: a test without
  `derandomize=True` draws fresh examples on every run (Hypothesis seeds it from OS entropy), and only the
  tests that set `derandomize=True` draw the same examples every time.
- `testpaths = ["tests"]`, `timeout = 180` (pytest-timeout, per test).
- Markers: `real_provider_acceptance`, `real_gondolin_acceptance`, `qualification_installation`.
  - They are **not** deselected by default. `scripts/check` passes `-m "not real_provider_acceptance and not
    real_gondolin_acceptance and not qualification_installation"` (`scripts/check:8`). A bare `pytest` would run
    them.
  - Users: `motus/test_private_execution_substrate.py:695`, `test_gondolin_environment.py:788`,
    `agenticus/runtime/test_{codex,amp,pi,claude,agent_net}_real.py`, `test_pi_application.py`,
    `test_pi_model_phase.py`.

**`scripts/check`:**

- `quick`: `ruff check`, `ruff format --check`, `ty check src/petrus`, `ast-grep scan`.
- `full`: quick, then `pytest -q -n 4 --dist loadscope --basetemp=/tmp/petrus-check --durations=20
  --durations-min=0.5 --forbid-skips -m "$ROUTINE_TESTS"` under `flock /tmp/petrus-check-full.lock` (pytest-xdist).
- `release`: full, then one serial run with `--randomly-seed=20260724`.
- `mutation`: `mutmut run` on `petrus.impetus.selection.x_fold_history*`, `x__cursor*`, and `marking.xǁTokenQueueǁ*`
  with `--max-children 1`.
  - `[tool.mutmut]`: `only_mutate` = `petrus/impetus/petrinet/marking.py` and `petrus/impetus/selection/__init__.py`.
  - Tests: `tests/petrus/impetus/selection/test_selection.py` and `tests/petrus/impetus/petrinet/test_token_queue.py`.
  - `timeout_multiplier = 5`, `timeout_constant = 0.2`.
  - Reporting only, not a gate.

**Other scripts:**

- `scripts/gen-golden-traces.py` generates `spec/traces/*`, the golden replay corpus consumed by `tests/harness.py`.
  That corpus is interop-relevant and owned by the kernel (history/instance) port.
- `scripts/check-release.py` is the release guard.
- `scripts/cv5-*-demo.py` are host demos, constrained by `test_package_boundaries`.

**`rules/` (36 ast-grep YAML rules) + `sgconfig.yml` + `rule-tests/` (19):**

- Each rule is `language: python`, `severity: error`, a `files:` glob, and `import_statement` /
  `import_from_statement` regexes for forbidden modules.
- Together they encode the layer graph. Examples:
  - `petrinet-is-independent` forbids history, history_store, instance, dispatch, execution, binding,
    `_coordination`, fabric, processes, absurd, and worker;
  - `core-no-runtime-imports`;
  - `activity-is-a-leaf`;
  - `binding-dependencies` allows only Petrinet, activity, and celpy;
  - `dsl-boundary`;
  - `testing-dst-boundary`, which forbids importing any `petrus`;
  - `worker-is-activity-dispatch-only`;
  - the engine/provider/fabric/processes boundaries.
- The Haskell package and module graph should be derived from these rules. They are the most precise statement of
  upstream's intended dependency DAG.

#### 3. Concurrency & durability semantics (test runs)

- Parallelism is xdist with 4 processes, distributed by module/class (`loadscope`), and one Postgres container per
  worker. Session fixtures are per worker process.
- `flock` prevents concurrent full runs from stealing each other's labeled containers or basetemp.
- The 180 s per-test timeout uses pytest-timeout's signal method by default on POSIX.
- Haskell suites run in one process with GHC threads. Recommendations:
  - one container per test-suite process (a tasty `withResource` or hspec `aroundAll`);
  - **per-test databases** (`CREATE DATABASE t_<n> TEMPLATE …`) or per-test schemas for isolation under
    `-j`/`parallel`;
  - the same label-based stale cleanup and the same pinned digest.

#### 4. External dependencies (test tooling → Haskell)

| Python tool | Role | Haskell option |
| --- | --- | --- |
| pytest + markers | runner, opt-in suites | **tasty** (`tasty-hunit`, `tasty-hedgehog`, `tasty-golden`; `--pattern` / `-p '!/real_provider/'` for opt-in groups; built-in `--timeout`) or **hspec** (`--match`/`--skip`, `--randomize --seed 1729`, `--fail-on=pending,empty`) |
| `--forbid-skips` | no silent skips | hspec `--fail-on=pending`. tasty has no skip concept; require opt-in groups to be excluded by pattern, never skipped at runtime. Docker absence must fail. |
| pytest-randomly seed 1729 | order randomization plus RNG seeding (not of Hypothesis) | hspec `--randomize --seed 1729` for order; a property keeps QuickCheck's or Hedgehog's per-run seed unless its upstream test sets `derandomize=True`, and then fixes one. tasty has no order randomization, which is acceptable. |
| pytest-timeout 180 | per-test cap | tasty `--timeout 180s`; hspec: wrap with `System.Timeout.timeout`. |
| pytest-xdist `-n 4 --dist loadscope` | parallel | tasty `-j4` / hspec `parallel` plus `+RTS -N4` |
| hypothesis | properties, state machines | hedgehog (state machines), QuickCheck, falsify |
| mutmut | mutation report | **Gap:** no maintained Haskell mutation tool (MuCheck and similar are unmaintained). Skip, or write a bespoke source-mutation script for the two curated modules. Not a release gate upstream either. |
| ruff / ty | lint, types | `-Wall -Werror` (GHC), HLint, fourmolu/ormolu `--mode check` |
| ast-grep | import rules | cabal dependency graph, HLint module restrictions, or ast-grep with tree-sitter-haskell |
| docker CLI | Postgres provisioning | `typed-process` calling `docker` (same flags), or `testcontainers` for Haskell (it exists, but the upstream deliberately avoids testcontainers, so prefer the docker-CLI clone) |
| psycopg (readiness) | connect probe | `postgresql-libpq` `connectdb` loop with `connect_timeout=3` in the conninfo |

#### 5. Upstream tests

`tests/project/` holds 30 test functions: conventions 4, package boundaries 20, check command 3, distribution 1,
exploration 1, release 1×14. Requirements:

- `test_distribution` needs `build` and `twine`, from the dev group.
- `test_conventions` needs the `ast-grep` binary.
- None need Docker or credentials.

#### 6. Performance

Not applicable beyond keeping the gate fast. Upstream records `--durations=20` to watch slow nodes. Mirror it with
tasty's `--hide-successes` plus timing output, or hspec `--times`.

#### 7. Better-the-Haskell-way suggestions

- Make the dependency DAG a build fact: one cabal package per upstream boundary family. Each `rules/*.yml` allowlist
  becomes a `build-depends` list. Only intra-package rules need a lint.
- Keep the "no silent skip" posture: the Postgres suite errors loudly when Docker is unavailable, and opt-in
  real-provider suites are separate test-suite **components** or flags (`cabal test petrus-agenticus:real-provider`),
  so they are never skipped at runtime.
- Pin the Postgres image by digest in one Haskell constant shared by every suite, and assert it in a test against
  the upstream `conftest.py` pin, so re-pins are deliberate.

#### 8. Packaging

- A small internal library `petrus-test-support` (Docker Postgres resource, `--forbid-skips`-equivalent policy,
  shared golden/fixture loaders pointing at `upstream/petrus/tests/**` and `spec/**`, without copying them).
  Every package's test suite can depend on it.
- It can be built now. Its Postgres resource is needed before any Postgres-backed component tests run.

## 11. Agenticus core

### Agenticus core: architecture overview (everything except `agenticus/runtime/`)

All paths below are relative to `upstream/petrus`. Agenticus is a Petrus-level
*composition* subsystem over Impetus and Motus (decision
`docs/project/decisions/records/2026-08-03T0430Z-installations-own-authority-agenticus-owns-machinery.md`):
the host installation owns authority instances, enablement, and policy; Agenticus owns the
reusable machinery. There is **no spec/*.md for Agenticus**; the normative artifacts are the
source, the two conformance fixtures under `tests/petrus/agenticus/conformance/`, and the
glossary (`docs/project/glossary/agenticus.md`, `episode-attachment.md`, `continuation.md`).
Related decisions: `2026-08-05T0923Z-net-owned-pi-loop-mirrors-a-bounded-public-seam.md`,
`2026-08-09T1400Z-episode-owns-independent-execution-territory.md`.

#### Package map and dependency direction

| Subpackage | Modules | Role | Imports from Petrus |
|---|---|---|---|
| `catalog` | `descriptor`, `result`, `resolution` | Capability descriptors, compatibility results, host Catalog + immutable `ResolutionSnapshot` | none |
| `thread` | `identity`, `continuation`, `lifecycle` | `ThreadId/ContinuationId/EpisodeId/TurnId`, opaque Continuation custody, pure Thread/Episode/Turn state machine | `catalog`, `program.descriptor` |
| `program` | `descriptor`, `seam`, `agent_net` | Agent Program ownership descriptors; steering/evaluator seams; the static **Agent-as-Net** Petri net | `catalog`, `thread`, `hands.contract`, `impetus.{binding,dsl,petrinet}`, `motus.activity` |
| `connection` | `key`, `materialization`, `storage`, `custody` | Agent Connection (provider credential) custody: SQLite CAS store, host enrollment, leases, fencing, private-file materialization | none (stdlib only) |
| `hands` | `contract`, `grants`, `gateway`, `workspace`, `conformance` | Capability-scoped workspace tool protocol v1, grants, the single gateway, Motus workspace adapter, ES-049 policy | `catalog`, `motus.execution` (workspace only) |
| `attachment` | `binding`, `episode`, `_retention` | Episode Attachment over one Motus territory lease, ordered settlement, retained-territory SQLite custody | `catalog`, `connection.custody`, `hands`, `thread`, `motus.execution`(+`.archive`) |
| `effect` | `model`, `gateway` | Provider-neutral external Effect proposal/fence/receipt/decision values; lookup-first gateway | none |

Every `__init__.py` is exactly `__all__ = []` (enforced by `tests/petrus/agenticus/test_boundaries.py:39-50`).
Impetus and Motus must never import Agenticus (`test_boundaries.py:68-73`); Agenticus must never import
`petrus.motus._execution*` (`:76-82`); no class/function named `Agent` or `Session` (`:85-94`); importing
the root must not pull `anthropic`, `claude_agent_sdk`, `e2b`, `openai` (`:53-65`). The Motus Worker must not
import `attachment._retention` (`tests/project/test_package_boundaries.py:186-189`).

#### How the pieces compose (one Episode, end to end)

```
Host Catalog ──register/enable──► resolve(ResolutionRequest) ─► ResolutionSnapshot (immutable, kinds ≤1 each, runtime required)
     │                                                                  │ must select HANDS + TERRITORY
Thread (pure value) ─start_episode(program, runtime, budget)─► Episode ─start_turn/accept_append/settle_turn/settle
     │   (Continuation claim → in-use → retired; next_continuation published at settle)
     ▼
AgentConnectionCustody (SQLite CAS)  ─materialize(conn, host, mode, ttl)─►  Materialization{fence, home=<root>/<attachment-id>.state}
     │  AttachmentFence ──► CustodyResultAdmission (Hands ResultAdmission seam) / admit_effect
     ▼
EpisodeAttachment(episode_id, snapshot, binding=MotusAttachmentBinding(EnvironmentProvider lease), attachment_id, epoch, deadline)
     ├─ GrantLedger (per attachment epoch) ─open()─► CapabilityGrant(grant_epoch++)
     ├─ gateway(MotusWorkspaceAdapter) ─► HandsGateway.submit(v1 envelope) ─► ToolResult (model sees to_model_data())
     ├─ settle(): close admission → drain gateways → discard stages → export tar (≤512 MiB) → binding.settle() (destroy lease) → AttachmentSettlement
     ├─ successor(...) at epoch+1 (only after verified cleanup)
     └─ _release_to(SqliteTerritoryCustody ticket) → retained lease → reclaim(...) into a distinct Episode at epoch+1 → retire()
Program "agenticus.net-owned": static Net agent-as-net, run by petrus.engine.Engine; two Activity transitions
     model_phase → Activity "agenticus.net.model-phase" ; execute_tool → Activity "agenticus.net.hands"
     (implementations live in agenticus/runtime: agent_net_runner.py, pi_model_phase.py — section 12)
EffectGateway (host side): EffectProposal + host EffectDecision.approve(fence) → lookup-first, fresh fence, execute once
     EffectFence carries (authority_epoch from custody, target_head from host, episode/attachment coordinates from EpisodeAttachment.coordinates())
```

* **Motus Activities/Dispatch**: only `program/agent_net.py` touches them: `_ModelActivity.prepare` and
  `_HandsActivity.prepare` return `motus.activity.ActivityInvocation(activity, input=...)`
  (`src/petrus/agenticus/program/agent_net.py:460-490`); the Engine's dispatch (e.g. `motus.dispatch.InlineDispatch`
  in tests, Worker/ZeroMQ in production via the runtime) executes them and their JSON results are recorded in
  canonical History as `ActivityRequested`/`ActivityCompleted` (`tests/petrus/agenticus/program/test_agent_net.py:451-473`).
* **Motus execution (territory)**: `attachment/binding.py`, `attachment/_retention.py`, `hands/workspace.py` use only the
  public `petrus.motus.execution` contract: `EnvironmentProvider.{create,lookup,attach,execute,export,cancel,destroy}`,
  `EnvironmentLease`, `LeaseIdentity(operation_id, provider, lease_id)`, `ExecutionAttachment`, `Command`, `CommandResult`
  (with `provenance.identity`, `timed_out`, `superseded`, `output_truncated`), `CleanupResult(identity, disposition, detail)`
  with `verified ⇔ disposition ∈ {clean, not-created}`, `LeaseState{ready,terminal,uncertain}`,
  `CleanupDisposition{clean,not-created,unverified}` (`src/petrus/motus/execution/__init__.py:43-137,355-403`) and
  `MAX_WORKSPACE_ARCHIVE_BYTES = 512*1024*1024` (`src/petrus/motus/execution/archive.py:7-9`,
  `src/petrus/motus/_execution/artifacts.py:14`).
* **Canonical History**: Agenticus never writes History directly and must not read Timeline as authority. The only
  History-visible Agenticus bytes are the Agent-as-Net token data and activity inputs/results (see Program).
  Other durable state lives in two **separate private SQLite files** (connection custody; territory custody) — never
  in History.

#### Shared validation primitives (must be replicated bit-for-bit)

| Rule (Python) | Where | Exact semantics |
|---|---|---|
| bounded identity text `_text` | `catalog/descriptor.py:13-22`, `thread/identity.py:11-20`, `effect/model.py:17-26`, `connection/custody.py:885-894`, `attachment/binding.py:41-50`, `hands/grants.py:26-35` | `str`, non-empty, `value == value.strip()` (**Python `str.strip()` Unicode whitespace**, incl. U+0085/U+00A0/U+2000..), UTF-8 length ≤ 256 **bytes**, no code point < 32 (DEL 0x7f allowed) |
| positive integer | everywhere | `type(v) is int and v > 0` — JSON `true`, `1.0`, `1e0` are rejected (Python decodes them as bool/float) |
| exact object | `catalog/descriptor.py:31-37`, `effect/model.py:48-51`, `program/agent_net.py:93-98` | key set must equal the field set exactly (no extras, no missing) |
| capability key set | `catalog/descriptor.py:40-47` | iterable (not a bare string) of `_text` items; duplicates rejected; stored as set; emitted **sorted** |
| Hands bounds | `hands/contract.py:144-151` | counted in **code points** (`len(str)`), not bytes; control < 32 or 0x7f rejected |
| agent_net JSON bound | `program/agent_net.py:83-90` | `json.dumps(v, allow_nan=False, separators=(",",":"))` with default **`ensure_ascii=True`**, UTF-8 length ≤ 4096 (non-ASCII counts 6 bytes per BMP char, 12 per astral char) |

All sorts are Python `str` ordering = Unicode code-point order (Haskell `Text` `Ord` in text≥2 matches).

---

### Catalog (`catalog/descriptor.py`, `catalog/result.py`, `catalog/resolution.py`)

#### 1. Responsibility & public API

Host-local registry of exact component identities, plus deterministic compatibility checking of one exact
per-Episode selection. Catalog *validates* a plan; it never searches for or substitutes a provider/account/runtime/
territory/continuation (`resolution.py:76-83`).

* `DescriptorKind(StrEnum)`: `connection | program | runtime | hands | territory | continuation | effect` (`descriptor.py:50-59`).
* `DescriptorIdentity(kind, name, contract_version)` frozen, `order=True` (`descriptor.py:62-102`): `name` `_text`, version positive int.
* `CompatibilityRequirement(kind, name: str|None, contract_version, capabilities: frozenset[str])` (`descriptor.py:105-156`).
* `CapabilityDescriptor(identity, offers: frozenset[str], requires: tuple[CompatibilityRequirement,...]=())`
  (`descriptor.py:159-202`): duplicate requirements rejected; `requires` sorted by
  `(kind.value, name or "", contract_version, tuple(sorted(capabilities)))` (`descriptor.py:205-211`).
* `CompatibilityIssue(code: str, subject: str)` frozen ordered; both `_text` (**code is open text, not the enum**) (`result.py:12-36`).
* `CompatibilityResult(candidate: DescriptorIdentity|None, issues=())` (`result.py:39-85`): duplicates rejected; issues
  sorted by `(code, subject)`; `candidate is None and not issues` rejected; `compatible ⇔ candidate is not None and not issues`.
* `CompatibilityIssueCode` (emitted vocabulary, `resolution.py:21-31`): `not-registered, not-enabled, missing-selection,
  selection-not-registered, selection-not-enabled, name-mismatch, version-mismatch, missing-capability`.
* Errors: `CatalogRegistrationError(ValueError)` ⊃ `DuplicateRegistrationError`, `AmbiguousRegistrationError`;
  `UnknownRegistrationError(LookupError)`; `SelectionError(ValueError)` ⊃ `DuplicateSelectionError`, `AmbiguousSelectionError` (`:34-59`).
* `CatalogEntry(descriptor, enabled: bool)`; `ResolutionRequest(selections)` — no duplicate identity, ≤1 per kind,
  RUNTIME mandatory, stored sorted by `(kind.value, name, version)` (`:76-98`).
* `ResolutionSnapshot(catalog_revision ≥ 0, descriptors)` — unique identities, ≤1 per kind, runtime mandatory, sorted;
  `descriptor(kind) -> CapabilityDescriptor|None` (`:101-157`).
* `Resolution(request, results, snapshot)` — results align 1:1 with sorted selections; snapshot exists iff all compatible (`:160-190`).
* `Catalog` (`:193-275`): `revision` (starts 0, +1 on register and on every *effective* enable/disable), `register(d)`
  (always disabled; same envelope → Duplicate, different envelope same identity → Ambiguous; also refuses descriptors whose
  same-kind requirements disagree on version or on non-null name, `:286-299`), `enable(id)`, `disable(id)`
  (unknown → `UnknownRegistrationError`), `inspect()` (sorted), `resolve(request)`.
* Resolution algorithm (`:302-347`): for each selected identity: unregistered → `not-registered(name)`; else
  disabled → `not-enabled(name)`; for each requirement of its descriptor: no selection of that kind →
  `missing-selection(kind.value)` (stop); name set and differs → `name-mismatch(requirement.name)`; version differs →
  `version-mismatch("<kind>@<required version>")`; selected identity unregistered → `selection-not-registered(selected.name)` (stop);
  disabled → `selection-not-enabled(selected.name)`; each `capability ∈ required − offers` → `missing-capability(capability)`.
  Issues are a set, then sorted. Snapshot captures `catalog_revision` at lock time and the registered descriptors.

Kernel APIs used: none.

#### 2. Wire formats (JSON; field order = Python insertion order shown)

`CapabilityDescriptor.to_data()` (`descriptor.py:178-184`), conformance fixture
`tests/petrus/agenticus/conformance/catalog-descriptor-v1.json` (verbatim case payload):

```json
{"schema_version": 1,
 "identity": {"kind": "runtime", "name": "pi.application-owned", "contract_version": 1},
 "offers": ["continuation.opaque", "program.harness-owned"],
 "requires": [
   {"kind": "connection", "name": null, "contract_version": 1, "capabilities": ["authority.materialize"]},
   {"kind": "hands", "name": null, "contract_version": 1, "capabilities": ["workspace.read", "workspace.write"]}]}
```

Fixture envelope (both files): `{"format": "petrus.agenticus.conformance", "version": 1, "contract": "catalog.descriptor"|"catalog.result", "cases": [...]}`;
descriptor cases are `{"name", "descriptor"}`; result cases are `{"name", "compatible": bool, "result"}`.
`CompatibilityResult.to_data()` (`result.py:62-67`) and fixture `catalog-result-v1.json` cases:

```json
{"name": "compatible-candidate", "compatible": true,
 "result": {"schema_version": 1, "candidate": {"kind": "runtime", "name": "pi.application-owned", "contract_version": 1}, "issues": []}}
{"name": "blocked-candidate", "compatible": false,
 "result": {"schema_version": 1, "candidate": {...same...},
            "issues": [{"code": "missing-capability", "subject": "workspace.write"}, {"code": "version-mismatch", "subject": "hands"}]}}
{"name": "no-candidate", "compatible": false,
 "result": {"schema_version": 1, "candidate": null, "issues": [{"code": "no-candidate", "subject": "runtime"}]}}
```

Interop-critical quirks: the fixture uses code `no-candidate` (not in `CompatibilityIssueCode`) and subject `"hands"` for
`version-mismatch` whereas `Catalog` emits `"hands@1"` — the decoder must accept any `_text` code/subject. Decoders accept
`offers`/`issues`/`requires`/`descriptors` in any order and re-sort; `to_data(from_data(x)) == x` holds only for canonical input.
`ResolutionSnapshot.to_data()` = `{"schema_version": 1, "catalog_revision": n, "descriptors": [CapabilityDescriptor...]}` (`resolution.py:133-138`).
Decoders: `schema_version` must be int 1; `contract_version`/`catalog_revision` must be JSON integers (bool rejected);
`kind` must be a known kind; arrays must be JSON arrays (`TypeError` otherwise).

#### 3. Concurrency & durability

In-memory only; one `RLock` guards `_entries`/`_revision`; `resolve` copies entries+revision under the lock then computes
outside it (`resolution.py:256-267`). Snapshots are immutable and unaffected by later enable/disable
(`test_resolution.py:236-256`). Nothing is persisted by Catalog itself (runtime persists snapshots inside its own records).

#### 4. External dependencies

None. Haskell: `containers` (`Map`, `Set`), `text`, `petrus-json` for decode/encode fidelity (int vs float, key order).

#### 5. Upstream tests

* `tests/petrus/agenticus/catalog/test_descriptor.py` — 5 functions (8 cases: one 4-way parametrize): fixture round-trips,
  normalization/immutability, decoder refusals (extra key, schema 2, bool version, duplicate offer), result requires candidate.
* `tests/petrus/agenticus/catalog/test_resolution.py` — 13 functions: disabled-by-default/exact enablement, duplicate vs
  conflicting registration without mutation, impossible same-kind requirements (2 cases), compatible same-kind requirements,
  duplicate/ambiguous selections, full issue vocabulary in stable order, no substitution, snapshot immutability, snapshot decoder
  (4 cases), **hypothesis** order-determinism (`max_examples=40`, permutations of 7), and 2× parametrized over
  `petrus.agenticus.runtime.profiles.RUNTIME_PROFILES` (depends on the runtime package), inspection permutation canonicality.
  No Docker/network.

#### 6. Performance

Trivial; hot path is `resolve` (O(selections × requirements × capabilities)). Benchmark: 1 000 registered descriptors,
7-kind request with 5 requirements × 10 capabilities, 100k resolves; plus `from_data/to_data` of the snapshot. Python
baseline via `timeit` on the same synthetic set.

#### 7. Better the Haskell way

* `ResolutionRequest` as a record `{runtime :: Identity 'Runtime, connection :: Maybe (Identity 'Connection), ...}` —
  "≤1 per kind, runtime required" becomes unrepresentable-if-invalid; keep a JSON/array view for ordering.
* `CompatibilityResult = Compatible Identity | Blocked (Maybe Identity) (NESet Issue)`; keep `code` as `Text` (fixture requires open codes)
  with a separate closed `IssueCode` for the emitter.
* Catalog as an `IORef`/`TVar` of a pure `CatalogState`; `resolve` pure over a snapshot.
* Preserve: `version-mismatch` subject format `kind@version`, revision increments only on effective changes.

#### 8. Packaging

`petrus-agenticus` (pure core layer: `Petrus.Agenticus.Catalog.{Descriptor,Result,Resolution}`). Depends only on
`petrus-json`. Can be built immediately, in parallel with the kernel.

---

### Connection custody (`connection/key.py`, `materialization.py`, `storage.py`, `custody.py`)

#### 1. Responsibility & public API

Installation-owned custody of provider-native opaque credential state ("Agent Connection"): encrypted at rest by
host-supplied key operations, materialized as a private 0600 file for exactly one leased attachment, fenced against stale
writers by host enrollment epochs, authority epochs and state versions, with an append-only secret-free audit log inside
the same CAS document. Agenticus never sees key material.

* Key boundary (`key.py`): `KeyContext(connection_id, authority_epoch>0, state_version>0)` with
  `authenticated_data() = b"petrus-agenticus-connection/v1\0" + connection_id + b"\0" + str(authority_epoch) + b"\0" + str(state_version)`
  (UTF-8; `key.py:29-32`). `KeyOperations` protocol: `seal(ctx, plaintext: bytearray) -> bytes`,
  `open(ctx, ciphertext) -> bytearray`, `erase(connection_id) -> KeyErasureEvidence(connection_id, erased=True)`.
  `KeyOperationError`. Ciphertext format is **host-defined** (test uses AES-GCM `nonce(12, big-endian counter) || ct||tag`
  with the AAD above, `tests/petrus/agenticus/connection/test_custody.py:60-92`).
* Materialization (`materialization.py`): `PrivateFileMaterializer(root)`; `materialize(attachment_id, plaintext) -> MaterializedState`;
  `read`, `replace(non-empty bytes)`, `cleanup(attachment_id) -> CleanupEvidence`, `summarize(ids) -> CleanupSummary`.
  `CleanupEvidence(attachment_id, removed, already_absent, bytes_overwritten, physical_erasure_guaranteed=False, security_violation=False)`,
  `CleanupSummary(attempted, removed, already_absent, unresolved, security_violations, physical_erasure_guaranteed=False)`.
  `MaterializedState.path` (only for the provider runtime), `.erased`, `.read()`, `.replace()`; repr hides path/bytes.
* Storage (`storage.py`): `StoredHost(host_id, enrollment_epoch, active)`, `StoredConnection(connection_id, provider,
  account_fingerprint, profile, status, authority_epoch, state_version, encrypted_state: bytes|None, state_digest: str|None)`,
  `StoredLease(lease_id, attachment_id, connection_id, host_id, host_epoch, mode, authority_epoch, base_version, expires_at: float,
  activated=False, released=False, release_reason=None)`, `AuditRecord(sequence, operation_id, event_kind, connection_id?, host_id?,
  lease_id?, details: tuple[(str, str|int|float|bool|None)])`, `StorageSnapshot(revision, hosts, connections, leases, audit)`.
  `ConnectionStorage` protocol: `load() -> StorageSnapshot`, `compare_and_swap(expected_revision, replacement) -> bool`, `close()`.
  `SqliteConnectionStorage(path)`; `validate_snapshot(s)`; `StorageError`, `StorageSecurityError`.
* Custody (`custody.py`): `LeaseMode{read, refresh}`, `ConnectionStatus{ready, refreshing, revoked, erasure_pending,
  reauthorization_required}`; errors `CustodyError(RuntimeError)` ⊃ `HostNotEnrolled, LeaseConflict, StaleCustody,
  StaleAttachment, ReauthorizationRequired, OperationConflict, StorageContention`. `OpaqueState(bytes)` (erasable buffer,
  `erase()` zeroes). Values: `ConnectionIdentity(connection_id, provider, account_fingerprint, profile)`,
  `ConnectionView(identity, status, authority_epoch, state_version, state_digest)`,
  `AttachmentFence(attachment_id, lease_id, connection_id, host_id, host_epoch, authority_epoch, base_version)`,
  `Materialization(fence, mode, expires_at, home)`, result records (`PublicationResult`, `ReleaseResult`, `RenewalResult`,
  `HostRemoval(..., offline_erasure_limit=True)`, `RevocationResult(..., provider_revocation="not_claimed", offline_erasure_limit=True)`,
  `ErasureResult(..., physical_media_erasure_guaranteed=False)`, `RecoveryResult`, `AdmissionResult(operation_id, purpose, attachment_id)`,
  `OperationView`). `AgentConnectionCustody(storage, keys, materializer, *, clock)` methods (all take keyword `operation_id`):
  `enroll_host`, `remove_host`, `authorize(identity, OpaqueState)`, `materialize(connection_id, host_id, *, mode, ttl)`,
  `activate(m)`, `renew(m, *, ttl)`, `checkpoint(m)`, `release(m)`, `rotate(connection_id, OpaqueState)`, `revoke`, `erase`,
  `admit_result(fence)`, `admit_effect(fence)`, `connection(id) -> ConnectionView`, `recover()`, `lookup_operation(op) -> OperationView|None`,
  `audit_records()`, `close()`.

Kernel APIs used: none.

#### 2. Durable schema and formats

**SQLite file** (path chosen by host; tests use `<installation>/connections.sqlite3`), `storage.py:121-141`:

```sql
PRAGMA journal_mode = DELETE
PRAGMA synchronous = FULL
CREATE TABLE IF NOT EXISTS connection_custody (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    revision INTEGER NOT NULL,
    payload TEXT NOT NULL
)
INSERT OR IGNORE INTO connection_custody (singleton, revision, payload) VALUES (1, 0, ?)
SELECT revision, payload FROM connection_custody WHERE singleton = 1
BEGIN IMMEDIATE
UPDATE connection_custody SET revision = ?, payload = ?
WHERE singleton = 1 AND revision = ?
```

Connection opened with `isolation_level=None` (autocommit), `check_same_thread=False`, `timeout=5` (busy timeout 5 s); CAS =
`BEGIN IMMEDIATE` + conditional UPDATE, rowcount ≠ 1 → `ROLLBACK`, `False` (`storage.py:156-178`). `load` refuses
`payload.revision != column revision`. Filesystem: parent dir must be non-symlink, created `0700`, mode exactly `0700`;
file created `O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW` mode `0600` + `fchmod 0600`, then `os.chmod(path, 0o600)` after connect;
must be a regular non-symlink file with mode exactly `0600` (`storage.py:184-228`). (`-journal` file is transient in DELETE mode.)

**Payload JSON** (`storage.py:409-470`): `json.dumps(data, sort_keys=True, separators=(",", ":"), allow_nan=False)` with
default `ensure_ascii=True`, no trailing newline. Keys therefore appear sorted. Empty initial payload, byte-exact:

```json
{"audit":[],"connections":[],"hosts":[],"leases":[],"revision":0,"schema_version":1}
```

Object shapes (keys emitted sorted):

| Array | Element keys | Encoding notes |
|---|---|---|
| `hosts` | `active` bool, `enrollment_epoch` int>0, `host_id` | sorted by `host_id` |
| `connections` | `account_fingerprint`, `authority_epoch`, `connection_id`, `encrypted_state` (standard **base64 with padding** string or `null`), `profile`, `provider`, `state_digest` (lowercase hex SHA-256 of the *ciphertext*, or `null`), `state_version`, `status` | sorted by `connection_id` |
| `leases` | `activated`, `attachment_id`, `authority_epoch`, `base_version`, `connection_id`, `expires_at` (**Python float repr**, e.g. `1060.0`, `1e+16`), `host_epoch`, `host_id`, `lease_id`, `mode` (`read`/`refresh`), `release_reason` (`null` or one of `host_reenrolled, host_removed, checkpointed, released, connection_revoked, connection_erased, authority_rotated, expired, materialization_failed`), `released` | sorted by `lease_id` |
| `audit` | `connection_id`/`host_id`/`lease_id` (string or null), `details` (object of safe scalars), `event_kind`, `operation_id`, `sequence` (dense 1..n) | append order |

Decode (`storage.py:473-551`): `schema_version` int 1; `expires_at` accepts int or float (→ `float`) — a Haskell writer must
always emit the float form to stay byte-identical with Python re-encodes; `base64.b64decode(validate=True)`; any error →
`StorageError("connection custody payload is invalid")`. `validate_snapshot` (`:231-388`) invariants: `revision == len(audit)`;
hosts/connections/leases canonically sorted and unique; strings `_stored_text` (non-empty, trimmed, no control; no length cap);
status ∈ 5 values; positive epochs/versions; ciphertext and digest present together and digest matches; ciphertext may be absent
only in `reauthorization_required|revoked|erasure_pending`; lease ids and attachment ids unique; lease references known host and
connection; `activated ⇒ mode == refresh`; `released ⇔ release_reason != null`; every **unreleased** lease matches an active host
with equal `enrollment_epoch` and the connection's current `authority_epoch`/`state_version`; per connection: an unreleased refresh
lease must be the only unreleased lease, `refreshing ⇔` unreleased refresh lease exists, unreleased leases only in
`ready|refreshing`; audit details sorted by key, values `null|str|int|bool|finite float`.

**Event kinds** (`AuditRecord.event_kind`) and details keys:

| event_kind | method | details |
|---|---|---|
| `host.enrolled` | `enroll_host` (`custody.py:268-291`) | `ambiguous_connections, canceled_leases, enrollment_epoch, expired_leases` |
| `host.removed` | `remove_host` (`:293-315`) | `ambiguous_connections, canceled_leases, offline_erasure_limit=true` |
| `connection.authorized` / `connection.reauthorized` | `authorize` (`:317-369`) | `authority_epoch, state_version` |
| `materialization.reconciled` (op id `reconcile-<sha256(parent op)[:32]>`) | pre-step of `materialize` (`:778-791`) | `ambiguous_connections, expired_leases` |
| `materialization.acquired` | `materialize` (`:371-451`) | `ambiguous_connections, authority_epoch, base_version, expired_leases, mode` |
| `materialization.failed` (op id `abort-<sha256(parent)[:32]>`) | `_abort_materialization` (`:793-812`) | `ambiguous_refresh` or `already_settled=true` |
| `materialization.activated` | `activate` (`:453-473`) | `authority_epoch` |
| `materialization.renewed` | `renew` (`:475-498`) | `expires_at` (float) |
| `materialization.checkpointed` | `checkpoint` (`:500-557`) | `accepted_version, base_version` |
| `materialization.released` | `release` (`:559-592`) | `ambiguous_refresh, mode` or `already_settled=true, mode` |
| `connection.rotated` | `rotate` (`:594-595,733-776`) | `authority_epoch, canceled_leases, state_version` |
| `connection.revoked` | `revoke` (`:597-626`) | `authority_epoch, canceled_leases, offline_erasure_limit, provider_revocation="not_claimed"` |
| `connection.erasure_started` (op id `prepare-<sha256(op)[:32]>`) / `connection.erased` | `erase` (`:628-673`) | `state_version` / `key_erased, physical_media_erasure_guaranteed=false, state_version` |
| `attachment.result.admitted` / `attachment.effect.admitted` | `admit_result`/`admit_effect` (`:675-731`) | `authority_epoch` (snapshot otherwise unchanged; admission is itself an audited CAS op) |
| `installation.recovered` | `recover` (`:685-697`) | `ambiguous_connections, expired_leases` |

Audit detail names containing `token|secret|password|home|key_material` (case-insensitive) are refused (`:1135-1143`).

**Derived identities**: `lease_id = "lease-" + sha256(operation_id.utf8).hexdigest()[:32]`, `attachment_id = "attachment-" + same`
(`custody.py:385-387`).

**Materialization files** (`materialization.py`): root dir non-symlink, created `0700`, must be exactly `0700`
(`:190-208`); file `<root>/<attachment_id>.state` (`:210-211`), attachment id charset `[a-z0-9-]+` (`:213-220`); create
`O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW`, mode `0600`, `fchmod 0600`, write, flush, `fsync` (`:81-102`); `read`/`replace`
re-`lstat`, refuse symlink/non-regular/mode≠0600, open with `O_NOFOLLOW`, verify `(st_dev, st_ino)` unchanged (`:167-188`);
`replace` = `O_WRONLY|O_TRUNC` + write + fsync. `cleanup` (`:124-155`): absent → `already_absent`; symlink → unlink,
`security_violation`; non-regular → unresolved violation; else overwrite `st_size` bytes with zeros in ≤64 KiB blocks, `fsync`,
unlink; `bytes_overwritten = st_size`; `physical_erasure_guaranteed` always `False`.

**Log line** (observable, secret-free): logger `petrus.agenticus.connection.custody`, INFO,
`"%s operation=%s connection=%s host=%s lease=%s"` with `-` for absent ids (`custody.py:873-880`).

#### 3. Concurrency & durability semantics

* **Optimistic CAS over one row**: `_commit` (`custody.py:838-882`) loops up to `_CAS_ATTEMPTS = 8`: load + validate; if
  `operation_id` already present in audit → `OperationConflict` (idempotency key; callers reconcile via `lookup_operation`);
  run the pure transform; append an `AuditRecord(sequence=len+1)`; `revision+1`; CAS; on success run cleanup of the
  change's `cleanup_ids` (deduplicated, order-preserving) via `materializer.summarize`; after 8 failures → `StorageContention`.
  Multiple processes may share the SQLite file; SQLite `BEGIN IMMEDIATE` serializes writers and the revision predicate fences.
* Seal/open happen **outside** the CAS loop; transforms re-check generation (`_same_connection_generation`: id, status, epochs,
  digest) and raise `StorageContention`/`StaleCustody` if it moved (`:347-351,752-755,1114-1123`).
* **Leases**: `ttl` finite > 0; `expires_at = clock()+ttl` (custody clock is host-injected wall/monotonic seconds as float).
  `_reconcile_expired` (`:1017-1023`) releases every unreleased lease with `expires_at <= now` (reason `expired`) and
  `_settle_released_refreshes` (`:994-1014`): for released refresh leases whose connection is `refreshing` → `ready`, unless the
  lease was **activated** (provider may have rotated) → `reauthorization_required`, `authority_epoch+1`, ciphertext dropped
  ("ambiguous"). Expiry reconciliation runs inside enroll/remove/materialize/release/recover.
* **Fencing**: `_require_current_lease` (`:1040-1059`) requires lease present, host active with `enrollment_epoch == fence.host_epoch`,
  not released, not expired, mode matches, all fence fields equal. Admission additionally requires connection `ready|refreshing`
  and current `authority_epoch`/`state_version` (`:1073-1084`).
* **Refresh protocol**: materialize(refresh) only when no active lease (`LeaseConflict`), sets status `refreshing`; `activate`
  marks provider-mutation start; provider mutates the materialized file; `checkpoint` requires activated current lease, reads the
  file, seals as `base_version+1` under the same authority epoch, CAS publishes `ready` + new ciphertext + lease released
  (`checkpointed`), then cleans the file (cleanup is called twice: explicitly and in `finally`; the second is `already_absent`).
* Re-enrollment bumps the host epoch and cancels that host's active leases; removal bumps epoch, deactivates; rotate/revoke bump
  `authority_epoch` and cancel all unsettled leases; `erase` is two-phase (`revoked → erasure_pending` CAS, `keys.erase`, then
  `reauthorization_required`, `state_version+1`, ciphertext null) and is retryable from `erasure_pending`.
  `authorize` on an existing connection is only allowed in `reauthorization_required` with matching identity fields; both epochs +1.
* `recover()` sweeps files for **all** released leases (orphans left by a crash after publication), not only newly expired.
* Plaintext buffers are zeroed (`_erase_buffer`) after seal/materialize; `OpaqueState` is erased on every authorize/rotate path.
* No threads are spawned; the SQLite connection is guarded by a `threading.Lock`.

#### 4. External dependencies

Python: `sqlite3`, `hashlib`, `base64`, `json`, `os` (O_NOFOLLOW/O_EXCL/fchmod/fsync), `logging`; tests: `cryptography` (AESGCM).
Haskell: `direct-sqlite` or `sqlite-simple` (need explicit `BEGIN IMMEDIATE`, busy timeout 5000 ms, pragmas), `crypton`
(SHA-256; AES-GCM for a reference `KeyOperations`), `base64-bytestring` (padded standard alphabet, strict decode), `unix`
(`openFd` with `exclusive`/`nofollow`/`creat`, `setFdMode`, `getSymbolicLinkStatus`, `fileSynchronise` from unix ≥ 2.8),
`memory`/`crypton` `ScrubbedBytes` for erasable plaintext, `co-log`/`katip` or plain `Text` logging, `petrus-json` (sorted keys,
`ensure_ascii`, Python float repr — `aeson` cannot reproduce Python float repr/escaping).

#### 5. Upstream tests

`tests/petrus/agenticus/connection/test_custody.py` — 21 functions (24 cases: `ttl ∈ {nan, inf}`, 3 terminal statuses). Rig
fixture (`:160-194`): fake clock at 1000.0, synthetic AES-GCM key ops, a fake rotating OAuth provider (JSON opaque state with
canary tokens), real SQLite file and materializer under `tmp_path`. Covers: cross-host materialization, single CAS winner under
`threading.Barrier` with two custody objects on one file, renew/admission, non-finite TTL, lost-ack reconciliation via
`lookup_operation` (asserts exact details tuple), bounded 8-attempt contention, crash before/after provider mutation, orphan sweep,
stale writer vs rotation, expired refresh superseded by rotation, ambiguous release, host removal/re-enrollment (`host_epoch == 3`),
revoke, retryable erase, **secret canaries absent** from DB bytes, files, reprs and logs, permissive-mode/symlink refusal,
storage validation, empty provider return, terminal states never materialize. Needs only `cryptography`; no Docker/network.

#### 6. Performance

Every operation rewrites the **entire** JSON document including the full audit history: per-op cost O(total ops), cumulative
O(n²), plus 2 fsyncs (`synchronous=FULL`, DELETE journal). Benchmark: same rig, N ∈ {100, 1 000, 5 000} cycles of
materialize(read)/release on 10 connections × 3 hosts with identical synthetic AES-GCM; measure p50/p99 per-op latency and
total wall time; measure separately with `synchronous=OFF` on tmpfs to isolate encode/validate cost. Same SQLite version for both.

#### 7. Better the Haskell way

* Model transforms exactly as upstream: pure `StorageSnapshot -> Either CustodyError (Change a)` + one generic `casCommit`; this
  is already the Python design and ports cleanly.
* Sum types: `ConnState = Ready Cipher | Refreshing Cipher | Revoked (Maybe Cipher) | ErasurePending (Maybe Cipher) | ReauthRequired (Maybe Cipher)`;
  `LeaseLife = Live | Released ReleaseReason`; `Activated` only constructible for `Refresh` (GADT index on mode).
* `ScrubbedBytes` + `bracket`/`finally` guarantee zeroing and file cleanup on async exceptions (Python relies on `finally`).
* Keep the snapshot-document format (needed for interop) even though a normalized schema would be faster; optionally add an
  in-memory parsed cache keyed by revision to skip re-parsing on unchanged loads.
* Preserve quirks: details `expires_at` float; `prepare-`/`abort-`/`reconcile-` derived op ids (a retried `materialize` whose
  derived `reconcile-` id already exists raises `OperationConflict`); `recover` cleans all released leases' files.

#### 8. Packaging

`petrus-agenticus` IO layer, module `Petrus.Agenticus.Connection.*`. Independent of the kernel; depends on `petrus-json`,
SQLite binding, `crypton`, `unix`. Buildable in parallel with everything.

---

### Thread lifecycle (`thread/identity.py`, `thread/continuation.py`, `thread/lifecycle.py`)

#### 1. Responsibility & public API

Pure immutable values for Thread (lineage) → Episode (one bounded Agent Program execution) → Turn (one step), and
opaque Continuation revisions with explicit program compatibility. No workspace/process/transcript custody.

* Identities (`identity.py:23-51`): `ThreadId`, `ContinuationId`, `EpisodeId`, `TurnId` — distinct newtypes over `_text`;
  `to_data()` = bare JSON string.
* `ContinuationState{available, in-use, retired}`; `ContinuationDescriptor(identity: continuation-kind DescriptorIdentity,
  program: program-kind DescriptorIdentity)`, ordered (`continuation.py:39-69`). `Continuation(id, thread, descriptor,
  state_reference: _text (opaque custody ref, hidden from repr), state=available)`; `claim()` only from available → in-use;
  `retire()` idempotent (`:72-132`). `ContinuationCodec[P]` protocol (`descriptor`, `load(c) -> P`).
* `check_continuation_compatibility(program, continuation|None) -> CompatibilityResult` (`:152-173`): fresh start needs
  `accepts_fresh_start` else issue `continuation-required(program name)`; otherwise needs an accepted entry with equal identity
  (`continuation-not-accepted(cont identity name)`) and equal program (`continuation-program-mismatch(cont program name)`);
  `require_continuation_compatible` raises `IncompatibleContinuation(result)`. Never translates state.
* Lifecycle (`lifecycle.py`): enums `ThreadState{open,closed}`, `EpisodeState{running,cancelling,settled}`,
  `TurnState{running,settled}`, `TurnOutcome{completed,failed,cancelled,indeterminate}`,
  `EpisodeOutcome{completed,failed,cancelled,budget-exhausted,indeterminate}`,
  `CancellationDisposition{requested,already-requested,too-late}`, `SettlementDisposition{accepted,duplicate}`;
  `LifecycleTransitionError(ValueError)`, `EpisodeBudgetExceeded(dimension)`. `EpisodeBudget(max_turns, max_accepted_appends)`;
  `Turn(id, episode, ordinal, state, accepted_appends, outcome)`; `Episode(id, thread, program, runtime, budget,
  expected_continuation, continuation, state, turns, accepted_appends, settlement, next_continuation)`;
  `Thread(id, state, episodes, continuation)`; results `EpisodeCancellation`, `EpisodeSettlement`, `ThreadCancellation`,
  `ThreadSettlement`. Transitions: `Thread.start_episode(episode_id, program: AgentProgramDescriptor, runtime, budget)` (checks
  continuation compatibility, claims the Thread continuation, `expected_continuation = program.produced_continuation`),
  `start_turn`, `accept_append`, `settle_turn`, `request_cancellation`, `settle_episode(outcome, continuation=None)`, `close()`.

Key invariants (enforce identically, they gate `from_data`): Turn ordinals contiguous from 1; only the final Turn running;
`Episode.accepted_appends == Σ turn.accepted_appends ≤ max_accepted_appends`; `len(turns) ≤ max_turns`; active Episode input
continuation `in-use`, settled one `retired`; completed Episode with `expected_continuation` must publish `next_continuation`
(`available`, matching identity and program); cancelling Episode cannot complete; `cancelled` needs a prior cancellation;
`budget-exhausted` needs `len(turns) ≥ max_turns or appends ≥ max`; settle is idempotent (`duplicate`) only for identical
outcome+continuation; Thread: only last Episode active, adjacent Episodes share one Continuation revision (equality ignoring
`state`), result continuation ids unique, closed Thread continuation retired and equal (ignoring state) to last
`next_continuation`, open resting Thread exposes last `next_continuation` as `available` (`lifecycle.py:137-681`).

#### 2. Wire formats

All JSON, insertion order as listed, `schema_version: 1`, exact key sets:
`EpisodeBudget {"schema_version","max_turns","max_accepted_appends"}`;
`Turn {"schema_version","id","episode","ordinal","state","accepted_appends","outcome"}`;
`ContinuationDescriptor {"schema_version","identity","program"}`;
`Continuation {"schema_version","id","thread","descriptor","state_reference","state"}`;
`Episode {"schema_version","id","thread","program","runtime","budget","expected_continuation","continuation","state","turns","accepted_appends","settlement","next_continuation"}`;
`Thread {"schema_version","id","state","episodes","continuation"}` (`lifecycle.py:112-117,174-183,396-413,650-657`;
`continuation.py:50-55,103-111`). Durable use: the runtime's Agent-as-Net Thread projection embeds `Thread.to_data()` and
`LoopState.to_data()` and encodes with `json.dumps(..., allow_nan=False, separators=(",",":"), sort_keys=True)`
(`src/petrus/agenticus/runtime/agent_net_runner.py:260-270,343`); Codex runtime records embed `Continuation.to_data()`.

#### 3. Concurrency & durability

Pure values; persistence/CAS is the caller's (runtime repositories).

#### 4. External dependencies

None. Haskell: `text`, `petrus-json`.

#### 5. Upstream tests

`thread/test_continuation.py` — 5 functions: no inferred cross-program portability, fresh-start refusal, typed refusal before codec,
explicit migration requirement, single claim. `thread/test_identity_and_lifecycle.py` — 8 functions: identity non-interchangeability,
runtime replacement within one Thread, round trip of active Episode, budgets, cancellation/settlement races ("first terminal fact
wins"), declared result Continuation, failed Episode retirement, provider-shaped traces never enter lifecycle data. Pure, fast.

#### 6. Performance

`Thread.__post_init__` revalidates all Episodes on every `replace` (O(episodes) per transition; `_validate_result_continuation`
scans all prior Episodes). Benchmark: Thread with 1 000 sequential Episodes × 4 Turns, time all transitions and
`to_data/from_data`; Haskell should be dominated by JSON.

#### 7. Better the Haskell way

Indexed state machine: `Episode (s :: EpisodeState)` with transitions as total functions; `Turn` as `Running | Settled TurnOutcome`;
`Continuation` state phantom-typed so only `Available` can be claimed. Smart constructors for `from_data` that re-run the same
invariants (Python validates on construction, so decode of an invalid but well-shaped document must fail).

#### 8. Packaging

Pure core of `petrus-agenticus` (`Petrus.Agenticus.Thread.*`); depends on Catalog and `Program.Descriptor`. Parallel with kernel.

---

### Program (`program/descriptor.py`, `program/seam.py`, `program/agent_net.py`)

#### 1. Responsibility & public API

* `ProgramOwnership{provider-owned, harness-owned, net-owned}`; `ContinuationRequirement(identity: continuation kind, program:
  program kind)` ordered; `AgentProgramDescriptor(identity: program kind, ownership, accepts_fresh_start=True,
  accepted_continuations=() (deduped, sorted), produced_continuation=None, owns_steering=False, owns_evaluation=False)`
  (`descriptor.py:29-144`).
* `ProgramSeams[D,T,E](descriptor, steering=None, evaluator=None)` — a seam must be present iff the descriptor owns it
  (`seam.py:24-42`); `ProgramSteering`/`ProgramEvaluator` are callables `(EpisodeId, x) -> ...`.
* **Agent-as-Net** (`agent_net.py`): a provider-free static Net owning a bounded Pi-style loop.
  Constants (`:22-56`): `VERSION=1, MAX_PROPOSALS=16, MAX_PHASES=16, MAX_TOOLS=64, MAX_JSON_BYTES=4096`, text ≤ 256 B, error detail
  ≤ 128 B; activities `MODEL_PHASE_ACTIVITY = "agenticus.net.model-phase"`, `HANDS_ACTIVITY = "agenticus.net.hands"`;
  identities `program/agenticus.net-owned@1`, `continuation/agenticus.net-owned@1`; `AGENT_AS_NET_PROGRAM` (net-owned, accepts
  fresh start, accepts and produces its own continuation); capability descriptors offering `program.net-owned` /
  `continuation.net-owned`. Enums `StopReason{stop, toolUse, length, error, aborted}`,
  `TerminalCode{completed, failed, cancelled, phase-budget-exhausted, tool-budget-exhausted}`.
  Values: `Proposal(id, method, params: JSON object)`, `ModelResult(id, ok, data, error)`, `LoopState(episode_id, turn_id, phase,
  phase_limit, tool_count, tool_limit, output_ref?, continuation_ref?, grant_epoch, capabilities, results)`,
  `ModelSettlement(state, stop, assistant_digest, output_ref, continuation_ref, proposals)`, `ToolWork(state, assistant_digest,
  proposals, index)`, `HandsSettlement(work, result)`, `Terminal(episode_id, turn_id, code, phases, tools, output_ref,
  continuation_ref)`; `initial_marking(state)`, `agent_net()`, `agent_net_handlers()`, `agent_net_guards()`.

Kernel APIs used: `petrus.impetus.dsl.{NetSpec, arc, petri_guard, petri_handler}`, `petrus.impetus.petrinet.{Arc, Binding, Cel,
Marking, Net, NetPath, Token}`, `Net.handler_uri`, `NetSpec.build() -> (net, handlers, guards)`,
`petrus.impetus.binding.ActivityHandler` (`prepare(binding) -> ActivityInvocation`, `project(binding, result) -> {place: tokens}`),
`petrus.motus.activity.ActivityInvocation(activity, input=...)`. Tests also use `petrus.engine.Engine.{create,load,advance}`,
`InMemoryHistoryStore`, `InlineDispatch`, `ActivityRequested/ActivityCompleted`, `Status`.

#### 2. Net topology and History-visible JSON (byte-for-byte relevant)

Net (`agent_net.py:639-672`): `NetSpec("agent-as-net", completion=Cel("size(done) != 0"))`; places (name: color)
`model_pending: LoopState`, `model_settled: ModelSettlement`, `tool_pending: ToolWork`, `tool_settled: HandsSettlement`,
`done: Terminal`; transitions `model_phase(handler="model_phase")` (activity), `classify_model(petri_handler(_classify))`,
`execute_tool(handler="hands", guards=petri_guard(_execute))` (activity), `reject_tool(petri_handler(_reject_tool),
guards=petri_guard(_reject))`, `record_result(petri_handler(_record))`; arcs (all consume, color-inscribed, in this authored order):
`model_pending→model_phase→model_settled`, `model_settled→classify_model`, `classify_model→{model_pending, tool_pending, done}`,
`tool_pending→{execute_tool, reject_tool}`, `execute_tool→tool_settled→record_result`, `reject_tool→{tool_pending, model_pending, done}`,
`record_result→{tool_pending, model_pending, done}`. Handler/guard URIs follow `NetUri.declaration("transition", path, "handler")`
and guard `"$0"` (`src/petrus/impetus/petrinet/schema.py:461-472`); anonymous declarations keep display names `_classify`,
`_reject_tool`, `_record`, `_execute`, `_reject` (`src/petrus/impetus/dsl.py:91-94`) — a Haskell port must author the identical
net so net definitions/documents and History match.

Token payloads (History stores token data and activity input/result **without `sort_keys`**
(`src/petrus/impetus/history_store/sqlite.py:345`), so **key insertion order is part of the format**):

* `LoopState.to_data()` (`:214-219`, built with `dataclasses.asdict` then `version` appended **last**):
  `{"episode_id","turn_id","phase","phase_limit","tool_count","tool_limit","output_ref","continuation_ref","grant_epoch","capabilities"(sorted unique),"results"[ModelResult.to_data],"version":1}`.
* `ModelResult.to_data()` = `{"version":1,"id","result":{"version":1,"ok","data","error"}}`; `to_model_data()` is the inner object.
  ok ⇒ `data` object, `error` null; not ok ⇒ `data` null, `error == {"category","detail"}` exactly, category ∈ the 13 Hands
  `RejectionCategory` values, detail `_text` ≤ 128 B (`:124-167`). `data`/`error`/`params` pass through `_json` (dumps→loads) which
  preserves the caller's key order.
* `Proposal` = `{"version":1,"id","method","params"}`; `ModelSettlement` = `{"version","state","stop","assistant_digest"(64 lowercase hex),"output_ref","continuation_ref","proposals"}`;
  `ToolWork` = `{"version","state","assistant_digest","proposals","index"}`; `HandsSettlement` = `{"version","work","result"}`;
  `Terminal` = `{"version","episode_id","turn_id","code","phases","tools","output_ref","continuation_ref"}`.
* Token colors: `"LoopState"`, `"ModelSettlement"`, `"ToolWork"`, `"HandsSettlement"`, `"Terminal"`.
* Model activity: input = the `LoopState` token data; result must decode as `ModelSettlement` whose `state` equals the input
  state (`:460-472`). Hands activity input = `{"version":1,"proposal":Proposal,"grant_epoch":n}`; result =
  `{"version":1,"result":ModelResult.to_data()}` with `result.id == proposal.id` (`:475-490`).

Loop semantics (`:493-636`): `classify` resets `results` to `()` and adopts settlement refs; `error → failed`, `aborted → cancelled`,
no proposals → `completed` (even after `length`), `length` with proposals → every proposal answered
`{"category":"provider","detail":"proposal rejected after length stop"}` without Hands, then next phase or
`phase-budget-exhausted`; `tool_count ≥ tool_limit` → `tool-budget-exhausted`; else `ToolWork(index 0)`. Guard
`execute ⇔ method ∈ capabilities ∧ tool_count < tool_limit`; `reject` is the complement producing
`budget` ("tool budget exhausted" → terminal) or `capability` ("tool is unsupported or not granted", no tool count increment).
`record` increments `tool_count`; Hands error category `aborted` → `cancelled`; `_continue` moves to the next proposal, else
next phase (phase+1) or `phase-budget-exhausted` when `phase ≥ phase_limit`.

#### 3. Concurrency & durability

Deterministic and replayable: reconstruction from every committed quiescent History prefix must reproduce marking and status
(`test_agent_net.py:476-497`). All durability is the Engine's; Activities are at-least-once per Motus semantics, so activity
implementations (runtime) must be idempotent by invocation identity.

#### 4. External dependencies

None beyond the kernel and Motus Activity types. Haskell: the ported Impetus DSL/Net/Marking/Token, CEL (`size(done) != 0`),
`petrus-json` with **ordered objects** (insertion order) and Python `ensure_ascii=True` size measurement.

#### 5. Upstream tests

`program/test_program_descriptor.py` — 3 functions (5 cases): each ownership round-trips, seams keep native payload types, seam
presence matches ownership. `program/test_agent_net.py` — 21 functions (35 cases: 2 stop routes, 13 error categories): exact
descriptors/topology, single/multi-tool batches with exactly one Activity per real call, ordered rejections, length/terminal routes,
budgets, result delivery to exactly one following model phase, bounds, History contains model/hands facts and no custody data,
prefix reconstruction (`Engine.load`), and a static import check (no provider/runtime imports). Uses `Engine` +
`InMemoryHistoryStore` + `InlineDispatch`; no Docker.

#### 6. Performance

Hot path = JSON round-trips of `LoopState`/`ToolWork` on every firing (each handler re-decodes and re-validates). Benchmark:
`run()` harness with 16 phases × 4 proposals per phase (64 tools), 1 000 episodes, InMemory history and inline dispatch;
measure firings/s and bytes recorded; compare record bytes for equality across implementations.

#### 7. Better the Haskell way

Typed handlers over decoded values (decode once per binding), `LoopState` with `refs :: Maybe (OutputRef, ContinuationRef)` (both-or-none
by construction), `Proposal` batch as `NonEmpty` with a zipper for `ToolWork`. Keep the encoder emitting the exact Python key orders.

#### 8. Packaging

`Petrus.Agenticus.Program.{Descriptor,Seam}` in the pure core; `Petrus.Agenticus.Program.AgentNet` needs `petrus-impetus`
(DSL, petrinet, binding), `petrus-cel`, and `petrus-motus` (`ActivityInvocation`); its tests need `petrus-engine`. Build after the
kernel DSL and Motus Activity types exist.

---

### Hands (`hands/contract.py`, `grants.py`, `gateway.py`, `workspace.py`, `conformance.py`)

#### 1. Responsibility & public API

Exactly five version-1 workspace tools behind one capability-scoped gateway per Episode Attachment epoch; all errors in a fixed
secret-safe vocabulary.

* `ToolMethod{workspace_read, workspace_search, workspace_shell, workspace_write, workspace_test}`; params
  `ReadParams(path)`, `SearchParams(query, path)`, `ShellParams(argv: tuple, cwd)`, `WriteParams(path, content)`, `TestParams()`
  (`contract.py:41-190`). Bounds: path ≤ 64 chars, query ≤ 64, argv ≤ 4 parts each ≤ 64, cwd ≤ 8, content ≤ 1024 chars (no NUL),
  result text ≤ 4096 UTF-8 bytes per string, identity ≤ 256 B, detail ≤ 128 B (`:19-27`).
* `CAPABILITY_SCOPED_HANDS = CapabilityDescriptor(hands/agenticus.capability-scoped@1, offers {hands.capability-scoped,
  workspace.read, workspace.search, workspace.shell, workspace.write, workspace.test})` (`:51-63`).
* `RejectionCategory` (13): `capability, path, argv, write, unknown, deadline, aborted, stale_epoch, post_fence, provider, schema,
  authority, budget` (`:75-95`). `ToolRequestRejected(category, detail)`, `ToolCallConflict`.
* `parse_tool_request(data) -> ToolRequest` (`:286-322`), `ToolError(category, detail)`, `ToolResult(call_id, attachment_id, epoch,
  ok, data, error)` with `to_data()`/`to_model_data()` (`:343-401`).
* Grants (`grants.py`): `CapabilityGrant(attachment_id, attachment_epoch, grant_epoch, capabilities, writable_paths, allowed_argv,
  deadline, max_calls, writable_roots=∅, denied_writable_roots=∅)`; `permits(method)`, `permits_write_path(path)` (denied roots win;
  `"."` = all; segment-prefix match `root/`) (`:94-137`). `GrantLedger(attachment_id, attachment_epoch)`: `current()`, `open(...)`
  (grant_epoch strictly +1, resets consumed count), `close()`, `consume(grant_epoch)` (`GrantLedgerError` / `GrantBudgetExhausted`) (`:148-229`).
* Gateway (`gateway.py`): adapter result values `ShellOutcome(returncode, stdout, stderr, truncated)`, `StagedWrite(call_id, path,
  digest: 64 hex)`, `TestOutcome(passed, evidence_digest)`; `HandsAdapter` protocol (`read, search, shell, stage_write, commit_write,
  discard_write, run_test, discard_all_stages`); `CallFence(open, aborted, deadline)`, `CallFenceSource.snapshot()`,
  `ResultAdmission.admit(call_id) -> bool`, `TargetCurrency.is_current() -> bool`; `CallEvidence`, `GatewayCounters`;
  `HandsGateway(episode_id, adapter, grants, fence, barrier: RLock, admission=None, target=None, clock=time.monotonic,
  max_evidence=256, max_calls=256)` with `submit(data) -> ToolResult`, `drain(timeout)`, `cleanup_stages()`, `counters()`, `evidence()`.
* `MotusWorkspaceAdapter(provider, attachment, *, test_command, command_timeout=60.0)` (`workspace.py:48-200`); constants
  `STAGE_DIRECTORY=".petrus-hands-stage"`, `MAX_READ_BYTES=4096`, `MAX_SEARCH_MATCHES=16`, `MAX_SEARCH_MATCH_CHARS=256`,
  `MAX_STREAM_BYTES=2048`, command output limit 65536.
* `SevenStepEpisodePolicy` + `MarkerDecision{episode_complete|episode_step}` + `ConformanceError` (`conformance.py:23-201`):
  executable ES-049 example policy (≤ 8 turns/appends; blocked write → read/search → grant → write → test → marker).

#### 2. Wire formats and exact command lines

Request envelope v1 (exact key set, `contract.py:29-38`):
`{"version":1,"call_id","episode_id","attachment_id","attachment_epoch","grant_epoch","method","params"}`; params exact fields:
read `{path}`, search `{query,path}`, shell `{argv: [str...], cwd}`, write `{path,content}`, test `{}`.
**Validation order** (determines the reported category): envelope is an object with string keys → exact envelope keys → `version`
int 1 → `method` string (else `schema`) and known (else `unknown`) → params object with exact keys (`schema`) → per-method field
checks (path: `path`; query: `schema`; argv shape `schema`, count/part/traversal `argv`; cwd `argv` (`"."` or normalized relative);
content type/NUL `schema`, length `write`) → only then `call_id/episode_id/attachment_id` (`schema`) and epochs (`schema`)
(`:286-322`). Relative path = no leading `/`, no `\`, no empty/`.`/`..` segment (`.hidden` is fine).

Result `to_data()` = `{"version":1,"ok","data","error":{"category","detail"}|null,"epoch","call_id","attachment_id"}`;
model projection `to_model_data()` = `{"version":1,"ok","data","error"}` (no custody coordinates). Data shapes:
read `{"content"}`, search `{"matches":[...≤64]}`, shell `{"returncode","stdout","stderr","truncated"}`,
write `{"committed":true,"digest"}`, test `{"passed","digest"}` (`gateway.py:422-480`). Unparsed requests salvage `call_id`/
`episode_id` only if string, 1..64 chars, trimmed, no control, else `"unparsed-request"` (`:615-632`).

Fixed details (secret-safe vocabulary) include: `"provider operation failed"`, `"episode, attachment identity, or epoch is not current"`,
`"attachment admission is closed"`, `"attachment is cancelled"`, `"grant is not current"`, `"call deadline has passed"`,
`"no current write grant"`, `"path is not writable under the current grant"`, `"capability is not granted"`,
`"argv is not allowed under the current grant"`, `"grant call budget is exhausted"`, `"call ledger budget is exhausted"`,
`"attachment fence closed after staging"`, `"attachment cancelled before commit"`, `"grant replaced before commit"`,
`"deadline passed before commit"`, `"connection admission rejected the result"`, `"target head is no longer current"`
(`gateway.py:312-504`), plus parser details from `contract.py`.

Territory commands (`workspace.py`, run via `Command(argv, cwd=Path(cwd), timeout, output_limit=65536)`, empty environment):

| op | argv |
|---|---|
| read | `("/bin/sh","-c",'cat -- "$0"', path)`; stdout UTF-8 `errors="replace"` truncated to 4096 bytes (trim chars until ≤ bound) |
| search | `("/bin/sh","-c",'grep -r -n -e "$0" -- "$1"', query, path)`; rc 1 → no matches; lines ≤ 256 chars, ≤ 16 lines |
| shell | argv verbatim, cwd; stdout/stderr ≤ 2048 bytes each; `truncated` = provider truncation or local truncation |
| stage | name = `sha256(call_id).hexdigest()[:32]`: `("/bin/sh","-c",'mkdir -p -- "$0" && printf %s "$2" > "$0/$1"', ".petrus-hands-stage", name, content)`; digest = sha256(content UTF-8) |
| commit | `("/bin/sh","-c",'parent=$(dirname -- "$2") && mkdir -p -- "$parent" && mv -f -- "$0/$1" "$2"', ".petrus-hands-stage", name, path)` |
| discard | `("/bin/sh","-c",'rm -f -- "$0/$1"', ".petrus-hands-stage", name)` |
| discard all | `("/bin/sh","-c",'rm -rf -- "$0"', ".petrus-hands-stage")` |
| test | host `test_command`; `passed = rc == 0`; evidence = sha256(stdout+stderr) |

Every result's `provenance.identity` must equal the attachment lease identity; `timed_out`/`superseded` → adapter error.

#### 3. Concurrency semantics

Pipeline (`gateway.py:293-320`): `requests++` → parse (reject unparsed) → `_claim` (call ledger single-flight: same `call_id` +
equal request waits on a `Condition` and returns the published result; different request → `ToolCallConflict`; ledger full
(256) → `budget`; claim increments `in_flight`) → direct precheck (identity/epoch → `stale_epoch`; fence snapshot errors →
`provider`; closed → `post_fence`; aborted → `aborted`; grant epoch → `stale_epoch`; `clock() > min(fence.deadline, grant.deadline)`
→ `deadline`; policy) — prechecks never cross the adapter → `grants.consume` (exhausted → `budget`, stale → `stale_epoch`) →
adapter → **postcheck under the shared attachment barrier** (fence, abort, grant replaced, deadline, admission → `authority`, target
→ `post_fence`) → for writes: stage outside the barrier, postcheck+commit inside the barrier, discard on failure → finalize/publish
(`in_flight--`, notify). Abandoned claims (exceptions) are removed so an exact waiter can reclaim. `drain(timeout)` waits for
`in_flight == 0`. Successful results count `results_admitted`. Evidence is a bounded deque (256). Grant budget is spent only after
prechecks pass. The barrier is an `RLock` shared with `EpisodeAttachment` (reentrant: fence snapshots re-enter it).

#### 4. External dependencies

Python stdlib + Motus execution provider (subprocess/Docker/Gondolin via Motus). Haskell: `stm` (ledger, counters, drain with
`registerDelay`), `async`, `crypton` (SHA-256), `text` (code-point lengths, `decodeUtf8With lenientDecode` = Python `errors="replace"`
on invalid bytes — verify equivalence of replacement granularity; Python replaces per maximal invalid subsequence like
text's lenient decoder in text ≥ 2.0), the ported `petrus-motus` execution contract.

#### 5. Upstream tests

* `hands/test_contract_and_gateway.py` — 20 functions (29 cases: 5 methods, 6 bad paths): exact strict requests, descriptor
  registerable, bounds/unknown, 1024-char write boundary, grants monotonic/finite/budgeted, write roots and denials, all direct
  rejections pre-crossing with flat counters, staged write commits once and post-fence discards, sanitized provider errors,
  model projection, retransmission/conflict, concurrent single-flight, budget vs stale, malformed adapter result, abandoned
  primary reclaim, every postcheck, claimed call drained before cleanup.
* `hands/test_workspace.py` — 3 functions: local `LocalProcessEnvironment` route (real `/bin/sh`, `cat`, `grep`, `mkdir`, `mv`, `rm`),
  binary output byte bound, **Docker** route (`docker info` must succeed; uses `POSTGRES_IMAGE` from root `conftest.py`; no skip marker → fails without Docker).
* `hands/test_conformance.py` — 4 functions (5 cases): exact ES-049 two-Episode report (e.g. gateway totals requests 18,
  adapter_entries 11, stages 3, commits 2, rejections per category 1), premature marker, abort/deadline fail closed, independent budgets.

#### 6. Performance

Gateway overhead per call (parse + 2 fence snapshots + ledger + evidence) with an in-memory adapter: 100k `workspace_read`
submissions, 1 and 8 concurrent callers, unique call ids (ledger size raised); measure calls/s and p99. Workspace adapter is
process-spawn bound — benchmark separately with LocalProcessEnvironment (1 000 reads) to compare spawn overhead
(`typed-process` vs `subprocess`).

#### 7. Better the Haskell way

`ToolRequest` as a GADT indexed by `ToolMethod`; `ToolResult = ToolResult Coords (Either ToolError Data)`; ledger in STM
(`TVar (Map CallId (Request, Maybe Result))`, `retry` for single-flight). Replace the reentrant RLock with an explicit
`Barrier` capability: functions that run "under the barrier" take a `HeldBarrier` token so reentrancy is not needed.
Preserve: validation order, code-point vs byte bounds, `"unparsed-request"` salvage, 256-call ledger.

#### 8. Packaging

Contract/grants/conformance in the pure core; gateway in the IO layer (`stm`); `Workspace` adapter needs `petrus-motus`
execution contract. Parallel with kernel except the adapter.

---

### Episode Attachment and retained territory (`attachment/binding.py`, `episode.py`, `_retention.py`)

#### 1. Responsibility & public API

* `AttachmentCoordinates(episode_id, attachment_id, attachment_epoch)` — the exact coordinates an `EffectFence` needs
  (`binding.py:71-86`). `BindingSettlement(binding_kind: [a-z][a-z0-9-]{0,63}, disposition: same token grammar, verified: bool,
  detail ≤ 256 B no control, hidden from repr)` (`:89-107`). `AttachmentBinding` protocol: `binding_kind`, `cancel(reason)`,
  `export_archive() -> bytes`, `settle() -> BindingSettlement` (`:110-124`). Provider-managed bindings need no Motus lease.
* `MotusAttachmentBinding` (`binding_kind = "motus-territory"`, `:131-338`): `open(provider, operation_id, spec, *,
  workspace_archive_bytes, input_digest)` — **lookup-first** (`provider.lookup(op)` else `create(op, spec)`), then `attach`; on
  attach failure destroys and raises `MotusBindingError` ("...after verified cleanup" vs "...could not be verified"). `execute(command)`
  provenance-fenced; timed-out/superseded/truncated output sets `discard_output` so `export_archive` returns the **base** archive;
  `cancel` also discards output; `settle` destroys the exact lease: foreign identity → `unverified` settlement, else
  `BindingSettlement("motus-territory", cleanup.disposition.value, cleanup.verified, "provider cleanup evidence consumed")`.
  Private: `_reclaim_exact(provider, LeaseIdentity, ...)` (never creates; requires `READY` and equal identity), `_quiesce(timeout)`
  (close operation admission, wait active ops), `_release(accept)` (irrevocably hand lease to host custody).
* `EpisodeAttachment(*, episode_id: EpisodeId, snapshot: ResolutionSnapshot (must select HANDS and TERRITORY), binding,
  attachment_id, deadline (finite), attachment_epoch=1, admission=None, target=None, clock=time.monotonic)` (`episode.py:152-221`):
  `coordinates()`, `grants() -> GrantLedger`, `gateway(adapter, *, max_evidence=256) -> HandsGateway`, `cancel(reason)`,
  `settle(*, drain_timeout=30.0) -> AttachmentSettlement`, `retry_settlement()`, `successor(...)` (epoch+1, different EpisodeId and
  attachment_id, only after verified settlement), `custody_uncertain`, `settled`, `last_settlement`, `barrier`.
  `AttachmentSettlement(attachment_id, epoch, stages_discarded, archive, archive_digest = sha256 hex, settlement)`,
  `AttachmentRelease(..., territory: LeaseIdentity)`; `EpisodeAttachmentError`, `UncertainCustodyError`;
  `CustodyResultAdmission(custody, fence)` adapts `AgentConnectionCustody.admit_result` into Hands `ResultAdmission`
  (`admit(call_id)` uses the call id as custody `operation_id`; any exception → `False` → `authority`) (`:62-80`).
* `SqliteTerritoryCustody(path, *, clock=time.time)` (`_retention.py:161-609`, private to hosts): `begin_release(custody_id,
  owner_id, attachment, *, retain_until) -> _ReleaseTicket`, `release(...) -> AttachmentRelease`, `reclaim(custody_id, owner_id,
  provider, *, episode_id, snapshot, attachment_id, deadline, admission=None, target=None) -> EpisodeAttachment`, `recover()`,
  `retire(custody_id, owner_id, provider)`, `lookup`, `records`, `close`. `TerritoryCustodyPhase{releasing, retained, claiming,
  attached, retiring, retired, quarantined}`; `TerritoryCustodyRecord(custody_id, owner_id, generation, phase, source:
  AttachmentCoordinates, lease: EnvironmentLease, retain_until, archive?, archive_digest?, target_episode_id?,
  target_attachment_id?, target_epoch?, cleanup: CleanupDisposition?)` (target all-or-none, `target_epoch > source epoch`;
  retained/claiming require archive).

Kernel APIs used: none (Motus execution contract only).

#### 2. Durable schema (territory custody SQLite)

File path chosen by host (tests `<tmp>/custody/territories.db`); parent must be an **owned** (`st_uid == geteuid()`) `0700`
directory; file created `O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW` `0600`, must be owned regular `0600` (`_retention.py:580-609`).
Writer fence file `<parent>/.<db filename>.writer.lock` (`O_RDWR|O_CREAT|O_NOFOLLOW`, `0600`, owned regular) locked with
**`flock(LOCK_EX|LOCK_NB)`**; contention → `StorageError("territory custody already has a live writer")`; use across `fork` refused
by PID check (`:612-652`). Statements, verbatim (`:173-191`, `:235-261`, `:304`, `:329-330`, `:372-373`, `:383`, `:393`, `:423-424`,
`:466-467`, `:487`, `:494-496`, `:520`):

```sql
PRAGMA journal_mode = DELETE
PRAGMA synchronous = FULL
PRAGMA secure_delete = ON
CREATE TABLE IF NOT EXISTS territory_custody (
                    custody_id TEXT PRIMARY KEY, owner_id TEXT NOT NULL,
                    generation INTEGER NOT NULL, phase TEXT NOT NULL,
                    source_episode TEXT NOT NULL, source_attachment TEXT NOT NULL,
                    source_epoch INTEGER NOT NULL, operation_id TEXT NOT NULL,
                    provider TEXT NOT NULL, lease_id TEXT NOT NULL,
                    capabilities TEXT NOT NULL, retain_until REAL NOT NULL,
                    archive BLOB, archive_digest TEXT,
                    target_episode TEXT, target_attachment TEXT, target_epoch INTEGER,
                    cleanup TEXT)
CREATE UNIQUE INDEX IF NOT EXISTS one_live_territory_operation
                   ON territory_custody(provider, operation_id) WHERE phase <> 'retired'
INSERT INTO territory_custody
                       (custody_id, owner_id, generation, phase, source_episode, source_attachment,
                        source_epoch, operation_id, provider, lease_id, capabilities, retain_until)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                       ON CONFLICT(custody_id) DO UPDATE SET owner_id=excluded.owner_id,
                        generation=excluded.generation, phase=excluded.phase,
                        source_episode=excluded.source_episode, source_attachment=excluded.source_attachment,
                        source_epoch=excluded.source_epoch, operation_id=excluded.operation_id,
                        provider=excluded.provider, lease_id=excluded.lease_id,
                        capabilities=excluded.capabilities, retain_until=excluded.retain_until,
                        archive=NULL, archive_digest=NULL, target_episode=NULL,
                        target_attachment=NULL, target_epoch=NULL, cleanup=NULL
SELECT * FROM territory_custody WHERE custody_id=?
UPDATE territory_custody SET phase=?, target_episode=?,
                   target_attachment=?, target_epoch=? WHERE custody_id=? AND phase=?
UPDATE territory_custody SET phase=? WHERE phase IN (?, ?, ?)
                   OR (phase=? AND retain_until<=?)
SELECT * FROM territory_custody ORDER BY custody_id
UPDATE territory_custody SET phase=?, archive=NULL,
                   archive_digest=NULL, cleanup=? WHERE custody_id=? AND phase=?
UPDATE territory_custody SET phase=?, archive=?, archive_digest=?
                   WHERE custody_id=? AND generation=? AND phase=?
UPDATE territory_custody SET phase=? WHERE custody_id=? AND phase=?
UPDATE territory_custody SET phase=?, capabilities='[]', retain_until=0,
               archive=NULL, archive_digest=NULL, target_episode=NULL,
               target_attachment=NULL, target_epoch=NULL, cleanup=NULL WHERE custody_id=?
UPDATE territory_custody SET phase=? WHERE custody_id=?
```

Every write is `BEGIN IMMEDIATE; <stmt>; COMMIT` with optional `expected_rows=1` check (rowcount mismatch → rollback,
`StorageError("territory custody write lost its expected state")`) (`:528-537`). Column encodings: `capabilities` =
`json.dumps(sorted(lease.capabilities), separators=(",", ":"))` (**default `ensure_ascii=True`**, e.g. `["container","workspace"]`);
`retain_until` REAL (wall-clock seconds); `archive` BLOB = Motus workspace tar ≤ 512 MiB; `archive_digest` lowercase sha256 hex of
the archive; `cleanup` = `clean|not-created|unverified`. **Decode is positional over `SELECT *`** (`:549-578`) — the Haskell DDL must
keep the exact column order; decoded leases always get `state=READY`. Integers must be SQLite INTEGER (`type is int`), text must be TEXT
(BLOB identity → quarantine), `retain_until` int or float.

Phase machine:

| from | operation | to |
|---|---|---|
| (none) / `attached` with matching owner+target coords+lease | `begin_release` (generation 1 / +1; upsert clears archive/target/cleanup; `IntegrityError` on unique index → "live custody obligation") | `releasing` |
| `releasing` (same generation) | `_accept_release` via ticket after binding `_release` (expired → `retiring` + error) | `retained` (+archive, digest) |
| `retained` | `reclaim`: owner match, distinct Episode/attachment id, not expired, provider `lookup` READY with identical identity | `claiming` (target = new episode, attachment, `source_epoch+1`) → `attached`; any failure → `retiring` |
| `releasing`/`claiming`/`attached`, or `retained` with `retain_until <= now` | `recover()` | `retiring` |
| corrupt row with valid identity columns | `recover()`/`reclaim` salvage | `retiring` with reset (`capabilities='[]'`, `retain_until=0`, nulls) |
| corrupt identity (custody id/owner/generation/source/operation/provider/lease) | salvage | `quarantined` (+`StorageError("...quarantined")`; never destroyed) |
| `retained`→`retiring` | `retire()`: lookup (foreign current lease → error), `destroy`, verified → | `retired` (archive nulled, cleanup recorded); unverified → stays `retiring` (retry) |

`quarantined` rows still count as live for the unique index.

#### 3. Concurrency & durability

* EpisodeAttachment uses one `RLock` **barrier** shared with every HandsGateway it opens; `settle` (`episode.py:335-395`): under
  barrier mark settling + close admission, then outside: drain every gateway (timeout → `EpisodeAttachmentError`), sum
  `cleanup_stages()`, export archive (bytes, ≤ 512 MiB), `binding.settle()`; exception → synthetic `unverified` settlement "binding
  settlement failed", `uncertain = True`, re-raise as `EpisodeAttachmentError`; unverified → uncertain (no raise). Grant ledger is
  closed at settlement. `retry_settlement` repeats only destroy/consume. Uncertain custody blocks new gateways, settlement,
  release and succession. `cancel` before settlement only, sets `aborted` (fence reports `aborted`), calls `binding.cancel`.
  Call fence = `open ⇔ epoch current ∧ admission open ∧ not uncertain` (`:535-538`).
* `_release_to` (`:397-452`): requires Motus binding; quiesce binding operations, drain gateways, discard stages, export, then the
  host ticket accepts (`binding._release` closes binding forever, then SQLite `releasing → retained`); any failure → uncertain.
* `MotusAttachmentBinding._operation` (`binding.py:310-334`): thread-local depth counter allows nested borrowing; a `Condition`
  tracks active operations for `_quiesce`.
* Territory custody: single writer per state root (flock), SQLite `BEGIN IMMEDIATE`, `synchronous=FULL`, `secure_delete=ON`;
  durable-intent-first: transfer intent (`releasing`) is written before the Attachment closes; reclaim writes `claiming` before
  attaching; crash recovery never resumes active work — it fences to `retiring` and later destroys the exact lease.
  Destroy happens outside the DB lock; a crash after destroy but before commit is retried idempotently (`lookup` returns
  `None` → destroy recorded lease again → `not-created` is verified).

#### 4. External dependencies

Python: `sqlite3`, `fcntl.flock`, `hashlib`, `json`, `threading`. Haskell: `direct-sqlite`/`sqlite-simple`;
**`lukko` (`Lukko.FLock`) or `filelock`** — must use BSD `flock`, not POSIX/OFD `fcntl` locks, or the lock will not exclude a
Python writer on Linux; `unix` for owner/mode checks and `getProcessID`; `stm`/`async` for barrier and drains; `crypton` SHA-256;
ported `petrus-motus` execution contract and workspace archive codec.

#### 5. Upstream tests

* `attachment/test_binding.py` — 5 functions (6 cases): outer shape not Motus-specific, lookup-first open and exact settle,
  interrupted output discarded (cancel/timeout) but territory destroyed, foreign cleanup never verifies, attach-failure cleanup.
* `attachment/test_episode.py` — 9 functions (11 cases): ordered settlement + successor, unverified/raising settlement → uncertain
  + retry, settlement waits for claimed calls, no double export/destroy under concurrency, cancellation ordering, a local end-to-end
  composition (gateway write+test → archive extract → successor stale-epoch rejection), epoch exactly positive.
* `attachment/test_retention.py` — 15 functions (18 cases): reclaim into distinct Episode then exact retirement, recovery retires
  incomplete release, corrupt archive never reclaims, missing lease never re-created, foreign lookup stays retryable, expiry →
  retirement, expiry during export, single live writer, release quiesces before export, one live custody per provider operation,
  reuse of source identities refused, malformed non-identity → retirable vs malformed identity → quarantine, binary identity
  columns quarantine without provider cleanup (3 columns), attached lease fenced on recovery, unverified/crashed retirement retried.
  Most use `LocalProcessEnvironment` (real subprocesses, no Docker); several mutate the SQLite file directly with `sqlite3`.

#### 6. Performance

Dominated by provider operations (process spawn, tar export). Fair benchmark with a fake in-memory `EnvironmentProvider`:
10 000 release→reclaim→retire cycles (archive 1 MiB) measuring SQLite write latency (3 fsync'd transactions per cycle) and
settle() latency with 8 concurrent gateways draining.

#### 7. Better the Haskell way

`EpisodeAttachment` lifecycle as an explicit state ADT (`Open | Settling | Settled Verified | Uncertain AttachmentSettlement | Released`)
in a `TVar`; settlement as a `bracket`-like operation so async exceptions cannot skip the uncertain marking. Territory record as a
phase-indexed sum (archive only in `Retained`/`Claiming`, target only in `Claiming`/`Attached`). Preserve positional row layout and
`json` capability encoding.

#### 8. Packaging

`petrus-agenticus` IO layer (`Petrus.Agenticus.Attachment.*`, retention as an internal module not re-exported to Worker code).
Requires `petrus-motus` execution contract (+ archive bound), Hands gateway, Connection fence type, Catalog snapshot, Thread ids.

---

### Effect (`effect/model.py`, `effect/gateway.py`)

#### 1. Responsibility & public API

Host-side, provider-neutral external Effects (not workspace mutation): secret-free proposals identified by digests, host
decisions, fresh fences, lookup-first execute-at-most-once with digest-only evidence.

* `digest_payload(payload) -> "sha256:<hex>"` over canonical JSON (`model.py:72-89`); payload must be a strict JSON object
  (`None/str/bool/int/list/dict` with string keys; **floats rejected**, tuples rejected).
* `TargetIdentity(target_type: code, target_id: text)` where code = `[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*` (`:14,92-113`).
* `EffectProposal(proposal_id, effect_type: code, effect_version>0, payload_digest, target, requested_authority_class: code)`;
  `.digest = sha256(canonical(to_data()))` (`:116-180`).
* `EffectFence(proposal_id, proposal_digest, authority_epoch, target_head, episode_id, attachment_id, attachment_epoch)`;
  `matches(proposal)` (`:183-243`).
* `EffectReceipt(proposal_id, proposal_digest, payload_digest, target, receipt_digest)`; `correlates(proposal)` (`:246-297`).
* `LookupDisposition{applied, safe-to-retry, superseded, indeterminate}`; `LookupResult(disposition, receipt)` (receipt iff applied)
  (`:300-359`).
* `EffectEvidence(proposal_id, proposal_digest, payload_digest, target, fence, recovery: LookupDisposition|None, receipt_digest|None)`:
  `recovery None` (direct execution) and `applied` require a receipt digest; other recoveries forbid one (`:362-441`).
* `EffectDecisionKind{reject, approve, execute, already-applied, superseded, indeterminate}`; `EffectDecision(kind, proposal_id,
  proposal_digest, fence?, evidence?, reason_code?)`: reject = reason code only; approve = fence only; outcomes = fence + evidence
  with recovery `execute:{None}`, `already-applied:{applied}`, `superseded:{superseded}`, `indeterminate:{safe-to-retry, indeterminate}`;
  fence/evidence must correlate (`:444-567`). Factories `reject(proposal, reason_code)`, `approve(proposal, fence)`.
* `EffectAdapter` (`lookup(proposal) -> LookupResult`, `execute(proposal, payload, fence) -> EffectReceipt`),
  `EffectFenceSource.current(proposal) -> EffectFence`, `EffectGateway(adapter, fences).execute(proposal, payload, approval) -> EffectDecision`
  (`gateway.py:26-183`).

#### 2. Wire formats

Canonical JSON for digests: `json.dumps(v, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()` (UTF-8). Golden
vectors (computed with CPython `json`):
`digest_payload({"message": "ready"})` = canonical `{"message":"ready"}` →
`sha256:50543babb442f1dc6879f51826e6e312d961860667eeb86c9a1fff542cc7e875`; the test proposal
(`tests/petrus/agenticus/effect/test_contract.py:26-34`) canonicalizes to
`{"effect_type":"bulletin.publish","effect_version":1,"payload_digest":"sha256:50543b…e875","proposal_id":"proposal-7","requested_authority_class":"bulletin.publish","schema_version":1,"target":{"target_id":"release-notes","target_type":"bulletin"}}`
→ digest `sha256:f1e336671ced6c810f32f34b25e5ce3733c2482eef2007753e2084c37a106318`. Non-ASCII stays raw UTF-8
(`{"é":"ü"}` → bytes `{"\xc3\xa9":"\xc3\xbc"}`).

`to_data()` shapes (insertion order; all with `"schema_version": 1`, exact key sets on decode):
`TargetIdentity {"target_type","target_id"}`;
`EffectProposal {"schema_version","proposal_id","effect_type","effect_version","payload_digest","target","requested_authority_class"}`;
`EffectFence {"schema_version","proposal_id","proposal_digest","authority_epoch","target_head","episode_id","attachment_id","attachment_epoch"}`;
`EffectReceipt {"schema_version","proposal_id","proposal_digest","payload_digest","target","receipt_digest"}`;
`LookupResult {"schema_version","disposition","receipt"}`;
`EffectEvidence {"schema_version","proposal_id","proposal_digest","payload_digest","target","fence","recovery","receipt_digest"}`;
`EffectDecision {"schema_version","kind","proposal_id","proposal_digest","fence","evidence","reason_code"}`.
Digests are `sha256:` + 64 lowercase hex (`model.py:13`).

#### 3. Concurrency & idempotency semantics

`EffectGateway.execute` (`gateway.py:49-74`): validate approval (kind approve, same id+digest) → canonical payload copy, digest must
equal `payload_digest` (before any provider call) → **lookup first** (adapter exception or non-`LookupResult` → indeterminate):
`applied` with correlating receipt → `already-applied`, uncorrelated → `indeterminate/indeterminate`; `superseded` → `superseded`;
`indeterminate` → `indeterminate`; `safe-to-retry` → continue → fetch **fresh** fence (exception/non-fence → `indeterminate` with
recovery `safe-to-retry`; fence ≠ approved fence in any field → `superseded`) → execute **once**; exception or non-correlating
receipt → second lookup (`_recover`) with the same classification; never a blind retry. Idempotency rests on the provider's
lookup by proposal identity and native conditional mutation on `target_head`.

#### 4. External dependencies

None (stdlib `hashlib`, `json`, `re`). Haskell: `crypton`, `petrus-json` canonical encoder (sorted keys, `ensure_ascii=False`,
Python escaping), `regex-tdfa` or hand-written lexers for the code/digest grammars.

#### 5. Upstream tests

`effect/test_contract.py` — 15 functions (≈30 cases; **hypothesis** `max_examples=60` canonical digest property over
dictionaries of text/int/bool/None/lists/dicts): round trips, digest canonicality, non-strict payload refusal, decoder refusals,
reject/approve distinctness, strict serialization, gateway paths (mismatch before lookup, no blind retry, already-applied,
lookup dispositions, each fence field refreshed, uncorrelated receipt, lookup crash, fence-source failures, digest-only evidence).
`effect/test_provider_neutrality.py` — 2 functions (3 cases): bulletin vs deployment adapters execute once and replay lookup-first;
provider CAS race → superseded. Pure, no I/O.

#### 6. Performance

Canonical-JSON hashing: payloads 1 KB / 100 KB / 1 MB (nested objects, Unicode strings), 10k digests each; `EffectGateway.execute`
with in-memory adapter, 100k calls.

#### 7. Better the Haskell way

`EffectDecision = Reject ReasonCode | Approve Fence | Outcome Fence Evidence` with `Evidence` recovery as
`Direct ReceiptDigest | Applied ReceiptDigest | NotApplied NonAppliedRecovery`, and decision kind derived from recovery
(removes the cross-field validator). `LookupResult = Applied Receipt | SafeToRetry | Superseded | Indeterminate`. Strict JSON
payload as a dedicated type without `Double` so the "no floats" rule is static.

#### 8. Packaging

Pure core of `petrus-agenticus` (`Petrus.Agenticus.Effect.*`); depends only on `petrus-json` and `crypton`. Parallel with everything.

---

### Agenticus core: cross-cutting tests, interop quirks, packaging summary

#### Test inventory (core only; counts from `testcounts.txt`)

| File | fns | Notes |
|---|---|---|
| `tests/petrus/agenticus/test_boundaries.py` | 5 | AST/import boundary checks; spawns `sys.executable -c` subprocess |
| `attachment/test_binding.py` / `test_episode.py` / `test_retention.py` | 5 / 9 / 15 | `LocalProcessEnvironment` (real `/bin/sh`) |
| `catalog/test_descriptor.py` / `test_resolution.py` | 5 / 13 | hypothesis; depends on `runtime.profiles.RUNTIME_PROFILES` |
| `connection/test_custody.py` | 21 | needs `cryptography` |
| `effect/test_contract.py` / `test_provider_neutrality.py` | 15 / 2 | hypothesis |
| `hands/test_contract_and_gateway.py` / `test_workspace.py` / `test_conformance.py` | 20 / 3 / 4 | one test needs **Docker** (hard failure if absent) |
| `program/test_agent_net.py` / `test_program_descriptor.py` | 21 / 3 | uses `petrus.engine.Engine`, `InMemoryHistoryStore`, `InlineDispatch` |
| `thread/test_continuation.py` / `test_identity_and_lifecycle.py` | 5 / 8 | pure |

Run config: `pyproject.toml [tool.pytest.ini_options]` — `--randomly-seed=1729`, `timeout = 180`; none of these tests carry the
opt-in markers (`real_provider_acceptance`, `real_gondolin_acceptance`, `qualification_installation`); no network, no Postgres,
no credentials. Conformance fixtures are read from `tests/petrus/agenticus/conformance/*.json` (directory required by
`test_boundaries.py:44-46`). Haskell ports should load the same fixture files directly (they are plain JSON).

#### Interop-critical quirks to preserve

1. `CompatibilityIssue.code` is open text (fixture has `no-candidate`); Catalog's `version-mismatch` subject is `kind@version`.
2. Python `str.strip()` whitespace set (incl. U+0085) in every `_text`; Haskell `Data.Char.isSpace` differs (U+0085) — use a
   Python-compatible predicate.
3. Integer fields reject JSON booleans and any number with fraction/exponent (`1.0`, `1e0`).
4. Byte (UTF-8) bounds for identities vs code-point bounds for Hands params vs ASCII-escaped-JSON byte bound in agent_net.
5. JSON encoders: custody payload `sort_keys` + `ensure_ascii=True` + Python float repr; territory capabilities `ensure_ascii=True`
   compact; effect digests `sort_keys` + `ensure_ascii=False`; History-visible agent_net payloads in **Python insertion order**
   (`LoopState` with `version` last).
6. Derived ids: `lease-`/`attachment-`/`reconcile-`/`abort-`/`prepare-` + `sha256(operation_id)[:32]`; stage file name
   `sha256(call_id)[:32]`.
7. Custody CAS: 8 attempts; reused `operation_id` → `OperationConflict`; `revision == len(audit)`.
8. Territory DB: positional `SELECT *` decode (column order), partial unique index on `(provider, operation_id) WHERE phase <> 'retired'`,
   `flock` writer fence on `.<name>.writer.lock`.
9. Agent-as-Net names (places, transitions, colors, activity names `agenticus.net.model-phase`/`agenticus.net.hands`,
   completion CEL `size(done) != 0`, anonymous handler display names) must match for net identity and History equality.

#### Packaging summary

Recommend one cabal package **`petrus-agenticus`** (matching upstream's single namespace; boundary tests apply per module) with
two internal layers, or two packages if build parallelism matters:

* `petrus-agenticus-core` (pure; deps `petrus-json`, `text`, `containers`, `crypton`): Catalog, Thread, Program.Descriptor/Seam,
  Effect, Hands.Contract/Grants/Conformance. Can start **now**, in parallel with the kernel port.
* `petrus-agenticus` (IO; deps core + SQLite binding + `unix` + `lukko`/`filelock` + `stm`/`async` + `petrus-motus` execution and
  activity types + `petrus-impetus` DSL/petrinet/binding + `petrus-cel`): Connection custody (no kernel dependency; can start now),
  Hands gateway (now) and workspace adapter (after Motus execution contract), Attachment/retention (after Motus execution +
  archive), Program.AgentNet (after Impetus DSL + Motus `ActivityInvocation`; tests after `petrus-engine`).
  The `runtime/` package (section 12) depends on all of the above.

## 12. Agenticus runtime adapters

Scope: 15 Python modules (12,361 lines including the 3 `.mjs` helpers). The package turns an Agenticus Episode Attachment, a Connection and a Hands grant into one bounded **runtime operation** (one Turn) driven through an external coding agent, and publishes a `RuntimeTurnSettlement`. All paths below are relative to `upstream/petrus`.

**How each adapter drives its agent (summary of the most interop-critical fact):**

| Adapter | External agent | Mechanism Petrus uses | SDK-only? | Haskell recommendation |
| --- | --- | --- | --- | --- |
| `claude.py` | Claude Code CLI 2.1.220 (bundled in the wheel) | Python `claude-agent-sdk==0.2.128` (`ClaudeSDKClient`), with an in-process SDK MCP server, a PreToolUse hook and a `SessionStore` mirror. The SDK speaks the CLI's undocumented `stream-json` control protocol. | **Yes.** Python library. Petrus never touches the CLI protocol itself, and it reads SDK private attributes (`_transport._process`, `_materialized.config_dir`). | **Keep a Python sidecar** pinned to the SDK. Do not reimplement the control protocol. |
| `codex.py` | `@openai/codex` CLI 0.145.0 (A2 Local), 0.146.0 (A3 Gondolin guest) | Stock CLI: `codex exec --json ...` writes JSONL events to stdout, one process per turn. **Not** the app-server JSON-RPC. | No | Speak it directly from Haskell (`typed-process` plus a JSONL parser). Keep the embedded Python `_HELPER_SOURCE` byte-identical, because it runs inside the Gondolin guest as `/usr/bin/python3`. |
| `pi.py`, `pi_application.py`, `pi_model_phase.py` | npm `@earendil-works/pi-coding-agent` / `pi-agent-core` / `pi-ai` 0.83.0 | Node libraries only (no Pi CLI is invoked; `dist/cli.js` is only probed for existence). Petrus ships its own `.mjs` bridges speaking an NDJSON protocol over stdin/stdout. | **Yes** (Node libraries), but the bridge protocol is Petrus-owned | Ship the three `.mjs` helpers verbatim as data files. Haskell spawns `node` and speaks the Petrus NDJSON protocol. |
| `amp.py` | `@ampcode/cli` 0.0.1785733786-gde6a10 | Python `amp-sdk==0.1.20260729121202`: `amp_sdk.execute(prompt, AmpOptions(executor="orb", ...))` async iterator. The SDK spawns the `amp` CLI with `--stream-json`/`--orb-execute`. | **Yes.** Python library. | Keep a Python sidecar (lowest risk). Direct CLI use is possible but the argv and event schema of `amp --stream-json` must first be extracted from the pinned SDK source, which is not vendored. |
| `agent_net_runner.py` | none (model calls go via `pi_model_phase`) | Petrus engine plus a JSONL history | n/a | Pure Haskell |

The unit tests for every adapter run against fakes (fake SDK modules, fake `codex`/`claude` shell scripts, fake `pi` `.mjs` SDKs run by a real `node`). Only the `*_real.py` files touch real CLIs or credentials, and each one sits behind an env var plus a marker.

Support status (docs/runtime-guide.md:61-98):

| Surface | Status |
| --- | --- |
| Pi A2 Local host lifecycle with the scripted runtime client (`compose_pi_a2_scripted_runtime`) | **Supported**, needs no credentials |
| Codex A3 Gondolin + Local Worker replay | Experimental, qualification-only. Uses a fake Gondolin SDK and a simulated Codex protocol. The fenced host service stores the terminal result before replying and can replay it without redispatch after a Local Worker is replaced. |
| `pi.native.a2.local` with the exact external Pi plus a live provider | Experimental, opt-in |
| Other binding-target descriptors | Experimental |
| `unqualified` cells | Unavailable |
| `unsupported` cells | Unsupported |

The pyproject extras `agenticus-amp` (`amp-sdk==0.1.20260729121202`) and `agenticus-claude` (`claude-agent-sdk==0.2.128`) (pyproject.toml:47-55) install the exact pins, but installing them does not promote either runtime to supported.

---

### Runtime foundation contracts (`installation.py`, `operation.py`, `result.py`)

#### 1. Responsibility and public API
- `installation.py` (144 lines) defines the probe vocabulary:
  - `ProbeDisposition` = `ready | not-installed | incompatible | unavailable`.
  - `InstalledComponent(name, version, source_identity)`: frozen and ordered, each text field at most 256 UTF-8 bytes.
  - `ProbeIssue(code, component=None)`.
  - `RuntimeInstallation(runtime: DescriptorIdentity[kind RUNTIME], adapter_contract_version>0, components, platform, architecture, capabilities)`. Components are unique by name and stored sorted. Capabilities match `[a-z][a-z0-9.-]{0,127}`.
  - `RuntimeProbeResult(runtime, disposition, installation=None, issues=())`. Shape rules (`_validate_probe_shape`, installation.py:108-120):
    - READY: installation present and no issues.
    - INCOMPATIBLE: installation present and issues.
    - NOT_INSTALLED: no installation and issues.
    - UNAVAILABLE: issues.
    - Issues are sorted and unique. `installation.runtime` must equal `runtime`.
- `operation.py` (87 lines):
  - `RuntimeCleanupDisposition` = `clean | not-created | unverified`.
  - `RuntimeOperationCleanup(operation_id, disposition, code, physical_erasure_guaranteed=False)`. Its `.verified` property means the disposition is CLEAN or NOT_CREATED.
  - `RuntimeProtocolError(code)`: the message is `"runtime protocol error: {code}"` and `.code` is a machine-safe token.
  - `RuntimeOperation` Protocol (semantics docstring at operation.py:65-78):
    - `wait(timeout)` raises `TimeoutError` and changes nothing. Once settled it returns the same immutable `RuntimeTurnSettlement`. After `close` it raises `RuntimeProtocolError("operation-closed")`.
    - `cancel(reason)` returns `CancellationDisposition` REQUESTED, ALREADY_REQUESTED or TOO_LATE.
    - `close()` is legal only once settled or after cancel was requested; otherwise it raises `"operation-active"`. It is idempotent and returns `RuntimeOperationCleanup`.
- `result.py` (77 lines): `RuntimeTurnSettlement(episode_id, turn_id, outcome: TurnOutcome, accepted_appends∈{0,1}, termination_code, output_reference, continuation_reference)`.
  - COMPLETED requires `accepted_appends == 1`.
  - `termination_code` matches `[a-z][a-z0-9.-]{0,127}`.
  - References are at most 512 bytes, already stripped, with no control characters.
  - `safe_termination_code(x)` maps any non-conforming code to a safe fallback.
- Kernel dependencies: `petrus.agenticus.descriptors` (DescriptorIdentity/Kind), `petrus.agenticus.thread` (TurnOutcome, CancellationDisposition).

#### 2. Wire formats
None are durable on their own. These are value types; their codes and strings appear verbatim inside the ledgers below.

Common cleanup codes across adapters:
- `client-not-created`, `client-closed`, `cleanup-uncertain`
- `client-cleanup-uncertain`, `private-cleanup-uncertain`, `provider-state-uncertain`, `host-cleanup-uncertain`

Common termination codes:
- `turn-completed`, `cancelled`, `provider-failed`, `provider-max-turns`, `cleanup-unverified`
- `command-timeout`, `command-superseded`, `output-overflow`, `command-signal`
- `restart-indeterminate`, `close-indeterminate`, `runtime-start-failed`

#### 3. Concurrency/durability
Pure values.

#### 4. Haskell
Plain ADTs with smart constructors. Use `Data.Text` and check UTF-8 byte length (not char length) for the 256- and 512-byte limits.

#### 5. Tests
`test_foundation.py` (6 tests, 190 lines) checks the shape rules and the operation protocol.

#### 6. Performance
Trivial.

#### 7. Better in Haskell / quirks
- Encode the probe-shape rules as a sum type (`Ready Installation | Incompatible Installation (NonEmpty Issue) | NotInstalled (NonEmpty Issue) | Unavailable (Maybe Installation) (NonEmpty Issue)`), so invalid shapes cannot be represented.
- Keep the `"runtime protocol error: "` message prefix.

#### 8. Packaging
Part of a `petrus-agenticus-runtime` library (module `Petrus.Agenticus.Runtime.Types`).

---

### Runtime profile matrix (`profiles.py`)

#### 1. Responsibility and public API
`profiles.py` (475 lines) holds the frozen qualification matrix:

| Enum | Values |
| --- | --- |
| `RuntimeFamily` | `amp, codex, claude, pi.native, pi.application-owned, agent-as-net` |
| `TerritoryProfile` | `amp.provider-managed, motus.local, motus.docker, motus.gondolin, motus.e2b` |
| `EmbodimentArchetype` | `A1..A5` |
| `QualificationExpectation` | `binding-target, unqualified, unsupported` |

Exports:
- `RUNTIME_PROFILES` (the table, profiles.py:285-466).
- `CV16_HANDS_TERRITORY_TARGETS = {LOCAL, DOCKER, GONDOLIN, E2B}`.
- `territory_identity(t) = DescriptorIdentity(TERRITORY, t.value, 1)`.
- One `CapabilityDescriptor` constant per runtime binding.

#### 2. Wire formats
Each runtime binding descriptor comes from `_runtime_descriptor` (profiles.py:109-139):
- `identity = DescriptorIdentity(RUNTIME, name, 1)`.
- `offers = {archetype.aN, loop.*, topology.*, ...}`.
- `requires` = capability requirements on CONNECTION, PROGRAM and HANDS; TERRITORY `name=territory.value` with contract 1; CONTINUATION; and EFFECT `"effect.host-fenced"`.

| Runtime descriptor | connection | program | hands | continuation | loop | topology |
| --- | --- | --- | --- | --- | --- | --- |
| `amp.a1.provider-managed` | connection.amp | program.provider-owned | hands.provider-managed | continuation.amp-native | loop.provider-owned | topology.provider-managed |
| `codex.a2.local` | connection.codex | program.provider-owned | hands.collocated | continuation.codex-native | loop.provider-owned | topology.durable-collocated |
| `codex.a3.gondolin` | connection.codex | program.provider-owned | hands.collocated | continuation.codex-native | loop.provider-owned | topology.ephemeral-collocated + topology.episode-collocated |
| `claude.a2.local` | connection.claude | program.provider-owned | hands.collocated | continuation.claude-native | loop.provider-owned | topology.durable-collocated |
| `pi.native.a2.local` | connection.pi-compatible | program.harness-owned | hands.collocated | continuation.pi-native | loop.harness-owned | topology.durable-collocated |
| `pi.native.a4.gondolin` / `.a4.e2b` | connection.pi-compatible | program.harness-owned | hands.capability-scoped | continuation.pi-native | loop.harness-owned | topology.split |
| `pi.application-owned.a5.gondolin` / `.a5.e2b` | connection.pi-compatible | program.application-owned | hands.capability-scoped | continuation.application-owned | loop.application-owned | topology.split |
| `agent-as-net.a5.local` | connection.model-call | program.net-owned | hands.capability-scoped | continuation.net-owned | loop.net-owned | topology.application-owned |

Cells by expectation:
- **Binding targets:** AMP×provider-managed; CODEX×{LOCAL, GONDOLIN}; CLAUDE×LOCAL; PI_NATIVE×{LOCAL, GONDOLIN, E2B}; PI_APP×{GONDOLIN, E2B}; AGENT_AS_NET×LOCAL.
- **Unsupported:** PI_APP×provider-managed and AGENT_AS_NET×provider-managed.
- **Unqualified:** every other cell. Each carries a written reason string that must be preserved verbatim.

#### 3. Concurrency/durability
Static data.

#### 4. Haskell
Generate the table as a literal `[(RuntimeFamily, TerritoryProfile, Expectation, Maybe Descriptor, Text)]` and test it against a JSON dump produced from Python.

#### 5. Tests
`test_profiles.py` (6 tests, 235 lines) checks exact cell coverage (6×5), the descriptor shapes and the reasons.

#### 6. Performance
n/a.

#### 7. Better in Haskell / quirks
- Use total `Bounded`/`Enum` instances so cell coverage is checked by the compiler.
- Keep every string value (descriptor names, reasons) byte-identical, because they feed `ResolutionSnapshot` fingerprints.

#### 8. Packaging
Module `Petrus.Agenticus.Runtime.Profiles`.

---

### Claude adapter (`claude.py`, A2 Local) — SDK-ONLY

#### 1. Responsibility and public API
`claude.py` (1473 lines) runs one Claude Code turn locally. Claude Code's only tools are the five Petrus Hands methods, exposed through an in-process SDK MCP server. The adapter publishes the turn and stores a native continuation (the session transcript).

Public API:
- `ClaudeRuntimeAdapter(config, connection_custody, continuation_operations, turn_operations, ...)`, claude.py:812.
  - `.probe() -> RuntimeProbeResult`
  - `.start(invocation) -> RuntimeOperation`
- Protocols:
  - `ClaudeContinuationOperations.store(op_id, payload) -> ref` and `.load(ref)`
  - `ClaudeTurnOperations.store_turn(op_id, final_text) -> ref`
  - `ClaudeConnectionCustody`: `materialize`, `admit_result`, `release` (claude.py:682)
- `ClaudeContinuationCodec`.

Kernel dependencies:
- `agenticus.connection.custody` (Materialization, LeaseMode, AttachmentFence)
- `agenticus.attachment.episode.EpisodeAttachment`
- `agenticus.hands` (HandsGateway, ToolMethod, MAX_* schema limits)
- `motus` (MotusAttachmentBinding, provider `"local-process"`)
- `agenticus.continuation`, `agenticus.thread`

Pins (claude.py:75-80):
- `CLAUDE_SDK_VERSION="0.2.128"`, commit `ec776735b0eb8a8286827a005b35be1782e1940c`.
- `CLAUDE_CODE_VERSION="2.1.220"`, distribution commit `7ef6eec9d9ba84ea6f233f26c45f1df5c5991843`.
- Component sources: `pypi:claude-agent-sdk==0.2.128#commit=…` and `bundled:claude-code==2.1.220#commit=…`.

Descriptor IDs (claude.py:82-100):

| Kind | ID | Capability |
| --- | --- | --- |
| program | `claude.provider-managed` | `program.provider-owned` |
| continuation | `claude.native` | `continuation.claude-native` |
| connection | `claude.api-key` | `connection.claude` |
| hands | `claude.collocated` | |
| territory | `motus.local` | |

#### 2. Wire formats and protocols

**How the agent is driven.** The adapter builds a `ClaudeSDKClient(options=ClaudeAgentOptions(**opts))` (claude.py:518-591; options at 1157-1178) with:
- `tools = allowed_tools = _TOOLS`, where `_TOOLS = ("mcp__petrus_hands__workspace_read", "…workspace_search", "…workspace_shell", "…workspace_write", "…workspace_test")`, one per `ToolMethod`.
- `strict_mcp_config=True`, `permission_mode="dontAsk"`.
- `setting_sources=[]`, `skills=[]`, `plugins=[]`, `agents={}`.
- `model=config.model`, `fallback_model=None`, `cwd=working_directory`, `cli_path=<wrapper>`, `env=<below>`.
- `max_turns` (default 32), `max_budget_usd` (default 10), `max_buffer_size=max_message_bytes` (default 1,000,000).
- `session_store=_SessionStore`, `session_store_flush="eager"`, `resume=prior.session_id`.
- `stderr` set to a discard callback.
- `mcp_servers={"petrus_hands": sdk.create_sdk_mcp_server("petrus_hands", tools=[sdk.tool(method, "Agenticus workspace capability", schema)(handler)…])}`.
- `hooks={"PreToolUse":[HookMatcher(matcher=None, hooks=[hook])]}`.

Each turn runs `connect()`, then `query(prompt, "default")`, then drains `receive_response()`. On cancel it calls `interrupt()` (shielded, bounded by `cancellation_grace`). It finishes with `disconnect()`.

The SDK spawns the CLI and speaks its `stream-json` control protocol. That protocol is **not** reproduced in Petrus. From general SDK knowledge, not verified against the 0.2.128 source (it is not vendored or installed here), it consists of:
- `--output-format stream-json --input-format stream-json --verbose`
- `control_request` / `control_response` frames for `initialize` (hook registration), `hook_callback`, `mcp_message` (in-process MCP server traffic) and `interrupt`.

**Tool JSON schemas** (claude.py:131-171) are built from the `hands.contract` limits (`MAX_PATH_CHARS` etc.) and must be reproduced exactly.

**PreToolUse hook** (claude.py:527-550):
- It denies the call if the tool name is not in `_TOOLS`, `tool_use_id` is not a string, `agent_id`/`agent_type` is present (no subagents), or the input is not a dict. The deny response is:
  `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"unsupported-tool"}}`
- Otherwise it enqueues the `tool_use_id` under the key `(name, canonical_input)` and returns `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}`.
- `canonical_input = json.dumps(args, sort_keys=True, separators=(",",":"), allow_nan=False)`, at most 8192 bytes (claude.py:653).

**MCP handler** (claude.py:553-584):
- It pops the oldest matching `tool_use_id`. With no match it returns `{"content":[{"type":"text","text":"unsupported-tool"}],"is_error":true}`.
- Otherwise it calls `gateway.submit` with:
  `{"version":1,"call_id","episode_id","attachment_id","attachment_epoch","grant_epoch","method","params"}`
- It returns `{"content":[{"type":"text","text":json.dumps(result.to_data(),separators=(",",":"))}],"is_error":not result.ok}`.

**Credential environment** (`_AUTH_ENVIRONMENT`, claude.py:109-129). These are set to `""` so ambient credentials cannot leak in:
- `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`, `CLAUDE_CODE_OAUTH_TOKEN`
- `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_FOUNDRY`, `CLAUDE_CODE_USE_VERTEX`
- `AWS_ACCESS_KEY_ID`, `AWS_CONTAINER_CREDENTIALS_FULL_URI`, `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`, `AWS_PROFILE`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_WEB_IDENTITY_TOKEN_FILE`
- `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`
- `GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_CLOUD_PROJECT`

It then sets `ANTHROPIC_API_KEY=<materialized key>` and `CLAUDE_CONFIG_DIR=<per-op private root>`.

**CLI wrapper** `claude-launcher` (`_install_cli_wrapper`, claude.py:1355-1402):
- It is a `python -I` script, created `O_EXCL|O_NOFOLLOW` with mode 0700 and fsynced.
- It rebuilds the environment from scratch: `HOME=$CLAUDE_CONFIG_DIR`, `PATH=os.defpath`, `LANG=LC_ALL=C.UTF-8`. It passes through only `ANTHROPIC_API_KEY`, `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_ENTRYPOINT` and `CLAUDE_AGENT_SDK_VERSION`.
- It then `execve`s the real CLI with the SDK's argv.

**SessionStore mirror** (`_SessionStore`, claude.py:290-388). It mirrors the SDK `SessionStore` protocol by shape:
- `append(key={"project_key","session_id"}, entries)` deduplicates by the entry's `"uuid"`; a conflicting duplicate raises.
- `load(key)`, `seed(transcript)`, `snapshot(session_id)`.

**Continuation payload** `ClaudeContinuationPayloadV1` (claude.py:242):
- `session_id`: a canonical lowercase UUID v1-5 (`_UUID`, claude.py:103).
- `project_binding = sha256(str(working_directory)).hexdigest()`.
- `project_key`: at most 512 bytes.
- `transcript` bytes and `schema_version=1`.
- Transcript canonical form: `json.dumps(entries, separators=(",",":"), ensure_ascii=False, sort_keys=True)` (UTF-8). Decoding re-encodes and requires **byte-identical** output. Limits are 10,000 entries and 4,000,000 bytes.

**Message classification** (claude.py:625-652):

| SDK message | Classified as |
| --- | --- |
| `ResultMessage` | `_Result(subtype,is_error,session_id,terminal_reason,result)` |
| `MirrorErrorMessage` | `session-store-failed` |
| `UserMessage`, `AssistantMessage`, `SystemMessage`, `StreamEvent`, `RateLimitEvent` | counted events |
| anything else | `RuntimeProtocolError("unknown-message")` |

- Message size is `len(json.dumps(asdict(m), sort_keys=True, ensure_ascii=False).encode())`.
- Exactly one result is allowed, and its `session_id` must equal the prior session when resuming.
- Success requires `subtype=="success"`, `not is_error` and `terminal_reason=="completed"`; anything else is `provider-failed`.
- Final text is sanitized: ANSI escapes stripped and control characters other than `\n\r\t` replaced with U+FFFD.

**Disconnect verification** (claude.py:605-623) reaches into SDK **private** attributes:
- `client._transport._process.returncode` must be set, else `client-cleanup-uncertain`.
- `client._materialized.config_dir` (the SDK's resume temp dir) must no longer exist, else `private-cleanup-uncertain`.

#### 3. Concurrency and durability semantics
- One daemon thread per operation runs an asyncio loop. A `threading.Condition` guards the `_cancelled`/`_publishing` flags.
- `_operations` maps op_id to an operation with a `_Key` idempotency key. The same op_id with a different key raises `operation-conflict`.
- Execute flow (claude.py:1072-1275):
  1. Seed the session store.
  2. `materialize(connection_id, host_id, LeaseMode.READ, ttl=min(credential_ttl, remaining), operation_id=f"{op}.materialize")`.
  3. Check the fence (attachment coordinates, authority_epoch, base_version).
  4. Read the credential (at most 8192 bytes, UTF-8).
  5. `mkdtemp(prefix="operation-")` under `runtime_root` (0700, owned by the user).
  6. connect, query, drain (poll every 0.05 s).
  7. disconnect.
  8. `claim()` the publication.
  9. `admit_result(fence)`.
  10. `store_turn`.
  11. `codec.store` (continuation).
  12. Settle COMPLETED / `turn-completed`.
  13. `release(f"{op}.release")` and remove the private root after an identity check against `(st_dev, st_ino)`.
- Any failure while the operation is no longer current becomes CANCELLED / `cancelled`. Cleanup that is not verified becomes FAILED / `cleanup-unverified` with UNVERIFIED.
- Durability is delegated entirely to the injected operations. The adapter stores nothing durably and has no restart replay. Credentials exist only in process memory, the child env and the 0700 private root, which is deleted.
- `close()` joins for `disconnect_timeout(≥25) + cancellation_grace`.

#### 4. External dependencies and Haskell equivalents
- `claude-agent-sdk==0.2.128` (Python) and its bundled `_bundled/claude` CLI 2.1.220. **No Hackage equivalent.**
- **Recommendation: keep a Python sidecar.** It would be a tiny `petrus-claude-helper` process speaking a Petrus-owned NDJSON protocol modelled on `pi_helper.mjs` (start → tool_call/tool_result → complete/failed). Reasons:
  - (a) the CLI control protocol is undocumented and changes per CLI release;
  - (b) the adapter depends on SDK internals (session-store mirroring, `_materialized`, MCP-in-process);
  - (c) the whole cell is experimental.
- Implementing `stream-json` control directly in Haskell (`typed-process` + `aeson`) is feasible but must be re-qualified against each CLI pin. Treat it as a later optimisation.

#### 5. Upstream tests
- `test_claude.py` (32 tests, 1138 lines) uses a fake SDK module and a fake CLI (`#!python` printing `"2.1.220 (Claude Code)"`).
- `test_claude_real.py` (2 tests, 460 lines):
  - `qualification_installation` + `PETRUS_CV16_CLAUDE_QUALIFY=1` runs a credential-free probe.
  - `real_provider_acceptance` + `timeout(900)` + `PETRUS_CV16_CLAUDE_LIVE=1` + `PETRUS_CV16_CLAUDE_AUTH_FILE` (+ `PETRUS_CV16_CLAUDE_MODEL`, default `claude-sonnet-4-5`) runs a live G1→G2 resume.

#### 6. Performance
Dominated by the provider. Overheads to keep low: transcript canonicalization (up to 4 MB, re-encoded twice) and per-message `asdict` sizing. Benchmark: a scripted fake CLI emitting 10k messages, measuring the adapter's overhead per message.

#### 7. Better in Haskell / quirks to preserve
- The probe (claude.py:853-976):
  - `importlib.metadata.version("claude-agent-sdk")` must equal the pin.
  - CLI resolution order: `cli_path`, then the bundled `_bundled/claude[.exe]` beside the SDK, then `which claude`.
  - `claude --version` (timeout 10) is matched with `([0-9]+\.[0-9]+\.[0-9]+)`.
  - Required SDK symbols and option fields are checked (claude.py:922-960).
  - Capabilities: `{runtime.cancel, runtime.continue, runtime.local, runtime.provider-managed}`.
- A sidecar should re-expose the same probe result fields.
- Preserve the duplicate-`uuid` dedup semantics and the canonical transcript bytes. Continuation references stored by Python must load in Haskell.

#### 8. Packaging
`petrus-agenticus-runtime-claude` (Haskell host side) plus a Python helper distributed with a `uv`-locked environment pinning `claude-agent-sdk==0.2.128`.

---

### Codex adapter (`codex.py`, A2 Local and A3 Gondolin)

#### 1. Responsibility and public API
- `CodexRuntimeAdapter` (codex.py:665) runs `codex exec` once per turn with file-based auth (`auth.json`) and a native rollout continuation.
- `CodexGondolinRuntimeAdapter(CodexRuntimeAdapter)` (codex.py:1127) runs the same flow inside a Gondolin VM through Motus private-file and command primitives.
- `_CodexGondolinActivityAdapter` (codex.py:1370) exposes it as an Impetus Activity.

Protocols:
- `CodexContinuationOperations.store` / `load`
- `CodexTurnOperations.store_turn(op_id, thread_id, final_text)`
- `CodexConnectionCustody`: `materialize`, `activate`, `admit_result`, `checkpoint`, `release` (codex.py:213)

Pins (codex.py:74-87):
- `CODEX_VERSION="0.145.0"`, commit `1e85ca099e4265bf89f4016772d299816e231bb3`, npm integrity `sha512-/PSPSFujjjmiyVFvG2yu/grOFhsWdokTH8t2KGWhXSo/M5n/dIDsnbsnO82/7bLtIoDuzQf7ATBUMWqPWQINlQ==`. Source `npm:@openai/codex@0.145.0#commit=…#integrity=…`.
- Gondolin: `CODEX_GONDOLIN_VERSION="0.146.0"`, `CODEX_GONDOLIN_SDK_VERSION="0.12.0"`, image `petrus-cv10-agents:amp1785543452-codex01460-gondolin0120`, build `49aac5ff-ea3f-5f46-a67a-cdc613ac4827`, OCI `sha256:9c7e769eb44f37b1e802c55dc43ee222e7b6c907fad3de8c01404a3b6c61124f`. Source `gondolin:IMAGE#build=…#oci=…`.
- Activity name `petrus.agenticus.codex.gondolin`.

IDs:

| Kind | ID |
| --- | --- |
| program | `codex.provider-managed` |
| continuation | `codex.native-rollout` |
| connection | `codex.file-auth` |
| hands | `codex.collocated` |
| territory | `motus.local` / `motus.gondolin` |

#### 2. Wire formats and protocols

**Process invocation** (codex.py:885-1124):
```
codex exec --json --color never --sandbox read-only \
  --config cli_auth_credentials_store=file --skip-git-repo-check \
  --ignore-user-config --ignore-rules [resume <thread_id>] -- <prompt>
```
- env: `{LANG:"C.UTF-8", NO_COLOR:"1", PATH:<execution_path>}`.
- Private root: `CODEX_HOME=<auth private dir>`.
- Locally, `execution_path = dirname(codex) + dirname(node) + os.defpath`. In Gondolin the guest uses `/usr/local/bin/codex` with `PATH=/usr/local/bin:/usr/bin:/bin`.
- The command runs through the Motus environment (`is_current` predicate, `command_timeout` default 300, `output_limit = MAX_COMMAND_OUTPUT_BYTES`).
- Error mapping:

  | Condition | Code |
  | --- | --- |
  | timeout | `command-timeout` |
  | superseded | `command-superseded` |
  | truncated | `output-overflow` |
  | rc<0 | `command-signal` |

**JSONL event protocol** (`_parse_jsonl`, codex.py:435-522), one JSON object per stdout line:
- Allowed `type` values: `thread.started`, `turn.started`, `item.started`, `item.updated`, `item.completed`, `turn.completed`, `turn.failed`, `error`.
- Event 1 must be `{"type":"thread.started","thread_id":<uuid>}`. On resume, `thread_id` must equal the prior one.
- Event 2 must be `turn.started`.
- The last event must be terminal:
  - `turn.completed` requires rc==0 and a `usage` object.
  - `turn.failed` requires rc==1 and `error.message`.
- Allowed item types: `agent_message`, `reasoning`, `command_execution`, `file_change`, `mcp_tool_call`, `collab_tool_call`, `web_search`, `todo_list`, `error`.
- A duplicate terminal for the same item is a protocol error.
- The final text is the latest **completed** `agent_message.text`, sanitized (ANSI and control characters).

**Private helper `_HELPER_SOURCE`** (codex.py:277-400): an embedded Python program run as `(python, "-c", SRC, mode, …)`.
- Private roots: `CODEX_HOME=auth_ref` and `PETRUS_CODEX_ROLLOUT_ROOT=rollout_ref`. Output limit 512 bytes.
- Modes:
  - `stage <thread> <relative>` writes the prior rollout into `$CODEX_HOME/<relative>`.
  - `collect <thread>` finds exactly one `sessions/**/rollout-*-<thread>.jsonl`, copies it to the leaf `rollout.jsonl`, scrubs everything except `auth.json` and prints `{"ok":true,"rollout_path":"<relative>"}`.
  - `scrub` removes provider state.
- Failure exits with 64. Stdout is parsed with an exact key set (`_parse_helper`, codex.py:403).
- The rollout path must match `sessions/YYYY/MM/DD/rollout-[A-Za-z0-9_.-]+-<uuid>\.jsonl` (codex.py:113).

**Continuation** `CodexContinuationPayloadV1` (codex.py:165): `(thread_id uuid, rollout_path, rollout bytes ≤ MAX_PRIVATE_FILE_BYTES)`.

**Probe:**
- `which codex` and `which node`.
- `codex --version` must fullmatch `codex-cli (\S+)` with the pinned version.
- `codex exec --help` must mention every flag above.
- `codex exec resume --help` must contain `SESSION_ID`.
- Gondolin probe (credential-free):
  - Writes the private file `agenticus-codex-a3-before`, reads it back as `after`.
  - `codex --version`.
  - `/bin/uname -m` must equal `aarch64`; platform is `linux`.
  - It records the qualified `(lease_identity, attachment_id)` pair. Starting on an unqualified pair raises `territory-not-qualified`.

#### 3. Concurrency and durability semantics
Custody order (the subscription-style refresh flow):
1. `materialize(..., LeaseMode.REFRESH, op+".materialize")`
2. `activate(op+".activate")`
3. Import private files: `auth.json` (from `home.read()`) and `rollout.jsonl` (prior or empty).
4. `stage` (only on resume).
5. `codex exec`
6. `collect`
7. Export `auth.json` and `rollout.jsonl`.
8. `home.replace(auth)`, which captures the refreshed token.
9. `codec.store(rollout)`
10. `store_turn` (only if completed)
11. Delete the private files.
12. `claim`
13. `admit_result(fence)`
14. `checkpoint(op+".checkpoint")`, which must yield `state_version == base+1`.

- A `turn.failed` turn settles FAILED `provider-failed` but **still returns the continuation reference**, since the rollout is valid.
- In-memory operations dict, idempotency `_Key` dataclass (codex.py:526), and a per-op thread, all as in Claude.
- Credentials (auth.json) live only in the Motus private-file store and the connection home. They never enter the continuation or turn bodies.
- A3 durability lives in the Gondolin runtime service (next component).

#### 4. External dependencies and Haskell equivalents
- No SDK is involved. Haskell can drive `codex exec --json` directly:
  - `typed-process` (or the Motus Haskell port's command API)
  - `aeson` with a strict JSONL line splitter
  - `regex-tdfa` for the rollout and version regexes
- Keep `_HELPER_SOURCE` as an opaque `ByteString` constant, because it executes in the guest's `/usr/bin/python3`; a Haskell binary cannot run there.
- A Haskell reimplementation of the helper is acceptable for the **Local** cell only if the bytes produced (paths and file modes) are identical. Simpler to keep one helper for both cells.

#### 5. Upstream tests
- `test_codex.py` (41 tests, 2389 lines): fake `codex` shell scripts, the JSONL protocol matrix (`test_jsonl_protocol_fails_closed`, `…rejects_protocol_drift…`), helper stage/collect/scrub against a real python, and fake `uname` printing `aarch64`.
- `test_codex_real.py` (2 tests, 569 lines):
  - `real_provider_acceptance` + `PETRUS_CV16_CODEX_LIVE=1` (+ `PETRUS_CV16_CODEX_BIN`, `OPENAI_API_KEY`).
  - `real_gondolin_acceptance` + `PETRUS_CV16_CODEX_GONDOLIN_LIVE=1` + `PETRUS_REAL_GONDOLIN_SDK_MODULE`, `PETRUS_REAL_GONDOLIN_IMAGE` (must equal the pin), `PETRUS_REAL_GONDOLIN_BUILD_ID`, `PETRUS_CV16_CODEX_AUTH_FILE`.
- `codex_worker_support.py` (26 lines) is an importable activity registry for a subprocess Local Worker. It wraps `_CodexGondolinActivityClient`. If `PETRUS_CODEX_GONDOLIN_WITHHOLD=<marker>` is set, the first worker to create the marker sleeps 3600 s after receiving the result, which simulates a worker lost after the service stored the terminal result. Used by the replay-without-redispatch tests.
- Related DST tests: `tests/dst/test_generated_runtime_qualification.py` (5) and `test_generated_runtime_world.py` (4).

#### 6. Performance
JSONL parsing of up to `MAX_COMMAND_OUTPUT_BYTES` per turn. Benchmark: parse a 10 MB synthetic event stream and compare with Python `_parse_jsonl`. Haskell should be at least 5× faster with strict `ByteString.lines` + `aeson`.

#### 7. Better in Haskell / quirks to preserve
- Model the event stream as a small state machine type, so the "first `thread.started`, then `turn.started`, last terminal" rule is checked structurally.
- Preserve:
  - rc coupling (completed ⇔ rc 0, failed ⇔ rc 1);
  - "latest completed agent_message wins";
  - the continuation being returned on failure;
  - `checkpoint` asserting `base+1`.

#### 8. Packaging
`Petrus.Agenticus.Runtime.Codex` in `petrus-agenticus-runtime`, with the helper source embedded via `file-embed` from a checked-in `codex_private_helper.py` whose bytes equal the upstream string.

---

### Codex Gondolin runtime service (`_codex_gondolin_service.py`)

#### 1. Responsibility and public API
A host-side, process-fenced Unix-socket service (636 lines). It owns one pre-provisioned Episode Attachment and executes Codex A3 operations **at most once**. Its rules:
- The terminal result is stored **before** replying.
- A retried request with the same `operation_id` replays the stored terminal without redispatch.
- An in-flight row found after a crash is fenced as indeterminate.

Classes:
- `_CodexGondolinRuntimeService(endpoint, ledger, token, adapter: CodexGondolinRuntimeAdapter, connection: READY ConnectionView, attachment: EpisodeAttachment)` (line 170).
- `_CodexGondolinActivityClient` (line 569), used by Local Workers as the activity `agenticus.codex.a3.gondolin`.

#### 2. Wire formats (VERBATIM)

Environment variables:
- `PETRUS_CODEX_GONDOLIN_ENDPOINT`: socket path.
- `PETRUS_CODEX_GONDOLIN_TOKEN`: 32..256 printable ASCII characters.

Limits (lines 35-42):

| Limit | Value |
| --- | --- |
| request | ≤ 64 KiB |
| response | ≤ 16 KiB |
| frame timeout | 1.0 s |
| close timeout | 2.0 s |
| schema version | 1 |

DDL (`_DDL`, lines 43-50):
```sql
CREATE TABLE operations (
 operation_id TEXT PRIMARY KEY NOT NULL,
 request_fingerprint TEXT NOT NULL
  CHECK(length(request_fingerprint)=64 AND request_fingerprint NOT GLOB '*[^0-9a-f]*'),
 phase TEXT NOT NULL CHECK(phase IN ('executing','terminal')),
 terminal BLOB,
 episode_id TEXT NOT NULL, turn_id TEXT NOT NULL,
 CHECK((phase='executing' AND terminal IS NULL) OR (phase='terminal' AND terminal IS NOT NULL)))
```

Connection setup:
- `PRAGMA journal_mode=WAL` must return `("wal",)`.
- `PRAGMA synchronous=FULL`, connection `timeout=2`.
- On a fresh DB: `PRAGMA quick_check` must return `ok`, then create the table and set `PRAGMA user_version=1`.
- On an existing DB, it validates via `PRAGMA table_info` (name, type, notnull, pk), compares normalized DDL against `sqlite_master.sql`, checks `user_version==1`, and parses every row.

Startup recovery:
```sql
UPDATE operations SET phase='terminal', terminal=? WHERE phase='executing'
```
The bound value is `{"error":"operation-indeterminate","ok":false}`.

Request handling, all under the execution lock:
1. `SELECT request_fingerprint,phase,terminal FROM operations WHERE operation_id=?`
   - fingerprint mismatch → `operation-conflict`
   - `executing` → `operation-indeterminate`
   - `terminal` → replay the stored blob
2. `INSERT INTO operations VALUES(?,?,'executing',NULL,?,?)`
3. Execute the adapter.
4. `UPDATE operations SET phase='terminal',terminal=? WHERE operation_id=? AND phase='executing'` (rowcount must be 1).
5. Reply.

`runtime-failed` results are persisted as terminal too.

Canonical JSON: `json.dumps(v, sort_keys=True, separators=(",",":"), ensure_ascii=True)`.
- **ASCII-escaped**: unlike the other stores, `\uXXXX` is used for non-ASCII.
- The `terminal` blob is canonical JSON with no newline.
- Frames on the wire are canonical JSON plus `"\n"`.

Request:
- `{"input":{...},"operation_id":…,"token":…,"version":1}`, with exact keys.
- It must be byte-canonical, i.e. it must re-serialize to the identical bytes.
- `token` is checked with `hmac.compare_digest`.

`input` keys: `version, episode_id, turn_id, prompt, attachment_id, attachment_epoch, connection_id, authority_epoch, state_version, continuation`.

`request_fingerprint = sha256(_json_bytes({"version":1,"operation_id":…,"input":…})).hexdigest()`.

Reply:
- Success: `{"ok":true,"result":{…}}`.
- Error: `{"ok":false,"error":<code>}`, where code ∈ {`unauthorized`, `frame-too-large`, `request-invalid`, `operation-conflict`, `operation-indeterminate`, `runtime-failed`}.
- Result fields (exact): `version`(1), `operation_id`, `episode_id`, `turn_id`, `outcome`, `accepted_appends`, `termination_code`, `output_reference`, `continuation_reference`, `cleanup:{disposition,code}`.
- Strings are 1..4096 characters or null.

#### 3. Concurrency and durability
- The fence is `<state>/.service.lock`:
  - The state dir must be 0700, owned by the euid, and not a symlink.
  - The lock file is 0600, opened `O_RDWR|O_CREAT|O_NOFOLLOW`, then `flock(LOCK_EX|LOCK_NB)`. Failure raises `runtime-service-owned`.
  - The fence remembers the owning pid; a fork raises `runtime-service-owner-invalid`.
- The endpoint and ledger must share the parent directory.
- Socket: `AF_UNIX SOCK_STREAM`, chmod 0600, `listen(8)`, one frame per connection, served by an accept thread. Execution is serialized by a single `threading.Lock`.
- Client: `_CodexGondolinActivityClient` heartbeats `{"phase":"runtime"}` with recv timeout `min(0.25, heartbeat_timeout/3)`, and heartbeats on each timeout.

#### 4. Haskell
- `network` (Unix sockets), `unix` (`System.Posix.IO` flock via `lukko` or `filelock`, file modes)
- `direct-sqlite` or `sqlite-simple`
- `crypton` (SHA-256), `memory` (constant-time `eq` on `ScrubbedBytes`/`Bytes`)
- `petrus-json` for canonical output, which must support an `ensure_ascii=True` mode

#### 5. Tests
Covered inside `test_codex.py` (ledger validation, replay, indeterminate fence, conflict) and `codex_worker_support.py`. No dedicated file.

#### 6. Performance
One request per turn, so latency is irrelevant. The fsync-heavy WAL+FULL configuration is intentional.

#### 7. Better in Haskell / quirks to preserve
- The canonical-request check rejects clients that do not emit sorted, ASCII-escaped JSON. The Haskell client must emit exactly that.
- Preserve:
  - the startup rewrite of `executing` → indeterminate terminal;
  - the byte-exact `{"error":"operation-indeterminate","ok":false}` blob;
  - the normalized-DDL check, which means the DDL text must be **identical**, whitespace included, for a Python-created DB to validate under Haskell and vice versa.

#### 8. Packaging
Module `Petrus.Agenticus.Runtime.Codex.GondolinService`, plus an executable `petrus-codex-gondolin-service` if the host runs it out of process.

---

### Pi native adapter (`pi.py` + `pi_helper.mjs`) — Node-library bridge

#### 1. Responsibility and public API
`PiRuntimeAdapter` (pi.py:981) drives Pi's harness-owned coding agent for A2 Local, A4 Gondolin and A4 E2B (`territory_profile`). Three auth profiles:

| Profile | Connection ID |
| --- | --- |
| `api-key` | `pi.compatible-api-key` |
| `native-subscription` | `pi.native-subscription` |
| `cc-patch-subscription` | `pi.cc-patch-subscription` (uses the `pi-cc-patch` extension) |

API:
- `.probe()`, `.start(invocation)`, `.evict(op_id)`, `.receipt(op_id)`
- `pi_durable_work_fingerprint(...)` (pi.py:449-495) and `pi_durable_fingerprint(config, inv)` (pi.py:498)
- Protocols `PiContinuationOperations`, `PiTurnOperations`, `PiConnectionCustody` (pi.py:844)
- `PiContinuationCodec`

Pins (pi.py:72-93):
- `PI_SDK_VERSION = PI_AI_VERSION = "0.83.0"`, commit `6e48c10f5b1f5cfc90d6cb21abf26a3e1e8a6bd7`.
- `pi-cc-patch` 1.0.1, commit `1891a39e3e1c61e37f950159fdc51de1ecffce84`, npm sha512 `1yxwj/4K3RIT+zAcngpL6yQ3QHwYDx6oJ+F7vQU4SHGotspqexPfSTxlSgzdtVD35jrqbTSeccwQrE5cjdVXlg==`, plus a pinned `index.ts` sha256.
- Catalogs:
  - API_KEY: `(anthropic, claude-sonnet-4-5)`, `(openrouter, anthropic/claude-sonnet-4.5)`, `(openai, gpt-5.6-sol)`
  - SUBSCRIPTION: `(anthropic, claude-sonnet-4-5)`, `(openai-codex, gpt-5.6-sol)`
  - CC_PATCH: `(anthropic, claude-sonnet-4-5)`

#### 2. Wire formats and protocols

**Process:**
```
Popen((node, <pkg>/pi_helper.mjs, <pi-coding-agent entrypoint>, <cc-patch index.ts> | "--no-extension"),
      env={HOME:<private root>, PATH:dirname(node), LANG:"C.UTF-8", LC_ALL:"C.UTF-8"},
      start_new_session=True, stdin=PIPE, stdout=PIPE, stderr=PIPE (drained))
```
See pi.py:580-841. The helper sets `umask 077`.

**Framing:** NDJSON in both directions. Host frames are `json.dumps(v, separators=(",",":"), ensure_ascii=False, allow_nan=False) + "\n"`. Each frame is at most `max_frame_bytes` (default 14 MiB, hard cap 16 MiB).

Host → helper:
- `start`:
  ```
  {"type":"start","version":1,"provider","model","prompt","cwd","root",
   "session_id":<prior or uuid4>,"session":<b64 jsonl>|null,
   "schemas":{<granted method>:<JSON schema>},
   "limits":{"frame","output","session","events","tools"[,"auth"]},
   "api_key":<str>  |  "auth":<b64 auth.json>}
  ```
- `{"type":"tool_result","id","result":<ToolResult.to_model_data()>}`
- `{"type":"abort"}`, sent on cancel or wall deadline.

Helper → host:
- `{"type":"ready"}`
- `{"type":"tool_call","id","method","params"}`
- `{"type":"complete","session_id","text","session":<b64>[,"auth":<b64>]}`
- `{"type":"failed","code":"aborted|provider-failed|session-invalid|protocol-failed"[,"auth"]}`. The `auth` field appears only for a subscription `provider-failed`, so refreshed tokens are not lost.

Exit code is 0 after `complete` and 1 after `failed`. `close` uses `killpg(SIGKILL)`.

**Helper internals** (`pi_helper.mjs`, 238 lines):
- Required SDK exports: `ModelRuntime`, `SettingsManager`, `DefaultResourceLoader`, `SessionManager`, `defineTool`, `createAgentSession`.
- Run mode:
  - Creates `agent/`, `auth/` and `sessions/` dirs; writes `auth.json` with `O_EXCL` and mode 0600.
  - `ModelRuntime.create({authPath, modelsPath:null, allowModelNetwork:false})`, then `setRuntimeApiKey` (api-key) or an OAuth check.
  - `SettingsManager.inMemory({retry:{enabled:false},compaction:{enabled:false}})`.
  - `DefaultResourceLoader` with no extensions, skills, prompts or themes, and system prompt `"You are an Agenticus workspace agent. Use only the supplied tools."`.
  - Session: `SessionManager.open(resume.jsonl)` or `.create(cwd, sessionDir, {id})`.
  - `createAgentSession({noTools:"builtin", customTools})`, then `prompt(text,{expandPromptTemplates:false})`, then `waitForIdle`.
  - The final assistant message must have `stopReason:"stop"`.
- Probe mode: `node pi_helper.mjs <sdk> --probe '<catalogs json>' [cc_patch_entry]` with `HOME=/dev/null` must print exactly `{"type":"probe","ok":true}\n`. For cc-patch it also verifies the extension's `before_provider_request` patch and the billing header `x-anthropic-billing-header: cc_version=2.1.96.000; cc_entrypoint=cli;`.

**Session JSONL validation** (pi.py:257):
- Complete lines ending in `\n`, strict JSON (no NaN, no duplicate keys).
- Exactly one header, as the first line: `{"type":"session","version":3,"id":<session_id>}`.
- At most 10,000 events and 4,000,000 bytes.
- It is stored **byte-for-byte** (never rewritten).

**Native auth** (pi.py:219): `{<provider>:{"type":"oauth","access","refresh","expires":<number>[,"accountId" for openai-codex]}}`, at most 1 MB.

**Continuation** `PiContinuationPayloadV1(session_id, working_directory_binding=sha256(str(path)), session_jsonl)` (pi.py:287).

**Durable work fingerprint** (pi.py:449-495):
```
sha256(json.dumps({"schema_version":1,"episode_id","turn_id","prompt_sha256","connection_id",
  "connection_provider","connection_profile","connection_account":<account_fingerprint>,
  "provider","model","territory","cc_patch",
  "continuation":null|{"id","thread","state_reference_sha256"}},
  sort_keys=True, separators=(",",":"), allow_nan=False))
```
`ensure_ascii` keeps its default (True).

#### 3. Concurrency and durability
- Custody:
  - api-key: `materialize(READ)` → `admit_result` → `release`.
  - subscription: `materialize(REFRESH)` → `activate` → … → `home.replace(new_auth)` → `checkpoint`.
- The subscription reserve is `_PUBLICATION_MARGIN(5) + 2*cancellation_grace`. `credential_ttl` (default 315) must be ≥ `wall_timeout(300) + reserve`.
- Config frame bound: `max_frame ≥ b64(session) + b64(auth) + 6*output + 128 KiB` and ≤ 16 MiB.
- Lease provider: `"local-process"` for local, otherwise the profile name. Errors `runtime-local-lease-required` / `runtime-territory-lease-required`.
- Publication order matches the other adapters. Durability (ledger, replay) is added by `PiRecoveredRuntime` and the A2 host.

#### 4. External dependencies and Haskell equivalents
- Node ≥ 22.19.0 plus the npm packages. **SDK-only (Node).** Keep `pi_helper.mjs` verbatim.
- Haskell: `typed-process` with `setNewSession`, `aeson`, `base64-bytestring`, `unix` (`signalProcessGroup sigKILL`).

#### 5. Tests
- `test_pi.py` (61 tests, 2100 lines) uses fake `.mjs` SDKs (`fake-pi-sdk.mjs`, `fake-pi-subscription-sdk.mjs`, `fake-cc-patch.ts`) run by the real `node`, so **node must be on PATH**.
- `test_pi_real.py` (2 tests, 510 lines):
  - `qualification_installation` + `PETRUS_CV16_PI_QUALIFY=1` + `PETRUS_CV16_PI_PROVIDER`/`MODEL`/`AUTH_PROFILE`.
  - `real_provider_acceptance` + `PETRUS_CV16_PI_LIVE=1`.

#### 6. Performance
Base64 of sessions up to 4 MB per turn. Benchmark: a fake SDK with 256 tool calls; measure host overhead per frame.

#### 7. Better in Haskell / quirks to preserve
- `session_id` is uuid4 for fresh sessions.
- The `auth` field is carried in `failed` frames.
- The probe's exact-output check.
- JSON emitted to the helper uses `ensure_ascii=False`. Node accepts either form, so only the fingerprints need exact Python encoding.

#### 8. Packaging
Ship `pi_helper.mjs` as a data file (`data-files` in cabal) and resolve its path via `Paths_` or an install-dir config.

---

### Pi operation ledger (`pi_recovery.py`)

#### 1. Responsibility and public API
- `SqlitePiOperationLedger` (pi_recovery.py:143) and the `PiOperationLedger` Protocol (line 129).
- `PiOperationRecord` (line 52) and `PiOperationPhase` = `executing | settled`.
- `PiRecoveredRuntime` (line 528) wraps `PiRuntimeAdapter` with crash-safe admission, replay and eviction.

#### 2. Wire formats (VERBATIM)
Connection: `sqlite3.connect(path, isolation_level=None, check_same_thread=False, timeout=5)`; `chmod 0600`; `PRAGMA journal_mode = DELETE`; `PRAGMA synchronous = FULL`.
```sql
CREATE TABLE IF NOT EXISTS pi_operations (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    operation_id TEXT NOT NULL UNIQUE, fingerprint TEXT NOT NULL,
                    episode_id TEXT NOT NULL, turn_id TEXT NOT NULL, phase TEXT NOT NULL,
                    outcome TEXT, accepted_appends INTEGER, termination_code TEXT,
                    output_reference TEXT, continuation_reference TEXT,
                    cleanup TEXT NOT NULL, cleanup_code TEXT NOT NULL,
                    acknowledged INTEGER NOT NULL CHECK (acknowledged IN (0, 1)))
```
`AUTOINCREMENT` implies a `sqlite_sequence` table.

Statements. Each write is `BEGIN IMMEDIATE` → statement → rowcount check → `COMMIT`.

recover:
```sql
SELECT operation_id FROM pi_operations WHERE phase = ? ORDER BY sequence
UPDATE pi_operations SET phase = ?, outcome = ?, accepted_appends = 0, termination_code = ?,
  output_reference = NULL, continuation_reference = NULL, cleanup = ?, cleanup_code = ?,
  acknowledged = 0 WHERE phase = ?
```
Bound values: `('settled','indeterminate','restart-indeterminate','unverified','cleanup-uncertain','executing')`.

admit:
```sql
INSERT INTO pi_operations (operation_id, fingerprint, episode_id, turn_id, phase, cleanup, cleanup_code, acknowledged) VALUES (?, ?, ?, ?, ?, ?, ?, 0)
```

settle:
```sql
UPDATE pi_operations SET phase = ?, outcome = ?, accepted_appends = ?, termination_code = ?, output_reference = ?, continuation_reference = ? WHERE operation_id = ? AND phase = ?
```

upgrade_cleanup (only UNVERIFIED → CLEAN/NOT_CREATED):
```sql
UPDATE pi_operations SET cleanup = ?, cleanup_code = ? WHERE operation_id = ?
```

acknowledge:
```sql
UPDATE pi_operations SET acknowledged = 1 WHERE operation_id = ? AND acknowledged = 0
```

Reads:
- `SELECT * FROM pi_operations WHERE operation_id = ?`
- `SELECT * FROM pi_operations ORDER BY sequence`. `sequence` must be dense 1..n.

Writer fence: `.{dbname}.writer.lock` beside the DB, mode 0600, `flock(LOCK_EX|LOCK_NB)`, with pid-based fork detection (`_WriterFence`, line 390).

Path preparation: parent dir 0700; the DB file is created `O_EXCL|O_NOFOLLOW` with mode 0600.

#### 3. Concurrency and durability
- Admission happens before `adapter.start`, so a crash after the provider was crossed leaves `executing`, and `recover()` turns that into INDETERMINATE `restart-indeterminate` / UNVERIFIED `cleanup-uncertain`.
- Same `operation_id` and fingerprint with a settled row → `_ReplayOperation`:
  - `wait` returns the stored settlement;
  - `cancel` returns TOO_LATE;
  - `close` returns the stored cleanup.
  - There is no redispatch.
- A different fingerprint raises `operation-conflict`.
- `_DurableOperation.wait` settles the ledger. `close` records the adapter receipt (else INDETERMINATE `close-indeterminate`), then calls `upgrade_cleanup`.
- A start error settles FAILED (`<error code>` or `runtime-start-failed`) with NOT_CREATED `client-not-created`.
- `evict()` drops in-memory operations up to the **watermark**: the highest contiguous sequence that is both settled and acknowledged.

#### 4. Haskell
`direct-sqlite` (explicit `BEGIN IMMEDIATE`), `filelock` or `unix` flock. The pid-based fork check is unnecessary in Haskell (no fork), but keep the lock-file name.

#### 5. Tests
Covered in `test_pi.py` and `test_pi_a2_host.py` (restart, replay, watermark).

#### 6. Performance
Two to four fsynced transactions per turn, which is negligible.

#### 7. Better in Haskell / quirks to preserve
- Rows are **positional** (`SELECT *`), so keep the column order.
- Keep `journal_mode=DELETE` here, unlike the Codex service which uses WAL.

#### 8. Packaging
`Petrus.Agenticus.Runtime.Pi.Ledger`.

---

### Pi A2 Local host (`pi_a2_host.py`)

#### 1. Responsibility and public API
A complete self-hosting composition (1554 lines) for `pi.native.a2.local`. It owns:
- the connection store,
- the materialization dir,
- Motus local territory provisioning,
- the Episode Attachment, Hands gateway and grants,
- the Pi adapter, the operation ledger and a body store.

Public API:
- `compose_pi_a2_runtime(config, authority)` (line 1401) and `compose_pi_a2_scripted_runtime(...)` (line 1497).
- `PiA2RuntimeHost` Protocol (line 457): `probe`, `start(PiA2RuntimeStart)`, `close`.
- `PiA2RuntimeHostConfig` (line 182):
  - `state_root`, `working_directory`, provider/model (API_KEY catalog), `host_id`
  - `capabilities`, `allowed_argv`, `test_command=("/bin/true",)`, `max_tool_calls=16`
  - `attachment_timeout=960` (> wall + grace), `command_timeout=60`, `credential_ttl=1020`, `wall_timeout=900`, `cancellation_grace=5`
  - cli/node/package paths
- `PiA2RuntimePolicy(capabilities, writable_paths, max_tool_calls, writable_roots)`; `.git` and `STAGE_DIRECTORY` are always denied.
- `PiA2RuntimeStart(operation_id, episode_id, turn_id, prompt, workspace_archive, workspace_correlation, policy, continuation)`. The archive's sha256 must equal `workspace_digest`, checked by `validate_workspace_archive`.
- `PiA2DirectAuthority(connection, key_operations, supply_api_key -> bytearray)`. The key is supplied once and the buffer is erased.
- Scripted types `PiA2ScriptedCall` / `Turn` / `Readiness`. `_SCRIPTED_SESSION="00000000-0000-4000-8000-000000000001"`. Support label: `"Pi A2 Local host lifecycle — scripted runtime conformance"`.

#### 2. Wire formats (VERBATIM)

State root layout (0700): `connection.sqlite3`, `materializations/`, `runtime/`, `bodies.sqlite3`, `operations.sqlite3` (the Pi ledger).

`bodies.sqlite3` uses `PRAGMA journal_mode = DELETE` and `PRAGMA synchronous = FULL`:
```sql
CREATE TABLE IF NOT EXISTS pi_a2_bodies (
                operation_id TEXT PRIMARY KEY,
                output_reference TEXT, output_text TEXT,
                continuation_reference TEXT, session_id TEXT,
                working_binding TEXT, session_jsonl BLOB,
                workspace_archive BLOB NOT NULL, workspace_digest TEXT NOT NULL,
                aggregate_verified INTEGER NOT NULL CHECK (aggregate_verified IN (0, 1)))
```

References, staged in memory until commit:
- output: `"pi-a2-output-" + sha256(op_id + "\0" + text)`
- continuation: `"pi-a2-continuation-" + sha256(op_id \0 session_id \0 binding \0 jsonl)`

Writes:
- commit: `INSERT INTO pi_a2_bodies VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)` with `aggregate_verified=0`.
- publish: `UPDATE pi_a2_bodies SET aggregate_verified = 1 WHERE operation_id = ? AND aggregate_verified = 0`.
- Loads require `aggregate_verified = 1`.

Durable fingerprint (schema 2, line 350):
```
sha256(json.dumps({"schema_version":2,"pi":<pi_durable_work_fingerprint>,
  "workspace":{"digest","correlation"},
  "policy":{"capabilities":sorted,"writable_paths","writable_roots",
            "denied_writable_roots":[".git",STAGE_DIRECTORY],
            "allowed_argv"(if shell granted),"test_command"(if test granted, else null),"max_tool_calls"}},
  sort_keys=True, separators=(",",":"), allow_nan=False))
```

IDs:
- lifecycle operations: `pi-a2-{uuid4hex}-{recover|enroll|remove|revoke|erase|rotate|authorize}`
- territory: `pi-a2-territory-<sha256(op)>`
- attachment: `pi-a2-attachment-<sha256(op)>`

Required environment capabilities: `COMMAND_CANCELLATION`, `EXPLICIT_ENVIRONMENT`, `PRIVATE_FILE_TRANSFER`, `PROCESS_GROUP`, `WORKSPACE`.

#### 3. Concurrency and durability
Start order:
1. fingerprint
2. ledger lookup: replay **only** if the row is settled, cleanup is clean and the bodies are verified; otherwise `operation-indeterminate`
3. policy ceiling check (a rejection does not burn the operation id)
4. continuation workspace-digest check
5. `_require_ready`
6. `ledger.admit`
7. connection authorize/rotate, consuming the one-shot authority
8. `MotusAttachmentBinding.open`
9. `EpisodeAttachment`
10. gateway
11. `grants.open`
12. `adapter.start`

Finalize order (`_HostOperation._finalize_owned`, line 805 ff.):
1. `inner.close`
2. `attachment.settle(drain=2*grace)`
3. cleanup is verified only if `provider.lookup(territory) is None`
4. `bodies.commit`
5. `ledger.settle`
6. `ledger.upgrade_cleanup`
7. `bodies.publish`

Any failure gives INDETERMINATE `host-cleanup-uncertain`.

Host `close`: ordered teardown (remove_host, revoke/erase), then requires `materializations/` and `runtime/` to be empty.

#### 4. Haskell
Pure composition over the Haskell ports of connection custody, Motus local and Hands, plus `direct-sqlite`. No external helper beyond `pi_helper.mjs`.

#### 5. Tests
`test_pi_a2_host.py` (24 tests, 932 lines). The scripted runtime needs no node or credentials. These are the only **Supported** surface's tests and should be the first conformance target for the port.

#### 6. Performance
Workspace archives are stored as BLOBs in every body row, so cost is dominated by archive size. Benchmark: start/finalize latency for a 10 MB archive with the scripted client.

#### 7. Better in Haskell / quirks to preserve
- The two-phase `aggregate_verified` publish must be kept.
- Keep the "policy rejection does not burn operation identity" ordering.
- `bytearray` erasure becomes `ScrubbedBytes` from `memory`.

#### 8. Packaging
`Petrus.Agenticus.Runtime.Pi.A2Host`.

---

### Pi application-owned adapter (`pi_application.py` + `pi_application_helper.mjs`, A5 Gondolin/E2B)

#### 1. Responsibility and public API
`PiApplicationRuntimeAdapter` (pi_application.py:718) runs one application-owned agent-loop step in which Petrus, not Pi, owns steering and evaluation.

| Kind | ID |
| --- | --- |
| program | `pi.application-owned` (HARNESS ownership, `owns_steering`, `owns_evaluation`) |
| continuation | `pi.application-owned` |
| connection | `pi.compatible-api-key` |
| hands | `pi.capability-scoped` |

- Profiles: gondolin or e2b. Provider/model must be in `PI_API_KEY_CATALOG`.
- Pins: coding-agent, agent-core and ai are all 0.83.0 at the same commit as `pi.py`.

#### 2. Wire formats
**Process:** `node pi_application_helper.mjs <coding entry> <core entry> <ai entry>`, plus `--probe <catalog json>` or `--test-probe`.

Start frame (one line):
```
{"api_key","cwd","limits":{"frame","output","transcript","messages","events","tools"},
 "model","observation","provider","transcript":<b64>,"type":"start","version":1,"write_allowed":bool}
```

Helper behaviour:
- Runs `core.runAgentLoop` once with `shouldStopAfterTurn: () => true` and sequential tool execution.
- `tool_call` / `tool_result` frames work as in `pi.py`.
- `beforeToolCall` blocks `workspace_write` when writes are not allowed and emits `{"type":"guard_blocked","id","method","params"}`. The host maps this to `ToolResult(id, False, None, ToolError(RejectionCategory.WRITE, "application guard blocked workspace write"))`.
- Completion: `{"type":"complete","text","transcript":<b64 delta>}`.
- Failure codes: `aborted`, `protocol-failed`, `provider-failed`.

Continuation `PiApplicationContinuationPayloadV1(working_directory_binding = sha256("pi-application:"+path), transcript_json)`. The host appends the delta as `json.dumps(prior+delta, ensure_ascii=False, separators=(",",":"))`.

Step payload: `PiApplicationStepPayloadV1(profile, results: tuple[ToolResult], final_text)`, passed to `store_turn`.

#### 3. Concurrency/durability
- Custody is READ only (materialize, admit_result, release).
- Idempotency key: transcript sha, grant capabilities, profile, plus the standard coordinates.
- Frame bound: ≥ b64(transcript) + 64 KiB + 128 KiB.
- Same thread/Condition operation model as the other adapters.

#### 4. Haskell
Same as Pi native: keep the `.mjs` helper verbatim.

#### 5. Tests
`test_pi_application.py` (25 tests, 1096 lines). It includes seven separate operations through a real gateway, a Gondolin→E2B continuation crossing and the closed-write guard.

#### 6. Performance
Transcript re-serialization per step grows as O(total transcript size). Benchmark: 100 chained steps.

#### 7. Better in Haskell / quirks to preserve
`_package` resolves nested or sibling `node_modules` (pi_application.py:1110-1123). Keep the same lookup order.

#### 8. Packaging
Same module group as Pi, with its own data file.

---

### Pi model-phase activity (`pi_model_phase.py` + `pi_model_phase_helper.mjs`)

#### 1. Responsibility and public API
`PiModelPhaseAdapter` (pi_model_phase.py:339) is an Impetus **Activity** for `MODEL_PHASE_ACTIVITY` used by Agent-as-a-Net. Its input is a `LoopState`. It performs one model call with declaration-only tools and returns `ModelSettlement(state, stop, sha256(assistant), output_ref, continuation_ref, proposals).to_data()`.
- Operation id: the idempotency key or `attempt_id`.
- `PiModelPhaseConfig` default timeout is 120 s.
- Protocols `PiModelPhaseOperations.publish(op, output, continuation)` and `PiModelPhaseCustody`.

#### 2. Wire formats
Start frame (single line):
```
{"type","version","provider","model","api_key","system","observation","transcript":<b64>,
 "results":[{"id","method","result":<to_model_data>}],
 "limits":{"frame":16777216,"output":1000000,"transcript":4000000,"messages":10000}}
```
The limits must be exactly these values (pi_model_phase.py:54).

Helper behaviour:
- Calls `runtime.streamSimple(model,{systemPrompt, messages: convertToLlm(...), tools})`.
- Outputs exactly one line: `{"type":"complete","assistant":<b64>,"transcript":<b64>}`.
- Also supports `--probe` and `--test-probe`.

Transcript validation (pi_model_phase.py:633-723). The new transcript must equal, in order:
1. the prior transcript;
2. the user observation (phase 1 only);
3. one `toolResult` entry per result, with text `json.dumps(result.to_model_data(), separators=(",",":"))` (default `ensure_ascii=True`);
4. the assistant message.

Assistant keys:
- Required: `role, content, api, provider, model, usage, stopReason, timestamp`.
- Optional: `responseModel, responseId, diagnostics, errorMessage, rawStopReason`.

Proposals come from `toolCall` blocks: unique ids, at most `MAX_PROPOSALS`.

#### 3. Concurrency/durability
- The client writes stdin non-blocking through a selector and heartbeats every `min(5, timeout/2)`.
- **Ordering:** authority is released **before** `operations.publish`.
- Failures release authority and publish nothing.

#### 4. Haskell
Keep the helper. Use `typed-process` with a stdin writer thread and an `async` heartbeat.

#### 5. Tests
`test_pi_model_phase.py` (25 tests, 795 lines). Some tests launch the real `node` (`shutil.which("node")`).

#### 6. Performance
One process spawn per model phase (node startup ≈ 50-100 ms). The helper could become persistent later, but that changes the protocol, so it is not recommended for parity.

#### 7. Quirks to preserve
`toolResult` text is built with Python `ensure_ascii=True`, while JS `JSON.stringify` does not escape. Non-ASCII tool output could therefore cause `transcript-mismatch` upstream. Haskell must reproduce the Python bytes exactly using `petrus-json` in ASCII-escape mode. Flag this as a latent upstream bug rather than fixing it silently.

#### 8. Packaging
Same group as Pi.

---

### Amp adapter (`amp.py`, A1 provider-managed) — SDK-ONLY

#### 1. Responsibility and public API
`AmpRuntimeAdapter` (amp.py:741) runs one Amp turn in Amp's **orb** executor. Amp owns hands and territory. `AmpProviderManagedBinding` (line 406) has `binding_kind="amp-provider-managed"` and `export_archive=b""`.

Pins (amp.py:58-66):
- `AMP_SDK_VERSION="0.1.20260729121202"`, source `pypi:amp-sdk==…#sha256=83d0f4805ddfa836c690419a88f4fd35f1505e03dd772e0831d802db42ca33d7`.
- `AMP_CLI_VERSION="0.0.1785733786-gde6a10"`, source `npm:@ampcode/cli@…#sha512=oqErM5EQmPmQ2yzoRk/vbWRvvkcRMDV8IjJniLFCFldTlDzq8KDHq43XBo3ktDqy6bV09aWrkwIo4zs1DrRGrA==`.

IDs: `amp.provider-managed` (program, hands, territory), `amp.native` (continuation), `amp.platform-managed` (connection).

#### 2. Wire formats and protocols
- Call: `amp_sdk.execute(prompt, AmpOptions(executor="orb", project, mode, visibility, no_archive_after_execute[, continue_thread]))`, an async iterator of pydantic events (amp.py:274).
- Config:
  - `mode` ∈ low/medium/high/ultra (default medium)
  - `visibility` ∈ private/unlisted/workspace/group
  - `project` at most 512 bytes
- Events (size measured with `model_dump_json`; at most 10,000 events, 1 MB each, 4 MB total):
  - The first event must be `{"type":"system","subtype":"init","session_id":"T-…"}`, with thread id regex `T-[A-Za-z0-9]+(?:-[A-Za-z0-9]+)+`.
  - Later events must have type `assistant`, `user` or `result` and the same `session_id`.
- Result mapping:

  | Result | Settlement |
  | --- | --- |
  | `is_error:false`, `subtype:"success"` | COMPLETED; result text sanitized, at most 1 MB |
  | `is_error:true`, `error_during_execution` | FAILED `provider-failed` |
  | `is_error:true`, `error_max_turns` | FAILED `provider-max-turns` |

- Continuation: `{"schema_version":1,"thread_id":"T-…"}`.
- CLI resolution (mirrors the SDK, amp.py:312-330), in order:
  1. `$AMP_CLI_PATH` (`.js` → `node <path>`)
  2. `$AMP_HOME` (default `~/.amp`) `/sdk/bin/amp`, then `/bin/amp`
  3. `~/.local/bin/amp`
  4. `which amp`
- Probe:
  - `amp --version` (first token must equal the pin).
  - `amp --help` must contain `--orb-execute`, `--project` and `--stream-json`.
  - `AmpOptions.model_fields ⊇ {executor, project, continue_thread}`, and `execute` must take an `options` parameter.
  - Capabilities: `{runtime.cancel, runtime.continue, runtime.orb, runtime.provider-managed}`.

#### 3. Concurrency/durability
- Cancel uses `task.cancel` via `call_soon_threadsafe`. The stream is closed with `athrow(CancelledError)` then `aclose()`.
- Close dispositions:

  | State | Disposition |
  | --- | --- |
  | provider terminal observed | CLEAN `client-closed` |
  | SDK never started | NOT_CREATED |
  | otherwise | UNVERIFIED `provider-state-uncertain` (`client-cleanup-uncertain` if the worker is still alive) |

- **Credential handling:** no Connection custody materialization. The Connection is a logical fence only (authority_epoch is part of the key), and the `amp` CLI uses its own ambient login. Durable state is only the thread id.
- Idempotency key: episode, turn, prompt digest, connection_id, authority_epoch, attachment id/epoch, continuation thread.

#### 4. External dependencies
- Python `amp-sdk`. **SDK-only.** The SDK wraps the `amp` CLI using `--stream-json` and `--orb-execute`; its argv and JSON event schema are defined in the SDK source, which is not vendored.
- **Recommendation: keep a small Python sidecar** for parity. Only port to a direct CLI driver after extracting the pinned SDK's argv and event schema into a test fixture. Amp is provider-managed, so a sidecar costs little.

#### 5. Tests
- `test_amp.py` (15 tests, 587 lines) monkeypatches `_resolve_amp_cli`, `importlib.metadata.version` and `subprocess.run`, and uses a fake `execute`.
- `test_amp_real.py` (1 test): `real_provider_acceptance` + `PETRUS_RUN_CV16_AMP_A1=1` (+ `PETRUS_AMP_PROJECT`, default `henriquebastos/petrus`).

#### 6. Performance
Provider-bound.

#### 7. Quirks to preserve
- The version check takes only the first whitespace token of `--version`.
- Probe failures are swallowed into "not ready" (`except Exception`).

#### 8. Packaging
Optional component `petrus-agenticus-runtime-amp` plus the Python sidecar (`uv`-locked `amp-sdk` pin).

---

### Agent-as-a-Net runner (`agent_net_runner.py`, A5 Local)

#### 1. Responsibility and public API
`AgentNetRunner` (line 416) runs the Agent-as-a-Net Petri net (`program.agent_net`) on the Petrus Engine with an `InlineDispatch` of two activities:
- `MODEL_PHASE_ACTIVITY`: the injected `PiModelPhaseAdapter`.
- `HANDS_ACTIVITY`: `AgentNetHandsActivity`, line 363.

It projects the history-committed facts onto an Agenticus `Thread`.

API:
- `create(root, instance_id, thread, initial: LoopState, attachment, model_activity, hands_adapter)`. Fails if `thread.json` or `history.jsonl` already exists.
- `load(root, attachment, model_activity, hands_adapter)`.
- `advance() -> DriveOutcome`.
- `drain(max_actions=256)`. Raises if blocked on external custody, stopped without a terminal, or out of action budget.
- `close()`, and the properties `thread` and `settled`.
- `JsonAgentNetThreadRepository`, `AgentNetThreadProjection`, `HaltCode` = `indeterminate | activity-failed`.

#### 2. Wire formats
Files under `root`:
- `thread.json`: the projection.
- `history.jsonl`: Impetus `JsonlHistoryStore`; see section 4.

`thread.json` = `json.dumps(projection.to_data(), allow_nan=False, separators=(",",":"), sort_keys=True)`, with no trailing newline, holding:
```
{"schema_version":1,"instance_id","initial":<LoopState>,"thread":<Thread>,"attachment":{episode_id,attachment_id,attachment_epoch,grant_epoch},
 "appends":[{occurrence,output_reference,continuation_reference}],"hands":[{occurrence,call_id}],
 "terminal":<Terminal>|null,"halt":{code,activity,occurrence}|null}
```
Invariants are at lines 210-254.

Save:
- compare-and-save (`load() == expected`, else a conflict);
- temp file `.{name}.{uuid4hex}.tmp` created `O_EXCL` with mode 0600;
- fsync, `os.replace`, fsync the directory.

Hands activity:
- Input `{"version":1,"proposal","grant_epoch"}`, heartbeat `{"phase":"hands"}`.
- Output `{"version":1,"result":ModelResult.from_model_data(gateway.submit(...)).to_data()}`.

Continuation id: `"agent-net:" + sha256(f"{thread_id}\0{episode_id}\0{continuation_ref}")`, using `AGENT_AS_NET_CONTINUATION_DESCRIPTOR` (line 793).

Episode start: `EpisodeBudget(max_turns=1, max_accepted_appends=initial.phase_limit)`.

#### 3. Concurrency and durability
History is the source of order; `thread.json` is a derived projection. On `_open` (line 494) and after each `advance` (line 621):
1. `_project_committed`: each `ActivityCompleted` is matched to its `ActivityRequested`.
   - A model completion becomes an `accept_append` plus a `ProjectedAppend`.
   - A hands completion becomes a `ProjectedHands`.
   - Re-projection is idempotent; a conflict raises.
2. `_settle_recorded_failure`: the last `ActivityFailed` cancels the attachment (`activity-failed`), settles the Turn and Episode FAILED, and records a halt.
3. `_settle_terminal`: a single `Terminal` token in `DONE`. Its refs must equal the last append. The terminal code maps to the episode outcome:

   | Terminal code | Turn | Episode |
   | --- | --- | --- |
   | CANCELLED | CANCELLED (after `request_cancellation`) | CANCELLED (attachment cancel reason `agent-cancelled`) |
   | COMPLETED | COMPLETED | COMPLETED |
   | PHASE_BUDGET / TOOL_BUDGET | COMPLETED | BUDGET_EXHAUSTED |
   | FAILED | FAILED | FAILED |
   | any other code | COMPLETED | FAILED |

4. `_fence_reconstructed_activities` (on load only): exactly one in-flight invocation without a completion becomes `reconstruction-indeterminate`, with Turn/Episode INDETERMINATE and a halt. More than one raises. There is **no redispatch**.

`_settle_attachment` requires an independently verified settlement and refuses while custody is uncertain. A crash between attachment settlement and the thread save is tolerated: `load` uses `require_grant=False`.

#### 4. Haskell
Pure Haskell on the ported Engine and History. The atomic file write needs `unix` (fsync on the directory fd) and `directory`.

#### 5. Tests
- `test_agent_net_runner.py` (10 tests, 487 lines): reconstruction without redispatch, indeterminate fencing of in-flight model/hands, failure propagation.
- `test_agent_net_real.py` (2 tests, 599 lines):
  - `qualification_installation` + `PETRUS_CV16_AGENT_NET_QUALIFY=1`
  - `real_provider_acceptance` + `PETRUS_CV16_AGENT_NET_LIVE=1`
  - Paths: `PETRUS_CV16_AGENT_NET_NODE`, `_PACKAGE_ROOT`, `_AUTH_FILE`.

#### 6. Performance
`_project_committed` rescans the whole history on every advance, which is O(n²) over a run. Bounded by `max_actions=256`. Haskell can keep a cursor but must give the same results.

#### 7. Quirks to preserve
- The `create` once-only check runs before any history write.
- Stale attachment or grant validation fails before history.

#### 8. Packaging
`Petrus.Agenticus.Runtime.AgentNet`.

---

### Runtime package layout for the port

- **`petrus-agenticus-runtime`** (library). Modules: `Types`, `Profiles`, `Codex`, `Codex.GondolinService`, `Pi`, `Pi.Ledger`, `Pi.A2Host`, `Pi.Application`, `Pi.ModelPhase`, `AgentNet`.
  - Dependencies: `petrus-agenticus` (connection custody, attachment, hands, thread, continuation), `petrus-motus`, the `petrus` engine/history, `petrus-json`, `aeson`, `typed-process`, `unix`, `network`, `direct-sqlite`, `crypton`, `memory`, `base64-bytestring`, `async`, `stm`, `filelock`, `file-embed`.
  - `data-files`: `pi_helper.mjs`, `pi_application_helper.mjs`, `pi_model_phase_helper.mjs` (byte-identical to upstream). The Codex helper is embedded byte-identically.
- **`petrus-agenticus-runtime-claude`** and **`-amp`** (optional): Haskell host modules plus Python sidecars. Each sidecar sits in its own `uv` project with the exact pins (`claude-agent-sdk==0.2.128`, `amp-sdk==0.1.20260729121202`) and speaks a Petrus-owned NDJSON protocol modelled on `pi_helper.mjs`. Both cells are experimental upstream, so they can land after the supported Pi A2 scripted host.
- **External toolchain prerequisites** (validated by probe, never bundled): `node ≥ 22.19.0` plus the Pi npm packages at 0.83.0; `codex` 0.145.0; the Gondolin image above; the Claude Code CLI 2.1.220 bundled in the SDK wheel; `amp` CLI 0.0.1785733786-gde6a10.
- **Conformance order:**
  1. `test_foundation` and `test_profiles`
  2. Pi ledger and A2 scripted host (`test_pi_a2_host`)
  3. Codex JSONL parser and the Gondolin service ledger
  4. Pi helpers through node
  5. Agent-net runner
  6. Claude/Amp sidecars
- **Cross-store DB compatibility tests:** open Python-created `operations` (Codex service), `pi_operations` and `pi_a2_bodies` databases from Haskell, and the reverse.

## 13. Inventories

These tables collect what the component sections say, so that the interop,
dependency and benchmark work can be planned as a whole. The component sections
remain the source of the details.

### 13.1 Durable stores

Every row is something a Python and a Haskell process may both open. "Text
check" means the opener compares the stored DDL text, so the DDL must be
copied verbatim (section 3.4).

| Store | Backend | Tables / files | Fence or lock | Text check | Section |
| --- | --- | --- | --- | --- | --- |
| JSONL History | file | one JSONL file per instance; one record per line | none (Engine fence applies) | n/a; lines byte-pinned | 4 |
| SQLite History | SQLite (WAL, `synchronous=FULL`) | `impetus_history_schema`, `impetus_history_events`, 2 partial unique terminal indexes | `flock` writer fence file | yes | 4, 6 |
| Postgres History | Postgres | `impetus.semantic_events` + 3 indexes (`ensure_schema` is explicit, never implied) | session advisory lock | no | 4, 6 |
| Fabric | Postgres | `impetus_fabric.{schema_metadata,processes,exposed_sources,service_offers,delivery_grants,deliveries}` | credentials as sha256, constant-time check | no | 4 |
| Process lifecycle | Postgres | `impetus_lifecycle.{schema_metadata,spawns}` | claimed under autocommit before `ensure` | no | 4 |
| Local Dispatch | SQLite (WAL, `synchronous=FULL`) | `impetus_local_dispatch_{schema,tasks,terminals,cancellations}` + claimable index; v1→v2→v3 migrations | `BEGIN IMMEDIATE`; leases by claimant + epoch | yes | 7 |
| Absurd Dispatch | Postgres | vendored `absurd-0.4.0.sql` (sha256 pinned, checked on every `ensure`); per-queue `absurd.t_<queue>`/`r_<queue>`/… tables; checkpoint `__impetus_latest_activity_details_v1` | `FOR UPDATE` run guard, `pg_advisory_xact_lock(hashtextextended(key,0))` for queue moves | schema hash | 7 |
| ZeroMQ IPC endpoint | file | `.<name>.impetus.lock` beside the IPC socket | `flock` | n/a | 8 |
| Gondolin state | files | `<state>/<sha256[:24]>/{lock,registry.json,workspace/}`, runtime dirs `/tmp/petrus-g-*` | `flock` + inode re-check; process identity from `/proc` or `ps lstart` | registry bytes | 9 |
| Execution evidence (private) | files | ArtifactStore blobs, Timeline JSONL | fsync per line/blob | n/a | 9 |
| Connection custody | SQLite (`journal_mode=DELETE`, FULL) | `connection_custody` (singleton row, revision, canonical JSON payload) | `BEGIN IMMEDIATE` + conditional UPDATE, ≤ 8 retries | — | 11 |
| Territory custody | SQLite (`secure_delete=ON`) | `territory_custody` + partial unique index `one_live_territory_operation`; positional `SELECT *` | `.<db>.writer.lock` `flock` | — | 11 |
| Credential home files | files | `<root>/<attachment_id>.state`, dir 0700, files 0600 `O_EXCL|O_NOFOLLOW`, zero-overwritten before unlink | dev/ino re-check | n/a | 11 |
| Codex Gondolin service | SQLite (WAL, FULL, `user_version=1`) | `operations` | 0600 Unix socket, HMAC token | yes (normalized DDL) | 12 |
| Pi operation ledger | SQLite (`journal_mode=DELETE`) | `pi_operations` (AUTOINCREMENT; positional `SELECT *`) | `.{db}.writer.lock` `flock` | — | 12 |
| Pi A2 bodies | SQLite | `pi_a2_bodies` (two-phase `aggregate_verified` publish; archive BLOBs) | — | — | 12 |
| Agent-net thread | file | `thread.json` (canonical, no trailing newline, atomic replace) | — | bytes | 12 |
| DST artifacts | files | strict JSON artifacts, versions v1–v4 replayable; runner `progress.jsonl` | `open("xb")` + fsync | bytes (`encode(decode(f)) == f`) | 10 |

### 13.2 Protocols

| Protocol | Transport | Framing | Peers that must interoperate | Section |
| --- | --- | --- | --- | --- |
| Observation protocol v1 | HTTP/1.0, `GET /v1/snapshot`, `/v1/history?after=&limit=`, `/v1/document` | one request per connection; compact sorted ASCII JSON; CORS `*` | any watcher, petrus-viewer | 5 |
| Simulation HTTP profile 1 | HTTP/1.0, `GET /v1/simulation-profile`, `POST /v1/simulations` | ≤ 1 MiB body, 5 s per socket op, single flight (429), exact origin | petrus-viewer | 5 |
| Absurd queueing | Postgres SQL functions + `LISTEN/NOTIFY` (`impetus_dispatch`, `impetus_results`) | jsonb params, spawn options, failure reason `{"petrus_failure":1,…}` | Python Workers ↔ Haskell Engine and the reverse | 6, 7 |
| Fabric delivery | Postgres rows (+ unused `impetus_fabric_delivery` notify) | Envelope v1, 8 exact keys | Python ↔ Haskell instances | 4 |
| ZeroMQ Worker transport v2 | ZeroMQ DEALER → ROUTER, CURVE on TCP (ZAP domain `impetus.dispatch.worker.v2`) | one JSON frame per request, `[route, json]` reply, 1 MiB cap, v1 refused | Python Workers ↔ Haskell server and the reverse | 8 |
| Worker CLI | process argv/env/stdout | readiness and event lines (`json.dumps` defaults), exit codes 0/1/2 | operators, process supervisors | 8 |
| Gondolin sidecar | Unix socket, one request per connection | one JSON line each way, 8 MiB cap, `lease_id` + `boot_token`, 11 actions | Haskell host ↔ verbatim `gondolin_sidecar.mjs` | 9 |
| Docker / E2B providers | `docker` CLI argv; E2B SDK | labels `run.petrus.operation`, `run.petrus.spec` | shared containers | 9 |
| Codex CLI | process, `codex exec --json …` JSONL on stdout | strict event state machine | `@openai/codex` 0.145.0 / 0.146.0 | 12 |
| Codex Gondolin service | Unix socket (0600), one frame per connection | canonical sorted ASCII JSON + `\n`; sha256 request fingerprint; stored terminal replayed | host ↔ guest helper | 12 |
| Pi bridges | process stdin/stdout NDJSON | start, tool_call/tool_result, abort, complete/failed | Haskell host ↔ verbatim `.mjs` helpers | 12 |
| Claude / Amp | Python SDKs (new sidecars) | to be defined by the port | Haskell host ↔ Python sidecar | 12 |
| DST process runner | child process + files | `progress.jsonl`, SIGTERM → SIGKILL escalation | Python ↔ Haskell parents and children | 10 |
| Telemetry lines | stdout/log sink | JSON line per event, Python default separators, insertion order | log consumers | 10 |

### 13.3 External dependencies

| Need | Upstream | Haskell choice | Gap or caveat |
| --- | --- | --- | --- |
| JSON fidelity | stdlib `json` | `petrus-json` | add CPython 4,300-digit limit, order-insensitive equality with `0.0 == -0.0`, depth guard |
| SQLite | stdlib `sqlite3` | `direct-sqlite` (+ `sqlite-simple` for rows) | check the bundled amalgamation has JSON1 (3.38+) and partial indexes |
| PostgreSQL | `psycopg` 3 | `postgresql-libpq` (+ `postgresql-simple`) | avoid `hasql`/`hasql-transaction` on the joined connection (no first-class LISTEN, auto-retry conflicts with poisoning) |
| Absurd | `absurd-sdk==0.4.0` (import only) | raw SQL against the vendored schema | no Haskell SDK, none needed |
| ZeroMQ | `pyzmq` 27 | `zeromq4-haskell` 0.8.0 | last release 2019: verify it builds on GHC 9.10.3; no ZAP authenticator, no certificate loader (write both, ~150 lines); fallback is a thin FFI |
| File locks | `fcntl.flock` | `lukko` (`Lukko.FLock`) or FFI `flock(2)` | never `hLock` or `setLock` (section 3.3) |
| Hashing, random, constant-time compare, AES-GCM (tests) | `hashlib`, `secrets`, `hmac`, `cryptography` | `crypton` (`memory`/`ram` for `constEq`, `ScrubbedBytes`), `base16-bytestring`, `base64-bytestring` | — |
| HTTP server | `http.server` | small custom HTTP/1.0 core on `network` | warp/wai normalize targets, send `100 Continue`, answer HTTP/1.1 and differ in status phrases; do not use them for these two services |
| Processes, signals | `subprocess`, `os`, `signal` | `typed-process`/`process`, `unix`, `async`, `stm` | `openat`-family calls need small FFI shims; resolve `argv[0]` explicitly (no inherited PATH) |
| Tar | `tarfile` | hand-written PAX tar codec (~400 lines) | Hackage `tar` writes no PAX and reads PAX `path` wrongly; byte identity matters because digests are persisted |
| Telemetry | own JSON logger (`telemetry.py`), not OpenTelemetry | `petrus-telemetry` with a pluggable sink; FFI `getrusage`/`sysconf` | optional OpenTelemetry sink via `hs-opentelemetry-*` is a non-parity extra; its metrics API is incomplete |
| CLI parsing | `argparse` | `optparse-applicative` | exits 1 on parse error by default; upstream exits 2 |
| Node runtimes | Node ≥ 23.6 (Gondolin), ≥ 22.19 (Pi) | keep the `.mjs` helpers | runtime prerequisite, as upstream |
| Agent CLIs and SDKs | Codex CLI, Claude Agent SDK, Amp SDK, Pi libraries | Codex direct; Claude and Amp through Python sidecars; Pi through the `.mjs` helpers | Claude's CLI control protocol is undocumented; Amp's stream schema is not vendored |
| E2B | `e2b` SDK | defer | no Haskell SDK; upstream only uses it in opt-in acceptance tests |
| Tests | pytest, Hypothesis, pytest-randomly/timeout/xdist, mutmut, ast-grep | `tasty` or `hspec`, `hedgehog`, golden files from `upstream/` | no maintained Haskell mutation tool |

### 13.4 Upstream test suites to port

Counts are `def test_*` functions; section 5 of each component expands
parametrization. "Docker" means the root `conftest.py` Postgres
(`postgres:17.5-alpine@sha256:6567bca8…`), which fails rather than skips without
Docker.

| Suite | Functions | Needs | Section |
| --- | ---: | --- | --- |
| `impetus/history_store/test_history_backends.py` | 14 | Docker for its Postgres parameter only | 4 |
| `impetus/history_store/test_persistence.py` | 33 | — | 4 |
| `impetus/history_store/test_sqlite_history.py` | 11 | — | 4 |
| `impetus/history_store/test_postgres_history.py` | 21 | Docker | 4 |
| `fabric/test_fabric.py` | 12 | Docker (all), runs `scripts/cv5-fabric-demo.py` | 4 |
| `processes/test_processes.py` | 19 | Docker for 9; runs `scripts/cv5-lifecycle-demo.py` | 4 |
| `engine/test_observation.py`, `test_observation_http.py` | 19 + 7 | loopback only | 5 |
| `engine/test_simulation.py`, `test_simulation_http.py` | 19 + 24 | loopback only; repo-relative fixture paths; some timing assertions | 5 |
| `engine/test_engine.py`, `test_coordinator.py`, `test_execution.py` | 28 + 42 + 134 | — (`test_execution` uses a `subprocess` crash) | 6 |
| `engine/test_postgres_engine.py` | 12 | Docker | 6 |
| `engine/test_sqlite_engine.py` | 5 | POSIX, `multiprocessing` spawn and fork | 6 |
| `integration/test_activity_seam.py` | 100 | — (mostly kernel behavior; about 40 are Activity/Inline tests) | 7 |
| `motus/dispatch/test_local_dispatch.py` | 36 | — (5 need the Engine) | 7 |
| `motus/dispatch/test_absurd_adapter.py` | 78 | Docker for all but ~10 | 7 |
| `motus/dispatch/test_attempt_heartbeats.py` | 8 | — | 7 |
| `motus/worker/test_async_worker.py`, `test_worker_runtime.py` | 26 + 12 | — | 8 |
| `motus/worker/test_worker_topology.py` | 36 | Docker for 34 (Absurd topology) | 8 |
| `motus/transport/test_zeromq_dispatch_transport.py` | 26 | libzmq with CURVE | 8 |
| `motus/test_execution_contract.py` | 10 | Docker for 1 | 9 |
| `motus/test_gondolin_environment.py` | 32 | node, `ps`, `tar`, `/usr/bin/python3`, fake Gondolin SDK; 1 opt-in `real_gondolin_acceptance` | 9 |
| `motus/test_private_execution_substrate.py` | 23 | Docker for 3 (fail, not skip); 1 opt-in `real_provider_acceptance` | 9 |
| `motus/test_private_file_transfer.py` | 6 | — | 9 |
| `impetus/dsl/test_petrinet_dsl.py` | 42 | — | 10 |
| `telemetry/test_telemetry.py`, `test_telemetry_instrumentation.py` | 29 + 22 | — (instrumentation needs Engine and stores) | 10 |
| `tests/dst/**` | 193 | Engine, JSONL, SQLite; joined worlds (87) need Docker; boundaries need Docker and ZeroMQ | 10 |
| `tests/project/**` | 30 | `ast-grep`, `build`, `twine` (re-expressed as Haskell checks) | 10 |
| `agenticus/{catalog,connection,effect,hands,program,thread,attachment}`, `test_boundaries.py` | 154 | 1 Docker test in `hands/test_workspace.py` without a skip marker; custody tests use `cryptography` AES-GCM | 11 |
| `agenticus/runtime/*` (non-`_real`) | 245 | `test_pi.py` and `test_pi_model_phase.py` need `node`; fakes elsewhere | 12 |
| `agenticus/runtime/*_real.py` | 9 | opt-in markers + `PETRUS_CV16_*` env vars, real CLIs and credentials | 12 |

Around 1,550 test functions in total are in scope for this document. The pytest
defaults to mirror: `--randomly-seed=1729`, per-test timeout 180 s,
`--forbid-skips` (an opt-in suite is excluded by selection, never skipped at run
time), and the three opt-in markers `real_provider_acceptance`,
`real_gondolin_acceptance`, `qualification_installation`.

### 13.5 Benchmarks

Each benchmark runs the same workload definition in both languages (section
3.7), checks output equivalence first, and records commits/fsyncs where
durable. The first column is the suggested benchmark id under `bench/`.

| Id | Workload | Measures | Section |
| --- | --- | --- | --- |
| `engine-pure-chain` | line net, K ∈ {10, 100} transitions, M ∈ {1, 100, 1000} tokens, in-memory store, inline dispatch | turns/s, time to rest | 6 |
| `engine-activity` | N ∈ {100, 10k} independent Activities, in-memory dispatch, both driving policies | begin+accept/s, p50/p99 per turn | 6 |
| `engine-ingress` | burst of N identified deliveries + 64 exact redeliveries each | acceptances/s, redelivery cost (must append nothing) | 6 |
| `engine-timers` | chain with `Delay` maturations, simulated clock | turns/s | 6 |
| `engine-durable` | the above on the SQLite and Postgres (joined) providers | µs/action, commits/action (must equal Python's) | 6 |
| `engine-recovery` | load + first `advance()` over 10k/100k records with K in flight | time to first turn | 6 |
| `history-append` | 10k records cycling every record category, batches of 1 and 8, JSONL/SQLite/Postgres (autocommit and joined) | records/s, p50/p99 per batch | 4 |
| `history-load` | open over 1k/10k/100k records | time to `records` | 4 |
| `fabric-throughput` | 10k envelopes of 1 KiB, drained in batches of 100 | submits/s, drained/s, latency | 4 |
| `process-identity` | 100k spec digests, child ids, envelopes; 10k claims | ops/s | 4 |
| `observation` | N ∈ {1k, 10k, 50k} records, M ∈ {10, 1k} tokens: snapshot, history page, full paged scan, document; writer throughput under a polling reader | latency, allocations, writer stall | 5 |
| `observation-http` | the same state over HTTP/1.0 without keep-alive | req/s, p99 | 5 |
| `simulation` | the spec fixture, a 512-token loop with 256 actions, a scan-heavy net, a 1 MB payload | wall time per `simulate`, allocations | 5 |
| `simulation-http` | the four simulation workloads as POSTs | req/s, p99 | 5 |
| `dispatch-local` | Local SQLite claim/heartbeat/complete over 1k/10k tasks | ops/s, sweep cost | 7 |
| `dispatch-absurd` | dispatch with Q queues, claim/heartbeat/terminal round trips | ops/s, round trips/op | 7 |
| `worker-throughput` | drain K ∈ {1k, 10k} no-op invocations from Local SQLite, sync and async Workers | Attempts/s, p50/p99, RSS | 8 |
| `zeromq-dispatch-rpc` | 5,000 invocations (100 B and 64 KiB), server and clients in each language, 1/8/32 clients | RPC/s, p99, cross-language matrix | 8 |
| `archive` | 10k × 1 KiB, 1k × 64 KiB, 1 × 256 MiB trees: archive, validate, extract | wall time, RSS; archive sha256 must match | 9 |
| `local-execute` | 1,000 × `/bin/true`; 1 MB output | p50/p99, throughput | 9 |
| `gondolin-client` | 1,000 handshakes, 200 executes, 50 MiB attach/export against the same fake-SDK sidecar | client latency | 9 |
| `dsl-build` | flat chain N ∈ {1k, 10k}; stamped child at K ∈ {10, 100, 1000} scopes | build time; projected bytes must match | 10 |
| `telemetry-emit` | per-emit with no/null/recorder sink; 1k-firing run with `off` versus `facts` | ns/emit, overhead % | 10 |
| `dst-replay` | decode/encode/digest of every fixture; 10k-operation toy World; local Engine fixtures | MB/s, ops/s, per-fixture time | 10 |
| `agenticus-custody` | N ∈ {100, 1k, 5k} materialize/release cycles | per-op latency (upstream is O(n²) by design) | 11 |
| `agenticus-effect`, `agenticus-hands`, `agenticus-catalog` | canonical-JSON digests; gateway calls; 100k resolves | ops/s | 11 |
| `agent-net` | 16 phases × 4 proposals, 1,000 episodes, in-memory history, inline dispatch | firings/s; record bytes must match | 11, 12 |
| `codex-jsonl` | parse a 10 MB synthetic Codex event stream | MB/s | 12 |
| `app-end-to-end` | `scripts/cv5-fabric-demo.py` and `cv5-lifecycle-demo.py` equivalents, and a Worker topology run on Absurd | wall time end to end | 4, 8 |

Several upstream paths are quadratic (Engine `records` deep copies, simulation
re-encoding all records per action, custody rewriting the whole document, the
agent-net runner rescanning History). Haskell can beat them without changing
behavior; where a speedup would change observable behavior (commit counts,
fsync counts, file contents), the behavior wins.

## 14. Package decomposition and build order

### 14.1 Principles

- **Mirror the upstream optional extras.** Upstream keeps `psycopg`, Absurd,
  `pyzmq`, and the agent SDKs out of the neutral import graph, and its boundary
  tests assert it. In Haskell, every libpq, libzmq, Node or Python-sidecar
  dependency lives in its own package, so the neutral packages never link them.
- **Keep the kernel boundary narrow.** Packages that do not need `Instance`
  must not depend on `petrus-impetus`, so that they can be built and tested
  before it is finished.
- **Values below, effects above.** Value types that the kernel records (Activity
  invocations, policies, failures) sit below the kernel; everything that
  performs IO against a store or a process sits above the thing it stores.
- **One shared layer per external system.** One SQLite helper (PRAGMAs, DDL text
  checks, `BEGIN IMMEDIATE`), one Postgres connection layer (join mode,
  notifications, advisory fence), one POSIX helper (`flock`, `openat` shims,
  Python-compatible path resolution, fsync, atomic replace, `getrusage`).

### 14.2 Packages

Names are proposals; module names follow `Petrus.<Area>.<Component>`.

This table is the reconciled layout. The *Packaging* sub-sections of the
component sections were researched independently and sometimes propose other
names; where they differ, this table wins. The main renames are:
`petrus-motus-activity` → `petrus-activity`; `petrus-motus-dispatch`,
`petrus-dispatch-local` and the Worker → `petrus-motus`;
`petrus-dispatch-absurd` → `petrus-motus-absurd`;
`petrus-motus-execution` → `petrus-execution`; the Postgres History store
moves out of `petrus-postgres` (which stays kernel-free so that Absurd Dispatch
does not depend on the kernel) into `petrus-history-postgres`; the pure
agenticus layers → `petrus-agenticus-core`; observation and the DSL default to
their own packages rather than modules inside `petrus-impetus`.

| # | Package | Contents | Depends on | Kernel? |
| --- | --- | --- | --- | --- |
| 0 | `petrus-json` (exists) | JSON value, CPython encoder, parsers | — | no |
| 1 | `petrus-posix` | `flock`, `openat` shims, `rmtree`, Python-compatible `resolve`, fsync and atomic replace, `getrusage`/`sysconf` and the RSS gauges, `confstr`, descriptor readiness (`poll`), `getaddrinfo` error codes | `unix`, `directory` | no |
| 1 | `petrus-telemetry` | levels, JSON logger, spans, recorder; re-exports the RSS gauges | `petrus-json`, `petrus-posix` | no |
| 1 | `petrus-activity` | `ActivityInvocation`, `ExecutionPolicy`, `RetryPolicy`, `ActivityFailure`, `ActivityDefinition`, `ActivityDeclaration`, payload converters, heartbeat details, `@activity` equivalent | `petrus-json` | **below** the kernel |
| 1 | `petrus-test-support` (internal) | Docker Postgres resource, fixture loaders pointing into `upstream/`, interop drivers | `petrus-json`, `typed-process`, `postgresql-libpq` | no |
| 2 | `petrus-sqlite` | shared SQLite connection helper and DDL text check | `direct-sqlite`, `petrus-posix` | no |
| 2 | `petrus-postgres` | shared connection layer: join mode, owned transactions, LISTEN/notifications, advisory writer fence | `postgresql-libpq`, `petrus-json`, `petrus-posix`, `cryptohash-sha256` | no |
| 2 | `petrus-http-core` | CPython-compatible HTTP/1.0 server core | `network`, `petrus-json` | no |
| 3 | `petrus-motus` | Dispatch protocols, `InlineDispatch`, `InMemoryDispatch`, Local (SQLite) Dispatch, Worker runtime and CLI library | `petrus-activity`, `petrus-telemetry`, `petrus-sqlite` | no |
| 3 | `petrus-execution` | territory contract, PAX archive codec, Local and Docker providers, Gondolin client + verbatim sidecar, private ArtifactStore/Timeline | `petrus-json`, `petrus-posix`, `typed-process`, `network` | no |
| 3 | `petrus-dst` | DST interpreter, strict artifacts v1–v4, replay, `ChoiceStreams`, process runner | `petrus-json`, `petrus-posix` | no |
| 3 | `petrus-agenticus-core` | catalog, effect, thread, hands contract/grants/conformance, connection custody | `petrus-json`, `petrus-sqlite`, `crypton` | no |
| 4 | `petrus-motus-zeromq` | ZeroMQ transport v2, CURVE files, ZAP, server and client, server executable | `petrus-motus`, `zeromq4-haskell` | no |
| 4 | `petrus-motus-absurd` | Absurd Dispatch, vendored schema with hash pin | `petrus-motus`, `petrus-postgres` | no |
| 4 | `petrus-fabric` | Envelope model and identities, `FabricInbox` against an abstract delivery door; Postgres store as a sub-library or `petrus-fabric-postgres` | `petrus-json`, `petrus-postgres`; `petrus-impetus` for `Token` only | light |
| 4 | `petrus-processes` | call/spawn models and identities, `SpawnActivity`, Postgres lifecycle registry | `petrus-fabric`, `petrus-activity`, `petrus-postgres` | no |
| K | `petrus-cel`, `petrus-impetus` (kernel, other teams) | petrinet, history + codec, binding, selection, instance, scope, net definition v3, net document v1, memory store | `petrus-json`, `petrus-activity`, `petrus-telemetry` | — |
| 5 | `petrus-history-store` | JSONL and SQLite History stores, SQLite writer fence | `petrus-impetus`, `petrus-sqlite`, `petrus-posix` | codec only |
| 5 | `petrus-history-postgres` | Postgres History store, `ensureSchema` | `petrus-impetus`, `petrus-postgres` | codec only |
| 5 | `petrus-dsl` | net authoring DSL (or `Petrus.Impetus.Dsl` inside the kernel, if its owners prefer) | `petrus-impetus`, `petrus-activity` | yes |
| 5 | `petrus-observation` | snapshot, history page, document projection (or inside the kernel) | `petrus-impetus` | yes |
| 6 | `petrus-engine` | Engine, Coordinator, driving policies, clocks, read doors | `petrus-impetus`, `petrus-observation`, `petrus-motus`, `petrus-telemetry` | yes |
| 7 | `petrus-engine-sqlite`, `petrus-engine-postgres`, `petrus-engine-absurd` | provider compositions and writer fences | `petrus-engine` + the matching store/dispatch packages | yes |
| 7 | `petrus-observation-http` | observation HTTP adapter | `petrus-engine`, `petrus-http-core` | yes |
| 7 | `petrus-simulation` (+ `Petrus.Simulation.Http`) | bounded runner, profile `implementation-free-v1`, simulation HTTP | `petrus-engine`, `petrus-dsl`, `petrus-cel`, `petrus-http-core` | yes |
| 8 | `petrus-agenticus` | attachment/episode/retention, Hands gateway and workspace adapter, program and Agent-as-a-Net | `petrus-agenticus-core`, `petrus-execution`, `petrus-dsl`, `petrus-engine` | yes |
| 8 | `petrus-agenticus-runtime` | runtime foundation, profiles, Codex, Codex Gondolin service, Pi adapters and ledgers (with `.mjs` data files), agent-net runner | `petrus-agenticus`, `petrus-history-store`, `petrus-motus` | yes |
| 8 | `petrus-agenticus-runtime-claude`, `-amp` | host side + Python sidecar (uv-locked SDK pins) | `petrus-agenticus-runtime` | yes |
| 9 | `petrus-runtime-tools` | executables that wire providers together: `petrus-worker`, `petrus-zeromq-dispatch`; DST profiles test library | everything above | yes |

### 14.3 Build order and parallel tracks

The critical path is **`petrus-activity` + `petrus-telemetry` → kernel
(`Instance`) → `petrus-engine` → providers, simulation, agenticus runtime.**
Everything else is arranged to come off that path.

**Now, before the kernel is finished** (each bullet can be one engineer):

1. **Foundations** (small, first): `petrus-activity`, `petrus-telemetry`,
   `petrus-posix`, the three `petrus-json` gaps, `petrus-test-support`, and the
   interop and benchmark harnesses of section 3.7. The kernel team needs
   `petrus-activity` and `petrus-telemetry` immediately, because History records
   embed Activity values and `Instance` emits telemetry.
2. **Motus**: `petrus-sqlite`, `petrus-motus` (Dispatch, Local SQLite
   Dispatch, Worker), then `petrus-motus-zeromq`. None of it imports the
   kernel; only the five Local Dispatch tests and the Worker topology tests that
   drive an Engine wait for it.
3. **Postgres and Absurd**: `petrus-postgres`, then `petrus-motus-absurd`. The
   schema-pin, wire and identity tests run without a kernel; the rest need only
   Docker Postgres.
4. **Execution**: `petrus-execution` (archive codec first, because agenticus
   persists its digests; then Local, Docker and the Gondolin client against the
   verbatim sidecar and fake SDK).
5. **HTTP**: `petrus-http-core`, plus the observation and simulation request
   decoders and error mapping, tested against stub engines.
6. **Agenticus core**: `petrus-agenticus-core` (catalog, effect, thread, Hands
   contract, connection custody), then attachment and retention once track 4
   lands.
7. **DST**: `petrus-dst` (interpreter, artifact codec checked byte for byte
   against all 51 world fixtures, `ChoiceStreams` vectors, the process runner).
8. **Fabric and processes models**: envelopes, digests, child ids and reply ids
   with golden vectors; the Postgres stores on top of track 3.

**When the kernel's codec and `Record` type exist** (an early kernel
milestone, before `Instance` is done): `petrus-history-store` and
`petrus-history-postgres`. The JSONL store comes first, because the Engine
tests, the agent-net runner and the DST worlds all use it.

**When `Net`, binding and `Instance` exist**: `petrus-dsl`, `petrus-observation`,
and then `petrus-engine` (the one item on the critical path that this document
owns; give it the strongest engineer and start reading the Coordinator early).

**When the Engine exists** (these can again run in parallel):
`petrus-engine-sqlite`, `petrus-engine-postgres`, `petrus-engine-absurd`;
`petrus-observation-http`; `petrus-simulation`; Fabric ingress and the cv5
demos; `petrus-agenticus` program and Agent-as-a-Net; `petrus-agenticus-runtime`
(start with the only supported surface, the Pi A2 scripted host); DST profiles
and cross-runtime replay; the Engine-dependent Worker topology and telemetry
instrumentation tests.

### 14.4 What this work needs from the kernel

The kernel teams should treat this list as requirements on their public (or
package-internal but exported) API. Each item is cited in the section that
needs it.

- **Dependency direction.** The kernel depends on `petrus-activity` and
  `petrus-telemetry` rather than defining its own Activity types or logging,
  and takes a telemetry handle from the start (section 10).
- **History codec.** `Record` as a closed sum, `encodeRecord`/`decodeRecord`
  with upstream's exact error messages, the record type name, and the
  `occurrence` of a record (section 4). Instants stay JSON numbers that keep
  int versus float (`0.5` round-trips, `10` stays integral).
- **HistoryStore interface** that supports both backend-owned writes and a
  joined transaction (the Engine supplies commits), batch `extend` as one
  commit, the in-memory mirror growing only after the durable write, and
  verify-on-conflict with Python value equality (section 4).
- **Instance doors** used by the Engine, including the ones upstream treats as
  private: `candidates`, `begin`, `bound_handler`, `_commit_completion` with a
  distinguishable "commit refused" error, `fail`, `record_activity_completion`,
  `record_activity_failure`, `complete`, `wake`, `next_maturation`, `armed`,
  `in_flight`, `projection_pending`, `pending_activity_outcomes`, `cancelled`,
  `activity_occurrences`, `accept_delivery`/`complete_delivery` and
  `_canonical_accepted_delivery`, the scope doors, `seal`,
  `firing_failure_text`, `history.replay_cancellation_positions` and
  `selection.fold_history` (section 6).
- **Observation inputs.** Frozen results of in-flight occurrences,
  `replay_markings`, the net definition v3 projection and serializer, and net
  document v1 `project`/`serialize` with lineage types (section 5).
- **DSL inputs.** `Net`, `NetUri`, `NetPath`, the typed binding derivation and
  the payload converter abstraction (section 10).
- **Simulation and Fabric inputs.** `BuiltNet`, sorted `Marking`/`Token`
  shapes, `NetPath` parsing, `FiringOutcome`, `PriorAcknowledgement`
  (sections 4 and 5).

## 15. Risks and open questions

| Risk or question | Why it matters | Proposed handling |
| --- | --- | --- |
| Lock semantics on Linux | GHC's `hLock` silently fails to exclude Python's `flock` | `petrus-posix` `flock` only; cross-language exclusion tests for every lock (section 3.3) |
| `zeromq4-haskell` is unmaintained | may not build on GHC 9.10.3; lacks ZAP and cert loading | spike it first in track 2; fall back to a thin FFI |
| Claude and Amp are SDK-only | no protocol to speak from Haskell | Python sidecars with locked SDK pins; define and document their protocol in the owning package |
| Claude CLI protocol details were not verified from source | the research used general knowledge for the `stream-json` control protocol | settled by the sidecar decision; revisit only if the sidecar is dropped |
| jsonb round trip of large floats | `1e16` may come back as an integer and look like a conflict on redispatch | confirm against Docker Postgres in track 3 before relying on it (section 7) |
| `FiringFailed.error` is Python-repr-shaped | Haskell exceptions cannot produce the same text | accept as a documented divergence for Haskell-raised errors; keep the `ActivityFailure` path exact |
| Upstream quirks that look like bugs | Local Dispatch loses a long `retry_after`; `pi_model_phase` ASCII-escapes tool results that the JS helper does not; observation HEAD returns a body | preserve for parity, list them in PARITY.md, report upstream rather than fixing silently |
| HTTP byte compatibility | stdlib pre-handler errors and the `Server` header cannot be matched exactly | match status codes and JSON bodies; emit our own `Server` value; document |
| DST cross-runtime replay | the strongest behavioral equivalence test, but it needs the profiles ported with identical identity dicts | plan it as a deliverable of the Engine milestone, not as an afterthought |
| Where DSL and observation live | upstream puts them in `impetus`; the kernel team owns that package | default to separate packages (`petrus-dsl`, `petrus-observation`) unless the kernel owners prefer modules |
| SCOPE.md mentions OpenTelemetry collectors | at this pin `telemetry.py` is a JSON-line logger (env `IMPETUS_TELEMETRY_LEVEL`), not OpenTelemetry | parity means the `impetus_*` event names and fields; an OpenTelemetry sink is an optional extra; correct SCOPE.md |
| E2B | no Haskell SDK; upstream uses it only in opt-in tests | defer; keep the provider record open |
| Moving the pin | thousands of quoted lines and line numbers here | `scripts/upstream-diff` lists the touched files; re-verify the matching sections and mark them `in progress` in PARITY.md |
