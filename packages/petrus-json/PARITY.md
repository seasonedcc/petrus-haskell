# petrus-json: parity with CPython `json` as Petrus uses it

petrus-json has no upstream module of its own. Its reference is CPython
3.14.6's `json` (pinned by `scripts/upstream-python`), restricted to what
`upstream/petrus/src` and `upstream/hamsterdan/src` actually call. Parity
means:

1. **`json.dumps`**: for every keyword combination upstream passes, the same
   bytes for every value petrus-json can represent, and the same refusal
   (exception text) for every value CPython refuses.
2. **`json.loads`**: for every hook combination upstream passes, the same
   value (type-exact: `1` is not `1.0`, `-0.0` is not `0.0`, NaN equals NaN
   bit for bit) for every document CPython accepts, and a refusal for every
   document it refuses, with the same text where the text can reach a user
   (the integer digit limit).
3. The edges: float `repr`, integers past CPython's 4 300-digit
   string-conversion limit, lone surrogates, BOMs, nesting depth.

Differences that remain are in [DIVERGENCES.md](DIVERGENCES.md), each with
its reason.

## The call sites covered

An AST survey of `upstream/petrus/src` and `upstream/hamsterdan/src` finds
these `json.dumps` keyword sets (count, then one call site). Each is a row of
`dumpsConfigurations` in
[`CPythonDifferentialSpec`](test/Petrus/Json/CPythonDifferentialSpec.hs):

| `json.dumps` keywords | uses | example | petrus-json |
| --- | ---: | --- | --- |
| `separators=(",", ":"), sort_keys=True` | 28 | `gondolin.py` | `tight {sortKeys = True}` |
| `allow_nan=False, separators=(",", ":"), sort_keys=True` | 12 | `dst.py` | `tight {sortKeys, allowNan = False}` |
| `allow_nan=False` | 10 | `observation.py`, the JSONL History writer | `defaultDumps {allowNan = False}` |
| (none) | 10 | `pi_application.py` | `defaultDumps` |
| `allow_nan=False, ensure_ascii=False, separators=(",", ":"), sort_keys=True` | 9 | `simulation.py` | `compact {sortKeys = True}` (`canonicalText`) |
| `separators=(",", ":")` | 8 | `_retention.py` | `tight` |
| `sort_keys=True` | 8 | `gondolin.py` | `defaultDumps {sortKeys = True}` |
| `allow_nan=False, ensure_ascii=False, separators=(",", ":")` | 7 | `fabric/model.py` | `compact` |
| `indent=2, sort_keys=True` | 6 | hamsterdan `export.py` | `defaultDumps {indent = Just 2, sortKeys = True}` |
| `allow_nan=False, separators=(",", ":")` | 5 | `dst.py` | `tight {allowNan = False}` |
| `ensure_ascii=True, separators=(",", ":"), sort_keys=True` | 4 | `_codex_gondolin_service.py` | `tight {sortKeys = True, ensureAscii = True}` |
| `allow_nan=False, ensure_ascii=False` | 3 | `simulation.py` | `defaultDumps {allowNan = False, ensureAscii = False}` |
| `ensure_ascii=False, separators=(",", ":"), sort_keys=True` | 3 | `claude.py` | `tight {sortKeys = True, ensureAscii = False}` |
| `allow_nan=False, ensure_ascii=False, indent=2` | 2 | `net_document.py` | `indented` |
| `ensure_ascii=False, separators=(",", ":")` | 1 | `local.py` | `tight {ensureAscii = False}` |
| `indent=2` | 1 | `export.py` | `defaultDumps {indent = Just 2}` |
| `default=<hook>` | 1 | `telemetry.py` | not applicable: a Haskell caller converts to `Json` first ([DIVERGENCES.md](DIVERGENCES.md)) |

(`tight` is `defaultDumps {itemSeparator = Just ",", keySeparator = ":"}`.)

The `json.loads` calls, by the hooks they pass, are the four admission
profiles of `loadsProfiles`:

| `json.loads` hooks | uses | petrus-json |
| --- | ---: | --- |
| none | 78 | `surrogateRefusingLoads` |
| `object_pairs_hook` refusing duplicate members, `parse_constant` refusing | 7 (`simulation_http.py`, `net_document.py`, `pi`, `dst`) | `surrogateRefusingLoads {duplicateMembers = RejectDuplicates, allowNonFiniteConstants = False}` |
| the same, then a strict UTF-8 `json.dumps(..., allow_nan=False)` round trip (`simulation_http._strict_loads`) | 1 | `strictLoads` |
| `object_pairs_hook`, `parse_int` (safe-integer range), `parse_float` and `parse_constant` refusing (`net_definition.py` v3) | 1 | `strictLoads {integerTokensOnly = True, integerRange = Just (safeIntegerMin, safeIntegerMax)}` |

## Tests

`cabal test petrus-json` runs the suite with no failure and no pending example:

- **Differential against CPython**
  ([`CPythonDifferentialSpec`](test/Petrus/Json/CPythonDifferentialSpec.hs),
  oracle [`cpython_json_oracle.py`](test/cpython_json_oracle.py)). It runs the
  pinned interpreter live, and fails rather than skips when the interpreter
  cannot be provisioned. Every run generates the corpora from fixed seeds:
  - `json.dumps`: 2 003 values × 16 configurations = **32 048 answers**,
    byte for byte or refusal text for refusal text. The values have every
    code point class (ASCII controls, `\u007f`, Latin-1, BMP, astral, the
    characters around the surrogate block, and lone surrogates as WTF-8
    `Text`, which the oracle encodes with `surrogatepass`), integers up to 10^4400 (both
    sides of the 4 300-digit limit), doubles including NaN, ±inf, -0.0,
    subnormals and the extremes, and three values nested 1 200 levels deep.
  - `json.loads`: 16 402 documents × 4 profiles = **65 608 answers**. The
    documents are about 100 hand-picked edges (BOM, empty input, lone and
    paired surrogate escapes, `NaN`/`Infinity`/`-Infinity`, numbers at the
    digit limit, duplicate members, trailing garbage, control characters,
    invalid UTF-8), plus generated documents and documents a generator
    mutates (byte flips, truncations, insertions), number spellings,
    token soup, escaped strings, keyed objects and whitespace variants. Every
    profile both admits and refuses at least 2 000 of them. An accepted
    document must give the type-exact value; a refused one must be refused.
    In the plain profile, the digit-limit refusal must have CPython's text.
    Under the default `RefuseLoneSurrogates`, the one tolerated difference
    is a lone surrogate CPython admits, which must be refused with the
    surrogate text ([DIVERGENCES.md](DIVERGENCES.md)); with
    `KeepLoneSurrogates` the plain profile must answer exactly as CPython
    does, value for value, lone surrogates included (more than 200 such
    admissions per run).
  - The tagged transport between the two sides is itself checked lossless.
- **`json.loads` of a `str`, read in place**
  ([`InPlaceSpec`](test/Petrus/Json/InPlaceSpec.hs)): `parseInPlace`, the
  fast path of `loadsText`, accepts its subset and declines everything
  else, including raw lone surrogates. On 3 000 generated documents and
  the hand-made edges, each document it accepts gives the byte parser's
  value and CPython's `json.loads` value, the latter compared through
  `json.dumps`.
- **Float `repr`** ([`FloatReprSpec`](test/Petrus/Json/FloatReprSpec.hs)):
  `pythonFloatRepr` against CPython's `repr` on more than 100 000 doubles
  (random bit patterns, powers of ten and two, the exponent-notation
  boundaries, the extremes).
- **`repr(str)` and `str.isprintable`**
  ([`PythonTextSpec`](test/Petrus/Json/PythonTextSpec.hs)): the printability
  vector for every code point ([`python-printable.txt`](test/python-printable.txt)).
- **The CPython-compatibility layer** (`Petrus.Json.Python`,
  [`PythonCompatSpec`](test/Petrus/Json/PythonCompatSpec.hs)): one live run
  of the pinned interpreter ([`cpython_compat_oracle.py`](test/cpython_compat_oracle.py))
  answers every case and every answer must match exactly: `str.isprintable`,
  `str.isspace`, the `str.splitlines` boundaries, `unicodedata.decimal`,
  `str.isdigit` and the full `str.lower`, `str.upper` and `str.casefold`
  mappings on every code point; `repr`, `strip`, `lstrip`, `rstrip`,
  `split()`, `splitlines()`, `isprintable()`, `lower()` (the final-sigma
  rule in every context), `upper()`, `casefold()` and `os.fsencode` (the
  `surrogateescape` error and its range) of 2 500 generated strings (dense
  in whitespace, line boundaries, U+00A0, Unicode 16.0 additions such as
  U+105C0, and lone surrogates); `bytes.decode("utf-8", "surrogateescape")`
  (`fsDecode`, `os.fsdecode`); `repr(bytes)`; `repr(float)`
  with the non-finite values; `repr`, `str` and type name of `json.loads`
  values; the exact text of `json.loads` refusals (`JSONDecodeError` with
  line, column and character, and the digit limit), plain and with a
  duplicate-refusing `object_pairs_hook` and refusing `parse_constant` (hook
  order); strict UTF-8 `UnicodeDecodeError` texts and strict
  `str.encode("utf-8")`'s `UnicodeEncodeError` texts; `bytes.decode("utf-8", "replace")`;
  `repr()` and `str()` of exceptions (`PythonException`) built from 1 500
  generated argument lists, `KeyError`'s and the codec errors' own `__str__`
  included, out-of-range positions too; `json.detect_encoding`
  and the `surrogatepass` decoding `json.loads(bytes)` applies, in every
  encoding, intact and damaged; `json.loads(bytes)` whole (`loadsBytes`:
  the value's `repr`, or the exception's class and `str()`, and its `repr()`
  where CPython's `args` agree with its attributes) over those bytes and the
  refusal documents; and `uuid.uuid4()`'s spelling.
- **Retired copies.** Packages that carried their own `repr(str)` now call
  this layer, and the copies that had drifted are fixed, each with a test in
  its package: petrus-motus decided printability with GHC's `isPrint`, which
  admits the space separators (U+00A0 printed raw instead of `'\xa0'`;
  `test/Main.hs`, "an unknown activity's name is spelled by CPython's
  repr"); petrus-agenticus-core and petrus-dst used GHC's Unicode 15.1
  general categories, escaping characters Unicode 16.0 assigned (U+105C0
  became `'\U000105c0'`; `ConnectionSpec` "spells connection ids with
  CPython 3.14's repr", `Spec.Codec` "spells refused versions with CPython
  3.14's repr"); petrus-execution's `repr` and `int()` digits had the same
  Unicode 15.1 gap. petrus-cel's CPython tables are this package's
  (`gen/gen-unicode-tables.py` keeps only RE2's), and
  `bytes.decode("utf-8", "replace")` (petrus-http-core, petrus-agenticus) is
  `decodeUtf8Replace`. petrus-impetus's Python exception value and its
  text are this package's `PythonException`; petrus-cel's
  `UnicodeEncodeError` and `UnicodeDecodeError` are `utf8EncodeFailure` and
  `utf8DecodeFailure`; the json.loads diagnosers of petrus-motus-zeromq,
  petrus-dst and petrus-engine-file are `Petrus.Json.Python.Scanner`, and
  engine-file's Jiter port is a pure parser.
- **Unit tests** ([`test/Main.hs`](test/Main.hs)): `dumps` spellings,
  `parseJson` behaviours, lone surrogates kept as WTF-8 (pairing, keys,
  ordering, byte-for-byte re-encoding, `dumpsText`, `repr`, `fromWtf8`), the 4 300-digit limit in both directions with
  CPython's exact messages, the nesting guard, `encodeErrorMessage`, type-exact
  equality, value equality (`Eq Json`: objects compare as their last-wins
  dicts, so a repeated key cannot make it asymmetric, with reflexivity,
  symmetry and transitivity checked as properties over finite values dense in
  repeated keys, reordered members and `1` / `1.0` / `true`), and a property check of the parser against the pre-optimization
  reader ([`ReferenceParse`](test/Petrus/Json/ReferenceParse.hs)).

## Interop

The wire form is JSON text itself, and the differential is the interop
check: CPython writes what petrus-json reads (`loads`), and petrus-json
writes what CPython must write byte for byte (`dumps`). `scripts/interop`
runs it under the `petrus-json` group.

## Performance

[bench/RESULTS.md](bench/RESULTS.md): eight rows against CPython's
C-accelerated `json` on History records, a Net document and Thread documents.
petrus-json is faster on every row, in every repetition.
