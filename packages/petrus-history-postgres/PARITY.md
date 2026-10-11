# petrus-history-postgres: parity with the Python reference

This package ports `petrus.impetus.history_store.postgres` at the pin in
[UPSTREAM.md](../../UPSTREAM.md): `ensure_schema` (`ensureSchema`, the same
five DDL statements byte for byte) and `PostgresHistoryStore`
(`openPostgresHistoryStore`). It is kept out of `petrus-postgres`, which
stays kernel-free (docs/runtime.md §14.2).

Every Hspec example is named after the upstream test it ports. To cross-check
that every in-scope upstream test is accounted for, run:

    python3 packages/petrus-engine/scripts/parity_check.py

`cabal test petrus-history-postgres` runs 60 examples. With
`PETRUS_TEST_POSTGRES` set (CI sets it), all 60 pass. Without it, the 57
examples that need a server are pending and say why, the same way upstream's
`postgres` marker skips. Each group of examples gets its own scratch database
(`Petrus.TestSupport.postgresSpec`), which is dropped afterwards.

## Ledger

| upstream test | Haskell spec | status |
| --- | --- | --- |
| test_postgres_history.py (21, all `postgres`-marked, none parametrized) | PostgresSpec / `TestEnsureSchema`, `TestBackendShape`, `TestTransactionalBatches`, `TestVerifyOnConflict`, `TestCallerTransactionJoin`, `TestDecodeFailsLoudAtLoad` | 21 ported |
| test_history_backends.py (14), with `reopen` = postgres | the shared BackendContractSpec (compiled in from `petrus-history-store/test`), instantiated as `backend contract (postgres)` | 13 ported, 1 enforced by types |
| test_package_boundaries.py, the 2 PostgreSQL History rows | BoundarySpec | 2 ported over Cabal metadata |
| rules/history-store-postgres-provider-boundary.yml (ast-grep rule) | BoundarySpec / provider boundary | ported over the module's imports |

The `test_history_backends.py` tests run through the shared contract under
these example names. Each is a fresh store over the same instance on one
connection, which is the upstream `reopen` fixture's postgres parameter.

| upstream test | Haskell example | status |
| --- | --- | --- |
| `TestRoundTrip.test_a_store_contains_history_without_being_history` | round trip / a store contains history | ported. The "without being History" half is enforced by types. |
| `TestRoundTrip.test_every_record_category_round_trips_value_equal` | round trip / every record category round-trips value-equal | ported |
| `TestRoundTrip.test_append_and_extend_accumulate_and_a_reload_continues` | round trip / append and extend accumulate, and a reload continues | ported |
| `TestRoundTrip.test_durable_before_in_memory` | round trip / is durable before in memory | ported |
| `TestRoundTrip.test_an_unencodable_record_fails_loud_and_enters_nothing` | — | enforced by types. The only unencodable `Json` is a non-finite number, which is the NaN case below. |
| `TestRoundTrip.test_nan_token_data_is_refused_loud_on_both_backends` | round trip / a refused (NaN) record fails loud and enters nothing | ported. The exact refusal text is checked in PostgresSpec / beyond upstream. |
| `TestRoundTrip.test_a_mid_batch_encode_failure_writes_nothing` | round trip / a mid-batch encode failure writes nothing | ported |
| `TestInstanceParity.test_construction_over_a_recorded_history_is_rejected` | Instance parity / construction over a recorded history is rejected | ported |
| `TestInstanceParity.test_a_full_drive_kills_and_resumes_identical` | Instance parity / a full drive kills and resumes identical | ported |
| `TestInstanceParity.test_the_occurrence_counter_resumes_past_every_recorded_id` | Instance parity / the occurrence counter resumes past every recorded id | ported |
| `TestInstanceParity.test_the_accepted_identity_index_resumes_from_the_records` | Instance parity / the accepted-identity index resumes from the records | ported |
| `TestInstanceParity.test_the_terminal_activity_index_resumes_from_the_records` | Instance parity / the terminal-activity index resumes from the records | ported |
| `TestKillWindowParity.test_killed_after_the_begin_batch_resumes_and_redispatches` | kill-window parity / killed after the begin batch: resumes and redispatches | ported |
| `TestKillWindowParity.test_killed_after_the_frozen_result_resumes_projection_pending` | kill-window parity / killed after the frozen result: resumes projection-pending | ported |

## Beyond upstream

- **The shared backend contract, beyond upstream** (1 example): an integer
  over CPython's 4300-digit limit is refused with the `cannot durably encode`
  text and enters nothing, as on JSONL and SQLite.
- **PostgresSpec / beyond upstream** (7 examples):
  - an autocommit connection is `BackendOwned`;
  - the `postgres_commit` telemetry event carries the batch size and the entered count;
  - the exact NaN refusal text;
  - a refused append in join mode;
  - U+0000 in token data is refused by the server (SQLSTATE 22P05) and enters nothing;
  - `1e16` reads back as the integer jsonb stores, and a stale writer still acknowledges it value-equal (Python equality);
  - event ids are dense positions.
- **Interop with the reference process** (InteropSpec, 15 examples). These
  run `test/interop/postgres_history_interop.py` under the pinned
  `upstream/petrus/.venv`, on the same scratch database.
  - Spelling and schema:
    - the DDL statements are the reference's `_DDL`, byte for byte;
    - every record's payload parameter is the reference's `json.dumps(encode_record(r), allow_nan=False)`, byte for byte;
    - the `impetus` catalog is identical whichever implementation provisions it (columns, defaults, constraints, indexes including the partial ones, sequences), and each `ensure_schema` is idempotent over the other's.
  - Rows:
    - the reference's rows load value-equal here, and the reverse holds;
    - both implementations write identical rows: event ids, types, occurrences, and stored jsonb text;
    - one history extended in turn by both languages loads identically in each.
  - Verify-on-conflict across languages:
    - a stale writer in either language acknowledges the other's value-equal fact, and refuses a different one with the same text;
    - racing a Python process and a Haskell thread on the same facts, every round succeeds for both and each position holds one row;
    - racing them on different facts, exactly one wins and the loser is refused, naming the winner's fact (6 races).
  - Transactions and doorbells:
    - a joined batch in either language is invisible to the other until commit, and gone after rollback;
    - an `impetus_dispatch` NOTIFY issued in the same joined transaction reaches the other language's listener only on commit, never on rollback, and the batch is durable when it arrives. This holds in both directions.
- **Package boundaries** (BoundarySpec, 3 examples; see the ledger).

## Benchmarks

See [bench/RESULTS.md](bench/RESULTS.md). Every row is faster than the pinned
Python in wall-clock time over six interleaved repetitions: 1.24× to 2.6× against a
native PostgreSQL 17, with statements prepared from their sixth execution as
psycopg prepares them (petrus-postgres's prepared-statement cache).
