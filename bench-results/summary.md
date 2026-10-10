# Benchmark summary

- Date: 2026-10-10 15:55 UTC
- Commit: `748efc7`
- Machine: Darwin arm64, Apple M4
- Haskell: GHC 9.10.3 (-O2), tasty-bench mean
- Python: CPython 3.14.6 (upstream venv), median of timed batches (scripts/bench_timing.py)

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
