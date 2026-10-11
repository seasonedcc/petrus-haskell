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

Seven interleaved repetitions on 2026-10-11, 06:14–06:26 local (UTC-3), at
commit `8024875` (a fresh timer store's schema in one transaction, below),
load average 1.96–3.91, on the same machine as below:

    mkdir -p bench-results/tmp/htmp
    TMPDIR="$PWD/bench-results/tmp/htmp" scripts/bench-compare hamsterdan-host 7 --upstream hamsterdan

- **Haskell:** the tasty-bench mean in wall-clock time (`--stdev 5`,
  `+RTS -M2G`). scripts/bench-compare now builds the benchmark once and runs
  its executable directly, in the package directory with the variables
  `cabal bench` sets, as it runs the Python twin; under `cabal bench` the
  benchmark had cabal as its parent process, which the twin does not.
- **Python:** `bench/python_bench.py` runs `bench.py`'s cases, timed by
  `scripts/bench_timing.py`: the median of 10 batches of at least 0.2 s.
  That is the twin protocol of the other packages. `bench.py`'s best of 5
  repeats, used in the earliest table below, takes Python's luckiest run
  against Haskell's mean.
- Each figure is the median of the seven repetitions. Repetitions alternate
  which side goes first.

| Operation (one pass) | Haskell | Python | Python / Haskell | Lowest per repetition |
| --- | ---: | ---: | ---: | ---: |
| webhook ingest (100 deliveries) | 4.20 ms | 10.8 ms | 2.57× | 0.97× |
| reconciliation step (one webhook to quiescence) | 28.3 ms | 176 ms | 6.23× | 3.35× |
| agent turn (one webhook to quiescence through the scripted Pi agent) | 147 ms | 317 ms | 2.15× | 1.94× |
| gate classification (24 classifications) | 2.69 µs | 55.4 µs | 20.6× | 20.2× |
| timer rebuild (333-fact History) | 3.73 ms | 7.52 ms | 2.01× | 1.76× |
| fresh timer store open (no History) | 943 µs | 1.40 ms | 1.49× | 1.01× |

Fresh open, repetition by repetition (Haskell / Python): 1.01 / 1.43,
0.94 / 1.33, 1.30 / 2.10, 1.43 / 1.44, 0.89 / 1.40, 0.93 / 1.40 and
0.93 / 1.35 ms. Haskell was ahead in all seven. The lowest ratios of the
first three rows come from repetitions 3–5, when the load average rose to
3.6–3.9: the Haskell ingest row read 8.5–11.4 ms there against 4.1–4.2 ms
in the other four, and the reconciliation row 52.7 ms once.

### The fresh open: six fsyncs fewer

The row was level with Python before this change: 1.00× (1.41 ms against
1.41 ms) over seven repetitions at 05:49–06:00, load 3.08–5.20, with
Haskell ahead in three, behind in three and tied in one. What was
measured, with the harnesses doing the same work (the same open, close and
removal of the three files, in the same scratch directory):

- **The system calls were the same.** A libc interposer counted, per open,
  6 `open`s, 15 `fsync`s, 65 `pwrite`s, about 91 `fcntl`s and 18 `pread`s
  on both sides. The only difference was the benchmark's own cleanup:
  `removePathForcibly` makes an `lstat` and one `unlink` where Python makes
  three `unlink`s. The time inside those calls came to about 1.0 ms of the
  1.3 ms open on both sides.
- **The rest is SQLite on both sides.** macOS's `sample` over the
  benchmark put 87% of the busy thread in the kernel and 8% in SQLite on
  both sides; the Haskell code itself (RTS included) was 2%, as was the
  interpreter's on the Python side.
- **The cost was the commits.** The reference's `_create_schema` runs
  `executescript` on an autocommit connection: each of its six `CREATE`
  statements commits on its own, and the meta row once more, each commit
  writing WAL frames and fsyncing the WAL. The port did the same.

`createSchema` now runs the same statements in one transaction: 9 fsyncs
and 51 `pwrite`s per open instead of 15 and 65, and the row dropped from
about 1.3 ms to 0.93 ms. The closed file holds the same bytes as before and
as the reference's: `TimersSpec` compares a fresh store with one the
reference writes, byte for byte, except offsets 96–99, the
`SQLITE_VERSION_NUMBER` of the library that wrote it (direct-sqlite bundles
3.45.0, CPython links 3.53.4). A crash during the schema leaves a store the
next open quarantines either way. See DIVERGENCES.md. The timer rebuild row
opens a fresh store too, and gained as much (4.33 ms before, 3.73 ms now).

The row's earlier swings (2–3 ms Haskell means in some rounds) came from
the machine's load, not from the benchmark's context: on a quiet machine
the row read the same alone and after every other row (1.26–1.35 ms before
the change), and tasty-bench at `--stdev 2` agreed with `--stdev 5`.

### Rounds before the schema transaction (2026-10-11, 05:49–06:00)

<!-- bench: superseded -->

Seven interleaved repetitions at commit `5c8bb93`, load average
3.08–5.20, medians of the repetitions:

| Operation (one pass) | Haskell | Python | Python / Haskell | Lowest per repetition |
| --- | ---: | ---: | ---: | ---: |
| webhook ingest (100 deliveries) | 4.51 ms | 11.2 ms | 2.48× | 1.12× |
| reconciliation step (one webhook to quiescence) | 31.5 ms | 185 ms | 5.87× | 5.53× |
| agent turn (one webhook to quiescence through the scripted Pi agent) | 163 ms | 336 ms | 2.06× | 1.99× |
| gate classification (24 classifications) | 2.81 µs | 55.9 µs | 19.9× | 19.4× |
| timer rebuild (333-fact History) | 4.33 ms | 8.03 ms | 1.85× | 1.75× |
| fresh timer store open (no History) | 1.41 ms | 1.41 ms | 1.00× | 0.90× |

### Rounds of 2026-10-11, 03:40–03:45

<!-- bench: superseded -->

The analysis after the table is the one written at the time.

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
