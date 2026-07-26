"""A1 regression: computed-codomain dependent types `El(Fam x)` lower correctly.

Pins the conversion rule  El(c) ≡ carrier(nf_Δ c)  end-to-end through the frontend
emitter. A Tarski code family `Fam : A -> U_omega` applied to an argument is reduced
to its Δ-normal form (El_normalize, driven by the certified deltas — the same kernel
reducer the definitional-equality checker uses), then the pure carrier functor
decodes that normal form. So `El(Fam k)` must produce the SAME runtime carrier as the
type `Fam` computes to, and the type-family function itself (universe codomain) must
never be emitted as runtime code.

Lightweight: only the frontend emitter (`--emit=mlir`, YONC_FRONTEND) is needed — the
carrier decision is made entirely in the frontend, no LLVM toolchain required.
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

# number/money/text share the f64 scalar; boolean/unit share i1. The set spans both
# scalar carriers, so an "always-number" bug would be caught by boolean/unit.
PRIMS = ["number", "money", "text", "boolean", "unit"]
# type-POSITION spelling: the prelude faces are capitalized; money has no face yet
FACE = {"number": "Number", "money": "money", "text": "Text",
        "boolean": "Boolean", "unit": "Unit"}


@pytest.fixture(scope="session", autouse=True)
def _built():
    if not FRONTEND.exists():
        pytest.skip(f"frontend emitter not built: {FRONTEND} (run `dune build` in frontend/)")


def _emit(src: str, tmp_path) -> str:
    f = tmp_path / "a1.yon"
    f.write_text(src)
    r = subprocess.run([str(FRONTEND), str(f)], capture_output=True, timeout=60)
    assert r.returncode == 0, (
        "frontend emit failed:\n" + r.stderr.decode(errors="replace")[-1200:]
    )
    return r.stdout.decode(errors="replace")


def _sig(mlir: str, fn: str):
    """The parameter-type signature string of `func.func @fn(...)`, or None."""
    m = re.search(r"func\.func @%s\(([^)]*)\)" % re.escape(fn), mlir)
    return m.group(1) if m else None


@pytest.mark.parametrize("prim", PRIMS)
def test_constant_family_carrier(prim, tmp_path):
    """El(Fam k) with a constant family Fam(x) = P lowers to P's carrier."""
    src = f"""
fun Fam(x: Number): Type_0 {{ return {prim} }}
fun viaEl(p: El(Fam(7))): Number {{ return 0 }}
fun direct(p: {FACE[prim]}): Number {{ return 0 }}
fun main(): Number {{ return 0 }}
"""
    mlir = _emit(src, tmp_path)
    se, sd = _sig(mlir, "viaEl"), _sig(mlir, "direct")
    assert sd is not None and se == sd, f"El(Fam)->{se!r} vs direct {prim}->{sd!r}"


@pytest.mark.parametrize("prim", PRIMS)
def test_identity_type_family(prim, tmp_path):
    """El(Id P) = P: the identity functor on the universe computes away."""
    src = f"""
fun Id_ty(t: Type_0): Type_0 {{ return t }}
fun viaEl(p: El(Id_ty({prim}))): Number {{ return 0 }}
fun direct(p: {FACE[prim]}): Number {{ return 0 }}
fun main(): Number {{ return 0 }}
"""
    mlir = _emit(src, tmp_path)
    se, sd = _sig(mlir, "viaEl"), _sig(mlir, "direct")
    assert sd is not None and se == sd, f"El(Id {prim})->{se!r} vs direct->{sd!r}"


def test_sigma_computed_codomain(tmp_path):
    """The A1 headline: Sigma with a computed-codomain second component compiles and
    matches the concrete Sigma it computes to."""
    src = """
fun Fam(x: Number): Type_0 { return Number }
fun viaEl(p: Sigma(x: Number). El(Fam(x))): Number { return 0 }
fun direct(p: Sigma(x: Number). Number): Number { return 0 }
fun main(): Number { return 0 }
"""
    mlir = _emit(src, tmp_path)
    se, sd = _sig(mlir, "viaEl"), _sig(mlir, "direct")
    assert sd is not None and se == sd, f"El sigma->{se!r} vs direct->{sd!r}"


def test_type_family_not_emitted(tmp_path):
    """A type-family function (universe codomain) is a compile-time citizen: it is
    consumed by the El conversion and must NOT reach codegen as a runtime function."""
    src = """
fun Fam(x: Number): Type_0 { return Number }
fun takes(p: El(Fam(3))): Number { return 0 }
fun main(): Number { return 0 }
"""
    mlir = _emit(src, tmp_path)
    assert "func.func @Fam" not in mlir, "type-family Fam leaked into runtime codegen"
