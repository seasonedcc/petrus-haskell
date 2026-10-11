# Elegance audit: hamsterdan slice

This is the elegance and design audit of the Haskell port of Hamsterdan,
against the project goal's "better the Haskell way" outcome: wherever Haskell
can make a part clearly better than a direct translation (safer, simpler, more
correct, more composable or faster), the port does it, and wire formats and
specified behavior never diverge. Accuracy was audited separately
([hamsterdan.md](hamsterdan.md), HAM-1 to HAM-11) and is not repeated here.

Scope: `packages/hamsterdan-{agents,cli,contracts,e2e,export,github,host,operator,readiness,testing}`
(`src`, `app`, `test`, `bench`, the `.cabal` files and `DIVERGENCES.md`), about
80,000 lines. Method: every `DIVERGENCES.md` and `.cabal` file read in full;
module export lists and top-level signatures inventoried for every library
module; then targeted reading of the modules where the inventory pointed
(duplicated names, `Text` fields that hold closed vocabularies, `IORef`
state, `error`/`!!`/`unsafePerformIO`, subprocess and thread code). Nothing
was built or run. Paths are relative to the repository root; line numbers are
at `3bfb6c9`.

The bar is calibrated: a finding is listed only when the better shape is
clear and worth its churn. No finding below needs a wire, persisted or
observable change. Where a change could move a failure text, that is called
out together with the existing corpus that would catch it.

## Verdict

**Passes with changes.**

The semantic core is the Haskell way already. The V5 readiness net is a set
of pure folds (`hamsterdan-readiness` has no `IO` at all), refusals are
values, the contracts are records and sum types generated from the pinned
pydantic models, the readiness model in `hamsterdan-testing` is two pure
functions over fully typed facts, and the GitHub boundary hands typed
snapshots to the host. The divergence records are thorough and each one has
a rationale.

What keeps the slice from passing cleanly is a layer that grew piecemeal
around that core. "CPython semantics" (truthiness, `dict.get`,
`str.splitlines`, `json.loads`, `urlsplit`, exception classes) is implemented
five to seven times in five packages, with five representations of a Python
exception. One of them renders failures to text that the host then parses
back with `literal_eval`. The readiness folds still use the Python
`validated_update(**changes)` idiom 75 times, although the contracts'
divergence record says it became record update. Closed vocabularies that the
contracts model as sum types turn back into `Text` at the host and agent
seams. The host carries a second, independent `argparse` emulation beside
`hamsterdan-cli`. None of this risks a wire format, and each fix is
incremental and covered by the existing corpora and differentials. Together
they are the difference between "a faithful port with a Haskell core" and
"the Haskell way throughout".

## Findings

Severity: **major** = materially weakens the "better the Haskell way"
outcome in production code or across packages; **minor** = a local
improvement. Ranked by impact.

| Id | Severity | Finding | Churn |
| --- | --- | --- | --- |
| ELG-H-1 | major | CPython-semantics helpers are reimplemented in five packages, and inconsistently | M |
| ELG-H-2 | major | Five representations of a Python exception; readiness renders failures to text that the host parses back | M |
| ELG-H-3 | major | Readiness folds update records through string-keyed JSON patches (`vupdate`) | M |
| ELG-H-4 | major | Closed vocabularies become `Text` again at the host, GitHub and agent seams | M |
| ELG-H-5 | major | The host's command line is a second `argparse` emulation; both CLIs dispatch on strings | M |
| ELG-H-6 | minor | The readiness World validates and applies commands by string name, twice | M |
| ELG-H-7 | minor | `HostService` keeps three parallel maps in sync by hand, keyed by a bare triple | S |
| ELG-H-8 | minor | Two hand-rolled `forkIO`/`MVar` subprocess readers | S |
| ELG-H-9 | minor | Effect retries index a delay list with `!!` and accumulate results in an `IORef` | S |
| ELG-H-10 | minor | `_unused = (undefined, …)` bindings silence warnings instead of removing dead imports | XS |
| ELG-H-11 | minor | Partial `error` in "cannot fail" encoders, one of them reachable with a wrong message | S |
| ELG-H-12 | minor | Intrinsic invariants are checked only by examples and corpora | S |

Churn: XS < 50 lines, S < 300, M < 1,500, L above.

### ELG-H-1 (major): CPython-semantics helpers are reimplemented in five packages

**Evidence.** The same Python built-ins are defined over and over, each
where it was first needed:

| Operation | Definitions |
| --- | --- |
| truthiness | `hamsterdan-github/.../GitHub/Python.hs:108`, `hamsterdan-readiness/.../NetV5/Py.hs:68`, `.../NetV5/Board.hs:58`, `hamsterdan-export/.../Export/Python.hs:223`, `hamsterdan-agents/.../Agents/Validate.hs:269`, `hamsterdan-contracts/.../ReadinessProjection.hs:245`, `hamsterdan-testing/.../Testing/World.hs:1599` |
| `dict.get(k, default)` | `GitHub/Python.hs:98`, `NetV5/Py.hs:125`, `NetV5/Board.hs:49`, `Operator/Python.hs:46`, `Agents/Validate.hs:280` |
| `str(value)` | `GitHub/Python.hs:127`, `NetV5/Py.hs:258`, `Export/Python.hs:183`, `Host/V5/Application.hs:270`, `Host/Service.hs:541` (`pyStrId`) |
| `str.splitlines()` | `Host/Agenticus.hs:496`, `Host/PiWorkspace.hs:510`, `Host/GitPublish.hs:560`, `Host/Cli.hs:665`, `Export.hs:326` (bytes) |
| `hashlib.sha256().hexdigest()` | `Agents/Pi.hs:373`, `Host/PiWorkspace.hs:160`, `Export.hs:230`, `Host/Python.hs:188`, `Testing/World/Contract.hs:363` |
| `urllib.parse.urlsplit` | `Agents/Url.hs:32`, `GitHub/Url.hs:65` |
| `json.loads(bytes)` | `GitHub/Python.hs:212` (`loadsBytes`), `Export/Python.hs:393` (`loadsText`) |
| `except Exception` | `Host/Python.hs:142` (`tryPython`), `Agents/Pi.hs:387` and `Host/PublicationQualification.hs:326` (`trySync`) |
| a Python value model | `Json` + helpers (github, readiness), `PV` (`Export/Python.hs:78`), `PyValue` (`Hamsterdan.PyLiteral`) |

The copies have already drifted:

- `GitHub.Python.loadsBytes` decodes UTF-16 and UTF-32 documents as
  `json.loads` does; `Export.Python.loadsText` refuses them
  (`hamsterdan-export/DIVERGENCES.md` item 4).
- `Agents.Url.urlsplit` reproduces CPython's NFKC netloc check;
  `GitHub.Url.urlsplit` does not (`hamsterdan-github/DIVERGENCES.md` item 9).
- `Host.Service.pyStrId` prints a float with Haskell's `show` and a list or
  dict with the `Json` `Show` instance (`Service.hs:541-548`), where
  `GitHub.Python.str` is the faithful `str()` (`GitHub/Python.hs:127-138`).

The same accretion bends the package graph. `hamsterdan-cli` depends on
`hamsterdan-github` and `hamsterdan-agents` depends on `hamsterdan-github`
only for text helpers (HAM-2). `hamsterdan-operator` depends on
`hamsterdan-export` for the `PV` model and on `hamsterdan-host` for
`pySplitlines` (`Operator.hs:104,117-118`). `Hamsterdan.GitHub.Sqlite`, a
general `sqlite3` wrapper, lives in the GitHub package and is imported by
agents and host. Modules named `Hamsterdan.Host.*` live in
`hamsterdan-agents` and `hamsterdan-operator`.

**Better shape.** One home for the CPython layer, named for what it is, in
the package every Hamsterdan package already depends on (or a new
`hamsterdan-python` under it):

```haskell
Hamsterdan.Python.Value      -- truthy, typeName, get/getOr, subscript, iterate, str, repr over Json
Hamsterdan.Python.Text       -- isSpace, strip, casefold, splitlines, isPrintable, utf8Length, int()
Hamsterdan.Python.Json       -- json.loads (one implementation, UTF-16/32 included), json.dumps spellings
Hamsterdan.Python.Url        -- urlsplit (with the NFKC check), quote, unquote
Hamsterdan.Python.Exception  -- see ELG-H-2
Hamsterdan.Python.Sqlite     -- today's Hamsterdan.GitHub.Sqlite, immediate, rowValue
```

`PV` can stay where `bytes` must be modeled (export and operator read SQLite
blobs), but its operations should be the same functions instantiated at a
second type, not a third copy. The HAM-2 fix already in progress moves
`strip` and `utf8Length` into `hamsterdan-contracts`; it is the natural
moment to move the whole layer rather than two functions.

**Churn.** M: mostly moves and import edits. Deleting the copies is where
the risk lies, and it is behavior-preserving except where the copies
disagree today. There the shared version must be the faithful one, which
changes export (UTF-16/32 JSON accepted, closing its divergence 4) and the
GitHub URL refusal text (closing its divergence 9) toward the reference.
**Wire risk:** none; both changes move toward the reference, and the
existing corpora pin every other output.

### ELG-H-2 (major): five representations of a Python exception

**Evidence.**

- `hamsterdan-github`: `PyClass` (an enum of six classes), `PyFailure`, and
  the thrown `PythonFault {pythonClass :: Text, pythonDetail :: Text}`
  (`GitHub/Python.hs:63-88`). `Webhooks.parseObservation` returns
  `Either (Either () PyFailure) Observation` (`Webhooks.hs:468`), where
  `Left (Left ())` means "refused".
- `hamsterdan-export` and `hamsterdan-operator`: `PyError {cls, message}`
  (`Export/Python.hs:153`).
- `hamsterdan-host`: its own `TypeError` newtype, Petrus's `RuntimeError`,
  `ValueError` and `LookupError`, and Petrus's
  `PythonException name args` (`Host/Python.hs:77-102`).
- `hamsterdan-readiness`: `type Py = Either Text`, the failure already
  rendered as `ValueError('…')` text (`NetV5/Py.hs:54`, `NetV5/Folding.hs:160-177`).
- `hamsterdan-agents`: `Validate.Failure` (`Agents/Validate.hs:68`).

The host then has to recognize every one of them by type to recover a class
name (`exceptionClass`, `Host/Python.hs:147-159`). Worse,
`raiseFailureText` (`Host/Python.hs:91-102`) takes the readiness layer's
rendered text, splits it at `(`, runs `literal_eval` on the argument, and
throws a typed exception again. It is called at ten sites in
`V5/Runtime.hs`, `V5/Application.hs` and `V5/Gates.hs`. Rendering a value
to text and parsing it back is the clearest Python-shaped seam in the slice.

**Better shape.** One structured exception value, which already exists in
Petrus as the History spelling:

```haskell
-- Hamsterdan.Python.Exception
data PyException = PyException { pyClass :: Text, pyArgs :: [PythonArg] }  -- = Petrus's PythonException
instance Exception PyException
failureText :: PyException -> Text          -- pythonFailureText, used only where the engine needs Text

-- readiness
type Py = Either PyException                 -- render at the Fold boundary only
-- host
raise :: PyException -> IO a                 -- replaces raiseFailureText's parse-back
```

`PythonFault` and `PyError` become this type. `parseObservation` returns
`Either ParseRefusal Observation` with
`data ParseRefusal = Refused | Uncaught PyException`. Only the Fold type
(`Binding -> [Arc] -> Either Text HandlerResult`, fixed by petrus-impetus)
still needs `Text`, and gets it from one `first failureText` at the
boundary.

**Churn.** M. **Wire risk:** none. Failure texts are produced by the same
`pythonFailureText` at the same points, and `FoldCorpusSpec` and the gate
corpora compare them byte for byte.

### ELG-H-3 (major): readiness folds update records through string-keyed JSON patches

**Evidence.** `vupdate` (`NetV5/Py.hs:285-288`) is Python's
`validated_update(**changes)`: dump the record to JSON, overwrite members by
name, and revalidate the whole object. It is called 75 times across nine
fold modules, almost always with values that are already typed fields:

```haskell
-- NetV5/Life.hs:155, where st.phase :: Phase and PhaseQuiescent exists
quiescent <- vupdate st [("phase", String "quiescent")]
-- NetV5/Readiness.hs:151-158
vupdate snap0 [("incarnation", Int fact.incarnation), ("checks", String "pending"), ("review", String "pending"), …]
```

A misspelled member name or a wrongly typed value becomes a run-time
`ValidationError` instead of a compile error, and every update returns
`Either` and needs a bind. The same module builds other values with record
syntax (`Life.hs:123-137`), so the two styles sit side by side.
`hamsterdan-contracts/DIVERGENCES.md` item 3 says "`validated_update` is
record update … record update syntax gives both guarantees at compile time".
That is true of the contracts package and not of the folds that use it.

**Better shape.**

```haskell
let quiescent = st {phase = PhaseQuiescent}
let snap = snap0 {incarnation = fact.incarnation, checks = "pending", review = ReviewPending, findingsBlocking = 0, pending = []}
```

None of the V5 contracts has a refinement or normalizing codec (no `refine`,
`normalizing` or `finiteJson` in `Contracts/ReadinessV5.hs`), so
revalidating a well-typed record is a no-op whenever
`validate . dump = Right`. ELG-H-12 proposes checking that as a property,
which makes this change provably behavior-preserving. Keep `construct @T`
(about five sites) where the reference really builds a model from an
untyped dict, so a `ValidationError` surfaces at the same point.

**Churn.** M (75 sites, mechanical). **Wire risk:** none for well-typed
patches. Where a patch value comes from an untyped baton, decode it with the
field's codec at the same position in the fold, so that the first failure,
and therefore the recorded text, does not move. `FoldCorpusSpec` checks
this.

### ELG-H-4 (major): closed vocabularies become `Text` again at the seams

**Evidence.** The contracts model `Literal` vocabularies as sum types and
treat this as a headline divergence. Past the contracts, the same kind of
closed sets travel as `Text` and are compared with string literals:

- `CurrentClaim.phase :: Text` (`Host/V5/Claim.hs:14`).
  `Application.phaseOf :: PullRequestSnapshot -> Text` (`Application.hs:450`)
  produces `"running" | "quiescent" | "terminal"`, and `Review.hs:227` and
  `Mutation.hs:134` each parse it back into `Phase`, with an unreachable
  `ValidationError` branch.
- `QualificationFault` holds `boundary` and `phase` as `Text`, validated
  against sets and against the invariant
  `(boundary == "agent") == (phase ∈ {timed_out, malformed})`, then
  re-tested with `fault.phase == "timed_out"` (`Host/Service.hs:172-255`).
- The webhook inbox status (`Custody.status :: … -> IO (Maybe Text)`,
  `Webhooks.hs:684`), compared with `Just "pending"`, `Just "terminal"` and
  `Just "failed"` (`Service.hs:800, 954-960`). `CustodyOneResult.disposition :: Text`
  (`Service.hs:452-456`).
- `PublicationResult.status :: Text` (`GitHub/Models.hs:266`), compared with
  `"existing"`, `"requested"` and `"unable"` (`V5/Rerun.hs:123-124`,
  `V5/Review.hs:327`, `V5/Gates.hs:134`), and the Git publisher's
  `disposition :: Text` (`GitPublish.hs:143`, compared at `:223, :265, :270`,
  `V5/Mutation.hs:200, 243`).
- Agent protocol results: `ReviewResult.status`, `CodingResult.status` and
  `CodingRequest.kind` are `Text` (`Agents/Protocol.hs:96, 171, 218`).
  `Agents.Validate` checks them against the closed sets and then discards
  that knowledge, and the host compares strings again
  (`V5/Mutation.hs:222-225`).

**Better shape.** Parse at the edge and carry the type:

```haskell
data FaultPoint = AgentFault AgentFaultPhase | CommentFault CommentFaultPhase   -- the invariant is the type
data AgentFaultPhase = FaultTimedOut | FaultMalformed
data CommentFaultPhase = FaultBeforeCall | FaultAfterCall
data InboxStatus = InboxPending | InboxTerminal | InboxFailed                   -- spelled at the SQL boundary
data PublicationStatus = Created | Existing | Requested | Unable | InlineUnavailable | …
CurrentClaim { phase :: Phase, … }                                            -- phaseOf pull :: Phase
```

Each type gets a `spell`/`unspell` pair (the `Contract` enum codec already
provides it for vocabularies that are on the wire). For the agent protocol,
`validateResult` can return the validated status as a sum type alongside the
record, or the record can hold it. The strict protocol decoders are a
port-only addition (contracts DIVERGENCES item 6), so their admission is not
a wire contract.

**Churn.** M, spread over host, GitHub and agents. **Wire risk:** none. SQLite
columns, JSON members and log lines keep their spellings through `spell`, and
the inbox, CLI and journey differentials compare them.

### ELG-H-5 (major): a second `argparse` emulation, and string dispatch in both CLIs

**Evidence.** `hamsterdan-cli` exists to be "CPython 3.14's argparse for
Hamsterdan's operator command lines" (`hamsterdan-cli.cabal`), and export
and operator use it. `Hamsterdan.Host.Cli` reimplements the same machinery
privately in about 450 lines (`Host/Cli.hs:93-545`): `_parse_optional`,
option tuples and abbreviations, `classify`, `formatUsage`, `formatHelp`,
`textwrap`, and the `COLUMNS`/`TIOCGWINSZ` FFI. `terminalColumns`,
`environmentColumns`, `windowColumns`, `pythonInt` and `removeFirst` are
defined in both modules.

After parsing, both CLIs read their namespace by string. The host compares
`arguments.command == "requeue"` and switches on
`case arguments.command of "validate" -> …` (`Host/Cli.hs:930-1000`). The
operator does `fromMaybe "" (lookupText "command" namespace)` with a
catch-all `_ -> inspectAuthority …` (`Operator.hs:1779-1802`), so a
misspelled branch silently becomes `inspect-authority`.

**Better shape.** Declare the host parser with `Hamsterdan.Cli.Argparse`
(a positional with `choices`, store options, defaults computed from the
environment). Then decode the namespace once into a command type, so the
dispatch is a total `case`:

```haskell
data HostCommand = Serve Endpoint | Validate | Inbox | Requeue DeliveryId
                 | InspectInstance InstanceKey
fromNamespace :: Namespace -> Either UsageError HostCommand  -- "requeue requires --delivery" lives here
```

The operator's commands get the same treatment.

**Churn.** M (delete about 450 lines and add about 120). **Wire risk:** none.
The host CLI differential (105 command lines) and the argparse differentials
of export and operator compare stdout, stderr and exit status byte for byte.

### ELG-H-6 (minor): the readiness World validates and applies commands by string name, twice

**Evidence.** `validateCommand` (`Testing/World.hs:304-406`) is an
`if | name == "readiness.github.pr.set" -> …` chain over string names. It
checks each payload and returns the untyped `Command` unchanged.
`applyOne` (`World.hs:518-690`) dispatches on the same strings, re-reads the
same `Json` payload with `fromMaybe "" (str (field "head"))`-style defaults
(`:542, 553, 559, 566, 569, 572, 590-592`), and repeats several checks with
different messages: the CI status set (`:343` and `:539`), the review status
set (`:347` and `:549`), the human review state (`:357` and `:561`), the
time-advance bound (`:398-400` and `:641-643`) and the webhook digest
(`:391-395` and `:593-594`). The provider `Truth` keeps `reviewStatus`, check
statuses and human review states as `Text`, although
`Hamsterdan.Testing.Readiness` already defines `CheckStatus`, `ReviewStatus`
and friends (`Readiness.hs:114, 136`). `profileLimit "payload_bytes"` looks
limits up by string and calls `error` on a miss (`World/Contract.hs:112-113`).
The e2e `Tape` accessors default silently in the same way (`text` gives `""`,
`integer` gives `0`; `E2E/Tape.hs:58-78`).

**Better shape.** Parse, don't validate:

```haskell
data ReadinessCommand
  = SetPullRequest AuthorityClaim | SetCi Sha [CheckName] [Check] | SetReview Sha ReviewStatus [Json]
  | HumanReview Reviewer Sha ReviewId HumanState | … | AdvanceTime Seconds | HostDriveOne | …
parseCommand :: Command -> Either PyError ReadinessCommand     -- the profile's `validate`
applyCommand :: … -> ReadinessCommand -> IO (Json, ActionDisposition)
```

The artifact keeps the `Command` JSON (the wire), and only the
interpretation becomes typed. A typed command is also the natural action
type for the Hedgehog state machine the HAM-6 rework is building.

**Churn.** M within one module. **Wire risk:** none. The World interop suite
compares artifacts, replays and verdicts with the reference. Where upstream
really checks twice, keep the second message as a branch that is reachable
only on replay without validation, if petrus-dst can do that.

### ELG-H-7 (minor): `HostService` keeps three parallel maps in sync by hand

**Evidence.** Loaded Instances live in `apps :: IORef (Map Key HostApplication)`,
`locks :: IORef (Map Key (MVar ()))` and `instances :: IORef [(Text, Key)]`
(`Host/Service.hs:436-438`), all written together at `:722-725` and read
with partial `Map.!` (`:598, 922-923, 932, 979-980, 1128, 1271`).
`type Key = (Integer, Integer, Integer)` (`:363`; the same bare triple at
`Webhooks.hs:569, 610, 622`) leaves installation, repository and pull
request order to convention. `processOne` recovers the Instance with
`fromMaybe (error "selected observation has an Instance")` (`:949`),
relying on `selectObservation` having checked the same three fields.

**Better shape.**

```haskell
data InstanceKey = InstanceKey { installation, repository, pullRequest :: Integer }
data Loaded = Loaded { name :: Text, app :: HostApplication, lock :: MVar () }
loaded :: IORef (Map InstanceKey Loaded), order :: IORef [InstanceKey]   -- or one ordered map
selectObservation :: … -> IO (Maybe Selected)    -- Selected carries the InstanceKey it proved
```

**Churn.** S. **Wire risk:** none.

### ELG-H-8 (minor): two hand-rolled `forkIO`/`MVar` subprocess readers

**Evidence.** `runGit` (`Host/GitPublish.hs:459-474`) and the workspace Git
runner (`Host/PiWorkspace.hs:471-480`) each fork two reader threads that
`putMVar` the drained pipes and then `takeMVar` both. If a reader throws,
its `MVar` is never filled and the caller blocks until the 60-second
timeout, or fails with `BlockedIndefinitelyOnMVar`. The slice already uses
`typed-process`'s `readProcess` for the same job (`Operator.hs:309, 423`,
`Testing/Journeys.hs:913`).

**Better shape.** `readProcess (setStdin (byteStringInput input) (setEnv gitEnvironment (proc path args)))`
under the same `timeout`. Reader exceptions propagate and children are
terminated by the library.

**Churn.** S. **Wire risk:** none; the same commands, environment and
decoding apply.

### ELG-H-9 (minor): effect retries index a delay list with `!!`

**Evidence.** The inline-finding and batch publishers retry with
`attempt == retries` guards and `transientRetrySeconds !! attempt`
(`GitHub/Effects.hs:563, 579, 663, 677`). Landed results accumulate in an
`IORef (Map Text PublicationResult)` that `reconcileBatch` mutates
(`:569, 590-608`).

**Better shape.** Retry over the delay list itself
(`loop (d : ds) = … retryDelay d >> loop ds; loop [] = throwIO failure`).
Have `reconcileBatch` return `(landed, remaining)` and fold the landed
results purely. One `withTransientRetries` combinator removes the four
copies.

**Churn.** S. **Wire risk:** none; the request sequence is unchanged and the
effects corpus pins it.

### ELG-H-10 (minor): `_unused = undefined` bindings

**Evidence.** `Testing/World.hs:1904-1905`, `Testing/World/Coverage.hs:847-848`
(ten `undefined`s), `Testing/World/Scenarios.hs:360-364` and
`test/ReadinessWorldSpec.hs:667-668` exist only to keep imports and
bindings "used" under `-Werror`. `Coverage.hs:527` also redefines `isNothing'`.

**Better shape.** Delete the dead imports and bindings, or, where an import
is kept on purpose, add `{-# OPTIONS_GHC -Wno-unused-imports #-}` with a
comment saying why.

**Churn.** XS. **Wire risk:** none.

### ELG-H-11 (minor): partial `error` in "cannot fail" encoders

**Evidence.** `encodeObservation` is
`either (const (error "observation encoding admits non-finite numbers"))`
(`GitHub/Webhooks.hs:219`). The encoder it wraps can also fail with
`NestingTooDeep` (petrus-json's `defaultNestingLimit` is 100,000), and a
signed 1 MiB body can carry a 100,001-deep `action` value. That path is
reachable, and it would raise `ErrorCall` with a message that is false.
Similar `either (error . show) id` wrappers are at `Host/Python.hs:164-185`
(every `dumps*`), `Host/Agenticus.hs:199`, `Host/Binding.hs:69`,
`Host/Scripted.hs:67`, `Testing/Journeys.hs:392-396` and
`Testing/World/Contract.hs:180, 360`. `Agents/Pi/Doubles.hs:67` builds a
constant policy through `unsafePerformIO`. `GitHub/Python.hs:256-261`
catches `SomeException`, asynchronous ones included, inside
`unsafePerformIO` where only `UnicodeException` is meant.

**Better shape.** Return `Either` from the encoders whose input is
provider-controlled (`encodeObservation`, the host `dumps*`), and throw the
reference's class at the caller (`RecursionError`, as
`Operator.Python.dumpsPlain` already does). Keep `error` only for
compile-time constants, with a message that states the real precondition.
Narrow `decodeStrictly` to `UnicodeException`. The deep-nesting outcome
itself belongs with the accuracy audit (`hamsterdan-github/DIVERGENCES.md`
item 7); this finding is about the partiality and the wrong message.

**Churn.** S. **Wire risk:** none. The reachable case changes only which
class a 500 records, toward the reference.

### ELG-H-12 (minor): intrinsic invariants are checked only by examples and corpora

**Evidence.** Only `hamsterdan-contracts` (`PyLiteralSpec`) depends on a
property-testing library. The differential corpora are excellent at
"agrees with Python", but some invariants are properties of the Haskell
code itself, and no example covers all of them:

- `validate @T (dump x) == Right x` for every generated contract. This is
  the law ELG-H-3 relies on, and `gen_models.py` could emit the generators.
- Folding a fact with a stale incarnation leaves the readiness snapshot
  unchanged (`applyState`, `applyWhenCurrent` in `NetV5/Readiness.hs`).
- `verifyWith (verifier s) b (sign s b)` holds and is false for any other
  body.
- `fastLoads` agrees with `loadsText` wherever it answers. `FastJsonSpec`
  already draws 3,000 documents from a hand-rolled generator; a Hedgehog
  generator would also shrink a counterexample.

**Better shape.** A handful of Hedgehog properties next to the existing
specs. This is separate from, and smaller than, the campaign conversion
already in progress under HAM-6.

**Churn.** S. **Wire risk:** none (tests only).

## Considered and not recommended

These looked Python-shaped but are the right call, or not worth the churn:

- **`Observation`'s provider members are `Json`** (`Webhooks.hs:152-170`).
  The reference stores whatever the payload held, unvalidated, and the inbox
  bytes must match. Typing these fields would either change admission or
  need a second copy. The comment says exactly this.
- **The 156 positional fast-path decoders** in `Contracts/ReadinessV5.hs`
  and `Contracts/Readiness.hs` (about 1,700 lines) repeat each field list,
  but they are generated from one list by `scripts/gen_models.py`, so they
  cannot drift.
- **`IORef ServiceHooks` / `ApplicationHooks`** are test seams that stand in
  for monkeypatching after construction, which several specs need. Making
  them immutable options would push that need into every spec for little
  gain.
- **`PV` in export and operator.** The exporter and operator do read
  untyped History, SQLite rows and `gh` output with dynamic Python, and
  their error classes are output. A dynamic value model is the honest port
  (ELG-H-1 only asks that it share operations).
- **`runPi`'s two `IORef`s** (`Agents/Pi.hs:414-444`) carry the body's
  result past a cleanup that may throw. A provider that returned its
  cleanup outcome as a value would remove them, but the seam change costs
  more than it saves.
- **The export `Reporter` `IORef`s** accumulate a report while files are
  written; a `Writer` over `IO` would not be clearer.

## On the accuracy fixes in progress

- **HAM-2** (move shared helpers into `hamsterdan-contracts`): take the
  whole CPython layer of ELG-H-1, not only `strip` and `utf8Length`, so the
  edges `cli → github`, `agents → github` and `operator → export/host` all
  disappear in one move. The architecture check HAM-2 asks for can then
  forbid them.
- **HAM-10** (`unsafePerformIO` in `V5/Runtime.hs:220-222`): `EngineSelection`
  already threads a selection state `s` (`v5Selection` uses `()`). The
  target could be that state, set per drive, if the selection state is not
  recorded in History or a fingerprint. Check that first, because
  `EngineSelection` requires `Show s`. Otherwise, build the `SelectionPolicy`
  per drive with the target closed over.
- **HAM-6** (campaigns to Hedgehog): a state-machine test over a typed
  command (ELG-H-6) gives shrinking to readable counterexamples for free.

## What is exemplary

- Contracts are generated from the pinned pydantic models. `Literal` fields
  become sum types, single-valued `Literal` fields carry no Haskell field,
  and `projectReadiness` takes a `Concerns` record, so the partition of the
  snapshot is checked by the compiler.
- `hamsterdan-readiness` is entirely pure: every fold, gate handler and board
  renderer returns `Either`, and refusals are values.
- `Hamsterdan.Testing.Readiness` is two total, pure functions over typed
  facts, with validation at the codec.
- The GitHub boundary has capabilities as records (`Transport`, `Exchange`),
  one production code path above the network seam, a redacting `Show` on
  `Secret` and no `Show` on clients, HMAC key state precomputed per custody,
  typed snapshots out of the gateway, and typed exceptions.
- `TypeGuaranteeSpec` (operator) and the agents' compile-time cases turn
  "a dynamically typed caller could pass this" into checked type errors
  instead of dropping those cases.
- Resource handling is careful where it matters. `immediate` masks and rolls
  back, and `openApplication` closes stores that were already opened when a
  later step fails, which the reference leaves to the garbage collector.
- The export parallelizes pure parsing and rendering while keeping the
  reference's "first failure in file order" and its partial-package result.
- The divergence records are specific, give a rationale for every item, and
  say how each item is tested.
