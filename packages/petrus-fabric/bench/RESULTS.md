# petrus-fabric benchmarks

Python figures time the upstream code path named in `bench/python_bench.py`;
Haskell figures are tasty-bench means of `bench/Main.hs`, which uses the same
names, values and store operations. Ratios above 1 mean Haskell is faster.
The ratio column pairs the slowest Haskell run with the fastest Python run.

- Commit: `37766e1`
- Machine: Darwin arm64, Apple M4
- Haskell: GHC 9.10.3 (-O2), tasty-bench mean, `--stdev 5`, `+RTS -M2G -RTS`
- Python: CPython 3.14.6 (upstream venv), median of timed batches (scripts/bench_timing.py)
- PostgreSQL 17.7 on localhost (a private server; the store rows use a scratch database each run)
- Runs: 2 rounds, interleaved (Haskell 1, Python 1, Haskell 2, Python 2). The machine was shared
  with other work; 1-minute load averages around each run:
  haskell 1 before: 3.21; haskell 1 after: 2.80; python 1 before: 2.80; python 1 after: 2.73; haskell 2 before: 2.73; haskell 2 after: 2.78; python 2 before: 2.78; python 2 after: 3.05.

| Benchmark | Haskell (run 1 / run 2) | Python (run 1 / run 2) | Python / Haskell (slowest Haskell vs fastest Python) |
|---|---:|---:|---:|
| `envelope.build` | 1.2 µs / 1.29 µs | 12 µs / 12.4 µs | 9.33× |
| `envelope.digest` | 2.97 µs / 3.27 µs | 20 µs / 20.5 µs | 6.13× |
| `envelope.roundtrip` | 1.87 µs / 2.42 µs | 18.4 µs / 19.2 µs | 7.59× |
| `canonical.16KiB` | 58.1 µs / 65 µs | 135 µs / 142 µs | 2.08× |
| `postgres.submit` | 58.4 µs / 59.7 µs | 246 µs / 390 µs | 4.12× |
| `postgres.submit-duplicate` | 28.5 µs / 28.8 µs | 115 µs / 191 µs | 3.98× |
| `postgres.send-drain` | 119 µs / 133 µs | 499 µs / 769 µs | 3.74× |
| `postgres.discover` | 20.7 µs / 20.8 µs | 77.1 µs / 112 µs | 3.71× |

## Notes

- `canonical.16KiB` first measured 326 µs, 2.4× slower than Python, with
  petrus-json's general encoder (Builder-based, with `floatToDigits`
  float spelling). `Petrus.Fabric.Canonical` replaced it with two passes:
  one measures an upper bound of the output and checks the refusals, and
  one writes straight into a buffer of that size. Its floats use a port of
  the reference Ryu algorithm (≈60 ns a float against ≈450 ns), and small
  objects are sorted with an insertion sort. The same encoder serves every
  digest and size check, so `envelope.*` gained 25–40% as well.
- That Ryu port now lives in petrus-json (`Petrus.Json.Float`) and spells
  every petrus-json float. A same-process A/B against the previous private
  copy measured the 16 KiB payload at 68.0 µs against 66.1 µs, and 10 000
  random doubles at 708 µs against 820 µs. A later run of this bench gave
  `canonical.16KiB` 59.5 µs and `envelope.*` 1.29, 3.08 and 2.03 µs, in line
  with the table.
- The store rows include the round trips to the server. Both sides use one
  autocommit connection to the same server and the same SQL.

## Rerun

```sh
export PETRUS_TEST_POSTGRES=postgresql://USER@HOST:PORT/postgres
scripts/bench petrus-fabric
# or by hand, interleaving:
cabal build -j2 petrus-fabric:bench:petrus-fabric-bench
"$(cabal list-bin petrus-fabric:bench:petrus-fabric-bench)" --stdev 5 --timeout 300 +RTS -M2G -RTS
(cd upstream/petrus && .venv/bin/python -B ../../packages/petrus-fabric/bench/python_bench.py)
```
