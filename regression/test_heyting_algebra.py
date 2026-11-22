"""The algebra of Omega is Heyting G3, and its laws are certified on the three truth values.

prelude/alg/Heyting.yon is an algebra on the carrier proposition (`carried by proposition is
algebra`): its operations are written with the connectives of Omega (`as "&&?"`, `"||?"`, `"=>?"`,
`"!?"`) and its laws are those of a Heyting algebra; Omega uses it. The certification reads each law
on every assignment of absent < unknown < present: a law of Heyting holds, the excluded middle and
the double negation do not (both fail at unknown), refused by E2101 with the counterexample.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"

pytestmark = pytest.mark.skipif(not EMIT.exists(), reason="the frontend is not built")

_TOML = ('[package]\nname = "heyting"\n\n[world.W]\nobjects = ["H"]\n\n'
         '[runtime]\nbackend = "memory"\n')

_OPS = ("  operation meet(a: H, b: H): H as \"&&?\"\n"
        "  operation join(a: H, b: H): H as \"||?\"\n"
        "  operation imp(a: H, b: H): H as \"=>?\"\n"
        "  operation neg(a: H): H as \"!?\"\n"
        "  operation top: H as \"present\"\n"
        "  operation bottom: H as \"absent\"\n")


def _emit(tmp_path, laws):
    (tmp_path / "yon.toml").write_text(_TOML)
    (tmp_path / "H.yon").write_text("place H carried by proposition is algebra {\n" + _OPS + laws + "}\n")
    (tmp_path / "Entry.yon").write_text("place Entry { fun main: Number { return 0 } }\n")
    r = subprocess.run([str(EMIT), str(tmp_path)], capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout + r.stderr


def test_the_laws_of_a_heyting_algebra_are_certified_on_the_three_truth_values(tmp_path):
    rc, out = _emit(tmp_path,
                    "  law implication_and_meet ∀a : H ∀b : H, (a &&? (a =>? b)) = (a &&? b)\n"
                    "  law implication_distributes ∀a : H ∀b : H ∀c : H, "
                    "(a =>? (b &&? c)) = ((a =>? b) &&? (a =>? c))\n"
                    "  law negation ∀a : H, (!? a) = (a =>? bottom)\n")
    assert rc == 0, out[-600:]


def test_the_excluded_middle_is_refuted_on_omega(tmp_path):
    rc, out = _emit(tmp_path, "  law excluded_middle ∀a : H, (a ||? (!? a)) = top\n")
    assert rc != 0 and "[E2101]" in out, out[-600:]
    assert ("law excluded_middle of algebra H on the carrier proposition is refuted; "
            "counterexample: a = unknown") in out, out[-600:]


def test_the_double_negation_is_refuted_on_omega(tmp_path):
    rc, out = _emit(tmp_path, "  law double_negation ∀a : H, (!? (!? a)) = a\n")
    assert rc != 0 and "[E2101]" in out, out[-600:]
    assert ("law double_negation of algebra H on the carrier proposition is refuted; "
            "counterexample: a = unknown") in out, out[-600:]


def test_the_excluded_middle_holds_on_the_decided_points(tmp_path):
    """The twin of the refusal: on present and absent the excluded middle holds; only unknown
    breaks it."""
    rc, out = _emit(tmp_path, "  law decided_middle ∀a : H, ((a = top) ||? (a = bottom)) "
                              "=>? ((a ||? (!? a)) = top)\n")
    assert rc == 0, out[-600:]


def test_omega_uses_the_algebra_of_heyting():
    text = (ROOT / "prelude" / "logic" / "Omega.yon").read_text()
    assert "place Omega carried by proposition uses algebra Heyting {" in text
    heyting = (ROOT / "prelude" / "alg" / "Heyting.yon").read_text()
    assert "place Heyting carried by proposition is algebra {" in heyting
    assert "excluded" not in heyting.split("place Heyting", 1)[1], "the excluded middle is no law of Heyting"
