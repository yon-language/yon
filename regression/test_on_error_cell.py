"""A cell returned through the injection of `on error`.

In a fun `on error E: T` the value of `return c`, with c a cell, is injected
into the arm T of T + E. The injection is of the value the cell holds: the
read comes first. Before, the injection took the name of the cell itself, so
the read met a section instead of a cell and the program stopped ("a read of
a cell that is not live").

Layer/kind: native / end-to-end.
"""
import subprocess
from pathlib import Path

import pytest
from yon_programs import program

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_TOML = '[package]\nname = "probe"\n\n[runtime]\nbackend = "memory"\n'

CASES = {
    "returned": (program("test_on_error_cell/module_1.yon"), 5),
    "after_a_loop": (program("test_on_error_cell/module_2.yon"), 10),
    "in_a_branch": (program("test_on_error_cell/module_3.yon"), 7),
}


@pytest.mark.parametrize("name", sorted(CASES))
def test_a_cell_is_read_then_injected(tmp_path, name):
    body, want = CASES[name]
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML)
    (proj / "Entry.yon").write_text("place Entry { }\n" + body)
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True,
                       text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    run = subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)
    assert run.returncode == want, (run.returncode, run.stderr)
