# petrus-activity: divergences from `petrus.motus.activity`

Intentional differences from the pinned module. Everything else, including
every refusal message the value doors can produce from a representable
input, is meant to be identical. The live differential
([PARITY.md](PARITY.md)) checks that over 18 836 cases.

1. **`DataclassPayloadConverter` is not a value here.** The reference picks
   a conversion per parameter from its Python type annotation: a dataclass
   annotation decodes a mapping into the dataclass (dropping unknown
   fields), and anything else falls back to JSON. A Haskell
   `PayloadConverter` canonicalizes JSON on both sides, and a typed
   definition converts its own parameters: the `Typed` class of
   `Petrus.Impetus.Binding` for typed handlers, and the model decoders of
   `hamsterdan-readiness` for its gates. *Why:* Haskell has no runtime
   annotations to dispatch on. The types pick the conversion at compile
   time, which is what the annotation lookup emulates.

2. **The `activity` decorator's `TypeError`s are enforced by the types.**
   The reference refuses, at decoration time, a parameter without an
   annotation, a missing return annotation, a positional-only or variadic
   parameter, an annotation that does not resolve, and a coroutine function.
   `defineActivity` takes the declaration, the parameter names and an
   `[(Text, Json)] -> ActivityExecutionContext -> IO Json` implementation,
   so none of those can be written. *Why:* the checks are reflection over
   Python signatures, and a Haskell function's type is checked when it is
   compiled.

3. **No async variants.** `AsyncActivityDefinition`, `async_activity`,
   `AsyncActivity` and `AsyncActivityExecutionContext` are the same
   `ActivityDefinition` and `ActivityExecutionContext`, and both Workers of
   `petrus-motus` run them. The decorator's colour checks ("requires a
   synchronous function; use async_activity", "requires an async coroutine
   function") have nothing to check. *Why:* Haskell has no function colours;
   `IO` serves both Workers (see `packages/petrus-motus/PARITY.md`).

4. **Inputs the types cannot express.** The reference refuses, by exact
   type:
   - `bool` where an `int` or a number belongs (`ExecutionPolicy(attempts=True)`),
     and a float where an `int` belongs (`heartbeat_timeout=1.5`);
   - a non-`str` name, kind or identity;
   - a non-`bool` `retryable` (`TypeError: ActivityFailure retryable must be bool`);
   - heartbeat details with a non-`str` mapping key, a tuple or an
     arbitrary object.

   None of those can be built from `Integer`, `Number`, `Text`, `Bool` and
   `Json`, so the messages that name them cannot occur. The reference also
   copies a value it snapshots ("detach"); a Haskell `Json` is immutable, so
   there is nothing to detach from. *Why:* the Haskell types make those
   values unrepresentable.

5. **Deeply nested details.** Two of the reference's limits come from the
   Python stack:
   - `snapshot_heartbeat_details` normalizes recursively, so details nested
     about 1 000 levels deep raise `RecursionError` (not a `ValueError`; the
     call fails rather than refusing);
   - `json.dumps` in `ActivityFailure` and `JsonPayloadConverter` raises
     `RecursionError` near the C stack limit.

   The Haskell doors accept details up to petrus-json's fixed nesting
   limit, 100 000 levels. Past it they refuse with petrus-json's
   `maximum nesting depth (100000) exceeded …` message
   (`packages/petrus-json/DIVERGENCES.md`). The byte limits still apply,
   and heartbeat details cannot nest past about 32 000 levels in 65 536
   bytes anyway. *Why:* the reference's figure depends on the interpreter's
   stack, so it is not a contract.

6. **Duplicate member names.** The reference's values are `dict`s, so a
   member name occurs once, and its doors return `json.loads(json.dumps(value))`.
   A Haskell `Object` is a member list, and a door that accepts one returns
   it unchanged, duplicates included. *Why:* a value read from JSON has
   already been through petrus-json's `pythonLoads`, which collapses
   duplicates as CPython's `dict` does (or a strict reader that refuses
   them). Only a Haskell caller that builds an `Object` with a repeated name
   by hand can get one through, and re-parsing on every call would cost time
   to cover that case.

7. **Exception classes.** Refusals are `Left` messages, not `ValueError`,
   `TypeError` or `OverflowError`. `activityError` and the Workers raise
   Haskell exceptions that carry the same messages. *Why:* this is the
   repository's convention for value doors (`Either Text`). The messages
   are what reach History and the wires, and they match.

8. **An `ActivityInvocation` is built through its refusals.** The
   reference's `__post_init__` refuses an empty activity name or an empty
   supplied identity whenever an invocation is constructed. Here
   `ActivityInvocation` is opaque: `activityInvocation` (and `invocation`
   for the keyword defaults) is the only way to build one, so no Dispatch,
   Worker or wire ever sees an invocation the reference could not have
   built. Its fields are read as `inv.activity`, `inv.policy` and so on;
   a changed copy is `activityInvocation (invocationFields inv) {...}`.
   Handlers that build one in `prepare` go through
   `Petrus.Impetus.Binding.prepareInvocation`, which records a refusal as
   the `ValueError` the reference's constructor raises there. *Why:* the
   same refusals, at the same point, without a second representation of
   the value; every construction site states how it handles them.
