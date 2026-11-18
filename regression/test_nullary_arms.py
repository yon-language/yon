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
from yon_programs import program

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_TOML = ('[package]\nname = "arms"\n\n[world.W]\nobjects = ["Chain"]\n\n'
         '[runtime]\nbackend = "memory"\n')


def _build(tmp_path: Path, entry: str):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML)
    (proj / "Chain.yon").write_text(program("test_nullary_arms/_build_1.yon"))
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
    (proj / "Chain.yon").write_text(program("test_nullary_arms/_emit_1.yon"))
    (proj / "Entry.yon").write_text(entry)
    out = tmp_path / "m"
    out.mkdir()
    subprocess.run([str(YONC), "--emit=mlir", str(proj), "-o", str(out / "x.mlir")],
                   capture_output=True, text=True, timeout=180)
    return "\n".join(p.read_text() for p in out.glob("*.mlir"))


def test_a_nullary_arm_and_a_payload_arm_are_told_apart(tmp_path):
    entry = program("test_nullary_arms/test_a_nullary_arm_and_a_payload_arm_are_told_apart_1.yon")
    assert _value(tmp_path, entry) == 42


def test_a_nullary_arm_is_a_constant_with_no_node(tmp_path):
    entry = program("test_nullary_arms/test_a_nullary_arm_is_a_constant_with_no_node_1.yon")
    mlir = _emit(tmp_path, entry)
    body = mlir[mlir.index("func.func @none"):]
    body = body[:body.index("\n  }")]
    assert "merkle_leaf" not in body and "arith.constant -2.0 : f64" in body, body


def test_a_constant_inside_a_payload_comes_back(tmp_path):
    entry = program("test_nullary_arms/test_a_constant_inside_a_payload_comes_back_1.yon")
    assert _value(tmp_path, entry) == 42


def test_a_recursive_chain_ends_in_its_nullary_arm(tmp_path):
    entry = program("test_nullary_arms/test_a_recursive_chain_ends_in_its_nullary_arm_1.yon")
    assert _value(tmp_path, entry) == 42


def test_a_wildcard_branch_after_a_nullary_arm(tmp_path):
    entry = program("test_nullary_arms/test_a_wildcard_branch_after_a_nullary_arm_1.yon")
    assert _value(tmp_path, entry) == 42
