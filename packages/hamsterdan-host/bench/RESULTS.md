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

The machine was an Apple M4 (10 cores), macOS 26.3.1, shared with other
work. The load average was 4.2–9.3 during these runs (`uptime` before and
after each run).

- **Haskell:** GHC 9.10.3 with `-O2`, `tasty-bench`, run with `-j1` and
  `+RTS -M2G`. Each cell is that benchmark's mean, taken from the CSV.
- **Python:** CPython 3.14.6 with pydantic 2.13.4 and SQLite 3.53.4. Each
  cell is the best of 5 `timeit` repeats, each about half a second of
  passes.
- **Interleaving:** two rounds, run as Haskell, Python, then Python,
  Haskell. The table shows each side's better round.

| Operation (one pass) | Haskell | Python | Python / Haskell |
| --- | ---: | ---: | ---: |
| webhook ingest (100 deliveries) | 4.42 ms | 11.4 ms | 2.6× |
| reconciliation step (one webhook to quiescence) | 40.9 ms | 177 ms | 4.3× |
| gate classification (24 classifications) | 3.34 µs | 53 µs | 15.9× |
| timer rebuild (333-fact History) | 5.75 ms | 7.98 ms | 1.39× |
| fresh timer store open (no History) | 1.59 ms | 1.67 ms | 1.05× |

Haskell is faster on every row.

The fresh open row is within noise. Across the two rounds, Haskell measured
1.59 and 1.97 ms, and Python measured 1.67 and 1.86 ms, so the order flipped
in round 2. Almost all of that time is spent in SQLite creating the file,
switching to WAL, and running the schema DDL. That work is the same on both
sides.

The timer rebuild row was once slower in Haskell: 13.5–14.7 ms against
Python's 8.6 ms. The cause was parsing every timestamp and generation digit
with `read`. Folding the digits instead fixed it, and the on-disk bytes
did not change.

Python's reconciliation row moved the most between rounds: 177 ms, then
205 ms under higher load. Haskell's moved from 40.9 to 41.4 ms.

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
