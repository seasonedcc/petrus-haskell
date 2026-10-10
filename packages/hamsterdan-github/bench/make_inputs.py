"""Writes bench/inputs.json, the shared inputs of bench.py and Main.hs.

    python3 packages/hamsterdan-github/bench/make_inputs.py

The payloads are shaped like GitHub's (an ``issue_comment`` webhook of a
pull request, a ``GET /repos/{repo}/pulls/{n}`` body, and a page of bot
comments) with fixed, synthetic values.
"""

from __future__ import annotations

import json
from pathlib import Path

HEAD = "a" * 40
BASE = "b" * 40


def user(login: str, identifier: int, kind: str = "User") -> dict[str, object]:
    base = f"https://api.github.com/users/{login}"
    return {
        "login": login,
        "id": identifier,
        "node_id": f"MDQ6VXNlcj{identifier}",
        "avatar_url": f"https://avatars.githubusercontent.com/u/{identifier}?v=4",
        "gravatar_id": "",
        "url": base,
        "html_url": f"https://github.com/{login}",
        "followers_url": f"{base}/followers",
        "following_url": f"{base}/following{{/other_user}}",
        "gists_url": f"{base}/gists{{/gist_id}}",
        "starred_url": f"{base}/starred{{/owner}}{{/repo}}",
        "subscriptions_url": f"{base}/subscriptions",
        "organizations_url": f"{base}/orgs",
        "repos_url": f"{base}/repos",
        "events_url": f"{base}/events{{/privacy}}",
        "received_events_url": f"{base}/received_events",
        "type": kind,
        "user_view_type": "public",
        "site_admin": False,
    }


def repository() -> dict[str, object]:
    base = "https://api.github.com/repos/owner/one"
    value: dict[str, object] = {
        "id": 31,
        "node_id": "R_kgDOAAAAHw",
        "name": "one",
        "full_name": "owner/one",
        "private": True,
        "owner": user("owner", 23, "Organization"),
        "html_url": "https://github.com/owner/one",
        "description": "A repository with a description that is long enough to look real.",
        "fork": False,
        "url": base,
    }
    for name in [
        "forks", "keys", "collaborators", "teams", "hooks", "issue_events", "events", "assignees", "branches",
        "tags", "blobs", "git_tags", "git_refs", "trees", "statuses", "languages", "stargazers", "contributors",
        "subscribers", "subscription", "commits", "git_commits", "comments", "issue_comment", "contents",
        "compare", "merges", "archive", "downloads", "issues", "pulls", "milestones", "notifications", "labels",
        "releases", "deployments",
    ]:
        value[f"{name}_url"] = f"{base}/{name}{{/sha}}"
    value.update(
        {
            "created_at": "2024-01-02T03:04:05Z",
            "updated_at": "2026-10-01T03:04:05Z",
            "pushed_at": "2026-10-09T03:04:05Z",
            "git_url": "git://github.com/owner/one.git",
            "ssh_url": "git@github.com:owner/one.git",
            "clone_url": "https://github.com/owner/one.git",
            "svn_url": "https://github.com/owner/one",
            "homepage": None,
            "size": 12345,
            "stargazers_count": 3,
            "watchers_count": 3,
            "language": "Python",
            "has_issues": True,
            "has_projects": False,
            "has_downloads": True,
            "has_wiki": False,
            "has_pages": False,
            "has_discussions": False,
            "forks_count": 0,
            "mirror_url": None,
            "archived": False,
            "disabled": False,
            "open_issues_count": 7,
            "license": None,
            "allow_forking": False,
            "is_template": False,
            "web_commit_signoff_required": False,
            "topics": ["automation", "review"],
            "visibility": "private",
            "forks": 0,
            "open_issues": 7,
            "watchers": 3,
            "default_branch": "main",
        }
    )
    return value


def webhook() -> dict[str, object]:
    issue_url = "https://api.github.com/repos/owner/one/issues/7"
    return {
        "action": "created",
        "issue": {
            "url": issue_url,
            "repository_url": "https://api.github.com/repos/owner/one",
            "labels_url": f"{issue_url}/labels{{/name}}",
            "comments_url": f"{issue_url}/comments",
            "events_url": f"{issue_url}/events",
            "html_url": "https://github.com/owner/one/pull/7",
            "id": 2468013579,
            "node_id": "PR_kwDOAAAAHs5iAAAA",
            "number": 7,
            "title": "Teach the readiness board about stale review threads",
            "user": user("author", 5),
            "labels": [{"id": 1, "name": "enhancement", "color": "a2eeef", "default": True, "description": "New feature"}],
            "state": "open",
            "locked": False,
            "assignee": None,
            "assignees": [],
            "milestone": None,
            "comments": 4,
            "created_at": "2026-10-08T12:00:00Z",
            "updated_at": "2026-10-09T12:00:00Z",
            "closed_at": None,
            "author_association": "MEMBER",
            "active_lock_reason": None,
            "draft": False,
            "pull_request": {
                "url": "https://api.github.com/repos/owner/one/pulls/7",
                "html_url": "https://github.com/owner/one/pull/7",
                "diff_url": "https://github.com/owner/one/pull/7.diff",
                "patch_url": "https://github.com/owner/one/pull/7.patch",
                "merged_at": None,
            },
            "body": "This change makes the board notice review threads that went stale. " * 12,
            "reactions": {"url": f"{issue_url}/reactions", "total_count": 0, "+1": 0, "-1": 0},
            "timeline_url": f"{issue_url}/timeline",
            "performed_via_github_app": None,
            "state_reason": None,
        },
        "comment": {
            "url": "https://api.github.com/repos/owner/one/issues/comments/9",
            "html_url": "https://github.com/owner/one/pull/7#issuecomment-9",
            "issue_url": issue_url,
            "id": 9,
            "node_id": "IC_kwDOAAAAHs5AAAAJ",
            "user": user("human", 6),
            "created_at": "2026-10-09T12:30:00Z",
            "updated_at": "2026-10-09T12:30:00Z",
            "author_association": "MEMBER",
            "body": "@hamster-dan explain the blockers on this one, please — especially the stale thread rule.",
            "reactions": {"url": "https://api.github.com/repos/owner/one/issues/comments/9/reactions", "total_count": 0},
            "performed_via_github_app": None,
        },
        "repository": repository(),
        "organization": {"login": "owner", "id": 23, "node_id": "O_kgDOAAAAFw", "url": "https://api.github.com/orgs/owner"},
        "sender": user("human", 6),
        "installation": {"id": 44, "node_id": "MDIzOkludGVncmF0aW9uSW5zdGFsbGF0aW9uNDQ=", "account": {"id": 23, "login": "Owner"}},
    }


def pull() -> dict[str, object]:
    def side(sha: str, ref: str) -> dict[str, object]:
        return {"label": f"owner:{ref}", "ref": ref, "sha": sha, "user": user("owner", 23, "Organization"), "repo": repository()}

    return {
        "url": "https://api.github.com/repos/owner/one/pulls/7",
        "id": 2468013579,
        "number": 7,
        "state": "open",
        "locked": False,
        "title": "Teach the readiness board about stale review threads",
        "user": user("author", 5),
        "body": "This change makes the board notice review threads that went stale. " * 12,
        "created_at": "2026-10-08T12:00:00Z",
        "updated_at": "2026-10-09T12:00:00Z",
        "closed_at": None,
        "merged_at": None,
        "merge_commit_sha": "c" * 40,
        "assignee": None,
        "assignees": [],
        "requested_reviewers": [user("reviewer", 8)],
        "requested_teams": [],
        "labels": [],
        "milestone": None,
        "draft": False,
        "head": side(HEAD, "topic"),
        "base": side(BASE, "main"),
        "author_association": "MEMBER",
        "auto_merge": None,
        "active_lock_reason": None,
        "merged": False,
        "mergeable": True,
        "rebaseable": True,
        "mergeable_state": "clean",
        "merged_by": None,
        "comments": 4,
        "review_comments": 2,
        "maintainer_can_modify": False,
        "commits": 3,
        "additions": 120,
        "deletions": 14,
        "changed_files": 5,
    }


def comments() -> list[dict[str, object]]:
    items = []
    for index in range(100):
        body = f"Finding {index}: the dashboard and the gate disagree about readiness."
        marker = f"<!-- hamsterdan:finding operation=op-{index:03d} head={HEAD} -->"
        items.append(
            {
                "id": 1000 + index,
                "html_url": f"https://github.com/owner/one/pull/7#issuecomment-{1000 + index}",
                "body": f"{body}\n\n{marker}",
                "user": user("hamster-dan[bot]", 99, "Bot"),
                "created_at": "2026-10-09T12:00:00Z",
                "author_association": "NONE",
            }
        )
    return items


def main() -> None:
    compact = {"separators": (",", ":"), "ensure_ascii": False}
    inputs = {
        "webhook_body": json.dumps(webhook(), **compact),
        "pull_body": json.dumps(pull(), **compact),
        "comments": comments(),
        "head": HEAD,
    }
    out = Path(__file__).parent / "inputs.json"
    out.write_text(json.dumps(inputs, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
