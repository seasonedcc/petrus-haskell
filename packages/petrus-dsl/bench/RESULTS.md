# DSL benchmarks: Haskell vs the Python reference

<!-- scripts/bench: measured sources f9de9ae8ef64743d at f82d9988cb9a -->
<!-- scripts/bench: carried to f4daf96de8c8094a at c33829edc562: only petrus-json/posix library changes upstream of it (json.loads refusal path, new helpers, docs, uuid hex digit); the admit paths it measures are unchanged -->

`bench/Main.hs` (tasty-bench) and `bench/python_bench.py` time the same two
workloads. Both are the `chain` and `stamped` builders of
`differential/dsl_corpus.py`. The differential corpus checks the Haskell twins
of these builders byte for byte, as `chain-50` and `stamped-30`.

- **chain-N**: a flat chain of N places and N transitions, with 2N arcs.
- **stamped-K**: a 10-node child stamped at K scopes, nested three deep
  (`a{i%10}.b{i/10%10}.c{i/100}`), with 10K arcs.

Each workload is timed in two ways:

- **build**: author the specification and build the canonical Net. The
  kernel's Net constructor validates every node and arc before it returns, so
  the result is a fully checked Net.
- **build+v3**: the same, then project and serialize Net definition v3.

Both sides print the arc count and the v3 byte count, and they agree on every
size:

| workload | arcs | v3 bytes |
| --- | ---: | ---: |
| chain-1000 | 2 000 | 659 416 |
| chain-10000 | 20 000 | 6 681 419 |
| stamped-10 | 100 | 36 997 |
| stamped-100 | 1 000 | 368 918 |
| stamped-1000 | 10 000 | 3 697 119 |

## How to rerun

From the repository root (`scripts/bench petrus-dsl` runs exactly this;
`scripts/upstream-python` provisions the pinned reference):

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run petrus-dsl +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-dsl/bench/python_bench.py)
```

Haskell times are wall-clock time (`localOption WallTime` in `bench/Main.hs`),
like the Python side's `time.perf_counter`. The table above was taken before
that switch, in tasty-bench's default CPU time; this workload is
single-threaded and does no I/O inside the timed region, so the two agree
(see [CPU and wall-clock time](../../../docs/reproducing.md#cpu-and-wall-clock-time)).

Haskell numbers are tasty-bench means (± 2σ). Python numbers are the median of
5–20 runs after one warm-up. Both were run on 2026-10-10 on an Apple M4 with
24 GB of memory, using GHC 9.10.3 (`-O2`) and CPython 3.14.6. The reference
was pinned at `upstream/petrus` 3f85fc2.

## Current figures

Measured on 2026-10-12, 22:53–22:56 local (UTC-3), at commit `f82d998`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.58–3.43:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-dsl 3 \
        --map 'chain.chain-1000.build=build/chain-1000' \
        --map 'chain.chain-1000.build+v3=build+v3/chain-1000' \
        --map 'chain.chain-10000.build=build/chain-10000' \
        --map 'chain.chain-10000.build+v3=build+v3/chain-10000' \
        --map 'stamped.stamped-10.build=build/stamped-10' \
        --map 'stamped.stamped-10.build+v3=build+v3/stamped-10' \
        --map 'stamped.stamped-100.build=build/stamped-100' \
        --map 'stamped.stamped-100.build+v3=build+v3/stamped-100' \
        --map 'stamped.stamped-1000.build=build/stamped-1000' \
        --map 'stamped.stamped-1000.build+v3=build+v3/stamped-1000'

(the maps pair the Haskell rows with the twin's, whose names differ).

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `chain.chain-1000.build` | 9.31 ms | 29.3 ms | 3.15× | 3.15× | 3 of 3 | 9.39 ms, 9.31 ms, 9.22 ms | 30.2 ms, 29.3 ms, 29.3 ms |
| `chain.chain-1000.build+v3` | 16.9 ms | 112 ms | 6.65× | 6.61× | 3 of 3 | 17 ms, 16.8 ms, 16.9 ms | 112 ms, 112 ms, 112 ms |
| `chain.chain-10000.build` | 147 ms | 342 ms | 2.33× | 2.32× | 3 of 3 | 147 ms, 148 ms, 146 ms | 342 ms, 344 ms, 338 ms |
| `chain.chain-10000.build+v3` | 279 ms | 1.25 s | 4.49× | 4.45× | 3 of 3 | 280 ms, 278 ms, 279 ms | 1.25 s, 1.25 s, 1.25 s |
| `stamped.stamped-10.build` | 221 µs | 1.44 ms | 6.52× | 6.46× | 3 of 3 | 223 µs, 220 µs, 221 µs | 1.44 ms, 1.46 ms, 1.44 ms |
| `stamped.stamped-10.build+v3` | 562 µs | 6.38 ms | 11.35× | 11.19× | 3 of 3 | 562 µs, 556 µs, 565 µs | 6.38 ms, 6.42 ms, 6.32 ms |
| `stamped.stamped-100.build` | 3.99 ms | 15.4 ms | 3.86× | 3.84× | 3 of 3 | 4.01 ms, 3.98 ms, 3.99 ms | 15.5 ms, 15.3 ms, 15.4 ms |
| `stamped.stamped-100.build+v3` | 8.49 ms | 64.5 ms | 7.59× | 7.54× | 3 of 3 | 8.53 ms, 8.49 ms, 8.41 ms | 64.3 ms, 64.5 ms, 64.6 ms |
| `stamped.stamped-1000.build` | 70.8 ms | 257 ms | 3.63× | 3.59× | 3 of 3 | 71.5 ms, 69.9 ms, 70.8 ms | 257 ms, 261 ms, 257 ms |
| `stamped.stamped-1000.build+v3` | 137 ms | 791 ms | 5.76× | 5.62× | 3 of 3 | 143 ms, 137 ms, 137 ms | 801 ms, 791 ms, 782 ms |

## Earlier figures

<!-- bench: superseded -->

| workload | step | Python | Haskell | speed-up |
| --- | --- | ---: | ---: | ---: |
| chain-1000 | build | 39.0 ms | 12.3 ms | 3.2× |
| chain-1000 | build+v3 | 141.7 ms | 29.9 ms | 4.7× |
| chain-10000 | build | 507 ms | 181 ms | 2.8× |
| chain-10000 | build+v3 | 1 418 ms | 470 ms | 3.0× |
| stamped-10 | build | 1.52 ms | 0.345 ms | 4.4× |
| stamped-10 | build+v3 | 6.83 ms | 1.14 ms | 6.0× |
| stamped-100 | build | 17.0 ms | 5.26 ms | 3.2× |
| stamped-100 | build+v3 | 70.1 ms | 15.1 ms | 4.6× |
| stamped-1000 | build | 286 ms | 94.6 ms | 3.0× |
| stamped-1000 | build+v3 | 860 ms | 233 ms | 3.7× |

## Notes

- **Authoring is persistent.** Each authoring step updates immutable maps and
  can be rolled back (`attempt`). Building is one pass that composes the
  stamps, lowers the result, and hands it to the kernel's `mkNet`.
- **Growth is slightly superlinear on both sides.** Going from 1 000 to
  10 000 chain links costs 11× on the Python side and 16× here (13× and 15×
  in the earlier figures).
