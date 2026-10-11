# hamsterdan-e2e

End-to-end tooling for the Hamsterdan port: tiers B and C of
[docs/hamsterdan.md §5.2](../../docs/hamsterdan.md#52-comparison-procedure).
Tier B runs offline. Tier C is a live run of both hosts against real GitHub
Apps, and [docs/e2e.md](../../docs/e2e.md) is its runbook. Everything in this
package is tested against fakes. Nothing here talks to GitHub unless an
operator runs `scripts/e2e` without `--dry-run`.

Nothing upstream is patched. The reference host is driven through the
injection points it already has (`HostService(transport_factory=, runner=,
clock=, application_factory=)`), and the reference operator through a
runtime overlay. The Haskell host is driven through the matching seams,
which are listed in `../hamsterdan-host/DIVERGENCES.md` ("The end-to-end
seams").

## Tier B: record once, replay into both hosts

A tape (`hamsterdan-e2e-tape/1`, described in `python/tape.py`) is
everything one reference host run exchanged with the world:

- every GitHub request and its answer;
- every webhook delivery;
- every agent call;
- every Git publisher outcome;
- the clock at each step.

The pieces:

| | Python (reference environment) | Haskell |
| --- | --- | --- |
| record a journey over real HTTP | `python/record_journey.py`, `python/host_seams.py` | |
| fake GitHub answering from a tape | `python/tape_server.py` (standard library; used by both) | |
| replay into a host | `python/replay_python.py` | `hamsterdan-e2e-replay` (`Hamsterdan.E2E.Replay`) |
| compare | `python/compare_tier_b.py`: writes exact, History exact, comment set rendered | |

Each replay uses three replay seams:

- the replay runner, which answers each agent call by `(kind, operation,
  attempt)` and fails on an unknown key;
- the replay publisher;
- the step clock.

The tape server fails on any request the tape does not hold.

`TierBSpec` records all eleven readiness journeys plus three fault cases
(an agent call failing, and a GitHub connection dropped, once fatal and once
recovered). It replays each into both hosts and requires:

- the writes, identical between the replays and to the recording;
- every History file, byte for byte;
- the state directory;
- the rendered final comment set;
- no unrecorded, unused or mismatched exchange.

A last group checks that the comparison does fail when one side differs. If
the reference environment (`scripts/upstream-python hamsterdan`) cannot be
provisioned, the tests fail; they never skip.

## Tier C: both hosts live, side by side

| | Python | Haskell |
| --- | --- | --- |
| host with seams | `python/e2e_host.py` (`python -m hamsterdan.host` with `HostService` wrapped) | `hamsterdan-e2e-host` (the `hamsterdan-host` command line) |
| deterministic agent from a recorded tape | `host_seams.CarriedRunner` (`HAMSTERDAN_E2E_AGENTS`) | `Hamsterdan.E2E.Agents.carriedRunner` |
| record a live tape | `host_seams.LiveRecorder` (`HAMSTERDAN_E2E_RECORD`) | (the reference records) |
| operator over our fixture | `python/e2e_operator.py` (rebinds the HBNetwork constants) | `hamsterdan-e2e-operator` (`Operator.fixture`) |
| fixture file | `python/fixture.py` | `Hamsterdan.E2E.Fixture` |

Other tools in `python/`:

- `compare_tier_c.py`: the normalizing comparator of one checkpoint (step
  5). Its tolerances are documented in the module and in docs/e2e.md.
- `test_compare_tier_c.py`: synthetic captures that must pass or must fail.
- `rehearse_hosts.py`: starts both hosts offline against `fake_github.py`,
  sends one signed webhook, and stops them.
- `fake_gh.py`: a scripted `gh` for the operator tests.
- `live_style.py`: turns a journey tape into the shape a live tape has.

`scripts/e2e` drives a live run: it copies the fixture repositories, writes
the App manifests, starts and stops the hosts, runs the scenarios, captures
the checkpoints and compares them. Every command that would act on GitHub or
on the hosts takes `--dry-run`.

`TierCSpec` ("tier C tooling, against fakes") checks:

- **Carried agent.** The two carried agents give identical answers for
  every call. They point at the asking repository and its SHAs, and they
  fail the same way on calls with no recorded answer.
- **Operator over a fixture.** Both operators produce the same exit status,
  stdout and `gh` command lines over a non-HBNetwork fixture. This covers
  preflight (delegated and inline broker, legacy bot refused) and inspect.
- **Rehearsal.** Both hosts start under the §1.8 environment and answer
  `/healthz` and a webhook alike. They exit alike on SIGTERM (status −15)
  and on SIGINT (status 0).
- **Live-shaped tapes.** These replay alike in both hosts.
- **Comparator.** It passes and fails its synthetic captures.
- **`scripts/e2e --dry-run`.** It runs nothing, writes nothing and prints
  no secret.

```
nice -n 10 cabal -j2 test hamsterdan-e2e --test-options='+RTS -M2G -RTS'
python3 -B packages/hamsterdan-e2e/python/test_compare_tier_c.py
scripts/e2e rehearse
```
