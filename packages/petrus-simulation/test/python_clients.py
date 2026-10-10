"""Run the upstream HTTP tests' urllib and socket clients against a server.

Usage: python -I python_clients.py PORT

The upstream module ``tests/petrus/engine/test_simulation_http.py`` serves
its own Python server through ``serving()``. This replaces ``serving`` with
one that yields a stand-in for the server listening on PORT (its profile,
fetched over HTTP, and its address), then runs every upstream test whose
assertions hold for any correct server, with each pytest parametrization.
Tests that replace ``simulate`` only to prove it is never reached get a
``monkeypatch`` that ignores the replacement: their assertions (the status
and error code) are about the server under test.

Prints ``PASS name`` or ``FAIL name`` plus the traceback per case, then
``DONE passed failed``.
"""

from contextlib import contextmanager
import copy
import json
import sys
import traceback
from urllib.request import Request, urlopen
import warnings

sys.path.insert(0, ".")  # run from upstream/petrus: its ``tests`` package

import tests.petrus.engine.test_simulation_http as upstream  # noqa: E402
from tests.simulation_support import build_scenario  # noqa: E402

PORT = int(sys.argv[1])
BASE = f"http://127.0.0.1:{PORT}"


class Remote:
    """What the upstream tests read from a server."""

    def __init__(self) -> None:
        request = Request(f"{BASE}/v1/simulation-profile", headers={"Origin": upstream.ORIGIN})
        with urlopen(request) as response:
            self._profile_bytes = response.read()
        self._profile = json.loads(self._profile_bytes)
        self.server_address = ("127.0.0.1", PORT)
        self.server_port = PORT

    @property
    def profile(self):
        return copy.deepcopy(self._profile)


@contextmanager
def serving():
    built, marking = build_scenario()
    yield Remote(), built, marking, BASE


class IgnoredPatch:
    def setattr(self, *args, **kwargs) -> None:
        del args, kwargs


TESTS = [
    "test_profile_routes_cors_options_and_origin_are_exact",
    "test_profile_property_is_detached_and_head_and_extension_methods_have_no_body",
    "test_success_is_exact_direct_simulate_bytes",
    "test_strict_json_schema_types_and_definition_mismatch",
    "test_nested_non_strict_json_is_400_before_simulation",
    "test_expected_definition_must_be_exact_object",
    "test_raw_framing_refusals",
    "test_content_length_lexemes_have_exact_errors",
    "test_duplicate_headers_targets_short_body_and_pipeline_are_closed_exactly",
    "test_short_body_is_exact_400",
    "test_malformed_color_is_400_before_simulation",
    "test_nested_definition_number_type_mismatch_is_409_before_engine_or_simulate",
    "test_strict_value_failures_are_exact_400_before_simulate",
    "test_head_and_all_extension_methods_have_exact_405_headers_cors_and_body_rules",
    "test_profile_copies_cannot_mutate_get_or_post_definition_compare",
]


def cases(function):
    marks = [mark for mark in getattr(function, "pytestmark", []) if mark.name == "parametrize"]
    if not marks:
        yield function.__name__, {}
        return
    (mark,) = marks
    names, values = mark.args
    names = [name.strip() for name in names.split(",")] if isinstance(names, str) else list(names)
    for index, value in enumerate(values):
        arguments = dict(zip(names, value if len(names) > 1 else (value,)))
        yield f"{function.__name__}[{index}]", arguments


def main() -> None:
    warnings.simplefilter("ignore")
    upstream.serving = serving
    passed = failed = 0
    for name in TESTS:
        function = getattr(upstream, name)
        for label, arguments in cases(function):
            if "monkeypatch" in function.__code__.co_varnames[: function.__code__.co_argcount]:
                arguments = {"monkeypatch": IgnoredPatch(), **arguments}
            try:
                function(**arguments)
            except Exception:  # noqa: BLE001 - reported to the caller
                failed += 1
                print(f"FAIL {label}")
                traceback.print_exc(file=sys.stdout)
            else:
                passed += 1
                print(f"PASS {label}")
    print(f"DONE {passed} {failed}", flush=True)


if __name__ == "__main__":
    main()
