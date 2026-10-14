# petrus-sqlite: divergences from upstream's `sqlite3` usage

Intentional differences from how the pinned Petrus drives SQLite through
CPython 3.14's `sqlite3` module. Everything not listed here is meant to be
identical; the test suite compares connection state, transactions, DDL text,
PRAGMA readers and the writer fence against the pinned Python code.

| Behavior | Upstream (CPython `sqlite3`) | petrus-sqlite | Why |
| --- | --- | --- | --- |
| SQLite library | The interpreter's linked SQLite (Homebrew/CPython builds: 3.50+). | `direct-sqlite`'s bundled amalgamation (3.45.0, with JSON1, `usleep`). | Both read and write the same file format, WAL and locking protocol; nothing upstream depends on features newer than 3.38 (JSON1). Build with `direct-sqlite`'s `systemlib` flag to link the system library instead. |
| Implicit transactions (legacy isolation level, only the Codex service profile) | CPython opens `BEGIN ` before a statement it classifies as DML (`INSERT`/`UPDATE`/`DELETE`/`REPLACE` after leading whitespace and comments). | The same classification, implemented in Haskell. | `direct-sqlite` has no such mode. |
| Statement cache | 128 statements per connection, LRU. `execute("BEGIN IMMEDIATE")` goes through it; `commit()` and `rollback()` prepare `COMMIT`/`ROLLBACK` afresh each time. | 128 statements per connection; when full the cache is flushed. `BEGIN IMMEDIATE`, the implicit `BEGIN `, `COMMIT` and `ROLLBACK` go through the cache too. | No observable difference beyond performance: the same statement texts run in the same order, and errors carry the same messages. |
| Per-operation connections (Local Dispatch) | A new connection per operation; read-only ones linger until the garbage collector closes them. | `Petrus.Sqlite.Pool` keeps a few idle connections open between operations and closes them when the pool is closed (or garbage collected). Each operation still has a connection to itself; one is reused only while the path names the same file and it saw no SQLite error. | Closing the last connection to a WAL file checkpoints and deletes the WAL (several fsyncs). Statements, transactions and file contents are unchanged. See petrus-motus DIVERGENCES (15). |
| Fork handling of the writer fence | `os.register_at_fork` closes inherited fence descriptors in the child. | Not needed (Haskell programs do not fork the running process); `ensureWriterFence` keeps the PID check and message. | — |

## Resolved

- **Busy timeout.** `connect` ran `PRAGMA busy_timeout = <ms>` right after
  opening, because `direct-sqlite` does not bind `sqlite3_busy_timeout`. It
  now calls `sqlite3_busy_timeout` itself, as `sqlite3.connect(timeout=t)`
  does, so no statement is compiled and run for it. The setting is the
  same; the pragmas a profile lists (`PRAGMA busy_timeout = 5000` among
  them) still run as statements, as the reference runs them.
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
- **An asynchronous exception while a statement was prepared.** No
  divergence from the reference, which has no foreign calls, but a defect of
  the Haskell side alone. An exception thrown to a thread inside
  `sqlite3_prepare_v2` is raised as the call returns, and it used to land
  before the statement was cached, leaving it unfinalized. `close` then
  failed with `SQLITE_BUSY` ("unable to close due to unfinalized
  statements"), the handle leaked, and `withConnection` and `open` raised
  that error in place of the original exception. Preparing and caching now
  run masked, and `withConnection` and `open` close quietly on the way out
  of a failure. The test "an asynchronous exception while a statement is
  prepared leaves nothing unfinalized" throws into a 10 000-branch
  `CASE` statement's preparation ten times (every try failed before), and
  "withConnection rethrows the action's exception when closing fails too"
  checks the second half.
