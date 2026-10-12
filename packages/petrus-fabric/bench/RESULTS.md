# petrus-fabric benchmarks

<!-- scripts/bench: measured sources 9e41647c2fc3c3d0 at 14f6d69e9572 -->

Python figures time the upstream code path named in `bench/python_bench.py`;
Haskell figures are tasty-bench means of `bench/Main.hs`, which uses the same
names, values and store operations. Both are wall-clock time. Ratios above 1
mean Haskell is faster. Haskell is faster on every row: 1.9–2.4× on the store
operations, which now run as prepared statements as psycopg's do (see below),
and 2.3–9.6× on the in-memory work.

- Date: 2026-10-10 23:54 to 2026-10-11 00:35 local (UTC-3), two runs of
  `scripts/bench-compare petrus-fabric 6` (23:54–00:08 and 00:22–00:35), on the commit
  that adds petrus-postgres's prepared-statement cache
- Machine: Darwin arm64, Apple M4, heavily shared with other agents' builds and benchmarks;
  1-minute load average 4.3–7.7 around the runs
- Haskell: GHC 9.10.3 (-O2), tasty-bench mean in wall-clock time, `--stdev 5`, `+RTS -M2G -RTS`
- Python: CPython 3.14.6 (upstream venv), psycopg 3.3.4, median of 10 timed batches of 0.2 s
  (scripts/bench_timing.py)
- PostgreSQL 17.7, a throwaway server from `scripts/with-postgres` (Postgres.app binaries,
  `initdb` defaults) on 127.0.0.1, one per run; the store rows use a scratch database each
  repetition
- Interleaved: each run alternates Haskell first and Python first over six repetitions. The
  figures are the medians of all twelve repetitions; "lowest" is the worst single
  repetition's ratio, and the last column counts the repetitions Haskell won.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Repetitions Haskell faster |
|---|---:|---:|---:|---:|---:|
| `envelope.build` | 1.43 µs | 12.9 µs | 8.98× | 7.46× | 12/12 |
| `envelope.digest` | 3.16 µs | 21.4 µs | 6.77× | 5.14× | 12/12 |
| `envelope.roundtrip` | 2.06 µs | 19.8 µs | 9.60× | 6.97× | 12/12 |
| `canonical.16KiB` | 63.5 µs | 144 µs | 2.27× | 2.01× | 12/12 |
| `postgres.submit` | 203 µs | 459 µs | 2.27× | 1.24× | 12/12 |
| `postgres.submit-duplicate` | 102 µs | 242 µs | 2.36× | 0.68× | 10/12 |
| `postgres.send-drain` | 467 µs | 936 µs | 2.00× | 0.68× | 11/12 |
| `postgres.discover` | 66 µs | 128 µs | 1.94× | 0.75× | 10/12 |

The load was high and uneven, and every store figure moved with it: Haskell's
`postgres.discover` ranged from 46 µs to 118 µs over the twelve repetitions,
and Python's from 65 µs to 201 µs. Python's `postgres.submit` ranged from
241 µs to 762 µs, against 237 µs in the quieter run of the superseded table
below. The two runs agree with each other: `postgres.discover` came out at
1.62× and 1.66× on their own medians, and `postgres.submit` at 3.39× and
1.59×. Haskell lost `postgres.discover` in two repetitions (0.75× and 0.95×),
`postgres.submit-duplicate` in two and `postgres.send-drain` in one. Before
the change below, Haskell lost `postgres.discover` in both repetitions, by
about 12 µs each time.

### The prepared-statement cache

The store rows used to trail Python: `postgres.discover` at 0.86× and
`postgres.submit` at 0.97× (the superseded table below). With
`log_statement = all` on a throwaway server, both clients sent the same
statements for every operation, in the same order, with the same `BEGIN` and
`COMMIT` round trips (Haskell spells `BEGIN ISOLATION LEVEL READ COMMITTED`,
see petrus-postgres's DIVERGENCES). The one difference was psycopg's
prepared-statement cache. From its sixth execution on a connection, psycopg
runs a statement by name (`execute _pg3_1: SELECT o.instance_id …`), which
spares the server the parse and plan of the capability-filtered join.
petrus-postgres sent every statement unnamed (`execute <unnamed>: …`), so the
server parsed and planned `discover`'s join, and each of `submit`'s five
statements, on every call. petrus-postgres now keeps the same cache as
psycopg, with the same threshold, size, statement names and discards; see
[its DIVERGENCES](../../petrus-postgres/DIVERGENCES.md). After the change the
statement logs of the two clients are identical line for line, statement
names included. Each operation still makes the same round trips.
`postgres.discover` went from 87.8 µs to about 46 µs at the lower loads.

### Before the prepared-statement cache

<!-- bench: superseded -->

2026-10-10 21:01–21:06 local, commit `74e6b1e`, `scripts/bench-compare petrus-fabric 2`, load
average 3.0–4.0:

| Benchmark | Haskell | Python | Python / Haskell (before) | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---|---|
| `envelope.build` | 1.27 µs | 12.5 µs | 9.89× | 1.2 µs, 1.34 µs | 12.4 µs, 12.6 µs |
| `envelope.digest` | 3.17 µs | 20.2 µs | 6.37× | 2.96 µs, 3.38 µs | 20.2 µs, 20.2 µs |
| `envelope.roundtrip` | 2.02 µs | 18.8 µs | 9.30× | 1.85 µs, 2.18 µs | 18.7 µs, 18.8 µs |
| `canonical.16KiB` | 62.9 µs | 138 µs | 2.19× | 58 µs, 67.7 µs | 139 µs, 137 µs |
| `postgres.submit` | 245 µs | 237 µs | 0.97× | 226 µs, 264 µs | 238 µs, 236 µs |
| `postgres.submit-duplicate` | 103 µs | 111 µs | 1.08× | 99.5 µs, 107 µs | 114 µs, 109 µs |
| `postgres.send-drain` | 458 µs | 499 µs | 1.09× | 442 µs, 473 µs | 528 µs, 470 µs |
| `postgres.discover` | 87.8 µs | 75.5 µs | 0.86× | 85.2 µs, 90.3 µs | 77.7 µs, 73.3 µs |

The figures committed before those timed Haskell in tasty-bench's default CPU
time, against Python's wall-clock time. CPU time leaves out the wait for the
server, so the store rows read 3.7–4.1× faster than Python (`postgres.submit`
58 µs, `postgres.discover` 21 µs).

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

From the repository root (`scripts/bench petrus-fabric` runs exactly this block). The store rows
need a server where the role may create databases in `PETRUS_TEST_POSTGRES`; when that is unset,
`scripts/bench` and `scripts/bench-compare` start a throwaway one with `scripts/with-postgres`.

<!-- scripts/bench: rerun -->
```sh
cabal bench -j2 petrus-fabric --benchmark-options '--stdev 5 --timeout 300 +RTS -M2G -RTS'
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-fabric/bench/python_bench.py)
```

`scripts/bench-compare petrus-fabric 6` interleaves both sides over six repetitions and prints a
table like the one above; the table pools two such runs.
