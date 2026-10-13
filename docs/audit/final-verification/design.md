<!-- Dated record: final verification (2026-10-13). Every finding is resolved; see ../final.md. -->

# Final verification B: design and elegance (outcome 5, README design rule)

Checked at main = HEAD = c0cb6cb. The review was read-only: no builds, no benchmarks, no git state changes.

Counts: **0 BLOCKER, 1 MAJOR, 8 MINOR, 12 NIT.**

## 1. Findings, by severity

### BLOCKER

None.

### MAJOR

**D-M1. "The one Python value model of the port" is still not true. This is residue of CK-2.**

- **Where:**
  - `packages/petrus-json/src/Petrus/Json/Python/Object.hs:4-7` claims "This is the one Python value model of the port".
  - `packages/hamsterdan-contracts/src/Hamsterdan/Python/Object.hs:84` defines `data PV` (`PNone`/`PBool`/`PInt`/`PFloat`/`PStr`/`PBytes`/`PList`/`PDict [(Text, PV)]`). It is an exact subset of `PyObject`.
  - `PV` has its own copies of `typeName` (:95), `fromJson` (:109), `pyStr` (:194), `pyRepr` (:200), `truthy` (:217) and `pyEq` (:230). They duplicate `PyObject`'s `pyTypeName`, `fromJson`, `pyStr` and `pyRepr`. Only the leaf reprs (`pythonDoubleRepr`, `pythonBytesRepr`) are shared.
  - `PV` has 163 references across hamsterdan-contracts, -export and -operator.
  - The two models are used inconsistently: petrus-impetus already writes `type PV = PyObject` (`Validation/Pydantic.hs:69`), but hamsterdan does not.
  - The exception side has the same pattern. `hamsterdan-operator/src/Hamsterdan/Host/PublicationQualification.hs:530` declares `data QualificationError = QualificationError {cls :: Text, message :: Text}` ("Python's ValueError or TypeError, with its message"), and :537 a local `newtype RuntimeError`. Both sit outside the `IsPythonException` hierarchy that CK-2's fix introduced. This is the "class: message" record that CK-2 removed from engine-file.
- **What is wrong.** This is outcome 5 (no needless duplication; one source for byte-level compatibility primitives). The structural `repr`/`str`/`==` of a list or dict must match CPython, and it is now written twice. A change in one copy does not reach the other. The petrus-json header asserts the opposite.
- **Fix:**
  - Replace `data PV` with `type PV = PyObject`, as impetus does. Add pattern synonyms if the `P*` spellings must stay.
  - Delete the duplicated functions, keeping `toJson`, which is exporter-specific.
  - Make `QualificationError` and the local `RuntimeError` `PythonException`s, or instances of `IsPythonException`.
  - The other option is to correct the header so it names `PV` as a deliberate exporter subset and gives the reason. That alone would make this a MINOR.

### MINOR

**D-m1. The "admit fast, explain with Scanner" fallback is written four times, and the copies have drifted.**

- **The four copies:**
  - `petrus-json/src/Petrus/Json/Python/Loads.hs:55-66` (`decodeText`);
  - `petrus-dst/src/Petrus/Testing/Dst/Internal/StrictJson.hs:46-63`;
  - `petrus-engine-file/src/Petrus/EngineFile/PyJson.hs:53-60`;
  - `petrus-motus-zeromq/src/Petrus/Motus/Transport/ZeroMQ/Wire.hs:320-330`.
- **The drift:**
  - For a text with a lone surrogate, `Loads.decodeText` returns `Scanner.rawJson raw` without re-applying petrus-json's nesting limit.
  - StrictJson re-parses the text with U+FFFD in place of each surrogate, so that the limits still apply.
  - So a document that is deeper than the limit and also carries a lone surrogate is admitted by `json.loads` but refused by DST.
- **Fix.** Write one combinator in petrus-json, for example `parseOrExplain :: ParseOptions -> Hooks -> Text -> Either ScanFailure Json`, with the surrogate re-check inside it. Each caller then maps only the error constructor.

**D-m2. The sqlite FFI text binder still has no length guard. This is residue of CK-m1.**

- **Where:** `petrus-sqlite/src/Petrus/Sqlite/Connection.hs:463-478`, with `cbits/petrus_sqlite.c:20`.
- **Done:** the tests asked for are in place (`test/Main.hs:209-213`: empty, non-ASCII, NUL, sliced).
- **Still open:**
  - `bindTextParam` passes `fromIntegral size :: CInt` with no check.
  - A text of 2^31 bytes or more wraps to a negative length. `sqlite3_bind_text` then reads up to a NUL past the `ByteArray#`, which is an out-of-bounds read.
  - CPython raises `OverflowError` first.
  - The `ptrdiff_t` offset is declared as `Int` rather than `CPtrdiff`.
- **Why it matters.** The design rule requires a safe and total interface over the low-level code.
- **Fix.** Refuse `size > fromIntegral (maxBound :: CInt)` with CPython's `OverflowError("string longer than INT_MAX bytes")` before the call, and type the offset as `CPtrdiff`.

**D-m3. petrus-execution Archive keeps its own unsafe FFI write loop and `linkat` binding.**

- **Where:** `petrus-execution/src/Petrus/Motus/Execution/Archive.hs:675-700`.
- **What it has:**
  - `writeAll`: a capi unsafe `write` in 64 KiB chunks;
  - capi unsafe `linkat`, `AT_FDCWD` and `AT_SYMLINK_FOLLOW`.
- **What is wrong:**
  - These duplicate `Petrus.Posix.File.writeAll` (`File.hs:76`) and petrus-posix's At module. The package already depends on petrus-posix (`petrus-execution.cabal:72`).
  - The justification is "~10% of a 256 MiB extraction", with no date, machine, repetitions or RESULTS reference. Every other kept optimization cites those.
- **Fix:**
  - Move a chunked unsafe write (for example `writeAllChunked`) and `linkat` into petrus-posix, and call them from Archive.
  - Record the figure in the usual form, or drop to `Posix.writeAll`.

**D-m4. The viewer logger's unsafe `write` has no measurement beside it.**

- **Where:** `petrus-viewer-server/src/Petrus/Viewer/Log.hs:35-40`, and its own retry loop near :138.
- **What is wrong:**
  - The comment argues qualitatively that this spares the capability hand-off. No figure supports it.
  - The other viewer low-level modules (reactor, file reads, escaper) each carry their figure, and RESULTS "Low-level code, measured" (:1016-1095) does not list the logger.
- **Fix.** Add the A/B figure (unsafe against safe `write`, or `hPut`) to the comment and to RESULTS, or use a plain `hPut`.

**D-m5. engine-file and hamsterdan keep their own copies of Python dict and equality helpers.**

- **Where:**
  - `petrus-engine-file/src/Petrus/EngineFile/Value.hs`:
    - `pyDict` re-implements `Petrus.Json.Value.pythonDict` exactly;
    - it has its own `pyEq` and `pyEqWith`.
  - `pyEq` also exists in `Hamsterdan/Python/Object.hs:230` and in `hamsterdan-contracts/src/Hamsterdan/PyLiteral.hs`.
- **What is wrong.** Python's cross-type numeric equality (bool/int/float, NaN) is written three times. engine-file's `Value` model itself is justified (jiter flags), but `pyDict` is not.
- **Fix.** Call `pythonDict`. Give petrus-json one `pyEq` over `PyObject`, which `PV` gets for free after D-M1, and reuse its numeric core in `PyLiteral` and engine-file.

**D-m6. Small helpers are triplicated. This is partly residue of CA-5.**

- `normpath`:
  - `petrus-cel/.../Tz.hs:93`;
  - `hamsterdan-operator/.../Operator/Posix.hs:110`;
  - `petrus-execution/.../PosixPath.hs:168`.
- `pathParent`:
  - `hamsterdan-export/.../Files.hs:94`;
  - `hamsterdan-operator/.../Operator/Posix.hs:99`;
  - `petrus-agenticus-runtime/.../CodexGondolin.hs:483`.
- `exitInt`:
  - `petrus-dst` campaigns `Process.hs:52`;
  - `hamsterdan-operator/.../Operator.hs:336`;
  - `petrus-agenticus-runtime/.../Internal/Process.hs:206`.
- **Fix.** Put `posixpath.normpath` and `dirname` in `Petrus.Posix.Path`, and `exitInt` (ExitCode to Python's int) in `Petrus.Posix.Process` or petrus-json's Python layer.

**D-m7. The rmtree C comment contradicts the code.**

- **Where:** `petrus-posix/cbits/petrus_posix.c:222-224`.
- **What is wrong:**
  - The comment says `is_dir` is "0 when the entry vanished".
  - The code sets 2 for that case (:276, `is_dir = errno == ENOENT ? 2 : -1;`) and skips 2 in the unlink loop (:317).
- **Fix.** Make the comment say 2 = vanished, or use named constants.

**D-m8. The petrus-posix package description is stale.**

- **Where:** `petrus-posix/petrus-posix.cabal:4-10`.
- **What is wrong.** The description still lists flock, openat, resolve, fsync and RSS. It omits the modules the waves added: the bounded interruptible poll wait (`Poll`), `gai` error codes (`Netdb`), `rmtree` (`At`) and `confstr` (`Path`). The `Petrus.Posix` haddock was updated; the cabal text was not.

### NIT

1. **Partial literal constructors.** `petrus-agenticus-core/.../Catalog/Descriptor.hs:120,249` and the siblings (`episodeBudget`, and so on) export partial literal constructors that `error` on invalid input. They are documented as "for literals" and only used that way. Moving them to an `.Unsafe` or test-support module would keep the public surface total.
2. **Exception constructor names.** `Petrus.Json.Python.Exception.raised` (:112) and `pythonError` (:120) differ only in whether an empty message gives no args. The names do not say so. Consider `raisedWith` or documenting the difference at both.
3. **Uuid hex digit.** `petrus-json/.../Python/Uuid.hs:72` uses `digit n = "0123456789abcdef" !! fromIntegral n`. It is total in practice. `intToDigit` or `BS.index` of a constant would read better.
4. **Duplicated classify block in Gates.** `hamsterdan-host/.../V5/Gates.hs:145-195`: `replyGate` and `reminderGate` duplicate the classify block. The module also imports `PythonException` via `Petrus.Impetus.Instance.FailureText` (:60) rather than from petrus-json.
5. **DST message wording.** In `petrus-dst/.../Internal/StrictJson.hs`, the refusal message says a surrogate key is something "this port cannot represent". The haddock gives the real reason, pydantic's `model_dump` rewrite.
6. **Uncommented RTS option.** The `hamsterdan-operator` test suite sets `-N4` with no comment. It is test-only. The other RTS options all carry a reason.
7. **Byte-by-byte copy.** `petrus-json/.../Encode.hs`: `bytes` copies byte by byte where `copyBytes` would do. The writer's buffer safety rests on the "reserve before poke" convention (:248-250). That is acceptable inside the one module, but worth an assertion in the test build.
8. **Unchecked narrowing.**
   - `petrus-engine-file/app/Main.hs:105,121` narrows `--indent`, `--max-inline` and `--fail-on-change` with `fromInteger` without a range check. A huge value wraps where CPython would use it (or raise `OverflowError` for the exit status).
   - `pythonExceptionStr` has a similar `fromInteger`.
9. **Mixed IORef idioms in the in-memory dispatch.**
   - `petrus-motus/src/Petrus/Motus/Dispatch/InMemory.hs:91-127`: `dispatch`, `cancel` and `settleOccurrence` use `readIORef` then `writeIORef`, while `collect` (:111) uses `atomicModifyIORef'`.
   - The module is a deterministic, single-driver pump, so this is a consistency nit, not a race in its intended use.
   - Use `atomicModifyIORef'` throughout, or plain `modifyIORef'` with a note.
10. **Dead code and partial lookups in Firing.**
    - `petrus-impetus/.../Instance/Firing.hs:194-196`: `fmap finish` with `finish l = l` is dead code.
    - :466, :478 and :555 use `l.initiated IntMap.! o` after a separate `member` guard. :571 does the same lookup totally (`case IntMap.lookup`). Use the total form everywhere.
11. **ServiceHooks missing from host DIVERGENCES.** `ServiceHooks` is documented in `Service.hs:425-449`, in hamsterdan-testing DIVERGENCES:126 and in PARITY. The host DIVERGENCES "Internal" list names `reconcileHook` but not `ServiceHooks`.
12. **Non-reentrant `strerror`.** `petrus-json/.../Python/OsError.hs` binds the non-reentrant `strerror` as an unsafe ccall. `strerror_r` would be thread-safe for unknown errnos. Known errnos return static strings on both target libcs.

## 2. Earlier findings (confirmation-audit reports): status at c0cb6cb

| ID | Earlier finding | Status | Evidence |
|---|---|---|---|
| CK-1 (MAJOR) | Two `json.dumps` encoders, the low-level one unjustified | Resolved | One direct writer in `Encode.hs`; the Builder encoder moved to `test/Petrus/Json/ReferenceEncode.hs`; figures at `Encode.hs:145-151` and in RESULTS "The direct writer" |
| CK-2 (MAJOR) | Python object/exception model plural | Resolved for the named sites; residue in D-M1 | `PyObject` merged; `PythonException.args :: [PyObject]`; engine-file `PyException` gone; CEL's closed `ExcClass` documented in `Exception.hs`. The hamsterdan `PV` model and operator `QualificationError` remain |
| CK-3 (MAJOR) | `petrus-format-json` hand-rolls argparse | Resolved | `app/Main.hs` declares the parser with petrus-argparse (`positionals`, `file`, `constant`); FileType divergence in argparse and engine-file DIVERGENCES |
| CK-m1 | FFI text binder truncates; no tests | Partly resolved | Tests at `test/Main.hs:209-213`; no length guard, offset `Int` (D-m2) |
| CK-m2 | Batch payload re-copied; impossible branch | Resolved | `dumpsMany :: Traversable t => … -> Either (a, EncodeError) (t (a, ByteString))`; b76b586 |
| CK-m3 | `hasLoneSurrogate` copies; `rawText` partial | Resolved | `Wtf8.hs:97-104` scans the array with `TA.unsafeIndex`; `rawText` no longer exists |
| CK-m4 | Two `os.urandom` implementations | Resolved | impetus `Internal/Uuid.hs` deleted; uuid7 in `Petrus.Json.Python.Uuid` |
| CK-m5 | petrus-json name/description | Resolved | cabal synopsis/description updated; `maxIntStrDigits` shared (CEL uses it) |
| CK-m6 | argv decoded lossily | Resolved | `getArguments` = Posix `getArgs` + `fsDecode`; `Main.hs:91` |
| CK-m7 | CEL DIVERGENCES §8 framing | Resolved | §8 now "A diagnostic whose rendering raises: the specification over the reference" (`petrus-cel/DIVERGENCES.md:204`) |
| PD-1 (MAJOR) | Viewer HTTP front unnecessary | Resolved | `HttpFront.hs` and `http_front.c` deleted; Warp back |
| PD-2 (MAJOR) | FastJson unmeasured second parser in a high-level package | Resolved | Moved to `petrus-json/.../Parse/InPlace.hs`; total (`Nothing` falls back); header 0.81x/1.37x; `InPlaceSpec` |
| PD-5 | SQLite `ByteArray#` bind not strictly necessary | Decided (kept with figure) | PLAN line 38; `Connection.hs:466-473` 2-6%, RESULTS:150 |
| PD-6 | Two unmeasured `casMutVar#` helpers | Resolved / decided | agenticus Atomic CAS deleted; impetus `HistoryStore.hs:105-121` `modifyStrict` with 295 vs 520 µs (ref 422) |
| PD-7 | Viewer escaper / file reader unmeasured | Resolved | Module headers + RESULTS "Low-level code, measured" (:1016-1095): 0.93/0.88/0.82x, 0.80/0.66x |
| PD-8 | Postgres C poll and unsafe libpq unmeasured | Resolved | No cbits; wait is `Petrus.Posix.Poll`; `Internal.hs:391-396` 14.09 ms vs 672 µs |
| PD-9 | petrus-json micro-optimizations without numbers | Resolved | SWAR `findSpecial` removed (`BS.findIndex`); `copyAscii` gone; `namesMayRepeat` measured (RESULTS "The duplicate-member pre-check", 0.92x without) |
| PD-10 | PyLiteral writes Text arrays without a number | Resolved | Writer in `Petrus.Json.Python.JsonRepr`, header 916 ns/1.41 µs vs 487/769 ns; bound checked (float 32, str 4×+2) |
| PD-11 | stat/RSS duplicated outside posix | Resolved | telemetry cbits deleted, uses `Petrus.Posix.Resource`; operator cbits deleted |
| PD-12 | Fabric canonical encoder in fabric | Resolved | fabric `Canonical.hs` deleted; `Model.hs:143` uses `dumps canonicalOptions` |
| PD-13 | fd-wait / spawn in wrong package | Resolved / decided | wait in `Petrus.Posix.Poll` (Gondolin uses it); spawn stays in execution (1fa27d0, PLAN) |
| PD-14 | Three errno→OSError tables | Resolved | One `Petrus.Json.Python.OsError` used by telemetry, host ExceptionClass, engine-file, execution |
| motus MAJOR-1 | zmq_poll wait can lose cancellation | Resolved | `Native.hsc` `pollBound = 50000`, figures + run ids in header |
| motus MINOR-1 | Docs describe the IO-manager wait; dead branch | Resolved | non-threaded branch removed; README:55-70, DIVERGENCES 9 |
| motus MINOR-4 | Sync bridge lanes translate Python threads | Decided | Lanes kept (MVar mailbox, Map lookup, `RuntimeError` not `!!`); DIVERGENCES 20 |
| motus MINOR-5 | Cross-language spawn bypasses custody | Decided | Documented (a8a2010) |
| CA-1 (MAJOR) | DST refuses lone surrogates | Resolved | `StrictJson.hs` admits value surrogates (with limits re-checked), refuses key surrogates |
| CA-2 (MAJOR) | Exported fields bypass smart constructors | Resolved | 9c1b593: `_field` + `HasField` getters, abstract types, `mk*` constructors (e.g. `Descriptor.hs`); BoundariesSpec; AgentNetRunner uses `mkEpisodeBudget` (:688); impetus NetDefinition/NetDocument public by decision (impetus DIVERGENCES 20, 22) |
| CA-3 (MAJOR) | DST second canonical encoder | Resolved | `Internal/Canonical.hs` deleted |
| CA-4 | Two RSS implementations | Resolved | telemetry uses posix `Resource` |
| CA-5 | Low-level I/O in high-level modules | Mostly resolved | Materialization uses posix `writeAll`/`writeAllBuffer`; HostSupport `B.hGetSome`; `exitInt` ×3 remains (D-m6) |
| CA-7 | PinnedSdkSpec re-spells Claude options | Resolved | uses `claudeAdapterOptions` / `claudeHandsTools` |
| CA-8 | Pi fail-closed divergences lack rationale | Resolved | `divergences/pi.md` entries carry "Why it stays" (:112, :197, :243) |
| CA-9 | Transcript in public library | Resolved | moved to the test suite |
| hamsterdan M1 (MAJOR) | Operator carries its own C/FFI POSIX layer | Resolved | operator cbits deleted; `Operator/Posix.hs` uses `Petrus.Posix.Path.confstrPath`; depends on petrus-posix |
| hamsterdan M2 (MAJOR) | Unmeasured optimizations in high-level packages | Resolved | FastJson → petrus-json InPlace (measured); PyLiteral writer → JsonRepr (measured); Export/Parallel kept on A/B figures (PLAN) |
| hamsterdan m4 | IOException always "OSError" | Resolved | ExceptionClass uses `ioExceptionClass` |
| hamsterdan m5 | Two exception representations bridged | Resolved / decided | engine-file `PyException` gone; motus newtypes are `IsPythonException` instances (`Motus/PythonException.hs:59-97`); `raisePython` kept and documented (`Host/Python.hs:80-90`) |
| hamsterdan m6 | `quote` / `int()` re-implemented | Resolved | `Api.hs:223` `Url.quoteBytes`; `Uvicorn.hs:235` `Url.quote`; `pythonInt` imported from petrus-json (:73) |
| hamsterdan m7 | `gaiFailure` recovers the code by text | Resolved | `Petrus.Posix.Netdb.gaiErrorCode` (C table matching `gai_strerror`) |
| hamsterdan m8 | ServiceHooks test seams on production | Decided | `Service.hs:425-449`, testing DIVERGENCES:126, PARITY (host DIVERGENCES omission: NIT 11) |
| hamsterdan m10 | Dead exports | Resolved | all 15 names have 0 references |
| viewer MAJOR-2 | Low-level code without measurement | Resolved, apart from Log.hs | Reactor 0.63x, file reads, escaper, `prelay_unmask` measured; `-N1 -qg -A4m` measured ("The allocation area"); Log.hs unsafe `write` unmeasured (D-m4) |
| viewer m7 | Oracle executable installed; `ToolResult` boolean-blind | Resolved | `ToolOk \| ToolError`; oracle moved into the test suite (`petrus-viewer-server.cabal:134,150`) |
| testing MINOR-3 | Same upstream test ported twice | Resolved | `HistoryStoreContract.hs` is shared by impetus and history-store tests |

These findings are left to the accuracy and parity verifiers and are not in the table: CK-m8, PD-3, PD-4, PD-15 (the user decided on CI benchmarking), CA-6, motus MINOR-2/3, hamsterdan m1-m3/m9/m11/m12, viewer MAJOR-1 and m1-m6, testing MAJOR-1..3 and MINOR-1/2/4.

## 3. What was verified, with evidence

### 3.1 Fresh review of the waves since d869f62

- **petrus-json consolidation:**
  - What was checked: one encoder; `Parse` (SWAR removed, `namesMayRepeat` measured); `Parse/InPlace` (total, measured, tested); `Python/Object` and `Python/Exception` (one hierarchy with `IsPythonException`/`SomePythonException`); `OsError` (one table); `JsonRepr` (bound arithmetic checked by hand: float ≤ 32, str ≤ 4×UTF-8 + 2; property-tested in PyLiteralSpec and by the CPython differential); `Uuid`.
  - Findings: D-M1, D-m1, D-m5, NITs 2, 3, 7, 12.
- **petrus-posix:**
  - What was checked:
    - `Poll.waitReadable`: interruptible C wait in a 50 ms bounded loop, with an IO-manager fallback for the non-threaded RTS; header figures 15-31%, notify 0.63x.
    - `Netdb`, `Resource`, `At.rmtree` (a safe ccall; C figure 1.00x against 1.02-1.05x), `Path.confstrPath` (capi value), `File.writeAll`/`writeAllBuffer`.
  - Findings: D-m7, D-m8.
- **Read-only HasField records:**
  - What was checked:
    - abstract exports with `mk*` smart constructors;
    - 38 `HasField` instances in AgentNet;
    - BoundariesSpec enforces the pattern;
    - derived `Show` printing `_field` names is debug-only, so harmless.
  - Findings: NIT 1.
- **argparse:**
  - What was checked:
    - the new `constant`, `positionals`, `file`/`FileMode`/`Stream`, `getArguments` and `runArgumentParser`;
    - `Parser.parseArgsIO` keeps the parse pure: it collects `FileOpen`s in State, and IO opens them afterwards in order. This is a clean split;
    - engine-file `Main.hs` is rewritten on it.
  - Findings: NIT 8.
- **DST PythonException.** StrictJson admits value surrogates and refuses key surrogates. Findings: D-m1, NIT 5.
- **Viewer back on Warp.**
  - What was checked:
    - `HttpFront` is deleted;
    - `ToolResult` is a sum (internal; the wire is unchanged);
    - FileIO, the C escaper, the reactor and `prelay_unmask` are kept with figures.
  - Findings: D-m4.
- **capi unsafe imports.** The value imports (`ENOTCAPABLE`, `_CS_PATH`, `F_OK`, `AT_*`) and the accessors are all checked. Finding: D-m3 for Archive.
- **RTS options:**
  - viewer `-N1 -qg -A4m`, measured;
  - export `-maxN4`, in DIVERGENCES;
  - testing `-A64m`, with a GC figure;
  - fae8539 removed the bench `-A32m` and the operator `-A16m`, with measurement;
  - Finding: NIT 6 (the operator test's `-N4`).
- **`namesMayRepeat`.** It uses `readArray`/`writeArray` over a bounded array, and is measured in RESULTS "The duplicate-member pre-check": 0.92x without it, and an IntSet variant was not enough.
- **Execution bench clock and connect change (0d01544):**
  - the macOS `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` capi is bench-only;
  - `exchange` drops the timer on the Unix-socket connect, and its comment matches.
- **CI scripts.**
  - An AST scan found no unused functions in `ci-tests`, `check-pending`, `lint-example-counts`, `upstream-test-counts` or `bench-gate`.
  - Every `ci-tests` subcommand is referenced from `ci.yml` or `cabal-dist`.

### 3.2 Design-rule inventory: every low-level optimization at c0cb6cb

| Item | Location | Measurement beside it | Lowest layer | Safe and total interface |
|---|---|---|---|---|
| Direct JSON writer (`unsafeDupablePerformIO`, hand buffer) | petrus-json `Encode.hs` | Yes, :145-151 + RESULTS | Yes | Yes (pure `dumps`); internal reserve-before-poke (NIT 7) |
| Duplicate-member pre-check (mutable array) | petrus-json `Parse.hs` `namesMayRepeat` | Yes, RESULTS | Yes | Yes |
| In-place parser | petrus-json `Parse/InPlace.hs` | Yes, header 0.81x / 1.37x | Yes | Yes, `Maybe`, falls back |
| `TA.unsafeWrite` repr writer | petrus-json `Python/JsonRepr.hs` | Yes, header | Yes | Yes (bound verified) |
| `TA.unsafeIndex` scan | petrus-json `Wtf8.hasLoneSurrogate` | Not needed (bounded loop, replaces a copy) | Yes | Yes |
| `strerror` unsafe ccall, `ENOTCAPABLE` capi | petrus-json `Python/OsError.hs` | Not an optimization | Yes | Yes (NIT 12) |
| Interruptible poll wait (C) | petrus-posix `Poll.hs` + cbits | Yes, header 15-31%, 0.63x | Yes | Yes, bounded 50 ms, fallback |
| `gai` code table (C) | petrus-posix `Netdb.hs` | Not an optimization (correctness) | Yes | Yes |
| `rmtree` (C walk) | petrus-posix `At.hs` + `petrus_posix.c` | Yes, C comment 1.00x vs 1.02-1.05x | Yes | Yes (comment mismatch, D-m7) |
| `confstr` capi unsafe | petrus-posix `Path.hs` | Trivial | Yes | Yes |
| SQLite text bind from `ByteArray#` (C) | petrus-sqlite `Connection.hs:463-478` | Yes, 2-6%, RESULTS:150 | Yes | **No**, no INT_MAX guard (D-m2) |
| 15 unsafe libpq accessors | petrus-postgres `Internal.hs` | Yes, :391-396 | Yes | Yes |
| zmq_poll bounded wait | petrus-motus-zeromq `Native.hsc` | Yes, header + run ids | Yes | Yes |
| `waitid` WNOWAIT, spawn, bzip2 (C) | petrus-execution cbits | Functional, not optimization; spawn location decided | Decided | Yes |
| Unsafe chunked `write`, `linkat` | petrus-execution `Archive.hs:675-700` | **Approximate** ("~10%", no date/run) | **No** (duplicates petrus-posix) | Yes (D-m3) |
| Bench clock capi | petrus-execution bench | Bench-only | n/a | n/a |
| `casMutVar#` `modifyStrict` | petrus-impetus `HistoryStore.hs:105-121` | Yes, 295 vs 520 µs | Accepted in PLAN | Yes |
| File reads (C) | viewer `FileIO` / `file_io.c` | Yes, 0.80x / 0.66x | Viewer-specific | Yes |
| JSON escaper (C) | viewer `Json.hs` / `json_escape.c` | Yes, 0.93/0.88/0.82x | Viewer-specific | Yes |
| Reactor / event loop (C) | viewer `Mcp/Reactor`, `relay_io.c` | Yes, 0.63x without | Viewer-specific | Yes |
| WebSocket unmask (C) | viewer `Frame.hs` `prelay_unmask` | Yes, RESULTS :1016-1095 | Viewer-specific | Yes |
| Unsafe `write` logger | viewer `Log.hs:35-40` | **No** | Viewer-specific | Yes (D-m4) |
| RTS options | viewer, export, testing, operator test | Yes, except the operator test `-N4` | n/a | n/a (NIT 6) |
| SWAR | None remain (`findSpecial` removed) | n/a | n/a | n/a |

### 3.3 Divergences (task 4)

All of these divergences are documented with a rationale, and none touches a wire format or specified behavior:

- petrus-argparse DIVERGENCES: FileType keeps the name rather than an open handle, with the pure/IO split;
- engine-file DIVERGENCES: the argparse-based CLI;
- impetus DIVERGENCES 20 and 22: NetDefinition and NetDocument keep public constructors (`model_construct`), see `NetDefinition.hs:568-575`;
- hamsterdan-export DIVERGENCES: `-maxN4`;
- motus-zeromq DIVERGENCES 9: the non-threaded branch is dropped;
- motus DIVERGENCES 20: lanes;
- hamsterdan-testing DIVERGENCES:126: ServiceHooks;
- CEL §8;
- DST StrictJson: surrogate keys.

The remaining wave changes are internal and need no DIVERGENCES entry:

- viewer `ToolOk`/`ToolError`;
- `dumpsMany`'s type;
- HasField getters, which keep the field names.

The one documentation gap is NIT 11.

### 3.4 Repo-wide spot-check of 8 modules the waves did not touch

| Module | Result |
|---|---|
| petrus-impetus `Instance/Firing.hs` | NIT 10: dead `finish`; guarded `IntMap.!` where :571 is total |
| petrus-engine `Coordinator.hs` | Clean: an IORef record mirroring the Python class |
| petrus-engine-sqlite `Sqlite.hs` | Clean: `mask`/`onException` discipline |
| petrus-motus `Dispatch/InMemory.hs` | NIT 9: mixed IORef idioms |
| petrus-agenticus `Internal/PyText.hs` | Clean |
| hamsterdan-host `V5/Gates.hs` | NIT 4: duplicated classify; import path |
| petrus-viewer-server `Agent/Protocol.hs` | Clean |
| hamsterdan-readiness `NetV5/Esc.hs` | No partial functions found (light scan) |
