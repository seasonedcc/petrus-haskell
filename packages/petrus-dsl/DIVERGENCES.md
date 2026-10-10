# petrus-dsl: divergences from the Python reference

The DSL has no wire format of its own. Its contract is the canonical `Net` it
builds. For every model the two DSLs can both express, the Haskell DSL builds
the same Net:

- the same Net-definition v3 bytes;
- the same first-touch order of places and transitions;
- the same arc order;
- the same implementation URIs and anonymous display names;
- or the same refusal text.

`differential/dsl_corpus.json` checks this for 68 cases. Refusals the
reference raises as `ValueError` come back as `Left DslError` with the same
message text.

The differences below are in API shape. Python's decorators, proxies, and
mutable objects become Haskell combinators, types, and values. None of them
changes a built Net.

Pinned reference: `upstream/petrus` 3f85fc2, `src/petrus/impetus/dsl.py`.

## Shape of the API

| Python | Haskell |
| --- | --- |
| `net = NetSpec("orders")`, then statements on `net` | `netSpec (named "orders") $ do ...` returns `Either DslError NetSpec` |
| `NetSpec()` | `netSpec unnamed ...` |
| `NetSpec(name, completion=...)` | `withCompletion completion (named name)` |
| `net.p.pending`, `net.t.process` | `p "pending"`, `t "process"` |
| `net.s.review.p.pending`, `net.s["review"]` | `scope "review" (p "pending")` |
| `abs(node)` | `nodePath node` |
| `net.p.pending(Order)`, `net.place(node, color=Order)` | `p "pending" >>= color "Order"`, or `color (colorOf @Order)` |
| `node.override(color=...)` | `recolor (Just c)` / `recolor Nothing` |
| `node.color` | `placeColor node` |
| `net.t.x(handler=..., guards=..., timers=...)`, `net.transition(...)` | `t "x" >>= configure [handler ..., guards [...], timers [...]]` |
| `transition.override(handler=None, guards=())` | `override [noHandler, guards []]` |
| `a >> b`, `a >> arc.read(...) >> b` | `a ~> b`, `a ~> readArc {...} ~> b` |
| `(a, b) >> t` | `sequence [p "a", p "b"] ~> t "t"` (or a list of handles) |
| `arc(weight=2)`, `arc.read(...)`, `arc.inhibit(...)` | `arc {arcWeight = 2}`, `readArc`, `inhibitArc` |
| `scope.stamp(child)` | `scope "s" (stamp child)` |
| `net.connections` | `connections spec` |
| `net.build()`, `NetBuilder(net).build()` | `build spec` |
| `net.copy()` | `flatten spec` |
| `@direct`, `direct(converter=...)` | `direct "name" args` |
| `typed_guard(f)`, a bare callable guard | `typedGuard "name" args` |
| `petri_handler(f)`, `petri_guard(f)` | `petriHandler "name" f`, `petriGuard "name" f` |

### Statements with values

`~>` returns its right operand, like `>>`, so chains compose left to right.
Python discards a chain's value. In a Haskell `do` block, write
`void $ a ~> b ~> c`.

### Atomic steps are observable

Every authoring step either succeeds or leaves the specification unchanged,
as in the reference. `attempt step` runs a step and returns its refusal as
`Left`, so a program can keep authoring after the refusal. This is the
Haskell form of `pytest.raises(...)` followed by more statements.

## Checked by the type system instead of at run time

Each of these reference refusals guards against a value the Haskell types
cannot express. The corresponding upstream test is listed as "enforced by
types" in PARITY.md.

- **Connections between two specifications.** `Author s` carries a rank-2
  brand `s`, so a handle from one `netSpec` cannot be used in another. Python
  refuses this at run time with "different net specifications".
- **Arcs that join two places or two transitions.** `~>` requires one end to
  be a place and the other a transition (the `Joins` type family). Python
  defers this to the canonical Net ("connect a place and a transition").
- **A node used as a handler or a guard; a raw callable as a handler.**
  `HandlerSpec` and `GuardSpec` are closed types. A function becomes a
  handler only through `direct`, `petriHandler`, or `activityHandler`.
- **Mutable or generator guard collections.** `guards` takes a list, which is
  immutable.
- **`arc(mode=...)`, the `>` operator, a color that is not a type or
  string, `NetBuilder(non-spec)`, and non-string scope segments.** None of
  these can be written.
- **A typed guard that returns a non-`bool`.** `typedGuard` takes a
  `TypedArgs Bool`, so "must return bool, got str" cannot happen.

## Specifications are values

A Python `NetSpec` is a mutable object, and a stamp is a live link to it. A
Haskell `NetSpec` is an immutable value.

- **Stamps embed a snapshot of the child.** In the reference, changing a child
  after stamping it changes what the parent builds next
  (`test_stamped_specification_remains_live_between_immutable_build_snapshots`).
  Here the child is a value, so you change it by stamping the new value. The
  corpus cases `live.first` and `live.second` check that both builds match
  the reference.
- **`copy()` is `flatten`.** It composes the stamps into one flat
  specification with the same name. Because the original never changes, the
  copy is already "without source links".
- **Stamp cycles are refused only in Python.** A cycle needs a specification
  that contains itself. Finite values cannot do that. A knot-tied lazy value
  would make `build` diverge, so the reference's "stamp cycle: ..." refusal
  has no counterpart.
- **A build reflects the program up to `netSpec`.** Python's "snapshot, then
  configure more, then build again" becomes two programs, or one program
  that branches on a flag (see the `late-configuration` and
  `callable-snapshots` corpus cases).

## Implementations

- **Identity is the display name.** Python keeps a function object in its
  `HandlerSpec` and `GuardSpec`. Configuring the same function twice is
  idempotent, and a different one is refused. A Haskell function has no
  identity, so each implementation gets an explicit display name. Two
  implementation specs are the same declaration when their flavor
  (direct, Petri-aware, typed guard, activity) and display name match.

  The display name is the reference's `__name__` (for example
  `AnonymousDeclaration(display_name='process')`). Like `__name__`, it never
  reaches the canonical Net's semantics.
- **The converter is the `Typed` instance.** `direct(converter=c)` and
  `typed_guard(converter=c)` decode with a converter object. Here decoding is
  the `Typed` instance of each parameter type. A different decoding of the
  same color is a newtype with its own instance (`StringOrder` in the tests).
  Because decoding is structural, the order of converter calls the reference
  test records cannot be observed.
- **`activityHandler` is an addition.** The reference binds Activity bridges
  after building, by URI (the Agent-as-Net does this). `activityHandler`
  makes the same binding while authoring. The `agent-net` corpus case uses
  the reference's way.
- **`withImplementations` is an addition.** It adds a `BuiltNet`'s handlers
  and guards, keyed by canonical URI, to an `InstanceConfig`. This replaces
  passing `built.handlers` and `built.guards` to `Instance(...)`.

## Small differences

- `p` and `t` accept dotted relative names (`p "review.pending"`). This is the
  same as `scope "review" (p "pending")`. Python reaches only one segment per
  attribute, so it needs `net.s.review.p.pending`.
- Python identifiers starting with `_` are not reachable through
  `net.p.<name>`. Haskell names are text, so they are. The kernel's path rules
  still apply.
- An empty list of handles on either side of `~>` is refused with "expected a
  node specification or non-empty tuple of them, got []". Python names the
  empty tuple `()`.
