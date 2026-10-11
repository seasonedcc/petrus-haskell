# petrus-agenticus-runtime divergences

These choices are deliberate. None of them changes a `thread.json` byte, a
History byte or a refusal; `differential/runner_corpus.json` pins all three.

The Pi hosts (native, recovery, model phase, application and A2 host) are
covered in [divergences/pi.md](divergences/pi.md). The Codex, Claude and Amp
hosts are covered in [divergences/codex.md](divergences/codex.md),
[divergences/claude-a2.md](divergences/claude-a2.md) and
[divergences/amp.md](divergences/amp.md).

## Local Agent-as-a-Net runner (`Petrus.Agenticus.Runtime.AgentNetRunner`)

1. **The repository is a record of two actions.** `AgentNetThreadRepository`
   holds `load` and `save` (compare-and-save), standing in for the reference's
   `runtime_checkable` `Protocol`. `jsonThreadRepository` is the reference's
   `JsonAgentNetThreadRepository`. It writes the same compact sorted ASCII
   JSON to `.thread.json.<hex>.tmp`, opened `O_CREAT | O_EXCL` with mode
   0600. It then fsyncs the file, renames it over `thread.json` and fsyncs
   the directory. The temporary name uses 16 random bytes in hex instead of
   `uuid4().hex`. Both are 32 hex characters, and the name never reaches
   durable state.

2. **The runner is mutable only through explicit operations.** The reference
   assigns `runner.repository` directly in one test. The Haskell runner keeps
   the repository and the projection in `IORef`s. `setRunnerRepository` is
   the one exported setter, which exists for that test.

3. **Halt-code refusals use a local `repr`.** `HaltCode(value)` raises
   `ValueError: <repr(value)> is not a valid HaltCode`. The runner renders
   `repr` of the decoded JSON value itself: `None`, `True`, quoted strings,
   lists and dicts, with Python's float spelling. The projection corpus pins
   these messages.

4. **Engine failures keep the Engine's exception type.** The reference
   re-raises the Engine's `RuntimeError` after it settles the Thread and the
   Attachment. The Haskell runner re-raises `Engine.EngineRuntimeError` with
   the same message. The corpus maps it to the class `RuntimeError`.

5. **Python exception kinds in scripted Activities.** The reference's
   scripted failing model raises `RuntimeError("provider-failed")`, and the
   History records `"kind": "RuntimeError"`. A Haskell Activity that throws
   an arbitrary exception is recorded under its Haskell type name. The
   differential replay therefore throws an `ActivityError` whose failure has
   kind `RuntimeError`, which is how a Haskell Activity spells a Python
   exception kind. The unit test keeps a plain `userError`, because it only
   checks the "failed terminally" refusal and the settlement.

## Helper and sidecar processes (`Petrus.Agenticus.Runtime.Pi.spawnPiped`)

1. **Children start through `posix_spawn`, not the `process` package.** The
   reference starts every helper and sidecar with
   `subprocess.Popen(..., stdin=PIPE, stdout=PIPE, stderr=PIPE,
   start_new_session=True)`. Its default `close_fds=True` closes only the
   descriptors that are open. With `close_fds`, the `process` package falls
   back to fork and closes every descriptor up to `RLIMIT_NOFILE`. That costs
   about 0.1 s per spawn at macOS's 1 048 576, and made each Pi Turn about
   three times slower than the reference's. `spawnPiped` serves the native,
   application and model-phase Pi helpers and the Codex, Claude and Amp
   sidecars. It uses petrus-execution's `posix_spawn` instead (see that
   package's DIVERGENCES.md): only stdio survives, the child leads a new
   session, and SIGPIPE and SIGXFSZ are restored as under
   `restore_signals=True`. The child is then adopted as an ordinary
   `ProcessHandle`. The `PiSpec` group "spawnPiped (not in the reference)"
   pins the descriptors, the session and the launch failure.
