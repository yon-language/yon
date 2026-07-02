---
id: arrows
title: "7. Arrows"
sidebar_position: 7
---

import ProjectStructure from '@site/src/components/ProjectStructure';
import GeomorphAdjunction from '@site/src/components/GeomorphAdjunction';

# Arrows

A restaurant runs on things that happen at different levels. The price of a dish
is just a number. Reading an order's running total is an observation: you look,
you do not change it. Sending an order to the kitchen carries it across a
boundary, from the dining room to the line. Tallying the courses at the end
interprets a sequence of actions into one figure. These are not the same kind of
act, and in Yon they are not the same kind of arrow.

Everything that *maps* in Yon is an arrow with a categorical kind, and the kind
says which level it lives at. Arrows are first class: they bind, compose, and
apply, under a discipline the compiler enforces. You pick the lowest rung that
does the job, and the type checker holds you to it.

| Kind | Lives between | What it does | In the restaurant |
|---|---|---|---|
| `fun` | values | a plain morphism of values | compute a service charge |
| `view … of P` | a place → values | observe a place, read-only | read an order's total |
| `move … from P to Q` | place → place | carry content across places (and Spaces) | send an order to the kitchen |
| `reduction … of P` | a place's operations → a value | interpret operations (a handler) | tally the courses |
| `geomorph … from P to Q` | site → site | an adjunction between two sites | link the dining room and the kitchen |
| `functor … from W to V` | world → world | translate a whole context | convert one bank's world into another's |
| `nat transform … from F to G` | functor → functor | relate two translations | the gap between two exchange rates |

## The restaurant on disk

A world is not a block you write inside a file. It is a declaration in
`yon.toml`, and the rest of the structure is the project's layout: a **space** is
a directory, a **place** is a file, and each arrow is a file that names a
morphism. Our restaurant has two spaces, the `sala` (the dining room) and the
`cucina` (the kitchen line). Here it is, exactly as it compiles.

<ProjectStructure />

The world, declared once, in `yon.toml`:

```toml
[world.Restaurant]
objects = ["Guest"]
spaces  = ["sala", "cucina"]
```

An order is a file, `sala/Order.yon`. Its fields are its sections; its
`operation`s are the things a guest can do to it, which is why it is declared
`with effects`:

<!-- yon-gate: illustrative -->
```yon
place Order with effects {
  table number
  total number
  operation add_item(price: number): number
}
```

Nothing here says which world `Order` belongs to. It does not need to: it lives
in `sala/`, and `sala` is a space of the `Restaurant` world by the `yon.toml`
above. The layout carries the binding, and the compiler reads it back. Every
code block from here on is a file of this one project, and the project compiles.

## `fun`: a plain computation

The humblest arrow claims nothing about places. A service charge is a morphism of
numbers, and that is all it is:

<!-- yon-gate: illustrative -->
```yon
fun service(n: number): number { return n + n / 10 }
```

A `fun` is welcome everywhere precisely because it knows nothing: it cannot read
an order, cannot cross a boundary, cannot interpret an operation. It just
computes. That modesty is what lets the arrows above it *hire* it for one job, as
a view and a move are about to.

## `view`: observe a place, never change it

To read an order without touching it, you write a **view**, `sala/Bill.yon`. It
can `show` a stored section, or a computed column that factors through a `fun`:

<!-- yon-gate: illustrative -->
```yon
fun service(n: number): number { return n + n / 10 }
view Bill of Order { show charged = service(total) }
```

A view is an observation out of a place, and it is read-only *by construction*:
there is no syntax for it to write a field. The reason is not a rule bolted on: a
view is a projection, and a projection has nowhere to put a new value. The waiter
reads the bill. The waiter does not rewrite it.

## `move`: the only way content crosses

When an order leaves the dining room for the kitchen, its content crosses a
boundary, from the `sala` space to the `cucina` space. That crossing is a
**move**, and it is the *only* way content travels between places.
`sala/ToKitchen.yon`:

<!-- yon-gate: illustrative -->
```yon
fun identity(x: number): number { return x }
move ToKitchen from Order to Ticket {
  total maps to total by identity
}
```

A move's body is a list of mapping clauses. `maps to` renames a field into the
target; `converts to … by f` transforms it through a function, the `fun` it
hires; `aggregates to` folds several sources into one. The `Ticket` place is the
kitchen's copy, and it lives in the other space, `cucina/Ticket.yon`:

<!-- yon-gate: illustrative -->
```yon
place Ticket {
  total number
}
```

A move is a capability-gated border crossing: it may declare `requires CAP`, and
it can touch only the fields its clauses name. That discipline is exactly what
makes it sound to carry an order not just to another place but, later, across a
**Space** boundary into another process. Content crosses on a move, or it does
not cross.

## `reduction`: what the operations mean

An order is not only fields; it is a sequence of `operation`s, each `add_item`. To
say what those operations *mean*, you write a **reduction**, an eliminator that
folds the place's operations into a value. `sala/Tally.yon`:

<!-- yon-gate: illustrative -->
```yon
reduction Tally of Order {
  on add_item(price: number) { return price }
}
```

A reduction does not touch sections at all. It gives meaning to operations, which
is why it is activated as a handler over a block, `with Tally of Order { … }`,
rather than applied to a section. It is the algebra of the order: every
`add_item` is interpreted, and the interpretations fold into the tally.

Four arrows, four levels, and each one *cannot* do what the next one does. That
is the point. The view cannot write; the move cannot look outside its clauses;
the reduction never sees a section; the `fun` claims nothing at all. The kind is
the contract, and the compiler is the maître d'.

## Arrows are closed

An arrow travels. You bind it, `compose` it, and apply it elsewhere, possibly on
the far side of a Space boundary, in another process with its own memory. So an
arrow's body must be **closed**: it may use only its own parameters and the
top-level definitions of the project (functions, places, worlds), never a local
from the scope it was written in. This is enforced. A move that reaches for an
enclosing local is a compile-time error:

<!-- yon-gate: illustrative -->
```yon
be base holds 7
be m holds move(s: Order) => new Ticket { total base } from Order to Ticket
```

The compiler refuses it and says why: the move's body captures the enclosing
local `base`; a morphism may use only its own parameters and top-level
definitions, never a local from the surrounding scope, because it escapes its
definition site and runs elsewhere, where a captured local would have nothing to
point at. The fix is to pass `base` as a parameter, or lift it to a top-level
`fun`.

The reason is structural, and the restaurant makes it concrete. An instruction
carried out in the kitchen cannot say "the number I was thinking of on the
floor." It has to carry every value it needs with it, because by the time it
runs, the dining room is out of reach. A `fun` is the opposite case, and
deliberately so: a value combinator, the lambda you hand to `fold`, lives and
dies on the spot, so it captures its enclosing locals freely, at any depth. A
`fun` stays in the room; a morphism leaves it. The distinction *is* the
discipline.

## `geomorph`: an adjunction between two sites

A move sends one order across, one way. But the `sala` and the `cucina` are not
just two places with a courier between them; they are two *views of the same
service*, and what an order is on one side has a counterpart on the other. That
correspondence is a **geomorph**, an adjunction between the two sites. It is not
one arrow but an adjoint pair, `push` and `pull`, that carry each side to the
other and are held consistent by the adjunction. `cucina/Line.yon`:

<!-- yon-gate: illustrative -->
```yon
geomorph Line from Order to Ticket {
  pull(t: Ticket): Order { be o holds t  return o }
  push(o: Order): Ticket { be t holds o  return t }
}
```

<GeomorphAdjunction />

`push` sends an order to its ticket; `pull` brings a ticket back to its order.
The point of the geomorph, over a bare pair of moves, is the *law*: `push` is
left-adjoint to `pull` (you can mark `adjunction`, and `exact pull` / `exact
push`), which is what makes "the ticket in the kitchen" and "the order in the
dining room" two faithful sides of one thing rather than two loosely related
records. Where a move is a courier, a geomorph is a translation between two
whole contexts, and the adjunction is its guarantee of coherence.

## One level up: between worlds

The last two rungs relate whole **worlds**, and a restaurant has only one. They
are natural where there are two worlds to compare, so step next door, to a bank
that keeps its books in two currencies. Its `yon.toml` declares two worlds:

```toml
[world.EurBank]
objects = ["Money"]
spaces  = ["eur"]

[world.UsdBank]
objects = ["Dollar"]
spaces  = ["usd"]
```

A **functor** translates one world into the other, objects and operations
together. Converting the euro books into dollar books at a rate is exactly that,
a structure-preserving map of the entire accounting context, `eur/Rates.yon`:

<!-- yon-gate: illustrative -->
```yon
functor Spot(x: number) from EurBank to UsdBank { return x * 110 / 100 }
```

A functor may carry `law identity` and `law composition` for the checker to
verify, the promise that it maps the identity to the identity and respects
composition, so the translated books add up the same way the originals do.

A **nat transform** relates two functors, one component per object of the source
world. Two rates give two functors, the spot rate and the forward rate, and the
adjustment from one to the other is a natural transformation, the same shift
applied coherently to every account:

<!-- yon-gate: illustrative -->
```yon
functor Fwd(x: number) from EurBank to UsdBank { return x * 112 / 100 }
nat transform Adjust from Spot to Fwd { for each Money by Spot }
```

`Adjust` is not a number; it is the *family* of adjustments, one per object,
that turns the spot translation into the forward one, coherently across the whole
world. That is what "natural" means: not case by case, but the same move at every
object, and the checker holds the naturality square.

These higher arrows obey the same kind discipline as the lower ones: composing
two things of the wrong kind is rejected, because the levels would not line up.
You will not reach for a functor to send one order to the kitchen; a move does
that. You reach for it when you want to translate an *entire* world onto another
and have the compiler check that the translation respects the structure. Pick the
lowest rung that does the job. The whole chapter, in one line, is that the rung is
part of the type, and the type checker will not let you pretend otherwise.

Where content actually crosses between Spaces, and what a `move` becomes when its
target lives in another process, is [chapter 16](/book/how-spaces-talk).
