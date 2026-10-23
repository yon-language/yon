---
id: control-flow
title: "4. Control flow and mutation"
sidebar_position: 4
---

# Control flow and mutation

<!-- yon-gate: exit 42 -->
```yon
fun main(): Number {
  x := present
  mut acc := 0
  when x is present { acc <- 10 }
  otherwise { acc <- 1 }

  grade := if acc > 5 then 2 else 3            // expression form
  acc <- acc + grade                                  // 12

  iter 3 do { acc <- acc + 1 }                        // 15
  mut i := 0
  while i < 2 do {
    acc <- acc + 5                                    // 25
    i <- i + 1
  }
  for every n in List.cons(8, List.cons(9, List.empty(0))) {
    acc <- acc + n                                    // 42
  }
  return acc
}
```

**A cell is declared, and written with `<-`.** `mut acc := 0` declares a
*Space cell*, a mutable cell over the content-addressed heap: every read goes
through it, every `acc <- e` updates it. Mutability shows where it is born: a
name defined with plain `:=` is a value, and writing it is refused (E2008).
(The cells are also usable directly as `Space.make / set / get`.)

**`when` is the statement conditional.** It chains (`when c1 { } when c2 { }
otherwise { }`) and accepts *pattern conditions*: `x is present`,
`x is not 0`, combinable with `and`/`or`. One rule to know: a function's value
is the value of its body, so `return` stands where the body ends — its last
statement, or the last statement of each branch of a `when … otherwise` that
ends the body. A `return` anywhere else is refused (E2002): a `when` without
`otherwise`, and the body of a loop, are for effects. To *select a value*, use
the expression form `if c then a else b`, or end the body with a
`when … otherwise` whose branches each `return`.

**Loops.** `iter n do { }` is the bounded loop (it always terminates);
`while c do { }` is the general one. On top of these, Yon offers:

- `for every x in list { }`, iteration over a `List` (execution is sequential for both this
  and `in sequence over x in list { }` sequentially; parallelism is declared
  intent, not yet a runtime distinction);
- `repeat at most N times { } otherwise { }`, the body runs N times, then
  `otherwise`;
- `forever { }`, the infinite loop, typically paired with effects inside.

<!-- yon-gate: exit 9 -->
```yon
fun main(): Number {
  mut acc := 0
  lst := List.cons(5, List.cons(7, List.empty(0)))
  in sequence over y in lst { acc <- acc + 1 }     // 2
  repeat at most 3 times { acc <- acc + 2 }        // 8
  otherwise { acc <- acc + 1 }                     // 9
  return acc
}
```

A `forever` in flight (the loop runs without bound, printing as it goes):

<!-- yon-gate: illustrative -->
```yon
fun main(): Number {
  mut n := 0
  forever {
    n <- n + 1
    when n > 3 { _p := IO.print_num(n) }
  }
  return 0
}
```

All of these are *surface lowerings* onto `while`, `iter` and Space cells.
There is no second loop machinery underneath.
