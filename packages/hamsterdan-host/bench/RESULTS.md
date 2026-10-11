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
- **Agent turn:** the same step with the agent `serve` composes in place of
  the clear-review runner: the Pi A2 installation from the environment,
  `agent-routes.sqlite3`, the workspace receiver, the owned Pi A2 runtime
  over Petrus's deterministic scripted Pi runtime, and the Pi native
  runner. The review is one scripted Pi turn over a clone of a local
  repository with fixed commits, and its route is claimed and settled.
  The composition is the state interop's (`Hamsterdan.Host.Scripted`, and
  `compose_real_agent` in `differential/state_reference.py`).
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

Five interleaved rounds on 2026-10-11, 03:40–03:45 local (UTC-3), on the
merge of `ee7e4a5` with `main` at `ab3544a` (the agent-turn row and the
HTTP layer's changes included), load average 3.6–6.5, on the same machine as
below:

    mkdir -p bench-results/tmp/htmp
    TMPDIR="$PWD/bench-results/tmp/htmp" scripts/bench-compare hamsterdan-host 5 --upstream hamsterdan

- **Haskell:** the tasty-bench mean in wall-clock time, as below.
- **Python:** `bench/python_bench.py` runs `bench.py`'s cases, timed by
  `scripts/bench_timing.py`: the median of 10 batches of at least 0.2 s.
  That is the twin protocol of the other packages. `bench.py`'s best of 5
  repeats, used in the earliest table below, takes Python's luckiest run
  against Haskell's mean.
- Each figure is the median of the five rounds. Rounds alternate which side
  goes first.

| Operation (one pass) | Haskell | Python | Python / Haskell | Lowest per round |
| --- | ---: | ---: | ---: | ---: |
| webhook ingest (100 deliveries) | 4.15 ms | 10.8 ms | 2.61× | 2.46× |
| reconciliation step (one webhook to quiescence) | 27.7 ms | 180 ms | 6.50× | 5.76× |
| agent turn (one webhook to quiescence through the scripted Pi agent) | 146 ms | 312 ms | 2.13× | 2.05× |
| gate classification (24 classifications) | 2.75 µs | 54.7 µs | 19.9× | 19.2× |
| timer rebuild (333-fact History) | 3.97 ms | 7.37 ms | 1.86× | 1.57× |
| fresh timer store open (no History) | 1.25 ms | 1.24 ms | 0.99× | 0.96× |

Fresh open, round by round (Haskell / Python): 1.32 / 1.38, 1.25 / 1.26,
1.26 / 1.21, 1.20 / 1.24 and 1.24 / 1.22 ms. Haskell was ahead in three
rounds and behind in two.

**The fresh open is level with Python, at 0.99×, and so still not faster.**
In the twin-protocol rounds of 02:10–02:20 (below) it was 0.95×. What was
measured:

- **The SQLite work is level.** A probe ran the open's statements one by
  one with direct-sqlite: connect, `busy_timeout`, WAL, `foreign_keys`, the
  schema script, the meta row, the rebuild transaction, the three
  validating queries, close and unlink. The same statements through
  CPython's `sqlite3` alternated with it. Over three alternations of 200
  opens each, Haskell's medians were 1.23–1.39 ms and Python's 1.32–1.44 ms.
- **The store adds little to it.** `openTimerStore` and `close` timed
  directly, outside tasty-bench, came to medians of 1.34–1.41 ms, with a
  mean of 1.43 ms against a median of 1.35 ms over 300 opens.
- **Neither SQLite build nor durability differs.** Both sides use SQLite's
  defaults for the timer store (`synchronous` FULL, WAL, plain `fsync`).
  The bundled 3.45.0 and the system SQLite performed alike in the probe.

So the remaining gap lies between that floor and the benchmark's
measurement. The Haskell benchmark runs with the webhook-ingest host open
in the same process, and the row is a mean over a skewed, fsync-bound
distribution. A switch that closed the ingest host first was tried, but
the machine's load swamped the difference (1.52–3.06 ms either way), so it
was not kept. The row stays below 1.0× until a quieter run settles it.

### Earlier twin-protocol rounds (2026-10-11, 02:10–02:20)

<!-- bench: superseded -->

Five interleaved rounds at commit `3f31d2e`, before the merge with `main`
(no agent-turn row, the earlier HTTP layer), load average 4.6–6.2, medians
of the rounds:

| Operation (one pass) | Haskell | Python | Python / Haskell |
| --- | ---: | ---: | ---: |
| webhook ingest (100 deliveries) | 9.31 ms | 13.5 ms | 1.45× |
| reconciliation step (one webhook to quiescence) | 55.4 ms | 202 ms | 3.65× |
| gate classification (24 classifications) | 3.03 µs | 58.3 µs | 19.2× |
| timer rebuild (333-fact History) | 4.90 ms | 8.92 ms | 1.82× |
| fresh timer store open (no History) | 1.61 ms | 1.54 ms | 0.95× |

Fresh open, round by round (Haskell / Python): 1.48 / 1.43, 3.08 / 1.32,
2.44 / 1.56, 1.61 / 1.54 and 1.48 / 1.54 ms.

### Earlier results, best-of-5 protocol (2026-10-11, 00:16–00:17)

<!-- bench: superseded -->

The machine was an Apple M4 (10 cores), macOS 26.3.1, shared with other
work. The load average was 5.3–5.8 during these runs (2026-10-11,
00:16–00:17 local, UTC-3; `uptime` after each run).

- **Haskell:** GHC 9.10.3 with `-O2`, `tasty-bench`, every row in
  wall-clock time (`localOption WallTime` in the benchmark, the same as
  `--time-mode wall`), run with `-j1` and `+RTS -M2G`. Each cell is that
  benchmark's mean, taken from the CSV.
- **Python:** CPython 3.14.6 with pydantic 2.13.4 and SQLite 3.53.4. Each
  cell is the best of 5 `timeit` repeats, each about half a second of
  passes.
- **Interleaving:** two rounds, run as Haskell, Python, then Python,
  Haskell. The table shows each side's better round.

| Operation (one pass) | Haskell | Python | Python / Haskell |
| --- | ---: | ---: | ---: |
| webhook ingest (100 deliveries) | 5.31 ms | 18.1 ms | 3.4× |
| reconciliation step (one webhook to quiescence) | 36.1 ms | 184 ms | 5.1× |
| agent turn (one webhook to quiescence through the scripted Pi agent) | 175 ms | 348 ms | 2.0× |
| gate classification (24 classifications) | 2.92 µs | 56 µs | 19× |
| timer rebuild (333-fact History) | 4.58 ms | 8.54 ms | 1.86× |
| fresh timer store open (no History) | 1.51 ms | 1.63 ms | 1.08× |

The other rounds were: Haskell 6.14 ms, 36.1 ms, 175 ms, 2.98 µs, 5.25 ms
and 1.73 ms; Python 23.5 ms, 185 ms, 349 ms, 56 µs, 8.86 ms and 1.68 ms.

**The fresh open is not reliably faster than Python.** In these rounds it
was 1.08× and 0.97×. In the wall-clock rounds of 2026-10-10 (commit
`aaafd62`, load 4.0–4.3) it was 0.81× on the better rounds (Haskell
1.81 ms against Python 1.46 ms; 2.01 ms against 1.52 ms in the other round),
and 0.94× in a third run through `scripts/bench`. Almost all of that time
is spent in SQLite creating the file, switching to WAL, and running the
schema DDL, which waits on the file system. Whether the gap is the SQLite
build (direct-sqlite bundles 3.45.0, CPython links 3.53.4) or the binding's
own work has not been measured. The row belongs to the "V5 timers"
component, which stays in progress until it is settled.

The other rows of those 2026-10-10 rounds were: ingest 4.27 ms against
11.4 ms (2.7×), reconciliation 30.2 ms against 181 ms (6.0×),
classification 2.65 µs against 53 µs (20×), and rebuild 5.15 ms against
8.31 ms (1.61×). The agent turn row did not exist yet.

The figures committed before those timed Haskell in tasty-bench's default
CPU time, which leaves out the time spent waiting on the file system: for
example 1.59 ms for the fresh open, and 40.9 ms for the reconciliation step,
which reads lower in wall-clock time because the threaded runtime's CPU
time adds up every OS thread of the process.

The timer rebuild row was once slower in Haskell: 13.5–14.7 ms against
Python's 8.6 ms. The cause was parsing every timestamp and generation digit
with `read`. Folding the digits instead fixed it, and the on-disk bytes
did not change.

## Rerun

From the repository root (`scripts/bench hamsterdan-host` runs exactly this
block; `scripts/upstream-python hamsterdan` provisions the pinned
reference). `--time-mode wall` makes tasty-bench measure wall-clock time,
like Python's `timeit`; the benchmark also sets it for every row.

Both sides keep their scratch state at its resolved path. The host refuses
a state root with a symbolic link among its ancestors, as the reference
does, and macOS's default temporary directory is under `/var`, which is a
symbolic link to `/private/var`. That refusal, not a clash with another
checkout, is why the reconciliation row once failed with "the dashboard was
not posted" under the shared `TMPDIR`. The block still gives each run a
private `TMPDIR`, because the Haskell scratch directory has a fixed name.

<!-- scripts/bench: rerun -->
```sh
export TMPDIR="$BENCH_TMP/tmp" && mkdir -p "$TMPDIR"
cabal bench -j2 hamsterdan-host --benchmark-options="-j1 --time-mode wall --csv $BENCH_TMP/hamsterdan-host.csv +RTS -M2G -RTS"
cat "$BENCH_TMP/hamsterdan-host.csv"
"$(scripts/upstream-python hamsterdan)" -I -B packages/hamsterdan-host/bench/bench.py
```

`cabal bench` runs in the package directory. Read the Haskell numbers from
the CSV, not from the console. The reconciliation and agent rows send
stdout to `/dev/null` while they run, so the console can show a row's name
over its neighbour's time. `bench.py` finds its inputs and doubles relative
to itself.

Run `make_inputs.py` with the same interpreter to regenerate `inputs.json`.
Note `uptime` before and after each run.
