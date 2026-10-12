# agenticus-effect benchmark results

<!-- scripts/bench: measured sources 6dfbc2563f96dee2 at 5a73d7a7f019 -->

Twin workloads: `bench/Bench/Effect.hs` (tasty-bench) and
`bench/python_effect.py` (the pinned reference, `upstream/petrus` @ 3f85fc2).

- `digest-*`: `digest_payload` over nested payloads of 1 054, 100 140 and
  1 000 088 canonical bytes. Each payload holds records with Unicode and
  escaped strings, integers up to 2^64, bools, nulls, and nested objects and
  lists. Haskell starts from decoded `Json`, as the reference starts from a
  dict. Before timing, the bench checks each payload's digest against the
  digests the reference prints.
- `digest-1MB-strict-payload` (Haskell only): the same 1 MB payload, already
  admitted as an `EffectPayload`. It measures only the canonical write and
  SHA-256.
- `gateway-execute`: `EffectGateway.execute` with an in-memory adapter on
  the first-execution path: lookup says safe-to-retry, then the fresh fence,
  then execute.
- `gateway-replay`: the replay path, where the lookup finds the applied
  receipt.

## Current figures

Measured on 2026-10-12, 03:07–03:16 local (UTC-3), at commit `81bbdc5`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.18–2.54:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-agenticus-core 3 --python python_catalog.py --python python_effect.py --python python_hands.py --python python_thread.py

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The same three repetitions measured the other results files' rows (see [RESULTS.md](RESULTS.md)). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `effect.digest-1KB` | 8.43 µs | 36.8 µs | 4.36× | 4.33× | 8.45 µs, 8.43 µs, 8.39 µs | 36.8 µs, 36.5 µs, 36.9 µs |
| `effect.digest-100KB` | 723 µs | 2.85 ms | 3.94× | 3.91× | 721 µs, 723 µs, 725 µs | 2.88 ms, 2.83 ms, 2.85 ms |
| `effect.digest-1MB` | 8.92 ms | 29.1 ms | 3.26× | 3.22× | 8.89 ms, 9.04 ms, 8.92 ms | 29.3 ms, 29.1 ms, 28.8 ms |
| `effect.digest-1MB-strict-payload` | 5.05 ms | — | — | — | 5.04 ms, 5.09 ms, 5.05 ms |  |
| `effect.gateway-execute` | 1.75 µs | 22.1 µs | 12.60× | 12.58× | 1.74 µs, 1.75 µs, 1.76 µs | 22.2 µs, 22.1 µs, 22.1 µs |
| `effect.gateway-replay` | 1.71 µs | 21.5 µs | 12.54× | 12.50× | 1.72 µs, 1.71 µs, 1.71 µs | 21.4 µs, 21.5 µs, 21.5 µs |

## Results

Environment:

- Apple M4, macOS (Darwin 25.3).
- GHC 9.10.3, `-O2`, run with `+RTS -A32m`.
- CPython 3.14.6.

Haskell times are tasty-bench means; Python times are medians of 7 batches.

<!-- bench: superseded -->

| Benchmark | Haskell | Python | Python / Haskell |
| --- | ---: | ---: | ---: |
| digest-1KB | 13.6 µs | 41.0 µs | 3.0× |
| digest-100KB | 1.28 ms | 3.18 ms | 2.5× |
| digest-1MB | 15.2 ms | 32.7 ms | 2.2× |
| digest-1MB-strict-payload | 7.89 ms | — | — |
| gateway-execute | 2.71 µs | 24.7 µs | 9.1× |
| gateway-replay | 2.53 µs | 24.4 µs | 9.6× |

### Where the time goes

**Digests.** `_payload_copy` in the reference takes three steps:

1. Canonical `json.dumps`.
2. `json.loads` of that output.
3. A second canonical dump, for the digest.

The Haskell port does the work once:

1. Admit the payload as a float-free `PayloadValue`. Its objects are `Map`s,
   which already iterate in `sort_keys` order.
2. Write the canonical bytes straight into a lazy `Builder`. Strings are
   escaped per byte with `encodeUtf8BuilderEscaped`.
3. Hash the bytes with `hashlazy` as they stream.

On the strict row, about half the from-`Json` time goes to admission, that
is, building the maps.

**Gateway.** The reference recomputes `proposal.digest` five times per call
(one SHA-256 over a canonical dump each time). The calls are:

- approval check;
- receipt correlation;
- `_outcome` ×2;
- the evidence constructor's re-validation.

The Haskell `EffectProposal` caches its digest lazily.

## Rerun

```sh
# Haskell (from the repository root)
scripts/bench-run petrus-agenticus-core -p effect

# Python reference
cd upstream/petrus
.venv/bin/python ../../packages/petrus-agenticus-core/bench/python_effect.py
```
