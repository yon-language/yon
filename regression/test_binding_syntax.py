"""A value is defined with `:=`; a cell is declared with `mut` and written
with `<-`; mutability shows where it is born (Antonio, 2026-10-23).

Before, `be x := e` declared a name and a later `x = e` silently promoted it
to a cell: reading `be x := 5` did not say whether x was a value or a cell.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_TOML = '[package]\nname = "probe"\n\n[runtime]\nbackend = "memory"\n'


def _build(tmp_path: Path, main_body: str):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML)
    (proj / "Entry.yon").write_text(
        "place Entry {}\nfun main(): Number {\n" + main_body + "}\n")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)],
                       capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout + r.stderr, exe


def _value(tmp_path, body):
    rc, out, exe = _build(tmp_path, body)
    assert rc == 0, out
    return subprocess.run([str(exe)], timeout=30).returncode


def test_a_value_is_defined_without_be(tmp_path):
    assert _value(tmp_path, "  x := 1 + 2\n  return x\n") == 3


def test_a_cell_is_declared_mut_and_written_with_the_arrow(tmp_path):
    assert _value(tmp_path, "  mut c := 1\n  c <- c + 1\n  return c\n") == 2


def test_a_cell_written_in_a_loop(tmp_path):
    body = ("  mut total := 0\n  mut k := 0\n  while k < 5 do {\n"
            "    total <- total + k\n    k <- k + 1\n  }\n  return total\n")
    assert _value(tmp_path, body) == 10


def test_writing_a_value_is_refused(tmp_path):
    rc, out, _ = _build(tmp_path, "  x := 1\n  x <- 2\n  return x\n")
    assert rc != 0 and "[E2008]" in out and "Fatal error" not in out, out
    assert "mut x :=" in out, out


def test_be_is_a_clean_syntax_error(tmp_path):
    rc, out, _ = _build(tmp_path, "  be x := 1\n  return x\n")
    assert rc != 0 and "[E1001]" in out and "Fatal error" not in out, out


def test_the_old_assignment_is_a_clean_syntax_error(tmp_path):
    rc, out, _ = _build(tmp_path, "  mut c := 1\n  c = 2\n  return c\n")
    assert rc != 0 and "[E1001]" in out and "Fatal error" not in out, out


def test_shadowing_in_a_nested_scope_stays(tmp_path):
    # a nested scope may define the name again; the outer value is untouched
    body = ("  x := 5\n  mut k := 0\n  while k < 1 do {\n"
            "    x := 100\n    k <- k + 1\n  }\n  return x\n")
    assert _value(tmp_path, body) == 5


def test_a_second_definition_in_one_scope_is_refused(tmp_path):
    rc, out, _ = _build(tmp_path, "  x := 1\n  x := 2\n  return x\n")
    assert rc != 0 and "[E2001]" in out and "already bound" in out, out
