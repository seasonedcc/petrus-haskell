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

1. **`IMPETUS_TELEMETRY_LEVEL` is read when first used,** not at import
   (Haskell has no import-time effects). An invalid value throws
   `UnknownTelemetryLevel` at that first use, and again at every later use.
2. **`setLevel` and `atLevel` take a typed `Level`.** Only `parseLevel` can
   see a bad spelling, so upstream's quirk where `capture(level="bad")`
   leaves the sink swapped cannot happen.
3. **`error_type` is the Haskell exception's `Typeable` name**
   (`ErrorCall`, `IOException`), not the Python class name. Spans also
   observe async exceptions, as `__exit__` sees `KeyboardInterrupt`. Item 15
   shows what this means for the Engine's events.
4. **A duplicate field in `emit` throws `DuplicateTelemetryFields`;** `bind`
   returns `Either Text`.
5. **A sink swallows only synchronous exceptions.**
6. **With no route, the default sink formats nothing.** Routing is
   `setRoute` with a ByteString callback, not stdlib logging handlers.

   The reference's `JsonLogger` runs `json.dumps` even when no handler is
   configured, and the stdlib logger then drops the INFO record. The
   Haskell default therefore costs 0.06 µs per emit, against the
   reference's 7.5 µs ([bench](../petrus-telemetry-instrumentation/bench/RESULTS.md)).
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
13. **`newSpan` and `runSpan` let a span exist before it starts.**
14. **The `TelemetryLogger` constructor is exported.**

## The instrumentation (`impetus_*` events)

15. **A failed Engine drive reports `error_type: "EngineError"`.** When a
    handler fails during `Engine.advance`, the reference's `drive` span
    finishes with the class of the exception that escapes the drive
    (`RuntimeError` for a handler raising one). The Haskell Engine raises
    its typed `EngineError` (`EngineHandlerFailed`, item 1 of
    [`petrus-engine/DIVERGENCES.md`](../petrus-engine/DIVERGENCES.md)), so
    item 3 names that.

    `test_a_halting_advance_finishes_the_span_failed` expects `EngineError`.
    The differential maps `EngineError` to `RuntimeError` and nothing else.
    Every other field of the event matches.
16. **`firing_failed.error` is the Haskell failure text.** It follows
    [`petrus-impetus/DIVERGENCES.md`](../petrus-impetus/DIVERGENCES.md)
    item 11. The differential's failing handlers return the reference's
    spelling (`RuntimeError('handler broke')`), so the field matches there.
17. **The Engine and Instance take an explicit `telemetrySink`.**
    `EngineOptions.telemetrySink` and `InstanceConfig.telemetrySink` bypass
    the process default. When neither is set, the process default applies,
    as in the reference, where every logger resolves the module-level sink
    on each emit.
