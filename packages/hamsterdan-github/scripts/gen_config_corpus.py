"""Generate the host-configuration differential corpus.

Run with the pinned reference environment from the repository root:

    upstream/hamsterdan/.venv/bin/python packages/hamsterdan-github/scripts/gen_config_corpus.py

Two kinds of rows:

* ``installations``: one installations file (raw bytes, base64) and the
  outcome of ``installation_accounts`` on it (TOML 1.0 parsing through
  ``tomllib``, every shape rule, sorting and casefolding) or the exact
  ``ConfigurationError`` message.
* ``environment``: one host environment (the installations path is the
  placeholder ``{installations}``) and the outcome of
  ``HostConfig.from_environment``: the public configuration values or the
  exact error message.

Every credential is a synthetic placeholder.
"""

from __future__ import annotations

import base64
import json
import os
import random
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "upstream" / "hamsterdan" / "src"))

from hamsterdan.github_app.config import ConfigurationError, HostConfig, installation_accounts  # noqa: E402

SEED = 20261013
OUT = ROOT / "packages" / "hamsterdan-github" / "test" / "corpus" / "config.jsonl"
rng = random.Random(SEED)

LOGINS = ["Owner", "Other-Owner", "o", "a" * 39, "a" * 40, "Ownér", "Own er", "-x", "x_y", "OWNER", "Kelvin", ""]
IDS = ["23", "24", "+25", "0x1A", "0o33", "0b11100", "2_9", "30.0", "true", '"23"', "-5", "0", str(2**63 - 1), str(2**64), "1e3", "inf", "1979-05-27"]
REPOSITORY_NAMES = ["one", "Two", "three.x", "a_b-c", "x y", "", "a/b", "été"]


def toml_string(value: str) -> str:
    roll = rng.random()
    if roll < 0.8:
        return json.dumps(value, ensure_ascii=rng.random() < 0.5)
    if roll < 0.85 and "'" not in value and "\n" not in value:
        return f"'{value}'"
    if roll < 0.9:
        return '"""\n' + value.replace("\\", "\\\\").replace('"', '\\"') + '"""'
    if roll < 0.97:
        return "".join(f"\\u{ord(c):04X}" if ord(c) < 0x10000 else f"\\U{ord(c):08X}" for c in value).join('""')
    return '"' + value + '\\e"' if rng.random() < 0.5 else '"\\x41' + value + '"'


def repository(login: str, used: set[int]) -> str:
    roll = rng.random()
    identifier = rng.randint(1, 120)
    while identifier in used and rng.random() < 0.95:
        identifier = rng.randint(1, 120)
    used.add(identifier)
    owner = login if rng.random() < 0.93 else rng.choice([login.upper(), login.lower(), "Stranger", login + "x"])
    name = rng.choice(REPOSITORY_NAMES[:4]) if rng.random() < 0.96 else rng.choice(REPOSITORY_NAMES)
    if roll < 0.92:
        return f"{identifier}:{owner}/{name}"
    return rng.choice(
        [
            f"0{identifier}:{owner}/{name}",
            f"{identifier}",
            f"{identifier}:{owner}/{name}:extra",
            f"٣١:{owner}/{name}",
            f" {identifier}:{owner}/{name}",
            f"{identifier}:{owner}/{name} ",
            f"{identifier}:{owner}",
            f"-{identifier}:{owner}/{name}",
            f"{identifier}:{owner}//{name}",
            f"{2**80}:{owner}/{name}",
        ]
    )


def account_members(used: set[int]) -> list[tuple[str, str]]:
    login = rng.choice(LOGINS[:3]) if rng.random() < 0.94 else rng.choice(LOGINS)
    identifier = rng.choice(IDS[:2]) if rng.random() < 0.93 else rng.choice(IDS)
    repositories = [toml_string(repository(login, used)) for _ in range(rng.choice([0, 1, 1, 1, 2, 2, 3]))]
    if rng.random() < 0.03:
        repositories.append(rng.choice(["31", "true", "[]", "{}", "1979-05-27T07:32:00Z"]))
    layout = rng.random()
    if layout < 0.5:
        array = "[" + ", ".join(repositories) + "]"
    elif layout < 0.8:
        array = "[\n" + "".join(f"  {item},\n" for item in repositories) + "]"
    else:
        array = "[ # comment\n" + ",\n".join(f"  {item}" for item in repositories) + "\n]"
    members = [("id", identifier), ("login", toml_string(login)), ("repositories", array)]
    if rng.random() < 0.03:
        members.append(rng.choice([("extra", "1"), ("name", '"x"')]))
    if rng.random() < 0.02:
        members.pop(rng.randrange(len(members)))
    if rng.random() < 0.02:
        members.append(members[0])
    rng.shuffle(members)
    return members


def document() -> bytes:
    used: set[int] = set()
    accounts = [account_members(used) for _ in range(0 if rng.random() < 0.01 else rng.choice([1, 1, 1, 2, 2, 3]))]
    style = rng.random()
    if style < 0.65:
        text = "".join(
            "\n[[accounts]]\n" + "".join(f"{k} = {v}\n" for k, v in members) for members in accounts
        )
    elif style < 0.85:
        text = "accounts = [\n" + "".join(
            "  { " + ", ".join(f"{k} = {re.sub(r' *# comment', '', v).replace(chr(10), ' ')}" for k, v in members) + " },\n" for members in accounts
        ) + "]\n"
    elif style < 0.92:
        # TOML 1.1 only: newlines and a trailing comma inside an inline table.
        text = "accounts = [\n" + "".join(
            "  {\n" + "".join(f"    {k} = {v},\n" for k, v in members) + "  },\n" for members in accounts
        ) + "]\n"
    else:
        text = "".join(
            "\n[[accounts]]\n" + "".join(f"{k} = {v}\n" for k, v in members) for members in accounts
        )
        text = rng.choice(
            [
                "title = 'x'\n" + text,
                text + "\n[accounts.extra]\n",
                text + "\naccounts = 1\n",
                "accounts.x = 1\n" + text,
                text.replace("\n", "\r\n"),
                text.replace("\n", "\r"),
                "﻿" + text,
                text + "\n# trailing comment",
                text + "\nwhen = 1979-05-27T07:32\n",
                text.replace("=", " = ", 1),
                text + "\n[other]\n",
                "[accounts]\n" + text,
            ]
        )
    raw = text.encode()
    roll = rng.random()
    if roll < 0.01:
        raw = raw + b"\n# \xff\xfe"
    elif roll < 0.015:
        raw = b""
    elif roll < 0.02:
        raw = raw + b"\n" + b"# padding padding\n" * 4000
    elif roll < 0.03:
        raw = raw.replace(b"[[accounts]]", b"[[ accounts ]]", 1)
    elif roll < 0.035:
        raw = raw + b"\x00"
    elif roll < 0.04:
        raw = raw + b"\nkey = \"tab\there\"\n"
    return raw


def accounts_value(accounts: tuple[object, ...]) -> list[object]:
    return [[a.account_id, a.account_login, [list(r) for r in a.repositories]] for a in accounts]  # type: ignore[attr-defined]


def run_installations(raw: bytes) -> dict[str, object]:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "installations.toml"
        path.write_bytes(raw)
        path.chmod(0o600)
        try:
            return {"accounts": accounts_value(installation_accounts(path))}
        except ConfigurationError as error:
            return {"error": str(error)}


VALID_TOML = b'[[accounts]]\nid = 23\nlogin = "Owner"\nrepositories = ["31:Owner/One", "32:Owner/Two"]\n'
KEY = "-----BEGIN PRIVATE KEY-----\nplaceholder\n-----END PRIVATE KEY-----\n"


def environment_case() -> dict[str, object]:
    env: dict[str, str] = {
        "HAMSTERDAN_GITHUB_APP_ID": "17",
        "HAMSTERDAN_GITHUB_APP_SLUG": "hamsterdan-test",
        "HAMSTERDAN_GITHUB_CLIENT_ID": "Iv1.explicit",
        "HAMSTERDAN_GITHUB_INSTALLATIONS_FILE": "{installations}",
        "HAMSTERDAN_STATE_PATH": "/var/lib/hamsterdan/state.db",
        "HAMSTERDAN_GITHUB_PRIVATE_KEY": KEY,
        "HAMSTERDAN_GITHUB_WEBHOOK_SECRET": "hook-secret",
    }
    choices = {
        "HAMSTERDAN_GITHUB_APP_ID": ["0", "017", "+17", " 17", "17 ", "1_7", "١٧", "x", "", "99999999999999999999999", "17\n"],
        "HAMSTERDAN_GITHUB_APP_SLUG": ["Hamster-Dan", "-x", "x-", "", "a" * 100, "a" * 101, "émoji", "a_b", "a b", "K", "ß", "ﬃ", "x1-2", "İ"],
        "HAMSTERDAN_GITHUB_CLIENT_ID": ["", "x" * 128, "x" * 129, "Iv1.é", "Iv1.\n", "Iv1. x", "Iv1.\x7f"],
        "HAMSTERDAN_GITHUB_INSTALLATIONS_FILE": ["", "/nonexistent/installations.toml", "{directory}", "{wide}", "{symlink}"],
        "HAMSTERDAN_STATE_PATH": ["", ".", "./", "//x//y/", "///x", "a/./b/", "state.db", "/", "./.", "a/../b", "~/x"],
        "HAMSTERDAN_GITHUB_PRIVATE_KEY": ["", " \n", "{repeat:x:65536}", "{repeat:x:65537}", "{repeat:é:32768}", "{repeat:é:32769}", "k\x00"],
        "HAMSTERDAN_GITHUB_WEBHOOK_SECRET": ["", "\t", "{repeat:s:65537}", " s "],
        "HAMSTERDAN_WATCH_AUTHORS": ["", " ", " Alice , bob-Dev ", "alice,", "@alice", ",", "Alice,ALICE", "a" * 39, "a" * 40, "ﬃ", "Kelvin", "a b", "x,\ty"],
        "HAMSTERDAN_ALLOWED_REPOSITORIES": ["x"],
        "HAMSTERDAN_GITHUB_ACCOUNT_ID": [""],
        "HAMSTERDAN_GITHUB_PRIVATE_KEY_FILE": ["/x"],
        "HAMSTERDAN_GITHUB_WEBHOOK_SECRET_FILE": [""],
        "GITHUB_APP_ID": ["999"],
    }
    names = list(choices)
    weights = [1.0 if name.startswith("HAMSTERDAN") and not name.endswith(("_FILE", "REPOSITORIES", "ACCOUNT_ID")) else 0.12 for name in names]
    for _ in range(rng.choice([0, 1, 1, 1, 2, 3])):
        name = rng.choices(names, weights)[0]
        if rng.random() < 0.08 and name in env:
            del env[name]
        else:
            env[name] = rng.choice(choices[name])
    installations = VALID_TOML if rng.random() < 0.85 else document()
    return {"kind": "environment", "environment": env, "installations": base64.b64encode(installations).decode()}


def expand(value: str) -> str:
    """``{repeat:c:n}`` spells ``c * n`` (keeps the corpus small)."""
    match = re.fullmatch(r"\{repeat:(.):(\d+)\}", value)
    return value if match is None else match.group(1) * int(match.group(2))


def run_environment(case: dict[str, object]) -> dict[str, object]:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "installations.toml"
        path.write_bytes(base64.b64decode(case["installations"]))  # type: ignore[arg-type]
        path.chmod(0o600)
        wide = Path(directory) / "wide.toml"
        wide.write_bytes(VALID_TOML)
        wide.chmod(0o664)
        link = Path(directory) / "link.toml"
        link.symlink_to(path)
        env = {
            name: expand(value).replace("{installations}", str(path))
            .replace("{directory}", directory)
            .replace("{wide}", str(wide))
            .replace("{symlink}", str(link))
            for name, value in case["environment"].items()  # type: ignore[attr-defined]
        }
        try:
            config = HostConfig.from_environment(env)
        except ConfigurationError as error:
            return {"error": str(error)}
        private_key, webhook_secret = config._credentials()
        return {
            "config": {
                "app_id": config.app_id,
                "app_slug": config.app_slug,
                "bot_login": config.bot_login,
                "client_id": config.client_id,
                "accounts": accounts_value(config.accounts),
                "state_path": str(config.state_path),
                "watched_authors": sorted(config.watched_authors),
                "private_key_matches": private_key == env["HAMSTERDAN_GITHUB_PRIVATE_KEY"],
                "webhook_secret_matches": webhook_secret == env["HAMSTERDAN_GITHUB_WEBHOOK_SECRET"],
            }
        }


def main() -> None:
    rows: list[dict[str, object]] = []
    for _ in range(1500):
        raw = document()
        rows.append({"kind": "installations", "raw": base64.b64encode(raw).decode()} | run_installations(raw))
    for _ in range(600):
        case = environment_case()
        rows.append(case | run_environment(case))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w") as handle:
        for row in rows:
            handle.write(json.dumps(row, separators=(",", ":"), sort_keys=True) + "\n")
    print(f"wrote {len(rows)} rows to {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    os.umask(0o022)
    main()
