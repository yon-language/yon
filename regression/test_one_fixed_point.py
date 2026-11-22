"""The facts over the calls are one fixed point, on the condensation of the graph, with no bound.

The effects a fun visits, the Spaces a fun reaches (the drop check) and the terminations of the
size-change gate grow by union along the calls: their least fixed point is one pass over the
strongly connected components, callees first (frontend/call_graph.ml). So a long chain gives the
same verdict as a short one, a recursive group the same verdict whatever its names, and a call
through a function value reaches every fun the program names as a value (the termination and the
Spaces; for the effects, the question is Antonio's). A reducer that keeps a bound refuses past it
where its answer decides (E2022), and keeps the term where it only computes ahead of the run time.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_MEMORY = '[package]\nname = "fp"\n\n[runtime]\nbackend = "memory"\n'


def _emit(proj):
    r = subprocess.run([str(EMIT), str(proj)], capture_output=True, text=True, timeout=300)
    return r.returncode, r.stdout + r.stderr


def _chain(n):
    body = ["place Entry {", "  fun main: Number { return f1(1) }"]
    body += [f"  fun f{i}(x: Number): Number {{ return f{i + 1}(x) }}" for i in range(1, n)]
    body += [f'  fun f{n}(x: Number): Number visits Output {{ Output.print("hi")  return x }}', "}"]
    return "\n".join(body) + "\n"


@pytest.mark.parametrize("n", [3, 101, 150, 300])
def test_an_effect_at_the_end_of_a_chain_reaches_its_head(tmp_path, n):
    """The effect of the last fun reaches the first, however long the chain: the refusal names f1,
    the call main makes (with a bound of 100 rounds it named f50 at 150)."""
    (tmp_path / "yon.toml").write_text(_MEMORY)
    (tmp_path / "Entry.yon").write_text(_chain(n))
    rc, out = _emit(tmp_path)
    assert rc != 0 and "[E2001]" in out, out[-600:]
    assert "function 'f1' visits effect 'Output', but the caller does not declare it" in out, out[-600:]


_DROP_TOML = ('[package]\nname = "drop_names"\n\n[runtime]\nbackend = "separate"\n\n'
              '[world.W]\nobjects = ["X"]\nspaces  = ["D"]\n')
_DP = "place DP { n Number }\n  fun d_op(x: Number): Number { return x + 1 }\n"


def _drop_project(tmp_path, funs, first):
    (tmp_path / "yon.toml").write_text(_DROP_TOML)
    (tmp_path / "D").mkdir()
    (tmp_path / "D" / "Topos.yon").write_text("topos T where { }\n")
    (tmp_path / "D" / "DP.yon").write_text(_DP)
    (tmp_path / "Entry.yon").write_text(
        "import svc::d_op from D\nplace Entry { }\n" + funs +
        f"fun main(): Number {{\n  drop D\n  r := {first}(2)\n  return r - r\n}}\n")
    return tmp_path


_PAIRS = [("up", "down"), ("p1", "p2"), ("a", "b"), ("b", "a"), ("x", "y"), ("y", "x"),
          ("zeta", "alpha"), ("alpha", "zeta"), ("m", "n")]


@pytest.mark.parametrize("one, two", _PAIRS, ids=[f"{a}-{b}" for a, b in _PAIRS])
def test_a_drop_before_a_recursive_group_that_reaches_the_space_is_refused(tmp_path, one, two):
    """The arcs of a recursive group are the union over the group, whatever the names: the order
    of the visit no longer decides the verdict (before, `up`/`down` compiled and the others did not)."""
    funs = (f"fun {one}(n: Number): Number {{ return if n > 0 then {two}(n - 1) else 0 }}\n"
            f"fun {two}(n: Number): Number {{ r := d_op(9)  return if n > 0 then {one}(n - 1) else r }}\n")
    rc, out = _emit(_drop_project(tmp_path, funs, one))
    assert rc != 0 and "DROP ERROR [E3001]" in out, out[-600:]
    assert "cannot drop Space D" in out and "is still reachable downstream" in out, out[-600:]


def test_a_drop_before_a_cycle_of_three_is_refused(tmp_path):
    funs = ("fun p1(n: Number): Number { return if n > 0 then p2(n - 1) else 0 }\n"
            "fun p2(n: Number): Number { return if n > 0 then p3(n - 1) else 0 }\n"
            "fun p3(n: Number): Number { r := d_op(9)  return if n > 0 then p1(n - 1) else r }\n")
    rc, out = _emit(_drop_project(tmp_path, funs, "p1"))
    assert rc != 0 and "DROP ERROR [E3001]" in out and "cannot drop Space D" in out, out[-600:]


def test_a_drop_before_a_group_that_does_not_reach_the_space_is_legal(tmp_path):
    funs = ("fun up(n: Number): Number { return if n > 0 then down(n - 1) else 0 }\n"
            "fun down(n: Number): Number { return if n > 0 then up(n - 1) else 7 }\n")
    rc, out = _emit(_drop_project(tmp_path, funs, "up"))
    assert rc == 0, out[-600:]


def _concats(n):
    e = "refl(4)"
    for _ in range(n):
        e = f"concat({e}, refl(4))"
    return "place Entry {\n  fun j: 4 = 4 { return " + e + " }\n  fun main: Number { q := j  return q @ I0 }\n}\n"


def test_a_computation_of_the_emitter_past_the_bound_keeps_its_term(tmp_path):
    """Where the reducer only computes ahead of the run time (the emitter), a term that still
    reduces after the bound is the same value, not yet computed: 1100 composites (two steps each)
    compile, and the program computes 4. Where the answer decides (a conversion, the code of an El,
    a sheaf), the bound is a refusal, E2022 (frontend/test_builtins.ml)."""
    (tmp_path / "yon.toml").write_text(_MEMORY)
    (tmp_path / "Entry.yon").write_text(_concats(1100))
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(tmp_path), "-o", str(exe)], capture_output=True, text=True,
                       timeout=300)
    assert r.returncode == 0, (r.stdout + r.stderr)[-600:]
    assert subprocess.run([str(exe)], timeout=30).returncode == 4
