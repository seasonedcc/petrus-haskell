# petrus-agenticus-runtime benchmark results

The Pi benchmarks (frame codec, session validation, fingerprints, the
operation ledger and a scripted A2 turn) are in [results-pi.md](results-pi.md).
This file covers the Local Agent-as-a-Net runner.

These are twin workloads: `bench/Main.hs` (tasty-bench) and
`bench/python_runner.py`, which runs the pinned reference
(`upstream/petrus` @ 3f85fc2).

- `runner-3-phases-3-reads` builds an Episode Attachment with its grant,
  creates a runner in a fresh temporary directory and drains it to the
  terminal.
  - Model phase 1 proposes two `workspace_read` calls, phase 2 proposes one,
    and phase 3 stops.
  - Every projection is saved through the atomic JSON repository, with two
    fsyncs per save, and every History record is appended to
    `history.jsonl`.
- `projection-roundtrip` runs `AgentNetThreadProjection.from_data(json.loads(text))`
  and dumps the result back to compact sorted JSON. The input is that run's
  final `thread.json`.

## Results

Environment:

- Apple M4, macOS (Darwin 25.3), APFS.
- GHC 9.10.3, `-O2`, run with `+RTS -A32m -M2G`.
- CPython 3.14.6.

Haskell times are tasty-bench means. Python times are medians of 7 batches.

| Benchmark | Haskell | Python | Python / Haskell |
| --- | ---: | ---: | ---: |
| runner-3-phases-3-reads | 5.86 ms | 11.39 ms | 1.9× |
| projection-roundtrip | 81.8 µs | 116.1 µs | 1.4× |

The full run is dominated by file-system work (temporary-file creation,
fsync, rename and History appends), which costs the same in both languages.
The round trip is dominated by JSON text encoding. `petrus-json`'s
`dumpsText` is known to trail CPython's C encoder on large documents.

## Rerun

```sh
cabal bench petrus-agenticus-runtime-bench --benchmark-options='+RTS -M2G -RTS'
cd upstream/petrus && .venv/bin/python ../../packages/petrus-agenticus-runtime/bench/python_runner.py
```
