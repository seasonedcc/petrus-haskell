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

1. **Lone surrogate escapes in a Pi result are refused at parse time.**
   - `json.loads` accepts `"\ud800"` into a `str`. `Data.Text` holds
     Unicode scalar values only, so `parseResult` refuses the document as
     `result is malformed JSON` (a protocol failure), as petrus-json does
     everywhere (`../petrus-json/DIVERGENCES.md`).
   - The reference parses such a document, then `_validate_result` raises
     `UnicodeEncodeError` when it encodes the string as UTF-8 to measure
     it. That error is not an `AgentError`, so the runner does not classify
     it as a protocol failure.
   - Either way the result is refused and nothing is published. Only the
     failure's class differs.
2. **A History file that cannot be stat'ed is "malformed" during route
   repair.** The reference calls `path.stat()` outside its `try`, so a
   dangling `history.jsonl` symbolic link raises `FileNotFoundError`. The
   port reports `agent route repair History is malformed`, as it does when
   the file cannot be read. The host refuses to start in both cases.
3. **Undecodable Git output is a `ValueError`.** The workspace provider runs
   Git with `text=True`, so non-UTF-8 output raises CPython's
   `UnicodeDecodeError`, which is not a `PiWorkspaceError`. The port raises
   `ValueError("'utf-8' codec can't decode git output")`.
   `UnicodeDecodeError` is a `ValueError` subclass, and that is the class
   name the host records (`error_class=ValueError`, where the reference
   records `UnicodeDecodeError`). Git writes UTF-8 for every path and ref
   the provider asks for, so this needs a corrupt repository.
4. **Settled workspace archives are read by petrus-motus's tar reader.**
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
5. **Exceptions the composition cannot classify print one line.** When the
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
