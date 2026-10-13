<!-- Dated record: confirmation audit at d869f62 (2026-10-12). Every finding is resolved or decided; see ../final.md. -->

# Confirmation audit: kernel, CEL, DSL, history stores, Engines, platform layers

Scope: petrus-json, petrus-impetus, petrus-cel, petrus-dsl,
petrus-history-store, petrus-history-postgres, petrus-engine,
petrus-engine-sqlite, petrus-engine-postgres, petrus-engine-absurd,
petrus-engine-file (fileVersion "2"), petrus-sqlite, petrus-postgres,
petrus-posix, petrus-argparse; `upstream/petrus/spec/` with the golden traces;
CEL against cel-python.

Repository: `main` = `origin/main` = `d869f62`. Nothing was built locally (the
brief forbids it). The evidence is main's CI, the parity scripts, read-only
review, and probes against the pinned Python references
(`scripts/upstream-python`, run with `-I`). The probe scripts are in
`confirm-audit/kernel-engines/py/`.

## Summary

| Severity | Count |
| --- | ---: |
| BLOCKER | 0 |
| MAJOR | 3 |
| MINOR | 8 |

- **MAJOR CK-1.** `Petrus.Json.Encode` holds two complete `json.dumps`
  encoders. Production uses only the low-level one, and nothing beside it
  records the measurement that would justify it.
- **MAJOR CK-2.** The "one Python exception/object representation" is still
  several: `PythonArg` and `Pydantic.PyObject` in petrus-json,
  `PyException` in engine-file, and `PyErr`/`PyExc`/`ExcClass` in CEL.
- **MAJOR CK-3.** `petrus-format-json` hand-rolls a second argparse. It
  diverges from the reference in undocumented ways (`-1x`, `--indent -1a`),
  and petrus-argparse's DIVERGENCES and the root PARITY row make false
  claims about it.

## 1. Earlier findings: status

| Finding | Status | Evidence |
| --- | --- | --- |
| FA-K-1 CEL DST zones | **Resolved** | `275bc54`. `Petrus/Cel/Tz.hs` resolves keys as ZoneInfo does with an empty TZPATH and applies `zoneinfo_fromutc`, using the transition table and then the TZ rule. The tables are generated from the pinned tzdata 2026.3 (`gen/gen-tz-tables.py`), and `check-corpora` checks them (`ok petrus-cel/tz tables` in CI run 38259575603). There are 3 corpus groups (`timestamp.zones/zone_keys/zone_overflow`). The live differential ("reads every tzdata key and mutated keys at random instants and DST transitions as cel-python does") ran in CI. DIVERGENCES §7 has moved to Resolved. |
| FA-K-2 CEL error class/args | **Resolved** | `f2a1f26`. `gen-cel-corpus.py:94-97` records the whole `repr()`, `repr(args)` with `repr_raises`, and class/str/repr. `test/Corpus.hs:160-189` compares all of them (`excReprStrict`). |
| FA-K-3 Engine default refuses CEL | **Resolved** | `aa88490`. `petrus-engine.cabal:46` depends on petrus-cel. `Engine/Internal.hs:143` sets `celCompilers = Cel.celCompilers`. DIVERGENCES item 6 was rewritten. |
| FA-K-4 format CLI lone surrogates | **Resolved** | `11bbda7`, `b1338e8`. `EngineFile/PyJson.hs` keeps WTF-8 `Text`, and the refusal is gone. engine-file DIVERGENCES §1 now records only the recursion limits. |
| FA-K-5 two pydantic renderers | **Resolved for the renderer** | `0af1535`, `6a90ea7`. Rendering happens once, in `Petrus.Json.Python.Pydantic.renderValidationError`. Impetus (`Validation/Pydantic.hs:56,102`) and engine-file (`Validate.hs:406`) call it. The object models are still duplicated (CK-2). |
| FA-K-6 JSONL corrupt inputs | **Resolved** | `ce8f26d`. `HistoryStore/Jsonl.hs:234` uses `doesPathExist`. Both corrupt-UTF-8 and directory behaviors are documented in `petrus-history-store/DIVERGENCES.md:27-41`. |
| FA-K-7 stale ledger claims | **Partly resolved; recurring** | `2a99f99` fixed the listed texts, and the GoldenTracesSpec header now cites the real paths. The suggested mechanism (read counts from the suites) was not built, and counts are already stale again (CK-m8). |
| FA-K-8 vestigial validator / two answer types | **Resolved** | `58f7f00`. `Instance.hs:244-248` has `data DeliveryAnswer a … deriving (Functor, Foldable, Traversable)`. `Engine/Internal.hs:428-436` is `type Delivered = DeliveryAnswer FiringOutcome` with `traverse`. `canonicalAcceptedDelivery` is gone. |
| FA-K-9 `wait` timeouts | **Resolved** | `088083e`. `Engine/Internal.hs:388-417` `sleepNanoseconds` checks the same things in the same order as CPython's `time.sleep`: NaN is `ValueError`; round away from zero; the `[-2^63, 2^63)` range is `OverflowError "timestamp out of range for platform time_t"`; negative is `ValueError`. It rounds up into `threadDelay`. |
| FA-K-10 DSL `unsafePath` | **Resolved** | `e082e2d`. `Schema.hs:201-215` has `childPath`, `stripPathPrefix` and `pathPrefixes`. The DSL has no `error`/`unsafePath` (grep is clean). `IsString NetPath` stays partial for literals. |

## 2. Findings

### CK-1 (MAJOR, elegance and the design rule): two `json.dumps` encoders, and the low-level one has no recorded justification

**Where.** `packages/petrus-json/src/Petrus/Json/Encode.hs`.

- The production writer is `direct`/`written` (`:316-589`): `IORef Buffer`,
  `unsafeForeignPtrToPtr`, `pokeByteOff`, and its own string escaper
  `writeString`.
- The second, Builder-based encoder is `dumpsBuilder`, `writer`, `stringB`,
  `firstProblem`, `clean` and `checked` (`:201-312`, `:593-625`). It has
  its own separator logic, its own escaper and its own refusal search.

**What is wrong.**

- Every production caller uses `dumps`, `dumpsText` or `dumpsMany`, so
  every call goes through `direct`.
- `dumpsBuilder` is exported but used only by tests
  (`test/Main.hs:90,322-331`, `FloatReprSpec.hs:108,117`); grep across
  `packages/` finds no other caller.
- The second encoder is therefore library code whose only job is to be a
  test oracle. The real oracle is CPython (`CPythonDifferentialSpec`).
- Its comments are stale. `:256-259` says `writer` "throws 'Refused'
  (caught by 'dumps')", but `dumps` no longer runs `writer`. Under
  `dumpsBuilder` the refusal is pre-decided, so that `throw` (an imprecise
  exception from pure code) is unreachable.
- README:20-23 requires a low-level optimization to come with "the
  measurement that justifies it recorded beside it". `Encode.hs` records
  none. `bench/RESULTS.md` has no row for the clean (Builder) writer
  against CPython; its figures are 1.8–3.0× for the direct writer only.

**Why it matters.** Outcome 5 (better the Haskell way, no needless
duplication). Also the standing design rule in the goal. Escaping, separator
and refusal-order rules are wire-critical, and they now live in two places.

**Fix.** Measure `dumpsBuilder` (`toStrict . toLazyByteString`) against
CPython on the existing `history/net-document/thread` rows. Then take one
of two paths:

- If the clean writer keeps up (likely, since the direct writer has a 1.8×
  minimum margin), make `dumps` the Builder and delete
  `direct`/`written`/`writeString`.
- Otherwise keep `direct`. Write the figure in the `Encode.hs` header and
  RESULTS.md, and delete the Builder encoder and `firstProblem`/`clean`,
  or move them into the test suite as a test-only oracle.

Either way one encoder remains. `dumpsMany` can share `direct`'s setup;
today it duplicates the `mallocByteString`/`IORef`/`layoutOf` prologue
(`:164-167` vs `:350-352`).

### CK-2 (MAJOR, elegance): the Python object/exception model is still plural, against the repo's own claim

**Where.**

- `petrus-json/src/Petrus/Json/Python/Exception.hs:6-12` says "This is the
  one representation the Petrus and Hamsterdan ports use for an exception
  the reference raises".
- `PythonArg` (`:111-124`) is a Python value model, with `pythonArgRepr`.
- `Petrus.Json.Python.Pydantic.PyObject` (`Pydantic.hs:53-62`) is a second
  Python value model in the same package, with its own `pyRepr`. It
  overlaps `PythonArg`: None, bool, int, float, str and opaque objects are
  in both, and the two differ only in bytes/slice versus
  list/tuple/dict/instance.
- `petrus-engine-file/src/Petrus/EngineFile/Validate.hs:41-45` has
  `data PyException = PyException {exceptionClass, message}`, exported from
  `Petrus.EngineFile`. `7de3adc` says it was "left alone (… owned by the
  kernel/engine work)".
- `petrus-cel/src/Petrus/Cel/Python.hs:194` has `data PyErr = PyErr ExcClass
  Text`, and `Value.hs:310-314` has `PyExc ExcClass Text [Text]`, which
  stores a pre-rendered `str()` and pre-rendered argument reprs. Both sit
  on a closed `ExcClass`.

**Why it matters.** Outcome 5 (no needless duplication, one source for
byte-level compatibility primitives). FA-K-5 asked for "one `PyObject`
type". The fix produced a second model beside `PythonArg` instead of
merging them. The CEL and engine-file exception types render
`ClassName(args)` and `class: message` on their own, so a CPython
rendering change has to be found in three places.

**Fix.**

- Merge the two models into one `Petrus.Json.Python.Object.PyObject`
  (None/bool/int/float/str/bytes/list/tuple/dict/slice/instance-with-repr),
  with one `pyRepr`/`pyStr`/`pyTypeName`, and make `PythonException.args ::
  [PyObject]`.
- Replace engine-file's `PyException` with `PythonException`. Its
  `message` is `pythonExceptionStr`.
- Make CEL's `PyErr`/`PyExc` a `PythonException`. CEL argument reprs such
  as `StringType('x')` are the opaque-instance case. Keep only
  `CELEvalError` as CEL's own type.
- Or, if CEL must keep its closed class set, state that in `Exception.hs`
  instead of claiming "the one representation".

### CK-3 (MAJOR, parity and elegance): `petrus-format-json` hand-rolls argparse, diverges undocumented, and the ledgers deny it

**Where.** `petrus-engine-file/app/Main.hs:42-185` is a second argparse:

- a hard-coded usage line and help text;
- option abbreviation and ambiguity resolution;
- `isNegativeNumber` as "all digits or dots";
- an ASCII-only `pyInt`.

**Reference probes** (pinned `petrus.cli.format_json`, CPython 3.14.6
argparse, whose `_negative_number_matcher` is `-\.?\d`). The Haskell results
come from the code path.

| argv | reference | `petrus-format-json` |
| --- | --- | --- |
| `--indent -1a` | `error: argument --indent: invalid int value: '-1a'` (exit 2) | `looksLikeOption "-1a"` is true (`Main.hs:146-149`), so `error: argument --indent: expected one argument` |
| `-1x` (a path) | a positional path: `FileNotFoundError: … '-1x'` (exit 1) | `usageError "unrecognized arguments: -1x"` (`Main.hs:126`, exit 2) |
| `--indent ١` | accepted (`int()` reads Unicode digits) | refused (documented) |

`CliSpec`'s 52 scenarios do not cover negative-number-like arguments.
`engine-file/DIVERGENCES.md` §3 says the CLI matches "the final line of every
error" apart from its listed items, and these two are not listed.

Meanwhile:

- `petrus-argparse` already implements `-\.?\d` correctly
  (`Argparse/Parser.hs:345-350`) and Python's `int()` (`pythonInt`).
- `petrus-argparse/DIVERGENCES.md` says `nargs` other than the default and
  `store_const` are "not ported, because no reference command line
  declares them". This is false: `format_json.py` declares
  `nargs="*"`, `action="store_const"` and `argparse.FileType`.
- `PARITY.md:77` says petrus-argparse covers "every `python -m` entry
  point".

**Why it matters.**

- Outcome 1/5: the CLI's errors and exit codes differ, and the differences
  are undocumented.
- Outcome 5: there are two argparse ports, and the one FA-H-9 established
  as "one typed argparse port" is not used here.
- The documented divergences ("help not wrapped", "ASCII digits only")
  are now avoidable.

**Fix.**

- Add `nargs="*"` (a `many` positional), `store_const` and a `FileType`
  hook (open at parse time, as argparse does) to petrus-argparse.
- Declare the format CLI with it, and delete `Main.hs`'s parser, `usage`,
  `help` and `pyInt`.
- Drop the two now-false DIVERGENCES bullets.
- Add the `-1x` and `--indent -1a` scenarios to `CliSpec`.

### CK-m1 (MINOR, correctness and safety): the FFI text binder truncates lengths and has no direct test

**Where.**

- `petrus-sqlite/src/Petrus/Sqlite/Connection.hs:442-459`: `fromIntegral
  size :: CInt`.
- `cbits/petrus_sqlite.c:20`.

**What is wrong.**

- A text of 2^31 bytes or more wraps. A negative length makes
  `sqlite3_bind_text` read up to a NUL that the unpinned `ByteArray#` does
  not have (an out-of-bounds read). From 2^32 bytes up it silently
  truncates.
- CPython raises `OverflowError("string longer than INT_MAX bytes")`
  before binding.
- `ptrdiff_t` is declared as Haskell `Int`; `CPtrdiff` is the exact type.
- No petrus-sqlite example exercises the new path directly. That includes a
  sliced `Text` (offset ≠ 0, the case the C offset arithmetic exists for),
  an embedded NUL, non-ASCII text, the empty text, and the bind-error
  branch.
- The rest is sound. An unpinned `ByteArray#` in an `unsafe` call cannot
  move, `SQLITE_TRANSIENT` matches CPython, and the parameter-count check
  and message are kept.

**Why it matters.** The README rule asks for "a safe, total interface"
(outcome 5). Coverage of new low-level code is outcome 7.

**Fix.**

- Refuse `size > maxBound :: CInt` with CPython's `OverflowError` text, and
  type the offset as `CPtrdiff`.
- Add an example that binds `T.drop k t` for non-ASCII and NUL-bearing
  texts, plus `""`, and compares `SELECT typeof(?), length(?), hex(?)`
  with what Python's `sqlite3` stores.

### CK-m2 (MINOR, elegance): the batch payload is copied again after `dumpsMany`, and `encodeRow` has an impossible branch

**Where.** `petrus-history-store/src/Petrus/HistoryStore/Sqlite.hs`.

- `:466` binds `SQLText (TE.decodeLatin1 row.payload)`. Every payload
  `dumpsMany` wrote as a slice is copied into a fresh `Text`, and then
  handed to the zero-copy `Text` binder. The copy that `dumpsMany` and
  the FFI binder were each measured to remove comes back between them.
- `:173-176`: `encodeRow r = encodeRows [r] >>= \case [row] -> …; _ -> Left
  "cannot durably encode: no row"` invents a message for a case that
  cannot happen.

**Fix.**

- Either make the one-pass writer produce `Text` slices (write into a
  text array; this also removes `dumpsText`'s `unsafeTextFromBytes` copy),
  or bind the ASCII payload `ByteString` directly.
- Generalize to `dumpsMany :: Traversable t => … -> t a -> Either (a,
  EncodeError) (t (a, ByteString))`, so `encodeRow` is the `Identity`
  instance with no impossible branch.

### CK-m3 (MINOR, elegance): small WTF-8 helpers are needlessly costly or partial

- `Petrus/Json/Wtf8.hs` `hasLoneSurrogate` runs `TE.encodeUtf8 text` (a
  full pinned copy) only to scan bytes. It has 18 call sites, among them
  `loadsText`, `fsEncode` and the impetus readers. Scan `TI.Text arr off
  len` with `TA.unsafeIndex` instead.
- `Petrus/Json/Python/Scanner.hs:76-77` `rawText = T.pack` has a "call only
  on admitted strings" precondition. `Pydantic.fromRaw` relies on it. The
  total `fromCodePoints` already exists, so use it and drop the
  precondition.

### CK-m4 (MINOR, duplication): two `os.urandom` implementations

`petrus-impetus/src/Petrus/Impetus/Internal/Uuid.hs:33` opens `/dev/urandom`
with `withBinaryFile` on every mint. `Petrus.Json.Python.Uuid.randomBytes`
(`getentropy`) is the package's `os.urandom`. Use `randomBytes`. uuid7
belongs beside uuid4, in `Petrus.Json.Python.Uuid`; the process-global
counter can stay `NOINLINE` there.

### CK-m5 (MINOR, docs and layering): petrus-json is no longer what its name and description say

- `petrus-json.cabal:4-9` describes a JSON value type and serializer. The
  package now also holds the CPython compatibility layer: `getentropy` FFI
  uuid4, the filesystem codec, the exception hierarchy, pydantic error
  rendering, and Unicode/case tables.
- The `Petrus.Json.Python` umbrella haddock (`Python.hs:1-24`) lists its
  modules but omits `Python.Fs` and `PythonCase` (both re-exported) and
  `Python.Pydantic`.
- `petrus-cel/src/Petrus/Cel/Python.hs:51` re-declares `intMaxStrDigits =
  4300`, beside petrus-json's `Limits.maxIntStrDigits`.

**Fix.** Update the synopsis/description (or split out a `petrus-python`
package that depends on petrus-json), complete the umbrella list, and reuse
`maxIntStrDigits`.

### CK-m6 (MINOR, parity edge): argv is decoded lossily

- `petrus-argparse/src/Petrus/Argparse.hs:262` uses `map T.pack argv`.
  `petrus-engine-file/app/Main.hs:180` uses `getArgs >>= parseArgs` with
  `T.pack` paths.
- GHC's `getArgs` escapes undecodable bytes as U+DC80–U+DCFF (PEP 383, the
  same scheme as Python's `sys.argv`). `T.pack` then replaces each with
  U+FFFD.
- So a non-UTF-8 file name passed to `petrus-format-json` is not found,
  where the reference opens it. An argparse error quoting such an argument
  shows `'�'` where the reference shows `'\udcff'`.
- `hamsterdan-export/app/Main.hs:14` already does this right:
  `System.Posix.Env.ByteString.getArgs` followed by `fsDecode`.

**Fix.** Read argv that way inside `runArgumentParser`, which should take or
read `[Text]` decoded by `fsDecode`. Do the same in the format CLI, which
CK-3 moves onto petrus-argparse anyway.

### CK-m7 (MINOR, divergence documentation): CEL DIVERGENCES §8 frames a spec-mandated behavior as a missing seam

**Where.** `petrus-cel/DIVERGENCES.md` §8.

**Behavior, verified against the reference.**

- In celpy, `repr()` of a `CELEvalError` raises
  `IndexError('pop from empty list')` for `x.tags == []`,
  `x.tags + [] == 1` and `x.n > {}`.
- Upstream `enabledness.py:384-393,418-427` and
  `instance/__init__.py:2368-2375` format the warning with `{error!r}`.
  The `IndexError` therefore escapes `guards_hold` / `is_complete`, and the
  Instance call raises.
- The port warns and treats the binding as not satisfied.
- That is exactly what `upstream/petrus/spec/firing-semantics.md:36-48`
  rules: a runtime evaluation error means "binding is not satisfied … and
  enablement computation continues". The reference contradicts its own
  spec because of a celpy rendering bug.

The DIVERGENCES text says instead that "matching the reference here needs a
seam that lets a diagnostic abort the call". That reads as a known gap,
reachable from a realistic net.

**Why it matters.** Outcome 5: every intentional divergence must be
documented with its rationale. Here the rationale is the spec, and outcome 2
(conformance) favors the port.

**Fix.** Restate §8 as intentional: the spec rules a skip, and the
reference's crash is celpy's `tree_dump` bug. Cite the spec lines. Mention
it in the root PARITY CEL row, which still says "corpus of 1996
expressions" (see m8).

### CK-m8 (MINOR, verifiability): example and corpus counts in prose are stale again

| Claim | Says | CI run 38259575603 at HEAD / file |
| --- | --- | --- |
| `petrus-json/PARITY.md:63` | 123 examples | 125 |
| `petrus-cel/PARITY.md:14` | 170 examples | 171 |
| root `PARITY.md:32` (CEL) | "corpus of 1996 expressions" | `cel-corpus.json` has 2673 cases, which `petrus-cel/DIVERGENCES.md` and its PARITY state |

FA-K-7 proposed reading these counts from the suites. `scripts/check-parity`
checks upstream test counts but not the port's own example counts, so they
drift on every test change.

**Fix.** Have `check-parity` (or `ci-tests ledger`) compare `cabal test`'s
"N examples" with the ledgers. Or drop the numbers from the prose and let
the CI ledger artifact carry them.

## 3. Verified and holding

- **CI.**
  - HEAD `d869f62` (run 38259575603) is green. Its plan reports "44 suites,
    44 to run, 0 reused", so the `baf5836`/`9e691e8` changes to
    petrus-json, petrus-sqlite and the history store were tested.
  - Counts in scope: impetus 5783, json 125, cel 171, dsl 111,
    history-store 135, history-postgres 60, engine 226, engine-sqlite 20,
    engine-postgres 31, engine-absurd 58, engine-file 1004, sqlite 31,
    postgres 37, posix 30, argparse 4 (219 cases inside 4 examples).
  - The Postgres-backed suites run under docker in CI. This closes the
    earlier audit's "not run" gap.
  - `check-corpora` regenerates byte-identically, including `petrus-cel/tz
    tables`, `gen-cel-corpus`, `gen-cel-instance`, the kernel corpora and
    `petrus-json/python tables`. `interop --check` passed.
- **Upstream tests mirrored.**
  - `packages/petrus-impetus/scripts/parity_check.py` (run now): "672
    in-scope upstream tests, 0 unaccounted".
  - `packages/petrus-engine/scripts/parity_check.py`: "460 in-scope
    upstream tests (439 distinct), 0 unaccounted".
  - The only Hypothesis test in scope is
    `test_instance_replay_properties.py` (`max_examples=300,
    derandomize=True`). It stays ported as
    `InstanceReplayPropertiesSpec`. Grep confirms that
    `test_net_document_lineage.py` uses no Hypothesis.
  - The petrus-engine repo's in-scope tests are mapped in
    `petrus-engine-file/PARITY.md` §5. The other files are out of scope:
    runtime, DSL, timers, tokens, stubgen.
- **Spec and golden traces.** `GoldenTracesSpec` regenerates all 8 fixtures
  and the manifest byte-identically and replays each one.
  `SpecFixturesSpec` discovers every `spec/` fixture rather than listing
  them.
- **dumpsMany (correctness).**
  - Growth copies the written prefix (`grow`, `:372-380`), so every
    earlier item survives a regrowth.
  - The slices are cut from the final buffer only after all writes.
  - A refusal answers the item itself.
  - It equals `traverse dumps` by a QuickCheck property (`test/Main.hs:336-340`)
    and by a corpus test (`CPythonDifferentialSpec.hs:371-375`).
  - Its gain is recorded beside the call site (`Sqlite.hs:181-186`) and in
    the history-store RESULTS per-change table. The row was 0.91–0.94× on
    Linux CI before the change, so the README rule's precondition held.
- **The one-pass writer (correctness).**
  - Escape sets match CPython's `ESCAPE`/`ESCAPE_ASCII`, including `\u007f`
    under `ensure_ascii`.
  - The reservation bound (6 bytes per input byte) holds for every escape.
  - `minBound :: Int` is written correctly through `Word`.
  - Keys sort by UTF-8 bytes, which is code-point order, and that holds for
    WTF-8 surrogates too.
  - The indent separators match CPython's.
- **FFI text binding (correctness).** An unpinned `ByteArray#` in an
  `unsafe` call is GC-safe. SQLite copies the bytes (`SQLITE_TRANSIENT`).
  The parameter-count check uses direct-sqlite's message. The binder sits
  in the lowest layer, internal to petrus-sqlite, and the measurement is
  recorded at `Connection.hs:445-451`. Only the length bound is missing
  (m1).
- **`sqlite3_busy_timeout`** is called as CPython's `connect(timeout=)`
  calls it. It is documented under petrus-sqlite DIVERGENCES "Resolved".
- **CPython-fidelity modules.**
  - `Fs` (surrogateescape decode/encode, including CPython's
    run-of-surrogates error span), `Loads` (fast admit, then CPython's
    scanner for the exact refusal), `Pydantic` (one renderer, with pydantic's
    25/24-byte truncation), `PythonCase` (keeps surrogates through
    `fromCodePoints`) and `Exception` (an open `IsPythonException`
    hierarchy) are clean.
  - They are checked live against the pinned interpreter
    (`PythonCompatSpec`), and their tables are regenerated by
    `check-corpora`.
  - WTF-8 in plain `Text` stays a documented trade-off. `Data.Text`
    operations that re-encode (`T.map`, `T.pack`) replace surrogates, and
    the ports route around them (`fromCodePoints`, `lossyUtf8`).
- **CEL time zones.** `Tz.zoneUtcOffset` follows C `zoneinfo_fromutc`:
  `ttinfo_before`, then bisect-right, then the TZ rule evaluated in the UTC
  year, with standard time before the start and DST before the end.
  `normpath` and key validation follow `_tzpath`.
- **Engine.** Delivery doors `traverse` the one `DeliveryAnswer`. CEL is in
  the default options. `wait` follows `time.sleep`. No partial functions in
  the Engine, store or DSL sources (grep).
- **History-store SQLite.** The refusal text matches `sqlite.py:348-349`
  word for word. `verifyInsert` uses Python value equality
  (`Json`'s `Eq`), as `json.loads(stored) == encoded` does.
- **petrus-argparse (typed API).**
  - `Arg` is an `Applicative` of declarations plus decoder, and each
    destination is read back through the `Type` that declared it, so a
    misspelled or mistyped read is ruled out.
  - Negative-number detection is CPython's.
  - CK-3 and m6 are the gaps.
