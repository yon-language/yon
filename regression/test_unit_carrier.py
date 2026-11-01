"""A fun answering 1 is found by its call wherever it is defined.

The return of a fun is announced, for the calls compiled before its body,
by the one function that gives a type its carrier; the carrier of 1 is the
f64 of the uniform slot every value has at a call, which is what the body of
such a fun returns, so the announcement and the body agree.

Layer/kind: native / end-to-end.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")


def _run(tmp_path: Path, entry: str):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text('[package]\nname = "probe"\n\n[runtime]\nbackend = "memory"\n')
    (proj / "Entry.yon").write_text(entry)
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True,
                       text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    return subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)


@pytest.mark.parametrize("order", ["callee after", "callee before"])
def test_a_fun_answering_one_is_called_wherever_it_is_defined(tmp_path, order):
    outer = "fun outer(): Unit { return say(41) }\n"
    say = ("fun say(n: Number): Unit {\n"
           "  _ := if n == 41 then SystemOs.write_output(\"ok\\n\")\n"
           "       else SystemOs.write_output(\"bad\\n\")\n"
           "  return star\n"
           "}\n")
    funs = outer + say if order == "callee after" else say + outer
    r = _run(tmp_path, ("place Entry {\n"
                        "fun main(): Number {\n  _ := outer()\n  return 42\n}\n"
                        + funs + "}\n"))
    assert r.returncode == 42, r.stderr
    assert r.stdout.count("ok") == 1, r.stdout
