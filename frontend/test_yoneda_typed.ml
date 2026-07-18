(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
open Ast

let pass = ref 0
let fail = ref 0

let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let u0 = TyDirUniverse 0
let el x = TyEl (Var x)
let hom a b = TyArrow (el a, el b)

let comp ~cod ~arg ~dom =
  Lam ("u", dom, App (cod, App (arg, Var "u")))

let id_p = Lam ("u", el "P", Var "u")
let h = Var "h"
let eta_x = Var "eta_X"
let eta_p = Var "eta_P"
let phi = App (eta_p, id_p)

let yo_phi_x =
  Lam ("hh", hom "X" "P",
    comp ~cod:phi ~arg:(Var "hh") ~dom:(el "X"))

let nat_lhs =
  App (eta_x, comp ~cod:id_p ~arg:h ~dom:(el "X"))

let nat_rhs = comp ~cod:phi ~arg:h ~dom:(el "X")
let full_lhs = App (eta_x, h)
let full_rhs = App (yo_phi_x, h)
let hom_xq = hom "X" "Q"
let ty_nat = TyId (hom_xq, nat_lhs, nat_rhs)
let ty_full = TyId (hom_xq, full_lhs, full_rhs)

let witness =
  Lam ("P", u0,
    Lam ("Q", u0,
      Lam ("X", u0,
        Lam ("eta_X", TyArrow (hom "X" "P", hom "X" "Q"),
          Lam ("eta_P", TyArrow (hom "P" "P", hom "P" "Q"),
            Lam ("h", hom "X" "P",
              Lam ("nat", ty_nat, Var "nat")))))))

let witness_type result =
  TyPi ("P", u0,
    TyPi ("Q", u0,
      TyPi ("X", u0,
        TyPi ("eta_X", TyArrow (hom "X" "P", hom "X" "Q"),
          TyPi ("eta_P", TyArrow (hom "P" "P", hom "P" "Q"),
            TyPi ("h", hom "X" "P", TyArrow (ty_nat, result)))))))

let witness_ty = witness_type ty_full

let well_formed ty =
  try
    let _ = Core_check.sort_of [] ty in
    true
  with Core_check.Check_error _ -> false

let nf t = Builtins.reduce_with_builtins Reduce.empty_ctx t

let () =
  Printf.printf "=== typed Yoneda fullness witness oracle ===\n\n";

  check "THE LEMMA, typed: kernel checks the closed Yoneda fullness witness"
    (Core_check.check_closed witness witness_ty);

  let ty_full_bad = TyId (hom_xq, full_lhs, full_lhs) in
  let witness_ty_bad = witness_type ty_full_bad in
  check "broken target remains well formed"
    (well_formed witness_ty_bad);
  check "broken witness rejected: wrong target type is not accepted"
    (not (Core_check.check_closed witness witness_ty_bad));

  check "well-formedness gate: witness type is well formed"
    (well_formed witness_ty);

  check "forward map computes: nf(full_rhs) = nf(nat_rhs)"
    (term_equal_env [] (nf full_rhs) (nf nat_rhs));

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
