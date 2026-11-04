"""SystemOs, the face of the operating system, and the rule that heap code
allocates nothing.

SystemOs (prelude/sys) is the one place whose primitives reach the kernel:
memory, shared memory, the wait on a word, the clocks, the arguments,
the standard streams, processes. A Region is memory the kernel gave, an opaque handle. What
the language can see is wrong before asking is a DomainError. Each public
face has a probe here.

Heap code is the code of the houses that own a primitive writing the raw
memory of a region (FnvHeap, LeechHeap in prelude/heap); it allocates
nothing (E2009). The refusal is checked by its code and its words, on a copy
of the prelude whose FnvHeap has funs with bodies.

Layer/kind: native / end-to-end.
"""
import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_TOML = '[package]\nname = "probe"\n\n[runtime]\nbackend = "memory"\n'


def _build(tmp_path: Path, main_body: str, env=None, name="proj"):
    proj = tmp_path / name
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML)
    (proj / "Entry.yon").write_text(
        "place Entry {\nfun main: Number {\n" + main_body + "}\n}\n")
    exe = tmp_path / (name + ".exe")
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True,
                       text=True, timeout=180, env=env)
    return r.returncode, r.stdout + r.stderr, exe


def _run(tmp_path, body, args=()):
    rc, out, exe = _build(tmp_path, body)
    assert rc == 0, out
    return subprocess.run([str(exe), *args], capture_output=True, text=True, timeout=30)


def _value(tmp_path, body, args=()):
    return _run(tmp_path, body, args).returncode


def _region(expr: str, ok: str) -> str:
    """main matching a Region | DomainError: `ok` is the answer with the region r."""
    return (f"  return match {expr} {{\n"
            f"    Region as r => ({ok}),\n"
            f"    DomainError as d => 200 }}\n")


# ─── Memory ─────────────────────────────────────────────────────────────


def test_map_gives_a_region_of_the_asked_words(tmp_path):
    assert _value(tmp_path, _region("SystemOs.map(40)",
                                    "if SystemOs.words(r) == 40 then 42 else 1")) == 42


def test_unmap_gives_the_region_back(tmp_path):
    body = _region("SystemOs.map(4096)", "if SystemOs.unmap(r) == star then 7 else 1")
    assert _value(tmp_path, body) == 7


def test_a_region_of_no_word_is_a_domain_error(tmp_path):
    assert _value(tmp_path, _region("SystemOs.map(0)", "1")) == 200


# ─── The regions of the heaps of the Space ─────────────────────────────


def test_the_space_has_a_region_for_each_heap_made_when_it_starts(tmp_path):
    # the FnvHeap's root (64 words of state, a directory of 65,600 parts),
    # the LeechHeap's root (64 words of state, the next generation of each
    # of the 202,902 places of the tree over the shell)
    body = ("  f := SystemOs.fnv_heap_region\n  l := SystemOs.leech_heap_region\n"
            "  return if SystemOs.words(f) == 65664 and SystemOs.words(l) == 202966"
            " and f != l then 42 else 1\n")
    assert _value(tmp_path, body) == 42


def test_the_region_of_the_space_is_the_same_at_every_ask(tmp_path):
    body = ("  return if SystemOs.fnv_heap_region == SystemOs.fnv_heap_region"
            " and SystemOs.leech_heap_region == SystemOs.leech_heap_region"
            " then 42 else 1\n")
    assert _value(tmp_path, body) == 42


def test_heap_code_asks_for_its_region_without_allocating(tmp_path):
    env = _prelude_with_heap_funs(
        tmp_path,
        "  fun probe_first(): Word64 { return read_word(SystemOs.fnv_heap_region, 0) }\n")
    rc, out, _ = _build(tmp_path, "  return 1\n", env=env)
    assert rc == 0 and "E2009" not in out, out


# ─── Shared memory ──────────────────────────────────────────────────────


def test_shared_map_twice_under_one_name_is_one_region_of_the_same_words(tmp_path):
    name = f"yon_t{os.getpid() % 100000}"
    body = (f"  a := SystemOs.shared_map(\"{name}\", 8)\n"
            f"  b := SystemOs.shared_map(\"{name}\", 8)\n"
            "  return match a {\n"
            "    Region as ra => (match b {\n"
            "      Region as rb => (if SystemOs.words(ra) == 8 and SystemOs.words(rb) == 8\n"
            f"                       then (match SystemOs.shared_remove(\"{name}\") {{\n"
            "                         Boolean as gone => (if gone then 42 else 3),\n"
            "                         DomainError as d => 4 })\n"
            "                       else 2),\n"
            "      DomainError as d => 5 }),\n"
            "    DomainError as d => 6 }\n")
    assert _value(tmp_path, body) == 42


def test_shared_remove_of_an_absent_name_answers_false(tmp_path):
    body = ("  return match SystemOs.shared_remove(\"yon_never_made_x\") {\n"
            "    Boolean as gone => (if gone then 1 else 42),\n"
            "    DomainError as d => 2 }\n")
    assert _value(tmp_path, body) == 42


def test_a_shared_memory_name_with_a_slash_is_a_domain_error(tmp_path):
    # the name says nothing of a kernel: a '/' is not one of its characters
    assert _value(tmp_path, _region("SystemOs.shared_map(\"/x\", 8)", "1")) == 200


# ─── The wait on a word ─────────────────────────────────────────────────


def _wait(call: str, arm: str) -> str:
    """main matching a wait on a fresh region: 42 when it ends by `arm`."""
    ends = {"Woken": "1", "NotExpected": "2", "TimedOut": "3"}
    domain = "4"
    if arm in ends:
        ends[arm] = "42"
    else:
        domain = "42"
    inner = ", ".join(f"{a} => {v}" for a, v in ends.items())
    return _region("SystemOs.map(4)",
                   f"match {call} {{ WaitResult as w => (match w {{ {inner} }}), "
                   f"DomainError as d => {domain} }}")


def test_wait_on_a_word_that_is_not_the_expected_value_returns_at_once(tmp_path):
    # a fresh region holds zeroes
    assert _value(tmp_path, _wait("SystemOs.wait(r, 0, 1)", "NotExpected")) == 42


def test_wait_for_on_the_expected_value_runs_out_of_time(tmp_path):
    t0 = time.monotonic()
    assert _value(tmp_path, _wait("SystemOs.wait_for(r, 0, 0, 20000000)", "TimedOut")) == 42
    assert time.monotonic() - t0 >= 0.02


def test_wake_with_no_waiter_wakes_nobody(tmp_path):
    body = _region("SystemOs.map(4)",
                   "match SystemOs.wake(r, 1) { Number as n => (if n == 0 then 42 else 1), "
                   "DomainError as d => 200 }")
    assert _value(tmp_path, body) == 42


def test_a_word_outside_the_region_is_a_domain_error(tmp_path):
    assert _value(tmp_path, _wait("SystemOs.wait(r, 4, 0)", "DomainError as d")) == 42


def test_a_timeout_of_zero_is_a_domain_error(tmp_path):
    assert _value(tmp_path, _wait("SystemOs.wait_for(r, 0, 0, 0)", "DomainError as d")) == 42


# ─── Clocks ─────────────────────────────────────────────────────────────


def test_the_monotonic_clock_does_not_go_back(tmp_path):
    body = ("  a := SystemOs.monotonic_ns()\n  b := SystemOs.monotonic_ns()\n"
            "  return if b >= a and a > 0 then 42 else 1\n")
    assert _value(tmp_path, body) == 42


def test_the_wall_clock_is_after_2025(tmp_path):
    # 2025-01-01T00:00:00Z in nanoseconds
    body = "  return if SystemOs.wall_ns() > 1735689600000000000 then 42 else 1\n"
    assert _value(tmp_path, body) == 42


# ─── Arguments ──────────────────────────────────────────────────────────


def test_arg_count_counts_the_program_and_its_arguments(tmp_path):
    assert _value(tmp_path, "  return SystemOs.arg_count\n", args=("a", "bc")) == 3


def test_arg_gives_the_argument_text(tmp_path):
    body = ("  return match SystemOs.arg(2) {\n"
            "    Text as t => String.length(t),\n"
            "    DomainError as d => 200 }\n")
    assert _value(tmp_path, body, args=("a", "hello")) == 5


def test_an_argument_past_the_last_is_a_domain_error(tmp_path):
    body = ("  return match SystemOs.arg(9) {\n"
            "    Text as t => 1,\n"
            "    DomainError as d => 200 }\n")
    assert _value(tmp_path, body) == 200


# ─── The standard streams ──────────────────────────────────────────────


def test_write_output_puts_the_text_on_the_standard_output(tmp_path):
    r = _run(tmp_path, "  return SystemOs.write_output(\"ciao\")\n")
    assert r.returncode == 4 and r.stdout == "ciao" and r.stderr == "", (r.returncode, r.stdout, r.stderr)


def test_write_error_puts_the_text_on_the_standard_error(tmp_path):
    r = _run(tmp_path, "  return SystemOs.write_error(\"guai\")\n")
    assert r.returncode == 4 and r.stderr == "guai" and r.stdout == "", (r.returncode, r.stdout, r.stderr)


# ─── Processes ──────────────────────────────────────────────────────────


def test_process_id_is_the_id_the_kernel_gave(tmp_path):
    rc, out, exe = _build(tmp_path, "  return SystemOs.process_id\n")
    assert rc == 0, out
    p = subprocess.Popen([str(exe)])
    assert p.wait(timeout=30) == p.pid % 256


def _exists(pid_expr: str) -> str:
    return (f"  return match SystemOs.process_exists({pid_expr}) {{\n"
            "    Boolean as there => (if there then 42 else 7),\n"
            "    DomainError as d => 200 }\n")


def test_the_running_process_exists(tmp_path):
    assert _value(tmp_path, _exists("SystemOs.process_id")) == 42


def test_a_process_that_ended_does_not_exist(tmp_path):
    child = subprocess.Popen(["true"])
    child.wait(timeout=30)
    assert _value(tmp_path, _exists(str(child.pid))) == 7


def test_a_process_id_of_zero_is_a_domain_error(tmp_path):
    assert _value(tmp_path, _exists("0")) == 200


def test_terminate_ends_the_process(tmp_path):
    child = subprocess.Popen(["sleep", "30"])
    try:
        body = (f"  return match SystemOs.terminate({child.pid}) {{\n"
                "    Boolean as ended => (if ended then 42 else 7),\n"
                "    DomainError as d => 200 }\n")
        assert _value(tmp_path, body) == 42
        assert child.wait(timeout=10) != 0
    finally:
        if child.poll() is None:
            child.kill()


# ─── Heap code allocates nothing ────────────────────────────────────────


def _prelude_with_heap_funs(tmp_path: Path, funs: str) -> dict:
    """A copy of the prelude whose FnvHeap holds `funs` too; the directory is
    named prelude, which is what makes its files the prelude's."""
    pre = tmp_path / "copy" / "prelude"
    shutil.copytree(ROOT / "prelude", pre)
    heap = pre / "heap" / "FnvHeap.yon"
    text = heap.read_text().rstrip()
    assert text.endswith("}")
    heap.write_text(text[:-1] + funs + "}\n")
    return {**os.environ, "YON_PRELUDE": str(pre)}


def test_heap_code_that_writes_a_text_literal_is_refused(tmp_path):
    env = _prelude_with_heap_funs(
        tmp_path, '  fun label(r: Region): Text { return "slot" }\n')
    rc, out, _ = _build(tmp_path, "  return 1\n", env=env)
    assert rc != 0 and "[E2009]" in out and "Fatal error" not in out, out
    assert ("FnvHeap.label is the code of a heap (FnvHeap owns a primitive that "
            "writes the raw memory of its region), and a heap allocates nothing: it "
            "is where the values are put. FnvHeap.label writes a Text literal.") in out, out


def test_heap_code_reaching_an_allocation_through_its_calls_is_refused(tmp_path):
    env = _prelude_with_heap_funs(
        tmp_path,
        '  internal fun label(r: Region): Text { return "slot" }\n'
        "  internal fun probe_tag(r: Region, w: Int64): Int64 { return String.length(label(r)) + w }\n"
        "  fun probe_put(r: Region, w: Int64): Int64 { return probe_tag(r, w) }\n")
    rc, out, _ = _build(tmp_path, "  return 1\n", env=env)
    assert rc != 0 and "[E2009]" in out and "Fatal error" not in out, out
    assert ("FnvHeap.probe_put calls FnvHeap.probe_tag, which calls FnvHeap.label, which writes "
            "a Text literal.") in out, out


def test_heap_code_that_builds_a_section_is_refused(tmp_path):
    env = _prelude_with_heap_funs(
        tmp_path,
        "  fun fail(r: Region) on error DomainError: Int64 {\n"
        "    return .-> DomainError { message \"no\" }\n  }\n")
    rc, out, _ = _build(tmp_path, "  return 1\n", env=env)
    assert rc != 0 and "[E2009]" in out, out
    assert "FnvHeap.fail builds a section of DomainError (.->)." in out, out


def test_heap_code_that_reads_and_writes_words_and_computes_is_accepted(tmp_path):
    env = _prelude_with_heap_funs(
        tmp_path,
        "  fun bump(r: Region, i: Int64): Word64 {\n"
        "    w := Word64.add(Word64.mul(read_word(r, i), Word64.from_int64(31)), Word64.one)\n"
        "    _u := write_word(r, i, w)\n"
        "    return w\n  }\n")
    rc, out, exe = _build(tmp_path, "  return 1\n", env=env)
    assert rc == 0 and "E2009" not in out, out


def test_heap_code_computing_on_the_bits_of_a_word_is_accepted(tmp_path):
    # the operators on the bits of a 64-bit integer are arithmetic, not calls
    env = _prelude_with_heap_funs(
        tmp_path,
        "  fun low_byte(r: Region, i: Int64): Int64 { return (i & 255) | (i ^ i) }\n")
    rc, out, _ = _build(tmp_path, "  return 1\n", env=env)
    assert rc == 0 and "E2009" not in out, out


def test_heap_code_answering_a_boolean_and_a_nullary_arm_is_accepted(tmp_path):
    # a nullary arm is a constant, not a node: it allocates nothing
    env = _prelude_with_heap_funs(
        tmp_path,
        "  fun is_zero(r: Region, i: Int64): Boolean { return read_word(r, i) == Word64.zero }\n"
        "  fun probe_first(r: Region): Lookup<Word64> { return Absent }\n")
    rc, out, _ = _build(tmp_path, "  return 1\n", env=env)
    assert rc == 0 and "E2009" not in out, out


def test_heap_code_building_a_payload_arm_is_refused(tmp_path):
    env = _prelude_with_heap_funs(
        tmp_path,
        "  fun probe_first(r: Region): Lookup<Word64> { return read_word(r, 0) ↪ Found }\n")
    rc, out, _ = _build(tmp_path, "  return 1\n", env=env)
    assert rc != 0 and "[E2009]" in out and "Fatal error" not in out, out
    assert "FnvHeap.probe_first builds the coproduct value Found." in out, out
