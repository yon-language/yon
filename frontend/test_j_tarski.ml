(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_j_tarski.ml — integration oracle for the Tarski dependent J.
 *
 * A GENUINE motive C (a term whose type lands in the universe) makes J typed
 * dependently: J(C, d, p) : El(C x p), with d checked against El(C a (refl a)).
 * A PLACEHOLDER motive (a literal) keeps the honest non-dependent typing.
 * This exercises the engine end-to-end through Tycheck.infer.
 *)

open Surface_ast

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let () =
  Printf.printf "=== Tarski dependent J oracle ===\n\n";
  let dl = dummy_loc in
  let ctx = Reduce.empty_ctx in
  let a_ty = TyPrim "A" in

  (* (1) GENUINE motive C : A -> Type. p = refl(a) gives endpoints "refl_arg".
     d is bound at exactly El(C refl_arg (refl refl_arg)) so the base case
     checks; the result must be El(C applied to the endpoint and the path). *)
  let motive_ty = TyArrow (a_ty, TyUniverse 0) in
  let refl_arg = EVar ("refl_arg", dl) in
  let expected_d =
    TyEl (TyTermExpr (EApp (EVar ("C", dl), [refl_arg; ERefl (refl_arg, dl)], dl))) in
  let env =
    Tyenv.add_vars Tyenv.empty
      [("C", motive_ty); ("d", expected_d); ("a", a_ty)] in
  let j = EJ (EVar ("C", dl), EVar ("d", dl), ERefl (EVar ("a", dl), dl), dl) in
  (match Tycheck.infer env ctx j with
   | Ok (TyEl (TyTermExpr (EApp (EVar ("C", _), [_; _], _)))) ->
       check "genuine motive: J typed dependently, result = El(C _ _)" true
   | Ok other ->
       check (Printf.sprintf "genuine motive: unexpected result %s"
                (Tyenv.ty_to_string other)) false
   | Error e ->
       check (Printf.sprintf "genuine motive: infer failed: %s"
                (Tycheck.error_to_string e)) false);

  (* (2) PLACEHOLDER motive (literal 0): must NOT take the Tarski path; legacy
     non-dependent typing reads d's codomain (here A), never El(...). *)
  let env2 =
    Tyenv.add_vars Tyenv.empty [("diag", TyArrow (a_ty, a_ty)); ("a", a_ty)] in
  let j2 =
    EJ (ELit (LitNumber 0.0, dl), EVar ("diag", dl),
        ERefl (EVar ("a", dl), dl), dl) in
  (match Tycheck.infer env2 ctx j2 with
   | Ok (TyEl _) ->
       check "placeholder motive: wrongly took Tarski path" false
   | Ok _ ->
       check "placeholder motive: legacy non-dependent typing (no El)" true
   | Error _ ->
       check "placeholder motive: infer failed" false);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
