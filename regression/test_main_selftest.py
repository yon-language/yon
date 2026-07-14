"""Wire the built-in OCaml self-test suite (frontend/main.ml) into the harness.

main.exe runs 144 known-answer self-tests (kernel eval, tycheck, cubical, HITs,
dispatcher, Heyting/Godel G3, catt, stdlib, move, place-visibility, diagnostics),
exercising a large slice of the frontend that the per-oracle .exe tests do not.

It was ORPHANED: nothing in the harness ran it. Two consequences had accumulated
unnoticed: three Heyting self-tests had rotted to stale Kleene expectations after
the K3 -> Godel G3 fix (main.ml Tests 72/73/75), and the driver printed the failing
summary but still exited 0. Both are fixed; this node keeps them fixed by asserting
the whole suite is green (via the Summary line) and that the process exits 0.

One node on purpose: a regression points here, and the per-test detail is in
main.exe's stdout. Layer/kind: ocaml / functional.
"""
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
MAIN = ROOT / "frontend" / "_build" / "default" / "main.exe"

pytestmark = [pytest.mark.ocaml, pytest.mark.functional]


@pytest.mark.skipif(not MAIN.exists(),
                    reason="main.exe not built (run `dune build` in frontend/)")
def test_ocaml_selftest_suite_all_green():
    r = subprocess.run([str(MAIN)], capture_output=True, text=True, timeout=180)
    out = r.stdout + r.stderr
    m = re.search(r"Summary:\s+(\d+)/(\d+)\s+tests passed", out)
    assert m, f"no Summary line in main.exe output:\n{out[-2000:]}"
    passed, total = int(m.group(1)), int(m.group(2))
    assert passed == total, (
        f"main.exe self-tests: {passed}/{total} passed. Tail:\n{out[-2000:]}"
    )
    # exit-code contract: 0 iff all pass (regression guard for the swallowed-failure bug)
    assert r.returncode == 0, f"main.exe exited {r.returncode} at {passed}/{total}"
