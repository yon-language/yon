"""The guard of the rule of the pair (regression/control_pairs.py).

Every control predicate of the compiler (a code of frontend/error_codes.ml, a certifier found by its
name, the verifier of an MLIR pass) has a test that it accepts and a test that it refuses, the refusal
checked by its code and by the words of its reason; or it is in UNCOVERED, the debt, which only
shrinks. The mended twins of the negative fixtures (the "yes" half of most codes) run here.
"""
import ast
import re
import shutil
import subprocess
from pathlib import Path

import pytest

import control_pairs as CP

ROOT = Path(__file__).resolve().parent.parent
FRONTEND = ROOT / "frontend"
PASSES = ROOT / "mlir" / "passes"
EMIT = FRONTEND / "_build" / "default" / "yoner_emit_mlir.exe"
REJECTIONS = ROOT / "regression" / "yon_tests" / "rejections.txt"

CERTIFIER = re.compile(r"^\s*(?:let|and)(?: rec)? (certify_\w+|\w+_check|factor_through|is_\w+_alias|"
                       r"cell_match)\b", re.M)


def codes():
    src = (FRONTEND / "error_codes.ml").read_text()
    return set(re.findall(r'->\s*"(E\d{4})"', src))


def certifiers():
    out = set()
    for f in sorted(FRONTEND.glob("*.ml")):
        if f.name.startswith("test_"):
            continue
        mod = f.stem.capitalize()
        for name in CERTIFIER.findall(f.read_text()):
            out.add(f"{mod}.{name}")
    return out


def verifiers():
    """The MLIR passes that can fail (signalPassFailure), the lowerings left out."""
    out = set()
    for f in sorted(PASSES.glob("*.cpp")):
        src = f.read_text()
        starts = [m.start() for m in re.finditer(r"\nstruct \w+", src)] + [len(src)]
        for a, b in zip(starts, starts[1:]):
            body = src[a:b]
            arg = re.search(r'getArgument\(\) const (?:override|final) \{\s*return "([^"]+)"', body)
            if arg and "signalPassFailure()" in body and not arg.group(1).startswith("lower-"):
                out.add("mlir:" + arg.group(1))
    return out


def declared():
    """The predicates PAIRS names by their site `file::function`: a predicate by declaration, as
    long as the function is defined in the file."""
    out = set()
    for name, pair in CP.PAIRS.items():
        path, _, fn = pair.site.partition("::")
        if fn and re.search(rf"^\s*(?:let|and)(?: rec)? {re.escape(fn)}\b", (ROOT / path).read_text(), re.M):
            out.add(name)
    return out


def predicates():
    return codes() | (certifiers() - set(CP.NOT_PREDICATES)) | verifiers() | declared()


def test_every_predicate_has_its_pair_or_is_in_the_debt():
    found = predicates()
    missing = sorted(found - set(CP.PAIRS) - set(CP.UNCOVERED))
    assert not missing, ("control predicates with no pair and not in UNCOVERED (write the two "
                         f"tests, or list them with the reason): {missing}")
    both = sorted(set(CP.PAIRS) & set(CP.UNCOVERED))
    assert not both, f"in PAIRS and in UNCOVERED at once (take them out of UNCOVERED): {both}"
    gone = sorted((set(CP.PAIRS) | set(CP.UNCOVERED)) - found)
    assert not gone, f"names that are no longer a control predicate (remove them): {gone}"


def test_the_debt_does_not_grow():
    assert len(CP.UNCOVERED) <= CP.UNCOVERED_AT_MOST, (
        f"UNCOVERED holds {len(CP.UNCOVERED)} names, more than {CP.UNCOVERED_AT_MOST}: the debt only "
        "shrinks; lower UNCOVERED_AT_MOST when a name leaves it")


def _test_source(path, name):
    src = (ROOT / path).read_text()
    for n in ast.walk(ast.parse(src)):
        if isinstance(n, ast.FunctionDef) and n.name == name:
            seg = ast.get_source_segment(src, n) or ""
            return "".join((ast.get_source_segment(src, d) or "") for d in n.decorator_list) + seg
    return None


def _expect(path):
    txt = (ROOT / path).read_text()
    fields = dict(re.findall(r"^(\w+):\s*(.*)$", txt, re.M))
    return fields


def _rejections():
    out = {}
    for line in REJECTIONS.read_text().splitlines():
        if line.startswith("#") or line.count("|") < 2:
            continue
        p, c, w = (x.strip() for x in line.split("|", 2))
        out[p] = (c, w)
    return out


def _half(name, pair, ref, side):
    kind, _, what = ref.partition(":")
    if kind == "py":
        path, _, test = what.partition("::")
        src = _test_source(path, test)
        if src is None:
            return f"{ref}: no such test"
        if "xfail" in src.split("def ", 1)[0]:
            return f"{ref}: an xfail is no half of a pair"
        if side == "no" and (pair.code not in src or pair.words not in src):
            return f"{ref}: the test does not check the code {pair.code} and the words «{pair.words}»"
    elif kind == "ml":
        path, _, test = what.partition("::")
        if test not in (ROOT / path).read_text():
            return f"{ref}: no such unit test"
    elif kind == "fixture":
        if side != "no":
            return f"{ref}: a negative fixture is a «no»"
        got = _rejections().get(what)
        if got is None:
            return f"{ref}: not in rejections.txt"
        if got[0] != pair.code or pair.words not in got[1]:
            return f"{ref}: rejections.txt says {got}, not {pair.code} «{pair.words}»"
    elif kind == "canon":
        e = _expect(what)
        if side == "yes" and e.get("status") != "accept":
            return f"{ref}: not an accepted form"
        if side == "no" and (e.get("code") != pair.code or pair.words not in e.get("match", "")):
            return f"{ref}: the form says {e.get('code')} «{e.get('match')}», not {pair.code} «{pair.words}»"
    elif kind == "twin":
        if side != "yes" or what not in CP.TWINS:
            return f"{ref}: no mended twin {what}"
    else:
        return f"{ref}: unknown kind of half"
    return None


@pytest.mark.parametrize("name", sorted(CP.PAIRS))
def test_each_half_of_a_pair_says_what_it_claims(name):
    pair = CP.PAIRS[name]
    assert pair.yes and pair.no, f"{name}: a pair has a «yes» and a «no»"
    bad = [m for side in ("yes", "no") for ref in getattr(pair, side)
           if (m := _half(name, pair, ref, side))]
    assert not bad, f"{name}: " + "; ".join(bad)


def _mend(tmp, fixture, edits):
    dst = tmp / fixture
    shutil.copytree(ROOT / "regression" / "yon_tests" / "negative" / fixture, dst)
    for f, ed in edits.items():
        if ed == "rename":
            a, b = f.split(">")
            (dst / a).rename(dst / b)
            continue
        p = dst / f
        if ed is None:
            p.unlink()
        elif isinstance(ed, str):
            p.write_text(ed)
        else:
            s = p.read_text()
            for old, new in ed:
                assert s.count(old) == 1, f"{fixture}/{f}: «{old}» is not found once"
                s = s.replace(old, new)
            p.write_text(s)
    return dst


@pytest.mark.skipif(not EMIT.exists(), reason="frontend not built")
@pytest.mark.parametrize("code", sorted(CP.TWINS))
def test_the_mended_fixture_is_accepted(tmp_path, code):
    """The «yes» of the code: its negative fixture with the fault mended compiles; the fixture itself
    is still refused with the code and the words (the «no» of the same pair)."""
    fixture, edits = CP.TWINS[code]
    pair = CP.PAIRS[code]
    neg = ROOT / "regression" / "yon_tests" / "negative" / fixture
    r = subprocess.run([str(EMIT), str(neg)], capture_output=True, text=True, timeout=120)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and f"[{code}]" in out and pair.words in out, out[-800:]
    dst = _mend(tmp_path, fixture, edits)
    r = subprocess.run([str(EMIT), str(dst)], capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, (r.stdout + r.stderr)[-800:]
