# Pi runtime benchmark results

<!-- scripts/bench: measured sources baf81cf78b32471f at f12e7471cb61 -->

These are twin workloads, run by the tasty-bench runner `bench/Main.hs`
and by scripts against the pinned reference (`upstream/petrus` @ 3f85fc2):

- `bench/PiBench.hs` and `bench/python_pi.py` cover the native runtime;
- `bench/PiA2Bench.hs` and `bench/python_pi_a2.py` cover the A2 host.

- `pi-start-frame-encode` encodes the resumed, all-tools api-key `start`
  frame to its wire bytes (`_SubprocessClient._write`). The frame is the
  second `frames.starts` case of `differential/pi_corpus.json`: 1,594 bytes
  with five tool schemas and a base64 session.
- `pi-tool-call-decode` decodes one `tool_call` frame line through the frame
  reader's strict loader (`_strict_load`; in the port, `strictFrameLoad`).
- `pi-session-validate` runs `_validate_session` over a version-3 header and
  199 message entries (about 25 KB).
- `pi-fingerprint` runs `pi_durable_work_fingerprint`.
- `pi-ledger-cycle` takes one durable operation through a
  `SqlitePiOperationLedger`: `admit`, `settle`, `upgrade_cleanup`,
  `acknowledge`, then `lookup`. One ledger serves the whole benchmark, and
  each iteration uses a fresh operation id. Both sides time it with the
  Python script's protocol (`bench/Twin.hs`), as explained below the
  table.
- `pi-a2-fingerprint` runs `_pi_a2_durable_fingerprint` over an all-tools
  policy with one writable path and a fixed inner fingerprint.
- `pi-a2-scripted-turn` takes one scripted operation through one host:
  `start` with a fresh operation id (admission, a Local territory, the
  Episode Attachment and the grant), `wait` (the body commit, the ledger
  settlement and publication), then `close`. The script interpreter makes no
  Hands calls. Both sides use the same reversible stand-in keys, so the
  cipher is not measured. Authority is supplied once, on the first
  iteration.

## Results

Environment:

- Apple M4, macOS (Darwin 25.3), APFS, 2026-10-10.
- GHC 9.10.3. The benchmark is built with `-O2` and run with
  `+RTS -A32m -M2G`.
- CPython 3.14.6.

Method: five interleaved rounds. Each round ran the Haskell bench, then
`python_pi.py` and `python_pi_a2.py`, so both saw the same machine state.
The table gives the median of the five rounds. The machine was shared with
other work (load average 3.7 to 5.8). The `pi-ledger-cycle` row comes from a
later wall-clock run, described below the table.

- A Haskell value is a tasty-bench mean (`--stdev 3`), except for
  `pi-a2-scripted-turn` and `pi-ledger-cycle`.
- A Python value is the script's median of 7 batches.
- `pi-a2-scripted-turn` is timed on both sides with the Python script's
  protocol: one warm-up turn, then 7 batches of 20 turns, and the median
  batch's time per turn. Each turn adds to the host's ledgers, so a turn
  costs more the more turns came before it, in both implementations.
  tasty-bench doubles its iteration count until the estimate settles, so on
  this workload it measured turns from much fuller ledgers than the twin
  did. `bench/PiA2Bench.hs` explains this in more detail.

| Benchmark | Haskell | Python | Python / Haskell | Slowest round |
| --- | ---: | ---: | ---: | ---: |
| pi-start-frame-encode | 3.24 µs | 7.80 µs | 2.4× | 2.3× |
| pi-tool-call-decode | 377 ns | 1.87 µs | 5.0× | 4.4× |
| pi-session-validate | 168 µs | 460 µs | 2.7× | 2.5× |
| pi-fingerprint | 2.32 µs | 6.46 µs | 2.8× | 2.6× |
| pi-ledger-cycle | 911 µs | 928 µs | 1.02× | 0.88× |
| pi-a2-fingerprint | 2.49 µs | 6.25 µs | 2.5× | 2.5× |
| pi-a2-scripted-turn | 10.4 ms | 29.2 ms | 2.8× | 2.7× |

"Slowest round" is the lowest Python / Haskell ratio of a single round.

**`pi-ledger-cycle` runs level with Python, at 1.02×.** The cycle is
bound by the file system: per cycle, Haskell spent about 78 µs of user CPU
and 605 µs of system CPU, Python about 160 µs and 660 µs. The system time
is the four commits' fsyncs (`synchronous = FULL`), the same on both sides,
so the port's smaller CPU share can only move the ratio a little.

Its row comes from 15 interleaved rounds on 2026-10-11 at 10:56–10:58 local
(UTC-3), load average 5.1 to 7.2. The rounds alternated which side went
first. Both sides used the Python script's protocol: one warm-up cycle,
then 7 batches of 200 cycles, and the median batch's time per cycle. The
table gives the median over the rounds. Haskell took 826, 816, 878, 911,
890, 796, 946, 978, 998, 937, 934, 948, 1026, 852 and 794 µs; Python took
931, 891, 1004, 953, 887, 877, 834, 1072, 979, 878, 1008, 863, 1032, 855
and 928 µs. Haskell was ahead in 10 of the 15 rounds; the per-round ratio
ranged from 0.88× to 1.17×.

The row used to be a tasty-bench mean, and that compared unlike things on
this workload. A tasty-bench run lasts 4 to 60 s and reports a mean, so one
of the file system's slow periods moves it. The twin measures for about
1.4 s and reports a median. In an 11-round run at 10:19–10:27 with the
tasty-bench row, the Haskell mean was 0.88–0.93 ms in the first three
rounds and 1.3–1.8 ms in the last eight, while the Python twin measured
0.83–0.98 ms in all but one of those rounds, giving 0.62×. Timing both
sides alike removes that difference.

The earlier figure was 1.08×, from five wall-clock rounds on 2026-10-11 at
01:50–02:05 local with the tasty-bench row. Before the statement cache below,
the row was 0.84× (Haskell 1.07, 1.07 and 0.934 ms
against Python 1.05, 0.869 and 0.902 ms, three wall-clock rounds on
2026-10-10). The cause was the port's ledger, not SQLite:

- `SqlitePiOperationLedger` prepared, ran and finalized every statement on
  every call. That means four write transactions and a read per cycle, each
  re-parsing its `BEGIN IMMEDIATE`, DML, `COMMIT` and `SELECT`.
- CPython's `sqlite3` keeps a per-connection statement cache, so the
  reference parses each of those strings once.

The ledger now keeps its prepared statements in a per-ledger cache. They are
reset after each use and finalized when the ledger closes, as CPython's
cache does. That saved about 100 µs per cycle. The SQL, the transactions and
the durability are unchanged: `journal_mode = DELETE` and `synchronous = FULL`
on both sides. The SQLite builds differ (direct-sqlite bundles 3.45.0,
CPython links 3.53.4). A probe of 2 000 single-insert fsynced commits (WAL,
the History store's posture) showed no difference beyond noise between
them. It ran on the bundled build, on the
system SQLite through direct-sqlite's `systemlib` flag, and on CPython.

The other rows do no IO in the timed region, so the
two clocks agree on them, except `pi-a2-scripted-turn`, which both sides time
with the monotonic clock. The 1.08× run's figures for them agree with the
table: frame encoding 2.33×, tool-call decoding 4.28×, session validation
2.54×, fingerprint 2.60×.

Haskell was faster in every round of every other row. The batches of the scripted
turn ranged from 7.3 to 15.0 ms across the five rounds.

Before these changes, the committed figures were 0.5× for frame encoding,
0.9× and 0.8× for the fingerprints, 1.0× for session validation and 0.5×
(55 ms ± 61 ms) for the scripted turn.

Notes on the results:

- **Frame encoding** and **both fingerprints** are `petrus-json`'s `dumps`.
  The fingerprints add SHA-256 over those bytes. The encoder now writes
  in one pass into a growing buffer (no `Builder`, no lazy intermediate),
  and copies a string that needs no escaping with one `memcpy`. A
  fingerprint's hex digest comes from `memory`'s base-16 encoder rather
  than `show` of the digest. The bytes are unchanged.
- **Session validation** first runs `petrus-json`'s strict parser
  (duplicate members and non-finite constants refused). Whatever that
  parser accepts, the CPython-faithful scanner in
  `Petrus.Json.Python.Scanner` accepts as the same value. The two
  differ only on lone surrogate escapes, a UTF-8 BOM and very deep nesting,
  which the strict parser refuses. Those inputs, and every refused input,
  still go through the scanner, so the outcome is the reference's.
- **The ledger cycle** is four SQLite write transactions plus one read, each
  committed with the journal in `delete` mode. File-system work dominates it
  in both languages. Its statements come from a per-ledger cache, as in
  CPython (see above).
- **The scripted A2 turn** is mostly Local territory work:
  - creating the lease directory;
  - extracting and exporting the archive through `/bin/sh` commands;
  - destroying the lease.

  On top of that come three SQLite databases written with
  `synchronous = FULL`. The wide spread of the earlier figure had two
  causes:
  - tasty-bench's iteration doubling over a workload whose cost grows per
    turn (see the method above);
  - CPython's exit-polling back-off (0.5 ms doubling to 50 ms), which the
    port copied. With it, a command that ended just after a poll cost up to
    one 50 ms step.

  `petrus-execution` now blocks on the child's exit instead (a watcher
  thread in `waitid(..., WNOWAIT)`; see its DIVERGENCES.md). Timeouts,
  cancellation and the process-group kill are unchanged.

## Whole Pi Turns

These rows take one whole Turn through each Pi adapter. The twins are
`bench/PiTurnsBench.hs` and `bench/python_bench.py`, which drives the
reference's own adapters. Both sides run the reference tests' fake Pi SDKs
(`test/fixtures/pi`) under the system `node`, with the runtime's own
`.mjs` helpers, and the reference tests' fake custody (one READ lease per
Turn). Each call uses a fresh operation id. The adapters' installation is
assigned as the reference's tests assign it, so the helpers run for real
but no installed SDK is probed.

- `pi-native-turn`: the native A2 adapter. Open a Local Motus territory,
  its Episode Attachment, the Hands gateway and a grant, then `start`
  (custody materialization; `pi_helper.mjs` over `framed_tool_sdk.mjs`:
  one `workspace_read` through the gateway, the session file and the
  candidate), `wait` (session validation, admission, the Continuation and
  Turn stores), `close`, and settle the attachment.
- `pi-a5-turn`: the A5 application adapter on a `gondolin` territory (a
  Local Motus provider whose leases report `gondolin`, as in the
  reference's tests): `pi_application_helper.mjs` over the fake
  `application_coding.mjs`, `application_core_projection.mjs` and
  `application_ai.mjs`, one `workspace_read` through the gateway, then
  `wait`, `close` and settle.
- `pi-model-phase-turn`: one model-phase Activity call: custody
  materialization, `pi_model_phase_helper.mjs` over the fake
  `model_phase_coding.mjs` (one public stream, five tool declarations),
  candidate validation, admission, release and publication.

Method: nine interleaved rounds on 2026-10-11 at 12:21–12:33 local
(UTC-3), load average 2.7 to 5.7, together with the hosts' whole Turns
([results-hosts.md](results-hosts.md) has the method). Haskell values are
tasty-bench wall-clock means (`--stdev 5`); Python values are
`scripts/bench_timing.py` medians of 10 batches of at least 0.2 s. The
table gives the medians over the rounds and the lowest single-round ratio.
Haskell was ahead in every round of every row.

| Benchmark | Haskell | Python | Python / Haskell | Slowest round |
| --- | ---: | ---: | ---: | ---: |
| pi-native-turn | 41.2 ms | 47.2 ms | 1.15× | 1.13× |
| pi-a5-turn | 39.7 ms | 46.1 ms | 1.16× | 1.13× |
| pi-model-phase-turn | 28.0 ms | 29.4 ms | 1.05× | 1.02× |

Most of each Turn is the `node` helper: its start-up, its import of the
fake SDK modules, and its exit. That is the same process on both sides, so
the ratios stay close to 1.

**What it took: starting the helper with `posix_spawn`.** These rows first
measured about three times slower than the reference. The port started its
helpers through the `process` package with `close_fds = True`, and that
package falls back to `fork` and closes every descriptor up to
`RLIMIT_NOFILE`: about 0.1 s per spawn at macOS's 1 048 576. CPython closes
only the open ones. Helpers and sidecars now start through
`Petrus.Agenticus.Runtime.Pi.spawnPiped`, which uses petrus-execution's
`posix_spawn`, with non-blocking pipe ends as the `process` package makes
them (see DIVERGENCES.md).

An earlier series of nine rounds (11:29–11:53, load average 3.9 to 12.8)
ran before the pipe ends were non-blocking, at `--stdev 3`. It measured
1.28× (`pi-native-turn`), 1.29× (`pi-a5-turn`) and 1.13×
(`pi-model-phase-turn`). In its two rounds at load 12.8, Haskell was
behind on all three rows (0.63× to 0.84×).

## Rerun

`scripts/bench petrus-agenticus-runtime` runs these rows with the rest of the
package, in wall-clock time (the rerun block in [RESULTS.md](RESULTS.md)). To
run only the Pi rows:

```sh
cabal bench -j2 petrus-agenticus-runtime --benchmark-options='-p /pi-/ --time-mode wall --stdev 3 +RTS -A32m -M2G -RTS'
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus-runtime/bench/python_pi.py)
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus-runtime/bench/python_pi_a2.py)
```

To interleave the native rows with `python_pi.py` and print a table:

```sh
scripts/bench-compare petrus-agenticus-runtime 15 --python python_pi.py --pattern '/pi-/ && !/-turn/' --stdev 3
```

`bench-compare` reads the rows timed with the twin's protocol
(`pi-ledger-cycle`, `pi-a2-scripted-turn`) from the `twin NAME NANOSECONDS`
line each one prints. The pattern leaves out the whole Pi Turns, whose twins
are in `python_bench.py`. To interleave those, with the hosts' whole Turns:

```sh
scripts/bench-compare petrus-agenticus-runtime 9 --pattern '/-turn/ && !/scripted/'
```
