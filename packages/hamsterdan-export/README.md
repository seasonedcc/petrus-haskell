# hamsterdan-export

Hamsterdan's offline evidence exporter: `python -m hamsterdan.host.export`
(`src/hamsterdan/host/export.py`) as the `hamsterdan-export` binary.

Given a host state directory, a repository and a pull request, it writes one
self-contained evidence package:

- canonical History and its index;
- every landed board;
- one transcript document per agent operation attempt, with its session
  JSONL when the agent runtime kept one;
- the webhook inbox and, when supplied, the raw delivery records;
- the identity files;
- `MANIFEST.json` and `README.md`.

It names every gap it finds on stderr (`GAP: ...`) and prints the numbers on
stdout.

The package tree, the numbers, the gap lines, the exit status and every
error message are the reference's, byte for byte. That includes the partial
package a failure part-way leaves behind.

```
hamsterdan-export --state-dir STATE --out PKG --repository OWNER/NAME --pull-request N \
  [--webhook-deliveries DIR]... [--identity FILE]...
```

The command-line parser is petrus-argparse's `argparse` port: the same
usage, help, abbreviations, error messages and colors, wrapped to
`COLUMNS`.

Evidence and the remaining differences are in [PARITY.md](PARITY.md),
[DIVERGENCES.md](DIVERGENCES.md) and [bench/RESULTS.md](bench/RESULTS.md).
