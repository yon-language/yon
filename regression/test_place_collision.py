"""P1 soundness: a place name that resolves to two different worlds is rejected.

A place symbol is not space-qualified downstream, so two `place Foo` living in
different worlds would silently bind both to the last world written and check one
against the WRONG sheaf condition. The driver (yoner_emit_mlir.ml) detects the
cross-world clash and rejects it loudly (exit 6, "declared in two different worlds")
rather than miscompiling. This builds a two-world project with a duplicated place
name and asserts the rejection; the control renames one place and expects no such
clash.

Needs the full toolchain only to reach the driver's world-binding pass, so it runs
`yonc <dir>`; skips if yonc is absent.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"


@pytest.fixture(scope="session", autouse=True)
def _built():
    if not YONC.exists():
        pytest.skip(f"yonc not found: {YONC}")


def _project(root: Path, second_place: str):
    (root / "sa").mkdir(parents=True, exist_ok=True)
    (root / "sb").mkdir(parents=True, exist_ok=True)
    (root / "yon.toml").write_text(
        '[package]\nname = "dupplace"\n\n'
        '[world.Alpha]\nobjects = ["X"]\nspaces  = ["sa"]\n\n'
        '[world.Beta]\nobjects = ["Y"]\nspaces  = ["sb"]\n\n'
        '[runtime]\nbackend = "memory"\n'
    )
    (root / "Entry.yon").write_text("place Entry { }\nfun main(): Number { return 0 }\n")
    (root / "sa" / "Dup.yon").write_text("place Dup { x Number }\n")
    (root / "sa" / "Topos.yon").write_text("topos AlphaT where {\n}\n")
    (root / "sb" / f"{second_place}.yon").write_text(f"place {second_place} {{ y Number }}\n")
    (root / "sb" / "Topos.yon").write_text("topos BetaT where {\n}\n")


def test_cross_world_place_collision_rejected(tmp_path):
    proj = tmp_path / "dup"
    _project(proj, second_place="Dup")  # same name in world Beta as in world Alpha
    r = subprocess.run(
        [str(YONC), str(proj), "-o", str(proj / "out")], capture_output=True, timeout=120
    )
    assert r.returncode != 0, "duplicated cross-world place name was accepted"
    err = r.stderr.decode(errors="replace")
    assert "two different worlds" in err, f"unexpected rejection reason:\n{err[-600:]}"


def test_distinct_place_names_no_collision(tmp_path):
    proj = tmp_path / "ok"
    _project(proj, second_place="Dup2")  # distinct name -> no cross-world clash
    r = subprocess.run(
        [str(YONC), str(proj), "-o", str(proj / "out")], capture_output=True, timeout=120
    )
    err = r.stderr.decode(errors="replace")
    assert "two different worlds" not in err, f"false collision:\n{err[-600:]}"
