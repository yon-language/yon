"""Smoke test for the unified `yon` driver (toolchain/yon).

The driver is a thin facade: it dispatches to the stage-0 reference toolchain
(yonc) and the shared tooling binaries, and reports honestly for commands that
are not wired yet. This pins the contract of the facade: the delegating commands
work end to end, and the roadmap commands fail loudly (exit 2) instead of
pretending to succeed.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YON = ROOT / "toolchain" / "yon"
YONC = ROOT / "toolchain" / "yonc"

GOOD = "fun main(): Number { return 2 + 3 * 4 }\n"          # exits 14
BAD = 'fun bad(): Number { return "text" + 1 }\nfun main(): Number { return 0 }\n'


def _yon(*args, **kw):
    return subprocess.run([str(YON), *args], capture_output=True, text=True,
                          timeout=180, **kw)


pytestmark = pytest.mark.skipif(not YON.exists() or not YONC.exists(),
                                reason="toolchain/yon or yonc not present")


def test_build_and_run(tmp_path):
    src = tmp_path / "t.yon"
    src.write_text(GOOD)
    out = tmp_path / "t"
    b = _yon("build", str(src), "-o", str(out))
    assert b.returncode == 0 and out.exists(), b.stderr[-800:]
    r = _yon("run", str(src))
    assert r.returncode == 14, f"run exited {r.returncode}, expected 14"


def test_check_accepts_good_and_rejects_bad(tmp_path):
    good = tmp_path / "good.yon"
    good.write_text(GOOD)
    bad = tmp_path / "bad.yon"
    bad.write_text(BAD)
    assert _yon("check", str(good)).returncode == 0
    # a type error is rejected without running the backend; exit 3 = false proof.
    assert _yon("check", str(bad)).returncode == 3


def test_version_and_help():
    v = _yon("version")
    assert v.returncode == 0 and "yon" in v.stdout
    h = _yon("help")
    assert h.returncode == 0 and "Usage:" in h.stdout


def test_stages_reports_the_three_stages():
    # `yon stages` is wired since c43f4c1 (the driver reports the bootstrap
    # ladder); the roadmap-fail expectation below predates that commit.
    r = _yon("stages")
    assert r.returncode == 0
    for s in ("stage 0", "stage 1", "stage 2"):
        assert s in r.stdout


@pytest.mark.parametrize("cmd", ["diff", "bootstrap", "spec", "prove"])
def test_roadmap_commands_fail_honestly(cmd):
    # not-yet-wired commands must exit non-zero (2), not fake success.
    r = _yon(cmd)
    assert r.returncode == 2 and "roadmap" in r.stderr


def test_unknown_command_fails():
    r = _yon("frobnicate")
    assert r.returncode == 2 and "unknown command" in r.stderr
