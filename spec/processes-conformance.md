# Process lifecycle conformance checklist (call and spawn, version 1)

This list enumerates the testable obligations of [processes.md](processes.md).
The format matches [fabric-conformance.md](fabric-conformance.md):

- each check has an identifier and a level (`unit`, `db`, `engine`, or
  `interop`), followed by the spec section it verifies;
- the upstream evidence follows in parentheses. `test_processes::name` means
  `tests/petrus/processes/test_processes.py`, and `demo` means
  `scripts/cv5-lifecycle-demo.py`;
- outcome categories are those of [fabric.md §12](fabric.md).

## A Call payloads

- **P-001** `unit` §3.1. `CallRequest("call-1", "answer", {"nested":[1]})`
  encodes to `{"version":1,"kind":"process.call.request","call_id":"call-1","operation":"answer","input":{"nested":[1]}}`,
  and decoding it gives back an equal value.
  *(test_processes::test_call_values_are_exact_detached_and_provider_neutral)*
- **P-002** `unit` §3.1. `input` is detached and immutable, and a non-object
  `input` is refused. *(test_processes::test_call_values_are_exact…)*
- **P-003** `unit` §1, §3. Request decoding is refused (invalid) for:
  - an extra member (`"provider": "claude"`);
  - a missing member;
  - `version` of 2, `1.0`, or `true`;
  - a `kind` other than `process.call.request`.

  *(test_processes::test_call_values_are_exact…; variants derived)*
- **P-004** `unit` §3.2. Any JSON `result` is accepted, including
  `[1, {"ok": true}]`, `null`, and scalars, and round-trips. A non-finite
  float is refused ("strict JSON").
  *(test_processes::test_call_values_are_exact…)*
- **P-005** `unit` §3.3. `CallError` defaults `details` to `null` and always
  emits it. `CallError("call-1","refused","no",{"retry":false})` round-trips.
  An empty or non-string `code` or `message` is refused.
  *(test_processes::test_call_values_are_exact…; refusals derived)*
- **P-006** `unit` §3. The kind strings are exactly `process.call.request`,
  `process.call.result`, and `process.call.error`. Each decoder refuses the
  other kinds. *(derived)*

## B Call envelopes and identities

- **P-007** `unit` §4.1. The default request delivery id is
  `process-call-v1-request-` followed by the SHA-256 hex of `call_id`:
  - `call-1` gives
    `process-call-v1-request-5d7963c4f471e142f5a72214a9666fb164718f9ba1066a7862ac1c5041887940`;
  - `c-é` gives
    `process-call-v1-request-5024ad417352781fc1bbf47e59357db7908dd4f9607f6eac499c85323e237a5f`.

  *(derived)*
- **P-008** `unit` §4.1. The request envelope has `correlation = call_id`.
  A reply route whose `instance_id` is not the sender is refused ("belong to
  the sender"). *(test_processes::test_call_helpers_refuse_mismatched_correlation_sender_and_reply_owner)*
- **P-009** `unit` §4.1. The §8 request envelope has digest
  `e838ab15859a2bcadbb3d2c17fe2fcf8a7b0a5e62a0dcf3b8e2b969b1120990e`.
  *(derived)*
- **P-010** `unit` §4.2. The default reply delivery id prefixes the caller
  with its UTF-8 byte length as a big-endian u32:
  - caller `caller` with call `call-1` gives
    `process-call-v1-reply-cc2a24e1ad965ab6d3ed917d5d448e43f5246556a710a74a57ee205ade2e2b6c`;
  - caller `é` with call `c-é` hashes the preimage `00000002c3a9632dc3a9` and
    gives
    `process-call-v1-reply-58993fa106ffeef14b0dbb8c0f753da1e4c4005f60905ef78a5fb28b18f02e6f`.

  *(derived)*
- **P-011** `unit` §4.2. The result envelope has:
  - `recipient` = the reply route's instance and `source` = the reply route's
    source (`("parent","replies")` in the fixture);
  - `correlation` = `call_id`;
  - `reply_route = null`.

  The §8 result envelope has digest
  `df7373fce36bfb17631813b24e8eda8885fed4f4b3510d18ac8cd66c54054b6f`.
  *(test_processes::test_call_envelopes_are_correlated_addressed_and_share_one_terminal_reply_identity)*
- **P-012** `unit` §4.2–4.3. The result and error envelopes for one request
  share a delivery id and have different digests. The §8 error envelope has
  digest `a92c1070ced3ce5f8fab94c9b774cd3924a4d369fa506fb51fe9a93f6fbecd22`.
  *(test_processes::test_call_envelopes_are_correlated…)*
- **P-013** `unit` §4.2. Building a result whose `call_id` differs from the
  request is refused ("correlate"). *(test_processes::test_call_helpers_refuse…)*
- **P-014** `unit` §4.2. Building a result with a sender other than the
  request recipient is refused ("correlate"). *(test_processes::test_call_helpers_refuse…)*
- **P-015** `unit` §4.2, §5.1. Building a result for a malformed request,
  whose envelope correlation `other` differs from its payload `call-1`, is
  refused ("payload … correlation"). *(test_processes::test_call_helpers_refuse…)*
- **P-016** `unit` §4.3. An explicit non-empty `delivery_id` overrides the
  default for requests, results, and errors. *(derived)*

## C Call validation

- **P-017** `unit` §5.1. A request whose correlation differs from its
  payload `call_id` is refused. *(test_processes::test_call_helpers_refuse…)*
- **P-018** `unit` §5.1. A request without a reply route is refused.
  *(derived)*
- **P-019** `unit` §5.1. A request whose reply route belongs to someone other
  than the sender is refused. *(derived)*
- **P-020** `unit` §5.2. A valid result reply decodes to a result, and a
  valid error reply to an error. *(test_processes::test_call_envelopes_are_correlated…)*
- **P-021** `unit` §5.2. A reply payload of any other kind is refused.
  *(derived)*
- **P-022** `unit` §5.2. A reply whose envelope correlation is `other` while
  its payload `call_id` is `call-1` is refused ("payload … correlation").
  *(test_processes::test_call_helpers_refuse…)*
- **P-023** `unit` §5.2. A reply whose payload `call_id` differs from the
  request's is refused. *(derived)*
- **P-024** `unit` §5.2. A reply from `sibling` instead of the callee is
  refused ("request callee"), even though it uses the derived reply delivery
  id. *(test_processes::test_call_helpers_refuse…)*
- **P-025** `unit` §5.2. A reply addressed to a recipient other than the
  caller, or arriving on a source other than the reply route's, is refused.
  *(derived)*
- **P-026** `unit` §5.2. A reply carrying a reply route is refused.
  *(derived)*
- **P-027** `unit` §5.2. A reply with a custom, non-default delivery id that
  satisfies every other rule is accepted, because the delivery id is not
  checked. *(derived)*

## D Call identity over Fabric

- **P-028** `db` §4.3. After the callee submits a result, submitting an error
  for the same request is a Fabric conflict. *(test_processes::test_call_result_and_error_share_fabric_conflict_identity)*
- **P-029** `db` §4.3. The same `call_id` from two callers yields different
  reply delivery ids, and both replies submit fresh (`duplicate = false`).
  *(test_processes::test_call_result_and_error_share_fabric_conflict_identity)*
- **P-030** `db` §4.3. A caller that reuses a `call_id` with different request
  content (another callee, operation, or input) gets a Fabric conflict at
  submission. *(derived)*
- **P-031** `db` §4.3. Exact retransmission of a reply is a duplicate.
  *(derived)*

## E Call end to end

- **P-032** `engine` §6, §7. While the callee host is down, the request is
  pending (count 1) and the caller is AWAITING. *(test_processes::test_process_lifecycle_acceptance_demo, "offline call: pending=1 parent=awaiting")*
- **P-033** `engine` §6.1, §7. A reply for an unrelated `call_id`, delivered
  while the reply registration is armed, is accepted, and the caller stays
  AWAITING. *(demo "unrelated correlation: parent=awaiting")*
- **P-034** `engine` §6. A correlated result completes both caller and
  callee. *(demo "correlated result: parent=completed child=completed")*
- **P-035** `engine` §6, §7. A correlated error completes the caller with
  outcome `error`. *(demo "correlated error: parent=completed outcome=error")*
- **P-036** `engine` §6.2. Reopening both Engines after completion appends 0
  records and dispatches 0 Activities. *(demo "replay: parent appends=0 dispatches=0; child appends=0 dispatches=0")*
- **P-037** `engine` §7. A reply delivered to a reply source with no armed
  registration is refused by the caller's door, stays pending, and blocks the
  caller's inbox. *(derived)*
- **P-038** `interop` §3–6. A Python caller with a Haskell callee, and a
  Haskell caller with a Python callee, each complete both a result round trip
  and an error round trip. Each side validates the other's envelopes with
  §5. *(derived)*

## F Spawn values

- **P-039** `unit` §9. SpawnSpec JSON has exactly the eight members, and
  decoding it gives back an equal value. Its `config` is detached and
  immutable.
  *(test_processes::test_spawn_spec_is_exact_detached_strict_and_fully_digested)*
- **P-040** `unit` §9. The spec digest changes when `config`, `source`,
  `capabilities`, `process_kind`, or `reply_route` changes.
  *(test_processes::test_spawn_spec_is_exact…; process_kind and reply_route derived)*
- **P-041** `unit` §9. An extra member (`"credential": …`) is refused
  ("exact version-1"). *(test_processes::test_spawn_spec_is_exact…)*
- **P-042** `unit` §9. A NaN in `config` is refused ("strict JSON").
  *(test_processes::test_spawn_spec_is_exact…)*
- **P-043** `unit` §9. A reply route owned by someone other than the parent
  is refused ("belong to the parent"). *(test_processes::test_spawn_spec_is_exact…)*
- **P-044** `unit` §9. A non-object `capabilities` or `config` is refused,
  and so is a `version` that is not the integer 1. *(derived)*
- **P-045** `unit` §9, §15. The §15 spec has canonical bytes
  `{"capabilities":{"protocol":"call-v1"},"config":{"role":"agent"},"parent":"parent","process_kind":"analysis-agent","reply_route":{"instance_id":"parent","source":"replies"},"source":"calls","spawn_id":"spawn-1","version":1}`
  and digest
  `8b6ffab905673be4a0de33b1ea8b3c9e3715412694f21fa6051633fd63cea3c2`.
  *(derived)*
- **P-046** `unit` §10. Child identity vectors:
  - `child_identity("parent","spawn-1")` is
    `process-v1-d2404af783c2bf50f6456e89c63e58067a6205fb5e23d3de79a411921c64ecad`;
  - `child_identity("pai/é","spawn\n😀")` is
    `process-v1-46c4213496ebb26fcfad46ad7d181d60377de58df89d012d08235b2c94e6df64`.

  *(derived)*
- **P-047** `unit` §10. The child identity:
  - does not change when `process_kind` changes;
  - changes when `parent` or `spawn_id` changes;
  - starts with `process-v1-` and is 75 characters long.

  *(test_processes::test_child_identity_is_stable_parent_scoped_and_not_spec_scoped)*
- **P-048** `unit` §11.1. `spawn_idempotency("parent","spawn-1")` is
  `process.spawn:process-v1-d2404af783c2bf50f6456e89c63e58067a6205fb5e23d3de79a411921c64ecad`.
  *(derived)*
- **P-049** `unit` §11.3. SpawnOutcome:
  - round-trips;
  - refuses an extra member (`"credential"`) as "exact version-1";
  - refuses a non-boolean `prior_claim`;
  - refuses an endpoint that does not address the child ("address the
    child");
  - refuses a child that does not match `child_identity`.

  *(test_processes::test_spawn_outcome_and_provisioning_refuse_cross_identity_values)*
- **P-050** `unit` §11.2, §12.3. Provisioning, SpawnClaim, and Lineage refuse a
  child that does not equal `child_identity(parent, spawn_id)`
  ("parent-scoped"). Provisioning also refuses an endpoint whose recipient is
  not the child. *(test_processes::test_spawn_outcome_and_provisioning_refuse…)*

## G The `process.spawn` Activity

- **P-051** `unit` §11.2. An invocation with an activity name other than
  `process.spawn` is refused ("only implements"). *(test_processes::test_spawn_activity_refuses_wrong_activity_idempotency_or_registry_identity)*
- **P-052** `unit` §11.2. A wrong `idempotency` is refused.
  *(test_processes::test_spawn_activity_refuses_wrong…)*
- **P-053** `unit` §11.2. A registry claim for a different identity is
  refused ("different identity"), and the provisioner is never invoked.
  *(test_processes::test_spawn_activity_refuses_wrong…)*
- **P-054** `unit` §11.2–11.3. Two invocations of one exact invocation produce
  the event order `claim, ensure, claim, ensure`. The outcomes have
  `prior_claim` false then true, with the same child.
  *(test_processes::test_spawn_activity_claims_before_ensure_and_reensures_an_exact_retry)*
- **P-055** `unit` §11.2. A provisioner that returns a value is refused
  ("never a live host or credential"). *(test_processes::test_spawn_activity_refuses_a_live_object_from_the_provisioner)*
- **P-056** `unit` §11.2, §13.1. The provisioner receives a Provisioning with:
  - no credential field;
  - `endpoint = (child, spec.source, spec.capabilities)`;
  - the spec's `config` and `reply_route`.

  *(test_processes::test_spawn_activity_claims_before_ensure…; test_spawn_outcome_and_provisioning…)*
- **P-057** `db` §14.1. When the first `ensure` raises after the claim, the
  retry succeeds with `prior_claim = true`, and `ensure` saw the same child
  twice. *(test_processes::test_failed_provision_after_claim_retries_the_same_claim)*
- **P-058** `unit` §15. The first-attempt outcome JSON equals the §15 bytes,
  and the retry differs only in `"prior_claim":true`. *(derived)*

## H Lineage registry storage

- **P-059** `db` §12.1. The columns of `impetus_lifecycle.spawns` are exactly
  `(parent, spawn_id, child, spec_digest, created_at)`, in that order. The
  table has `spawns_pkey (parent, spawn_id)` and `spawns_child_key UNIQUE (child)`.
  *(test_processes::test_lifecycle_schema_is_mapping_only_versioned_and_refuses_unknown_shapes; constraints derived)*
- **P-060** `db` §12.2. A pre-existing unversioned
  `impetus_lifecycle.spawns (unknown text)` is refused (schema-refused).
  *(test_processes::test_lifecycle_schema_is_mapping_only…)*
- **P-061** `db` §12.2. `schema_metadata('lifecycle').version = 999` is refused
  (schema-refused, reporting 999). *(test_processes::test_lifecycle_schema_is_mapping_only…)*
- **P-062** `db` §12.2. Provisioning in a non-autocommit transaction followed
  by a rollback leaves no `impetus_lifecycle` namespace.
  *(test_processes::test_lifecycle_schema_provisioning_does_not_commit_the_callers_transaction)*
- **P-063** `db` §12.2. Provisioning is idempotent, and `schema_metadata`
  contains exactly `('lifecycle', 1)`. *(derived)*
- **P-064** `db` §12.3. Constructing a registry on a non-autocommit
  connection is refused. *(test_processes::test_postgres_registry_requires_autocommit_and_authentication)*
- **P-065** `db` §12.3. A registry with the wrong credential is denied on
  claim ("lifecycle authentication"). *(test_processes::test_postgres_registry_requires_autocommit…)*
- **P-066** `db` §12.3. Claiming a spec whose `parent` is not the bound
  parent is denied. *(test_processes::test_postgres_registry_requires_autocommit…)*
- **P-067** `db` §12.3. The first claim returns
  `SpawnClaim("parent","spawn-1",child,false)` and the second returns `…,true`.
  The single row is `(parent, spawn_id, child, spec.digest)`.
  *(test_processes::test_postgres_claim_is_durable_exact_conflict_detecting_and_queryable)*
- **P-068** `db` §12.3. A claim with changed content (a different `config`) is
  a conflict ("content changed"), and the row count stays 1.
  *(test_processes::test_postgres_claim_is_durable…)*
- **P-069** `db` §12.3. After the claim:
  - `child_of("parent","spawn-1")` and `parent_of(child)` return the lineage;
  - `children_of("parent")` returns exactly that one lineage.

  *(test_processes::test_postgres_claim_is_durable…)*
- **P-070** `db` §12.3. Lineage queries are parent-bound. Another parent's
  registry:
  - is denied on `child_of("parent", …)` ("parent must match");
  - is denied on `parent_of(child)` ("does not belong");
  - gets absent from `parent_of` for an unknown child.

  *(test_processes::test_lineage_queries_are_parent_bound; absent derived)*
- **P-071** `db` §12.3. Two concurrent exact claims on two connections
  produce `prior_claim` values `{false, true}` and a single child.
  *(test_processes::test_concurrent_exact_claims_converge_on_one_row)*
- **P-072** `db` §11.2, §12.3. The claim row is visible from an independent
  connection while `ensure` is running, because it was committed before
  provisioning. *(derived)*

## I Provisioner postconditions

- **P-073** `db` §13.1–13.2. After a spawn with a reference-profile
  provisioner:
  - the child is registered;
  - `(child, endpoint.source)` is exposed, and the parent is granted on it;
  - an offer exists under `process_kind` with the spec capabilities;
  - `(parent, reply_route.source)` is exposed, and the child is granted on it.

  *(demo DemoProvisioner)*
- **P-074** `db` §13.1. Re-running `ensure` for the same claim converges with
  no error and the same rows. That needs a deterministic or stored child
  credential. *(demo "claims=1 ensure_calls=2")*
- **P-075** `engine` §13.1. Child credentials appear in no spawn outcome,
  Fabric envelope, or parent or child History record. *(demo "credential absent from outcomes/envelopes/history: true")*

## J Spawn and net Instances

- **P-076** `engine` §11.3, §14. After a successful spawn and before any child
  host opens, the child's History is empty (size 0).
  *(demo "child history before host open: 0")*
- **P-077** `engine` §14.1. When the first spawn completion is lost and the
  Activity is re-dispatched:
  - there is exactly 1 claim row, 1 child registration, and 2 `ensure`
    calls;
  - the outcome recorded in the parent's History has `prior_claim = true`.

  *(demo "spawn retry: claims=1 ensure_calls=2 prior_claim=true")*
- **P-078** `engine` §14. Spawn followed by call: a call to `outcome.child`
  on `outcome.endpoint.source` is pending while the child is offline. Once a
  host opens the child Engine with Instance identity = child identity, the
  call completes. *(demo)*
- **P-079** `interop` §11–14. A `process.spawn` Activity requested by a Python
  parent Engine is executed by a Haskell worker, and the reverse, against one
  shared lineage and Fabric database. The outcome JSON is equal as a JSON value to the
  reference outcome, so the two are canonically byte-identical. *(derived)*
- **P-080** `interop` §14.1. A spawn whose first attempt runs in one
  implementation and whose retry runs in the other converges: one lineage
  row, `prior_claim = true`, and an identical child identity and endpoint.
  *(derived)*

Total: 80 checks.
