# hamsterdan-github benchmarks

<!-- scripts/bench: measured sources 349f5a5cb0cf091a at df073f3106e5 -->
<!-- scripts/bench: carried to eeb491cc93f0f4f3 at f87d05b6f42b: since 50635f0, no behavior or representation change on the measured paths: its Auth module uses Hamsterdan.PyLiteral's renamed constructors (PyNone..PyDict to LitNone..LitDict), names only; Hamsterdan.Python.Value.truthy is petrus-json's pythonTruthy, the same seven equations; hamsterdan-contracts' Codec Literal int-against-float test calls pyNumberEq, the same exact test it spelled out; Hamsterdan.Sqlite gains a comment only; petrus-sqlite's checkBindLength names the either throwIO pure . bindLength its bind loop already ran; petrus-json's Json == compiles to the same optimized Core as at 50635f0 (-ddump-simpl compared; numericEq/intFloatEq moved as pyNumberEq/exactFloatEq into Petrus.Json.Value and inlined there), PyObject's pyEq likewise, pythonTruthy added; petrus-posix gains additions only (DirectFd, directFd, writeDirect) and docs -->

These are the paths the GitHub boundary runs on every delivery and every
provider call:

- verifying a webhook signature (`X-Hub-Signature-256`, HMAC-SHA256);
- projecting an `issue_comment` payload to an `Observation`;
- encoding the stored observation (sorted, compact JSON);
- the whole `receive`: envelope checks, verification, projection and the
  SQLite insert;
- minting the App JWT (RS256);
- an installation `GET` through the full client stack: auth, the HTTP cache,
  response decoding, and the bounded transport;
- a gateway read (`pull_request`) over a fake transport;
- a lookup-first publisher hit among 100 bot comments.

Both sides run the same operations on the same inputs (`bench/inputs.json`,
written by `bench/make_inputs.py`):

- a 10 KB `issue_comment` webhook body;
- a 14 KB `GET /repos/{repo}/pulls/{n}` body;
- a page of 100 bot comments carrying finding markers.

The network is mocked on both sides. Python uses `httpx.MockTransport` under
`GitHubAppClients`. Haskell uses a scripted `Exchange` under `githubAppClients`.
Both return the same status, headers and body bytes. The installation token is
minted once before timing, so the `GET` measures the cached-token path.

## Current figures

Measured on 2026-10-13, 02:52–02:59 local (UTC-3), at commit `df073f3`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.58–3.67:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare hamsterdan-github 3 --twin '"$(scripts/upstream-python hamsterdan)" -I -B packages/hamsterdan-github/bench/bench.py'

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `webhook verify (HMAC-SHA256, 10 KB)` | 3.98 µs | 4.33 µs | 1.09× | 1.07× | 5 of 5 | 3.98 µs, 3.86 µs, 4.01 µs, 3.97 µs, 4.04 µs | 4.34 µs, 4.31 µs, 4.29 µs, 4.35 µs, 4.33 µs |
| `webhook verify, key state per call` | 3.94 µs | — | — | — | — | 3.94 µs, 3.85 µs, 3.97 µs |  |
| `webhook parse (issue_comment, 10 KB)` | 24.6 µs | 33.6 µs | 1.37× | 1.36× | 3 of 3 | 24.8 µs, 24.6 µs, 24.6 µs | 33.6 µs, 33.7 µs, 33.5 µs |
| `observation encode (sorted JSON)` | 1.35 µs | 4.89 µs | 3.62× | 3.55× | 3 of 3 | 1.37 µs, 1.34 µs, 1.35 µs | 4.87 µs, 4.89 µs, 4.92 µs |
| `webhook receive (verify, parse, SQLite insert)` | 68.1 µs | 81 µs | 1.19× | 1.12× | 3 of 3 | 68.1 µs, 66.9 µs, 70.6 µs | 82.8 µs, 81 µs, 79.2 µs |
| `App JWT mint (RS256, PEM key)` | 480 µs | 44.5 ms | 92.71× | 90.54× | 3 of 3 | 493 µs, 480 µs, 480 µs | 44.6 ms, 44.5 ms, 44.5 ms |
| `App JWT sign (RS256, parsed key)` | 451 µs | — | — | — | — | 454 µs, 451 µs, 449 µs |  |
| `installation GET pull (cached token, mock network)` | 44.6 µs | 180 µs | 4.03× | 4.01× | 3 of 3 | 44.6 µs, 44.7 µs, 44.6 µs | 180 µs, 180 µs, 179 µs |
| `gateway pull_request snapshot` | 1.78 µs | 2.34 µs | 1.31× | 1.29× | 3 of 3 | 1.79 µs, 1.78 µs, 1.78 µs | 2.31 µs, 2.34 µs, 2.36 µs |
| `publisher lookup hit (100 comments)` | 11.7 µs | 25.8 µs | 2.20× | 2.15× | 3 of 3 | 11.8 µs, 11.7 µs, 11.4 µs | 25.4 µs, 25.8 µs, 25.8 µs |

Haskell was ahead in every repetition of every row with a Python twin; the
closest is `webhook verify`, 1.09× (1.07× in the closest repetition; 1.10×
at `fcc7701`), an HMAC over 10 KB that both sides hand to C. It read 1.08×
after the three repetitions, so it got two more of its own (03:55–04:00,
load average 2.57–3.89, the same command with
`2 --pattern '/webhook verify/'`), and its line pools all five; the
Haskell-only row beside it keeps the three. `webhook receive`, the row
with the SQLite insert, reads 1.19×, as at `fcc7701`. The Haskell parse (13.9 →
24.6 µs) and the installation `GET` (27.1 → 44.6 µs) are slower than in the
table below, measured two days earlier at commit `74e6b1e`; both still lead
Python.

## Results

The machine was an Apple M4 (10 cores), macOS 26.3, shared with other
agents; the 1-minute load average was 5.0–5.6 during these runs
(2026-10-10, 21:40–21:45 local, UTC-3, commit `74e6b1e` with the switch to
wall-clock time in `bench/Main.hs`).

- Haskell: GHC 9.10.3 with `-O2`, `tasty-bench` 0.5.1 in wall-clock time
  (`localOption WallTime`), run with `+RTS -M2G`. Each cell is the mean of
  that benchmark run.
- Python: CPython 3.14.6 with githubkit 0.16.0, httpx 0.28.1, hishel 1.3.0,
  PyJWT 2.13.0 and cryptography 50.0.0. Each cell is the best of 5 `timeit`
  repeats (`time.perf_counter`).
- Both suites were run twice, interleaved (Haskell, Python, then Python,
  Haskell). The table shows each side's best run.

<!-- bench: superseded -->

| Operation | Haskell | Python | Python / Haskell |
| --- | ---: | ---: | ---: |
| webhook verify (HMAC-SHA256, 10 KB) | 4.06 µs | 4.37 µs | 1.08× |
| webhook parse (`issue_comment`, 10 KB) | 13.9 µs | 34.2 µs | 2.5× |
| observation encode (sorted JSON) | 2.81 µs | 5.06 µs | 1.8× |
| webhook receive (verify, parse, SQLite insert) | 77.6 µs | 99.2 µs | 1.28× |
| App JWT mint (RS256, from the PEM text) | 494 µs | 45,328 µs | 92× |
| installation GET pull (cached token, mock network) | 27.1 µs | 189.5 µs | 7.0× |
| gateway `pull_request` snapshot | 1.81 µs | 2.45 µs | 1.35× |
| publisher lookup hit (100 comments) | 11.1 µs | 26.2 µs | 2.4× |

The other runs: verify 4.15 µs against 4.43 µs, receive 82.4 µs against
114.2 µs; every other row within 3% of its best on both sides.

The figures committed before these timed Haskell in tasty-bench's default CPU
time. Only `webhook receive` does IO (the SQLite insert and its commit), and
it is the only row that moved: 49.6 µs then, 77.6 µs in wall-clock time now,
which takes it from 1.7× to 1.28× faster than Python.

Haskell is faster on every operation.

Two cases need a word of context:

- **Webhook verify** is bound by SHA-256 throughput on both sides. Both use the
  ARMv8 SHA-2 instructions: OpenSSL in Python, crypton's CRYPTOGAMS assembly
  in Haskell. A raw SHA-256 of the 10 KB body takes 3.6–4.0 µs on either
  side, so the margin is small: 1.07× and 1.08× in the two interleaved
  rounds above. Earlier single runs overlapped within noise (4.53 µs against
  4.50 µs).
  - The Haskell custody absorbs the secret's keyed HMAC pads once, when the
    inbox opens (`verifier`), and reuses that state for every delivery
    (`verifyWith`).
  - The bench also reports `verify` with the key state rebuilt on every call.
    Its best was 4.02 µs, the same as the custody path.
- **App JWT mint** is dominated on the Python side by
  `cryptography.load_pem_private_key`. PyJWT calls it on every mint, and it
  validates the RSA key on each load.
  - Haskell parses the PEM and signs in 494 µs. The bench also reports signing
    with an already-parsed key (462 µs).
  - GitHubKit caches the JWT for eight minutes, and so does the Haskell
    client, so this cost is paid rarely in production on either side.

Changes made for these numbers:

- **SQLite statement cache:** `Hamsterdan.Sqlite` keeps one prepared
  statement per SQL text on each connection. A statement is checked out
  atomically, then reset and unbound when it is returned. This mirrors
  CPython's `sqlite3` statement cache.
- **HMAC key state:** the custody precomputes the HMAC key state once (see
  above).
- **Signature comparison:** the expected `sha256=…` hex is compared to the
  header's bytes in constant time, without decoding either side to `Text`.

## Rerun

From the repository root:

`scripts/bench hamsterdan-github` runs exactly this block; `scripts/upstream-python hamsterdan`
provisions the pinned Hamsterdan and its environment:

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run hamsterdan-github +RTS -M2G -RTS
"$(scripts/upstream-python hamsterdan)" -I -B packages/hamsterdan-github/bench/bench.py
```

Run the Haskell benchmark from `packages/hamsterdan-github` if you call the
binary directly: it reads `bench/inputs.json` and
`test/corpus/app-test-key.pem` relative to that directory (`cabal bench`
already runs it there). `bench.py` finds its inputs next to itself, so it can
run from any directory.

To regenerate the shared inputs (deterministic):

```sh
python3 packages/hamsterdan-github/bench/make_inputs.py
```

The App key is the throwaway test key committed with the corpora. It signs
nothing outside this repository.
