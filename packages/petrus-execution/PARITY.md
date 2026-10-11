# petrus-execution parity

Upstream: `petrus.motus.execution` and `petrus.motus._execution` at the pin in
[UPSTREAM.md](../../UPSTREAM.md). Intentional differences are in
[DIVERGENCES.md](DIVERGENCES.md); performance is in [bench/RESULTS.md](bench/RESULTS.md).

## Status

| Criterion | State |
| --- | --- |
| Tests | Every test in the four upstream files is ported (table below); 1 is not applicable. |
| Conformance | Archive bytes, Timeline lines, artifact metadata, redaction and telemetry mirroring are byte-identical to upstream (differential fixtures below). |
| Interop | The Gondolin sidecar is upstream's file, embedded verbatim (pinned SHA-256); registries, archives, Timeline JSONL and artifact metadata are the upstream formats. E2B is reached by a native client of E2B's REST and envd protocols (the wire protocol of the `e2b` SDK upstream imports), checked request by request against a fake E2B server. |
| Performance | Archive pack/validate/extract 1.1x-8x faster, process spawn 1.7x faster; sidecar round trips level: over eleven alternating rounds on a quiet machine (2026-10-11, load 2.2–2.3), handshake 1.02x (Haskell ahead in 6 of 11) and execute 1.00x (4.84 ms against 4.86 ms, Haskell ahead in 7 of 11, every round within 3%; the execute is the shared Node sidecar spawning `sh`, and no PostgreSQL is involved). The earlier 0.98x was within that noise ([bench/RESULTS.md](bench/RESULTS.md)). |

Suite: `cabal test petrus-execution` runs 412 examples on macOS and 416 on the Linux CI runner
(3 pending without opt-ins: real Docker, real Gondolin and live E2B; CI sets `PETRUS_TEST_DOCKER=1`,
so 2 are pending there).

## Upstream test map

Every Haskell example that ports an upstream test carries the upstream test name in its label, so
`--match <name>` runs it. Parametrized upstream tests are expanded per parameter.

| Upstream file | Upstream test | Haskell | Notes |
| --- | --- | --- | --- |
| test_execution_contract.py | test_public_surface_is_exact_optional_safe_and_owns_its_values | `test/ProvidersSpec.hs` | the bounds and capability vocabulary are asserted; the exact export list and `optional-safe` import discipline (no e2b / timeline / agenticus import) are enforced by the module export list of `Petrus.Motus.Execution`, which imports no provider, Timeline or SDK module |
| test_execution_contract.py | test_private_model_location_is_identity_compatible_without_owning_types | - | not applicable: checks that a private Python module re-exports the public class object (`is` identity). Haskell has one definition per type, so there is no second location to alias. |
| test_execution_contract.py | test_provider_capability_discovery_is_semantic_and_provider_differences_are_explicit | `test/GondolinSpec.hs`, `test/ProvidersSpec.hs` |  |
| test_execution_contract.py | test_destroy_never_verifies_absence_for_a_foreign_provider | `test/DockerSpec.hs`, `test/E2bSpec.hs`, `test/GondolinSpec.hs`, `test/ProvidersSpec.hs` |  |
| test_execution_contract.py | test_local_public_lifecycle_transfers_workspace_and_returns_verified_cleanup | `test/LocalSpec.hs` |  |
| test_execution_contract.py | test_local_destroy_refuses_stale_identity_and_retains_uncertain_custody | `test/LocalSpec.hs` |  |
| test_execution_contract.py | test_create_checks_capabilities_before_reusing_an_existing_operation | `test/LocalSpec.hs` |  |
| test_execution_contract.py | test_command_is_snapshotted_finite_and_uniformly_bounded | `test/ContractSpec.hs` |  |
| test_execution_contract.py | test_private_file_values_are_bounded_path_free_and_secret_safe | `test/ContractSpec.hs` |  |
| test_execution_contract.py | test_docker_public_lifecycle_is_lookup_first_and_cleanup_is_identity_correlated | `test/DockerSpec.hs` | runs against the fake CLI and, with `PETRUS_TEST_DOCKER=1`, a real daemon |
| test_gondolin_environment.py | test_sidecar_has_valid_node_syntax | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_gondolin_sidecar_lifecycle_recreation_vfs_and_bounds | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_sidecar_resolves_a_custom_image_store_locally_before_vm_creation | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_sidecar_sanitizes_a_missing_local_image_store_path | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_gondolin_private_file_route_and_persisted_grant | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_gondolin_lease_without_requirement_does_not_gain_private_transfer | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_existing_noncapable_lease_cannot_satisfy_later_private_requirement | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_private_probe_failure_rolls_back_without_relocking_or_residue | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_private_symlink_replacement_is_unverified_and_never_touches_target | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_private_cleanup_is_unverified_while_command_is_active | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_private_sidecar_death_requires_territory_destroy_for_verified_cleanup | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_gondolin_timeout_destroys_lease | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_gondolin_output_overflow_closes_and_destroy_is_idempotent | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_command_cwd_is_guest_lexical_and_cannot_escape_workspace | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_concurrent_provision_creates_one_lease_and_sidecar | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_spawn_failure_removes_runtime_and_operation_directory | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_registry_write_failure_stops_unregistered_sidecar | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_unregistered_workspace_fails_closed_before_runtime_creation | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_lock_revalidates_after_destroy_unlinks_a_waiters_inode | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_process_identity_uses_ps_when_proc_is_unavailable | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_group_identity_snapshot_ignores_member_that_exited_after_enumeration | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_sidecar_enforces_single_flight_commands | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_currency_check_failure_closes_active_lease | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_supersession_closes_fresh_lease | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_ttl_expires_and_can_be_destroyed_without_residue | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_private_security_probe_gets_startup_grace_before_short_ttl | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_hard_sidecar_death_has_verified_cleanup | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_foreign_reused_process_group_fails_closed_without_signal | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_same_process_marker_allows_zombie_leader_cleanup | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_recorded_member_identity_allows_orphan_process_group_cleanup | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_changed_recorded_member_identity_fails_closed_without_signal | `test/GondolinSpec.hs` |  |
| test_gondolin_environment.py | test_real_gondolin_lifecycle_is_explicitly_opt_in | `test/GondolinSpec.hs` | opt-in; see *Real-backend runs* below |
| test_private_execution_substrate.py | test_provider_neutral_lifecycle_and_environment_custody | `test/DockerSpec.hs`, `test/LocalSpec.hs` | runs against the fake CLI and, with `PETRUS_TEST_DOCKER=1`, a real daemon |
| test_private_execution_substrate.py | test_docker_lookup_first_survives_adapter_recreation_and_is_unique | `test/DockerSpec.hs` | runs against the fake CLI and, with `PETRUS_TEST_DOCKER=1`, a real daemon |
| test_private_execution_substrate.py | test_artifacts_are_host_custodied_integrity_checked_and_provider_neutral | `test/SubstrateSpec.hs` |  |
| test_private_execution_substrate.py | test_artifact_retention_prunes_oldest_without_removing_current_authority | `test/SubstrateSpec.hs` |  |
| test_private_execution_substrate.py | test_timeline_redacts_recursively_correlates_and_has_no_authority | `test/SubstrateSpec.hs` |  |
| test_private_execution_substrate.py | test_timeline_mints_sequences_across_restart_and_retention_is_sink_policy | `test/SubstrateSpec.hs` |  |
| test_private_execution_substrate.py | test_telemetry_handler_builds_one_redacted_correlated_noncanonical_stream | `test/SubstrateSpec.hs` |  |
| test_private_execution_substrate.py | test_telemetry_handler_failure_is_non_blocking | `test/SubstrateSpec.hs` |  |
| test_private_execution_substrate.py | test_capabilities_and_reconciliation_are_truthful | `test/LocalSpec.hs` |  |
| test_private_execution_substrate.py | test_local_cwd_still_resolves_symlinks_before_containment | `test/LocalSpec.hs` |  |
| test_private_execution_substrate.py | test_cross_provider_workspace_handoff_has_no_shared_path | `test/DockerSpec.hs` | runs against the fake CLI and, with `PETRUS_TEST_DOCKER=1`, a real daemon |
| test_private_execution_substrate.py | test_tar_rejects_escape_links_and_special_files | `test/ArchiveSpec.hs` |  |
| test_private_execution_substrate.py | test_workspace_archive_member_and_size_limits_are_enforced | `test/ArchiveSpec.hs` |  |
| test_private_execution_substrate.py | test_local_collection_drains_large_output_and_kills_sigterm_ignoring_process | `test/LocalSpec.hs` |  |
| test_private_execution_substrate.py | test_command_snapshots_and_validates_environment | `test/ContractSpec.hs` |  |
| test_private_execution_substrate.py | test_docker_command_credentials_are_not_exposed_in_host_argv | `test/DockerSpec.hs` |  |
| test_private_execution_substrate.py | test_e2b_vm_lifecycle_is_lookup_first_artifact_based_and_recoverable | `test/E2bSpec.hs` |  |
| test_private_execution_substrate.py | test_e2b_vm_cwd_remains_a_guest_path_when_the_host_remaps_home | `test/E2bSpec.hs` |  |
| test_private_execution_substrate.py | test_e2b_vm_creation_lookup_failure_kills_uncertain_sandbox | `test/E2bSpec.hs` |  |
| test_private_execution_substrate.py | test_e2b_vm_transport_failure_is_not_mislabeled_as_command_failure | `test/E2bSpec.hs` |  |
| test_private_execution_substrate.py | test_e2b_vm_output_is_bounded | `test/E2bSpec.hs` |  |
| test_private_execution_substrate.py | test_e2b_vm_command_timeout_and_supersession_kill_remote_command | `test/E2bSpec.hs` |  |
| test_private_execution_substrate.py | test_live_e2b_vm_provider_is_explicitly_opt_in | `test/E2bSpec.hs`, `test/E2bLive.hs`, `test/E2bHttpSpec.hs` | opt-in exactly as upstream (same three gates and skip reasons); the same body runs on every run against the fake E2B server through the native client (see *Real-backend runs*) |
| test_private_file_transfer.py | test_local_private_file_full_custody_route_is_bounded_and_workspace_free | `test/LocalSpec.hs` |  |
| test_private_file_transfer.py | test_local_private_refs_are_exactly_attachment_and_lease_fenced | `test/LocalSpec.hs` |  |
| test_private_file_transfer.py | test_local_private_symlink_replacement_never_reads_or_unlinks_target | `test/LocalSpec.hs` |  |
| test_private_file_transfer.py | test_local_private_operations_are_excluded_while_command_is_active | `test/LocalSpec.hs` |  |
| test_private_file_transfer.py | test_local_private_file_count_and_total_bounds_are_attachment_scoped | `test/LocalSpec.hs` |  |
| test_private_file_transfer.py | test_noncapable_providers_reject_private_roots_before_lookup_or_allocation | `test/DockerSpec.hs`, `test/E2bSpec.hs` |  |

`test/E2bHttpSpec.hs` drives the native E2B client (`Providers.E2b.Http`, the default `e2bSdkLoader`) against
`test/fixtures/fake_e2b.py`, a stand-in for E2B's API and envd that speaks the `e2b` 2.55.1 SDK's wire
protocol and runs commands for real in a per-sandbox directory. It runs upstream's whole live lifecycle
through the default loader and the SDK's environment variables, and checks the requests (paths, bodies,
`X-API-KEY`, envd headers, Connect framing and timeouts, `SendSignal SIGKILL`), envd's exit report for a
killed command, foreground failures raising `CommandExitException` as `commands.run` does, old-envd
default-user handling, the envd-0.1.0 template refusal, missing and wrong API keys, the SDK's retry policy
(503 retried, a 502 on create not), `x-next-token` pagination, and a dropped command stream.

Beyond the upstream tests, the suite also checks constructor validation, operation-id validation,
TERM-to-KILL escalation of process groups, Timeline envelope/sequence errors and retention hysteresis,
archive bounds, descriptor and SIGPIPE inheritance of spawned children, and cross-provider
capability discovery and foreign-lease destroy across all four providers at once.

## Differential fixtures (byte identity)

Generated by running upstream Petrus and committed; regenerate from the repository root.

| Fixture | Generator | Proves |
| --- | --- | --- |
| `test/fixtures/archive_fixtures-darwin.json`, `test/fixtures/archive_fixtures-linux.json` | `uv run --frozen --python 3.14.6 --project upstream/petrus python packages/petrus-execution/test/fixtures/generate_archive_fixtures.py`, once on macOS and once on Linux (the generator's docstring has the Docker command) | `workspace_archive` bytes and digests, PAX headers, `tarfile.open("r:*")` member parsing (GNU, PAX, sparse, global, gzip, malformed), validation outcomes and messages, extracted trees. The reference's output is platform-dependent (a symlink's `lstat` mode is `0o777` on Linux and follows the umask on macOS, APFS refuses non-UTF-8 names, errno numbers differ), so each platform has its own file and the suite reads the one for the host it runs on |
| `test/fixtures/substrate_fixtures.json` | `upstream/petrus/.venv/bin/python packages/petrus-execution/test/fixtures/generate_substrate_fixtures.py` | artifact digests and `.json` metadata bytes, Timeline JSONL lines (including microsecond and year-999 timestamps and non-ASCII), secret-key and secret-value redaction, telemetry mirroring, phase derivation |
| `test/fixtures/fake_gondolin.mjs` | `upstream/petrus/.venv/bin/python packages/petrus-execution/test/fixtures/generate_fake_gondolin.py` | the fake Gondolin SDK, extracted verbatim from upstream's `fake_sdk` fixture |
| `data/gondolin_sidecar.mjs` | copied from `upstream/petrus/src/petrus/motus/_execution/gondolin_sidecar.mjs` | the sidecar itself; its SHA-256 is pinned by a test |

## Real-backend runs

The fakes cover every upstream behavior in CI. The real backends are opt-in and env-gated; with the
variables unset the corresponding examples are reported as pending with the reason.

### E2B (`PETRUS_RUN_CV10_E2B=1`, `E2B_API_KEY`, `PETRUS_CV10_E2B_TEMPLATE`)

The gates and skip reasons are upstream's. With all three set, `test_live_e2b_vm_provider_is_explicitly_opt_in`
runs upstream's live lifecycle (`test/E2bLive.hs`) against real E2B through the default loader, the native
client; `E2B_DOMAIN`, `E2B_API_URL` and `E2B_SANDBOX_URL` are honoured as by the SDK:

```
PETRUS_RUN_CV10_E2B=1 E2B_API_KEY=... PETRUS_CV10_E2B_TEMPLATE=base \
  cabal test petrus-execution --test-options='--match test_live_e2b_vm_provider_is_explicitly_opt_in'
```

Status: **not yet run against real E2B** (no API key is available to this project), exactly like upstream,
whose live test is skipped without one. The same lifecycle body passes on every run against the fake E2B
server (`E2bHttpSpec`), whose protocol was read from the `e2b` 2.55.1 SDK source.

### Docker (`PETRUS_TEST_DOCKER=1`, optional `PETRUS_TEST_DOCKER_IMAGE`)

CI sets `PETRUS_TEST_DOCKER=1` (Ubuntu with Docker). Local run on 2026-10-10, macOS, Docker 29.8.2,
image `postgres:17.5-alpine@sha256:6567bca8...`:

```
PETRUS_TEST_DOCKER=1 cabal test petrus-execution --test-options='--match "real CLI"'
```

Result: 5 examples, 0 failures in 6.5 s, no labelled containers left behind. Upstream's own Docker
tests (`pytest -k "docker or cross_provider"`) took 8.3 s on the same machine.

### Gondolin (`PETRUS_REAL_GONDOLIN_SDK_MODULE`, `PETRUS_REAL_GONDOLIN_IMAGE`, optional `PETRUS_REAL_GONDOLIN_NODE`)

Status on 2026-10-11: **passes against real Gondolin, as upstream's own acceptance test does.**
On macOS (aarch64), with the commands below, the port's
`test_real_gondolin_lifecycle_is_explicitly_opt_in` provisioned a real VM and ran its whole
lifecycle: 1 example, 0 failures in 11.3 s. Upstream's
`pytest -m real_gondolin_acceptance tests/petrus/motus/test_gondolin_environment.py`, run at the
pinned commit with the same SDK, image and Node, passed in 11.2 s (1 passed, 32 deselected). The
fake-SDK suite drives the verbatim sidecar through every upstream scenario on every CI run.

| Step | State |
| --- | --- |
| SDK `@earendil-works/gondolin@0.12.0` in the git-ignored `.gondolin/sdk` | installed |
| SDK entry module | `node_modules/@earendil-works/gondolin/dist/src/index.js`, the package's `exports["."].import`; the sidecar `import()`s it by path |
| Guest image `alpine-base:latest` in the package-local store `.gondolin/images` | pulled (build `e490f153-9700-596d-bb59-9ebf69c725dc`, aarch64) |
| QEMU 11.1.2, Node 24 via `fnm` | available |

The sidecar resolves the image with the SDK's `resolveImageSelector`. That lookup is local only: it
reads `GONDOLIN_IMAGE_STORE` (default `$XDG_CACHE_HOME/gondolin/images`) and never downloads. The
image therefore has to be pulled first. Upstream's acceptance test has the same requirement, and
both implementations pass `GONDOLIN_IMAGE_STORE`, `HOME`, `PATH` and `XDG_CACHE_HOME` through to
the sidecar. `alpine-base:latest` is the SDK's default image (`GONDOLIN_DEFAULT_IMAGE`).

To run it, from the repository root (everything stays inside the package's git-ignored `.gondolin/`):

```
cd packages/petrus-execution
mkdir -p .gondolin/sdk
printf '{"private":true,"dependencies":{"@earendil-works/gondolin":"0.12.0"}}\n' > .gondolin/sdk/package.json
(cd .gondolin/sdk && fnm exec --using=24 npm install)
export GONDOLIN_IMAGE_STORE=$PWD/.gondolin/images
fnm exec --using=24 node .gondolin/sdk/node_modules/@earendil-works/gondolin/dist/bin/gondolin.js \
  image pull alpine-base:latest
cd ../..
PETRUS_REAL_GONDOLIN_SDK_MODULE=$PWD/packages/petrus-execution/.gondolin/sdk/node_modules/@earendil-works/gondolin/dist/src/index.js \
PETRUS_REAL_GONDOLIN_IMAGE=alpine-base:latest \
PETRUS_REAL_GONDOLIN_NODE=$(fnm exec --using=24 which node) \
  cabal test petrus-execution --test-options='--match test_real_gondolin_lifecycle_is_explicitly_opt_in'
```

Upstream's own test, for comparison (same variables; its sidecar takes `node` from `PATH`):

```
cd upstream/petrus
PETRUS_REAL_GONDOLIN_SDK_MODULE=... PETRUS_REAL_GONDOLIN_IMAGE=alpine-base:latest \
  fnm exec --using=24 uv run pytest -m real_gondolin_acceptance tests/petrus/motus/test_gondolin_environment.py
```

The sidecar refuses a real SDK on Node older than 23.6, which is why `PETRUS_REAL_GONDOLIN_NODE`
exists; upstream takes `node` from `PATH`.

`npm audit` (2026-10-10) reports 2 high-severity entries, both caused by one advisory:

- [GHSA-86w9-cpqp-85rv](https://github.com/advisories/GHSA-86w9-cpqp-85rv): `node-forge` (1.4.0
  installed; no fixed version) accepts extra nested DigestAlgorithm elements when verifying RSA
  PKCS#1 v1.5 signatures.
- The second entry is `@earendil-works/gondolin` itself, flagged only because it depends on
  `node-forge`.

The SDK uses `node-forge` to:

- generate its HTTPS-interception CA and per-host leaf certificates;
- parse PEM files;
- verify signatures in exactly one place: checking that a leaf certificate it previously cached on
  the host (under the XDG cache) was signed by its own CA (`qemu/net.js`, `caCertVerifiesLeaf`).

Exploiting the flaw would require an attacker who can already write that host-side cache
directory. No signature from the network or the guest is ever verified with `node-forge`. For the
opt-in, test-only use here, the finding does not matter.

### E2B

Not runnable: there is no Haskell E2B SDK (see DIVERGENCES.md). Upstream's live test is likewise opt-in.
