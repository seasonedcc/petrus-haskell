# petrus-history-store: parity with the Python reference

This package holds the durable History store backends behind the kernel's
`HistoryStore` contract. At this milestone that is the JSONL store
(`Petrus.HistoryStore.Jsonl`, the reference's `JsonlHistoryStore`). The
SQLite store has a reserved place and a written recipe in the
`Petrus.HistoryStore` module header.

Every Hspec example is named after the upstream test it ports. To cross-check
that every in-scope upstream test is accounted for, run:

    python3 packages/petrus-engine/scripts/parity_check.py

`cabal test petrus-history-store` runs 37 examples, with 0 failures and 0
pending. The interop examples are pending only when
`upstream/petrus/.venv` is not synced.

## Ledger

| upstream test | Haskell spec | status |
| --- | --- | --- |
| test_persistence.py `TestDurableAppend` (2) | JsonlSpec / `TestDurableAppend` | ported |
| test_persistence.py `TestJsonlHistoryStore` (10) | JsonlSpec / `TestJsonlHistoryStore` | ported |
| test_history_backends.py (14), with `reopen` = jsonl | BackendContractSpec | 13 ported, 1 enforced by types |

The rows of `test_history_backends.py` whose example names differ from the
upstream names:

| upstream test | Haskell example | status |
| --- | --- | --- |
| `TestRoundTrip.test_a_store_contains_history_without_being_history` | round trip / a store contains history | ported. The "without being History" half (`not isinstance(store, History)`) is enforced by types: a store is a record of operations. |
| `TestRoundTrip.test_durable_before_in_memory` | round trip / is durable before in memory | ported |
| `TestRoundTrip.test_nan_token_data_is_refused_loud_on_both_backends` | round trip / a refused (NaN) record fails loud and enters nothing | ported. The refusal text is asserted in JsonlSpec's "unencodable data fails loud and appends nothing". |
| `TestRoundTrip.test_an_unencodable_record_fails_loud_and_enters_nothing` | — | enforced by types. Token data is `Json`, and the only unencodable `Json` is a non-finite number, which is the NaN case. |

The `reopen` fixture's sqlite and postgres parameters wait for those
backends. When the SQLite store lands, it joins the same factory in
BackendContractSpec.

## Covered elsewhere or out of scope

- The other `test_persistence.py` classes are kernel tests, ported in
  `petrus-impetus`: `TestRecordCodec`, `TestInstanceDurableHistory`, and
  `TestARaisingAppendMovesNothingElse`.
- `test_sqlite_history.py` (11) and `test_postgres_history.py` (21) are out of
  scope for this milestone. The SQLite store goes in this package; see the
  `Petrus.HistoryStore` module header.

## Beyond upstream

- **Interop with the reference process** (InteropSpec, 4 examples). These run
  `test/interop/jsonl_interop.py` under `upstream/petrus/.venv`.
  - A file the reference wrote loads value-equal here and re-encodes
    byte-identically.
  - A file written here loads value-equal in the reference and re-encodes
    byte-identically.
  - An Instance the reference began resumes here, and the reference reads
    the result.
  - The same holds in the other direction.

  The Engine suite adds whole-Engine JSONL interop: identical bytes, plus
  cross-process crash and resume in both directions.
- **Load edges of the reference's text-mode reader** (5 examples):
  - a final line without a terminator;
  - CRLF and CR read as universal newlines;
  - an empty file;
  - a blank line, refused with CPython's diagnostic;
  - a record decode failure that carries the codec's message.
- **`jsonl_commit` telemetry.** There is one event per durable commit, with
  its batch size and bytes, as `jsonl.py` emits.
- **`PowerFailure` durability.** It writes the same bytes; fsync is the only
  difference.
- **The kernel contract through the file.** An Instance's every appending door
  is driven through a JSONL store.
