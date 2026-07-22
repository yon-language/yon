"""Gate del refactor place — stadio 3 (FLIPPATO, era il rosso pinnato dello
stadio 0). Doppio pin:

  - lo specimen (bracci-place + campo sull'unione, ogni braccio lo espone)
    COMPILA: l'obbligo del campo-sull'unione e' soddisfatto;
  - il gemello negativo (un braccio NON espone il campo) e' rifiutato con il
    messaggio dell'obbligo — mai piu' il failwith del parser.

Una mappa fuori da un coprodotto e' una tupla di mappe: un campo dichiarato
sull'unione e' un obbligo su ogni braccio (yon_place_grammar.md §3.4)."""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"
SPEC = ROOT / "examples" / "union_field_obligation"
REJECT = ROOT / "examples" / "union_field_obligation_reject"


def test_union_field_obligation_compiles():
    r = subprocess.run([str(EMIT), str(SPEC)], capture_output=True, timeout=60)
    assert r.returncode == 0, (
        f"lo specimen sum-of-products NON compila piu' (stadio 3 rotto):\n"
        f"{r.stderr.decode(errors='replace')[-400:]}")
    assert len(r.stdout) > 0, "specimen: exit 0 ma MLIR vuoto"


def test_union_field_obligation_reject_pins_the_obligation():
    r = subprocess.run([str(EMIT), str(REJECT)], capture_output=True, timeout=60)
    assert r.returncode != 0, (
        "il gemello negativo COMPILA: l'obbligo del campo-sull'unione "
        "non morde piu'")
    msg = (r.stderr + r.stdout).decode(errors="replace")
    assert "obligation on every arm" in msg and "balance" in msg, (
        f"gemello rosso ma per il motivo SBAGLIATO (atteso l'obbligo del "
        f"campo-sull'unione):\n{msg[-400:]}")


# ---- stadio 4: clausole nel corpo, `error` come zucchero ----------------

def _emit(path):
    return subprocess.run([str(EMIT), str(path)], capture_output=True, timeout=60)


def test_body_clause_is_the_header_clause(tmp_path):
    """`over` scritto come riga del corpo emette MLIR byte-identico all'header."""
    import shutil
    src = ROOT / "examples" / "c_place_over"
    twin = tmp_path / "twin"
    shutil.copytree(src, twin)
    (twin / "Slice.yon").write_text("place Slice {\n  over Base\n  weight number\n}\n")
    header = _emit(src)
    body = _emit(twin)
    assert header.returncode == 0 and body.returncode == 0, body.stderr[-300:]
    assert header.stdout == body.stdout, "body-clause emette MLIR diverso dall'header"


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
    """error_decl e' morta: `error E ...` passa dalla produzione unica del place."""
    r = _emit(ROOT / "examples" / "error_morphism")
    assert r.returncode == 0, r.stderr[-300:]
