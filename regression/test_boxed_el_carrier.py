"""Value-dependent `El` lowers to a UNIFORM boxed carrier.

Complements test_dependent_carrier.py (the A1 COMPUTED case: `El(Fam x)` where the
code reduces to a concrete type → that type's concrete carrier). This file pins the
OPEN case: a code that stays STUCK under Δ because it genuinely depends on a runtime
value (a non-constant / non-terminating family applied to a free variable). Such a
type has no single concrete layout, but it DOES have a single UNIFORM layout — a fat
pointer `{ptr, i64-tag}` shared by every stuck-El instance. Before this feature the
frontend emit FAILED on such a type ("type has no runtime carrier"); now it lowers to
the box and functions over it compile once.

What this pins:
  1. A value-dependent `El` now COMPILES (emit exit 0) instead of failing.
  2. Its carrier is the uniform box `!llvm.struct<(ptr, i64)>`, identical across
     distinct stuck families (uniformity → compile-once ABI).
  3. The box ROUND-TRIPS through the calling convention: a function taking `El(stuck)`
     and returning `El(stuck)` carries the box through unmodified.
  4. The A1 computed case is UNCHANGED — a constant family still gets the CONCRETE
     carrier, never the box (soundness guard: the box is the last resort, only for a
     genuinely stuck code).

Lightweight: only the frontend emitter (`--emit=mlir`, YONC_FRONTEND) is needed.
"""

import os
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
FRONTEND = Path(
    os.environ.get(
        "YONC_FRONTEND", ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"
    )
)

# The uniform value-dependent-El carrier: a fat pointer {payload-ptr, i64 type-tag}.
BOX = "!llvm.struct<(ptr, i64)>"


@pytest.fixture(scope="session", autouse=True)
def _built():
    if not FRONTEND.exists():
        pytest.skip(f"frontend emitter not built: {FRONTEND} (run `dune build` in frontend/)")


def _run(src: str, tmp_path):
    f = tmp_path / "box.yon"
    f.write_text(src)
    return subprocess.run([str(FRONTEND), str(f)], capture_output=True, timeout=60)


def _emit(src: str, tmp_path) -> str:
    r = _run(src, tmp_path)
    assert r.returncode == 0, (
        "frontend emit failed:\n" + r.stderr.decode(errors="replace")[-1200:]
    )
    return r.stdout.decode(errors="replace")


def _decl(mlir: str, fn: str):
    """The `(params) -> ret` slice of `func.func @fn(params) -> ret {`.

    MLIR carrier types nest parens (`!llvm.struct<(ptr, i64)>`), so a naive
    `\\(([^)]*)\\)` truncates at the first inner `)`. We instead grab everything
    between the opening `(` after the name and the ` {` that opens the body, then
    split at the top-level ` -> ` (the last one, since the box return has no arrow).
    """
    m = re.search(r"func\.func @%s\((.*?)\)\s*->\s*(.+?)\s*\{" % re.escape(fn), mlir)
    if not m:
        return None, None
    return m.group(1), m.group(2).strip()


def _sig(mlir: str, fn: str):
    """The parameter-type signature string, or None."""
    return _decl(mlir, fn)[0]


def _ret(mlir: str, fn: str):
    """The return-type string, or None."""
    return _decl(mlir, fn)[1]


# A genuinely value-dependent family: NON-TERMINATING, so it is NOT SCT-certified,
# so El_normalize leaves `El(Fam x)` STUCK (App(Fam, x) irreducible) — the honest
# value-dependent case (the type really does depend on the runtime x). `Fam` is a
# universe-codomain family, so type_erase drops it from codegen; `x` stays a runtime
# parameter and `p : El(Fam(x))` reaches the carrier stuck.
STUCK_FAM = "fun Fam(x: number): Type_0 { return Fam(x) }\n"


def test_value_dependent_el_compiles(tmp_path):
    """A value-dependent `El` that previously FAILED emit now compiles to the box."""
    src = STUCK_FAM + (
        "fun viaEl(x: number, p: El(Fam(x))): number { return 0 }\n"
        "fun main(): number { return 0 }\n"
    )
    mlir = _emit(src, tmp_path)
    sig = _sig(mlir, "viaEl")
    assert sig is not None, "viaEl was not emitted"
    # the value-dependent El parameter `p` lowers to the uniform box.
    assert BOX in sig, f"viaEl signature {sig!r} does not carry the boxed El carrier {BOX!r}"


def test_boxed_carrier_is_uniform(tmp_path):
    """Two DISTINCT stuck families produce the SAME carrier — uniformity is what lets a
    function over `El(stuck)` compile once, regardless of the code inside."""
    src = (
        "fun Fam(x: number): Type_0 { return Fam(x) }\n"
        "fun Gam(y: number): Type_0 { return Gam(y) }\n"
        "fun useF(x: number, p: El(Fam(x))): number { return 0 }\n"
        "fun useG(y: number, q: El(Gam(y))): number { return 0 }\n"
        "fun main(): number { return 0 }\n"
    )
    mlir = _emit(src, tmp_path)
    sf, sg = _sig(mlir, "useF"), _sig(mlir, "useG")
    assert sf is not None and sg is not None
    # both parameters carry the identical box carrier.
    assert BOX in sf and BOX in sg, f"useF={sf!r} useG={sg!r}"
    # the box appears exactly once in each (the single El param), and it is the SAME
    # string — one ABI shape shared across the two distinct stuck codes.
    assert sf.count(BOX) == 1 and sg.count(BOX) == 1, f"useF={sf!r} useG={sg!r}"


def test_boxed_value_round_trips_through_call(tmp_path):
    """The box round-trips through the calling convention: a function that takes
    `El(stuck)` and RETURNS `El(stuck)` carries the box through unmodified."""
    src = STUCK_FAM + (
        "fun passBox(x: number, p: El(Fam(x))): El(Fam(x)) { return p }\n"
        "fun main(): number { return 0 }\n"
    )
    mlir = _emit(src, tmp_path)
    sig, ret = _sig(mlir, "passBox"), _ret(mlir, "passBox")
    assert sig is not None and ret is not None, "passBox not emitted"
    # box in, box out — the same uniform carrier on both sides.
    assert BOX in sig, f"passBox param {sig!r} missing box"
    assert ret == BOX, f"passBox return {ret!r} != box {BOX!r}"
    # the body returns the argument itself: a genuine value round-trip.
    assert re.search(r"return %arg_p : " + re.escape(BOX), mlir), (
        "passBox body does not return its boxed argument unchanged"
    )


def test_computed_case_never_boxed(tmp_path):
    """SOUNDNESS GUARD / A1 unchanged: a CONSTANT family (code computes to a concrete
    type) gets the CONCRETE carrier, NEVER the box. The box is strictly the last
    resort for a genuinely stuck code — it must not swallow the computed case."""
    src = (
        "fun Fam(x: number): Type_0 { return number }\n"
        "fun viaEl(p: El(Fam(7))): number { return 0 }\n"
        "fun direct(p: number): number { return 0 }\n"
        "fun main(): number { return 0 }\n"
    )
    mlir = _emit(src, tmp_path)
    se, sd = _sig(mlir, "viaEl"), _sig(mlir, "direct")
    # computed case decodes to number's concrete carrier (f64), NOT the box.
    assert se == sd, f"computed El(Fam 7)->{se!r} vs direct number->{sd!r}"
    assert BOX not in (se or ""), f"computed case wrongly boxed: {se!r}"
