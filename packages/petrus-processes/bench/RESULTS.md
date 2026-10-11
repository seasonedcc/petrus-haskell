# petrus-processes benchmarks

Python figures time the upstream code path named in `bench/python_bench.py`;
Haskell figures are tasty-bench means of `bench/Main.hs`, which uses the same
names, values and store operations. Both are wall-clock time. Ratios above 1
mean Haskell is faster. **One store row is slower than Python:**
`postgres.child-of` (0.97×).

- Date: 2026-10-10 21:06–21:08 local (UTC-3), commit `74e6b1e` with the switch to wall-clock
  time in `bench/Main.hs` (the library code is unchanged)
- Machine: Darwin arm64, Apple M4, shared with other agents; 1-minute load average 2.7–4.0
  around the runs
- Haskell: GHC 9.10.3 (-O2), tasty-bench mean in wall-clock time, `--stdev 5`, `+RTS -M2G -RTS`
- Python: CPython 3.14.6 (upstream venv), psycopg 3.3.4, median of 10 timed batches of 0.2 s
  (scripts/bench_timing.py)
- PostgreSQL 17.7, a throwaway server from `scripts/with-postgres` (Postgres.app binaries,
  `initdb` defaults) on 127.0.0.1; the store rows use a scratch database each run
- Interleaved by `scripts/bench-compare petrus-processes 2`: Haskell, Python, then Python,
  Haskell. The figures are the medians of the two repetitions; the last two columns give each
  repetition.

| Benchmark | Haskell | Python | Python / Haskell | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---|---|
| `model.child-identity` | 625 ns | 1.78 µs | 2.85× | 629 ns, 622 ns | 1.78 µs, 1.78 µs |
| `model.spawn-spec-digest` | 2.61 µs | 15.5 µs | 5.93× | 2.57 µs, 2.65 µs | 15.6 µs, 15.4 µs |
| `model.spawn-spec-roundtrip` | 1.24 µs | 14.1 µs | 11.40× | 1.28 µs, 1.2 µs | 14.1 µs, 14.1 µs |
| `call.request-envelope` | 1.37 µs | 14.6 µs | 10.67× | 1.38 µs, 1.35 µs | 14.6 µs, 14.5 µs |
| `call.result-envelope` | 1.51 µs | 15.3 µs | 10.15× | 1.52 µs, 1.49 µs | 15.2 µs, 15.4 µs |
| `call.reply-from-envelope` | 796 ns | 11.9 µs | 14.91× | 804 ns, 789 ns | 11.8 µs, 12 µs |
| `spawn.activity` | 5.83 µs | 46.5 µs | 7.98× | 5.83 µs, 5.82 µs | 45.8 µs, 47.1 µs |
| `postgres.claim-prior` | 92.4 µs | 111 µs | 1.21× | 90.3 µs, 94.5 µs | 111 µs, 112 µs |
| `postgres.child-of` | 59.7 µs | 58 µs | 0.97× | 58.9 µs, 60.6 µs | 60.9 µs, 55 µs |
| `postgres.claim-new` | 100 µs | 135 µs | 1.35× | 101 µs, 99.7 µs | 134 µs, 136 µs |
| `postgres.spawn-activity` | 113 µs | 187 µs | 1.65× | 119 µs, 107 µs | 187 µs, 186 µs |

### Wall-clock time, and the earlier figures

The figures committed before these timed Haskell in tasty-bench's default CPU
time, against Python's wall-clock time. CPU time leaves out the wait for the
server, so the store rows read 3.0–5.5× faster than Python
(`postgres.child-of` 17.5–19.7 µs). Measured the same way as Python, they are
0.97–1.65×: `postgres.child-of` is one indexed `SELECT`, essentially a round
trip on both sides, and comes out level with Python (0.97× on the medians;
Haskell won the first repetition, Python the second). The in-memory rows
(`model.*`, `call.*`, `spawn.activity`) are unchanged.

## Notes

- The `postgres` rows run at 20% relative precision (`RelStDev 0.2`, as
  the other PostgreSQL benchmarks in this repository do). At 5% the
  inserting rows did not converge within 300 s on a loaded machine. Each
  row is a round trip to the server, and `claim-new` and `spawn-activity`
  grow the table they read.

## Rerun

From the repository root (`scripts/bench petrus-processes` runs exactly this block). The store
rows need a server where the role may create databases in `PETRUS_TEST_POSTGRES`; when that is
unset, `scripts/bench` and `scripts/bench-compare` start a throwaway one with
`scripts/with-postgres`.

<!-- scripts/bench: rerun -->
```sh
cabal bench -j2 petrus-processes --benchmark-options '--stdev 5 --timeout 300 +RTS -M2G -RTS'
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-processes/bench/python_bench.py)
```

`scripts/bench-compare petrus-processes 2` interleaves both sides and prints the table above.
