# Upstream pins

Parity in this repository is always defined against the exact upstream
commits below. They are checked out as git submodules under `upstream/`, so
the Python reference implementation used by the interop and benchmark suites
is the pinned one, never whatever `main` happens to be.

| Project | Submodule | Pinned commit | Upstream date |
| --- | --- | --- | --- |
| [henriquebastos/petrus](https://github.com/henriquebastos/petrus) | `upstream/petrus` | `3f85fc2094e50ece48bcf6bf9ace19cb0a22a544` | 2026-09-13 |
| [henriquebastos/hamsterdan](https://github.com/henriquebastos/hamsterdan) | `upstream/hamsterdan` | `5d382467eaa4ff837cbd6b93012c99081e0153f9` | 2026-09-11 |
| [henriquebastos/petrus-engine](https://github.com/henriquebastos/petrus-engine) | `upstream/petrus-engine` | `fc1dd507ec4341f15aa9d0b17d4e14def95cf5c7` | 2026-07-08 (v0.1.0) |
| [henriquebastos/petrus-viewer](https://github.com/henriquebastos/petrus-viewer) | `upstream/petrus-viewer` | `ccb7808439f9bbc7f0e49cb0fabaa1a8471f37b8` | 2026-07-29 |

Hamsterdan pins its own Petrus dependency (`89baf78`). The Haskell port of
Hamsterdan runs on the Haskell port of Petrus at the Petrus pin above; any
behavior Hamsterdan depends on that differs between the two Petrus commits is
recorded in [PARITY.md](PARITY.md).

## Moving a pin

1. `git -C upstream/<name> fetch && git -C upstream/<name> checkout <new-sha>`.
2. Update the table above.
3. Run `scripts/upstream-diff <name> <old-sha> <new-sha>`. It lists the
   changed upstream modules, specs, fixtures, tests, dependency locks
   (`pyproject.toml`, `uv.lock`; `package.json`, `pnpm-lock.yaml`), the
   viewer's `vite.config.ts` and Hamsterdan's `deployment/`, then every
   other changed file, so nothing that moved goes unseen.
4. Mark every affected component in [PARITY.md](PARITY.md) as `in progress`
   until its conformance, interop, and benchmark evidence pass again at the new
   pin.
5. Regenerate the corpora and fixtures recorded from the reference, so the
   differential suites compare against the new pin and not the old one.
   `scripts/check-corpora` lists each recorded corpus with the command that
   regenerates it and reports the stale ones. For example, the viewer's MCP
   golden transcript is `node packages/petrus-viewer-server/test/record-mcp-transcript.mjs`.
6. Run `scripts/check-all` (build, tests, conformance, interop, benchmarks).
7. Commit the new gitlink (`git add upstream/<name>`) together with this
   table, the regenerated corpora, and the PARITY changes. A checkout that
   is moved but not committed leaves the gitlink at the old commit, and
   `scripts/check-pins` fails until the two agree.
