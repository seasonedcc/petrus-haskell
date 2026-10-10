# Benchmark summary

- Date: 2026-10-10 17:30 UTC
- Commit: `70622a0`
- Machine: Darwin arm64, Apple M4
- Haskell: GHC 9.10.3 (-O2), tasty-bench mean
- Python: CPython 3.14.6 (upstream venv), median of timed batches (scripts/bench_timing.py)

## petrus-http-core

| Benchmark | Haskell | Python | Python / Haskell |
|---|---:|---:|---:|
| `roundtrip.get-snapshot` | 37.5 µs | 104 µs | 2.77× |
| `roundtrip.post-1k` | 45 µs | 105 µs | 2.32× |
| `roundtrip.refused-version` | 35.7 µs | 96.1 µs | 2.69× |
| `parse.request-head` | 729 ns | 14.1 µs | 19.33× |
| `render.send-error` | 1.92 µs | 4.51 µs | 2.35× |
| `render.response` | 882 ns | 3.56 µs | 4.03× |

## petrus-posix

| Benchmark | Haskell | Python | Python / Haskell |
|---|---:|---:|---:|
| `flock.tryLock-unlock` | 619 ns | 652 ns | 1.05× |
| `flock.open-tryLock-close` | 15.2 µs | 14.8 µs | 0.97× |
| `path.resolve-symlinked` | 14.1 µs | 17.8 µs | 1.26× |
| `path.expanduser-resolve` | 13.2 µs | 17.8 µs | 1.35× |
| `at.stat-nofollow` | 875 ns | 996 ns | 1.14× |
| `atomic.write-1KiB-fsync` | 139 µs | 153 µs | 1.10× |
| `resource.max_rss_mb` | 243 ns | 466 ns | 1.92× |

## petrus-postgres

| Benchmark | Haskell | Python | Python / Haskell |
|---|---:|---:|---:|
| `roundtrip.select-1` | 9.5 µs | 57.5 µs | 6.05× |
| `roundtrip.select-param` | 10.4 µs | 84.3 µs | 8.08× |
| `query.select-1000-decoded` | 729 µs | 2.52 ms | 3.46× |
| `tx.join-insert-commit` | 33.3 µs | 239 µs | 7.17× |
| `tx.owned-insert-10` | 222 µs | 1.12 ms | 5.04× |
| `fence.acquire-release` | 30.5 µs | 165 µs | 5.42× |
| `notify.roundtrip` | 33.8 µs | 114 µs | 3.36× |
| `params.convert-placeholders` | 448 ns | 4.5 µs | 10.03× |

## petrus-sqlite

| Benchmark | Haskell | Python | Python / Haskell |
|---|---:|---:|---:|
| `connect.local-dispatch-profile` | 49.9 µs | 60.1 µs | 1.21× |
| `tx.immediate-insert-commit` | 21.4 µs | 35.4 µs | 1.65× |
| `tx.immediate-insert-100` | 302 µs | 339 µs | 1.12× |
| `query.select-by-key` | 1.28 µs | 1.74 µs | 1.36× |
| `query.select-1000` | 393 µs | 459 µs | 1.17× |
| `schema.normalize-ddl` | 3.46 µs | 5.34 µs | 1.55× |
| `fence.acquire-release` | 39.9 µs | 39.9 µs | 1.00× |
