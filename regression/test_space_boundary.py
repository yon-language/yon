"""The boundary between Spaces is the wire.

What crosses from one Space to another is what the wire can carry, and
nothing else: a call from a function of one Space into a function of another
Space of the same program, a call to a function imported from another
process, a value sent on a wire, the element of a producer's wire. A
closure, a cell or a region handle has no meaning in the other Space, so
handing one over is a type error, whatever it carries. A call between
processes is checked on the types of the remote signature, not on the count
of its arguments; what such a call cannot carry yet is refused, never
delivered as a number that means nothing.
"""
from pathlib import Path
import os
import subprocess

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_TOML = """[package]
name = "probe"

[world.W]
objects = ["Q"]
spaces  = ["w"]

[runtime]
backend = "memory"
"""

_BUILD = """place Q {
  side Number
  fun build(n: Number): HashMap<Number, Number> {
    be m := HashMap.empty()
    be k := 0
    iter n do {
      m = HashMap.set(m, k, k * 100)
      k = k + 1
    }
    return m
  }
  fun apply(f: Number -> Number, x: Number): Number { return f(x) }
  fun adder(n: Number): Number -> Number { return fun(x: Number) => x + n }
  fun peek(c: Space): Number { return Space.get(c) }
}
"""

_READ_MAP = """place Entry {
  fun main(): Number {
    be m := Q.build(10)
    return HashMap.size(m) + (match HashMap.get(m, 3) { Found(v) => v, Absent => 0 })
  }
}
"""


def _project(tmp_path: Path, entry: str) -> Path:
    proj = tmp_path / "proj"
    (proj / "w").mkdir(parents=True)
    (proj / "yon.toml").write_text(_TOML)
    (proj / "w" / "Topos.yon").write_text("topos WT where {\n}\n")
    (proj / "w" / "Q.yon").write_text(_BUILD)
    (proj / "Entry.yon").write_text(entry)
    return proj


def _yonc(src: Path, exe: Path):
    c = subprocess.run([str(YONC), str(src), "-o", str(exe)], capture_output=True,
                       text=True, timeout=180, cwd=str(exe.parent))
    return c.returncode, c.stdout + c.stderr


def _refused(rc: int, out: str, *words: str) -> bool:
    return (rc != 0 and "[E" in out and "Fatal error: exception" not in out
            and all(w in out for w in words))


def _in_binary(tmp_path: Path, entry: str):
    exe = tmp_path / "probe.exe"
    return _yonc(_project(tmp_path, entry), exe) + (exe,)


# ---- one binary, two Spaces ----

def test_a_map_built_in_another_space_reaches_main(tmp_path):
    rc, out, exe = _in_binary(tmp_path, _READ_MAP)
    assert rc == 0, out
    r = subprocess.run([str(exe)], capture_output=True, timeout=60)
    assert r.returncode == 54   # 10 entries + the value at 3, 300; mod 256


def test_a_closure_does_not_cross_into_another_space(tmp_path):
    rc, out, _ = _in_binary(tmp_path, """place Entry {
  fun main(): Number {
    be k := 5
    return Q.apply(fun(x: Number) => x + k, 1)
  }
}
""")
    assert _refused(rc, out, "another Space", "Q__apply"), out


def test_a_closure_does_not_come_back_from_another_space(tmp_path):
    rc, out, _ = _in_binary(tmp_path, """place Entry {
  fun main(): Number {
    be f := Q.adder(3)
    return 0
  }
}
""")
    assert _refused(rc, out, "the result of Q__adder", "another Space"), out


def test_a_cell_does_not_cross_into_another_space(tmp_path):
    rc, out, _ = _in_binary(tmp_path, """place Entry {
  fun main(): Number {
    be c := Space.make(7)
    return Q.peek(c)
  }
}
""")
    assert _refused(rc, out, "Q__peek", "another Space"), out


def test_a_call_inside_one_space_is_not_a_crossing(tmp_path):
    # the same closure handed within Q's own Space is an ordinary call
    proj = _project(tmp_path, """place Entry {
  fun main(): Number { return Q.inside(4) }
}
""")
    (proj / "w" / "Q.yon").write_text(_BUILD.replace(
        "  fun peek(c: Space)",
        "  fun inside(x: Number): Number { be k := 1\n"
        "    return Q.apply(fun(y: Number) => y + k, x) }\n"
        "  fun peek(c: Space)"))
    exe = tmp_path / "probe.exe"
    rc, out = _yonc(proj, exe)
    assert rc == 0, out
    assert subprocess.run([str(exe)], timeout=60).returncode == 5


# ---- two processes ----

_ECHO = """place Entry {
  fun slen(s: String): Number { return String.length(s) }
  fun twice(x: Number): Number { return x * 2 }
  fun build(n: Number): HashMap<Number, Number> {
    be m := HashMap.empty()
    be k := 0
    iter n do {
      m = HashMap.set(m, k, k * 100)
      k = k + 1
    }
    return m
  }
  fun main(): Number { return 0 }
}
"""


def _between_processes(tmp_path: Path, client: str):
    (tmp_path / "echo.yon").write_text(_ECHO)
    (tmp_path / "client.yon").write_text(client)
    rc, out = _yonc(tmp_path / "echo.yon", tmp_path / "Echo_srv")
    assert rc == 0, out
    rc, out = _yonc(tmp_path / "client.yon", tmp_path / "client")
    return rc, out


def _run_client(tmp_path: Path) -> int:
    env = dict(os.environ, YON_WORLD="b%03x" % (os.getpid() % 4096))
    r = subprocess.run([str(tmp_path / "client")], capture_output=True, timeout=60,
                       cwd=str(tmp_path), env=env)
    return r.returncode


def test_an_import_is_checked_on_its_types(tmp_path):
    rc, out = _between_processes(tmp_path, """import echo::twice from Echo

place Entry {
  fun main(): Number { return twice("a") }
}
""")
    assert _refused(rc, out, "argument 1 of twice"), out


def test_a_number_still_crosses_between_processes(tmp_path):
    rc, out = _between_processes(tmp_path, """import echo::twice from Echo

place Entry {
  fun main(): Number { return twice(21) }
}
""")
    assert rc == 0, out
    assert _run_client(tmp_path) == 42


def test_a_text_is_refused_while_calls_carry_numbers_only(tmp_path):
    # never delivered as a number: refused until the call carries the frame
    rc, out = _between_processes(tmp_path, """import echo::slen from Echo

place Entry {
  fun main(): Number { return slen("hello") }
}
""")
    assert _refused(rc, out, "argument 1 of slen", "another process"), out


@pytest.mark.xfail(strict=True, reason="calls between processes carry numbers only")
def test_a_text_crosses_between_processes(tmp_path):
    rc, out = _between_processes(tmp_path, """import echo::slen from Echo

place Entry {
  fun main(): Number { return slen("hello") }
}
""")
    assert rc == 0, out
    assert _run_client(tmp_path) == 5


@pytest.mark.xfail(strict=True, reason="calls between processes carry numbers only")
def test_a_map_crosses_between_processes(tmp_path):
    rc, out = _between_processes(tmp_path, """import echo::build from Echo

place Entry {
  fun main(): Number {
    be m := build(10)
    return HashMap.size(m) + (match HashMap.get(m, 3) { Found(v) => v, Absent => 0 })
  }
}
""")
    assert rc == 0, out
    assert _run_client(tmp_path) == 54


# ---- the element of a wire ----

def _producer(tmp_path: Path, elem: str, value: str):
    src = tmp_path / "prod.yon"
    src.write_text("""place Entry {
  fun readings(): Wire<%s> {
    return produce {
      emit %s
    }
  }
  fun main(): Number { return 0 }
}
""" % (elem, value))
    return _yonc(src, tmp_path / "prod")


def test_a_wire_of_closures_is_refused(tmp_path):
    rc, out = _producer(tmp_path, "(Number -> Number)", "fun(x: Number) => x")
    assert _refused(rc, out, "the element of this wire"), out


def test_a_wire_of_text_is_accepted(tmp_path):
    rc, out = _producer(tmp_path, "String", "\"a\"")
    assert rc == 0, out


def test_a_wire_of_a_coproduct_is_refused(tmp_path):
    # Lookup<Number> is Found(v) | Absent: the wire has no frame for an arm
    rc, out = _producer(tmp_path, "Lookup<Number>", "Found(1)")
    assert _refused(rc, out, "the element of this wire"), out


def test_a_wire_of_numbers_is_accepted(tmp_path):
    rc, out = _producer(tmp_path, "Number", "1")
    assert rc == 0, out
