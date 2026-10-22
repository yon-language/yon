"""Reclaim by regions: a Space's two heaps end with it.

Every value is made in the heaps of the Space whose code runs (its FNV heap,
its Leech store). A Space whose code keeps nothing past a call (no stream, no
pool of the runtime) is stateless: each call into it is a region, and when
the call returns, after its result was copied out, both its heaps are made
empty and their pages go back to the system. A Space with state keeps its
heaps as long as it lives, and `drop X` (or the death-watch) ends them. The
probes read the runtime's heap trace (YON_DEBUG_HEAP): at each call into a
Space, each return, each region's end and each drop, every Space's value
bytes (both heaps) and the resident memory of the process (rss).
"""
from pathlib import Path
import re
import subprocess

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

MB = 1 << 20

_WORK = """  fun {name}(n: Number): Number {{
    be m := HashMap.empty()
    be x := XRelMap.empty()
    be k := 0
    iter n do {{
      m = HashMap.set(m, k, k * 3)
      x = XRelMap.set(x, k, k + 1)
      k = k + 1
    }}
    return HashMap.size(m) + XRelMap.size(x){keep}
  }}
"""

# a call that keeps something in a runtime registry past the call: state
_KEEP = """ + String.length(Buffer.finish(Buffer.append(Buffer.make(0), "kept"))) * 0"""


def _project(tmp_path: Path, spaces: dict, entry: str) -> Path:
    """spaces: Space name -> (place name, place body)."""
    proj = tmp_path / "proj"
    objs = ", ".join('"%s"' % p for p, _ in spaces.values())
    names = ", ".join('"%s"' % s for s in spaces)
    proj.mkdir()
    (proj / "yon.toml").write_text(
        '[package]\nname = "probe"\n\n[world.W]\nobjects = [%s]\nspaces  = [%s]\n\n'
        '[runtime]\nbackend = "memory"\n' % (objs, names))
    for sp, (place, body) in spaces.items():
        (proj / sp).mkdir()
        (proj / sp / "Topos.yon").write_text("topos T%s where {\n}\n" % sp)
        (proj / sp / f"{place}.yon").write_text(f"place {place} {{\n  side Number\n{body}}}\n")
    (proj / "Entry.yon").write_text(entry)
    return proj


def _trace(tmp_path: Path, proj: Path):
    exe = tmp_path / "probe.exe"
    c = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True,
                       text=True, timeout=300)
    assert c.returncode == 0, c.stdout + c.stderr
    r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=300,
                       env={"YON_DEBUG_HEAP": "1", "PATH": "/usr/bin:/bin"})
    ticks = []
    for line in r.stderr.splitlines():
        if not line.startswith("[HEAP]"):
            continue
        f = dict(kv.split("=", 1) for kv in line.split()[1:] if "=" in kv)
        ticks.append((f.pop("ev"), {k: int(v) for k, v in f.items() if k != "seq"}))
    return r.returncode, ticks


def _at(ticks, ev):
    return [t for e, t in ticks if e == ev]


def test_a_stateless_space_gives_its_heaps_back_when_the_call_returns(tmp_path):
    proj = _project(tmp_path, {"w": ("Q", _WORK.format(name="work", keep=""))},
                    "place Entry {\n  fun main(): Number {\n"
                    "    be r := Q.work(100000)\n    return r - 200000 + 7\n  }\n}\n")
    rc, ticks = _trace(tmp_path, proj)
    assert rc == 7
    (before,), (peak,), (after,) = _at(ticks, "call:w"), _at(ticks, "return:w"), _at(ticks, "region:w")
    assert peak["w"] > 50 * MB                    # a map and an XRelMap of 10^5 in w
    assert after["w"] < 64                        # both heaps empty
    grown = peak["rss"] - before["rss"]
    assert grown > 100 * MB
    assert after["rss"] - before["rss"] < grown // 10, (before, peak, after)


def test_a_map_made_in_a_space_is_read_after_the_space_is_dropped(tmp_path):
    body = """  fun build(n: Number): HashMap<Number, Number> {
    be m := HashMap.empty()
    be k := 0
    iter n do {
      m = HashMap.set(m, k, k * 100)
      k = k + 1
    }
    return m
  }
"""
    proj = _project(tmp_path, {"w": ("Q", body)}, """place Entry {
  fun main(): Number {
    be m := Q.build(10)
    drop w
    return HashMap.size(m) + (match HashMap.get(m, 3) { Found(v) => v, Absent => 0 })
  }
}
""")
    rc, ticks = _trace(tmp_path, proj)
    assert rc == 54
    assert _at(ticks, "drop:w")


def test_drop_frees_the_collections_of_a_space_with_state(tmp_path):
    proj = _project(tmp_path, {"w": ("Q", _WORK.format(name="work", keep=_KEEP))},
                    "place Entry {\n  fun main(): Number {\n"
                    "    be r := Q.work(100000)\n    drop w\n    return r - 200000 + 9\n  }\n}\n")
    rc, ticks = _trace(tmp_path, proj)
    assert rc == 9
    assert not _at(ticks, "region:w")             # with state: no region per call
    (before,), (ret,), (dropped,) = _at(ticks, "call:w"), _at(ticks, "return:w"), _at(ticks, "drop:w")
    assert ret["w"] > 50 * MB                      # the collections stay in w after the call
    assert dropped["w"] < 64                       # drop w frees them
    grown = ret["rss"] - before["rss"]
    assert dropped["rss"] - before["rss"] < grown // 10, (before, ret, dropped)


def test_a_stateless_space_called_eight_times_stays_flat(tmp_path):
    proj = _project(tmp_path, {"w": ("Q", _WORK.format(name="work", keep=""))},
                    "place Entry {\n  fun main(): Number {\n    be t := 0\n"
                    "    iter 8 do {\n      t = t + Q.work(20000)\n    }\n"
                    "    return t / 40000\n  }\n}\n")
    rc, ticks = _trace(tmp_path, proj)
    assert rc == 8
    ends = _at(ticks, "region:w")
    peaks = _at(ticks, "return:w")
    assert len(ends) == 8 and all(t["w"] < 64 for t in ends)
    per_call = peaks[0]["rss"] - ends[0]["rss"]
    assert max(t["rss"] for t in ends) - ends[0]["rss"] < per_call // 4, ends


def test_a_space_with_state_grows_while_it_lives(tmp_path):
    proj = _project(tmp_path, {"w": ("Q", _WORK.format(name="work", keep=_KEEP))},
                    "place Entry {\n  fun main(): Number {\n    be t := 0\n"
                    "    iter 8 do {\n      t = t + Q.work(20000)\n    }\n"
                    "    return t / 40000\n  }\n}\n")
    rc, ticks = _trace(tmp_path, proj)
    assert rc == 8
    sizes = [t["w"] for t in _at(ticks, "return:w")]
    assert len(sizes) == 8
    steps = [b - a for a, b in zip(sizes, sizes[1:])]
    # every call adds about the same: the Space grows with the work, while it lives
    assert all(s > 5 * MB and abs(s - steps[0]) < steps[0] // 5 for s in steps), sizes


def test_the_growth_benchmark_with_one_space_per_round_is_flat(tmp_path):
    rounds = 8
    spaces = {f"r{i}": (f"R{i}", _WORK.format(name=f"work{i}", keep=""))
              for i in range(1, rounds + 1)}
    calls = "\n".join(f"    t = t + R{i}.work{i}(20000)" for i in range(1, rounds + 1))
    proj = _project(tmp_path, spaces,
                    "place Entry {\n  fun main(): Number {\n    be t := 0\n"
                    f"{calls}\n    return t / 40000\n  }}\n}}\n")
    rc, ticks = _trace(tmp_path, proj)
    assert rc == rounds
    ends = [t for e, t in ticks if e.startswith("region:")]
    peaks = [t for e, t in ticks if e.startswith("return:")]
    assert len(ends) == rounds
    per_round = peaks[0]["rss"] - ends[0]["rss"]
    assert per_round > 20 * MB
    assert max(t["rss"] for t in ends) - ends[0]["rss"] < per_round // 4, ends
    assert all(t["total"] < 64 * rounds for t in ends)
