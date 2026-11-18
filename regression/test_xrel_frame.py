"""XRelFrame: a partition of the type-2 shell, given by its canonical projection.

A frame is a quotient of the 196,560 points; `canon(f, p)` is the projection,
the representative of p's class. `discrete` is the finest frame (each point its
own class, canon is the identity), `whole` the coarsest (one class), `curtis`
the frame of the 26 Curtis octads, and `refine(f, p)` splits each class of f by
the type of v ^ p. A map on the classes is an ordinary map composed with
canon. The exhaustive laws (c(c(v)) = c(v) on every point, the sign) are in
runtime/test_unit_xrel_frame.c; these probes check that the surface says the
same thing.
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


def _run(tmp_path: Path, entry: str):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML)
    (proj / "Entry.yon").write_text(entry)
    exe = tmp_path / "probe.exe"
    c = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True,
                       text=True, timeout=120)
    if c.returncode != 0:
        out = c.stdout + c.stderr
        if "XRelFrame" in out:
            raise ProbeOutcome("XRelFrame is not a place yet: " + out[-300:])
        raise AssertionError(out)
    r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=60)
    return r.returncode, [float(t) for t in r.stdout.split()]


_POINTS = program("test_xrel_frame/module_1.yon")


def test_canon_is_a_projection(tmp_path):
    """canon(f, canon(f, p)) is canon(f, p) on the frames the surface makes."""
    entry = program("test_xrel_frame/test_canon_is_a_projection_1.yon")
    rc, out = _run(tmp_path, entry)
    if out != [1.0, 1.0, 1.0, 1.0]:
        raise ProbeOutcome(f"canon is not idempotent on the surface: {out}")


def test_classes_of_the_frames(tmp_path):
    """discrete keeps 1536 and -1536 apart; curtis and the frame by 1536 hold
    them together and keep 1536 and 1280 apart; whole has one class; refining
    the discrete frame leaves it discrete."""
    entry = program("test_xrel_frame/test_classes_of_the_frames_1.yon")
    rc, out = _run(tmp_path, entry)
    if out != [0.0, 1.0, 1.0, 0.0, 1.0, 0.0, 1.0]:
        raise ProbeOutcome(f"classes: {out}")
