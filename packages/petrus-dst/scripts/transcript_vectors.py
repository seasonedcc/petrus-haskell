"""Record the reference's Engine-backed fixture replays as door transcripts.

The 51 world fixtures replay through Engine-backed profiles (and, for the
33 ``joined-*`` fixtures, through PostgreSQL with the Impetus and Absurd
schemas). The Haskell port has no Engine yet, so this script records, for
each replay, every call the Python World makes across the profile seam:
the door, its arguments, every ScenarioContext service the door used (with
its result), and the door's outcome (value or raised exception), plus every
checker verdict. The Haskell ``Petrus.Testing.Dst.Transcript`` replays the
same artifact through a profile that serves these recorded outcomes, and
must end with the same replay result bytes or the same error, after making
exactly the same door calls with exactly the same arguments.

Run from upstream/petrus, with a PostgreSQL server whose DSN may create
databases (the ``absurd_dsn`` shape of the reference's ``conftest.py``):

    PYTHONPATH=. uv run --frozen python ../../packages/petrus-dst/scripts/transcript_vectors.py \
        postgres://postgres@127.0.0.1:55432/postgres \
        ../../packages/petrus-dst/test/data/transcripts.json
"""

from __future__ import annotations

import inspect
import json
import sys
import tempfile
from copy import deepcopy
from pathlib import Path

import psycopg

from petrus.impetus.history_store.postgres import ensure_schema
from petrus.motus.dispatch.absurd import ensure_absurd_schema
from petrus.testing.dst import (
    GenerationStart,
    ScenarioRegistry,
    decode_artifact,
    load_artifact,
    replay,
)
from tests.dst import joined_creation_world, joined_registration_world, joined_seal_world, joined_world
from tests.dst.engine_world import EngineHistoryChecker, EngineProfile
from tests.dst.postgres_support import isolated_absurd_database
from tests.dst.replay_world import replay_path

FIXTURES = Path("tests/dst/fixtures")
FOREIGN = {"generated-runtime-semantic-coverage-v1.json", "projection-crash-recovery-v1.json"}
JOINED_MODULES = (joined_world, joined_creation_world, joined_registration_world, joined_seal_world)


def dump(value):
    # A detached JSON copy now: profiles return their own mutable state,
    # which they may change after the door returns.
    return json.loads(json.dumps(_dump(value), allow_nan=False))


def _dump(value):
    if hasattr(value, "model_dump"):
        return value.model_dump(mode="json")
    if isinstance(value, (list, tuple)):
        return [_dump(item) for item in value]
    return value


def error_of(caught: BaseException) -> dict:
    return {"type": type(caught).__name__, "message": str(caught)}


class Recorder:
    """One replay's transcript."""

    def __init__(self) -> None:
        self.profiles: list = []
        self.checkers: list = []
        self.calls: list = []
        self.checks: list = []
        self.open: dict | None = None
        self.tokens: dict[int, int] = {}
        self.generations: list = []

    def token(self, generation) -> int | None:
        if generation is None:
            return None
        return self.tokens[id(generation)]

    def call(self, profile, door: str, arguments: dict, body):
        record = {"profile": dump(profile.identity), "door": door, "arguments": arguments, "context": []}
        if self.open is not None:
            raise AssertionError("a door was entered while another door was open")
        self.calls.append(record)
        self.open = record
        try:
            value = body()
        except BaseException as caught:
            record["outcome"] = {"error": error_of(caught)}
            raise
        finally:
            self.open = None
        return record, value

    def context(self, event: dict) -> None:
        if self.open is None:
            raise AssertionError("a ScenarioContext service ran outside a door")
        self.open["context"].append(event)


class Generation:
    """The World-facing generation: a token over the real one."""

    def __init__(self, token: int, inner) -> None:
        self.token = token
        self.inner = inner


class RecordingContext:
    def __init__(self, recorder: Recorder, inner) -> None:
        self._recorder = recorder
        self._inner = inner

    def now(self) -> int:
        value = self._inner.now()
        self._recorder.context({"service": "now", "result": value})
        return value

    def stable_id(self, namespace: str) -> str:
        try:
            value = self._inner.stable_id(namespace)
        except BaseException as caught:
            self._recorder.context({"service": "stable_id", "argument": namespace, "error": error_of(caught)})
            raise
        self._recorder.context({"service": "stable_id", "argument": namespace, "result": value})
        return value

    def faults(self, target: str):
        try:
            value = self._inner.faults(target)
        except BaseException as caught:
            self._recorder.context({"service": "faults", "argument": target, "error": error_of(caught)})
            raise
        self._recorder.context({"service": "faults", "argument": target, "result": dump(value)})
        return value


class RecordingProfile:
    def __init__(self, recorder: Recorder, inner) -> None:
        self._recorder = recorder
        self._inner = inner
        self.identity = inner.identity
        door = getattr(inner, "resource_usage", None)
        self._resources = callable(door)
        if self._resources:
            self.resource_usage = self._resource_usage
        recorder.profiles.append({"identity": dump(inner.identity), "resource_usage": self._resources})

    def _simple(self, door, arguments, body):
        record, value = self._recorder.call(self._inner, door, arguments, body)
        record["outcome"] = {"value": dump(value)}
        return value

    def validate(self, command):
        return self._simple("validate", {"command": dump(command)}, lambda: self._inner.validate(command))

    def validate_fault(self, fault):
        return self._simple("validate_fault", {"fault": dump(fault)}, lambda: self._inner.validate_fault(fault))

    def _start(self, door, context):
        recording = RecordingContext(self._recorder, context)
        record, started = self._recorder.call(self._inner, door, {}, lambda: getattr(self._inner, door)(recording))
        token = len(self._recorder.tokens) + 1
        wrapped = Generation(token, started.generation)
        self._recorder.tokens[id(wrapped)] = token
        self._recorder.generations.append(wrapped)
        record["outcome"] = {"value": {"generation": token, "scheduled": dump(list(started.scheduled))}}
        return GenerationStart(wrapped, started.scheduled)

    def create(self, context):
        return self._start("create", context)

    def load(self, context):
        return self._start("load", context)

    def apply(self, generation, command, context):
        recording = RecordingContext(self._recorder, context)
        return self._simple(
            "apply",
            {"generation": generation.token, "command": dump(command)},
            lambda: self._inner.apply(generation.inner, command, recording),
        )

    def observe(self, generation, request, context):
        recording = RecordingContext(self._recorder, context)
        return self._simple(
            "observe",
            {"generation": generation.token, "request": dump(request)},
            lambda: self._inner.observe(generation.inner, request, recording),
        )

    def drop(self, generation):
        return self._simple("drop", {"generation": generation.token}, lambda: self._inner.drop(generation.inner))

    def close(self, generation):
        return self._simple("close", {"generation": generation.token}, lambda: self._inner.close(generation.inner))

    def _resource_usage(self, generation):
        token = None if generation is None else generation.token
        inner = None if generation is None else generation.inner
        return self._simple("resource_usage", {"generation": token}, lambda: self._inner.resource_usage(inner))


class RecordingChecker:
    def __init__(self, recorder: Recorder, inner) -> None:
        self._recorder = recorder
        self._inner = inner
        self.identity = inner.identity
        self.request = inner.request
        recorder.checkers.append({"identity": dump(inner.identity), "request": dump(inner.request)})

    def check(self, observation):
        record = {"checker": dump(self.identity), "observation": dump(observation)}
        self._recorder.checks.append(record)
        try:
            value = self._inner.check(observation)
        except BaseException as caught:
            record["outcome"] = {"error": error_of(caught)}
            raise
        record["outcome"] = {"value": dump(value)}
        return value


CURRENT: list[Recorder] = []
_register_profile = ScenarioRegistry.register_profile
_register_checker = ScenarioRegistry.register_checker


def register_profile(self, profile) -> None:
    _register_profile(self, RecordingProfile(CURRENT[-1], profile) if CURRENT else profile)


def register_checker(self, checker) -> None:
    _register_checker(self, RecordingChecker(CURRENT[-1], checker) if CURRENT else checker)


ScenarioRegistry.register_profile = register_profile
ScenarioRegistry.register_checker = register_checker


def record(name: str, artifact_bytes: bytes, run) -> dict:
    recorder = Recorder()
    CURRENT.append(recorder)
    try:
        try:
            result = run()
            outcome = {"result": json.dumps(dump(result), allow_nan=False, separators=(",", ":"), sort_keys=True)}
        except Exception as caught:  # noqa: BLE001 - the error is the vector
            outcome = {"error": error_of(caught)}
    finally:
        CURRENT.pop()
    return {
        "name": name,
        "artifact": artifact_bytes.decode(),
        "profiles": recorder.profiles,
        "checkers": recorder.checkers,
        "calls": recorder.calls,
        "checks": recorder.checks,
        "outcome": outcome,
    }


def joined_classes():
    profiles: dict = {}
    checkers: dict = {}
    for module in JOINED_MODULES:
        for _, cls in inspect.getmembers(module, inspect.isclass):
            identity = getattr(cls, "identity", None)
            if not hasattr(identity, "model_dump"):
                continue
            key = json.dumps(dump(identity), sort_keys=True)
            if callable(getattr(cls, "apply", None)):
                profiles.setdefault(key, set()).add(cls)
            elif callable(getattr(cls, "check", None)):
                checkers.setdefault(key, set()).add(cls)
    return profiles, checkers


def joined_replay(path: Path, server_dsn: str):
    profiles, checkers = joined_classes()
    artifact = load_artifact(path)

    def only(table: dict, identity) -> type:
        found = table.get(json.dumps(dump(identity), sort_keys=True), set())
        if len(found) != 1:
            raise AssertionError(f"{path.name}: {len(found)} classes for {identity}")
        return next(iter(found))

    profile_class = only(profiles, artifact.profile)
    checker_classes = [only(checkers, identity) for identity in artifact.checkers]

    def run():
        with isolated_absurd_database(server_dsn) as dsn:
            registry = ScenarioRegistry()
            registry.register_profile(profile_class(dsn))
            for checker_class in checker_classes:
                registry.register_checker(checker_class())
            return replay(artifact, registry)

    return run


def engine_mutation(name: str, fixture: str, mutate, checkers=(EngineHistoryChecker,)) -> dict:
    value = deepcopy(json.loads((FIXTURES / fixture).read_bytes()))
    mutate(value)
    encoded = json.dumps(value, allow_nan=False, separators=(",", ":"), sort_keys=True).encode()

    def run():
        artifact = decode_artifact(encoded)
        with tempfile.TemporaryDirectory(prefix="petrus-dst-transcript-") as directory:
            registry = ScenarioRegistry()
            registry.register_profile(EngineProfile(Path(directory) / "history.jsonl"))
            for checker in checkers:
                registry.register_checker(checker())
            return replay(artifact, registry)

    return record(name, encoded, run)


def set_path(*steps):
    *walk, (key, value) = steps

    def mutate(document) -> None:
        target = document
        for step in walk:
            target = target[step]
        target[key] = value

    return mutate


def changed_failure(document) -> None:
    changed = "DST budget 'actions' exhausted somewhere else"
    document["operations"][-1]["failure"]["error"] = changed
    document["expected"]["failure"]["error"] = changed


def main() -> int:
    server_dsn, output = sys.argv[1], Path(sys.argv[2])
    with psycopg.connect(server_dsn, autocommit=True) as connection:
        ensure_schema(connection)
        ensure_absurd_schema(connection)
    fixtures = []
    for path in sorted(FIXTURES.glob("*.json")):
        if path.name in FOREIGN:
            continue
        if path.name.startswith("joined-"):
            run = joined_replay(path, server_dsn)
        else:
            run = (lambda p: lambda: replay_path(p))(path)
        fixtures.append(record(path.name, path.read_bytes().rstrip(b"\n"), run))
        print(path.name, next(iter(fixtures[-1]["outcome"])), len(fixtures[-1]["calls"]), file=sys.stderr)
    mutations = [
        engine_mutation("changed-failure-location", "action-budget-exhaustion-world-v2.json", changed_failure),
        engine_mutation(
            "checker-version-mismatch",
            "projection-crash-recovery-world-v1.json",
            lambda d: d["checkers"][0].__setitem__("version", 2),
        ),
        engine_mutation(
            "journal-digest-mismatch",
            "projection-crash-recovery-world-v1.json",
            set_path("expected", ("journal_digest", "sha256:" + "0" * 64)),
        ),
        engine_mutation("checker-unregistered", "projection-crash-recovery-world-v1.json", lambda d: None, checkers=()),
        engine_mutation(
            "changed-seed-provenance",
            "seeded-projection-crash-recovery-world-v3.json",
            set_path("origin", ("seed", json.loads((FIXTURES / "seeded-projection-crash-recovery-world-v3.json").read_bytes())["origin"]["seed"] + 1)),
        ),
    ]
    for mutation in mutations:
        print(mutation["name"], json.dumps(mutation["outcome"])[:160], file=sys.stderr)
    output.write_text(
        json.dumps({"fixtures": fixtures, "mutations": mutations}, sort_keys=True, indent=None, separators=(",", ":"), ensure_ascii=True)
        + "\n"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
