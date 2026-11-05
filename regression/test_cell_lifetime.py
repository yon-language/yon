"""A cell lives as long as the block that declares it.

A block that declares a cell (a loop body, a branch) takes the mark of the
cell table on entry and gives the cells back on exit, so a cell declared in
the body of a loop lives one turn, the hidden cell of a `for every` included.
When as many cells are live as the table holds, making one stops the program
with a sentence and exit code 3: no write can land in another cell.

Layer/kind: native / end-to-end.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_TOML = '[package]\nname = "probe"\n\n[runtime]\nbackend = "memory"\n'


def _build(tmp_path: Path, source: str):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML)
    (proj / "Entry.yon").write_text(source)
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)],
                       capture_output=True, text=True, timeout=180)
    assert r.returncode == 0, r.stdout + r.stderr
    return exe


def _run(tmp_path, source):
    return subprocess.run([str(_build(tmp_path, source))], capture_output=True,
                          text=True, timeout=120)


_CELL_CAP_ALIAS = """place Entry {
fun main: Number {
  mut i := 0
  mut bad := 0
  iter 1100 do {
    mut t := i
    t <- 500000
    bad <- bad + (if t == 500000 then 0 else 1)
    i <- i + 1
  }
  return i
}
}
"""


def test_a_cell_in_a_loop_body_lives_one_turn(tmp_path):
    # the inventory's probe cell_cap_alias: 1100 turns, 1100 mod 256 = 76
    assert _run(tmp_path, _CELL_CAP_ALIAS).returncode == 76


def test_a_hundred_thousand_turns_with_a_cell_in_the_body(tmp_path):
    src = """place Entry {
fun main: Number {
  mut i := 0
  mut bad := 0
  while i < 100000 do {
    mut t := i * 2
    t <- t + 1
    bad <- bad + (if t == i * 2 + 1 then 0 else 1)
    i <- i + 1
  }
  return if i == 100000 and bad == 0 then 42 else 1
}
}
"""
    assert _run(tmp_path, src).returncode == 42


def test_the_hidden_cell_of_a_for_every_lives_one_turn_of_the_outer_loop(tmp_path):
    src = """place Entry {
fun main: Number {
  l := List.cons(1, List.cons(2, List.cons(3, List.empty)))
  mut total := 0
  iter 2000 do {
    for every x in l {
      total <- total + x
    }
  }
  return if total == 12000 then 42 else 1
}
}
"""
    assert _run(tmp_path, src).returncode == 42


def test_more_live_cells_than_the_table_holds_is_a_declared_refusal(tmp_path):
    src = """place Entry {
fun deep(n: Number): Number {
  mut c := n
  c <- c + 1
  return if n == 0 then c else deep(n - 1) + 0 * c
}
fun main: Number {
  return deep(1100)
}
}
"""
    r = _run(tmp_path, src)
    assert r.returncode == 3, (r.returncode, r.stderr)
    assert ("error: cell: 1024 cells are live, the most the cell table holds; "
            "a cell lives as long as the block that declares it") in r.stderr, r.stderr
