# Benchmark summary

- Date: 2026-10-10 17:47 UTC
- Commit: `eef6b6a`
- Machine: Darwin arm64, Apple M4
- Haskell: GHC 9.10.3 (-O2), tasty-bench mean
- Python: CPython 3.14.6 (upstream venv), median of timed batches (scripts/bench_timing.py)

## petrus-http-core

| Benchmark | Haskell | Python | Python / Haskell |
|---|---:|---:|---:|
| `roundtrip.get-snapshot` | 43.9 µs | 122 µs | 2.77× |
| `roundtrip.post-1k` | 46 µs | 129 µs | 2.80× |
| `roundtrip.refused-version` | 43.1 µs | 102 µs | 2.36× |
| `parse.request-head` | 757 ns | 14.4 µs | 19.08× |
| `render.send-error` | 2.03 µs | 4.65 µs | 2.29× |
| `render.response` | 953 ns | 3.65 µs | 3.83× |

## petrus-posix

| Benchmark | Haskell | Python | Python / Haskell |
|---|---:|---:|---:|
| `flock.tryLock-unlock` | 599 ns | 625 ns | 1.04× |
| `flock.open-tryLock-close` | 15.5 µs | 14.1 µs | 0.91× |
| `path.resolve-symlinked` | 13 µs | 17.2 µs | 1.32× |
| `path.expanduser-resolve` | 13.4 µs | 17.4 µs | 1.29× |
| `at.stat-nofollow` | 861 ns | 947 ns | 1.10× |
| `atomic.write-1KiB-fsync` | 133 µs | 154 µs | 1.16× |
| `resource.max_rss_mb` | 212 ns | 445 ns | 2.10× |

## petrus-postgres

| Benchmark | Haskell | Python | Python / Haskell |
|---|---:|---:|---:|
| `roundtrip.select-1` | 9.8 µs | 28.1 µs | 2.87× |
| `roundtrip.select-param` | 10.1 µs | 29.1 µs | 2.89× |
| `query.select-1000-decoded` | 601 µs | 1.82 ms | 3.02× |
| `tx.join-insert-commit` | 30 µs | 80.2 µs | 2.67× |
| `tx.owned-insert-10` | 121 µs | 644 µs | 5.33× |
| `fence.acquire-release` | 22.8 µs | 78.6 µs | 3.45× |
| `notify.roundtrip` | 14.1 µs | 41.4 µs | 2.93× |
| `params.convert-placeholders` | 325 ns | 4.24 µs | 13.04× |

## petrus-sqlite

| Benchmark | Haskell | Python | Python / Haskell |
|---|---:|---:|---:|
| `connect.local-dispatch-profile` | 55.1 µs | 67.4 µs | 1.22× |
| `tx.immediate-insert-commit` | 34.4 µs | 51 µs | 1.48× |
| `tx.immediate-insert-100` | 489 µs | 527 µs | 1.08× |
| `query.select-by-key` | 1.34 µs | 1.79 µs | 1.33× |
| `query.select-1000` | 442 µs | 478 µs | 1.08× |
| `schema.normalize-ddl` | 3.53 µs | 5.63 µs | 1.59× |
| `fence.acquire-release` | 44.7 µs | 45.9 µs | 1.03× |
