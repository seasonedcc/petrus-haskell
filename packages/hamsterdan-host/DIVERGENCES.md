# hamsterdan-host divergences

Wire and on-disk formats never diverge. Both hosts write the same bytes to:

- History;
- `webhooks.sqlite3`, `runnable.sqlite3` and the per-Instance stores;
- `binding.json`;
- the review requests;
- the timers.

The same holds for the HTTP responses (apart from item 1) and for the GitHub
requests. [PARITY.md](PARITY.md) lists the tests that hold both hosts to
this.

Below are the differences that remain, with their rationale.

## Observable

1. **An HTTP/1.0 request gets an `HTTP/1.0` status line.**
   - h11 always answers `HTTP/1.1`. Warp echoes the request's version, and
     no WAI hook can change that.
   - The headers, including the final `Connection: close`, are the same, and
     so is the body.
   - The surface test (`ApiSpec`) sends one HTTP/1.0 request and compares
     everything after the version.
   - GitHub's webhook deliveries and health probes use HTTP/1.1.
2. **uvicorn's own log lines are not written.**
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
3. **The agent composition is a stub.**
   - This package keeps the `AgentRunner` seam. The command line composes
     `unavailableRunner`, whose capabilities all refuse with
     `RuntimeError('no agent runtime is composed in this host')`, and
     `noAgentCustody`.
   - So `serve` does not read the Pi configuration, does not open
     `agent-routes.sqlite3`, and does not refuse to start over a bad agent
     configuration.
   - A delivery that needs an agent fails its Activity, and the reference's
     retry policy then applies. Every other route behaves as upstream.
   - The agent runtimes belong to `hamsterdan-agents` (package 5).
4. **An uncaught exception prints only its last traceback line.** The
   command line prints `Class: message` with exit status 1. The reference
   prints the whole Python traceback, which ends in that same line.
5. **Help and usage text has no color.**
   - CPython 3.14's `argparse` colors help when the stream is a terminal and
     `NO_COLOR` / `PYTHON_COLORS` allow it.
   - The port writes the plain text, which is what the reference writes to
     a pipe. That is the differential test's setting.
   - The width is the same: `COLUMNS`, else the terminal, else 80.
6. **Haskell-native failures get the nearest Python class name.** Where a
   failure class reaches History or a log line (`error_class=…`), the
   port's own exception types carry the reference's class names
   (`RuntimeError`, `ValueError`, `TypeError`, `PythonException name`).
   Failures that only Haskell can raise are named by `exceptionClass`:
   - `IOException` is `OSError`;
   - `ErrorCall` is `RuntimeError`;
   - `ArithException` is `ArithmeticError`;
   - `ArrayException` is `IndexError`;
   - anything else gets its Haskell type name.

## Internal (no observable difference)

- **Stores are closed when the application fails to construct.**
  `openApplication` closes the stores it had already opened when a later
  step fails. The reference leaves them for the garbage collector.
- **The engine policy's target is read through `unsafePerformIO`.** The
  reference's selection reads a mutable attribute, but the Petrus selection
  seam is pure. `currentTarget` depends on the candidates, so it is never
  floated out. The host writes the target only between drives, on the
  Instance's single thread.
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
- **`test_git_publish` derives the bounded diff with Git.** The reference
  test gets its binary diff from the Pi workspace provider, which is not
  ported (package 5). `GitPublishSpec` builds the same diff with
  `git diff --cached --binary --full-index` on a local clone.

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
