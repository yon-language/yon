"""XRelMap<K, V> and XRelSet<V>: the collections of the Leech heap.

Same semantics as HashMap / HashSet: a map from keys to values and a set
without duplicates, values that persist (set and add return a new collection
and leave the one they were given). What differs is the store: the nodes of
their trie live only in the Leech heap, each in a place (generation, point),
written once. A LatticePoint key routes by its index on the shell; any other
key by the hash of its bits. A map on the classes of a frame keys by
XRelFrame.canon. Arena<V>, add_ref and fuse/fusion_count are gone.
"""
from pathlib import Path
import subprocess

import pytest
from yon_programs import program

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_TOML = '[package]\nname = "probe"\n[runtime]\nbackend = "memory"\n'


class ProbeOutcome(AssertionError):
    """The probe's own verdict: the law does not hold (or is not there yet)."""


def _compile(tmp_path: Path, entry: str):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML)
    (proj / "Entry.yon").write_text(entry)
    exe = tmp_path / "probe.exe"
    c = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True,
                       text=True, timeout=120)
    return c.returncode, c.stdout + c.stderr, exe


def _run(tmp_path: Path, entry: str):
    rc, out, exe = _compile(tmp_path, entry)
    if rc != 0:
        if "XRelMap" in out or "XRelSet" in out:
            raise ProbeOutcome("not the new collections yet: " + out[-300:])
        raise AssertionError(out)
    r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=60)
    return r.returncode, [float(t) for t in r.stdout.split()]


def _rejected(out: str, code: str, *words: str) -> bool:
    """Refused with the code `code`, for the reason the words name."""
    assert words, "name the reason of the refusal, not only its code"
    return (f"[{code}]" in out and "Fatal error: exception" not in out
            and all(w in out for w in words))


_AT = """\
fun main: Number {{
  return match LatticePoint.of_coordinate({n}) {{
    LatticePoint as p => {f}(p), DomainError as d => 0 - 1 }}
}}
"""



def test_a_map_is_a_value(tmp_path):
    """set returns a new map and leaves the one it was given."""
    entry = program("test_xrel_collections/test_a_map_is_a_value_1.yon")
    rc, out = _run(tmp_path, entry)
    if out != [1.0, 2.0, 1.0, 0.0]:
        raise ProbeOutcome(f"persistence: {out}")


def test_the_arena_corpus_on_xrelmap(tmp_path):
    """What examples/arena_basic and uc_arena asked of Arena (put/get,
    occupied, Absent at an empty point, orbits of the point), asked of an
    XRelMap keyed by LatticePoint, answers the same."""
    entry = program("test_xrel_collections/test_the_arena_corpus_on_xrelmap_1.yon")
    rc, out = _run(tmp_path, entry)
    if out != [42.0, 1.0, 0.0, 1.0, 0.0, 0.0, 7.0]:
        raise ProbeOutcome(f"arena corpus: {out}")


def test_keys_that_are_not_points(tmp_path):
    """A Text key is its content: "abc" built two ways is one key. A Number
    key is its bits: 0.0 and -0.0 are two keys."""
    entry = program("test_xrel_collections/test_keys_that_are_not_points_1.yon")
    rc, out = _run(tmp_path, entry)
    if out != [7.0, 2.0, -1.0]:
        raise ProbeOutcome(f"non-point keys: {out}")


def test_same_answers_as_hashmap_and_hashset(tmp_path):
    """The same keys, the same overwrites, the same reads: HashMap and XRelMap
    answer alike; HashSet and XRelSet give the same union and intersection."""
    entry = program("test_xrel_collections/test_same_answers_as_hashmap_and_hashset_1.yon")
    rc, out = _run(tmp_path, entry)
    if len(out) != 9 or out[0] != out[1] or out[2] != out[3] or out[4] != out[5] \
            or out[6] != out[7] or out[2] != 200.0 or out[8] != 1.0:
        raise ProbeOutcome(f"HashMap/XRelMap and HashSet/XRelSet disagree: {out}")


def test_a_map_on_the_classes_keys_by_canon(tmp_path):
    """Keyed by XRelFrame.canon(curtis, p), a map answers by class: the
    negative of 1536 finds what 1536 stored, 1280 does not."""
    entry = program("test_xrel_collections/test_a_map_on_the_classes_keys_by_canon_1.yon")
    rc, out = _run(tmp_path, entry)
    if out != [100.0, 0.0, 2.0]:
        raise ProbeOutcome(f"classes through canon: {out}")


@pytest.mark.parametrize("call", [
    "Arena.empty()",
    "XRelMap.add_ref(XRelMap.empty, 1536)",
    "XRelSet.add_ref(XRelSet.empty, 1536)",
])
def test_retired_forms_are_refused(tmp_path, call):
    entry = f"place Entry {{}}\nfun main: Number {{\n  a := {call}\n  return 0\n}}\n"
    rc, out, _ = _compile(tmp_path, entry)
    if not (rc != 0 and _rejected(out, "E2001", "unknown function or operation")):
        raise ProbeOutcome(f"{call} still compiles: rc={rc}")
