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
| PostgreSQL 17 (`initdb`, `pg_ctl`) **or** Docker | 17.x | the PostgreSQL suites and benchmarks |
| Node.js | 22 (CI pins 22.19.0) | the Gondolin sidecar and Pi helper suites; the petrus-viewer suites and the viewer benchmark (with pnpm) |
| pnpm | 11.5.1 | the petrus-viewer suites (`--viewer`) and the viewer benchmark |
| Graphviz (`dot`) | any | petrus-impetus's diagram rendering tests |
| bash | 4.4 or later | hamsterdan-operator's secret-launch tests (macOS ships bash 3.2). They use `$PETRUS_BASH` when it is set, else the first bash of at least 4.4 among `bash` on `PATH`, `/opt/homebrew/bin/bash` and `/usr/local/bin/bash` |

A suite whose tool is missing fails and names the tool; it does not skip.

On macOS with Homebrew:

```sh
brew install ghcup uv zeromq libpq sqlite node pnpm graphviz bash postgresql@17
ghcup install ghc 9.10.3 && ghcup set ghc 9.10.3
ghcup install cabal 3.16.1.0 && ghcup set cabal 3.16.1.0
```

On Ubuntu 24.04 (what CI uses):

```sh
sudo apt-get install -y build-essential libzmq3-dev libpq-dev libsqlite3-dev graphviz
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
curl -LsSf https://astral.sh/uv/install.sh | sh
```

plus Node.js 22 (for example from NodeSource) and either Docker or
PostgreSQL 17 from the [PGDG apt repository](https://www.postgresql.org/download/linux/ubuntu/)
(Ubuntu 24.04's own `postgresql` package is 16).

Haskell dependency versions are pinned in `cabal.project.freeze` (every
Hackage package's exact version, plus the Hackage `index-state`), so a clean
checkout builds against the same libraries CI and the committed benchmarks
used. Run `cabal update` once so the index reaches that state. To move the
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

`--recursive` checks out the four pinned upstream projects under
`upstream/` ([UPSTREAM.md](../UPSTREAM.md)). In an existing clone,
`git submodule update --init --recursive` does the same.

## Build and test

```sh
scripts/check-all -j2
```

It runs, in order, and stops at the first failing step:

1. `scripts/check-pins`: the submodules sit at the commits UPSTREAM.md pins.
2. `scripts/lint-skips`: no test goes pending, or skips, because a Python
   reference is missing (see [No silent skips](#no-silent-skips)).
3. Provisioning of the Python references (`scripts/upstream-python petrus`
   and `petrus-engine`): CPython 3.14.6 and each project's frozen `uv.lock`,
   in `upstream/<project>/.venv`.
4. `cabal build all` (every package is `-Werror`).
5. `scripts/interop --check`: every pattern `scripts/interop` uses still
   selects tests.
6. `cabal test all` under `scripts/with-postgres`, every test binary with
   `+RTS -M2G -RTS`. This includes the conformance and interop groups.
7. `scripts/check-pending`: no example went pending in step 6. A pending
   example is a test that did not run, so a missing tool (Graphviz `dot`,
   `node`) or server fails the run. The only examples that may stay pending
   are listed in the script: the Docker tests, which wait for
   `PETRUS_TEST_DOCKER=1` (CI sets it, and check-all refuses to run in CI
   without it), and the reference's own opt-in acceptance tests. Those
   acceptance tests need provider credentials or exactly installed external
   toolchains, and the reference skips them too.
8. `scripts/check-corpora`: every committed corpus is regenerated against the
   pinned references and must come out unchanged.
9. `scripts/bench --check`: every package's benchmark results document how
   to rerun them, and `bench-results/summary.md` matches them.
10. `scripts/check-parity`: the parity table's claims hold.

`-j2` limits cabal's parallelism; leave it out to use every core.
`--viewer` adds, after the tests, the upstream petrus-viewer suites against
the Haskell backend (`scripts/interop --viewer petrus-viewer-server`, below);
they need Node 22, pnpm, `pnpm install --frozen-lockfile && pnpm build` in
`upstream/petrus-viewer`, and `npx playwright install chromium`.

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
`npx playwright install chromium` for its browser suites).

The committed differential corpora, fixture databases and generated modules
are themselves reference output. `scripts/check-corpora` (also part of
`scripts/check-all`) reruns every generator against the pinned references
and fails on any file that no longer matches, so a corpus cannot go stale
behind a passing replay. The corpora are recorded on macOS and checked on
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
```

Each package's `bench/RESULTS.md` holds its committed figures, how they were
taken, and a rerun block under a `<!-- scripts/bench: rerun -->` marker.
`scripts/bench PKG` runs exactly that block from the repository root. It runs
under `scripts/with-postgres` when the block needs PostgreSQL. Its output goes
to the terminal and to `bench-results/tmp/PKG.log`. It never rewrites a
results file: those are curated by hand from runs like these, with the
machine, the load and the date of the run they report.

`scripts/bench-compare` serves the packages whose `bench/python_bench.py`
names its rows like the Haskell benchmarks. It alternates the two sides for a
number of repetitions, recording the load average, and tabulates each row's
median and ratio. `--python SCRIPT` picks another twin in the package's
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

`.github/workflows/ci.yml` runs on every push to `main`, every pull request,
nightly (04:17 UTC) and on demand (`workflow_dispatch`, with a `full`
input). It runs the steps of `scripts/check-all --viewer`, plus the container
job, spread over Blacksmith runners so that they run side by side:

| CI job | Runner | `scripts/check-all` step |
| --- | --- | --- |
| `lint` | 2 vCPU | `check-pins`, `lint-skips`, `lint-hamsterdan-architecture`, `bench --check`, `check-parity`, the runtime test ledgers (`parity_check.py`) |
| `build` | 16 vCPU | `cabal build all` (`-Werror`); then plans the test shards |
| `checks` | 4 vCPU | `scripts/interop --check` (with the PostgreSQL and Docker variables set, so that the selection counts those examples too); `scripts/check-corpora`, with PostgreSQL 17 |
| `test (1)` … `test (N)` | 8 vCPU | the upstream Python environments, then `cabal test` of the shard's suites, with PostgreSQL 17 (pinned by digest); then `scripts/check-pending` on their output (a suite with a pending example outside the declared opt-ins does not count as passed) |
| `viewer` | 8 vCPU | `--viewer`: what `scripts/interop --viewer petrus-viewer-server` runs (`scripts/ci-tests run-viewer`: the interop group, then every upstream petrus-viewer suite, in three groups side by side), with Node 22.19.0, pnpm 11.5.1 and Playwright's Chromium |
| `container` | 16 vCPU | none (Docker): the image and `scripts/container-smoke` ([The container image](#the-container-image)) |
| `ci` | 2 vCPU | the verdict: green only when every job above is |

Branch protection needs only the `ci` check. CI steps carry the names of
the `check-all` steps they run, and `lint` first runs
`scripts/ci-tests check-steps`, which fails when a `check-all` step (other
than the opt-in benchmarks) has no CI step of that name: a check added to
`check-all` fails CI until CI runs it too.

**Caches.** The GHC and cabal install (`~/.ghcup`) is cached by their
versions. The cabal store and package index are cached by `cabal.project`,
`cabal.project.freeze` and the `.cabal` files, falling back to the latest
entry. `dist-newstyle` is cached by commit, falling back to the latest
entry, so `build` recompiles only what changed since: cabal decides that
from the sources' content, not from timestamps. A branch or pull request
reads its own entries and those of `main`. The test jobs and `checks`
restore the `dist-newstyle` that `build` saved for the commit and build
nothing. Three things would make cabal reconfigure (and relink) anyway, and
every job avoids them: test flags that differ between commands (so CI's
test flags, `--test-show-details=direct`, the `scripts/ci-test-wrapper`
wrapper and the `+RTS -M2G -RTS` heap cap, come from a `cabal.project.local`
that `scripts/ci-tests configure` writes in every job, not from command
lines); a `PATH` unlike the build's (so every job installs the same
toolchain, Node included); and `.cabal` files newer than the restored
configuration (Cabal's own check, which a fresh checkout always trips; the
jobs set the `.cabal` files' timestamps back after checkout, and
cabal-install still notices a changed `.cabal` file by its content).

**Shards.** `scripts/ci-tests plan` spreads the suites over about ten
`test` jobs, balancing their measured times (`.github/ci/test-times.json`).
A suite much longer than the rest is split into parts, each a set of hspec
`--match` patterns, plus a rest part that `--skip`s all of them, so every
example runs whatever the patterns select; two parts of one
suite never share a job. `build` checks the parts against the built test
binaries (`scripts/ci-tests check-parts`, hspec dry runs): each part
selects an example, and the parts' counts add up to the suite's. A suite passes only when all its parts pass. Stale
times only unbalance the jobs.

**Reusing results.** Each run's `ci` job uploads a test ledger: for every
suite known green at that commit, its input hash and the run where it
passed. `build` reads the ledgers of the latest runs on the same branch and
on `main`, and a suite is not run again when its input hash equals one in
those ledgers. The hash covers, as committed: every file of the suite's
package, of every local package it depends on (any component, transitively,
from cabal's plan) and of every local package its files name; every file
outside `packages/` (the cabal project and freeze file, `scripts/`, the
submodule pins, `spec/`, `deployment/`, `.github/`, ...) except README.md,
PARITY.md, SCOPE.md, `docs/` and `bench-results/`; and the toolchain and
runner image (GHC, cabal, uv, Node, Python and Docker versions, the system
libraries). `scripts/ci-tests inputs` prints each suite's hash and the
packages it covers. The `build` log and the run summary list every reused
suite with the run it comes from. The nightly run and a dispatch with `full`
reuse nothing and run every suite:

```sh
gh workflow run CI --ref main -f full=true
```

When a `test` job fails on a flaky test, rerunning the failed jobs reruns
only those shards; the ledger counts a part as passed when an attempt of the
run passed it.

**Timings** (October 2026, wall clock from the first job's start to the
`ci` verdict):

| Run | Total | Notes |
| --- | --- | --- |
| Cold: no cache at all, every suite | about 10 min | GHC and cabal install 1 min, build 5.5 min, test jobs 1.5 to 2 min, container 6.5 min (side by side with the build) |
| Warm, every suite (a change outside `packages/`) | about 4 min | build job 1 min, test jobs 1.5 to 2 min, `viewer` 2.5 min |
| Warm, a change to a package many suites depend on | 4 to 5.5 min | build 1 to 3 min, depending on how much recompiles |
| Warm, a change to a leaf package | about 3 to 4 min | its suites only |

The single-runner workflow this replaced took about 50 minutes. Within a
warm run, the longest jobs are `viewer` (the upstream petrus-viewer suites,
about 1:45) and the shards holding parts of `hamsterdan-testing` (its
World runs).
