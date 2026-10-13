# hamsterdan-agents parity

This file lists what this package ports from `upstream/hamsterdan` (pinned
in [UPSTREAM.md](../../UPSTREAM.md) at `5d382467`) and the evidence for
each piece. It is package 5 of `docs/hamsterdan.md` §6.

The reference is:

- `upstream/hamsterdan/.venv`;
- Python 3.14.6;
- Petrus `89baf78`, the version Hamsterdan pins, with its Pi A2 Local host
  and scripted Pi runtime.

Tests find the reference through `upstreamPythonExecutable "hamsterdan"`
(`withReference`) from petrus-test-support, and run it with
`python -I -B`. A test that needs the reference fails when the reference is
missing. It is never skipped.

## Upstream source → Haskell

| Upstream | Haskell | Evidence |
| --- | --- | --- |
| `agents/pi.py`: the prompt envelope, `_parse_result`, `PiNativeRunner` | `Hamsterdan.Agents.Pi`, hamsterdan-contracts' `Hamsterdan.Python.Url` | `PiSpec`, plus hamsterdan-host's `PiActivitySpec`. |
| `agents/protocol.py`: the validators (the types are in hamsterdan-contracts) | `Hamsterdan.Agents.Validate` | `ProtocolSpec`, `PiSpec`. |
| `host/agenticus.py`: catalog resolution, runner selection, `AgentRouteStore`, History repair | `Hamsterdan.Host.Agenticus` | `AgenticusSpec`, plus the route-database interop. |
| `host/pi_a2.py`: the installation config and binding, persistent keys, `compose_owned_pi_a2` | `Hamsterdan.Host.PiA2` | `PiA2Spec`, `PiA2FactorySpec`, plus the sealed-key interop. |
| `host/pi_workspace.py`: `GitPiWorkspaceProvider`, archive admission | `Hamsterdan.Host.PiWorkspace` | `PiWorkspaceSpec`. |
| `host/__main__.py`: `_compose_agent_runtime`, `_close_owned_resources` | `Hamsterdan.Host.AgentRuntime` | `AgenticusSpec`, plus hamsterdan-host's `CliSpec` and `InteropSpec`. |
| `host/binding.py`, moved here from hamsterdan-host | `Hamsterdan.Host.Binding` | hamsterdan-host's `BindingSpec`. |
| The reference tests' runtime doubles | `Hamsterdan.Agents.Pi.Doubles` | Used by `PiSpec` and `PiActivitySpec`. |
| `differential/state_reference.py`'s `compose_real_agent` (the scripted agent) | `Hamsterdan.Host.Scripted` | hamsterdan-host's `InteropSpec`, and both benchmarks. |

hamsterdan-host composes all of this in `Hamsterdan.Host.Agents`
(`composeHostAgent`), as `main()` does. `serve` reads the Pi configuration,
opens `agent-routes.sqlite3`, composes the owned Pi A2 runtime and the
workspace receiver, and selects the Pi runner after an exact READY probe.

## Upstream tests

- **Cases:** collected pytest items, so each parametrization counts.
- **Examples:** hspec examples. A parametrized test is one `describe`
  named after the test, with one example per parameter.

| Upstream file | Functions | Cases | Haskell spec |
| --- | ---: | ---: | --- |
| `tests/unit/agents/test_pi.py` | 28 | 46 | `PiSpec` (33), hamsterdan-host `PiActivitySpec` (9) |
| `tests/unit/agents/test_protocol.py` | 10 | 20 | `ProtocolSpec` |
| `tests/unit/host/test_agenticus.py` | 26 | 33 | `AgenticusSpec` |
| `tests/unit/host/test_pi_a2.py` | 15 | 24 | `PiA2Spec` |
| `tests/integration/host/test_pi_workspace.py` | 12 | 20 | `PiWorkspaceSpec` |
| `tests/integration/host/test_pi_a2_factory.py` | 8 | 8 | `PiA2FactorySpec` |
| **Total** | **99** | **151** | |

- **Compile-time cases.** Four `test_pi.py` cases pass a `bool` or a `str`
  as the runner's timeout or poll interval. They do not compile in Haskell,
  because the options are `Double`s (DIVERGENCES).
- **The coding-activity cases.** Nine `test_pi.py` cases drive the Pi
  runner behind the host's V5 mutation gate, which is a hamsterdan-host
  module. They run in hamsterdan-host's `PiActivitySpec`, over this
  package's `Hamsterdan.Agents.Pi.Doubles`.
- **Undecodable Git output.** Two `PiWorkspaceSpec` examples go beyond
  upstream. A Latin-1 byte in the review diff is sanitized to
  `private Pi workspace preparation failed`, as `open`'s `except Exception`
  does. A Latin-1 byte in the canonical patch raises CPython's
  `UnicodeDecodeError` from `reconcile` with the pinned interpreter's
  message, byte for byte (checked against the reference on 2026-10-11:
  `'utf-8' codec can't decode byte 0xe9 in position 130: invalid
  continuation byte`), so the host records `error_class=UnicodeDecodeError`.
- **The crash case.** `test_pi_a2_factory.py`'s crash case runs the
  reference's crash script under the pinned Python, with Hamsterdan's
  `PersistentKeyOperations` and Petrus's scripted runtime. It then
  recovers the crashed operation in Haskell from the state Python left.

## Interop (no upstream counterpart)

| Spec | What it checks |
| --- | --- |
| `InteropSpec`: sealed keys | Each side seals connection state, and the other opens it, both ways (`differential/agents_reference.py`). The key file is 32 bytes with mode `0600` on both sides. Opening under the wrong context, and opening tampered state, are refused the same way on both sides (`KeyOperationError`). |
| `InteropSpec`: route database | Two phases of claims and settlements on one `agent-routes.sqlite3`, in all four pairings (Python/Python, Haskell/Haskell, Python/Haskell, Haskell/Python). Every pairing must leave the same rows and schema. Settled work must be refused with `resolved agent work cannot be redispatched`, and unsettled work must resume. |
| `InteropSpec`: route-repair Histories | `_terminal_operations` (the History scan of agent-route repair) on the same bytes on both sides, 17 Histories: two records joined by each of `str.splitlines()`'s 11 line boundaries (`\n`, `\r\n`, `\r`, `\v`, `\f`, `\x1c`–`\x1e`, U+0085, U+2028, U+2029), non-boundary multi-byte text, no final boundary, a U+2028 or U+0085 inside a record, an empty line and invalid UTF-8. Both sides must report the same operations or the same refusal. The port finds the boundaries in the UTF-8 bytes rather than decoding each line to text (the scan was 10 times slower that way; see hamsterdan-host's bench/RESULTS.md). |
| `InteropSpec`: route-repair History paths | The same scan where `history.jsonl` is a dangling symbolic link, a symbolic-link loop, a link to a History, a directory, or a file that cannot be read: the same operations, refusal, or propagated `OSError` (class and text). |
| `ResultDifferentialSpec` | 16 Pi review results through the reference's `_parse_result` and `_validate_result` and the port's: a valid one, then one value replaced, mostly by strings with lone surrogate escapes (titles, bodies, the empty-allowed suggestion, ids, paths, related locations, lineage, status, head, repository, extra keys) and a surrogate pair. Each must be accepted, refused with the same reason and category, or raise the same built-in exception. |
| hamsterdan-host `InteropSpec`: agent state | A full journey through `serve`'s composed agent on both hosts, over Petrus's scripted Pi runtime. Phase one reviews the first head at epoch 1; phase two reviews a new head at epoch 2. Phase one runs on one host and phase two on the other, in all four pairings. Every file under the state root must match the Python-only run: `agent-routes.sqlite3`, `pi-a2/installation`, and the runtime host's `operations.sqlite3` and `bodies.sqlite3`, alongside the host's own files. The provider calls, the reviews and the dashboard comment must match too. |

## Benchmarks

[bench/RESULTS.md](bench/RESULTS.md) has the figures, the method and the
rerun commands. Both sides are measured in wall-clock time and interleaved,
over six rows: the prompt (review envelope), the result (parse and validate
8 findings), archive admission (200 files), the sealed key (seal then
open), a route claim (claim then settle) and an agent turn (one scripted Pi
review). Haskell is faster on every row; the sealed key, which is mostly
the same cryptography on both sides, by the thinnest margin.

hamsterdan-host's [bench](../hamsterdan-host/bench/RESULTS.md) adds a full
scripted agent turn through the host: one webhook to quiescence through the
composed agent, also faster in Haskell.

## Divergences

[DIVERGENCES.md](DIVERGENCES.md) lists them. Two remain observable, each
only in which failure is raised:

- the tar reader's tolerance of malformed headers;
- the one-line uncaught traceback.

Lone surrogates in a Pi result and History paths that cannot be stat'ed
used to differ; both now match the reference (`ResultDifferentialSpec`,
`InteropSpec`).

## Not covered

- **The real Pi installation.** Running the real Pi needs the Pi CLI, Node
  and a provider key. The tests use the reference's runtime doubles and
  Petrus's scripted runtime, as the upstream tests do. The end-to-end run
  against a real GitHub App and a real Pi is the top-level `PARITY.md`
  row "End-to-end against a real GitHub App".
