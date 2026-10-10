"""Time the reference History stores on the same workloads as ``bench/Main.hs``.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-history-store/bench/python_bench.py

The History is the same 20 002 records the Haskell side builds (a drained
4 000-token FIFO); every timing is the median of several runs after one
warm-up, printed in milliseconds with a result size the Haskell side
computes too.
"""

from __future__ import annotations

import os
import shutil
import statistics
import sys
import tempfile
import time

from petrus.impetus.history import FiringCompleted
from petrus.impetus.history_store import InMemoryHistoryStore, JsonlHistoryStore, SqliteHistoryStore
from petrus.impetus.instance import Instance
from petrus.impetus.petrinet import Arc, Marking, Net, NetPath, Place, Token, Transition

HISTORY_FIFO_TOKENS = 4_000
PER_RECORD_APPENDS = 2_000
TERMINAL_RESENDS = 1_000


def remove_database(path: str) -> None:
    for suffix in ("", "-wal", "-shm"):
        if os.path.exists(path + suffix):
            os.remove(path + suffix)


def fifo(tokens: int) -> tuple[Net, Marking]:
    net = Net(
        places=[Place(NetPath("queue")), Place(NetPath("taken"))],
        transitions=[Transition(NetPath("take"))],
        arcs=[Arc(NetPath("queue"), NetPath("take")), Arc(NetPath("take"), NetPath("taken"))],
    )
    return net, Marking({NetPath("queue"): tuple(Token("Item", {"seq": n}) for n in range(tokens))})


def timed(name: str, action, repeats: int) -> None:
    size = action()
    samples = []
    for _ in range(repeats):
        start = time.perf_counter()
        action()
        samples.append(time.perf_counter() - start)
    print(f"{name:28} {statistics.median(samples) * 1000:12.3f} ms   (size {size}, n={repeats})")
    sys.stdout.flush()


def main() -> None:
    net, marking = fifo(HISTORY_FIFO_TOKENS)
    instance = Instance(net, marking, instance_id="bench")
    instance.run()
    history = list(instance.history.records)
    directory = tempfile.mkdtemp(prefix="petrus-history-store-bench")
    existing = os.path.join(directory, "existing.jsonl")
    fresh = os.path.join(directory, "fresh.jsonl")
    JsonlHistoryStore(existing).extend(history)
    memory = InMemoryHistoryStore()
    memory.extend(history)
    loaded = JsonlHistoryStore(existing)

    def append_one_batch() -> int:
        store = JsonlHistoryStore(fresh)
        store.extend(history)
        n = len(store)
        os.remove(fresh)
        return n

    def append_per_record() -> int:
        store = JsonlHistoryStore(fresh)
        for record in history[:PER_RECORD_APPENDS]:
            store.append(record)
        n = len(store)
        os.remove(fresh)
        return n

    def in_memory_append() -> int:
        store = InMemoryHistoryStore()
        for record in history:
            store.append(record)
        return len(store)

    def resume() -> int:
        resumed = Instance.resume(net, JsonlHistoryStore(existing))
        return len(list(resumed.marking))

    timed("jsonl/append-one-batch", append_one_batch, 5)
    timed("jsonl/append-per-record", append_per_record, 5)
    timed("jsonl/load", lambda: len(JsonlHistoryStore(existing)), 5)
    timed("jsonl/resume", resume, 3)
    existing_sqlite = os.path.join(directory, "existing.sqlite3")
    fresh_sqlite = os.path.join(directory, "fresh.sqlite3")
    SqliteHistoryStore(existing_sqlite, "bench").extend(history)

    def sqlite_append(chunks) -> int:
        store = SqliteHistoryStore(fresh_sqlite, "bench")
        for chunk in chunks:
            store.extend(chunk)
        n = len(store)
        store.close()
        remove_database(fresh_sqlite)
        return n

    def sqlite_load() -> int:
        store = SqliteHistoryStore(existing_sqlite, "bench")
        n = len(store)
        store.close()
        return n

    def sqlite_resume() -> int:
        store = SqliteHistoryStore(existing_sqlite, "bench")
        resumed = Instance.resume(net, store)
        n = len(list(resumed.marking))
        store.close()
        return n

    first = history[:PER_RECORD_APPENDS]
    terminal = next(record for record in history if isinstance(record, FiringCompleted))
    resent = SqliteHistoryStore(existing_sqlite, "bench")

    def terminal_resend_ack() -> int:
        for _ in range(TERMINAL_RESENDS):
            resent.extend([terminal])
        return len(resent)

    timed("sqlite/append-one-batch", lambda: sqlite_append([history]), 5)
    timed("sqlite/append-per-record", lambda: sqlite_append([[record] for record in first]), 3)
    timed("sqlite/append-batches-of-8", lambda: sqlite_append([first[i : i + 8] for i in range(0, len(first), 8)]), 3)
    timed("sqlite/load", sqlite_load, 5)
    timed("sqlite/resume", sqlite_resume, 3)
    timed("sqlite/terminal-resend-ack", terminal_resend_ack, 3)
    resent.close()
    timed("store/in-memory-append", in_memory_append, 20)
    timed("store/in-memory-records", lambda: len(memory.records), 20)
    timed("store/jsonl-records", lambda: len(loaded.records), 20)

    def iterate() -> int:
        n = 0
        for _ in memory:
            n += 1
        return n

    timed("store/in-memory-iterate", iterate, 20)
    shutil.rmtree(directory)


if __name__ == "__main__":
    main()
