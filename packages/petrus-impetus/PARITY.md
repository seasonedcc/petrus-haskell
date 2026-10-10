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

| upstream file | Haskell spec(s) | ported | via CEL stub | by types | not at parity |
| --- | --- | ---: | ---: | ---: | ---: |
| petrinet/test_schema.py (45) | SchemaSpec | 42 | | 3 | |
| petrinet/test_marking.py (15) | MarkingSpec | 15 | | | |
| petrinet/test_token_queue.py (19) | MarkingSpec | 19 | | | |
| petrinet/test_enabledness.py (23) | EnablednessSpec | 23 | | | |
| petrinet/test_arc_filters.py (29) | ArcFiltersSpec, FiringSpec, FiringHistorySpec | 24 | 3 | 2 | |
| petrinet/test_arc_weights.py (4) | EnablednessSpec, FiringSpec | 4 | | | |
| petrinet/test_inhibitor_arc.py (3) | EnablednessSpec, FiringSpec | 3 | | | |
| petrinet/test_read_arc.py (8) | EnablednessSpec, FiringSpec, FiringHistorySpec | 8 | | | |
| petrinet/test_petrinet_dot.py (16) | DotSpec | 14 | | 2 | |
| petrinet/test_golden_replay.py (3) | GoldenTracesSpec | 3 | | | |
| instance/test_fifo_queue.py (2) | FifoQueueSpec | 2 | | | |
| instance/test_passthrough_chain.py (1) | GoldenTracesSpec | 1 | | | |
| instance/ — 10 files (135) | see `parity-instance-a.md` | 104 | 20 | 4 | 7 |
| instance/ — 6 files (158) | see `parity-instance-b.md` | 148 | 3 | 7 | 0 |
| selection, history, history_store (in-memory), petrinet History halves | see `parity-history.md` | 61 | 3 | 3 | 11 |
| integration/test_activity_seam.py + binding/test_typed_bindings.py | see `parity-activity-seam.md` | 94 | 0 | 9 | 8 |
| test_net_definition.py (14) | NetDefinitionSpec, SpecFixturesSpec | 11 | | 3 | |
| test_net_document.py (8) | NetDocumentSpec, SpecFixturesSpec | 8 | | | |
| test_net_document_lineage.py (9) | NetDocumentLineageSpec | 9 | | | |

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
| dsl/test_petrinet_dsl.py (42) | the DSL is out of scope |
| binding/test_cel.py (19) | CEL itself is the separate `petrus-cel` package |
| history_store/test_sqlite_history.py (11) | durable stores other than in-memory are out of scope |
| history_store/test_postgres_history.py (21) | same |

## Not at parity (26 upstream test functions)

**Engine and Dispatch belong to other packages (8)**, all in
`test_activity_seam.py::TestInlineDispatch`. The kernel side of each one
(begin, record, complete over an inline driver) is ported elsewhere in the
same file. The Dispatch side is ported in `petrus-motus`: 7 tests, plus the
dataclass-reflection one, which does not apply (see
`packages/petrus-motus/PARITY.md`).

- `test_registry_is_snapshotted_and_the_adapter_remains_frozen`
- `test_classified_retries_are_immediate_and_never_sleep`
- `test_generic_exception_keeps_precise_retryable_metadata_when_budget_exhausts`
- `test_value_shape_preserves_the_prior_dataclass_contract`
- `test_executes_the_named_activity_with_the_whole_invocation`
- `test_an_unknown_activity_fails_loud`
- `test_the_conservative_policy_makes_an_exception_terminal`
- `test_a_declared_attempts_policy_is_honored`

**JSONL, SQLite, and Postgres file mechanics (11)**, from `test_persistence.py`
and `test_history_backends.py`. Only the in-memory store is in scope. The
store contract these tests rely on is ported over `mirroredHistoryStore` with
a JSON-lines round trip.

- the `reopen` fixture's jsonl/sqlite/postgres parameterization
- `TestDurableAppend.test_appends_accumulate_across_calls`
- `TestDurableAppend.test_makes_the_parent_directory_once_needed`
- `TestJsonlHistoryStore.test_every_append_is_durable_immediately`
- `TestJsonlHistoryStore.test_loading_then_appending_continues_the_file`
- `TestJsonlHistoryStore.test_a_missing_file_is_an_empty_history`
- `TestJsonlHistoryStore.test_a_v1_encoded_line_fails_loud_at_load_naming_the_migration`
- `TestJsonlHistoryStore.test_a_schema_2_line_fails_through_the_actual_jsonl_load`
- `TestJsonlHistoryStore.test_a_torn_tail_fails_loud_naming_the_line`
- `TestJsonlHistoryStore.test_unencodable_data_fails_loud_and_appends_nothing`
- `TestJsonlHistoryStore.test_a_mid_batch_encoding_failure_writes_nothing`

The v1 and schema-2 refusal messages themselves are ported at the codec level.
All 11 are ported against the real JSONL store in `petrus-history-store`
(`packages/petrus-history-store/PARITY.md`). Its backend-contract suite runs
`test_history_backends.py` with `reopen` set to jsonl.

**Private Instance helpers that are not exported (2)**, in `test_firing.py`.
The same records and outcomes are asserted through the public `begin` and
`complete` doors.

- `TestBeginEndFiring.test_instance_begin_firing_retains_its_record_authoring_contract`
- `TestBeginEndFiring.test_instance_complete_firing_retains_its_outcome_and_registration_contract`

**CEL semantics, which live in `petrus-cel` (5).** These cover the CEL
environment and macro-bound variable analysis.

- `test_completion.py::TestCelEnvironment.test_place_variables_bind_token_color_and_data`
- `test_completion.py::TestCelEnvironment.test_a_black_token_reads_as_null_color_and_data`
- `test_completion.py::TestCelEnvironment.test_an_empty_place_binds_to_the_empty_list`
- `test_completion.py::TestCompletionValidation.test_macro_bound_variables_are_not_place_references`
- `test_cel_guards.py::TestCelGuardValidation.test_macro_bound_variables_are_not_place_references`

## Behaviour known not to be at parity

These are the Net-definition edge cases listed in `DIVERGENCES.md` (items 20,
24, and 25):

- when hand-built Haskell records are validated;
- the order in which a nesting-depth refusal is found among other refusals on
  serialize or project;
- character data outside the embedded Unicode 16 printability table.

`FiringFailed.error` for an exception raised inside user code is item 11.

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
  - `kernel_corpus.json` has 240 seeded random nets and action scripts. For
    every action it records the candidate bindings, the firing outcome or
    refusal (class and message), the marking, status, watermark, and next
    maturation, and the complete encoded History (`KernelDifferentialSpec`).
- **Properties (QuickCheck).**
  - `KernelPropertiesSpec`: the marking is the replay of History; resume is
    equivalent; the History round-trips the codec through JSON text; tokens
    are conserved.
  - The history slice's 6 properties.
  - The 4 Net-definition properties.
  - The port of `test_instance_replay_properties.py`, with 300 examples.
