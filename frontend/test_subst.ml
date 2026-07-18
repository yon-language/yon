(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_subst.ml — oracle for capture-avoiding substitution (subst.ml).
 *
 * Pins the three sub-cases named in the subst.ml header, plus the HITElim
 * branch-binder capture case routed through subst_under_binders (the fix
 * that made every multi-binder form capture-proof). free_vars is the ground
 * truth for "did capture happen": a variable that should stay free must be
 * in free_vars of the result, and a renamed binder must differ from the
 * captured name.
 *)

open Ast

module SS = Set.Make (String)

let pass = ref 0
let fails = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fails; Printf.printf "  [FAIL] %s\n" name)

let ty = TyPlace "A"
let free t v = SS.mem v (free_vars t)

let () =
  Printf.printf "=== capture-avoiding subst (subst.ml) oracle ===\n\n";

  (* ── case 1: shadowing — binder x shadows the substitution ────────── *)
  (* subst "x" u (lambda x. body) leaves the lambda unchanged. *)
  let body = App (Var "x", Var "z") in
  let shadowed = Lam ("x", ty, body) in
  check "shadow: subst x u (lambda x. x z) = (lambda x. x z) unchanged"
    (term_equal_env [] (Subst.subst "x" (Var "u") shadowed) shadowed);

  (* ── case 2: no-capture — binder y <> z, recurse into body ────────── *)
  (* subst "x" (Var "z") (lambda y. x) = lambda y. z  (y <> z). *)
  check "no-capture: subst x z (lambda y. x) = lambda y. z"
    (match Subst.subst "x" (Var "z") (Lam ("y", ty, Var "x")) with
     | Lam ("y", _, Var "z") -> true
     | _ -> false);

  (* ── case 3: capture-avoidance — y is free in u, rename the binder ── *)
  (* subst "x" (Var "y") (lambda y. x): the substituted free y must NOT be
   * captured by the binder y. The result must be alpha-equiv to
   * (lambda y'. y) with y' fresh: "y" is FREE in the result, and the binder
   * is no longer "y". *)
  let captured = Lam ("y", ty, Var "x") in
  let result = Subst.subst "x" (Var "y") captured in
  check "capture: subst x y (lambda y. x) keeps y FREE in the result"
    (free result "y");
  check "capture: subst x y (lambda y. x) renames the binder (binder <> y)"
    (match result with
     | Lam (y', _, Var z) -> y' <> "y" && z = "y"
     | _ -> false);
  (* alpha-equivalence to (lambda w. y) for any fresh w: build with a concrete
   * fresh binder name distinct from y and compare via term_equal_env. *)
  check "capture: result is alpha-equiv to (lambda w. y)"
    (term_equal_env [] result (Lam ("_w", ty, Var "y")));

  (* ── HITElim branch-binder capture (the subst_under_binders fix) ───── *)
  (* A branch (ctor, [v], body=Var "x") binds v over body. Substituting
   * x := Var v must NOT let the binder v capture the incoming v: v must
   * stay FREE in the resulting branch body. We assert via free_vars of the
   * whole HITElim, and that the branch binder got renamed away from "v". *)
  let v = "v" in
  let branch = ("c", [v], Var "x") in
  let scrut = Var "s" in
  let hit = HITElim ([branch], scrut) in
  let hit' = Subst.subst "x" (Var v) hit in
  check "HITElim capture: subst x (Var v) keeps v FREE (no branch capture)"
    (free hit' v);
  check "HITElim capture: branch binder renamed away from v"
    (match hit' with
     | HITElim ([(_, [v'], _)], _) -> v' <> v
     | _ -> false);
  (* control: when no binder clashes, the substitution goes through without
   * renaming. subst x (Var "w") into the same branch (w not a binder) puts
   * w free in the body, binder "v" untouched. *)
  let hit_ctrl = Subst.subst "x" (Var "w") hit in
  check "HITElim control: subst x w leaves binder v intact, w free"
    (match hit_ctrl with
     | HITElim ([("c", ["v"], Var "w")], Var "s") -> true
     | _ -> false);

  (* ── direct subst_under_binders: the shared multi-binder routine ───── *)
  (* x shadowed by the binder list -> body untouched. *)
  check "subst_under_binders: x in vars -> shadowed, body untouched"
    (match Subst.subst_under_binders "x" (Var "u") ["x"; "y"] (Var "x") with
     | (["x"; "y"], Var "x") -> true
     | _ -> false);
  (* no binder free in u -> recurse, vars unchanged. *)
  check "subst_under_binders: no clash -> recurse, vars unchanged"
    (match Subst.subst_under_binders "x" (Var "z") ["y"] (Var "x") with
     | (["y"], Var "z") -> true
     | _ -> false);
  (* a binder free in u -> that binder is renamed, the incoming name stays free. *)
  check "subst_under_binders: clash -> binder renamed, u's var stays free"
    (let (vars', body') =
       Subst.subst_under_binders "x" (Var "y") ["y"] (Var "x") in
     match vars' with
     | [y'] -> y' <> "y" && SS.mem "y" (free_vars body')
     | _ -> false);

  Printf.printf "\n%d passed, %d failed\n" !pass !fails;
  if !fails = 0 then exit 0 else exit 1
