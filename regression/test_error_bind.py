"""The bind of the monad (-) + E', inside a fun that declares `on error E'`.

`escape e`, with e a value of S + E (E <= E'), reads it as an S: the desugar
writes the match that exists, the success arm goes on with the rest and the
error arm leaves the fun through E', along the mono E -> E'. The binds are
hoisted in the order of evaluation, left to right, and the first error wins.
They stand in statements, in blocks in the tail and in the middle, in the
branches of an if, a match, an and/or, and in loops, where a loop with a
partial step is the monadic fold: the first error leaves the loop and the fun.

The compiler checks the mark both ways. A value of S + E read where S is
wanted without escape is refused with E2012; escape on a value that cannot
fail, or on the value the fun returns (which leaves as it is, along the mono
too), is refused with E2013; escape where the error has no way out (a fun
without on error, an error the signature does not contain, a lambda, a
producer, a spawn) is refused with E2011. Each refusal by code and by the
words of the reason.

Each case is a project: the expected exit code of its main, or the refusal.

Layer/kind: native / end-to-end.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

TOML = '[package]\nname = "{n}"\n\n[runtime]\nbackend = "memory"\n'
FAIL = '''fun fail(m: Text) on error DomainError: Number { return .-> DomainError { message m } }
fun check(i: Number, m: Text) on error DomainError: Number {
  return if i < 2 then i else fail(m)
}
'''
def main_of(call, ok="v", err="Text.length(d.message) + 100"):
    return f"fun main: Number {{\n  return match {call} {{ Number as v => {ok}, DomainError as d => {err} }}\n}}\n"
CASES = {}
FILES = {}


def case(name, body, expect, files=None):
    CASES[name] = (body, expect)
    if files:
        FILES[name] = files

case("ok", """fun k(x: Number) on error DomainError: Number {
  y := escape Number.sqrt(x)
  return y + 1
}
""" + main_of("k(4)"), 3)
case("err", """fun k(x: Number) on error DomainError: Number {
  y := escape Number.sqrt(x)
  return y + 1
}
""" + main_of("k(0 - 4)", err="99"), 99)
case("order", FAIL + """fun f(u: Number) on error DomainError: Number {
  return escape fail("ab") + escape fail("abcde")
}
""" + main_of("f(0)"), 102)
case("order_args", FAIL + """fun two(a: Number, b: Number): Number { return a + b }
fun f(u: Number) on error DomainError: Number {
  return two(escape fail("abc"), escape fail("abcde"))
}
""" + main_of("f(0)"), 103)
case("nested", """fun f(x: Number) on error DomainError: Number {
  return escape Number.sqrt(escape Number.sqrt(x) + 5) + 1
}
""" + main_of("f(16)"), 4)
case("arg", """fun add1(n: Number): Number { return n + 1 }
fun f(x: Number) on error DomainError: Number {
  return add1(escape Number.sqrt(x))
}
""" + main_of("f(9)"), 4)
case("tailsub", """fun h(x: Number) on error Error: Number {
  return Number.sqrt(x)
}
fun main: Number {
  return match h(0 - 4) { Number as v => v, Error as e => 7 }
}
""", 7)
case("tailsub_ok", """fun h(x: Number) on error Error: Number {
  return Number.sqrt(x)
}
fun main: Number {
  return match h(9) { Number as v => v, Error as e => 7 }
}
""", 3)
case("sub_bind", """fun h(x: Number) on error Error: Number {
  y := escape Number.sqrt(x)
  return y + 1
}
fun main: Number {
  return match h(0 - 4) { Number as v => v, Error as e => Text.length(e.message) }
}
""", len("sqrt of a negative"))
case("cell", """fun f(x: Number) on error DomainError: Number {
  mut y := escape Number.sqrt(x)
  y <- y + 1
  return y + 1
}
""" + main_of("f(4)"), 4)
case("when_mid", """fun g(x: Number) on error DomainError: Number {
  mut acc := 0
  when x > 0 { acc <- escape Number.sqrt(x) + 1 } otherwise { acc <- escape Number.sqrt(0 - x) + 2 }
  return acc + 10
}
""" + main_of("g(4)"), 13)
case("when_mid_else", """fun g(x: Number) on error DomainError: Number {
  mut acc := 0
  when x > 0 { acc <- escape Number.sqrt(x) + 1 } otherwise { acc <- escape Number.sqrt(0 - x) + 2 }
  return acc + 10
}
""" + main_of("g(0 - 9)"), 15)
case("when_mid_err", FAIL + """fun g(x: Number) on error DomainError: Number {
  mut acc := 0
  when x > 0 { acc <- escape fail("abcd") } otherwise { acc <- 1 }
  return acc + 10
}
""" + main_of("g(4)"), 104)
case("when_tail", FAIL + """fun g(x: Number) on error DomainError: Number {
  when x > 0 { return escape Number.sqrt(x) + 1 } otherwise { return escape fail("abcdef") + 1 }
}
""" + main_of("g(0 - 1)"), 106)
case("elif_bind", FAIL + """fun g(x: Number) on error DomainError: Number {
  mut acc := 0
  when x > 10 { acc <- 1 } when escape fail("abcdefg") > 0 { acc <- 2 } otherwise { acc <- 3 }
  return acc
}
""" + main_of("g(20)"), 1)
case("elif_bind_err", FAIL + """fun g(x: Number) on error DomainError: Number {
  mut acc := 0
  when x > 10 { acc <- 1 } when escape fail("abcdefg") > 0 { acc <- 2 } otherwise { acc <- 3 }
  return acc
}
""" + main_of("g(5)"), 107)
case("if_mid", """fun g(x: Number) on error DomainError: Number {
  y := if x > 0 then escape Number.sqrt(x) + 1 else 5
  return y * 2
}
""" + main_of("g(4)"), 6)
case("if_mid_else", """fun g(x: Number) on error DomainError: Number {
  y := if x > 0 then escape Number.sqrt(x) + 1 else 5
  return y * 2
}
""" + main_of("g(0 - 4)"), 10)
case("if_mid_err", FAIL + """fun g(x: Number) on error DomainError: Number {
  y := if x > 0 then escape fail("abcde") + 1 else 5
  return y * 2
}
""" + main_of("g(4)"), 105)
case("if_tail", FAIL + """fun g(x: Number) on error DomainError: Number {
  return if x > 0 then escape Number.sqrt(x) + 1 else escape fail("abc") + 1
}
""" + main_of("g(0 - 4)"), 103)
case("if_tail_ok", FAIL + """fun g(x: Number) on error DomainError: Number {
  return if x > 0 then escape Number.sqrt(x) + 1 else escape fail("abc") + 1
}
""" + main_of("g(9)"), 4)
case("match_branch", FAIL + """fun g(x: Number) on error DomainError: Number {
  y := match Number.sqrt(x) { Number as v => escape fail("abcd") + v, DomainError as d => 0 }
  return y + 1
}
""" + main_of("g(4)"), 104)
case("and_rhs", FAIL + """fun g(x: Number) on error DomainError: Boolean {
  return x > 0 && escape fail("ab") > 0
}
fun main: Number {
  return match g(0 - 1) { Boolean as b => if b then 1 else 2, DomainError as d => 100 + Text.length(d.message) }
}
""", 2)
case("and_rhs_err", FAIL + """fun g(x: Number) on error DomainError: Boolean {
  return x > 0 && escape fail("ab") > 0
}
fun main: Number {
  return match g(1) { Boolean as b => if b then 1 else 2, DomainError as d => 100 + Text.length(d.message) }
}
""", 102)
case("iter_ok", FAIL + """fun s(n: Number) on error DomainError: Number {
  mut acc := 0
  mut i := 0
  iter n do {
    acc <- acc + escape check(i, "x")
    i <- i + 1
  }
  return acc + 40
}
""" + main_of("s(2)"), 41)
case("iter_err", """fun check(i: Number) on error DomainError: Number {
  return if i < 2 then i else .-> DomainError { message if i < 3 then "ab" else "abcd" }
}
fun s(n: Number) on error DomainError: Number {
  mut acc := 0
  mut i := 0
  iter n do {
    acc <- acc + escape check(i)
    i <- i + 1
  }
  return acc + 40
}
""" + main_of("s(5)"), 102)
case("while_err", """fun check(i: Number) on error DomainError: Number {
  return if i < 2 then i else .-> DomainError { message if i < 3 then "ab" else "abcd" }
}
fun s(n: Number) on error DomainError: Number {
  mut acc := 0
  mut i := 0
  while i < n do {
    acc <- acc + escape check(i)
    i <- i + 1
  }
  return acc + 40
}
""" + main_of("s(5)"), 102)
case("while_cond_err", """fun check(i: Number) on error DomainError: Number {
  return if i < 2 then i else .-> DomainError { message if i < 3 then "ab" else "abcd" }
}
fun s(n: Number) on error DomainError: Number {
  mut acc := 0
  mut i := 0
  while escape check(i) < n do {
    acc <- acc + 1
    i <- i + 1
  }
  return acc + 40
}
""" + main_of("s(5)"), 102)
case("nested_loop_err", """fun check(i: Number) on error DomainError: Number {
  return if i < 2 then i else .-> DomainError { message if i < 3 then "ab" else "abcd" }
}
fun s(n: Number) on error DomainError: Number {
  mut acc := 0
  mut i := 0
  iter n do {
    mut j := 0
    iter n do {
      acc <- acc + escape check(i + j)
      j <- j + 1
    }
    i <- i + 1
  }
  return acc + 40
}
""" + main_of("s(3)"), 102)
case("refuse_none", """fun f(x: Number): Number {
  return escape Number.sqrt(x) + 1
}
fun main: Number { return f(4) }
""", ("E2011", ["f declares no on error", "Declare on error DomainError"]))
case("refuse_lambda", """fun f(x: Number) on error DomainError: Number {
  g := fun(y: Number) => escape Number.sqrt(y) + 1
  return g(x)
}
""" + main_of("f(4)"), ("E2011", ["inside a lambda", "carries no on error"]))
case("refuse_other", """place OtherError { this < Error }
fun f(x: Number) on error OtherError: Number {
  return escape Number.sqrt(x) + 1
}
fun main: Number { return match f(4) { Number as v => v, OtherError as e => 9 } }
""", ("E2011", ["declares on error OtherError, which does not contain DomainError"]))

case("if_tail_a", """fun g(x: Number) on error DomainError: Number {
  return if x > 0 then escape Number.sqrt(x) + 1 else 5
}
""" + main_of("g(9)"), 4)
case("if_tail_b", """fun g(x: Number) on error DomainError: Number {
  return if x > 0 then escape Number.sqrt(x) + 1 else 5
}
""" + main_of("g(0 - 9)"), 5)
case("if_tail_c", """fun g(x: Number) on error DomainError: Number {
  return if x > 0 then 3 else escape Number.sqrt(x) + 1
}
""" + main_of("g(9)"), 3)

CHK = """fun check(i: Number) on error DomainError: Number {
  return if i < 2 then i else .-> DomainError { message if i < 3 then "ab" else "abcd" }
}
"""
case("when_cond", FAIL + """fun g(x: Number) on error DomainError: Number {
  mut acc := 0
  when escape Number.sqrt(x) > 2 { acc <- 1 } otherwise { acc <- 2 }
  return acc
}
""" + main_of("g(9)"), 1)
case("when_cond_err", FAIL + """fun g(x: Number) on error DomainError: Number {
  mut acc := 0
  when escape fail("abc") > 2 { acc <- 1 } otherwise { acc <- 2 }
  return acc
}
""" + main_of("g(9)"), 103)
case("if_cond", """fun g(x: Number) on error DomainError: Number {
  return if escape Number.sqrt(x) > 2 then 1 else 2
}
""" + main_of("g(1)"), 2)
case("for_every_err", CHK + """fun s(n: Number) on error DomainError: Number {
  mut acc := 0
  lst := List.cons(0, List.cons(1, List.cons(2, List.cons(3, List.empty))))
  for every x in lst { acc <- acc + escape check(x) }
  return acc + 40
}
""" + main_of("s(0)"), 102)
case("for_every_ok", CHK + """fun s(n: Number) on error DomainError: Number {
  mut acc := 0
  lst := List.cons(0, List.cons(1, List.empty))
  for every x in lst { acc <- acc + escape check(x) }
  return acc + 40
}
""" + main_of("s(0)"), 41)
case("in_sequence_err", CHK + """fun s(n: Number) on error DomainError: Number {
  mut acc := 0
  lst := List.cons(0, List.cons(1, List.cons(2, List.cons(3, List.empty))))
  in sequence over x in lst { acc <- acc + escape check(x) }
  return acc + 40
}
""" + main_of("s(0)"), 102)
case("repeat_err", CHK + """fun s(n: Number) on error DomainError: Number {
  mut acc := 0
  mut i := 0
  repeat at most 5 times {
    acc <- acc + escape check(i)
    i <- i + 1
  }
  return acc + 40
}
""" + main_of("s(0)"), 102)
case("scope_err", FAIL + """fun s(n: Number) on error DomainError: Number {
  mut acc := 0
  scope {
    acc <- escape fail("abcde")
  }
  return acc + 40
}
""" + main_of("s(0)"), 105)
case("refuse_field", """fun mk(v: Number) on error DomainError: Pt {
  return .-> Pt { x v }
}
fun g(v: Number): Number {
  p := escape mk(v)
  return p.x
}
fun main: Number { return g(3) }
""", ("E2011", ["g declares no on error"]), {"Pt.yon": "place Pt { x Number }\n"})
case("refuse_produce", """fun f(x: Number) on error DomainError: Number {
  s := produce {
    emit escape Number.sqrt(x) + 1
  }
  return 0
}
""" + main_of("f(4)"), ("E2011", ["a producer is a process of its own"]))
case("when_and", """fun f(x: Number) on error DomainError: Number {
  mut acc := 0
  when x > 0 and escape Number.sqrt(x) > 1 { acc <- 1 }
  return acc
}
""" + main_of("f(4)"), 1)
case("when_and_err", FAIL + """fun f(x: Number) on error DomainError: Number {
  mut acc := 0
  when x > 0 and escape fail("abcd") > 1 { acc <- 1 }
  return acc
}
""" + main_of("f(4)"), 104)
case("when_and_skip", FAIL + """fun f(x: Number) on error DomainError: Number {
  mut acc := 7
  when x > 0 and escape fail("abcd") > 1 { acc <- 1 }
  return acc
}
""" + main_of("f(0 - 4)"), 7)

case("refuse_spawn", """fun f(x: Number) on error DomainError: Number {
  results := spawn in 2 parallel {
    promote escape Number.sqrt(x) + spawn_index
  }
  return 0
}
""" + main_of("f(4)"), ("E2011", ["a spawn is a process of its own"]))
# escape is the mark of the bind: without it the value is refused, and an
# escape with nothing to do is refused too
case("missing_escape", """fun f(x: Number) on error DomainError: Number {
  return Number.sqrt(x) + 1
}
""" + main_of("f(4)"), ("E2012", ["read where a Number is wanted without escape",
                               "write escape, or handle the error with match"]))
case("missing_escape_arg", """fun add1(n: Number): Number { return n + 1 }
fun f(x: Number) on error DomainError: Number {
  return add1(Number.sqrt(x))
}
""" + main_of("f(9)"), ("E2012", ["write escape, or handle the error with match"]))
case("needless_total", """fun f(x: Number) on error DomainError: Number {
  return escape x + 1
}
""" + main_of("f(4)"), ("E2013", ["there is nothing to escape", "a Number, which cannot fail"]))
case("needless_tail", """fun f(x: Number) on error DomainError: Number {
  return escape Number.sqrt(x)
}
""" + main_of("f(4)"), ("E2013", ["escape is not needed here: the fun returns the error as it is"]))
case("needless_tail_branch", FAIL + """fun f(x: Number) on error DomainError: Number {
  return if x > 0 then escape fail("ab") else 1
}
""" + main_of("f(4)"), ("E2013", ["escape is not needed here: the fun returns the error as it is"]))
# the return of a value of S + E needs no escape, along the mono too
# (check, in FAIL, is `return if i < 2 then i else fail(m)`)
case("tail_check", FAIL + """fun f(u: Number) on error DomainError: Number {
  return check(5, "abcd")
}
""" + main_of("f(0)"), 104)
# without escape and where no S is wanted, the value stays a value of S + E
case("value_kept", """fun f(x: Number): Number {
  y := Number.sqrt(x)
  return match y { Number as v => v, DomainError as d => 50 }
}
fun main: Number { return f(0 - 4) }
""", 50)


def _project(tmp_path, name):
    body, _ = CASES[name]
    d = tmp_path / name
    d.mkdir()
    toml = TOML.format(n=name)
    if name in FILES:
        objs = '", "'.join(f[:-4] for f in FILES[name])
        toml = toml.replace("[runtime]", '[world.W]\nobjects = ["' + objs + '"]\n\n[runtime]')
    (d / "yon.toml").write_text(toml)
    (d / "Entry.yon").write_text("place Entry { }\n" + body)
    for fn, txt in FILES.get(name, {}).items():
        (d / fn).write_text(txt)
    return d


@pytest.mark.parametrize("name", sorted(CASES))
def test_bind(tmp_path, name):
    _, expect = CASES[name]
    d = _project(tmp_path, name)
    exe = tmp_path / (name + ".bin")
    r = subprocess.run([str(YONC), str(d), "-o", str(exe)], capture_output=True,
                       text=True, timeout=600)
    msg = r.stdout + r.stderr
    if isinstance(expect, tuple):
        code, words = expect
        assert r.returncode != 0, msg
        assert f"[{code}]" in msg, msg
        for w in words:
            assert w in msg, (w, msg)
        return
    assert r.returncode == 0, msg
    run = subprocess.run([str(exe)], capture_output=True, text=True, timeout=60)
    assert run.returncode == expect, (run.returncode, run.stderr)
