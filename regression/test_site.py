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
    # filesystem layout: folder = world, file = space (deduction + reconstruction):
    "layout: main.yon is a space in the ROOT world",
    "layout: Orders.yon is space Orders in world Commerce",
    "layout: world.yon is flagged as the world header file of Commerce",
    "reconstruct: emits the world header `world Commerce { Code is Order }`",
    "reconstruct: emits `space Orders in Commerce`",
    "reconstruct: the rebuilt explicit text PARSES with today's parser",
    # the sheaf predicate for the quotient generator (factor through canon):
    "sheaf: salary = f(cohort u) factors through canon -> sheaf",
    "sheaf: salary reading u directly does NOT factor -> rejected",
    "sheaf: a constant field factors trivially -> sheaf",
    "sheaf: a field using u both via canon AND directly does NOT factor",
    "sheaf: identity canon (trivial Rel) accepts every field (Sh = PSh)",
    "sheaf: total Rel (constant canon) rejects a non-constant field",
    "sheaf: total Rel accepts a constant field",
    # surface binding: a place on a quotient world (canon = the rel field projection):
    "quotient_violations: salary & age violate, cohort (the rel) does not",
    "quotient_violations: a place with only the relation field is a sheaf",
    "place_violations: a place on User/cohort flags salary as non-invariant",
    "place_violations: no quotient generator -> no constraint (empty)",
    "place_violations: coproduct world imposes nothing on fields (vacuous)",
    "place_violations: subset world imposes nothing on fields (vacuous)",
]


@pytest.mark.parametrize("prop", PROPERTIES, ids=[p.split(":")[0].split("(")[0].strip() for p in PROPERTIES])
def test_site_property(prop):
    """Each generated-topology property is asserted PASS in the oracle output."""
    _, out = _run()
    assert f"[PASS] {prop}" in out, f"property not PASS: {prop!r}\n{out[-2000:]}"


# ── end-to-end from source: a place on a quotient world is checked at compile time ──
# These prove the WHOLE thread (filesystem deduction is separate; here the place
# verb is the sheaf reject wired into tycheck on cr_errors / exit 3).
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"


def _emit_rc(src):
    return subprocess.run([str(EMIT), str(src)], capture_output=True, timeout=60).returncode


def test_sheaf_quotient_rejected():
    """A place on `Anon = User / cohort` with a non-invariant field `salary` is
    rejected at compile time (exit 3): it is not a sheaf on the quotient."""
    if not EMIT.exists():
        pytest.skip("frontend not built")
    src = ROOT / "regression" / "yon_tests" / "negative" / "sheaf_quotient.yon"
    assert _emit_rc(src) == 3


def test_sheaf_quotient_ok():
    """A place carrying only the relation field `cohort` is a sheaf -> exit 0."""
    if not EMIT.exists():
        pytest.skip("frontend not built")
    src = ROOT / "regression" / "yon_tests" / "prove" / "sheaf_quotient_ok.yon"
    assert _emit_rc(src) == 0


def test_project_mode_compiles():
    """A package directory (yon.toml + src/) compiles end-to-end. The driver
    enters project mode on the manifest, deduces world from the folder and space
    from the file (filesystem as declaration), reconstructs the explicit form,
    and emits MLIR -> exit 0. The src/ files carry no world/space keywords."""
    if not EMIT.exists():
        pytest.skip("frontend not built")
    proj = ROOT / "regression" / "yon_tests" / "project_min"
    assert _emit_rc(proj) == 0


def test_project_place_world_binding():
    """The inferred place->world binding reaches codegen. In project_min the
    folder Commerce is the only world, so `place Order` (in src/Commerce/) is
    inferred into Commerce and the emitted MLIR binds it there -- not __Default.
    This is the propagation fix: the tycheck resolved the world all along, but
    the desugar/emit used to see the raw __INFER marker."""
    if not EMIT.exists():
        pytest.skip("frontend not built")
    proj = ROOT / "regression" / "yon_tests" / "project_min"
    out = subprocess.run([str(EMIT), str(proj)],
                         capture_output=True, timeout=60).stdout.decode(errors="replace")
    assert "topos.place @Order in @Commerce" in out
    assert "@__Default" not in out
