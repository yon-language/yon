"""The place-refactor gate — stage 3 (FLIPPED; it was stage 0's pinned red).
Double pin:

  - the specimen (place-arms + a field on the union, every arm exposing it)
    COMPILES: the field-on-union obligation is satisfied;
  - the negative twin (an arm NOT exposing the field) is rejected with the
    obligation message — never the parser failwith again.

A map out of a coproduct is a tuple of maps: a field declared on the union
is an obligation on every arm (yon_place_grammar.md §3.4)."""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"
SPEC = ROOT / "examples" / "union_field_obligation"
REJECT = ROOT / "examples" / "union_field_obligation_reject"


def test_union_field_obligation_compiles():
    r = subprocess.run([str(EMIT), str(SPEC)], capture_output=True, timeout=60)
    assert r.returncode == 0, (
        f"the sum-of-products specimen no longer compiles (stage 3 broken):\n"
        f"{r.stderr.decode(errors='replace')[-400:]}")
    assert len(r.stdout) > 0, "specimen: exit 0 but empty MLIR"


def test_union_field_obligation_reject_pins_the_obligation():
    r = subprocess.run([str(EMIT), str(REJECT)], capture_output=True, timeout=60)
    assert r.returncode != 0, (
        "the negative twin COMPILES: the field-on-union obligation "
        "no longer bites")
    msg = (r.stderr + r.stdout).decode(errors="replace")
    assert "obligation on every arm" in msg and "balance" in msg, (
        f"twin red but for the WRONG reason (expected the field-on-union "
        f"obligation):\n{msg[-400:]}")


# ---- stage 4: clauses in the body, `error` as sugar ----------------------

def _emit(path):
    return subprocess.run([str(EMIT), str(path)], capture_output=True, timeout=60)


def test_body_clause_is_the_header_clause(tmp_path):
    """`over` written as a body line emits MLIR byte-identical to the header."""
    import shutil
    src = ROOT / "examples" / "c_place_over"
    twin = tmp_path / "twin"
    shutil.copytree(src, twin)
    (twin / "Slice.yon").write_text("place Slice {\n  over Base\n  weight number\n}\n")
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
        "place Slice over Base {\n  over Base\n  weight number\n}\n")
    r = _emit(twin)
    assert r.returncode != 0
    assert b"declared both in the header and in the body" in r.stderr + r.stdout


def test_error_is_sugar_for_marked_place():
    """error_decl is dead: `error E ...` flows through the single place production."""
    r = _emit(ROOT / "examples" / "error_morphism")
    assert r.returncode == 0, r.stderr[-300:]


# ---- stage 6 (fork 2 = reserved slot): path constructors -----------------

def test_path_constructor_slot_is_reserved(tmp_path):
    """The grammar accepts the path-arm form; the parser rejects it cleanly
    until the path-over obligation is pinned in the kernel. This test flips
    when fork 2 opens."""
    import shutil
    twin = tmp_path / "twin"
    shutil.copytree(ROOT / "examples" / "inductive_list", twin)
    (twin / "Entry.yon").write_text(
        "place List {\n"
        "  this > Nil :U Cons(number, List) :U dup(number) : Cons(0, Nil) = Nil\n"
        "}\n"
        "place Entry { }\n"
        "fun main(): number { return 0 }\n")
    r = _emit(twin)
    assert r.returncode != 0, "the reserved path-arm slot COMPILES (fork 2 opened without a plan?)"
    assert b"path constructor" in r.stderr + r.stdout
    assert b"not yet enabled" in r.stderr + r.stdout


# ---- world-guard rule (f): the site of a union is DERIVED from its arms ----

def test_sited_union_compiles():
    """Arms in one world -> the union's site is derived (Sited), and the
    project compiles. Phase 2 of the ONE world inferrer."""
    r = _emit(ROOT / "regression" / "yon_tests" / "union_sited")
    assert r.returncode == 0, r.stderr.decode(errors="replace")[-300:]


def test_cross_world_union_is_incoherent():
    """Arms in two worlds -> a coproduct across topoi does not exist; the
    diagnostic names the right arrow (a geometric morphism)."""
    r = _emit(ROOT / "examples" / "union_cross_world_reject")
    assert r.returncode != 0
    msg = (r.stderr + r.stdout).decode(errors="replace")
    assert "needs a geometric morphism, not a coproduct" in msg, msg[-300:]


def test_arm_section_at_union_boundary_fails_closed(tmp_path):
    """SOUNDNESS pin: passing an arm section where the union is expected
    TYPECHECKS (the stage-1 mono) but has NO value-level lowering yet — it
    must be a clean reject, never the type-inconsistent MLIR that once
    reached a wrong binary (found live 2026-07-23: exit 1 instead of 7).
    Flips when the value-level injection is designed (cantiere «sezione»)."""
    import shutil
    twin = tmp_path / "sub"
    shutil.copytree(ROOT / "regression" / "yon_tests" / "union_sited", twin)
    (twin / "Entry.yon").write_text(
        "place Entry { }\n"
        "place Account {\n  this > Opened :U Closed\n}\n"
        "fun accept(a: Account): number { return 7 }\n"
        "fun main(): number {\n"
        "  be o holds new Opened { initial 42 }\n"
        "  return accept(o)\n}\n")
    r = _emit(twin)
    assert r.returncode != 0, "the subsumed call EMITS again: either the value-level injection landed (flip this) or the miscompile is back"
    msg = (r.stderr + r.stdout).decode(errors="replace")
    assert "injection along the mono is type-level only" in msg, msg[-300:]
