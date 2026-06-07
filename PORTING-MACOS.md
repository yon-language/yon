# Yon on macOS — porting rationale and troubleshooting

**For the operational walkthrough follow INSTRUCTIONS.md (authoritative):
this document is the rationale behind the choices, plus troubleshooting.**

Status: the full suite is green on Apple Silicon with the self-contained runtime (first brought up 2026-06-04 at 112 examples; last verified 2026-06-07 at 126). Regression 112/112
identical to the baseline + cross-Space 2/2. Every fix mentioned below
already lives in the sources; the only manual step left is the
install_name surgery (INSTRUCTIONS.md §1b).

## The critical dependency: mmgroup — superseded by vendoring (2026-06-07)

The section below predates the vendoring and is kept for the record.
The mmgroup mathematical
core is now vendored under `runtime/vendor/mmgroup` and built by the
runtime Makefile: no Python, no wheel, no install_name surgery, no
rpath. The macOS port needs only: Xcode CLT, Homebrew
(`opam cmake ninja llvm@18 coreutils`), and the standard build. The
original analysis is kept for the record.

### (historical) The critical dependency: mmgroup

The runtime links `libmmgroup_mat24` and `libmmgroup_mm_op` from the
Python `mmgroup` package (BSD-2-Clause). The arm64 wheel ships both the
native libraries and the `dev/headers` — verify both before anything
else; if headers are missing, build from source
(`pip install mmgroup --no-binary :all:`, requires cython).

### The wheel's install_name defect

The macOS wheel's `.so` files carry the GitHub CI runner's absolute
path (`/Users/runner/work/...`) baked in as their install_name. A
Mach-O executable records that name at link time, and dyld looks it up
at run time — so every Yon binary aborts with
`dyld: Library not loaded: /Users/runner/...` until the libraries are
re-stamped with `@rpath`-relative names and ad-hoc re-signed (Apple
Silicon requires valid signatures after modification). The exact
commands are in INSTRUCTIONS.md §1b. For official packaging this repair
should be automated, or reported upstream to mmgroup.

## Darwin differences handled in the sources

- **BSD APIs under strict `-std=c11`**: Darwin hides `flock`,
  `LOCK_EX`, `MAP_ANON*` in strict ISO mode. Fixed with
  `-D_DARWIN_C_SOURCE` in the Makefile (a no-op on Linux) plus a
  `MAP_ANONYMOUS → MAP_ANON` shim.
- **`-no-pie`**: required on Linux (non-PIC runtime), rejected by the
  Apple linker. `yonc` omits it on Darwin, where PIE is the correct
  default.
- **Library naming**: the Apple linker resolves `-lfoo` to
  `.dylib/.tbd/.a`, never `.so`. `yonc` and the regression harness link
  the mmgroup `.so` files by explicit path — identical behavior on both
  platforms, no symlinks.
- **shm name limit (PSHMNAMLEN = 31, slash included)**: the RPC2 reply
  channel name used to be 32 characters and silently failed with
  ENAMETOOLONG; it is now `/yr_%.10s_%012llx` (max 27). The name is
  only a unique rendezvous — request/reply correlation uses the full
  64-bit nonce inside the payload, so no guarantee was lost. Residual
  documented limit: a QUEUE name (`/yon_stream_` + Space name) can
  still exceed 31 chars for Space names beyond ~15 characters; the
  failure is explicit.
- **CMake `LANGUAGES C`**: Homebrew's LLVMConfig runs a C-language
  header check (`FindLibEdit`); the project enables C alongside CXX so
  `try_compile` works. "Could NOT find LibEdit" in the configure output
  is harmless — it is optional and unused.
- **`timeout`**: not shipped with macOS; provided by `coreutils`
  (gnubin on the PATH).

## What did NOT need changing

`fork`/`execl` spawning, the constructor-based argv capture (dyld
passes argc/argv to constructors), `clock_gettime`, `flock` semantics,
process-shared pthread mutexes/condvars in shared memory, and the f64
bit patterns (arm64 is little-endian like x86-64: hashes and handles
are identical across platforms).

## The acceptance criterion

The regression, identical to Linux — exit codes are mod 256 and
portable by construction. Benchmark constants will differ on Apple
Silicon; the SHAPES must not (flat equality, exact sizes, zero
collisions).
