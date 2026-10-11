# hamsterdan-export parity

This file lists what this package ports from `upstream/hamsterdan` (pinned in
[UPSTREAM.md](../../UPSTREAM.md) at `5d382467`) and the evidence for each
piece.

The reference is `upstream/hamsterdan/.venv` (CPython 3.14.6). Tests find it
through `upstreamPythonExecutable "hamsterdan"` from petrus-test-support and
run it with `python -I -B`. A test that needs the reference fails when the
reference is missing. It is never skipped.

## Upstream source → Haskell

| Upstream | Haskell | Evidence |
| --- | --- | --- |
| `host/export.py`: `export_package` and every helper | `Hamsterdan.Export` | `ExportSpec` (all 41 upstream cases) and `DifferentialSpec`. |
| `host/export.py`: `main` (argparse, the report, exit statuses) | `Hamsterdan.Export.runExport`, `app/Main.hs` (`hamsterdan-export`), hamsterdan-cli's `Hamsterdan.Cli.Argparse` | `ExportSpec` (`TestCommandLine`) and `DifferentialSpec`, which runs the binary. |
| The CPython calls `export.py` makes: `pathlib` (joining, `exists`, `is_file`, `is_dir`, `iterdir`, `glob`, `rglob`, `mkdir`), `shutil.copyfile`, `tempfile.TemporaryDirectory`, `sqlite3`, `json`, `str`/`int` built-ins, and their exception texts | `Hamsterdan.Export.Files`, `Hamsterdan.Export.Python` | `DifferentialSpec`'s hostile state directories. |

The package reuses:

- hamsterdan-readiness (`renderBoard`, the board renderer);
- hamsterdan-contracts (`Hamsterdan.PyLiteral`, for `repr` and the board
  failure texts);
- hamsterdan-github (`Hamsterdan.GitHub.Python`: `str.strip`,
  `int(text, base)`);
- petrus-engine-file (`PyJson.pyLoads`, `PyText.decodeText`);
- petrus-json (the `json.dumps` encoder).

## Upstream tests

| Upstream file | Functions | Cases | Haskell spec | Examples |
| --- | ---: | ---: | --- | ---: |
| `tests/unit/host/test_export.py` | 38 | 41 | `ExportSpec` | 41 |

Each upstream class is an hspec `describe` and each test keeps its name.
The parametrized `test_an_absent_store_is_named_in_the_readme` keeps its
pytest id (`[bodies-bodies.sqlite3]`). `test/Fixtures.hs` ports the
module's fixtures (`state_dir`, `deliveries`, `raw_delivery`, `_history`).

## Differential suite (no upstream counterpart)

`DifferentialSpec` is one example. It runs every case through
`differential/export_reference.py`, which calls the reference's `main(argv)`
in process from the case's `py/` directory. It runs the `hamsterdan-export`
binary from the sibling `hs/` directory, with the same arguments, over the
same state directory. Each case must give:

- the same exit status;
- the same stdout;
- the same stderr (for an exception the reference does not catch, the last
  traceback entry: the exception line and its notes, DIVERGENCES item 1);
- the same package tree, file by file and byte for byte, including the
  partial tree a failure part-way leaves.

The suite collects every mismatch before failing. There are 115 cases: 11
upstream fixtures, 4 host-driven, and 100 hostile state directories and
command lines.

- **Upstream fixtures (11):** the reference test suite's own state
  directories, built by its helpers. They cover the default fixture,
  sessionless and orphan bodies, repeated and newer History, each omitted
  store, raw deliveries with repeated directory spellings and credential
  files, and a missing webhooks store.
- **Host-driven state (4):** state directories written by the reference host
  itself (`hamsterdan-host`'s `differential/state_reference.py drive` over
  `differential/host_steps.json`: two synchronize webhooks and a workflow
  run for `owner/one` PR 7, converged and swept, about 600 History
  records). They are exported plain, with the agent routes in place, with
  raw deliveries and identity files, and for a pull request that has no
  Instance.
- **Hostile state directories:**
  - malformed, mistyped and ambiguous bindings, including Unicode-digit
    directory names;
  - History that is missing, blank, not JSON, not UTF-8, split at every
    `str.splitlines` boundary, carrying repeated keys, integers past the
    digit limit, NaN schemas and values of every type;
  - board entries that are not lists or that the renderer refuses;
  - routes, bodies, Pi operations and review requests that are blobs,
    integers, floats, NULLs, undecodable text or overlong ids;
  - WAL sidecars and locked or unreadable stores;
  - credential-named, hidden and symbolic-link identity files;
  - raw delivery directories with every file-name edge the classifier
    meets;
  - enough transcripts, History lines and boards to take the parallel paths
    (DIVERGENCES, internal), with a failure in the middle of each: a file
    name too long for the file system, a text session, colliding file names,
    a bad line, a board that does not render.
- **Command lines:** help at widths 1 to 200, every parser error,
  abbreviations, negative pull requests, output paths that exist, are files
  or are not empty, and repeated options.

## Benchmarks

[bench/RESULTS.md](bench/RESULTS.md) times both sides by wall clock. The
Haskell side is at least as fast on every row.
