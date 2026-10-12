# petrus-engine-sqlite: parity with the Python reference

This package holds the fenced local SQLite Engine composition
(`Petrus.Engine.Sqlite`, the reference's `petrus.engine.sqlite`):
`createEngine`, `loadEngine` and `openSqliteEngine`. It is built on:
- petrus-engine's provider seam (`openEngine` with `EngineResources`);
- petrus-history-store's `SqliteHistoryStore`;
- petrus-sqlite's writer fence;
- petrus-motus's Local Dispatch, which can share the database file.

Every Hspec example is named after the upstream test it ports. To cross-check
that every in-scope upstream test is accounted for, run:

    python3 packages/petrus-engine/scripts/parity_check.py

`cabal test petrus-engine-sqlite` runs the suite with no failure and no pending example.
The interop examples provision the pinned reference through
`scripts/upstream-python` and fail, never go pending, when they cannot. By
file:

- SqliteSpec (`test_sqlite_engine.py`'s 5 tests, and checks beyond upstream);
- SqliteInteropSpec (interop with the reference process).

## Ledger

| upstream test | Haskell example | status |
| --- | --- | --- |
| `test_fenced_engine_refuses_same_database_and_instance_then_releases` | test_sqlite_engine.py / fenced engine refuses same database and instance then releases | ported |
| `test_fenced_engines_scope_authority_by_database_and_instance` | test_sqlite_engine.py / fenced engines scope authority by database and instance | ported |
| `test_writing_door_poison_releases_sqlite_resources` | test_sqlite_engine.py / writing door poison releases sqlite resources | ported |
| `test_spawned_process_contention_and_holder_death_release` | test_sqlite_engine.py / spawned process contention and holder death release | ported. The holder is the test binary re-executed in a `hold` role, where the reference uses `multiprocessing` spawn ([DIVERGENCES 4](DIVERGENCES.md)). |
| `test_forked_engine_refuses_and_child_does_not_retain_fence` | test_sqlite_engine.py / forked engine refuses and child does not retain fence | ported with `forkProcess`. The child's Engine refuses with the "inherited across fork" text. After the parent closes, the Instance loads again while the child is still alive, so the child does not retain the fence ([DIVERGENCES 3](DIVERGENCES.md)). |

`test_sqlite_engine.py` has no parametrized tests. 5 of 5 are ported.

## Beyond upstream

- **SqliteSpec**:
  - an empty instance id is refused before anything is created;
  - create refuses an existing Instance, and load refuses an absent one, and
    each releases the fence;
  - a refused History file releases the fence;
  - close is idempotent and every later door refuses;
  - a poisoned Engine releases the fence while it still refuses every door;
  - the order scenario runs, crashes mid-flight and resumes over SQLite;
  - the Engine, its History and the Local Dispatch share one database file;
  - a holder in another process gets the reference's refusal text.
- **Interop with the reference process** (SqliteInteropSpec).
  These run `test/interop/engine_sqlite_interop.py` under
  `upstream/petrus/.venv`, with petrus-engine's order scenario on both sides:
  - the same scenario writes identical History rows (DDL, schema row, and
    every event row apart from `recorded_at`);
  - an Instance the reference left mid-flight resumes in Haskell to the
    reference's own resumed rows, and the other way round;
  - a reference Engine holding the fence refuses a Haskell Engine with the
    reference's text, while another instance in the same file stays free,
    and the other way round;
  - a dead holder of either language releases the fence to the other.
