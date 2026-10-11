# hamsterdan-contracts divergences

These are the intentional differences from `upstream/hamsterdan`. None of them
changes a wire format. Every JSON spelling, admission decision, `repr` text and
digest is checked byte for byte against the pinned Python (see
[PARITY.md](PARITY.md)).

## API and representation

1. **`Literal` vocabularies are Haskell enumerations.**
   - Upstream fields typed `Literal["running", "quiescent", ...]` are plain
     `str` at runtime. Here they are sum types such as `Phase`, `ReviewStatus`
     and `MutationKind`, with one constructor per spelling.
   - An invalid state cannot be constructed. Decoding still refuses exactly the
     spellings pydantic refuses.
   - A field whose `Literal` admits a single value (a fact's `kind`, a body's
     `status`) has no Haskell field at all. The codec writes and checks the
     constant, so it cannot be set wrong.
2. **Unions are sum types.**
   - Smart-mode unions of disjoint models (`ReviewFactBody`, `ReminderClock`,
     ...) decode to the first member that admits the input, as pydantic does.
   - The encoder dispatches on the constructor instead of inspecting the
     instance.
   - `tuple[int, int] | tuple[()]` is `Maybe (Integer, Integer)`.
3. **`validated_update` is record update.**
   - Python's `validated_update(**changes)` dumps, merges, re-encodes and
     revalidates, so a copy cannot carry a wrong type or an unknown field.
   - In Haskell, record update syntax gives both guarantees at compile time.
   - The one runtime normalization, `ActionsObservation.__post_init__`, is
     applied by the codec when decoding and again when encoding. A value built
     in Haskell with an empty `observation` therefore still dumps
     `"{run_id}:{attempt}:{conclusion}"`, as Python would after revalidation.
   - The equivalence rests on `validate . dump == Right` for every contract,
     which `test/RoundTripSpec.hs` checks as a Hedgehog property over
     generated values. The readiness folds (hamsterdan-readiness `NetV5.*`)
     rely on it to use record syntax wherever the reference calls
     `validated_update`.
4. **`project_readiness` takes one `Concerns` record.**
   - Python takes the nine concern tokens positionally and builds the snapshot
     with `ReadinessSnapshot(**merged)`.
   - `projectReadiness` builds the snapshot field by field from a record, so the
     compiler checks that the nine concerns partition the snapshot.
   - `test_readiness_state_tokens_partition_snapshot_fields` only checks this at
     runtime.
5. **`AgentRunner` is a record of capabilities**, not a structural
   `Protocol`.
   - Its keyword arguments (`operation`, `attempt`, `is_current`) travel as an
     `Invocation`.
   - `AgentProtocolError`'s category arguments are typed, so the constructor's
     `TypeError` for a category outside the closed vocabulary cannot happen.
   - `retain_*_category` returns an updated value instead of mutating the
     exception.
6. **The protocol records have strict decoders.** Upstream never decodes them
   generically: `_validate_result` builds results field by field, and that
   validation is ported in `hamsterdan-agents`. The decoders here are an
   addition for fixtures and tooling. They use the same strict rules as the
   pydantic contracts, with the dataclass defaults for omitted fields.

## Errors

7. **Decode errors report the first failure.**
   - pydantic collects every error. `DecodeError` names one path and reason:
     an unknown member first, then fields in declaration order.
   - Only whether an input is admitted is compared with Python (thousands of
     corpus rows). Error texts are not part of any wire format; Hamsterdan logs
     or wraps them.
   - Why it stays: no pydantic text reaches an output. The host's call sites
     (`v5/ingress.py`, `review.py`, `runtime.py`, `timers.py`) catch
     `ValidationError` and raise their own fixed text `from None`, and where
     one propagates into a firing, the engine records
     `ValidationError()`, which hamsterdan-readiness reproduces. Reporting
     every error would mean reproducing pydantic-core's report format
     (truncated `input_value` reprs, `errors.pydantic.dev` links) for no
     reader.
8. **`literalEval` collapses `SyntaxError` and `ValueError` into
   `Malformed`.** `board.py` catches both the same way (it skips the entry).
   `TypeError` from an unhashable dict key stays separate as `Unhashable`,
   because it propagates in Python.

## Unmodeled Python values

9. **`Unsupported` literals.**
   - CPython's `literal_eval` also returns bytes, complex numbers, sets and
     `Ellipsis`.
   - Strings with lone surrogates are no longer among them (resolved). An
     escaped one (`'\ud800'`) is kept in the `str`, unpaired, as WTF-8
     ("Petrus.Json.Wtf8"); a raw one in the source is `Malformed`, the
     `UnicodeEncodeError` (a `ValueError`) CPython's compiler raises
     encoding the source. The corpus has both forms.
   - No Hamsterdan body contains any of these, so `PyValue` does not model them.
     `literalEval` reports `Unsupported` where CPython would return a value.
     The corpus checks that the Haskell side says `Unsupported` exactly where
     Python returned one of these types.
   - CPython validates its sub-expressions in a particular order: a set
     containing an unhashable value raises `TypeError`, and a malformed element
     inside a set is still `Malformed`. The parser keeps that order.
10. **`\N{name}` escapes are `Unsupported`.**
    - Resolving them needs the Unicode name database, which would add a large
      table for a form Hamsterdan never prints (`repr` never emits `\N`).
    - A well-formed `\N{...}` is reported `Unsupported`; a malformed one is
      `Malformed`, as in CPython.
    - The corpus contains such sources. The suite accepts `Unsupported` for
      them and checks every other source exactly.
11. **An unhashable `disposition` is "not open".**
    - In `workflow_gates_ready`, Python evaluates
      `finding.get("disposition") in {"new", "still_open"}`, which raises
      `TypeError` when a blocking finding's disposition is a list or dict.
    - `workflowGatesReady` treats such a finding as not open and stays total.
    - No contract produces such a finding: dispositions are written by
      Hamsterdan as strings.
12. **JSON bodies print as JSON values.**
    - `dictEntry` and `sortedItemsDigest` take the body as `Json`, which is how
      bodies travel through History.
    - A body that held a Python tuple in memory would print `(...)` in Python.
      No V5 fact body holds one. For such a value, build a `PyValue` and use
      `repr`.

## Toolchain

13. **The corpora come from Python 3.14.6.**
    - Hamsterdan's container pins Python 3.14.7. The `uv` environment on the
      corpus machine resolved 3.14.6, the newest 3.14 available there.
    - Nothing used differs between the two patch releases: `repr`,
      `ast.literal_eval`, the `json` module and the Unicode 16.0.0
      `isprintable` table.
    - pydantic (2.13.4) and pydantic-core (2.46.4) are exactly the `uv.lock`
      pins.

## Changes to `petrus-json` made for this package

These keep `petrus-json`'s behavior and its tests unchanged, and add property
tests. They were needed to meet the benchmark bar:

- The parser returns an unboxed `(value, offset)` product instead of
  `Either String (Json, Int)`.
- Strings are scanned eight bytes at a time and plain ASCII is copied
  directly.
- Short integers are parsed in machine `Int`.
- Duplicate members are found by a quadratic check for at most 8 members, or
  else by an open-addressing hash pre-check with an exact fallback.
- `dumps` measures the document exactly and writes it into one buffer. The
  streaming `dumpsBuilder` remains.

The new properties in `packages/petrus-json/test/Main.hs` cover:

- string round trips at every offset and in every escaping mode;
- integers of every size;
- first-position/last-value duplicates, and rejection of duplicates;
- `dumps` and `dumpsBuilder` spelling the same bytes under seven option sets.
  Those values include non-finite floats, huge integers, and every kind of
  escape.
