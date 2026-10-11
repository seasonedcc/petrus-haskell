# hamsterdan-export divergences

The output never diverges. Given the same state directory and arguments,
both sides write the same package tree, the same numbers on stdout, the
same gap lines on stderr and the same exit status. A failure part-way
leaves the same partial package. [PARITY.md](PARITY.md) lists the tests
that hold the port to this.

Below are the differences that remain, with their rationale.

## Observable

1. **An uncaught exception prints only its last traceback entry.**
   - The binary prints the exception line (`Class: message`, the class
     module-qualified the way the traceback qualifies it, for example
     `json.decoder.JSONDecodeError` or `sqlite3.OperationalError`), then the
     notes CPython 3.14 attaches (`when serializing dict item 'k'`), and
     exits 1.
   - The reference prints the whole traceback, which ends in those same
     lines.
   - `export failed: ...` (exit 2) and argparse errors (exit 2) are
     identical.
2. **Help and usage text has no color.** CPython 3.14's `argparse` colors
   help on a terminal when `NO_COLOR` and `PYTHON_COLORS` allow it. The port
   writes the plain text, which is what the reference writes to a pipe. The
   width is the same: `COLUMNS`, else the terminal, else 80.
3. **Names and text that are not UTF-8: resolved, no longer a
   difference.**
   - Arguments and directory entries are decoded with `surrogateescape`
     (petrus-json's `fsDecode`), every path is encoded back with
     `fsEncode`, so an undecodable byte round-trips, and a surrogate that
     is not an escaped byte raises CPython's `UnicodeEncodeError`
     (`os.path.exists` and the other predicates answer `False` instead,
     as CPython's do).
   - Lone surrogates inside JSON (`"\ud800"`) and escaped in a board
     literal stay in their `str` (WTF-8, "Petrus.Json.Wtf8"). Writing one
     fails where CPython's does: a file (`write_text` truncates first, so
     an empty file is left), an operation id (`str.encode`), standard
     output (strict); standard error escapes it (`backslashreplace`).
   - The differential runs hostile cases for each, and command lines with
     undecodable arguments. APFS refuses names that are not UTF-8
     (`EILSEQ`), so the undecodable directory entries exist on Linux
     only; on macOS that case runs without them.
4. **JSON stored as UTF-16 or UTF-32 bytes: resolved, no longer a
   difference.** `json.loads(bytes)` is petrus-json's `loadsBytes`, which
   runs CPython's `detect_encoding` and decodes with `surrogatepass`, so
   such files load as in the reference (they used to raise
   `UnsupportedJsonEncoding`). `Hamsterdan.Python.Object`'s tests cover it.
5. **`str.lower()`: resolved, no longer a difference.** It used `base`'s
   Unicode 15.1 tables, without the final-sigma rule. It is now
   petrus-json's `pythonLower`: CPython 3.14's full mapping from the
   Unicode 16.0 tables, with `handle_capital_sigma`, checked against the
   pinned interpreter on every code point and in every final-sigma context
   (`PythonCompatSpec`). `str.isspace()`, `str.isprintable()` (in `repr`)
   and `int()` come from the same tables. The hostile case "the inbox
   holds delivery ids only Unicode 16.0 lower-cases alike" runs the
   reference on such ids.

## Internal (no observable difference)

- **Independent work runs on several cores.** The binary uses up to four
  capabilities (`-maxN4`).
  - History lines are parsed in parallel and boards are rendered in
    parallel. These are pure functions. The first failure in file order is
    the one reported, as in the reference.
  - Transcript and board files are planned in the reference's order, then
    written in parallel. A path planned twice gets its last contents.
  - If any parallel write fails, the files are removed and the plan is
    written again one by one. That raises at the first failure and leaves
    exactly the files the reference leaves. Each such directory is one the
    export just created empty.
  - Files are created in a different order, so their creation times
    differ.
- **Writes are unbuffered system calls.** A file is written with one
  `write` per contents. `inbox.jsonl` is collected in memory and written
  when it is closed, as the reference's buffered file is. Only an I/O error
  in the middle of `inbox.jsonl` could tell the two apart.
- **SHA-256 comes from crypton.** It is the same digest as `hashlib`, using
  the CPU's SHA instructions.
