"""The reference operator over a tier C fixture, as a runtime overlay.

    python -I -B e2e_operator.py FIXTURE.json <python -m hamsterdan.operator arguments>

Runs in the reference's environment. ``hamsterdan.operator`` hard-codes
HBNetwork's repository, organization, App and hero reviewer
(``operator.py:35-87``, ``/orgs/HBNetwork`` in ``preflight``). Nothing
upstream is patched: this driver imports the module, rebinds those
constants from FIXTURE (``fixture.py`` documents it), and calls its
``main()``:

- ``REPOSITORY``, ``ORG_ID``, ``REPOSITORY_ID``, ``APP_SLUG``,
  ``HERO_REVIEWER``, ``DELEGATED_BROKER_DIGEST``,
  ``DELEGATED_VALIDATOR_DIGEST``;
- ``APP_BOT_LOGIN`` and ``APP_BROKER_AUTHORIZATION``, derived from the slug
  as the module derives them;
- ``inspect``'s ``bot_login`` keyword default, which Python froze at
  definition time (``--bot-login`` defaults to the rebound
  ``APP_BOT_LOGIN``, read when the parser is built);
- ``_api``: the path ``/orgs/HBNetwork`` becomes ``/orgs/<organization>``.

The Haskell operator takes the same fixture as configuration
(``Hamsterdan.Operator.Fixture``, through ``hamsterdan-e2e-operator``).
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import fixture as fixtures  # noqa: E402


def overlay(module, fixture: fixtures.Fixture) -> None:
    module.REPOSITORY = fixture.repository
    module.ORG_ID = fixture.org_id
    module.REPOSITORY_ID = fixture.repository_id
    module.APP_SLUG = fixture.app_slug
    module.APP_BOT_LOGIN = fixture.bot_login
    module.APP_BROKER_AUTHORIZATION = (
        f"github.event.comment.user.type == 'Bot' &&\n      github.event.comment.user.login == '{fixture.bot_login}' &&"
    )
    module.HERO_REVIEWER = fixture.hero_reviewer
    module.DELEGATED_BROKER_DIGEST = fixture.broker_digest
    module.DELEGATED_VALIDATOR_DIGEST = fixture.validator_digest
    module.inspect.__kwdefaults__ = {**module.inspect.__kwdefaults__, "bot_login": fixture.bot_login}
    api = module._api
    organization = f"/orgs/{fixture.organization}"

    def rebound_api(runner, path):
        return api(runner, organization if path == "/orgs/HBNetwork" else path)

    module._api = rebound_api


def main() -> int:
    if len(sys.argv) < 2:
        sys.stderr.write("usage: e2e_operator.py FIXTURE.json <operator arguments>\n")
        return 2
    fixture = fixtures.load(Path(sys.argv[1]))
    from hamsterdan import operator

    overlay(operator, fixture)
    sys.argv = ["python -m hamsterdan.operator", *sys.argv[2:]]
    return operator.main()


if __name__ == "__main__":
    raise SystemExit(main())
