# hamsterdan-operator parity

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
| `src/hamsterdan/operator.py`: the demo commands (`preflight`, `create`, `prepare_broker`, `inspect`, `inspect_authority`) and their helpers | `Hamsterdan.Operator` | `OperatorSpec` and `DifferentialSpec` |
| `operator.py`: `qualification_setup`, `_consume_private_file`, `_parse_setup_refs`, `_setup_subprocess` | `Hamsterdan.Operator` | `OperatorSpec`, `QualificationSetupLocalSpec` and `DifferentialSpec` |
| `operator.py`: `parser` and `main` (argparse, the JSON report, exit statuses) | `Hamsterdan.Operator.runOperator`, `app/Main.hs` (`hamsterdan-operator`), petrus-argparse's `Petrus.Argparse` | `OperatorSpec` and `DifferentialSpec`, which runs the binary |
| `src/hamsterdan/host/publication_qualification.py`: the publication assertions, the agent result and cleanup fences, `AtomicSetupPush`, the setup qualification sequence and its sanitized evidence | `Hamsterdan.Host.PublicationQualification` | `PublicationQualificationSpec`, `TypeGuaranteeSpec` and `QualificationSetupLocalSpec` |
| The CPython calls these make: `os.open`/`fstat`/`lstat`/`stat(dir_fd=..., follow_symlinks=False)`, `os.path.abspath`/`normpath`, `pathlib` parents and names, `shutil.which`, `shutil.rmtree`, `tempfile`, `json.loads` | `Hamsterdan.Operator.Posix` and petrus-posix (`Petrus.Posix.At`: the `stat` calls and `rmtree`; `Petrus.Posix.Path`: `confstrPath`, `normpath`, `purePathParent`), `Hamsterdan.Operator.Python` (`json.loads` is petrus-json's `loadsText`) | the suites above; petrus-posix's `rmtree` and `confstr` examples against CPython; petrus-json's `InPlaceSpec` for `json.loads` |
| `deployment/Containerfile`, `.dockerignore`, `deployment/config`, `deployment/pi`, `scripts/with-runtime-secrets` | the files of the same names at the repository root, plus `deployment/python-shim` and `cabal.project.freeze` | `ContainerSpec` and `SecretLaunchSpec`; see "Container runtime contract" below |

The package reuses:

- hamsterdan-contracts' `Hamsterdan.Python.Object` (the dynamic Python value
  model the exporter shares: `json.loads`, `json.dumps(sort_keys=True)`, the
  exception lines) and `Hamsterdan.Python.*` (`str` built-ins, `hashlib`,
  `urllib.parse.quote`);
- petrus-argparse (`argparse`);
- hamsterdan-contracts (`ChangeResult` and the readiness vocabulary);
- hamsterdan-host (`Hamsterdan.Host.GitPublish`'s publication categories, and
  the `hamsterdan-host` binary that the shim tests run);
- petrus-json and petrus-engine-file.

The test suite also uses hamsterdan-github (`derivePolicy` for the authority
inspection, and `Hamsterdan.GitHub.Config` for the launcher's child).

## Upstream tests

- **Cases:** collected pytest items, so each parametrization counts.
- **Examples:** hspec examples. A parametrized test is one `describe`
  named after the test, with one example per parameter.

| Upstream file | Functions | Cases | Haskell spec |
| --- | ---: | ---: | --- |
| `tests/unit/test_operator.py` | 32 | 57 | `OperatorSpec` |
| `tests/unit/host/test_publication_qualification.py` | 26 | 52 | `PublicationQualificationSpec` (46 cases), `TypeGuaranteeSpec` (6 cases) |
| `tests/unit/host/test_secret_launch.py` | 5 | 10 | `SecretLaunchSpec` |
| `tests/integration/host/test_qualification_setup_local.py` | 7 | 7 | `QualificationSetupLocalSpec` |
| `deployment/tests/test_container_contract.py` | 4 | 4 | `ContainerSpec` |
| **Total ported** | **74** | **130** | |

Each test keeps its upstream name. The fixtures are ported in
`test/Support.hs` (the reference's `FakeRunner`, `completed()` and Python
object literals) and `test/Fakes.hs` (the fake `op` CLI and the
application child of `test_secret_launch.py`, run as modes of the test
binary).

- **Type-enforced cases (6).** `TypeGuaranteeSpec` holds the cases whose
  inputs the port's types cannot express: the four parametrizations of
  `test_falsy_nonstring_categories_cannot_bypass_the_closed_vocabulary`
  (`None`, `0`, `False` and `[]` as a category),
  `test_atomic_setup_rejects_string_subclasses_before_formatting_or_spending`
  (a `str` subclass), and the `"yes"` observer of
  `test_setup_observation_requires_strict_confirmation_without_retaining_diagnostics`.
  It also covers the ill-typed halves of three tests whose other halves are
  in `PublicationQualificationSpec` (a schema assertion returning
  `"passed"`, `ok = "true"`, a setup runner returning `True`). The module
  compiles with deferred type errors, and each example passes only when
  the ill-typed value raises a `TypeError` where a typed slot receives it.
  DIVERGENCES.md, item 2.
- **`test_secret_launch.py` and bash.** Nine of the ten cases run the
  launcher with no extra arguments, which expands an empty array under
  `set -u`; bash older than 4.4 refuses that, and the reference test fails
  the same way there. Those nine run the launcher under a bash of at least
  4.4: `$PETRUS_BASH` when set, else the first such bash among `bash` on
  `PATH`, `/opt/homebrew/bin/bash` and `/usr/local/bin/bash`. When there is
  none (a stock macOS has only `/bin/bash` 3.2) they fail and say how to
  provide one (docs/reproducing.md). The tenth runs through the script's own
  `#!/usr/bin/env bash`. CI (Ubuntu, bash 5) and the image (Debian bookworm,
  bash 5.2) run all ten.
- **The fake `op` runs the command instead of exec'ing it.** The
  reference's fake `op` ends with `os.execvpe`. The port's fake is a mode
  of the threaded test binary, and an exec from the threaded RTS fails at
  random: while one thread is in `execve`, Linux refuses to create another
  thread of the same process (`EAGAIN` from `copy_fs`), and when the RTS
  happens to be starting a worker at that moment it exits with "failed to
  create OS thread: Resource temporarily unavailable". On a CI runner with
  every CPU busy, a third of the `test_secret_launch.py` runs failed that
  way. The fake now runs the command as a child with inherited standard
  streams and exits with its status, as the real `op run` does; the
  launcher, the environment the command receives and everything the cases
  observe are unchanged.
- **The launcher's child.** `test_secret_launch.py`'s child is a Python
  program that calls `HostConfig.from_environment` and
  `PiA2InstallationConfig.from_environment`. The port's child is a mode of
  the test binary. It reads the host configuration with hamsterdan-github's
  `Hamsterdan.GitHub.Config.fromEnvironment` and the Pi installation config
  with hamsterdan-agents' `Hamsterdan.Host.PiA2.installationFromEnvironment`
  (`PiA2InstallationConfig.from_environment`), and asserts the same values
  upstream's child does.
- **`test_public_petrus_revision_is_exact_and_locked`** checks the
  reference's `pyproject.toml` pin and `uv.lock`. This repository has
  neither. The port checks the equivalent: the Haskell dependency plan is
  frozen (`cabal.project.freeze` has an `index-state`, pins the
  network, SQLite, crypto, process and text libraries, and pins no local
  package).

## Suites with no upstream counterpart

Besides the ported examples, the suite has `DifferentialSpec` (below) and
`ContainerSpec`'s shim and Containerfile checks. The six-tree `shutil.rmtree`
comparison moved to petrus-posix's suite with the walk itself.

## Differential suite

`DifferentialSpec` runs 134 command lines through both
`python -I -B -m hamsterdan.operator` and the `hamsterdan-operator` binary.
Each side runs in its own directory, with `PATH` starting with scripted
fakes of `gh`, `git`, `curl` and `python` (modes of the test binary that log
every call), `TMPDIR` inside the directory and the same `COLUMNS`. Each case
must give:

- the same exit status;
- the same stdout;
- the same stderr (for an exception the reference does not catch, the last
  traceback line, DIVERGENCES.md item 1);
- the same external commands, argument vector and working directory, in
  order;
- the same files left behind, path, mode and bytes.

Before comparing, it replaces each side's own root, temporary-directory
suffixes and UTC time stamps with placeholders. The suite collects every
mismatch before failing, and a 135th example checks that every subcommand
has cases. The cases:

- **Argument parsing (25):** help at several widths and under
  `FORCE_COLOR` / `NO_COLOR`, every parser error (undecodable arguments
  among them), each subcommand's help.
- **`preflight` (16):** legacy, App and delegated brokers, missing
  authentication, missing or malformed provider answers, wrong
  repositories and workflows, healthy, malformed, unreachable, empty and
  undecodable health URLs.
- **`create` (17):** each scenario, clone and pull request failures,
  malformed admission files, unexpected, empty and mismatched changes,
  lone surrogates in a pull request answer (printed, and passed to a
  subprocess).
- **`prepare-broker` (11):** a prepared pull request (and one lacking its
  number), current, legacy, malformed, missing and non-UTF-8 brokers, an
  unrecognized validator, a failed or malformed search and a failed push.
- **`inspect` (19):** fresh and legacy evidence, foreign, case-folded and
  undecodable bot logins, the hero review, inline comments and findings batches,
  non-positive pull requests, and each malformed provider answer.
- **`inspect-authority` (25):** each of the eight expectations, then
  malformed pull requests, rules, reviewers, reviews, threads and
  comparisons, a moving head and further pages.
- **`qualification-setup` (21):** the success path, then every
  preparation refusal (relative or repeated paths, missing,
  group-readable or malformed inputs, a marker parent that is not private)
  and every phase failure (fixture, identity, target, push, readback,
  pull request, malformed revision, an already spent marker).

## Container runtime contract

No container runtime may run on the development machine, so the image is
built and run in CI: the `container` job of
[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml), on every push
to `main` and every pull request, builds `deployment/Containerfile` for
`linux/amd64` and runs [`scripts/container-smoke`](../../scripts/container-smoke)
against it (see "The image at run time" below). Before that, `ContainerSpec`
checks the image's definition against the reference's:

- **Byte-identical inputs.** `ContainerSpec` checks that
  `scripts/with-runtime-secrets`, `deployment/config/installations.toml`,
  `deployment/config/runtime.env`, `deployment/pi/package.json` and
  `deployment/pi/package-lock.json` are the reference's files, byte for
  byte, and that the launcher is executable.
- **The Containerfile keeps the reference's runtime stage.** `ContainerSpec`
  checks:
  - the same `# syntax` line, the same Pi stage (Node base image, digest,
    `npm ci`), and the same runtime base image and digest;
  - every instruction of the reference's runtime stage, in order, except
    the two that install the application:
    - the `.venv` `COPY` is replaced by the binaries' `COPY`, the shim's
      `COPY`, and the `COPY` of petrus-agenticus-runtime's `data/`
      (exactly its `data-files`) with the `ENV` that points the binaries at
      them (DIVERGENCES.md, "The Pi helpers");
    - the `RUN` runs the same commands, and its package list is a superset
      that adds exactly `libffi8`, `libgmp10` and `zlib1g`, the shared
      libraries GHC's binaries link, and `libbz2-1.0` and `liblzma5`, which
      read bzip2 and xz workspace archives as the reference's `tarfile`
      does.
  - This keeps the labels, the user and group 10001, `/var/lib/hamsterdan`
    at `0700`, the environment, `USER`, `EXPOSE 8000`, `ENTRYPOINT` and
    `CMD`.
- **The reference's container tests**, adapted as described above:
  - the build context admits only the declared inputs, and every `COPY`
    source is one of them;
  - every `FROM` is pinned by digest, with no build credentials;
  - the dependency plan is frozen;
  - the Pi runtime is locked.
- **The interpreter-path shim.** `deployment/python-shim` is installed at
  `/opt/hamsterdan/.venv/bin/python`, the path the `ENTRYPOINT`, the
  systemd unit, the Ansible validation runs and the release checks invoke.
  `ContainerSpec` lays out the image's `/opt/hamsterdan` (`bin/` with the
  three binaries, the shim at `.venv/bin/python`). It then checks that the
  shim answers like the reference interpreter for each invocation the
  tooling makes:
  - the version probe and the version assertion (matching and not);
  - an unknown module;
  - `-m hamsterdan.host`, `-m hamsterdan.operator` and
    `-m hamsterdan.host.export`, each with `--help` and with an unknown
    option, compared with the reference's output and exit status.
  - It also checks that the shim refuses any other invocation with status
    2.
- **Linked libraries.** `otool -L` on the three binaries built here lists
  only system libraries (`libSystem`, `libz`, `libiconv`, `libffi`,
  `libcharset`, the Security framework). In the image, `ldd` shows they
  link `libm`, `libz`, `libgmp` and `libc` (below).
- **Lint.** The CI job runs `shellcheck` on the launcher, the shim (as
  POSIX `sh`) and the smoke scripts, and `hadolint` v2.12.0 on the
  Containerfile with `--failure-threshold error`.

### The image at run time

`scripts/container-smoke IMAGE` (or `--build`, which builds the image
first) checks, against the built image, what the reference's
`deployment/release.py verify`, Ansible candidate and runtime playbooks,
systemd unit (`hamsterdan.service.j2`) and deployment README expect of it.
[docs/reproducing.md](../../docs/reproducing.md#the-container-image)
lists every check; in short:

- **Image configuration:** `linux/amd64`, user `hamsterdan`, working
  directory, `ENTRYPOINT`, `CMD`, `EXPOSE 8000`, the OCI labels (revision
  and version equal to the build arguments), the reference's environment.
  No credential appears in the image's environment or build history.
- **Filesystem:** uid and gid 10001 with the reference's passwd entry,
  `/var/lib/hamsterdan` at `0700`, owned by `hamsterdan` and writable;
  the ownership of the binaries, shim, Pi runtime and launcher; the
  launcher, the shim and the runtime data files byte for byte the repository's.
- **Shared libraries:** `ldd` resolves every library of `hamsterdan-host`,
  `hamsterdan-operator`, `hamsterdan-export` (`libm`, `libz`, `libgmp`,
  `libc`) and of the Pi runtime's `node`.
- **Pi runtime:** Node `v22.19.0` and Pi `0.83.0` at the reference's paths,
  and the `HAMSTERDAN_PI_*` paths exist.
- **The interpreter path:** the default `ENTRYPOINT` answers `--help` with
  the host's usage, and with its default `CMD` starts the host's `serve`,
  which refuses the missing configuration as the host does. The version
  probe, the version assertion (matching and not), an unknown module, any
  other invocation and each module's `--help` answer as `ContainerSpec`
  checks against the reference interpreter.
- **Secrets from files:** the launcher runs as the entrypoint with the
  systemd unit's flags (read-only root, no capabilities,
  `no-new-privileges`, the private `/tmp` tmpfs), the settings file the
  runtime playbook installs, and the token-file, `op` and configuration
  mounts at the unit's paths. A fake `op` (`scripts/container-smoke.d/fake-op`)
  checks it gets the Environment, the bootstrap from the mounted token
  file, `--config /tmp/hamsterdan-op` (which it creates on the tmpfs) and
  none of the scrubbed credential families. The application sees the
  Environment's values (the multiline key intact) and neither the
  bootstrap nor credentials planted in the container's environment. No
  Environment, a malformed Environment ID and a symlinked token file are
  refused, under bookworm's bash 5.2.
- **`validate`**, as the runtime and configure playbooks run it, with
  `deployment/config/installations.toml` mounted at
  `/run/config/hamsterdan`: against a fake GitHub served over TLS as
  `api.github.com` (`scripts/container-smoke.d/fake-github.py`), it
  reconciles 1 installation and admits 1 repository, the values the
  playbooks assert.
- **`serve`**, as the systemd unit runs it: `GET /healthz` is
  `HTTP/1.1 200 OK` with uvicorn's `server` header and a healthy service
  whose configured installation is reconciled; `/openapi.json` answers
  200, an unknown path `404 {"detail":"Not Found"}`, an unsigned webhook
  delivery 400. PID 1 is `hamsterdan-host serve --host 0.0.0.0 --port
  8000` as uid 10001 (the launcher, `op`, `env` and the shim each exec
  into the next), and nothing else runs. Through a recording Node wrapper
  (`HAMSTERDAN_PI_NODE_PATH`), the host is seen checking Node's version
  and running the Pi helper's READY probe, which answers
  `{"type":"probe","ok":true}`, so the host selects Pi execution; neither
  Node process inherits a credential. `docker stop` ends the host with
  status 0.

The first green run is
[38117536511](https://github.com/seasonedcc/petrus-haskell/actions/runs/38117536511)
(a cold build and every check took 23 minutes in an earlier run; with the
Hackage layer cached, a source change takes about 10 minutes and a
documentation-only change under 3). The first image CI built failed the
Pi probe check: the binaries looked
for the Pi helpers at the build stage's source path. The image now ships
them (DIVERGENCES.md, "The Pi helpers").

What this does not cover: an agent turn against a real model provider,
real GitHub, and the real 1Password CLI; the smoke run replaces each with a
local fake. GitHub-facing behaviour and the launcher's contract with `op`
are checked against the reference by `DifferentialSpec`, hamsterdan-host's
suites and `SecretLaunchSpec`.

## Benchmarks

[bench/RESULTS.md](bench/RESULTS.md) times both sides by wall clock:
three fresh-process CLI rows and four in-process rows. The Haskell side
is faster on every row. The `qualification-setup` row is the closest to
level: almost all of its time is in the kernel (directory, file and `fsync`
system calls that both sides make one for one), so its ratio moves with the
machine's load. RESULTS.md gives the figures, the spread over repeated runs
and the system-call counts behind it.
