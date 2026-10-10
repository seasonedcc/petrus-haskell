# agenticus-catalog benchmark results

These are twin workloads: `bench/Bench/Catalog.hs` (tasty-bench) and
`bench/python_catalog.py`, which runs the pinned reference
(`upstream/petrus` @ 3f85fc2).

The catalog holds 1 000 enabled descriptors spread over the seven kinds.
Each one offers `cap-0` to `cap-9`, and each runtime requires five other
kinds with all ten capabilities.

- `resolve-6-kinds` resolves a runtime plus its five requirements.
- `snapshot-to-json` runs `json.dumps(snapshot.to_data())` on the resulting
  snapshot.
- `snapshot-from-data` decodes that snapshot.
- `register+enable-1000` builds a fresh catalog: 1 000 registrations, each
  followed by an enable.

## Results

Environment:

- Apple M4, macOS (Darwin 25.3).
- GHC 9.10.3, `-O2`, run with `+RTS -A32m`.
- CPython 3.14.6.

Haskell times are tasty-bench means. Python times are medians of 7 batches.

| Benchmark | Haskell | Python | Python / Haskell |
| --- | ---: | ---: | ---: |
| resolve-6-kinds | 2.61 µs | 16.46 µs | 6.3× |
| snapshot-to-json | 22.4 µs | 15.47 µs | 0.69× |
| snapshot-from-data | 74.3 µs | 120.8 µs | 1.6× |
| register+enable-1000 | 850 µs | 3 040 µs | 3.6× |

`snapshot-to-json` is the one path where Haskell is slower. CPython's
`json.dumps` is implemented in C, while petrus-json's encoder:

1. pre-scans for non-finite floats,
2. builds a `Builder`,
3. turns that into a lazy `ByteString`,
4. then copies it into a strict one.

petrus-json is shared by every package, so this is recorded instead of
special-cased here. The effect layer needed a fast canonical writer, so
`Petrus.Agenticus.Effect.Model` streams its digest input straight into
SHA-256 (see `results-effect.md`).

## Rerun

```sh
cabal bench petrus-agenticus-core-bench --benchmark-options='-p catalog'
cd upstream/petrus && .venv/bin/python ../../packages/petrus-agenticus-core/bench/python_catalog.py
```
