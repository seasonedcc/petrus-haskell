# petrus-cel benchmark results

<!-- scripts/bench: measured sources fdcbc90965f6d05c at 5a73d7a7f019 -->

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

Measured on 2026-10-12, 05:17–05:21 local (UTC-3), at commit `fc3e42b` with
the benchmark built `-threaded` (below), on the Apple M4 (Darwin arm64) with
a 1-minute load average of 2.22–2.80: three interleaved repetitions,
alternating which side goes first, of

    scripts/bench-compare petrus-cel 3 --twin '"$(scripts/upstream-python)" -B packages/petrus-cel/bench/time_cel.py'

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6, best
of 5 runs). Each figure is the median over the repetitions, and the ratio is
Python ÷ Haskell (above 1 means Haskell is faster). Haskell is faster in
every measurement: 7.9–22× on parsing, 19–289× on evaluation and 14–67× on
compile+evaluate. The table under "Numbers" is the earlier measurement.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `filter/field.parse` | 1.62 µs | 36.3 µs | 22.39× | 22.16× | 1.64 µs, 1.62 µs, 1.62 µs | 36.4 µs, 36.2 µs, 36.3 µs |
| `filter/field.evaluate` | 316 ns | 67.9 µs | 214.76× | 211.49× | 317 ns, 316 ns, 314 ns | 67 µs, 68.4 µs, 67.9 µs |
| `filter/field.compile+evaluate` | 1.96 µs | 131 µs | 66.68× | 64.86× | 1.96 µs, 2.02 µs, 1.96 µs | 131 µs, 131 µs, 130 µs |
| `filter/conjunction.parse` | 16.8 µs | 172 µs | 10.21× | 10.18× | 16.9 µs, 16.8 µs, 16.7 µs | 172 µs, 172 µs, 171 µs |
| `filter/conjunction.evaluate` | 629 ns | 182 µs | 288.78× | 286.56× | 634 ns, 629 ns, 629 ns | 182 µs, 183 µs, 181 µs |
| `filter/conjunction.compile+evaluate` | 17.9 µs | 406 µs | 22.66× | 22.66× | 17.9 µs, 17.9 µs, 17.9 µs | 406 µs, 411 µs, 406 µs |
| `filter/regex.parse` | 6.05 µs | 48 µs | 7.94× | 7.89× | 5.98 µs, 6.05 µs, 6.05 µs | 47.2 µs, 48.8 µs, 48 µs |
| `filter/regex.evaluate` | 3.55 µs | 68.3 µs | 19.24× | 19.24× | 3.51 µs, 3.56 µs, 3.55 µs | 67.7 µs, 68.6 µs, 68.3 µs |
| `filter/regex.compile+evaluate` | 9.76 µs | 142 µs | 14.50× | 14.28× | 9.89 µs, 9.71 µs, 9.76 µs | 141 µs, 144 µs, 142 µs |
| `guard/correlate.parse` | 10.3 µs | 107 µs | 10.37× | 9.91× | 10.6 µs, 10.3 µs, 10.3 µs | 105 µs, 107 µs, 107 µs |
| `guard/correlate.evaluate` | 789 ns | 138 µs | 174.17× | 172.40× | 789 ns, 791 ns, 789 ns | 136 µs, 138 µs, 138 µs |
| `guard/correlate.compile+evaluate` | 16.3 µs | 320 µs | 19.68× | 19.58× | 16.3 µs, 16.3 µs, 16.2 µs | 320 µs, 319 µs, 322 µs |
| `guard/macros.parse` | 24.4 µs | 233 µs | 9.56× | 9.40× | 24.4 µs, 24.4 µs, 24.1 µs | 230 µs, 233 µs, 234 µs |
| `guard/macros.evaluate` | 7 µs | 1.46 ms | 208.67× | 207.25× | 7 µs, 7.04 µs, 6.98 µs | 1.45 ms, 1.46 ms, 1.46 ms |
| `guard/macros.compile+evaluate` | 46.7 µs | 1.82 ms | 38.95× | 38.93× | 46.8 µs, 46.7 µs, 46.5 µs | 1.82 ms, 1.82 ms, 1.83 ms |
| `completion/all.parse` | 15.6 µs | 154 µs | 9.87× | 9.73× | 15.7 µs, 15.6 µs, 15.5 µs | 153 µs, 154 µs, 155 µs |
| `completion/all.evaluate` | 8.09 µs | 1.46 ms | 180.51× | 177.64× | 8.09 µs, 8.22 µs, 8.03 µs | 1.45 ms, 1.46 ms, 1.46 ms |
| `completion/all.compile+evaluate` | 32.5 µs | 1.71 ms | 52.61× | 50.24× | 32.5 µs, 32.5 µs, 34 µs | 1.71 ms, 1.71 ms, 1.71 ms |
| `completion/exists.parse` | 20.9 µs | 194 µs | 9.29× | 8.99× | 21.4 µs, 20.9 µs, 20.4 µs | 193 µs, 195 µs, 194 µs |
| `completion/exists.evaluate` | 2.05 µs | 447 µs | 217.65× | 214.71× | 2.05 µs, 2.05 µs, 2.08 µs | 441 µs, 447 µs, 447 µs |
| `completion/exists.compile+evaluate` | 33.2 µs | 752 µs | 22.63× | 22.33× | 33.5 µs, 33.1 µs, 33.2 µs | 748 µs, 752 µs, 755 µs |

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
