# hamsterdan-agents benchmarks

<!-- scripts/bench: measured sources be5492ab6c81e8c6 at 5b060ba21cb6 -->

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
cabal bench -j2 hamsterdan-agents --benchmark-options="-j1 --time-mode wall --csv $BENCH_TMP/hamsterdan-agents.csv +RTS -M2G -RTS"
cat "$BENCH_TMP/hamsterdan-agents.csv"
"$(scripts/upstream-python hamsterdan)" -I -B packages/hamsterdan-agents/bench/bench.py
```

`cabal bench` runs in the package directory, where the benchmark reads
`bench/inputs.json`. Read the Haskell numbers from the CSV. `bench.py` finds
its inputs relative to itself. Run `make_inputs.py` with the same
interpreter to regenerate `inputs.json`. Note `uptime` before and after
each run.
