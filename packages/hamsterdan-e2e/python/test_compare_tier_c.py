"""Synthetic captures for ``compare_tier_c.py``: what must pass and what must fail.

    python3 -B test_compare_tier_c.py

Standard library only; run by the package's test suite. Each case builds a
Python-side and a Haskell-side capture of one checkpoint that differ in
every identity a live run gives them (repository, App, bot, ids, SHAs,
timestamps), applies one change, and checks the verdict.
"""

from __future__ import annotations

import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))

import compare_tier_c  # noqa: E402

SIDES = {
    "python": {
        "repository": "seasonedcc/demo-pr-readiness-py",
        "slug": "hamster-dan-py",
        "pr": 3,
        "ids": 1000,
        "sha": "1",
        "day": "11",
        "installation": 501,
        "repository_id": 601,
    },
    "haskell": {
        "repository": "seasonedcc/demo-pr-readiness-hs",
        "slug": "hamster-dan-hs",
        "pr": 5,
        "ids": 9000,
        "sha": "9",
        "day": "12",
        "installation": 777,
        "repository_id": 888,
    },
}


def sha(side: dict[str, Any], n: int) -> str:
    return (side["sha"] + format(n, "x")) * 20


def stamp(side: dict[str, Any], minute: int) -> str:
    return f"2026-10-{side['day']}T10:{minute:02d}:00Z"


def capture(side: dict[str, Any]) -> dict[str, Any]:
    """One checkpoint: a reviewed, repaired, approved PR, with a status reply."""
    repository, slug = side["repository"], side["slug"]
    bot = f"{slug}[bot]"
    head, repaired, base = sha(side, 1), sha(side, 2), sha(side, 3)
    url = f"https://github.com/{repository}/pull/{side['pr']}"
    operation = f"findings:{head}:i1:F-lease"
    rerun_operation = "rerun:L1:" + (side["sha"] * 64)

    def comment(n: int, minute: int, body: str, user: str = bot) -> dict[str, Any]:
        return {
            "id": side["ids"] + n,
            "user": {"login": user},
            "body": body,
            "created_at": stamp(side, minute),
            "updated_at": stamp(side, minute + 30),
            "html_url": f"{url}#issuecomment-{side['ids'] + n}",
        }

    dashboard = (
        f"## Hamsterdan summary — ✅ all gates clear for `{repaired[:7]}` — see the readiness advisory.\n\n"
        f"<sub>head {repaired} on base {base}</sub>\n\n<!-- hamsterdan:dashboard -->"
    )
    findings = (
        "## Hamsterdan review findings\n\n### `lease` — the lease is converted twice\n**blocking** · severity: **high**\n"
        f"Primary location: `scenario-fixtures/hero_review/gate.py:10`\n\n### `cache` — the cache key ignores case\n"
        f"**blocking** · severity: **medium**\nPrimary location: `scenario-fixtures/hero_review/cache.py:11`\n\n"
        f"<!-- hamsterdan:finding operation={operation} head={head} -->"
    )
    reply = (
        f"Head `{repaired[:7]}` is green and Dan's review is clear; waiting on human review. See {url}.\n\n"
        f"<!-- hamsterdan:conversation operation=reply:{side['ids'] + 40} head={repaired} -->"
    )
    readiness = (
        "## Hamsterdan readiness advisory\n\nAll observed gates are ready.\n\n"
        f"<!-- hamsterdan:readiness operation=ready:{repaired}:i1 head={repaired} -->"
    )
    rerun = f"<!-- hamsterdan-rerun run={side['ids'] + 77} head={head} operation={rerun_operation} -->"
    history = [
        {"record": "FiringCompleted", "transition": "review.agent"},
        {"record": "FiringCompleted", "transition": "dash.publish"},
        {"record": "FiringCompleted", "transition": "dash.publish"},
        {"record": "ActivityRequested", "occurrence": 1, "transition": "dash.publish", "activity": "dash_gate"},
        {"record": "ActivityCompleted", "occurrence": 1, "transition": "dash.publish", "result": {"$variant": "DashLanded"}},
        {"record": "ActivityRequested", "occurrence": 2, "transition": "review.agent", "activity": "review_agent"},
        {"record": "ActivityCompleted", "occurrence": 2, "transition": "review.agent", "result": {"$variant": "AgentReview"}},
        {"record": "ActivityRequested", "occurrence": 3, "transition": "ready.gate", "activity": "announce_gate"},
        {"record": "ActivityCompleted", "occurrence": 3, "transition": "ready.gate", "result": {"$variant": "ALanded"}},
    ]
    return {
        "meta.json": {
            "side": "?",
            "repository": repository,
            "organization": repository.split("/")[0],
            "app_slug": slug,
            "pr": side["pr"],
            "checkpoint": "final",
        },
        "inspect.json": {
            "ok": True,
            "repository": repository,
            "checks": [{"name": name, "pass": True, "observed": True} for name in ("pull_identity", "dashboard_present")],
        },
        "healthz.json": {"status": "ok", "inbox": {"processed": 12}, "applications": 1},
        "github/issue-comments.json": [
            comment(1, 0, dashboard),
            comment(2, 3, findings),
            comment(3, 4, rerun),
            comment(4, 5, f"@{slug} status", user="henriquebastos"),
            comment(5, 6, reply),
            comment(6, 9, readiness),
        ],
        "github/review-comments.json": [],
        "github/reviews.json": [
            {"id": side["ids"] + 50, "user": {"login": "crisbastos"}, "state": "CHANGES_REQUESTED", "submitted_at": stamp(side, 2), "body": "please fix"},
            {"id": side["ids"] + 51, "user": {"login": "crisbastos"}, "state": "APPROVED", "submitted_at": stamp(side, 8), "body": "ok"},
        ],
        "github/threads.json": [
            {"path": "scenario-fixtures/hero_review/gate.py", "line": 10, "isResolved": True, "resolvedBy": {"login": bot}, "comments": {"nodes": [{"author": {"login": bot}}]}},
        ],
        "github/commits.json": [
            {"sha": head, "commit": {"tree": {"sha": "a" * 40}, "message": "hero fixture", "author": {"name": "Henrique", "email": "h@example.com", "date": stamp(side, 0)}, "committer": {"name": "Henrique", "email": "h@example.com", "date": stamp(side, 0)}}, "parents": [{"sha": base}], "author": {"login": "henriquebastos"}, "committer": {"login": "henriquebastos"}},
            {"sha": repaired, "commit": {"tree": {"sha": "b" * 40}, "message": f"Repair the review findings\n\nHamsterdan-Operation: mutation:github:{side['installation']}:{side['repository_id']}:pr:{side['pr']}:{head}:i1", "author": {"name": bot, "email": f"{side['ids']}+{bot}@users.noreply.github.com", "date": stamp(side, 7)}, "committer": {"name": bot, "email": f"{side['ids']}+{bot}@users.noreply.github.com", "date": stamp(side, 7)}}, "parents": [{"sha": head}], "author": {"login": bot}, "committer": {"login": bot}},
        ],
        f"github/trees/{repaired}.json": {
            "sha": "b" * 40,
            "tree": [
                {"path": "scenario-fixtures/hero_review/gate.py", "type": "blob", "sha": "d" * 40},
                {"path": ".github/workflows/rerun-broker.yml", "type": "blob", "sha": side["sha"] * 40},
                {"path": "tools/rerun_broker.py", "type": "blob", "sha": (side["sha"] + "f") * 20},
                {"path": "scenario-fixtures", "type": "tree", "sha": "e" * 40},
            ],
        },
        "github/pull.json": {"number": side["pr"], "head": {"sha": repaired}, "base": {"sha": base}},
        "github/runs.json": {"workflow_runs": []},
        "export/history/history.jsonl": history,
        "shutdown.log": "INFO:     Shutting down\nINFO:     Application shutdown complete.\n",
    }


def write(root: Path, files: dict[str, Any]) -> None:
    for name, value in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if name.endswith(".jsonl"):
            path.write_text("".join(json.dumps(item) + "\n" for item in value), encoding="utf-8")
        elif name.endswith(".log"):
            path.write_text(value, encoding="utf-8")
        else:
            path.write_text(json.dumps(value), encoding="utf-8")


Change = Callable[[dict[str, Any]], None]


def both(change: Change) -> tuple[Change, Change]:
    return change, change


def nothing(_files: dict[str, Any]) -> None:
    pass


class CompareTierC(unittest.TestCase):
    def verdict(self, python: Change = nothing, haskell: Change = nothing, **options: bool) -> dict[str, Any]:
        with tempfile.TemporaryDirectory() as directory:
            roots = {}
            for name, change in (("python", python), ("haskell", haskell)):
                files = copy.deepcopy(capture(SIDES[name]))
                change(files)
                roots[name] = Path(directory) / name
                write(roots[name], files)
            return compare_tier_c.compare(
                roots["python"], roots["haskell"], options.get("real_agent", False), options.get("allow_failed", False)
            )

    def assertPasses(self, report: dict[str, Any]) -> None:
        self.assertTrue(report["ok"], json.dumps(report["differences"], indent=1, ensure_ascii=False))

    def assertFails(self, report: dict[str, Any], aspect: str) -> None:
        self.assertFalse(report["ok"])
        self.assertIn(aspect, [difference["aspect"] for difference in report["differences"]])

    # -- passes ------------------------------------------------------------

    def test_identities_ids_shas_and_times_are_normalized(self) -> None:
        report = self.verdict()
        self.assertPasses(report)
        self.assertEqual(
            report["known_defects"],
            {name: {"status_reply_claims_approval": False, "pi_cleanup_uncertain": False} for name in ("python", "haskell")},
        )

    def test_summary_update_and_deferral_counts_are_tolerated(self) -> None:
        def more(files: dict[str, Any]) -> None:
            history = files["export/history/history.jsonl"]
            history.append({"record": "FiringCompleted", "transition": "dash.publish"})
            history.append({"record": "ActivityRequested", "occurrence": 9, "transition": "dash.publish", "activity": "dash_gate"})
            history.append({"record": "ActivityCompleted", "occurrence": 9, "transition": "dash.publish", "result": {"$variant": "DashDeferred"}})

        report = self.verdict(haskell=more)
        self.assertPasses(report)
        self.assertNotEqual(report["tolerated"]["python"], report["tolerated"]["haskell"])

    def test_comment_order_and_timing_are_tolerated(self) -> None:
        def reorder(files: dict[str, Any]) -> None:
            comments = files["github/issue-comments.json"]
            comments[1], comments[2] = comments[2], comments[1]
            comments[2]["created_at"] = "2026-10-12T10:04:30Z"

        self.assertPasses(self.verdict(haskell=reorder))

    def test_agent_prose_and_finding_order_only_with_a_real_agent(self) -> None:
        def prose(files: dict[str, Any]) -> None:
            comments = files["github/issue-comments.json"]
            comments[1]["body"] = comments[1]["body"].replace("the lease is converted twice", "lease converted twice")
            comments[4]["body"] = comments[4]["body"].replace("is green", "passes CI")

        self.assertFails(self.verdict(haskell=prose), "comments")
        self.assertPasses(self.verdict(haskell=prose, real_agent=True))

    def test_known_defects_reproduced_on_both_sides_pass_and_are_reported(self) -> None:
        def defects(files: dict[str, Any]) -> None:
            comments = files["github/issue-comments.json"]
            comments[4]["body"] = comments[4]["body"].replace(
                "waiting on human review", "Human review shows approval and a changes-requested review"
            )
            files["github/reviews.json"] = files["github/reviews.json"][:1]
            files["shutdown.log"] += "RuntimeProtocolError: host-cleanup-uncertain\n"

        report = self.verdict(*both(defects))
        self.assertPasses(report)
        for name in ("python", "haskell"):
            self.assertEqual(report["known_defects"][name], {"status_reply_claims_approval": True, "pi_cleanup_uncertain": True})

    # -- failures ----------------------------------------------------------

    def test_a_summary_body_differs(self) -> None:
        def summary(files: dict[str, Any]) -> None:
            files["github/issue-comments.json"][0]["body"] = files["github/issue-comments.json"][0]["body"].replace("all gates clear", "waiting")

        self.assertFails(self.verdict(haskell=summary), "comments")
        self.assertFails(self.verdict(haskell=summary, real_agent=True), "comments")

    def test_a_second_readiness_advisory_for_one_head(self) -> None:
        def twice(files: dict[str, Any]) -> None:
            comments = files["github/issue-comments.json"]
            comments.append({**comments[5], "id": comments[5]["id"] + 1})

        report = self.verdict(haskell=twice)
        self.assertFails(report, "comments")
        self.assertFails(report, "rule")

    def test_an_app_commit_with_another_tree(self) -> None:
        def blob(files: dict[str, Any]) -> None:
            listing = next(value for name, value in files.items() if name.startswith("github/trees/"))
            listing["tree"][0]["sha"] = "c" * 40

        def unlisted(files: dict[str, Any]) -> None:
            for name in [name for name in files if name.startswith("github/trees/")]:
                del files[name]

        def other(files: dict[str, Any]) -> None:
            unlisted(files)
            files["github/commits.json"][1]["commit"]["tree"]["sha"] = "c" * 40

        self.assertFails(self.verdict(haskell=blob), "commits")
        self.assertPasses(self.verdict(*both(unlisted)))
        self.assertFails(self.verdict(python=unlisted, haskell=other), "commits")

    def test_a_thread_left_unresolved(self) -> None:
        def unresolved(files: dict[str, Any]) -> None:
            files["github/threads.json"][0]["isResolved"] = False
            files["github/threads.json"][0]["resolvedBy"] = None

        self.assertFails(self.verdict(haskell=unresolved), "reviews")

    def test_an_exact_history_count_differs(self) -> None:
        def extra(files: dict[str, Any]) -> None:
            files["export/history/history.jsonl"].append({"record": "FiringCompleted", "transition": "review.agent"})

        self.assertFails(self.verdict(haskell=extra), "history")

    def test_a_failed_activity(self) -> None:
        def failed(files: dict[str, Any]) -> None:
            history = files["export/history/history.jsonl"]
            history.append({"record": "ActivityRequested", "occurrence": 7, "transition": "review.agent", "activity": "review_agent"})
            history.append({"record": "ActivityFailed", "occurrence": 7, "transition": "review.agent"})

        self.assertFails(self.verdict(*both(failed)), "rule")
        self.assertPasses(self.verdict(*both(failed), allow_failed=True))
        self.assertFails(self.verdict(haskell=failed, allow_failed=True), "history")

    def test_an_effect_before_the_summary(self) -> None:
        def late(files: dict[str, Any]) -> None:
            files["github/issue-comments.json"][0]["created_at"] = "2026-10-12T11:00:00Z"

        report = self.verdict(haskell=late)
        self.assertFails(report, "summary_first")
        self.assertFails(report, "rule")

    def test_inspect_failing_on_both_sides(self) -> None:
        def failing(files: dict[str, Any]) -> None:
            files["inspect.json"]["ok"] = False
            files["inspect.json"]["checks"][1]["pass"] = False

        self.assertFails(self.verdict(*both(failing)), "rule")

    def test_the_status_reply_defect_on_one_side_only(self) -> None:
        def claims(files: dict[str, Any]) -> None:
            comments = files["github/issue-comments.json"]
            comments[4]["body"] = comments[4]["body"].replace(
                "waiting on human review", "Human review shows approval and a changes-requested review"
            )
            files["github/reviews.json"] = files["github/reviews.json"][:1]

        def no_claim(files: dict[str, Any]) -> None:
            files["github/reviews.json"] = files["github/reviews.json"][:1]

        report = self.verdict(python=claims, haskell=no_claim, real_agent=True)
        self.assertFails(report, "known_defects")
        self.assertTrue(report["known_defects"]["python"]["status_reply_claims_approval"])
        self.assertFalse(report["known_defects"]["haskell"]["status_reply_claims_approval"])

    def test_the_cleanup_defect_on_one_side_only(self) -> None:
        def uncertain(files: dict[str, Any]) -> None:
            files["shutdown.log"] += "RuntimeProtocolError: host-cleanup-uncertain\n"

        self.assertFails(self.verdict(python=uncertain), "known_defects")

    def test_a_human_review_missing(self) -> None:
        def missing(files: dict[str, Any]) -> None:
            files["github/reviews.json"] = files["github/reviews.json"][:1]

        self.assertFails(self.verdict(haskell=missing), "reviews")


if __name__ == "__main__":
    unittest.main()
