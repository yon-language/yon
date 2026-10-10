"""The OCaml unit oracles, one pytest node per oracle executable.

Each oracle (frontend/test_*.ml, built as frontend/_build/default/test_*.exe)
runs a batch of internal assertions, prints one line per assertion (`[PASS]` /
`[FAIL]` in most, `ok` / `FAIL` / a tally in a few) and exits 0 iff all hold.

The list of oracles is the build's own: the `test_*` names of the `(names ...)`
stanza in frontend/dune, read from the file, never a glob of _build. A name in
that list whose executable is missing FAILS: a stale or partial build must not
shrink the suite. Collection runs nothing; each node runs its oracle once and
asserts exit 0, no `[FAIL]` line and no non-zero "N failed" tally, quoting the
failing assertion lines in the message.

Oracles with a dedicated module are left to it (DEDICATED below), and
test_dedicated_modules_run_their_oracle checks that each of those modules still
runs that executable, so the exclusion cannot silently become a hole.

Layer/kind: ocaml / unit (every oracle is an isolated module-level assertion).
"""

import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
DUNE = ROOT / "frontend" / "dune"
ORACLE_DIR = ROOT / "frontend" / "_build" / "default"
REGRESSION = Path(__file__).resolve().parent
TIMEOUT = 600

pytestmark = [pytest.mark.ocaml, pytest.mark.unit]

# oracle -> the module that runs it with a stronger, named contract
DEDICATED = {
    "test_world_site": "test_site.py",                 # one node per site property
    "test_surface_fuzz": "test_surface_fuzz.py",       # fixed + rotating seeds
    "test_metatheory_fuzz": "test_metatheory_fuzz.py",  # fixed + rotating seeds
    "test_kernel_independent": "test_kernel_independent.py",
    "test_space_graph": "test_space_graph.py",         # fixture graph + selftest
}

# a line that reports a failed assertion, in any of the oracles' formats
_FAIL_LINE = re.compile(
    r"\[FAIL\]|^\s*FAIL\b|✗|MISMATCH:|RESULT: FAIL|FAILED|\b[1-9]\d* (failed|FAIL)\b")
_TALLY = re.compile(r"\b(\d+) failed\b")


def _dune_oracles():
    """The `test_*` executables the build declares, in declaration order."""
    m = re.search(r"\(names\s+([^)]*)\)", DUNE.read_text())
    assert m, f"no (names ...) stanza in {DUNE}"
    return [n for n in m.group(1).split() if n.startswith("test_")]


ALL_ORACLES = _dune_oracles()
ORACLES = sorted(n for n in ALL_ORACLES if n not in DEDICATED)


@pytest.mark.parametrize("oracle", ORACLES)
def test_oracle(oracle):
    exe = ORACLE_DIR / f"{oracle}.exe"
    assert exe.exists(), (
        f"{exe} is missing although frontend/dune declares it: build first "
        "(dune build --root frontend)")
    try:
        r = subprocess.run([str(exe)], capture_output=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        pytest.fail(f"{oracle} did not finish within {TIMEOUT} s (a hang in the oracle "
                    "or in the code it checks)")
    out = r.stdout.decode(errors="replace") + r.stderr.decode(errors="replace")
    failing = [l.strip() for l in out.splitlines() if _FAIL_LINE.search(l)]
    tally = [int(n) for n in _TALLY.findall(out)]
    assert r.returncode == 0 and not failing and not any(tally), (
        f"{oracle}: exit {r.returncode}, failing assertions:\n  "
        + ("\n  ".join(failing) or "(none printed)")
        + f"\n--- output tail ---\n{out[-1500:]}")


def test_oracle_list_is_not_empty():
    """The dune stanza still declares the oracles this module reads."""
    assert len(ORACLES) >= 40, f"only {len(ORACLES)} oracles parsed from {DUNE}"
    assert set(DEDICATED) <= set(ALL_ORACLES), (
        f"DEDICATED names an oracle frontend/dune no longer builds: "
        f"{sorted(set(DEDICATED) - set(ALL_ORACLES))}")


@pytest.mark.parametrize("oracle,module", sorted(DEDICATED.items()))
def test_dedicated_modules_run_their_oracle(oracle, module):
    """An oracle left out of test_oracle is run by its dedicated module: the
    module exists and points at that executable."""
    src = REGRESSION / module
    assert src.exists(), f"{module} (the dedicated runner of {oracle}) is gone"
    assert f'"{oracle}.exe"' in src.read_text(), (
        f"{module} no longer runs {oracle}.exe: put it back in test_oracle")
