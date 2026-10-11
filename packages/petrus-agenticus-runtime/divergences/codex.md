## Codex host (`Petrus.Agenticus.Runtime.Codex`, `Petrus.Agenticus.Runtime.CodexGondolin`)

These choices are deliberate. None of them changes a wire or storage byte:

- the `codex exec` argv, the helper protocol and the helper itself
  (`data/codex_helper.py` is the reference's `_HELPER_SOURCE`);
- the continuation payload;
- the runtime service's request and terminal frames;
- its SQLite ledger (`_DDL`, `user_version`, WAL, file modes).

`differential/hosts_corpus.json` and the interop examples in `CodexSpec`
pin those on both sides. The corpus's single tolerated difference is item 5.

1. **Protocols are records of operations.** The reference's structural
   protocols are records here, whose fields are the protocol's methods:
   - continuation storage is `CodexContinuationOperations {store, load}`;
   - Turn storage is `CodexTurnOperations {storeTurn}`;
   - connection custody is the `PiConnectionCustody` record the Pi host
     already uses (`piConnectionCustody` adapts the real
     `AgentConnectionCustody`).

   `CodexContinuationCodec` is the reference's codec over those operations.

2. **Monkeypatched seams are explicit hooks.** The reference's tests patch
   module and instance attributes. The port exposes each seam as a value:

   | Reference seam | Port |
   | --- | --- |
   | `shutil.which`, `subprocess.run` in the probe | `CodexProbeHooks {which, run}` |
   | assigning `adapter.start` | `setCodexStartWrapper` |
   | `_helper_executable` | `setCodexHelperExecutable` |
   | `os.environ` read by the Activity client | `codexGondolinActivityClientWith` takes the lookup |

   `officialCodexProbeHooks` and `codexGondolinActivityClient` are the
   reference's own behaviour.

3. **The helper interpreter is explicit.** The reference runs
   `_HELPER_SOURCE` with `sys.executable`. A Haskell process has no
   interpreter of its own, so `CodexAdapterOptions` carries one.
   `codexAdapterOptions` resolves `python3` on `PATH`, falling back to
   `/usr/bin/python3`. The Gondolin lane runs the guest helper under
   `/usr/bin/python3`, as upstream does.

4. **No `__all__`.** The reference keeps the Gondolin Activity adapter out
   of `codex.__all__`. The port puts it in a separate module
   (`CodexGondolin`), and `Codex`'s export list does not name it.

5. **Lone surrogate escapes are refused at decoding.** `petrus-json`
   values hold `Text`, which cannot contain a lone surrogate. CPython admits
   `"\ud800"` into a `str`. Two cases follow:
   - An agent message holding one makes the reference's `_final_text` raise
     an uncaught `UnicodeEncodeError` later. The port refuses the line as
     `malformed-jsonl`.
   - A runtime-service request frame holding one is refused as
     `request-invalid` before admission. The reference decodes it and
     carries the string further. The corpus does not pin this path.

   In the first case the Turn fails in both languages and nothing is
   published. The corpus accepts any refusal where the reference raises
   `UnicodeEncodeError`, and nothing else.

6. **Values Python can forge but JSON cannot carry.** The reference's
   fence test passes an `EqualityString`, a `str` subclass whose `__eq__`
   always answers true, and checks that the adapter still refuses it. A JSON
   string has no such subclass, so the port's test passes the foreign
   attachment id it stands for, and the refusal is the same
   `input-invalid`. Similarly, a `bytes` prompt is not representable, so
   the port's test uses `null`, and a tuple continuation becomes a JSON
   array. Both are refused as `input-invalid`, as upstream.

7. **Unexpected exceptions settle, never escape.** Inside `_execute`, the
   reference maps any `Exception` to `runtime-failed`, and so does the
   port. Around it, the reference's operation thread handles only
   `MotusBindingError` (`runtime-not-ready`, cleanup `not-created`).
   Anything else would end the thread without a result, and `wait` would
   only time out. The port catches every synchronous exception at that
   boundary too and settles `runtime-failed`. Asynchronous exceptions
   (cancellation, timeouts) are never swallowed.

8. **Sockets, locks and ledgers use POSIX calls directly.** The runtime
   service listens on an `AF_UNIX` stream socket (the `network` package)
   with mode 0600. It holds `.service.lock` with `flock(LOCK_EX |
   LOCK_NB)` through the FFI, opened `O_NOFOLLOW` with mode 0600, in a
   mode-0700 state directory. Its ledger is SQLite through the core
   package's binding. Paths, modes, lock semantics, frame bounds, the
   accept timeout and the close quiescence bound are the reference's.

9. **Python's `TypeError` texts are CPython 3.14's.** An unhashable item
   `type` in a `codex exec` stream raises `TypeError: cannot use 'list' as
   a set element (unhashable type: 'list')` in both languages. The pinned
   reference interpreter is CPython 3.14.6.
