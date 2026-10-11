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

   One sidecar process serves every stream of a Haskell process (per
   interpreter and search path), each on its own channel, so the SDK is
   imported once, as upstream imports it once into its interpreter. Its
   streams share one asyncio loop, where upstream gives each operation's
   coroutine a loop on its own thread. A pull runs as an eagerly started
   task, as upstream awaits `__anext__` directly, and the first pull is
   requested together with the stream (upstream starts iterating as soon as
   `execute` returns). The process inherits the environment it was started
   with, so environment changes made later by the Haskell process do not
   reach the SDK, where upstream's in-process SDK would see them.

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

   An exception raised while computing the size or reading one attribute
   crosses in place of that part as `{"raised": kind}`, and admission
   raises it exactly where upstream's `_read_stream` would read that part
   (after the count bound, before the byte bounds; `type` before `subtype`
   in `_admit_initial`, `session_id` before `type` in `_admit_later`, and so
   on), so a part upstream never reaches never matters. `_run` then settles
   it as upstream does: a `TimeoutError` is `deadline-exceeded`, a
   `CancelledError` a cancelled Turn, anything else `client-failed`; an
   `AttributeError` is `getattr`'s default, `None`. A pull that raises
   crosses the same way. The sidecar example `settles events that raise
   where upstream reads them as the reference does` runs 22 such streams
   through the reference's own adapter and through the port, against the
   same fake SDK, and compares outcome, appends, termination code and
   cleanup code.

   What remains:
   - The sidecar reads every part of an event once, as it arrives. A part
     upstream never reaches is still read (its exception is dropped), so a
     property with side effects runs where upstream's would not.
   - An exception that is not an `Exception` (a `KeyboardInterrupt`,
     `SystemExit` or `GeneratorExit` from a property) settles
     `client-failed`. Upstream it escapes `_run` and ends the worker thread
     without a settlement.
   - An SDK that raises Petrus's own `RuntimeProtocolError` from a property
     would settle with that error's code upstream; the port settles
     `client-failed`.

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
