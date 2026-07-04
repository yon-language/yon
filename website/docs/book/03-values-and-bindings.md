---
id: values-and-bindings
title: "3. Values and bindings"
sidebar_position: 3
---

# Values and bindings

<!-- yon-gate: exit 62 -->
```yon
fun main(): number {
  be answer holds 42
  be greeting holds "ciao"
  be who holds String.concat(greeting, " mondo")     // strings are values
  be same holds String.equal("ciao", greeting)       // literals are interned
  be wait holds 2500                                 // a duration is just a number (ms)
  when same { be _p holds String.print(who) }
  return String.length(who) + (wait / 250) + answer  // 10 + 10 + 42 = 62
}
```

This program exits with 62 and prints `ciao mondo`. Walking through it:

**Numbers.** `number` is an IEEE double. Arithmetic is the usual
`+ - * / %`.

**Strings.** `text` is the type of a string literal; `String` is the builtin
place whose sections (`concat`, `equal`, `length`, `print`, ...) act on those
values. At runtime a string is a handle into the content-addressed heap, and
literals are **interned**, the same literal is the same value, which is why
`String.equal("ciao", greeting)` holds: equality is equality of content.
Strings are process-local handles: a string does not cross a cross-package
function call, which carries numbers. How structured data moves between
processes is chapter 16.

**Durations.** A duration *is* a `number` of milliseconds, so `2500` (two and
a half seconds) is ordinary arithmetic. The dedicated literal suffixes (`5s`,
`100ms`) were removed in v1.1.0; write the millisecond count directly.

**Truth.** Yon's logical core is intuitionistic: the proposition type Ω has
three literals, `present`, `absent`, `unknown`. `boolean` is a distinct type
that embeds into `proposition` by the canonical injection `true` maps to
`present`, `false` maps to `absent`. `true`/`false` are the two classical
literals. The chapter on the Heyting core develops this.

**Bindings are immutable.** `be x holds e` introduces `x` once. Mutation
exists, but it is a separate, deliberate construct (`=`, Space-cell assignment)
tied to the content-addressed space, next chapter.
