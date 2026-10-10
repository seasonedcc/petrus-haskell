# hamsterdan-github benchmarks

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

## Results

The machine was an Apple M4 (10 cores), macOS 26.3, shared with other
builds; the 1-minute load average was 5–8 during these runs.

- Haskell: GHC 9.10.3 with `-O2`, `tasty-bench` 0.5.1, run with
  `+RTS -M2G`. Each cell is the mean of that benchmark run.
- Python: CPython 3.14.6 with githubkit 0.16.0, httpx 0.28.1, hishel 1.3.0,
  PyJWT 2.13.0 and cryptography 50.0.0. Each cell is the best of 5 `timeit`
  repeats.
- Both suites were run twice, interleaved. The verify case was run once more
  on each side. The table shows each side's best run.

| Operation | Haskell | Python | Python / Haskell |
| --- | ---: | ---: | ---: |
| webhook verify (HMAC-SHA256, 10 KB) | 4.12 µs | 4.49 µs | 1.09× |
| webhook parse (`issue_comment`, 10 KB) | 15.2 µs | 34.4 µs | 2.3× |
| observation encode (sorted JSON) | 3.06 µs | 4.99 µs | 1.6× |
| webhook receive (verify, parse, SQLite insert) | 49.6 µs | 82.1 µs | 1.7× |
| App JWT mint (RS256, from the PEM text) | 512 µs | 47,226 µs | 92× |
| installation GET pull (cached token, mock network) | 28.0 µs | 200.6 µs | 7.2× |
| gateway `pull_request` snapshot | 1.84 µs | 2.48 µs | 1.35× |
| publisher lookup hit (100 comments) | 11.2 µs | 27.0 µs | 2.4× |

Haskell is faster on every operation.

Two cases need a word of context:

- **Webhook verify** is bound by SHA-256 throughput on both sides. Both use the
  ARMv8 SHA-2 instructions: OpenSSL in Python, crypton's CRYPTOGAMS assembly
  in Haskell. A raw SHA-256 of the 10 KB body takes 3.6–4.0 µs on either
  side, so the margin is small. In single runs the two sides overlap within
  noise: the second interleaved round measured 4.53 µs against 4.50 µs.
  - The Haskell custody absorbs the secret's keyed HMAC pads once, when the
    inbox opens (`verifier`), and reuses that state for every delivery
    (`verifyWith`).
  - The bench also reports `verify` with the key state rebuilt on every call.
    Its best was 4.12 µs, the same as the custody path, but less stable
    under load.
- **App JWT mint** is dominated on the Python side by
  `cryptography.load_pem_private_key`. PyJWT calls it on every mint, and it
  validates the RSA key on each load.
  - Haskell parses the PEM and signs in 512 µs. The bench also reports signing
    with an already-parsed key (469 µs).
  - GitHubKit caches the JWT for eight minutes, and so does the Haskell
    client, so this cost is paid rarely in production on either side.

Changes made for these numbers:

- **SQLite statement cache:** `Hamsterdan.GitHub.Sqlite` keeps one prepared
  statement per SQL text on each connection. A statement is checked out
  atomically, then reset and unbound when it is returned. This mirrors
  CPython's `sqlite3` statement cache.
- **HMAC key state:** the custody precomputes the HMAC key state once (see
  above).
- **Signature comparison:** the expected `sha256=…` hex is compared to the
  header's bytes in constant time, without decoding either side to `Text`.

## Rerun

From the repository root:

```sh
cabal bench -j2 hamsterdan-github --benchmark-options='+RTS -M2G -RTS'
upstream/hamsterdan/.venv/bin/python packages/hamsterdan-github/bench/bench.py
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
