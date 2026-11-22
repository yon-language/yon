"""A variable is not generalized: one variable holds values of one type.

`mut r := List.empty` fixes the type of r at its first write: a variable that held a List<Number>
and then a List<Text> would be the polymorphic box of Landin and of ML's value restriction (Harper
ch. 34; Turbak §13.5), through which a value is read at a type it was not written at. The second
write of another type is refused; two writes of one type are accepted. The read of a variable is
not pure either: an index of a type does not read it (test_soundness_probes, E2021).
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"

pytestmark = pytest.mark.skipif(not EMIT.exists(), reason="frontend not built")


def _emit(tmp_path, second):
    (tmp_path / "yon.toml").write_text('[package]\nname = "box"\n\n[runtime]\nbackend = "memory"\n')
    (tmp_path / "Entry.yon").write_text(
        "place Entry {\n  fun main: Number {\n    mut r := List.empty\n"
        "    r <- List.cons(1, List.empty)\n    r <- List.cons(" + second + ", List.empty)\n"
        "    return 7\n  }\n}\n")
    r = subprocess.run([str(EMIT), str(tmp_path)], capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout + r.stderr


def test_a_variable_holds_values_of_one_type(tmp_path):
    rc, out = _emit(tmp_path, "2")
    assert rc == 0, out[-600:]


def test_a_variable_does_not_take_a_second_type(tmp_path):
    rc, out = _emit(tmp_path, '"a"')
    assert rc != 0 and "[E2001]" in out, out[-600:]
    assert "type mismatch: expected List<Number>, got List<Text>" in out, out[-600:]
