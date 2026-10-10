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
| replay the 14 Engine-world fixtures through real Engine profiles | 61.4 ms | 23.2 ms | 2.6× |
| author the 14 Engine worlds (the reference's `build_*_artifact`) | 62.7 ms | 21.3 ms | 2.9× |

Haskell is faster on every workload.

The two Engine rows were measured later the same day, with other builds running on the
machine, so their absolute times are noisier than the rows above. Both sides were measured
back to back under the same load. During that run Python's `decode + encode` row measured
48.5 ms, against 30.7 ms quiet.

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
- **Engine authoring**: every `Spec.EngineWorlds.authorCases` story runs on a fresh History.
  This covers the executable, seeded, and failure stories of `engine_world`, `delayed_world`,
  `delivery_world`, `timer_world` and `lifecycle_world`. Each produces and encodes its
  artifact. The Python side calls the reference's `build_*_artifact` functions.

The first measurement had Haskell slower on encoding: 24.2 ms against 11.4 ms, and 1.05 ms
against 571 µs for the digest. petrus-json's general `dumps` builds every string one character
at a time and threads an `Either` through every node. `Petrus.Testing.Dst.Internal.Canonical`
now specializes the one canonical spelling. It copies plain-ASCII strings in one piece, and it
scans for non-finite floats once, up front. Two checks keep it byte-identical to `dumps`:

- a QuickCheck property over generated JSON (escapes, control characters, astral text,
  non-finite floats, key order);
- the fixture and mutation corpora.

## Rerun

Haskell, from the repository root (the benchmark reads fixtures relative to the package
directory):

```sh
cabal build petrus-dst:bench:petrus-dst-bench
cd packages/petrus-dst && $(cabal list-bin petrus-dst:bench:petrus-dst-bench) --stdev 5
```

Python, from `upstream/petrus`:

```sh
PYTHONPATH=. uv run --frozen python ../../packages/petrus-dst/scripts/bench.py
```
