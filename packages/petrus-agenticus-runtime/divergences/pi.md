## Pi native runtime (`Petrus.Agenticus.Runtime.Pi`, `Petrus.Agenticus.Runtime.PiRecovery`)

These choices are deliberate. `differential/pi_corpus.json` pins the wire
bytes, validator results, fingerprints, records and ledger files on both
sides of each one, and every case matches.

1. **Protocols are records of operations.** The reference's structural
   protocols are records here, whose fields are the protocol's methods:
   - continuation and Turn storage: `PiContinuationOperations`,
     `PiTurnOperations`;
   - connection custody: `HostConnectionCustody`
     (`Petrus.Agenticus.Runtime.Custody`, shared by every host);
   - helper clients and factories: `PiHelperClient`, `PiHelperFactory`;
   - the operation ledger: `PiOperationLedger`.

   `hostConnectionCustody` adapts the real `AgentConnectionCustody`, and
   `sqlitePiOperationLedger` adapts the SQLite ledger.

2. **Private attributes are fixed at construction.** The reference's tests
   assign private adapter attributes or monkeypatch private methods
   (`_binding_current`, `_start`, `_receipt`, `_thread_start` and others)
   on a built adapter. The port takes them when the adapter is built:
   - `newPiRuntimeAdapterWith` takes `PiAdapterOptions`: the clock, the
     helper factory, `PiAdapterHooks`, and `prepare`, the readiness a probe
     would record in `PiAdapterRuntime`;
   - `SubprocessOptions.adjustStart` rewrites a helper client's `start`
     frame (the reference assigns `client._start`).

   The configuration, clock and hooks are plain values; only the probe
   changes `PiAdapterRuntime`. A test that needs a mid-run change keeps the
   switch in its own double.

   The recovered runtime takes a `PiAdapterSurface`
   (`newPiRecoveredRuntimeWith`) in place of a patched adapter. Each hook
   defaults to the reference's own behaviour.

3. **Python exception classes without a Haskell type.** The port raises
   `AgenticusError`. Exceptions the reference raises from library code keep
   their Python class name as `OtherError`:
   - `binascii.Error` (strict base64) becomes `OtherError "Error"`;
   - `UnicodeDecodeError` becomes `OtherError "UnicodeDecodeError"`, with
     CPython's exact message (from `Petrus.Json.Python.Scanner`);
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

6. **Lone surrogate escapes (resolved, audit finding SDA-12).** CPython's
   scanner admits `"\ud800"` into a `str`; so do `strictLoad` and
   `strictFrameLoad`, as a WTF-8 `Text` (`Petrus.Json.Wtf8`). Wherever the
   reference calls `str.encode()` on such a string, the port checks first
   (`encodeRefusal` in `Petrus.Agenticus.Internal.Validate`) and fails with
   CPython's message. The class is `ValueError`, the base of CPython's
   `UnicodeEncodeError`, which is what every `except` on the way tests for.
   A helper frame that holds one is therefore failed, or forwarded, where
   the reference does it:
   - in a `tool_call`'s parameters, the call reaches the Hands gateway;
   - in a `tool_result` that echoes one, `helper-pipe-failed` (`_write`);
   - in a `complete` frame's text or session identity: `malformed-complete`,
     and in the A5 loop also when the delta's messages hold one (the
     combined transcript's encode);
   - in a `tool_call` identity: the encode failure escapes the loop, so the
     Turn ends `runtime-failed`;
   - in a method name: `malformed-tool-call`; in a frame type:
     `unknown-frame` (`frame-order` in the A5 loop); in a member name:
     `frame-order`; in a `failed` code: `malformed-failed` (`frame-order` in
     the A5 loop);
   - in the model phase's assistant `api` (`malformed-complete`) or a tool
     call's identity (`malformed-proposal`), through the `_text` validators.

   Past the gateway, the workspace adapter (`Petrus.Agenticus.Hands.Workspace`
   in petrus-agenticus) matches CPython's `surrogateescape` argv: U+DC80–
   U+DCFF reach the command as raw bytes, and any other surrogate fails
   building it (`territory command failed`). A staged write's content
   fails its `content.encode()` after the command ran, as in the reference.

   The forged helpers in `PiSpec` and `PiApplicationSpec` cover each frame
   case, `PiModelPhaseSpec` the assistant, and `WorkspaceSpec` the
   workspace adapter. The differential corpus's lone surrogate case now
   matches.

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
   `HostConnectionCustody`. Because the types are fixed, the reference's
   `isinstance` refusals cannot occur and have no port:
   - `TypeError("... exact configuration and connection")`;
   - `TypeError("... exact collaborators")`;
   - a non-`Materialization` or non-`AttachmentFence` custody answer;
   - a non-`PiModelPhasePublication` answer (`publication-mismatch`).
2. **Adapter attributes are fixed at construction.** The reference's tests
   assign `adapter.node`, `adapter.sdk_entrypoint`, `adapter.factory` and
   `adapter.config`. The port's tests build an adapter over the same parts
   with those values instead; only the probe changes the Node and SDK
   entrypoint afterwards. `isinstance(self.factory, _SubprocessFactory)`
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
   protocols. `applicationCustody` adapts a `HostConnectionCustody`, and through
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
2. **Adapter attributes are fixed at construction.** The reference's tests
   assign `_installation`, `_node`, `_coding`, `_core`, `_ai`, `_config` and
   `_clock`, and they monkeypatch `_binding_current`.
   `newPiApplicationRuntimeAdapterWith` takes `ApplicationAdapterOptions`
   instead: the clock, the factory, `ApplicationAdapterHooks.bindingCurrent`,
   and `prepare`, the readiness a probe would record. The configuration is
   validated once, as `dataclasses.replace` does.

   `isinstance(self._factory, _SubprocessFactory)` becomes the
   `subprocessFactoryInstalled` flag.
3. **The helper process.** A reader thread feeds a queue that is polled every
   50 ms, in place of the `selectors` loop. The abort, grace, frame, event and
   tool bounds are unchanged. When the helper does not exit within the grace,
   the reference raises `subprocess.TimeoutExpired`, and `_execute` turns it
   into `runtime-failed`. The port reports `helper-exit-inconsistent`, as the
   native port does. Neither one publishes.
4. **Unhashable methods.** A `tool_call` whose `method` is an array or an
   object makes the reference's `method not in _METHODS` raise `TypeError`,
   so the run ends as `runtime-failed`. The port reports
   `malformed-tool-call`. Neither one reaches the gateway.
5. **Configuration numbers.** The three durations are `Double`s, so a bool
   cannot be passed. `repr` also differs for an integral duration: the
   reference renders the `int` it was given (`1`), and the port renders `1.0`.
6. **`probe` fails closed on any synchronous exception.** When `package.json`
   is not an object, the reference lets an `AttributeError` escape. The port
   reports `protocol-unavailable`.

## Pi A2 host (`Petrus.Agenticus.Runtime.PiA2Host`)

1. **Protocols and private attributes.** `PiA2RuntimeHost` is an abstract
   type built only by the composers, so the reference's
   `TypeError("Protocols cannot be instantiated")` cannot occur. The private
   attributes its tests reach (`_provider`, `_adapter`, `_ledger`, `_bodies`,
   `_storage`, `_fingerprint`, `_territory_operation`) are accessors that
   `PiA2Host.Internal` exports, and `type(host._adapter._factory)` is
   `hostFactoryKind`. Monkeypatching `host._bodies.publish` becomes
   `PiA2HostHooks.publishBodies`.
2. **Fixed types.** These checks have no port, because the types rule them
   out:
   - `TypeError` for a `workspace_archive` that is not `bytes`;
   - `TypeError` for capabilities that are not `ToolMethod` values (an empty
     set is still refused, with the reference's message);
   - the `PiA2DirectAuthority` and `PiA2ScriptedCall` type checks.
3. **Validation is explicit.** Dataclass `__post_init__` validation becomes
   `newPiA2RuntimeHostConfig`, `mkPiA2RuntimePolicy`, `newPiA2RuntimeStart`,
   `mkPiA2DirectAuthority`, `mkPiA2ScriptedCall` and `mkPiA2ScriptedTurn`.
   The composers validate the configuration, and `startHost` validates the
   start, so an unvalidated record never reaches the host.
4. **Archive errors.** `validate_workspace_archive` raises Motus's own
   `ExecutionError` of kind `ValueError` in the port. `newPiA2RuntimeStart`
   re-raises it as the `ValueError` the reference raises, with the same
   message.
5. **Erasable buffers.** The authority supplier returns `ScrubbedBytes`
   instead of a `bytearray`. As in the reference, the host copies the key into
   custody and then zeroes the supplied buffer.
6. **Child processes.** The killed-host and reconstructed-host tests
   re-execute the test binary (with `PETRUS_PI_A2_HOST_CHILD`) instead of
   running `python -c`.
7. **`/bin/true`.** The spec uses `/usr/bin/true` when `/bin/true` is absent
   (macOS). The host's own default test command is still `("/bin/true",)`,
   as in the reference.
8. **Scripted factory.** `piA2ScriptedFactory` takes a list, which may be
   infinite (the benchmark uses `repeat`). The reference's tuple is finite;
   `compose_pi_a2_scripted_runtime` still refuses an empty script with the
   reference's `TypeError`.
