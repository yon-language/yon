---
id: how-spaces-talk
title: "16. How Spaces talk"
sidebar_position: 16
---

# How Spaces talk

Chapter 9 showed the surface: `import mid::addtriple from Mid`, and a call
crosses a process boundary. This chapter is the machinery underneath, all
of it verified against the runtime sources.

## The server is the same binary

There is no separate server build. Every compiled package exports one extra
symbol:

```c
double __yon_dispatch(double selector, double a1, double a2,
                      double a3, double a4);
```

, a switch over the package's **public** (non-`internal`) number functions,
arity 0 to 4 (lower-arity functions simply ignore the extra slots). At
startup, an ELF constructor stashes `argc/argv` before `main` even runs, so
the binary can ask *"was I launched as a server?"* and enter the serve loop
instead of `main`. The runtime owns that loop; the compiled code only
provides the dispatch table. `internal` functions are not in the switch:
from outside the package they do not exist.

## Spawn and discovery

The first call toward Space `S` forks and launches `./S_srv`, by
convention, the server binary sits next to the caller; `YON_SRV_DIR`
overrides the directory. Shutdown cascades from the caller; nothing
outlives the conversation.

## The channel

In the language this transport is the `Wire` family: `Wire.make` /
`Wire.send` / `Wire.recv` within one process, the `_shm` variants
across processes, the `_net` variants across machines. `Stream` is the
sequence (map, filter, fold); `Wire` is how Spaces talk.

Transport is a POSIX shared-memory region named `/yon_stream_<Space>`,
designed to be **position-independent**: a fixed header followed by a ring
buffer, all fields plain integers and offsets, no pointers, so every
process can map it wherever it likes. The header carries:

- a `magic` sentinel (`"STRE"`), *published last* during the `O_EXCL`
  creation race, so attachers never see a half-initialized region;
- `slot_size`, `capacity`, `head`, `tail`, `count`, the ring;
- `closed`, a clean-EOF flag from the producer;
- `producers`, a live attach count, used for fault detection.

Cross-process `emit`/`await` are serialized with an exclusive `flock`; the
RPC session adds a `PROCESS_SHARED` mutex with `nonempty`/`nonfull`
condition variables, so a slow consumer exerts **back-pressure** instead of
dropping frames.

## Epochs, liveness, recovery

Freshness is an **epoch**: recreating a channel means unlink + recreate
with the epoch advanced, so a stale peer can never talk to the new
incarnation by accident. Liveness is checked the Unix way, 
`kill(pid, 0)`/`ESRCH` against the recorded server pid. When a server has
crashed, the caller gets a **virgin channel**, the epoch advances, and the
call is retried once, transparently: the program never sees the death.
Sessions deliberately do **not** survive `fork()`, a child re-handshakes
on first contact rather than inheriting its parent's reply slot.

## The discipline of the wire

Everything above moves `f64` and nothing else: a selector plus at most
four numeric arguments per call. Strings and sections never cross, they
are handles into a heap the other process does not have (chapter 11), and
the type checker rejects them in imported signatures before you ever run.
This is the same hermeticity ladder throughout: *inside* a binary it is
typed (TOPOS-E1110 and friends); *between* binaries it is the kernel's
process isolation; the narrow numeric wire is the only door, and
`internal` is not on it.

## What about threads?

There is no `thread`, no `spawn`, no intra-process concurrency primitive in
1.0, by design, not omission. Shared-memory threading would puncture every
guarantee this book has described: hermetic Spaces, the no-aliasing value
model, cells as the *only* identity. Yon's unit of concurrency is the
**process**: Spaces in separate binaries, the numeric wire between them,
shared-memory cells with `flock` and convergent folds where state must
really be shared (chapter 13). `for every … when here` declares parallel
*intent* at the surface, 1.0 executes it sequentially, and any future
parallel execution will be process-shaped, not thread-shaped.

## Choosing a runtime backend

The backend selects how Space heaps are backed within one machine. A
project declares it in `yon.toml`, and the key is required in project
mode:

```toml
[runtime]
backend = "memory"     # or: separate | shm
```

`yonc` bakes the declared value into the binary as its default; a
`YON_BACKEND` environment variable at launch still overrides it, as a
deployment lever. The values:
`memory` (the default, one private heap), `separate` (one heap per Space),
`shm` (heaps in POSIX shared memory, `/yon_space_<name>`, enabling the
cross-process cells and convergent shared folds of chapter 13). The
language semantics do not change across backends; only the physical
residence of the content does.
