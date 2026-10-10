# petrus-telemetry-instrumentation: parity evidence for the `impetus_*` events

This package has no library. It holds the evidence that the Instance
(`petrus-impetus`), the Engine (`petrus-engine`) and the JSONL History store
(`petrus-history-store`) emit the reference's telemetry. `petrus-telemetry`
is layer zero and cannot depend on what it instruments, so the evidence
lives here.

The full map from every upstream telemetry test to its Haskell example is in
[`petrus-telemetry/PARITY.md`](../petrus-telemetry/PARITY.md). Divergences
are in [`petrus-telemetry/DIVERGENCES.md`](../petrus-telemetry/DIVERGENCES.md).

`cabal test petrus-telemetry-instrumentation` runs 52 examples, 0 failures.

## The port: `test/Petrus/Telemetry/InstrumentationSpec.hs`

All 22 tests of `tests/petrus/telemetry/test_telemetry_instrumentation.py`
are here, each named after its upstream test. One is adapted: a halting
advance reports `error_type: "EngineError"` (DIVERGENCES 15). Four
Haskell-specific examples are added. One of them is the telemetry half of
`test_coordinator.py`'s all-filtered decline test, which the Engine port
deferred to this package.

## The differential: `differential/` and `test/Petrus/Telemetry/DifferentialSpec.hs`

The generator, [`telemetry_scenarios.py`](differential/telemetry_scenarios.py),
runs 23 scenarios through the pinned reference. Each runs under
`telemetry.capture(level=...)`, and every emitted payload is recorded in
[`telemetry_scenarios.json`](differential/telemetry_scenarios.json): 282
events, plus the routed line for each event with `ts` pinned. The fixture is
committed, and regenerating it is deterministic.

To regenerate it:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-telemetry-instrumentation/differential/telemetry_scenarios.py

[`Scenarios.hs`](test/Petrus/Telemetry/Scenarios.hs) holds the Haskell twin
of each scenario. For every scenario, `DifferentialSpec` captures at the
same level and requires:

- the same event names, in the same order;
- payloads equal under `exactEq`, which checks field names, field order,
  and Python's int, float and bool distinctions;
- `telemetryLine ts` producing exactly the reference's routed line bytes.

Only wall-clock fields are normalised, by key and type, on both sides:

- every `*_ms` must be an int ≥ 0;
- `max_rss_mb` must be a positive float;
- `current_rss_mb` must be a float or null.

One documented divergence is mapped: `error_type` `EngineError` →
`RuntimeError` (DIVERGENCES 15).

A further example reruns the generator against the pinned checkout into a
scratch directory and requires the committed fixture to equal its output.
It is pending when `upstream/petrus/.venv` is missing.

The `pinned` entries are fixed payloads, including the benchmark payload.
They are routed through the reference's real `JsonLogger` with
`time.time` patched, and the Haskell `jsonLoggerWith` must write the same
bytes.

The scenarios are, in order:

| Scenario | Drives |
| --- | --- |
| `instance_created` | construction: integer and float instants, a named net (`net` kind), a source net |
| `step_and_run` | `step` at integer and float instants, a fruitless step, `run` over a chain |
| `failing_handler` | a raising handler: `firing_failed` |
| `delivery_lifecycle` | acceptance, completion, redelivery, conflicting reuse, multi-token deliveries, scoped identities |
| `seal_and_wake` | `registrations_sealed`; `timer_matured` only when a maturation derives |
| `resume` | `instance_resumed`, including a resume with a firing in flight |
| `activity_seam` | `begin`, `record_activity_completion` and `_failure` (with redelivery), `complete`, `fail` with text and with an `ActivityFailure` |
| `jsonl_commits` | `jsonl_commit` on run, resume, and a delivery with non-ASCII data |
| `engine_advance` | the `drive` span: counters, phase timings, a named net |
| `engine_failing_handler` | a halting advance: the span finishes `failed` (DIVERGENCES 15) |
| `engine_gauges` | `gauges` at `profile` |
| `engine_declined` | `candidate_selection_declined` |
| `engine_orders` | the order scenario: deliveries, a redelivery, seal, inline activities |
| `engine_sensor` | sensor batches through the drive |
| `engine_activities` | dispatched activities completing, then a terminal failure that halts |
| `engine_reconcile` | a crashed JSONL Engine reloaded and reconciled through inline dispatch |
| `engine_cancellation` | close scope: `activity_cancelled`, a late fenced result, `reset_scope` |
| `engine_reconcile_pure` | a pure firing in flight, reconciled on load |
| `engine_clock_not_due` | a clock whose timers are never due |
| `engine_failure_projection` | `project_failure` over JSONL at `profile` |
| `engine_failing_source_projection` | a raising source projection on `deliver` |
| `engine_debug_level` | `debug` admits what `profile` does |
| `level_off` | `engine_orders` and `jsonl_commits` at `off`: nothing |

No emission divergence was found. The differential needed no change to
`petrus-impetus`, `petrus-engine`, `petrus-history-store` or
`petrus-telemetry` code.

## The benchmark: `bench/`

[`bench/RESULTS.md`](bench/RESULTS.md) compares `bench/Main.hs` (tasty-bench)
with `bench/python_bench.py`:

- a routed emit costs 4.6 µs against the reference's 14.4 µs;
- the default (no route) costs 0.06 µs against 7.5 µs;
- on a 1 000-firing chain, routed telemetry costs about 8× less per firing
  through `run`, and about 2.5× less through `Engine.advance`.
