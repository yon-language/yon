"""The kernel interpreter and a cell written inside a `scope`.

At runtime a cell captured by a scope is written through its handle, and the
write is seen after the block. The kernel models a cell write as a new binding
of its name, which does not leave the block, so it would read the old value.
eval_runner refuses such a program ("EVAL INCOMPLETE", exit 6) rather than
return that value; the refusal must see the write at any depth, inside every
form of statement the scope holds.

Layer/kind: ocaml / functional.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
EVR = ROOT / "frontend" / "_build" / "default" / "eval_runner.exe"

pytestmark = pytest.mark.skipif(not EVR.exists(), reason="eval_runner.exe missing")

_TOML = '[package]\nname = "probe"\n\n[runtime]\nbackend = "memory"\n'
_REASON = "a cell is written inside a `scope`"


def _run(tmp_path: Path, main_body: str):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML)
    (proj / "Entry.yon").write_text(
        "place Entry {\nfun main(): Number {\n" + main_body + "}\n}\n")
    return subprocess.run([str(EVR), "--trace", str(proj)],
                          capture_output=True, text=True, timeout=120)


def test_a_cell_written_in_a_loop_inside_a_scope_is_refused(tmp_path):
    r = _run(tmp_path,
             "  mut r := 0\n  scope H {\n    iter 3 do {\n      r <- r + 14\n    }\n  }\n"
             "  return r\n")
    assert r.returncode == 6, r.stdout + r.stderr
    assert "EVAL INCOMPLETE" in r.stdout and _REASON in r.stderr, r.stderr


def test_a_cell_written_in_a_branch_inside_a_scope_is_refused(tmp_path):
    r = _run(tmp_path,
             "  mut r := 0\n  scope H {\n    when r == 0 {\n      r <- 42\n    }\n  }\n"
             "  return r\n")
    assert r.returncode == 6, r.stdout + r.stderr
    assert "EVAL INCOMPLETE" in r.stdout and _REASON in r.stderr, r.stderr


def test_a_cell_written_outside_any_scope_is_still_evaluated(tmp_path):
    r = _run(tmp_path, "  mut r := 0\n  r <- 42\n  return r\n")
    assert r.returncode == 0 and "EXIT 42" in r.stdout, r.stdout + r.stderr
