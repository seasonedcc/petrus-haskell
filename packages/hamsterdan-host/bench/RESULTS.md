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

The machine was an Apple M4 (10 cores), macOS 26.3.1, shared with other
work. The load average was 5.3–5.8 during these runs (`uptime` after each
run).

- **Haskell:** GHC 9.10.3 with `-O2`, `tasty-bench`, run with `-j1` and
  `+RTS -M2G`, every row in wall-clock time (`localOption WallTime`), as
  `bench.py` measures. The reconciliation and agent rows wait on SQLite,
  the file system and git child processes, which tasty-bench's default CPU
  time does not count. Each cell is that benchmark's mean, taken from the
  CSV.
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

Haskell is faster on every row.

The other rounds were: Haskell 6.14 ms, 36.1 ms, 175 ms, 2.98 µs, 5.25 ms
and 1.73 ms; Python 23.5 ms, 185 ms, 349 ms, 56 µs, 8.86 ms and 1.68 ms.

The fresh open row is within noise: Haskell's slower round (1.73 ms) is
above Python's slower round (1.68 ms). Almost all of that time is spent in
SQLite creating the file, switching to WAL, and running the schema DDL.
That work is the same on both sides.

Earlier versions of this table took the Haskell side in tasty-bench's
default CPU time; the rows above are wall-clock time on both sides.

Both sides keep their scratch directory at its resolved path: the host
refuses a state root with a symbolic link among its ancestors (as the
reference does), and macOS's temporary directory is under `/var`, which is
a symbolic link.

The timer rebuild row was once slower in Haskell: 13.5–14.7 ms against
Python's 8.6 ms. The cause was parsing every timestamp and generation digit
with `read`. Folding the digits instead fixed it, and the on-disk bytes
did not change.

The webhook ingest row moved the most between rounds: 18.1 ms, then
23.5 ms in Python, and 5.31 ms, then 6.14 ms in Haskell.

## Rerun

From the repository root, alternating the two sides:

```sh
cabal bench hamsterdan-host -j2 --benchmark-options='-j1 --csv hs.csv +RTS -M2G -RTS'
upstream/hamsterdan/.venv/bin/python -I -B packages/hamsterdan-host/bench/bench.py
```

`cabal bench` runs in the package directory. Read the Haskell numbers from
`hs.csv`, not from the console. The reconciliation row sends stdout to
`/dev/null` while it runs, so the console can show a row's name over its
neighbour's time. `bench.py` finds its inputs and doubles relative to
itself.

Run `make_inputs.py` with the same interpreter to regenerate `inputs.json`.
Note `uptime` before and after each run.
