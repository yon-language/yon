"""Lowering defects found while writing the heap in Yon, each with its fix.

- The 0 of a negative literal (-e is 0 - e) stood at no location; admitted
  as an Int64 it made every other literal at no location an Int64 (the count
  of `repeat`, the bound of a stream's loop), and the program no longer
  compiled.
- The point of 1 (`star`) after other statements was never read: a term
  checks against the terminal whatever it is, so its site was not the
  point's.
- A fun answering the terminal was erased whole when its call looked pure,
  and a call looked pure when the callee declared no effect, even if its
  body reached the operating system: purity is now closed along the calls.
- The calls of a house's own funs inside `c <- e` and inside `iter` were
  not addressed to the house.
- An Int64 a fun answers from a cell came back as the cell's double.
- A local of a fun named as a fun of the program was dropped, and its uses
  reached the fun.
- A term checked against 1 was never typed: the arguments of `return f(..)`
  in a fun answering 1 were neither checked against the parameters nor given
  their literals' sites.
- A cell holding a Boolean gave invalid MLIR: its i1 went into the f64 slot
  of the cell unconverted, and came back from it as an f64.
- A let of a pure fun answering 1 with no parameters (`_ := f()`) failed in
  the emitter: the fun's body is absorbed to the point of 1, and the let
  that binds it in the program's chain was taken for a call of a lambda.

Layer/kind: native / end-to-end.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")


def _run(tmp_path: Path, entry: str, files=None, objects=()):
    proj = tmp_path / "proj"
    proj.mkdir()
    world = ('[world.W]\nobjects = [' + ", ".join(f'"{o}"' for o in objects) + ']\n\n'
             if objects else "")
    (proj / "yon.toml").write_text('[package]\nname = "probe"\n\n' + world
                                   + '[runtime]\nbackend = "memory"\n')
    (proj / "Entry.yon").write_text(entry)
    for name, text in (files or {}).items():
        (proj / name).write_text(text)
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True,
                       text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    return subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)


def test_a_negative_int64_literal_leaves_the_other_literals_as_they_are(tmp_path):
    r = _run(tmp_path, (
        "place Entry {\n"
        "fun main(): Number {\n"
        "  mut acc := 0\n"
        "  repeat at most 3 times { acc <- acc + 2 }\n"
        "  return if neg() == int64(-5) then acc + 36 else 1\n"
        "}\n"
        "fun neg(): Int64 { return -5 }\n"
        "fun int64(n: Int64): Int64 { return n }\n"
        "}\n"))
    assert r.returncode == 42, r.stderr


def test_the_point_of_one_after_other_statements_is_the_point(tmp_path):
    r = _run(tmp_path, (
        "place Entry {\n"
        "fun main(): Number {\n"
        "  _ := done(1)\n"
        "  return 42\n"
        "}\n"
        "fun done(n: Int64): Unit {\n"
        "  m := n + 1\n"
        "  return star\n"
        "}\n"
        "}\n"))
    assert r.returncode == 42, r.stderr


def test_a_fun_answering_one_through_a_call_that_writes_is_not_erased(tmp_path):
    r = _run(tmp_path, (
        "place Entry {\n"
        "fun main(): Number {\n"
        "  _ := say()\n"
        "  return 42\n"
        "}\n"
        "fun shout(): Unit {\n"
        "  _ := SystemOs.write_output(\"heard\\n\")\n"
        "  return star\n"
        "}\n"
        "fun say(): Unit { return shout() }\n"
        "}\n"))
    assert r.returncode == 42, r.stderr
    assert r.stdout.count("heard") == 1, r.stdout


def test_the_house_names_its_funs_inside_a_write_and_an_iteration(tmp_path):
    # and the Int64 the fun answers from its cell is that Int64
    r = _run(tmp_path, (
        "place Entry {\n"
        "fun main(): Number {\n"
        "  return if Counter.run() == Counter.expected() then 42 else 1\n"
        "}\n"
        "}\n"),
        files={"Counter.yon": (
            "place Counter {\n"
            "  fun run(): Int64 {\n"
            "    mut x := start()\n"
            "    iter 3 do { x <- x + step() }\n"
            "    return x\n"
            "  }\n"
            "  fun expected(): Int64 { return 42 }\n"
            "  internal fun start(): Int64 { return 30 }\n"
            "  internal fun step(): Int64 { return 4 }\n"
            "}\n")},
        objects=("Counter",))
    assert r.returncode == 42, r.stderr


def test_a_local_named_as_a_fun_of_the_program_is_the_local(tmp_path):
    r = _run(tmp_path, (
        "place Entry {\n"
        "fun main(): Number { return twice(21) }\n"
        "fun twice(n: Number): Number {\n"
        "  w := n * 2\n"
        "  return w\n"
        "}\n"
        "fun w(): Number { return 1 }\n"
        "}\n"))
    assert r.returncode == 42, r.stderr


def test_the_arguments_of_a_call_answering_one_are_checked(tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text('[package]\nname = "probe"\n\n[runtime]\nbackend = "memory"\n')
    (proj / "Entry.yon").write_text(
        "place Entry {\n"
        "fun main(): Number { return 1 }\n"
        "fun outer(): Unit { return say(\"text\") }\n"
        "fun say(n: Int64): Unit { return star }\n"
        "}\n")
    r = subprocess.run([str(YONC), str(proj), "-o", str(tmp_path / "exe")],
                       capture_output=True, text=True, timeout=300)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out, out
    assert "parameter n expects Int64" in out, out


def test_a_boolean_cell_holds_its_boolean(tmp_path):
    # written, negated in a loop, read in a condition; a cell of the same name
    # holding a number, later in the same fun, is read as its number
    r = _run(tmp_path, (
        "place Entry {\n"
        "fun main(): Number {\n"
        "  mut b := true\n"
        "  mut n := 0\n"
        "  while n < 3 do {\n"
        "    b <- not b\n"
        "    n <- n + 1\n"
        "  }\n"
        "  return if b then 1 else other() + flag(false)\n"
        "}\n"
        "fun flag(x: Boolean): Number {\n"
        "  mut c := x\n"
        "  c <- c or true\n"
        "  return if c then 2 else 0\n"
        "}\n"
        "fun other(): Number {\n"
        "  mut b := 40\n"
        "  b <- b + 0\n"
        "  return b\n"
        "}\n"
        "}\n"))
    assert r.returncode == 42, r.stderr


def test_a_pure_fun_answering_one_with_no_parameters_is_called(tmp_path):
    # its body is absorbed to the point of 1; the let that binds it in the
    # program's chain is no call of it
    r = _run(tmp_path, (
        "place Entry {\n"
        "fun main(): Number {\n"
        "  _ := nothing()\n"
        "  x := nothing()\n"
        "  return 42\n"
        "}\n"
        "fun nothing(): Unit { return star }\n"
        "}\n"))
    assert r.returncode == 42, r.stderr
