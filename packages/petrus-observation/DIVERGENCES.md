# petrus-observation: divergences from the Python reference

Every projection matches the reference exactly:

- the protocol-v1 snapshot;
- the History page;
- the observed and inspection Net documents;
- the definition body;
- the marking.

Exactly means the same members, in the same insertion order, with the same
int/float spelling. Fixture files match byte for byte (see `PARITY.md` and
the differential corpus). Every refusal the reference raises carries the same
full message text. The entries below are where the Haskell API differs on
purpose.

Pinned reference: `upstream/petrus` (`src/petrus/impetus/observation.py`).

## 1. The Engine seam: capture, then project

The reference's projections take a live `Instance` and its `records` tuple.
The Engine calls them under its lock, so one door reads a coherent state:
`frontier == len(records)` agrees with `current`.

This package does not depend on an Engine (neither does the reference
module). It splits each read door into two steps:

    capture        :: Instance -> IO Observation              -- reads, needs writer exclusion
    snapshot       :: Observation -> Either ObservationError Json
    historyPage    :: Text -> Seq Record -> Integer -> Integer -> Either ObservationError Json
    netDocument    :: Observation -> Either ObservationError Json

- **`captureInstance` / `capture`** read the Instance's public accessors once
  (`marking`, `status`, `watermark`, `inFlight`, `pendingActivityOutcomes`,
  `armed`, `nextMaturation`, plus the identity and net) and its History
  mirror (`HistoryStore.snapshot`). They return immutable values.
- **The projections** are pure functions of those values.

An Engine must run `capture` while no writing door is active, which is what
the reference's lock gives a reader that arrives mid-door. The projection can
then run outside the lock. The upstream tests of that exclusion, re-entry,
and commit poisoning belong to the Engine and are deferred (see `PARITY.md`).

`ObservedInstance.frozen` is the reference's private
`Instance._frozen_results`. The kernel already exposes it as
`pendingActivityOutcomes`, so no new kernel read was needed.

## 2. Detachment is by construction

The reference deep-copies and round-trips through `json.dumps`/`json.loads`,
so later mutation of a result dict, token data or the Instance can't reach a
returned snapshot. Haskell `Json` values are immutable, so a captured value
is already detached. The tests that mutate afterwards keep their assertions
on the captured values. They have no mutation step.

## 3. Cases that can't be represented

- **Unencodable data.** Python accepts `object()` as token data, as a net
  name, or as a timer value. Here token data and Activity values are `Json`,
  names are `Text`, and timers and instants are a `Number`. So the
  `object()`, `True` and `"1"` cases are enforced by types.
- **Booleans.** A `True` watermark and `Until(True)` can't be built. The
  reachable non-integer is a float. It is refused with the reference's own
  message ("protocol 1 requires current watermark|next maturation to be an
  integer, got 7.5"), which the corpus records.
- **Strictness.** The reference's `_strict` is `json.dumps(allow_nan=False)`.
  Here it is a scan for the first non-finite `Float`, with the same message
  (`observation data must be strict JSON-faithful: Out of range float values
  are not JSON compliant: nan|inf|-inf`). The scan runs in the same order as
  the reference: watermark, next maturation, definition, marking, then the
  whole payload.

## 4. The History cursor: typed and Json-level

`history_page(instance_id, records, after, limit)` validates Python values:
it refuses a `bool`, a non-`int`, a negative `after`, and a non-positive
`limit`. Here there are two layers:

- **`historyPage`** takes `Integer`s and refuses negative and zero values and
  a future cursor with the reference's messages.
- **`historyCursor :: Json -> Json -> Either ObservationError (Integer,
  Integer)`** validates untyped cursor values (`True`, `0.5`, `1.5`, …). It
  refuses them with the reference's messages, Python `repr` included
  (`got True`, `got 0.5`). A transport that parses query parameters into Json
  should call it before `historyPage`.

## 5. `snapshotWith` (an addition)

`snapshot` re-projects the definition on every call, as the reference does.
`snapshotWith body` takes an already-projected definition body: a net never
changes during an Instance's life, so an Engine can project it once. The
result is identical to `snapshot` (a seam test checks this).

## 6. The observed Net document's token validation

The reference validates each replayed marking entry with
`PlaceMarking.model_validate(entry, strict=True)` before building the
lineage. An unsafe integer in token data is therefore refused with pydantic's
`1 validation error for PlaceMarking …` text.

To reproduce that exactly, `petrus-impetus` gained one additive export:
`Petrus.Impetus.NetDocument.placeMarkingFromJson :: Json -> Either Text
PlaceMarking`. It reuses the module's existing `validatePlaceMarking` and
`renderValidationError`. No existing definition changed.
