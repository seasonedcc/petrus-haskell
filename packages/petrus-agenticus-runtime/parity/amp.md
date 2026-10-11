# Amp host parity

Upstream module: `petrus/agenticus/runtime/amp.py` (the exact Amp A1
provider-managed lane), pinned at `upstream/petrus` 3f85fc2.

Haskell:

- `Petrus.Agenticus.Runtime.Amp`: pins, descriptors, the continuation
  payload and codec, the provider-managed binding, the operation, stream
  admission and the adapter.
- `data/amp_sidecar.py`: hosts the optional Python Amp SDK. It does only
  what `amp.py` does through the SDK: reads `importlib.metadata.version`,
  checks the `AmpOptions` and `execute` protocol, and runs
  `execute(prompt, AmpOptions(**options))`. Each event is reduced to what
  the adapter reads: the `_event_size` byte count and the five
  `_event_value` attributes. Admission, publication and cleanup evidence
  stay in Haskell.

Spec: `test/Petrus/Agenticus/Runtime/AmpSpec.hs`. Each `it` label is the
upstream test name; parametrized cases keep pytest's ids.

## Fixtures

| Reference fake | Haskell |
| --- | --- |
| async-generator `execute` fakes | `AmpEventStream` records: pulls plus the two finalizers upstream calls (`athrow(CancelledError())` and `aclose()`) |
| `monkeypatch` of the probe environment | `AmpProbeHooks` |
| continuation and Turn fakes | records over `AmpContinuationOperations` and `AmpTurnOperations`; the connection is only a `ConnectionView` fence, as upstream |

`test/fixtures/amp/amp_sdk` is a fake SDK package with the pinned SDK's
protocol surface (`AmpOptions.model_fields` and `execute(prompt, options)`).
It yields events that carry `model_dump_json`. The sidecar tests run it
under the pinned CPython (`pythonExecutable`).

## `tests/petrus/agenticus/runtime/test_amp.py` (15 functions, 19 cases)

| Upstream test | Notes |
| --- | --- |
| `test_descriptors_freeze_provider_owned_amp_native_profile` | |
| `test_continuation_payload_and_codec_are_exact_and_opaque` | |
| `test_config_and_invocation_hide_prompt_and_reject_implicit_profile_changes` | |
| `test_probe_requires_exact_sdk_cli_and_orb_protocol_before_start` | |
| `test_probe_reports_absent_sdk_without_importing_or_materializing` | |
| `test_new_turn_uses_only_orb_project_policy_and_settles_one_batch` | |
| `test_continue_loads_only_exact_amp_thread_and_reuses_provider_placement` | |
| `test_malformed_or_incomplete_stream_fails_without_an_append` (5 ids) | `[events0-missing-system-init]`, `[events1-malformed-thread-id]`, `[events2-event-thread-mismatch]`, `[events3-terminal-result-missing]`, `[events4-duplicate-terminal]` |
| `test_provider_error_is_typed_without_retaining_raw_diagnostic` | |
| `test_protocol_failure_finalizes_the_sdk_stream` | |
| `test_cancellation_is_idempotent_but_remote_provider_cleanup_stays_unverified` | |
| `test_wait_timeout_does_not_change_operation_and_active_close_is_refused` | |
| `test_operation_identity_is_lookup_first_and_conflicts_fail_before_provider_call` | |
| `test_wrong_catalog_snapshot_fails_before_sdk_execution` | |
| `test_amp_defining_module_imports_without_optional_sdk` | The import blocker becomes an adapter built over a sidecar whose interpreter does not exist: building the adapter and descriptors never runs it. |

### Sidecar examples (not in the reference)

These drive `amp_sidecar.py` against the fake SDK under the pinned CPython.
They are this host's cross-language checks: the options cross the pipe one
way, and the event sizes and values cross the other.

- `reads the SDK version and protocol through the sidecar`
- `runs one Orb turn through the official execute`
- `injects the cancellation into the SDK generator`

## Differential corpus

The `amp` section of `differential/hosts_corpus.json` (seed 4242), replayed
by `HostsDifferentialSpec`:

| Section | Cases | What it covers |
| --- | ---: | --- |
| `bounded_text` | 200 | `_bounded_text` |
| `thread_id` | 208 | `_thread_id` |
| `safe_final_text` | 200 | `_safe_final_text` |
| `payload_from_data` | 69 | `AmpContinuationPayloadV1.from_data` and `to_data` |
| `execution_options` | 30 | `_execution_options`, member order included |
| `streams` | 600 | `_read_stream` over whole streams: every protocol code, the event, byte and total bounds, continuation-thread mismatch, unhashable values (`client-failed`), and the admitted candidate |

## Benchmarks

See `bench/results-hosts.md`: `amp-stream-admit` 3.5× and
`amp-final-text` 1.8× the reference's speed.

## `tests/petrus/agenticus/runtime/test_amp_real.py` (1 function)

Not ported. It runs the real Amp SDK and CLI against a real Amp account and
a provider-managed Orb. Upstream it is opt-in: it is skipped unless
`PETRUS_RUN_CV16_AMP_A1=1` is set together with credentials. Porting it
would add credentials and paid provider calls to the default suite, and it
would test the same sidecar path that the fake SDK already reaches.
