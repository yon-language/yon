---
id: how-spaces-talk
title: "16. How Spaces talk"
sidebar_position: 16
---

# How Spaces talk

Chapter 10 showed the surface: `import mid::addtriple from Mid`, and a call
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

## Crossing by value: the DTO wire

The numeric door above carries a *call*. A second path carries *data*. When a
producer Space exports a `stream of <Place>` and a consumer subscribes to it,
the values themselves cross, not handles to them. The model is a **wormhole**:
a value is copied out of the producer, flattened to bytes, sent, and rebuilt in
the consumer's own heap. Nothing is shared after transit; the two processes
keep no common reference, so there is no cross-process lifetime to manage.

What makes this safe is the split between `emit` and serialization, which sit
at different levels:

- `emit` deposits a **section id**, an `f64` handle, into the local stream and
  knows nothing about bytes or frame boundaries. It is the same `emit` used
  within a process.
- **Serialization is a runtime boundary service.** Only the wire pump on the
  producer side and the drain on the consumer side ever call
  `yon_rt_serialize` / `yon_rt_deserialize`, and only at the instant a value is
  about to leave or has just arrived. The language never names it.

A frame is **variable length**. The producer serializes the section into a
dense **64&nbsp;KB byte ring** (`YON_WIRE_RING_BYTES`, fixed in the runtime,
not a configuration knob); the consumer awaits one whole frame and
deserializes it. A value that would not fit the ring makes the pump **fail
loudly** rather than truncate, the same discipline as every other hard limit in
this language.

What crosses, recursively:

- **scalars** (`number`, `money`, durations) as their `f64`;
- **strings**, length-prefixed, re-interned into the consumer's `String` place
  on arrival, so a string that left as one slot arrives as one slot again;
- **nested places**: a field that is itself a transportable place becomes a
  **sub-frame** with its own schema id, serialized inline and rebuilt by a
  recursive descent, so a chain like `o.inner.b` survives the crossing intact.

Each place that travels registers a small **schema**, its field tags and a
content-derived schema id, so the consumer can reconstruct the right shape.
The registry is bounded (256 schemas, 64 fields each), and a missing or
mismatched schema is an error, never a silent mis-read.

In the language this is the subscription pipeline:

```
import forecasts from Weather

fun main(): number {
  be w holds wire to Weather
  be sub holds w.awaits(forecasts)        // forecasts: fun(): stream of Reading
  be total holds sub.stream.fold(0, sum_reading)
  return total
}
```

`forecasts` runs inside the Weather Space and emits `Reading` values; `sub.stream`
is the consumer's local view of them, folded on its own heap. The two Spaces
never share a cell: each `Reading` is a copy that lives in the consumer's heap,
strings and nested places and all.

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

Two doors, two disciplines. The **call** door, `__yon_dispatch`, moves `f64`
and nothing else: a selector plus at most four numeric arguments. A string or a
bare section cannot ride it, since it would be a handle into a heap the callee
does not have (chapter 12), and the type checker rejects it in an imported
*function signature* before you ever run. The **subscription** door, just
above, is the one that carries values, and it carries them by **copy**, never
by handle: a value is serialized on the way out and rebuilt on the far side.

So the underlying rule is uniform, and it is the rule the whole book keeps
returning to: no process ever dereferences another process's heap. Either a
datum is a number small enough to be its own meaning, or it is flattened to
bytes and reconstructed in the receiver's heap. The narrow door stays narrow;
the wide door copies. This is the same hermeticity ladder as everywhere else:
*inside* a binary it is typed (TOPOS-E1110 and friends); *between* binaries it
is the kernel's process isolation. `internal` functions are on neither door.

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
