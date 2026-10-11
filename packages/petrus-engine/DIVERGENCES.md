# petrus-engine: divergences from the Python reference

The Engine and Coordinator follow `petrus/engine/__init__.py` and
`_coordination.py` call for call. The behavior that History can see is
identical, and the interop suite checks the JSONL bytes against the
reference process, including crash and resume in both directions. That
covers the commit points, records and their order, poisoning texts, the
reconcile order, selection durability, and cancellation positions. The
differences are in how the API is spelled and in what the types rule out.

1. **A handler failure is `EngineHandlerFailed <text>`, not the handler's
   own exception.** The kernel reduces every pure-handler or projection
   failure to `HandlerRaised Text`. A failure is either a `Left` text or an
   exception thrown while the handler runs. The text is exactly the
   `FiringFailed.error` the reference records, so the History, the poison
   text, and a fresh load's behavior all match. A caller who wants the
   original exception object gets its rendered text. Exceptions from a
   `Dispatch`, a sensor, a store, or a commit hook are rethrown unchanged,
   as the reference rethrows them.
2. **Errors are one sum type.** `EngineError` has these constructors:
   - `EngineValueError`, `EngineTypeError` and `EngineRuntimeError` stand
     for the reference's `ValueError`, `TypeError` and `RuntimeError` raised
     by the Engine itself.
   - `EngineHandlerFailed` is the case in item 1.

   Each carries the reference's message text. Store load refusals are
   `HistoryStoreError` (see `petrus-history-store/DIVERGENCES.md`).
3. **Observation views go through a seam, not Engine methods.** The
   reference's `snapshot()`, `net_document()` and `history_page()` belong to
   `petrus-observation`. `Petrus.Engine.Observation.observeEngine` gives
   that package the Instance and a History snapshot, coherently and under
   the Engine's monitor. That is everything those views read, so they are
   built there (`Petrus.Observation.Engine.snapshot`, `netDocument`,
   `historyPage`) without the Engine depending on them.
4. **The type system replaces the reference's run-time type checks.** The
   reference spends many guards on values that pose as something else:
   `str`/`int`/`NetPath`/`LifecycleScope`/record subclasses, a bool posing as
   an occurrence, a `None` sensor answer, tuples versus lists, and
   `__deepcopy__` hooks. None of these can be built in Haskell. PARITY.md
   lists the 26 tests that exist only for those guards, and 15 more whose
   observable half is ported.
5. **Configuration is a record.** `create` and `load` take `EngineOptions`
   where the reference takes keyword arguments. The fields are `marking`,
   `at`, `handlers`, `guards`, `filters`, `completions`, `celCompilers`,
   `policy`, `selection`, `clock`, `sensor`, `activities`,
   `defaultHeartbeatTimeout` and `telemetrySink`. The defaults are the
   reference's: the conservative policy, the kernel's default selection, a
   simulated clock, no sensor, and a 30-second default heartbeat timeout.
6. **CEL compilers are a field.** CEL guards, filters and completions
   compile through `celCompilers`. Its default is petrus-cel's
   `Petrus.Cel.Impetus.celCompilers` (cel-python's semantics), so an Engine
   runs every CEL net the reference runs, as the reference, which has CEL
   built in, does. A host may inject other compilers. The kernel's own
   default stays `noCelCompilers`, because the kernel cannot depend on
   petrus-cel (petrus-cel depends on it).
7. **Policies and selection are values.**
   - A `DrivingPolicy` is `Snapshot -> IO Action`.
   - `BeginCandidate` carries the candidate `Binding`. The coordinator keeps
     the selection proposal behind it, so `Action` equality ignores the
     proposal. The reference compares proposals that are equal in every
     test.
   - A selection policy is a pure `SelectionPolicy s` with explicit state
     (`EngineSelection`). Two Engines given the same policy share no mutable
     state, which the reference has to test for. A host that steers its
     selection between drives (the reference lets it set an attribute on
     its policy object) gives a `SteeredSelection`: an `IO` input the
     coordinator reads before each proposal and a pure policy built from
     it.
8. **The monitor is an `MVar` with an owner thread.** It stands in for the
   reference's `RLock`, and it is re-entrant for the holding thread. A
   sensor or hook that calls a read door (for example `Engine.status`) from
   inside `advance` works as in the reference.
9. **A thrown exception is spelled by the kernel's `exceptionFailureText`.**
   It is now exact wherever the Python text is predictable: an exception
   with an empty message is `Name()` and one with a message is
   `Name('message')` (Python's `repr` quoting), as the reference records for
   a Python exception of that class raised with no argument or one string.
   A handler that needs any other spelling (several arguments, numbers,
   bytes, objects) throws `Petrus.Impetus.Instance.PythonException`, whose
   text is the reference's for every argument shape. The evidence is the
   kernel's `FailureTextSpec` over `differential/failure_text_corpus.json`
   (452 reference-produced texts; see `packages/petrus-impetus/DIVERGENCES.md`
   item 11). The Dispatches' and Workers' own exceptions are named by
   `Petrus.Motus.PythonException` (a `DispatchError` is `ValueError`; see
   `packages/petrus-motus/DIVERGENCES.md` item 4). What remains is the class
   name of any other exception: it is named by its `Typeable` type name, so
   it matches the reference only when the Haskell type is named like the
   Python class.
10. **A joined-transaction store must come with a commit point.** As in the
    reference, the Engine commits at its commit points exactly when the
    provider's `EngineResources` supply a `commit`. The reference does not
    inspect the pairing. Here `openEngine` refuses a `JoinedTransaction`
    store without a `commit` (`ValueError`), since its appends would never
    become durable. This is a port-only guard, checked by the EngineSpec
    example "a joined-transaction store without a commit point is refused".
    A `BackendOwned` store may still take a commit hook, as the reference's
    observation tests do.
11. **A kernel performance change.** This milestone touched
    `Petrus.Impetus.HistoryStore` in `petrus-impetus`, minimally and
    additively:
    - `inMemoryHistoryStore` is a direct `IORef (Seq Record)`, with no
      admission bookkeeping.
    - `mirroredHistoryStore` skips its admission filter when every record
      entered.

    Semantics are unchanged, and the kernel suite (2 762 examples) passes.
12. **`EngineOptions.handlerObserver` is a port-only option.** The
    reference's Activity handlers are objects that may count their calls or
    read an injected fault (its tests' bridges do both). Here handlers stay
    pure values, and the host passes that behaviour once as a
    `HandlerObserver`, which the Instance's writing door runs exactly once
    before each `prepare`/`project` application; a `Left` is that call
    raising. The default (`Nothing`) is the reference's behaviour. The
    EngineSpec examples under "handler observer" pin the call count and the
    raise; the DST worlds install their bridges through it
    (`Petrus.Testing.Dst.Engine.Bridge.withBridge`).
