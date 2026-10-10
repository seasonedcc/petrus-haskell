# DSL benchmarks: Haskell vs the Python reference

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

From the repository root:

    cabal bench petrus-dsl

Python, from the pinned reference checkout with its virtual environment:

    cd upstream/petrus
    uv sync    # once
    .venv/bin/python ../../packages/petrus-dsl/bench/python_bench.py

Haskell numbers are tasty-bench means (± 2σ). Python numbers are the median of
5–20 runs after one warm-up. Both were run on 2026-10-10 on an Apple M4 with
24 GB of memory, using GHC 9.10.3 (`-O2`) and CPython 3.14.6. The reference
was pinned at `upstream/petrus` 3f85fc2.

## Results

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
  10 000 chain links costs 13× on the Python side and 15× here.
