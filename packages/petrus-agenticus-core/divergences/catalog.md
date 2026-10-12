# Catalog, profiles and shared-model divergences

These choices are deliberate. None of them changes a wire byte or a refusal.
The differential corpus pins both.

## The error model (shared by every agenticus module)

1. **One exception type.** The reference raises one Python class per
   failure, for example `DuplicateRegistrationError(CatalogRegistrationError(ValueError))`.
   This port raises a single `AgenticusError {errorClass, errorMessage}`.

   - `ErrorClass` names every upstream class.
   - `parentClass` and `isSubclassOf` encode the inheritance chain, so
     `isInstanceOf e CustodyError` accepts every subclass, just as
     `except CustodyError` does.
   - Messages are byte-identical to `str(error)`.

   Values are built by smart constructors returning
   `Either AgenticusError`, and IO operations throw.

2. **Python type confusion becomes types.** Many reference checks exist
   because Python is dynamically typed, for example
   `isinstance(kind, DescriptorKind)` or `type(version) is int`.

   - A Haskell value cannot violate these checks. `DescriptorKind` is a sum
     type and versions are `Integer`.
   - At the JSON boundary (`*FromData`) the same checks still run, in the
     reference's order and with its messages. For example, a JSON `true`
     version or `1.0` is refused exactly as `type(v) is int` refuses it.

## Values

3. **Wire integers are `Integer`.** They are unbounded, like Python `int`.
   Python's 4300-digit `int`-parsing limit is not reproduced.

4. **Records hide their constructors.** Fields can be read with
   `OverloadedRecordDot`, but the data constructor is not exported. Every
   value has passed its constructor's validation, which is what the
   reference's frozen dataclasses with `__post_init__` provide.

   `RuntimeTerritoryProfile` goes further. Its archetype and descriptor
   live in a `Qualification` sum (`BindingCell archetype descriptor`,
   `UnqualifiedCell`, `UnsupportedCell`), so upstream's two descriptor
   refusals ("a binding runtime profile needs an archetype and descriptor",
   "an unqualified or unsupported cell must not expose a runtime
   descriptor") describe values that cannot be built. `expectation`,
   `archetype` and `descriptor` still read with record dot syntax, derived
   from the qualification. `mkRuntimeTerritoryProfile` refuses an empty
   reason with the reference's `ValueError` message, the one refusal left.

5. **Capability sets are `Set Text`.** The reference uses `frozenset` and
   sorts it on output. `Set` iterates in code-point order, which matches
   Python's `sorted()` for `str`.

## Catalog

6. **Pure state and a thin mutable shell.**
   - `CatalogState` is a pure value. `registerState`, `enableState` and
     `resolveState` return the new state, or the refusal with the state
     unchanged.
   - `Catalog` wraps that state in an `IORef` for the reference's
     imperative API.
   - The reference's catalog is not thread-safe beyond the GIL. This one
     updates atomically (`atomicModifyIORef'`).

## Packaging

7. **`runtime/profiles.py` lives in `petrus-agenticus-core`.** docs/runtime.md
   §14 places it in `petrus-agenticus-runtime`. It is pure catalog data,
   though, and both the Catalog tests (`test_resolution.py` resolves every
   profile) and `agent_net_runner` need it. Putting it in core keeps the
   runtime package free of a back-dependency for tests. The module name
   still says `Runtime.Profiles`.

## Benchmarks

8. **`catalog/snapshot-to-json`** used to be slower than Python (22 µs
   against 15 µs), because petrus-json's encoder built a `Builder`, then a
   lazy `ByteString`, then a strict one, after a non-finite pre-scan. The
   encoder now writes in one pass, and the row is 2.1 times faster than
   Python (7.1 µs against 14.6 µs). The other three catalog paths are 1.8
   to 6.1 times faster. See `bench/results-catalog.md`.
