<!-- Dated record: final verification (2026-10-13). Every finding is resolved; see ../final.md. -->

# Final verification: accuracy (verifier A)

Repository: `petrus-haskell`, main = `c0cb6cb59655f03e8c270d7ba818d6d3d4add3c1`
(the local HEAD equals origin/main). The verification was read-only: no
cabal builds, no benchmarks, no git state changes. Scratch files are in
`final-verify/accuracy/`.

CI evidence:

- push run **38340388621** (c0cb6cb): success;
- full=true dispatch run **38342172477** (c0cb6cb, newer than the push run):
  success.

**Totals: 0 BLOCKER, 0 MAJOR, 4 MINOR, 4 NIT.**

---

## 1. Findings by severity

### BLOCKER

None.

### MAJOR

None.

### MINOR

**A. Package-level performance prose was not refreshed in the wave-3 rerun
(outcome 7: docs accurate; the stale-figures class recurs).** The root
`PARITY.md` (4fdc408) and the `bench/RESULTS.md` files were updated. Several
package PARITY and DIVERGENCES files still quote figures from older runs:

- `packages/petrus-fabric/PARITY.md:109-116`
  - Says: "twelve interleaved repetitions", 2.3× on `canonical.16KiB`, store
    operations 1.9–2.4×.
  - Current `bench/RESULTS.md:33`: 5 reps, `canonical.16KiB` 1.79×, store
    1.38–1.55×.
- `packages/petrus-processes/PARITY.md:126-137`
  - Says: 1.39–1.88×, child-of 1.50× (11/12), call 1.81×.
  - Current RESULTS: 1.51×, call 1.56×. Root PARITY: store 1.51–2.11×.
- Telemetry, three files: `packages/petrus-telemetry/DIVERGENCES.md:67-68`,
  `packages/petrus-telemetry/PARITY.md:22` and
  `packages/petrus-telemetry-instrumentation/PARITY.md:113-117`.
  - Say: 0.056 µs, routed 2.5 µs.
  - Current RESULTS (rerun 39455cb): 0.058 µs, routed 2.1 µs.
- `packages/petrus-viewer-server/PARITY.md` lines 88, 109, 146, 179, 204,
  229, 255, 270, 307 and 371 cite "run I". Run I is superseded by run J
  (865e62b; `bench/RESULTS.md:142`). This is the earlier viewer m1
  recurring.
- `packages/hamsterdan-host/PARITY.md:179-191` restates a 2026-10-11 table
  (validate 7.65×, inspect-instance 14.1×). Current RESULTS: 7.32× and
  30.81×.
- My heuristic also flagged these for possible drift; I did not check each
  one figure by figure:
  - `hamsterdan-agents/PARITY.md:94-105`
  - `petrus-engine-postgres/PARITY.md:78-80`
  - `petrus-execution/PARITY.md:14`
  - `petrus-observation-http/PARITY.md:90-91`
  - `petrus-json/PARITY.md:175`

None of the directions is wrong: Haskell is still faster wherever the prose
says it is. The magnitudes and rep counts are out of date.

Fix: either point package docs at `bench/RESULTS.md` without restating
figures, or re-derive the figures from the current RESULTS. Extend
`lint-example-counts`, or add a sibling lint, to flag a figure followed by
`×` or `µs` in PARITY and DIVERGENCES that does not appear in the package's
current RESULTS.

**B. Eight bench result files (19 components) are STALE at main
(outcome 7: PARITY current).** `scripts/bench --check` and
`scripts/check-parity` both exit 0, but they warn that 8 of 46 result files
are stale. The only source change since the reruns is 0d01544, which touches
`packages/petrus-execution/src/Petrus/Motus/Execution/Providers/Gondolin.hs`
(`exchange`: the connect no longer goes through `within`). That change sits
in the dependency closure of these files:

- `hamsterdan-agents`, `hamsterdan-host`, `hamsterdan-operator` and
  `hamsterdan-testing` RESULTS;
- `petrus-agenticus` RESULTS;
- `petrus-agenticus-runtime` RESULTS, results-hosts and results-pi.

The change is very unlikely to move any measured path, because the
Gondolin provider is not exercised by those benches. Still, "PARITY current"
holds with a warning, not cleanly.

Fix: rerun the 8 files, or restamp them with a recorded justification that
0d01544 is outside the measured paths. A rerun of stale bench packages
appeared to be in progress elsewhere when I finished; I verified only
c0cb6cb.

**C. The SQLite text bind has no INT_MAX bound (outcome 5 safety; residue of
the earlier CK-m1).**

- `packages/petrus-sqlite/src/Petrus/Sqlite/Connection.hs:475-476` converts the
  UTF-8 byte length with `fromIntegral size` to `CInt`.
- `packages/petrus-sqlite/cbits/petrus_sqlite.c:20` passes that `int length` to
  `sqlite3_bind_text` unchecked.

So a text of 2^31 bytes or more either wraps to a negative length (SQLite
then reads up to the first NUL, past the buffer) or is silently truncated.
CPython's `sqlite3` raises `OverflowError("string longer than INT_MAX
bytes")`. The test added for CK-m1 (`petrus-sqlite/test/Main.hs:210`)
compares the Text bind against the Utf8 bind and does not cover the bound.
The input is impractical in normal use, but the result is an out-of-bounds
read rather than an error.

Fix: refuse `size > fromIntegral (maxBound :: CInt)` before the FFI call,
with CPython's OverflowError text. A unit test can drive the bound check
directly without allocating 2 GiB.

**D. The obligation ledgers cover only the 6 core upstream docs
(outcome 2: spec ledgers).**

- `spec/impetus-conformance.md` enumerates 109 obligations over the 6 core
  docs ("Gaps: None").
- Two protocol docs do not have obligation-by-obligation ledgers:
  - `observation-protocol-v1.md` is covered by
    `petrus-observation-http/PARITY.md:29-38`;
  - `simulation-http-v1.md` is covered by
    `petrus-simulation/PARITY.md:98-110`.

  Both PARITY sections list only "what tests leave implicit".
- `spec/README.md` §1a names only `impetus-conformance`.

The coverage evidence itself is strong:

- the fixtures are byte-exact;
- WireSpec replays 501 requests with identical wire output;
- `check-corpora` keeps the corpora current.

This is a completeness gap in the ledgers, not missing behaviour.

Fix: add O- and S- obligation lists, in impetus-conformance or in a new
ledger linked from §1a.

### NIT

1. `packages/petrus-observation/PARITY.md:26` defines the status
   "**deferred**: it needs the observation HTTP adapter, which does not
   exist yet". The adapter exists (`petrus-observation-http`). If no row
   uses the status, drop it. If a row does, reword it.
2. `packages/petrus-engine-postgres/PARITY.md:8` says "`petrus.engine.absurd`,
   not ported yet". `packages/petrus-engine-absurd` exists.
3. `packages/petrus-agenticus-runtime/PARITY.md:157` reads "**TODO: no paid
   live run has been recorded.**" The paid cells are a declared opt-in, so
   this is acceptable. It should be worded as a status ("not recorded; opt-in
   requires …") rather than a TODO.
4. `exitInt` is still defined three times (CA-5 residue):
   - `hamsterdan-operator` `Operator.hs:336`;
   - `petrus-dst` campaigns `Process.hs:52`;
   - `petrus-agenticus-runtime` `Internal/Process.hs:206`.

   It is small enough to tolerate, but it is the duplication CA-5 asked to
   remove.

I checked one other candidate and rejected it:
`hamsterdan-host/bench/RESULTS.md:283-284` ("V5 timers … stays in progress
until it is settled") sits inside a section marked
`<!-- bench: superseded -->` (lines 245-247). The current table
(`RESULTS.md:69-70`) has the fresh open at 1.53× and the rebuild at 2.05×,
and the root `PARITY.md:139` has V5 timers at parity. It is consistent
historical text.

---

## 2. Earlier findings: status

| id | status | evidence |
| --- | --- | --- |
| CK-1 | resolved | Builder encoder moved to `petrus-json/test/Petrus/Json/ReferenceEncode.hs`; `petrus-json/bench/RESULTS.md:125-140` records Builder at 0.51–0.94× against Python |
| CK-2 | resolved | one `Petrus.Json.Python.Object.PyObject`; CEL's closed ExcClass justified in `Exception.hs:15-20`; the engine-file PyException is gone |
| CK-3 | resolved | engine-file `app/Main.hs` is 127 lines on `Petrus.Argparse`; `CliSpec.hs:81-82` covers `-1x` and `--indent -1a` |
| CK-m1 | partly open | test added (`petrus-sqlite/test/Main.hs:210`, Text against Utf8); INT_MAX bound still missing → finding C |
| CK-m2 | resolved | `HistoryStore/Sqlite.hs:175` `encodeRow = fmap runIdentity . encodeRows . Identity`; `dumpsMany` is Traversable (`Encode.hs:188`); `Utf8Text` Param |
| CK-m3 | resolved | `Wtf8.hs:97` scans the array |
| CK-m4 | resolved | no `/dev/urandom` in impetus; uuid7 is in `Petrus.Json.Python.Uuid` |
| CK-m5 | resolved | cabal description updated; umbrella list complete; CEL uses `maxIntStrDigits` (`Cel/Python.hs:29,72`) |
| CK-m6 | resolved | `Argparse.hs:315` `getArguments = map fsDecode <$> Posix.getArgs` |
| CK-m7 | resolved | petrus-cel DIVERGENCES "By design §8" |
| CK-m8 | resolved | counts removed and `lint-example-counts` guards them; the 1996 figure is now only the impetus hand_built corpus (correct); the CEL corpus is 2673 |
| Motus MAJOR-1 | resolved | `Native.hsc:339-344` `pollBound = 50000` with run ids; README:62-69 and DIVERGENCES:105 updated; `TransportSpec.hs:420` "a curve server stops while its clients are still connected" |
| Motus MINOR-1 | resolved | docs updated; the zeromq threadWaitRead branch is gone |
| Motus MINOR-2 | resolved | spec wording fixed |
| Motus MINOR-3 | resolved | `spec/README.md` updated |
| Motus MINOR-4 | decided | lanes kept with rationale in petrus-motus DIVERGENCES item 20 (lines 194-208); `!!` removed (58aa4b7) |
| Motus MINOR-5 | decided | a8a2010 and `petrus-processes/PARITY.md:102-113` explain why the line protocol is equivalent for P-079 |
| CA-1 | resolved | values admitted, only keys refused (`StrictJson.hs:23-77`; DIVERGENCES:157) |
| CA-2 | resolved | 9c1b593; `AgentNetRunner.hs:688` uses `mkEpisodeBudget` |
| CA-3 | resolved | `Codec.hs:48-49` `dumps canonicalOptions`; Internal.Canonical gone |
| CA-4 | resolved | `Telemetry.hs:131` imports `Petrus.Posix.Resource`; no telemetry cbits |
| CA-5 | mostly resolved | materialization uses `Petrus.Posix.File` writeAll; spawnPiped moved (1fa27d0); the HostSupport buffer is gone; `exitInt` is still defined 3 times → NIT 4 |
| CA-6 | resolved for the listed cells | the cells named in the finding were fixed; other package prose drifted again → finding A |
| CA-7 | resolved | PinnedSdkSpec uses `claudeHandsTools` from production |
| CA-8 | resolved | "Why it stays" in `pi.md:112,188,196-199,243` |
| CA-9 | resolved | Transcript is in the test suite (`petrus-dst.cabal:213-215`) |
| Hamsterdan M1 | resolved | operator cbits gone; depends on petrus-posix; `Posix.hs` uses `Petrus.Posix` |
| Hamsterdan M2 | resolved | FastJson deleted; export sequential vs parallel recorded at RESULTS:84-101; PyLiteral writer moved to petrus-json JsonRepr, measured at contracts RESULTS:94-112 |
| Hamsterdan m1 | resolved | github DIVERGENCES:205 (`trust_env` False) |
| Hamsterdan m2 | resolved | only a historical mention remains (agents bench RESULTS:122) |
| Hamsterdan m3 | resolved | counts removed; testing PARITY:117 |
| Hamsterdan m4 | resolved | `ExceptionClass.hs:55,100-102` `ioExceptionClass` |
| Hamsterdan m5 | resolved | `raisePython` kept with its reason (`Host/Python.hs:80-89`); the engine-file PyException is gone |
| Hamsterdan m6 | resolved | `Url.quote` / `quoteBytes` and `pythonInt` from petrus-json |
| Hamsterdan m7 | resolved | no FFI in hamsterdan src |
| Hamsterdan m8 | resolved (alternative) | documented as a test seam in `Service.hs:15-16,430-436` instead of DIVERGENCES |
| Hamsterdan m9 | resolved | host DIVERGENCES:49-52 |
| Hamsterdan m10 | resolved | dead exports removed |
| Hamsterdan m11 | resolved | `docs/hamsterdan.md:948,1315` marked "Historical" |
| Hamsterdan m12 | resolved | `Containerfile:30-34` pins ghcup 0.2.6.2 plus SHA; operator DIVERGENCES:154-156 lists the apt libs |
| Viewer MAJOR-1 | resolved | collab only with `--host`; DIVERGENCES:15 is accurate (upstream `VITE_COLLAB_ENABLED` check verified) |
| Viewer MAJOR-2 | resolved | RESULTS "Low-level code, measured" :1016-1101; the Reactor header cites the measurement |
| Viewer m1 | recurred | package PARITY cites run I, superseded by run J (865e62b) → finding A |
| Viewer m2 | user decision | no CI benchmarking; viewer is in the gate per 512b164 |
| Viewer m3 | resolved / decided | wording "every push"; tip runs; the absence of branch protection is stated at `docs/reproducing.md:637-644` |
| Viewer m4 | resolved | `PARITY.md:71-74` tables |
| Viewer m5 | resolved | as fixed |
| Viewer m6 | decided | deliberate divergences (c8d7553) |
| Viewer m7 | resolved | all 43 packages list maintainer daniel@seasoned.cc; the oracle is a test-binary mode; `data ToolResult = ToolOk …` |
| Testing MAJOR-1 | resolved | agenticus-core PARITY:28-38; `runtime.md:5976-5979`; ReadinessCampaignSpec header "exactly" |
| Testing MAJOR-2 | resolved | `PiApplicationSpec.hs:1076-1106` gated real bodies; `pi.md:300-301` |
| Testing MAJOR-3 | resolved | CI log shows the 12 and 2 opt-ins seen; `check-pending --self-test` passes; a missing summary or empty log dir exits 1 |
| Testing MINOR-1 | resolved | catalog.md 35/44; agenticus 34 |
| Testing MINOR-2 | resolved | `upstream-test-counts --check`: 301 counts in 50 ledgers |
| Testing MINOR-3 | resolved | impetus HistoryStoreSpec is a 50-line wrapper over the shared HistoryStoreContract |
| Testing MINOR-4 | resolved | `GitHubSpec:395` label is the upstream name with spaces |
| PD-1 | resolved | HttpFront gone; Warp |
| PD-2 | resolved | as fixed |
| PD-3 | resolved | postgres bench BenchTwin `twin` (`Main.hs:14,95-99`) |
| PD-4 | resolved, then stale again | wave-3 rerun done; 8 files stale after 0d01544 → finding B |
| PD-5 | kept with figures | `Connection.hs:466-473` |
| PD-6 | resolved / kept | agenticus CAS removed (e26c238); the impetus `casMutVar#` is kept with figures per PLAN (aMIR' 0.81×) |
| PD-7 | kept with A/B | RESULTS:1069-1101 |
| PD-8 | measured | d5eb493; petrus-posix `Poll.hs` header |
| PD-9 | resolved | SWAR/hash/copyAscii handled; `Parse.hs:352` findSpecial is `BS.findIndex` |
| PD-10 | resolved | as fixed |
| PD-11 | resolved | as fixed |
| PD-12 | resolved | fabric Canonical moved to petrus-json (d354c96); fabric tests 242 → 238, petrus-json 135 |
| PD-13 | resolved | `Petrus.Posix.Poll.waitReadable`, used by postgres and gondolin |
| PD-14 | resolved | `Petrus.Json.Python.OsError` |
| PD-15 | user decision | — |
| PLAN: poll error re-verify | verified | `Poll.hs` raises OSError on a non-EINTR error, as psycopg `wait_c` does; bounded at 50 ms; petrus-postgres DIVERGENCES:23 |

---

## 3. What was verified, with evidence

### Scripts at main (all exit 0)

| script | output |
| --- | --- |
| `scripts/check-pins` | 4 ok |
| `scripts/upstream-test-counts --check` | "301 upstream test counts in 50 ledgers match" |
| `scripts/check-parity` | "76 of 76 components at parity" (STALE warning for 19 components → finding B) |
| `scripts/lint-skips` | 485 sources |
| `scripts/lint-example-counts` | passes |
| `scripts/lint-hamsterdan-architecture` | 94 modules |
| `scripts/ci-tests check-steps` | "all 15 check-all steps (not: Benchmarks)" |
| `scripts/check-pending --self-test` | "5 fixture logs read as expected" |
| `scripts/bench --check` | passes; warns 8 of 46 result files STALE |

For `check-pending`, I also confirmed the failure cases: an empty or missing
log dir exits 1, and a log without a summary exits 1.

### Outcome 1: pins

The submodules are pinned to petrus 3f85fc2, hamsterdan 5d38246,
petrus-engine fc1dd50 and petrus-viewer ccb7808.

- Each equals the upstream HEAD.
- All four upstream repos are public.
- The `UPSTREAM.md` pin table matches the gitlinks.
- `UPSTREAM.md` has a 7-step "Moving a pin" procedure.

### Outcome 2: spec, ledgers and tests

**Spec structure.** `spec/README.md` has the §1a index, the §1b citation
convention (`[DR …]`) and the §1c markers (OPEN, CONTRACT, ACCIDENT).

**Ledgers:**

- `spec/impetus-conformance.md`: 109 obligations over the 6 core docs,
  "Gaps: None";
- `spec/fabric-conformance.md`: 108 checks;
- `spec/processes-conformance.md`: 80 checks;
- the observation and simulation protocols are covered through PARITY
  sections, fixtures and WireSpec (501 requests) → finding D.

**Golden traces.** GoldenTracesSpec runs in CI: the log shows 20 examples
matched "golden traces" and 20 matched "spec/ fixtures".

**Upstream test counts.** `upstream-test-counts --check` and `check-parity`
pass (see the scripts table).

**Spot-checks of upstream test files** (7, more than the 5 asked for):

| upstream file | result |
| --- | --- |
| `fabric/test_fabric.py` | 12/12 in ReferenceSpec.hs |
| `engine/test_observation.py` | 19/19 in ObservationSpec and EngineSpec |
| hamsterdan readiness `net_v5/test_review_loop.py` | 33/33 in ReviewSpec (hyphenated names); hamsterdan-readiness PARITY:45 counts 36 |
| `motus/test_private_file_transfer.py` | 6/6 in LocalSpec and E2bSpec |
| petrus-engine `tests/test_flatnet_resolution.py` | 10 ported as `upstream/resolution/*` corpus cases (corpus of 923); 1 out of scope with a ledgered reason (engine-file PARITY §5:141) |
| `impetus/binding/test_cel.py` | 19/19 in `petrus-cel/test/Impetus.hs` |
| hamsterdan `github/test_github.py` | 55/56 by name; 1 ledgered |

**Spot-checks of Hypothesis ports** (3; all faithful):

1. `InstanceReplayPropertiesSpec.hs`: maxSuccess 300, and
   `replay = Just (mkQCGen 300, 0)` for upstream `derandomize=True`. The
   strategy shapes are the same.
2. `EffectSpec.hs:112-210`: `hypothesisSettings 60`;
   `genObject 8 (genJson 20)` with dict-key dedupe; full-range
   non-surrogate `genText`; a per-run seed. That matches upstream, which is
   not derandomized. I confirmed this in the upstream venv: pytest-randomly's
   `_reseed` does not touch Hypothesis, and Hypothesis `core.py:726` uses
   `Random()`.
3. `ReadinessCampaignSpec.hs:86-130`: the 3 `@example` cases, plus
   `withTests 6` with a fixed seed (upstream `derandomize=True`); `assume`
   is mapped to `H.discard`.

### Outcome 3: interop and CEL

**Interop count.** The `checks` job prints "interop: 95 patterns over 42
packages select 9012 examples". Push and full runs give the same count.

**Corpora.** `check-corpora` reports "51 generators, 71 files current".
These include:

- `petrus-cel/tz tables`, `gen-cel-corpus` and `gen-cel-instance`;
- the impetus corpora;
- `petrus-json/python tables`;
- `petrus-viewer-server/record-node-corpora`.

**Both directions.** The interop examples run with Python writing and
Haskell reading, and the reverse. Examples include:

- `timers.sqlite3`, byte-compatible in both directions;
- the fabric, processes and CV5 tests (see outcome 4);
- the viewer's mcp-haskell-relay and mcp-node-haskell-relay.

**CEL against cel-python.** cel-python is 0.5.0 (upstream `uv.lock`). The
evidence:

- a 2673-case corpus;
- a live round trip;
- time-zone tables.

The CEL suite reports 172 examples in CI.

### Outcome 4: Fabric and processes, language-neutral

**Spec wording.** `spec/fabric.md` and `spec/processes.md` never mention
"Haskell port". Python is cited only as provenance.

**CI logs (test jobs 2 and 4)** show the cross-language tests running:

- F-038, F-046, F-102/F-103, F-104, F-105, F-106 and F-108 ran in both
  orders: [Python, then Haskell] and [Haskell, then Python].
- CV5 ran four ways:
  - Haskell orchestrator with a Python child;
  - Haskell orchestrator with a Python parent;
  - Python orchestrator with a Haskell child;
  - Python orchestrator with a Haskell parent.
- P-038, P-079 and P-080 ran in both orders.
- The lifecycle demo ran in 6 configurations.
- "a refused fabric.send or process.spawn is recorded as the reference
  Worker records it" ran in both directions.
- The fabric conformance groups ran under both "Haskell port" and "Python
  reference".

In total the log has 218 F- lines and 191 P- lines.

### Outcome 7: docs, CI and parity

**Docs.**

- `README.md:44` and the "Clone" section of `docs/reproducing.md` give
  `git clone --recursive https://github.com/seasonedcc/petrus-haskell.git`.
- `docs/reproducing.md` covers prerequisites, PostgreSQL, `--with-deps`,
  pnpm, Docker and petrus-sdks.

**`ci.yml`.**

- Triggers: push to main, pull_request, and workflow_dispatch (full, sha,
  bench).
- The concurrency group is per run on main.
- The `ci` verdict job allows only bench-smoke and bench-gate to be skipped.
- There is no branch protection (API 404, no rulesets). The repo states this
  at `reproducing.md:637-644`, an accepted decision.

**Push run 38340388621 (c0cb6cb): success.**

- Every job succeeded: container, lint, build, checks, viewer, test 1–10,
  and the `ci` verdict. bench-smoke and bench-gate were skipped, as allowed.
- 53 suite units passed, covering all 43 declared test suites.
- Totals: 13,738 examples, 14 pending. All 14 are declared opt-ins: 12 in
  agenticus-runtime and 2 in execution. `check-pending` confirmed both sets.
- Examples per suite:

  | suite | examples |
  | --- | ---: |
  | impetus | 5783 |
  | engine-file | 1013 |
  | execution | 881 |
  | agenticus-core | 667 |
  | agenticus-runtime | 445 |
  | contracts | 403 |
  | host | 392 |
  | readiness | 339 |
  | dst | 285 |
  | operator | 283 |
  | fabric | 238 |
  | engine | 226 |
  | processes | 225 |
  | github | 205 |
  | agenticus | 172 |
  | cel | 172 |
  | json | 135 |
  | observation | 75 |

- Viewer job:

  | check | passed |
  | --- | ---: |
  | relay | 5/5 |
  | endpoints | 14/14 |
  | url-cache | 9/9 |
  | cli | 5/5 |
  | mcp | 7/7 |
  | mcp-haskell-relay | 7/7 |
  | mcp-node-haskell-relay | 7/7 |
  | collab | 6/6 |
  | protocol | 19/19 |
  | differential | 4/4 |
  | history | 8/8 |
  | wire | 20/20 |
  | playwright | 4/4 |
  | live | 13/13 |

**Full=true run 38342172477 (c0cb6cb, dispatch, newer than the push run):
success.**

- It was a clean build: `FULL_RUN` true, DIST_KEY contains
  `full-38342172477`, cabal-dist `fresh: true`, and every local library was
  compiled.
- It produced the same results as the push run: 53 units, 13,738 examples,
  14 pending opt-ins, 9012 interop examples, and 51 generators with 71 files
  current.
- bench-smoke: "39 benchmarks built and ran to the end". bench-gate was
  skipped, as allowed.

**CI history.**

- 9db401e and c5e7c2a failed and were fixed by d89205a, which went green.
- f0eedad also failed.
- Every later main run is green.

**PARITY.** `check-parity` passes: 76 of 76 components are at parity. The
STALE warning and the package prose drift are findings B and A.

### Scope and licensing

**Scope.** `SCOPE.md` lists the in-scope and out-of-scope projects with
reasons (Arx, hamsterdan2, ngrok and others).

**Root files.**

- `LICENSE` is Apache-2.0.
- `NOTICE`:
  - credits petrus and hamsterdan (Apache-2.0);
  - reproduces the MIT text for petrus-engine and petrus-viewer;
  - names the Absurd schema;
  - covers upstream's THIRD_PARTY_NOTICES (Absurd, Ariad).

**Packages.** All 43 packages have:

- a `LICENSE` identical to the root one;
- a `NOTICE` file;
- `license: Apache-2.0` and `license-file` in the cabal file;
- `NOTICE` in `extra-doc-files`.

The MIT text appears in the NOTICE of petrus-cel, petrus-engine-file and
petrus-viewer-server.
