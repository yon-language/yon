"""The names the compiler and the runtime make are theirs, and a fun of the program is no symbol.

A user fun or place named like a name the compiler generates (`__...`), the runtime (`yon_rt_...`),
or the qualified name of a fun of a house (`House__f`, for the places of the program and of the
library, and the houses of the lowering: Stream, Wire, Spawn) is refused where it is declared, E2025:
it would take the place of the one the compiler means (a prelude fun, a symbol of the runtime at the
link). A name with `__` whose head is no house names nothing of the compiler and stays legal. A fun
of the program is emitted with internal linkage: `strlen` or `malloc` of the program are local
symbols, and the system's stay the system's.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_TOML = '[package]\nname = "names"\n\n[runtime]\nbackend = "memory"\n'


def _entry(tmp_path, decl, main="  fun main: Number { return 7 }\n"):
    (tmp_path / "yon.toml").write_text(_TOML)
    (tmp_path / "Entry.yon").write_text("place Entry {\n" + decl + main + "}\n")
    return tmp_path


_RESERVED = [
    ("__conto", "it begins with `__`"),
    ("yon_rt_section", "it begins with `yon_rt_`"),
    ("Stream__recv", "it is the qualified name of a fun of the house Stream (Stream.recv)"),
    ("Wire__x", "it is the qualified name of a fun of the house Wire (Wire.x)"),
    ("Spawn__x", "it is the qualified name of a fun of the house Spawn (Spawn.x)"),
    ("Int64__gcd", "it is the qualified name of a fun of the house Int64 (Int64.gcd)"),
]


@pytest.mark.parametrize("name, why", _RESERVED, ids=[n for n, _ in _RESERVED])
def test_a_reserved_name_is_refused_where_it_is_declared(tmp_path, name, why):
    proj = _entry(tmp_path, f"  fun {name}(c: Number): Number {{ return c }}\n")
    r = subprocess.run([str(EMIT), str(proj)], capture_output=True, text=True, timeout=120)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "[E2025]" in out, out[-600:]
    assert f"the name `{name}` is reserved: {why}" in out, out[-600:]


def test_a_name_whose_head_is_no_house_is_legal(tmp_path):
    proj = _entry(tmp_path, "  fun a__b(c: Number): Number { return c + 1 }\n",
                  "  fun main: Number { return a__b(6) }\n")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True, text=True,
                       timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    assert subprocess.run([str(exe)], timeout=30).returncode == 7


@pytest.mark.parametrize("name", ["strlen", "malloc", "peek"])
def test_a_fun_of_the_program_is_a_local_symbol(tmp_path, name):
    """The fun is local (`t` in nm): it takes nothing from the system, which keeps its own; the
    program runs, prints with the system's strlen, and calls its own fun."""
    proj = _entry(tmp_path, f"  fun {name}(c: Number): Number {{ return c }}\n",
                  f'  fun main: Number visits Output {{ Output.print("hello")  return {name}(7) }}\n')
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True, text=True,
                       timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    run = subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)
    assert run.returncode == 7 and "hello" in run.stdout, (run.returncode, run.stdout, run.stderr)
    syms = subprocess.run(["nm", str(exe)], capture_output=True, text=True).stdout.splitlines()
    mine = [s for s in syms if s.endswith(f" _{name}") and s.split()[-2] in ("t", "T")]
    assert mine and all(s.split()[-2] == "t" for s in mine), mine
