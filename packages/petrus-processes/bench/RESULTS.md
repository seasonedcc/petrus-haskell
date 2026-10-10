# petrus-processes benchmarks

Python figures time the upstream code path named in `bench/python_bench.py`;
Haskell figures are tasty-bench means of `bench/Main.hs`, which uses the same
names, values and store operations. Ratios above 1 mean Haskell is faster.
The ratio column pairs the slowest Haskell run with the fastest Python run.

- Commit: `956d24a`
- Machine: Darwin arm64, Apple M4
- Haskell: GHC 9.10.3 (-O2), tasty-bench mean, `--stdev 5`, `+RTS -M2G -RTS`
- Python: CPython 3.14.6 (upstream venv), median of timed batches (scripts/bench_timing.py)
- PostgreSQL 17.7 on localhost (a private server; the store rows use a scratch database each run)
- Runs: 2 rounds, interleaved (Haskell 1, Python 1, Haskell 2, Python 2). The machine was shared
  with other work; 1-minute load averages around each run:
  haskell 1 before: 4.22; haskell 1 after: 4.44; python 1 before: 4.44; python 1 after: 4.38; haskell 2 before: 4.38; haskell 2 after: 5.19; python 2 before: 5.19; python 2 after: 4.56.

| Benchmark | Haskell (run 1 / run 2) | Python (run 1 / run 2) | Python / Haskell (slowest Haskell vs fastest Python) |
|---|---:|---:|---:|
| `model.child-identity` | 652 ns / 647 ns | 1.81 µs / 1.76 µs | 2.70× |
| `model.spawn-spec-digest` | 2.81 µs / 2.72 µs | 15.6 µs / 15.5 µs | 5.50× |
| `model.spawn-spec-roundtrip` | 1.3 µs / 1.34 µs | 14.4 µs / 14.6 µs | 10.79× |
| `call.request-envelope` | 1.46 µs / 1.46 µs | 14.8 µs / 15 µs | 10.14× |
| `call.result-envelope` | 1.49 µs / 1.6 µs | 15.6 µs / 15.8 µs | 9.80× |
| `call.reply-from-envelope` | 804 ns / 868 ns | 12.1 µs / 12.2 µs | 13.94× |
| `spawn.activity` | 5.76 µs / 5.86 µs | 46.4 µs / 47.3 µs | 7.91× |
| `postgres.claim-prior` | 34.5 µs / 31.1 µs | 117 µs / 102 µs | 2.97× |
| `postgres.child-of` | 17.5 µs / 19.7 µs | 62.8 µs / 61.8 µs | 3.14× |
| `postgres.claim-new` | 34.1 µs / 29.8 µs | 159 µs / 3.73 ms | 4.67× |
| `postgres.spawn-activity` | 40.2 µs / 35.3 µs | 221 µs / 239 µs | 5.51× |

## Notes

- The `postgres` rows run at 20% relative precision (`RelStDev 0.2`, as
  the other PostgreSQL benchmarks in this repository do). At 5% the
  inserting rows did not converge within 300 s on a loaded machine. Each
  row is a round trip to the server, and `claim-new` and `spawn-activity`
  grow the table they read.
- Python's second `postgres.claim-new` batch hit a load spike (3.73 ms).
  The ratio column uses Python's fastest run, so the spike does not count
  in Haskell's favour.

## Rerun

```sh
export PETRUS_TEST_POSTGRES=postgresql://USER@HOST:PORT/postgres
scripts/bench petrus-processes
# or by hand, interleaving:
cabal build -j2 petrus-processes:bench:petrus-processes-bench
"$(cabal list-bin petrus-processes:bench:petrus-processes-bench)" --stdev 5 --timeout 300 +RTS -M2G -RTS
(cd upstream/petrus && .venv/bin/python -B ../../packages/petrus-processes/bench/python_bench.py)
```
