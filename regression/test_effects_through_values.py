"""The effect of a call through a function value.

A fun that calls its parameter visits what the function it is handed visits. The rule chosen for
it (the union of the funs named as a value, one rule for the effects, the allocation of a heap, the
termination and the mobility) is not yet the rule of the effects: there a call through a value adds
nothing, so a fun named as a value that writes on Output is called by a caller that does not declare
Output, and the program prints. Applied to the effects as it stands, the union reaches the funs of
the prelude that call a parameter (List.map, List.filter, List.fold_left, Land.witness), which declare
no effect: then a program that declares every effect it visits is refused as well. The effect of a
call through a value is the effect inferred in the arrow, with variables of effect for the higher
order (the effect of List.map(f, xs) is that of f): the lot of the program graph.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"

pytestmark = pytest.mark.skipif(not EMIT.exists(), reason="the frontend is not built")

_TOML = '[package]\nname = "effects"\n\n[runtime]\nbackend = "memory"\n'

_ANNOUNCE = '  fun announce(n: Number): Number visits Output { _u := Output.print("hi")  return n }\n'


def _emit(tmp_path, entry):
    (tmp_path / "yon.toml").write_text(_TOML)
    (tmp_path / "Entry.yon").write_text(entry)
    r = subprocess.run([str(EMIT), str(tmp_path)], capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout + r.stderr


@pytest.mark.xfail(strict=True, reason="a call through a function value adds no effect: apply(announce) "
                   "prints with no `visits Output` in main; the union of the funs named as a value "
                   "reaches the funs of the prelude that call a parameter, which declare no effect "
                   "(the effect in the arrow, with variables of effect: the lot of the program graph)")
def test_an_effect_through_a_named_function_value_must_be_declared(tmp_path):
    rc, out = _emit(tmp_path, "place Entry {\n" + _ANNOUNCE +
                    "  fun apply(g: Number -> Number): Number { return g(41) }\n"
                    "  fun main: Number { return apply(announce) + 1 }\n}\n")
    assert rc != 0 and "[E2001]" in out, out[-600:]
    assert "function 'apply' visits effect 'Output', but the caller does not declare it" in out, out[-600:]


def test_an_effect_through_a_named_function_value_declared_on_the_chain_compiles(tmp_path):
    """The twin: apply and main declare Output, the program compiles."""
    rc, out = _emit(tmp_path, "place Entry {\n" + _ANNOUNCE +
                    "  fun apply(g: Number -> Number): Number visits Output { return g(41) }\n"
                    "  fun main: Number visits Output { return apply(announce) + 1 }\n}\n")
    assert rc == 0, out[-600:]
