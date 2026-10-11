# Codex, Claude and Amp host benchmark results

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

## Results

Environment:

- Apple M4, macOS (Darwin 25.3), APFS.
- GHC 9.10.3. The benchmark is built with `-O2` and run with
  `+RTS -A32m -M2G`.
- CPython 3.14.6.

Haskell times are tasty-bench means. Python times are medians of 7 batches.

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

Every row is at least as fast as the reference.

Not benchmarked:

- **Whole Turns.** A Local Codex Turn runs the fake `codex` CLI and the
  private helper as Python subprocesses, and a Gondolin Turn adds the
  fake SDK under `node`. Claude and Amp Turns run the official SDK in a
  Python sidecar (the port) or in-process (the reference). Interpreter
  start-up and file-system work dominate all of these, so they would measure
  the fixtures, not the hosts.
- **The A3 runtime service round trip.** One Unix-socket request plus a
  SQLite ledger commit (`synchronous = FULL`), dominated by fsync.

## Rerun

```sh
cabal bench petrus-agenticus-runtime-bench \
  --benchmark-options="-p '/codex-/ || /claude-/ || /amp-/' +RTS -M2G -RTS"
cd upstream/petrus && .venv/bin/python ../../packages/petrus-agenticus-runtime/bench/python_hosts.py
```
