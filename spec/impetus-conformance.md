# Impetus conformance checklist (upstream `spec/` at the pin)

This list enumerates the testable obligations of the six core documents of
the upstream specification (`upstream/petrus/spec/` at the commit UPSTREAM.md
pins):

- `net-schema.md`;
- `firing-semantics.md`;
- `event-history.md`;
- `handler-contract.md`;
- `net-definition-v3.md`;
- `net-document-v1.md`.

Each obligation is mapped to the Haskell example that checks it. Upstream
states that "a normative behavior without an executable check remains a
coverage gap" (`spec/README.md`); this ledger makes those gaps visible. The
format follows [fabric-conformance.md](fabric-conformance.md) and
[processes-conformance.md](processes-conformance.md).

Each check gives:

- its identifier;
- its level:
  - `kernel`: pure Petrinet values (`Net`, `Marking`, enabledness, the firing
    transform, Transition Selection);
  - `instance`: an `Instance` and its History;
  - `codec`: the History codec and the Net-definition and Net-document
    parsers and writers;
  - `interop`: compared with the pinned reference (committed corpora, golden
    traces, or a live round trip);
  - `engine`: owned by the Engine or Dispatch packages; listed so the
    document is complete;
  - `types`: the Haskell types rule the violation out;
- the section of the upstream document it verifies;
- the evidence.

Evidence names Hspec examples by their path in the `petrus-impetus` suite,
written `group › subgroup › example`, unless another package is named.
`cabal test petrus-impetus --test-options='-m "<example>"'` runs one. The
top-level groups live in these modules:

| group | module (`packages/petrus-impetus/test/Petrus/Impetus/`) |
| --- | --- |
| `Petrinet.Schema` | `SchemaSpec.hs` |
| `Petrinet.Marking` | `MarkingSpec.hs` |
| `Petrinet.Enabledness` | `EnablednessSpec.hs` |
| `Petrinet arc filters` | `ArcFiltersSpec.hs` |
| `Petrinet.Firing` | `FiringSpec.hs` |
| `Petrinet.Dot` | `DotSpec.hs` |
| `Instance FIFO drain` | `FifoQueueSpec.hs` |
| `Instance firing` | `InstanceFiringSpec.hs` |
| `Instance firing occurrences` | `FiringOccurrencesSpec.hs` |
| `Instance handlers` | `HandlersSpec.hs` |
| `Instance runtime` | `RuntimeSpec.hs` |
| `Instance awaiting termination` | `AwaitingTerminationSpec.hs` |
| `Instance completion` | `CompletionSpec.hs` |
| `Instance guards` | `GuardBranchSpec.hs` |
| `Instance CEL guards` | `CelGuardsSpec.hs` |
| `Ingress` | `IngressSpec.hs` |
| `Delivery registrations` | `RegistrationsSpec.hs` |
| `Lifecycle scopes` | `LifecycleScopesSpec.hs` |
| `Timers` | `TimersSpec.hs` |
| `Resume` | `ResumeSpec.hs` |
| `Instance replay properties` | `InstanceReplayPropertiesSpec.hs` |
| `Activity invocation seam` | `ActivitySeamSpec.hs` |
| `typed bindings` | `TypedBindingsSpec.hs` |
| `Selection` | `SelectionSpec.hs` |
| `History` | `HistorySpec.hs` |
| `History codec` | `HistoryCodecSpec.hs` |
| `HistoryStore contract` | `HistoryStoreSpec.hs` |
| `Petrinet.Firing through the Instance` | `FiringHistorySpec.hs` |
| `Petrus.Impetus.NetDefinition` | `NetDefinitionSpec.hs` |
| `Petrus.Impetus.NetDocument` | `NetDocumentSpec.hs` |
| `Petrus.Impetus.NetDocument lineage` | `NetDocumentLineageSpec.hs` |
| `spec/ fixtures` | `SpecFixturesSpec.hs` |
| `Net definition and document round-trip properties` | `NetDefinitionPropertiesSpec.hs` |
| `Petrus.Impetus.NetDefinition differential corpus` | `NetDefinitionCorpusSpec.hs` |
| `Petrus.Impetus JSON Schema differential corpus` | `JsonSchemaSpec.hs` |
| `Impetus golden traces` | `GoldenTracesSpec.hs` |
| `Petrus.Impetus.Instance differential corpus` | `KernelDifferentialSpec.hs` |
| `kernel properties` | `KernelPropertiesSpec.hs` |
| `live round trip through the pinned reference` | `LiveSpec.hs` |

The documents also carry rationale, history, and comparisons with other
systems (the Petrus oracle, velocitron). Those are not obligations. Neither
are statements marked DEFERRED or OPEN, nor behavior the pin does not ship
(see [Not applicable at the pin](#not-applicable-at-the-pin)).

## A net-schema.md

- **I-001** `types` §Explicit schema, never derived. A Net is built only from
  explicit places, transitions and arcs. Handlers bind afterwards, by
  declaration, through the Instance configuration; nothing derives topology
  from them. *(`mkNet` takes no implementation; `Instance handlers › handler
  declaration bindings`)*
- **I-002** `kernel` §Nodes. A place and a transition share one namespace: a
  name collision between them is refused, and so is a duplicate node path.
  *(`Petrinet.Schema › Net › rejects a place/transition name collision`;
  `rejects duplicate node paths`)*
- **I-003** `kernel` §Places. A typed place's color resolves once onto every
  otherwise-untyped incident arc, for consume, read, inhibit and output arcs.
  *(`Petrinet.Schema › Net › resolves a place color onto untyped incident
  arcs`; `typed places › resolve untyped input and output arcs once for
  Consume` / `Read` / `Inhibit`)*
- **I-004** `kernel` §Places. An explicit arc color that conflicts with a
  typed place is refused, in either direction. On an untyped place the
  explicit arc color stays the arc's contract. *(`Petrinet.Schema › Net › an
  explicit arc color conflicting with its place › is rejected on source ->
  move` / `on move -> source`; `keeps an explicit arc color as the contract of
  an untyped place`)*
- **I-005** `instance` §Places. A typed place's initial marking holds only
  its declared color. A token of another color, or a black token, is refused
  before any History record. *(`Instance runtime › typed-place initial
  marking`, 2 examples, beyond upstream; `petrus-engine` `DeliveryPhasesASpec`:
  "load refuses initial token color the live constructor rejects")*
- **I-006** `instance` §Places. A place with no outgoing arcs is a legal
  accumulator. *(`Instance FIFO drain › the sink accumulates in arrival
  order`)*
- **I-007** `kernel` §Transitions, §Source transitions. Source-ness is
  structural: a transition is a source iff it has no input arcs. *(`Petrinet.Schema
  › Net › identifies source transitions`; `treats a transition without inputs
  as a source`; `does not treat a transition with inputs as a source`)*
- **I-008** `kernel` §Source transitions. A source transition is never a
  scheduler candidate and fires only on external delivery. *(`Petrinet.Enabledness
  › candidates › excludes source transitions`; `Instance firing occurrences ›
  begin › rejects a source transition`; `Ingress › delivery › rejects delivery
  to a non-source transition`)*
- **I-009** `instance` §Source transitions. One source transition
  demultiplexes delivered tokens by color through its output arcs. Delivered
  tokens no arc admits are left undeposited. *(`Ingress › delivery › routes
  delivered tokens by color through the output arcs`; `leaves delivered tokens
  no arc admits undeposited`)*
- **I-010** `instance` §Source transitions. The single writer enforces
  idempotent acceptance of a delivery identity:
  - a redelivered identity gets the prior acknowledgement and appends
    nothing;
  - reusing an identity for other content is a conflict.

  *(`Ingress › delivery identity enforcement`, 7 examples)*
- **I-011** `engine` §Source transitions. A Sensor that learned an answer
  re-offers it under the same delivery identity. *(`petrus-engine`
  `ExecutionSpec`: "sensor can redeliver the identity returned by a prior
  acceptance")*
- **I-012** `kernel` §Arcs. Place → place and transition → transition arcs are
  refused. *(`Petrinet.Schema › Net › rejects an arc between two places`;
  `rejects an arc between two transitions`, beyond upstream)*
- **I-013** `kernel` §Input arc modes. The modes are exactly consume, read and
  inhibit, and only an input arc has one. *(`Petrinet.Schema › Net › arc mode
  predicates`; `rejects a mode on an output arc`)*
- **I-014** `kernel` §Inscriptions. An untyped arc admits any token, a typed
  arc only its color. *(`Petrinet.Schema › Net › lets an untyped arc admit
  anything`; `lets a typed output arc admit its color only`)*
- **I-015** `kernel` §Inscriptions. A filter sees one token and narrows
  admission after the color check, on consume, read and inhibit arcs. An
  inhibit filter gates on the absence of a matching token. *(`Petrinet.Enabledness
  › selection › narrows color admission by the filter`; `never reaches the
  filter on a color mismatch`; `Petrinet arc filters › read and inhibit
  filters`, 3 examples)*
- **I-016** `kernel` §Inscriptions. Weight applies to every input mode: a
  consume arc needs that many admitted tokens, and an inhibitor is satisfied
  below its weight. A weight below one is refused. *(`Petrinet.Enabledness ›
  offer › vetoes for a consume arc below weight`; `vetoes for an inhibit arc
  at weight`; `is satisfied for an inhibit arc below weight`; `Petrinet.Schema
  › Net › rejects a weight below one`)*
- **I-017** `kernel` §Inscriptions. A filter on an output arc is refused.
  *(`Petrinet arc filters › filter validation › rejects a filter on an output
  arc`)*
- **I-018** `instance` §Inscriptions. The handler supplies output tokens keyed
  by destination. Only tokens whose color and destination match an output arc
  are deposited, so one firing can send different payloads down different
  arcs. *(`Instance handlers › per-arc output contracts`, 4 examples)*
- **I-019** `kernel` §Arc identity. Parallel arcs between one endpoint pair
  keep their order. A unique arc's URI has no fragment; repeated pairs use
  `#$N`; filters use `#filter` or `#filter:$N`. *(`Petrinet.Schema › Net ›
  aligns arc occurrences and filters by position`; `addresses a unique arc
  without a fragment`; `NetUri › escapes arc endpoints and preserves one
  fragment for the arc filter`)*
- **I-020** `instance` §Completion condition. The completion condition never
  affects enabledness or firing. *(`Instance completion › status resolution ›
  never affects enabledness or firing`; `is running while enabled even when
  the condition already holds`)*
- **I-021** `instance` §Completion condition. The condition's place references
  must resolve, and a named symbol must have an implementation, at
  construction. *(`Instance completion › completion validation`, 2 examples;
  `named completion › fails at construction on a missing implementation`)*
- **I-022** `kernel` §Colored tokens and markings. A place's tokens form a
  FIFO queue that admits duplicates. A consume removes the front-most equal
  occurrence, and entry instants mirror the queue. *(`Petrinet.Marking ›
  TokenQueue › remove`, 7 examples; `Timers › entry instants`, 2 examples;
  `Instance FIFO drain › each firing consumes the front token`)*
- **I-023** `kernel` §Addressing. A NetPath is validated strictly (no empty
  path or segment) and round-trips its spelling. *(`Petrinet.Schema ›
  NetPath`, 9 examples)*
- **I-024** `kernel` §Addressing. NetUri is canonical ASCII:
  - typed schemes;
  - `->` between arc endpoints;
  - uppercase percent escapes.

  Noncanonical spellings are refused. *(`Petrinet.Schema › NetUri`, 9
  examples)*
- **I-025** `kernel` §Addressing. A handler is `#handler`, a named guard
  `#guard:name`, an anonymous guard `#guard:$N`. A leading `$` is reserved,
  and duplicate named guards are refused. *(`Petrinet.Schema › Net › indexes
  transition behavior declarations canonically`; `reserves the generated
  namespace for handlers` / `for guards`; `rejects duplicate named guards`)*
- **I-026** `types` §Addressing. Execution takes typed records and
  identifiers and never parses a History URI to find runtime state. No such
  lookup exists in the API.
- **I-027** `kernel` §Flattened net. The flattened net indexes nodes by path,
  behavior declarations by NetUri, and inputs and outputs per transition. An
  anonymous declaration's display name is outside equality, URIs and binding.
  *(`Petrinet.Schema › Net › indexes inputs and outputs`; `indexes transition
  behavior declarations canonically`; `treats an anonymous declaration's
  display name as non-semantic`)*
- **I-028** `interop` §Python authored-net frontend. The DSL builds the same
  canonical Net as the reference DSL: the same v3 bytes, order, URIs, and
  refusals. *(`petrus-dsl`: 68-net differential corpus and `DslSpec`; see
  [its ledger](../packages/petrus-dsl/PARITY.md))*
- **I-029** `kernel` §Python Graphviz presentation. DOT generation:
  - is deterministic in canonical order;
  - shows token counts only;
  - marks source transitions;
  - keeps anonymous display names out of identity;
  - escapes user text.

  *(`Petrinet.Dot › golden source`; `marking, declarations, and arc
  semantics`; `marks sources and keeps anonymous declarations in tooltips`;
  `preserves parallel arcs and escapes user text`)*

## B firing-semantics.md

- **I-030** `kernel` §Enabledness. Each consume arc needs its weight in
  admitted tokens (color and filter). *(`Petrinet.Enabledness › candidates ›
  requires available tokens`; `weighted consume › is enabled only when the
  place holds at least the weight`; `Petrinet arc filters › colored consume
  selection › is disabled without a matching token`; `counts admitted tokens
  only toward the weight`)*
- **I-031** `kernel` §Enabledness. A read arc needs matching tokens; they join
  the binding and are not consumed. *(`Petrinet.Enabledness › read arcs`, 2
  examples; `Petrinet.Firing › read arcs › peeks the read token instead of
  consuming it`)*
- **I-032** `kernel` §Enabledness. An inhibit arc needs no matching token.
  *(`Petrinet.Enabledness › inhibitor gating`, 2 examples; `Petrinet.Firing ›
  inhibitor gating`, 2 examples)*
- **I-033** `instance` §Enabledness. Guards see the selected tokens, consumed
  then read, without consuming them, and must all hold. *(`Instance guards ›
  guards see the full binding`, 2 examples; `guard composition › requires all
  guards to hold`)*
- **I-034** `kernel` §Enabledness. Candidates enumerate per-arc selections
  first (filters prune each arc's tokens) and then guards filter the
  assembled bindings. Every admissible binding is a candidate, in a
  deterministic order (input arc major, FIFO minor), and a guard-failed head
  does not mask a deeper binding. *(`Petrinet.Enabledness › multi-binding
  enumeration`, 4 examples; `candidates › orders candidates stably by path`;
  `Instance guards › guard branch`, 3 examples; `Instance CEL guards › CEL
  guard routing`, 2 examples)*
- **I-035** `instance` §Enabledness (evaluation errors). A declared mismatch
  is refused at construction and never evaluates. Examples are a CEL guard
  naming a place that does not feed the transition, and invalid CEL. Read
  places are in the guard scope; inhibit-only places are not. *(`Instance CEL
  guards › CEL guard validation`, 5 examples; on real CEL in `petrus-cel`
  `test/KernelSeam.hs`)*
- **I-036** `instance` §Enabledness (evaluation errors). A runtime evaluation
  error on a concrete token is handled this way:
  - a filter error means that token is not admitted;
  - a guard error skips that binding;
  - enablement continues;
  - a diagnostic carries the declaration URI, the token and the error.

  *(`Petrinet.Enabledness › selection › treats a raising filter as not
  admitted, with a diagnostic`; `Petrinet arc filters › filter evaluation
  errors`, 4 examples; `Instance guards › guard evaluation errors`, 3
  examples; `Instance CEL guards › CEL guard evaluation errors`, 2 examples)*
- **I-037** `instance` §Firing pipeline, §Begin/end firing lifecycle.
  `CandidateSelected` precedes the firing lifecycle. Begin firing accounts for
  the inputs, and end firing produces the outputs. *(`Instance runtime › the
  integration path › records the selection before the firing lifecycle`;
  `Instance firing › begin/end firing › consumes at begin and produces at end`;
  `returns movements in lifecycle order`)*
- **I-038** `instance` §Begin/end firing lifecycle. Inputs are accounted at
  begin, so a consumed token cannot be selected again. A stale selection
  appends nothing, and an in-flight occurrence keeps the Instance running.
  *(`Instance firing occurrences › begin`, 9 examples; `Petrinet.Firing › read
  arcs › refuses to begin a binding that consumes its own read token`)*
- **I-039** `instance` §Begin/end firing lifecycle. An impure transition's
  activity request is frozen in the begin batch. The result freezes in its
  own append before a deterministic projection. A failing prepare appends
  nothing. *(`Activity invocation seam › begin freezes the request`, 5
  examples; `record_activity_completion › the result freezes as its own append
  before projection`; `append boundaries`)*
- **I-040** `instance` §Begin/end firing lifecycle. Several occurrences may be
  in flight at once, and each is completed, failed or resumed on its own.
  *(`Resume › resume › rebuilds an in-flight occurrence a driver can
  complete` / `can fail`; `Instance replay properties`, random interleavings
  of begins and ends)*
- **I-041** `instance` §Begin/end firing lifecycle. On terminal failure,
  `ActivityFailed` is recorded first:
  - an opt-in failure projection then ends the firing through ordinary
    effects;
  - otherwise `FiringFailed` halts.

  After a crash between the two, reload resumes projection only and never
  makes another Attempt. *(`Activity invocation seam › fail: exhausted
  execution`, 4 examples; `terminal failure projection`, 6 examples)*
- **I-042** `engine` §Begin/end firing lifecycle. The following are
  Dispatch's:
  - operational retries reuse the frozen identities;
  - heartbeats renew one Attempt's lease;
  - a delayed retry never blocks Inline execution.

  *(`petrus-activity`, `petrus-motus` and `petrus-engine` ledgers;
  `Activity invocation seam › the seam's value objects › ExecutionPolicy`, 6
  examples)*
- **I-043** `instance` §Token production. Output is per arc: handler tokens
  are deposited only where their color and destination match, never merged.
  *(`Instance handlers › per-arc output contracts`; `Petrinet.Firing ›
  weighted consume › deposits one token per consumed token, never merged`;
  `Impetus golden traces › normative fixtures replay`, including
  `per_arc_passthrough` and `heterogeneous_fanout`)*
- **I-044** `kernel` §Scheduling. Transition Selection:
  - has the First, Priority and Round-Robin policies;
  - runs filters, then stable rankers, then one strategy;
  - uses Petrinet candidate order as the final tie-breaker;
  - returns no choice when every candidate is filtered out.

  *(`Selection`, the 8 policy and pipeline examples)*
- **I-045** `kernel` §Scheduling. Policy state advances only through
  committed `CandidateSelected` + `FiringBegun` pairs. Replay folds those
  pairs only. An orphan selection spends its id but does not advance the
  policy, and a duplicate or mismatched pair is refused. *(`Selection › replay
  folds only exact committed selection pairs and spends orphans`; `replay
  threads accumulated policy state through committed pairs`;
  `test_replay_refuses_duplicate_or_mismatched_selection_lifecycle`, 3
  examples; `properties`, 2 examples)*
- **I-046** `engine` §Scheduling. These belong to the Engine:
  - one Engine turn applies at most one normal Action;
  - `DriveOutcome` reports ready, waiting or the next maturation;
  - the host owns waiting.

  *(`petrus-engine` `CoordinatorSpec`: "each drive applies at most one normal
  action", "a future wall clock maturation returns without waiting")*
- **I-047** `instance` §Default behavior. A transition with no handler is
  bound to `passthrough`:
  - each consumed token goes through every output arc that admits it;
  - unadmitted tokens are simply consumed;
  - a transition with no output arcs is a sink;
  - read and inhibit arcs contribute nothing.

  *(`Instance firing › passthrough`, 4 examples; `Instance handlers › typed
  passthrough routing`, 2 examples; `Petrinet.Firing › read arcs › contributes
  nothing to output`)*
- **I-048** `kernel` §Timers. Timers belong to transitions:
  - a source transition cannot carry one;
  - a delay over inhibitor-only inputs is refused;
  - an `until` over inhibitor-only inputs is admitted.

  *(`Timers › timer declarations`, 3 examples)*
- **I-049** `kernel` §Timers. Maturation is per binding. A delay matures at
  the youngest consume- or read-bound entry instant plus Δ, an `until` at its
  instant, and a conjunction when its last timer does. *(`Timers ›
  maturation`, 5 examples; `timed enabledness › matures the binding a delay
  after its token entered`; `anchors the binding on a read-bound token like a
  consumed one`; `ratified scenarios › matures concurrent bindings in anchor
  order`)*
- **I-050** `instance` §Timers. Timer state is derived, never stored. The next
  maturation is derived from the marking and History, and a binding that
  fails its guard never waits on time. *(`Timers › timed enabledness`, 10
  examples)*
- **I-051** `instance` §Timers. "Now" is the clock watermark: monotone, and it
  advances only at appends. An earlier instant clamps to it, and a wakeup
  appends `TimerMatured`. An early wakeup is suppressed, and a stale one is
  harmless. Replay re-derives every maturation without reading a clock.
  *(`Timers › record instants`, 6 examples; `wakeup`, 5 examples; `watermark
  advance`, 3 examples; `Resume › resume › restores a pending delay and wakes
  it`)*
- **I-052** `instance` §Timers. There is no urgency: maturation enables but
  never fires. *(`Timers › wakeup › enables on maturation but never fires`)*
- **I-053** `instance` §Timers. A delay does not restart per enablement
  epoch. A refresh transition restarts it by minting a new entry instant.
  *(`Timers › ratified scenarios › keeps an until indifferent to enablement
  churn`; `restarts the delay through a refresh transition minting a new
  entry`)*
- **I-054** `instance` §Deterministic replay. The same History gives the same
  state, and replay never reruns a handler or an Activity. *(`kernel
  properties › the Instance marking is always the replay of its History`;
  `resume rebuilds the marking, watermark, occurrence counter, and
  candidates`; `Instance handlers › handler tokens › replays the
  handler-supplied tokens from History`; `Ingress › handled source › records
  the handler result and never reruns it`; `Activity invocation seam › the
  kill windows, over the durable record › window two: resume is
  projection-pending and the activity is never re-invoked`)*
- **I-055** `interop` §Deterministic replay. The kernel's behavior on 240
  generated nets matches the reference's:
  - candidates;
  - firings;
  - History;
  - status.

  *(`Petrus.Impetus.Instance differential corpus`; `Impetus golden traces`)*
- **I-056** `instance` §Termination. An Instance is quiescent when three things
  hold:
  - no non-source candidate is enabled;
  - no occurrence is in flight;
  - no binding has a future maturation.

  *(`Instance firing occurrences › begin › keeps the instance running while an
  occurrence is in flight`; `fail › no longer blocks quiescence once failed`;
  `Timers › timed status`, 2 examples)*
- **I-057** `instance` §Termination. The status is RUNNING if not quiescent.
  Otherwise it is:
  - COMPLETED if the condition holds;
  - AWAITING if a registration is armed;
  - STUCK if a condition is declared;
  - TERMINATED otherwise.

  *(`Instance completion › status resolution`, 6 examples; `Delivery
  registrations › awaiting status`, 7 examples; `Instance awaiting
  termination`, 3 examples)*
- **I-058** `instance` §Termination. The status is re-evaluated on every
  append, including a registration close with no net activity. *(`Delivery
  registrations › awaiting status › flips status on seal with zero net
  activity`; `collapses to terminated when sealed with no condition`)*

## C event-history.md

- **I-059** `instance` §One unified history per net instance. Every kind of
  firing appears in the Instance's one History: passthrough, handled,
  delivered and Activity-backed. *(`Instance firing occurrences › step through
  the seam`; `deliver through the seam`; `Activity invocation seam › an inline
  driver drives the whole seam (Engine emulated) › an activity firing records
  the canonical lifecycle`)*
- **I-060** `instance` §The canonical log is uncompacted. History is append
  only, and the marking is a projection rebuilt from it. *(`History ›
  replayMarking`, 6 examples; `HistoryStore contract › round trip › append and
  extend accumulate, and a reload continues`)*
- **I-061** `instance` §The minimal record model. Token movements are explicit
  records, and the marking derives from them. `TokensRead` is replay-inert,
  and a diverging consume record fails loud. *(`History › replayMarking › only
  movement records affect the marking`; `TokensRead is a movement-category
  record, yet replay-inert`; `a diverging consume record fails loud`)*
- **I-062** `instance` §The minimal record model. A begin batch is
  `CandidateSelected`, `FiringBegun`, consumes, reads, then
  `ActivityRequested`. Any other order is replay divergence. *(`Activity
  invocation seam › begin batch order parity`, 2 examples; `begin freezes the
  request › the begin batch carries the activity request after the reads`;
  `Petrinet.Firing through the Instance › read arcs › begin records the read
  selection in the begin batch`)*
- **I-063** `codec` §The minimal record model, §Lifecycle scopes. Records
  decode as follows:
  - every category round-trips;
  - schema 5 is the only spelling;
  - schemas 2 and 3, and unversioned discriminators, are refused before
    interpretation;
  - unknown records and field drift are refused.

  *(`History codec › record codec`, 20 examples; `durable line spelling`, 2
  examples)*
- **I-064** `instance` §The minimal record model. Opening and closing a
  delivery registration are recorded facts, inert for the marking on replay.
  *(`Delivery registrations › registration lifecycle`, 6 examples;
  `handler-driven lifecycle › commits the effects after the movements as their
  own records`; `keeps registration records inert during replay`)*
- **I-065** `instance` §The minimal record model. An external event is
  recorded when it arrives, before and independent of consumption. *(`Ingress
  › delivery › records the event, then the firing lifecycle`; `handled source
  › records the event before a raising handler propagates`; `delivery identity
  enforcement › keeps an identity accepted when the source projection fails`)*
- **I-066** `instance` §Lifecycle scopes. A scope is `(name, generation)`. A
  reset closes, cleans up and opens the next generation in one record.
  *(`Lifecycle scopes › resets in one record that closes, cleans up, and opens
  the next generation`)*
- **I-067** `instance` §Lifecycle scopes. A close lists exactly the queue
  entries it discards and the occurrences it cancels. Replay refuses an
  omitted, additional or reclassified identity, and equal-valued tokens stay
  distinct. *(`Lifecycle scopes`: `discards duplicate-valued entries by
  identity on close, and replay preserves the other scope`; `refuses at replay
  a scope close that omits queued cleanup`; `refuses at resume a scope close
  that omits an in-flight occurrence`; `… that reclassifies an already ended
  occurrence`)*
- **I-068** `instance` §Lifecycle scopes. A close restores nothing: consumed
  inputs stay consumed. *(`Lifecycle scopes › cancels an activity on close
  without restoring its consumed input`)*
- **I-069** `instance` §Lifecycle scopes. Scope provenance flows from scoped
  tokens into the occurrence, its produced entries and its Activity request.
  *(`Lifecycle scopes › records the exact consumed identity and scope on the
  activity outbox at begin`; `refuses at resume inconsistent same-occurrence
  scope provenance`; `petrus-engine` `EngineSpec`: "sensor delivery preserves
  exact scope provenance")*
- **I-070** `engine` §Lifecycle scopes. A close or reset commits before any
  cancellation reaches Dispatch. Dispatch repairs it from History after a
  restart. A provider that cannot fence is refused before the close.
  *(`petrus-engine` `EngineSpec`: "close commits before retiring pending
  dispatch and late terminal is quarantined", "scope close append failure
  never notifies dispatch", "restart repairs a committed cancellation
  instruction idempotently", "unsupported dispatch is refused before canonical
  close")*
- **I-071** `instance` §Lifecycle scopes. A terminal accepted before the close
  must project before the generation closes. A close that cancels it is
  refused. *(`Lifecycle scopes › accepts a completion before a same-instant
  close, then cleans its output`; `refuses at resume a scope close that
  cancels an accepted terminal awaiting projection`; `refuses at resume a
  normal terminal boundary after lifecycle cancellation`)*
- **I-072** `instance` §Lifecycle scopes. The dispositions are:
  - a terminal after the close is `ActivityTerminalQuarantined`;
  - a delivery to a closed generation is `ScopedDeliveryDropped`;
  - a delivery whose generation History cannot prove is
    `ScopedDeliveryQuarantined`, never retargeted;
  - an exact duplicate is acknowledged, and a conflict fails.

  *(`Lifecycle scopes › quarantines a completion after a same-instant close,
  acknowledges redelivery, refuses conflict`; `dispositions closed and
  uncertain scoped deliveries canonically and idempotently`; `quarantines an
  exact future generation without losing its target identity`)*
- **I-073** `codec` §Lifecycle scopes. Movement records always carry `entries`
  and `scope`; nonempty entries without a scope are invalid. *(`History codec ›
  record codec › schema 5 refuses partial or invalid scope provenance`;
  `spells the ratified wire shape`)*
- **I-074** `instance` §Lifecycle scopes. Queue identities are never reused
  across a restart and are allocated identically live and on replay.
  *(`Lifecycle scopes › never reuses a spent queue identity after restart`;
  `allocates scoped identities identically live and after replay of unscoped
  movements`; `rebuilds the scope projection and quarantine deterministically
  on resume`)*
- **I-075** `instance` §Deterministic records vs activity records. The
  requested input and the terminal result are in the canonical log. An
  identical terminal redelivery is acknowledged, before or after the firing
  ends and across a resume; a conflicting one is refused. *(`Activity
  invocation seam › record_activity_completion`, 6 examples; `ended-occurrence
  acknowledgement`, 6 examples; `K6 across resume`, 3 examples; `terminal
  activity replay divergence`, 3 examples)*
- **I-076** `instance` §Deterministic records vs activity records. A durable
  prefix that ends at `ActivityFailed` reloads into projection only.
  *(`Activity invocation seam › activity replay guards › an activity failure
  without its firing boundary is projection-pending`; `terminal failure
  projection › legacy fail-and-halt recovers after the failure freeze`)*
- **I-077** `codec` §Activities, not worker mechanics. `ActivityRequested`
  carries no Worker capability or queue routing, and an extra field is
  refused. *(`History codec › record codec › field drift fails as the record
  type's own rejection`; `test_schema_5_activity_request_refuses_noncanonical_policy_shapes`,
  4 examples)*
- **I-078** `instance` §Activities, not worker mechanics. A pure handler
  writes no activity records, but its firing is recorded. *(`Instance firing
  occurrences › complete › records no activity records for a passthrough
  firing`; `records a user-handled firing as a pure projection, movements
  only`; `Activity invocation seam › purity is the binding's classification ›
  a plain callable bound to a symbol is a pure projection`)*
- **I-079** `interop` §The minimal record model. The History bytes match the
  reference's:
  - the golden traces regenerate byte for byte;
  - the reference's own `decode_record` and `encode_record` reread every
    record Haskell writes, byte for byte.

  *(`Impetus golden traces › regeneration`; `live round trip through the
  pinned reference`)*

## D handler-contract.md

- **I-080** `instance` §Symbols and implementation mappings. Before an
  Instance runs, every declared handler, guard, filter and completion symbol
  must have an implementation, and every inline CEL must compile. *(`Instance
  handlers › handler tokens › fails at construction on a missing handler
  implementation`; `Instance guards › guard branch › fails at construction on
  a missing guard implementation`; `Petrinet.Firing through the Instance ›
  named filter selection › a missing filter implementation fails at
  construction`; `CEL filter selection › invalid CEL fails at construction and
  never evaluates`; `Instance completion › named completion › fails at
  construction on a missing implementation`)*
- **I-081** `instance` §Symbols and implementation mappings. Declarations bind
  by URI or by symbol:
  - same-named declarations bind independently by exact URI;
  - a bare symbol shares one implementation;
  - supplying both for one declaration is ambiguous;
  - an anonymous declaration needs its exact URI;
  - an inline CEL filter refuses an exact override.

  *(`Instance handlers › handler declaration bindings`, 4 examples; `Instance
  guards › guard declaration bindings`, 4 examples; `Petrinet arc filters ›
  named filter selection`, 3 examples; `Petrinet.Firing through the Instance ›
  named filter selection › an exact and a bare filter binding is ambiguous`;
  `CEL filter selection › an exact override of an inline CEL filter is
  refused`)*
- **I-082** `instance` §Symbols and implementation mappings. Several guards
  compose as a conjunction. *(`Instance guards › guard composition`; `Instance
  CEL guards › mixed guards`, 3 examples)*
- **I-083** `instance` §The handler contract. A handler sees the full binding,
  consumed and read tokens, and supplies the output tokens. *(`Instance
  handlers › a handler sees the full binding › correlates consumed and read
  tokens`; `handler tokens › deposits the handler-supplied token, not the
  consumed one`)*
- **I-084** `instance` §The handler contract. A typed transformation or
  predicate matches each parameter to one weight-one consume or read arc by
  nominal color. The result must match every weight-one output arc. Refused:
  - source transitions;
  - weighted inputs;
  - ambiguous same-color inputs;
  - unmatched inputs;
  - output mismatches.

  *(`typed bindings`, 8 examples; `Activity invocation seam ›
  DerivedActivityHandler`, 12 examples)*
- **I-085** `kernel` §The handler contract. Color matching is nominal. *(`Petrinet.Schema
  › Net › spells a color as a plain nominal name`; `Petrinet.Enabledness ›
  selection › never reaches the filter on a color mismatch`)*
- **I-086** `instance` §Petrinet, activity, binding, and execution boundaries.
  An impure firing goes through prepare, then `ActivityRequested` in the
  begin batch, then execution, then `ActivityCompleted`, then projection. A
  plain callable is a pure projection with no activity records, and a source
  transition cannot bind an `ActivityHandler`. *(`Activity invocation seam ›
  append boundaries`; `purity is the binding's classification`, 2 examples;
  `an inline driver drives the whole seam (Engine emulated)`, 4 examples)*
- **I-087** `instance` §Petrinet, activity, binding, and execution boundaries.
  The default execution policy is one Attempt. Durations above 1 000 000 000
  seconds fail before dispatch. *(`Activity invocation seam › the seam's value
  objects › ExecutionPolicy › the default is maximally conservative`;
  `provider-neutral durations refuse values over one billion seconds`)*
- **I-088** `instance` §Petrinet, activity, binding, and execution boundaries.
  Failure projection is pure and replayable: a reload may rerun it but never
  reruns the Activity. *(`Activity invocation seam › terminal failure
  projection › a failure projection crash reloads the frozen failure without
  another attempt`; `complete projects the frozen result › a projection bug is
  fixed in code and retried from the same frozen result`)*

## E net-definition-v3.md

- **I-089** `codec` §Envelope. `format` and `version` must be exact; an extra
  member is refused. *(`Petrus.Impetus.NetDefinition ›
  test_noncanonical_or_invalid_documents_are_refused › a boolean version`; `a
  foreign format`; `an extra member`)*
- **I-090** `interop` §Canonical laws. The four laws hold:

  ```text
  P(C(P(N))) == P(N)
  P(C(D)) == D
  R(S(D)) == D
  S(R(S(D))) == S(D)
  ```

  *(`Petrus.Impetus.NetDefinition › projects, compiles, and round-trips JSON
  as fixed points`; `Net definition and document round-trip properties`, 4
  examples; `Petrus.Impetus.NetDefinition differential corpus`, 1763 cases;
  `hand-built Net definitions and documents (differential corpus)`; `live
  round trip through the pinned reference`)*
- **I-091** `interop` §Canonical laws. The writer's bytes equal the
  reference's: two-space indentation, deterministic UTF-8, one final newline.
  *(`spec/ fixtures › Net definitions`, 4 fixtures; `Net definitions embedded
  in golden traces`; the differential corpus)*
- **I-092** `codec` §Canonical laws. Parsing refuses:
  - malformed UTF-8;
  - duplicate members;
  - non-finite numbers;
  - lone surrogates.

  *(`Petrus.Impetus.NetDefinition ›
  test_strict_json_refuses_duplicate_nonfinite_utf8_and_surrogate`, 4
  examples; `refuses lone surrogates when projecting a net or serializing a
  model`)*
- **I-093** `codec` §Canonical laws, §Flat definition. Parsing also refuses:
  - unknown fields;
  - coercible wrong types;
  - noncanonical order, positions and derived URIs;
  - an inherited `null` arc color;
  - every runtime `Net` violation.

  *(`Petrus.Impetus.NetDefinition ›
  test_noncanonical_or_invalid_documents_are_refused`, 10 examples; the
  differential corpus's mutation and fuzz cases)*
- **I-094** `codec` §Interoperable integers. Every number must use integer
  spelling within ±(2^53 − 1), checked before shape. Every schema integer and
  runtime projection keeps that bound. *(`Petrus.Impetus.NetDefinition ›
  test_every_json_number_token_is_interoperably_admitted_before_shape`, 4
  examples;
  `test_every_schema_owned_integer_refuses_values_outside_interoperable_range`,
  5 examples;
  `test_runtime_projection_refuses_integers_outside_interoperable_range`, 2
  examples)*
- **I-095** `codec` §Canonical path ordering. Paths sort by Unicode scalar
  value, not UTF-16 code unit. *(`Petrus.Impetus.NetDefinition › keeps the
  cross-language integer and scalar-order fixture an exact fixed point`;
  `test_cross_language_negative_fixtures_are_refused`, 2 examples)*
- **I-096** `interop` §Canonical path ordering. The generated JSON Schema
  matches `NetDefinitionV3.model_json_schema()`. *(`Petrus.Impetus.NetDefinition
  › publishes a strict, versioned JSON Schema`; `Petrus.Impetus JSON Schema
  differential corpus`)*
- **I-097** `codec` §Flat definition. Parallel arcs stay distinct by position.
  Their `#$N` and `#filter:$N` identities are rederived, not serialized.
  *(`Petrus.Impetus.NetDefinition › round-trips parallel arcs without wire
  identity and rederives the same URIs`)*
- **I-098** `codec` §Delta from predecessor v2. A document without the exact
  v3 envelope is refused; there is no v2 fallback. *(the differential corpus's
  `delete format` and `replace format` mutations; `a foreign format`)*

## F net-document-v1.md

- **I-099** `codec` §1a Envelope. `format`, `version` and `definition` are
  required. An absent `view` is omitted, never `null`, and a definition-only
  document is valid. *(`Petrus.Impetus.NetDocument ›
  test_malformed_or_confused_documents_are_refused`, 11 examples; `omits the
  view of a definition-only document, and a view never changes identity`)*
- **I-100** `codec` §1b Net identity. The identity is the SHA-256 of the
  canonical definition bytes; Layout and Timeline do not change it.
  *(`Petrus.Impetus.NetDocument › omits the view of a definition-only document,
  and a view never changes identity`; `Net definition and document round-trip
  properties › round-trips documents and never lets the view change the
  identity`)*
- **I-101** `codec` §1c Layout. Each `node` is a path of the definition, `x`
  and `y` are finite numbers, and nodes are unique and sorted. A partial
  Layout is valid. *(`Petrus.Impetus.NetDocument › admits a partial,
  fractional view and publishes a strict JSON Schema`;
  `test_view_coordinates_must_be_finite_interoperable_json_numbers`, 6
  examples; `revalidates foreign nodes and non-finite coordinates on direct
  serialization and projection`)*
- **I-102** `codec` §1d Timeline. The Timeline is strict:
  - ids are dense and equal their index;
  - there is one root;
  - parents are smaller;
  - the head exists;
  - entries are nonempty;
  - metadata is an object.

  *(`Petrus.Impetus.NetDocument lineage › test_lineage_shape_is_strict`, 8
  examples)*
- **I-103** `codec` §1d Timeline. Observed, manual and simulated entries share
  one shape. *(`Petrus.Impetus.NetDocument lineage › gives observed, manual,
  and simulated entries the same core shape`; `reads the fixture as one
  uniform, marking-first navigation sequence`)*
- **I-104** `codec` §1d Timeline. Each marking is sparse:
  - unique, sorted places from the definition, each nonempty;
  - colors that match the place;
  - strict JSON data within the safe-integer range.

  *(`Petrus.Impetus.NetDocument lineage ›
  test_every_entry_contains_one_complete_valid_sparse_marking`, 5 examples;
  `test_direct_token_data_must_already_be_strict_json`, 3 examples)*
- **I-105** `codec` §1d Timeline. Metadata is strict JSON and never decides a
  marking or an ancestry. *(`Petrus.Impetus.NetDocument lineage › keeps
  metadata non-authoritative strict JSON`; `round-trips the fixture exactly
  without hidden evidence or replay state`)*
- **I-106** `instance` §1e Runtime materialization. A live run materializes as
  one document of `observed` entries with complete markings. *(`petrus-observation`
  `ObservationSpec`: "produces the exact observed Net document fixture, one
  complete marking per record"; its `LiveSpec`)*
- **I-107** `interop` §1f Canonical laws. The four laws hold:

  ```text
  R(S(P(N, V))) == P(N, V)
  R(S(D)) == D
  S(R(S(D))) == S(D)
  identity(P(N, absent)) == identity(P(N, V))
  ```

  *(`Petrus.Impetus.NetDocument › projects, parses, serializes, and identifies
  as fixed points`; `Net definition and document round-trip properties`; `spec/
  fixtures › Net documents`, 7 fixtures; the differential corpus; `live round
  trip through the pinned reference`)*
- **I-108** `codec` §1f Canonical laws. Parsing refuses:
  - malformed UTF-8;
  - duplicate members;
  - non-finite numbers;
  - lone surrogates.

  *(`Petrus.Impetus.NetDocument ›
  test_strict_json_refuses_duplicate_nonfinite_utf8_and_surrogate`, 4
  examples; `refuses the negative interoperability fixture`)*
- **I-109** `interop` §1f Canonical laws. The generated JSON Schema matches
  `NetDocumentV1.model_json_schema()`. *(`Petrus.Impetus JSON Schema
  differential corpus`)*

## Not applicable at the pin

These statements describe behavior the pinned reference does not ship, so
neither implementation has a check:

- place roles (`net-schema.md` §Places): `net-definition-v3.md` §Explicit
  deferrals says the runtime `Place` does not implement them yet;
- the `unpack` stdlib handler (`firing-semantics.md` §Default behavior,
  `handler-contract.md`): decided, but not in `petrus.impetus` at the pin;
- correlated inhibitors (`net-definition-v3.md` §Explicit deferrals);
- items marked DEFERRED or OPEN: source maps, the token-type ledger
  boundary, and exact payload fields per category.

The reusable-component layering (`handler-contract.md` §Reusable components)
and the library-not-framework rule are design guidance, not testable
obligations.

## Gaps

None. Two obligations had no direct check before this ledger. Both now have
examples beyond upstream, with the reference's messages:

- I-005: the typed-place initial marking, which upstream checks only through
  Engine load;
- I-012: the transition → transition arc.
