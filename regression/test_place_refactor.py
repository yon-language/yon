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
