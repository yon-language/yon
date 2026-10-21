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


def _clean_rejection(rc: int, out: str) -> bool:
    """Rejected by the frontend with a stable diagnostic code - not by an
    uncaught OCaml exception, and not by the MLIR verifier downstream."""
    return (rc != 0 and "[E" in out and "Fatal error: exception" not in out
            and "stage0.topos.mlir" not in out)


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
  fun omega(b: Bad): Number { be g := b.f  return g(b) }
  fun boom(n: Number): Number { return omega(.-> Bad { f omega }) }
  fun force(n: Number): Same(boom(n), 0) { return clear }
  fun main(): Number { return 0 }
}
"""


def test_checker_terminates_on_negative_place(tmp_path):
    """The checker never diverges. The place construction `.-> Bad {...}` is
    opaque to the reducer, so the self-application is never unfolded (a
    TimeoutExpired would mean it diverged). Terminating is not enough: the
    program asks `clear` to prove Same(boom(n), 0), which is false, so the
    checker must REJECT it, cleanly (a stable [E....] code, no uncaught OCaml
    exception)."""
    proj = _project(tmp_path, _BAD, '\n[world.W]\nobjects = ["Bad"]\n')
    rc, out = _compile(proj, tmp_path / "out", timeout=60)
    assert "Fatal error" not in out, f"the checker crashed instead of deciding:\n{out}"
    assert _clean_rejection(rc, out), (
        f"Same(boom(n), 0) is false, so `clear` must be rejected with a diagnostic "
        f"code (rc={rc}):\n{out}")


@pytest.mark.xfail(strict=True, reason="a place that occurs negatively in its own "
                   "fields, `place Bad { f Bad -> Number }`, is not strictly positive")
def test_negative_place_rejected(tmp_path):
    entry = "place Bad { f Bad -> Number }\nplace Entry { fun main(): Number { return 0 } }\n"
    proj = _project(tmp_path, entry, '\n[world.W]\nobjects = ["Bad"]\n')
    rc, out = _compile(proj, tmp_path / "out")
    assert _clean_rejection(rc, out), out


# --- parametricity of generics ------------------------------------------------

def test_no_field_access_on_abstract_t(tmp_path):
    entry = """\
place Entry {
  fun bad<T>(x: T): Number { return x.foo }
  fun main(): Number { return 0 }
}
"""
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out), out


@pytest.mark.parametrize("body", ["7", "x + 1", '"hello"'])
def test_t_to_t_is_the_identity(tmp_path, body):
    entry = f"""\
place Entry {{
  fun notid<T>(x: T): T {{ return {body} }}
  fun main(): Number {{ return notid(5) }}
}}
"""
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out), out


@pytest.mark.parametrize("body", ["x(1)", "x.foo", "fst(x)"])
def test_an_abstract_t_admits_no_operation(tmp_path, body):
    """Inside a generic function a T can only be passed on."""
    entry = f"""\
place Entry {{
  fun bad<T>(x: T): Number {{ return {body} }}
  fun main(): Number {{ return 0 }}
}}
"""
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out), out


def test_an_abstract_t_admits_no_literal_test(tmp_path):
    """A test against a literal would reveal T: refused."""
    entry = """\
place Entry {
  fun peek<T>(x: T): Number {
    be r := 0
    when x is 5 { r = 1 }
    return r
  }
  fun main(): Number { return peek(5) }
}
"""
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out), out


def test_a_generic_call_is_typed_at_its_instance(tmp_path):
    """identity(41) is a Number, first("ok", 0) a String; a generic function
    passed as a value fits the arrow it is passed to."""
    entry = """\
place Entry {
  fun identity<T>(x: T): T { return x }
  fun first<A, B>(x: A, y: B): A { return x }
  fun apply(f: Number -> Number, x: Number): Number { return f(x) }
  fun main(): Number {
    return identity(40) + String.length(first("ok", 0)) + apply(identity, 0)
  }
}
"""
    assert _compile_and_run(tmp_path, entry) == 42


def test_a_generic_result_is_not_another_type(tmp_path):
    """The instance chosen by the arguments is the type of the result."""
    entry = """\
place Entry {
  fun identity<T>(x: T): T { return x }
  fun main(): Number { return String.length(identity(5)) }
}
"""
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out), out


# --- Int64 precision -----------------------------------------------------------

def test_int64_exact_past_2_53_through_list(tmp_path):
    entry = """\
place Entry {
  fun big(): Int64 { return Int64.ipow_ok(2, 53) + 1 }
  fun first(xs: List<Int64>): Int64 { return List.head(xs) }
  fun main(): Number {
    be xs := List.cons(big(), List.empty(0))
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
  fun main(): Number { return 0 }
}
""")
    (tmp_path / "client.yon").write_text("""\
import echo::odd_remote from Echo

place Entry {
  fun main(): Number {
    be a := odd_remote(Int64.ipow_ok(2, 40) + 1)
    be b := odd_remote(Int64.ipow_ok(2, 52) + 1)
    be c := odd_remote(Int64.ipow_ok(2, 53) + 1)
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
  fun big(): Int64 { return 9007199254740992 + 1 }
  fun base(): Int64 { return 9007199254740992 }
  fun main(): Number { return if big() - base() == 1 then 1 else 0 }
}
"""
    assert _compile_and_run(tmp_path, entry) == 1


def test_int64_wraps_modulo_2_64(tmp_path):
    entry = """\
place Entry {
  fun main(): Number {
    be a := if Int64.max_value() + 1 == Int64.min_value() then 1 else 0
    be b := if Int64.min_value() - 1 == Int64.max_value() then 10 else 0
    be c := if Int64.max_value() > 0 then 100 else 0
    return a + b + c
  }
}
"""
    assert _compile_and_run(tmp_path, entry) == 111


def test_int64_crosses_every_uniform_slot_bit_for_bit(tmp_path):
    """Int64.MAX, Int64.MIN and 2^53+1 come back equal through a List, a
    coproduct payload and a closure capture."""
    entry = """\
place Entry {
  fun via_list(x: Int64): Int64 { return List.head(List.cons(x, List.empty(0))) }
  fun wrap(x: Int64): (Lit(Int64) | Nil) { return hit(Lit, x) }
  fun unwrap(e: (Lit(Int64) | Nil)): Int64 { return match e { Lit(n) => n, Nil => 0 } }
  fun adder(k: Int64): Int64 -> Int64 { return fun(y: Int64) => k + y }
  fun same(x: Int64): Number {
    be f := adder(x)
    be a := if via_list(x) == x then 1 else 0
    be c := if unwrap(wrap(x)) == x then a else 0
    return if f(0) == x then c else 0
  }
  fun main(): Number {
    return same(Int64.max_value()) + same(Int64.min_value()) * 10
         + same(9007199254740992 + 1) * 100
  }
}
"""
    rc = _compile_and_run(tmp_path, entry)
    assert rc == 111, f"Int64 through the slots: {rc}"


def test_an_integer_literal_past_2_53_is_exact(tmp_path):
    """9007199254740993 at Int64 is that integer (odd), and the largest
    literal is Int64.MAX; one past it is refused."""
    entry = """\
place Entry {
  fun odd(): Int64 { return 9007199254740993 }
  fun top(): Int64 { return 9223372036854775807 }
  fun main(): Number {
    be a := if Int64.is_odd(odd()) then 1 else 0
    return if top() == Int64.max_value() then a + 10 else a
  }
}
"""
    assert _compile_and_run(tmp_path, entry) == 11
    over = "place Entry {\n  fun m(): Int64 { return 9223372036854775808 }\n  fun main(): Number { return 0 }\n}\n"
    (tmp_path / "over").mkdir()
    rc, out = _compile(_project(tmp_path / "over", over), tmp_path / "out2")
    assert _clean_rejection(rc, out), out


def test_int64_to_text_writes_its_exact_digits(tmp_path):
    entry = """\
place Entry {
  fun main(): Number {
    be _a := String.print(Int64.to_text(Int64.max_value()))
    be _b := String.print(Int64.to_text(Int64.min_value()))
    be _c := String.print(Int64.to_text(9007199254740993))
    be _d := String.print(Int64.to_text(0 - 42))
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
  fun main(): Number { return %s(2147483647, 1) }
}
"""


def test_widen_additive_law_at_int32_max(tmp_path):
    """widen(a + b) = widen(a) + widen(b) at Int32.MAX + 1. It holds while
    Int32 is carried as f64 and never overflows; it is the alarm that goes red
    when Int32 becomes a wrapping i32 and the law needs its overflow side
    condition (see the next test)."""
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
  fun main(): Number { return 0 }
}
"""


def _call_remote(tmp: Path, fn: str) -> int:
    (tmp / "ledger.yon").write_text(_LEDGER)
    (tmp / "client.yon").write_text(
        f"import ledger::{fn} from Ledger\n\n"
        f"place Entry {{\n  fun main(): Number {{ return {fn}(100) }}\n}}\n")
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
    ('String.char_at("abc", 3) + 100', 99),
    ('String.index_of("abc", 122) + 100', 99),
])
def test_no_in_band_sentinel(tmp_path, expr, sentinel_exit):
    """A failure must be a typed value the program has to handle. Either the
    sentinel-producing program is rejected, or it no longer yields the sentinel."""
    proj = _project(tmp_path, f"place Entry {{ fun main(): Number {{ return {expr} }} }}\n")
    rc, out = _compile(proj, tmp_path / "out")
    assert rc != 0 or _run(tmp_path / "out") != sentinel_exit


# --- internal places -----------------------------------------------------------

@pytest.mark.xfail(strict=True, reason="`internal` hides a place from outside its "
                   "Space, so matching on its arms from outside is refused")
def test_internal_place_match_from_outside_rejected(tmp_path):
    entry = "place Entry { fun main(): Number { return match A { A => 1, B => 2 } } }\n"
    files = {"w/Topos.yon": "topos WTopos where {\n}\n",
             "w/Secret.yon": "internal place Secret { this > A :U B }\n"}
    proj = _project(tmp_path, entry, '\n[world.W]\nobjects = ["Secret"]\nspaces  = ["w"]\n', files)
    rc, out = _compile(proj, tmp_path / "out")
    assert _clean_rejection(rc, out) and "PARSE ERROR" not in out, out


# --- subobjects: `this <` -------------------------------------------------------

def test_subobject_with_incompatible_field_rejected(tmp_path):
    """The mono `this < B` is checked structurally on fields, by name and type,
    not merely declared."""
    entry = """\
place Entry {
  fun read(b: B): Number { return b.value }
  fun main(): Number { be a := .-> A { value "hi" }  return read(a) }
}
"""
    files = {"w/Topos.yon": "topos WTopos where {\n}\n",
             "w/B.yon": "place B { value Number }\n",
             "w/A.yon": "place A { this < B\n  value Text\n}\n"}
    proj = _project(tmp_path, entry, '\n[world.W]\nobjects = ["X"]\nspaces  = ["w"]\n', files)
    rc, out = _compile(proj, tmp_path / "out")
    assert _clean_rejection(rc, out) and "subcontains" in out, out


# --- a cell handle must not outlive its activation --------------------------

def test_escaping_closure_over_cell(tmp_path):
    """A closure over a cell is not mobile and is stopped at the return;
    otherwise it would read another activation's cell (exit 99)."""
    entry = """\
place Entry {
  fun mk(): Number -> Number { be c := 10  c = 20  return fun(y: Number) => y + c }
  fun user(f: Number -> Number): Number { be d := 90  d = 98  return f(1) }
  fun main(): Number { be f := mk()  return user(f) }
}
"""
    proj = _project(tmp_path, entry)
    rc, out = _compile(proj, tmp_path / "out")
    # rejected at compile time, or the closure sees its own cell (20 + 1)
    assert _clean_rejection(rc, out) or (rc == 0 and _run(tmp_path / "out") == 21)


# Every route out of the activation that owns a cell. The judgment must
# be conservative (never "does not escape" for a value that escapes), so each
# route the analysis could miss is a case: mutating any part of it (the lambda
# capture, the fixpoint over bindings, the walk over every expression form, the
# implicit tail through compound statements, the allocation of a cell, the
# tainted parameters at a store or on the wire) turns at least one case green.
_CELL_ESCAPES = {
    # leaving the call
    "alias": "fun mk(): Number -> Number { be c := 10  c = 20  be g := fun(y: Number) => y + c  be h := g  return h }",
    "field": "fun mk(): Box { be c := 10  c = 20  return .-> Box { f (fun(y: Number) => y + c) } }",
    "through_call": "fun idf(g: Number -> Number): Number -> Number { return g }\n"
                    "  fun mk(): Number -> Number { be c := 10  c = 20  return idf(fun(y: Number) => y + c) }",
    "implicit_tail": "fun mk(): Number -> Number { be c := 10  c = 20  be g := fun(y: Number) => y + c }",
    "tail_through_when": "fun mk(): Number -> Number { be c := 10  c = 20  when c > 0 { be g := fun(y: Number) => y + c } "
                         "otherwise { be h := fun(y: Number) => y + c } }",
    "return_in_while": "fun mk(): Number -> Number { be c := 10  c = 20  be g := fun(y: Number) => y + c  "
                       "while c > 0 do { return g }  return g }",
    "if_expression": "fun mk(): Number -> Number { be c := 10  c = 20  be g := fun(y: Number) => y + c  "
                     "return if c > 0 then g else fun(y: Number) => y }",
    "match_arms": "fun mk(b: Bit): Number -> Number { be c := 10  c = 20  "
                  "return match b { One => fun(y: Number) => y + c, Zero => fun(y: Number) => y + c } }",
    "curried": "fun mk(): Number -> (Number -> Number) { be c := 10  c = 20  return fun(y: Number) => fun(z: Number) => z + c }",
    "lambda_over_alias": "fun mk(): Number -> Number { be c := 10  c = 20  be g := fun(y: Number) => y + c  "
                         "return fun(y: Number) => g(y) }",
    "move_lambda": "fun mk(): move from P to Q { be c := 10  c = 20  return move(s: P) => .-> Q { v c } from P to Q }",
    "cell_holds_closure": "fun mk(): Number -> Number { be c := 10  c = 20  be k := fun(y: Number) => y  "
                          "k = fun(y: Number) => y + c  return k }",
    "assigned_after_the_return": "fun mk(): Number -> Number { be c := 10  c = 20  be k := fun(y: Number) => y  be i := 0  "
                                 "while i < 2 do { when i > 0 { return k }  k = fun(y: Number) => y + c  i = i + 1 }  return k }",
    "assigned_in_a_while_then_returned": "fun mk(): Number -> Number { be c := 10  c = 20  be k := fun(y: Number) => y  "
                                         "be i := 0  while i < 2 do { k = fun(y: Number) => y + c  i = i + 1 }  return k }",
    "stored_before_its_assignment_in_a_while": "fun mk(out: Space): Number { be c := 10  c = 20  be k := fun(y: Number) => y  "
                                               "be i := 0  while i < 2 do { when i > 0 { be _s := Space.set(out, k) }  "
                                               "k = fun(y: Number) => y + c  i = i + 1 }  return 0 }",
    "alias_before_assignment": "fun mk(): Number -> Number { be c := 10  c = 20  be k := fun(y: Number) => y  "
                               "be h := fun(y: Number) => y  be i := 0  "
                               "while i < 2 do { h = k  k = fun(y: Number) => y + c  i = i + 1 }  return h }",
    "no_declared_return": "fun mk() { be c := 10  c = 20  return fun(y: Number) => y + c }",
    # a cell made with Space.make is freed on return as well
    "space_cell_returned": "fun mk(): Space { be h := Space.make(21)  be h2 := h  return h2 }",
    "space_cell_captured": "fun mk(): Number -> Number { be h := Space.make(20)  return fun(y: Number) => y + Space.get(h) }",
    "space_cell_contents_read_out": "fun mk(): Number -> Number { be h := Space.make(0)  be c := 10  c = 20  "
                                    "be _s := Space.set(h, fun(y: Number) => y + c)  return Space.get(h) }",
    "space_cell_made_with_a_closure": "fun mk(): Number -> Number { be c := 10  c = 20  "
                                      "be h := Space.make(fun(y: Number) => y + c)  return Space.get(h) }",
    # stored into a cell the caller owns
    "stored_in_outer_cell": "fun mk(k: Space): Number { be c := 10  c = 20  be _s := Space.set(k, fun(y: Number) => y + c)  return 0 }",
    "stored_by_a_helper": "fun put(k: Space, g: Number -> Number): Number { be _s := Space.set(k, g)  return 0 }\n"
                          "  fun mk(k: Space): Number { be c := 10  c = 20  return put(k, fun(y: Number) => y + c) }",
    # sent on the wire
    "wire_send": "fun mk(): Number { be ch := Wire.make(4)  be c := 10  c = 20  "
                 "be _s := Wire.send(ch, fun(y: Number) => y + c)  return 0 }",
    "wire_send_by_a_helper": "fun sendit(ch: Number, g: Number -> Number): Number { be _s := Wire.send(ch, g)  return 0 }\n"
                             "  fun mk(): Number { be ch := Wire.make(4)  be c := 10  c = 20  "
                             "return sendit(ch, fun(y: Number) => y + c) }",
}

_CELL_PLACES = ("place Box { f Number -> Number }\nplace P { v Number }\nplace Q { v Number }\n"
               "place Bit { this > One :U Zero }\n")


# A route that leaves through a `return` inside a loop is closed by structure:
# a return stands only where its body ends, so the program is refused before
# mobility is asked.
_CLOSED_BY_STRUCTURE = {"return_in_while", "assigned_after_the_return"}


@pytest.mark.parametrize("form", sorted(_CELL_ESCAPES))
def test_every_escape_route_of_a_cell_is_rejected(tmp_path, form):
    entry = (f"{_CELL_PLACES}place Entry {{\n  {_CELL_ESCAPES[form]}\n"
             "  fun main(): Number { return 0 }\n}\n")
    proj = _project(tmp_path, entry, '\n[world.W]\nobjects = ["Box", "P", "Q", "Bit"]\n')
    rc, out = _compile(proj, tmp_path / "out")
    if form in _CLOSED_BY_STRUCTURE:
        assert _clean_rejection(rc, out) and "[E2002]" in out, out
    else:
        assert _clean_rejection(rc, out) and ("outlive" in out or "crosses" in out), out


def test_closure_over_cell_sent_to_another_space_is_rejected(tmp_path):
    """The cross-Space call is a wire: the argument leaves the process."""
    (tmp_path / "echo.yon").write_text(
        "place Entry {\n  fun use_remote(g: Number -> Number): Number { return g(1) }\n"
        "  fun main(): Number { return 0 }\n}\n")
    (tmp_path / "client.yon").write_text(
        "import echo::use_remote from Echo\n\nplace Entry {\n  fun main(): Number {\n"
        "    be k := 10\n    k = 20\n    return use_remote(fun(y: Number) => y + k)\n  }\n}\n")
    rc, out = _compile(tmp_path / "client.yon", tmp_path / "client", cwd=tmp_path)
    assert _clean_rejection(rc, out) and "crosses" in out, out


@pytest.mark.parametrize("body,expected", [
    # variant D: applied inside its own activation
    ("fun mk(): Number { be c := 10  c = 20  be g := fun(y: Number) => y + c  return g(1) }", 21),
    # passed downward: the callee runs inside the owner's activation
    ("fun apply(g: Number -> Number): Number { return g(1) }\n"
     "  fun mk(): Number { be c := 10  c = 20  return apply(fun(y: Number) => y + c) }", 21),
    # an immutable binding is captured by value: the closure is mobile
    ("fun mk2(): Number -> Number { be c := 20  return fun(y: Number) => y + c }\n"
     "  fun mk(): Number { be f := mk2()  return f(1) }", 21),
    # ... also when that value was read out of a cell
    ("fun mk2(): Number -> Number { be c := 10  c = 20  be n := c + 0  return fun(y: Number) => y + n }\n"
     "  fun mk(): Number { be f := mk2()  return f(1) }", 21),
    # a cell READ is a value, and so is what the closure computes
    ("fun mk(): Number { be c := 10  c = 20  return c }", 20),
    ("fun mk(): Number { be c := 10  c = 20  be g := fun(y: Number) => y + c  be n := g(1)  return n }", 21),
    # a Space cell used inside its activation, or handed back to its owner
    ("fun mk(): Number { be h := Space.make(20)  be g := fun(y: Number) => y + Space.get(h)  return g(1) }", 21),
    ("fun pass(k: Space): Space { return k }\n"
     "  fun mk(): Number { be h := Space.make(21)  be h2 := pass(h)  return Space.get(h2) }", 21),
    # what crosses the wire is the closure's value, a number
    ("fun mk(): Number { be ch := Wire.make(4)  be c := 10  c = 20  be g := fun(y: Number) => y + c  "
     "be _s := Wire.send(ch, g(1))  return Wire.recv(ch) }", 21),
])
def test_mobile_uses_of_a_cell_are_untouched(tmp_path, body, expected):
    entry = f"place Entry {{\n  {body}\n  fun main(): Number {{ return mk() }}\n}}\n"
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
    entry = (f"place Entry {{\n  fun five(x: {{ n : Number where Same(n, 5) }}): Number {{ return 0 }}\n"
             f"{extra}  fun main(): Number {{ return five({arg}) }}\n}}\n")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out) and "five: parameter x expects" in out, out


# --- DomainError survives lowering ---------------------------------------------

_HALF = """\
place Entry {
  fun half(n: Number) on error DomainError: Number {
    return if n < 0 then .-> DomainError { message "neg" } else n / 2
  }
  fun relay(n: Number) on error DomainError: Number { return half(n) }
  fun main(): Number { return match relay(%s) { Number as v => 1, DomainError as e => 30 } }
}
"""


@pytest.mark.parametrize("entry,expected", [
    ("place Entry { fun main(): Number { return match Int64.div(5, 0) "
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
  fun announce(n: Number): Number visits Output { be _u := Output.print("hi")  return n }
  fun mk(): Number -> Number visits Output { return fun(y: Number) => announce(y) }
  fun apply(g: Number -> Number): Number { return g(41) }
  fun main(): Number visits Output { return apply(mk()) + 1 }
}
"""
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out) and "visits" in out, out


# --- static deadlock analysis --------------------------------------------------

@pytest.mark.xfail(strict=True, reason="mutually synchronous calls between two "
                   "Spaces can deadlock, and the compiler says so")
def test_mutual_sync_rpc_flagged(tmp_path):
    (tmp_path / "alpha.yon").write_text("""\
import beta::pong from Beta

place Entry {
  fun ping(n: Number): Number { return if n <= 0 then 0 else pong(n - 1) + 1 }
  fun main(): Number { return 0 }
}
""")
    (tmp_path / "beta.yon").write_text("""\
import alpha::ping from Alpha

place Entry {
  fun pong(n: Number): Number { return if n <= 0 then 0 else ping(n - 1) + 1 }
  fun main(): Number { return 0 }
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
  fun main(): Number {
    be c := 5
    be p := clear c
    c = 6
    be q := clear c
    be j := p ++ q
    return (j @ I0) * 10 + (j @ I1)
  }
}
"""
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out) and "concat" in out, out
