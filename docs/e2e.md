# End-to-end runbook: both Hamsterdan hosts against real GitHub Apps

This is the runbook for tier C of
[docs/hamsterdan.md §5.2](hamsterdan.md#52-comparison-procedure). The
reference Python host and the Haskell host run side by side. Each has its
own GitHub App and its own public copy of the fixture repository. The same
two people drive the same scenarios on both, and the checkpoints are
compared after normalizing.

Tiers A and B run offline and need nothing from you (see
[Offline checks](#offline-checks)). All tier C tooling is in place and tested
against fakes. What remains is the inputs listed below, which only you can
provide, and running the commands.

The tooling lives in `scripts/e2e` and in `packages/hamsterdan-e2e` (see its
[README](../packages/hamsterdan-e2e/README.md)). The plan placed it in
`interop/hamsterdan/`.

Two safety properties hold throughout:

- Every command that acts on GitHub or on the hosts takes `--dry-run`, which
  prints exactly what would run, with secrets shown as `<redacted>`, and
  runs nothing.
- Nothing creates tunnels, webhooks or Apps on its own. The App is
  registered by an organization owner in a browser.

## What you must provide

1. **An organization you own** (the config assumes `seasonedcc`), and an
   owner of it who can approve two App registrations in a browser.
2. **Two GitHub accounts:**
   - an *author/operator*, who opens and closes the PRs, comments and
     merges;
   - a distinct *reviewer*, who requests changes, approves and leaves
     inline comments.

   The author must be able to create public repositories and rulesets in
   the organization. The reviewer must be able to review there (a member
   with read access is enough).

   Each account needs its own `gh` login in its own config directory:

   ```
   GH_CONFIG_DIR=~/.config/gh-e2e-author   gh auth login
   GH_CONFIG_DIR=~/.config/gh-e2e-author   gh auth setup-git
   GH_CONFIG_DIR=~/.config/gh-e2e-reviewer gh auth login
   ```

   The scripts use these two config directories for every GitHub action,
   never your everyday `gh` login.
3. **Two public HTTPS URLs**, one per host. They must forward
   `POST /github/webhooks` to `127.0.0.1:8101` (Python) and `127.0.0.1:8102`
   (Haskell). A cloudflared or ngrok tunnel, or any reverse proxy, works.
   The scripts never start one.
4. **An LLM API key** for a provider/model pair from the Pi catalog (§1.8).
   The config's default is `openai` / `gpt-5.6-sol`, as production uses.
   It is read from the environment as `HAMSTERDAN_PI_API_KEY` and is never
   written to disk.
5. **The agent runtime:**
   - Node 22.19.0;
   - Pi 0.83.0 (`@mariozechner/pi-coding-agent`), with absolute paths to
     its `dist/cli.js`, its package root and the `node` binary.
6. **Tools on PATH:**
   - `git`;
   - `gh` 2.48 or later (it needs `gh api --slurp`);
   - `python3` 3.9 or later (to run `scripts/e2e`);
   - a `python`, which the fixture's `tools/scenario_control.py` is run
     with by the operator's `create`;
   - the GHC toolchain (`cabal list-bin` finds the Haskell binaries);
   - `scripts/upstream-python hamsterdan`, which provisions the pinned
     reference.

That is everything. No database server, container or cloud account is
needed.

## The commands, in order

All paths below are relative to the repository root. A run's files go under
`e2e-work/` (git-ignored):

- the config;
- the fixture checkouts;
- the App credentials, at mode 0600;
- the state directories and logs;
- the run records;
- the captures.

Build first:

```
cabal build hamsterdan-e2e:exes hamsterdan-export:exes
scripts/upstream-python hamsterdan >/dev/null
```

### 1. Configure

```
scripts/e2e init                # writes e2e-work/config.json
$EDITOR e2e-work/config.json
```

Fill in:

- `actors.author.login`, `actors.reviewer.login` and their
  `gh_config_dir`;
- `watch_authors` (the author's login);
- the `pi` paths;
- each side's `public_url`.

Keep `repository`, `app_slug` and `port` unless they are already taken.

Look at any step before running it:

```
scripts/e2e prepare-repos --dry-run
scripts/e2e manifests --dry-run
scripts/e2e start-hosts --dry-run
scripts/e2e run-scenario --scenario hero-review --dry-run
scripts/e2e scenarios           # every scenario's steps
```

### 2. Register the two Apps (manifest flow)

```
scripts/e2e manifests
```

This writes `e2e-work/manifests/{python,haskell}.json` and an `.html` form
for each. The manifests ask for:

- exactly the permissions of §5.1: Administration read, Actions read,
  Contents write, Issues write, Pull requests write, Metadata read;
- exactly the six events of §5.1;
- a private App;
- an active webhook at `<public_url>/github/webhooks`.

As the organization owner:

1. Open each `.html` file in a browser and submit it. GitHub opens
   `https://github.com/organizations/<org>/settings/apps/new` with the
   manifest filled in.
2. Confirm. GitHub redirects to
   `http://127.0.0.1:9/hamsterdan-e2e-manifest?code=…&state=hamsterdan-e2e-<side>`.
   Nothing listens there, on purpose. Copy the `code` from the address bar.
   It expires after an hour.
3. Convert each code:

```
scripts/e2e convert-manifest --side python  --code <code>
scripts/e2e convert-manifest --side haskell --code <code>
```

The App id, slug, client id, private key and webhook secret are saved to
`e2e-work/credentials/<side>.json`, mode 0600. If GitHub assigned a different
slug, the command says so: put that slug in `sides.<side>.app_slug` before
the next step.

### 3. Create the two fixture repositories

```
scripts/e2e prepare-repos
```

For each side this:

1. Clones the fixture source (`HBNetwork/demo-pr-readiness`) at
   `a83e9223f7ffc6b0af919b0b8261fa2578261b41` and verifies the commit.
2. Rebinds `.github/workflows/rerun-broker.yml` and `tools/rerun_broker.py`
   to the side's bot login (`hamster-dan-py[bot]` / `hamster-dan-hs[bot]`)
   and repository, and commits that on `main`. Any `HBNetwork` or
   `hamster-dan[bot]` left over stops it.
3. Creates the public repository as the author and pushes.
4. Adds the branch ruleset: one approval, thread resolution, and strict
   required checks `lint`, `type`, `unit`, `build` and `integration`.
5. Writes `e2e-work/fixtures/<side>.json`. This holds the repository, the
   organization and repository ids, the App slug, the hero reviewer and the
   rebound broker digests. The operator of that side reads it, through
   `e2e_operator.py` (Python) or `hamsterdan-e2e-operator` (Haskell).

Then install each App **on its own repository only**:

```
https://github.com/apps/hamster-dan-py/installations/new   → seasonedcc/demo-pr-readiness-py
https://github.com/apps/hamster-dan-hs/installations/new   → seasonedcc/demo-pr-readiness-hs
```

Two Apps on one repository would both comment and both trigger the broker.

### 4. Start the hosts

Start the tunnels first, then:

```
export HAMSTERDAN_PI_API_KEY=…
scripts/e2e start-hosts                       # both; --side python|haskell for one
```

For each side, this:

1. Writes `e2e-work/installations/<side>.toml`.
2. Sets the §1.8 environment:
   - App id, slug, client id, key and secret;
   - the installations file;
   - `HAMSTERDAN_WATCH_AUTHORS`;
   - `HAMSTERDAN_WORKFLOW_PATH=.github/workflows/ci.yml`;
   - `HAMSTERDAN_REMINDER_SECONDS=300`;
   - the Pi variables;
   - the state path;
   - `HAMSTERDAN_HOST=127.0.0.1` and the side's port.
3. Runs `validate`.
4. Starts `serve` in the background (log and pid in `e2e-work/logs/<side>/`).
5. Waits for `/healthz`.

The Python side is `e2e_host.py` under the pinned reference. The Haskell
side is `hamsterdan-e2e-host`. Both are the production command lines, with
two optional additions:

- `HAMSTERDAN_E2E_AGENTS`: the deterministic agent, below;
- `HAMSTERDAN_E2E_RECORD`: on the reference, the tape of the run.

Check that each App's webhook deliveries arrive (App settings → Advanced)
before you run a scenario.

### 5. Run the scenarios

```
scripts/e2e run-scenario --scenario clean-green
scripts/e2e run-scenario --scenario first-attempt-flake
scripts/e2e run-scenario --scenario hero-review
scripts/e2e run-scenario --scenario draft-ready
scripts/e2e run-scenario --scenario collaboration-approval
scripts/e2e run-scenario --scenario stale-base
scripts/e2e run-scenario --scenario true-conflict
```

Each step runs on both repositories at the same time, as the same actor.
The steps are:

- `create` / `branch`, which open the PR;
- reviews, comments and merges;
- waits on `operator inspect`, App commits or replies (every 30 s, for
  at most 30 min);
- `inspect-authority` expectations;
- the checkpoint captures;
- a final close without merging.

`hero-review` is the three-actor repair:

1. The reviewer requests changes.
2. The author comments `@<slug> please fix all three findings`.
3. An App commit arrives.
4. The author comments `@<slug> status`.
5. The reviewer approves.

It is captured at `findings`, `repaired`, `status` and `final`.

A run's PR numbers are kept in `e2e-work/runs/<scenario>/<side>.json`. If a
step fails (for example a wait times out), fix the cause and resume with
`--from <step>`.

To capture by hand at any point:

```
scripts/e2e capture --scenario hero-review --checkpoint extra [--inspect=--expect-readiness --inspect=absent] [--authority non-draft]
```

### 6. Stop, and compare

```
scripts/e2e stop-hosts --into hero-review/final   # keeps the shutdown output in that capture
scripts/e2e compare --scenario hero-review        # every checkpoint; --checkpoint C for one
```

The hosts get SIGTERM. Both exit by that signal, as uvicorn does; this was
checked by the rehearsal. Their output while stopping is kept as
`e2e-work/logs/<side>/shutdown.log` and, with `--into`, in that capture, for
the known Pi cleanup defect below.

`compare` writes `comparison.json` next to each checkpoint's two captures.
It prints `same` or `DIFFERENT` and exits 1 on any difference.

### Agent determinism: record once, then carry

The comparison is exact on agent output only when both hosts get the same
agent results (§5.2 tier C step 2). Do two passes.

**First pass: the real agent.**

```
scripts/e2e start-hosts --record hero-review    # the reference records e2e-work/tapes/hero-review
scripts/e2e run-scenario --scenario hero-review
scripts/e2e stop-hosts --into hero-review/final
scripts/e2e compare --scenario hero-review --real-agent
```

This is the nondeterministic smoke pass. With `--real-agent`, the
comparator tolerates the prose of findings and replies, and the finding
order.

**Second pass: the deterministic agent.** Set `"agents_tape":
"e2e-work/tapes/hero-review"` in the config, then:

```
scripts/e2e start-hosts
scripts/e2e run-scenario --scenario hero-review
scripts/e2e stop-hosts --into hero-review/final
scripts/e2e compare --scenario hero-review
```

Both hosts now answer every agent call from the recorded results. Each call
is keyed by `(kind, operation shape, attempt)` and carried to the asking
repository, PR and SHAs. A call the tape has no answer for fails as an
agent protocol error, which shows up as a failed Activity, and the
comparison reports it. The Pi runtime is still configured, but it is not
called.

The tape is also a tier B tape (`hamsterdan-e2e-tape/1`, live-shaped). You
can replay it offline into both hosts with the tier B tools, with
`--sticky-reads` and `--allow-unused`, as `TierCSpec`'s live-shaped cases
do.

### Clean up

Close any PRs left open; every scenario closes its own unmerged. Delete
the two repositories and the two Apps when you are done. The credentials
live only in `e2e-work/credentials/`.

## What a capture holds

`e2e-work/captures/<scenario>/<checkpoint>/<side>/`:

| File | From |
| --- | --- |
| `meta.json` | side, repository, organization, App slug, PR, checkpoint |
| `inspect.json` | operator `inspect --pr N` (plus the step's flags) |
| `inspect-authority.json` | `{expectation: inspect-authority output}` for the run's authority steps |
| `github/pull.json` | `GET /repos/R/pulls/N` |
| `github/issue-comments.json`, `review-comments.json`, `reviews.json`, `commits.json` | the paginated REST lists (flattened) |
| `github/threads.json` | GraphQL `reviewThreads` (location, resolved, resolver, first comment) |
| `github/runs.json` | `GET /repos/R/actions/runs?event=pull_request` |
| `github/trees/<sha>.json` | each App commit's recursive tree |
| `healthz.json` | the host's `/healthz` |
| `export/` | the evidence package (`python -m hamsterdan.host.export` / `hamsterdan-export`) |
| `shutdown.log` | only with `stop-hosts --into` |

## What the comparison requires

The comparator is `packages/hamsterdan-e2e/python/compare_tier_c.py`, which
documents every rule. It implements §5.2 tier C step 5.

**Normalization.** On both sides it replaces:

- the repository, organization, App slug, bot login and `@mention`;
- SHAs and their short forms;
- 64-hex digests;
- UUIDs and timestamps;
- every id GitHub assigns (comments, reviews, runs, jobs, PR numbers in
  URLs and markers, installation and repository ids in operation
  identities).

**What must be equal:**

- **App comments by kind** (summary, finding, reminder, readiness, reply,
  rerun). Normalized bodies and markers must be identical. Both sides must
  have the same final summary body, exactly one summary comment, and at
  most one readiness advisory per head.
- **Reviews and threads:** the App's native reviews and inline comment
  locations, the humans' reviews, and the same threads resolved.
- **Commits:** the App's commits have the same tree, parent shape,
  trailers, author and committer. The tree is compared blob by blob,
  except for the two broker files each copy rebinds.
- **Sequencing:** on each side the summary comes before any other App
  effect.
- **History shape:** per-transition firing counts, Activity counts by name,
  and terminal variants.
- **Health:** `inspect` passes every check, `/healthz` is `ok` with no
  failed delivery, and there is no failed or pending Activity.
  `--allow-failed-activities` lifts the last rule for a fault-injection
  run; the two sides must still agree.

**Tolerated**, and only this, as upstream's PR84-vs-PR83 comparison
tolerates:

- timing, and the order of comments other than summary-first;
- the counts of summary updates and deferrals. These are the `dash.publish`,
  `dash.fold*` and `review.fold_round_moved` firings, the `DashLanded`,
  `DashDeferred` and `RoundMoved` variants, and the `dash_gate` Activity.
  They are reported separately under `tolerated`;
- with `--real-agent` only, agent prose and finding order.

**Known upstream defects must reproduce identically** (PR85 §1c1, §1c2).
The report shows both under `known_defects`, and a difference between the
sides fails:

- `status_reply_claims_approval`: a status reply words the approval-gate
  flag as an approval while no approving review exists (expect it at
  `hero-review/status`);
- `pi_cleanup_uncertain`: `host-cleanup-uncertain` in the shutdown output
  (needs `stop-hosts --into`).

`test_compare_tier_c.py` holds the comparator to these rules on synthetic
captures, both ones that must pass and ones that must fail.

## Offline checks

Run these before spending any credentials. None of them touches GitHub.

```
scripts/e2e rehearse
cabal test hamsterdan-e2e
```

`rehearse` starts both hosts against a local fake GitHub, with the same
environment `start-hosts` builds. It sends one signed
webhook, then stops them. It reports `/healthz`, the webhook answer, the
exit status, the GitHub requests, any secret left on disk, and the
reference's recorded tape.

`cabal test hamsterdan-e2e` runs tier B and the tier C tooling against
fakes.

## Limits

- **Tolerances are untested live.** The tolerance sets are upstream's
  PR84-vs-PR83 list, mapped onto History names. A live run may show a
  timing-dependent count that is not on the list. Widen the list only
  when the upstream comparison would also have accepted the difference,
  and record it here.
- **Fault injection has no plan.** `HAMSTERDAN_QUALIFICATION_FAULT` (§5.2
  tier C step 3) is not scripted as a scenario. Start both hosts with the
  same fault in the environment, run a scenario, and compare with
  `--allow-failed-activities`.
- **Lifecycle plans are unexercised live.** The steps of the lifecycle
  plans (draft→ready, collaboration, stale base, true conflict) have run
  only as dry runs. Their GitHub calls are plain `gh`, but the order and
  the waits have not met real GitHub.
- **The carried agent may meet new keys.** A live run whose review rounds
  differ from the recorded run's will ask questions the tape has no answer
  for. Those calls fail, and the comparison reports them.
- **The manifest code is copied by hand.** Nothing listens for the
  manifest redirect, so you copy the code from the browser.
