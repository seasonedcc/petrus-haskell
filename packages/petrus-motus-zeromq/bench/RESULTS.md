# ZeroMQ Dispatch transport benchmarks: Haskell vs the Python reference

`bench/Main.hs` and `bench/python_bench.py` time the same workloads. On each
side the client runs in the bench process and the server is a separate
process of the same implementation, reached over IPC:
- on the Haskell side, the bench executable re-executed as the server CLI or
  as the in-memory server;
- on the Python side, `python -m petrus.motus.transport.zeromq`, or the bench
  script itself as the in-memory server.

Both sides print the same row names and result sizes.

## Server set-ups

- **local.** The server CLI over a fresh Local SQLite Dispatch, as deployed.
  Every custody operation opens and closes its own SQLite connection.
- **local-held-open.** The same, while the bench process keeps a co-resident
  connection open on the dispatch file. This is the equal-IO comparison for
  SQLite; see the notes.
- **memory.** The server over in-memory custody, built through the private
  factory door (`fromFactory` / `ZeroMQDispatchServer._from_factory`). Only
  the transport remains: the per-request DEALER socket, the IPC hops, the
  framing, the canonical JSON, the request validation, and the routing. The
  Worker named `empty` never gets an Attempt; any other Worker always gets
  the same one.

## Workloads

- **claim-empty-100.** 100 sequential claims that find nothing, which
  measures request latency.
- **roundtrip-20.** Dispatch 20 occurrences, then claim, heartbeat and
  complete each one through the server, then collect.
- **custody-20.** 20 claim, heartbeat and complete cycles against in-memory
  custody.
- **async-claim-empty-100-c1 / -c8.** 100 empty claims spread over 1 or 8
  concurrent requesters. The requesters share one native asynchronous access
  with at most 8 sockets in flight. On the Haskell side the requesters are
  threads; on the Python side they are `asyncio` tasks.

## How to rerun

From the repository root:

    cabal bench petrus-motus-zeromq --benchmark-options '+RTS -M2G -RTS'

Python, from the pinned reference checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-motus-zeromq/bench/python_bench.py

The Haskell bench prints its rows to stdout. The Python script prints the
same rows to stderr, and `name,nanoseconds` lines to stdout for
`scripts/bench`; the Haskell bench writes the matching CSV when it is given
`--csv PATH`.

Every figure is the median of 10 timed runs after one warm-up run.

## Results

The runs took place on 2026-10-10 on an Apple M4 with 24 GB of memory:
- GHC 9.10.3 (`-O2`, `-A32m`), with libzmq 4.3.5 from Homebrew;
- CPython 3.14.6, with pyzmq 27.1.0, whose bundled libzmq is also 4.3.5;
- the reference pinned at `upstream/petrus` 3f85fc2.

Haskell and Python ran interleaved (H, P, H, P, H, P), with a load average
of 1.7–2.0 throughout. The table gives the median of each row's three
rounds. The Haskell / Python ratio is above 1 when Haskell is faster.

| workload | size | Haskell rounds (ms) | Python rounds (ms) | Haskell | Python | Python / Haskell |
| --- | ---: | --- | --- | ---: | ---: | ---: |
| local/claim-empty-100 | 100 | 54.4, 55.1, 54.6 | 35.6, 35.8, 36.0 | 54.6 ms | 35.8 ms | 0.66× |
| local/roundtrip-20 | 20 | 68.1, 57.1, 54.6 | 34.2, 32.5, 32.3 | 57.1 ms | 32.5 ms | 0.57× |
| local-held-open/claim-empty-100 | 100 | 42.3, 38.3, 38.5 | 35.8, 35.3, 36.2 | 38.5 ms | 35.8 ms | 0.93× |
| local-held-open/roundtrip-20 | 20 | 37.4, 32.5, 32.1 | 33.1, 34.1, 33.1 | 32.5 ms | 33.1 ms | 1.02× |
| memory/claim-empty-100 | 100 | 25.2, 21.5, 22.1 | 21.7, 21.6, 21.4 | 22.1 ms | 21.6 ms | 0.98× |
| memory/custody-20 | 20 | 16.4, 13.5, 14.3 | 14.4, 14.0, 14.4 | 14.3 ms | 14.4 ms | 1.01× |
| memory/async-claim-empty-100-c1 | 100 | 24.1, 24.1, 21.9 | 32.4, 31.4, 32.0 | 24.1 ms | 32.0 ms | 1.33× |
| memory/async-claim-empty-100-c8 | 100 | 18.0, 15.5, 15.9 | 22.8, 21.1, 22.7 | 15.9 ms | 22.7 ms | 1.43× |

A fourth interleaved round of the `local-held-open` rows ran at load
1.9–2.5:
- `claim-empty-100`: 39.0 and 40.3 ms in Haskell, against 36.4 and 36.2 ms
  in Python;
- `roundtrip-20`: 32.3 and 33.6 ms in Haskell, against 35.5 and 32.6 ms in
  Python.

## Notes

- **The transport is at parity.** The memory rows isolate the transport.
  The synchronous rows match within the run-to-run spread, which is ±10 % on
  the Haskell side and ±1 % on the Python side. The native asynchronous
  access is 1.3–1.4× faster.

  A synchronous request costs about 210 µs on both sides. Most of that is
  setting up a fresh DEALER socket and connecting it with `ZMQ_IMMEDIATE`.
  The protocol requires this on every request: both clients discard the
  socket once it has answered, so a late reply can never be read as the
  answer to the next request.
- **The local rows pay SQLite's last-close checkpoint.** In the `local` rows
  the Haskell server's Local Dispatch closes every per-operation connection
  when the operation ends. Nothing else holds the file open, so each close
  is the last one, and SQLite checkpoints the WAL and deletes it. That costs
  several fsyncs per request.

  The reference's read-only `with _connect(path)` blocks never close their
  connections. Those connections linger until the cyclic garbage collector
  runs, so the reference's closes are almost never the last one. This is the
  connection-lifetime difference described in
  `packages/petrus-motus/DIVERGENCES.md` (15) and
  `packages/petrus-motus/bench/RESULTS.md`. It is not a transport cost.

  Holding one co-resident connection open removes the difference. In the
  `local-held-open` rows `roundtrip-20` is at parity.
- **The empty Local claim is 4–8 % slower in the Haskell server.** The gap
  in `local-held-open/claim-empty-100` is in the server, not the client or
  the transport:
  - the memory rows show no gap in the transport;
  - with the reference's own Python client and a held-open file, a claim
    took a median of 369–370 µs against the Haskell server, and 352–358 µs
    against the reference's server (three runs of 300 claims each).

  An empty claim is one `BEGIN IMMEDIATE`, a lease-expiry sweep, one
  `SELECT` and a `COMMIT` with nothing to write. It runs on a freshly opened
  connection that first sets the reference's four pragmas. Both
  implementations do exactly this. The remaining difference is in opening
  and configuring that connection. The two sides link different SQLite
  builds: direct-sqlite bundles 3.45.0, while CPython links 3.53.4. This
  has not been isolated further.

  Claims that find work, in `roundtrip-20`, show no gap. The Local Dispatch
  bench also has the Haskell adapter 1.3–1.9× faster at equal IO.
