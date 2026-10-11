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
11. **`FiringFailed.error` for a Haskell exception is named by its type.**
    The reference records `firing_failure_text(error)`: the class name and
    each of `error.args` (`None`, `bool`, `int`, `float`, `str`, and `bytes`
    by `repr`, anything else as `<module.qualname>`), bounded to 4096
    characters. Here:
    - A kernel refusal records the same spelling: `ValueError('msg')`,
      `TypeError('msg')`, or `RuntimeError('msg')`.
    - A handler's `Left text` is recorded as given.
    - A thrown `PythonException name args` is recorded exactly as the
      reference records a Python exception of that class and those args,
      for every argument shape above (huge ints, non-finite floats, quotes,
      unprintable characters, bytes, objects).
    - A Haskell exception with a Python counterpart is recorded under that
      class with the arguments the reference's exception carries: an
      `errno`-carrying `IOException` as CPython's `OSError` subclass with
      `(errno, strerror)` (`FileNotFoundError(2, 'No such file or
      directory')`), one without an `errno` as `OSError('description')`,
      `UserInterrupt` as `KeyboardInterrupt()`, `DivideByZero` as
      `ZeroDivisionError('division by zero')`, an `ExitCode` as
      `SystemExit(n)` (`Petrus.Telemetry.ErrorType`; checked against the
      pinned reference for every `errno` in petrus-telemetry-instrumentation's
      `DifferentialSpec`).
    - Any other Haskell exception is recorded as `Name()` when its message is
      empty and `Name('message')` otherwise, with the message's GHC call
      stack removed: exactly what the reference records for a Python
      exception of that class raised with no argument or one string.

    `FailureTextSpec` checks 452 texts produced by the reference
    (`differential/failure_text_corpus.json`): every one through
    `PythonException`, and each zero- or one-string-argument case also
    thrown as a Haskell exception of that name.

    What cannot match is the name of an exception that is not a
    `PythonException`: it is the Haskell type's `Typeable` name (`ErrorCall`,
    `IOException`), which is a Python class name only when the Haskell type
    is named like one.
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

    The reference's identity classes are newtypes whose constructors are
    not exported (`Petrus.Impetus.Instance.Identity`):
    - `InstanceIdentity`, built by `mkInstanceIdentity`;
    - `DeliveryIdentity`, built by `mkDeliveryIdentity`;
    - `FiringOccurrenceId`, built by `mkFiringOccurrenceId`.

    Each constructor has its class's rule and message. Upstream's classes
    subclass `str` and `int`, so a value passes wherever a plain one does.
    Here it converts explicitly (`instanceIdentityText`,
    `deliveryIdentityText`, `firingOccurrenceIdInt`). The newtypes appear
    where upstream's annotations carry them:
    - the fields of `AcceptedDelivery`;
    - the identity an Instance is created or resumed with.

    Elsewhere the API keeps validated `Text` and `Int`, which matches how
    upstream passes the plain values on: History records, `FiringOccurrence`,
    and `instanceIdentity`.

    `canonical_net_path(value, noun)` is the class `CanonicalNetPath`: a
    `NetPath` passes as it is, and a `Text` is parsed by `netPath`. Its third
    case, any other type refused with the caller's noun, is a type error.
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
20. **A record built with its constructor is `model_construct`.** The
    record constructors check nothing, like the reference's
    `Model.model_construct(...)`. The `mk*` functions
    (`mkPlaceDefinition`, `mkArcDefinition`, `mkNetDefinitionBody`,
    `mkLineageEntry`, and the rest, one per model) are the reference's
    validating `Model(field=..., ...)` calls, with nested models passed as
    already-built instances and the reference's `ValidationError` text.
    `compileNetDefinition`, `serializeNetDefinition`, `serializeNetDocument`,
    and `projectNetDocument` then do exactly what the reference does with
    such an instance: compilation builds the net in the reference's lazy
    order and compares the projection; serialization of a document
    revalidates its dump; projection takes the lineage as it is.
    `differential/hand_built_corpus.json` pins all of this
    (`HandBuiltCorpusSpec`, 1996 cases).

    What a Haskell record cannot hold, and so is not covered:
    - a value of the wrong Python type in a field (a `bool` for an `int`, a
      non-string path, a list where the reference keeps a tuple), an
      unknown `kind`, `mode`, or `provenance` literal, a `format` or
      `version` other than the constant, extra fields, and non-string
      metadata keys: the types rule them out;
    - model-level construction with a string holding a lone surrogate. The
      parsers refuse them with the reference's text; a `Text` holds one
      only as WTF-8 built on purpose ("Petrus.Json.Wtf8", what the History
      stores read token data into), and serializing such a document is
      not covered (the reference's `.encode()` would raise).

    The recursion-depth checks are calibrated to a call from a module's top
    level (item 24). A caller deeper in the Python stack hits the limit
    sooner; the depth of the Haskell call does not matter.
21. **View positions are a list of pairs,** not a dict. Duplicates are
    representable, and they are refused as "view node paths must be unique".
22. **The `mk*` constructors validate only their own fields.** As in the
    reference, nested models passed to them are not revalidated (item 20).
    `petrus-observation` builds its lineage with `mkLineageEntry` and
    `mkExecutionLineage`, as the reference's `net_document` builds
    `LineageEntry(...)` and `ExecutionLineage(...)`.
23. **`netDocumentToJson` omits an absent view or lineage,** matching the
    writer's value. `parse*Json v` means `parse(json.dumps(v))`. It is
    total: the reference's `model_dump(mode="json")` raises Pydantic's
    `Circular reference detected (depth exceeded)` for token data or a
    metadata value nested 256 deep, and here only `serializeNetDocument`
    refuses that, with the reference's text.
24. **Depth limits are the reference's for a top-level call.** These are
    at parity; the entry records the calibration. Token data and metadata
    are walked as the reference's recursive `_strict_json` validator walks
    them, and fail where CPython's default limit of 1000 frames does when
    the validating call is made from a module's top level (a constructor,
    `serialize_net_document`, or `parse_net_document`). That
    `RecursionError` aborts the whole validation, so it wins over every
    other validation error, as in the reference. Parsing walks the whole
    payload first: definitions are refused at 997 nested empty lists, and
    documents at 499. `HandBuiltCorpusSpec` pins the thresholds (494 to 501
    levels, lists and objects, numeric, string, and null leaves) with and
    without other errors in the same value.
25. **Printability is CPython 3.14's.** `Petrus.Json.PythonText` (used by
    every `repr` in this package, `petrus-telemetry`, and the failure texts)
    decides `str.isprintable` from a table of 736 ranges generated from
    CPython 3.14 (Unicode 16) by `packages/petrus-json/gen/gen_python_printable.py`.
    `PythonTextSpec` checks all 1,114,112 code points against the committed
    vector `packages/petrus-json/test/python-printable.txt`. This is at
    parity; GHC's own `isPrint` (Unicode 15.1, and it admits space
    separators such as U+00A0) is no longer used for it. Other packages'
    own `repr` helpers (`petrus-motus`, `petrus-execution`, `petrus-dst`)
    still use GHC's tables.

## Telemetry (`petrus-telemetry`)

26. `impetus_*` events are emitted after the durable append and stamped with
    the record's virtual instant, as in the reference. The
    [telemetry differential](../petrus-telemetry-instrumentation/PARITY.md)
    checks every event against the reference: names, fields, field order,
    and routed bytes. The telemetry package's own divergences, formerly
    listed here, are in
    [`petrus-telemetry/DIVERGENCES.md`](../petrus-telemetry/DIVERGENCES.md).

## Out of scope

The DSL (`dsl.py`), observation (`observation.py`), CEL evaluation, and the
durable stores are not ported in this package. They live in `petrus-dsl`,
`petrus-observation`, `petrus-cel`, and `petrus-history-store`; their tests
are listed in `PARITY.md`.
