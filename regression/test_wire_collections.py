"""The wire carries collections.

A value crosses between processes as a frame typed by its type root: a
number as itself, a string by its bytes, a place by its fields, a list, a
HashMap, a HashSet, an XRelMap or an XRelSet by its elements (their values
too). The receiver rebuilds it in its own heaps as a persistent collection,
with the same set and add a program would call, so what arrives answers
size, has and get like what left. A message longer than the 64 KB ring
crosses in pieces.

Each probe: a producer Space `P` (its own binary, P_srv) emits one value on
a Wire<T>; the consumer subscribes, drains the stream and folds a number
out of what arrived; the exit code is that number mod 256.
"""
from pathlib import Path
import os
import subprocess

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")


def _cross(tmp_path: Path, decls: str, elem: str, build: str, read: str) -> int:
    """decls: places both sides declare; build: the producer's value; read:
    the consumer's number from `x` (the arrived value)."""
    (tmp_path / "prod.yon").write_text(f"""{decls}
fun value(): {elem} {{
{build}
}}
fun items(): Wire<{elem}> {{
  be v := value()
  be s := produce {{
    emit v
  }}
  return s
}}
fun main(): Number {{ return 0 }}
""")
    (tmp_path / "cons.yon").write_text(f"""import prod::items from P
{decls}
fun main(): Number {{
  be w := wire to space P
  be sub := w.awaits(items)
  be s := sub.stream
  return s.fold(0, fun(a: Number, x: {elem}) => a + {read})
}}
""")
    for src, exe in (("prod.yon", "P_srv"), ("cons.yon", "cons")):
        c = subprocess.run([str(YONC), src, "-o", exe], cwd=str(tmp_path),
                           capture_output=True, text=True, timeout=180)
        assert c.returncode == 0, c.stdout + c.stderr
    env = dict(os.environ, YON_WORLD="c%03x" % (abs(hash(str(tmp_path))) % 4096))
    r = subprocess.run(["./cons"], cwd=str(tmp_path), capture_output=True, text=True,
                       timeout=120, env=env)
    assert "error" not in r.stderr, r.stderr
    return r.returncode


def _cross_project(tmp_path: Path, place: str, fields: str, elem: str, build: str,
                   read: str) -> int:
    """The same, as two projects: the place lives in Space w of each side, the
    producer's functions in the place's file (the meteo layout)."""
    toml = '[package]\nname = "{n}"\n\n[runtime]\nbackend = "shm"\n\n' \
           '[world.W]\nobjects = ["X"]\nspaces  = [{s}]\n'
    funs = f"""
  fun value(): {elem} {{
{build}
  }}
  fun items(): Wire<{elem}> {{
    be v := value()
    be s := produce {{
      emit v
    }}
    return s
  }}"""
    svc, sub = tmp_path / "svc", tmp_path / "sub"
    for d, spaces in ((svc, '"w"'), (sub, '"w", "P"')):
        (d / "w").mkdir(parents=True)
        (d / "yon.toml").write_text(toml.format(n=d.name, s=spaces))
        (d / "w" / "Topos.yon").write_text("topos WTopos where {\n}\n")
    (svc / "w" / f"{place}.yon").write_text(f"place {place} {{\n{fields}{funs}\n}}\n")
    (svc / "Entry.yon").write_text("place Entry {\n  fun main(): Number { return 0 }\n}\n")
    (sub / "w" / f"{place}.yon").write_text(f"place {place} {{\n{fields}}}\n")
    (sub / "yon_modules" / "prod").mkdir(parents=True)
    (sub / "yon_modules" / "prod" / "prod.yon").write_text(
        f"fun items(): Wire<{elem}> {{\n  be s := produce {{ emit value() }}\n  return s\n}}\n")
    (sub / "Entry.yon").write_text(f"""import prod::items from P

place Entry {{
  fun main(): Number {{
    be w := wire to space P
    be sub := w.awaits(items)
    be s := sub.stream
    return s.fold(0, fun(a: Number, x: {elem}) => a + {read})
  }}
}}
""")
    for src, exe in (("svc", "P_srv"), ("sub", "cons")):
        c = subprocess.run([str(YONC), src, "-o", exe], cwd=str(tmp_path),
                           capture_output=True, text=True, timeout=180)
        assert c.returncode == 0, c.stdout + c.stderr
    env = dict(os.environ, YON_WORLD="d%03x" % (abs(hash(str(tmp_path))) % 4096))
    r = subprocess.run(["./cons"], cwd=str(tmp_path), capture_output=True, text=True,
                       timeout=120, env=env)
    assert "error" not in r.stderr, r.stderr
    return r.returncode


_FILL_MAP = """  be m := {empty}
  be k := 0
  iter {n} do {{
    m = {set}
    k = k + 1
  }}
  return m"""


def test_a_hashmap_crosses_with_its_values(tmp_path):
    build = _FILL_MAP.format(empty="HashMap.empty()", n=10, set="HashMap.set(m, k, k * 7)")
    rc = _cross(tmp_path, "", "HashMap<Number, Number>", build,
                "HashMap.size(x) + (match HashMap.get(x, 9) { Found(v) => v, Absent => 0 })")
    assert rc == 10 + 63


def test_a_hashmap_larger_than_the_ring_crosses_in_pieces(tmp_path):
    # 10^5 entries: about 1.6 MB of frame against a 64 KB ring
    build = _FILL_MAP.format(empty="HashMap.empty()", n=100000, set="HashMap.set(m, k, k * 3)")
    rc = _cross(tmp_path, "", "HashMap<Number, Number>", build,
                "HashMap.size(x) - 100000 + (match HashMap.get(x, 99999) "
                "{ Found(v) => v - 299997 + 7, Absent => 0 })")
    assert rc == 7


def test_a_hashset_crosses(tmp_path):
    build = _FILL_MAP.format(empty="HashSet.empty()", n=12, set="HashSet.add(m, k * 2)")
    rc = _cross(tmp_path, "", "HashSet<Number>", build,
                "HashSet.size(x) + (if HashSet.contains(x, 22) then 100 else 0)"
                " + (if HashSet.contains(x, 23) then 50 else 0)")
    assert rc == 112


def test_a_list_crosses_in_order(tmp_path):
    build = "  return List.cons(1, List.cons(2, List.cons(3, List.empty(0))))"
    rc = _cross(tmp_path, "", "List<Number>", build,
                "List.head(x) * 100 + List.head(List.tail(x)) * 10 + List.length(x)")
    assert rc == (100 + 20 + 3) % 256


def test_an_xrelmap_crosses_on_the_leech_heap(tmp_path):
    build = _FILL_MAP.format(empty="XRelMap.empty()", n=10, set="XRelMap.set(m, k, k + 40)")
    rc = _cross(tmp_path, "", "XRelMap<Number, Number>", build,
                "XRelMap.size(x) + (match XRelMap.get(x, 5) { Found(v) => v, Absent => 0 })")
    assert rc == 10 + 45


def test_an_xrelset_crosses(tmp_path):
    build = _FILL_MAP.format(empty="XRelSet.empty()", n=9, set="XRelSet.add(m, k)")
    rc = _cross(tmp_path, "", "XRelSet<Number>", build,
                "XRelSet.size(x) + (if XRelSet.contains(x, 8) then 30 else 0)")
    assert rc == 39


def test_a_string_crosses(tmp_path):
    rc = _cross(tmp_path, "", "String", '  return "hello wire"', "String.length(x)")
    assert rc == 10


def test_a_place_with_a_map_field_crosses(tmp_path):
    fields = "  label String\n  counts HashMap<Number, Number>\n"
    build = '    return .-> Bag { label "abc" counts HashMap.set(HashMap.empty(), 4, 40) }'
    rc = _cross_project(tmp_path, "Bag", fields, "Bag", build,
                        "String.length(x.label) + (match HashMap.get(x.counts, 4) "
                        "{ Found(v) => v, Absent => 0 })")
    assert rc == 43


def test_a_list_of_strings_crosses(tmp_path):
    build = '  return List.cons("abc", List.cons("de", List.empty(0)))'
    rc = _cross(tmp_path, "", "List<String>", build,
                "List.length(x) * 100 + String.length(List.head(x)) * 10"
                " + String.length(List.head(List.tail(x)))")
    assert rc == (200 + 30 + 2) % 256
