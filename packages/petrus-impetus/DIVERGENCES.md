# petrus-impetus: divergences from the Python reference

Every wire format here matches the reference byte for byte: History schema 5,
the JSON-line spelling, Net definition v3, Net document v1, and the golden
traces. Every refusal the reference raises as `ValueError`, `TypeError`, or
`RuntimeError` is refused here with the same message text. The entries below
are the places where the Haskell API differs on purpose, or where a Python-only
artifact can't be reproduced. None of them changes what is recorded, replayed,
or serialized.

Pinned reference: `upstream/petrus` (`src/petrus/impetus/`).

## API shape

1. **Configuration is a record, not keyword arguments.** `Instance(net,
   marking, scheduler=..., guards=..., handlers=..., filters=..., ...)`
   becomes `newInstance net defaultInstanceConfig {..}`. `resume net store
   cfg` reads only the binding fields of `cfg` (the implementations, CEL
   compilers, telemetry sink, and scheduler). A resumed Instance takes its
   marking, identity, and clock from History, as the reference's does.
2. **Doors return `Either InstanceError`, not exceptions.** The Python
   exception classes map to these constructors:

   | Python | Haskell |
   | --- | --- |
   | `ValueError` | `Refused` |
   | `TypeError` | `TypeRefused` |
   | `RuntimeError` | `RuntimeRefused` |
   | an exception raised by a handler, `prepare`, or `project` | `HandlerRaised` |

   A History-store refusal of a completion batch is the distinct
   `CommitRefused SomeException`, returned by `commitCompletion` (the
   reference's `_commit_completion`). `complete` rethrows the store's own
   exception, as the reference does. Store exceptions anywhere else propagate
   as IO exceptions.
3. **`fail` is `failFiring`,** because `fail` is a Prelude method.
   `_commit_completion` is `commitCompletion`, and
   `_canonical_accepted_delivery` is `canonicalAcceptedDelivery`.
4. **Warnings are explicit diagnostics.** The reference emits
   `GuardEvaluationWarning`, `FilterEvaluationWarning`, and
   `CompletionEvaluationWarning` through `warnings.warn`. Here
   `candidatesWithDiagnostics` and `statusWithDiagnostics` (and the pure
   `Enabledness.candidatesWithDiagnostics`) return them as values, and
   `renderDiagnostic` gives the reference's warning text. The plain
   `candidates` and `status` discard them, so there is no global warning
   state.
5. **The History store is a record of IO actions** (`snapshot`, `count`,
   `extend`, `mode`), not a Protocol. `inMemoryHistoryStore` is the
   reference's in-memory store. `mirroredHistoryStore mode loaded
   durableWrite` builds any durable backend with the reference's contract:
   - backend-owned writes, or the joined-transaction mode;
   - a batch extends as one commit;
   - the mirror grows only after the durable write succeeds;
   - conflicts are verified with Python equality (`verifyConflict`).
6. **The Instance's single-writer lock is an `MVar`,** and doors called by
   other doors (fail → record failure → complete) never take it twice. The
   reference uses a re-entrant lock.
7. **Implementation maps are keyed by `ImplementationRef`** (`Symbol name` or
   `Exact netUri`) instead of `str | NetUri`.
8. **The token field `data` is `payload`,** because `data` is a Haskell
   keyword. The wire name stays `data`.
9. **`pendingActivityOutcomes` is an `IntMap`,** so it is ordered by
   occurrence id rather than by dict insertion order. The two orders agree
   whenever outcomes are recorded in occurrence order.

## Handlers, guards, filters, completions

10. **Implementations are pure functions.**
    - A handler is `Binding -> [Arc] -> Either Text HandlerResult`, and
      `Left` means the handler raised. Its text is recorded verbatim as
      `FiringFailed.error`.
    - Guards and filters are `-> Either Text Bool`, completions
      `Marking -> Either Text Bool`, and `Left` means "raised". Raising means
      not satisfied, or no match, with a diagnostic, as in the reference.
    - The kernel also catches Haskell exceptions thrown by a handler's result
      (forced with `evaluate . force`) and by a completion. It does not catch
      them in a guard or filter: `error` in a pure guard is a programming
      error, and the `Either` is the contract.
    - Upstream tests that count calls to a pure function (`prepared == 0`, or
      "the strategy was never called") are replaced by stand-ins that refuse
      if they are ever consulted.
11. **`FiringFailed.error` text cannot always match the reference.**
    - The reference records `repr(exception)` of whatever Python raised.
    - A kernel refusal here records the same spelling: `ValueError('msg')`,
      `TypeError('msg')`, or `RuntimeError('msg')`.
    - A handler's `Left text` is recorded as given.
    - A Haskell exception is recorded as its `Typeable` name and message, for
      example `ErrorCall('boom')`, without the call stack.
    - All of these are truncated to 4096 characters, as upstream truncates.
    - A Python `KeyError('amount')` raised by user code therefore has no
      automatic twin. The golden-trace guards return that spelling
      themselves.
12. **Typed bindings are an applicative,** `Typed`/`param`, with
    `deriveTypedTransform`/`deriveTypedGuard`/`derivedActivityHandler`.
    Signature introspection does not exist here. Python's "unresolved
    annotation", "untyped parameter", "variadic parameter", "non-dataclass
    return", and "exact bool at runtime" refusals are enforced by types.
13. **CEL is a seam.** An Instance takes a `CelCompilers` record
    (`compileGuard`, `compileFilter`, `compileCompletion`); `noCelCompilers`
    refuses every inline expression with an explicit "not admitted" error.
    The kernel computes scopes and free-place checks and passes them to the
    compiler. It never evaluates CEL and does not depend on `petrus-cel`.
## Values that cannot exist

14. **Json is already JSON.** Token data, activity inputs and results, and
    record fields are `Json`, so the reference's "not JSON-faithful" refusals
    for tuples, sets, non-string keys, `object()`, and nested Net objects
    can't arise. Non-finite floats can still be built, and they are refused
    with the reference's message (`...; Out of range float values are not
    JSON compliant: nan`).
15. **Exact-type checks are enforced by types.** Python checks things like
    `type(x) is not NetPath`, a bool passed where an int is expected, a
    non-Token item in a delivery, a non-str identity, or a registration key
    that is not a string. Haskell cannot represent those values. The same
    holds for read-only views and mutation of returned containers, since
    every value is immutable. `AcceptedDelivery` can only be built through
    `acceptedDelivery`, which validates it.
16. **Timer enabledness errors are typed** (`ClockRequired`,
    `MisalignedInstants ...`). The fields carry the data of the reference's
    message; the pure layer has no text rendering, and the Instance never
    surfaces them because it always supplies the clock.

## Identity and time

17. **Minted instance ids are UUIDv7.** They port `uuid.uuid7`, RFC 9562
    §6.2 Method 1: a 42-bit per-process counter, so ids minted in one
    millisecond still sort by creation, with randomness from
    `/dev/urandom`. A supplied identity is used verbatim.
18. **Instants are `Number = IntNumber | FloatNumber`,** with Python's
    numeric equality and ordering (`1 == 1.0`) and Python's spelling on the
    wire. The effective instant is `max(at, watermark)` and keeps the
    supplied spelling when the two are equal, as `max` does in Python.

## Net definition v3 and Net document v1

19. **`format` and `version` are type constants,** not fields, and
    `time_domain` is the `TimeDomain` type.
20. **Haskell records are validated when they are used, not when they are
    built.** `compileNetDefinition`, `serializeNet*`, and
    `projectNetDocument` revalidate hand-built records. The error prefixes
    are:
    - compile: `invalid Petrus Net-definition v3: <ValidationError>`;
    - serialize: `cannot serialize Petrus Net document v1: …`.

    A lineage passed to `projectNetDocument` is validated as an
    `ExecutionLineage`, and positions as `NodePosition`/`PortableViewV1`.
    Python validates a model when it is constructed, so an invalid
    hand-built record fails later here, with the prefix of the operation
    that caught it.
21. **View positions are a list of pairs,** not a dict. Duplicates are
    representable, and they are refused as "view node paths must be unique".
22. **`mkMarkingToken` and `mkLineageEntry` are smart constructors.** They
    return pydantic-formatted errors (`1 validation error for
    MarkingToken/LineageEntry …`).
23. **`netDocumentToJson` omits an absent view or lineage,** matching the
    writer's value. `parse*Json v` means `parse(json.dumps(v))`.
24. **Recursion-depth refusals are ordered by depth.** When a hand-built
    value is serialized or projected, a nesting-depth refusal can be found in
    a different order from the other validator refusals than in Python.
    Parsing is calibrated to the reference's top-level call: definitions are
    refused at 997 nested empty lists under a depth-4 caller, documents at
    499.
25. **Printability uses Python's Unicode 16 tables,** through an embedded
    table of 47 ranges, because GHC ships Unicode 15.1. Character data
    outside that table could still render differently in error text.

## Telemetry (`petrus-telemetry`)

26. `impetus_*` events are emitted after the durable append and stamped with
    the record's virtual instant, as in the reference. The telemetry package
    has its own divergences:
    1. **`IMPETUS_TELEMETRY_LEVEL` is read when first used,** not at import
       (Haskell has no import-time effects). An invalid value throws
       `UnknownTelemetryLevel` at that first use, and again at every later
       use.
    2. **`setLevel` and `atLevel` take a typed `Level`.** Only `parseLevel`
       can see a bad spelling, so upstream's quirk where `capture(level="bad")`
       leaves the sink swapped cannot happen.
    3. **`error_type` is the Haskell exception's `Typeable` name**
       (`ErrorCall`, `IOException`), not the Python class name. Spans also
       observe async exceptions, as `__exit__` sees `KeyboardInterrupt`.
    4. **A duplicate field in `emit` throws `DuplicateTelemetryFields`;**
       `bind` returns `Either Text`.
    5. **A sink swallows only synchronous exceptions.**
    6. **With no route, the default sink formats nothing.** Routing is
       `setRoute` with a ByteString callback, not stdlib logging handlers.
    7. **There is no `default=str`.** Values are already `Json`;
       `exceptionJson` stringifies exceptions.
    8. **The monotonic clock is a per-logger field,** injected in tests.
    9. **A `Payload` has dict semantics:** a duplicate key replaces the value
       in its first position.
    10. **`milestone` overwrites an `elapsed_ms` field,** where upstream
        raises a `TypeError`.
    11. **`increment` and `accumulateTime` on a non-numeric field throw
        `NonNumericTelemetryField`.**
    12. **statm parsing accepts ASCII digits only.**
    13. **`newSpan` and `runSpan` let a span exist before it starts.**
    14. **The `TelemetryLogger` constructor is exported.**

## Out of scope

The DSL (`dsl.py`), observation (`observation.py`), CEL evaluation, and the
durable stores other than the in-memory one are not ported here. Their tests
are listed in `PARITY.md`.
