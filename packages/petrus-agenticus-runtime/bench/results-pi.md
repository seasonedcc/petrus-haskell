# Pi native runtime benchmark results

These are twin workloads: `bench/PiBench.hs` (part of the tasty-bench
runner `bench/Main.hs`) and `bench/python_pi.py`, which runs the pinned
reference (`upstream/petrus` @ 3f85fc2).

- `pi-start-frame-encode` encodes the resumed, all-tools api-key `start`
  frame to its wire bytes (`_SubprocessClient._write`). The frame is the
  second `frames.starts` case of `differential/pi_corpus.json`: 1,594 bytes
  with five tool schemas and a base64 session.
- `pi-tool-call-decode` decodes one `tool_call` frame line through the frame
  reader's strict loader (`_strict_load`; in the port, `strictFrameLoad`).
- `pi-session-validate` runs `_validate_session` over a version-3 header and
  199 message entries (about 25 KB).
- `pi-fingerprint` runs `pi_durable_work_fingerprint`.
- `pi-ledger-cycle` takes one durable operation through a
  `SqlitePiOperationLedger`: `admit`, `settle`, `upgrade_cleanup`,
  `acknowledge`, then `lookup`. One ledger serves the whole benchmark, and
  each iteration uses a fresh operation id.

## Results

Environment:

- Apple M4, macOS (Darwin 25.3), APFS.
- GHC 9.10.3. The benchmark is built with `-O2` and run with
  `+RTS -A32m -M2G`.
- CPython 3.14.6.

Haskell times are tasty-bench means. Python times are medians of 7 batches.

| Benchmark | Haskell | Python | Python / Haskell |
| --- | ---: | ---: | ---: |
| pi-start-frame-encode | 15.7 µs | 7.7 µs | 0.5× |
| pi-tool-call-decode | 406 ns | 1.81 µs | 4.5× |
| pi-session-validate | 445 µs | 460 µs | 1.0× |
| pi-fingerprint | 7.33 µs | 6.35 µs | 0.9× |
| pi-ledger-cycle | 755 µs | 862 µs | 1.1× |

Notes on the results:

- **Frame encoding** is `petrus-json`'s `dumps`, which is known to trail
  CPython's C encoder. A `start` frame is written once per Turn, so it is
  not a hot path in practice.
- **Session validation** runs the CPython-faithful scanner from
  `Petrus.Impetus.Internal.PyJson`, which keeps lone surrogate escapes the
  way the reference does. That scanner works over `String`, so it is no
  faster than CPython's C scanner.
- **The ledger cycle** is four SQLite write transactions plus one read, each
  committed with the journal in `delete` mode. File-system work dominates it
  in both languages.

## Rerun

```sh
cabal bench petrus-agenticus-runtime-bench --benchmark-options='+RTS -M2G -RTS'
cd upstream/petrus && .venv/bin/python ../../packages/petrus-agenticus-runtime/bench/python_pi.py
```
