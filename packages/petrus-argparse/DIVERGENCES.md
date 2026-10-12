# petrus-argparse: divergences from CPython 3.14's `argparse`

The package ports the parts of `argparse` and `_colorize` that the pinned
references' command lines use. Within that subset, parsing, the namespace,
help, usage, error text, wrapping and colors are meant to be identical. The
test suite builds the same parsers in the pinned interpreter and compares
them case by case. The Hamsterdan and Petrus command-line suites compare
the real entry points as well.

Within the subset, one difference: `argparse.FileType("r")` and `("w")`
open the file while parsing, in the same order and with the same errors,
but the namespace keeps its name rather than the open handle (the port
closes it again). A command line that uses the file reopens it by name, so
it sees the file as it is then.

Outside the subset, these `argparse` features are not ported, because no
reference command line declares them: `nargs` other than the default, `"*"`
and a subparser's, `FileType` modes other than `"r"` and `"w"`, `count`,
`version`, mutually exclusive and argument groups, `epilog`,
`usage=`, `prefix_chars`, `fromfile_prefix_chars`, `allow_abbrev=False`,
`exit_on_error=False`, `suggest_on_error`, `parse_intermixed_args`, and
`%(default)s`-style help expansion.

Colors follow `_colorize.can_colorize()` for a process that reads its
environment, as `python -m` runs without `-E` or `-I`. `PYTHON_COLORS`
decides first, then `NO_COLOR`, `FORCE_COLOR`, `TERM=dumb`, and whether
standard output is a terminal. A user theme set with `_colorize.set_theme`
has no counterpart, because the references set none.
