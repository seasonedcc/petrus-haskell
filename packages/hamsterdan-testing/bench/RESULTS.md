# hamsterdan-testing benchmarks

<!-- scripts/bench: measured sources 3afa5039dc56289f at df073f3106e5 -->
<!-- scripts/bench: carried to d5867f288f22c309 at f87d05b6f42b: since 50635f0, no behavior or representation change on the measured paths: of petrus-dst only the engine-worlds and joined-worlds sub-libraries changed, which hamsterdan-testing does not link (it builds on petrus-dst's main library); hamsterdan-host's V5 Runtime, hamsterdan-readiness's Board, the GitHub Auth module and hamsterdan-agents' Pi and Validate use Hamsterdan.PyLiteral's renamed constructors (PyNone..PyDict to LitNone..LitDict), names only; Hamsterdan.Python.Value.truthy, petrus-agenticus-runtime's Claude pyTruthy, petrus-execution's Docker and Gondolin truthy and petrus-motus-absurd's spellFailure truthy are petrus-json's pythonTruthy, the same seven equations; hamsterdan-contracts' Codec Literal int-against-float test, petrus-impetus's literalInt float branch and petrus-motus's local-dispatch sqlite3 int-against-float == call pyNumberEq, the same exact test they spelled out; petrus-history-store's floatEqualsInteger calls it too, reached only for a REAL position or a float occurrence, which the store never writes; Hamsterdan.Sqlite gains a comment only; petrus-sqlite's checkBindLength names the either throwIO pure . bindLength its bind loop already ran; petrus-json's Json == compiles to the same optimized Core as at 50635f0 (-ddump-simpl compared; numericEq/intFloatEq moved as pyNumberEq/exactFloatEq into Petrus.Json.Value and inlined there), PyObject's pyEq likewise, pythonTruthy added; petrus-posix gains additions only (DirectFd, directFd, writeDirect) and docs -->
<!-- scripts/bench: carried to 8d5e9844121d4ba9 at b4d1ccb669ad: since f87d05b: of petrus-dst only the joined-worlds sub-library changed (Support and Checkers compare, order and add counters through pyNumberEq, pyNumberCompare and pyNumAdd), which hamsterdan-testing does not link (it builds on petrus-dst's main library); hamsterdan-readiness's compareValues (NetV5.Py) orders two numbers through petrus-json's pyNumberCompare instead of its own Num'/numericCompare, reached only through the esc folds' tupleCompare and pyMax2 over (run, attempt) pairs of ints, whose int/int case pyNumberCompare inlines there as an Integer compare, as before, the rest of NetV5.Py compiling to the same optimized Core (-O2 -ddump-simpl compared); hamsterdan-readiness, rerun at b4d1ccb, reads its esc folds at 7.74x against 7.86x at df073f3; petrus-json gains additions only (jsonNumber exported, pyNumberCompare added and re-exported by Petrus.Json.Python.Object), every binding Petrus.Json.Value had before, Json's == (pythonEq) and pyNumberEq among them, compiling to the same optimized Core, generated constant names aside; petrus-posix's writeDirect gains a haddock sentence only -->
<!-- scripts/bench: carried to ef1467d73732601a at fa21af7738de: since b4d1ccb, only petrus-agenticus-runtime changed, in code this benchmark does not reach: runBounded's and ClaudeAdapterOptions' cases are named (ChildEnvironment, BoundedRun, ClientFactory, ClientReadiness), and no hamsterdan package calls runBounded or builds ClaudeAdapterOptions -->

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

Measured on 2026-10-13, 03:07–03:17 local (UTC-3), at commit `df073f3`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.47–3.33:
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
| `oracle.evaluate every admitted corpus document (1658)` | 825 µs | 9.77 ms | 11.84× | 11.80× | 3 of 3 | 825 µs, 822 µs, 828 µs | 10.1 ms, 9.71 ms, 9.77 ms |
| `oracle.load and evaluate every admitted corpus document (1658)` | 18.2 ms | 29.6 ms | 1.62× | 1.60× | 3 of 3 | 18 ms, 18.2 ms, 18.4 ms | 29.8 ms, 29.2 ms, 29.6 ms |
| `oracle.evaluate_liveness x12 over every expectation (1658)` | 117 µs | 2.81 ms | 24.04× | 22.87× | 3 of 3 | 115 µs, 117 µs, 123 µs | 2.85 ms, 2.75 ms, 2.81 ms |
| `journeys.clean_green` | 37.2 ms | 265 ms | 7.13× | 6.71× | 3 of 3 | 36.7 ms, 38.8 ms, 37.2 ms | 266 ms, 260 ms, 265 ms |
| `journeys.first_attempt_flake` | 47.8 ms | 373 ms | 7.80× | 7.69× | 3 of 3 | 47.8 ms, 48.5 ms, 47 ms | 367 ms, 373 ms, 376 ms |
| `journeys.persistent_ci_regression` | 49.9 ms | 422 ms | 8.47× | 8.38× | 3 of 3 | 49.9 ms, 49.3 ms, 50.9 ms | 422 ms, 421 ms, 426 ms |
| `journeys.seeded_review_finding` | 33.1 ms | 220 ms | 6.64× | 6.32× | 3 of 3 | 33.1 ms, 34.4 ms, 32.5 ms | 220 ms, 217 ms, 220 ms |
| `journeys.conversational_change` | 79.3 ms | 862 ms | 10.87× | 10.24× | 3 of 3 | 79.3 ms, 84 ms, 78.9 ms | 862 ms, 860 ms, 868 ms |
| `journeys.agent_repair` | 752 ms | 1.68 s | 2.24× | 2.22× | 3 of 3 | 743 ms, 756 ms, 752 ms | 1.68 s, 1.68 s, 1.7 s |
| `journeys.hero_review` | 32.9 ms | 224 ms | 6.80× | 6.74× | 3 of 3 | 33.1 ms, 32.9 ms, 32.8 ms | 223 ms, 224 ms, 225 ms |
| `journeys.draft_ready` | 55.3 ms | 504 ms | 9.12× | 8.87× | 3 of 3 | 55.3 ms, 55.7 ms, 54.6 ms | 491 ms, 514 ms, 504 ms |
| `journeys.stale_base_update` | 841 ms | 1.9 s | 2.26× | 2.23× | 3 of 3 | 841 ms, 849 ms, 812 ms | 1.9 s, 1.89 s, 1.93 s |
| `journeys.true_conflict_resolution` | 873 ms | 1.9 s | 2.18× | 2.17× | 3 of 3 | 873 ms, 879 ms, 859 ms | 1.9 s, 1.91 s, 1.9 s |
| `journeys.collaboration_approval` | 57.2 ms | 516 ms | 9.01× | 8.99× | 3 of 3 | 55.5 ms, 57.4 ms, 57.2 ms | 516 ms, 516 ms, 519 ms |
| `world.author coverage-duplicate-delivery` | 172 ms | 489 ms | 2.85× | 2.81× | 3 of 3 | 174 ms, 170 ms, 172 ms | 489 ms, 484 ms, 493 ms |
| `world.author authority-draft_resume` | 643 ms | 1.91 s | 2.97× | 2.93× | 3 of 3 | 656 ms, 626 ms, 643 ms | 1.92 s, 1.9 s, 1.91 s |
| `world.author timer-draft_resume` | 761 ms | 2.16 s | 2.84× | 2.75× | 3 of 3 | 778 ms, 727 ms, 761 ms | 2.14 s, 2.16 s, 2.17 s |
| `world.author git-after_acceptance` | 1.14 s | 3.22 s | 2.83× | 2.72× | 3 of 3 | 1.19 s, 1.13 s, 1.14 s | 3.23 s, 3.22 s, 3.19 s |
| `world.replay coverage-duplicate-delivery` | 170 ms | 475 ms | 2.79× | 2.74× | 3 of 3 | 170 ms, 173 ms, 170 ms | 473 ms, 475 ms, 486 ms |
| `world.replay authority-draft_resume` | 651 ms | 1.89 s | 2.90× | 2.87× | 3 of 3 | 651 ms, 625 ms, 654 ms | 1.9 s, 1.89 s, 1.88 s |
| `world.replay timer-draft_resume` | 734 ms | 2.13 s | 2.90× | 2.82× | 3 of 3 | 750 ms, 728 ms, 734 ms | 2.12 s, 2.13 s, 2.14 s |
| `world.replay git-after_acceptance` | 1.12 s | 3.23 s | 2.89× | 2.83× | 3 of 3 | 1.1 s, 1.12 s, 1.12 s | 3.23 s, 3.17 s, 3.23 s |

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
