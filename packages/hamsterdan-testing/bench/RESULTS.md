# hamsterdan-testing benchmarks

Two groups of workloads, both timed in wall-clock time on both sides:

- **The oracle** that a deterministic simulation consults at every
  checkpoint.
- **The readiness journeys**, each run end to end.

The machine was an Apple M4 (10 cores) on macOS 26.3.1, shared with other
work. The versions were:

- **Haskell:** GHC 9.10.3 with `-O2` and `tasty-bench`, run with `+RTS -M2G`.
- **Python:** CPython 3.14.6 with pydantic 2.13.4, from
  `scripts/upstream-python hamsterdan`.

Every ratio is Python ÷ Haskell.

## Oracle

The inputs are the 1658 documents of `test/corpus/oracle.jsonl` that the
reference admits. Each operation runs one pass over all of them:

- **evaluate:** `ReadinessModel().evaluate(facts)` on already-loaded facts.
- **load and evaluate:** `ReadinessFacts.load(json_text)` (strict
  validation), then `evaluate`.
- **liveness:** `evaluate_liveness` for each expectation, under the corpus's
  six environments and both budget flags (12 calls per document).

The load average was 2.1–2.5 during these runs (`uptime` before and after
each run).

- **Haskell:** each cell is that benchmark's mean.
- **Python:** each cell is the best of 5 `timeit` repeats, each about half a
  second of passes.
- **Interleaving:** two rounds, run as Haskell, Python, then Python, Haskell.
  The table shows each side's better round.

| Operation (one pass, 1658 documents) | Haskell | Python | Python / Haskell |
| --- | ---: | ---: | ---: |
| `evaluate` | 826 µs | 9.57 ms | 11.6× |
| `load` + `evaluate` | 17.3 ms | 29.1 ms | 1.7× |
| `evaluate_liveness` ×12 | 122 µs | 2.78 ms | 22.8× |

Haskell is faster on every row.

The Haskell `evaluate` forces the whole verdict: subject, generation,
readiness, disposition, every blocker, and every violation. The Python
`evaluate` also validates the `ReadinessExpectation` it builds. The Haskell
`load` runs the strict codec, including every `__post_init__` rule.

These Haskell times were taken in tasty-bench's default CPU time, before
`bench/Main.hs` switched to wall-clock time (`localOption WallTime`). This
workload is single-threaded and does no I/O inside the timed region, so the
two agree (see
[CPU and wall-clock time](../../../docs/reproducing.md#cpu-and-wall-clock-time)).

## Journeys

Each row runs one of the eleven readiness journeys of
`tests/integration/host/test_readiness_scenarios.py`, end to end. A run
starts from an empty temporary directory and ends with the journey's
result. In between it does everything the journey does:

- opens the host;
- receives and processes every signed webhook;
- runs every durable Activity;
- runs the scripted agents;
- for the journeys that publish (agent repair, stale base update, true
  conflict resolution), builds the Git fixture and publishes through the
  real Git publisher, with real `git` processes.

The two sides run the same journeys:

- **Haskell:** `runJourney` from `Hamsterdan.Testing.Journeys`. The result
  is then encoded to JSON, so all of it is forced.
- **Python:** the upstream `run_<name>` function, unchanged and in process.
  It runs under the determinism seams `differential/journeys_reference.py`
  applies: counted delivery ids, the fixed host clock, fixed Git dates and
  source-order intents.

The interop suite checks that both sides produce the same result and state
byte for byte (see [PARITY.md](../PARITY.md)).

How each side was measured:

- **Haskell:** each cell is tasty-bench's estimate, run with `--stdev 10` in
  the second and third rounds.
- **Python:** each cell is the best of 3 `timeit` repeats of at least one
  run each (`bench.py journeys/`). The Worker's stdout event lines go to
  `/dev/null`.
- **Interleaving:** three rounds, run as Haskell, Python, Python, Haskell,
  Haskell, Python. The table shows each side's best round.
- **Load:** the load average was 3.9–6.0 throughout, with other agents'
  builds running.

| Journey (one run) | Haskell | Python | Python / Haskell |
| --- | ---: | ---: | ---: |
| `clean_green` | 86.9 ms | 296 ms | 3.4× |
| `first_attempt_flake` | 77.3 ms | 414 ms | 5.3× |
| `persistent_ci_regression` | 99.2 ms | 517 ms | 5.2× |
| `seeded_review_finding` | 60.2 ms | 290 ms | 4.8× |
| `conversational_change` | 146 ms | 1.02 s | 7.0× |
| `agent_repair` | 1.30 s | 2.21 s | 1.7× |
| `hero_review` | 51.0 ms | 274 ms | 5.4× |
| `draft_ready` | 80.8 ms | 553 ms | 6.8× |
| `stale_base_update` | 1.13 s | 2.25 s | 2.0× |
| `true_conflict_resolution` | 1.16 s | 2.23 s | 1.9× |
| `collaboration_approval` | 171 ms | 559 ms | 3.3× |

Haskell is faster on every row.

The three Git journeys spawn about 40 `git` processes each: the fixture's
and the publisher's, the same on both sides. Under this load each one took
15–50 ms (traced with a logging `git` wrapper), so these runs are mostly
process spawning. The Haskell host spends about 0.3 s of CPU in a whole
`agent_repair` run (`+RTS -s`). The Python host spends about 0.7 s of CPU in
the same span, with no `git` process running. That difference is most of the
ratio.

<!-- TODO(world): World authoring and replay rows, once the World is ported. -->

## Rerun

From the repository root, alternating the two sides:

<!-- scripts/bench: rerun -->
```sh
cabal bench hamsterdan-testing -j2 --benchmark-options='+RTS -M2G -RTS' | sed -E 's/[{]"(worker|ready)"[^}]*[}]//g' | grep -v '^ *$'
"$(scripts/upstream-python hamsterdan)" -I -B packages/hamsterdan-testing/bench/bench.py
```

`scripts/bench hamsterdan-testing` runs exactly this block once;
`scripts/upstream-python hamsterdan` provisions the pinned Hamsterdan. The
`sed` and `grep` drop the Petrus Worker's event lines, which it prints on stdout for
every Activity it runs. To run one group, pass `-p journeys` (or `-p oracle`)
in the Haskell benchmark options and `journeys/` (or `oracle/`) to
`bench.py`.

Note `uptime` before and after each run.
