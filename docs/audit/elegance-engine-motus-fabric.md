# Elegance audit: Engine, motus and Fabric

This audit covers design quality on local `main` at `8d08f99`. It was done on
2026-10-11.

The slice is:

- `petrus-engine`, plus the `petrus-engine-sqlite`, `petrus-engine-postgres`
  and `petrus-engine-absurd` backends;
- `petrus-motus`, `petrus-motus-absurd` and `petrus-motus-zeromq`;
- `petrus-activity`, `petrus-execution`, `petrus-fabric` and
  `petrus-processes`.

For each package the audit covers `src`, `test`, `bench`, the cabal file and
`DIVERGENCES.md`.

The question here is: *is this the better Haskell shape for the same
behaviour?* Accuracy is out of scope. It was audited separately in
`docs/audit/engines-motus-fabric.md`, and this audit does not repeat it. One
finding (ELG-E-1) came out of the design review but is also a parity defect.
It is flagged for the owners of the accuracy audit.

Method: I read every module in the slice, the test layout, the cabal files and
each `DIVERGENCES.md`. Where a design question depended on upstream behaviour,
I checked it against the upstream sources at the pin. Nothing was built or run
(the machine was busy). Every suggested change below keeps wire formats and
observable behaviour identical, except the ELG-E-1 fix, which restores
behaviour.

Severity scale:

- **major**: a design problem that already causes, or invites, a defect, or
  that a reviewer would ask to fix before calling the port idiomatic.
- **minor**: polish. Worth doing when the code is next touched.

## Findings, ranked by impact

### ELG-E-1 (major): Python exception classes are named in five places, inconsistently

**Evidence**

The port has no single function that answers "what Python class name and
repr does this exception carry?". Each site answers it on its own:

| Site | How it spells the exception |
|---|---|
| `petrus-motus/src/Petrus/Motus/Dispatch/Inline.hs:116-123` | Special-cases `DispatchError` as `"ValueError"`, else `exceptionTypeName`. |
| `petrus-engine/src/Petrus/Engine/Vocabulary.hs:92-100` | Special-cases `DispatchError` as `"ValueError(" <> pyStr m <> ")"`. |
| `petrus-motus-zeromq/src/Petrus/Motus/Transport/ZeroMQ/Server.hs:409-417` | Special-cases `DispatchError` as `"ValueError"`. |
| `petrus-motus/src/Petrus/Motus/Dispatch/Local.hs:693` (`fail`) | No special case: `exceptionRepr err` / `exceptionTypeName err`. |
| `petrus-motus-zeromq/src/Petrus/Motus/Transport/ZeroMQ/Wire.hs:333-338` (`classifiedFailure`) | No special case. |
| `petrus-motus-absurd/src/Petrus/Motus/Dispatch/Absurd.hs:598` (`guardedTerminal`) | No special case. |

**What goes wrong**

`exceptionTypeName` is `T.pack (show (typeOf e))`
(`petrus-motus/src/Petrus/Motus/Internal/Repr.hs:53-54`). That has two
consequences:

1. The three sites without a special case durably record the port's own
   `DispatchError` as kind `"DispatchError"` with repr `DispatchError ...`.
   Upstream records `"ValueError"`:
   - `upstream/petrus/src/petrus/motus/dispatch/local.py:387-394` uses
     `type(error).__name__` and `repr(error)`;
   - the reference raises `ValueError` from the heartbeat-details snapshot
     (`local.py:358`, `worker/__init__.py:251`), and that error reaches
     `fail`.

   This is a stored-data parity defect. The accuracy audit missed it.
2. A Haskell type's *name* becomes wire data. If an exception type is renamed,
   wrapped in a parameterised type, or moved, the stored `kind` changes
   silently.

The Python-named newtypes in `petrus-motus/src/Petrus/Motus/Worker.hs:106-131`
and `petrus-motus-zeromq/.../Errors.hs` exist only to make `typeOf` print the
right word. Correctness then depends on how the types happen to be named.

**Better shape**

Make the class name an explicit, total mapping, the same way `petrus-fabric`
does with `pythonExceptionName` and `petrus-execution` does with `ErrorKind`.
Define it once, in `Petrus.Motus.Internal.Repr` (or `Petrus.Motus.Dispatch`):

```haskell
-- | The Python class and repr the reference would record for this exception.
data PythonException = PythonException { className :: Text, message :: Text }

pythonException :: SomeException -> PythonException
pythonException e
  | Just (DispatchError m) <- fromException e = PythonException "ValueError" m
  -- ... one line per Python-named error the port raises
  --     (the Worker.hs and ZeroMQ Errors.hs newtypes)
  | otherwise = PythonException (fallbackName e) (exceptionMessage e)

pythonRepr :: PythonException -> Text   -- "ValueError('...')"
```

Then:

- Inline, Vocabulary, Server, Local `fail`, Wire and Absurd all call
  `pythonException`;
- the per-site special cases are deleted;
- the newtypes keep their names for Haskell readers, but no longer carry the
  wire spelling.

**Cost and risk**

- Churn: low (about 60 lines; six call sites and one new function).
- Wire risk: the change is the fix. It brings the three wrong sites to the
  reference spelling, and the other three are unchanged. Add one golden test:
  a heartbeat-details failure through `Local` stores kind `ValueError`.

### ELG-E-2 (major): Python text shims are duplicated, and one copy is wrong

**Evidence**

`petrus-json` already has `Petrus.Json.PythonText.pythonStrRepr`
(`packages/petrus-json/src/Petrus/Json/PythonText.hs:43`). It is the canonical
table for CPython 3.14 `repr(str)`. Alongside it, the slice has its own
copies:

- **`repr` / printable:**
  - `petrus-motus/src/Petrus/Motus/Internal/Repr.hs:41` uses GHC `isPrint`,
    which differs from Python's `str.isprintable`. Python escapes `Zs` other
    than U+0020 (for example U+00A0 becomes `'\xa0'`); GHC `isPrint` prints
    it raw. This copy is **wrong** for non-ASCII spaces.
  - `petrus-motus-absurd/src/Petrus/Motus/Dispatch/Absurd.hs:1492` has its own
    `pyRepr`.
  - `petrus-execution/src/Petrus/Motus/Execution/Internal/PyText.hs:140-200`
    has `pyStrRepr`, `pyIsPrintable` and `pyIsSpace`.
- **`uuid4`:**
  - `Repr.hs:72` (getentropy);
  - `Absurd.hs:1510` (`/dev/urandom`);
  - `petrus-execution/.../Internal/Common.hs:136-151`.
- **Python whitespace:** `petrus-motus-zeromq/.../Wire.hs:430-433`
  (`pyStrip`) and `PyText.hs:199`.
- **JSON-error emulators:** `petrus-motus-zeromq/.../PythonDecode.hs`, next to
  the decode-error text in `petrus-json`.

**What goes wrong**

Each copy is a small re-implementation of one CPython rule. They drift: the
motus `pyStr` is wrong where the `petrus-json` and execution copies are right.
Every fix has to be made four times.

**Better shape**

- Make `petrus-json` (`Petrus.Json.PythonText`) the single home for
  `pythonStrRepr`, `pythonIsPrintable`, `pythonIsSpace`, `pythonStrip` and the
  JSON value repr.
- Re-export or call these from `Petrus.Motus.Internal.Repr`, and delete the
  copies in Absurd, execution `PyText` and Wire.
- Move `uuid4` into one module (`petrus-posix` already owns getentropy-style
  OS access, or it can stay in `Repr`) and delete the other two.
- Keep `PythonDecode` only if `petrus-json` cannot give the same error text.
  Otherwise fold it in.

**Cost and risk**

- Churn: medium, mostly deletion (about 300 lines removed).
- Wire risk: none, except that motus reprs of non-ASCII spaces become
  correct. Pin that with one property test:
  `pyStr == pythonStrRepr` over arbitrary `Text`.

### ELG-E-3 (minor, bordering on major): the `ActivityInvocation` codec exists three times

**Evidence**

| Package and module | `encodeInvocation` | `decodeInvocation` |
|---|---|---|
| `petrus-motus`, `Dispatch/Local.hs` | `:1204` | `:1233` |
| `petrus-motus-absurd`, `Dispatch/Absurd.hs` | `:234` | `:269` |
| `petrus-motus-zeromq`, `Wire.hs` | `:215` | `:242` |

`petrus-activity` already exports `invocationJson` and `policyJson`, the
canonical encoders, and all three `encodeInvocation` copies rebuild the same
object.

**What goes wrong**

Three hand-maintained copies of one shape. A new field in
`ActivityInvocation` has to be added in four places, and nothing fails if one
is missed.

**Better shape**

- Each `encodeInvocation` becomes `invocationJson`, plus the backend's framing
  if any.
- Add one `invocationFromJson :: Json -> Either Text ActivityInvocation` to
  `Petrus.Activity`, next to `invocationJson`.
- Each backend maps the error into its own type (`WireError`, a "corrupt
  durable Activity invocation" prefix, and so on).

**Cost and risk**

- Churn: low (about 150 lines removed).
- Wire risk: none. Add a round-trip property `invocationFromJson .
  invocationJson == Right` in `petrus-activity` (see ELG-E-11).

### ELG-E-4 (minor): Engine state is a bag of `IORef`s, and `completeAccepted` exists twice with different semantics

**Evidence: the Engine record**

`petrus-engine/src/Petrus/Engine/Internal.hs:181-194`. The Engine record
carries:

- `holder`, `writer :: IORef (Maybe ThreadId)`;
- `resourcesClosed`, `closed :: IORef Bool`;
- `broken :: IORef (Maybe Text)`.

**Evidence: the Coordinator**

`petrus-engine/src/Petrus/Engine/Coordinator.hs` has the same pattern:

- `offer`, `arrived`, `deliveries`, `dispatched`, `reconciled` and `previous`
  are each an `IORef`;
- `apply` (`:405`) returns `(Maybe (IO ()), Bool)` and appends to an `IORef
  (Seq FiringOutcome)` passed in from outside.

**Evidence: the two `completeAccepted`**

| Copy | Behaviour |
|---|---|
| `Internal.hs:414-424` | Uses `onException`, so it acts on every exception, async ones included. |
| `Coordinator.hs:495-506` | Catches only synchronous exceptions and lets async ones pass. |

The Coordinator copy matches upstream `except Exception:` at
`engine/__init__.py:449-462`; the `Internal.hs` copy does not.

**Smaller points**

- `instanceToEngine` (`Coordinator.hs:553`) duplicates
  `Vocabulary.throwInstanceError`.
- `completePure` is exported but used only internally.

**What goes wrong**

- Several `Bool`/`Maybe` flags encode one lifecycle: open, broken, closing,
  closed. Nothing stops impossible combinations, such as `closed = True` while
  `broken = Nothing` and `resourcesClosed = False` mid-close.
- The `(Maybe (IO ()), Bool)` return of `apply` gives the reader no names.
- Two copies of the commit-point logic have already diverged on async
  exceptions.

**Better shape**

The engine lifecycle becomes one sum:

```haskell
data Lifecycle = Open | Broken Text | Closing | Closed
-- one IORef Lifecycle (or TVar), replacing broken/closed/resourcesClosed

data Applied = Applied { deferred :: Maybe (IO ()), progressed :: Bool }
apply :: Coordinator -> Action -> Span -> IO (Applied, Seq FiringOutcome)
```

Then:

- keep a single `completeAccepted`, the Coordinator's async-aware one, and
  have `Internal` call it;
- delete `instanceToEngine` in favour of the Vocabulary mapping;
- stop exporting `completePure`.

**Cost and risk**

- Churn: low to medium (Engine internals only).
- Wire risk: none. The single change in behaviour is that `Internal.hs` stops
  acting on async exceptions at the commit point, which is the reference
  behaviour.

### ELG-E-5 (minor): `HistoryStore.mode` is never consulted

**Evidence**

`openEngine` (`petrus-engine/src/Petrus/Engine/Internal.hs`) never reads
`store.mode` (`CommitMode = BackendOwned | JoinedTransaction`). The pairing of
mode and `resources.commit` is enforced only by convention.
`petrus-engine/DIVERGENCES.md` item 10 admits this ("the joined pairing is not
inspected").

**Better shape**

Make the check one case at `openEngine`:

```haskell
case (store.mode, resources.commit) of
  (JoinedTransaction, Nothing) -> throwIO (EngineValueError "joined store needs a commit point")
  (BackendOwned, Just _)       -> throwIO (EngineValueError "backend-owned store must not take a commit point")
  _ -> pure ()
```

Use the reference's message if upstream has one. Otherwise this is a
port-only guard: record it in DIVERGENCES, or drop the `mode` field as dead.

**Cost and risk**

- Churn: trivial.
- Wire risk: none. Every shipped backend already pairs these correctly.

### ELG-E-6 (minor): Absurd custody rows are untyped tuples with state strings

**Evidence**

`petrus-motus-absurd/src/Petrus/Motus/Dispatch/Absurd.hs`:

- `:1102` defines `type Custody = (Text, Text, Text, Maybe Text, Maybe Text,
  Maybe Text)`.
- Task states are compared as strings throughout. Examples:
  - `"cancelled"` at `:1131`, `:1140`, `:1242` and `:1243`;
  - `["completed", "failed"]` at `:1159` and `:1258`;
  - `"pending"` at `:1165`;
  - `Just "running"` / `Just "t"` at `:692` and `:730`;
  - the case arms at `:1360-1371`.
- `guardedTerminal` (`:592-640`) threads a `Maybe` triple through a
  catch-all.

`Dispatch/Local.hs` has the same issue: it reads rows positionally (`row !! 6`
at `:655`, `row !! 5` at `:662`).

**What goes wrong**

- A misspelt state string compiles.
- A column reorder compiles.
- `!!` is partial.

**Better shape**

```haskell
data TaskState = Pending | Running | Sleeping | Completed | Failed | Cancelled
taskStateFromText :: Text -> Either Text TaskState

data Custody = Custody { queue, taskId, runId :: Text, state :: TaskState, ... }
```

- Decode each row once at the query boundary. Pattern-match on the row list
  (`[a, b, c, ...]`) instead of using `!!`.
- `guardedTerminal` returns `Either Refusal Report`.

**Cost and risk**

- Churn: medium (one module).
- Wire risk: none. The SQL text and the stored strings are unchanged.

### ELG-E-7 (minor): ZeroMQ test seams are mutable `replace*` functions

**Evidence**

`petrus-motus-zeromq/src/Petrus/Motus/Transport/ZeroMQ/Client.hs:296-418`:

- `replaceSocketFactory`, `replaceAccessSocketFactory` and
  `replaceAccessSocketOpener` write into `IORef` fields of live clients;
- `replaceConnection` (`Absurd.hs:802`) does the same in motus-absurd.

The ZeroMQ tests (`TransportSpec` 246-307) call the `replace*` functions right
after construction. So the mutability is never needed at run time.

**Better shape**

Put the seams in the construction options record, as `petrus-execution` and
the Engine provider seam already do:

```haskell
data ClientOptions = ClientOptions { ..., socketFactory :: SocketFactory, opener :: Maybe (IO RpcSocket) }
defaultClientOptions :: ClientOptions
```

The `IORef` fields and the `replace*` exports then go away.
`replaceConnection` is a real reconnect, not a test seam, so keep it.

**Cost and risk**

- Churn: low (the client constructors and about 6 test call sites).
- Wire risk: none.

### ELG-E-8 (minor): some smart constructors can be bypassed

**Evidence**

`petrus-activity/src/Petrus/Activity.hs` exports `ActivityInvocation (..)`,
so `activityInvocation`'s validation can be bypassed by direct construction or
by record update.

`petrus-motus/src/Petrus/Motus/Dispatch.hs` exports the field labels of
`CancellationInstruction` and `ActivityAttempt`. `Delivery` in
`Petrus.Engine.Vocabulary` does the same. Exported field labels allow record
update after construction.

`petrus-fabric` (`Model.hs`) and `petrus-processes` already solve this: an
abstract type plus `HasField` instances, so dot-access works and record
update is impossible.

**Better shape**

- Apply the Fabric pattern to `ActivityInvocation`.
- `RetryPolicy`, `ExecutionPolicy` and `ActivityFailure` already have smart
  constructors; check that they follow it too.
- For `Delivery`, `CancellationInstruction` and `ActivityAttempt`: these carry
  no invariant, so exporting their labels is fine. Leave them alone.

**Cost and risk**

- Churn: low.
- Wire risk: none.

### ELG-E-9 (minor): a placeholder `error` Dispatch, and overlapping session records

**Evidence**

`petrus-engine-absurd/src/Petrus/Engine/Absurd.hs:169,188-189` passes

```haskell
unused = error "Petrus.Engine.Absurd: the Absurd composition supplies its own Dispatch"
```

into `joinedProvider`. Three records describe nearly the same shape: a
connection plus a transaction scope:

- `PostgresSession` (engine-postgres);
- `AbsurdSession` (engine-absurd);
- `JoinedProvider` (engine-postgres `Postgres/Joined.hs`).

**What goes wrong**

The type promises a `Dispatch` that the composition never wants, and the
`error` stands in for it. If a refactor ever forces it, the failure is a
runtime crash.

**Better shape**

Split `joinedProvider` so the `Dispatch` is supplied at the `EngineResources`
step (`joinedResources :: Connection -> JoinedProvider`, then
`withDispatch`). Alternatively, take `Maybe Dispatch`. Then
`AbsurdSession` can reuse `JoinedProvider` instead of restating it.

**Cost and risk**

- Churn: trivial to low.
- Wire risk: none.

### ELG-E-10 (minor): `petrus-execution` re-implements `petrus-posix`

**Evidence**

`petrus-execution/src/Petrus/Motus/Execution/Internal/Posix.hs` has its own
`flock`, `fsync`, atomic write and `realpath`. `packages/petrus-posix` now
ships the same operations in its `Flock`, `File` and `Path` modules.

`petrus-execution/DIVERGENCES.md` justifies the local copy with "not yet on
main". That rationale is stale.

**Better shape**

Depend on `petrus-posix`, delete `Internal/Posix.hs`, and update the
DIVERGENCES entry.

**Cost and risk**

- Churn: medium (several call sites; error texts must stay identical, so check
  that the two modules spell errno messages the same way).
- Wire risk: none, if the message check passes.

### ELG-E-11 (minor, tests only): almost no properties where they are natural

**Evidence**

The slice's tests are almost all example-based ports of upstream tests.
QuickCheck is barely used, yet there are obvious laws:

- `invocationFromJson . invocationJson` and `policyJson` round-trip
  (`petrus-activity`);
- the ZeroMQ `Wire` encode/decode round-trip;
- `chooseConservative` and `chooseThroughput` in `Petrus.Engine.Vocabulary`.
  These are pure, which is good, and at least one law is obvious: the choice
  is always drawn from the offered bindings;
- `pyStr` agrees with `pythonStrRepr` (ELG-E-2).

A shared Dispatch contract suite would also help. Today inline, in-memory,
Local, Absurd and ZeroMQ are each tested separately for the same port
semantics: dispatch, collect, cancel, exactly-once completion. A single
`dispatchContract :: IO Dispatch -> Spec` run against each backend would make
the port's laws explicit.

**Cost and risk**

- Churn: test-only.
- Wire risk: none.

### ELG-E-12 (minor, cabal only): test suites compile other packages' test directories

**Evidence**

These test stanzas pull in other packages' test trees through
`hs-source-dirs`:

| Cabal file | Lines | Extra test trees |
|---|---|---|
| `petrus-engine/petrus-engine.cabal` | `:56`, `:95` | `../petrus-impetus/test`, `../petrus-history-store/test`, `../petrus-motus/test` |
| `petrus-engine-sqlite/petrus-engine-sqlite.cabal` | `:49`, `:82` | `../petrus-impetus/test`, `../petrus-engine/test`, `../petrus-motus/test` |
| `petrus-engine-postgres/petrus-engine-postgres.cabal` | `:56` | `../petrus-impetus/test`, `../petrus-engine/test`, `../petrus-history-postgres/test` |
| `petrus-processes/petrus-processes.cabal` | `:112` | `../petrus-fabric/test` |

**What goes wrong**

- The same modules are compiled again in every suite.
- The dependency is invisible to cabal.
- An `sdist` of any of these packages is broken.

**Better shape**

Each package that shares fixtures exposes a
`library <pkg>-test-support` sublibrary (`visibility: public`). Consumers
list it in `build-depends`. Fabric already uses a sublibrary
(`petrus-fabric:engine`), so the pattern is established in the repo.

**Cost and risk**

- Churn: cabal plus module moves. No code logic changes.
- Wire risk: none.

## Smaller notes (no finding)

These were weighed and deliberately not raised as findings:

- `stdoutLock = unsafePerformIO (newMVar ())`
  (`petrus-motus/src/Petrus/Motus/Worker.hs:153-155`). It has `NOINLINE`, and
  stdout is a process global. This is the accepted idiom.
- The sync bridge in `Worker` indexes lanes with `lanes !! slot`. The slot is
  always in range by construction. A `Data.Vector` or `Seq` lookup would be
  tidier but this is not worth a finding.
- `bigint` in `Local.hs:1458` uses `throw` in pure code to report
  integer-too-large. It is caught at the single row-write boundary.
  An `Either` would be cleaner, but this is borderline.
- `guarded` in `Internal.hs:329-342` poisons the engine on any
  `SomeException`, async ones included. Poisoning on cancellation mid-write
  is the conservative choice for a durable engine, so I left it alone.
  Whether it matches the reference exactly is a question for the accuracy
  audit.
- The worker's `absorbing`/`owned` forks (`Worker.hs:373-394`) and
  `coordinate` (`:489-545`) are careful, correct uses of `forkIOWithUnmask`.
  They read as idiomatic Haskell, not as a transliteration.

## DIVERGENCES review

| Package | Verdict |
|---|---|
| `petrus-engine` | Sound. Item 10 (joined pairing not inspected) is honest, but the fix is trivial; see ELG-E-5. |
| `petrus-engine-sqlite`, `-postgres`, `-absurd` | Sound. Short and accurate. |
| `petrus-motus` | Mostly sound and very thorough. Items 4, 12 and 23 each describe the `DispatchError`↔`ValueError` mapping slightly differently, and none says that `Local` `fail` does not apply it (ELG-E-1). Consolidate these into one entry once the fix lands. |
| `petrus-motus-absurd`, `petrus-motus-zeromq` | Sound. |
| `petrus-activity` | Sound. |
| `petrus-execution` | The `Internal/Posix` rationale ("petrus-posix not yet on main") is stale (ELG-E-10). The others are sound. |
| `petrus-fabric`, `petrus-processes` | Sound and well argued. The `HasField` design note is a model for the rest of the repo. |

## What is exemplary

- **`petrus-fabric` and `petrus-processes`.** Both use abstract models with
  `HasField` accessors. The `FabricError` category sum carries an explicit
  `pythonExceptionName`. The Engine-dependent part lives in a public
  sublibrary (`petrus-fabric:engine`). This is the shape the rest of the
  slice should converge on.
- **`petrus-execution` errors and invariants.** The `ErrorKind` sum, smart
  constructors and the `EnvironmentProvider` record of functions give clean,
  explicit Python-class mapping. ELG-E-1 asks motus to copy this.
- **The `Dispatch` / `WorkerDispatch` / `WorkerAccess` ports.** Records of IO
  functions are the right Haskell rendering of the reference protocols. The
  optional capabilities are `Maybe` fields, not runtime `hasattr` emulation.
- **The Engine provider seam.** `EngineResources` together with
  `JoinedProvider` makes backend composition (SQLite, Postgres, joined
  Postgres, Absurd) a value-level choice with no type-class machinery.
- **Pure scheduling policies.** `chooseConservative` and `chooseThroughput`
  are plain functions, cleanly separated from effects. `EngineSelection` is a
  small, justified existential.
- **The Worker CLI.** The arguments and outcomes are sum types, not stringly
  flags.

## Verdict: passes with changes

The slice is idiomatic in its architecture:

- ports as records of functions;
- pure policies;
- explicit error sums in Fabric and Execution;
- careful asynchronous-exception handling.

It does not read as a line-by-line transliteration.

Two things keep it from a clean pass:

- **ELG-E-1.** The Python exception class is derived from Haskell type names
  and mapped ad hoc at six sites. That has already produced a stored-data
  divergence (`"DispatchError"` where the reference writes `"ValueError"`).
- **ELG-E-2.** Python text and UUID shims are duplicated across four
  packages, and one copy (motus `pyStr`) is wrong.

Both fixes are low to medium churn and mostly delete code. With them, the
slice passes.

ELG-E-3 to ELG-E-12 are polish and can be scheduled freely. None of them
changes a wire format.
