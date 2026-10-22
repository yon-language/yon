"""Laws the compiler must keep, each shown by the smallest program that breaks it.

A wrong program must be refused; a right program must be accepted and compute
the right value. When the language does not keep a law yet, its test is
xfail(strict=True): the day it does, the test XPASSes and the marker is removed
on purpose. A probe checks the VALUE it observes, not only an exit code, and an
expected failure is raised as ProbeOutcome, so an unrelated breakage (the probe
program no longer compiles) fails the test instead of passing as expected.
"""
from decimal import Decimal
from pathlib import Path
import ctypes
import ctypes.util
import math
import os
import pytest
import re
import shutil
import subprocess
import sys
import zlib

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
FRONTEND = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_TOML = '[package]\nname = "probe"\n{extra}\n[runtime]\nbackend = "memory"\n'


def _project(tmp: Path, entry: str, extra: str = "", files: dict | None = None) -> Path:
    proj = tmp / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML.format(extra=extra))
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


def _run(exe: Path, cwd: Path | None = None, timeout: int = 30, env=None):
    """(exit code, stdout) of a compiled probe."""
    r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=timeout,
                       cwd=cwd, env=env)
    return r.returncode, r.stdout


def _clean_rejection(rc: int, out: str) -> bool:
    """Refused by the frontend with a stable diagnostic code - not by an
    uncaught OCaml exception, and not by the MLIR verifier downstream."""
    return (rc != 0 and "[E" in out and "Fatal error: exception" not in out
            and "stage0.topos.mlir" not in out)


class ProbeOutcome(AssertionError):
    """The probe's own verdict: a law is broken. An xfail names this type in
    `raises=`, so a broken precondition fails the test instead of passing."""


def _verdict(ok: bool, msg: str):
    if not ok:
        raise ProbeOutcome(msg)


# --- identity types ------------------------------------------------------------

def test_reflexivity_does_not_inhabit_a_false_identity(tmp_path):
    """refl(0) has type Id(Number, 0, 0); the checker refuses it at 0 = 1."""
    entry = ("place Entry {\n  fun bad(): Id(Number, 0, 1) { return refl(0) }\n"
             "  fun main(): Number { return 0 }\n}\n")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out), out


# A path is an identity between two given endpoints; a path whose endpoints the
# checker does not know cannot stand for every identity. Passing refl(0) through
# a `Path` parameter must not let it come back typed 0 = 1.
_LAUNDER = {
    "kernel": ("fun launder(p: Path): Id(Number, 0, 1) { return p }",
               "launder(refl(0))"),
    "surface": ("fun launder(p: Path): Same(0, 1) { return p }",
                "launder(clear 0)"),
}


@pytest.mark.parametrize("voice", sorted(_LAUNDER))
def test_a_path_does_not_prove_every_identity(tmp_path, voice):
    launder, call = _LAUNDER[voice]
    entry = (f"place Entry {{\n  {launder}\n"
             f"  fun main(): Number {{ be q := {call}  return (q @ I0) * 10 + (q @ I1) }}\n}}\n")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    if _clean_rejection(rc, out):
        return
    assert rc == 0, f"neither refused cleanly nor compiled:\n{out}"
    ends, _ = _run(tmp_path / "out")
    # the value typed 0 = 1 is a path whose endpoints are read back: 10*I0 + I1
    raise ProbeOutcome(f"accepted a proof of 0 = 1; its endpoints read back as "
                       f"I0={ends // 10}, I1={ends % 10}")


def test_an_identity_flows_into_path_by_forgetting_its_endpoints(tmp_path):
    """Id(A, x, y) is a point of the total space of paths: it is accepted where
    a bare Path is expected, as an argument and as a return value."""
    entry = ("place Entry {\n"
             "  fun seven(): Id(Number, 7, 7) { return refl(7) }\n"
             "  fun forget(): Path { return seven() }\n"
             "  fun weigh(p: Path): Number { return 7 }\n"
             "  fun main(): Number { be q := forget()  return weigh(q) + weigh(seven()) }\n"
             "}\n")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert rc == 0, out
    assert _run(tmp_path / "out")[0] == 14


# --- a lattice point is made only where it is one --------------------------------
# LatticePoint is an abstract type over its representation: `of_coordinate` is
# the characteristic map of the type-2 shell (a coordinate is a point, or a
# DomainError), `at_index` the i-th point of the shell; no literal is a point
# and no arithmetic applies.

_LP_PROBE = """\
place Entry {}
fun of_ok(n: Number): Number {
  return match LatticePoint.of_coordinate(n) { LatticePoint as p => 1, DomainError as d => 0 }
}
fun at_ok(i: Number): Number {
  return match LatticePoint.at_index(i) { LatticePoint as p => 1, DomainError as d => 0 }
}
fun main(): Number {
  be _a := IO.print_num(of_ok(1536))
  be _b := IO.print_num(of_ok(1536.5))
  be _c := IO.print_num(of_ok(0 - 1536))
  be _d := IO.print_num(of_ok(7))
  be _e := IO.print_num(at_ok(0))
  be _f := IO.print_num(at_ok(196559))
  be _g := IO.print_num(at_ok(196560))
  be _h := IO.print_num(at_ok(0 - 1))
  be _i := IO.print_num(at_ok(0.5))
  return 0
}
"""


def _compiles_and_runs(tmp_path, entry):
    proj = _project(tmp_path, entry)
    rc, out = _compile(proj, tmp_path / "out")
    _verdict(rc == 0, f"the program does not compile: {out[-300:]}")
    return _run(tmp_path / "out")


def test_a_lattice_point_is_made_only_where_it_is_one(tmp_path):
    code, out = _compiles_and_runs(tmp_path, _LP_PROBE)
    got = out.split()
    # 1536 is a type-2 point; a fraction, a negative and 7 are not; the shell
    # has 196560 points, indexed from 0
    _verdict(got == ["1", "0", "0", "0", "1", "1", "0", "0", "0"],
             f"of_coordinate(1536, 1536.5, -1536, 7), at_index(0, 196559, 196560, -1, 0.5): {got}")


def test_a_lattice_point_reads_its_index_and_orbit(tmp_path):
    code, out = _compiles_and_runs(tmp_path, """\
place Entry {}
fun idx(i: Number): Number {
  return match LatticePoint.at_index(i) { LatticePoint as p => LatticePoint.index(p), DomainError as d => 0 - 1 }
}
fun orb(n: Number): Number {
  return match LatticePoint.of_coordinate(n) { LatticePoint as p => LatticePoint.orbit(p), DomainError as d => 0 - 1 }
}
fun main(): Number {
  be _a := IO.print_num(idx(5))
  be _b := IO.print_num(idx(196559))
  be _c := IO.print_num(if orb(1536) == orb(1280) then 1 else 0)
  return 0
}
""")
    _verdict(out.split() == ["5", "196559", "1"], f"index(at_index 5), index(at_index 196559), same orbit: {out.split()}")


def test_a_number_is_not_a_lattice_point(tmp_path):
    rc, out = _compile(_project(tmp_path, """\
place Entry {}
fun main(): Number {
  be a := Arena.put(Arena.empty(), 1536, 42)
  return 0
}
"""), tmp_path / "out")
    _verdict(_clean_rejection(rc, out), f"a Number used as a lattice point was accepted: rc={rc}")


def test_a_lattice_point_has_no_arithmetic(tmp_path):
    rc, out = _compile(_project(tmp_path, """\
place Entry {}
fun main(): Number {
  return match LatticePoint.at_index(0) { LatticePoint as p => LatticePoint.index(p + 1), DomainError as d => 0 }
}
"""), tmp_path / "out")
    _verdict(_clean_rejection(rc, out) and "LatticePoint" in out,
             f"p + 1 on a lattice point was not refused: rc={rc} {out[-200:]}")


def test_an_arena_is_addressed_by_lattice_points(tmp_path):
    code, out = _compiles_and_runs(tmp_path, """\
place Entry {}
fun main(): Number {
  return match LatticePoint.of_coordinate(1536) {
    LatticePoint as p => (match Arena.get(Arena.put(Arena.empty(), p, 42), p) { Found(v) => v, Absent => 0 }),
    DomainError as d => 0
  }
}
""")
    _verdict(code == 42, f"put then get at a lattice point: {code}")


# --- a name is defined: be x := e ----------------------------------------------
# `:=` reads "is defined as", the same symbol as a field's `side := Number`:
# x equals e by definition for its whole scope. `holds` is no word of the
# language, so it is free as a name.

def _run_entry_names(tmp_path, body):
    proj = _project(tmp_path, "place Entry {}\n" + body)
    rc, out = _compile(proj, tmp_path / "out")
    if rc != 0:
        return rc, out, None
    code, _ = _run(tmp_path / "out")
    return rc, out, code


def test_a_name_is_defined_with_colon_eq(tmp_path):
    rc, out, code = _run_entry_names(tmp_path,
        "fun main(): Number {\n  be x := 1 + 2\n  return x\n}\n")
    _verdict(rc == 0 and code == 3, f"be x := 1 + 2: rc={rc} code={code} {out[-200:]}")


def test_holds_is_no_binder(tmp_path):
    old_form = "be x " + "holds 3"     # the binder this probe refuses
    rc, out, _ = _run_entry_names(tmp_path,
        "fun main(): Number {\n  " + old_form + "\n  return x\n}\n")
    _verdict(_clean_rejection(rc, out) and "E1001" in out,
             f"{old_form} was not a clean syntax error: rc={rc} {out[-200:]}")


def test_holds_is_an_ordinary_name(tmp_path):
    rc, out, code = _run_entry_names(tmp_path,
        "fun holds(n: Number): Number { return n + 1 }\n"
        "fun main(): Number { return holds(41) }\n")
    _verdict(rc == 0 and code == 42, f"fun holds: rc={rc} code={code} {out[-200:]}")


def test_a_name_is_defined_once_in_its_scope(tmp_path):
    (tmp_path / "twice").mkdir()
    rc, out, _ = _run_entry_names(tmp_path / "twice",
        "fun main(): Number {\n  be x := 1\n  be x := x + 1\n  return x\n}\n")
    _verdict(_clean_rejection(rc, out) and "already bound" in out,
             f"a second definition of x was not refused as such: rc={rc} {out[-200:]}")
    (tmp_path / "again").mkdir()
    rc, out, code = _run_entry_names(tmp_path / "again",
        "fun main(): Number {\n  be x := 1\n  x = x + 1\n  return x\n}\n")
    _verdict(rc == 0 and code == 2, f"be x := 1; x = x + 1: rc={rc} code={code} {out[-200:]}")


# --- control flow --------------------------------------------------------------

# A function's value is the value of its body: `return` names it where the
# body ends. A `return` anywhere else would be a non-local jump, and there is
# none, so it is refused, at its own line.
_MISPLACED_RETURNS = {
    "before_another_statement": "  return 5\n  return 9\n",
    "in_a_when_without_otherwise": "  when c == 1 { return 5 }\n  return 9\n",
    "in_a_last_when_without_otherwise": "  when c == 1 { return 5 }\n",
    "in_an_iter_body": "  iter 3 do { return 5 }\n  return 9\n",
    "in_a_while_body": "  while c > 0 do { return 5 }\n  return 9\n",
    "in_a_case_analysis_that_is_not_last": ("  when c == 1 { return 5 } otherwise { return 7 }\n"
                                            "  return 9\n"),
}


@pytest.mark.parametrize("form", sorted(_MISPLACED_RETURNS))
def test_a_return_outside_the_tail_is_refused(tmp_path, form):
    entry = ("place Entry {}\nfun f(c: Number): Number {\n" + _MISPLACED_RETURNS[form] +
             "}\nfun main(): Number { return f(1) }\n")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out) and "[E2002]" in out, out
    assert "[line 3," in out, f"the diagnostic does not point at the return:\n{out}"


def test_a_case_analysis_in_the_tail_ends_in_a_return_in_each_branch(tmp_path):
    entry = ("place Entry {}\nfun f(c: Number): Number { when c == 1 { return 5 } otherwise { return 9 } }\n"
             "fun main(): Number { return f(1) * 10 + f(2) }\n")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert rc == 0, out
    assert _run(tmp_path / "out")[0] == 59



def test_a_nested_case_analysis_passes_the_tail_to_every_branch(tmp_path):
    entry = ("place Entry {}\nfun f(a: Number, b: Number): Number {\n"
             "  when a == 1 {\n"
             "    when b == 1 { return 1 } otherwise { return 2 }\n"
             "  } otherwise { return 3 }\n}\n"
             "fun main(): Number { return f(1, 1) * 100 + f(1, 0) * 10 + f(0, 0) }\n")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert rc == 0, out
    assert _run(tmp_path / "out")[0] == 123 % 256

# === the type checker -------------------------------------------------

_WORLD_checker = '\n[world.W]\nobjects = ["X"]\nspaces  = ["w"]\n'
_WORLD_FILES_checker = {
    "w/Topos.yon": "topos WTopos where {\n}\n",
    "w/P.yon": "place P { v Number }\n",
    "w/Q.yon": "place Q { v Number }\n",
}


def _value_checker(tmp_path, entry, world=False):
    """Compile (must succeed) and return main's exit code."""
    if world:
        proj = _project(tmp_path, entry, extra=_WORLD_checker, files=_WORLD_FILES_checker)
    else:
        proj = _project(tmp_path, entry)
    exe = tmp_path / "exe"
    rc, out = _compile(proj, exe)
    assert rc == 0, out
    code, _ = _run(exe)
    return code


def _must_reject_checker(tmp_path, entry, what, world=False):
    """The program is ill-typed: the frontend must refuse it with an E-code."""
    if world:
        proj = _project(tmp_path, entry, extra=_WORLD_checker, files=_WORLD_FILES_checker)
    else:
        proj = _project(tmp_path, entry)
    exe = tmp_path / "exe"
    rc, out = _compile(proj, exe)
    if rc == 0:
        code, _ = _run(exe)
        _verdict(False, f"{what}: accepted, main computed {code}")
    assert _clean_rejection(rc, out), out


# ---------------------------------------------------------------- compose

def test_compose_applies_the_first_function_then_the_second(tmp_path):
    entry = """place Entry {
  fun f(x: Number): Number { return x + 3 }
  fun g(y: Number): Number { return y * 2 }
  fun main(): Number {
    be h := compose f with g
    return h(1)
  }
}
"""
    assert _value_checker(tmp_path, entry) == 8


def test_compose_requires_the_output_of_the_first_to_be_the_input_of_the_second(tmp_path):
    entry = """place Entry {
  fun f(x: Number): Text { return "abc" }
  fun g(y: Number): Number { return y * 2 }
  fun main(): Number {
    be h := compose f with g
    return h(1)
  }
}
"""
    _must_reject_checker(tmp_path, entry, "Text-valued f composed into Number-taking g")


def test_compose_of_two_function_parameters_computes_their_composite(tmp_path):
    """A composite of runtime values (two parameters) is a closure over them."""
    entry = """place Entry {
  fun twice_then(f: Number -> Number, g: Number -> Number, x: Number): Number {
    be h := compose f with g
    return h(x)
  }
  fun inc(x: Number): Number { return x + 3 }
  fun dbl(y: Number): Number { return y * 2 }
  fun main(): Number { return twice_then(inc, dbl, 1) }
}
"""
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "exe")
    assert rc == 0, out
    assert _run(tmp_path / "exe")[0] == 8


def test_compose_of_two_bound_lambdas_computes_their_composite(tmp_path):
    entry = """place Entry {
  fun main(): Number {
    be f := fun(x: Number) => x + 3
    be g := fun(y: Number) => y * 2
    be h := compose f with g
    return h(1)
  }
}
"""
    proj = _project(tmp_path, entry)
    rc, out = _compile(proj, tmp_path / "exe")
    _verdict(rc == 0, f"well-typed composite refused: {out.strip()[-200:]}")
    code, _ = _run(tmp_path / "exe")
    _verdict(code == 8, f"computed {code}, expected 8")


# ---------------------------------------------------------------- terminal types

@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a body returned at a terminal type must still be well-typed")
def test_a_unit_body_still_rejects_an_unbound_name(tmp_path):
    entry = """place Entry {
  fun f(): Unit { return no_such_name + "x" }
  fun main(): Number { return 7 }
}
"""
    _must_reject_checker(tmp_path, entry, "unbound name under Unit")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a call returned at a terminal type must still respect the callee's arity")
def test_a_unit_body_still_rejects_a_wrong_arity_call(tmp_path):
    entry = """place Entry {
  fun k(a: Number): Number { return a }
  fun f(): Unit { return k(1, 2, 3, 4) }
  fun main(): Number { return 7 }
}
"""
    _must_reject_checker(tmp_path, entry, "four arguments to a unary function under Unit")


def test_an_unbound_name_is_rejected_at_a_non_terminal_type(tmp_path):
    entry = """place Entry {
  fun f(): Number { return no_such_name + "x" }
  fun main(): Number { return 7 }
}
"""
    proj = _project(tmp_path, entry)
    rc, out = _compile(proj, tmp_path / "exe")
    assert _clean_rejection(rc, out), out


# ---------------------------------------------------------------- produce / spawn

@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="every emit in a produce block has the stream's element type")
def test_every_emit_in_a_stream_has_the_element_type(tmp_path):
    entry = """place Entry {
fun main(): Number {
  be s := produce {
    emit 41
    emit "abc"
  }
  be total := s.fold(0, fun(a: Number, v: Number) => a + v)
  return total
}
}
"""
    _must_reject_checker(tmp_path, entry, "Text emitted on a Number stream")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="every promote in a spawn block has the collected stream's element type")
def test_every_promote_in_a_spawn_has_the_element_type(tmp_path):
    entry = """place Entry {
fun main(): Number {
  be results := spawn in 2 parallel {
    promote spawn_index + 1
    promote "abc"
  }
  be total := results.fold(0, fun(a: Number, v: Number) => a + v)
  return total
}
}
"""
    _must_reject_checker(tmp_path, entry, "Text promoted on a Number stream")


# ---------------------------------------------------------------- stdlib

@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a stdlib call's arguments must match its declared parameter types")
def test_stdlib_arguments_match_the_declared_signature(tmp_path):
    entry = """place Entry {
fun main(): Number {
  return Math.abs("abc")
}
}
"""
    _must_reject_checker(tmp_path, entry, "Text passed to Math.abs(Number)")


def test_a_prelude_string_function_rejects_a_number(tmp_path):
    entry = """place Entry {
fun main(): Number {
  return String.length(42)
}
}
"""
    proj = _project(tmp_path, entry)
    rc, out = _compile(proj, tmp_path / "exe")
    assert _clean_rejection(rc, out), out


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="the function passed to a stream fold is type-checked like any other lambda")
def test_a_fold_function_body_is_type_checked(tmp_path):
    entry = """place Entry {
fun main(): Number {
  be s := produce {
    emit 41
    emit 1
  }
  be total := s.fold(0, fun(a: Number, v: Number) => a + "zz")
  return total
}
}
"""
    _must_reject_checker(tmp_path, entry, "Number + Text inside the fold function")


def test_a_user_function_with_an_ordinary_name_is_called(tmp_path):
    entry = """place Entry {
  fun plus(a: Number, b: Number): Number { return a + b }
  fun main(): Number { return plus(40, 2) }
}
"""
    assert _value_checker(tmp_path, entry) == 42


def test_a_user_function_named_like_a_stream_combinator_is_called(tmp_path):
    entry = """place Entry {
  fun take(a: Number, b: Number): Number { return a + b }
  fun main(): Number { return take(40, 2) }
}
"""
    code = _value_checker(tmp_path, entry)
    _verdict(code == 42, f"take(40, 2) computed {code}, expected 42")


# ---------------------------------------------------------------- handle lambdas

def test_a_view_lambda_reads_its_section(tmp_path):
    entry = """place Entry {
  fun main(): Number {
    be vw := view(s: P) => s.v + 2 of P
    be sp := .-> P { v 40 }
    return vw(sp)
  }
}
"""
    assert _value_checker(tmp_path, entry, world=True) == 42


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="the body of a view lambda is type-checked")
def test_a_view_lambda_body_is_type_checked(tmp_path):
    entry = """place Entry {
  fun main(): Number {
    be vw := view(s: P) => s.v + "x" of P
    be sp := .-> P { v 40 }
    return vw(sp)
  }
}
"""
    _must_reject_checker(tmp_path, entry, "Number + Text in a view body", world=True)


# ---------------------------------------------------------------- move handlers

def test_a_move_converts_a_field_through_its_handler(tmp_path):
    entry = """place Entry {
  move PtoQ from P to Q {
    v converts to v by double_it
  }
  fun double_it(x: Number): Number { return x * 2 }
  fun main(): Number {
    be p := .-> P { v 21 }
    be q := apply_move(PtoQ, p)
    return q.v
  }
}
"""
    assert _value_checker(tmp_path, entry, world=True) == 42


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a move clause naming a handler that does not exist is rejected")
def test_a_move_naming_an_unknown_handler_is_rejected(tmp_path):
    entry = """place Entry {
  move PtoQ from P to Q {
    v converts to v by double_itt
  }
  fun double_it(x: Number): Number { return x * 2 }
  fun main(): Number {
    be p := .-> P { v 21 }
    be q := apply_move(PtoQ, p)
    return q.v
  }
}
"""
    _must_reject_checker(tmp_path, entry, "unknown handler double_itt", world=True)


# ---------------------------------------------------------------- let-polymorphism scope

def test_a_number_parameter_is_a_number(tmp_path):
    entry = """place Entry {
fun b(g: Number): Number { return g + 40 }
fun main(): Number { return b(2) }
}
"""
    assert _value_checker(tmp_path, entry) == 42


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a lambda bound in one function does not retype a same-named parameter of another")
def test_a_local_lambda_does_not_retype_a_parameter_elsewhere(tmp_path):
    entry = """place Entry {
fun a(): Number {
  be g := fun(x: Number) => x + 1
  return g(1)
}
fun b(g: Number): Number { return g + 40 }
fun main(): Number { return a() + b(0) }
}
"""
    proj = _project(tmp_path, entry)
    rc, out = _compile(proj, tmp_path / "exe")
    _verdict(rc == 0, f"well-typed program refused: {out.strip()[-200:]}")
    code, _ = _run(tmp_path / "exe")
    _verdict(code == 42, f"computed {code}, expected 42")


# === lowering to MLIR -------------------------------------------------

pytestmark_lowering = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_WORLD_lowering = '\n[world.W]\nobjects = ["X"]\nspaces  = ["w"]\n'
_TOPOS_lowering = {"w/Topos.yon": "topos WTopos where {\n}\n"}

_IPC_lowering = pytest.mark.skipif(not sys.platform.startswith(("darwin", "linux")),
                          reason="cross-Space calls need fork and POSIX shared memory")


def _build_run_lowering(tmp_path, entry, extra="", files=None):
    proj = _project(tmp_path, entry, extra, files)
    exe = tmp_path / "out"
    rc, out = _compile(proj, exe)
    assert rc == 0, out
    return _run(exe, cwd=tmp_path)


def _world_env_lowering(tmp_path):
    env = dict(os.environ)
    env["YON_WORLD"] = "p%03x" % (zlib.crc32(str(tmp_path).encode()) % 4096)
    return env


# --- local names and global functions ------------------------------------------

@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a local binding shadows a top-level function of the same name")
def test_a_local_binding_shadows_a_function_of_the_same_name(tmp_path):
    """`be total := 42` inside main makes `total` mean 42 there, even when a
    top-level function is called `total`."""
    entry = ("place Entry {\n"
             "fun total(): Number { return 1 }\n"
             "fun main(): Number {\n  be total := 41 + 1\n  return total\n}\n}\n")
    rc, _ = _build_run_lowering(tmp_path, entry)
    _verdict(rc == 42, f"the local `total` should be 42, main returned {rc}")


def test_a_local_binding_with_a_fresh_name_is_kept(tmp_path):
    entry = ("place Entry {\n"
             "fun total(): Number { return 1 }\n"
             "fun main(): Number {\n  be subtotal := 41 + 1\n  return subtotal + total() - 1\n}\n}\n")
    rc, _ = _build_run_lowering(tmp_path, entry)
    assert rc == 42


# --- arguments are evaluated once, before the call --------------------------------

_TWICE_RANDOM_lowering = ("place Entry {{\n"
                 "fun ident(y: Number): Number {{ return y }}\n"
                 "{twice}\n"
                 "fun main(): Number {{\n"
                 "  be _s := Random.seed(42)\n"
                 "  be d := {call}\n"
                 "  return if d == 0 then 7 else 9\n}}\n}}\n")


def test_a_higher_order_call_evaluates_a_random_argument_once(tmp_path):
    entry = _TWICE_RANDOM_lowering.format(
        twice="fun twice(f: Number -> Number, x: Number): Number { return f(x) - f(x) }",
        call="twice(ident, Random.range(0, 1000000))")
    rc, _ = _build_run_lowering(tmp_path, entry)
    _verdict(rc == 7, f"f(x) - f(x) differs from 0: x was drawn more than once (exit {rc})")


def test_a_first_order_call_evaluates_a_random_argument_once(tmp_path):
    entry = _TWICE_RANDOM_lowering.format(
        twice="fun twice(x: Number): Number { return ident(x) - ident(x) }",
        call="twice(Random.range(0, 1000000))")
    rc, _ = _build_run_lowering(tmp_path, entry)
    assert rc == 7


def test_a_higher_order_call_runs_an_argument_effect_once(tmp_path):
    entry = ("place Entry {\n"
             "fun ident(y: Number): Number { return y }\n"
             "fun twice(f: Number -> Number, x: Number): Number { return f(x) + f(x) }\n"
             "fun main(): Number {\n  be d := twice(ident, IO.print_num(5))\n  return 3\n}\n}\n")
    rc, out = _build_run_lowering(tmp_path, entry)
    assert rc == 3, out
    _verdict(out.split() == ["5"], f"the argument printed {out.split()!r}, expected one '5'")


def test_a_higher_order_call_evaluates_its_arguments_left_to_right(tmp_path):
    """As in a call: the arguments of an inlined higher-order call are
    evaluated before the body, in order, each once."""
    entry = ("place Entry {\n"
             "fun ident(y: Number): Number { return y }\n"
             "fun pick(f: Number -> Number, a: Number, b: Number): Number { return f(b) }\n"
             "fun main(): Number {\n  be d := pick(ident, IO.print_num(1), IO.print_num(2))\n  return 3\n}\n}\n")
    rc, out = _build_run_lowering(tmp_path, entry)
    assert rc == 3, out
    assert out.split() == ["1", "2"], f"the arguments printed {out.split()!r}"


# --- streams ---------------------------------------------------------------------

_INC_lowering = "fun inc(y: Number): Number { return y + 1 }\n"


def test_sum_take_of_an_iterate_sums_the_prefix(tmp_path):
    entry = ("place Entry {\n" + _INC_lowering +
             "fun main(): Number { return Stream.sum_take(Stream.iterate(inc, 1), 4) }\n}\n")
    rc, _ = _build_run_lowering(tmp_path, entry)
    assert rc == 10


def test_sum_take_of_a_named_stream_sums_the_prefix(tmp_path):
    entry = ("place Entry {\n" + _INC_lowering +
             "fun f(): Number {\n  be s := Stream.iterate(inc, 1)\n"
             "  return Stream.sum_take(s, 4)\n}\n"
             "fun main(): Number { return f() }\n}\n")
    proj = _project(tmp_path, entry)
    rc, out = _compile(proj, tmp_path / "out")
    if _clean_rejection(rc, out):
        return
    assert rc == 0, out
    code, _ = _run(tmp_path / "out", cwd=tmp_path)
    _verdict(code == 10, f"sum of the first 4 of 1,2,3,... should be 10, got {code}")


def test_a_named_stream_used_twice_is_read_twice(tmp_path):
    entry = ("place Entry {\n" + _INC_lowering +
             "fun f(): Number {\n  be s := Stream.iterate(inc, 1)\n"
             "  return Stream.sum_take(s, 4) + Stream.sum_take(s, 2)\n}\n"
             "fun main(): Number { return f() }\n}\n")
    rc, _ = _build_run_lowering(tmp_path, entry)
    assert rc == 13, f"10 + 3 expected, got {rc}"


def test_the_seed_of_a_named_stream_is_evaluated_once(tmp_path):
    entry = ("place Entry {\n" + _INC_lowering +
             "fun main(): Number {\n  be s := Stream.iterate(inc, IO.print_num(7))\n"
             "  be a := Stream.sum_take(s, 1)\n  be b := Stream.sum_take(s, 1)\n"
             "  return 3\n}\n}\n")
    rc, out = _build_run_lowering(tmp_path, entry)
    assert rc == 3 and out.split() == ["7"], (rc, out)


def test_a_stream_passed_to_a_function_is_refused_not_zero(tmp_path):
    entry = ("place Entry {\n" + _INC_lowering +
             "fun total(s: Stream<Number>): Number { return Stream.sum_take(s, 4) }\n"
             "fun main(): Number { return total(Stream.iterate(inc, 1)) }\n}\n")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    if rc == 0:
        code, _ = _run(tmp_path / "out", cwd=tmp_path)
        assert code == 10, f"a stream across a call computed {code}"
    else:
        assert _clean_rejection(rc, out), out


def test_a_user_function_named_iterate_is_called(tmp_path):
    entry = """place Entry {
  fun iterate(a: Number, b: Number): Number { return a * b }
  fun main(): Number { return iterate(6, 7) }
}
"""
    assert _value_checker(tmp_path, entry) == 42


def test_head_of_a_list_is_its_first_cons(tmp_path):
    entry = ("place Entry {\nfun main(): Number {\n"
             "  return List.head(List.cons(10, List.cons(11, List.empty(0))))\n}\n}\n")
    rc, _ = _build_run_lowering(tmp_path, entry)
    assert rc == 10


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="take(iterate(f, x0), n) starts with x0")
def test_take_of_an_iterate_starts_with_the_seed(tmp_path):
    entry = ("place Entry {\n" + _INC_lowering +
             "fun main(): Number {\n"
             "  return List.head(Stream.take(Stream.iterate(inc, 10), 3))\n}\n}\n")
    rc, _ = _build_run_lowering(tmp_path, entry)
    _verdict(rc == 10, f"head of [10, 11, 12] should be 10, got {rc}")


# --- operations need a handler ----------------------------------------------------

_COUNTER_lowering = dict(_TOPOS_lowering, **{"w/Counter.yon":
                           "place Counter {\n  count Number\n  operation tick(n: Number): Number\n}\n"})


def test_an_operation_with_a_handler_runs_the_handler(tmp_path):
    entry = ("place Entry {\n  reduction Bump of Counter {\n    be seed := 0\n"
             "    on tick(n: Number) {\n      return n + 1\n    }\n  }\n"
             "  fun main(): Number visits Counter { return Counter.tick(5) }\n}\n")
    rc, _ = _build_run_lowering(tmp_path, entry, _WORLD_lowering, _COUNTER_lowering)
    assert rc == 6


def test_an_operation_without_a_handler_is_refused(tmp_path):
    entry = ("place Entry {\n"
             "  fun main(): Number visits Counter { return Counter.tick(5) }\n}\n")
    proj = _project(tmp_path, entry, _WORLD_lowering, _COUNTER_lowering)
    rc, out = _compile(proj, tmp_path / "out")
    if _clean_rejection(rc, out):
        assert "[E2003]" in out, out
        return
    assert rc == 0, out
    code, _ = _run(tmp_path / "out", cwd=tmp_path)
    _verdict(False, f"an unhandled operation compiled and returned {code}")


def test_an_operation_called_in_a_condition_without_a_handler_is_refused(tmp_path):
    entry = ("place Entry {\n"
             "  fun main(): Number visits Counter {\n    be r := 0\n"
             "    when Counter.tick(5) > 0 { r = 1 }\n    return r\n  }\n}\n")
    proj = _project(tmp_path, entry, _WORLD_lowering, _COUNTER_lowering)
    rc, out = _compile(proj, tmp_path / "out")
    assert _clean_rejection(rc, out) and "[E2003]" in out, out


# --- integer division ------------------------------------------------------------

@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="an integer division by zero yields no ordinary quotient")
def test_integer_division_by_zero_is_not_an_ordinary_number(tmp_path):
    entry = ("place Entry {\n"
             "fun d(a: Int64, b: Int64): Int64 { return a / b }\n"
             "fun m(a: Int64, b: Int64): Int64 { return a % b }\n"
             "fun main(): Number {\n"
             "  be q := d(7, 0)\n"
             "  be r := m(7, 0)\n"
             "  return if q + r == 0 then 5 else 6\n}\n}\n")
    proj = _project(tmp_path, entry)
    rc, out = _compile(proj, tmp_path / "out")
    if _clean_rejection(rc, out):
        return
    assert rc == 0, out
    code, _ = _run(tmp_path / "out", cwd=tmp_path)
    _verdict(code > 0 and code not in (5, 6),
             f"7/0 and 7%0 ran to completion with ordinary values (exit {code})")


def test_integer_division_by_a_nonzero_truncates(tmp_path):
    entry = ("place Entry {\n"
             "fun d(a: Int64, b: Int64): Int64 { return a / b }\n"
             "fun main(): Number { return if d(7, 2) == 3 then (if d(0 - 7, 2) == 0 - 3 then 5 else 6) else 7 }\n}\n")
    rc, out = _build_run_lowering(tmp_path, entry)
    assert rc == 5, (rc, out)


# --- mutable cells are local to their function ------------------------------------

_P_lowering = dict(_TOPOS_lowering, **{"w/P.yon": "place P {\n  x Number\n}\n"})
_H_lowering = ("fun h(): Number {\n  be c := .-> P { x 1 }\n  c = .-> P { x 2 }\n  return c.x\n}\n")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a mutable number cell in main reads back the number stored in it")
def test_a_cell_reads_its_own_type_beside_a_namesake_place_cell(tmp_path):
    entry = ("place Entry {\n" + _H_lowering +
             "fun main(): Number {\n  be k := IO.print_num(h())\n"
             "  be c := 0\n  c = 7\n  return c\n}\n}\n")
    rc, out = _build_run_lowering(tmp_path, entry, _WORLD_lowering, _P_lowering)
    assert out.split() == ["2"], out
    _verdict(rc == 7, f"main's cell c holds 7, main returned {rc}")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a mutable number cell is a number in arithmetic, whatever another function names its cells")
def test_a_number_cell_beside_a_namesake_place_cell_compiles(tmp_path):
    entry = ("place Entry {\n" + _H_lowering +
             "fun main(): Number {\n  be k := h()\n"
             "  be c := 0\n  c = 7\n  return c + k * 10\n}\n}\n")
    proj = _project(tmp_path, entry, _WORLD_lowering, _P_lowering)
    rc, out = _compile(proj, tmp_path / "out")
    _verdict(rc == 0, "a well-typed program is refused downstream:\n" + out[-600:])
    code, _ = _run(tmp_path / "out", cwd=tmp_path)
    assert code == 27


def test_cells_with_distinct_names_keep_their_types(tmp_path):
    entry = ("place Entry {\n" + _H_lowering +
             "fun main(): Number {\n  be k := h()\n"
             "  be d := 0\n  d = 7\n  return d + k * 10\n}\n}\n")
    rc, _ = _build_run_lowering(tmp_path, entry, _WORLD_lowering, _P_lowering)
    assert rc == 27


# --- move handlers ---------------------------------------------------------------

_TEMPS_lowering = dict(_TOPOS_lowering, **{"w/Celsius.yon": "place Celsius { degrees Number }\n",
                         "w/Fahrenheit.yon": "place Fahrenheit { degrees Number }\n"})
_MOVE_lowering = ("place Entry {{\n{local}"
         "  move M from Celsius to Fahrenheit {{\n    degrees maps to degrees by {by}\n  }}\n"
         "  fun main(): Number {{\n    be c := .-> Celsius {{ degrees 100 }}\n"
         "    be f := apply_move(M, c)\n    return f.degrees + {bias}\n  }}\n}}\n")


def test_a_move_applies_a_local_handler(tmp_path):
    entry = _MOVE_lowering.format(local="  fun halve(c: Number): Number { return c / 2 }\n",
                         by="halve", bias=0)
    rc, _ = _build_run_lowering(tmp_path, entry, _WORLD_lowering, _TEMPS_lowering)
    assert rc == 50


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a move applies its handler wherever the handler is declared")
@pytest.mark.parametrize("home", ["prelude", "source_place"])
def test_a_move_applies_a_handler_declared_elsewhere(tmp_path, home):
    files = dict(_TEMPS_lowering)
    if home == "prelude":
        entry, expected = _MOVE_lowering.format(local="", by="negate", bias=200), 100
    else:
        files["w/Celsius.yon"] = ("place Celsius {\n  degrees Number\n"
                                  "  fun halve(c: Number): Number { return c / 2 }\n}\n")
        entry, expected = _MOVE_lowering.format(local="", by="halve", bias=0), 50
    rc, _ = _build_run_lowering(tmp_path, entry, _WORLD_lowering, files)
    _verdict(rc == expected, f"converted degrees should give {expected}, got {rc}")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a move handler that names no function is refused")
def test_a_move_handler_must_name_a_function(tmp_path):
    entry = _MOVE_lowering.format(local="", by="nosuch_fn", bias=0)
    proj = _project(tmp_path, entry, _WORLD_lowering, _TEMPS_lowering)
    rc, out = _compile(proj, tmp_path / "out")
    if _clean_rejection(rc, out):
        return
    assert rc == 0, out
    code, _ = _run(tmp_path / "out", cwd=tmp_path)
    _verdict(False, f"a move by an undefined handler compiled and returned {code}")


# --- cross-Space calls -----------------------------------------------------------

def _cross_space_call_lowering(tmp_path, offset):
    (tmp_path / "shifter.yon").write_text(
        "place Entry {\n"
        f"  fun shift(x: Number): Number {{ return x - {offset} }}\n"
        "  fun main(): Number { return 0 }\n}\n")
    (tmp_path / "client.yon").write_text(
        "import shifter::shift from Shifter\n"
        "place Entry {\n  fun main(): Number {\n"
        "    be _p := IO.print_num(shift(0))\n    return 3\n  }\n}\n")
    for src, out in (("shifter.yon", "Shifter_srv"), ("client.yon", "client")):
        rc, log = _compile(tmp_path / src, tmp_path / out, cwd=tmp_path)
        assert rc == 0, log
    r = subprocess.run([str(tmp_path / "client")], cwd=tmp_path, capture_output=True,
                       text=True, timeout=60, env=_world_env_lowering(tmp_path))
    return r.returncode, r.stdout, r.stderr


@_IPC_lowering
def test_a_cross_space_call_returns_its_value(tmp_path):
    rc, out, err = _cross_space_call_lowering(tmp_path, 776)
    assert (rc, out.split()) == (3, ["-776"]), err
    assert "failed" not in err


@_IPC_lowering
@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="every number is a legal cross-Space result, -777 included")
def test_any_number_is_a_legal_cross_space_result(tmp_path):
    rc, out, err = _cross_space_call_lowering(tmp_path, 777)
    assert rc == 3, err
    _verdict(out.split() == ["-777"] and "failed" not in err,
             f"the result -777 was reported as a failure: {err.strip()!r}")


# --- the wire boundary -----------------------------------------------------------

_SHM_TOML_lowering = ('[package]\nname = "{name}"\n\n[runtime]\nbackend = "shm"\n\n'
             '[world.W]\nobjects = ["X"]\nspaces  = [{spaces}]\n')
_SAMPLES_lowering = ("  fun samples(): Wire<Reading> {\n    be s := produce {\n"
            "      emit .-> Reading { temp 10 humidity 50 }\n"
            "      emit .-> Reading { temp 11 humidity 51 }\n"
            "      emit .-> Reading { temp 15 humidity 52 }\n    }\n    return s\n  }\n")


def _wire_lowering(tmp_path, consumer_reading):
    svc, sub = tmp_path / "meteo_svc", tmp_path / "meteo_sub"
    files = {
        svc / "yon.toml": _SHM_TOML_lowering.format(name="meteo_svc", spaces='"w"'),
        svc / "Entry.yon": "place Entry {\n  fun main(): Number { return 0 }\n}\n",
        svc / "w/Topos.yon": "topos WTopos where {\n}\n",
        svc / "w/Reading.yon": "place Reading {\n  temp Number\n  humidity Number\n\n" + _SAMPLES_lowering + "}\n",
        sub / "yon.toml": _SHM_TOML_lowering.format(name="meteo_sub", spaces='"w", "Meteo"'),
        sub / "Entry.yon": ("import meteo::samples from Meteo\n\nplace Entry {\n"
                            "  fun main(): Number {\n    be w := wire to space Meteo\n"
                            "    be sub := w.awaits(samples)\n    be s := sub.stream\n"
                            "    be total := s.fold(0, fun(a: Number, r: Reading) => a + r.temp)\n"
                            "    return total\n  }\n}\n"),
        sub / "w/Topos.yon": "topos WTopos where {\n}\n",
        sub / "w/Reading.yon": consumer_reading,
        sub / "yon_modules/meteo/meteo.yon": (
            "fun samples(): Wire<Reading> {\n"
            "  be s := produce { emit .-> Reading { temp 10 humidity 50 } }\n  return s\n}\n"),
    }
    for p, text in files.items():
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    rc, log = _compile(svc, tmp_path / "Meteo_srv", cwd=tmp_path)
    assert rc == 0, log
    rc, log = _compile(sub, tmp_path / "sub", cwd=tmp_path)
    if _clean_rejection(rc, log):
        return None
    assert rc == 0, log
    r = subprocess.run([str(tmp_path / "sub")], cwd=tmp_path, capture_output=True,
                       text=True, timeout=60, env=_world_env_lowering(tmp_path))
    return r.returncode


@_IPC_lowering
def test_a_place_crosses_the_wire_by_field(tmp_path):
    assert _wire_lowering(tmp_path, "place Reading {\n  temp Number\n  humidity Number\n}\n") == 36


@_IPC_lowering
@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a place whose fields are declared in another order is a different schema at the wire")
def test_reordered_fields_do_not_cross_the_wire_by_position(tmp_path):
    rc = _wire_lowering(tmp_path, "place Reading {\n  humidity Number\n  temp Number\n}\n")
    _verdict(rc != 50 + 51 + 52,
             f"the consumer read humidity as temp: sum of temp is {rc}, the temps sum to 36")


# === desugaring -------------------------------------------------------

def _build_run_desugar(tmp_path, entry, extra="", files=None):
    """(compile rc, compile output, exit code or None, stdout)."""
    proj = _project(tmp_path, entry, extra, files)
    exe = tmp_path / "exe"
    rc, out = _compile(proj, exe)
    if rc != 0 or not exe.exists():
        return rc, out, None, ""
    code, stdout = _run(exe)
    return rc, out, code, stdout


def _value_desugar(tmp_path, entry, extra="", files=None):
    """main's exit code; a refused or crashing compile is a broken law too."""
    rc, out, code, _ = _build_run_desugar(tmp_path, entry, extra, files)
    _verdict(rc == 0 and code is not None, f"the program does not compile: {out[-400:]}")
    return code


# ─── floor: every floor the language offers agrees with C libm ─────────────

_libm_desugar = ctypes.CDLL(ctypes.util.find_library("m"))
_libm_desugar.floor.restype = ctypes.c_double
_libm_desugar.floor.argtypes = [ctypes.c_double]

FLOOR_GRID_desugar = [-1.5, -0.5, -2.0, -1e-300, -0.0, 0.0, 1e-300, 0.5, 1.5, 2.0, 2.5, -2.5,
              3.0, -3.0, 0.1, -0.1, 0.9999999999999999, -0.9999999999999999,
              1e15, 1e15 + 0.5, -(1e15 + 0.5), 4.5e15, 4503599627370495.5,
              -4503599627370495.5, 1e300, -1e300]


def _lit_desugar(x):
    if x == 0.0:
        return "(0 * (0 - 1))" if math.copysign(1.0, x) < 0 else "0"
    s = format(Decimal(repr(abs(x))), "f")
    return f"(0 - {s})" if x < 0 else s


def _floor_program_desugar(form):
    calls = "\n".join(
        f"  be _c{i} := check(f({_lit_desugar(x)}), {_lit_desugar(_libm_desugar.floor(x))})"
        for i, x in enumerate(FLOOR_GRID_desugar))
    return ("place Entry {}\n"
            f"fun f(x: Number): Number {{ return {form} }}\n"
            "fun check(got: Number, want: Number): Number {\n"
            "  be _p := IO.print_num(if got == want and 1 / got == 1 / want then 1 else 0)\n"
            "  be _q := IO.print_num(got)\n"
            "  return 0\n}\n"
            "fun main(): Number {\n" + calls + "\n  return 0\n}\n")


def _floor_disagreements_desugar(tmp_path, form):
    rc, out, code, stdout = _build_run_desugar(tmp_path, _floor_program_desugar(form))
    assert rc == 0 and code == 0, f"the grid program does not run: {out[-400:]}"
    toks = stdout.split()
    assert len(toks) == 2 * len(FLOOR_GRID_desugar), f"unexpected output: {stdout!r}"
    return [(x, toks[2 * i + 1], _libm_desugar.floor(x))
            for i, x in enumerate(FLOOR_GRID_desugar) if toks[2 * i] != "1"]


def test_the_sign_of_negative_zero_survives_numbers_functions(tmp_path):
    """-0 in, -0 out, as in libm: Number.sqrt, Number.sin, Number.floor and
    the bare floor."""
    src = ("place Entry {}\n"
           "fun neg(x: Number): Number { return if 1 / x < 0 then 1 else 0 }\n"
           "fun main(): Number {\n"
           "  be z := 0 * (0 - 1)\n"
           "  be r := match Number.sqrt(z) { Number as v => v, DomainError as d => 1 }\n"
           "  return neg(r) * 1000 + neg(Number.sin(z)) * 100 + neg(Number.floor(z)) * 10\n"
           "       + neg(floor(z))\n"
           "}\n")
    rc, out, code, _ = _build_run_desugar(tmp_path, src)
    assert rc == 0, out
    assert code == 1111 % 256, f"signs of -0 through sqrt, sin, floor, bare floor: {code}"


def test_bare_floor_agrees_with_libm_on_the_grid(tmp_path):
    bad = _floor_disagreements_desugar(tmp_path, "floor(x)")
    _verdict(not bad, f"floor(x) disagrees with libm (x, got, libm): {bad}")


def test_method_floor_agrees_with_libm_on_the_grid(tmp_path):
    bad = _floor_disagreements_desugar(tmp_path, "x.floor()")
    _verdict(not bad, f"x.floor() disagrees with libm (x, got, libm): {bad}")


def test_math_floor_agrees_with_libm_on_the_grid(tmp_path):
    assert _floor_disagreements_desugar(tmp_path, "Math.floor(x)") == []


def test_number_floor_agrees_with_libm_on_the_grid(tmp_path):
    assert _floor_disagreements_desugar(tmp_path, "Number.floor(x)") == []


# ─── a method resolution belongs to its call site, file included ──────────

_OV_TOML_desugar = '[world.W]\nobjects = ["X"]\nspaces  = ["w"]'
_SQUARE_desugar = ("place Square {\n  side := Number\n"
           "  fun area(s: Square): Number { return s.side * s.side }\n}\n")
_ENTRY_RESOLVED_desugar = ("place Entry {}\n"
                   "fun main(): Number {\n"
                   "  be sq := .-> Square { side 5 }\n"
                   "  be ci := .-> Circle { r 2 }\n"
                   "  return sq.area() + Circle.k(sq)\n"
                   "}\n")


def _circle_desugar(indent):
    # line 5 of this file: the call `seven(s)` sits at the same (line, col) as
    # `sq.area()` in Entry.yon when indent is two spaces.
    return ("place Circle {\n  r := Number\n"
            "  fun area(c: Circle): Number { return c.r * c.r * 3 }\n"
            "  fun k(s: Square): Number {\n"
            f"{indent}return seven(s) + 0 }}\n"
            "  fun seven(s: Square): Number { return 7 }\n}\n")


def _ov_files_desugar(indent):
    return {"w/Topos.yon": "topos CTopos where {\n}\n",
            "w/Square.yon": _SQUARE_desugar, "w/Circle.yon": _circle_desugar(indent)}


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a call resolved in one file never renames a call at the same line and column of another file")
def test_a_method_resolution_stays_in_its_own_file(tmp_path):
    v = _value_desugar(tmp_path, _ENTRY_RESOLVED_desugar, _OV_TOML_desugar, _ov_files_desugar("  "))
    _verdict(v == 32, f"Square.area(5) + seven = 25 + 7 = 32, got {v}")


def test_a_method_resolution_with_distinct_positions(tmp_path):
    assert _value_desugar(tmp_path, _ENTRY_RESOLVED_desugar, _OV_TOML_desugar, _ov_files_desugar("   ")) == 32


# ─── a let-bound lambda is a binding like any other ────────────────────────

_SUM_DECL_desugar = "fun declares(s: (Box(Number) | Empty)): Number { return 0 }\n"


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a local binding shadows a top-level function of the same name inside a match arm")
def test_a_let_bound_lambda_wins_over_a_top_level_homonym_in_a_match_arm(tmp_path):
    src = ("place Entry {}\n"
           "fun sq(x: Number): Number { return 1000 }\n"
           "fun main(): Number {\n"
           "  be sq := fun(x: Number) => x * x\n"
           "  return match hit(Box, 3) { Box(v) => sq(v), Empty => 0 }\n"
           "}\n" + _SUM_DECL_desugar)
    v = _value_desugar(tmp_path, src)
    _verdict(v == 9, f"sq(3) with the local sq is 9, got {v} (1000 mod 256 = 232 is the top-level sq)")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a let-bound lambda is callable from a match arm")
def test_a_let_bound_lambda_is_callable_from_a_match_arm(tmp_path):
    src = ("place Entry {}\n"
           "fun main(): Number {\n"
           "  be sq := fun(x: Number) => x * x\n"
           "  return match hit(Box, 3) { Box(v) => sq(v), Empty => 0 }\n"
           "}\n" + _SUM_DECL_desugar)
    v = _value_desugar(tmp_path, src)
    _verdict(v == 9, f"sq(3) is 9, got {v}")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="an inner binding shadows an outer let-bound lambda of the same name")
def test_an_inner_binding_shadows_a_let_bound_lambda(tmp_path):
    src = ("place Entry {}\n"
           "fun main(): Number {\n"
           "  be f := fun(x: Number) => x + 1\n"
           "  when true {\n"
           "    be f := 5\n"
           "    return f\n"
           "  } otherwise {\n"
           "    return 0\n"
           "  }\n"
           "}\n")
    v = _value_desugar(tmp_path, src)
    _verdict(v == 5, f"the inner f is 5, got {v}")


def test_a_let_bound_lambda_is_callable_directly(tmp_path):
    src = ("place Entry {}\n"
           "fun main(): Number {\n"
           "  be sq := fun(x: Number) => x * x\n"
           "  return sq(3)\n"
           "}\n")
    assert _value_desugar(tmp_path, src) == 9


# ─── an arm's tag belongs to its sum, not to its name ─────────────────────

_AB_TOML_desugar = '[world.W]\nobjects = ["A", "B"]'


def _ab_program_desugar(b_arms, main_body):
    return ("place A { this > X :U Y }\n"
            f"place B {{ this > {b_arms} }}\n"
            "place Entry {}\n"
            "fun code(a: A): Number { return match a { X => 1, Y => 2 } }\n"
            f"fun main(): Number {{ return {main_body} }}\n")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a match on a sum dispatches on that sum's own tags, whatever other sums name their arms")
def test_homonymous_arms_across_sums_keep_their_own_tags(tmp_path):
    v = _value_desugar(tmp_path, _ab_program_desugar("Z :U X", "code(Y)"), _AB_TOML_desugar)
    _verdict(v == 2, f"code(Y) is 2, got {v}")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a bare point is resolved by the expected sum, so X is an A where an A is expected")
def test_a_bare_point_is_resolved_by_the_expected_sum(tmp_path):
    v = _value_desugar(tmp_path, _ab_program_desugar("Z :U X", "code(X)"), _AB_TOML_desugar)
    _verdict(v == 1, f"code(X) is 1, got {v}")


def test_distinct_arm_names_dispatch_by_tag(tmp_path):
    assert _value_desugar(tmp_path, _ab_program_desugar("Z :U W", "code(X) * 10 + code(Y)"), _AB_TOML_desugar) == 12


# ─── a Boolean match with a wildcard ───────────────────────────────────────

def _bool_program_desugar(arms):
    return ("place Entry {}\n"
            f"fun pick(b: Boolean): Number {{ return match b {{ {arms} }} }}\n"
            "fun main(): Number { return pick(true) * 10 + pick(false) }\n")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a leading wildcard either catches every value or is the complement of the other arm")
def test_a_leading_wildcard_in_a_boolean_match(tmp_path):
    v = _value_desugar(tmp_path, _bool_program_desugar("_ => 7, true => 1"))
    # first-match: 77; wildcard-as-complement: true -> 1, false -> 7 = 17.
    _verdict(v in (77, 17), f"expected 77 or 17, got {v}")


def test_a_trailing_wildcard_in_a_boolean_match(tmp_path):
    assert _value_desugar(tmp_path, _bool_program_desugar("true => 1, _ => 7")) == 17


# ─── forces evaluates its condition ────────────────────────────────────────

@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a stage that does not force its condition does not run the forced body")
def test_forces_does_not_run_its_body_under_a_false_condition(tmp_path):
    src = ("place Entry {}\n"
           "fun main(): Number {\n"
           "  be acc := 0\n"
           "  forces Stage 1 == 2 {\n"
           "    acc = acc + 5\n"
           "  }\n"
           "  return acc\n"
           "}\n")
    v = _value_desugar(tmp_path, src)
    _verdict(v == 0, f"1 == 2 is false, the body must not run: got {v}")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="the condition of forces is type-checked like any condition")
def test_forces_rejects_an_ill_typed_condition(tmp_path):
    src = ("place Entry {}\n"
           "fun main(): Number {\n"
           "  be acc := 0\n"
           "  forces Stage nowhere_defined + \"x\" {\n"
           "    acc = acc + 5\n"
           "  }\n"
           "  return acc\n"
           "}\n")
    proj = _project(tmp_path, src)
    rc, out = _compile(proj, tmp_path / "exe")
    _verdict(_clean_rejection(rc, out), f"an undefined name in the condition is accepted (rc={rc})")


def test_when_does_not_run_its_body_under_a_false_condition(tmp_path):
    src = ("place Entry {}\n"
           "fun main(): Number {\n"
           "  be acc := 0\n"
           "  when 1 == 2 {\n"
           "    acc = acc + 5\n"
           "  }\n"
           "  return acc\n"
           "}\n")
    assert _value_desugar(tmp_path, src) == 0


# ─── a naturality counterexample refuses the program ──────────────────────

_SHOP_TOML_desugar = '[world.Shop]\nobjects = ["X"]\nspaces  = ["shop"]'
_SHOP_FILES_desugar = {"shop/Topos.yon": "topos ShopTopos where {\n}\n",
               "shop/Account.yon": "place Account { balance Number }\n",
               "shop/AccountEU.yon": "place AccountEU { balance Number }\n"}
_NOT_NATURAL_desugar = ("place Entry {}\n"
                "fun df(b: Number): Number { return b + 1 }\n"
                "fun dg(b: Number): Number { return b + 1 }\n"
                "fun eta(b: Number): Number { return b * 2 }\n"
                "morph F from Account to AccountEU {\n  on morphism deposit via df\n}\n"
                "morph G from Account to AccountEU {\n  on morphism deposit via dg\n}\n"
                "nat transform Eta from F to G {\n  for each deposit by eta\n}\n"
                "fun main(): Number { return 0 }\n")


@pytest.mark.skipif(shutil.which("z3") is None or not FRONTEND.exists(),
                    reason="needs z3 on PATH and the built frontend")
def test_a_naturality_counterexample_refuses_the_program(tmp_path):
    """A natural transformation whose square has a counterexample (2x+2 vs
    2x+1) is refused with the refuted-law code, and the counterexample is
    shown to whoever compiles."""
    proj = _project(tmp_path, _NOT_NATURAL_desugar, _SHOP_TOML_desugar, _SHOP_FILES_desugar)
    env = dict(os.environ)
    r = subprocess.run([str(YONC), str(proj), "-o", str(tmp_path / "exe")],
                       capture_output=True, text=True, timeout=120, env=env)
    out = r.stdout + r.stderr
    assert _clean_rejection(r.returncode, out), out
    assert "[E2101]" in out and "counterexample" in out, out


# ─── reduction handler bodies are lowered like function bodies ────────────

_W_TOML_desugar = '[world.W]\nobjects = ["X"]\nspaces  = ["w"]'
_COUNTER_desugar = {"w/Topos.yon": "topos WTopos where {\n}\n",
            "w/Counter.yon": ("place Counter {\n  count Number\n"
                              "  operation tick(n: Number): Number\n}\n")}


def _reduction_desugar(body):
    return ("place Entry {\n"
            "  reduction Accumulate of Counter {\n"
            "    on tick(n: Number) {\n"
            f"{body}"
            "    }\n  }\n"
            "  fun main(): Number { return 7 }\n}\n")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a loop in a reduction handler body compiles like a loop in a function body")
def test_a_reduction_handler_body_may_loop(tmp_path):
    body = ("      be acc := 0\n"
            "      repeat at most 3 times { acc = acc + n }\n"
            "      return acc\n")
    v = _value_desugar(tmp_path, _reduction_desugar(body), _W_TOML_desugar, _COUNTER_desugar)
    _verdict(v == 7, f"main returns 7, got {v}")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a reassignment in a reduction handler body compiles like one in a function body")
def test_a_reduction_handler_body_may_reassign(tmp_path):
    body = ("      be acc := 0\n"
            "      acc = acc + n\n"
            "      return acc\n")
    v = _value_desugar(tmp_path, _reduction_desugar(body), _W_TOML_desugar, _COUNTER_desugar)
    _verdict(v == 7, f"main returns 7, got {v}")


def test_a_reduction_handler_body_with_a_plain_return(tmp_path):
    assert _value_desugar(tmp_path, _reduction_desugar("      return n + 1\n"), _W_TOML_desugar, _COUNTER_desugar) == 7


# ─── a stream may carry every Number ──────────────────────────────────────

def _stream_count_desugar(middle):
    return ("place Entry {\n"
            "fun main(): Number {\n"
            "  be s := produce {\n"
            "    emit 3\n"
            f"    emit {middle}\n"
            "    emit 1\n"
            "  }\n"
            "  return s.fold(0, fun(a: Number, v: Number) => a + 1)\n"
            "}\n}\n")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a fold over a stream visits every emitted value, 4294967295 included")
def test_a_stream_may_carry_4294967295(tmp_path):
    v = _value_desugar(tmp_path, _stream_count_desugar("4294967295"))
    _verdict(v == 3, f"three values were emitted, the fold counted {v}")


def test_a_stream_may_carry_4294967294(tmp_path):
    assert _value_desugar(tmp_path, _stream_count_desugar("4294967294")) == 3


# ─── a named proof value is a binding like any other ──────────────────────

@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a path bound by name is in scope in a later reassignment")
def test_a_named_path_is_in_scope_in_a_reassignment(tmp_path):
    src = ("place Entry {}\n"
           "fun main(): Number {\n"
           "  be p := clear 7\n"
           "  be acc := 0\n"
           "  acc = p @ I0\n"
           "  return acc\n"
           "}\n")
    v = _value_desugar(tmp_path, src)
    _verdict(v == 7, f"clear 7 read at I0 is 7, got {v}")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a sum value bound by name is in scope in a later reassignment")
def test_a_named_sum_value_is_in_scope_in_a_reassignment(tmp_path):
    src = ("place Box { this > Full(Number) :U Empty }\n"
           "place Entry {}\n"
           "fun code(b: Box): Number { return match b { Full(n) => n, Empty => 0 } }\n"
           "fun main(): Number {\n"
           "  be v := hit(Full, 5)\n"
           "  be acc := 0\n"
           "  acc = code(v)\n"
           "  return acc\n"
           "}\n")
    v = _value_desugar(tmp_path, src, '[world.W]\nobjects = ["Box"]')
    _verdict(v == 5, f"code(Full 5) is 5, got {v}")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="the method form a.concat(b) on two Strings is String concatenation")
def test_string_concat_method_form(tmp_path):
    src = ("place Entry {}\n"
           "fun main(): Number {\n"
           "  be a := \"ab\"\n"
           "  be b := \"cde\"\n"
           "  be s := a.concat(b)\n"
           "  return String.length(s)\n"
           "}\n")
    v = _value_desugar(tmp_path, src)
    _verdict(v == 5, f"length of \"abcde\" is 5, got {v}")


def test_string_concat_qualified_form(tmp_path):
    src = ("place Entry {}\n"
           "fun main(): Number {\n"
           "  be a := \"ab\"\n"
           "  be b := \"cde\"\n"
           "  be s := String.concat(a, b)\n"
           "  return String.length(s)\n"
           "}\n")
    assert _value_desugar(tmp_path, src) == 5


def test_a_named_path_is_in_scope_in_a_binding(tmp_path):
    src = ("place Entry {}\n"
           "fun main(): Number {\n"
           "  be p := clear 7\n"
           "  be acc := p @ I0\n"
           "  return acc\n"
           "}\n")
    assert _value_desugar(tmp_path, src) == 7


# === the kernel: identity types, cubical, conversion ------------------

_TWO_OBJECTS_kernel = '[world.W]\nobjects = ["Bool", "Bit"]\n'
_BOX_kernel = '[world.W]\nobjects = ["Box"]\n'


def _build_kernel(tmp_path, entry, extra=""):
    rc, out = _compile(_project(tmp_path, entry, extra), tmp_path / "out")
    return rc, out


# --- El: a code is a term, compared by its structure -------------------------

_FAMILY_kernel = "  fun Fam(x: Number): Type_0 { return if x > 7 then text else number }\n"


def test_codes_applied_to_different_arguments_are_different_types(tmp_path):
    entry = ("place Entry {\n" + _FAMILY_kernel +
             "  fun cast(e: El(Fam(7))): El(Fam(8)) { return e }\n"
             "  fun main(): Number { return 0 }\n}\n")
    rc, out = _build_kernel(tmp_path, entry)
    _verdict(_clean_rejection(rc, out),
             f"El(Fam(7)) was accepted as El(Fam(8)) (rc={rc})")


def test_codes_of_different_families_are_different_types(tmp_path):
    entry = ("place Entry {\n"
             "  fun Fam(x: Number): Type_0 { return number }\n"
             "  fun Gam(x: Number): Type_0 { return text }\n"
             "  fun cast(e: El(Fam(7))): El(Gam(7)) { return e }\n"
             "  fun main(): Number { return 0 }\n}\n")
    rc, out = _build_kernel(tmp_path, entry)
    assert _clean_rejection(rc, out), out


# --- transport along a univalence path lands in the target -------------------

_BOOL_BIT_kernel = (
    "place Bool { this > tt :U ff }\n"
    "place Bit  { this > one :U zero }\n"
    "place Entry {\n"
    "fun b2bit(b: Bool): Bit { return match b { tt => one, ff => zero } }\n"
    "fun bit2b(x: Bit): Bool { return match x { one => tt, zero => ff } }\n"
    "fun eta(a: Bool): Id(Bool, bit2b(b2bit(a)), a) { return match a { tt => clear tt, ff => clear ff } }\n"
    "fun eps(b: Bit): Id(Bit, b2bit(bit2b(b)), b) { return match b { one => clear one, zero => clear zero } }\n")


def test_transport_along_a_named_univalence_path_lands_in_the_target(tmp_path):
    entry = _BOOL_BIT_kernel + (
        "fun main(): Number {\n"
        "  be u := ua(equiv(b2bit, bit2b, eta, eps))\n"
        "  be y := transport(u, tt)\n"
        "  return match y { one => 1, zero => 0 }\n}\n}\n")
    rc, out = _build_kernel(tmp_path, entry, _TWO_OBJECTS_kernel)
    _verdict(rc == 0, f"a match on Bit constructors of the transported value was refused:\n{out[-300:]}")
    assert _run(tmp_path / "out")[0] == 1


def test_transport_along_a_named_univalence_path_leaves_the_source(tmp_path):
    entry = _BOOL_BIT_kernel + (
        "fun main(): Number {\n"
        "  be u := ua(equiv(b2bit, bit2b, eta, eps))\n"
        "  be y := transport(u, tt)\n"
        "  return match y { tt => 1, ff => 2 }\n}\n}\n")
    rc, out = _build_kernel(tmp_path, entry, _TWO_OBJECTS_kernel)
    if _clean_rejection(rc, out):
        return
    assert rc == 0, out
    got, _ = _run(tmp_path / "out")
    raise ProbeOutcome(f"a Bit value was matched as a Bool and returned {got}")


def test_transport_along_an_inline_univalence_path_lands_in_the_target(tmp_path):
    entry = _BOOL_BIT_kernel + (
        "fun main(): Number {\n"
        "  be y := transport(ua(equiv(b2bit, bit2b, eta, eps)), tt)\n"
        "  return match y { one => 1, zero => 0 }\n}\n}\n")
    rc, out = _build_kernel(tmp_path, entry, _TWO_OBJECTS_kernel)
    assert rc == 0, out
    assert _run(tmp_path / "out")[0] == 1


# --- the ring laws hold where the carrier is a ring --------------------------

# Int64 is Z/2^64: distributivity holds, and so does a law true only modulo
# 2^64 (2^62 * 4 is 0). Number is f64, not a ring: distributivity is not an
# identity there, and refl does not prove it.
_RING_LAWS = {
    "distributivity_on_int64": ("x: Int64", "x * (x + 1), x * x + x", True),
    "wrapping_on_int64": ("x: Int64", "x * 4611686018427387904 * 4, 0", True),
    "a_false_int64_identity": ("x: Int64", "x * 2, x + x + 1", False),
    "distributivity_on_numbers": ("x: Number", "x * (x + 1), x * x + x", False),
}


@pytest.mark.parametrize("law", sorted(_RING_LAWS))
def test_refl_proves_exactly_the_ring_laws_of_the_carrier(tmp_path, law):
    param, sides, holds = _RING_LAWS[law]
    entry = (f"place Entry {{\n  fun identity({param}): Same({sides}) {{ return clear }}\n"
             "  fun main(): Number { return 42 }\n}\n")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    if holds:
        assert rc == 0, out
        assert _run(tmp_path / "out")[0] == 42
    else:
        assert _clean_rejection(rc, out), out


# --- an identity on numbers holds for floating-point numbers -----------------

def _accepted_identity_is_false_kernel(tmp_path, entry):
    rc, out = _build_kernel(tmp_path, entry)
    if _clean_rejection(rc, out):
        return
    assert rc == 0, out
    differs, _ = _run(tmp_path / "out")
    _verdict(differs == 0, "an identity was accepted whose two sides differ at run time")


def test_dividing_back_is_not_an_identity_on_floats(tmp_path):
    entry = ("place Entry {\n"
             "  fun third(x: Number): Id(Number, (x * 3) / 3, x) { return clear x }\n"
             "  fun differs(x: Number): Number { return if (x * 3) / 3 == x then 0 else 1 }\n"
             "  fun main(): Number { return differs(0.1) }\n}\n")
    _accepted_identity_is_false_kernel(tmp_path, entry)


def test_large_coefficients_do_not_wrap(tmp_path):
    big = "2305843009213693952"
    lhs = "(a + 2147483648) * (b + 2147483648)"
    rhs = f"a * b + 2147483648 * a + 2147483648 * b - {big} - {big}"
    entry = ("place Entry {\n"
             f"  fun wide(a: Number, b: Number): Id(Number, {lhs}, {rhs}) {{ return clear ({lhs}) }}\n"
             f"  fun lhs(a: Number, b: Number): Number {{ return {lhs} }}\n"
             f"  fun rhs(a: Number, b: Number): Number {{ return {rhs} }}\n"
             "  fun main(): Number { return if lhs(0, 0) == rhs(0, 0) then 0 else 1 }\n}\n")
    _accepted_identity_is_false_kernel(tmp_path, entry)


def test_a_shifted_value_is_not_identical_to_itself(tmp_path):
    entry = ("place Entry {\n"
             "  fun off(x: Number): Id(Number, x + 1, x) { return clear x }\n"
             "  fun main(): Number { return 0 }\n}\n")
    rc, out = _build_kernel(tmp_path, entry)
    assert _clean_rejection(rc, out), out


# --- naturality ----------------------------------------------------------------

@pytest.mark.skipif(not FRONTEND.exists(), reason="frontend emitter not built")
def test_naturality_is_not_proven_for_a_square_that_does_not_commute(tmp_path):
    entry = ("place Entry {\n"
             "  fun shift(input: Number): Number { return input - 5 }\n"
             "  fun mark(input: Path): Path { return clear input }\n"
             "  fun eta(input: Number): Path { return clear input }\n"
             "  morph M1 from A to B { on morphism step via shift }\n"
             "  morph M2 from A to B { on morphism step via mark }\n"
             "  nat transform Eta from M1 to M2 { for each step by eta }\n"
             "  fun main(): Number { return __check_naturality_Eta__step(3) }\n}\n")
    proj = _project(tmp_path, entry)
    fe = subprocess.run([str(FRONTEND), str(proj)], capture_output=True, text=True, timeout=120)
    # the square is not proven (its components carry `clear input`, outside the
    # modelled fragment), so it is not certified: the program is refused
    assert "proven" not in fe.stderr.lower(), fe.stderr
    assert _clean_rejection(fe.returncode, fe.stderr) and (
        "[E2101]" in fe.stderr or "[E2102]" in fe.stderr), fe.stderr


# --- conditions: `is` binds tighter than `and` -------------------------------

_IS_AND_kernel = ("place Entry {{\n"
           "  fun probe(y: Number, n: Number): Number {{\n"
           "    be r := 0\n"
           "    when {cond} {{ r = 1 }}\n"
           "    return r\n  }}\n"
           "  fun main(): Number {{ return probe(5, 3) * 10 + probe(5, 7) }}\n}}\n")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="in a condition `a and x is p` groups as `a and (x is p)`")
def test_is_binds_tighter_than_and_on_the_right(tmp_path):
    rc, out = _build_kernel(tmp_path, _IS_AND_kernel.format(cond="y > 0 and n is 7"))
    _verdict(rc == 0, f"`y > 0 and n is 7` was not read as `y > 0 and (n is 7)`:\n{out[-300:]}")
    assert _run(tmp_path / "out")[0] == 1


def test_is_binds_tighter_than_and_on_the_left(tmp_path):
    rc, out = _build_kernel(tmp_path, _IS_AND_kernel.format(cond="n is 7 and y > 0"))
    assert rc == 0, out
    assert _run(tmp_path / "out")[0] == 1


# --- boolean and proposition ---------------------------------------------------

# A proposition leaves the classifier only as a decision with three arms:
# unknown is not absent, and nothing sends it to false.

@pytest.mark.parametrize("value, arm", [("present", 1), ("absent", 2), ("unknown", 3)])
def test_unknown_does_not_become_false(tmp_path, value, arm):
    entry = ("place Entry {}\nfun main(): Number {\n"
             f"  be p := {value}\n"
             "  return match decide(p) { Present => 1, Absent => 2, Unknown => 3 }\n}\n")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert rc == 0, out
    assert _run(tmp_path / "out")[0] == arm, f"decide({value}) took another arm"


def test_a_decision_is_left_only_by_answering_unknown(tmp_path):
    entry = ("place Entry {}\nfun main(): Number {\n  be p := unknown\n"
             "  return match decide(p) { Present => 1, Absent => 2 }\n}\n")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out) and "Unknown" in out, out


@pytest.mark.parametrize("form", ["to_bool(p)", "to_bool_dec(decide(p))", "p"])
def test_there_is_no_arrow_from_proposition_to_boolean(tmp_path, form):
    entry = ("place Entry {}\nfun main(): Number {\n  be p := unknown\n"
             f"  return if {form} then 1 else 2\n}}\n")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out), out


def test_a_boolean_flows_into_a_proposition(tmp_path):
    """Boolean <: proposition: a comparison returned where a proposition is
    expected is accepted, whichever way the proposition type is written."""
    entry = ("place Entry {}\nfun f(x: Number): proposition { return x > 0 }\n"
             "fun main(): Number { return match decide(f(1)) { Present => 42, Absent => 0, Unknown => 1 } }\n")
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert rc == 0, out
    assert _run(tmp_path / "out")[0] == 42


def test_a_proposition_is_not_a_boolean(tmp_path):
    entry = ("place Entry {\n"
             "  fun f(b: Boolean): Number { return if b then 1 else 2 }\n"
             "  fun g(p: proposition): Number { return f(p) }\n"
             "  fun main(): Number { return g(unknown) }\n}\n")
    rc, out = _build_kernel(tmp_path, entry)
    _verdict(_clean_rejection(rc, out),
             f"the checker accepted a proposition as a boolean (rc={rc}, "
             f"refused downstream: {'stage0.topos.mlir' in out})")


# --- cubical composition -------------------------------------------------------

_SUSP_kernel = ("place Entry {{\n"
         "fun main(): Number {{\n"
         "  be n := hit(north)\n"
         "  be m := hit(merid, 0)\n"
         "{body}"
         "  return match e {{ north => 5, south => 7, merid(a) => plam i => 9 }}\n"
         "}}\n}}\n")


def _ends_at_kernel(tmp_path, body, expected, what):
    rc, out = _build_kernel(tmp_path, _SUSP_kernel.format(body=body))
    if rc != 0:
        _verdict("Fatal error: exception" not in out, f"{what}: the compiler crashed:\n{out[-300:]}")
        raise AssertionError(out)
    got, _ = _run(tmp_path / "out")
    _verdict(got == expected, f"{what}: computed {got}, expected {expected}")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a composition on an active face is the side at its far end: here merid(0) at I1, the south pole")
def test_a_composition_on_an_active_face_is_the_side_at_its_end(tmp_path):
    body = ("  be p := plam i => hcomp Suspension [ i = I0 => plam j => m @ j ] n\n"
            "  be e := p @ I0\n")
    _ends_at_kernel(tmp_path, body, 7, "hcomp at i = I0")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a meridian is a path from the north pole to the south pole: merid(0) at I1 is south")
def test_a_meridian_ends_at_the_south_pole(tmp_path):
    _ends_at_kernel(tmp_path, "  be e := m @ I1\n", 7, "merid(0) @ I1")


# --- type erasure respects local binders ---------------------------------------

_SHADOW_kernel = ("place Entry {{\n"
           "  fun pick({tparams}x: Number): Number {{ return x }}\n"
           "  fun g(pick: Number -> Number): Number {{ return pick(5) }}\n"
           "  fun inc(a: Number): Number {{ return a + 1 }}\n"
           "  fun main(): Number {{ return g(inc) }}\n}}\n")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a parameter named like a top-level function with a type parameter is that parameter, and its call keeps all arguments")
def test_a_parameter_shadows_a_generic_function_of_the_same_name(tmp_path):
    rc, out = _build_kernel(tmp_path, _SHADOW_kernel.format(tparams="T: Type_0, "))
    assert rc == 0, out
    got, _ = _run(tmp_path / "out")
    _verdict(got == 6, f"g(inc) computed {got}, expected inc(5) = 6")


def test_a_parameter_shadows_a_plain_function_of_the_same_name(tmp_path):
    rc, out = _build_kernel(tmp_path, _SHADOW_kernel.format(tparams=""))
    assert rc == 0, out
    assert _run(tmp_path / "out")[0] == 6


# --- inference -----------------------------------------------------------------

@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="an unannotated return is inferred, so a section used as a number is refused by the checker")
def test_an_inferred_section_is_not_a_number(tmp_path):
    entry = ("place Box { v Number }\n"
             "place Entry {\n"
             "  fun mk() { return .-> Box { v 1 } }\n"
             "  fun main(): Number { be n := mk() + 1  return n }\n}\n")
    rc, out = _build_kernel(tmp_path, entry, _BOX_kernel)
    _verdict(_clean_rejection(rc, out),
             f"the checker accepted a section plus a number (rc={rc}, "
             f"refused downstream: {'stage0.topos.mlir' in out})")


# === the frontend passes: liveness, drop, homes, formatter, naturality ---

EMIT_frontend = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"
EVAL_frontend = ROOT / "frontend" / "_build" / "default" / "eval_runner.exe"
FMT_frontend = ROOT / "frontend" / "_build" / "default" / "yonfmt.exe"

# A world with one Space D that owns a place DP and a producer d_op.
_D_WORLD_frontend = '\n[world.W]\nobjects = ["X"]\nspaces = ["D"]\n'
_D_FILES_frontend = {
    "D/Topos.yon": "topos T where { }\n",
    "D/DP.yon": "place DP { n Number }\n"
                "  fun d_op(x: Number): Number { return x + 1 }\n",
}


def _d_project_frontend(tmp, entry):
    return _project(tmp, entry, extra=_D_WORLD_frontend, files=_D_FILES_frontend)


def _drop_refused_frontend(tmp, entry):
    """Compile [entry] in the Space-D world; True iff the drop is refused (E3001/E3002)."""
    rc, out = _compile(_d_project_frontend(tmp, entry), tmp / "out")
    return rc != 0 and ("E3001" in out or "E3002" in out), rc, out


# --- drop / reclaim: a Space is never released while a later step still reaches it ---

def test_drop_before_a_direct_call_into_the_space_is_refused(tmp_path):
    entry = ("import svc::d_op from D\nplace Entry { }\n"
             "fun b(k: Number): Number { return d_op(k) }\n"
             "fun main(): Number {\n  drop D\n  return b(3)\n}\n")
    refused, rc, out = _drop_refused_frontend(tmp_path, entry)
    assert refused, out


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a function reaches a Space through mutual recursion whatever the names of the functions in the cycle")
def test_drop_before_a_mutually_recursive_call_into_the_space_is_refused(tmp_path):
    entry = ("import svc::d_op from D\nplace Entry { }\n"
             "fun a(k: Number): Number {\n  when k > 0 { return b(k - 1) }\n  return d_op(k)\n}\n"
             "fun b(k: Number): Number { return a(k) }\n"
             "fun main(): Number {\n  drop D\n  return b(3)\n}\n")
    refused, rc, out = _drop_refused_frontend(tmp_path, entry)
    _verdict(refused, f"drop D accepted before b(3), which reaches D through a: rc={rc}")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="calling a closure that calls into a Space is a use of that Space")
def test_drop_before_calling_a_closure_into_the_space_is_refused(tmp_path):
    entry = ("import svc::d_op from D\nplace Entry { }\n"
             "fun main(): Number {\n  be g := fun(y: Number) => d_op(y)\n"
             "  drop D\n  return g(5)\n}\n")
    refused, rc, out = _drop_refused_frontend(tmp_path, entry)
    _verdict(refused, f"drop D accepted before g(5), whose body calls d_op in D: rc={rc}")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a call to a function homed in a place reaches every Space that function reaches")
def test_drop_before_a_homed_call_into_the_space_is_refused(tmp_path):
    entry = ("import svc::d_op from D\n"
             "place Repo {\n  fun load(k: Number): Number { return d_op(k) }\n}\n"
             "place Entry { }\n"
             "fun main(): Number {\n  drop D\n  return Repo.load(3)\n}\n")
    refused, rc, out = _drop_refused_frontend(tmp_path, entry)
    _verdict(refused, f"drop D accepted before Repo.load(3), which calls d_op in D: rc={rc}")


def test_drop_before_reading_a_handle_into_the_space_is_refused(tmp_path):
    entry = ("place Entry { }\nfun main(): Number {\n  be p := .-> DP { n 7 }\n"
             "  drop D\n  return p.n\n}\n")
    refused, rc, out = _drop_refused_frontend(tmp_path, entry)
    assert refused, out


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a drop inside a callee is refused when the caller still reads the Space afterwards")
def test_drop_in_a_callee_while_the_caller_still_reads_the_space_is_refused(tmp_path):
    entry = ("place Entry { }\n"
             "fun cleanup(): Number {\n  drop D\n  return 0\n}\n"
             "fun main(): Number {\n  be p := .-> DP { n 7 }\n"
             "  be z := cleanup()\n  return p.n\n}\n")
    refused, rc, out = _drop_refused_frontend(tmp_path, entry)
    _verdict(refused, f"drop D inside cleanup() accepted, main reads p.n afterwards: rc={rc}")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a place-typed parameter is a handle into its Space, so dropping that Space before reading it is refused")
def test_drop_before_reading_a_place_parameter_is_refused(tmp_path):
    entry = ("place Entry { }\n"
             "fun peek(a: DP): Number {\n  drop D\n  return a.n\n}\n"
             "fun main(): Number {\n  be p := .-> DP { n 7 }\n  return peek(p)\n}\n")
    refused, rc, out = _drop_refused_frontend(tmp_path, entry)
    _verdict(refused, f"drop D accepted before a.n with a: DP: rc={rc}")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a drop inside a spawn block obeys the same reachability check as any other drop")
def test_drop_inside_a_spawn_block_is_checked(tmp_path):
    entry = ("import svc::d_op from D\nplace Entry { }\n"
             "fun main(): Number {\n  be results := spawn in 1 parallel {\n"
             "    drop D\n    promote d_op(1)\n  }\n"
             "  return results.fold(0, fun(a: Number, v: Number) => a + v)\n}\n")
    refused, rc, out = _drop_refused_frontend(tmp_path, entry)
    _verdict(refused, f"drop D inside spawn accepted before d_op(1): rc={rc}")


# --- world boundary: a wire may not cross worlds ---

def _boundary_project_frontend(tmp, a_body):
    toml = ('[package]\nname="p"\n[runtime]\nbackend="separate"\n'
            '[world.W1]\nobjects=["X"]\nspaces=["A"]\n'
            '[world.W2]\nobjects=["Y"]\nspaces=["Bx","C"]\n')
    root = tmp / "proj"
    for d in ("A", "Bx", "C"):
        (root / d).mkdir(parents=True)
    (root / "yon.toml").write_text(toml)
    (root / "A" / "Topos.yon").write_text("topos TA where { }\n")
    (root / "Bx" / "Topos.yon").write_text("topos TB where { }\n")
    (root / "C" / "Topos.yon").write_text("topos TC where { }\n")
    (root / "A" / "AP.yon").write_text(a_body)
    (root / "Bx" / "BxP.yon").write_text(
        "fun b_op(x: Number): Number { return x + 1 }\nplace BxP { }\n")
    (root / "C" / "CP.yon").write_text(
        "import svc::b_op from Bx\nplace CP { }\n"
        "fun c_op(x: Number): Number { be r := b_op(x)  return r }\n")
    (root / "Entry.yon").write_text("place Entry { }\nfun main(): Number { return 0 }\n")
    return root


def test_an_import_across_worlds_is_refused(tmp_path):
    root = _boundary_project_frontend(tmp_path,
        "import svc::b_op from Bx\nplace AP { }\n"
        "fun a_op(x: Number): Number { be r := b_op(x)  return r }\n")
    rc, out = _compile(root, tmp_path / "out")
    assert rc != 0 and "E3010" in out, out


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a wire to a Space of another world is refused, like an import from it")
def test_a_wire_across_worlds_is_refused(tmp_path):
    root = _boundary_project_frontend(tmp_path,
        "place AP { }\nfun a_op(x: Number): Number {\n"
        "  be w := wire to space Bx\n  return x\n}\n")
    rc, out = _compile(root, tmp_path / "out")
    _verdict(rc != 0 and "E3010" in out,
             f"wire from world W1 to Space Bx of world W2 accepted: rc={rc}")


# --- subscriptions: each awaits subscribes to its own wire's Space ---

_AW_TOML_frontend = ('[package]\nname = "aw"\n\n[runtime]\nbackend = "shm"\n\n'
            '[world.W]\nobjects = ["X"]\nspaces  = ["w", "Alpha", "Beta"]\n')
_AW_ENTRY_frontend = """import pa::pa from Alpha
import pb::pb from Beta
place Entry {
fun main(): Number {
  return fa() + Other.fb()
}
fun fa(): Number {
  be w := wire to space Alpha
  be sub := w.awaits(pa)
  be s := sub.stream
  return s.fold(0, fun(a: Number, r: Number) => a + r)
}
}
"""
_AW_OTHER_frontend = """import pb::pb from Beta
place Other {
fun d1(): Number { return 0 }
fun d2(): Number { return 0 }
fun d3(): Number { return 0 }
fun d4(): Number { return 0 }
fun fb(): Number {
  be w := wire to space Beta
  be sub := w.awaits(pb)
  be s := sub.stream
  return s.fold(0, fun(a: Number, r: Number) => a + r)
}
}
"""


@pytest.mark.skipif(not EMIT_frontend.exists(), reason="the emitter is not built")
@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a subscription opened in one file goes to the Space of its own wire, whatever another file has at the same line and column")
def test_two_subscriptions_at_the_same_position_in_two_files_keep_their_spaces(tmp_path):
    root = tmp_path / "proj"
    (root / "w").mkdir(parents=True)
    (root / "yon_modules" / "pa").mkdir(parents=True)
    (root / "yon_modules" / "pb").mkdir(parents=True)
    (root / "yon.toml").write_text(_AW_TOML_frontend)
    (root / "w" / "Topos.yon").write_text("topos WTopos where {\n}\n")
    (root / "w" / "R.yon").write_text("place R { v Number }\n")
    (root / "yon_modules" / "pa" / "pa.yon").write_text(
        "fun pa(): Wire<Number> {\n  be s := produce { emit 1 }\n  return s\n}\n")
    (root / "yon_modules" / "pb" / "pb.yon").write_text(
        "fun pb(): Wire<Number> {\n  be s := produce { emit 2 }\n  return s\n}\n")
    (root / "Entry.yon").write_text(_AW_ENTRY_frontend)
    (root / "Other.yon").write_text(_AW_OTHER_frontend)
    r = subprocess.run([str(EMIT_frontend), str(root)], capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stderr[-800:]
    m = re.search(r"func\.func @fa\(\).*?\n  }\n", r.stdout, re.S)
    assert m, "no @fa in the emitted module"
    targets = re.findall(r"@yon_space_name_(\w+)", m.group(0))
    assert targets, "no subscription request in @fa"
    _verdict(targets == ["Alpha"],
             f"fa wires to Alpha but its subscription request goes to {targets}")


# --- authority: a cross-Space call exists only through an import ---

@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="user source cannot reach a Space by spelling the runtime's internal call name")
def test_a_runtime_rpc_name_in_user_source_is_refused(tmp_path):
    entry = ("import svc::d_op from D\nplace Entry { }\n"
             "fun main(): Number {\n  return __yon_rpc2_invoke1__D(7, 3)\n}\n")
    rc, out = _compile(_d_project_frontend(tmp_path, entry), tmp_path / "out")
    _verdict(_clean_rejection(rc, out),
             f"forged call to Space D with selector 7 compiled: rc={rc}")


# --- modules: a dependency's parameters are not its functions ---

def _geo_project_frontend(tmp, geo_src):
    return _project(tmp,
        'import "x/geo"\nplace Entry { }\n'
        "fun main(): Number {\n  return geo::apply(fun(y: Number) => y + 1, 1)\n}\n",
        files={"yon_modules/geo/geo.yon": geo_src})


def test_a_dependency_applies_its_function_parameter(tmp_path):
    proj = _geo_project_frontend(tmp_path,
        "fun scale(x: Number): Number { return x * 100 }\n"
        "fun apply(h: Number -> Number, x: Number): Number { return h(x) }\n")
    rc, out = _compile(proj, tmp_path / "out")
    assert rc == 0, out
    code, _ = _run(tmp_path / "out")
    assert code == 2


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a parameter of a dependency's function shadows the dependency's homonymous function")
def test_a_dependency_parameter_shadows_a_module_function(tmp_path):
    proj = _geo_project_frontend(tmp_path,
        "fun scale(x: Number): Number { return x * 100 }\n"
        "fun apply(scale: Number -> Number, x: Number): Number { return scale(x) }\n")
    rc, out = _compile(proj, tmp_path / "out")
    assert rc == 0, out
    code, _ = _run(tmp_path / "out")
    _verdict(code == 2, f"apply(y => y + 1, 1) gave {code}, expected 2")


# --- homes: inside a place, a sibling wins over a global homonym in every block ---

def _homes_project_frontend(tmp, f_body):
    return _project(tmp,
        "internal fun helper(): Number { return 1 }\nplace Entry { }\n"
        "fun main(): Number { return P.f() }\n",
        extra='\n[world.W]\nobjects = ["X"]\nspaces = ["w"]\n',
        files={"w/Topos.yon": "topos WTopos where {\n}\n",
               "P.yon": "place P {\n  internal fun helper(): Number { return 2 }\n"
                        "  fun f(): Number {\n" + f_body + "  }\n}\n"})


def test_a_sibling_call_resolves_to_the_sibling(tmp_path):
    rc, out = _compile(_homes_project_frontend(tmp_path, "    return helper()\n"), tmp_path / "out")
    assert rc == 0, out
    code, _ = _run(tmp_path / "out")
    assert code == 2


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a sibling call inside a when block resolves to the sibling, not to a global homonym")
def test_a_sibling_call_inside_when_resolves_to_the_sibling(tmp_path):
    body = "    be r := 0\n    when 1 == 1 { r = helper() }\n    return r\n"
    rc, out = _compile(_homes_project_frontend(tmp_path, body), tmp_path / "out")
    assert rc == 0, out
    code, _ = _run(tmp_path / "out")
    _verdict(code == 2, f"P.f() gave {code}, expected 2 from P.helper")


# --- naturality: a certificate only for a law that holds; a refuted law is refused ---

_NAT_PROJ_frontend = """place Entry {
  fun fa(b: Number): Number { return %s }
  fun ga(b: Number): Number { return %s }
  fun idf(b: Number): Number { return b }
  morph F from Account to AccountEU {
    on morphism deposit via fa
  }
  morph G from Account to AccountEU {
    on morphism deposit via ga
  }
  nat transform Eta from F to G {
    for each deposit by idf
  }
  fun main(): Number { return 0 }
}
"""


def _nat_project_frontend(tmp, fa, ga):
    return _project(tmp, _NAT_PROJ_frontend % (fa, ga),
        extra='\n[world.Shop]\nobjects = ["X"]\nspaces = ["shop"]\n',
        files={"shop/Topos.yon": "topos ShopTopos where {\n}\n",
               "shop/Account.yon": "place Account { balance Number }\n",
               "shop/AccountEU.yon": "place AccountEU { balance Number }\n"})


def _nat_stderr_frontend(proj):
    r = subprocess.run([str(EMIT_frontend), str(proj)], capture_output=True, text=True,
                       timeout=120)
    return r.stderr


@pytest.mark.skipif(shutil.which("z3") is None or not EMIT_frontend.exists(), reason="z3 is not installed")
def test_smt_does_not_prove_two_different_constants_equal(tmp_path):
    """The constants reach the solver by their exact bits: b * 3.14159265 and
    b * 3.1415926 are refuted, with a counterexample."""
    err = _nat_stderr_frontend(_nat_project_frontend(tmp_path, "b * 3.14159265", "b * 3.1415926"))
    assert "naturality of Eta" in err and "[E2101]" in err, err
    assert "proven" not in err.lower(), err


@pytest.mark.skipif(shutil.which("z3") is None, reason="z3 is not installed")
def test_a_refuted_naturality_law_is_refused(tmp_path):
    proj = _nat_project_frontend(tmp_path, "b + 1", "b + 2")
    r = subprocess.run([str(ROOT / "toolchain" / "yonc"), str(proj), "-o", str(tmp_path / "out")],
                       capture_output=True, text=True, timeout=120)
    out = r.stdout + r.stderr
    assert _clean_rejection(r.returncode, out) and "[E2101]" in out, out


# A square is decided on the values the program computes with: Number is an
# IEEE double, Int64 a 64-bit integer, and two values are the same iff they
# have the same bits. Proven is certified, refuted is refused with its
# counterexample, anything else is refused unless declared `is given`.
_SQUARES = {
    # same bits for every double, though not the same term
    "doubling_is_adding_to_itself": ("Number", "b + b", "2 * b", "proven"),
    # -0 + 0 is +0, which is not -0
    "adding_zero_is_not_the_identity_on_doubles": ("Number", "b + 0", "b", "refuted"),
    # on Int64, Z/2^64
    "adding_then_subtracting_one_on_int64": ("Int64", "(b + 1) - 1", "b", "proven"),
}


def _square_project(tmp, ty, fa, ga, given=False):
    src = (_NAT_PROJ_frontend.replace("Number", ty).replace("fun main(): " + ty, "fun main(): Number")
           % (fa, ga))
    if given:
        src = src.replace("nat transform Eta from F to G {", "nat transform Eta from F to G is given {")
    return _project(tmp, src,
        extra='\n[world.Shop]\nobjects = ["X"]\nspaces = ["shop"]\n',
        files={"shop/Topos.yon": "topos ShopTopos where {\n}\n",
               "shop/Account.yon": "place Account { balance Number }\n",
               "shop/AccountEU.yon": "place AccountEU { balance Number }\n"})


@pytest.mark.skipif(shutil.which("z3") is None, reason="z3 is not installed")
@pytest.mark.parametrize("square", sorted(_SQUARES))
def test_a_square_is_decided_on_the_values_of_its_carrier(tmp_path, square):
    ty, fa, ga, verdict = _SQUARES[square]
    proj = _square_project(tmp_path, ty, fa, ga)
    r = subprocess.run([str(ROOT / "toolchain" / "yonc"), str(proj), "-o", str(tmp_path / "out")],
                       capture_output=True, text=True, timeout=120)
    out = r.stdout + r.stderr
    if verdict == "proven":
        assert r.returncode == 0 and "proven" in out, out
    else:
        assert _clean_rejection(r.returncode, out) and "[E2101]" in out, out


def test_an_uncertified_square_is_refused_unless_given(tmp_path):
    """A square outside the modelled fragment is not certified: refused, and
    accepted when the transformation is declared an axiom."""
    fa, ga = "clear b @ I0", "b"
    d1, d2 = tmp_path / "plain", tmp_path / "given"
    d1.mkdir(); d2.mkdir()
    r1 = subprocess.run([str(ROOT / "toolchain" / "yonc"), str(_square_project(d1, "Number", fa, ga)),
                         "-o", str(d1 / "out")], capture_output=True, text=True, timeout=120)
    assert _clean_rejection(r1.returncode, r1.stdout + r1.stderr) and "[E2102]" in r1.stderr, r1.stderr
    r2 = subprocess.run([str(ROOT / "toolchain" / "yonc"),
                         str(_square_project(d2, "Number", fa, ga, given=True)),
                         "-o", str(d2 / "out")], capture_output=True, text=True, timeout=120)
    assert r2.returncode == 0, r2.stderr


def test_a_naturality_verdict_reaches_whoever_compiles(tmp_path):
    """What the checker concludes about a law is part of the compilation's
    answer: it reaches the user of yonc also when the program is accepted."""
    proj = _nat_project_frontend(tmp_path, "b + 1", "b + 1")
    r = subprocess.run([str(ROOT / "toolchain" / "yonc"), str(proj), "-o", str(tmp_path / "out")],
                       capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stderr
    assert "naturality of Eta" in r.stderr, r.stderr


# --- HITs: each built-in type's own constructors are reachable ---

def test_the_circle_base_point_eliminates(tmp_path):
    proj = _project(tmp_path,
        "place Entry {\nfun motive(x: S1): Number { return 0 }\n"
        "fun main(): Number {\n"
        "  return hit_elim(motive, [base => 42, loop => plam i => 42], hit(base))\n}\n}\n")
    rc, out = _compile(proj, tmp_path / "out")
    assert rc == 0, out
    assert _run(tmp_path / "out")[0] == 42


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="the sphere's base point has type S2 and eliminates over S2")
def test_the_sphere_base_point_eliminates(tmp_path):
    proj = _project(tmp_path,
        "place Entry {\nfun motive(x: S2): Number { return 0 }\n"
        "fun main(): Number {\n"
        "  return hit_elim(motive, [base => 42, surf => plam i => 42], hit(base))\n}\n}\n")
    rc, out = _compile(proj, tmp_path / "out")
    _verdict(rc == 0, f"S2 elimination refused: {out.strip()[-160:]}")
    assert _run(tmp_path / "out")[0] == 42


# --- transport: along a path that is not refl, transport is not the identity ---

_TRANSPORT_PARAM_frontend = """place Entry {
fun succ(n: Int64): Int64 { return n + 1 }
fun pred(n: Int64): Int64 { return n - 1 }
fun go(p: Id(Type, Int64, Int64), v: Int64): Int64 { return transport(p, v) }
fun main(): Number {
  be y := go(ua(equiv(succ, pred, fun(a) => clear a, fun(b) => clear b)), 10)
  return if y == 11 then 11 else 0
}
}
"""


def test_transport_along_an_inline_univalence_path_applies_the_equivalence(tmp_path):
    proj = _project(tmp_path,
        "place Entry {\nfun succ(n: Int64): Int64 { return n + 1 }\n"
        "fun pred(n: Int64): Int64 { return n - 1 }\n"
        "fun main(): Number {\n"
        "  be y := transport(ua(equiv(succ, pred, fun(a) => clear a, fun(b) => clear b)), 10)\n"
        "  return if y == 11 then 11 else 0\n}\n}\n")
    rc, out = _compile(proj, tmp_path / "out")
    assert rc == 0, out
    assert _run(tmp_path / "out")[0] == 11


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="transport along a univalence path passed as an argument applies the equivalence")
def test_transport_along_a_path_argument_applies_the_equivalence(tmp_path):
    proj = _project(tmp_path, _TRANSPORT_PARAM_frontend)
    rc, out = _compile(proj, tmp_path / "out")
    _verdict("Fatal error: exception" not in out,
             f"the compiler crashed: {out.strip()[-160:]}")
    _verdict(rc == 0, f"the program is refused: {out.strip()[-200:]}")
    _verdict(_run(tmp_path / "out")[0] == 11, "transport(ua(succ), 10) is not 11")


@pytest.mark.skipif(not EVAL_frontend.exists(), reason="the interpreter is not built")
def test_the_interpreter_does_not_transport_by_identity(tmp_path):
    """Along a path that is not refl the interpreter either computes the
    equivalence's action or declares the evaluation incomplete; it never hands
    back the input as if the path were refl."""
    proj = _project(tmp_path, _TRANSPORT_PARAM_frontend)
    r = subprocess.run([str(EVAL_frontend), str(proj)], capture_output=True, text=True, timeout=60)
    m = re.search(r"EXIT (-?\d+)", r.stdout + r.stderr)
    if m is None:
        # a declared refusal: it hands back no value at all
        assert ("EVAL INCOMPLETE" in r.stdout + r.stderr
                or "TYPE ERROR" in r.stdout + r.stderr), (r.stdout + r.stderr)[-400:]
    else:
        assert int(m.group(1)) == 11, "transport(ua(succ), 10) evaluated to a value other than 11"


# --- formatter: formatting never changes what the text says ---

def _fmt_frontend(tmp, src):
    f = tmp / "f.yon"
    f.write_text(src)
    r = subprocess.run([str(FMT_frontend), str(f)], capture_output=True, text=True, timeout=60)
    return r.returncode, r.stdout


def _fmt_keeps_frontend(tmp, src, needle):
    rc, out = _fmt_frontend(tmp, src)
    # refusing to format is acceptable; changing the text is not
    return rc != 0 or needle in out, out


@pytest.mark.skipif(not FMT_frontend.exists(), reason="yonfmt is not built")
def test_formatting_keeps_an_integer_literal(tmp_path):
    ok, out = _fmt_keeps_frontend(tmp_path, "place Entry {\n  fun main(): Number { return 42 }\n}\n", "42")
    assert ok, out


@pytest.mark.skipif(not FMT_frontend.exists(), reason="yonfmt is not built")
@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="formatting keeps every digit of a numeric literal")
def test_formatting_keeps_every_digit_of_a_literal(tmp_path):
    ok, out = _fmt_keeps_frontend(tmp_path,
        "place Entry {\n  fun main(): Number { return 3.14159265 }\n}\n", "3.14159265")
    _verdict(ok, f"formatted text: {out!r}")


@pytest.mark.skipif(not FMT_frontend.exists(), reason="yonfmt is not built")
@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="formatting keeps a function's on error clause")
def test_formatting_keeps_a_function_error_clause(tmp_path):
    ok, out = _fmt_keeps_frontend(tmp_path,
        "place Entry {\n  fun half(n: Number) on error DomainError: Number { return n / 2 }\n"
        "  fun main(): Number { return half(84) }\n}\n", "on error DomainError")
    _verdict(ok, f"formatted text: {out!r}")


@pytest.mark.skipif(not FMT_frontend.exists(), reason="yonfmt is not built")
@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="formatting keeps the when here filter of a stream loop")
def test_formatting_keeps_a_when_here_filter(tmp_path):
    ok, out = _fmt_keeps_frontend(tmp_path,
        "place Entry {\n  fun main(): Number {\n    be s := produce { emit 1 }\n"
        "    be t := 0\n    for every x in s when here { t = t + x }\n    return t\n  }\n}\n",
        "when here")
    _verdict(ok, f"formatted text: {out!r}")


@pytest.mark.skipif(not FMT_frontend.exists(), reason="yonfmt is not built")
@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="formatting keeps comments")
def test_formatting_keeps_comments(tmp_path):
    ok, out = _fmt_keeps_frontend(tmp_path,
        "place Entry {\n  // the answer\n  fun main(): Number { return 42 }\n}\n", "// the answer")
    _verdict(ok, f"formatted text: {out!r}")


# === the MLIR dialect and its passes ----------------------------------

WORLD_dialect = '[world.W]\nobjects = ["X"]\nspaces  = ["w"]\n'
TOPOS_dialect = "topos WTopos where {\n}\n"


def _build_run_dialect(proj, tmp):
    rc, out = _compile(proj, tmp / "a.out")
    assert rc == 0, out
    return _run(tmp / "a.out")


# ---------------------------------------------------------------------------
# Nested place fields: the read uses the same layout as the construction.

def _nested_dialect(tmp, node_src, literal):
    return _project(tmp, (
        "place Entry {\n"
        "  fun main(): Number {\n"
        f"    be n := .-> Node {{ {literal} }}\n"
        "    return n.child.v\n"
        "  }\n"
        "}\n"), extra=WORLD_dialect, files={
            "w/Topos.yon": TOPOS_dialect,
            "w/Leaf.yon": "place Leaf { v Number }\n",
            "w/Node.yon": node_src})


def test_nested_field_after_a_boolean_reads_its_value(tmp_path):
    proj = _nested_dialect(tmp_path, "place Node { flag Boolean\n  child Leaf }\n",
                   "flag true child .-> Leaf { v 7 }")
    rc, _ = _build_run_dialect(proj, tmp_path)
    _verdict(rc == 7, f"n.child.v after a Boolean field gave {rc}, expected 7")


def test_nested_field_after_fields_of_every_width_reads_its_value(tmp_path):
    proj = _nested_dialect(tmp_path, "place Node { flag Boolean\n  k Number\n  child Leaf }\n",
                   "flag true k 3 child .-> Leaf { v 7 }")
    rc, _ = _build_run_dialect(proj, tmp_path)
    assert rc == 7, f"n.child.v after a Boolean and a Number gave {rc}, expected 7"


def test_nested_field_before_a_boolean_reads_its_value(tmp_path):
    proj = _nested_dialect(tmp_path, "place Node { child Leaf\n  flag Boolean }\n",
                   "child .-> Leaf { v 7 } flag true")
    rc, _ = _build_run_dialect(proj, tmp_path)
    assert rc == 7


def test_nested_field_getter_buffer_holds_the_loaded_bytes(tmp_path):
    proj = _nested_dialect(tmp_path, "place Node { child Leaf\n  flag Boolean }\n",
                   "child .-> Leaf { v 7 } flag true")
    ll = tmp_path / "p.ll"
    r = subprocess.run([str(YONC), "--emit=ll", str(proj), "-o", str(ll)],
                       capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stdout + r.stderr
    text = ll.read_text()
    getters = re.findall(r"define [^@]*@(\w+__get_\w+)\([^)]*\) \{(.*?)\n\}", text, re.S)
    assert getters, "no nested field getter emitted"
    elem_size = {"i8": 1, "i32": 4, "i64": 8, "double": 8}
    for name, body in getters:
        a = re.search(r"alloca (\w+), i64 (\d+)", body)
        c = re.search(r"@yon_rt_field_load(?:_or_stop)?\([^,]+, i32 \d+, i32 (\d+),", body)
        assert a and c, f"unexpected getter shape in {name}"
        have = elem_size[a.group(1)] * int(a.group(2))
        need = int(c.group(1))
        _verdict(have >= need, f"{name}: buffer of {have} byte(s), runtime copies {need}")


def test_section_literal_binds_fields_by_name(tmp_path):
    proj = _project(tmp_path, (
        "place Entry {\n"
        "  fun main(): Number {\n"
        "    be p := .-> P { b 1 a 2 }\n"
        "    return p.a * 10 + p.b\n"
        "  }\n"
        "}\n"), extra=WORLD_dialect, files={
            "w/Topos.yon": TOPOS_dialect,
            "w/P.yon": "place P { a Number\n  b Number }\n"})
    rc, _ = _build_run_dialect(proj, tmp_path)
    _verdict(rc == 21, f"p.a, p.b gave {rc // 10},{rc % 10}; expected 2,1")


def test_section_literal_binds_fields_of_different_types_by_name(tmp_path):
    proj = _project(tmp_path, (
        "place Entry {\n"
        "  fun main(): Number {\n"
        "    be q := .-> Q { n 3 name \"ab\" }\n"
        "    return String.length(q.name) * 10 + q.n\n"
        "  }\n"
        "}\n"), extra=WORLD_dialect, files={
            "w/Topos.yon": TOPOS_dialect,
            "w/Q.yon": "place Q { name Text\n  n Number }\n"})
    rc, _ = _build_run_dialect(proj, tmp_path)
    assert rc == 23, f"len(q.name), q.n gave {rc // 10},{rc % 10}; expected 2,3"


# ---------------------------------------------------------------------------
# A HashSet / HashMap is a value: adding to a set or a map does not change the
# one you added to, so two reads of it agree however they are written.

def test_adding_to_a_set_leaves_the_original_unchanged(tmp_path):
    proj = _project(tmp_path, (
        "place Entry {}\n"
        "fun sz(s: HashSet<Number>): Number { return HashSet.size(s) }\n"
        "fun main(): Number {\n"
        "  be s := HashSet.add(HashSet.empty(), 1)\n"
        "  be t := HashSet.add(s, 2)\n"
        "  be b := HashSet.size(s)\n"
        "  be c := sz(s)\n"
        "  return b * 10 + c\n"
        "}\n"))
    rc, _ = _build_run_dialect(proj, tmp_path)
    _verdict(rc == 11, f"size(s) inline and through a function gave {rc // 10},{rc % 10}; expected 1,1")


def test_setting_a_map_key_leaves_the_original_unchanged(tmp_path):
    proj = _project(tmp_path, (
        "place Entry {}\n"
        "fun at1(m: HashMap<Number, Number>): Number {\n"
        "  return match HashMap.get(m, 1) { Found(v) => v, Absent => 0 }\n}\n"
        "fun look(m: HashMap<Number, Number>): Number { return at1(m) }\n"
        "fun main(): Number {\n"
        "  be m := HashMap.set(HashMap.empty(), 1, 5)\n"
        "  be t := HashMap.set(m, 1, 9)\n"
        "  be b := at1(m)\n"
        "  be c := look(m)\n"
        "  return b * 10 + c\n"
        "}\n"))
    rc, _ = _build_run_dialect(proj, tmp_path)
    _verdict(rc == 55, f"get(m,1) inline and through a function gave {rc // 10},{rc % 10}; expected 5,5")


# ---------------------------------------------------------------------------
# Heyting integers negate like the Heyting scalars (Goedel G3: not U = F).

def test_scalar_negation_of_unknown_is_false(tmp_path):
    """G3: not unknown is absent, and not not unknown is present."""
    proj = _project(tmp_path, (
        "place Entry {}\n"
        "fun main(): Number {\n"
        "  be s := match decide(!? unknown) { Present => 10, Absent => 0, Unknown => 20 }\n"
        "  be t := match decide(!? (!? unknown)) { Present => 1, Absent => 0, Unknown => 2 }\n"
        "  return s + t\n"
        "}\n"))
    rc, _ = _build_run_dialect(proj, tmp_path)
    assert rc == 1


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="the negation of an unknown trit of a Heyting integer is a decided trit, as for the scalar")
def test_heyting_integer_negation_of_unknown_is_decided(tmp_path):
    proj = _project(tmp_path, (
        "place Entry {}\n"
        "fun main(): Number {\n"
        "  be n := ~? heyting(0, 1)\n"
        "  return __heyt_int_mask(n)\n"
        "}\n"))
    rc, _ = _build_run_dialect(proj, tmp_path)
    _verdict(rc == 0, f"mask of ~?(unknown trit) is {rc}, expected 0 (decided)")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a Heyting integer implies itself: h =>? h compiles and decides to true")
def test_heyting_integer_implies_itself(tmp_path):
    proj = _project(tmp_path, (
        "place Entry {}\n"
        "fun main(): Number {\n"
        "  be h := heyting(0, 1)\n"
        "  return match decide(h =>? h) { Present => 7, Absent => 3, Unknown => 3 }\n"
        "}\n"))
    rc, out = _compile(proj, tmp_path / "a.out")
    _verdict(rc == 0, "h =>? h on a Heyting integer does not compile: " + out[-300:])
    rc, _ = _run(tmp_path / "a.out")
    _verdict(rc == 7, f"h =>? h decided to {rc}, expected 7")


# ---------------------------------------------------------------------------
# A place operation with no handler has no value: it is refused, not 0.

def _acc_dialect(tmp, entry):
    return _project(tmp, entry, extra=WORLD_dialect, files={
        "w/Topos.yon": TOPOS_dialect,
        "w/Acc.yon": "place Acc {\n  total Number\n  operation deposit(n: Number): Number\n}\n"})


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a handled place operation with no arguments compiles and returns the handler value")
def test_a_handled_nullary_operation_returns_the_handler_value(tmp_path):
    proj = _project(tmp_path, (
        "place Entry {\n"
        "  reduction Keep of Acc {\n"
        "    be seed := 0\n"
        "    on balance() {\n"
        "      return 40\n"
        "    }\n"
        "  }\n"
        "  fun main(): Number visits Acc { return Acc.balance() + 5 }\n"
        "}\n"), extra=WORLD_dialect, files={
            "w/Topos.yon": TOPOS_dialect,
            "w/Acc.yon": "place Acc {\n  total Number\n  operation balance(): Number\n}\n"})
    rc, out = _compile(proj, tmp_path / "a.out")
    _verdict(rc == 0, "handled nullary operation does not compile: " + out[-300:])
    code, _ = _run(tmp_path / "a.out")
    _verdict(code == 45, f"Acc.balance() + 5 gave {code}, expected 45")


# === the runtime, the prelude and the self-host -----------------------

SELFHOST_runtime = ROOT / "selfhost" / "selfhost_compiler.yon"


def _build_run_runtime(tmp_path, entry, timeout=30, env=None):
    proj = _project(tmp_path, entry)
    exe = tmp_path / "probe.exe"
    rc, out = _compile(proj, exe)
    assert rc == 0, out
    return _run(exe, cwd=tmp_path, timeout=timeout, env=env)


def _numbers_runtime(stdout):
    return [float(t) for t in stdout.split()]


def _lit_runtime(x):
    """An exact Yon literal for the f64 x (the lexer has no exponent form)."""
    if x == 0:
        return "0"
    s = format(Decimal(abs(x)), "f")
    if "." not in s:
        s += ".0"
    return s if x > 0 else f"(0 - {s})"


# --- Number payloads of a coproduct and closure captures keep their value -----

_PAYLOAD_runtime = """\
place Entry {}
fun mot(e: (Lit(Number) | Nil)): Number { return 0 }
fun get(e: (Lit(Number) | Nil)): Number {
  return hit_elim(mot, [Lit(n) => n, Nil => 0], e)
}
fun main(): Number {
  be _a := IO.print_num(get(hit(Lit, %s)))
  return 0
}
"""


def test_coproduct_payload_keeps_a_fraction(tmp_path):
    rc, out = _build_run_runtime(tmp_path, _PAYLOAD_runtime % "1.5")
    _verdict(_numbers_runtime(out) == [1.5], f"payload 1.5 read back as {out.strip()}")


def test_coproduct_payload_keeps_a_negative(tmp_path):
    rc, out = _build_run_runtime(tmp_path, _PAYLOAD_runtime % "0 - 3")
    _verdict(_numbers_runtime(out) == [-3.0], f"payload -3 read back as {out.strip()}")


# A child of a node is always a node handle; a value enters as a leaf whose
# label is its exact f64, so whatever goes in comes out bit for bit.
_PAYLOAD_EXACT_runtime = """\
place Entry {}
fun mot(e: (Lit(Number) | Nil)): Number { return 0 }
fun get(e: (Lit(Number) | Nil)): Number {
  return hit_elim(mot, [Lit(n) => n, Nil => 0], e)
}
fun main(): Number {
  be n := get(hit(Lit, %s))
  return if %s then 1 else 0
}
"""

_PAYLOAD_VALUES = {
    "negative_zero_keeps_its_sign": ("0.0 * (0 - 1)", "1 / n < 0"),
    "nan_stays_nan": ("0.0 / 0.0", "(if n == n then 0 else 1) == 1"),
    "past_2_to_the_32": ("4294967296 + 0.5", "n == 4294967296.5"),
    "past_2_to_the_53": ("9007199254740992 * 1024", "n == 9007199254740992 * 1024"),
}


@pytest.mark.parametrize("value", sorted(_PAYLOAD_VALUES))
def test_coproduct_payload_reads_back_bit_for_bit(tmp_path, value):
    put, check = _PAYLOAD_VALUES[value]
    rc, _ = _build_run_runtime(tmp_path, _PAYLOAD_EXACT_runtime % (put, check))
    assert rc == 1, f"{put} did not read back as itself"


def test_coproduct_payloads_of_every_carrier_read_back(tmp_path):
    """A Boolean, a String and a nested coproduct payload come back as they went in."""
    entry = """\
place Entry {}
fun flag(e: (Flag(Boolean) | Off)): Number { return match e { Flag(b) => if b then 1 else 0, Off => 7 } }
fun name(e: (Named(String) | Anon)): Number { return match e { Named(s) => String.length(s), Anon => 0 } }
fun inner(e: (Wrap((Lit(Number) | Nil)) | None)): Number {
  return match e { Wrap(x) => (match x { Lit(n) => n, Nil => 0 }), None => 0 }
}
fun main(): Number {
  return flag(hit(Flag, 3 > 2)) * 100 + name(hit(Named, "abcde")) * 10
       + inner(hit(Wrap, hit(Lit, 0.5))) * 2
}
"""
    rc, _ = _build_run_runtime(tmp_path, entry)
    assert rc == 151, f"payloads read back as {rc}, expected 1*100 + 5*10 + 0.5*2 = 151"


def test_a_value_is_never_cast_into_a_child(tmp_path):
    """A child that is not a node handle stops the program; it is never cast."""
    entry = """\
place Entry {}
fun main(): Number {
  be n := MerkleTree.node2(9, 1.5, MerkleTree.leaf(0))
  return MerkleTree.label(MerkleTree.child(n, 0))
}
"""
    proj = _project(tmp_path, entry)
    exe = tmp_path / "probe.exe"
    rc, out = _compile(proj, exe)
    assert rc == 0, out
    r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)
    assert r.returncode != 0 and "not a node handle" in r.stderr, (r.returncode, r.stderr)


def test_coproduct_payload_keeps_a_small_integer(tmp_path):
    rc, out = _build_run_runtime(tmp_path, _PAYLOAD_runtime % "7")
    assert _numbers_runtime(out) == [7.0]


def test_prelude_sqrt_result_survives_its_success_arm(tmp_path):
    entry = """\
place Entry {}
fun main(): Number {
  be a := match Number.sqrt(2) { Number as r => r, DomainError as d => 0 - 1 }
  return if a > 1.414 then (if a < 1.415 then 1 else 0) else 0
}
"""
    rc, out = _build_run_runtime(tmp_path, entry)
    _verdict(rc == 1, f"sqrt(2) via its success arm out of (1.414, 1.415): exit {rc}")


_CAPTURE_runtime = """\
place Entry {}
fun scaler(k: Number): Number -> Number {
  return fun(y: Number) => k * y
}
fun main(): Number {
  be f := scaler(%s)
  be _a := IO.print_num(f(10))
  return 0
}
"""


def test_closure_capture_keeps_a_fraction(tmp_path):
    rc, out = _build_run_runtime(tmp_path, _CAPTURE_runtime % "0.5")
    _verdict(_numbers_runtime(out) == [5.0], f"f(10) with k = 0.5 gave {out.strip()}")


def test_closure_capture_keeps_a_negative(tmp_path):
    rc, out = _build_run_runtime(tmp_path, _CAPTURE_runtime % "0 - 3")
    _verdict(_numbers_runtime(out) == [-30.0], f"f(10) with k = -3 gave {out.strip()}")


def test_closure_capture_keeps_a_small_integer(tmp_path):
    rc, out = _build_run_runtime(tmp_path, _CAPTURE_runtime % "4")
    assert _numbers_runtime(out) == [40.0]


# --- lists longer than one heap -------------------------------------------------

@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="List.length of a 200000-element list is 200000")
def test_list_length_counts_past_one_heap(tmp_path):
    entry = """\
place Entry {}
fun main(): Number {
  be _a := IO.print_num(List.length(Sequence.range_to_list(200000)))
  return 0
}
"""
    rc, out = _build_run_runtime(tmp_path, entry)
    _verdict(_numbers_runtime(out) == [200000.0], f"length printed {out.strip()}")


_REVERSE_runtime = """\
place Entry {}
fun main(): Number {
  be m0 := Magma.empty(0)
  be m1 := Magma.gen(m0, 3)
  be m2 := Magma.gen(m1, 5)
  be before := Land.witness(m2, 8)
  be r := List.reverse(Sequence.range_to_list(%d))
  be after := Land.witness(m2, 8)
  return if before == after then 1 else 0
}
"""


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="reversing a long list leaves unrelated values unchanged")
def test_reversing_a_long_list_does_not_touch_other_values(tmp_path):
    rc, out = _build_run_runtime(tmp_path, _REVERSE_runtime % 400000)
    _verdict(rc == 1, f"a magma's witness changed across List.reverse (exit {rc})")


def test_reversing_a_short_list_does_not_touch_other_values(tmp_path):
    rc, out = _build_run_runtime(tmp_path, _REVERSE_runtime % 1000)
    assert rc == 1


# --- wire: values and strings cross the boundary whole ---------------------------

def _wire_runtime(tmp_path, svc_place, consumer_fold, consumer_place, iface):
    """A producer Space `Weather` and a consumer over a shm wire; returns the
    consumer's exit code."""
    toml = ('[package]\nname = "{n}"\n\n[runtime]\nbackend = "shm"\n\n'
            '[world.W]\nobjects = ["X"]\nspaces  = [{s}]\n')
    svc = tmp_path / "svc"
    (svc / "w").mkdir(parents=True)
    (svc / "yon.toml").write_text(toml.format(n="weather_svc", s='"w"'))
    (svc / "Entry.yon").write_text("place Entry {\n  fun main(): Number { return 0 }\n}\n")
    (svc / "w" / "Topos.yon").write_text("topos WTopos where {\n}\n")
    (svc / "w" / "R.yon").write_text(svc_place)
    sub = tmp_path / "sub"
    (sub / "w").mkdir(parents=True)
    (sub / "yon_modules" / "weather").mkdir(parents=True)
    (sub / "yon.toml").write_text(toml.format(n="weather_sub", s='"w", "Weather"'))
    (sub / "w" / "Topos.yon").write_text("topos WTopos where {\n}\n")
    (sub / "w" / "R.yon").write_text(consumer_place)
    (sub / "yon_modules" / "weather" / "weather.yon").write_text(iface)
    (sub / "Entry.yon").write_text(
        "import weather::feed from Weather\n\nplace Entry {\n  fun main(): Number {\n"
        "    be w := wire to space Weather\n    be sub := w.awaits(feed)\n"
        "    be s := sub.stream\n    be total := s.fold(0, " + consumer_fold + ")\n"
        "    return total\n  }\n}\n")
    rc, out = _compile(svc, tmp_path / "Weather_srv")
    assert rc == 0, out
    rc, out = _compile(sub, tmp_path / "sub_bin")
    assert rc == 0, out
    env = dict(os.environ, YON_WORLD="p%03x" % (abs(hash(str(tmp_path))) % 4096))
    rc, _ = _run(tmp_path / "sub_bin", cwd=tmp_path, env=env, timeout=30)
    return rc


_NUM_SVC_runtime = """\
place R {
  t Number

  fun feed(): Wire<Number> {
    be s := produce {
      emit 3
      emit %s
      emit 7
    }
    return s
  }
}
"""
_NUM_IFACE_runtime = "fun feed(): Wire<Number> {\n  be s := produce { emit 1 }\n  return s\n}\n"


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a subscription delivers every emitted Number, -1 included: 3 values arrive")
def test_wire_subscription_delivers_minus_one(tmp_path):
    rc = _wire_runtime(tmp_path, _NUM_SVC_runtime % "0 - 1", "fun(a: Number, r: Number) => a + 1",
               "place R {\n  t Number\n}\n", _NUM_IFACE_runtime)
    _verdict(rc == 3, f"{rc} values arrived, expected 3")


def test_wire_subscription_delivers_three_numbers(tmp_path):
    rc = _wire_runtime(tmp_path, _NUM_SVC_runtime % "1", "fun(a: Number, r: Number) => a + 1",
               "place R {\n  t Number\n}\n", _NUM_IFACE_runtime)
    assert rc == 3


_TEXT_SVC_runtime = """\
place R {
  id Number
  body Text

  fun feed(): Wire<R> {
    be s := produce {
      emit .-> R { id 5 body "%s" }
    }
    return s
  }
}
"""
_TEXT_IFACE_runtime = 'fun feed(): Wire<R> {\n  be s := produce { emit .-> R { id 5 body "x" } }\n  return s\n}\n'


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a Text field crosses a wire whole: 2000 characters arrive as 2000")
def test_wire_carries_a_long_text_field_whole(tmp_path):
    rc = _wire_runtime(tmp_path, _TEXT_SVC_runtime % ("a" * 2000),
               "fun(a: Number, n: R) => a + n.id + String.length(n.body)",
               "place R {\n  id Number\n  body Text\n}\n", _TEXT_IFACE_runtime)
    _verdict(rc == (5 + 2000) % 256, f"exit {rc}, expected {(5 + 2000) % 256} (5 + 2000)")


# --- local streams: data values are not end markers -------------------------------

@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="for every visits each emitted value, 4294967295 included: 4 values")
def test_stream_visits_the_value_two_to_the_32_minus_one(tmp_path):
    entry = """\
place Entry {}
fun main(): Number {
  be s := produce { emit 3 emit 4294967295 emit 7 emit 100 }
  be n := 0
  for every v in s {
    n = n + 1
  }
  return n
}
"""
    rc, out = _build_run_runtime(tmp_path, entry)
    _verdict(rc == 4, f"{rc} values visited, expected 4")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="every spawn returns its own promoted value, the 33rd and later included")
def test_spawn_results_stay_distinct_after_many_spawns(tmp_path):
    entry = """\
place Entry {}
fun one(k: Number): Number {
  be results := spawn in 1 parallel {
    promote k
  }
  return results.fold(0, fun(a: Number, v: Number) => a + v)
}
fun main(): Number {
  be good := 0
  be i := 0
  while i < 40 do {
    good = good + (if one(i + 100) == i + 100 then 1 else 0)
    i = i + 1
  }
  return good
}
"""
    rc, out = _build_run_runtime(tmp_path, entry, timeout=60)
    _verdict(rc == 40, f"{rc} of 40 spawns returned their own value")


# --- collections ----------------------------------------------------------------------

def test_hashset_union_keeps_minus_one(tmp_path):
    entry = """\
place Entry {}
fun main(): Number {
  be s := HashSet.add(HashSet.empty(), 0 - 1)
  return HashSet.size(HashSet.union(s, HashSet.empty()))
}
"""
    rc, out = _build_run_runtime(tmp_path, entry)
    _verdict(rc == 1, f"union size {rc}, expected 1")


def test_hashset_union_keeps_four(tmp_path):
    entry = """\
place Entry {}
fun main(): Number {
  be s := HashSet.add(HashSet.empty(), 4)
  return HashSet.size(HashSet.union(s, HashSet.empty()))
}
"""
    rc, out = _build_run_runtime(tmp_path, entry)
    assert rc == 1


def test_hashmap_set_leaves_the_source_map_unchanged(tmp_path):
    entry = """\
place Entry {}
fun main(): Number {
  be m1 := HashMap.set(HashMap.empty(), 1, 10)
  be m2 := HashMap.set(m1, 2, 20)
  return HashMap.size(m1) * 10 + HashMap.size(m2)
}
"""
    rc, out = _build_run_runtime(tmp_path, entry)
    _verdict(rc == 12, f"size(m1)*10 + size(m2) = {rc}, expected 12")


# A collection has one generic face: what it holds is a type parameter, and a
# lookup answers with Lookup<V>, Found(v) or Absent — never a value in disguise.

def test_a_missing_key_is_absent_not_zero(tmp_path):
    entry = """\
place Entry {}
fun main(): Number {
  be m := HashMap.set(HashMap.empty(), 1, 0)
  be a := match HashMap.get(m, 1) { Found(v) => (if v == 0 then 1 else 0), Absent => 5 }
  be b := match HashMap.get(m, 2) { Found(v) => 7, Absent => 10 }
  return a + b
}
"""
    rc, _ = _build_run_runtime(tmp_path, entry)
    assert rc == 11, f"a held 0 and an absent key: {rc}, expected 1 + 10"


def test_a_collection_holds_its_elements_bit_for_bit(tmp_path):
    """Int64.MAX, Int64.MIN and 2^53+1 in a HashMap<Number, Int64> and a
    HashSet<Int64> come back the same integers."""
    entry = """\
place Entry {}
fun round_trip(x: Int64): Number {
  be m := HashMap.set(HashMap.empty(), 1, x)
  be s := HashSet.add(HashSet.empty(), x)
  be a := match HashMap.get(m, 1) { Found(v) => (if v == x then 1 else 0), Absent => 0 }
  return if HashSet.contains(s, x) then a else 0
}
fun main(): Number {
  return round_trip(Int64.max_value()) + round_trip(Int64.min_value()) * 10
       + round_trip(9007199254740993) * 100
}
"""
    rc, _ = _build_run_runtime(tmp_path, entry)
    assert rc == 111, f"through the collections: {rc}"


def test_one_collection_is_not_another(tmp_path):
    """A HashMap is not a HashSet, and a HashMap<Number, Int64> is not a
    HashMap<Number, Number>."""
    for i, body in enumerate([
            "fun f(s: HashSet<Number>): Number { return HashSet.size(s) }\n"
            "fun main(): Number { return f(HashMap.set(HashMap.empty(), 1, 2)) }\n",
            "fun f(m: HashMap<Number, Number>): Number { return HashMap.size(m) }\n"
            "fun big(): Int64 { return 5 }\n"
            "fun main(): Number { return f(HashMap.set(HashMap.empty(), 1, big())) }\n"]):
        d = tmp_path / str(i)
        d.mkdir()
        rc, out = _compile(_project(d, "place Entry {}\n" + body), d / "out")
        assert _clean_rejection(rc, out), out


def test_every_version_of_a_map_stays_what_it_was(tmp_path):
    """A thousand versions of one map: each keeps its own entries, and there is
    no bound on how many versions there are."""
    entry = """\
place Entry {}
fun fill(m: HashMap<Number, Number>, i: Number, n: Number): HashMap<Number, Number> {
  return if i >= n then m else fill(HashMap.set(m, i, i * 2), i + 1, n)
}
fun main(): Number {
  be m10 := fill(HashMap.empty(), 0, 10)
  be m1000 := fill(m10, 10, 1000)
  be ok10 := if HashMap.size(m10) == 10 then (if HashMap.has(m10, 500) then 0 else 1) else 0
  be v999 := match HashMap.get(m1000, 999) { Found(v) => v, Absent => 0 }
  be ok1000 := if HashMap.size(m1000) == 1000 then (if v999 == 1998 then 1 else 0) else 0
  return ok10 * 10 + ok1000
}
"""
    rc, _ = _build_run_runtime(tmp_path, entry)
    assert rc == 11, f"versions after 10 and 1000 insertions gave {rc // 10},{rc % 10}; expected 1,1"


def test_a_key_is_identified_by_its_bits(tmp_path):
    """-0.0 and 0.0 are two keys, the identity of the heap; a NaN key finds itself."""
    entry = """\
place Entry {}
fun main(): Number {
  be negz := 0.0 * (0 - 1)
  be nan := 0.0 / 0.0
  be s := HashSet.add(HashSet.add(HashSet.add(HashSet.empty(), 0.0), negz), nan)
  return HashSet.size(s) * 10 + (if HashSet.contains(s, nan) then 1 else 0)
}
"""
    rc, _ = _build_run_runtime(tmp_path, entry)
    assert rc == 31, f"size*10 + contains(nan) = {rc}, expected 31"


def test_union_and_intersection_leave_their_operands(tmp_path):
    entry = """\
place Entry {}
fun main(): Number {
  be a := HashSet.add(HashSet.add(HashSet.empty(), 1), 2)
  be b := HashSet.add(HashSet.add(HashSet.empty(), 2), 3)
  be u := HashSet.union(a, b)
  be i := HashSet.intersect(a, b)
  return HashSet.size(u) * 1000 + HashSet.size(i) * 100 + HashSet.size(a) * 10 + HashSet.size(b)
}
"""
    rc, _ = _build_run_runtime(tmp_path, entry)
    assert rc == 3122 % 256, f"sizes gave {rc}, expected u=3 i=1 a=2 b=2"


def test_a_call_with_effects_is_never_shared(tmp_path):
    """Value numbering shares a call only when its callee declares no effect:
    two equal prints both happen."""
    entry = """\
place Entry {}
fun main(): Number {
  be _a := IO.print_num(7)
  be _b := IO.print_num(7)
  return 0
}
"""
    _, out = _build_run_runtime(tmp_path, entry)
    assert _numbers_runtime(out) == [7.0, 7.0], out


def test_xrelmap_returns_the_stored_number(tmp_path):
    entry = """\
place Entry {}
fun held(x: Number): Number {
  return match XRelMap.get(XRelMap.insert(XRelMap.empty(), 1536, x), 1536) { Found(v) => v, Absent => 0 }
}
fun main(): Number {
  be _a := IO.print_num(held(2.5))
  be _b := IO.print_num(held(0 - 3))
  return 0
}
"""
    rc, out = _build_run_runtime(tmp_path, entry)
    _verdict(_numbers_runtime(out) == [2.5, -3.0], f"read back {out.split()}")


def test_arena_returns_the_stored_number(tmp_path):
    entry = """\
place Entry {}
fun held(p: LatticePoint, x: Number): Number {
  return match Arena.get(Arena.put(Arena.empty(), p, x), p) { Found(v) => v, Absent => 0 }
}
fun both(p: LatticePoint): Number {
  be _a := IO.print_num(held(p, 2.5))
  be _b := IO.print_num(held(p, 0 - 3))
  return 0
}
fun main(): Number {
  return match LatticePoint.of_coordinate(1536) { LatticePoint as p => both(p), DomainError as d => 1 }
}
"""
    rc, out = _build_run_runtime(tmp_path, entry)
    _verdict(_numbers_runtime(out) == [2.5, -3.0], f"read back {out.split()}")


def test_arena_returns_a_small_integer(tmp_path):
    entry = """\
place Entry {}
fun main(): Number {
  return match LatticePoint.of_coordinate(1536) {
    LatticePoint as p => (match Arena.get(Arena.put(Arena.empty(), p, 42), p) { Found(v) => v, Absent => 0 }),
    DomainError as d => 0 }
}
"""
    rc, out = _build_run_runtime(tmp_path, entry)
    assert rc == 42


# A lattice slot holds a value inline, as its bits: whatever goes in comes out
# bit for bit (identity by bits: -0.0 keeps its sign, NaN is NaN), and an empty
# slot reads Absent.
_SLOT_GRID = """\
place Entry {}
fun same_n(v: Number, x: Number): Number {
  return if x == x then (if v == x then (if 1 / v == 1 / x then 1 else 0) else 0)
         else (if v == v then 0 else 1)
}
fun arena_n(x: Number): Number {
  return match LatticePoint.of_coordinate(1536) {
    LatticePoint as p => (match Arena.get(Arena.put(Arena.empty(), p, x), p) { Found(v) => same_n(v, x), Absent => 0 }),
    DomainError as d => 0 }
}
fun xrel_n(x: Number): Number {
  return match XRelMap.get(XRelMap.insert(XRelMap.empty(), 1536, x), 1536) { Found(v) => same_n(v, x), Absent => 0 }
}
fun arena_i(x: Int64): Number {
  return match LatticePoint.of_coordinate(1536) {
    LatticePoint as p => (match Arena.get(Arena.put(Arena.empty(), p, x), p) { Found(v) => (if v == x then 1 else 0), Absent => 0 }),
    DomainError as d => 0 }
}
fun xrel_i(x: Int64): Number {
  return match XRelMap.get(XRelMap.insert(XRelMap.empty(), 1536, x), 1536) { Found(v) => (if v == x then 1 else 0), Absent => 0 }
}
fun both_n(x: Number): Number { return arena_n(x) * xrel_n(x) }
fun both_i(x: Int64): Number { return arena_i(x) * xrel_i(x) }
fun main(): Number {
  be inf := 1 / 0.0
  be floats := both_n(2.5) + both_n(0 - 3) + both_n(0.0 * (0 - 1)) + both_n(0.0 / 0.0)
                + both_n(inf) + both_n(0 - inf)
  be ints := both_i(Int64.max_value()) + both_i(Int64.min_value()) + both_i(9007199254740993)
  be empty := match LatticePoint.of_coordinate(1536) {
    LatticePoint as p => (match Arena.get(Arena.empty(), p) { Found(v) => 0, Absent => 1 }),
    DomainError as d => 0 }
  return floats * 100 + ints * 10 + empty
}
"""


def test_a_lattice_slot_holds_every_value_bit_for_bit(tmp_path):
    rc, _ = _build_run_runtime(tmp_path, _SLOT_GRID)
    assert rc == (6 * 100 + 3 * 10 + 1) % 256, f"slots read back {rc}"


def test_a_value_that_does_not_fit_a_slot_is_refused(tmp_path):
    entry = """\
place Entry {}
fun main(): Number {
  be a := Arena.put(Arena.empty(), 1536, true)
  return 0
}
"""
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out), out


# A key is where a value is found. A lattice collection is keyed by a lattice
# point; any other key — a Text among them — goes to HashMap, whose trie
# identifies a key by its identity: the bits of a scalar, the content-addressed
# handle of a section. No collection holds a ceiling: every HashMap is a value.

def test_there_is_no_ceiling_on_the_number_of_maps(tmp_path):
    entry = """\
place Entry {}
fun many(i: Number, acc: Number): Number {
  return if i == 0 then acc
         else many(i - 1, acc + HashMap.size(HashMap.set(HashMap.set(HashMap.empty(), i, 1), 0 - i, 2)))
}
fun main(): Number {
  return many(1000, 0) / 1000
}
"""
    rc, out = _build_run_runtime(tmp_path, entry)
    _verdict(rc == 2, f"2000 live maps of two keys each: mean size {rc}, expected 2")


def test_text_keys_equal_by_content_are_one_key(tmp_path):
    entry = """\
place Entry {}
fun main(): Number {
  be m := HashMap.set(HashMap.empty(), String.concat("ab", "c"), 7)
  be m2 := HashMap.set(m, String.concat("a", "bc"), 9)
  be got := match HashMap.get(m2, "abc") { Found(v) => v, Absent => 0 }
  return HashMap.size(m2) * 10 + got
}
"""
    rc, out = _build_run_runtime(tmp_path, entry)
    _verdict(rc == 19, f"size*10 + value at abc = {rc}, expected 19")


def test_a_text_value_rides_a_lattice_slot_by_its_handle(tmp_path):
    entry = """\
place Entry {}
fun main(): Number {
  be m := XRelMap.insert(XRelMap.empty(), 1536, String.concat("ab", "c"))
  be x := match XRelMap.get(m, 1536) { Found(v) => (if v == "abc" then 1 else 0), Absent => 0 }
  be y := match LatticePoint.of_coordinate(1536) {
    LatticePoint as p => (match Arena.get(Arena.put(Arena.empty(), p, String.concat("a", "bc")), p) {
      Found(v) => String.length(v), Absent => 0 }),
    DomainError as d => 0 }
  return x * 10 + y
}
"""
    rc, out = _build_run_runtime(tmp_path, entry)
    _verdict(rc == 13, f"Text through XRelMap and Arena: {rc}, expected 13")


def test_a_text_key_in_a_lattice_collection_is_refused(tmp_path):
    entry = """\
place Entry {}
fun main(): Number {
  be m := XRelMap.insert(XRelMap.empty(), "abc", 7)
  return XRelMap.size(m)
}
"""
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    _verdict(_clean_rejection(rc, out), f"a Text key was accepted: rc={rc} {out[-300:]}")


@pytest.mark.parametrize("call", ["HashMap.value(HashMap.set(HashMap.empty(), 1, 42), 1)",
                                  "XRelMap.value(XRelMap.insert(XRelMap.empty(), 1536, 42), 1536)",
                                  "match LatticePoint.of_coordinate(1536) { LatticePoint as p => Arena.value(Arena.put(Arena.empty(), p, 42), p), DomainError as d => 0 }"])
def test_a_collection_offers_get_and_keeps_value_to_itself(tmp_path, call):
    """`value` reads a key the collection holds and stops on any other: it is
    how `get` is built, internal to its house. Outside, the face is `get`."""
    entry = f"place Entry {{}}\nfun main(): Number {{\n  return {call}\n}}\n"
    rc, out = _compile(_project(tmp_path, entry), tmp_path / "out")
    assert _clean_rejection(rc, out) and "is internal to" in out, out[-400:]


# A function with a body is never replaced by a primitive: a primitive binds
# to its `is given` declaration in the prelude, not to the string of its name.

@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a function with a body is never replaced by a primitive of the same name")
def test_a_body_is_never_replaced_by_a_primitive_of_its_name(tmp_path):
    prelude = tmp_path / "prelude"
    shutil.copytree(ROOT / "prelude", prelude)
    number = prelude / "num64" / "Number.yon"
    src = number.read_text()
    given = "  fun floor(n: Number): Number is given\n"
    assert given in src, "the prelude no longer declares floor as given"
    number.write_text(src.replace(
        given, "  fun floor(n: Number): Number { return Math.floor(n) + 7 }\n"))
    proj = _project(tmp_path, "place Entry {}\nfun main(): Number { return Number.floor(2.5) }\n")
    r = subprocess.run([str(YONC), str(proj), "-o", str(tmp_path / "out")],
                       capture_output=True, text=True, timeout=120,
                       env={**os.environ, "YON_PRELUDE": str(prelude)})
    out = r.stdout + r.stderr
    if r.returncode != 0:
        _verdict(_clean_rejection(r.returncode, out), f"not a clean rejection: {out[-300:]}")
        return
    code, _ = _run(tmp_path / "out")
    _verdict(code == 9, f"Number.floor(2.5) with `+ 7` in its body gave {code}, expected 9 "
                        "(the body) or a refusal")


def test_merkle_node3_children_are_its_leaves(tmp_path):
    entry = """\
place Entry {}
fun main(): Number {
  be pad1 := MerkleTree.leaf(500)
  be pad2 := MerkleTree.leaf(600)
  be n := MerkleTree.node3(9, MerkleTree.leaf(11), MerkleTree.leaf(22), MerkleTree.leaf(33))
  return MerkleTree.label(MerkleTree.child(n, 0)) + MerkleTree.label(MerkleTree.child(n, 1))
       + MerkleTree.label(MerkleTree.child(n, 2))
}
"""
    rc, out = _build_run_runtime(tmp_path, entry)
    _verdict(rc == 66, f"sum of child labels {rc}, expected 66")


def test_merkle_node3_streams_its_leaves(tmp_path):
    entry = """\
place Entry {}
fun main(): Number {
  be n := MerkleTree.node3(9, MerkleTree.leaf(11), MerkleTree.leaf(22), MerkleTree.leaf(33))
  return List.length(MerkleTree.to_stream(n))
}
"""
    rc, out = _build_run_runtime(tmp_path, entry)
    _verdict(rc == 3, f"{rc} leaves, expected 3")


def test_merkle_node2_children_are_its_leaves(tmp_path):
    entry = """\
place Entry {}
fun main(): Number {
  be n := MerkleTree.node2(9, MerkleTree.leaf(11), MerkleTree.leaf(22))
  return MerkleTree.label(MerkleTree.child(n, 0)) + MerkleTree.label(MerkleTree.child(n, 1))
}
"""
    rc, out = _build_run_runtime(tmp_path, entry)
    assert rc == 33


# --- strings ----------------------------------------------------------------------------

@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="an out-of-range substring is a string: concatenating \"x\" gives length 1")
def test_out_of_range_substring_is_a_neutral_string(tmp_path):
    entry = """\
place Entry {}
fun main(): Number {
  return String.length(String.concat(String.substring("ab", 5, 1), "x"))
}
"""
    rc, out = _build_run_runtime(tmp_path, entry)
    _verdict(rc == 1, f"length {rc}, expected 1")


def test_empty_substring_is_neutral_for_concat(tmp_path):
    entry = """\
place Entry {}
fun main(): Number {
  return String.length(String.concat(String.substring("ab", 0, 0), "x"))
}
"""
    rc, out = _build_run_runtime(tmp_path, entry)
    assert rc == 1


# --- Magma / Land ----------------------------------------------------------------------

@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="the 400th reachability query answers like the first")
def test_land_reach_answers_the_same_on_every_call(tmp_path):
    entry = """\
place Entry {}
fun main(): Number {
  be m0 := Magma.empty(0)
  be m1 := Magma.gen(m0, 3)
  be m2 := Magma.gen(m1, 5)
  be hits := 0
  be i := 0
  while i < 400 do {
    hits = hits + (if Land.reach(m2, 8 + i - i) then 1 else 0)
    i = i + 1
  }
  return if hits == 400 then 1 else 0
}
"""
    rc, out = _build_run_runtime(tmp_path, entry)
    _verdict(rc == 1, "some of 400 identical reach queries answered unreachable")


_LAND_runtime = """\
place Entry {}
fun main(): Number {
  be m0 := %s
  be m1 := Magma.gen(m0, 5)
  be m2 := Magma.gen(m1, 0 - 3)
  return if Land.reach(m2, 2) then 1 else 0
}
"""


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="with generators 5 and -3 under addition, 2 = 5 + (-3) is reachable")
def test_additive_catalog_reaches_through_a_negative_generator(tmp_path):
    rc, out = _build_run_runtime(tmp_path, _LAND_runtime % "Magma.from_catalog(0)")
    _verdict(rc == 1, f"reach answered {rc}, expected 1")


def test_raw_addition_reaches_through_a_negative_generator(tmp_path):
    rc, out = _build_run_runtime(tmp_path, _LAND_runtime % "Magma.empty(0)")
    assert rc == 1


# --- Int64 totality ------------------------------------------------------------------

@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a function marked total returns: Int64.shift_right(8, -1) terminates")
def test_int64_shift_right_terminates_on_a_negative_count(tmp_path):
    entry = """\
place Entry {
  fun main(): Number {
    be a := Int64.shift_right(8, 0 - 1)
    return if a == a then 7 else 9
  }
}
"""
    try:
        rc, out = _build_run_runtime(tmp_path, entry, timeout=20)
    except subprocess.TimeoutExpired:
        rc = None
    _verdict(rc in (7, 9), f"shift_right(8, -1) did not return (exit {rc})")


def test_int64_shift_right_on_a_positive_count(tmp_path):
    entry = """\
place Entry {
  fun main(): Number {
    return if Int64.shift_right(8, 1) == 4 then 1 else 0
  }
}
"""
    rc, out = _build_run_runtime(tmp_path, entry)
    assert rc == 1


# --- the compiler written in Yon: names are compared as names ---------------------------

@pytest.fixture(scope="module")
def selfhost_compiler_runtime(tmp_path_factory):
    d = tmp_path_factory.mktemp("selfhost")
    exe = d / "stage1"
    rc, out = _compile(SELFHOST_runtime, exe, timeout=300)
    assert rc == 0, out
    return exe


def _selfhost_run_runtime(tmp_path, compiler, src):
    work = tmp_path / "work"
    work.mkdir()
    (work / "in.yon").write_text(src)
    subprocess.run([str(compiler), str(work)], capture_output=True, timeout=60)
    mlir = work / "out.mlir"
    assert mlir.exists()
    exe = tmp_path / "prog"
    rc, out = _compile(mlir, exe)
    if rc != 0:
        return None
    return _run(exe)[0]


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="a function named fozp is called, not read as the hit_elim keyword")
def test_selfhost_function_named_like_no_keyword_is_called(tmp_path, selfhost_compiler_runtime):
    rc = _selfhost_run_runtime(tmp_path, selfhost_compiler_runtime,
                       "fun fozp(x): Number { return x + 1 }\n"
                       "fun main(): Number { return fozp(41) }")
    _verdict(rc == 42, f"fozp(41) gave exit {rc}, expected 42")


@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="two functions with different names are two functions: aaaa(2) + aobsf(3) = 33")
def test_selfhost_distinct_names_are_distinct_functions(tmp_path, selfhost_compiler_runtime):
    rc = _selfhost_run_runtime(tmp_path, selfhost_compiler_runtime,
                       "fun aaaa(x): Number { return x + 1 }\n"
                       "fun aobsf(x): Number { return x * 10 }\n"
                       "fun main(): Number { return aaaa(2) + aobsf(3) }")
    _verdict(rc == 33, f"exit {rc} (None = the emitted module did not lower), expected 33")


def test_selfhost_two_names_with_distinct_hashes_call_their_own_bodies(tmp_path, selfhost_compiler_runtime):
    rc = _selfhost_run_runtime(tmp_path, selfhost_compiler_runtime,
                       "fun aaaa(x): Number { return x + 1 }\n"
                       "fun aobsg(x): Number { return x * 10 }\n"
                       "fun main(): Number { return aaaa(2) + aobsg(3) }")
    assert rc == 33


# --- a shared-memory Space heap under concurrent replicas -------------------------------

_SHM_ENTRY_runtime = """\
place Entry {
  fun probe(base: Number): Number {
    be bad := 0
    be k := 0
    while k < 1000 do {
      be p := .-> P { v base + k }
      bad = bad + (if p.v == base + k then 0 else 1)
      k = k + 1
    }
    return bad
  }
  fun main(): Number {
    be results := spawn in 8 parallel {
      promote probe(spawn_index * 100000 + 1)
    }
    return results.fold(0, fun(a: Number, v: Number) => a + v)
  }
}
"""


def _shm_project_runtime(tmp_path, backend):
    proj = tmp_path / "proj"
    (proj / "w").mkdir(parents=True)
    (proj / "yon.toml").write_text(
        '[package]\nname = "probe"\n\n[runtime]\nbackend = "%s"\n\n'
        '[world.W]\nobjects = ["X"]\nspaces  = ["w"]\n' % backend)
    (proj / "w" / "Topos.yon").write_text("topos WTopos where {\n}\n")
    (proj / "w" / "P.yon").write_text("place P {\n  v Number\n}\n")
    (proj / "Entry.yon").write_text(_SHM_ENTRY_runtime)
    exe = tmp_path / "probe.exe"
    rc, out = _compile(proj, exe)
    assert rc == 0, out
    return exe


@pytest.mark.skipif(sys.platform not in ("darwin", "linux"),
                    reason="needs POSIX shared memory and fork")
@pytest.mark.xfail(strict=True, raises=ProbeOutcome,
                   reason="sections built concurrently in a shared Space heap each read back their own value")
def test_shared_space_heap_keeps_concurrent_sections_apart(tmp_path):
    exe = _shm_project_runtime(tmp_path, "shm")
    worst = 0
    for i in range(3):
        env = dict(os.environ, YON_WORLD="q%03x" % ((abs(hash(str(tmp_path))) + i) % 4096))
        rc, _ = _run(exe, cwd=tmp_path, env=env, timeout=60)
        worst = max(worst, rc)
    _verdict(worst == 0, f"{worst} sections read back another replica's value")


def test_private_space_heaps_keep_concurrent_sections_apart(tmp_path):
    exe = _shm_project_runtime(tmp_path, "memory")
    env = dict(os.environ, YON_BACKEND="separate")
    rc, _ = _run(exe, cwd=tmp_path, env=env, timeout=60)
    assert rc == 0



# One concept of channel: what a produce block emits goes through a local
# Wire<T>, the channel between Spaces; a Stream<T> (an infinite pure unfold)
# is not a channel.
def _produce_returning(ty):
    return ("place Entry {}\n"
            f"fun f(): {ty} {{\n  be s := produce {{ emit 40\n emit 2 }}\n  return s\n}}\n"
            "fun main(): Number {\n  be s := f()\n"
            "  return s.fold(0, fun(a: Number, v: Number) => a + v)\n}\n")


def test_a_produce_block_is_a_wire(tmp_path):
    rc, _ = _build_run_runtime(tmp_path, _produce_returning("Wire<Number>"))
    assert rc == 42, f"a produced Wire folded to {rc}"


def test_a_stream_is_not_a_channel(tmp_path):
    rc, out = _compile(_project(tmp_path, _produce_returning("Stream<Number>")),
                       tmp_path / "out")
    assert _clean_rejection(rc, out), out
