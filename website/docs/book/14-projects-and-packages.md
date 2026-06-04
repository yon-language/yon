---
id: projects-and-packages
title: "14. Projects, yon.toml, and packages"
sidebar_position: 14
---

# Projects, yon.toml, and packages

## A project is a directory

There is no `src/` convention and no project file beyond the manifest: a
**package is a directory**, and every `.yon` file in it shares one scope. If
a `main` is present, the package is an executable; if not, it is a library —
a convention, not a flag. `internal` declarations stay invisible outside the
package either way.

```
example/
├── yon.toml
├── main.yon
├── geometry.yon        # same scope as main.yon, no import needed
└── yon_modules/        # dependencies land here (never edited by hand)
```

You compile the *directory*:

```bash
$ yonc example/ -o example
```

`yonc` walks every `.yon` in it (skipping `yon_modules/`, which is pulled in
only via imports) and builds one program.

## The manifest

`yon.toml` declares identity and dependencies. Dependencies are **git
repositories** — no central registry, no hosting to trust:

```toml
[package]
name = "example"
version = "0.1.0"

[dependencies]
geometria = { git = "https://github.com/utente/geometria", version = "1.0" }
algebra   = { git = "https://github.com/altro/algebra", rev = "abc123" }
```

`version` is a git tag (`v1.0` or `1.0`); `rev` pins a commit or branch
explicitly. The workflow is `yon-pkg`:

```bash
$ yon-pkg init example      # writes a fresh yon.toml
$ yon-pkg install           # clones deps into yon_modules/, writes yon.lock
$ yon-pkg list              # shows what's declared
$ yon-pkg update            # re-resolves versions
```

`yon.lock` records the exact dependency commits for reproducibility — it is
generated, never edited.

## Importing

`import "spec"` brings a package (a directory) into scope. Two forms:

- `import "./sub"` — relative to the importing file;
- `import "host/user/repo"` — a git dependency; the **last segment** is
  looked up in `./yon_modules/<repo>`.

Imports load transitively (with a cycle guard), and every top-level
declaration of an imported module arrives **prefixed with its module name**:

```yon
import "github.com/utente/geometria"

fun main(): number {
  return area(6, 5) + geometria::circle_area(2)    // 30 + 12 = 42
}
```

Local files share the bare namespace; dependencies are always reached as
`repo::name` — collisions are impossible by construction. (This whole
chapter is a verified walkthrough: the project above, with `geometria`
installed from a git repository by `yon-pkg install`, compiles as a
directory and exits 42.)
