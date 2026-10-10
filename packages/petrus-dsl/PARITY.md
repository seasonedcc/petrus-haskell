# petrus-dsl: parity with the Python reference

`Petrus.Impetus.Dsl` ports `upstream/petrus/src/petrus/impetus/dsl.py` (at
3f85fc2). Parity is checked in two ways.

1. **A differential corpus.** `differential/dsl_corpus.py` authors 68 nets with
   the reference DSL and records its verdict for each in
   `differential/dsl_corpus.json`. The verdict is either the result below or
   the exact refusal text:
   - the canonical Net-definition v3 bytes;
   - the first-touch order of places and transitions, and the arc order;
   - the implementation URIs;
   - the anonymous display names.

   `test/Petrus/Impetus/Dsl/Corpus.hs` authors the same 68 nets with the
   Haskell DSL, and `DslCorpusSpec` requires agreement on every key of every
   case. The corpus covers:
   - every net the upstream DSL tests author, including their refusals;
   - the nets other upstream modules author with the DSL: the Agent-as-Net
     (`agent-net`), the bounded-simulation scenario (`simulation-scenario`),
     and the observation inspection design (`observation-inspection`);
   - two generated workloads (`chain-50`, `stamped-30`), which the
     benchmarks use at larger sizes.
2. **Behavioural ports.** `DslSpec` ports each upstream test,
   (`tests/petrus/impetus/dsl/test_petrinet_dsl.py`). Each example has a
   `-- test_name` comment that names the test it ports. It asserts the same
   facts with the same messages. It also runs lowered implementations: a
   typed transform inside a real Instance, a custom-converter guard, and the
   Petri-aware handlers. It also checks that the observation inspection design
   rebuilds `upstream/petrus/spec/net-document-v1-inspection.json` byte for
   byte.

To regenerate the corpus (it is deterministic; a rerun reproduces the
committed file):

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-dsl/differential/dsl_corpus.py

To run the tests:

    cabal test petrus-dsl

This prints 110 examples and 0 failures: 41 behavioural, plus 69 corpus
examples (68 cases and a coverage check).

Statuses:

- **ported**: the same scenario with the same assertions.
- **enforced by types**: the refused input cannot be written in Haskell.
  DIVERGENCES.md explains each one.
- **N/A**: the test checks behavior of mutable Python objects. Its net-level
  effect is still checked through the corpus.

## Per upstream test

| upstream test | status | Haskell | corpus |
| --- | --- | --- | --- |
| test_path_proxies_return_stable_authored_spec_types | ported (stable handles, `nodePath`); `isinstance` and "no `.path`" are by types | DslSpec | |
| test_net_spec_name_is_optional_but_an_empty_name_is_rejected | ported | DslSpec | unnamed, empty-name |
| test_apply_named_child_is_an_ordinary_scope_that_can_receive_a_stamp | ported | DslSpec | apply.flat, apply.composed |
| test_item_navigation_authors_python_reserved_scope_segments (×4) | ported | DslSpec | reserved.{p,t,s,stamp} |
| test_item_navigation_requires_exactly_one_non_empty_scope_segment (×2) | ported | DslSpec | scope-segment.* |
| test_item_navigation_rejects_non_string_scope_segments | enforced by types | | |
| test_only_right_shift_builds_default_and_explicit_connections | ported | DslSpec | orders |
| test_arc_and_connection_specs_preserve_authored_order_and_multiplicity | ported | DslSpec | multiplicity |
| test_arc_factory_names_modes_and_does_not_accept_mode_as_a_parameter | ported (modes); the mode parameter is by types | DslSpec | |
| test_build_snapshots_are_independent_and_implementation_maps_are_immutable | ported; immutable maps are by types | DslSpec | snapshots.* |
| test_cross_specification_failure_is_atomic | enforced by types (rank-2 brand) | | |
| test_identical_configuration_is_idempotent_and_override_is_explicit | ported | DslSpec | configuration, configuration.conflict |
| test_conflicting_place_color_fails_without_mutation | ported | DslSpec | places.conflict |
| test_place_override_changes_or_clears_color_and_requires_a_base | ported | DslSpec | place-overrides.* |
| test_transition_override_preserves_omitted_fields_and_explicitly_clears_values | ported | DslSpec | transition-overrides.* |
| test_transition_override_requires_a_base_and_at_least_one_field | ported | DslSpec | invalid-overrides.* |
| test_transition_override_is_atomic_when_a_supplied_field_is_invalid | ported with a refusal that can be written; the node-as-guard value is by types | DslSpec | atomic-overrides |
| test_callable_specs_configure_stable_identity_reused_by_bare_references | ported | DslSpec | callable-specs |
| test_configuration_after_topology_applies_at_build_without_mutating_prior_snapshot | ported | DslSpec | late-configuration.* |
| test_callable_node_specs_are_rejected_as_handler_and_guard_values | enforced by types | | |
| test_canonical_net_remains_the_semantic_validation_boundary | ported with two kernel refusals (weight 0, color mismatch); place→place is by types | DslSpec | invalid.weight, invalid.color |
| test_python_comparison_operator_is_not_supported | enforced by types | | |
| test_color_adapter_rejects_non_type_objects | enforced by types (`colorOf @T` names a type's color) | DslSpec | |
| test_direct_and_callable_guard_lower_after_place_colors_and_execute_by_declaration_uri | ported, including a run inside an Instance | DslSpec | typed, typed.untyped-input |
| test_typed_guard_uses_a_custom_converter_for_every_selected_input_and_stays_anonymous | ported; the converter is a newtype's `Typed` instance, so the recorded call order does not apply | DslSpec | custom-guard |
| test_typed_guard_factory_preserves_the_exact_bool_result_contract | enforced by types (`TypedArgs Bool`); the lowered guard is still run | DslSpec | exact-bool |
| test_scalar_and_mixed_guard_forms_preserve_authored_order_and_absolute_positions | ported | DslSpec | guards, scalar |
| test_guards_reject_mutable_iterables_and_generators (×2) | enforced by types | | |
| test_handler_rejects_raw_callable_without_direct_or_advanced_flavor | enforced by types | | |
| test_petri_aware_specs_use_owner_identity_not_callable_name | ported | DslSpec | identity |
| test_same_callable_spec_reused_across_transitions_keeps_two_declarations | ported | DslSpec | reuse |
| test_build_snapshots_keep_the_callable_association_selected_at_build_time | ported | DslSpec | callable-snapshots.* |
| test_scope_stamp_rebases_reusable_definition_at_each_destination | ported | DslSpec | stamp-rebase |
| test_flat_parent_authoring_and_stamped_child_authoring_compose_together | ported | DslSpec | flat-and-stamped |
| test_stamped_specification_remains_live_between_immutable_build_snapshots | N/A (stamps embed values); both builds checked | DslSpec | live.first, live.second |
| test_restamping_a_scope_replaces_the_base_and_clears_destination_overrides | ported | DslSpec | restamp, restamp.kept-override |
| test_stamp_refuses_to_erase_direct_content_without_mutating_the_scope | ported | DslSpec | stamp-direct-content.* |
| test_stamp_diagnostics_identify_enclosing_stamp_and_requested_missing_node | ported | DslSpec | stamp-diagnostics.* |
| test_root_stamp_and_missing_connection_diagnostics_name_the_composition_location | ported | DslSpec | root-stamp, missing-connection |
| test_nested_stamps_flatten_and_stamp_cycles_fail_explicitly | ported in part (flattening); cycles cannot be represented | DslSpec | nested-stamps |
| test_copy_snapshots_a_composed_specification_without_retaining_source_links | ported as `flatten`; "no source links" holds trivially | DslSpec | copy, copy.stamped |
| test_stamped_specification_cannot_contribute_root_completion | ported | DslSpec | stamped-completion |

In total, 42 upstream test functions:

- 32 ported, 5 of them partly enforced by types;
- 8 enforced by types;
- 1 N/A, with its nets still checked by the corpus;
- 1 ported in part, with the stamp-cycle half unrepresentable.

The corpus also has these cases with no upstream DSL test of their own:

- `inherited-configuration*`: configuring stamped nodes;
- `agent-net`, `simulation-scenario`, `observation-inspection`;
- `chain-50`, `stamped-30`.

## Not at parity

Nothing that builds a Net. The reference behaviors the Haskell DSL does not
reproduce are all unrepresentable inputs or mutable-object semantics; each
is listed above and explained in DIVERGENCES.md.
