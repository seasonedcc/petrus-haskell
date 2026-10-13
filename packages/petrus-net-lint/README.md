# petrus-net-lint

A Petri net is not a state machine with one central state. Its state is its marking: which
tokens sit in which places, spread across the net. A process's concurrency, its waiting, and its
scarce resources live in the net's places and transitions, never inside a token's data.

A net's marking can still collapse into one token: one token walking a chain of places, with each
handler deciding where it goes next and counting what it used in its own fields. Petrus runs such
a net fine, but nothing in its structure shows what waits on what or what is scarce, so no tool
can check it. This lint finds the signs, in a net's structure and in what its author declares,
and says where each one is.

## Running it

```sh
petrus-net-lint NET.json
```

`NET.json` is a Net-definition v3 or a Net document v1, the documents Petrus projects from any
built net, in Haskell or in Python. The lint reads `NET.declared.json` and `NET.waivers.json`
beside it when they exist. It prints each finding on its own line and exits 1 when there is any.

A test suite calls the library instead, so a net that fails doesn't build green:

```haskell
lint net declared waivers `shouldBe` []
```

## What the author declares

A definition shows the arcs, not what a handler does with them. A transition with two output
places may fill both, or choose one. So the author declares each transition's outcomes in
`NET.declared.json`:

```json
{ "v": 1,
  "initial": {"key-ring": 1},
  "outcomes": {
    "revoke": [
      {"name": "recorded", "when": "success", "puts": {"destroying": 1}},
      {"name": "refused", "when": "success", "puts": {"key-ring": 1}},
      {"name": "failed", "when": "failure", "puts": {"key-ring": 1}}]},
  "ingress": [],
  "final_places": [],
  "final_markings": [{"key-ring": 1}],
  "laws": [{"name": "the key ring", "weights": {"key-ring": 1, "destroying": 1, "@revoke": 1}, "total": 1}],
  "scenarios": [{"name": "two requests", "deliver": {"request": 2}}] }
```

- `initial` is how many tokens each place starts with.
- `outcomes` lists each way a firing can end, and what it puts in each place. A transition with a
  `failure` outcome runs an Activity. One with no declared outcomes fills each output place by
  its arc's weight.
- `ingress` are places a caller fills from outside the net, such as an inbox.
- `final_places` are places a token may rest in for good.
- `final_markings`, `laws` and `scenarios` are for behavioral checks, such as `petrus-net-check`:
  the markings the net may come to rest in, the weighted sums of tokens every reachable marking
  keeps, and small runs, each saying how many times a caller delivers to each source transition
  or ingress place. A law counts an Activity's firings in flight as `@transition`.

Every member but `v` may be left out, and a member the lint doesn't know is refused, so a
misspelled one isn't quietly ignored.

## What it reports

| Rule | What it finds |
| --- | --- |
| `single-token-s-net` | The marking collapsed into one token: every transition takes one token and puts at most one, ignoring read and inhibitor arcs, and the initial marking holds at most one. |
| `no-concurrency` | No transition forks into two places or joins two, anywhere in the net. |
| `handler-choice` | A transition whose declared successes fill different places, one per firing. An Activity's failure is the world's answer, not the handler's choice, so success against failure isn't one. |
| `undeclared-outcomes` | A transition with a handler and two or more output places, and no declared outcomes, so nobody can tell whether it forks or chooses. |
| `status-switch` | Two or more filters taking tokens from one place, or a field that inline CEL guards and filters compare against two or more constants, such as `token.kind == "checks"`. |
| `counted-resource` | A field that an inline CEL guard or filter compares with `<`, `<=`, `>=` or `>`. Symbol guards and filters are code the lint can't read. |
| `lonely-place` | A place nothing fills, or nothing empties. A place is filled by a transition, by the initial marking, or by a caller as declared `ingress`. A declared final place needn't be emptied, and neither does a standing fact that a read or inhibitor arc checks. |
| `checked-once` | A read or inhibitor arc on a transition that runs an Activity. The engine checks it only when the transition fires, never while the Activity runs, so it is no lock. Take a token to hold one, or check again where the outcome joins. |
| `declaration` | A declaration naming a place or transition the net doesn't have, or a scenario delivering to something that is neither a source nor ingress. |

## Waivers

The rules are heuristics, and a real net can trip one for a good reason: a request's kind, fixed
when it is made and never rewritten, isn't a status it moves through. A justified finding is
waived in `NET.waivers.json`:

```json
{ "v": 1,
  "waivers": [
    {"rule": "handler-choice", "at": "revoke",
     "reason": "It decides on what History holds: whether that version exists and isn't revoked yet.",
     "accepted_by": "the review that accepted the net"}] }
```

A waiver that no longer matches a finding is a finding itself, `stale-waiver`, so waivers can't
pile up. A `declaration` finding can't be waived.
