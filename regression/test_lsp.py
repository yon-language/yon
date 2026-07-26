"""The language server surfaces the Space-semantic diagnostics, in-process.

The drop check (the diagnostic no other language server can give) lives in the
compiler driver. The LSP is a separate binary that, before this, only parsed and
type-checked a single buffer. These pins prove the LSP -- made project aware --
finds the containing package, runs the WHOLE-PROGRAM drop check with the open
buffer substituted, and reports it under its stable code E3001, without shelling
out to the compiler. And that a well-placed drop raises nothing.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
LSP = ROOT / "frontend" / "_build" / "default" / "yon_lsp.exe"
FIXTURE = ROOT / "regression" / "keyword_coverage" / "drop_reclaim"

_ILLEGAL = """\
import svc::d_op from D
place Entry { }
fun main(): Number {
  drop D
  be r holds d_op(5)
  return r - r
}
"""

_LEGAL = """\
import svc::d_op from D
place Entry { }
fun main(): Number {
  be r holds d_op(5)
  drop D
  return r - r
}
"""


def _check(tmp_path, entry: str) -> str:
    proj = tmp_path / "proj"
    shutil.copytree(FIXTURE, proj)
    (proj / "Entry.yon").write_text(entry)
    r = subprocess.run([str(LSP), "--check", str(proj / "Entry.yon")],
                       capture_output=True, text=True, timeout=60)
    return r.stdout + r.stderr


@pytest.mark.skipif(not LSP.exists() or not FIXTURE.exists(),
                    reason="yon_lsp or fixture missing")
def test_lsp_surfaces_drop_code(tmp_path):
    out = _check(tmp_path, _ILLEGAL)
    assert "E3001" in out, out
    assert "Space D" in out, out


@pytest.mark.skipif(not LSP.exists() or not FIXTURE.exists(),
                    reason="yon_lsp or fixture missing")
def test_lsp_no_false_drop_on_legal(tmp_path):
    out = _check(tmp_path, _LEGAL)
    assert "E3001" not in out, out


def _two_world_project(root: Path) -> Path:
    (root / "A").mkdir(parents=True)
    (root / "B").mkdir(parents=True)
    (root / "yon.toml").write_text(
        '[package]\nname = "bnd"\n[runtime]\nbackend = "separate"\n'
        '[world.W1]\nobjects = ["X"]\nspaces  = ["A"]\n'
        '[world.W2]\nobjects = ["Y"]\nspaces  = ["B"]\n')
    (root / "A" / "Topos.yon").write_text("topos TA where { }\n")
    (root / "B" / "Topos.yon").write_text("topos TB where { }\n")
    (root / "B" / "BP.yon").write_text(
        "fun b_op(x: Number): Number { return x + 1 }\nplace BP { }\n")
    # A (world W1) imports from B (world W2): the wire crosses a world boundary.
    a = root / "A" / "AP.yon"
    a.write_text(
        "import svc::b_op from B\nplace AP { }\n"
        "fun a_op(x: Number): Number { be r holds b_op(x)  return r }\n")
    return a


@pytest.mark.skipif(not LSP.exists(), reason="yon_lsp missing")
def test_lsp_surfaces_wire_boundary_code(tmp_path):
    """The other Space-semantic crown jewel: a wire crossing a world boundary is
    surfaced under its stable code E3010, at the import site, in-process."""
    a = _two_world_project(tmp_path / "proj")
    r = subprocess.run([str(LSP), "--check", str(a)],
                       capture_output=True, text=True, timeout=60)
    out = r.stdout + r.stderr
    assert "E3010" in out and "boundary" in out, out


def _world_project(root: Path):
    """A one-world package: space A (world W) with an UNANNOTATED place, a topos,
    and a root entry. Compiles clean; the place's world is a filesystem fact."""
    (root / "A").mkdir(parents=True)
    (root / "yon.toml").write_text(
        '[package]\nname = "w"\n[runtime]\nbackend = "separate"\n'
        '[world.W]\nobjects = ["X"]\nspaces  = ["A"]\n')
    (root / "A" / "Topos.yon").write_text("topos TA where { }\n")
    (root / "A" / "AP.yon").write_text(
        "place AP { }\nfun a_op(x: Number): Number { return x + 1 }\n")
    (root / "Entry.yon").write_text(
        "place Entry { }\nfun main(): Number { return 0 }\n")
    return root


@pytest.mark.skipif(not LSP.exists(), reason="yon_lsp missing")
def test_lsp_no_false_cannot_infer_world_on_space_file(tmp_path):
    """A package file type-checked alone must NOT trip "cannot infer world": an
    unannotated place inherits its space's world (a project fact), so the LSP binds
    it from the manifest before type-checking, exactly as the compiler does."""
    root = _world_project(tmp_path / "proj")
    for f in [root / "A" / "AP.yon", root / "Entry.yon"]:
        r = subprocess.run([str(LSP), "--check", str(f)],
                           capture_output=True, text=True, timeout=60)
        out = r.stdout + r.stderr
        assert "cannot infer world" not in out, f"{f}: {out}"
        assert "unknown world" not in out, f"{f}: {out}"
        assert "E2001" not in out, f"{f}: {out}"


def _two_boundary_files_same_pos(root: Path) -> Path:
    """A/AP.yon and B/BP.yon each import a DIFFERENT W2 space, both at the same
    line/col. Returns A/AP.yon. Each import crosses the W1->W2 boundary (E3010)."""
    for d in ["A", "B", "OtherX", "OtherY"]:
        (root / d).mkdir(parents=True)
    (root / "yon.toml").write_text(
        '[package]\nname = "col"\n[runtime]\nbackend = "separate"\n'
        '[world.W1]\nobjects = ["P"]\nspaces  = ["A", "B"]\n'
        '[world.W2]\nobjects = ["Q"]\nspaces  = ["OtherX", "OtherY"]\n')
    for d, t in [("A", "TA"), ("B", "TB"), ("OtherX", "TX"), ("OtherY", "TY")]:
        (root / d / "Topos.yon").write_text(f"topos {t} where {{ }}\n")
    (root / "OtherX" / "XP.yon").write_text(
        "fun fx(x: Number): Number { return x }\nplace XP { }\n")
    (root / "OtherY" / "YP.yon").write_text(
        "fun fy(x: Number): Number { return x }\nplace YP { }\n")
    a = root / "A" / "AP.yon"
    a.write_text("import svc::fx from OtherX\nplace AP { }\n")
    (root / "B" / "BP.yon").write_text("import svc::fy from OtherY\nplace BP { }\n")
    return a


@pytest.mark.skipif(not LSP.exists(), reason="yon_lsp missing")
def test_lsp_attributes_boundary_by_file_not_position(tmp_path):
    """Per-file attribution is EXACT: two files carry a boundary error at the same
    line/col; opening one shows only ITS error (OtherX), never the sibling's
    (OtherY). A (line, col) heuristic would leak the sibling; the file each location
    carries does not."""
    a = _two_boundary_files_same_pos(tmp_path / "proj")
    r = subprocess.run([str(LSP), "--check", str(a)],
                       capture_output=True, text=True, timeout=60)
    out = r.stdout + r.stderr
    assert "E3010" in out and "OtherX" in out, out
    assert "OtherY" not in out, f"sibling file's boundary leaked in: {out}"


@pytest.mark.skipif(not LSP.exists(), reason="yon_lsp missing")
def test_lsp_still_reports_genuine_type_error_in_package_file(tmp_path):
    """World-binding must not silence real type errors: an undefined identifier in
    a package file is still reported under E2001."""
    root = _world_project(tmp_path / "proj")
    (root / "A" / "AP.yon").write_text(
        "place AP { }\nfun a_op(x: Number): Number { return zzz + 1 }\n")
    r = subprocess.run([str(LSP), "--check", str(root / "A" / "AP.yon")],
                       capture_output=True, text=True, timeout=60)
    out = r.stdout + r.stderr
    assert "E2001" in out and "zzz" in out, out


def _cross_file_call_project(root: Path):
    """Two spaces in one world: A/AP.yon calls gee() defined in B/BP.yon."""
    (root / "A").mkdir(parents=True)
    (root / "B").mkdir(parents=True)
    (root / "yon.toml").write_text(
        '[package]\nname = "xf"\n[runtime]\nbackend = "separate"\n'
        '[world.W]\nobjects = ["X", "Y"]\nspaces  = ["A", "B"]\n')
    (root / "A" / "Topos.yon").write_text("topos TA where { }\n")
    (root / "B" / "Topos.yon").write_text("topos TB where { }\n")
    (root / "A" / "AP.yon").write_text(
        "place AP { }\nfun a_op(n: Number): Number { return gee(n) + 1 }\n")
    (root / "B" / "BP.yon").write_text(
        "place BP { }\nfun gee(n: Number): Number { return n * 2 }\n")
    # main uses a_op so the project is lint-clean (no unused-function warnings);
    # these tests are about cross-file type resolution, not lint.
    (root / "Entry.yon").write_text(
        "place Entry { }\nfun main(): Number { return a_op(1) }\n")
    return root


@pytest.mark.skipif(not LSP.exists(), reason="yon_lsp missing")
def test_lsp_resolves_cross_file_reference(tmp_path):
    """A function defined in a sibling file resolves: the LSP type-checks the WHOLE
    package, so A calling B's `gee` is no longer a false "unknown function"."""
    root = _cross_file_call_project(tmp_path / "proj")
    r = subprocess.run([str(LSP), "--check", str(root / "A" / "AP.yon")],
                       capture_output=True, text=True, timeout=60)
    out = r.stdout + r.stderr
    assert "OK: no errors" in out, out


@pytest.mark.skipif(not LSP.exists(), reason="yon_lsp missing")
def test_lsp_type_error_attributes_to_owning_file(tmp_path):
    """A genuine type error is reported on the file that OWNS it, and does not leak
    onto a clean sibling that references it -- whole-program check, per-file view."""
    root = _cross_file_call_project(tmp_path / "proj")
    (root / "B" / "BP.yon").write_text(
        "place BP { }\nfun gee(n: Number): Number { return zzz }\n")
    b = subprocess.run([str(LSP), "--check", str(root / "B" / "BP.yon")],
                       capture_output=True, text=True, timeout=60)
    bout = b.stdout + b.stderr
    assert "E2001" in bout and "zzz" in bout, bout
    a = subprocess.run([str(LSP), "--check", str(root / "A" / "AP.yon")],
                       capture_output=True, text=True, timeout=60)
    aout = a.stdout + a.stderr
    assert "zzz" not in aout and "OK: no errors" in aout, aout
