# petrus-agenticus-core divergences

These choices are deliberate. None of them changes a wire byte, a stored
byte or a refusal message for any input the reference can produce; the
differential corpora pin all three. Each layer has its own fragment under
`divergences/`.

| Layer | Fragment | Main themes |
| --- | --- | --- |
| Shared error model, catalog and profiles | [divergences/catalog.md](divergences/catalog.md) | One `AgenticusError` value with an `ErrorClass` hierarchy that mirrors the Python exception classes, with byte-exact messages. Values are smart-constructed records. There is no import-time registration. |
| Effect | [divergences/effect.md](divergences/effect.md) | Payloads are admitted as a float-free `PayloadValue`. Canonical digests are streamed straight into SHA-256. The proposal digest is cached. Adapters and fence sources are records of IO actions. |
| Hands | [divergences/hands.md](divergences/hands.md) | Typed tool methods. A re-entrant `MVar` barrier stands in for the shared `RLock`. The call ledger is an `IORef` updated by compare-and-swap, with per-claim `MVar` signals. `isinstance` refusals become types. |
| Thread, program descriptors, runtime values | [divergences/thread.md](divergences/thread.md) | Identities are distinct newtypes. Thread transitions revalidate only the Episode they change, which keeps them linear. Error attributes become accessors. Probe issues that share a code are handled differently. |
| Connection custody | [divergences/custody.md](divergences/custody.md) | Secrets are held in `ScrubbedBytes`. The logger is a callback. SQLite runs through the shared `petrus-sqlite` connection behind `Petrus.Agenticus.Internal.Sqlite`, which maps driver errors to the Python `sqlite3` classes. Each write is validated once and decoded snapshots are cached. Payloads the reference never writes are handled differently. |

## Shared conventions

- **Errors.** Every refusal is an `AgenticusError {errorClass, errorMessage}`.
  `isSubclassOf` reproduces the Python class hierarchy, so a test that
  expects a `ValueError` accepts its subclasses, as `pytest.raises` does.
- **Protocols become records.** Every upstream `Protocol` is a record of IO
  actions: key operations, custody sources, adapters and codecs. Test
  monkeypatching becomes a record override on a copy.
- **No field selectors.** Records are read with `OverloadedRecordDot`.
  Constructors that enforce invariants are exported as `mk*` functions that
  return `Either AgenticusError`.
