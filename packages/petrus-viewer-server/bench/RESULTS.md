# Benchmark results

<!-- scripts/bench: measured sources 2e2786ee5d3f152c at 5a73d7a7f019 -->

The Haskell backend against the upstream Node backend at the pin in
[UPSTREAM.md](../../../UPSTREAM.md), driven by one load client
(`petrus-viewer-bench`, a Haskell program) for every server.

## How to rerun

From the repository root (`scripts/bench petrus-viewer-server` runs exactly this block):

<!-- scripts/bench: rerun -->
```sh
test -d upstream/petrus-viewer/node_modules || (cd upstream/petrus-viewer && pnpm install --frozen-lockfile)
test -f upstream/petrus-viewer/dist/index.html || (cd upstream/petrus-viewer && pnpm build)
node packages/petrus-viewer-server/bench/run.mjs
```

CI's nightly smoke run (`scripts/bench --smoke`, not a measurement): the
in-process `micro` rows, a few iterations each (the scenario runner needs the
upstream viewer's `pnpm install`, which CI's `viewer` job covers). `micro`
reads the `--file` it is given and a `B.json` next to it (the file a
`resolve-ref` from it would read), so the net is copied to both names.

<!-- scripts/bench: smoke -->
```sh
cp upstream/petrus-viewer/examples/sample-net.json "$BENCH_TMP/A.json"
cp upstream/petrus-viewer/examples/sample-net.json "$BENCH_TMP/B.json"
"$BENCH_BIN" micro --file "$BENCH_TMP/A.json" --iters 50 +RTS -M2G -RTS
```

Other ways to run it:

```bash
# from the repository root; needs `pnpm install` in upstream/petrus-viewer
node packages/petrus-viewer-server/bench/run.mjs                 # builds, 5 reps
node packages/petrus-viewer-server/bench/run.mjs --reps 15 --json out.json  # the runs below
node packages/petrus-viewer-server/bench/run.mjs --bin-dir DIR   # prebuilt petrus, petrus-collab, petrus-viewer-bench
node packages/petrus-viewer-server/bench/run.mjs --quick         # 1 short rep
node packages/petrus-viewer-server/bench/run.mjs --only "open-file|resolve-ref"  # scenarios by name
node packages/petrus-viewer-server/bench/run.mjs --only "GET /|GET the|MCP|cold start"  # run G
node packages/petrus-viewer-server/bench/run.mjs --rts "-N4"     # other RTS options for petrus
cabal run petrus-viewer-bench -- micro --file DIR/A.json             # with a DIR/B.json beside it
```

The runner starts every server once on its own non-default port (from
47310), runs the scenarios interleaved (scenario by scenario, repetition by
repetition, rotating which server goes first), prints the median and the
best run of each server and the Haskell / Node ratio within each round,
and stops the servers by PID. `petrus-viewer-bench` runs with
`+RTS -M2G -RTS`. The static, `/temporal` and cold-start scenarios need
the built UI (`pnpm build` in `upstream/petrus-viewer`); the `/temporal`
scenarios need port 7243 free, since Vite's proxy target is fixed. The `micro` mode times single library calls in process
(wall clock, `GHC.Clock`); it has no Node counterpart and is for profiling
only.

## Servers

| Name | What runs |
| --- | --- |
| haskell (petrus) | `petrus --no-open --strict-port --port P`; prints the `[petrus-relay-perf]` lines like Vite |
| haskell (petrus, relay log off) | the same with `PETRUS_RELAY_PERF=0` (relay scenarios only) |
| node (vite dev server) | upstream `vite --port P --strictPort`, which is what `bin/petrus.mjs` runs; prints the relay lines |
| node (bare baseline) | `bench/node-baseline.mjs`: the upstream `attachOpenFileEndpoint` and the upstream relay logic on bare `node:http` + `ws`, no relay lines (Node's best case) |
| haskell (petrus-collab) | `petrus-collab P` |
| node (server/collab.mjs) | upstream `node server/collab.mjs P` |
| haskell (petrus), static and `/temporal` rows | the same `petrus`, with `--ui-dir upstream/petrus-viewer/dist` (the `pnpm build` output) |
| node (vite preview) | upstream `vite preview --port P --strictPort`: serves `dist/` like `petrus` does |
| haskell (petrus-mcp) | `petrus-mcp` (stdio), bridged to an agent relay (`petrus`, relay log off) |
| node (server/mcp.mjs) | upstream `node server/mcp.mjs` (stdio), bridged to the same relay |
| haskell (petrus FILE) | `petrus --no-open --ui-dir upstream/petrus-viewer/dist FILE` |
| node (bin/petrus.mjs FILE) | upstream `node bin/petrus.mjs --no-open FILE` (it runs `pnpm exec vite`) |

## Scenarios

| Scenario | One op |
| --- | --- |
| relay round trip, N pairs | an agent sends a petrus-agent `request` targeted at its browser client, which answers with a `response` (2.4 KB result) targeted back; N pairs at once |
| open-file POST+GET | `POST /__petrus/open-file {path}` then `GET /__petrus/open-file` (reads the 3.3 KB sample net); with 16 clients, in lockstep rounds (below) |
| resolve-ref | `POST /__petrus/resolve-ref {ref: "./B.json", basePath: "file:///…/A.json"}` (resolves the URL, reads the file, returns it as a JSON string) |
| collab fan-out, P peers x M msgs | one peer sends M cursor messages; one op = one delivery to one of the P other peers |
| GET / (index.html), the JS bundle, /sample-net.json | a static `GET` of the UI's page (389 B; the Vite dev server sends its 548 B dev page), its 592 KiB bundle (built servers only), and the sample net (3.3 KB) |
| GET /temporal/... (proxied) | a `GET` through the server's `/temporal` proxy to `localhost:7243`, where `petrus-viewer-bench backend` (Warp) answers every request with the same 2.3 KB JSON |
| MCP tool, C calls in flight | one `tools/call` line on the server's stdin, answered on its stdout: `petrus_inspect_document {includeSchema: true}` (a bridge request to the browser, whose 2.4 KB answer the server formats as the tool result) or `petrus_status` (no bridge request); the load client is the agent and, over a WebSocket to the relay, the browser |
| cold start | spawn the server for a net file, until `GET /__petrus/open-file` returns the file and `GET /` returns the UI; then stop the process group and wait for the port to close |

The HTTP scenarios give every server the same work, and the runner checks
it: every run of a scenario must have the same counts of 200, 204 and
other statuses, or it prints `WORKLOAD DIFFERS` with the counts of each
server and exits non-zero. open-file keeps one pending file for the whole
server, so with 16 free-running clients the work depended on how each
server interleaved them: a `GET` read the file only if no other `GET` had
consumed it since the last `POST`, and otherwise answered 204 with no
body. With 16 clients the load client therefore runs open-file in
lockstep rounds: every client `POST`s, all wait, every client `GET`s, all
wait. Each round is one `POST` per client (200), one `GET` that reads the
file (200), and 15 `GET`s that find nothing pending (204), on every
server: 68000 / 60000 / 0 over the 64000 ops of a run. The time spent
waiting for the other clients is not counted in the latencies.

Since run E the load client speaks HTTP/1.1 itself: one keep-alive
connection per client, a fixed request, and the response read by its
`Content-Length`. Runs A–D used `http-client`, which costs more per
request than these servers do. At 16 clients it set the pace: every
server landed in the same band, and the servers' differences were lost in
its noise. Runs E and F are 20000 ops per run with 1 client and 64000 with 16
(runs A–D: 5000 and 32000), so that every run lasts about a second or two
rather than a fraction of one.

## Results

Run H (2026-10-12) reran every scenario on the current code and is the
current measurement: every scenario is above 1.0× in every round (the
lowest round is 1.10x). Before it, run G covered the static UI, the `/temporal` proxy, the MCP server and
cold start: every one of its scenarios is above 1.0× in every round (the
lowest round is 1.07x). Run F covered the other scenarios:
every scenario is above 1.0× by median and by
best run. Single rounds below 1.0× remain in the 1-client endpoint
scenarios (lowest 0.78x) and once at 16 clients (0.97x); "Reading the
results" explains them. Run E measured the endpoints of the same code,
with the previous server in the same rounds (its column is the "before"
one). Runs A to D measured earlier code; they are kept for the record and
marked superseded, as are runs E to G now that run H replaces them.

Machine: Apple M4 (10 cores), 24 GB, macOS 26 (Darwin 25.3.0), node
v22.22.0, GHC 9.10.3. **The machine was shared with other agents building
and benchmarking during every run**, so absolute numbers move a lot from
run to run (a single 16-client run of the same server can swing by ±40%
within one table). Interleaving makes the ratios more trustworthy than the
absolute values. "Haskell / Node" is the best Haskell server over the best
Node server for the row; for the relay rows that compares like with like
(the fastest Node server is the bare baseline, which logs nothing, and the
Haskell set includes `petrus` with the relay log off). The last table of
each run gives that ratio within each round: every round runs each server
once, back to back, so it is the comparison least exposed to the
machine's drift between rounds.

Everything here is wall-clock time: ops/s is completed operations over the
load client's elapsed time, and latencies are per-operation wall times.

### Run H (every scenario, current code; 5 reps; load average 2.95 → 4.35)

Measured on 2026-10-12, 04:15–04:25 local (UTC-3), at commit `81bbdc5`, by the
rerun block above (`node packages/petrus-viewer-server/bench/run.mjs`, five
interleaved repetitions). Every scenario is above 1.0× by median, by best
run and in every round; the lowest single round is `GET /sample-net.json`,
16 clients, at 1.10× (two rounds where the Vite dev server answered at
about twice its usual rate). Runs A to G below are earlier measurements.

#### Relay and endpoints

| scenario | haskell (petrus) | haskell (petrus, relay log off) | node (vite dev server) | node (bare baseline) | Haskell / Node |
|---|---:|---:|---:|---:|---:|
| relay round trip, 1 pair | 13659 (72 / 94) | 15830 (62 / 87) | 9885 (101 / 135) | 11346 (88 / 124) | 1.40x |
| relay round trip, 16 pairs | 63361 (242 / 417) | 78065 (190 / 334) | 32161 (491 / 636) | 42872 (366 / 507) | 1.82x |
| open-file POST+GET, 1 client | 13755 (72 / 116) |  | 11309 (88 / 115) | 11585 (85 / 125) | 1.19x |
| open-file POST+GET, 16 clients in lockstep | 59010 (108 / 318) |  | 38874 (192 / 396) | 40900 (181 / 386) | 1.44x |
| resolve-ref, 1 client | 20152 (49 / 59) |  | 16892 (59 / 81) | 16673 (59 / 80) | 1.19x |
| resolve-ref, 16 clients | 38091 (390 / 800) |  | 28410 (521 / 1066) | 27473 (541 / 1108) | 1.34x |
| server RSS after run (MiB) | 81 | 44 | 134 | 63 | |

Cells: median ops/s over 5 interleaved runs (p50 / p99 latency in us).

| scenario (best of 5) | haskell (petrus) | haskell (petrus, relay log off) | node (vite dev server) | node (bare baseline) | Haskell / Node |
|---|---:|---:|---:|---:|---:|
| relay round trip, 1 pair | 14380 | 15839 | 10287 | 11428 | 1.39x |
| relay round trip, 16 pairs | 64851 | 78960 | 32340 | 43458 | 1.82x |
| open-file POST+GET, 1 client | 13889 |  | 11366 | 12148 | 1.14x |
| open-file POST+GET, 16 clients in lockstep | 59148 |  | 39037 | 41025 | 1.44x |
| resolve-ref, 1 client | 20219 |  | 17711 | 16779 | 1.14x |
| resolve-ref, 16 clients | 38166 |  | 29648 | 28638 | 1.29x |

| scenario | Haskell / Node in each round (best of each side) | min |
|---|---|---:|
| relay round trip, 1 pair | 1.44 1.38 1.42 1.37 1.39 | 1.37x |
| relay round trip, 16 pairs | 1.86 1.84 1.81 1.91 1.68 | 1.68x |
| open-file POST+GET, 1 client | 1.17 1.14 1.19 1.20 1.19 | 1.14x |
| open-file POST+GET, 16 clients in lockstep | 1.46 1.44 1.44 1.43 1.45 | 1.43x |
| resolve-ref, 1 client | 1.19 1.14 1.20 1.18 1.16 | 1.14x |
| resolve-ref, 16 clients | 1.31 1.28 1.31 1.34 1.33 | 1.28x |

#### Collab

| scenario | haskell (petrus) | haskell (petrus-collab) | node (server/collab.mjs) | Haskell / Node |
|---|---:|---:|---:|---:|
| collab fan-out, 50 peers x 1000 msgs | 2077102 (14950 / 21876) | 2261932 (14122 / 20181) | 542711 (45233 / 86081) | 4.17x |
| collab fan-out, 200 peers x 200 msgs | 1948938 (16446 / 20182) | 2132196 (13688 / 18430) | 540030 (36830 / 72718) | 3.95x |
| server RSS after run (MiB) | 81 | 72 | 73 | |

Cells: median ops/s over 5 interleaved runs (p50 / p99 latency in us).

| scenario (best of 5) | haskell (petrus) | haskell (petrus-collab) | node (server/collab.mjs) | Haskell / Node |
|---|---:|---:|---:|---:|
| collab fan-out, 50 peers x 1000 msgs | 2348851 | 2298111 | 549378 | 4.28x |
| collab fan-out, 200 peers x 200 msgs | 2163332 | 2262571 | 542947 | 4.17x |

| scenario | Haskell / Node in each round (best of each side) | min |
|---|---|---:|
| collab fan-out, 50 peers x 1000 msgs | 4.36 3.83 4.17 3.81 4.36 | 3.81x |
| collab fan-out, 200 peers x 200 msgs | 4.02 3.63 4.17 3.71 3.99 | 3.63x |

#### Static UI (`dist/`)

| scenario | haskell (petrus) | node (vite dev server) | node (vite preview) | Haskell / Node |
|---|---:|---:|---:|---:|
| GET / (index.html), 1 client | 22810 (43 / 55) | 9000 (110 / 128) | 11724 (85 / 129) | 1.95x |
| GET / (index.html), 16 clients | 39360 (405 / 477) | 17191 (912 / 1143) | 28009 (555 / 793) | 1.41x |
| GET the JS bundle (592 KiB), 16 clients | 20798 (761 / 1263) |  | 4967 (2969 / 5201) | 4.19x |
| GET /sample-net.json, 16 clients | 38242 (415 / 501) | 21553 (576 / 2667) | 17086 (794 / 2280) | 1.77x |
| server RSS after run (MiB) | 81 | 134 | 132 | |

Cells: median ops/s over 5 interleaved runs (p50 / p99 latency in us).

| scenario (best of 5) | haskell (petrus) | node (vite dev server) | node (vite preview) | Haskell / Node |
|---|---:|---:|---:|---:|
| GET / (index.html), 1 client | 22901 | 9029 | 11743 | 1.95x |
| GET / (index.html), 16 clients | 39400 | 17519 | 28955 | 1.36x |
| GET the JS bundle (592 KiB), 16 clients | 21066 |  | 5065 | 4.16x |
| GET /sample-net.json, 16 clients | 38457 | 34527 | 17122 | 1.11x |

| scenario | Haskell / Node in each round (best of each side) | min |
|---|---|---:|
| GET / (index.html), 1 client | 1.94 1.95 1.94 1.97 1.94 | 1.94x |
| GET / (index.html), 16 clients | 1.39 1.33 1.41 1.40 1.41 | 1.33x |
| GET the JS bundle (592 KiB), 16 clients | 3.83 4.16 4.19 4.15 4.19 | 3.83x |
| GET /sample-net.json, 16 clients | 1.10 1.11 1.80 1.78 1.79 | 1.10x |

#### The `/temporal` proxy

| scenario | haskell (petrus) | node (vite dev server) | node (vite preview) | Haskell / Node |
|---|---:|---:|---:|---:|
| GET /temporal/... (proxied), 1 client | 13596 (73 / 102) | 3472 (273 / 546) | 3489 (274 / 394) | 3.90x |
| GET /temporal/... (proxied), 16 clients | 26387 (589 / 891) | 9329 (1550 / 2827) | 9774 (1576 / 2854) | 2.70x |
| server RSS after run (MiB) | 81 | 134 | 132 | |

Cells: median ops/s over 5 interleaved runs (p50 / p99 latency in us).

| scenario (best of 5) | haskell (petrus) | node (vite dev server) | node (vite preview) | Haskell / Node |
|---|---:|---:|---:|---:|
| GET /temporal/... (proxied), 1 client | 13659 | 3549 | 3543 | 3.85x |
| GET /temporal/... (proxied), 16 clients | 26802 | 9842 | 9986 | 2.68x |

| scenario | Haskell / Node in each round (best of each side) | min |
|---|---|---:|
| GET /temporal/... (proxied), 1 client | 3.83 3.91 3.87 3.92 4.03 | 3.83x |
| GET /temporal/... (proxied), 16 clients | 2.66 2.71 2.88 2.05 2.64 | 2.05x |

#### MCP `tools/call` round trip

| scenario | haskell (petrus-mcp) | node (server/mcp.mjs) | Haskell / Node |
|---|---:|---:|---:|
| MCP petrus_inspect_document, 1 call at a time | 6224 (157 / 224) | 5247 (181 / 425) | 1.19x |
| MCP petrus_inspect_document, 16 calls in flight | 18568 (867 / 1478) | 15877 (912 / 2168) | 1.17x |
| MCP petrus_status, 1 call at a time | 8462 (117 / 165) | 6950 (137 / 297) | 1.22x |

Cells: median ops/s over 5 interleaved runs (p50 / p99 latency in us).

| scenario (best of 5) | haskell (petrus-mcp) | node (server/mcp.mjs) | Haskell / Node |
|---|---:|---:|---:|
| MCP petrus_inspect_document, 1 call at a time | 6263 | 5300 | 1.18x |
| MCP petrus_inspect_document, 16 calls in flight | 19155 | 16193 | 1.18x |
| MCP petrus_status, 1 call at a time | 8482 | 6969 | 1.22x |

| scenario | Haskell / Node in each round (best of each side) | min |
|---|---|---:|
| MCP petrus_inspect_document, 1 call at a time | 1.19 1.20 1.19 1.18 1.18 | 1.18x |
| MCP petrus_inspect_document, 16 calls in flight | 1.16 1.15 1.15 1.21 1.19 | 1.15x |
| MCP petrus_status, 1 call at a time | 1.22 1.21 1.22 1.21 1.22 | 1.21x |

#### Cold start

| scenario | haskell (petrus FILE) | node (bin/petrus.mjs FILE) | Haskell / Node |
|---|---:|---:|---:|
| cold start until the file and UI are served | 104 (9555 / 9988) | 2.73 (369875 / 389475) | 38.10x |

Cells: median ops/s over 5 interleaved runs (p50 / p99 latency in us).

| scenario (best of 5) | haskell (petrus FILE) | node (bin/petrus.mjs FILE) | Haskell / Node |
|---|---:|---:|---:|
| cold start until the file and UI are served | 109 | 2.8 | 38.93x |

| scenario | Haskell / Node in each round (best of each side) | min |
|---|---|---:|
| cold start until the file and UI are served | 38.10 39.21 38.57 37.50 38.38 | 37.50x |

### Before and after

Median Haskell / Node (best of each side). Runs B–D used `http-client` as
the load client and runs E–F the lean HTTP/1.1 client, so absolute ops/s
are comparable only within a run, not across that change. Run E ran the
previous server (700c623) and the new one side by side; its endpoint rows
are in the "run E" columns.

| scenario | run B (9a4d2b4) | run C (bbab9aa) | run D (9a5969c) | run E, previous server | run E, HTTP front | run F (HTTP front, final) |
|---|---:|---:|---:|---:|---:|---:|
| relay round trip, 1 pair | 1.05x | 1.41x | 1.40x | | | 1.32x |
| relay round trip, 16 pairs | 0.85x | 1.17x | 1.31x | | | 1.09x |
| open-file POST+GET, 1 client | 1.09x | 1.00x | 1.10x | 1.03x | 1.14x | 1.20x |
| open-file POST+GET, 16 clients | 1.25x | 1.10x | 1.00x | 1.12x | 1.39x | 1.54x |
| resolve-ref, 1 client | 1.07x | 1.07x | 1.07x | 1.08x | 1.17x | 1.16x |
| resolve-ref, 16 clients | 0.69x | 1.16x | 1.17x | 1.16x | 1.31x | 1.37x |
| collab fan-out, 50 peers x 1000 msgs | 3.87x | 4.17x | 4.27x | | | 4.37x |
| collab fan-out, 200 peers x 200 msgs | 3.44x | 3.93x | 4.50x | | | 4.04x |

The open-file 16-client rows of runs B–D are free-running clients
sharing one pending file, so the servers did not do the same work;
from run E on they run in lockstep.

Lowest Haskell / Node ratio within a round:

| scenario | run C | run D | run E, HTTP front | run F |
|---|---:|---:|---:|---:|
| relay round trip, 1 pair | 1.09x | 1.23x | | 1.01x |
| relay round trip, 16 pairs | 1.07x | 1.07x | | 1.02x |
| open-file POST+GET, 1 client | 0.79x | 0.97x | 0.66x | 0.78x |
| open-file POST+GET, 16 clients | 0.77x | 0.58x | 0.94x | 0.97x |
| resolve-ref, 1 client | 1.07x | 0.96x | 0.83x | 1.01x |
| resolve-ref, 16 clients | 1.01x | 0.84x | 1.07x | 1.06x |
| collab fan-out, 50 peers x 1000 msgs | 3.87x | 3.91x | | 3.79x |
| collab fan-out, 200 peers x 200 msgs | 3.78x | 3.92x | | 3.21x |

### Run G (static UI, `/temporal`, MCP and cold start; 5 reps; load average 5.9 → 6.8)

The scenarios that run F did not cover, on the final code (`--only "GET /|GET the|MCP|cold start"`).
The other scenarios' code is unchanged since run F. In the static and
`/temporal` rows, "Haskell / Node" compares `petrus` with the faster of
the Vite dev server and `vite preview`. The Vite dev server serves its
development page and does not serve the built bundle.

#### Static UI (`dist/`)

<!-- bench: superseded -->

| scenario | haskell (petrus) | node (vite dev server) | node (vite preview) | Haskell / Node |
|---|---:|---:|---:|---:|
| GET / (index.html), 1 client | 22003 (43 / 87) | 9478 (95 / 257) | 13658 (68 / 149) | 1.61x |
| GET / (index.html), 16 clients | 40523 (384 / 620) | 16723 (884 / 2249) | 28627 (536 / 965) | 1.42x |
| GET the JS bundle (592 KiB), 16 clients | 19711 (766 / 1610) |  | 6126 (2557 / 4058) | 3.22x |
| GET /sample-net.json, 16 clients | 37915 (412 / 590) | 19370 (603 / 3079) | 20112 (738 / 1806) | 1.89x |
| server RSS after run (MiB) | 53 | 135 | 83 | |

Cells: median ops/s over 5 interleaved runs (p50 / p99 latency in us).

<!-- bench: superseded -->

| scenario (best of 5) | haskell (petrus) | node (vite dev server) | node (vite preview) | Haskell / Node |
|---|---:|---:|---:|---:|
| GET / (index.html), 1 client | 24195 | 10335 | 14744 | 1.64x |
| GET / (index.html), 16 clients | 40957 | 18106 | 31223 | 1.31x |
| GET the JS bundle (592 KiB), 16 clients | 20160 |  | 6217 | 3.24x |
| GET /sample-net.json, 16 clients | 38954 | 32700 | 21728 | 1.19x |

| scenario | Haskell / Node in each round (best of each side) | min |
|---|---|---:|
| GET / (index.html), 1 client | 1.74 1.68 1.64 1.51 1.65 | 1.51x |
| GET / (index.html), 16 clients | 1.41 1.42 1.27 1.38 1.31 | 1.27x |
| GET the JS bundle (592 KiB), 16 clients | 3.17 3.25 2.82 3.29 3.60 | 2.82x |
| GET /sample-net.json, 16 clients | 1.07 1.21 1.74 2.09 1.58 | 1.07x |

#### The `/temporal` proxy

<!-- bench: superseded -->

| scenario | haskell (petrus) | node (vite dev server) | node (vite preview) | Haskell / Node |
|---|---:|---:|---:|---:|
| GET /temporal/... (proxied), 1 client | 7103 (136 / 229) | 2128 (435 / 1062) | 2042 (437 / 1241) | 3.34x |
| GET /temporal/... (proxied), 16 clients | 12594 (1245 / 1835) | 5698 (2617 / 6491) | 5887 (2351 / 7497) | 2.14x |
| server RSS after run (MiB) | 53 | 135 | 83 | |

Cells: median ops/s over 5 interleaved runs (p50 / p99 latency in us).

<!-- bench: superseded -->

| scenario (best of 5) | haskell (petrus) | node (vite dev server) | node (vite preview) | Haskell / Node |
|---|---:|---:|---:|---:|
| GET /temporal/... (proxied), 1 client | 8290 | 2179 | 2205 | 3.76x |
| GET /temporal/... (proxied), 16 clients | 15398 | 6058 | 6016 | 2.54x |

| scenario | Haskell / Node in each round (best of each side) | min |
|---|---|---:|
| GET /temporal/... (proxied), 1 client | 3.45 3.35 3.26 3.14 4.12 | 3.14x |
| GET /temporal/... (proxied), 16 clients | 2.54 2.08 2.06 2.24 2.00 | 2.00x |

#### MCP `tools/call` round trip

<!-- bench: superseded -->

| scenario | haskell (petrus-mcp) | node (server/mcp.mjs) | Haskell / Node |
|---|---:|---:|---:|
| MCP petrus_inspect_document, 1 call at a time | 4589 (202 / 439) | 3827 (238 / 664) | 1.20x |
| MCP petrus_inspect_document, 16 calls in flight | 11896 (1254 / 2660) | 9239 (1542 / 4330) | 1.29x |
| MCP petrus_status, 1 call at a time | 6180 (154 / 298) | 4735 (183 / 521) | 1.31x |

Cells: median ops/s over 5 interleaved runs (p50 / p99 latency in us).

<!-- bench: superseded -->

| scenario (best of 5) | haskell (petrus-mcp) | node (server/mcp.mjs) | Haskell / Node |
|---|---:|---:|---:|
| MCP petrus_inspect_document, 1 call at a time | 4630 | 3876 | 1.19x |
| MCP petrus_inspect_document, 16 calls in flight | 12223 | 10111 | 1.21x |
| MCP petrus_status, 1 call at a time | 6417 | 4928 | 1.30x |

| scenario | Haskell / Node in each round (best of each side) | min |
|---|---|---:|
| MCP petrus_inspect_document, 1 call at a time | 1.30 1.20 1.19 1.30 1.17 | 1.17x |
| MCP petrus_inspect_document, 16 calls in flight | 1.22 1.32 1.40 1.12 1.43 | 1.12x |
| MCP petrus_status, 1 call at a time | 1.31 1.30 1.23 1.24 1.44 | 1.23x |

#### Cold start

<!-- bench: superseded -->

| scenario | haskell (petrus FILE) | node (bin/petrus.mjs FILE) | Haskell / Node |
|---|---:|---:|---:|
| cold start until the file and UI are served | 85.83 (11575 / 12862) | 2.66 (377930 / 387062) | 32.27x |

Cells: median ops/s over 5 interleaved runs (p50 / p99 latency in us).

<!-- bench: superseded -->

| scenario (best of 5) | haskell (petrus FILE) | node (bin/petrus.mjs FILE) | Haskell / Node |
|---|---:|---:|---:|
| cold start until the file and UI are served | 95.11 | 2.71 | 35.10x |

| scenario | Haskell / Node in each round (best of each side) | min |
|---|---|---:|
| cold start until the file and UI are served | 33.79 31.56 35.49 31.01 35.59 | 31.01x |

Server CPU per MCP call (user + system time of the server process over
the timed calls, from `ps`; the medians' runs):

| scenario | haskell (petrus-mcp) | node (server/mcp.mjs) |
|---|---:|---:|
| petrus_inspect_document, 1 call at a time | 50 + 20 us | 155 + 25 us |
| petrus_inspect_document, 16 calls in flight | 53.1 + 16.3 us | 171.3 + 13.1 us |
| petrus_status, 1 call at a time | 25 + 20 us | 140 + 27.5 us |

Through Vite, every `/temporal` request was answered with
`Connection: close` (4000 and 8000 reconnects per run, one per request);
the load client reopens its connection, as a browser does, and that time
is part of Vite's latencies.

### Run F (the HTTP front, final code; 15 reps; load average 5.1 → 9.0)

<!-- bench: superseded -->

| scenario | haskell (petrus) | haskell (petrus, relay log off) | node (vite dev server) | node (bare baseline) | haskell (petrus-collab) | node (server/collab.mjs) | Haskell / Node |
|---|---:|---:|---:|---:|---:|---:|---:|
| relay round trip, 1 pair | 14249 (66 / 141) | 15806 (59 / 136) | 10585 (89 / 198) | 11965 (78 / 169) |  |  | 1.32x |
| relay round trip, 16 pairs | 37227 (417 / 807) | 39277 (390 / 753) | 25674 (613 / 1014) | 35949 (424 / 827) |  |  | 1.09x |
| open-file POST+GET, 1 client | 14068 (66 / 159) |  | 11612 (81 / 183) | 11719 (81 / 160) |  |  | 1.20x |
| open-file POST+GET, 16 clients in lockstep | 46897 (152 / 418) |  | 30135 (253 / 562) | 30475 (255 / 622) |  |  | 1.54x |
| resolve-ref, 1 client | 20280 (45 / 132) |  | 17043 (55 / 113) | 17456 (53 / 110) |  |  | 1.16x |
| resolve-ref, 16 clients | 37224 (377 / 872) |  | 25962 (527 / 1505) | 27244 (525 / 1250) |  |  | 1.37x |
| collab fan-out, 50 peers x 1000 msgs | 840887 (25555 / 47583) |  |  |  | 876317 (36428 / 52857) | 200711 (109719 / 233158) | 4.37x |
| collab fan-out, 200 peers x 200 msgs | 808832 (34302 / 49073) |  |  |  | 790373 (42479 / 49952) | 200254 (94295 / 195530) | 4.04x |
| server RSS after run (MiB) | 55 | 18 | 46 | 39 | 49 | 88 | |

Cells: median ops/s over 15 interleaved runs (p50 / p99 latency in us).

<!-- bench: superseded -->

| scenario (best of 15) | haskell (petrus) | haskell (petrus, relay log off) | node (vite dev server) | node (bare baseline) | haskell (petrus-collab) | node (server/collab.mjs) | Haskell / Node |
|---|---:|---:|---:|---:|---:|---:|---:|
| relay round trip, 1 pair | 15180 | 16672 | 10909 | 12897 |  |  | 1.29x |
| relay round trip, 16 pairs | 56112 | 67013 | 32827 | 41274 |  |  | 1.62x |
| open-file POST+GET, 1 client | 16861 |  | 11949 | 14359 |  |  | 1.17x |
| open-file POST+GET, 16 clients in lockstep | 59991 |  | 33563 | 34075 |  |  | 1.76x |
| resolve-ref, 1 client | 21979 |  | 17772 | 18476 |  |  | 1.19x |
| resolve-ref, 16 clients | 39492 |  | 28616 | 28609 |  |  | 1.38x |
| collab fan-out, 50 peers x 1000 msgs | 1000140 |  |  |  | 1102657 | 228321 | 4.83x |
| collab fan-out, 200 peers x 200 msgs | 945247 |  |  |  | 994283 | 265940 | 3.74x |

| scenario | Haskell / Node in each round (best of each side) | min |
|---|---|---:|
| relay round trip, 1 pair | 1.48 1.20 1.26 1.32 1.74 1.49 1.25 1.21 1.01 1.35 1.44 1.36 1.36 1.34 1.42 | 1.01x |
| relay round trip, 16 pairs | 1.09 1.06 1.15 1.02 1.11 1.36 1.19 1.18 1.17 1.88 1.93 1.52 1.46 1.36 1.68 | 1.02x |
| open-file POST+GET, 1 client | 1.05 1.17 0.78 0.87 0.79 0.97 1.26 1.35 1.23 1.27 1.24 1.13 1.17 1.16 1.24 | 0.78x |
| open-file POST+GET, 16 clients in lockstep | 1.43 0.97 1.41 1.02 1.50 1.65 1.18 1.53 1.50 1.89 1.55 1.49 1.76 1.50 1.40 | 0.97x |
| resolve-ref, 1 client | 1.08 1.09 1.17 1.13 1.17 1.19 1.19 1.40 1.15 1.11 1.05 1.22 1.17 1.01 1.16 | 1.01x |
| resolve-ref, 16 clients | 1.30 1.38 1.43 1.38 1.36 1.39 1.34 1.32 1.32 1.30 1.06 1.23 1.88 1.47 1.59 | 1.06x |
| collab fan-out, 50 peers x 1000 msgs | 4.52 4.06 3.86 4.70 5.20 5.22 4.38 4.10 5.43 4.61 5.07 4.06 3.79 4.89 5.41 | 3.79x |
| collab fan-out, 200 peers x 200 msgs | 3.21 3.52 7.44 4.21 3.76 3.80 4.39 4.89 5.93 4.04 3.54 3.48 5.22 4.85 5.22 | 3.21x |

### Run E (the HTTP front against the previous Warp server and Node, interleaved; 15 reps; load average 6.1–6.7)

The endpoint scenarios only, with one more target: `haskell before` is
`petrus` at commit 700c623 (Warp serves every request), started and run
in the same rotation as the others. The ratio column compares the new
`petrus` with the best Node server.

<!-- bench: superseded -->

| scenario | haskell (petrus) | haskell before (700c623, Warp) | node (vite dev server) | node (bare baseline) | Haskell / Node |
|---|---:|---:|---:|---:|---:|
| open-file POST+GET, 1 client | 13027 (72 / 161) | 11717 (80 / 170) | 11382 (86 / 136) | 11097 (85 / 171) | 1.14x |
| open-file POST+GET, 16 clients in lockstep | 47626 (146 / 429) | 38581 (185 / 504) | 34363 (214 / 546) | 33915 (218 / 567) | 1.39x |
| resolve-ref, 1 client | 20886 (45 / 96) | 19324 (49 / 96) | 17329 (55 / 114) | 17905 (52 / 104) | 1.17x |
| resolve-ref, 16 clients | 37856 (377 / 856) | 33610 (457 / 762) | 27588 (521 / 1161) | 28871 (501 / 1099) | 1.31x |
| server RSS after run (MiB) | 50 | 67 | 61 | 55 | |

Cells: median ops/s over 15 interleaved runs (p50 / p99 latency in us).

| scenario | new / Node in each round | min | before / Node, median |
|---|---|---:|---:|
| open-file POST+GET, 1 client | 1.23 1.01 0.98 0.66 0.80 1.06 1.18 1.22 1.19 1.11 1.29 1.10 1.25 1.10 1.03 | 0.66x | 1.03x |
| open-file POST+GET, 16 clients in lockstep | 1.09 1.36 1.27 1.34 1.26 1.11 1.44 1.40 1.16 0.94 1.83 1.46 1.42 0.95 1.40 | 0.94x | 1.12x |
| resolve-ref, 1 client | 1.13 1.25 1.26 1.16 1.22 1.00 1.05 1.08 1.13 1.13 1.13 1.14 1.11 0.83 1.20 | 0.83x | 1.08x |
| resolve-ref, 16 clients | 1.28 1.25 1.34 1.17 1.35 1.07 1.33 1.28 1.35 1.29 1.32 1.39 1.38 1.34 1.35 | 1.07x | 1.16x |

The previous server failed the workload check: in at least 4 of its 15
16-client open-file runs, 1 to 6 `GET`s too many read the file (68001,
68002, 68003 and 68006 statuses 200). Its `GET` read the pending file and cleared
it afterwards, so two Warp threads could both serve the same pending
file, which Node's single thread never does. The new code takes the
pending file atomically before reading it, and every run of the new
server and of both Node servers had exactly 68000 / 60000 / 0.

### Run D (commit 9a5969c, before the HTTP front; 7 reps; load average 5.0 → 6.4)

<!-- bench: superseded -->

| scenario | haskell (petrus) | haskell (petrus, relay log off) | node (vite dev server) | node (bare baseline) | haskell (petrus-collab) | node (server/collab.mjs) | Haskell / Node |
|---|---:|---:|---:|---:|---:|---:|---:|
| relay round trip, 1 pair | 14789 (64 / 138) | 16959 (57 / 109) | 10696 (83 / 215) | 12115 (81 / 139) |  |  | 1.40x |
| relay round trip, 16 pairs | 37786 (404 / 817) | 50811 (296 / 712) | 29222 (491 / 1189) | 38877 (379 / 814) |  |  | 1.31x |
| open-file POST+GET, 1 client | 8939 (108 / 182) |  | 8114 (121 / 203) | 8096 (121 / 196) |  |  | 1.10x |
| open-file POST+GET, 16 clients | 18851 (814 / 1645) |  | 18875 (837 / 1436) | 17829 (858 / 2184) |  |  | 1.00x |
| resolve-ref, 1 client | 14060 (69 / 128) |  | 13135 (75 / 132) | 13118 (76 / 133) |  |  | 1.07x |
| resolve-ref, 16 clients | 33815 (460 / 714) |  | 28927 (501 / 1084) | 28728 (514 / 1111) |  |  | 1.17x |
| collab fan-out, 50 peers x 1000 msgs | 1921303 (18129 / 24495) |  |  |  | 2027246 (15864 / 22254) | 474244 (50695 / 98343) | 4.27x |
| collab fan-out, 200 peers x 200 msgs | 1440092 (22109 / 27434) |  |  |  | 1453383 (22826 / 26604) | 323300 (67544 / 117553) | 4.50x |
| server RSS after run (MiB) | 82 | 44 | 89 | 77 | 61 | 76 | |

Cells: median ops/s over 7 interleaved runs (p50 / p99 latency in us).

| scenario (best of 7) | haskell (petrus) | haskell (petrus, relay log off) | node (vite dev server) | node (bare baseline) | haskell (petrus-collab) | node (server/collab.mjs) | Haskell / Node |
|---|---:|---:|---:|---:|---:|---:|---:|
| relay round trip, 1 pair | 15943 | 18572 | 11593 | 12449 |  |  | 1.49x |
| relay round trip, 16 pairs | 46113 | 58282 | 31752 | 40772 |  |  | 1.43x |
| open-file POST+GET, 1 client | 10129 |  | 9037 | 9227 |  |  | 1.10x |
| open-file POST+GET, 16 clients | 25452 |  | 20022 | 29136 |  |  | 0.87x |
| resolve-ref, 1 client | 14966 |  | 13730 | 13660 |  |  | 1.09x |
| resolve-ref, 16 clients | 35054 |  | 30265 | 29884 |  |  | 1.16x |
| collab fan-out, 50 peers x 1000 msgs | 2012558 |  |  |  | 2098812 | 492136 | 4.26x |
| collab fan-out, 200 peers x 200 msgs | 1573502 |  |  |  | 1526019 | 372946 | 4.22x |

| scenario | Haskell / Node in each round (best of each side) | min |
|---|---|---:|
| relay round trip, 1 pair | 1.38 1.40 1.39 1.50 1.43 1.23 1.26 | 1.23x |
| relay round trip, 16 pairs | 1.07 1.80 1.32 1.60 1.30 1.49 1.22 | 1.07x |
| open-file POST+GET, 1 client | 1.04 1.11 1.06 1.10 0.97 0.98 1.26 | 0.97x |
| open-file POST+GET, 16 clients | 0.65 0.58 0.87 1.26 0.67 1.09 1.34 | 0.58x |
| resolve-ref, 1 client | 1.07 1.07 1.09 1.05 0.96 0.99 1.07 | 0.96x |
| resolve-ref, 16 clients | 1.15 1.18 1.14 1.09 1.21 1.17 0.84 | 0.84x |
| collab fan-out, 50 peers x 1000 msgs | 5.15 4.38 4.43 4.25 3.91 4.19 5.64 | 3.91x |
| collab fan-out, 200 peers x 200 msgs | 4.22 4.72 4.12 4.84 4.82 4.92 3.92 | 3.92x |

### Run C (commit bbab9aa: `-N1`, before the relay log was written from the relay loop; 7 reps; load average 4.3–4.7)

<!-- bench: superseded -->

| scenario | haskell (petrus) | haskell (petrus, relay log off) | node (vite dev server) | node (bare baseline) | haskell (petrus-collab) | node (server/collab.mjs) | Haskell / Node |
|---|---:|---:|---:|---:|---:|---:|---:|
| relay round trip, 1 pair | 11116 (80 / 179) | 14874 (59 / 160) | 10055 (92 / 208) | 10538 (86 / 232) |  |  | 1.41x |
| relay round trip, 16 pairs | 32319 (488 / 865) | 35292 (434 / 897) | 24284 (626 / 1391) | 30279 (510 / 1000) |  |  | 1.17x |
| open-file POST+GET, 1 client | 8120 (116 / 238) |  | 7996 (117 / 255) | 8129 (113 / 255) |  |  | 1.00x |
| open-file POST+GET, 16 clients | 20792 (797 / 1333) |  | 18559 (849 / 1272) | 18866 (843 / 1347) |  |  | 1.10x |
| resolve-ref, 1 client | 14284 (68 / 126) |  | 13312 (74 / 120) | 12815 (74 / 138) |  |  | 1.07x |
| resolve-ref, 16 clients | 33013 (581 / 953) |  | 28343 (522 / 1087) | 27240 (544 / 1134) |  |  | 1.16x |
| collab fan-out, 50 peers x 1000 msgs | 2216410 (11758 / 19422) |  |  |  | 2119363 (15767 / 21904) | 530943 (45419 / 89499) | 4.17x |
| collab fan-out, 200 peers x 200 msgs | 2024701 (11751 / 19362) |  |  |  | 1983537 (15816 / 19368) | 515371 (38378 / 76398) | 3.93x |
| server RSS after run (MiB) | 86 | 58 | 108 | 72 | 76 | 74 | |

Cells: median ops/s over 7 interleaved runs (p50 / p99 latency in us).

| scenario (best of 7) | haskell (petrus) | haskell (petrus, relay log off) | node (vite dev server) | node (bare baseline) | haskell (petrus-collab) | node (server/collab.mjs) | Haskell / Node |
|---|---:|---:|---:|---:|---:|---:|---:|
| relay round trip, 1 pair | 12619 | 15290 | 10356 | 12230 |  |  | 1.25x |
| relay round trip, 16 pairs | 36382 | 44230 | 25807 | 33022 |  |  | 1.34x |
| open-file POST+GET, 1 client | 9179 |  | 9095 | 9265 |  |  | 0.99x |
| open-file POST+GET, 16 clients | 22744 |  | 21275 | 20024 |  |  | 1.07x |
| resolve-ref, 1 client | 14556 |  | 13341 | 12873 |  |  | 1.09x |
| resolve-ref, 16 clients | 52262 |  | 29590 | 28003 |  |  | 1.77x |
| collab fan-out, 50 peers x 1000 msgs | 2344336 |  |  |  | 2520542 | 532272 | 4.74x |
| collab fan-out, 200 peers x 200 msgs | 2227419 |  |  |  | 2173913 | 536064 | 4.16x |

| scenario | Haskell / Node in each round (best of each side) | min |
|---|---|---:|
| relay round trip, 1 pair | 1.49 1.48 1.87 1.44 1.38 1.34 1.09 | 1.09x |
| relay round trip, 16 pairs | 1.19 1.07 1.18 1.36 1.10 1.42 1.33 | 1.07x |
| open-file POST+GET, 1 client | 0.92 1.10 1.00 1.11 0.92 0.99 0.79 | 0.79x |
| open-file POST+GET, 16 clients | 1.18 0.77 1.12 0.88 1.09 1.05 0.89 | 0.77x |
| resolve-ref, 1 client | 1.07 1.09 1.07 1.09 1.09 1.07 1.11 | 1.07x |
| resolve-ref, 16 clients | 1.01 1.92 1.09 1.21 1.34 1.10 1.12 | 1.01x |
| collab fan-out, 50 peers x 1000 msgs | 4.41 4.41 3.99 4.25 3.87 4.30 4.74 | 3.87x |
| collab fan-out, 200 peers x 200 msgs | 4.37 4.72 4.16 4.04 3.97 4.33 3.78 | 3.78x |

### Run B (commit 9a4d2b4, thread-per-connection relays, `-N2`; 9 reps; load average 7 → 186 → 37)

<!-- bench: superseded -->

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

<!-- bench: superseded -->

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

- **Static UI: 1.4–3.2x `vite preview`** by median (run G), and at
  least 1.07x in every round. Warp sends files with `sendfile`, and
  `petrus` keeps its one capability for it; the 592 KiB bundle is where
  the gap is widest (3.2x). The Vite dev server is slower still: it
  transforms its development page on every request.
- **`/temporal` proxy: 3.3x Vite (1 client) and 2.1x (16 clients).**
  Vite's proxy opens a new connection to Temporal for every request and
  closes the browser's connection after each answer; `petrus` keeps both
  alive (see [DIVERGENCES.md](../DIVERGENCES.md)).
- **MCP: 1.20–1.31x `server/mcp.mjs`** by median and at least 1.12x in
  every round, for a call that goes through the browser bridge and for
  one that does not, one at a time and 16 in flight. Per call, `petrus-mcp`
  uses about a third of Node's CPU time (70 us against 185 us with the
  bridge).
- **Cold start: about 32x.** `petrus FILE` serves the file and the UI
  11.6 ms after it is spawned (median); `bin/petrus.mjs`, which starts
  Vite through `pnpm exec vite`, takes 378 ms.
- **Collaboration fan-out: Haskell is 3.9–4.5x Node** by median in runs
  C, D and F, and at least 3.2x in every round.
- **Agent relay: Haskell is ahead of the bare-`ws` Node relay**, Node's
  best case: 1.09–1.41x median and at least 1.01x in every round of runs
  C, D and F (it was 0.81–0.98x on 16 pairs in run B). With the timing log
  on, `petrus` is 1.35x the Vite relay that `bin/petrus.mjs` runs (1 pair, run F).
  The HTTP front only sees a relay connection's upgrade request, which it
  hands to Warp; after that the relay loop owns the socket as before.
- **open-file and resolve-ref: ahead in every median** of runs E and F:
  open-file 1.14–1.20x (1 client) and 1.39–1.54x (16 clients),
  resolve-ref 1.16–1.17x and 1.31–1.37x. In run E the previous server
  (Warp) was 1.03x, 1.12x, 1.08x and 1.16x against the same Node servers
  in the same rounds, so the HTTP front adds 8–23% to every scenario.
  With the lean C client, a request is now cheaper than Node's: a `GET`
  that answers 204 takes 11.7 µs (Node about 19 µs, Warp 18.8 µs), a
  refused `POST` 14 µs (Node 25–31 µs), and 16 threads of resolve-ref get
  33.7k req/s (Node 21.9k, Warp 24.5k).
- **The lowest rounds.** 16-client rounds stay at or above 0.94x, and
  every resolve-ref round of run F is at or above 1.01x. The 1-client
  scenarios are the most exposed: a run is one request in flight at a
  time, so it runs at the speed of whichever core the scheduler gives the
  server and the client for that second. This machine has 4 performance
  and 6 efficiency cores, and other agents kept the load at 5–9. In the
  low rounds, servers drop together to about half speed. In run E, rounds
  2–4 of open-file at 1 client have three or four of the four servers at
  5.9–7.8k ops/s against 11–15k in most other rounds; the 0.66x is the
  round where only Node bare escaped. In run F, the 0.78x and 0.79x
  rounds are rounds 3 and 5. In round 5, Node bare itself fell to 5.6k
  while Vite kept 11.6k and `petrus` had 9.2k. In round 3, `petrus` had
  10.9k against Node bare's 14.0k. The same server's 1-client runs range
  over 9.2–16.9k (`petrus`) and 5.6–14.4k (Node bare) within run F. No
  server is slower in every round; each one loses some rounds to the
  machine. The 16-client scenarios keep several requests in flight and
  are much less exposed.
- **Runs A–D measured the load client more than the servers at 16
  clients.** With `http-client`, every server landed in the same band (about
  10–38k ops/s) and single rounds swung by tens of percent, which is why open-file and resolve-ref
  looked like parity there. The lean client runs the same requests, so
  the ratios of runs E and F are the servers' own.

## What the Haskell side does to get there

- **Relays as one event loop.** Each relay (agent and collaboration) is
  a single thread that owns all of its sockets after the HTTP upgrade:
  - it waits on them in one kqueue/epoll set, and the sockets stay
    registered;
  - it reads what is ready and decodes RFC 6455 frames with the `ws`
    library's checks and close codes;
  - it routes each message, and writes each receiver's queue with one
    `writev` at the end of the turn.

  There are no thread hand-offs or per-message I/O-manager registrations,
  and events reach every client in one total order, as in Node. The
  previous design ran a reader and a writer thread per connection, and
  every message paid a wake-up and a readiness registration with GHC's I/O
  manager. That cost it the 16-pair relay against bare `ws` (0.81–0.98x).
  The opening handshake is the `ws` library's, byte for byte
  (`Petrus.Viewer.Relay.Handshake`).
- **Relaying without re-serializing.** Text already in `JSON.stringify`
  form (what every known client sends) is relayed by splicing the sender
  id into the bytes (`Petrus.Viewer.Json.Canonical`, property-tested
  against the full parse and stringify path). Other text takes the full
  round trip.
- **The timing log.** To a file or a terminal (`/dev/null` in these
  runs), each `[petrus-relay-perf]` line is one `write` from the relay
  loop, synchronous as `console.log` is there. To a pipe, a background
  thread writes the lines. Run C still used the background thread
  everywhere; its hand-off cost `petrus` with the log on about 25% of the
  1-pair throughput.
- **The HTTP front.** `/__petrus/open-file` and `/__petrus/resolve-ref`
  are served by one event-loop thread (`Petrus.Viewer.HttpFront`,
  `cbits/http_front.c`), built like the relays. It owns the listening
  sockets and every connection in one kqueue/epoll set. Sockets stay
  registered, and a turn polls without blocking before it waits. Each
  ready connection gets one `recv`, its requests are parsed in place, and
  the answers go out in one `writev`. The front writes Node's framing
  byte for byte (status line, header order, `Date`, `Connection` /
  `Keep-Alive`, `Content-Length`, `100 Continue`, the 5 s idle close).
  It parses conservatively, and anything else hands the whole connection
  to Warp with the bytes already read: another path, an upgrade, a
  chunked body, an unusual request, or a resolve-ref that must fetch a
  URL. Warp paid a thread wake-up and a one-shot kqueue registration
  through GHC's I/O manager on every wait. With the lean C client, a
  `GET` that answers 204 now takes 11.7 µs (Warp: 18.8 µs, Node: about
  19 µs).
- **The MCP server.** Before this work, with 16 calls in flight,
  `petrus-mcp` was slower than Node (about 9k against 12–15k calls/s) and
  saturated its one busy core at about 88 + 26 us of user and system time
  per call. A ticky profile put most of the allocation in the pretty
  printer, a `Builder`. Three changes:
  - `JSON.stringify(v, null, 2)`, the text of most tool results, is now
    measured and written into one buffer, like the compact encoder. The
    text goes into the result as an already escaped JSON string, without
    a round trip through `Text`. This is the change that cut the CPU time:
    about 38 + 9 us per call at 16 in flight with `-N1`, in interleaved
    A/B runs against Node.
  - Standard input and the bridge WebSocket are served from one event loop
    (`Petrus.Viewer.Mcp.Reactor` on `Petrus.Viewer.EventLoop`), like the
    relays. Both stay registered with kqueue/epoll, and a turn reads
    whatever is ready, instead of one wait in GHC's I/O manager per line
    and per frame. On its own this made no difference the A/B runs could
    tell from noise; it removes a thread hand-off per message.
  - `PETRUS_PERF` lines go to standard error like the relay's timing
    lines: one unsafe `write` to a file or a terminal, a background writer
    for a pipe.
- **HTTP handlers.** File reads are unsafe foreign calls shaped like
  `readFileSync`: one call opens the file and learns its size
  (`cbits/file_io.c`), then the file is read up to that size. `resolve-ref`
  resolves plain relative paths against `file:///` bases without the URL
  state machine (property-tested against it). JSON string escaping is a
  small C routine (`cbits/json_escape.c`).
- **RTS defaults** for `petrus`, `petrus-collab` and `petrus-mcp`: `-N1 -qg -A16m`. That
  is one capability, like Node's one event loop. Request handling is short
  and I/O bound, and every extra capability adds cross-thread wake-ups to
  each request: `resolve-ref` at 16 clients ran 22.9–25.9k ops/s with
  `-N2` and 27.9k with `-N1` (bare Node: 26.1k), and `-N4` was slower
  still. A 16 MB allocation area makes collections rare. With the HTTP
  front, a 2 MB area (`-A2m`, which fits an efficiency core's cache) was
  measured against it in the same interleaved rounds (11 reps). The
  medians moved by −13% (open-file, 1 client), +2% (open-file, 16
  clients), −2% (resolve-ref, 1 client) and +9% (resolve-ref, 16
  clients). That is no consistent gain, so the defaults stay. `petrus-mcp`
  ran `-N2` before run G; with 16 calls in flight, `-N1 -qg -A16m` served
  as many calls per second (17.3–20.3k against 16.5–20.5k over three
  interleaved rounds) for less CPU (37 + 8 us per call against 45 + 20 us).
  Override with `+RTS … -RTS` (or `--rts` in the runner).
- **Memory.** `petrus` holds 82–86 MiB after runs A–D and 50–55 MiB after runs E–F; Vite holds 46–108
  MiB. `+RTS -M…` caps it if needed.
