# petrus-impetus: parity with the Python reference

This file maps every upstream test of the kernel (`upstream/petrus/tests/`) to
its Haskell counterpart. Each Hspec example has a `-- test_name` comment
naming the upstream test it ports. To cross-check that every in-scope upstream
test function is accounted for, run:

    python3 packages/petrus-impetus/scripts/parity_check.py

It currently reports 668 in-scope functions and 0 unaccounted.

Statuses:

- **ported**: the same scenario with the same assertions. Error messages are
  compared in full, and each message was captured from the reference.
- **ported via CEL stub**: the test drives inline CEL through a test-local
  `CelCompilers` that recognises the test's exact expressions. The kernel's
  side of the seam (scopes, free-place checks, refusals) is what gets tested.
- **enforced by types**: the case cannot be represented in Haskell.
- **ported elsewhere**: the test's subject lives in another package of this
  repository, and that package ports it (the ledger row names the example).
- **not at parity**: not reproduced. Each case is listed below with its reason.

Per-test ledgers, one row per upstream test function:
[`parity-instance-a.md`](parity-instance-a.md),
[`parity-instance-b.md`](parity-instance-b.md),
[`parity-history.md`](parity-history.md),
[`parity-activity-seam.md`](parity-activity-seam.md).
The remaining files are summarised in the table below, with the details in the
spec modules' comments.

## Summary by upstream file

Counts are upstream test functions. A parametrized test counts once; its
parameters are separate Hspec examples where they are ported.

| upstream file | Haskell spec(s) | ported | via CEL stub | by types | elsewhere | not at parity |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| petrinet/test_schema.py (45) | SchemaSpec | 42 | | 3 | | |
| petrinet/test_marking.py (15) | MarkingSpec | 15 | | | | |
| petrinet/test_token_queue.py (19) | MarkingSpec | 19 | | | | |
| petrinet/test_enabledness.py (23) | EnablednessSpec | 23 | | | | |
| petrinet/test_arc_filters.py (29) | ArcFiltersSpec, FiringSpec, FiringHistorySpec | 24 | 3 | 2 | | |
| petrinet/test_arc_weights.py (4) | EnablednessSpec, FiringSpec | 4 | | | | |
| petrinet/test_inhibitor_arc.py (3) | EnablednessSpec, FiringSpec | 3 | | | | |
| petrinet/test_read_arc.py (8) | EnablednessSpec, FiringSpec, FiringHistorySpec | 8 | | | | |
| petrinet/test_petrinet_dot.py (16) | DotSpec | 14 | | 2 | | |
| petrinet/test_golden_replay.py (3) | GoldenTracesSpec | 3 | | | | |
| instance/test_fifo_queue.py (2) | FifoQueueSpec | 2 | | | | |
| instance/test_passthrough_chain.py (1) | GoldenTracesSpec | 1 | | | | |
| instance/ — 10 files (135) | see `parity-instance-a.md` | 104 | 20 | 4 | 5 | 2 |
| instance/ — 6 files (158) | see `parity-instance-b.md` | 148 | 3 | 7 | | 0 |
| selection, history, history_store (in-memory), petrinet History halves | see `parity-history.md` | 61 | 3 | 3 | 11 | |
| integration/test_activity_seam.py + binding/test_typed_bindings.py | see `parity-activity-seam.md` | 94 | 0 | 9 | 8 | |
| test_net_definition.py (14) | NetDefinitionSpec, SpecFixturesSpec | 11 | | 3 | | |
| test_net_document.py (8) | NetDocumentSpec, SpecFixturesSpec | 8 | | | | |
| test_net_document_lineage.py (9) | NetDocumentLineageSpec | 9 | | | | |

Notes on the table:

- The history ledger's three golden-replay rows are counted under
  `test_golden_replay.py`, not in its row.
- The History halves of `test_arc_filters.py` and `test_read_arc.py` appear
  in both their petrinet rows and the history ledger's row. This includes the
  three `TestCelFilterSelection` cases, which are ported via CEL stub.
- In `test_net_document.py`, the schema half of the partial-view test and the
  tuple and non-string-key cases of the lineage metadata are enforced by
  types; their other halves are ported.
- Two `test_petrinet_dot.py` examples render real SVG and run only when
  Graphviz `dot` is installed. Without it they are pending, which is why the
  suite reports 2 pending. Every other render test uses a fake `dot` on the
  search path, as upstream does with `monkeypatch`.

## Out of scope (not ported, by the task's boundary)

| upstream file | reason |
| --- | --- |
| dsl/test_petrinet_dsl.py (42) | the DSL is its own package: ported in `petrus-dsl` (`packages/petrus-dsl/PARITY.md`) |
| binding/test_cel.py (19) | CEL itself is the separate `petrus-cel` package; all 19 are ported there, in `packages/petrus-cel/test/Impetus.hs` |
| history_store/test_sqlite_history.py (11) | durable stores other than in-memory are out of scope |
| history_store/test_postgres_history.py (21) | same |

## Ported in other packages (24 upstream test functions)

These tests were listed here as not at parity while their subjects had no
Haskell home. Each one is now ported by the package that owns its subject,
under the same test name.

**Dispatch (8)**, all in `test_activity_seam.py::TestInlineDispatch`. The
kernel side of each one (begin, record, complete over an inline driver) is
ported in this package too. The Dispatch side is in
`packages/petrus-motus/test/Main.hs`, `describe "TestInlineDispatch
(activity seam)"`: 7 ported, plus
`test_value_shape_preserves_the_prior_dataclass_contract`, which asserts
dataclass reflection and does not apply to a record of functions (see
`packages/petrus-motus/PARITY.md`).

**The JSONL store (11)**, from `test_persistence.py` and
`test_history_backends.py`: `TestDurableAppend` (2) and
`TestJsonlHistoryStore` (8) are in
`packages/petrus-history-store/test/Petrus/HistoryStore/JsonlSpec.hs`, and the
`reopen` fixture's jsonl parameter is `BackendContractSpec.hs` there. The
fixture's sqlite and postgres parameters wait for those backends, which are
out of scope like `test_sqlite_history.py` and `test_postgres_history.py`.
See `packages/petrus-history-store/PARITY.md`.

**CEL semantics (5)**: the CEL environment and macro-bound variable
analysis, in `packages/petrus-cel/test/Impetus.hs`, on real Instances built
with `Petrus.Cel.Impetus.celCompilers`.

The per-test rows are in `parity-activity-seam.md`, `parity-history.md`, and
`parity-instance-a.md`.

## Not at parity (2 upstream test functions)

**Private Instance helpers that are not exported**, in `test_firing.py`. The
same records and outcomes are asserted through the public `begin` and
`complete` doors.

- `TestBeginEndFiring.test_instance_begin_firing_retains_its_record_authoring_contract`
- `TestBeginEndFiring.test_instance_complete_firing_retains_its_outcome_and_registration_contract`

## Net definition and document edge cases

The edge cases that used to be listed here are now at parity, and
`differential/hand_built_corpus.json` pins them (`HandBuiltCorpusSpec`):

- **Hand-built records.** A record built with its constructor is the
  reference's `Model.model_construct(...)`, and the `mk*` functions are the
  reference's validating `Model(...)` calls, with its `ValidationError` text.
  `compileNetDefinition`, `serializeNetDefinition`, `serializeNetDocument`,
  and `projectNetDocument` run the reference's steps on whatever a record
  holds, in the reference's order.
- **Depth refusals.** Token data and metadata hit CPython's recursion limit
  at the reference's depth for a top-level call, and that refusal wins over
  every other validation error, as the reference's `RecursionError` does.
  Serializing a document refuses token data or a metadata value nested 256
  deep with Pydantic's `Circular reference detected (depth exceeded)`.
- **Printability.** `repr` text uses CPython 3.14's `str.isprintable` for
  every code point (`Petrus.Json.PythonText`), checked against a committed
  vector of all 1,114,112 verdicts.

`FiringFailed.error` for an exception raised by user code is exact for a
`PythonException` and for any Haskell exception whose Python twin is raised
with no argument or one string (`differential/failure_text_corpus.json`,
`FailureTextSpec`). DIVERGENCES item 11 says what remains.

## Beyond upstream

- **Byte identity.**
  - Every `spec/` fixture is loaded. The valid ones re-serialize
    byte-identically, and the invalid ones are refused with the reference's
    text (`SpecFixturesSpec`).
  - `petrus-golden-traces` regenerates `spec/traces/*.json` and
    `manifest.json` byte-identically, and `GoldenTracesSpec` checks it.
- **Differential corpora.** These are committed together with their Python
  generators in `differential/`.
  - `net_definition_corpus.json` has 1763 cases. It covers parse, serialize,
    compile, and project of the Net definition and document, with exact
    bytes or their SHA-256, and exact error text.
  - `hand_built_corpus.json` has 1996 cases (`HandBuiltCorpusSpec`, 2443
    examples): validating constructors, compile and serialize of hand-built
    definitions, serialize of hand-built documents (including token data and
    metadata nested around both depth limits, mixed with other errors),
    project with hand-built positions and lineage, and parse-then-serialize
    of deep documents.
  - `failure_text_corpus.json` has 452 `firing_failure_text` cases
    (`FailureTextSpec`).
  - `kernel_corpus.json` has 240 seeded random nets and action scripts. For
    every action it records the candidate bindings, the firing outcome or
    refusal (class and message), the marking, status, watermark, and next
    maturation, and the complete encoded History (`KernelDifferentialSpec`).
- **Properties (QuickCheck).**
  - `KernelPropertiesSpec`: the marking is the replay of History; resume is
    equivalent; the History round-trips the codec through JSON text; tokens
    are conserved. A run stops once a place holds more than 8 tokens, which
    keeps the combinatorial candidate sets (and memory) small for every
    seed.
  - The history slice's 6 properties.
  - The 4 Net-definition properties.
  - The port of `test_instance_replay_properties.py`, with 300 examples.
