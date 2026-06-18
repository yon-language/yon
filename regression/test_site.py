"""pytest — the world reified as a Grothendieck site C(W).

Stage 1 of the Yoneda sheafification rebuild. The `world` is a first-class Core
citizen carrying its objects and the GENERATORS of its topology J; `get_J` reads
J off the world's construction:

    world C = A + B        -> coproduct cover         (one generator)
    world Q = W / Rel      -> quotient cover          (one generator)
    world S subset of V    -> dense-inclusion cover   (one generator)
    world P = A * B        -> product (a limit)       -> NO generator
    world W { Code is X }  -> bare                     -> trivial J, Sh = PSh

The topologies on a fixed category form a complete lattice; J(W) is the join of
the generators, so it is insensitive to order and to duplicates.

The logic is fixed by the OCaml oracle test_world_site.ml (built as
test_world_site.exe). This module runs it and asserts each load-bearing property
holds, one node per property, as the readable per-step contract for the site
layer. The generic oracle sweep in test_yon_pipeline.py also runs it; this is
the explicit, named version.
"""

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
ORACLE = ROOT / "frontend" / "_build" / "default" / "test_world_site.exe"


@pytest.fixture(scope="session", autouse=True)
def _built():
    if not ORACLE.exists():
        pytest.skip("frontend not built (cd frontend && dune build)")


def _run():
    r = subprocess.run([str(ORACLE)], capture_output=True, timeout=60)
    return r.returncode, r.stdout.decode(errors="replace")


def test_site_oracle_all_pass():
    """The whole site oracle passes: exit 0 and no failed checks."""
    rc, out = _run()
    assert rc == 0, out[-2000:]
    assert "0 failed" in out, out[-2000:]


# One node per load-bearing property of get_J and the topology lattice.
PROPERTIES = [
    "bare world is_trivial (Sh = PSh)",
    "coproduct: exactly one generator",
    "coproduct generator is the disjoint cover {A,B}",
    "quotient: one quotient-covering generator",
    "subset: one dense-inclusion generator",
    "join carries all generators",
    "join is order-insensitive as a topology",
    "join is idempotent (duplicate generator = same J)",
    "same_topology ignores objects (coarser than world_equal)",
    # step 2 — TopWorld reifies the surface world into the Core site:
    "desugar bare world { Code is X }: trivial J",
    "desugar world = A + B: GenCoproduct [A;B]",
    "desugar world = User / SameCohort: GenQuotient (User, SameCohort)",
    "desugar world subset of Region: GenSubset Region",
    "desugar world = A * B: NO generator (product is a limit, not a cover)",
]


@pytest.mark.parametrize("prop", PROPERTIES, ids=[p.split(":")[0].split("(")[0].strip() for p in PROPERTIES])
def test_site_property(prop):
    """Each generated-topology property is asserted PASS in the oracle output."""
    _, out = _run()
    assert f"[PASS] {prop}" in out, f"property not PASS: {prop!r}\n{out[-2000:]}"
