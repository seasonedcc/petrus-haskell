# petrus-engine-file: parity with petrus-engine

`Petrus.EngineFile` ports `fileVersion: "2"` net loading from
`upstream/petrus-engine` (`fc1dd50`): `schema.py` (`FlatNetFile`, `FlatNet`,
`FlatSchema`), `loader.py`, `types.py` (`NetPath`), `json_formatter.py`, and
`cli/format_json.py`. Files the viewer saves (`upstream/petrus-viewer`
`ccb7808`) are part of the corpus. Parity is checked in five ways.

## 1. The differential corpus

`differential/corpus.py` builds 911 cases. It runs each one through the
pinned petrus-engine (`differential/reference.py`) and records the results
in `differential/corpus.json`. A case is a directory of files plus a list of
operations:

| Operation | Reference | Haskell |
| --- | --- | --- |
| `file` | `FlatNetFile.from_filename(p).to_json(indent, max_inline)` | `fromFilename`, `toJsonBytes` |
| `format` | `reformat_content(Path(p).read_text(), ...)` | `readText`, `reformatContent` |
| `load` | `FlatNet.from_filename(p)` and `.to_schema()` | `loadFile`, `toSchema` |
| `dict` | `FlatNet.from_dict(json.loads(...), deps)` and `.to_schema()` | `loads`, `loadDict`, `toSchema` |

Each result is either the full outcome or the refusal, given as exception
class plus `str(exception)`. The outcomes are:

- `file` and `format`: the written bytes;
- `load` and `dict`: every place, transition, arc, view state and ref origin
  of the `FlatNet`, and every key of the `FlatSchema`.

`CorpusSpec` requires the Haskell result of every operation to match. Over
4618 operations, that means:

- 2973 outcomes, re-serialized byte for byte;
- 1645 refusals, with the same class and the same text.

The cases come from four places:

| Group | Cases | What |
| --- | ---: | --- |
| `upstream/` | 29 | Every net the upstream loader, file-ref, resolution, formatter and timed-transition tests build, written as their `persist_net` fixture writes them. |
| `viewer/` | 159 | The viewer's `examples/sample-net.json`, a file with the viewer-only `viewState.annotations`, and 157 corpus nets opened and saved again by the viewer's own TypeScript (`differential/viewer_resave.mjs`, run on node). |
| `edge/` | 323 | Every field, default and coercion, and every pydantic error kind and its text. Also JSON syntax (jiter for files, `json.loads` for `format` and dicts), invalid UTF-8, BOMs and newlines, duplicate keys, NaN and infinities, big integers, durations, layout thresholds, arc sorting with non-text segments, multi-file refs (cycles, duplicates, missing files, directories, relative paths) and `from_dict` deps. |
| `fuzz/` | 400 | Seeded random nets (seed 20261010), some mutated: wrong types, missing fields, corrupted bytes, multi-file refs. |

The viewer saves `examples/sample-net.json` back to the same bytes, and the
engine writes it unchanged. Every viewer re-save loads here exactly as it
loads in petrus-engine.

To regenerate the corpus (deterministic; needs node 22.18 or later for the
viewer re-saves):

    "$(scripts/upstream-python petrus-engine)" packages/petrus-engine-file/differential/corpus.py

## 2. Live differential

`LiveSpec` runs these checks against the pinned petrus-engine, which
`scripts/upstream-python petrus-engine` provisions on first use; when it
cannot, the examples fail rather than go pending:

- **The corpus is current.** `reference.py` reproduces every recorded result.
- **Fresh fuzz cases agree.** Three seeds (1, 2, 3) of 300 cases each are
  generated, run through the reference, and must agree. Other seeds can be set
  with `PETRUS_ENGINE_FILE_FUZZ_SEEDS=4,5,6`.
- **Extra corpora agree.** Any corpora named in `PETRUS_ENGINE_FILE_CORPORA`
  (comma-separated) must also agree.
- **The JSON Schema is current.** `petrus-cli gen-json-schema` at the pin
  writes `net_file_schema.json` byte for byte as committed upstream (the
  schema section 4 checks against).

A local sweep of seeds 10 to 39, 500 cases each (15 000 cases), found no
disagreement.

## 3. The format CLI

`CliSpec` runs 40 scenarios through both `petrus-format-json` and
`python -m petrus.cli.format_json`. Each scenario fixes the arguments, stdin
and files; both sides must produce the same exit status, stdout, files
afterwards and error line. The scenarios cover:

- in-place and stream modes;
- `--fail-on-change`;
- `--infile` and `--outfile` (truncated at parse time);
- CRLF handling (`--infile` translates newlines, stdin does not);
- invalid JSON, invalid models, unreadable files, invalid UTF-8;
- delay overflow and serialization errors;
- argparse's usage errors: abbreviations, ambiguity, bad integers, missing
  values, `--`;
- `RecursionError` at the CLI's nesting limit (990 levels formatted, 991
  refused) for lists, objects, and place and arc metadata.

## 4. The JSON Schema

petrus-engine exports the file format as a JSON Schema,
`src/petrus/net_file_schema.json`, generated from `FlatNetFile` by
`petrus-cli gen-json-schema`. `SchemaSpec` reads it from the pinned
submodule and checks this package against it:

- it defines exactly the models this package reads;
- each model's properties are the members `toJsonBytes` writes for a file
  that sets every field;
- removing a member from such a file is refused exactly when the schema
  requires it (`net`; an arc's `source` and `target`; a ref's `ref`);
- its enums are `ArcKind` and `Interface`;
- every corpus file this package accepts, written back, conforms. There is one
  exception, and it comes from the reference itself: petrus-engine writes
  a transition's `delay` as a number of seconds (`to_json`,
  `model_dump_json`), while its schema allows only an ISO 8601 string. The
  test expects exactly those violations, so any other violation fails.

The validator in `SchemaSpec` implements the keywords the schema uses and
fails on any other.

To regenerate the schema, use the reference's generator (this package has no
pydantic models to generate it from): moving the petrus-engine pin brings the
new file, and `LiveSpec` confirms it is current:

    "$(scripts/upstream-python petrus-engine)" -m petrus.cli gen-json-schema -o <file>

## 5. Upstream tests

| Upstream test file | Tests | Status | Where |
| --- | ---: | --- | --- |
| `tests/test_flatnet_loader.py` | 12 | ported | corpus `upstream/loader/*`, one case per test |
| `tests/test_flatnet_file_refs.py` | 4 | ported | corpus `upstream/file_refs/*`. `test_ref_keys_serialize_as_strings` is the `file` operation of `ref_keys_are_netpaths_after_validation`. |
| `tests/test_flatnet_resolution.py` | 11 | 10 ported, 1 out of scope | corpus `upstream/resolution/*`. `test_dsl_roundtrip_schema_maps_match` compares with the petrus-engine DSL, which is out of scope (SCOPE.md). |
| `tests/test_json_formatter.py` | 3 | ported | `UpstreamSpec` (`compactJsonWith`, same inputs and expected strings), and corpus `upstream/json_formatter/*` |
| `tests/test_timed_transitions.py` | 8 | 1 ported, 7 out of scope | corpus `upstream/timed/static_delay` (the schema delay a file carries). The rest test `PetriNetRuntime` timers. |
| `tests/test_net_path.py` | 27 | file-relevant parts covered | NetPath construction, dot splitting, the dot-in-segment refusals and `str` are exercised by the corpus `edge/segments-*`, `edge/refs-*` and `edge/dotted-*` cases. Navigation (`head`, `relative_to`, slicing) is runtime API. |
| `src/petrus/cli/main.py` (`petrus-cli`) | | `gen-json-schema` checked, `gen-stub` out of scope | `gen-json-schema`: section 4; the schema is the reference's artifact, regenerated by the reference. `gen-stub` writes `.pyi` stubs for Python net modules of the DSL, which is out of scope (SCOPE.md). |
| `tests/test_flatnet_nav.py`, `test_runtime_execution.py`, `test_subnet_execution.py`, `test_state_and_time_travel.py`, `test_timer_manager.py`, `test_tokens.py`, `test_dsl_*.py`, `test_stubgen.py` | | out of scope | petrus-engine's runtime and DSL, superseded by the `petrus` runtime (SCOPE.md) |

## Kernel nets

`KernelSpec` checks `toKernel`, the conversion of a loaded net into the
`petrus-impetus` kernel:

- the viewer's sample net, its paths, modes, weights, handlers, guards and
  marking;
- refs inlined;
- delays;
- repeated arcs;
- each kernel refusal with its message;
- every corpus net that petrus-engine loads. It must become a kernel net
  with the same nodes, arcs and marking, or be refused by the kernel. No
  corpus net may be refused by one path and accepted by the other.

petrus-engine has no kernel, and Petrus's v3 spec defines no v2 migration,
so there is no reference to compare this conversion against.
DIVERGENCES.md lists what the kernel refuses that petrus-engine runs.

## Running

    cabal test petrus-engine-file

The run prints 977 examples and 0 failures:

| Group | Examples |
| --- | ---: |
| `UpstreamSpec` | 3 |
| `CorpusSpec` (911 cases plus a coverage check) | 912 |
| `KernelSpec` | 12 |
| `SchemaSpec` | 5 |
| `LiveSpec` | 5 |
| `CliSpec` | 40 |

The live and CLI examples provision the reference venv on first use and fail
if they cannot.
