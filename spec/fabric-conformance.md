# Fabric conformance checklist (protocol version 1)

This list enumerates the testable obligations of [fabric.md](fabric.md). The
Haskell implementation is tested against each check. Checks marked
**interop** run the Python reference (`upstream/petrus` at the pin) and the
Haskell implementation against one shared PostgreSQL database.

Each check gives:

- its identifier;
- its level:
  - `unit`: pure values, no database;
  - `db`: one implementation against PostgreSQL;
  - `engine`: through a real Engine and History;
  - `interop`: Python and Haskell together;
- the spec section it verifies;
- the upstream evidence. `test_fabric::name` means
  `tests/petrus/fabric/test_fabric.py`, and `demo` means
  `scripts/cv5-fabric-demo.py`. "derived" means the check was derived from the
  reference source and confirmed against it at the pin, with no upstream test.

Expected outcomes use the error categories of [fabric.md §12](fabric.md):
invalid, conflict, denied, not-found, schema-refused, and storage. A check that
names a category does not require Python's message text.

## A Text and JSON values

- **F-001** `unit` §3.1. A non-string text field is refused (invalid).
  Example: an envelope `source` of `3`. *(test_fabric::test_envelope_is_exact_versioned_detached_strict_json_and_bounded)*
- **F-002** `unit` §3.1. An empty text field is refused (invalid). *(derived)*
- **F-003** `unit` §3.1. A text field of exactly 1024 UTF-8 bytes (`"é"×512`)
  is admitted, and one of 1025 bytes (`"é"×513`) is refused. The limit is in
  bytes, not characters. *(derived)*
- **F-004** `db` §3.1. A text or JSON string containing U+0000 never reaches
  storage. It is refused at construction (preferred) or fails as storage, and
  no row is written. *(derived)*
- **F-005** `unit` §3.1. A string with a lone surrogate is refused. *(derived)*
- **F-006** `unit` §3.2. NaN, +Infinity, and −Infinity anywhere in a payload
  are refused (invalid, "strict JSON"). *(test_fabric::test_envelope_is_exact…)*
- **F-007** `unit` §3.2. Where the API accepts host values, a non-JSON value
  nested in a payload is refused, with its path reported (for example
  `payload.items[0]`). *(test_fabric::test_envelope_is_exact…)*
- **F-008** `unit` §3.2. A payload object with a non-string key is refused.
  *(derived)*
- **F-009** `unit` §3.2–3.3. The payloads `{"n":2}` and `{"n":2.0}` produce
  different canonical bytes and different envelope digests. *(derived)*
- **F-010** `unit` §3.2–3.3. The integer `123456789012345678901234567890` is
  preserved and encoded exactly. *(derived)*
- **F-011** `unit` §3.2. Constructed values are detached. Mutating the
  caller's input afterwards does not change the value, and the value's
  payload cannot be mutated through the API. *(test_fabric::test_envelope_is_exact…)*

## B Canonical encoding vectors

- **F-012** `unit` §3.3–3.4. The value

  ```text
  {"b":1, "a":[1.0, 2, 1e16, 1.5e-7, 0.0001, 1e-5, -0.0, 123456789012345678901234567890, true, null],
   "ctl":"\u0001\u001f\u007f \"\\\n\t\b\f\r", "é":"é"}
  ```

  encodes to

  ```text
  {"a":[1.0,2,1e+16,1.5e-07,0.0001,1e-05,-0.0,123456789012345678901234567890,true,null],"b":1,"ctl":"\u0001\u001f<7F><E2 80 A8>\"\\\n\t\b\f\r","é":"é"}
  ```

  with SHA-256 `6fd2734297a8c0790611a64078bb8804ede158440a9e80b130d7df17dd8f88ba`.
  `<7F>` and `<E2 80 A8>` stand for raw, unescaped UTF-8 bytes. *(derived)*
- **F-013** `unit` §3.3. Keys sort by code point.
  `{"😀":1,"":2,"B":3,"a":4}` encodes as
  `{"B":3,"a":4,"":2,"😀":1}`, where `` stands for the raw
  character, with SHA-256
  `d04cf6929a6673b7534a1bb2cb6b9a46bd31cab8a11b4a9ccfd7b6227ad2dcd3`.
  *(derived)*
- **F-014** `unit` §3.3. Each of these floats is spelled exactly as shown:

  | Float | Canonical spelling |
  |---|---|
  | 0.0 | `0.0` |
  | −0.0 | `-0.0` |
  | 2.0 | `2.0` |
  | 100.0 | `100.0` |
  | 0.5 | `0.5` |
  | 0.001 | `0.001` |
  | 0.0001 | `0.0001` |
  | 1e-5 | `1e-05` |
  | 1.25e-5 | `1.25e-05` |
  | 12345.678 | `12345.678` |
  | 9999999999999998.0 | `9999999999999998.0` |
  | 1e16 | `1e+16` |
  | 1.2345678901234568e17 | `1.2345678901234568e+17` |
  | 1e22 | `1e+22` |
  | 1.5e300 | `1.5e+300` |
  | 5e-324 | `5e-324` |

  *(derived)*
- **F-015** `unit` §3.3. String escaping:
  - `\b \f \n \r \t \" \\` use their short forms;
  - other C0 controls use lowercase `\u00xx`;
  - `/`, U+007F, U+2028, U+2029, and non-BMP characters are emitted raw.

  *(derived)*

## C Envelope, ReplyRoute, and Endpoint

- **F-016** `unit` §4.1. ReplyRoute decoding refuses missing, extra, and
  non-string keys, and a non-object. *(derived)*
- **F-017** `unit` §4.2. Envelope JSON has exactly eight members with
  `version` = integer 1. An absent reply route is the explicit
  `"reply_route":null`. *(test_fabric::test_envelope_is_exact…)*
- **F-018** `unit` §4.2. `decode(encode(e)) == e`. *(test_fabric::test_envelope_is_exact…)*
- **F-019** `unit` §4.2. Decoding refuses `version: 2`. *(test_fabric::test_envelope_is_exact…)*
- **F-020** `unit` §4.2. Decoding refuses `version: 1.0` and `version: true`.
  *(derived)*
- **F-021** `unit` §4.2. Decoding refuses a missing member (for example
  `source`) and identifies the missing name. *(test_fabric::test_envelope_is_exact…)*
- **F-022** `unit` §4.2. Decoding refuses an extra member (`"extra": true`) and
  a non-string key, and identifies the unknown member.
  *(test_fabric::test_envelope_is_exact…)*
- **F-023** `unit` §4.2. Decoding refuses a non-object payload (`[]`).
  *(derived)*
- **F-024** `unit` §4.2.1. A payload of exactly 65536 canonical bytes is
  admitted. 65537 bytes is refused (invalid). The limit is measured on the
  payload alone, so an envelope whose total exceeds 65536 bytes, but whose
  payload does not, is admitted. *(test_fabric::test_envelope_is_exact…; boundary derived)*
- **F-025** `unit` §4.2.1. Escapes count by their encoded length:
  `{"x":"\u0001"}` costs 14 bytes. *(derived)*
- **F-026** `unit` §4.2.2. This envelope:

  ```text
  Envelope(delivery_id="d-1", sender="sender-a", recipient="recipient",
           source="commands/start", correlation="conversation-1",
           payload={"command":"go"},
           reply_route=ReplyRoute("sender-a", "replies/finish"))
  ```

  has digest `8865b183f1d8b38dbdcd816dcb63368db0323936b2f95ae9a39ba6a1eee3c605`.
  The same envelope with no reply route has canonical form

  ```text
  {"correlation":"conversation-1","delivery_id":"d-1","payload":{"command":"go"},"recipient":"recipient","reply_route":null,"sender":"sender-a","source":"commands/start","version":1}
  ```

  and digest `4d806f6288ac30a5e88d54e121ccef1f6797a742a0d49cec401ce7578185e6ba`.
  *(derived)*
- **F-027** `unit` §4.2.2. A digest is 64 lowercase hex characters.
  *(test_fabric::test_envelope_is_exact…)*
- **F-028** `unit` §4.2.3. Sender `sender-a` with delivery `delivery-1` has
  ingress identity `fabric:8:sender-a:delivery-1`. *(test_fabric::test_envelope_is_exact…)*
- **F-029** `unit` §4.2.3. Sender `é😀:z` with delivery `x:y` has ingress
  identity `fabric:4:é😀:z:x:y`. The length counts code points, not bytes.
  *(derived)*
- **F-030** `unit` §4.3. Endpoint JSON is exactly
  `{recipient, source, capabilities}`, decoding is exact-key, and
  capabilities must be an object. *(derived)*

## D Storage schema

- **F-031** `db` §6.1. After provisioning, catalog introspection of
  `impetus_fabric` matches the §6.1 object table exactly:
  - tables, column names and order, types, nullability, and defaults
    (`clock_timestamp()`);
  - primary keys, foreign keys and their names, both CHECK constraints, and
    both indexes, including the partial predicate `accepted_at IS NULL`.

  *(derived)*
- **F-032** `db` §6.3. Provisioning twice in a row succeeds and changes
  nothing. *(test_fabric fixture `fabric_schema`)*
- **F-033** `db` §6.3, §8.1. Provisioning inside a caller's non-autocommit
  transaction followed by a rollback leaves no `impetus_fabric` namespace.
  *(derived; mirrors test_processes::test_lifecycle_schema_provisioning_does_not_commit_the_callers_transaction)*
- **F-034** `db` §6.3. Provisioning is refused (schema-refused) when the schema
  holds a pre-existing `impetus_fabric.processes (unknown_shape text)` and no
  `schema_metadata`. *(test_fabric::test_schema_provisioning_refuses_unknown_or_mismatched_versions)*
- **F-035** `db` §6.3. Provisioning is refused (schema-refused) when
  `schema_metadata('fabric').version = 999`, and the error reports 999.
  *(test_fabric::test_schema_provisioning_refuses_unknown_or_mismatched_versions)*
- **F-036** `db` §6.3. A schema containing only unrelated tables is
  provisioned normally. *(derived)*
- **F-037** `db` §6.2. `schema_metadata` contains exactly `('fabric', 1)`.
  *(derived)*
- **F-038** `interop` §6. A schema provisioned by Python is accepted by
  Haskell's provisioning as a no-op, and the reverse. Both leave identical
  catalogs. *(derived)*

## E Credentials and registration

- **F-039** `unit` §7. The credential acceptance rule is ≥ 32 UTF-8 bytes and
  ≥ 16 distinct code points:
  - `"x"*40` and `"ab"*20` are refused (invalid);
  - a 31-byte string with 31 distinct characters is refused;
  - every issued credential is accepted.

  *(test_fabric::test_registration_stores_only_digest_is_idempotent_and_authenticates)*
- **F-040** `unit` §8.2. Constructing a client with a weak credential is
  refused without database access. *(derived)*
- **F-041** `db` §7, §8.3. Registration stores the lowercase SHA-256 hex of the
  credential: 64 characters, with the credential not a substring. A fixed
  vector: credential `caller-credential-0123456789-abcdefghijklmnop` gives
  `f87d0d9624b9288fbcea1554e00abffbd965251aef9d310ca9e63e025cca36a5`.
  *(test_fabric::test_registration_stores_only_digest…; vector derived)*
- **F-042** `db` §8.3. Re-registering with the same credential succeeds.
  *(test_fabric::test_registration_stores_only_digest…)*
- **F-043** `db` §8.3. Re-registering with a different credential is a
  conflict, and the stored digest is unchanged.
  *(test_fabric::test_registration_stores_only_digest…)*
- **F-044** `db` §8.2. A client with the wrong credential is denied on any
  operation (for example `discover("anything")`), and the operation has no
  effect. *(test_fabric::test_registration_stores_only_digest…)*
- **F-045** `db` §8.2. A client whose instance is unregistered is denied.
  *(derived)*
- **F-046** `interop` §7. A process registered by Python authenticates from
  Haskell with the same credential, and the reverse. *(derived)*

## F Exposure, offers, grants, and discovery

- **F-047** `db` §8.4. `expose_source` is idempotent. *(derived)*
- **F-048** `db` §8.5. `offer_service` on an unexposed source fails as
  storage, and no offer row is written. *(derived)*
- **F-049** `db` §8.5. Re-offering one `(source, service)` replaces its
  capabilities. *(derived)*
- **F-050** `db` §8.6. `grant` to an unregistered sender fails as storage.
  *(derived)*
- **F-051** `db` §8.6. `grant` on an unexposed source fails as storage.
  *(derived)*
- **F-052** `db` §8.6. `grant` is idempotent, and `revoke` of an absent grant
  is a successful no-op. *(derived)*
- **F-053** `db` §8.7. Discovery is deny-by-default: when an offer exists
  without a grant to the caller, `discover` returns empty. *(test_fabric::test_discovery_and_send_are_deny_by_default_and_capability_filtered)*
- **F-054** `db` §8.7. After the grant,
  `discover("worker", {"model":"large"})` returns exactly
  `[Endpoint("recipient", "commands/start", {"model":"large","region":"eu"})]`.
  *(test_fabric::test_discovery_and_send_are_deny_by_default…)*
- **F-055** `db` §8.7. `discover("worker", {"model":"small"})` returns empty.
  *(test_fabric::test_discovery_and_send_are_deny_by_default…)*
- **F-056** `db` §8.7. Capability matching is jsonb containment:
  - `{"tools":["git"]}` matches `{"tools":["shell","git"]}`;
  - `{"n":1}` matches `{"n":1.0}`;
  - `{"tools":"shell"}` does not match `{"tools":["shell"]}`;
  - `{}` and an omitted filter match every granted offer.

  *(derived)*
- **F-057** `db` §8.7. Discovery returns only offers on sources granted to the
  calling sender, not those granted to other senders. *(derived)*
- **F-058** `db` §8.7. Discovery results are ordered by
  `(instance_id, source)` as the database sorts them. *(derived)*

## G Submit

- **F-059** `unit/db` §8.8. Submitting an envelope whose sender is not the
  bound instance is denied, before any database access. *(derived)*
- **F-060** `db` §8.8. Submitting to an exposed but ungranted source is denied
  ("not exposed and granted"), and no row is written. *(test_fabric::test_discovery_and_send_are_deny_by_default…)*
- **F-061** `db` §8.8. Submitting to an unregistered recipient is denied, not
  storage. *(derived)*
- **F-062** `db` §8.8, §6.2. A fresh submit returns
  `Submission(sender, delivery_id, "pending", false, null, null)`. The row
  has:
  - `recipient`, `source`, and `correlation` copied from the envelope;
  - `digest` = the envelope digest;
  - `envelope` = the envelope JSON form, modulo §3.5;
  - `accepted_occurrence` and `accepted_at` NULL;
  - a non-null `submitted_at`.

  *(test_fabric::test_discovery_and_send_are_deny_by_default…; row derived)*
- **F-063** `db` §6.4. A fresh submit produces exactly one notification on
  `impetus_fabric_delivery` whose payload is the recipient id, delivered at
  commit. *(derived)*
- **F-064** `db` §5.2. An exact retransmission returns `duplicate = true` and
  `state = "pending"`, leaves the row unchanged, and sends no notification.
  *(test_fabric::test_exact_retransmission_precedes_current_grant_and_changed_content_conflicts)*
- **F-065** `db` §5.2. An exact retransmission succeeds as a duplicate after
  the recipient revoked the grant. *(test_fabric::test_exact_retransmission_precedes_current_grant…)*
- **F-066** `db` §5.2. A changed payload under the same
  `(sender, delivery_id)` is a conflict, and the row is unchanged.
  *(test_fabric::test_exact_retransmission_precedes_current_grant…)*
- **F-067** `db` §5.2. A changed recipient or source under the same
  `(sender, delivery_id)` is a conflict. *(derived)*
- **F-068** `db` §5.2. A changed correlation or reply route under the same
  `(sender, delivery_id)` is a conflict. *(derived)*
- **F-069** `db` §8.6, §8.8. After revocation, a **new** delivery id is denied.
  *(test_fabric::test_exact_retransmission_precedes_current_grant…)*
- **F-070** `db` §5.1. The same `delivery_id` from two different senders gives
  two rows, both pending, with ingress identities `fabric:8:sender-a:same` and
  `fabric:8:sender-b:same`. *(test_fabric::test_same_delivery_id_from_distinct_senders_has_distinct_ingress_identity)*
- **F-071** `db` §5.2. A duplicate of an accepted row reports
  `state = "accepted"` with the stored occurrence and `accepted_at`.
  *(test_fabric::test_pruning_removes_envelope_but_preserves_receipt_dedup_and_conflict; demo "duplicate: accepted/true")*
- **F-072** `db` §8.1. On a non-autocommit connection, `submit` joins the
  caller's transaction:
  - the row is invisible to other sessions before commit;
  - it is absent after rollback;
  - the notification is sent only on commit.

  *(derived; mirrors test_fabric::test_fabric_operations_join_a_caller_transaction_without_committing)*
- **F-073** `db` §8.8. Two concurrent identical submits on two connections
  yield one row: one fresh result and one duplicate. *(derived)*
- **F-074** `db` §8.8. Two concurrent submits with different content for one
  `(sender, delivery_id)` yield one row and one conflict. *(derived)*
- **F-075** `db` §3.5, §6.2. For a payload `{"f":1e16}`:
  - the stored `digest` equals the sender's pre-storage digest;
  - `pending` returns payload `{"f":10000000000000000}`, an integer;
  - the reader does not reject or re-digest the envelope.

  *(derived)*

## H Pending

- **F-076** `unit/db` §8.9. `pending` refuses `limit` of 0, −1, and boolean
  `true` (invalid). *(derived)*
- **F-077** `db` §8.9. `pending` returns only this recipient's unaccepted
  deliveries, ordered by `(submitted_at, sender, delivery_id)` and capped at
  `limit`. *(derived)*
- **F-078** `db` §3.5. A payload read back through `pending` follows the
  normalization rules: key order is irrelevant, `1e16` becomes an integer,
  `-0.0` becomes `0.0`, `2.0` stays a float, and big integers are exact.
  *(derived)*
- **F-079** `db` §8.9. `pending` requires authentication. *(derived)*

## I Acknowledge

- **F-080** `unit/db` §8.10. `acknowledge` refuses occurrence 0, a negative
  occurrence, and boolean `true` (invalid, "positive integer").
  *(test_fabric::test_acknowledgement_occurrence_conflicts)*
- **F-081** `db` §8.10. Acknowledging an unknown delivery is not-found.
  *(derived)*
- **F-082** `db` §8.10. Acknowledging a delivery addressed to another process
  is not-found. *(derived)*
- **F-083** `db` §8.10. A first acknowledgement with occurrence 4 sets
  `accepted_occurrence = 4` and `accepted_at`. It returns a Receipt with
  `state = "accepted"`, the stored digest, and `payload_retained = true`.
  *(test_fabric::test_acknowledgement_occurrence_conflicts)*
- **F-084** `db` §8.10. Re-acknowledging with occurrence 4 succeeds with the
  same `accepted_at`. *(test_fabric::test_acknowledgement_occurrence_conflicts)*
- **F-085** `db` §8.10. Acknowledging with occurrence 5 after 4 is a conflict
  reporting 4, and the row is unchanged.
  *(test_fabric::test_acknowledgement_occurrence_conflicts)*
- **F-086** `db` §8.10. Acknowledging a pruned delivery with its own
  occurrence succeeds with `payload_retained = false`. *(derived)*
- **F-087** `db` §8.1. On a non-autocommit connection, `acknowledge` joins the
  caller's transaction, and a rollback leaves the delivery pending.
  *(derived)*

## J Receipt

- **F-088** `db` §8.11. A sender receipt for a pending delivery has
  `state = "pending"`, null occurrence and `accepted_at`, and
  `payload_retained = true`. *(derived)*
- **F-089** `db` §8.11. A receipt for an unknown delivery id is absent. A
  recipient asking about an inbound delivery id also gets absent, because
  receipts are sender-scoped. *(derived)*
- **F-090** `db` §8.11. After acknowledgement, the receipt shows `"accepted"`
  with the occurrence. *(test_fabric::test_pruning_removes_envelope…)*

## K Prune

- **F-091** `unit/db` §8.12. `prune_accepted` refuses a cutoff without a
  timezone (invalid). *(test_fabric::test_pruning_removes_envelope…)*
- **F-092** `db` §8.12. `prune_accepted(now + 1s)` nulls the envelope of the
  one accepted delivery and returns 1. Pending deliveries are untouched: with
  only pending deliveries, it returns 0. *(test_fabric::test_pruning_removes_envelope…; pending derived)*
- **F-093** `db` §8.12, §5.2. After pruning:
  - the row exists, with the same digest and NULL `envelope`;
  - the receipt equals
    `Receipt(sender, id, recipient, source, digest, "accepted", 9, accepted_at, false)`;
  - an exact resubmission is `("accepted", duplicate = true, occurrence = 9)`;
  - a changed resubmission is a conflict.

  *(test_fabric::test_pruning_removes_envelope…)*
- **F-094** `db` §6.1. Direct SQL that violates `deliveries_check` (an
  occurrence without `accepted_at`) or `deliveries_check1` (NULL envelope on
  a pending row) is rejected by the database. *(derived)*

## L Ingress bridge

- **F-095** `unit/db` §9.1–9.2. `drain` calls the door with
  `(envelope.source, [Token("FabricEnvelope", <8-member envelope JSON>)], identity = ingress_identity)`
  and no lifecycle scope. The fixture expects
  `("commands/start", "FabricEnvelope", "fabric:8:sender-a:delivery-1")`.
  *(test_fabric::test_inbox_delivery_acceptance_and_prior_acknowledgement_crash_recovery)*
- **F-096** `db` §9.2. `drain` acknowledges each delivery with the door's
  occurrence, returns the receipts, and afterwards `pending` is empty.
  *(test_fabric::test_inbox_delivery_acceptance…)*
- **F-097** `db` §9.2. In the crash window (door delivered with occurrence 7,
  no acknowledgement), the next `drain` gets `PriorAcknowledgement(identity, 7)`
  and acknowledges with 7 (`state = "accepted"`, `occurrence = 7`).
  *(test_fabric::test_inbox_delivery_acceptance…)*
- **F-098** `db` §9.3. When the door raises, `drain` raises, that delivery and
  every later one remain pending, and earlier acknowledgements in the batch
  persist. *(derived)*
- **F-099** `db` §9.2. When the door returns a value of any other type,
  `drain` fails, and nothing is acknowledged for that delivery. *(derived)*
- **F-100** `engine` §9.1. With a real recipient Engine, the delivered token
  is recorded as `ExternalEventDelivered` with `identity` = the ingress
  identity. A redelivery appends nothing. *(demo; derived)*

## M `fabric.send` activity profile

- **F-101** `engine` §11.
  - The `fabric.send` executor refuses an invocation whose idempotency
    differs from the envelope's ingress identity.
  - Its result is exactly
    `{"state", "duplicate", "delivery_id", "correlation"}`.
  - A re-dispatch after a lost completion yields `duplicate: true`.

  *(demo SendActivity)*

## N Interoperability (shared database)

- **F-102** `interop` §8–9. A Python sender submits, and a Haskell recipient
  drains, delivers to its Engine, and acknowledges. Python's
  `receipt(...)` then shows `accepted` with Haskell's occurrence. *(derived)*
- **F-103** `interop` §8–9. A Haskell sender submits, and a Python recipient
  drains and acknowledges. Haskell's receipt then shows `accepted` with
  Python's occurrence. *(derived)*
- **F-104** `interop` §5.2. An envelope submitted by Python is resubmitted by
  Haskell under the same sender identity and credential, and the result is a
  duplicate, because the digests are identical. The same envelope with any
  changed member is a conflict. Repeat with the roles reversed. *(derived)*
- **F-105** `interop` §8.7. Offers made by either implementation are
  discovered identically, including order, by either implementation.
  *(derived)*
- **F-106** `interop` §8.12. Deliveries pruned by one implementation are
  reported identically, through receipts and duplicates, by the other.
  *(derived)*
- **F-107** `interop` §9–11. The `cv5-fabric-demo` scenario passes with a
  Python parent and a Haskell child, and with the roles reversed:
  - offline pending count 1;
  - the parent goes awaiting → completed;
  - the duplicate request reports accepted;
  - replay appends 0 and invokes 0;
  - in-flight crash resume dispatches exactly once;
  - local and split History shapes are equal.

  *(test_fabric::test_two_authority_process_fabric_acceptance_demo)*
- **F-108** `interop` §4.2.3, §9.2. A recipient History written by Python is
  resumed by Haskell, or the reverse. Redelivery of an already-accepted
  pending Fabric delivery returns `PriorAcknowledgement` with the original
  occurrence, not a conflict and not a new firing. *(derived)*

Total: 108 checks.
