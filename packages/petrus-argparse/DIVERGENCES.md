# petrus-argparse: divergences from CPython 3.14's `argparse`

The package ports the parts of `argparse` and `_colorize` that the pinned
references' command lines use. Within that subset, parsing, the namespace,
help, usage, error text, wrapping and colors are meant to be identical. The
test suite builds the same parsers in the pinned interpreter and compares
them case by case. The Hamsterdan and Petrus command-line suites compare
the real entry points as well.

None that is observable for the subset.

Outside it, these `argparse` features are not ported, because no reference
command line declares them: `nargs` other than the default, `store_const`,
`count`, `version`, mutually exclusive and argument groups, `epilog`,
`usage=`, `prefix_chars`, `fromfile_prefix_chars`, `allow_abbrev=False`,
`exit_on_error=False`, `suggest_on_error`, `parse_intermixed_args`, and
`%(default)s`-style help expansion.

Colors follow `_colorize.can_colorize()` for a process that reads its
environment, as `python -m` runs without `-E` or `-I`. `PYTHON_COLORS`
decides first, then `NO_COLOR`, `FORCE_COLOR`, `TERM=dumb`, and whether
standard output is a terminal. A user theme set with `_colorize.set_theme`
has no counterpart, because the references set none.
