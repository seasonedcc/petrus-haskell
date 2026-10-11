# ZeroMQ Dispatch transport benchmarks: Haskell vs the Python reference

<!-- scripts/bench: measured sources 817e565ff26b9b4b at bd4a0085b979 -->

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
  The Haskell server's providers share one pool of Local Dispatch
  connections, which stays open until the server stops; the reference opens
  a connection per custody operation (see the notes).
- **local-held-open.** The same, while the bench process keeps a co-resident
  connection open on the dispatch file.
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

From the repository root (`scripts/bench petrus-motus-zeromq` runs exactly this;
`scripts/upstream-python` provisions the pinned reference):

<!-- scripts/bench: rerun -->
```sh
cabal bench -j2 petrus-motus-zeromq --benchmark-options '+RTS -M2G -RTS'
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-motus-zeromq/bench/python_bench.py)
```

CI's nightly smoke run (`scripts/bench --smoke`, not a measurement): the
Haskell harness once.

<!-- scripts/bench: smoke -->
```sh
cd packages/petrus-motus-zeromq && "$BENCH_BIN" +RTS -M2G -RTS
```

Both harnesses read the monotonic clock around each timed run, so both sides are wall-clock time.

The Haskell bench prints its rows to stdout. The Python script prints the
same rows to stderr, and `name,nanoseconds` lines to stdout for
`scripts/bench`; the Haskell bench writes the matching CSV when it is given
`--csv PATH`.

Every figure is the median of 10 timed runs after one warm-up run.

## Results

The runs took place on 2026-10-10 on an Apple M4 with 24 GB of memory:
- GHC 9.10.3 (`-O2`, `-A32m`), with libzmq 4.3.5 from Homebrew and
  direct-sqlite 2.3.29, which bundles SQLite 3.45.0;
- CPython 3.14.6, with pyzmq 27.1.0, whose bundled libzmq is also 4.3.5, and
  SQLite 3.53.4;
- the reference pinned at `upstream/petrus` 3f85fc2.

Three rounds ran interleaved: the Haskell bench before the changes below
(commit f80e0c3), the Haskell bench with them, then the reference, three
times over. Other work shared the machine, with a load average of 3.2–5.8.
Each figure is the median of a row's three rounds. The Python / Haskell
ratio is above 1 when Haskell is faster.

| workload | size | Haskell before | Haskell rounds (ms) | Python rounds (ms) | Haskell | Python | Python / Haskell before | Python / Haskell |
| --- | ---: | ---: | --- | --- | ---: | ---: | ---: | ---: |
| local/claim-empty-100 | 100 | 58.5 ms | 26.8, 21.9, 24.1 | 40.3, 36.2, 41.2 | 24.1 ms | 40.3 ms | 0.69× | 1.67× |
| local/roundtrip-20 | 20 | 60.3 ms | 26.1, 20.2, 22.4 | 41.5, 33.3, 35.6 | 22.4 ms | 35.6 ms | 0.59× | 1.59× |
| local-held-open/claim-empty-100 | 100 | 42.4 ms | 26.5, 22.2, 24.2 | 35.0, 36.8, 40.6 | 24.2 ms | 36.8 ms | 0.87× | 1.52× |
| local-held-open/roundtrip-20 | 20 | 36.7 ms | 24.3, 20.2, 22.5 | 39.8, 33.8, 35.2 | 22.5 ms | 35.2 ms | 0.96× | 1.57× |
| memory/claim-empty-100 | 100 | 23.6 ms | 33.2, 18.9, 20.4 | 20.2, 21.6, 23.1 | 20.4 ms | 21.6 ms | 0.91× | 1.06× |
| memory/custody-20 | 20 | 15.0 ms | 21.6, 11.9, 12.8 | 13.2, 13.7, 15.5 | 12.8 ms | 13.7 ms | 0.91× | 1.06× |
| memory/async-claim-empty-100-c1 | 100 | 23.6 ms | 29.1, 18.6, 19.7 | 30.2, 30.0, 34.4 | 19.7 ms | 30.2 ms | 1.28× | 1.53× |
| memory/async-claim-empty-100-c8 | 100 | 18.1 ms | 19.6, 13.5, 15.3 | 20.5, 20.7, 23.7 | 15.3 ms | 20.7 ms | 1.14× | 1.35× |

The first Haskell round of the memory rows ran during a load spike (load
average 4.3 rising to 4.5); the other two rounds were faster than every
Python round. An earlier set of three interleaved rounds, against a build
that differed only in schema initialization (which the memory rows do not
use), gave 1.09× for `memory/claim-empty-100` and 1.04× for
`memory/custody-20`.

## Notes

- **The local rows no longer pay SQLite's last-close checkpoint.** Before
  this change, the Haskell server's Local Dispatch closed every
  per-operation connection when the operation ended. Nothing else held the
  file open, so each close was the last one, and SQLite checkpointed the WAL
  and deleted it, at the cost of several fsyncs per request. The reference
  mostly escapes this because its read-only `with _connect(path)` blocks
  never close their connections, which linger until the cyclic garbage
  collector runs.

  The server's providers now share one `LocalConnections` pool
  (`Petrus.Sqlite.Pool`, up to four idle connections), which the server
  closes when it stops. Requests reuse open connections and their prepared
  statements, skipping the open, the four pragmas and the statement
  preparation as well as the checkpoint. This also closed the 4–8 % gap
  the empty Local claim used to show with a held-open file: it was the cost
  of opening and configuring a fresh connection. Rows, statements and
  `BEGIN IMMEDIATE` transactions are unchanged; see
  `packages/petrus-motus/DIVERGENCES.md` (15) and
  `packages/petrus-motus/bench/RESULTS.md`.
- **Request ids were slow to generate.** Every synchronous request carries
  a fresh uuid4 request id. The Haskell `uuid4` read its 16 random bytes by
  opening `/dev/urandom` each time, which cost about 26 µs per id, about a
  tenth of a request. It now calls `getentropy`, as Python's `os.urandom`
  does, at about 2.3 µs. That is what moved the synchronous memory rows from
  0.91× to 1.06×.
- **The transport is at parity.** The memory rows isolate the transport:
  every row is now at least as fast as the reference, and the native
  asynchronous access is 1.35–1.5× faster.

  A synchronous request costs about 200 µs on both sides. Most of that is
  setting up a fresh DEALER socket and connecting it with `ZMQ_IMMEDIATE`.
  The protocol requires this on every request: both clients discard the
  socket once it has answered, so a late reply can never be read as the
  answer to the next request.
