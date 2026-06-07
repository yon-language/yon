---
title: "Keywords, one by one"
---

import CodeWindow from '@site/src/components/CodeWindow';

# Keywords, one by one

Every reserved word of Yon, explained next to a compiling example.
Each snippet on this page is a file from `examples/` in the
repository: it builds and runs in the regression suite, with the exit
code shown. (For the census view with status per keyword, see
`KEYWORDS.md` in the repository root.)

## Paths and the universe

#### `refl`

The reflexivity path: the proof that a value equals itself. In Yon a
path value lowers to its *erased witness*, operationally the endpoint
value, so `refl(7)` can be bound and passed like any value. What it
can never do is decide path equality at runtime: that judgement
belongs to the reducer alone.

#### `ind_path`

The J eliminator, the one tool of path induction: to prove something
about every path, prove it on `refl`. `ind_path(C, d, p)` computes
`d(basepoint)` when the path is `refl` in evidence at the call site.
A J stuck on a non-trivial path is rejected at compile time, loudly:
the runtime never identifies `loop` with `refl`, so the circle stays
a circle.

#### `Type`

The universe of types (`Type_1`, `Type_2`, ... for the levels). A
universe-typed parameter compiles to an inert runtime token: types are
compile-time citizens, and the runtime never inspects one.

<CodeWindow file="kw_paths.yon"
            run="yonc kw_paths.yon -o paths && ./paths; echo $?"
            out={["42"]}>
{`fun diag(a: number): number { return a * 6 }
fun universe_taker(t: Type): number { return 7 }
fun main(): number {
  be r holds refl(7)                          // a path value, let-bound
  be moved holds ind_path(0, diag, refl(7))   // J computes diag(7) = 42
  return moved
}`}
</CodeWindow>

## Pattern conditions

#### `not`

Pattern negation: `e is not pattern` is the Heyting negation of the
positive test. At `unknown` it stays unknown, and an unknown condition
decides to false: nothing provable, nothing run.

#### `absent`

The third value of the tri-value logic, next to `present` and
`unknown`. A subtlety worth meeting early: a *false* proposition is
still `present`, because it is a known falsehood; only `unknown` is
not present.

<CodeWindow file="kw_patterns.yon"
            run="yonc kw_patterns.yon -o patterns && ./patterns; echo $?"
            out={["p is not absent", "u is unknown", "6"]}>
{`fun chain_one(a: number, b: number): number visits Output {
  be p holds (a < b)
  when p is not absent {
    be _ holds String.print("p is not absent")
  }
  return 1
}
fun chain_two(d: number): number visits Output {
  be u holds unknown
  when u is unknown {
    be _ holds String.print("u is unknown")
  }
  return d
}
fun chain_three(a: number, b: number): number visits Output {
  be p holds (a < b)
  when p is absent {
    be _ holds String.print("NEVER printed: p is a known truth")
  }
  return 3
}
fun main(): number visits Output {
  be x holds chain_one(3, 5)
  be y holds chain_two(2)
  be z holds chain_three(3, 5)
  return x + y + z
}`}
</CodeWindow>
