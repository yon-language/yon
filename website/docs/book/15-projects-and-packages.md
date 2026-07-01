---
id: projects-and-packages
title: "15. Projects, yon.toml, and packages"
sidebar_position: 15
---

# Projects, yon.toml, and packages

## A project is a directory

There is no `src/` convention and no project file beyond the manifest: a
**package is a directory**, and every `.yon` file in it shares one scope. The
entrypoint is an `Entry.yon` at the project root holding `place Entry { fun
main() … }` (a place file's name is its place, so the entry place lives in
`Entry.yon`); a package with one is an executable, a package without one is a
library, a convention, not a flag. `internal` declarations stay invisible
outside the package either way.

```
example/
├── yon.toml
├── Entry.yon           # place Entry { fun main() { ... } }, the entrypoint
├── geometry.yon        # bare functions, same scope as Entry.yon, no import needed
└── yon_modules/        # dependencies land here (never edited by hand)
```

You compile the *directory*:

```bash
$ yonc example/ -o example
```

`yonc` walks every `.yon` in it (skipping `yon_modules/`, which is pulled in
only via imports) and builds one program.

## The manifest

`yon.toml` declares identity, the runtime backend, and dependencies.
Dependencies are **git repositories**, no central registry, no hosting
to trust:

```toml
[package]
name = "example"
version = "0.1.0"

[runtime]
backend = "memory"     # required: memory | separate | shm

[dependencies]
geometria = { git = "https://github.com/utente/geometria", version = "1.0" }
algebra   = { git = "https://github.com/altro/algebra", rev = "abc123" }
```

The `[runtime]` section is required in project mode: `backend` decides
how Space heaps are physically backed (chapter 16), and a missing or
invalid key is a compile error. The declared value is the binary's
default; a `YON_BACKEND` environment variable at launch overrides it.

`version` is a git tag (`v1.0` or `1.0`); `rev` pins a commit or branch
explicitly. The workflow is `yon-pkg`:

```bash
$ yon-pkg init example      # writes a fresh yon.toml
$ yon-pkg install           # clones deps into yon_modules/, writes yon.lock
$ yon-pkg list              # shows what's declared
$ yon-pkg update            # re-resolves versions
```

`yon.lock` records the exact dependency commits for reproducibility, it is
generated, never edited.

## Importing

`import "spec"` brings a package (a directory) into scope. Two forms:

- `import "./sub"`, relative to the importing file;
- `import "host/user/repo"`, a git dependency; the **last segment** is
  looked up in `./yon_modules/<repo>`.

Imports load transitively (with a cycle guard), and every top-level
declaration of an imported module arrives **prefixed with its module name**:

```yon
// Entry.yon
import "github.com/utente/geometria"

place Entry {
  fun main(): number {
    return area(6, 5) + geometria::circle_area(2)    // 30 + 12 = 42
  }
}
```

Here `area` is a bare `fun` in a sibling root file (`geometry.yon`), reached
directly because the package shares one scope; `geometria::circle_area` comes
from the dependency, reached through its `repo::` prefix. Local files share
the bare namespace; dependencies are always reached as `repo::name`, so
collisions are impossible by construction. (This whole chapter is a verified
walkthrough: the project above, with `geometria` installed into
`yon_modules/`, compiles as a directory and exits 42.)
