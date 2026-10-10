# fileVersion 2 benchmarks: Haskell vs petrus-engine

`bench/Main.hs` (tasty-bench) and `bench/python_bench.py` time the same steps
on the same input texts. Both sides generate the inputs byte for byte the
same and print their sizes, and the sizes agree:

| input | bytes in | out |
| --- | ---: | ---: |
| chain-10 | 1 949 | 2 212 bytes written |
| chain-1000 | 202 056 | 224 667 bytes written |
| chain-10000 | 2 130 285 | 2 356 040 bytes written |
| mounted-10 | 1 277 | 230 arcs resolved |
| mounted-100 | 12 437 | 2 300 arcs resolved |
| mounted-1000 | 128 537 | 23 000 arcs resolved |

The inputs:

- **chain-N**: one file, written on one line. It has N+1 places, N
  transitions and about 2.1N arcs, with keys out of canonical order, float
  coordinates, labels, weights, read arcs, delays, and a layout entry per
  node.
- **mounted-K**: a root file that mounts the `chain-10` net K times through
  `refs`, with an arc into each mount. Loading it means K+1 file reads,
  parses and catalog comparisons, and K mounts inlined.

The steps:

| step | petrus-engine | Haskell |
| --- | --- | --- |
| parse | `FlatNetFile.model_validate_json(text)` | `fromJson` |
| to_json | `file.to_json()` | `toJson` |
| format | `reformat_content(text, indent=2, max_inline=120)` | `reformatContent 2 120` |
| load | `FlatNet.from_filename(path).to_schema()` | `loadFile`, `toSchema` |

Each Haskell result is forced in full (`NFData`).

## How to rerun

From the repository root:

    cabal bench petrus-engine-file

For Python, use the pinned reference and its virtual environment:

    uv sync --frozen --python 3.14 --project upstream/petrus-engine   # once
    upstream/petrus-engine/.venv/bin/python packages/petrus-engine-file/bench/python_bench.py

Haskell numbers are tasty-bench means (± 2σ). Python numbers are the median
of 5 to 200 runs after one warm-up. Both were run on 2026-10-10 on an Apple
M4 with 24 GB of memory, using GHC 9.10.3 (`-O2`), CPython 3.14.6 and the
locked pydantic 2, with petrus-engine at `fc1dd50`. The machine was shared
with other builds, so absolute numbers moved by up to 25% between runs; the
table is one Haskell run and the Python run that followed it.

## Results

| input | step | Python | Haskell | speed-up |
| --- | --- | ---: | ---: | ---: |
| chain-10 | parse | 0.048 ms | 0.024 ms | 2.0× |
| chain-10 | to_json | 0.320 ms | 0.060 ms | 5.3× |
| chain-10 | format | 0.384 ms | 0.090 ms | 4.3× |
| chain-10 | load | 0.188 ms | 0.082 ms | 2.3× |
| chain-1000 | parse | 6.64 ms | 4.22 ms | 1.6× |
| chain-1000 | to_json | 33.1 ms | 8.07 ms | 4.1× |
| chain-1000 | format | 42.6 ms | 13.0 ms | 3.3× |
| chain-1000 | load | 22.1 ms | 13.5 ms | 1.6× |
| chain-10000 | parse | 118 ms | 70.1 ms | 1.7× |
| chain-10000 | to_json | 390 ms | 110 ms | 3.5× |
| chain-10000 | format | 529 ms | 179 ms | 3.0× |
| chain-10000 | load | 333 ms | 220 ms | 1.5× |
| mounted-10 | load | 2.77 ms | 1.28 ms | 2.2× |
| mounted-100 | load | 30.2 ms | 17.3 ms | 1.7× |
| mounted-1000 | load | 351 ms | 248 ms | 1.4× |

Over all runs, the closest comparison paired the fastest Python run with the
slowest Haskell run of the same step:

- mounted-1000 load: 351 ms against 301 ms, 1.17×;
- chain-10000 parse: 88.9 ms against 72.8 ms, 1.22×.

Every step was faster in Haskell in every run.

## Notes

- **Parsing is where Python is strongest.** pydantic validates JSON in Rust
  through jiter, so `parse` has the smallest margin. This package ports jiter
  and pydantic's checks and error reports, and still parses 1.6–2× faster.
- **Writing is where the gap is widest.** `compact_json` is pure Python and
  serializes each container again at every nesting level. The Haskell port
  keeps that algorithm, so its output and the thresholds it decides by are
  the same, and it runs 3–5× faster.
- **Loading grows a little faster than the input on both sides.** From
  mounted-100 to mounted-1000, Python takes 11.6× longer and Haskell 14×.
  Each mount is read and parsed again and compared with the catalog entry,
  as the reference does.
