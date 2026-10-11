# petrus-execution divergences

Intentional differences from upstream `petrus.motus.execution` / `_execution`. None of them
changes a wire or storage format: workspace archives, artifact metadata, Timeline JSONL,
Gondolin registries and sidecar control frames are byte-identical, and the sidecar is upstream's
file, embedded verbatim.

## API shape (the Haskell way)

| Area | Upstream | Haskell | Why |
| --- | --- | --- | --- |
| Errors | Built-in exception classes (`ValueError`, `RuntimeError`, `KeyError`, `TarError`, ...). | One `ExecutionError` with an `ErrorKind` mirroring the class and the **exact upstream message**. | Callers branch on the kind instead of string matching; messages stay the observable contract. |
| Value invariants | Dataclass `__post_init__` validation. | Smart constructors returning `Either ExecutionError`; record constructors are not exported. Invalid `ReconcileResult` combinations are unrepresentable. | Every value in hand already satisfies the upstream invariants. |
| Providers | Classes with `isinstance` protocol checks (`PrivateFileTransfer`). | An `EnvironmentProvider` record; private-file transfer is `providerPrivateFiles :: Maybe PrivateFileTransfer`. | Capability presence is a value, not a runtime type test. |
| Test seams | Tests monkeypatch module globals (`_group_members`, `_identity`, `os.killpg`, registry writes, socket requests). | Gondolin takes a `ProcessInspector` record and a `GondolinHooks` record (`hookRequest`, `hookWriteRegistry`, `hookRuntimeCreated`, `hookLockOpened`). | Same failure injection, explicit in the configuration. |
| E2B client | Imports the official `e2b` Python SDK. | `Providers.E2b.Http` is a native client of the same E2B REST and envd wire protocol (read from `e2b` 2.55.1: `/v2/sandboxes`, `/files`, Connect with the JSON codec), loaded by default through the same `E2bSdk` seam upstream's `sdk_loader` fills. Residual differences in the client itself: it always speaks HTTP/1.1 (the SDK's `E2B_HTTP_VERSION=1.1` mode; its default is HTTP/2); it does not reproduce the SDK's local-development mode (`E2B_DEBUG`); a dropped command stream is reported as the SDK's `unavailable` `SandboxException` without the SDK's follow-up health probe that can refine it to `SandboxNotRunningException`; retry back-off has no jitter; requests carry a `petrus-haskell-e2b` User-Agent. SDK exception classes surface as `OtherError "<class>"` with the SDK's message. | No Haskell SDK exists; the client covers exactly the calls upstream makes. |
| Telemetry handler | `logging.Handler` subclass receiving `LogRecord`s. | `emitTelemetry :: TelemetryTimelineHandler -> Text -> IO ()` taking the formatted message. | There is no `logging` module; the mirrored record is byte-identical (fixtures). |
| Gondolin registry | A `dict` read lazily; malformed fields fail where first used. | Decoded eagerly into a `Registry` record; malformed fields fail at read time with the corresponding `KeyError`/`TypeError` kind. Its `Show` instance redacts the boot token. | Typed access, and secrets never reach logs via `show`. |
| Gondolin sidecar file | Shipped as package data and passed by path. | Embedded at compile time (Template Haskell, SHA-256 pinned by a test) and written `0600` into the private runtime directory, unless `gondolinSidecar` names a file. | No install-location lookup; the executed bytes are exactly upstream's. |
| Gondolin Node | `node` from `PATH`. | `gondolinNode` in the configuration (default `"node"`). | The real SDK needs Node >= 23.6, which may not be first on `PATH`. |

## Behavior

| Area | Upstream | Haskell | Why |
| --- | --- | --- | --- |
| Compressed archives | `tarfile.open("r:*")` also decodes bz2, xz and zstd. | gzip is decoded; bz2/xz/zstd inputs fail with `TarError` "bzip2, xz, and zstd workspace archives are not supported" (the `bz2-magic` fixture checks the kind, not upstream's message). gzip decompression errors are reported as truncation, and decompressed size is capped at 3 GiB. | Producers only ever emit uncompressed archives; this avoids three codec dependencies and bounds memory. |
| Transfer bound when packing | `workspace_archive` reads every file, then checks the archive size. | The 512 MiB bound is checked from file sizes before any content is read. | Same accept/reject outcome, without reading an oversized workspace into memory first. |
| Command output retention | Reads all output into memory, then slices `stdout[:limit]`, `stderr[:limit - len(stdout)]`. | Each stream retains at most the limit while counting every byte. | Identical results and truncation flag in bounded memory. |
| Spawning children | `subprocess.Popen(close_fds=True)`, which closes only open descriptors. | `posix_spawn` (`cbits/petrus_spawn.c`) with `POSIX_SPAWN_CLOEXEC_DEFAULT` on Darwin and `addclosefrom_np(3)` on glibc >= 2.34; SIGPIPE/SIGXFSZ restored to default and an empty signal mask, like `restore_signals=True`. A path containing `/` gets no `/bin/sh` fallback on ENOEXEC, like CPython's `execve`. | The `process` package's `close_fds` path closes every descriptor up to `RLIMIT_NOFILE` (about 115 ms per spawn at macOS's 1 048 576). Same semantics, 1 ms per spawn. |
| Executable lookup | `Popen` searches `PATH` of the supplied environment. | Done explicitly (`resolveExecutable`) before spawning, with the same `[Errno 2]` / `[Errno 13]` messages. | Keeps the error text exact. |
| Waiting for a child's exit | `Popen.wait(timeout)` polls `waitpid(WNOHANG)` with a back-off from 0.5 ms doubling to 50 ms. | With the threaded RTS, one watcher thread per child blocks in `waitid(P_PID, WEXITED \| WNOWAIT)` (a safe FFI call, `cbits/petrus_wait.c`), which observes the exit without reaping it; waiters block on that signal under their own timeout, then reap through the same `waitpid` path as before. Without the threaded RTS the back-off loop is kept. | Same results, timeouts, cancellation and process-group kill. A waiter wakes when the child exits instead of up to 50 ms later; the back-off cost a scripted Pi A2 turn up to one 50 ms step per command. |
| Sidecar socket wait | `socket.settimeout` (poll, then recv). | An `interruptible` `poll()` on the calling thread, then `recv`. | Same timeout semantics; avoids an IO-manager wakeup per round trip and stays cancellable by asynchronous exceptions. |
| Timeline timestamps | `observed_at` is any `datetime`; naive or non-UTC values serialize with their own offset. | `UTCTime`, always serialized with `+00:00` (microseconds omitted when zero, exactly as `isoformat`). | Upstream only ever produces UTC; the type rules out the other cases. |
| Secret redaction | `re` patterns with `IGNORECASE`. | Hand-written matchers, including Python's Unicode case folding (`ı`→`i`, `ſ`→`s`). | No regex dependency; equivalence is proven by the redaction fixtures. |
| Unix helpers | `os`, `os.path` and `fcntl` calls. | `flock`, `fsync`, atomic replace and the `*at` family come from the shared `petrus-posix` package. `Internal.PosixPath` keeps `os.path.realpath` with its `strict` modes and `normpath`/`dirname`/`join`/`commonpath` over raw bytes, which `petrus-posix` does not offer; `cbits/` keeps only the `posix_spawn` and wait helpers. | The tarfile `data` filter calls `realpath(strict=ALLOW_MISSING)` and reports the failing errno and path; the archive code compares undecoded bytes. |

### Resolved: no longer a difference

- **Provider answers that do not decode, or decode to the wrong type.** Docker's
  `subprocess.run(text=True)` decodes stdout and then stderr strictly (the `UnicodeDecodeError`'s
  text) before the exit status is checked, with universal newlines; `json.loads` failures carry
  CPython's `JSONDecodeError` text (petrus-json's `loadsText`); `[0]`, `["key"]`, iteration and
  `.get` on a value of the wrong JSON type raise the `TypeError`, `KeyError`, `IndexError` or
  `AttributeError` CPython raises. The Gondolin sidecar's frame and `registry.json`
  (`read_text()`: strict UTF-8, universal newlines) fail the same way, and a refused request
  raises `RuntimeError` with `str()` of whatever `error` holds (an object, a list, `null`, a
  number), as `RuntimeError(response.get("error"))` does. `test/ProviderAnswersSpec.hs` runs 60
  answers through the pinned reference and the port (PARITY.md, "Provider answers").
- **Pax number fields with C0 separators.** `int()` and `float()` of a pax `size`, `mtime`,
  `uid` or `gid` skip Unicode whitespace but not `\x1c`–`\x1f` (CPython skips C's `isspace` set
  after mapping non-ASCII whitespace to a space); the port skipped everything `str.isspace`
  accepts, so `mtime=\x1c12.5` read as 12.5 where `tarfile` reads 0. Both now use petrus-json's
  `parsePythonInt` and `isPythonNumberSpace`; `ArchiveSpec`'s "pax number fields" group checks
  19 values against the live `tarfile`.

## Not applicable

- `test_private_model_location_is_identity_compatible_without_owning_types` checks that a private
  Python module re-exports the same class object. Haskell has one definition per type.
