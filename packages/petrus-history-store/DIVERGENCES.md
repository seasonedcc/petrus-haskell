# petrus-history-store: divergences from the Python reference

The JSONL bytes are identical to the reference's in both directions. Files
written by either implementation load, resume, and keep appending in the
other; the interop suites check this. These are the differences:

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
6. **The SQLite store is not here yet.** Its place, contract steps, and test
   plan are written in the `Petrus.HistoryStore` module header.
