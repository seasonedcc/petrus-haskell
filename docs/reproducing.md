# Reproducing everything from a clean checkout

This page takes a fresh machine to a full rerun of what this repository
claims: the build, the test suites (unit, conformance and interop with the
pinned Python), the cross-language suites on their own, the benchmarks
against the pinned Python, and the parity table. `scripts/check-all` runs all of it but
the benchmarks and, unless asked with `--viewer`, the upstream petrus-viewer
suites. CI (`.github/workflows/ci.yml`) runs the same steps, `--viewer`
included, on every push to `main` and every pull request, spread over
several runners ([Continuous integration](#continuous-integration)).

## Prerequisites

| Tool | Version | Used for |
| --- | --- | --- |
| [ghcup](https://www.haskell.org/ghcup/) | any | installs the two below |
| GHC | 9.10.3 exactly | `ghcup install ghc 9.10.3 && ghcup set ghc 9.10.3` |
| cabal | 3.16.1.0 (3.16 or later) | `ghcup install cabal 3.16.1.0 && ghcup set cabal 3.16.1.0` |
| [uv](https://docs.astral.sh/uv/) | 0.9 or later | provisions the pinned Python references (it downloads CPython 3.14.6 itself) |
| python3 | 3.9 or later | the repository's scripts (`scripts/bench`, `scripts/interop`, ...) |
| git | with submodule support | the pinned upstream projects are submodules |
| libzmq, libpq, SQLite | system packages | the ZeroMQ, PostgreSQL and SQLite bindings |
| libbz2, liblzma (with `pkg-config`) | system packages (macOS ships libbz2) | petrus-execution's bzip2 and xz workspace-archive decoding |
| PostgreSQL 17 (`initdb`, `pg_ctl`) **or** Docker | 17.x | the PostgreSQL suites and benchmarks |
| Node.js | 22 (CI pins 22.19.0) | the Gondolin sidecar and Pi helper suites; the petrus-viewer suites and the viewer benchmark (with pnpm) |
| pnpm | 11.5.1 exactly | the petrus-viewer suites (`--viewer`) and the viewer benchmark. It is the upstream viewer's `packageManager` pin, so `corepack enable` provides exactly it; CI installs `pnpm@11.5.1` |
| Graphviz (`dot`) | any | petrus-impetus's diagram rendering tests |
| bash | 4.4 or later | hamsterdan-operator's secret-launch tests (macOS ships bash 3.2). They use `$PETRUS_BASH` when it is set, else the first bash of at least 4.4 among `bash` on `PATH`, `/opt/homebrew/bin/bash` and `/usr/local/bin/bash` |

A suite whose tool is missing fails and names the tool; it does not skip.

On macOS with Homebrew:

```sh
brew install ghcup uv zeromq libpq sqlite xz pkgconf node pnpm graphviz bash postgresql@17
ghcup install ghc 9.10.3 && ghcup set ghc 9.10.3
ghcup install cabal 3.16.1.0 && ghcup set cabal 3.16.1.0
```

On Ubuntu 24.04 (what CI uses):

```sh
sudo apt-get install -y build-essential libzmq3-dev libpq-dev libsqlite3-dev libbz2-dev liblzma-dev pkg-config graphviz
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
curl -LsSf https://astral.sh/uv/install.sh | sh
sudo apt-get install -y docker.io && sudo usermod -aG docker "$USER"   # or PostgreSQL 17, below
```

plus Node.js 22 (for example from NodeSource) with pnpm 11.5.1
(`corepack enable` inside `upstream/petrus-viewer`, or
`npm install -g pnpm@11.5.1` as CI does), and, instead of Docker, PostgreSQL
17 from the [PGDG apt repository](https://www.postgresql.org/download/linux/ubuntu/)
also works (Ubuntu 24.04's own `postgresql` package is 16). Log in again after
`usermod` so the `docker` group applies. The `--viewer` suites' Chromium also
needs its system libraries: `npx playwright install --with-deps chromium`
(below) installs them through apt.

Haskell dependency versions are pinned in `cabal.project.freeze` (every
Hackage package's exact version, plus the Hackage `index-state`), so a clean
checkout builds against the same libraries CI and the committed benchmarks
used. Run `cabal update` once so the index reaches that state. (`cabal
update` moves your user-wide package index to the latest state; this project
still resolves at the freeze file's `index-state`, so other projects are
unaffected unless they leave `index-state` unpinned.) To move the
pins, run `cabal freeze`, keep only the version lines and the `index-state`
(the flag lines describe the machine that ran it), and let CI confirm.

The scripts put `~/.ghcup/bin` and `~/.local/bin` (uv's default location) on
`PATH` themselves.

### PostgreSQL

The PostgreSQL suites read `PETRUS_TEST_POSTGRES`, a URL to a server where
the role may create databases (each test creates and drops its own scratch
database). When it is unset, `scripts/check-all`, `scripts/interop` and
`scripts/bench` wrap their runs in `scripts/with-postgres`, which starts a
throwaway PostgreSQL 17 for the duration of the command and removes it
afterwards:

- with `initdb`/`pg_ctl` from Postgres.app 17, `/usr/lib/postgresql/17/bin`,
  Homebrew's `postgresql@17`, or `PATH`: a fresh cluster in a temporary
  directory, on a free port of 127.0.0.1;
- otherwise with Docker: a `postgres:17` container on a free local port;
- with neither, it stops with a message saying so.

To use your own server instead:

```sh
export PETRUS_TEST_POSTGRES=postgresql://postgres:postgres@127.0.0.1:5432/postgres
```

## Clone

```sh
git clone --recursive https://github.com/seasonedcc/petrus-haskell.git
cd petrus-haskell
```

The repository and the upstream projects are public, so no account is needed.
`--recursive` checks out the four pinned upstream projects under
`upstream/` ([UPSTREAM.md](../UPSTREAM.md)). In an existing clone,
`git submodule update --init --recursive` does the same.

## Build and test

```sh
scripts/check-all -j2
```

It runs, in order, and stops at the first failing step:

0. A preflight for the tools the later steps need: a bash of at least 4.4
   (looked up as the secret-launch tests do: `$PETRUS_BASH`, `bash` on
   `PATH`, `/opt/homebrew/bin/bash`, `/usr/local/bin/bash`), uv, and
   `PETRUS_TEST_POSTGRES`, PostgreSQL's `initdb`/`pg_ctl` or Docker. A
   missing one stops the script here, before the build, with what to
   install, instead of failing the test step half an hour in and skipping
   every step after it. On stock macOS that means `brew install bash` (or
   `PETRUS_BASH=/path/to/bash`).
1. `scripts/check-pins`: the submodules sit at the commits UPSTREAM.md pins.
2. `scripts/lint-skips`: no test goes pending, or skips, because a Python
   reference is missing (see [No silent skips](#no-silent-skips)).
3. `scripts/lint-hamsterdan-architecture`: the Hamsterdan packages keep the
   import boundaries of upstream `tests/test_architecture.py`.
4. `scripts/check-pending --self-test`: the pending check of step 9 still
   reads hspec's output, coloured or plain, from the fixture logs in
   `scripts/check-pending.d/`.
5. Provisioning of the Python references (`scripts/upstream-python petrus`,
   `petrus-engine`, `hamsterdan` and `petrus-sdks`): CPython 3.14.6 and each
   project's frozen `uv.lock`, in `upstream/<project>/.venv`. `petrus-sdks`
   is `upstream/petrus` with the real Claude and Amp SDKs at the reference's
   pins, kept apart in `dist-newstyle/upstream-python/petrus-sdks/.venv`.
6. `cabal build all` (every package is `-Werror`).
7. `scripts/interop --check`: every pattern `scripts/interop` uses still
   selects tests.
8. `cabal test all` under `scripts/with-postgres`, every test binary with
   `+RTS -M2G -RTS`. This includes the conformance and interop groups.
9. `scripts/check-pending`: no example went pending in step 8. A pending
   example is a test that did not run, so a missing tool (Graphviz `dot`,
   `node`) or server fails the run. The only examples that may stay pending
   are listed in the script: the Docker tests, which wait for
   `PETRUS_TEST_DOCKER=1` (CI sets it, and check-all refuses to run in CI
   without it), and the reference's own opt-in acceptance tests. Those
   acceptance tests need provider credentials or exactly installed external
   toolchains, and the reference skips them too. A suite log without hspec's
   summary line fails too, so a crashed suite or an unreadable log cannot
   pass as "nothing pending".
10. `scripts/check-corpora`: every committed corpus is regenerated against
    the pinned references (and Node 22, for the viewer's V8 and WHATWG URL
    corpora) and must come out unchanged.
11. With `--viewer` only: the upstream petrus-viewer suites against the
    Haskell backend, then `record-mcp-transcript.mjs --check`, which
    re-records the MCP golden transcript through the upstream Node MCP server.
12. With `--bench` only: `scripts/bench`, every benchmark against Python.
13. `scripts/bench --check`: every package's benchmark results document how
    to rerun them and which sources they measured, and
    `bench-results/summary.md` matches them. It also lists, as `STALE` (a
    warning), every results file measured on code that has changed since:
    the package's own sources, any local package it builds on, the cabal
    project and freeze file, the upstream pins or the twins' timing harness.
    A file carried forward to the current sources counts as current
    ([Which code the figures measured](#which-code-the-figures-measured)).
14. `scripts/check-parity`: the parity table's claims hold: evidence for
    every component at parity, no cited benchmark row below 1.0×, and every
    upstream test count the parity ledgers cite (in `PARITY.md` and every
    package's `PARITY.md` and `parity` files: "all 11 `test_sqlite_history.py`
    tests (14 cases)", the Functions and Cases columns, the not-ported
    tables) equal to what pytest collects at the pinned upstream commits, as
    recorded in `docs/upstream-test-counts.json` (`scripts/upstream-test-counts
    --write` recollects all three projects after a submodule moves). A count
    the script cannot read fails too, so none goes unchecked. No document states how
    many Haskell examples a suite has (`scripts/lint-example-counts`): such a
    number goes stale with the next test. `cabal test` prints each suite's
    count, and CI's `test` jobs print every suite's. Nor does a parity or
    divergence document restate a benchmark ratio (`scripts/lint-bench-figures`):
    it would go stale with the next rerun, so they point at the results
    files and name rows without their figures. It warns
    (`STALE evidence`) about components whose cited results are stale, and
    names (`CARRIED evidence`) those whose cited results were carried forward.
15. `packages/petrus-engine/scripts/parity_check.py`: the runtime test
    ledgers account for every in-scope upstream test.

`-j2` limits cabal's parallelism; leave it out to use every core.
`--ghc-options=...` is passed to every cabal command that builds, so a heap
cap for GHC itself goes there:

```sh
scripts/check-all -j2 --ghc-options='+RTS -M3G -RTS'
```

(The test binaries already run with `+RTS -M2G -RTS`.) What a full run
takes, measured on an Apple M4 with 24 GB of memory at `-j2`, with the
Hackage dependencies already in the cabal store (October 2026):

- **Time**: about 25 minutes of wall-clock time for steps 0 to 8 (the build
  about 11 minutes, the test suites most of the rest), and 2 to 3 minutes
  for steps 9 to 15. A cold cabal store adds the Hackage dependencies' build,
  roughly another 20 minutes.
- **Disk**: about 6.5 GB for `dist-newstyle`, about 1 GB for the cabal
  store's Hackage dependencies, about 1 GB for the four upstream Python
  environments (plus uv's download cache), and about 3 GB for GHC itself;
  keep at least 15 GB free.
- **Memory**: GHC needs up to about 3 GB for the largest modules, so at
  `-j2` allow about 8 GB for the build (with the `-M3G` cap above GHC fails
  rather than swapping); the test step runs up to `-j` suites at once, each
  capped at 2 GB.
`--viewer` adds, after the tests, the upstream petrus-viewer suites against
the Haskell backend (`scripts/interop --viewer petrus-viewer-server`, below);
they need Node 22, pnpm, `pnpm install --frozen-lockfile && pnpm build` in
`upstream/petrus-viewer`, and `npx playwright install --with-deps chromium`
(`--with-deps` also installs Chromium's system libraries on Linux; CI runs it).

One package's suite, or one group in it:

```sh
cabal build -j2 petrus-sqlite
cabal test -j2 petrus-sqlite --test-options='+RTS -M2G -RTS'
cabal test -j2 petrus-impetus --test-option=-m --test-option='differential corpus'
```

## Interop with the pinned Python

```sh
scripts/interop                 # every package's cross-language groups
scripts/interop petrus-fabric   # one package
scripts/interop --list          # what each pattern selects, without running it
scripts/interop --viewer        # also the upstream petrus-viewer test suites against
                                # the Haskell backend
```

`scripts/check-all` already runs these groups as part of each package's
suite (the `--viewer` suites only when given `--viewer` too).
`scripts/interop` runs only them: the live interop against reference
processes over shared files, databases and sockets, the byte-for-byte
comparisons with the reference's servers and CLIs, the committed
differential corpora, and the conformance suites shared with the reference.
It is the quick check after moving a pin or touching a wire format. Each run
passes hspec's `--fail-on=empty,pending`, so a renamed group or a test that
goes pending fails it. `--viewer` needs `pnpm install` in
`upstream/petrus-viewer` (and `pnpm build` plus
`npx playwright install --with-deps chromium` for its browser suites).

The committed differential corpora, fixture databases and generated modules
are themselves reference output. `scripts/check-corpora` (also part of
`scripts/check-all`) reruns every generator against the pinned references
and fails on any file that no longer matches, so a corpus cannot go stale
behind a passing replay. The viewer's two Node-recorded corpora (V8's
`JSON.parse` results and messages, WHATWG `new URL` results) are rerun the
same way, through Node 22
(`packages/petrus-viewer-server/test/record-node-corpora.mjs`). Its MCP
golden transcript needs the upstream viewer's `pnpm install`, so it is
re-recorded with the viewer suites (`--viewer`, and CI's `viewer` job)
instead. The corpora are recorded on macOS and checked on
Linux too (CI), so the comparison leaves out the two platform facts that
differ: the SQLite library version in a database's header, and EOVERFLOW's
errno and message in hamsterdan-github's HTTP corpus.

```sh
scripts/check-corpora                  # every generator (about 40 s)
scripts/check-corpora --list           # each generator and the files it writes
scripts/check-corpora --update NAME    # write NAME's regenerated files
```

## Benchmarks

```sh
scripts/bench --list            # the packages with benchmarks
scripts/bench petrus-sqlite     # rerun one package, Haskell and Python
scripts/bench                   # every package, one at a time (slow)
scripts/bench-compare petrus-sqlite 3   # interleave 3 Haskell and Python runs, tabulate
scripts/bench-run petrus-sqlite --stdev 5 +RTS -M2G -RTS   # one package's benchmark, with options
scripts/bench-gate petrus-sqlite        # its gated rows against Python (CI's gate, on request)
```

Each package's `bench/RESULTS.md` holds its committed figures, how they were
taken, and a rerun block under a `<!-- scripts/bench: rerun -->` marker.
`scripts/bench PKG` runs exactly that block from the repository root. It runs
under `scripts/with-postgres` when the block needs PostgreSQL. Its output goes
to the terminal and to `bench-results/tmp/PKG.log`. It never rewrites a
results file: those are curated by hand from runs like these, with the
machine, the load and the date of the run they report.

The rerun blocks run the Haskell side with `scripts/bench-run PKG OPTIONS`,
not `cabal bench PKG --benchmark-options=...`: cabal records benchmark
options in the package's configuration, so each new set of options
reconfigured and relinked the package and its local dependencies.
`scripts/bench-run` builds the benchmark (`cabal build`, a no-op when it is
current), finds the executable with `cabal list-bin` and runs it in the
package directory with the environment `cabal bench` sets, passing the
options through; `--no-build` skips the build.

Rows whose cost grows with every iteration (each one adds rows to a
database, as petrus-sqlite's and petrus-postgres's `tx` rows do), and
server-bound rows whose tasty-bench mean swung with the machine
(petrus-postgres's `fence` and `notify` rows), are timed with the twins' own
protocol instead of tasty-bench's, so that both sides run the same number of
iterations: `twin` from `Petrus.TestSupport.BenchTwin` runs one warm-up call,
then 10 batches (`PETRUS_BENCH_BATCHES`) of a fixed number of calls, and
reports the median per call, as `scripts/bench_timing.py`'s `report(name, fn,
number)` does with the same number. Such a row prints `twin NAME
NANOSECONDS`, which `scripts/bench-compare` and `scripts/bench-gate` read
(tasty-bench's CSV leaves it out).

`scripts/bench-compare` alternates a package's benchmark and its twin for a
number of repetitions, recording the load average, and tabulates each row's
median and ratio. It reads the twin's rows from what it prints
(`name,nanoseconds` lines, or `NAME VALUE UNIT` lines) and matches them to
the Haskell rows by name (the same name, or the Haskell name ending in the
twin's, comparing `/`, `.` and spaces alike); `--map HASKELL=TWIN` names a
pair it does not find. By default the twin is `bench/python_bench.py`;
`--twin COMMAND` runs any shell command from the repository root instead,
such as the Python line of the package's rerun block, and `--haskell-arg`
passes one more option to the benchmark (`-j1`). `--python SCRIPT` picks another twin in the package's
`bench/` directory (for example `python_pi.py`), `--upstream PROJECT` runs the
twins in another pinned project's environment (`hamsterdan` for
`hamsterdan-host`), `--pattern P` limits the Haskell side to the rows that
tasty-bench's `-p P` selects, and `--stdev PERCENT` sets tasty-bench's target
deviation. It builds the benchmark once and runs its executable directly in
each repetition (in the package directory, with the environment variables
`cabal bench` would set), as the Python twins run, because a benchmark started
by `cabal bench` measured about 1% slower on syscall-bound rows:

```sh
scripts/bench-compare petrus-agenticus-runtime 5 --python python_pi.py --pattern '/pi-/' --stdev 3
mkdir -p bench-results/tmp/htmp   # a private TMPDIR for its fixed scratch directory
TMPDIR="$PWD/bench-results/tmp/htmp" scripts/bench-compare hamsterdan-host 5 --upstream hamsterdan
```

Benchmarks are noisy on a shared machine. Run them one
package at a time, on an otherwise idle machine, and compare interleaved runs
rather than runs taken minutes apart.

`bench-results/summary.md` lists every package's results file with its
slowest and fastest row against Python, and flags every row where Haskell is
slower. It is generated from the results files:

```sh
scripts/bench --summary         # rewrite bench-results/summary.md
```

### The benchmarks' runtime options

Every benchmark runs with the GHC runtime's defaults (a 4 MB allocation
area), as the executables that run the measured code do: `hamsterdan-host`,
`hamsterdan-operator`, `hamsterdan-export` and the others set no `-A` (the
viewer's binaries state `-A4m`, its measured choice). Nineteen benchmarks
used to set `-with-rtsopts=-A32m`. On 2026-10-12 each of them ran twice
with `+RTS -A32m` and twice with `-A4m`, alternating (Apple M4, load
1.8–3.5); the geometric mean over a package's rows of the time with
`-A32m` over the time with `-A4m`, and the rows the default was faster on:

| Package | `-A32m` / `-A4m` | default faster |
| --- | ---: | ---: |
| petrus-cel | 1.23 | 21 of 21 |
| petrus-engine | 1.16 | 5 of 5 |
| petrus-telemetry-instrumentation | 1.15 | 16 of 16 |
| petrus-engine-postgres | 1.15 | 5 of 5 |
| petrus-fabric | 1.13 | 7 of 8 |
| petrus-processes | 1.12 | 11 of 12 |
| petrus-motus | 1.12 | 11 of 11 |
| petrus-agenticus-runtime | 1.10 | 22 of 26 |
| petrus-agenticus | 1.10 | 4 of 5 |
| petrus-agenticus-core | 1.10 | 18 of 20 |
| petrus-engine-file | 1.08 | 10 of 15 |
| petrus-engine-sqlite | 1.05 | 3 of 4 |
| petrus-dsl | 1.03 | 7 of 10 |
| petrus-engine-absurd | 1.01 | 2 of 2 |
| petrus-motus-zeromq | 1.01 | 5 of 8 |
| petrus-history-postgres | 1.00 | 2 of 7 |
| petrus-motus-absurd | 0.99 | 2 of 4 |
| petrus-impetus | 0.93 | 9 of 20 |
| petrus-observation | 0.87 | 5 of 21 |

A larger allocation area helps a row that builds a large structure, since
fewer minor collections copy less of it while it is young (petrus-impetus's
History parse, petrus-observation's paging), and costs a row with a small
working set, whose new objects then land on memory that has left the cache
(the viewer measured the same, packages/petrus-viewer-server/bench/RESULTS.md).
The benchmarks measure what ships, so they now run with the defaults.
petrus-history-store had already switched (its bench/RESULTS.md), and
hamsterdan-operator's binary dropped its `-A16m` after the same kind of
measurement (its bench/RESULTS.md, "The allocation area").

### Which code the figures measured

Every results file records the code its figures measured, in a marker:

```
<!-- scripts/bench: measured sources FINGERPRINT at COMMIT -->
```

FINGERPRINT hashes, as committed (git blob ids, so content): the package's
files but its prose (`*.md`, LICENSE, NOTICE) and its tests (`test/`,
`differential/`, `upstream-tests/`); the same files of every local package
it builds on (the packages its .cabal file's stanzas other than test suites
name, transitively; their benchmarks aside); `cabal.project` and its freeze
file; the pinned `upstream/` commits; and `scripts/bench_timing.py`. COMMIT
is the commit those sources were at. `summary.md` shows each file's commit.

- `scripts/bench --check` (CI's `lint` job, every push) fails on a results
  file without the marker, and lists as `STALE` (a warning, with a GitHub
  annotation in CI) every file whose fingerprint has changed since.
  `scripts/check-parity` names, as `STALE evidence`, every component at
  parity that cites such a file.
- `scripts/bench --stale` lists those files, and exits 1 when there is one.
  Their figures may no longer hold: rerun them before relying on them.
- Refreshing a package's results: on an idle machine, from a clean commit,
  run `scripts/bench PKG` (or `scripts/bench-compare`), update the tables by
  hand, then `scripts/bench --stamp PKG` (for one of several results files,
  `scripts/bench --stamp PKG results-x.md`). That records HEAD's fingerprint
  and regenerates `summary.md`. Commit the result.
- Carrying figures forward: the fingerprint changes with any source in the
  package's dependency closure, including a change that cannot affect what
  the benchmark measures (a bounds check on a path no row runs, a doc
  comment, a provider the benchmark never uses). For such a change,
  `scripts/bench --carry PKG [results-x.md] --reason "TEXT"` keeps the
  measured marker as it is and adds, after it, a line

  ```
  <!-- scripts/bench: carried to FINGERPRINT at COMMIT: REASON -->
  ```

  with HEAD's fingerprint and commit. A carry claims exactly this: the
  change since the measurement does not touch the code paths the figures
  measured, for the reason given (required), so the figures measured at the
  older commit still stand for HEAD's sources. It is a claim for a reviewer
  to check, not a measurement. `--check` and `--stale` count the file as
  current while its latest carry matches; `summary.md` shows the measured
  commit and the commit it was carried to; `scripts/check-parity` names, as
  `CARRIED evidence`, the components citing it, with the reason. A later
  carry adds another line, so the history stays visible. A carry never
  refreshes a figure: rerunning and `--stamp` does, and removes every carry
  line.

A push reruns no benchmark. A `full` dispatch runs
`scripts/bench --smoke` (the `bench-smoke` job), which builds every
benchmark and runs it once: each tasty-bench row measured once (`--stdev
Infinity`), or, for the custom harnesses, the sh block after a `<!--
scripts/bench: smoke -->` marker in the package's RESULTS.md. So a benchmark
cannot silently stop building or running. The same job lists the stale
results files in its run summary.

A dispatch with `bench` (`gh workflow run ci.yml -f bench=true`) also runs
`scripts/bench-gate` (the `bench-gate` jobs, four shards), which measures;
no run measures on its own, since the committed figures are the record and
a gate on every run would only re-measure them. Its `ENTRIES` name, for every package with a Python twin,
the rows with the thinnest margin (and, where every margin is wide, the
headline row): 42 entries over 39 packages. Each pair of Haskell and Python
runs is repeated 5 times, alternating which side goes first; each
repetition gives a ratio of the two figures measured next to each other,
and the row's ratio is their median. The harnesses that interleave both
sides themselves (hamsterdan-export, hamsterdan-operator,
petrus-execution's `compare.py`, petrus-viewer-server's `bench/run.mjs`)
run once, and their table gives the row's ratio and how many of its runs
or rounds Haskell won. A row passes when Haskell won more than half of
them ("won k of n", 2k > n), in that one measurement: a row whose two sides
do the same server or kernel work came out on either side of 1.0× from run
to run, and a median with a rerun below 1.0× only gave the noise a second
draw. The job fails on a row that does not pass or cannot be measured. The
table goes to the run summary, the figures and the log to the
`bench-gate-N` artifacts. petrus-viewer-server's entry, whose twin is the
upstream Node backend (`bench/run.mjs` needs `pnpm build`), runs in the
`viewer` job instead of a shard. Left out: the second
harness of packages that have two, and four thin rows that are the same
kernel or server work on both sides (one `fsync`, `CREATE DATABASE` and
`DROP DATABASE`, or 256 MiB of `write(2)`), which the runner measured below
or on either side of 1.0× from run to run; their packages' next-thinnest
rows are gated instead (the `scripts/bench-gate` docstring names them and
gives the runner's figures). `scripts/bench-gate --list`
prints the rows. CI runners are not the machine the results files were measured on,
so the gate checks the direction (Haskell not slower), not the committed
ratios. Its PostgreSQL server is set up as `scripts/with-postgres` sets up
the one the results files were measured against: trust authentication over
127.0.0.1, without the GSSAPI encryption probe. Under the image's default
SCRAM-SHA-256, each connect spends about 1.8 ms of PBKDF2 inside the client
library, and the two sides link different builds of it (the runner's libpq
and OpenSSL against psycopg-binary's bundled ones), so the connect-heavy
rows measured those builds rather than the port (0.89–0.97× under SCRAM,
1.00–1.12× with trust, in the same runs).

### CPU and wall-clock time

Every Haskell benchmark measures wall-clock time, as the Python twins do
(`time.perf_counter_ns`, through `scripts/bench_timing.py`). tasty-bench
defaults to CPU time, so each `bench/Main.hs` sets `localOption WallTime`,
except petrus-agenticus-runtime's, whose rerun block passes `--time-mode wall`
instead. The custom harnesses (petrus-execution, petrus-motus-zeromq,
petrus-viewer-server) read the monotonic clock directly. CPU time leaves out
the time a process waits on the kernel, a database server or a child
process. For those benchmarks it flattered Haskell by up to several times
against a Python figure that counted the wait. The threaded runtime's CPU
time also adds up every OS thread, so it can come out above wall time too.

The figures for single-threaded workloads that do no I/O inside the timed
region (parsers, encoders, the kernel's firing) were taken before the switch,
in CPU time, and keep their tables. For them the two clocks should agree
within the run-to-run noise. Two Haskell-only spot checks in wall-clock time
on 2026-10-10 (load average 3.4–3.6) bear that out:
- petrus-cel's `filter` rows came within 10% of the committed figures
  (`filter/field` compile+evaluate 2.19 µs against 2.17 µs), or faster;
- petrus-impetus's `candidates` rows did too (wide fan-in 20.8 µs against
  23.4 µs, long FIFO 1.55 ms against 1.51 ms).

The other petrus-impetus rows checked (replay 174 ms against 237 ms, net
serialization 0.82 ms against 2.49 ms) came out faster than committed,
because library work merged since, not because of the clock. One exception
to "the clocks agree" turned up: petrus-history-store's in-memory append read
0.360 ms in CPU time and 0.445 ms in wall-clock time; its RESULTS.md has the
details.

Every benchmark that touches a server, a file, a socket or a child process
was rerun in wall-clock time, interleaved with Python.

### Python batch size

`scripts/bench_timing.py` times each Python row in batches. It calibrates how
many calls fill a batch of `PETRUS_BENCH_BATCH_SECONDS` (default 0.2 s), then
reports the median of 10 such batches. That is about 2 s per row, comparable
to tasty-bench's runs at `--stdev 5`. The earlier 0.05 s batches were short
enough for stateful workloads (a database that grows, a cache that warms) to
drift between the calibration and the timed batches. They also left a single
scheduler hiccup a large share of a batch.

## The container image

`deployment/Containerfile` builds the Haskell image of Hamsterdan, which
keeps the reference image's runtime contract
([PARITY](../packages/hamsterdan-operator/PARITY.md#container-runtime-contract)).
`scripts/container-smoke` runs it and checks that contract at run time. It
needs Docker with Buildx, `curl`, `openssl` and `python3`:

```sh
scripts/container-smoke --build      # build hamsterdan:smoke for linux/amd64, then check it
scripts/container-smoke IMAGE        # check an image built already
```

`--build` runs `docker buildx build --load --platform linux/amd64` with the
reference's build arguments (`SOURCE_REVISION`, `SOURCE_VERSION`,
`SOURCE_CREATED`), as upstream's `deployment/release.py build` does. The
image's revision label must be `--revision` (default `git rev-parse HEAD`)
and its version label `--version` (default: the version
`deployment/python-shim` reports). A cold build compiles GHC's toolchain
and every Hackage dependency, which takes a long time and several GB of
memory. Building `linux/amd64` on an arm64 machine goes through emulation
and is slower still.

The script runs every check even after one fails, prints `ok` or `FAIL` for
each, and exits 1 if any failed. It removes every container, network,
volume and temporary file it creates. No credential is real: the GitHub App
key is the repository's test key (`packages/hamsterdan-github/test/corpus`),
GitHub is a local fake (`scripts/container-smoke.d/fake-github.py`) served
over TLS as `api.github.com` from a CA the run generates, and `op` is a
local fake (`scripts/container-smoke.d/fake-op`). The checks:

- **Image configuration**, as `release.py verify` reads it: `linux/amd64`,
  the user, working directory, `ENTRYPOINT`, `CMD`, exposed port, the OCI
  labels (revision and version included), and the environment. No
  credential name appears in the image's environment or build history.
- **Filesystem**: user and group 10001 with the reference's passwd entry,
  `/var/lib/hamsterdan` at `0700` and writable, the ownership of the
  binaries, the shim, the Pi runtime and the launcher, and the launcher,
  the shim and petrus-agenticus-runtime's data files (the Pi helpers and the
  provider sidecars, in the data directory `petrus_agenticus_runtime_datadir`
  names) byte for byte the repository's.
- **Shared libraries**: `ldd` resolves every library of the three Haskell
  binaries and of the Pi runtime's `node`.
- **Pi runtime**: Node `v22.19.0`, Pi `0.83.0`, and the
  `HAMSTERDAN_PI_*` paths, as `release.py verify` and the Ansible candidate
  playbook check them.
- **The interpreter path**: the default `ENTRYPOINT` with `--help` (the
  host's usage) and with its `CMD` (the host's `serve`, which refuses the
  missing configuration with status 2), the version probe and assertion,
  an unknown module, any other invocation, and `--help` of each of the
  three modules.
- **Secrets from files**: `/opt/hamsterdan/with-runtime-secrets` runs as
  the entrypoint with the systemd unit's flags (read-only root,
  no capabilities, `no-new-privileges`, the private `/tmp`), the settings
  file the runtime playbook installs (`deployment/config/runtime.env` plus
  the Environment ID and container paths), and the token-file, `op` and
  configuration mounts. The fake `op` checks that it receives the
  Environment, the bootstrap read from the mounted token file and the
  configuration directory, and none of the scrubbed credentials. The
  application sees the Environment's values, multiline key included, and
  neither the bootstrap nor credentials planted in the container's
  environment. A missing or malformed Environment ID and a symlinked token
  file are refused.
- **`validate`**, as the runtime and configure playbooks run it, against
  `deployment/config/installations.toml`: one installation reconciled, one
  repository admitted.
- **`serve`**, as the systemd unit runs it: `GET /healthz` answers 200 with
  uvicorn's headers and a healthy, reconciled service; `/openapi.json`, an
  unknown path and an unsigned webhook delivery answer as the host does.
  PID 1 is `/opt/hamsterdan/bin/hamsterdan-host serve --host 0.0.0.0 --port
  8000` running as 10001, alone. The host made its registration calls to
  the fake over TLS, and `docker stop` ends it with status 0. A recording
  wrapper around the image's Node (`scripts/container-smoke.d/node-wrapper`,
  through `HAMSTERDAN_PI_NODE_PATH`) shows that at startup the host checked
  Node's version and ran the Pi helper's READY probe against the image's Pi
  package, that the probe answered ready (so the host selected Pi
  execution), and that neither Node process inherited a credential.

The `container` job of `.github/workflows/ci.yml` runs the same script on
every push to `main` and every pull request, after building the image on
Blacksmith's persistent Docker builder (`useblacksmith/setup-docker-builder`
and `useblacksmith/build-push-action`), which keeps the layers between runs.
The Containerfile builds every Hackage dependency in a layer keyed only on
the `.cabal` files, `cabal.project` and `cabal.project.freeze`, so a
source-only change rebuilds the local packages and nothing else. The cabal
store and the local packages' `dist-newstyle` are build cache mounts, which
the persistent builder keeps: a source change recompiles only the changed
packages and those that depend on them, and a `.cabal` change finds the
Hackage dependencies already built. A builder without that cache (a local
`scripts/container-smoke --build`) builds everything.

## Parity

```sh
scripts/check-parity
```

[PARITY.md](../PARITY.md) lists every upstream component with its status
and evidence. The script fails if a component is marked at parity without
evidence, or if a benchmark results file its evidence cites has a row where
Haskell is slower than Python. A results file shared by several components
can attribute its slower rows to components that are still in progress, with
a `<!-- parity: rows below 1.0× belong to "..." -->` marker. A row counts by
its headline ratio. Historical figures do not count: columns or headings that
say "before", and sections marked `<!-- bench: superseded -->`. Neither do
spread columns (`min`, `lowest …`, `slowest …`, `worst …`), which give a
row's worst single round. `scripts/bench_results.py` documents the rules.

## No silent skips

A test that needs the Python reference gets its interpreter from
petrus-test-support's `upstreamPythonExecutable` (or `pythonExecutable`),
usually through a package-local `withReference` helper. That provisions the
reference through `scripts/upstream-python`, and fails, rather than going
pending, when it cannot. `scripts/lint-skips` rejects the other patterns:
probing for `.venv` or `bin/python`, `pending` on a missing Python or
upstream checkout, guarding a test on whether an upstream file exists, and
`pytest.skip` or import fallbacks in the Python drivers. A line that
legitimately needs one says so with `-- lint-skips: allow <reason>`.

## Continuous integration

`.github/workflows/ci.yml` runs on every push to `main`, every pull request
and on demand (`workflow_dispatch`, with a `full` input, a `bench` input,
and a `sha` input that tests that commit instead of the branch's
tip). It runs the steps of `scripts/check-all --viewer`, plus the container
job, spread over Blacksmith runners so that they run side by side. Every
run runs every test suite; only the build is incremental (see Caches):

| CI job | Runner | `scripts/check-all` step |
| --- | --- | --- |
| `lint` | 2 vCPU | `check-pins`, `lint-skips`, `lint-hamsterdan-architecture`, `check-pending --self-test`, `bench --check`, `check-parity`, the runtime test ledgers (`parity_check.py`) |
| `build` | 16 vCPU | `cabal build all` (`-Werror`); then plans the test shards |
| `checks` | 4 vCPU | `scripts/interop --check` (with the PostgreSQL and Docker variables set, so that the selection counts those examples too); `scripts/check-corpora`, with PostgreSQL 17 |
| `test (1)` … `test (N)` | 8 vCPU | the upstream Python environments, then `cabal test` of the shard's suites, with PostgreSQL 17 (pinned by digest); then `scripts/check-pending` on their output (a suite with a pending example outside the declared opt-ins does not count as passed) |
| `viewer` | 8 vCPU | `--viewer`: what `scripts/interop --viewer petrus-viewer-server` runs (`scripts/ci-tests run-viewer`: the interop group, then every upstream petrus-viewer suite, in three groups side by side), with Node 22.19.0, pnpm 11.5.1 and Playwright's Chromium; then the MCP golden transcript re-recorded through the upstream Node MCP server; a dispatch with `bench` also `scripts/bench-gate petrus-viewer-server` |
| `bench-smoke` | 8 vCPU | a dispatch with `full` only, with PostgreSQL 17: `scripts/bench --smoke` (every benchmark builds and runs once; not a measurement) and the list of stale results files ([Which code the figures measured](#which-code-the-figures-measured)) |
| `bench-gate` (4 shards) | 8 vCPU | a dispatch with `bench` only, with PostgreSQL 17: `scripts/bench-gate --shard N/4`, the gated rows against the pinned Python, 5 interleaved repetitions, failing on a row Haskell did not win most repetitions of ([Which code the figures measured](#which-code-the-figures-measured)) |
| `container` | 16 vCPU | none (Docker): the image and `scripts/container-smoke` ([The container image](#the-container-image)) |
| `ci` | 2 vCPU | the verdict: green only when every job above is |

Every push to `main` gets a complete run of its tip, which holds every
change the push brought. An earlier commit of the same push can be
checked on its own with `gh workflow run ci.yml -f sha=<commit>` (the
`sha` input checks out, builds and tests that commit). On `main`, each run has its own concurrency group, so a
newer push neither cancels it nor replaces it while it waits. On a branch or pull request a newer push
cancels the older run. `main` has no branch protection rule: commits land on
it without waiting for CI, and the run of each commit, red or green, is what
verifies it. The `ci` job is the single verdict to require if a protection
rule is added. CI steps carry the names of
the `check-all` steps they run, and `lint` first runs
`scripts/ci-tests check-steps`, which fails when a `check-all` step (other
than the opt-in benchmarks) has no CI step of that name: a check added to
`check-all` fails CI until CI runs it too.

**Caches.** The GHC and cabal install (`~/.ghcup`) is cached by their
versions. The cabal store and package index are cached by `cabal.project`,
`cabal.project.freeze` and the `.cabal` files, falling back to the latest
entry. `dist-newstyle` is cached by commit, falling back to the latest
entry, so `build` recompiles only what changed since. That is all a run
takes from an earlier one: no test result is ever carried over. A branch or
pull request reads its own entries and those of `main`. The test jobs and
`checks` restore the `dist-newstyle` that `build` saved for the commit and
build nothing. Every job prepares the restored `dist-newstyle` the same
way, in one composite action
(`.github/actions/cabal-dist`):

- CI's test flags (`--test-show-details=direct`, the
  `scripts/ci-test-wrapper` wrapper and the `+RTS -M2G -RTS` heap cap) come
  from a `cabal.project.local` that `scripts/ci-tests configure` writes, not
  from command lines: flags that differ between commands make cabal
  reconfigure and relink every package. A `PATH` unlike the build's does
  too, so every job installs the same toolchain, Node included.
- A checkout leaves every `.cabal` file newer than the restored build, which
  the Cabal library takes as a change that forces reconfiguring, so the
  `.cabal` files get a fixed old timestamp.
- That fixed timestamp is also the one cabal-install recorded when it last
  planned the project, and cabal-install does not hash a monitored file whose
  timestamp is unchanged: on its own, the timestamp would hide an edited
  `.cabal` file (a new test suite, a dropped `build-depends`). So the action
  then deletes `dist-newstyle/cache`, the project-level plan. cabal solves
  and elaborates the plan again from the files' content and rewrites
  `dist-newstyle/cache/plan.json`. Each package's own build cache stays: a
  package whose elaborated configuration and sources are unchanged is not
  rebuilt, and one whose `.cabal` file changed is reconfigured and rebuilt.
  `scripts/ci-tests plan` also checks that the plan lists every package
  under `packages/` with exactly the test suites its `.cabal` file declares.

**Shards.** `scripts/ci-tests plan` spreads the suites over about ten
`test` jobs, balancing their measured times (`.github/ci/test-times.json`).
A suite much longer than the rest is split into parts, each a set of hspec
`--match` patterns, plus a rest part that `--skip`s all of them, so every
example runs whatever the patterns select; two parts of one
suite never share a job. `build` checks the parts against the built test
binaries (`scripts/ci-tests check-parts`, hspec dry runs): each part
selects an example, and the parts' counts add up to the suite's. A suite passes only when all its parts pass. Stale
times only unbalance the jobs.

**A build from scratch.** A dispatch with `full` restores no
`dist-newstyle` and builds every package from scratch (under a cache key of
its own, so its later jobs never restore an incremental build), and adds
the `bench-smoke` job:

```sh
gh workflow run CI --ref main -f full=true
```

When a `test` job fails on a flaky test, rerunning the failed jobs reruns
only those shards, and the `ci` verdict after them.

**Timings** (October 2026, wall clock from the first job's start to the
`ci` verdict):

| Run | Total | Notes |
| --- | --- | --- |
| Cold: no cache at all | about 10 min | GHC and cabal install 1 min, build 5.5 min, test jobs 1.5 to 2 min, container 6.5 min (side by side with the build) |
| Warm, nothing to recompile (a change outside `packages/`) | 4.0 to 4.2 min | `build` job under 1 min (`cabal build` 8 s); then, side by side, the test jobs 1.7 to 2.5 min, `checks` 1.9 to 2.1 min and `viewer` 2.9 min |
| Warm, packages recompiled | the above plus the extra build time | `cabal build` takes from seconds to 4.5 min, depending on how much recompiles, so 5 to 7.5 min in all |

Each job after `build` spends about 40 s on setup (checkout, the toolchain
and cache restores, the upstream Python environments) before its own work;
the test shards then spend 40 to 100 s in `cabal test`. The longest job is
`viewer` (the upstream petrus-viewer suites alone take about 1:45), and
`build` is on the path of every run: with nothing to recompile it is mostly
its own setup. The single-runner workflow this replaced took about 50
minutes.
