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


def test_genuine_ambiguity_is_rejected(tmp_path):
    # two methods with the same name AND the same receiver type cannot be told
    # apart: still a clean duplicate error, not a silent pick.
    dup = ("place Square {\n  side := Number\n"
           "  fun area(s: Square): Number { return s.side * s.side }\n"
           "  fun area(s: Square): Number { return s.side }\n}\n")
    root = _make(tmp_path, {"Square": dup}, "fun main(): Number { return 0 }\n")
    c = subprocess.run([str(YONC), str(root), "-o", str(tmp_path / "bin")],
                       capture_output=True, text=True, timeout=120)
    assert c.returncode != 0, "same-name same-receiver methods should be rejected"
