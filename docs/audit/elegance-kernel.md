# Elegance and design audit: kernel slice

Scope: `petrus-json`, `petrus-cel`, `petrus-dsl`, `petrus-impetus`,
`petrus-history-store`, `petrus-history-postgres`, `petrus-sqlite`,
`petrus-postgres` and `petrus-posix`. For each package the audit read `src`,
`test`, `bench`, the cabal file and `DIVERGENCES.md`.

The question is whether the code is "better the Haskell way". Parity, interop
and performance were audited separately and are not repeated here. All paths
below are relative to `packages/`.

Calibration: the brief was "don't over-correct". A finding is listed only if
the improvement is clear and worth its churn. Every proposed change keeps wire
formats and observable behavior the same. The one exception is ELG-K-1, which
restores reference behavior that the port currently loses.

Static reading only. Nothing was built or run.

## Verdict: passes with changes

The kernel is idiomatic Haskell, and in several places it is a better design
than the Python reference:

- Purity is expressed in the types.
- Replay is a pure fold, and property tests pin it against the live marking.
- The rule that a write is durable before it is mirrored is built into the
  structure of the code.
- The DSL makes ill-formed nets hard to write.
- CEL is a pure seam that the kernel does not depend on.

Most findings are local consolidation and typing tightenings. One is a real
defect, ELG-K-1: a swallowed `Left` lets the JSONL store write a blank line
where the reference refuses loud. It hides behind a total-looking
`either (const mempty) id`, and is the main reason the verdict is not a plain
"passes". None of the changes touches a wire format.

## Findings, ranked by impact

### ELG-K-1 (major): the JSONL encoder swallows a refusal and writes a blank line

Evidence:

- `petrus-history-store/src/Petrus/HistoryStore/Jsonl.hs:160` defines
  `encodeLine = encodeRefusal record >> Right (... lineBuilder record)`.
- `Jsonl.hs:165-181`: `encodeRefusal` checks only `firstNonFinite`.
- `Jsonl.hs:196-197`:
  `lineBuilder record = either (const mempty) id (dumpsBuilder defaultDumps {allowNan = True} (encodeRecord record))`.
- Upstream `jsonl.py:181-192` has `_encoded_line`. It catches every
  `TypeError`/`ValueError` from `json.dumps` and raises
  `cannot durably encode {Type}: {error} — durable instants and token data must be JSON-faithful values`.

What is wrong:

- `dumpsBuilder` refuses more than non-finite floats. It also refuses an
  integer above CPython's 4300-digit limit, and nesting deeper than the
  recursion limit.
- Both can reach the store through handler output (token data). The kernel
  canonicalizes only delivery and activity payloads. `recordInvariants` and
  `recordFieldRules` check only `allFinite`.
- On those inputs `encodeRefusal` passes, and `lineBuilder` turns the `Left`
  into `mempty`. The file gets an empty line, the append succeeds, and the
  next load refuses the file.
- So the error is not reported. Instead the store silently corrupts its own
  file.
- SQLite (`encodeRows` via `dumps`) and Postgres (`encodePayload` via `dumps`)
  already refuse correctly, so only JSONL is affected.
- No test covers this case. A grep for `4300` or `IntegerTooLarge` in the
  history-store and impetus tests finds nothing.

The Haskell problem behind the bug: one refusal is checked in one pass, and the
encoder's own refusals are thrown away in a second pass. That split is what
lets the two drift apart. The checked pass and the encoder must be the same
`Either`.

Better shape: run one fallible pass and map every `DumpsError` to the
reference wording. The streaming concern in the comment at line 194 still
holds, because `dumpsBuilder` already produces a lazy `Builder`.

```haskell
encodeLine :: Record -> Either Text ByteString
encodeLine record =
  first refusal (dumpsBuilder defaultDumps {allowNan = False} (encodeRecord record))
    <&> (BL.toStrict . B.toLazyByteString)
  where
    refusal err = "cannot durably encode " <> recordName record <> ": "
      <> dumpsErrorText err   -- "Out of range float values ...", "Exceeds the limit (4300 digits) ...", ...
      <> " — durable instants and token data must be JSON-faithful values"
```

`firstNonFinite` is only needed if `dumpsBuilder` reports a non-finite float
with different text. In that case it becomes the message formatter, not a
separate gate.

Add one `BackendContractSpec` case: a record whose token data holds `10^5000`
must refuse on every backend, and the file must be unchanged.

Fold in this duplication: `Jsonl.hs:148-153` (`writeAll`) and the
`fileSynchronise` calls at 144-146 re-implement `Petrus.Posix.File.writeAll`
and `fsyncFd` (`petrus-posix/src/Petrus/Posix/File.hs:76`, `:66`). Use the
posix ones.

| Churn | Wire risk |
|---|---|
| About 40 lines plus one test | None for every valid record. The change removes a silent-corruption path and restores the reference's refusal. |

### ELG-K-2 (major): Python-compatibility primitives are duplicated across packages

Evidence:

- Two generated printability tables come from the same CPython 3.14 data:
  - `petrus-json/src/Petrus/Json/Printable.hs` (747 lines);
  - `petrus-cel` `Tables.pythonPrintable`, produced by
    `gen/gen-unicode-tables.py` and used by `Unicode.hs:105`
    (`isPythonPrintable`).
- `petrus-cel/src/Petrus/Cel/Python.hs` re-implements three helpers that
  `petrus-json` already has:
  - `strRepr` at line 41 duplicates `Petrus.Json.Repr` `pythonStrRepr`/`pythonStringRepr`;
  - `bytesRepr` at line 63 duplicates `pythonReprBytes`;
  - `floatRepr` at line 80 duplicates the Json float repr.
- `petrus-cel/src/Petrus/Cel/Binding.hs:78` (`pythonTypeName`) duplicates
  `jsonTypeName`.
- Python repr is spread over four modules:
  - `Petrus.Impetus.Internal.Repr` (`pyStr…`);
  - `Petrus.Json.Repr` (`pythonReprText`, which returns a `String`);
  - `Petrus.Sqlite.PythonRepr`, now a re-export;
  - `Petrus.Cel.Python`.

What is wrong:

- These are the port's most delicate compatibility tables, and each exists
  more than once.
- The next Unicode or CPython bump has to regenerate and re-verify two tables
  and keep four repr implementations in step. Anything missed there would be
  a silent divergence, not a compile error.
- `petrus-cel` already depends on `petrus-json`, so nothing forces the
  duplication.

Better shape:

- `petrus-json` owns all Python-text primitives: `isPythonPrintable`, `str`
  and `bytes` repr, float repr, and type names. Export them `Text`-first from
  one module, for example `Petrus.Json.Python`.
- `petrus-cel` deletes its table and the three helpers and imports those
  primitives.
- `pythonTypeName` becomes `jsonTypeName`, or a thin wrapper where the CEL
  value type is richer than `Json`.

| Churn | Wire risk |
|---|---|
| Medium: about 900 generated lines deleted, about 150 hand-written lines moved | None. The CEL differential and the JSON property suites pin the outputs. |

### ELG-K-3 (minor): impetus `Internal` modules are de facto public API

Evidence:

- `Petrus.Impetus.Internal.PyJson` (the CPython `json.loads` scanner) is
  imported by `petrus-history-store` `Internal` and by agenticus-runtime `Pi`.
- `Petrus.Impetus.Internal.Repr` is imported by dsl, engine and agenticus.
- `Petrus.Impetus.Internal.Pydantic` is imported by observation.
- `petrus-json/DIVERGENCES.md` itself points readers to
  `Petrus.Impetus.Internal.PyJson`.

What is wrong:

- Seven packages depend on modules marked internal. The name promises a
  freedom to change that the dependency graph does not grant.
- The JSON scanner also lives in the wrong package. It is JSON semantics, not
  kernel semantics.

Better shape:

- Move the scanner and repr, which is the Python-compatibility layer, into
  `petrus-json` as public modules. This is the same home as ELG-K-2.
- Keep `Pydantic` in impetus, but rename it non-`Internal`
  (`Petrus.Impetus.Validation.Pydantic`), since observation uses it by design.

| Churn | Wire risk |
|---|---|
| Import rewrites in about 20 modules | None |

### ELG-K-4 (minor): verify-on-conflict is stringly typed and duplicated across the two transactional stores

Evidence:

- `petrus-impetus/src/Petrus/Impetus/HistoryStore.hs:148-165` defines
  `verifyConflict :: Bool -> Json -> Json -> ConflictVerdict`:
  - it ignores its `Bool`;
  - it is equivalent to `(==)`;
  - only SQLite calls it (`Sqlite.hs:490` with `True`, `:518` with `False`).
- `petrus-history-postgres/src/Petrus/HistoryStore/Postgres.hs:333` defines a
  local `verifyConflict` with the same name.
- The terminal family of each record is matched by record-name `Text` in both
  stores:
  - `Postgres.hs:399`: `terminalFamily :: Text -> Maybe [Text]`;
  - SQLite `firingTerminals`/`activityTerminals` at `Sqlite.hs:149-150` and
    `504-507`.
- The same reference `RuntimeError` gets two exception types:
  - `UnverifiableConflict` (`Postgres.hs:135`);
  - `UnexplainedConflict` in `SqliteHistoryStoreFailure` (`Sqlite.hs:206`).

What is wrong:

- Which records are terminal for one firing or activity is a kernel fact
  about `Record`, but each backend encodes it again as a string table.
- A new record kind would compile cleanly and then mis-verify on one backend.
- The `Bool` parameter and the `ConflictVerdict` type add nothing.

Better shape:

```haskell
-- Petrus.Impetus.History.Records
data TerminalFamily = FiringTerminal | ActivityTerminal deriving (Eq, Show)
recordTerminalFamily :: Record -> Maybe TerminalFamily   -- total pattern match
```

- Both stores dispatch on `recordTerminalFamily`, so the compiler's
  exhaustiveness check covers new records.
- Drop `ConflictVerdict` and the `Bool`, and compare stored with candidate
  using `==`.
- Unify the two conflict exceptions into one kernel
  `HistoryConflictUnverifiable`. Their constructors are referenced only within
  the history packages and their tests.

| Churn | Wire risk |
|---|---|
| About 120 lines across 3 packages | None. The SQL text and the error message strings are unchanged. |

### ELG-K-5 (minor): knot-tying to learn the mirror position, and a silent `repeat`

Evidence:

- `Postgres.hs:286` uses `fixIO` so that the write can read `store.count`.
- `Sqlite.hs:255-258` does the same thing a different way: `self <- newIORef
  Nothing` … `writeIORef self (Just store)`.
- `HistoryStore.hs:137`:
  `[r | (r, Entered) <- zip batch (admissions ++ repeat Entered)]`.

What is wrong:

- Two different knot-tying tricks solve one missing parameter: the durable
  write needs the position the mirror has reached.
- `++ repeat Entered` silently accepts an admissions list of the wrong length.
  The structural guarantee of `mirroredHistoryStore` deserves a checked
  invariant here.

Better shape: `mirroredHistoryStore` passes the mirror's count in, so the
backends need no self-reference, and it checks the admissions length.

```haskell
mirroredHistoryStore :: (Int -> [Record] -> IO [Admission]) -> ... -> IO HistoryStore
-- and in the append:
when (length admissions /= length batch) (throwIO (AdmissionArity ...))
```

| Churn | Wire risk |
|---|---|
| About 40 lines | None |

### ELG-K-6 (minor): the accepted-identity index holds `Record` where only three constructors can occur

Evidence:

- `petrus-impetus/src/Petrus/Impetus/Instance.hs:351`: `sAccepted :: Map Text Record`.
- Its source is `Replay.hs:474`: `replayAcceptedIdentities :: ... Either Text (Map Text Record)`.
- The consequences in `Instance.hs`:
  - the `_ -> (path, [], Nothing, Nothing)` arm at line 1933;
  - an impossible `RuntimeRefused "accepted identity index holds a non-delivery record"` at line 1963;
  - the `head' record batch` reconstruction at 1993 and 2032-2034.

What is wrong: the type allows states that cannot happen, so the code has to
handle them with dead arms and a refusal that can never fire.

Better shape:

```haskell
data DeliveryFact
  = Delivered DeliveryAccepted
  | ActivityDelivered ActivityAccepted
  | ...                      -- exactly the three constructors that are inserted
deliveryFactRecord :: DeliveryFact -> Record
```

With this type the impossible branches and `head'` disappear.

| Churn | Wire risk |
|---|---|
| About 80 lines in `Replay.hs` and `Instance.hs` | None |

### ELG-K-7 (minor): `decodeStored` chooses control flow by matching error message text

Evidence: `petrus-history-store/src/Petrus/HistoryStore/Internal.hs:68-80`.
`headerPassed message` uses `T.isInfixOf` against substrings of
`decodeRecord`'s error text to decide which refusal path to take.

What is wrong:

- Rewording a message would silently change control flow.
- The decoder already knows whether it failed at the envelope or header stage
  or at the field stage.

Better shape: split the decoder into
`decodeEnvelope :: Json -> Either Text (RecordName, Schema, Fields)` and
`decodeFields`. `decodeStored` then branches on which stage failed. The message
strings stay byte-identical.

| Churn | Wire risk |
|---|---|
| About 50 lines | None. Error texts are unchanged. |

### ELG-K-8 (minor): `Eq Json` is not symmetric for objects with duplicate keys

Evidence: `petrus-json/src/Petrus/Json/Value.hs:42-50`.

```haskell
pythonEq (Object as) (Object bs) =
  length as == length bs && all (\(k, v) -> maybe False (pythonEq v) (lookup k bs)) as
```

With duplicate keys the result depends on argument order:

- `[(a,1),(a,1)] == [(a,1),(b,1)]` is `True`;
- the reverse is `False`.

What is wrong:

- An `Eq` instance that is not an equivalence relation is a latent trap for
  `nub`, `Map` keys and property tests.
- Python compares the parsed dicts, which are last-wins, so this does not
  match Python either.
- `typeExactEq` in the same module already does the right thing by comparing
  last-wins maps.

Better shape:

- Compare the last-wins maps, as `typeExactEq` does. This needs `O(n log n)`
  `Map.fromList` only when the lengths are equal, or always for simplicity.
- Add a property suite for reflexivity, symmetry and transitivity over a
  generator that produces duplicate keys.

| Churn | Wire risk |
|---|---|
| About 15 lines plus one property | None. Objects without duplicate keys compare exactly as before. |

### ELG-K-9 (minor): missing `NFData` instances force workarounds

Evidence:

- `petrus-impetus/src/Petrus/Impetus/Petrinet/Marking.hs:91` hand-writes
  `jsonRnf` because `Json` has no `NFData` instance.
- `Instance.hs:520` has `forcePrepared` use
  `evaluate (length (show prepared) `seq` prepared)` to deep-force an
  `ActivityInvocation`.

What is wrong:

- Forcing through `show` is surprising and costs a full render.
- The hand-written `rnf` belongs with the type, in `petrus-json`.
  `petrus-activity` already carries `deepseq`.

Better shape:

- `instance NFData Json` in `petrus-json`, derived through `Generic` or
  written once.
- `deriving anyclass NFData` on `ActivityInvocation` and its fields.
- `forcePrepared = evaluate . force`.

| Churn | Wire risk |
|---|---|
| About 20 lines | None |

### ELG-K-10 (minor): `recordInstant` and `recordOccurrence` are string lookups with a silent fallback

Evidence: `petrus-impetus/src/Petrus/Impetus/History/Records.hs`.

- `recordInstant` (474-477) looks up `("instant", FNumber i)` over
  `recordFields` and falls back silently with `[] -> 0`.
- `recordOccurrence` (481-482) is the same kind of lookup.
- `recordScope`, right next to them, uses a direct pattern match.

What is wrong: an accessor that can return a fabricated `0` instant for a
record without one hides bugs. The total pattern-match style used by
`recordScope` already sits beside it.

Better shape: write both as total `case record of` matches. A record kind with
no instant returns `Maybe`, or is structurally excluded.

| Churn | Wire risk |
|---|---|
| About 40 lines | None |

### ELG-K-11 (minor): `Instance.hs` is 2118 lines, and every door repeats the commit sequence

Evidence:

- Resume validation sits at about lines 704-1105 of `Instance.hs`.
- Every door repeats the sequence effective → `appendBatch` → `putState` →
  `emitEvent`.

What is wrong:

- The module mixes three concerns: the doors, the resume validator, and
  commit plumbing.
- The repeated commit sequence is where an ordering slip would hide.

Better shape:

- Move resume validation to `Petrus.Impetus.Instance.Resume`. It is already
  mostly pure.
- Add one `commit :: [Record] -> State -> [Event] -> Door ()` helper that
  fixes the current order. Keep that order exactly, because Python also
  applies movements after `extend`.
- Do not restructure the doors into a pure core. See "Considered, not
  recommended".

| Churn | Wire risk |
|---|---|
| A file move of about 400 lines, plus about 60 lines of call-site edits | None |

### ELG-K-12 (minor): documentation gaps

Evidence and fixes:

- `petrus-sqlite/DIVERGENCES.md:16` is stale. It says repr uses GHC's
  `generalCategory`, but `Petrus.Sqlite.PythonRepr` now re-exports
  `Petrus.Json.Repr`, which uses the CPython table. Update or delete the row.
- `petrus-cel` has no `DIVERGENCES.md`, although every other package in the
  slice has one. Its API-shape divergences appear only in haddocks:
  - errors are values, not exceptions;
  - the API is split into `compile` and `evaluateJson`;
  - a lone surrogate decodes to U+FFFD;
  - `Ops` has no identity shortcuts and no `MemoryError`.

  Collect them in a `DIVERGENCES.md`.

| Churn | Wire risk |
|---|---|
| Docs only | None |

### ELG-K-13 (minor): small local cleanups

Each item is low churn and carries no wire risk. They are worth doing in
passing, not as a project of their own.

- `petrus-impetus/src/Petrus/Impetus/Binding.hs:418` and `421-422`:
  `objectOf = Object` is an alias, and `foldlM'` is `flip foldM`. Inline both.
- `petrus-history-store/src/Petrus/HistoryStore/Sqlite.hs:134-137`:
  `expectedSql` indexes `historyDdl !! 0/2/3/4`. Name the DDL statements, for
  example as a record or as separate top-level bindings.
- `Postgres.hs:92` imports `HistoryStoreError` through
  `Petrus.HistoryStore.Jsonl`. Import it from its defining module.
- `petrus-sqlite/src/Petrus/Sqlite/Connection.hs:121` has two unclear fields:
  - `RequireWal Text WalRetry Bool` is a `Bool` flag. Use a two-constructor
    sum.
  - `RetryLocked Double Double` has unnamed fields. Use record fields or
    newtypes for the delay and the budget.
- `petrus-dsl/src/Petrus/Dsl.hs:315`: `handlerChange :: Maybe (Maybe
  HandlerSpec)` encodes "unset vs None". Use `data Change a = Keep | Set a`.
- `petrus-posix/src/Petrus/Posix/At.hs:194-198`: `fromFields` calls `error`
  on a field count that cannot occur. Use a fixed-arity pattern or a tuple so
  the impossible case cannot be written.

## DIVERGENCES review

- The rationales are sound overall, and the files are thorough.
- Each recorded divergence is either forced by the type system (errors as
  values, int/float distinction) or an explicit and pinned compatibility
  choice.
- Impetus item 20, the `model_construct`-style constructors, is justified by
  the 1996-case corpus.
- Impetus item 25 is sound.
- The `petrus-json` duplicate-keys row is sound. ELG-K-8 is about `Eq`, not
  about parsing.
- One row is stale: `petrus-sqlite:16` (ELG-K-12).
- One file is missing: `petrus-cel` (ELG-K-12).
- After ELG-K-1, JSONL needs no new divergence, because the fix restores
  reference behavior.

## What is already exemplary

- **CEL as a seam.** The kernel takes `CelCompilers` and has no dependency on
  CEL. `petrus-cel` itself is fully pure, with `Either Exc` throughout.
- **Purity in the types.**
  - `PureHandler` and `ActivityBound` are distinct types, and handlers return
    `Either`.
  - Diagnostics are values, not warnings.
  - `EnablednessError` is typed.
- **Selection policy.** `SelectionPolicy s` carries typed state, and the
  existential `StableRanker` carries an `Ord` constraint. This is cleaner
  than the reference's duck typing.
- **The DSL.**
  - A rank-2 brand prevents mixing nodes across nets.
  - The `Joins` type family checks joins at compile time.
  - `attempt` is atomic.
  - Specs are immutable values.
- **History.**
  - `mirroredHistoryStore` makes the rule that a write is durable before it
    is mirrored structural instead of a convention.
  - One shared `BackendContractSpec` runs against every backend.
- **Replay.**
  - Replay is a set of pure folds over `History`.
  - Property tests pin that the marking equals replay, and that resume is
    equivalent to a live run.
  - The suites are `KernelPropertiesSpec`, `InstanceReplayPropertiesSpec`
    and `NetDefinitionPropertiesSpec`.
- **Postgres.** The prepare cache is a pure state machine, and `Internal` is
  kept in `other-modules`.
- **SQLite.** Connection profiles are data.
- **Json.** It keeps the int/float distinction and exposes both `exactEq` and
  `typeExactEq`.
- **Smart constructors.** `LifecycleScope` is built through one.
- **Documented performance hacks.** The `casMutVar#` loop in the in-memory
  store and the `recentPath` pointer-equality cache in `petrus-posix` are
  localized and justified in comments. The global UUID counter is justified
  too.

## Considered, not recommended

These were weighed and rejected as not worth their churn or risk.

- **Rewriting the `Instance` doors as a pure core with an effect shell.** The
  nested commits in `failFiring` and Python's apply-after-extend order would
  make the pure core contort to preserve ordering. ELG-K-11 captures the
  useful part.
- **Typed `InstanceError` refusals instead of `Text`.** No downstream code
  branches on the message text. Typing them would touch every door and every
  test for no behavioral gain.
- **Opaque `NetDefinition` records.** The `model_construct` constructors are a
  documented divergence (item 20), and the corpus pins them.
- **A `Binding` sum type (`Scheduled | Delivered`).** It would ripple through
  the codec, replay and every door. ELG-K-6 removes the worst of the
  impossible states at a fraction of the cost.
- **Typed refusals instead of exceptions in the stores.** The `HistoryStore`
  record of IO actions with exceptions matches the reference's contract and
  `bracket` usage.
- **Splitting `Petrus.Cel.Ops`.** It is 1677 lines but cohesive: one
  operator table.
- **Removing the performance hacks.** They are measured, documented and
  local.
- **A single-fold resume.** Error precedence must match the reference, and
  the staged validator encodes it plainly.
- **Moving `GoldenTraces` and `Dot` out of the kernel library.** The
  dependency cost is small, and the move would churn the app and test
  imports.
