"""The boundary between Spaces, as a matrix.

Every value that can move is carried across every boundary, and arrives
intact: what the receiving side reads out of it is what the sending side
put in. The boundaries are a call from main into another Space of the same
binary (the value as argument, the value as result), a call to a function
of another process (argument, result), and the element of a Wire<T> between
processes. A cell (a Space handle) and a closure have no meaning on the
other side: across each boundary they are refused with an E code.

The probes are not chosen case by case: a value or a boundary added to the
two tables below is tried against all the others, so a forgotten case has
nowhere to hide (the 1.8c hole was a place of the user's, never tried
between processes).

Each case: the sending side builds the value with BUILD, the receiving side
folds a number out of it with READ; the exit code is that number mod 256.
"""
from pathlib import Path
import os
import subprocess

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")


# the places every side declares, in Space w
_PLACES = {
    "Pt.yon": "place Pt { x Number  y Number }\n",
    "Note.yon": "place Note { message Text  line Number }\n",
    "Line.yon": "place Line { a Pt  b Note }\n",
    "Bag.yon": "place Bag { label Text  counts HashMap<Number, Number> }\n",
    "SyntaxError.yon": "place SyntaxError { this < Error  line Number }\n",
}

_FILL = """  mut m := {empty}
  mut k := 0
  iter {n} do {{
    m <- {set}
    k <- k + 1
  }}
  return m"""

# key: (type, BUILD (statements ending in a return), READ of `x`, exit)
VALUES = {
    "scalar": ("Number", "  return 42", "x", 42),
    # 2^62 + 1 has no f64: a value carried as a Number would come back as 2^62
    "int64": ("Int64", "  return Int64.two_to_62() + 1",
              "if x - Int64.two_to_62() == 1 then 42 else 1", 42),
    "text": ("Text", '  return "seven c"', "String.length(x)", 7),
    "list": ("List<Number>", "  return List.cons(1, List.cons(2, List.cons(3, List.empty(0))))",
             "List.head(x) * 100 + List.head(List.tail(x)) * 10 + List.length(x)", 123),
    "hashmap": ("HashMap<Number, Number>",
                _FILL.format(empty="HashMap.empty()", n=10, set="HashMap.set(m, k, k * 7)"),
                "HashMap.size(x) + (match HashMap.get(x, 9) { Found(v) => v, Absent => 0 })", 73),
    "hashset": ("HashSet<Number>",
                _FILL.format(empty="HashSet.empty()", n=12, set="HashSet.add(m, k * 2)"),
                "HashSet.size(x) + (if HashSet.contains(x, 22) then 100 else 0)"
                " + (if HashSet.contains(x, 23) then 50 else 0)", 112),
    "xrelmap": ("XRelMap<Number, Number>",
                _FILL.format(empty="XRelMap.empty()", n=10, set="XRelMap.set(m, k, k + 40)"),
                "XRelMap.size(x) + (match XRelMap.get(x, 5) { Found(v) => v, Absent => 0 })", 55),
    "xrelset": ("XRelSet<Number>",
                _FILL.format(empty="XRelSet.empty()", n=9, set="XRelSet.add(m, k)"),
                "XRelSet.size(x) + (if XRelSet.contains(x, 8) then 30 else 0)", 39),
    "place": ("Pt", "  return .-> Pt { x 4 y 2 }", "x.x * 10 + x.y", 42),
    "place_text": ("Note", '  return .-> Note { message "unexpected }" line 30 }',
                   "String.length(x.message) + x.line", 42),
    "nested": ("Line", "  p := .-> Pt { x 4 y 2 }\n"
                       '  n := .-> Note { message "abc" line 5 }\n'
                       "  return .-> Line { a p b n }",
               "x.a.x * 10 + x.a.y + String.length(x.b.message) + x.b.line", 50),
    "place_map": ("Bag", '  return .-> Bag { label "abc" counts HashMap.set(HashMap.empty(), 4, 40) }',
                  "String.length(x.label) + (match HashMap.get(x.counts, 4) "
                  "{ Found(v) => v, Absent => 0 })", 43),
    # a SyntaxError where an Error is expected: it crosses by its own frame
    "sub_object": ("Error", '  return .-> SyntaxError { message "unexpected }" line 30 }',
                   "String.length(x.message)", 12),
}

# what has no meaning on the other side: (type, the value made in place,
# the words of the refusal at each boundary). A cell cannot leave the
# function call that makes it, so a cell as the result of a remote function,
# or emitted by a producer, is refused there, before any boundary: the words
# say so.
_ACROSS = "another Space"
_WIRE = "the element of this wire"
_OUTLIVES = "outlive the call"
REFUSED = {
    "cell": ("Space", "Space.make(7)",
             {"bin_arg": _ACROSS, "bin_res": _OUTLIVES, "proc_arg": _ACROSS,
              "proc_res": _OUTLIVES, "wire": _OUTLIVES}),
    "closure": ("(Number -> Number)", "fun(y: Number) => y + 5",
                {"bin_arg": _ACROSS, "bin_res": _ACROSS, "proc_arg": _ACROSS,
                 "proc_res": _ACROSS, "wire": _WIRE}),
}

BOUNDARIES = ["bin_arg", "bin_res", "proc_arg", "proc_res", "wire"]

# the holes the matrix found (2026-10-23), each with the reason it closes
_HOLES = {}


def _cases(table):
    return [pytest.param(v, b, marks=pytest.mark.xfail(strict=True, reason=_HOLES[(v, b)]))
            if (v, b) in _HOLES else pytest.param(v, b)
            for v in table for b in BOUNDARIES]


def _yonc(src: Path, exe: Path):
    c = subprocess.run([str(YONC), str(src), "-o", str(exe)], capture_output=True,
                       text=True, timeout=180, cwd=str(exe.parent))
    return c.returncode, c.stdout + c.stderr


def _run(exe: Path, tag: str):
    env = dict(os.environ, YON_WORLD="%s%03x" % (tag, abs(hash(str(exe))) % 4096))
    r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=120,
                       cwd=str(exe.parent), env=env)
    return r.returncode, r.stderr


def _side(d: Path, name: str, spaces: str, objects: str):
    (d / "w").mkdir(parents=True)
    (d / "yon.toml").write_text(
        f'[package]\nname = "{name}"\n\n[runtime]\nbackend = "memory"\n\n'
        f'[world.W]\nobjects = [{objects}]\nspaces  = [{spaces}]\n')
    (d / "w" / "Topos.yon").write_text("topos WTopos where {\n}\n")
    for f, text in _PLACES.items():
        (d / "w" / f).write_text(text)


def _indent(body: str) -> str:
    return "\n".join("  " + line for line in body.splitlines())


def _in_binary(tmp: Path, boundary: str, ty: str, build: str, read: str, inline=None):
    """main (the root Space) and place Q in Space w, one binary. With
    `inline`, the value is that expression, made where it is handed over."""
    proj = tmp / "proj"
    _side(proj, "probe", '"w"', '"Q", "Pt", "Note", "Line", "Bag", "SyntaxError"')
    if boundary == "bin_arg":
        q = f"  fun digest(x: {ty}): Number {{ return {read} }}\n"
        main = f"  fun make(): {ty} {{\n{_indent(build)}\n  }}\n" \
               "  fun main(): Number { return Q.digest(make()) }\n"
        if inline:
            main = f"  fun main(): Number {{\n    v := {inline}\n    return Q.digest(v)\n  }}\n"
    else:
        q = f"  fun build(): {ty} {{\n{_indent(build)}\n  }}\n"
        main = f"  fun main(): Number {{\n    x := Q.build()\n    return {read}\n  }}\n"
    (proj / "w" / "Q.yon").write_text(f"place Q {{\n  side Number\n{q}}}\n")
    (proj / "Entry.yon").write_text(f"place Entry {{\n{main}}}\n")
    exe = tmp / "probe.exe"
    rc, out = _yonc(proj, exe)
    return rc, out, [exe]


def _between_processes(tmp: Path, boundary: str, ty: str, build: str, read: str, inline=None):
    """a server P (its own binary, P_srv) and a client that imports from it."""
    svc, cli = tmp / "svc", tmp / "cli"
    objects = '"X", "Pt", "Note", "Line", "Bag", "SyntaxError"'
    _side(svc, "svc", '"w"', objects)
    _side(cli, "cli", '"w", "P"', objects)
    build_fn = f"fun build(): {ty} {{\n{build}\n}}\n"
    if boundary == "proc_arg":
        exported = f"fun digest(x: {ty}): Number {{ return {read} }}\n"
        stub = f"fun digest(x: {ty}): Number {{ return 0 }}\n"
        imp = "digest"
        main = f"  fun make(): {ty} {{\n{_indent(build)}\n  }}\n" \
               "  fun main(): Number { return digest(make()) }\n"
        if inline:
            main = f"  fun main(): Number {{\n    v := {inline}\n    return digest(v)\n  }}\n"
    elif boundary == "proc_res":
        exported = stub = build_fn
        imp = "build"
        main = f"  fun main(): Number {{\n    x := build()\n    return {read}\n  }}\n"
    else:
        made = inline or "build()"
        exported = stub = (build_fn if not inline else "") + \
            f"fun items(): Wire<{ty}> {{\n  v := {made}\n" \
            "  s := produce {\n    emit v\n  }\n  return s\n}\n"
        imp = "items"
        main = ("  fun main(): Number {\n    w := wire to space P\n"
                "    sub := w.awaits(items)\n    s := sub.stream\n"
                f"    return s.fold(0, fun(a: Number, x: {ty}) => a + {read})\n  }}\n")
    (svc / "Entry.yon").write_text(
        "place Entry {\n" + _indent(exported) + "\n  fun main(): Number { return 0 }\n}\n")
    (cli / "yon_modules" / "prod").mkdir(parents=True)
    (cli / "yon_modules" / "prod" / "prod.yon").write_text(stub)
    (cli / "Entry.yon").write_text(f"import prod::{imp} from P\n\nplace Entry {{\n{main}}}\n")
    rc, out = _yonc(svc, tmp / "P_srv")
    if rc != 0:
        return rc, out, []
    exe = tmp / "client.exe"
    rc, out = _yonc(cli, exe)
    return rc, out, [exe]


def _case(tmp: Path, boundary: str, ty: str, build: str, read: str, inline=None):
    if boundary.startswith("bin_"):
        return _in_binary(tmp, boundary, ty, build, read, inline)
    return _between_processes(tmp, boundary, ty, build, read, inline)


@pytest.mark.parametrize("value,boundary", _cases(VALUES))
def test_a_value_arrives_intact(tmp_path, value, boundary):
    ty, build, read, want = VALUES[value]
    rc, out, exes = _case(tmp_path, boundary, ty, build, read)
    assert rc == 0, out
    got, err = _run(exes[0], "m")
    assert got == want % 256, (got, err)


@pytest.mark.parametrize("value,boundary", _cases(REFUSED))
def test_what_has_no_meaning_on_the_other_side_is_refused(tmp_path, value, boundary):
    ty, made, words = REFUSED[value]
    # the receiving side reads nothing: the refusal is the crossing's alone
    rc, out, _ = _case(tmp_path, boundary, ty, f"  return {made}", "0", inline=made)
    assert (rc != 0 and "[E" in out and "Fatal error: exception" not in out
            and words[boundary] in out), out
