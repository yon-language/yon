"""`a + b` of two values of text is their concatenation at run time, not only
where the compiler computes it: the operator lowers to the concatenation of the
runtime, never to the sum of the two handles."""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")


def _exit(tmp_path: Path, top: str, body: str, places: dict | None = None) -> int:
    proj = tmp_path / "proj"
    proj.mkdir(parents=True)
    objs = ", ".join(f'"{n}"' for n in (places or {}))
    (proj / "yon.toml").write_text('[package]\nname = "concat"\n\n'
                                   + (f"[world.W]\nobjects = [{objs}]\n\n" if places else "")
                                   + '[runtime]\nbackend = "memory"\n')
    for n, src in (places or {}).items():
        (proj / f"{n}.yon").write_text(src)
    (proj / "Entry.yon").write_text("place Entry {\n" + top + "fun main: Number {\n" + body + "\n}\n}\n")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True, text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    return subprocess.run([str(exe)], capture_output=True, timeout=30).returncode


_HELLO = 'fun hello: Text { return "hel" + "lo" }\n'


def test_the_sum_of_two_strings_known_only_at_run_time_is_their_concatenation(tmp_path):
    body = '  return if Text.equal(hello + hello, "hellohello") and Text.length(hello) == 5 then 42 else 1'
    assert _exit(tmp_path, _HELLO, body) == 42


def test_the_empty_string_is_the_unit_of_the_concatenation(tmp_path):
    top = _HELLO + 'fun none: Text { return "" }\n'
    body = ('  a := none + hello\n'
            '  b := hello + none\n'
            '  c := none + none\n'
            '  return if Text.equal(a, "hello") and Text.equal(b, "hello")'
            ' and Text.length(c) == 0 then 42 else 1')
    assert _exit(tmp_path, top, body) == 42


def test_a_long_string_concatenates_whole(tmp_path):
    # two thousand characters, built by doubling at run time
    top = ("fun doubled(s: Text, k: Number): Text {\n"
           "  return if k == 0 then s else doubled(s + s, k - 1)\n}\n")
    body = ('  long := doubled("abcdefghij", 7)\n'
            '  both := long + long\n'
            '  return if Text.length(long) == 1280 and Text.length(both) == 2560'
            ' and Text.char_at(both, 1281) == 98 then 42 else 1')
    assert _exit(tmp_path, top, body) == 42


def test_a_concatenation_in_a_loop_keeps_every_piece(tmp_path):
    body = ('  mut s := ""\n'
            '  for every x in List.cons(1, List.cons(2, List.cons(3, List.empty))) { s <- s + "ab" }\n'
            '  return if Text.equal(s, "ababab") then 42 else 1')
    assert _exit(tmp_path, "", body) == 42


def test_a_lambda_whose_parameter_is_text_by_its_use_concatenates(tmp_path):
    # the parameters have no annotation: the `+` waits for their type, and it
    # is text once the program is checked
    body = ('  twice := fun(a) => a + a\n'
            '  join := fun(a, b) => a + b\n'
            '  return if Text.equal(twice(hello), "hellohello")'
            ' and Text.length(join(hello, twice(hello))) == 15 then 42 else 1')
    assert _exit(tmp_path, _HELLO, body) == 42


def test_a_lambda_on_a_place_of_text_concatenates(tmp_path):
    name = {"Name": "place Name carried by text {\n  fun spelled(n: Name): Text { return n }\n}\n"}
    top = 'fun hello: Name { return "hel" + "lo" }\n'
    body = ('  twice := fun(a) => a + a\n'
            '  return if Text.equal(Name.spelled(twice(hello)), "hellohello") then 42 else 1')
    assert _exit(tmp_path, top, body, name) == 42


def test_a_lambda_on_numbers_still_adds(tmp_path):
    body = '  twice := fun(a) => a + a\n  return twice(21)'
    assert _exit(tmp_path, "", body) == 42
