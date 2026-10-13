# agenticus-catalog benchmark results

<!-- scripts/bench: measured sources 58b8b899b48a81e2 at 13f7a84d2779 -->
<!-- scripts/bench: carried to 79b9a7598b6cb16d at c33829edc562: the petrus-json/posix/sqlite changes (loads refusal path, posix additions, SQLite bind length guard) are off the catalog, effect, hands and thread paths, which bind no SQLite -->

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

## Current figures

Measured on 2026-10-12, 22:18–22:26 local (UTC-3), at commit `424aa4e`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 1.80–2.65:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-agenticus-core 3 --python python_catalog.py --python python_effect.py --python python_hands.py --python python_thread.py

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The same three repetitions measured the other results files' rows (see [RESULTS.md](RESULTS.md)). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `catalog.resolve-6-kinds` | 2.43 µs | 14.7 µs | 6.08× | 6.03× | 3 of 3 | 2.4 µs, 2.43 µs, 2.43 µs | 14.8 µs, 14.7 µs, 14.6 µs |
| `catalog.snapshot-to-json` | 5.45 µs | 14.3 µs | 2.63× | 2.59× | 3 of 3 | 5.41 µs, 5.53 µs, 5.45 µs | 14 µs, 14.8 µs, 14.3 µs |
| `catalog.snapshot-from-data` | 47.4 µs | 111 µs | 2.34× | 2.34× | 3 of 3 | 47.5 µs, 47.1 µs, 47.4 µs | 111 µs, 111 µs, 111 µs |
| `catalog.register+enable-1000` | 661 µs | 2.81 ms | 4.25× | 4.15× | 3 of 3 | 678 µs, 661 µs, 661 µs | 2.81 ms, 2.8 ms, 2.84 ms |

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

<!-- bench: superseded -->

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
