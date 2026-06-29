<!-- DRAFT — the Space cell / location: the second half of the fourth wall (content was
     the last chapter; this is location). Consolidates the verified probe (probe_no_alias,
     prints 3 3 5 3), the clipboard-and-pen visualization, and the manifesto. Code is the
     verified probe; no-aliasing is PROVEN in the lexer (no address-of), not asserted.
     Style: no em-dashes; reserved words stay keywords; reader-facing verdicts. -->

# One Fossil, Two Positions

## The scene

Hammond counts the dinosaurs and trusts the number. In the last chapter the computer
counted them too and came back with a smaller one: two raptors grown from the same genome
are, by content, a single thing, and a content-addressed herd holds them once. We left
that as a paradox. The same thing, and yet not the same individual.

Here is the other half, and it is the half Hammond needed. Two raptors with one genome are
still two animals. You can lose one to a fence and keep the other. You can feed one and
starve the other. You can find one dead in the morning and the other gone over the wall.
They share a fossil and they do not share a fate. What makes them two is not what they are
made of, which is identical. It is where they are.

## The idea

**On the philosophical plane.** Identity has two axes, and the disaster lives in the space
between them. There is what a thing is, its content, and there is where it is, its
position. Leibniz said that two things sharing every property are one thing. But "the
raptor in the eastern pen" is a fact about the pen, not about the raptor, and once you let
position count, two indistinguishable animals come apart. Content collapses the identical
into one. Location holds them apart as many. An individual is content placed somewhere.

**In the language.** Yon keeps the two axes separate by construction, and makes you say
which one you mean. Content lives in the content-addressed heap: the genome, hashed,
deduplicated, immutable, the single fossil of the last chapter. Location lives in a Space
cell: a small mutable cell that holds where something is now, and that you change with `=`.
`be x holds e` binds a value, which is content, and it never changes. `x = e` updates a
Space cell, which is a position, and it can. Two raptors are one genome and two location
cells.

**On the silicon.** The genome is one slot in the content-addressed heap, found by FNV and
confirmed by a byte-compare, written once for both animals. Each location is a cell in
`g_space_cells`, a plain mutable double, and the two raptors get two cells, two slots. The
store that moves one raptor writes to its cell and only its cell. It cannot reach the
other, because nothing connects them and, in Yon, nothing can: there is no address-of
operator with which to build the wire.

## The code

Read `x` as the pen a raptor stands in, and `y` as a number you copied off it onto a
clipboard. Move the raptor, and watch the clipboard.

```yon
// regression/book/jp/probe_no_alias  (native run prints: 3, 3, 5, 3)
fun main(): number visits Output {
  be x holds 3
  be y holds x
  be _1 holds Output.print(String.from_int(x))   // 3
  be _2 holds Output.print(String.from_int(y))   // 3
  x = 5                                           // the raptor moves
  be _3 holds Output.print(String.from_int(x))   // 5
  be _4 holds Output.print(String.from_int(y))   // 3, the clipboard did not follow
  return 0
}
```

`x` is a Space cell, a live position: `be x holds 3` opens it, `x = 5` stores into it. `y`
is not a cell. `be y holds x` reads `x` once and keeps the value: a snapshot, a copy of a
moment. When the raptor moves and the cell goes from 3 to 5, `y` stays 3, because `y` was
never wired to the cell. It held a number, not the pen. The last printed line, the second
`3`, is the whole point made small: the clipboard and the pen have come apart.

Two raptors are this, twice over. Same genome, the one fossil. Two positions, two cells.
Move one and the other does not move, because there is no wire between two cells and no way
to make one.

<!-- WEBSITE: the SpaceCellNoAlias component (clipboard & pen) replays this trace here. -->

## What holds

You can check the divergence yourself: build `regression/book/jp/probe_no_alias` with
`toolchain/yonc` and read its output, `3 3 5 3`. The last `3` is `y` refusing to follow
`x`. And the reason it can always be trusted is not in that run but in the language: there
is no address-of operator in Yon, so there is no way to bind `y` to `x`'s cell instead of
its value. In C the choice between a copy and an alias is yours and is invisible at the
place you use the name; in Yon the choice does not exist, because the alias is
unconstructable. The gap between the clipboard and the pen is Hammond's whole gap, and the
one thing Yon can promise is that you will never mistake one for the other. Trusting a
stale copy is still possible. It is just no longer a confusion about what you are holding.

> The content half of this wall was the last chapter; the location half is this one.
> Together they are why the park could not have miscounted itself in Yon the way it did in
> the novel: not because Yon keeps the count fresh, but because it will not let you blur
> what a thing is into where it is. The manifesto that follows, *Where the philosophy is
> paid for*, is the same story told from underneath: the immutable surface you have been
> reading is honoured by a runtime that mutates a cell in place, and that is allowed
> precisely because nothing can observe the cell.
