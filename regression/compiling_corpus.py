"""Shared corpus bookkeeping for the gates that reason ABOUT the corpus.

Two facts several gates need, kept in one place so they cannot drift apart:

  1. Which project directories the suite discovers, and which of them are
     NEGATIVE (must be rejected). test_projects compiles every one.

  2. Which `.yon` files are KNOWN TO COMPILE. A keyword-coverage oracle that
     promises "exercised by a compiling example" may only count a file whose
     compilation some gate asserts; a rejected negative fixture or an EMITFAIL
     example exercises nothing. Each rule below names the gate that asserts the
     compile, so the set is exactly as trustworthy as those gates:

       - examples marked RAN in baseline_exitcodes.txt
             (test_yon_pipeline::test_example: compile + run + exit code)
       - every .yon of a POSITIVE project discovered here, its vendored
         yon_modules included (test_projects: emit exit 0)
       - regression/keyword_coverage/*.yon
             (test_yon_coverage::test_coverage_example_emits: emit exit 0)
       - regression/yon_tests/prove/*.yon and runtime/*.yon
             (test_yon_selfhost: proof type-checks / binary exits 0)

     Loose cross_space/*.yon files and their yon_modules are compiled only by
     cross_space/run.sh (tier 2), never by a pytest gate, so they do not count.

  3. The rejection expectations (yon_tests/rejections.txt): for every negative
     fixture, the stable code and a message fragment it must be rejected with.

This module is a helper, not a test module (no test_ prefix).
"""
import glob
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXAMPLES = ROOT / "examples"
BASELINE = ROOT / "regression" / "baseline_exitcodes.txt"
YON_TESTS = ROOT / "regression" / "yon_tests"
KEYWORD_COVERAGE = ROOT / "regression" / "keyword_coverage"
REJECTIONS = YON_TESTS / "rejections.txt"

PROJECT_ROOTS = ["examples", "regression/yon_tests", "regression/book",
                 "regression/keyword_coverage", "regression/cross_space"]


def discover_projects() -> list[str]:
    """Every project dir (a yon.toml) under PROJECT_ROOTS. `project_min` is
    covered by test_site.py and skipped here."""
    dirs = set()
    for r in PROJECT_ROOTS:
        for toml in glob.glob(str(ROOT / r / "**" / "yon.toml"), recursive=True):
            d = os.path.dirname(toml)
            if os.path.basename(d) == "project_min":
                continue
            dirs.add(d)
    return sorted(dirs)


def is_negative(path: str) -> bool:
    """A project is negative if it lives under a `negative/` directory or its
    name contains `reject` or `leak`."""
    name = os.path.basename(path)
    return ("/negative/" in str(path).replace(os.sep, "/")
            or "reject" in name or "leak" in name)


def rel(path) -> str:
    return Path(path).resolve().relative_to(ROOT).as_posix()


def baseline() -> dict[str, object]:
    """example name -> 'EMITFAIL' or the integer exit code it RAN with."""
    out: dict[str, object] = {}
    for line in BASELINE.read_text().splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "EMITFAIL":
            out[parts[1]] = "EMITFAIL"
        elif parts[0] == "RAN":
            out[parts[1]] = int(parts[2].split("=")[1])
    return out


def rejections() -> dict[str, tuple[str, str]]:
    """relative fixture path -> (stable code, message fragment).

    Format of yon_tests/rejections.txt, one fixture per line:
        <path relative to the repo root> | <code> | <fragment>
    Blank lines and `#` comments are ignored."""
    out: dict[str, tuple[str, str]] = {}
    for line in REJECTIONS.read_text().splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        path, code, frag = (x.strip() for x in s.split("|", 2))
        assert path not in out, f"rejections.txt lists {path} twice"
        out[path] = (code, frag)
    return out


def compiling_files() -> list[Path]:
    """The .yon files whose compilation a gate asserts (see the module doc)."""
    files: set[Path] = set()
    for name, outcome in baseline().items():
        if outcome == "EMITFAIL":
            continue
        d = EXAMPLES / name
        files |= set(d.glob("**/*.yon")) if d.is_dir() else {EXAMPLES / f"{name}.yon"}
    for proj in discover_projects():
        if not is_negative(proj):
            files |= set(Path(proj).glob("**/*.yon"))
    files |= set(KEYWORD_COVERAGE.glob("*.yon"))
    files |= set((YON_TESTS / "prove").glob("*.yon"))
    files |= set((YON_TESTS / "runtime").glob("*.yon"))
    return sorted(p for p in files if p.is_file())


def rejection_failure(rc: int, out: str, code: str, frag: str) -> str | None:
    """None if `out` is a CLEAN rejection carrying `[code]` and `frag`, else a
    reason. Clean = nonzero exit, no uncaught OCaml exception, not a failure of
    the MLIR stage downstream of the frontend, and ONE diagnostic line carrying
    both the stable code and the fragment (so the fragment cannot be matched
    from an unrelated second error)."""
    if rc == 0:
        return "accepted (exit 0), expected a rejection"
    if "Fatal error: exception" in out:
        return "crashed with an uncaught exception instead of a diagnostic"
    if "stage0.topos.mlir" in out:
        return "rejected downstream (MLIR stage), not by the frontend"
    if f"[{code}]" not in out:
        return f"rejected without the stable code [{code}]"
    if not any(f"[{code}]" in line and frag in line for line in out.splitlines()):
        return f"rejected with [{code}] but not for the expected reason {frag!r}"
    return None
