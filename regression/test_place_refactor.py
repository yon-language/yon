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

def _twin(tmp_path, entry):
    import shutil
    twin = tmp_path / "twin"
    shutil.copytree(ROOT / "examples" / "inductive_list", twin)
    (twin / "Entry.yon").write_text(entry)
    return _emit(twin)


def test_path_constructor_slot_is_refused_and_the_law_shown(tmp_path):
    """A path is not an arm of the clause: it is a cell, a law of the place. Comes back in
    the form with laws when they are constitutive."""
    r = _twin(tmp_path, "place NumList {\n  this > Nil :U dup : Nil = Nil\n}\n"
                        "place Entry { }\nfun main(): Number { return 0 }\n")
    out = r.stderr + r.stdout
    assert r.returncode != 0 and b"E1001" in out and b"law dup" in out, out


def test_record_pattern_on_a_payload_is_refused_and_the_tuple_shown(tmp_path):
    prog = ("place NumList { this > Nil :U Cons Number NumList }\n"
            "place Entry { }\n"
            "fun sum(xs: NumList): Number {\n"
            "  return match xs { Nil => 0, %s => h + sum(t) }\n}\n"
            "fun main(): Number { return sum((5, (37, Nil) ↪ Cons) ↪ Cons) }\n")
    r = _twin(tmp_path, prog % "Cons { _1 as h _2 as t }")
    out = r.stderr + r.stdout
    assert r.returncode != 0 and b"E1001" in out and b"Cons as (x, y)" in out, out


def test_mediatrice_on_arm_is_refused_and_the_injection_shown(tmp_path):
    r = _twin(tmp_path, "place NumList { this > Nil :U Cons Number NumList }\n"
                        "place Entry { }\nfun main(): Number {\n"
                        "  c := .-> Cons { _1 1 }\n  return 0\n}\n")
    out = (r.stderr + r.stdout).decode()
    assert r.returncode != 0 and "E2001" in out and "(x1, x2) ↪ Cons" in out, out


def test_injection_needs_the_whole_payload(tmp_path):
    """A payload arm has full arity: a missing projection is a clean, positioned refusal."""
    import shutil
    twin = tmp_path / "twin"
    shutil.copytree(ROOT / "examples" / "inductive_list", twin)
    (twin / "Entry.yon").write_text(
        "place NumList { this > Nil :U Cons Number NumList }\n"
        "place Entry { }\n"
        "fun main(): Number {\n"
        "  c := 1 ↪ Cons\n"
        "  return 0\n}\n")
    r = _emit(twin)
    assert r.returncode != 0
    assert b"arm Cons: expected 2 payload(s), got 1" in r.stderr + r.stdout


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
        "place NumList { this > Nil :U Cons Number NumList }\n"
        "place Entry { }\n"
        "fun sum(xs: NumList): Number {\n"
        "  return match xs {\n"
        "    Nil => 0,\n"
        "    Cons as (h, t) => h + sum(t)\n"
        "  }\n}\n"
        "fun main(): Number {\n"
        "  xs := (5, ((37, Nil) ↪ Cons)) ↪ Cons\n"
        "  return sum(xs)\n}\n")
    r = _emit(twin)
    assert r.returncode == 0, r.stderr.decode(errors="replace")[-400:]
