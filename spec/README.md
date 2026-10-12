# 1 Specifications added by this repository

This directory holds language-neutral contracts that upstream does not
write down, and the conformance checklists that tie specifications to
executable checks. It sits beside upstream's own specification
(`upstream/petrus/spec/`, at the commit [UPSTREAM.md](../UPSTREAM.md) pins)
and follows its layout and conventions (upstream `spec/README.md` §1a to
§1c).

Upstream has no specification for Fabric or for process call and spawn; the
two documents here are derived from the pinned Python reference, which stays
the reference binding [DR 2026-07-06 implementation-language-python-first].
They state every rule in implementation-free terms and cite Python only as
provenance. Conformance evidence has the scope upstream gives it: a
normative behavior without an executable check is a coverage gap, and each
checklist names the check for every obligation.

## 1a Documents

- [fabric.md](fabric.md): Fabric protocol version 1, the inter-Instance
  protocol plane: addressing, authorization, delivery, acknowledgement and
  retention between independently authoritative Instances over one
  PostgreSQL database.
- [processes.md](processes.md): process lifecycle protocol version 1,
  `call` and `spawn` above Fabric, and the shared lineage registry.
- [fabric-conformance.md](fabric-conformance.md): the testable obligations of
  fabric.md, each with its level (`unit`, `db`, `engine`, `interop`) and the
  check that verifies it.
- [processes-conformance.md](processes-conformance.md): the same for
  processes.md.
- [impetus-conformance.md](impetus-conformance.md): the testable obligations
  of upstream's six core documents (`net-schema.md`, `firing-semantics.md`,
  `event-history.md`, `handler-contract.md`, `net-definition-v3.md`,
  `net-document-v1.md`), each mapped to the check that verifies it.

The two specifications are self-contained enough to read alone; processes.md
reuses fabric.md's value model, canonical JSON and error categories by
reference. The checklists also say how this repository's implementation is
checked against them; the specifications themselves name no implementation
but the reference.

## 1b Sources and citation convention

The documents here use upstream's labels, with upstream's meaning:

- `[ADR NNNN]`: a Hermes ADR, in upstream's
  `docs/project/decisions/records/` as `*hermes-adr-NNNN-*.md`.
- `[DR <date> <slug>]`: an Ariad decision record in the same folder, named
  `<date>T<time>Z-<slug>.md`, e.g.
  `[DR 2026-07-20 process-fabric-is-an-inter-authority-protocol-plane]`.
- `[glossary]`: upstream's glossary at `docs/project/glossary/`.

Python sources and tests are cited by their path in `upstream/petrus`
(`src/petrus/fabric/postgres.py`, `tests/petrus/fabric/test_fabric.py`).
Such a citation is provenance, like upstream's `[Petrus oracle]`: the
executable evidence is the conformance checklist.

## 1c Marker conventions

- `**OPEN**`: upstream's `**OPEN:**` marker, with its meaning unchanged: an
  unresolved point, a gap that needs a decision before relying on a default.

Upstream writes its specifications from the design. The specifications here
are derived from an implementation, so each derived behavior also says
whether another implementation must reproduce it. Two markers extend
upstream's convention for that:

- `**CONTRACT**`: observable on the wire, in the database, or in a
  recipient's canonical History. A conforming implementation MUST match it
  exactly. A behavior observable in shared state whose intent is unclear is
  classified CONTRACT.
- `**ACCIDENT**`: a reference behavior not observable in shared state, or
  one upstream would plausibly treat as a defect. A conforming implementation
  MAY differ, and interoperability checks MUST NOT depend on it. Where it
  matters, the text says what an implementation SHOULD do instead.

Upstream's `**VELOCITRON-DIVERGENCE:**` marker has no use here.
[fabric.md §1](fabric.md#1-status-scope-and-normative-language) defines the
normative key words and these markers for both documents.
