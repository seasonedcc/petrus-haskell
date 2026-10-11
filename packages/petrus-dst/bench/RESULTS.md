# petrus-dst benchmark results

The same workloads, measured on the same inputs, in Haskell (`bench/Bench.hs`, tasty-bench)
and in the pinned Python reference (`scripts/bench.py`, `timeit`).

- Machine: Apple M4, 24 GB, macOS 26.3.1
- Haskell: GHC 9.10.3, library `-O2`, benchmark `-O2`
- Python: CPython 3.14.6, the reference's locked environment (`uv run --frozen`), petrus at
  `3f85fc2`
- Date: 2026-10-10

| Workload | Python | Haskell | Python ÷ Haskell |
| --- | ---: | ---: | ---: |
| decode + encode the 51 world fixtures | 30.7 ms | 20.0 ms | 1.5× |
| encode the 51 world fixtures (already decoded) | 11.4 ms | 5.63 ms | 2.0× |
| `digest_json` of the largest fixture | 571 µs | 219 µs | 2.6× |
| 1000 workload choice draws (`sha256-counter-v1`) | 1.89 ms | 1.29 ms | 1.5× |
| author and replay the 400 generated toy scripts | 255 ms | 87.3 ms | 2.9× |
| fold the queue-story process progress into its result | 557 µs | 256 µs | 2.2× |
| replay the 18 Engine-world fixtures through real Engine profiles | 162 ms | 81.3 ms | 2.0× |
| author the 18 Engine worlds (the reference's `build_*_artifact`) | 228 ms | 107 ms | 2.1× |
| one isolated PostgreSQL database (create, both schemas, drop) | 58.4 ms | 57.2 ms | 1.02× |
| replay the 33 joined fixtures, each in a fresh isolated database | 4.00 s | 3.61 s | 1.11× |
| author the 33 joined worlds, each in a fresh isolated database | 4.00 s | 3.63 s | 1.10× |

Haskell is faster on every workload. On the joined rows the margin is small, because the
PostgreSQL server does most of the work (below); the isolated database alone is level.

The three joined rows come from seven interleaved repetitions on 2026-10-11, 07:12–07:32 local
(UTC-3), at commit `570780d`, on `scripts/with-postgres`'s throwaway PostgreSQL 17.7 (`initdb`
defaults, so `fsync` on), with the 1-minute load average at 1.85–3.48. Each repetition ran
tasty-bench's `-p joined` (the executable started directly, `--stdev 5`, wall-clock time,
`+RTS -M2G`) and `scripts/bench.py joined/` (the median of 5 `timeit` rounds), alternating which
went first. Each figure is the median of the seven repetitions:

| Joined row | Python / Haskell | Lowest repetition | Repetitions Haskell faster | Haskell per repetition (ms) | Python per repetition (ms) |
| --- | ---: | ---: | ---: | --- | --- |
| one isolated database | 1.02× | 0.84× | 4/7 | 58, 56, 54, 70, 57, 57, 63 | 56, 58, 58, 59, 58, 58, 61 |
| replay 33 joined fixtures | 1.11× | 1.10× | 7/7 | 3471, 3439, 3703, 3730, 3608, 3641, 3598 | 3938, 3948, 4241, 4192, 4011, 4003, 4005 |
| author 33 joined worlds | 1.10× | 1.00× | 6/7 | 3595, 3770, 3595, 3618, 3688, 3633, 3678 | 3969, 3760, 4366, 4197, 3940, 4001, 4086 |

The isolated database is `CREATE DATABASE`, the two schemas and `DROP DATABASE … WITH (FORCE)`:
the same statements on both sides, and the server's work. It is level (the median repetition
1.006×); one Haskell repetition at 70 ms, when the load rose to 3.5, gives its lowest ratio.

The two Engine rows were measured later the same day, with many other builds running on the
machine (load average between 60 and 200), so their absolute times are much noisier than the
rows above. Both sides were measured back to back under the same load, so the ratio is the
meaningful number. Four of the 18 fixtures and four of the 18 stories run over the SQLite
LocalDispatch (`retry_world` and `generated_runtime_world`), which is why they cost more per
fixture than the History-only worlds. An earlier, quieter run over the 14 History-only worlds
measured 61.4 ms against 23.2 ms for replay (2.6×) and 62.7 ms against 21.3 ms for authoring
(2.9×).

### The joined rows of 2026-10-10

<!-- bench: superseded -->

The three joined rows were earlier measured (2026-10-10, load average 3 to 5) on a private
PostgreSQL 17 server (`fsync=off`) on the same machine, in wall-clock time (`--time-mode wall`;
these workloads wait on the server, which CPU time would not count). Haskell and Python ran
interleaved, twice each; the table then showed the second pair: 3.93 s against 3.74 s for replay
(1.05×), 4.09 s against 3.70 s for authoring (1.10×), 60.3 ms against 59.3 ms for the isolated
database (1.0×), Python first. The first pair measured 4.37 s against
3.62 s for replay and 4.15 s against 3.56 s for authoring. An earlier run at a higher load had
Haskell 5% behind on replay (4.71 s against 4.48 s), within the spread between runs.

The joined worlds are bound by the PostgreSQL server, not by either runtime. The isolated
database alone (`CREATE DATABASE`, the Impetus and Absurd schemas, `DROP DATABASE … WITH (FORCE)`)
costs about 60 ms on both sides, which is 2 of the 3.7 s; the rest is the Engine's, the Workers'
and the probes' round trips. Haskell's CPU time for the whole replay workload is 0.37 s.

### The joined rows after petrus-postgres's prepared-statement cache (2026-10-11, 02:28–03:03)

The joined rows above predate petrus-postgres's prepared-statement cache, which now prepares a
statement on its sixth execution on a connection, as psycopg does. On 2026-10-11 (02:28–03:03
local) they were rerun on a private PostgreSQL 17.7 (`fsync=off`) while other agents kept the
1-minute load average between 3.6 and 9.9:

- **Haskell against Python**, six interleaved pairs. The medians of the per-pair ratios were
  1.09× for replay (Haskell faster in 4 of 6 pairs), 1.02× for authoring (3 of 6) and 1.00× for
  the isolated database (3 of 6). Each side's own figures swung by up to 2× with the load
  (Haskell's replay from 3.76 s to 6.91 s, Python's from 4.05 s to 7.71 s), and the medians of
  the raw figures, which mix the quieter and busier pairs, came out at 0.98× for replay and
  0.88× for authoring. These runs cannot tell the two sides apart. They do not replace the
  table.
- **The cache itself**, the same Haskell bench built with the cache off
  (`prepareThresholdOption = Nothing`) and on, alternated four times: replay 6.69 s off against
  4.74 s on (medians; the cache faster in all four pairs), authoring 5.68 s against 4.92 s (three
  of four). The change does not slow these rows down.

What each workload covers:

- **decode + encode**: the strict artifact loader (strict JSON, duplicate keys, the pydantic-
  equivalent validation of versions 1 to 4) and the canonical re-encoding, over every committed
  world fixture.
- **encode**: `model_dump(mode="json")` plus canonical `json.dumps` (`encodeArtifact`).
- **digest**: canonical bytes plus SHA-256 of the largest fixture's JSON value.
- **choice draws**: `ChoiceStreams(1729).index(WORKLOAD, 1000)` a thousand times.
- **author and replay**: the differential corpus of `test/data/generated-stories.json`. Each
  script is authored on a fresh toy World (commands, faults, observations, crashes, restarts,
  the fair phase, the settle loop), its artifact is produced and encoded, and the artifact is
  replayed through fresh toys. This is the interpreter's own cost, because the toy profiles
  are trivial.
- **fold**: `_process_result` over the 15-frame queue-story progress file, including result
  encoding. Python reads the progress from a file. Haskell takes the bytes.
- **Engine replay**: each fixture of `Spec.EngineWorlds.replayCases` is strictly decoded and
  replayed through fresh profiles over a fresh scratch directory. It runs on the real Engine
  over a real JSONL History: create, load after every crash, apply, observe, and the checkers.
  The run ends with the canonical replay-result bytes.
  - Python uses the reference's own `tests.dst.replay_world.replay_path`. It registers every
    Engine profile per fixture, constructors only: History and Dispatch files open lazily.
  - Haskell registers the profiles of that fixture's world module.
- **Joined replay**: each of the 33 `joined-*` fixtures is strictly decoded and replayed
  through a fresh profile (`Spec.JoinedWorlds.joinedCases`) in a fresh isolated database: the
  real Absurd Engine over PostgreSQL History, with Absurd Workers. Python uses
  `transcript_vectors.joined_replay`, the reference's profile and checker classes over
  `isolated_absurd_database`, exactly as its retained-fixture tests do.
- **Joined authoring**: each of the 33 joined stories in a fresh isolated database. Python calls
  the reference's 33 `build_joined_*_artifact(dsn)` functions.
- **Engine authoring**: every `Spec.EngineWorlds.authorCases` story runs on a fresh History.
  This covers the executable, seeded, and failure stories of `engine_world`, `delayed_world`,
  `delivery_world`, `timer_world`, `lifecycle_world`, `retry_world` (over LocalDispatch) and
  `generated_runtime_world`. Each produces and encodes its artifact. The Python side calls the reference's `build_*_artifact` functions.

The first measurement had Haskell slower on encoding: 24.2 ms against 11.4 ms, and 1.05 ms
against 571 µs for the digest. petrus-json's general `dumps` builds every string one character
at a time and threads an `Either` through every node. `Petrus.Testing.Dst.Internal.Canonical`
now specializes the one canonical spelling. It copies plain-ASCII strings in one piece, and it
scans for non-finite floats once, up front. Two checks keep it byte-identical to `dumps`:

- a QuickCheck property over generated JSON (escapes, control characters, astral text,
  non-finite floats, key order);
- the fixture and mutation corpora.

## Rerun

From the repository root. The joined rows run only with `PETRUS_TEST_POSTGRES` set to a
server where the role may create databases, on both sides; `scripts/bench petrus-dst` runs
this block under `scripts/with-postgres`, which starts a throwaway server when the variable is
unset. `cabal bench` runs the benchmark from the package directory, where it reads its
fixtures; `scripts/upstream-python` provisions the pinned reference.

<!-- scripts/bench: rerun -->
```sh
# Every row; the joined rows need PETRUS_TEST_POSTGRES.
cabal bench -j2 petrus-dst --benchmark-options='--stdev 5 +RTS -M2G -RTS'
(cd upstream/petrus && PYTHONPATH=. "$(../../scripts/upstream-python)" -B ../../packages/petrus-dst/scripts/bench.py)
```

The Python script takes a name filter (`bench.py joined/`), and tasty-bench a pattern
(`--benchmark-options='-p joined'`), to run the joined rows alone.

Every Haskell row is timed in wall-clock time (`localOption WallTime` in `bench/Bench.hs`),
like the Python side; the joined rows always were (`--time-mode wall`). The other rows were
taken in tasty-bench's default CPU time; they are single-threaded and do no I/O inside the
timed region, so the two agree (see
[CPU and wall-clock time](../../../docs/reproducing.md#cpu-and-wall-clock-time)).
