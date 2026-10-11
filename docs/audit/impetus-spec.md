# Audit: Impetus kernel and `spec/`

Auditor slice: upstream `henriquebastos/petrus` at
`3f85fc2094e50ece48bcf6bf9ace19cb0a22a544`. It covers all of `petrus.impetus`:
kernel, firing, marking, guards and CEL (cel-python is the reference), History
and its stores (memory, JSONL, SQLite, Postgres), Instance, the Net definition
and Net document, non-HTTP observation, and the DSL. It also covers all of
`spec/`, including the golden traces, and the upstream tests for both.

Haskell packages audited: `petrus-impetus`, `petrus-cel`, `petrus-dsl`,
`petrus-history-store`, `petrus-history-postgres`, `petrus-observation`,
`petrus-json`.

Audited at local `main` `3bfb6c9`. The reference was built with
`scripts/upstream-python` (CPython 3.14.6, cel-python 0.5.0).

Path conventions:

- Upstream paths are relative to `upstream/petrus/`. These are `petrus/…`
  (under `src/`), `tests/…`, and `spec/…` for the upstream documents and
  fixtures.
- `spec/fabric-conformance.md` and `spec/processes-conformance.md` belong to
  this repository.

## A. Scope covered (inventory)

| item | count |
| --- | ---: |
| upstream `petrus/impetus` modules | 25 |
| public names (module-level, plus public methods of public classes) | 333 |
| upstream test files in `tests/petrus/impetus/`, plus `integration/test_activity_seam.py` | 40 |
| upstream test functions in those files | 668 |
| test functions checked, adding `engine/test_observation.py` and the impetus rows of `project/test_package_boundaries.py` | 780 |
| `spec/` normative documents (plus `spec/traces/README.md`) | 11 |
| RFC 2119 keywords in the four core docs (net-schema / event-history / firing-semantics / handler-contract) | 11 / 5 / 2 / 1 |
| Net document fixtures (of which invalid) | 7 (2) |
| Net definition fixtures (of which invalid) | 4 (2) |
| observation fixtures | 3 |
| golden traces (+ `manifest.json`) | 8 (+1) |

The test suites run (`nice -n 10`, `-j2`, `+RTS -M2G`) had these results:

| suite | examples | failures | pending |
| --- | ---: | ---: | ---: |
| `petrus-impetus` | 5754 | 0 | 0 (Graphviz present) |
| `petrus-cel` | 134 | 0 | 0 |
| `petrus-dsl` | 110 | 0 | 0 |

`petrus-history-store`, `petrus-history-postgres` and `petrus-observation`
were checked by reading their specs and through the live interop groups
already wired into `scripts/interop`. Their suites were not rerun here.

## B. Mapping summary

### Public API

Of the 333 public names, these have no Haskell export:

| upstream name | status |
| --- | --- |
| `instance.firing.begin_firing`, `instance.firing.complete_firing` | **not exported**; no DIVERGENCES entry (IMP-3) |
| `NetDefinitionV3.model_json_schema`, `NetDocumentV1.model_json_schema` (Pydantic, spec-described) | **not ported** (IMP-1) |
| `InstanceIdentity`, `DeliveryIdentity`, `FiringOccurrenceId` | validated `Text` / `Int`; no DIVERGENCES entry (IMP-11) |
| `binding.cel.MACROS`, `canonical_net_path` | internal to the port; no DIVERGENCES entry (IMP-11) |
| DSL `NodeSpec`, `ScopeSpec`, `NetBuilder` | documented in `packages/petrus-dsl/DIVERGENCES.md` |

Every other name maps to a Haskell function or type.

### Upstream tests

The 780 test functions checked are all accounted for in Haskell, with these
exceptions:

- **Ported.** The other upstream tests have a Hspec example carrying a
  `-- test_name` comment. `petrus-cel` uses prose `it` names, and
  `petrus-history-postgres` uses `it "name_without_test_"`.
- **Recorded elsewhere.** Some tests are ledger rows in
  `packages/petrus-impetus/PARITY.md` and its `parity-*.md` files, marked
  "enforced by types", "via CEL stub", or "ported elsewhere".
- **2 not at parity.** `test_firing.py`'s two `instance_*_firing` tests
  (IMP-3).
- **2 mislabeled as "enforced by types".** The JSON Schema assertions of
  `test_net_definition.py:146` and `test_net_document.py:84` (IMP-1).
- **7 unaccounted.** Impetus rows of `project/test_package_boundaries.py`
  (IMP-8).

`parity_check.py` reports "668 in-scope functions, 0 unaccounted". The check
is name-based, so it counts the mislabeled and stub-only rows as accounted.

### `spec/` requirements

| spec document | requirement group | Haskell evidence |
| --- | --- | --- |
| net-schema.md | places, transitions, arcs, scopes, inhibitor/read arcs, DOT | SchemaSpec, MarkingSpec, DotSpec, IngressSpec, petrus-dsl |
| firing-semantics.md | enabledness, arc filters, guard branches, selection, timers, completion, registrations | EnablednessSpec, ArcFiltersSpec, GuardBranchSpec, FiringSpec, SelectionSpec, TimersSpec, CompletionSpec, RegistrationsSpec |
| event-history.md | record kinds, codec, lifecycle scopes, resume, replay | HistoryCodecSpec, LifecycleScopesSpec, ActivitySeamSpec, ResumeSpec, KernelPropertiesSpec, GoldenTracesSpec |
| handler-contract.md | handler results, failures, typed bindings | HandlersSpec, GuardBranchSpec, FiringHistorySpec, TypedBindingsSpec, FailureTextSpec |
| net-definition-v3.md | canonical form, refusals, compile, identity | NetDefinitionSpec, SpecFixturesSpec, `net_definition_corpus.json`, properties. **Gap:** §JSON Schema (`:97`, `:118`), IMP-1 |
| net-document-v1.md | document, view, lineage, projection | NetDocumentSpec, NetDocumentLineageSpec, SpecFixturesSpec, corpora. **Gap:** JSON Schema (`:243`), IMP-1 |
| observation | projections and fixtures | petrus-observation ObservationSpec, EngineSpec, CorpusSpec (HTTP is out of slice) |
| simulation | — | petrus-simulation (out of slice; only noted) |
| traces/ | golden traces | GoldenTracesSpec replays every manifest entry, and `petrus-golden-traces` regenerates every trace and the manifest byte-identically |
| fixtures | all `spec/*.json` | SpecFixturesSpec discovers every file. Valid ones round-trip byte-identically; invalid ones are refused with exact text |

The typed-place initial-marking refusal is tested in
`packages/petrus-engine/test/Petrus/Engine/DeliveryPhasesASpec.hs:369`, outside the
slice. Some requirements are owned by the Engine or Dispatch: sensor re-offer,
cancellation fence ordering, and `DriveOutcome`. They fall outside this slice
and are left to those audits.

Unlike `spec/fabric-conformance.md` and `spec/processes-conformance.md`, the six
core documents have no requirement-level conformance ledger. Upstream itself
states that "a normative behavior without an executable check remains a
coverage gap" (`spec/README.md:9-11`) (IMP-6).

## C. Interop

The Python side is always the reference at the pin.

| artifact | Python → Haskell | Haskell → Python | live? |
| --- | --- | --- | --- |
| JSONL History store | ✓ (`JSONL interop with the reference`) | ✓ | live, fails without the reference |
| SQLite History store | ✓ | ✓ | live |
| Postgres History store | ✓ | ✓ | live |
| Net definition v3 / Net document v1 | committed corpus (1763 + 1996 cases) + spec fixtures | **never exercised** | corpus only (IMP-4) |
| History codec (in-memory records) | `kernel_corpus.json` (240 nets) | **never exercised** | corpus only (IMP-4) |
| CEL | `cel-corpus.json` (1978), `cel-operators.json` (17850), `cel-instance.json` (5) | n/a (evaluation verdicts) | corpus only (IMP-4) |
| DSL | `dsl_corpus.json` (68) | **never exercised** | corpus only (IMP-4) |
| observation projections | `observation_corpus.json` | n/a | corpus only (IMP-4) |
| golden traces | regenerated byte-identically | (same bytes) | committed |
| lone-surrogate token data in a History | **fails** (IMP-2) | n/a | probed by hand |

I regenerated every committed corpus in the slice from the pinned reference
into a scratch directory: net_definition, kernel, failure_text, hand_built,
dsl, observation, cel-instance, cel-corpus and cel-operators. **All are
byte-identical to the committed files**, so they are current at the pin.
Nothing automated would catch them going stale on a pin bump, though (IMP-4).

The surrogate probe (IMP-2) went as follows:

1. The reference `Instance` with a JSONL store fired a token whose data is
   `"\ud800"`.
2. The reference wrote the line, using `json.dumps` with `ensure_ascii`, which
   escapes it.
3. `parseJson pythonLoads` on that line returned `Left "JSON strings must
   contain Unicode scalar values"`.
4. `Petrus.HistoryStore.Jsonl` and `.Sqlite` both load through that parser, so
   a Python-written History holding such a value cannot be opened by the port.

## D. Findings

| id | outcome | severity | finding | evidence (upstream ↔ Haskell) | fix |
| --- | --- | --- | --- | --- | --- |
| IMP-1 | 2, 5 | major | **JSON Schema of the Net definition and Net document is not ported.** `model_json_schema()` is a spec-described artifact (strict, versioned, closed records, interoperable integer bounds). Two upstream tests assert on it, and the ledger labels them "enforced by types", which they are not: the port publishes no schema. There is no DIVERGENCES entry. | `spec/net-definition-v3.md:97`, `:118`; `spec/net-document-v1.md:243`; `tests/petrus/impetus/test_net_definition.py:146`; `test_net_document.py:84-92` ↔ `packages/petrus-impetus/test/Petrus/Impetus/NetDefinitionSpec.hs:111-114`, `NetDocumentSpec.hs:96-98` | Emit both JSON Schema documents from Haskell (e.g. `netDefinitionV3JsonSchema :: Json`). Commit the reference's `model_json_schema()` output and compare byte for byte (or structurally, if key order is not normative). Port both tests' assertions (`additionalProperties: false`, `const` format/version, integer bounds). |
| IMP-2 | 3, 5 | major | **A Python-written History holding a lone surrogate cannot be loaded by the port.** Upstream accepts `"\ud800"` as token data and writes it to JSONL (and SQLite) as an escaped JSON string. `petrus-json` refuses lone-surrogate escapes, and both Haskell stores parse through it. The petrus-json divergence entry and the `Parse.hs` header claim that "no Petrus format admits" them. That is false for History. | `petrus/impetus/history_store/jsonl.py:187` (`json.dumps(encode_record(record), allow_nan=False)`) ↔ `packages/petrus-json/src/Petrus/Json/Parse.hs:4`, `:418`; `packages/petrus-history-store/src/Petrus/HistoryStore/Jsonl.hs:233`, `Sqlite.hs:430`; `packages/petrus-json/DIVERGENCES.md:10` | Wire formats must not diverge, so represent lone surrogates instead of refusing them. For example, `Json` strings could carry a WTF-8/escaped form that survives decode and re-encode for History stores (`pythonLoads` admits it, `pythonDumps` re-escapes it). Then add a JSONL and SQLite interop case with `"\ud800"` data in both directions. At minimum, correct `DIVERGENCES.md:10` and the `Parse.hs` header now and record this as a known History wire divergence. |
| IMP-3 | 2, 5 | major | **Upstream's public `petrus.impetus.instance.firing.begin_firing` / `complete_firing` have no Haskell equivalent.** Their two upstream tests are not ported, and there is no DIVERGENCES entry. The ledger described them as "private helpers"; this commit corrects that. | `petrus/impetus/instance/firing.py:126`, `:656`; `tests/petrus/impetus/instance/test_firing.py:19-20`, `:159`, `:173` ↔ `packages/petrus-impetus/src/Petrus/Impetus/Instance/Firing.hs:15-31` (export list); `Instance.hs:1410` (`beginOccurrence`, internal); `packages/petrus-impetus/PARITY.md:115-126` | Export pure Instance-level record-authoring functions from `Petrus.Impetus.Instance.Firing` (begin: the started record and occurrence; complete: outcome and registration records). Port both tests verbatim. If this is deliberately not ported, add a DIVERGENCES entry with the rationale instead. |
| IMP-4 | 3, 1, 7 | major | **Interop rests on committed corpora alone for most of the slice, and the Haskell → Python direction is never exercised for definitions, documents, History codec records or DSL output.** The `scripts/interop` groups for `petrus-impetus`, `petrus-cel`, `petrus-dsl` and `petrus-observation` select corpus checks that pass without the reference. No upstream test (including the HTTP clients) feeds a Haskell-produced Net definition or document to the reference parser. Nothing detects a stale corpus after a pin bump. All corpora were verified current by hand during this audit. | `scripts/interop:74`, `:75`, `:87`, `:92` (corpus patterns only) ↔ the model to follow: `packages/petrus-engine-file/test/Petrus/EngineFile/LiveSpec.hs:62` (live staleness check of committed verdicts) | Add a live spec per package, selected by `scripts/interop` and failing without the reference. It should (a) regenerate each corpus's verdicts with the pinned reference and compare them with the committed file, and (b) feed Haskell-serialized Net definitions and documents (property-generated, plus the corpus inputs), encoded History records and DSL-built definitions to `parse_net_definition` / `parse_net_document` / `decode_record` in the reference. It should assert acceptance and byte-identical re-serialization. |
| IMP-5 | 2 | minor | 26 upstream tests are ported only "via CEL stub" (instance-a 20, instance-b 3, history 3). The kernel side of the seam is tested, but those exact bodies never run on real CEL. `cel-instance.json` (5 scenarios) covers some of them. | `packages/petrus-impetus/PARITY.md:16-18`, `:51-53` | Rerun those bodies in `petrus-cel` with `Petrus.Cel.Impetus.celCompilers`, as is already done for the 5 CEL-semantics tests. |
| IMP-6 | 2 | minor | There is no requirement-level conformance ledger for net-schema, firing-semantics, event-history, handler-contract, net-definition-v3 and net-document-v1. | `spec/README.md:9-11`; `spec/fabric-conformance.md`, `spec/processes-conformance.md` (existing models) | Add `spec/impetus-conformance.md` in this repository, beside the two existing ledgers, seeded from the table in §B. |
| IMP-7 | 5, 7 | minor | `petrus-cel` has neither PARITY.md nor DIVERGENCES.md. Its one deliberate deviation (a lone-surrogate string literal decodes to U+FFFD) is documented only in Haddock. | `packages/petrus-cel/src/Petrus/Cel.hs:61` | Add both files. Record the U+FFFD divergence there and tie it to the resolution of IMP-2. |
| IMP-8 | 2 | minor | 7 impetus rows of `tests/project/test_package_boundaries.py` are unaccounted for: `lazy_root_surface`, `import_defining_modules`, `canonical_petrinet_and_binding_facades`, `canonical_instance_facade`, `petrinet_import_does_not_load_forbidden_layers`, `petrinet_owns_binding_and_history_independent_firing`, `removed_flat_deep_modules`. The Haskell layering holds today (Petrinet modules import only Schema, Marking, Scope, Activity.Number and Json), but nothing enforces it. | `tests/project/test_package_boundaries.py` ↔ no Haskell counterpart | Add a layering check, e.g. a test that greps the imports of `Petrus.Impetus.Petrinet.*` against an allow-list. Add ledger rows for the facade and lazy-import tests, which are Python-only. |
| IMP-9 | 7 | minor | Stale ledger text. `PARITY.md` still said the sqlite and postgres stores and the DSL were "out of scope" and that the firing helpers were "private"; corrected in this commit. `parity_check.py`'s `OUT_OF_SCOPE` reasons still say so. | `packages/petrus-impetus/scripts/parity_check.py:26-31` | Reword the reasons to "ported in petrus-dsl / petrus-history-store / petrus-history-postgres". |
| IMP-10 | 6 | minor | Bench gaps. There are no benchmarks for timer maturation and wake, lifecycle scope close and reset, model-level `parse_net_document` / `serialize_net_document`, or `compile_net_definition`. | the existing benches in each package's `bench/` | Add those four cases against the reference. |
| IMP-11 | 5 | minor | Identity newtypes (`InstanceIdentity`, `DeliveryIdentity`, `FiringOccurrenceId`), `canonical_net_path` and `MACROS` are not ported as named API. Validated `Text`/`Int` is a defensible choice, but it is undocumented. | `petrus/impetus/instance/*.py`, `binding/cel.py:50` ↔ `packages/petrus-impetus/DIVERGENCES.md` (item 15 covers identities as Text only in part) | Add a DIVERGENCES entry. Better still, introduce newtypes, which is the Haskell way. |
| IMP-12 | 6 | minor | All bench medians are ≥1.0× the reference: impetus 1.6–97×, cel 14–73×, dsl 2.8–6×, observation 3.1–23×, history-store 1.09–156×, postgres 1.05–2.6×, json 1.8–2.7×. The `petrus-history-postgres` committed results include per-repetition lows of 0.48× and 0.82×. | `bench-results/` (postgres history) | Investigate the variance (connection warm-up, fsync) and raise repetitions, or report the minimum as well as the median. |
| IMP-13 | 7 | minor | DotSpec's two real-Graphviz examples go pending when `dot` is absent. CI installs Graphviz, but `check-all`'s `cabal test` does not pass `--fail-on=pending` (or an equivalent), so a missing `dot` would silently drop them. | `packages/petrus-impetus/test/Petrus/Impetus/DotSpec.hs:304`; `scripts/check-all:65` | Make pending fail under CI (an environment flag that turns `pendingWith` into a failure, or hspec `--fail-on=pending` for this suite). |

## E. Performance

Benchmarks were not rerun (per instructions). The committed results show
medians at or above parity for every package in the slice (IMP-12). The engine
bench covers deliveries and activities. The gaps are IMP-10.

## F. Pins and CI

- `UPSTREAM.md` records the pin. `scripts/check-pins` verifies the submodule,
  the gitlink and the table.
- `.github/workflows/ci.yml` installs Graphviz and Postgres and runs
  `scripts/check-all`. That script runs check-pins, lint-skips, the build,
  `interop --check`, `cabal test all` under `with-postgres`, `bench --check` and
  `check-parity`.
- The live store interop groups fail (rather than skip) without the reference.
- The corpus-only groups pass without the reference (IMP-4).

## Verdict per outcome

1. **Pinned and reproducible: holds.** The pin is recorded and checked in CI.
   Every corpus in the slice regenerates byte-identically from the pinned
   reference. The weakness is that no automated check catches a stale corpus
   (IMP-4).
2. **Every upstream behavior and spec requirement is ported and tested: does
   not fully hold.**
   - Golden traces and spec fixtures hold completely.
   - The JSON Schema is missing (IMP-1).
   - Two public Instance firing functions and their tests are missing (IMP-3).
   - Minor gaps: IMP-5, IMP-6, IMP-8.
3. **Interop in both directions: partially holds.**
   - History stores hold: they are live and tested in both directions.
   - Net definitions and documents, the History codec, CEL, the DSL and
     observation are checked against corpora only. Haskell → Python is never
     exercised for them (IMP-4).
   - Lone-surrogate History data written by Python cannot be loaded (IMP-2).
4. **Not in this slice.**
5. **Divergences are deliberate and documented: mostly holds.** The 26
   `petrus-impetus` DIVERGENCES items all carry a rationale. These are
   undocumented: IMP-1, IMP-2 (documented wrongly), IMP-3, IMP-7 and IMP-11.
6. **Performance at or above the reference: holds.** All medians are ≥1×.
   There are bench gaps (IMP-10) and variance in the postgres history bench
   (IMP-12).
7. **Enforced by CI: holds.** `check-all` runs on main and on PRs. Minor
   issues: IMP-9 (stale ledger text) and IMP-13 (pending is not failing).
   IMP-4's missing live groups also weaken CI's interop guarantee.

There are no blockers.
