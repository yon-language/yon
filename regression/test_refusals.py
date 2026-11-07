"""Every refusal of the runtime is an arm of the prelude's place Refusal.

The place is the source: its arms and the sentence of each. The runtime's
table (runtime/yon_refusals.h) is generated from it; SystemOs.refuse takes an
arm and three words of the occasion, writes "error: " and the sentence with
the words in their places, and exits with code 3. No sentence of refusal is
written by hand in the C, and no abort() is left.

Layer/kind: native / end-to-end.
"""
import re
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
SRC = ROOT / "prelude" / "sys" / "Refusal.yon"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_TOML = '[package]\nname = "probe"\n\n[runtime]\nbackend = "memory"\n'


def _arms_and_sentences():
    sys.path.insert(0, str(ROOT / "tools"))
    import gen_refusals
    return gen_refusals.arms_and_sentences()


def test_the_runtime_table_is_generated_from_the_place():
    r = subprocess.run([sys.executable, str(ROOT / "tools" / "gen_refusals.py"), "--check"],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def test_no_refusal_is_written_by_hand_in_the_c():
    aborts, exits = [], []
    for f in sorted((ROOT / "runtime").glob("*.c")):
        if f.name.startswith(("test_", "bench_", "yon_test_", "tools_")) or f.name == "yon_arena_test.c":
            continue
        for i, line in enumerate(f.read_text().splitlines(), 1):
            code = line.split("//")[0]
            if re.search(r"\babort\s*\(\s*\)", code):
                aborts.append(f"{f.name}:{i}: {line.strip()}")
            if "exit(3)" in code:
                exits.append(f.name)
    assert aborts == [], "\n".join(aborts)
    # the one exit(3) is the refusal's own
    assert exits == ["yon_refuse.c"], exits
    body = (ROOT / "runtime" / "yon_refuse.c").read_text()
    fn = body[body.index("_Noreturn void yon_rt_refuse_with("):]
    assert "exit(3)" in fn[:fn.index("\n}\n")], "exit(3) is outside yon_rt_refuse_with"


def test_every_arm_writes_its_own_sentence(tmp_path):
    arms, sentences = _arms_and_sentences()
    branches = "\n".join(
        f"    else if i == {k} then SystemOs.refuse({a}, w, w, w)" for k, a in enumerate(arms))
    entry = ("place Entry {\nfun main(): Number {\n"
             "  i := match SystemOs.arg(1) { Text as t => Text.parse_number(t), DomainError as d => 0 - 1 }\n"
             "  w := Word64.from_int64(7)\n"
             "  return if i < 0 then 1\n" + branches + "\n    else 2\n}\n}\n")
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML)
    (proj / "Entry.yon").write_text(entry)
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True,
                       text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    for k, a in enumerate(arms):
        run = subprocess.run([str(exe), str(k)], capture_output=True, text=True, timeout=30)
        fixed = sentences[a].split("{")[0]
        assert run.returncode == 3 and run.stderr.startswith("error: " + fixed), (a, run.returncode, run.stderr)


def test_the_words_of_the_occasion_take_their_places(tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML)
    (proj / "Entry.yon").write_text(
        "place Entry {\nfun main(): Number {\n"
        "  n := SystemOs.refuse(WordOutsideRegion, Word64.from_int64(7), Word64.from_int64(5), Word64.zero)\n"
        "  return n + 1\n}\n}\n")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True, text=True, timeout=180)
    assert r.returncode == 0, r.stdout + r.stderr
    run = subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)
    assert run.returncode == 3, run
    assert run.stderr == "error: region: word 7 is outside a region of 5 words\n", run.stderr


def test_the_bridge_of_the_algebra_verifier_refuses_through_the_registry(tmp_path):
    # The bridge gives a unit written by hand the handle of an algebra of the
    # table, and refuses an index outside it with the arm AlgebraNotInTable.
    from test_runtime_units import CC, DISPATCH_STUB, FT, RTSET
    missing = [n for n in RTSET if not Path(n).exists()]
    if missing:
        pytest.skip(f"runtime objects not built: {missing[0]} (run `make` in runtime/)")
    main = tmp_path / "bridge.c"
    main.write_text(
        "#include <stdio.h>\n#include <stdlib.h>\n"
        "double yon_rt_magma_from_algebra(double);\n"
        "int main(int argc, char **argv) {\n"
        "  (void)argc;\n"
        "  printf(\"%g\\n\", yon_rt_magma_from_algebra(atof(argv[1])));\n"
        "  return 0;\n}\n")
    exe = tmp_path / "bridge"
    c = subprocess.run([CC, "-std=c11", "-O2", f"-I{FT}", str(main), *RTSET, DISPATCH_STUB,
                        "-lpthread", "-lm", "-o", str(exe)], capture_output=True, text=True, timeout=120)
    assert c.returncode == 0, c.stderr[-2000:]
    ok = subprocess.run([str(exe), "6"], capture_output=True, text=True, timeout=30)
    assert ok.returncode == 0 and ok.stdout == "7\n", ok
    for bad, said in (("7", "7"), ("2.5", "2.5"), ("-1", "-1")):
        run = subprocess.run([str(exe), bad], capture_output=True, text=True, timeout=30)
        assert run.returncode == 3, run
        assert run.stderr == f"error: algebra verifier: {said} names no algebra of the table\n", run.stderr
