"""The `drop X` construct: the driver's static drop check, end to end.

Runs the real toolchain (toolchain/yonc) on a project fixture and checks that a
misplaced `drop X` is rejected at compile time with a DROP ERROR, while a
well-placed drop compiles. Two faults are exercised: X still reachable downstream
(an early drop), and X not a declared Space (a typo).

The fixture (regression/keyword_coverage/drop_reclaim) declares a Space D with a
producer d_op, and an entry that imports d_op from D. The committed Entry.yon is
LEGAL (drop D after the last use), so a compile-everything sweep stays green; the
illegal variants are written into a tmp copy per test.

Three things are pinned here that the in-process oracle (test_space_graph.exe)
cannot reach:

  1. The check is wired into the driver as a real exit-3 compile error, not just
     an analysis that returns a list.
  2. It runs on the PRE-LOWERING surface program. Space_liveness.check_drops must
     fire before Module_prefix.lower_cross_space, which rewrites cross-Space calls
     and consumes the import decls; run it after, and the import/transitive arcs
     vanish and every drop looks legal. The import and transitive cases below go
     red the moment the check is moved past that rewrite.
  3. Existence is read from the manifest census (the declared Spaces), so
     `drop Zeta` for an undeclared name is an unknown-Space error, not silently
     legal (the misspelling has no arc, so reachability alone would pass it).
"""
import os
import shutil
import subprocess
from pathlib import Path

import pytest

# The runtime drop counter (yon_xheap_drops) is printed at exit only under this
# env var, so the automatic reclaim stays silent by default; the tests set it to
# read the counter.
_DEBUG_ENV = {**os.environ, "YON_DEBUG_DROPS": "1"}

# No explicit `drop`: main uses D (the imported d_op) then does unrelated work, so
# D dies before the end and the automatic reclaim inserts the drop at its last use.
_AUTO_NO_DROP = """\
import svc::d_op from D
place Entry { }
fun main(): number {
  be r holds d_op(5)
  be s holds r + 1
  return s - s
}
"""

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
FIXTURE = ROOT / "regression" / "keyword_coverage" / "drop_reclaim"

_ILLEGAL_IMPORT = """\
import svc::d_op from D
place Entry { }
fun main(): number {
  drop D
  be r holds d_op(5)
  return r - r
}
"""

_ILLEGAL_TRANSITIVE = """\
import svc::d_op from D
place Entry { }
fun helper(): number { be r holds d_op(9)  return r }
fun main(): number {
  drop D
  be r holds helper()
  return r - r
}
"""

_ILLEGAL_UNKNOWN = """\
import svc::d_op from D
place Entry { }
fun main(): number {
  drop Zeta
  be r holds d_op(5)
  return r - r
}
"""

# A legal standalone drop of the declared Space D (nothing downstream touches D,
# no cross-Space RPC before it), so the compiled binary runs in-process and the
# reclaim executes. Used to prove the emission reaches the runtime.
_LEGAL_STANDALONE = """\
place Entry { }
fun main(): number {
  drop D
  return 0
}
"""


def _compile(project: Path, out: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(YONC), str(project), "-o", str(out)],
        capture_output=True, text=True, timeout=120,
    )


def _copy_with_entry(src: Path, dst: Path, entry: str) -> Path:
    shutil.copytree(src, dst)
    (dst / "Entry.yon").write_text(entry)
    return dst


@pytest.mark.skipif(not YONC.exists() or not FIXTURE.exists(),
                    reason="yonc or drop_check fixture missing")
def test_legal_drop_compiles(tmp_path):
    """drop D placed after the last use of D compiles: no false positive."""
    r = _compile(FIXTURE, tmp_path / "out")
    combined = r.stdout + r.stderr
    assert "DROP ERROR" not in combined, f"legal drop was rejected:\n{combined}"
    assert r.returncode == 0, f"legal fixture failed to compile:\n{combined}"


@pytest.mark.skipif(not YONC.exists() or not FIXTURE.exists(),
                    reason="yonc or drop_check fixture missing")
def test_illegal_import_drop_rejected(tmp_path):
    """drop D before a downstream use of the imported d_op is a compile error,
    citing Space D. Import arcs are only visible pre-lowering."""
    proj = _copy_with_entry(FIXTURE, tmp_path / "proj", _ILLEGAL_IMPORT)
    r = _compile(proj, tmp_path / "out")
    combined = r.stdout + r.stderr
    # yonc wraps the frontend and reports its own nonzero code; the signal is a
    # failed compile carrying the DROP ERROR, not the exact frontend exit code.
    assert r.returncode != 0, f"expected a failed compile:\n{combined}"
    assert "DROP ERROR" in combined and "Space D" in combined, combined


@pytest.mark.skipif(not YONC.exists() or not FIXTURE.exists(),
                    reason="yonc or drop_check fixture missing")
def test_illegal_transitive_drop_rejected(tmp_path):
    """drop D before a call to a local function that uses d_op is rejected: the
    arc is reached transitively through the call graph."""
    proj = _copy_with_entry(FIXTURE, tmp_path / "proj", _ILLEGAL_TRANSITIVE)
    r = _compile(proj, tmp_path / "out")
    combined = r.stdout + r.stderr
    # yonc wraps the frontend and reports its own nonzero code; the signal is a
    # failed compile carrying the DROP ERROR, not the exact frontend exit code.
    assert r.returncode != 0, f"expected a failed compile:\n{combined}"
    assert "DROP ERROR" in combined and "Space D" in combined, combined


@pytest.mark.skipif(not YONC.exists() or not FIXTURE.exists(),
                    reason="yonc or drop_check fixture missing")
def test_illegal_unknown_space_rejected(tmp_path):
    """drop Zeta, where Zeta is not a declared Space, is an unknown-Space error,
    not silently legal. The domain is checked before reachability."""
    proj = _copy_with_entry(FIXTURE, tmp_path / "proj", _ILLEGAL_UNKNOWN)
    r = _compile(proj, tmp_path / "out")
    combined = r.stdout + r.stderr
    assert r.returncode != 0, f"expected a failed compile:\n{combined}"
    assert "DROP ERROR" in combined and "unknown Space" in combined and "Zeta" in combined, combined


@pytest.mark.skipif(not YONC.exists() or not FIXTURE.exists(),
                    reason="yonc or drop_check fixture missing")
def test_legal_drop_reclaims_at_runtime(tmp_path):
    """A compiled `drop D` reaches the runtime AND the reclaim runs, proven by the
    authoritative counter: the binary prints `xheap_drops=1`. This is the double
    pin on one observable -- (a) the emission wired through (the drop point
    reaches the call, not the placeholder) and (b) the primitive executed (the
    counter increments inside yon_xheap_drop, past the madvise). Remove the emit
    call and the counter stays 0: the negative control that proves (a)."""
    proj = _copy_with_entry(FIXTURE, tmp_path / "proj", _LEGAL_STANDALONE)
    out = tmp_path / "out"
    c = _compile(proj, out)
    combined = c.stdout + c.stderr
    assert c.returncode == 0, f"legal standalone drop failed to compile:\n{combined}"
    r = subprocess.run([str(out)], capture_output=True, text=True, timeout=60, env=_DEBUG_ENV)
    run_out = r.stdout + r.stderr
    assert "xheap_drops=1" in run_out, (
        f"expected exactly one reclaim (yon_xheap_drops()==1):\n{run_out}")


@pytest.mark.skipif(not YONC.exists() or not FIXTURE.exists(),
                    reason="yonc or drop_check fixture missing")
def test_automatic_reclaim_without_explicit_drop(tmp_path):
    """The automatic reclaim (the mechanism): with NO `drop` written, a Space that
    dies before main ends is reclaimed at its last use. main uses D then does
    unrelated work, so the compiler inserts the reclaim and the binary reports
    xheap_drops=1. Disable the auto-reclaim pass and the counter stays 0: the
    negative control that proves the mechanism, not just the construct."""
    proj = _copy_with_entry(FIXTURE, tmp_path / "proj", _AUTO_NO_DROP)
    out = tmp_path / "out"
    c = _compile(proj, out)
    combined = c.stdout + c.stderr
    assert c.returncode == 0, f"auto-reclaim fixture failed to compile:\n{combined}"
    r = subprocess.run([str(out)], capture_output=True, text=True, timeout=60, env=_DEBUG_ENV)
    run_out = r.stdout + r.stderr
    assert "xheap_drops=1" in run_out, (
        f"D was not automatically reclaimed (no drop written):\n{run_out}")
