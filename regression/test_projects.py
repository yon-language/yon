"""Project-runner for the toml-only migration.

After the filesystem-only worlds migration, the corpus that used inline worlds
became directory PROJECTS (yon.toml + space-dirs + place files). This suite
discovers every project and gates `yoner_emit_mlir <dir>` with the expected
exit code:

  - positive project  -> compiles (exit 0)
  - negative project  -> rejected at compile time (exit != 0)

A project is "negative" if it lives under a `negative/` directory or its name
contains `reject` or `leak`. `project_min` is covered by test_site.py and is
skipped here.
"""
import glob
import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"


def _projects():
    roots = ["examples", "regression/yon_tests", "regression/book",
             "regression/keyword_coverage", "regression/cross_space"]
    dirs = set()
    for r in roots:
        for toml in glob.glob(str(ROOT / r / "**" / "yon.toml"), recursive=True):
            d = os.path.dirname(toml)
            if os.path.basename(d) == "project_min":
                continue
            dirs.add(d)
    return sorted(dirs)


PROJECTS = _projects()


def _is_negative(path):
    name = os.path.basename(path)
    return ("/negative/" in path.replace(os.sep, "/")
            or "reject" in name or "leak" in name)


@pytest.fixture(scope="session", autouse=True)
def _built():
    if not EMIT.exists():
        pytest.skip("frontend not built (cd frontend && dune build)")


@pytest.mark.parametrize("proj", PROJECTS, ids=[Path(p).name for p in PROJECTS])
def test_project_emits(proj):
    r = subprocess.run([str(EMIT), proj], capture_output=True, text=True, timeout=120)
    if _is_negative(proj):
        assert r.returncode != 0, (
            f"{Path(proj).name}: expected REJECTION, got exit 0\n{r.stderr[-500:]}")
    else:
        assert r.returncode == 0, (
            f"{Path(proj).name}: expected compile, got exit {r.returncode}\n{r.stderr[-500:]}")
