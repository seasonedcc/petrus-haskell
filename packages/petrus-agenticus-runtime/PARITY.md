# petrus-agenticus-runtime parity

This package ports the host runtimes of `petrus.agenticus.runtime`, as pinned
at `upstream/petrus` 3f85fc2. So far these are ported:

- the Local Agent-as-a-Net runner;
- the Pi native runtime (`pi.py`, `pi_recovery.py`);
- the Pi A2 model phase (`pi_model_phase.py`);
- the application-owned Pi A5 runtime (`pi_application.py`);
- the Pi A2 host (`pi_a2_host.py`);
- the Codex A2 Local and A3 Gondolin host (`codex.py`,
  `_codex_gondolin_service.py`);
- the Claude A2 Local host (`claude.py`);
- the Amp A1 provider-managed host (`amp.py`).

`parity/pi.md` maps the Pi tests, corpus and benchmarks. `parity/codex.md`,
`parity/claude-a2.md` and `parity/amp.md` map the Codex, Claude and Amp tests,
the shared hosts corpus (`differential/hosts_corpus.json`) and their
benchmarks (`bench/results-hosts.md`). The Claude files are not named
`claude.md` because a case-insensitive file system would read that name as
`CLAUDE.md`. The runtime value modules (`profiles.py`, `result.py`, `operation.py`,
`installation.py`) live in `petrus-agenticus-core`, which maps their tests
(`test_profiles.py` and `test_foundation.py`).

Each `it` label in the Haskell specs is the upstream test name.

## `tests/petrus/agenticus/runtime/test_agent_net_runner.py` (10 functions)

Module: `Petrus.Agenticus.Runtime.AgentNetRunner`. Spec:
`test/Petrus/Agenticus/Runtime/AgentNetRunnerSpec.hs`.

The scripted `Binding`, `Workspace` and `Model` fixtures are ported as
`scriptedBinding`, `workspace` and `model`. They record the same call logs.
The runner drives the real Engine over a real `history.jsonl` and a real
`thread.json`.

| Upstream test | Haskell | Notes |
| --- | --- | --- |
| `test_local_runner_uses_history_for_order_and_projects_thread_idempotently` | same label | |
| `test_quiescent_reconstruction_projects_unobserved_completion_without_redispatch` | same label | |
| `test_reconstruction_finishes_thread_projection_after_attachment_settled_before_save` | same label | The reference swaps `runner.repository` for an object whose `save` fails once. The Haskell runner exposes `setRunnerRepository`, which installs the same wrapper. |
| `test_reconstructed_in_flight_model_is_indeterminate_before_first_advance` | same label | |
| `test_reconstructed_in_flight_hands_is_indeterminate_without_a_second_crossing` | same label | |
| `test_in_process_activity_failure_settles_thread_and_attachment_before_propagating` | same label | The Engine's `RuntimeError` is `Engine.EngineRuntimeError`, with the same "failed terminally" text. |
| `test_model_abort_cancels_attachment_and_projects_first_terminal_outcome` | same label | |
| `test_create_is_once_and_stale_attachment_or_grant_fails_before_history` | same label | |
| `test_mid_episode_grant_replacement_fails_before_another_engine_action` | same label | |
| `test_durable_projection_rejects_mutation_and_carries_no_private_payload` | same label | |

### Differential corpus

`differential/runner_corpus.py` writes `differential/runner_corpus.json`.
`test/Petrus/Agenticus/Runtime/RunnerDifferentialSpec.hs` replays it in two
parts.

**Scripted runs.** The corpus holds 12 runs: stop; read then stop; multi-tool
batches; every tool (including a refused `workspace_search`); not-granted and
unsupported proposals; the phase and tool budgets; `length` with and without a
proposal; `aborted`; `error`; and a model that raises. For each run the
Haskell runner must produce:

- the reference's `thread.json` bytes after `create` and after every
  `advance` (107 snapshots in all);
- the same `history.jsonl` bytes (405 records in all);
- the same refusal (`RuntimeError: activity for firing occurrence 1
  (model_phase) failed terminally: provider-failed`);
- the same Workspace and Binding call logs.

**Projection decoding.** There are 6,617 `AgentNetThreadProjection.from_data`
cases (seed 7071). Each case is one of the 107 committed snapshots, or a
snapshot with one mutation: a removed key, an extra key, or a weird value at
a sampled path. Each case must give the same compact sorted `to_data` bytes
or the same `{class, message}` refusal. The corpus has 539 accepted cases,
5,690 `ValueError` refusals and 388 `TypeError` refusals. The mutations reach
through the nested `LoopState`, `Thread`, `Episode`, `Turn`, `Continuation`
and descriptor decoders of `petrus-agenticus-core`.

Rerun:

```sh
cd upstream/petrus
.venv/bin/python ../../packages/petrus-agenticus-runtime/differential/runner_corpus.py \
  ../../packages/petrus-agenticus-runtime/differential/runner_corpus.json
```

## Benchmarks

See `bench/RESULTS.md`. A full three-phase run, which includes the fsyncs of
the atomic `thread.json` saves, is 1.9 times faster than the reference. A
projection decode and encode round trip is 1.4 times faster.

## Host test counts

| Upstream file | Functions | Cases | Haskell spec |
| --- | ---: | ---: | --- |
| `test_codex.py` | 41 | 54 | `CodexSpec`, plus 5 verbatim and interop examples |
| `test_claude.py` | 32 | 46 | `ClaudeSpec`, plus 4 sidecar examples |
| `test_amp.py` | 15 | 19 | `AmpSpec`, plus 3 sidecar examples |

`HostsDifferentialSpec` replays the 5,844-case hosts corpus in 22 sections.

## Out of scope: the `*_real.py` tests

| Upstream file | Functions | Gate upstream |
| --- | ---: | --- |
| `test_codex_real.py` | 2 | `PETRUS_CV16_CODEX_LIVE=1`, `PETRUS_CV16_CODEX_GONDOLIN_LIVE=1` |
| `test_claude_real.py` | 2 | `PETRUS_CV16_CLAUDE_QUALIFY=1`, `PETRUS_CV16_CLAUDE_LIVE=1` |
| `test_amp_real.py` | 1 | `PETRUS_RUN_CV16_AMP_A1=1` |
| `test_agent_net_real.py` | 2 | real model APIs |

These tests call real provider services: OpenAI through the `codex` CLI
(plus a real Gondolin VM image for A3), Anthropic through the Claude Agent
SDK, Amp's thread service and Orbs, and real model APIs. Each needs
credentials and makes paid calls. Upstream they are opt-in and skipped by
default.

They are not ported, for two reasons. As default tests they would add
credentials and paid calls to every run. And everything they reach on the
host side (the argv, the helper, the sidecars, admission, custody,
publication) is already exercised by the fakes: the reference's own fake
`codex` CLI and fake Gondolin SDK, and fake Claude and Amp SDK packages with
the pinned public surfaces. The per-host `parity/*.md` files list each test
and its gate.
