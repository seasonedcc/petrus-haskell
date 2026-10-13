<!-- Dated record: confirmation audit at d869f62 (2026-10-12). Every finding is resolved or decided; see ../final.md. -->

# Confirmation audit: viewer-repo (petrus-viewer-server, repo root, scripts, CI, docs)

Repo: `petrus-haskell` main at `d869f62` (= origin/main). Read-only. No cabal build; no pnpm install.

What was run or read:
- CI for HEAD `d869f62`:
  - push run 38259575603: green. 44 of 44 suites ran, none reused. `petrus-viewer-server-test` passed with 114 examples. Every viewer suite passed: relay 5/5, endpoints 14/14, url-cache 9/9, cli 5/5, mcp 7/7, mcp-haskell-relay 7/7, mcp-node-haskell-relay 7/7, collab 6/6, protocol 19/19, differential 4/4, wire 20/20, playwright 4/4, live 12/12, history 8/8. `record-mcp-transcript.mjs --check` passed.
  - full dispatch run 38255030541: green, including bench-smoke and all four bench-gate shards.
- The nightly schedule run 38204999198 (`e6a624b`) fired and was full. Its build log shows `DIST_KEY …-full-38204999198-…` and every local package compiling from scratch.
- Run locally under the machine's python3 and under `/usr/bin/python3` 3.9.6, with identical results:
  - `scripts/check-parity`: 76/76, with 62 STALE warnings.
  - `scripts/check-pins`, `scripts/ci-tests check-steps` (14 steps), `scripts/lint-skips`, `scripts/bench --check` (42 of 46 files STALE), `parity_check.py` (0 unaccounted), `upstream-test-counts --check` and `lint-hamsterdan-architecture`: all pass.
  - `node packages/petrus-viewer-server/test/record-node-corpora.mjs --check`: both corpora match Node v22.22.0.
- A hash scan of every tracked file against all four submodules (for verbatim copies), and every link and path in the root and viewer docs checked for existence.
- Read-only `gh` calls: branch protection, rulesets, the visibility of henriquebastos repositories, and the run list against main's commits.
- Read the upstream viewer's `vite.config.ts`, `bin/petrus.mjs`, `server/*.mjs`, `src/App.tsx` and `src/collaboration.ts` at the pin.

## Earlier findings (final-audit/viewer-repo.md): status

| Finding | Status | Evidence |
| --- | --- | --- |
| FA-R-1 (blocker): `.cabal` edits ignored under cached dist-newstyle | **Resolved** | `.github/actions/cabal-dist/action.yml:61-64` deletes `dist-newstyle/cache` after the touch, and every job goes through this one action. `scripts/ci-tests` `check_plan_is_current` fails when `plan.json` disagrees with any `packages/*/*.cabal`. Full runs restore nothing (`action.yml:35`, `ci.yml:72-78, 113-119`); the nightly log confirms a from-scratch build. The comments and `docs/reproducing.md:598-611` now describe the mechanism correctly. |
| FA-R-2: Arx missing from SCOPE | **Resolved** | `SCOPE.md:26`. Also viewer `README.md:96-104` and `PARITY.md:284-290`. |
| FA-R-3: main not gated; cancel-in-progress | **Partly resolved** | Fixed: `ci.yml:56-58` gives one group per run on main with no cancel; `reproducing.md:570-573` now states that main is unprotected. Still open: there is still no protection (`gh api …/branches/main/protection` returns 404, rulesets `[]`). The new claim that every commit gets its own run is not accurate (m3 below). |
| FA-R-4: Node-recorded viewer fixtures never re-recorded | **Resolved** | `ci.yml:285-286` and `scripts/check-all:155-156` run the transcript recorder with `--check`. `scripts/check-corpora:380-414` covers the V8 and WHATWG corpora through `test/record-node-corpora.mjs`, and that check passes locally. |
| FA-R-5: `/temporal` proxy and content codings | **Resolved** | `Proxy.hs:54-82`: `decompress = const False`, the browser's `Accept-Encoding` passed through (empty when it sent none, which http-client drops), `withResponse` + `responseStream`. Documented accurately in `DIVERGENCES.md:104-114` and tested in `test/ProxySpec.hs`. |
| FA-R-6: performance evidence never re-measured | **Mostly resolved** | Fixed: results carry a `measured sources … at COMMIT` marker; `bench --check` and `check-parity` list STALE files; a nightly bench-gate exists. Still open for the viewer: it is excluded from the gate, and its smoke runs only `micro` (m2). |
| FA-R-7: stale example counts | **Resolved** | `PARITY.md:21` says 114, which matches the CI ledger. CliSpec has 10 examples and Relay+Protocol 31. The package PARITY.md is now stale in a different way (m1). |
| FA-R-8: stale check-all step list | **Resolved, one slip** | `reproducing.md:111-161` lists steps 0-14 in check-all's order. Step 4 omits `petrus-sdks` (m5). |
| FA-R-9: bridge action as `Text` | **Resolved** | `Mcp/Bridge.hs:360-372` defines `data BridgeAction = ProtocolAction RequestAction \| CanvasScreenshot`. Every call site uses constructors (`Mcp/Server.hs:381, 499, 581, 640, 704`). |
| FA-R-10: dead `toolPassthroughArgs` | **Resolved** | `Mcp/Server.hs:57-62`: `Tool` has 4 fields. |
| FA-R-11: fixtures as `data-files` | **Resolved** | `petrus-viewer-server.cabal:25-28` declares them as `extra-source-files`. |
| FA-R-12: run.mjs counts skips as passes | **Resolved** | `upstream-tests/run.mjs:269-271` also requires `pass === tests`. |
| FA-R-13: duplicated CI block | **Resolved** | It now lives in one composite action, `.github/actions/cabal-dist`. |
| FA-R-14: Node MCP on the Haskell relay only exercised by the bench | **Resolved** | `run.mjs:115-124` defines `mcp-node-haskell-relay`; it passed 7/7 in CI. |

## New findings

Counts: **BLOCKER 0 · MAJOR 2 · MINOR 7**

### MAJOR-1: `petrus` turns collaboration on by default. The UI then waits 3 s before loading the file and syncs every open tab. DIVERGENCES says "as before".

- Upstream behavior:
  - `vite.config.ts:9-10, 214, 244` enables the collab client and the `/collab-ws` proxy for the dev server only when Vite runs with `--host`. `bin/petrus.mjs` runs `pnpm exec vite [--open]` without `--host`, so the upstream `petrus` CLI runs with `VITE_COLLAB_ENABLED=false`.
  - In that mode `App.tsx:297-302` loads the file immediately (`loadLocal()`).
  - A production build (`pnpm build`) always sets the flag to `true`.
- The Haskell `petrus` serves that build (`DIVERGENCES.md:14`), and always answers `/collab-ws` in process (`Server.hs:207-208`, `DIVERGENCES.md:15`). The built UI therefore:
  - connects to the relay (`App.tsx:322`);
  - receives `peer_count` 1, i.e. 0 peers (`collaboration.ts:156-157`);
  - waits out `waitForPeers(3000)` (`App.tsx:326`, `collaboration.ts:397-415`) before it calls `loadLocal()`.
- Under `vite preview`, the upgrade fails and `onclose` resolves at once. So only the Haskell server shows these behaviors:
  - every `petrus FILE` shows the net about 3 s late;
  - two tabs on one server mirror each other's schema edits, which the upstream CLI never does.
- `DIVERGENCES.md:15` says "The browser build decides whether to use collaboration (`VITE_COLLAB_ENABLED`), as before". That is inaccurate: the build now always decides "yes".
- The browser suites still pass because they wait for `browser_ui_ready` with generous timeouts (`live-mcp.test.mjs:152-156`, `history-live.test.mjs:151-159`). This was found by reading the code; I could not reproduce it at runtime without a UI build.
- Outcome affected: 5 (specified, user-visible behavior diverges, and the divergence is documented as "no divergence"). The CLI is an in-scope capability.
- Fix:
  - Mirror Vite's rule: serve `/collab-ws` from `petrus` only when `--host` is given (or behind an explicit `--collab`). Otherwise refuse the upgrade, so the UI's `onclose` path loads locally at once.
  - `petrus-collab` stays as the standalone relay.
  - Add a browser test asserting that `petrus FILE` renders the net well under 3 s, plus a two-tab isolation test.
  - Correct DIVERGENCES. At the very least, document the delay and the cross-tab sync honestly.

### MAJOR-2: low-level code without the measurement the standing design rule requires, and one case where the recorded measurement says the clean version was enough

- The rule (README:20-23) allows a low-level optimization only where a benchmark shows the clean version cannot keep up, with that measurement beside it.
- `Petrus.Viewer.Mcp.Reactor`:
  - It runs `petrus-mcp`'s stdin and bridge socket on the kqueue/epoll `EventLoop` (`cbits/relay_io.c`), with unsafe FFI reads, and puts the pipes into O_NONBLOCK (`DIVERGENCES.md:98-103`).
  - The recorded measurement says the opposite of a need: `bench/RESULTS.md:785-787`: "On its own this made no difference the A/B runs could tell from noise".
  - The module's own comment contradicts that: `Mcp/Reactor.hs:8-13` says the I/O-manager path "with requests in flight dominated the cost of a tool call".
  - The CPU win came from the pretty-printer change (`RESULTS.md:777-783`).
- `cbits/file_io.c` (open+fstat in one call, then unsafe `read`) and `cbits/json_escape.c` (`Json.hs:143-158`, an SWAR escaper under `unsafeDupablePerformIO`) are justified only by prose: `RESULTS.md:791-796` says "File reads are unsafe foreign calls…", "JSON string escaping is a small C routine". No A/B against the clean Haskell version (a `bytestring` Builder escape; `B.readFile`) is recorded.
  - Run A is labelled "before the C string escaper", but its table measured other changes too, and its relay and endpoint scenarios do not isolate the escaper.
- By contrast, the relay and HTTP-front loops are justified: 16-pair relay at 0.81-0.98x before; endpoint rounds below 1.0x before the front.
- Outcome affected: 5 and the standing design rule; the comment contradicts the measurement.
- Fix:
  - Return `petrus-mcp`'s stdin and bridge to the GHC I/O manager (the clean version). Keep the Reactor only with an A/B that shows a gap against Node.
  - Measure `file_io.c` and `json_escape.c` against their clean Haskell equivalents in the same interleaved rounds. Record the figures beside them (in RESULTS.md and the module header), or drop them.
  - Fix the Reactor comment either way.

### MINOR

**m1: the package PARITY.md is stale against run H and contradicts the root PARITY.md.**
- `packages/petrus-viewer-server/PARITY.md` (lines 56-69, 81-98, 117-127, 151-158, 170-171, 193-205, 223-269) still argues from runs C-G:
  - for example, relay 16 pairs at "1.17x / 1.31x / 1.09x";
  - rounds below 1.0x "explained" at length.
- But `bench/RESULTS.md:113-124, 142-286` marks E-G superseded by run H. Run H is ≥ 1.10x in every round, with relay 16 pairs at 1.82x.
- The root `PARITY.md:175-178` cites run H. A reader of the package file gets an outdated and more defensive performance story.
- Outcome affected: 7.
- Fix: rewrite the package's performance tables from run H, and keep earlier runs only as history in RESULTS.md.

**m2: viewer performance is never re-measured automatically, and the STALE signal is too coarse to act on.**
- The viewer is excluded from bench-gate (`reproducing.md:366-367`). Its nightly smoke runs only the in-process `micro` rows (`RESULTS.md:20-31`), never the Node comparison. The `viewer` job already has Node, pnpm and the built UI.
- Staleness is package-granular. The viewer's results are flagged STALE because `petrus-json`'s `Encode.hs` changed (`baf5836`, `9e691e8`), yet the viewer imports only `Petrus.Json.Float` (`Json/Number.hs:27`).
- One such change marks 42 of 46 files and 62 components STALE (`scripts/check-parity`), and the warning stops meaning anything.
- Outcome affected: 6 and 7.
- Fix:
  - Add a nightly `node packages/petrus-viewer-server/bench/run.mjs --quick` direction check (Haskell ≥ Node per scenario) to the `viewer` job or a bench-gate shard.
  - Consider fingerprinting by the module closure actually linked, or let a passing bench-gate row clear STALE for its component.

**m3: "every commit pushed to main gets a complete run of its own" is not true, and main is still ungated.**
- `ci.yml:52-55` and `reproducing.md:567-569` say every commit pushed to main gets a complete run of its own. Only the tip of each push runs. For example, `baf5836` (a `petrus-sqlite`/history-store source change) has 0 runs (`gh api …/actions/runs?head_sha=…`); `9e691e8`, `da94728` and `3f1c30a` likewise.
- With no protection or ruleset, red commits land: run 38198678253 failed on `test (8)` at `5e6b05a`.
- The state of main is verified by its tip's run (the HEAD runs are green), so outcome 7 holds in substance, but the wording overclaims.
- Fix:
  - Say "every push to main". Alternatively, run CI per commit of a push.
  - Add a ruleset requiring the `ci` check, as reproducing.md suggests.

**m4: the upstream viewer's UI-side tests are not accounted for.**
- `upstream/petrus-viewer/tests/*.test.ts` (27 files) and `tests/ui/**` (vitest; `pnpm test:unit`/`test:ui`) appear nowhere in the viewer PARITY. By contrast, PARITY.md has "Upstream tests not ported" tables for petrus (`:80-97`) and hamsterdan (`:143-167`).
- Most belong with the TypeScript UI (out of scope by design). Several, though, encode the UI's expectations of the backend:
  - `temporalClient`/`temporalState`/`temporalSchema` (the `/temporal` shapes);
  - `openFileBoot` (the open-file endpoint);
  - `resolveRef`/`unifiedRefLoader`/`githubUrl` (resolve-ref).
- Outcome affected: 2 and 7 (the repo should show that every upstream test is either ported or out of scope).
- Fix: add a "Upstream tests not ported" table to the viewer PARITY.md that names each file group, says it tests the unchanged UI, and points to the Haskell-side evidence for the backend-facing ones (`history`, `live`, `endpoints`).

**m5: `docs/reproducing.md` has small gaps for a fresh machine.**
- `reproducing.md:190, 220` say `npx playwright install chromium`. On a fresh Ubuntu, Chromium also needs its system libraries: CI uses `--with-deps` (`ci.yml:280`).
- The Ubuntu block (`:42-50`) installs neither pnpm nor Docker.
- Step 4 (`:124-126`) omits `petrus-sdks`, which `scripts/check-all:117` provisions.
- `README.md:33` says `docs/` holds "the audits", but none are there.
- Otherwise the page is accurate and complete: prerequisites, private clone, preflight, step order, resources, caches, bench, corpora and container. Its CI table matches `ci.yml`.
- Outcome affected: 7.
- Fix: correct the four points.

**m6: documented JavaScript-emulation gaps remain behavior divergences.**
- `DIVERGENCES.md:144-167` lists them:
  - IDNA without UTS #46 mapping, so `ﬀ` in a `$ref` host resolves to a different URL than Node's;
  - a malformed-JSON message from a history server folds a cut surrogate to U+FFFD.
- They are documented with reasons and exotic in practice. But outcome 5 says specified behavior never diverges, so they are open gaps, not design choices.
- Fix: track them as known gaps (not "divergences by design") in PARITY.md, or close the IDNA one with a mapping-table port.

**m7: package metadata and installed artifacts.**
- All 43 `.cabal` files have `maintainer: danielweinmann@avatarnaturalfoods.com`, while `author`, `copyright` and NOTICE say Seasoned. This looks like a cabal-init default; confirm that it is intended.
- `petrus-viewer-oracle` (`petrus-viewer-server.cabal:126-131`) is a test-only helper that `cabal install` would install as a user-facing executable. Gate it behind a flag, or make it part of the test suite (the test binary already doubles as the chain producer).
- Nit: `ToolResult JsString Bool` (`Mcp/Server.hs:64-66`) is boolean-blind; `ToolOk | ToolError` would read better.

## Verified holds (with evidence)

- **Viewer capabilities on the Haskell backend.** Each was confirmed against HEAD's CI run 38259575603:
  - CLI: `cli` 5/5, CliSpec 10, `playwright` 4/4.
  - MCP:
    - the 16 tools, with names identical to `server/mcp.mjs`;
    - `mcp`, `mcp-haskell-relay` and `mcp-node-haskell-relay` all 7/7;
    - the golden transcript byte for byte, re-recorded from Node in CI.
  - Agent protocol: `relay` 5/5, `protocol` 19/19 (upstream tests verbatim against the Haskell parser), `wire` byte-equality with `ws`.
  - Collaboration: `collab` 6/6 and wire equality with `server/collab.mjs`.
  - Simulation: relayed `simulation.*` and scenario tools in `live` 12/12. Upstream simulates in the browser too.
  - History replay and live watching: `HistorySpec` (Haskell Engine and Python reference, the same answers at every step), `history` 8/8 in the browser, `ProxySpec`.
  - The UI stays the upstream TypeScript bundle, as allowed.
  - The one capability-level problem found is MAJOR-1.
- **`run.mjs` integrity.** Upstream test files are copied verbatim. Rewrites must match exactly (`run.mjs:184-191`). Skips fail a suite. `ci-tests run-viewer` refuses when `VIEWER_GROUPS` differs from `run.mjs`'s suite list (`ci-tests:729-737`).
- **Scope.**
  - `gh repo list henriquebastos` was rechecked. The four pinned repos are public, and each `pushed_at` equals its pin date, so the pins are current upstream HEADs.
  - Every Petrus-related repo is recorded with a reason: petrus, hamsterdan, petrus-viewer and petrus-engine in scope; petrus-arx, CarlAdam, ariad, beans, orbital and the sites out.
  - The repos new since the last audit (obsidian-reviewer, my-repo-skills, jira-genie, obsidian-dynamic-wide-content, dsapp, pi-fence, the codex and pi-subagents forks) have no references in any upstream tree, so the "every other" row covers them.
  - The only upstream mention of `orbital` is a config-path convention in a Hamsterdan decision record.
- **Pins.** `UPSTREAM.md` SHAs equal the gitlinks and the checkouts (`check-pins`). The "Moving a pin" checklist now covers the viewer's Node corpora and transcript.
- **Licensing.**
  - The root LICENSE is Apache-2.0, identical to upstream petrus's.
  - The root NOTICE credits petrus and hamsterdan (Apache-2.0), reproduces the MIT text for petrus-engine and petrus-viewer, and names the Absurd schema.
  - All 43 packages have LICENSE, NOTICE, `license: Apache-2.0`, `license-file` and NOTICE in `extra-doc-files`.
  - All 14 verbatim copies found by the hash scan are attributed in their package NOTICE or the root NOTICE: the viewer's 2 spec fixtures, the agenticus conformance JSON and Pi helpers, the gondolin sidecar, the Absurd SQL, and `deployment/*` plus `scripts/with-runtime-secrets` under hamsterdan-operator.
  - Upstream has no NOTICE file to carry forward under Apache §4(d).
- **CI.**
  - Every check-all step but Benchmarks is a named CI step (`check-steps`).
  - The verdict job fails unless every job succeeded. Only test, viewer and bench jobs may be skipped, and the ledger proves every planned suite passed (`ci.yml:454-499`).
  - Reuse requires an identical input hash covering the package closure, the paths referenced by name and relatively, everything outside `packages/` but prose, and the toolchain (`ci-tests:21-58, 270-320`).
  - The nightly and a `full` dispatch build from an empty dist-newstyle, rerun every suite, and add bench-smoke and the 4-shard bench-gate. The full dispatch on HEAD (38255030541) is green end to end.
- **`check-parity` semantics.** It does what `reproducing.md:519-534` says:
  - non-empty evidence for "at parity";
  - a DIVERGENCES.md for every package named;
  - no cited bench row below 1.0 (excluding "before", superseded and min/worst columns);
  - the upstream pytest counts cited match `docs/upstream-test-counts.json`;
  - STALE as a warning.

  It is honest but narrow. It does not check that cited test files exist (I checked them by script: no broken local links in PARITY, README, SCOPE, UPSTREAM, the viewer docs or reproducing.md), nor the hard-coded suite counts (currently correct), nor STALE beyond a warning (m2).
- **Scripts.** Every Python script parses and the lightweight ones run under Python 3.9.6, the documented minimum. `upstream-diff`'s path lists cover the viewer's Vite config, locks and examples.
