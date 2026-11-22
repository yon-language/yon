"""Empty is the initial object, not the terminal one: Hom(Empty, X) has one map, Hom(A, Empty) none.

meta/kernel/Empty.yon declares `place Empty { this > nessuno Empty }`: its only arm needs a point of
itself, so it has no point. The checker does not take it for the terminal object (which absorbs a
pure value of any type, like Unit): a Number where an Empty is wanted is refused; two maps out of
Empty, which no point tells apart, are both accepted.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"

pytestmark = pytest.mark.skipif(not EMIT.exists(), reason="frontend not built")

_TOML = ('[package]\nname = "empty"\n\n[world.W]\nobjects = ["Empty"]\nspaces = ["w"]\n\n'
         '[runtime]\nbackend = "memory"\n')


def _emit(tmp_path, entry):
    (tmp_path / "yon.toml").write_text(_TOML)
    (tmp_path / "w").mkdir()
    (tmp_path / "w" / "Empty.yon").write_text((ROOT / "meta" / "kernel" / "Empty.yon").read_text())
    (tmp_path / "w" / "Topos.yon").write_text("topos WTopos where {\n}\n")
    (tmp_path / "Entry.yon").write_text(entry)
    r = subprocess.run([str(EMIT), str(tmp_path)], capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout + r.stderr


@pytest.mark.parametrize("value, ty", [("x", "Number"), ('"hello"', "Text")])
def test_no_map_into_empty_from_an_inhabited_type(tmp_path, value, ty):
    rc, out = _emit(tmp_path, "place Entry {\n  fun f(x: Number): Empty { return " + value + " }\n"
                              "  fun main: Number { return 7 }\n}\n")
    assert rc != 0 and "[E2001]" in out, out[-600:]
    assert f"type mismatch: expected Empty, got {ty}" in out, out[-600:]


def test_maps_out_of_empty_are_accepted(tmp_path):
    rc, out = _emit(tmp_path, "place Entry {\n  fun f(e: Empty): Number { return 1 }\n"
                              "  fun g(e: Empty): Number { return 2 }\n"
                              "  fun main: Number { return 7 }\n}\n")
    assert rc == 0, out[-600:]


def test_a_pure_value_of_any_type_is_absorbed_by_the_terminal_unit(tmp_path):
    """The contrast: Unit is terminal, the map A -> Unit is the unique one."""
    rc, out = _emit(tmp_path, "place Entry {\n  fun f(x: Number): Unit { return x }\n"
                              "  fun main: Number { return 7 }\n}\n")
    assert rc == 0, out[-600:]
