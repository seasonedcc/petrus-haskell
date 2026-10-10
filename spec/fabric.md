# Fabric protocol version 1

This document specifies **Fabric**, the inter-Instance protocol plane that lets
independently authoritative Petrus net Instances address, authorize, deliver,
acknowledge, and retain messages between each other. It is written so that a
second implementation (the Haskell port) can share one PostgreSQL database
with the Python reference implementation and exchange deliveries with it in
both directions.

Upstream has no language-neutral Fabric specification. This document is
derived from the pinned Python reference
(`upstream/petrus` at `3f85fc2094e50ece48bcf6bf9ace19cb0a22a544`, see
[UPSTREAM.md](../UPSTREAM.md)):

- `src/petrus/fabric/model.py`: transport-neutral values and wire encoding;
- `src/petrus/fabric/postgres.py`: PostgreSQL schema and operations;
- `src/petrus/fabric/ingress.py`: the bridge into an Engine's delivery door;
- `tests/petrus/fabric/test_fabric.py` and `scripts/cv5-fabric-demo.py`:
  executable evidence;
- decision records `2026-07-20T1114Z-process-fabric-is-an-inter-authority-protocol-plane`
  and `2026-07-23T1851Z-fabric-public-term`.

Process `call` and `spawn` are specified separately in
[processes.md](processes.md). The conformance checklist for this document is
[fabric-conformance.md](fabric-conformance.md).

## 1 Status, scope, and normative language

Upstream describes Fabric as "an unfinished coordination prototype, subject to
rewrite" (`README.md`, `docs/project/briefing.md`). This document pins version
1 **as implemented at the pin**. A future upstream rewrite is a new protocol
version and moves the pin; it does not silently change this document.

The key words MUST, MUST NOT, SHOULD, and MAY are normative. Three markers
classify behavior:

- **CONTRACT**: observable on the wire, in the database, or in a recipient's
  canonical History. A second implementation MUST match it exactly. When this
  document is unsure whether a Python behavior is intended, and the behavior is
  observable in shared state, it is classified as CONTRACT.
- **ACCIDENT**: a Python behavior that is not observable in shared state, or
  that upstream would plausibly treat as a defect. A second implementation MAY
  differ, and interop tests MUST NOT depend on it. Each accident states what
  a conforming implementation SHOULD do instead, when that matters.
- **OPEN**: an unresolved point. Do not rely on a default.

Fabric is neither Petri-kernel semantics nor an application host. Fabric
rows are delivery and routing truth. They never enter any Instance's canonical
History, except through the recipient's own delivery door (§9). Fabric does
not schedule nets, does not own process lifecycle, and offers no
cross-Instance transaction.

**Security model (CONTRACT).** Fabric is a *trusted-workspace* protocol. Its
API-level credentials prevent *accidental* cross-Instance use. They do not
protect against a hostile SQL principal that can reach the shared database:
any such principal can read and write every Fabric table directly.

### 1.1 Revisions

These are changes made after the Haskell port ran every check against the
pinned reference. Each change makes this document say what the pinned
reference does. None of them changes the wire format or the schema.

- §3.3 item 6 now states how `float.__repr__` chooses among several shortest
  digit strings: the nearest one, ties to even, and interval ends admitted for
  even significands. The earlier wording ("the shortest round-tripping decimal
  digit string") did not identify one string. F-014 gains the two
  distinguishing values `1e+23` and `2.9802322387695312e-08`.
- §9.3 now states that a refusal by a reference Engine door poisons that
  Engine, and that the host recovers through a fresh load. The earlier
  wording left open whether a host may keep using the same Engine. The
  pinned reference does not allow it.

## 2 Terminology

- **Process (identity)**: the stable Fabric address of one independently
  authoritative net Instance, called `instance_id` in storage. In the reference
  compositions the Fabric process identity is the same string as the net
  Instance identity the Engine is created or loaded with.
- **Source**: the name of one source transition of the recipient's net, as its
  canonical dotted `NetPath` string (for example `request` or
  `commands.start`). Fabric treats it as opaque text. The ingress bridge
  passes it to the Engine's delivery door unchanged (§9).
- **Exposure**: a recipient's declaration that one of its sources is
  reachable through Fabric.
- **Grant**: a recipient's permission for one sender to deliver to one
  exposed source.
- **Service offer**: a recipient's discoverable advertisement of a service name
  and a capability object on one exposed source.
- **Envelope**: the version-1 message value (§4.2).
- **Delivery**: one stored envelope, identified by `(sender, delivery_id)`.
- **Submission**: the sender-side act of storing a delivery, and its result value.
- **Acceptance / acknowledgement**: the recipient-side act of recording the
  recipient's firing occurrence that durably accepted the delivery.
- **Receipt**: the sender-visible or recipient-visible state of one delivery.
  Receipt means acceptance by the recipient's canonical ingress, not that the
  recipient understood the message, completed any work, or performed an
  external effect (glossary *Delivery receipt*).

## 3 Common value rules

These rules are shared with [processes.md](processes.md).

### 3.1 Text fields

Every identifier field in this protocol is **Fabric text**, validated as
follows (`model._text`):

1. The value MUST be a string. Any other type is rejected.
2. It MUST be non-empty.
3. Its UTF-8 encoding MUST be at most **1024 bytes**. The limit is in
   bytes, not characters: 512 copies of `é` (1024 bytes) are admitted, and 513
   are refused.

Fabric text is otherwise unrestricted: there is no character-class, trimming,
case-folding, or Unicode-normalization rule. Comparison is exact by Unicode
scalar sequence.

- **CONTRACT:** text MUST NOT contain U+0000. PostgreSQL `text` and `jsonb`
  cannot store NUL. Python admits NUL at value construction and then fails at
  the database (`DataError` for text, `UntranslatableCharacter` for jsonb), so
  no NUL-bearing identifier can ever exist in shared state. A conforming
  implementation SHOULD reject NUL at construction (**ACCIDENT:** Python's late
  failure).
- Strings MUST consist of Unicode scalar values. Python raises
  `UnicodeEncodeError` (not `ValueError`) on lone surrogates (**ACCIDENT:** the
  exception class). Lone surrogates can never reach shared state.

### 3.2 JSON value model

Payloads, capabilities, configuration, and results are **strict JSON values**
(`model._json_copy`):

- `null`, `true`, `false`, strings, arrays, and objects with string keys;
- **integers**: arbitrary precision. A number that has no fraction and no
  exponent is an integer.
- **floats**: finite IEEE-754 binary64. A number with a fraction or an
  exponent is a float, even when its value is integral (`2.0` is a float).
  NaN and ±Infinity are refused.

The integer/float distinction is **CONTRACT**. It changes the canonical bytes
(§3.3) and therefore every digest and identity. An implementation whose JSON
library collapses `2` and `2.0` (for example a bare `Scientific`) MUST track
the distinction separately.

Python refuses non-JSON host values (tuples, sets, non-string keys, arbitrary
objects) with `TypeError`, naming the offending path (for example
`payload.items[0]`). Python's `bool` is a JSON boolean, never an integer.

Values are **detached**: a constructed value never aliases caller-mutable
state, and the reference exposes read-only views. This is an API property,
not a wire property.

### 3.3 Canonical JSON encoding

Digests and size limits use one canonical byte encoding. It is exactly
Python's
`json.dumps(value, allow_nan=False, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")`
(`model._canonical`), restated here language-neutrally (**CONTRACT**):

1. The output is UTF-8, with no whitespace outside strings. Members are
   separated by `,` and keys from values by `:`.
2. Object members are sorted ascending by key, comparing keys as sequences of
   Unicode scalar values by unsigned scalar value, with a shorter prefix sorting
   first. This is code-point order, **not** UTF-16 code-unit order and not
   locale collation. Examples: `"B" < "a" < "aa" < "é" < "\u{E000}" < "😀"`.
   Keys are unique, because a JSON object with duplicate keys is never
   constructed.
3. Strings are written between `"` characters. Exactly these characters are
   escaped:
   - `"` becomes `\"` and `\` becomes `\\`;
   - U+0008 becomes `\b`, U+000C becomes `\f`, U+000A becomes `\n`, U+000D
     becomes `\r`, and U+0009 becomes `\t`;
   - every other code point in U+0000–U+001F becomes `\u00XX`, with
     **lowercase** hex (`\u001f`).

   Every other scalar value is emitted literally as UTF-8. That includes `/`,
   U+007F, U+2028, U+2029, and non-BMP characters (never surrogate-pair
   escapes).
4. Integers are written as an optional `-` followed by decimal digits, with no
   leading zeros, no `+`, and any magnitude.
5. `true`, `false`, and `null` are written literally.
6. Floats use Python `float.__repr__`. Its digit string `d₁d₂…dₙ` is
   chosen as follows. Among the decimal strings that read back as the same
   double, take the shortest. Among those, take the one nearest the exact
   binary value. An exact tie between two of them goes to the one whose last
   digit is even. Reading back is round-half-even, so the ends of a double's
   rounding interval read back as that double exactly when its binary
   significand is even. Two examples follow from this:
   - The double nearest 10²³ lies just below it and has an even
     significand, so it is spelled `1e+23` and not `9.999999999999999e+22`.
   - 2⁻²⁵ is exactly 2.98023223876953125e-08. Both 17-digit neighbours are
     equally near, so it is spelled `2.9802322387695312e-08` and not
     `…313e-08`.

   This is David Gay's shortest mode, as CPython uses, and Ryu with interval
   ends accepted for even significands. GHC's `floatToDigits` and some Ryu
   ports exclude the ends and round ties up, so they differ on both
   examples. Let `p` be the decimal-point position, so that
   value = `0.d₁…dₙ × 10^p`, which is `d₁.d₂… × 10^(p−1)`:
   - If `-4 < p ≤ 16`, use fixed notation. If the value is integral, append
     `.0`. Examples: `0.0`, `-0.0`, `2.0`, `0.1`, `0.0001`, `12345.678`,
     `9999999999999998.0`.
   - Otherwise use exponent notation `d₁[.d₂…dₙ]e±XX`. The sign is always
     present, the exponent has at least two digits, and the mantissa gets no
     trailing `.0`. Examples: `1e+16`, `1e-05`, `1.25e-05`, `1e+22`,
     `1.2345678901234568e+17`, `5e-324`.
   - Negative values carry a leading `-`. `-0.0` keeps its sign.

Worked example: the value with members `b` = integer 1, `a` = the array
[float 1.0, integer 2, float 1e16, float 1.5e-7, float 0.0001, float 1e-5,
float -0.0, integer 123456789012345678901234567890, true, null], `ctl` = the
string U+0001 U+001F U+007F U+2028 `"` `\` LF TAB BS FF CR, and `é` = `é`
has these canonical bytes. In the listing, `<7F>` stands for the single raw
byte 0x7F and `<E2 80 A8>` for the three raw UTF-8 bytes of U+2028. Neither is
escaped.

```text
{"a":[1.0,2,1e+16,1.5e-07,0.0001,1e-05,-0.0,123456789012345678901234567890,true,null],"b":1,"ctl":"\u0001\u001f<7F><E2 80 A8>\"\\\n\t\b\f\r","é":"é"}
```

### 3.4 Digests

A **digest** is the lowercase hexadecimal SHA-256 of the canonical bytes
(64 characters) (**CONTRACT**).

### 3.5 Database round trip of JSON (CONTRACT, inherited from PostgreSQL)

Envelopes and capabilities are stored as `jsonb`. What a reader observes is
the PostgreSQL `jsonb` normalization of what the writer stored, decoded by the
§3.2 rule (a numeral without fraction or exponent is an integer):

- **Object member order is lost.** `jsonb` reorders keys (shorter keys first,
  then bytewise). Member order is never semantic anywhere in this protocol.
  Readers MUST NOT depend on it.
- **Some floats come back as integers.** `jsonb` prints numerics in plain
  decimal. A float whose canonical spelling uses a non-negative exponent
  (`1e+16`, `1.7976931348623157e+308`) is read back as the *integer*
  `10000000000000000`. Floats spelled in fixed notation keep their fraction
  (`2.0` stays `2.0`). Floats with negative exponents come back as equal floats
  (`1.5e-07` is stored as `0.00000015` and read as `1.5e-07`).
- **`-0.0` comes back as `0.0`.**
- Integers of any magnitude and all strings round-trip exactly.

Consequently the envelope a recipient reads can differ from the one the sender
digested. The stored `digest` column (§6) is authoritative. A reader MUST NOT
recompute and compare an envelope digest from the `envelope` column.
Senders SHOULD avoid floats of magnitude ≥ 1e16 and negative zero in
payloads.

## 4 Values

### 4.1 ReplyRoute

A reply route names where replies to a delivery should go.

| Field | Type | Rule |
|---|---|---|
| `instance_id` | Fabric text | the process that receives replies |
| `source` | Fabric text | the source on that process |

Its JSON form is exactly `{"instance_id": …, "source": …}`. Decoding refuses
any object whose key set is not exactly `{instance_id, source}`, and any
non-object (`ValueError`).

Fabric itself attaches no meaning to a reply route. It is carried, digested,
and returned. [processes.md](processes.md) gives it meaning for calls.

### 4.2 Envelope version 1

| Field | Type | Rule |
|---|---|---|
| `version` | integer | exactly `1`. Decoding requires a JSON integer: `1.0` and `true` are refused. |
| `delivery_id` | Fabric text | sender-chosen, unique per sender (§5.1) |
| `sender` | Fabric text | the submitting process |
| `recipient` | Fabric text | the addressed process |
| `source` | Fabric text | the recipient's exposed source |
| `correlation` | Fabric text | an application correlation; Fabric attaches no meaning to it |
| `payload` | JSON object | strict JSON (§3.2); canonical size ≤ 65536 bytes (§4.2.1) |
| `reply_route` | ReplyRoute or `null` | optional reply route; `null` when absent |

**Encoding (CONTRACT).** The JSON form has exactly these eight members. The
reference writer emits them in the order shown above, and the payload keeps
its in-memory order. Order is not semantic (§3.5). `reply_route` is always
present, as `null` when absent.

**Decoding (CONTRACT).** The following are refused:

- a non-object, or an object whose key set is not exactly the eight names
  above (missing or unknown members, including non-string keys);
- a `version` that is not the JSON integer `1`;
- any text field that violates §3.1;
- a non-object `payload` (`TypeError` in Python);
- a `reply_route` that is neither `null` nor an exact ReplyRoute;
- a payload that is not strict JSON, or that is over the size limit.

Python reports the missing and unknown member names in the error.

#### 4.2.1 Inline payload limit

`MAX_INLINE_PAYLOAD_BYTES = 65536`. The limit applies to the canonical bytes
(§3.3) **of the payload object alone**, not of the whole envelope. Escapes
count by their encoded length, so `"\u0001"` costs six bytes. A payload of
exactly 65536 canonical bytes is admitted, and 65537 is refused at
construction (**CONTRACT**). The refusal message points to "the artifact
protocol": large content must travel by verified reference, which is outside
this document.

#### 4.2.2 Envelope digest

`digest = SHA-256-hex(canonical(envelope JSON form))` over all eight members,
including `version: 1` and `reply_route: null` (**CONTRACT**). Every field
participates, including the address (`recipient`, `source`). Changing any of
them changes the digest.

#### 4.2.3 Ingress identity

```text
ingress_identity = "fabric:" + decimal(len(sender)) + ":" + sender + ":" + delivery_id
```

Here `len(sender)` is the number of **Unicode scalar values (code points)** in
`sender`, not its UTF-8 byte length (**CONTRACT**). For example, sender `é😀`
gives the prefix `fabric:2:é😀:`. The length prefix makes the
`(sender, delivery_id)` pair injective even when either component contains
`:`.

The ingress identity is the delivery identity that the recipient's Engine
records on its `ExternalEventDelivered` History fact (§9). It is therefore
persisted in the recipient's canonical History. A Python-written History
resumed by Haskell, or the reverse, depends on it being bit-identical.

### 4.3 Endpoint

| Field | Type | Rule |
|---|---|---|
| `recipient` | Fabric text | offering process |
| `source` | Fabric text | offered exposed source |
| `capabilities` | JSON object | strict JSON |

The JSON form is exactly `{"recipient": …, "source": …, "capabilities": …}`,
and decoding is exact-key (§4.1 style). Endpoints are discovery results
(§8.7) and appear inside spawn outcomes ([processes.md](processes.md)).

### 4.4 Submission (result value)

`Submission(sender, delivery_id, state, duplicate, occurrence, accepted_at)`:

- `state` is `"pending"` or `"accepted"`.
- `duplicate` is `false` only when this call stored the row.
- `occurrence` and `accepted_at` are present only for a duplicate whose stored
  row is already accepted. A fresh submission and a duplicate of a pending row
  both carry `null` and `null`.

### 4.5 Receipt (result value)

`Receipt(sender, delivery_id, recipient, source, digest, state, occurrence, accepted_at, payload_retained)`:

- `digest` is the **stored** digest.
- `state` is `"accepted"` iff `accepted_at` is non-null, and `"pending"`
  otherwise.
- `payload_retained` is true iff the stored `envelope` is non-null, that is,
  the envelope has not been pruned (§8.12).

Submission and Receipt are API results. They are not persisted as such.
Their field set is CONTRACT at the level of the conformance checklist, so
that both implementations' APIs can be compared.

## 5 Identity, idempotency, and conflict

### 5.1 Delivery identity

A delivery is identified by **`(sender, delivery_id)`** (the primary key).
`delivery_id` is chosen by the sender and only needs to be unique within that
sender. Two senders may use the same `delivery_id`. Their deliveries are
distinct and have distinct ingress identities (`fabric:8:sender-a:same`
and `fabric:8:sender-b:same`).

### 5.2 Exact retransmission versus conflict (CONTRACT)

Submitting an envelope whose `(sender, delivery_id)` already exists is judged
**only** by digest equality, compared in constant time in the reference:

- **Equal digest** means an exact retransmission. It succeeds with
  `duplicate = true` and reports the stored state. It appends nothing and
  sends no notification. This judgment happens **before** the current
  authorization check (§8.8). An exact retransmission therefore still succeeds
  after the grant was revoked, after the recipient's exposure was replaced,
  and after the envelope was pruned.
- **Different digest** means an identity conflict. The submission fails and the
  stored row is unchanged. A changed payload, correlation, reply route,
  recipient, or source under one `(sender, delivery_id)` always conflicts.

### 5.3 Acceptance identity

A delivery is accepted **at most once**, by exactly one recipient firing
occurrence: a positive integer, the occurrence id minted by the recipient's
History writer. Acknowledging again with the same occurrence is idempotent.
Acknowledging with a different occurrence is a conflict (§8.10).

Combined with the recipient's identity-enforcing delivery door (§9), this
gives **effectively-once acceptance** into the recipient's History on top of
at-least-once delivery attempts.

## 6 Storage schema version 1

All Fabric state lives in PostgreSQL schema `impetus_fabric`. The names below
(`impetus_fabric`, the channel `impetus_fabric_delivery`, the component
`'fabric'`) are CONTRACT. The `impetus_` prefix is a historical name and is
not a typo.

### 6.1 DDL (CONTRACT)

An implementation MUST be able to provision, and MUST operate against, exactly
these objects. It SHOULD provision them by executing these statements
verbatim and in this order, so that PostgreSQL's generated constraint names
match:

```sql
CREATE SCHEMA IF NOT EXISTS impetus_fabric;

CREATE TABLE IF NOT EXISTS impetus_fabric.schema_metadata (
    component text PRIMARY KEY, version integer NOT NULL);

CREATE TABLE IF NOT EXISTS impetus_fabric.processes (
    instance_id text PRIMARY KEY, credential_digest text NOT NULL,
    registered_at timestamptz NOT NULL DEFAULT clock_timestamp());

CREATE TABLE IF NOT EXISTS impetus_fabric.exposed_sources (
    instance_id text NOT NULL REFERENCES impetus_fabric.processes(instance_id), source text NOT NULL,
    exposed_at timestamptz NOT NULL DEFAULT clock_timestamp(), PRIMARY KEY (instance_id, source));

CREATE TABLE IF NOT EXISTS impetus_fabric.service_offers (
    instance_id text NOT NULL, source text NOT NULL, service text NOT NULL, capabilities jsonb NOT NULL,
    offered_at timestamptz NOT NULL DEFAULT clock_timestamp(), PRIMARY KEY (instance_id, source, service),
    FOREIGN KEY (instance_id, source) REFERENCES impetus_fabric.exposed_sources(instance_id, source));

CREATE TABLE IF NOT EXISTS impetus_fabric.delivery_grants (
    sender text NOT NULL REFERENCES impetus_fabric.processes(instance_id), recipient text NOT NULL,
    source text NOT NULL, granted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (sender, recipient, source),
    FOREIGN KEY (recipient, source) REFERENCES impetus_fabric.exposed_sources(instance_id, source));

CREATE TABLE IF NOT EXISTS impetus_fabric.deliveries (
    sender text NOT NULL REFERENCES impetus_fabric.processes(instance_id), delivery_id text NOT NULL,
    recipient text NOT NULL REFERENCES impetus_fabric.processes(instance_id), source text NOT NULL,
    correlation text NOT NULL, envelope jsonb, digest text NOT NULL, submitted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    accepted_occurrence bigint, accepted_at timestamptz,
    PRIMARY KEY (sender, delivery_id),
    CHECK ((accepted_occurrence IS NULL) = (accepted_at IS NULL)),
    CHECK (envelope IS NOT NULL OR accepted_at IS NOT NULL));

CREATE INDEX IF NOT EXISTS fabric_pending_by_recipient ON impetus_fabric.deliveries (recipient, submitted_at) WHERE accepted_at IS NULL;

CREATE INDEX IF NOT EXISTS fabric_offers_by_service ON impetus_fabric.service_offers (service, instance_id, source);
```

The objects PostgreSQL 17 creates, as observed on the reference schema, are:

| Table | Constraint / index | Definition |
|---|---|---|
| `schema_metadata` | `schema_metadata_pkey` | PK `(component)` |
| `processes` | `processes_pkey` | PK `(instance_id)` |
| `exposed_sources` | `exposed_sources_pkey` | PK `(instance_id, source)` |
| | `exposed_sources_instance_id_fkey` | FK `(instance_id)` → `processes` |
| `service_offers` | `service_offers_pkey` | PK `(instance_id, source, service)` |
| | `service_offers_instance_id_source_fkey` | FK `(instance_id, source)` → `exposed_sources` |
| | `fabric_offers_by_service` | btree `(service, instance_id, source)` |
| `delivery_grants` | `delivery_grants_pkey` | PK `(sender, recipient, source)` |
| | `delivery_grants_sender_fkey` | FK `(sender)` → `processes` |
| | `delivery_grants_recipient_source_fkey` | FK `(recipient, source)` → `exposed_sources` |
| `deliveries` | `deliveries_pkey` | PK `(sender, delivery_id)` |
| | `deliveries_sender_fkey` | FK `(sender)` → `processes` |
| | `deliveries_recipient_fkey` | FK `(recipient)` → `processes` |
| | `deliveries_check` | `(accepted_occurrence IS NULL) = (accepted_at IS NULL)` |
| | `deliveries_check1` | `envelope IS NOT NULL OR accepted_at IS NOT NULL` |
| | `fabric_pending_by_recipient` | btree `(recipient, submitted_at) WHERE accepted_at IS NULL` |

All timestamps are `timestamptz` defaulted from `clock_timestamp()`: the wall
time of the statement, **not** the transaction start time and not commit
time. No column uses a non-default collation.

### 6.2 Column semantics (CONTRACT)

- `processes.credential_digest` is the SHA-256 hex digest of the credential's
  UTF-8 bytes (§7). The credential itself is never stored.
- `service_offers.capabilities` is the strict-JSON capability object.
- `deliveries.envelope` is the full envelope JSON form (§4.2) of the
  submitted envelope, as stored by the sender. It is `NULL` only after pruning.
- `deliveries.digest` is the sender-computed envelope digest (§4.2.2). It is
  authoritative and immutable.
- `deliveries.recipient`, `source`, and `correlation` duplicate the envelope's
  fields, so the row stays queryable after pruning. They MUST equal the
  envelope's fields.
- `deliveries.accepted_occurrence` and `accepted_at` are set together, once,
  by acknowledgement.
- `schema_metadata` has one row `('fabric', 1)`.

### 6.3 Provisioning protocol (`ensure_fabric_schema`) (CONTRACT)

Provisioning runs on the caller's connection and **never commits** on the
caller's behalf. On a non-autocommit connection, everything below joins the
caller's transaction, and a rollback undoes it. The steps are:

1. `SELECT 1 FROM pg_namespace WHERE nspname = 'impetus_fabric'`.
2. If the schema exists and `to_regclass('impetus_fabric.schema_metadata')` is
   `NULL`, query `information_schema.tables` for any of `processes`,
   `exposed_sources`, `service_offers`, `delivery_grants`, `deliveries` in
   that schema. If one exists, **refuse** with a schema error ("unversioned
   table … refusing to bless an unknown shape"). Unrelated tables in the schema
   do not block provisioning.
3. Execute the §6.1 statements in order.
4. `INSERT INTO impetus_fabric.schema_metadata (component, version) VALUES ('fabric', 1) ON CONFLICT (component) DO NOTHING`.
5. `SELECT version FROM impetus_fabric.schema_metadata WHERE component = 'fabric'`.
   If no row exists, or the version is not `1`, refuse with a schema error
   naming the found version and "migrate deliberately". There is no implicit
   upgrade or downgrade.

Provisioning is idempotent: running it twice is a no-op.

**ACCIDENT:** if `schema_metadata` exists but has no `'fabric'` row, step 4
blesses whatever tables exist, without a shape check. Two concurrent
first-time provisioners can race on `CREATE SCHEMA IF NOT EXISTS` and one can
fail with a catalog unique violation. Operators SHOULD provision once, before
starting hosts.

### 6.4 Notification channel (CONTRACT)

A fresh submission executes `SELECT pg_notify('impetus_fabric_delivery', <recipient>)`
inside its transaction. The notification is therefore delivered at commit,
and only if the submission commits. The payload is the recipient process
identity as plain text. Duplicates (§5.2) do not notify.

The notification is a **wake hint only**. The reference implementation has
no listener: recipients poll `pending` (§8.9). An implementation MAY LISTEN to
reduce latency, but MUST NOT treat a notification as a delivery or rely on
receiving one.

## 7 Processes and credentials

- `issue_credential()` returns a fresh opaque token. The reference uses
  `secrets.token_urlsafe(32)`, a 43-character base64url string.
  Issuance format is **ACCIDENT**. Only the acceptance rule below is CONTRACT.
- **Credential acceptance rule (CONTRACT):** a string whose UTF-8 encoding is
  **at least 32 bytes** and which contains **at least 16 distinct code
  points**. Anything else is refused ("high-entropy opaque token") before any
  database access, including at client construction. For example, `"x" * 40`
  and `"ab" * 20` are refused.
- **Credential digest (CONTRACT):** `sha256_hex(utf8(credential))`, lowercase.
- Digest comparison SHOULD be constant-time.

Credentials MUST NOT appear in any envelope, payload, offer, outcome, or
History record.

## 8 Operations

Each operation below states its local validation (performed before any
database access), its SQL protocol (statements in order), its transaction
behavior, and its outcomes. Parameters are bound, never interpolated.

### 8.1 Transaction joining (CONTRACT)

Every operation runs on a connection supplied by the caller and **never
commits a caller's transaction**:

- On an **autocommit** connection, each statement commits by itself, except
  that `submit` and `acknowledge` wrap their critical section in one explicit
  transaction (`BEGIN … COMMIT`, rolled back on any error or refusal).
- On a **non-autocommit** connection, every statement, including the
  `submit` and `acknowledge` sections, joins the caller's open transaction.
  Effects become visible only when the caller commits, and vanish on rollback.
  The `pg_notify` is then delivered at the caller's commit.

A database error (for example a foreign-key violation) inside a caller's
transaction aborts that transaction, per PostgreSQL rules.

### 8.2 Authentication step (CONTRACT)

The bound client `(instance, credential)` validates `instance` as Fabric text
and the credential by §7 at construction, without database access. Every
operation except `register_process` then begins with:

```sql
SELECT credential_digest FROM impetus_fabric.processes WHERE instance_id = $instance;
```

If there is no row, or the digest does not equal the credential digest, the
operation fails with **denied** ("fabric authentication failed for
'<instance>'") and executes nothing further. In `submit` and `acknowledge`,
this statement runs *before* the explicit transaction of §8.1. Authentication
is re-checked on every call. Registration is never cached.

### 8.3 `register_process(instance, credential)` (trusted operator bootstrap)

Validation: `instance` is Fabric text, and the credential satisfies §7. Then:

```sql
INSERT INTO impetus_fabric.processes (instance_id, credential_digest) VALUES ($instance, $digest) ON CONFLICT DO NOTHING;
-- if no row was inserted:
SELECT credential_digest FROM impetus_fabric.processes WHERE instance_id = $instance;
```

The outcomes are:

- inserted: success;
- an existing row with an equal digest: success (idempotent);
- an existing row with a different digest: **invalid** ("already registered
  with a different credential"), with nothing changed.

There is no unregister, credential-rotation, or exposure-removal operation in
version 1.

### 8.4 `expose_source(source)`

Validation: `source` is Fabric text. Then authentication, followed by:

```sql
INSERT INTO impetus_fabric.exposed_sources (instance_id, source) VALUES ($self, $source) ON CONFLICT DO NOTHING;
```

The operation is idempotent. Re-exposing does not change `exposed_at`.

### 8.5 `offer_service(source, service, capabilities)`

Validation: `source` and `service` are Fabric text, and `capabilities` is a
JSON object (`TypeError` otherwise) of strict JSON. Then authentication,
followed by:

```sql
INSERT INTO impetus_fabric.service_offers (instance_id, source, service, capabilities)
VALUES ($self, $source, $service, $capabilities::jsonb) ON CONFLICT (instance_id, source, service)
DO UPDATE SET capabilities = EXCLUDED.capabilities, offered_at = clock_timestamp();
```

Re-offering **replaces** the capabilities and refreshes `offered_at`. Offering
on a source this process has not exposed fails with a **storage** error
(`service_offers_instance_id_source_fkey` violation). Offers cannot be
withdrawn in version 1.

### 8.6 `grant(sender, source)` / `revoke(sender, source)`

The recipient (the bound client) authorizes or deauthorizes a sender on one
of its own sources. Validation: both arguments are Fabric text. Then
authentication, followed by:

```sql
-- grant
INSERT INTO impetus_fabric.delivery_grants (sender, recipient, source) VALUES ($sender, $self, $source) ON CONFLICT DO NOTHING;
-- revoke
DELETE FROM impetus_fabric.delivery_grants WHERE sender = $sender AND recipient = $self AND source = $source;
```

- Granting is idempotent. Granting to an unregistered sender fails with a
  **storage** error (`delivery_grants_sender_fkey`). Granting on an unexposed
  source fails with a **storage** error
  (`delivery_grants_recipient_source_fkey`).
- Revoking an absent grant is a successful no-op.
- Revocation affects **future** submissions only. Deliveries already stored
  stay pending and deliverable, and exact retransmissions of them still
  succeed (§5.2).

### 8.7 `discover(service, capabilities = {})`

Validation: `service` is Fabric text. `capabilities` defaults to `{}` and must
be a JSON object of strict JSON. Then authentication, followed by:

```sql
SELECT o.instance_id, o.source, o.capabilities FROM impetus_fabric.service_offers o
JOIN impetus_fabric.delivery_grants g ON (g.recipient, g.source) = (o.instance_id, o.source)
WHERE g.sender = $self AND o.service = $service AND o.capabilities @> $wanted::jsonb
ORDER BY o.instance_id, o.source;
```

Discovery is **deny-by-default**: a caller sees only offers on sources that
have been granted *to the caller*. Matching uses PostgreSQL `jsonb`
containment `@>` (**CONTRACT**, inherited):

- objects match recursively by subset;
- arrays match as unordered subsets, so `["git"]` is contained in
  `["shell","git"]`;
- scalars match by jsonb equality, so `1` matches `1.0`;
- an array never contains a bare scalar at a nested position, so
  `{"tools":"shell"}` is **not** contained in `{"tools":["shell"]}`;
- `{}` matches every offer.

The result is a sequence of Endpoints (§4.3) in the SQL order. Because the
database sorts by its default collation, two implementations that issue this
SQL against one database observe the same order. The order is collation
dependent, and conformance tests SHOULD NOT depend on it beyond that
(**ACCIDENT:** collation sensitivity).

### 8.8 `submit(envelope)` (alias `send`)

Local validation:

1. The argument is an Envelope (§4.2). Constructing it already enforced every
   value rule and the payload limit.
2. `envelope.sender` must equal the bound instance. Otherwise the call fails
   with **denied** ("envelope sender must match the authenticated fabric
   client"), with no database access.

SQL protocol (CONTRACT, in order):

```sql
-- (a) authentication, §8.2 (outside the transaction on autocommit connections)
-- (b) BEGIN, on an autocommit connection only
SELECT digest, accepted_occurrence, accepted_at FROM impetus_fabric.deliveries
 WHERE sender = $sender AND delivery_id = $delivery_id FOR UPDATE;              -- (c)
--   row found: go to PRIOR
SELECT 1 FROM impetus_fabric.exposed_sources e JOIN impetus_fabric.delivery_grants g
  ON (g.recipient, g.source) = (e.instance_id, e.source)
 WHERE e.instance_id = $recipient AND e.source = $source AND g.sender = $sender;  -- (d)
--   no row: denied ("recipient source is not exposed and granted to this sender"); roll back
INSERT INTO impetus_fabric.deliveries
  (sender, delivery_id, recipient, source, correlation, envelope, digest)
VALUES ($sender, $delivery_id, $recipient, $source, $correlation, $envelope::jsonb, $digest)
ON CONFLICT DO NOTHING;                                                           -- (e)
--   0 rows inserted (a concurrent submitter won; PostgreSQL waited for it):
--     re-run (c) and go to PRIOR
SELECT pg_notify('impetus_fabric_delivery', $recipient);                          -- (f)
-- (g) COMMIT, on an autocommit connection only
```

PRIOR, with the row `(digest, accepted_occurrence, accepted_at)`, works as
follows:

- If the stored digest differs from the envelope digest, the result is
  **conflict** ("fabric delivery identity conflict for (sender, delivery_id):
  content or address changed"). Nothing is written.
- Otherwise the call returns a Submission with `duplicate = true`,
  `state = "accepted"` if `accepted_at` is non-null and `"pending"`
  otherwise, and the stored `occurrence` and `accepted_at`.

A fresh insert returns `Submission(sender, delivery_id, "pending", false, null, null)`.

Notes:

- Authorization is checked only for fresh inserts, and only by the exposure
  and grant join. The recipient's registration is implied by the exposure's
  foreign key. An unregistered or unexposed recipient is reported as
  **denied**, never as a storage error.
- `envelope` stores the sender's §4.2 JSON form. `digest` stores the sender's
  §4.2.2 digest. A conforming writer MUST compute the digest from the exact
  value it stores, before any database normalization.
- **ACCIDENT:** Python `ON CONFLICT DO NOTHING` has no conflict target.
  `deliveries` has only the primary-key unique constraint, so the behavior is
  the same.

### 8.9 `pending(limit = 100)`

Validation: `limit` is an integer ≥ 1. Booleans are refused (`ValueError`).
Then authentication, followed by:

```sql
SELECT envelope FROM impetus_fabric.deliveries WHERE recipient = $self AND accepted_at IS NULL
ORDER BY submitted_at, sender, delivery_id LIMIT $limit;
```

Each row is decoded with the strict Envelope decoder (§4.2), after the §3.5
database round trip. A malformed stored envelope makes `pending` fail, and
therefore blocks the inbox (§9.3).

The order is `submitted_at` (the insert statement's wall clock), then
`sender`, then `delivery_id` under the database default collation.
`submitted_at` is taken at insert, not at commit, so a delivery inserted
earlier but committed later can become visible *after* a later one was already
returned. Fabric guarantees **no ordering** across senders, and none across
concurrent submissions of one sender. Sequential, committed submissions from
one sender are returned in submission order, unless the database server's wall
clock steps backwards.

### 8.10 `acknowledge(sender, delivery_id, occurrence)`

Validation: `sender` and `delivery_id` are Fabric text. `occurrence` is an
integer ≥ 1, and booleans are refused. Then authentication, followed by:

```sql
-- BEGIN, on an autocommit connection only
SELECT recipient, source, correlation, digest, accepted_occurrence, accepted_at, envelope IS NOT NULL
  FROM impetus_fabric.deliveries
 WHERE sender = $sender AND delivery_id = $delivery_id AND recipient = $self FOR UPDATE;
--   no row: not-found ("pending delivery (sender, delivery_id) does not exist for this recipient")
--   accepted_occurrence IS NOT NULL AND accepted_occurrence <> $occurrence:
--       conflict ("delivery was already accepted by occurrence N, not M")
--   accepted_occurrence IS NULL:
UPDATE impetus_fabric.deliveries SET accepted_occurrence = $occurrence, accepted_at = clock_timestamp()
 WHERE sender = $sender AND delivery_id = $delivery_id RETURNING accepted_at;
-- COMMIT, on an autocommit connection only
```

The result is
`Receipt(sender, delivery_id, recipient, source, stored digest, "accepted", occurrence, accepted_at, envelope_was_present)`.
Re-acknowledging with the same occurrence returns the original `accepted_at`.
Acknowledgement is recipient-bound: a process cannot acknowledge a delivery
addressed to another process (**not-found**). Acknowledging a pruned delivery
with its own occurrence still succeeds, with `payload_retained = false`.

Fabric does not verify that `occurrence` exists in the recipient's History.
Only the ingress bridge (§9) supplies it.

### 8.11 `receipt(delivery_id)` (sender side)

Validation: `delivery_id` is Fabric text. Then authentication, followed by:

```sql
SELECT recipient, source, digest, accepted_occurrence, accepted_at, envelope IS NOT NULL
  FROM impetus_fabric.deliveries WHERE sender = $self AND delivery_id = $delivery_id;
```

No row gives `null` (absent). Receipts are sender-scoped: a recipient that
asks about its own inbound delivery id gets `null`. Otherwise the result is
the Receipt of §4.5.

### 8.12 `prune_accepted(before)` (recipient side)

Validation: `before` must be a timezone-aware instant. A naive timestamp is
refused ("pruning cutoff must be a timezone-aware datetime"). Then
authentication, followed by:

```sql
UPDATE impetus_fabric.deliveries SET envelope = NULL
 WHERE recipient = $self AND accepted_at < $before AND envelope IS NOT NULL;
```

The result is the number of rows changed. Pruning removes only the inline
envelope bytes. The row, `digest`, `correlation`, and acceptance remain
**forever**, so retransmission dedup and conflict detection keep working
(§5.2). Pending deliveries can never be pruned, which is enforced by
`deliveries_check1`. Version 1 has no operation that deletes delivery rows.

## 9 Ingress bridge: Fabric to Engine

### 9.1 Token form (CONTRACT)

A delivery enters the recipient's net as **exactly one token** delivered to
the source transition named by `envelope.source`:

- color: `"FabricEnvelope"`;
- data: the envelope JSON form (§4.2), as read from `pending` (§3.5), with all
  eight members, including `"version": 1` and `"reply_route"`.

The delivery identity passed to the door is `envelope.ingress_identity`
(§4.2.3). No lifecycle scope is passed: Fabric deliveries are unscoped. The
recipient's net receives the token through the ordinary source-transition
ingress of [firing-semantics.md](../upstream/petrus/spec/firing-semantics.md)
and records it as `ExternalEventDelivered` with that identity
([event-history.md](../upstream/petrus/spec/event-history.md)).

### 9.2 Drain algorithm (`FabricInbox.drain(limit)`)

```text
for envelope in pending(limit):                                 # §8.9 order
    result = engine.deliver(envelope.source,
                            [Token("FabricEnvelope", envelope.to_data())],
                            identity = envelope.ingress_identity)
    require result is FiringOutcome or PriorAcknowledgement     # else TypeError
    acknowledge(envelope.sender, envelope.delivery_id, result.occurrence)
return receipts
```

- A fresh delivery is accepted and completed by the door, which returns the
  source firing's occurrence.
- A redelivery whose accepted occurrence is still unfinished is completed by
  the door. A redelivery whose occurrence ended returns `PriorAcknowledgement`
  with the original occurrence. Neither appends a second acceptance.
- Therefore, after a crash **between** the door's commit and the Fabric
  acknowledgement, the next drain acknowledges with the same occurrence
  (**CONTRACT**, tested).
- The Engine door commits the recipient History. The Fabric acknowledgement
  is a separate, later commit. Never acknowledge before the door has durably
  accepted.

### 9.3 Failure behavior (CONTRACT)

If the door raises, drain stops and propagates the error. Deliveries
acknowledged earlier in the same drain stay acknowledged. The failing delivery
and every later one stay pending. Because `pending` order is stable, a
delivery that the door always refuses blocks the recipient's inbox at its
position (head-of-line blocking) until an operator intervenes. Version 1 has
no dead-letter, skip, or retry-limit mechanism. Typical permanent refusals
are:

- the source has no armed delivery registration (for example a sealed reply
  source, or a late reply after the registration closed);
- `envelope.source` is not a source transition of the recipient's net;
- a delivery-identity conflict in the recipient's History;
- a malformed stored envelope (§8.9).

The same applies to a door result of any other type (`TypeError`). Hosts
SHOULD keep a source armed for as long as any sender may still deliver to it,
or accept that late deliveries block the inbox.

When the door is a reference Engine, a refusal is a failure inside a writing
door. It therefore also **poisons that Engine**. Every later operation on that
Engine object, including reads such as `records` and `status`, raises
`RuntimeError("this Engine is poisoned after a writing door failed …")`. The
host continues through a fresh load (`load_engine`), and the fresh Engine
refuses the same pending delivery in the same way. Nothing is appended to the
recipient's History by the refused attempts. An implementation whose door is
an Engine MUST behave the same way, so that a host written against either
implementation recovers the same way.

## 10 Delivery guarantees summary

| Property | Guarantee |
|---|---|
| Storage | A submission is durable once its transaction commits. Exactly one row exists per `(sender, delivery_id)`. |
| Sender idempotency | Exact retransmission is a no-op success at any later time, even after revocation or pruning. Changed content is a conflict. |
| Delivery to recipient | At least once: pull-based, repeated until acknowledged. No TTL, expiry, or retry scheduling. |
| Acceptance | Effectively once, through the recipient door's identity dedup plus single-occurrence acknowledgement. |
| Ordering | None across senders or concurrent submissions. Best-effort `(submitted_at, sender, delivery_id)`. |
| Wake-up | Optional NOTIFY hint at commit. Polling is authoritative. |
| Retention | Envelope bytes are prunable after acceptance. Identity, digest, and acceptance are retained forever. |
| Authorization | Deny by default. Exposure plus grant per `(sender, recipient, source)`, checked at first submission only. |
| Meaning | A receipt means canonical ingress acceptance only. It says nothing about processing, completion, or effects. |

## 11 Send side: the `fabric.send` activity profile

The Python library ships **no** send activity. Senders submit from inside an
impure handler's Activity, so the send is frozen in the sender's History before
it happens. Both reference demos (`cv5-fabric-demo.py`,
`cv5-lifecycle-demo.py`) use one identical profile. This port adopts it as the
interoperable profile (**CONTRACT for this port**; upstream: demo convention).
It matters whenever a Python Engine's Activity may be executed by a Haskell
worker, or the reverse:

- Activity name: `"fabric.send"`.
- `ActivityInvocation.input`: the envelope JSON form (§4.2).
- `ActivityInvocation.correlation`: `envelope.correlation`.
- `ActivityInvocation.idempotency`: `envelope.ingress_identity`. The executor
  MUST refuse an invocation whose idempotency differs from the decoded
  envelope's ingress identity.
- Execution: decode the envelope strictly, then `submit` it with a client bound
  to `envelope.sender`.
- Result (frozen as `ActivityCompleted`): the exact object
  `{"state": <"pending"|"accepted">, "duplicate": <bool>, "delivery_id": <text>, "correlation": <text>}`.

Because the invocation is frozen, every operational retry resubmits the
identical envelope and converges through §5.2. A retry after the first
submission's commit returns `duplicate: true`. Only the first terminal
Activity result enters History.

## 12 Error categories

Implementations MUST distinguish these categories. The exception classes in
the table are the Python spellings, and the messages are informative.

| Category | Python | Raised by |
|---|---|---|
| invalid | `ValueError` / `TypeError` | text, JSON, payload size, version, exact-shape, limit, occurrence, or credential violations; tz-naive prune cutoff |
| conflict | `ValueError` | changed content under one delivery identity (§5.2); a different acceptance occurrence (§8.10); registration with a different credential (§8.3) |
| denied | `PermissionError` | authentication failure (§8.2); sender ≠ bound instance; recipient source not exposed and granted |
| not-found | `LookupError` | acknowledging a delivery that is not addressed to this recipient or does not exist |
| schema-refused | `RuntimeError` | unversioned known tables; schema version ≠ 1 |
| storage | driver error | foreign-key violations from `offer_service` and `grant` (§8.5, §8.6); NUL in text or JSON (§3.1) |

Refusals in the invalid and denied categories that are detected before the
database is touched leave no trace. Refusals inside `submit` and `acknowledge`
leave shared state unchanged.

## 13 Versioning

- Envelope `version` is `1`, decoded exactly. There is no negotiation and no
  fallback.
- `impetus_fabric.schema_metadata('fabric').version` is `1`. A runtime refuses
  any other value and never migrates implicitly.
- The ingress identity prefix `fabric:` and the token color `FabricEnvelope`
  are part of version 1.
- Any change to §3.3 encoding, §4 fields, §6 schema, or §8 SQL semantics is
  a new protocol version, and per [UPSTREAM.md](../UPSTREAM.md) requires moving
  the pin.

## 14 Implementation accidents and non-contract details

| Python behavior | Classification | Guidance |
|---|---|---|
| NUL admitted at construction, fails at the database | ACCIDENT | reject early (§3.1) |
| Lone surrogate raises `UnicodeEncodeError` | ACCIDENT | reject as invalid |
| `issue_credential` = `token_urlsafe(32)` | ACCIDENT | any rule-conforming credential |
| Empty `schema_metadata` blessed without a shape check | ACCIDENT | do not rely on it |
| Concurrent first provisioning may fail | ACCIDENT | provision before hosts start |
| Collation-dependent `ORDER BY` tiebreaks | ACCIDENT (the SQL itself is CONTRACT) | issue the same SQL; do not assert collation order |
| Telemetry events (`fabric_registered`, `fabric_exposed`, `fabric_offered`, `fabric_granted`, `fabric_submitted`, `fabric_redelivered`, `fabric_accepted`, `fabric_pruned`, `fabric_denied`, `fabric_conflict` on logger `impetus`; `revoke` logs nothing) | informative | names MAY be mirrored for operational parity |
| `jsonb` normalization of floats, `-0.0`, and key order | CONTRACT (inherited) | §3.5 |
| Exact error message text | informative | categories are CONTRACT (§12) |

## 15 Worked examples

The values below were produced by the reference implementation at the pin.
Credentials are fixed test strings. Timestamps vary.

### 15.1 Registration

The credential `caller-credential-0123456789-abcdefghijklmnop` produces this
row:

```text
impetus_fabric.processes: ('caller', 'f87d0d9624b9288fbcea1554e00abffbd965251aef9d310ca9e63e025cca36a5', <registered_at>)
```

### 15.2 Routing setup

The callee runs `expose_source("calls")`,
`offer_service("calls", "answerer", {"protocol":"call-v1","features":["reply"]})`,
and `grant("caller", "calls")`. The caller runs `expose_source("replies")`
and `grant("callee", "replies")`.

`caller.discover("answerer", {"features":["reply"]})` then returns:

```text
(Endpoint(recipient="callee", source="calls", capabilities={"features":["reply"],"protocol":"call-v1"}),)
```

### 15.3 One submission, retransmission, acceptance

The envelope is the call request of [processes.md §8](processes.md). Its JSON
form, as emitted:

```json
{"version":1,"delivery_id":"process-call-v1-request-5d7963c4f471e142f5a72214a9666fb164718f9ba1066a7862ac1c5041887940","sender":"caller","recipient":"callee","source":"calls","correlation":"call-1","payload":{"version":1,"kind":"process.call.request","call_id":"call-1","operation":"answer","input":{"question":42}},"reply_route":{"instance_id":"caller","source":"replies"}}
```

Its canonical bytes (§3.3):

```json
{"correlation":"call-1","delivery_id":"process-call-v1-request-5d7963c4f471e142f5a72214a9666fb164718f9ba1066a7862ac1c5041887940","payload":{"call_id":"call-1","input":{"question":42},"kind":"process.call.request","operation":"answer","version":1},"recipient":"callee","reply_route":{"instance_id":"caller","source":"replies"},"sender":"caller","source":"calls","version":1}
```

- digest: `e838ab15859a2bcadbb3d2c17fe2fcf8a7b0a5e62a0dcf3b8e2b969b1120990e`
- ingress identity: `fabric:6:caller:process-call-v1-request-5d7963c4f471e142f5a72214a9666fb164718f9ba1066a7862ac1c5041887940`

The first `submit` returns `("pending", duplicate=false)` and notifies
`impetus_fabric_delivery` with payload `callee`. The second returns
`("pending", duplicate=true)` and does not notify. The row after submission is
shown below; the `envelope` text is PostgreSQL's `jsonb` rendering, with keys
reordered:

```text
sender='caller' delivery_id='process-call-v1-request-5d79…7940' recipient='callee' source='calls'
correlation='call-1'
envelope={"sender": "caller", "source": "calls", "payload": {"kind": "process.call.request", "input": {"question": 42}, "call_id": "call-1", "version": 1, "operation": "answer"}, "version": 1, "recipient": "callee", "correlation": "call-1", "delivery_id": "process-call-v1-request-5d79…7940", "reply_route": {"source": "replies", "instance_id": "caller"}}
digest='e838ab15859a2bcadbb3d2c17fe2fcf8a7b0a5e62a0dcf3b8e2b969b1120990e'
accepted_occurrence=NULL accepted_at=NULL
```

The callee's drain calls the door with
`("calls", [Token("FabricEnvelope", <envelope JSON>)], identity="fabric:6:caller:process-call-v1-request-5d79…7940")`.
Suppose the door returns occurrence `2`. Acknowledgement then sets
`accepted_occurrence=2` and `accepted_at=<clock_timestamp()>`.

`caller.receipt(...)` now returns
`Receipt(…, state="accepted", occurrence=2, payload_retained=true)`. A later
`prune_accepted(now+1s)` by the callee nulls `envelope`. The row keeps
`digest` and `accepted_occurrence=2`, and a resubmission of the identical
envelope returns `("accepted", duplicate=true, occurrence=2)`.
