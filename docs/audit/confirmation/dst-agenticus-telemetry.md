<!-- Dated record: confirmation audit at d869f62 (2026-10-12). Every finding is resolved or decided; see ../final.md. -->

# Confirmation audit: DST, test-support, Agenticus (core, agenticus, runtime), telemetry

Repository: `petrus-haskell` `main` at `d869f62` (= `origin/main`, clean tree). Nothing in the repository was modified.

## Evidence base

- **CI at HEAD.** Run 38259575603 at `d869f62` passed every job: build, lint, checks, viewer and test 1–10.
- **Per-suite counts.** They come from run 38232074972 at `e861f5d`. No file in this area has changed since; `git diff e861f5d HEAD` over the seven packages is empty.

  | Suite | Result |
  | --- | --- |
  | `petrus-telemetry-test` | 36 examples, 0 failures |
  | `petrus-telemetry-instrumentation-test` | 58 examples, 0 failures |
  | `petrus-test-support-test` | 11 examples, 0 failures |
  | `petrus-agenticus-core-test` | 667 examples, 0 failures |
  | `petrus-agenticus-test` | 170 examples, 0 failures |
  | `petrus-agenticus-runtime-test` | 445 examples, 0 failures, 12 pending (9 live-provider gates, 3 qualification packages, all declared in `check-pending`) |
  | `petrus-dst-test` | 285 examples, 0 failures, 0 pending (CI sets PostgreSQL) |

- **Corpora.** The CI `checks` job regenerated every corpus in the area, and all were current: the 10 `petrus-dst` corpora, the agenticus catalog, effect, hands, thread, custody, retention, workspace and agent-net corpora, the hosts, Pi, Codex and runner corpora, and the telemetry scenarios.
- **Test mapping, checked mechanically.** I collected 458 unique `def test_*` names under `upstream/petrus/tests/petrus/{agenticus,telemetry}`. Each one appears in the Haskell test sources, either by its exact name or with its underscores turned into spaces. The single exception is `test_elapsed_time_before_span_entry_fails_with_lifecycle_error`, which is documented as unrepresentable (telemetry DIVERGENCES 13).
- **Additional checks.** I ran `scripts/bench --check` (see the Notes section), ran a toy GHC 9.10.3 program in scratch for the language point in CA-2, and read the pinned upstream sources directly.

## 1. Earlier findings: all ten resolved

| Finding | Status | Evidence |
| --- | --- | --- |
| FA-S-1 invalid `IMPETUS_TELEMETRY_LEVEL` fails after a durable write | **Resolved** | `a656ff4`. Reading the level is now total: `environmentLevel` holds an `Either`, and `levelRef` falls back to `Off` (`Petrus/Telemetry.hs:188-216`). `validateTelemetryEnvironment` (`:205`) is the first step of every constructor whose upstream module imports `petrus.telemetry`. I enumerated upstream's importers (instance, the jsonl and postgres stores, `_coordination`, dispatch local and absurd, worker, fabric/postgres, processes/postgres) and matched each one to a call site: `Instance.hs:628,690`, `Jsonl.hs:252`, `HistoryStore/Postgres.hs:270`, `Engine/Internal.hs:231`, `Local.hs:264,515,537`, `Absurd.hs:753,897`, `Worker.hs:231,402,410`, `Fabric/Postgres.hs:218`, `Processes/Postgres.hs:112`. `InvalidLevelSpec` runs a child process and checks that no file is written and no record is appended; it is green in CI. DIVERGENCES item 1 has been rewritten to match. |
| FA-S-2 Pi A5 settlement codes | **Resolved** | `f5e2362`, `PiApplication/Internal.hs:662-671,704-714,763-808`. A `waitExit` that returns `Nothing` now raises `OtherError "TimeoutExpired"`, and unhashable `type`, `code` and `method` raise CPython 3.14's `TypeError`. I checked the guard ordering against `pi_application.py:466-529,559-562`: the abort check comes first, then the `"ready"` comparison, then set membership, and the method check runs only after the earlier `or` operands. All of these settle as `runtime-failed`. Twelve forged-helper scenarios are checked against the reference, and `pi.md` application items 3–4 are gone. |
| FA-S-3 `RuntimeTerritoryProfile` invariants | **Resolved** | `b9d6483`, `Runtime/Profiles.hs:97-148`. A `Qualification` sum replaces the separate fields, the constructor is hidden, `expectation`, `archetype` and `descriptor` are `HasField`-derived, and `mkRuntimeTerritoryProfile` refuses an empty reason with upstream's text. `catalog.md` item 4 has been updated. CA-2 below covers the remaining gap in that same claim. |
| FA-S-4 Claude and Amp sidecars never run on the real SDKs | **Resolved** | `3f860d7`. `scripts/upstream-python petrus-sdks` installs the frozen-lock `claude-agent-sdk 0.2.128` and `amp-sdk 0.1.20260729121202`. `PinnedSdkSpec` runs ungated, and its three examples are green in CI (job 114766266897). A recorded gated-probe run is in `docs/live-provider-acceptance.md`. CA-7 is a small leftover. |
| FA-S-5 global `StableName` cache | **Resolved** | `29ad1cb`. `unsafePerformIO` is gone from `Connection/Storage.hs`. `trustedLoad :: Maybe (IO ValidatedSnapshot)` sits on the storage, and `ValidatedSnapshot`'s constructor is private (`:174-180`). `Custody.hs:841-846` validates every load from host storage, as upstream does. |
| FA-S-6 `error` for invariants the types could carry | **Resolved** | `e9c5070`. `CodexOperation.binding` stores the validated `MotusAttachmentBinding` (`Codex.hs:696`, `:1049`) and `operationBinding` is gone. `claim` returns `Claim`, and `Waiting` is internal to `Lookup` (`Gateway.hs:411-459`). |
| FA-S-7 hand-rolled DST process capture | **Resolved** | `31ce058`. One `captureWithin` in `campaigns/Petrus/Testing/Dst/Process.hs` drains both streams with `withAsync` inside `withCreateProcess`. On timeout the campaign uses `killNow` (SIGKILL, then wait), as `subprocess.run` does. |
| FA-S-8 a failed Hedgehog example leaves its World open | **Resolved** | `639a507`. `bracketExample` (`Campaign/Machines.hs`) wraps everything after `forAll` in `bracket` through `mkTestT`/`runTestT`. The `Opened` IORef is removed and the DIVERGENCES entry is closed. |
| FA-S-9 two `test_world.py` tests used a different method | **Resolved** | `7d4e320`. `Spec/EngineWorlds.hs` now runs the predicate-poll budget test over `Projection.engineProfile` with upstream's exact budget. `Spec/Surface.hs` asserts the supported surface: no re-export outside `petrus-dst`, the main library imports nothing from the runtime, no Engine or Coordinator in any export list, the context arity, and the `apply` shape. |
| FA-S-10 stale PARITY claims | **Resolved as listed** | `f72a800` corrects all four cells. Later changes have made other counts stale, though (CA-6). |

## 2. Fresh findings

**Counts:** 0 BLOCKER, 3 MAJOR, 6 MINOR.

### CA-1: MAJOR. DST refuses lone UTF-16 surrogates that the reference admits, a wire divergence the rest of the area has already closed

- **Where.** `packages/petrus-dst/src/Petrus/Testing/Dst/Internal/StrictJson.hs:23-27,58-64` (`loneSurrogate`), documented in `packages/petrus-dst/DIVERGENCES.md`, "Lone UTF-16 surrogates are refused".
- **What is wrong.** `decode_artifact` and `_load_strict_json` (`testing/dst.py:2337-2361`) admit `\ud800`-style escapes, and `encode_artifact` writes them back with `ensure_ascii`. The port refuses any artifact, run spec or progress frame that contains one. Its own documentation says it does so although "the loader, the validators and the canonical encoder agree with the reference on surrogates in string values". The reason given for keeping the refusal concerns only object *keys*, where pydantic-core's `model_dump` mangles a surrogate into U+FFFD per byte, or raises for typed keys.
- **Why it matters (outcomes 3 and 5).** The goal says "wire formats ... never diverge", and outcome 3 requires exchange without loss. Every other JSON boundary in this area already admits surrogates through petrus-json's WTF-8 strings:
  - custody (`divergences/custody.md` item 13);
  - Codex (`codex.md` item 5);
  - Pi (`pi.md` item 6);
  - History (`805e139`).

  DST is the only outlier, and its refusal is wider than its own rationale requires.
- **Fix.**
  1. Load with petrus-json's surrogate-admitting options (as `pythonJsonLoads` does), so that values round-trip exactly as they already do elsewhere.
  2. Either reproduce pydantic-core's documented key behavior (one U+FFFD per byte of the `surrogatepass` encoding, last value wins on collision; `UnicodeEncodeError` for `dict[str, int]` keys), or keep a refusal for surrogate *keys* only and narrow the DIVERGENCES entry to that.
  3. Add a value-surrogate artifact to the raw-bytes corpus and to `Spec.ToolingInterop`, in both directions.

### CA-2: MAJOR. Exported record fields let callers bypass the smart constructors, so "every value has passed its constructor's validation" is false

- **Where.** 60 export entries take the form `Type (field, ...)`:
  - 42 in `petrus-agenticus-core`, for example `Catalog/Descriptor.hs:10,16,21`, `Catalog/Result.hs:4,9`, `Catalog/Resolution.hs:14-21`, `Connection/Custody.hs:28`, `Runtime/Installation.hs:8-17` and `Hands/Gateway.hs:18-22`;
  - 11 in `petrus-agenticus`, for example `Program/AgentNet.hs:68` (`LoopState (..., phaseLimit, ...)`);
  - 7 in `petrus-agenticus-runtime`.

  The claim itself is in `packages/petrus-agenticus-core/divergences/catalog.md:36-39`.
- **What is wrong.** Exporting a field name, even under `NoFieldSelectors`, enables record-update syntax outside the module. I confirmed this with GHC 9.10.3 on a toy copy of the `LoopState`/`mkLoopState` shape (scratch `recupd/`): `s {phaseLimit = 0}` compiles and yields an invalid value. So `descriptor {contractVersion = 0}`, `loopState {phaseLimit = 0}` and similar build states that `mk*` refuses.
  - One concrete consequence: `createRunnerWith` (`AgentNetRunner.hs:625-634`) runs `validateInitial`, which does not recheck `phase <= phaseLimit`, and then evaluates `episodeBudget 1 initial'.phaseLimit`.
  - `episodeBudget` (`Thread/Lifecycle.hs:225-226`) is `either error id`. The process therefore dies with an `ErrorCall` where upstream raises `ValueError`.
  - Upstream's frozen dataclasses forbid assignment, and `dataclasses.replace` re-runs `__post_init__`, so the reference cannot reach this state.
- **Why it matters (outcome 5).** Types that rule out invalid states are the main "better the Haskell way" claim for this area, and the divergence catalog states it as fact. FA-S-3 fixed one type by exactly this method; the others were left open.
- **Fix.**
  1. Export the validated types abstractly and provide read access through `HasField` instances, as `Runtime/Profiles.hs:111-139` already does, or through getter functions. Records whose every field combination is valid, such as plain outcome records, can keep their fields.
  2. Separately, the exported partial "literal" constructors (`descriptorIdentity`, `capabilityDescriptor`, `callFence`, `episodeBudget`, `continuationDescriptor`, `continuationRequirement`, `compatibilityIssue`) should not be reachable with runtime values. Make `AgentNetRunner` use `mkEpisodeBudget` and raise its `ValueError`, and keep the partial forms module-internal or restricted to literal tables.

### CA-3: MAJOR. DST keeps a second canonical JSON encoder, justified by a measurement against a petrus-json writer that no longer exists

- **Where.**
  - `packages/petrus-dst/src/Petrus/Testing/Dst/Internal/Canonical.hs` (88 lines, used by `Codec.hs:36-49`);
  - the justification in `packages/petrus-dst/bench/RESULTS.md:188-196`: "petrus-json's general `dumps` builds every string one character at a time and threads an `Either` through every node";
  - the "Additions" section of `DIVERGENCES.md`.
- **What is wrong.** That description fits the encoder as it was when `8d411ad` (Oct 10 13:32) added `Canonical.hs`. Seven hours later, `1483760` ("petrus-json: ... one-pass dumps") replaced it with a single-pass writer into a growing buffer (`petrus-json/src/Petrus/Json/Encode.hs:139-150`, plus `dumpsBuilder`), and the History store already relies on that writer.
- **Why it matters (standing design rule, outcomes 5 and 6).** The rule allows a specialized fast path only where a benchmark shows that the clean version cannot keep up, and puts it in the lowest layer that can hold it, with its measurement beside it. Here the measurement compares against superseded code, and the duplicate lives in a high-level package. Two encoders for one spelling must also be kept byte-identical by a property test forever.
- **Fix.** Re-run the DST encode and digest rows with `Codec.canonicalBytes = dumps canonicalOptions`.
  - If those rows stay at or above Python (encode was 11.4 ms on the Python side), delete `Internal.Canonical`, its property and the "Additions" entry.
  - If not, move the ASCII-run fast path into petrus-json's writer, where every canonical caller benefits, and record the new measurement there.

### CA-4: MINOR. Two implementations of the RSS gauges, and the tested one is dead

- **Where.** These two exist side by side:
  - `packages/petrus-telemetry/cbits/petrus_telemetry.c` and `Petrus/Telemetry.hs:552-598` (`maxRssMb`, `currentRssMb`, `pythonRound1`);
  - `packages/petrus-posix/src/Petrus/Posix/Resource.hs` with its own C shim (`petrus_maxrss`, `petrus_page_size`), described as "Process resource figures as upstream's telemetry reports them". It is used only by petrus-posix's own test and bench.
- **Why it matters.** It is needless duplication plus dead code (elegance, outcome 5), and two C shims for `getrusage` and `sysconf`. petrus-posix depends only on base, bytestring, containers, directory, filepath, random and unix, so telemetry can use it and still be "layer zero" with respect to the Petrus runtime.
- **Fix.** Pick one implementation. The natural choice is to make telemetry call `Petrus.Posix.Resource` and delete `petrus_telemetry_max_rss`, `petrus_telemetry_page_size` and the telemetry copies. Then update the "Layer zero" comment.

### CA-5: MINOR. Low-level I/O code in high-level modules, duplicating the posix layer

- **`packages/petrus-agenticus-core/src/Petrus/Agenticus/Connection/Materialization.hs`:**
  - `:210-216,337-342` defines a pointer-walking `writeAll` over `unsafeUseAsCStringLen`, with a `castPointer p = p \`plusPtr\` 0` workaround in place of `castPtr`;
  - `:331-335` defines a hand-written `finallyClose`, which is `finally` spelled out.

  petrus-posix, which this package already depends on, exports `writeAll :: Fd -> ByteString -> IO ()` and `fsyncFd`.
- **`packages/petrus-agenticus-runtime/src/Petrus/Agenticus/Runtime/Internal/Process.hs:212-244`:**
  - `spawnPiped` adopts raw descriptors through `GHC.IO.FD.mkFD`, `mkHandleFromFD` and `System.Process.Internals.mkProcessHandle`;
  - `HostSupport.hs:391-404` reuses a `mallocForeignPtrBytes` buffer with `hGetBufSome` and `packCStringLen`, as a per-read optimization with no recorded measurement.
- **Why it matters (design rule, outcome 5).** Low-level code belongs behind a safe interface in the lowest layer. The spawn itself already lives in petrus-execution (`Petrus.Motus.Execution.Spawn`); the step that turns pipe ends into handles does not.
- **Fix.**
  1. Use `Petrus.Posix.File.writeAll` and `finally`.
  2. Move "spawn with piped, non-blocking `Handle`s and a `ProcessHandle`" into petrus-execution next to `spawnChild`.
  3. Either measure the reusable read buffer against `B.hGetSome` and record the result next to the code, or drop it.

  `exitInt` is also defined three times: in DST `Process.hs`, in agenticus `Internal/Process.hs` and in hamsterdan-operator.

### CA-6: MINOR. PARITY counts and figures went stale again after the fixes

| Location | Claim | Actual |
| --- | --- | --- |
| `packages/petrus-telemetry/PARITY.md:23`, `packages/petrus-telemetry-instrumentation/PARITY.md:13` | "56 examples" | 58 in CI. The two `InvalidLevelSpec` examples added by FA-S-1 are also missing from the Haskell-specific example lists. |
| `packages/petrus-agenticus-core/PARITY.md:19` | "666 examples" | 667 in CI |
| `packages/petrus-telemetry/DIVERGENCES.md` item 6 | 0.06 µs vs 2.6 µs | `bench/RESULTS.md`: 0.056 µs vs 2.5 µs. The telemetry PARITY says 0.057 vs 2.6. |
| `packages/petrus-agenticus-runtime/divergences/codex.md` item 8 | `flock` "through the FFI" | It goes through petrus-posix (`CodexGondolin.hs:95,512`). |

- **Why it matters (outcome 7).** FA-S-10's class of drift recurred within one round of fixes.
- **Fix.** Correct the cells. Better still, have `check-parity` compare each "N examples" claim with the suite's actual count, as it already does for upstream test counts.

### CA-7: MINOR. `PinnedSdkSpec` re-spells production's Claude options and tools instead of calling them

- **Where.** `packages/petrus-agenticus-runtime/test/Petrus/Agenticus/Runtime/PinnedSdkSpec.hs:56-93` copies the 18-key option list and the tool list from `Claude.hs:1632-1652` and `:1026-1033`. `docs/live-provider-acceptance.md` says the smoke is "built from production's option keys and tools".
- **Why it matters (outcome 3).** If production adds or renames a key, the smoke test still passes against the real SDK. That is exactly the drift FA-S-4 was meant to catch.
- **Fix.** Extract pure `claudeOptionValues :: ClaudeOptionInputs -> [(Text, Json)]` and `claudeHandsTools :: (ToolMethod -> handler) -> [ClaudeTool]`, use them in both places, and have the smoke test pass dummy inputs.

### CA-8: MINOR. Pi "fail closed" divergences are documented without a rationale, unlike the parallel Codex entry

- **Where.** `packages/petrus-agenticus-runtime/divergences/pi.md` has four such entries:
  - native item 8: `probe` maps every synchronous exception to `protocol-unavailable`;
  - model phase item 5: a cleanup exception becomes `cleanup-unverified`, where the reference lets it escape from `close()`;
  - model phase item 6;
  - application item 5: a non-object `package.json` gives `protocol-unavailable`, where the reference lets `AttributeError` escape.
- **What is wrong.** Each entry states the behavior difference but not why it stays. `codex.md` item 7 handles the same kind of difference with an explicit "Why it stays", and FA-S-2 closed two siblings of these by reproducing the reference.
- **Why it matters (outcome 5).** Every intentional divergence must be documented with its rationale.
- **Fix.** For each entry, either reproduce the reference (let the exception escape, so it settles or propagates as upstream does) or add a "Why it stays" sentence, as Codex item 7 has.

### CA-9: MINOR. `Petrus.Testing.Dst.Transcript` is test scaffolding in the public library

- **Where.** `packages/petrus-dst/src/Petrus/Testing/Dst/Transcript.hs` (326 lines) is exposed by the main `petrus-dst` library (`petrus-dst.cabal:49`). Its only user is `test/Spec/Transcript.hs`.
- **What is wrong.** DIVERGENCES ("Additions") calls it "the stand-in for the Engine before the Haskell Engine existed". The real Engine profiles now replay all 51 fixtures.
- **Why it matters.** It is dead weight on the supported surface, which upstream does not have, and its corpus regeneration takes 11.8 s per check run.
- **Fix.** Move it into the test suite, or delete it together with `transcript_vectors` if the real-profile replays are judged sufficient.

## 3. Verified to hold

- **Pin (outcome 1).** `upstream/petrus` matches UPSTREAM.md (`3f85fc2`), and every corpus generator in the area reran clean in CI `checks`.
- **Upstream tests ported by name (outcome 2).** All 458 unique agenticus and telemetry test names are present (the mechanical check above). The one exception, the unstarted span, is documented as unrepresentable.
- **DST mapping.** `petrus-dst/PARITY.md` maps every `tests/dst/` file. FA-S-9 closed the two method substitutions.
- **Hypothesis ports (outcome 2).**
  - `test_payload_digest_is_a_canonical_replay_identity` uses `hypothesisSettings 60` with `genObject 8 (genJson 20)` (`EffectSpec.hs:199-210`). This matches `max_examples=60` and `_JSON`.
  - The tuple and non-string-key parameter cases are documented as statically excluded (`parity/effect.md:24`).
  - Catalog permutations use 40 examples (`PARITY.md:40`).
  - The DST campaigns keep `campaign_settings`: `max_examples`, `stateful_step_count`, derandomization as a fixed seed, and no deadline (`PARITY.md:359-399`).
- **Telemetry semantics, rechecked line by line against `telemetry.py`.** Fields are bound before `_started`. A finish-emit collision replaces the body's exception. `off` returns before the duplicate check. The sink swallows only synchronous exceptions, as `except Exception` does. `capture` restores both the sink and the level. `increment` follows Python's numeric promotion. `accumulateTime` keeps its time on failure. `max_rss_mb` and statm rounding match `round(x, 1)`.
- **Interop (outcome 3).** These all ran green in CI:
  - DST artifacts, failure bundles and legacy replay both ways (`Spec.ToolingInterop`);
  - custody, retention and Codex ledgers and `thread.json`/History byte-identical (runner corpus, retention and custody corpora);
  - the pinned Claude and Amp SDKs, credential-free (`PinnedSdkSpec`).
- **Better the Haskell way (outcome 5), confirmed intact.**
  - pure Mealy checkers;
  - `Profile m g` records with a structural `Scenario` context;
  - `AuthoredDisposition` and `IndexAuthority` types;
  - `ScrubbedBytes` secrets;
  - the typed `Claim` and `Lookup` split;
  - the `Qualification` sum;
  - a `ValidatedSnapshot` that only the storage module can build;
  - the `bracket`-scoped Hedgehog World;
  - one owned process capture.

  The remaining `unsafePerformIO` uses are justified: the telemetry `routeRef`/`defaultSinkRef`/`levelRef`/`environmentLevel` (the process-global contract of `capture`), `ErrorType`'s C constant, test-support's interpreter cache, and `defaultSidecarPool` (documented in `claude-a2.md` item 1, with `withSidecarPool` as the owned alternative).
- **Divergence documentation.** FA-S-1 and FA-S-3 are now documented consistently. Apart from CA-1, CA-2 and CA-8, every divergence in the area that I read carries its rationale.

## Notes (outside this area's ownership)

- `scripts/bench --check` at HEAD reports 42 of 46 results files as stale. In this area that covers:
  - petrus-agenticus;
  - petrus-agenticus-core (RESULTS and the five `results-*` files);
  - petrus-agenticus-runtime (RESULTS, hosts, pi);
  - petrus-dst;
  - petrus-telemetry-instrumentation.

  All were measured at `5a73d7a`. The only change since then that reaches these packages is petrus-json's `Encode.hs`, through `baf5836` and `9e691e8`, which added `dumpsMany` to petrus-json. Outcome 6 needs these files restamped or rerun. That belongs to the verify-perf owner.
