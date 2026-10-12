# hamsterdan-testing benchmarks

<!-- scripts/bench: measured sources 0aa75ac95f5bccb3 at 4b4fcde3cc48 -->

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

Measured on 2026-10-12, 03:44–03:53 local (UTC-3), at commit `81bbdc5`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.27–3.02:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare hamsterdan-testing 3 --twin '"$(scripts/upstream-python hamsterdan)" -I -B packages/hamsterdan-testing/bench/bench.py'

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `oracle.evaluate every admitted corpus document (1658)` | 826 µs | 9.67 ms | 11.71× | 11.60× | 827 µs, 820 µs, 826 µs | 9.6 ms, 9.67 ms, 9.7 ms |
| `oracle.load and evaluate every admitted corpus document (1658)` | 17.6 ms | 29.2 ms | 1.66× | 1.65× | 17.6 ms, 17.5 ms, 17.6 ms | 29.2 ms, 29.4 ms, 29.1 ms |
| `oracle.evaluate_liveness x12 over every expectation (1658)` | 117 µs | 2.8 ms | 23.96× | 23.50× | 115 µs, 117 µs, 119 µs | 2.92 ms, 2.76 ms, 2.8 ms |
| `journeys.clean_green` | 35.1 ms | 258 ms | 7.35× | 7.26× | 35.1 ms, 35.5 ms, 34.8 ms | 257 ms, 258 ms, 258 ms |
| `journeys.first_attempt_flake` | 45 ms | 367 ms | 8.17× | 8.11× | 43.8 ms, 45 ms, 45.1 ms | 367 ms, 364 ms, 367 ms |
| `journeys.persistent_ci_regression` | 49 ms | 420 ms | 8.57× | 8.52× | 49.6 ms, 48.6 ms, 49 ms | 422 ms, 417 ms, 420 ms |
| `journeys.seeded_review_finding` | 31 ms | 216 ms | 6.96× | 6.72× | 31 ms, 32 ms, 30.5 ms | 216 ms, 215 ms, 217 ms |
| `journeys.conversational_change` | 75.9 ms | 855 ms | 11.27× | 11.03× | 75.9 ms, 76.8 ms, 74.5 ms | 856 ms, 847 ms, 855 ms |
| `journeys.agent_repair` | 671 ms | 1.61 s | 2.39× | 2.38× | 676 ms, 668 ms, 671 ms | 1.61 s, 1.6 s, 1.61 s |
| `journeys.hero_review` | 31.6 ms | 226 ms | 7.15× | 6.98× | 31.6 ms, 30.8 ms, 32.3 ms | 226 ms, 222 ms, 226 ms |
| `journeys.draft_ready` | 52.6 ms | 488 ms | 9.27× | 8.84× | 55.3 ms, 51.3 ms, 52.6 ms | 489 ms, 483 ms, 488 ms |
| `journeys.stale_base_update` | 754 ms | 1.84 s | 2.44× | 2.33× | 750 ms, 788 ms, 754 ms | 1.84 s, 1.84 s, 1.84 s |
| `journeys.true_conflict_resolution` | 763 ms | 1.85 s | 2.42× | 2.38× | 760 ms, 772 ms, 763 ms | 1.87 s, 1.84 s, 1.85 s |
| `journeys.collaboration_approval` | 53.8 ms | 511 ms | 9.49× | 9.06× | 53.8 ms, 53.1 ms, 56.4 ms | 513 ms, 509 ms, 511 ms |
| `world.author coverage-duplicate-delivery` | 181 ms | 477 ms | 2.63× | 2.62× | 184 ms, 179 ms, 181 ms | 483 ms, 475 ms, 477 ms |
| `world.author authority-draft_resume` | 729 ms | 1.88 s | 2.58× | 2.55× | 728 ms, 729 ms, 738 ms | 1.89 s, 1.88 s, 1.88 s |
| `world.author timer-draft_resume` | 826 ms | 2.13 s | 2.58× | 2.54× | 826 ms, 833 ms, 826 ms | 2.14 s, 2.12 s, 2.13 s |
| `world.author git-after_acceptance` | 1.3 s | 3.17 s | 2.45× | 2.45× | 1.3 s, 1.27 s, 1.3 s | 3.21 s, 3.15 s, 3.17 s |
| `world.replay coverage-duplicate-delivery` | 177 ms | 473 ms | 2.67× | 2.65× | 177 ms, 177 ms, 178 ms | 473 ms, 470 ms, 473 ms |
| `world.replay authority-draft_resume` | 718 ms | 1.86 s | 2.59× | 2.55× | 713 ms, 728 ms, 718 ms | 1.88 s, 1.86 s, 1.86 s |
| `world.replay timer-draft_resume` | 820 ms | 2.11 s | 2.57× | 2.47× | 819 ms, 849 ms, 820 ms | 2.12 s, 2.1 s, 2.11 s |
| `world.replay git-after_acceptance` | 1.28 s | 3.14 s | 2.46× | 2.46× | 1.28 s, 1.26 s, 1.28 s | 3.16 s, 3.13 s, 3.14 s |

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
