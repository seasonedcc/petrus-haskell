# petrus-agenticus-runtime divergences

These choices are deliberate. None of them changes a `thread.json` byte, a
History byte or a refusal; `differential/runner_corpus.json` pins all three.

The Pi hosts (native, recovery, model phase, application and A2 host) are
covered in [divergences/pi.md](divergences/pi.md).

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
