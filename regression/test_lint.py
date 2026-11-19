"""The linter warns (never rejects) under stable Wxxx codes, shared by CLI + LSP.

The rules live in one place (frontend/linter.ml); the `yon_lint` CLI and the
language server both call Linter.lint_program, so they cannot disagree. The
distinctive rule is W3001 unused-import: an `import ... from S` whose symbol is
never used is a dead Space dependency (a communication arc with no traffic) --
a warning that comes from Yon's Space model, not generic style.
"""
import re
import subprocess
from pathlib import Path

import pytest
import compiling_corpus as cc
from yon_programs import program

ROOT = Path(__file__).resolve().parent.parent
LINT = ROOT / "frontend" / "_build" / "default" / "yon_lint.exe"
LSP = ROOT / "frontend" / "_build" / "default" / "yon_lsp.exe"

CORPUS = sorted(
    list((ROOT / "examples").rglob("*.yon"))
    + list((ROOT / "regression" / "yon_tests").rglob("*.yon"))
)


def _lint(tmp_path, source: str) -> str:
    f = tmp_path / "x.yon"
    f.write_text(source)
    r = subprocess.run([str(LINT), str(f)], capture_output=True, text=True, timeout=60)
    return r.stdout + r.stderr


@pytest.mark.skipif(not LINT.exists(), reason="yon_lint not built")
def test_lint_flags_dead_function(tmp_path):
    out = _lint(tmp_path, program("test_lint/test_lint_flags_dead_function_1.yon"))
    assert "W1001" in out and "orphan" in out, out


@pytest.mark.skipif(not LINT.exists(), reason="yon_lint not built")
def test_lint_flags_unused_binding(tmp_path):
    out = _lint(tmp_path, program("test_lint/test_lint_flags_unused_binding_1.yon"))
    assert "W1002" in out and "unusedb" in out, out


@pytest.mark.skipif(not LINT.exists(), reason="yon_lint not built")
def test_lint_flags_unused_param(tmp_path):
    out = _lint(tmp_path, program("test_lint/test_lint_flags_unused_param_1.yon"))
    assert "W1003" in out and "dead" in out, out


@pytest.mark.skipif(not LINT.exists(), reason="yon_lint not built")
def test_lint_flags_unused_import_dead_space_dep(tmp_path):
    """The Space-aware rule: an import whose symbol is never called is a dead
    dependency on that Space."""
    out = _lint(tmp_path,
                program("test_lint/test_lint_flags_unused_import_dead_space_dep_1.yon"))
    assert "W3001" in out and "dead_op" in out and "Space B" in out, out
    assert "used_op" not in out.replace("used_op(5)", ""), f"used import flagged: {out}"


@pytest.mark.skipif(not LINT.exists(), reason="yon_lint not built")
def test_lint_underscore_and_clean_are_quiet(tmp_path):
    # leading-underscore binding/param are intentional discards, not warned
    out = _lint(tmp_path,
                program("test_lint/test_lint_underscore_and_clean_are_quiet_1.yon"))
    assert "no lint warnings" in out, out


WARNINGS = cc.warnings()


@pytest.mark.skipif(not LINT.exists(), reason="yon_lint not built")
@pytest.mark.parametrize("fixture", sorted(WARNINGS))
def test_a_warning_fixture_carries_its_code(fixture):
    """Each fixture of yon_tests/warnings/ warns with its code, for the reason its line names."""
    code, frag = WARNINGS[fixture]
    r = subprocess.run([str(LINT), str(ROOT / fixture)], capture_output=True, text=True, timeout=60)
    out = r.stdout + r.stderr
    assert r.returncode == 0 and f"[{code}]" in out and frag in out, out


def test_every_warning_fixture_has_an_expectation():
    on_disk = {str(p.relative_to(ROOT)) for p in (ROOT / "regression" / "yon_tests" / "warnings").glob("*.yon")}
    assert on_disk == set(WARNINGS), (
        f"fixtures without a line: {sorted(on_disk - set(WARNINGS))}; "
        f"lines without a fixture: {sorted(set(WARNINGS) - on_disk)}")


@pytest.mark.skipif(not LINT.exists(), reason="yon_lint not built")
def test_lint_never_crashes_on_corpus():
    """Advisory tool: it must run cleanly (exit 0) on every corpus file."""
    for f in CORPUS:
        r = subprocess.run([str(LINT), str(f)], capture_output=True, text=True, timeout=60)
        assert r.returncode == 0, f"yon_lint crashed on {f}: {r.stderr}"


def _two_space_project(root: Path):
    (root / "A").mkdir(parents=True)
    (root / "B").mkdir(parents=True)
    (root / "yon.toml").write_text(
        '[package]\nname = "p"\n[runtime]\nbackend = "separate"\n'
        '[world.W]\nobjects = ["X"]\nspaces  = ["A", "B"]\n')
    (root / "A" / "Topos.yon").write_text(program("test_lint/_two_space_project_1.yon"))
    (root / "B" / "Topos.yon").write_text(program("test_lint/_two_space_project_2.yon"))
    return root


@pytest.mark.skipif(not LSP.exists(), reason="yon_lsp not built")
def test_lsp_dead_function_is_whole_program(tmp_path):
    """dead-function is a whole-program rule in the LSP: a function used only from a
    SIBLING file (but reachable from main) is not falsely flagged; a function reached
    from nowhere is."""
    root = _two_space_project(tmp_path / "proj")
    (root / "A" / "AP.yon").write_text(
        program("test_lint/test_lsp_dead_function_is_whole_program_1.yon"))
    (root / "B" / "BP.yon").write_text(
        program("test_lint/test_lsp_dead_function_is_whole_program_2.yon"))
    (root / "Entry.yon").write_text(
        program("test_lint/test_lsp_dead_function_is_whole_program_3.yon"))
    r = subprocess.run([str(LSP), "--check", str(root / "A" / "AP.yon")],
                       capture_output=True, text=True, timeout=60)
    out = r.stdout + r.stderr
    assert "shared" not in out, f"cross-file-used function flagged dead: {out}"
    assert "W1001" in out and "truly_dead" in out, out


@pytest.mark.skipif(not LSP.exists(), reason="yon_lsp not built")
def test_lsp_surfaces_lint_as_warning(tmp_path):
    """The LSP reports lint under its stable code, as a Warning (not an error)."""
    f = tmp_path / "x.yon"
    f.write_text(program("test_lint/test_lsp_surfaces_lint_as_warning_1.yon"))
    r = subprocess.run([str(LSP), "--check", str(f)],
                       capture_output=True, text=True, timeout=60)
    out = r.stdout + r.stderr
    assert re.search(r"W1001 warn", out), out
