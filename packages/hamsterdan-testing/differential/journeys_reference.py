"""Run the reference's deterministic readiness journeys, for byte comparison.

Usage:

    python -I -B journeys_reference.py journey NAME ROOT
    python -I -B journeys_reference.py drive ROOT < document.json
    python -I -B journeys_reference.py dump ROOT

``journey`` runs one of the eleven journeys of
``tests/integration/host/test_readiness_scenarios.py`` through the upstream
``run_<NAME>`` function itself, unchanged. Four determinism seams are
applied around it, and nothing else changes:

- The delivery ids the module draws from ``uuid.uuid4()`` come from a
  counter: ``00000000-0000-0000-0000-000000000001``, then ``...2``, and so on.
- ``HostService`` gets the fixed clock ``CLOCK``.
- The Git fixtures commit at a fixed date with no global or system Git
  configuration.
- The allowed intents a conversation request declares come in source order
  (``intent_order``).

The command then prints one JSON document with two members. ``result`` is
the ``JourneyResult``, with the runner's calls and results as plain JSON.
``state`` is every file under ROOT, read back the way ``dump`` reads it.

``drive`` runs the same journey in phases, as the second half of
section 5.2 of docs/hamsterdan.md asks: "one language runs the first half of
a journey and the other runs the second half". The document names the
journey, the phases to run, and the ``carry`` a previous drive printed.
``carry`` is the provider, the runner and the journey's own snapshots.
Each drive opens a host on ROOT, runs its phases, closes the host and
prints the new ``carry``. The drive that runs the last phase also prints
``result``.

``dump`` prints every file under ROOT in a comparable form. SQLite databases
become their schema and their sorted rows. Every other file becomes text.
Two things are normalized, and neither is in History: the per-process
Worker claimant identity, and the wall-clock milliseconds the Local Dispatch
stamps on its tasks (Petrus Motus reads the system clock there, with no seam
in either host).

``ReadinessScenariosSpec`` runs the same journeys through the Haskell host
and compares the documents.
"""

from __future__ import annotations

import functools
import importlib.util
import json
import os
import re
import sqlite3
import sys
import uuid
from dataclasses import asdict, fields, is_dataclass
from itertools import count
from pathlib import Path
from types import SimpleNamespace

import pytest

import hamsterdan
from hamsterdan.github_app.models import InstallationInventory
from hamsterdan.host import git_publish as git_publish_module
from hamsterdan.host.agenticus import AgentRouteStore, compose_agent
from hamsterdan.host.git_publish import GitPublishResult, GitReconciliation, HostGitPublisher, _git_environment
from hamsterdan.host.service import HostService

CLOCK = 1786838400.0
GIT_DATE = "2001-01-01T00:00:00Z"
APPLICATION_KEY = (44, 31, 7)

JOURNEYS: dict[str, dict[str, object]] = {
    "clean_green": {"rerun_conclusion": None},
    "first_attempt_flake": {"rerun_conclusion": "success"},
    "persistent_ci_regression": {"rerun_conclusion": "failure"},
    "seeded_review_finding": {"rerun_conclusion": None, "seeded_finding": True},
    "conversational_change": {"rerun_conclusion": None, "conversational_change": True},
    "agent_repair": {"rerun_conclusion": "failure", "agent_repair": True},
    "hero_review": {"rerun_conclusion": None, "hero_review": True},
    "draft_ready": {"rerun_conclusion": None, "draft_ready": True},
    "stale_base_update": {"rerun_conclusion": None, "update_base": True},
    "true_conflict_resolution": {"rerun_conclusion": None, "resolve_conflict": True},
    "collaboration_approval": {"rerun_conclusion": None, "collaboration": True},
}


def scenarios_module():
    path = Path(hamsterdan.__file__).resolve().parents[2] / "tests" / "integration" / "host" / "test_readiness_scenarios.py"
    spec = importlib.util.spec_from_file_location("readiness_scenarios_reference", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def git_determinism() -> None:
    os.environ.update(
        {
            "GIT_AUTHOR_DATE": GIT_DATE,
            "GIT_COMMITTER_DATE": GIT_DATE,
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
        }
    )


def intent_order(monkeypatch: pytest.MonkeyPatch) -> None:
    """``_ALLOWED`` with its mutations in source order.

    The reference spreads ``_MUTATIONS``, a ``frozenset`` of strings, into
    ``_ALLOWED``, so the last three allowed intents a conversation request
    declares come in the process's string-hash order (``-I`` ignores
    ``PYTHONHASHSEED``). The Haskell host declares them in source order:
    ``change``, ``update_base``, ``resolve_conflict``.
    """
    from hamsterdan.host.v5 import application

    selected = tuple(name for name in application._ALLOWED if name not in application._MUTATIONS)
    monkeypatch.setattr(application, "_ALLOWED", (*selected, "change", "update_base", "resolve_conflict"))


def counted_uuid4(start: int = 1):
    numbers = count(start)
    state = {"next": start}

    def uuid4() -> uuid.UUID:
        value = next(numbers)
        state["next"] = value + 1
        return uuid.UUID(int=value)

    return uuid4, state


def plain(value: object) -> object:
    if is_dataclass(value) and not isinstance(value, type):
        return plain(asdict(value))
    if isinstance(value, dict):
        return {str(key): plain(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [plain(item) for item in value]
    if isinstance(value, (set, frozenset)):
        return sorted(plain(item) for item in value)
    return value


RUNNER_FIELDS = (
    "review_entries",
    "reviews",
    "review_results",
    "conversation_calls",
    "conversation_results",
    "code_calls",
    "code_results",
    "coding_status",
    "seeded_finding",
    "conversational_change",
    "update_base",
    "resolve_conflict",
    "finding_head",
    "review_findings",
    "codes",
    "conversations",
)


def runner_json(runner) -> dict[str, object]:
    return {name: plain(getattr(runner, name)) for name in RUNNER_FIELDS}


def result_json(result) -> dict[str, object]:
    document = {}
    for field in fields(result):
        value = getattr(result, field.name)
        document[field.name] = runner_json(value) if field.name == "runner" else plain(value)
    return document


# ---------------------------------------------------------------------------
# journey: the upstream run_<NAME>, unchanged


def journey(name: str, root: Path) -> dict[str, object]:
    module = scenarios_module()
    git_determinism()
    uuid4, _ = counted_uuid4()
    with pytest.MonkeyPatch.context() as monkeypatch:
        monkeypatch.setattr(module, "uuid", SimpleNamespace(uuid4=uuid4))
        monkeypatch.setattr(module, "HostService", functools.partial(HostService, clock=lambda: CLOCK))
        intent_order(monkeypatch)
        result = getattr(module, f"run_{name}")(root, monkeypatch)
    return {"result": result_json(result), "state": dump(root)}


# ---------------------------------------------------------------------------
# drive: the same journey in phases, each drive its own host

PROVIDER_FIELDS = (
    "head",
    "base",
    "state",
    "draft",
    "merged",
    "mergeable",
    "mergeable_state",
    "rerun_conclusion",
    "run_id",
    "run_attempt",
    "run_status",
    "run_conclusion",
    "rerun_requests",
    "behind_by",
    "git_reconciliations",
    "git_publications",
    "comments",
    "review_comments",
    "requested_reviewers",
    "human_reviews",
    "review_threads",
    "cas_updates",
    "git_boundary_events",
)


def provider_json(provider) -> dict[str, object]:
    document = {name: plain(getattr(provider, name)) for name in PROVIDER_FIELDS}
    document["created_git_objects"] = sorted(provider.created_git_objects)
    document["calls"] = plain(provider.calls)
    document["requests"] = plain(provider.requests)
    document["writes"] = plain(provider.writes)
    document["git_work"] = None if provider.git_work is None else str(provider.git_work)
    document["git_remote"] = None if provider.git_remote is None else str(provider.git_remote)
    return document


def restore_provider(module, document: dict[str, object]):
    provider = module.ScenarioProvider(
        rerun_conclusion=document["rerun_conclusion"],
        head=document["head"],
        base=document["base"],
        git_work=None if document["git_work"] is None else Path(document["git_work"]),
        git_remote=None if document["git_remote"] is None else Path(document["git_remote"]),
    )
    for name in PROVIDER_FIELDS:
        setattr(provider, name, document[name])
    provider.created_git_objects = set(document["created_git_objects"])
    provider.calls = [tuple(item) for item in document["calls"]]
    provider.requests = [tuple(item) for item in document["requests"]]
    provider.writes = [tuple(item) for item in document["writes"]]
    return provider


def restore_runner(module, document: dict[str, object]):
    runner = module.ScenarioRunner(
        coding_status=document["coding_status"],
        seeded_finding=document["seeded_finding"],
        conversational_change=document["conversational_change"],
        update_base=document["update_base"],
        resolve_conflict=document["resolve_conflict"],
        finding_head=document["finding_head"],
        review_findings=document["review_findings"],
    )
    for name in RUNNER_FIELDS:
        setattr(runner, name, document[name])
    return runner


def phases(flags: dict[str, object]) -> list[str]:
    """The journey's phases in ``_run_journey``'s order."""
    selected = ["open"]
    if flags.get("draft_ready"):
        selected.append("draft")
    if flags.get("update_base") or flags.get("resolve_conflict"):
        selected.append("stale_base")
    if flags.get("collaboration"):
        selected.append("collaboration")
    selected.append("follow_up")
    return selected


class Drive:
    """One host lifetime over a span of a journey's phases."""

    def __init__(self, module, name: str, root: Path, carry: dict[str, object] | None, monkeypatch) -> None:
        self.module, self.name, self.root = module, name, root
        flags = JOURNEYS[name]
        self.flags = flags
        self.rerun_conclusion = flags.get("rerun_conclusion")
        self.base_mutation = bool(flags.get("update_base") or flags.get("resolve_conflict"))
        self.repairing = bool(flags.get("agent_repair")) or self.base_mutation
        start = 1 if carry is None else int(carry["next_uuid"])
        self.uuid4, self.uuid_state = counted_uuid4(start)
        if carry is None:
            self.fresh()
        else:
            self.provider = restore_provider(module, carry["provider"])
            self.runner = restore_runner(module, carry["runner"])
            self.snapshots = dict(carry["snapshots"])
        self.patch(monkeypatch)
        composition = compose_agent()
        routes = AgentRouteStore(root / "agent-routes.sqlite3")
        routes.activate(composition, root / "applications")
        self.host = HostService(
            module.config(root),
            clients=module.Clients(),
            runner=self.runner,
            agent_composition=composition,
            agent_routes=routes,
            clock=lambda: CLOCK,
        )
        if carry is None:
            self.host.registry.reconcile((InstallationInventory(44, 23, ((31, "owner/repo"),)),))

    def fresh(self) -> None:
        module, flags = self.module, self.flags
        git_work = git_remote = None
        initial_base, initial_head = module.BASE, module.HEAD
        if flags.get("resolve_conflict"):
            git_work, git_remote, initial_base, initial_head = module.conflict_repository(self.root / "git-world")
        elif flags.get("agent_repair") or flags.get("update_base"):
            git_work, git_remote, initial_base, initial_head = module.repair_repository(self.root / "git-world")
        provider = module.ScenarioProvider(
            rerun_conclusion=self.rerun_conclusion,
            head=initial_head,
            base=initial_base,
            git_work=git_work,
            git_remote=git_remote,
        )
        provider.draft = bool(flags.get("draft_ready"))
        if flags.get("collaboration"):
            provider.human_reviews = []
            provider.review_threads = []
        conversational = bool(flags.get("conversational_change"))
        self.provider = provider
        self.runner = module.ScenarioRunner(
            coding_status="changed"
            if conversational or flags.get("agent_repair") or self.base_mutation
            else "unchanged"
            if self.rerun_conclusion == "failure"
            else None,
            seeded_finding=bool(flags.get("seeded_finding") or flags.get("agent_repair") or flags.get("hero_review")),
            conversational_change=conversational,
            update_base=bool(flags.get("update_base")),
            resolve_conflict=bool(flags.get("resolve_conflict")),
            finding_head=initial_head if flags.get("agent_repair") else None,
            review_findings=module.HERO_FINDINGS if flags.get("hero_review") else None,
        )
        self.snapshots = {"initial_head": initial_head, "initial_base": initial_base}

    def patch(self, monkeypatch) -> None:
        provider, flags = self.provider, self.flags
        monkeypatch.setattr("hamsterdan.host.service.GitHubKitTransport", lambda client: provider)
        if self.repairing:
            git_environment = _git_environment() | {
                "GIT_CONFIG_COUNT": "3",
                "GIT_CONFIG_KEY_2": f"url.{provider.git_remote.as_uri()}.insteadOf",
                "GIT_CONFIG_VALUE_2": "https://github.com/owner/repo.git",
            }
            monkeypatch.setattr("hamsterdan.host.git_publish._git_environment", lambda: dict(git_environment))
            original_reconcile = HostGitPublisher.reconcile
            original_publish = HostGitPublisher.publish

            def observed_reconcile(publisher, **kwargs):
                reconciliation = original_reconcile(publisher, **kwargs)
                observed = {**kwargs, "result": asdict(reconciliation)}
                provider.git_reconciliations.append(observed)
                provider.git_boundary_events.append({"kind": "reconcile", **observed})
                return reconciliation

            def observed_publish(publisher, result, **kwargs):
                publication = original_publish(publisher, result, **kwargs)
                observed = {**kwargs, "result": asdict(result), "outcome": asdict(publication)}
                provider.git_publications.append(observed)
                provider.git_boundary_events.append({"kind": "publish", **observed})
                return publication

            monkeypatch.setattr(HostGitPublisher, "reconcile", observed_reconcile)
            monkeypatch.setattr(HostGitPublisher, "publish", observed_publish)
        elif self.rerun_conclusion == "failure" or flags.get("conversational_change"):
            conversational = bool(flags.get("conversational_change"))
            module = self.module

            def reconcile(_publisher, **kwargs):
                provider.git_reconciliations.append(dict(kwargs))
                return GitReconciliation("absent", provider.head)

            def publish(_publisher, result, **kwargs):
                provider.git_publications.append({**kwargs, "result": asdict(result)})
                if not conversational:
                    raise AssertionError("an unchanged repair must never reach Git publication")
                assert provider.head == module.HEAD
                provider.head = module.NEW_HEAD
                provider.run_id = 102
                provider.run_attempt = 1
                provider.run_status = "in_progress"
                provider.run_conclusion = None
                return GitPublishResult(module.NEW_HEAD)

            monkeypatch.setattr(HostGitPublisher, "reconcile", reconcile)
            monkeypatch.setattr(HostGitPublisher, "publish", publish)

    # -- the journey's moves, as _run_journey makes them

    def external_state(self) -> tuple[object, ...]:
        provider, runner = self.provider, self.runner
        return (
            tuple(map(repr, provider.calls)),
            tuple(map(repr, provider.requests)),
            tuple(map(repr, provider.writes)),
            repr(runner.reviews),
            repr(runner.review_results),
            repr(runner.conversation_calls),
            repr(runner.conversation_results),
            repr(runner.code_calls),
            repr(runner.code_results),
            runner.conversations,
            repr(provider.git_reconciliations),
            repr(provider.git_publications),
            repr(provider.cas_updates),
            tuple(sorted(provider.created_git_objects)),
            repr(provider.git_boundary_events),
        )

    def unresolved(self) -> bool:
        """``host._apps[(44, 31, 7)].has_unresolved_publication()``.

        A resumed drive whose phases deliver nothing never loads the
        application; an unloaded application holds no publication.
        """
        application = self.host._apps.get(APPLICATION_KEY)
        return application is not None and application.has_unresolved_publication()

    def converge(self) -> None:
        for _ in range(50):
            before = self.external_state()
            processed = self.host.pump()
            if processed == 0 and before == self.external_state() and not self.unresolved():
                return
        raise AssertionError("parity journey host did not converge")

    def deliver(self, body: bytes, event: str = "pull_request") -> tuple[str, str | None]:
        delivery = str(self.uuid4())
        receipt = self.host.custody.receive(self.module.signed(body, delivery, event).items(), body)
        assert receipt.disposition == "accepted"
        before = self.host.custody.status(delivery)
        pending = next(item for item in self.host.custody.pending() if item.delivery_id == delivery)
        self.host.process(pending)
        self.converge()
        return delivery, before

    def comments(self) -> list[dict[str, object]]:
        return [dict(item) for item in self.provider.comments]

    def phase_open(self) -> None:
        module = self.module
        body = module.envelope("opened" if self.flags.get("draft_ready") else "synchronize")
        delivery, before = self.deliver(body)
        self.snapshots["delivery"] = delivery
        self.snapshots["custody_before"] = before

    def phase_draft(self) -> None:
        host, provider, runner = self.host, self.provider, self.runner
        draft_custody_after = host.custody.status(self.snapshots["delivery"])
        draft_custody_counts = host.custody.counts()
        draft_comments = self.comments()
        draft_review_comments = [dict(item) for item in provider.review_comments]
        draft_provider_writes = list(provider.writes)
        draft_agent_counts = (runner.review_entries, runner.codes, runner.conversations)
        draft_rerun_requests = provider.rerun_requests
        provider.draft = False
        ready_delivery, ready_custody_before = self.deliver(self.module.envelope("ready_for_review"))
        self.snapshots["draft_phase"] = plain(
            self.module.DraftPhase(
                self.snapshots["custody_before"],
                draft_custody_after,
                draft_custody_counts,
                draft_comments,
                draft_review_comments,
                draft_provider_writes,
                draft_agent_counts,
                draft_rerun_requests,
                ready_custody_before,
                host.custody.status(ready_delivery),
            )
        )

    def phase_stale_base(self) -> None:
        module, provider = self.module, self.provider
        initial_base, initial_head = self.snapshots["initial_base"], self.snapshots["initial_head"]
        if self.flags.get("resolve_conflict"):
            current_base = module.advance_conflicting_base_repository(
                provider.git_work, provider.git_remote, initial_base, initial_head
            )
        else:
            current_base = module.advance_base_repository(provider.git_work, provider.git_remote, initial_base, initial_head)
        provider.base = current_base
        provider.behind_by = 1
        if self.flags.get("resolve_conflict"):
            provider.mergeable, provider.mergeable_state = False, "dirty"
        stale_delivery, stale_custody_before = self.deliver(module.envelope())
        self.snapshots["stale_base_phase"] = plain(
            module.StaleBasePhase(
                stale_custody_before,
                self.host.custody.status(stale_delivery),
                initial_base,
                current_base,
                self.comments(),
                (self.runner.review_entries, self.runner.codes, self.runner.conversations),
            )
        )

    def phase_collaboration(self) -> None:
        module, provider = self.module, self.provider
        deliveries: list[tuple[str, str | None, str | None]] = []

        def snapshot() -> tuple[str, int]:
            [dashboard] = [item for item in provider.comments if "<!-- hamsterdan:dashboard -->" in str(item["body"])]
            readiness_count = sum("<!-- hamsterdan:readiness " in str(item["body"]) for item in provider.comments)
            return str(dashboard["body"]), readiness_count

        snapshots = [snapshot()]

        def observe(label: str, event: str, action: str) -> None:
            delivery, before = self.deliver(module.envelope(action), event)
            deliveries.append((label, before, self.host.custody.status(delivery)))
            snapshots.append(snapshot())

        provider.requested_reviewers = ["reviewer"]
        observe("review_requested", "pull_request", "review_requested")
        provider.requested_reviewers = []
        provider.human_reviews = [
            {"id": 401, "submitted_at": "2026-08-16T01:00:00Z", "state": "CHANGES_REQUESTED", "user": {"login": "reviewer"}}
        ]
        provider.review_threads = [False]
        observe("changes_requested", "pull_request_review", "submitted")
        provider.human_reviews.append(
            {"id": 402, "submitted_at": "2026-08-16T02:00:00Z", "state": "APPROVED", "user": {"login": "reviewer"}}
        )
        observe("approved_thread_open", "pull_request_review", "submitted")
        provider.review_threads = [True]
        observe("thread_resolved", "pull_request_review_thread", "resolved")
        self.snapshots["collaboration_phase"] = plain(
            module.CollaborationPhase(
                tuple(deliveries),
                tuple(item[0] for item in snapshots),
                tuple(item[1] for item in snapshots),
            )
        )

    def phase_follow_up(self) -> None:
        module, provider, runner, flags = self.module, self.provider, self.runner, self.flags
        initial_head = self.snapshots["initial_head"]
        self.snapshots["before_follow_up_comments"] = self.comments()
        self.snapshots["before_follow_up_calls"] = plain(provider.calls)
        self.snapshots["before_follow_up_write_count"] = len(provider.writes)
        if self.repairing:
            assert runner.code_calls == []
        conversational = bool(flags.get("conversational_change"))
        if conversational or self.base_mutation:
            comment_id = 501
            instruction = (
                module.RESOLVE_CONFLICT_INSTRUCTION
                if flags.get("resolve_conflict")
                else module.UPDATE_BASE_INSTRUCTION
                if flags.get("update_base")
                else module.CHANGE_INSTRUCTION
            )
            provider.comments.append(
                {
                    "id": comment_id,
                    "html_url": "https://github.com/owner/repo/pull/7#issuecomment-501",
                    "body": f"@hamsterdan-test {instruction}",
                    "user": {"login": "author"},
                }
            )
            follow_up, before = self.deliver(module.comment_envelope(comment_id, instruction), "issue_comment")
            self.snapshots["conversation_delivery_id"] = follow_up
            self.snapshots["follow_up_custody_before"] = before
            assert provider.head != initial_head
            if conversational:
                assert provider.head == module.NEW_HEAD
            self.head_follow_up()
        elif self.rerun_conclusion is not None:
            provider.complete_rerun()
            _follow_up, before = self.deliver(
                module.workflow_envelope(self.rerun_conclusion, head=initial_head), "workflow_run"
            )
            self.snapshots["follow_up_custody_before"] = before
            if flags.get("agent_repair"):
                assert provider.head != initial_head
                self.head_follow_up()

    def head_follow_up(self) -> None:
        self.snapshots["head_follow_up_comments_before"] = self.comments()
        self.snapshots["head_follow_up_review_count_before"] = len(self.runner.reviews)
        _delivery, before = self.deliver(self.module.envelope())
        self.snapshots["head_follow_up_custody_before"] = before

    def finish(self) -> dict[str, object]:
        """``_run_journey``'s closing checks and its ``JourneyResult``."""
        module, provider, host, snapshots = self.module, self.provider, self.host, self.snapshots
        comments = self.comments()
        frozen = self.external_state()
        assert not self.unresolved()
        assert host.pump() == 0
        assert not self.unresolved() and self.external_state() == frozen
        remote = provider.git_remote
        changed = (
            "src/pr_fixture/__init__.py"
            if self.flags.get("resolve_conflict")
            else "BASE-NOTES.md"
            if self.flags.get("update_base")
            else "src/readiness.py"
        )
        result = {
            "custody_before": snapshots["custody_before"],
            "custody_after": host.custody.status(snapshots["delivery"]),
            "custody_counts": host.custody.counts(),
            "comments": comments,
            "review_comments": [dict(item) for item in provider.review_comments],
            "provider_calls": provider.calls,
            "provider_requests": provider.requests,
            "provider_writes": provider.writes,
            "provider_state": [
                provider.state,
                provider.draft,
                provider.merged,
                provider.mergeable,
                provider.mergeable_state,
                provider.head,
                provider.base,
            ],
            "initial_head": snapshots["initial_head"],
            "initial_base": snapshots["initial_base"],
            "runner": runner_json(self.runner),
            "run_attempt": provider.run_attempt,
            "run_id": provider.run_id,
            "run_conclusion": provider.run_conclusion,
            "rerun_requests": provider.rerun_requests,
            "git_reconciliations": provider.git_reconciliations,
            "git_publications": provider.git_publications,
            "before_follow_up_comments": snapshots["before_follow_up_comments"],
            "before_follow_up_calls": snapshots["before_follow_up_calls"],
            "before_follow_up_write_count": snapshots["before_follow_up_write_count"],
            "follow_up_custody_before": snapshots.get("follow_up_custody_before"),
            "head_follow_up_custody_before": snapshots.get("head_follow_up_custody_before"),
            "head_follow_up_comments_before": snapshots.get("head_follow_up_comments_before"),
            "head_follow_up_review_count_before": snapshots.get("head_follow_up_review_count_before"),
            "conversation_delivery_id": snapshots.get("conversation_delivery_id"),
            "git_cas_updates": provider.cas_updates,
            "git_created_objects": sorted(provider.created_git_objects),
            "git_boundary_events": provider.git_boundary_events,
            "git_remote_head": "" if remote is None else module.git(remote, "rev-parse", "refs/heads/feature"),
            "git_commit_body": "" if remote is None else module.git(remote, "log", "-1", "--format=%B", provider.head),
            "git_commit_parents": []
            if remote is None
            else module.git(remote, "rev-list", "--parents", "-n", "1", provider.head).split()[1:],
            "git_repaired_content": "" if remote is None else module.git(remote, "show", f"{provider.head}:{changed}"),
            "quiescent_comments": self.comments(),
            "quiescent_review_count": len(self.runner.reviews),
            "draft_phase": snapshots.get("draft_phase"),
            "stale_base_phase": snapshots.get("stale_base_phase"),
            "collaboration_phase": snapshots.get("collaboration_phase"),
        }
        provider.state, provider.draft, provider.merged = "closed", True, True
        provider.mergeable, provider.mergeable_state = False, "dirty"
        provider.head, provider.base = "c" * 40, "d" * 40
        frozen = self.external_state()
        host.close()
        assert self.external_state() == frozen
        assert self.comments() == result["quiescent_comments"]
        assert len(self.runner.reviews) == result["quiescent_review_count"]
        return plain(result)

    def carry(self) -> dict[str, object]:
        return {
            "provider": provider_json(self.provider),
            "runner": runner_json(self.runner),
            "snapshots": plain(self.snapshots),
            "next_uuid": self.uuid_state["next"],
        }


def drive(root: Path, document: dict[str, object]) -> dict[str, object]:
    module = scenarios_module()
    git_determinism()
    name = str(document["journey"])
    selected = phases(JOURNEYS[name])
    first, last = document["phases"]
    output: dict[str, object] = {}
    with pytest.MonkeyPatch.context() as monkeypatch:
        intent_order(monkeypatch)
        current = Drive(module, name, root, document.get("carry"), monkeypatch)
        for phase in selected[first:last]:
            getattr(current, f"phase_{phase}")()
        if last >= len(selected):
            output["result"] = current.finish()
        else:
            current.host.close()
        output["carry"] = plain(current.carry())
    return output


# ---------------------------------------------------------------------------
# dump

CLAIMANT = re.compile(r"worker:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


# The Local Dispatch's own wall-clock milliseconds: Petrus Motus stamps them
# from the system clock, with no clock seam in either host.
DISPATCH_CLOCK = {
    "impetus_local_dispatch_tasks": {"deadline", "schedule_start", "attempt_start", "attempt_deadline", "available_at"},
}


def cell(value: object, wall_clock: bool = False) -> object:
    if wall_clock and value is not None:
        return "<wall-clock-ms>"
    if isinstance(value, bytes):
        return {"blob": value.hex()}
    if isinstance(value, str):
        return CLAIMANT.sub("worker:<uuid>", value)
    return value


def table_rows(database, table: str) -> list[list[object]]:
    cursor = database.execute(f'SELECT * FROM "{table}"')
    clocked = DISPATCH_CLOCK.get(table, set())
    names = [column[0] for column in cursor.description]
    rows = ([cell(value, name in clocked) for name, value in zip(names, row)] for row in cursor)
    return sorted(rows, key=lambda row: json.dumps(row, sort_keys=True))


def dump(root: Path) -> dict[str, object]:
    files: dict[str, object] = {}
    for directory, subdirectories, names in os.walk(root):
        subdirectories[:] = [name for name in subdirectories if name not in {"git-world"}]
        for name in names:
            path = Path(directory) / name
            relative = str(path.relative_to(root))
            if name.endswith(("-wal", "-shm", "-journal")):
                continue
            if name.endswith(".sqlite3"):
                with sqlite3.connect(f"file:{path}?mode=ro", uri=True) as database:
                    tables = {}
                    for table, sql in database.execute(
                        "SELECT name, sql FROM sqlite_master WHERE type IN ('table','index') AND sql IS NOT NULL ORDER BY name"
                    ):
                        rows = []
                        if sql.startswith("CREATE TABLE"):
                            rows = table_rows(database, table)
                        tables[table] = {"sql": sql, "rows": rows}
                    files[relative] = {
                        "user_version": database.execute("PRAGMA user_version").fetchone()[0],
                        "tables": tables,
                    }
                database.close()
            else:
                files[relative] = path.read_bytes().decode("utf-8", "backslashreplace")
    return dict(sorted(files.items()))


def main() -> None:
    command = sys.argv[1]
    if command == "journey":
        output = journey(sys.argv[2], Path(sys.argv[3]).absolute())
    elif command == "drive":
        output = drive(Path(sys.argv[2]).absolute(), json.load(sys.stdin))
    elif command == "dump":
        output = dump(Path(sys.argv[2]))
    else:
        raise SystemExit(f"unknown command {command}")
    sys.stdout.write("\n" + json.dumps(output, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
