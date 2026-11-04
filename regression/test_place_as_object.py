"""place-as-object: a named type is a coproduct place, `place X { this > A :U B }`.

Yon's one ontology is the place (carrier.ml: "an object, a presheaf Site ->
Type"); every type lowers to a C.TyPlace. A named sum surfaces that directly: the
`this >` clause declares the object X as the coproduct of its arms, each arm a
sub-object (a coproduct injection). This is the single canonical form: the
grammar has no `inductive` and no `place X = ...`.
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
                "fun v(b: Bit): Number { return match b { one => 1, zero => 0 } }\n"
                "fun main(): Number { return v(one) }", 1),
    ("payload", "place Val { this > Lit Number }\n"
                "fun get(v: Val): Number { return match v { Lit as n => n } }\n"
                "fun main(): Number { return get(42 |> Lit) }", 42),
    ("recursive", "place Term { this > Leaf Number :U Node Term }\n"
                  "fun d(t: Term): Number { return match t { Leaf as n => n, Node as m => d(m) } }\n"
                  "fun main(): Number { return d(7 |> Leaf |> Node |> Node) }", 7),
]


@pytest.mark.parametrize("name,src,expected", BLOCK_FORMS, ids=[p[0] for p in BLOCK_FORMS])
def test_block_form_declares_a_type(tmp_path, name, src, expected):
    assert _run(tmp_path, src) == expected


# The retired form and its lawful twin differ ONLY in the declaration line; both
# carry a `place Entry` so the program is otherwise valid.
_INDUCTIVE = ("inductive Bit = O | I\n"
              "place Entry {\n  fun main(): Number { return 0 }\n}\n")
_PLACE_TWIN = ("place Bit { this > O :U I }\n"
               "place Entry {\n  fun main(): Number { return 0 }\n}\n")


def test_inductive_keyword_is_gone(tmp_path):
    """`inductive` is not Yon: the reference rejects it as a PARSE error at the
    declaration (line 1), with the syntax code E1001 -- not a type error, not a
    crash. The twin with the block form compiles and runs, so the keyword is the
    only thing the rejection can be about."""
    assert _run(tmp_path, _PLACE_TWIN) == 0, "the lawful twin must compile and exit 0"
    s = tmp_path / "old.yon"
    s.write_text(_INDUCTIVE)
    c = subprocess.run([str(YONC), str(s), "-o", str(tmp_path / "old")],
                       capture_output=True, text=True, timeout=120)
    out = c.stdout + c.stderr
    assert c.returncode != 0, "`inductive` should no longer be accepted by the reference"
    assert "Fatal error: exception" not in out, out
    assert "PARSE ERROR [E1001]" in out, f"expected a syntax error, got:\n{out[-600:]}"
    assert f"{s.name}:1:" in out, f"the parse error must point at line 1:\n{out[-600:]}"
