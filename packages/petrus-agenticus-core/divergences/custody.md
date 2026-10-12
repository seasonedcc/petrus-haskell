# Connection custody divergences

These choices are deliberate. The shared error model and value conventions
are covered in `divergences/catalog.md`.

None of the choices below changes a stored byte, a refusal class, or a
refusal message for any state the reference writer can produce. The custody
corpus and the cross-implementation interop spec pin that (see
`parity/custody.md`).

## Secrets and buffers

1. **Erasable buffers are `ScrubbedBytes`.** The reference passes plaintext
   as a `bytearray` and zeroes it in place. The port uses `ScrubbedBytes`
   (from `ram`), and `eraseBuffer` zero-fills it in place.

   - `KeyOperations.seal` takes the buffer, and `open` returns one.
   - Results computed from a plaintext buffer are forced before it is
     erased. Otherwise laziness could read zeroes.
   - `newOpaqueState` copies a `ByteString`. `opaqueStateFromBuffer` takes
     ownership of a buffer, so erasing it erases the caller's buffer. This
     matches `OpaqueState(bytearray)`.

2. **Reads.** `readState` returns an immutable `ByteString` copy, which the
   GC never zeroes. The reference returns `bytes`, which has the same
   property. `readStateScrubbed` and `readMaterializedScrubbed` return an
   erasable buffer instead, and the custody uses those internally. The
   file is read in 64 KiB scrubbed chunks, and each chunk is erased.

3. **Redacted `Show`.** `OpaqueState`, `MaterializedState` and
   `Materialization` render as `OpaqueState(<redacted>)` and
   `MaterializedState(<private>)`. `Materialization(...)` shows the same
   fields as the reference `repr`.

   The reference `repr` also says `<erased>` or `<present>`, which needs a
   filesystem or flag read. A pure `show` cannot do that, so
   `renderOpaqueState` and `renderMaterializedState` (both `IO`) give the
   exact reference text.

## Host boundaries

4. **The logger is a callback.** The reference logs at INFO to
   `petrus.agenticus.connection.custody`. The port calls the sink installed
   with `withCustodyLogger`, which is a no-op by default. The text is the
   same `"%s operation=%s connection=%s host=%s lease=%s"` line, with `-`
   for absent subjects.

5. **The clock is `IO Double`.** A non-finite reading is refused with
   `custody clock must be a finite number`, as `_finite_time` does. Python
   type checks on the clock's return value (`bool`, non-number) cannot arise.

6. **`KeyOperations` is a record of functions,** where the reference uses a
   `Protocol`. A host failure is any exception. The custody propagates it
   unchanged, as the reference does.

7. **Keyword-only `operation_id`** is the last positional argument.
   `connection()` is named `lookupConnection`, because `connection` is a
   common field name.

## SQLite

8. **Driver.** The reference uses CPython's `sqlite3`. The port goes through
   `Petrus.Agenticus.Internal.Sqlite` over the shared `petrus-sqlite`
   connection (`direct-sqlite` 2.3.29, which bundles SQLite 3.45.0). The
   reference venv links 3.53.4.

   - The DDL text, the pragmas, the transaction shape and the stored bytes are
     identical, and the corpus checks `sqlite_master.sql`.
   - Driver errors surface as `AgenticusError (OtherError "<class>")`. The
     class is the one CPython's `_pysqlite_seterror` would pick (for example
     `OperationalError` for `SQLITE_BUSY`), and the message is
     `sqlite3_errmsg`.
   - Using a closed storage raises `ProgrammingError` with
     `Cannot operate on a closed database.`. Closing twice is harmless.
   - Statements run through the connection's prepared-statement cache, as
     CPython's `sqlite3` keeps one per connection.

9. **Busy timeout.** The reference calls `sqlite3.connect(timeout=5)`, which
   uses the C `sqlite3_busy_timeout`. direct-sqlite does not expose that, so
   `petrus-sqlite` runs `PRAGMA busy_timeout = 5000` as the connection opens,
   which installs the same handler before any other statement.
   `test/Petrus/Agenticus/SqliteSpec.hs` checks both sides under the same
   lock, including `timeout=0` failing at once.

10. **`openSqliteConnectionStorageWith`** is a port-only, additive entry
    point. It runs extra statements, such as `PRAGMA synchronous = OFF`,
    after the reference pragmas. It exists only so the benchmark can separate
    CPU cost from fsync cost. Production code uses
    `openSqliteConnectionStorage`.

## Performance-only changes (no observable difference)

11. **One validation per publish, not four.** For every commit the reference
    validates the loaded snapshot twice (`_decode`, then `_load`) and the
    replacement twice (`compare_and_swap`, then `_encode`). The port gets
    the same verdicts with less work:

    - `compareAndSwap` validates once and then renders the payload.
    - Each storage connection keeps the last payload text it read or wrote,
      with its decoded snapshot. A load that reads byte-identical text
      reuses that snapshot instead of parsing it again. Any other text is
      decoded and validated as usual. After a successful CAS the cached pair
      is (written text, replacement), which is sound because decoding the
      encoding of a valid snapshot yields that snapshot. The corpus and
      interop specs exercise this round trip on every step.
    - The SQLite storage vouches for its loads: every snapshot it answers
      was validated when it was decoded or by its own `compareAndSwap`, so
      it offers `trustedLoad`, which yields a `ValidatedSnapshot` (a newtype
      only the storage module builds) that custody accepts without checking
      again. A host-supplied `ConnectionStorage` sets `trustedLoad =
      Nothing`, and custody validates each of its loads, as upstream does.

    All three are transparent. The SQLite row is still read on every load,
    so a concurrent writer is always seen.

12. **Pre-sorted payload members.** `snapshotToJson` emits every object's
    members in `sort_keys` order: code-point order, with detail names
    deduplicated as a Python dict would. The encoder therefore runs with
    `sortKeys = False` and produces the same bytes.

## Hostile payloads (states the reference writer never produces)

13. **Lone surrogates (resolved).** A payload with a `\ud800`-style escape
    decodes, as in Python, to a string `_stored_text` accepts (a WTF-8
    `Text`, `Petrus.Json.Wtf8`), and re-encodes to the same escape. The
    custody corpus pins a surrogate host id, audit detail value and detail
    name.

14. **Integers.** Wire integers are `Integer`. An integer token of more than
    4300 digits fails `json.loads`, so the payload is invalid, as in Python
    (pinned by the corpus).

    The `revision` column is read with Python's `int(row[0])` semantics (see
    `pythonInt`): an integer column is used as is, a float is truncated, and
    text is parsed. A huge integer in the payload that Python would turn
    into an `OverflowError` elsewhere stays an `Integer` here.

15. **Duplicate members** use last-wins, like `json.loads`, through
    petrus-json's `surrogateRefusingLoads`. That includes duplicate detail names.
