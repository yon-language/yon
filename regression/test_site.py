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
    # filesystem layout: folder = space, file = place; world from the toml:
    "layout: Order.yon is a place in space Orders (directory = space)",
    "layout: Main.yon is under the root, in no space",
    "world_decls: the toml world becomes a TopWorld named Commerce",
    "world_decls: Commerce carries object Code is Order as a world_place",
    "space_decls: the Orders directory becomes a bare TopSpace (no world)",
    "space_decls: a root file contributes no space",
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
    # [package] entry: the entrypoint place, declared in the manifest:
    "manifest: [package] entry is parsed into pkg_entry",
    "manifest: no entry declared -> pkg_entry = None",
    "manifest: entry survives alongside [world.*] sections",
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
    src = ROOT / "regression" / "yon_tests" / "negative" / "sheaf_quotient"
    assert _emit_rc(src) == 3


def test_sheaf_quotient_ok():
    """A place carrying only the relation field `cohort` is a sheaf -> exit 0."""
    if not EMIT.exists():
        pytest.skip("frontend not built")
    src = ROOT / "regression" / "yon_tests" / "prove" / "sheaf_quotient_ok"
    assert _emit_rc(src) == 0


def test_project_mode_compiles():
    """A package directory (yon.toml at the root, folders = spaces, files =
    places) compiles end-to-end. The driver enters project mode on the
    manifest, materialises the worlds from the toml, declares each space bare,
    keeps the place bodies, reconstructs the explicit form, and emits MLIR ->
    exit 0. The files carry no world keyword; the space is the folder."""
    if not EMIT.exists():
        pytest.skip("frontend not built")
    proj = ROOT / "regression" / "yon_tests" / "project_min"
    assert _emit_rc(proj) == 0


def test_project_place_world_binding():
    """The inferred place->world binding reaches codegen. In project_min the
    folder Orders is the only space and the toml puts it in world Commerce, so
    `place Order` (in Orders/) is inferred into Commerce and the emitted MLIR
    binds it there -- not __Default. This is the propagation fix: the tycheck
    resolved the world all along, but the desugar/emit used to see __INFER."""
    if not EMIT.exists():
        pytest.skip("frontend not built")
    proj = ROOT / "regression" / "yon_tests" / "project_min"
    out = subprocess.run([str(EMIT), str(proj)],
                         capture_output=True, timeout=60).stdout.decode(errors="replace")
    assert "topos.place @Order in @Commerce" in out
    assert "@__Default" not in out


# ── wire boundary end-to-end: the world from the toml cuts the wire ──────────
# A place inherits the world of its space (directory -> toml). A wire may only
# reach a space of the place's own world; crossing is rejected (exit 3).

def _make_project(d, toml, files):
    """files: dict of relpath -> content; writes yon.toml + files under d."""
    d.mkdir(parents=True, exist_ok=True)
    (d / "yon.toml").write_text(toml)
    for rel, content in files.items():
        p = d / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
    return d


def test_wire_cross_world_rejected(tmp_path):
    """Orders (world Commerce) wiring to Reports (world Analytics) crosses a
    world boundary -> rejected at compile time (exit 3, case C)."""
    if not EMIT.exists():
        pytest.skip("frontend not built")
    toml = ("[package]\nname = \"x\"\n[runtime]\nbackend = \"memory\"\n"
            "[world.Commerce]\nspaces = [\"Orders\"]\nobjects = [\"Order\"]\n"
            "[world.Analytics]\nspaces = [\"Reports\"]\nobjects = [\"Report\"]\n")
    proj = _make_project(tmp_path / "cross", toml, {
        "Orders/Order.yon": "place Order { id Text }\nimport Mod::feed from Reports\n",
        "Reports/Report.yon": "place Report { v Number }\n",
        "Entry.yon": "place Entry { }\nfun main(): Number { return 0 }\n",
    })
    assert _emit_rc(proj) == 3


def test_wire_intra_world_ok(tmp_path):
    """Two spaces in the same world wire freely (exit 0). Also exercises the
    place->space->world inheritance: with two spaces the place world is not
    unique, yet each place is bound through its directory."""
    if not EMIT.exists():
        pytest.skip("frontend not built")
    toml = ("[package]\nname = \"x\"\n[runtime]\nbackend = \"memory\"\n"
            "[world.Commerce]\nspaces = [\"Orders\", \"Billing\"]\n"
            "objects = [\"Order\", \"Account\"]\n")
    proj = _make_project(tmp_path / "intra", toml, {
        "Orders/Order.yon": "place Order { id Text }\nimport Mod::feed from Billing\n",
        "Orders/Topos.yon": "topos OrdersCat where {\n}\n",
        "Billing/Account.yon": "place Account { balance Number }\n",
        "Billing/Topos.yon": "topos BillingCat where {\n}\n",
        "Entry.yon": "place Entry { }\nfun main(): Number { return 0 }\n",
    })
    assert _emit_rc(proj) == 0


def test_wire_orphan_space_rejected(tmp_path):
    """A space directory not listed in any [world] is rejected (exit 3, case D)."""
    if not EMIT.exists():
        pytest.skip("frontend not built")
    toml = ("[package]\nname = \"x\"\n[runtime]\nbackend = \"memory\"\n"
            "[world.Commerce]\nspaces = [\"Orders\"]\nobjects = [\"Order\"]\n")
    proj = _make_project(tmp_path / "orphan", toml, {
        "Orders/Order.yon": "place Order { id Text }\n",
        "Ghost/Lost.yon": "place Lost { x Number }\n",
        "Entry.yon": "place Entry { }\nfun main(): Number { return 0 }\n",
    })
    assert _emit_rc(proj) == 3


def test_entry_default_compiles(tmp_path):
    """No [package] entry: the entrypoint defaults to `place Entry` in the root,
    in the file that defines main (exit 0)."""
    if not EMIT.exists():
        pytest.skip("frontend not built")
    toml = ("[package]\nname = \"x\"\n"
            "[world.Commerce]\nspaces = [\"Orders\"]\nobjects = [\"Order\"]\n")
    proj = _make_project(tmp_path / "entry_default", toml, {
        "Orders/Order.yon": "place Order { id Text }\n",
        "Orders/Topos.yon": "topos OrdersCat where {\n}\n",
        "Entry.yon": "place Entry { }\nfun main(): Number { return 0 }\n",
    })
    assert _emit_rc(proj) == 0


def test_entry_custom_name_compiles(tmp_path):
    """[package] entry sets the entrypoint place name (exit 0)."""
    if not EMIT.exists():
        pytest.skip("frontend not built")
    toml = ("[package]\nname = \"x\"\nentry = \"Boot\"\n"
            "[world.Commerce]\nspaces = [\"Orders\"]\nobjects = [\"Order\"]\n")
    proj = _make_project(tmp_path / "entry_custom", toml, {
        "Orders/Order.yon": "place Order { id Text }\n",
        "Orders/Topos.yon": "topos OrdersCat where {\n}\n",
        "Boot.yon": "place Boot { }\nfun main(): Number { return 0 }\n",
    })
    assert _emit_rc(proj) == 0


def test_entry_absent_rejected(tmp_path):
    """No `place Entry` anywhere -> rejected (exit 3)."""
    if not EMIT.exists():
        pytest.skip("frontend not built")
    toml = ("[package]\nname = \"x\"\n"
            "[world.Commerce]\nspaces = [\"Orders\"]\nobjects = [\"Order\"]\n")
    proj = _make_project(tmp_path / "entry_absent", toml, {
        "Orders/Order.yon": "place Order { id Text }\n",
        "Main.yon": "fun main(): Number { return 0 }\n",   # no place Entry
    })
    assert _emit_rc(proj) == 3


def test_entry_duplicate_rejected(tmp_path):
    """Two `place Entry` declarations -> rejected (exit 3)."""
    if not EMIT.exists():
        pytest.skip("frontend not built")
    toml = "[package]\nname = \"x\"\n"
    proj = _make_project(tmp_path / "entry_dup", toml, {
        "Entry.yon": "place Entry { }\nfun main(): Number { return 0 }\n",
        "Entry2.yon": "place Entry { }\n",
    })
    assert _emit_rc(proj) == 3


def test_entry_in_space_rejected(tmp_path):
    """`place Entry` inside a space (not the root) -> rejected (exit 3)."""
    if not EMIT.exists():
        pytest.skip("frontend not built")
    toml = ("[package]\nname = \"x\"\n"
            "[world.Commerce]\nspaces = [\"Orders\"]\nobjects = [\"Order\"]\n")
    proj = _make_project(tmp_path / "entry_space", toml, {
        "Orders/Entry.yon": "place Entry { }\nfun main(): Number { return 0 }\n",
    })
    assert _emit_rc(proj) == 3


def test_entry_no_main_rejected(tmp_path):
    """`place Entry` whose file has no `fun main` -> rejected (exit 3)."""
    if not EMIT.exists():
        pytest.skip("frontend not built")
    toml = "[package]\nname = \"x\"\n"
    proj = _make_project(tmp_path / "entry_nomain", toml, {
        "Entry.yon": "place Entry { }\n",   # no main
    })
    assert _emit_rc(proj) == 3


def test_entry_main_inside_place(tmp_path):
    """A place body accepts fun: `place Entry { fun main() ... }` puts main
    inside the place, and the entrypoint check is satisfied (exit 0)."""
    if not EMIT.exists():
        pytest.skip("frontend not built")
    toml = ("[package]\nname = \"x\"\n"
            "[world.Commerce]\nspaces = [\"Orders\"]\nobjects = [\"Order\"]\n")
    proj = _make_project(tmp_path / "entry_inside", toml, {
        "Orders/Order.yon": "place Order { id Text }\n",
        "Orders/Topos.yon": "topos OrdersCat where {\n}\n",
        "Entry.yon": ("place Entry {\n"
                      "  fun helper(x: Number): Number { return x + 1 }\n"
                      "  fun main(): Number { return helper(41) }\n"
                      "}\n"),
    })
    assert _emit_rc(proj) == 0
