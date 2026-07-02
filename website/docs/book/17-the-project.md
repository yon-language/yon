---
id: the-project
title: "17. The project: a ledger in three packages"
sidebar_position: 17
---

# The project: a ledger in three packages

Everything in one walkthrough: a git dependency, a service in its own Space,
a client that loops over the wire. Three packages, and every file and
command on this page was run, in this order, before being written down.

```
yonproj/
├── rates/          # a library, published as a git repository
├── bank/           # the Bank service (its own Space, its own process)
└── ledger/         # the executable: imports both
```

## 1. The library: `rates`

A library is a directory without a `main`. Publish it by pushing a tag:

<!-- yon-gate: illustrative -->
```yon
/* rates, currency conversion, published as a git package. */
fun eur_to_usd(eur: number): number { return eur * 110 / 100 }
```

```bash
$ git init rates && cd rates && git add -A
$ git commit -m "v1.0" && git tag v1.0
```

## 2. The service: `bank`

The Bank exposes pure domain logic over the wire. Two facts of life for a
service package. First, only `internal` separates the private from the
exported: everything else with a numeric signature (arity ≤ 4) is on the
wire. Second, **a service still has a `main`**: the compiled binary is both
the program and the server (chapter 15), so an idle `main` is the
convention.

<!-- yon-gate: exit 0 -->
```yon
/* The Bank service: pure domain logic, exported over the wire. */
fun deposit_net(amount: number): number {
  return amount - fee(amount)
}

fun fee(amount: number): number {
  return amount / 20            // 5%
}

internal fun audit_key(x: number): number { return x * 1789 }

/* A service package still has a main: the binary is both the program and
 * the server (serve mode is chosen at launch). An idle main is the rule. */
fun main(): number { return 0 }
```

Compile it **as the server binary**, named for its Space and placed next to
the client that will spawn it:

```bash
$ yonc bank/bank.yon -o ledger/Bank_srv
```

## 3. The executable: `ledger`

The manifest declares the git dependency; `yon-pkg install` resolves it into
`yon_modules/` and pins the commit in `yon.lock`:

```toml
[package]
name = "ledger"
version = "0.1.0"

[dependencies]
rates = { git = "https://github.com/utente/rates", version = "1.0" }
```

And the program, both kinds of import at work, a loop, mutation, and three
calls that each cross a process boundary:

<!-- yon-gate: illustrative -->
```yon
import "yonproj/rates"
import bank::deposit_net from Bank

fun main(): number {
  be deposits holds List.cons(100, List.cons(60, List.cons(40, List.empty(0))))
  be total holds 0
  for every d in deposits {
    total = total + deposit_net(d)           // three calls cross the wire
  }
  be usd holds rates::eur_to_usd(total)      // 190 EUR -> 209 USD
  be _p holds IO.print_num(usd)
  return usd - 167                           // 42
}
```

```bash
$ cd ledger && yon-pkg install
$ yonc main.yon -o ledger
$ ./ledger
209
$ echo $?
42
```

What just happened, end to end: the first `deposit_net(100)` **forked and
spawned `./Bank_srv`**; each iteration sent a selector and one `f64` through
`/yon_stream_Bank` and waited for one `f64` back; `audit_key` was never on
the wire (`internal`); the totals accumulated through a promoted cell
(the `=` assignment); the conversion came from a git-pinned dependency under its
`rates::` prefix; and when the program exited, the server it had spawned
went down with it.

Three packages, two kinds of boundary, git for code, the kernel for
processes, and the type checker policing both ends.
