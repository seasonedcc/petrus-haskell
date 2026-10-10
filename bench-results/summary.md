# Benchmark summary

- Date: 2026-10-10 16:12 UTC
- Commit: `ed50a6f`
- Machine: Darwin arm64, Apple M4
- Haskell: GHC 9.10.3 (-O2), tasty-bench mean
- Python: CPython 3.14.6 (upstream venv), median of timed batches (scripts/bench_timing.py)

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
