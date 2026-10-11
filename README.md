# petrus-haskell

A Haskell port of [Petrus](https://petrus.run/), Henrique Bastos's
colored-Petri-net runtime, together with the Petrus applications and tools
around it: [Hamsterdan](https://github.com/henriquebastos/hamsterdan), the
[petrus-viewer](https://github.com/henriquebastos/petrus-viewer) backend, and
loading of [petrus-engine](https://github.com/henriquebastos/petrus-engine) net
files.

The port aims to be:

- **Equivalent** to the upstream Python at the commits pinned in
  [UPSTREAM.md](UPSTREAM.md): everything in the upstream specs holds, every
  behavior the upstream tests check is checked here, and wire formats are
  byte-identical, so Haskell and Python instances interoperate.
- **At least as fast** as the pinned Python, shown by committed benchmarks.
- **Better designed where Haskell allows**: every intentional API divergence is
  documented next to the package that makes it.

[SCOPE.md](SCOPE.md) lists what is in and out of scope and why;
[PARITY.md](PARITY.md) shows which upstream components are at parity.

## Layout

| Path | Contents |
| --- | --- |
| `packages/` | Haskell packages (one cabal package each). |
| `docs/` | Plans of record, such as [docs/runtime.md](docs/runtime.md) for everything outside the kernel. |
| `spec/` | Language-neutral contracts this repo adds (Fabric, processes). The upstream specs live in `upstream/petrus/spec/`. |
| `upstream/` | Git submodules of the pinned upstream projects (the Python reference). |
| `scripts/` | `check-all`, `interop`, `bench`, `check-parity` and their helpers. |
| `bench-results/` | [summary.md](bench-results/summary.md): every package's benchmarks against Python at a glance. |

## Building and checking

[docs/reproducing.md](docs/reproducing.md) goes from a fresh machine to a
full rerun: prerequisites (GHC 9.10.3 and cabal 3.16 through ghcup, uv,
libzmq, PostgreSQL 17 or Docker, Node.js), the build, the tests, the interop
suites, the benchmarks and the parity check. In short:

```sh
git clone --recursive https://github.com/seasonedcc/petrus-haskell.git
cd petrus-haskell
scripts/check-all -j2      # build, tests, conformance, interop, parity table
scripts/check-all --viewer # also the upstream petrus-viewer suites (what CI runs)
scripts/interop            # only the cross-language suites, against the pinned Python
scripts/bench PACKAGE      # rerun a package's benchmarks against the pinned Python
scripts/check-parity       # the parity table's claims against the committed evidence
```

CI runs those same checks on every push to `main` and every pull request,
spread over parallel runners, plus the container image; its
[section in docs/reproducing.md](docs/reproducing.md#continuous-integration)
maps each CI job to its `scripts/check-all` step.

## License

Apache-2.0, like upstream Petrus. See [LICENSE](LICENSE) and [NOTICE](NOTICE)
for attribution of the upstream projects.
