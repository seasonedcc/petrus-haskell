# petrus-sqlite: divergences from upstream's `sqlite3` usage

Intentional differences from how the pinned Petrus drives SQLite through
CPython 3.14's `sqlite3` module. Everything not listed here is meant to be
identical; the test suite compares connection state, transactions, DDL text,
PRAGMA readers and the writer fence against the pinned Python code.

| Behavior | Upstream (CPython `sqlite3`) | petrus-sqlite | Why |
| --- | --- | --- | --- |
| SQLite library | The interpreter's linked SQLite (Homebrew/CPython builds: 3.50+). | `direct-sqlite`'s bundled amalgamation (3.45.0, with JSON1, `usleep`). | Both read and write the same file format, WAL and locking protocol; nothing upstream depends on features newer than 3.38 (JSON1). Build with `direct-sqlite`'s `systemlib` flag to link the system library instead. |
| Busy timeout | `sqlite3.connect(timeout=t)` calls `sqlite3_busy_timeout(db, t*1000)`. | `PRAGMA busy_timeout = <ms>` right after opening (the pragma calls the same function). | `direct-sqlite` does not bind `sqlite3_busy_timeout`; the effect is identical. |
| Implicit transactions (legacy isolation level, only the Codex service profile) | CPython opens `BEGIN ` before a statement it classifies as DML (`INSERT`/`UPDATE`/`DELETE`/`REPLACE` after leading whitespace and comments). | The same classification, implemented in Haskell. | `direct-sqlite` has no such mode. |
| Statement cache | 128 statements per connection, LRU. `execute("BEGIN IMMEDIATE")` goes through it; `commit()` and `rollback()` prepare `COMMIT`/`ROLLBACK` afresh each time. | 128 statements per connection; when full the cache is flushed. `BEGIN IMMEDIATE`, the implicit `BEGIN `, `COMMIT` and `ROLLBACK` go through the cache too. | No observable difference beyond performance: the same statement texts run in the same order, and errors carry the same messages. |
| Per-operation connections (Local Dispatch) | A new connection per operation; read-only ones linger until the garbage collector closes them. | `Petrus.Sqlite.Pool` keeps a few idle connections open between operations and closes them when the pool is closed (or garbage collected). Each operation still has a connection to itself; one is reused only while the path names the same file and it saw no SQLite error. | Closing the last connection to a WAL file checkpoints and deletes the WAL (several fsyncs). Statements, transactions and file contents are unchanged. See petrus-motus DIVERGENCES (15). |
| Fork handling of the writer fence | `os.register_at_fork` closes inherited fence descriptors in the child. | Not needed (Haskell programs do not fork the running process); `ensureWriterFence` keeps the PID check and message. | — |

## Resolved

- **`normalizeDdl` lowercasing.** It used `Data.Text.toLower` (Unicode
  15.1, no final-sigma rule). It is now petrus-json's `pythonLower`
  (CPython 3.14's `str.lower`, Unicode 16.0, `handle_capital_sigma`), and
  its whitespace is petrus-json's `isPythonSpace`. The test "normalizes DDL
  exactly like re.sub(r'\s+', ' ', s.strip()).lower()" runs the pinned
  interpreter on final sigmas and a Unicode 16.0 capital.
- **`repr()` of non-ASCII strings in messages.** It used GHC's
  `generalCategory`. `Petrus.Sqlite.PythonRepr` now re-exports
  petrus-json's `pythonStrRepr` (CPython 3.14's printability table, checked
  on every code point).
