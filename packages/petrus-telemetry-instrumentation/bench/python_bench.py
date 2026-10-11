"""Time the reference's telemetry on the same workloads as ``bench/Main.hs``.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-telemetry-instrumentation/bench/python_bench.py

Two workloads, each timed as the median of several runs after one warm-up:

- **emit**: 1 000 emits of one 6-field payload through a logger with bound
  context (``instance``, ``net``), with the level ``off``; at ``facts`` with
  no handler configured (the default: ``JsonLogger`` still runs
  ``json.dumps`` before the stdlib logger drops the INFO record); at
  ``facts`` with a ``NullHandler`` on an INFO-enabled logger (the line is
  formatted and a ``LogRecord`` is handled); and under ``capture()`` (a
  ``TelemetryRecorder``). Reported per emit.
- **chain**: 50 tokens through 20 passthrough transitions (1 000 firings),
  driven by ``Instance.run()`` and by one-action ``Engine.advance()`` turns,
  with telemetry ``off``, ``facts`` with no handler, ``facts`` with a
  ``NullHandler``, and ``profile`` (the Engine's gauges after every applied
  action) with no handler and with a ``NullHandler``. The overhead is
  relative to ``off``.
- **line**: ``JsonLogger``'s ``json.dumps`` alone on the full 9-field
  payload, and the ``time.time()`` read alone.

It also prints the routed line for the emit payload with ``ts`` pinned; the
Haskell bench prints the same bytes (and the differential test checks them).
"""

from __future__ import annotations

import json
import logging
import statistics
import sys
import time

import petrus.telemetry as telemetry
from petrus.engine import Engine
from petrus.impetus.history_store import InMemoryHistoryStore
from petrus.impetus.instance import Instance
from petrus.impetus.petrinet import Arc, Marking, Net, NetPath, Place, Token, Transition
from petrus.motus.dispatch import InMemoryDispatch

EMITS = 1000
CHAIN_LENGTH = 20
CHAIN_TOKENS = 50
TS = 1700000000123

log = telemetry.get_logger("impetus").bind(instance="i-1", net="n")


def emit_batch() -> int:
    for occurrence in range(EMITS):
        log.emit("firing_completed", transition="t", occurrence=occurrence, instant=7, records=3, impure=False, source="s")
    return EMITS


def line_batch() -> int:
    # JsonLogger's formatting alone: json.dumps({**payload, "ts": ms}, default=str).
    for occurrence in range(EMITS):
        payload = {
            "event": "impetus_firing_completed",
            "instance": "i-1",
            "net": "n",
            "transition": "t",
            "occurrence": occurrence,
            "instant": 7,
            "records": 3,
            "impure": False,
            "source": "s",
        }
        json.dumps({**payload, "ts": TS}, default=str)
    return EMITS


def clock_batch() -> int:
    for _ in range(EMITS):
        int(time.time() * 1000)
    return EMITS


def chain_net() -> Net:
    places = [Place(NetPath(f"p{i}")) for i in range(CHAIN_LENGTH + 1)]
    transitions = [Transition(NetPath(f"t{i}")) for i in range(CHAIN_LENGTH)]
    arcs = []
    for i in range(CHAIN_LENGTH):
        arcs.append(Arc(NetPath(f"p{i}"), NetPath(f"t{i}")))
        arcs.append(Arc(NetPath(f"t{i}"), NetPath(f"p{i + 1}")))
    return Net(places=places, transitions=transitions, arcs=arcs)


def chain_marking() -> Marking:
    return Marking({NetPath("p0"): tuple(Token("Item", {"seq": k}) for k in range(CHAIN_TOKENS))})


def instance_chain() -> int:
    instance = Instance(chain_net(), chain_marking(), instance_id="chain")
    return len(instance.run())


def engine_chain() -> int:
    engine = Engine.create(
        chain_net(), "chain", history=InMemoryHistoryStore(), dispatch=InMemoryDispatch(), marking=chain_marking()
    )
    while engine.advance().ready:
        pass
    size = len(engine.records)
    engine.close()
    return size


def median_ms(action, repeats: int) -> tuple[float, object]:
    size = action()
    samples = []
    for _ in range(repeats):
        start = time.perf_counter()
        action()
        samples.append(time.perf_counter() - start)
    return statistics.median(samples) * 1000, size


class Configuration:
    """A level plus whether the stdlib logger has an INFO-enabled NullHandler."""

    def __init__(self, level: str, null_handler: bool):
        self.level = level
        self.null_handler = null_handler

    def __enter__(self):
        logger = telemetry.python_logger
        self.saved = (telemetry.level(), logger.level, list(logger.handlers), logger.propagate)
        telemetry.set_level(self.level)
        if self.null_handler:
            logger.setLevel(logging.INFO)
            logger.handlers = [logging.NullHandler()]
            logger.propagate = False
        return self

    def __exit__(self, *exc):
        logger = telemetry.python_logger
        level, logger_level, handlers, propagate = self.saved
        telemetry.set_level(level)
        logger.setLevel(logger_level)
        logger.handlers = handlers
        logger.propagate = propagate
        return False


CONFIGURATIONS = {
    "off": Configuration("off", False),
    "facts-no-handler": Configuration("facts", False),
    "facts-null-handler": Configuration("facts", True),
    "profile-no-handler": Configuration("profile", False),
    "profile-null-handler": Configuration("profile", True),
}
EMIT_CONFIGURATIONS = ("off", "facts-no-handler", "facts-null-handler")


def pinned_line() -> str:
    lines = []

    class Collect(logging.Handler):
        def emit(self, record):
            lines.append(record.getMessage())

    collector = logging.getLogger("petrus-telemetry-bench")
    collector.setLevel(logging.INFO)
    collector.propagate = False
    collector.addHandler(Collect())
    real = telemetry.time.time
    telemetry.time.time = lambda: TS / 1000
    try:
        telemetry.get_logger("impetus", telemetry.JsonLogger(collector)).bind(instance="i-1", net="n").emit(
            "firing_completed", transition="t", occurrence=1, instant=7, records=3, impure=False, source="s"
        )
    finally:
        telemetry.time.time = real
    return lines[0]


def main() -> None:
    print(f"pinned line: {pinned_line()}")
    print()
    for name in EMIT_CONFIGURATIONS:
        with CONFIGURATIONS[name]:
            ms, _ = median_ms(emit_batch, 50)
        print(f"emit/{name:24} {ms * 1000 / EMITS:10.3f} us per emit")
        sys.stdout.flush()
    with telemetry.capture():
        ms, _ = median_ms(emit_batch, 50)
    print(f"emit/{'recorder':24} {ms * 1000 / EMITS:10.3f} us per emit")
    ms, _ = median_ms(line_batch, 50)
    print(f"line/{'json.dumps':24} {ms * 1000 / EMITS:10.3f} us per line")
    ms, _ = median_ms(clock_batch, 50)
    print(f"line/{'time.time':24} {ms * 1000 / EMITS:10.3f} us per read")
    print()
    for workload, action, rounds in (("instance-run", instance_chain, 15), ("engine-advance", engine_chain, 11)):
        # Interleaved rounds (off, no handler, null handler, off, ...) so
        # machine-load drift hits every configuration alike.
        samples: dict[str, list[float]] = {name: [] for name in CONFIGURATIONS}
        size = None
        for round_ in range(rounds + 1):
            for name, configuration in CONFIGURATIONS.items():
                with configuration:
                    start = time.perf_counter()
                    size = action()
                    elapsed = time.perf_counter() - start
                if round_ > 0:  # round 0 warms up
                    samples[name].append(elapsed * 1000)
        baseline = statistics.median(samples["off"])
        for name in CONFIGURATIONS:
            ms = statistics.median(samples[name])
            overhead = (ms / baseline - 1) * 100
            print(f"chain/{workload}/{name:20} {ms:10.3f} ms  ({overhead:+.1f}% vs off, size {size}, n={rounds})")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
