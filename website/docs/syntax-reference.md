---
id: syntax-reference
title: Syntax Reference
sidebar_position: 2
description: The normative syntax of Yon 1.2 (in development), derived from the actual grammar.
---

# Yon, Syntax Reference

This is the **normative reference for Yon 1.2** (in development; `yon version` prints `1.2-dev`). Every form below was
re-verified against the real grammar (`frontend/parser.mly` and
`frontend/lexer.mll`) and the compiling examples under
`regression/book/jp/*/Entry.yon`, not from memory, not from older documents.
Where a construct could not be confirmed in the live grammar it has been
removed or flagged, rather than asserted.

This table answers *is this form valid?* For *what does this keyword
mean?*, with a compiling example next to each explanation, see
[Keywords, one by one](/book/keywords). An alphabetical
[index of every keyword](#keyword-index) closes this page.

Each construct carries a status:

- **✓**, verified end-to-end: a regression example or a compiled probe
  exercises it through `yonc` down to a running binary.
- **✗ rejected**, the grammar accepts it but the type checker refuses it
  cleanly, by design, with a specific error. A deviation, pinned by a negative
  fixture in `regression/canonical_forms/`.

A form the grammar accepts but the compiler does not implement is not listed
here: it is not part of the 1.2 contract.

## Lexical structure

| Form | Status | Meaning |
|---|---|---|
| `// ...`, `/* ... */` | ✓ | Line / block comments |
| `42`, `3.14` | ✓ | `Number` literal (IEEE f64) |
| `"ciao"` | ✓ | String literal, a real value of type `Text`/`String` (see *Strings*) |
| [`true`](/book/keywords#true), [`false`](/book/keywords#false) | ✓ | Boolean literals |
| [`present`](/book/keywords#present), [`absent`](/book/keywords#absent), [`unknown`](/book/keywords#unknown) | ✓ | Heyting truth values (intuitionistic Ω) |
| `mod::name` | ✓ | Qualified name (module namespace) |

Duration literals (`100ms`, `5s`, `2min`) were **removed**: `2s` now
lexes as `NUM_LIT 2` followed by the identifier `s`. Currency literals
(`10.50 EUR`) are likewise **not** in the grammar; the `money` *type* exists
(see *Types*).

## Strings

Since the **string fusion**, `Text` and `String` are the *same semantic
object*: sections of the builtin `String` place. At runtime a string is a
handle into the content-addressed heap; literals are interned, so the same
literal is the same value and `String.equal` compares content:

```yon
fun greet(who: String): String {
  return String.concat("ciao ", who)
}

fun main(): Number {
  msg := greet("mondo")
  _w := File.write_text("/tmp/out.txt", msg)
  return String.length(msg)        // 10
}
```

A cross-Space **call** carries numbers only (at most four arguments). Strings
and places cross a Space boundary by copy, on a `Wire<T>` subscription
(chapter 17). A `String` parameter in a cross-Space signature is not yet
refused: it compiles, and the call returns a wrong value (0). This is a defect.

## Bindings and mutation

| Form | Status | Meaning |
|---|---|---|
| `x := e` | ✓ | Definition of a value, with no keyword, at top level and inside functions alike (no `let`, no `be`). Defines once per scope: a second `x := ...` of a name already bound in the same scope is a compile error; nested-scope shadowing is allowed, `_`-prefixed names are exempt |
| `mut c := e` | ✓ | Declares a **cell** (a Space cell, the one mutable thing): mutability shows where it is born |
| `c <- e` | ✓ | Writes the cell `c`. A write to a name not declared `mut` is refused (E2008), with the message proposing `mut`. Snapshot semantics, no aliasing (`y := c` does not alias `c`'s cell). `x = e` does not exist |
| `Space.make / set / get` | ✓ | The underlying mutable cells, also usable directly |
| `x.f <- e` | ✗ rejected | Field mutation: place sections are immutable; the type checker rejects it ("place sections are immutable"). Mutate through cells |

Yon has no assignment operator `=`: a value is defined with `:=`, and a cell
is written with `<-`. The single `=` token appears in only three places,
none of them a write: `prop name(...) = e` inside a topos, `show f = e` inside
a view, and the faces `i = I0 => …` / `i = I1 => …` of a composition.
Equality between values is `==`. There is no `becomes` keyword.

## Types

| Form | Status | Meaning |
|---|---|---|
| `Number`, `Text`, `Boolean`, `Unit` | ✓ | Primitives, the prelude places. `Text` ≡ `String`. The lowercase spellings `number`, `text`, `boolean`, `unit` are the kernel codes and are rejected at the surface (E1001) |
| `Int64` | ✓ | The exact 64-bit integer, a prelude place carried as `i64`: no rounding. A literal is an `Int64` where the context asks for one |
| `T in A, B, C` | ✓ | Constrained primitive (e.g. `money in EUR, USD`) |
| `place P { this > A :U B T }` | ✓ | Coproduct (sum): the arms are places, an arm may carry arguments; see [`this`](/book/keywords#this) |
| `List<T>`, `HashMap<K, V>`, `HashSet<T>` | ✓ | Collections |
| `Wire<T>` | ✓ | Channel type: what `produce`, `spawn` and a subscription give. (The `buffer N` / `drop oldest` / `drop newest` modifiers were parsed but never consumed and were removed) |
| `T -> U` | ✓ | Function type, right-associative |
| `heyting<N>` | ✓ | Heyting integer: N trits with an Unknown mask |
| [`Type`](/book/keywords#type), `Type_0`, `Type_1`, … | ✓ | Universes (HoTT) |
| `Pi(x: A). B`, `Sigma(x: A). B` | ✓ | Dependent function / pair types |
| `x = y` | ✓ | Identity (path) type between terms `x`, `y`; the carrier is read off the endpoints |
| `{ x : A where P }` | ✓ | **Comprehension**: the subobject of `A` carved out by the fibre `P` (a Σ whose first projection is monic when `P` is a mere proposition) |
| `move from W1 to W2` | ✓ | Handle type of a move from `W1` to `W2` |
| `reduction of P` | ✓ | Handle type of a reduction over `P` |
| `morph from S1 to S2` | ✓ | Handle type of a morph from `S1` to `S2` |
| `view of P` | ✓ | Handle type of a view of `P` |

The four **handle types** make arrows first-class values: a handle can be
passed as a parameter. Each keeps its categorical stratification: handles do
not nest, they only compose, through [`compose`](/book/keywords#compose).

A function parameter may omit its annotation; the signature pre-pass infers it
from the call sites.

## Expressions

| Form | Status | Meaning |
|---|---|---|
| `f(a, b)`, `mod::f(a)` | ✓ | Calls. **Nullary builtins are called with empty parens `()`**: `HashSet.empty`, `XSet.empty()`, `Vec.empty()`, `XRelMap.empty`. A few builtins instead take an explicit unit argument `(0)` (signature `[unit]`): `List.empty(0)`, `Time.now_ms(0)`, `Args.count(0)` |
| `obj.field`, `x.f1.f2` | ✓ | Field access (chains left-associatively) |
| `e.method(args).map(f).fold(0, g)` | ✓ | Method chaining: `recv.m(args)` ≡ `m(recv, args)` |
| `fun answer: Number { return 42 }`, used as `answer` | ✓ | **A point** `1 → X`: a pure nullary is declared and named without `()`; a value fixed for the life of the Space is pure |
| `fun tick(): Int64 { .. }`, used as `tick()` | ✓ | **A nullary that acts**: an effect, a wait, shared memory, a cell that leaves, or a call of one that acts; `()` is the empty product |
| `operation zero: Additive as "0"`, used as `zero` | ✓ | A constant of an algebra |
| `place P<A, f : A -> A> { … }`, `(A, B) -> C` | ✓ | A parameter that stands for a term, read in the laws; its argument is the name of a fun, and that name is its identity |
| `a ↦ f`, `(a, b) ↦ f` | ✓ | Application: a tuple spreads into the arguments. The call `f(a, b)` stays |
| `if c then a else b` | ✓ | Conditional expression |
| `fun(x: T, y) => e` | ✓ | Inline lambda (unannotated params are inferred) |
| `move(s: P) => .-> Q {...} from P to Q` | ✓ | Inline move lambda (see the note below the table) |
| `reduction(acc, x) => e of P` | ✓ | Inline reduction lambda |
| `view(s: P) => e of P` | ✓ | Inline view lambda |
| `functor(x) => e from W to V [law id]*` | ✓ | Inline functor lambda; its declared laws are checked |
| `morph(s) => e from S1 to S2` | ✓ | Inline morph lambda |
| `compose h1 with h2` | ✓ | Handle composition, `(compose f with g)(x) = g(f(x))`. Kind discipline enforced: e.g. `reduction ∘ reduction` is rejected (the eliminator lands in `Number`) |
| *capture by value* | ✓ | A `move`/`functor`/`view`/`reduction`/`morph` lambda, like a `fun` lambda, may mention enclosing locals; they are captured by value. A **cell** (a local declared `mut`, or made with `Space.make`) cannot leave its call: returning, storing or sending an arrow that mentions one is a compile-time error (chapter 7) |
| `f(args) in S` | ✓ | Call in a Space context (`apply_move ... in S`, morph dispatch) |
| `.-> P { field value }` | ✓ | Section construction through the mediatrice, **no `=`** between field and value. (`new` and `verify` are retired: the constructor is the mediating arrow, and a law-verified place is instantiated like any other) |
| [`clear(t)`](/book/keywords#clear), `pair(a,b)`, `fst(p)`, `snd(p)` | ✓ | HoTT introduction forms. `clear` is the reflexivity proof: the path that needs no argument, because the two ends are definitionally the same |
| [`ind_path(C, d, p)`](/book/keywords#ind_path) | ✓ | The J eliminator: computes `d(basepoint)` when `p` is [`clear`](/book/keywords#clear) in evidence at the call site; a J stuck on a non-reflexive path is rejected at compile time (the runtime never decides path equality) |
| [`walk i => e`](/book/keywords#walk) | ✓ | Path abstraction over a dimension `i`; the face system for the compositions is written `i = I0 => walk j => e` / `i = I1 => walk j => e` |
| [`hit`](/book/keywords#hit), [`hit_elim`](/book/keywords#hit_elim) | ✗ | Forms of the **kernel**, refused on the surface: a nullary arm is its name, an injection `x ↪ Arm`, the eliminator `match` |
| [`comp(line)[faces]`](/book/keywords#comp) / [`hcomp T[faces]`](/book/keywords#hcomp) | ✓ | Kan composition along a line / homogeneous composition; reduced by the kernel (`regression/yon_tests/prove`) |
| [`quote(c, a)`](/book/keywords#quote) / [`el_match(target, ret, body)`](/book/keywords#el_match) | ✓ | Universe-code introduction / elimination for `El(c)`; lowers to the inhabitant / the body application. The deeper Tarski reflection is still ahead |
| `heyting(v)`, `heyting(v, mask)` | ✓ | Heyting-integer constructor (mask marks Unknown trits) |

The **inline handle lambdas** are one per arrow kind. They can be bound to a
name, composed, and applied: a bound or composed handle is called like a
function, and `apply_move` accepts a locally bound move lambda. Composition is
kind-checked: both sides of the same kind, or a view or reduction
post-composed with a `fun`.

### Operators (by family)

| Operators | Status | Meaning |
|---|---|---|
| `+ - * / %`, unary `-` | ✓ | Arithmetic |
| `== != < > <= >=` | ✓ | Comparison |
| [`and`](/book/keywords#and)/`&&`, [`or`](/book/keywords#or)/`\|\|`, [`not`](/book/keywords#not)/`!` | ✓ | Classical logic |
| `a => b` | ✓ | Classical implication, sugar for `(not a) or b` |
| `& \| ^ ~` | ✓ | **Bitwise on numbers** |
| `&&? \|\|? =>? !?` | ✓ | Heyting (scalar Ω): and, or, implication, negation |
| `&? \|? ^? ~?` | ✓ | Heyting **trit-wise** on [`heyting`](/book/keywords#heyting) (Unknown-mask propagation) |
| `:` `.` `->` `↦` | ✓ | Annotation, access, function type, pipe |

Precedence, loosest first. Each Heyting operator shares the level of its
classical twin:

| Level | Operators | Associativity |
|---|---|---|
| 1 | `↔` | right |
| 2 | `=>` `=>?` `→` | right |
| 3 | `or` `\|\|` `\|\|?` `∨` | left |
| 4 | `and` `&&` `&&?` `∧` | left |
| 5 | `==` `!=` `≠` `<` `>` `<=` `>=` | left |
| 6 | `@` | left |
| 7 | `↦` | left |
| 8 | `\|` | left |
| 9 | `\|?` | left |
| 10 | `^` `^?` | left |
| 11 | `&` `&?` | left |
| 12 | `+` `-` | left |
| 13 | `*` `/` `%` | left |
| 14 | unary `-` | |
| 15 | `not` `!` `!?` | |
| 16 | `~` `~?` | |

So `a &&? b == c` groups as `a &&? (b == c)`, `x & y + 1` as `x & (y + 1)`,
`x + 1 ↦ f` as `(x + 1) ↦ f`, and `true ↪ merid @ i` as `(true ↪ merid) @ i`.

**The four readings of `=>`.** The arrow `=>` is read by what stands before it,
never by its operands, so the reading is never ambiguous:

- between two expressions, `a => b` is classical implication;
- after a parameter list, `fun(x) => e` (and `move(…) =>`, `view(…) =>`, …)
  starts a lambda body;
- after a dimension, `walk i => e` starts a path abstraction;
- after a pattern, `Ctor => e` in a `match`, or a face `i = I0 => …`, starts a
  branch.

When an implication is the body of a lambda or a branch, writing it as
`(a => b)` makes it easier to read.

## Statements

| Form | Status | Meaning |
|---|---|---|
| `return e` | ✓ | Return from the function |
| `when c { } when c2 { } otherwise { }` | ✓ | Conditional chain. Branches are for effects; a [`return`](/book/keywords#return) stands only at the end of the body, in each branch of a final `when … otherwise` (elsewhere: E2002); select values with `if/then/else` |
| `e is pattern`, [`e is not pattern`](/book/keywords#not) | ✓ | Pattern conditions (in [`when`](/book/keywords#when)/[`forces`](/book/keywords#forces)): patterns are a variable, a literal, `present`, `absent`, `unknown`; chainable with `and`/`or` |
| `iter n do { }` | ✓ | Bounded loop (always terminates) |
| `while c do { }` | ✓ | General loop |
| `scope [Name] { }` | ✓ | **Hermetic block** (see below) |
| `produce { }` / `emit e` | ✓ | Producer block / emit into the active stream or handler |
| `spawn { }` / `spawn in N parallel { }` / `promote e` | ✓ | Fork one or N isolated process replicas; each `promote e` contributes to the block's collection stream, drained by the parent with `.fold` / `.for_every`. `spawn_index` (0..N-1) is in scope in the body. Scaling measured in Appendix D |
| `forces stage cond { }` | ✓ | Kripke–Joyal forcing block at a stage |
| `for every x in e { }` (+ `when here`) | ✓ | Iteration over a List. **Execution is sequential**; parallelism (and the `when here` space filter) are declared intent, not yet a runtime distinction |
| `in sequence over x in e { }` | ✓ | Sequential iteration over a List |
| `repeat at most N times { } [otherwise { }]` | ✓ | The body runs exactly N times, then [`otherwise`](/book/keywords#otherwise) (if present) runs. A success-based early exit is a later protocol |
| `forever { }` | ✓ | Infinite loop (`while present`); typically paired with effects inside |

### Hermetic scope

A `scope` block is a **formally hermetic region**. Every outer binding the
body uses enters as an **explicit capture**; an implicit reference is a
*compiler error*, verified on the real IR.

A `scope` is a statement, not an expression: it gives no value of its own,
and the names it defines stay inside. A result leaves the scope through a cell
declared outside it, which the body writes with `<-`:

```yon
fun main(): Number {
  base := 40
  mut result := 0
  scope Hermetic {
    sealed := base + 2    // `base` enters as an explicit capture
    result <- sealed      // so does the cell `result`
  }
  return result           // 42
}
```

`sealed` is not visible after the block; `result` carries the value out.

<details>
<summary>For implementers: the lowering</summary>

The block becomes a `topos.scope_with_yield` region with the MLIR trait
`IsolatedFromAbove`; the captures (here `base` and the handle of `result`) are
its block arguments, and the region yields `present`. It is inlined at zero
runtime cost. `if/then/else` lowers to `scf.if`, `iter` to `scf.for`, and
`while` to `scf.while`.

</details>

## Functions

```yon
fun f(x: Number, y: Number): Number { return x + y }
fun g<A, B>(x: A): B { ... }                      // type parameters
fun h(x: Number): Number visits Output { ... }    // declared effect
internal fun secret(x: Number): Number { ... }    // only its house calls it; not exported cross-Space
fun p(x: Number) on error E: Number { ... }       // partial: it declares how it fails
```

The four modifiers above, type parameters, `visits`, `internal` and
`on error`, are ✓ verified. **Effect discipline (`visits`)**: calling a
function that `visits E` requires the caller to cover `E`, by declaring
`visits E` itself or having a handler active; the effect propagates up to
`main`. I/O is an effect (`visits Output`).

## Worlds

A world has **no surface syntax**. `world` is not a lexer keyword, so any
`world W { ... }`, `world W = A * B`, `world W = A + B`, `world W = Base / Rel`,
or `world W subset of V` is a parse error.

A world is declared **only in `yon.toml`**, never in a `.yon` file:

```toml
[world.Park]
objects = ["Dinosaur", "Herd"]
spaces  = ["Enclosure"]
```

A `place` then takes its world by inference from the project's toml, not from an
`in W` clause in the source.

## Places, operations, laws

| Form | Status | Meaning |
|---|---|---|
| `place P [over X] [on error E] { members }` | ✓ | An object (its world is inferred from the toml; there is no `in W` clause). `over X` = slice (fibered over `X`); `on error E` = error morphism `P → E`. The sub-object mono is a **body clause**: `this < B` |
| `error E { fields }` | ✓ | An error place (target of `on error`); world inferred from the toml, no `in W` clause. The mono into a parent error is the body clause `this < B` |
| `field_name type` | ✓ | Field, **no colon**: `balance Number` |
| `operation op(a: T): U` | ✓ | Operation (1-cell), written directly among the place's members |
| `operation op(...) uses algebra Additive` | ✓ | Bind to a catalog algebra; laws certified by the compiler |
| `law commutative` etc. | ✓ | Declared law, verified (AlgebraVerifier) |
| `place A is algebra { ... }` | ✓ | **An algebra**: a theory, its operations and its laws. Inside it the name `A` stands for the carrier of any model. It lowers to nothing that runs: the models give the operations |
| `operation add(a: A, b: A): A as "+"` | ✓ | An operation of an algebra and the operator that writes it; a nullary operation (`operation zero: A`) is a neutral element |
| `law associative ∀a : A ∀b : A ∀c : A, (a + b) + c = a + (b + c)` | ✓ | A law stated over the carrier: each quantifier carries its type, here the carrier; the comma closes the quantifiers, and the statement reaches the end of the line, with parentheses only to group |
| `place Cerchio { this > punto  law giro punto = punto }` | ✓ | **A cell**: a law in the body of a place with `this >` is constitutive. The arms are the 0-cells, each law a cell, of the order its ends say; source and target have one type. A cell is an arrow with a name in the house: `x ↦ meridiano` is a path, `x ↦ meridiano @ i` a point on it |
| `match s { punto => 42, giro => walk i => 42 }` | ✓ | The eliminator wants a branch for each cell: a path between what it gives at the two ends, decided by the kernel's conversion. `meridiano as a => walk i => ..`, `quot as (a, b, r) => ..` bind the quantifiers and the premise |
| `law nothing zero + zero = zero` | ✓ | A law with no quantifier: the statement follows its name, to the end of the line |
| `law retract ∀x : V, value_of(word_of(x)) = x is given` | ✓ | **An axiom**: a law of a place that is not an algebra, about faces the certification cannot read (given ones); it is declared, never certified, and its variables range over every type. A law of an algebra is certified on each model and cannot be given |
| `carried by i64` (in an algebra) | ✓ | **A carrier model**: the carrier is a model of the algebra, with the machine's operation for each symbol (`as "+"` the machine's sum, `as "0"` its zero). Its laws are certified like those of any model; `carried by C is given` declares it an axiom, admitted only where the certification does not decide (E2102) |
| `fun double(a: A): A { return a + a }` (in an algebra) | ✓ | **A derived operation**: a composite of the algebra's operations over its name as the carrier. Each model that does not give a fun of that name receives its instance, the composite read with the model for the carrier: `P.double`. A model that gives the fun keeps its own. The algebra itself has no fun to run |
| `place P uses algebra A, B { ... }` | ✓ | **A model**: `P` gives each operation of `A` and `B` as its own fun of the same name and type (the algebra's name read as `P`); the operators of the algebras then write those funs on values of `P`, and every law is certified on `P`. An operation `P` does not give is taken from the carrier model of `A` for the carrier of `P`, when `A` declares one; a fun `P` gives itself is its own, and the laws are certified on it. An algebra not listed gives `P` nothing, whatever its carrier models |
| `cell c from e1 to e2` | ✓ | Higher cell between lower cells (CaTT witness) |
| `place P carried by <carrier> { ... }` | ✓ | **Declared representation**: `P` is carried at runtime as `<carrier>`, and the representation is open: the form of the prelude's primitives (`place Int64 carried by i64`) |
| `internal place P carried by <carrier> { ... }` | ✓ | The same representation, **internal to the house**: inside it `P` is `<carrier>`; outside it `P` is abstract, no literal is one of its points, no arithmetic of the carrier applies, and its values come only from its own functions. The place stays usable everywhere: `internal` before `place` hides how it is carried, not the place, unlike `internal fun`, which hides the fun from every caller outside its house. Example: `internal place LatticePoint carried by i64` |
| `internal place P<V> carried by <carrier> { ... }` | ✓ | A generic internal place: inside the house every application `P<...>` is the carrier; outside, `P<Number>` and `P<Boolean>` are two types. A parameter no field carries says what a value is about: `FnvHeap<V>` is the handle of a V in the heap |

The old forms `place P is <carrier>` and `place P is internal <carrier>` are
refused, with a message that names the form above.

The carrier after `carried by` names how the bits are laid out, not a type: `f64`,
`f32`, `i64`, `i32`, `i16`, `i8`, `i1`. These lowercase names are valid only
in this clause; in a type position they are refused (E1001), like `number`.

The algebras of the prelude (`prelude/alg/`): `Additive` (`+`, `zero`, carried by i64),
`Multiplicative` (`*`, `one`, carried by i64), `TropicalMax`, `TropicalMin`, `BooleanOr`,
`BooleanAnd`, `Gcd`. An algebra named but not declared `is algebra` is an
error.

**The statement of a law** is written with the symbols of mathematical logic:
`∀x : T` and `∃x : T` (only at the head of a law), `=` and `≠` (equality, the
comparison level), `∧` `∨` `→` `¬` (the Heyting connectives `&&?` `||?`
`=>?` `!?`), and `↔`, which is `(p → q) ∧ (q → p)`. Inside the statement a
single `=` is equality. **Certification** on each model, with three verdicts:
on a place of nullary arms, every assignment of arms is evaluated; on i64
(the ring Z/2^64, whose sum and product wrap) z3 decides the statement over
64-bit bitvectors, on f64 over IEEE doubles (where the sum is not
associative); a law false on the model is refused (E2101, with a
counterexample), one that is not decided is not certified (E2102), never
accepted in silence.

## Arrows

| Form | Status | Meaning |
|---|---|---|
| `move m from P to Q [requires CAP1, CAP2] { A maps to B by f ... }` | ✓ | Move between places; the body is a list of **mapping clauses**; [`requires`](/book/keywords#requires) lists capabilities |
| `move m unifies A, B { share f1, f2  conflict on f resolves to fn }` | ✓ | Merge move: shared fields plus per-field conflict resolution; applied with `Move.merge(m, s1, s2)`, result in the first source place |
| `A maps to B by f` / `converts to` / `aggregates to` | ✓ | Mapping kinds; `by fun(x) => e` inline lambda allowed |
| `morph F from W to V { on object(...) { } on morphism op via op2 }` | ✓ | Functor by components; `on object: fun(...) => e` inline form allowed; `on`, `object`, `morphism` stay free as user identifiers |
| `functor F(x: T) from W to V [law identity] [law composition] { return e }` | ✓ | Functor given by a return expression with declared laws |
| `nat transform t from F to G { for each X by fnX }` | ✓ | Natural transformation: one component per object |
| `geomorph g from P to Q { pull(...) { } push(...) { } }` | ✓ | Geometric morphism, the adjoint pair f* ⊣ f∗: [`pull`](/book/keywords#pull) is the inverse image, [`push`](/book/keywords#push) the direct image; the clause `exact push` declares that f∗ preserves finite limits. (`adjunction` and `exact pull` are retired: they declared what holds by definition) |
| `view V of P { show f  show f = e  show f as "label" }` | ✓ | Derived projection of a place, lowered to a record place plus a constructor: `V(x)` builds the projection, fields read normally |
| `reduction R[<T>] of P [with multishot] [fold "sum_f64"] { on op(params) { } x := e }` | ✓ | A reduction; clauses are contextual `on` handlers and `x := e` definitions. (The `forward`/`backward`/`bi` directions and the `lawful`/`invertible` modifiers are retired: they were obligations nobody verified) |

## Topos declarations

```yon
topos where {
  morphism plus(a: Int64, b: Int64): Int64       // the site's generators
  prop is_overdrawn(s: State) = s.balance < 0
  prop some_other(x: Coin) = ∃y : Coin (x ≠ y)
}
```

Status: ✓ (regression examples). Under *topos-per-space* there is no `in W` or
`at SPACE` annotation and no inline `objects { }` block: the world, the
residence space, and the objects are all **inferred from the filesystem**. The
name is not written either: it comes from the file, so it lives in one place
and cannot diverge (the named form `topos Name where` is also accepted). A `prop` is a subobject classifier, a map into Ω, and it carries no
return type, since a `prop` always lands in Ω; the abstract form (no
`= body`) declares the signature only.

A quantifier of a prop carries its type, `∀x : T`, followed by
the statement in parentheses, written with the symbols of a law. The type is
a place, named. A prop is a proposition the program computes, so a
quantifier has a value only over a place of nullary arms: there `∀` is the
meet of the statement at each arm, and `∃` the join, exactly. Over any other
type the prop is refused at compile time (E2001), with the reason. In a law,
the quantifier carries no type: the variable ranges over the carrier.

## Spaces and packages

A **Space has no surface declaration**. There is no `space S ...` declaration
form (the `space` keyword's `SPACE` token appears only inside the expression
`wire to space S`), and `init` is not a keyword (`init X as Space` is a parse
error). A Space is a **filesystem directory plus its `yon.toml`**, discovered by
the toolchain, not declared in source.

The import forms below are the surface syntax that *references* Spaces:

| Form | Status | Meaning |
|---|---|---|
| `import "file.yon"` | ✓ | File import |
| `import m::n [as alias]` | ✓ | Symbol import from a module |
| `import m::n from Space` | ✓ | **Cross-package import**: `n` becomes a remote arrow into `Space` |

Cross-package calls are RPC over a named channel (`/yon_stream_<Space>`):
a call carries only **numbers**, at most **4 arguments** (strings and places
cross by copy on a `Wire<T>`, chapter 17); `internal`
functions are not exported; the server binary is `./<Space>_srv` by convention
(override with `YON_SRV_DIR`), spawned on first contact, shut down in cascade,
and **transparently recovered** after a crash (virgin channel, epoch advanced,
one retry).

Hermeticity model: **cross-package = process isolation** (kernel MMU, values
only on the wire); **intra-package = typed/logical** (visibility, `internal`;
a move's `requires` check is emitted but not yet enforced, chapter 20) with opt-in physical heap separation
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
| `List` | `empty, cons, head, tail, length, is_empty, append, reverse`, an immutable list over the content-addressed heap |
| `HashMap` | `empty, set, has, get, value, size, to_stream`, an immutable map (a trie over the content-addressed heap) |
| `HashSet` | `empty, add, contains, size, union, intersect, to_stream`, an immutable set |
| `XSet` | `empty, add, contains, size, union, intersect, to_stream`, a set of lattice points: one table indexed by the shell, on the Leech heap, changed in place |
| `Sequence` | `from_list, range, map, filter, fold`: a finite, pure sequence over a list, fused into one loop (not the `sequence` keyword) |
| `Stream` | `iterate, take`: an infinite, pure unfold |
| `Vec` | `empty, push, get, set, size`, a dynamic array on an arena strip (in-place mutable, no malloc) |
| `MerkleTree` | `leaf, node2, node2_commutative, node3, node4, label, child, equal, to_stream`, a Merkle tree on the FNV heap. The label is the node's datum, given by whoever builds the node; the identity of the node is the content address of the pair of its label and its children, so two identical subtrees are the same node and `equal` is a comparison of handles, exact. `node2` keeps the order of the children; `node2_commutative`, `node3` and `node4` sort them, for commutative operators |
| `VoyagerList` | `empty, append, get, size, seal, open, corrupt, corrupt_at, to_stream`, a Golay-sealed list: `append` seals each entry into a codeword, `get` decodes it and corrects up to 3 flipped bits. `seal` and `open` do the same on one word (12 bits to a 24-bit codeword and back); `corrupt` and `corrupt_at` flip bits, for tests |
| `Magma` | `gen, closure_size, is_commutative, is_associative, identity, word_push, normal_form, from_catalog` |
| `Space` | `make, set, get`, mutable cells (the mutation mechanism) |

Failure convention: string-producing operations return the `0.0` handle on
failure (missing file, unset variable, out-of-range index).

## Conventions

- Nullary builtins are called with empty parens `()`: `XSet.empty()`,
  `Vec.empty()`. The few with a unit-argument signature take `(0)`:
  `List.empty(0)`, `Time.now_ms(0)`, `Args.count(0)`.
- `.-> P { field value }` and place fields `name type`, no `=`, no `:`.
- A program's exit code is `main`'s return value, truncated mod 256.
- `return` stands where the body ends (or at the end of each branch of a final
  `when … otherwise`); anywhere else it is refused (E2002). Use
  `if/then/else` to select values.

## Keyword index

Every keyword, alphabetically, each linked to its entry in
[Keywords, one by one](/book/keywords):

<details>
<summary>Show all keywords</summary>

<!-- BEGIN keyword-index (generated by website/scripts/gen-keyword-index.py) -->

[`absent`](/book/keywords#absent) ·
[`aggregates`](/book/keywords#aggregates) ·
[`algebra`](/book/keywords#algebra) ·
[`along`](/book/keywords#along) ·
[`and`](/book/keywords#and) ·
[`as`](/book/keywords#as) ·
[`at`](/book/keywords#at) ·
[`back`](/book/keywords#back) ·
[`by`](/book/keywords#by) ·
[`carried`](/book/keywords#carried) ·
[`carry`](/book/keywords#carry) ·
[`cell`](/book/keywords#cell) ·
[`clear`](/book/keywords#clear) ·
[`comp`](/book/keywords#comp) ·
[`compose`](/book/keywords#compose) ·
[`converts`](/book/keywords#converts) ·
[`do`](/book/keywords#do) ·
[`drop`](/book/keywords#drop) ·
[`each`](/book/keywords#each) ·
[`El`](/book/keywords#el) ·
[`el_match`](/book/keywords#el_match) ·
[`else`](/book/keywords#else) ·
[`emit`](/book/keywords#emit) ·
[`error`](/book/keywords#error) ·
[`every`](/book/keywords#every) ·
[`exact`](/book/keywords#exact) ·
[`false`](/book/keywords#false) ·
[`fold`](/book/keywords#fold) ·
[`for`](/book/keywords#for) ·
[`forces`](/book/keywords#forces) ·
[`forever`](/book/keywords#forever) ·
[`from`](/book/keywords#from) ·
[`fst`](/book/keywords#fst) ·
[`fun`](/book/keywords#fun) ·
[`functor`](/book/keywords#functor) ·
[`geomorph`](/book/keywords#geomorph) ·
[`given`](/book/keywords#given) ·
[`hcomp`](/book/keywords#hcomp) ·
[`here`](/book/keywords#here) ·
[`heyting`](/book/keywords#heyting) ·
[`hit`](/book/keywords#hit) ·
[`hit_elim`](/book/keywords#hit_elim) ·
[`I0`](/book/keywords#i0) ·
[`I1`](/book/keywords#i1) ·
[`Id`](/book/keywords#id) ·
[`if`](/book/keywords#if) ·
[`import`](/book/keywords#import) ·
[`in`](/book/keywords#in) ·
[`ind_path`](/book/keywords#ind_path) ·
[`induct`](/book/keywords#induct) ·
[`internal`](/book/keywords#internal) ·
[`is`](/book/keywords#is) ·
[`iter`](/book/keywords#iter) ·
[`law`](/book/keywords#law) ·
[`maps`](/book/keywords#maps) ·
[`match`](/book/keywords#match) ·
[`morph`](/book/keywords#morph) ·
[`morphism`](/book/keywords#morphism) ·
[`most`](/book/keywords#most) ·
[`move`](/book/keywords#move) ·
[`multishot`](/book/keywords#multishot) ·
[`mut`](/book/keywords#mut) ·
[`nat`](/book/keywords#nat) ·
[`not`](/book/keywords#not) ·
[`of`](/book/keywords#of) ·
[`operation`](/book/keywords#operation) ·
[`or`](/book/keywords#or) ·
[`otherwise`](/book/keywords#otherwise) ·
[`over`](/book/keywords#over) ·
[`pair`](/book/keywords#pair) ·
[`parallel`](/book/keywords#parallel) ·
[`PathP`](/book/keywords#pathp) ·
[`Pi`](/book/keywords#pi) ·
[`place`](/book/keywords#place) ·
[`plam`](/book/keywords#plam) ·
[`present`](/book/keywords#present) ·
[`produce`](/book/keywords#produce) ·
[`promote`](/book/keywords#promote) ·
[`prop`](/book/keywords#prop) ·
[`pull`](/book/keywords#pull) ·
[`push`](/book/keywords#push) ·
[`quote`](/book/keywords#quote) ·
[`reduction`](/book/keywords#reduction) ·
[`refl`](/book/keywords#refl) ·
[`repeat`](/book/keywords#repeat) ·
[`requires`](/book/keywords#requires) ·
[`resolves`](/book/keywords#resolves) ·
[`return`](/book/keywords#return) ·
[`Same`](/book/keywords#same) ·
[`scope`](/book/keywords#scope) ·
[`sequence`](/book/keywords#sequence) ·
[`share`](/book/keywords#share) ·
[`show`](/book/keywords#show) ·
[`Sigma`](/book/keywords#sigma) ·
[`snd`](/book/keywords#snd) ·
[`space`](/book/keywords#space) ·
[`spawn`](/book/keywords#spawn) ·
[`stream`](/book/keywords#stream) ·
[`then`](/book/keywords#then) ·
[`this`](/book/keywords#this) ·
[`through`](/book/keywords#through) ·
[`times`](/book/keywords#times) ·
[`to`](/book/keywords#to) ·
[`topos`](/book/keywords#topos) ·
[`true`](/book/keywords#true) ·
[`Type`](/book/keywords#type) ·
[`unifies`](/book/keywords#unifies) ·
[`unknown`](/book/keywords#unknown) ·
[`uses`](/book/keywords#uses) ·
[`via`](/book/keywords#via) ·
[`view`](/book/keywords#view) ·
[`visits`](/book/keywords#visits) ·
[`walk`](/book/keywords#walk) ·
[`when`](/book/keywords#when) ·
[`where`](/book/keywords#where) ·
[`while`](/book/keywords#while) ·
[`wire`](/book/keywords#wire) ·
[`with`](/book/keywords#with)

<!-- END keyword-index -->

</details>
