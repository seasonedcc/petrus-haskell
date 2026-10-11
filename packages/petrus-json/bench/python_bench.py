"""CPython's C-accelerated ``json`` on the documents of petrus-json's benchmarks.

Run by scripts/bench and scripts/bench-compare with the pinned interpreter
(``scripts/upstream-python``), from ``upstream/petrus``. Prints one
``name,nanoseconds`` line per benchmark, named like ``bench/Main.hs``'s. Each
row starts from bytes and ends in bytes or a value, with the options of the
upstream call site it stands for.
"""

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "scripts"))
from bench_timing import report  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"


def unique(pairs):
    # petrus.impetus.net_document._pairs
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON member {key!r}")
        result[key] = value
    return result


def no_constant(value):
    raise ValueError(f"non-finite JSON number {value}")


def main() -> None:
    # The C scanner and encoder, not the pure-Python fallbacks.
    assert json.decoder.c_scanstring is not None and json.encoder.c_make_encoder is not None
    history = [line for line in (FIXTURES / "history.jsonl").read_bytes().split(b"\n") if line]
    document = (FIXTURES / "net-document.json").read_bytes()
    threads = [line for line in (FIXTURES / "threads.jsonl").read_bytes().split(b"\n") if line]
    records = [json.loads(line) for line in history]
    document_value = json.loads(document)
    thread_values = [json.loads(line) for line in threads]

    # petrus.impetus.history_store.jsonl: json.loads(line), json.dumps(record, allow_nan=False)
    report("history.loads", lambda: [json.loads(line) for line in history])
    report("history.dumps", lambda: [json.dumps(record, allow_nan=False).encode() for record in records])
    # the canonical spelling of conflict judgments (simulation, observation, fabric)
    report(
        "history.dumps-canonical",
        lambda: [
            json.dumps(record, allow_nan=False, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
            for record in records
        ],
    )
    # petrus.impetus.net_document: parse_net_document, serialize_net_document
    report("net-document.loads", lambda: json.loads(document))
    report("net-document.loads-strict", lambda: json.loads(document, object_pairs_hook=unique, parse_constant=no_constant))
    report("net-document.dumps", lambda: json.dumps(document_value, ensure_ascii=False, allow_nan=False, indent=2).encode())
    # petrus.agenticus thread documents: json.loads, and the repository's writer
    report("thread.loads", lambda: [json.loads(line) for line in threads])
    report(
        "thread.dumps",
        lambda: [json.dumps(value, allow_nan=False, separators=(",", ":"), sort_keys=True).encode() for value in thread_values],
    )


main()
