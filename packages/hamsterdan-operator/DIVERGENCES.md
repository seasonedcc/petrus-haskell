# hamsterdan-operator divergences

The output never diverges. Given the same arguments, the same provider
answers and the same files, both sides print the same JSON object and exit
with the same status. They run the same `gh` and `git` command lines in the
same order and leave the same files behind. [PARITY.md](PARITY.md) lists
the tests that hold the port to this.

Below are the differences that remain, with their rationale.

## Observable

1. **An uncaught exception prints only its last traceback line.**
   - Where the reference raises an exception it does not catch, the binary
     prints the exception line and exits 1. Examples are an
     `AttributeError` for a list where a dict belongs, or a
     `json.decoder.JSONDecodeError` from a provider answer the reference
     reads without a guard.
   - The reference prints the whole traceback, which ends in that same
     line, and also exits 1.
   - The bounded failures (`{"command": ..., "ok": false, "error": ...}`,
     exit 1) and argparse errors (exit 2) are identical.
   - One exception has no reference text: an operating-system error the
     reference would not catch either, other than a failed spawn (which
     prints `FileNotFoundError`/`PermissionError` like the reference). For
     example, the disk filling while `create` writes a scenario file prints
     GHC's description of the `IOException`, not CPython's `OSError` line.
2. **Type-enforced refusals.** Some reference checks guard against values a
   dynamically typed caller could pass: a `None`, `0`, `False` or `[]`
   category, a `str` subclass as a ref, an assertion that returns
   `"passed"` instead of a `bool`, a runner that returns `True` instead of
   an exit code, an observer that returns `"yes"`. In the port these slots
   are typed (`Text`, `Bool`, `Int`), so such a call does not compile.
   `TypeGuaranteeSpec` holds each of those test inputs and checks that it is
   rejected by the type checker. Every check on values the types admit
   (empty text, an unknown category, a nonzero exit) runs at run time, as
   in the reference.
3. **Temporary directory names.** The reference names its temporary
   directories `hamsterdan-qualification-XXXXXXXX`,
   `hamsterdan-operator-XXXXXXXX` and `hamsterdan-broker-XXXXXXXX`, with
   eight random characters (`tempfile`). The port keeps the prefixes, puts
   the directories in the same place (`TMPDIR`), and creates them with the
   same owner-only mode, but the suffix comes from the `temporary` package.
   The names show up only in the command lines the operator runs (a `git
   clone` destination, for example), and they are removed afterwards. The
   differential suite replaces both suffixes with a placeholder.
4. **Help and usage text has no color.** CPython 3.14's `argparse` colors
   help on a terminal when `NO_COLOR` and `PYTHON_COLORS` allow it. The port
   writes the plain text, which is what the reference writes to a pipe. The
   width is the same: `COLUMNS`, else the terminal, else 80.
5. **Names and text that are not UTF-8, and Unicode tables: resolved, no
   longer a difference.**
   - Arguments are decoded with `surrogateescape` (petrus-json's
     `fsDecode`), and what a subprocess receives (executable, arguments,
     environment) goes through `os.fsencode`'s rule: an undecodable byte
     reaches the child as that byte, and a surrogate that is not an escaped
     byte raises `UnicodeEncodeError` before anything is spawned.
   - JSON with lone surrogate escapes keeps them in its `str` (WTF-8,
     "Petrus.Json.Wtf8"); JSON bytes in UTF-16 or UTF-32 load through
     `detect_encoding`. The result line escapes them as `json.dumps` does;
     standard error writes them with `backslashreplace`, standard output
     is strict.
   - `str.casefold()` (the bot-login comparison) and `str.isspace()` use
     petrus-json's CPython 3.14 (Unicode 16.0) tables, checked on every
     code point against the pinned interpreter.
   - The differential runs undecodable arguments (a pull request number,
     a scenario, a health URL, a bot login) and provider answers with lone
     surrogates (in the result line, and in a subprocess argument).

## Internal (no observable difference)

- **Credential bytes cannot be zeroed.** The reference overwrites its
  `bytearray` copies of the credential and the target file with zeros and
  drops `GH_TOKEN` from the child environment once the setup is done. In
  the port these are immutable `ByteString` and `Text` values: nothing
  keeps them reachable after the setup, so the garbage collector reclaims
  them, but their memory is not overwritten. The credential still never
  leaves the bounded child environment, and it never reaches the output.
- **`RuntimeError` and the other exceptions the setup sequence catches**
  are `PyError` values carrying the reference's class name. The sequence
  turns them into the same evidence categories.
- **JSON fast path.** Provider answers are parsed by
  `Hamsterdan.Operator.FastJson`, which decodes the common subset of JSON
  (no floats, no repeated keys, no surrogate escapes, at most 500 levels
  deep, integers up to 4000 digits) in place. Within that subset
  `json.loads` has exactly one result. For any other document it returns
  nothing and the reference loader
  (`Hamsterdan.Python.Object.loadsText`) decides, with CPython's values and
  errors. `FastJsonSpec` checks 3000 generated documents and the hand-made
  edge cases against both the reference loader and CPython.
- **Plain system calls.** `shutil.which` is ported directly
  (`Hamsterdan.Operator.Posix.which`: the same `PATH` walk, `CS_PATH` when
  `PATH` is unset, one `stat`, one `access(X_OK)` and the directory check).
  `Path.write_text` is one `open`/`write`/`close`. Neither goes through
  GHC's `Handle` layer or the `directory` package's permission probes.
  The cleanup's `shutil.rmtree` is CPython's descriptor-relative walk
  (`cbits/rmtree.c`: `lstat`, `open`, `fstat` to refuse a symbolic link,
  a listing through a duplicate descriptor, `unlinkat` relative to the open
  directory) rather than the `directory` package's path-based
  `removeDirectoryRecursive`. Below the top it resolves no path twice and
  follows no link, as the reference does. `RmtreeSpec` builds six trees
  (links inside, a linked top, a missing top, a file top, an entry that
  cannot be unlinked) and checks both sides' outcome and what is left.
- **The HBNetwork fixture is configuration.** The reference hard-codes
  the fixture repository, organization and repository ids, App slug, hero
  reviewer and delegated broker digests as module constants
  (`operator.py:35-87`, and `/orgs/HBNetwork` inside `preflight`). The port
  keeps them in `Operator`: a `Fixture` (`hbNetworkFixture` by default,
  the reference's values) and the two digests, from which the bot login,
  the broker authorization and `--bot-login`'s default derive. The
  `hamsterdan-operator` binary always runs the default, so nothing changes.
  Tier C (`packages/hamsterdan-e2e`, docs/e2e.md) runs
  `hamsterdan-e2e-operator FIXTURE.json`, which sets another fixture; its
  reference twin `e2e_operator.py` rebinds the same constants as a
  runtime overlay, and the e2e suite runs both against a scripted `gh`.
- **Runtime options.** The binary runs with a 16 MB allocation area
  (`-with-rtsopts=-A16m`), which removes most minor collections from a
  command's run.

## Container runtime contract

- **Binaries and a shim instead of a virtual environment.**
  - The reference image copies a Python virtual environment to
    `/opt/hamsterdan/.venv`. This image copies the `hamsterdan-host`,
    `hamsterdan-operator` and `hamsterdan-export` binaries to
    `/opt/hamsterdan/bin`. At the reference's interpreter path,
    `/opt/hamsterdan/.venv/bin/python`, it installs a POSIX `sh` shim
    (`deployment/python-shim`).
  - The shim accepts the invocations that the `ENTRYPOINT`, the systemd
    unit, the Ansible validation runs and the release checks make:
    `-m hamsterdan.host`, `-m hamsterdan.operator`,
    `-m hamsterdan.host.export`, the package version probe and the
    version assertion.
  - It answers the version probe with `0.1.0`, the version of the
    reference package this port follows.
  - It refuses an unknown module as CPython does (`No module named ...`,
    status 1) and any other invocation with status 2. A Python one-liner
    that is none of those does not run in this image.
- **The Pi helpers.** The binaries run petrus-agenticus-runtime's data
  files (the Node Pi helpers and the provider sidecars, `data/`, exactly the
  package's `data-files`), which the reference ships inside its virtual
  environment. Cabal compiles the build stage's source path into the
  binaries, so the runtime stage copies `data/` to
  `/opt/hamsterdan/share/petrus-agenticus-runtime/data` and sets
  `petrus_agenticus_runtime_datadir` (Cabal's data-directory override) to
  that directory. These are the only runtime-stage instructions besides
  the binaries' and the shim's `COPY` that the reference does not have.
  Without them the host's Pi READY probe cannot find its helper, and the
  host silently runs with no agent runner, as the reference would with a
  broken Pi installation; `scripts/container-smoke` caught exactly that in
  the first image CI built.
- **Toolchain pins.** The base images are the reference's, pinned by
  digest. GHC (9.10.3) and cabal (3.16.1.0) are pinned by version, and the
  Haskell dependency plan by `cabal.project.freeze` (an
  `index-state` plus every package version). The `ghcup` binary that
  installs them is fetched unpinned from downloads.haskell.org. Pinning it
  by digest means picking a release to trust; it is not done yet.
- **The build stage** installs the `-dev` packages of every local package
  (`libpq`, `libzmq`, SQLite, `libffi`, `gmp`, `zlib`), because cabal plans
  the whole project, though only the three executables are built. It
  builds in two steps so the build cache can keep the slow one: a
  `cabal-files` stage reduces `packages/` to its `.cabal` files, the build
  stage plans the three executables from those alone and builds every
  Hackage library of that plan through a one-package project with the same
  freeze and options, and only then copies the sources and builds the
  executables. A change to the sources rebuilds the local packages only.
- **Built in CI, not on the development machine.** No container runtime may
  run on the development machine. The `container` job of
  `.github/workflows/ci.yml` builds the image and runs
  `scripts/container-smoke` against it (PARITY.md, "Container runtime
  contract").
