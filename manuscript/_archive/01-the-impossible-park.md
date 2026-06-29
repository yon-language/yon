---
id: the-impossible-park
title: "Chapter 1 — The Impossible Park"
sidebar_position: 1
slug: /book/the-impossible-park
description: "Why a hundred thousand dinosaurs, seen by three departments at once, break every mainstream language — and what it would mean for the compiler to refuse the bug."
---

# Chapter 1 — The Impossible Park

A hundred thousand dinosaurs move through the park, and each is two things at
once: an animal with a heartbeat and a position, and a row of data someone
wants to query. Storing them isn't the hard part. The hard part is that the
biologist, security, and legal look at the *same* animal and must see
*different* things — and none of the three may see what isn't theirs.

The biologist needs the genome, the biometrics, the feeding curve. Security
needs the position and the containment status, and nothing about the genome.
Legal needs to answer "how many animals are in cohort 7?" without ever touching
an individual's identity — that is the whole point of the privacy regime they
operate under. Three lenses, one animal. The lenses are not a feature you bolt
on at the end. They are the shape of the problem.

Here is the claim this book will make good on, starting in this chapter: in
every mainstream language, "the legal view may not see individual identity" is
a *promise* — written in a comment, guarded by code review, and broken the
first afternoon someone is in a hurry. In Yon it is something the compiler
**refuses to betray**.

## The promise in a comment

Watch how the promise is made in Java. We have a dinosaur, and we have a
"legal view" whose job is to expose aggregates without identity.

```java
// The "legal" projection. RULE: never expose individual identity.
// (See compliance doc §4. Reviewers: please enforce.)
final class LegalView {
    private final Dinosaur dino;
    LegalView(Dinosaur dino) { this.dino = dino; }

    int cohort() { return dino.cohort(); }          // allowed: it's an aggregate key
    // ... and nothing else. That's the rule.
}
```

The rule lives in a comment and in the discipline of whoever reads it. Nothing
in the language knows the rule exists. Six months later, a new analyst needs
"just the id, for a one-off join," and writes:

```java
int id() { return dino.individualId(); }            // ships. compiles. reviewed on a Friday.
```

It compiles. It passes the tests, because the tests encode the same intentions
the comment did. The invariant — *the legal lens never sees identity* — was
never a fact the machine could check. It was a hope. The data-leak you would
pay a regulatory fine for is, at the level of the language, indistinguishable
from correct code.

Python, Go, TypeScript do no better here; the projection is a method, and a
method can return whatever its author types. SQL gets closer with views and
column grants, but the guarantee stops at the database boundary and says
nothing about the program that reads it. The pattern is the same everywhere:
*the invariant is enforced by people, not by the language.*

## What if the compiler refused

Now the same scene in Yon. The three lenses are not three classes that redact
different fields. They come from the *structure* of the problem — and in Yon you
don't write that structure in code: **the project's shape is the declaration.**
The park is a directory tree, and the worlds live in its manifest, `yon.toml`:

```toml
# yon.toml
[world.Park]
objects = ["Species"]

[world.PublicPark]
quotient = ["Park", "cohort"]      # PublicPark is Park "up to cohort"
```

```
park/
  yon.toml
  Main.yon                 # the entrypoint (a place Entry + fun main)
  herd/Dinosaur.yon        # the "herd" space  → world Park
  public/PublicDino.yon    # the "public" space → world PublicPark
```

A folder is a world; a file inside it is a space; a record in the file
**inherits its folder's world**. Science works in `Park` — the whole animal
lives in `herd/`:

```yon
// herd/Dinosaur.yon          (world Park, inherited from the folder)
place Dinosaur {
  individual_id number
  cohort number
  heart_rate number
}
```

The legal lens lives in `public/`, a space of `PublicPark = Park / cohort` — the
park seen **up to cohort**. Here is the move with no equivalent in a mainstream
language: in that folder a record may carry *only* data invariant under the
relation. A public dinosaur may know its cohort, and nothing that tells one
individual from another:

```yon
// public/PublicDino.yon      (world PublicPark, a quotient of Park)
fun bucket_of(c: number): number { return c }

place PublicDino {
  cohort number                    // the relation field: invariant, allowed
}

view LegalLens of PublicDino {
  show bucket = bucket_of(cohort)  // a function of cohort: it descends
}
```

This compiles. Now try to give the public record an identity — add one line to
`public/PublicDino.yon`:

```yon
place PublicDino {
  cohort number
  individual_id number             // NOT determined by cohort
}
```

It **does not compile**. Not "fails a test," not "warns" — the type checker
rejects it:

> place `PublicDino` is not a sheaf on the quotient world
> `PublicPark = Park / cohort`: field(s) individual_id are not invariant under
> `cohort`.

Read what that means, because it is stronger than redaction. The world is not a
keyword you write — it is the **folder your file lives in**. `public/` *is*
PublicPark. You cannot put identity into the public folder, because the folder's
world forbids it. The Friday-afternoon leak is not a bug that ships — it is a
data model that never builds. The thing the Java comment *asked* for, Yon makes
impossible to violate.

:::tip Key idea
On a quotient world `A / r` — here the `public/` folder — **every field of a
record must be invariant under `r`**, and every view must factor through `r`.
Data that distinguishes individuals the relation calls equal simply cannot live
there. This is the sheaf/descent condition, enforced as a typing rule — at the
record level, not only the view. Privacy stops being a convention and becomes a
property the compiler checks for you. (The full story is Chapter 8.)
:::

## See it: one animal, three lenses

The interactive below shows a single dinosaur and lets you switch between the
three departmental lenses. Watch what each lens can and cannot reach — and note
that the legal lens doesn't merely *hide* identity, it works in a world where
identity is *not expressible*.

> _Interactive component: `ThreeLenses` (source in
> `manuscript/components/ThreeLenses.jsx`; rendered inline in the chat preview
> while drafting)._

## Run it yourself

Every claim in this book ships with something you can build. This chapter's
guarantee is a project:

- `regression/book/01/park_project/` — the park as a directory tree (`yon.toml`,
  `herd/Dinosaur.yon`, `public/PublicDino.yon`). It compiles:
  `yoner_emit_mlir park_project` exits `0`; `Dinosaur` lands in world `Park`,
  `PublicDino` and `LegalLens` in `PublicPark`.
- `regression/book/01/park_project_leak/` — the same tree with one extra line
  (`individual_id` on `public/PublicDino.yon`); **rejected** at compile time
  (not a sheaf on the quotient).

The project must build, the leak variant must be rejected. If a future change to
Yon ever let the leak compile, the suite goes red. The book and the compiler are
kept honest by the same gate.

:::note A Jurassic Project — for the business reader
**The academic fetish.** A *sheaf* is data that stays coherent across the way
you cover a space; a *quotient* is a space where you have deliberately forgotten
a distinction.

**The enterprise disaster.** In Java/Python the "legal can't see identity" rule
is a comment plus three code reviews. The leak that triggers a GDPR fine looks
exactly like correct code to the compiler.

**The dinosaur solution.** The `public/` folder *is* the world `Park / cohort`.
A file there can carry only cohort-invariant data; `individual_id` is not
determined by cohort, so it cannot be put on a public record at all, and a view
depending on the individual would not factor through the quotient. Identity
isn't hidden — in the public folder it cannot exist.

**The return on capital.** The most expensive class of data-leak becomes a
compile error: zero runtime cost, impossible to ship downstream, no audit
needed to prove it can't happen.
:::

## Where we are, where we go next

You have seen the shape of the whole book in one scene: a domain whose
*correctness is structural*, and a compiler that enforces the structure instead
of trusting a comment. We reached for three words without defining them —
**world**, **place**, **view** — and one idea, the **quotient**. Chapter 2
gives them their proper vocabulary; Chapter 8 returns to this exact park and
proves the sheaf condition in full.

**Checkpoint.** Before moving on, make sure you can say, in one sentence, why
the Java `id()` method is dangerous and why, in Yon, a public dinosaur simply
cannot carry an `individual_id`.
