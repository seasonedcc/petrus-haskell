"""Generate bench/inputs.json: the timer History the rebuild benchmark replays.

    upstream/hamsterdan/.venv/bin/python -I -B \
        packages/hamsterdan-host/bench/make_inputs.py

A reference ``V5TimerStore`` on a fake clock lives through 200 reminder
generations of one subject: every generation arms a fresh timer (superseding
the previous armed one); every third is then cancelled, and every other odd
one matures. The History a V5 Instance would carry is every acknowledged
``TimerCommandApplied`` plus every delivered ``TimerDue``, in order. Each
fact is written as ``{"applied": ...}`` or ``{"due": ...}`` holding the
model's JSON dump (``TypeAdapter.dump_python(mode="json")``). The generator
checks that a fresh store rebuilds from the History before writing it.
"""

from __future__ import annotations

import json
import tempfile
from pathlib import Path

from pydantic import TypeAdapter

from hamsterdan.contracts.readiness_v5 import (
    ArmReminder,
    CancelReminder,
    ReminderTimer,
    TimerCommand,
    TimerCommandApplied,
    TimerDue,
)
from hamsterdan.host.v5.timers import V5TimerStore

SUBJECT = "github:44:31:pr:7"
GENERATIONS = 200
OUT = Path(__file__).resolve().parent / "inputs.json"


def main() -> None:
    now = [1_786_838_400_000_000]
    facts: list[TimerCommandApplied | TimerDue] = []
    generation = 0
    with tempfile.TemporaryDirectory() as directory:
        store = V5TimerStore.open(Path(directory) / "timers.sqlite3", SUBJECT, clock_us=lambda: now[0])

        def applied(command: TimerCommand) -> None:
            result = store.apply(command)
            store.mark_ack_delivered(result.operation)
            facts.append(result)

        for index in range(1, GENERATIONS + 1):
            timer = ReminderTimer(
                id=f"timer:{SUBJECT}:i{index}:s0",
                incarnation=index,
                sequence=0,
                head=f"{index:040x}",
            )
            generation += 1
            applied(
                TimerCommand(
                    operation=f"timer-command:{SUBJECT}:g{generation}",
                    command=ArmReminder(kind="arm", timer=timer, delay_s=60),
                )
            )
            if index % 3 == 0:
                generation += 1
                applied(
                    TimerCommand(
                        operation=f"timer-command:{SUBJECT}:g{generation}",
                        command=CancelReminder(kind="cancel", timer=timer, reason="draft"),
                    )
                )
                now[0] += 1_000_000
            elif index % 2 == 1:
                now[0] += 61_000_000
                maturity = store.claim_due()
                assert maturity is not None and maturity.value.timer == timer
                store.mark_maturity_delivered(timer.id)
                facts.append(maturity.value)
            else:
                now[0] += 1_000_000
        store.close()
        rebuilt = V5TimerStore.open(Path(directory) / "rebuilt.sqlite3", SUBJECT, history=tuple(facts))
        rebuilt.close()
    rows = [
        {"applied": TypeAdapter(TimerCommandApplied).dump_python(fact, mode="json")}
        if isinstance(fact, TimerCommandApplied)
        else {"due": TypeAdapter(TimerDue).dump_python(fact, mode="json")}
        for fact in facts
    ]
    OUT.write_text(json.dumps({"subject": SUBJECT, "timer_history": rows}, sort_keys=True) + "\n")
    print(f"{len(rows)} timer facts -> {OUT}")


if __name__ == "__main__":
    main()
