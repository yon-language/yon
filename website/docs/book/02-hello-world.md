---
id: hello-world
title: "2. Hello, world"
sidebar_position: 2
---

# Hello, world

A Yon program is a list of top-level declarations; execution starts at `main`,
which returns a `number`:

<!-- yon-gate: exit 0 -->
```yon
fun main(): number {
  return 0
}
```

Compile and run it with `yonc`, the end-to-end compiler (OCaml frontend → the
Topos MLIR dialect → LLVM → a native executable):

```bash
$ yonc hello.yon -o hello
$ ./hello
```

The process **exit code is `main`'s return value, truncated mod 256**, and Yon
programs commonly use it as their observable result:

<!-- yon-gate: exit 44 -->
```yon
fun main(): number {
  return 300   // the process exit code is main's value mod 256 -> 44
}
```

Printing takes one call:

<!-- yon-gate: exit 0 -->
```yon
fun main(): number {
  be _p holds String.print("ciao, mondo")
  return 0
}
```

Two things are already visible here. First, `be x holds e` is *the* binding
form of Yon, immutable, used everywhere (there is no `let`). Second, the
string literal is a real value: since the 1.0 *string fusion*, `"ciao, mondo"`
is a section of the builtin `String` place, interned on the content-addressed
heap.

`String.print` is a direct builtin. Yon also has an *effectful* printing path
(`Output.print` under the `visits Output` effect), we will meet it in the
chapter on functions and effects.

You can stop the compiler at any stage and look at what it produced:

```bash
$ yonc --emit=mlir hello.yon      # the Topos-dialect MLIR from the frontend
$ yonc --emit=standard hello.yon  # after the Topos -> standard lowering
$ yonc --emit=ll hello.yon        # the LLVM IR
```
