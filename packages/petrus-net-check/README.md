# petrus-net-check

Explores every marking of a Petri net's skeleton, for small scenarios its author declares, and
checks that the net keeps its laws, never stops where it may not rest, and can always come to
rest. It is the behavioral half of `petrus-net-lint`, and reads the same declarations.

## Running it

```sh
petrus-net-check NET.json
```

`NET.json` is a Net-definition v3 or a Net document v1. The checker reads `NET.declared.json`
beside it (the lint's `README.md` has its format). It prints what each scenario reached, each
problem with the firings that lead to it from the scenario's start, and the net's P-invariants.
It exits 1 when there is any problem.

A test suite calls the library instead:

```haskell
[p | r <- (check defaultLimits net declared).reports, p <- r.problems] `shouldBe` []
```

## The skeleton

The checker abstracts the net's colors away. A place holds a count of tokens. Every filter and
guard is taken to hold, so a transition is enabled when each consume and read arc finds as many
tokens as its weight, and each place it inhibits is empty. Timers are taken to have matured.

What a firing puts is one of its declared outcomes, or each output place by its arc's weight when
none is declared. A transition with a `failure` outcome runs an Activity: it takes its inputs when
it starts, is in flight as `@transition`, and puts one outcome when it ends, so other transitions
fire in between.

So the skeleton can do things the real net can't, where a filter, guard or timer would stop it,
and the colors can do things the skeleton doesn't show. Deterministic simulation of the real
handlers (`petrus-dst`) covers what the skeleton abstracts.

## Scenarios

Each scenario starts from the declared initial marking, and delivers to source transitions and
ingress places as many times as it says, at any moment. With no scenario declared, the checker
explores the initial marking alone. A net whose handlers fill several places needs their
outcomes declared before it can be checked: taken to fill every output place at once, a large
net's markings multiply past any limit. Keep scenarios small, such as one to three requests and pools
of one or two: the number of markings grows fast, and the checker stops past 200,000 markings or
32 tokens in one place.

## The checks

- **`law`:** a declared law's weighted sum differs from its total in a reachable marking.
- **`deadlock`:** nothing can happen, and the net may not rest in that marking.
- **`never-rests`:** from a reachable marking, no marking the net may rest in can be reached.
- **`unbounded`** and **`too-large`:** the exploration stopped.

A marking the net may rest in has every delivery made and no Activity in flight, and matches a
declared final marking, leaving final places out. With no final markings declared, it holds
tokens only in final places. So a net with a pool declares the pool full as its final marking,
and a request stuck holding a pool's token never counts as at rest.

Each problem comes with a shortest firing sequence that reaches it, and the marking it ends in. In
a marking, `@transition` counts that Activity's firings in flight, and `+name` the deliveries
still to come to a source or ingress place. The checker also lists the
net's minimal semi-positive P-invariants, by Farkas' algorithm, over its places and Activities in
flight, so a law nobody declared still shows.
