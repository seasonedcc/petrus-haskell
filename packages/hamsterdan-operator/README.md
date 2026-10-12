# hamsterdan-operator

Hamsterdan's bounded human-operator tooling: `python -m hamsterdan.operator`
(`src/hamsterdan/operator.py`) as the `hamsterdan-operator` binary, and
`src/hamsterdan/host/publication_qualification.py`, the qualification
fences the operator's setup command runs, as
`Hamsterdan.Host.PublicationQualification`.

```
hamsterdan-operator preflight [--health-url URL]
hamsterdan-operator create --scenario SCENARIO
hamsterdan-operator prepare-broker
hamsterdan-operator inspect --pr N [--bot-login LOGIN] [--expect-hero-review] [--expect-readiness {present,absent}]
hamsterdan-operator inspect-authority --pr N --expect EXPECTATION
hamsterdan-operator qualification-setup --credential-file FILE --target-file FILE --spent-marker FILE
```

- The demo commands (`preflight`, `create`, `prepare-broker`, `inspect`,
  `inspect-authority`) act through the operator's own `gh` and Git
  identity.
- `qualification-setup` consumes one private credential file into a bounded
  child environment, pushes a two-ref fixture atomically behind a spent
  marker, and reads it back.
- No command takes a credential value as an argument, and none repeats
  provider prose or command output.

Each command prints one sorted-key JSON object and exits 0 when it reports
`"ok": true`, 1 otherwise. That object, the exit status, every `gh` and
`git` command line in order, and the files written are the reference's,
byte for byte. The command-line parser is petrus-argparse's `argparse`
port, so the usage, help, abbreviations, errors and colors are also the
reference's.

The package also carries the Haskell image's runtime contract:
`deployment/Containerfile`, `deployment/python-shim`, `.dockerignore`,
`cabal.project.freeze`, and the reference's
`scripts/with-runtime-secrets`, `deployment/config` and `deployment/pi`,
copied byte for byte. The tests live here; the files are at the repository
root, where the image build expects them.

Evidence and the remaining differences are in [PARITY.md](PARITY.md),
[DIVERGENCES.md](DIVERGENCES.md) and [bench/RESULTS.md](bench/RESULTS.md).
