"""concat and inv are path induction (J) with refl at refl, and exist only where the ends are known.

concat : x = y -> y = z -> x = z is J on its second path, with the first as the value at refl;
inv : x = y -> y = x is J with refl as the value at refl. So the checker types a composite only when
the end of the first path and the start of the second are known and equal, in one carrier: a path
given as a bare `Path` has no ends to meet, and its composite or its inverse is refused by the
checker, with its words, not later by the lowering for another reason. The kernel computes what J
computes and nothing more: concat(p, refl) is p, inv(refl a) is refl a; the left unit and the
involution are paths between paths, proved by J, not computations.
"""
import subprocess
from pathlib import Path

import pytest
from yon_programs import program

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_TOML = '[package]\nname = "paths"\n\n[runtime]\nbackend = "memory"\n'


def _build(tmp_path, name):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML)
    (proj / "Entry.yon").write_text(program(f"test_path_algebra/{name}.yon"))
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True, text=True,
                       timeout=300)
    return r.returncode, r.stdout + r.stderr, exe


def _refused(tmp_path, name, *words):
    rc, out, _ = _build(tmp_path, name)
    assert rc != 0 and "TYPE ERROR [E2001]" in out, out
    assert "cannot be lowered" not in out, f"refused by the lowering, not by the checker:\n{out}"
    for w in words:
        assert w in out, out


_UNKNOWN_ENDS = "the end of the first and the start of the second must be known and equal"


def test_a_composite_with_a_path_of_unknown_ends_is_refused(tmp_path):
    _refused(tmp_path, "concat_with_a_path_of_unknown_ends", "concat: the paths do not compose",
             _UNKNOWN_ENDS)


def test_a_composite_of_two_paths_of_unknown_ends_is_refused_by_the_checker(tmp_path):
    _refused(tmp_path, "concat_of_two_paths_of_unknown_ends", "concat: the paths do not compose",
             _UNKNOWN_ENDS, "Path · Path")


def test_the_inverse_of_a_path_of_unknown_ends_is_refused_by_the_checker(tmp_path):
    _refused(tmp_path, "inv_of_a_path_of_unknown_ends", "inv: the ends of the path must be known")


def test_paths_whose_ends_meet_compose_and_run(tmp_path):
    rc, out, exe = _build(tmp_path, "concat_of_paths_whose_ends_meet")
    assert rc == 0, out
    assert subprocess.run([str(exe)], timeout=30).returncode == 44


def test_the_computations_of_j_are_definitional(tmp_path):
    """concat(p, refl) = p and inv(refl a) = refl a hold by `clear`: they are J at refl."""
    rc, out, _ = _build(tmp_path, "the_computations_of_j")
    assert rc == 0, out


@pytest.mark.parametrize("name", ["the_left_unit_is_no_computation", "the_involution_is_no_computation"])
def test_a_law_of_the_groupoid_is_a_path_not_a_computation(tmp_path, name):
    """concat(refl, q) = q and inv(inv(q)) = q are proved by J, not by `clear`."""
    _refused(tmp_path, name, "type mismatch")
