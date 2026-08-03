(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_hm_infer.ml — ORACLE for the HM inference engine (Algorithm W) plus the
 * pure ty_subst core it stands on (unify / occur-check).
 *
 * Grounded on:
 *   ty_subst.ml (via test_ty_subst.ml:5-118 for the exact API shapes):
 *     try_unify : ty -> ty -> (subst, unify_error) result
 *       Ok [(0, TyPrim "number")]  on  unify alpha0 number     (ty_subst test:59-61)
 *       Error (UMismatch _)        on  unify number text       (ty_subst test:57-58)
 *       Error (UOccurCheck (0,_))  on  unify alpha0 (list a0)  (ty_subst test:86-88)
 *     occur_check : int -> ty -> bool                          (ty_subst test:46-49)
 *     apply_subst : subst -> ty -> ty                          (ty_subst test:38)
 *     reset_metavars / fresh_metavar                           (ty_subst test:26-31)
 *   surface_ast.ml:
 *     ty:        TyMetaVar of int (70), TyPrim of string (59),
 *                TyList of ty (63), TyUser of string (68), TyArrow (85)
 *     expr:      ELit of literal*location (137), EVar (138),
 *                EBinop of binop*expr*expr*location (151)
 *     literal:   LitNumber of float (122) ;  binop: OpAdd (132)
 *     stmt:      SReturn of expr*location (259)
 *     param:     { param_name; param_ty } (312-315)
 *     fun_decl:  { fn_name; fn_type_params; fn_params; fn_return; fn_visits;
 *                  fn_internal; fn_body; fn_loc }
 *     top_decl:  TopFun of fun_decl (677) ;  program = top_decl list (772)
 *     dummy_loc  (24)
 *   hm_infer.ml:
 *     infer_program : program -> program (345-356); a "_"-typed param surfaces
 *     the inferred type via the returned fun's param_ty
 *     (build_initial_fun_env:283-287 maps TyUser "_" -> fresh metavar;
 *      infer_fun_decl:332-336 writes metavar_to_unknown inferred back only for
 *      TyUser "_" params).
 *)

open Surface_ast
open Ty_subst

let num = TyPrim "number"
let txt = TyPrim "text"

let pass = ref 0
let fails = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fails; Printf.printf "  [FAIL] %s\n" name)

let () =
  Printf.printf "=== HM inference + ty_subst oracle ===\n\n";

  (* ── ty_subst core: unify binds a metavar to a concrete ─────────────────── *)
  reset_metavars ();
  let _a0 = fresh_metavar () in   (* alpha0 *)
  check "unify alpha0 number -> binds 0 |-> number"
    (match try_unify (TyMetaVar 0) num with
     | Ok sigma -> apply_subst sigma (TyMetaVar 0) = num
     | Error _ -> false);

  check "unify number number -> trivially ok"
    (match try_unify num num with Ok _ -> true | Error _ -> false);

  (* incompatible concretes must be a hard error, never a silent bind. *)
  check "unify number text -> mismatch error"
    (match try_unify num txt with
     | Error (UMismatch _) -> true | _ -> false);

  (* ── occur-check / infinite type rejection ──────────────────────────────── *)
  check "occur_check 0 in (list alpha0) -> true (would be infinite)"
    (occur_check 0 (TyList (TyMetaVar 0)));
  check "occur_check 0 in number -> false"
    (not (occur_check 0 num));
  (* unify driving the occur-check: alpha0 = list alpha0 is the infinite type. *)
  check "unify alpha0 (list alpha0) -> occurs-check error (no infinite type)"
    (match try_unify (TyMetaVar 0) (TyList (TyMetaVar 0)) with
     | Error (UOccurCheck (0, _)) -> true | _ -> false);

  (* ── program-level inference (known answer) ─────────────────────────────── *)
  (* fun f(x): Number { return x + 1 }   with x untyped (TyUser "_").
   * The body forces x to number (binop LHS expects number, hm_infer.ml:112),
   * so the inferred param type must come back as number. *)
  let dl = dummy_loc in
  let body_ret =
    SReturn (EBinop (OpAdd, EVar ("x", dl),
                     ELit (LitNumber 1.0, dl), dl), dl) in
  let fn : fun_decl =
    { fn_name = "f";
      fn_type_params = [];
      fn_params = [ { param_name = "x"; param_ty = TyUser "_" } ];
      fn_return = Some num;
      fn_on_error = None; fn_visits = []; fn_home = None;
      fn_internal = false; fn_given = false;
      fn_body = [ body_ret ];
      fn_loc = dl } in
  let prog : program = [ TopFun fn ] in
  let inferred = Hm_infer.infer_program prog in
  let inferred_param_ty =
    match inferred with
    | [ TopFun fn' ] ->
        (match fn'.fn_params with
         | [ p ] -> Some p.param_ty
         | _ -> None)
    | _ -> None in
  check "infer_program: untyped param x of (x + 1) inferred as number"
    (inferred_param_ty = Some num);

  Printf.printf "\n%d passed, %d failed\n" !pass !fails;
  if !fails = 0 then exit 0 else exit 1
