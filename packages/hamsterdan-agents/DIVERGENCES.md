# hamsterdan-agents divergences

On-disk formats never diverge. Both implementations write the same bytes
to:

- `agent-routes.sqlite3`;
- the sealed connection keys under `pi-a2/keys/` (32 bytes, mode `0600`)
  and the sealed state they protect;
- `pi-a2/installation` (the installation binding);
- the Pi A2 runtime host's stores under `pi-a2/runtime-host/`, which hold
  the operations, their bodies and the settled workspace archives.

The prompt envelope is the reference's byte for byte, and the result
validation accepts and refuses the same documents with the same messages.
[PARITY.md](PARITY.md) lists the tests that hold both implementations to
this.

Below are the differences that remain, with their rationale.

## Observable

1. **Lone surrogate escapes in a Pi result: resolved, no longer a
   difference.** `parseResult` keeps them in their `str` (WTF-8,
   "Petrus.Json.Wtf8"), as `json.loads` does, and `_text` and
   `_safe_path` raise the `UnicodeEncodeError` the reference raises when
   it encodes such a string to measure it (a built-in failure the runner
   sanitizes as the reference's `except Exception` does). Every other
   check meets them where the reference does: a status outside its
   vocabulary, a correlation mismatch, an extra key named in the refusal.
   `ResultDifferentialSpec` runs such results through the reference's
   `_parse_result` and `_validate_result`.
2. **A History path that cannot be stat'ed during route repair: resolved,
   no longer a difference.** Like `pathlib`'s glob, route repair matches a
   `history.jsonl` that is a dangling symbolic link (it used to skip it),
   and `path.stat()`'s `OSError` propagates (`FileNotFoundError`, the
   `OSError` of a symbolic-link loop), as in the reference. `InteropSpec`
   compares dangling, looping and working links, a directory and an
   unreadable file with the reference's `_terminal_operations`.
3. **Settled workspace archives are read by petrus-motus's tar reader.**
   - The reference opens them with `tarfile`. The port uses
     `Petrus.Motus.Execution.Archive.Tar`, the reader Petrus's own Pi A2
     workspace code uses.
   - Every check after reading is the reference's, in the same order and
     with the same messages:
     - entry count;
     - safe, unique UTF-8 paths;
     - entry types and modes;
     - the expanded size bound;
     - consistent sizes;
     - exactly the directories the files need.
   - `test_pi_workspace.py` and the archive rows of `test_pi.py` pass
     unchanged.
   - Headers that only one reader tolerates are still refused as
     `settled workspace archive is malformed` by the other. Examples are a
     bad checksum, a truncated final block, and GNU or PAX extensions the
     Pi runtime never writes.
   - The Pi runtime writes plain ustar, which both readers read the same.
4. **Exceptions the composition cannot classify print one line.** When the
   startup composition or its cleanup fails, `serve` prints
   `Class: message` with exit status 1, as hamsterdan-host's DIVERGENCES
   item 2 records for every uncaught exception. The reference prints the
   whole traceback, which ends in that line.

## Enforced by types (not observable at run time)

- **The runner's wait policy is a `Double`.** `test_runner_rejects_nonfinite_or_unordered_wait_policy`
  has 13 cases. The 9 cases with numbers or `None` are ported. The 4 cases
  that pass a `bool` or a `str` do not compile, because
  `PiRunnerOptions.timeout` is `Maybe Double` and `pollInterval` is
  `Double`. PARITY.md counts them as compile-time.

## Adapted tests

- **Source-inspection tests read the Haskell source.**
  - `test_production_composition_does_not_inject_provider_or_client_factory`
    reads `compose_owned_pi_a2` with `inspect.getsource`. The port reads
    `Hamsterdan/Host/PiA2.hs` and checks the same things:
    - the production hook is `composePiA2Runtime config authority …`;
    - no client factory or helper factory is passed.
  - `test_host_composition_imports_only_public_defining_modules` checks
    that `Hamsterdan/Host/Agenticus.hs` imports the defining Petrus modules
    (catalog descriptor, resolution, the Pi runtime, profiles), and does
    not import the `Petrus.Agenticus` or `Petrus.Motus` umbrella modules.
- **`/bin/true` is `/usr/bin/true` on macOS.** `test_pi_a2_factory.py`
  uses `/bin/true` as an installed command. macOS has no `/bin/true`, so
  the port uses `/usr/bin/true` when `/bin/true` is missing. That includes
  the crash script it runs under the reference.

## Internal (no observable difference)

- **Random bytes come from `getentropy(2)`.** Key material, AES-GCM nonces
  and temporary-file suffixes use `Hamsterdan.Host.Random.urandom`, which
  draws from the system CSPRNG with one `getentropy` call per 256 bytes, as
  `os.urandom` does. crypton's `getRandomBytes` in `IO` opens
  `/dev/random` and `/dev/urandom` on every call, which made the
  sealed-key path slower than Python's.
- **Key paths are encoded once.** The persistent key store encodes its root
  with the file-system encoding once, then stats and opens each key by its
  raw path (the file name is the SHA-256 hex of the connection, which is
  ASCII). The checks are unchanged: no symbolic link, a regular file, mode
  `0600`, the owner, and 32 bytes.
- **`InstanceBinding` lives in this package.** `host/binding.py` was first
  ported in hamsterdan-host. The Pi A2 installation binding uses it, so
  `Hamsterdan.Host.Binding` moved here, and hamsterdan-host imports it.
  `BindingSpec` still runs in hamsterdan-host.
- **The scripted composition is a library module.** The state interop and
  the benchmarks compose the real agent over Petrus's scripted Pi runtime
  on both sides. `Hamsterdan.Host.Scripted` holds the Haskell side of
  `differential/state_reference.py`'s `compose_real_agent`, so the tests
  and the benchmarks share it.
