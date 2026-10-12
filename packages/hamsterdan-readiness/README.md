# hamsterdan-readiness

This package ports Hamsterdan's V5 PR-readiness Petri net from
`upstream/hamsterdan`: `src/hamsterdan/readiness/net_v5` and
`readiness/payloads.py`.

The net is nine actor loops plus a startup precondition. Each loop is a set
of pure folds over strict workflow tokens. Every world touch goes through a
variant-routing Activity gate. A summary board renders the dashboard's
entry log.

The built net definition matches the reference's byte for byte. Its sha256
fingerprint is `7e7d437b90c8f623f2180ab011e86ac5f4ba0fc3a8ef9d4853671970a39f9744`.
Folds, gate handlers and the board are checked against the pinned Python by
committed corpora (see [PARITY.md](PARITY.md)). Intentional API differences
are listed in [DIVERGENCES.md](DIVERGENCES.md). No wire format diverges.

## Modules

| Module | Ports | Key API |
| --- | --- | --- |
| `Hamsterdan.Readiness.NetV5` | `net_v5/__init__.py` | `buildNetV5`, `seedMarking`, `seedMarkingWith` |
| `Hamsterdan.Readiness.NetV5.Topology` | `net_v5/topology.py` | `netV5Spec`, `buildNetV5`, `gates`, `derived`, `seedMarking`, `defaultReminderDelayS`, `subjectMalformed` |
| `Hamsterdan.Readiness.NetV5.Folding` | `net_v5/folding.py` | hydration (`hydrate`, `values1`–`values3`, `revive`), `emit`, `route`, the reference's error texts |
| `Hamsterdan.Readiness.NetV5.Py` | Python operator semantics used by the folds | subscript, truthiness, comparison and merge, each with CPython's exception text |
| `Hamsterdan.Readiness.NetV5.Wiring` | the authoring idioms shared by the loops | `place`, `fold`, `gate`, `door`, `inhibit`, `filtered`, `seedToken`, `celFilter` |
| `Hamsterdan.Readiness.NetV5.{Life,Ci,Esc,Review,Mutation,Conversation,Dashboard,Reminders,Readiness,Startup}` | one loop module each | `declare`, `wire`, and the loop's folds |
| `Hamsterdan.Readiness.NetV5.Gating` | `net_v5/gating.py` | `encodeVariant`, `variantPayloadConverter`, `decodeDataclass`, `GateDefinition`, `Annotation`, `gateFlavor`, `durablePublicationGates`, `identifiedInlineGates`, `gatePolicy`, `variantRouting`, `wireGates` |
| `Hamsterdan.Readiness.NetV5.Board` | `net_v5/board.py` | `renderBoard`, `gateFacts`, `gateFactsValue` |
| `Hamsterdan.Readiness.Payloads` | `readiness/payloads.py` | `decodeModel`, `encodeModel`, `pydanticPayloadConverter` |

## Using it

```haskell
import Hamsterdan.Readiness.NetV5 (buildNetV5, seedMarking)
import Hamsterdan.Readiness.NetV5.Gating (wireGates)
import Hamsterdan.Readiness.NetV5.Topology (derived, gates)

-- the composed net, and the seed marking for one pull request
built   <- either (fail . show) pure buildNetV5
marking <- either (fail . show) pure (seedMarking "github:44:31:pr:7")
-- bind every gate transition to its Activity (the host supplies definitions)
handlers <- either (fail . show) pure (wireGates built gates definitions derived)
```

The host supplies the gate Activities, the Engine, the dispatch and the
history store. Hamsterdan's host does this in `hamsterdan-host`.
`test/Harness.hs` shows a complete wiring against a fake world.

## Tests, corpora, benchmarks

```sh
cabal test hamsterdan-readiness -j2 --test-options='+RTS -M2G -RTS'
scripts/bench-run hamsterdan-readiness +RTS -M2G -RTS
```

To regenerate the corpora, run from the repository root against the pinned
upstream environment:

```sh
upstream/hamsterdan/.venv/bin/python -I -B packages/hamsterdan-readiness/scripts/gen_topology_corpus.py
upstream/hamsterdan/.venv/bin/python -I -B packages/hamsterdan-readiness/scripts/gen_fold_corpus.py
upstream/hamsterdan/.venv/bin/python -I -B packages/hamsterdan-readiness/scripts/gen_board_corpus.py
```

Benchmark results against Python are in [bench/RESULTS.md](bench/RESULTS.md).
