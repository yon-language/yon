(* test_desugar.ml — oracle for the Surface->Core desugar rules (desugar.ml).
 *
 * Pins the canonical statement-desugar shapes (desugar.ml desugar_stmts):
 *   - a let-binding lifts to an application of a unit-lambda:
 *       SLet x v :: rest  ->  App(Lam(x, unit, <rest>), <v>)
 *   - a single `return e` desugars to the bare Core expression `e`;
 *   - a non-let statement before a tail lifts to App(Lam("_", unit, <tail>), <stmt>);
 *   - nested lets nest the unit-lambdas in SOURCE order.
 * term_equal_env is the structural ground truth on Core terms. The last
 * oracle missing from Layer 2 (the Surface->Core boundary).
 *)

module S = Surface_ast
open Ast

let pass = ref 0
let fails = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fails; Printf.printf "  [FAIL] %s\n" name)

let dl = S.dummy_loc
let svar x = S.EVar (x, dl)
let sret x = S.SReturn (svar x, dl)
let slet n x = S.SLet (n, svar x, dl)

let () =
  Printf.printf "=== Surface->Core desugar (desugar.ml) oracle ===\n\n";

  (* let -> App(Lam,v): `be x holds y ; return x`  ==>  (lambda x. x) y *)
  check "let: [SLet x y; return x]  =>  App(Lam(x, unit, Var x), Var y)"
    (term_equal_env []
       (Desugar.desugar_stmts [slet "x" "y"; sret "x"])
       (App (Lam ("x", TyPlace "unit", Var "x"), Var "y")));

  (* a single `return e` desugars to the bare e. *)
  check "single return: [return y]  =>  Var y"
    (term_equal_env []
       (Desugar.desugar_stmts [sret "y"])
       (Var "y"));

  (* a non-let statement before a tail lifts to App(Lam("_"), stmt). *)
  check "non-let stmt: [return a; return b]  =>  App(Lam(_, unit, Var b), Var a)"
    (term_equal_env []
       (Desugar.desugar_stmts [sret "a"; sret "b"])
       (App (Lam ("_", TyPlace "unit", Var "b"), Var "a")));

  (* nested lets nest the unit-lambdas in source order. *)
  check "nested let: [be x=a; be y=b; return y]  =>  Lam x.(Lam y. y) b applied to a"
    (term_equal_env []
       (Desugar.desugar_stmts [slet "x" "a"; slet "y" "b"; sret "y"])
       (App (Lam ("x", TyPlace "unit",
                  App (Lam ("y", TyPlace "unit", Var "y"), Var "b")),
             Var "a")));

  Printf.printf "\n%d passed, %d failed\n" !pass !fails;
  if !fails = 0 then exit 0 else exit 1
