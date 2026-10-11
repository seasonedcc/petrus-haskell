# petrus-history-store: divergences from the Python reference

The JSONL bytes and the SQLite DDL, rows and payload spelling are identical
to the reference's in both directions. Files and databases written by either
implementation load, resume, and keep appending in the other; the interop
suites check this (`test/Petrus/HistoryStore/InteropSpec.hs`,
`test/Petrus/HistoryStore/SqliteInteropSpec.hs`). These are the
differences:

1. **A store is the kernel's record, not a class.** `openJsonlHistoryStore`
   returns the kernel's `HistoryStore`, which has these operations:
   - `snapshot :: IO (Seq Record)`
   - `count`
   - `extend`
   - `mode`

   `records` is an O(1) snapshot of a persistent sequence. The reference
   copies its list into a tuple. Nothing observable changes, because both
   are immutable views of the records appended so far.
2. **Errors are `HistoryStoreError`, not `ValueError`.** A load refusal, a
   torn tail, a blank line, a v1 or schema-2 line, or an unencodable record
   throws `HistoryStoreError` with the reference's exact message text. A
   load refusal is raised when the store is opened, before any Engine or
   Instance sees the records. The reference raises `ValueError` at the same
   point.
3. **Unencodable data is only non-finite numbers.** Token data, activity
   payloads and instants are `Json` and `Number`. The reference's other
   unencodable values (`object()`, sets) cannot be built, so the refusal path
   is reached only by NaN and ±Infinity. It fails loud before the file is
   opened, as in the reference.
4. **Durability is a separate, opt-in policy.** The default is the
   reference's posture: each batch opens, writes, and closes the file, with
   no fsync and no lock. It is durable across a process crash, and an
   Instance is its History's single writer. `JsonlOptions{durability =
   PowerFailure}` adds an fsync per batch, and of the parent directory when
   the file is created. The reference names this as a future swap at the
   same point (`jsonl.py`, "an explicit fsync is a future swap there"). The
   bytes are the same either way.
5. **Telemetry.** `jsonl_commit` carries the same fields as the reference:
   `records`, `bytes`, and `elapsed_ms`. The byte count is the same. The
   elapsed time differs, as it would between any two runs.
6. **Non-object payloads are refused with CPython's `dict()` text.** The
   reference's `decode_record` starts with `dict(payload)`. So a JSONL line
   or SQLite payload that is valid JSON but not an object is refused with
   the text `dict()` raises, for example `'int' object is not iterable` or
   `dictionary update sequence element #0 has length 3; 2 is required`. A
   list of two-element pairs is converted, as `dict()` converts it. Both
   stores reproduce these texts (`Petrus.HistoryStore.Internal.decodeStored`).
   There are two residual differences, both for payloads no writer produces:
   - A converted pair list whose header passes but which has a non-string
     key is refused with `keywords must be strings`, as the reference's
     `Record(**fields)` call refuses it. The reference first decodes each
     field, so a payload that also has a malformed field reports that
     field's error instead.
   - The reference's SQLite load then raises `AttributeError: 'list' object
     has no attribute 'get'` for a converted pair list. The port raises
     `HistoryStoreError` with the same text, because an `AttributeError`
     has no counterpart in the store's error types.

## SQLite

7. **A SQLite store is a record with an explicit `close`.**
   `openSqliteHistoryStore path instance` returns `SqliteHistoryStore`:
   - `history`, the kernel's `HistoryStore`;
   - `path` and `instanceId`;
   - `close`, which is idempotent.

   `withSqliteHistoryStore` brackets it. The reference's object is the
   store itself and has `close()`. The loaded mirror stays readable after
   `close` on both sides.
8. **Error types.** The reference's exceptions map as follows. The message
   text is the reference's in every case:
   - `ValueError` (a foreign or unsupported schema, a different fact at an
     event id or terminal, an undecodable row, an empty instance id, an
     unencodable record) is `HistoryStoreError`;
   - `RuntimeError` for a conflict that no stored row explains is the
     kernel's `UnverifiableConflict` (`Petrus.Impetus.HistoryStore`, shared
     with the PostgreSQL store);
   - `sqlite3.ProgrammingError` for an append after `close` is
     `ClosedDatabase`, with the text `Cannot operate on a closed database.`;
   - SQLite's own errors (a busy or locked database, IO errors) surface as
     direct-sqlite's `SQLError` (re-exported by petrus-sqlite), where the
     reference raises `sqlite3.OperationalError`.
9. **The instance id is `Text`.** The reference refuses a non-`str`
   instance with a `ValueError`. Here the type rules it out, and only the
   empty-string refusal remains, with the same text.
10. **The writer fence has no at-fork hook.** It lives in
    `Petrus.Sqlite.WriterFence` (petrus-sqlite) and is re-exported here. The
    reference registers an `os.register_at_fork` hook that closes inherited
    fence descriptors in a child. A forked Haskell child keeps the
    descriptor but refuses to use it: `ensureWriterFence` compares the PID
    and raises the reference's "inherited across fork" error. The
    petrus-engine-sqlite suite checks this with `forkProcess`. See also
    `packages/petrus-sqlite/DIVERGENCES.md`.
11. **The terminal lookup reads one row.** Verify-on-conflict looks the
    stored terminal up with the reference's exact statement and reads its
    first row. CPython's `fetchone` also pre-steps the statement to the next
    row. The answers are identical, and the port only skips that extra step.
    See `bench/RESULTS.md`, terminal-resend-ack.
