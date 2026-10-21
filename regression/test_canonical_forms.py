"""Canonical forms: the corpus IS the spec, the markdown is a projection, this is the custode.

`regression/canonical_forms/<construct>/` holds executable truth. Each construct has:

  canonical.yon  |  canonical/       the one canonical form; MUST compile to canonical.expect
  dev_<name>.yon |  dev_<name>/       a deviation; MUST behave per dev_<name>.expect

A fixture is a single `.yon` (compiled in file mode) OR a project directory of the same
name (compiled in directory mode) when the construct only exists at project scope, as the
entrypoint rule does. Each `.expect` carries:

  status : accept | reject_clean | accepted_deviation
  exit   : the expected exit code (from the compiler, not assumed)
  match  : an error-message fragment that MUST appear (reject_clean only)

`match` is the whole point: a deviation that fails for the WRONG reason is a false green
dressed as a true one, and `match` forbids it.

  accept        compile succeeds, the program runs and exits `exit`.
  reject_clean  compile FAILS with exit `exit` and stderr containing `match`.
  accepted_deviation
                a deviation the language should reject and the compiler accepts. The
                gate compiles it and asserts it passes (so the ledger says what the
                compiler does). A checker that rejects it makes the fixture fail to
                compile, and the fixture flips to reject_clean with a match: it is then
                the acceptance test of that check.

Three jobs, in order:
  1. Execution     every fixture behaves as its .expect says.
  2. Completeness  every surface production in parser.mly has a construct directory whose
                   canonical.expect `covers:` names it, or an allowlist.txt line.
  3. Generation    CANONICAL-FORMS.md is rebuilt from the directories; `--check` fails on
                   drift. The markdown is never hand-written, so it can never be the source.
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
PARSER = ROOT / "frontend" / "parser.mly"
YONC = ROOT / "toolchain" / "yonc"
TOK_DUMP = ROOT / "frontend" / "_build" / "default" / "tok_dump.exe"
DATA = ROOT / "regression" / "canonical_forms"
ALLOWLIST = DATA / "allowlist.txt"
PROJECTION = ROOT / "regression" / "CANONICAL-FORMS.md"


# --------------------------------------------------------------------------- #
# .expect parsing and fixture discovery
# --------------------------------------------------------------------------- #
def parse_expect(path: Path) -> dict:
    """Single-line `key: value` fields; a `note: |` block scalar is skipped."""
    fields, skip = {}, False
    for line in path.read_text().splitlines():
        if skip:
            if line and not line[0].isspace():
                skip = False
            else:
                continue
        m = re.match(r"^(\w+):\s*(.*)$", line)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if val == "|":
            skip = True
            continue
        fields[key] = val
    return fields


def fixtures():
    """(construct, name, expect_path, target) for every .expect under canonical_forms/."""
    out = []
    for expect in sorted(DATA.glob("*/*.expect")):
        construct = expect.parent.name
        name = expect.stem
        target = expect.parent / name          # directory fixture
        if not target.is_dir():
            target = expect.parent / f"{name}.yon"   # single-file fixture
        out.append((construct, name, expect, target))
    return out


def canonical_covers() -> set[str]:
    """The productions each construct DECLARES it accounts for (advisory doc only)."""
    covered = set()
    for expect in DATA.glob("*/canonical.expect"):
        val = parse_expect(expect).get("covers", "")
        covered |= {p.strip() for p in re.split(r"[,\s]+", val) if p.strip()}
    return covered


_REDUCED_CACHE = None


def reduced_productions() -> set[str]:
    """The productions ACTUALLY reduced when Menhir parses the fixtures.

    This is grammar coverage, not bookkeeping: for every `.yon` under
    canonical_forms/, dump its token names (tok_dump.exe) and feed them to
    `menhir --interpret --interpret-show-cst`, then read the production names off
    the concrete syntax tree. A production only counts if a real fixture makes the
    parser reduce it. Cached per session (Menhir is spawned once per file)."""
    global _REDUCED_CACHE
    if _REDUCED_CACHE is not None:
        return _REDUCED_CACHE
    reduced = set()
    for f in sorted(DATA.rglob("*.yon")):
        toks = subprocess.run([str(TOK_DUMP), str(f)], capture_output=True, text=True)
        if toks.returncode != 0 or not toks.stdout.strip():
            continue
        cst = subprocess.run(["menhir", "--interpret", "--interpret-show-cst", str(PARSER)],
                             input=toks.stdout + "\n", capture_output=True, text=True)
        if "ACCEPT" not in cst.stdout:
            continue
        reduced |= set(re.findall(r"\[([a-z_][a-z_0-9]*):", cst.stdout))
    _REDUCED_CACHE = reduced & parser_productions()
    return _REDUCED_CACHE


def allowlisted() -> set[str]:
    if not ALLOWLIST.exists():
        return set()
    out = set()
    for line in ALLOWLIST.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            out.add(line)
    return out


def parser_productions() -> set[str]:
    return set(re.findall(r"^([a-z_][a-z_0-9]*):", PARSER.read_text(), re.M))


# --------------------------------------------------------------------------- #
# Compilation
# --------------------------------------------------------------------------- #
def _compile_and_run(target: Path, tmp: Path):
    """Return (compile_rc, compile_stderr, run_rc or None)."""
    src = str(target) if target.is_dir() else str(target)
    c = subprocess.run([str(YONC), src, "-o", str(tmp / "b")],
                       capture_output=True, text=True, timeout=120)
    if c.returncode != 0:
        return c.returncode, c.stderr, None
    r = subprocess.run([str(tmp / "b")], capture_output=True, text=True, timeout=30)
    return 0, c.stderr, r.returncode


# =========================================================================== #
# Job 1 — execution
# =========================================================================== #
@pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")
@pytest.mark.parametrize("fx", fixtures(), ids=lambda f: f"{f[0]}/{f[1]}")
def test_fixture_behaves(fx, tmp_path):
    construct, name, expect_path, target = fx
    assert target.exists(), f"{construct}/{name}.expect has no fixture ({target.name})"
    exp = parse_expect(expect_path)
    status = exp.get("status")
    want_exit = int(exp["exit"]) if "exit" in exp else None
    crc, cerr, rrc = _compile_and_run(target, tmp_path)

    if status == "accept":
        assert crc == 0, f"{construct}/{name} (accept) failed to compile:\n{cerr[-400:]}"
        assert rrc == want_exit, f"{construct}/{name} ran to {rrc}, expected {want_exit}"

    elif status == "reject_clean":
        assert crc != 0, f"{construct}/{name} (reject_clean) COMPILED but must be rejected"
        assert crc == want_exit, f"{construct}/{name} reject exit {crc} != expected {want_exit}"
        frag = exp.get("match", "")
        assert frag and frag in cerr, (
            f"{construct}/{name} was rejected, but for the wrong reason: the error did not "
            f"contain `match` fragment {frag!r}. A deviation that fails for the wrong reason "
            f"is a false green.\n--- stderr ---\n{cerr[-500:]}"
        )

    elif status == "accepted_deviation":
        assert crc == 0, (
            f"{construct}/{name} is an accepted deviation and was expected to COMPILE, "
            f"but it failed:\n{cerr[-400:]}\n\nIf the checker now rejects it, flip "
            f"{name}.expect to status: reject_clean and add its match."
        )
        assert rrc == want_exit, f"{construct}/{name} (accepted deviation) ran to {rrc}, expected {want_exit}"

    else:
        pytest.fail(f"{construct}/{name}.expect has unknown status {status!r}")


# =========================================================================== #
# Job 2 — completeness = grammar coverage (every production actually REDUCED)
# =========================================================================== #
@pytest.mark.skipif(not TOK_DUMP.exists() or not shutil.which("menhir"),
                    reason="tok_dump.exe (dune build) or menhir missing")
def test_every_production_reduced():
    """Every non-allowlisted parser.mly production must be REDUCED by some fixture.

    This is what makes 'we test all the syntax' true rather than asserted: not that
    a construct DECLARES it covers a production, but that Menhir, parsing a real
    fixture, actually reduces it. A production that no fixture exercises fails here."""
    target = parser_productions() - allowlisted()
    missing = sorted(target - reduced_productions())
    assert not missing, (
        f"{len(missing)} surface production(s) are covered on paper but NO fixture makes "
        f"the parser reduce them (add a fixture that uses the form, or an allowlist.txt "
        f"line with a reason): {missing}"
    )


# =========================================================================== #
# Job 3 — generation
# =========================================================================== #
def build_projection() -> str:
    prods = parser_productions()
    allow = allowlisted()
    reduced = reduced_productions()
    by_construct: dict[str, list] = {}
    for construct, name, expect_path, _target in fixtures():
        by_construct.setdefault(construct, []).append((name, parse_expect(expect_path)))

    L = []
    L.append("<!-- GENERATED from regression/canonical_forms/ by test_canonical_forms.py.")
    L.append("     Do not edit by hand: the .yon fixtures are the source, this is a projection. -->")
    L.append("")
    L.append("# Canonical forms and their rejected deviations")
    L.append("")
    L.append("One canonical form per construct, and every deviation the compiler rejects, as")
    L.append("EXECUTABLE fixtures under `regression/canonical_forms/`. This page is generated")
    L.append("from them; the `.yon` files are the specification, not this text.")
    L.append("")
    L.append(f"- constructs: **{len(by_construct)}**")
    L.append(f"- productions REDUCED by a fixture (Menhir-verified): "
             f"**{len((prods - allow) & reduced)} / {len(prods - allow)}** "
             f"surface (+{len(allow)} structural allowlisted)")
    debts = sum(1 for rows in by_construct.values() for _, e in rows
                if e.get("status") == "accepted_deviation")
    L.append(f"- deviations rejected: "
             f"**{sum(1 for rows in by_construct.values() for _, e in rows if e.get('status') == 'reject_clean')}**")
    L.append(f"- deviations still accepted (`accepted_deviation`): **{debts}**")
    L.append("")
    L.append("| construct | fixture | status | exit | match |")
    L.append("|---|---|---|---|---|")
    for construct in sorted(by_construct):
        for name, e in sorted(by_construct[construct]):
            L.append("| {c} | `{n}` | {s} | {x} | {m} |".format(
                c=construct, n=name, s=e.get("status", "?"),
                x=e.get("exit", "?"),
                m=f"`{e['match']}`" if e.get("match") else "—"))
    L.append("")
    if debts:
        L.append("## Accepted deviations")
        L.append("")
        L.append("Deviations the language should reject and the compiler accepts. A checker")
        L.append("that rejects one makes its fixture fail to compile; its `.expect` then flips")
        L.append("to `reject_clean` with a `match`, and this gate verifies the check.")
        L.append("")
        for construct in sorted(by_construct):
            for name, e in sorted(by_construct[construct]):
                if e.get("status") == "accepted_deviation":
                    L.append(f"- `{construct}/{name}`")
        L.append("")
    return "\n".join(L) + "\n"


def test_projection_in_sync():
    assert PROJECTION.exists(), (
        "CANONICAL-FORMS.md missing; run `python regression/test_canonical_forms.py`"
    )
    assert PROJECTION.read_text() == build_projection(), (
        "CANONICAL-FORMS.md is stale; regenerate with "
        "`python regression/test_canonical_forms.py`"
    )


if __name__ == "__main__":
    if "--check" in sys.argv:
        cur = PROJECTION.read_text() if PROJECTION.exists() else ""
        if cur != build_projection():
            print("CANONICAL-FORMS.md is stale; run without --check to regenerate.")
            sys.exit(1)
        print("CANONICAL-FORMS.md up to date.")
    else:
        PROJECTION.write_text(build_projection())
        print(f"wrote {PROJECTION.relative_to(ROOT)}")
