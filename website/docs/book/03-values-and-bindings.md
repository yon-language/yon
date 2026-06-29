---
id: values-and-bindings
title: "3. Values and bindings"
sidebar_position: 3
---

# Values and bindings

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

**Strings.** `text` and `String` are two names for the *same* type: sections
of the builtin `String` place. At runtime a string is a handle into the
content-addressed heap, and literals are **interned**, the same literal is
the same value, which is why `String.equal("ciao", greeting)` holds: equality
is equality of content. Strings are process-local: they never cross a package
boundary (only numbers do).

**Durations.** A duration *is* a `number` of milliseconds, so `2500` (two and
a half seconds) is ordinary arithmetic. The dedicated literal suffixes (`5s`,
`100ms`) were removed in v1.1; write the millisecond count directly.

**Truth.** Yon's logical core is intuitionistic: the proposition type Ω has
three literals, `present`, `absent`, `unknown`, and `boolean` is an alias
of `proposition`. `true`/`false` exist as classical sugar. The chapter on the
Heyting core develops this.

**Bindings are immutable.** `be x holds e` introduces `x` once. Mutation
exists, but it is a separate, deliberate construct (`=`, Space-cell assignment)
tied to the content-addressed space, next chapter.
