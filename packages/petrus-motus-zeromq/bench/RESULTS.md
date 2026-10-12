# ZeroMQ Dispatch transport benchmarks: Haskell vs the Python reference

<!-- scripts/bench: measured sources 5a8bc7c24f29bda6 at 5a73d7a7f019 -->

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
scripts/bench-run petrus-motus-zeromq +RTS -M2G -RTS
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

## Current figures

Measured on 2026-10-12, 05:21 local (UTC-3), at commit `fc3e42b` with
the `zmq_poll` wait described below, on the Apple M4 (Darwin arm64) with a
1-minute load average of 2.40–2.45: three interleaved repetitions,
alternating which side goes first, of

    scripts/bench-compare petrus-motus-zeromq 3

Haskell figures are the bench's own medians of 10 timed runs, run directly
in the package directory with `+RTS -M2G`; Python figures are the twin's
own timing (CPython 3.14.6). Each figure is the median over the
repetitions, and the ratio is Python ÷ Haskell (above 1 means Haskell is
faster). Haskell is faster on every row, in every repetition: the
synchronous memory rows (the transport alone) by 1.09× and 1.17×, the
native asynchronous access by 1.60× and 2.01×, and the Local-backed rows by
1.64–1.77×.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `zeromq/local/claim-empty-100` | 21.1 ms | 34.7 ms | 1.64× | 1.64× | 20.9 ms, 21.1 ms, 21.1 ms | 34.6 ms, 34.8 ms, 34.7 ms |
| `zeromq/local/roundtrip-20` | 18 ms | 31.3 ms | 1.73× | 1.69× | 17.9 ms, 18 ms, 18.5 ms | 31.1 ms, 31.5 ms, 31.3 ms |
| `zeromq/local-held-open/claim-empty-100` | 20.8 ms | 34.6 ms | 1.67× | 1.65× | 20.8 ms, 20.4 ms, 20.8 ms | 34.8 ms, 34.6 ms, 34.3 ms |
| `zeromq/local-held-open/roundtrip-20` | 17.8 ms | 31.6 ms | 1.77× | 1.76× | 17.6 ms, 18 ms, 17.8 ms | 31.8 ms, 31.6 ms, 31.5 ms |
| `zeromq/memory/claim-empty-100` | 19.3 ms | 21.1 ms | 1.09× | 1.07× | 19.6 ms, 19.3 ms, 19.3 ms | 21.1 ms, 21.2 ms, 20.9 ms |
| `zeromq/memory/custody-20` | 12 ms | 14.1 ms | 1.17× | 1.14× | 12.3 ms, 12 ms, 12 ms | 14.1 ms, 14.1 ms, 13.9 ms |
| `zeromq/memory/async-claim-empty-100-c1` | 19.6 ms | 31.3 ms | 1.60× | 1.59× | 19.7 ms, 19.4 ms, 19.6 ms | 31.3 ms, 31.4 ms, 31.3 ms |
| `zeromq/memory/async-claim-empty-100-c8` | 10.9 ms | 22 ms | 2.01× | 1.99× | 11 ms, 10.8 ms, 10.9 ms | 21.9 ms, 22.1 ms, 22 ms |

**The socket waits now poll in libzmq.** The binding waits for a socket
with an interruptible `zmq_poll` on the calling OS thread, as pyzmq's
blocking receive waits inside libzmq, instead of through the GHC IO
manager on the socket's `ZMQ_FD`. Each wake through the IO manager costs
an event-manager hand-off, and each `System.Timeout.timeout` a
timer-manager registration; on the Linux CI runners that was enough to put
a request round trip behind pyzmq's. The bench-gate figures (Python ÷
Haskell, Blacksmith 8-vCPU Ubuntu 24.04 runners):

| Run | Wait | `memory/claim-empty-100` | `memory/custody-20` |
|---|---|---:|---:|
| 38202655016, job 114660170314 (`81bbdc5`) | IO manager | 0.90× (rerun 0.95×): FAIL | 0.98× (rerun 0.98×): FAIL |
| 38206418285, job 114671152637 | `zmq_poll` | 1.19× | 1.36× |
| 38206418285, job 114671152691 | `zmq_poll` | 1.18× | 1.27× |
| 38255030541, job 114832832210 (`d869f62`) | `zmq_poll` | 1.11× | 1.28× |

On macOS the IO-manager wait already cleared every row, so the poll is
kept for Linux. A run of the rows above earlier the same night with the
IO-manager wait (load 3.22–3.46) read, in the table's order, 1.60×,
1.61×, 1.60×, 1.66×, 1.14×, 1.21×, 1.71× and 1.71×: on macOS the change
moves the rows by a few per cent either way, and the eight-way
asynchronous row gains most (12.9 ms to 10.9 ms).

**Each poll is bounded at 50 ms.** An asynchronous exception interrupts
the foreign call with a signal, but `zmq_poll` handles libzmq commands
(peers' pipes ending, say) in user space between its `poll()` calls, and a
signal that lands there is lost. An unbounded poll then held the exception
until a message arrived: stopping a CURVE server while its clients were
connected could hang in the ZAP handler's cancel, and the confirmation
audit's reproduction lost 44 of 47 such cancels. The wait now polls at most
50 ms at a time and loops until its deadline, so a lost interrupt only
delays the exception (0 of 200 lost); the transport tests stop a CURVE
server with clients connected and cancel a receive while peers come and
go. The bound costs nothing measurable: four interleaved runs of the memory
rows on the M4 (load 1.9–2.5), unbounded against bounded, medians of the
bench's own medians:

| Benchmark | Unbounded poll | Bounded at 50 ms |
|---|---:|---:|
| `zeromq/memory/claim-empty-100` | 19.1 ms | 19.4 ms |
| `zeromq/memory/custody-20` | 12.0 ms | 12.1 ms |
| `zeromq/memory/async-claim-empty-100-c1` | 18.9 ms | 19.6 ms |
| `zeromq/memory/async-claim-empty-100-c8` | 11.5 ms | 11.2 ms |

The differences are within the spread between repetitions (for example
async-claim-empty-100-c1: 18.3–19.3 ms unbounded, 19.3–19.9 ms bounded;
async-claim-empty-100-c8 moves the other way), as expected: the two waits
differ only when a single wait lasts more than 50 ms.

## Results

<!-- bench: superseded -->

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
