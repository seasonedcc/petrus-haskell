## Claude host (`Petrus.Agenticus.Runtime.Claude`)

These choices are deliberate. None of them changes a persisted byte: the
Continuation payload's transcript is produced by `encodeTranscript`, which
`differential/hosts_corpus.json` pins byte for byte against
`_encode_transcript`, together with `_decode_transcript`,
`_canonical_input`, `_sanitize`, `_uuid` and the payload validator.

1. **The SDK runs in a sidecar, and the host logic stays in Haskell.** A
   Haskell process cannot import the Python Claude Agent SDK.
   `data/claude_sidecar.py` builds the official `ClaudeSDKClient` from the
   adapter's options, and the client's work comes back over a JSON-lines
   pipe:
   - the PreToolUse hook;
   - the `mcp__petrus_hands__*` tool handlers;
   - the session store's `append` and `load`.

   Haskell answers each of those calls. Admission, connection custody, the
   transcript mirror, publication and cleanup evidence never run in Python.
   Options that are Python objects upstream travel as fields of
   `ClaudeOptions` (the session store and the stderr policy), and the
   sidecar rebuilds them on its side.

   One sidecar process serves every client of a `SidecarPool` (per
   interpreter and search path), each on its own channel, so the SDK is
   imported once, as upstream imports it once into its interpreter.
   `ClaudeSidecar.pool` defaults to `defaultSidecarPool`, one per Haskell
   process. `withSidecarPool` gives an owner its own pool, closed with it.
   When a sidecar dies, every channel on it ends. Each pending call then
   fails at once, and so does each later call. The next client starts a new
   sidecar. Its
   clients share one asyncio loop, where upstream gives each operation a
   loop on its own thread, and each operation starts as an eagerly started
   task, as upstream awaits it directly. The process inherits the
   environment it was started with, so environment changes made later by
   the Haskell process do not reach the SDK.

2. **Protocols are records of operations.** `_Client` and `_ClientFactory`
   are `ClaudeClient` and `ClaudeClientFactory`. `_OfficialFactory` is
   `officialFactory` over a `ClaudeSdk` record, whose default is
   `sidecarSdk`. Storage is `ClaudeContinuationOperations` and
   `ClaudeTurnOperations`. Connection custody is the `HostConnectionCustody`
   record (`Petrus.Agenticus.Runtime.Custody`, the reference's
   `PiConnectionCustody`) that every host shares.

3. **The client is released explicitly.** Upstream, the official
   client's resources go when the object is garbage-collected after
   `disconnect`. `ClaudeClient` has one more operation, `release`, which
   ends the client's channel: the sidecar cancels the client's pending
   operations, disconnects it when it was connected and not disconnected,
   and then ends the channel. `release` answers `False` when that has not
   happened within the grace. An unproven release downgrades the cleanup to
   unverified, the same outcome upstream reports for a surviving child. A
   client stuck past the grace stays in the shared process, which is not
   killed for it, since other clients share it. `closeSidecarPool` ends each
   sidecar's input and kills the sidecar's process group if it has not
   exited within the pool's grace. When the Haskell process exits, the
   sidecar's input closes. The sidecar then gives every open channel 10
   seconds to tear down, and exits.

   Tests: `ClaudeSpec`'s "shared sidecar" examples, each on its own pool,
   cover the shared process:
   - Three turns run concurrently with a fourth that is cancelled mid-turn.
     Each completes on its own channel, with its own prompt in its own
     session mirror, and all of them run on one process.
   - The sidecar crashes under one client while another waits mid-turn.
     Both settle within seconds as `failed`/`cleanup-unverified`, which is
     upstream's outcome for a client whose disconnect fails. The next turn
     starts a new process.
   - One client's teardown is stuck past the release grace. Another
     client's whole turn completes during it. The stuck one settles
     cancelled with an unverified cleanup, and closing the pool still ends
     the process.

   These tests found one bug, now fixed: a call made after the channel had
   ended waited out the disconnect timeout (25 s).

4. **Monkeypatched seams are explicit hooks.** The probe's
   `importlib.metadata.version` and `importlib.import_module` are
   `ClaudeProbeHooks`; `officialClaudeProbeHooks` asks the sidecar.
   `ClaudeAdapterOptions.ready` stands for the tests' direct assignment of
   the adapter's readiness, fixed at construction.

5. **The CLI wrapper's interpreter is explicit.** Upstream writes the
   private wrapper with a `#!{sys.executable} -I` line. A Haskell process
   has no interpreter of its own, so `ClaudeAdapterOptions.interpreter`
   names one. `claudeAdapterOptions` resolves `python3` on `PATH`, falling
   back to `/usr/bin/python3`. The wrapper's text is otherwise the
   reference's.

6. **No logging.** The reference's canary test also scans `caplog`. The
   port writes no log records, so its test scans every rendering
   (`render…` functions and `Show` instances) for the same canaries.
