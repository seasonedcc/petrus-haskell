# petrus-dst benchmark results

<!-- scripts/bench: measured sources 11304a25a36733fc at df073f3106e5 -->

The same workloads, measured on the same inputs, in Haskell (`bench/Bench.hs`, tasty-bench)
and in the pinned Python reference (`scripts/bench.py`, `timeit`).

## Current figures

Measured on 2026-10-13, 04:08–04:17 local (UTC-3), at commit `df073f3`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 3.16–3.81:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-dst 3 \
        --map 'engine.replay the Engine-world fixtures=engine/replay 18 Engine-world fixtures' \
        --map 'engine.author the Engine worlds=engine/author 18 Engine worlds' \
        --map 'joined.one isolated database (create, both schemas, drop)=joined/one isolated database' \
        --map 'joined.replay the 33 joined fixtures=joined/replay 33 joined fixtures' \
        --map 'joined.author the 33 joined worlds=joined/author 33 joined worlds' \
        --twin '(cd upstream/petrus && PYTHONPATH=. "$(../../scripts/upstream-python)" -B ../../packages/petrus-dst/scripts/bench.py)'

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The server was `scripts/with-postgres`'s throwaway PostgreSQL 17.7 on 127.0.0.1 over TCP (`initdb` defaults, `fsync` on). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `codec.decode+encode 51 fixtures` | 6.47 ms | 29.3 ms | 4.53× | 4.49× | 3 of 3 | 6.47 ms, 6.53 ms, 6.4 ms | 29.3 ms, 29.3 ms, 29.2 ms |
| `codec.encode 51 fixtures` | 2.2 ms | 10.5 ms | 4.78× | 4.75× | 3 of 3 | 2.18 ms, 2.2 ms, 2.22 ms | 10.5 ms, 10.5 ms, 10.6 ms |
| `digest_json largest fixture` | 86.6 µs | 536 µs | 6.19× | 6.14× | 3 of 3 | 86.6 µs, 86.3 µs, 86.8 µs | 536 µs, 537 µs, 533 µs |
| `1000 workload draws` | 1.18 ms | 1.77 ms | 1.49× | 1.49× | 3 of 3 | 1.18 ms, 1.19 ms, 1.17 ms | 1.76 ms, 1.77 ms, 1.77 ms |
| `author+replay 400 generated scripts` | 67.9 ms | 226 ms | 3.33× | 3.26× | 3 of 3 | 69.3 ms, 67.9 ms, 67.2 ms | 226 ms, 226 ms, 226 ms |
| `fold queue-story progress` | 101 µs | 516 µs | 5.09× | 5.06× | 3 of 3 | 102 µs, 101 µs, 101 µs | 517 µs, 516 µs, 513 µs |
| `engine.replay the Engine-world fixtures` | 29.5 ms | 90.2 ms | 3.06× | 3.05× | 3 of 3 | 29.5 ms, 29.5 ms, 29.4 ms | 89.8 ms, 90.2 ms, 90.3 ms |
| `engine.author the Engine worlds` | 31.6 ms | 126 ms | 4.01× | 3.96× | 3 of 3 | 32 ms, 31.6 ms, 31.5 ms | 127 ms, 126 ms, 126 ms |
| `joined.replay the 33 joined fixtures` | 3.71 s | 4.11 s | 1.11× | 1.10× | 5 of 5 | 3.71 s, 3.77 s, 3.63 s, 3.69 s, 3.72 s | 4.12 s, 4.13 s, 4.08 s, 4.11 s, 4.09 s |
| `joined.author the 33 joined worlds` | 3.66 s | 4.15 s | 1.13× | 1.10× | 5 of 5 | 3.66 s, 3.61 s, 3.69 s, 3.64 s, 3.67 s | 4.08 s, 4.16 s, 4.15 s, 4.02 s, 4.15 s |

The two Engine rows run four of their worlds over the SQLite
LocalDispatch, so they go through petrus-sqlite's parameter binds, which
`c33829e` guards with a length check; they read 3.06× and 4.01× here,
against 3.07× and 3.95× at `f82d998`.

The isolated-database row is the server's work on both sides: `CREATE
DATABASE` (a copy of `template1`), the two schemas and `DROP DATABASE ...
WITH (FORCE)`, over three connections. The joined rows read under 1.15×
after the three repetitions above, so they got two more, 04:17–04:20
local, load average 3.49–3.90, of

    scripts/bench-compare petrus-dst 2 --pattern joined \
        --map 'joined.one isolated database (create, both schemas, drop)=joined/one isolated database' \
        --map 'joined.replay the 33 joined fixtures=joined/replay 33 joined fixtures' \
        --map 'joined.author the 33 joined worlds=joined/author 33 joined worlds' \
        --twin '(cd upstream/petrus && PYTHONPATH=. "$(../../scripts/upstream-python)" -B ../../packages/petrus-dst/scripts/bench.py joined/)'

and the replay and authoring lines above pool all five (1.10× and 1.10× at
`f82d998`). Over the same five the isolated database reads 1.08× (57.8 ms
against 62.2 ms, Haskell ahead in 4 of 5, 0.98× at the lowest; Haskell
57.0–59.4 ms, Python 57.6–64.2 ms). It is close to level, as before, and
was not investigated further: the statements are the same on both sides and
the time is the server's. At `f82d998` it read 0.97× (65.2 ms against
63.0 ms, Haskell ahead in 2 of 5), and at `81bbdc5`, in the five-repetition
run then, 0.99× (55.3 ms against 54.6 ms, 0.95× at the lowest). That
commit's run of the row alone, 15 interleaved repetitions on 2026-10-12, 04:52–04:55 local, load average
1.86–2.75, of

    scripts/bench-compare petrus-dst 15 --pattern isolated \
        --map 'joined.one isolated database (create, both schemas, drop)=joined/one isolated database' \
        --twin '(cd upstream/petrus && PYTHONPATH=. "$(../../scripts/upstream-python)" -B ../../packages/petrus-dst/scripts/bench.py "joined/one isolated")'

put the two sides level: 53.3 ms against 53.1 ms, Haskell ahead in 9 of
the 15 repetitions, the per-repetition ratios spread from 0.90× to 1.08×
around a median of 1.01×.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `joined.one isolated database (create, both schemas, drop)` | 53.3 ms | 53.1 ms | 1.00× | 0.90× | 58.6 ms, 52.2 ms, 52.9 ms, 54.3 ms, 53.4 ms, 52.6 ms, 53.3 ms, 52.1 ms, 51.8 ms, 51.8 ms, 53.9 ms, 51.6 ms, 53.3 ms, 53.9 ms, 53.9 ms | 52.8 ms, 51.7 ms, 52.1 ms, 53.1 ms, 52.1 ms, 56.6 ms, 54.5 ms, 52.4 ms, 53.3 ms, 52.1 ms, 54 ms, 49.3 ms, 56.5 ms, 56.7 ms, 56.7 ms |

## Earlier figures

- Machine: Apple M4, 24 GB, macOS 26.3.1
- Haskell: GHC 9.10.3, library `-O2`, benchmark `-O2`
- Python: CPython 3.14.6, the reference's locked environment (`uv run --frozen`), petrus at
  `3f85fc2`
- Date: 2026-10-10

<!-- bench: superseded -->

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

<!-- bench: superseded -->

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
against 571 µs for the digest. petrus-json's general `dumps` then built every string one
character at a time and threaded an `Either` through every node, so a dedicated canonical
encoder (`Petrus.Testing.Dst.Internal.Canonical`) was written here. Since then petrus-json's
`dumps` writes straight into one buffer. An A/B on 2026-10-12 found it about twice as fast as
the dedicated encoder, so `canonicalBytes` is `dumps` again and the dedicated encoder is gone.
The A/B ran on the Apple M4 at a one-minute load average of about 5, with five interleaved
repetitions of each variant's benchmark executable. Each cell is the median of the five
tasty-bench means:

| row | dedicated encoder | petrus-json `dumps` (now) | Python |
| --- | ---: | ---: | ---: |
| `codec.encode` | 5.05 ms | 2.48 ms | 10.5 ms |
| `digest` | 206 µs | 95.3 µs | 533 µs |
| decode and encode | 10.1 ms | 7.15 ms | 29.3 ms |

## Rerun

From the repository root. The joined rows run only with `PETRUS_TEST_POSTGRES` set to a
server where the role may create databases, on both sides; `scripts/bench petrus-dst` runs
this block under `scripts/with-postgres`, which starts a throwaway server when the variable is
unset. `cabal bench` runs the benchmark from the package directory, where it reads its
fixtures; `scripts/upstream-python` provisions the pinned reference.

<!-- scripts/bench: rerun -->
```sh
# Every row; the joined rows need PETRUS_TEST_POSTGRES.
scripts/bench-run petrus-dst --stdev 5 +RTS -M2G -RTS
(cd upstream/petrus && PYTHONPATH=. "$(../../scripts/upstream-python)" -B ../../packages/petrus-dst/scripts/bench.py)
```

The Python script takes a name filter (`bench.py joined/`), and tasty-bench a pattern
(`--benchmark-options='-p joined'`), to run the joined rows alone.

Every Haskell row is timed in wall-clock time (`localOption WallTime` in `bench/Bench.hs`),
like the Python side; the joined rows always were (`--time-mode wall`). The other rows were
taken in tasty-bench's default CPU time; they are single-threaded and do no I/O inside the
timed region, so the two agree (see
[CPU and wall-clock time](../../../docs/reproducing.md#cpu-and-wall-clock-time)).
