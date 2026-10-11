# petrus-history-store: parity with the Python reference

This package holds the durable History store backends behind the kernel's
`HistoryStore` contract:
- the JSONL store (`Petrus.HistoryStore.Jsonl`, the reference's
  `JsonlHistoryStore`);
- the SQLite store (`Petrus.HistoryStore.Sqlite`, the reference's
  `SqliteHistoryStore`), with the SQLite writer fence re-exported from
  petrus-sqlite.

Every Hspec example is named after the upstream test it ports. To cross-check
that every in-scope upstream test is accounted for, run:

    python3 packages/petrus-engine/scripts/parity_check.py

`cabal test petrus-history-store` runs 134 examples, with 0 failures and 0
pending. The interop examples fail, never skip, when `upstream/petrus/.venv`
cannot be provisioned. By file:

| spec | examples |
| --- | ---: |
| JsonlSpec (JSONL, upstream and beyond) | 26 |
| BackendContractSpec (jsonl and sqlite, 14 each: 13 upstream, 1 beyond) | 28 |
| InteropSpec (JSONL interop) | 8 |
| SqliteSpec (`test_sqlite_history.py` 14, beyond upstream 5) | 19 |
| SqliteInteropSpec (SQLite interop) | 53 |

## Ledger

| upstream test | Haskell spec | status |
| --- | --- | --- |
| test_persistence.py `TestDurableAppend` (2) | JsonlSpec / `TestDurableAppend` | ported |
| test_persistence.py `TestJsonlHistoryStore` (10) | JsonlSpec / `TestJsonlHistoryStore` | ported |
| test_history_backends.py (14), with `reopen` = jsonl | BackendContractSpec / `backend contract (jsonl)` | 13 ported, 1 enforced by types |
| test_history_backends.py (14), with `reopen` = sqlite | BackendContractSpec / `backend contract (sqlite)` | 13 ported, 1 enforced by types |
| test_sqlite_history.py (11 tests, 14 cases) | SqliteSpec / `test_sqlite_history.py` | 11/11 ported |

The rows of `test_sqlite_history.py` keep the upstream names, with
underscores read as spaces. Its two parametrized tests are `describe` blocks
with one example per parameter:
- `test_unsupported_schema_refuses_without_mutation` has `version 0` and
  `version 2`;
- `test_fresh_constructor_refuses_corrupt_durable_rows` has `gap`,
  `payload` and `metadata`.

`test_concurrent_first_initialization_for_distinct_instances` starts
threads in the reference. Here it starts Haskell threads, and
SqliteInteropSpec repeats it with three reference processes racing three
Haskell threads on one fresh file.

The rows of `test_history_backends.py` whose example names differ from the
upstream names:

| upstream test | Haskell example | status |
| --- | --- | --- |
| `TestRoundTrip.test_a_store_contains_history_without_being_history` | round trip / a store contains history | ported. The "without being History" half (`not isinstance(store, History)`) is enforced by types: a store is a record of operations. |
| `TestRoundTrip.test_durable_before_in_memory` | round trip / is durable before in memory | ported |
| `TestRoundTrip.test_nan_token_data_is_refused_loud_on_both_backends` | round trip / a refused (NaN) record fails loud and enters nothing | ported. The refusal text is asserted in JsonlSpec's "unencodable data fails loud and appends nothing". |
| `TestRoundTrip.test_an_unencodable_record_fails_loud_and_enters_nothing` | — | enforced by types. Token data is `Json`, and the only unencodable `Json` is a non-finite number, which is the NaN case. |

The `reopen` fixture's sqlite parameter runs the same 13 examples through
`SqliteHistoryStore`. Its postgres parameter runs in
`petrus-history-postgres`, which instantiates the same `backendContract`.

## Covered elsewhere or out of scope

- The other `test_persistence.py` classes are kernel tests, ported in
  `petrus-impetus`: `TestRecordCodec`, `TestInstanceDurableHistory`, and
  `TestARaisingAppendMovesNothingElse`.
- `test_postgres_history.py` (21) is ported in `petrus-history-postgres`.
- The SQLite writer fence's own tests are in petrus-sqlite, and the fenced
  Engine's (`test_sqlite_engine.py`) are in petrus-engine-sqlite.

## Beyond upstream

- **Interop with the reference process** (InteropSpec, 8 examples). These run
  `test/interop/jsonl_interop.py` under `upstream/petrus/.venv`.
  - A file the reference wrote loads value-equal here and re-encodes
    byte-identically.
  - A file written here loads value-equal in the reference and re-encodes
    byte-identically.
  - An Instance the reference began resumes here, and the reference reads
    the result.
  - The same holds in the other direction.
  - Lone surrogates (4 examples): the reference's `json.dumps` writes a `str`
    holding one as `"\ud800"`, in token data, a member name, a delivery
    identity, an Activity result and a failure text. Both stores read
    with `historyLoads`, which keeps them as WTF-8 `Text` (petrus-json
    DIVERGENCES.md), so such a file loads value-equal here and re-encodes
    byte-identically, a file written here loads value-equal in the
    reference, and an Instance begun on either side with such token data
    resumes on the other.

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

- **Every `json.dumps` refusal fails loud** (BackendContractSpec, one
  example per backend). An integer over CPython's 4300-digit limit in token
  data is refused with the backend's `cannot durably encode …` text, on
  JSONL, SQLite and PostgreSQL alike, and the stored history is unchanged;
  JSONL's encoder is a single `Either` pass over `dumpsBuilder`, as
  `jsonl.py`'s `_encoded_line` catches every `json.dumps` error (it used to
  check only non-finite floats and write an empty line for the rest).

### SQLite

- **SqliteSpec, beyond upstream** (5 examples):
  - closing is idempotent, a closed store refuses appends, and the mirror
    stays readable;
  - an empty batch commits and enters nothing;
  - an equal terminal held elsewhere is acknowledged and later positions
    stay dense;
  - a conflict no stored row explains is the `RuntimeError` case;
  - the exotic record's payload is the compact ASCII spelling.
- **Interop with the reference process** (SqliteInteropSpec, 53 examples).
  These run `test/interop/sqlite_interop.py` under `upstream/petrus/.venv`.
  - Every record category, both ways: rows written by one side load
    value-equal in the other, with byte-identical payloads.
  - Lone surrogates, both ways (4 examples), as for JSONL: records and
    Instances whose strings hold them, with byte-identical payloads.
  - Fresh files created by each side dump identically: DDL text in
    `sqlite_master`, schema rows, and event rows apart from `recorded_at`.
  - Interleaved appends from both sides to one file stay dense and agree.
  - Verify-on-conflict gives the same answer on copies of one file (4
    cases), and a stale writer is refused with the same text on both
    sides.
  - Refusals of foreign, unsupported and corrupt files have the same type
    and text (36 cases). These include 17 stored payloads that are not
    objects, refused with CPython's `dict()` texts.
  - The empty instance id has the same refusal text.
  - First initialization under three reference processes and three Haskell
    threads racing on one file.
  - Crash and resume in both directions: an Instance begun by one side
    resumes in the other, which then reads the result.
