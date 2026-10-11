# hamsterdan-host benchmarks

These are the host's hot paths:

- **Webhook ingest:** 100 signed `pull_request` deliveries, each sent as a
  `POST /github/webhooks` through the HTTP application, called in process,
  into one long-lived host. That covers the header and body checks, the
  signature, routing, and durable custody in `webhooks.sqlite3`.
- **Reconciliation step:** one webhook driven to quiescence on a fresh
  Instance:
  1. Open the host on a fresh state directory.
  2. Take the delivery into custody.
  3. Process it through the real V5 application against the `V5Provider`
     double. That covers the PR reads, the review, and the dashboard
     publication.
  4. Pump until nothing is runnable.
  5. Close the host and remove the directory.
- **Gate classification:** `reply_gate`, `reminder_gate` and `dash_gate`
  under each of the eight publisher outcomes of `test_v5_gates.py`, for 24
  classifications.
- **Timer rebuild:** `V5TimerStore.open` of a fresh store from the 333-fact
  timer History in `inputs.json`, which `make_inputs.py` generates. The
  store is then closed and removed.
- **Fresh open:** the same open with no History. It separates the SQLite
  file work (create, WAL, schema) from the History replay.

Both sides run the same operations on the same inputs, using the doubles
that the state interop tests use (`differential/state_reference.py`, and
`test/V5Doubles.hs`). Each side sends the Worker's progress lines to
`/dev/null`.

## Results

<!-- parity: rows below 1.0× belong to "V5 timers" -->

The machine was an Apple M4 (10 cores), macOS 26.3.1, shared with other
work. The load average was 4.0–4.3 during these runs (2026-10-10,
22:54–22:55 local, UTC-3, commit `aaafd62`).

- **Haskell:** GHC 9.10.3 with `-O2`, `tasty-bench` in wall-clock time
  (`--time-mode wall`), run with `-j1` and `+RTS -M2G`. Each cell is that
  benchmark's mean, taken from the CSV.
- **Python:** CPython 3.14.6 with pydantic 2.13.4 and SQLite 3.53.4. Each
  cell is the best of 5 `timeit` repeats, each about half a second of
  passes.
- **Interleaving:** two rounds, run as Haskell, Python, then Python,
  Haskell. The table shows each side's better round.

| Operation (one pass) | Haskell | Python | Python / Haskell |
| --- | ---: | ---: | ---: |
| webhook ingest (100 deliveries) | 4.27 ms | 11.4 ms | 2.7× |
| reconciliation step (one webhook to quiescence) | 30.2 ms | 181 ms | 6.0× |
| gate classification (24 classifications) | 2.65 µs | 53 µs | 20× |
| timer rebuild (333-fact History) | 5.15 ms | 8.31 ms | 1.61× |
| fresh timer store open (no History) | 1.81 ms | 1.46 ms | 0.81× |

The other rounds: ingest 6.89 ms against 11.6 ms, reconciliation 44.8 ms
against 183 ms, classification 3.32 µs against 54 µs, rebuild 5.35 ms
against 8.45 ms, fresh open 2.01 ms against 1.52 ms. A third run, through
`scripts/bench hamsterdan-host` a few minutes later, gave ingest 6.75 ms
against 10.9 ms, reconciliation 32.6 ms against 173 ms, rebuild 4.90 ms
against 7.64 ms and fresh open 1.54 ms against 1.44 ms (0.94×).

**The fresh open is slower than Python in wall-clock time**: 0.81× on the
better rounds, 0.76× and 0.81× round by round. Almost all of that time is
spent in SQLite creating the file, switching to WAL, and running the schema
DDL, work that waits on the file system. The figures committed before these
timed Haskell in tasty-bench's default CPU time, which leaves that wait out:
1.59 ms then, against Python's 1.67 ms (1.05×). Whether the gap is the SQLite
build (direct-sqlite bundles 3.45.0, CPython links 3.53.4) or the binding's
own work has not been measured.

The CPU-time figures for the other rows were 4.42 ms (ingest), 40.9 ms
(reconciliation), 3.34 µs (classification) and 5.75 ms (rebuild). The
reconciliation row reads lower in wall-clock time: the threaded runtime's CPU
time adds up every OS thread of the process.

The timer rebuild row was once slower in Haskell: 13.5–14.7 ms against
Python's 8.6 ms. The cause was parsing every timestamp and generation digit
with `read`. Folding the digits instead fixed it, and the on-disk bytes
did not change.

In those earlier CPU-time rounds, Python's reconciliation row moved the most
between rounds: 177 ms, then 205 ms under higher load.

## Rerun

From the repository root (`scripts/bench hamsterdan-host` runs exactly this block;
`scripts/upstream-python hamsterdan` provisions the pinned reference). `--time-mode wall`
makes tasty-bench measure wall-clock time, like Python's `timeit`. The bench keeps its
scratch state in `$TMPDIR/hamsterdan-host-bench`, a fixed name, so the block gives each run
a private `TMPDIR`. With the shared one, the reconciliation row failed here with "the
dashboard was not posted", most likely because another checkout's run was using the same
directory; with a private `TMPDIR` it passed.

<!-- scripts/bench: rerun -->
```sh
export TMPDIR="$BENCH_TMP/tmp" && mkdir -p "$TMPDIR"
cabal bench -j2 hamsterdan-host --benchmark-options="-j1 --time-mode wall --csv $BENCH_TMP/hamsterdan-host.csv +RTS -M2G -RTS"
cat "$BENCH_TMP/hamsterdan-host.csv"
"$(scripts/upstream-python hamsterdan)" -I -B packages/hamsterdan-host/bench/bench.py
```

`cabal bench` runs in the package directory. Read the Haskell numbers from
the CSV, not from the console. The reconciliation row sends stdout to
`/dev/null` while it runs, so the console can show a row's name over its
neighbour's time. `bench.py` finds its inputs and doubles relative to
itself.

Run `make_inputs.py` with the same interpreter to regenerate `inputs.json`.
Note `uptime` before and after each run.
