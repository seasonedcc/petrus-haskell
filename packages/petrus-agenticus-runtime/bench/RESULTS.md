# petrus-agenticus-runtime benchmark results

<!-- scripts/bench: measured sources 74c3be7661028153 at df073f3106e5 -->
<!-- scripts/bench: carried to 18f6681461150a58 at f87d05b6f42b: since 50635f0, no behavior or representation change on the measured paths: Claude's pyTruthy (its isError check) is petrus-json's pythonTruthy, the same seven equations, as are petrus-execution's Docker and Gondolin providers' local truthy; petrus-history-store's floatEqualsInteger calls pyNumberEq, the same exact test, reached only for a REAL position or a float occurrence, which the store never writes; petrus-impetus's literalInt float branch and petrus-motus's local-dispatch sqlite3 int-against-float == call pyNumberEq, the same exact test they spelled out; petrus-sqlite's checkBindLength names the either throwIO pure . bindLength its bind loop already ran; petrus-json's Json == compiles to the same optimized Core as at 50635f0 (-ddump-simpl compared; numericEq/intFloatEq moved as pyNumberEq/exactFloatEq into Petrus.Json.Value and inlined there), PyObject's pyEq likewise, pythonTruthy added; petrus-posix gains additions only (DirectFd, directFd, writeDirect) and docs -->

The Pi benchmarks (frame codec, session validation, fingerprints, the
operation ledger and a scripted A2 turn) are in [results-pi.md](results-pi.md).
This file covers the Local Agent-as-a-Net runner.

These are twin workloads: `bench/Main.hs` (tasty-bench) and
`bench/python_runner.py`, which runs the pinned reference
(`upstream/petrus` @ 3f85fc2).

- `runner-3-phases-3-reads` builds an Episode Attachment with its grant,
  creates a runner in a fresh temporary directory and drains it to the
  terminal.
  - Model phase 1 proposes two `workspace_read` calls, phase 2 proposes one,
    and phase 3 stops.
  - Every projection is saved through the atomic JSON repository, with two
    fsyncs per save, and every History record is appended to
    `history.jsonl`.
- `projection-roundtrip` runs `AgentNetThreadProjection.from_data(json.loads(text))`
  and dumps the result back to compact sorted JSON. The input is that run's
  final `thread.json`.

## Current figures

Measured on 2026-10-13, 03:22–03:29 local (UTC-3), at commit `df073f3`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.45–3.82:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-agenticus-runtime 3 --python python_runner.py --python python_pi.py --python python_pi_a2.py --python python_hosts.py --python python_bench.py

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The same three repetitions measured the rows of [results-pi.md](results-pi.md) and [results-hosts.md](results-hosts.md), whose current figures are there. The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `runner-3-phases-3-reads` | 5.16 ms | 10.3 ms | 1.99× | 1.94× | 3 of 3 | 5.29 ms, 5.16 ms, 5.16 ms | 10.3 ms, 10.6 ms, 10.2 ms |
| `projection-roundtrip` | 34.3 µs | 109 µs | 3.17× | 3.08× | 3 of 3 | 34.6 µs, 34.3 µs, 34.2 µs | 106 µs, 109 µs, 109 µs |

### 2026-10-13, at `c0cb6cb` (superseded)

<!-- bench: superseded -->

Measured on 2026-10-13, 01:06–01:12 local (UTC-3), with a 1-minute load
average of 2.05–3.65: three interleaved repetitions of the command above. Superseded by the run at `df073f3` above.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `runner-3-phases-3-reads` | 5.15 ms | 10.3 ms | 2.00× | 1.98× | 3 of 3 | 5.15 ms, 5.1 ms, 5.19 ms | 10.3 ms, 10.2 ms, 10.3 ms |
| `projection-roundtrip` | 35.2 µs | 107 µs | 3.04× | 3.04× | 3 of 3 | 35 µs, 35.4 µs, 35.2 µs | 107 µs, 109 µs, 107 µs |

### 2026-10-12, at `13f7a84` (superseded)

<!-- bench: superseded -->

Measured on 2026-10-12, 22:26–22:32 local (UTC-3), with a 1-minute load
average of 2.03–3.60: three interleaved repetitions of the command above.
Superseded by the run at `c0cb6cb`.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `runner-3-phases-3-reads` | 5.41 ms | 10.1 ms | 1.86× | 1.84× | 3 of 3 | 4.99 ms, 5.41 ms, 5.48 ms | 10 ms, 10.1 ms, 10.1 ms |
| `projection-roundtrip` | 34.8 µs | 108 µs | 3.11× | 3.04× | 3 of 3 | 34.8 µs, 34.2 µs, 35.2 µs | 108 µs, 108 µs, 107 µs |

## Results

Environment:

- Apple M4, macOS (Darwin 25.3), APFS, 2026-10-10.
- GHC 9.10.3, `-O2`, run with `+RTS -A32m -M2G`.
- CPython 3.14.6.

Method: five interleaved rounds, together with the Pi rows of
[results-pi.md](results-pi.md). Each round ran the Haskell bench, then the
Python scripts. A Haskell value is a tasty-bench mean (`--stdev 3`); a
Python value is the script's median of 7 batches. The table gives the median
of the five rounds. The machine was shared with other work (load average 3.7
to 5.8).

<!-- bench: superseded -->

| Benchmark | Haskell | Python | Python / Haskell | Slowest round |
| --- | ---: | ---: | ---: | ---: |
| runner-3-phases-3-reads | 6.02 ms | 11.17 ms | 1.86× | 1.8× |
| projection-roundtrip | 42.0 µs | 110 µs | 2.6× | 2.4× |

The five rounds timed Haskell in tasty-bench's default CPU time.
`runner-3-phases-3-reads` does file IO with fsyncs inside the timed region,
where CPU time leaves out the waits, so its row comes from a separate
wall-clock rerun (`--time-mode wall`, as the rerun block below passes)
interleaved with Python: Haskell 5.75 and 6.29 ms, Python 10.95 and
11.38 ms (2026-10-10, 21:39–21:40 local, commit `74e6b1e`, load average
5.4–5.6); the row shows the medians, and the slowest-round column the worse
of the two pairs. In CPU time the five rounds had read 5.41 ms against
10.2 ms (1.9×). `projection-roundtrip` is in memory and keeps its CPU-time
figure, for which the two clocks agree.

The full run is dominated by file-system work (temporary-file creation,
fsync, rename and History appends), which costs the same in both languages.
The round trip is mostly JSON text encoding. It was 1.4× (81.8 µs) before
petrus-json's encoder was rewritten to write in one pass.

## Rerun

From the repository root (`scripts/bench petrus-agenticus-runtime` runs exactly this block, for
this file's rows, [results-pi.md](results-pi.md)'s and [results-hosts.md](results-hosts.md)'s; `scripts/upstream-python` provisions the
pinned reference). `--time-mode wall` makes tasty-bench measure wall-clock time, like the
Python side's `time.perf_counter`:

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run petrus-agenticus-runtime --time-mode wall +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus-runtime/bench/python_runner.py)
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus-runtime/bench/python_pi.py)
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus-runtime/bench/python_pi_a2.py)
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus-runtime/bench/python_hosts.py)
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus-runtime/bench/python_bench.py)
```

CI's smoke run on a `full` dispatch (`scripts/bench --smoke`, not a measurement, on
Linux): every row once.

<!-- scripts/bench: smoke -->
```sh
cd packages/petrus-agenticus-runtime && "$BENCH_BIN" --stdev Infinity +RTS -M2G -RTS
```

`bench/python_bench.py` holds the whole-Turn twins (`codex-turn`,
`codex-a3-service-turn`, `claude-turn`, `amp-turn`; see
[results-hosts.md](results-hosts.md); `pi-native-turn`, `pi-a5-turn`,
`pi-model-phase-turn`; see [results-pi.md](results-pi.md)), so
`scripts/bench-compare petrus-agenticus-runtime N` interleaves those rows.
