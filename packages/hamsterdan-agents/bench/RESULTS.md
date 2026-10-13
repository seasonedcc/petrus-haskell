# hamsterdan-agents benchmarks

<!-- scripts/bench: measured sources e5b795610d0b1e87 at fcc77016965a -->

These are the agent adapter's hot paths:

- **Prompt:** `encode_prompt("review", url, request)`, the exact envelope of
  a review request with five lenses, context paths, two evidence entries
  and three prior comments.
- **Result:** `_parse_result` and `_validate_result("review", ...)` of an
  eight-finding blocking review with lineage.
- **Archive admission:** `_validated_entries` of a 200-file settled
  workspace archive (ten directories of twenty 1 KiB files).
- **Sealed key:** `PersistentKeyOperations.seal` then `open` of connection
  state under one context. The key is loaded from its file each time.
- **Route claim:** `AgentRouteStore.claim` of a new operation then
  `settle`, on one long-lived store.
- **Agent turn:** one scripted Pi review through `PiNativeRunner`, from a
  fresh state directory:
  1. `_compose_agent_runtime`: the workspace receiver, then
     `compose_owned_pi_a2` over Petrus's deterministic scripted Pi runtime
     (the installation binding, the persistent keys, the Pi A2 store).
  2. The review: clone of a local repository at the PR head, the review
     inputs, the workspace archive, the prompt, the scripted turn, result
     validation, the operation bodies and ledger.
  3. Close the runtime and remove the directory.

`make_inputs.py` writes the inputs (`inputs.json`); the agent turn builds
its repository with fixed identities and dates
(`Hamsterdan.Host.Scripted.deterministicRepository` and its twin in
`bench.py`), so both sides review the same commits.

## Current figures

Measured on 2026-10-12, 21:09–21:11 local (UTC-3), at commit `1427bb8`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 3.07–3.84:
five interleaved repetitions, alternating which side goes first, of

    TMPDIR="$PWD/bench-results/tmp" scripts/bench-compare hamsterdan-agents 5 --haskell-arg=-j1 --twin '"$(scripts/upstream-python hamsterdan)" -I -B packages/hamsterdan-agents/bench/bench.py'

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `agents.prompt/encode a review prompt` | 9.5 µs | 31.7 µs | 3.34× | 3.23× | 5 of 5 | 9.27 µs, 9.52 µs, 9.86 µs, 9.45 µs, 9.5 µs | 31.3 µs, 31.7 µs, 31.8 µs, 31.4 µs, 31.7 µs |
| `agents.result/parse and validate an 8-finding review result` | 25.9 µs | 47.7 µs | 1.84× | 1.81× | 5 of 5 | 25.4 µs, 25.3 µs, 26.3 µs, 26 µs, 25.9 µs | 47.5 µs, 47.7 µs, 47.6 µs, 48 µs, 48.1 µs |
| `agents.archive/admit a 200-file settled workspace archive` | 613 µs | 3.26 ms | 5.32× | 5.22× | 5 of 5 | 606 µs, 609 µs, 613 µs, 627 µs, 613 µs | 3.26 ms, 3.26 ms, 3.29 ms, 3.27 ms, 3.26 ms |
| `agents.keys/seal and open connection state` | 38.9 µs | 40.5 µs | 1.04× | 1.02× | 5 of 5 | 39.1 µs, 38.8 µs, 39.3 µs, 38.8 µs, 38.9 µs | 40.1 µs, 40.4 µs, 40.5 µs, 41.2 µs, 40.6 µs |
| `agents.routes/claim and settle one operation` | 98.8 µs | 169 µs | 1.71× | 1.66× | 5 of 5 | 99.1 µs, 101 µs, 97.1 µs, 98.8 µs, 97.3 µs | 168 µs, 168 µs, 171 µs, 169 µs, 170 µs |
| `agents.agent turn/one scripted Pi review through the Pi native runner` | 123 ms | 129 ms | 1.05× | 1.02× | 5 of 5 | 117 ms, 125 ms, 120 ms, 125 ms, 123 ms | 130 ms, 128 ms, 128 ms, 136 ms, 129 ms |

Haskell was ahead in every repetition of every row. The two closest rows
are `keys` and the agent turn.

The agent turn reads 1.05× here (123 ms against 129 ms; lowest repetition
1.02×), against 1.10× at `2ee3287` (19:22–19:24, load 3.25–3.86, five
repetitions: 125 ms against 138 ms) and 1.16× in the table at `81bbdc5`
(04:36–04:37, load 2.32–2.76, three repetitions: 109 ms against 126 ms).
The Haskell side has read 117–127 ms in every repetition since, at a higher
load than then; the row drives a scripted Pi review through the native
runner, with a Git clone and the runtime's stores, so it is as much
process start-up and file-system work as code.

The `keys` row is close to level (1.04×; 1.02× at `2ee3287` and at `81bbdc5`), and its
Haskell figure is higher than the 31.4 µs of the table below. Most of that
is where the row's key files live, not the code: the row seals connection
state into files under `TMPDIR`, which this run pointed into the checkout.
Run on its own after the `81bbdc5` table (05:22, load 2.4), three times a
side, the row read
33.6–34.4 µs in Haskell and 36.0–36.8 µs in Python with the default
`TMPDIR` (`/var/folders/…`), and 37.2–38.2 µs against 39.2–40.8 µs with
`TMPDIR` in the checkout: both sides about 10% slower there, and Haskell
ahead by 1.06–1.07× in each pairing. (The Python figures are the best of
five repeats, the Haskell ones tasty-bench means.)

## Results

The machine was an Apple M4 (10 cores), macOS 26.3.1, shared with other
work. The load average was 5.1–6.0 during these runs (`uptime` after each
run).

- **Haskell:** GHC 9.10.3 with `-O2`, `tasty-bench`, run with `-j1` and
  `+RTS -M2G`, every row in wall-clock time (`localOption WallTime`). The
  agent turn spends much of its time in git child processes and file system
  calls, which tasty-bench's default CPU time does not count. Each cell is
  that benchmark's mean, from the CSV.
- **Python:** CPython 3.14.6, the reference's pinned environment. Each cell
  is the best of 5 `timeit` repeats, each about half a second of passes.
- **Interleaving:** two rounds per side, run as Haskell, Python, Haskell,
  Python. The table shows each side's better round.

<!-- bench: superseded -->

| Operation (one pass) | Haskell | Python | Python / Haskell |
| --- | ---: | ---: | ---: |
| prompt (review envelope) | 10.8 µs | 32.0 µs | 3.0× |
| result (parse and validate 8 findings) | 24.4 µs | 49.8 µs | 2.0× |
| archive admission (200 files) | 871 µs | 3.41 ms | 3.9× |
| sealed key (seal then open) | 31.4 µs | 39.0 µs | 1.24× |
| route claim (claim then settle) | 113 µs | 172 µs | 1.52× |
| agent turn (one scripted Pi review) | 127 ms | 146 ms | 1.15× |

Haskell is faster on every row, in both rounds. The other rounds were:
Haskell 11.0 µs, 29.3 µs, 990 µs, 31.6 µs, 126 µs and 129 ms; Python
32.2 µs, 50.6 µs, 3.41 ms, 42.3 µs, 184 µs and 154 ms.

About 120 ms of the agent turn is the workspace (`git clone`, checkout and
the review inputs, all child processes, on both sides). The scripted Pi turn
itself, from start to the settled output, takes about 8 ms in Haskell.

Two rows were once slower in Haskell:

- **Sealed key** measured 131 µs at first, against Python's 43 µs. crypton's
  `getRandomBytes` in `IO` opens `/dev/random` and `/dev/urandom` on every
  call, and every seal draws a fresh nonce. petrus-json's `randomBytes`
  (then `Hamsterdan.Host.Random.urandom`) calls `getentropy(2)`, as `os.urandom` does. Every key load also encoded
  the key path from a `FilePath` for each POSIX call; the store now encodes
  its root once and stats and opens the key by its raw path. On both sides
  most of what remains is macOS's `open(2)`.
- **Agent turn** measured 240 ms against Python's 219 ms in one early run,
  under heavier load from other work on the machine. A stage-by-stage
  trace of the same build then showed no stage slower than Python's, and
  every interleaved run since has Haskell ahead.

## Rerun

From the repository root, alternating the two sides (`scripts/bench
hamsterdan-agents` runs exactly this block; `scripts/upstream-python
hamsterdan` provisions the pinned reference). The benchmark measures every
row in wall-clock time; `--time-mode wall` says so on the command line too.
The Haskell scratch directory has a fixed name under `TMPDIR`, so the block
gives each run a private one.

<!-- scripts/bench: rerun -->
```sh
export TMPDIR="$BENCH_TMP/tmp" && mkdir -p "$TMPDIR"
scripts/bench-run hamsterdan-agents -j1 --time-mode wall --csv "$BENCH_TMP/hamsterdan-agents.csv" +RTS -M2G -RTS
cat "$BENCH_TMP/hamsterdan-agents.csv"
"$(scripts/upstream-python hamsterdan)" -I -B packages/hamsterdan-agents/bench/bench.py
```

`cabal bench` runs in the package directory, where the benchmark reads
`bench/inputs.json`. Read the Haskell numbers from the CSV. `bench.py` finds
its inputs relative to itself. Run `make_inputs.py` with the same
interpreter to regenerate `inputs.json`. Note `uptime` before and after
each run.
