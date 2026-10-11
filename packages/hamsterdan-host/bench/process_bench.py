"""The reference side of the host's in-process rows of ``bench/Process.hs``.

Usage: ``python -I -B process_bench.py SPEC.json``

``bench/Process.hs`` writes SPEC.json: the template state directory (made by
the Haskell host over the V5 doubles: 20 PRs of ``owner/one``, 5 heads each),
the provider double's state at the end of it (each PR's head and comments), a
scratch directory, and the iterations per run of the effect rows. This
script prints ``ready``, then answers each ``run NAME`` line read from stdin
with one JSON line, ``{"check": ..., "seconds": ...}``: the wall time of the
timed region (``time.perf_counter``) and what both sides must agree on. The
setup of every run (the state copy, opening and closing the host, the
repository fixture and the patch) is outside the timed region.

The workloads:

* ``sweep-loaded``: ``HostService.sweep("periodic")`` over the 20 Instances
  after a warm-up sweep has loaded their Engines;
* ``sweep-unloaded``: the same sweep on a freshly opened host, which loads
  every Engine from its History;
* ``effects-comment``: ``CommentPublisher.immutable`` among 100 bot comments
  (lookup, then the create);
* ``effects-review-batch``: ``CommentPublisher.findings`` with 8 anchored
  findings among 100 issue and 100 review comments (one native review);
* ``effects-cas``: ``GitHubGraphQL.compare_and_swap_ref`` (the repository
  identity query and the ``updateRefs`` mutation);
* ``git-publish``: ``HostGitPublisher.publish`` of a host-derived patch
  through ``test_git_publish.py``'s ``LocalPublicationAuthority``, as in
  ``test_host_derived_patch_publishes_and_replays_through_complete_local_authority``.

The sweep runs over ``state_reference.py``'s doubles (``Clients``,
``V5Runner``) with ``V5Provider`` generalized to every PR number, as
``Process.hs``'s provider is.
"""

from __future__ import annotations

import contextlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE.parent / "differential"))
sys.path.insert(0, str(ROOT / "upstream" / "hamsterdan" / "tests" / "integration" / "host"))

import state_reference as doubles  # noqa: E402
import test_git_publish as git_fixtures  # noqa: E402
from petrus.motus.execution.archive import extract_workspace_archive, workspace_archive  # noqa: E402

from hamsterdan.agents import CodingRequest, CodingResult  # noqa: E402
from hamsterdan.github_app.effects import CommentPublisher  # noqa: E402
from hamsterdan.github_app.models import FindingPublication, WireResponse  # noqa: E402
from hamsterdan.github_app.transport import GitHubGraphQL  # noqa: E402
from hamsterdan.host import service as service_module  # noqa: E402
from hamsterdan.host.agenticus import AgentRouteStore, compose_agent  # noqa: E402
from hamsterdan.host.git_publish import HostGitPublisher  # noqa: E402
from hamsterdan.host.pi_workspace import GitPiWorkspaceProvider  # noqa: E402
from hamsterdan.host.service import HostService  # noqa: E402

DEVNULL = open(os.devnull, "w")  # noqa: SIM115 - lives for the whole run
BASE = "b" * 40
BOT = "hamsterdan-test[bot]"
HEAD = "a" * 40


# ---------------------------------------------------------------------------
# The V5 provider double for any PR number


class MultiProvider:
    """``state_reference.V5Provider`` for every PR of ``owner/one``."""

    def __init__(self, snapshot: dict) -> None:
        self.heads = {int(number): head for number, head in snapshot["heads"].items()}
        self.comments = {int(number): items for number, items in snapshot["comments"].items()}
        self.calls = 0

    def pages(self, path: str):
        self.calls += 1
        matched = re.fullmatch(r"/repos/owner/one/issues/(\d+)/comments\?per_page=100", path)
        return tuple(self.comments.get(int(matched.group(1)), ())) if matched else ()

    def request(self, method: str, path: str, body: object | None = None):
        self.calls += 1
        pull = re.fullmatch(r"/repos/owner/one/pulls/(\d+)(/requested_reviewers)?", path)
        if method == "GET":
            if pull and not pull.group(2) and int(pull.group(1)) in self.heads:
                number = int(pull.group(1))
                return WireResponse(
                    200,
                    {
                        "state": "open",
                        "draft": False,
                        "mergeable": True,
                        "mergeable_state": "clean",
                        "merged": False,
                        "html_url": f"https://example.test/owner/one/pull/{number}",
                        "user": {"login": "author"},
                        "head": {"sha": self.heads[number], "ref": "feature", "repo": {"full_name": "owner/one"}},
                        "base": {"sha": BASE, "ref": "main"},
                    },
                )
            if path == "/repos/owner/one/git/ref/heads/main":
                return WireResponse(200, {"object": {"sha": BASE}})
            if path in ("/repos/owner/one/rules/branches/main", "/repos/owner/one/branches/main/protection"):
                return WireResponse(404, {})
            prefix = f"/repos/owner/one/compare/{BASE}..."
            if path.startswith(prefix) and path[len(prefix) :] in self.heads.values():
                return WireResponse(200, {"status": "ahead", "behind_by": 0})
            if pull and pull.group(2) and int(pull.group(1)) in self.heads:
                return WireResponse(200, {"users": []})
            if path.startswith("/repos/owner/one/actions/workflows/.github%2Fworkflows%2Fci.yml/runs?"):
                return WireResponse(200, {"total_count": 0, "workflow_runs": []})
        if method == "POST":
            if path == "/graphql":
                return WireResponse(
                    200,
                    {
                        "data": {
                            "repository": {
                                "pullRequest": {
                                    "reviewThreads": {
                                        "nodes": [],
                                        "pageInfo": {"hasNextPage": False, "endCursor": None},
                                    }
                                }
                            }
                        }
                    },
                )
            issue = re.fullmatch(r"/repos/owner/one/issues/(\d+)/comments", path)
            if issue and int(issue.group(1)) in self.heads and isinstance(body, dict):
                identifier = 1 + sum(len(items) for items in self.comments.values())
                comment = {
                    "id": identifier,
                    "html_url": f"https://example.test/comments/{identifier}",
                    "body": body.get("body", ""),
                    "user": {"login": BOT},
                }
                self.comments.setdefault(int(issue.group(1)), []).append(comment)
                return WireResponse(201, comment)
        if method == "PATCH" and path.startswith("/repos/owner/one/issues/comments/") and isinstance(body, dict):
            identifier = int(path.rsplit("/", 1)[1])
            for items in self.comments.values():
                for comment in items:
                    if comment["id"] == identifier:
                        comment["body"] = body.get("body", "")
                        return WireResponse(200, comment)
        raise AssertionError(f"unexpected provider request: {method} {path} {body!r}")


# ---------------------------------------------------------------------------
# Sweeps


def sweep(spec: dict, loaded: bool) -> tuple[float, str]:
    root = Path(spec["scratch"]) / "py-sweep"
    root.parent.mkdir(parents=True, exist_ok=True)
    shutil.rmtree(root, ignore_errors=True)
    subprocess.run(("cp", "-R", spec["template"], str(root)), check=True)
    provider = MultiProvider(json.loads(spec["snapshot_text"]))
    service_module.GitHubKitTransport = lambda client: provider
    with contextlib.redirect_stdout(DEVNULL):
        composition = compose_agent()
        routes = AgentRouteStore(root / "test-agent-routes.sqlite3")
        routes.activate(composition, root / "applications")
        host = HostService(
            doubles.config(root),
            clients=doubles.Clients(),
            runner=doubles.V5Runner(),
            agent_composition=composition,
            agent_routes=routes,
        )
        try:
            if loaded:
                host.sweep("periodic")
            before = provider.calls
            start = time.perf_counter()
            reconciled = host.sweep("periodic")
            elapsed = time.perf_counter() - start
            calls = provider.calls - before
        finally:
            host.close()
    return elapsed, f"{reconciled} reconciled, {calls} provider calls"


# ---------------------------------------------------------------------------
# GitHub effects


def existing_comments(offset: int) -> tuple[dict, ...]:
    return tuple(
        {
            "id": offset + i,
            "html_url": f"https://example.test/comments/{offset + i}",
            "user": {"login": BOT},
            "body": f"prose {i}\n\n<!-- hamsterdan:finding operation=finding:old{i} head={HEAD} -->",
        }
        for i in range(1, 101)
    )


ISSUE_COMMENTS = existing_comments(0)
REVIEW_COMMENTS = existing_comments(1000)


class EffectsTransport:
    """100 issue and 100 review comments that never match, a created
    comment, an accepted review, and the GraphQL answers."""

    def pages(self, path: str):
        if path == "/repos/owner/one/issues/7/comments?per_page=100":
            return ISSUE_COMMENTS
        if path == "/repos/owner/one/pulls/7/comments?per_page=100":
            return REVIEW_COMMENTS
        return ()

    def request(self, method: str, path: str, body=None) -> WireResponse:
        if method == "POST" and path == "/repos/owner/one/issues/7/comments":
            return WireResponse(
                201,
                {
                    "id": 5000,
                    "html_url": "https://example.test/comments/5000",
                    "body": body.get("body", ""),
                    "user": {"login": BOT},
                },
            )
        if method == "POST" and path == "/repos/owner/one/pulls/7/reviews":
            return WireResponse(200, {"id": 6000, "html_url": "https://example.test/reviews/6000"})
        if method == "POST" and path == "/graphql":
            variables = body.get("variables", {})
            if isinstance(variables.get("input"), dict) and "clientMutationId" in variables["input"]:
                return WireResponse(
                    200, {"data": {"updateRefs": {"clientMutationId": variables["input"]["clientMutationId"]}}}
                )
            return WireResponse(200, {"data": {"repository": {"id": "R_kgDOBench"}}})
        raise AssertionError(f"unexpected request: {method} {path}")


TRANSPORT = EffectsTransport()
FINDINGS = tuple(FindingPublication(f"finding:b{i}", f"Finding {i} text", "src/app.py", 10 + i) for i in range(1, 9))


def publisher() -> CommentPublisher:
    return CommentPublisher(TRANSPORT, "owner/one", 7, BOT, lambda *_: None)


def timed_loop(iterations: int, action) -> tuple[float, str]:
    start = time.perf_counter()
    for _ in range(iterations - 1):
        action()
    check = action()
    return (time.perf_counter() - start) / iterations, check


# ---------------------------------------------------------------------------
# Git publication


def repository(tmp: Path) -> tuple[Path, Path, str, str]:
    """``test_git_publish.py``'s ``repository`` fixture (and, as the Haskell
    fixture does, ``commit.gpgsign=false``)."""
    git = git_fixtures.git
    remote = tmp / "remote.git"
    subprocess.run(("git", "init", "--bare", "-q", str(remote)), check=True)
    root = tmp / "work"
    subprocess.run(("git", "clone", "-q", str(remote), str(root)), check=True)
    git(root, "config", "user.name", "Test")
    git(root, "config", "user.email", "test@example.invalid")
    git(root, "config", "commit.gpgsign", "false")
    (root / "file.txt").write_text("one\n")
    git(root, "add", "file.txt")
    git(root, "commit", "-qm", "one")
    first = git(root, "rev-parse", "HEAD")
    git(root, "push", "-q", "origin", "HEAD:refs/heads/topic")
    (root / "file.txt").write_text("two\n")
    git(root, "commit", "-qam", "two")
    second = git(root, "rev-parse", "HEAD")
    return root, remote, first, second


def git_publish(spec: dict) -> tuple[float, str]:
    scratch = Path(spec["scratch"])
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=scratch) as directory:
        tmp = Path(directory).resolve()
        work, remote, head, _ = repository(tmp)
        receiver = GitPiWorkspaceProvider(tmp / "receiver")
        request = CodingRequest("change", "owner/repo", 7, 2, head, head, "hamsterdan/change/diagnostic")
        result_root = tmp / "settled"
        with receiver.open("coding", str(remote), request, "change:diagnostic:1") as prepared:
            extract_workspace_archive(prepared.archive, result_root)
            (result_root / "bounded.txt").write_text("qualified\n")
            diff, changed = prepared.reconcile(workspace_archive(result_root))
        result = CodingResult(
            "change",
            request.repository,
            request.pull_request,
            request.epoch,
            request.head,
            request.base,
            request.ref,
            "changed",
            "not_attempted",
            diff,
            changed,
            [{"command": "credential-free", "status": "passed"}],
            "Apply bounded diagnostic change",
        )
        authority = git_fixtures.LocalPublicationAuthority(work, remote, head)
        subject = HostGitPublisher(authority, str(remote))  # type: ignore[arg-type]
        start = time.perf_counter()
        published = subject.publish(
            result,
            operation="change:diagnostic",
            payload_digest="d" * 64,
            expected_head=head,
            base_head=head,
        )
        elapsed = time.perf_counter() - start
    return elapsed, f"recovered={published.recovered}"


def effects_comment(iterations: int) -> tuple[float, str]:
    subject = publisher()
    return timed_loop(iterations, lambda: subject.immutable("conversation", "reply:bench", 1, HEAD, "the answer").status)


def effects_review_batch(iterations: int) -> tuple[float, str]:
    subject = publisher()
    return timed_loop(
        iterations,
        lambda: ",".join(
            result.status for result in subject.findings(1, HEAD, FINDINGS, authority_operation="review:bench")
        ),
    )


def effects_cas(iterations: int) -> tuple[float, str]:
    graphql = GitHubGraphQL(TRANSPORT)

    def swap() -> str:
        graphql.compare_and_swap_ref("owner/one", "refs/heads/feature", HEAD, "c" * 40)
        return "ok"

    return timed_loop(iterations, swap)


def workloads(spec: dict) -> dict:
    iterations = spec["iterations"]
    return {
        "sweep-loaded": lambda: sweep(spec, True),
        "sweep-unloaded": lambda: sweep(spec, False),
        "effects-comment": lambda: effects_comment(iterations),
        "effects-review-batch": lambda: effects_review_batch(iterations),
        "effects-cas": lambda: effects_cas(iterations),
        "git-publish": lambda: git_publish(spec),
    }


def main() -> None:
    spec = json.loads(Path(sys.argv[1]).read_text())
    spec["snapshot_text"] = json.dumps(spec["snapshot"])
    cases = workloads(spec)
    print("ready", flush=True)
    for line in sys.stdin:
        command, _, name = line.strip().partition(" ")
        if command != "run":
            raise SystemExit(f"unknown command {line!r}")
        seconds, check = cases[name]()
        print(json.dumps({"check": check, "seconds": seconds}), flush=True)


if __name__ == "__main__":
    main()
