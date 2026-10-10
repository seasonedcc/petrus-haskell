## Pi native runtime (`Petrus.Agenticus.Runtime.Pi`, `Petrus.Agenticus.Runtime.PiRecovery`)

These choices are deliberate. `differential/pi_corpus.json` pins the wire
bytes, validator results, fingerprints, records and ledger files on both
sides of each one. Its single accepted difference is item 6.

1. **Protocols are records of operations.** The reference's structural
   protocols are records here, whose fields are the protocol's methods:
   - continuation and Turn storage: `PiContinuationOperations`,
     `PiTurnOperations`;
   - connection custody: `PiConnectionCustody`;
   - helper clients and factories: `PiHelperClient`, `PiHelperFactory`;
   - the operation ledger: `PiOperationLedger`.

   `piConnectionCustody` adapts the real `AgentConnectionCustody`, and
   `sqlitePiOperationLedger` adapts the SQLite ledger.

2. **Private attributes are explicit state with named setters.** The
   reference's tests assign private adapter attributes or monkeypatch private
   methods (`_binding_current`, `_start`, `_receipt`, `_thread_start` and
   others). The port keeps that state in `PiAdapterRuntime`, which is
   changed only through these functions:
   - `modifyAdapterRuntime`, `setAdapterConfig`, `setAdapterClock`;
   - `setAdapterHooks`, which takes `PiAdapterHooks`;
   - `setSubprocessStartFrame`.

   The recovered runtime takes a `PiAdapterSurface`
   (`newPiRecoveredRuntimeWith`) in place of a patched adapter. Each hook
   defaults to the reference's own behaviour.

3. **Python exception classes without a Haskell type.** The port raises
   `AgenticusError`. Exceptions the reference raises from library code keep
   their Python class name as `OtherError`:
   - `binascii.Error` (strict base64) becomes `OtherError "Error"`;
   - `UnicodeDecodeError` becomes `OtherError "UnicodeDecodeError"`, with
     CPython's exact message (from `Petrus.Impetus.Internal.PyJson`);
   - `OverflowError` becomes `OtherError "OverflowError"`.

   Both `binascii.Error` and `UnicodeDecodeError` are `ValueError`
   subclasses upstream. The tests' `pytest.raises(ValueError)` therefore
   accepts all three names (`raisesValueLike`).

4. **`_strict_load` refusals carry no message.** The reference's
   `_strict_load` raises `ValueError`, `UnicodeDecodeError` or
   `JSONDecodeError`. Every caller maps all three to one protocol code
   (`malformed-frame`, `malformed-complete`, a bare `ValueError`, or a
   session message). The port's `strictLoad` therefore returns `Left ()`.
   The corpus compares acceptance and the decoded value, not
   `JSONDecodeError` text.

5. **Non-ASCII base64 text is refused before decoding.**
   `base64.b64decode(str, validate=True)` raises `ValueError: string
   argument should contain only ASCII characters` before it applies any
   base64 rule. `pyB64DecodeText` checks in the same order.

6. **Lone surrogate escapes decode to U+FFFD.** CPython's scanner admits
   `"\ud800"` into a `str`, which `Data.Text` cannot hold. Two cases follow:
   - **Sessions and credentials.** `strictLoad` runs the CPython-faithful
     scanner and accepts the same documents. Each lone surrogate becomes
     U+FFFD. `_validate_session` and `_validate_native_auth` inspect only
     structure, so they accept exactly what the reference accepts. The
     session bytes themselves are stored and resent untouched.
   - **Helper frames.** `strictFrameLoad` refuses a frame with a lone
     surrogate escape as `malformed-frame`. The reference admits such a
     frame. It then either fails later on that member (`text.encode()` in a
     `complete` frame gives `malformed-complete`) or forwards the string to
     the Hands gateway. The port does not invent a replacement character
     inside model output or tool parameters.

   This is the one corpus case recorded as a known divergence
   (`strictLoadDivergences` in `PiDifferentialSpec`).

7. **Ledger rows with foreign column types.** `_decode` passes raw SQLite
   values into `PiOperationRecord`. The port mirrors the values a tampered
   file can hold:
   - A `BLOB` text column renders as `str(bytes)`, for example `b'op-a'`.
   - A `REAL` `accepted_appends` behaves as its integer when it is integral.
     Otherwise it fails the record's own checks with the reference's
     message.
   - Any other non-integer `accepted_appends` or `sequence` is refused as
     `ValueError` ("must be an integer column"). The reference would build a
     record around the foreign value. The corpus's text `'1'` case stores an
     integer under the column's affinity and agrees.

8. **`probe` fails closed on any synchronous exception.** The reference
   catches `OSError`, `ValueError`, `KeyError`, `JSONDecodeError` and
   `SubprocessError`, and reports `protocol-unavailable`. The port reports
   the same issue for every non-asynchronous exception and rethrows
   asynchronous ones.

9. **Reprs.** `renderPiRuntimeConfig`, `renderPiRuntimeInvocation` and
   `renderPiRuntimeAdapter` reproduce the reference's dataclass reprs, with
   the same `repr=False` omissions. There is one exception. Inside the
   invocation, the `connection=` member uses the derived `Show` of
   `petrus-agenticus-core`'s `ConnectionView`
   (`ConnectionView {identity = ..., ...}`), not the reference's
   `ConnectionView(identity=ConnectionIdentity(...), ...)`. Both carry only
   nonsecret identity, status, epochs and digest. No secret, prompt or
   session byte reaches any render; the canary test pins this.

10. **Fresh session identities.** A fresh `session_id` is a uuid4 drawn from
    crypton's random generator, not `uuid.uuid4()`. Both are canonical,
    lowercase RFC 4122 version-4 identities. The corpus takes the fresh
    value from the reference's frame, and the bytes then agree.

11. **No logging.** The reference logs nothing secret, and its
    `test_canaries_never_render_log_or_error` checks `caplog`. The port does
    not log, so only the renders and refusals are checked.

12. **Test-only substitutions** (`test/Petrus/Agenticus/Runtime/PiSupport.hs`):
    - The reference mutates a frozen lease with `object.__setattr__`. The
      test Territory instead wraps the local Motus provider, relabels its
      leases, attachments, provenance and cleanup, and can drift its lookup.
    - The reference passes `object()` as a malformed checkpoint. The port's
      checkpoint is typed, so the malformed case returns a publication for
      another operation id, which the adapter refuses in the same way.
    - `test_import_has_no_node_or_npm_dependency` becomes a structural check
      (see `parity/pi.md`).

## Pi model phase (`Petrus.Agenticus.Runtime.PiModelPhase`)

1. **Protocols are records.** `PiModelPhaseOperations`,
   `PiModelPhaseCustody`, `PhaseClient` and `PhaseFactory` replace the
   structural protocols. `piModelPhaseCustody` adapts a
   `PiConnectionCustody`. Because the types are fixed, the reference's
   `isinstance` refusals cannot occur and have no port:
   - `TypeError("... exact configuration and connection")`;
   - `TypeError("... exact collaborators")`;
   - a non-`Materialization` or non-`AttachmentFence` custody answer;
   - a non-`PiModelPhasePublication` answer (`publication-mismatch`).
2. **Adapter attributes are explicit state.** The reference's tests assign
   `adapter.node`, `adapter.sdk_entrypoint`, `adapter.factory` and
   `adapter.config`. The port provides `setModelPhaseNode`,
   `setModelPhaseSdkEntrypoint`, `setModelPhaseFactory` and
   `modifyModelPhaseConfig`. `isinstance(self.factory, _SubprocessFactory)`
   becomes the factory's `isSubprocess` flag.
3. **Payload refusal messages.** `_payload` lets the strict parser's own
   exception escape: `JSONDecodeError`, a bare `ValueError` for a constant or
   a duplicate name, or `UnicodeDecodeError`. The port raises `ValueError`
   with the reference's own shape message ("Pi model phase transcript is
   invalid" or "Pi model phase assistant is invalid") for every refusal.
   Every caller inside the module maps these to one protocol code anyway.
4. **The helper process.** A writer thread and a reader thread replace the
   `selectors` loop over non-blocking pipes. They keep the same 20 ms poll,
   heartbeat cadence, wall deadline, frame bounds and post-exit `stdin`
   close. `close` kills the process group, waits one second for the exit,
   and reports whether the stderr drain finished within one more second, as
   `thread.join(1)` does. If `wait(timeout=0.1)` expires, the reference
   raises `TimeoutExpired`, which `_execute` turns into `runtime-failed`. The
   port raises `OtherError "TimeoutExpired"`, which ends the same way.
5. **Cleanup in `finally`.** If closing the client or releasing the
   materialization raises during cleanup, the reference lets the exception
   escape from `close()`, or records `clean = False` for release. The port
   records `clean = False` for both, so the outcome is `cleanup-unverified`.
6. **`probe` fails closed on any synchronous exception**, as item 8 above
   describes for `pi.py`.

## Pi application (`Petrus.Agenticus.Runtime.PiApplication`)

1. **Protocols are records.** `PiApplicationContinuationOperations`,
   `PiApplicationTurnOperations`, `PiApplicationConnectionCustody`,
   `ApplicationClient` and `ApplicationFactory` replace the structural
   protocols. `applicationCustody` adapts a `PiConnectionCustody`, and through
   it the real `AgentConnectionCustody`. Because the types are fixed, the
   reference's `isinstance` refusals cannot occur and have no port:
   - `TypeError("Pi application codec requires exact operations")`;
   - `TypeError("Pi application custody returned a foreign payload")`;
   - `TypeError("Pi application adapter requires exact collaborators")`;
   - `TypeError("Pi application step results must be ToolResult values")`;
   - the invocation's type checks on the identities, the `HandsGateway` and
     the `Continuation`;
   - a custody answer that is not a `Materialization`, `AttachmentFence`,
     `AdmissionResult` or `ReleaseResult`. The checks on the values (mode,
     fence, admission and release) remain.
2. **Adapter attributes are explicit state.** The reference's tests assign
   `_installation`, `_node`, `_coding`, `_core`, `_ai`, `_config` and
   `_clock`, and they monkeypatch `_binding_current`. The port provides:
   - `modifyApplicationAdapterRuntime`;
   - `setApplicationAdapterConfig`, which validates, as `dataclasses.replace`
     does;
   - `setApplicationAdapterClock`;
   - `ApplicationAdapterHooks.bindingCurrent`.

   `isinstance(self._factory, _SubprocessFactory)` becomes the
   `subprocessFactoryInstalled` flag.
3. **The helper process.** A reader thread feeds a queue that is polled every
   50 ms, in place of the `selectors` loop. The abort, grace, frame, event and
   tool bounds are unchanged. When the helper does not exit within the grace,
   the reference raises `subprocess.TimeoutExpired`, and `_execute` turns it
   into `runtime-failed`. The port reports `helper-exit-inconsistent`, as the
   native port does. Neither one publishes.
4. **Frames.**
   - As in the native port, a lone surrogate escape in a helper frame is a
     `malformed-frame`.
   - A `tool_call` whose `method` is an array or an object makes the
     reference's `method not in _METHODS` raise `TypeError`, so the run ends
     as `runtime-failed`. The port reports `malformed-tool-call`. Neither one
     reaches the gateway.
5. **Configuration numbers.** The three durations are `Double`s, so a bool
   cannot be passed. `repr` also differs for an integral duration: the
   reference renders the `int` it was given (`1`), and the port renders `1.0`.
6. **`probe` fails closed on any synchronous exception.** When `package.json`
   is not an object, the reference lets an `AttributeError` escape. The port
   reports `protocol-unavailable`.
