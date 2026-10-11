# hamsterdan-agents

Hamsterdan's Pi agent adapter and its host composition.

- **The adapter** (`src/hamsterdan/agents`): the canonical Pi prompt
  envelope, strict validation of review, conversation and coding results,
  and the Pi native runner over Petrus's Pi A2 Local host.
- **The host composition** (`host/{agenticus,pi_a2,pi_workspace}.py`):
  - Agenticus catalog resolution and runner selection;
  - the durable agent route store (`agent-routes.sqlite3`) and its repair
    from Instance Histories;
  - the Pi A2 installation binding, sealed connection keys, and the owned
    Pi A2 runtime;
  - the private Git workspace provider and settled-archive admission.

hamsterdan-host composes it into `serve` (`Hamsterdan.Host.Agents`).

Every file this package writes under the state directory is the
reference's, byte for byte, so the Haskell and Python hosts can resume each
other's agent state. See [PARITY.md](PARITY.md),
[DIVERGENCES.md](DIVERGENCES.md) and [bench/RESULTS.md](bench/RESULTS.md).
