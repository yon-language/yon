"""The stable-diagnostic-code catalog gate.

The catalog (frontend/error_codes.ml) is the single registry of stable diagnostic
codes. The compiler renders every error as "<PREFIX> [<id>]: <message>", so a tool
grabs the code (E3001), not the fragile prose. The invariants checked here:

  1. Every assigned code is UNIQUE and inside its assigned range. Hand-numbering
     invites a collision, and two diagnostics sharing one code silently break the
     tool that keys on it.
  2. Every registered code has a PRODUCER: some test of the suite asserts that a
     real program renders it (or the code sits in NO_PRODUCER, with the reason).
     A registered code nothing can emit is a promise to tools that never holds.
  3. Every code the negative fixtures actually emit is REGISTERED: a diagnostic
     printed with an unregistered id would be a code no catalog explains.

That the CLI carries the code (a real DROP error renders "DROP ERROR [E3001]:")
is pinned by test_drop_check::test_illegal_import_drop_rejected, on the same
fixture and program this module used to repeat.

Exhaustiveness of the variant is enforced by the OCaml build (the `id`/`title`
matches have no wildcard, so a new code fails compilation until it is registered).
"""
import re
import subprocess
from pathlib import Path

import pytest

import compiling_corpus as cc

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "frontend" / "error_codes.ml"
REGRESSION = ROOT / "regression"
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"

# Registered codes with no producer anywhere in the suite, each with the reason.
# This list may only SHRINK: test_every_code_has_a_producer fails when a code
# listed here gains a producer (remove it then) or when a code is missing a
# producer and is not listed (write the fixture, or list it with a reason).
NO_PRODUCER = {
    # Error_codes.File_layout is constructed nowhere in frontend/: the per-file
    # layout rules (Manifest.check_file_layout) are reported under Topos_layout
    # (E4001) by project.ml, so E4003 is registered but unreachable.
    "E4003": "no constructor site: file-layout diagnostics are emitted as E4001",
}

_TOML = '[package]\nname = "{name}"\n{extra}[runtime]\nbackend = "memory"\n'
_ENTRY_OK = "place Entry {\n  fun main(): Number { return 0 }\n}\n"

# Producers that live in THIS module (the grep below skips this file, whose
# NO_PRODUCER table would otherwise count as a producer of what it lists).
LOCAL_PRODUCERS = {"E1002", "E4004"}


def _ids() -> list[str]:
    return re.findall(r'->\s*"(E\d{4}|W\d{4})"', SRC.read_text())


def _project(tmp: Path, entry: str, extra: str = "") -> Path:
    proj = tmp / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML.format(name="codes", extra=extra))
    (proj / "Entry.yon").write_text(entry)
    return proj


def _emit(path) -> tuple[int, str]:
    r = subprocess.run([str(EMIT), str(path)], capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout + r.stderr


@pytest.mark.skipif(not SRC.exists(), reason="error_codes.ml missing")
def test_codes_are_unique():
    ids = _ids()
    assert ids, "no stable codes found in the registry"
    dupes = sorted({c for c in ids if ids.count(c) > 1})
    assert not dupes, f"duplicate stable codes (one code, two meanings): {dupes}"
    out_of_range = [c for c in ids if not re.fullmatch(r"E[1-4]\d{3}|W\d{4}", c)]
    assert not out_of_range, f"codes out of the assigned ranges: {out_of_range}"


# --------------------------------------------------------------------------- #
# Producers kept here: the two codes no other gate emits.
# --------------------------------------------------------------------------- #
@pytest.mark.skipif(not EMIT.exists(), reason="frontend not built")
def test_lexer_error_carries_e1002(tmp_path):
    """A character the lexer has no token for is a LEXICAL error (E1002), not a
    parse error (E1001): the input never reaches the parser."""
    (tmp_path / "ok").mkdir()
    rc, out = _emit(_project(tmp_path / "ok", "place Entry {\n  fun main(): Number { return 0 + 1 }\n}\n"))
    assert rc == 0, f"the control (`+` for `$`) must emit:\n{out[-600:]}"
    proj = _project(tmp_path, "place Entry {\n  fun main(): Number { return 0 $ 1 }\n}\n")
    rc, out = _emit(proj)
    assert rc != 0 and "Fatal error: exception" not in out, out
    assert "PARSE ERROR [E1002]:" in out and "unexpected character $" in out, out


@pytest.mark.skipif(not EMIT.exists(), reason="frontend not built")
def test_manifest_error_carries_e4004(tmp_path):
    """A malformed yon.toml (an unterminated string in a world's spaces list) is a
    MANIFEST error (E4004); the same project with the quote closed emits."""
    world = '[world.W]\nobjects = ["X"]\nspaces  = ["w{close}]\n'
    bad = _project(tmp_path, _ENTRY_OK, world.format(close=""))
    (bad / "w").mkdir()
    (bad / "w" / "Topos.yon").write_text("topos T where {\n}\n")
    rc, out = _emit(bad)
    assert rc != 0 and "Fatal error: exception" not in out, out
    assert "MANIFEST ERROR [E4004]:" in out and "unterminated string" in out, out
    (bad / "yon.toml").write_text(_TOML.format(name="codes", extra=world.format(close='"')))
    rc, out = _emit(bad)
    assert rc == 0, f"the repaired manifest must emit:\n{out[-600:]}"


# --------------------------------------------------------------------------- #
# Registry <-> producers
# --------------------------------------------------------------------------- #
_CODE_LITERAL = re.compile(r"""\[(E\d{4}|W\d{4})\]|["'](E\d{4}|W\d{4})["']""")


def _asserted_codes() -> dict[str, list[str]]:
    """code -> where the suite asserts it: a `[Exxxx]` / "Exxxx" literal in a
    test module (other than this one), or a line of yon_tests/rejections.txt
    (each line is enforced on a real negative fixture)."""
    where: dict[str, list[str]] = {}
    for py in sorted(REGRESSION.glob("**/test_*.py")):
        if py.name == Path(__file__).name:
            continue
        for m in _CODE_LITERAL.finditer(py.read_text()):
            where.setdefault(m.group(1) or m.group(2), []).append(py.name)
    for _path, (code, _frag) in cc.rejections().items():
        where.setdefault(code, []).append("yon_tests/rejections.txt")
    for code in LOCAL_PRODUCERS:
        where.setdefault(code, []).append(Path(__file__).name)
    return where


@pytest.mark.skipif(not SRC.exists(), reason="error_codes.ml missing")
def test_every_code_has_a_producer():
    registered = set(_ids())
    produced = _asserted_codes()
    orphans = sorted(registered - set(produced) - set(NO_PRODUCER))
    assert not orphans, (
        f"registered codes no test produces: {orphans}. Add a fixture that emits "
        "each, or list it in NO_PRODUCER with the reason.")
    stale = sorted(c for c in NO_PRODUCER if c in produced)
    assert not stale, f"NO_PRODUCER lists codes that now have a producer, remove them: {stale}"
    unknown = sorted(set(NO_PRODUCER) - registered)
    assert not unknown, f"NO_PRODUCER lists codes that are not registered: {unknown}"
    phantom = sorted(set(produced) - registered)
    assert not phantom, (
        f"the suite asserts codes the registry does not define: "
        f"{ {c: produced[c] for c in phantom} }")


def _negative_fixtures() -> list[Path]:
    return [ROOT / k for k in cc.rejections()]


@pytest.mark.skipif(not EMIT.exists() or not SRC.exists(), reason="frontend not built")
def test_negative_fixtures_emit_only_registered_codes():
    """Run every negative fixture of rejections.txt and collect every code it
    prints (all its diagnostics, not only the expected one): each must be in the
    registry, and each fixture must print at least one."""
    registered = set(_ids())
    unregistered, codeless = {}, []
    for fx in _negative_fixtures():
        assert fx.exists(), f"rejections.txt names a missing fixture: {fx}"
        _rc, out = _emit(fx)
        codes = set(re.findall(r"\[(E\d{4}|W\d{4})\]", out))
        if not codes:
            codeless.append(f"{cc.rel(fx)}: {out[-200:]}")
        if codes - registered:
            unregistered[cc.rel(fx)] = sorted(codes - registered)
    assert not codeless, "negative fixtures rejected without any stable code:\n" + "\n".join(codeless)
    assert not unregistered, f"diagnostics printed with unregistered codes: {unregistered}"
