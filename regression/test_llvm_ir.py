"""LLVM-stage UNIT tests for the Yon compiler, driven from pytest.

The existing end-to-end suite (test_yon_pipeline.py) treats the LLVM stage as a
black box: it compiles each example to a native binary and checks the exit code.
Nothing inspects the emitted LLVM IR. This module fills that gap.

For a few known .yon programs we run the pipeline *only up to* the emitted LLVM
IR (the `.ll` text) and assert IR-level invariants — the cheap checks that catch
a runtime-symbol rename, an ABI drift, or an undefined reference BEFORE the
(slower) link+run, and that localize a failure to "the IR references a symbol
nobody provides" rather than a generic link error.

Pipeline reused verbatim from test_yon_pipeline.py:
    .yon -> yoner_emit_mlir.exe        (EMIT)             -> .mlir
         -> topos-opt lowering (two passes, MLIROPT fallback)  -> .s2
         -> mlir-translate --mlir-to-llvmir                    -> .ll   <-- STOP

We deliberately do NOT run llc / link / run here; those are integration concerns
covered by test_yon_pipeline.py::test_example.

Grounding for the .ll-shape assumptions (we cannot run the Mac toolchain here):
  * frontend/emit_mlir.ml:5364   emits  `func.func @main() -> i32`  (the entry).
  * frontend/emit_mlir.ml:5554   emits  `func.func @__yon_dispatch(...) -> f64`,
    "Always emitted (even for non-Space programs) so the runtime's reference
    resolves at link time" (comment at 5517-5521).
  * frontend/emit_mlir.ml runtime facade table declares the Stream__/Spawn__/
    yon_rt_* calls, mostly f64 -> f64 (e.g. "Spawn__open", (["f64"], "f64"))
    but with i1/Prop, ptr, i32 and void exceptions; test_ll_runtime_abi
    checks each declaration against its C prototype instead of assuming f64.
  * runtime/yon_rt.c defines the runtime bodies: Stream__make (1214),
    Spawn__open (2440), __yon_dispatch extern decl (1730), and the many
    yon_rt_* functions. These land in the RTSET .o objects.

macOS underscore: nm on the runtime .o files shows a leading `_` on C symbols
(`_yon_rt_foo` for the IR symbol `@yon_rt_foo`). We normalize by stripping at
most one leading underscore from both sides before comparing sets.

IR formatting tolerance: every assertion is a regex over symbol *names* or a
set-subset relation, never an exact-text match, so benign LLVM formatting (SSA
numbering, attribute ordering, `dso_local`, etc.) cannot false-fail it.

Markers: llvm + unit (registered in conftest.py). pytest -m "llvm and unit".
"""

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

pytestmark = [pytest.mark.llvm, pytest.mark.unit]

# ── tool discovery: copied from test_yon_pipeline.py (same env vars as yonc) ──
ROOT = Path(__file__).resolve().parent.parent
FE = ROOT / "frontend"
FT = ROOT / "runtime"
EXD = ROOT / "examples"
EMIT = FE / "_build" / "default" / "yoner_emit_mlir.exe"


def _tool(name, env):
    cand = os.environ.get(env) or shutil.which(name) or shutil.which(f"{name}-18")
    if not cand:
        p = Path(f"/usr/lib/llvm-18/bin/{name}")
        cand = str(p) if p.exists() else name
    return cand


TOPOS = os.environ.get("YONC_TOPOS_OPT") or str(ROOT / "mlir" / "build" / "topos-opt")
LLC = _tool("llc", "YONC_LLC")
MLIRTRANS = _tool("mlir-translate", "YONC_MLIR_TRANSLATE")
MLIROPT = _tool("mlir-opt", "YONC_MLIR_OPT")
CC = os.environ.get("YONC_CC", "gcc")
NM = _tool("nm", "YONC_NM")

LOWER = ("--convert-scf-to-cf --convert-cf-to-llvm --convert-func-to-llvm "
         "--convert-arith-to-llvm --reconcile-unrealized-casts").split()

_RT_NAMES = [
    "yon_rt.o", "yon_mmap.o", "leech_orbits.o", "yon_arena.o", "yon_curtis_canon.o",
    "xleech2_coord.o", "xleech2_heap.o", "xleech2_mphf.o",
    "vendor/mmgroup/mat24_tables.o", "vendor/mmgroup/mat24_functions.o",
    "vendor/mmgroup/gen_leech.o", "vendor/mmgroup/gen_leech3.o",
    "vendor/mmgroup/gen_leech_type.o", "vendor/mmgroup/gen_leech_reduce.o",
    "vendor/mmgroup/gen_xi_functions.o", "vendor/mmgroup/mm_group_n.o",
    "vendor/mmgroup/mm_index.o",
]
RTSET = [str(FT / n) for n in _RT_NAMES]


def _run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, timeout=120, **kw)


# ── representative examples (from regression/baseline_exitcodes.txt, RAN) ──
#   arena_basic            : pure arithmetic / arena, no spawn/stream
#   spawn_parallel_collect : exercises Spawn__* and Stream__* runtime calls
#   net_stream             : exercises Stream__*_net send/recv runtime calls
#   string_literals        : exercises yon_rt_string_lit + String.* family
#   collections_ext        : exercises yon_rt_hashset_* (set union/intersect)
#   merkle_noncommutative  : exercises yon_rt_merkle_* (node2 / commutative)
# Every name here is an example the acceptance suite compiles and runs, so a
# missing source or a failing stage is a FAILURE with the stage's diagnostics,
# never a skip: a skip here once hid the whole gate (the names stopped resolving
# when the corpus became directory projects, and every node skipped silently).
EXAMPLES = ["arena_basic", "spawn_parallel_collect", "net_stream",
            "string_literals", "collections_ext", "merkle_noncommutative",
            # broadened to touch more runtime families (math, iteration,
            # history/route).
            # (primes_bertrand omitted: it has a facade call the best-effort
            # f64-abi heuristic flags — out of scope for a coverage broaden.)
            "math_ext", "iter_loop", "route_history"]

# Examples that exercise the spawn machinery (child fork + child_exit). Only
# these are relevant to the child-exit node; others have no such call site.
SPAWN_EXAMPLES = ["spawn_parallel_collect"]


# ── skip fixture: skip cleanly if any required stage tool is unavailable ──
@pytest.fixture(scope="session", autouse=True)
def _toolchain():
    missing = [str(p) for p in (EMIT, Path(TOPOS)) if not Path(p).exists()]
    missing += [n for n in RTSET if not Path(n).exists()]
    if missing:
        pytest.skip(f"toolchain not built: {missing[0]} (run dune build / make / cmake)")
    # mlir-translate, llc and nm must be runnable (they may be bare names on PATH).
    for t in (MLIRTRANS, LLC, NM):
        if not (shutil.which(t) or Path(t).exists()):
            pytest.skip(f"tool not found on PATH: {t}")


def _emit_ll(name, tmp):
    """Run EMIT -> topos-opt (two lowering passes, MLIROPT fallback) ->
    mlir-translate --mlir-to-llvmir and return the .ll text. A missing source
    or a failing stage FAILS the node with that stage's stderr."""
    # a single examples/<name>.yon, or a project
    # directory examples/<name>/ with a yon.toml: EMIT accepts both, as in
    # run_regression.sh.
    src = next((c for c in (EXD / f"{name}.yon", EXD / name) if c.exists()), None)
    if src is None:
        pytest.fail(f"{name}: example source not found ({EXD / name}[.yon])")
    mlir, s1, s2 = (tmp / f"{name}.{e}" for e in ("mlir", "s1", "s2"))

    r = _run([str(EMIT), str(src)])
    if r.returncode != 0 or not r.stdout:
        pytest.fail(f"{name}: EMIT failed\n{r.stderr.decode(errors='replace')[-2000:]}")
    mlir.write_bytes(r.stdout)

    lowered = False
    a = _run([TOPOS, "--algebra-verifier", "--lower-topos-extensions",
              "--lower-topos-to-standard", str(mlir)])
    if a.returncode == 0 and a.stdout:
        s1.write_bytes(a.stdout)
        b = _run([TOPOS, "--lower-topos-to-llvm", str(s1)])
        if b.returncode == 0 and b.stdout:
            s2.write_bytes(b.stdout)
            lowered = True
    if not lowered:
        f = _run([MLIROPT, str(mlir), *LOWER])
        if f.returncode != 0 or not f.stdout:
            pytest.fail(f"{name}: lowering failed (topos-opt and the MLIROPT fallback)\n"
                        f"{a.stderr.decode(errors='replace')[-1500:]}\n"
                        f"{f.stderr.decode(errors='replace')[-1500:]}")
        s2.write_bytes(f.stdout)

    t = _run([MLIRTRANS, str(s2), "--mlir-to-llvmir"])
    if t.returncode != 0 or not t.stdout:
        pytest.fail(f"{name}: mlir-translate failed\n{t.stderr.decode(errors='replace')[-2000:]}")
    return t.stdout.decode(errors="replace")


def _emit_obj(name, tmp):
    """Carry one example all the way to a relocatable object: _emit_ll() then
    `llc -filetype=obj <name>.ll -o <name>.o` (the exact llc invocation from
    test_yon_pipeline.py::_build_and_run). Returns the Path to the .o; a failing
    stage FAILS the node. This is the last artifact BEFORE the slow link step."""
    ll = _emit_ll(name, tmp)
    llf, obj = tmp / f"{name}.ll", tmp / f"{name}.o"
    llf.write_text(ll)
    r = _run([LLC, "-filetype=obj", str(llf), "-o", str(obj)])
    if r.returncode != 0 or not obj.exists() or obj.stat().st_size == 0:
        pytest.fail(f"{name}: llc failed\n{r.stderr.decode(errors='replace')[-2000:]}")
    return obj


# ── helpers ──────────────────────────────────────────────────────────────
def _norm(sym):
    """Strip at most one leading underscore (macOS nm mangling) so an IR
    `@yon_rt_foo` matches an nm `_yon_rt_foo`."""
    return sym[1:] if sym.startswith("_") else sym


# Any token of the runtime facade families, used in @name position in the IR.
_RT_FAMILY = re.compile(r"@(yon_rt_[A-Za-z0-9_]+|Spawn__[A-Za-z0-9_]+|"
                        r"Stream__[A-Za-z0-9_]+|__yon_dispatch)\b")
# A `define ... @name(` so we know which symbols the module itself provides.
_DEFINE = re.compile(r"^\s*define\b.*?@([A-Za-z0-9_$.]+)\s*\(", re.MULTILINE)


def _module_defines(ll):
    return {_norm(m) for m in _DEFINE.findall(ll)}


def _runtime_refs(ll):
    return {_norm(m) for m in _RT_FAMILY.findall(ll)}


# The child-exit facade. desugar.ml:1316 lowers a spawn body's child arm to
# `Spawn__child_exit(ch)`; runtime/yon_rt.c:2344-2347 has
# `void yon_rt_spawn_child_exit(void *h){ _exit(0); }` and yon_rt.c:2454
# `double Spawn__child_exit(double id){ yon_rt_spawn_child_exit(...); ... }`.
# Both names may appear in @-position depending on inlining, so we match either.
_CHILD_EXIT = re.compile(
    r"@(Spawn__child_exit|yon_rt_spawn_child_exit)\b")


_NM_CACHE = {"set": None}


def _provided_symbols():
    """Symbols defined (text/data, i.e. not 'U') by the RTSET .o files,
    normalized. Cached across nodes. The toolchain fixture has already checked
    that every RTSET object exists, so an object nm cannot read FAILS the node:
    a silently partial provided-set would hide exactly the undefined reference
    these nodes look for."""
    if _NM_CACHE["set"] is not None:
        return _NM_CACHE["set"]
    provided = set()
    for obj in RTSET:
        r = _run([NM, "-g", obj])
        if r.returncode != 0:
            pytest.fail(f"nm could not read runtime object {obj}\n"
                        f"{r.stderr.decode(errors='replace')[-1000:]}")
        for line in r.stdout.decode(errors="replace").splitlines():
            parts = line.split()
            # `<addr> <type> <name>`  or  `         <type> <name>` (undefined)
            if len(parts) >= 2:
                typ, sym = parts[-2], parts[-1]
                # defined symbols: any type letter that is not 'U' (undefined).
                if typ.upper() != "U":
                    provided.add(_norm(sym))
    _NM_CACHE["set"] = provided
    return provided


# ── nodes ──────────────────────────────────────────────────────────────────
# (test_ll_emits, "the .ll is non-empty and has a `define`", was removed:
# _emit_ll already fails on an empty .ll, and test_ll_has_entry below, on the
# same EXAMPLES, requires `define i32 @main()`, which implies a `define`.)
@pytest.mark.parametrize("name", EXAMPLES)
def test_ll_has_entry(name, tmp_path):
    """The module defines the program entry with the C ABI the linker expects:
    `define i32 @main()` (emit_mlir.ml emits `func.func @main() -> i32`).
    `@__yon_dispatch` is NOT accepted as a substitute: it is emitted for every
    program, so its presence proves nothing about the entry."""
    ll = _emit_ll(name, tmp_path)
    m = re.search(r"^\s*define\b[^\n]*?(\S+)\s+@main\s*\(([^)]*)\)", ll, re.MULTILINE)
    assert m is not None, (
        f"{name}: @main is not defined in the module; "
        f"defines seen: {sorted(_module_defines(ll))[:20]}")
    assert (m.group(1), m.group(2).strip()) == ("i32", ""), (
        f"{name}: @main has signature `{m.group(1)} @main({m.group(2)})`, "
        f"expected `i32 @main()`")


@pytest.mark.parametrize("name", EXAMPLES)
def test_ll_no_undefined_runtime_refs(name, tmp_path):
    """HIGHEST-VALUE node. Every runtime-facade symbol referenced (called or
    declared) by the IR — @yon_rt_*, @Spawn__*, @Stream__*, @__yon_dispatch —
    must be either defined in this module OR provided by the runtime objects.
    This catches a renamed/removed runtime function (ABI drift, undefined ref)
    before the slow link step, and points straight at the offending symbol."""
    ll = _emit_ll(name, tmp_path)

    refs = _runtime_refs(ll)
    # every program calls yon_rt_maybe_serve from main: an IR with no facade
    # reference at all means the emitter (or this extraction) broke.
    assert refs, f"{name}: IR references no runtime-facade symbols"

    provided = _provided_symbols()

    in_module = _module_defines(ll)
    available = provided | in_module
    missing = sorted(s for s in refs if s not in available)
    assert not missing, (
        f"{name}: IR references runtime symbols that NOTHING provides "
        f"(not defined in module, not in runtime objects): {missing}. "
        f"This is exactly the link-time 'undefined reference' the IR stage "
        f"should localize."
    )


# ── the runtime ABI, read from the C side ───────────────────────────────────
# The facade is NOT uniformly f64: emit_mlir.ml's table also has i1/Prop
# arrows (yon_rt_to_prop/to_bool_dec: i8), a ptr (yon_rt_string_lit), an i32
# (yon_rt_xheap_used) and a void control call (yon_rt_maybe_serve). The truth
# the IR must agree with is the C prototype the runtime object is compiled
# from, so that is the oracle: every facade declaration in the IR must have
# exactly the return and parameter types of its prototype in runtime/*.[ch].
_C2LL = {"double": "double", "void": "void", "int8_t": "i8", "uint8_t": "i8",
         "bool": "i8", "int32_t": "i32", "uint32_t": "i32", "int": "i32",
         "int64_t": "i64", "uint64_t": "i64"}
_C_QUAL = re.compile(r"\b(?:const|static|inline|extern|volatile|restrict)\b")
_DECLARE = re.compile(r"^declare\s+(\S+)\s+@([A-Za-z0-9_]+)\(([^)]*)\)", re.MULTILINE)
_C_FUNC = re.compile(r"^[ \t]*((?:[A-Za-z_][A-Za-z0-9_]*[ \t*]+)+?)\**"
                     r"([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)\s*[{;]", re.MULTILINE)
_C_INDEX = {"by_name": None}


def _c_to_ll(ctype):
    """The LLVM type a C type lowers to on our 64-bit targets, or None when
    the text is not a type we know (e.g. `return` from a call statement)."""
    t = " ".join(_C_QUAL.sub("", ctype).split())
    if "*" in t:
        return "ptr"
    return _C2LL.get(t)


def _c_param_type(param):
    """`double a` -> double, `const char *s` -> ptr, `double` -> double."""
    p = param.strip()
    if "*" in p:
        return "ptr"
    words = p.split()
    return _c_to_ll(" ".join(words[:-1]) if len(words) > 1 else p)


def _c_prototypes(sym):
    """Every (ret, [params]) signature the runtime sources give `sym`, from its
    definitions and prototypes (a call statement such as `return sym(x);` is
    filtered out because `return` is not a C type). The sources are indexed
    once per process."""
    if _C_INDEX["by_name"] is None:
        text = "\n".join(p.read_text(errors="replace") for p in sorted(FT.glob("*.[ch]")))
        idx = {}
        for m in _C_FUNC.finditer(text):
            idx.setdefault(m.group(2), []).append((m.group(1), m.group(3)))
        _C_INDEX["by_name"] = idx
    sigs = []
    for ret, params in _C_INDEX["by_name"].get(sym, []):
        r = _c_to_ll(ret)
        if r is None:
            continue
        ps = [] if params.strip() in ("", "void") else \
            [_c_param_type(x) for x in params.split(",")]
        sigs.append((r, ps))
    return sigs


def _ll_param_types(args):
    """`double %1, ptr @s` / `double, double` -> ['double', 'ptr']."""
    return [a.split()[0] for a in args.split(",") if a.strip()]


def _abi_violations(ll):
    """The facade ABI mismatches of one module: (symbol, what is wrong).
    Two checks: (1) each facade declaration matches every C prototype of the
    symbol; (2) each facade call site passes and returns exactly the types of
    the module's own declaration of that symbol."""
    bad = []
    declared = {}
    for ret, sym, args in _DECLARE.findall(ll):
        if not _RT_FAMILY.match("@" + sym):
            continue
        declared[sym] = (ret, _ll_param_types(args))
        protos = _c_prototypes(sym)
        if not protos:
            bad.append((sym, "no C prototype in runtime/*.[ch]"))
        for proto in protos:
            if proto != declared[sym]:
                bad.append((sym, f"IR declares {declared[sym]}, C has {proto}"))
    call_re = re.compile(r"\bcall\s+(?:[a-z]+\s+)*?(\S+)\s+@([A-Za-z0-9_]+)\(([^)]*)\)")
    for ret, sym, args in call_re.findall(ll):
        if sym not in declared:
            continue  # a call to a function defined in this module
        got = (ret, _ll_param_types(args))
        if got != declared[sym]:
            bad.append((sym, f"call site {got} vs declaration {declared[sym]}"))
    return bad


@pytest.mark.parametrize("name", EXAMPLES)
def test_ll_runtime_abi(name, tmp_path):
    """Every runtime-facade symbol the IR declares has, operand by operand,
    the return and parameter types of its C prototype in runtime/*.[ch], and
    every call site agrees with that declaration. This is the ABI drift the
    linker cannot see (C symbols carry no types): a `double` argument passed
    where the runtime reads an `int8_t` links fine and computes garbage."""
    ll = _emit_ll(name, tmp_path)
    declared = [s for _, s, _ in _DECLARE.findall(ll) if _RT_FAMILY.match("@" + s)]
    assert declared, f"{name}: the IR declares no runtime-facade symbol"
    bad = _abi_violations(ll)
    assert not bad, f"{name}: runtime ABI mismatches: {bad[:10]}"


@pytest.mark.parametrize("name", SPAWN_EXAMPLES)
def test_ll_child_exit_noreturn(name, tmp_path):
    """The child-exit invariant: a spawn body's child arm ends in a call to the
    child-exit facade (desugar.ml lowers it to `Spawn__child_exit(ch)`, whose
    body calls `_exit(0)`), and control must never resume the parent's
    continuation after it. emit_mlir marks the facade declaration with a
    noreturn passthrough, which func->llvm forwards to the LLVM `noreturn`
    attribute; we assert (a) the spawn program really calls the facade (the
    declaration is only emitted when used, but a call site is what makes the
    child exit) and (b) the declaration carries `noreturn`, inline or in an
    `attributes #N` group.

    (test_ll_child_exit_unreachable, which checked that the call's SSA result
    is not consumed after the call, was removed: on the same SPAWN_EXAMPLES,
    `noreturn` makes every instruction after the call unreachable by LLVM
    semantics, so it implies that property.)"""
    ll = _emit_ll(name, tmp_path)
    sites = re.findall(r"\bcall\b[^\n]*" + _CHILD_EXIT.pattern, ll)
    assert sites, f"{name}: the spawn program has no child-exit call site"
    m = re.search(
        r"^\s*(?:declare|define)[^\n]*" + _CHILD_EXIT.pattern + r"[^\n]*$",
        ll, re.MULTILINE)
    assert m is not None, f"{name}: IR calls but does not declare the child-exit facade"
    line = m.group(0)
    if "noreturn" in line:
        return  # inline attribute: invariant satisfied
    grp = re.search(r"#(\d+)\b", line)
    assert grp is not None, (
        f"{name}: @Spawn__child_exit has neither an inline `noreturn` nor an "
        f"attribute group:\n{line}")
    n = grp.group(1)
    attrs = re.search(rf"^attributes #{n} = \{{[^}}\n]*\}}", ll, re.MULTILINE)
    assert attrs is not None and "noreturn" in attrs.group(0), (
        f"{name}: attribute group #{n} of @Spawn__child_exit lacks `noreturn` "
        f"(the noreturn passthrough did not reach the IR):\n"
        f"{attrs.group(0) if attrs else '(group #' + n + ' not found)'}")


def _nm_symbols(obj):
    """(defined, undefined) symbol sets of an object file, normalized (one
    leading underscore stripped). nm failing on an object llc just produced
    FAILS the node."""
    r = _run([NM, str(obj)])
    if r.returncode != 0:
        pytest.fail(f"nm could not read {obj}\n{r.stderr.decode(errors='replace')[-1000:]}")
    defined, undef = set(), set()
    for line in r.stdout.decode(errors="replace").splitlines():
        parts = line.split()
        if len(parts) >= 2:
            (undef if parts[-2].upper() == "U" else defined).add(_norm(parts[-1]))
    return defined, undef


# libc / libm / pthread symbols an object may legitimately leave undefined:
# the system linker resolves them, not our RTSET objects. Anything matching
# here is NOT required to be in the runtime-provided set.
#
# There is deliberately NO blanket "__" prefix: it used to whitelist every
# `__yon_*` runtime symbol, so a missing one passed as "system". The system
# symbols that do start with "__" are listed by name (as they read after
# _norm strips one underscore):
#   __stack_chk_fail, __stack_chk_guard   stack protector (macOS ___stack_chk_*)
#   __error                               macOS errno accessor (___error)
#   __errno_location                      glibc errno accessor
#   __stderrp, __stdoutp, __stdinp        macOS stdio streams
#   __bzero, __memcpy_chk, __memmove_chk, __memset_chk, __strcpy_chk,
#   __strcat_chk, __snprintf_chk, __sprintf_chk, __vsnprintf_chk
#                                         FORTIFY_SOURCE builtins
#   __assert_fail, __assert_rtn           glibc / macOS assert
#   __udivti3, __umodti3, __divti3, __modti3  compiler-rt 128-bit division
# (The objects emitted for EXAMPLES today leave none of them undefined: the
# list is the tolerance an llc upgrade may need, not observed traffic.)
_SYS_PREFIXES = ("pthread_", "_ZSt", "llvm.", "sem_", "atomic_")
_SYS_EXACT = {
    "memcpy", "memmove", "memset", "memcmp", "strlen", "strcmp", "strncmp",
    "strcpy", "strncpy", "strcat", "strdup", "printf", "fprintf", "snprintf",
    "sprintf", "vsnprintf", "puts", "putchar", "fputs", "fwrite", "fputc",
    "fflush", "malloc", "calloc", "realloc", "free", "abort", "exit", "_exit",
    "_Exit", "qsort", "memchr", "strchr", "strrchr", "strstr", "getenv",
    "open", "close", "read", "write", "lseek", "mmap", "munmap", "ftruncate",
    "fopen", "fclose", "fread", "feof", "ferror", "perror", "errno",
    "stderr", "stdout", "stdin", "sqrt", "pow", "fabs",
    "floor", "ceil", "round", "fmod", "log", "exp", "sin", "cos", "nan",
    "shm_open", "shm_unlink", "usleep", "sleep", "nanosleep", "fork", "waitpid",
    "kill", "getpid", "socket", "bind", "listen", "accept", "connect", "send",
    "recv", "setsockopt", "htons", "ntohs", "inet_pton", "dprintf",
    "clock_gettime", "gettimeofday",
    "__stack_chk_fail", "__stack_chk_guard", "__error", "__errno_location",
    "__stderrp", "__stdoutp", "__stdinp", "__bzero", "__memcpy_chk",
    "__memmove_chk", "__memset_chk", "__strcpy_chk", "__strcat_chk",
    "__snprintf_chk", "__sprintf_chk", "__vsnprintf_chk", "__assert_fail",
    "__assert_rtn", "__udivti3", "__umodti3", "__divti3", "__modti3",
}


def _is_system_symbol(sym):
    return sym in _SYS_EXACT or sym.startswith(_SYS_PREFIXES)


@pytest.mark.parametrize("name", EXAMPLES)
def test_ll_object_symbol_split(name, tmp_path):
    """LINK-TIME invariant asserted BEFORE the slow link. Carry the example to a
    relocatable object (_emit_obj: _emit_ll -> `llc -filetype=obj`) and `nm` it.
    Assert the two halves of a clean link:

      (a) the program entry `main` (macOS `_main`) is DEFINED here; the
          always-emitted `__yon_dispatch` is not an entry and does not count;
      (b) every UNDEFINED ('U') symbol is resolvable: it is either provided by
          the RTSET runtime objects (nm union of those .o) OR a named system
          symbol (libc/libm/pthread allowlist above).

    A 'U' that is neither runtime-provided nor a system symbol is precisely the
    undefined reference that would blow up the link, caught here and named.

    This is NOT the same check as test_ll_no_undefined_runtime_refs: that one
    reads the IR, where every facade declaration (~220 per module) is visible
    whether used or not, but only the facade families; this one reads the
    object, where only the symbols actually referenced survive, of every
    family (system symbols and non-facade runtime symbols included)."""
    obj = _emit_obj(name, tmp_path)
    defined, undef = _nm_symbols(obj)

    assert "main" in defined, (
        f"{name}: object does not define `main`; defined sample: {sorted(defined)[:20]}")

    provided = _provided_symbols()
    unresolved = sorted(
        s for s in undef
        if s not in provided and not _is_system_symbol(s)
    )
    assert not unresolved, (
        f"{name}: object has UNDEFINED symbol(s) that neither the runtime "
        f"objects nor the system allowlist provide: {unresolved}. This is the "
        f"link-time 'undefined reference' the IR/object stage should localize."
    )
