# petrus-posix: divergences from CPython

Intentional differences from the CPython 3.14 calls this package mirrors
(`fcntl.flock`, `os.open`/`os.*` with `dir_fd`, `pathlib.Path.resolve` and
`expanduser`, `os.path.realpath`, `tempfile`/`uuid` naming, `os.fsync`,
`resource.getrusage`, `os.sysconf`, `os.confstr("CS_PATH")`, and
`shutil.rmtree` without `onexc`). Everything not listed here is meant to be
identical; the test suite checks the observable behavior against Python
(including cross-process `flock` exclusion in both directions).

| Behavior | CPython 3.14 | petrus-posix | Why |
| --- | --- | --- | --- |
| Random part of temporary names (`tmpXXXXXXXX`, `uuid4().hex`) | `tempfile` uses `random.Random` seeded from `os.urandom`; `uuid4` uses `os.urandom`. | The `random` package's global generator (SplitMix, seeded from the system at start). The spelling (alphabet, length, version and variant bits) is identical. | The names only need to be unlikely to collide; safety comes from `O_CREAT \| O_EXCL`, and a collision draws a new name. No upstream behavior depends on the randomness quality. |
| Fork safety of locks | The SQLite engine closes inherited fence descriptors after `fork` (`os.register_at_fork`). | Not provided here. | Haskell programs do not `fork` the running process; the engine's `ensure` PID check lives in petrus-sqlite. |
| Path strings with undecodable bytes | `str` paths carry undecodable bytes as surrogate escapes (`os.fsdecode`). | `FilePath` uses GHC's file-system encoding, which round-trips undecodable bytes the same way (PEP 383 escapes). `realpath` walks the encoded bytes and decodes once. | Same bytes reach the kernel; the in-memory representation differs only in type. |
| `os.close` | Interruptible, releases the GIL. | `closeFd` from `unix`. | Equivalent. |

No other differences are known. In particular the lock primitive is real
`flock(2)` (not GHC's `hLock`, which prefers OFD `fcntl` locks on Linux), the
lock-file mode is `0600`, `Path.resolve` follows CPython's non-strict
algorithm exactly (missing tails kept, loops left unresolved, `..` applied
after symlink resolution), and `max_rss_mb` keeps the Darwin-bytes and
Linux-KiB divisors and CPython's correctly rounded `round(x, 1)`.
