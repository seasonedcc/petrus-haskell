# hamsterdan-testing benchmarks

<!-- scripts/bench: measured sources 079e1c5ab975ba36 at 9da9efa829ab -->

Three groups of workloads, all timed in wall-clock time on both sides:

- **The oracle** that a deterministic simulation consults at every
  checkpoint.
- **The readiness journeys**, each run end to end.
- **The World**: named World scenarios authored to artifacts, and those
  artifacts replayed.

The machine was an Apple M4 (10 cores) on macOS 26.3.1, shared with other
work. The versions were:

- **Haskell:** GHC 9.10.3 with `-O2` and `tasty-bench`, run with `+RTS -M2G`.
- **Python:** CPython 3.14.6 with pydantic 2.13.4, from
  `scripts/upstream-python hamsterdan`.

Every ratio is Python ÷ Haskell.

## Current figures

Measured on 2026-10-12, 21:26–21:37 local (UTC-3), at commit `848eeba`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.02–3.25:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare hamsterdan-testing 3 --twin '"$(scripts/upstream-python hamsterdan)" -I -B packages/hamsterdan-testing/bench/bench.py'

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `oracle.evaluate every admitted corpus document (1658)` | 824 µs | 9.82 ms | 11.92× | 11.58× | 3 of 3 | 824 µs, 833 µs, 820 µs | 9.82 ms, 9.64 ms, 10 ms |
| `oracle.load and evaluate every admitted corpus document (1658)` | 18.1 ms | 29.5 ms | 1.62× | 1.62× | 3 of 3 | 18.4 ms, 18.1 ms, 18 ms | 29.8 ms, 29.5 ms, 29.4 ms |
| `oracle.evaluate_liveness x12 over every expectation (1658)` | 117 µs | 2.81 ms | 24.00× | 23.86× | 3 of 3 | 116 µs, 118 µs, 117 µs | 2.81 ms, 2.81 ms, 2.93 ms |
| `journeys.clean_green` | 38.5 ms | 268 ms | 6.94× | 6.86× | 3 of 3 | 36.5 ms, 38.5 ms, 38.7 ms | 268 ms, 264 ms, 274 ms |
| `journeys.first_attempt_flake` | 49.6 ms | 380 ms | 7.66× | 7.46× | 3 of 3 | 49.6 ms, 50 ms, 48.5 ms | 381 ms, 373 ms, 380 ms |
| `journeys.persistent_ci_regression` | 53.7 ms | 427 ms | 7.94× | 7.67× | 3 of 3 | 55.4 ms, 53.7 ms, 51.7 ms | 424 ms, 427 ms, 431 ms |
| `journeys.seeded_review_finding` | 34.8 ms | 222 ms | 6.37× | 6.24× | 3 of 3 | 34.8 ms, 34.8 ms, 35.2 ms | 226 ms, 222 ms, 219 ms |
| `journeys.conversational_change` | 83.6 ms | 874 ms | 10.46× | 9.95× | 3 of 3 | 83.4 ms, 87.8 ms, 83.6 ms | 868 ms, 874 ms, 888 ms |
| `journeys.agent_repair` | 784 ms | 1.69 s | 2.15× | 2.14× | 3 of 3 | 758 ms, 784 ms, 790 ms | 1.64 s, 1.7 s, 1.69 s |
| `journeys.hero_review` | 35.3 ms | 230 ms | 6.51× | 6.35× | 3 of 3 | 36 ms, 33.4 ms, 35.3 ms | 229 ms, 230 ms, 233 ms |
| `journeys.draft_ready` | 55.5 ms | 497 ms | 8.96× | 8.77× | 3 of 3 | 54 ms, 56.7 ms, 55.5 ms | 493 ms, 497 ms, 505 ms |
| `journeys.stale_base_update` | 876 ms | 1.95 s | 2.22× | 2.21× | 3 of 3 | 876 ms, 872 ms, 898 ms | 1.94 s, 1.95 s, 1.98 s |
| `journeys.true_conflict_resolution` | 931 ms | 1.95 s | 2.10× | 2.08× | 3 of 3 | 868 ms, 938 ms, 931 ms | 1.94 s, 1.95 s, 2 s |
| `journeys.collaboration_approval` | 61.4 ms | 519 ms | 8.46× | 8.32× | 3 of 3 | 57.4 ms, 61.4 ms, 62.4 ms | 515 ms, 524 ms, 519 ms |
| `world.author coverage-duplicate-delivery` | 174 ms | 493 ms | 2.83× | 2.80× | 3 of 3 | 174 ms, 174 ms, 178 ms | 489 ms, 493 ms, 501 ms |
| `world.author authority-draft_resume` | 682 ms | 1.9 s | 2.79× | 2.77× | 3 of 3 | 682 ms, 687 ms, 665 ms | 1.9 s, 1.9 s, 1.96 s |
| `world.author timer-draft_resume` | 764 ms | 2.19 s | 2.87× | 2.85× | 3 of 3 | 770 ms, 756 ms, 764 ms | 2.2 s, 2.15 s, 2.19 s |
| `world.author git-after_acceptance` | 1.15 s | 3.22 s | 2.79× | 2.76× | 3 of 3 | 1.18 s, 1.15 s, 1.15 s | 3.26 s, 3.22 s, 3.2 s |
| `world.replay coverage-duplicate-delivery` | 175 ms | 482 ms | 2.76× | 2.74× | 3 of 3 | 177 ms, 168 ms, 175 ms | 484 ms, 482 ms, 478 ms |
| `world.replay authority-draft_resume` | 662 ms | 1.88 s | 2.84× | 2.81× | 3 of 3 | 670 ms, 662 ms, 662 ms | 1.88 s, 1.88 s, 1.88 s |
| `world.replay timer-draft_resume` | 740 ms | 2.12 s | 2.87× | 2.79× | 3 of 3 | 730 ms, 740 ms, 760 ms | 2.12 s, 2.13 s, 2.12 s |
| `world.replay git-after_acceptance` | 1.13 s | 3.17 s | 2.81× | 2.73× | 3 of 3 | 1.17 s, 1.1 s, 1.13 s | 3.19 s, 3.17 s, 3.17 s |

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

<!-- bench: superseded -->

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

<!-- bench: superseded -->

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

## World

Four of the named World scenarios (`Hamsterdan.Testing.World.Scenarios`,
`differential/world_reference.py`), each timed two ways:

- **author:** a fresh `ReadinessWorld` in an empty temporary directory, the
  scenario's Timeline calls through the real V5 host and Petrus DST v4, then
  `world.artifact(...)` and `encode_artifact`. This is the work the World
  interop suite compares byte for byte.
- **replay:** `replay_readiness` of the scenario's artifact (decoded once,
  outside the timed region) in an empty temporary directory, then the
  canonical replay-result bytes.

The scenarios:

- `coverage-duplicate-delivery`: a clean green delivery, redelivered.
- `authority-draft_resume`: the authority moves to a new head as a draft,
  then resumes.
- `timer-draft_resume`: the reminder timer across a draft/resume, a lost
  reminder response and a crash after acceptance.
- `git-after_acceptance`: a conversational Git publication whose ref
  response is lost, a crash after the ref is accepted, then recovery.

How each side was measured:

- **Haskell:** each cell is tasty-bench's estimate with `--stdev 10`
  (`-p world`).
- **Python:** each cell is the best of 3 `timeit` repeats of one run each
  (`bench.py world/`). The Worker's stdout event lines go to `/dev/null`.
- **Interleaving:** two rounds, run as Haskell, Python, then Python,
  Haskell. The table shows each side's better round.
- **Load:** the load average was 4.0–5.0 throughout, with other agents'
  builds running.

<!-- bench: superseded -->

| World scenario (one run) | Haskell | Python | Python / Haskell |
| --- | ---: | ---: | ---: |
| author `coverage-duplicate-delivery` | 255 ms | 575 ms | 2.3× |
| author `authority-draft_resume` | 892 ms | 2.66 s | 3.0× |
| author `timer-draft_resume` | 1.07 s | 2.50 s | 2.3× |
| author `git-after_acceptance` | 1.63 s | 3.54 s | 2.2× |
| replay `coverage-duplicate-delivery` | 244 ms | 530 ms | 2.2× |
| replay `authority-draft_resume` | 882 ms | 2.09 s | 2.4× |
| replay `timer-draft_resume` | 1.02 s | 2.39 s | 2.3× |
| replay `git-after_acceptance` | 2.11 s | 3.56 s | 1.7× |

Haskell is faster on every row.

Haskell's first round ran under heavier load and was 1.1–1.9× slower than
its second; even that round was faster than both Python rounds on every row.

## Rerun

From the repository root, alternating the two sides:

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run hamsterdan-testing +RTS -M2G -RTS | sed -E 's/[{]"(worker|ready)"[^}]*[}]//g' | grep -v '^ *$'
"$(scripts/upstream-python hamsterdan)" -I -B packages/hamsterdan-testing/bench/bench.py
```

`scripts/bench hamsterdan-testing` runs exactly this block once;
`scripts/upstream-python hamsterdan` provisions the pinned Hamsterdan. The
`sed` and `grep` drop the Petrus Worker's event lines, which it prints on stdout for
every Activity it runs. To run one group, pass `-p journeys` (or `-p oracle`,
`-p world`) in the Haskell benchmark options and `journeys/` (or `oracle/`,
`world/`) to `bench.py`.

Note `uptime` before and after each run.
