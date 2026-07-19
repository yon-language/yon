"""Self-host M6 differential oracle -- the Yon0-in-Yon compiler agrees with yonc.

For a corpus of Yon0 programs, compile each one BOTH with the OCaml reference
compiler (`yonc`) and with selfhost/selfhost_compiler.yon (the compiler written in
Yon, which reads a source file and emits an MLIR module), run both native binaries,
and require the SAME exit code. Agreement with the reference is the convergence
metric toward the M-bootstrap: where the two compilers agree, the Yon-in-Yon
frontend behaves as the reference does.

This oracle already earned its keep: it caught a real bug -- `a - b - c` was parsed
right-associative (a-(b-c)) instead of left (a-b)-c, so `10 - 3 - 2` gave 9 where
the reference gave 5. The parser was fixed to left-associative and the two now
converge (see the chain_sub / mixed_prec cases below).

Note: selfhost_compiler.yon reads/writes fixed /tmp paths (Yon's argv access has
friction), so these cases share global files and must run serially (as the rest of
the self-host suite already does).
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
COMPILER = ROOT / "selfhost" / "selfhost_compiler.yon"
IN_PATH = Path("/tmp/yon_selfhost_in.yon")     # the tool's hardcoded input
OUT_MLIR = Path("/tmp/yon_selfhost_out.mlir")  # the tool's hardcoded output

# (name, Yon0 source, expected exit). The core assertion is reference == self-hosted;
# `expected` is a sanity anchor that also rejects a shared-wrong-answer.
PROGRAMS = [
    ("arith",      "fun main(): number { return 2 + 3 * 4 }", 14),
    ("single_sub", "fun main(): number { return 10 - 3 }", 7),
    ("chain_sub",  "fun main(): number { return 10 - 3 - 2 }", 5),
    ("mixed_prec", "fun main(): number { return 100 - 2 * 3 - 4 }", 90),
    ("let42",      "fun main(): number { be x holds 20  be y holds 22  return x + y }", 42),
    ("if_false",   "fun main(): number { be x holds 20  be y holds 22  "
                   "return if x == y then 99 else x + y }", 42),
    ("call",       "fun dbl(x): number { return x + x }\n"
                   "fun main(): number { return dbl(21) }", 42),
    ("fact5",      "fun fact(n): number { return if n == 0 then 1 else n * fact(n - 1) }\n"
                   "fun main(): number { return fact(5) }", 120),
    ("sum10",      "fun sum(n): number { return if n == 0 then 0 else n + sum(n - 1) }\n"
                   "fun main(): number { return sum(10) }", 55),
    # multiple parameters (3-arg), plus a digit in the function name (sub3).
    ("multi_arg",  "fun sub3(a, b, c): number { return a - b - c }\n"
                   "fun main(): number { return sub3(100, 30, 8) }", 62),
    # underscore in identifiers, two parameters.
    ("ident_us",   "fun add_two(x, y): number { return x + y }\n"
                   "fun main(): number { return add_two(19, 23) }", 42),
    # comparison operators beyond ==: <, !=, and >= inside a recursion.
    ("cmp_lt",     "fun main(): number { return if 3 < 4 then 11 else 22 }", 11),
    ("cmp_ne",     "fun main(): number { return if 3 != 3 then 11 else 22 }", 22),
    ("cmp_ge_rec", "fun cd(n): number { return if n >= 1 then cd(n - 1) else 42 }\n"
                   "fun main(): number { return cd(9) }", 42),
    # block and line comments must be skipped by the lexer.
    ("comments",   "/* a header comment */\n"
                   "fun main(): number {\n"
                   "  /* inline */ return 40 + 2 // a line comment\n"
                   "}\n", 42),
    # Stage 1 of the heavy core: nullary coproduct places, hit and hit_elim
    # (a runtime tag switch over MerkleTree labels).
    ("enum_bit",   "place Bit { this > O :U I }\n"
                   "fun mot(b: Bit): number { return 0 }\n"
                   "fun v(b: Bit): number { return hit_elim(mot, [ O => 0, I => 1 ], b) }\n"
                   "fun main(): number { return v(hit(I)) }", 1),
    ("enum_dir",   "place Dir { this > N :U S :U E }\n"
                   "fun mot(d: Dir): number { return 0 }\n"
                   "fun code(d: Dir): number { return hit_elim(mot, [ N => 10, S => 20, E => 30 ], d) }\n"
                   "fun main(): number { return code(hit(E)) }", 30),
    # Stage 2: number-payload arms -- hit stores a raw number child,
    # a pattern binder projects it back with child().
    ("payload_lit", "place Val { this > Lit(number) }\n"
                    "fun mot(v: Val): number { return 0 }\n"
                    "fun get(v: Val): number { return hit_elim(mot, [ Lit(n) => n ], v) }\n"
                    "fun main(): number { return get(hit(Lit, 42)) }", 42),
    # a mix of a nullary and a payload arm (the names are arbitrary user
    # constructors -- Yon has no built-in option type).
    ("payload_mix", "place Box { this > Empty :U Full(number) }\n"
                    "fun mot(o: Box): number { return 0 }\n"
                    "fun un(o: Box): number { return hit_elim(mot, [ Empty => 99, Full(x) => x ], o) }\n"
                    "fun main(): number { return un(hit(Full, 7)) }", 7),
    # a two-field arm: both payloads projected.
    ("payload_duo", "place Duo { this > Both(number, number) }\n"
                    "fun mot(d: Duo): number { return 0 }\n"
                    "fun a(d: Duo): number { return hit_elim(mot, [ Both(x, y) => x ], d) }\n"
                    "fun b(d: Duo): number { return hit_elim(mot, [ Both(x, y) => y ], d) }\n"
                    "fun main(): number { return a(hit(Both, 5, 9)) + b(hit(Both, 5, 9)) }", 14),
    # Stage 3: nested / recursive payloads (a sum handle stored raw as a child).
    # ev(build(3)) = -(-(-7)) = -7 = 249 mod 256.
    ("rec_neg",    "place Term { this > Lit(number) :U Neg(Term) }\n"
                   "fun mot(t: Term): number { return 0 }\n"
                   "fun ev(t: Term): number { return hit_elim(mot, [ Lit(n) => n, Neg(m) => 0 - ev(m) ], t) }\n"
                   "fun build(k: number): Term { return if k == 0 then hit(Lit, 7) else hit(Neg, build(k - 1)) }\n"
                   "fun main(): number { return ev(build(3)) }", 249),
    # a recursive list with a number + a nested-list payload; sum = 42.
    ("rec_list",   "place Lst { this > Nil :U Cons(number, Lst) }\n"
                   "fun mot(l: Lst): number { return 0 }\n"
                   "fun sum(l: Lst): number { return hit_elim(mot, [ Nil => 0, Cons(h, t) => h + sum(t) ], l) }\n"
                   "fun main(): number { return sum(hit(Cons, 10, hit(Cons, 20, hit(Cons, 12, hit(Nil))))) }", 42),
]


def _run(binary):
    return subprocess.run([str(binary)], capture_output=True, timeout=60).returncode


def _reference(tmp_path, src):
    """Compile and run src with the OCaml reference compiler."""
    s = tmp_path / "ref_src.yon"
    s.write_text(src)
    b = tmp_path / "ref_bin"
    c = subprocess.run([str(YONC), str(s), "-o", str(b)],
                       capture_output=True, text=True, timeout=180)
    assert c.returncode == 0 and b.exists(), \
        f"reference did not compile the program:\n{c.stderr[-800:]}"
    return _run(b)


def _self_hosted(tmp_path, compiler_bin, src):
    """Compile and run src with the Yon0-in-Yon compiler (prebuilt as compiler_bin)."""
    IN_PATH.write_text(src)
    if OUT_MLIR.exists():
        OUT_MLIR.unlink()
    subprocess.run([str(compiler_bin)], capture_output=True, timeout=60)
    assert OUT_MLIR.exists(), "the Yon0-in-Yon compiler did not write an MLIR module"
    b = tmp_path / "self_bin"
    c = subprocess.run([str(YONC), str(OUT_MLIR), "-o", str(b)],
                       capture_output=True, text=True, timeout=180)
    assert c.returncode == 0 and b.exists(), \
        f"MLIR emitted by the Yon0-in-Yon compiler did not compile:\n{c.stderr[-800:]}"
    return _run(b)


@pytest.fixture(scope="module")
def compiler_bin(tmp_path_factory):
    """Build the Yon0-in-Yon compiler once for the whole module."""
    d = tmp_path_factory.mktemp("selfhostc")
    b = d / "selfhost_compiler"
    c = subprocess.run([str(YONC), str(COMPILER), "-o", str(b)],
                       capture_output=True, text=True, timeout=240)
    assert c.returncode == 0 and b.exists(), \
        f"selfhost_compiler.yon did not build:\n{c.stderr[-800:]}"
    return b


@pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc not present")
@pytest.mark.parametrize("name,src,expected", PROGRAMS, ids=[p[0] for p in PROGRAMS])
def test_differential(tmp_path, compiler_bin, name, src, expected):
    a = _reference(tmp_path, src)
    b = _self_hosted(tmp_path, compiler_bin, src)
    assert a == b, \
        f"[{name}] reference exited {a}, self-hosted exited {b} -- the compilers DIVERGE"
    assert a == expected, \
        f"[{name}] both compilers exited {a}, expected {expected}"
