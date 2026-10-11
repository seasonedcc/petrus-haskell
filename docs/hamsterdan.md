# Hamsterdan port plan

This is the plan of record for porting
[Hamsterdan](https://github.com/henriquebastos/hamsterdan) to Haskell. It
describes what the pinned upstream does end to end, every Petrus API it
depends on, its external dependencies, its test suites, what an end-to-end
comparison against a real GitHub App requires, and how the port decomposes into
packages that can be sequenced against the Petrus ports.

Unless noted, paths are relative to `upstream/hamsterdan/` at the pin in
[UPSTREAM.md](../UPSTREAM.md) (`5d38246`). Petrus paths are relative to
`upstream/petrus/`.

## 0. Decisions and headline facts

1. **The port target is V5 in `src/hamsterdan`.** Non-sharded V5 is the only
   runtime topology (decision record
   `docs/project/decisions/records/2026-08-23T2152Z-v5-is-the-only-runtime-and-retired-topology-state-fails-closed.md`).
   The previous integrated net (`readiness/net/topology.py`) was deleted in
   `1f00cfd` (2026-08-23). "V1–V4" and "sharded V5" were design explorations
   (ES-006/ES-007) and never shipped. There is no V6 net; `pr63-v6-hero` under
   `tools/demo-video` is a demo slug.
2. **The pin is production.** Production runs release `1eef74a` with Petrus
   `913acb0` (README, `docs/project/briefing.md`). `git diff 1eef74a 5d38246 -- src`
   is empty: the pinned source *is* the production source. Only tests, scripts,
   docs, and the Petrus pin differ.
3. **No Petrus reconciliation is needed.** Petrus `89baf78` (Hamsterdan's pin),
   `913acb0` (production's pin), and `3f85fc2` (our pin) run identical code for
   everything Hamsterdan touches (§2.3).
4. **`src/hamsterdan2` is not a port target yet.** It is the non-selectable
   CV21 rebuild of the outer system (webhook inbox, intake, workflow bridge).
   It has no entry point, no effects, no agents, and no deployment. We track it
   as design reference only (§1.11).
5. **Byte-level interop has two traps beyond Petrus History.**
   - The dashboard stores Python `repr()` dict literals inside History tokens.
     It also derives an operation identity from `repr(sorted(items))` and
     parses entries back with `ast.literal_eval` (§1.3.6).
   - Many digests hash CPython `json.dumps(sort_keys=True, separators=(",",":"))`
     output with the default `ensure_ascii=True`. That is the `petrus-json`
     encoder.
6. **Real-provider acceptance is manual upstream.** The pytest marker
   `real_provider_acceptance` exists but marks zero tests at the pin. Real
   GitHub evidence comes from operator-run proofs (PR56/57/61/80/83/84/85). We
   have to build the side-by-side comparison ourselves (§5).

## 1. What Hamsterdan does end to end

Hamsterdan is a GitHub App that answers one question on every watched pull
request: *is this PR ready to merge?* It never merges. It reviews the PR with
an AI agent, watches the GitHub Actions run, re-runs a failing run once, sends
a coding agent to repair it once, answers `@<slug>` comments, keeps one
summary comment current, nudges idle PRs, and posts one readiness advisory per
generation when every gate is green (`docs/product/what-hamsterdan-is.md`).

### 1.1 Architecture and one reconciliation

```text
                      host                       (composition root, custody)
                       |
        +--------------+--------------+
        |              |              |
   github_app        agents    readiness/net_v5  (siblings, never import each other)
        |              |              |
        +--------------+--------------+
                       |
                   contracts                     (neutral pydantic models)
```

These import rules are enforced by `tests/test_architecture.py`. One
reconciliation runs as follows:

```text
signed webhook  ──►  POST /github/webhooks  ──►  webhooks.sqlite3 inbox (durable, 202)
startup / 60 s sweep ─┐                              │
                      ▼                              ▼
             HostService.pump (every 0.25 s) ─► RunnableIndex wake ─► _activate_instance
                      │
                      ▼
       PrReadinessV5Application.process_observation / reconcile
          - re-read provider truth (REST + GraphQL)
          - freeze an ingress manifest + authority grant (one SQLite transaction)
                      │
                      ▼
       V5Runtime: Engine.deliver(door, Token) ; Engine.advance (forced fold)
                      │
                      ▼
       net_v5 folds (pure)  ──►  gate Activities (typed Motus requests)
                      │
                      ▼
       fence on CurrentClaim ─► lookup-first ─► GitHub effect / agent run / Git publish
                      │
                      ▼
       Activity result ($variant) ─► fold ─► settle timers ─► ack custody rows
```

Each PR has its own Engine, its own History (`history.jsonl`), and its own
instance key `github:{installation_id}:{repository_id}:pr:{n}`.

### 1.2 Inputs: GitHub webhooks

**Route.** `POST /github/webhooks` (`src/hamsterdan/host/api.py:38-50`).
- The body is streamed with a 1,048,576-byte cap; over the cap gives 400.
- `WebhookCustody.receive(headers, body)` runs in a worker thread
  (`src/hamsterdan/github_app/webhooks.py:116-204`).
- **Success** is 202 with
  `{"custody":"durable","delivery_id":<uuid>,"disposition":"accepted"|"accepted_terminal"|"duplicate"}`.
- **Rejection** is 400 with `{"detail": <reason>}`.
- **The receipt shape is a wire contract.** The Amp relay
  (`.amp/plugins/github-webhook-relay.ts`) accepts only exactly these three
  keys, a matching `delivery_id`, and a receipt of at most 512 bytes; anything
  else makes it retry.

**Header and body checks, in order:**
1. Header names are lowercased. A duplicate `content-length`, `content-type`,
   `transfer-encoding`, `x-hub-signature-256`, `x-github-delivery` or
   `x-github-event` is rejected, and so is any `transfer-encoding`.
2. `content-length` is required, must be ASCII decimal, and must equal the body
   length (at most 1 MiB).
3. `content-type` must be exactly `application/json`. Form-encoded deliveries
   are rejected.
4. `x-hub-signature-256` must match `sha256=[0-9a-f]{64}`. The delivery, event
   and content-type headers are each at most 256 characters.
5. `X-GitHub-Delivery` must parse as a UUID and is canonicalized with
   `str(uuid.UUID(...))`.
6. The event must be one of `installation`, `installation_repositories`,
   `pull_request`, `issues`, `issue_comment`, `pull_request_review`,
   `pull_request_review_comment`, `pull_request_review_thread`, `workflow_run`,
   `check_run`, `check_suite`, `ping` (`webhooks.py:26-41`).
7. **Signature:** `githubkit.webhooks.verify` computes HMAC-SHA256 over the raw
   body with the webhook secret, compared with `hmac.compare_digest`.
   Verification happens before parsing and before persistence.
8. **Parse into an `Observation`** (`webhooks.py:49-66, 206-247`). Fields:
   `action`, `installation.id`, `installation.account.id`, `repository.id`,
   `repository.full_name`, and a PR number. The PR number comes from:
   - `pull_request.number` for PR events;
   - `issue.number` for `issue_comment`, only when `issue.pull_request` exists;
   - `<event>.pull_requests[0].number` for `workflow_run`, `check_run` and
     `check_suite`;
   - nowhere for `issues`, which therefore carry no PR.

   Comment fields (id, body ≤ 16,384 UTF-8 bytes, user id/login/type,
   `author_association`) are kept only for `issue_comment`. Installation events
   carry their repository lists.

**Durable inbox.** `<state>/webhooks.sqlite3` in WAL mode
(`webhooks.py:148-160`):

```sql
inbox(delivery_id TEXT PRIMARY KEY, event TEXT NOT NULL, observation TEXT NOT NULL,
      status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, reason TEXT,
      error_class TEXT, next_attempt_at REAL NOT NULL DEFAULT 0)
```

- `observation` is the observation dataclass serialized as compact sorted JSON.
  The raw payload is never stored.
- **Deduplication** is the primary key on `delivery_id`; a repeat gives
  disposition `duplicate`.
- **Installation events** (`installation`, `installation_repositories`) update
  the route registry in the same transaction and become `terminal`
  (`accepted_terminal`).
- **Retry:** backoff `min(2**(attempts-1), 300)` seconds; after 20 attempts the
  row is `failed` (`webhooks.py:349-368`).
- **Rows are processed strictly in per-PR order** (`ORDER BY rowid`, filtered by
  `json_extract`).

**Admission** (`service.py:420-441`, `webhooks.py:76-113`). These rows are
acknowledged terminally without reaching a workflow:
- `ping`, `installation` and `installation_repositories`;
- rows with an inactive route;
- rows with no PR number;
- `issue_comment` deliveries that are not addressed to the bot.

A comment is admitted only when all of these hold:
- the action is `created`;
- the actor is a `User` and not `<slug>[bot]`;
- `author_association` is OWNER, MEMBER or COLLABORATOR;
- the case-folded body equals `@<slug>` or starts with `@<slug> `.

PR authors must be in `HAMSTERDAN_WATCH_AUTHORS` (empty means everyone) unless
an admitted mention opts the PR in (`service.py:~660-690`).

**Events are wake hints, not data.** Apart from three edges, the payload body
is ignored and every admitted delivery triggers a full re-read of GitHub truth
(`host/v5/ingress.py:174-258`). The three edges are:
- `pull_request` with action `closed`;
- `converted_to_draft` / `ready_for_review`;
- an admitted `issue_comment`.

Startup and the periodic sweep (every 60 s) run the same reconciliation, so a
missed delivery cannot strand a PR.

### 1.3 The readiness model (net V5)

The live net is `build_net_v5()` in `src/hamsterdan/readiness/net_v5/topology.py`.
It is built with the Petrus DSL (`NetSpec("pr_v5")`) from a startup module and
nine loops, in the order `life, ci, esc, review, mutation, conversation,
dashboard, reminders, readiness`.

**Measured shape** (built in a scratch venv against Petrus `89baf78`):

| Item | Count |
| --- | --- |
| Places | 111 |
| Transitions | 141 |
| `petri_handler`s | 122 |
| Guards | 0 |
| Read arcs | 0 |
| Input arcs | 225 |
| Inhibitor arcs | 46 |
| Output arcs | 318 |
| Distinct place colors | 96 (plus 10 nested models) |
| Gate (Activity) transitions | 8 |
| Ingress doors (no-input transitions) | 11 |

**Structural fingerprint.** `project_net_definition(build_net_v5().net)`
serialized with `serialize_net_definition` is a 167,801-byte Net definition v3
with SHA-256 `7e7d437b90c8f623f2180ab011e86ac5f4ba0fc3a8ef9d4853671970a39f9744`.
The Haskell net builder must project to the same bytes. This is the first
conformance check for the readiness package (§6).

**Discipline** (`topology.py` docstring):
- One concern is one loop: a memory "baton" place plus mailbox places.
- Cross-loop influence is mailed facts only.
- Every decision is a pure fold on token data.
- Gates are the only effects.
- The 11 ingress doors are the only no-input transitions:
  - mailbox doors `on_head`, `on_draft`, `on_ready`, `on_close`, `on_comment`,
    `on_human`, `on_runs`;
  - wake doors `on_review_round_wake`, `on_timer`, `on_timer_command_applied`,
    `on_announce_wake`.
- Engine identified delivery is the only deduplication.

**CEL** appears only on the input-only `ready.facts` migration lane
(`readiness.py:532-600`, 17 filter declarations such as `kind == "checks"` and
`kind == "fault" && (!has(body.status) || body.status == "faulted")`). Current
code never produces into that lane, but resuming old Histories requires it, so
`petrus-cel` is on the critical path for exact parity.

#### 1.3.1 Startup precondition

`startup.pending` (seeded) inhibits every gate except `dash_gate`
(`startup.py:31-36`). The first `DashLanded` emits `SummaryPublished`, and
`startup.finish` consumes both tokens, so **the initial summary comment lands
before any other effect**. This was introduced in `2ce1372` (2026-09-04); older
Histories have no pending token.

#### 1.3.2 The nine loops

| Loop | Module | Baton | Behavior |
| --- | --- | --- | --- |
| Lifecycle | `life.py` | `LifeState` | Admits heads, drafts, readies, closes, comments, human facts, runs. `incarnation` is the glossary's *generation*: it bumps on a new or superseded head and on draft→ready. Relation is `new` / `superseded` / `confirmed` (our own push) / `resumed` / `refreshed` (same head, other authority changed). Close fans `CloseFact` out to 7 loops (not conversation). |
| CI | `ci.py` | `CiState` | Exact-head runs only. `(run_id, attempt)` is freshness; rank strictly advances (queued 0, in_progress 1, success/failure 2). A failure mails `ChecksFailure` with a fingerprint to escalation. |
| Escalation | `esc.py` | `Ladder` | Budget per `"{lineage}:{fingerprint}"`: **rerun once, then repair once (coding agent), then hand to a human.** Moved outcomes refund budget; faults are retained for recovery. |
| Review | `review.py` | `ReviewMemory` | One agent round per generation, op `review:{subject}:{head}:i{inc}`. Re-review after confirmed and resumed generations; none on `refreshed`. Findings are published, dismissible by conversation, and counted as blocking. |
| Mutation | `mutation.py` | `MutState` | One push at a time, op key `push:{rid}:{head}:i{inc}`. Kinds are `repair`, `change`, `update_base`, `resolve_conflict`, all executed by the coding agent plus the host's CAS push. A fault blocks further mutations until recovery. |
| Conversation | `conversation.py` | `ConvMemory` | Never ends. Grades intents as pure (`reply`, `status`), note (`acknowledge`, `dismiss`, `defer`, `snooze`, `resume`, `reassign`, `recover_publication`) or committing (`change`, `update_base`, `resolve_conflict`). Each intent gets one reply, op `reply:{comment_id}`. Fixed reply strings are at `conversation.py:75-95`. |
| Dashboard | `dashboard.py`, `board.py` | `DashMemory` | Accumulates facts as entries, digests them, and upserts the summary comment (`dash:{digest}`). Deferred while the PR is a draft. |
| Reminders | `reminders.py` | `RemState` | Serialized net↔host timer protocol (ArmReminder/CancelReminder, acknowledged by `TimerCommandApplied`). Nudge every `delay_s` (default 259,200 s = 3 days) per running generation, uncapped. Draft pauses, close cancels, snooze suppresses. Approval does *not* stop reminders; RS-027 tracks that as an open product question. |
| Readiness | `readiness.py` | `Snapshot` | Typed fact mailboxes, ordered by inhibitor arcs. `authorize` is inhibited until every mailbox is drained. Mints `AnnounceReq` with op `ready:{head}:i{inc}`; announcement is **once per generation** on the not-ready→ready edge. |

#### 1.3.3 Readiness rule

`_ready` in `readiness.py:66-79` requires all of:
- `phase == "running"`
- `checks == "success"`
- `review == "clear"`
- `findings_blocking == 0`
- `approval`
- `not changes_requested`
- `unresolved == 0`
- `mergeable`
- `not strict_base or base_current`
- no pending mutation
- no open faults

`_announce_viable` (`readiness.py:82-89`) also requires that this incarnation
was not announced yet, and that nothing is announcing, blocked or closing.

The host derives these inputs from GitHub in `host/v5/ingress.py`:
approval, changes requested and unresolved threads from reviews and
reviewThreads; `strict_base`, required checks and required approvals from
rulesets or branch protection; `base_current` from compare.

#### 1.3.4 Gates (typed Motus Activities)

| Activity | Transition | Request | Result variants | Dispatch |
| --- | --- | --- | --- | --- |
| `review_agent` | `review.agent` | `RoundOpen` | `AgentReview`, `RoundDeferred`, `RoundMoved`, `RoundUnable` | inline |
| `publish_gate` | `review.publish` | `Publishable` | `ReviewLanded`, `PublicationDeferred`, `ReviewMoved`, `ReviewBlocked`, `ReviewFault` | inline |
| `rerun_gate` | `esc.rerun_gate` | `RerunReq` | `RerunLanded`, `RerunMoved`, `RerunFault` | inline |
| `git_gate` | `mut.git_gate` | `MutWork` | `Pushed`, `MovedM`, `FaultM`, `DeclinedM` | inline |
| `reminder_gate` | `rem.gate` | `RemReq` | `RemLanded`, `RemBlocked`, `RemFault` | inline |
| `reply_gate` | `conv.reply` | `ReplyReq` | `Replied`, `ReplyBlocked`, `ReplyFault` | durable |
| `dash_gate` | `dash.publish` | `DashReq` | `DashLanded`, `DashDeferred`, `DashBlocked`, `DashFault` | durable |
| `announce_gate` | `ready.gate` | `AnnounceReq` | `ALanded`, `ADeferred`, `ABlocked`, `AMoved`, `AFault` | durable |

**Contracts.** Request and result types are frozen, strict, `extra="forbid"`
pydantic dataclasses in `src/hamsterdan/contracts/readiness_v5.py` (lines
607–1491). `contracts/readiness.py` is mostly legacy; only `WorkflowModel`,
`AdmittedConversation` and `ChangeResult`/`RepairResult` are live.

**Handlers** (`readiness/net_v5/gating.py`):
- `VariantPayloadConverter` encodes a result as
  `{"$variant": "<ClassName>", **fields}` and refuses subclasses.
- `VariantRoutingActivityHandler` routes the result to the place of that color.
- `DurablePublicationActivityHandler`, for reply/dash/announce, maps a
  `DeadlineExceeded` failure to the Blocked variant.
- `IdentifiedInlineActivityHandler` covers the other five.

All eight use `ExecutionPolicy(attempts=1)`, so retry and recovery are modeled
in the net, not in Petrus. Correlation and idempotency are both the operation
identity.

**Operation identity grammars:**
- `publish_gate`, `rerun_gate`, `reminder_gate`:
  `[A-Za-z0-9][A-Za-z0-9._:-]{0,127}`
- everything else: `[!-~]{1,1024}`

**Identity formats:**
- `review:{subject}:{head}:i{n}`
- `findings:{head}:i{n}` (falls back to a sha256 form if the head fails the
  grammar)
- per-finding `{op}:{finding_id}` (sha256 fallback)
- `rerun:L{n}:{fp}`
- `repair:L{n}:{fp}`
- `push:{rid}:{head}:i{n}`
- `reply:{comment_id}`
- `dash:{digest}`
- `reminder:timer:{subject}:i{n}:s{k}`
- `ready:{head}:i{n}`
- `timer-command:{subject}:g{n}`

The host derives agent operations from these:
`mutation:{repo}:pr:{n}:{op_key}` and
`conversation:{repo}:pr:{n}:delivery:{uuid}`.

#### 1.3.5 What goes into History

Token `data` is `WorkflowModel.dump()`, which is pydantic
`dump_python(mode="json")`:
- every field is present, defaults included;
- fields appear in **declaration order**;
- tuples become lists and `None` becomes `null`;
- token color is the Python class name.

Typed facts put `kind` last, for example
`{"incarnation":1,"body":{…},"kind":"state"}`.

Before every fold, `folding.values()` re-serializes bound token data with
sorted keys and validates it through a `TypeAdapter`. That validation is
observable when a fold copies nested dicts into its output.

Durable Activity results carry `$variant`; routed tokens do not. Seed baton
bytes for every loop are listed in the readiness research notes. The Haskell
codecs must reproduce them exactly, with fields in declaration order and kinds
last.

#### 1.3.6 The Python-literal trap

`dashboard.py` appends entries `f"{kind}:{body}"`, where `body` is a Python
dict. Its digest is `f"{kind}:{sorted(body.items())!r}"`. Both end up in
History (`DashMemory.entries`, `digest`) and in the Activity identity
`dash:{digest}`. `board.py:39-49` parses entries back with `ast.literal_eval`.
Example entry:

```text
state:{'base': 'def', 'base_current': False, 'head': 'abc', 'mergeable': True, 'phase': 'running', 'policy': 'p', 'strict_base': True}
```

The port needs:
- a Python `repr` printer for `str` (CPython's quote selection and escapes),
  `int`, `bool`, `None`, `list`, `tuple` and `dict`;
- a parser for the same literal subset.

#### 1.3.7 Nondeterminism

The net and contracts contain no clocks, randomness or environment reads. Every
nondeterministic value enters through doors and gate results, and the host
supplies them:
- the subject;
- `reminder_delay_s` (frozen at instance creation);
- timer instants (`%Y-%m-%dT%H:%M:%S.%fZ`, microseconds);
- SHAs, run ids and policy digests;
- comment ids;
- LLM intents and findings;
- provider error strings.

Firing order among concurrently enabled transitions comes from the Engine
policy (§1.4). It must match Petrus exactly to get byte-identical History.

### 1.4 Host and runtime wiring

**Entry point:** `python -m hamsterdan.host` (`src/hamsterdan/host/__main__.py`).

| Subcommand | What it does |
| --- | --- |
| `serve` | Runs uvicorn with the FastAPI app. |
| `validate` | Prints `reconcile_registration()` as JSON. |
| `inbox` | Prints custody counts and failures. |
| `requeue --delivery` | Resets a parked delivery. |
| `inspect-instance --installation --repository --pr` | Offline read of `binding.json` and `history.jsonl`. |

`--host` and `--port` default to `HAMSTERDAN_HOST` / `127.0.0.1` and
`HAMSTERDAN_PORT` / `8000`.

**Startup order:**
1. Read `HostConfig` from the environment.
2. Pop the private key and webhook secret from `os.environ`.
3. Refuse retired variables.
4. `preflight_v5_state`: only `"topology":"v5"` bindings may resume.
5. Read the Pi config and pop the API key.
6. Compose the agent and activate the agent route store.
7. Compose the Pi A2 runtime and the workspace provider.
8. Construct `HostService`.

On a configuration error the process exits with code 2.

**HTTP** (`host/api.py`). The FastAPI lifespan reconciles the registration
(GitHub inventory into `routes.sqlite3`) and starts `service.worker()`. Routes:
- `GET /healthz` returns `ok`/`degraded`, installation counts, active
  repositories, loaded applications, inbox counts, runnable hints, and
  scheduler errors.
- `POST /github/webhooks` (§1.2).

**Worker loop** (`host/service.py:493-540`):
- A startup sweep, then `pump()` every 0.25 s and `sweep("periodic")` every 60 s.
- **`pump`**, under one lock:
  1. Project pending inbox rows into `RunnableIndex` wakes.
  2. Activate due instances (`run_due(100)`).
  3. Run durable publication Activities on each instance's Worker.
  4. `settle()`.
  5. Schedule repair wakes.
- **`_activate_instance`**, under a per-instance lock (`service.py:681-777`):
  1. Process each observation in row order.
  2. Reconcile on sweeps.
  3. `settle()`.
  4. Re-arm the timer hint.
  5. Acknowledge the custody rows; on error, call `custody.retry`.

Everything runs on one asyncio thread plus `to_thread` workers. **Agent runs
execute inline during `Engine.advance`**, so a review or repair blocks the pump
for its duration (the Pi wall timeout is 900 s).

**Petrus wiring** (`host/v5/runtime.py:100-230`):
- **Engine:** the base `petrus.engine.Engine`, through `Engine.create(...)` and
  `Engine.load(...)` with these arguments:
  - `history=JsonlHistoryStore(<pr>/history.jsonl)`
  - `dispatch=_CompositeDispatch(InlineDispatch(definitions), LocalDispatch(<state>/activity-dispatch.sqlite3, instance=…, activity_queues={reply_gate|dash_gate|announce_gate: "v5-publication:{instance}"}))`
  - `handlers=wire_gates(built, GATES, definitions, DERIVED)`
  - `guards=built.guards`
  - `policy=selection=_V5EnginePolicy`
  - `activities=…`
  - `marking=seed_marking(instance, reminder_delay_s)`
- **`_V5EnginePolicy`** normally calls `choose_throughput(snapshot)` with a
  default `SelectionPipeline()`. During ingress it forces the single
  `BeginCandidate` for the door's lifecycle fold transition: `on_head` maps to
  `life.admit_head`, and so on (`_INGRESS_FOLDS`, `runtime.py:56`).
- **Delivery identities:**
  - `github-delivery:{uuid}:{door}`
  - `host-reconcile:{subject}:{revision}:{sha256}:{door}`
  - `v5-timer-due:{timer_id}:{due_us}`
  - `v5-timer-command-applied:{op}`
  - `v5-review-wake:sha256(op\0attempt\0blocker)`
  - `v5-announce-wake:sha256(json)`
- **Poisoned composition:** any exception from `deliver` or `advance` reloads
  the Engine from JSONL before re-raising. `drain(limit=500)` advances until
  nothing is ready.
- **Worker:** one `petrus.motus.worker.Worker` per instance over
  `LocalDispatch(...).worker(("v5-publication:{instance}",))`. Its resolver
  (`HostService._guard_durable_activity`):
  - fails closed on scope mismatch;
  - returns a synthetic Blocked result when the route was revoked;
  - wraps foreign exceptions as non-retryable `ActivityError`.
- **Not used:** Postgres, Absurd, the SQLite *engine* wrapper (`engine/sqlite.py`),
  ZeroMQ, Gondolin, `observation_http`, simulation, fabric, processes,
  telemetry.

**Authority fencing** (`host/v5/claim.py`, `application.py:196-219`):
- `current_claim()`:
  1. Refuses if any same-PR inbox row lacks a manifest.
  2. Reads the authority grant (`v5_authority_grants`).
  3. Fresh-reads the PR, base ref and branch policy.
  4. Requires `(phase, head, base, policy digest)` to match the grant.
  5. Returns `CurrentClaim(phase, incarnation, head, base, policy)`.
- **Grant reduction:**
  - a new head while running bumps `incarnation`;
  - draft sets `quiescent`;
  - ready sets `running` and bumps `incarnation`;
  - close sets `terminal`.
- **Gate classification** (`host/v5/gates.py:1-31`):
  - lookup-first for landed effects;
  - a claim mismatch gives Moved;
  - `GitHubBoundaryError` or a capability denial gives Blocked;
  - unstaged custody gives Deferred;
  - `ValueError` or `RuntimeError` gives Fault.
- **Unfenced by design:** reply, reminder and dashboard (`_UNFENCED_PREFIXES`).
  The announcement is fully fenced; with a strict policy it also requires
  `base_current`.

**Ingress manifests** (`host/v5/ingress.py`). Each delivery is staged before
any fold, in one SQLite transaction in `webhooks.sqlite3`:
- the observation is converted to door entries, frozen as a manifest
  (`v5_ingress_manifests`);
- the authority grant is updated (`v5_authority_grants`).

Sweeps use `v5_reconciliation_manifests`. Conversation classification (an LLM
call) happens *during staging*, so the classified intent is frozen into the
manifest before it reaches the net.

**Timers** (`host/v5/timers.py`). The net emits `TimerCommand` tokens. The host
applies each one transactionally in `timers.sqlite3` and delivers
`TimerCommandApplied`; maturity delivers `TimerDue`. `settle()` iterates this
loop up to 500 times, and the next due time becomes a `petri-timer` wake in
`runnable.sqlite3`.

**Shutdown** (`service.py:844-878`):
1. Settle terminals.
2. Close the applications (Worker, Engine, timers, review store, ingress DB).
3. Close the runnable index, custody, registry and clients.
4. Close the Pi runtime host and the agent routes.

### 1.5 Agents

**Runtime.** The only route is **Pi native A2 local** through Petrus
agenticus, composed by `compose_pi_a2_runtime` in `src/hamsterdan/host/pi_a2.py:219-246`.
- Amp A1 and agent-as-net A5 are explicitly refused (`host/agenticus.py:87-90`).
- There is no Claude CLI, Codex or Amp path.
- Pi is `@earendil-works/pi-coding-agent` 0.83.0, run by Node 22.19.0, both
  pinned in `deployment/pi/package.json`. Petrus spawns `node pi_helper.mjs`.

**Provider and model.** The pair must appear in Petrus `PI_API_KEY_CATALOG`
(`src/petrus/agenticus/runtime/pi.py:84-88`):
- `anthropic/claude-sonnet-4-5`
- `openrouter/anthropic/claude-sonnet-4.5`
- `openai/gpt-5.6-sol`

**Production uses `openai` / `gpt-5.6-sol`** (`deployment/config/runtime.env`).
The pair is bound to state in `state/pi-a2/installation`.

**Execution limits:**
- Territory is local (no sandbox).
- Review and conversation get `WORKSPACE_READ` and `WORKSPACE_SEARCH`; coding
  also gets `WORKSPACE_WRITE` on `.`.
- `max_tool_calls=32`.
- Petrus defaults: wall timeout 900 s, attachment 960 s, command 60 s,
  credential TTL 1020 s, cancellation grace 5 s.
- `PiNativeRunner` polls every 0.1 s and cancels with `stale-authority` when the
  claim moves.

**Key custody.** `HAMSTERDAN_PI_API_KEY` is handed over once
(`OneShotApiKeySupplier` → `PiA2DirectAuthority`). Connection state is sealed
with AES-GCM using per-connection 32-byte key files under `pi-a2/keys/`.

**Prompts** (`src/hamsterdan/agents/pi.py:87-241`). Each prompt is one compact,
sorted JSON object of at most 64 KiB, with keys `instructions`, `kind`,
`prompt_version` (3 for review, 2 otherwise), `repository_url`, `request` and
`response_contract`.

**Workspaces** (`host/pi_workspace.py`):
1. Anonymous `git clone --no-checkout https://github.com/{repo}.git`, detached
   checkout of the head, `git fsck --strict`.
2. Export tracked regular files only (no symlinks or submodules; at most 20k
   entries and 64 MiB).
3. For review, add `diff.patch` (`git diff base...head`) and `diff.patch.lines`.
4. Pack with Petrus `workspace_archive` (a deterministic PAX tar whose SHA-256
   is the start digest).
5. Coding results are reconciled by re-applying the diff on a fresh clone.

**The target repository must therefore be publicly readable.**

**Results** (`src/hamsterdan/agents/protocol.py`). Validation is strict, with
exact field sets.
- **Every result** echoes `repository`, `pull_request`, `epoch`, `head`, `base`.
- **Review:**
  - `status` is `clear`, `blocking` or `unable`.
  - `findings[]` items are
    `{id, path, line, related_locations, title, body, severity, confidence, evidence, blocking, suggestion}`.
  - `lineage[]` items are `{finding_id, state, supersedes}`.
- **Conversation:** exactly one intent `{type, arguments, mutation, explicit, confidence}`.
- **Coding:** `{kind, ref, status, reproduction_status, diff, changed_files, validation_evidence, proposed_commit_message}`.
- **Errors** are `AgentProtocolError` with a result category.

**Conversation is not an Activity.** `application._classify` (`host/v5/application.py:271-324`)
calls `runner.converse` synchronously while staging the manifest. It offers 12
allowed intents; mutations and `recover_publication` require explicit wording.

**Agent route custody** (`host/agenticus.py:186-198, 320-463`). Operations are
claimed in `agent-routes.sqlite3` and never re-dispatched once resolved. On
startup the store is rebuilt by decoding every `history.jsonl` directly.

**Deterministic seam.** The `AgentRunner` protocol (`review`, `converse`,
`code`, keyed by `(operation, attempt)`; `agents/protocol.py:212`) is injected
into `HostService(runner=...)`. That is the record/replay point for comparisons
(§5).

### 1.6 Outputs: every GitHub API call

All App calls go through `GitHubKitTransport` (`github_app/transport.py:46-84`):
- methods GET, POST and PATCH only; relative paths; no body on GET;
- request bodies at most 64 KiB, encoded with
  `json.dumps(..., allow_nan=False, separators=(",",":"))`;
- responses at most 1 MiB; any 3xx is an error;
- pagination follows `Link rel="next"` only to `https://api.github.com`, at most
  20 pages, refusing cycles.

githubkit defaults are `Accept: application/vnd.github+json`,
`User-Agent: GitHubKit/Python`, no `X-GitHub-Api-Version` header, no timeout,
`auto_retry=False`, and no redirects. Below, `R` means `/repos/{owner}/{repo}`.

**Auth and registration** (`github_app/auth.py`; githubkit `AppAuthStrategy`):
- **App JWT:** RS256 with `{"iss": app_id, "iat": now-60, "exp": iat+600}`,
  cached for 8 minutes.
- **Installation token:** `POST /app/installations/{id}/access_tokens` with
  `{"repository_ids":[sorted ids]}`. Cached in memory until `expires_at - 1 min`
  and never persisted. One client per `(installation, sorted repo ids)`;
  operation clients are narrowed to a single repository.
- **Startup validation:**
  - `GET /app`: id, client id and slug must match, and the permissions and
    events must be **exactly** those in §5.1.
  - `GET /app/installations?per_page=100`: each configured account has exactly
    one unsuspended installation with the same exact permissions.
  - `GET /installation/repositories?per_page=100`: every configured repository
    is present.

**Reads** (`github_app/gateway.py` unless noted):

| Call | Purpose |
| --- | --- |
| `GET R/pulls/{n}` | state, draft, head sha/ref/repo, base sha/ref, author, mergeable, merged, mergeable_state, html_url |
| `GET R/git/ref/heads/{base_ref}` | current base SHA (used instead of `pull.base.sha`) |
| `GET R/rules/branches/{base_ref}` (on 404, `GET R/branches/{base_ref}/protection`) | strict checks, required contexts, required approvals, thread resolution; policy digest = sha256 of compact sorted JSON |
| `GET R/compare/{base}...{head}` | `behind_by == 0` means base is current |
| `GET R/pulls/{n}/requested_reviewers` | reminder recipients |
| `GET R/pulls/{n}/reviews?per_page=100` | latest state per login (DISMISSED removes) |
| `POST /graphql` reviewThreads (`first:100`, paged; `{id isResolved comments(first:1){nodes{viewerDidAuthor body}}}`) | unresolved count, excluding the App's own threads |
| `GET R/actions/workflows/{workflow_path}/runs?event=pull_request&head_sha={head}&per_page=20` | exact-head runs for this PR, sorted by `(attempt, id)` descending |
| `GET R/actions/runs/{id}/attempts/{a}/jobs?per_page=100` | job conclusions; a required check with no job counts as failed |
| `GET R/issues/{n}/comments?per_page=100` | marker lookup; review context (last 100, bodies truncated to 20k) |
| `GET R/pulls/{n}/comments?per_page=100` | inline finding lookup |

`GET R/actions/runs/{id}/attempts/{a}/logs` is defined but never called.

**Writes** (`github_app/effects.py` unless noted):

| Call | Payload | Purpose |
| --- | --- | --- |
| `POST R/issues/{n}/comments` | `{"body": body + "\n\n" + marker}` | readiness advisory, reply, reminder, finding fallback, dashboard create |
| `PATCH R/issues/comments/{id}` | `{"body": …}`, only if it differs | dashboard update |
| `POST R/pulls/{n}/reviews` | `{"body":"I found review issues on this head; details are attached to the relevant lines.","commit_id":head,"event":"COMMENT","comments":[{"body","path","line","side":"RIGHT"}…]}` | anchored findings, one native review per batch |
| `POST R/pulls/{n}/comments` | `{"body","commit_id","path","line","side":"RIGHT"}` | single inline finding; a 422 "not in diff" falls back to an issue comment |
| GraphQL `resolveReviewThread` | `{threadId}` | resolves the App's own unresolved finding threads from older heads, after a fresh publication or announcement |
| `POST R/issues/{n}/comments` | body is only `<!-- hamsterdan-rerun run={id} head={sha} operation={op} -->` | **rerun request**; see the note below |
| `POST R/git/blobs`, `R/git/trees`, `R/git/commits` | base64 blobs; tree with `base_tree`; commit authored by `Hamsterdan <hamster-dan[bot]@users.noreply.github.com>` with trailers `Hamsterdan-Operation:` and `Hamsterdan-Payload-Digest:` | host-side Git publication (`host/git_publish.py`) |
| GraphQL `repository{id}`, then `updateRefs` | `refUpdates:[{name:"refs/heads/<head_ref>", beforeOid, afterOid, force:false}]`, `clientMutationId` = sha256 of compact sorted JSON | exact compare-and-swap of the PR branch |

**Rerun requests go through the target repository.** The App has only
`actions: read`, so the rerun marker comment is picked up by a
`rerun-broker.yml` workflow in the target repository, which validates it and
calls `POST R/actions/runs/{id}/rerun` itself.

**Never called:** merge, the Checks API, commit statuses, labels, approve or
request-changes reviews, reviewer requests, PR edits, Actions writes.
**Hamsterdan creates no check runs, statuses or labels.** Its only outputs are
comments, one review per finding batch, thread resolution, and commits pushed
to the PR branch.

**Markers and bodies:**
- **Immutable comments** end in `\n\n<!-- hamsterdan:{conversation|finding|readiness|reminder} operation={op} head={sha40} -->`.
  Lookup matches only comments by `<slug>[bot]` whose body equals the marker or
  ends with `"\n\n" + marker`. The same marker with a different body is a Fault.
- **Summary comment:** marker `<!-- hamsterdan:dashboard -->`. The body is
  `render_board(entries)` (`board.py:205-220`):
  - heading `## Hamsterdan summary — <verdict>`;
  - a Gate/State table with rows CI checks, Dan's review, Human review, Base,
    Conflicts;
  - attention lines;
  - `<sub>head … on base …</sub>`.
- **Readiness advisory:**
  `## Hamsterdan readiness advisory\n\nAll observed gates are ready. Clean. Humans keep merge authority; Dan never merges PRs.`
  One legacy body is accepted on lookup (`host/v5/gates.py:85-93`).
- **Reminder:** `@{login}, this PR and I have gotten to know each other quite well. {Please review this PR|Please assign a reviewer for this PR}.{ [See current readiness state.](url)}`
- **Finding bodies:** the agent's text, `Related locations:` links, a
  ```` ```suggestion ```` block, and links (`effects.py:476-522`).

**Errors and retries** (`github_app/models.py:13-40`):
- `GitHubBoundaryError(failure_class ∈ {transport_ambiguity, transient_http_rejection, capability_denial, payload_rejection, provider_rejection})`.
- There are no client retries. The only retries are:
  - comment POST: 2 attempts with lookup-first recovery in between;
  - inline findings: sleep 60 s, then 120 s, on 429, 5xx, secondary rate limit,
    or an empty 422;
  - the inbox backoff (§1.2).
- Rate-limit headers are logged, never acted on.

### 1.7 Operator surfaces

- **Host CLI** (§1.4): `serve`, `validate`, `inbox`, `requeue`,
  `inspect-instance`. These are runtime surfaces to port.
- **`python -m hamsterdan.operator`** (`src/hamsterdan/operator.py`; wrapper
  `scripts/hamsterdan-demo`). It acts with the human's `gh`/`git` credentials,
  never the App's, and prints one sorted-key JSON object.
  - Hard-coded constants: fixture `HBNetwork/demo-pr-readiness`, slug
    `hamster-dan`, reviewer `crisbastos`, pinned broker digests.

  | Subcommand | What it does |
  | --- | --- |
  | `preflight [--health-url]` | Read-only checks of org, repo, workflows, broker, and `/healthz`. |
  | `create --scenario {clean-green, first-attempt-flake, hero-review}` | Branch, `tools/scenario_control.py prepare`, push, `gh pr create`, request a reviewer for hero-review. |
  | `prepare-broker` | Broker identity cutover PR. |
  | `inspect --pr N [--expect-hero-review] [--expect-readiness present\|absent]` | The "ten checks" over comments, markers, runs, attribution. |
  | `inspect-authority --pr N --expect {...}` | Branch-rule, review and thread facts. |
  | `qualification-setup` | One-shot Git-publication fixture setup. |

- **`python -m hamsterdan.host.export`** (`host/export.py`). Builds an offline
  evidence package from a copy of the state directory: History,
  re-rendered boards, agent transcripts joined from `bodies.sqlite3`, inbox rows
  plus raw deliveries (`--webhook-deliveries`), and `MANIFEST.json` with named
  gaps. It is the best existing tool for harvesting real journeys.
- **`deployment/observe.py`.** Payload-free JSONL observation of a remote host
  (History, dispatch, inbox, `/healthz`) over SSH.

### 1.8 Configuration, environment variables, secrets

**Host environment** (`github_app/config.py:229-248`, `host/__main__.py`, `host/pi_a2.py:59-83`):

| Variable | Required | Notes |
| --- | --- | --- |
| `HAMSTERDAN_STATE_PATH` | yes | state root (`/var/lib/hamsterdan` in the image) |
| `HAMSTERDAN_GITHUB_APP_ID` | yes | positive decimal |
| `HAMSTERDAN_GITHUB_APP_SLUG` | yes | bot login is `<slug>[bot]`, mention is `@<slug>` |
| `HAMSTERDAN_GITHUB_CLIENT_ID` | yes | |
| `HAMSTERDAN_GITHUB_PRIVATE_KEY` | yes, secret | PEM value (not a path), at most 64 KiB; popped from the environment |
| `HAMSTERDAN_GITHUB_WEBHOOK_SECRET` | yes, secret | popped from the environment |
| `HAMSTERDAN_GITHUB_INSTALLATIONS_FILE` | yes | TOML; regular file, not group/other-writable, at most 64 KiB |
| `HAMSTERDAN_WATCH_AUTHORS` | no | comma-separated logins; empty means all |
| `HAMSTERDAN_PI_PROVIDER`, `HAMSTERDAN_PI_MODEL` | yes | must be a catalog pair (§1.5) |
| `HAMSTERDAN_PI_API_KEY` | yes, secret | 16–512 printable ASCII; popped |
| `HAMSTERDAN_PI_CLI_PATH`, `HAMSTERDAN_PI_NODE_PATH`, `HAMSTERDAN_PI_PACKAGE_ROOT` | yes | absolute paths |
| `HAMSTERDAN_WORKFLOW_PATH` | no | default `.github/workflows/ci.yml` |
| `HAMSTERDAN_REMINDER_SECONDS` | no | default `259200` |
| `HAMSTERDAN_HOST`, `HAMSTERDAN_PORT` | no | `127.0.0.1`, `8000` |
| `HAMSTERDAN_QUALIFICATION_FAULT` | no | one-shot fault injection JSON (`service.py:51-145`) |

**Retired variables fail startup if present:**
- `HAMSTERDAN_READINESS_TOPOLOGY`
- `HAMSTERDAN_AGENT_MODE`
- `HAMSTERDAN_AGENT_ISOLATION_REQUIRED`
- `HAMSTERDAN_PI_API_KEY_FILE`
- `HAMSTERDAN_GITHUB_PRIVATE_KEY_FILE`
- `HAMSTERDAN_GITHUB_WEBHOOK_SECRET_FILE`
- `HAMSTERDAN_ALLOWED_REPOSITORIES`
- `HAMSTERDAN_GITHUB_ACCOUNT_ID`
- `HAMSTERDAN_GITHUB_ACCOUNT_LOGIN`

**`installations.toml`** (`config.py:128-174`). Exactly one key, `accounts`. Each
entry has exactly `{id, login, repositories = ["<repo_id>:<Owner>/<name>"]}`;
the owner must equal the login; no duplicates. Production value:
`108842540 / HBNetwork / "1316665126:HBNetwork/demo-pr-readiness"`.

**`deployment/config/runtime.env`** (non-secret):
- `HAMSTERDAN_PI_PROVIDER=openai`
- `HAMSTERDAN_PI_MODEL=gpt-5.6-sol`
- `HAMSTERDAN_WORKFLOW_PATH=.github/workflows/ci.yml`
- `HAMSTERDAN_REMINDER_SECONDS=259200`

**Secrets.** The 1Password Environments `hamsterdan-dev` and `hamsterdan-prod`
carry the same six variables:
- `HAMSTERDAN_GITHUB_APP_ID`
- `HAMSTERDAN_GITHUB_APP_SLUG`
- `HAMSTERDAN_GITHUB_CLIENT_ID`
- `HAMSTERDAN_GITHUB_PRIVATE_KEY`
- `HAMSTERDAN_GITHUB_WEBHOOK_SECRET`
- `HAMSTERDAN_PI_API_KEY`

They are loaded by `scripts/with-runtime-secrets`, which:
- requires `HAMSTERDAN_ENVIRONMENT_ID`;
- takes its bootstrap token from `OP_SA_HAMSTERDAN_DEV`,
  `OP_SERVICE_ACCOUNT_TOKEN` or `HAMSTERDAN_OP_TOKEN_FILE`;
- scrubs inherited credential families;
- runs `op run --environment` (`op` 2.39.1-beta.01) and removes the loader
  token from the child.

The host itself only reads plain environment variables, so **the port needs no
1Password integration**; the launcher script wraps any binary. Ops-only
variables (`EXE_DEV_*`, `OP_SA_HAMSTERDAN_OPS`, `OP_SA_HAMSTERDAN_DEMO`,
`GITHUB_DEMO_*_LOGIN`) are in `deployment/README.md`, `env-ops.tpl` and
`scripts/demo-github`.

### 1.9 Persistence

Everything lives under `HAMSTERDAN_STATE_PATH`. Directories are mode 0700 and
symlinks are refused.

| Path | Owner | Contents |
| --- | --- | --- |
| `routes.sqlite3` | `github_app/routing.py:29` | `installations(installation_id PK, account_id, active)`, `repositories(installation_id, repository_id, full_name, active, PK(installation_id, repository_id))` |
| `webhooks.sqlite3` | `github_app/webhooks.py:152`, `host/v5/ingress.py` | `inbox` (§1.2); `v5_ingress_manifests(delivery_id PK, subject, revision, topology, schema_version, entries, UNIQUE(subject, revision))`; `v5_authority_grants(subject PK, phase, incarnation, head, base, policy, revision, source_kind, source_id)`; `v5_reconciliation_manifests(source_id PK, subject, revision, digest, topology, schema_version, entries)` |
| `runnable.sqlite3` | `host/runnable.py:59-69` | `wakes(instance, kind, identity, due_at, PK(instance, kind, identity))`; non-canonical, quarantined and rebuilt on corruption |
| `activity-dispatch.sqlite3` | Petrus `motus/dispatch/local.py:66-95` | LocalDispatch schema v3 (`impetus_local_dispatch_{schema,tasks,terminals,cancellations}`), WAL, `synchronous=FULL`; shared by all PRs |
| `agent-routes.sqlite3` | `host/agenticus.py:186-198` | `agent_routes(operation PK, profile, snapshot, resolved)`, `active_agent_route(singleton, profile, snapshot)` |
| `applications/{inst}/{repo}/{pr}/binding.json` | `host/binding.py:98-159` | `{"instance_id","pull_request","repository","topology":"v5"}`, compact sorted JSON, mode 0600 |
| `applications/{inst}/{repo}/{pr}/history.jsonl` | Petrus `JsonlHistoryStore` | canonical schema-5 History |
| `applications/{inst}/{repo}/{pr}/review-requests.sqlite3` | `host/v5/review.py:96` | `v5_review_requests(operation, attempt, request_json, digest)`: frozen review requests |
| `applications/{inst}/{repo}/{pr}/timers.sqlite3` | `host/v5/timers.py:266-318` | `v5_timer_meta`, `v5_timer_operations`, `v5_timers`; rebuildable from History |
| `pi-a2/` | `host/pi_a2.py`, Petrus `pi_a2_host` | `installation`, `keys/*.key`, `workspace/`, `runtime-host/{connection,bodies,operations}.sqlite3`, `materializations/` |
| `pi-workspaces/operation-*` | `host/pi_workspace.py` | per-operation clones (temporary) |

There are no external databases. PostgreSQL is not used.

### 1.10 Deployment

**Runtime-required:**
- The host process with its environment, config and state directory.
- `git` (Git publication and workspaces).
- Node 22.19.0 and the Pi package.
- An HTTPS endpoint forwarding to `POST /github/webhooks`.
- `/healthz`.

**Production setup:**
- An image from `deployment/Containerfile`: Python 3.14.7-slim plus `git`, uid
  10001, `ENTRYPOINT python -m hamsterdan.host`, `CMD serve --host 0.0.0.0 --port 8000`.
- Runs on the exe.dev VM `hamsterdan-prod` under the systemd unit in
  `deployment/ansible/templates/hamsterdan.service.j2` (read-only rootfs,
  `--cap-drop=ALL`, loopback port 8000).
- Webhooks arrive through an exe.dev HTTPS share, with no upstream queue;
  recovery is GitHub's Redeliver. Development uses the Amp durable relay.

**Ops tooling, not ported:** Ansible playbooks, `deployment/{release,deploy,runtime,exe_vm,exe_access,observe,observation}.py`,
1Password wrappers, `.agents/setup` / `.agents/resume`, and `tools/demo-video`.
A Haskell image only needs to honor the same container contract: entrypoint
arguments, environment, state path, uid, port.

### 1.11 `src/hamsterdan2` (deferred)

CV21's rebuild of the outer system, about 3.5k lines of source and 43 tests.
- **Webhook API:** `POST /github/webhooks` returns **200** with a different
  receipt.
- **Storage:** a raw-body `webhook_inbox` and `pr_workflows` in
  `hamsterdan.sqlite3`, Petrus `engine.sqlite` and `SqliteHistoryStore`.
- **Bridge:** a workflow bridge into the V5 net that folds only `HeadSeen`.

It is not runnable and has no effects, so it is out of the first port. Its
inbox/intake split is a good shape for the Haskell host's internals, provided
the V5 wire contracts stay unchanged. Revisit when upstream CV22 cuts over.

## 2. Petrus APIs Hamsterdan uses

### 2.1 Inventory

The inventory comes from an AST scan of `src/`, `tests/`, `tests2/`,
`deployment/` and `scripts/`: 155 distinct (module, symbol) pairs. Neither
`deployment/` nor `scripts/` imports Petrus. In the "Used by" column, SRC is
`src/hamsterdan`, H2 is `src/hamsterdan2`, and T is tests.

| Petrus area | Symbols | Used by | Purpose |
| --- | --- | --- | --- |
| `impetus.petrinet` (`marking.py`, `schema.py`, `enabledness.py`) | `Token`, `Marking`, `NetPath`, `Binding`, `Cel`, `Net`, `NetUri`, `Guard` (H2 typing) | SRC net_v5, host/v5; H2; T | tokens, seed marking, paths, CEL filters, `net.inputs/outputs/handler_uri` for variant routing |
| `impetus.dsl` | `NetSpec`, `BuiltNet`, `arc` (`arc.inhibit`, `arc(filter=Cel)`), `petri_handler` | SRC net_v5 | building the net |
| `impetus.binding` | `Handler`, `ActivityHandler`, `DerivedActivityHandler` | SRC `gating.py`; H2 | gate handlers (`prepare`, `project`, `project_failure`) |
| `impetus.selection` | `SelectionPipeline`, `SelectionProposal`, `SelectionState` | SRC `host/v5/runtime.py` | custom engine policy |
| `impetus.history` (+`codec`) | `ActivityRequested`, `ActivityCompleted`, `ActivityFailed`, `ActivityTerminalQuarantined`, `ExternalEventDelivered`, `FiringBegun`, `TokensProduced`, `FiringCompleted`, `FiringFailed`; `decode_record`, `encode_record` | SRC runtime, `agenticus.py`; H2; T | manifest/fold checks, wake validation, route rebuild by decoding `history.jsonl` directly |
| `impetus.history_store` | `JsonlHistoryStore` (production), `SqliteHistoryStore` (H2), `InMemoryHistoryStore` (T) | | |
| `impetus.instance` | `AcceptedDelivery`, `PriorAcknowledgement`, `ScopedDeliveryAcknowledgement`, `FiringOutcome` | H2 only | |
| `engine` | `Engine` (`create`, `load`, `deliver`, `advance`, `records`, `marking`, `close`; H2 also `accept_delivery`, `complete_delivery`, `snapshot`, `history_page`); `Action`, `BeginCandidate`, `Snapshot`, `DriveOutcome`, `choose_throughput` (from `_coordination.py`, re-exported); `engine.sqlite.create_engine`/`load_engine` (H2) | SRC runtime | |
| `motus.activity` | `activity`, `Activity`, `ActivityDefinition`, `ActivityDeclaration`, `ActivityInvocation`, `ActivityError`, `ActivityFailure`, `ExecutionPolicy`, `PayloadConverter`, `JsonPayloadConverter`, `DataclassPayloadConverter` | SRC `application.py`, `service.py`, `gating.py`, `payloads.py` | the 8 gates |
| `motus.dispatch` | `Dispatch`, `CancellableDispatch`, `CancellationInstruction`, `CancellationDisposition`, `InlineDispatch`, `LocalDispatch` (+`.worker`), `InMemoryDispatch` (T) | SRC runtime | composite inline + durable dispatch |
| `motus.worker` | `Worker` (`run_available`, `stop`, `close`) | SRC runtime | durable publications |
| `motus.execution.archive` | `workspace_archive`, `extract_workspace_archive` (T) | SRC `pi_workspace.py` | deterministic PAX tar |
| `agenticus.runtime.pi_a2_host` | `PiA2RuntimeHost`, `PiA2RuntimeHostConfig`, `PiA2DirectAuthority`, `PiA2RuntimePolicy`, `PiA2RuntimeStart`, `compose_pi_a2_runtime`; T: `compose_pi_a2_scripted_runtime`, `PiA2ScriptedCall`, `PiA2ScriptedTurn` | SRC `pi_a2.py`, `pi_workspace.py`, `agents/pi.py`, `agenticus.py`, `service.py` | the only agent route |
| `agenticus.runtime.pi` | `PI_API_KEY_CATALOG`, `PI_CONNECTION_CAPABILITIES`, `PI_PROGRAM_CAPABILITIES`, `PI_COLLOCATED_HANDS`, `PI_LOCAL_TERRITORY`, `PI_CONTINUATION_CAPABILITIES` (T: `PI_SDK_VERSION`, `PI_AI_VERSION`, `PI_CONTINUATION_DESCRIPTOR`) | SRC | |
| `agenticus.runtime.{profiles,operation,installation,result}` | `PI_NATIVE_A2_LOCAL`, `AMP_A1`, `AGENT_AS_NET_A5_LOCAL` (only checked in order to refuse them); `RuntimeOperation`, `RuntimeProtocolError`; `ProbeDisposition`; T: `RuntimeTurnSettlement`, installation probe types | SRC | |
| `agenticus.catalog` | `CapabilityDescriptor`, `DescriptorIdentity`, `DescriptorKind`, `Catalog`, `ResolutionRequest`, `ResolutionSnapshot.to_data()` | SRC `agenticus.py` | route resolution; snapshot JSON persisted |
| `agenticus.connection` | `ConnectionIdentity`, `KeyContext`, `KeyErasureEvidence`, `KeyOperationError` | SRC `pi_a2.py` | sealed key custody |
| `agenticus.hands` | `ToolMethod` | SRC | workspace capabilities |
| `agenticus.thread` | `EpisodeId`, `TurnId`, `TurnOutcome` (T: `ThreadId`, `ContinuationId`, `Continuation`, `CancellationDisposition`) | SRC `agents/pi.py` | |
| `testing.dst` | about 40 symbols (`World`, `replay`, `ScenarioArtifact`, `BudgetV4`, `encode_artifact`, …; compatibility string `"petrus.testing.dst/v4"`) | `src/hamsterdan/host/testing/*` and tests only | deterministic World |

**Not used anywhere:** `net_definition`, `net_document`, `observation` (except
indirectly in H2), `scope`, telemetry, simulation, fabric, processes, Postgres,
Absurd, ZeroMQ, Gondolin.

**No private APIs and no monkeypatching.** Tests and the DST World do read
Petrus's private storage schemas:
- `impetus_local_dispatch_*` tables (`host/testing/readiness_world.py:~1660-1695`,
  `tests/unit/readiness/net_v5/test_gating.py:195`);
- `impetus_history_events` (`tests2`).

`host/agenticus.py` decodes `history.jsonl` itself.

### 2.2 What a Haskell host must keep byte-compatible to resume Python state

1. **`history.jsonl`:** schema-5 records (`spec/event-history.md`), plus token
   data in pydantic declaration order and the Python-literal dashboard strings
   (§1.3.5–1.3.6).
2. **`activity-dispatch.sqlite3`:** LocalDispatch schema v3 and its stored
   invocation and outcome JSON, including `$variant`.
3. **Firing order:** `choose_throughput` plus `SelectionPipeline` order. This
   decides record order and occurrence numbers.
4. **Hamsterdan's own SQLite stores** and `binding.json` (§1.9).
5. **Pi state:** `pi-a2/runtime-host/*` stores, the `workspace_archive` bytes
   (their SHA-256 is compared on resume), and the `ResolutionSnapshot.to_data()`
   JSON.

No net definition is persisted. The net is rebuilt from code on every
`Engine.load`.

### 2.3 Behavior differences between Petrus `89baf78` and `3f85fc2`

**History rewrite.** Petrus history was rewritten on 2026-09-12 to remove an
external project name from a telemetry docstring (Petrus
`docs/process/worklog/entries/2026-09-12T2354Z-codex-history-cleanup.md`).
`89baf78` and `913acb0` are therefore **not ancestors of `3f85fc2`** and are
not fetched by a normal clone:
- `89baf78` maps to rewritten `cce9d78`;
- `913acb0` maps to rewritten `0451c69`;
- each pair differs only in `src/petrus/telemetry.py` (docstring) and its test.

To diff, fetch the old commits explicitly:
`git -C upstream/petrus fetch origin 89baf78aa030b047f239435a1ad5f25cde67e4d8 913acb0a82928f34281d9ed15aaaf5c44de34617`.
`scripts/upstream-diff` runs a plain `fetch origin` and will not find them.

**Findings:**

| Range | `src/` changes | Effect on Hamsterdan |
| --- | --- | --- |
| `89baf78..913acb0` (production) | none (`git diff … -- src pyproject.toml uv.lock` is empty) | none |
| `89baf78..3f85fc2` | ImportError message text in `engine/_postgres.py`, `fabric/postgres.py`, `impetus/history_store/postgres.py`, `motus/dispatch/absurd.py`, `motus/transport/zeromq.py`, `processes/postgres.py` (`petrus[x]` became `petrus-runtime[x]`); the `telemetry.py` docstring | none; Hamsterdan imports none of these modules |
| spec | `spec/net-document-v1.md`, `observation-protocol-v1.md`, `simulation-http-v1.md`: terminology only (Layout, Timeline, Net identity); same JSON keys | none |
| packaging | distribution renamed `petrus` 0.0.0 → `petrus-runtime` 0.1.0a1; extras renamed to match | Hamsterdan never reads distribution metadata for Petrus and requests no extras. Its `uv.lock` resolves `petrus` with only `cel-python 0.5.0` and `pydantic 2.13.4`. Re-pinning upstream would only rename the requirement. |
| tests | timing-only edits (`cancellation_grace=2`, ZeroMQ `request_timeout`) | none |

**Conclusion: for every API in §2.1, behavior is identical across the three
commits. The port has nothing to reconcile.** The Petrus github-app extra
(cryptography only) is unused; Hamsterdan does its own GitHub integration.

Two Python tests hard-code the old pin and must be ported as "pin is exact"
checks against our pin, not as behavior:
`deployment/tests/test_container_contract.py::test_public_petrus_revision_is_exact_and_locked`
and `tests/test_architecture.py`.

## 3. External dependencies and Haskell equivalents

| Python dependency | Used for | Suggested Haskell equivalent |
| --- | --- | --- |
| `githubkit[auth-app]==0.16.0` | App JWT, installation-token minting and caching, raw request building, `webhooks.verify`, Link pagination | Hand-written client over `http-client` + `http-client-tls`; JWT RS256 via `jose` or `crypton` (PKCS#1 v1.5 SHA-256); token cache in `TVar`. Avoid the `github` package: requests must be byte-controlled. |
| `httpx` (via githubkit; also tests' `MockTransport`) | bounded streaming reads, event hooks | `http-client` `withResponse` + `brRead` with a byte cap; a `Transport` record of functions as the fake seam |
| `cryptography>=46,<51` | AES-GCM sealing of Pi connection state; RSA for the JWT | `crypton` (`Crypto.Cipher.AES` GCM, `Crypto.PubKey.RSA.PKCS15`) |
| `fastapi`, `uvicorn` | `POST /github/webhooks`, `GET /healthz`, lifespan | `warp` + `wai` (raw body streaming with a cap, exact 202/400 JSON); optionally servant |
| `pydantic>=2.11,<3` | strict frozen contracts, `dump_python(mode="json")`, `TypeAdapter.validate_json` | hand-written records with explicit encoders in declaration order (`petrus-json` values), strict decoders rejecting extra fields; no generic aeson-TH defaults |
| stdlib `json` | every digest and canonical JSON | `petrus-json` (CPython-exact, `ensure_ascii`, separators, `sort_keys`) |
| stdlib `ast.literal_eval` / `repr` | dashboard entries and digests | a small Python-literal printer and parser (part of `hamsterdan-contracts`) |
| stdlib `sqlite3` | all local stores | `sqlite-simple` / `direct-sqlite`, same DDL and pragmas (WAL, `synchronous=FULL` where Petrus sets it) |
| stdlib `tomllib` | `installations.toml` | `toml-parser` (strict key sets) |
| stdlib `hmac`, `hashlib` | webhook HMAC, digests | `crypton` HMAC-SHA256; `Data.ByteArray.constEq` |
| stdlib `uuid` | delivery-id canonicalization | `uuid` |
| stdlib `subprocess` + `git` CLI | anonymous clones, `apply --binary --index`, `write-tree`, `ls-remote`, `log --first-parent` | `typed-process` with the same hardened environment (no credential helpers, no hooks, `HOME=/dev/null`) |
| `cel-python 0.5.0` (via Petrus) | `ready.facts` migration filters | `petrus-cel` |
| Pi (`@earendil-works/pi-coding-agent` 0.83.0, Node 22.19.0) via Petrus `pi_helper.mjs` | the agent | keep the Node helper; the Haskell agenticus port drives the same line-framed JSON protocol (SCOPE.md: external agent runtimes are not reimplemented) |
| `op` CLI (2.39.1-beta.01), Ansible, exe.dev API, Docker/buildx, bun | ops | unchanged; not ported |
| dev: `pytest`, `pytest-xdist`, `pytest-randomly`, `pytest-timeout`, `hypothesis`, `mutmut`, `ruff`, `ty`, `ast-grep` | tests and quality | `tasty`/`hspec`, `hedgehog` or `quickcheck-state-machine` (stateful campaigns), `hlint`, `ormolu`/`fourmolu`, cabal module visibility instead of import-scanner tests |

## 4. Test suites

### 4.1 Organization and how to run

- **pytest configuration** (`pyproject.toml`):
  - `testpaths = ["tests", "deployment/tests"]`, `addopts = "--randomly-seed=1729"`,
    `timeout = 30`.
  - Markers: `real_provider_acceptance` and `linux_orb_setup`.
  - The root `conftest.py` adds `--forbid-skips`.
  - `tests2` runs separately with `-o addopts=`.
- **Run the routine suite:** `uv sync --frozen && scripts/check tests`. That is
  xdist with up to 4 workers, `-m "not real_provider_acceptance"` (plus
  `not linux_orb_setup` off Linux), the campaign file serially, then `tests2`.

**Profiles of `scripts/check`:**

| Profile | Runs |
| --- | --- |
| `quick` | ruff, ty, `tests/test_architecture.py`, and the hamsterdan2 gate |
| `hamsterdan2` | strict ruff, ty, ast-grep `quality/hamsterdan2`, `pytest tests2` |
| `tests` | the routine suite (CI job, `.github/workflows/ci.yml`; public Actions are disabled) |
| `full` | quick + `bun test tests/amp_webhook_relay.test.ts` + `uv build` + the routine suite |
| `release` | full + a serial run with seed 20260825 |
| `audit` | non-blocking; root `sgconfig.yml` with `audit-rules/` and `audit-rule-tests/` |
| `mutation` | mutmut on `host/v5/rerun.py` |
| `demo-video` | `tools/demo-video` checks |

**Local run on macOS** (Python 3.14.6, 4 workers):
- 1,297 collected, 1,281 passed, 6 failed, in 94 s. The six failures are
  environmental:
  - three need the exact Python 3.14.7 for a nested `uv run`;
  - three need bash ≥ 4 instead of macOS bash 3.2.
- `tests2`: 43 of 43 passed in 3.6 s.

**Requirements:**
- **None of the suites need network, credentials, Docker or PostgreSQL.**
- Always needed: `git`, bash ≥ 4, `ssh-keygen`.
- `full` also needs bun 1.3.10.
- Pi is exercised through Petrus's scripted runtime on a fabricated package tree
  and a fake `node`. The real Pi package is not needed.

### 4.2 Classification

| Kind | Where | Collected |
| --- | --- | --- |
| Unit (in-process; GitHub via `httpx.MockTransport` or fakes; Engine with in-memory/JSONL stores and inline/in-memory/local dispatch) | `tests/unit/**` | 1,026 |
| Integration (real `git` with local bare remotes, real SQLite and `HostService`, FastAPI `TestClient`, Petrus DST and Hypothesis campaigns) | `tests/integration/**` | 176 |
| Deployment tooling (Containerfile, Ansible argv, exe.dev client fakes) | `deployment/tests` | 42 |
| Repository meta (architecture, check script, skip policy, artifact contents) | `tests/test_*.py` | 20 |
| Replacement track | `tests2` | 43 |
| TypeScript relay (bun) | `tests/amp_webhook_relay.test.ts` | 6 |
| Real-provider acceptance | none at the pin; the last one (Amp) was removed in `1f0508d` | 0 |

`tests/fixtures/` holds only `skip_probe.py`. There are **no recorded webhook
payloads, API responses or agent transcripts**; worlds are built in code.

### 4.3 Behavior coverage by component

Counts are collected cases, with distinct test functions in parentheses.

| Area | Files | Cases | What is checked |
| --- | --- | --- | --- |
| github_app foundation | `tests/unit/github_app/test_app_foundation.py` | 80 (34) | config redaction and validation, watched authors, installation TOML custody, JWT→scoped token with no host cache, registration and inventory validation with safe Link pagination, webhook envelope rules, verify-before-parse, dedupe, no payload storage, retry/park, routing reconciliation, conversation admission |
| github_app effects and gateway | `tests/unit/github_app/test_github.py` | 83 (56) | marker lookup-first, immutable retries, inline review batch and fallback, backoff, dashboard fencing, reminders across heads, Actions evidence selection, rerun marker fencing, GraphQL ref CAS, stale-thread resolution, branch rules with 404 fallback, pagination completeness, error normalization |
| agents | `tests/unit/agents/test_pi.py`, `test_protocol.py` | 66 (38) | prompt envelope, stable Pi execution identities, authority polling and cancel, cleanup failures, coding archive policy, strict result validation (correlation, finding ids, one intent, reproduction) |
| host (non-v5) | `tests/unit/host/test_{agenticus,binding,export,host_architecture,pi_a2,publication_qualification,runnable,secret_launch}.py` | 180 (123) | route profile and selection, Pi A2 only, route persistence and repair, V5-only bindings, evidence export, key sealing, provider/model qualification, runnable index, launcher contract |
| host/v5 | `tests/unit/host/test_v5_{gates,ingress,mutation,rerun,review,timers}.py` | 238 (173) | gate classification (landed/blocked/moved/fault) with lookup-first; ingress door order, atomic manifest and grant, crash cuts and replay, summary-first; mutation CAS; rerun; frozen review requests; timer custody and rebuild |
| readiness/net_v5 | `tests/unit/readiness/net_v5/test_*.py` and `test_payloads.py` | 305 (253) | board 22, ci 21, conversation 21, dashboard 17, escalation 23, gating 5, inline recovery 35, lifecycle 16, mutation 32, readiness 38, reminders 20, review 36, startup 7, payloads 12 |
| readiness model oracle | `tests/unit/testing/test_readiness_model.py` | 34 (29) | independent `ReadinessModel` rules, safety violations, liveness |
| integration/host | `tests/integration/host/test_{service,git_publish,pi_workspace,pi_a2_factory,qualification_setup_local,readiness_scenarios}.py` | 146 (120) | service 70 (durable accept, dedupe, rejections, watched authors, sweeps, restart replay, shutdown); git_publish 30; pi_workspace 20; pi_a2_factory 8; qualification 7; **11 end-to-end journeys** |
| DST World | `tests/integration/testing/test_readiness_{world,coverage,campaign}.py` | 30 | deterministic World around the real `HostService` (duplicate and delayed deliveries, crashes, exhaustion, ambiguous effects, checked against the oracle); coverage accounting; Hypothesis campaigns with exact replay |
| operator and ops | `tests/unit/test_operator.py`, `test_orb_setup.py`, `test_secret_tools.py` | 73 | `gh` inspection parsers; mutation commands never force, merge or bypass |
| repository meta | `tests/test_{architecture,check_command,distribution,pytest_policy}.py` | 20 | Python-specific |
| deployment | `deployment/tests/*` | 42 | ops tooling |
| tests2 | `tests2/*` | 43 | webhook inbox and intake 22, process recovery 4, architecture, enum privacy, feedback 16 |

The 11 journeys in `tests/integration/host/test_readiness_scenarios.py` are:
1. clean green
2. first-attempt flake
3. persistent CI regression
4. seeded finding
5. conversational change
6. agent repair
7. hero review
8. draft→ready
9. stale-base update
10. true conflict resolution
11. collaboration approval

### 4.4 What the Haskell port must mirror

- **Behavioral, must be mirrored: about 1,190 cases.**

  | Area | Cases |
  | --- | --- |
  | github_app | 163 |
  | agents | 66 |
  | host | 180 |
  | host/v5 | 238 |
  | net_v5 + payloads | 305 |
  | oracle | 34 |
  | integration/host | 146 |
  | DST | 30 |
  | tests2 intake | 26 (only if hamsterdan2 is ported) |

  The operator inspection tests (57) apply only when the operator is ported.
- **Python-specific; replace with Haskell mechanisms rather than porting:**
  - the architecture/import scanners, enum-privacy and feedback tests, the
    check-command and pytest-policy tests;
  - ruff, ty, mutmut;
  - the ast-grep rules (`audit-rules/reflective-contract-access.yml` and the 7
    `quality/hamsterdan2` rules).

  Package boundaries and module visibility enforce the architecture rules.
- **Ops tests stay with the Python and TypeScript tooling:** launcher, orb
  setup, deployment, relay.
- **Best cross-implementation corpus:**
  1. the 11 journeys' recorded `(method, path, sorted-JSON body)` request logs
     from `ScenarioProvider` plus `git_boundary_events`, captured as golden files;
  2. History JSONL from the same runs;
  3. DST `ScenarioArtifact`s;
  4. `ReadinessModel` facts→expectation pairs.

## 5. End-to-end against a real GitHub App

**Status.**
- **Tier A** is done. It lives in `packages/hamsterdan-testing`, with the
  eleven journeys byte-exact in all four pairings.
- **Tier B** is done offline, in `packages/hamsterdan-e2e`. All eleven
  journeys, plus three fault cases, are recorded from the reference and
  replayed into both hosts.
- **Tier C** tooling is ready and tested against fakes:
  - the operator fixture parameterization;
  - the deterministic carried agent;
  - `scripts/e2e`, for repositories, App manifests, hosts, scenarios and
    captures;
  - the normalizing comparator.

  It needs only the credentials and accounts listed in
  [docs/e2e.md](e2e.md), which is the runbook. The harness lives in
  `packages/hamsterdan-e2e` and `scripts/e2e`, not in `interop/hamsterdan/`.

### 5.1 What upstream needs

**GitHub App** (`docs/operator/README.md:33-88`; checked at startup by
`github_app/auth.py:19-33`; a mismatch fails startup):
- A private App owned by an organization, with webhooks active, a secret, and
  content type JSON. User authorization is off.
- **Repository permissions, exactly:**
  - Administration: read
  - Actions: read
  - Contents: read & write
  - Issues: read & write
  - Pull requests: read & write
  - Metadata: read
- **Webhook events, exactly:**
  - Issue comment
  - Pull request
  - Pull request review
  - Pull request review comment
  - Pull request review thread
  - Workflow run
- Installed on selected repositories. Every repository in
  `installations.toml` must be visible to the installation.

**Test repository.** Upstream uses the public `HBNetwork/demo-pr-readiness`
(repo id 1316665126, org id 108842540). It must be **public**, because clones
are anonymous. It contains:
- `.github/workflows/ci.yml`: six jobs `scenario-control`, `lint`, `type`,
  `unit`, `build`, `integration`, where `scenario-control` fails attempt 1 for
  the flake scenario.
- `.github/workflows/rerun-broker.yml` and `tools/rerun_broker.py`. This
  workflow is gated on the bot login and marker, and holds `actions: write`.
- `tools/scenario_control.py` and `tools/lifecycle_control.py`.
- `.pr-lab/scenarios/*`: clean-green, first-attempt-flake, hero-review (with
  `scenario-fixtures/hero_review/{gate,cache,models,validate}.py`),
  persistent-ci-regression, seeded-review-finding, conversational-change,
  agent-repair.
- `.pr-lab/lifecycle/*`: collaboration-gate, draft-to-ready, stale-base,
  true-conflict.
- A branch ruleset: strict required checks, one approval, thread resolution.

**Human actors** (needed for hero and authority journeys): an author/operator
and a distinct reviewer, each with their own `gh` login. Upstream uses
`henriquebastos` and `crisbastos`, loaded by `scripts/demo-github`.

**Credentials:**
- the six variables in §1.8, including an API key for a catalog provider
  (production uses OpenAI `gpt-5.6-sol`);
- the operators' `gh` logins.

**Hosting:**
- a public HTTPS URL forwarding to the host's `/github/webhooks`;
- local disk for the state directory;
- `git`, Node 22.19.0 and Pi 0.83.0.

No database server is needed.

**Ownership constraint.** The upstream App is HBNetwork-owned and installable
only on HBNetwork repositories. To run both implementations we need, in an org
we control (for example `seasonedcc`):
- two private Apps with the exact permissions above: one for the Python host
  and one for the Haskell host, for example `hamster-dan-py` and
  `hamster-dan-hs`;
- two public copies of the fixture repository, one per App.

The rerun-broker workflow and the operator constants (`REPOSITORY`, `ORG_ID`,
`REPOSITORY_ID`, `APP_SLUG`, `HERO_REVIEWER`, broker digests;
`operator.py:35-87`) hard-code HBNetwork values. We need a small
parameterization patch, kept in this repo as a harness overlay and not pushed
upstream, or a forked broker with the bot login substituted.

Both are done without patching upstream:
- The reference operator runs under a runtime overlay,
  `packages/hamsterdan-e2e/python/e2e_operator.py`.
- The Haskell operator takes the fixture as configuration
  (`Operator.fixture`, through `hamsterdan-e2e-operator`).
- `scripts/e2e prepare-repos` rebinds the broker's two files to each App's
  bot login. It commits that rebinding on top of the fixture commit.

Two Apps on one repository would both comment and both trigger the broker, so
each App gets its own repository copy.

### 5.2 Comparison procedure

Parity is defined the way upstream defines it for V5 (CV17.DS4,
`docs/project/roadmap/cv17-v5-actor-loop-production-parity/cv17-ds4-production-parity-harness.md`):
**the behavior a GitHub user sees**. We run three tiers, from most to least
deterministic. Only tier C touches real GitHub.

**Tier A: offline journeys (byte-exact).**
1. Patch nothing upstream. Write a Python capture driver (in this repo, under
   `interop/hamsterdan/`) that runs the 11 journeys from
   `tests/integration/host/test_readiness_scenarios.py` with:
   - `ScenarioProvider` as the GitHub transport;
   - `ScenarioRunner` as the `AgentRunner`;
   - a fixed injected `clock`.

   For each journey it emits:
   - the ordered signed webhook deliveries (headers and body);
   - the provider request log `(method, path, sorted-JSON body)`;
   - `git_boundary_events`;
   - each PR's `history.jsonl`;
   - a dump of `binding.json`, `activity-dispatch.sqlite3`, `timers.sqlite3`
     and `webhooks.sqlite3` rows.
2. The Haskell host runs the same journeys with a Haskell `ScenarioProvider`
   that serves the same truth, the same scripted agent results, and the same
   clock.
3. Compare byte for byte: request log, History JSONL, binding, SQLite rows
   (normalized for rowid and WAL only).
4. Cross-resume: start the Haskell host on a Python-produced state directory
   mid-journey, then the reverse, and check convergence to the same final
   History.

**Tier B: recorded production-like replay (byte-exact on effects).**
1. Run each live scenario once against the Python host (tier C setup) with a
   **recording `transport_factory`**. It wraps `GitHubKitTransport` and appends
   every `(request, response)` pair to a JSONL tape. Also record:
   - raw webhook deliveries, via `export.py --webhook-deliveries` or a tee in
     front of `/github/webhooks`;
   - agent results, through a recording `AgentRunner` wrapper keyed by
     `(operation, attempt)`. The canonical request JSON is already in
     `review-requests.sqlite3`; raw outputs are in
     `pi-a2/runtime-host/bodies.sqlite3`.
2. Replay into both implementations with:
   - a fake GitHub server that answers from the tape, in order per
     `(method, path, body)`, and fails on any unrecorded request;
   - a replay `AgentRunner` that fails on unknown keys;
   - a replayed clock.

   Python takes these through `HostService(transport_factory=…, runner=…, clock=…)`.
   The Haskell host gets equivalent test seams and a configurable API base URL.
3. Compare:
   - the write requests (POST/PATCH bodies, GraphQL mutations), exact;
   - History JSONL, exact;
   - the final comment set, rendered.

   The deterministic input order removes webhook-timing nondeterminism, and the
   tape removes provider drift.

**Tier C: live side by side (observable equivalence).**
1. **Setup:**
   - Apps `hamster-dan-py` and `hamster-dan-hs`.
   - Repositories `seasonedcc/demo-pr-readiness-py` and `-hs`, created from the
     same fixture commit.
   - Both hosts get the same `HAMSTERDAN_WATCH_AUTHORS` and
     `HAMSTERDAN_WORKFLOW_PATH`, and `HAMSTERDAN_REMINDER_SECONDS=300` so
     reminder journeys finish in minutes.
   - Each host gets its own state directory and HTTPS endpoint (for example a
     cloudflared or ngrok tunnel, or the exe.dev share).
2. **Agent determinism.** Use a deterministic agent in both hosts: the replay
   `AgentRunner` above, seeded with outputs recorded from one real Pi run of the
   scenario. Run real Pi only in a separate, explicitly nondeterministic
   smoke pass.
3. **Run each scenario on both repositories concurrently** with the
   parameterized operator: `create --scenario …`, then the human steps by the
   same two actors (request changes, `@<slug> please fix`, `@<slug> status`,
   approve), then close unmerged. Scenarios:
   - clean-green
   - first-attempt-flake
   - hero-review (three-actor repair)
   - the lifecycle set (draft→ready, stale base, true conflict, collaboration
     approval)
   - fault injection via `HAMSTERDAN_QUALIFICATION_FAULT`
4. **Capture** at each checkpoint: `operator inspect` and `inspect-authority`
   JSON, the GitHub API snapshots of comments, reviews, threads, commits and
   runs, the `export.py` package, and `/healthz`.
5. **Compare after normalizing** repository, App and bot names, ids, SHAs and
   timestamps:
   - **Comments:** the same set of App comments by kind (summary, findings,
     replies, reminders, readiness advisory), with identical normalized bodies
     and markers, the same final summary-comment body, and the same count of
     readiness advisories (exactly one per generation).
   - **Reviews and threads:** the same native reviews and inline comment
     locations, and the same threads resolved.
   - **Commits:** the same rerun-marker comments; App-authored commits with the
     same tree, parents shape, trailers and author.
   - **Sequencing:** the summary appears before any other effect.
   - **Durable state:** the same History *shape*, meaning the per-transition
     firing multiset and the Activity counts by name and terminal variant.
     Exact History bytes are not expected live, because webhook arrival
     interleaving differs; tier B covers exact bytes.
   - **Health:** no failed or pending Activities; `operator inspect` passes the
     ten checks on both sides.

   Upstream's PR84-vs-PR83 comparison (`docs/project/roadmap/cv19-private-v0-1-production/proof/pr84.md:15-50`)
   is the template. Tolerate only what it tolerates: prose, finding order,
   timing, and summary-update and deferral counts when the agent is real.
6. **Known upstream defects** must reproduce identically, not be fixed
   silently (PR85 §1c1, §1c2):
   - a status reply wording an approval-gate flag as an actual approval;
   - Pi cleanup `host-cleanup-uncertain` errors at shutdown.

## 6. Port decomposition and sequencing

The packages follow the upstream architecture so the import rules become
package boundaries. Names follow the existing `petrus-*` convention.

| # | Package | Ports | Petrus components needed first | Can start |
| --- | --- | --- | --- | --- |
| 0 | `petrus-json` (exists) | CPython JSON fidelity | — | now |
| 1 | `hamsterdan-contracts` | `contracts/readiness_v5.py` (≈106 models, strict decode, encode in declaration order), live parts of `contracts/readiness.py`, `agents/protocol.py` types, the **Python-literal printer and parser** (`Hamsterdan.PyLiteral`) | none (Token JSON shape only) | now |
| 2 | `hamsterdan-github` | `github_app/*`: config and TOML, webhook verification and inbox (SQLite), routing registry, JWT and installation tokens, bounded transport and pagination, gateway reads, GraphQL, effects, markers and bodies | none | now |
| 3 | `hamsterdan-readiness` | `readiness/net_v5/*` (topology, nine loops, startup, folding, gating handlers, `board.render_board`), `readiness/payloads.py` | `petrus-impetus` kernel (Token, Marking, NetPath, Net, inhibit arcs, arc filters), DSL (`NetSpec`, `arc`, `petri_handler`, place colors, `handler_uri`), binding contract (`ActivityHandler`, `DerivedActivityHandler`), `petrus-cel`; Motus activity *types* (`ActivityInvocation`, `ExecutionPolicy`, `ActivityFailure`, payload converters); `net_definition` projection for the fingerprint test | when the impetus kernel and DSL land |
| 4 | `hamsterdan-host` | `host/service.py`, `api.py` (warp), `binding.py`, `runnable.py`, `v5/{runtime,application,ingress,claim,gates,rerun,review,mutation,timers}.py`, `git_publish.py`, `__main__.py` (serve, validate, inbox, requeue, inspect-instance) | engine (`create`, `load`, `deliver`, `advance`, `records`, `marking`, `close`; Action, Snapshot, BeginCandidate, `choose_throughput`; custom policy and selection), selection pipeline, History records and codec, `JsonlHistoryStore`, `InlineDispatch`, `LocalDispatch` (SQLite schema v3, queues, cancellation), `Worker`, `activity` definitions | after the engine, JSONL store, LocalDispatch and Worker; until agenticus lands, it runs with a stub `AgentRunner` |
| 5 | `hamsterdan-agents` | `agents/pi.py` (prompt envelope, result validation, `PiNativeRunner`), `host/agenticus.py` (route store, catalog resolution), `host/pi_a2.py` (key sealing, installation binding), `host/pi_workspace.py` | agenticus (catalog, connection custody and storage, hands, thread ids, `runtime.pi`, `pi_a2_host`, `pi_recovery`, profiles, installation, operation), `motus.execution.archive` (`workspace_archive`), `LocalProcessEnvironment`, the `pi_helper.mjs` protocol | last on the critical path (biggest Petrus dependency) |
| 6 | `hamsterdan-testing` | `testing/readiness.py` (ReadinessModel oracle), `host/testing/*` (modeled GitHub truth, World, coverage), the 11 journeys | `petrus-testing` DST v4 (`World`, `replay`, artifacts, `BudgetV4`) for the World; the oracle and journeys need none | oracle now; World after the DST port |
| 7 | `hamsterdan-export` | `host/export.py` evidence package | History codec | after 4 |
| 8 | `hamsterdan-operator` (optional) | `operator.py`, `publication_qualification.py` | none | any time. The Python operator can drive both hosts meanwhile, so this is the lowest priority. |
| — | `interop/hamsterdan/` (Python + Haskell harness) | tier A–C capture, replay and compare (§5.2) | follows 2–4 | capture side now |

**Suggested order:**
1. **Without Petrus:** contracts, Python literals, GitHub layer, oracle, and the
   tier-A capture tooling, which runs against the Python reference today.
2. **With the impetus kernel, DSL, CEL and `net_definition`:** the readiness
   net.
   - Gate it on the Net definition fingerprint (§1.3).
   - Gate it on per-loop fold unit tests using hand-fed tokens and expected
     output token JSON, harvested from Python.
3. **With the engine, History codec, JSONL store, Inline/LocalDispatch and
   Worker:** the host with a stub agent.
   - Gate it on tier A (11 journeys byte-exact) and cross-resume of Python state
     directories.
4. **With agenticus Pi A2 and the execution archive:** agents.
   - Gate it on workspace archive bytes and Pi A2 scripted-runtime tests.
   - Then tier B.
5. **With DST:** the World and campaigns.
6. **Tier C live comparison:** this is the PARITY "end to end" row.

**Haskell design latitude.** The deviation rules in [README.md](../README.md)
apply. These are natural places to diverge internally while keeping every wire
contract (webhook receipt, comment bodies and markers, History bytes, SQLite
schemas, environment variables, CLI JSON):
- STM instead of locks and polling;
- a typed `Claim`;
- GADT-indexed gate results instead of `$variant` dictionaries (still encoded
  with `$variant`).

## 7. Interop checklist

- [ ] Pydantic `dump_python(mode="json")` field order for all 106 models; `kind`
      last in typed facts; tuple→list; defaults always present.
- [ ] Python `repr`/`literal_eval` subset for dashboard entries and digests.
- [ ] CPython `json.dumps` variants used for digests (`sort_keys`, compact
      separators, `ensure_ascii` default; `allow_nan=False` on requests).
- [ ] `$variant` result encoding; refusal of subclasses and unknown variants.
- [ ] Operation-identity grammars and sha256 fallbacks.
- [ ] Delivery identity formats (§1.4).
- [ ] Timer instant format `%Y-%m-%dT%H:%M:%S.%fZ`.
- [ ] Engine selection order (`choose_throughput`, forced ingress folds).
- [ ] LocalDispatch schema v3 bytes; JSONL History schema 5.
- [ ] Webhook 202 receipt shape; 400 `{"detail"}`; header and body rules.
- [ ] Every REST path, query string and JSON body in §1.6, including
      `per_page` values and the compact JSON encoding.
- [ ] Comment markers, bodies, legacy-compatible bodies on lookup.
- [ ] Git publication: tree equality, trailers, author, parents shape,
      `clientMutationId` digest.
- [ ] `workspace_archive` bytes; `ResolutionSnapshot.to_data()` JSON.
- [ ] Environment variable names, retired-variable refusal, exit code 2 on
      configuration errors; CLI JSON outputs.

## 8. Open questions

1. **Tier C organization and Apps.** Do we register our own Apps in
   `seasonedcc`, or ask upstream for access to HBNetwork? *Partly answered:*
   the tooling assumes our own Apps in `seasonedcc`, registered through the
   manifest flow ([docs/e2e.md](e2e.md)). An owner still has to approve
   them.
2. **Which LLM provider key do we use for the real-agent smoke pass?** It must
   be a catalog pair. *Open:* the config defaults to production's
   `openai`/`gpt-5.6-sol`, and the key is the one input only the user can
   supply.
3. **Do we port the operator, or keep the Python one?** The Python operator
   needs parameterization either way. *Answered:* both are used. Each host's
   scenarios run through its own operator: the reference under a runtime
   overlay, and the port with the fixture as configuration.
4. **When does hamsterdan2 enter scope?** Upstream CV22 cutover would make a
   new net and storage layout production. If that lands before our port
   finishes, moving the Hamsterdan pin follows the UPSTREAM.md procedure.
