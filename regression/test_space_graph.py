"""The static Space communication graph gate.

Runs the frontend graph extractor (frontend/test_space_graph.exe) on a real
project fixture and checks the four static properties the pass exists to compute:
an arc is present, an isolated Space is recognized, a cycle is detected, and, the
load-bearing one, a Space reached ONLY by an import is NOT isolated.

That last check is the pin for the decision the graph rests on: the
communication graph has two edge families, wire AND import, and the in/out-degree
must sum both. If a future edit dropped import edges from the degree, the
only-imported Space `D` would show up as isolated (and a 1.2 death-watch built on
this would reclaim a Space that still receives dispatch calls). This test fails
the moment that regression happens.

The fixture (regression/space_graph/topology): entry wires to A and imports from
D; A and B wire to each other (a cycle); C has no arcs (isolated); D is reached
only by the import from entry.
"""
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
EXE = ROOT / "frontend" / "_build" / "default" / "test_space_graph.exe"
FIXTURE = ROOT / "regression" / "space_graph" / "topology"


def _dump() -> str:
    r = subprocess.run([str(EXE), str(FIXTURE)], capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, f"extractor failed:\n{r.stderr}"
    return r.stdout


def _edges(dump: str) -> set[tuple[str, str, str]]:
    out = set()
    for m in re.finditer(r"^\s*(\S+) -> (\S+)\s+\[(wire|import)\]\s*$", dump, re.M):
        out.add((m.group(1), m.group(2), m.group(3)))
    return out


def _isolated(dump: str) -> set[str]:
    m = re.search(r"^isolated \(static-reclaimable\): (.*)$", dump, re.M)
    assert m, "dump has no isolated line"
    body = m.group(1).strip()
    return set() if body == "(none)" else {x.strip() for x in body.split(",")}


def _cycles_line(dump: str) -> str:
    m = re.search(r"^cycles: (.*)$", dump, re.M)
    assert m, "dump has no cycles line"
    return m.group(1).strip()


@pytest.mark.skipif(not EXE.exists() or not FIXTURE.exists(),
                    reason="graph extractor not built or fixture missing")
def test_arc_present():
    """A declared wire shows up as an arc between the right Spaces."""
    assert ("A", "B", "wire") in _edges(_dump())


@pytest.mark.skipif(not EXE.exists() or not FIXTURE.exists(),
                    reason="graph extractor not built or fixture missing")
def test_import_family_is_collected():
    """The import arc (entry imports from D) is in the graph, not just wires."""
    assert ("<root>", "D", "import") in _edges(_dump())


@pytest.mark.skipif(not EXE.exists() or not FIXTURE.exists(),
                    reason="graph extractor not built or fixture missing")
def test_isolated_recognized():
    """A Space with no arcs at all is marked isolated (static-reclaimable)."""
    assert "C" in _isolated(_dump())


@pytest.mark.skipif(not EXE.exists() or not FIXTURE.exists(),
                    reason="graph extractor not built or fixture missing")
def test_cycle_detected():
    """The A <-> B cycle is reported, not swallowed as acyclic."""
    line = _cycles_line(_dump())
    assert line != "acyclic" and "A" in line and "B" in line


@pytest.mark.skipif(not EXE.exists() or not FIXTURE.exists(),
                    reason="graph extractor not built or fixture missing")
def test_import_only_space_is_not_isolated():
    """THE pin. `D` is reached only by an import (no wire). It MUST NOT be
    isolated: the import arc gives it in-degree >= 1. If this fails, the in/out
    degree stopped summing the import family, and the reclaimability foundation
    is unsound (a Space that still receives dispatch calls looks reclaimable)."""
    iso = _isolated(_dump())
    assert "D" not in iso, (
        "an import-only Space is marked isolated: the degree calculation is no "
        "longer summing wire AND import edges. This is the soundness hole the "
        "graph exists to prevent."
    )
