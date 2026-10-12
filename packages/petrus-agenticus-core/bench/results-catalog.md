# agenticus-catalog benchmark results

<!-- scripts/bench: measured sources 479d741849778ff1 at 9126e1be67f7 -->

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

- Apple M4, macOS (Darwin 25.3), 2026-10-10.
- GHC 9.10.3, `-O2`, run with `+RTS -A32m -M2G`.
- CPython 3.14.6.

Method: five interleaved rounds. Each round ran the Haskell bench, then
this script, so both saw the same machine state. A Haskell value is a
tasty-bench mean (`--stdev 3`); a Python value is the script's median of 7
batches. The table gives the median of the five rounds. The machine was
shared with other work (load average 3.7 to 5.8).

| Benchmark | Haskell | Python | Python / Haskell | Slowest round |
| --- | ---: | ---: | ---: | ---: |
| resolve-6-kinds | 2.50 µs | 15.2 µs | 6.1× | 5.9× |
| snapshot-to-json | 7.07 µs | 14.6 µs | 2.1× | 2.0× |
| snapshot-from-data | 64.2 µs | 114 µs | 1.8× | 1.6× |
| register+enable-1000 | 734 µs | 2 870 µs | 3.9× | 3.7× |

"Slowest round" is the lowest Python / Haskell ratio of a single round.
Haskell was faster in every round of every row.

`snapshot-to-json` was 0.69× (22.4 µs against 15.5 µs) before petrus-json's
encoder was rewritten. The encoder used to:

1. pre-scan for non-finite floats,
2. build a `Builder`,
3. turn that into a lazy `ByteString`,
4. then copy it into a strict one.

It now writes the bytes in one pass into a growing buffer, refusing as it
goes, and copies a plain string with one `memcpy`. The output is unchanged:
200 000 generated values and options give the same bytes and the same
refusals as the old encoder.

## Rerun

```sh
scripts/bench-run petrus-agenticus-core -p catalog
cd upstream/petrus && .venv/bin/python ../../packages/petrus-agenticus-core/bench/python_catalog.py
```
