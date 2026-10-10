# petrus-cel benchmark results

Typical Petrus CEL expressions, compiled and evaluated through the Impetus
kernel seam: `Petrus.Cel.Impetus.celCompilers` in Haskell and
`petrus.impetus.binding.cel` (cel-python 0.5.0) in Python. Both sides run the
same seven cases on the same kernel values (tokens, bindings, markings), and
each side checks that every case holds before timing it.

## Machine

- Apple M4 (10 cores), 24 GiB RAM, macOS 26.3.1 (arm64)
- GHC 9.10.3, cabal 3.16.1; library built with `-O2`, benchmark with `-O2 -with-rtsopts=-A32m`
- Python 3.14.6 with celpy 0.5.0 and google-re2 1.1.20251105, from the pinned `upstream/petrus/.venv`
- Other background jobs were running on the machine, so absolute numbers are noisy. The ratios are large enough not to matter.

## Commands

From the repository root:

```sh
export PATH=$HOME/.ghcup/bin:$PATH
cabal build petrus-cel:bench:petrus-cel-bench --enable-benchmarks
cd packages/petrus-cel && "$(cabal list-bin petrus-cel:bench:petrus-cel-bench --enable-benchmarks)" --csv bench.csv
cd ../.. && upstream/petrus/.venv/bin/python packages/petrus-cel/bench/time_cel.py
```

## What is measured

- **parse**: source text to a syntax tree. In Haskell this is `Petrus.Cel.compile`, with the tree forced completely. In Python it is `celpy.Environment().compile`.
- **evaluate**: one call of the precompiled filter, guard or completion. This includes building the activation from the token JSON, which both sides do on every call.
- **compile+evaluate**: the kernel compiler (parse, free-variable check, closure), then one evaluation.

Haskell figures are tasty-bench means; their ± values are 2σ. Python figures are the best of 5 runs of the mean per call, with each run lasting at least 0.2 s.

## Numbers

| case | parse (Haskell) | parse (Python) | evaluate (Haskell) | evaluate (Python) | compile+evaluate (Haskell) | compile+evaluate (Python) | speed-up (compile+evaluate) |
|---|---:|---:|---:|---:|---:|---:|---:|
| filter/field | 1.75 µs | 48.4 µs | 0.34 µs | 93.3 µs | 2.17 µs | 157.8 µs | 73× |
| filter/conjunction | 18.8 µs | 198.8 µs | 0.80 µs | 209.4 µs | 21.9 µs | 486.9 µs | 22× |
| filter/regex | 7.20 µs | 56.5 µs | 4.27 µs | 81.8 µs | 12.2 µs | 170.4 µs | 14× |
| guard/correlate | 12.2 µs | 124.6 µs | 0.95 µs | 161.0 µs | 19.7 µs | 360.7 µs | 18× |
| guard/macros | 28.5 µs | 250.5 µs | 8.49 µs | 1.51 ms | 56.9 µs | 1.91 ms | 34× |
| completion/all | 18.9 µs | 160.6 µs | 9.54 µs | 1.52 ms | 38.0 µs | 1.78 ms | 47× |
| completion/exists | 24.5 µs | 202.5 µs | 2.65 µs | 463.5 µs | 36.4 µs | 791.5 µs | 22× |

The cases (see `bench/Main.hs` and `bench/time_cel.py`):

- **filter/field**: `amount >= 100`
- **filter/conjunction**: `amount >= 100 && currency == "USD" && !(status in ["void", "refunded"])`
- **filter/regex**: `email.matches(r'^[a-z.]+@example\.com$')`
- **guard/correlate**: `pending[0].data.amount <= config[0].data.limit`. It has one consumed token and one read token.
- **guard/macros**: `pending.all(t, t.data.amount < 500) && size(pending.filter(t, t.data.amount > 100)) >= 1`, over 11 consumed tokens.
- **completion/all**: `size(pending) == 0 && accepted.all(t, t.data.amount >= 100)`, over 3 places holding 25 tokens.
- **completion/exists**: `done.exists(t, t.color == "Result" && t.data.state == "ok") && size(failed) == 0`

The Haskell implementation is faster in every measurement: 8–28× on parsing, 19–270× on evaluation, and 14–73× on compile+evaluate.
