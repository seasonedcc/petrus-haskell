# petrus-cel: parity with the Python reference

`Petrus.Cel` evaluates the Common Expression Language exactly as cel-python
(`celpy` 0.5.0) does. `Petrus.Cel.Binding` and `Petrus.Cel.Impetus` port
`upstream/petrus/src/petrus/impetus/binding/cel.py` (at 3f85fc2): Petrus's
filter, guard and completion environments, `free_variables`, and the
`celCompilers` the Impetus kernel takes. Divergences are in
[DIVERGENCES.md](DIVERGENCES.md).

To run the tests:

    cabal test petrus-cel

This prints 164 examples and 0 failures:

| group | examples | what it checks |
| --- | ---: | --- |
| differential corpus (`test/Corpus.hs`) | 96 | every case of the three corpora below |
| `binding/test_cel.py` (`test/Impetus.hs`) | 20 | the 19 upstream tests, one example each, and `MACROS` read back from the pinned source |
| PARITY.md CEL tests on Instances (`test/Impetus.hs`) | 5 | the CEL tests of the Instance suite, on real Instances |
| end-to-end Instances (`test/Impetus.hs`) | 6 | `cel-instance.json`, five case groups and a coverage check |
| kernel CEL seam on real CEL (`test/KernelSeam.hs`) | 26 | the kernel tests `petrus-impetus` ports on a CEL stub, rerun on `celCompilers` |
| live round trip (`test/Live.hs`) | 1 | the reference rereads what Haskell writes |
| properties (`test/Properties.hs`) | 10 | QuickCheck properties and the lone-surrogate encoding errors |

## The differential corpora

`test/gen-cel-corpus.py` and `test/gen-cel-instance.py` record cel-python's
and the reference's answers. They are deterministic, and
`scripts/check-corpora` reruns them against the pinned reference.

- **`test/corpus/cel-corpus.json`**: 1996 expressions in 39 groups (literals,
  lexing, precedence, parse errors, arithmetic, comparison, logic, membership,
  maps and lists, strings, regex, conversions, macros, timestamps and
  durations, environments, the cel-python quirks, and lone-surrogate string
  literals). Each case records the lark parse tree or the parse error with
  its position, and the evaluation outcome: the value's `repr` and
  truthiness, the CEL error text, or the Python exception's class and
  message. Every case is replayed; none is excluded. The file also holds 52
  `free_variables` answers and 55 Petrus adapter cases: filters, guards and
  completions compiled by `petrus.impetus.binding.cel` and evaluated on
  token inputs.
- **`test/corpus/cel-operators.json`**: 17 850 cases: every binary and unary
  operator, postfix form and conversion function over 35 representative
  operands of every runtime class cel-python can produce, including the
  plain Python values that leak out of celtypes arithmetic.
- **`test/corpus/cel-instance.json`**: 5 Instance cases (routing, errors,
  correlation, inhibit-and-black, completion-errors). Each runs a net with
  inline CEL guards, arc filters and completion conditions on the reference
  Instance until quiescent. The Haskell Instance with `celCompilers` must
  produce the same candidate bindings and enabledness warnings before every
  step, the same firing outcomes, and at the end the same marking, status,
  completion warnings and encoded schema-5 History.

## Per upstream test

`tests/petrus/impetus/binding/test_cel.py`: all 19 tests are ported in
`test/Impetus.hs` (`bindingSpec`), with the same names and assertions.

| upstream class | tests | status |
| --- | ---: | --- |
| `TestCompileFilter` | 3 | ported |
| `TestCompileCompletion` | 5 | ported |
| `TestCompileGuard` | 8 | ported |
| `TestFreeVariables` | 3 | ported |

The Instance suite's own CEL tests, which need real CEL, are ported in
`test/Impetus.hs` (`paritySpec`). They are listed as such in
[petrus-impetus's ledger](../petrus-impetus/PARITY.md):

- `test_completion.py::TestCelEnvironment` (3 tests);
- `test_completion.py::TestCompletionValidation.test_macro_bound_variables_are_not_place_references`;
- `test_cel_guards.py::TestCelGuardValidation.test_macro_bound_variables_are_not_place_references`.

## The kernel's CEL-stub ports, rerun on real CEL

`petrus-impetus` cannot depend on this package. It ports 26 upstream kernel
tests that use CEL against a stub compiler that understands only the
expressions those tests write. `test/KernelSeam.hs` reruns each one, under
its upstream name, with `Petrus.Cel.Impetus.celCompilers`, so the stub cannot
hide a difference between the stub and cel-python:

| upstream file | classes | tests |
| --- | --- | ---: |
| `tests/petrus/impetus/instance/test_completion.py` | `TestStatusResolution` (5), `TestCompletionValidation` (2) | 7 |
| `tests/petrus/impetus/instance/test_cel_guards.py` | `TestCelGuardRouting` (2), `TestCelGuardCorrelation` (1), `TestMixedGuards` (3), `TestCelGuardValidation` (5), `TestCelGuardEvaluationErrors` (2) | 13 |
| `tests/petrus/impetus/instance/test_registrations.py` | `TestAwaitingStatus` (3) | 3 |
| `tests/petrus/impetus/petrinet/test_arc_filters.py` | `TestCelFilterSelection` (3) | 3 |

## Beyond upstream

- **`MACROS`** (`binding/cel.py`) is named API: `macros` in `Petrus.Cel`,
  re-exported by `Petrus.Cel.Binding`. `freeVariables` subtracts the
  variables of exactly these macros. An example reads the set back from the
  pinned reference's source.
- **Live round trip** (`test/Live.hs`, selected by `scripts/interop`). Every
  `cel-instance.json` net's definition and document, and the History Haskell
  writes while running it with `celCompilers`, go to the pinned reference's
  own `parse_net_definition`, `parse_net_document` and `decode_record`. The reference must accept them
  and serialize them back byte for byte. Without the reference the example
  fails.
- **Properties** (QuickCheck):
  - `compile` and evaluation are total on token soup;
  - free variables are identifier spellings within the source;
  - `compile` is deterministic;
  - int arithmetic, division, remainder and comparison agree with
    `Integer`, and overflow is an error;
  - string size, concatenation and prefixes agree with `Text`;
  - list membership agrees with `elem`.
- **Lone-surrogate strings.** `bytes(s)` and `matches` on a string that
  holds a lone surrogate raise CPython's `UnicodeEncodeError`, with every
  argument as celpy renders it. The corpus records only an error's first
  argument.

## Benchmarks

[bench/RESULTS.md](bench/RESULTS.md) times seven typical filters, guards and
completions through the kernel seam against cel-python: parse, evaluate, and
compile+evaluate.
