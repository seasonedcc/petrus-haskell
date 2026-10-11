# petrus-dst parity

Port of `petrus.testing.dst` (`upstream/petrus/src/petrus/testing/dst.py`) at the pin `3f85fc2`.

**Status: at parity.** With the evidence below:

- the World interpreter, Timeline and choice streams;
- artifacts v1 to v4, replay and the registry;
- the process runner, including the complete public-Engine resource world in a child;
- every Engine-backed world on the real Haskell Engine, including the 33 joined
  History/Dispatch worlds over PostgreSQL History, the Absurd Engine and real Absurd Workers.
  That means the profiles, the checkers, the authoring stories, and replay of all 51 fixtures
  through those profiles with the reference's exact result bytes.

API differences are in [DIVERGENCES.md](DIVERGENCES.md). Wire formats do not diverge.
Benchmarks are in [bench/RESULTS.md](bench/RESULTS.md): Haskell is faster on every workload,
including the joined worlds, where PostgreSQL does most of the work and the margin is small
(1.10–1.11×; the isolated database alone is level at 1.02×).

## Evidence

`cabal build petrus-dst && cabal test petrus-dst` runs 216 hspec examples with
`PETRUS_TEST_POSTGRES` set (the 66 joined examples are pending without it). Each one compares
against vectors produced by the pinned Python. The ten generator scripts are committed under
`scripts/`, and their output under `test/data/` (and, for the generated identities module,
under `joined/`).

| Vectors | Script | What it pins | Spec |
| --- | --- | --- | --- |
| `codec-vectors.json` | `codec_vectors.py` | 53 fixture verdicts, 5523 structural mutations, 65 raw-byte loader cases, 150 recursion-guard boundaries (each JSON value location nested in lists, objects, or both, at the deepest admitted and first refused depth) | `Spec.Codec` |
| `world-stories.json` | `world_stories.py` | 22 toy World stories: artifacts, replays, observations, exception classes and messages | `Spec.Stories` |
| `choice-vectors.json` | `choice_vectors.py` | 6 golden draw scripts, plus refusals and provenance validation | `Spec.Choice` |
| `process-vectors.json` | `process_vectors.py` | 8 child runs (progress bytes, exit status, result), 36 crafted progress folds, 1 input-budget refusal | `Spec.Runner` |
| `transcripts.json` | `transcript_vectors.py` | the 51 Engine world fixtures replayed by the reference, with every door call recorded (1456 door calls, 362 context events, 447 checks), plus 5 replay mutations | `Spec.Transcript` |
| `generated-stories.json` | `generated_stories.py` | 400 seeded random toy scripts: refusals, settling, disposition, artifact bytes, replay result | `Spec.Properties` |
| `engine-authored.json` | `engine_authored.py` | the artifact bytes of all 18 non-joined `build_*_artifact` builders (engine ×9, delayed, delivery, timer, lifecycle ×2, retry ×3, generated runtime) | `Spec.EngineWorlds` authoring |
| `engine-checkers.json` | `engine_checker_vectors.py` | 26 full checker verdicts (`passed` and every `detail` field): the 13 upstream `*_checker_*` unit tests; the 10 cases of the generated-runtime divergence test, including its stateful frozen-execution check; 3 extra passing and refusing cases | `Spec.EngineCheckers` |
| `joined-checkers.json` | `joined_checker_vectors.py` | 35 full joined checker verdicts: every observation the 21 upstream joined `test_*checker*` functions hand to a checker, recorded with the whole verdict, plus one close-vocabulary vector per recorded reset-checker observation | `Spec.EngineCheckers` |
| `joined/Petrus/Testing/Dst/Joined/Identities.hs` | `joined_identities.py` | every joined Profile and Checker identity definition, evaluated by the reference module itself (never transcribed by hand) | every joined authoring and replay test (an identity mismatch fails closed) |

The Engine worlds are also checked without vectors. `Spec.EngineWorlds` replays every non-joined
fixture, and `Spec.JoinedWorlds` every joined fixture, through fresh real profiles and compares
the replay result bytes with the reference's (`transcripts.json` `outcome`).

The Haskell tests also include properties:

- 300 random toy scripts, whose artifacts round-trip byte for byte and replay to `pass`;
- 2000 random JSON values, encoded canonically exactly as petrus-json encodes them;
- choice-stream isolation under arbitrary interleavings.

### Regenerating the vectors

`scripts/check-corpora petrus-dst` reruns every generator below against the pinned reference
(under a throwaway PostgreSQL server when `PETRUS_TEST_POSTGRES` is unset) and fails on any
file that no longer matches; `--update` writes the regenerated files. By hand, run these from
`upstream/petrus`:

```sh
PYTHONPATH=. uv run --frozen python ../../packages/petrus-dst/scripts/codec_vectors.py ../../packages/petrus-dst/test/data/codec-vectors.json
PYTHONPATH=. uv run --frozen python ../../packages/petrus-dst/scripts/world_stories.py ../../packages/petrus-dst/test/data/world-stories.json
PYTHONPATH=. uv run --frozen python ../../packages/petrus-dst/scripts/choice_vectors.py ../../packages/petrus-dst/test/data/choice-vectors.json
PYTHONPATH=. uv run --frozen python ../../packages/petrus-dst/scripts/process_vectors.py ../../packages/petrus-dst/test/data/process-vectors.json
PYTHONPATH=. uv run --frozen python ../../packages/petrus-dst/scripts/generated_stories.py ../../packages/petrus-dst/test/data/generated-stories.json
PYTHONPATH=. uv run --frozen python ../../packages/petrus-dst/scripts/transcript_vectors.py postgres://USER@HOST:PORT/postgres ../../packages/petrus-dst/test/data/transcripts.json
PYTHONPATH=. uv run --frozen python ../../packages/petrus-dst/scripts/engine_authored.py ../../packages/petrus-dst/test/data/engine-authored.json
PYTHONPATH=. uv run --frozen python ../../packages/petrus-dst/scripts/engine_checker_vectors.py ../../packages/petrus-dst/test/data/engine-checkers.json
PYTHONPATH=. uv run --frozen python ../../packages/petrus-dst/scripts/joined_checker_vectors.py ../../packages/petrus-dst/test/data/joined-checkers.json
PYTHONPATH=. uv run --frozen python ../../packages/petrus-dst/scripts/joined_identities.py ../../packages/petrus-dst/joined/Petrus/Testing/Dst/Joined/Identities.hs
```

To run the joined worlds, point `PETRUS_TEST_POSTGRES` at a server where the role may create
databases (each joined example makes and drops its own):

```sh
PETRUS_TEST_POSTGRES=postgresql://postgres:postgres@localhost:5432/postgres cabal test petrus-dst
```

`transcript_vectors.py` replays the joined fixtures against real Postgres, as the reference
tests do. It needs a server DSN with the right to create databases, and makes one isolated
database per replay. Every script's output is deterministic: rerunning it reproduces the
committed file byte for byte.

## The Engine seam

The DST interpreter never sees the Engine. It sees two records:

- `Profile m g`, the system under test's doors;
- `Checker`, the pure invariants.

The Engine-backed profiles (`tests/dst/engine_world.py`, the joined worlds) are Python classes
over the production Engine. Their Haskell twins are below; `Petrus.Testing.Dst.Transcript`
also checks the interpreter on its own, without any Engine. `transcript_vectors.py` wraps every profile and checker the reference
registers while it replays a fixture, and records:

- each door call, with its arguments and outcome;
- the scenario-context services the door used (`now`, `stable_id`, `faults`) and their results;
- each checker verdict.

`transcriptRegistry` serves those outcomes back as a `Registry IO`. It re-executes the context
services and compares them with the record. `replayTranscript` then runs the Haskell replay
over the fixture.

The test requires both:

- the same calls, in the same order, with the same arguments (otherwise `TranscriptDivergence`);
- the replay result bytes the reference produced.

So the interpreter's replay half is checked against every Engine fixture, including the joined
Postgres worlds.

### Real Engine profiles

The internal library `petrus-dst:engine-worlds` (`engine/`) ports the reference's non-joined
world modules. Each becomes `Profile IO g` and `Checker` values over:

- the real Haskell Engine (`petrus-engine`);
- the real JSONL History store (`petrus-history-store`);
- either the in-memory Dispatch or the real SQLite `LocalDispatch` (`petrus-motus`).

| Reference module | Haskell module | Profiles | Fixtures replayed | Builders authored |
| --- | --- | --- | --- | --- |
| `engine_world.py` | `Petrus.Testing.Dst.Engine.Projection` | projection, resource-bounded, history-refusal, history-ack-loss, dispatch-refusal | 9 | 9 |
| `delayed_world.py` | `…Engine.Delayed` | delayed terminal | 1 | 1 |
| `delivery_world.py` | `…Engine.Delivery` | identified delivery | 1 | 1 |
| `timer_world.py` | `…Engine.Timer` | timer recovery | 1 | 1 |
| `lifecycle_world.py` | `…Engine.Lifecycle` | lifecycle race, cancellation refusal | 2 | 2 |
| `retry_world.py` | `…Engine.Retry` | LocalDispatch retry, delayed retry (World provider clock), local terminal | 3 | 3 |
| `generated_runtime_world.py` | `…Engine.GeneratedRuntime` | generated runtime (9 resource gauges) | 1 | 1 |

`Spec.EngineWorlds` runs each fixture through fresh profiles in a fresh directory, and runs each
story on a fresh History. Two checks follow:

- the authored bytes must equal the reference builder's;
- the authored artifact must replay to `pass`.

The transcripts stay as an independent cross-check of every door call, including for the joined
worlds.

### Joined profiles

The internal library `petrus-dst:joined-worlds` (`joined/`) ports the four joined world modules.
Each profile hosts the real Absurd Engine (`petrus-engine-absurd`) over the real PostgreSQL
History store (`petrus-history-postgres`) and the real Absurd Dispatch, with
`AbsurdWorkerDispatch` Workers (`petrus-motus-absurd`) completing the Activities. The fault
doors wrap the same sessions the reference wraps (History commit refusal and acknowledgement
loss, Dispatch refusal).

| Reference module | Haskell module | Fixtures replayed | Builders authored |
| --- | --- | --- | --- |
| `joined_world.py` | `Petrus.Testing.Dst.Joined.World` (profile), `…Joined.Stories` (25 builders) | 25 | 25 |
| `joined_creation_world.py` | `…Joined.Creation` (profile and its 4 builders) | 4 | 4 |
| `joined_registration_world.py` | `…Joined.World`, `…Joined.Stories` | 2 | 2 |
| `joined_seal_world.py` | `…Joined.World`, `…Joined.Stories` | 2 | 2 |
| every module's checkers | `…Joined.Checkers` (26 checkers) | | |
| shared fixture plumbing | `…Joined.Support` | | |
| every identity constant | `…Joined.Identities` (generated) | | |

`Spec.JoinedWorlds` runs each of the 33 fixtures twice, each time in a fresh scratch database:

- replay: the fixture through a fresh profile, ending with the reference's replay result bytes;
- authoring: the Haskell story must produce exactly the fixture's bytes, and the authored
  artifact must replay through a fresh profile in another fresh database with outcome `pass`,
  the story's disposition, and every operation consumed.

## Upstream test map

Every test in `upstream/petrus/tests/dst/`.

### `test_world.py`

| Upstream test | Haskell |
| --- | --- |
| `test_world_owns_stable_ids_total_tie_order_and_logical_time` | `Spec.Stories` stable-order |
| `test_version_four_accounts_for_profile_resources_and_replays_exactly` | `Spec.Stories` resource-v4 |
| `test_version_four_retains_the_accepted_operation_which_exceeds_a_profile_resource` | `Spec.Stories` resource-exhaustion-v4 |
| `test_version_four_requires_an_exact_stable_resource_key_set` | `Spec.Stories` resource-keyset |
| `test_predicate_poll_budget_ends_explicitly` | `Spec.Stories` "ends the predicate-poll budget explicitly". The upstream test drives an Engine profile; the toy authors the same budget path, and the Engine budget-failure worlds author through the real profile in `Spec.EngineWorlds` |
| `test_constructor_closes_an_installed_generation_when_initial_checker_refuses` | `Spec.Stories` constructor-checker-refusal |
| `test_every_authored_finish_refuses_scheduled_work` | `Spec.Stories` finish-pending |
| `test_fair_phase_drains_profile_work_without_new_authored_interference` | `Spec.Stories` fair-phase |
| `test_profile_validates_fault_when_it_is_activated` | `Spec.Stories` fault-validation |
| `test_generation_start_requires_detached_scheduled_values` | enforced by types (DIVERGENCES.md) |
| `test_action_timer_and_logical_time_budgets_end_explicitly` | `Spec.Stories` action-timer-logical |
| `test_queue_reload_and_artifact_byte_budgets_end_explicitly` | `Spec.Stories` queue-reload-bytes |
| `test_executable_story_preserves_the_strict_version_three_artifact` | `Spec.EngineWorlds` `engine_world.build_projection_artifact` (bytes and replay); `Spec.Codec` |
| `test_choice_authorities_are_repeatable_and_stream_isolated` | `Spec.Choice`, `Spec.Properties` |
| `test_choice_authorities_refuse_implicit_or_malformed_inputs` | `Spec.Choice`, `Spec.Stories` "refuses choices in an unseeded World" |
| `test_seeded_story_is_exact_and_replay_uses_expanded_operations` | `Spec.EngineWorlds` `build_seeded_projection_artifact` and the seeded fixture; `Spec.Stories` seeded toys; the changed-seed mutation in `Spec.Transcript` |
| `test_seeded_manual_replay_route_is_deterministic` | the CLI `python -m tests.dst.replay_world` is Python tooling; its replay result bytes are compared exactly in `Spec.EngineWorlds` and `Spec.Transcript` |
| `test_history_refusal_before_terminal_is_exact_and_replayable` | `Spec.EngineWorlds` `build_history_refusal_artifact` and its fixture |
| `test_history_refusal_manual_replay_route_is_deterministic` | tooling (as above) |
| `test_commit_authority_checker_refuses_a_terminal_above_external_acceptance` | `Spec.EngineCheckers` |
| `test_legacy_version_one_artifact_remains_byte_exact` | `Spec.Codec` |
| `test_retained_artifact_replays_through_the_same_interpreter` | `Spec.EngineWorlds` `projection-crash-recovery-world-v1.json`; `Spec.Transcript` (pins the drop and close calls too) |
| `test_legacy_manual_replay_route_is_deterministic` | tooling (as above) |
| `test_failed_attempt_artifacts_are_exact_and_replayable` | `Spec.EngineWorlds` `build_invariant_failure_artifact`, `build_budget_failure_artifact`, `build_resource_budget_failure_artifact`; `Spec.Stories` authored-checker-failure |
| `test_retained_version_two_failure_artifacts_remain_exact_and_replayable` | `Spec.EngineWorlds` (the two v2 fixtures through real profiles), `Spec.Codec` |
| `test_authored_command_checker_failure_replays_the_submit_attempt` | `Spec.Stories` authored-checker-failure |
| `test_replay_does_not_apply_an_accepted_failed_attempt_twice` | `Spec.Stories` authored-checker-failure (its passing replay) |
| `test_profile_and_checker_exceptions_are_not_reclassified_as_world_failures` | `Spec.Stories` not-reclassified |
| `test_failed_attempt_manual_replay_is_deterministic` | tooling (as above) |
| `test_crash_revokes_before_drop_and_close_remains_distinct` | `Spec.EngineWorlds` Engine stories (crash, drop, fresh load; the stories assert the drop counts); `Spec.Stories` stale-timeline toy; drop and close calls in `Spec.Transcript` |
| `test_checker_runs_after_create_actions_crash_and_fresh_load` | the checker triggers are in every journal digest, which `Spec.EngineWorlds` authoring compares byte for byte |
| `test_run_until_external_wait_has_checkpoint_diagnostics` | `Spec.Stories` "reports run_until's external wait…" |
| `test_supported_surface_has_no_root_reexports_or_private_runtime_handles` | the export lists of `Petrus.Testing.Dst`; the structural `Scenario` context (DIVERGENCES.md) |
| `test_unknown_mismatched_or_non_strict_artifacts_refuse` | `Spec.Codec` |
| `test_duplicate_and_nonfinite_artifact_data_refuses` | `Spec.Codec` |
| `test_version_two_failure_artifact_requires_one_exact_terminal_failure` | `Spec.Codec` |
| `test_failure_replay_refuses_a_changed_expected_failure_location` | `Spec.Transcript` changed-failure-location mutation |
| `test_replay_fails_closed_on_manifest_or_journal_digest_mismatch` | `Spec.Transcript` checker-version-mismatch and journal-digest-mismatch mutations |
| `test_registry_fails_closed_on_profile_or_checker_identity_mismatch` | `Spec.Transcript` checker-unregistered mutation; `Spec.Stories` misuse refusals and foreign-profile |

### `test_process_runner.py`

| Upstream test | Haskell |
| --- | --- |
| `test_process_input_budget_refuses_a_scenario_before_launch` | `Spec.Runner` "refuses a spec over its input budget before launch" |
| `test_complete_public_engine_world_runs_and_replays_from_a_fresh_process` | `Spec.Runner` "runs the complete public-Engine world in a child and replays it from a fresh process". This is the real resource-bounded Engine world: 14 operations, 39 journal entries, its last resource sample and its last check |
| `test_watchdog_terminates_and_reaps_a_hung_profile_with_its_acknowledged_prefix` | `Spec.Runner` "terminates and reaps a hung profile…" |

### Engine world files

These files:

- `test_delayed_world.py`, `test_delivery_world.py`, `test_dispatch_refusal_world.py`;
- `test_history_ack_loss_world.py`, `test_lifecycle_world.py`,
  `test_lifecycle_cancellation_world.py`;
- `test_local_terminal_world.py`, `test_resource_world.py`, `test_retry_world.py`,
  `test_timer_world.py`;
- `test_joined_world.py`, `test_joined_creation_world.py`, `test_joined_registration_world.py`,
  `test_joined_seal_world.py`.

Their tests map by kind:

| Kind of test | Non-joined worlds | Joined worlds |
| --- | --- | --- |
| `*_is_exact_and_replayable` | `Spec.EngineWorlds`: the authored bytes equal the reference builder's, the artifact replays to `pass`, and the fixture replays through fresh real profiles to the reference's result bytes | `Spec.JoinedWorlds` authoring (33 tests: 25, 4, 2, 2), the same three checks over PostgreSQL |
| `test_retained_*_replays_*` | `Spec.EngineWorlds` | `Spec.JoinedWorlds` replay (33 tests: 25, 4, 2, 2); also `Spec.Transcript` |
| `*_manual_replay_route_is_deterministic` | Python CLI tooling; the replay result bytes are compared in `Spec.EngineWorlds` | (none upstream) |
| `*_checker_*` (checker unit tests over Engine observations) | `Spec.EngineCheckers` | `Spec.EngineCheckers` over `joined-checkers.json` (21 tests: 17, 2, 1, 1) |

Upstream test counts of the joined files: `test_joined_world.py` 67, `test_joined_creation_world.py`
10, `test_joined_registration_world.py` 5, `test_joined_seal_world.py` 5. Upstream skips the 66
PostgreSQL tests without `PETRUS_TEST_POSTGRES`; `Spec.JoinedWorlds` marks them pending, saying
so.

The non-joined files are:

- `test_delayed_world.py`, `test_delivery_world.py`, `test_dispatch_refusal_world.py`;
- `test_history_ack_loss_world.py`, `test_lifecycle_world.py`,
  `test_lifecycle_cancellation_world.py`;
- `test_local_terminal_world.py`, `test_resource_world.py`, `test_retry_world.py`,
  `test_timer_world.py`.

### `test_generated_runtime_world.py`

| Upstream test | Haskell |
| --- | --- |
| `test_cross_layer_runtime_story_is_exact_and_replayable` | `Spec.EngineWorlds` `generated_runtime_world.build_generated_runtime_artifact` (bytes, then replay to `pass`) |
| `test_cross_layer_checker_rejects_independent_authority_divergence` | `Spec.EngineCheckers`: the passing observation, the 8 single-property mutations, and the stateful frozen-execution case on one checker instance |
| `test_focused_generated_runtime_schedules_replay_exactly`, `test_broad_generated_runtime_schedules_replay_exactly` | hypothesis campaigns (out of scope, below); the minimized fixture they retain replays in `Spec.EngineWorlds` |

### Out of scope

These are Engine-backed campaign tooling, or formats that are not `testing/dst.py`:

- Hypothesis campaigns over the Engine:
  - the hypothesis state machines of `test_generated_runtime_world.py`;
  - `test_generated_runtime_qualification.py`;
  - `test_generated_delivery_world.py`.

  The minimized fixture they retain, `generated-runtime-minimized-fair-regression-v4.json`,
  replays through the real profile in `Spec.EngineWorlds`. The profile and checker the
  campaigns drive are ported; the hypothesis drivers are not.
- `test_replay.py` covers the legacy `tests/dst/replay.py` format.
  `projection-crash-recovery-v1.json` and `generated-runtime-semantic-coverage-v1.json` are not
  `petrus-dst-world` artifacts. `Spec.Codec` checks that the strict loader refuses both, as the
  reference's does.
- `test_failure.py` covers failure bundles (`tests/dst/failure.py`).
- `test_dst_boundaries.py` and `test_campaign.py` cover the pytest campaign and boundary
  runners.

## What the port found

A reference quirk: a budget refusal after the World has ended records a second failure
operation, so the World can no longer produce its artifact. The port reproduces it, and the
`failure-after-end` story pins it (see DIVERGENCES.md).

## Not ported

The reference's `LivelockMutationProfile` lives in `tests/dst/generated_runtime_qualification.py`,
a qualification mutant of the generated-runtime world. Only the hypothesis campaign
`test_generated_runtime_qualification.py` uses it (out of scope, above), and no committed
fixture names it. It is not a joined or Absurd profile.
