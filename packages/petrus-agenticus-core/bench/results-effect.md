# agenticus-effect benchmark results

<!-- scripts/bench: measured sources 2a4f7fce681fe31a at c76ae2d20d51 -->

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

## Results

Environment:

- Apple M4, macOS (Darwin 25.3).
- GHC 9.10.3, `-O2`, run with `+RTS -A32m`.
- CPython 3.14.6.

Haskell times are tasty-bench means; Python times are medians of 7 batches.

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
