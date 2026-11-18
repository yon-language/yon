"""A proof fun reaches the kernel check before it leaves the lowering.

A proof fun has no run time, so it is not emitted; but it is lowered to Core and the
dependent checker (core_wf.ml) certifies the theorem it states: the Π over its
parameters with the statement at the end, its paths with their endpoints. Under
YON_CORE_WF=1 the frontend names every proof it saw:

    [core-wf] proof types certified: a, b
    [core-wf] proof types skipped (out of fragment): c (reason)

The test does not pin the totals of the certified types. It reads the names:

  1. every proof fun of the .yon corpus that compiles is named by the kernel,
     certified or skipped with its reason; the test breaks only if a proof fun
     disappears from the kernel again;
  2. the proofs whose statement is inside the checker's fragment are certified by
     name: eta and eps of examples/cx_univalence_distinct, and a proof about a
     path between paths (quadrato).

  3. a proof skipped by the kernel is skipped for a reason of the admitted list
     (SKIP_REASONS below): a construct outside the fragment of core_check (a
     pair, an arm with arguments, an `if`), or the run-time encoding of a sum (a
     point of a sum that reaches the Core as its encoding: the statement the
     checker cannot read, `true`/`false`, a nullary arm read off its place). A
     skip for any other reason fails. The list is meant to reach empty, when the
     kernel judges proofs instead of witnessing them.

The kernel re-check of a proof BODY is not asked here: most proof bodies fall
outside the fragment of core_check and are skipped, and their check is the work
of the cubical kernel.

Frontend-only (YONC_FRONTEND): the certification is decided in the frontend.
"""

import os
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
FRONTEND = Path(
    os.environ.get(
        "YONC_FRONTEND", ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"
    )
)
CORPUS = ("examples", "regression", "meta")
PROOF = re.compile(r"^\s*proof\s+fun\s+([a-z_][A-Za-z0-9_]*)", re.M)


@pytest.fixture(scope="session", autouse=True)
def _built():
    if not FRONTEND.exists():
        pytest.skip(f"frontend emitter not built: {FRONTEND} (run `dune build` in frontend/)")


# The admitted reasons for a skipped proof, each with the arms of the unit it may
# name: "args" (an arm with arguments), "nullary" (an arm without), or none.
SKIP_REASONS = [
    # outside the fragment of core_check
    ("pair", re.compile(r"Pair only checks against a Sigma \(no inference mode\)"), None),
    ("arm with arguments", re.compile(r"unbound (?:__arm_new_)?(\w+)"), "args"),
    ("if", re.compile(r"unbound __if_expr"), None),
    # the run-time encoding of a sum (frontend/desugar.ml, lower_sum_constr)
    ("sum encoding", re.compile(r"the checker cannot read the statement: .+"), None),
    ("sum encoding", re.compile(r"unbound __bool_(?:true|false)"), None),
    ("sum encoding", re.compile(r"unbound __field_(\w+)"), "nullary"),
]


def _kernel_names(stderr: str):
    """The proofs the kernel certified, and those it skipped with their reason."""
    certified, skipped = set(), {}
    for line in stderr.splitlines():
        if line.startswith("[core-wf] proof types certified: "):
            certified |= {n.strip() for n in line.split(": ", 1)[1].split(",")}
        elif line.startswith("[core-wf] proof types skipped (out of fragment): "):
            body = line.split(": ", 1)[1]
            # "name (reason), name (reason)"; a reason holds no parenthesis but its own
            for name, why in re.findall(
                    r"([A-Za-z_][A-Za-z0-9_]*) \(((?:[^()]|\([^()]*\))*)\)", body):
                skipped[name] = why
    return certified, skipped


def _arms(unit: Path):
    """The arms declared in a unit, split by whether they carry arguments."""
    files = [unit] if unit.is_file() else list(unit.rglob("*.yon"))
    args, nullary = set(), set()
    for f in files:
        for clause in re.findall(r"this\s*>\s*([^\n}]*)", f.read_text(errors="replace")):
            for arm in clause.split(":U"):
                words = arm.split()
                if words and re.fullmatch(r"[a-z]\w*", words[0]):
                    (args if len(words) > 1 else nullary).add(words[0])
    return args, nullary


def _admitted(why: str, arms) -> bool:
    args, nullary = arms
    for _, rx, needs in SKIP_REASONS:
        m = rx.fullmatch(why)
        if not m:
            continue
        if needs is None:
            return True
        if (needs == "args" and m.group(1) in args) or (needs == "nullary" and m.group(1) in nullary):
            return True
    return False


def _compile(target: Path):
    env = dict(os.environ, YON_CORE_WF="1")
    r = subprocess.run([str(FRONTEND), str(target)], capture_output=True, timeout=600,
                       env=env, cwd=ROOT)
    return r.returncode, r.stderr.decode(errors="replace")


def _expected_refusals():
    """The corpus files that are refused on purpose, as the other suites declare them."""
    out = set()
    rej = ROOT / "regression" / "yon_tests" / "rejections.txt"
    for line in rej.read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            out.add(line.split("|")[0].strip())
    for exp in (ROOT / "regression" / "canonical_forms").rglob("*.expect"):
        if re.search(r"^status:\s*reject", exp.read_text(), re.M):
            out.add(str(exp.with_suffix(".yon").relative_to(ROOT)))
            out.add(str(exp.with_suffix("").relative_to(ROOT)))
    base = ROOT / "regression" / "baseline_exitcodes.txt"
    for line in base.read_text().splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] == "EMITFAIL":
            out.add(f"examples/{parts[1]}.yon")
            out.add(f"examples/{parts[1]}")
    return out


def _units():
    """Each compilation unit of the corpus that writes a proof fun: the project
    directory that holds the file (the nearest yon.toml), or the file alone."""
    units = {}
    for top in CORPUS:
        for f in (ROOT / top).rglob("*.yon"):
            if (ROOT / "regression" / "refusals") in f.parents or (ROOT / "regression" / "programs") in f.parents:
                continue    # the drafts of the catalogue of refusals (not compiled yet), and the programs
                            # of the Python tests (each test compiles its own, in its own project)
            names = PROOF.findall(f.read_text(errors="replace"))
            if not names:
                continue
            unit = f
            for d in f.parents:
                if d == ROOT:
                    break
                if (d / "yon.toml").exists():
                    unit = d
                    break
            units.setdefault(unit, set()).update(names)
    return units


UNITS = _units()


def test_the_corpus_has_proof_funs():
    assert UNITS, "no proof fun found in the corpus: the scan is broken"


@pytest.mark.parametrize("unit", sorted(UNITS), ids=lambda u: str(u.relative_to(ROOT)))
def test_every_proof_fun_reaches_the_kernel(unit):
    rel = str(unit.relative_to(ROOT))
    rc, err = _compile(unit)
    if rc != 0:
        assert rel in _expected_refusals(), (
            f"{rel} is refused and no suite declares it a refusal:\n{err[-800:]}")
        assert "kernel re-check rejected" not in err, err[-800:]
        return
    certified, skipped = _kernel_names(err)
    seen = certified | set(skipped)
    # a fun of a place is named by the kernel with the place in front: Proofs__comm
    missing = sorted(n for n in UNITS[unit]
                     if n not in seen and not any(s.endswith("__" + n) for s in seen))
    assert not missing, (
        f"proof funs of {rel} that the kernel did not see: {missing}\n{err[-1200:]}")
    arms = _arms(unit)
    unknown = sorted(f"{n} ({why})" for n, why in skipped.items() if not _admitted(why, arms))
    assert not unknown, (
        f"proofs of {rel} skipped for a reason outside the admitted list: {unknown}")


def test_eta_and_eps_are_certified():
    rc, err = _compile(ROOT / "examples" / "cx_univalence_distinct")
    assert rc == 0, err[-800:]
    certified, _ = _kernel_names(err)
    assert {"eta", "eps"} <= certified, err[-800:]


def test_a_path_between_paths_is_certified(tmp_path):
    proj = tmp_path / "quadrato"
    proj.mkdir()
    (proj / "yon.toml").write_text(
        '[package]\nname = "quadrato"\n\n[world.W]\nobjects = ["Bool"]\n\n'
        '[runtime]\nbackend = "memory"\n')
    (proj / "Entry.yon").write_text(
        'place Bool { this > tt :U ff }\nplace Entry {\nproof fun quadrato(a: Bool, p: a = a): p = p { return clear p }\nfun main(): Number {\n  return 1\n}\n}\n')
    rc, err = _compile(proj)
    assert rc == 0, err[-800:]
    certified, _ = _kernel_names(err)
    assert "quadrato" in certified, err[-800:]
