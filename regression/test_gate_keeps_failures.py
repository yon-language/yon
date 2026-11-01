"""A red gate keeps what it saw.

When a step of regression/gate.sh fails, the whole output of that step and
the environment it failed in (commit, dirty files, machine, load, the seed
of the day, the relevant variables) go to a file of their own in
YON_GATE_FAILURES, which nothing deletes: a failure that does not come back
can still be read.

Layer/kind: tooling / end-to-end.
"""
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def test_a_failed_build_leaves_its_output_and_environment(tmp_path):
    keep = tmp_path / "failures"
    # no dune on the PATH: the build of tier 0 fails for sure
    env = {"PATH": "/usr/bin:/bin", "HOME": os.environ.get("HOME", str(tmp_path)),
           "YON_GATE_FAILURES": str(keep), "YON_PROBE_VAR": "seen"}
    r = subprocess.run(["bash", str(ROOT / "regression" / "gate.sh"), "0"], capture_output=True,
                       text=True, timeout=120, env=env)
    assert r.returncode == 1, r.stdout + r.stderr
    assert "GATE RED (build)" in r.stdout, r.stdout
    files = sorted(keep.glob("*.log"))
    assert len(files) == 1, files
    text = files[0].read_text()
    assert f"kept: {files[0]}" in r.stdout, r.stdout
    for line in ("gate 0 red at: build", "commit: ", "dirty files:", "machine: ", "load: ",
                 "fuzz seed of the day", "YON_PROBE_VAR=seen", "──────── output of the step"):
        assert line in text, (line, text)
    # the output of the step is the build's own complaint
    assert "dune" in text.split("──────── output of the step ────────", 1)[1], text
