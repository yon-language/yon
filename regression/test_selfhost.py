"""Yon-in-Yon: the self-host seed programs compile through the real pipeline and run.

Each selfhost/*.yon is a fragment of a compiler for a small object language, written IN
Yon: its AST is encoded as content-addressed MerkleTree nodes, and each pass (eval,
parse, typecheck) is a recursive fun that is a catamorphism over that structure. This
pins, on silicon, the design's spine: eval is a catamorphism on a content-addressed
coproduct place; parse is a fold over the token stream; typecheck is a fold into the type
algebra. Layer/kind assigned centrally in conftest: yon / integration.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
SELFHOST = ROOT / "selfhost"

# program -> expected exit code (main's value mod 256)
EXPECTED = {
    "ast_eval": 125,    # eval((2+3)*(4+1)) = 25, plus the structural collapse (100)
    "eval_env": 30,     # let x = (2+3) in x*(x+1) = 30 (binders via an environment)
    "parse": 20,        # parse "2 + 3 * 4" left-assoc -> (2+3)*4
    "typecheck": 100,   # infer(well-typed) = NUMBER(1) * 100 + infer(ill-typed) = ERROR(0)
    "heyting_eval": 120,  # Omega/G3: (NOT U=A)*100 + (U or NOT U=U)*10 + (P or NOT P=P)
    "typecheck_omega": 5,  # Omega-valued judgment: base3(refl=P, conv=P, neq=A, open=U)
    "lexer": 20,           # text "2+3*4" -> lex -> parse -> eval, left-assoc (2+3)*4
    # Stage 1 metacircular evaluator, written in Yon over the native coproduct place
    # types. Each oracle is a structural identity; the binary exits 0 iff it holds.
    "eval_core_products": 0,  # eval Fst(Pair(20,22)) = 20  (products, no binder)
    "eval_core_lambda": 0,    # (lam.0) 42 = 42 and Fst((lam.0) Pair(20,22)) = 20 (de Bruijn beta)
    "eval_core_j": 0,         # J(_, lam.0, refl 7) = 7  (the diagonal beta, as the OCaml kernel)
    "lexer_min": 0,           # lex "2+3*4" -> tokens; structural checksum = 309 (front-end)
    "parse_arith": 0,         # text -> lex -> parse (prec: * over +) -> eval; "2+3*4" = 14
    "eval_unified": 0,        # one Term, one eval: lambda beta + arithmetic; (lam.x+x) 21 = 42
    "parse_scope": 0,         # text -> de Bruijn resolution -> Term; "\aa+a" applied to 21 = 42
}


@pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc not present")
@pytest.mark.parametrize("name,expected", sorted(EXPECTED.items()))
def test_selfhost_program(name, expected, tmp_path):
    src = SELFHOST / f"{name}.yon"
    if not src.exists():
        pytest.skip(f"{src.name} not present")
    binp = tmp_path / name
    comp = subprocess.run([str(YONC), str(src), "-o", str(binp)],
                          capture_output=True, text=True, timeout=180)
    assert comp.returncode == 0 and binp.exists(), (
        f"{name}.yon failed to compile:\n{comp.stdout[-800:]}\n{comp.stderr[-1500:]}")
    r = subprocess.run([str(binp)], capture_output=True, timeout=60)
    assert r.returncode == expected, (
        f"{name}: exit {r.returncode}, expected {expected} "
        f"(the self-host program computed the wrong value)")
