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
