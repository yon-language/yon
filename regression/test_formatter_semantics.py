"""The formatter preserves meaning: formatted source compiles to the same MLIR.

test_formatter.py proves the formatter is idempotent and fail-safe. Neither says
the output MEANS what the input meant: a formatter that drops a statement, swaps
two operands or loses a parenthesis does so idempotently, and the idempotence gate
stays green. This is the missing oracle. For every corpus file the formatter
covers (the same CORPUS as test_formatter.py), the frontend's emitted MLIR of the
formatted source must equal the MLIR of the original, byte for byte after the
normalization below. A file that is REJECTED (the negative fixtures) must be
rejected identically: same exit code, same diagnostic text.

Units: a corpus file inside a package (nearest ancestor with yon.toml) is checked
with its whole package, every .yon in it formatted at once -- a file of a package
cannot be emitted alone (its world is a package fact). A file outside any package
is emitted on its own.

Both sides are emitted from temp copies with the same layout (orig/<name> and
fmt/<name>), so the only path difference is the copy root, which is normalized.
The only other normalization: "[line N, col M]" in diagnostics, because moving
code to its canonical layout legitimately moves where an error points. The MLIR
itself carries no source locations; it is compared verbatim.

Limit of the oracle: it observes what reaches the emitter. Source the frontend
checks but erases (a declared reduction's body, an unused proof-level binding)
can be dropped by a formatter without changing the MLIR; the idempotence and
round-trip gates in test_formatter.py remain the guard there.
"""
import difflib
import re
import shutil
import subprocess
from pathlib import Path

import pytest

from test_formatter import CORPUS, FMT, ROOT

EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"
_CORPUS_ROOTS = (ROOT / "examples", ROOT / "regression" / "yon_tests")


def _package_of(f: Path):
    """The nearest ancestor holding yon.toml, below the corpus roots; else None."""
    for p in f.parents:
        if p in _CORPUS_ROOTS or p == ROOT:
            return None
        if (p / "yon.toml").exists():
            return p
    return None


def _units():
    """One unit per package (a directory) plus one per package-less file."""
    seen, out = set(), []
    for f in CORPUS:
        u = _package_of(f) or f
        if u not in seen:
            seen.add(u)
            out.append(u)
    return out


UNITS = _units()

# Units whose formatting breaks the oracle, each with the law it breaks. Strict:
# an entry whose unit formats correctly fails the run and must go.
# kw_geomorph_full: formatter.ml (TopGeomMorphism) does not print the
# `exact push` / `exact pull` clause (gm_f_lower_star_exact / gm_f_star_exact),
# so the emitted MLIR changes (an i32 constant 1 -> 0); the round-trip
# fail-safe does not see it.
KNOWN_DEFECTS = {
    "examples/kw_geomorph_full": (
        "formatting keeps the exactness of a geomorph's push/pull: the "
        "formatted program emits the same MLIR"),
}


def _params():
    out = []
    for u in UNITS:
        rel = str(u.relative_to(ROOT))
        marks = ([pytest.mark.xfail(strict=True, raises=pytest.fail.Exception,
                                   reason=KNOWN_DEFECTS[rel])]
                 if rel in KNOWN_DEFECTS else [])
        out.append(pytest.param(u, id=rel, marks=marks))
    return out


def _copy(unit: Path, dest_parent: Path) -> Path:
    dest_parent.mkdir(parents=True)
    dest = dest_parent / unit.name
    if unit.is_dir():
        shutil.copytree(unit, dest)
    else:
        shutil.copy2(unit, dest)
    return dest


def _format_in_place(target: Path):
    """Replace every .yon under target (or target itself) by its formatted text.
    Fails if the formatter declines a file: the corpus is 100% covered (see
    test_formatter_is_idempotent_on_corpus), so a decline is a regression there."""
    files = sorted(target.rglob("*.yon")) if target.is_dir() else [target]
    assert files, f"no .yon under {target}"
    for f in files:
        r = subprocess.run([str(FMT), str(f)], capture_output=True, text=True, timeout=60)
        assert r.returncode == 0, f"formatter declined {f}:\n{r.stderr[-400:]}"
        f.write_text(r.stdout)


def _emit(target: Path, copy_root: Path):
    r = subprocess.run([str(EMIT), str(target)], capture_output=True, text=True, timeout=120)

    def norm(s: str) -> str:
        s = s.replace(str(copy_root.resolve()), "<COPY>").replace(str(copy_root), "<COPY>")
        return re.sub(r"\[line \d+, col \d+\]", "[line _, col _]", s)

    return r.returncode, norm(r.stdout), norm(r.stderr)


def _orig_vs_formatted(unit: Path, tmp: Path, mutate=None):
    """Emit the original and the formatted copy. `mutate`, if given, is applied
    to the formatted copy after formatting (used only to prove the oracle bites)."""
    a = _copy(unit, tmp / "orig")
    b = _copy(unit, tmp / "fmt")
    _format_in_place(b)
    if mutate is not None:
        mutate(b)
    return _emit(a, tmp / "orig"), _emit(b, tmp / "fmt")


def _assert_same(unit, ea, eb):
    rc_a, out_a, err_a = ea
    rc_b, out_b, err_b = eb
    assert rc_b == rc_a, (f"{unit}: exit {rc_a} -> {rc_b} after formatting\n"
                          f"orig stderr: {err_a[-400:]}\nfmt stderr: {err_b[-400:]}")
    assert err_b == err_a, f"{unit}: diagnostics changed after formatting"
    if out_b != out_a:
        diff = "".join(list(difflib.unified_diff(
            out_a.splitlines(True), out_b.splitlines(True), "orig", "formatted"))[:60])
        pytest.fail(f"{unit}: formatting changed the emitted MLIR\n{diff}")


@pytest.mark.skipif(not FMT.exists() or not EMIT.exists(), reason="yonfmt or emitter not built")
@pytest.mark.parametrize("unit", _params())
def test_formatting_preserves_emitted_mlir(unit, tmp_path):
    ea, eb = _orig_vs_formatted(unit, tmp_path)
    # A unit that emits nothing would make the comparison vacuous: an accepted
    # unit must have produced a module.
    if ea[0] == 0:
        assert "module" in ea[1], f"{unit}: emitter exited 0 with no module"
    else:
        assert ea[2].strip(), f"{unit}: rejected with no diagnostic"
    _assert_same(unit, ea, eb)


def test_corpus_units_cover_the_formatter_corpus():
    """Every CORPUS file belongs to exactly one unit, so no file escapes the gate."""
    covered = set()
    for u in UNITS:
        covered |= set(u.rglob("*.yon")) if u.is_dir() else {u}
    assert set(CORPUS) <= covered, sorted(map(str, set(CORPUS) - covered))[:10]


_DROP_PROBE = """\
place Entry { }
fun main(): Number {
  mut x := 1
  x <- x + 41
  return x
}
"""


@pytest.mark.skipif(not FMT.exists() or not EMIT.exists(), reason="yonfmt or emitter not built")
def test_oracle_catches_a_dropped_statement(tmp_path):
    """The oracle bites: a "formatter" that silently drops one statement (applied
    after the real one, so the result is still canonical and still compiles) must
    be caught by the same comparison the corpus gate runs."""
    unit = tmp_path / "src" / "probe"
    unit.mkdir(parents=True)
    (unit / "yon.toml").write_text('[package]\nname = "probe"\n\n[runtime]\nbackend = "memory"\n')
    (unit / "Entry.yon").write_text(_DROP_PROBE)

    def drop_reassignment(copy: Path):
        f = copy / "Entry.yon"
        lines = f.read_text().splitlines(True)
        kept = [ln for ln in lines if not re.match(r"\s*x <- x \+ 41\s*$", ln)]
        assert len(kept) == len(lines) - 1, f"probe line not found in:\n{''.join(lines)}"
        f.write_text("".join(kept))

    honest_a, honest_b = _orig_vs_formatted(unit, tmp_path / "honest")
    _assert_same(unit, honest_a, honest_b)  # the real formatter preserves it
    ea, eb = _orig_vs_formatted(unit, tmp_path / "lossy", mutate=drop_reassignment)
    assert ea[0] == 0 and eb[0] == 0, "the lossy copy must still compile"
    with pytest.raises(pytest.fail.Exception, match="changed the emitted MLIR"):
        _assert_same(unit, ea, eb)
