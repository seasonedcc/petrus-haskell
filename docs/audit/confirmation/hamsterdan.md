<!-- Dated record: confirmation audit at d869f62 (2026-10-12). Every finding is resolved or decided; see ../final.md. -->

# Confirmation audit: Hamsterdan (hamsterdan-*, deployment/, docs/hamsterdan.md)

Repository `main` at `d869f62` (2026-10-12). Pin `upstream/hamsterdan` =
`5d382467eaa4ff837cbd6b93012c99081e0153f9` (`scripts/check-pins`: ok).
Scope target: behaves like the current production Hamsterdan (V5, `src/hamsterdan`) at that pin.

Counts: **BLOCKER 0, MAJOR 2, MINOR 12.**

## Method

- Re-checked each FA-H item of `final-audit/hamsterdan.md` against the code and its fixing commit.
- Ran: `scripts/lint-hamsterdan-architecture`, `check-pins`, `lint-skips`, `check-parity`.
  `scripts/interop --check` started a cabal build, so I stopped it (PIDs I started, killed by
  exact PID) and removed the `dist-newstyle/` it had just created (gitignored, created at the
  moment of my run). The tree is clean (`git status`). Interop and corpora evidence below come
  from CI instead.
- CI: the latest run that executed the test jobs is 38232074972 at `e861f5d`. `git diff e861f5d HEAD`
  touches no `packages/hamsterdan-*`, `deployment/` or `docs/hamsterdan.md` file. Later runs
  skipped tests (README/bench-only changes); the run for `d869f62` was in progress.
- Fresh reading: host API/serve/uvicorn layer, service worker/pump/release, ExceptionClass,
  Sqlite, export parallelism, operator POSIX/C and JSON fast path, contracts PyLiteral writer,
  github transport/HTTP, all hamsterdan DIVERGENCES "Observable"/"Runtime" sections,
  deployment vs upstream deployment (Containerfile, unit template, Ansible, release.py),
  env-var inventory vs upstream, a dead-export scan (script in `confirm-audit/hamsterdan/scripts/`),
  and a module-reference check of every hamsterdan .md.

## Earlier findings: status

| ID | Status | Evidence |
| --- | --- | --- |
| FA-H-1 surrogate-refusing reads | Resolved | `2d7fe58`: `pythonJsonLoads` (keeps) vs `surrogateRefusingLoads`; host reads use the former (Cli.hs:255, Agenticus.hs:425/497, Ingress.hs:814/829, Service.hs:227, Binding.hs:133, Pi.hs:581, Tape.hs:59). Refusing loader kept only where pydantic/jiter is the reference (Codec.hs:405, GitHub Client.hs:456, Coverage.hs:760). Live-reference cases CliSpec.hs:395-401, agents InteropSpec.hs:223-225. |
| FA-H-2 overflow bound | Resolved | Cli.hs:280, 364-366 (`abs i >= 2^1024 - 2^970`); CliSpec.hs:403-405 (pr 13/14). |
| FA-H-3 `float()` emulation | Resolved | `62bfaf5`: one `parsePythonFloat` in petrus-json (PythonText.hs); host Cli.hs:155-157, argparse Parser.hs:963 and CEL use it. |
| FA-H-4 Haskell type names in stored state | Resolved (one closable residue, m4) | `Hamsterdan.Sqlite.translated` (Sqlite.hs) raises the CPython `sqlite3` class; `Host/ExceptionClass.hs` is a closed list with a suite check ("names each Hamsterdan failure by a class the pinned reference defines", passes in CI). |
| FA-H-5 uvicorn lines | Resolved | `Hamsterdan.Host.Uvicorn` + `Api.serve` (startup/shutdown/access lines, proxy headers, bind failures, colors by stdout isatty); CliSpec/UvicornSpec. Remaining h11/connection items documented (host DIVERGENCES 1), but see m9. |
| FA-H-6 secret-launch child | Resolved | operator test/Fakes.hs:244-248 calls `installationFromEnvironment` and asserts the direct key; PARITY.md:94-101 corrected. |
| FA-H-7 one exception type | Mostly resolved (residue m5) | `7de3adc`: `PyError` and the host `TypeError` newtype gone; `pattern TypeError` over `PythonException` (Host/Python.hs:77-85). |
| FA-H-8 parallelism / lifespan ownership | Resolved (but see M2) | Parallel.hs: pure `parallelMap` (par/pseq; `parallel` not in the freeze), `forConcurrently` writers; Api.hs:283-296 `withAsync` worker. |
| FA-H-9 two argparse ports, string-keyed lookups | Resolved | `d2e421e`: `petrus-argparse` with a typed applicative `Arg`; host Cli.hs:118-150 decodes into `HostCommand`; no `lookupText`/`lookupInteger` left in hamsterdan sources. |
| FA-H-10 partial `spelling` | Resolved | Codec.hs:326-352 total `Enumeration`; `class Spelled` gone; `CodingRequest.kind` stays `Text` with a stated reason (commit `ab25546` message). |
| FA-H-11 github item 8 rationale | Resolved | github DIVERGENCES.md:119-124. |
| FA-H-12 stale claims | Resolved as listed (new stale claims: m2, m3) | readiness PARITY.md:66 (339), agents DIVERGENCES.md:57 (PAX), operator PARITY.md:94-101. |
| FA-H-13 help colors | Resolved | petrus-argparse `_colorize`; host DIVERGENCES 3. |
| FA-H-14 journeys clone URL | Resolved | GitPublish.hs:192-195, 427-477 `extraGitConfig`; testing DIVERGENCES.md:80-82. |

## Findings

### MAJOR

**M1. hamsterdan-operator carries its own C/FFI POSIX layer duplicating petrus-posix.**
- packages/hamsterdan-operator/cbits/stat.c, cbits/rmtree.c (202 lines of C),
  src/Hamsterdan/Operator/Posix.hs:46-120 (`Stat`, `fdStat`, `lstat`, `statAt`, `isDirectory`,
  `isRegular`, `isSymlink`, `permissionBits`, `rmtree`, `confstr`).
- petrus-posix already provides exactly these through a safe interface:
  `Petrus.Posix.At.statAt :: Maybe Fd -> FilePath -> Follow -> IO FileStat` (lstat is
  `statAt Nothing p NoFollowLinks`), `fdStat`, `isDirectory`, `isSymbolicLink`,
  `permissionBits`, plus `openDirectoryAt`, `listDirectoryFd`, `unlinkAt`,
  `removeDirectoryAt` (At.hs:16-45, 178-252). stat.c's stated reason, "the unix package has
  neither fstatat nor confstr", is false for the repo, which has petrus-posix.
- Why it matters: Outcome 5 and the standing design rule. Low-level code must live "in the
  lowest layer that can hold it", and there must be no needless duplication. This is a second
  `struct stat` marshalling layer in a domain package. Its `withCString` also uses the locale
  encoding, not the fs encoding that petrus-posix's `withPath` handles.
- rmtree.c does have a recorded measurement (operator bench/RESULTS.md:143-147). It belongs in
  petrus-posix as a Haskell walk over `openDirectoryAt`/`listDirectoryFd`/`unlinkAt`/
  `removeDirectoryAt`, or as one C helper there.
- Fix:
  - Delete cbits/stat.c and the stat FFI, and use `Petrus.Posix.At`.
  - Move `rmtree` and `confstr(_CS_PATH)` to petrus-posix, with the measurement beside them.
  - Have the operator depend on petrus-posix.

**M2. Optimizations in high-level Hamsterdan packages lack the measurement the standing rule
requires.**

The README rule: optimize only "where a benchmark shows the clean version cannot keep up with
the Python", in the lowest layer, with the justifying measurement recorded beside it. Three
cases fall short:

- packages/hamsterdan-operator/src/Hamsterdan/Operator/FastJson.hs (204 lines).
  - It is a second hand-written JSON parser, over `Data.Text.Internal` and `A.unsafeIndex`,
    in front of `Hamsterdan.Python.Object.loadsText`.
  - DIVERGENCES.md:88-96 and FastJsonSpec cover its correctness only. Neither
    operator bench/RESULTS.md nor the DIVERGENCES file shows that the clean path is slower
    than CPython.
  - If it is needed, the right layer is petrus-json (for example a parse-to-builder or fold
    interface that produces `PV` directly), not the operator.
- packages/hamsterdan-export/src/Hamsterdan/Export/Parallel.hs:1-77.
  - It parses and renders in parallel, and writes in parallel with a remove-and-rewrite
    fallback on failure. It also changes file-creation order (DIVERGENCES.md:64-75).
  - RESULTS.md shows only the parallel figures (in process 1.08–1.63×). No sequential run
    shows that the plain `map`/`mapM_` falls below 1.0×.
- packages/hamsterdan-contracts/src/Hamsterdan/PyLiteral.hs:188-315.
  - The dashboard-literal printer is an unchecked `TA.unsafeWrite`/`copyI` writer into a
    buffer sized by a hand-proved `bound`. I checked the bound and it holds.
  - contracts bench/RESULTS.md:68-78 lists it under "Getting there took these changes", with
    no figure for the clean (`pythonStrRepr`/Builder) version.
  - It also duplicates petrus-json's exact-size writer one layer up.
- Why it matters: Outcome 5 and the standing rule. These add unsafe or concurrent complexity
  to domain packages without the evidence that licenses it.
- Fix, for each:
  - Benchmark the clean version against Python and record the figure beside the code. Where
    the clean version is at or above 1.0×, revert to it.
  - Otherwise, move the primitive into petrus-json, behind a safe, total interface.

### MINOR

**m1.** packages/hamsterdan-github/DIVERGENCES.md:203-209 (item 14) misstates the reference.
- It says "httpx's `trust_env=True` honors HTTPS_PROXY…". But upstream builds every client with
  `"trust_env": False` (upstream/hamsterdan/src/hamsterdan/github_app/auth.py:84, used for the
  App and installation clients, :77/116/129).
- So the reference ignores proxy variables and `SSL_CERT_FILE`, exactly as `noProxy` does. The
  only real difference is CA source: certifi's bundle against the system store.
- Fix: rewrite the item to say that (Outcome 5: divergences documented truthfully).

**m2.** Documentation names modules that do not exist.
- packages/hamsterdan-agents/DIVERGENCES.md:93-98 cites `Hamsterdan.Host.Random.urandom`.
  Random bytes now come from `Petrus.Json.Python.randomBytes` (PiA2.hs:47, PiWorkspace.hs:69).
- packages/hamsterdan-export/PARITY.md:25 cites `Hamsterdan.GitHub.Python`.
- Fix both names.

**m3.** Stale example counts.
- packages/hamsterdan-github/PARITY.md:63-66 says "200 examples (162 + 38)". CI runs 205.
- packages/hamsterdan-testing/PARITY.md:167 says "215 examples". CI runs 216.
- `test_readiness_campaign.py` has three different counts: "13 (12, plus a property)" at
  testing PARITY.md:117, "12 campaign" at :167, and "6, as 11 examples" in root PARITY.md:136.
- Fix: reconcile the numbers, ideally with a check like `check-parity`'s upstream-count check.

**m4.** `Host/ExceptionClass.hs:102` names every `IOException` `"OSError"`.
- CPython's `type(error).__name__` is the PEP 3151 subclass (`FileNotFoundError`,
  `PermissionError`, …), and the port already has that table:
  `Hamsterdan.Python.Exception.errnoClass`/`ioException`
  (hamsterdan-contracts Exception.hs:95-135).
- Use it for an `IOException` with an errno. Host DIVERGENCES 4 then shrinks.
- The errno table and a `strerror` FFI are also duplicated in
  petrus-engine-file/src/Petrus/EngineFile/PyText.hs:131-147. One copy belongs in petrus-json,
  next to `PythonException`.

**m5.** FA-H-7 residue: two exception representations are still bridged.
- petrus-engine-file's `PyException` is converted at hamsterdan-export Files.hs:299 and
  hamsterdan-operator Operator/Python.hs:107.
- petrus-motus's `ValueError`/`RuntimeError`/`LookupError` newtypes are bridged by
  `raisePython` (Host/Python.hs:87-93), so `ExceptionClass` must list both families.
- Fix at the source: make `PyException` an alias or pattern for `PythonException`, and the
  motus newtypes pattern synonyms over it.

**m6.** `urllib.parse.quote` and the `int()` digit limit are re-implemented locally.
- `quote`:
  - Api.hs:225-236 (`quote` plus a hand `hex` with `!!`);
  - Uvicorn.hs:236-246 (`logPath`'s `quote` via `printf`);
  - the dependency already exports `Hamsterdan.Python.Url.quote :: Text -> Text -> Text`.
- `int()` with the 4300-digit limit:
  - Uvicorn.hs:357-361 has its own `pythonInt`;
  - it duplicates `Petrus.Argparse.Parser.pythonInt` (Parser.hs:956-959).
- Hex-digit helpers are duplicated in GitHub Url.hs:105 and Client.hs:233.
- Fix: use the shared functions.

**m7.** `Uvicorn.gaiFailure` (Uvicorn.hs:459-473) recovers a getaddrinfo error code.
- It calls `gai_strerror` on a guessed range of codes and matches the message text, through an
  FFI import inside the host package.
- Fix: return the code from a small binding in petrus-posix, or drop the code if no test needs
  it. The same applies to `strerror` in hamsterdan-contracts Exception.hs:135.

**m8.** `ServiceHooks` puts test seams on the production service.
- `ServiceHooks` (Service.hs:428-449, stored in `HostService.hooks :: IORef`) has seven
  test-override hooks: `workerOverride`, `projectPendingOverride`, `runDueOverride`,
  `activateOverride`, `reconcileRegistrationOverride` and two `around…` hooks.
- They are read on every pump and worker start. They are documented only by a code comment
  ("The reference tests' instance monkeypatches"), while `reconcileHook` is documented in host
  DIVERGENCES (Internal).
- Fix: either list them in DIVERGENCES (Outcome 5: every API divergence documented), or make
  them construction-time `ServiceOptions` so production values are immutable.

**m9.** Host DIVERGENCES item 1 says "A second CTRL+C does not force the shutdown". That is
inaccurate.
- `serve` installs `CatchOnce` handlers (Api.hs:375-381), which reset the signal to `SIG_DFL`.
  A second SIGINT or SIGTERM therefore terminates the process at once: no lifespan shutdown,
  no `Service.close`, no "Finished server process".
- uvicorn's `force_exit` also skips the lifespan shutdown, but it still logs and re-raises.
- Fix: correct the sentence, or implement `force_exit`: skip the lifespan shutdown, log
  "Finished server process", and re-raise.

**m10.** Dead exports. Each is exported, defined, and never used anywhere in `packages/`:
- Agents/Validate.hs: `resultKindText`
- Host/AgentRuntime.hs: `composeAgentRuntime` (production uses `composeAgentRuntimeWith`,
  Host/Agents.hs:107)
- Contracts/Codec.hs: `anyJson`, `literalInteger`, `mapCodec`
- Host/Python.hs: `dumpsCompactSortedText`, `rowValue`
- Host/Service.hs: `applicationKeys`
- Operator/Python.hs: `dictKeys`
- NetV5/Py.hs: `strictInteger`
- NetV5/Folding.hs: `tokenColors`
- NetV5/Gating.hs: `routingParameter`, `routingSource`, `routingTargets`, `routingTransition`
- Testing/Journeys.hs: `journeyFromName`, `phaseName`
- Testing/World.hs: `revealEffect`

Fix: delete them, or document the ones kept as upstream API mirrors.

**m11.** docs/hamsterdan.md is still written as a plan, and parts are stale.
- §6 lists an `interop/hamsterdan/` harness, which does not exist. The harnesses are each
  package's `differential/` directory and hamsterdan-e2e.
- §6 still calls the operator "optional … lowest priority", but it is ported, and still gives a
  "Suggested order".
- §3's "suggested equivalents" (`sqlite-simple`, `toml-parser`, servant, a `TVar` token cache)
  are not what was built.
- Fix: mark §3 and §6 as historical, or update them to the built packages.

**m12.** Container reproducibility and its documentation.
- deployment/Containerfile:38-43 fetches `ghcup` unpinned. This is acknowledged in operator
  DIVERGENCES.md:159-162 as "not done yet", but it weakens Outcome 7 (clean rebuild). Fix: pin
  it by version URL and SHA-256.
- operator DIVERGENCES.md:153-155 says the data-dir lines are "the only runtime-stage
  instructions besides the binaries' and the shim's COPY that the reference does not have".
  The runtime `apt-get` line also adds `libbz2-1.0 libffi8 libgmp10 liblzma5 zlib1g`
  (Containerfile:87), which only PARITY.md:191-192 records. Fix: add them to that sentence.

### Note outside this area

- `scripts/interop --check` builds the test suites with cabal. It is not the lightweight check
  the brief lists.
- `check-parity` reports every hamsterdan benchmark row STALE: they were measured at `5a73d7a`,
  and their dependency closure has changed since (petrus-sqlite at HEAD). For verify-perf.

## Verified to hold

- **Pin.** `upstream/hamsterdan` is at `5d38246` (check-pins ok). docs/hamsterdan.md §0.2:
  `git diff 1eef74a 5d38246 -- src` is empty, so the pin is production's source.
- **Tests (CI 38232074972 at `e861f5d`, no hamsterdan change since).** Every hamsterdan suite
  passed with 0 pending:

  | Suite | Examples |
  | --- | ---: |
  | contracts | 403 |
  | github | 205 |
  | readiness | 339 |
  | host | 392 |
  | agents | 145 |
  | export | 42 |
  | operator | 293 (SecretLaunchSpec and ContainerSpec included on Linux) |
  | testing | 216 over 10 shards |
  | e2e | 31 (tier B 17) |

- **Corpora and interop (same run, `checks` job).** `interop --check` selected 8998 examples
  over 42 packages; `check-corpora`: 51 generators, 71 files current.
- **Container (same run, `container` job).** "Every runtime-contract check passed for
  hamsterdan:ci": the launcher byte for byte, secrets through the systemd unit's flags,
  `validate`, and `serve` `/healthz` against a fake GitHub over TLS.
- **Architecture.** `scripts/lint-hamsterdan-architecture`: 95 modules follow upstream's import
  boundaries.
- **Skips.** `scripts/lint-skips`: 482 test sources, no silent skip on a missing reference.
- **Parity table.** `scripts/check-parity`: 76/76 components at parity; 27 cited upstream test
  counts match the recorded collection.
- **Deployment inputs.** deployment/config/installations.toml, config/runtime.env,
  pi/package.json and pi/package-lock.json are byte-identical to upstream.
- **Containerfile.** It keeps the reference runtime stage's base digest, user/group 10001, the
  0700 state directory, ENV, labels, port, ENTRYPOINT and CMD. The interpreter-path shim
  answers every `python` invocation the deployment tooling makes:
  - systemd unit template line 13;
  - ansible/runtime.yml:258 and configure.yml:158 (`-m hamsterdan.host validate`);
  - candidate.yml:108-111 (version print);
  - release.py:279-282 (version assert).
- **Environment.** The set of environment variables the port reads equals upstream's
  `src/hamsterdan`, plus uvicorn's `FORWARDED_ALLOW_IPS`. `HAMSTERDAN_E2E_*` are read only by
  hamsterdan-e2e's app (Host.hs).
- **Service loop.** `worker`/`pump`/`runDue`/`release` follow service.py:493-875 step for step:
  - the startup sweep, a 0.25 s poll and a 60 s sweep;
  - the pump lock, `project_pending`, then `run_due(100)`, the stop check, the per-instance
    pending-custody skip, and the dispatch-repair wakes;
  - the shutdown order and first-failure-wins close.
- **Lifespan.** `withLifespan` matches api.py's: reconcile, then the worker task, then stop,
  await and close in `finally`.
- **Webhook route.** `POST /github/webhooks` streams with the 400 "request body is too large"
  bound, decodes latin-1 header pairs, and answers 202 with `custody`, `delivery_id` and
  `disposition`. FastAPI and Starlette fallbacks (405 with `allow`, 307, 404) are reproduced.
- **GitHub transport.** It follows upstream's `trust_env=False`, `follow_redirects=False`,
  `auto_retry=False` and no timeout (githubkit `build_timeout(None)`). Transport failures map
  to `GitHubBoundaryError` with detail `http_transport`, as transport.py:70-84 and 137-151 do.
- **Pi runner.** Its policy matches pi.py:252-270 and 499-516: `maxToolCalls = 32`,
  `pollInterval` 0.1, the ordered timeout validation and `host-timeout` cancellation.
- **Not re-litigated.** The earlier audit's "not findings": pydantic error text, the operator
  grammars, the `PV` model, the readiness overlays and the World command parse.
