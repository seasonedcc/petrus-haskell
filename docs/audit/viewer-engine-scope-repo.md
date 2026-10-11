# Audit: petrus-viewer, petrus-engine, scope, licensing, pins and CI

Audited commit: `3bfb6c9` (local `main`), with the four submodules at the
UPSTREAM.md pins. Audit date: 2026-10-11. Auditor slice: (i) petrus-viewer
non-UI capabilities, (ii) petrus-engine `fileVersion: "2"` loading, (iii)
scope completeness, (iv) licensing and attribution, (v) the repo-wide parts of
outcomes 1 and 7, plus a repo-wide scan of skipped and pending tests.

Every claim below was checked against the upstream source or by running the
checks. PARITY.md and README text were not taken on trust.

## 1. What was run

All runs under `nice -n 10`, `cabal -j2`, test binaries with `+RTS -M2G -RTS`,
in a fresh worktree (`git submodule update --init`, no prior `dist-newstyle`).

| Check | Result |
| --- | --- |
| `git submodule status` against UPSTREAM.md; `scripts/check-pins` | 4/4 pins match (gitlink, checkout and table) |
| `scripts/upstream-python petrus` and `petrus-engine` from scratch | provisioned CPython 3.14.6 and both frozen locks |
| `cabal build` of petrus-viewer-server and petrus-engine-file (clean worktree, `cabal.project.freeze`) | OK |
| `cabal.project.freeze` against the solver's `plan.json` | 136/136 external packages frozen, 0 mismatches, `index-state` present |
| `cabal test petrus-viewer-server --test-option=--fail-on=pending` | 99 examples, 0 failures, 0 pending |
| `petrus-engine-file-test --fail-on=pending` (live differential and format CLI against the pinned petrus-engine) | 971 examples, 0 failures, 0 pending |
| `pnpm install --offline --frozen-lockfile` and `pnpm build` in `upstream/petrus-viewer` | OK (pnpm 11.5.1 from `packageManager`, from the local store) |
| `scripts/interop --viewer petrus-viewer-server` (hspec interop groups, then `upstream-tests/run.mjs`, all 12 suites incl. headless Chromium) | 4 hspec examples; 101/101 Node tests (relay 5, endpoints 14, url-cache 9, cli 5, mcp 7, mcp-haskell-relay 7, collab 6, differential 4, wire 20, playwright 4, live 12, history 8) |
| `scripts/check-parity` | OK, 75 of 76 components at parity (hamsterdan end-to-end in progress) |
| `scripts/lint-skips` | OK, 415 test sources |
| `scripts/bench --check` (no benchmark run) | OK, 39 packages document a rerun block; summary current |
| Relative links in PARITY.md, SCOPE.md, UPSTREAM.md, README.md, docs/, every package `*.md` and `bench/RESULTS.md`, spec/, bench-results/ | 668 links, 0 broken (2 regex false positives inside code spans) |
| Upstream paths named in PARITY.md's "Upstream" column | 1 stale reference (fixed, VSR-9) |
| `scripts/upstream-diff petrus-viewer d6f4a52 ccb7808` | runs; see VSR-12 for what it does not list |
| GitHub Actions on `seasonedcc/petrus-haskell` (read-only `gh run list/view`) | see VSR-4 |

No benchmark was run. No process started by this audit remains.

## 2. petrus-viewer (slice i)

### 2.1 Inventory

Non-UI upstream source at `ccb7808`: `bin/petrus.mjs`, `server/collab.mjs`,
`server/mcp.mjs`, `server/openFileEndpoint.mjs`, `server/urlCache.mjs`, the
five plugins and the proxy and `publicDir` settings of `vite.config.ts`, and
`src/agent/protocol.ts`. Upstream tests that touch the backend: the 8 files
`tests/{bridgeVitePlugin,openFileEndpoint,resolveRefEndpoint,urlCache,petrusCli,mcpServer,collab-server}.test.mjs`
and `tests/playwright/bridge-live.test.mjs`. The other 39 test files
(`tests/*.test.ts`, 26; `tests/ui/*`, 13) test the browser code, which stays
TypeScript; none of them starts or talks to a backend.

41 capabilities, mapped:

| # | Capability (upstream) | Haskell | Checked by |
| --- | --- | --- | --- |
| 1–7 | CLI: no argument, file argument (`resolve`, "file not found" exit 1), URL argument (GitHub normalization, fetch, cache, `PETRUS_SOURCE_URL`, the three fetch error exits), `--no-open`, `-h/--help` text, unknown dashed arguments ignored, exit code and signal forwarding | `Petrus.Viewer.Cli`, `app/petrus` | `CliSpec` (8), upstream `cli` 5/5, `playwright` 4/4; help text and missing-file path also compared by hand against `node bin/petrus.mjs` (identical) |
| 8 | `/__petrus/open-file` GET/POST/OPTIONS, `PETRUS_OPEN_FILE` | `Endpoints`, `FileIO`, `HttpFront` | `EndpointsSpec`, upstream `endpoints`, `wire` (bytes against `node:http`), `live` |
| 9 | `/__petrus/resolve-ref` (local, http(s) with cache) | `Endpoints`, `UrlCache`, `Url` | `EndpointsSpec`, `UrlSpec`, upstream `endpoints` and `url-cache`, `differential` (WHATWG URL against Node, 6000 refs), `wire` |
| 10 | `urlCache.mjs`: `normalizeGitHubUrl`, `slugifyUrl`, `cacheRelativePath`, `cacheFile` | `UrlCache` | upstream `url-cache` 9/9 through the oracle, `differential` |
| 11 | Agent relay `/ws/agent` (welcome, `client_count`, `leave`, targeted and broadcast routing, non-object drop, `[petrus-relay-perf]` log) | `Relay`, `Relay.Frame`, `Relay.Handshake` | `RelaySpec`, upstream `relay` 5/5, `wire` (handshake, frames, closes byte for byte against `ws`), `differential` (relay output on generated messages) |
| 12 | Collaboration relay (`server/collab.mjs`, `pnpm collab`, Vite `/collab-ws` proxy) | `petrus-collab`, `/collab-ws` in `petrus` | `CollabSpec`, upstream `collab` 6/6, `wire` |
| 13 | `/temporal` proxy to `localhost:7243` | `Proxy` (`--temporal-target`) | `ServerSpec`, `ObservationSpec` |
| 14 | Static UI and `publicDir: examples` | `Static` (`--ui-dir`, the `pnpm build` output, which contains `examples/`) | `ServerSpec`, `playwright`, `live` |
| 15 | ngrok tunnel (`NGROK=1`, `pnpm dev:ngrok`) | not provided | documented in DIVERGENCES.md:17 only (VSR-13) |
| 16–31 | MCP: the 16 `petrus_*` tools (status, open_file, inspect_document/canvas/selection/simulation, preview/apply_mutation, undo, redo, simulation_command, scenario_save/compare, trace_import, trace_scenarios, screenshot) with upstream schemas and texts | `Mcp.Server`, `Mcp.Schema`, `Mcp.Bridge` | `McpSpec` (tool list in order, Node transcript byte for byte), upstream `mcp` and `mcp-haskell-relay` 7/7 each, `live` (all 16 through headless Chromium) |
| 32–36 | MCP plumbing: bridge URL resolution (`PETRUS_AGENT_URL`, defaults), dev-server auto-start, `PETRUS_MCP_BRIDGE_WAIT_MS`, `PETRUS_MCP_REQUEST_TIMEOUT_MS`, `PETRUS_PERF` | same | `McpSpec`, upstream `mcp` |
| 37 | Agent protocol envelope (`protocol.ts`) | runs in the browser, unchanged; typed port `Agent.Protocol` used for action names | `ProtocolSpec` (10), `live`; see VSR-11 |
| 38 | Simulation | runs in the browser (as upstream); backend part is the relay | `live` (simulation commands, scenarios), `playwright` |
| 39–41 | History replay (Temporal list, `get_schema`, `get_state`), live watching (polling), `petrus_trace_import` | `/temporal` proxy, plus `History.Observation` serving `observation-protocol-v1` producers as Temporal workflows, `Mcp.History` | `ObservationSpec`, `HistorySpec` (Haskell Engine and pinned Python producer, same answers at every step), `history` 8/8 in the browser, `live` |

Environment variables: every one upstream reads (`PETRUS_OPEN_FILE`,
`PETRUS_SOURCE_URL`, `PETRUS_AGENT_URL`, `PETRUS_MCP_BRIDGE_WAIT_MS`,
`PETRUS_MCP_REQUEST_TIMEOUT_MS`, `PETRUS_PERF`) is read by the Haskell
executables; `NGROK` is not (row 15); `VITE_COLLAB_ENABLED` is a build-time
UI flag. MCP: 16/16 tool names match; upstream registers no resources or
prompts.

Summary: 40 of 41 capabilities are ported and checked; 1 (ngrok) is a
documented omission. Every upstream backend test file runs verbatim (backend
construction rewritten, each rewrite exact-text-guarded) against Haskell and
passes. Divergences are documented in `packages/petrus-viewer-server/DIVERGENCES.md`.

### 2.2 Performance

Benchmarked against Node: agent relay round trips (1 and 16 pairs),
collaboration fan-out, open-file and resolve-ref at 1 and 16 clients; every
median is at least 1.09x (bench-results/summary.md:59). Not benchmarked: the
MCP server, CLI start-up and end-to-end CLI runs, static UI serving, the
`/temporal` proxy and the http(s) resolve-ref path (VSR-2).

## 3. petrus-engine `fileVersion: "2"` (slice ii)

Format features at `fc1dd50` (from `schema.py`, `types.py`, `loader.py`,
`json_formatter.py`, `cli/format_json.py`, `net_file_schema.json`):
`fileVersion`, `net`, `arcs` (`source`, `target`, `kind`
normal/read/inhibitor, `weight`, `metadata`), `places` (`initial`, `label`,
`interface`, `metadata`), `transitions` (`handler`, `guard`, `label`,
`metadata`, `delay` as seconds or duration string), `refs` (multi-file
mounts, cycles, duplicates, missing files), `viewState` (`layout`, `zoom`,
`pan`, `selected`, `arcWaypoints`, plus the viewer-only `annotations`), dotted
NetPaths, canonical writer, format CLI. All 7 top-level keys and all 6 model
definitions in `net_file_schema.json` are modelled in `Petrus.EngineFile.Types`.

| Evidence | Count | Verified |
| --- | ---: | --- |
| Differential corpus (`differential/corpus.json`) | 911 cases, 4618 operations (file 1894, load 913, dict 913, format 898): upstream 29, viewer 159 (incl. 157 re-saved by the viewer's own TypeScript), edge 323, fuzz 400 | counts recomputed from the file; all agree |
| Live differential against the pinned petrus-engine (corpus current, 3 fresh fuzz seeds × 300) | 4 examples | ran, pass |
| `petrus-format-json` against `python -m petrus.cli.format_json` | 40 scenarios | ran, pass |
| Upstream tests: loader 12, file_refs 4, resolution 10 of 11, json_formatter 3, timed 1 of 8, net_path (file-relevant) | | counts match upstream files; the out-of-scope ones (DSL round trip, runtime timers, `NetNav`, runtime/DSL/tokens/stubgen) are petrus-engine's runtime, superseded per SCOPE.md |

Verdict: net files load identically (acceptance, refusal class and text,
written bytes, resolved net and schema). `toKernel` is a documented Haskell
addition; DIVERGENCES.md §5 lists the nets the kernel refuses that
petrus-engine's own runtime would run. Gap: VSR-14.

## 4. Scope completeness (slice iii)

`gh repo list henriquebastos --limit 300` returns 61 public repositories (50
sources, 11 forks). A GitHub code search for "petrus" across the user hits
only petrus, petrus-engine, petrus-viewer, hamsterdan and beans (beans: two
design notes that list "Petrus integration" items as tracker examples).
Upstream dependency manifests (`pyproject.toml`, `uv.lock`,
`deployment/pi/package.json`) reference no other henriquebastos repository
except hamsterdan's own Petrus pin.

| Repository | Fork | Petrus-related | SCOPE.md | Agrees |
| --- | --- | --- | --- | --- |
| petrus | no | yes, the runtime | in scope | yes |
| hamsterdan | no | yes, the Petrus application | in scope (except `src/hamsterdan2`, argued) | yes |
| petrus-viewer | no | yes, editor and agent interface | in scope (non-UI) | yes |
| petrus-engine | no | yes, predecessor runtime and file format | in scope (fileVersion 2 loading) | yes |
| petrus-site, hamsterdan-site | no | websites | out (websites) | yes |
| henriquebastos.net | no | personal website | out (websites) | yes |
| CarlAdam | yes (of matthewryanscott/CarlAdam) | Petri nets, not Petrus | out, reason given | yes; fork status added |
| ariad | yes (of mirror-mind-ai/ariad) | development method; upstream Petrus vendors its `using-ariad` skill as dev tooling | out, reason given | yes; detail added |
| beans | no | agent issue tracker, no code dependency | out, reason given | yes |
| orbital | no | Pi remote workspaces, no dependency (hamsterdan's "orb" is Amp's) | out, reason given | yes |
| codex, pi-subagents (forks) | yes | third-party agent runtimes/extensions; Petrus drives Codex as an external system | covered by "every other" and "External systems" | yes |
| the other 48 (obsidian-reviewer, my-repo-skills, obsidian-dynamic-wide-content, jira-genie, requests-pro, zettelkasten, pi-fence, homebrew-tap (formulae: beans, jira-genie), career-ops, 2E-Lighting-Gateway, python-jsonstar, dictdeeper, pacote-desafios-pythonicos, eventex, pyitau, imovelweb, virtualenv-bootstrap, dsapp, monopoly, xlsweb, fixofx, jetpack, inputao, itauscraper, ipython-config, gnucash-to-beancount, smallactsmanifesto, googlegroupexporter, the-spreadsheet-quest, django-test-without-migrations, sqlformatter, django-aggregate-if, chipy8, dojorio, the-matrix-rain, danp, stallonecobra, kata, apihack, dgp-happy-numbers, free-programming-books, gridforme, wp-restructuredtext, slides-django-sem-trabalho, slides-chipy8, The-Zen-of-Python-Poster, autoword, crosscompileruby) | mixed | no | "every other repository" | yes |

No Petrus-related project is missing or misclassified. SCOPE.md now notes
that `ariad` and `CarlAdam` are forks (small correction in this commit).

## 5. Licensing and attribution (slice iv)

- Root `LICENSE` is byte-identical to `upstream/petrus/LICENSE` (Apache-2.0).
  Root `NOTICE` credits Henrique Bastos for petrus and hamsterdan
  (Apache-2.0) and for petrus-engine and petrus-viewer, reproducing their
  **MIT** licence (the goal says "Apache-2.0", but those two upstreams are MIT;
  the repo handles both correctly), and the Absurd schema.
- Every package has `LICENSE` byte-identical to the root one.
  `petrus-viewer-server/NOTICE` and `petrus-engine-file/NOTICE` reproduce the
  MIT notice as its terms require.
- Files copied verbatim from upstream (found by hashing every repo file
  against every upstream file): `absurd_schema/absurd-0.4.0.sql`,
  `petrus-execution/data/gondolin_sidecar.mjs`,
  `petrus-agenticus-runtime/data/pi_*helper.mjs` (3),
  `petrus-agenticus-core/test/conformance/catalog-*.json` (2), two
  `upstream/petrus/spec` fixtures in `petrus-viewer-server/test/fixtures`,
  `deployment/config/runtime.env`, `deployment/pi/package-lock.json`,
  `scripts/with-runtime-secrets`. None of the upstream originals carries a
  file header, so there is no header to keep; the copies are unmodified.
- Six package NOTICE files said "Petrus / Copyright Seasoned" (VSR-3, fixed).

## 6. Pins, reproduction and CI (slice v)

- **Outcome 1.** UPSTREAM.md pins all four upstreams that are used;
  `git submodule status`, the committed gitlinks and the table agree, and
  `scripts/check-pins` enforces it in CI. Upstream `main` of petrus-viewer and
  petrus-engine has no commits past the pins. The move-the-pin procedure
  works (`upstream-diff` ran), with gaps listed in VSR-12. The reference
  CPython (3.14.6) is pinned in `scripts/upstream-python`; Hamsterdan's own
  Petrus pin (`89baf78`) is recorded.
- **Reproduction.** Following docs/reproducing.md from a clean worktree
  worked for this slice: submodules, uv provisioning, a build that honours
  `cabal.project.freeze` (consistent with the plan), the tests, and the viewer
  suites after `pnpm install`/`pnpm build`.
- **CI.** `.github/workflows/ci.yml` runs on push to `main`, on every pull
  request and on dispatch; job `check` runs `scripts/check-all` (pins,
  lint-skips, Python provisioning, `cabal build all` with `-Werror`,
  `scripts/interop --check`, `cabal test all` under PostgreSQL 17,
  `scripts/bench --check`, `scripts/check-parity`), and job `container` lints
  and builds the image and runs `scripts/container-smoke`. `check-all` never
  passes `--viewer` and the workflow installs no pnpm or browser (VSR-1).
- **PARITY.md** covers every in-scope component of all four upstreams
  (cross-checked against `upstream/petrus/src/petrus` module list and the
  viewer and engine inventories above); all evidence links resolve.
- **Benchmarks.** Every package with a benchmark stanza (39) has a rerun block
  that `scripts/bench --check` validates. The four without a stanza are
  `hamsterdan-cli`, `hamsterdan-e2e`, `petrus-test-support`, and
  `petrus-telemetry` (left to the telemetry slice).

### 6.1 Skipped and pending tests (repo-wide scan)

CI's last full `check` log (run 38134729883) shows exactly 5 pending examples
(rows 1, 2, 3, 7, 9). Nothing in `packages/*/upstream-tests` or the Python
drivers skips (`lint-skips` enforces the latter).

| # | Test (file:line) | Gate | Runs in CI | Legitimately opt-in upstream? |
| --- | --- | --- | --- | --- |
| 1 | `petrus-agenticus-runtime/test/.../PiApplicationSpec.hs:921` | exact Pi qualification packages in `/tmp/petrus-pi-a2-probe` | no | yes, upstream skips the same way |
| 2 | `PiApplicationSpec.hs:924` | `PETRUS_CV16_PI_APPLICATION_QUALIFY=1` | no | yes |
| 3 | `PiModelPhaseSpec.hs:733` | exact Pi qualification packages | no | yes |
| 4 | `PiSpec.hs:154` | `node` on `PATH` | yes | no: an environment gate, not opt-in (VSR-15) |
| 5 | `petrus-agenticus/test/.../WorkspaceSpec.hs:104` | `PETRUS_TEST_DOCKER=1` | yes (CI sets it) | yes |
| 6 | `petrus-execution/test/DockerSpec.hs:97` | `PETRUS_TEST_DOCKER=1` | yes | yes |
| 7 | `petrus-execution/test/E2bSpec.hs:302` | always pending | no | upstream is opt-in (`PETRUS_RUN_CV10_E2B=1` + `E2B_API_KEY`); the Haskell one cannot be opted into (VSR-10) |
| 8 | `petrus-execution/test/GondolinSpec.hs:205`, `:307` | `node` on `PATH` | yes | no: environment gate (VSR-15) |
| 9 | `GondolinSpec.hs:744` | real Gondolin SDK and image env vars | no | yes |
| 10 | `petrus-test-support/src/Petrus/TestSupport/Postgres.hs:113` (used by Fabric `Conformance/Setup.hs:86,133`, `DemoSpec.hs:184`, Processes `DemoSpec.hs:106`, DST `JoinedWorlds.hs:233`, and every Postgres suite) | `PETRUS_TEST_POSTGRES` | yes; `check-all` wraps `with-postgres` and refuses CI without it | yes (infrastructure) |
| 11 | `petrus-impetus/test/.../DotSpec.hs:304` | Graphviz `dot` | yes | no: environment gate (VSR-15) |
| 12 | `hamsterdan-operator/test/SecretLaunchSpec.hs:132` | bash ≥ 4.4 (pending on macOS's bash 3.2) | yes | no: environment gate (VSR-15) |

## 7. Findings

| ID | Outcome / scope item | Severity | Evidence | Suggested fix |
| --- | --- | --- | --- | --- |
| VSR-1 | Outcome 7 (and 2, viewer): every change to main checked automatically | **blocker** | `scripts/check-all:58-77` never calls `scripts/interop --viewer`; `.github/workflows/ci.yml:14-55` sets up no Node 22, pnpm or Playwright; `scripts/interop:190-196`. The viewer's PARITY evidence (`packages/petrus-viewer-server/PARITY.md:37-50`): the verbatim upstream server tests (57 runs), byte-for-byte `wire` comparisons against `ws`/`node:http` (20), V8/WHATWG `differential` (4), the upstream Playwright suite (4), `live` MCP (12) and `history` (8) never run in CI. Only the 99 hspec examples do. A change that broke the wire bytes or the UI path could land on a green main. | Add a CI job: `actions/setup-node` 22 with `pnpm/action-setup` (pnpm 11.5.1), `pnpm install --frozen-lockfile && pnpm build` in `upstream/petrus-viewer`, `npx playwright install --with-deps chromium`, `scripts/upstream-python petrus`, then `scripts/interop --viewer petrus-viewer-server` (or add `--viewer` to `check-all` behind a flag CI sets). Cache the pnpm store and Playwright browsers. |
| VSR-2 | Outcome 6 (viewer): end-to-end CLI/app runs benchmarked | major | `packages/petrus-viewer-server/PARITY.md:77-78` ("startup is not benchmarked"), `:93-94` (MCP "cost is the relay's"); `bench/RESULTS.md:52-56` lists only relay, collab, open-file and resolve-ref scenarios. `petrus-mcp` parses JSON-RPC, validates arguments and formats results, so its cost is not the relay's. | Add scenarios to `bench/run.mjs`: an MCP `tools/call` round trip (`petrus-mcp` vs `node server/mcp.mjs`, same relay and fake browser, e.g. `petrus_inspect_document` and `petrus_scenario_compare`); `petrus` cold start to first answer vs `bin/petrus.mjs`; static `index.html` and asset serving vs Vite; `/temporal` proxying. Optionally a process-level `petrus-format-json` vs `python -m petrus.cli.format_json` row in petrus-engine-file. |
| VSR-3 | Scope: upstream attribution preserved | major (**fixed in this commit**) | `packages/{petrus-fabric,petrus-processes,petrus-engine-absurd,petrus-engine-postgres,petrus-history-postgres,petrus-motus-absurd}/NOTICE` credited "Petrus / Copyright Seasoned"; upstream Petrus is by Henrique Bastos (`upstream/petrus/pyproject.toml:14-16`). These files ship in each package's sdist (`extra-doc-files`). | Done: now "Petrus (https://github.com/henriquebastos/petrus) / Copyright 2026 Henrique Bastos". |
| VSR-4 | Outcome 7: main is checked and green | major | `gh run list`: main CI failed on `10c9c7a` (run 38134729883: `petrus-execution` `test_local_collection_drains_large_output_and_kills_sigterm_ignoring_process`) and `517d360` (run 38129412600: `petrus-agenticus-runtime` "interop: the reference's Activity client and Worker replay through the Haskell runtime service"); a `flake-fix` branch is in flight and `3bfb6c9` was still running. Both suites passed on other runs, so these are flaky tests. | Land the flake fixes (owners: execution and agenticus slices); consider a required status check on `main` so a red run blocks the next merge. |
| VSR-5 | Scope: licensing, per-package notices | minor | 26 packages have no NOTICE (`packages/hamsterdan-contracts`, `hamsterdan-github`, `petrus-impetus`, `petrus-agenticus*`, `petrus-execution`, ...), including two that ship verbatim upstream files: `petrus-agenticus-runtime/data/pi_*helper.mjs`, `petrus-execution/data/gondolin_sidecar.mjs`. No package has a cabal `copyright:` field; all say `author: Seasoned`. Apache-2.0 §4(d) does not require it (upstream Petrus has no NOTICE), but an sdist of these packages carries no credit to Henrique Bastos. | Add a short NOTICE to every package that ports upstream code ("Haskell port of henriquebastos/petrus, Copyright 2026 Henrique Bastos, Apache-2.0"; name the verbatim files), list it in `extra-doc-files`, and add `copyright:` fields. |
| VSR-6 | Outcome 7: viewer interop selection | minor | `scripts/interop:101` selects `petrus-viewer-server` groups with the pattern `"upstream"`, which matches 3 incidental examples (help text, tool order, transcript). `scripts/interop petrus-viewer-server` without `--viewer` reports a pass while running none of the viewer's cross-language suites. | Point the pattern at the hspec groups named after upstream test files (`tests/`) and print a notice that the Node suites need `--viewer`. |
| VSR-7 | Outcome 7: reproducing.md | minor | `docs/reproducing.md:6-8` and `:130-131` say CI runs "the same `scripts/check-all`" and that check-all "already runs these groups"; neither covers the `--viewer` suites. CI does not pin Node (runner default) though the doc requires Node 22. | Say explicitly that the viewer suites are outside check-all (until VSR-1 is fixed); add `actions/setup-node` with 22 to the `check` job. |
| VSR-8 | Viewer: MCP golden transcript | minor | `packages/petrus-viewer-server/test/McpSpec.hs:4` says the session covers "every tool"; `test/fixtures/mcp-requests.json` has no `petrus_redo` or `petrus_inspect_simulation` call (they are exercised only by the `live` browser suite, which CI does not run). | Add both calls to the fixture and re-record the Node transcript. |
| VSR-9 | Outcome 7: PARITY.md accuracy | minor (**fixed in this commit**) | `PARITY.md:40` cited `motus/dispatch/{__init__,inline,memory}.py`; `inline.py` and `memory.py` do not exist at the pin (both classes live in `motus/dispatch/__init__.py:90,194`). Also `packages/petrus-engine-file/PARITY.md` said LiveSpec and CliSpec go pending without the venv; they provision it and fail loudly (`test/Petrus/EngineFile/LiveSpec.hs:36-42`), and the corpus regeneration command used an unpinned `--python 3.14`. | Done: path corrected; engine-file text and regeneration command (now `scripts/upstream-python petrus-engine`) corrected. |
| VSR-10 | Outcome 2: pending tests | minor | `packages/petrus-execution/test/E2bSpec.hs:301-302` is always pending; `packages/petrus-execution/PARITY.md:90` calls it "opt-in skip, as upstream", but upstream's runs when opted in (`upstream/petrus/tests/petrus/motus/test_private_execution_substrate.py:696-703`), while the Haskell provider's default SDK loader always fails like a missing `e2b` module (DIVERGENCES.md:16). Upstream does not depend on `e2b` either, so default behavior matches. | Reword PARITY.md:90 to "never runs: no Haskell E2B SDK", or bind the E2B REST API so the live test can be opted into. (Execution slice to confirm.) |
| VSR-11 | Viewer: agent protocol tests | minor | `packages/petrus-viewer-server/test/ProtocolSpec.hs` has 10 examples against 19 upstream cases (`tests/agentProtocol.test.ts`, `agentParseRegression.test.ts`); not covered: Infinity in numeric fields, unknown error codes, missing additional result fields, `selectedEdgeToRef`, named event payloads, the fixture set. `petrus-viewer-oracle` exposes `parseAgentMessage` but no differential test calls it. Impact is low: the parser that matters runs in the browser, unchanged, and the Haskell side uses only action names. | Either port the remaining cases (or drive them through the oracle against `protocol.ts`), or state in PARITY that `Agent.Protocol` is an unused typed mirror. |
| VSR-12 | Outcome 1: move-the-pin procedure | minor | `scripts/upstream-diff:9,12` diffs only `src spec tests scripts server bin`, so it misses `vite.config.ts` (the viewer's relay, proxy and endpoint plugins), hamsterdan's `deployment/` (the container contract is ported), and `pyproject.toml`/`uv.lock` (cel-python, psycopg versions shape behavior). `UPSTREAM.md:20-29` does not say to commit the new gitlink (`check-pins` compares `HEAD`'s tree) or to regenerate recorded corpora and fixtures (e.g. `petrus-engine-file/differential/corpus.json`, `petrus-viewer-server/test/fixtures/mcp-transcript-node.txt`). | Add those paths to `upstream-diff`; add "`git add upstream/<name>` and commit" and "regenerate the recorded corpora (list)" steps to UPSTREAM.md. |
| VSR-13 | Viewer: ngrok capability in PARITY | minor | The `ngrokTunnel` plugin (`NGROK=1`, `pnpm dev:ngrok`) is omitted with a rationale in `packages/petrus-viewer-server/DIVERGENCES.md:17` but is absent from PARITY.md's petrus-viewer table. Also `petrus-mcp`'s auto-start runs `petrus --no-open` without a UI directory unless `PETRUS_UI_DIR` is set or the working directory holds `./dist`, so the auto-started server answers "Petrus UI not configured" where upstream's `pnpm run dev` serves the UI. | Add an "out of scope" row for the ngrok tunnel; have auto-start pass `--ui-dir` from `PETRUS_UI_DIR` (or a default install location) and document it. |
| VSR-14 | Scope (ii): format tooling | minor | Root `PARITY.md:135` lists `net_file_schema.json` as covered, but nothing in `petrus-engine-file` checks its models against that JSON Schema or regenerates it (`petrus-cli gen-json-schema`, `upstream/petrus-engine/src/petrus/cli/main.py:28-34,37-54`). `gen-stub` (DSL stubs) is reasonably out of scope but unlisted. | Add a test that validates the corpus's accepted files against `net_file_schema.json` (and refused ones where the schema can tell), or mark `gen-json-schema`/`gen-stub` out of scope in petrus-engine-file/PARITY.md. |
| VSR-15 | Outcome 7: pending on missing tools | minor | Rows 4, 8, 11, 12 of §6.1: tests go pending when `node`, Graphviz or bash ≥ 4.4 is missing; `lint-skips` only polices the Python reference and `check-all` does not pass `--fail-on=pending`, so a CI image without one of them would pass silently. Today CI has all three (only the 5 expected pendings appear). | Make these fail under `CI` (as `check-all` already does for PostgreSQL), or have `check-all` fail on any pending outside an allow-list of the opt-in ones. |
| VSR-16 | Outcome 5: wire-level divergences | minor | `packages/petrus-viewer-server/DIVERGENCES.md:103-121`: requests handed to Warp (chunked bodies, http(s) resolve-ref, other routes) lack Node's `Connection: keep-alive`/`Keep-Alive: timeout=5` headers, and pipelined requests are strictly ordered. Bodies and status codes are identical; documented with rationale. | None required; consider emitting the two headers on Warp-served responses for byte parity. |

## 8. Verdicts

| Outcome / scope item | Verdict |
| --- | --- |
| Scope (i) petrus-viewer non-UI capabilities on Haskell | **Holds.** 40/41 capabilities ported and verified by running every upstream backend test file plus 48 own cross-implementation tests (all pass); the ngrok tunnel is a documented omission (VSR-13). |
| Scope (ii) petrus-engine fileVersion 2 loads | **Holds.** 4618 differential operations, live fuzzing and the format CLI agree with the pinned petrus-engine; minor tooling gap VSR-14. |
| Scope (iii) completeness of SCOPE.md | **Holds.** All 61 public repositories classified; no Petrus-related project missing or misclassified. |
| Scope (iv) licensing and attribution | **Holds after this commit** (VSR-3 fixed); per-package notices remain uneven (VSR-5). |
| Outcome 1 pinned parity | **Holds.** Procedure works; documentation gaps VSR-12. |
| Outcome 2 conformance (this slice) | **Holds for the viewer and engine slices** when the viewer suites are run (they were, all pass). Repo-wide pendings are legitimate except VSR-10 and the environment gates in VSR-15. |
| Outcome 3 interoperability (this slice) | **Holds.** The unchanged UI talks to the Haskell backend byte for byte; history comes from Haskell and Python producers with identical answers; engine files round-trip identically with Python. |
| Outcome 4 Fabric/processes contract | Not in this slice; `spec/fabric*.md` and `spec/processes*.md` exist and PARITY rows link evidence. |
| Outcome 5 better the Haskell way | **Holds for this slice.** Divergences are documented with rationale; wire bodies unchanged (VSR-16 minor). |
| Outcome 6 performance (this slice) | **Does not fully hold.** Engine-file and the benchmarked viewer paths are ahead of the reference; the MCP server and end-to-end CLI runs are not benchmarked (VSR-2). |
| Outcome 7 verifiability | **Does not hold.** A clean rebuild and rerun works, PARITY.md and its links are sound, but CI never runs the viewer's cross-implementation suites (VSR-1) and main CI is intermittently red (VSR-4). |
