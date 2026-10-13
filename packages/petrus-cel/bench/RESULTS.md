# petrus-cel benchmark results

<!-- scripts/bench: measured sources d96ae160a5a8769d at 4b2f7e6ecdef -->

Typical Petrus CEL expressions, compiled and evaluated through the Impetus
kernel seam: `Petrus.Cel.Impetus.celCompilers` in Haskell and
`petrus.impetus.binding.cel` (cel-python 0.5.0) in Python. Both sides run the
same seven cases on the same kernel values (tokens, bindings, markings), and
each side checks that every case holds before timing it.

## Machine

- Apple M4 (10 cores), 24 GiB RAM, macOS 26.3.1 (arm64)
- GHC 9.10.3, cabal 3.16.1; library built with `-O2`, benchmark with `-O2 -threaded -with-rtsopts=-A32m`
- Python 3.14.6 with celpy 0.5.0 and google-re2 1.1.20251105, from the pinned `upstream/petrus/.venv`
- Other background jobs were running on the machine, so absolute numbers are noisy. The ratios are large enough not to matter.

## Commands

From the repository root (`scripts/bench petrus-cel` runs exactly this;
`scripts/upstream-python` provisions the pinned reference):

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run petrus-cel +RTS -M2G -RTS
"$(scripts/upstream-python)" -B packages/petrus-cel/bench/time_cel.py
```

Haskell times are wall-clock time (`localOption WallTime` in `bench/Main.hs`),
like the Python side's `time.perf_counter`. The table above was taken before
that switch, in tasty-bench's default CPU time; this workload is
single-threaded and does no I/O inside the timed region, so the two agree
(see [CPU and wall-clock time](../../../docs/reproducing.md#cpu-and-wall-clock-time)).

## What is measured

- **parse**: source text to a syntax tree. In Haskell this is `Petrus.Cel.compile`, with the tree forced completely. In Python it is `celpy.Environment().compile`.
- **evaluate**: one call of the precompiled filter, guard or completion. This includes building the activation from the token JSON, which both sides do on every call.
- **compile+evaluate**: the kernel compiler (parse, free-variable check, closure), then one evaluation.

Haskell figures are tasty-bench means; their ± values are 2σ. Python figures are the best of 5 runs of the mean per call, with each run lasting at least 0.2 s.

## Current figures

Measured on 2026-10-12, 22:38–22:42 local (UTC-3), at commit `9c6cdb8` with
the benchmark built `-threaded` (below), on the Apple M4 (Darwin arm64) with
a 1-minute load average of 2.04–2.72: three interleaved repetitions,
alternating which side goes first, of

    scripts/bench-compare petrus-cel 3 --twin '"$(scripts/upstream-python)" -B packages/petrus-cel/bench/time_cel.py'

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6, best
of 5 runs). Each figure is the median over the repetitions, and the ratio is
Python ÷ Haskell (above 1 means Haskell is faster). Haskell is faster in
every measurement: 9.9–24× on parsing, 23–337× on evaluation and 18–70× on
compile+evaluate. The table under "Numbers" is the earlier measurement.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `filter/field.parse` | 1.54 µs | 36.3 µs | 23.54× | 23.26× | 3 of 3 | 1.53 µs, 1.54 µs, 1.56 µs | 36.5 µs, 36 µs, 36.3 µs |
| `filter/field.evaluate` | 310 ns | 68.1 µs | 219.51× | 216.51× | 3 of 3 | 310 ns, 309 ns, 315 ns | 67.3 µs, 68.6 µs, 68.1 µs |
| `filter/field.compile+evaluate` | 1.86 µs | 130 µs | 69.93× | 69.93× | 3 of 3 | 1.84 µs, 1.86 µs, 1.86 µs | 130 µs, 130 µs, 131 µs |
| `filter/conjunction.parse` | 12.9 µs | 171 µs | 13.30× | 13.28× | 3 of 3 | 12.9 µs, 12.8 µs, 12.9 µs | 171 µs, 170 µs, 172 µs |
| `filter/conjunction.evaluate` | 541 ns | 182 µs | 336.54× | 333.10× | 3 of 3 | 547 ns, 541 ns, 541 ns | 182 µs, 181 µs, 183 µs |
| `filter/conjunction.compile+evaluate` | 13.3 µs | 410 µs | 30.73× | 30.29× | 3 of 3 | 13.3 µs, 13.3 µs, 13.5 µs | 410 µs, 405 µs, 410 µs |
| `filter/regex.parse` | 4.81 µs | 47.8 µs | 9.95× | 9.87× | 3 of 3 | 4.81 µs, 4.76 µs, 4.84 µs | 48.8 µs, 47.8 µs, 47.8 µs |
| `filter/regex.evaluate` | 2.9 µs | 67.9 µs | 23.44× | 23.05× | 3 of 3 | 2.89 µs, 2.9 µs, 2.94 µs | 67.9 µs, 67.9 µs, 67.8 µs |
| `filter/regex.compile+evaluate` | 7.81 µs | 143 µs | 18.30× | 18.18× | 3 of 3 | 7.82 µs, 7.74 µs, 7.81 µs | 142 µs, 143 µs, 143 µs |
| `guard/correlate.parse` | 7.93 µs | 108 µs | 13.57× | 13.39× | 3 of 3 | 7.93 µs, 7.92 µs, 7.98 µs | 108 µs, 108 µs, 107 µs |
| `guard/correlate.evaluate` | 625 ns | 138 µs | 220.57× | 217.94× | 3 of 3 | 625 ns, 621 ns, 629 ns | 138 µs, 138 µs, 137 µs |
| `guard/correlate.compile+evaluate` | 12.2 µs | 318 µs | 26.06× | 25.16× | 3 of 3 | 12.2 µs, 12.1 µs, 12.6 µs | 319 µs, 318 µs, 317 µs |
| `guard/macros.parse` | 18.6 µs | 233 µs | 12.56× | 12.38× | 3 of 3 | 18.6 µs, 18.6 µs, 19.1 µs | 233 µs, 230 µs, 237 µs |
| `guard/macros.evaluate` | 5.65 µs | 1.45 ms | 256.54× | 253.41× | 3 of 3 | 5.64 µs, 5.65 µs, 5.68 µs | 1.43 ms, 1.47 ms, 1.45 ms |
| `guard/macros.compile+evaluate` | 35.8 µs | 1.83 ms | 51.14× | 49.91× | 3 of 3 | 35.8 µs, 35.7 µs, 36.5 µs | 1.83 ms, 1.83 ms, 1.82 ms |
| `completion/all.parse` | 11.8 µs | 154 µs | 13.09× | 12.97× | 3 of 3 | 11.8 µs, 11.7 µs, 11.9 µs | 154 µs, 152 µs, 155 µs |
| `completion/all.evaluate` | 6.46 µs | 1.46 ms | 226.16× | 223.06× | 3 of 3 | 6.46 µs, 6.43 µs, 6.47 µs | 1.44 ms, 1.46 ms, 1.47 ms |
| `completion/all.compile+evaluate` | 25 µs | 1.72 ms | 68.81× | 67.65× | 3 of 3 | 25 µs, 24.9 µs, 25.4 µs | 1.72 ms, 1.71 ms, 1.72 ms |
| `completion/exists.parse` | 15.2 µs | 196 µs | 12.91× | 12.78× | 3 of 3 | 15.3 µs, 15 µs, 15.2 µs | 196 µs, 194 µs, 196 µs |
| `completion/exists.evaluate` | 1.71 µs | 448 µs | 262.94× | 258.83× | 3 of 3 | 1.71 µs, 1.69 µs, 1.71 µs | 441 µs, 448 µs, 450 µs |
| `completion/exists.compile+evaluate` | 24.6 µs | 759 µs | 30.88× | 30.06× | 3 of 3 | 24.6 µs, 24.5 µs, 25.3 µs | 764 µs, 758 µs, 759 µs |

The benchmark is now built with `-threaded`. Built without it, it stopped
for good partway through a `scripts/bench-compare` run on 2026-10-12, at 0%
CPU with its main thread in the non-threaded RTS's deadlock path
(`awaitUserSignals`, from `sample`); petrus-impetus's benchmark did the
same. The threaded build ran through.

## Numbers

<!-- bench: superseded -->

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

In that earlier measurement the Haskell implementation was faster in every measurement: 8–28× on parsing, 19–270× on evaluation, and 14–73× on compile+evaluate.
