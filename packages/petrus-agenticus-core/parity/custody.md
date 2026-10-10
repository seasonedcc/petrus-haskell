# Connection custody parity (`petrus.agenticus.connection`)

Upstream: `src/petrus/agenticus/connection/{key,materialization,storage,custody}.py`,
at the pinned `upstream/petrus` 3f85fc2.

Haskell modules:

- `Petrus.Agenticus.Connection.Key`: `KeyContext`, `authenticatedData`,
  `KeyErasureEvidence`, the `KeyOperations` record, and `eraseBuffer`.
- `Petrus.Agenticus.Connection.Materialization`: `PrivateFileMaterializer`,
  `MaterializedState`, `CleanupEvidence`, and `CleanupSummary`.
- `Petrus.Agenticus.Connection.Storage`: the stored values,
  `validateSnapshot`, the payload codec, and `openSqliteConnectionStorage`.
- `Petrus.Agenticus.Connection.Custody`: `AgentConnectionCustody` and its
  operations.
- `Petrus.Agenticus.Internal.Sqlite`: the SQLite access layer, built on
  direct-sqlite. It is the swap point for `petrus-sqlite`.
- `Petrus.Agenticus.Internal.PyRepr`: `repr()` of strings, for messages.

The tests live in `test/Petrus/Agenticus/ConnectionSpec.hs`, under
`describe "connection/test_custody.py"`. Each `it` label is the upstream test
name, with the pytest parameter id when the test is parametrized.

Upstream has 21 test functions with 24 collected cases. All of them are
ported, and none is skipped or pending.

## API map

| Upstream | Haskell |
| --- | --- |
| `KeyContext(connection_id, authority_epoch, state_version)` | `mkKeyContext` (returns `Either`) |
| `KeyContext.authenticated_data()` | `authenticatedData` |
| `KeyErasureEvidence(connection_id, erased)` | `mkKeyErasureEvidence` |
| `KeyOperations` protocol (`seal`, `open`, `erase`) | `KeyOperations {seal, open, erase}`, a record of `IO` functions over `ScrubbedBytes` |
| `KeyOperationError(msg)` | `keyOperationError` / `AgenticusError KeyOperationError` |
| `PrivateFileMaterializer(root)` | `newPrivateFileMaterializer` |
| `.materialize / .read / .replace / .cleanup / .summarize` | `materializeState`, `readState` (or `readStateScrubbed`), `replaceState`, `cleanup`, `summarize` |
| `MaterializedState.path / .erased / .read() / .replace()` | `materializedPath`, `materializedErased`, `readMaterialized`, `replaceMaterialized` |
| `StoredHost / StoredConnection / StoredLease / AuditRecord / StorageSnapshot` | records of the same names and fields |
| `validate_snapshot` | `validateSnapshot` |
| `_encode / _decode` | `encodeSnapshot` / `decodeSnapshot` |
| `ConnectionStorage` protocol | `ConnectionStorage {load, compareAndSwap, close}` |
| `SqliteConnectionStorage(path)` | `openSqliteConnectionStorage` |
| `OpaqueState(content)` | `newOpaqueState` (copies the bytes) / `opaqueStateFromBuffer` (takes ownership of a buffer) |
| `ConnectionIdentity(...)` | `mkConnectionIdentity` |
| `AgentConnectionCustody(storage, keys, materializer, clock=...)` | `agentConnectionCustody storage keys materializer clock`, plus `withCustodyLogger` |
| `enroll_host`, `remove_host`, `authorize`, `materialize`, `activate`, `renew`, `checkpoint`, `release`, `rotate`, `revoke`, `erase` | the same names in camelCase; the keyword-only `operation_id` is the last positional argument |
| `admit_result` / `admit_effect` | `admitResult` / `admitEffect`. `admitResult` is what the attachment layer calls (`custody.admit_result(fence, operation_id=call_id)`). |
| `connection(connection_id)` | `lookupConnection` |
| `recover`, `lookup_operation`, `audit_records`, `close` | `recover`, `lookupOperation`, `auditRecords`, `closeCustody` |
| `_fence(lease)` | `fenceOf` |
| `"lease-" + sha256(op)[:32]` and the other derived ids | `derivedIdentity` |
| `_CAS_ATTEMPTS = 8` | `casAttempts` |
| `StorageError`, `StorageSecurityError`, `MaterializationError`, `MaterializationSecurityError`, `CustodyError` and its subclasses | `ErrorClass` constructors, with the same inheritance chain |

## Byte-level guarantees

All of these are pinned by `differential/custody_corpus.json`:

- **SQLite DDL.** `sqlite_master.sql` is the same text, including the
  leading newline and the 12-space indentation. The initial row is the same.
  The connection opens with `journal_mode = DELETE`, `synchronous = FULL` and
  a 5 s busy timeout. The compare-and-swap is `BEGIN IMMEDIATE`, then the
  verbatim `UPDATE`, then `COMMIT`, or `ROLLBACK` when no row changed.
- **Payload text.** It is `json.dumps(sort_keys=True, separators=(",", ":"))`
  with `ensure_ascii=True` and float `repr`. Encrypted state is standard
  base64. Decoding follows CPython's `b64decode(validate=True)`.
- **Authenticated data.** `petrus-agenticus-connection/v1\0{id}\0{epoch}\0{version}`.
- **Refusals.** Every message is `str(error)` exactly, and every class
  matches.

## `tests/petrus/agenticus/connection/test_custody.py` (21 functions, 24 cases)

| Upstream test | Haskell | Notes |
| --- | --- | --- |
| `test_ordinary_materialization_moves_one_logical_connection_between_hosts` | same label | |
| `test_concurrent_refresh_has_one_cas_winner_and_waits_for_readers` | same label | Python threads and `threading.Barrier` become `forkFinally` workers with an STM barrier that has a 5 s timeout. |
| `test_current_host_renews_bounded_read_and_current_attachments_are_admitted` | same label | |
| `test_materialization_and_renewal_refuse_nonfinite_lease_bounds[nan]`, `[inf]` | same labels | |
| `test_operation_lookup_reconciles_a_lost_publication_acknowledgement` | same label | |
| `test_cas_contention_is_bounded_and_publishes_no_operation` | same label | |
| `test_crash_before_provider_mutation_reconciles_to_last_accepted_state` | same label | |
| `test_crash_after_provider_rotation_fails_closed_to_reauthorization` | same label | |
| `test_recovery_sweeps_released_plaintext_left_after_publication_crash` | same label | |
| `test_stale_writer_never_replaces_a_newer_rotated_authority` | same label | |
| `test_rotation_supersedes_an_expired_unreconciled_refresh_lease` | same label | |
| `test_releasing_activated_refresh_fails_closed_and_is_idempotently_cleanable` | same label | |
| `test_host_removal_and_reenrollment_fence_old_custody_and_clean_reachable_state` | same label | |
| `test_revoke_fences_every_attachment_and_returns_secret_free_cleanup` | same label | |
| `test_erase_is_key_backed_retryable_and_requires_explicit_reauthorization` | same label | |
| `test_secret_canaries_never_reach_durable_rendered_or_cleanup_evidence` | same label | `caplog` becomes the custody logger callback. The port also asserts one log line per audit record. |
| `test_materialization_refuses_permissive_modes_and_symlink_substitution` | same label | |
| `test_sqlite_storage_enforces_private_modes_and_refuses_symlink_files` | same label | |
| `test_storage_validation_refuses_state_the_live_writer_cannot_publish` | same label | |
| `test_empty_provider_return_is_not_published` | same label | |
| `test_terminal_and_fail_closed_states_never_materialize[revoked-revoke]`, `[erasure_pending-erase-pending]`, `[reauthorization_required-erased]` | same labels | |

The fixtures are in `test/Petrus/Agenticus/ConnectionSupport.hs`:

- the fake clock at 1000.0;
- AES-256-GCM key operations with a counter nonce and an erased-key set;
- the fake rotating OAuth provider;
- the rig over a real SQLite file and materializer.

No real provider or model API is called.

## Differential and interop

`differential/custody_corpus.py` runs under the reference and writes
`custody_corpus.json`. `test/Petrus/Agenticus/CustodyCorpusSpec.hs` replays
it. The corpus contains:

- **Schema.** The `sqlite_master` rows of a fresh store and its initial row.
  The Haskell store must have identical text.
- **Key contexts.** 8 `KeyContext` cases: the `authenticated_data()` bytes,
  or the refusal.
- **Payload cases.** 86 stored payload texts, taken from real sessions plus
  mutations. They cover wrong shapes, strict-base64 edge cases, NaN, ±inf and
  integer expiries, every validation invariant, duplicate members and escapes.
  Each case records the outcome of `_encode(_decode(text))`: the canonical
  text, or the refusal class and message.
- **Sessions.** 30 seeded sessions of 50 steps each, run against a real
  SQLite file and materializer:
  - Steps are drawn from enroll, remove, authorize, materialize (read and
    refresh, with odd TTLs), activate, renew, a provider refresh inside the
    home, emptying the home, checkpoint, release, rotate, revoke, erase (with
    injected key-erasure failure and retry under the same operation id),
    admit_result / admit_effect (with a forged fence), recover, lookup,
    connection, clock advances, and reused operation ids.
  - After every step the corpus records the outcome (result data, or class
    and message), the store revision, the SHA-256 of the exact payload text,
    and the materialized file names.
  - Every tenth step, and the last step, also records the full payload text.

The keys in the corpus are AES-GCM with a nonce derived from the context and
the plaintext, so sealing is a pure function. A session can therefore move
between implementations.

`test/Petrus/Agenticus/CustodyInteropSpec.hs` uses
`differential/custody_interop.py`. For 6 seeds, each split at 17 and at 33
steps, it does two runs:

- Haskell runs the prefix and the reference runs the rest.
- The reference runs the prefix and Haskell runs the rest.

Both runs share one installation directory, meaning the same SQLite file and
the same materialization root. Every record must still equal the corpus,
which gives 24 cases. The cases are pending when `upstream/petrus/.venv` is
not synced.

## Gaps

- **Process crash injection.** Upstream simulates a crash by abandoning a
  custody instance mid-protocol and reopening the same store. The port does
  the same (`reopen` in `ConnectionSupport`). Neither side kills a real OS
  process between the SQLite COMMIT and the cleanup.
- **Lone-surrogate payloads.** These are refused as invalid. See
  `divergences/custody.md`.
- **Provider SDK–backed key or provider implementations.** Upstream ships
  none in this layer either. Only the protocols and the test fakes exist.
