# hamsterdan-testing divergences

These are the intentional differences from `upstream/hamsterdan`'s
`testing/readiness.py`. None of them changes a wire format. The oracle
corpus checks the following byte for byte against the pinned Python (see
[PARITY.md](PARITY.md)):

- every admission decision;
- every strict dump;
- every expectation;
- every liveness verdict.

## API

1. **Validation happens at the codec, not at construction.**
   - The reference's frozen pydantic dataclasses validate in their
     constructors. That covers both strict types and `__post_init__`.
   - Haskell records do not validate. Every rule lives in the record's
     codec, so `load`, `loadJson` and `checked` refuse exactly what the
     reference's constructor refuses.
   - `checked` re-validates a value built in Haskell. It is the
     reference's constructor.
   - `evaluate` and `evaluateLiveness` are total over any value, including
     one the reference could not build.
2. **Refusal text names the first failure.**
   - pydantic's `ValidationError` lists every failing member.
   - The codec reports the first one as `path: reason`.
   - A construction rule's message is the reference's exact text, such as
     `$: authority identities must be positive`. The corpus checks it
     whenever that rule is the reference's only refusal.
3. **`Literal` vocabularies are enumerations.** For example, `Lifecycle`,
   `EffectKind` and `ReadinessDisposition` are sum types with one
   constructor per spelling. Their wire spelling is `spell`. An invalid
   spelling cannot be constructed, and decoding refuses exactly what
   pydantic refuses.
4. **The model is two functions.**
   - The stateless class `ReadinessModel().evaluate` is `evaluate`.
   - `evaluate_liveness(…, budget_exhausted=b)` is
     `evaluateLiveness expectation environment b`.
   - The property `FairEnvironment.declared` is the function `declared`.
5. **Defaults are named values.**
   - Python's keyword defaults become named values: `readinessFacts subject
     authority`, `ciFacts`, `reviewFacts`, `humanFacts`, `mutationFacts`,
     `effectObligation`, `timerObligation`.
   - A test changes fields with record update.
6. **`StrictValue.load` takes bytes.** `load` takes UTF-8 bytes, and
   `loadJson` takes an already parsed value.
