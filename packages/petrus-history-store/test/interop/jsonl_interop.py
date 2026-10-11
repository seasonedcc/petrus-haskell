"""The reference's half of the JSONL interop suite (run from upstream/petrus).

Subcommands:
  write-every PATH   write every_record_category() through JsonlHistoryStore
  verify-every PATH  load PATH; records equal every_record_category(), bytes re-encode identically
  verify-bytes PATH  load PATH; every record re-encodes to the file's exact bytes
  begin PATH         drive the activity net to an in-flight activity occurrence (kill window 1)
  finish PATH        resume PATH, complete the one in-flight occurrence
  inspect PATH       resume PATH; assert the receipt marking; print the record count
  write-surrogates PATH    write surrogate_records() (token data, identity, result, error
                           holding lone surrogates)
  verify-surrogates PATH   load PATH; records equal surrogate_records(), bytes re-encode identically
  begin-surrogate PATH     `begin`, delivering surrogate_payment() (a memo with lone surrogates)
"""

from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.getcwd())

from petrus.impetus.history import (  # noqa: E402
    ActivityCompleted,
    ExternalEventDelivered,
    FiringFailed,
    TokensProduced,
)
from petrus.impetus.history.codec import encode_record  # noqa: E402
from petrus.impetus.history_store import JsonlHistoryStore  # noqa: E402
from petrus.impetus.instance import Instance  # noqa: E402
from petrus.impetus.petrinet import Marking, NetPath, Token  # noqa: E402
from tests.petrus.impetus.history_store.test_history_backends import (  # noqa: E402
    INTAKE,
    OUT,
    Charge,
    activity_net,
    payment,
)
from tests.petrus.impetus.history_store.test_persistence import every_record_category  # noqa: E402

RECEIPT = Marking({OUT: (Token("Receipt", {"status": "captured"}),)})

# Lone surrogates: a str may hold one, json.dumps escapes it ("\ud800") and
# json.loads reads it back. The Haskell suite's `surrogateRecords` is the same
# list; its strings are WTF-8 Text there.
SURROGATE_DATA = ("\ud800", {"\udc00x": ["a\ud83d", 1, "\udfff\ud800"]})


def surrogate_records() -> list:
    tokens = tuple(Token("Payment", data) for data in SURROGATE_DATA)
    return [
        ExternalEventDelivered(INTAKE, tokens, identity="evt-\udfff", occurrence=1, instant=1),
        TokensProduced(NetPath("queue"), tokens, occurrence=1, instant=1),
        ActivityCompleted(NetPath("work"), {"note": "\udbff!", "\ud800": None}, occurrence=2, instant=3),
        FiringFailed(NetPath("work"), "boom \ud800", occurrence=2, instant=4),
    ]


def surrogate_payment() -> Token:
    return Token("Payment", {"amount": 100, "memo": "\ud800 \udc00"})


def _reencoded(store: JsonlHistoryStore) -> bytes:
    return "".join(json.dumps(encode_record(r), allow_nan=False) + "\n" for r in store.records).encode()


def main(command: str, path: str) -> None:
    if command == "write-every":
        JsonlHistoryStore(path).extend(every_record_category())
    elif command == "verify-every":
        store = JsonlHistoryStore(path)
        assert store.records == tuple(every_record_category()), "records differ"
        assert _reencoded(store) == open(path, "rb").read(), "bytes differ"
    elif command == "verify-bytes":
        store = JsonlHistoryStore(path)
        assert _reencoded(store) == open(path, "rb").read(), "bytes differ"
        print(len(store))
    elif command == "write-surrogates":
        JsonlHistoryStore(path).extend(surrogate_records())
    elif command == "verify-surrogates":
        store = JsonlHistoryStore(path)
        assert store.records == tuple(surrogate_records()), "records differ"
        assert _reencoded(store) == open(path, "rb").read(), "bytes differ"
    elif command in ("begin", "begin-surrogate"):
        instance = Instance(
            activity_net(), handlers={"charge": Charge()}, history=JsonlHistoryStore(path), instance_id="interop-1"
        )
        delivered = payment() if command == "begin" else surrogate_payment()
        accepted = instance.accept_delivery(INTAKE, delivered, identity="evt_123", at=1)
        instance.complete_delivery(accepted, at=1)
        instance.begin(instance.candidates()[0], at=2)
    elif command == "finish":
        handler = Charge()
        resumed = Instance.resume(activity_net(), JsonlHistoryStore(path), handlers={"charge": handler})
        [occurrence] = resumed.in_flight
        resumed.record_activity_completion(occurrence, {"status": "captured"}, at=3)
        resumed.complete(occurrence, at=4)
        assert handler.prepared == 0, "prepare re-ran"
        assert resumed.marking == RECEIPT, resumed.marking
    elif command == "inspect":
        resumed = Instance.resume(activity_net(), JsonlHistoryStore(path), handlers={"charge": Charge()})
        assert resumed.marking == RECEIPT, resumed.marking
        assert resumed.watermark == 4, resumed.watermark
        assert str(resumed.instance_id) == "interop-1", resumed.instance_id
        print(len(resumed.history))
    else:
        raise SystemExit(f"unknown command {command!r}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
