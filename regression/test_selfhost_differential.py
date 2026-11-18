"""Self-host differential oracle -- the Yon0-in-Yon compiler agrees with yonc.

For a corpus of Yon0 programs, compile each one BOTH with the OCaml reference
compiler (`yonc`) and with selfhost/selfhost_compiler.yon (the compiler written in
Yon, which reads a source file and emits an MLIR module), run both native binaries,
and require the SAME exit code: where the two compilers agree, the Yon-in-Yon
frontend behaves as the reference does. `-` is left-associative in both:
`10 - 3 - 2` = (10-3)-2 = 5 (the chain_sub / mixed_prec cases below).

selfhost_compiler.yon works in the directory given as its first argument
(<dir>/in.yon -> <dir>/out.mlir), so every case uses its own and the cases run in
parallel; test_two_runs_side_by_side pins that.
"""
import subprocess
from pathlib import Path

import pytest
from yon_programs import program

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
COMPILER = ROOT / "selfhost" / "selfhost_compiler.yon"

# (name, Yon0 source, expected exit). The core assertion is reference == self-hosted;
# `expected` is a sanity anchor that also rejects a shared-wrong-answer.
PROGRAMS = [
    ("arith",      program("test_selfhost_differential/module_1.yon"), 14),
    ("single_sub", program("test_selfhost_differential/module_2.yon"), 7),
    ("chain_sub",  program("test_selfhost_differential/module_3.yon"), 5),
    ("mixed_prec", program("test_selfhost_differential/module_4.yon"), 90),
    ("let42",      program("test_selfhost_differential/module_5.yon"), 42),
    ("if_false",   program("test_selfhost_differential/module_6.yon"), 42),
    ("call",       program("test_selfhost_differential/module_7.yon"), 42),
    ("fact5",      program("test_selfhost_differential/module_8.yon"), 120),
    ("sum10",      program("test_selfhost_differential/module_9.yon"), 55),
    # multiple parameters (3-arg), plus a digit in the function name (sub3).
    ("multi_arg",  program("test_selfhost_differential/module_10.yon"), 62),
    # underscore in identifiers, two parameters.
    ("ident_us",   program("test_selfhost_differential/module_11.yon"), 42),
    # comparison operators beyond ==: <, !=, and >= inside a recursion.
    ("cmp_lt",     program("test_selfhost_differential/module_12.yon"), 11),
    ("cmp_ne",     program("test_selfhost_differential/module_13.yon"), 22),
    ("cmp_ge_rec", program("test_selfhost_differential/module_14.yon"), 42),
    # block and line comments must be skipped by the lexer.
    ("comments",   program("test_selfhost_differential/module_15.yon"), 42),
    # Stage 1 of the heavy core: nullary coproduct places, bare arms and match
    # (a runtime tag switch over MerkleTree labels).
    ("enum_bit",   program("test_selfhost_differential/module_16.yon"), 1),
    ("enum_dir",   program("test_selfhost_differential/module_17.yon"), 30),
    # Stage 2: number-payload arms -- an injection stores a raw number child,
    # a pattern binder projects it back with child().
    ("payload_lit", program("test_selfhost_differential/module_18.yon"), 42),
    # a mix of a nullary and a payload arm (the names are arbitrary user
    # constructors -- Yon has no built-in option type).
    ("payload_mix", program("test_selfhost_differential/module_19.yon"), 7),
    # a two-field arm: both payloads projected.
    ("payload_duo", program("test_selfhost_differential/module_20.yon"), 14),
    # Stage 3: nested / recursive payloads (a sum handle stored raw as a child).
    # ev(build(3)) = -(-(-7)) = -7 = 249 mod 256.
    ("rec_neg",    program("test_selfhost_differential/module_21.yon"), 249),
    # a recursive list with a number + a nested-list payload; sum = 42.
    ("rec_list",   program("test_selfhost_differential/module_22.yon"), 42),
    # Text literals and qualified runtime calls (Text.op). A literal lexes
    # to a content handle (substring), lowers to a from_char/concat chain that
    # interns to the same content-address as yonc's global+string_lit, so the
    # exit codes agree; `Text.op(..)` lowers to a runtime call.
    ("str_len",    program("test_selfhost_differential/module_23.yon"), 5),
    ("str_concat", program("test_selfhost_differential/module_24.yon"), 5),
    ("str_char",   program("test_selfhost_differential/module_25.yon"), 66),
    ("str_in_fun", program("test_selfhost_differential/module_26.yon"), 4),
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
    work = tmp_path / "selfhost"
    work.mkdir()
    (work / "in.yon").write_text(src)
    r = subprocess.run([str(compiler_bin), str(work)], capture_output=True, timeout=60)
    out_mlir = work / "out.mlir"
    assert out_mlir.exists(), (
        f"the Yon0-in-Yon compiler did not write an MLIR module (exit {r.returncode})")
    b = tmp_path / "self_bin"
    c = subprocess.run([str(YONC), str(out_mlir), "-o", str(b)],
                       capture_output=True, text=True, timeout=180)
    assert c.returncode == 0 and b.exists(), \
        f"MLIR emitted by the Yon0-in-Yon compiler did not compile:\n{c.stderr[-800:]}"
    return _run(b)


@pytest.fixture(scope="session")
def compiler_bin(selfhost_compiler_bin):
    """The Yon0-in-Yon compiler, built once for the session (conftest)."""
    return selfhost_compiler_bin


@pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc not present")
@pytest.mark.parametrize("name,src,expected", PROGRAMS, ids=[p[0] for p in PROGRAMS])
def test_differential(tmp_path, compiler_bin, name, src, expected):
    a = _reference(tmp_path, src)
    b = _self_hosted(tmp_path, compiler_bin, src)
    assert a == b, \
        f"[{name}] reference exited {a}, self-hosted exited {b} -- the compilers DIVERGE"
    assert a == expected, \
        f"[{name}] both compilers exited {a}, expected {expected}"


def test_two_runs_side_by_side(tmp_path, compiler_bin):
    """Two runs of the compiler at once, each in its own directory: neither sees
    the other's input or output (a shared fixed path would capture names
    between runs)."""
    cases = [p for p in PROGRAMS if p[0] in ("fact5", "str_concat")]
    procs = []
    for name, src, _ in cases:
        work = tmp_path / name
        work.mkdir()
        (work / "in.yon").write_text(src)
        procs.append((name, work, subprocess.Popen([str(compiler_bin), str(work)],
                                                   stdout=subprocess.DEVNULL,
                                                   stderr=subprocess.DEVNULL)))
    for name, work, p in procs:
        p.wait(timeout=120)              # its exit code is the module's length
        assert (work / "out.mlir").exists(), f"[{name}] no MLIR written"
    for (name, work, _), (_, _, expected) in zip(procs, cases):
        b = tmp_path / f"{name}_bin"
        c = subprocess.run([str(YONC), str(work / "out.mlir"), "-o", str(b)],
                           capture_output=True, text=True, timeout=180)
        assert c.returncode == 0, f"[{name}] {c.stderr[-800:]}"
        assert _run(b) == expected, name
