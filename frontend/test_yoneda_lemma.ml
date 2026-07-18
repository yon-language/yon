(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_yoneda_lemma.ml - kernel oracle for full faithfulness of the Yoneda
 * embedding. Recovery uses beta-eta; fullness is conversion of the naturality
 * square at h, evaluated on id_P. *)

open Ast

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let nf t = Builtins.reduce_with_builtins Reduce.empty_ctx t

let () =
  Printf.printf "=== Yoneda recovery (faithful half) oracle ===\n\n";

  let p_ty = TyPlace "P" in
  let q_ty = TyPlace "Q" in
  let id_p = Lam ("x", p_ty, Var "x") in
  let id_q = Lam ("y", q_ty, Var "y") in
  let f = Var "f" in
  let g = Var "g" in
  let comp ~cod ~arg ~dom =
    Lam ("x", dom, App (cod, App (arg, Var "x")))
  in
  let recov_f = comp ~cod:f ~arg:id_p ~dom:p_ty in
  let recov_g = comp ~cod:g ~arg:id_p ~dom:p_ty in
  let left_f = comp ~cod:id_q ~arg:f ~dom:p_ty in

  check "recovery is not yet syntactic id"
    (not (term_equal_env [] recov_f f));

  check "backward∘forward = id (beta+eta): nf(f ∘ id_P) = f"
    (term_equal_env [] (nf recov_f) f);

  check "left identity: nf(id_Q ∘ f) = f"
    (term_equal_env [] (nf left_f) f);

  check "recovery works for any arrow: nf(g ∘ id_P) = g"
    (term_equal_env [] (nf recov_g) g);

  check "faithful: distinct arrows have distinct recoveries"
    (not (term_equal_env [] (nf recov_f) (nf recov_g)));

  check "beta under composition: nf(id_P x) = x"
    (term_equal_env [] (nf (App (id_p, Var "x"))) (Var "x"));

  Printf.printf "\n--- fullness via naturality ---\n\n";

  let x_ty = TyPlace "X" in
  let hom_xq = TyArrow (x_ty, q_ty) in
  let h = Var "h" in
  let eta_x = Var "eta_X" in
  let eta_p = Var "eta_P" in
  let phi = App (eta_p, id_p) in
  let yo_phi_x =
    Lam ("hh", TyArrow (x_ty, p_ty),
         comp ~cod:phi ~arg:(Var "hh") ~dom:x_ty)
  in
  let full_rhs = App (yo_phi_x, h) in
  let nat_lhs =
    App (eta_x, comp ~cod:id_p ~arg:h ~dom:x_ty)
  in
  let nat_rhs = comp ~cod:phi ~arg:h ~dom:x_ty in
  let full_lhs = App (eta_x, h) in
  let id_ty_conv a b =
    match a, b with
    | TyId (_, a1, b1), TyId (_, a2, b2) ->
        term_equal_env [] (nf a1) (nf a2)
        && term_equal_env [] (nf b1) (nf b2)
    | _ -> false
  in
  let ty_nat = TyId (hom_xq, nat_lhs, nat_rhs) in
  let ty_full = TyId (hom_xq, full_lhs, full_rhs) in

  check "forward map computes to postcomposition: nf((yo phi)_X h) = phi o h"
    (not (term_equal_env [] full_rhs nat_rhs)
     && term_equal_env [] (nf full_rhs) (nf nat_rhs));

  check "naturality LHS reduces into fullness LHS: nf(eta_X(id_P o h)) = eta_X(h)"
    (term_equal_env [] (nf nat_lhs) full_lhs);

  check "THE LEMMA: fullness Id-type = naturality Id-type by conversion"
    (id_ty_conv ty_nat ty_full);

  let j_fullness =
    J ("z", hom_xq, Var "C", Var "dbase", Refl full_lhs, full_lhs)
  in
  check "J path-induction computes (iota)"
    (term_equal_env [] (nf j_fullness) (App (Var "dbase", full_lhs)));

  let yo_phi_p =
    Lam ("hh", TyArrow (p_ty, p_ty),
         comp ~cod:phi ~arg:(Var "hh") ~dom:p_ty)
  in
  check "recovery link (Stage 1): nf((yo phi)_P id_P) = phi"
    (term_equal_env [] (nf (App (yo_phi_p, id_p))) phi);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
