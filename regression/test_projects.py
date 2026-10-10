"""Project-runner for the toml-only migration.

After the filesystem-only worlds migration, the corpus that used inline worlds
became directory PROJECTS (yon.toml + space-dirs + place files). This suite
discovers every project and gates `yoner_emit_mlir <dir>`:

  - positive project  -> compiles (exit 0)
  - negative project  -> rejected at compile time, CLEANLY and for the RIGHT
                         reason: exit 3, the stable code and the message
                         fragment recorded for it in yon_tests/rejections.txt
                         (a parse error or a crash must not pass for the type
                         error the fixture was written to show).

A project is "negative" if it lives under a `negative/` directory or its name
contains `reject` or `leak` (compiling_corpus.is_negative). `project_min` is
covered by test_site.py and is skipped here.
"""
import subprocess
from pathlib import Path

import pytest

import compiling_corpus as cc

ROOT = cc.ROOT
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"

PROJECTS = cc.discover_projects()
NEGATIVE = [p for p in PROJECTS if cc.is_negative(p)]
EXPECT = cc.rejections()


@pytest.fixture(scope="session", autouse=True)
def _built():
    if not EMIT.exists():
        pytest.skip("frontend not built (cd frontend && dune build)")


@pytest.mark.parametrize("proj", PROJECTS, ids=[Path(p).name for p in PROJECTS])
def test_project_emits(proj):
    r = subprocess.run([str(EMIT), proj], capture_output=True, text=True, timeout=120)
    out = r.stdout + r.stderr
    if cc.is_negative(proj):
        key = cc.rel(proj)
        assert key in EXPECT, f"{key}: negative project with no line in yon_tests/rejections.txt"
        code, frag = EXPECT[key]
        why = cc.rejection_failure(r.returncode, out, code, frag)
        assert why is None, f"{key}: {why}\n{r.stderr[-800:]}"
        assert r.returncode == 3, f"{key}: rejected with exit {r.returncode}, expected 3"
    else:
        assert r.returncode == 0, (
            f"{Path(proj).name}: expected compile, got exit {r.returncode}\n{r.stderr[-500:]}")


def test_every_negative_project_has_an_expectation():
    """The expectation table and the negative projects are the same set: a new
    negative project needs its code + fragment, a removed one its line removed."""
    projects = {cc.rel(p) for p in NEGATIVE}
    listed = {k for k in EXPECT if not k.endswith(".yon")}
    assert projects - listed == set(), f"negative projects without an expectation: {sorted(projects - listed)}"
    assert listed - projects == set(), f"expectations for no negative project: {sorted(listed - projects)}"
