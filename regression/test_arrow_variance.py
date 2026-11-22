"""The arrow is contravariant in its domain and covariant in its codomain (S-Arrow; Pierce ch. 15).

A fun given where `Error -> Number` is wanted must take every Error: a `SyntaxError -> Number` would
read the line of an Error that has none, so it is refused by the checker (before, it was accepted
and stopped only by the lowering, for another reason). An `Error -> Number` where a
`SyntaxError -> Number` is wanted takes every SyntaxError, which is an Error: accepted, and it runs.
Hom(-, B) is contravariant in its first argument.
"""
import subprocess
from pathlib import Path

import pytest
from yon_programs import program

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_TOML = ('[package]\nname = "variance"\n\n[world.W]\nobjects = ["X"]\nspaces  = ["w"]\n\n'
         '[runtime]\nbackend = "memory"\n')


def _proj(tmp_path, name):
    (tmp_path / "yon.toml").write_text(_TOML)
    (tmp_path / "w").mkdir()
    (tmp_path / "w" / "SyntaxError.yon").write_text("place SyntaxError { this < Error  line Number }\n")
    (tmp_path / "w" / "Topos.yon").write_text("topos WTopos where {\n}\n")
    (tmp_path / "Entry.yon").write_text(program(f"test_arrow_variance/{name}.yon"))
    return tmp_path


def test_a_narrower_domain_where_a_wider_is_wanted_is_refused_by_the_checker(tmp_path):
    r = subprocess.run([str(EMIT), str(_proj(tmp_path, "a_narrower_domain_where_a_wider_is_wanted"))],
                       capture_output=True, text=True, timeout=120)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "TYPE ERROR [E2001]" in out, out[-600:]
    assert "apply: parameter f expects Error -> Number, got SyntaxError -> Number" in out, out[-600:]
    assert "cannot be lowered" not in out, out[-600:]


def test_a_wider_domain_where_a_narrower_is_wanted_is_accepted_and_runs(tmp_path):
    proj = _proj(tmp_path, "a_wider_domain_where_a_narrower_is_wanted")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True, text=True,
                       timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    assert subprocess.run([str(exe)], timeout=30).returncode == 10
