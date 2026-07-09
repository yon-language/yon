# Yon — honest use-case matrix

> Written 2026-07-09. One row per domain in the grid. Every "Yon REAL lever" cell
> is anchored to a file:line or a named test that was **grepped and verified to
> exist** in this repo on this date. Where Yon has no credible lever, the cell is
> `—` and the row says so.
>
> **Two labels, on every row:**
> - **REAL** = a property of the *core* that is *already tested*. The lever is real
>   today; you can run it. (This does **not** mean a finished product exists.)
> - **ASPIRATIONAL** = a *product* that would be *built on top* of the core. The
>   lever underneath may be real, but the domain artifact (a VM, a DB engine, an
>   orchestrator, a web stack) does not exist and would have to be written.
>
> **Anti-hype guardrail (load-bearing):** Yon is **not** a complete proof
> assistant. Strong Normalization is argued (SCT), **not** machine-checked. Cubical
> canonicity is **partial**: the fuzzer's ~490 "stuck" terms are neutral normal
> forms over *free* dimensions (correct behaviour), not a gap — closed-instance
> canonicity holds and is probed. See `docs/metatheory-internal/trusted-kernel.md:92-95`
> and `frontend/test_o2_probe.ml`. For anything proof/verification-shaped the honest
> framing is: **"dependent core + a sound, tested cubical layer — NOT a complete
> proof assistant."**

---

## Verified lever inventory (the anchors every row draws on)

These were grepped live on 2026-07-09; each is a REAL/TESTED property of the core.

| # | Lever (REAL/TESTED) | Anchor (grepped) |
|---|---|---|
| L1 | Content-addressed heap; dedup **by construction** (identical content → same ref) | `runtime/yon_rt.c:352-375` (`yon_xheap_put` dedup via content_index); test `runtime/test_unit_extensionality.c:54` — 300k distinct contents past Leech kissing number 196 560, all distinct refs, dedup stable |
| L2 | Space isolation, **no data races** (MMU-isolated processes; typed wire only) | `runtime/yon_rt.c:1382,1462-1466` (`PROCESS_SHARED` mutex, Bug B fix); test `runtime/test_unit_wire_race.c:63` — exact delivery/sum under cross-process contention |
| L3 | **No-GC** region reclaim (death-watch: reap when static input arcs close) | `runtime/yon_rt.c:81-88,293-320`; test `runtime/test_unit_deathwatch.c:104` (`DEATHWATCH: PASS`) |
| L4 | First-order **dependent types**, computed codomain `El(Fam x)` | `frontend/el_normalize.ml`, `frontend/carrier.ml:149`; gates `regression/test_dependent_carrier.py`, `regression/test_boxed_el_carrier.py` |
| L5 | **Kernel re-checks the elaborator** (`core_wf` gate over the dependent fragment) | `frontend/core_wf.ml`, `frontend/core_check.ml`; gates `regression/test_core_wf_gate.py`, `regression/test_core_wf.py` |
| L6 | **Sound** cubical layer: `ua`/Glue require a genuine equivalence; transport computes | `frontend/test_isequiv.ml`, `frontend/test_glue.ml`, `frontend/test_path.ml`; runnable `examples/cx_univalence_succ.yon` (`transport(ua(succ≃pred),10)` → 11), `examples/circle_hit.yon` (S¹ recursor → 42) |
| L7 | **Precise path typing** (concat/inv endpoints; non-composable concat is a clean type error) | `frontend/test_path_typing.ml` (inv/concat/refl endpoints, Task 0-A) |
| L8 | Closed-instance cubical **canonicity probe** (boundary laws + 8000/8000 corners) | `frontend/test_o2_probe.ml`; `docs/metatheory-internal/trusted-kernel.md:92-95`, `CONFORMANCE.md:58` |
| L9 | **Declared effects** (`visits`, caller-covers-callee, compile-time) | `examples/effect_propagation.yon` (`unit visits Output`) |
| L10 | **Intuitionistic** 3-valued Heyting logic (no excluded middle; `HUnknown`) | `frontend/prop_eval.ml`, `frontend/test_prop_eval.ml` (`HPresent/HAbsent/HUnknown`) |
| L11 | Typed **cross-Space IPC** (wire over shm, structural EOF) | `examples/wire_eof.yon`; gates `regression/test_wire_throughput.py`, `regression/test_cross_space_runtime.py` |
| L12 | **Native** compile path (OCaml → MLIR `topos` → LLVM → native) + self-host gate | `frontend/emit_mlir.ml`, `toolchain/yonc`; gate `regression/test_yon_selfhost.py` |

---

## The matrix

Columns: **Category | Use Case | Typical languages | Why that language | Yon REAL lever (anchor) | REAL / ASPIRATIONAL**

| Category | Use Case | Typical languages | Why that language | Yon REAL lever (file:line / test) | Label |
|---|---|---|---|---|---|
| Operating Systems | Kernel | C, Rust, Zig, asm | No-runtime, direct hardware/memory control, deterministic | `—` (Yon needs its C runtime `yon_rt.c`; no bare-metal target, no interrupt/MMU-programming surface). Only tangential: no-GC reclaim `runtime/test_unit_deathwatch.c:104` | ASPIRATIONAL (weak — no lever) |
| Blockchain | Smart contract | Solidity, Rust, Move | Determinism, gas metering, formal-verification of invariants | Dependent core + kernel re-check `frontend/core_wf.ml` (+ `test_core_wf_gate.py`); intuitionistic props `frontend/test_prop_eval.ml` — invariants as *types*. **No VM, no gas model, no chain.** | ASPIRATIONAL (real lever, product absent) |
| Web | Frontend | JS/TS, Elm, Dart | DOM/browser APIs, hot reload, huge component ecosystem | `—` (no DOM binding, no JS/wasm-DOM backend, no UI runtime) | ASPIRATIONAL (weak — no lever) |
| Web | Backend | Go, Java, TS, Python | Concurrency, HTTP/DB libs, ops maturity | Space isolation + typed wire `runtime/test_unit_wire_race.c:63`, `examples/wire_eof.yon` — race-free request workers *in principle*. **No HTTP server, no sockets surfaced.** | ASPIRATIONAL (lever real, no I/O stack) |
| Database | DBMS | C++, Rust, Java | Storage engines, buffer/txn control, query planners | **Content-addressing = identity** `runtime/yon_rt.c:352-375` + `test_unit_extensionality.c:54` (dedup by construction, 300k contents). Strongest structural fit; Merkle/dedup storage is *the* native primitive. **No query engine / txn / persistence layer yet.** | ASPIRATIONAL (strongest lever; product to build) |
| Networking | Server | C, Rust, Go | epoll/io_uring, zero-copy, backpressure | Typed cross-Space wire `regression/test_wire_throughput.py`, `test_cross_space_runtime.py`; race-free by construction `test_unit_wire_race.c`. **No OS sockets / async I/O surface.** | ASPIRATIONAL (concurrency lever real; no netstack) |
| Networking | Protocol | C, Rust, P4, TLA+ | Bit-precise framing; state-machine correctness | Dependent types for message shapes `frontend/test_dependent_carrier.py` (`El(Fam x)`); intuitionistic state props `test_prop_eval.ml`. **No parser/serializer library.** | ASPIRATIONAL (typing lever real) |
| Embedded | Firmware | C, Rust, Ada | Tiny footprint, no allocator/GC, real-time | No-GC region reclaim `runtime/test_unit_deathwatch.c:104` conceptually fits "never free / no collector". **But the C runtime + LLVM target isn't a bare-metal/MCU profile; no HAL.** | ASPIRATIONAL (no-GC lever real; no MCU target) |
| Data Science | ML | Python, Julia | Autodiff, GPU/BLAS, notebook ecosystem | `—` (no tensors, no GPU, no autodiff, no numeric libs; `number` is scalar f64) | ASPIRATIONAL (weak — no lever) |
| Data Science | Pipeline | Python, Scala, SQL | Dataflow, dedup/joins, reproducibility | Content-addressed dedup `test_unit_extensionality.c:54`; typed streams `examples/wire_eof.yon` (`produce`/`for every`, structural EOF); declared effects `examples/effect_propagation.yon`. **Reproducible-by-content is a genuine fit; no connectors.** | ASPIRATIONAL (dedup + stream lever real) |
| Compilers | Compiler | OCaml, Rust, C++, Haskell | ADTs/pattern-match, perf, self-hosting | Yon **is** a native compiler and passes a **self-host** gate `regression/test_yon_selfhost.py`; native path `frontend/emit_mlir.ml`. Writing *new* compilers *in* Yon lacks lexer/parser libs. | ASPIRATIONAL (Yon-as-compiler is real; Yon-for-compilers not) |
| Compilers | DSL | Racket, OCaml, Haskell | Macros, embedded grammars, typed hosts | `place`/`topos` categorical modelling is real (`frontend/desugar.ml`, `place_visibility.ml`); dependent codomains `El(Fam x)` `el_normalize.ml`. **No macro system / user-facing embedding API.** | ASPIRATIONAL (host-typing lever real; no macros) |
| Games | Engine | C++, Rust, C# | Frame-time control, ECS, GPU, tooling | `—` (no GPU, no windowing, no real-time scheduler, no asset pipeline) | ASPIRATIONAL (weak — no lever) |
| Graphics | Shaders | GLSL, HLSL, WGSL, Slang | SIMT execution, GPU pipeline binding | `—` (no GPU backend; MLIR path targets CPU/LLVM only) | ASPIRATIONAL (weak — no lever) |
| Security | Cryptography | C, Rust | Constant-time, side-channel control, bignum | `—` for primitives (no constant-time story, no bignum). Tangential: content-addressing uses a Merkle/hash spine `runtime/yon_rt.c:352-375` but it is **not** a crypto hash guarantee | ASPIRATIONAL (weak — no crypto lever) |
| Security | Formal Verification | Coq, Lean, Isabelle, TLA+, Dafny | Machine-checked proofs of program properties | **Dependent core + sound tested cubical layer** `frontend/core_wf.ml`, `test_isequiv.ml`, `test_path_typing.ml`, `test_o2_probe.ml` — **NOT a complete proof assistant**; SN not machine-checked; canonicity proof open. Real for *typed invariants*, not for arbitrary program proofs. | ASPIRATIONAL / partial (lever real, scope limited) |
| Distributed | Microservices | Go, Java, Rust, Erlang | Process isolation, message passing, supervision | **Space = MMU-isolated process, race-free by construction** `runtime/test_unit_wire_race.c:63`, `yon_rt.c:1382,1462-1466`; typed wire `test_cross_space_runtime.py`. Erlang-class isolation is *native*, tested. **No service mesh / discovery / RPC framing lib.** | ASPIRATIONAL (strong lever; product to build) |
| Distributed | Cluster | Go, C++, Erlang, Rust | Fault isolation, no shared-mutable-state, scale-out | Space isolation + **spawn scales ~linearly** (`regression/test_spawn_scaling.py`), death-watch reclaim `test_unit_deathwatch.c:104`, typed wire `test_wire_throughput.py`. Same strong isolation lever. **No multi-node transport.** | ASPIRATIONAL (strong lever; single-node only) |
| Scripting | Automation | Python, Bash, Ruby | Fast edit-run, glue libs, ubiquitous | Runs source directly via `toolchain/yonc` (native, no VM). **But effects reach only declared sinks (`visits Output`); no filesystem/process/env stdlib.** | ASPIRATIONAL (weak — no OS glue) |
| Scripting | CLI | Go, Rust, Python | Single static binary, argparse, fast start | Native single binary `frontend/emit_mlir.ml` → LLVM; declared effects `examples/effect_propagation.yon`. **No argv/stdin/stdout stdlib beyond `Output.print`.** | ASPIRATIONAL (native-binary lever real; no CLI stdlib) |
| Education | Teaching | Python, Scheme, Racket | Small core, clear semantics, immediate feedback | **Runnable, honest core semantics today**: dependent types `test_dependent_carrier.py`, effects `examples/effect_propagation.yon`, intuitionistic logic `test_prop_eval.ml`, content-addressing `test_unit_extensionality.c`. The concepts *are* the artifact — you teach them by running them. | **REAL** (with the caveat: niche, steep, no tutorials) |
| Education | Research | Agda, Coq, Lean, Racket | Novel type theories, executable semantics | **Executable topos/cubical experiments today**: `examples/cx_univalence_succ.yon` (univalence computes), `examples/circle_hit.yon` (HIT recursor), `test_isequiv.ml`, `test_glue.ml`, `test_o2_probe.ml`, `docs/metatheory-internal/`. A genuine research vehicle for content-addressing-as-identity, Space isolation, cubical-on-native. | **REAL** (research-grade, partial cubical) |
| Finance | Trading | C++, Rust, Java, kdb+ | Ultra-low latency, determinism, decimal money | `money` is a **first-class primitive type** `frontend/carrier.ml:83`; determinism + no-GC `test_unit_deathwatch.c:104`. **But `money` is just an f64 carrier today — no decimal/fixed-point semantics; no market I/O.** | ASPIRATIONAL (typed-money lever thin) |
| AI | Neural Networks | Python, C++/CUDA | Autodiff, GPU kernels, tensor libs | `—` (no tensors, no autodiff, no GPU) | ASPIRATIONAL (weak — no lever) |
| AI | Symbolic AI | Prolog, Lisp, Datalog | Terms/unification, rules, structural equality | **Structural equality is free** via content-addressing `runtime/yon_rt.c:352-375` (identical terms → same ref); intuitionistic 3-valued logic `test_prop_eval.ml`; dependent terms `el_normalize.ml`. Hash-consed terms + open-world logic are a real fit. **No unifier / rule engine.** | ASPIRATIONAL (hash-consing + logic lever real) |
| Hardware | HDL | Verilog, VHDL, Chisel, Bluespec | Cycle/bit semantics, synthesis to gates | `—` (no synthesis backend, no bit-timing model, no register/wire semantics) | ASPIRATIONAL (weak — no lever) |
| Mathematics | Proof Assistant | Coq, Lean, Agda, Isabelle | Machine-checked proofs, tactic ecosystem, large libs | **Dependent core + sound tested cubical layer** — `frontend/core_wf.ml`, `test_isequiv.ml`, `test_path_typing.ml`, `examples/cx_univalence_succ.yon`, `test_o2_probe.ml`. **Explicitly NOT a complete proof assistant**: first-order surface dependents, no tactics, no library, SN not machine-checked, canonicity proof open. | ASPIRATIONAL / partial (honest hard cap) |
| Mathematics | Simulations | Fortran, C++, Julia, Python | Fast float/array math, ODE/PDE solvers | `—` for numerics (scalar f64 only, no arrays/BLAS). Only "simulation" that runs today is **executable type theory** (see Education/Research), not physical simulation. | ASPIRATIONAL (weak — no numeric lever) |

---

## Tally

- **28 rows.**
- **REAL (addressable today with the tested core): 2** — *Education/Teaching* and *Education/Research*. These are the only rows where the tested artifact **is** the use case: you run `cx_univalence_succ.yon`, `circle_hit.yon`, the dependent/effect/logic examples, and that is the deliverable.
- **ASPIRATIONAL: 26.** Of these, the levers split three ways:
  - **Strong, real lever — product just needs building (4):** Database/DBMS, Data-Science/Pipeline (content-addressing L1); Distributed/Microservices, Distributed/Cluster (Space isolation L2/L3, spawn scaling).
  - **Real-but-narrow lever (8):** Blockchain, Web/Backend, Networking/Server, Networking/Protocol, Compilers/Compiler, Compilers/DSL, Security/Formal-Verification, Symbolic-AI, Finance/Trading, Embedded/Firmware, Scripting/CLI. (The lever exists and is tested, but the domain needs a substantial stack — VM, netstack, HAL, macros, tactics — on top.)
  - **No credible lever (the `—` rows, ~6):** OS/Kernel, Web/Frontend, DS/ML, Games/Engine, Graphics/Shaders, Security/Cryptography, AI/Neural-Networks, Hardware/HDL, Mathematics/Simulations. Said plainly rather than inflated.

---

## Where Yon is credible TODAY vs where you'd need to build on top

**Credible today (levers are strongest, tested, and *are* the artifact):**

1. **Teaching & research of type theory / topos / cubical.** This is the one place the
   grep-verified artifacts are the product itself. Univalence that *computes*
   (`examples/cx_univalence_succ.yon` → 11), a HIT recursor (`examples/circle_hit.yon`
   → 42), precise path typing (`test_path_typing.ml`), the O2 canonicity probe
   (`test_o2_probe.ml`), all running natively. No product layer required.

2. **Content-addressed storage / dedup (a DB or object-store *primitive*).** L1 is the
   heart of the runtime, not a bolt-on: `runtime/yon_rt.c:352-375` + 300k-content
   dedup test `test_unit_extensionality.c:54`. Identity-by-content is *already true*.
   You still have to write the query/txn/persistence engine — but the hard primitive
   is done and tested.

3. **Race-free process isolation (distributed / Space concurrency).** L2/L3: MMU-isolated
   Spaces, cross-process wire serialized by a `PROCESS_SHARED` mutex (Bug B),
   proven by `test_unit_wire_race.c` under contention; region reclaim without a GC
   (`test_unit_deathwatch.c`); spawn scales ~linearly (`test_spawn_scaling.py`).
   Erlang-class isolation, native and tested — the orchestration layer is what's missing.

**Everything else is aspirational.** For OS/kernel, GPU/ML/graphics/games,
cryptography, HDL, and numeric simulation, Yon has **no credible lever** and the
honest answer is a dash. For blockchain, web, networking, compilers-in-Yon, formal
verification, symbolic-AI, embedded and CLI, a **real tested lever exists** but the
usable product is a substantial library/runtime that has **not** been written.

**Two hard caps to keep repeating, because they're the ones people inflate:**
- Yon is **not a complete proof assistant** — first-order surface dependents, no
  tactics/library, SN argued not machine-checked, cubical canonicity partial
  (closed-instance holds and is probed; the mechanized proof is open).
  `docs/metatheory-internal/trusted-kernel.md:92-95`, `frontend/test_o2_probe.ml`.
- Yon has **no I/O, OS, GPU, or numeric stack** today. Effects reach declared sinks
  only (`visits`); there are no sockets, filesystem, tensors, or arrays. That single
  gap is why so many otherwise-plausible rows are aspirational rather than real.
