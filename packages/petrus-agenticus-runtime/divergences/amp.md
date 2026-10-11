## Amp host (`Petrus.Agenticus.Runtime.Amp`)

These choices are deliberate. The persisted Continuation payload
(`{"schema_version": 1, "thread_id": ...}`), the SDK execution options and
stream admission are pinned against the reference by
`differential/hosts_corpus.json`. That includes every protocol code over
600 generated streams.

1. **The SDK runs in a sidecar, and admission stays in Haskell.** A Haskell
   process cannot import the Python Amp SDK. `data/amp_sidecar.py` does only
   the SDK calls `amp.py` makes:
   - `importlib.metadata.version("amp-sdk")`;
   - the `AmpOptions` and `execute` protocol check;
   - `execute(prompt, AmpOptions(**options))`.

   Upstream's async iterator becomes an `AmpEventStream`: pulls, plus the
   two finalizers upstream calls (`athrow(CancelledError())`, then
   `aclose()`). The sidecar injects the cancellation into the SDK generator
   just as upstream does, so the pinned SDK reaps its CLI.

2. **Events cross the pipe reduced to what admission reads.** Each event
   crosses as two things:
   - its `_event_size` byte count (`model_dump_json` length, or
     `encoded_size`), `null` when it cannot be measured;
   - the five attributes `_event_value` reads.

   Upstream's comparisons treat values as follows, and the port does the
   same:
   - A `str`, `int` or `float` subclass (a `StrEnum` event type, say)
     crosses as its base value, so it compares as it does upstream.
   - Any other non-scalar value crosses as `{"opaque": type, "hashable":
     bool}`. It equals no string or boolean admission compares against.
   - An unhashable value (a list, a dict, a model without `__hash__`)
     settles `client-failed`, as upstream, where `value in {...}` raises
     `TypeError` and `_run` maps it.
   - A hashable one gets upstream's protocol code (`unknown-event`,
     `malformed-terminal`).

   One difference remains. Upstream, an exception raised by
   `model_dump_json` or by an attribute read escapes to `_run` and settles
   `client-failed`. The sidecar reports `null` (`malformed-event`) or an
   opaque value instead. Neither the corpus nor the fake SDK covers this
   path.

3. **Protocols are records of operations.** Storage is
   `AmpContinuationOperations` and `AmpTurnOperations`. The probe's
   environment is `AmpProbeHooks {resolveCli, installedSdkVersion, runCli,
   sdkProtocolReady}`, which stands for upstream's monkeypatched
   `_resolve_amp_cli`, `importlib.metadata.version`, `subprocess.run` and
   SDK protocol check.
   `officialProbeHooks` is the reference's own behaviour, through the
   sidecar.

4. **The provider-managed binding is a record.** `AmpProviderManagedBinding`
   exposes the provider-neutral `AttachmentBinding` record
   (`ampAttachmentBinding`) with kind `amp-provider-managed`. Its `cancel`,
   `settle` and empty archive export behave as upstream's binding methods.
