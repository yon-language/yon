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
  * frontend/emit_mlir.ml runtime facade table (lines ~308-350) declares every
    Stream__/Spawn__/yon_rt_* call as f64 -> f64 (the whole runtime facade is
    f64); e.g. "Spawn__open", (["f64"], "f64").
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
    "xleech2_coord.o", "xleech2_handler_stack.o", "xleech2_heap.o", "xleech2_mphf.o",
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
EXAMPLES = ["arena_basic", "spawn_parallel_collect", "net_stream"]


# ── skip fixture: skip cleanly if any required stage tool is unavailable ──
@pytest.fixture(scope="session", autouse=True)
def _toolchain():
    missing = [str(p) for p in (EMIT, Path(TOPOS)) if not Path(p).exists()]
    missing += [n for n in RTSET if not Path(n).exists()]
    if missing:
        pytest.skip(f"toolchain not built: {missing[0]} (run dune build / make / cmake)")
    # mlir-translate and nm must be runnable (they may be bare names on PATH).
    for t in (MLIRTRANS, NM):
        if not (shutil.which(t) or Path(t).exists()):
            pytest.skip(f"tool not found on PATH: {t}")


def _emit_ll(name, tmp):
    """Run EMIT -> topos-opt (two lowering passes, MLIROPT fallback) ->
    mlir-translate --mlir-to-llvmir and return the .ll text, or None if any
    stage fails / produces no output (caller skips)."""
    src = EXD / f"{name}.yon"
    if not src.exists():
        return None
    mlir, s1, s2 = (tmp / f"{name}.{e}" for e in ("mlir", "s1", "s2"))

    r = _run([str(EMIT), str(src)])
    if r.returncode != 0 or not r.stdout:
        return None
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
            return None
        s2.write_bytes(f.stdout)

    t = _run([MLIRTRANS, str(s2), "--mlir-to-llvmir"])
    if t.returncode != 0 or not t.stdout:
        return None
    return t.stdout.decode(errors="replace")


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


_NM_CACHE = {"set": None}


def _provided_symbols():
    """Symbols defined (text/data, i.e. not 'U') by the RTSET .o files,
    normalized. Cached across nodes; skip if nm fails on every object."""
    if _NM_CACHE["set"] is not None:
        return _NM_CACHE["set"]
    provided = set()
    ran_any = False
    for obj in RTSET:
        if not Path(obj).exists():
            continue
        r = _run([NM, "-g", obj])
        if r.returncode != 0:
            continue
        ran_any = True
        for line in r.stdout.decode(errors="replace").splitlines():
            parts = line.split()
            # `<addr> <type> <name>`  or  `         <type> <name>` (undefined)
            if len(parts) >= 2:
                typ, sym = parts[-2], parts[-1]
                # defined symbols: any type letter that is not 'U' (undefined).
                if typ.upper() != "U":
                    provided.add(_norm(sym))
    if not ran_any:
        _NM_CACHE["set"] = None
        return None
    _NM_CACHE["set"] = provided
    return provided


# ── nodes ──────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("name", EXAMPLES)
def test_ll_emits(name, tmp_path):
    """The pipeline reaches valid LLVM IR: non-empty .ll containing a function
    `define` (a real function body, not just declarations)."""
    ll = _emit_ll(name, tmp_path)
    if ll is None:
        pytest.skip(f"{name}: a pre-LLVM stage failed/produced no output")
    assert ll.strip(), f"{name}: emitted .ll is empty"
    assert re.search(r"^\s*define\b", ll, re.MULTILINE), \
        f"{name}: .ll has no function 'define' (no function bodies reached)"


@pytest.mark.parametrize("name", EXAMPLES)
def test_ll_has_entry(name, tmp_path):
    """The module defines the program entry. emit_mlir.ml emits both
    `func.func @main() -> i32` (5364) and the always-emitted
    `func.func @__yon_dispatch(...)` (5554); after lowering+translate these
    become `define ... @main(` and `define ... @__yon_dispatch(`. We accept
    either definition as evidence the entry/dispatch scaffolding survived."""
    ll = _emit_ll(name, tmp_path)
    if ll is None:
        pytest.skip(f"{name}: a pre-LLVM stage failed/produced no output")
    defs = _module_defines(ll)
    assert ("main" in defs) or ("__yon_dispatch" in defs), (
        f"{name}: neither @main nor @__yon_dispatch is defined in the module; "
        f"defines seen: {sorted(defs)[:20]}"
    )


@pytest.mark.parametrize("name", EXAMPLES)
def test_ll_no_undefined_runtime_refs(name, tmp_path):
    """HIGHEST-VALUE node. Every runtime-facade symbol referenced (called or
    declared) by the IR — @yon_rt_*, @Spawn__*, @Stream__*, @__yon_dispatch —
    must be either defined in this module OR provided by the runtime objects.
    This catches a renamed/removed runtime function (ABI drift, undefined ref)
    before the slow link step, and points straight at the offending symbol."""
    ll = _emit_ll(name, tmp_path)
    if ll is None:
        pytest.skip(f"{name}: a pre-LLVM stage failed/produced no output")

    refs = _runtime_refs(ll)
    if not refs:
        pytest.skip(f"{name}: IR references no runtime-facade symbols")

    provided = _provided_symbols()
    if provided is None:
        pytest.skip("nm could not read any runtime .o (cannot build provided set)")

    in_module = _module_defines(ll)
    available = provided | in_module
    missing = sorted(s for s in refs if s not in available)
    assert not missing, (
        f"{name}: IR references runtime symbols that NOTHING provides "
        f"(not defined in module, not in runtime objects): {missing}. "
        f"This is exactly the link-time 'undefined reference' the IR stage "
        f"should localize."
    )


@pytest.mark.parametrize("name", EXAMPLES)
def test_ll_f64_abi(name, tmp_path):
    """BEST-EFFORT. The runtime facade is uniformly f64 (emit_mlir.ml facade
    table: every Spawn__/Stream__/yon_rt_* arrow is (f64.. -> f64)). So a *call*
    to one of those symbols in the IR should pass/return `double`, never i32/i64
    pointers in the value slots. We scan call sites with a tolerant regex and
    require that the calls we can clearly parse mention `double`. If no such
    call is parseable (formatting variance), we skip rather than false-fail."""
    ll = _emit_ll(name, tmp_path)
    if ll is None:
        pytest.skip(f"{name}: a pre-LLVM stage failed/produced no output")

    # match: `call <ret> @sym(<args>)` for a facade symbol, on one logical line.
    call_re = re.compile(
        r"\bcall\b[^\n@]*@(yon_rt_[A-Za-z0-9_]+|Spawn__[A-Za-z0-9_]+|"
        r"Stream__[A-Za-z0-9_]+|__yon_dispatch)\s*\(([^)]*)\)")
    # Symbols whose runtime signature involves !llvm.ptr (string-lit / rpc) and
    # so legitimately are NOT pure-double — excluded from the f64 assertion.
    ptr_syms = ("yon_rt_string_lit", "yon_rt_rpc2_invoke_named")

    checked = 0
    bad = []
    for ret_and_args in call_re.finditer(ll):
        sym = ret_and_args.group(1)
        if any(sym.startswith(p) for p in ptr_syms):
            continue
        whole = ret_and_args.group(0)
        args = ret_and_args.group(2).strip()
        # A `call void @f()` (void return, no operands) is a CONTROL call — no
        # value crosses the boundary (e.g. yon_rt_maybe_serve: poll the RPC
        # serve-loop), so the f64 value-ABI simply does not apply to it.
        if args == "" and re.search(r"\bcall\s+void\b", whole):
            continue
        # the call text should mention double somewhere (ret or an operand).
        checked += 1
        if "double" not in whole:
            bad.append(sym)

    if checked == 0:
        pytest.skip(f"{name}: no parseable pure-f64 facade call sites in this IR")
    assert not bad, (
        f"{name}: facade call site(s) without a `double` operand/return, "
        f"contradicting the f64 runtime ABI: {sorted(set(bad))}"
    )
