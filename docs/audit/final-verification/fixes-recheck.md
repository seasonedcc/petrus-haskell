<!-- Dated record: final verification (2026-10-13). Every finding is resolved; see ../final.md. -->

# Re-check of the final-audit fixes (59b0a85, c33829e, df073f3)

**Scope.** I read `git diff 36443b0..df073f3`, which covers 91 files, against `design.md` and `accuracy.md`. The repository was not modified, nothing was built, and no benchmarks were run.

**CPython checks.** I ran a short script under the pinned 3.14.6 interpreter, `upstream/hamsterdan/.venv/bin/python -I`.

**CI.** The push runs for c33829e (38352626953) and df073f3 (38352719607) are both green on every job. bench-smoke and bench-gate were skipped, as allowed. 59b0a85 was pushed together with c33829e. Every new example appears as passed (`[✔]`) in the df073f3 log:

- `refuses a str or bytes parameter past INT_MAX bytes…`, petrus-sqlite (shard 7);
- `takes the parent like PurePosixPath.parent and normalizes like os.path.normpath`, petrus-posix (shard 8);
- `hard-links like os.link…`, petrus-posix (shard 8);
- `json.loads(str) applies the limit whether or not the text holds a lone surrogate`, petrus-json: 135 → 136 examples (shard 3);
- `a poisoned Engine is a 503 on every read door…` (shard 4);
- `a document read blocks between a writer's append and projection…` (shard 6);
- `bounds a response write to a client that never reads…` (shard 7).

**Totals: 0 BLOCKER, 0 MAJOR, 2 MINOR, 3 NIT.**

## 1. Findings

### MINOR

**R-1. One of the 25 carry reasons is false: petrus-dst (outcomes 6 and 7: the figures measure the current code).**

- **The reason.** `packages/petrus-dst/bench/RESULTS.md:4` says "… no SQLite on the bench path".
- **Why it is false.** Two of the file's rows exercise code the fixes changed:
  - the rows are `engine worlds › replay the Engine-world fixtures` and `author the Engine worlds` (`bench/Bench.hs:132-133`);
  - they run the Retry and GeneratedRuntime profiles over the real SQLite LocalDispatch (`test/Spec/EngineWorlds.hs:114`, `dispatch.sqlite3`; `engine/Petrus/Testing/Dst/Engine/Retry.hs:18,84`);
  - those profiles bind `SQLText` through petrus-sqlite (`petrus-motus/src/Petrus/Motus/Dispatch/Local.hs:139-141,327-348`, `C.execute` → `Connection.hs:416,434` → `bindAll`/`bindTextParam`);
  - `bindAll`/`bindTextParam` now run the new `bindLength` guard (`Connection.hs:461-497`).
- **The inconsistency.** This is the same changed path for which petrus-motus's `local-50*` rows are being remeasured (RERUN-BRIEF).
- **Effect on the figures.** Practically nil: one integer comparison per bind, against SQLite I/O. Still, the reason as written is untrue and fails the carry rule.
- **Fix.** Either rerun the two Engine-world rows and stamp, or re-carry with a true reason, for example "the only change on the path is petrus-sqlite's per-bind length check".

The other 24 carries are sound in substance; checks below in §3. Three reasons are worded inaccurately but are right in substance (NIT N-3).

**R-2. petrus-json still has two numeric cores for Python `==`, and the new haddock claims one (outcome 5; residue of D-m5).**

- **The second core.** `Petrus.Json.Value.pythonEq` keeps its own `numericEq`/`intFloatEq` (`petrus-json/src/Petrus/Json/Value.hs:61-95`).
- **The duplicate.** The fix added `pyNumberEq`/`exactFloatEq` beside it (`Python/Object.hs:186-211`). The two are identical rather than shared.
- **The claim.** Its haddock (:200) calls `pyNumberEq` "The one numeric core of every Python value model of the port".
- **The same class, elsewhere:**
  - `petrus-dst/joined/.../Joined/Support.hs:384-410` has a third Python `==` over `Json`. It compares numbers through `toRational`, so NaN and inf are mishandled.
  - Python truthiness over `Json` is spelled out six times, identically:
    - `Hamsterdan/Python/Value.hs:38`
    - `Agenticus/Runtime/Claude.hs:502`
    - `Dst/Joined/Checkers.hs:94`
    - `Execution/Providers/Docker.hs:178`
    - `Execution/Providers/Gondolin.hs:298`
    - `Motus/Dispatch/Absurd.hs:329`
  - petrus-json now has `pyTruthy` over `PyObject` but not over `Json`.
- **Fix:**
  - Make `Value.numericEq` use `PyNumber`/`pyNumberEq`, or move the core down to `Value` and let `Object` import it.
  - Add `pythonTruthy :: Json -> Bool` beside `pythonEq`/`pythonDict`, and delete the six copies.
  - Make joined-worlds' `pyEq` use `pythonEq`.

### NIT

- **N-1. Clashing constructor names.** `Hamsterdan.PyLiteral.PyValue` and petrus-json's `PyObject` now share the constructor names `PyNone`, `PyInt`, `PyStr`, `PyList`, `PyDict` and so on, in the same package. `Hamsterdan/Export.hs:919` has to write `Lit.PyList (map Lit.PyStr …)`. Distinct constructor names for the literal model would remove the qualification.
- **N-2. Repeated length-check boilerplate.** `_ <- either throwIO pure (bindLength …)` appears three times in `bindAll`/`bindTextParam` (`Connection.hs:462,466,494`). It is also open-coded in Hamsterdan's `bindChecked`. An IO wrapper (`checkBindLength :: Text -> Int -> IO CInt`) would read better and keep `bindLength` pure for the test.
- **N-3. Three carry reasons are worded inaccurately; each conclusion still holds:**
  - **petrus-fabric and petrus-telemetry-instrumentation.** They say "only petrus-json/posix library changes upstream of it". Their closures also include the changed petrus-sqlite `Connection.hs` and petrus-cel `Tz.hs`. Neither bench binds SQLite or uses a time zone: fabric uses Postgres, and telemetry-instrumentation uses an in-memory store and dispatch.
  - **petrus-agenticus-runtime RESULTS.md.** It says "in-memory stores". The runner uses a JSONL History and inline dispatch (`AgentNetRunner.hs:125,133,722`); neither changed.
  - **petrus-motus-absurd.** Its reason says the petrus-json changes are off the measured path. In fact the `uuid4` digit change runs once per lane rotation (`openAbsurdWorkerDispatch`, `Absurd.hs:760`), which is negligible.

## 2. Status of the findings the commits claim to resolve

| Finding | Status | Evidence |
|---|---|---|
| D-M1: `PV` is a second Python value model; `QualificationError` and a local `RuntimeError` | **RESOLVED** | `Hamsterdan/Python/Object.hs:84` `type PV = PyObject`. Its copies of `typeName`, `fromJson`, `forceValue`, `pyStr`, `pyRepr`, `truthy` and `pyEq` are deleted, and petrus-json's are re-exported. `PublicationQualification.hs:600` `valueError = throwIO . ValueError` and `:664` catches motus's `RuntimeError` (both `IsPythonException`). No `QualificationError` is left in the repo. The petrus-json header (`Object.hs:4-13`) now names the two deliberate narrower models. A rename-normalized diff of `Export.hs`, `Operator.hs` and the operator tests shows only renames: `forceValue` → `rnf`, and `fromJsonValue` → `fromJson`. |
| D-m1: four copies of the scanner fallback, with drift | **RESOLVED** | `Loads.hs:76-113` `LoadsRefusal`/`parseOrExplain` re-applies the limits with U+FFFD in place of each surrogate. `decodeText` (:62), DST `StrictJson.hs:47`, engine-file `PyJson.hs:54` and ZeroMQ `Wire.hs:324` all use it. No other scanner fallback remains outside petrus-json. The DST switch from `Scanner.loads` to `Scanner.decode` is right: upstream `dst.py:2361` calls `json.loads(payload)` on bytes, which has no BOM check. ZeroMQ's `decodeUtf8Python` is strict, so its text never holds a raw surrogate and its behavior is unchanged. |
| D-m2 / accuracy C: SQLite bind with no INT_MAX bound | **RESOLVED** | `Connection.hs:475-478` `bindLength`, applied to `Text` (:494), `Utf8Text` (:466) and blobs (:462). The offset is `CPtrdiff` (:481, C `ptrdiff_t`). c33829e extends the guard to Hamsterdan's own direct-sqlite binds (`Hamsterdan/Sqlite.hs:105-113`), checking each parameter for UTF-8 first and length second, which is CPython's order (`PyUnicode_AsUTF8AndSize`, then the `buflen > INT_MAX` check). The messages "string longer than INT_MAX bytes" and "BLOB longer than INT_MAX bytes" are CPython's `cursor.c` texts. The test drives the bound without allocating, at 2^31-1 and 2^31. |
| D-m3: Archive's unsafe write and `linkat` | **RESOLVED** | `Archive.hs:678-686` uses `Posix.writeAll` and `Posix.linkAt … FollowLinks`. `At.hs:164-172` is an `interruptible` capi with `AT_SYMLINK_FOLLOW`/0; the test covers following, not following, `EEXIST` and `ENOENT`. hardLink's error naming the source rather than the target is unobservable, because `makeLink` discards the exception and falls back (:709-712). The A/B record is at `bench/RESULTS.md:124-163`: the clean write is within noise of the unsafe one and ahead of Python on all three extract rows. The gate row `medium/extract` is 1.12×. |
| D-m4: viewer logger's unmeasured unsafe `write` | **RESOLVED** | `Log.hs:132` `try @IOException (Posix.writeAll …)` (unix `fdWriteBuf`, a safe call that retries on EINTR) drops a line on a broken stream, as before. The A/B is at `RESULTS.md:1097-1114`: 0.98× and 0.94× against unsafe, still 1.17× and 1.41× ahead of Node. |
| D-m5: `pyDict` and `pyEq` copies | **PARTIAL** | The named sites are fixed: engine-file `pyDict` and execution `dictFromPairs` are now `pythonDict`; engine-file `pyEqWith` and `PyLiteral.pyEq` use `pyNumberEq`; hamsterdan's `pyEq` is petrus-json's. petrus-json itself still has two numeric cores, and the truthiness copies remain (R-2). |
| D-m6: `normpath`, `pathParent` and `exitInt` triplicated | **RESOLVED** | `Petrus.Posix.Path.normpath`/`purePathParent` (`Path.hs:93-117`), compared against CPython over 27 inputs, including `//`, `///`, `//..`, `/../a` and non-ASCII. `Petrus.Posix.Process.exitInt`. CEL, execution, the operator, export and CodexGondolin call them. The byte and WTF-8 adapters are exact, because only `/` and `.` are inspected. The CodexGondolin and export parents now match `PurePosixPath`: the old export version gave `a/b` for `a/b/`, and the old CodexGondolin version gave `a/.` for `a/./b`. |
| D-m7: rmtree comment | **RESOLVED** | `petrus_posix.c:222-225` |
| D-m8: petrus-posix description | **RESOLVED** | `petrus-posix.cabal:4-13`; `Petrus/Posix.hs:1-9` |
| NIT 2 (`raised` vs `pythonError`), NIT 3 (uuid digit), NIT 5 (DST wording) | **RESOLVED** | `Exception.hs:110-122`; `Uuid.hs:73` uses `intToDigit`, which is lowercase; `StrictJson.hs:65` and the test string match. |
| Accuracy NIT 4 (`exitInt` ×3) | **RESOLVED** | as for D-m6 |
| Accuracy D (ledger gaps O-006, O-027, S-013) | **RESOLVED** | The examples are at `EngineSpec.hs:190-218`, `UpstreamSpec.hs:155-175` and `HttpSpec.hs:569-584`, and all ran green in CI. Both "Gaps" sections now read "None." (`spec/observation-conformance.md:255-257`, `spec/simulation-http-conformance.md:210-212`). |
| Accuracy B (stale results) | **In progress** | `scripts/bench --stale` at df073f3 lists the 21 files being rerun. 24 of the 25 carries are sound; the petrus-dst carry is not (R-1). |

These findings were not claimed by these commits and are out of scope here: design NITs 1, 4, 6-12 and accuracy A and NITs 1-3, which were handled by earlier commits.

## 3. New code checked against CPython (holds)

**Python value model**

- **`hashCheck`** (`Object.hs:190-203`). It recurses into tuples and reports the first unhashable item. CPython 3.14.6 gives:
  - `{(1,[2])}` → `cannot use 'tuple' as a set element (unhashable type: 'list')`;
  - `{((1,{}),)}` → `… (unhashable type: 'dict')`;
  - `{slice(1)}` is accepted (slices have been hashable since 3.12); `hashCheck` lets slices through.
- **`toJson` on a tuple.** It writes an array, and the note is `when serializing tuple item 1`, matching CPython's `__notes__`.
- **`pyEq`.**
  - int, float and bool compare exactly, and NaN equals nothing.
  - A list never equals a tuple.
  - Dicts compare as mappings.
  - Slices are compared by fields of type `Maybe Integer`. That differs from `slice(1) == slice(1.0)` (True), but this model's slices only hold ints.
  - A `PyInstance` equals nothing (documented).
- **`pyTruthy`.** NaN is true and -0.0 is false; slices and instances are true (documented).

**Loads, SQLite and paths**

- **`parseOrExplain`.** The admit path is byte-for-byte the old one. Re-parsing with U+FFFD keeps the UTF-8 length (3 bytes either way), so a document deeper than the limit that also holds a raw surrogate now gets `RecursionError` (tested), as DST already did.
- **SQLite.** The order (UTF-8, then length, per parameter) and the messages are CPython's. At exactly INT_MAX the guard lets the bind through, and SQLite refuses it as "too big", as the test comment says.
- **`normpath` and `purePathParent`.** CPython gives:
  - `//..` → `//`; `/..` → `/`; `///a/../..` → `/`; `a/../..` → `..`; `../a/..` → `..`; `` → `.`;
  - `PurePosixPath("//").parent` → `//`; `("///a")` → `/`; `("..")` → `.`; `("a/..")` → `a`.

  The Haskell rules give the same answers, and the committed test checks them against CPython directly.
- **`os.link`.** CPython's default `follow_symlinks=True` corresponds to `AT_SYMLINK_FOLLOW`, as before the change.

**Carries.** For each of the 25 carried files, the fingerprint at 36443b0 equals its measured marker, so the only change since measurement is 59b0a85 plus c33829e. I computed each package's closure diff with `scripts/bench_results.local_dependencies`, then checked the bench sources:

- **Postgres-backed:** engine-absurd, engine-postgres, history-postgres, motus-absurd, postgres, processes and fabric.
- **In-memory store and dispatch:** engine (in-memory and JSONL), observation, observation-http, telemetry-instrumentation.
- **No time zone in the measured rows:** cel. `normpath` is used only in `Tz.validateKey`.
- **SQLite only in the remeasured custody file:** agenticus-core's catalog, effect, hands and thread benches import no storage; only `Bench/Custody.hs` uses SQLite, and results-custody.md is remeasured.
- **Changed code off the measured paths:**
  - activity, dsl, impetus, http-core, json: only petrus-json and posix changed in their closures, and the loads admit path is unchanged;
  - posix: the change is additions only.
- **dst:** false (R-1).
