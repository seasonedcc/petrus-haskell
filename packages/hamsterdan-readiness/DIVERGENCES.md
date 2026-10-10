# hamsterdan-readiness divergences

These are the intentional differences from `upstream/hamsterdan`. None of
them changes a wire format. The following are all checked byte for byte
against the pinned Python (see [PARITY.md](PARITY.md)):

- the serialized net definition and its fingerprint;
- every token a fold or gate produces, `$variant` included;
- every activity invocation;
- every board;
- every refusal text the engine records.

## API

1. **Refusals are values, not exceptions.**
   - `buildNetV5` returns `Either DslError BuiltNet`.
   - `seedMarking` and `seedMarkingWith` return `Either Text Marking`.
   - Folds, gate handlers and `renderBoard` return `Either Text`.
   - The refusal text is the text the reference's engine records, its
     `firing_failure_text`, such as `ValueError('…')`. The corpora compare it
     exactly.
2. **Gate definitions state their annotations.**
   - The reference reads a gate's request type and result union off the
     Activity function's annotations.
   - A Haskell `ActivityDefinition` has no annotations. So a `GateDefinition`
     carries the parameter's request `Annotation` (a `Contract` type) and the
     union's member colors.
   - `wireGates` takes these definitions where `wire_gates` takes
     `ActivityDefinition`s.
3. **The `$variant` converter is split in two.**
   - A Haskell `PayloadConverter` is JSON to JSON. It has no type to
     dispatch on.
   - `variantPayloadConverter` is therefore the JSON-faithful converter.
   - The union stamping of `VariantPayloadConverter.encode` is
     `encodeVariant`. A gate implementation applies it to its result. It
     refuses with the reference's text and writes `$variant` first, as the
     reference does.
   - The decoding side, `decodeDataclass`, and the routing handler's
     `project` behave as upstream does.
4. **Typed payload conversion.**
   - `PydanticPayloadConverter` picks the model from the parameter
     annotation. Here, `decodeModel @T` and `encodeModel` are the typed
     directions.
   - `pydanticPayloadConverter (modelOf …)` is the type-erased converter for
     one known model.
   - The reference refuses `type(value) is not ChangeResult` at encode time.
     Here a value of the wrong type cannot be passed to `encodeModel` at all,
     because the type checker rejects it.
   - The type-erased converter sees only JSON. It therefore accepts any
     payload that is a valid instance of its model, such as a `RepairResult`
     dump that also spells a valid `ChangeResult`. `PayloadsSpec`
     "(statically)" pins this.
5. **Python semantics are explicit.**
   - The folds that read untyped `dict[str, Any]` batons use the helpers in
     `NetV5.Py`, such as subscript, truthiness and comparison. These
     reproduce Python's result and its exception text.
   - Python gets the same behavior implicitly from its operators.

## Board

6. **Literal types that a dashboard never writes are unrecognized.**
   - `ast.literal_eval` accepts bytes, complex numbers, sets and `\N{…}`
     escapes. `Hamsterdan.PyLiteral` reports these as `Unsupported` (see
     hamsterdan-contracts' DIVERGENCES).
   - An entry whose body holds one renders as "unrecognized" here.
   - The reference would parse it, then render or refuse it.
   - The dashboard writes only `repr` of JSON-shaped values, so no entry the
     net produces is affected. The board corpus includes hostile entries of
     every other kind.
   - An unhashable dict key or set element still refuses with CPython
     3.14's exact `TypeError` text.

## Test harness

7. **The harness follows `harness.py` with Haskell names.**
   - Examples: `spawnHeld`, `pumpHolding`, `releaseOne`, `completeOne`.
   - Its delivery-identity counter (`door-n`) is per spawned Engine. The
     reference uses one module-global counter.
   - Identities only need to be unique within an Engine, and no assertion
     reads them.
8. **Inline-recovery convergence uses a ledger double.** The five upstream
   cases use the `hamsterdan.host.v5` gates. Here a ledger test double wraps
   the harness gate (see [PARITY.md](PARITY.md)).
