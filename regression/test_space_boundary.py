"""The boundary between Spaces is the wire.

What crosses from one Space to another is what the wire can carry, and
nothing else: a call from a function of one Space into a function of another
Space of the same program, a call to a function imported from another
process, a value sent on a wire, the element of a producer's wire. A
closure, a cell or a region handle has no meaning in the other Space, so
handing one over is a type error, whatever it carries. A call between
processes is checked on the types of the remote signature, not on the count
of its arguments, and carries its arguments and its result by their type, as
the wire does; the two sides compare their signature roots, so a caller and
a server built from different versions of a signature never exchange a call.
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
    mut m := HashMap.empty()
    mut k := 0
    iter n do {
      m <- HashMap.set(m, k, k * 100)
      k <- k + 1
    }
    return m
  }
  fun apply(f: Number -> Number, x: Number): Number { return f(x) }
  fun adder(n: Number): Number -> Number { return fun(x: Number) => x + n }
  fun peek(c: Space): Number { return Space.get(c) }
  fun points(n: Number): XRelMap<Number, Number> {
    mut m := XRelMap.empty()
    mut k := 0
    iter n do {
      m <- XRelMap.set(m, k, k + 40)
      k <- k + 1
    }
    return m
  }
  fun len(s: String): Number { return String.length(s) }
  fun flow(): Wire<Number> {
    s := produce {
      emit 1
    }
    return s
  }
}
"""

_READ_MAP = """place Entry {
  fun main(): Number {
    mut m := Q.build(10)
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


def test_an_xrelmap_made_in_another_space_is_copied_to_main(tmp_path):
    rc, out, exe = _in_binary(tmp_path, """place Entry {
  fun main(): Number {
    mut m := Q.points(6)
    return XRelMap.size(m) + (match XRelMap.get(m, 5) { Found(v) => v, Absent => 0 })
  }
}
""")
    assert rc == 0, out
    assert subprocess.run([str(exe)], capture_output=True, timeout=60).returncode == 51


def test_a_text_crosses_into_another_space(tmp_path):
    rc, out, exe = _in_binary(tmp_path, """place Entry {
  fun main(): Number { return Q.len("seven c") }
}
""")
    assert rc == 0, out
    assert subprocess.run([str(exe)], capture_output=True, timeout=60).returncode == 7


def test_a_channel_does_not_cross_and_the_error_says_subscribe(tmp_path):
    rc, out, _ = _in_binary(tmp_path, """place Entry {
  fun main(): Number {
    s := Q.flow()
    return 0
  }
}
""")
    assert _refused(rc, out, "the result of Q__flow", "subscribe"), out


def test_a_closure_does_not_cross_into_another_space(tmp_path):
    rc, out, _ = _in_binary(tmp_path, """place Entry {
  fun main(): Number {
    mut k := 5
    return Q.apply(fun(x: Number) => x + k, 1)
  }
}
""")
    assert _refused(rc, out, "another Space", "Q__apply"), out


def test_a_closure_does_not_come_back_from_another_space(tmp_path):
    rc, out, _ = _in_binary(tmp_path, """place Entry {
  fun main(): Number {
    f := Q.adder(3)
    return 0
  }
}
""")
    assert _refused(rc, out, "the result of Q__adder", "another Space"), out


def test_a_cell_does_not_cross_into_another_space(tmp_path):
    rc, out, _ = _in_binary(tmp_path, """place Entry {
  fun main(): Number {
    c := Space.make(7)
    return Q.peek(c)
  }
}
""")
    assert _refused(rc, out, "Q__peek", "another Space"), out


@pytest.mark.parametrize("params,args", [("", ""), ("k: Number", "0")])
def test_a_closure_returned_inside_one_space_is_a_value(tmp_path, params, args):
    # the control of the refusals above: what may not cross a Space is an
    # ordinary value inside one
    exe = tmp_path / "probe.exe"
    src = tmp_path / "one"
    src.mkdir()
    (src / "yon.toml").write_text('[package]\nname = "one"\n[runtime]\nbackend = "memory"\n')
    (src / "Entry.yon").write_text(f"""place Entry {{
  fun build({params}): Number -> Number {{ return fun(y: Number) => y + 41 }}
  fun main(): Number {{
    f := build({args})
    return f(1)
  }}
}}
""")
    rc, out = _yonc(src, exe)
    assert rc == 0, out
    assert subprocess.run([str(exe)], timeout=60).returncode == 42


def test_a_call_inside_one_space_is_not_a_crossing(tmp_path):
    # the same closure handed within Q's own Space is an ordinary call
    proj = _project(tmp_path, """place Entry {
  fun main(): Number { return Q.inside(4) }
}
""")
    (proj / "w" / "Q.yon").write_text(_BUILD.replace(
        "  fun peek(c: Space)",
        "  fun inside(x: Number): Number { mut k := 1\n"
        "    return Q.apply(fun(y: Number) => y + k, x) }\n"
        "  fun peek(c: Space)"))
    exe = tmp_path / "probe.exe"
    rc, out = _yonc(proj, exe)
    assert rc == 0, out
    assert subprocess.run([str(exe)], timeout=60).returncode == 5


# ---- a place made by the caller crosses into another Space of the binary ----

_NOTE_TOML = _TOML.replace('objects = ["Q"]', 'objects = ["Note"]')


def _note_project(tmp_path: Path, space_file: str, entry: str) -> Path:
    proj = tmp_path / "proj"
    (proj / "w").mkdir(parents=True)
    (proj / "yon.toml").write_text(_NOTE_TOML)
    (proj / "w" / "Topos.yon").write_text("topos WTopos where {\n}\n")
    name, text = space_file
    (proj / "w" / name).write_text(text)
    (proj / "Entry.yon").write_text(entry)
    return proj


_NOTE_ENTRY = """place Entry { }
fun main(): Number {
  s := .-> %s { message "unexpected }" line 30 }
  d := describe(s)
  return d + s.line
}
"""


def test_a_place_with_a_text_crosses_into_another_space_and_stays_the_callers(tmp_path):
    # the section main makes lives in main's heaps: before, `.-> Note` was
    # pinned to the Space of Note, and the region ending the call into that
    # Space emptied it under main (the read of s.line aborted)
    proj = _note_project(tmp_path, ("Note.yon",
        "place Note { message Text  line Number }\n\n"
        "fun describe(e: Note): Number { return String.length(e.message) }\n"),
        _NOTE_ENTRY % "Note")
    exe = tmp_path / "probe.exe"
    rc, out = _yonc(proj, exe)
    assert rc == 0, out
    assert subprocess.run([str(exe)], timeout=60).returncode == 42   # 12 + 30


def test_a_sub_object_crosses_by_its_own_frame(tmp_path):
    # describe takes the prelude's Error; the value is a SyntaxError, copied
    # by its own frame (the frame of Error does not describe it)
    proj = _note_project(tmp_path, ("SyntaxError.yon",
        "place SyntaxError { this < Error  line Number }\n\n"
        "fun describe(e: Error): Number { return String.length(e.message) }\n"),
        _NOTE_ENTRY % "SyntaxError")
    (proj / "yon.toml").write_text(_TOML.replace('objects = ["Q"]', 'objects = ["SyntaxError"]'))
    exe = tmp_path / "probe.exe"
    rc, out = _yonc(proj, exe)
    assert rc == 0, out
    assert subprocess.run([str(exe)], timeout=60).returncode == 42


# ---- two processes ----

_ECHO = """place Entry {
  fun slen(s: String): Number { return String.length(s) }
  fun twice(x: Number): Number { return x * 2 }
  fun build(n: Number): HashMap<Number, Number> {
    mut m := HashMap.empty()
    mut k := 0
    iter n do {
      m <- HashMap.set(m, k, k * 100)
      k <- k + 1
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


def test_a_call_to_another_version_of_the_signature_is_refused(tmp_path):
    # the server is built from echo.yon; the caller then sees a twice that
    # gives an Int64: same name and arity, another result type
    (tmp_path / "echo.yon").write_text(_ECHO)
    rc, out = _yonc(tmp_path / "echo.yon", tmp_path / "Echo_srv")
    assert rc == 0, out
    (tmp_path / "echo.yon").write_text(_ECHO.replace(
        "fun twice(x: Number): Number", "fun twice(x: Number): Int64"))
    (tmp_path / "client.yon").write_text("""import echo::twice from Echo

place Entry {
  fun main(): Number {
    r := twice(21)
    return 0
  }
}
""")
    rc, out = _yonc(tmp_path / "client.yon", tmp_path / "client")
    assert rc == 0, out
    env = dict(os.environ, YON_WORLD="v%03x" % (os.getpid() % 4096))
    r = subprocess.run([str(tmp_path / "client")], capture_output=True, text=True,
                       timeout=60, cwd=str(tmp_path), env=env)
    assert r.returncode == 3, (r.returncode, r.stderr)
    assert "cross-Space call refused" in r.stderr, r.stderr


def test_a_number_still_crosses_between_processes(tmp_path):
    rc, out = _between_processes(tmp_path, """import echo::twice from Echo

place Entry {
  fun main(): Number { return twice(21) }
}
""")
    assert rc == 0, out
    assert _run_client(tmp_path) == 42


def test_a_text_crosses_between_processes(tmp_path):
    rc, out = _between_processes(tmp_path, """import echo::slen from Echo

place Entry {
  fun main(): Number { return slen("hello") }
}
""")
    assert rc == 0, out
    assert _run_client(tmp_path) == 5


def test_a_map_crosses_between_processes(tmp_path):
    rc, out = _between_processes(tmp_path, """import echo::build from Echo

place Entry {
  fun main(): Number {
    mut m := build(10)
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


# ---- a place with a Text between processes ----

_NOTES_TOML = """[package]
name = "%s"

[runtime]
backend = "memory"

[world.W]
objects = ["X"]
spaces  = %s
"""


def test_a_place_with_a_text_crosses_between_processes(tmp_path):
    # the server's dispatch table admits an operation whose parameter is a
    # place: the frame is rebuilt in its heaps and the handle is passed
    for p, spaces in (("svc", '["w"]'), ("client", '["w", "Notes"]')):
        (tmp_path / p / "w").mkdir(parents=True)
        (tmp_path / p / "yon.toml").write_text(_NOTES_TOML % (p, spaces))
        (tmp_path / p / "w" / "Topos.yon").write_text("topos WTopos where {\n}\n")
        (tmp_path / p / "w" / "Note.yon").write_text("place Note { message Text  line Number }\n")
    (tmp_path / "svc" / "Entry.yon").write_text(
        "place Entry {\n  fun describe(e: Note): Number { return String.length(e.message) + e.line }\n"
        "  fun main(): Number { return 0 }\n}\n")
    mods = tmp_path / "client" / "yon_modules" / "notes"
    mods.mkdir(parents=True)
    (mods / "notes.yon").write_text("fun describe(e: Note): Number { return 0 }\n")
    (tmp_path / "client" / "Entry.yon").write_text(
        "import notes::describe from Notes\n\nplace Entry {\n  fun main(): Number {\n"
        "    n := .-> Note { message \"unexpected }\" line 30 }\n"
        "    return describe(n)\n  }\n}\n")
    rc, out = _yonc(tmp_path / "svc", tmp_path / "Notes_srv")
    assert rc == 0, out
    rc, out = _yonc(tmp_path / "client", tmp_path / "client.exe")
    assert rc == 0, out
    env = dict(os.environ, YON_WORLD="n%03x" % (os.getpid() % 4096))
    r = subprocess.run([str(tmp_path / "client.exe")], capture_output=True, timeout=60,
                       cwd=str(tmp_path), env=env)
    assert r.returncode == 42, r.stderr
