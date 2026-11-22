"""A variable is a slot of the frame of its fun, not a cell of a table of the runtime.

`mut x := e` is a slot of the activation of the fun that declares it, allocated at its entry and
gone with it: no table, no bound on how many variables live, nothing given back at the end of a
block. A variable made in a loop takes its one slot again at each turn, so the stack does not
grow with the turns; a recursion has a slot per activation; a lambda over a variable reads it
through its address while it stays in its block (the mobility judgment keeps it there).
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")


def _run(tmp_path, entry):
    (tmp_path / "yon.toml").write_text('[package]\nname = "frame"\n\n[runtime]\nbackend = "memory"\n')
    (tmp_path / "Entry.yon").write_text(entry)
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(tmp_path), "-o", str(exe)], capture_output=True, text=True,
                       timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    return exe, subprocess.run([str(exe)], capture_output=True, text=True, timeout=60)


def test_a_variable_made_in_a_loop_of_a_million_turns(tmp_path):
    """The table of the runtime held at most 1024 live cells; a slot per variable has no bound."""
    exe, r = _run(tmp_path, "place Entry {\n  fun main: Number {\n    mut i := 0\n    mut s := 0\n"
                            "    while i < 1000000 do {\n      mut t := i\n      t <- t + 1\n"
                            "      s <- s + 1\n      i <- t\n    }\n"
                            "    return if s == 1000000 then 42 else 1\n  }\n}\n")
    assert r.returncode == 42, (r.returncode, r.stderr)


def test_a_slot_per_activation_of_a_recursion(tmp_path):
    exe, r = _run(tmp_path, "place Entry {\n  fun go(n: Number): Number {\n    mut a := n\n"
                            "    a <- a - 1\n    return if a > 0 then go(a) else 42\n  }\n"
                            "  fun main: Number { return go(100000) }\n}\n")
    assert r.returncode == 42, (r.returncode, r.stderr)


def test_a_lambda_reads_a_variable_of_its_block(tmp_path):
    exe, r = _run(tmp_path, "place Entry {\n  fun twice(f: Number -> Number, x: Number): Number { return f(f(x)) }\n"
                            "  fun main: Number {\n    mut k := 20\n    k <- k + 0\n"
                            "    return twice(fun(y: Number) => y + k, 2)\n  }\n}\n")
    assert r.returncode == 42, (r.returncode, r.stderr)


def test_the_executable_calls_no_table_of_cells(tmp_path):
    exe, r = _run(tmp_path, "place Entry {\n  fun main: Number {\n    mut x := 1\n    x <- x + 41\n"
                            "    return x\n  }\n}\n")
    assert r.returncode == 42, (r.returncode, r.stderr)
    syms = subprocess.run(["nm", str(exe)], capture_output=True, text=True).stdout
    assert "yon_rt_space_make" not in syms and "yon_rt_space_mark" not in syms, syms[-400:]
