"""Time the reference CEL path on the cases of ``bench/Main.hs``.

Run from the repository root with the pinned upstream virtual environment:

    upstream/petrus/.venv/bin/python packages/petrus-cel/bench/time_cel.py

Each case goes through ``petrus.impetus.binding.cel`` (cel-python 0.5.0), the
way the Impetus kernel uses it. Three measurements per case, matching the
Haskell benchmark:

* ``parse``: ``celpy.Environment().compile(source)`` (lark parse to a tree);
* ``evaluate``: one call of the precompiled filter/guard/completion (this
  builds the activation with ``celpy.json_to_cel`` on every call);
* ``compile+evaluate``: ``compile_filter``/``compile_guard``/
  ``compile_completion`` followed by one evaluation.

Each figure is the best of 5 runs of the mean time per call, with the loop
count chosen so a run lasts at least 0.2 s.
"""

from __future__ import annotations

import platform
import sys
import time

import celpy

from petrus.impetus.binding.cel import compile_completion, compile_filter, compile_guard
from petrus.impetus.petrinet import Binding, Cel, Marking, NetPath, Token


def payment(amount: int) -> Token:
    return Token("Payment", {"amount": amount, "currency": "USD", "status": "paid"})


def filter_case(name, source, token, expected):
    return name, source, lambda s: compile_filter(Cel(s)), token, expected


def guard_case(name, source, binding, expected):
    scope = {place for place, _ in binding.consumed + binding.read}
    return name, source, lambda s: compile_guard(Cel(s), binding.transition, scope), binding, expected


def completion_case(name, source, places, marking, expected):
    return name, source, lambda s: compile_completion(Cel(s), places), marking, expected


CONFIG = Token("Config", {"limit": 200})


def result(state: str) -> Token:
    return Token("Result", {"state": state})


P = NetPath

CASES = [
    filter_case("filter/field", "amount >= 100", payment(150), True),
    filter_case(
        "filter/conjunction",
        'amount >= 100 && currency == "USD" && !(status in ["void", "refunded"])',
        payment(150),
        True,
    ),
    filter_case(
        "filter/regex",
        r"email.matches(r'^[a-z.]+@example\.com$')",
        Token("Customer", {"email": "jane.doe@example.com"}),
        True,
    ),
    guard_case(
        "guard/correlate",
        "pending[0].data.amount <= config[0].data.limit",
        Binding(P("approve"), ((P("pending"), (payment(150),)),), ((P("config"), (CONFIG,)),)),
        True,
    ),
    guard_case(
        "guard/macros",
        "pending.all(t, t.data.amount < 500) && size(pending.filter(t, t.data.amount > 100)) >= 1",
        Binding(P("approve"), ((P("pending"), tuple(payment(a) for a in [*range(10, 101, 10), 150])),)),
        True,
    ),
    completion_case(
        "completion/all",
        "size(pending) == 0 && accepted.all(t, t.data.amount >= 100)",
        [P("pending"), P("accepted"), P("rejected")],
        Marking(
            {
                P("accepted"): tuple(payment(a) for a in range(100, 291, 10)),
                P("rejected"): tuple(payment(a) for a in range(1, 6)),
            }
        ),
        True,
    ),
    completion_case(
        "completion/exists",
        'done.exists(t, t.color == "Result" && t.data.state == "ok") && size(failed) == 0',
        [P("done"), P("failed")],
        Marking({P("done"): (result("pending"), result("running"), result("ok"))}),
        True,
    ),
]


def per_call(action) -> float:
    """Best-of-5 mean seconds per call, each run lasting at least 0.2 s."""
    loops = 1
    while True:
        start = time.perf_counter()
        for _ in range(loops):
            action()
        if time.perf_counter() - start >= 0.2:
            break
        loops *= 2
    best = float("inf")
    for _ in range(5):
        start = time.perf_counter()
        for _ in range(loops):
            action()
        best = min(best, (time.perf_counter() - start) / loops)
    return best


def show(seconds: float) -> str:
    if seconds >= 1e-3:
        return f"{seconds * 1e3:.2f} ms"
    return f"{seconds * 1e6:.1f} us"


def main() -> None:
    print(f"Python {sys.version.split()[0]} on {platform.machine()} ({platform.platform()}), celpy {celpy.__version__ if hasattr(celpy, '__version__') else '0.5.0'}")
    for name, source, compiler, value, expected in CASES:
        predicate = compiler(source)
        assert predicate(value) is expected, name
        environment = celpy.Environment()
        timings = {
            "parse": per_call(lambda: environment.compile(source)),
            "evaluate": per_call(lambda: predicate(value)),
            "compile+evaluate": per_call(lambda: compiler(source)(value)),
        }
        print(f"{name:20} " + "  ".join(f"{k}: {show(v):>10}" for k, v in timings.items()))


if __name__ == "__main__":
    main()
