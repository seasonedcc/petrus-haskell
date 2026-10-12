# Codex, Claude and Amp host benchmark results

<!-- scripts/bench: measured sources baf81cf78b32471f at f12e7471cb61 -->

These are twin workloads, run by the tasty-bench runner `bench/Main.hs`
(`bench/HostsBench.hs`) and by `bench/python_hosts.py` against the pinned
reference (`upstream/petrus` @ 3f85fc2). They cover the hosts' own protocol
work: the code that runs once per provider event, frame or Turn.

- `codex-jsonl-parse`: `_parse_jsonl` over one completed `codex exec --json`
  stream of 205 events (about 19 KB): `thread.started`, `turn.started`, 100
  reasoning items (started and completed), two agent messages and
  `turn.completed`.
- `codex-helper-parse`: `_parse_helper(..., collect=True)` over the private
  helper's `collect` reply.
- `codex-terminal-encode`: `_json_bytes` of one A3 runtime-service success
  terminal.
- `codex-terminal-parse`: `_parse_terminal` of that frame, correlated with
  its operation, Episode and Turn.
- `claude-transcript-encode`: `_encode_transcript` of 200 transcript entries
  (about 29 KB).
- `claude-transcript-decode`: `_decode_transcript` of those bytes, including
  the canonical re-encoding check.
- `claude-canonical-input`: `_canonical_input` of one MCP tool input.
- `claude-sanitize`: `_sanitize` of a 4 KB result with ANSI escapes.
- `amp-stream-admit`: `_read_stream` over `system/init`, 200 assistant events
  and a success `result`. Each event is sized from its compact JSON, as the
  SDK's `model_dump_json` does. The Python side sends into the coroutine
  directly, so no event loop is timed.
- `amp-final-text`: `_safe_final_text` of the same 4 KB text.

## Current figures

Measured on 2026-10-12, 02:57–03:06 local (UTC-3), at commit `81bbdc5`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.26–2.93:
five interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-agenticus-runtime 5 --python python_runner.py --python python_pi.py --python python_pi_a2.py --python python_hosts.py --python python_bench.py

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The same five repetitions measured the rows of [RESULTS.md](RESULTS.md) and [results-pi.md](results-pi.md). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `codex-jsonl-parse` | 114 µs | 223 µs | 1.95× | 1.93× | 114 µs, 114 µs, 115 µs, 114 µs, 114 µs | 222 µs, 227 µs, 221 µs, 224 µs, 223 µs |
| `codex-helper-parse` | 442 ns | 944 ns | 2.14× | 2.10× | 442 ns, 436 ns, 440 ns, 442 ns, 442 ns | 939 ns, 953 ns, 924 ns, 947 ns, 944 ns |
| `codex-terminal-encode` | 1.17 µs | 2.61 µs | 2.23× | 2.19× | 1.17 µs, 1.17 µs, 1.18 µs, 1.17 µs, 1.17 µs | 2.67 µs, 2.61 µs, 2.63 µs, 2.56 µs, 2.59 µs |
| `codex-terminal-parse` | 4.78 µs | 12.9 µs | 2.69× | 2.64× | 4.74 µs, 4.78 µs, 4.89 µs, 4.78 µs, 4.81 µs | 13.1 µs, 12.7 µs, 12.9 µs, 12.9 µs, 12.9 µs |
| `claude-transcript-encode` | 150 µs | 546 µs | 3.64× | 3.59× | 152 µs, 149 µs, 150 µs, 151 µs, 149 µs | 550 µs, 543 µs, 546 µs, 543 µs, 549 µs |
| `claude-transcript-decode` | 326 µs | 1.09 ms | 3.35× | 3.32× | 325 µs, 327 µs, 326 µs, 329 µs, 325 µs | 1.09 ms, 1.09 ms, 1.09 ms, 1.09 ms, 1.1 ms |
| `claude-canonical-input` | 499 ns | 1.64 µs | 3.28× | 3.26× | 501 ns, 495 ns, 500 ns, 499 ns, 497 ns | 1.66 µs, 1.66 µs, 1.63 µs, 1.64 µs, 1.64 µs |
| `claude-sanitize` | 73.6 µs | 126 µs | 1.71× | 1.70× | 73.6 µs, 74 µs, 73.4 µs, 73.7 µs, 73.4 µs | 126 µs, 127 µs, 126 µs, 126 µs, 125 µs |
| `amp-stream-admit` | 90.5 µs | 417 µs | 4.60× | 4.53× | 91.7 µs, 90.5 µs, 90 µs, 90.2 µs, 90.6 µs | 416 µs, 414 µs, 417 µs, 419 µs, 420 µs |
| `amp-final-text` | 72 µs | 113 µs | 1.57× | 1.55× | 71.6 µs, 71.8 µs, 72 µs, 72.9 µs, 72.6 µs | 112 µs, 113 µs, 113 µs, 113 µs, 112 µs |
| `codex-turn` | 46.4 ms | 62.7 ms | 1.35× | 1.31× | 46.4 ms, 46.1 ms, 47.8 ms, 46.4 ms, 47.4 ms | 62.7 ms, 63.1 ms, 62.4 ms, 63.1 ms, 62.2 ms |
| `codex-a3-service-turn` | 1.12 s | 1.25 s | 1.12× | 1.10× | 1.14 s, 1.12 s, 1.12 s, 1.12 s, 1.12 s | 1.26 s, 1.25 s, 1.25 s, 1.26 s, 1.25 s |
| `claude-turn` | 8.26 ms | 11 ms | 1.33× | 1.28× | 8.35 ms, 8.26 ms, 8.12 ms, 8.52 ms, 8.2 ms | 11 ms, 11 ms, 10.9 ms, 10.9 ms, 11 ms |
| `amp-turn` | 168 µs | 192 µs | 1.14× | 1.13× | 169 µs, 168 µs, 167 µs, 168 µs, 168 µs | 192 µs, 190 µs, 193 µs, 191 µs, 192 µs |

## Results

Environment:

- Apple M4, macOS (Darwin 25.3), APFS.
- GHC 9.10.3. The benchmark is built with `-O2` and run with
  `+RTS -A32m -M2G`.
- CPython 3.14.6.

Haskell times are tasty-bench means. Python times are medians of 7 batches.

<!-- bench: superseded -->

| Benchmark | Haskell | Python | Python / Haskell |
| --- | ---: | ---: | ---: |
| codex-jsonl-parse | 144 µs | 266 µs | 1.8× |
| codex-helper-parse | 393 ns | 1.06 µs | 2.7× |
| codex-terminal-encode | 2.39 µs | 2.91 µs | 1.2× |
| codex-terminal-parse | 6.68 µs | 14.2 µs | 2.1× |
| claude-transcript-encode | 280 µs | 569 µs | 2.0× |
| claude-transcript-decode | 472 µs | 1.13 ms | 2.4× |
| claude-canonical-input | 732 ns | 1.77 µs | 2.4× |
| claude-sanitize | 61.0 µs | 136 µs | 2.2× |
| amp-stream-admit | 125 µs | 438 µs | 3.5× |
| amp-final-text | 68.0 µs | 124 µs | 1.8× |

Every row is at least as fast as the reference. The A3 runtime service's
round trip is measured whole, as `codex-a3-service-turn` below.

## Whole Turns

These rows take one whole Turn through each host: prompt in, events
streamed, ledger and stores written, settlement out, cleanup verified. The
twins are `bench/TurnsBench.hs` and `bench/python_bench.py`, which drives the
reference's own adapters. Both sides run the same fakes from `test/fixtures`
under the pinned CPython (`scripts/upstream-python`), with a fresh operation
id every call:

- `codex-turn`: open a Local Motus territory and its Episode Attachment,
  `start` (real connection custody over a SQLite ledger: materialize and
  activate; the fake `codex` CLI and the private helper's `collect` run as
  Python subprocesses; checkpoint and admission), `wait`, `close`, and
  settle the attachment (archive export and lease cleanup).
- `claude-turn`: open a Local Motus territory, its Episode Attachment, the
  Hands gateway and a grant, then `start` (custody materialization; the
  official `ClaudeSDKClient` of the fake `claude_agent_sdk`: its PreToolUse
  hook twice, one `workspace_read` through the gateway, the session store's
  `append`, three messages), `wait`, `close`, and settle the attachment.
- `amp-turn`: an Episode Attachment over the provider-managed binding, then
  `start` (the official `execute` of the fake `amp_sdk`: `system/init`, an
  assistant event and the `success` result), `wait`, `close`, and settle.
- `codex-a3-service-turn`: the A3 lane end to end over its host-local
  runtime service. Open a Gondolin Motus territory over the reference's
  fake Gondolin SDK (`test/fixtures/codex/fake_gondolin_codex.mjs`, under
  the system `node`; its guest commands run on the host) and its Episode
  Attachment, and probe the guest `codex`. Start the service on a fresh
  private state directory under the platform's temporary directory
  (`TMPDIR`, else `/tmp`), with its fence and SQLite
  replay ledger. Send one request through the Worker-side Activity client
  over the Unix socket: the service records the operation, runs one Codex
  Turn with the same custody as `codex-turn`, and stores and returns the
  terminal. Then close the service, remove its state directory, and settle
  the attachment.

The reference imports each SDK into its own interpreter. The port reaches
it through one shared sidecar process per SDK (`data/claude_sidecar.py`,
`data/amp_sidecar.py`), with one channel per client or stream, so every
SDK call, hook, tool call and event crosses a pipe. The connection keys are
reversible stand-ins on both sides, so the cipher is not measured.

Method: nine interleaved rounds on 2026-10-11 at 12:21–12:33 local
(UTC-3), load average 2.7 to 5.7, with `spawnPiped`'s non-blocking pipe
ends (see below). Each round ran the Haskell bench executable directly
(tasty-bench wall-clock means, `--stdev 5`, `+RTS -A32m -M2G`) and
`python_bench.py` (`scripts/bench_timing.py`: the median of 10 batches of
at least 0.2 s), alternating which side went first. That is what
`scripts/bench-compare petrus-agenticus-runtime 9 --pattern '/-turn/ &&
!/scripted/'` runs. The table gives the medians over the rounds and the
lowest single-round ratio. Haskell was ahead in every round of every row
except one `codex-a3-service-turn` round (0.96×).

<!-- bench: superseded -->

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition |
| --- | ---: | ---: | ---: | ---: |
| codex-turn | 51.5 ms | 64.4 ms | 1.25× | 1.10× |
| codex-a3-service-turn | 1.24 s | 1.25 s | 1.01× | 0.96× |
| claude-turn | 9.29 ms | 11.2 ms | 1.20× | 1.18× |
| amp-turn | 174 µs | 199 µs | 1.15× | 1.09× |

`codex-a3-service-turn`, round by round (Haskell / Python): 1.26 / 1.34,
1.24 / 1.36, 1.24 / 1.39, 1.32 / 1.61, 1.30 / 1.25, 1.13 / 1.25,
1.12 / 1.25, 1.11 / 1.25 and 1.11 / 1.24 s; the per-round ratios have a
median of 1.11×. Most of the second goes to the fake Gondolin SDK's `node`
process and the fake `codex` CLI's Python, the same on both sides.

**`--stdev 5`, not tighter.** These rows are stateful: every Turn adds an
operation to the custody ledger and the stores, and a Turn costs more the
more Turns came before it, in both implementations. bench_timing's 0.2 s
batches are sized to match tasty-bench at `--stdev 5` (see its docstring).
At `--stdev 3`, tasty-bench ran `codex-turn` for its full 75 s, about 1 500
Turns, and its mean rose to 82 ms ± 39 ms, against 44 ms at `--stdev 5`.
The reference grows faster over a run that long: `python_bench.py
codex-turn` with batches of 4 s (about 600 Turns) gave 268 ms per Turn. An
earlier round series at `--stdev 3` therefore showed `codex-turn` at
0.76–0.83×; it was the protocol, not the port.

**Non-blocking pipe ends.** That series also showed `amp-turn` at 236 µs
against Python's 195 µs (0.83×, behind in all nine rounds). The cause was
in the port. Helpers and sidecars had just moved to `spawnPiped`
(`posix_spawn`, see DIVERGENCES.md). It wrapped the parent's pipe ends with
`fdToHandle`, which makes blocking handles: every read and write then cost
a readiness poll and a safe foreign call. The `process` package makes its
pipe handles non-blocking, so that reads and writes wait in the IO manager.
`spawnPiped` now does the same, and `amp-turn` went back to 157–164 µs on
its own (174 µs in the table, taken alongside the other rows).

What it took:

- **One sidecar per SDK, not one per Turn.** The first version started a
  Python process per Claude client and per Amp stream: 193 ms and 172 ms a
  Turn, against 26 ms and 0.49 ms for the reference (0.13× and 0.003×),
  almost all of it interpreter start-up and SDK import. A shared sidecar
  imports the SDK once, as the reference does.
- **Eager pulls and fewer round trips.** The sidecar runs each SDK call as
  an eagerly started asyncio task on one loop that reads stdin through
  `add_reader`, and writes each answer straight to the pipe. The first Amp
  pull travels with the stream's request; a stream whose generator has
  stopped closes itself (its `athrow` and `aclose` would run no SDK code);
  the Claude `receive_response()` request is not awaited.
- **No retained thread stacks.** The Amp operation kept its worker's and
  consumer's `ThreadId` after they finished. A retained `ThreadId` keeps the
  thread's stack alive, about 64 KB per remembered operation, which
  exhausted the 2 GB heap within seconds of this benchmark.
- **One reusable read buffer** in the sidecar reader, where `hGetSome`
  allocated and pinned 64 KB per read.

Codex runs the same two Python subprocesses on both sides (about 20 ms of
interpreter start-up each), so its ratio is bounded by them. Its first
interleaved run had one Haskell repetition at 126 ms (load average 8.6),
the noise these subprocess-bound rows are open to on a shared machine.

### The run of 2026-10-11, 07:58–08:01

<!-- bench: superseded -->

`scripts/bench-compare petrus-agenticus-runtime 7 --pattern=-turn`,
seven interleaved repetitions of the Haskell bench (tasty-bench wall-clock
means, `--stdev 5`, the executable started directly) and `python_bench.py`
(median of 10 batches of 0.2 s), commit `24b53d7`, 2026-10-11 07:58–08:01
local, load average 2.46 to 3.03, each repetition alternating which side
went first. Helpers and sidecars were then started through the `process`
package. The table gives the medians over the repetitions and the
lowest single-repetition ratio; Haskell was ahead in every repetition of
every row.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition |
| --- | ---: | ---: | ---: | ---: |
| codex-turn | 47.1 ms | 62.8 ms | 1.33× | 1.26× |
| claude-turn | 8.27 ms | 10.9 ms | 1.32× | 1.22× |
| amp-turn | 161 µs | 196 µs | 1.22× | 1.21× |

`codex-turn`, repetition by repetition (Haskell / Python): 45.0 / 61.0,
46.0 / 65.0, 47.1 / 61.8, 46.7 / 66.9, 49.7 / 62.7, 48.5 / 65.0 and
47.6 / 62.8 ms. The 1.20× of the earlier run (below) was the same code at a
load of 3.9–5.3.

### The run of 2026-10-11, 03:08–03:30

<!-- bench: superseded -->

Five
interleaved repetitions of the Haskell bench (tasty-bench wall-clock means,
`--stdev 5`) and `python_bench.py` (median of 10 batches of 0.2 s), commit
`aa613ac`, 2026-10-11 03:08–03:30 local, load average 3.9 to 5.3 (the
machine was shared). The table gives the medians over the repetitions and
the lowest single-repetition ratio.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition |
| --- | ---: | ---: | ---: | ---: |
| codex-turn | 57.1 ms | 68.7 ms | 1.20× | 1.10× |
| claude-turn | 10.5 ms | 14.1 ms | 1.34× | 1.25× |
| amp-turn | 163 µs | 213 µs | 1.31× | 1.15× |

## Rerun

```sh
scripts/bench-run petrus-agenticus-runtime \
  -p '/codex-/ || /claude-/ || /amp-/' --time-mode wall +RTS -M2G -RTS
cd upstream/petrus && .venv/bin/python ../../packages/petrus-agenticus-runtime/bench/python_hosts.py
cd upstream/petrus && .venv/bin/python ../../packages/petrus-agenticus-runtime/bench/python_bench.py
```

The pattern also selects the whole-Turn rows. For the interleaved
comparison of those rows, run `scripts/bench-compare petrus-agenticus-runtime 9
--pattern '/-turn/ && !/scripted/'` from the repository root. The pattern
also selects the whole Pi Turns ([results-pi.md](results-pi.md)), whose
twins are in `python_bench.py` too; `!/scripted/` leaves out
`pi-a2-scripted-turn`, whose twin is `python_pi_a2.py`.
