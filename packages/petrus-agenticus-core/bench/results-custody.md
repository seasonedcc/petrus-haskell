# agenticus-custody benchmark results

<!-- scripts/bench: measured sources b5dffc98cbfa603a at 209e8d8c2a6b -->

These are twin workloads: `bench/Bench/Custody.hs` and
`bench/python_custody.py`, which runs the pinned reference
(`upstream/petrus` @ 3f85fc2).

Each run starts from a fresh installation: a SQLite store plus a
materialization root, with 3 enrolled hosts and 10 authorized connections.
It then runs N materialize(read)/release cycles. Cycle `i` uses connection
`i mod 10` and host `i mod 3`, with a TTL of 60 s on a fixed clock.

Every operation is one full custody commit:

- load the store (read the SQLite row, decode, validate);
- check for an operation conflict;
- transform the snapshot;
- run the CAS (validate, encode, `BEGIN IMMEDIATE`, `UPDATE`, `COMMIT`);
- do the private-file work (create plus fsync on materialize, overwrite plus
  unlink on release).

The audit log and the released leases are part of the payload, so they grow
with every operation. In both implementations the cost per operation is
therefore linear in the operations so far, and the total is quadratic in N.

The table reports, for each operation kind, the median wall time over the N
cycles, plus the total wall time of the N cycles. Each implementation runs
with its reference pragmas (`synchronous = FULL`). A second set of rows uses
`synchronous = OFF`, which separates the CPU cost from the fsync cost.

## Results

Environment:

- Apple M4, macOS (Darwin 25.3).
- GHC 9.10.3 with `-O2`, run with `+RTS -M2G -A32m`.
- CPython 3.14.6 with SQLite 3.53.4. The Haskell side uses direct-sqlite's
  bundled SQLite 3.45.0.
- Other agents were sharing the machine, so expect roughly ±10% noise.

| sync | N | materialize p50 (Haskell / Python) | release p50 (Haskell / Python) | total (Haskell / Python) | Python / Haskell (total) |
| --- | ---: | ---: | ---: | ---: | ---: |
| FULL | 100 | 1.02 ms / 5.74 ms | 0.98 ms / 3.85 ms | 0.209 s / 0.975 s | 4.7× |
| FULL | 1000 | 8.04 ms / 40.6 ms | 7.97 ms / 26.6 ms | 17.3 s / 69.5 s | 4.0× |
| FULL | 5000 | 64.7 ms / 206.3 ms | 64.6 ms / 135.1 ms | 638 s / 1701 s | 2.7× |
| OFF | 100 | 1.31 ms / 4.96 ms | 1.26 ms / 3.28 ms | 0.247 s / 0.834 s | 3.4× |
| OFF | 1000 | 9.29 ms / 40.3 ms | 8.94 ms / 26.1 ms | 18.6 s / 65.4 s | 3.5× |
| OFF | 5000 | 65.1 ms / not run | 64.5 ms / not run | 640 s / not run | — |

The Python OFF run at N = 5000 was skipped because it takes about 30
minutes. The FULL row already shows the large-N trend. At every size, OFF and
FULL are within noise of each other. macOS `fsync` does not flush the drive
cache (`F_FULLFSYNC`), so this workload is CPU-bound in both implementations.

## Fixes

The first port was a literal translation. At N = 1000 (FULL) it was barely
faster than the reference:

| Version | materialize p50 | release p50 | total |
| --- | ---: | ---: | ---: |
| Literal port | 35.8 ms | 25.4 ms | 68.6 s |
| Reference | 40.6 ms | 26.6 ms | 69.5 s |

Like the reference, each commit parsed and validated the loaded payload,
validated it again in `_load`, validated the replacement in
`compare_and_swap`, and validated it again in `_encode`. Profiling at
N = 300 (264 KB payload) attributed about 4.8 ms per op to the load, 2.1 ms
to each validation, and 8.3 ms to the encode.

Three changes cut this by about 4×. None of them is observable;
`divergences/custody.md` §11–12 covers them in full.

1. **One validation per CAS.** `_encode`'s second validation of the same
   value is redundant, because validation is pure.
2. **Decoded-snapshot cache.** Each SQLite connection keeps the last payload
   text it read or wrote, together with its snapshot. A load whose row text
   is byte-identical reuses the snapshot. The row is still read every time,
   so a concurrent writer's change is decoded normally. The custody's
   re-validation of an object already accepted is skipped through a
   `StableName` memo.
3. **Pre-sorted payload members.** The payload is emitted in `sort_keys`
   order, so the encoder skips its per-object sort.

The corpus replay (30 sessions × 50 steps with exact payload bytes) and the
cross-implementation interop spec both pass with these changes.

## Remaining cost and scaling

At large N, each Haskell op is dominated by three things:

- validating the replacement, which is linear in the audit log;
- encoding the roughly 4 MB payload. petrus-json's encoder pre-scans for
  non-finite floats and then builds a lazy `ByteString`; the reference uses C
  `json.dumps`;
- GC copying the live snapshot.

Haskell's advantage therefore narrows as N grows: about 4.7× at 100 and
about 2.7× at 5000. Two further options were not pursued, because they would
change the code's shape rather than remove redundancy:

- Incremental validation and encoding of the append-only audit log, by
  caching per-record fragments.
- A faster petrus-json encoder, which is shared work.
