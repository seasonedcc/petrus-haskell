# Final audit

This is the closing audit of the Haskell port against the project goal: the seven outcomes, for
everything in scope (SCOPE.md). It records how the audit was done, what each outcome rests on, every
finding the last two audit rounds raised and the commit that resolved it, and the decisions taken along
the way. It was completed on 2026-10-13 at `main` = `f892783` (this document was committed on top of it).

The audit reports it summarizes are kept beside it as dated records:

- `docs/audit/*.md` (2026-10-11): the slice audits of record (kernel and spec, engines/motus/fabric,
  simulation/DST/telemetry/agenticus, hamsterdan, viewer/engine/scope/repo) and their elegance reviews.
- `docs/audit/confirmation/` (2026-10-12, at `d869f62`): a second, independent audit of the full
  codebases in seven areas.
- `docs/audit/final-verification/` (2026-10-13): four verifications of the result: accuracy, design,
  a recheck of the fixes they led to, and the performance evidence.

Figures quoted in those reports are what was measured or counted at the commit each names; the current
benchmark figures are in each package's `bench/RESULTS.md` and in
[bench-results/summary.md](../../bench-results/summary.md).

## Method

Each round was run by independent reviewers reading the whole of their area on both sides (the pinned
upstream checkout under `upstream/` and the port), read-only, with the repository's own checks and CI
logs as evidence. Each finding carries a severity: BLOCKER (an outcome does not hold), MAJOR (a clear
quality or correctness gap to fix before declaring done), MINOR (worth fixing, not blocking). Every
finding of the confirmation and final rounds was fixed, or decided with its rationale recorded; each
fix was checked by CI on `main` and rechecked by a later verifier.

| Round | Commit | BLOCKER | MAJOR | MINOR |
| --- | --- | ---: | ---: | ---: |
| Confirmation audit, 7 areas | `d869f62` | 0 | 18 | ~55 |
| Final verification A: accuracy (outcomes 1–4, 7, scope, licensing) | `c0cb6cb` | 0 | 0 | 4 |
| Final verification B: design (outcome 5, the design rule) | `c0cb6cb` | 0 | 1 | 8 |
| Recheck of the fixes to A and B | `df073f3` | 0 | 0 | 2 |
| Final verification C: performance (outcome 6), review of `f87d05b` | `f12bfd6` | 0 | 0 | 7 |
| Closing check of the fixes to C | `f892783` | 0 | 0 | 0 |

The last row is the coordinator's review of the fixes to C, with CI on `main`; no further finding was raised. The reports name reviewers' scratch files (scripts, logs, Core dumps); those were working files and are not kept.

## Outcomes

### 1. Pinned parity

- The four upstream projects are pinned as submodules at the commits in [UPSTREAM.md](../../UPSTREAM.md)
  (petrus `3f85fc2`, hamsterdan `5d38246`, petrus-engine `fc1dd50`, petrus-viewer `ccb7808`);
  `scripts/check-pins` checks the gitlinks against the table. All four are public.
- UPSTREAM.md gives the procedure for moving a pin: `scripts/upstream-diff` lists what moved,
  `scripts/check-corpora` reruns every committed-corpus generator against the new pin (51 generators,
  71 files current), and PARITY.md marks the affected components until their gaps are closed.

### 2. Conformance

- `spec/` holds the upstream specifications with conformance ledgers: impetus (109 obligations over the
  six core documents), fabric (108 checks), processes (80 checks), observation and simulation HTTP
  (added in this round: `spec/observation-conformance.md`, `spec/simulation-http-conformance.md`).
  Every ledger's Gaps section reads "None". The golden trace corpus runs in CI (GoldenTracesSpec).
- Every upstream test is mapped in a package PARITY ledger; `scripts/upstream-test-counts --check`
  holds the 301 upstream test counts in 50 ledgers to the recorded pytest collection, and
  `scripts/lint-skips` refuses a silent skip on a missing reference (485 test sources).
- Hypothesis tests are ported as property tests with the same strategies, settings and `@example`s;
  verifier A spot-checked three ports (derandomized ones replay a fixed seed, the others draw a fresh one,
  as upstream does).
- The three ledger gaps the final audit found (O-006, O-027, S-013) now have examples (`59b0a85`).

### 3. Interoperability

- `scripts/interop` runs the cross-language groups: Python writing and Haskell reading and the reverse,
  over shared files, databases and sockets; byte-for-byte comparisons with the reference's servers and
  CLIs; the committed differential corpora; and conformance suites run against both implementations.
  In CI: 95 patterns over 42 packages select 9,013 examples (`scripts/interop --check` fails on a pattern
  that selects nothing).
- CEL guards are checked against cel-python 0.5.0 (upstream's lock): a 2,673-case recorded corpus, a live
  round trip, and generated time-zone tables.
- The viewer's own upstream suites (relay, endpoints, url-cache, CLI, MCP, collaboration, protocol,
  differential, history, wire, Playwright, live) run against the Haskell backend in CI's viewer job.

### 4. Fabric and processes

- `spec/fabric.md` and `spec/processes.md` are language-neutral contracts (Python is cited only as
  provenance), with conformance ledgers.
- The cross-language checks run in both orders: Python messaging, calling and spawning Haskell and the
  reverse (fabric F-038, F-046, F-102–F-108; processes P-038, P-079, P-080; the CV5 orchestration four
  ways; the lifecycle demo in six configurations).

### 5. Better the Haskell way

- Each package's DIVERGENCES.md documents every intentional API divergence with its rationale; wire
  formats and specified behavior are held equal by the interop, conformance and differential suites.
- The design reviews (2026-10-11 elegance reports, the confirmation audit, and verification B with its
  recheck) judged the port module by module. Their findings drove, among others: one Python value model
  (`PyObject`) and one exception model (`PythonException`) for the whole port; one `json.dumps` writer;
  one `json.loads` "admit fast, explain with CPython's scanner" path (`parseOrExplain`); one numeric core
  for Python's `==` and ordering and one truthiness (`Petrus.Json.Value`); validated records with
  abstract constructors and smart constructors; POSIX primitives (`flock`, `openat`, `linkat`,
  `normpath`, `rmtree`, `getaddrinfo` errors, rusage, whole-buffer writes) in one package
  (`petrus-posix`) instead of ad hoc FFI; and total SQLite binds that raise CPython's `OverflowError`.
- The design rule (README): speed never comes at the cost of design. A low-level optimization is made
  only where a benchmark shows the clean version cannot keep up with the reference; it then lives behind
  a safe, total interface in the lowest layer that can hold it, with its measurement beside it.
  Verification B inventoried every low-level optimization against that rule; the ones that could not show
  a measurement were replaced by clean code (e.g. the execution archive's writes and the viewer
  log's write in `59b0a85`), and the one that then measured short (the viewer's logging under 16
  concurrent MCP calls) became `Petrus.Posix.File.writeDirect`, behind `DirectFd`, with its A/B
  measurement beside it (`f87d05b`).

### 6. Performance

- 46 committed results files over 39 benchmark packages compare each component with the pinned Python
  (the viewer backend with upstream's Node server) on equivalent workloads, interleaved on one machine.
  [bench-results/summary.md](../../bench-results/summary.md) lists every file, its worst and best row and
  the commit its figures measured: no row is below 1.0×.
- Rows whose two sides do the same kernel or device work come out level and are reported as measured:
  petrus-sqlite's fsync-bound transaction rows, petrus-dst's isolated-database row and
  hamsterdan-operator's qualification setup.
- Every results file is current: `scripts/bench --check` reports none stale. Each file's marker names the
  sources its figures measured; a file whose package changed without touching its measured paths is
  carried forward with a stated reason (`scripts/bench --carry`), and verification C checked those
  reasons against the code (including identical optimized Core where a reason claims it).
- Coverage of real-use paths (verification C §4): firing on small and large nets, history append and
  replay, store reads and writes (SQLite, PostgreSQL, JSONL, memory), simulation, observation paging, and
  end-to-end CLI and application runs (viewer, engine-file, Hamsterdan host, operator and export).
- Every results file documents its machine, method and rerun command; `scripts/bench PKG` runs it, and
  [docs/reproducing.md](../reproducing.md) covers the whole procedure.

### 7. Verifiability

- From a clean checkout: `git clone --recursive https://github.com/seasonedcc/petrus-haskell.git`, then
  [docs/reproducing.md](../reproducing.md) (prerequisites, PostgreSQL, the Python references, pnpm,
  Docker) and `scripts/check-all`.
- Every push and pull request to `main` runs CI (`.github/workflows/ci.yml`): the build, every test suite
  (43 suites in 53 units, 13,752 examples; the 14 pending are declared opt-ins for live providers),
  the interop and corpus checks, the lints, the viewer job and the container smoke test. A `full=true`
  dispatch rebuilds from scratch and runs every benchmark once; `bench=true` runs the benchmark gate.
  At `f892783`: push run 38384374519 and the clean-rebuild `full=true` run 38384381797, both green.
- [PARITY.md](../../PARITY.md) shows every component's status: 76 of 76 at parity
  (`scripts/check-parity`, which also reports any component whose cited benchmark figures are stale).

### Scope and licensing

- SCOPE.md records what is in and out of scope and why (websites, unrelated repositories, Arx, which
  is private, `hamsterdan2`, which production does not run).
- LICENSE is Apache-2.0; NOTICE credits the upstream projects, reproduces the MIT texts of petrus-engine
  and petrus-viewer, and carries upstream's third-party notices; every package has the same LICENSE and a
  NOTICE.

## Findings of the final rounds and their resolution

| Finding | Resolution |
| --- | --- |
| A-A: package prose quoted stale benchmark figures | figures moved out of PARITY/DIVERGENCES into RESULTS files; `scripts/lint-bench-figures` (`12a24a8`) |
| A-B: results files stale | rerun or carried with reasons (`330cb44`, `36443b0`, `df073f3`, `50635f0`, `f12bfd6`) |
| A-C: SQLite text bind past `INT_MAX` | `bindLength`/`checkBindLength`, CPython's `OverflowError` (`59b0a85`, `c33829e`) |
| A-D: three ledger gaps (O-006, O-027, S-013) | examples added, ledgers' Gaps read "None" (`59b0a85`) |
| B-M1: a second Python value model in Hamsterdan | `type PV = PyObject`; qualification errors are `PythonException`s (`59b0a85`) |
| B-m1: four copies of the `json.loads` fallback | `parseOrExplain` (`59b0a85`) |
| B-m2: SQLite bind not total | as A-C |
| B-m3, B-m4: unmeasured low-level writes (archive, viewer log) | clean writes on petrus-posix, A/B recorded (`59b0a85`); the viewer log's then measured shortfall fixed by `writeDirect` (`f87d05b`) |
| B-m5, B-m6: duplicated `pyDict`, `pyEq`, `normpath`, `pathParent`, `exitInt` | one home each in petrus-json and petrus-posix (`59b0a85`) |
| B-m7, B-m8 and NITs | fixed (`59b0a85`, `12a24a8`) |
| R-1: petrus-dst carry reason false | re-measured (`50635f0`) |
| R-2: two numeric `==` cores, six truthiness copies, a third `==` in DST | one core and `pythonTruthy` in `Petrus.Json.Value` (`f87d05b`) |
| R-N1..N3: clashing constructor names, bind-check boilerplate, carry wording | `Lit*` constructors, `checkBindLength`, re-carried (`f87d05b`, `f12bfd6`) |
| C-1, C-2: DST numeric checkers and three ordering copies outside the shared core | `pyNumberCompare` beside `pyNumberEq` in `Petrus.Json.Value`, used by readiness, the engine-file loader and the DST checkers, which now work over `PyNumber`; tested against CPython (`b4d1ccb`) |
| C-3: `writeDirect` haddock understated its reach | the haddock states that a running unsafe call also holds up garbage-collection synchronisation (`b4d1ccb`) |
| C-4: results fingerprint ignored `test/` sources compiled into benchmarks | the fingerprint counts every source directory a benchmark stanza compiles (`60f3c54`); the 11 files affected only by the new definition carried with reasons (`32a430b`) |
| C-5..C-7: carry wording, a DST table row, a PARITY sentence | carries re-worded, the DST row re-measured, the PARITY sentence corrected (`b4d1ccb`, `f892783`) |

## Decisions

Taken with the project owner during the audit, and recorded where they apply:

- CI runs every test suite on every push and pull request (no reuse of earlier results); benchmarks run
  on request (`full=true`, `bench=true`), not on a schedule.
- Benchmarks use three interleaved repetitions, five for rows under 1.15×; a row is investigated only
  when it falls below 1.0×. Rows whose two sides do the same kernel or device work and come out level are
  accepted as measured.
- The repository is public; `main` takes direct pushes, each checked by CI; pull requests from forks need
  approval to run.

## Limits

- Interop with Arx is untested: the repository is private (SCOPE.md); the protocols it consumes are tested
  against the pinned Python and the shared spec fixtures.
- Live-provider tests (agent hosts, sandboxes) are opt-in and need credentials; they are declared as such
  and checked by `scripts/check-pending`.
- Benchmarks were measured on one machine (Apple M4) and are meant to be rerun, not read as absolutes.
