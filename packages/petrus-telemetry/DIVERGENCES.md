# petrus-telemetry: divergences from the Python reference

What is emitted matches the reference, as checked by the differential in
[`petrus-telemetry-instrumentation`](../petrus-telemetry-instrumentation/PARITY.md):

- every `impetus_*` event the Instance, the Engine, and the JSONL History
  store emit;
- its field names, field order, and values (including Python's int, float
  and bool distinctions);
- the routed line, byte for byte, with `ts` pinned.

The entries below are where the Haskell API differs on purpose, or where a
Python-only artifact cannot be reproduced. Items 1–14 were item 26 of
[`petrus-impetus/DIVERGENCES.md`](../petrus-impetus/DIVERGENCES.md) and were
moved here.

Pinned reference: `upstream/petrus` (`src/petrus/telemetry.py`).

## The library (`Petrus.Telemetry`)

1. **`IMPETUS_TELEMETRY_LEVEL` is validated by each instrumented
   constructor,** not at import (Haskell has no import-time effects). The
   reference refuses a bad value when `petrus.telemetry` is imported, so a
   program that loads the Instance, a History store, the Engine, a dispatch,
   the Worker, or the PostgreSQL fabric or processes aborts before it can
   write anything. Here `validateTelemetryEnvironment` throws
   `UnknownTelemetryLevel` (the reference's `ValueError` text) as the first
   step of every constructor of those modules: `newInstance`, `resume`,
   `openJsonlHistoryStore`, `openPostgresHistoryStore`, Engine creation,
   `newWorker`/`newAsyncWorker`, the Local and Absurd dispatches,
   `postgresFabric` and `postgresSpawnRegistry`, before any I/O. So a
   misconfigured process is still refused before its first durable write
   (`petrus-telemetry-instrumentation`'s "IMPETUS_TELEMETRY_LEVEL refused at
   construction" runs a child and checks that no History file appears and
   no record is appended). The level itself reads totally: an invalid value
   reads as `off`, so `emit` and `withSpan` never throw for configuration
   after an effect. A program that uses only `Petrus.Telemetry` and no
   instrumented runtime is not refused unless it calls
   `validateTelemetryEnvironment` itself, as hosts may at startup.
2. **`setLevel` and `atLevel` take a typed `Level`.** Only `parseLevel` can
   see a bad spelling, so upstream's quirk where `capture(level="bad")`
   leaves the sink swapped cannot happen.
3. **`error_type` uses the reference's class vocabulary.** A span names the
   exception escaping its body by the Python class the reference reports
   (`Petrus.Telemetry.ErrorType.pythonErrorType`): an `errno`-carrying
   `IOException` is CPython's `OSError` subclass for that `errno`
   (`FileNotFoundError`, `PermissionError`, `BlockingIOError`, ..., checked
   against the pinned interpreter for every `errno` the platform knows), one
   without an `errno` is `OSError`; `UserInterrupt` is `KeyboardInterrupt`,
   `async`'s `AsyncCancelled` is `CancelledError`, `DivideByZero` is
   `ZeroDivisionError`, `Overflow` is `OverflowError`, an `ExitCode` is
   `SystemExit`. A runtime whose own failures stand for Python exceptions
   names them first with `classifyErrors`/`withSpanClassifying` (the Engine
   does, item 15). The one remaining difference: a Haskell exception with no
   Python counterpart (`ErrorCall`, a user's own exception type) is named by
   its `Typeable` type constructor, since the reference has no class to
   report for it. Spans also observe async exceptions, as `__exit__` sees
   `KeyboardInterrupt`.
4. **A duplicate field in `emit` throws `DuplicateTelemetryFields`;** `bind`
   returns `Either Text`.
5. **A sink swallows only synchronous exceptions.**
6. **With no route, the default sink formats nothing.** Routing is
   `setRoute` with a ByteString callback, not stdlib logging handlers.

   The reference's `JsonLogger` runs `json.dumps` even when no handler is
   configured, and the stdlib logger then drops the INFO record. The
   Haskell default therefore costs 0.06 µs per emit, against the
   reference's 2.6 µs ([bench](../petrus-telemetry-instrumentation/bench/RESULTS.md)).
   A routed line is identical on both sides.
7. **There is no `default=str`.** Values are already `Json`;
   `exceptionJson` stringifies exceptions.
8. **The monotonic clock is a per-logger field,** injected in tests.
9. **A `Payload` has dict semantics:** a duplicate key replaces the value in
   its first position.
10. **`milestone` overwrites an `elapsed_ms` field,** where upstream raises a
    `TypeError`.
11. **`increment` and `accumulateTime` on a non-numeric field throw
    `NonNumericTelemetryField`.**
12. **statm parsing accepts ASCII digits only.**
13. **A span exists only once it has started.** The reference's `Span` is
    built before `__enter__`, and its `elapsed_ms` raises `span has not
    started` until then. Here `withSpan`, `withSpanClassifying` and
    `withChildSpan` are the only ways to get a `Span`, and they hand it to
    the body after stamping its start, so the start time is a plain value
    and the unstarted state, with its error, cannot be represented. Why:
    no runtime caller holds a span before entering it; the state existed
    only so the reference's test of the error could port, at the cost of an
    `IORef (Maybe Double)` and a throwing `spanElapsedMs`. That test
    (`test_elapsed_time_before_span_entry_fails_with_lifecycle_error`) is
    not ported.
14. **The `TelemetryLogger` constructor is exported,** so a test can set a
    logger's `clock` (`logger {clock = tick}`), where the reference
    monkeypatches `time.perf_counter`.

## The instrumentation (`impetus_*` events)

15. **A failed Engine drive reports the reference's `error_type`.** (Once
    a divergence: the drive span reported the Haskell `EngineError`.) The
    Haskell Engine raises its typed `EngineError` where the reference raises
    `ValueError`, `TypeError`, `RuntimeError` or the handler's own
    exception; its drive span names that failure by the class the reference
    reports (`Petrus.Engine.Vocabulary.engineErrorType`): the refusal's
    class, a handler failure's class as its recorded text names it
    (`RuntimeError('handler broke')` is a `RuntimeError`), a
    `PythonException`'s class, and otherwise `pythonErrorType` (item 3), so
    a handler throwing an `ENOENT` `IOException` reports `FileNotFoundError`.
    `test_a_halting_advance_finishes_the_span_failed` is ported unadapted
    (`RuntimeError`), and the differential compares `error_type` raw, with
    scenarios for a handler's `RuntimeError`, a handler's
    `FileNotFoundError` and the coordinator's own `ValueError`.
16. **`firing_failed.error` uses the reference's class vocabulary too.** It
    is the recorded `FiringFailed.error`
    ([`petrus-impetus/DIVERGENCES.md`](../petrus-impetus/DIVERGENCES.md)
    item 11): the reference's spelling for kernel refusals, handler texts
    and `PythonException`s, and for a Haskell exception with a Python
    counterpart that class with the arguments the reference's exception
    carries (`FileNotFoundError(2, 'No such file or directory')`,
    `KeyboardInterrupt()`, `ZeroDivisionError('division by zero')`,
    `SystemExit(3)`), checked against the pinned reference's
    `firing_failure_text` for every `errno`. A Haskell exception with no
    Python counterpart keeps the `Name('message')` spelling of item 3. The
    differential compares the field raw.
17. **The Engine and Instance take an explicit `telemetrySink`.**
    `EngineOptions.telemetrySink` and `InstanceConfig.telemetrySink` bypass
    the process default. When neither is set, the process default applies,
    as in the reference, where every logger resolves the module-level sink
    on each emit.
