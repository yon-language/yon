---
id: values-and-bindings
title: "3. Values and bindings"
sidebar_position: 3
---

# Values and bindings

<!-- yon-gate: exit 62 -->
```yon
fun main(): Number {
  be answer := 42
  be greeting := "ciao"
  be who := String.concat(greeting, " mondo")     // strings are values
  be same := String.equal("ciao", greeting)       // literals are interned
  be wait := 2500                                 // a duration is just a number (ms)
  when same { be _p := String.print(who) }
  return String.length(who) + (wait / 250) + answer  // 10 + 10 + 42 = 62
}
```

This program exits with 62 and prints `ciao mondo`. Walking through it:

**Bindings.** `be x := e` defines `x` as `e`. `:=` reads "is defined as", as
in mathematics: a definition, not an assignment, valid for the whole scope of
`x`. It is the same symbol that defines a field of a place (`side := Number`).

**Numbers.** `Number` is an IEEE double. Arithmetic is the usual
`+ - * / %`.

**Strings.** `Text` (the same type as `String`) is the type of a string
literal; `String` is the builtin place whose sections (`concat`, `equal`, `length`, `print`, ...) act on those
values. At runtime a string is a handle into the content-addressed heap, and
literals are **interned**, the same literal is the same value, which is why
`String.equal("ciao", greeting)` holds: equality is equality of content.
A cross-package function call carries numbers only. A string passed to one
is not yet refused at compile time: it arrives as a wrong value (chapter 19).
Strings and places cross between processes by copy, on a `Wire<T>`
(chapter 17).

**Durations.** A duration *is* a `Number` of milliseconds, so `2500` (two and
a half seconds) is ordinary arithmetic. The dedicated literal suffixes (`5s`,
`100ms`) were removed; write the millisecond count directly.

**Truth.** Yon's logical core is intuitionistic: the proposition type Ω has
three literals, `present`, `absent`, `unknown`. `Boolean` is a distinct type
that embeds into Ω by the canonical injection `true` maps to
`present`, `false` maps to `absent`. `true`/`false` are the two classical
literals. The chapter on the Heyting core develops this.

**Bindings are immutable.** `be x := e` introduces `x` once. Mutation
exists, but it is a separate, deliberate construct (`=`, Space-cell assignment)
tied to the content-addressed space, next chapter.
