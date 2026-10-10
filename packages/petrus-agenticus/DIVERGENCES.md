# petrus-agenticus divergences

These choices are deliberate. None of them changes a History byte, a wire
byte or a refusal; the differential corpora pin all three. The error model
(one `AgenticusError` value with an `ErrorClass` hierarchy and byte-exact
messages) is shared with `petrus-agenticus-core`. It is described in that
package's DIVERGENCES.md.

## Agent-as-a-Net (`Petrus.Agenticus.Program.AgentNet`)

1. **Pure handlers and guards.** The reference's `_classify`, `_reject_tool`
   and `_record` handlers and its `_execute` and `_reject` guards are Python
   functions over plain values. Here they are total, pure Haskell functions:
   `Binding -> [Arc] -> Either Text HandlerResult` and
   `Binding -> Either Text Bool`. A `Left` carries the reference's
   `repr(error)` text, so the Engine records the same failure bytes.

2. **The Net is authored once, with the DSL.** `agentNet` is built with
   `Petrus.Impetus.Dsl` and is spelled exactly like the DSL corpus's
   agent-net. The handler and guard symbols are the reference's
   (`_classify`, `model_phase`, `hands` and so on), so the implementation URIs
   and the net-definition bytes match the reference.
   - The two Activity bridges, `model_phase` and `hands`, are bound to their
     `ActivityHandler`s by URI after the build.
   - `agentNetOptions` installs the handlers, the guards and the CEL compiler
     in one step. The reference passes `handlers=` and `guards=` separately,
     and its CEL compiler is ambient.

3. **`ToolWork` keeps the spelling of its index.** The reference keeps
   whatever JSON value arrived as `index` (Python's `bool` is an `int`, so
   `true` passes as 1 and is written back as `true`). The Haskell record keeps
   the validated `Integer` for logic, plus a hidden copy of the original JSON
   spelling for `to_data`. The resulting bytes are identical.

4. **Python's dynamic type errors are reproduced at the JSON boundary.** These
   are refusals such as `TypeError: '<=' not supported between instances of
   'int' and 'NoneType'`, `slice indices must be integers...` and
   `cannot use 'list' as a set element`. The Haskell constructors cannot
   receive such values; the `*FromData` decoders check for them in the
   reference's order and raise the same class and message. The corpus pins
   each case.

## Attachment binding (`Petrus.Agenticus.Attachment.Binding`)

5. **The protocol is a record.** `AttachmentBinding` is the reference's
   `Protocol`. It is a record of IO actions (`cancel`, `exportArchive`,
   `settle`) plus an optional Motus view. A provider-managed binding is a
   value of that record, not a subclass.

6. **Re-entrancy is tracked per thread.** The reference serializes operations
   with an `RLock` and counts active operations. Here, `withBindingOperation`
   keeps a per-`ThreadId` depth map in STM, so a nested operation on the
   same thread is admitted even after admission closes, as the `RLock`
   allows. `bindingQuiesce` then waits with an STM timeout for active
   operations to reach zero, instead of polling.

7. **Settlement evidence never prints its detail.** `BindingSettlement`'s
   `Show` instance omits `detail`, which can hold provider diagnostics. The
   reference achieves the same with `field(repr=False)`.

8. **Test monkeypatching becomes record overrides.** `EnvironmentProvider` is
   a record of functions. The upstream tests patch `destroy` and `attach`;
   the Haskell tests override `providerDestroy` and `providerAttach` on a
   copy of the real local provider.

## Packaging

9. **Boundary tests check cabal dependency graphs.** Haskell imports have no
   side effects, so `test_root_import_has_no_facade_or_optional_provider_side_effects`
   cannot observe import-time behaviour. `BoundariesSpec` asserts the
   equivalent structural fact instead: `petrus-agenticus-core` depends on no
   kernel package, and no agenticus package depends on a provider SDK
   binding.
