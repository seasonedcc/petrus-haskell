# Elegance audit: petrus-viewer-server, petrus-engine-file, repo coherence and tooling

Audited on local `main` at `8d08f99` on 2026-10-11. This audit judges design
quality only. Accuracy (parity, wire bytes, test coverage) was audited
separately in the other files under `docs/audit/`, and this one does not
redo that work. The bar is the goal's "better the Haskell way" outcome: where
Haskell clearly makes a part safer, simpler, more correct, more composable or
faster than a direct translation, the port does so. Each case is decided on
its merits, and over-engineering counts as a defect too.

Slice:

1. `packages/petrus-viewer-server` and `packages/petrus-engine-file`: `src`,
   `app`, `test`, `bench`, the cabal files and `DIVERGENCES.md`.
2. Coherence across all 43 packages: idioms, shared helpers, package
   granularity, cabal hygiene and reuse of test support.
3. Tooling and docs: `scripts/*`, README, PARITY, SCOPE, UPSTREAM and `docs/`.
   This audit does not cover `.github/workflows/ci.yml`, which another track
   owns.

Method: read-only. The audit read the sources, ran targeted `grep` surveys
across `packages/*/src` (duplicate definitions, FFI imports, `unsafePerformIO`,
partial functions, dependency choices), and parsed every `.cabal` file
mechanically. Nothing was built or run. Line numbers are at `8d08f99`.

## Verdict: passes with changes

Package by package, the design is strong. The code is typed at its
boundaries, with typed error kinds rendered to the reference's text only at
the edge (`EngineFile.Validate.ErrorKind`, `LineError`). Partiality is rare:
`error` is called about 27 times in all of `packages/*/src`, and only for
internal invariants. Effects are separated from pure logic where it matters
(`Viewer.Cli.parseCliArgs` is pure, and so are the engine-file loaders over
`Either PyException`). Low-level code exists only where a measured
performance or byte-for-byte requirement demands it, and the reason is
written next to it. The tooling is unusually disciplined.

At the repository level, the port has a coherence gap. Its own plan of
record says there should be "one shared layer per external system"
(`docs/runtime.md:8481`). `petrus-json` is the declared foundation for CPython
fidelity. But the CPython-emulation primitives (`repr`, `str.isprintable`,
`json.loads` diagnostics, `UnicodeDecodeError` text, `argparse`) are
re-implemented in up to seven packages each. Two platform seams that were
documented as temporary were never closed. Some copies use GHC's `Data.Char`
as a stand-in for CPython's printability, which `petrus-json`'s own header
calls wrong (ELG-R-1). Duplicated behavior that silently diverges is the
failure that a single foundation package exists to prevent.

ELG-R-1 to ELG-R-3 are the changes the elegance bar needs. The rest are
polish worth doing when the files are touched. No finding requires a change
to any wire format or specified behavior. ELG-R-1 removes a latent
divergence.

## Findings

Ranked by impact.

| ID | Severity | Area | Summary | Churn | Wire/behavior risk |
| --- | --- | --- | --- | --- | --- |
| ELG-R-1 | major | repo | CPython-emulation primitives duplicated across ~15 packages; several copies approximate printability with GHC's Unicode tables | ~20 modules, net about −1,500 lines, incremental | none; removes a latent divergence |
| ELG-R-2 | major | repo | Shared platform layers bypassed: unfinished `petrus-posix`/`petrus-sqlite` seams, 5 private `flock` FFIs, a copy-pasted writer fence | ~8 modules, net about −600 lines | none |
| ELG-R-3 | minor | repo | `argparse` emulated four times; `hamsterdan-host` re-implements `hamsterdan-cli` | ~3 modules, net about −400 lines | none |
| ELG-R-4 | minor | engine-file | Parse failures are thrown from pure code and caught with `unsafeDupablePerformIO (try (evaluate …))` | ~100 lines | none |
| ELG-R-5 | minor | viewer | The event-loop substrate is duplicated between `Relay` and `HttpFront` | ~100 lines | none |
| ELG-R-6 | minor | docs | Stale design statements: viewer "Join ordering" divergence, runtime.md "no Haskell code exists yet", Observation.hs "when it lands" | a few lines | none |
| ELG-R-7 | minor | tooling | `scripts/interop` selects tests by a central table of name substrings | ~100 `describe` sites | none |
| ELG-R-8 | minor | docs | PARITY.md cells restate figures that live in package files; the per-package doc set is not checked | edit about 60 rows; a few lines in check-parity | none |

### ELG-R-1 (major): one home for CPython-observable behavior

**What's wrong.** Many Petrus wire texts embed CPython diagnostics. For that,
`petrus-json` already provides the exact primitives:
`Petrus.Json.PythonText` (`pythonStrRepr` and `isPythonPrintable`, from a
table generated from CPython 3.14.6 / Unicode 16.0 and checked on every code
point) and `Petrus.Json.Repr` (`pythonReprText`, `pythonReprBytes` and
`pythonReprFloat`). Its header (`packages/petrus-json/src/Petrus/Json/PythonText.hs:6-8`)
explains why GHC's `Data.Char` cannot stand in: GHC 9.10 ships Unicode 15.1,
and `isPrint` admits the space separators. Despite that, the following are
re-implemented:

- **`repr(str)`**, at least 6 independent copies:
  `petrus-agenticus-core/src/Petrus/Agenticus/Internal/PyRepr.hs:17`,
  `petrus-dst/src/Petrus/Testing/Dst/PyRepr.hs:55`,
  `petrus-execution/src/Petrus/Motus/Execution/Internal/PyText.hs:140`,
  `petrus-motus/src/Petrus/Motus/Internal/Repr.hs:31`,
  `petrus-cel/src/Petrus/Cel/Python.hs:41` and
  `hamsterdan-contracts/src/Hamsterdan/PyLiteral.hs:195`. The first three
  decide printability with `generalCategory` (Unicode 15.1, not 16.0). See
  `PyRepr.hs:35`, `Dst/PyRepr.hs:73` and `PyText.hs:186`.
  `petrus-motus`'s `pyStr` uses `isPrint` (`Repr.hs:41`), so it writes
  U+00A0 and the other `Zs` separators raw, where CPython writes `'\xa0'`.
  That `pyStr` reaches refusal texts (`Dispatch/Inline.hs:67`,
  `Worker.hs:192`, `Worker/Cli.hs:213-219`). The divergence is rare, but it
  is real, and it is exactly what the shared table exists to prevent.
- **The CPython printable table itself**, generated three times:
  `petrus-json/src/Petrus/Json/PythonText/Printable.hs`,
  `petrus-cel/src/Petrus/Cel/Unicode/Tables.hs` (`pythonPrintable`) and
  `hamsterdan-contracts/src/Hamsterdan/PyLiteral/Printable.hs`.
- **`repr()` of a decoded JSON value** (`None`/`True`, `nan`/`inf`, dict and
  list spelling), at least 5 folds over the same `Json` type:
  `petrus-agenticus-runtime/src/Petrus/Agenticus/Runtime/AgentNetRunner.hs:216`,
  `petrus-execution/src/Petrus/Motus/Execution/Timeline.hs:464`,
  `petrus-motus/src/Petrus/Motus/Internal/Repr.hs:88`,
  `petrus-motus-absurd/src/Petrus/Motus/Dispatch/Absurd.hs:1492` and
  `petrus-simulation/src/Petrus/Simulation.hs:213`. Each also re-decides the
  `nan`/`inf` cases around `pythonFloatRepr`.
- **A CPython `json.loads` scanner that reproduces `JSONDecodeError` text**
  (`msg: line L column C (char P)`), four times:
  `petrus-impetus/src/Petrus/Impetus/Internal/PyJson.hs` (413 lines, with
  `Hooks` for `object_pairs_hook`/`parse_int`/`parse_float`/`parse_constant`),
  `petrus-engine-file/src/Petrus/EngineFile/PyJson.hs` (345),
  `petrus-dst/src/Petrus/Testing/Dst/Internal/StrictJson.hs` (391) and
  `petrus-motus-zeromq/src/Petrus/Motus/Transport/ZeroMQ/PythonDecode.hs` (290).
  The last two use the same design ("admit with petrus-json, re-scan on
  refusal for CPython's message"), written twice.
- **The `UnicodeDecodeError` position text of CPython's strict UTF-8
  decoder**, five times: `Impetus/Internal/PyJson.hs:65-116`,
  `ZeroMQ/PythonDecode.hs:34-100`, `Dst/Internal/StrictJson.hs:147-149`,
  `EngineFile/PyText.hs:161-168` and `Cel/Ops.hs:1558`.

**Better shape.** Treat `petrus-json` as what PARITY.md already calls it,
the foundation for CPython fidelity. (If the JSON name feels wrong for
`str` predicates, a small `petrus-python` package can sit under
`petrus-json`, but that is optional.) It would export:

```haskell
-- Petrus.Json.PythonText (exists): pythonStrRepr, isPythonPrintable
-- Petrus.Json.Repr (extend)
pythonRepr :: Json -> Text            -- None/True/nan/inf/dict/list, one fold
-- Petrus.Json.Python.Codec (new; moved from impetus)
decodeUtf8Python :: ByteString -> Either Text Text   -- CPython's UnicodeDecodeError text
-- Petrus.Json.Python.Scanner (new; impetus's Internal.PyJson, generalised)
loadsWith :: Hooks e -> Text -> Either (ScanError e) Raw
renderDecodeError :: Text -> Int -> Text             -- "msg: line L column C (char P)"
```

Each consumer then keeps only its own admission policy: the hooks, and
which Python value type it builds. The per-package Python value types
(`Pydantic.PV`, `Dst.PyObj`, `EngineFile.Value`, `PyLiteral`) model
different object sets (tuples, models, bytes) and should stay separate. Only
their leaves (`str`, `float` and `Json`) should come from the foundation.
Do it in steps: (a) replace every local `str` repr and printability
predicate, which is the smallest change and closes the latent divergence;
(b) add `pythonRepr :: Json -> Text`; (c) move the scanner and the codec
text. Step (c) also makes the lone-surrogate fix proposed in IMP-2 a
one-place change, because impetus's scanner already keeps lone surrogates
(`String`) until admission.

**Churn.** About 20 modules. Net change is around −1,500 lines (four scanners
of 290 to 413 lines become one; about 15 small `repr` and codec copies are
deleted). **Risk.** None to wire formats. Every consumer has a differential
corpus that pins its texts. The only behavior change is the intended one:
`Zs` separators and Unicode 16 code points are escaped as CPython escapes
them.

### ELG-R-2 (major): finish the platform seams the plan of record prescribes

**What's wrong.** Section 14.1 of `docs/runtime.md` says "One shared layer per
external system" (`:8481`). Its package table makes `petrus-execution` depend
on `petrus-posix` and `petrus-agenticus-core` on `petrus-sqlite`
(`:8513`, `:8515`). Both shared packages are on `main`, at parity, and
differentially tested. But:

- `petrus-execution/src/Petrus/Motus/Execution/Internal/Posix.hs` (416 lines)
  and `cbits/petrus_posix.c` still carry their own `flock`, `fsync`, atomic
  replace, `realpath`, `mkdir -p` and `*at` helpers. The module header
  (`:3-9`) says they exist only "before `petrus-posix` lands on main" and
  should be swapped "without changing callers". `petrus-execution/DIVERGENCES.md:37`
  still says `petrus-posix` is "not yet on main". There are now two
  `atomicWriteFile` implementations with different temp-naming and
  directory-fsync policies (`Internal/Posix.hs:300` and
  `petrus-posix/src/Petrus/Posix/File.hs:146`).
- `petrus-agenticus-core/src/Petrus/Agenticus/Internal/Sqlite.hs:3-7` says
  "`petrus-sqlite` is not on `main` yet ... once it lands, replace this
  module's implementation". The same is restated in
  `petrus-agenticus-core/DIVERGENCES.md:14` and
  `petrus-agenticus/DIVERGENCES.md:84-85`.
- `flock` is imported by private FFI in five places instead of through
  `Petrus.Posix.Flock`. Four of them hard-code the `LOCK_*` constants:
  `petrus-agenticus/src/Petrus/Agenticus/Attachment/Retention.hs:775`,
  `petrus-agenticus-runtime/src/Petrus/Agenticus/Runtime/PiRecovery.hs:656`,
  `…/Runtime/CodexGondolin.hs:434`,
  `petrus-motus-zeromq/src/Petrus/Motus/Transport/ZeroMQ/Server.hs:241`,
  plus `petrus-execution`'s own.
- The owner-checked SQLite writer fence (`WriterFence`, `openWriterFence`,
  the mode-0600, owner and fork checks) appears twice, identical except for
  its message strings: `Retention.hs:770-840` and `PiRecovery.hs:651-721`.

**Better shape.** Close the seams the way their own comments describe.
Make `Execution.Internal.Posix` re-export `petrus-posix`, keeping only the
spawn and `waitid` helpers that are specific to execution, or delete it.
Implement `Agenticus.Internal.Sqlite` over `petrus-sqlite`'s `Connection`.
Use `Petrus.Posix.Flock` everywhere. Write one fence, parameterized by its
texts:

```haskell
data FenceTexts = FenceTexts { unavailable, badMode, live, unlockable, closed, forked :: Text }
openOwnedFence :: FenceTexts -> FilePath -> IO OwnedFence   -- in petrus-agenticus-core
```

Then delete the "not on main" sentences.

**Churn.** About 8 modules, net about −600 lines, plus one C file. **Risk.**
None. The helpers being replaced implement the same POSIX calls, and the
shared ones carry the differential tests.

### ELG-R-3 (minor): one `argparse`

**What's wrong.** CPython's `argparse` (option classification, prefix
abbreviation, `int()` conversion, usage and help layout, `textwrap`
wrapping to `COLUMNS`) is emulated four times:

- `hamsterdan-cli/src/Hamsterdan/Cli/Argparse.hs` (843 lines; general:
  actions, choices, subcommands, `HelpFormatter`), used by
  `hamsterdan-export` and `hamsterdan-operator`;
- `hamsterdan-host/src/Hamsterdan/Host/Cli.hs:117-546`, about 430 lines of a
  separate parser and formatter. `terminalColumns`, `environmentColumns`,
  `windowColumns` (an `ioctl` FFI) and `pythonInt` are identical to
  `Argparse.hs:799-846`;
- `petrus-motus/src/Petrus/Motus/Internal/Argparse.hs` (308 lines);
- `petrus-engine-file/app/Main.hs:86-150`, written for this program alone.

`hamsterdan-cli` also depends on `hamsterdan-github` only to reach
`Hamsterdan.GitHub.Python` (`isSpace`, `pyIntBase`; `Argparse.hs:65`, `:757`,
`:801`). That is a set of generic CPython helpers living in the GitHub
package.

**Better shape.** Have `hamsterdan-host` declare its five subcommands with
`Hamsterdan.Cli.Argparse`, which already supports subcommands and choices.
That removes about 430 lines from an application that sits in the same
layer. Move the `str` and `int()` helpers that `hamsterdan-cli` needs to
ELG-R-1's home, so it no longer depends on `hamsterdan-github`. Moving the
parser down to the Petrus layer, so `petrus-motus` and `petrus-format-json`
could share it, is optional. Their parsers are small and specific, and the
churn there is not clearly worth it.

**Churn.** `Host/Cli.hs` and the cabal files. **Risk.** None. `CliSpec`
compares 105 command lines with the reference byte for byte.

### ELG-R-4 (minor): engine-file parsers use imprecise exceptions for expected failures

**What's wrong.** Both parsers in `petrus-engine-file` signal a refusal by
`throw` from pure code and recover it with
`unsafeDupablePerformIO (try (evaluate …))`. See
`src/Petrus/EngineFile/Jiter.hs:116`, `:121` and
`src/Petrus/EngineFile/PyJson.hs:76`, `:97`, `:335`. A malformed document is
an expected outcome, not an exceptional one, and the refusal text is the
contract. Under imprecise-exception semantics GHC may pick either of two
throwing subterms, and `evaluate` forces only to weak head normal form. The
code is correct today because `StrictData` and the offset threading
sequence everything. That correctness rests on strictness details, not on
types.

**Better shape.** Use the form `petrus-json` itself uses. Its parser returns a
`Step` whose negative offset marks failure, which GHC unboxes like the
exception path but which stays pure and total
(`petrus-json/src/Petrus/Json/Parse.hs:113-129`). `PyJson` disappears under
ELG-R-1. `Jiter` (pydantic's jiter grammar and messages, rightly separate)
needs the conversion.

**Churn.** About 100 lines in `Jiter.hs`. **Risk.** None. The 911-case
corpus and live fuzzing pin every refusal.

### ELG-R-5 (minor): viewer event-loop substrate written twice

**What's wrong.** `Petrus.Viewer.Relay` and `Petrus.Viewer.HttpFront` are two
event loops over the same C poller, and they duplicate:

- the 12 FFI imports (`Relay.hs:93-105`, `HttpFront.hs:83-94`);
- poller and wake-pipe creation (`Relay.hs:182-195`, `HttpFront.hs:182-194`);
- the stop handshake (`stopRequested` IORef plus `stopped` TVar;
  `Relay.hs:209-213`, `HttpFront.hs:210-214`);
- the poll-then-block wait (`Relay.hs:264-272`, `HttpFront.hs:240-248`);
- `writeChunks` verbatim (`Relay.hs:405`, `HttpFront.hs:426`).

Separately, `span'` (`HttpFront.hs:316`) re-implements `Data.List.partition`.

**Better shape.** Add a `Petrus.Viewer.EventLoop` module exporting
`Poller` (`create`/`add`/`remove`/`watchWrite`/`wait`/`wake`),
`withLoopThread :: Int -> (Poller -> IO ()) -> (Poller -> IO a) -> IO a`
(fork, stop and join), and `writeChunks`. The two loops keep only their own
dispatch logic.

**Churn.** About 100 lines moved, about 60 deleted. **Risk.** None. The
`wire` suites compare bytes against `ws` and `node:http`.

### ELG-R-6 (minor): stale design statements

- `packages/petrus-viewer-server/DIVERGENCES.md:77-81` ("Join ordering")
  describes the previous design: a thread per connection, "one STM
  transaction" per event, and a 250 ms hold. The relays are now one event
  loop that orders events as Node does (`Relay.hs:28-31`), so this entry is
  no longer a divergence. Delete it.
- `packages/petrus-viewer-server/src/Petrus/Viewer/History/Observation.hs:9`
  says "the Haskell runtime when it lands". It has landed, and `HistorySpec`
  serves a Haskell Engine.
- `docs/runtime.md:13-14` says "No Haskell code exists yet for anything it
  covers", and README links the file as a plan of record. Add a one-line
  banner: historical plan; current status in PARITY.md; divergences in each
  package's DIVERGENCES.md.
- The "not on main" sentences of ELG-R-2.

**Churn.** A few lines. **Risk.** None.

### ELG-R-7 (minor): mark interop membership where the test is defined

**What's wrong.** `scripts/interop:47-110` keeps a table from each package to
hspec `--match` substrings. Some substrings are as broad as `"Python"`,
`"upstream"` and `"CPython"` (petrus-json, petrus-posix, petrus-postgres,
petrus-sqlite). Whether a test belongs to the cross-language set is decided
in a Python file far from the test. A renamed `describe` silently changes
the selection. `--check` catches only a pattern that selects nothing, not
one that selects too much or misses a new group.

**Better shape.** Tag the groups at their definition site. Add one
combinator to `petrus-test-support`:

```haskell
interop :: String -> SpecWith a -> SpecWith a
interop name = describe ("interop: " <> name)
```

Then `scripts/interop` runs `-m "interop: "` for every package, and the
table goes away. `--check` keeps its value: every package listed must
select at least one example.

**Churn.** Wrap about 100 `describe` sites. **Risk.** None.

### ELG-R-8 (minor): keep each figure in one place; make the doc set checkable

- PARITY.md rows hold paragraphs of evidence: the DST and Absurd rows run
  to about 1,000 characters, and test counts and benchmark ratios are
  restated there. The same figures live in the package PARITY.md, in
  `bench/RESULTS.md` and in `bench-results/summary.md`, so each rerun must
  edit up to four places. Keep the top-level row to status, a one-line
  headline and links. The detail already lives in the package files, and
  `check-parity` already reads the linked results files.
- The README's rule ("every intentional API divergence is documented next
  to the package") is not checked mechanically. `petrus-cel` (see IMP-7) and
  `petrus-telemetry-instrumentation` have no DIVERGENCES.md. Requiring a
  DIVERGENCES.md (possibly "None.") for every package that PARITY.md names
  is a three-line addition to `scripts/check-parity`.

**Churn.** Editing about 60 table rows, and a few script lines. **Risk.**
None.

## Considered and not raised

These were weighed and left alone.

- **The viewer's hand-rolled HTTP front and relay event loops**
  (`HttpFront.hs`, `Relay.hs`, `cbits/`). They are a lot of low-level code
  for a local dev server. But they serve two stated requirements: Node's
  exact response framing on the endpoints (`Connection`/`Keep-Alive` header
  bytes, `100 Continue`, idle close), and the speed bar. The previous Warp server
  reached only 1.03 to 1.16× Node's median, and the HTTP front adds 8 to 23%
  on top of that (`packages/petrus-viewer-server/bench/RESULTS.md:370-378`). They are
  contained, documented at the top of each module, and pinned by the `wire`
  suites. Only their duplication is raised (ELG-R-5).
- **The viewer's own JSON (`JsValue`) and WHATWG URL parser.** They have
  V8 and Node semantics, not CPython's, and they already reuse
  `petrus-json`'s shortest float digits (`Json/Number.hs:27`).
- **engine-file's `Jiter` next to a CPython scanner.** pydantic's `jiter` has
  its own grammar, limits and messages. It must stay separate.
- **engine-file's Python-equality `Eq` instances** (`Types.hs:60-254`, where
  NaN is never equal). They mirror `Double`'s own `Eq`, they are documented
  in the module header, and they are used only for model equality.
- **Three HTTP server cores** (`petrus-http-core` for `http.server`, the
  uvicorn-shaped Warp responses in `hamsterdan-host`, and the viewer's
  `node:http` front). Each reproduces a different upstream server's bytes,
  and a shared core would couple unrelated byte contracts.
- **29 one-line `tshow`/`showT` definitions.** A shared prelude would cost
  more than it saves.
- **Small provider packages** (`petrus-engine-sqlite` has 67 source lines,
  `-postgres` 270 and `-absurd` 189). They mirror upstream's optional extras
  and its package-boundary tests. Keeping libpq, libzmq and Node away from
  the neutral packages is the point. `petrus-telemetry-instrumentation` (a
  tests-only package) and the viewer's `HistorySpec` both keep dependencies
  one-way. Both choices are sound.
- **`common warnings` with `-Werror`, copied into 43 cabal files.** Cabal
  has no cross-package common stanzas, and the pinned GHC plus
  `cabal.project.freeze` (136/136 packages) make `-Werror` safe. Lower bounds
  in the cabal files with exact versions in the freeze file is a coherent
  policy for an application repository.
- **Two record styles.** 28 packages use
  `OverloadedRecordDot`/`NoFieldSelectors` and 15 do not. Each package is
  internally consistent, so the churn is not worth it.
- **`process` next to `typed-process`.** This is harmless.

## Exemplary

- **One JSON foundation and no aeson.** `petrus-json` is used everywhere for
  CPython semantics, and `petrus-sqlite`'s `PythonRepr` shows the right
  reuse pattern (it re-exports `Petrus.Json.Repr`). `petrus-json`'s test
  module re-derives `repoRoot` rather than depend on `petrus-test-support`,
  which depends on it. Avoiding that cycle is deliberate.
- **Typed failure models rendered at the edge**: `EngineFile.Validate`
  (`ErrorKind`, `LineError`, `LocItem`) and `Viewer.Cli.CliAction`.
- **Tooling that keeps claims honest.** `scripts/upstream-python` is the
  single place the reference Python version is pinned, with the reason.
  `scripts/bench` executes the rerun block inside each `RESULTS.md`, so the
  documented commands cannot drift from what runs. `scripts/lint-skips`
  turns "a missing reference fails, never skips" into a check.
  `scripts/with-postgres` gives a throwaway server either with initdb or
  with Docker. `check-all` is short and readable, and it is what CI runs.
- **Consistent toolchain**: hspec, QuickCheck and tasty-bench everywhere;
  GHC2024; one warning set; a freeze file.
- **Rationale written where the code is.** The RTS defaults of the viewer
  executables, the HTTP front and the relay loop each say why at the top of
  the file, with the measurements in `bench/RESULTS.md`.
- **The docs give a newcomer a clear path**: README (aims, layout, four
  commands), then `docs/reproducing.md` (prerequisites through parity), with
  SCOPE, UPSTREAM and PARITY each holding one concern.
