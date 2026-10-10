# petrus-engine-file

Petri net files in [petrus-engine](https://github.com/henriquebastos/petrus-engine)'s
`fileVersion: "2"` format, the format
[petrus-viewer](https://github.com/henriquebastos/petrus-viewer) saves. Nets
authored in the viewer keep loading here, with the reference's acceptance,
refusals, error texts and canonical spelling. Both references are pinned in
[`upstream/`](../../upstream), see [UPSTREAM.md](../../UPSTREAM.md).

## The format

A file is one JSON object, defined by petrus-engine's pydantic models (at
`fc1dd50`):

| Key | Model | Contents |
| --- | --- | --- |
| `fileVersion` | `FlatNetFile.fileVersion` | Any string; written as `"2"` by default. |
| `net` | `FlatNetFile.net` | The net's name (required). |
| `arcs` | `list[FlatArc]` | `source`, `target` (dotted paths), `kind` (`normal`, `read`, `inhibitor`), `weight`, `metadata`. |
| `places` | `dict[NetPath, PlaceDef]` | `initial`, `label`, `interface` (`input`, `output`, `awaiting`, `control`), `metadata`. |
| `transitions` | `dict[NetPath, TransitionDef]` | `handler`, `guard`, `label`, `metadata`, `delay` (a pydantic `timedelta`: seconds or a duration string). |
| `refs` | `dict[NetPath, RefEntry]` | Mount points: `{"ref": "other.json"}`, resolved against the root file's directory. |
| `viewState` | `ViewState` | The viewer's layout: `layout`, `zoom`, `pan`, `selected`, `arcWaypoints`. |

The definition lives in `upstream/petrus-engine/src/petrus/`:

- `schema.py`: `FlatNetFile` and the models above, `FlatNet`,
  `FlatSchema`;
- `types.py`: `NetPath`;
- `loader.py`: multi-file loading;
- `json_formatter.py`: `compact_json`, the canonical writer;
- `cli/format_json.py`: the format CLI;
- `net_file_schema.json`: the exported JSON Schema.

The viewer reads and writes the same shape (`src/utils/fileIO.ts`,
`flatFormat.ts`, `compactJson.ts`), and may add `viewState.annotations`, which
the engine ignores as an extra field. Older viewer files (`fileVersion` other
than `"2"`, the nested v1 shape) are refused by the viewer itself and have no
loader upstream, so they are out of scope (DIVERGENCES.md).

## API

`Petrus.EngineFile`:

| Haskell | petrus-engine |
| --- | --- |
| `fromFilename path` | `FlatNetFile.from_filename(path)` |
| `fromJson bytes` | `FlatNetFile.model_validate_json(bytes)` |
| `fromDict value` | `FlatNetFile.from_dict(data)` |
| `toJson indent maxInline file`, `toJsonBytes` | `file.to_json(indent, max_inline)`, byte for byte |
| `reformatContent indent maxInline text` | `petrus.cli.format_json.reformat_content` |
| `loadFile path` | `FlatNet.from_filename(path)`: refs read, checked and inlined |
| `loadDict root deps` | `FlatNet.from_dict(root, deps)` |
| `toSchema flat` | `flat.to_schema()`, the executable projection |
| `toKernel schema`, `loadKernelFile path` | (none) the schema as a validated kernel `Net` of `petrus-impetus`, with its initial marking |

Refusals come back as `Left PyException {exceptionClass, message}` with the
reference's class name (`ValidationError`, `ValueError`, `FileNotFoundError`,
`TypeError`, ...) and its `str(exception)`, including pydantic's multi-line
validation reports.

### Kernel nets

petrus-engine runs a file by building a `PetriNetRuntime` from its
`FlatSchema`. Here `toKernel` takes the same `FlatSchema` to the Haskell
kernel's types (`Petrus.Impetus.Petrinet.Schema`):

- paths stay absolute and net-prefixed (`order_system.payment.pending`);
- a place-to-transition arc is an input arc, with `normal`, `read` and
  `inhibitor` becoming `Consume`, `Read` and `Inhibit`;
- `handler` and `guard` become `HandlerSymbol` and `GuardSymbol`;
- `delay` becomes a `Delay` in seconds;
- the marking is `FlatSchema.initial_marking()`;
- `mkNet` validates the result, and its refusals keep the kernel's messages.

The kernel is stricter than petrus-engine's runtime. DIVERGENCES.md lists
the nets that load here but are not kernel nets.

## `petrus-format-json`

`python -m petrus.cli.format_json`, with the same options, output, exit
status and error lines:

    petrus-format-json nets/*.json                    # format in place
    petrus-format-json --fail-on-change nets/*.json   # exit 1 when anything changed
    petrus-format-json < in.json > out.json           # stdin to stdout
    petrus-format-json --infile in.json --outfile out.json --indent 2 --max-inline 120

## Tests and benchmarks

    cabal test petrus-engine-file
    cabal bench petrus-engine-file

The differential corpus and the live checks against the pinned petrus-engine
are described in [PARITY.md](PARITY.md); the benchmark numbers are in
[bench/RESULTS.md](bench/RESULTS.md).

## License

Apache-2.0 (LICENSE). The ported upstream is MIT; see NOTICE.
