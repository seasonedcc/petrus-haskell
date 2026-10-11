# hamsterdan-github parity

This file lists what this package ports from `upstream/hamsterdan` (pinned in
[UPSTREAM.md](../../UPSTREAM.md)) and the evidence for each piece. The
expectations in every corpus were produced by the committed generator scripts
running in the pinned environment:

- `upstream/hamsterdan/.venv` with Python 3.14.6;
- githubkit 0.16.0, httpx 0.28.1, hishel 1.3.0, PyJWT 2.13.0,
  cryptography 50.0.0 and pydantic 2.13.4.

The Haskell suite replays each row and compares the results byte for byte.

## Upstream source → Haskell

| Upstream | Haskell | Evidence |
| --- | --- | --- |
| `github_app/config.py`: `HostConfig.from_environment`, `installation_accounts` (TOML through `tomllib`, file custody checks, credential validation, watched authors, redaction) | `Hamsterdan.GitHub.Config` | `test/corpus/config.jsonl` (1500 installations files, 600 host environments: every snapshot and every `ConfigurationError` message); `AppFoundationSpec` "configuration" |
| `github_app/webhooks.py`: `WebhookCustody` (envelope checks, `verify` before parse, `_parse` projection, dedupe, the retry schedule and parking, the `next_attempt_at` migration, `pending`/`eligible`/`acknowledge`/`retry`/`status`/`counts`/`failures`/`requeue`), `admit_conversation` | `Hamsterdan.GitHub.Webhooks` | `test/corpus/webhooks.jsonl`: 1000 `receive` sequences (outcomes and final SQLite rows, byte for byte) and 200 inbox lifecycles; `AppFoundationSpec` "webhooks", "conversation admission" |
| githubkit `webhooks.sign` / `verify` | `sign`, `verify`, `verifier` / `verifyWith` | the webhook corpus (every receive verifies), `AppFoundationSpec` |
| `github_app/routing.py`: `InstallationRegistry` (lifecycle events, reconciliation, fenced removal) | `Hamsterdan.GitHub.Routing` | `test/corpus/webhooks.jsonl` (300 routing sequences, outcomes and rows); `AppFoundationSpec` "routing" |
| CPython `sqlite3` as the stores use it (busy timeout, scripts, `with connection:` transactions) | `Hamsterdan.Sqlite` (in hamsterdan-contracts, shared with the host and agents) | the inbox and routing rows in the webhook corpus |
| `github_app/auth.py`: `GitHubAppClients` (`app`, `installation`, `inventory_client`), `registration_inventory`, `_validate_permissions` (the startup permission/event/installation/repository check) | `Hamsterdan.GitHub.Auth`, `Hamsterdan.GitHub.Client` | `test/corpus/http.jsonl` (rows that run the inventory check); `GitHubSpec` "GitHub App client stack" |
| githubkit `AppAuthStrategy` / PyJWT: the RS256 App JWT, installation-token minting and expiry, `MemCacheStrategy`, route rules (App JWT vs. token vs. bypass) | `Hamsterdan.GitHub.Jwt`, `Hamsterdan.GitHub.Client` | `test/corpus/http.jsonl` (every `Authorization` header, including the JWT bytes, and every token request body) |
| githubkit / httpx request building, header order, response decoding (`Content-Encoding`, charset), error families, `Link` handling | `Hamsterdan.GitHub.Http`, `Hamsterdan.GitHub.Url`, `Hamsterdan.GitHub.Client` | `test/corpus/http.jsonl` (1400 rows: request line, ordered headers and body bytes of every exchange; metadata-hook observations; each step's outcome) |
| hishel 1.3 `SpecificationPolicy` (private cache, conditional revalidation, 304 freshening and invalidation, unread-body hiding, `parse_date`) | `Hamsterdan.GitHub.Cache` | `test/corpus/http.jsonl` (cacheable, revalidated, mismatched-304 and malformed-date responses) |
| `github_app/transport.py`: `GitHubKitTransport` (`request`, `pages`, `download`: method and origin bounds, 64 KiB bodies, 1 MiB responses, redirect refusal, `Link` pagination to 20 pages without cycles), `GitHubGraphQL` (review threads, `resolveReviewThread`, the `repository{id}` + `updateRefs` compare-and-swap) | `Hamsterdan.GitHub.Transport` | `test/corpus/http.jsonl` (REST and download bounds); `test/corpus/effects.jsonl` (`review_threads`, `resolve_thread`, `cas_ref`); `GitHubSpec` |
| `github_app/gateway.py`: `GitHubAuthority` (`pull_request`, `policy` with the classic-protection fallback and digest, `human_review`, `resolve_stale_finding_threads`, `base_current`, `comments`, `workflow_runs`, `select_run`, `jobs`, `run_result`, `actions_evidence`, `failure_logs`, `create_tree` / `create_commit` with blobs) | `Hamsterdan.GitHub.Gateway` | `test/corpus/effects.jsonl` (each read and Git-object write against a randomly misbehaving GitHub: every request, body and outcome); `GitHubSpec` "GitHub gateway" |
| `github_app/effects.py`: `CommentPublisher` (markers, `immutable`, `immutable_operation`, `find`, `dashboard`, `finding`, `findings` review batches, `reminder`, `reminder_operation`, lookup-first recovery, fences, fault hooks, the 60 s / 120 s inline retry), `CommentRerunBroker` (`held`, `issue`, `request`) | `Hamsterdan.GitHub.Effects` | `test/corpus/effects.jsonl` (every interaction in order: requests with exact JSON bodies, page reads, fences, faults, retry delays, and the outcome); `GitHubSpec` "comment publisher", "rerun broker" |
| `github_app/models.py`: snapshots, results, `GitHubBoundaryError` / `GitHubObjectWriteError`, failure classes, `RerunRefusedError`, the capability protocols | `Hamsterdan.GitHub.Models` | all of the above |

## Corpora

| Corpus | Rows | Generator |
| --- | ---: | --- |
| `config.jsonl` (installations files and host environments) | 2100 | `scripts/gen_config_corpus.py` |
| `webhooks.jsonl` (1000 receive, 200 inbox, 300 routing sequences) | 1500 | `scripts/gen_webhook_corpus.py` |
| `effects.jsonl` (reads, Git objects, effects, broker and GraphQL operations against a simulated GitHub) | 4010 | `scripts/gen_effects_corpus.py` |
| `http.jsonl` (the client stack over a scripted network) | 1400 | `scripts/gen_http_corpus.py` |
| **Total** | **9010** | |

Each generator is seeded and deterministic. To regenerate the corpora, run
from the repository root:

```sh
upstream/hamsterdan/.venv/bin/python packages/hamsterdan-github/scripts/gen_config_corpus.py
upstream/hamsterdan/.venv/bin/python packages/hamsterdan-github/scripts/gen_webhook_corpus.py
upstream/hamsterdan/.venv/bin/python packages/hamsterdan-github/scripts/gen_effects_corpus.py
upstream/hamsterdan/.venv/bin/python packages/hamsterdan-github/scripts/gen_http_corpus.py
```

Every value in the corpora is synthetic: no credential, token or real
payload. The App key that signs the corpus JWTs is the throwaway
`test/corpus/app-test-key.pem`.

`HTTP_CORPUS_ROW=<n>` makes the HTTP corpus spec replay one row and trace each
request and step. Use it when debugging a mismatch.

## Upstream tests

The suite has 200 examples:

- 162 examples port upstream tests, one per test or per parameter;
- 38 examples replay the corpora.

| Upstream module | Tests | Haskell | Status |
| --- | ---: | --- | --- |
| `tests/unit/github_app/test_github.py` | 56 | `test/GitHubSpec.hs` (gateway, comment publisher, rerun broker): 81 examples with parameters | 55 ported. `test_transport_repr_does_not_claim_or_expose_credentials` does not apply (DIVERGENCES 3). |
| `tests/unit/github_app/test_app_foundation.py` | 34 | `test/AppFoundationSpec.hs` (admission, configuration, routing, webhooks): 54 examples; `test/GitHubSpec.hs` "GitHub App client stack": 27 examples | all ported |

Each ported example's description paraphrases its upstream test name. For
example, `test_inline_transient_exhaustion_uses_bounded_exponential_backoff`
is "exhausts transient inline rejections with bounded exponential backoff".
They drive the same fakes:

- `FakeTransport` and its subclasses are a `Fake` record with an override
  function;
- `httpx.MockTransport` is a scripted `Exchange`.

They make the same assertions. Two tests change how the fake is wired:

- **`test_actions_evidence_*`** monkeypatch `jobs` and `run_result` in Python.
  The ports serve the equivalent jobs response through the fake transport
  instead, and assert the same evidence.
- **`test_transport_normalizes_httpx_network_failures`** builds a token-auth
  `GitHub` client in Python. The port goes through an installation client,
  whose exchange mints a token and then fails every API request with a
  `ReadError`.

## Not in this package (by design)

- **`host/api.py`** (the `POST /github/webhooks` endpoint and its HTTP 202/400
  bodies), **host Git publication** (`host/git_publish.py`) and the V5
  gates that call these effects belong to `hamsterdan-host`. This package
  provides the pieces they call: `receive`, `createTree`, `createCommit`,
  `compareAndSwapRef`.
- **Upstream tests that use this layer but test other components** are ported
  with those components:
  - `tests/unit/host/*`, `tests/integration/host/test_git_publish.py` and
    `test_service.py` with `hamsterdan-host`;
  - `tests/unit/readiness/net_v5/test_inline_recovery.py` with
    `hamsterdan-readiness`;
  - `tests/unit/test_operator.py` with `hamsterdan-operator`.
- **`tests/test_architecture.py`** enforces Python import rules. Here
  `scripts/lint-hamsterdan-architecture` enforces the ones that carry over on
  the Haskell import graph (see "Upstream tests not ported" in the root
  [PARITY.md](../../PARITY.md)).
- **End-to-end runs against a real GitHub App** (docs/hamsterdan.md §5) are
  not part of this package. No test makes a network call.

## Known differences

All are listed with their reasons in [DIVERGENCES.md](DIVERGENCES.md). None
changes a wire format. In short:

- Lone surrogates in provider JSON are refused, and very deep nesting is
  parsed.
- The members of the repository objects in an installation-token response are
  not validated.
- `urlsplit`'s NFKC check and httpx's IDNA check are not reproduced. The
  origin bound refuses those URLs anyway.
- `str.isdigit` is approximated in the hishel date parser.
- The messages of uncaught CPython exceptions are not compared; their classes
  are.
- There is no environment proxy or CA-bundle handling, and no 100-request
  concurrency throttle.
