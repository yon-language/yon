"""Gate del refactor place. Stadio 0: lo specimen arm+campi e' RIFIUTATO
con il failwith noto. Questo test verra' FLIPPATO a verde allo stadio 3;
fino ad allora pinna il rosso, cosi' nessuna sessione puo' dichiarare
chiuso il refactor senza spostarlo."""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"
SPEC = ROOT / "examples" / "union_field_obligation"


def test_union_field_obligation_still_red():
    r = subprocess.run([str(EMIT), str(SPEC)], capture_output=True, timeout=60)
    assert r.returncode != 0, (
        "lo specimen arm+campi COMPILA: o lo stadio 3 e' stato raggiunto "
        "(flippare questo test a verde) o qualcosa e' cambiato senza piano")
    assert b"cannot yet be mixed" in r.stderr + r.stdout, (
        f"specimen rosso ma per il motivo SBAGLIATO (atteso il failwith "
        f"arm+campi):\n{(r.stderr or r.stdout).decode(errors='replace')[-400:]}")
