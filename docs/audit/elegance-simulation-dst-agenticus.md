# Elegance audit: simulation, observation, HTTP core, DST, telemetry, agenticus

Design-quality review of the Haskell code in this slice, against the goal's "better the Haskell
way" outcome: where Haskell can make a part clearly better than a direct translation (safer,
simpler, more correct, more composable or faster), the port should do it, decided case by case.
Accuracy (parity, interop, performance) was audited separately in
[`simulation-dst-telemetry-agenticus.md`](simulation-dst-telemetry-agenticus.md) and is not
repeated here. Findings already listed there (SDA-*), in particular the DST checker
`unsafePerformIO` (SDA-9) and the shared-sidecar tests (SDA-6), are referenced, not repeated.

Packages: `petrus-simulation`, `petrus-observation`, `petrus-observation-http`,
`petrus-http-core`, `petrus-dst` (with `engine-worlds` and `joined-worlds`), `petrus-telemetry`,
`petrus-telemetry-instrumentation`, `petrus-agenticus-core`, `petrus-agenticus`,
`petrus-agenticus-runtime`, `petrus-test-support`: their `src`, test, bench, cabal and
DIVERGENCES files. About 84,000 lines in all.

Local `main` at `3bfb6c9`. Read-only review, 2026-10-11. Nothing was built or run; the claims
below come from reading the code. Line numbers refer to that commit.

## Verdict: passes with changes

The semantic core of the slice is idiomatic Haskell. In several places it is clearly better than
the reference:

- The observation projections are pure, and the effect is one `capture` (`Petrus.Observation`).
- The DST World is a deterministic state machine in `WorldT m g` over a `Profile m g` record.
- Thread and Episode transitions are pure `Either` functions over newtype identities.
- Simulation admission is a pure `Either`.
- The HTTP core's accept loop wakes through STM.
- Secrets are held in `ScrubbedBytes`.
- Payloads are float-free `PayloadValue`s.

The DIVERGENCES files are thorough and give a reason for almost every entry.

The provider-runtime layer is different. It is `petrus-agenticus-runtime`, about 15,000 lines of
source. It is mostly a transliteration of the reference's per-host modules, and three things
follow from that:

- **Duplicated plumbing.** The operation lifecycle and the helper-subprocess plumbing are
  copied, nearly word for word, into five host modules (ELG-S-1, ELG-S-2).
- **Python-shaped seams.** Python monkeypatching and attribute assignment became mutable setters
  in the public API (ELG-S-5).
- **Hidden process-global state.** It appears where an explicit resource or a refined type would
  do (ELG-S-6).

Separately, the Python `repr(str)` algorithm is copied in two places with a Unicode predicate
that petrus-json itself documents as wrong. This is a latent correctness trap, not only
duplication (ELG-S-3).

None of the findings needs a wire, schema, History or refusal change. Each is a refactor behind
the existing differential suites, which pin the bytes. That is why the verdict is "passes with
changes" and not "does not pass": the design faults are confined, mechanical to fix, and do not
compromise the semantics. But they are real. ELG-S-1 to ELG-S-3 should be fixed before calling
the slice done on the elegance side.

## Findings

Ranked by impact. "Churn" counts lines touched, roughly. "Wire risk" is the risk of changing any
byte the differential suites pin. For every finding it is none, by construction.

| ID | Severity | Area | Summary |
| --- | --- | --- | --- |
| ELG-S-1 | major | agenticus-runtime | The operation lifecycle (`wait`, `cancel`, `close` and the phase flags) is copied across five hosts. Four Bool and Maybe `TVar`s under an `MVar` encode one phase. |
| ELG-S-2 | major | agenticus-runtime | Helper-subprocess plumbing is copied five times. Generic process and custody pieces live in, and are named after, the Pi adapter. `trySync` is defined six times. |
| ELG-S-3 | major | dst, agenticus-core, agenticus-runtime | Python `repr` and `json.detect_encoding` are reimplemented outside petrus-json. Two `repr(str)` copies use GHC's Unicode 15.1 tables, not CPython 3.14's (16.0). |
| ELG-S-4 | minor | dst worlds | Helpers are copied across the world modules (`strs` ×9, `path` ×6, `effectful` ×5, counting bridge ×4). `unsafePerformIO` is not confined to one place. Direction for SDA-9. |
| ELG-S-5 | minor | agenticus-runtime | Test monkeypatching became mutable setters on production values (`setRunnerRepository`, `setAdapterConfig`, `configRef`, …). |
| ELG-S-6 | minor | agenticus-runtime, agenticus-core | Hidden process-global state: the shared-sidecar registry and the custody validation cache, both via `unsafePerformIO`. |
| ELG-S-7 | minor | telemetry | `newSpan`/`runSpan` make an unstarted span representable only to reproduce `SpanNotStarted`. |
| ELG-S-8 | minor | simulation | Expected outcomes take an exception round trip. An `IORef` holds what is loop state. Admission uses `MVar Bool` + `TVar Bool`. Bounds are hard-coded twice. |
| ELG-S-9 | minor | agenticus-runtime, agenticus-core | Closed vocabularies are `Text` (`territoryProfile`, application `profile`, Amp `mode`/`visibility`). Custody takes positional `Text` identifiers. |
| ELG-S-10 | minor | tests | Corpora load through `unsafePerformIO`. JSON-navigation and raw-HTTP helpers are copied per suite. Pure state machines lack invariant properties. |
| ELG-S-11 | minor | dst, agenticus-runtime | Children are not cleaned up on interruption (`runProcessScenario`, `runBounded`). Raw `forkIO` threads are not linked to their owner. |
| ELG-S-12 | minor | packaging, docs | Stale runtime cabal description. Internals are exported from public modules. Two telemetry DIVERGENCES entries lack a reason. |

---

### ELG-S-1 (major): one operation lifecycle, copied into five hosts

**Evidence.** The operation record carries the same seven-field state cluster in three hosts:
`monitor :: MVar ()`, `cancelled`, `publishing`, `result`, `cleanupDisposition`, `cleanup` and
`finished`.

- `Pi.hs:1472-1485`
- `Claude.hs:1161-1174`
- `Codex.hs:699-713`

`PiApplication.hs:927-940` has the same cluster, and `Amp.hs:787-807` has a variant of it. The
operations built on it are copies that differ only in a label, a grace period and one
exception-tolerance rule:

| Host | `wait` | `cancel` | `close` |
| --- | --- | --- | --- |
| Pi | `Pi.hs:1557` | `:1573` | `:1594` |
| Claude | `Claude.hs:1247` | `:1263` | `:1279` |
| Codex | `Codex.hs:790` | `:806` | `:823` |
| Pi application | `PiApplication.hs:1004` | `:1020` | `:1041` |
| Amp | `Amp.hs:920` | `:933` | `:947` |

The `close` bodies of Pi, Claude, Codex and Pi application are character-identical except for
the grace expression.

**What's wrong.**

- **Duplication.** About 100 lines per host are the same protocol, so any fix has to be made five
  times. The upstream modules duplicate it too, but a direct translation of that duplication is
  exactly what the goal asks the port to improve on.
- **Bool flags for a sum type.** The operation's phase is spread over several flags: `result`
  (`Maybe`), `cancelled`, `publishing`, `finished` and `cleanupDisposition`. Each check reads
  them one at a time with `readTVarIO` under an `MVar` monitor. So the impossible combinations
  can be represented: settled and publishing; finished without a disposition. Only the monitor
  discipline keeps the reads coherent.
- **The better shape is already in the repo.** `PiRecovery.hs:107` models its phase as a sum type
  (`PiOperationPhase = PhaseExecuting | PhaseSettled`).

**Better shape.** Give all hosts one lifecycle core, with one `TVar` per fact and the transitions
in STM:

```haskell
-- Petrus.Agenticus.Runtime.Lifecycle (new; or beside core's Runtime.Operation)
data Phase
  = Running
  | CancelRequested
  | Publishing
  | Settled RuntimeTurnSettlement

data Lifecycle = Lifecycle
  { operationId :: Text
  , labels      :: Labels                                      -- per-host message texts
  , phase       :: TVar Phase
  , finished    :: TVar (Maybe RuntimeCleanupDisposition)      -- replaces finished + cleanupDisposition
  , cleanup     :: TVar (Maybe RuntimeOperationCleanup)
  }

waitLifecycle   :: Lifecycle -> Maybe Timeout -> IO RuntimeTurnSettlement
cancelLifecycle :: Lifecycle -> (Text -> IO ()) -> Text -> IO CancellationDisposition
closeLifecycle  :: Lifecycle -> Double -> (RuntimeCleanupDisposition -> Text) -> IO RuntimeOperationCleanup
claimPublication :: Lifecycle -> STM Bool        -- Running -> Publishing, else False
```

How the per-host differences fit:

- The host-specific messages become `Labels`. `"Pi operation has not settled"` and
  `"Codex runtime operation has not settled"` differ in text only.
- Codex's cancel tolerates only `EpisodeAttachmentError`, where the others swallow every
  synchronous exception. That rule is the `Text -> IO ()` the host passes in.
- Amp's extra facts (`sdkStarted`, `providerTerminal`, `worker`) stay in Amp's own record, next to
  a `Lifecycle`.
- A `Timeout` smart constructor replaces the five copies of the positive-and-finite check.

**Churn.** About 450 lines removed across five modules, plus one new module of about 150 lines.

**Wire risk.** None. The messages and codes are the parameters, and the per-host specs pin them.

### ELG-S-2 (major): helper-subprocess plumbing copied five times; generic pieces housed in Pi

**Evidence.**

- **Spawning.** Five functions repeat the same spawn: `createProcess` with `new_session`,
  `close_fds`, binary mode and block buffering, then a stderr drainer thread with a done `TVar`
  and a stdout reader thread into a `TQueue (Maybe ByteString)`.
  - `Pi.newSubprocessClientWith` (`Pi.hs:1110-1172`)
  - `PiApplication.newApplicationSubprocessClientWith` (`PiApplication.hs:640-712`)
  - `PiModelPhase.newPhaseSubprocessClient` (`PiModelPhase.hs:387-420`)
  - `HostSupport.spawnSidecar` (`HostSupport.hs:190-232`)
  - `HostSupport.spawnShared` (`HostSupport.hs:381-437`)
- **The private-helper environment** (`HOME`, `PATH`, `LANG`, `LC_ALL`) is spelled out three
  times.
- **Closing.** Close stdin, wait for the grace period, `SIGKILL` the group, reap, then wait for the
  drain. This exists four times:
  - `closeSubprocess` (`Pi.hs:1441`)
  - `PiApplication.hs:901`
  - `PiModelPhase.hs:524`
  - `sidecarClose` (`HostSupport.hs:263`)

  Each guards idempotence with a non-atomic `readIORef` and `writeIORef` on a `closed` flag.
  `channelClose` (`HostSupport.hs:488`) does it correctly, with `atomicModifyIORef'`.
- **Line splitting.** `splitLines` (`HostSupport.hs:445`) and the local `splitComplete`
  (`HostSupport.hs:228`) are the same function.
- **Exception helpers.**
  - `trySync` is defined six times:
    - `Codex.hs:737`
    - `CodexGondolin.hs:311`
    - `PiA2Host.hs:360`
    - `AgentNetRunner.hs:583`
    - `Hands/Gateway.hs:496` (agenticus-core)
    - `Attachment/Binding.hs:212` (agenticus)
  - `isAsync` is defined twice: `Claude.hs:695`, `Codex.hs:733`.
  - `rethrowAsync` is defined twice: `Pi.hs:1588`, `PiApplication.hs:1035`.
- **Process helpers.** The generic ones (`waitExit`, `runBounded`, `micros`, `exitInt`,
  `removeRoot`) are exported from the Pi adapter under "Process pieces shared with the sibling Pi
  runtimes" (`Pi.hs:142-147`). Yet `HostSupport`, `Claude` and `Codex` import them. `HostSupport`
  depends on the Pi adapter for them (`HostSupport.hs:59`).
- **Custody seam.** The connection-custody seam that Claude and Codex use is Pi-named:
  `PiConnectionCustody`, `PiHome`, `PiMaterialization` (`Pi.hs:974-995`; imports at
  `Claude.hs:208`, `Codex.hs`).

**What's wrong.**

- Resource-lifecycle code is the code that most needs to be written once. Copies drift: one close
  is atomic and four are not.
- The module graph says that Claude and Codex depend on Pi. They do not: they depend on a process
  utility and a custody seam that happen to live there.
- No `async` is used anywhere. The runtime has 34 raw `forkIO` calls, so helper threads are not
  tied to the helper's lifetime (see also ELG-S-11).

**Better shape.**

1. `Petrus.Agenticus.Runtime.Process` holds the helper lifecycle:
   - `HelperSpec`
   - `spawnHelper :: HelperSpec -> IO (Either IOException Helper)`
   - `closeHelper :: Helper -> Double -> IO Bool`, idempotent through `atomicModifyIORef'`
   - `privateEnvironment`, `waitExit`, `runBounded`, `splitLines`

   The reader and drainer become `Async`s owned by the `Helper`. Each host keeps only its framing
   on top.
2. `Petrus.Agenticus.Runtime.Custody` holds the seam as `HostConnectionCustody`, `ProviderHome`
   and `HostMaterialization`. Type aliases in `Pi` keep the old names if they are wanted.
3. `trySync` and `isAsync` go in one place, `Petrus.Agenticus.Internal.Exception` in
   agenticus-core.

**Churn.** About 400 lines removed. Imports change in eight modules.

**Wire risk.** None. Frames, environment and signals are unchanged, and the protocol tests and
corpora pin them.

### ELG-S-3 (major): Python `repr` and `detect_encoding` reimplemented outside petrus-json, one copy subtly wrong

**Evidence.**

petrus-json already provides `Petrus.Json.PythonText.pythonStrRepr`. Its table comes from the
pinned CPython 3.14 (Unicode 16.0), and its test checks every code point. Its header says plainly
that "GHC's Data.Char follows the Unicode version GHC ships (15.1 for GHC 9.10) … so neither can
stand in for CPython's predicate" (`petrus-json/src/Petrus/Json/PythonText.hs:1-12`). Simulation
and telemetry use it.

Two packages carry their own copy instead, and both decide printability with
`Data.Char.generalCategory`:

- `petrus-dst/src/Petrus/Testing/Dst/PyRepr.hs:51-81`
- `petrus-agenticus-core/src/Petrus/Agenticus/Internal/PyRepr.hs:17-44`. Its header says it
  repeats the DST copy "so the core package does not depend on the DST harness". It does not
  mention petrus-json.

CI builds with GHC 9.10.3 (`.github/workflows/ci.yml:35`), whose tables are Unicode 15.1.

A Python-repr-of-JSON function is written three more times:

- `Petrus.Simulation.pythonRepr` (`Simulation.hs:213`)
- `AgentNetRunner.pythonRepr` (`AgentNetRunner.hs:216`)
- DST `jsonToPy`/`pyRepr` (`PyRepr.hs:84-93`)

CPython's `json.detect_encoding` plus decode is written twice:

- `Petrus.Testing.Dst.Internal.StrictJson.pythonDecodeBytes` (`StrictJson.hs:78`)
- `HostSupport.pyJsonLoadsBytes` (`HostSupport.hs:124`)

**What's wrong.**

- **The two copies are wrong for new characters.** Characters first assigned in Unicode 16.0 are
  `NotAssigned` to GHC 9.10, so the copies escape them, while CPython 3.14 prints them. One
  example is U+105C0, TODHRI LETTER A. This follows from the two Unicode versions; it was not
  run.
- **The divergence reaches observable text.** DST notes that some `repr` strings are "retained
  inside artifacts and covered by journal digests" (`PyRepr.hs:3-7`). Agenticus refusal messages
  embed `{value!r}` of identifiers and payload strings. No committed corpus contains such a
  character, which is why the suites pass.
- **The copies have no test.** Only the shared version has the every-code-point check.

**Better shape.** Delete both `pyStrRepr` copies and import `Petrus.Json.PythonText.pythonStrRepr`.
Then add two functions to petrus-json:

- `Petrus.Json.Repr.pythonJsonRepr :: Json -> Text`, which replaces the three Json-repr functions.
  DST's `PyObj` model stays for tuples and pydantic models, and its `PyStr` case calls the shared
  function.
- `pythonDecodeBytes :: ByteString -> Either Text Text` (the `detect_encoding` path, returning
  CPython's codec message). `HostSupport` keeps a one-line `Maybe` wrapper over it.

**Churn.** About 150 lines removed. Imports change in about 15 modules.

**Wire risk.** None for any input the corpora contain. The change removes a latent divergence for
Unicode-16 code points, so it improves accuracy.

### ELG-S-4 (minor): DST world helpers copied per module; `unsafePerformIO` not confined

**Evidence.** These helpers are copied across the `engine/` and `joined/` modules:

| Helper | Copies | Where |
| --- | --- | --- |
| `strs = Array . map String` | 9 | Delayed, Delivery, GeneratedRuntime, Lifecycle, Projection, Retry, Timer, Joined.Support, Joined.Identities |
| `path = either (error . T.unpack) id . netPath` | 6 | |
| `effectful = unsafePerformIO` with `NOINLINE` | 5 | `Retry.hs:312`, `Lifecycle.hs:239`, `GeneratedRuntime.hs:267`, `Projection.hs:416`, `Joined/World.hs:309` |
| counting `bridgeHandler` | 4 | `Retry.hs:285`, `Lifecycle.hs:224`, `GeneratedRuntime.hs:238`, `Projection.hs` |
| `listOf` | 3 | |
| `epochOf` | 2 | |

`Engine.Common` exists precisely to share this plumbing, and the copies bypass it. Each module
that copies `effectful` must also carry `-fno-full-laziness -fno-cse`.

**What's wrong.** The `unsafePerformIO` discipline is spread over five modules. Its correctness
depends on GHC flags and on the Engine forcing each handler result exactly once. An argument like
that should be made once, in one audited place.

**Better shape.**

- Move `strs`, `path`, `listOf` and `epochOf` to `Engine.Common`.
- Replace the four bridges with one counting handler. Then only `Common` needs the
  `OPTIONS_GHC` pragma:

  ```haskell
  countingHandler :: Bridge -> (Binding -> Either Text ActivityInvocation)
                  -> (Json -> Either Text HandlerResult) -> BoundHandler
  ```

**Direction for the in-flight SDA-9 work.**

- **Prefer a pure, state-threaded checker to an `m`-effectful one.** The one stateful checker,
  `newGeneratedRuntimeChecker` (`GeneratedRuntime.hs:867-875`), only carries a list of frozen
  counts from one check to the next. That is a Mealy machine. The World can thread it purely:

  ```haskell
  data Checker = forall s. Checker
    { identity :: CheckerIdentity, request :: ObservationRequest
    , initial :: s, check :: s -> Observation -> Either ProfileError (CheckResult, s) }
  ```

  This keeps "checkers are pure" true, so the DIVERGENCES entry becomes accurate instead of being
  deleted. It also keeps the World's verdicts independent of `m`.
- **The bridge counters are a separate problem.** They exist because `petrus-engine`'s
  `ActivityHandler` makes `prepare` and `project` pure. That is outside this slice. The clean
  fix is an observer hook on the Engine, called once per invocation. Until it exists, confine the
  workaround as described above.

**Churn.** About 150 lines removed. **Wire risk:** none (the authored journals pin the counts).

### ELG-S-5 (minor): test monkeypatching became mutable setters on production values

**Evidence.**

- **The runner.** `AgentNetRunner` keeps its repository in an `IORef` "for that test"
  (`AgentNetRunner.hs:597, 621-622`; `DIVERGENCES.md` item 2). The one use injects a failing
  `save` after two advances (`AgentNetRunnerSpec.hs:246`).
- **The Pi adapter.** It holds `configRef :: IORef PiRuntimeConfig` and `clockRef` and exports
  `setAdapterConfig`, `setAdapterClock`, `setAdapterHooks` and `modifyAdapterRuntime`
  (`Pi.hs:116-122, 1660-1711`). Every operation reads the configuration again
  (`readIORef o.adapter.configRef`, `Pi.hs:1605`).
- **The same pattern elsewhere:**
  - `PiApplication.hs:91-97`
  - `PiModelPhase.hs:53-56`
  - `setCodexHelperExecutable` and `setCodexStartWrapper` (`Codex.hs:90-91`)
  - `setSubprocessStartFrame`
  - `setClaudeReady`
  - `setPiA2HostHooks`

  Together that is 33 call sites in tests.

**What's wrong.** Python tests assign attributes, and the port turned each assignment into
mutable state on the production value. Adapter configuration becomes something that can change
under a running operation, and every read of it becomes `IO`. The DIVERGENCES elsewhere state the
right rule ("Test monkeypatching becomes a record override on a copy", agenticus-core
`DIVERGENCES.md`). These modules do not follow it.

**Better shape.** Fix configuration, clock and hooks at construction (`new*With` options records),
so the adapter's fields are plain values. Where a test needs a mid-run change, the switch belongs
in the test double, not in the runner or adapter. For example, a repository whose `save` reads a
test-owned `IORef Bool`:

```haskell
failing <- newIORef False
let repo = base { save = \e v -> readIORef failing >>= \f -> if f && isJust v.terminal then ioError … else base.save e v }
runner <- createRunnerWith repo …;  advance runner; advance runner;  writeIORef failing True
```

**Churn.** Moderate: about 12 setters removed and about 33 test sites adapted.

**Wire risk.** None.

### ELG-S-6 (minor): hidden process-global state where an explicit resource or a type would do

**Evidence.**

- **The sidecar registry.** `sharedSidecars = unsafePerformIO (newMVar Map.empty)`
  (`HostSupport.hs:339-341`) keys long-lived Python sidecars by command and environment. Nothing
  can shut them down; their reader threads are bare `forkIO`s (`HostSupport.hs:399-401`).
- **The validation cache.** `lastValidated = unsafePerformIO (newIORef Nothing)` holds a
  `StableName` of the last validated custody snapshot. It is process-wide and shared by every
  storage and thread (`Connection/Storage.hs:408-422`).

**What's wrong.**

- **The sidecar registry.** The reason given is that "the SDK is imported once per process". An
  explicit pool achieves that just as well, and it is closable. It is also isolatable: SDA-6's
  missing tests need exactly that (a private pool per test, killing the sidecar mid-Turn).
- **The validation cache.** It stands in for a type. Validation is pure, so the fact "this
  snapshot was validated" belongs in a refined type, not in a global cell.

**Better shape.**

- **Sidecars.** A `SidecarPool` value with `withSidecarPool` (bracket), passed in the Claude and
  Amp host configs. A `defaultSidecarPool` can keep today's convenience if it is wanted.
- **Snapshots.** `newtype ValidSnapshot = ValidSnapshot StorageSnapshot` (constructor hidden).
  `validateSnapshot :: StorageSnapshot -> Either AgenticusError ValidSnapshot`. The storage
  record's `load` and `compareAndSwap` traffic in `ValidSnapshot`, so the SQLite storage validates
  where it decodes, as upstream's `_decode` does. The `StableName` cache then disappears.
- **Telemetry's globals are fine.** `levelRef`, `routeRef` and `defaultSinkRef` are documented,
  justified by `capture`'s reach, and explicit sinks bypass them.

**Churn.** Small to moderate: about 120 lines.

**Wire risk.** None. The decode order and messages are unchanged, because validation runs at the
same point.

### ELG-S-7 (minor): an unstarted telemetry span is representable only to reproduce an error

**Evidence.** `newSpan` and `runSpan` are exported (`Telemetry.hs:418-443`) so that a `Span` can
exist before it starts. The start time is therefore `IORef (Maybe Double)` (`:410`), and
`spanElapsedMs` and `milestone` can throw `SpanNotStarted` (`:504-508`, `:615`). The only user is
the test that checks that error (`petrus-telemetry/test/Main.hs:172`). DIVERGENCES items 13 and 14
(`petrus-telemetry/DIVERGENCES.md:52-53`) state the choice without a reason.

**Better shape.** Export only `withSpan` and `withChildSpan`. The span is created started, so
`spanStartedAt :: Double`, and `SpanNotStarted` is gone: the invalid state cannot be represented.
Record it as a divergence with that reason, and drop the one test.

**Churn.** About 30 lines. **Wire risk:** none (no event changes).

### ELG-S-8 (minor): simulation control flow carries Python's exception shape

**Evidence.**

- **The runner.**
  - `run` signals profile refusals by throwing `ProfileAbort` (`Simulation.hs:457-463`).
  - It turns every `Either Text` into a thrown `userError` (`unexpected`, `:465-466`).
  - It catches everything back in `simulateWith` (`:447-454`).
  - It keeps the History byte tally in an `IORef` (`:487`, `:520-536`), although that tally is
    state of the `loop`.
- **The service.**
  - Admission is an `MVar Bool` plus a `TVar Bool` (`Http.hs:135-138`, `:358-368`), copying
    Python's lock around a flag.
  - `max_actions` is hard-coded as `256` (`Http.hs:354`), and the body limit as `"1048576"`
    (`:321-323`). Both duplicate `defaultBounds`, and the served profile is built from
    `defaultBounds`.

**Better shape.**

- **The runner.** Run it in `ExceptT SimulationError IO`, with the tally as a parameter of
  `loop`. The only `try` left is for the Engine's own exceptions.
- **Admission.** One `TVar Admission`, where `data Admission = Admission { shuttingDown, busy ::
  Bool }`, changed in one `atomically`.
- **The limits.** Read them from `defaultBounds`.

**Churn.** About 80 lines. **Wire risk:** none (same checks, order and messages).

### ELG-S-9 (minor): closed vocabularies and identifiers as `Text`

**Evidence.**

- **Closed vocabularies.**
  - `PiRuntimeConfig.territoryProfile :: Text` (`Pi.hs:757`) is checked against
    `["local", "gondolin", "e2b"]` (`:839`), then string-matched again (`:1681-1703`).
  - The application `profile` gets the same treatment (`PiApplication.hs:439, 1138`).
  - So do Amp's `mode` and `visibility` (`Amp.hs:385-387`).
- **Identifiers.** The custody API takes identifiers as positional `Text`:
  - `materialize :: … -> Text -> Text -> LeaseMode -> Double -> Text -> IO Materialization`
    (`Connection/Custody.hs:431`)
  - `enrollHost :: … -> Text -> Text -> IO ()` (`:337`)
  - `replaceAuthority`, with three `Text`s (`:753`)

  The same package already uses distinct newtypes for Thread identities (`Thread/Identity.hs:36-48`).

**What's wrong.** Swapping a connection id and a host id compiles. A typo in a profile literal
compiles. Elsewhere the port turns the same kind of runtime check into a type and documents it,
for example the telemetry `Level`, DST's `AuthoredDisposition` and `IndexAuthority`. Here it does
not.

**Better shape.**

- `data TerritoryProfile = TerritoryLocal | TerritoryGondolin | TerritoryE2b`, with
  `territoryText` for `repr` and frames. The reference's message moves to the parser, as the
  other "unrepresentable" divergences do.
- `newtype ConnectionId`, `HostId` and `OperationId`, with the existing validators as smart
  constructors.
- Leave stored-record fields such as `StoredConnection.status` as `Text`. Their check order is
  part of the refusal contract (custody `DIVERGENCES.md`).

**Churn.** Small for the enums, about 60 lines. Moderate for the custody identifiers, about 300
lines. Do the enums; the identifiers are optional.

**Wire risk.** None.

### ELG-S-10 (minor): test design

**Evidence.**

- **Corpus loading.** Corpora load through top-level `unsafePerformIO`:
  - `HostsDifferentialSpec.hs:28`
  - `RunnerDifferentialSpec.hs:42`
  - `PiDifferentialSpec.hs:49`
  - observation `Support.hs:183`

  Meanwhile agenticus-core's suites use hspec's `runIO` for the same job
  (`ThreadDifferentialSpec.hs:91`, `EffectSpec.hs:553`).
- **JSON navigation.** Partial helpers (`member`, `items`, `str`, `field`, `int`) are redefined in
  about 20 test modules across the slice.
- **The raw HTTP client.** `exchange`, `normalize`, `parseReply` and `header` are copied in
  `petrus-simulation/test/Support.hs`, `petrus-observation-http/test/Support.hs` and
  `petrus-http-core/test/Main.hs`.
- **Properties.** Outside DST there are almost no properties. There are two `forAll`s in
  agenticus-core and none in observation, telemetry, agenticus or runtime. Yet several pure state
  machines have stated invariants that example tests cover only pointwise.

**Better shape.**

- Load corpora with `runIO` or `beforeAll`.
- Add one `Petrus.TestSupport.Json` module (the accessors, with good failure messages). Add a raw
  HTTP client module to `petrus-test-support`, or a `test-support` sublibrary of
  `petrus-http-core`.
- Add a few cheap, high-value properties:
  - any sequence of successful Thread, Episode and Turn transitions leaves `validateThread`
    satisfied;
  - `episodeFromData . episodeToData` is `Right` on generated Episodes, and likewise for Turn and
    budget codecs;
  - custody snapshot encode and validate round-trips;
  - telemetry's `dictUnion` keeps first-key order.

**Churn.** Moderate, tests only. **Wire risk:** none.

### ELG-S-11 (minor): children are not cleaned up on interruption

**Evidence.**

- **`runProcessScenario`** (`Runner.hs:827-856`). It starts the child in a new session and then
  polls. If the calling thread is interrupted between `createProcess` and the reap, for example by
  an hspec timeout or `cancel`, nothing signals the group. The `bracket` then removes the
  temporary directory under a live child.
- **`runBounded`** (`Pi.hs:1906-1925`). It kills the child only on its own timeout, not when its
  caller is interrupted.
- **Polling.** Process waits poll with `getProcessExitCode` in three places:
  - `waitFor` (`Runner.hs:859`)
  - `waitExit` (`Pi.hs:1428`, 2 ms fixed)
  - the HostSupport callers

**Better shape.**

- Wrap the spawn-to-reap section in `onException` (or `bracketOnError`), killing the group and
  reaping.
- In the runtime, own the reader and drainer as `Async`s (ELG-S-2), so that `closeHelper` and
  interruption cancel them.
- One `waitExit` (ELG-S-2) is enough for both packages' polling.

**Churn.** About 40 lines. **Wire risk:** none.

### ELG-S-12 (minor): packaging and documentation nits

- **Stale description.** `petrus-agenticus-runtime.cabal:4-12` still describes the package as
  "the first is the durable Local Agent-as-a-Net runner … Provider hosts … are tracked in
  PARITY.md". All hosts are ported now.
- **Exported internals.** `HostSupport` is an exposed module. `Pi` exports a section headed
  "Adapter internals (the reference's private attributes, for tests)" (`Pi.hs:114-124`), and
  others export similar sections. The repo convention elsewhere is `…Internal` modules; use it
  (this also shrinks ELG-S-5).
- **Missing reasons.** Telemetry DIVERGENCES items 13 and 14 have no reason (see ELG-S-7).
- **Cross-package sources (repo-wide; noted only).** The telemetry-instrumentation test and bench
  compile other packages' test directories through relative `hs-source-dirs`
  (`petrus-telemetry-instrumentation.cabal:38, 68`), as several engine-layer packages do. A public
  test-fixtures sublibrary, as `petrus-dst:engine-worlds` already demonstrates, is the idiomatic
  form. It belongs to whichever audit owns `petrus-engine` and `petrus-impetus`.

## Considered and not flagged

These are deliberate, documented trade-offs. Changing any of them would cost more than it gains:

- **Process-global telemetry level and sink.** They are justified by `capture` reaching
  pre-existing loggers, and explicit sinks bypass them.
- **One `AgenticusError` with an `ErrorClass` hierarchy.** Messages are the contract across
  hundreds of refusals, and per-domain error types would be large churn for little safety. Two
  accessors parse the message back to recover an attribute: `budgetExceededDimension` and
  `runtimeProtocolErrorCode`. They are a small smell, worth a structured field only if more
  appear.
- **`RLock` equivalents.** These are `Barrier` in Hands and the per-`ThreadId` depth map in
  `Attachment.Binding`. Re-entrancy from provider callbacks is part of the upstream contract, and
  both are documented and benchmarked.
- **Observation HTTP classifies thrown failures,** the way Python's `except` clauses do. The doors
  are `IO` and throw Engine errors, so an `ExceptT` would only wrap the same classification.
- **DST's pydantic-emulating decoder and specialised canonical encoder.** Both are required for
  byte-identical artifacts and refusal text. The encoder is checked against petrus-json by
  property.
- **`Request.requestSimple :: Bool` in the HTTP core.** It reproduces the CPython HTTP/0.9 quirk.
  A sum type would not simplify either service.
- **Retention ledger `archive :: Maybe` checked at runtime.** It comes from SQL rows, and the
  check is part of the refusal contract.

## Exemplary

- **`Petrus.Observation` and `.Engine`.** Capture under the monitor, then project purely. The
  module header states the coherence argument.
- **`Petrus.Testing.Dst`.**
  - `Profile m g` with the `Scenario` monad makes out-of-door use and re-entrancy
    unrepresentable.
  - `WorldT` is a plain state machine whose failure leaves the state where the reference leaves
    it.
  - Identities are phantom-kinded (`Identity 'ProfileKind`).
  - `AuthoredDisposition` and `IndexAuthority` remove run-time refusals by type.
- **`Petrus.Http.Core.Server`.** The STM shutdown and accept loop, `mask` and `restore`
  discipline, and idempotent close.
- **`Petrus.Agenticus.Thread.Lifecycle` and `Identity`.** Pure `Either` transitions over newtype
  identities, with `Seq` for O(1) appends.
- **Agenticus effect and custody value modelling.** `PayloadValue` without floats,
  `ScrubbedBytes` with forced results before erasure, and redacted `Show`.
- **`Petrus.Simulation.admit`.** Every profile check runs in the reference's order as a pure
  `Either`, before any Engine exists.
- **DIVERGENCES files.** They are precise. They separate wire-identical behaviour from API shape,
  and they name what cannot be represented and why.
