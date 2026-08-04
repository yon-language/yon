---
title: "Keywords, one by one"
---

import CodeWindow from '@site/src/components/CodeWindow';

# Keywords, one by one

Every reserved word of Yon, explained next to an example.

This chapter answers *what does it mean?* For the normative table of
valid forms, with status per construct, see the
[Syntax Reference](/syntax-reference).

:::note Reading the snippets
Each runnable snippet below is one project. The `// path` comments name the files:
a world is declared in `yon.toml` (`[world.Name]`, there is no surface `world`
keyword), a Space is a directory, and each file declares a single `place` whose
basename is the place name. The `examples/` projects that back these constructs
follow exactly that layout, and each `run` line compiles the directory with
`yonc <dir>`.
:::

## Top-level declarations

A Yon program is a list of these.

#### `place`

An object living in a world. A place is declared in one of two shapes, both inside `place Name { ... }`. As a **product**: named fields (`side := number`, or the bare `side number`), plus operations (mediated arrows, listed inline with the fields); instances are built with `.-> P { field value }`. As a **coproduct**: a `this >` clause naming the arms it is the sum of (`place Tree { this > Leaf(number) :U Node(Tree, Tree) }`). One place per file, the file's basename is the place name; the world is inferred from the project layout. There is no surface `world` keyword: a world is declared in `yon.toml` (`[world.Name]`), and a Space is a directory under the project root, not a surface declaration. The `space` token survives only inside `wire to space S` (see `wire`).

#### `this`

Heads the coproduct clause of a block place: `this > A :U B` declares the place as the sum of its arms. Each arm is a sub-object of the place (a coproduct injection, a mono), optionally carrying a payload (`Node(Tree, Tree)`). The name is what lets an arm's payload refer to the type being defined, so this is how a genuinely recursive type is written; an anonymous inline sum (`A | B`) cannot name itself. A value is built with the mediatrice `.-> Ctor { _1 a _2 b }` (a bare name denotes a nullary arm's point) and consumed with `match`, one branch per arm; `hit(Ctor, args)`/`hit_elim` remain the kernel spellings of the same constructor/eliminator (Yon0 and the cubical layer speak them directly). At runtime the value is a content-addressed node (the arm is the tag, its arguments are the children), so equal subvalues share storage.

#### `import`

Brings a module or a qualified symbol into scope: `import "x/rates"`, `import q as a`. Multi-file by nature; see the chapter on projects and packages.

#### `internal`

Marks a function as not exported across Spaces: it never enters the cross-Space dispatch table.

#### `given`

`fun f(x: T): U is given` — the body is axiomatic: the compiler realizes it, the language declares its face. It is Java's `native`, and it is the brother of `is <prim>`: that one says the *carrier* is a leaf of the recursion, this one says the *body* is.

It is not a mute promise. The checker verifies that an implementation is actually wired under the name the house qualifies (`Math.floor` → `Math__floor`), and that the declared signature is the wired one — a missing name, a different arity, or a different type are errors. So the boundary with the silicon stops being invisible and becomes a line of Yon: you can read where the language ends and the machine begins.

A `given` function emits nothing: calls resolve to the builtin exactly as before, and the declaration lives in the checker, not in the lowering.

<CodeWindow file="kw_given/"
            run="yonc kw_given/ -o given && ./given; echo $?"
            out={["42"]}>
{`// w/Math.yon
place Math { unit Number
  // is given: the body is wired in the compiler, and the checker verifies it
  fun floor(x: Number): Number is given
  fun sqrt(x: Number): Number is given
}
// Entry.yon
place Entry {
  fun main(): Number {
    be a holds Math.floor(21.9)
    be b holds Math.sqrt(441)
    return a + b
  }
}`}
</CodeWindow>

## Bindings and mutation

#### `be`

The only binding form, and it is immutable: `be x holds e`. There is no `let` and no rebinding. Writing `be x holds e` a second time for a name already bound in the same scope is a compile error ("`x` is already bound in this scope; use `x = ...` to reassign it"); the fix is `x = e`. Shadowing in a nested scope (a loop or `when` body) is allowed, and names that begin with `_` are exempt as throwaways.

#### `holds`

The "equals" of the binding: it reads as English and it means *holds this value at this point*. A later `x = e` is a separate act (promotion to a Space cell), not a rebinding of the `be` name.

#### `=` (assignment)

Mutation, reserved to Space cells: `x = e`. Where `be` is a promise, `=` is an update; the surface has no `becomes` word (the older `becomes` keyword is retired, it survives only as an internal AST node). Rebinding a `be` name does not exist.

#### `when`

The conditional chain: `when c { } when c2 { } otherwise { }`. Consecutive `when` blocks form one chain and the first true branch wins. Branches are for effects: a `return` inside a branch does not exit the function; select values with `if`/`then`/`else` instead.

#### `otherwise`

The else branch, of a `when` chain and of `repeat at most N times`.

#### `if`

Expression-level conditional: `if c then a else b` selects a value, and lowers to `scf.if`. Use it where the branch *is* the result.

#### `then`

Introduces the value of the true branch of `if`.

#### `else`

Introduces the value of the false branch of `if`.

#### `iter`

`iter N do { }`: the bounded loop. It always terminates, by construction.

#### `while`

`while cond do { }`: the general loop. It may not terminate, and that is its job.

#### `do`

Introduces the body of `iter` and `while`.

#### `for`

With `every`: `for every x in e { }`, iteration over a List. Execution is sequential.

#### `every`

The companion of `for`; see above.

#### `here`

`for every x in e when here { }`: the Space filter in the for-every header. Declared intent: execution is sequential and every element passes.

#### `sequence`

`in sequence over x in e { }`: iteration that is sequential by declaration, not by accident.

#### `repeat`

`repeat at most N times { } otherwise { }`: the body runs up to N times, then the otherwise.

#### `at`

Part of the `repeat at most N times` form.

#### `most`

Part of the `repeat at most N times` form.

#### `times`

Part of the `repeat at most N times` form.

#### `forever`

The infinite loop, typically wrapped around effects: a server, a producer, a heartbeat.

<CodeWindow file="v1_control_flow.yon"
            run="yonc v1_control_flow.yon -o v1_control_flow && ./v1_control_flow; echo $?"
            out={["42"]}>
{`fun main(): Number {
  be acc holds 0
  be lst holds List.cons(5, List.cons(7, List.cons(9, List.empty(0))))

  for every x in lst { acc = acc + x }            // 21
  in sequence over y in lst { acc = acc + 1 }     // 24
  repeat at most 3 times { acc = acc + 2 }        // 30
  otherwise { acc = acc + 1 }                     // 31

  be d holds 2000 + 500                           // 2500
  when d == 2500 { acc = acc + 10 }               // 41

  be i holds 0
  while i < 1 do {
    acc = acc + 1                                 // 42
    i = i + 1
  }
  return acc
}`}
</CodeWindow>

#### `scope`

The formally hermetic block: `scope { }` lowers to an MLIR `IsolatedFromAbove` region and the verifier enforces that nothing leaks in or out.

<CodeWindow file="hermetic_scope.yon"
            run="yonc hermetic_scope.yon -o hermetic_scope && ./hermetic_scope; echo $?"
            out={["42"]}>
{`fun main(): Number {
  be base holds 40
  scope Hermetic {
    be sealed holds base + 2
  }
  return base + 2
}`}
</CodeWindow>

#### `forces`

The Kripke-Joyal forcing block: `forces stage cond { }` runs its body at a stage of the site, where the condition is forced. See the Heyting core chapter for the worked example.

<CodeWindow file="forcing_demo/"
            run="yonc forcing_demo/ -o forcing && ./forcing; echo $?"
            out={["0"]}>
{`// net/NodeA.yon
place NodeA { value Number }
// Entry.yon
place Entry {
  fun guard(): Number {
    forces NodeA value is Number {
      return 1
    }
    return 0
  }
  fun main(): Number { return 0 }
}`}
</CodeWindow>

#### `produce`

The producer block: `produce { ... }` builds a stream, the body emits into it, and the value of the block is the stream. Streams are consumed with the methods: `s.fold(init, fun(acc, v) => ...)` accumulates (state threads through the parameters), `s.for_every(f)` runs a function on each value. The close is structural: when the block ends, nobody can write any more, so the stream closes itself and the drain stops on its own. Lists keep the `for every x in xs` statement; streams use the methods.

#### `emit`

Emits a value: into the stream being built inside a `produce` block, or into the active handler inside a reduction's `on` clause.

<CodeWindow file="kw_produce_emit.yon" run="yonc kw_produce_emit.yon -o produce_emit && ./produce_emit; echo $?" out={["42"]}>

```yon
fun main(): Number {
  be s holds produce {
    emit 41
    emit 1
  }
  be total holds s.fold(0, fun(a: Number, v: Number) => a + v)
  return total        // 41 + 1 = 42
}
```

</CodeWindow>

#### `return`

Returns from the function. Inside a `when` branch it does not exit the function; branches are for effects.

#### `.->`

Instance construction: `.-> P { field value }`. The instance's Space is the place's directory on the filesystem, so the Space is not named at the construction site.

## Word-form operators

#### `and`

Conjunction, in expressions and in pattern conditions: `when a is present and b is present`.

#### `or`

Disjunction, same positions as `and`.

#### `where`

The constraint of the `topos ... where { }` block, and of the comprehension `{ x : A where P }`: the subobject carved out by the fibre P. With a mere-proposition fibre the comprehension is exactly the classified subobject of the formalization. (The older `all P where cond` quantifier is retired.)

<CodeWindow file="comprehension_carrier/"
            run="yonc comprehension_carrier/ -o comprehension && ./comprehension; echo $?"
            out={["0"]}>
{`// w/Account.yon
place Account { balance Number }
// Entry.yon
place Entry {
  fun takes_sub(s: { a : Account where Pi(x: Account). Pi(y: Account). Id(Account, x, y) }): Number { return 0 }
  fun main(): Number { return 0 }
}`}
</CodeWindow>

## The four kinds of handle

Static structures of the topos: they compose, they do not nest.

#### `fun`

The ordinary function, and the inline lambda form `fun(x) => e` where an argument expects one.

#### `move`

A map between two places: `move m from A to B { }` with a body of mapping clauses, or the inline `move(s: P) => e from P to Q`. Applied with `apply_move`.

#### `view`

A representable functor on a place: the declaration `view V of P { show ... }` (lowered to a record place plus a constructor) or the inline `view(s: P) => e of P`.

#### `reduction`

Folds a structure to a value. Declared `reduction ... of P { on op { } be seed holds e }` against a place that declares operations, or inline `reduction(acc, x) => e of P`.

#### `operation`

A method signature declared inline on a place; it carries an effect and may bind to a certified algebra with `uses algebra`.

#### `cell`

A higher cell inside a place, CaTT style: the seed of the higher-dimensional structure.

<CodeWindow file="handle_lambdas/"
            run="yonc handle_lambdas/ -o handles && ./handles; echo $?"
            out={["44"]}>
{`// w/P.yon
place P { v Number }
// w/Q.yon
place Q { v Number }
// w/R.yon
place R { v Number }
// Entry.yon
place Entry {
  fun main(): Number {
    be m1 holds move(s: P) => .-> Q { v 1 } from P to Q
    be m2 holds move(s: Q) => .-> R { v 2 } from Q to R
    be mm holds compose m1 with m2
    be sp holds .-> P { v 0 }
    be sr holds mm(sp)
    be vw holds view(s: P) => 40 of P
    be forty holds vw(sp)
    return forty + 4
  }
}`}
</CodeWindow>

## Views and `show`

#### `show`

Inside a view declaration: `show f` exposes the field, `show f = e` a derived value, `show f as "label"` keeps the field with presentation metadata.

#### `as`

The aliasing word: `import q as a`, `show f as "label"`.

<CodeWindow file="kw_view_show/"
            run="yonc kw_view_show/ -o view_show && ./view_show; echo $?"
            out={["8"]}>
{`// w/Account.yon
place Account { balance Number
  fee Number
  view Snapshot of Account {
    show balance
    show net = balance - fee
    show fee as "monthly fee"
  }
}
// Entry.yon
place Entry {
  fun main(): Number {
    be acc holds .-> Account { balance 50
      fee 8 }
    be snap holds Snapshot(acc)
    return snap.net + snap.fee - snap.balance + 8    // 42 + 8 - 50 + 8 = 8
  }
}`}
</CodeWindow>

## Moves and mapping clauses

#### `unifies`

The merge move: `move m unifies A, B { }` merges two places field by field, applied with `Move.merge(m, s1, s2)`; the result lives in the first source place.

#### `share`

In the merge move: the fields shared without conflict.

#### `resolves`

`conflict on f resolves to fn`: the function that decides a conflicting field, applied to both values.

#### `maps`

`A maps to B by f`: the rename clause of a move (the `by` is mandatory).

#### `converts`

`A converts to B by f`: the transform clause.

#### `aggregates`

`src aggregates to dst by f`: the aggregation clause, one source in the grammar. The three kinds are operationally `f(source)`; the distinction is declared intent.

<CodeWindow file="kw_merge_move/"
            run="yonc kw_merge_move/ -o merge_move && ./merge_move; echo $?"
            out={["22"]}>
{`// w/A.yon
place A { v Number
  w Number }
// w/B.yon
place B { v Number
  w Number }
// w/Wide.yon
place Wide { x Number
  y Number }
// w/Narrow.yon
place Narrow { x Number
  total Number }
// Entry.yon
place Entry {
  fun pick(a: Number, b: Number): Number { return a }
  fun ident(x: Number): Number { return x }
  fun double(x: Number): Number { return x * 2 }
  move Merge unifies A, B {
    share v
    conflict on w resolves to pick
  }
  move Squeeze from Wide to Narrow {
    x maps to x by ident
    y aggregates to total by double
  }
  fun main(): Number {
    be a holds .-> A { v 7
      w 1 }
    be b holds .-> B { v 7
      w 9 }
    be m holds Move.merge(Merge, a, b)
    be wide holds .-> Wide { x 4
      y 5 }
    be narrow holds apply_move(Squeeze, wide)
    return m.v + m.w + narrow.x + narrow.total   // 7 + 1 + 4 + 10 = 22
  }
}`}
</CodeWindow>

## Certified algebra

#### `algebra`

Names an algebra from the certified catalog: `uses algebra Additive`.

#### `uses`

Binds an operation to its algebra; the compiler checks the claim against the catalog.

#### `law`

Declares an algebraic law on a place; a false claim is rejected at compile time.

#### `fold`

Names a space's fold function: `with fold "sum_f64"`.

<CodeWindow file="kw_algebra/"
            run="yonc kw_algebra/ -o kw_alg && ./kw_alg; echo $?"
            out={["0"]}>
{`// alg/Or.yon
place Or {
  operation join(a: Number, b: Number): Number uses algebra BooleanOr
  law commutative
  law associative
}
// Entry.yon
place Entry {
  fun main(): Number {
    return 0
  }
}`}
</CodeWindow>

## Functors and directions

#### `functor`

A map between worlds that preserves the categorical structure; composable with `compose`.

#### `nat`

A natural transformation between two functors: `nat transform Eta from F to G { for each X by F }`, the clause naming how each component is built. The naturality square (η_Y ∘ F(f) = G(f) ∘ η_X) is its law; 1.1.0 checks the structural precondition, the full equation is future work. (Example `nat_transform_functor`.)

#### `compose`

Handle composition with kind discipline: `(compose f with g)(x) = g(f(x))`.

#### `topos`

The first-class declaration: a category rich enough to do logic inside, with its morphisms and props in one `where` block. With topos-per-space, the objects are inferred from the filesystem (the place files in the Space), so a topos no longer carries an inline `objects { }` block (that keyword is retired) — and the terminal is not declared either: every topos has one by definition (`terminal` is retired with it).

#### `morphism`

A single map inside a topos's `morphisms { }` block, and the contextual word in `on morphism N via M`.

#### `prop`

A subobject classifier map into Omega: `prop is_overdrawn(s) = ...`. The return type is not written — `prop` already implies proposition. Syntactically it signals the categorical intent, a subobject rather than an arbitrary function.

<CodeWindow file="kw_topos_block/"
            run="yonc kw_topos_block/ -o topos_block && ./topos_block; echo $?"
            out={["42"]}>
{`// bank/State.yon
place State { balance Number }
// bank/Unit1.yon
place Unit1 { u Number }
// bank/Topos.yon  (objects are inferred from the place files in bank/)
topos Bank where {
  
  morphism tag(s: State): Number
  morphism lift(s: State): Number
  prop is_overdrawn(s: State) = s.balance < 0
}
// Entry.yon
place Entry {
  fun main(): Number {
    be s holds .-> State { balance 5 }
    be bad holds is_overdrawn(s)
    return if bad then 0 else 42
  }
}`}
</CodeWindow>

#### `morph`

A single functor between topoi: `morph F from A to B { }` with the two-word contextual aspects `on object` and `on morphism ... via ...`.

#### `via`

In `on morphism op via op2`: names the operation that realizes the map.

<CodeWindow file="kw_morph/"
            run="yonc kw_morph/ -o morph && ./morph; echo $?"
            out={["0"]}>
{`// shop/Account.yon
place Account { balance Number }
// shop/AccountEU.yon
place AccountEU { balance Number }
// Entry.yon
place Entry {
  morph LiftEU from Account to AccountEU {
    on object(s: Account): AccountEU {
      return .-> AccountEU { balance s.balance }
    }
  }
  fun main(): Number { return 0 }
}`}
</CodeWindow>

#### `each`

In `for each X by fnX` inside a `nat transform`: one component per object of the natural transformation.

<CodeWindow file="nat_transform_functor/"
            run="yonc nat_transform_functor/ -o nattransform && ./nattransform; echo $?"
            out={["0"]}>
{`// yon.toml declares two worlds: [world.W] and [world.V]
[package]
name = "nat_transform_functor"

[world.W]
objects = ["X"]

[world.V]
objects = ["Y"]

[runtime]
backend = "memory"
// Entry.yon
place Entry {
  functor F(x: Number) from W to V { return x }
  functor G(x: Number) from W to V { return x }
  nat transform Eta from F to G {
    for each X by F
  }
  fun main(): Number { return 0 }
}`}
</CodeWindow>

## Categorical constructions

#### `geomorph`

The geometric morphism between worlds: the adjoint pair `pull` (inverse image, f*) and `push` (direct image), with the clause `exact push` (`adjunction` and `exact pull` are retired: they declared the implied — f* is left exact by definition).

#### `pull`

Inside a geomorph: the inverse image, the left adjoint.

#### `push`

Inside a geomorph: the direct image, the right adjoint.

#### `exact`

`exact push`: the direct image f_* preserves finite limits — the exactness that is NOT automatic. `exact pull` is retired: f* is left exact in every geometric morphism by definition.

<CodeWindow file="kw_geomorph_full/"
            run="yonc kw_geomorph_full/ -o geomorph_full && ./geomorph_full; echo $?"
            out={["0"]}>
{`// shop/Account.yon
place Account { balance Number }
// shop/AccountEU.yon
place AccountEU { balance Number }
// Entry.yon
place Entry {
  geomorph Lift from Account to AccountEU {
    exact push
    pull(a: AccountEU): Account {
      be tmp holds a
      return tmp
    }
    push(a: Account): AccountEU {
      be tmp holds a
      return tmp
    }
  }
  fun main(): Number { return 0 }
}`}
</CodeWindow>

#### `over`

The slice: `place P over X` declares objects equipped with a chosen map down to X.

## Worlds of errors

#### `error`

`error E subcontains Base { }`: an error is a place that is a subobject of Base, every E is a Base. A place declares its error morphism with the two-word phrase `on error E`.

#### `of`

`list of T`, `view of P`, `reduction ... of P`, `map of K to V`.

#### `in`

`for every x in e` (iterate over the elements of `e`).

#### `to`

`move m from A to B`, `maps to`, `resolves to`, `map of K to V`.

#### `from`

The source of a move, morph, geomorph or import.

#### `by`

`A maps to B by f`: names the function realizing a clause.

#### `is`

The pattern condition `e is pattern` (a variable, a literal, `present`, `absent`, `unknown`). Literal and text equality compile to the single content-addressed comparison.

<CodeWindow file="kw_is_literal.yon"
            run="yonc kw_is_literal.yon -o is_literal && ./is_literal; echo $?"
            out={["x is seven", "city is rome", "other is not rome", "30"]}>
{`fun pick(x: Number): Number visits Output {
  when x is 7 {
    be _ holds String.print("x is seven")
  }
  return 10
}
fun name_check(a: Number, b: Number): Number visits Output {
  be city holds "rome"
  when city is "rome" {
    be _ holds String.print("city is rome")
  }
  be other holds "paris"
  when other is not "rome" {
    be _ holds String.print("other is not rome")
  }
  be y holds (a + b)
  when y is a {
    be _ holds String.print("NEVER: y equals a")
  }
  return 20
}
fun main(): Number visits Output {
  be r1 holds pick(7)
  be r2 holds name_check(2, 3)
  return r1 + r2
}`}
</CodeWindow>

#### `with`

`with multishot`, `with fold`, `compose f with g`.


#### `requires`

`move m ... requires CAP1, CAP2`: the capabilities a move demands.

<CodeWindow file="kw_list_here.yon"
            run="yonc kw_list_here.yon -o list_here && ./list_here; echo $?"
            out={["21"]}>
{`fun total(xs: List<Number>): Number {
  be acc holds 0
  for every x in xs when here {
    acc = acc + x
  }
  return acc
}
fun main(): Number {
  be lst holds List.cons(5, List.cons(7, List.cons(9, List.empty(0))))
  return total(lst)
}`}
</CodeWindow>

#### `multishot`

`with multishot`: the continuation may be resumed more than once.

## Streams and back-pressure

#### `stream`

In member position (`subscription.stream`): the subscription's stream handle. The stream TYPE is the generic `Stream<T>` (the spelling `stream of T` is retired).

#### `wire`

`wire to space S` opens the transport toward a Space. The producer side declares a public function returning `Stream<T>`; the consumer subscribes by name with `w.awaits(producer)` and materializes the emissions with `.stream`. Three errors are caught at compile time: an unknown Space, a function the Space does not declare, a declared function that is not a producer. The channel identity is the producer's dispatch selector: nominal on both sides, no literals anywhere.

<CodeWindow file="subscriber.yon" run="yonc sensors.yon -o Sensors_srv && yonc subscriber.yon -o subscriber && ./Sensors_srv && ./subscriber; echo $?" out={["36"]}>

```yon
// sensors.yon, the producer package -> ./Sensors_srv
fun readings(): Stream<Number> {
  be s holds produce {
    emit 10
    emit 11
    emit 15
  }
  return s
}
fun main(): Number { return 0 }

// subscriber.yon, the consumer
import sensors::readings from Sensors

fun main(): Number {
  be w holds wire to space Sensors
  be sub holds w.awaits(readings)
  be s holds sub.stream
  be total holds s.fold(0, fun(a: Number, v: Number) => a + v)
  return total      // 10+11+15 = 36, from another process
}
```

</CodeWindow>

The stream back-pressure modifiers `buffer N` and `drop oldest` / `drop newest` were parsed but never consumed, and were removed in v1.1.0: `buffer` is no longer a reserved word. (`drop` was later reintroduced with an unrelated meaning, the Space-reclaim statement `drop X`; see below.)

#### `space`

A reserved word that appears in the surface only as the target of a wire, `wire to space S`. A Space itself is not declared with a surface block: it is a directory in the package, and its world is read from `yon.toml` (`[world.X]`). So `space` names the destination of a transport, while the Space's existence and world come from the filesystem.

#### `drop`

`drop X` reclaims Space `X` at this point: an explicit, compile-time-checked assertion that `X` is no longer needed. Two obligations are checked, in order. First `X` must be a declared Space, a directory named in a world's `spaces` list; a `drop` of an unknown name, a typo, is rejected as an unknown Space before anything else. Then the check proves that no arc toward `X` is reachable downstream of the drop (a `wire to space X`, a use of a symbol imported `from X`, or a call that reaches either transitively); an early drop, with such an arc still ahead, is a compile error that names the offending arc. The criterion is existence and reachability in the source, computed statically with no runtime bookkeeping, so a `drop` turns a wrong assumption about a Space's lifetime into a diagnostic rather than a shortcut.

## Concurrency: spawn and collect

#### `spawn`

`spawn { ... }` forks one isolated replica that runs the body in a separate OS process; `spawn in N parallel { ... }` forks N of them, which run on real cores at once. The value of a `spawn` block is the collection stream: every `promote` in the body contributes one element, and the parent drains it with the stream methods (`.fold`, `.for_every`). The replicas are isolated by construction (each gets its own heap), so the collection is unordered; an order-independent fold over it is deterministic.

#### `promote`

Inside a `spawn` body, `promote E` emits `E` onto the parent's collection stream, the spawn counterpart of `emit`. A `spawn` block with no `promote` is a compile-time error (it would collect nothing). The implicit variable `spawn_index` (0 to N-1) is in scope in the body, the replica's own index.

#### `parallel`

The replica-count marker in `spawn in N parallel { ... }`: `N` is evaluated in the parent before the fork and gives the number of replicas. (`=` is not yet supported inside a spawn body; use `Space.set`, or compute the value before the block. The full fix lands with the produce rework.)

<CodeWindow file="spawn_parallel_collect.yon" run="yonc spawn_parallel_collect.yon -o spc && ./spc; echo $?" out={["10"]}>

```yon
fun main(): Number {
  be results holds spawn in 4 parallel {
    promote spawn_index + 1
  }
  be total holds results.fold(0, fun(a: Number, v: Number) => a + v)
  return total      // (0+1)+(1+1)+(2+1)+(3+1) = 1+2+3+4 = 10
}
```

</CodeWindow>

The wall-clock scaling of `spawn in N parallel` is measured in Appendix D: N replicas of a fixed task finish in roughly the time of one until N meets the core count, a near-linear speedup (`regression/book/jp/bench/spawn_scaling`).

## Three-valued logic and effects

#### `present`

The certain-true value of the Heyting tri-value, and a pattern in `when`/`forces`.

#### `unknown`

The third truth value: not provable, not refutable. An unknown condition decides to false: nothing provable, nothing run.

#### `absent`

The certain-false value as a pattern. A *false* proposition is still `present`, a known falsehood; only `unknown` is not present.

#### `not`

Pattern negation, `e is not pattern`: the Heyting negation of the positive test, computed at runtime through `heyt_not`.

<CodeWindow file="kw_patterns.yon"
            run="yonc kw_patterns.yon -o patterns && ./patterns; echo $?"
            out={["p is not absent", "u is unknown", "6"]}>
{`fun chain_one(a: Number, b: Number): Number visits Output {
  be p holds (a < b)
  when p is not absent {
    be _ holds String.print("p is not absent")
  }
  return 1
}
fun chain_two(d: Number): Number visits Output {
  be u holds unknown
  when u is unknown {
    be _ holds String.print("u is unknown")
  }
  return d
}
fun chain_three(a: Number, b: Number): Number visits Output {
  be p holds (a < b)
  when p is absent {
    be _ holds String.print("NEVER printed: p is a known truth")
  }
  return 3
}
fun main(): Number visits Output {
  be x holds chain_one(3, 5)
  be y holds chain_two(2)
  be z holds chain_three(3, 5)
  return x + y + z
}`}
</CodeWindow>

#### `heyting`

`heyting<N>` / `heyting(v, mask)`: integers in Heyting arithmetic, trits with an Unknown mask; `&?` is trit-wise with mask propagation and the Omega connectives follow the intuitionistic rules.

<CodeWindow file="kw_heyting.yon"
            run="yonc kw_heyting.yon -o heyting && ./heyting; echo $?"
            out={["42"]}>
{`fun main(): Number {
  be u holds unknown
  be p holds present
  be both holds p &&? u            // unknown: conjunction with the undecided
  be imp holds u =>? p             // present: anything implies the present
  be dec holds to_bool(imp)
  be h1 holds heyting(5)           // trits 101, all certain
  be h2 holds heyting(5, 2)        // middle trit unknown
  be hand holds h1 &? h2           // trit-wise, the unknown propagates
  return if dec then 42 else 0
}`}
</CodeWindow>

#### `visits`

The effect signature: `fun h(x) visits Output`. Whoever calls must cover the effect, all the way up to `main`.

#### `true`

The boolean literal, in Omega.

#### `false`

The boolean literal, in Omega.

## HoTT: pairs, paths, universes

#### `Pi`

The dependent product: `Pi(x: A). B` is the type of dependent functions. As a comprehension fibre, a Pi chain into `Id` is a mere proposition.

#### `Sigma`

The dependent sum: `Sigma(x: A). B` is the type of dependent pairs, lowered to the honest two-field struct.

#### `Id`

The identity type: `Id(A, x, y)` is the type of paths from x to y.

#### `pair`

The constructor of the Sigma pair.

#### `fst`

First projection of the pair.

#### `snd`

Second projection of the pair.

<CodeWindow file="kw_hott.yon"
            run="yonc kw_hott.yon -o hott && ./hott; echo $?"
            out={["42"]}>
{`fun takes(p: Sigma(x: Number). Number): Number {
  return fst(p) + snd(p)
}
fun proj_sum(a: Number, b: Number): Number {
  be p holds pair(a, b)
  be x holds fst(p)
  be y holds snd(p)
  return x + y
}
fun main(): Number {
  be direct holds takes(pair(20, 10))
  return direct + proj_sum(7, 5)        // 30 + 12 = 42
}`}
</CodeWindow>

#### `refl`

KERNEL FORM (the surface spelling is `clear`). The reflexivity path: the proof that a value equals itself. A path value lowers to its *erased witness*, operationally the endpoint value, so `refl(7)` binds and passes like any value. What it never does is decide path equality at runtime: that judgement belongs to the reducer alone. Yon0 and the cubical layer speak `refl` directly; human surface code says `clear 7`.

#### `Same`

`Same(X, Y)` is the proposition that `X` and `Y` are the same value, sugar for `Id(A, X, Y)` with the carrier `A` inferred from the endpoints. It reads as a law of the domain — `Same(total(merge(a, b)), total(a) + total(b))` — without spelling out the carrier. The raw `Id(A, X, Y)`, carrier written, stays available in the lower stratum for when the endpoints do not determine it.

#### `clear`

THE surface spelling of reflexivity, one keyword with two shapes. `clear a` is the trivial path, the proof that `a` is clearly itself (kernel: `refl(a)`) — the journey that goes nowhere; read off at either end, it is just `a`. Bare `clear` is the proof that the two sides of a `Same` (or `Id`) return type are the same *by computation* — reflexivity of the endpoint, inferred from the goal; it is checked, not asserted: if the two sides do not reduce to one value the compiler rejects it, the same gate as the kernel `refl` written by hand, and it is valid only in return position, where the goal fixes which endpoint to reflect. Part of the *journey* vocabulary for paths (`clear`/`back`/`through`/`span`/`carry`/`along`, `++`, `<=>`), plain names for the cubical primitives.

#### `back`

`back p` is the path `p` travelled in reverse, sugar for `inv(p)`. Reverse a reverse and you return to the start: `back back p` is `p` (prefixes chain; parentheses only when an infix rides underneath: `back (p ++ q)`). If `p` runs from `a` to `b`, `back p` runs from `b` to `a`.

#### `through`

`p through f` carries the path `p` *through* the function `f`, sugar for `ap(f, p)`. If `p` runs from `a` to `b`, then `p through f` runs from `f a` to `f b`: structure preserved under the map (functoriality).

#### `carry`

`carry x along e` carries the value `x` along the bridge `e`, sugar for `transport(ua(e), x)`. When `e` is `f <=> g`, this computes to `f x`: an equivalence of *types* becomes computation on *values*. Always paired with `along`.

#### `along`

The second half of `carry x along e` (see `carry`): it names the bridge the value travels. `along` has no meaning on its own.

#### `ind_path`

The J eliminator, the one tool of path induction: to prove something about every path, prove it on `refl`. `ind_path(C, d, p)` computes `d(basepoint)` when the path is `refl` in evidence at the call site. A J stuck on a non-trivial path is rejected at compile time, loudly: the runtime never identifies `loop` with `refl`, so the circle stays a circle.

#### `induct`

`induct(d, p)` is path induction with the motive left implicit, sugar for `ind_path(0, d, p)`. It fires the same computation rule, `induct(d, refl(a)) = d(a)`, and carries the same operational boundary: a J stuck on a non-`refl` path is still rejected. The motive is omitted the way `match` omits the eliminator motive — Yon's eliminators compute, they do not carry a full dependent motive; the raw `ind_path(C, d, p)` stays available when you want to write it.

#### `Type`

The universe of types (`Type_1`, `Type_2`, ... for the levels). A universe-typed parameter compiles to an inert runtime token: types are compile-time citizens, and the runtime never inspects one.

<CodeWindow file="kw_paths.yon"
            run="yonc kw_paths.yon -o paths && ./paths; echo $?"
            out={["42"]}>
{`fun diag(a: Number): Number { return a * 6 }
fun universe_taker(t: Type): Number { return 7 }
fun main(): Number {
  be r holds clear 7                          // a path value, let-bound
  be moved holds ind_path(0, diag, clear 7)   // J computes diag(7) = 42
  return moved
}`}
</CodeWindow>

## Cubical composition and universe codes

These are active in the kernel today: their reductions are exercised by the
`regression/yon_tests/prove` oracle (definitional equality, the emitter exits 0 only when the
reducer agrees) and they run end to end (`examples/circle_hit`). The full pedagogical treatment of
cubical type theory is future work (1.2). All are type-level or proof constructs: they reduce or
erase at compile time, so they carry no runtime benchmark.

#### `plam`

Path abstraction: `plam i => e` builds a path by binding a dimension variable `i`; applied at an
endpoint it recovers the face. The companion of `refl` for non-constant paths (`path_app`,
`path_typed`).

#### `I0`

Interval endpoint 0: the start of the abstract interval a path runs over. Read a closed path at its
start with `p @ I0`, and substituting `i := I0` in a `plam i => e` recovers the path's left face.
Paired with `I1`.

#### `I1`

Interval endpoint 1: the far end of the interval. `p @ I1` reads a path at its end, and `i := I1` in a
`plam i => e` recovers the right face. Paired with `I0`.

#### `PathP`

Dependent path type: the type former behind a path whose endpoints live in a family of types that
itself varies over the interval, the dependent generalisation of `Id`. A `plam i => e` inhabits a
`PathP` when the type of `e` depends on `i`; when it does not, the `PathP` is just an ordinary `Id`
path.

#### `comp`

Kan composition: transports along a path system, filling the missing face. On a constant system it
reduces to the identity (`comp_refl`), and it computes through a `ua` path (`comp_ua_id`) in the
reducer.

#### `hcomp`

Homogeneous composition: closes an open box from its faces; when a face is active the reducer
selects it (`hcomp_face_active`). The Kan operation that makes the cubical structure compose.

#### `hit`

KERNEL FORM. Higher inductive type constructor: `hit(base)`, `hit(loop)`, `hit(merid, a)` build the points and
paths of a HIT (the circle's `base` and `loop`, a suspension's meridian).

#### `hit_elim`

Higher inductive type eliminator: one branch per constructor, the path branches required to respect
the points. The reducer never identifies `loop` with `refl`, so the circle stays a circle.

#### `match`

KERNEL FORM (the surface eliminator is `match`). `match x { ctor => v, .. }` is `hit_elim` with the motive synthesized or, in checked position, taken from the expected type — so every branch may read its payload (`fun total(t: Tree): number { return match t { Leaf { _1 as v } => v, ... } }`). Field patterns bind projections by name (`Cons { _1 as h _2 as t }`, empty braces `Gray { }` discard a payload); `hit_elim(motive, [...], x)` remains the explicit kernel spelling for dependent motives written by hand.

#### `El`

Universe-code type: `El(c)` is the type of inhabitants of the code `c`, "the elements of `c`". It is
the bridge the [Generics](/book/generics) chapter leans on: a generic field of parameter type `T`
lowers to `El(T)`, a genuine element of the universe rather than an erased placeholder. `quote(c, a)`
introduces an inhabitant; `el_match` eliminates one.

#### `quote`

Universe-code introduction: `quote(c, a) : El(c)` packages an inhabitant `a` under the code `c` that
names its type. It lowers to its inhabitant and runs; the deeper Tarski reflection (a code inspecting
its own structure) is 1.2.

#### `el_match`

Universe-code elimination: `el_match(target, ret, body)` eliminates an `El(_)` by handing its
inhabitant to `body`. Lowers to the body application and runs.

<CodeWindow file="circle_hit.yon" run="yonc circle_hit.yon -o circle_hit && ./circle_hit; echo $?" out={["42"]}>
{`fun motive(x: S1): Number { return 0 }
fun circle_elim(): Number {
  return hit_elim(motive, [base => 42, loop => plam i => 42], hit(base))
}
fun main(): Number {
  return circle_elim()
}`}
</CodeWindow>
