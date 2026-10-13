<!-- Dated record: confirmation audit at d869f62 (2026-10-12). Every finding is resolved or decided; see ../final.md. -->

# Confirm audit: perf-design

Tree: `d869f62` (main), audited read-only in worktree `agent-a8d57136ea9c3f535`. No local A/B builds were run (load average 9-10 from six other auditors; a local A/B would not be decisive). The figures below come from the committed RESULTS files and from the CI logs and artifacts of runs 38249569895 and 38255030541. These are saved under `scratchpad/confirm-audit/perf-design/`: `job-*.log`, `artifacts/r1/probe-{a,b}` and `artifacts/r2/bench-gate-{1..4}`. The survey script is `perf-design/survey.py` and its output is `survey.txt`: 195 source files containing low-level constructs.

The rule under test (README.md:20-23): speed never at the cost of design. A low-level optimization is allowed only where a benchmark shows the clean version cannot keep up with Python. It must sit behind a safe, total interface in the lowest layer that can hold it, with the measurement recorded beside it.

## Summary

| Severity | Count |
|---|---|
| BLOCKER | 0 |
| MAJOR | 4 |
| MINOR | 12 |

MAJOR:

- **PD-1.** The viewer's hand-written HTTP front (HttpFront.hs plus cbits/http_front.c) is not necessary. Its own Run E shows the previous Warp server already beat Node by 1.03-1.16x by median.
- **PD-2.** hamsterdan-operator FastJson is a second, unmeasured JSON parser on Text internals, in a high-level package.
- **PD-3.** petrus-postgres `tx.join-insert-commit` is bimodal on Linux CI. The Haskell row is a cold tasty-bench mean, while the Python twin uses a calibrated median-of-10. Under this mismatch, per-process placement noise (both sides vary 48-89 µs) shows up as 0.83x.
- **PD-4.** 42 of 46 results files are stale against HEAD (baf5836/9e691e8). Outcome 6 cannot be claimed until the full rerun described in §3 is done. This is already known and scheduled.

## 1. Earlier findings (final-audit/verify-perf.md)

| ID | Status at d869f62 | Evidence |
|---|---|---|
| FA-V-1 (JSONL batch append slower than Python) | **Resolved** | history-store RESULTS "Current figures" at da94728: `jsonl.append-one-batch` 2.89x on the Mac, 2.11-2.25x on CI bench-gate. The attribution table records each change, e.g. the dropped event-id buffer at -2.7% and `dumpsMany` at -14%. |
| FA-V-2 (nothing re-measures, figures stale) | **Resolved as a mechanism** | Four parts: (1) `<!-- scripts/bench: measured sources FP at COMMIT -->` fingerprints; (2) `scripts/bench --stale/--check/--stamp`; (3) the nightly bench-gate (ci.yml:361-403: schedule or `full` dispatch, 4 shards, 5 interleaved reps, rerun below 1.0); (4) `bench-results/summary.md`. The bulk stamp f5dc26c at 5a73d7a is consistent: the figures date from 81bbdc5, only 5 commits earlier, and the measured code was unchanged apart from motus-zeromq, which was measured with the new wait. The mechanism correctly flags 42 files as stale now (PD-4). Residue: PD-15. |
| FA-V-3 (main unprotected) | Not in this area (outcome 7) | — |
| FA-V-4 (SQLite/fsync rows thin; build differences) | **Resolved** | petrus-sqlite RESULTS:69-85 records the comparison: `PRAGMA compile_options`, `synchronous` (2), `fullfsync`/`checkpoint_fullfsync` (0), WAL. Durability is the same on both sides. The thin rows show per-rep spread and "won k of n". Rows Linux cannot win for kernel reasons (sqlite `tx.immediate-insert-commit`, posix `atomic.write-1KiB-fsync`, execution `one-large/extract`, where a bare 256 MiB `write(2)` takes 58-67 ms on the runner) are left out of the gate with the reason written down (scripts/bench-gate docstring; execution RESULTS:50). |
| FA-V-5 (execution compare.py always Python first) | **Resolved** | packages/petrus-execution/bench/compare.py:8-13,50-51 alternates which side goes first and reports per-round lows and "won k of n". hamsterdan-agents still compares Python best-of-5 with the Haskell mean (RESULTS:66-67). That is conservative against Haskell, so acceptable. |
| FA-V-6 (stateful rows, different iteration counts) | **Partially resolved** | `Petrus.TestSupport.BenchTwin.twin` exists and applies the twin's fixed-batch median protocol to petrus-sqlite tx rows (bench/Main.hs:61-70), history-store `sqlite.append-per-record` (bench:145) and motus `local.open-fresh` (bench:255). The petrus-postgres tx rows still use tasty-bench means under `RelStDev 0.2` (bench/Main.hs:70-93). That is PD-3. |
| FA-V-8..11 | Not in this area | — |

## 2. Design sweep (item 1)

Legend:

- **(a)** safe, total interface in the lowest layer that can hold it;
- **(b)** measurement recorded beside it;
- **(c)** strictly necessary, i.e. the clean version measured below Python.

"Correctness" means the construct exists for exact CPython parity, not speed, so the perf rule does not apply.

### 2.1 Constructs that hold

| Construct | Where | (a) | (b) | (c) | Note |
|---|---|---|---|---|---|
| Ryu float repr, BoundedPrim | petrus-json `Petrus/Json/Float.hs` | yes | n/a | correctness | `float.__repr__` parity; shared by every float path, including fabric Canonical. |
| WTF-8 Text (`unsafeTextFromBytes`) | petrus-json `Wtf8.hs` | yes | n/a | correctness | Lone surrogates as CPython keeps them; documented design. |
| Hand-written JSON parser | petrus-json `Parse.hs` | yes | yes (RESULTS 1.7-3.0x) | correctness | `json.loads` parity: errors, duplicate keys, big ints. The SWAR/hash parts are covered in PD-9. |
| `dumpsMany` batch writer | petrus-json `Encode.hs:164` | yes | yes (history-store RESULTS, -14%) | yes for FA-V-1 | Total, pure interface via `unsafeDupablePerformIO`. |
| uuid4 via `getentropy` capi | petrus-json `Python/Uuid.hs` | yes | n/a | correctness | — |
| Path marshalling: one-pass ASCII copy plus pointer-equality one-entry cache | petrus-posix `Internal.hs:30-85` | yes (lowest layer; can only miss) | yes (posix RESULTS:95-117: 1.2 µs → 0.23 µs; `path.*` rows were 1.31x before, `flock.open-tryLock-close` 0.93 → 0.97x) | yes (flock row was below 1.0) | A model of the rule. |
| Fabric canonical encoder (two-pass, `pokeByteOff`, Builder.Prim) | petrus-fabric `Canonical.hs` | total (`Nothing` defers to petrus-json for refusals) | yes (fabric RESULTS:125: 326 µs = 2.4x slower → 57.8 µs = 2.34x) | yes | Placement is covered in PD-12. |
| `spawn` C primitive (closes fds in C) | petrus-execution `Internal/Process.hs:95-98`, cbits | yes, safe call | yes (about 0.1 s per spawn without it) | yes | Placement is covered in PD-13. |
| bzip2 binding and streaming decompressors | petrus-execution `Archive/Stream.hs:253-259` | yes | n/a | correctness (no bzip2 in Haskell deps) | — |
| SQLite `busy_timeout` unsafe import; `stepNoCB` for later steps | petrus-sqlite `Connection.hs:298, 476-480` | yes | stepNoCB qualitative | — | Harmless: non-blocking calls. |
| Viewer relay event loop (kqueue/epoll, unsafe recv/sendv) | petrus-viewer-server `EventLoop.hs:61-72`, cbits/relay_io.c | yes, package-local | yes (Runs A/B: relays at 0.83-0.98x vs bare `ws` before; now 1.09-1.41x) | yes | — |
| Viewer RTS defaults `-N1 -qg -A16m` | viewer cabal | — | yes | yes | — |
| History-store attribution table | history-store RESULTS "Current figures" | — | yes | — | A model for how every optimization should be recorded. |
| argparse `ioctl TIOCGWINSZ`, hamsterdan-host `gai_strerror`, bench `getloadavg` | various | yes | n/a | correctness | — |

### 2.2 Constructs that do not hold

| Construct | Where | Verdict | Suggested simplification | Finding |
|---|---|---|---|---|
| Hand-written HTTP front (accept loop, parser, response writer, C date/accept helpers) | petrus-viewer-server `HttpFront.hs` (542 lines, FFI :80-83), cbits/http_front.c | (b) yes; (c) **no** | Return to Warp for HTTP and keep the relay loop and the atomic pending-file take. | PD-1 |
| FastJson parser on Text internals | hamsterdan-operator `Operator/FastJson.hs` (204 lines), used at `Operator/Python.hs:141` | (a) no, (b) no, (c) unknown | Delete it, or move it into petrus-json behind a benchmark. | PD-2 |
| `waitReadableFor` C poll and 15 raw `ccall unsafe` libpq imports | petrus-postgres `Internal.hs:358-390, 425-439`, cbits/petrus_postgres.c | (a) yes; (b) **no**; (c) unproven | A/B and record, else use `threadWaitRead` and postgresql-libpq. | PD-3, PD-8 |
| Text ByteArray# bind (`petrus_sqlite_bind_text`) | petrus-sqlite `Connection.hs:442-459` | (a) yes; (b) yes (4-6%: 73.5 → 69.0 ms); (c) **no**: the row is about 1.83x without it | Keep with a note, or drop for `bindText`. | PD-5 |
| `casMutVar#` CAS, two copies | agenticus-core `Internal/Atomic.hs:18-30`; impetus `HistoryStore.hs:51,105-118` | (a) **no** (high-level modules, duplicated); (b) **no** | Use `atomicModifyIORef'`, or one shared helper with a number. | PD-6 |
| C JSON string escaper | petrus-viewer-server `Json.hs:145-158`, cbits/json_escape.c | (b) no isolated A/B; duplicates petrus-json | Use petrus-json's escaper. | PD-7 |
| C file reader (`petrus_open_read`, raw read/close/access) | petrus-viewer-server `FileIO.hs:32-36`, cbits/file_io.c | (b) no isolated A/B | Use `BS.readFile` or petrus-posix. | PD-7 |
| SWAR `findSpecial`, STUArray `hashesCollide` pre-check | petrus-json `Parse.hs:311-330, 350-372` | (a) yes; (b) **no** | A/B and record, or drop. | PD-9 |
| `copyAscii` | petrus-json `Parse.hs:383, ~472-478` | Reimplements `TE.decodeLatin1` (ASCII is checked already) | Use `decodeLatin1`/`decodeASCII`. | PD-9 |
| Two encoders (direct mutable-buffer writer and Builder) | petrus-json `Encode.hs:145-164, 364ff` | (b) the writer vs Builder has no number; `reserve`-before-`poke` is a convention, not a type | Record the A/B; keep one. | PD-9 |
| Text-array literal printer (`written`/`bound` plus `TA.unsafeWrite`) | hamsterdan-contracts `PyLiteral.hs:185-230` | (a) total only if `bound` is right; (b) **no** before/after (RESULTS:78-79 is qualitative); (c) unknown | Builder, or petrus-json's writer. | PD-10 |
| Own `fstat`/`lstat`/`fstatat`/rmtree/`confstr` C layer | hamsterdan-operator `Posix.hs:55-61`, cbits/stat.c, rmtree.c | (a) **no**: duplicates petrus-posix `At` | Depend on petrus-posix. | PD-11 |
| `Resource` (`maxRssMb`, own `petrus_maxrss`/`page_size`) | petrus-posix `Resource.hs:8-40` | Dead outside its own tests and bench; duplicates petrus-telemetry `Telemetry.hs:552-590` and its cbits | Keep one, in petrus-posix, used by telemetry. | PD-11 |
| fd "wait readable" poll C, two copies (zeromq does the same with `zmq_poll`) | petrus-postgres cbits; petrus-execution `Providers/Gondolin.hs:554-562` and cbits | (a) **no**: belongs in petrus-posix | One `waitReadable :: Fd -> Maybe Double -> IO Bool` in petrus-posix. | PD-13 |
| errno → OSError-subclass tables (×3) and strerror FFI (×2) | engine-file `PyText.hs:128-147` (partial); hamsterdan-contracts `Python/Exception.hs:116-136`; telemetry `ErrorType.hs:73-79, 138-159` (C `ENOTCAPABLE` via `unsafePerformIO`) | (a) **no** | One table in the lowest Python-error layer. | PD-14 |

## 3. Outcome 6: coverage, twins, rerun scope (item 2)

**Coverage of real-use paths holds:**

- **Firing on small and large nets:** impetus instance-run wide-fanout and long-fifo; engine orders-small, orders-large and chain.
- **History append and replay:** history-store (jsonl and sqlite append-per-record, one-batch, load, resume); history-postgres.
- **Store reads and writes:** petrus-sqlite, petrus-postgres, engine-sqlite, engine-postgres.
- **Simulation:** petrus-dst; twin `scripts/bench.py`.
- **Observation paging:** observation `history_page` and full-scan; observation-http.
- **End-to-end CLI and app runs:**
  - hamsterdan-host process rows (validate, inbox, requeue, inspect-instance, serve, sweep);
  - engine-file `process_bench`;
  - operator, export and github CLIs;
  - agenticus whole Turns and the Pi ledger;
  - viewer cold start, relay, open-file and MCP.

**Every ported component with a bench has a Python twin.** The viewer is compared with the Node server it replaces, which is the right twin. Packages without their own bench are covered elsewhere:

- petrus-argparse: by the CLI process rows;
- petrus-telemetry: by telemetry-instrumentation;
- hamsterdan-e2e and petrus-test-support: test-only.

**Committed and rerunnable holds.** Every RESULTS.md has a `<!-- scripts/bench: rerun -->` block and a fingerprint, and `bench-results/summary.md` lists 46 files, none below 1.0x at their measured commit.

**PD-4: 42 of 46 are stale.** The cause is baf5836/9e691e8: the petrus-json `Encode` writer and `dumpsMany`, and the petrus-sqlite Text bind. Those sit under nearly every package. A full rerun must cover:

1. **All 42 files** reported by `scripts/bench --stale`, each through its own rerun block, and then `--stamp`.
2. **These rows first**, because they can move:
   - every SQLite-backed row: petrus-sqlite tx rows, history-store `sqlite.*`, engine-sqlite, impetus with a sqlite store, hamsterdan-host process rows;
   - every JSON-encode-heavy row: history-store `jsonl.*` and `encode-payload`, fabric canonical and digest rows, observation paging and HTTP, export, viewer MCP;
   - the thin rows: postgres `tx.*`, motus `local.*` and roundtrip, motus-zeromq memory rows, execution `archive/*/extract`, viewer 1-client rows.
3. **The same protocol for both sides:**
   - stateful rows through `BenchTwin` on the Haskell side;
   - 5 interleaved reps on a quiet machine;
   - per-rep spread and "won k of n" for any row under 1.15x.
4. **A Linux pass:** the nightly bench-gate (`gh workflow run ci.yml -f full=true`), because Linux is where postgres, zeromq and fsync rows diverge from the Mac. Plus a separate viewer pass, since the gate leaves the viewer out (PD-15).

## 4. petrus-postgres `tx.join-insert-commit` (item 3)

**Data.** Per-process figures from the artifacts, in µs:

| Run | Haskell (5 processes) | Python (5 processes) |
|---|---|---|
| r1 probe-a | 47.8, 52.7, 64.7, 50.3, 73.9 | 59.8, 61.8, 62.0, 57.3, 65.1 |
| r1 probe-b | 51.9, 83.0, 88.2, 71.6, 86.1 | 72.3, 62.7, 68.9, 75.2, 61.4 |
| r1 probe-b rerun | 50.7, 88.9, 67.8, 87.9, 88.4 | 79.0, 79.6, 57.0, 73.6, 57.2 |
| r2 (d869f62) gate-1 | 56.6, 50.4, 77.4, 51.1, 48.4 | 65.2, 75.1, 76.9, 54.4, 54.5 |

Run 38249569895 is the r1 probe jobs at d6b1bf9. Run 38255030541 is main at d869f62; it gated at 1.28x.

**What the data show:**

1. **Both sides are bimodal per process.** Haskell is about 48-56 µs or 72-89 µs; Python about 54-62 µs or 69-80 µs. So the slow mode is an environmental per-process factor, not a Haskell code path. The most likely cause is where the fresh client process and its fresh backend land on the runner's vCPUs: same or sibling core versus cross-core wake-up, plus the new backend's warm-up. A transaction is three or four socket round trips to the server, so the wake-up latency is the whole cost.
2. **The harnesses amplify it differently.**
   - Haskell: tasty-bench `RelStDev 0.2` (bench/Main.hs:70-93) stops after 0.06-0.32 s of measurement. The logs read e.g. "50.4 μs ± 11 μs (0.06s)" and "77.4 ± 21 (0.32s)", and it reports the **mean** of a cold, short window with σ about 15-25%.
   - Python (bench/python_bench.py, `report`): calibrates to at least 0.2 s, then takes the **median of 10 batches**, which dampens the outliers inside a process.
   - The Haskell number is therefore both noisier and pulled up by the tail. When the Haskell process lands slow and the Python one lands fast, the row reads 0.83x.
3. **Ruled out:**
   - Capability migration: `-threaded`, `-N1` (bench ghc-options `-threaded -O2 -rtsopts`), and no other runnable Haskell thread during the wait.
   - The IO manager: bypassed on the threaded path by the C `poll`.
   - Safe vs unsafe FFI: about 12 safe calls per transaction (`sendQuery*`, `transactionStatus`, `socket`) at 0.1-0.2 µs each, far below the 30 µs gap.
   - GC: a few KB allocated per transaction.

**Fix, within the design rule (no library change):**

1. Time `tx.join-insert-commit`, `tx.owned-insert-10`, `fence` and `notify` with `BenchTwin.twin "tx.join-insert-commit" Nothing n`, with the Python side's `report(..., number=n)` pinned to the same n. Then both report a median of fixed batches after the same warm-up. This also finishes FA-V-6 for postgres.
2. In the gate, report "won k of n" for this row, and accept it on a majority of interleaved reps rather than on one process's mean.
3. If a Haskell-only slow mode remains after (1), diagnose before optimizing:
   - `getrusage` `ru_nvcsw`/`ru_nivcsw` per transaction;
   - `perf stat -e cpu-migrations,context-switches` on both clients;
   - one run with `taskset` pinning client and backend;
   - a non-threaded vs threaded A/B (the non-threaded build takes the `threadWaitRead` path).
4. Record a C-`poll` vs `threadWaitRead` A/B beside `waitReadableFor` (Internal.hs:360-365). Its comment claims "several microseconds per wake-up" with no number. If the gap does not show, delete the C poll (PD-8). If it does, move the wait to petrus-posix (PD-13).

## 5. Findings

### PD-1 MAJOR (outcome 6 design rule): the viewer's HTTP front is not necessary

- **Where.**
  - packages/petrus-viewer-server/src/Petrus/Viewer/HttpFront.hs (542 lines, FFI :80-83) and cbits/http_front.c;
  - the evidence is bench/RESULTS.md:487-520 (Run E) and :695-702.
- **What.**
  - In Run E (15 interleaved reps), the previous Warp server (700c623) beat the same Node servers by median: 1.03x, 1.12x, 1.08x and 1.16x.
  - The front adds 8-23% on top. The clean version keeps up, so (c) fails.
  - The other motive the file gives, the pending-file race where two Warp threads served one pending file, is fixed by taking the pending file atomically. That fix does not depend on the front.
- **Why it matters.** The README rule allows a hand-written HTTP parser and accept loop (C helpers, raw fds) only when the clean version cannot keep up. Here it could. This is several hundred lines of protocol code to own and fuzz.
- **Fix.**
  - Revert HTTP serving to Warp and keep the atomic pending-file take and the relay event loop.
  - If the front is kept, the RESULTS must show a row where Warp is below 1.0x. Its 1-client open-file rounds might qualify: Run E reports only medians for Warp, so measure Warp's per-round lows.

### PD-2 MAJOR (design rule): FastJson is a second, unmeasured JSON parser in a high-level package

- **Where.**
  - packages/hamsterdan-operator/src/Hamsterdan/Operator/FastJson.hs (204 lines, reads the Text UTF-8 array in place);
  - used at src/Hamsterdan/Operator/Python.hs:141 (`loadsStr`);
  - documented at DIVERGENCES.md:88-96;
  - introduced in 96eda46.
- **What.**
  - Nothing in hamsterdan-operator/bench/RESULTS.md mentions the fast path or a before/after. So (b) fails, and (c) is unknown.
  - The JSON layer is petrus-json; operator is near the top of the stack. So (a) fails.
  - The interface is total: `Nothing` falls back to the reference loader, and tests compare the two.
- **Why it matters.** It is a parallel parser whose agreement with `json.loads` rests on a 3000-document property test instead of on the shared, CPython-checked parser.
- **Fix.**
  - A/B `loadsStr` with and without `fastLoads` on the operator workloads.
  - If the reference loader keeps up, delete FastJson.
  - If not, make the reference path faster in petrus-json (`Petrus.Json.Python` or `Hamsterdan.Python.Object.loadsText` over `Parse`) and record the number there.

### PD-3 MAJOR (outcome 6): postgres tx rows are not measured like their twin and flap on Linux

- **Where.**
  - packages/petrus-postgres/bench/Main.hs:70-93 (`localOption (RelStDev 0.2)`, `bench "join-insert-commit"` at :84) against bench/python_bench.py `report`;
  - bench/RESULTS.md (56.9 vs 69.6 µs, 1.22x at 81bbdc5).
- **What.** See §4. One Linux process reads 0.83x, another 1.28x, and both clients are bimodal. The Haskell side reports a short, cold mean, the Python side a calibrated median of 10.
- **Why it matters.** The gate result for a headline store row depends on process placement, and the committed ratio is not reproducible on Linux CI. This is the remaining part of FA-V-6.
- **Fix.** Move the postgres tx rows to `BenchTwin.twin` with an equal fixed n on both sides and gate on "won k of n" (§4 steps 1-2). Run the diagnostics of §4 step 3 only if a Haskell-only gap remains.

### PD-4 MAJOR (outcome 6): 42 of 46 results files are stale against HEAD

- **Where.** `scripts/bench --stale` at d869f62; the trigger is baf5836/9e691e8 (petrus-json `Encode`, petrus-sqlite bind).
- **What.** The fingerprints correctly mark the figures as measured on older sources.
- **Why it matters.** Outcome 6 ("results committed and rerunnable", at parity) cannot be claimed for HEAD until the rerun is done. This is already known and scheduled separately.
- **Fix.** The rerun scope in §3.

### PD-5 MINOR (design rule (c)): the SQLite Text ByteArray# bind is not strictly necessary

- **Where.** packages/petrus-sqlite/src/Petrus/Sqlite/Connection.hs:442-459 and cbits/petrus_sqlite.c.
- **What.**
  - The measurement is recorded: 4-6% of the one-batch row (73.5 → 69.0 ms; 61.8 → 59.3 ms with `dumpsMany`).
  - Without it the row is about 1.83x on the Mac.
  - The Linux before/after (0.91-0.94x → 1.95-2.07x) is not split per change.
  - The interface is safe and total, and the layer is right.
- **Why it matters.** It fails rule (c) on the Mac. It may be needed on Linux, but that is unproven.
- **Fix.** Attribute the Linux gain per change. If the bind is not what lifted Linux above 1.0, drop it for direct-sqlite's `bindText`. Otherwise add the Linux number beside it.

### PD-6 MINOR (design rule (a),(b)): two unmeasured `casMutVar#` CAS helpers in high-level modules

- **Where.**
  - packages/petrus-agenticus-core/src/Petrus/Agenticus/Internal/Atomic.hs:18-30 (`modifyStrict :: IORef a -> (a -> (a, b)) -> IO b`), used by Hands/Grants and Gateway;
  - packages/petrus-impetus/src/Petrus/Impetus/HistoryStore.hs:51, 105-118 (`modifyStrict :: IORef a -> (a -> a) -> IO ()`), used only by `inMemoryHistoryStore` (:100). `mirroredHistoryStore` in the same file uses `atomicModifyIORef'`.
- **What.**
  - The only justification is qualitative ("most of the cost of a one-record append").
  - `store.in-memory-append` is 1.70x on the Mac and 1.66-1.68x on CI. The gap to Python is large either way.
- **Fix.** A/B against `atomicModifyIORef'`. Drop both if the row stays above 1.0. Otherwise move one helper to the lowest shared package and record the number.

### PD-7 MINOR (design rule (b), duplication): viewer C escaper and file reader have no isolated measurement

- **Where.**
  - packages/petrus-viewer-server/src/Petrus/Viewer/Json.hs:145-158 with cbits/json_escape.c;
  - src/Petrus/Viewer/FileIO.hs:32-36 with cbits/file_io.c.
- **What.**
  - RESULTS "Run A: before the C string escaper" changed other things in the same run, so the escaper has no number of its own.
  - The escaper writes the same bytes as petrus-json's escaper (JSON.stringify spelling for well-formed UTF-8).
  - file_io.c has no A/B against `BS.readFile`.
- **Fix.** A/B each against the clean version (petrus-json escaping; `BS.readFile` or petrus-posix). Delete whichever does not show.

### PD-8 MINOR (design rule (b)): petrus-postgres C poll and raw unsafe libpq imports carry no measurement

- **Where.**
  - packages/petrus-postgres/src/Petrus/Postgres/Internal.hs:358-390 (`waitReadableFor`, `ccall interruptible "petrus_pg_wait_readable"`) and :425-439 (15 `ccall unsafe` libpq imports);
  - cbits/petrus_postgres.c;
  - all introduced in 70622a0 with no numbers.
- **What.**
  - The comments claim microseconds per wake-up and per safe call, but nothing records them.
  - The same module still uses postgresql-libpq's safe calls on the hot path (`sendQuery*`, `transactionStatus`, `socket`).
  - The safe/total interface and the layer are fine.
- **Fix.** Record a poll-vs-`threadWaitRead` A/B and a safe-vs-unsafe accessor A/B on `join-insert-commit` (after PD-3, so the number is stable). Remove what does not pay.

### PD-9 MINOR (design rule (b)): petrus-json micro-optimizations without numbers

- **Where.** packages/petrus-json/src/Petrus/Json/Parse.hs:
  - :350-372 (SWAR `findSpecial`);
  - :274, 311-330 (STUArray `hashesCollide` pre-check before the Set);
  - :383 and the `copyAscii` helper.
  - Also Encode.hs:145-164, 364ff (direct mutable-buffer writer next to the Builder encoder).
- **What.**
  - The layer is right and the interfaces are total.
  - None of the SWAR scan, the hash pre-check or the writer-vs-Builder split has a recorded A/B.
  - `copyAscii` reimplements `Data.Text.Encoding.decodeLatin1`/`decodeASCII` for bytes already known to be ASCII.
  - The writer's memory safety rests on the convention "every write reserves first".
- **Fix.**
  - Record a before/after in petrus-json/bench/RESULTS.md for each, and drop what does not show.
  - Replace `copyAscii` with `decodeLatin1`.
  - If both encoders stay, record why.

### PD-10 MINOR (design rule (a),(b)): hamsterdan-contracts PyLiteral writes Text arrays by hand without a number

- **Where.** packages/hamsterdan-contracts/src/Hamsterdan/PyLiteral.hs:185-230 (`written`/`bound` plus `TA.unsafeWrite`).
- **What.**
  - It is a fourth hand-written output writer, after petrus-json's writer, petrus-json's Builder and fabric Canonical.
  - Its bounds safety depends on `bound` being exact.
  - bench/RESULTS.md:78-79 names the optimization but gives no before/after. The rows are 1.65x and 2.21x.
- **Fix.** A/B against a Builder (or petrus-json's writer with a repr hook). Keep the hand-written version only with a recorded number.

### PD-11 MINOR (lowest layer, duplication): stat and RSS bindings duplicated outside petrus-posix

- **Where.**
  - packages/hamsterdan-operator/src/Hamsterdan/Operator/Posix.hs:55-61 with cbits/stat.c and rmtree.c (fstat, lstat, fstatat, rmtree, confstr). It does not depend on petrus-posix, which has `statAt`, `fdStat`, `isDirectory` and `permissionBits`.
  - packages/petrus-posix/src/Petrus/Posix/Resource.hs:8-40 (own `petrus_maxrss`/`page_size`) is unused outside its own tests and bench, and duplicates petrus-telemetry `Telemetry.hs:552-590` and cbits/petrus_telemetry.c. petrus-motus Worker uses the telemetry copy.
- **Fix.**
  - Operator: depend on petrus-posix, adding `rmtree` there if needed.
  - RSS: telemetry should use `Petrus.Posix.Resource`, and the telemetry C copy should be deleted.

### PD-12 MINOR (lowest layer): fabric's canonical encoder lives in fabric, not petrus-json

- **Where.** packages/petrus-fabric/src/Petrus/Fabric/Canonical.hs.
- **What.** It is justified and measured (326 µs → 57.8 µs). But it is a specialised `json.dumps(sort_keys, compact, ensure_ascii=False)` writer, which other packages could use (history digests, hamsterdan digests).
- **Fix.** Move it into petrus-json as the `sortKeys`/compact fast path of `dumps`, with fabric's numbers moved alongside.

### PD-13 MINOR (lowest layer): fd-wait and spawn primitives live in the wrong package, twice

- **Where.**
  - petrus-postgres cbits/petrus_postgres.c `petrus_pg_wait_readable`;
  - petrus-execution cbits with `Providers/Gondolin.hs:554-562` (`capi interruptible "petrus_execution.h petrus_wait_readable"`);
  - motus-zeromq `Native.hsc` (the same pattern over `zmq_poll`, justified qualitatively);
  - the spawn primitive in petrus-execution `Internal/Process.hs:95-98`, which hamsterdan imports through `Petrus.Motus.Execution.Spawn`.
- **Fix.** Add one `waitReadable :: Fd -> Maybe Double -> IO Bool` (and `spawn`) to petrus-posix, with the measurement there, and use it from postgres, execution and hamsterdan.

### PD-14 MINOR (lowest layer, consistency): three errno → OSError-subclass tables

- **Where.**
  - petrus-engine-file/src/Petrus/EngineFile/PyText.hs:128-147 (a partial table and a local `PyException`);
  - hamsterdan-contracts/src/Hamsterdan/Python/Exception.hs:116-136 (`errnoClass`);
  - petrus-telemetry/src/Petrus/Telemetry/ErrorType.hs:138-159 (`oserrorSubclass`, plus `ENOTCAPABLE` through `unsafePerformIO` of a C constant at :73-79).
  - There are also two strerror FFI copies.
- **Why it matters.** engine-file's table is partial, so the same errno can map to different Python classes in different components.
- **Fix.** One total table, plus `strerror`, in the lowest Python-compat layer (petrus-posix or petrus-json's Python module), used by all three.

### PD-15 MINOR (outcome 6): the bench-gate does not run per push and leaves the viewer out

- **Where.** .github/workflows/ci.yml:361-403 (schedule or `inputs.full` only) and the scripts/bench-gate docstring (viewer and second harnesses excluded).
- **What.** A regression like FA-V-1 can land and stay up to a day before the nightly catches it. The viewer's Node comparison is never re-run automatically.
- **Fix.**
  - Run a 1-rep gate shard for the packages a PR touches, or make the nightly gate's failure open an issue.
  - Add a viewer shard (Node is available on the runners) for the endpoint and relay rows.

## 6. Verified to hold

- The README rule is stated and is followed by most recorded optimizations: the history-store attribution table, posix path marshalling, fabric Canonical, sqlite bind (recorded, if not necessary), the viewer relay loop and RTS flags, execution spawn, and `dumpsMany`.
- Correctness-driven low-level code is correctly scoped: Ryu, WTF-8, the petrus-json parser, the jiter-parity parser in engine-file, bzip2, uuid, ioctl and gai_strerror.
- FA-V-1 and FA-V-2 are resolved, as are FA-V-4 and FA-V-5. FA-V-6 is resolved for sqlite, history-store and motus (`BenchTwin`), but not postgres.
- Outcome 6 coverage holds: every real-use path named in the brief has a row and a twin.
- Results are committed with rerun blocks and fingerprints. `--stale` works, and its 42 stale files are explained by two identified commits.
- On Linux CI at d869f62, bench-gate shard 1 shows `tx.join-insert-commit` at 1.28x. The 0.83x of run 38249569895 comes from per-process placement amplified by the protocol mismatch (§4), not from a code regression.
