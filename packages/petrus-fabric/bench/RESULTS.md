# petrus-fabric benchmarks

<!-- scripts/bench: measured sources 97610f156b71eb16 at d880d2fd15f9 -->

Python figures time the upstream code path named in `bench/python_bench.py`;
Haskell figures are tasty-bench means of `bench/Main.hs`, which uses the same
names, values and store operations. Both are wall-clock time. Ratios above 1
mean Haskell is faster. Haskell is faster on every row: 1.40–1.65× on the
store operations, which run as prepared statements as psycopg's do (see
below), and 1.8–10× on the in-memory work.

## Current figures

Measured on 2026-10-12, 18:41–18:44 local (UTC-3), at commit `4cf1bd5`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 1.89–2.77:
five interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-fabric 5

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The store rows ran on `scripts/with-postgres`'s throwaway PostgreSQL 17.7 on 127.0.0.1 (`initdb` defaults). On this quiet machine the store rows read 1.40–1.65× (1.35–1.55× at `81bbdc5`); the 1.9–2.4× of the earlier table below came from runs at load 4.3–7.7, which slowed the Python side more than the Haskell side. The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `envelope.build` | 1.24 µs | 12.1 µs | 9.80× | 9.64× | 5 of 5 | 1.25 µs, 1.22 µs, 1.26 µs, 1.23 µs, 1.24 µs | 12.2 µs, 12.2 µs, 12.1 µs, 12.1 µs, 12.1 µs |
| `envelope.digest` | 2.9 µs | 20 µs | 6.91× | 6.89× | 5 of 5 | 2.88 µs, 2.9 µs, 2.9 µs, 2.88 µs, 2.91 µs | 19.9 µs, 20 µs, 20 µs, 20.3 µs, 20.2 µs |
| `envelope.roundtrip` | 1.81 µs | 18.5 µs | 10.21× | 10.11× | 5 of 5 | 1.82 µs, 1.81 µs, 1.81 µs, 1.81 µs, 1.81 µs | 18.4 µs, 18.4 µs, 18.5 µs, 18.5 µs, 18.5 µs |
| `canonical.16KiB` | 75 µs | 135 µs | 1.80× | 1.79× | 5 of 5 | 75 µs, 74.9 µs, 75 µs, 75.5 µs, 74.7 µs | 135 µs, 135 µs, 135 µs, 136 µs, 135 µs |
| `postgres.submit` | 152 µs | 233 µs | 1.53× | 1.50× | 5 of 5 | 147 µs, 152 µs, 153 µs, 152 µs, 156 µs | 233 µs, 235 µs, 230 µs, 231 µs, 233 µs |
| `postgres.submit-duplicate` | 77.9 µs | 109 µs | 1.40× | 1.38× | 5 of 5 | 75.9 µs, 77.6 µs, 77.9 µs, 77.9 µs, 78.3 µs | 108 µs, 110 µs, 108 µs, 109 µs, 109 µs |
| `postgres.send-drain` | 304 µs | 465 µs | 1.53× | 1.51× | 5 of 5 | 297 µs, 304 µs, 301 µs, 305 µs, 308 µs | 465 µs, 469 µs, 465 µs, 467 µs, 465 µs |
| `postgres.discover` | 46.2 µs | 76.4 µs | 1.65× | 1.64× | 5 of 5 | 46 µs, 46.4 µs, 46.1 µs, 46.2 µs, 46.5 µs | 76.4 µs, 76.7 µs, 75.9 µs, 76.6 µs, 76.2 µs |

## Earlier figures

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

<!-- bench: superseded -->

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
  float spelling). A dedicated encoder, `Petrus.Fabric.Canonical`, replaced
  it. It ran two passes, one to bound the output and check the refusals and
  one to write into a buffer of that size, and spelled floats with a port of
  the reference Ryu algorithm. That Ryu port now lives in petrus-json
  (`Petrus.Json.Float`) and spells every petrus-json float, and petrus-json's
  `dumps` now writes straight into one buffer. So the dedicated encoder was
  measured against plain `dumps` on 2026-10-12, on the Apple M4 at a
  one-minute load average of about 5. Each variant's benchmark executable
  ran five interleaved repetitions, and each cell below is the median of
  the five tasty-bench means:

  | row | dedicated encoder | petrus-json `dumps` (now) | Python | now vs Python |
  | --- | ---: | ---: | ---: | ---: |
  | `canonical.16KiB` | 66.2 µs | 90.3 µs | 135 µs | 1.49× |
  | `envelope.build` | 1.41 µs | 1.82 µs | 12.0 µs | 6.6× |
  | `envelope.digest` | 3.42 µs | 5.05 µs | 19.9 µs | 3.9× |
  | `envelope.roundtrip` | 2.17 µs | 2.61 µs | 18.3 µs | 7.0× |

  The general encoder clears CPython on every row, so `canonicalBytes` is
  `dumps` and the dedicated encoder is gone.
- The store rows include the round trips to the server. Both sides use one
  autocommit connection to the same server and the same SQL.

## Rerun

From the repository root (`scripts/bench petrus-fabric` runs exactly this block). The store rows
need a server where the role may create databases in `PETRUS_TEST_POSTGRES`; when that is unset,
`scripts/bench` and `scripts/bench-compare` start a throwaway one with `scripts/with-postgres`.

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run petrus-fabric --stdev 5 --timeout 300 +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-fabric/bench/python_bench.py)
```

`scripts/bench-compare petrus-fabric 6` interleaves both sides over six repetitions and prints a
table like the one above; the table pools two such runs.
