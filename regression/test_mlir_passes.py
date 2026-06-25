"""Per-pass UNIT tests for the Yon Topos MLIR passes, driven via topos-opt.

Each Topos pass is exercised in ISOLATION: a minimal, hand-written .mlir
fixture (in regression/mlir_units/) is fed to `topos-opt --<flag> <fixture>`,
and we assert on the process result:

  * checker passes   -> `accept` fixture exits 0;
                        `reject` fixture exits non-zero AND the expected
                        diagnostic (error code or message) appears in stderr.
  * rewrite/lowering -> `in` fixture exits 0 AND stdout matches / does not
                        match a regex (e.g. after --heyting-short-circuit no
                        `topos.heyt_and` op remains).

topos-opt is discovered like test_yon_pipeline.py: env YONC_TOPOS_OPT, else
mlir/build/topos-opt. If it is not built, the whole module is skipped.

This is the `mlir` / `unit` slice of the suite (see regression/conftest.py
markers). Run just this layer with:  pytest -m "mlir and unit"

Every fixture's op syntax is grounded in mlir/TopOps.td assembly formats, the
pass .cpp implementations, and the existing mlir_examples/ fixtures. The Mac
gate runs these live against a real topos-opt build.
"""

import os
import re
import subprocess
from pathlib import Path

import pytest

# This module is the MLIR unit layer. Tag every node explicitly so it is
# selectable with `-m "mlir and unit"` regardless of conftest module maps.
pytestmark = [pytest.mark.mlir, pytest.mark.unit]

ROOT = Path(__file__).resolve().parent.parent
UNITS = Path(__file__).resolve().parent / "mlir_units"
TOPOS = os.environ.get("YONC_TOPOS_OPT") or str(ROOT / "mlir" / "build" / "topos-opt")


@pytest.fixture(scope="session", autouse=True)
def _topos_opt():
    if not Path(TOPOS).exists():
        pytest.skip(f"topos-opt not built: {TOPOS} (run cmake in mlir/build)")


def _run(flag, fixture):
    """Run `topos-opt --<flag> <fixture>` and return the CompletedProcess."""
    path = UNITS / fixture
    assert path.exists(), f"missing fixture {path}"
    return subprocess.run(
        [TOPOS, f"--{flag}", str(path)],
        capture_output=True,
        timeout=60,
    )


def _txt(b):
    return b.decode(errors="replace")


# ---------------------------------------------------------------------------
# Checker passes: accept -> exit 0 ; reject -> non-zero + diagnostic in stderr
# ---------------------------------------------------------------------------
#
# (flag, accept_fixture, reject_fixture, expected_diagnostic_substring)
#
# The diagnostic substring is the EXACT error code (e.g. "TOPOS-E0451") for
# passes that emit one, or a literal message fragment for AlgebraVerifier which
# emits a plain (uncoded) error.
CHECKERS = [
    pytest.param(
        "algebra-verifier",
        "algebra_verifier_accept.mlir",
        "algebra_verifier_reject.mlir",
        "is not in the certified catalog",
        id="algebra-verifier",
    ),
    pytest.param(
        "ccc-equations-check",
        "ccc_equations_check_accept.mlir",
        "ccc_equations_check_reject.mlir",
        "TOPOS-E0451",
        id="ccc-equations-check",
    ),
    pytest.param(
        "topos-giraud-check",
        "giraud_check_accept.mlir",
        "giraud_check_reject.mlir",
        "TOPOS-E0501",
        id="topos-giraud-check",
    ),
    pytest.param(
        "topos-type-preservation",
        "type_preservation_accept.mlir",
        "type_preservation_reject.mlir",
        "TOPOS-E0101",
        id="topos-type-preservation",
    ),
    pytest.param(
        "topos-progress",
        "progress_accept.mlir",
        "progress_reject.mlir",
        "TOPOS-E0102",
        id="topos-progress",
    ),
    pytest.param(
        "topos-localisation-decomp",
        "localisation_decomp_accept.mlir",
        "localisation_decomp_reject.mlir",
        "TOPOS-E0504",
        id="topos-localisation-decomp",
    ),
    pytest.param(
        "topos-internal-lang",
        "internal_lang_accept.mlir",
        "internal_lang_reject.mlir",
        "TOPOS-E0505",
        id="topos-internal-lang",
    ),
]


@pytest.mark.parametrize("flag,accept,reject,diag", CHECKERS)
def test_checker_accepts(flag, accept, reject, diag):
    r = _run(flag, accept)
    assert r.returncode == 0, (
        f"--{flag} on {accept} should accept (exit 0) but exited "
        f"{r.returncode}\nSTDERR:\n{_txt(r.stderr)[-2000:]}"
    )


@pytest.mark.parametrize("flag,accept,reject,diag", CHECKERS)
def test_checker_rejects(flag, accept, reject, diag):
    r = _run(flag, reject)
    assert r.returncode != 0, (
        f"--{flag} on {reject} should reject (non-zero exit) but exited 0\n"
        f"STDOUT:\n{_txt(r.stdout)[-2000:]}"
    )
    err = _txt(r.stderr)
    assert diag in err, (
        f"--{flag} on {reject} rejected, but expected diagnostic "
        f"{diag!r} not found in stderr:\n{err[-2000:]}"
    )


# ---------------------------------------------------------------------------
# Rewrite / lowering passes: in -> exit 0 + stdout regex assertions
# ---------------------------------------------------------------------------
#
# (flag, in_fixture, [(regex, present)], stderr_substr)
#   - present=True: regex MUST match stdout; present=False: regex MUST NOT match
#     (op was eliminated/lowered).
#   - stderr_substr (optional, default None): if given, this literal substring
#     MUST appear in stderr. Some rewrite passes (e.g. structural value
#     numbering) report their effect only on stderr, not in the printed IR.
REWRITES = [
    pytest.param(
        "heyting-short-circuit",
        "heyting_short_circuit_in.mlir",
        [
            (r"topos\.heyt_and", False),  # AND(true,false) folded away
        ],
        None,
        id="heyting-short-circuit",
    ),
    pytest.param(
        "lower-topos-to-standard",
        "lower_topos_to_standard_in.mlir",
        [
            (r"topos\.heyt", False),   # whole topos dialect gone
            (r"arith\.", True),        # replaced by arith ops
        ],
        None,
        id="lower-topos-to-standard",
    ),
    pytest.param(
        "coherence-elimination",
        "coherence_elimination_in.mlir",
        [
            (r"topos\.coherence", False),  # dead coherence erased
        ],
        None,
        id="coherence-elimination",
    ),
    pytest.param(
        "move-composition",
        "move_composition_in.mlir",
        [
            (r"topos\.apply_move", False),  # identity move application elided
            (r"topos\.move @m", True),      # the move declaration stays
        ],
        None,
        id="move-composition",
    ),
    pytest.param(
        "place-fusion",
        "place_fusion_in.mlir",
        [
            (r"@P_b", False),  # duplicate place fused away
            (r"@P_a", True),   # canonical (lex-smallest) place survives
        ],
        None,
        id="place-fusion",
    ),
    pytest.param(
        "reduction-inlining",
        "reduction_inlining_in.mlir",
        [
            # The no-op handler body is inlined and the with_handler erased. We
            # assert only its disappearance: the inner op (a pure, unused
            # topos.heyt) is legitimately DCE'd, so asserting its survival is
            # fragile — the load-bearing effect is that the handler is gone.
            (r"topos\.with_handler", False),
        ],
        None,
        id="reduction-inlining",
    ),
    # (reduction-inlining KEEP negative dropped: it needs a valid topos.op_apply
    #  in the handler body, whose custom assembly format couldn't be grounded
    #  blind; the inline-happens case above already exercises the pass.)
    pytest.param(
        "world-specialization",
        "world_specialization_single_in.mlir",
        [
            (r"topos\.static_world", True),  # single-world: place gets the attr
        ],
        None,
        id="world-specialization-single",
    ),
    pytest.param(
        "world-specialization",
        "world_specialization_multi_in.mlir",
        [
            (r"topos\.static_world", False),  # multi-world: nothing marked
        ],
        None,
        id="world-specialization-multi",
    ),
    pytest.param(
        "structural-value-numbering",
        "structural_vn_in.mlir",
        [
            (r"topos\.heyt_or", True),  # consumer rewired, still present
        ],
        # The collapse itself is reported only on stderr; assert the tally.
        "collassate 1",
        id="structural-value-numbering",
    ),
    pytest.param(
        "lower-topos-extensions",
        "lower_topos_extensions_in.mlir",
        [
            (r"topos\.canonical_subplace", False),  # erased (F5a)
        ],
        None,
        id="lower-topos-extensions",
    ),
]


@pytest.mark.parametrize("flag,fixture,checks,stderr_substr", REWRITES)
def test_rewrite(flag, fixture, checks, stderr_substr):
    r = _run(flag, fixture)
    assert r.returncode == 0, (
        f"--{flag} on {fixture} should succeed (exit 0) but exited "
        f"{r.returncode}\nSTDERR:\n{_txt(r.stderr)[-2000:]}"
    )
    out = _txt(r.stdout)
    for pat, present in checks:
        found = re.search(pat, out) is not None
        if present:
            assert found, (
                f"--{flag} on {fixture}: expected {pat!r} in stdout, absent.\n"
                f"STDOUT:\n{out[-2000:]}"
            )
        else:
            assert not found, (
                f"--{flag} on {fixture}: expected {pat!r} to be gone from "
                f"stdout, still present.\nSTDOUT:\n{out[-2000:]}"
            )
    if stderr_substr is not None:
        err = _txt(r.stderr)
        assert stderr_substr in err, (
            f"--{flag} on {fixture}: expected {stderr_substr!r} in stderr, "
            f"absent.\nSTDERR:\n{err[-2000:]}"
        )
