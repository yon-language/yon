"""place-as-object: a named type is a coproduct place, `place X { this > A :U B }`.

Yon's one ontology is the place (carrier.ml: "an object, a presheaf Site ->
Type"); every type lowers to a C.TyPlace. A named sum surfaces that directly: the
`this >` clause declares the object X as the coproduct of its arms, each arm a
sub-object (a coproduct injection). This is the single canonical form -- there is
no `inductive`/`place X = ...`; both were dropped once the corpus was migrated.
This gate pins the block form: an arm may be nullary, carry a payload, or recur.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"


def _run(tmp_path, src):
    s = tmp_path / "p.yon"
    s.write_text(src)
    b = tmp_path / "p"
    c = subprocess.run([str(YONC), str(s), "-o", str(b)],
                       capture_output=True, text=True, timeout=180)
    assert c.returncode == 0 and b.exists(), \
        f"place-as-object did not compile:\n{c.stderr[-800:]}"
    return subprocess.run([str(b)], capture_output=True, timeout=60).returncode


pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc not present")

# The canonical block form: `place X { this > A :U B }`. Each arm is nullary,
# carries a payload, or recurs into the type. (name, source, expected exit).
BLOCK_FORMS = [
    ("nullary", "place Bit { this > one :U zero }\n"
                "fun mot(b: Bit): number { return 0 }\n"
                "fun v(b: Bit): number { return hit_elim(mot, [ one => 1, zero => 0 ], b) }\n"
                "fun main(): number { return v(hit(one)) }", 1),
    ("payload", "place Val { this > Lit(number) }\n"
                "fun mot(v: Val): number { return 0 }\n"
                "fun get(v: Val): number { return hit_elim(mot, [ Lit(n) => n ], v) }\n"
                "fun main(): number { return get(hit(Lit, 42)) }", 42),
    ("recursive", "place Term { this > Leaf(number) :U Node(Term) }\n"
                  "fun mot(t: Term): number { return 0 }\n"
                  "fun d(t: Term): number { return hit_elim(mot, [ Leaf(n) => n, Node(m) => d(m) ], t) }\n"
                  "fun main(): number { return d(hit(Node, hit(Node, hit(Leaf, 7)))) }", 7),
]


@pytest.mark.parametrize("name,src,expected", BLOCK_FORMS, ids=[p[0] for p in BLOCK_FORMS])
def test_block_form_declares_a_type(tmp_path, name, src, expected):
    assert _run(tmp_path, src) == expected


def test_inductive_keyword_is_gone(tmp_path):
    # `inductive` was dropped: the reference must now reject it as a parse error.
    src = ("inductive Bit = O | I\n"
           "fun main(): number { return 0 }\n")
    s = tmp_path / "old.yon"
    s.write_text(src)
    c = subprocess.run([str(YONC), str(s), "-o", str(tmp_path / "old")],
                       capture_output=True, text=True, timeout=120)
    assert c.returncode != 0, "`inductive` should no longer be accepted by the reference"
