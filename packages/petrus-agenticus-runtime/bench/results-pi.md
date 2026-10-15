# Pi runtime benchmark results

<!-- scripts/bench: measured sources 74c3be7661028153 at df073f3106e5 -->
<!-- scripts/bench: carried to 18f6681461150a58 at f87d05b6f42b: since 50635f0, no behavior or representation change on the measured paths: Claude's pyTruthy (its isError check) is petrus-json's pythonTruthy, the same seven equations, as are petrus-execution's Docker and Gondolin providers' local truthy; petrus-history-store's floatEqualsInteger calls pyNumberEq, the same exact test, reached only for a REAL position or a float occurrence, which the store never writes; petrus-impetus's literalInt float branch and petrus-motus's local-dispatch sqlite3 int-against-float == call pyNumberEq, the same exact test they spelled out; petrus-sqlite's checkBindLength names the either throwIO pure . bindLength its bind loop already ran; petrus-json's Json == compiles to the same optimized Core as at 50635f0 (-ddump-simpl compared; numericEq/intFloatEq moved as pyNumberEq/exactFloatEq into Petrus.Json.Value and inlined there), PyObject's pyEq likewise, pythonTruthy added; petrus-posix gains additions only (DirectFd, directFd, writeDirect) and docs -->
<!-- scripts/bench: carried to 54829b917bb023f6 at b4d1ccb669ad: since f87d05b, no measured code changed: petrus-json gains additions only (Petrus.Json.Value exports jsonNumber and adds pyNumberCompare, Python's numeric <, NaN unordered, INLINE, beside pyNumberEq; Petrus.Json.Python.Object re-exports it), and every binding Petrus.Json.Value had before, Json's == (pythonEq), pyNumberEq and exactFloatEq among them, compiles to the same optimized Core (-O2 -ddump-simpl compared, generated constant names aside); petrus-posix's writeDirect gains a haddock sentence only -->
<!-- scripts/bench: carried to 99313422e024c368 at fa21af7738de: since b4d1ccb, no measured path changed: runBounded takes a ChildEnvironment and returns a BoundedRun in place of its two Maybes, matched by name where each probe read the Maybe, and ClaudeAdapterOptions' clientFactory and ready are ClientFactory and ClientReadiness, read once when the adapter is built into the same Readiness; the probes that call runBounded run once before timing (TurnsBench), and no turn, frame, transcript or parse path changed -->

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

## Current figures

Measured on 2026-10-13, 03:22–03:29 local (UTC-3), at commit `df073f3`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.45–3.82:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-agenticus-runtime 3 --python python_runner.py --python python_pi.py --python python_pi_a2.py --python python_hosts.py --python python_bench.py

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `pi-a2-scripted-turn` | 8.65 ms | 28.3 ms | 3.27× | 3.04× | 3 of 3 | 9.42 ms, 8.62 ms, 8.65 ms | 28.7 ms, 28 ms, 28.3 ms |
| `pi-start-frame-encode` | 3.72 µs | 7.71 µs | 2.07× | 2.05× | 3 of 3 | 3.72 µs, 3.67 µs, 3.75 µs | 7.71 µs, 7.52 µs, 7.77 µs |
| `pi-tool-call-decode` | 296 ns | 1.82 µs | 6.16× | 6.08× | 3 of 3 | 300 ns, 296 ns, 294 ns | 1.82 µs, 1.81 µs, 1.83 µs |
| `pi-session-validate` | 132 µs | 463 µs | 3.50× | 3.38× | 3 of 3 | 132 µs, 134 µs, 131 µs | 463 µs, 453 µs, 463 µs |
| `pi-fingerprint` | 2 µs | 6.33 µs | 3.16× | 3.09× | 3 of 3 | 2.04 µs, 1.99 µs, 2 µs | 6.31 µs, 6.38 µs, 6.33 µs |
| `pi-a2-fingerprint` | 2.09 µs | 6.09 µs | 2.92× | 2.88× | 3 of 3 | 2.08 µs, 2.09 µs, 2.11 µs | 6.02 µs, 6.15 µs, 6.09 µs |
| `pi-native-turn` | 39.8 ms | 46.2 ms | 1.16× | 1.16× | 3 of 3 | 39.5 ms, 39.8 ms, 40.4 ms | 45.6 ms, 46.2 ms, 46.9 ms |
| `pi-a5-turn` | 37.8 ms | 45.7 ms | 1.21× | 1.19× | 3 of 3 | 37.7 ms, 37.8 ms, 38.4 ms | 45.6 ms, 46.2 ms, 45.7 ms |
| `pi-model-phase-turn` | 27.6 ms | 29.6 ms | 1.07× | 1.06× | 5 of 5 | 27.6 ms, 27.4 ms, 27.2 ms, 27.9 ms, 27.6 ms | 29.6 ms, 29.1 ms, 28.7 ms, 30.4 ms, 30.6 ms |
| `pi-ledger-cycle` | 845 µs | 918 µs | 1.09× | 1.03× | 5 of 5 | 816 µs, 845 µs, 866 µs, 833 µs, 853 µs | 922 µs, 884 µs, 891 µs, 918 µs, 938 µs |

The rows under 1.15× after the three repetitions (`pi-ledger-cycle`,
`pi-model-phase-turn`, and `codex-a3-service-turn` and `amp-turn` in
[results-hosts.md](results-hosts.md)) got two more interleaved
repetitions of those rows alone, 03:59–04:02, load average 2.65–3.20:

    scripts/bench-compare petrus-agenticus-runtime 2 --python python_runner.py --python python_pi.py --python python_pi_a2.py --python python_hosts.py --python python_bench.py --pattern '/pi-ledger-cycle/ || /codex-a3-service-turn/ || /amp-turn/ || /pi-model-phase-turn/' --python-only 'pi-ledger-cycle|codex-a3-service-turn|amp-turn|pi-model-phase-turn'

Their lines above pool all five; Haskell was ahead in every repetition of
every row. `pi-ledger-cycle` is four fsyncs, and its closeness to 1.0× is
the device's noise (below). `pi-native-turn` cleared 1.15× after the
three (39.8 ms against 46.2 ms, 1.16×).

### 2026-10-13, at `c0cb6cb` (superseded)

<!-- bench: superseded -->

Measured on 2026-10-13, 01:06–01:12 local (UTC-3), with a 1-minute load
average of 2.05–3.65: three interleaved repetitions of the command above, and two more of the rows under 1.15× (01:12–01:14, load average
2.99–3.49), whose lines pooled all five. Superseded by the run at `df073f3` above.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `pi-a2-scripted-turn` | 8.77 ms | 28.1 ms | 3.21× | 3.11× | 3 of 3 | 8.77 ms, 9.1 ms, 8.65 ms | 28.1 ms, 28.3 ms, 28 ms |
| `pi-start-frame-encode` | 3.7 µs | 7.68 µs | 2.07× | 2.05× | 3 of 3 | 3.66 µs, 3.7 µs, 3.73 µs | 7.7 µs, 7.68 µs, 7.63 µs |
| `pi-tool-call-decode` | 310 ns | 1.84 µs | 5.95× | 5.87× | 3 of 3 | 310 ns, 310 ns, 310 ns | 1.86 µs, 1.84 µs, 1.82 µs |
| `pi-session-validate` | 137 µs | 460 µs | 3.37× | 3.34× | 3 of 3 | 137 µs, 136 µs, 138 µs | 462 µs, 460 µs, 460 µs |
| `pi-fingerprint` | 2.03 µs | 6.37 µs | 3.15× | 3.02× | 3 of 3 | 2.07 µs, 2.03 µs, 2.01 µs | 6.24 µs, 6.37 µs, 6.39 µs |
| `pi-a2-fingerprint` | 2.11 µs | 6.15 µs | 2.91× | 2.88× | 3 of 3 | 2.08 µs, 2.11 µs, 2.11 µs | 6.15 µs, 6.07 µs, 6.17 µs |
| `pi-native-turn` | 39.7 ms | 45.2 ms | 1.14× | 1.08× | 5 of 5 | 40.1 ms, 39.7 ms, 39.4 ms, 39.4 ms, 42 ms | 44.7 ms, 46.3 ms, 45.4 ms, 44.5 ms, 45.2 ms |
| `pi-a5-turn` | 37.6 ms | 45.9 ms | 1.22× | 1.20× | 3 of 3 | 37.2 ms, 38.1 ms, 37.6 ms | 47.8 ms, 45.9 ms, 45.8 ms |
| `pi-model-phase-turn` | 27.4 ms | 29 ms | 1.06× | 1.02× | 5 of 5 | 27.2 ms, 27.4 ms, 27.7 ms, 26.7 ms, 27.6 ms | 29 ms, 29 ms, 29.2 ms, 29.1 ms, 28.1 ms |
| `pi-ledger-cycle` | 838 µs | 898 µs | 1.07× | 1.03× | 5 of 5 | 820 µs, 864 µs, 877 µs, 810 µs, 838 µs | 898 µs, 886 µs, 943 µs, 928 µs, 898 µs |

### 2026-10-12, at `13f7a84` (superseded)

<!-- bench: superseded -->

Measured on 2026-10-12, 22:26–22:32 local (UTC-3), with a 1-minute load
average of 2.03–3.60: three interleaved repetitions of the command above,
and two more of the rows under 1.15× (22:36–22:38, load average
2.34–3.21), whose lines pooled all five. Superseded by the run at
`c0cb6cb`.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `pi-a2-scripted-turn` | 9.16 ms | 28.2 ms | 3.07× | 2.98× | 3 of 3 | 9.16 ms, 9.15 ms, 9.45 ms | 27.6 ms, 29.2 ms, 28.2 ms |
| `pi-start-frame-encode` | 3.69 µs | 7.78 µs | 2.11× | 2.09× | 3 of 3 | 3.69 µs, 3.72 µs, 3.69 µs | 7.8 µs, 7.78 µs, 7.72 µs |
| `pi-tool-call-decode` | 302 ns | 1.8 µs | 5.97× | 5.97× | 3 of 3 | 302 ns, 297 ns, 305 ns | 1.8 µs, 1.79 µs, 1.83 µs |
| `pi-session-validate` | 136 µs | 455 µs | 3.35× | 3.31× | 3 of 3 | 135 µs, 137 µs, 136 µs | 455 µs, 452 µs, 456 µs |
| `pi-fingerprint` | 2.02 µs | 6.37 µs | 3.15× | 3.11× | 3 of 3 | 2.02 µs, 2.05 µs, 2.02 µs | 6.32 µs, 6.37 µs, 6.38 µs |
| `pi-a2-fingerprint` | 2.1 µs | 6.14 µs | 2.92× | 2.87× | 3 of 3 | 2.1 µs, 2.09 µs, 2.14 µs | 6.12 µs, 6.18 µs, 6.14 µs |
| `pi-native-turn` | 40.1 ms | 45.5 ms | 1.13× | 1.09× | 5 of 5 | 40.2 ms, 39.6 ms, 40 ms, 40.2 ms, 40.1 ms | 45.5 ms, 46.4 ms, 44.5 ms, 43.9 ms, 45.7 ms |
| `pi-a5-turn` | 38 ms | 45.4 ms | 1.20× | 1.13× | 3 of 3 | 38 ms, 37.6 ms, 40.8 ms | 44.8 ms, 45.4 ms, 46.1 ms |
| `pi-model-phase-turn` | 27.3 ms | 28.6 ms | 1.05× | 1.01× | 5 of 5 | 27.1 ms, 27.3 ms, 27.3 ms, 27.9 ms, 26.9 ms | 28.6 ms, 28.6 ms, 28.8 ms, 28.1 ms, 28.2 ms |
| `pi-ledger-cycle` | 884 µs | 924 µs | 1.05× | 0.98× | 4 of 5 | 884 µs, 912 µs, 868 µs, 945 µs, 881 µs | 978 µs, 924 µs, 903 µs, 923 µs, 935 µs |

Their lines above pool all five. `pi-ledger-cycle` is four fsyncs, and its
closeness to 1.0× is the device's noise; Haskell was ahead in 4 of the 5.
At `81bbdc5` that row read 0.98× in the five-repetition run and, in a run
of its own, 15 interleaved repetitions on 2026-10-12, 04:26–04:27 local,
load average 2.43–2.60, of

    scripts/bench-compare petrus-agenticus-runtime 15 --pattern pi-ledger-cycle --python python_pi.py --python-only pi-ledger-cycle

gave:

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `pi-ledger-cycle` | 820 µs | 877 µs | 1.07× | 0.98× | 826 µs, 826 µs, 852 µs, 876 µs, 855 µs, 750 µs, 820 µs, 823 µs, 817 µs, 873 µs, 796 µs, 815 µs, 799 µs, 782 µs, 793 µs | 975 µs, 867 µs, 877 µs, 862 µs, 888 µs, 817 µs, 890 µs, 894 µs, 886 µs, 892 µs, 845 µs, 874 µs, 806 µs, 863 µs, 910 µs |

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

<!-- bench: superseded -->

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

<!-- bench: superseded -->

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
scripts/bench-run petrus-agenticus-runtime -p /pi-/ --time-mode wall --stdev 3 +RTS -A32m -M2G -RTS
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
