"""Boolean and Omega are two places, each with its algebra, and the connectives are theirs.

Boolean is the coproduct of two points with the algebra of Boole: `and`, `or`, `not` (and `=>`,
written `not a or b`) take Booleans and give a Boolean. Omega is the subobject classifier, three
points (present, absent, unknown) of its carrier, with the algebra of Heyting G3: `&&?`, `||?`,
`!?`, `=>?`. A connective of Boolean on an Omega, or on a Number, is refused with the spelling it
asks for; the one arrow between the two places is the canonical injection Boolean -> Omega.
In G3, unknown =>? unknown is present; `not a or b` would give unknown, and is refused on Omega.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_TOML = '[package]\nname = "logic"\n\n[runtime]\nbackend = "memory"\n'


def _proj(tmp_path, body):
    (tmp_path / "yon.toml").write_text(_TOML)
    (tmp_path / "Entry.yon").write_text("place Entry {\n" + body + "}\n")
    return tmp_path


def _emit(tmp_path, body):
    r = subprocess.run([str(EMIT), str(_proj(tmp_path, body))], capture_output=True, text=True,
                       timeout=120)
    return r.returncode, r.stdout + r.stderr


def _run(tmp_path, body):
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(_proj(tmp_path, body)), "-o", str(exe)],
                       capture_output=True, text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    return subprocess.run([str(exe)], timeout=30).returncode


_DECIDE = "match decide({}) {{ Present => 42, Absent => 0, Unknown => 20 }}"


@pytest.mark.parametrize("expr, words", [
    ("p or q", "`or` is an operation of Boolean, and this operand is an Omega: on Omega it is written `||?`"),
    ("p and q", "`and` is an operation of Boolean, and this operand is an Omega: on Omega it is written `&&?`"),
    ("not p", "`not` is the negation of Boolean, and this is an Omega: on Omega it is written `!?`"),
    ("p => q", "on Omega it is written `!?` (and `a => b` is `a =>? b`)"),
])
def test_a_connective_of_boolean_on_omega_is_refused(tmp_path, expr, words):
    rc, out = _emit(tmp_path, "  fun f(p: Omega, q: Omega): Omega { return " + expr + " }\n"
                              "  fun main: Number { return 7 }\n")
    assert rc != 0 and "[E2001]" in out and words in out, out[-600:]


@pytest.mark.parametrize("expr, words", [
    ("not 0", "`not` takes a Boolean, and this is Number"),
    ("3 and 0", "`and` takes Booleans, and this operand is Number"),
    ("3 or 0", "`or` takes Booleans, and this operand is Number"),
])
def test_a_connective_of_boolean_on_a_number_is_refused(tmp_path, expr, words):
    rc, out = _emit(tmp_path, "  fun main: Number { return if " + expr + " then 1 else 2 }\n")
    assert rc != 0 and "[E2001]" in out and words in out, out[-600:]


def test_the_connectives_of_boolean_on_booleans(tmp_path):
    assert _run(tmp_path, "  fun main: Number {\n    a := 1 < 2\n    b := 2 < 1\n"
                          "    return if (a and not b) or b then 42 else 1\n  }\n") == 42


@pytest.mark.parametrize("expr, exit", [
    ("unknown =>? unknown", 42),       # a -> a is the top in G3
    ("unknown ||? !? unknown", 20),    # the excluded middle is no law of G3
    ("!? unknown", 0),                 # the pseudo-complement of unknown is absent
    ("present &&? unknown", 20),
])
def test_the_connectives_of_omega_compute_in_g3(tmp_path, expr, exit):
    assert _run(tmp_path, "  fun main: Number { return " + _DECIDE.format(expr) + " }\n") == exit


def test_boolean_enters_omega_by_the_canonical_injection(tmp_path):
    assert _run(tmp_path, "  fun lift(b: Boolean): Omega { return b }\n"
                          "  fun main: Number { return " + _DECIDE.format("lift(1 < 2)") + " }\n") == 42


def test_no_arrow_goes_from_omega_to_boolean(tmp_path):
    rc, out = _emit(tmp_path, "  fun down(p: Omega): Boolean { return p }\n"
                              "  fun main: Number { return 7 }\n")
    assert rc != 0 and "type mismatch: expected Boolean, got Omega" in out, out[-600:]


def test_the_carrier_of_omega_is_no_type_of_the_program(tmp_path):
    """`proposition` is the carrier of Omega, as `boolean` is Boolean's: written as a type, it is
    refused with the name of the place."""
    rc, out = _emit(tmp_path, "  fun f(p: proposition): Number { return 1 }\n"
                              "  fun main: Number { return 7 }\n")
    assert rc != 0 and "[E1001]" in out, out[-600:]
    assert "type `proposition` is the kernel code: write `Omega` (the prelude place)" in out, out[-600:]
