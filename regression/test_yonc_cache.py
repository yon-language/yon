"""The content cache of yonc gives the verdict a compilation gives.

With YONC_CACHE_DIR set, yonc keys a compilation by the content of its
sources, the prelude, the toolchain's binaries, the runtime's objects, the
yonc script and its flags (toolchain/yonc_cache_key.py). A key seen before is
answered from the cache: the same exit code, the same messages (with the
path of this input in them), and on success the same artefact. The verdict is
what is compared, never the bytes: two links of one program differ in their
identifier.
"""
from pathlib import Path
import os
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

EXAMPLES = ["vec_basic", "closure_capture", "circle_hit"]


def _yonc(src, out, cache=None, env=None):
    e = dict(os.environ if env is None else env)
    e["YONC_CACHE_DIR"] = str(cache) if cache else ""
    return subprocess.run([str(YONC), str(src), "-o", str(out)], capture_output=True,
                          text=True, timeout=300, env=e)


def _verdict(exe):
    r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=60)
    return r.returncode, r.stdout


def _entries(cache):
    return sorted(p.name for p in cache.iterdir() if p.is_dir())


@pytest.mark.parametrize("name", EXAMPLES)
def test_a_cached_compilation_gives_the_verdict_of_a_fresh_one(tmp_path, name):
    cache = tmp_path / "cache"
    src = ROOT / "examples" / name
    fresh, cold, warm = tmp_path / "fresh", tmp_path / "cold", tmp_path / "warm"
    assert _yonc(src, fresh).returncode == 0
    assert _yonc(src, cold, cache).returncode == 0
    entries = _entries(cache)
    c = _yonc(src, warm, cache)
    assert c.returncode == 0 and c.stdout.strip() == str(warm)
    assert _entries(cache) == entries, "the warm compile made a new entry: no hit"
    assert warm.read_bytes() == (cache / entries[0] / "out").read_bytes(), \
        "a hit hands the stored artefact"
    assert os.stat(warm).st_ino != os.stat(cache / entries[0] / "out").st_ino, \
        "as a file of its own: a binary shared by hard links is at times killed (macOS)"
    assert _verdict(fresh) == _verdict(cold) == _verdict(warm)


def test_a_failing_compilation_is_replayed_with_this_input_in_its_messages(tmp_path):
    cache = tmp_path / "cache"
    text = "place Entry {\n  fun main(): Number { return ) }\n}\n"   # a parse error names its file
    a, b = tmp_path / "a" / "bad.yon", tmp_path / "b" / "bad.yon"
    for p in (a, b):
        p.parent.mkdir()
        p.write_text(text)
    fresh = _yonc(a, tmp_path / "x")
    first = _yonc(a, tmp_path / "x", cache)
    second = _yonc(b, tmp_path / "y", cache)
    assert fresh.returncode == first.returncode == second.returncode == 1
    assert len(_entries(cache)) == 1, "the same content is one entry, wherever it is"
    assert "PARSE ERROR" in second.stderr
    assert fresh.stderr.replace(str(tmp_path / "x"), "") == first.stderr.replace(str(tmp_path / "x"), "")
    assert str(b) in second.stderr and str(a) not in second.stderr


def test_two_files_of_one_directory_are_two_compilations(tmp_path):
    # both read the same directory (the signatures of their imports): the key
    # says which one is compiled
    cache = tmp_path / "cache"
    (tmp_path / "one.yon").write_text("place Entry {\n  fun main(): Number { return 11 }\n}\n")
    (tmp_path / "two.yon").write_text("place Entry {\n  fun main(): Number { return 22 }\n}\n")
    assert _yonc(tmp_path / "one.yon", tmp_path / "o1", cache).returncode == 0
    assert _yonc(tmp_path / "two.yon", tmp_path / "o2", cache).returncode == 0
    assert _verdict(tmp_path / "o1")[0] == 11 and _verdict(tmp_path / "o2")[0] == 22


def test_a_change_of_source_or_prelude_is_another_key(tmp_path):
    cache = tmp_path / "cache"
    proj = tmp_path / "p"
    shutil.copytree(ROOT / "examples" / "vec_basic", proj)
    assert _yonc(proj, tmp_path / "o1", cache).returncode == 0
    entry = (proj / "Entry.yon")
    entry.write_text(entry.read_text() + "\n")             # one byte more
    assert _yonc(proj, tmp_path / "o2", cache).returncode == 0
    assert len(_entries(cache)) == 2
    pre = tmp_path / "prelude"
    shutil.copytree(ROOT / "prelude", pre)
    (pre / "text" / "String.yon").write_text((pre / "text" / "String.yon").read_text() + "\n")
    env = dict(os.environ, YON_PRELUDE=str(pre))
    assert _yonc(proj, tmp_path / "o3", cache, env).returncode == 0
    assert len(_entries(cache)) == 3
    assert _verdict(tmp_path / "o2") == _verdict(tmp_path / "o3")
