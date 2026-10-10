# petrus-engine-sqlite: divergences from the Python reference

`Petrus.Engine.Sqlite` follows `petrus/engine/sqlite.py` step by step:
1. take the writer fence for `(path, instance)`;
2. open the `SqliteHistoryStore`;
3. hand both to the Engine as its resources: `release` is the fence's
   close, `close` is the store's close, and `ensure` is the fence's check.

Any failure before the Engine owns them closes the store and releases the
fence. The database, the rows, the fence's lock file and its refusal texts
are the reference's. The interop suite (`test/Petrus/Engine/SqliteInteropSpec.hs`)
checks this against the reference process in both directions, including
crash and resume and fence contention. The differences are in how the API is
spelled.

1. **Typed options instead of `**options`.** The reference's `create_engine`
   and `load_engine` take `dispatch=` and forward `**options` to
   `Engine._open`. Here they are positional and typed:

       createEngine, loadEngine :: FilePath -> Net -> Text -> Dispatch -> EngineOptions -> IO Engine

   `openSqliteEngine` takes petrus-engine's `OpenMode`
   (`CreateInstance` or `LoadInstance`) in place of the reference's private
   `create=` flag. The options are
   petrus-engine's `EngineOptions` (see `packages/petrus-engine/DIVERGENCES.md`).
2. **Fence refusals are `FenceError`.** It comes from petrus-sqlite and is
   re-exported here:
   - `EmptyInstance` is the reference's `ValueError` for an empty instance;
   - `SecondWriter` is its `RuntimeError` when another writer holds the
     fence;
   - `InheritedAcrossFork` is its `RuntimeError` for a fence used in a
     forked child.

   `fenceErrorMessage` gives the reference's text. Store refusals are
   `HistoryStoreError`, and Engine refusals are `EngineError`, as in those
   packages.
3. **No at-fork hook.** The reference registers `os.register_at_fork` to
   close inherited fence descriptors in a child process. The port keeps the
   PID check instead. A forked child's Engine refuses with the reference's
   "inherited across fork" text, and the parent's fence is unaffected. The
   upstream fork test is ported with `forkProcess`. See
   `packages/petrus-sqlite/DIVERGENCES.md`.
4. **Spawned processes are the test binary re-executed.** The reference's
   contention test starts holders with `multiprocessing` (spawn). The port
   re-executes its own test binary with `PETRUS_ENGINE_SQLITE_ROLE` set to
   `hold` or `try-load` (`test/Petrus/Engine/SqliteSupport.hs`). This is a
   test-harness difference only. The protocol under test, `flock` on the
   same lock file, is the same, and the interop suite also contends against
   reference processes.
