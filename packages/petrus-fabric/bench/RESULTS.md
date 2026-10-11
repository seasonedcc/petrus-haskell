# petrus-fabric benchmarks

Python figures time the upstream code path named in `bench/python_bench.py`;
Haskell figures are tasty-bench means of `bench/Main.hs`, which uses the same
names, values and store operations. Both are wall-clock time. Ratios above 1
mean Haskell is faster. **Two store rows are slower than Python:**
`postgres.discover` (0.86×) and `postgres.submit` (0.97×).

- Date: 2026-10-10 21:01–21:06 local (UTC-3), commit `74e6b1e` with the switch to wall-clock
  time in `bench/Main.hs` (the library code is unchanged)
- Machine: Darwin arm64, Apple M4, shared with other agents; 1-minute load average 3.0–4.0
  around the runs
- Haskell: GHC 9.10.3 (-O2), tasty-bench mean in wall-clock time, `--stdev 5`, `+RTS -M2G -RTS`
- Python: CPython 3.14.6 (upstream venv), psycopg 3.3.4, median of 10 timed batches of 0.2 s
  (scripts/bench_timing.py)
- PostgreSQL 17.7, a throwaway server from `scripts/with-postgres` (Postgres.app binaries,
  `initdb` defaults) on 127.0.0.1; the store rows use a scratch database each run
- Interleaved by `scripts/bench-compare petrus-fabric 2`: Haskell, Python, then Python,
  Haskell. The figures are the medians of the two repetitions; the last two columns give each
  repetition.

| Benchmark | Haskell | Python | Python / Haskell | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---|---|
| `envelope.build` | 1.27 µs | 12.5 µs | 9.89× | 1.2 µs, 1.34 µs | 12.4 µs, 12.6 µs |
| `envelope.digest` | 3.17 µs | 20.2 µs | 6.37× | 2.96 µs, 3.38 µs | 20.2 µs, 20.2 µs |
| `envelope.roundtrip` | 2.02 µs | 18.8 µs | 9.30× | 1.85 µs, 2.18 µs | 18.7 µs, 18.8 µs |
| `canonical.16KiB` | 62.9 µs | 138 µs | 2.19× | 58 µs, 67.7 µs | 139 µs, 137 µs |
| `postgres.submit` | 245 µs | 237 µs | 0.97× | 226 µs, 264 µs | 238 µs, 236 µs |
| `postgres.submit-duplicate` | 103 µs | 111 µs | 1.08× | 99.5 µs, 107 µs | 114 µs, 109 µs |
| `postgres.send-drain` | 458 µs | 499 µs | 1.09× | 442 µs, 473 µs | 528 µs, 470 µs |
| `postgres.discover` | 87.8 µs | 75.5 µs | 0.86× | 85.2 µs, 90.3 µs | 77.7 µs, 73.3 µs |

### Wall-clock time, and the earlier figures

The figures committed before these timed Haskell in tasty-bench's default CPU
time, against Python's wall-clock time. CPU time leaves out the wait for the
server, so the store rows read 3.7–4.1× faster than Python (`postgres.submit`
58 µs, `postgres.discover` 21 µs). Measured the same way as Python, the store
rows are within about 15% of it either way: their time is the server's work
and the round trips, which both clients share. `postgres.discover` is one
capability-filtered `SELECT`; Haskell's figure is about 12 µs above Python's
in both repetitions, and that client-side cost has not been tracked down yet.
The in-memory rows (`envelope.*`, `canonical.16KiB`) are unchanged.

## Notes

- `canonical.16KiB` first measured 326 µs, 2.4× slower than Python, with
  petrus-json's general encoder (Builder-based, with `floatToDigits`
  float spelling). `Petrus.Fabric.Canonical` replaced it with two passes:
  one measures an upper bound of the output and checks the refusals, and
  one writes straight into a buffer of that size. Its floats use a port of
  the reference Ryu algorithm (≈60 ns a float against ≈450 ns), and small
  objects are sorted with an insertion sort. The same encoder serves every
  digest and size check, so `envelope.*` gained 25–40% as well.
- The store rows include the round trips to the server. Both sides use one
  autocommit connection to the same server and the same SQL.

## Rerun

From the repository root (`scripts/bench petrus-fabric` runs exactly this block). The store rows
need a server where the role may create databases in `PETRUS_TEST_POSTGRES`; when that is unset,
`scripts/bench` and `scripts/bench-compare` start a throwaway one with `scripts/with-postgres`.

<!-- scripts/bench: rerun -->
```sh
cabal bench -j2 petrus-fabric --benchmark-options '--stdev 5 --timeout 300 +RTS -M2G -RTS'
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-fabric/bench/python_bench.py)
```

`scripts/bench-compare petrus-fabric 2` interleaves both sides and prints the table above.
