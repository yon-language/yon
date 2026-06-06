---
id: syntax-reference
title: Syntax Reference
sidebar_position: 2
description: The normative syntax of Yon 1.0, derived from the actual grammar.
---

# Yon, Syntax Reference

This is the **normative reference for Yon 1.0**. Every form below was derived
from a complete pass over the real grammar (`frontend/parser.mly` and
`frontend/lexer.mll`), not from memory, not from older documents.

Each construct carries a status:

- **✓**, verified end-to-end: a regression example or a compiled probe
  exercises it through `yonc` down to a running binary.
- **⚠ not implemented**, the grammar accepts it, but the 1.0 compiler does
  not implement it (it fails at emission, or the construct cannot actually be
  used). Listed for completeness; *not part of the 1.0 contract*.

## Lexical structure

| Form | Status | Meaning |
|---|---|---|
| `// ...`, `/* ... */` | ✓ | Line / block comments |
| `42`, `3.14` | ✓ | `number` literal (IEEE f64) |
| `"ciao"` | ✓ | String literal, a real value of type `text`/`String` (see *Strings*) |
| `true`, `false` | ✓ | Boolean literals |
| `present`, `absent`, `unknown` | ✓ | Heyting truth values (intuitionistic Ω) |
| `100ms`, `5s`, `2min`, `1h`, `3d`, `1y` | ✓ | Duration literals (no whitespace before the unit). **A duration is a `number` of milliseconds**: `2s + 500ms == 2500` |
| `mod::name` | ✓ | Qualified name (module namespace) |

Currency literals (`10.50 EUR`) are **not** in the 1.0 grammar; the `money`
*type* exists (see *Types*).

## Strings

Since the **string fusion**, `text` and `String` are the *same semantic
object*: sections of the builtin `String` place. At runtime a string is a
handle into the content-addressed heap; literals are interned, so the same
literal is the same value and `String.equal` compares content:

```yon
fun greet(who: String): String {
  return String.concat("ciao ", who)
}

fun main(): number {
  be msg holds greet("mondo")
  be _w holds File.write_text("/tmp/out.txt", msg)
  return String.length(msg)        // 10
}
```

Strings are **process-local**: they cannot cross a Space (package) boundary, 
only numbers travel on the wire.

## Bindings and mutation

| Form | Status | Meaning |
|---|---|---|
| `be x holds e` | ✓ | Immutable binding, the only declaration form, at top level and inside functions alike (there is no `let` keyword) |
| `x becomes e` | ✓ | Mutation. A becomes-target binding is **promoted to a Space cell** (the content-addressed mutation mechanism): its `be` allocates the cell, reads go through it, `becomes` updates it. Works on locals and parameters |
| `Space.make / set / get` | ✓ | The underlying mutable cells, also usable directly |
| `x.f becomes e` | ⚠ not implemented | Field mutation: place sections are immutable in 1.0; mutate through cells |

There is no reassignment `x = e`. `=` appears only in top-level categorical
definitions (`world W = A * B`, `place P = pullback(f, g)`) and in `show f = e`
inside views.

## Types

| Form | Status | Meaning |
|---|---|---|
| `number`, `text`, `boolean`, `proposition`, `money` | ✓ | Primitives. `boolean` ≡ `proposition` (Ω); `text` ≡ `String` |
| `T in A, B, C` | ✓ | Constrained primitive (e.g. `money in EUR, USD`) |
| `A \| B \| C(T)` | ✓ | Sum type; variants may carry arguments |
| `list of T`, `map of K to V` | ✓ | Collections |
| `stream of T buffer N drop oldest`/`drop newest` | ✓ | Stream with back-pressure modifiers |
| `T -> U` | ✓ | Function type, right-associative |
| `heyting<N>` | ✓ | Heyting integer: N trits with an Unknown mask |
| `Type`, `Type_0`, `Type_1`, … | ✓ | Universes (HoTT) |
| `Pi(x: A). B`, `Sigma(x: A). B` | ✓ | Dependent function / pair types |
| `Id(A, x, y)` | ✓ | Identity (path) type between terms `x`, `y` |
| `{ x : A where P }` | ✓ | **Comprehension**: the subobject of `A` carved out by the fibre `P` (a Σ whose first projection is monic when `P` is a mere proposition) |
| `move from W1 to W2` | ✓ | Handle types: arrows are first-class values that |
| `reduction of P` | ✓ | can be passed as parameters. Each keeps its |
| `morph from S1 to S2` | ✓ | categorical stratification (no nesting, only |
| `view of P` | ✓ | composition via `compose`) |

A function parameter may omit its annotation; the signature pre-pass infers it
from the call sites.

## Expressions

| Form | Status | Meaning |
|---|---|---|
| `f(a, b)`, `mod::f(a)` | ✓ | Calls. **Zero-argument builtins take a dummy `0`**: `Time.now_ms(0)` |
| `obj.field`, `x.f1.f2` | ✓ | Field access (chains left-associatively) |
| `e.method(args).map(f).fold(0, g)` | ✓ | Method chaining: `recv.m(args)` ≡ `m(recv, args)` |
| `a \|> f(args)` | ✓ | Pipe: passes `a` as the **first** argument of the call |
| `if c then a else b` | ✓ | Conditional expression (lowers to `scf.if`) |
| `fun(x: T, y) => e` | ✓ | Inline lambda (unannotated params are inferred) |
| `move(s: P) => new Q {...} from P to Q` | ✓ | Inline handle lambdas, one per arrow kind. They bind, compose |
| `reduction(acc, x) => e of P` | ✓ | (kind-checked: same kind, or post-compose of view/reduction with |
| `view(s: P) => e of P` | ✓ | a fun), and apply, a bound or composed handle is called like a |
| `functor(x) => e from W to V [law id]*` | ✓ | function, and `apply_move` accepts a locally bound move-lambda. |
| `morph(s) => e from S1 to S2` | ✓ | Functor laws are checkable |
| `compose h1 with h2` | ✓ | Handle composition, `(compose f with g)(x) = g(f(x))`. Kind discipline enforced: e.g. `reduction ∘ reduction` is rejected (the eliminator lands in `number`) |
| `f(args) in S` | ✓ | Call in a Space context (`apply_move ... in S`, morph dispatch) |
| `all P where cond` | ✓ | Quantification over the sections of a place |
| `solve P` | ✓ | Instantiate a law-verified place as a Magma handle |
| `new P { field value }` | ✓ | Section construction, **no `=`** between field and value |
| `new P in S { ... }` | ✓ | Construction inside Space `S` |
| `refl(t)`, `pair(a,b)`, `fst(p)`, `snd(p)` | ✓ | HoTT introduction forms |
| `ind_path(C, d, p)` | ⚠ not implemented | The J eliminator parses; its emission is not wired in 1.0 (the runnable fragment is `refl`/`pair`/`fst`/`snd`) |
| `pullback(f, g)` / `pullback(f, g, a, b)` | ✓ | Pullback scaffolding / runtime compatible pair with `f(a) == g(b)` checked |
| `heyting(v)`, `heyting(v, mask)` | ✓ | Heyting-integer constructor (mask marks Unknown trits) |

### Operators (by family)

| Operators | Status | Meaning |
|---|---|---|
| `+ - * / %`, unary `-` | ✓ | Arithmetic |
| `== != < > <= >=` | ✓ | Comparison |
| `and`/`&&`, `or`/`\|\|`, `not`/`!` | ✓ | Classical logic |
| `a => b` | ✓ | Classical implication, sugar for `(not a) or b` |
| `& \| ^ ~` | ✓ | **Bitwise on numbers** |
| `&&? \|\|? =>? !?` | ✓ | Heyting (scalar Ω): and, or, implication, negation |
| `&? \|? ^? ~?` | ✓ | Heyting **trit-wise** on `heyting` (Unknown-mask propagation) |
| `:` `.` `->` `\|>` | ✓ | Annotation, access, function type, pipe |

## Statements

| Form | Status | Meaning |
|---|---|---|
| `return e` | ✓ | Return from the function |
| `when c { } when c2 { } otherwise { }` | ✓ | Conditional chain. **A `return` inside a branch does not exit the function**, branches are for effects; select values with `if/then/else` |
| `e is pattern`, `e is not pattern` | ✓ | Pattern conditions (in `when`/`forces`): patterns are a variable, a literal, `present`, `absent`, `unknown`; chainable with `and`/`or` |
| `iter n do { }` | ✓ | Bounded loop (always terminates; `scf.for`) |
| `while c do { }` | ✓ | General loop (`scf.while`) |
| `scope [Name] { }` | ✓ | **Hermetic block** (see below) |
| `with R of P { }` | ✓ | Activate reduction `R` over `P` for the block |
| `produce { }` / `emit e` | ✓ | Producer block / emit into the active stream or handler |
| `forces stage cond { }` | ✓ | Kripke–Joyal forcing block at a stage |
| `for every x in e { }` (+ `when here`) | ✓ | Iteration over a List. **1.0 executes sequentially**; parallelism (and the `when here` space filter) are declared intent, not yet a runtime distinction |
| `in sequence over x in e { }` | ✓ | Sequential iteration over a List |
| `repeat at most N times { } [otherwise { }]` | ✓ | The body runs exactly N times, then `otherwise` (if present) runs. A success-based early exit is a post-1.0 protocol |
| `forever { }` | ✓ | Infinite loop (`while present`); typically paired with effects inside |

### Hermetic scope

A `scope` block is a **formally hermetic region**: at the IR level it becomes a
`topos.scope_with_yield` region with the MLIR trait `IsolatedFromAbove`. Every
outer binding the body uses enters as an **explicit capture**; an implicit
reference is a *compiler error*, verified on the real IR.

```yon
fun main(): number {
  be base holds 40
  scope Hermetic {
    be sealed holds base + 2    // `base` enters as an explicit capture
  }
  return base + 2               // 42
}
```

## Functions

```yon
fun f(x: number, y: number): number { return x + y }
fun g<A, B>(x: A): B { ... }                      // type parameters
fun h(x: number): number visits Output { ... }    // declared effect
internal fun secret(x: number): number { ... }    // not exported cross-Space
partial fun p(x: number): number { ... }          // partial (may not return)
```

All four modifiers are ✓ verified. **Effect discipline (`visits`)**: calling a
function that `visits E` requires the caller to cover `E`, by declaring
`visits E` itself or having a handler active; the effect propagates up to
`main`. I/O is an effect (`visits Output`).

## Worlds

| Form | Status | Meaning |
|---|---|---|
| `world W { Name is A, B, C  Color is by F }` | ✓ | A world; each member is `Name is descriptor` (an enumeration of inhabitants, a primitive type name, or `by F`) |
| `world W = A * B` | ✓ | Product of worlds |
| `world W = A + B` | ✓ | Coproduct |
| `world W = Base / Rel` | ✓ | Quotient world by an equivalence |
| `world W subset of V` | ✓ | Sub-world |

## Places, operations, laws

| Form | Status | Meaning |
|---|---|---|
| `place P [in W] [over X] [extends B] [on error E] { members }` | ✓ | An object. `over X` = slice (fibered over `X`); `extends B` = sub-object mono `P ↪ B`; `on error E` = error morphism `P → E` |
| `place P ... with effects { ... }` | ✓ | Enables operations (1-cells) among the members |
| `error E [in W] [extends B] { fields }` | ✓ | An error place (target of `on error`) |
| `field_name type` | ✓ | Field, **no colon**: `balance number` |
| `operation op(a: T): U` | ✓ | Operation (1-cell) |
| `functorial operation op(...)` | ✓ | Operation lifted along world morphisms (Yoneda lifting) |
| `operation op(...) uses algebra Additive` | ✓ | Bind to a catalog algebra; laws certified by the compiler |
| `law commutative` etc. | ✓ | Declared law, verified (MagmaSolve) |
| `cell c from e1 to e2` | ✓ | Higher cell between lower cells (CaTT witness) |
| `place P = pullback(f, g)` / `pushout(f, g)` | ✓ | Place as a limit / colimit |

Catalog algebras: `Additive`, `Multiplicative`, `TropicalMax`, `TropicalMin`,
`BooleanOr`, `BooleanAnd`, `Gcd`.

## Arrows

| Form | Status | Meaning |
|---|---|---|
| `move m from P to Q [requires CAP1, CAP2] { A maps to B by f ... }` | ✓ | Move between places; the body is a list of **mapping clauses**; `requires` lists capabilities |
| `move m unifies A, B { share f1, f2  conflict on f resolves to fn }` | ✓ | Merge move: shared fields plus per-field conflict resolution |
| `A maps to B by f` / `converts to` / `aggregates to` | ✓ | Mapping kinds; `by fun(x) => e` inline lambda allowed |
| `morph F from W to V { on object(...) { } on morphism op via op2 }` | ✓ | Functor by components; `on object: fun(...) => e` inline form allowed; `on`, `object`, `morphism` stay free as user identifiers |
| `functor F(x: T) from W to V [law identity] [law composition] { return e }` | ✓ | Functor given by a return expression with declared laws |
| `nat transform t from F to G { for each X by fnX }` | ✓ | Natural transformation: one component per object |
| `geomorph g from P to Q { pull(...) { } push(...) { } }` | ✓ | Geometric morphism, the adjoint pair f* ⊣ f∗: `pull` is the inverse image, `push` the direct image; clauses `adjunction`, `exact pull`, `exact push` declare its properties |
| `view V of P { show f  show f = e  show f as "label" }` | ✓ | Derived projection of a place |
| `topology j of P { ... }` | ✓ | **Lawvere–Tierney** topology: a body defining `j : Ω → Ω` |
| `reduction [forward\|backward\|bi] [lawful] [invertible] R[<T>] of P [with multishot] [fold "sum_f64"] { on op(params) { } be x holds e }` | ✓ | Reduction with direction and laws; clauses are contextual `on` handlers and `be` bindings |

## Topos declarations

```yon
topos Account [in W] [at SPACE] where {
  objects { ...place declarations... }
  terminal Unit                                  // optional
  morphisms { ...operations... }                 // optional
  prop is_overdrawn(s: State): proposition = s.balance < 0
}
```

Status: ✓ (regression examples). A `prop` is a subobject classifier, a map
into Ω; the abstract form (no `= body`) declares the signature only. `at SPACE`
binds the topos to a residence heap; without it the topos is purely formal.

## Spaces and packages

| Form | Status | Meaning |
|---|---|---|
| `space S [in W] [with fold "sum_f64"]` | ✓ | Declare a Space; the optional fold names its semilattice join |
| `init X as Space` | ✓ | Initialize a Space |
| `import "file.yon"` | ✓ | File import |
| `import m::n [as alias]` | ✓ | Symbol import from a module |
| `import m::n from Space` | ✓ | **Cross-package import**: `n` becomes a remote arrow into `Space` |

Cross-package calls are RPC over a named channel (`/yon_stream_<Space>`):
only **numbers** cross the boundary, at most **4 arguments**; `internal`
functions are not exported; the server binary is `./<Space>_srv` by convention
(override with `YON_SRV_DIR`), spawned on first contact, shut down in cascade,
and **transparently recovered** after a crash (virgin channel, epoch advanced,
one retry).

Hermeticity model: **cross-package = process isolation** (kernel MMU, values
only on the wire); **intra-package = typed/logical** (visibility, `internal`,
effects, move/morphism gating) with opt-in physical heap separation
(`YON_BACKEND=separate`).

## Standard library (module index)

| Module | Operations |
|---|---|
| `IO` | `print_num` |
| `String` | `length, concat, equal, char_at, substring, find_char, from_char, from_int, parse_number, print` |
| `File` | `read_text, exists, write_text, append_text` |
| `Env` | `get, has` |
| `Args` | `count, get` |
| `Time` | `now_ms, now_ns` |
| `Random` | `seed, int, range` |
| `Math` | `sqrt, abs, floor, ceil, round, min, max, pow, log, log2, log10, exp, sin, cos, sinh, cosh, tanh, atan2, modulo, gcd, lcm, pi, e` |
| `Bits` | `and, or, xor, not, shl, shr, popcount, fold, *_64` |
| `Crypto` | `fnv1a, hash_int` |
| `List` / `Map` / `Set` / `HashSet` / `XSet` | Immutable collections over the content-addressed heap |
| `Merkle` | Content-addressed Merkle trees |
| `VoyagerList` | Golay-sealed list (error-correcting) |
| `Magma` | `gen, closure_size, reachable, normal_form, subsetsum[_mask], knapsack[_mask]`, with `solve P` |
| `Stream` | `from_list, map, filter, fold, iterate, take` |
| `Space` | `make, set, get`, mutable cells (the 1.0 mutation mechanism) |

Failure convention: string-producing operations return the `0.0` handle on
failure (missing file, unset variable, out-of-range index).

## Conventions

- Zero-argument builtins are called with a dummy `0`: `Args.count(0)`.
- `new P { field value }` and place fields `name type`, no `=`, no `:`.
- A program's exit code is `main`'s return value, truncated mod 256.
- `return` inside a `when` branch does not exit the function; use
  `if/then/else` to select values.
