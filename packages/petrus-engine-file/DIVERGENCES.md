# petrus-engine-file: divergences from petrus-engine

The reference is `upstream/petrus-engine` at `fc1dd50`, on CPython 3.14 with
its locked pydantic 2. This package matches it on every file the
differential corpus and the live fuzzing produce. That covers what is
accepted and what is refused, the error classes and texts, the bytes
written, and the resolved nets and schemas. Each difference below is either
outside what a net file can reach or a deliberate scope decision.

## 1. Lone surrogates in `json.loads` strings

`reformat_content` (the format CLI) and `FlatNet.from_dict` take their input
from `json.loads`. That parser turns an unpaired escape such as `"\ud800"`
into a Python string holding a lone surrogate. Haskell `Text` cannot hold
one. Such a document is refused with `UnsupportedLoneSurrogate: a string
holds a lone surrogate, which this implementation cannot represent`, where
the reference would carry the surrogate through and write it back as an
escape.

Files read through `from_filename` use jiter, which never yields a lone
surrogate, so they are unaffected. The corpus marks the operations involved
(`lone_surrogate_ops`), and the test requires this refusal for them.

## 2. Recursion limits

`compact_json` recurses in Python once per nesting level. Under
`python -m petrus.cli.format_json`, a document nested more than 990
containers deep raises `RecursionError: maximum recursion depth exceeded`.
`toJson` and `reformatContent` raise the same error past the same depth.
`CliSpec` checks both sides at 990 and 991 levels, for lists, objects, and
arc and place metadata.

A Python program calling `reformat_content` or `to_json` from a different
stack depth hits the limit a few levels earlier or later; called directly
from a script, it is 992. The Haskell threshold is fixed at the CLI's.

`json.loads` itself overflows the C stack at around a million levels
(`RecursionError: Stack overflow (used N kB) ...`, with a machine-dependent
N). The Haskell parser has no such limit, and such a document is refused by
the formatter's limit above instead.

Files read through `from_filename` are limited to 200 levels by jiter, and
that refusal is reproduced exactly.

## 3. Sorting arcs whose paths hold lists

`FlatNet` sorts arcs by `(source, target)`. A file can only produce a
non-string path segment by writing an arc endpoint as a JSON array. When
that happens, Python compares the segments with `<`. That can raise
`TypeError` (`'<' not supported between instances of 'list' and 'str'`),
and with NaN it gives an inconsistent order.

For fewer than 64 arcs, Haskell replays the exact comparisons CPython's
timsort makes (`count_run`, then binary insertion), so the result, or the
first comparison that raises, is the same. For 64 or more such arcs it uses
a stable merge sort. A consistent order is still the same order, but a
raising comparison may name a different pair of types, and a NaN order may
differ.

When every segment is a string, which is every file the viewer writes, the
order is exact at any size.

## 4. The format CLI's surface

`petrus-format-json` matches the reference's options, behavior, exit
statuses, stdout, written files, and the final line of every error. It
differs in these ways:

- On an exception it prints only that final line
  (`pydantic_core._pydantic_core.ValidationError: ...`), not the traceback
  frames before it.
- Its usage and help text name the program `petrus-format-json`, and are
  not wrapped to the terminal width as argparse wraps them.
- `--indent` and `--max-inline` accept the integers Python's `int()` does
  (surrounding whitespace, a sign, single underscores), but in ASCII digits
  only; Python also accepts other Unicode decimal digits.
- Stdin is decoded as strict UTF-8, which is what Python does under a UTF-8
  locale. Under the C/POSIX locale Python would use `surrogateescape`
  instead.

## 5. Kernel nets

The reference has no kernel. petrus-engine runs a `FlatSchema` in its own
`PetriNetRuntime`, and Petrus's v3 net definition states that there is no v2
migration. `toKernel` is a Haskell addition, so that loaded files can run on
`petrus-impetus`. It admits a net only when the kernel's `mkNet` does.
petrus-engine runs these nets, but the kernel refuses them, with its own
messages:

- `read` or `inhibitor` on an output arc. petrus-engine ignores the kind
  there, but kernel modes are input inscriptions.
- An arc that does not connect a declared place and a declared transition.
- An arc weight below 1. A weight beyond the kernel's `Int` is refused here
  with `arc weight N does not fit the kernel's Int: s -> t`.
- A transition without a handler whose input arcs only read or inhibit.
- A guard or a delay on a transition with no input arcs.
- A delay on a transition whose input arcs are all inhibitors.
- A handler or guard name that is empty or starts with `$`.
- A path with an empty segment (`a..b`).
- A place and a transition with the same path.

A net the kernel accepts has the same places, transitions, arcs and initial
marking as the schema. Labels, interfaces, metadata and view state have no
kernel slot and are dropped. An empty net name becomes an unnamed net.

Running the net follows the kernel's semantics, not `PetriNetRuntime`'s:

- handlers return routed tokens;
- a delay matures from its youngest selected token's entry instant, not from
  the start of an enablement epoch.

## 6. Scope

- **Other file versions.** petrus-engine stores `fileVersion` as an
  unrestricted string and reads every file with the v2 models; this package
  does the same, as the corpus checks with `"1"` and `"3"` (and a JSON number,
  refused as a string field would be). The
  older nested format petrus-viewer once wrote has no loader upstream, and
  the viewer refuses it (`fileIO.ts`: `expected fileVersion "2"`), so it is
  not ported.
- **Not ported (SCOPE.md).** petrus-engine's DSL, runtime, tokens, timers
  and stub generator are not ported; the `petrus` runtime supersedes them.
  So `test_dsl_roundtrip_schema_maps_match`, which builds the same net with
  the DSL, is not ported.
