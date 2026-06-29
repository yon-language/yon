---
title: "1.1 · The Unreadable Fragment"
sidebar_label: "1.1 · The Unreadable Fragment"
sidebar_position: 1
description: "Chapter 1.1, the substrate of Yon, read through Jurassic Park's unreadable opening data. DRAFT voice & format specimen."
---

:::caution DRAFT, voice & format specimen
First drafted chapter, kept here so the **voice and format** can be read live. The
`.yon` snippet is **gated ✓ on the Mac** (`yoner_emit_mlir` exit 0). The prose is a
specimen pending review. Source of truth: `manuscript/chapters/01-1-the-unreadable-fragment.md`.
:::

> *I tried to engineer a Jurassic Park that works. I hope I did a better job than Hammond.*

That sentence is the opposite of the one InGen never said. John Hammond was certain his
park was foolproof, and the certainty was the flaw. So this book does not promise you a
park that holds. It promises you an attempt, and it invites you, the way Ian Malcolm
would, to look for the crack. Over seven Iterations the same figure is drawn one step
deeper, the way Malcolm's fractal is redrawn at the head of each part of the novel,
until you can decide for yourself whether the structure held.

The novel opens before any dinosaur is named. A man is carried into a clinic on the
Costa Rican coast, torn in a way no backhoe makes, whispering a word the doctors don't
know. The damage is in front of them and they cannot read it. Keep that image. The first
Iteration is about data that is all there, and unreadable.

> **First Iteration.** *"At the earliest drawings of the fractal curve, few clues to the
> underlying mathematical structure will be seen."*
>
> Ian Malcolm

## The scene

A small girl is bitten on a beach, and the lizard that did it leaves a clean, three-toed
track no living lizard leaves. A field biologist names it wrong. A fragment of the animal
travels to a laboratory in New York, where a machine reads its proteins and flags an
enzyme that has no business in nature, a marker of genetic engineering, and the
technician, reasonably, assumes the sample is contaminated. Everything needed to
understand what is loose in the world is sitting in that lab. None of it is legible yet.
A child's crayon drawing comes closer to the truth than the instruments do: it says
*dinosaur*.

The data was never missing. It was unstructured. That is the whole of the first
Iteration, and it is where we begin with Yon too, at the substrate: the layer that is
present under every program and that you are not yet equipped to read.

## The idea

**On the philosophical plane.** Before a thing has meaning it has a body. A genome is a
sequence before it is an animal; a value is a pattern of bits before it is a number, a
dinosaur, a proof. Yon takes this literally: meaning is built *up* from a substrate that
knows nothing of it, and the substrate is honest precisely because it is dumb.

**In the language.** A Yon program is not, at bottom, a tower of abstractions that must
be believed. It is a directory of files that compiles to a binary and runs. The smallest
such program does nothing you can see. It binds a value, hands back a number, and exits.
The machine underneath it has no garbage collector deciding when to pause, no runtime
guessing at your intent: memory is mapped, used, and the process terminates. Determinism
by construction. We will earn the right to read this layer; for now we run it.

**On the silicon.** Underneath, the machine is deliberately small. Memory comes from a
single primitive, `mmap`, split between two allocators; there is no garbage collector,
and the program ends with an explicit `exit()`. The one piece worth naming now is the
**Carrier**. A Carrier is how Yon holds *what a value is*, kept apart from *how it gets
written down*. Because those two things are separate, turning a program into MLIR, or
into printed output, or into whatever target comes next, is just running a printer over
the carriers; the mathematics underneath does not change with the choice of printer. And
every term in the language is reduced by one normalizer, with no second, special-case
path hiding in a corner. A substrate this small is one you can actually trust.

## The code

A first program. It binds a value and returns it; its exit code is the only thing it
says to the world.

```yon
// Entry.yon, the root entrypoint of a one-file park
place Entry { }

fun main(): number {
  be substrate holds 0
  return substrate
}
```

A word on shape, because it trips people up. `fun main` sits at the top level, beside
`place Entry`, not inside its braces. A `fun` is always a plain top-level function. The
empty braces of `place Entry` are just the program's entry shell here; what lives
*inside* a place, its fields and its own operations, is the subject of a later Iteration.

Gated on the Mac, it compiles, and the computation at the heart of the `main` it emits is this:

```
%v0 = arith.constant 0.0 : f64
%v1 = arith.fptosi %v0 : f64 to i32
return %v1 : i32
```

There is nothing to see, and that is the point. `be substrate holds 0` binds a name to a
value. `holds` is initialization, the act of giving `substrate` its starting value.
Changing a value later is a separate act in Yon, one the park reaches in a later
Iteration; this program never uses it. `return substrate` hands the value to the process
boundary. A Unix exit status is a small integer, not a floating-point number, so the
`f64` zero is narrowed to the integer 0 with an `fptosi`, and that integer is what the
operating system reads back as the program's exit status. The actual silicon of *this*
program is almost nothing: an `f64` set to zero, narrowed to an integer, and a clean
exit. The substrate described a moment ago is what is *available* under every Yon program,
not what this one spends. Don't let the smallness fool you in either direction: the
machinery is real, and this program barely touches it. The structure is there. Few clues
to it, yet.

The larger claims, one `mmap` primitive, no collector, a single normalizer, a Carrier
that keeps meaning apart from target, are not things a program returning zero can prove.
You will watch them hold as the park grows, or watch the book mark plainly where they
don't yet. For now the only promise is the smallest one, and it is kept: the program ran,
and it said nothing it didn't mean.

In the next chapter the fractal is redrawn once, and the bits acquire an identity. Two
dinosaurs built from the same data turn out to be the same thing, and yet not the same
individual. Hammond never saw the difference.
