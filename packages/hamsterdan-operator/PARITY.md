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
| `operator.py`: `parser` and `main` (argparse, the JSON report, exit statuses) | `Hamsterdan.Operator.runOperator`, `app/Main.hs` (`hamsterdan-operator`), hamsterdan-cli's `Hamsterdan.Cli.Argparse` | `OperatorSpec` and `DifferentialSpec`, which runs the binary |
| `src/hamsterdan/host/publication_qualification.py`: the publication assertions, the agent result and cleanup fences, `AtomicSetupPush`, the setup qualification sequence and its sanitized evidence | `Hamsterdan.Host.PublicationQualification` | `PublicationQualificationSpec`, `TypeGuaranteeSpec` and `QualificationSetupLocalSpec` |
| The CPython calls these make: `os.open`/`fstat`/`lstat`/`stat(dir_fd=..., follow_symlinks=False)`, `os.path.abspath`/`normpath`, `pathlib` parents and names, `shutil.which`, `shutil.rmtree`, `tempfile`, `json.loads` | `Hamsterdan.Operator.Posix` (with `cbits/stat.c` and `cbits/rmtree.c`), `Hamsterdan.Operator.Python`, `Hamsterdan.Operator.FastJson` | the suites above, `FastJsonSpec` and `RmtreeSpec` against CPython |
| `deployment/Containerfile`, `.dockerignore`, `deployment/config`, `deployment/pi`, `scripts/with-runtime-secrets` | the files of the same names at the repository root, plus `deployment/python-shim` and `cabal.project.freeze` | `ContainerSpec` and `SecretLaunchSpec`; see "Container runtime contract" below |

The package reuses:

- hamsterdan-export (`Hamsterdan.Export.Python`, the dynamic Python value
  model: `json.loads`, `json.dumps(sort_keys=True)`, the exception lines);
- hamsterdan-cli (`argparse`);
- hamsterdan-contracts (`ChangeResult` and the readiness vocabulary);
- hamsterdan-github (`Hamsterdan.GitHub.Python`'s `str` built-ins,
  `derivePolicy` for the authority inspection, and
  `Hamsterdan.GitHub.Config` for the launcher's child);
- hamsterdan-host (`pySplitlines`, and the `hamsterdan-host` binary that the
  shim tests run);
- petrus-json and crypton (SHA-256).

## Upstream tests

- **Cases:** collected pytest items, so each parametrization counts.
- **Examples:** hspec examples. A parametrized test is one `describe`
  named after the test, with one example per parameter.

| Upstream file | Functions | Cases | Haskell spec | Examples |
| --- | ---: | ---: | --- | ---: |
| `tests/unit/test_operator.py` | 32 | 57 | `OperatorSpec` | 57 |
| `tests/unit/host/test_publication_qualification.py` | 26 | 52 | `PublicationQualificationSpec` (46), `TypeGuaranteeSpec` (6 cases, 9 examples) | 55 |
| `tests/unit/host/test_secret_launch.py` | 5 | 10 | `SecretLaunchSpec` | 10 |
| `tests/integration/host/test_qualification_setup_local.py` | 7 | 7 | `QualificationSetupLocalSpec` | 7 |
| `deployment/tests/test_container_contract.py` | 4 | 4 | `ContainerSpec` | 4 |
| **Total ported** | **74** | **130** | | **133** |

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
  `set -u`; bash older than 4.4 refuses that. On such a bash (macOS's
  `/bin/bash` 3.2) those nine are pending with that reason, and the
  reference test fails the same way there. CI (Ubuntu, bash 5) and the image
  (Debian bookworm, bash 5.2) run all ten.
- **The launcher's child.** `test_secret_launch.py`'s child is a Python
  program that calls `HostConfig.from_environment` and
  `PiA2InstallationConfig.from_environment`. The port's child is a mode of
  the test binary. It reads the host configuration with hamsterdan-github's
  `Hamsterdan.GitHub.Config.fromEnvironment`, and checks the variables
  `PiA2InstallationConfig.from_environment` reads directly, because the Pi
  installation config belongs to hamsterdan-agents, which is not ported
  yet.
- **`test_public_petrus_revision_is_exact_and_locked`** checks the
  reference's `pyproject.toml` pin and `uv.lock`. This repository has
  neither. The port checks the equivalent: the Haskell dependency plan is
  frozen (`cabal.project.freeze` has an `index-state`, pins the
  network, SQLite, crypto, process and text libraries, and pins no local
  package).

## Suites with no upstream counterpart

Besides the 133 ported examples, the suite has `DifferentialSpec` (below),
`ContainerSpec`'s shim and Containerfile checks, `FastJsonSpec` (the JSON
fast path against CPython's `json.loads`) and `RmtreeSpec` (six trees
removed by `shutil.rmtree` and by the port, with the same outcome and the
same files left).

## Differential suite

`DifferentialSpec` runs 124 command lines through both
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
mismatch before failing, and a 125th example checks that every subcommand
has cases. The cases:

- **Argument parsing (19):** help at several widths, every parser error,
  each subcommand's help.
- **`preflight` (15):** legacy, App and delegated brokers, missing
  authentication, missing or malformed provider answers, wrong
  repositories and workflows, healthy, malformed, unreachable and empty
  health URLs.
- **`create` (15):** each scenario, clone and pull request failures,
  malformed admission files, unexpected, empty and mismatched changes.
- **`prepare-broker` (11):** a prepared pull request (and one lacking its
  number), current, legacy, malformed, missing and non-UTF-8 brokers, an
  unrecognized validator, a failed or malformed search and a failed push.
- **`inspect` (18):** fresh and legacy evidence, foreign and case-folded
  bot logins, the hero review, inline comments and findings batches,
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

The image is never built here: no container runtime may run on this
machine. What stands in for a build, and exactly what it checks:

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
    - the `.venv` `COPY` is replaced by the binaries' `COPY` and the shim's
      `COPY`;
    - the `RUN` runs the same commands, and its package list is a superset
      that adds exactly `libffi8`, `libgmp10` and `zlib1g`, the shared
      libraries GHC's binaries link.
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
  `libcharset`, the Security framework). On Linux, GHC also links `libgmp`
  dynamically. The runtime stage installs `libffi8`, `libgmp10` and
  `zlib1g` for these.
- **CI.** The `container` job in `.github/workflows/ci.yml` runs
  `shellcheck` on the launcher and on the shim (as POSIX `sh`), and
  `hadolint` v2.12.0 on the Containerfile with `--failure-threshold error`.
  Neither tool ran locally. ShellCheck is the only one installed here: the
  shim is clean under it, and the launcher is the reference's file.

Not verified: that the image builds, which needs the network for `ghcup`,
`cabal update` and the frozen plan's downloads. Also not verified: that
the built image starts, serves and runs the launcher under bookworm's
bash. The status in the top-level PARITY.md says so.

## Benchmarks

[bench/RESULTS.md](bench/RESULTS.md) times both sides by wall clock:
three fresh-process CLI rows and four in-process rows. Over seven runs on
2026-10-11 (load 1.8–3.4), the Haskell side was faster on every row in
every run. The `qualification-setup` row is the closest, at 1.04× (1.01–1.05×
run by run): almost all of its time is in the kernel (directory, file and
`fsync` system calls that both sides make one for one), so its ratio moves
with the machine's load. RESULTS.md gives the spread over repeated runs and
the system-call counts behind it.
