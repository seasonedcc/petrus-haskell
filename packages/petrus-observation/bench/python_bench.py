"""Time the reference observation projections on the workloads of ``bench/Main.hs``.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-observation/bench/python_bench.py

The workload is a two-place loop (``a -> t1 -> b -> t2 -> a``) holding M
tokens, stepped until its History holds at least N records, built exactly as
the Haskell benchmark builds it. Each row times what one Engine read door
does under its lock: read the Instance's History records, then project.
Every timing is the median of several runs after one warm-up, in
milliseconds. Before the timings the script prints one SHA-256 per measured
output (compact, key-sorted, ASCII JSON); the Haskell benchmark prints the
same digests.
"""

from __future__ import annotations

import hashlib
import json
import statistics
import time

from petrus.impetus.instance import Instance
from petrus.impetus.observation import history_page, net_document, snapshot
from petrus.impetus.petrinet import Arc, Marking, Net, NetPath, Place, Token, Transition

A, B, T1, T2 = NetPath("a"), NetPath("b"), NetPath("t1"), NetPath("t2")
SNAPSHOT_WORKLOADS = [(n, m) for n in (1_000, 10_000) for m in (10, 1_000)]
DOCUMENT_WORKLOADS = [(1_000, 10), (10_000, 10), (1_000, 1_000)]
HISTORY_WORKLOADS = [(1_000, 10), (10_000, 10)]


def loop_net() -> Net:
    return Net(
        places=[Place(A), Place(B)],
        transitions=[Transition(T1), Transition(T2)],
        arcs=[Arc(A, T1), Arc(T1, B), Arc(B, T2), Arc(T2, A)],
    )


def item(n: int) -> Token:
    return Token("Item", {"i": n, "label": f"token-{n}"})


def built(records: int, tokens: int) -> Instance:
    instance = Instance(loop_net(), Marking({A: tuple(item(n) for n in range(tokens))}), instance_id="bench")
    while len(instance.history) < records:
        instance.step()
    return instance


def scan(instance: Instance) -> list[dict[str, object]]:
    records = instance.history.records
    return [history_page(instance.instance_id, records, after, 1000) for after in range(0, len(records), 1000)]


def digest(value: object) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    return hashlib.sha256(encoded.encode("ascii")).hexdigest()


def label(n: int, m: int) -> str:
    return f"N={n} M={m}"


def timed(name: str, action, runs: int) -> None:
    action()
    samples = []
    for _ in range(runs):
        started = time.perf_counter()
        action()
        samples.append((time.perf_counter() - started) * 1000)
    print(f"{name}: {statistics.median(samples):.3f} ms (median of {runs})", flush=True)


def main() -> None:
    snapshots = {(n, m): built(n, m) for n, m in SNAPSHOT_WORKLOADS}
    documents = {(n, m): snapshots.get((n, m)) or built(n, m) for n, m in DOCUMENT_WORKLOADS}
    histories = {(n, m): snapshots.get((n, m)) or built(n, m) for n, m in HISTORY_WORKLOADS}
    for (n, m), instance in snapshots.items():
        records = instance.history.records
        print(f"digest snapshot {label(n, m)} frontier={len(records)} {digest(snapshot(instance, records))}")
    for (n, m), instance in histories.items():
        records = instance.history.records
        page = history_page(instance.instance_id, records, 0, 1000)
        print(f"digest history_page(0,1000) {label(n, m)} {digest(page)}")
        pages = scan(instance)
        print(f"digest full_scan {label(n, m)} pages={len(pages)} {digest(pages)}")
    for (n, m), instance in documents.items():
        print(f"digest net_document {label(n, m)} {digest(net_document(instance, instance.history.records))}")
    for (n, m), instance in snapshots.items():
        timed(f"snapshot {label(n, m)}", lambda i=instance: snapshot(i, i.history.records), 20)
    for (n, m), instance in histories.items():
        timed(
            f"history_page(0,1000) {label(n, m)}",
            lambda i=instance: history_page(i.instance_id, i.history.records, 0, 1000),
            20,
        )
    for (n, m), instance in histories.items():
        timed(f"full-scan {label(n, m)}", lambda i=instance: scan(i), 5)
    for (n, m), instance in documents.items():
        timed(f"net_document {label(n, m)}", lambda i=instance: net_document(i, i.history.records), 5)


if __name__ == "__main__":
    main()
