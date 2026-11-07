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
        "place Entry {\nfun plus(a: Number, b: Number): Number { return a + b }\n"
        "fun main: Number {\n" + main_body + "}\n}\n")
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


def test_a_cell_read_between_two_writes_gives_the_last_write(tmp_path):
    r = _run(tmp_path, "  mut r := 0\n  r <- 40\n  x := r\n  r <- x + 2\n  return r\n")
    assert r.returncode == 0 and "EXIT 42" in r.stdout, r.stdout + r.stderr


def test_a_loop_in_a_fun_of_the_prelude_that_main_reaches_is_refused(tmp_path):
    # Land.witness searches with `while` and `for every`: the reducer would
    # unfold it as it unfolds the program's own funs and lose the loop.
    r = _run(tmp_path,
             "  m := Generated.gen(Generated.generated_by(plus, HashSet.empty), 3)\n"
             "  return if Land.reach(m, 3) then 42 else 0\n")
    assert r.returncode == 6, r.stdout + r.stderr
    assert "EVAL INCOMPLETE" in r.stdout, r.stdout
    assert "main reaches `Land__witness`" in r.stderr and "loop / produce / spawn / wire" in r.stderr, r.stderr


def test_a_cell_written_in_a_branch_is_refused(tmp_path):
    # The reducer keeps the write inside the branch: after it, r would read 5.
    r = _run(tmp_path,
             "  mut r := 5\n  when r == 5 {\n    r <- 42\n  } otherwise {\n    r <- 9\n  }\n"
             "  return r\n")
    assert r.returncode == 6, r.stdout + r.stderr
    assert "EVAL INCOMPLETE" in r.stdout, r.stdout
    assert "main reaches `main`, whose body writes a cell inside a block" in r.stderr, r.stderr
