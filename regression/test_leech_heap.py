"""LeechHeap, identity by point, written in Yon in the prelude.

The heap of the Space running now: a node is written once, at its place on
the 32-way tree over the shell, and its name is (level, generation, place).
Level 4 is the points; a node of level l covers 32^(4 - l) indices, and its
place is the first of them divided by that span. A node written where one was
already written goes to the next generation of its place, taken by
compare-and-swap on the root, so there is no counter of names. A segment of a
level is 196,560 slots (40 bytes for a point, 192 for a node above it) and
holds 196,560 / (places of the level) whole generations: generation g of
place j is in segment g / that number, at slot (g mod it) * places + j. The
slot of a point is its index on the shell.

Every test reads the Yon part only: the corpus still runs on the C heap.

Layer/kind: native / end-to-end.
"""
import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_TOML = '[package]\nname = "probe"\n\n[runtime]\nbackend = "memory"\n'
_HELPERS = (
    "fun int64(n: Int64): Int64 { return n }\n"
    "fun word64(n: Int64): Word64 { return Word64.from_int64(n) }\n"
    "/* the point of index i, the program stopped with 2 if there is none */\n"
    "fun point_at(i: Number, k: Number): Number {\n"
    "  return match LatticePoint.at_index(i) {\n"
    "    LatticePoint as p => with_point(p, k),\n"
    "    DomainError as d => 2 }\n"
    "}\n")


def _build(tmp_path: Path, main_body: str, extra: str = ""):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML)
    (proj / "Entry.yon").write_text(
        "place Entry {\nfun main: Number {\n" + main_body + "}\n" + _HELPERS + extra + "}\n")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True,
                       text=True, timeout=300)
    return r.returncode, r.stdout + r.stderr, exe


def _run(tmp_path, body, extra="", env=None):
    rc, out, exe = _build(tmp_path, body, extra)
    assert rc == 0, out
    return subprocess.run([str(exe)], capture_output=True, text=True, timeout=120,
                          env={**os.environ, **(env or {})})


def _value(tmp_path, body, extra="", env=None):
    return _run(tmp_path, body, extra, env).returncode


_NO_POINT = "fun with_point(p: LatticePoint, k: Number): Number { return k }\n"


def test_the_slot_of_a_value_is_the_index_of_its_point(tmp_path):
    # across the shell, every 997th index and the last: the value put at the
    # point is at generation 0, segment 0, slot = the MPHF index of the point
    extra = (
        "fun with_point(p: LatticePoint, k: Number): Number {\n"
        "  h := LeechHeap.put(k, p)\n"
        "  return if LeechHeap.slot(h) == LeechHeap.place_of(h)\n"
        "            and LeechHeap.segment(h) == int64(0) and LeechHeap.generation(h) == int64(0)\n"
        "            and LeechHeap.level(h) == int64(4) and LeechHeap.value(h) == k\n"
        "            and slot_number(h) == LatticePoint.index(p) then 0 else 1\n"
        "}\n"
        "/* the slot as a Number, counted up: the same bits as the index */\n"
        "fun slot_number(h: LeechHeap<Number>): Number {\n"
        "  mut n := 0\n  mut i := int64(0)\n"
        "  while i < LeechHeap.slot(h) do {\n    n <- n + 1\n    i <- i + 1\n  }\n"
        "  return n\n}\n")
    body = ("  mut bad := 0\n  mut i := 0\n"
            "  while i < 196560 do {\n"
            "    bad <- bad + point_at(i, i)\n"
            "    i <- i + 997\n  }\n"
            "  bad <- bad + point_at(196559, 7)\n"
            "  return if bad == 0 then 42 else bad\n")
    assert _value(tmp_path, body, extra) == 42


def test_a_point_already_written_takes_the_next_generation(tmp_path):
    # the first value stays where it was: write-once, nothing overwritten
    extra = (
        "fun with_point(p: LatticePoint, k: Number): Number {\n"
        "  a := LeechHeap.put(40, p)\n"
        "  b := LeechHeap.put(41, p)\n"
        "  c := LeechHeap.put(42, p)\n"
        "  return if LeechHeap.generation(a) == int64(0) and LeechHeap.generation(b) == int64(1)\n"
        "            and LeechHeap.generation(c) == int64(2)\n"
        "            and LeechHeap.segment(c) == int64(2) and LeechHeap.slot(c) == LeechHeap.slot(a)\n"
        "            and LeechHeap.next_generation(4, int64(123456)) == int64(3)\n"
        "            and LeechHeap.value(a) == 40 and LeechHeap.value(b) == 41\n"
        "            then LeechHeap.value(c) else 1\n"
        "}\n")
    assert _value(tmp_path, "  return point_at(123456, 0)\n", extra) == 42


def test_a_handle_gives_back_the_value_of_its_type(tmp_path):
    extra = (
        "fun with_point(p: LatticePoint, k: Number): Number {\n"
        "  n := LeechHeap.value(LeechHeap.put(2.5, p))\n"
        "  i := LeechHeap.value(LeechHeap.put(int64(-7), p))\n"
        "  b := LeechHeap.value(LeechHeap.put(true, p))\n"
        "  f := LeechHeap.value(LeechHeap.put(false, p))\n"
        "  return if n == 2.5 and i == int64(-7) and b and not f then 42 else 1\n"
        "}\n")
    assert _value(tmp_path, "  return point_at(5, 0)\n", extra) == 42


def test_a_node_above_the_points_is_placed_by_its_level_and_its_interval(tmp_path):
    # index 100 is in place 3 of level 3 (32 indices a node), place 0 of the
    # levels above; a segment of level 3 holds 31 generations of its 6,143
    # places, so generation 31 of place 3 is segment 1, slot 3, and
    # generation 30 is segment 0, slot 30 * 6,143 + 3
    extra = (
        "fun make_node(level: Int64, i: Int64, n: Int64): LeechHeap<Word64> {\n"
        "  mut k := int64(0)\n"
        "  while k < n do {\n    _ := LeechHeap.stage(word64(level * 100 + k))\n    k <- k + 1\n  }\n"
        "  return LeechHeap.commit(level, i, n)\n}\n")
    body = ("  r := make_node(0, 100, 24)\n"
            "  one := make_node(1, 40000, 3)\n"
            "  mut i := int64(0)\n"
            "  while i < 30 do {\n    _ := make_node(3, 100, 1)\n    i <- i + 1\n  }\n"
            "  g30 := make_node(3, 127, 2)\n"
            "  g31 := make_node(3, 96, 2)\n"
            "  return if LeechHeap.level(r) == int64(0) and LeechHeap.place_of(r) == int64(0)\n"
            "            and LeechHeap.word(r, 0) == word64(0) and LeechHeap.word(r, 23) == word64(23)\n"
            "            and LeechHeap.place_of(one) == int64(1) and LeechHeap.word(one, 2) == word64(102)\n"
            "            and LeechHeap.slot(one) == int64(1)\n"
            "            and LeechHeap.generation(g30) == int64(30) and LeechHeap.segment(g30) == int64(0)\n"
            "            and LeechHeap.slot(g30) == int64(30 * 6143 + 3)\n"
            "            and LeechHeap.generation(g31) == int64(31) and LeechHeap.segment(g31) == int64(1)\n"
            "            and LeechHeap.slot(g31) == int64(3) and LeechHeap.word(g31, 1) == word64(301)\n"
            "            and LeechHeap.word(g31, 2) == word64(0)\n"
            "            then 42 else 1\n")
    assert _value(tmp_path, body, _NO_POINT + extra) == 42


def test_the_root_fills_a_segment_and_chains_the_next(tmp_path):
    # a segment of level 0 holds 196,560 generations of the root: the
    # 196,561st is slot 0 of segment 1, read directly; the first still reads
    body = ("  _ := LeechHeap.stage(word64(-1))\n"
            "  first := LeechHeap.commit(0, 0, 1)\n"
            "  mut i := int64(1)\n"
            "  while i < 196560 do {\n"
            "    _ := LeechHeap.stage(word64(i))\n    _ := LeechHeap.commit(0, 0, 1)\n"
            "    i <- i + 1\n  }\n"
            "  _ := LeechHeap.stage(word64(196560))\n"
            "  last := LeechHeap.commit(0, 0, 1)\n"
            "  return if LeechHeap.segments(0) == int64(2) and LeechHeap.segment(last) == int64(1)\n"
            "            and LeechHeap.slot(last) == int64(0)\n"
            "            and LeechHeap.generation(last) == int64(196560)\n"
            "            and LeechHeap.word(last, 0) == word64(196560)\n"
            "            and LeechHeap.word(first, 0) == word64(-1)\n"
            "            and LeechHeap.next_generation(0, int64(196559)) == int64(196561)\n"
            "            then 42 else 1\n")
    assert _value(tmp_path, body, _NO_POINT) == 42


def test_nothing_is_written_outside_the_geometry(tmp_path):
    # a thousand distinct points take one segment of level 4 and nothing else;
    # a level never written has no segment; the name of every handle is where
    # it is: slot = (generation mod per segment) * places + place
    extra = (
        "fun with_point(p: LatticePoint, k: Number): Number {\n"
        "  h := LeechHeap.put(k, p)\n"
        "  return if LeechHeap.slot(h) == LeechHeap.place_of(h) then 0 else 1\n"
        "}\n")
    body = ("  mut bad := 0\n  mut i := 0\n"
            "  while i < 1000 do {\n    bad <- bad + point_at(i * 196, i)\n    i <- i + 1\n  }\n"
            "  _ := LeechHeap.stage(word64(1))\n"
            "  n := LeechHeap.commit(2, int64(5000), 1)\n"
            "  return if bad == 0 and LeechHeap.segments(4) == int64(1)\n"
            "            and LeechHeap.segments(3) == int64(0) and LeechHeap.segments(0) == int64(0)\n"
            "            and LeechHeap.segments(2) == int64(1) and LeechHeap.place_of(n) == int64(4)\n"
            "            and LeechHeap.next_generation(4, int64(196)) == int64(1)\n"
            "            and LeechHeap.next_generation(4, int64(197)) == int64(0)\n"
            "            then 42 else 1\n")
    assert _value(tmp_path, body, extra) == 42


def test_a_node_born_while_its_child_is_born_keeps_its_words(tmp_path):
    # the node stages its words, the child is born on top of them and taken
    # off, then the node is committed with its own words
    body = ("  _ := LeechHeap.stage(word64(11))\n  _ := LeechHeap.stage(word64(12))\n"
            "  _ := LeechHeap.stage(word64(99))\n"
            "  child := LeechHeap.commit(3, int64(0), 1)\n"
            "  parent := LeechHeap.commit(2, int64(0), 2)\n"
            "  return if LeechHeap.word(child, 0) == word64(99) and LeechHeap.word(parent, 0) == word64(11)\n"
            "            and LeechHeap.word(parent, 1) == word64(12) then 42 else 1\n")
    assert _value(tmp_path, body, _NO_POINT) == 42


_REPLICAS = (
    "/* 2,000 values at the point of index 777: the sum of the generations\n"
    "   this replica took, each value read back from its handle */\n"
    "fun with_point(p: LatticePoint, k: Number): Number {\n"
    "  mut s := 0\n  mut j := 0\n"
    "  while j < 2000 do {\n"
    "    h := LeechHeap.put(j, p)\n"
    "    s <- s + (if LeechHeap.value(h) == j then generation_number(h) else 0 - 1000000000)\n"
    "    j <- j + 1\n  }\n"
    "  return s\n}\n"
    "fun generation_number(h: LeechHeap<Number>): Number {\n"
    "  mut n := 0\n  mut i := int64(0)\n"
    "  while i < LeechHeap.generation(h) do {\n    n <- n + 1\n    i <- i + 1\n  }\n"
    "  return n\n}\n")
_REPLICAS_MAIN = (
    "  sums := spawn in 2 parallel {\n    promote point_at(777, spawn_index)\n  }\n"
    "  total := sums.fold(0, fun(a: Number, v: Number) => a + v)\n"
    "  /* on one heap the two replicas took generations 0 to 3,999 between\n"
    "     them, each once: their sum is 3999 * 4000 / 2 */\n"
    "  return if total == 7998000 then 42 else 1\n")


def test_two_replicas_writing_one_point_at_once_take_distinct_generations(tmp_path):
    rc, out, exe = _build(tmp_path, _REPLICAS_MAIN, _REPLICAS)
    assert rc == 0, out
    for _ in range(3):
        r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=120,
                           env={**os.environ, "YON_BACKEND": "shm"})
        assert r.returncode == 42, r.stderr
    # the control: with heaps of their own both replicas take 0 to 1,999
    r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=120)
    assert r.returncode == 1, r.stderr


def test_a_word_past_a_slot_is_refused(tmp_path):
    extra = ("fun with_point(p: LatticePoint, k: Number): Number {\n"
             "  x := LeechHeap.word(LeechHeap.put(40, p), 5)\n  return 1\n}\n")
    r = _run(tmp_path, "  return point_at(3, 0)\n", extra)
    assert r.returncode == 3, r.stderr
    assert "error: heap: word 5 of a value of 40 bytes" in r.stderr, r.stderr


def test_a_node_larger_than_its_slot_is_refused(tmp_path):
    body = ("  mut k := int64(0)\n"
            "  while k < 25 do {\n    _ := LeechHeap.stage(word64(k))\n    k <- k + 1\n  }\n"
            "  h := LeechHeap.commit(0, int64(0), 25)\n  return 1\n")
    r = _run(tmp_path, body, _NO_POINT)
    assert r.returncode == 3, r.stderr
    assert "error: leech: a node of 200 bytes does not fit a slot of 192 bytes" in r.stderr, r.stderr


def test_a_node_of_more_words_than_staged_is_refused(tmp_path):
    body = ("  _ := LeechHeap.stage(word64(1))\n"
            "  h := LeechHeap.commit(1, int64(0), 3)\n  return 1\n")
    r = _run(tmp_path, body, _NO_POINT)
    assert r.returncode == 3, r.stderr
    assert "error: heap: a value of 24 bytes is born from 1 staged words" in r.stderr, r.stderr


@pytest.mark.parametrize("level,index", [(5, 0), (-1, 0), (4, 196560), (0, -1)])
def test_a_node_off_the_tree_is_refused(tmp_path, level, index):
    body = (f"  h := LeechHeap.commit(int64({level}), int64({index}), 0)\n  return 1\n")
    r = _run(tmp_path, body, _NO_POINT)
    assert r.returncode == 3, r.stderr
    assert (f"error: leech: the tree over the shell has no node at level {level} "
            f"over index {index}") in r.stderr, r.stderr


def test_a_handle_of_one_type_is_not_a_handle_of_another(tmp_path):
    rc, out, _ = _build(tmp_path, "  return 1\n",
                        _NO_POINT + "fun wrong(h: LeechHeap<Number>): LeechHeap<Boolean> { return h }\n")
    assert rc != 0 and "E2001" in out, out
    assert "type mismatch: expected LeechHeap<boolean>, got LeechHeap<number>" in out, out


def test_outside_the_heap_a_handle_is_not_its_word(tmp_path):
    rc, out, _ = _build(tmp_path, "  return 1\n",
                        _NO_POINT + "fun raw(h: LeechHeap<Number>): Int64 { return h }\n")
    assert rc != 0 and "E2001" in out, out
    assert "type mismatch: expected Int64, got LeechHeap<number>" in out, out


def test_a_handle_does_not_cross_a_space(tmp_path):
    proj = tmp_path / "proj"
    (proj / "w").mkdir(parents=True)
    (proj / "yon.toml").write_text('[package]\nname = "cross"\n\n[world.W]\nspaces = ["w"]\n\n'
                                   '[runtime]\nbackend = "memory"\n')
    (proj / "w" / "Topos.yon").write_text("topos where {\n}\n")
    (proj / "w" / "Other.yon").write_text(
        "place Other {\n  fun keep(h: LeechHeap<Word64>): LeechHeap<Word64> { return h }\n}\n")
    (proj / "Entry.yon").write_text(
        "place Entry {\n  fun main(): Number {\n"
        "    _ := LeechHeap.stage(Word64.from_int64(1))\n"
        "    h := Other.keep(LeechHeap.commit(0, 0, 1))\n    return 42\n  }\n}\n")
    r = subprocess.run([str(YONC), str(proj), "-o", str(tmp_path / "exe")],
                       capture_output=True, text=True, timeout=300)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out, out
    assert ("argument 1 of Other__keep of type LeechHeap<Word64> crosses into another "
            "Space") in out, out
