"""Differential gate: the compiler driver and the canonical check_all agree.

The check LOGIC is already one source (both call the same Manifest / Space_liveness
functions); this pins that the ORCHESTRATION agrees too -- for every class, the
driver and Project.check_all flag the SAME stable code, and both stay silent on a
valid project. It is the Yoneda guarantee made a test: the editor (which runs
check_all) can never green a project the compiler rejects, or vice versa, without
this gate going red. It is also the safety net for converging the two orchestrations
into one: if the merge changes what the driver reports, a class here diverges.

Each fixture triggers exactly one class as the driver's first-hit, so the driver's
(truncated) verdict and check_all's (full) verdict coincide.
"""
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"
LSP = ROOT / "frontend" / "_build" / "default" / "yon_lsp.exe"

_MANIFEST_1 = ('[package]\nname="p"\n[runtime]\nbackend="separate"\n'
               '[world.W]\nobjects=["X"]\nspaces=["A"]\n')


def _base(root: Path):
    """A valid single-space project (A) with a root entry."""
    (root / "A").mkdir(parents=True)
    (root / "yon.toml").write_text(_MANIFEST_1)
    (root / "A" / "AP.yon").write_text(
        "fun a_op(x: number): number { return x + 1 }\nplace AP { }\n")
    (root / "A" / "Topos.yon").write_text("topos TA where { }\n")
    (root / "Entry.yon").write_text(
        "place Entry { }\nfun main(): number { return 0 }\n")
    return root


def _mk_ok(root):
    return _base(root)


def _mk_drop(root):
    _base(root)
    (root / "Entry.yon").write_text(
        "import svc::a_op from A\nplace Entry { }\n"
        "fun main(): number { drop A  be r holds a_op(5)  return r - r }\n")
    return root


def _mk_entrypoint(root):
    _base(root)
    (root / "Entry.yon").unlink()
    (root / "main.yon").write_text("fun main(): number { return 0 }\n")
    return root


def _mk_topos(root):
    _base(root)
    (root / "A" / "Topos2.yon").write_text("topos TA2 where { }\n")  # two toposes in A
    return root


def _mk_orphan(root):
    # An on-disk space directory (Orphan) that no [world] lists: case D. The check
    # reads TopSpace nodes, which only the filesystem census carries -- the guard
    # that check_all runs the global orphan check on those, not on the parsed files
    # (where it would be a silent no-op).
    _base(root)
    (root / "Orphan").mkdir()
    (root / "Orphan" / "Topos.yon").write_text("topos TO where { }\n")
    (root / "Orphan" / "OP.yon").write_text(
        "fun o_op(x: number): number { return x + 1 }\nplace OP { }\n")
    return root


def _mk_boundary(root):
    (root / "A").mkdir(parents=True)
    (root / "Bx").mkdir(parents=True)
    (root / "yon.toml").write_text(
        '[package]\nname="p"\n[runtime]\nbackend="separate"\n'
        '[world.W1]\nobjects=["X"]\nspaces=["A"]\n'
        '[world.W2]\nobjects=["Y"]\nspaces=["Bx"]\n')
    (root / "A" / "Topos.yon").write_text("topos TA where { }\n")
    (root / "A" / "AP.yon").write_text(
        "import svc::b_op from Bx\nplace AP { }\n"
        "fun a_op(x: number): number { be r holds b_op(x)  return r }\n")
    (root / "Bx" / "Topos.yon").write_text("topos TB where { }\n")
    (root / "Bx" / "BxP.yon").write_text(
        "fun b_op(x: number): number { return x + 1 }\nplace BxP { }\n")
    (root / "Entry.yon").write_text(
        "place Entry { }\nfun main(): number { return 0 }\n")
    return root


CASES = [
    ("drop", _mk_drop, "E3001"),
    ("entrypoint", _mk_entrypoint, "E4002"),
    ("topos_layout", _mk_topos, "E4001"),
    ("boundary", _mk_boundary, "E3010"),
    ("orphan_space", _mk_orphan, "E3010"),
]


def _codes(text: str) -> set:
    return set(re.findall(r"\[(E\d{4})", text))


def _driver_codes(d: Path) -> set:
    r = subprocess.run([str(EMIT), str(d)], capture_output=True, text=True, timeout=120)
    return _codes(r.stdout + r.stderr)


def _check_all_codes(d: Path) -> set:
    r = subprocess.run([str(LSP), "--check", str(d)], capture_output=True, text=True, timeout=120)
    return _codes(r.stdout + r.stderr)


@pytest.mark.skipif(not EMIT.exists() or not LSP.exists(),
                    reason="compiler or lsp not built")
@pytest.mark.parametrize("name,builder,code", CASES, ids=[c[0] for c in CASES])
def test_driver_and_check_all_agree(tmp_path, name, builder, code):
    d = builder(tmp_path / name)
    dv = _driver_codes(d)
    ca = _check_all_codes(d)
    assert code in dv, f"the driver did not flag {code} for {name}: {dv}"
    assert code in ca, f"check_all did not flag {code} for {name}: {ca}"


@pytest.mark.skipif(not EMIT.exists() or not LSP.exists(),
                    reason="compiler or lsp not built")
def test_valid_project_is_silent_from_both(tmp_path):
    d = _mk_ok(tmp_path / "ok")
    assert _driver_codes(d) == set(), "driver flagged a valid project"
    assert _check_all_codes(d) == set(), "check_all flagged a valid project"
