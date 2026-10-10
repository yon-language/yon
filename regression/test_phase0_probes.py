"""Phase 0 of YON_IMPROVEMENT_PLAN.md (v1.1): the sixteen probes, P-01 .. P-16.

Every test states what the CORRECT language must do, not what HEAD does today.
Three outcomes, three shapes:

  * not reproduced  -> a plain test, green today: it guards the property.
  * defect reproduced (class D) -> xfail(strict=True), reason "DEFECT <item>".
  * acceptance (class A, the capability does not exist yet)
                    -> xfail(strict=True), reason "ACCEPTANCE <item>".

strict=True is the point: the day a fix lands the test XPASSes, the suite turns
red, and the marker has to be removed on purpose. A failure of an ACCEPTANCE
test is never evidence against its item (plan, rule 2).

Recorded on HEAD d782ff2 (baseline 1898 passed / 49 skipped / 0 failed).
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


# --- P-01 (D) S-01: strict positivity ----------------------------------------

_BAD = """\
place Bad { f Bad -> Number }
place Entry {
  fun omega(b: Bad): Number { be g holds b.f  return g(b) }
  fun boom(n: Number): Number { return omega(.-> Bad { f omega }) }
  fun force(n: Number): Same(boom(n), 0) { return clear }
  fun main(): Number { return 0 }
}
"""


def test_p01_checker_terminates_on_negative_place(tmp_path):
    """The guarantee S-01 protects: the checker never diverges. Not reproduced
    on HEAD: the place construction `.-> Bad {...}` is opaque to the reducer, so
    the self-application is never unfolded (the TimeoutExpired would be the
    defect)."""
    proj = _project(tmp_path, _BAD, '\n[world.W]\nobjects = ["Bad"]\n')
    _compile(proj, tmp_path / "out", timeout=60)


@pytest.mark.xfail(strict=True, reason="DEFECT S-01: no strict-positivity check; "
                   "`place Bad { f Bad -> Number }` is accepted by the frontend")
def test_p01_negative_place_rejected(tmp_path):
    entry = "place Bad { f Bad -> Number }\nplace Entry { fun main(): Number { return 0 } }\n"
    proj = _project(tmp_path, entry, '\n[world.W]\nobjects = ["Bad"]\n')
    rc, out = _compile(proj, tmp_path / "out")
    assert _clean_rejection(rc, out), out


# --- P-02, P-03 (D) S-02: parametric generics ------------------------------

@pytest.mark.xfail(strict=True, reason="DEFECT S-02: field access on an abstract T "
                   "passes the checker; only emit_mlir dies (uncaught Failure)")
def test_p02_no_field_access_on_abstract_t(tmp_path):
    entry = """\
place Entry {
  fun bad<T>(x: T): Number { return x.foo }
  fun main(): Number { return 0 }
}
"""
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out), out


@pytest.mark.xfail(strict=True, reason="DEFECT S-02: a T -> T that is not the "
                   "identity type-checks and runs")
@pytest.mark.parametrize("body", ["7", "x + 1", '"hello"'])
def test_p03_t_to_t_is_the_identity(tmp_path, body):
    entry = f"""\
place Entry {{
  fun notid<T>(x: T): T {{ return {body} }}
  fun main(): Number {{ return notid(5) }}
}}
"""
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out), out


# --- P-04, P-05 (D) S-03: Int64 precision ----------------------------------

@pytest.mark.xfail(strict=True, reason="DEFECT S-03: Int64 is carried and computed "
                   "as f64 (arith.mulf/addf), 2^53+1 is lost before any List")
def test_p04_int64_exact_past_2_53_through_list(tmp_path):
    entry = """\
place Entry {
  fun big(): Int64 { return Int64.ipow_ok(2, 53) + 1 }
  fun first(xs: List<Int64>): Int64 { return List.head(xs) }
  fun main(): Number {
    be xs holds List.cons(big(), List.empty(0))
    return if Int64.is_odd(first(xs)) then 1 else 0
  }
}
"""
    assert _compile_and_run(tmp_path, entry) == 1


@pytest.mark.slow
@pytest.mark.xfail(strict=True, reason="DEFECT S-03: 2^53+1 arrives even at the "
                   "remote Space (upstream loss, see P-04)")
def test_p05_int64_exact_across_spaces(tmp_path):
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
    be a holds odd_remote(Int64.ipow_ok(2, 40) + 1)
    be b holds odd_remote(Int64.ipow_ok(2, 52) + 1)
    be c holds odd_remote(Int64.ipow_ok(2, 53) + 1)
    return a + 2 * b + 4 * c
  }
}
""")
    rc, out = _compile(tmp_path / "echo.yon", tmp_path / "Echo_srv", cwd=tmp_path)
    assert rc == 0, out
    rc, out = _compile(tmp_path / "client.yon", tmp_path / "client", cwd=tmp_path)
    assert rc == 0, out
    assert _run(tmp_path / "client", cwd=tmp_path) == 7


# --- P-06 (D) S-04: the Widen law under overflow ---------------------------

_WIDEN = """\
place Entry {
  fun lhs(a: Int32, b: Int32): Int64 { return Int32.widen_i32_i64(a + b) }
  fun rhs(a: Int32, b: Int32): Int64 { return Int32.widen_i32_i64(a) + Int32.widen_i32_i64(b) }
  fun holds_law(a: Int32, b: Int32): Number { return if lhs(a, b) == rhs(a, b) then 1 else 0 }
  fun wrapped(a: Int32, b: Int32): Number { return if a + b < 0 then 1 else 0 }
  fun main(): Number { return %s(2147483647, 1) }
}
"""


def test_p06_widen_additive_law_today(tmp_path):
    """RECORDS the state of S-04: the law holds at Int32.MAX + 1 today only
    because Int32 is carried as f64 and never overflows. This test is the
    alarm: it goes red the day Int32 becomes a real i32 (see the next test)."""
    assert _compile_and_run(tmp_path, _WIDEN % "holds_law") == 1


@pytest.mark.xfail(strict=True, reason="DEFECT S-04 precondition: Int32 + Int32 is "
                   "arith.addf on f64; Int32.MAX + 1 = 2147483648, not an Int32")
def test_p06_int32_addition_wraps(tmp_path):
    assert _compile_and_run(tmp_path, _WIDEN % "wrapped") == 1


# --- P-07 (D) S-05: hygiene of generated names ------------------------------

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
def test_p07_double_underscore_inside_name_is_exported(tmp_path):
    assert _call_remote(tmp_path, "a__b") == 108


@pytest.mark.slow
@pytest.mark.xfail(strict=True, reason="DEFECT S-05: user functions named __x / "
                   "yon_rt_x silently drop out of the wire dispatch table")
@pytest.mark.parametrize("fn,expected", [("__conto", 102), ("yon_rt_saldo", 104)])
def test_p07_reserved_prefix_names_are_exported(tmp_path, fn, expected):
    assert _call_remote(tmp_path, fn) == expected


# --- P-08 (D) S-06: out-of-range sentinels ----------------------------------

@pytest.mark.xfail(strict=True, reason="DEFECT S-06: in-band sentinels "
                   "(Vec.get OOB -> 0.0, char_at/index_of -> -1)")
@pytest.mark.parametrize("expr,sentinel_exit", [
    ("Vec.get(Vec.push(Vec.push(Vec.push(Vec.empty(), 10), 20), 30), 1000) + 1", 1),
    ('String.char_at("abc", 3) + 100', 99),
    ('String.index_of("abc", 122) + 100', 99),
])
def test_p08_no_in_band_sentinel(tmp_path, expr, sentinel_exit):
    """A failure must be a typed value the program has to handle. Either the
    sentinel-producing program is rejected, or it no longer yields the sentinel."""
    proj = _project(tmp_path, f"place Entry {{ fun main(): Number {{ return {expr} }} }}\n")
    rc, out = _compile(proj, tmp_path / "out")
    assert rc != 0 or _run(tmp_path / "out") != sentinel_exit


# --- P-09 (D? -> A on HEAD) T-06: internal places ---------------------------

@pytest.mark.xfail(strict=True, reason="ACCEPTANCE T-06: `internal` applies to fun "
                   "only (parser.mly:1016,1032); an internal place is a parse error")
def test_p09_internal_place_match_from_outside_rejected(tmp_path):
    entry = "place Entry { fun main(): Number { return match A { A => 1, B => 2 } } }\n"
    files = {"w/Topos.yon": "topos WTopos where {\n}\n",
             "w/Secret.yon": "internal place Secret { this > A :U B }\n"}
    proj = _project(tmp_path, entry, '\n[world.W]\nobjects = ["Secret"]\nspaces  = ["w"]\n', files)
    rc, out = _compile(proj, tmp_path / "out")
    assert _clean_rejection(rc, out) and "PARSE ERROR" not in out, out


# --- P-10 (D? -> checked on fields) T-07: `this <` --------------------------

def test_p10_subobject_with_incompatible_field_rejected(tmp_path):
    """Not reproduced: the mono is checked structurally on fields (by name and
    type, tycheck.ml:3245), not merely declared. Operations are not probed."""
    entry = """\
place Entry {
  fun read(b: B): Number { return b.value }
  fun main(): Number { be a holds .-> A { value "hi" }  return read(a) }
}
"""
    files = {"w/Topos.yon": "topos WTopos where {\n}\n",
             "w/B.yon": "place B { value Number }\n",
             "w/A.yon": "place A { this < B\n  value Text\n}\n"}
    proj = _project(tmp_path, entry, '\n[world.W]\nobjects = ["X"]\nspaces  = ["w"]\n', files)
    rc, out = _compile(proj, tmp_path / "out")
    assert _clean_rejection(rc, out) and "subcontains" in out, out


# --- P-11 (A) T-03: a cell handle must not outlive its reset ----------------

def test_p11_escaping_closure_over_cell(tmp_path):
    """S-08 closed: the closure over a cell is not mobile and is stopped at the
    return (before: exit 99, another activation's cell read silently)."""
    entry = """\
place Entry {
  fun mk(): Number -> Number { be c holds 10  c = 20  return fun(y: Number) => y + c }
  fun user(f: Number -> Number): Number { be d holds 90  d = 98  return f(1) }
  fun main(): Number { be f holds mk()  return user(f) }
}
"""
    proj = _project(tmp_path, entry)
    rc, out = _compile(proj, tmp_path / "out")
    # rejected at compile time, or the closure sees its own cell (20 + 1)
    assert _clean_rejection(rc, out) or (rc == 0 and _run(tmp_path / "out") == 21)


# S-08: every route out of the activation that owns a cell. The judgment must
# be conservative (never "does not escape" for a value that escapes), so each
# route the analysis could miss is a case: mutating any part of it (the lambda
# capture, the fixpoint over bindings, the walk over every expression form, the
# implicit tail through compound statements, the allocation of a cell, the
# tainted parameters at a store or on the wire) turns at least one case green.
_S08_ESCAPES = {
    # leaving the call
    "alias": "fun mk(): Number -> Number { be c holds 10  c = 20  be g holds fun(y: Number) => y + c  be h holds g  return h }",
    "field": "fun mk(): Box { be c holds 10  c = 20  return .-> Box { f (fun(y: Number) => y + c) } }",
    "through_call": "fun idf(g: Number -> Number): Number -> Number { return g }\n"
                    "  fun mk(): Number -> Number { be c holds 10  c = 20  return idf(fun(y: Number) => y + c) }",
    "implicit_tail": "fun mk(): Number -> Number { be c holds 10  c = 20  be g holds fun(y: Number) => y + c }",
    "tail_through_when": "fun mk(): Number -> Number { be c holds 10  c = 20  when c > 0 { be g holds fun(y: Number) => y + c } "
                         "otherwise { be h holds fun(y: Number) => y + c } }",
    "return_in_while": "fun mk(): Number -> Number { be c holds 10  c = 20  be g holds fun(y: Number) => y + c  "
                       "while c > 0 do { return g }  return g }",
    "if_expression": "fun mk(): Number -> Number { be c holds 10  c = 20  be g holds fun(y: Number) => y + c  "
                     "return if c > 0 then g else fun(y: Number) => y }",
    "match_arms": "fun mk(b: Bit): Number -> Number { be c holds 10  c = 20  "
                  "return match b { One => fun(y: Number) => y + c, Zero => fun(y: Number) => y + c } }",
    "curried": "fun mk(): Number -> (Number -> Number) { be c holds 10  c = 20  return fun(y: Number) => fun(z: Number) => z + c }",
    "lambda_over_alias": "fun mk(): Number -> Number { be c holds 10  c = 20  be g holds fun(y: Number) => y + c  "
                         "return fun(y: Number) => g(y) }",
    "move_lambda": "fun mk(): move from P to Q { be c holds 10  c = 20  return move(s: P) => .-> Q { v c } from P to Q }",
    "cell_holds_closure": "fun mk(): Number -> Number { be c holds 10  c = 20  be k holds fun(y: Number) => y  "
                          "k = fun(y: Number) => y + c  return k }",
    "assigned_after_the_return": "fun mk(): Number -> Number { be c holds 10  c = 20  be k holds fun(y: Number) => y  be i holds 0  "
                                 "while i < 2 do { when i > 0 { return k }  k = fun(y: Number) => y + c  i = i + 1 }  return k }",
    "alias_before_assignment": "fun mk(): Number -> Number { be c holds 10  c = 20  be k holds fun(y: Number) => y  "
                               "be h holds fun(y: Number) => y  be i holds 0  "
                               "while i < 2 do { h = k  k = fun(y: Number) => y + c  i = i + 1 }  return h }",
    "no_declared_return": "fun mk() { be c holds 10  c = 20  return fun(y: Number) => y + c }",
    # a cell made with Space.make is freed on return as well
    "space_cell_returned": "fun mk(): Space { be h holds Space.make(21)  be h2 holds h  return h2 }",
    "space_cell_captured": "fun mk(): Number -> Number { be h holds Space.make(20)  return fun(y: Number) => y + Space.get(h) }",
    "space_cell_contents_read_out": "fun mk(): Number -> Number { be h holds Space.make(0)  be c holds 10  c = 20  "
                                    "be _s holds Space.set(h, fun(y: Number) => y + c)  return Space.get(h) }",
    "space_cell_made_with_a_closure": "fun mk(): Number -> Number { be c holds 10  c = 20  "
                                      "be h holds Space.make(fun(y: Number) => y + c)  return Space.get(h) }",
    # stored into a cell the caller owns
    "stored_in_outer_cell": "fun mk(k: Space): Number { be c holds 10  c = 20  be _s holds Space.set(k, fun(y: Number) => y + c)  return 0 }",
    "stored_by_a_helper": "fun put(k: Space, g: Number -> Number): Number { be _s holds Space.set(k, g)  return 0 }\n"
                          "  fun mk(k: Space): Number { be c holds 10  c = 20  return put(k, fun(y: Number) => y + c) }",
    # sent on the wire
    "wire_send": "fun mk(): Number { be ch holds Wire.make(4)  be c holds 10  c = 20  "
                 "be _s holds Wire.send(ch, fun(y: Number) => y + c)  return 0 }",
    "wire_send_by_a_helper": "fun sendit(ch: Number, g: Number -> Number): Number { be _s holds Wire.send(ch, g)  return 0 }\n"
                             "  fun mk(): Number { be ch holds Wire.make(4)  be c holds 10  c = 20  "
                             "return sendit(ch, fun(y: Number) => y + c) }",
}

_S08_PLACES = ("place Box { f Number -> Number }\nplace P { v Number }\nplace Q { v Number }\n"
               "place Bit { this > One :U Zero }\n")


@pytest.mark.parametrize("form", sorted(_S08_ESCAPES))
def test_s08_every_escape_route_is_rejected(tmp_path, form):
    entry = (f"{_S08_PLACES}place Entry {{\n  {_S08_ESCAPES[form]}\n"
             "  fun main(): Number { return 0 }\n}\n")
    proj = _project(tmp_path, entry, '\n[world.W]\nobjects = ["Box", "P", "Q", "Bit"]\n')
    rc, out = _compile(proj, tmp_path / "out")
    assert _clean_rejection(rc, out) and ("outlive" in out or "crosses" in out), out


def test_s08_closure_sent_to_another_space_is_rejected(tmp_path):
    """The cross-Space call is a wire: the argument leaves the process."""
    (tmp_path / "echo.yon").write_text(
        "place Entry {\n  fun use_remote(g: Number -> Number): Number { return g(1) }\n"
        "  fun main(): Number { return 0 }\n}\n")
    (tmp_path / "client.yon").write_text(
        "import echo::use_remote from Echo\n\nplace Entry {\n  fun main(): Number {\n"
        "    be k holds 10\n    k = 20\n    return use_remote(fun(y: Number) => y + k)\n  }\n}\n")
    rc, out = _compile(tmp_path / "client.yon", tmp_path / "client", cwd=tmp_path)
    assert _clean_rejection(rc, out) and "crosses" in out, out


@pytest.mark.parametrize("body,expected", [
    # variant D: applied inside its own activation
    ("fun mk(): Number { be c holds 10  c = 20  be g holds fun(y: Number) => y + c  return g(1) }", 21),
    # passed downward: the callee runs inside the owner's activation
    ("fun apply(g: Number -> Number): Number { return g(1) }\n"
     "  fun mk(): Number { be c holds 10  c = 20  return apply(fun(y: Number) => y + c) }", 21),
    # an immutable binding is captured by value: the closure is mobile
    ("fun mk2(): Number -> Number { be c holds 20  return fun(y: Number) => y + c }\n"
     "  fun mk(): Number { be f holds mk2()  return f(1) }", 21),
    # ... also when that value was read out of a cell
    ("fun mk2(): Number -> Number { be c holds 10  c = 20  be n holds c + 0  return fun(y: Number) => y + n }\n"
     "  fun mk(): Number { be f holds mk2()  return f(1) }", 21),
    # a cell READ is a value, and so is what the closure computes
    ("fun mk(): Number { be c holds 10  c = 20  return c }", 20),
    ("fun mk(): Number { be c holds 10  c = 20  be g holds fun(y: Number) => y + c  be n holds g(1)  return n }", 21),
    # a Space cell used inside its activation, or handed back to its owner
    ("fun mk(): Number { be h holds Space.make(20)  be g holds fun(y: Number) => y + Space.get(h)  return g(1) }", 21),
    ("fun pass(k: Space): Space { return k }\n"
     "  fun mk(): Number { be h holds Space.make(21)  be h2 holds pass(h)  return Space.get(h2) }", 21),
    # what crosses the wire is the closure's value, a number
    ("fun mk(): Number { be ch holds Wire.make(4)  be c holds 10  c = 20  be g holds fun(y: Number) => y + c  "
     "be _s holds Wire.send(ch, g(1))  return Wire.recv(ch) }", 21),
])
def test_s08_mobile_uses_are_untouched(tmp_path, body, expected):
    entry = f"place Entry {{\n  {body}\n  fun main(): Number {{ return mk() }}\n}}\n"
    assert _compile_and_run(tmp_path, entry) == expected


# --- P-12 (D? -> recorded) L-05: comprehension subobject policy -------------

@pytest.mark.parametrize("arg,extra", [
    ("3", ""),                                                          # violating literal
    ("three(1)", "  fun three(k: Number): Number { return k + 2 }\n"),  # computed
    ("loopy(0)", "  fun loopy(k: Number): Number { return if k > 100 then k else loopy(k + 1) }\n"),
])
def test_p12_bare_value_never_inhabits_a_subobject(tmp_path, arg, extra):
    """RECORDED POLICY on HEAD: `{ n : A where P }` is a Sigma; a bare value is
    never accepted for it - neither proved, nor checked at runtime, nor silently
    admitted. A witness is required. (Boolean predicates such as `n > 0` do not
    parse: the predicate is a type_expr, parser.mly:946.)"""
    entry = (f"place Entry {{\n  fun five(x: {{ n : Number where Same(n, 5) }}): Number {{ return 0 }}\n"
             f"{extra}  fun main(): Number {{ return five({arg}) }}\n}}\n")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out) and "five: parameter x expects" in out, out


# --- P-13 (D) V-05: DomainError survives lowering ---------------------------

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
def test_p13_domain_error_reaches_the_caller(tmp_path, entry, expected):
    """Not reproduced: the error arm survives MLIR lowering, also propagated."""
    assert _compile_and_run(tmp_path, entry) == expected


# --- P-14 (A) T-04: effects escaping their cover ----------------------------

@pytest.mark.xfail(strict=True, reason="ACCEPTANCE T-04: an arrow type carries no "
                   "latent effect; `apply` (no visits) runs an Output closure")
def test_p14_latent_effect_in_arrow_type(tmp_path):
    entry = """\
place Entry {
  fun announce(n: Number): Number visits Output { be _u holds Output.print("hi")  return n }
  fun mk(): Number -> Number visits Output { return fun(y: Number) => announce(y) }
  fun apply(g: Number -> Number): Number { return g(41) }
  fun main(): Number visits Output { return apply(mk()) + 1 }
}
"""
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out) and "visits" in out, out


# --- P-15 (A) D-03: static deadlock analysis --------------------------------

@pytest.mark.xfail(strict=True, reason="ACCEPTANCE D-03: mutually synchronous RPC "
                   "between two Spaces compiles without a diagnostic")
def test_p15_mutual_sync_rpc_flagged(tmp_path):
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


# --- P-16 (A) T-02: purity of dependent-type indices ------------------------

@pytest.mark.xfail(strict=True, reason="ACCEPTANCE T-02: `clear c ++ clear c` with a "
                   "write to c in between is judged composable by the checker")
def test_p16_cell_read_in_type_index(tmp_path):
    entry = """\
place Entry {
  fun main(): Number {
    be c holds 5
    be p holds clear c
    c = 6
    be q holds clear c
    be j holds p ++ q
    return (j @ I0) * 10 + (j @ I1)
  }
}
"""
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out) and "concat" in out, out
