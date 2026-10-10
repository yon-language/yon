"""Method dispatch by receiver type: same-named methods on distinct places.

A method is an arrow indexed by its domain object (Yoneda). Two places may each
declare `fun area(self: P): Number`; a call `x.area()` (which parses to
`area(x)`) resolves to the method whose receiver type matches `x`. The tycheck
qualifies overloaded methods to `Place__name` and records the resolution at the
call site; the desugar lowers the call to the resolved target. Unique names
(main, plain helpers) are untouched, and the qualifier is name-only so identical
method bodies still content-address to the same value.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc not present")

TOML = ('[package]\nname = "ov"\n[world.W]\n'
        'objects = ["X"]\nspaces  = ["w"]\n[runtime]\nbackend = "memory"\n')


def _make(tmp_path, places, main_body):
    root = tmp_path / "ov"
    (root / "w").mkdir(parents=True)
    (root / "yon.toml").write_text(TOML)
    (root / "w" / "Topos.yon").write_text("topos CTopos where {\n}\n")
    for name, body in places.items():
        (root / "w" / f"{name}.yon").write_text(body)
    (root / "Entry.yon").write_text("place Entry { }\n" + main_body)
    return root


def _run(tmp_path, places, main_body):
    root = _make(tmp_path, places, main_body)
    b = tmp_path / "bin"
    c = subprocess.run([str(YONC), str(root), "-o", str(b)],
                       capture_output=True, text=True, timeout=180)
    assert c.returncode == 0 and b.exists(), f"did not compile:\n{c.stderr[-800:]}"
    return subprocess.run([str(b)], capture_output=True, timeout=60).returncode


SQUARE = ("place Square {\n  side := Number\n"
          "  fun area(s: Square): Number { return s.side * s.side }\n}\n")
CIRCLE = ("place Circle {\n  r := Number\n"
          "  fun area(c: Circle): Number { return c.r * c.r * 3 }\n}\n")


def test_dispatch_by_receiver_type(tmp_path):
    # sq.area() -> Square's area (25); ci.area() -> Circle's area (12); 25+12=37.
    main = ("fun main(): Number {\n"
            "  be sq holds .-> Square { side 5 }\n"
            "  be ci holds .-> Circle { r 2 }\n"
            "  return sq.area() + ci.area()\n}\n")
    assert _run(tmp_path, {"Square": SQUARE, "Circle": CIRCLE}, main) == 37


def test_qualified_call(tmp_path):
    # the Place.method(x) form resolves to the same target.
    main = ("fun main(): Number {\n"
            "  be sq holds .-> Square { side 5 }\n"
            "  return Square.area(sq)\n}\n")
    assert _run(tmp_path, {"Square": SQUARE, "Circle": CIRCLE}, main) == 25


def test_third_place_extends_without_touching_others(tmp_path):
    # adding a place with the same method name is open: no change to Square/Circle.
    tri = ("place Tri {\n  base := Number\n"
           "  fun area(t: Tri): Number { return t.base }\n}\n")
    main = ("fun main(): Number {\n"
            "  be sq holds .-> Square { side 4 }\n"
            "  be t holds .-> Tri { base 9 }\n"
            "  return sq.area() + t.area()\n}\n")  # 16 + 9 = 25
    assert _run(tmp_path, {"Square": SQUARE, "Circle": CIRCLE, "Tri": tri}, main) == 25


def _reject(tmp_path, places, main_body):
    """Compile a project that must be rejected; return (rc, combined output)."""
    root = _make(tmp_path, places, main_body)
    c = subprocess.run([str(YONC), str(root), "-o", str(tmp_path / "bin")],
                       capture_output=True, text=True, timeout=120)
    out = c.stdout + c.stderr
    assert "Fatal error: exception" not in out, out
    assert "stage0.topos.mlir" not in out, f"rejected downstream, not by the frontend:\n{out}"
    return c.returncode, out


def test_genuine_ambiguity_is_rejected(tmp_path):
    # two methods with the same name AND the same receiver type cannot be told
    # apart: still a clean duplicate error, not a silent pick.
    dup = ("place Square {\n  side := Number\n"
           "  fun area(s: Square): Number { return s.side * s.side }\n"
           "  fun area(s: Square): Number { return s.side }\n}\n")
    rc, out = _reject(tmp_path, {"Square": dup}, "fun main(): Number { return 0 }\n")
    assert rc != 0, "same-name same-receiver methods should be rejected"
    assert "TYPE ERROR [E2001]" in out, out
    assert "duplicate top-level function" in out and "area" in out, out
    assert "cannot be distinguished" in out, out


TRI = "place Tri {\n  base := Number\n}\n"
CIRCLE_RADIUS = ("place Circle {\n  r := Number\n"
                 "  fun area(c: Circle): Number { return c.r * c.r * 3 }\n"
                 "  fun radius(c: Circle): Number { return c.r }\n}\n")


@pytest.mark.parametrize("method", ["area", "radius"],
                         ids=["overloaded_elsewhere", "unique_elsewhere"])
def test_method_absent_for_receiver_type_is_rejected(tmp_path, method):
    """`t.m()` where the receiver's place declares no `m` is a clean E2001, not a
    dispatch to some other place's `m`: both when `m` is overloaded on two other
    places (area: Square and Circle) and when exactly one other place has it
    (radius: Circle only). Tri declares no methods at all."""
    main = ("fun main(): Number {\n"
            "  be t holds .-> Tri { base 5 }\n"
            f"  return t.{method}()\n}}\n")
    rc, out = _reject(tmp_path, {"Square": SQUARE, "Circle": CIRCLE_RADIUS, "Tri": TRI}, main)
    assert rc != 0, f"t.{method}() on a Tri compiled: dispatched to another place's method"
    assert "TYPE ERROR [E2001]" in out, out
    assert f"unknown function or operation: {method}" in out, out


def test_unique_method_dispatches_on_its_own_receiver(tmp_path):
    # the control for the rejection above: the same places, the method called on
    # the place that declares it, compiles and runs (radius 2 + Tri.base 5 = 7).
    main = ("fun main(): Number {\n"
            "  be ci holds .-> Circle { r 2 }\n"
            "  be t holds .-> Tri { base 5 }\n"
            "  return ci.radius() + t.base\n}\n")
    assert _run(tmp_path, {"Square": SQUARE, "Circle": CIRCLE_RADIUS, "Tri": TRI}, main) == 7
