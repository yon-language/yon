"""Number's functions against an oracle that cannot share their mistakes.

sqrt, exp, ln, sin and floor are compiled, run on a grid, and every result is
held against Arb (FLINT's ball arithmetic): the true value is enclosed in a
ball computed at whatever precision makes it far narrower than one ulp, and the
result must lie in that ball widened by the declared tolerance of its function.
The oracle is not the platform's libm, which is what the functions call: a
comparison of libm with libm would agree with itself whatever it computed.

Arb lives here only. Nothing in the runtime, the prelude or the compiler reads
it; it is a dependency of this test and of nothing else (regression/
requirements.txt).

The grid crosses every region where a libm goes wrong: negatives, both zeros,
subnormals, the largest finite doubles, the overflow and underflow edges, NaN
and both infinities, arguments where the result nearly cancels (sin near pi,
ln near 1). Where IEEE 754 fixes the answer exactly (a NaN, an infinity, a
signed zero) the expectation is that exact value, sign included. Where Yon's
own law answers (sqrt of a negative, ln of a non-positive: a DomainError, never
a NaN), the expectation is the error arm.

A result is read back exactly: the program prints (y - a) / u, where a is the
double nearest the ball's centre and u a power of two (the ulp at a). Near the
truth that difference and that quotient are exact and small, so %g prints them
whole, and y = a + d*u is reconstructed as a rational with no rounding.
"""
from decimal import Decimal
from fractions import Fraction
from pathlib import Path
import math
import subprocess

import pytest
from flint import arb, ctx, fmpq

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

_TOML = '[package]\nname = "oracle"\n\n[runtime]\nbackend = "memory"\n'

NAN, INF = float("nan"), float("inf")
MAXD = 1.7976931348623157e308
MIN_NORMAL = 2.2250738585072014e-308
MIN_SUB = 5e-324
TWO_1024 = arb(2) ** 1024

# The tolerance of each function, in ulps of the true value. sqrt is
# correctly rounded by IEEE 754 (half an ulp); floor is exact; exp, ln and sin
# are faithful: within one ulp.
ULPS = {"sqrt": 0.5, "exp": 1, "ln": 1, "sin": 1, "floor": 0}

COMMON = [NAN, INF, -INF, 0.0, -0.0,
          MIN_SUB, -MIN_SUB, 1e-310, -1e-310, MIN_NORMAL, -MIN_NORMAL, 1e-300,
          0.5, -0.5, 1.0, -1.0, 2.0, 2.5, -2.5, 10.0, 100.0, 1e10, 1e22,
          1e300, -1e300, MAXD, -MAXD]

GRID = {
    "sqrt": COMMON + [3.0, 0.1, 4503599627370497.0],
    "exp": COMMON + [-20.0, 30.0, 700.0, 709.0, 709.78, 710.0, -708.0, -740.0,
                     -745.0, -746.0, -1000.0, 1e-16],
    "ln": COMMON + [0.9999999999999999, 1.0000000000000002, 2.718281828459045,
                    0.1, 3.0],
    "sin": COMMON + [3.141592653589793, 1.5707963267948966, 6.283185307179586,
                     1e6, 1e15, 9007199254740992.0, -1e22, 1e-16],
    "floor": COMMON + [4503599627370495.5, -4503599627370495.5,
                       0.9999999999999999, -0.9999999999999999, 1e15 + 0.5],
}

# The call each form makes, the outcome IEEE 754 fixes on the special inputs,
# and the domain Yon's partial functions refuse.
#   house:  the prelude's Number.<f> (sqrt and ln carry `on error DomainError`)
#   given:  the primitive Math.<f> it is built on
FORMS = {
    ("house", "sqrt"):  ("Number.sqrt({x})", True),
    ("house", "exp"):   ("Number.exp({x})", False),
    ("house", "ln"):    ("Number.ln({x})", True),
    ("house", "sin"):   ("Number.sin({x})", False),
    ("house", "floor"): ("Number.floor({x})", False),
    ("given", "sqrt"):  ("Math.sqrt({x})", False),
    ("given", "exp"):   ("Math.exp({x})", False),
    ("given", "ln"):    ("Math.log({x})", False),
    ("given", "sin"):   ("Math.sin({x})", False),
    ("given", "floor"): ("Math.floor({x})", False),
}


def _refused(form: str, fn: str, x: float) -> bool:
    """Yon's partial functions answer DomainError off their domain."""
    if form != "house" or math.isnan(x):
        return False
    return (fn == "sqrt" and x < 0) or (fn == "ln" and x <= 0)


def _ieee_special(fn: str, x: float):
    """The result IEEE 754 (and C Annex F) fixes exactly, or None when the
    result is an ordinary finite value the oracle must enclose."""
    neg0 = math.copysign(1.0, x) < 0
    if math.isnan(x):
        return NAN
    if fn == "sqrt":
        if x == 0:
            return x
        if x < 0:
            return NAN
        if x == INF:
            return INF
    if fn == "exp":
        if x == INF:
            return INF
        if x == -INF:
            return 0.0
        if x == 0:
            return 1.0
    if fn == "ln":
        if x == 0:
            return -INF
        if x < 0:
            return NAN
        if x == INF:
            return INF
        if x == 1.0:
            return 0.0
    if fn == "sin":
        if math.isinf(x):
            return NAN
        if x == 0:
            return -0.0 if neg0 else 0.0
    if fn == "floor":
        if math.isinf(x) or x == 0:
            return x
    return None


def _ball(fn: str, x: float):
    """The true value as an Arb ball whose radius is far below an ulp."""
    prec = 128
    while True:
        ctx.prec = prec
        a = arb(x)
        t = {"sqrt": a.sqrt, "exp": a.exp, "ln": a.log, "sin": a.sin,
             "floor": a.floor}[fn]()
        if t.is_exact() or t > TWO_1024 or -t > TWO_1024:
            return t
        u = _ulp(float(t.mid()), t)
        if t.rad() <= arb(u) * arb(2) ** -30:
            return t
        prec *= 2
        if prec > 1 << 16:
            raise AssertionError(f"Arb cannot narrow {fn}({x!r}) below an ulp")


def _ulp(a: float, t) -> float:
    """The spacing of doubles where the true value t lies (a is its nearest
    double): below a power of two the spacing is half the one above."""
    if a == 0 or abs(a) < MIN_NORMAL:
        return MIN_SUB
    if math.isinf(a):
        return math.ulp(MAXD)
    u = math.ulp(abs(a))
    m, _ = math.frexp(abs(a))
    if m == 0.5 and abs(t) < arb(abs(a)):
        u /= 2
    return u


def _lit(x: float) -> str:
    """An exact Yon expression for the double x (the lexer has no exponent
    form; the specials are computed so no folding can change them)."""
    if math.isnan(x):
        return "(recip(0) - recip(0))"
    if math.isinf(x):
        return "recip(0)" if x > 0 else "recip(negz())"
    if x == 0:
        return "negz()" if math.copysign(1.0, x) < 0 else "0"
    s = format(Decimal(abs(x)), "f")
    if "." not in s:
        s += ".0"
    return s if x > 0 else f"(0 - {s})"


def _expectations(form: str, fn: str):
    """Per grid point: ("refused",) | ("exact", v) | ("ball", t, a, u)."""
    out = []
    for x in GRID[fn]:
        if _refused(form, fn, x):
            out.append(("refused",))
            continue
        s = _ieee_special(fn, x)
        if s is not None:
            out.append(("exact", s))
            continue
        t = _ball(fn, x)
        if t > TWO_1024:
            out.append(("exact", INF))
        elif -t > TWO_1024:
            out.append(("exact", -INF))
        else:
            a = float(t.mid())
            out.append(("ball", t, a, _ulp(a, t)))
    return out


def _program(form: str, fn: str, exps) -> str:
    call, partial = FORMS[(form, fn)]
    lines = []
    for i, (x, e) in enumerate(zip(GRID[fn], exps)):
        if e[0] == "ball":
            arm = f"near({i}, r, {_lit(e[2])}, {_lit(e[3])})"
        else:
            arm = f"raw({i}, r)"
        c = call.format(x=_lit(x))
        if partial:
            body = f"match {c} {{ Number as r => {arm}, DomainError as d => dom({i}) }}"
        else:
            body = f"report({i}, {c}, {_lit(e[2]) if e[0] == 'ball' else '0'}, " \
                   f"{_lit(e[3]) if e[0] == 'ball' else '1'}, {1 if e[0] == 'ball' else 0})"
        lines.append(f"  _v{i} := {body}")
    return ("place Entry {}\n"
            "fun negz(): Number { return 0 * (0 - 1) }\n"
            "fun recip(x: Number): Number { return 1 / x }\n"
            "fun raw(i: Number, y: Number): Number {\n"
            "  _i := IO.print_num(i)\n  _k := IO.print_num(0)\n"
            "  _y := IO.print_num(y)\n  return 0\n}\n"
            "fun near(i: Number, y: Number, a: Number, u: Number): Number {\n"
            "  _i := IO.print_num(i)\n  _k := IO.print_num(0)\n"
            "  _y := IO.print_num((y - a) / u)\n  return 0\n}\n"
            "fun dom(i: Number): Number {\n"
            "  _i := IO.print_num(i)\n  _k := IO.print_num(1)\n"
            "  _y := IO.print_num(0)\n  return 0\n}\n"
            "fun report(i: Number, y: Number, a: Number, u: Number, scaled: Number): Number {\n"
            "  return if scaled == 1 then near(i, y, a, u) else raw(i, y)\n}\n"
            "fun main(): Number {\n" + "\n".join(lines) + "\n  return 0\n}\n")


def _parse(tok: str) -> float:
    return {"nan": NAN, "-nan": NAN, "inf": INF, "-inf": -INF}.get(tok) \
        if tok in ("nan", "-nan", "inf", "-inf") else float(tok)


def _same(y: float, v: float) -> bool:
    if math.isnan(v):
        return math.isnan(y)
    return y == v and math.copysign(1.0, y) == math.copysign(1.0, v)


def _in_ball(d: float, e, ulps: float) -> bool:
    _, t, a, u = e
    if not math.isfinite(d) or abs(d) > 1e5:
        return False
    y = Fraction(a) + Fraction(d) * Fraction(u)
    ctx.prec = max(ctx.prec, 256)
    diff = abs(arb(fmpq(y.numerator, y.denominator)) - t)
    return bool(diff <= arb(u) * arb(ulps))


@pytest.mark.parametrize("form", ["house", "given"])
@pytest.mark.parametrize("fn", ["sqrt", "exp", "ln", "sin", "floor"])
def test_number_function_lies_in_the_arb_ball(tmp_path, fn, form):
    exps = _expectations(form, fn)
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML)
    (proj / "Entry.yon").write_text(_program(form, fn, exps))
    exe = tmp_path / "oracle.exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True,
                       text=True, timeout=180)
    assert r.returncode == 0, (r.stdout + r.stderr)[-600:]
    run = subprocess.run([str(exe)], capture_output=True, text=True, timeout=60)
    assert run.returncode == 0, run.stderr[-400:]
    toks = run.stdout.split()
    n = len(GRID[fn])
    assert len(toks) == 3 * n, f"expected {3 * n} tokens, got {len(toks)}: {run.stdout[-300:]}"
    bad = []
    for i, (x, e) in enumerate(zip(GRID[fn], exps)):
        idx, kind, val = toks[3 * i: 3 * i + 3]
        assert float(idx) == i, f"output out of order at {i}: {toks[3 * i: 3 * i + 3]}"
        refused = kind == "1"
        if e[0] == "refused":
            if not refused:
                bad.append((x, "a value", "DomainError"))
            continue
        if refused:
            bad.append((x, "DomainError", e[1] if e[0] == "exact" else "a value"))
            continue
        y = _parse(val)
        if e[0] == "exact":
            if not _same(y, e[1]):
                bad.append((x, val, e[1]))
        elif not _in_ball(y, e, ULPS[fn]):
            bad.append((x, f"(y-a)/u = {val}", f"within {ULPS[fn]} ulp of {e[1]}"))
    assert not bad, f"{form} {fn} (x, got, expected): {bad}"
