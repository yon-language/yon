(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_tycheck.ml — ORACLE: verdict tests on hand-built surface programs.
 *
 * We build Surface_ast.program values directly (no parser) and run
 * Tycheck.check_program, asserting only on the VERDICT: whether cr_errors is
 * empty (accept) or non-empty (reject). We do NOT assert on message text, which
 * is expected to drift; we pin the accept/reject decision of the type checker.
 *
 * Grounded on:
 *   - surface_ast.ml: fun_decl record (fn_name … fn_loc), param record
 *     (param_name, param_ty), TopFun, SReturn, SLet, ELit (LitNumber/LitString),
 *     EBinop, OpAdd, ty (TyPrim), dummy_loc.
 *   - tycheck.ml:4194 check_program : program -> check_result;
 *     check_result.cr_errors : type_error list  (tycheck.ml:3699).
 *)

open Surface_ast

let pass = ref 0
let fails = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fails; Printf.printf "  [FAIL] %s\n" name)

let loc = dummy_loc

(* literal-expression helpers *)
let enum (n : float) : expr = ELit (LitNumber n, loc)
let estr (s : string) : expr = ELit (LitString s, loc)

(* A fun_decl with all fields defaulted; the caller overrides the ones that
   matter for the scenario. *)
let mkfun ?(type_params=[]) ?(params=[]) ?(ret=Some (TyPrim "number"))
          ?(visits=[]) ?(internal=false) ~body name : fun_decl =
  { fn_name = name;
    fn_type_params = type_params;
    fn_params = params;
    fn_return = ret;
    fn_on_error = None; fn_visits = visits; fn_home = None;
    fn_internal = internal;
    fn_body = body;
    fn_loc = loc }

let mkparam (nm : string) (t : ty) : param = { param_name = nm; param_ty = t }

(* Run the checker on a single-function program; true iff ACCEPTED (no errors). *)
let accepts (fn : fun_decl) : bool =
  (Tycheck.check_program [ TopFun fn ]).Tycheck.cr_errors = []

let rejects (fn : fun_decl) : bool =
  List.length (Tycheck.check_program [ TopFun fn ]).Tycheck.cr_errors >= 1

let () =
  Printf.printf "=== Tycheck verdict oracle ===\n\n";

  (* A. WELL-TYPED accepts: fun main(): Number { return 1 + 2 } *)
  let well_typed =
    mkfun "main"
      ~ret:(Some (TyPrim "number"))
      ~body:[ SReturn (EBinop (OpAdd, enum 1.0, enum 2.0, loc), loc) ]
  in
  check "well-typed `return 1 + 2 : number` is accepted (cr_errors = [])"
    (accepts well_typed);

  (* B. ILL-TYPED rejects: return type mismatch. *)
  let ret_mismatch =
    mkfun "main"
      ~ret:(Some (TyPrim "number"))
      ~body:[ SReturn (estr "text", loc) ]
  in
  check "return \"text\" against declared number is rejected (cr_errors <> [])"
    (rejects ret_mismatch);

  (* C. ILL-TYPED rejects: duplicate parameter name (we added this check). *)
  let dup_param =
    mkfun "f"
      ~params:[ mkparam "a" (TyPrim "number"); mkparam "a" (TyPrim "number") ]
      ~ret:(Some (TyPrim "number"))
      ~body:[ SReturn (enum 0.0, loc) ]
  in
  check "duplicate parameter `a` is rejected" (rejects dup_param);

  (* D. ILL-TYPED rejects: empty body with a declared return type (we added it). *)
  let empty_body =
    mkfun "g"
      ~ret:(Some (TyPrim "number"))
      ~body:[]
  in
  check "empty body with declared return type is rejected" (rejects empty_body);

  (* E. return-tail (the check we just added): a body ending in a let whose
     value clearly differs from the concrete declared return type is rejected.
     `fun h(): Number { let y holds "text" }` — tail value is text, declared
     number → rejected via check_implicit_tail_return (tycheck.ml:2337). *)
  let bad_tail =
    mkfun "h"
      ~ret:(Some (TyPrim "number"))
      ~body:[ SLet ("y", estr "text", loc) ]
  in
  check "let-tail of type text under declared number is rejected" (rejects bad_tail);

  Printf.printf "\n%d passed, %d failed\n" !pass !fails;
  if !fails = 0 then exit 0 else exit 1
