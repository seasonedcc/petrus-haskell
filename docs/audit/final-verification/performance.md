<!-- Dated record: final verification (2026-10-13). Every finding is resolved; see ../final.md. -->

# Verifier C: performance (outcome 6) and review of f87d05b

Main checkout at f12bfd6 (f12bfd6, 50635f0 and df073f3 after f87d05b are results/doc-only). Read-only; no cabal
builds, no benchmarks. Scratch evidence: `final-verify/performance/` (check.txt, markers.txt, intervals.txt,
core/, core2/, torat.hs).

## Findings

No BLOCKER. No MAJOR.

### MINOR 1: dst joined checkers still compare numbers through `toRational` (NaN/inf), contrary to three claims
- Where: `packages/petrus-dst/joined/Petrus/Testing/Dst/Joined/Support.hs:391-409` (`pyNum :: Json -> Maybe Rational`,
  `Float d -> Just (toRational d)`, `pyLe`, `pyLt`); `packages/petrus-dst/joined/Petrus/Testing/Dst/Joined/Checkers.hs:60-80`
  (`type N = Maybe Rational`, `(.==)`, `(.<=)`, `eqs`, `les`, `plus`).
- What: f87d05b moved the joined checkers' *value* equality (`pyIn`, `pyCount`, ...) to `pythonEq`, but the numeric
  checkers (`.==`, `.<=`, `eqs`, `les`, `pyLe`, `pyLt`) still go through `toRational`. `runghc` (scratch torat.hs):
  `toRational (1/0) == 2^1024` is True; `toRational nan == toRational nan` is True; NaN maps to a large positive
  rational, so `NaN <= x` / `x <= NaN` follow it. CPython: `nan == nan` False, `inf == 2**1024` False, every NaN
  ordering False.
- Claims contradicted: f87d05b message ("NaN equals nothing and an infinity no integer"); Support.hs:22 module header
  ("a NaN equals nothing", true for `pythonEq` users only); `packages/petrus-dst/bench/RESULTS.md:49-51` ("where they
  had their own == that compared numbers through `toRational` (wrong for NaN and the infinities)"), which implies the
  `toRational` path is gone.
- Outcome: 1/5 (fidelity of the DST oracle). Effect only on malformed/non-finite evidence; no performance effect.
- Fix: `type N = Maybe PyNumber`, `(.==)` = `pyNumberEq`, and a NaN/inf-aware `pyNumberCompare` (see MINOR 2) for
  `.<=`/`pyLe`/`pyLt`; or scope the header and RESULTS sentence to equality-of-values.

### MINOR 2 (design): numeric Python comparison still duplicated outside Petrus.Json.Value
- Where: `packages/hamsterdan-readiness/src/Hamsterdan/Readiness/NetV5/Py.hs:149` (`data Num' = Exact Integer |
  Inexact Double`, a copy of `PyNumber`) and `:181-196` (`numericCompare`); `packages/petrus-engine-file/src/Petrus/EngineFile/Loader.hs:233-249`
  (`numLt` over `Either Integer Double`); dst `pyNum` (MINOR 1).
- What: f87d05b made `==` single-sourced ("one Python == numeric core") but ordering has three private cores, one of
  them wrong (MINOR 1). Not a correctness bug in readiness/engine-file as far as read.
- Fix: export `pyNumberCompare :: PyNumber -> PyNumber -> Maybe Ordering` beside `pyNumberEq` and use it in all three.

### MINOR 3: `writeDirect` haddock understates the blocking scope
- Where: `packages/petrus-posix/src/Petrus/Posix/File.hs:113` ("While the call runs, no other Haskell thread of the
  capability runs ...").
- What: an in-progress unsafe call also blocks stop-the-world GC sync, so with `-threaded` a stalled write (terminal
  flow control, a slow char device) stalls every capability at the next GC, not just its own. Behaviourally this
  matches Node's single loop (the comparison target), and the design otherwise satisfies the README low-level rule
  (see Verified holding, Part 2).
- Outcome: documentation accuracy.
- Fix: add "and the next garbage collection, which waits for it, so a write that blocks (a terminal under flow
  control) pauses the whole program".

### MINOR 4: fingerprint ignores `test/` sources compiled into 11 benchmark stanzas
- Where: `scripts/bench_results.py:188-193` (`counted()` excludes `test/`, `differential/`, `upstream-tests/`);
  documented `docs/reproducing.md:384-397`.
- What: benchmark stanzas with `hs-source-dirs` into `test`: hamsterdan-export, hamsterdan-host, hamsterdan-operator,
  petrus-dst, petrus-engine-absurd, petrus-observation-http, petrus-simulation; into `../petrus-impetus/test` /
  `../petrus-engine/test`: petrus-engine-postgres, petrus-engine-sqlite, petrus-engine,
  petrus-telemetry-instrumentation. A change there does not mark results stale. Only actual instance since
  measurement: `packages/petrus-engine-absurd/test/Petrus/Engine/Absurd/Support.hs` in f87d05b (old truthy treated any
  Float as True), which its carry reason discloses by hand, so no results file is wrong today.
- Outcome: 6 (staleness detection).
- Fix: count every benchmark stanza's `hs-source-dirs` (and their local-dep closure) as sources.

### MINOR 5: two carry reasons slightly overstate "off its path" (conclusions hold)
- `packages/petrus-engine-absurd/bench/RESULTS.md:4` (c33829e carry): "the petrus-json/posix changes are off its
  measured path". The bench's round trip opens a lane on rotation -> `openAbsurdWorkerDispatch`, which draws
  `uuid4` (`packages/petrus-motus-absurd/src/Petrus/Motus/Dispatch/Absurd.hs:750`), whose hex digits changed to
  `intToDigit` in that interval. Negligible, but the claim is literally false; petrus-motus-absurd's carry corrected
  the same wording, engine-absurd's did not.
- petrus-cel's c33829e reason names only Tz and omits the petrus-json/posix changes in its closure (off path: cel
  imports only `pythonStrRepr` and similar); the c33829e reasons of observation, simulation, processes, engine,
  engine-absurd and engine-postgres omit cel's Tz change (off path: no time-zone keys in those benches).
- Outcome: 6. Fix: amend the wording at the next carry ("uuid4's digit rendering changed; one call per lane open").

### MINOR 6: petrus-dst "Current figures" table shows an older-code row
- Where: `packages/petrus-dst/bench/RESULTS.md:90`: `joined.one isolated database` 53.3 ms vs 53.1 ms, 1.00×
  (Haskell 0.4% slower), from 15 repetitions at 81bbdc5; the f87d05b measurement of this row (1.03×) is prose only.
  bench-results/summary.md's "worst 1.00×, measured at f87d05b" for petrus-dst therefore cites a pre-f87d05b row.
- It is an accepted level row (user decision), so not a BLOCKER.
- Fix: tabulate the f87d05b figure under "Current figures" and move the 81bbdc5 row to superseded.

### MINOR 7: PARITY wording vs a 1.00× row
- Where: `PARITY.md:93` (petrus-sqlite): "every row faster in wall-clock time; the fsync-bound transaction rows close
  to level". `packages/petrus-sqlite/bench/RESULTS.md:39` `tx.immediate-insert-100` is 327 µs vs 327 µs, 1.00×.
- Fix: "every row faster or, for the fsync-bound transaction rows, level".

## Verified holding

### 1. Results files current; carry reasons true
- `scripts/bench --stale`: 0 stale. `scripts/bench --check` (scratch check.txt, exit 0): 43 CARRIED lines, last line
  "39 benchmark packages document their rerun and the sources they measured; bench-results/summary.md is current".
  bench-results/summary.md: "46 results files; none with a row below 1.0×".
- Measured at f87d05b: petrus-dst, petrus-history-store, petrus-viewer-server. Carried df073f3 -> f87d05b:
  all hamsterdan-*, petrus-agenticus, agenticus-core (RESULTS + custody), agenticus-runtime (3 files), engine-file,
  engine-sqlite, execution, motus, motus-zeromq, sqlite. Others: older measurement -> c33829e carry -> f87d05b carry.
- Closure diffs per carry interval computed (scratch scripts/intervals.py -> intervals.txt); >20 reasons checked
  against the diff, every "identical Core"/"names only"/"pure move" claim included:
  - "Json == compiles to the same optimized Core as at 50635f0": TRUE. ghc-9.10.3 -O2 `-ddump-simpl` of
    Petrus.Json.Value and Petrus.Json.Python.Object at 50635f0 vs f87d05b (scratch core/, core2/): `Rec:pythonEq`
    identical modulo renames intFloatEq->exactFloatEq, Numeric->PyNumber, NInt->PyExact, NFloat->PyInexact;
    `$wexactFloatEq` identical modulo one variable name; `exactEq`, `typeExactEq`, `$fEqJson` identical; PyObject
    `pyEq` and `$fEqPyObject_$c==` identical.
  - PyLiteral -> Lit* rename: names only (diff).
  - "pythonTruthy, the same seven equations": every removed copy (Hamsterdan.Python.Value.truthy, agenticus-runtime
    Claude pyTruthy, execution Docker/Gondolin truthy) matched clause for clause; engine-absurd test Support's
    differing Float clause is disclosed.
  - literalInt (impetus Pydantic), motus Local PyValue Eq, hamsterdan-contracts Codec, history-store
    floatEqualsInteger: same exact int/float test; floatEqualsInteger reached only for SQLFloat/Float, never written.
  - `checkBindLength = either throwIO pure . bindLength kind`, the expression the bind loop already ran.
  - petrus-posix f87d05b: additions only (DirectFd, directFd, writeDirect, export list, docs).
  - Scoped reasons checked against bench sources: fabric (Postgres only, no uuid; bench/Main.hs), telemetry-instrumentation
    (in-memory store and dispatch), observation/observation-http/simulation/engine (in-memory/JSONL; the only SQLite
    bench use is agenticus-core Bench/Custody.hs, remeasured at df073f3), agenticus-core catalog/effect/hands/thread
    (no SQLite), processes/history-postgres (Postgres), hamsterdan-testing (links only petrus-dst's main library; only
    the engine/ and joined/ sublibraries changed), petrus-json loads (admit path decodeText -> parseInPlace, then
    parseOrExplain -> parseJson first: unchanged), cel (Tz.normpath now Petrus.Posix.Path.normpath, key validation only).
  - c33829e bind-length guard (59b0a85/c33829e) adds one INT_MAX comparison per text/blob bind; the SQLite-bound
    packages were remeasured at df073f3 after it.
- CI green on main through f12bfd6 (run 38373608884).

### 2. Rows: all ≥ 1.0× as reported; every row under 1.10×
| File:line | Row | Ratio | Note |
|---|---|---|---|
| packages/hamsterdan-agents/bench/RESULTS.md:55 | keys/seal | 1.03× | |
| packages/hamsterdan-agents/bench/RESULTS.md:57 | agent turn | 1.07× | |
| packages/hamsterdan-github/bench/RESULTS.md:50 | webhook verify | 1.09× | |
| packages/hamsterdan-operator/bench/RESULTS.md:69 | qualification-setup | 1.04× | accepted level |
| packages/petrus-agenticus-runtime/bench/results-pi.md:63 | pi-model-phase-turn | 1.07× | |
| packages/petrus-agenticus-runtime/bench/results-pi.md:64 | pi-ledger-cycle | 1.09× | |
| packages/petrus-dst/bench/RESULTS.md:90 | joined.one isolated database | 1.00× | accepted level (MINOR 6) |
| packages/petrus-engine-absurd/bench/RESULTS.md:36 | create-close | 1.08× | |
| packages/petrus-execution/bench/RESULTS.md:86 | sidecar/handshake | 1.01× | 0.031 vs 0.031 ms, 4 of 5; shared Node sidecar both sides |
| packages/petrus-execution/bench/RESULTS.md:87 | sidecar/execute | 1.05× | 4 of 5; earlier 2-round 0.96× superseded by 5 dedicated rounds |
| packages/petrus-motus/bench/RESULTS.md:111 | local.open-fresh | 1.07× | 3 of 5 |
| packages/petrus-motus-zeromq/bench/RESULTS.md:101 | memory/claim-empty-100 | 1.05× | |
| packages/petrus-posix/bench/RESULTS.md:32 | flock.open-tryLock-close | 1.01× | |
| packages/petrus-posix/bench/RESULTS.md:36 | atomic.write-1KiB-fsync | 1.01× | |
| packages/petrus-sqlite/bench/RESULTS.md:38 | tx.immediate-insert-commit | 1.07× | accepted level |
| packages/petrus-sqlite/bench/RESULTS.md:39 | tx.immediate-insert-100 | 1.00× | accepted level, 327 vs 327 µs |
| packages/petrus-viewer-server/bench/RESULTS.md:183 | open-file, 1 client, best of 3 | 1.05× | |

No other row below 1.0×; no BLOCKER.

### 3. Equivalence and fairness (both sides read, 10 packages)
- petrus-sqlite: same DDL, WAL + synchronous=FULL on both, same inserts, BenchTwin protocol both sides.
- petrus-fabric: same values/ops, one autocommit connection each.
- petrus-execution: per-call ns clock (`clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`) vs `perf_counter`; same 20 warm-ups,
  1000 handshakes.
- petrus-posix: same fsync(2) (no F_FULLFSYNC either side); Python's atomic write also does one extra unlink
  (small, documented; does not change the 1.01× reading's level status).
- petrus-motus-zeromq: each client against its own server over IPC.
- petrus-motus: same pragmas; twin protocol for open-fresh; Python-only "-closing" variants documented.
- hamsterdan-agents: same inputs, deterministic repository.
- petrus-telemetry-instrumentation: same in-memory chain.
- petrus-viewer-server: runner checks workload status counts; "best vs best" puts the no-log variant on each side.
- petrus-dst: same 33 fixtures, fresh isolated database each, same server.
- Interleaving: scripts/bench-compare; 3 repetitions, up to 5 under 1.15× (user decision).

### 4. Real-use coverage
- Firing small/large nets: impetus instance-run wide-fanout/long-fifo; engine.chain; engine orders-small/large
  (+jsonl/sqlite); engine-postgres advance-chain; simulation payload-400k-fire; telemetry chains; dsl chain-1000/10000.
- History append/replay: history-store sqlite/jsonl/in-memory append + load; history-postgres append/load 1k/10k;
  impetus history.replay-marking; dst replay rows; engine load rows; hamsterdan-testing world.replay.
- Store reads/writes: sqlite/postgres query and tx rows; fabric and processes Postgres rows; engine-sqlite.
- Simulation: 8 petrus-simulation rows including HTTP.
- Observation paging: petrus-observation snapshot/history_page/full-scan N=1000/10000; observation-http
  history after=0 limit=100.
- End-to-end CLI/app: viewer cold start and all HTTP scenarios; engine-file `--infile/--outfile` process rows;
  hamsterdan-host `serve` start to /healthz; hamsterdan-operator inspect; hamsterdan-export.
- No bench, none a gap: hamsterdan-e2e (test harness), petrus-argparse (exercised via CLI rows), petrus-telemetry
  (via telemetry-instrumentation), petrus-test-support. Viewer simulation runs in the browser (README/PARITY), out of
  backend scope.

### 5. Rerunnability
All 46 files state machine, rerun command, date; `scripts/bench --list` prints each package's rerun block;
README.md:53 and docs/reproducing.md:264-440 document scripts/bench, bench-compare, `--stamp/--carry`, `--smoke`.

### 6. Harness
StrictData throughout; whnf benches force via size/length/forced results; BenchTwin uses `getMonotonicTime` per
batch over fixed batches (1 µs resolution adequate at batch scale); tasty-bench batches internally; petrus-execution
uses a ns clock for per-call rows; warm-up treated alike (BenchTwin 1 warm-up both sides). No one-sided logging,
connection reuse or warm cache found in the spot-checked packages.

### 7. Figures placement / overclaims
`scripts/lint-bench-figures`: "no benchmark ratio restated in 101 parity and divergence documents". PARITY claims
checked: hamsterdan-export PARITY.md:99 "at least as fast on every row" (holds); petrus-engine-absurd PARITY.md:21
"faster on every row" (1.08×, 1.28×: holds); viewer "ahead of Node" claims match Run K. Only PARITY.md:93 loose
(MINOR 7).

### Part 2: f87d05b
- One `==` numeric core: `pyNumberEq`/`exactFloatEq` in Petrus.Json.Value, `GHC.Exts.inline` at the `pythonEq` call
  site; Core identical to the pre-move code (above). Semantics match CPython: int vs float exact (no
  float(int) rounding), NaN equals nothing, an infinity equals no int, `True == 1`.
- `pythonTruthy`: None/False/0/0.0/""/[]/{} falsy, all else truthy (CPython `bool()` on json.loads values); copies
  removed as claimed.
- DST joined worlds: value equality via `pythonEq` holds; numeric comparisons do not (MINOR 1).
- `Lit*` rename: names only, removes the clash with PyObject constructors.
- `checkBindLength`: total, names the existing guard, raises the same exception.
- petrus-posix `DirectFd`: newtype with smart constructor `directFd` (fstat: regular file or character device only;
  pipes and sockets are refused); `writeDirect` (File.hs:125-131) loops over short writes, retries EINTR via
  `throwErrnoIfMinus1Retry`, raises IOError; viewer `Log.hs` DirectLogger uses `Posix.directFd`/`writeDirect` and `logLine` catches
  IOException as the old `writeAll` path did. README low-level rule satisfied: lowest layer, safe total interface,
  measurement beside it (petrus-posix RESULTS "writeDirect" section; viewer RESULTS "Low-level code, measured":
  safe `writeAll` 0.74× / behind Node 0.92×, unsafe path 1.27× MCP 16-in-flight in Run K). Haddock caveat: MINOR 3.
