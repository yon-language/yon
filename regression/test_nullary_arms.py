"""A nullary arm of a coproduct is a constant, not a node of the heap.

The value of an arm without payload (Absent, Nil, Woken) is the number
-(tag + 1); an arm with a payload is a node whose label is its tag. A node
handle is never negative, so `match` tells the two apart by the sign. A
constant inside the payload of another coproduct is held in a leaf.

Layer/kind: native / end-to-end.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_TOML = ('[package]\nname = "arms"\n\n[world.W]\nobjects = ["Chain"]\n\n'
         '[runtime]\nbackend = "memory"\n')


def _build(tmp_path: Path, entry: str):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML)
    (proj / "Chain.yon").write_text("place Chain<V> { this > Nil :U Link(V, Chain<V>) }\n")
    (proj / "Entry.yon").write_text(entry)
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)],
                       capture_output=True, text=True, timeout=180)
    assert r.returncode == 0, r.stdout + r.stderr
    return exe


def _value(tmp_path, entry):
    return subprocess.run([str(_build(tmp_path, entry))], timeout=30).returncode


def _emit(tmp_path, entry):
    proj = tmp_path / "mproj"
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML)
    (proj / "Chain.yon").write_text("place Chain<V> { this > Nil :U Link(V, Chain<V>) }\n")
    (proj / "Entry.yon").write_text(entry)
    out = tmp_path / "m"
    out.mkdir()
    subprocess.run([str(YONC), "--emit=mlir", str(proj), "-o", str(out / "x.mlir")],
                   capture_output=True, text=True, timeout=180)
    return "\n".join(p.read_text() for p in out.glob("*.mlir"))


def test_a_nullary_arm_and_a_payload_arm_are_told_apart(tmp_path):
    entry = """place Entry {
fun none(n: Number): Lookup<Number> { return Absent }
fun some(n: Number): Lookup<Number> { return hit(Found, n) }
fun main(): Number {
  return match none(1) { Found(x) => x, Absent => 40 } + match some(2) { Found(x) => x, Absent => 0 }
}
}
"""
    assert _value(tmp_path, entry) == 42


def test_a_nullary_arm_is_a_constant_with_no_node(tmp_path):
    entry = """place Entry {
fun none(n: Number): Lookup<Number> { return Absent }
fun main(): Number { return match none(1) { Found(x) => x, Absent => 42 } }
}
"""
    mlir = _emit(tmp_path, entry)
    body = mlir[mlir.index("func.func @none"):]
    body = body[:body.index("\n  }")]
    assert "merkle_leaf" not in body and "arith.constant -2.0 : f64" in body, body


def test_a_constant_inside_a_payload_comes_back(tmp_path):
    entry = """place Entry {
fun inner(n: Number): Lookup<Number> { return if n > 0 then hit(Found, n) else Absent }
fun outer(n: Number): Lookup<Lookup<Number>> { return hit(Found, inner(n)) }
fun main(): Number {
  a := match outer(0) { Found(l) => (match l { Found(x) => x, Absent => 40 }), Absent => 0 }
  b := match outer(2) { Found(l) => (match l { Found(x) => x, Absent => 0 }), Absent => 0 }
  return a + b
}
}
"""
    assert _value(tmp_path, entry) == 42


def test_a_recursive_chain_ends_in_its_nullary_arm(tmp_path):
    entry = """place Entry {
fun len(c: Chain<Number>): Number {
  return match c { Nil => 0, Link(x, rest) => 1 + len(rest) }
}
fun total(c: Chain<Number>): Number {
  return match c { Nil => 0, Link(x, rest) => x + total(rest) }
}
fun main(): Number {
  c := hit(Link, 7, hit(Link, 8, hit(Link, 24, Nil)))
  return len(c) * 0 + total(c) + 3
}
}
"""
    assert _value(tmp_path, entry) == 42


def test_a_wildcard_branch_after_a_nullary_arm(tmp_path):
    entry = """place Entry {
fun pick(n: Number): Lookup<Number> { return if n > 0 then hit(Found, n) else Absent }
fun main(): Number {
  return match pick(0) { Absent => 42, _ => 1 }
}
}
"""
    assert _value(tmp_path, entry) == 42
