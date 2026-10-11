# Reproducing everything from a clean checkout

This page takes a fresh machine to a full rerun of what this repository
claims: the build, the test suites (unit, conformance and interop with the
pinned Python), the cross-language suites on their own, the benchmarks
against the pinned Python, and the parity table. CI runs the same
`scripts/check-all` on every push to `main` and every pull request
(`.github/workflows/ci.yml`).

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
| Node.js | 22 | the Gondolin sidecar and Pi helper suites; the petrus-viewer suites and the viewer benchmark (with pnpm) |
| Graphviz (`dot`) | any | petrus-impetus's diagram rendering tests |

On macOS with Homebrew:

```sh
brew install ghcup uv zeromq libpq sqlite node pnpm graphviz postgresql@17
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
7. `scripts/bench --check`: every package's benchmark results document how
   to rerun them, and `bench-results/summary.md` matches them.
8. `scripts/check-parity`: the parity table's claims hold.

`-j2` limits cabal's parallelism; leave it out to use every core.

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
suite. `scripts/interop` runs only them: the live interop against reference
processes over shared files, databases and sockets, the byte-for-byte
comparisons with the reference's servers and CLIs, the committed
differential corpora, and the conformance suites shared with the reference.
It is the quick check after moving a pin or touching a wire format. Each run
passes hspec's `--fail-on=empty,pending`, so a renamed group or a test that
goes pending fails it. `--viewer` needs `pnpm install` in
`upstream/petrus-viewer` (and `pnpm build` plus
`npx playwright install chromium` for its browser suites).

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
median and ratio. Benchmarks are noisy on a shared machine. Run them one
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
  the shim and petrus-agenticus-runtime's Pi helpers (in the data directory
  `petrus_agenticus_runtime_datadir` names) byte for byte the repository's.
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
every push to `main` and every pull request, after building the image with
`docker/build-push-action`. The layers come from the GitHub Actions cache.
The Containerfile builds every Hackage dependency in a layer keyed only on
the `.cabal` files, `cabal.project` and `cabal.project.freeze`, so a
source-only change rebuilds the local packages and nothing else.

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
