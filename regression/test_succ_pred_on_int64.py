"""The six tests of succ <=> pred on Int64 wait for Z, and they fail for the refusal of the ring.

Int64 is no ring (its sum goes into Int64 + Overflow): the coherence pred(succ(a)) = a that
`succ <=> pred` synthesizes does not convert, and each source is refused by that, with its code and
its words, not by a crash of the emitter nor by another error. The xfail markers and the EMITFAIL
lines of the acceptance baseline record only that they fail; this test records why
(regression/migrations.py).
"""
import subprocess
from pathlib import Path

import pytest

from migrations import (SUCC_PRED_FIELD_SOURCE, SUCC_PRED_FIELD_WORDS, RING_LAW_ON_INT64_CODE, RING_LAW_ON_INT64_WORDS, SUCC_PRED_BLOCK, SUCC_PRED_CODE,
                        SUCC_PRED_SOURCES, SUCC_PRED_WORDS)

ROOT = Path(__file__).resolve().parent.parent
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"

pytestmark = pytest.mark.skipif(not EMIT.exists(), reason="the frontend is not built")


def _refused_for_the_ring(target):
    r = subprocess.run([str(EMIT), str(target)], capture_output=True, text=True, timeout=120)
    out = r.stdout + r.stderr
    assert r.returncode != 0, out[-600:]
    assert "Fatal error" not in out, out[-600:]
    assert f"[{SUCC_PRED_CODE}]" in out and SUCC_PRED_WORDS in out, out[-600:]


@pytest.mark.parametrize("src", SUCC_PRED_SOURCES)
def test_the_source_is_refused_for_the_ring_of_int64(src):
    _refused_for_the_ring(ROOT / src)


def test_the_block_of_the_book_is_refused_for_the_ring_of_int64(tmp_path):
    import test_syntax_triangle as tri
    blocks = [b for b in tri.fenced_yon_blocks() if f"{b[0]}:{tri._stable_id(b[2])}" == SUCC_PRED_BLOCK]
    assert len(blocks) == 1, f"the block {SUCC_PRED_BLOCK} is not in the book"
    f = tmp_path / "block.yon"
    f.write_text(blocks[0][2])
    _refused_for_the_ring(f)


def test_a_ring_law_on_int64_is_refused_for_the_ring(tmp_path):
    """The waiting probe of distributivity on Int64 (test_audit_probes) fails for the same reason."""
    (tmp_path / "yon.toml").write_text('[package]\nname = "ring"\n\n[runtime]\nbackend = "memory"\n')
    (tmp_path / "Entry.yon").write_text(
        "place Entry {\n  fun identity(x: Int64): x * (x + 1) = x * x + x { return clear }\n"
        "  fun main: Number { return 42 }\n}\n")
    r = subprocess.run([str(EMIT), str(tmp_path)], capture_output=True, text=True, timeout=120)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "Fatal error" not in out, out[-600:]
    assert f"[{RING_LAW_ON_INT64_CODE}]" in out and RING_LAW_ON_INT64_WORDS in out, out[-600:]


def test_the_place_iso_on_int64_is_refused_for_the_ring():
    """The four waiting tests of test_dependent_fields: the left_law of Iso on succ and pred."""
    r = subprocess.run([str(EMIT), str(ROOT / SUCC_PRED_FIELD_SOURCE)], capture_output=True, text=True, timeout=120)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "Fatal error" not in out, out[-600:]
    assert f"[{SUCC_PRED_CODE}]" in out and SUCC_PRED_FIELD_WORDS in out, out[-600:]
