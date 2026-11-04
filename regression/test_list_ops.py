"""List.is_empty and List.append have a lowering, and `for every` walks a list
once.

`for every x in l` looks at each turn whether the list is empty, takes its
head and moves to its tail: one look per cell, O(n) in all. It used to
compute List.length at every turn, O(n^2). The benchmark times the loop from
inside the program (SystemOs.monotonic_ns) at n, 2n and 4n elements: four
times the elements take about four times as long, not sixteen.

Layer/kind: native / end-to-end.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_TOML = '[package]\nname = "probe"\n\n[runtime]\nbackend = "memory"\n'


def _run(tmp_path: Path, main_body: str, name="proj"):
    proj = tmp_path / name
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML)
    (proj / "Entry.yon").write_text(
        "place Entry {\nfun main: Number {\n" + main_body + "}\n}\n")
    exe = tmp_path / (name + ".exe")
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)],
                       capture_output=True, text=True, timeout=180)
    assert r.returncode == 0 and "Fatal error" not in r.stdout + r.stderr, r.stdout + r.stderr
    return subprocess.run([str(exe)], capture_output=True, text=True, timeout=120)


def test_is_empty_answers_for_the_empty_and_a_full_list(tmp_path):
    body = ("  l1 := List.cons(1, List.empty(0))\n"
            "  return (if List.is_empty(l1) then 1 else 2)"
            " + (if List.is_empty(List.empty(0)) then 40 else 0)\n")
    assert _run(tmp_path, body).returncode == 42


def test_append_puts_the_cells_of_the_first_list_before_the_second(tmp_path):
    body = ("  a := List.cons(1, List.cons(2, List.empty(0)))\n"
            "  b := List.cons(3, List.empty(0))\n"
            "  c := List.append(a, b)\n"
            "  return List.length(c) * 10 + List.head(c) * 0 + List.head(List.tail(List.tail(c)))\n")
    # length 3, third element 3
    assert _run(tmp_path, body).returncode == 33


def test_append_of_a_list_to_itself(tmp_path):
    # the inventory's probe list_append
    body = ("  l1 := List.cons(1, List.cons(2, List.empty(0)))\n"
            "  a := List.append(l1, l1)\n"
            "  return List.length(a)\n")
    assert _run(tmp_path, body).returncode == 4


def test_for_every_visits_every_cell_in_order(tmp_path):
    body = ("  l := List.cons(1, List.cons(2, List.cons(3, List.empty(0))))\n"
            "  mut acc := 0\n"
            "  for every x in l { acc <- acc * 10 + x }\n"
            "  return acc - 123 + 42\n")
    assert _run(tmp_path, body).returncode == 42


def _loop_ns(tmp_path, n):
    body = (f"  mut l := List.empty(0)\n  mut i := 0\n"
            f"  while i < {n} do {{\n    l <- List.cons(1, l)\n    i <- i + 1\n  }}\n"
            "  mut acc := 0\n"
            "  t0 := SystemOs.monotonic_ns()\n"
            "  for every x in l { acc <- acc + x }\n"
            "  t1 := SystemOs.monotonic_ns()\n"
            "  _w := SystemOs.write_output(Int64.to_text(t1 - t0))\n"
            f"  return if acc == {n} then 42 else 1\n")
    r = _run(tmp_path, body, name=f"n{n}")
    assert r.returncode == 42, (r.returncode, r.stderr)
    return int(r.stdout)


@pytest.mark.serial
def test_for_every_is_linear_in_the_length(tmp_path):
    def best(n):
        times = []
        for i in range(5):
            d = tmp_path / f"n{n}_{i}"
            d.mkdir()
            times.append(_loop_ns(d, n))
        return min(times)
    t10, t20, t40 = best(10000), best(20000), best(40000)
    # doubling the elements about doubles the time; the old O(n^2) walk
    # quadrupled it
    assert t20 / t10 < 3 and t40 / t20 < 3, (t10, t20, t40)
