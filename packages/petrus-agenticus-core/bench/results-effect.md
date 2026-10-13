# agenticus-effect benchmark results

<!-- scripts/bench: measured sources 58b8b899b48a81e2 at 13f7a84d2779 -->
<!-- scripts/bench: carried to 79b9a7598b6cb16d at c33829edc562: the petrus-json/posix/sqlite changes (loads refusal path, posix additions, SQLite bind length guard) are off the catalog, effect, hands and thread paths, which bind no SQLite -->
<!-- scripts/bench: carried to 625ff0185edc3f57 at f87d05b6f42b: since 50635f0, no behavior or representation change on the measured paths: petrus-sqlite's checkBindLength names the either throwIO pure . bindLength that bindAll and bindTextParam already ran; petrus-json's Json == compiles to the same optimized Core as at 50635f0 (-ddump-simpl compared; numericEq/intFloatEq moved as pyNumberEq/exactFloatEq into Petrus.Json.Value and inlined there), PyObject's pyEq likewise, pythonTruthy added; petrus-posix gains additions only (DirectFd, directFd, writeDirect) and docs -->

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

Measured on 2026-10-12, 22:18–22:26 local (UTC-3), at commit `424aa4e`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 1.80–2.65:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-agenticus-core 3 --python python_catalog.py --python python_effect.py --python python_hands.py --python python_thread.py

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The same three repetitions measured the other results files' rows (see [RESULTS.md](RESULTS.md)). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `effect.digest-1KB` | 6.9 µs | 36.9 µs | 5.35× | 5.32× | 3 of 3 | 6.9 µs, 6.9 µs, 6.9 µs | 37.2 µs, 36.7 µs, 36.9 µs |
| `effect.digest-100KB` | 660 µs | 2.83 ms | 4.30× | 4.28× | 3 of 3 | 660 µs, 662 µs, 659 µs | 2.82 ms, 2.83 ms, 2.84 ms |
| `effect.digest-1MB` | 11.8 ms | 29 ms | 2.46× | 2.44× | 3 of 3 | 11.8 ms, 11.8 ms, 11.9 ms | 28.8 ms, 29 ms, 29 ms |
| `effect.digest-1MB-strict-payload` | 4.17 ms | — | — | — | — | 4.16 ms, 4.17 ms, 4.17 ms |  |
| `effect.gateway-execute` | 1.44 µs | 22.2 µs | 15.41× | 15.34× | 3 of 3 | 1.45 µs, 1.42 µs, 1.44 µs | 22.2 µs, 22 µs, 22.2 µs |
| `effect.gateway-replay` | 1.4 µs | 21.7 µs | 15.55× | 15.17× | 3 of 3 | 1.39 µs, 1.43 µs, 1.4 µs | 21.8 µs, 21.7 µs, 21.7 µs |

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
