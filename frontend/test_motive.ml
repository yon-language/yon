(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_motive.ml — oracle for the type-level dependent substitution
 * (motive application). subst_term_in_ty x u t replaces the TERM variable x
 * inside the term-carrying type formers (TyId endpoints, TyEl code, TyGlue
 * equivalences), structurally elsewhere, capture-avoiding at TyPi/TySigma.
 *
 * This is the missing piece the J comment (tycheck.ml:914) named: without it
 * neither J nor a HIT eliminator can be typed dependently. With it, C(arg) is
 * computable from a dependent motive body.
 *)

open Ast

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let () =
  Printf.printf "=== motive application (subst_term_in_ty) oracle ===\n\n";

  let a = TyPlace "A" in
  let s = Subst.subst_term_in_ty in

  (* (1) TyId endpoints: C(x) = Id_A(x, y); C(a) substitutes the left endpoint *)
  check "TyId: Id_A(x,y) [x := a]  =  Id_A(a,y)"
    (match s "x" (Var "a") (TyId (a, Var "x", Var "y")) with
     | TyId (_, Var "a", Var "y") -> true | _ -> false);

  (* (2) TyEl code: El(x) [x := a] = El(a) — the code term is substituted *)
  check "TyEl: El(x) [x := a]  =  El(a)"
    (match s "x" (Var "a") (TyEl (Var "x")) with
     | TyEl (Var "a") -> true | _ -> false);

  (* (3) structural former with no term: untouched *)
  check "TyPlace / TyPlace: no term, untouched"
    (s "x" (Var "a") (TyPlace "S1") = TyPlace "S1");

  (* (4) TyPi binder SHADOWS: Pi(x:A). Id_A(x,y) [x := a] leaves the body alone *)
  check "TyPi shadow: Pi(x:A).Id(x,y) [x := a] keeps body's x"
    (match s "x" (Var "a") (TyPi ("x", a, TyId (a, Var "x", Var "y"))) with
     | TyPi ("x", _, TyId (_, Var "x", Var "y")) -> true | _ -> false);

  (* (5) TyPi NON-shadow: Pi(y:A). Id_A(x,y) [x := a] substitutes into codomain *)
  check "TyPi non-shadow: Pi(y:A).Id(x,y) [x := a]  =  Pi(y:A).Id(a,y)"
    (match s "x" (Var "a") (TyPi ("y", a, TyId (a, Var "x", Var "y"))) with
     | TyPi ("y", _, TyId (_, Var "a", Var "y")) -> true | _ -> false);

  (* (6) CAPTURE-AVOIDANCE: Pi(y:A). Id_A(x,y) [x := y] must rename the binder,
     so the substituted (free) y is NOT captured. Expect Pi(y':A).Id(y, y'). *)
  check "TyPi capture: Pi(y:A).Id(x,y) [x := y] renames binder (no capture)"
    (match s "x" (Var "y") (TyPi ("y", a, TyId (a, Var "x", Var "y"))) with
     | TyPi (y', _, TyId (_, Var "y", Var z)) -> y' <> "y" && z = y'
     | _ -> false);

  (* (7) nested under TyArrow: A -> Id_A(x,y) [x := a] *)
  check "TyArrow: (A -> Id(x,y)) [x := a]  =  A -> Id(a,y)"
    (match s "x" (Var "a") (TyArrow (a, TyId (a, Var "x", Var "y"))) with
     | TyArrow (_, TyId (_, Var "a", Var "y")) -> true | _ -> false);

  (* (8) NATIVE Tarski lowering: an APPLIED code El(C(x,p)) must desugar to
     TyEl of an applied term — the Ast world where subst_term_in_ty operates —
     not collapse to a bare name. (Strada A: ty_term carries a Surface expr.) *)
  let dl = Surface_ast.dummy_loc in
  let applied_code =
    Surface_ast.TyEl (Surface_ast.TyTermExpr
      (Surface_ast.ECall ("C",
        [Surface_ast.EVar ("x", dl); Surface_ast.EVar ("p", dl)], dl))) in
  check "desugar: El(C(x,p)) lowers natively to TyEl(applied term)"
    (match Desugar.desugar_ty applied_code with
     | TyEl (App _) -> true | _ -> false);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
