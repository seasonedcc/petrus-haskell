"""Compare one tier C checkpoint of the two hosts, after normalizing.

    python3 compare_tier_c.py --python CAPTURE --haskell CAPTURE [--real-agent]
        [--allow-failed-activities]

Standard library only. A CAPTURE is the directory ``scripts/e2e capture``
writes for one side at one checkpoint (docs/e2e.md lists it):

    meta.json                {"side", "repository", "organization", "app_slug",
                              "pr", "checkpoint"}
    inspect.json             operator ``inspect`` output
    inspect-authority.json   optional: {expectation: ``inspect-authority`` output}
    healthz.json             the host's /healthz answer
    github/pull.json, issue-comments.json, review-comments.json,
           reviews.json, threads.json, commits.json, runs.json
    github/trees/<sha>.json  each App commit's recursive tree listing
    export/history/history.jsonl   from the export package
    shutdown.log             optional: the host's output while stopping (stop-hosts --into)

Both sides are normalized the same way (docs/hamsterdan.md §5.2 tier C step
5): the side's repository, organization, App slug, bot login and mention;
40-hex SHAs and their short forms; 64-hex digests (a rerun operation's
identity digests its run); UUIDs; ISO timestamps; and the ids GitHub
assigns (comment, review, run, job and PR numbers in URLs and markers, the
installation/repository ids in operation identities). Then:

- **comments**: the App's comments by kind (dashboard, finding, reminder,
  readiness, reply, rerun, unmarked) with identical normalized bodies; the
  same final summary body; the same number of readiness advisories, at most
  one per head on each side;
- **reviews and threads**: the App's native reviews and inline comments
  (state, location, body), the humans' reviews (login, state), and the
  threads (location, resolved, resolver);
- **commits**: the same number of PR commits; the App's commits with the same
  tree (every blob but the two files each copy rebinds to its App, when
  ``github/trees/<sha>.json`` holds the recursive listing; otherwise the
  tree SHA), number of parents, trailers and normalized author and
  committer;
- **sequencing**: on each side the summary comes before any other App effect;
- **history**: the per-transition firing multiset, the Activity counts by
  name and the terminal variants;
- **health**: ``inspect`` passes every check, /healthz says ``ok`` with no
  failed delivery, and History holds no failed or pending Activity (unless
  ``--allow-failed-activities``, for the fault-injection scenario: then the
  two sides must still agree);
- **known upstream defects** (PR85 §1c1, §1c2) must reproduce identically:
  a status reply that words an approval-gate flag as an approval while no
  approving review exists, and ``host-cleanup-uncertain`` in the shutdown
  output.

Tolerated, as upstream's PR84-vs-PR83 comparison tolerates (and only that):
timing (timestamps, the order of comments other than the summary-first
rule), the counts of summary updates and deferrals (transitions matching
``TOLERATED_TRANSITIONS``, variants in ``TOLERATED_VARIANTS``, the
``dash_gate`` Activity), and, with ``--real-agent`` only, the prose of
agent-written comments (findings and replies are compared by kind and
count) and finding order.

Prints a JSON report; exits 1 when anything differs.
"""

from __future__ import annotations

import argparse
import collections
import json
import re
import sys
from pathlib import Path
from typing import Any

SHA = re.compile(r"\b[0-9a-f]{40}\b")
DIGEST = re.compile(r"\b[0-9a-f]{64}\b")
UUID = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b")
TIMESTAMP = re.compile(r"\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?")
HEX_WORD = re.compile(r"\b[0-9a-f]{7,39}\b")
IDS = (
    (re.compile(r"(issuecomment-|discussion_r|pullrequestreview-)\d+"), r"\1<id>"),
    (re.compile(r"(/pull/|/issues/|/runs/|/jobs/|/attempts/|/comments/|/reviews/)\d+"), r"\1<id>"),
    (re.compile(r"\b(run=|reply:|comment:|review:|delivery:)\d+"), r"\1<id>"),
    (re.compile(r"\bgithub:\d+:\d+:pr:\d+"), "github:<installation>:<repository>:pr:<n>"),
    (re.compile(r"(?<![\w/])#\d+\b"), "#<n>"),
)
DASHBOARD = re.compile(r"<!-- hamsterdan:dashboard -->\s*\Z")
IMMUTABLE = re.compile(r"<!-- hamsterdan:(finding|reminder|readiness) operation=\S+ head=([0-9a-f]{40}) -->")
REPLY = re.compile(r"<!-- hamsterdan:conversation operation=\S+ head=[0-9a-f]{40} -->")
RERUN = re.compile(r"<!-- (?:hamsterdan|impetus)-rerun run=\d+ head=[0-9a-f]{40} operation=\S+ -->")
APPROVAL_WORDING = re.compile(r"\bapprov(?:al|als|ed|es|e)\b", re.IGNORECASE)
TRAILER = re.compile(r"^[A-Za-z][A-Za-z0-9-]*: .+$")
CLEANUP_UNCERTAIN = "host-cleanup-uncertain"

TOLERATED_TRANSITIONS = re.compile(r"^(dash\.(publish|fold|fold_landed|fold_deferred)|review\.fold_round_moved)$")
TOLERATED_VARIANTS = frozenset({"DashLanded", "DashDeferred", "RoundMoved"})
TOLERATED_ACTIVITIES = frozenset({"dash_gate"})
AGENT_PROSE_KINDS = frozenset({"finding", "reply"})
# The two files each copy rebinds to its own App (scripts/e2e prepare-repos):
# an App commit's tree is compared without them.
REBOUND_PATHS = frozenset({".github/workflows/rerun-broker.yml", "tools/rerun_broker.py"})


class Side:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.meta = self.read("meta.json")
        self.repository = str(self.meta["repository"])
        self.organization = str(self.meta["organization"])
        self.slug = str(self.meta["app_slug"])
        self.bot = f"{self.slug}[bot]"
        self.shas: set[str] = set()
        for path in sorted(root.rglob("*")):
            if path.is_file() and path.suffix in (".json", ".jsonl", ".log"):
                self.shas.update(SHA.findall(path.read_text(encoding="utf-8", errors="replace")))

    def read(self, name: str, default: Any = None) -> Any:
        path = self.root / name
        if not path.exists():
            if default is not None:
                return default
            raise SystemExit(f"{self.root}: missing {name}")
        return json.loads(path.read_text(encoding="utf-8"))

    def text(self, name: str) -> str | None:
        path = self.root / name
        return path.read_text(encoding="utf-8", errors="replace") if path.exists() else None

    def normalize(self, value: Any) -> Any:
        if isinstance(value, str):
            return self.normalize_text(value)
        if isinstance(value, list):
            return [self.normalize(item) for item in value]
        if isinstance(value, dict):
            return {key: self.normalize(item) for key, item in value.items()}
        return value

    def normalize_text(self, text: str) -> str:
        owner, _, name = self.repository.partition("/")
        text = text.replace(self.repository, "<repository>")
        text = text.replace(self.bot, "<bot>")
        text = re.sub(r"\b\d+\+<bot>", "<id>+<bot>", text)
        text = re.sub(rf"@{re.escape(self.slug)}\b", "@<slug>", text)
        text = re.sub(rf"\b{re.escape(self.slug)}\b", "<slug>", text)
        text = re.sub(rf"\b{re.escape(name)}\b", "<repository-name>", text)
        text = re.sub(rf"\b{re.escape(self.organization)}\b", "<organization>", text)
        text = UUID.sub("<uuid>", text)
        text = DIGEST.sub("<digest>", text)
        text = SHA.sub("<sha>", text)
        text = HEX_WORD.sub(lambda match: "<short-sha>" if any(sha.startswith(match.group(0)) for sha in self.shas) else match.group(0), text)
        text = TIMESTAMP.sub("<time>", text)
        for pattern, replacement in IDS:
            text = pattern.sub(replacement, text)
        return text


def login(value: Any) -> str:
    return str((value or {}).get("login", "")) if isinstance(value, dict) else ""


def comment_kind(body: str) -> str:
    if DASHBOARD.search(body):
        return "dashboard"
    immutable = IMMUTABLE.search(body)
    if immutable:
        return immutable.group(1)
    if REPLY.search(body):
        return "reply"
    if RERUN.search(body):
        return "rerun"
    return "unmarked"


def app_comments(side: Side) -> list[dict[str, Any]]:
    return [comment for comment in side.read("github/issue-comments.json", []) if login(comment.get("user")) == side.bot]


def approved(side: Side) -> bool:
    return any(str(review.get("state")) == "APPROVED" for review in side.read("github/reviews.json", []))


def view_comments(side: Side, real_agent: bool) -> dict[str, Any]:
    comments = app_comments(side)
    kinds: dict[str, list[str]] = collections.defaultdict(list)
    readiness_heads: collections.Counter[str] = collections.Counter()
    summary = None
    for comment in comments:
        body = str(comment.get("body", ""))
        kind = comment_kind(body)
        if kind == "dashboard":
            summary = side.normalize_text(body)
            continue
        if kind == "readiness":
            readiness_heads[IMMUTABLE.search(body).group(2)] += 1  # type: ignore[union-attr]
        kinds[kind].append("<prose>" if real_agent and kind in AGENT_PROSE_KINDS else side.normalize_text(body))
    return {
        "by_kind": {kind: sorted(bodies) for kind, bodies in sorted(kinds.items())},
        "summary": summary,
        "readiness_count": sum(readiness_heads.values()),
        "readiness_duplicated_heads": sum(1 for count in readiness_heads.values() if count > 1),
        "dashboards": sum(1 for comment in comments if comment_kind(str(comment.get("body", ""))) == "dashboard"),
    }


def view_reviews(side: Side, real_agent: bool) -> dict[str, Any]:
    reviews = side.read("github/reviews.json", [])
    inline = side.read("github/review-comments.json", [])
    threads = side.read("github/threads.json", [])

    def prose(body: Any) -> str:
        return "<prose>" if real_agent else side.normalize_text(str(body or ""))

    return {
        "app_reviews": sorted(
            [str(review.get("state")), prose(review.get("body"))] for review in reviews if login(review.get("user")) == side.bot
        ),
        "human_reviews": sorted(
            [login(review.get("user")), str(review.get("state"))] for review in reviews if login(review.get("user")) != side.bot
        ),
        "app_inline": sorted(
            [str(item.get("path")), item.get("line") or item.get("original_line"), prose(item.get("body"))]
            for item in inline
            if login(item.get("user")) == side.bot
        ),
        "threads": sorted(
            [
                str(thread.get("path")),
                thread.get("line") or thread.get("originalLine"),
                bool(thread.get("isResolved")),
                side.normalize_text(login(thread.get("resolvedBy"))),
                side.normalize_text(login(((thread.get("comments") or {}).get("nodes") or [{}])[0].get("author"))),
            ]
            for thread in threads
        ),
    }


def app_commit(side: Side, commit: dict[str, Any]) -> bool:
    return side.bot in (login(commit.get("author")), login(commit.get("committer")))


def view_commits(side: Side) -> dict[str, Any]:
    commits = side.read("github/commits.json", [])
    shaped = []
    for commit in commits:
        if not app_commit(side, commit):
            continue
        detail = commit.get("commit") or {}
        message = str(detail.get("message", ""))
        trailers = [line for line in message.strip().split("\n\n")[-1].splitlines() if TRAILER.match(line)] if "\n\n" in message else []
        listing = side.read(f"github/trees/{commit.get('sha')}.json", {})
        tree: Any = (detail.get("tree") or {}).get("sha")
        if listing:
            tree = {
                str(entry.get("path")): entry.get("sha")
                for entry in listing.get("tree", [])
                if entry.get("type") == "blob" and entry.get("path") not in REBOUND_PATHS
            }
        shaped.append(
            {
                "tree": tree,
                "parents": len(commit.get("parents") or []),
                "trailers": side.normalize(trailers),
                "author": side.normalize({k: (detail.get("author") or {}).get(k) for k in ("name", "email")}),
                "committer": side.normalize({k: (detail.get("committer") or {}).get(k) for k in ("name", "email")}),
            }
        )
    return {"count": len(commits), "app_commits": shaped}


def summary_first(side: Side) -> bool:
    effects: list[tuple[str, str]] = []
    for comment in app_comments(side):
        effects.append((str(comment.get("created_at", "")), comment_kind(str(comment.get("body", "")))))
    for review in side.read("github/reviews.json", []):
        if login(review.get("user")) == side.bot:
            effects.append((str(review.get("submitted_at", "")), "review"))
    for commit in side.read("github/commits.json", []):
        if app_commit(side, commit):
            effects.append((str(((commit.get("commit") or {}).get("committer") or {}).get("date", "")), "commit"))
    if not effects:
        return True
    effects.sort()
    return effects[0][1] == "dashboard"


def history(side: Side) -> list[dict[str, Any]]:
    text = side.text("export/history/history.jsonl")
    if text is None:
        raise SystemExit(f"{side.root}: missing export/history/history.jsonl")
    return [json.loads(line) for line in text.splitlines() if line.strip()]


def view_history(side: Side) -> tuple[dict[str, Any], dict[str, Any], dict[str, int]]:
    firings: collections.Counter[str] = collections.Counter()
    activities: collections.Counter[str] = collections.Counter()
    variants: collections.Counter[str] = collections.Counter()
    requested: dict[int, str] = {}
    settled: set[int] = set()
    failed = 0
    for record in history(side):
        kind = record.get("record")
        if kind == "FiringCompleted":
            firings[str(record.get("transition"))] += 1
        elif kind == "ActivityRequested":
            activities[str(record.get("activity"))] += 1
            requested[int(record.get("occurrence", 0))] = str(record.get("activity"))
        elif kind == "ActivityCompleted":
            result = record.get("result")
            variant = result.get("$variant") if isinstance(result, dict) else None
            variants[f"{record.get('transition')}:{variant}"] += 1
            settled.add(int(record.get("occurrence", 0)))
        elif kind == "ActivityFailed":
            variants[f"{record.get('transition')}:<failed>"] += 1
            settled.add(int(record.get("occurrence", 0)))
            failed += 1
    exact: dict[str, Any] = {"firings": {}, "activities": {}, "variants": {}}
    tolerated: dict[str, Any] = {"firings": {}, "activities": {}, "variants": {}}
    for name, count in sorted(firings.items()):
        (tolerated if TOLERATED_TRANSITIONS.match(name) else exact)["firings"][name] = count
    for name, count in sorted(activities.items()):
        (tolerated if name in TOLERATED_ACTIVITIES else exact)["activities"][name] = count
    for name, count in sorted(variants.items()):
        transition, _, variant = name.partition(":")
        (tolerated if variant in TOLERATED_VARIANTS or TOLERATED_TRANSITIONS.match(transition) else exact)["variants"][name] = count
    health = {"failed_activities": failed, "pending_activities": len(set(requested) - settled)}
    return exact, tolerated, health


def view_health(side: Side, history_health: dict[str, int]) -> dict[str, Any]:
    inspect = side.read("inspect.json")
    healthz = side.read("healthz.json")
    authority = side.read("inspect-authority.json", {})
    return {
        "inspect_ok": inspect.get("ok") is True and all(check.get("pass") is True for check in inspect.get("checks", [])),
        "inspect_checks": sorted(str(check.get("name")) for check in inspect.get("checks", [])),
        "authority": {name: value.get("ok") for name, value in sorted(authority.items())},
        "healthz_ok": healthz.get("status") == "ok" and not (healthz.get("inbox") or {}).get("failed"),
        **history_health,
    }


def known_defects(side: Side) -> dict[str, Any]:
    replies = [comment for comment in app_comments(side) if comment_kind(str(comment.get("body", ""))) == "reply"]
    claims = any(APPROVAL_WORDING.search(REPLY.sub("", str(comment.get("body", "")))) for comment in replies) and not approved(side)
    shutdown = side.text("shutdown.log")
    return {
        "status_reply_claims_approval": claims,
        "pi_cleanup_uncertain": None if shutdown is None else CLEANUP_UNCERTAIN in shutdown,
    }


def compare(python_root: Path, haskell_root: Path, real_agent: bool, allow_failed: bool) -> dict[str, Any]:
    sides = {"python": Side(python_root), "haskell": Side(haskell_root)}
    differences: list[dict[str, Any]] = []
    tolerated: dict[str, Any] = {}
    views: dict[str, dict[str, Any]] = {}
    for name, side in sides.items():
        exact, tolerated_counts, history_health = view_history(side)
        views[name] = {
            "comments": view_comments(side, real_agent),
            "reviews": view_reviews(side, real_agent),
            "commits": view_commits(side),
            "summary_first": summary_first(side),
            "history": exact,
            "health": view_health(side, history_health),
            "known_defects": known_defects(side),
        }
        tolerated[name] = tolerated_counts

    for aspect in ("comments", "reviews", "commits", "summary_first", "history", "health", "known_defects"):
        left, right = views["python"][aspect], views["haskell"][aspect]
        if left != right:
            differences.append({"aspect": aspect, "python": left, "haskell": right})
    for name, view in views.items():
        problems = []
        if view["comments"]["dashboards"] != 1:
            problems.append(f"{view['comments']['dashboards']} summary comments")
        if view["comments"]["readiness_duplicated_heads"]:
            problems.append("more than one readiness advisory for a head")
        if not view["summary_first"]:
            problems.append("an App effect before the summary")
        health = view["health"]
        if not health["inspect_ok"]:
            problems.append("operator inspect does not pass every check")
        if not health["healthz_ok"]:
            problems.append("/healthz is not ok or has failed deliveries")
        if not allow_failed and (health["failed_activities"] or health["pending_activities"]):
            problems.append("failed or pending Activities")
        for problem in problems:
            differences.append({"aspect": "rule", "side": name, "problem": problem})
    return {
        "ok": not differences,
        "checkpoint": sides["python"].meta.get("checkpoint"),
        "differences": differences,
        "known_defects": {name: view["known_defects"] for name, view in views.items()},
        "tolerated": tolerated,
        "real_agent": real_agent,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--python", type=Path, required=True)
    parser.add_argument("--haskell", type=Path, required=True)
    parser.add_argument("--real-agent", action="store_true", help="tolerate agent prose and finding order")
    parser.add_argument("--allow-failed-activities", action="store_true")
    args = parser.parse_args()
    report = compare(args.python, args.haskell, args.real_agent, args.allow_failed_activities)
    print(json.dumps(report, sort_keys=True, indent=1, ensure_ascii=False))
    sys.exit(0 if report["ok"] else 1)


if __name__ == "__main__":
    main()
