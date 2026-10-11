# Benchmark results

The Haskell backend against the upstream Node backend at the pin in
[UPSTREAM.md](../../../UPSTREAM.md), driven by one load client
(`petrus-viewer-bench`, a Haskell program) for every server.

## How to rerun

From the repository root (`scripts/bench petrus-viewer-server` runs exactly this block):

<!-- scripts/bench: rerun -->
```sh
test -d upstream/petrus-viewer/node_modules || (cd upstream/petrus-viewer && pnpm install --frozen-lockfile)
node packages/petrus-viewer-server/bench/run.mjs
```

Other ways to run it:

```bash
# from the repository root; needs `pnpm install` in upstream/petrus-viewer
node packages/petrus-viewer-server/bench/run.mjs                 # builds, 5 reps
node packages/petrus-viewer-server/bench/run.mjs --reps 9 --json out.json
node packages/petrus-viewer-server/bench/run.mjs --quick         # 1 short rep
node packages/petrus-viewer-server/bench/run.mjs --only relay    # one scenario family
node packages/petrus-viewer-server/bench/run.mjs --rts "-N4"     # other RTS options for petrus
cabal run petrus-viewer-bench -- micro --file upstream/petrus-viewer/examples/sample-net.json
```

The runner starts every server once on its own non-default port (from
47310), runs the scenarios interleaved (scenario by scenario, repetition by
repetition, rotating which server goes first), prints the median and the
best run of each server, and stops the servers by PID.

## Servers

| Name | What runs |
| --- | --- |
| haskell (petrus) | `petrus --no-open --strict-port --port P`; prints the `[petrus-relay-perf]` lines like Vite |
| haskell (petrus, relay log off) | the same with `PETRUS_RELAY_PERF=0` (relay scenarios only) |
| node (vite dev server) | upstream `vite --port P --strictPort`, which is what `bin/petrus.mjs` runs; prints the relay lines |
| node (bare baseline) | `bench/node-baseline.mjs`: the upstream `attachOpenFileEndpoint` and the upstream relay logic on bare `node:http` + `ws`, no relay lines (Node's best case) |
| haskell (petrus-collab) | `petrus-collab P` |
| node (server/collab.mjs) | upstream `node server/collab.mjs P` |

## Scenarios

| Scenario | One op |
| --- | --- |
| relay round trip, N pairs | an agent sends a petrus-agent `request` targeted at its browser client, which answers with a `response` (2.4 KB result) targeted back; N pairs at once |
| open-file POST+GET | `POST /__petrus/open-file {path}` then `GET /__petrus/open-file` (reads the 3.3 KB sample net) |
| resolve-ref | `POST /__petrus/resolve-ref {ref: "./B.json", basePath: "file:///…/A.json"}` (resolves the URL, reads the file, returns it as a JSON string) |
| collab fan-out, P peers x M msgs | one peer sends M cursor messages; one op = one delivery to one of the P other peers |

## Results

<!-- parity: rows below 1.0× belong to "Agent WebSocket protocol", "File and URL endpoints" -->
The rows below 1.0× here are relay round trips (the Agent WebSocket protocol) and `resolve-ref`
(the file and URL endpoints); PARITY.md lists both components as in progress. The collaboration
fan-out rows are all above 1.0×.

Machine: Apple M4 (10 cores), 24 GB, macOS 26 (Darwin 25.3.0), node
v22.22.0, GHC 9.10.3. **The machine was shared with other agents building
and benchmarking during every run** (load average 6–9 for run A and 7 to
186 for run B), so absolute numbers move a lot from run to run;
interleaving makes the ratios more trustworthy than the absolute values,
and the best-of-N table shows each server in the moments the machine left
it alone. "Haskell / Node" is the best Haskell server over the best Node
server for the row (for the relay rows that compares like with like: the
fastest Node server is the bare baseline, which logs nothing, and the
Haskell set includes `petrus` with the relay log off).

### Run B (final code, commit 9a4d2b4; 9 reps; load average 7 → 186 → 37)

Median ops/s (p50 / p99 latency in µs):

| scenario | haskell (petrus) | haskell (petrus, relay log off) | node (vite) | node (bare) | haskell (petrus-collab) | node (collab.mjs) | Haskell / Node |
|---|---:|---:|---:|---:|---:|---:|---:|
| relay round trip, 1 pair | 4461 (166 / 1620) | 4873 (157 / 1442) | 3434 (222 / 1747) | 4627 (181 / 991) | | | 1.05x |
| relay round trip, 16 pairs | 10683 (1236 / 7761) | 10189 (1175 / 8119) | 9128 (1562 / 6360) | 12516 (1163 / 3870) | | | 0.85x |
| open-file POST+GET, 1 client | 2802 (167 / 3100) | | 2087 (352 / 2796) | 2564 (322 / 1994) | | | 1.09x |
| open-file POST+GET, 16 clients | 7678 (1959 / 8149) | | 6153 (2423 / 7102) | 5941 (2067 / 11221) | | | 1.25x |
| resolve-ref, 1 client | 3526 (174 / 1907) | | 3286 (212 / 1711) | 3075 (190 / 2406) | | | 1.07x |
| resolve-ref, 16 clients | 7879 (1988 / 5330) | | 11372 (1105 / 5375) | 10342 (1286 / 4946) | | | 0.69x |
| collab fan-out, 50 peers x 1000 msgs | 806192 (33949 / 57912) | | | | 789029 (44653 / 59621) | 208256 (110559 / 224343) | 3.87x |
| collab fan-out, 200 peers x 200 msgs | 650015 (34714 / 60583) | | | | 664297 (32754 / 58680) | 193040 (101335 / 204957) | 3.44x |
| server RSS after run (MiB) | 120 | 17 | 37 | 34 | 104 | 72 | |

Best of 9 (ops/s):

| scenario | haskell (petrus) | haskell (petrus, relay log off) | node (vite) | node (bare) | haskell (petrus-collab) | node (collab.mjs) | Haskell / Node |
|---|---:|---:|---:|---:|---:|---:|---:|
| relay round trip, 1 pair | 4853 | 5906 | 4915 | 5407 | | | 1.09x |
| relay round trip, 16 pairs | 11758 | 13549 | 11261 | 14509 | | | 0.93x |
| open-file POST+GET, 1 client | 4634 | | 3050 | 3780 | | | 1.23x |
| open-file POST+GET, 16 clients | 9619 | | 8296 | 8130 | | | 1.16x |
| resolve-ref, 1 client | 5133 | | 4791 | 4497 | | | 1.07x |
| resolve-ref, 16 clients | 16430 | | 13994 | 15880 | | | 1.03x |
| collab fan-out, 50 peers x 1000 msgs | 855930 | | | | 849343 | 266181 | 3.22x |
| collab fan-out, 200 peers x 200 msgs | 793619 | | | | 869357 | 230931 | 3.76x |

### Run A (commit 7eb9e61: before the C string escaper; no log-off target; 9 reps; load average 7)

Median ops/s (p50 / p99 latency in µs):

| scenario | haskell (petrus) | node (vite) | node (bare) | haskell (petrus-collab) | node (collab.mjs) | Haskell / Node |
|---|---:|---:|---:|---:|---:|---:|
| relay round trip, 1 pair | 8961 (89 / 368) | 9287 (95 / 357) | 9674 (82 / 363) | | | 0.93x |
| relay round trip, 16 pairs | 28530 (458 / 1712) | 29040 (489 / 1355) | 34252 (403 / 1241) | | | 0.83x |
| open-file POST+GET, 1 client | 7111 (128 / 438) | 6316 (131 / 506) | 6766 (129 / 509) | | | 1.05x |
| open-file POST+GET, 16 clients | 14086 (959 / 3815) | 11073 (1291 / 3110) | 8314 (1963 / 3339) | | | 1.27x |
| resolve-ref, 1 client | 11105 (82 / 292) | 11967 (77 / 256) | 11574 (78 / 260) | | | 0.93x |
| resolve-ref, 16 clients | 22954 (751 / 1454) | 24813 (572 / 1310) | 25213 (559 / 1332) | | | 0.91x |
| collab fan-out, 50 peers x 1000 msgs | 1997124 (11680 / 21826) | | | 1894514 (16283 / 25462) | 498763 (47796 / 94302) | 4.00x |
| collab fan-out, 200 peers x 200 msgs | 1568935 (16278 / 25254) | | | 1675603 (14430 / 23645) | 492162 (41401 / 79193) | 3.40x |

Best of 9 (ops/s):

| scenario | haskell (petrus) | node (vite) | node (bare) | haskell (petrus-collab) | node (collab.mjs) | Haskell / Node |
|---|---:|---:|---:|---:|---:|---:|
| relay round trip, 1 pair | 11107 | 10555 | 11827 | | | 0.94x |
| relay round trip, 16 pairs | 35944 | 32246 | 40535 | | | 0.89x |
| open-file POST+GET, 1 client | 7463 | 7017 | 7123 | | | 1.05x |
| open-file POST+GET, 16 clients | 23298 | 19314 | 19750 | | | 1.18x |
| resolve-ref, 1 client | 12791 | 14138 | 14006 | | | 0.90x |
| resolve-ref, 16 clients | 29662 | 25841 | 26912 | | | 1.10x |
| collab fan-out, 50 peers x 1000 msgs | 2278527 | | | 2242152 | 509554 | 4.47x |
| collab fan-out, 200 peers x 200 msgs | 1623640 | | | 1722801 | 507833 | 3.39x |

In run A, "Haskell / Node" for the relay rows compares `petrus`, which
logs, with the bare baseline, which does not. Spot checks with the relay
log off on both sides (interleaved, 5 reps, load average about 5): 16 pairs
38757 vs 39556 round trips/s (0.98x), 1 pair 11563 vs 11318 (1.02x).

## Reading the results

- **Collaboration fan-out: Haskell is 3.2–4.5x Node** in every run.
  Delivery is one STM transaction per message and a writer thread per
  peer that batches frames; Node serializes everything on one event loop.
- **Agent relay: Haskell matches or beats the Vite server** that
  `bin/petrus.mjs` runs (both log every request and response): run B median
  1.30x (1 pair) and 1.17x (16 pairs), best-of 0.99x and 1.04x; run A
  0.96x/0.98x median, 1.05x/1.11x best. Against the bare Node relay, which
  logs nothing, the Haskell relay with the log off is 1.05x (1 pair) and
  0.81x–0.93x (16 pairs) in run B, and 0.98–1.02x in the spot checks above.
- **open-file: Haskell is ahead** at both concurrencies in both runs
  (1.05–1.27x).
- **resolve-ref: parity, within the noise.** One client: 1.07x in run B,
  0.90–0.93x in run A (before the C escaper). Sixteen clients: 1.03–1.10x
  best-of; the medians swing both ways (0.69x in run B, whose load average
  passed 180 mid-scenario; 0.91x in run A).

So: collaboration fan-out and open-file are clearly faster; the relay and
resolve-ref are at parity with Node within this machine's noise, and the
16-pair relay is still slightly behind Node's best case (bare `ws`, no
logging) in most runs. Under heavy outside load the Haskell numbers drop
more than Node's (each GHC wakeup is an OS-thread handoff, while Node's
loop never leaves its thread), which is why the medians of run B are less
favorable than its best runs.

## What the Haskell side does to get there

- **Relays.** All threads of a relay run on one capability (`forkOn`):
  relay work is a chain of hand-offs (reader → queue → writer), and across
  capabilities each hand-off wakes another OS thread, which costs more
  than the work (16 relay pairs ran at half the throughput spread over four
  capabilities). Text that is already in `JSON.stringify` form (what every
  known client sends) is relayed by splicing the sender id into the bytes
  (`Petrus.Viewer.Json.Canonical`, property-tested against the full
  parse/stringify path); other text takes the full round trip. The
  `[petrus-relay-perf]` lines are written by a background thread after the
  frame is queued.
- **HTTP.** Each connection's thread is pinned to a capability, round
  robin (`setFork` with `forkOnWithUnmask`), so a request runs start to
  finish on one capability with that capability's I/O manager. File
  reads are direct unsafe `open`/`read` calls (like Node's `readFileSync`).
  `resolve-ref` resolves plain relative paths against `file:///` bases
  without the URL state machine (property-tested against it), and JSON
  string escaping is a small C routine (`cbits/json_escape.c`).
- **RTS defaults** for `petrus` and `petrus-collab`: `-N2 -qg -qm -A16m`.
  Two capabilities let HTTP requests run in parallel while the relays keep
  to one each; the sequential GC (`-qg`) avoids waking every capability
  for each collection; `-qm` keeps threads where they were put; a 16 MB
  allocation area makes collections rare. Four capabilities measured
  slower than two in the scenarios tried here. Override with
  `+RTS … -RTS` (or `--rts` in the runner).
- **Memory.** `petrus` holds 104–148 MiB after the runs (two 16 MB
  allocation areas plus the fan-out bursts); Vite holds 37–78 MiB.
  `+RTS -M…` caps it if needed.
