---
id: control-flow
title: "4. Control flow and mutation"
sidebar_position: 4
---

# Control flow and mutation

```yon
fun main(): number {
  be x holds present
  be acc holds 0
  when x is present { acc = 10 }
  otherwise { acc = 1 }

  be grade holds if acc > 5 then 2 else 3            // expression form
  acc = acc + grade                                  // 12

  iter 3 do { acc = acc + 1 }                        // 15
  be i holds 0
  while i < 2 do {
    acc = acc + 5                                    // 25
    i = i + 1
  }
  for every n in List.cons(8, List.cons(9, List.empty(0))) {
    acc = acc + n                                    // 42
  }
  return acc
}
```

**`=` is the one mutation.** A binding that is ever the target of `=` is
*promoted to a Space cell*, a mutable cell over the content-addressed heap.
Its `be` allocates the cell, every read goes through it, every `=` updates
it. You never see the cell; you just get a variable that can change. (The
cells are also usable directly as `Space.make / set / get`.)

**`when` is the statement conditional.** It chains (`when c1 { } when c2 { }
otherwise { }`) and accepts *pattern conditions*: `x is present`,
`x is not 0`, combinable with `and`/`or`. One rule to know: a `return` inside
a `when` branch does **not** exit the function, branches are for effects.
To *select a value*, use the expression form `if c then a else b`.

**Loops.** `iter n do { }` is the bounded loop (it always terminates);
`while c do { }` is the general one. On top of these, Yon offers:

- `for every x in list { }`, iteration over a `List` (1.0 executes both this
  and `in sequence over x in list { }` sequentially; parallelism is declared
  intent, not yet a runtime distinction);
- `repeat at most N times { } otherwise { }`, the body runs N times, then
  `otherwise`;
- `forever { }`, the infinite loop, typically paired with effects inside.

```yon
fun main(): number {
  be acc holds 0
  be lst holds List.cons(5, List.cons(7, List.empty(0)))
  in sequence over y in lst { acc = acc + 1 }     // 2
  repeat at most 3 times { acc = acc + 2 }        // 8
  otherwise { acc = acc + 1 }                     // 9
  return acc
}
```

A `forever` in flight (the loop runs without bound, printing as it goes):

```yon
fun main(): number {
  be n holds 0
  forever {
    n = n + 1
    when n > 3 { be _p holds IO.print_num(n) }
  }
  return 0
}
```

All of these are *surface lowerings* onto `while`, `iter` and Space cells, 
there is no second loop machinery underneath.
