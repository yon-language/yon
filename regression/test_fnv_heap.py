"""FnvHeap, identity by content, written in Yon in the prelude.

The heap of the Space running now: a value is put once, by its type (the tag)
and its bytes, and the same tag with the same bytes answers the same handle
on the whole chain of segments. A value of FnvHeap<V> is the handle of a V:
reading it gives back that V. The handle is (segment, slot) in one word,
segment * 2^18 + slot, read directly. A value is born on a stack: its words
are staged on top of the values being born before it, and its commit takes
them off. The replicas of a Space share the heap; a publication holds the
lock of the root, taken by compare-and-swap.

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
_INT64 = "fun int64(n: Int64): Int64 { return n }\n"


def _build(tmp_path: Path, main_body: str, extra: str = ""):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML)
    (proj / "Entry.yon").write_text(
        "place Entry {\nfun main: Number {\n" + main_body + "}\n" + _INT64 + extra + "}\n")
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


def test_the_same_value_put_twice_is_one_handle(tmp_path):
    body = ("  t := Word64.from_int64(7)\n"
            "  a := FnvHeap.put(40, t)\n  b := FnvHeap.put(40, t)\n  c := FnvHeap.put(41, t)\n"
            "  same := FnvHeap.handle_word(a) == FnvHeap.handle_word(b)\n"
            "  other := FnvHeap.handle_word(a) != FnvHeap.handle_word(c)\n"
            "  return if same and other then FnvHeap.value(a) + 2 else 1\n")
    assert _value(tmp_path, body) == 42


def test_a_handle_gives_back_the_value_of_its_type(tmp_path):
    # a Number, an Int64, a Boolean: each read back as what it was put as
    body = ("  t := Word64.from_int64(3)\n"
            "  n := FnvHeap.value(FnvHeap.put(2.5, t))\n"
            "  i := FnvHeap.value(FnvHeap.put(int64(-7), t))\n"
            "  b := FnvHeap.value(FnvHeap.put(true, t))\n"
            "  f := FnvHeap.value(FnvHeap.put(false, t))\n"
            "  return if n == 2.5 and i == int64(-7) and b and not f then 42 else 1\n")
    assert _value(tmp_path, body) == 42


def test_the_same_bytes_with_two_types_are_two_handles(tmp_path):
    body = ("  w := Word64.from_int64(258)\n"
            "  a := FnvHeap.put(w, Word64.from_int64(7))\n"
            "  b := FnvHeap.put(w, Word64.from_int64(8))\n"
            "  return if FnvHeap.handle_word(a) != FnvHeap.handle_word(b)\n"
            "            and FnvHeap.tag(b) == Word64.from_int64(8) then 42 else 1\n")
    assert _value(tmp_path, body) == 42


def test_a_last_byte_that_is_zero_is_a_byte_of_the_value(tmp_path):
    # eight bytes, and the same eight followed by a zero byte: two values,
    # each of its exact length
    body = ("  t := Word64.from_int64(7)\n  w := Word64.from_int64(258)\n"
            "  _ := FnvHeap.stage(w)\n  e8 := FnvHeap.commit(8, t)\n"
            "  _ := FnvHeap.stage(w)\n  _ := FnvHeap.stage(Word64.from_int64(0))\n"
            "  e9 := FnvHeap.commit(9, t)\n"
            "  return if FnvHeap.handle_word(e8) != FnvHeap.handle_word(e9)\n"
            "            and FnvHeap.length(e8) == 8 and FnvHeap.length(e9) == 9\n"
            "            and FnvHeap.handle_word(e8) == FnvHeap.handle_word(FnvHeap.put(w, t))\n"
            "         then 42 else 1\n")
    assert _value(tmp_path, body) == 42


def test_the_bytes_past_the_length_are_not_part_of_the_value(tmp_path):
    # three bytes staged in a word that has more: the bytes past the third
    # are not the value's, so the two are one value
    body = ("  t := Word64.from_int64(7)\n"
            "  _ := FnvHeap.stage(Word64.from_int64(16909060))\n  a := FnvHeap.commit(3, t)\n"
            "  _ := FnvHeap.stage(Word64.from_int64(151126788))\n  b := FnvHeap.commit(3, t)\n"
            "  return if FnvHeap.handle_word(a) == FnvHeap.handle_word(b)\n"
            "            and FnvHeap.word(a, 0) == Word64.from_int64(131844) then 42 else 1\n")
    assert _value(tmp_path, body) == 42


def test_a_child_born_while_its_node_is_born_does_not_overwrite_it(tmp_path):
    body = ("  t := Word64.from_int64(7)\n  w := Word64.from_int64(258)\n"
            "  _ := FnvHeap.stage(w)\n"
            "  _ := FnvHeap.stage(Word64.from_int64(5))\n"
            "  c := FnvHeap.commit(8, Word64.from_int64(8))\n"
            "  _ := FnvHeap.stage(FnvHeap.handle_word(c))\n"
            "  p := FnvHeap.commit(16, t)\n"
            "  return if FnvHeap.word(p, 0) == w and FnvHeap.word(p, 1) == FnvHeap.handle_word(c)\n"
            "            and FnvHeap.word(c, 0) == Word64.from_int64(5) and FnvHeap.length(p) == 16\n"
            "         then 42 else 1\n")
    assert _value(tmp_path, body) == 42


def test_a_value_of_16_mb_takes_a_segment_of_its_own(tmp_path):
    # 2^21 words, larger than the payload area of a segment (6.3 MB): a
    # segment sized on it; put again, the same handle
    stage = ("  mut {v} := int64(0)\n"
             "  while {v} < 2097152 do {{\n"
             "    _ := FnvHeap.stage(Word64.from_int64({v}))\n"
             "    {v} <- {v} + 1\n  }}\n")
    body = ("  t := Word64.from_int64(9)\n" + stage.format(v="i")
            + "  big := FnvHeap.commit(16777216, t)\n" + stage.format(v="j")
            + "  again := FnvHeap.commit(16777216, t)\n"
            "  return if FnvHeap.length(big) == 16777216\n"
            "            and FnvHeap.word(big, 2097151) == Word64.from_int64(2097151)\n"
            "            and FnvHeap.handle_word(big) == FnvHeap.handle_word(again)\n"
            "            and FnvHeap.handle_word(big) == Word64.from_int64(262144)\n"
            "            and FnvHeap.segments() == 2 then 42 else 1\n")
    assert _value(tmp_path, body) == 42


def test_a_chain_of_segments_is_read_directly_by_its_handles(tmp_path):
    # past the 196,560 slots of the first segment: the 200,001st value is
    # slot 3,440 of segment 1, its handle 2^18 + 3,440, read without walking
    # the chain; the first value is still the same handle
    body = ("  t := Word64.from_int64(9)\n"
            "  first := FnvHeap.put(Word64.from_int64(0), t)\n"
            "  mut i := int64(1)\n"
            "  while i < 200000 do {\n"
            "    _ := FnvHeap.put(Word64.from_int64(i), t)\n"
            "    i <- i + 1\n  }\n"
            "  last := FnvHeap.put(Word64.from_int64(200000), t)\n"
            "  return if FnvHeap.segments() == 2\n"
            "            and FnvHeap.handle_word(last) == Word64.from_int64(262144 + 3440)\n"
            "            and FnvHeap.value(last) == Word64.from_int64(200000)\n"
            "            and FnvHeap.value(first) == Word64.from_int64(0)\n"
            "            and FnvHeap.handle_word(FnvHeap.put(Word64.from_int64(0), t))\n"
            "                == FnvHeap.handle_word(first) then 42 else 1\n")
    assert _value(tmp_path, body) == 42


_REPLICAS = (
    "/* the handles of v for v in [1, 3000], put forward (r = 0) or backward,\n"
    "   each weighted by v: the same sum on every replica only if they share\n"
    "   the heap and its deduplication */\n"
    "fun weighted(r: Number): Word64 {\n"
    "  t := Word64.from_int64(11)\n"
    "  mut s := Word64.zero\n"
    "  mut k := int64(0)\n"
    "  while k < 3000 do {\n"
    "    v := if r == 0 then k + 1 else 3000 - k\n"
    "    h := FnvHeap.handle_word(FnvHeap.put(Word64.from_int64(v), t))\n"
    "    s <- s + h * Word64.from_int64(v)\n"
    "    k <- k + 1\n  }\n"
    "  return s\n}\n")
_REPLICAS_MAIN = (
    "  sums := spawn in 2 parallel {\n    promote weighted(spawn_index)\n  }\n"
    "  total := sums.fold(Word64.zero, fun(a: Word64, v: Word64) => a + v)\n"
    "  mine := weighted(0)\n"
    "  return if total == mine + mine then 42 else 1\n")


def test_two_replicas_publishing_at_once_share_one_heap(tmp_path):
    # the replicas put the same values in opposite orders at the same time;
    # on shared heaps every replica, and the parent after them, answers the
    # same handle for each value
    rc, out, exe = _build(tmp_path, _REPLICAS_MAIN, _REPLICAS)
    assert rc == 0, out
    for _ in range(3):
        r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=120,
                           env={**os.environ, "YON_BACKEND": "shm"})
        assert r.returncode == 42, r.stderr
    # the control: with heaps of their own the replicas disagree
    r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=120)
    assert r.returncode == 1, r.stderr


def test_a_value_born_of_more_bytes_than_staged_is_refused(tmp_path):
    r = _run(tmp_path, ("  _ := FnvHeap.stage(Word64.from_int64(1))\n"
                        "  h := FnvHeap.commit(16, Word64.from_int64(1))\n  return 1\n"))
    assert r.returncode == 3, r.stderr
    assert "error: heap: a value of 16 bytes is born from 1 staged words" in r.stderr, r.stderr


def test_a_word_past_a_value_is_refused(tmp_path):
    r = _run(tmp_path, ("  h := FnvHeap.put(40, Word64.from_int64(1))\n"
                        "  w := FnvHeap.word(h, 3)\n  return 1\n"))
    assert r.returncode == 3, r.stderr
    assert "error: heap: word 3 of a value of 8 bytes" in r.stderr, r.stderr


def test_a_handle_of_one_type_is_not_a_handle_of_another(tmp_path):
    rc, out, _ = _build(tmp_path, "  return 1\n",
                        "fun wrong(h: FnvHeap<Number>): FnvHeap<Boolean> { return h }\n")
    assert rc != 0 and "E2001" in out, out
    assert "type mismatch: expected FnvHeap<Boolean>, got FnvHeap<Number>" in out, out


def test_outside_the_heap_a_handle_is_not_its_word(tmp_path):
    rc, out, _ = _build(tmp_path, "  return 1\n",
                        "fun raw(h: FnvHeap<Number>): Int64 { return h }\n")
    assert rc != 0 and "E2001" in out, out
    assert "type mismatch: expected Int64, got FnvHeap<Number>" in out, out


def test_outside_the_heap_no_word_becomes_a_value(tmp_path):
    rc, out, _ = _build(tmp_path, "  return FnvHeap.value_of(Word64.zero)\n")
    assert rc != 0 and "E2001" in out, out
    assert ("FnvHeap.value_of is internal to FnvHeap: it is part of how FnvHeap is "
            "built, reachable only from the funs of FnvHeap") in out, out


def test_a_handle_does_not_cross_a_space(tmp_path):
    proj = tmp_path / "proj"
    (proj / "w").mkdir(parents=True)
    (proj / "yon.toml").write_text('[package]\nname = "cross"\n\n[world.W]\nspaces = ["w"]\n\n'
                                   '[runtime]\nbackend = "memory"\n')
    (proj / "w" / "Topos.yon").write_text("topos where {\n}\n")
    (proj / "w" / "Other.yon").write_text(
        "place Other {\n  fun keep(h: FnvHeap<Number>): FnvHeap<Number> { return h }\n}\n")
    (proj / "Entry.yon").write_text(
        "place Entry {\n  fun main(): Number {\n"
        "    h := Other.keep(FnvHeap.put(40, Word64.from_int64(1)))\n    return 42\n  }\n}\n")
    r = subprocess.run([str(YONC), str(proj), "-o", str(tmp_path / "exe")],
                       capture_output=True, text=True, timeout=300)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out, out
    assert ("argument 1 of Other__keep of type FnvHeap<Number> crosses into another "
            "Space") in out, out


def test_a_law_of_an_algebra_is_not_given(tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text('[package]\nname = "alg"\n\n[world.W]\nobjects = ["Plus"]\n\n'
                                   '[runtime]\nbackend = "memory"\n')
    (proj / "Plus.yon").write_text(
        "place Plus is algebra {\n"
        "  operation plus(a: Plus, b: Plus): Plus as \"+\"\n"
        "  law commutative ∀a : Plus ∀b : Plus, a + b = b + a is given\n}\n")
    (proj / "Entry.yon").write_text("place Entry {\n  fun main: Number { return 42 }\n}\n")
    r = subprocess.run([str(YONC), str(proj), "-o", str(tmp_path / "exe")],
                       capture_output=True, text=True, timeout=300)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out, out
    assert ("law commutative of the algebra Plus is given: a law of an algebra is "
            "certified on each model") in out, out


def test_an_import_does_not_take_a_name_of_the_heaps_house(tmp_path):
    # `feed` imported from another Space; the heap's own fun of that name
    # stays the heap's, and the heap answers
    proj = tmp_path / "proj"
    (proj / "Orders").mkdir(parents=True)
    (proj / "Billing").mkdir()
    (proj / "yon.toml").write_text(
        '[package]\nname = "x"\n[runtime]\nbackend = "memory"\n'
        '[world.Commerce]\nspaces = ["Orders", "Billing"]\nobjects = ["Order", "Account"]\n')
    (proj / "Orders" / "Order.yon").write_text("place Order { id Text }\nimport Mod::feed from Billing\n")
    (proj / "Orders" / "Topos.yon").write_text("topos OrdersCat where {\n}\n")
    (proj / "Billing" / "Account.yon").write_text("place Account { balance Number }\n")
    (proj / "Billing" / "Topos.yon").write_text("topos BillingCat where {\n}\n")
    (proj / "Entry.yon").write_text(
        "place Entry { }\nfun main(): Number {\n"
        "  return FnvHeap.value(FnvHeap.put(40, Word64.from_int64(1))) + 2\n}\n")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True,
                       text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    assert subprocess.run([str(exe)], capture_output=True, timeout=30).returncode == 42
