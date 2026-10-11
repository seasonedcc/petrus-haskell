# petrus-execution benchmark results

The Haskell port compared with upstream Python Petrus (`petrus.motus.execution` /
`_execution` at the pin in [UPSTREAM.md](../../../UPSTREAM.md)). Both harnesses run the same
workloads, iteration counts and operations:

| Benchmark | Operation (upstream / Haskell) | Iterations per round |
| --- | --- | --- |
| `archive/<w>/pack+sha256` | `workspace_archive(tree)` + SHA-256 hex / `workspaceArchive` + `archiveDigest` | 7 |
| `archive/<w>/validate` | `validate_workspace_archive` / `validateWorkspaceArchive` | 7 |
| `archive/<w>/extract` | `extract_workspace_archive` into a fresh directory / `extractWorkspaceArchive` | 7 |
| `process/run-captured` | `subprocess.run(("/usr/bin/true",), capture_output=True, timeout=5)` / `runCaptured` | 100 |
| `sidecar/handshake-round-trip` | `GondolinEnvironment._request(record, {"action": "handshake"})` / `sidecarRequest` | 1000 |
| `sidecar/execute-round-trip` | `environment.execute(attachment, Command(("/bin/sh", "-c", "true")))` / `providerExecute` | 50 |

Workloads (`make_workloads.py`, seeded pseudo-random contents):

- `many-small`: 10 000 files of 1 KiB in 100 directories
- `medium`: 1 000 files of 64 KiB in 10 directories
- `one-large`: 1 file of 256 MiB

The sidecar benchmarks provision one real territory through each implementation's provider. The
territory runs upstream's verbatim `gondolin_sidecar.mjs` on Node, backed by the committed fake
Gondolin SDK (`test/fixtures/fake_gondolin.mjs`). The Node-side work is the same for both, so
these rows measure each client's socket, framing, registry and JSON costs on top of a shared
fixed cost.

## Environment

- Apple M4 (10 cores), macOS 26.3.1, APFS SSD
- Python 3.14.6 (`upstream/petrus/.venv`), GHC 9.10.3 with `-O2 -threaded`, Node v22.22.0 for the sidecar
- 2026-10-10, on a shared machine: other builds and benchmarks kept the load average between 3.8 and 6

## Method

`compare.py` alternates the two harnesses, Python first and then Haskell, for N rounds, so both
see the same machine state. Each harness reports one median per benchmark per round. The table
shows the median of those per-round medians. A ratio above 1 means Haskell is faster.

## Results

`compare.py`, 5 interleaved rounds:

| benchmark | Python (ms) | Haskell (ms) | Python / Haskell |
|---|---:|---:|---:|
| archive/many-small/pack+sha256 | 521.973 | 185.141 | 2.82x |
| archive/many-small/validate | 96.875 | 42.098 | 2.30x |
| archive/many-small/extract | 1209.079 | 948.332 | 1.27x |
| archive/medium/pack+sha256 | 81.898 | 42.829 | 1.91x |
| archive/medium/validate | 9.437 | 4.478 | 2.11x |
| archive/medium/extract | 155.494 | 123.061 | 1.26x |
| archive/one-large/pack+sha256 | 131.149 | 111.167 | 1.18x |
| archive/one-large/validate | 0.080 | 0.010 | 7.97x |
| archive/one-large/extract | 152.094 | 133.841 | 1.14x |
| process/run-captured | 1.452 | 0.783 | 1.85x |
| sidecar/handshake-round-trip | 0.034 | 0.034 | 1.00x |
| sidecar/execute-round-trip | 5.497 | 5.602 | 0.98x |

The two sidecar rows are within noise, so they were run again on their own for 10 interleaved
rounds (`PETRUS_BENCH_ONLY=none`, which skips the archive workloads):

| benchmark | Python (ms) | Haskell (ms) | Python / Haskell | rounds Haskell won |
|---|---:|---:|---:|---:|
| process/run-captured | 1.529 | 0.846 | 1.81x | 10/10 |
| sidecar/handshake-round-trip | 0.033 | 0.033 | 1.01x | 7/10 |
| sidecar/execute-round-trip | 6.463 | 6.613 | 0.98x | 6/10 |

### Reading the numbers

- **Archive codec.** Haskell is faster on every pack and validate. The output bytes are identical
  to Python's, as the differential fixtures prove. Validating the single 256 MiB member is a
  header walk.
- **Extraction** is dominated by file creation and the kernel write path. It writes in 64 KiB
  chunks, which measured fastest for this filesystem: a raw Python `os.write` loop over 256 MiB
  took a median of about 68 ms with 64 KiB chunks, against 82 ms at 1 MiB and 100 ms at 16 KiB.
  `one-large/extract` is the most I/O-bound and noisiest row. Across other runs it ranged from
  0.90x to 1.14x. A dedicated 10-round interleaved run of that row alone gave medians of 74.4 ms
  for Python and 70.8 ms for Haskell.
- **Process spawning** is about 1.8x faster. It uses `posix_spawn` with close-on-exec-by-default,
  not the `process` package's `close_fds` loop; see DIVERGENCES.md. Before that change, a Haskell
  spawn cost about 118 ms, because the loop closes every descriptor up to the
  `RLIMIT_NOFILE` of 1 048 576.
- **Sidecar round trips** are at parity: the medians are equal or within 2%, and Haskell wins most
  rounds. Each handshake is one Unix-socket connect, send, `poll` and receive, about 33 µs on both
  sides. Each execute is a handshake plus an execute request, and Node spawning `sh` dominates
  it, which neither client controls. Two things made the Haskell client faster here:
  - the `poll()`-based wait (DIVERGENCES.md), which cut the handshake from 0.141 ms to 0.033 ms
  - `posix_spawn` for the sidecar process

## Rerunning

From the repository root (`scripts/bench petrus-execution` runs exactly this block; it sets
`BENCH_TMP` to a directory under the git-ignored `bench-results/tmp/`):

<!-- scripts/bench: rerun -->
```sh
cabal build -j2 petrus-execution:bench:petrus-execution-bench
# Everything, interleaved; the work directory receives about 330 MiB of workloads.
"$(scripts/upstream-python)" -B packages/petrus-execution/bench/compare.py "${BENCH_TMP:-bench-results/tmp/petrus-execution}/workloads" 5
rm -rf "${BENCH_TMP:-bench-results/tmp/petrus-execution}/workloads"
```

Both harnesses read the monotonic clock, so both sides are wall-clock time.

By hand:

```
cabal build petrus-execution:bench:petrus-execution-bench

# Everything, interleaved (WORKDIR receives about 330 MiB of workloads):
"$(scripts/upstream-python)" packages/petrus-execution/bench/compare.py WORKDIR 5

# Individual harnesses (one JSON line per benchmark):
python3 packages/petrus-execution/bench/make_workloads.py WORKDIR
"$(scripts/upstream-python)" packages/petrus-execution/bench/python_bench.py \
  WORKDIR packages/petrus-execution/test/fixtures/fake_gondolin.mjs
cabal run -v0 petrus-execution:bench:petrus-execution-bench -- \
  WORKDIR packages/petrus-execution/test/fixtures/fake_gondolin.mjs
```

`PETRUS_BENCH_ONLY=<workload>` restricts either harness to one archive workload. Any other value,
such as `none`, skips the archive workloads and keeps the process and sidecar benchmarks. Without
the fake SDK argument, the sidecar benchmarks are skipped. `compare.py` needs `cabal` on `PATH`
to locate the benchmark binary.
