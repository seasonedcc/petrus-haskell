# Pi runtime benchmark results

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
  each iteration uses a fresh operation id.
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
  `pi-a2-scripted-turn`.
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
| pi-ledger-cycle | 1.01 ms | 1.09 ms | 1.08× | 0.47× |
| pi-a2-fingerprint | 2.49 µs | 6.25 µs | 2.5× | 2.5× |
| pi-a2-scripted-turn | 10.4 ms | 29.2 ms | 2.8× | 2.7× |

"Slowest round" is the lowest Python / Haskell ratio of a single round.

**`pi-ledger-cycle` now runs level with Python or slightly ahead, at 1.08×.**
Its row comes from a separate run of five wall-clock rounds,
`scripts/bench-compare petrus-agenticus-runtime 5 --python python_pi.py
--pattern '/pi-/' --stdev 3`, on 2026-10-11 at 01:50–02:05 local (UTC-3),
with the ledger's statement cache (commit `3f31d2e`), load average
4.6–7.3. Each round ran the Haskell bench, then `python_pi.py`. Haskell took
1.07, 1.00, 0.955, 1.01 and 2.20 ms; Python took 1.07, 1.09, 1.09, 1.11 and
1.02 ms. Haskell was ahead in three rounds and level in one. It was behind
in the last round, where its 2.20 ms mean was one disturbed run (the
"slowest round" figure of 0.47× is that round).

Before this change the row was 0.84× (Haskell 1.07, 1.07 and 0.934 ms
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
with the monotonic clock. The same run's figures for them agree with the
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
  `Petrus.Impetus.Internal.PyJson` accepts as the same value. The two
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
scripts/bench-compare petrus-agenticus-runtime 5 --python python_pi.py --pattern '/pi-/' --stdev 3
```
