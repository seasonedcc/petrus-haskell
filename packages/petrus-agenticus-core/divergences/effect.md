# Effect divergences (`Petrus.Agenticus.Effect.*`)

These are deliberate. None of them changes a wire byte or a refusal that a
JSON caller can observe; the differential corpus pins that.

## Values

1. **Payloads have no floats, by type.** The reference checks for floats at
   run time (`_strict_json`). Here, `EffectPayload` wraps a
   `Map Text PayloadValue`, and `PayloadValue` has only these cases:

   - null
   - bool
   - `Integer`
   - `Text`
   - list
   - object

   `payloadFromJson` is the single entry point from `Json`. It raises the
   reference's two `TypeError`s:

   - "effect payload must be a strict JSON object"
   - "effect payload must contain only strict JSON values; …"

   The third refusal, "effect payload object keys must be strings", cannot
   arise, because keys are `Text`. Python tuples and other extended values
   cannot arise either.

   Objects are `Map`s:

   - Duplicate members keep the last value, as `json.loads` does when it
     builds a dict.
   - Iteration is already in code-point order, which is the order
     `sort_keys=True` writes.

2. **Canonical payload bytes come from a dedicated writer.** The reference
   computes `json.dumps(…, ensure_ascii=False, sort_keys=True,
   separators=(",", ":"))` twice per digest, with a `json.loads` in between.
   The port does it once:

   - It writes the payload directly as a `Builder`.
   - It escapes per UTF-8 byte: `\"`, `\\`, `\n`, `\r`, `\t`, `\b`, `\f`,
     and lowercase `\u00XX` for the other controls.
   - It hashes the bytes as they stream.

   A QuickCheck property checks this writer against petrus-json's
   `compact`+`sortKeys` encoder, and the corpus checks it against CPython.

3. **`LookupResult` is a sum type:**
   `LookupApplied EffectReceipt | LookupSafeToRetry | LookupSuperseded | LookupIndeterminate`.
   The upstream rule "only an applied lookup requires an EffectReceipt" is
   structural. `mkLookupResult` keeps the reference constructor and its
   `ValueError`. The upstream fields are virtual record fields:
   `.disposition` and `.receipt`.

4. **`EffectEvidence` carries one `EvidenceOutcome`.** The reference stores
   a `(recovery, receipt_digest)` pair; the port stores one of:

   - `DirectExecution digest`
   - `RecoveredApplied digest`
   - `RecoveredSafeToRetry`
   - `RecoveredSuperseded`
   - `RecoveredIndeterminate`

   The reference's three run-time pairing rules are therefore structural.
   `mkEffectEvidence` keeps the reference constructor, with its checks in
   the reference order and its exact messages. `.recovery` and
   `.receiptDigest` are virtual fields.

5. **`EffectDecision` is `Rejected id digest reason | Approved fence | Concluded evidence`.**
   The decision's coordinates come from its fence or evidence. Its kind
   comes from the evidence outcome:

   - direct → `execute`
   - applied → `already-applied`
   - superseded → `superseded`
   - safe-to-retry or indeterminate → `indeterminate`

   This removes the cross-field validator. `mkEffectDecision` is the
   reference constructor, with every check in order. The factories are:

   - `reject` and `approve`: as upstream;
   - `concluded`: total. Evidence already correlates with its fence and
     proposal, so the result is always valid.

   `.kind`, `.proposalId`, `.proposalDigest`, `.fence`, `.evidence` and
   `.reasonCode` are virtual fields.

6. **`EffectProposal` caches its digest.** `.digest` is a lazy field,
   computed once, on first use, from the canonical `to_data`. The reference
   recomputes it on every access, about five times per gateway call.
   Equality ignores the cache, which is a function of the other fields.

7. **Constructors have two validation orders.** `mk*` constructors check in
   `__post_init__` order. `*FromData` decoders check in the reference's
   argument-evaluation order. An `EffectFence` shows the difference: its
   constructor checks the four text fields before the digest and epochs,
   while `from_data` checks the fields in key order. The order matters only
   when more than one field is invalid, and both orders match the
   reference.

8. **Integers are unbounded.** CPython 3.11+ refuses to write integers of
   more than 4 300 digits (`sys.set_int_max_str_digits`); the port digests
   them. The corpus stays within the CPython limit. Payloads nested deeper
   than CPython's recursion limit also digest here instead of raising
   `RecursionError`.

## Gateway

9. **Protocols are records of `IO` functions.** They are `EffectAdapter`
   (`lookup`, `execute`) and `EffectFenceSource` (`current`). The adapter's
   `execute` receives the admitted `EffectPayload`, the counterpart of the
   reference's canonical dict copy.

10. **Exception boundary.** The reference catches `except Exception`. The
    port catches every synchronous exception and forces the answer to WHNF
    inside that boundary, so a lazily failing answer is caught too. Two
    kinds of exception propagate, as `KeyboardInterrupt` and `SystemExit`
    do upstream:

    - asynchronous exceptions;
    - `ExitCode`.

    Upstream also turns wrong return types into `indeterminate`: a lookup
    that is not a `LookupResult`, a fence that is not an `EffectFence`, or a
    receipt that is not an `EffectReceipt`. The types rule all three out.
    The ported "wrong-type" fence test uses a malformed value that fails
    when forced instead.

11. **Two entry points.**

    - `executeJson` takes a decoded `Json` payload and keeps the reference
      order exactly: approval check, payload admission (`TypeError`), then
      digest (`ValueError`).
    - `execute` takes an already-admitted `EffectPayload`.

    Everything else is shared.

12. **The gateway's `"effect gateway requires EffectProposal"` check and the
    `isinstance` checks in the value constructors** cannot fail, so they
    have no Haskell counterpart.
