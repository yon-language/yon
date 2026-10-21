"""Kernel interpreter <-> native binary differential (de Bruijn criterion).

Every RAN example of baseline_exitcodes.txt is computed twice, independently:

  KERNEL  : frontend/eval_runner.exe --trace evaluates the source with the kernel
            reducer (Builtins.reduce_with_builtins) and prints `EXIT n`.
  NATIVE  : the compiled binary's exit code, pinned in baseline_exitcodes.txt.
            test_yon_pipeline::test_example proves the binary still produces it,
            so this module does not recompile the corpus.

A disagreement means the kernel and the compiled binary compute different values:
a back-end miscompile or a kernel bug. This is also the judge for reduction-kernel
changes (subst, beta, the de Bruijn form of reduce) that the native exit-code
regression does not exercise.

The interpreter is incomplete for the imperative / effectful / stdlib layer, and it
says so in one of four ways (see interp_ledger.txt): a punt (`EXIT 0` with
"[no extractable value, assuming 0]" on --trace stderr), a refusal ("EVAL
INCOMPLETE", exit 6, for loop / produce / spawn / wire), a rejection by its own
checker, or an uncaught exception. On `iter` / `while` / `produce` / `spawn` /
`wire` / `for every` it refuses, never returns a silent wrong value. An
interpreter that evaluates the imperative layer turns INCOMPLETE rows into AGREE
rows.

interp_ledger.txt pins the classification, one row per RAN example:
  - an AGREE example must print `EXIT n` == native, with no punt;
  - an INCOMPLETE example must self-report, in the pinned way;
  - a value different from native without a self-report fails in every case;
  - an INCOMPLETE example that starts agreeing fails with "update the ledger",
    so the ledger cannot go stale;
  - the ledger rows and the RAN set must match exactly, both directions.

Layer/kind: ocaml / functional.
"""
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
EXAMPLES = ROOT / "examples"
NATIVE = Path(__file__).resolve().parent / "baseline_exitcodes.txt"
LEDGER = Path(__file__).resolve().parent / "interp_ledger.txt"
EVR = ROOT / "frontend" / "_build" / "default" / "eval_runner.exe"

HOWS = ("punt", "refused", "type-error", "crash")
_EXIT = re.compile(r"^EXIT (\d+)\s*$", re.M)


def _native():
    """name -> native exit code, for every RAN row of baseline_exitcodes.txt."""
    out = {}
    for line in NATIVE.read_text().splitlines():
        parts = line.split()
        if parts and parts[0] == "RAN":
            out[parts[1]] = int(parts[2].split("=")[1])
    return out


def _ledger():
    """Return (rows, errors). rows: name -> ("AGREE", None) | ("INCOMPLETE", how);
    errors: the malformed or duplicated lines, for test_ledger_rows_are_well_formed."""
    rows, errors = {}, []
    for i, line in enumerate(LEDGER.read_text().splitlines(), 1):
        body = line.split("#", 1)[0].split()
        if not body:
            continue
        ok = (body[0] == "AGREE" and len(body) == 2) or (
            body[0] == "INCOMPLETE" and len(body) == 3 and body[2] in HOWS)
        if not ok:
            errors.append(f"line {i}: {line!r}")
        elif body[1] in rows:
            errors.append(f"line {i}: duplicate row for {body[1]}")
        else:
            rows[body[1]] = (body[0], body[2] if len(body) == 3 else None)
    return rows, errors


_NATIVE = _native()
_ROWS, _ERRORS = _ledger()


@pytest.fixture(scope="session", autouse=True)
def _built():
    if not EVR.exists():
        pytest.fail(f"{EVR} is missing: build it first (dune build --root frontend)")


def _source(name):
    """An example is a directory PROJECT (examples/<name>/) or a single file
    (examples/<name>.yon); eval_runner accepts both. Prefer the directory."""
    d = EXAMPLES / name
    if d.is_dir():
        return d
    f = EXAMPLES / f"{name}.yon"
    assert f.exists(), f"example {name} is RAN in baseline_exitcodes.txt but has no source"
    return f


def _interpret(src):
    """Run eval_runner once. Returns (observed, detail): observed is ("value", n)
    for a plain `EXIT n`, or ("self-report", how) when the interpreter says it did
    not evaluate the program; detail is the tail of its output, for messages."""
    try:
        r = subprocess.run([str(EVR), "--trace", str(src)],
                           capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        pytest.fail(f"eval_runner did not terminate within 120 s on {src}")
    out, err = r.stdout, r.stderr
    detail = (f"rc={r.returncode}\nstdout tail:\n{out[-600:]}\nstderr tail:\n{err[-600:]}")
    exits = _EXIT.findall(out)
    if "no extractable value" in err:
        return ("self-report", "punt"), detail
    if exits:
        return ("value", int(exits[-1])), detail
    if "EVAL INCOMPLETE" in out + err:
        return ("self-report", "refused"), detail
    if "TYPE ERROR" in out + err:
        return ("self-report", "type-error"), detail
    if "Fatal error" in err:
        return ("self-report", "crash"), detail
    # no EXIT line and none of the known self-reports: it still did not hand back
    # a value, but the way it failed is new and must be classified by hand
    return ("self-report", f"unclassified (rc={r.returncode})"), detail


@pytest.mark.parametrize("name", sorted(_NATIVE))
def test_interp_against_native(name):
    native = _NATIVE[name]
    assert name in _ROWS, (
        f"{name} is RAN in baseline_exitcodes.txt but has no row in {LEDGER.name}")
    pinned, how = _ROWS[name]
    (kind, val), detail = _interpret(_source(name))

    if kind == "value" and val != native:
        pytest.fail(
            f"{name}: the kernel interpreter returned {val} WITHOUT a self-report, the "
            f"native binary exits {native}. A silent wrong value is a back-end or kernel "
            f"bug, whatever the ledger says.\n{detail}")
    if pinned == "AGREE":
        assert kind == "value", (
            f"{name}: pinned AGREE (native {native}) but the interpreter now "
            f"self-reports ({val}).\n{detail}")
        return
    # pinned INCOMPLETE
    if kind == "value":
        pytest.fail(
            f"{name}: pinned INCOMPLETE ({how}) but the interpreter now agrees with "
            f"native ({native}): update the ledger, make the row `AGREE {name}`.")
    assert val == how, (
        f"{name}: pinned INCOMPLETE {how}, the interpreter now self-reports as "
        f"{val}: a change in how it gives up; update the ledger if intended.\n{detail}")


def test_ledger_rows_are_well_formed():
    """Every non-comment line is `AGREE <name>` or `INCOMPLETE <name> <how>`,
    with <how> one of the four self-reports, and no name twice."""
    assert not _ERRORS, f"{LEDGER.name} has malformed rows:\n  " + "\n  ".join(_ERRORS)


def test_ledger_matches_ran_set():
    """The ledger rows are exactly the RAN examples: a RAN example with no row is
    untested, a row that is not RAN is stale."""
    missing = sorted(set(_NATIVE) - set(_ROWS))
    stale = sorted(set(_ROWS) - set(_NATIVE))
    assert not missing and not stale, (
        f"{LEDGER.name} out of sync with baseline_exitcodes.txt:\n"
        f"  RAN without a row: {missing}\n  rows that are not RAN: {stale}")
