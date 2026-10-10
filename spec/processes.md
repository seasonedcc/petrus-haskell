# Process lifecycle protocol version 1: call and spawn

This document specifies the two process-lifecycle protocols that sit above
[Fabric](fabric.md):

- **call** delegates work to an *existing* addressed process and correlates one
  terminal result or error;
- **spawn** claims one *new*, independently durable child identity and has it
  provisioned as an authorized Fabric address.

The two are distinct protocols, not one API. A spawn followed by a call is
explicit composition. The goal of this document is that a Python Instance and
a Haskell Instance can call and spawn each other, and share one lineage
registry in one PostgreSQL database.

Upstream has no language-neutral specification for these protocols. This
document is derived from the pinned Python reference (`upstream/petrus` at
`3f85fc2094e50ece48bcf6bf9ace19cb0a22a544`, see [UPSTREAM.md](../UPSTREAM.md)):

- `src/petrus/processes/call.py`: call payloads and envelope helpers;
- `src/petrus/processes/model.py`: spawn values and child identity;
- `src/petrus/processes/spawn.py`: the `process.spawn` Activity;
- `src/petrus/processes/postgres.py`: the lineage registry;
- `tests/petrus/processes/test_processes.py` and
  `scripts/cv5-lifecycle-demo.py`: executable evidence;
- decision record
  `2026-07-21T0030Z-call-and-spawn-are-distinct-process-lifecycle-protocols`.

The conformance checklist for this document is
[processes-conformance.md](processes-conformance.md).

## 1 Status and conventions

Upstream labels Fabric and its call/spawn demonstrations "an unfinished
coordination prototype, subject to rewrite" and "historical evidence rather
than a supported distributed application layer"
(`docs/project/briefing.md`). This document pins version 1 as implemented at
the pin.

Normative language and the **CONTRACT** / **ACCIDENT** / **OPEN** markers are
as defined in [fabric.md §1](fabric.md). These rules are reused unchanged:

- Fabric text: [fabric.md §3.1](fabric.md);
- the strict JSON value model: §3.2;
- canonical JSON: §3.3;
- digests: §3.4;
- database JSON normalization: §3.5;
- the error categories (invalid, conflict, denied, not-found, schema-refused,
  storage): §12.

"Version-1 exact" decoding below always means:

- the value is a JSON object whose key set is *exactly* the listed names, with
  no missing and no extra members;
- `version` is the JSON integer `1` (`1.0` and `true` are refused);
- `kind`, where present, equals the listed string exactly;
- every text field satisfies Fabric text.

Exact decoding is what keeps these values provider-neutral and
credential-free. Extra members such as `"provider"` or `"credential"` are
refused (**CONTRACT**).

### 1.1 Revisions

These are changes made after the Haskell port ran every check against the
pinned reference. Each change makes this document say what the pinned
reference does.

- §7, the row "Reply arrives while no registration is armed": the refusal
  also poisons the refusing Engine, and the host continues through a fresh
  load ([fabric.md §9.3](fabric.md)). P-037 now says so. As first written,
  the check could not pass against the reference: reading the refusing
  Engine's records after the refusal raises.

## 2 Process identity and net Instances

A *process* is addressed by its Fabric process identity
([fabric.md §2](fabric.md)), which is the identity of exactly one
independently authoritative net Instance. A process address never names a
worker, runner, provider session, or location (glossary *Process address*).
In the reference compositions:

- the Engine of a process is created or loaded with Instance identity =
  Fabric process identity;
- its Fabric client is bound to the same string;
- a spawned child's Instance identity is its derived child identity (§10).

Each Instance's canonical History remains its own semantic truth. Fabric rows
are delivery truth, and lineage rows are identity-mapping truth. Neither is a
second semantic history.

# Part I: Call

## 3 Call payloads

A call has three payload kinds. Each is carried as the `payload` of a Fabric
Envelope v1, unchanged ([fabric.md §4.2](fabric.md)).

### 3.1 `process.call.request`

| Member | Type | Rule |
|---|---|---|
| `version` | integer | `1` |
| `kind` | string | `"process.call.request"` |
| `call_id` | Fabric text | the call identity, scoped to the caller (§4.3) |
| `operation` | Fabric text | application-defined operation name |
| `input` | JSON object | strict JSON. A non-object is refused (`TypeError`). |

The emitted member order is as listed. Order is not semantic.

### 3.2 `process.call.result`

| Member | Type | Rule |
|---|---|---|
| `version` | integer | `1` |
| `kind` | string | `"process.call.result"` |
| `call_id` | Fabric text | must equal the request's |
| `result` | any JSON value | strict JSON, including `null`, arrays, and scalars |

### 3.3 `process.call.error`

| Member | Type | Rule |
|---|---|---|
| `version` | integer | `1` |
| `kind` | string | `"process.call.error"` |
| `call_id` | Fabric text | must equal the request's |
| `code` | Fabric text | application-defined; v1 reserves no codes |
| `message` | Fabric text | human-readable |
| `details` | any JSON value | strict JSON. The default is `null` and the member is always present. |

`CallError` is the callee's *reported* failure. It is a successful protocol
outcome of the call, not a transport error. Example codes in upstream
evidence (`failed`, `refused`, `delegated-refusal`) are illustrative only.

All three payloads are Fabric payloads, so the 65536-byte inline limit applies
to their canonical encoding ([fabric.md §4.2.1](fabric.md)). Larger inputs or
results must travel by verified reference.

## 4 Call envelopes

### 4.1 Request envelope (CONTRACT)

| Envelope field | Value |
|---|---|
| `delivery_id` | default `"process-call-v1-request-" + hex(SHA-256(UTF-8(call_id)))` |
| `sender` | the caller |
| `recipient` | the callee |
| `source` | the callee's request source |
| `correlation` | `call_id` |
| `payload` | the `process.call.request` of §3.1 |
| `reply_route` | **required**, with `reply_route.instance_id == sender` |

Construction refuses a reply route that does not belong to the sender ("call
reply_route must belong to the sender process").

### 4.2 Reply envelope: result or error (CONTRACT)

Let `Q` be the request envelope and `C` its decoded request.

| Envelope field | Value |
|---|---|
| `delivery_id` | default `"process-call-v1-reply-" + hex(SHA-256(u32be(len(UTF-8(Q.sender))) ‖ UTF-8(Q.sender) ‖ UTF-8(call_id)))` |
| `sender` | the callee, which must equal `Q.recipient` |
| `recipient` | `Q.reply_route.instance_id`, which equals `Q.sender` |
| `source` | `Q.reply_route.source` |
| `correlation` | `call_id` |
| `payload` | the `process.call.result` of §3.2 or the `process.call.error` of §3.3 |
| `reply_route` | `null` |

`u32be(n)` is the 4-byte big-endian unsigned encoding of the caller's
**UTF-8 byte length**. This differs deliberately from the code-point length
used by the Fabric ingress identity ([fabric.md §4.2.3](fabric.md)).
Construction requires `result.call_id == C.call_id` and
`sender == Q.recipient`. It first validates `Q` by §5.1.

### 4.3 Identity consequences (CONTRACT)

- **The request identity is `(caller, request delivery id)`.** Because the
  default request id hashes only `call_id`, a caller MUST use each `call_id`
  for at most one request content. Reusing a `call_id` with a different callee,
  source, operation, input, or reply route conflicts at Fabric submission
  ([fabric.md §5.2](fabric.md)). Exact resubmission is a duplicate.
- **The reply identity is `(callee, reply delivery id)`.** The reply id hashes
  both caller and `call_id`, so the same `call_id` used by two different
  callers to one callee produces two distinct reply identities.
- **One terminal reply.** A result and an error for the same request share one
  reply delivery id. The first terminal reply the callee submits wins. Any
  different terminal reply for that request (an error after a result, or a
  changed result) is a Fabric **conflict** at the callee's submit, and the
  caller never sees it. Exact retransmission of the winning reply is a
  duplicate.
- Callers and callees MAY pass an explicit `delivery_id`. A non-default id is
  carried but never validated by the reply checks (§5.2), and it forfeits the
  one-terminal-reply guarantee unless the callee keeps it stable.
  **ACCIDENT:** Python treats an explicit empty string as "use the default".
- When defaults are used, both implementations MUST derive byte-identical ids,
  because a reply may be resubmitted by a different implementation after a
  host migration.

## 5 Call validation

### 5.1 Validating a request: `request_from_envelope(Q)` (CONTRACT)

These steps run in order. The first failure refuses the request (invalid):

1. Decode `Q.payload` as a version-1 exact `process.call.request` (§3.1).
2. `C.call_id == Q.correlation` ("payload must match the envelope
   correlation").
3. `Q.reply_route` is non-null ("call request must carry a reply route").
4. `Q.reply_route.instance_id == Q.sender` ("must reply to its sender
   process").

### 5.2 Validating a reply: `reply_from_envelope(R, request=Q)` (CONTRACT)

These steps run in order. The first failure refuses the reply (invalid):

1. Validate `Q` by §5.1.
2. Dispatch on `R.payload.kind`:
   - `process.call.result` decodes by §3.2;
   - `process.call.error` decodes by §3.3;
   - anything else is refused ("must be a process.call.result or
     process.call.error").
3. `reply.call_id == C.call_id` **and** `R.correlation == C.call_id`.
4. `R.sender == Q.recipient`, `R.recipient == Q.sender`, and
   `R.source == Q.reply_route.source` ("must come from the request callee
   through the requested reply route").
5. `R.reply_route` is null ("must not carry another reply route").

`R.delivery_id` is **not** checked. Authenticity of `R.sender` comes from
Fabric: only the authenticated callee can submit with `sender = callee`
([fabric.md §8.8](fabric.md)).

## 6 Call over Fabric: the end-to-end protocol

The sequence is as follows. Every Fabric step uses the operations of
[fabric.md §8](fabric.md).

1. **Authorization.** The callee exposes its request source and grants the
   caller on it. The caller exposes its reply source and grants the callee on
   it. A spawn provisioner does this for a spawned child (§13). For an
   existing process it is operator or application setup.
2. **Send the request.** An impure caller transition prepares the
   `fabric.send` Activity ([fabric.md §11](fabric.md)) with the request
   envelope. The invocation is frozen in the caller's History before the
   send. Fabric then stores the delivery. The Fabric receipt state means only
   that the callee's canonical ingress accepted the request, never that the
   call completed.
3. **Callee ingress.** The callee's inbox drain delivers one `FabricEnvelope`
   token to the callee's request source transition, with ingress identity
   `fabric:<len>:<caller>:<request id>`, and acknowledges it with the accepted
   occurrence.
4. **Callee work.** The callee's net decodes the request (§5.1), performs the
   operation, and an impure transition sends a result or error envelope (§4.2)
   through `fabric.send`.
5. **Caller ingress.** The caller's drain delivers the reply as a
   `FabricEnvelope` token to its reply source transition.
6. **Correlation.** The caller's net validates the reply against the original
   request envelope (§5.2) and joins it with its waiting state.

### 6.1 Reference net composition (RECOMMENDED; `cv5-lifecycle-demo.py`)

The wire contract is §3 to §5. The net shapes below are application-owned, and
two interoperating processes need not share them. They are recommended because
they make the call replay-safe.

**Caller.**

- At Instance creation, seal the reply source's `default` delivery
  registration, so replies are admitted only while a call is outstanding.
- The `call` transition is an impure Activity handler:
  - `prepare` returns `ActivityInvocation("fabric.send", input=Q.to_data(), correlation=Q.correlation, idempotency=Q.ingress_identity)`;
  - `project` emits a wait token (color `CallWait`, data
    `{"call_id": call_id, "submission": <fabric.send result>}`) and **opens**
    `DeliveryRegistration(reply_source, key=call_id)`.
- The `reply` source transition is pure:
  - if the reply payload's `call_id` is not the awaited call, it routes the
    token to an "unrelated" place and leaves the registration open;
  - otherwise it validates with §5.2, emits the token toward the join, and
    **closes** `DeliveryRegistration(reply_source, key=correlation)`.
- `join` consumes the wait token and the reply token and records the outcome
  `result` or `error` from `payload.kind`.

**Callee.**

- The request source transition keeps its `default` registration open, or
  closes it after one request for a one-shot callee.
- The `respond` transition is an impure Activity handler. It builds the reply
  with the §4.2 helpers and sends it through `fabric.send`.

Registration keys are bookkeeping only. A source admits a delivery whenever
**any** registration on it is armed. The kernel does not match keys against
the envelope's correlation, so the caller's handler MUST route by
correlation itself.

### 6.2 Replay

Because the request envelope and the reply are frozen facts in the caller's
and callee's Histories, reloading either Engine re-sends nothing and re-delivers
nothing. Upstream evidence: "replay: parent appends=0 dispatches=0; child
appends=0 dispatches=0". A re-dispatched `fabric.send` after a lost completion
is an exact Fabric duplicate.

## 7 Call failures, timeouts, and cancellation

| Situation | Observable outcome |
|---|---|
| Callee reports failure | an ordinary `process.call.error` reply; the caller's net decides its meaning |
| Callee sends a second, different terminal reply | Fabric **conflict** at the callee's submit, so its `fabric.send` Activity fails; the caller sees only the first reply |
| Reply for another call reaches an armed reply source | accepted into the caller's History. The application routes it (reference: "unrelated" place). It does not complete the awaited call. |
| Reply arrives while no registration is armed on the reply source (sealed, or already closed) | the caller's delivery door refuses it, so it stays pending and blocks the caller's inbox ([fabric.md §9.3](fabric.md)). The refusal also poisons the refusing Engine. The host continues through a fresh load, which refuses the same reply again and appends nothing. |
| Reply fails §5.2 inside the caller's handler | a firing failure in the caller, under [handler-contract.md](../upstream/petrus/spec/handler-contract.md). The drain attempt raises, and the delivery stays unacknowledged. Later redelivery is answered by the Engine's delivery door. The reference kernel removes the failed occurrence from in-flight, so it answers `PriorAcknowledgement` and Fabric then acknowledges. An Engine that halted on the failure refuses instead, which blocks the inbox. **OPEN:** whether a halted Engine should still acknowledge ended deliveries. |
| Request to an unexposed or ungranted source | Fabric **denied** at the caller's submit, so the `fabric.send` Activity fails |
| Callee not running | the request waits in Fabric as pending; it is delivered once a host drains the callee's inbox ("offline call: pending=1 parent=awaiting") |

**Timeouts and cancellation (CONTRACT: none in v1).** Version 1 has no timeout
field, no deadline, no cancel or abort payload kind, and no callee supervision.
A caller that wants a timeout models it with its own net timers. It must then
decide whether to keep its reply source armed, so late replies are absorbed by
its net, or to close it and accept the head-of-line blocking above. Upstream
defers cancellation, retirement, orphan recovery, timeout, and supervision to
later explicit policy.

## 8 Worked example: call round trip

The values below were produced by the reference implementation at the pin.
Setup: callee `callee` exposes `calls` and grants `caller`. Caller `caller`
exposes `replies` and grants `callee`.

**Request.** The request is
`CallRequest("call-1", "answer", {"question": 42})`, sent from `caller` to
`callee` on source `calls`, with reply route `(caller, replies)`. Its
delivery id is computed as follows:

```text
SHA-256("call-1") = 5d7963c4f471e142f5a72214a9666fb164718f9ba1066a7862ac1c5041887940
delivery_id       = process-call-v1-request-5d7963c4f471e142f5a72214a9666fb164718f9ba1066a7862ac1c5041887940
```

The envelope JSON form, digest
`e838ab15859a2bcadbb3d2c17fe2fcf8a7b0a5e62a0dcf3b8e2b969b1120990e`, and stored
row are given in [fabric.md §15.3](fabric.md).

**Callee ingress.** The callee's door is called with ingress identity
`fabric:6:caller:process-call-v1-request-5d7963c4…7940`. If it returns
occurrence 2, the row gets `accepted_occurrence = 2`.

**Result.** The result is `CallResult("call-1", {"answer": 42})`:

```text
reply id preimage = 00000006 63616c6c6572 63616c6c2d31       (u32be(6) ‖ "caller" ‖ "call-1")
delivery_id       = process-call-v1-reply-cc2a24e1ad965ab6d3ed917d5d448e43f5246556a710a74a57ee205ade2e2b6c
```

Its canonical bytes:

```json
{"correlation":"call-1","delivery_id":"process-call-v1-reply-cc2a24e1ad965ab6d3ed917d5d448e43f5246556a710a74a57ee205ade2e2b6c","payload":{"call_id":"call-1","kind":"process.call.result","result":{"answer":42},"version":1},"recipient":"caller","reply_route":null,"sender":"callee","source":"replies","version":1}
```

Its digest is `df7373fce36bfb17631813b24e8eda8885fed4f4b3510d18ac8cd66c54054b6f`,
and its ingress identity at the caller is
`fabric:6:callee:process-call-v1-reply-cc2a24e1…2b6c`.

**Error.** The error alternative is
`CallError("call-1", "delegated-refusal", "child refused delegated work")`.
It has the **same** delivery id, and these canonical bytes:

```json
{"correlation":"call-1","delivery_id":"process-call-v1-reply-cc2a24e1ad965ab6d3ed917d5d448e43f5246556a710a74a57ee205ade2e2b6c","payload":{"call_id":"call-1","code":"delegated-refusal","details":null,"kind":"process.call.error","message":"child refused delegated work","version":1},"recipient":"caller","reply_route":null,"sender":"callee","source":"replies","version":1}
```

Its digest is `a92c1070ced3ce5f8fab94c9b774cd3924a4d369fa506fb51fe9a93f6fbecd22`.
After the result was submitted, submitting this error fails with a Fabric
identity conflict.

**Final `impetus_fabric.deliveries` rows.** The `envelope` column is shown as
PostgreSQL renders it, and ids are abbreviated:

```text
('caller','process-call-v1-request-5d79…7940','callee','calls','call-1',
 {"sender": "caller", "source": "calls", "payload": {"kind": "process.call.request", "input": {"question": 42}, "call_id": "call-1", "version": 1, "operation": "answer"}, "version": 1, "recipient": "callee", "correlation": "call-1", "delivery_id": "…", "reply_route": {"source": "replies", "instance_id": "caller"}},
 'e838ab15…990e', accepted_occurrence=2, accepted_at=<t1>)
('callee','process-call-v1-reply-cc2a…2b6c','caller','replies','call-1',
 {"sender": "callee", "source": "replies", "payload": {"kind": "process.call.result", "result": {"answer": 42}, "call_id": "call-1", "version": 1}, "version": 1, "recipient": "caller", "correlation": "call-1", "delivery_id": "…", "reply_route": null},
 'df7373fc…4b6f', accepted_occurrence=5, accepted_at=<t2>)
```

# Part II: Spawn

## 9 SpawnSpec version 1

| Member | Type | Rule |
|---|---|---|
| `version` | integer | `1` |
| `parent` | Fabric text | the spawning process |
| `spawn_id` | Fabric text | stable, parent-scoped spawn identity |
| `process_kind` | Fabric text | application-defined kind; the reference provisioner uses it as the offered service name |
| `source` | Fabric text | the child's request source, which becomes its endpoint source |
| `capabilities` | JSON object | strict JSON; becomes the endpoint capabilities |
| `config` | JSON object | strict JSON; for the provisioner only |
| `reply_route` | ReplyRoute or `null` | if present, `instance_id` MUST equal `parent` ("spawn reply_route must belong to the parent process") |

- **Encoding (CONTRACT).** The JSON form has exactly these eight members.
  The reference emits them in the listed order. `reply_route` is always present
  and is `null` when absent.
- **Decoding.** Decoding is version-1 exact (§1). A non-object
  `capabilities` or `config` is refused (`TypeError`).
- **Spec digest (CONTRACT).** The digest is
  `hex(SHA-256(canonical(spec JSON form)))`. Every member participates:
  changing `process_kind`, `source`, `capabilities`, `config`, or
  `reply_route` changes the digest.

## 10 Child identity (CONTRACT)

```text
child_identity(parent, spawn_id) =
  "process-v1-" + hex(SHA-256( "impetus-process-child" ‖ 0x00 ‖ canonical({"version":1,"parent":parent,"spawn_id":spawn_id}) ))
```

The canonical object is key-sorted: `{"parent":…,"spawn_id":…,"version":1}`.
The result is always 75 ASCII characters. It depends **only** on
`(parent, spawn_id)`, never on the rest of the spec. Changing `process_kind`
keeps the child identity, and changing either key changes it.

Example:

```text
preimage = "impetus-process-child\0{\"parent\":\"parent\",\"spawn_id\":\"spawn-1\",\"version\":1}"
child    = process-v1-d2404af783c2bf50f6456e89c63e58067a6205fb5e23d3de79a411921c64ecad
```

The child identity is used, unchanged:

- as the child's Fabric process identity (`impetus_fabric.processes.instance_id`);
- as the child's net Instance identity;
- as the `recipient` of its endpoint.

## 11 The `process.spawn` Activity

### 11.1 Invocation (CONTRACT)

| Field | Value |
|---|---|
| `activity` | `"process.spawn"` |
| `input` | the SpawnSpec JSON form (§9) |
| `idempotency` | `"process.spawn:" + child_identity(parent, spawn_id)` |
| `correlation` | not checked. The reference composition uses `spawn_id`. |

The invocation is prepared by an impure parent transition and frozen in the
parent's History as `ActivityRequested`. Any worker, in either language, may
execute it.

### 11.2 Algorithm (CONTRACT, in order)

1. Refuse unless `activity == "process.spawn"` (invalid: "only implements
   'process.spawn'").
2. Decode `input` as a version-1 exact SpawnSpec (§9).
3. Refuse unless `idempotency == "process.spawn:" + spec.child` (invalid).
4. `claim = registry.claim(spec)` (§12.3). Refuse unless
   `(claim.parent, claim.spawn_id, claim.child) == (spec.parent, spec.spawn_id, spec.child)`
   (invalid: "registry returned a claim for a different identity"). The claim
   is durably committed **before** step 6.
5. `endpoint = Endpoint(recipient = claim.child, source = spec.source, capabilities = spec.capabilities)`.
6. `provisioner.ensure(Provisioning(parent, spawn_id, child, process_kind, endpoint, config, reply_route))`.
   `ensure` MUST return nothing. A returned value is refused (invalid:
   "never a live host or credential") **after** `ensure` has already run.
7. Return the SpawnOutcome JSON form (§11.3), which is frozen as the Activity
   result.

Any exception from steps 4 to 6 propagates as an Activity failure, governed by
the execution policy. Because steps 4 and 6 are idempotent, every retry of the
same frozen invocation re-claims, gets `prior_claim = true`, and re-ensures.
Upstream evidence: "spawn retry: claims=1 ensure_calls=2 prior_claim=true".

### 11.3 SpawnOutcome version 1 (CONTRACT)

```json
{"version":1,"parent":"…","spawn_id":"…","child":"…","endpoint":{"recipient":"…","source":"…","capabilities":{…}},"prior_claim":false}
```

- Decoding is version-1 exact. The `endpoint` is decoded as an exact Endpoint
  ([fabric.md §4.3](fabric.md)).
- `prior_claim` must be a JSON boolean (`TypeError` otherwise).
- `child` must equal `child_identity(parent, spawn_id)`.
- `endpoint.recipient` must equal `child` ("must address the child process").
- `prior_claim` is `false` only for the attempt that inserted the lineage row,
  and `true` for every later attempt.

The outcome value can therefore differ between attempts. Only the first
terminal result is accepted into the parent's History. When the first
attempt's completion is lost, the recorded outcome has `prior_claim: true`
(**CONTRACT**, upstream evidence).

**Spawn success means only** that the child identity is durably claimed and
its address is registered and authorized. It does **not** mean that a host
started, that the child's History exists, or that the child ran or completed
(DR 2026-07-21). Upstream evidence: "child history before host open: 0".

## 12 Lineage registry

### 12.1 Storage schema version 1 (CONTRACT)

```sql
CREATE SCHEMA IF NOT EXISTS impetus_lifecycle;
CREATE TABLE IF NOT EXISTS impetus_lifecycle.schema_metadata (component text PRIMARY KEY, version integer NOT NULL);
CREATE TABLE IF NOT EXISTS impetus_lifecycle.spawns (
    parent text NOT NULL, spawn_id text NOT NULL, child text NOT NULL UNIQUE,
    spec_digest text NOT NULL, created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (parent, spawn_id));
```

The statements execute in this order. The resulting objects are:

- `spawns_pkey (parent, spawn_id)`;
- `spawns_child_key UNIQUE (child)`;
- `schema_metadata_pkey`;
- the row `('lifecycle', 1)`.

The column order is exactly `parent, spawn_id, child, spec_digest, created_at`
(tested). The registry is **mapping-only**: it has no status, host, credential,
or lifecycle-state column, and there MUST NOT be one in version 1. The
registry has no foreign key to `impetus_fabric`. Its authentication still
requires the Fabric schema (§12.3).

### 12.2 Provisioning protocol (`ensure_lifecycle_schema`) (CONTRACT)

Provisioning runs on the caller's connection and never commits on the
caller's behalf (tested: rollback leaves no `impetus_lifecycle` namespace).
The steps are:

1. `SELECT 1 FROM pg_namespace WHERE nspname = 'impetus_lifecycle'`.
2. If the schema exists and `to_regclass('impetus_lifecycle.schema_metadata')`
   is `NULL`, check whether `to_regclass('impetus_lifecycle.spawns')` is
   non-null. If it is, refuse (schema-refused: "unversioned spawns table:
   refusing unknown shape").
3. Execute the §12.1 DDL.
4. `INSERT INTO impetus_lifecycle.schema_metadata (component, version) VALUES ('lifecycle', 1) ON CONFLICT DO NOTHING`.
5. Read `version` for `'lifecycle'`. If it is absent or not 1, refuse
   (schema-refused, naming the version and "migrate deliberately").

### 12.3 Registry operations

A registry is bound to `(connection, parent, credential)`.

- **The connection MUST be autocommit** (**CONTRACT**). Construction refuses a
  non-autocommit connection (invalid). The point is that every claim is
  committed before `claim` returns, and so before provisioning. A second
  implementation MUST equally guarantee that the claim row is durably committed
  before `ensure` runs.
- **Authentication** is the Fabric authentication step
  ([fabric.md §8.2](fabric.md)) with `instance = parent`. The parent MUST be
  a registered Fabric process. Failure is denied ("lifecycle authentication
  failed for '<parent>'").

**`claim(spec)`.** Before any database access, `spec.parent` must equal the
bound parent (denied: "spawn parent must match the authenticated registry").
Then authentication, followed by these statements, each autocommitted:

```sql
INSERT INTO impetus_lifecycle.spawns (parent, spawn_id, child, spec_digest)
VALUES ($parent, $spawn_id, $child, $spec_digest) ON CONFLICT DO NOTHING;     -- (a)
SELECT child, spec_digest FROM impetus_lifecycle.spawns
 WHERE parent = $parent AND spawn_id = $spawn_id;                               -- (b)
```

- If (b) finds no row, or `(child, spec_digest) ≠ (spec.child, spec.digest)`,
  the result is **conflict** ("spawn identity conflict for (parent, spawn_id):
  content changed"). Nothing is written, and the original row stays.
- Otherwise the result is `SpawnClaim(parent, spawn_id, child, prior_claim)`,
  where `prior_claim` is true iff (a) inserted no row.
- Concurrent exact claims converge on one row. Exactly one of them reports
  `prior_claim = false` (tested with two connections).
- **ACCIDENT:** (a) has no conflict target. A `child` unique violation without
  a primary-key conflict is only possible through a SHA-256 collision, and
  then surfaces as a conflict through (b).

**Lineage queries** are all parent-bound:

```sql
-- child_of(parent, spawn_id), where parent must equal the bound parent (denied otherwise; checked before auth)
SELECT child FROM impetus_lifecycle.spawns WHERE parent = $parent AND spawn_id = $spawn_id;
-- children_of(parent), with the same binding rule
SELECT spawn_id, child FROM impetus_lifecycle.spawns WHERE parent = $parent ORDER BY spawn_id;
-- parent_of(child), after authentication
SELECT parent, spawn_id FROM impetus_lifecycle.spawns WHERE child = $child;
--   no row: absent; parent ≠ bound parent: denied ("child does not belong to the authenticated parent")
```

The results are `Lineage(parent, spawn_id, child)` values. A Lineage is
invalid unless `child == child_identity(parent, spawn_id)`. The order of
`children_of` is the database collation order of `spawn_id`.

**ACCIDENT:** `parent_of` distinguishes "absent" from "denied" for another
parent's child, which reveals that the child exists. Implementations SHOULD
match this anyway for interop tests, but MUST NOT build on it.

## 13 Provisioner port

### 13.1 Contract

`ensure(provisioning) -> nothing`. The input carries:

- `parent`, `spawn_id`, `child` (= `child_identity(parent, spawn_id)`);
- `process_kind`;
- `endpoint` (recipient = child);
- `config`;
- `reply_route` (owned by the parent, or `null`).

The port has these obligations:

- **Exact-retry safe and convergent (CONTRACT).** `ensure` may run any number
  of times for one claim, including after a crash or failure part-way, and
  must converge to the same end state.
- **Returns nothing.** No live host, connection, worker, provider session, or
  credential crosses back into the parent. Credentials never appear in
  Activity inputs, outcomes, envelopes, or History. Upstream evidence:
  "credential absent from outcomes/envelopes/history: true".
- **Postcondition** (the DR's "address is durably registered and
  authorized"): when `ensure` returns,
  1. the child is a registered Fabric process;
  2. the child has exposed `endpoint.source`;
  3. the parent is granted on `(child, endpoint.source)`;
  4. if `reply_route` is non-null, the parent has exposed
     `reply_route.source` and the child is granted on it.

  The generic Activity does not verify these. They are the provisioner's
  obligation, and an interop suite SHOULD check them after spawn.

### 13.2 Reference provisioning profile (RECOMMENDED; `cv5-lifecycle-demo.py`)

The reference profile performs these steps in order, each idempotent:

```text
register_process(child, child_credential)
child.expose_source(endpoint.source)
child.offer_service(endpoint.source, process_kind, endpoint.capabilities)
child.grant(parent, endpoint.source)
if reply_route:
    parent.expose_source(reply_route.source)
    parent.grant(child, reply_route.source)
```

The service offer under `process_kind` makes the child discoverable to the
parent. It is part of the profile, not of the postcondition. Credential
derivation is provisioner territory. The demo derives
`base64url(HMAC-SHA256(workspace_key, child))` so that retries re-register
with an identical credential. That derivation is **ACCIDENT**, but some
deterministic or stored credential is necessary, because re-registration with
a different credential is a Fabric conflict ([fabric.md §8.3](fabric.md)).

## 14 Spawn and net Instances

- The parent's spawn transition is an impure Activity handler. `prepare`
  returns the §11.1 invocation, and `project` decodes the SpawnOutcome and
  produces it as a token (reference color `SpawnReady`, data = outcome JSON).
- Spawning creates **no** child History and starts no child Engine. A host
  later creates the child Instance under Instance identity `child`, using the
  provisioner's credential for its Fabric client. Until then, calls to the
  child wait in Fabric as pending deliveries.
- Spawn followed by call: the call's `recipient` is `outcome.child`, its
  `source` is `outcome.endpoint.source`, and its reply route is the spec's
  `reply_route`.
- Version 1 defines no child status, retirement, cancellation, orphan
  recovery, re-parenting, or supervision. Neither a lineage row nor a Fabric
  receipt implies any of them.

### 14.1 Crash windows (CONTRACT behavior)

| Crash point | Recovery |
|---|---|
| Before the claim commits | Retry claims fresh: `prior_claim = false`. |
| After the claim, before or inside `ensure` | Retry re-claims (`prior_claim = true`) and re-ensures. Tested: the first `ensure` raises and the retry succeeds with `attempts == [child, child]`. |
| After `ensure`, before `ActivityCompleted` | Re-dispatch re-claims and re-ensures. The outcome has `prior_claim = true`. Exactly one lineage row and one Fabric registration remain. |
| A changed spec under the same `(parent, spawn_id)` | **Conflict** before provisioning. The original claim and provisioning are untouched. |

## 15 Worked example: spawn

The values below were produced by the reference implementation at the pin.
The spec is:

```text
SpawnSpec(parent="parent", spawn_id="spawn-1", process_kind="analysis-agent", source="calls",
          capabilities={"protocol":"call-v1"}, config={"role":"agent"},
          reply_route=ReplyRoute("parent","replies"))
```

Its canonical bytes:

```json
{"capabilities":{"protocol":"call-v1"},"config":{"role":"agent"},"parent":"parent","process_kind":"analysis-agent","reply_route":{"instance_id":"parent","source":"replies"},"source":"calls","spawn_id":"spawn-1","version":1}
```

The derived values are:

```text
spec digest  = 8b6ffab905673be4a0de33b1ea8b3c9e3715412694f21fa6051633fd63cea3c2
child        = process-v1-d2404af783c2bf50f6456e89c63e58067a6205fb5e23d3de79a411921c64ecad
idempotency  = process.spawn:process-v1-d2404af783c2bf50f6456e89c63e58067a6205fb5e23d3de79a411921c64ecad
```

The lineage row is:

```text
impetus_lifecycle.spawns:
('parent', 'spawn-1', 'process-v1-d2404af7…ecad', '8b6ffab9…a3c2', <created_at>)
```

The first-attempt outcome:

```json
{"version":1,"parent":"parent","spawn_id":"spawn-1","child":"process-v1-d2404af783c2bf50f6456e89c63e58067a6205fb5e23d3de79a411921c64ecad","endpoint":{"recipient":"process-v1-d2404af783c2bf50f6456e89c63e58067a6205fb5e23d3de79a411921c64ecad","source":"calls","capabilities":{"protocol":"call-v1"}},"prior_claim":false}
```

A retry produces the same outcome with `"prior_claim":true`. After the
reference provisioner runs, the database holds:

- `processes`: a row for the child;
- `exposed_sources`: `(child, calls)` and `(parent, replies)`;
- `service_offers`: `(child, calls, analysis-agent, {"protocol":"call-v1"})`;
- `delivery_grants`: `(parent → child, calls)` and `(child → parent, replies)`.

A call to the child is then the §8 round trip, with
`recipient = process-v1-d2404af7…ecad`.

## 16 Versioning

- The `version` member is `1` in `process.call.*` payloads, SpawnSpec, and
  SpawnOutcome, decoded exactly.
- The id prefixes `process-call-v1-request-`, `process-call-v1-reply-`, and
  `process-v1-`, the domain separator `impetus-process-child\0`, and the
  idempotency prefix `process.spawn:` are version-1 constants.
- The Activity name is `process.spawn`.
- `impetus_lifecycle.schema_metadata('lifecycle').version` is `1`, with no
  implicit migration.
- Any change is a new protocol version and moves the upstream pin
  ([UPSTREAM.md](../UPSTREAM.md)).

## 17 Implementation accidents and non-contract details

| Python behavior | Classification | Guidance |
|---|---|---|
| Explicit empty `delivery_id` falls back to the default | ACCIDENT | treat empty as invalid or as default; never send it |
| Provisioner return value refused only after `ensure` ran | ACCIDENT (ordering) | the refusal itself is CONTRACT |
| `parent_of` reveals another parent's child exists | ACCIDENT | §12.3 |
| Claim `ON CONFLICT` without a target | ACCIDENT | §12.3 |
| Demo credential derivation via HMAC | ACCIDENT | §13.2 |
| Net shapes, token colors `CallWait`, `SpawnReady`, `CallDone`, place names | application convention | §6.1 is RECOMMENDED only |
| Telemetry `lifecycle_claimed`, `lifecycle_conflict`, `lifecycle_denied` | informative | MAY be mirrored |
| Python exception classes and messages | informative | the categories are CONTRACT ([fabric.md §12](fabric.md)) |
