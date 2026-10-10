# petrus-json: divergences from CPython `json`

Intentional differences from CPython 3.14's `json` module, as used by the
pinned Petrus (`upstream/petrus`). Everything not listed here is meant to be
identical; the test suite pins the observable behavior.

| Behavior | CPython 3.14 | petrus-json | Why |
| --- | --- | --- | --- |
| Nesting depth | `json.loads` and `json.dumps` raise `RecursionError` when the C stack runs low: about 116,000 nested containers for `loads` and 104,000 for `dumps` on a 64-bit macOS build (16 MiB thread stacks); other platforms and stack sizes give other figures. The message names the stack (`Stack overflow (used 16352 kB) while decoding a JSON array from a unicode string`). | A fixed bound, `defaultNestingLimit` = 100,000 nested arrays/objects for `pythonLoads`, `strictLoads` and `defaultDumps`, configurable per call (`maxNestingDepth`, `nestingLimit`). The message is `maximum nesting depth (100000) exceeded while decoding a JSON array from a unicode string`. Like CPython, the decoder counts every container and the encoder counts only non-empty ones. | CPython's figure is not a contract (it depends on the stack). A fixed bound below every measured figure keeps the behavior deterministic and refuses pathological input instead of growing the Haskell stack without bound. Depths Petrus exercises (the upstream simulation tests use 1,200) are accepted. |
| Lone surrogate escapes (`"\ud800"`) | Accepted by `json.loads` (the resulting `str` cannot be UTF-8 encoded). | Refused at parse time. | `Data.Text` holds Unicode scalar values only. Every Petrus surface that admits strict JSON refuses lone surrogates anyway (simulation HTTP re-encodes to UTF-8 and returns 400). |
| Parse error messages | `JSONDecodeError` texts with line/column (`Expecting value: line 1 column 1 (char 0)`). | Byte offsets (`Expecting value at byte 0`). | No Petrus wire surface exposes decoder messages; they are diagnostics. The two `ValueError`s that can surface (`Exceeds the limit (4300 digits) …` and the encoder's `Out of range float values …`) match CPython exactly. |
