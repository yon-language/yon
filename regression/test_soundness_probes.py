"""What the checker must refuse, and what it must accept.

Every test states what the CORRECT language must do. Three shapes:

  * the property holds -> a plain test: it guards the property.
  * a wrong program is accepted, or computes a wrong value -> xfail(strict=True).
  * a right program is refused or crashes -> xfail(strict=True).

strict=True is the point: when the language comes to satisfy the property the
test XPASSes, the suite turns red, and the marker is removed on purpose. The
reason of each xfail states the property, not the defect's history.
"""
import os
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_TOML = '[package]\nname = "{name}"\n{extra}\n[runtime]\nbackend = "memory"\n'


def _project(tmp: Path, entry: str, extra: str = "", files: dict | None = None) -> Path:
    proj = tmp / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML.format(name="probe", extra=extra))
    (proj / "Entry.yon").write_text(entry)
    for rel, src in (files or {}).items():
        p = proj / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(src)
    return proj


def _compile(src: Path, out: Path, cwd: Path | None = None, timeout: int = 120):
    r = subprocess.run([str(YONC), str(src), "-o", str(out)], capture_output=True,
                       text=True, timeout=timeout, cwd=cwd)
    return r.returncode, r.stdout + r.stderr


def _run(exe: Path, cwd: Path | None = None, timeout: int = 30) -> int:
    return subprocess.run([str(exe)], capture_output=True, timeout=timeout,
                          cwd=cwd).returncode


def _compile_and_run(tmp: Path, entry: str, extra: str = "", files=None) -> int:
    proj = _project(tmp, entry, extra, files)
    rc, out = _compile(proj, tmp / "out")
    assert rc == 0, f"probe program did not compile:\n{out}"
    return _run(tmp / "out")


def _clean_rejection(rc: int, out: str, code: str, *words: str) -> bool:
    """Refused by the frontend with the stable code `code` and for the reason
    the words name - not by an uncaught OCaml exception, not by the MLIR
    verifier downstream, and not for another reason: a refusal for the wrong
    reason is no evidence."""
    assert words, "name the reason of the refusal, not only its code"
    return (rc != 0 and f"[{code}]" in out and "Fatal error: exception" not in out
            and "stage0.topos.mlir" not in out and all(w in out for w in words))


class ProbeOutcome(AssertionError):
    """The probe's own verdict: the program ran and computed the wrong thing.
    An xfail whose defect shows as a wrong result names this type in
    `raises=`, so a broken PRECONDITION (the probe program no longer compiles,
    a helper's plain assert) fails the test instead of passing as the expected
    failure."""


def _verdict(ok: bool, msg: str):
    if not ok:
        raise ProbeOutcome(msg)


# --- strict positivity ---------------------------------------------------------

_BAD = """\
place Bad { f Bad -> Number }
place Entry {
  fun omega(b: Bad): Number { g := b.f  return g(b) }
  fun boom(n: Number): Number { return omega(.-> Bad { f omega }) }
  fun force(n: Number): boom(n) = 0 { return clear }
  fun main: Number { return 0 }
}
"""


def test_checker_terminates_on_negative_place(tmp_path):
    """The checker never diverges. The place construction `.-> Bad {...}` is
    opaque to the reducer, so the self-application is never unfolded (a
    TimeoutExpired would mean it diverged). Terminating is not enough: the
    program asks `clear` to prove boom(n) = 0, which is false, so the
    checker must REJECT it, cleanly (a stable [E....] code, no uncaught OCaml
    exception)."""
    proj = _project(tmp_path, _BAD, '\n[world.W]\nobjects = ["Bad"]\n')
    rc, out = _compile(proj, tmp_path / "out", timeout=60)
    assert "Fatal error" not in out, f"the checker crashed instead of deciding:\n{out}"
    assert _clean_rejection(rc, out, 'E2001', 'expected Id_Number(boom(n), _code), got Id_Number(boom(n), boom(n))'), (
        f"boom(n) = 0 is false, so `clear` must be rejected with a diagnostic "
        f"code (rc={rc}):\n{out}")


@pytest.mark.xfail(strict=True, reason="a place that occurs negatively in its own "
                   "fields, `place Bad { f Bad -> Number }`, is not strictly positive")
def test_negative_place_rejected(tmp_path):
    entry = "place Bad { f Bad -> Number }\nplace Entry { fun main: Number { return 0 } }\n"
    proj = _project(tmp_path, entry, '\n[world.W]\nobjects = ["Bad"]\n')
    rc, out = _compile(proj, tmp_path / "out")
    assert _clean_rejection(rc, out, 'E2001', 'Bad'), out


# --- parametricity of generics ------------------------------------------------

def test_no_field_access_on_abstract_t(tmp_path):
    entry = """\
place Entry {
  fun bad<T>(x: T): Number { return x.foo }
  fun main: Number { return 0 }
}
"""
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out, 'E2001', 'the abstract type T admits no operation'), out


@pytest.mark.parametrize("body,reason", [
    ("7", "expected T, got Number"),
    ("x + 1", "got T and Number"),
    ('"hello"', "expected T, got Text")])
def test_t_to_t_is_the_identity(tmp_path, body, reason):
    entry = f"""\
place Entry {{
  fun notid<T>(x: T): T {{ return {body} }}
  fun main: Number {{ return notid(5) }}
}}
"""
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", reason), out


@pytest.mark.parametrize("body", [
    # refused today as "unknown function or operation: x": a parameter is not
    # looked up as a callee, so the refusal names the wrong reason
    pytest.param("x(1)", marks=pytest.mark.xfail(strict=True,
        reason="calling a value of the abstract type T is refused because T admits no operation")),
    "x.foo", "fst(x)"])
def test_an_abstract_t_admits_no_operation(tmp_path, body):
    """Inside a generic function a T can only be passed on."""
    entry = f"""\
place Entry {{
  fun bad<T>(x: T): Number {{ return {body} }}
  fun main: Number {{ return 0 }}
}}
"""
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", "the abstract type T admits no operation"), out


def test_an_abstract_t_admits_no_literal_test(tmp_path):
    """A test against a literal would reveal T: refused."""
    entry = """\
place Entry {
  fun peek<T>(x: T): Number {
    mut r := 0
    when x is 5 { r <- 1 }
    return r
  }
  fun main: Number { return peek(5) }
}
"""
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out, 'E2001', 'pattern literal of type Number', 'scrutinee type T'), out


def test_a_generic_call_is_typed_at_its_instance(tmp_path):
    """identity(41) is a Number, first("ok", 0) a Text; a generic function
    passed as a value fits the arrow it is passed to."""
    entry = """\
place Entry {
  fun identity<T>(x: T): T { return x }
  fun first<A, B>(x: A, y: B): A { return x }
  fun apply(f: Number -> Number, x: Number): Number { return f(x) }
  fun main: Number {
    return identity(40) + Text.length(first("ok", 0)) + apply(identity, 0)
  }
}
"""
    assert _compile_and_run(tmp_path, entry) == 42


def test_a_generic_result_is_not_another_type(tmp_path):
    """The instance chosen by the arguments is the type of the result."""
    entry = """\
place Entry {
  fun identity<T>(x: T): T { return x }
  fun main: Number { return Text.length(identity(5)) }
}
"""
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out, 'E2001', 'Text__length: parameter s expects Text, got Number'), out


# --- Int64 precision -----------------------------------------------------------

def test_int64_exact_past_2_53_through_list(tmp_path):
    entry = """\
place Entry {
  fun big: Int64 { return Int64.ipow_ok(2, 53) + 1 }
  fun first(xs: List<Int64>): Int64 { return match List.head(xs) { Found as v => v, Absent => 0 } }
  fun main: Number {
    xs := List.cons(big, List.empty)
    return if Int64.is_odd(first(xs)) then 1 else 0
  }
}
"""
    rc = _compile_and_run(tmp_path, entry)
    _verdict(rc == 1, f"2^53+1 came back even (exit {rc}, expected 1)")


@pytest.mark.slow
def test_int64_exact_across_spaces(tmp_path):
    (tmp_path / "echo.yon").write_text("""\
place Entry {
  fun odd_remote(x: Int64): Number { return if Int64.is_odd(x) then 1 else 0 }
  fun main: Number { return 0 }
}
""")
    (tmp_path / "client.yon").write_text("""\
import echo::odd_remote from Echo

place Entry {
  fun main: Number {
    a := odd_remote(Int64.ipow_ok(2, 40) + 1)
    b := odd_remote(Int64.ipow_ok(2, 52) + 1)
    mut c := odd_remote(Int64.ipow_ok(2, 53) + 1)
    return a + 2 * b + 4 * c
  }
}
""")
    rc, out = _compile(tmp_path / "echo.yon", tmp_path / "Echo_srv", cwd=tmp_path)
    assert rc == 0, out
    rc, out = _compile(tmp_path / "client.yon", tmp_path / "client", cwd=tmp_path)
    assert rc == 0, out
    rc = _run(tmp_path / "client", cwd=tmp_path)
    _verdict(rc == 7, f"parity bits a + 2b + 4c = {rc}, expected 7 (all three odd)")


# --- Int64 is Z/2^64 at runtime, as the ring laws prove it ------------------------

def test_int64_is_exact_past_2_53(tmp_path):
    entry = """\
place Entry {
  fun big: Int64 { return 9007199254740992 + 1 }
  fun base: Int64 { return 9007199254740992 }
  fun main: Number { return if big - base == 1 then 1 else 0 }
}
"""
    assert _compile_and_run(tmp_path, entry) == 1


def test_int64_overflow_is_a_declared_refusal(tmp_path):
    """Int64 is the integers in [-2^63, 2^63): MAX + 1 and MIN - 1 are no
    Int64, so the program stops with the reason (exit 3), never wraps."""
    msg = ("error: arithmetic: an Int64 operation leaves [-2^63, 2^63); "
           "its result is no Int64 (the ring that wraps is Word64)")
    for expr in ("Int64.max_value + 1", "Int64.min_value - 1",
                 "Int64.two_to_62 * 2"):
        d = tmp_path / str(abs(hash(expr)))
        d.mkdir()
        entry = ("place Entry {\n  fun main: Number {\n"
                 f"    n := {expr}\n"
                 "    return if n > 0 then 1 else 2\n  }\n}\n")
        src = d / "Entry.yon"
        src.write_text(entry)
        rc, out = _compile(src, d / "p", cwd=d)
        assert rc == 0, out
        r = subprocess.run([str(d / "p")], capture_output=True, text=True, timeout=30)
        assert r.returncode == 3 and msg in r.stderr, (expr, r.returncode, r.stderr)


def test_int64_in_range_is_exact(tmp_path):
    entry = """\
place Entry {
  fun main: Number {
    a := if Int64.max_value - 1 + 1 == Int64.max_value then 1 else 0
    b := if Int64.min_value + 1 - 1 == Int64.min_value then 10 else 0
    mut c := if Int64.ipow_ok(2, 62) - 1 + Int64.ipow_ok(2, 62) == Int64.max_value then 100 else 0
    return a + b + c
  }
}
"""
    assert _compile_and_run(tmp_path, entry) == 111


def test_int64_crosses_every_uniform_slot_bit_for_bit(tmp_path):
    """Int64.MAX, Int64.MIN and 2^53+1 come back equal through a List, a
    coproduct payload and a closure capture."""
    entry = """\
place IntExpr { this > Lit Int64 :U Nil }
place Entry {
  fun via_list(x: Int64): Int64 { return match List.head(List.cons(x, List.empty)) { Found as v => v, Absent => 0 } }
  fun wrap(x: Int64): IntExpr { return x ↪ Lit }
  fun unwrap(e: IntExpr): Int64 { return match e { Lit as n => n, Nil => 0 } }
  fun adder(k: Int64): Int64 -> Int64 { return fun(y: Int64) => k + y }
  fun same(x: Int64): Number {
    f := adder(x)
    a := if via_list(x) == x then 1 else 0
    mut c := if unwrap(wrap(x)) == x then a else 0
    return if f(0) == x then c else 0
  }
  fun main: Number {
    return same(Int64.max_value) + same(Int64.min_value) * 10
         + same(9007199254740992 + 1) * 100
  }
}
"""
    rc = _compile_and_run(tmp_path, entry, '\n[world.W]\nobjects = ["IntExpr"]\n')
    assert rc == 111, f"Int64 through the slots: {rc}"


def test_an_integer_literal_past_2_53_is_exact(tmp_path):
    """9007199254740993 at Int64 is that integer (odd), and the largest
    literal is Int64.MAX."""
    entry = """\
place Entry {
  fun odd: Int64 { return 9007199254740993 }
  fun top: Int64 { return 9223372036854775807 }
  fun main: Number {
    a := if Int64.is_odd(odd) then 1 else 0
    return if top == Int64.max_value then a + 10 else a
  }
}
"""
    assert _compile_and_run(tmp_path, entry) == 11


@pytest.mark.xfail(strict=True, reason="a literal past Int64.MAX is refused because it "
                   "does not fit an Int64, and the refusal names it (today it falls back "
                   "to a Number and the refusal is a type mismatch)")
def test_an_integer_literal_past_int64_max_is_refused_by_its_range(tmp_path):
    over = "place Entry {\n  fun m: Int64 { return 9223372036854775808 }\n  fun main: Number { return 0 }\n}\n"
    rc, out = _compile(_project(tmp_path, over), tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", "9223372036854775808", "Int64"), out


def test_int64_to_text_writes_its_exact_digits(tmp_path):
    entry = """\
place Entry {
  fun main: Number {
    _a := Text.print(Int64.to_text(Int64.max_value))
    _b := Text.print(Int64.to_text(Int64.min_value))
    _c := Text.print(Int64.to_text(9007199254740993))
    _d := Text.print(Int64.to_text(0 - 42))
    return 0
  }
}
"""
    proj = _project(tmp_path, entry)
    rc, out = _compile(proj, tmp_path / "out")
    assert rc == 0, out
    r = subprocess.run([str(tmp_path / "out")], capture_output=True, text=True, timeout=30)
    assert r.stdout.split() == ["9223372036854775807", "-9223372036854775808",
                                "9007199254740993", "-42"], r.stdout


# --- the Widen law under overflow ----------------------------------------------

_WIDEN = """\
place Entry {
  fun lhs(a: Int32, b: Int32): Int64 { return Int32.widen_i32_i64(a + b) }
  fun rhs(a: Int32, b: Int32): Int64 { return Int32.widen_i32_i64(a) + Int32.widen_i32_i64(b) }
  fun holds_law(a: Int32, b: Int32): Number { return if lhs(a, b) == rhs(a, b) then 1 else 0 }
  fun wrapped(a: Int32, b: Int32): Number { return if a + b < 0 then 1 else 0 }
  fun main: Number { return %s(2147483647, 1) }
}
"""


def test_widen_additive_law_at_int32_max(tmp_path):
    """widen(a + b) = widen(a) + widen(b) at Int32.MAX + 1. It holds while
    Int32 is carried as f64 and never overflows; it goes red if Int32 is
    carried as a wrapping i32, where the law needs its overflow side condition
    (see the next test)."""
    assert _compile_and_run(tmp_path, _WIDEN % "holds_law") == 1


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="Int32 addition is modular: Int32.MAX + 1 "
                   "is negative, never 2147483648")
def test_int32_addition_wraps(tmp_path):
    rc = _compile_and_run(tmp_path, _WIDEN % "wrapped")
    _verdict(rc == 1, f"Int32.MAX + 1 did not wrap below 0 (exit {rc}, expected 1)")


# --- hygiene of generated names ------------------------------------------------

_LEDGER = """\
place Entry {
  fun __conto(x: Number): Number { return x + 2 }
  fun yon_rt_saldo(x: Number): Number { return x + 4 }
  fun a__b(x: Number): Number { return x + 8 }
  fun main: Number { return 0 }
}
"""


def _call_remote(tmp: Path, fn: str) -> int:
    (tmp / "ledger.yon").write_text(_LEDGER)
    (tmp / "client.yon").write_text(
        f"import ledger::{fn} from Ledger\n\n"
        f"place Entry {{\n  fun main: Number {{ return {fn}(100) }}\n}}\n")
    rc, out = _compile(tmp / "ledger.yon", tmp / "Ledger_srv", cwd=tmp)
    assert rc == 0, out
    rc, out = _compile(tmp / "client.yon", tmp / "client", cwd=tmp)
    assert rc == 0, out
    return _run(tmp / "client", cwd=tmp)


@pytest.mark.slow
def test_double_underscore_inside_name_is_exported(tmp_path):
    assert _call_remote(tmp_path, "a__b") == 108


@pytest.mark.slow
@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a user name is never confused with a "
                   "generated one: __x and yon_rt_x are exported like any function")
@pytest.mark.parametrize("fn,expected", [("__conto", 102), ("yon_rt_saldo", 104)])
def test_reserved_prefix_names_are_exported(tmp_path, fn, expected):
    rc = _call_remote(tmp_path, fn)
    _verdict(rc == expected, f"remote {fn}(100) exited {rc}, expected {expected}")


# --- out-of-range access -------------------------------------------------------

@pytest.mark.xfail(strict=True, reason="an out-of-range access is a typed failure, "
                   "never an in-band value such as 0.0 or -1")
@pytest.mark.parametrize("expr,sentinel_exit", [
    ("Vec.get(Vec.push(Vec.push(Vec.push(Vec.empty(), 10), 20), 30), 1000) + 1", 1),
    ('Text.char_at("abc", 3) + 100', 99),
    ('Text.index_of("abc", 122) + 100', 99),
])
def test_no_in_band_sentinel(tmp_path, expr, sentinel_exit):
    """A failure must be a typed value the program has to handle. Either the
    sentinel-producing program is rejected, or it no longer yields the sentinel."""
    proj = _project(tmp_path, f"place Entry {{ fun main: Number {{ return {expr} }} }}\n")
    rc, out = _compile(proj, tmp_path / "out")
    if rc != 0:
        # refused: by its own reason, the operation that can fail
        op = re.search(r"\.(\w+)\(", expr).group(1)
        assert _clean_rejection(rc, out, "E2001", op), out
    else:
        assert _run(tmp_path / "out") != sentinel_exit


# --- internal places -----------------------------------------------------------

@pytest.mark.xfail(strict=True, reason="`internal` hides a place from outside its "
                   "Space, so matching on its arms from outside is refused")
def test_internal_place_match_from_outside_rejected(tmp_path):
    entry = "place Entry { fun main: Number { return match A { A => 1, B => 2 } } }\n"
    files = {"w/Topos.yon": "topos WTopos where {\n}\n",
             "w/Secret.yon": "internal place Secret { this > A :U B }\n"}
    proj = _project(tmp_path, entry, '\n[world.W]\nobjects = ["Secret"]\nspaces  = ["w"]\n', files)
    rc, out = _compile(proj, tmp_path / "out")
    assert _clean_rejection(rc, out, 'E2001', 'internal') and "PARSE ERROR" not in out, out


# --- subobjects: `this <` -------------------------------------------------------

def test_subobject_with_incompatible_field_rejected(tmp_path):
    """The mono `this < B` is checked structurally on fields, by name and type,
    not merely declared."""
    entry = """\
place Entry {
  fun read(b: B): Number { return b.value }
  fun main: Number { a := .-> A { value "hi" }  return read(a) }
}
"""
    files = {"w/Topos.yon": "topos WTopos where {\n}\n",
             "w/B.yon": "place B { value Number }\n",
             "w/A.yon": "place A { this < B\n  value Text\n}\n"}
    proj = _project(tmp_path, entry, '\n[world.W]\nobjects = ["X"]\nspaces  = ["w"]\n', files)
    rc, out = _compile(proj, tmp_path / "out")
    assert _clean_rejection(rc, out, 'E2001', 'does not have all the fields of') and "subcontains" in out, out


# --- a cell handle must not outlive its activation --------------------------

def test_escaping_closure_over_cell(tmp_path):
    """A closure over a cell is not mobile and is stopped at the return;
    otherwise it would read another activation's cell (exit 99)."""
    entry = """\
place Entry {
  fun mk: Number -> Number { mut c := 10  c <- 20  return fun(y: Number) => y + c }
  fun user(f: Number -> Number): Number { mut d := 90  d <- 98  return f(1) }
  fun main: Number { f := mk  return user(f) }
}
"""
    proj = _project(tmp_path, entry)
    rc, out = _compile(proj, tmp_path / "out")
    # rejected at compile time, or the closure sees its own cell (20 + 1)
    assert _clean_rejection(rc, out, 'E2001', 'would outlive the call') or (rc == 0 and _run(tmp_path / "out") == 21)


# Every route out of the activation that owns a cell. The judgment must
# be conservative (never "does not escape" for a value that escapes), so each
# route the analysis could miss is a case: mutating any part of it (the lambda
# capture, the fixpoint over bindings, the walk over every expression form, the
# implicit tail through compound statements, the allocation of a cell, the
# tainted parameters at a store or on the wire) turns at least one case green.
_CELL_ESCAPES = {
    # leaving the call
    "alias": "fun mk(): Number -> Number { mut c := 10  c <- 20  g := fun(y: Number) => y + c  mut h := g  return h }",
    "field": "fun mk(): Box { mut c := 10  c <- 20  return .-> Box { f (fun(y: Number) => y + c) } }",
    "through_call": "fun idf(g: Number -> Number): Number -> Number { return g }\n"
                    "  fun mk(): Number -> Number { mut c := 10  c <- 20  return idf(fun(y: Number) => y + c) }",
    "implicit_tail": "fun mk(): Number -> Number { mut c := 10  c <- 20  g := fun(y: Number) => y + c }",
    "tail_through_when": "fun mk(): Number -> Number { mut c := 10  c <- 20  when c > 0 { g := fun(y: Number) => y + c } "
                         "otherwise { mut h := fun(y: Number) => y + c } }",
    "return_in_while": "fun mk(): Number -> Number { mut c := 10  c <- 20  g := fun(y: Number) => y + c  "
                       "while c > 0 do { return g }  return g }",
    "if_expression": "fun mk(): Number -> Number { mut c := 10  c <- 20  g := fun(y: Number) => y + c  "
                     "return if c > 0 then g else fun(y: Number) => y }",
    "match_arms": "fun mk(b: Bit): Number -> Number { mut c := 10  c <- 20  "
                  "return match b { One => fun(y: Number) => y + c, Zero => fun(y: Number) => y + c } }",
    "curried": "fun mk(): Number -> (Number -> Number) { mut c := 10  c <- 20  return fun(y: Number) => fun(z: Number) => z + c }",
    "lambda_over_alias": "fun mk(): Number -> Number { mut c := 10  c <- 20  g := fun(y: Number) => y + c  "
                         "return fun(y: Number) => g(y) }",
    "move_lambda": "fun mk(): move from P to Q { mut c := 10  c <- 20  return move(s: P) => .-> Q { v c } from P to Q }",
    "cell_holds_closure": "fun mk(): Number -> Number { mut c := 10  c <- 20  mut k := fun(y: Number) => y  "
                          "k <- fun(y: Number) => y + c  return k }",
    "assigned_after_the_return": "fun mk(): Number -> Number { mut c := 10  c <- 20  mut k := fun(y: Number) => y  mut i := 0  "
                                 "while i < 2 do { when i > 0 { return k }  k <- fun(y: Number) => y + c  i <- i + 1 }  return k }",
    "assigned_in_a_while_then_returned": "fun mk(): Number -> Number { mut c := 10  c <- 20  mut k := fun(y: Number) => y  "
                                         "mut i := 0  while i < 2 do { k <- fun(y: Number) => y + c  i <- i + 1 }  return k }",
    "alias_before_assignment": "fun mk(): Number -> Number { mut c := 10  c <- 20  mut k := fun(y: Number) => y  "
                               "mut h := fun(y: Number) => y  mut i := 0  "
                               "while i < 2 do { h <- k  k <- fun(y: Number) => y + c  i <- i + 1 }  return h }",
    "stored_before_its_assignment_in_a_while": "fun mk(): Number -> Number { mut c := 10  c <- 20  mut k := fun(y: Number) => y  "
                                               "mut out := fun(y: Number) => y  mut i := 0  "
                                               "while i < 2 do { when i > 0 { out <- k }  "
                                               "k <- fun(y: Number) => y + c  i <- i + 1 }  return out }",
    "through_a_loop_binder": "fun mk(b: Bit): Number -> Number { mut c := 10  c <- 20  mut k := fun(y: Number) => y  "
                             "l := List.cons(fun(y: Number) => y + c, List.empty)  "
                             "for every g in l { k <- g }  return k }",
    "no_declared_return": "fun mk() { mut c := 10  c <- 20  return fun(y: Number) => y + c }",
    # a cell is freed on return, whatever holds what mentions it
    "cell_captured": "fun mk(): Number -> Number { mut h := 20  h <- 21  return fun(y: Number) => y + h }",
    "cell_contents_read_out": "fun mk(): Number -> Number { mut h := fun(y: Number) => y  mut c := 10  c <- 20  "
                              "h <- fun(y: Number) => y + c  return h }",
    "cell_made_with_a_closure": "fun mk(): Number -> Number { mut c := 10  c <- 20  "
                                "mut h := fun(y: Number) => y + c  return h }",
    # handed to a helper that gives it back
    "stored_by_a_helper": "fun put(g: Number -> Number): Number -> Number { return g }\n"
                          "  fun mk(): Number -> Number { mut c := 10  c <- 20  return put(fun(y: Number) => y + c) }",
    # sent on the wire
    "wire_send": "fun mk(): Number { ch := Wire.make(4)  mut c := 10  c <- 20  "
                 "_s := Wire.send(ch, fun(y: Number) => y + c)  return 0 }",
    "wire_send_by_a_helper": "fun sendit(ch: Number, g: Number -> Number): Number { _s := Wire.send(ch, g)  return 0 }\n"
                             "  fun mk(): Number { ch := Wire.make(4)  mut c := 10  c <- 20  "
                             "return sendit(ch, fun(y: Number) => y + c) }",
}

_CELL_PLACES = ("place Box { f Number -> Number }\nplace P { v Number }\nplace Q { v Number }\n"
               "place Bit { this > One :U Zero }\n")


# A route that leaves through a `return` inside a loop is closed by structure:
# a return stands only where its body ends, so the program is refused before
# mobility is asked.
_CLOSED_BY_STRUCTURE = {"return_in_while", "assigned_after_the_return"}


_K = "mut k := fun(y: Number) => y"
_C = "mut c := 10  c <- 20"
_USE_K = "h := k  return h(1)"

# Every way a closure over a cell of a block can reach a cell that outlives the
# block. Run, the first would read a dead slot, or the slot of the next cell.
_BLOCK_ESCAPES = {
    "written_by_name": f"{_K}\n when b {{ {_C}  k <- fun(y: Number) => y + c }}\n return k(1)",
    "read_after_the_block": f"{_K}\n when b {{ {_C}  k <- fun(y: Number) => y + c }}\n {_USE_K}",
    "the_slot_taken_again": f"{_K}\n when b {{ {_C}  k <- fun(y: Number) => y + c }}\n mut d := 90  d <- 98  {_USE_K}",
    "through_a_local": f"{_K}\n when b {{ {_C}  g := fun(y: Number) => y + c  k <- g }}\n {_USE_K}",
    "through_a_cell": f"{_K}\n when b {{ {_C}  mut j := fun(y: Number) => y  j <- fun(y: Number) => y + c  k <- j }}\n {_USE_K}",
    "through_a_call": f"{_K}\n when b {{ {_C}  k <- idf(fun(y: Number) => y + c) }}\n {_USE_K}",
    "through_a_list": f"{_K}\n when b {{ {_C}  l := List.cons(fun(y: Number) => y + c, List.empty)\n"
                      f" for every g in l {{ k <- g }} }}\n {_USE_K}",
    "through_an_if": f"{_K}\n when b {{ {_C}  k <- if b then fun(y: Number) => y + c else fun(y: Number) => y }}\n {_USE_K}",
    "lambda_over_a_local": f"{_K}\n when b {{ {_C}  g := fun(y: Number) => y + c  k <- fun(y: Number) => g(y) }}\n {_USE_K}",
    "two_blocks_deep": f"{_K}\n when b {{ when b {{ {_C}  k <- fun(y: Number) => y + c }} }}\n {_USE_K}",
    "in_the_other_branch": f"{_K}\n when b {{ k <- fun(y: Number) => y }} otherwise {{ {_C}  k <- fun(y: Number) => y + c }}\n {_USE_K}",
    "in_a_loop": f"{_K}\n mut i := 0\n while i < 1 do {{ {_C}  k <- fun(y: Number) => y + c  i <- i + 1 }}\n {_USE_K}",
    "a_shadow_is_another_cell": f"mut c := 1  c <- 2  {_K}\n when b {{ {_C}  k <- fun(y: Number) => y + c }}\n {_USE_K}",
    "a_middle_cell": f"mut r := 0\n when b {{ {_K}\n when b {{ {_C}  k <- fun(y: Number) => y + c }}\n h := k  r <- h(1) }}\n return r",
}

# What the rule leaves alone, with the value it computes.
_BLOCK_STAYS = {
    "a_cell_of_the_same_block": (f"mut r := 0\n when b {{ {_C}  {_K}  k <- fun(y: Number) => y + c  h := k  r <- h(1) }}\n return r", 21),
    "a_value_read_out": (f"mut r := 0\n when b {{ {_C}  g := fun(y: Number) => y + c  r <- g(1) }}\n return r", 21),
    "an_immutable_of_the_block": (f"{_K}\n when b {{ n := 5  k <- fun(y: Number) => y + n }}\n {_USE_K}", 6),
    "a_cell_never_written_is_a_value": (f"{_K}\n when b {{ mut c := 10  k <- fun(y: Number) => y + c }}\n mut d := 90  d <- 98  {_USE_K}", 11),
    "the_contents_of_a_cell_read_out": (f"{_K}\n when b {{ mut j := fun(y: Number) => y + 1  j <- fun(y: Number) => y + 2  k <- j }}\n {_USE_K}", 3),
    "same_name_in_sibling_blocks": (f"mut r := 0\n when b {{ {_C}  {_K}  k <- fun(y: Number) => y + c  h := k  r <- h(1) }}"
                                    " otherwise { mut c := 3  c <- 4  r <- c }\n return r", 21),
    "a_cell_of_a_loop_stays_in_its_turn": (f"mut r := 0  mut i := 0\n while i < 2 do {{ {_C}  {_K}  k <- fun(y: Number) => y + c  h := k  r <- r + h(1)  i <- i + 1 }}\n return r", 42),
}


def _block_entry(body: str) -> str:
    return ("place Entry {\n  fun idf(g: Number -> Number): Number -> Number { return g }\n"
            f"  fun mk(b: Boolean): Number {{ {body} }}\n"
            "  fun main: Number { return mk(true) }\n}\n")


@pytest.mark.parametrize("form", sorted(_BLOCK_ESCAPES))
def test_a_closure_over_a_cell_of_a_block_does_not_outlive_the_block(tmp_path, form):
    proj = _project(tmp_path, _block_entry(_BLOCK_ESCAPES[form]))
    rc, out = _compile(proj, tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", "outlives the block", "a cell lives as long as the block"), out


def test_a_section_holding_a_closure_over_a_cell_of_a_block_does_not_outlive_it(tmp_path):
    body = ("mut o := .-> Box { f (fun(y: Number) => y) }\n"
            f" when b {{ {_C}  o <- .-> Box {{ f (fun(y: Number) => y + c) }} }}\n return 0")
    entry = "place Box { f Number -> Number }\n" + _block_entry(body)
    proj = _project(tmp_path, entry, '\n[world.W]\nobjects = ["Box"]\n')
    rc, out = _compile(proj, tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", "`o` outlives the block"), out


@pytest.mark.parametrize("form", sorted(_BLOCK_STAYS))
def test_a_closure_that_stays_within_the_block_of_its_cell_runs(tmp_path, form):
    body, value = _BLOCK_STAYS[form]
    assert _compile_and_run(tmp_path, _block_entry(body)) == value


_MATCH_WORLD = '\n[world.W]\nobjects = ["Maybe", "Box", "Holder"]\n'


def _match_entry(body: str) -> str:
    return ("place Maybe { this > Full Number :U Empty }\nplace Box { f Number -> Number }\n"
            "place Holder { this > Has Box :U No }\n"
            "place Entry {\n"
            f"  fun mk(b: Boolean, m: Maybe): Number {{ {body} }}\n"
            "  fun main: Number { return mk(true, 21 ↪ Full) }\n}\n")


def _closure_over_binder(name: str) -> str:
    return (f"{_K}\n when b {{ {_C}\n k <- match m {{ Full as {name} => fun(y: Number) => y + {name}, "
            f"Empty => fun(y: Number) => y }} }}\n {_USE_K}")


def test_a_closure_through_a_match_binder_does_not_outlive_the_block(tmp_path):
    # the binder holds what the scrutinee holds, and the scrutinee is part of the value
    body = (f"{_K}\n when b {{ {_C}\n o := .-> Box {{ f (fun(y: Number) => y + c) }} ↪ Has\n"
            " k <- match o { Has as g => g.f, No => fun(y: Number) => y } }\n"
            f" {_USE_K}")
    proj = _project(tmp_path, _match_entry(body), _MATCH_WORLD)
    rc, out = _compile(proj, tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", "`k` outlives the block"), out


@pytest.mark.xfail(strict=True, raises=AssertionError,
                   reason="a closure over a match binder holds a value, even when the binder shadows a cell")
def test_a_closure_over_a_match_binder_that_shadows_a_cell_runs(tmp_path):
    # a refusal too many, not a hole: the walks of a value do not subtract the binders
    # of a match, and a lambda in a branch cannot capture its binder yet
    assert _compile_and_run(tmp_path, _match_entry(_closure_over_binder("c")), _MATCH_WORLD) == 22


def test_a_match_binder_that_shadows_a_written_cell_is_read_as_the_binder(tmp_path):
    # no block and no closure: the rule has nothing to say here, and the name is the binder
    body = f"{_C}\n return match m {{ Full as c => c, Empty => 0 }}"
    assert _compile_and_run(tmp_path, _match_entry(body), _MATCH_WORLD) == 21


_BINDER_IN_A_PRODUCE = {
    "directly": ("emit match m {{ Full as {b} => {b}, Empty => 0 }}", "c", 21),
    "in_a_scope": ("scope {{ emit match m {{ Full as {b} => {b}, Empty => 0 }} }}", "c", 21),
    "fields": ("emit match m {{ Full as {b} => {b} + 1, Empty => 0 }}", "c", 22),
}


@pytest.mark.parametrize("form", sorted(_BINDER_IN_A_PRODUCE))
def test_a_match_binder_inside_a_produce_is_no_read_of_the_cell_it_shadows(tmp_path, form):
    # the binder is a value of the produce: the value of the stream does not depend
    # on the cell, and the cell can change after the produce
    block, binder, value = _BINDER_IN_A_PRODUCE[form]
    block = block.format(b=binder)
    body = (f"{_C}\n s := produce {{ {block} }}\n c <- 99\n mut t := 0\n"
            " for every x in s { t <- t + x }\n return t")
    assert _compile_and_run(tmp_path, _match_entry(body), _MATCH_WORLD) == value


def test_a_read_of_a_cell_in_the_other_branch_of_a_binder_is_refused(tmp_path):
    # the binder hides the cell only in its own branch
    body = (f"{_C}\n s := produce {{ emit match m {{ Full as c => c, Empty => c }} }}\n return 0")
    rc, out = _compile(_project(tmp_path, _match_entry(body), _MATCH_WORLD), tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", "`c` is a cell declared outside the block"), out


def test_a_match_on_a_cell_inside_a_produce_is_a_read_of_the_cell(tmp_path):
    # the binder hides nothing in the scrutinee
    body = ("mut c := m  c <- 7 ↪ Full\n s := produce { emit match c { Full as c => c, Empty => 0 } }\n return 0")
    rc, out = _compile(_project(tmp_path, _match_entry(body), _MATCH_WORLD), tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", "`c` is a cell declared outside the block"), out


# Every block a statement can hold, around a store [w] and the last statement of
# the producer: a store is refused at any depth of it.
_STORE_DEPTHS = {
    "directly": "{w}  {last}",
    "when": "when b {{ {w} }}  {last}",
    "while": "while b do {{ {w} }}  {last}",
    "for_every": "for every i in List.cons(1, List.empty) {{ {w} }}  {last}",
    "in_sequence": "in sequence over i in List.cons(1, List.empty) {{ {w} }}  {last}",
    "repeat": "repeat at most 1 times {{ {w} }}  {last}",
    "repeat_otherwise": "repeat at most 1 times {{ {last} }} otherwise {{ {w} }}",
    "forever": "forever {{ {w}  {last} }}",
    "scope": "scope {{ {w} }}  {last}",
    "forces": "forces S b {{ {w} }}  {last}",
    "two_blocks_deep": "scope {{ repeat at most 1 times {{ {w} }} }}  {last}",
}
_PRODUCERS = [("produce", "emit 1"), ("spawn", "promote 1")]
_DEPTHS_OF_PRODUCERS = [(d, b, l) for d in sorted(_STORE_DEPTHS) for b, l in _PRODUCERS]


@pytest.mark.parametrize("depth,block,last", _DEPTHS_OF_PRODUCERS)
def test_a_branch_of_a_match_holds_no_store(tmp_path, depth, block, last):
    # a match binder is never visible at a store: this is why the scopes of the
    # block rule record the binders of the loops and not those of a match
    inner = _STORE_DEPTHS[depth].format(w="k <- fun(y: Number) => y + n", last=last)
    body = (f"{_K}\n s := match m {{ Full as n => {block} {{ {inner} }}, "
            f"Empty => {block} {{ {last} }} }}\n {_USE_K}")
    proj = _project(tmp_path, _match_entry(body), _MATCH_WORLD)
    rc, out = _compile(proj, tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", "is not supported inside a", f"`{block}`"), out


@pytest.mark.parametrize("depth,block,last", _DEPTHS_OF_PRODUCERS)
def test_the_body_of_a_lambda_holds_no_store(tmp_path, depth, block, last):
    # the same for a parameter of a lambda: a closure over a cell of the block,
    # passed to the lambda, cannot reach a cell that outlives the block through it
    inner = _STORE_DEPTHS[depth].format(w="k <- g", last=last)
    body = (f"{_K}\n when b {{ {_C}\n l := fun(g: Number -> Number) => {block} {{ {inner} }}\n"
            f" s := l(fun(y: Number) => y + c) }}\n {_USE_K}")
    proj = _project(tmp_path, _block_entry(body))
    rc, out = _compile(proj, tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", "is not supported inside a", f"`{block}`"), out


@pytest.mark.parametrize("form", ["produce", "t := produce"], ids=["statement", "expression"])
@pytest.mark.parametrize("block,last", _PRODUCERS)
def test_a_producer_in_a_producer_holds_no_store(tmp_path, form, block, last):
    # the statement form is a block of the outer body, and the expression form
    # runs its own check where the body binds it
    inner = f"{form} {{ repeat at most 1 times {{ k <- g }}  emit 1 }}  {last}"
    body = f"{_K}\n l := fun(g: Number -> Number) => {block} {{ {inner} }}\n {_USE_K}"
    proj = _project(tmp_path, _block_entry(body))
    rc, out = _compile(proj, tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", "is not supported inside a"), out


def _stream_entry(before: str, block: str) -> str:
    """A main that sums what the produce emits."""
    return (f"place Entry {{\n  fun main: Number {{ {before}\n s := produce {{ {block} }}\n"
            "    mut t := 0\n    for every x in s { t <- t + x }\n    return t }\n}\n")


@pytest.mark.parametrize("block", ["repeat at most 1 times { emit 1 }",
                                   "in sequence over i in List.cons(1, List.empty) { emit i }"],
                         ids=["repeat", "in_sequence"])
def test_a_loop_in_a_producer_runs(tmp_path, block):
    # no store here: the body emits, and the stream holds what it emits
    assert _compile_and_run(tmp_path, _stream_entry("", block)) == 1


# What a produce may write: the cells it declares, with the sum of what it emits.
_OWN_CELLS = {
    "directly": ("mut i := 1  i <- i + 1  emit i", 2),
    "in_scope": ("mut i := 1  scope { i <- i + 1 }  emit i", 2),
    "declared_in_scope": ("scope { mut i := 1  i <- i + 1  emit i }", 2),
    "in_iter": ("mut i := 0  iter 3 do { emit i  i <- i + 1 }", 3),
    "in_repeat": ("mut i := 1  repeat at most 1 times { i <- i + 1 }  emit i", 2),
    "in_when": ("mut i := 1  when i > 0 { i <- 5 }  emit i", 5),
    "captured_inside": ("mut i := 1  i <- 2  g := fun(y: Number) => y + i  v := g(1)  emit v", 3),
    "same_name_as_an_outer_value": ("mut n := 1  n <- 2  emit n", 2),
    "a_produce_in_a_produce": ("mut i := 1  i <- 2  emit i  t := produce { mut j := 3  j <- 4  emit j }  "
                               "for every x in t { emit x }", 6),
}


@pytest.mark.parametrize("form", sorted(_OWN_CELLS))
def test_a_produce_writes_the_cells_it_declares(tmp_path, form):
    block, value = _OWN_CELLS[form]
    assert _compile_and_run(tmp_path, _stream_entry("n := 7", block)) == value


def test_a_cell_declared_by_a_produce_does_not_leave_it_as_a_closure(tmp_path):
    entry = _stream_entry("", "mut i := 1  i <- 2  emit fun(y: Number) => y + i")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", "an element of a stream", "outlives the block"), out


# A store into a cell declared outside the produce, at every depth, in the form of
# the fixture and past a block that has ended.
@pytest.mark.parametrize("depth", sorted(_STORE_DEPTHS))
def test_a_produce_stores_into_no_outer_cell(tmp_path, depth):
    inner = _STORE_DEPTHS[depth].format(w="c <- 2", last="emit 1")
    entry = _block_entry(f"mut c := 1\n s := produce {{ {inner} }}\n return c")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", "is not supported inside a `produce`",
                            "when the stream is consumed"), out


def test_a_produce_stores_into_no_cell_of_a_finished_block_of_its_own(tmp_path):
    block = "scope { mut i := 1  i <- 2 }  i <- 3  emit 1"
    entry = _block_entry(f"mut i := 0\n s := produce {{ {block} }}\n return i")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", "is not supported inside a `produce`"), out


# A read of a cell declared outside the produce, at every depth: <r> is the read.
_READ_DEPTHS = {
    **{d: t.format(w="emit <r>", last="emit 1") for d, t in _STORE_DEPTHS.items()},
    "in_a_binding": "v := <r>  emit v",
    "in_an_expression": "emit 1 + <r>",
    "in_a_condition": "when <r> > 0 { emit 1 }  emit 2",
    "in_an_argument": "emit idn(<r>)",
    "in_a_lambda": "g := fun(y: Number) => y + <r>  v := g(1)  emit v",
    "in_a_produce_in_a_produce": "t := produce { emit <r> }  emit 1",
    "in_a_produce_statement": "produce { emit <r> }  emit 1",
}


def _read_entry(before: str, block: str, after: str = "") -> str:
    return ("place Entry {\n  fun idn(x: Number): Number { return x }\n"
            f"  fun mk(b: Boolean): Number {{ {before}\n s := produce {{ {block} }}\n {after}\n return 0 }}\n"
            "  fun main: Number { return mk(true) }\n}\n")


@pytest.mark.parametrize("depth", sorted(_READ_DEPTHS))
def test_a_produce_reads_no_outer_cell(tmp_path, depth):
    block = _READ_DEPTHS[depth].replace("<r>", "c")
    rc, out = _compile(_project(tmp_path, _read_entry("mut c := 1  c <- 2", block)), tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", "`c` is a cell declared outside the block",
                            "when the stream is consumed", "`x := c`", "`produce { emit x }`"), out


# Each path a read can take that a walk of the body alone would not see.
_READ_PATHS = {
    "written_after_the_produce": ("mut c := 1", "emit c", "c <- 2", "`c` is a cell"),
    "written_in_a_later_block": ("mut c := 1", "emit c", "when b { c <- 2 }", "`c` is a cell"),
    "a_closure_over_it": ("mut c := 1  c <- 2  g := fun(y: Number) => y + c", "emit g(1)", "", "`g` holds a closure"),
    "a_closure_copied": ("mut c := 1  c <- 2  g := fun(y: Number) => y + c  h := g", "emit h(1)", "", "`h` holds a closure"),
    "a_closure_in_a_lambda": ("mut c := 1  c <- 2  g := fun(y: Number) => y + c", "f := fun(y: Number) => g(y)  emit f(1)", "", "`g` holds a closure"),
    "a_cell_of_an_outer_produce": ("mut z := 0", "mut c := 1  c <- 2  t := produce { emit c }  emit 1", "", "`c` is a cell"),
}


@pytest.mark.parametrize("path", sorted(_READ_PATHS))
def test_a_read_of_an_outer_cell_is_refused_along_every_path(tmp_path, path):
    before, block, after, words = _READ_PATHS[path]
    rc, out = _compile(_project(tmp_path, _read_entry(before, block, after)), tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", words, "when the stream is consumed"), out


# Only `mut` declares a cell: a store into a parameter or a value is a store into a
# value, refused by its own rule, and the rules on cells have nothing to say of it.
_STORES_INTO_A_VALUE = {
    "a_parameter_read_in_a_produce": ("c: Number", "c <- c + 1\n s := produce { emit c }\n return 0", "1"),
    "a_value_read_in_a_produce": ("", "c := 1\n c <- 2\n s := produce { emit c }\n return 0", ""),
    "a_closure_over_a_parameter_in_a_produce": ("c: Number", "c <- c + 1\n g := fun(y: Number) => y + c\n"
                                                " s := produce { emit g(1) }\n return 0", "1"),
    "a_closure_over_a_value_in_a_produce": ("", "c := 1\n c <- 2\n g := fun(y: Number) => y + c\n"
                                            " s := produce { emit g(1) }\n return 0", ""),
    "a_closure_over_a_parameter_given_to_a_produce": ("c: Number", "c <- c + 1\n return mk2(fun(y: Number) => y + c)", "1"),
    "a_closure_over_a_value_given_to_a_produce": ("", "c := 1\n c <- 2\n return mk2(fun(y: Number) => y + c)", ""),
}


@pytest.mark.parametrize("form", sorted(_STORES_INTO_A_VALUE))
def test_a_store_into_a_value_makes_no_cell_of_it(tmp_path, form):
    sig, body, arg = _STORES_INTO_A_VALUE[form]
    entry = ("place Entry {\n  fun mk2(g: Number -> Number): Number { s := produce { emit g(1) }\n return 0 }\n"
             f"  fun mk({sig}): Number {{ {body} }}\n"
             f"  fun main: Number {{ return mk({arg}) }}\n}}\n")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out, "E2008", "`c` is a value", "a value does not change"), out
    assert "cell declared outside" not in out and "closure over a cell" not in out, out


_MK = "fun mk(g: Number -> Number): Number { s := produce { emit g(1) }\n mut t := 0\n for every x in s { t <- t + x }\n return t }"
_OVER_CELL = "fun(y: Number) => y + c"
_WRITTEN = "mut c := 10  c <- 20"

# A closure over a cell that enters a produce through a parameter, along every path:
# the functions it takes, and the body of main.
_PARAM_ROUTES = {
    "directly": (_MK, f"{_WRITTEN}  return mk({_OVER_CELL})", "`mk`"),
    "the_statement_form": ("fun mk(g: Number -> Number): Number { produce { emit g(1) }\n return 0 }",
                           f"{_WRITTEN}  return mk({_OVER_CELL})", "`mk`"),
    "in_a_scope": ("fun mk(g: Number -> Number): Number { s := produce { scope { emit g(1) } }\n return 0 }",
                   f"{_WRITTEN}  return mk({_OVER_CELL})", "`mk`"),
    "in_a_lambda": ("fun mk(g: Number -> Number): Number { s := produce { f := fun(y: Number) => g(y)  emit 1 }\n return 0 }",
                    f"{_WRITTEN}  return mk({_OVER_CELL})", "`mk`"),
    "written_after_the_call": (_MK, f"mut c := 10  r := mk({_OVER_CELL})  c <- 20  return r", "`mk`"),
    "a_local_closure": (_MK, f"{_WRITTEN}  f := {_OVER_CELL}  return mk(f)", "`mk`"),
    "a_copied_closure": (_MK, f"{_WRITTEN}  f := {_OVER_CELL}  h := f  return mk(h)", "`mk`"),
    "a_closure_in_a_cell": (_MK, f"{_WRITTEN}  mut f := fun(y: Number) => y  f <- {_OVER_CELL}  return mk(f)", "`mk`"),
    "a_lambda_over_a_closure": (_MK, f"{_WRITTEN}  f := {_OVER_CELL}  return mk(fun(y: Number) => f(y))", "`mk`"),
    "through_a_helper": ("fun idf(g: Number -> Number): Number -> Number { return g }\n" + _MK,
                         f"{_WRITTEN}  return mk(idf({_OVER_CELL}))", "`mk`"),
    "the_parameter_copied": ("fun mk(g: Number -> Number): Number { h := g  s := produce { emit h(1) }\n return 0 }",
                             f"{_WRITTEN}  return mk({_OVER_CELL})", "`mk`"),
    "a_forwarder": (_MK + "\n fun fw(g: Number -> Number): Number { return mk(g) }",
                    f"{_WRITTEN}  return fw({_OVER_CELL})", "`fw`"),
    "a_forwarder_before_the_callee": ("fun fw(g: Number -> Number): Number { return mk(g) }\n" + _MK,
                                      f"{_WRITTEN}  return fw({_OVER_CELL})", "`fw`"),
    "a_forwarder_with_a_lambda": (_MK + "\n fun fw(g: Number -> Number): Number { return mk(fun(y: Number) => g(y)) }",
                                  f"{_WRITTEN}  return fw({_OVER_CELL})", "`fw`"),
    "the_second_parameter": ("fun mk(n: Number, g: Number -> Number): Number { s := produce { emit g(n) }\n return 0 }",
                             f"{_WRITTEN}  return mk(1, {_OVER_CELL})", "`mk`"),
    "a_recursive_forwarder": (_MK + "\n fun go(n: Number, g: Number -> Number): Number { return if n > 0 then go(n - 1, g) else mk(g) }",
                              f"{_WRITTEN}  return go(1, {_OVER_CELL})", "`go`"),
    "a_lambda_with_a_produce": ("", f"{_WRITTEN}  l := fun(g: Number -> Number) => produce {{ emit g(1) }}\n"
                                    f" r := l({_OVER_CELL})  return 0", "this function value"),
    "a_function_named_as_a_value": (_MK, f"{_WRITTEN}  k := mk  return k({_OVER_CELL})", "this function value"),
    "a_function_given_as_an_argument": (_MK + "\n fun app(h: (Number -> Number) -> Number, g: Number -> Number): Number { return h(g) }",
                                        f"{_WRITTEN}  return app(mk, {_OVER_CELL})", "`app`"),
    "a_cell_of_an_outer_produce": (_MK, f"s := produce {{ {_WRITTEN}  v := mk({_OVER_CELL})  emit v }}\n return 0", "`mk`"),
}


def _param_entry(funs: str, main: str) -> str:
    return f"place Entry {{\n  {funs}\n  fun main: Number {{ {main} }}\n}}\n"


@pytest.mark.parametrize("route", sorted(_PARAM_ROUTES))
def test_a_closure_over_a_cell_does_not_enter_a_produce_through_a_parameter(tmp_path, route):
    funs, main, callee = _PARAM_ROUTES[route]
    rc, out = _compile(_project(tmp_path, _param_entry(funs, main)), tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", "holds a closure over a cell", callee,
                            "inside a `produce` block", "when the stream is consumed"), out


def test_a_closure_in_a_section_does_not_enter_a_produce_through_a_parameter(tmp_path):
    funs = "fun mk(o: Box): Number { s := produce { emit o.f(1) }\n return 0 }"
    main = f"{_WRITTEN}  return mk(.-> Box {{ f ({_OVER_CELL}) }})"
    entry = "place Box { f Number -> Number }\n" + _param_entry(funs, main)
    rc, out = _compile(_project(tmp_path, entry, '\n[world.W]\nobjects = ["Box"]\n'), tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", "holds a closure over a cell", "`mk`"), out


def test_a_function_in_a_section_is_a_function_value(tmp_path):
    # the callee is known only as a value: it can be any function named as one
    main = f"{_WRITTEN}  o := .-> Box {{ run (mk) }}\n h := o.run  return h({_OVER_CELL})"
    entry = "place Box { run (Number -> Number) -> Number }\n" + _param_entry(_MK, main)
    rc, out = _compile(_project(tmp_path, entry, '\n[world.W]\nobjects = ["Box"]\n'), tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", "holds a closure over a cell", "inside a `produce` block"), out


# The twins: the same shape, with a function that captures no cell, or a function that
# does not read the parameter inside a produce. With the value it computes.
_PARAM_TWINS = {
    "a_pure_lambda": (_MK, "return mk(fun(y: Number) => y + 2)", 3),
    "a_named_function": ("fun inc(y: Number): Number { return y + 4 }\n" + _MK, "return mk(inc)", 5),
    "an_immutable_captured": (_MK, "c := 20  return mk(fun(y: Number) => y + c)", 21),
    "a_cell_never_written": (_MK, f"mut c := 20  return mk({_OVER_CELL})", 21),
    "a_copy_captured": (_MK, "mut c := 10  c <- 20  x := c  c <- 30  return mk(fun(y: Number) => y + x)", 21),
    "a_forwarder_of_a_pure_lambda": (_MK + "\n fun fw(g: Number -> Number): Number { return mk(g) }",
                                     "return fw(fun(y: Number) => y + 2)", 3),
    "no_produce_in_the_callee": ("fun run1(g: Number -> Number): Number { return g(1) }",
                                 f"{_WRITTEN}  return run1({_OVER_CELL})", 21),
    "a_value_computed_before": ("fun em(n: Number): Number { s := produce { emit n }\n mut t := 0\n"
                                " for every x in s { t <- t + x }\n return t }",
                                f"{_WRITTEN}  f := {_OVER_CELL}  return em(f(1))", 21),
    "the_closure_applied_before_the_produce": ("fun mk(g: Number -> Number): Number { v := g(1)  s := produce { emit v }\n"
                                               " mut t := 0\n for every x in s { t <- t + x }\n return t }",
                                               f"{_WRITTEN}  return mk({_OVER_CELL})", 21),
    "another_parameter_read": ("fun mk(n: Number, g: Number -> Number): Number { v := g(1)  s := produce { emit n }\n"
                               " mut t := 0\n for every x in s { t <- t + x }\n return t + v }",
                               f"{_WRITTEN}  return mk(1, {_OVER_CELL})", 22),
}


@pytest.mark.parametrize("twin", sorted(_PARAM_TWINS))
def test_a_function_that_captures_no_cell_enters_a_produce(tmp_path, twin):
    funs, main, value = _PARAM_TWINS[twin]
    assert _compile_and_run(tmp_path, _param_entry(funs, main)) == value


# Each body of a statement produce is a body of its own: a store in a produce it
# holds says nothing of a same-named value around it.
_NESTED_PRODUCERS = {
    # a closure over the value, applied in the body: the value is not a cell of the produce
    "a_closure_over_the_value": ("return mk2(3)", 8),
    # what the inner statement emits is its own stream: the outer one holds its own f
    "a_value_in_the_outer_produce": ("n := 0\n s := produce { f := 5  produce { mut f := 1  f <- 2  emit f }  emit f }\n"
                                     " mut t := n\n for every x in s { t <- t + x }\n return t", 5),
    "the_outer_produce_has_a_cell_too": ("s := produce { mut f := 5  f <- 6  produce { mut f := 1  f <- 2  emit f }  emit f }\n"
                                         " mut t := 0\n for every x in s { t <- t + x }\n return t", 6),
    "a_cell_of_the_function_of_the_same_name": ("mut f := 1  f <- 2\n produce { f := 9  emit f }\n return f", 2),
}
_MK2 = "fun mk2(n: Number): Number { f := 5\n k := fun(y: Number) => y + f\n produce { mut f := 1  f <- 2  emit f }\n return k(n) }"


@pytest.mark.parametrize("form", sorted(_NESTED_PRODUCERS))
def test_a_statement_produce_has_cells_of_its_own(tmp_path, form):
    main, value = _NESTED_PRODUCERS[form]
    assert _compile_and_run(tmp_path, _param_entry(_MK2, main)) == value


_HOMONYMS = {
    # the function around a produce statement
    "around": "f := 5\n produce {{ mut {c} := 1  {c} <- 2  emit {c} }}\n return f",
    # the outer produce around a produce statement it holds
    "nested": "s := produce {{ f := 5  produce {{ mut {c} := 1  {c} <- 2  emit {c} }}  emit f }}\n"
              " mut t := 0\n for every x in s {{ t <- t + x }}\n return t",
    # the outer produce, in the expression form inside
    "nested_expression": "s := produce {{ f := 5  r := produce {{ mut {c} := 1  {c} <- 2  emit {c} }}  emit f }}\n"
                         " mut t := 0\n for every x in s {{ t <- t + x }}\n return t",
}


@pytest.mark.parametrize("form", sorted(_HOMONYMS))
def test_a_cell_of_a_nested_produce_makes_no_cell_of_a_same_named_value_outside(tmp_path, form):
    # the name of the inner cell changes nothing: the same cells are made under another
    # name, and the program computes the same value
    def cells(tmp: Path, name: str) -> tuple[int, int]:
        tmp.mkdir()
        entry = _param_entry("", _HOMONYMS[form].format(c=name))
        proj = _project(tmp, entry)
        mlir = tmp / "x.mlir"
        r = subprocess.run([str(YONC), "--emit=mlir", str(proj), "-o", str(mlir)],
                           capture_output=True, text=True, timeout=120)
        assert r.returncode == 0, r.stdout + r.stderr
        rc, out = _compile(proj, tmp / "out")
        assert rc == 0, out
        return mlir.read_text().count("call @__cell_make"), _run(tmp / "out")

    assert cells(tmp_path / "same", "f") == cells(tmp_path / "other", "z")


@pytest.mark.xfail(strict=True, reason="a declaration in a block hides a local lambda of the same name")
@pytest.mark.parametrize("block", ["when b { mut f := 1  f <- 2 }", "produce { mut f := 1  f <- 2  emit f }"],
                         ids=["when", "produce"])
def test_a_cell_in_a_block_hides_a_local_lambda_of_the_same_name(tmp_path, block):
    body = f"f := fun(y: Number) => y + 1\n {block}\n return f(3)"
    assert _compile_and_run(tmp_path, _block_entry(body)) == 4


def test_a_return_in_a_produce_takes_no_closure_over_its_cell(tmp_path):
    # the cells of a statement produce are not cells of the body: this route is closed
    # by structure, because a return stands only where its body ends
    block = "produce { mut i := 1  i <- 2  return fun(y: Number) => y + i }"
    entry = _param_entry(f"fun mkc(): Number -> Number {{ {block} }}", "return 0")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out, "E2002", "is not at the end of its body"), out


@pytest.mark.xfail(strict=True, raises=AssertionError,
                   reason="a cell of a produce says nothing of a closure over a same-named value outside it")
def test_a_closure_over_a_value_named_like_a_cell_of_a_produce_leaves_the_body(tmp_path):
    # a refusal too many, not a hole: the walks of a value count cells by name
    funs = ("fun mkc(): Number -> Number { f := 5\n produce { mut f := 1  f <- 2  emit f }\n"
            " return fun(y: Number) => y + f }")
    assert _compile_and_run(tmp_path, _param_entry(funs, "h := mkc()  return h(3)")) == 8


@pytest.mark.parametrize("form", ["produce", "t := produce"], ids=["statement", "expression"])
def test_a_closure_over_a_cell_of_a_produce_does_not_cross_the_wire(tmp_path, form):
    block = f"{form} {{ mut i := 1  i <- 2  _s := Wire.send(ch, fun(y: Number) => y + i)  emit i }}"
    entry = _param_entry("", f"ch := Wire.make(4)\n {block}\n return 0")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", "crosses"), out


def test_the_last_statement_of_a_produce_is_no_tail_of_the_function(tmp_path):
    # the statement yields its stream: the closure on its last line is a local of the
    # produce, and it leaves nothing
    block = "produce { mut i := 1  i <- 2  emit i  g := fun(y: Number) => y + i }"
    entry = _param_entry(f"fun mkc(): Wire<Number> {{ {block} }}",
                         "s := mkc()\n mut t := 0\n for every x in s { t <- t + x }\n return t")
    assert _compile_and_run(tmp_path, entry) == 2


@pytest.mark.xfail(strict=True, raises=AssertionError,
                   reason="a produce statement at the end of a function is checked against its return type")
@pytest.mark.parametrize("ret", ["Number", "Number -> Number"], ids=["number", "arrow"])
def test_a_produce_statement_at_the_end_answers_to_the_return_type(tmp_path, ret):
    # the statement yields a stream, and the implicit tail does not ask its type
    entry = _param_entry(f"fun mkc(): {ret} {{ produce {{ emit 1 }} }}", "return 0")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", "declares return type"), out


def test_a_read_after_a_produce_statement_is_of_the_outer_value(tmp_path):
    # the outer produce reads a value, not the cell of the produce it holds, and the
    # cell can be written around the read
    entry = _stream_entry("f := 5", "produce { mut f := 1  f <- 2  emit f }  emit f")
    assert _compile_and_run(tmp_path, entry) == 5


# A spawn holds no store of its own, and a produce it holds is a boundary.
def test_a_produce_in_a_spawn_writes_the_cells_it_declares(tmp_path):
    entry = ("place Entry {\n  fun main: Number {\n"
             "    w := spawn { produce { mut i := 1  i <- 2  emit i }  promote 1 }\n"
             "    mut t := 0\n    for every x in w { t <- t + x }\n    return t }\n}\n")
    assert _compile_and_run(tmp_path, entry) == 1


def test_a_produce_in_a_spawn_stores_into_no_cell_outside_it(tmp_path):
    entry = ("place Entry {\n  fun main: Number {\n"
             "    w := spawn { mut i := 1  produce { i <- 2  emit i }  promote 1 }\n"
             "    return 0 }\n}\n")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", "is not supported inside a `produce`"), out


def test_a_spawn_holds_no_store_of_its_own_around_a_produce(tmp_path):
    entry = ("place Entry {\n  fun main: Number {\n"
             "    w := spawn { mut i := 1  produce { emit 1 }  i <- 2  promote i }\n"
             "    return 0 }\n}\n")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out, "E2001", "is not supported inside a `spawn`"), out


# What a produce may read from outside: a value, with the sum of what it emits.
_OUTER_VALUES = {
    "a_copy_of_the_cell": ("mut c := 1  c <- 2  x := c", "emit x", 2),
    "a_copy_keeps_its_value": ("mut c := 1  c <- 2  x := c  c <- 9", "emit x", 2),
    "a_cell_never_written": ("mut c := 4", "emit c", 4),
    "an_immutable": ("c := 4", "emit c", 4),
    "a_value_computed_by_a_closure": ("mut c := 1  c <- 2  g := fun(y: Number) => y + c  x := g(1)", "emit x", 3),
    "a_name_the_produce_declares": ("mut c := 1  c <- 2", "c := 8  emit c", 8),
    "a_lambda_parameter_of_the_same_name": ("mut c := 1  c <- 2", "g := fun(c: Number) => c + 1  v := g(1)  emit v", 2),
}


@pytest.mark.parametrize("form", sorted(_OUTER_VALUES))
def test_a_produce_reads_a_value_from_outside(tmp_path, form):
    before, block, value = _OUTER_VALUES[form]
    assert _compile_and_run(tmp_path, _stream_entry(before, block)) == value


@pytest.mark.xfail(strict=True, reason="a local lambda can be called inside a produce")
@pytest.mark.parametrize("before,block", [("n := 5  g := fun(y: Number) => y + n", "v := g(1)  emit v"),
                                          ("", "n := 5  g := fun(y: Number) => y + n  emit g(1)")],
                         ids=["declared_outside", "called_in_an_emit"])
def test_a_local_lambda_called_inside_a_produce_runs(tmp_path, before, block):
    # no cell here: the lambda reads a value, and the rule on reads leaves it alone
    assert _compile_and_run(tmp_path, _stream_entry(before, block)) == 6


def test_a_lambda_parameter_outside_a_produce_hides_a_cell(tmp_path):
    entry = _stream_entry("mut c := 1  c <- 2  l := fun(c: Number) => produce { emit c }\n r := l(3)",
                          "for every x in r { emit x }")
    assert _compile_and_run(tmp_path, entry) == 3


@pytest.mark.xfail(strict=True, reason="a lambda in a branch of a match can capture the binder of the branch")
def test_a_closure_over_a_match_binder_runs(tmp_path):
    assert _compile_and_run(tmp_path, _match_entry(_closure_over_binder("n")), _MATCH_WORLD) == 22


def test_a_cell_never_written_captured_and_returned_is_a_value(tmp_path):
    # no write, so no handle: the closure holds 10, and another call's cells
    # taking the slots changes nothing
    entry = ("place Entry {\n  fun mk: Number -> Number { mut c := 10  return fun(y: Number) => y + c }\n"
             "  fun user(f: Number -> Number): Number { mut d := 90  d <- 98  return f(1) + (d - d) }\n"
             "  fun main: Number { f := mk  return user(f) }\n}\n")
    assert _compile_and_run(tmp_path, entry) == 11


@pytest.mark.xfail(strict=True, reason="a cell that holds a closure can be called by its name")
def test_a_written_cell_that_holds_a_closure_is_called_by_its_name(tmp_path):
    entry = ("place Entry {\n  fun main: Number { mut k := fun(y: Number) => y  "
             "k <- fun(y: Number) => y + 1  return k(1) }\n}\n")
    assert _compile_and_run(tmp_path, entry) == 2


@pytest.mark.xfail(strict=True, reason="a lambda in a block can capture a cell of an outer block")
def test_a_closure_over_an_outer_cell_written_in_a_block_runs(tmp_path):
    body = f"mut c := 1  c <- 2  {_K}\n when b {{ k <- fun(y: Number) => y + c }}\n {_USE_K}"
    assert _compile_and_run(tmp_path, _block_entry(body)) == 3


@pytest.mark.xfail(strict=True, reason="a local of a block that holds a closure can be stored in a cell")
def test_a_local_closure_of_a_block_stored_in_an_outer_cell_runs(tmp_path):
    body = f"{_K}\n when b {{ g := fun(y: Number) => y + 1  k <- g }}\n {_USE_K}"
    assert _compile_and_run(tmp_path, _block_entry(body)) == 2


@pytest.mark.parametrize("form", sorted(_CELL_ESCAPES))
def test_every_escape_route_of_a_cell_is_rejected(tmp_path, form):
    entry = (f"{_CELL_PLACES}place Entry {{\n  {_CELL_ESCAPES[form]}\n"
             "  fun main: Number { return 0 }\n}\n")
    proj = _project(tmp_path, entry, '\n[world.W]\nobjects = ["Box", "P", "Q", "Bit"]\n')
    rc, out = _compile(proj, tmp_path / "out")
    if form in _CLOSED_BY_STRUCTURE:
        assert _clean_rejection(rc, out, "E2002", "is not at the end of its body"), out
    else:
        assert (_clean_rejection(rc, out, "E2001", "outlive")
                or _clean_rejection(rc, out, "E2001", "crosses")), out


def test_closure_over_cell_sent_to_another_space_is_rejected(tmp_path):
    """The cross-Space call is a wire: the argument leaves the process."""
    (tmp_path / "echo.yon").write_text(
        "place Entry {\n  fun use_remote(g: Number -> Number): Number { return g(1) }\n"
        "  fun main: Number { return 0 }\n}\n")
    (tmp_path / "client.yon").write_text(
        "import echo::use_remote from Echo\n\nplace Entry {\n  fun main: Number {\n"
        "    mut k := 10\n    k <- 20\n    return use_remote(fun(y: Number) => y + k)\n  }\n}\n")
    rc, out = _compile(tmp_path / "client.yon", tmp_path / "client", cwd=tmp_path)
    assert _clean_rejection(rc, out, 'E2001', 'crosses into another Space') and "crosses" in out, out


@pytest.mark.parametrize("body,expected", [
    # variant D: applied inside its own activation
    ("fun mk: Number { mut c := 10  c <- 20  g := fun(y: Number) => y + c  return g(1) }", 21),
    # passed downward: the callee runs inside the owner's activation
    ("fun apply(g: Number -> Number): Number { return g(1) }\n"
     "  fun mk: Number { mut c := 10  c <- 20  return apply(fun(y: Number) => y + c) }", 21),
    # an immutable binding is captured by value: the closure is mobile
    ("fun mk2: Number -> Number { mut c := 20  return fun(y: Number) => y + c }\n"
     "  fun mk: Number { f := mk2  return f(1) }", 21),
    # ... also when that value was read out of a cell
    ("fun mk2: Number -> Number { mut c := 10  c <- 20  n := c + 0  return fun(y: Number) => y + n }\n"
     "  fun mk: Number { f := mk2  return f(1) }", 21),
    # a cell READ is a value, and so is what the closure computes
    ("fun mk: Number { mut c := 10  c <- 20  return c }", 20),
    ("fun mk: Number { mut c := 10  c <- 20  g := fun(y: Number) => y + c  n := g(1)  return n }", 21),
    # a cell used inside its activation, or its value handed to a callee
    ("fun mk: Number { mut h := 20  g := fun(y: Number) => y + h  return g(1) }", 21),
    ("fun pass(k: Number): Number { return k }\n"
     "  fun mk: Number { mut h := 21  h2 := pass(h)  return h2 }", 21),
    # what crosses the wire is the closure's value, a number
    ("fun mk(): Number { ch := Wire.make(4)  mut c := 10  c <- 20  g := fun(y: Number) => y + c  "
     "_s := Wire.send(ch, g(1))  return Wire.recv(ch) }", 21),
])
def test_mobile_uses_of_a_cell_are_untouched(tmp_path, body, expected):
    call = "mk()" if "Wire." in body else "mk"
    main = "fun main()" if "Wire." in body else "fun main"
    entry = f"place Entry {{\n  {body}\n  {main}: Number {{ return {call} }}\n}}\n"
    assert _compile_and_run(tmp_path, entry) == expected


# --- comprehension subobjects --------------------------------------------------

@pytest.mark.parametrize("arg,extra", [
    ("3", ""),                                                          # violating literal
    ("three(1)", "  fun three(k: Number): Number { return k + 2 }\n"),  # computed
    ("loopy(0)", "  fun loopy(k: Number): Number { return if k > 100 then k else loopy(k + 1) }\n"),
])
def test_bare_value_never_inhabits_a_subobject(tmp_path, arg, extra):
    """`{ n : A where P }` is a Sigma; a bare value is never accepted for it -
    neither proved, nor checked at runtime, nor silently admitted. A witness is
    required. (The predicate is a type, so a Boolean such as `n > 0` does not
    parse there.)"""
    entry = (f"place Entry {{\n  fun five(x: {{ n : Number where n = 5 }}): Number {{ return 0 }}\n"
             f"{extra}  fun main: Number {{ return five({arg}) }}\n}}\n")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out, 'E2001', 'five: parameter x expects') and "five: parameter x expects" in out, out


# --- DomainError survives lowering ---------------------------------------------

_HALF = """\
place Entry {
  fun half(n: Number) on error DomainError: Number {
    return if n < 0 then .-> DomainError { message "neg" } else n / 2
  }
  fun relay(n: Number) on error DomainError: Number { return half(n) }
  fun main: Number { return match relay(%s) { Number as v => 1, DomainError as e => 30 } }
}
"""


@pytest.mark.parametrize("entry,expected", [
    ("place Entry { fun main: Number { return match Int64.div(5, 0) "
     "{ Int64 as v => 1, DomainError as e => 30 } } }\n", 30),
    (_HALF % "0 - 4", 30),
    (_HALF % "8", 1),
])
def test_domain_error_reaches_the_caller(tmp_path, entry, expected):
    """The error arm survives MLIR lowering, also when propagated."""
    assert _compile_and_run(tmp_path, entry) == expected


# --- effects escaping their cover ----------------------------------------------

@pytest.mark.xfail(strict=True, reason="an arrow type carries its latent effect, so "
                   "a function without `visits Output` cannot run an Output closure")
def test_latent_effect_in_arrow_type(tmp_path):
    entry = """\
place Entry {
  fun announce(n: Number): Number visits Output { _u := Output.print("hi")  return n }
  fun mk: Number -> Number visits Output { return fun(y: Number) => announce(y) }
  fun apply(g: Number -> Number): Number { return g(41) }
  fun main: Number visits Output { return apply(mk) + 1 }
}
"""
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out, 'E2001', 'visits') and "visits" in out, out


# --- static deadlock analysis --------------------------------------------------

@pytest.mark.xfail(strict=True, reason="mutually synchronous calls between two "
                   "Spaces can deadlock, and the compiler says so")
def test_mutual_sync_rpc_flagged(tmp_path):
    (tmp_path / "alpha.yon").write_text("""\
import beta::pong from Beta

place Entry {
  fun ping(n: Number): Number { return if n <= 0 then 0 else pong(n - 1) + 1 }
  fun main: Number { return 0 }
}
""")
    (tmp_path / "beta.yon").write_text("""\
import alpha::ping from Alpha

place Entry {
  fun pong(n: Number): Number { return if n <= 0 then 0 else ping(n - 1) + 1 }
  fun main: Number { return 0 }
}
""")
    outs = [_compile(tmp_path / f"{n}.yon", tmp_path / f"{n.title()}_srv", cwd=tmp_path)
            for n in ("alpha", "beta")]
    assert any(rc != 0 and "deadlock" in out.lower() for rc, out in outs), outs


# --- purity of dependent-type indices ------------------------------------------

@pytest.mark.xfail(strict=True, reason="a type index is pure: `clear c ++ clear c` "
                   "with a write to c in between does not compose")
def test_cell_read_in_type_index(tmp_path):
    entry = """\
place Entry {
  fun main: Number {
    mut c := 5
    p := clear c
    c <- 6
    q := clear c
    j := p ++ q
    return (j @ I0) * 10 + (j @ I1)
  }
}
"""
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out, 'E2001', 'concat') and "concat" in out, out
