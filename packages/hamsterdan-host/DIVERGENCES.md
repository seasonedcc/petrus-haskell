# hamsterdan-host divergences

Wire and on-disk formats never diverge. Both hosts write the same bytes to:

- History;
- `webhooks.sqlite3`, `runnable.sqlite3` and the per-Instance stores;
- `binding.json`;
- the review requests;
- the timers;
- the agent state (`agent-routes.sqlite3` and `pi-a2/`, see
  `../hamsterdan-agents/DIVERGENCES.md`).

The same holds for the HTTP responses and for the GitHub requests.
[PARITY.md](PARITY.md) lists the tests that hold both hosts to this.

Below are the differences that remain, with their rationale.

## Observable

1. **uvicorn's own log lines are not written.**
   - `serve` does not print uvicorn's startup and shutdown lines (`Started
     server process`, `Uvicorn running on …`, `Application startup
     complete.`, and so on) to stderr.
   - It does not print the access log lines (`INFO:     127.0.0.1:… - "POST
     /github/webhooks HTTP/1.1" 202 Accepted`) to stdout.
   - The host's own warnings are written to stderr exactly as Python
     logging's last-resort handler writes them: the bare message, one per
     line. These are `webhook_retry`, `application_sweep_retry`,
     `scheduler_instance_degraded`, `shutdown_terminal_settlement_failed`,
     `qualification_fault` and `V5 review agent unavailable`.
   - The host's `LOG.info` lines are not written on either side, because no
     handler enables INFO for the host's loggers. That includes the
     GitHub request-metadata hook, so the port does not install that hook.
   - Why it stays: these lines are uvicorn 0.52's and h11's own
     operational log, not hamsterdan's. Matching them means emulating that
     stack's logging: `dictConfig`'s formatters with click colors chosen by
     each stream's `isatty`, the lifespan and bind-failure messages, the
     access line's client address and status phrase, and h11's protocol
     warnings (`Invalid HTTP request received.`) and ASGI tracebacks. The
     last two have no counterpart under warp, which parses and refuses
     malformed requests itself, so a port could only match the steady-state
     lines. Nothing in the reference or its tests reads them.
2. **An uncaught exception prints only its last traceback line.** The
   command line prints `Class: message` with exit status 1. The reference
   prints the whole Python traceback, which ends in that same line.
3. **Help and usage text has no color.**
   - CPython 3.14's `argparse` colors help when the stream is a terminal and
     `NO_COLOR` / `PYTHON_COLORS` allow it.
   - The port writes the plain text, which is what the reference writes to
     a pipe. That is the differential test's setting.
   - The width is the same: `COLUMNS`, else the terminal, else 80.
4. **Haskell-native failures get the nearest Python class name.** Where a
   failure class reaches History, the inbox (`error_class`), the status
   document or a log line (`error_class=…`), `Hamsterdan.Host.ExceptionClass`
   names it from a closed list:
   - every exception type the Hamsterdan packages declare carries its
     reference class (`GitHubBoundaryError`, `RerunRefusedError`,
     `ValueError`, …), checked against the pinned reference's modules;
   - a SQLite failure is named as CPython's `sqlite3` names it
     (`OperationalError`, `IntegrityError`, `DatabaseError`, …), checked
     against the pinned interpreter for the same statements;
   - failures that only Haskell can raise get the nearest built-in class:
     `IOException` is `OSError`, `ErrorCall` is `RuntimeError`,
     `ArithException` is `ArithmeticError`, `ArrayException` is
     `IndexError`.

   A declared type missing from the list fails the host's test suite. Only
   a library's own exception, which the reference cannot raise, keeps its
   Haskell type name.
5. **A conversation request's allowed intents come in source order.** The
   reference spreads `_MUTATIONS`, a `frozenset` of strings, into the V5
   application's `_ALLOWED`. So the last three intents a conversation
   request declares come in the process's string-hash order, which changes
   from run to run. The port always declares them in source order:
   `change`, `update_base`, `resolve_conflict`. That is one of the orders
   the reference produces. The hamsterdan-testing journeys pin the
   reference to it so that the two can be compared byte for byte.

## Internal (no observable difference)

- **`HostGitPublisher.reconcileHook` is a test seam.** Upstream tests
  observe the publisher by monkeypatching `HostGitPublisher.reconcile`,
  which also catches the reconciliations `publish` makes internally. The
  record field `reconcileHook` gives Haskell tests the same view: it wraps
  every reconciliation, including those inside `publish`, and receives the
  `self_caused_head` keyword (empty when it is not passed). It defaults to
  `noReconcileHook`, which changes nothing. The hamsterdan-testing journeys
  use it.

- **Stores are closed when the application fails to construct.**
  `openApplication` closes the stores it had already opened when a later
  step fails. The reference leaves them for the garbage collector.
- **The engine policy's target is the selection's input.** The
  reference's selection reads the policy object's mutable `target`
  attribute. The Petrus selection seam is pure, so the Engine is given a
  `SteeredSelection`: it reads the target (an `IORef` the host writes only
  between drives, on the Instance's single thread) before each proposal and
  proposes with `v5Selection target`. No `unsafePerformIO` is involved.
- **`inactive_activity_result` decodes the single parameter.** Every V5
  publication gate declares exactly one parameter. The port refuses any
  other shape with the reference's `ValueError` text, and does not
  generalize over parameter lists.
- **`transport_factory` is a pure function.** `ServiceOptions.transportFactory`
  is `Maybe (Transport -> Transport)`, applied to the operation transport
  where the reference calls `self._transport_factory(...)`. `HostClients`
  holds the composed client stack that the reference builds from
  `GitHubAppClients`.
- **Temporary directories.** `git_publish`'s private directory comes from
  `withSystemTempDirectory` (`hamsterdan-git-…`). Failing to create it or to
  remove it is the reference's `GitOperation` failure, as with
  `tempfile.TemporaryDirectory`.
- **`InstanceBinding` moved to hamsterdan-agents.** The Pi A2 installation
  binding needs `host/binding.py`, so `Hamsterdan.Host.Binding` now lives
  in hamsterdan-agents, and this package imports it. `BindingSpec` still
  runs here.
- **h11's status line is written by the port.** Warp echoes the request's
  HTTP version, and no WAI hook can change that. `runHostSocket` gives warp
  its own accept loop and wraps each connection: while the application
  answers an HTTP/1.0 request, the first bytes sent on its thread (the
  status line) have their version replaced with `HTTP/1.1`, as h11 writes
  it. The headers, including the final `Connection: close`, and the body
  are warp's, unchanged.
- **The end-to-end seams (`packages/hamsterdan-e2e`).** Tier B replays a
  tape into this host through seams it already had: `ServiceOptions.clock`
  and `clients` (`gitHubHostClients` over `newPlainExchangeAt`, the
  configurable API base), the agent runner and custody of `serviceOptions`,
  and `ApplicationOptions.mutationPublisher` (the Git publisher, replayed at
  its boundary) through `v5ApplicationFactory`. Tier C's
  `hamsterdan-e2e-host` is this command line with `CliEnvironment`'s
  `composeAgent` (the carried agent) and `clientOptions` (a fake GitHub,
  for tests only) replaced. The one seam added for them is
  `CliEnvironment.reraise`: `serve` returns the signal that stopped it,
  and the command line raises SIGTERM again with the default action, as
  uvicorn does (the tier C host rehearsal found the exit status differing).
  Production raises it; `CliSpec` records it instead.

- **A fresh timer store's schema is one transaction.** The reference's
  `_create_schema` runs `executescript` on an autocommit connection, so each
  of its six `CREATE` statements commits on its own, and then the meta row
  does: seven WAL commits, each with its fsync, on every fresh open and
  every rebuild. `createSchema` runs the same statements and the same
  `INSERT` inside one transaction, which saves six of the open's fifteen
  fsyncs (about 0.35 ms of 1.3 ms on the benchmark machine). The closed file
  is unchanged: the schema cookie still counts one change per statement,
  and `TimersSpec` checks the file byte for byte against one the reference
  wrote. The only bytes that differ are offsets 96–99, the
  `SQLITE_VERSION_NUMBER` of the library that wrote the file (direct-sqlite
  bundles 3.45.0, CPython links 3.53.4), as they did before. A crash during
  the schema leaves a store that the next open quarantines either way: the
  reference's holds part of the schema, the port's none of it.

## Changes made in sibling packages

The interop tests found these differences, and they were fixed at the
source:

- **hamsterdan-github (DDL text).** The `CREATE TABLE` / `CREATE INDEX`
  literals in `Routing.hs` and `Webhooks.hs` are now the reference's,
  byte for byte, including indentation. SQLite stores the statement text
  in `sqlite_master`, so `webhooks.sqlite3` now matches too. The same
  holds in this package for `Runnable.hs`, `V5/Ingress.hs` and
  `V5/Timers.hs`.
- **hamsterdan-github (`Accept-Encoding`).** The production exchange no
  longer sends http-client's default `Accept-Encoding: gzip`, which httpx
  never sends.
- **hamsterdan-github (`Origin`, `exchangeAt`, `newPlainExchangeAt`).** These
  run the production exchange against another origin. The tests use them
  to point both hosts at one recording fake GitHub. See
  `../hamsterdan-github/DIVERGENCES.md` item 13.
