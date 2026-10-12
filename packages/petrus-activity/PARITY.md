# petrus-activity: parity with `petrus.motus.activity`

Upstream: `upstream/petrus/src/petrus/motus/activity/__init__.py` (one
module, 20 exports). Haskell: `Petrus.Activity` and `Petrus.Activity.Number`.
Differences are in [DIVERGENCES.md](DIVERGENCES.md).

## Inventory

Every name in the module's `__all__`, and where it lives in Haskell:

| upstream | Haskell | checked by |
| --- | --- | --- |
| `MAX_DURATION_SECONDS` | `maxDurationSeconds` | the duration-bound cases of the differential and of `ActivitySeamSpec` |
| `RetryPolicy`, its `__post_init__` | `RetryPolicy` (opaque), `RetryPolicyFields`, `retryPolicy`, `defaultRetryPolicy`, `retryPolicyFields` | differential `RetryPolicy` |
| `RetryPolicy.delay` | `retryDelay` | differential `RetryPolicy.delay`, `test/Main.hs` (bit-for-bit vectors) |
| `dataclasses.asdict(RetryPolicy)` | `retryPolicyJson` | differential (wire bytes) |
| `ExecutionPolicy`, its `__post_init__` | `ExecutionPolicy` (opaque), `ExecutionPolicyFields`, `executionPolicy`, `defaultExecutionPolicy`, `policyFields` | differential `ExecutionPolicy` |
| `ExecutionPolicy.retry_policy` | `policyRetryPolicy` | `test/Main.hs` |
| `dataclasses.asdict(ExecutionPolicy)` (History's `policy` object) | `policyJson` | differential (wire bytes) |
| `ActivityInvocation`, its `__post_init__` | `ActivityInvocation` (opaque, read through its field names), `ActivityInvocationFields`, `activityInvocation`, `invocationFields`, `defaultInvocationFields` and `invocation` (the keyword defaults) | differential `ActivityInvocation` |
| `dataclasses.asdict(ActivityInvocation)` | `invocationJson` | differential (wire bytes) |
| the three dispatch backends' invocation decoders (`local.py` `_decode_invocation`, `absurd.py` `decode_invocation`, `zeromq.py` `_decode_invocation`) | one `invocationFromJson` (with `policyFromMembers` and the `InvocationJsonError` it reports), which Local, Absurd and ZeroMQ each word as their reference does (`invocationRefusal`) | `test/Main.hs` (round trip, legacy two-field policy, first refusing check); each backend's own decode tests and interop |
| `ActivityFailure` (with `_failure_details`) | `ActivityFailure` (opaque), `ActivityFailureFields`, `activityFailure`, `simpleFailure`, `failureFields` | differential `ActivityFailure` |
| `dataclasses.asdict(ActivityFailure)` | `failureJson` | differential (wire bytes) |
| `ActivityError` | `ActivityError` (an `Exception`), `activityError` | `test/Main.hs`; thrown and caught by the Workers in `petrus-motus` |
| `ActivityDeclaration` | `ActivityDeclaration` (opaque), `activityDeclaration`, `declarationName`, `declarationHeartbeatTimeout` | differential `ActivityDeclaration` |
| `dataclasses.asdict(ActivityDeclaration)` | `declarationJson` | differential (wire bytes) |
| `HEARTBEAT_DETAILS_LIMIT` | `heartbeatDetailsLimit` | `HeartbeatSpec` |
| `snapshot_heartbeat_details` | `snapshotHeartbeatDetails` | differential `snapshot_heartbeat_details`, `HeartbeatSpec` |
| `PayloadConverter` (protocol) | `PayloadConverter` (a record of `decodePayload` and `encodePayload`) | through `jsonPayloadConverter` |
| `JsonPayloadConverter` | `jsonPayloadConverter` | differential `JsonPayloadConverter` |
| `DataclassPayloadConverter` | not a value here: typed payloads decode through the Haskell types (`Typed` in `Petrus.Impetus.Binding`, the model decoders in `hamsterdan-readiness`) | [DIVERGENCES.md](DIVERGENCES.md) (1) |
| `ActivityDefinition`, its `__call__` | `ActivityDefinition`, `callActivity` | differential `ActivityDefinition.__call__`, `test/Main.hs` |
| `activity` (the decorator) | `defineActivity` | `test/Main.hs`; the decorator's signature `TypeError`s are enforced by the types ([DIVERGENCES.md](DIVERGENCES.md) (2)) |
| `ActivityExecutionContext` (protocol) | `ActivityExecutionContext` (a record) | the inline context in `petrus-motus` |
| `Activity` (protocol) | an `ActivityDefinition`, or any `ActivityInvocation -> ActivityExecutionContext -> IO Json` a Worker registry holds (`petrus-motus`) | `petrus-motus` Worker suites |
| `AsyncActivityDefinition`, `async_activity`, `AsyncActivity`, `AsyncActivityExecutionContext` | the same `ActivityDefinition` and context: Haskell has no function colours, and the async Worker of `petrus-motus` runs ordinary definitions | `petrus-motus` `AsyncWorkerSpec` ([DIVERGENCES.md](DIVERGENCES.md) (3)) |

`Petrus.Activity.Number` is the Haskell spelling of the reference's
`int | float` fields: a `Number` keeps an integer an integer and a float a
float on the wire, and compares and adds the way Python does.

## Upstream tests

Every upstream test whose subject is this module, and where its Haskell
counterpart runs:

| upstream test | Haskell | status |
| --- | --- | --- |
| `tests/petrus/motus/dispatch/test_attempt_heartbeats.py`: `test_attempt_state_model_covers_renewal_expiry_reassignment_terminal_and_stale_refusal`, `test_activity_declaration_and_execution_policy_require_positive_integer_timeouts`, `test_details_accept_every_json_faithful_shape_and_detach` (7 cases), `test_details_normalize_arbitrary_nested_mappings_and_detach`, `test_details_enforce_json_faithfulness_finite_numbers_and_utf8_byte_limit` | [`HeartbeatSpec`](test/Petrus/Activity/HeartbeatSpec.hs), `test_attempt_heartbeats.py (the Activity values)` / same names | all ported. Python inputs the types cannot express (`True` or `1.5` as a timeout, a non-string key, a tuple, `object()`, mutating a source after the snapshot) are noted where they occur |
| `test_attempt_heartbeats.py`: `test_inline_context_has_synthetic_identity_and_detached_omitted_null_details` | `petrus-motus` ([PARITY.md](../petrus-motus/PARITY.md)) | ported there |
| `test_attempt_heartbeats.py`: the two reconnectable-heartbeat tests | `petrus-motus-absurd` ([PARITY.md](../petrus-motus-absurd/PARITY.md)) | ported there |
| `tests/integration/test_activity_seam.py`: `TestExecutionPolicy` (6), `TestActivityInvocation` (3), the declaration and typed-activity tests | `petrus-impetus` `ActivitySeamSpec` ([ledger](../petrus-impetus/parity-activity-seam.md)) | ported there |
| `tests/petrus/impetus/history_store/test_persistence.py`: `TestRecordCodec.test_the_ratified_wire_shape` (the `policy` object in History) | `petrus-impetus` ([parity-history.md](../petrus-impetus/parity-history.md)) | ported there |
| `tests/petrus/motus/worker/test_async_worker.py`: the decorator tests | `petrus-motus` `AsyncWorkerSpec` ([PARITY.md](../petrus-motus/PARITY.md)) | ported there; 2 not applicable (no function colours) |
| `tests/petrus/engine/test_engine.py`: `test_activity_policy_resolution_belongs_to_engine_and_snapshots_declarations` | `petrus-engine` ([PARITY.md](../petrus-engine/PARITY.md)) | ported there |

## Differential against the reference

[`DifferentialSpec`](test/Petrus/Activity/DifferentialSpec.hs) runs every
value door against the pinned module, live, through
[`activity_oracle.py`](test/activity_oracle.py) and petrus-test-support's
pinned interpreter. `scripts/interop` runs it under the `petrus-activity`
group. Each case goes to both sides with the same fields:

- where the reference accepts, its wire bytes (`dataclasses.asdict` in field
  order, or the door's result, as `json.dumps(..., ensure_ascii=False,
  separators=(",", ":"))` writes it) must equal what petrus-json writes for
  the Haskell value; then the Haskell constructors must accept the
  reference's wire and spell it back byte for byte (Python to Haskell);
- where the reference refuses, the Haskell door must refuse with the same
  message.

| door | cases |
| --- | ---: |
| `RetryPolicy` | 2 500 |
| `RetryPolicy.delay` | 3 036 |
| `ExecutionPolicy` | 2 500 |
| `ActivityInvocation` | 1 500 |
| `ActivityFailure` | 2 500 |
| `ActivityDeclaration` | 800 |
| `snapshot_heartbeat_details` | 2 000 |
| `JsonPayloadConverter` | 2 000 |
| `ActivityDefinition.__call__` | 2 000 |
| **total** | **18 836** |

The corpora are generated from fixed seeds. Each door both accepts at least a
fifth of its cases and refuses at least a twentieth. They aim at the edges:

- numbers: zero and -0.0, subnormals, the one-billion-second bound, NaN and
  the infinities, integers past 2^53, past the largest double (CPython's
  `OverflowError: int too large to convert to float`) and past 4300 digits
  (CPython's `ValueError` in `repr` and `json.dumps`);
- strings at the 4096- and 128-character bounds, counted in code points;
- details within a few bytes of the 16 384-byte and 65 536-byte bounds;
- names that `repr` must quote or escape.

Bringing the port under this differential changed five places where it
refused, or spelled a refusal, differently from the reference:

- `math.isfinite` on a huge integer;
- the attempts `repr` past 4300 digits;
- `json.dumps`'s integer-limit message in failure details, payloads and
  heartbeat details;
- `repr` of names in `ActivityDefinition.__call__`;
- int-to-float rounding past 2^53 in `RetryPolicy.delay`.

## Interop

The Activity values travel inside other formats, which are checked against
the reference in their own packages:

- History records (`petrus-impetus` codec, `petrus-history-store`);
- Local, ZeroMQ and Absurd dispatch (`petrus-motus`, `petrus-motus-zeromq`,
  `petrus-motus-absurd`).

This package's wire is the `asdict` shape of each value, and the
differential checks it in both directions.

## Performance

[bench/RESULTS.md](bench/RESULTS.md): each door over 100 inputs, against the
pinned module.
