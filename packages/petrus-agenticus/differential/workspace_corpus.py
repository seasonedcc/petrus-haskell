"""Generate the Hands workspace differential corpus from the reference.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-agenticus/differential/workspace_corpus.py \
        ../../packages/petrus-agenticus/differential/workspace_corpus.json

Sections:

* ``bounded_text``: ``_bounded_text(data, limit)`` over byte strings biased
  toward UTF-8 edge cases (truncated sequences, surrogates, overlongs, bytes
  above U+10FFFF), at the adapter's real limits and at small ones.
* ``search_lines``: the ``search`` projection of raw grep output
  (``_bounded_text`` at the command output limit, ``str.splitlines``, empty
  lines dropped, each line cut to 256 code points, at most 16 lines).
* ``stage_names``: the stage file name for a call id
  (``sha256(call_id.encode()).hexdigest()[:32]``) and the staged digest of
  the content.
"""

from __future__ import annotations

import hashlib
import json
import random
import sys

from petrus.agenticus.hands import workspace

SEED = 6061
EDGE = [
    b"\x00", b"a", b"\x7f", b"\x80", b"\xbf", b"\xc0", b"\xc1", b"\xc2", b"\xdf",
    b"\xe0", b"\xe0\xa0", b"\xe0\x80", b"\xed", b"\xed\x9f", b"\xed\xa0", b"\xee",
    b"\xef\xbf", b"\xf0", b"\xf0\x90", b"\xf0\x8f", b"\xf0\x90\x80", b"\xf4",
    b"\xf4\x8f\xbf", b"\xf4\x90", b"\xf5", b"\xff", "é".encode(), "€".encode(),
    "😀".encode(), "�".encode(), b"\n",
]


def sample(rng: random.Random) -> bytes:
    kind = rng.randrange(4)
    if kind == 0:
        return bytes(rng.randrange(256) for _ in range(rng.randrange(0, 24)))
    if kind == 1:
        return b"".join(rng.choice(EDGE) for _ in range(rng.randrange(0, 16)))
    if kind == 2:
        text = "".join(rng.choice("ab é€😀\n") for _ in range(rng.randrange(0, 20)))
        return text.encode()
    return rng.choice(EDGE) * rng.randrange(1, 12)


def main() -> None:
    rng = random.Random(SEED)
    bounded = []
    for limit in (workspace.MAX_READ_BYTES, workspace.MAX_STREAM_BYTES):
        for payload in (b"\xff" * (limit + 10), "😀".encode() * (limit // 4 + 3), b"x" * limit, b"x" * (limit - 1) + "é".encode()):
            text, truncated = workspace._bounded_text(payload, limit)
            bounded.append({"hex": payload.hex(), "limit": limit, "text": text, "truncated": truncated})
    for _ in range(1500):
        payload = sample(rng)
        limit = rng.choice((0, 1, 2, 3, 4, 5, 7, 8, 16, len(payload), max(0, len(payload) - 1)))
        text, truncated = workspace._bounded_text(payload, limit)
        bounded.append({"hex": payload.hex(), "limit": limit, "text": text, "truncated": truncated})
    search = []
    separators = ["\n", "\r\n", "\r", "\v", "\f", "\x1c", "\x1d", "\x1e", "\x85", "\u2028", "\u2029", "\n\n"]
    for _ in range(200):
        parts = []
        for _ in range(rng.randrange(0, 24)):
            parts.append("".join(rng.choice("ab:1 é😀") for _ in range(rng.choice((0, 1, 5, 12, 0, 1, 5, 12, 0, 1, 5, 12, 255, 256, 257)))))
            parts.append(rng.choice(separators))
        raw = "".join(parts).encode() + sample(rng)
        text, _ = workspace._bounded_text(raw, workspace._COMMAND_OUTPUT_LIMIT)
        lines = [line[: workspace.MAX_SEARCH_MATCH_CHARS] for line in text.splitlines() if line]
        search.append({"hex": raw.hex(), "lines": lines[: workspace.MAX_SEARCH_MATCHES]})
    names = []
    for call_id in ("call", "discard", "cleanup", "é", "😀", "x" * 128, "call-1"):
        names.append(
            {
                "call_id": call_id,
                "name": workspace._digest(call_id.encode())[:32],
                "digest": workspace._digest(call_id.encode()),
            }
        )
    corpus = {
        "constants": {
            "STAGE_DIRECTORY": workspace.STAGE_DIRECTORY,
            "MAX_READ_BYTES": workspace.MAX_READ_BYTES,
            "MAX_SEARCH_MATCHES": workspace.MAX_SEARCH_MATCHES,
            "MAX_SEARCH_MATCH_CHARS": workspace.MAX_SEARCH_MATCH_CHARS,
            "MAX_STREAM_BYTES": workspace.MAX_STREAM_BYTES,
            "COMMAND_OUTPUT_LIMIT": workspace._COMMAND_OUTPUT_LIMIT,
        },
        "bounded_text": bounded,
        "search_lines": search,
        "stage_names": names,
    }
    with open(sys.argv[1], "w") as handle:
        json.dump(corpus, handle, separators=(",", ":"))
        handle.write("\n")


if __name__ == "__main__":
    main()
