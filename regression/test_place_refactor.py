"""The place-refactor gate: a field on a union is an obligation on every arm.
Double pin:

  - the specimen (place-arms + a field on the union, every arm exposing it)
    COMPILES: the field-on-union obligation is satisfied. Pinned elsewhere, by
    test_projects (emit exit 0) and test_yon_pipeline::test_example (RAN exit 0),
    as are examples/error_morphism (`error` as sugar for a marked place) and
    yon_tests/union_sited (a union's site derived from its arms);
  - the negative twin (an arm NOT exposing the field) is rejected with the
    obligation message — never the parser failwith again.

A map out of a coproduct is a tuple of maps: a field declared on the union
is an obligation on every arm."""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"
REJECT = ROOT / "examples" / "union_field_obligation_reject"


def test_union_field_obligation_reject_pins_the_obligation():
    r = subprocess.run([str(EMIT), str(REJECT)], capture_output=True, timeout=60)
    assert r.returncode != 0, (
        "the negative twin COMPILES: the field-on-union obligation "
        "no longer bites")
    msg = (r.stderr + r.stdout).decode(errors="replace")
    assert "obligation on every arm" in msg and "balance" in msg, (
        f"twin red but for the WRONG reason (expected the field-on-union "
        f"obligation):\n{msg[-400:]}")


# ---- clauses in the body, `error` as sugar --------------------------------

def _emit(path):
    return subprocess.run([str(EMIT), str(path)], capture_output=True, timeout=60)


def test_body_clause_is_the_header_clause(tmp_path):
    """`over` written as a body line emits MLIR byte-identical to the header."""
    import shutil
    src = ROOT / "examples" / "c_place_over"
    twin = tmp_path / "twin"
    shutil.copytree(src, twin)
    (twin / "Slice.yon").write_text("place Slice {\n  over Base\n  weight Number\n}\n")
    header = _emit(src)
    body = _emit(twin)
    assert header.returncode == 0 and body.returncode == 0, body.stderr[-300:]
    assert header.stdout == body.stdout, "body clause emits different MLIR than the header"


def test_duplicate_clause_rejected(tmp_path):
    import shutil
    src = ROOT / "examples" / "c_place_over"
    twin = tmp_path / "twin"
    shutil.copytree(src, twin)
    (twin / "Slice.yon").write_text(
        "place Slice over Base {\n  over Base\n  weight Number\n}\n")
    r = _emit(twin)
    assert r.returncode != 0
    assert b"declared both in the header and in the body" in r.stderr + r.stdout


# ---- path constructors: a reserved slot ------------------------------------

def test_path_constructor_slot_is_reserved(tmp_path):
    """The grammar accepts the path-arm form and the parser rejects it with a
    clean "path constructor ... not yet enabled" diagnostic: a path constructor
    needs a path-over obligation that the kernel does not check."""
    import shutil
    twin = tmp_path / "twin"
    shutil.copytree(ROOT / "examples" / "inductive_list", twin)
    (twin / "Entry.yon").write_text(
        "place NumList {\n"
        "  this > Nil :U Cons(Number, NumList) :U dup(Number) : Cons(0, Nil) = Nil\n"
        "}\n"
        "place Entry { }\n"
        "fun main(): Number { return 0 }\n")
    r = _emit(twin)
    assert r.returncode != 0, "the reserved path-arm slot COMPILES (fork 2 opened without a plan?)"
    assert b"path constructor" in r.stderr + r.stdout
    assert b"not yet enabled" in r.stderr + r.stdout


# ---- world-guard rule (f): the site of a union is DERIVED from its arms ----

def test_cross_world_union_is_incoherent():
    """Arms in two worlds -> a coproduct across topoi does not exist. The
    SPACE-level guard (E3003) fires first — different worlds always mean
    different spaces — and its diagnostic also names the right arrow (the
    wire). Rule (f)'s Incoherent stays as the deeper net for the one residual
    path (root-file places with diverging inferred worlds)."""
    r = _emit(ROOT / "examples" / "union_cross_world_reject")
    assert r.returncode != 0
    msg = (r.stderr + r.stdout).decode(errors="replace")
    assert ("SAME space" in msg and "wire" in msg) \
        or "needs a geometric morphism, not a coproduct" in msg, msg[-300:]


def test_arm_section_at_union_boundary_upcasts_as_identity():
    """An arm upcasts to its union as identity: an arm section where the union
    is expected emits a subtype_cast that lowers to IDENTITY on the handle (the
    mono costs nothing). The e2e run (exit 7) is pinned by examples/union_upcast
    in the acceptance baseline."""
    r = _emit(ROOT / "examples" / "union_upcast")
    assert r.returncode == 0, (r.stderr.decode(errors="replace"))[-400:]
    assert b"topos.subtype_cast" in r.stdout, "the upcast is not a subtype_cast (identity) anymore"


# ---- a payload arm IS a place ---------------------------------------------

def test_mediatrice_on_arm_requires_full_arity(tmp_path):
    """The mediatrice on a payload arm LOWERS to the arm's spine — the same value hit built. What remains
    guarded is completeness: a spine has full arity, there is no zero-fill,
    so a missing projection is a clean, positioned reject. The working full
    mediatrice is pinned by test_full_circle_no_constructors."""
    import shutil
    twin = tmp_path / "twin"
    shutil.copytree(ROOT / "examples" / "inductive_list", twin)
    (twin / "Entry.yon").write_text(
        "place NumList { this > Nil :U Cons(Number, NumList) }\n"
        "place Entry { }\n"
        "fun main(): Number {\n"
        "  be c := .-> Cons { _1 1 }\n"
        "  return 0\n}\n")
    r = _emit(twin)
    assert r.returncode != 0
    msg = (r.stderr + r.stdout).decode(errors="replace")
    assert "a spine has no zero-fill" in msg and "_2" in msg, msg[-300:]


def test_cross_space_union_rejected_same_world():
    """Same-space doctrine: the space IS the topos. Arms in two spaces of the
    SAME world are still two topoi — a coproduct across spaces does not
    exist; across spaces there is the wire. Project-level check (E3003:
    file->space truth lives there); rule (f) covers the cross-WORLD half."""
    r = _emit(ROOT / "examples" / "union_cross_space_reject")
    assert r.returncode != 0
    msg = (r.stderr + r.stdout).decode(errors="replace")
    assert "must be" in msg and "SAME space" in msg and "wire" in msg, msg[-300:]


# ---- the canonical match: the co-mediatrice pattern -----------------------

def test_record_pattern_matches_by_name(tmp_path):
    """`Cons { _1 as h _2 as t }` binds projections BY NAME (an arm declared
    with positional payloads names them _1.._n) — the mirror of the mediatrice
    `.-> Cons { ... }`. Byte-equal lowering with the positional twin, e2e
    exit 42."""
    import shutil
    a = tmp_path / "rec"; b = tmp_path / "pos"
    prog = ("place NumList { this > Nil :U Cons(Number, NumList) }\n"
            "place Entry { }\n"
            "fun sum(xs: NumList): Number {\n"
            "  return match xs {\n"
            "    Nil => 0,\n"
            "    %s => h + sum(t)\n"
            "  }\n}\n"
            "fun main(): Number {\n"
            "  be xs := hit(Cons, 5, hit(Cons, 37, hit(Nil)))\n"
            "  return sum(xs)\n}\n")
    for d, pat in ((a, "Cons { _1 as h _2 as t }"), (b, "Cons(h, t)")):
        shutil.copytree(ROOT / "examples" / "inductive_list", d)
        (d / "Entry.yon").write_text(prog % pat)
    ra, rb = _emit(a), _emit(b)
    assert ra.returncode == 0, ra.stderr.decode(errors="replace")[-300:]
    assert ra.stdout == rb.stdout, "record pattern lowers differently than the positional twin"


def test_full_circle_no_constructors(tmp_path):
    """The complete new surface, end to end: the mediatrice on a payload arm
    lowers to its SPINE (the same value hit built), the bare nullary name IS
    the point of its terminal arm, the co-mediatrice pattern eliminates.
    No hit, no new, no positional pattern — exit 42. The kernel underneath
    is unchanged (HITConstr spine + HITElim dispatch)."""
    import shutil
    twin = tmp_path / "circle"
    shutil.copytree(ROOT / "examples" / "inductive_list", twin)
    (twin / "Entry.yon").write_text(
        "place NumList { this > Nil :U Cons(Number, NumList) }\n"
        "place Entry { }\n"
        "fun sum(xs: NumList): Number {\n"
        "  return match xs {\n"
        "    Nil => 0,\n"
        "    Cons { _1 as h _2 as t } => h + sum(t)\n"
        "  }\n}\n"
        "fun main(): Number {\n"
        "  be xs := .-> Cons { _1 5 _2 (.-> Cons { _1 37 _2 Nil }) }\n"
        "  return sum(xs)\n}\n")
    r = _emit(twin)
    assert r.returncode == 0, r.stderr.decode(errors="replace")[-400:]
