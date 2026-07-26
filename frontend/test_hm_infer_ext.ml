(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_hm_infer_ext.ml — ORACLE (extension): Algorithm-W inference engine.
 *
 * test_hm_infer.ml already pins: unify alpha0/number, number/text mismatch,
 * occur-check, and ONE program-level inference (x+1 => number param). This
 * file ADDS, exercising Hm_infer directly (infer_expr / solve_constraints /
 * infer_program) with a bias toward negative + edge cases:
 *
 *   - literal inference (number / text / boolean / duration)
 *   - binop / not / if-then-else constraint generation and result types
 *   - constraint SOLVING failures wrapped as Infer_error (UnifyFailed):
 *       constructor mismatch (number = text), occurs-check (a = list a)
 *   - metavar resolution through the constraint solver (chains)
 *   - application inference: param-as-function (case a) and stdlib (case c),
 *     including the ArityMismatch and UnknownVar error paths
 *   - program-level inference: RETURN-type inference (fn_return None),
 *     let-binding threading (SLet -> SReturn), multi-param, and the graceful
 *     bail-out (infer_program leaves a fn unchanged on an inference error)
 *
 * Grounded on:
 *   hm_infer.ml:90  infer_expr  : env -> constraint_set -> expr -> ty
 *   hm_infer.ml:70  add_constraint, :68 new_constraints, :52 empty_env
 *   hm_infer.ml:75  solve_constraints : constraint_set -> subst   (raises)
 *   hm_infer.ml:39  exception Infer_error, :31 infer_error constructors
 *   hm_infer.ml:345 infer_program : program -> program
 *   stdlib_runtime.ml:790 "__stream_map" : (unknown, unknown) -> unknown
 *   ty_subst.ml apply_subst / try_unify / reset_metavars / fresh_metavar
 *)

open Surface_ast
open Ty_subst

let num = TyPrim "number"
let txt = TyPrim "text"
let bool_ty = TyPrim "boolean"

let pass = ref 0
let fails = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fails; Printf.printf "  [FAIL] %s\n" name)

let dl = dummy_loc
let n f = ELit (LitNumber f, dl)
let s str = ELit (LitString str, dl)
let b v = ELit (LitBool v, dl)
let var x = EVar (x, dl)

(* infer with a fresh constraint set, then return the *raw* inferred type
   (before solving) — used where the top-level type is already concrete. *)
let infer_raw env e =
  let cs = Hm_infer.new_constraints () in
  Hm_infer.infer_expr env cs e

(* infer and SOLVE, returning the substitution-applied type. *)
let infer_solved env e =
  let cs = Hm_infer.new_constraints () in
  let t = Hm_infer.infer_expr env cs e in
  let sigma = Hm_infer.solve_constraints cs in
  apply_subst sigma t

(* run f; true iff it raises an Infer_error matching pred. *)
let raises_infer pred f =
  try let _ = f () in false
  with Hm_infer.Infer_error e -> pred e

let mkfun name params ret body : fun_decl =
  { fn_name = name;
    fn_type_params = [];
    fn_params = params;
    fn_return = ret;
    fn_visits = [];
    fn_internal = false;
    fn_body = body;
    fn_loc = dl }

let () =
  Printf.printf "=== HM inference oracle (ext) ===\n\n";

  (* ── literal inference ──────────────────────────────────────────────── *)
  Printf.printf "-- literals --\n";
  check "infer number literal -> number"  (infer_raw Hm_infer.empty_env (n 1.0) = num);
  check "infer string literal -> text"    (infer_raw Hm_infer.empty_env (s "hi") = txt);
  check "infer bool literal -> boolean"   (infer_raw Hm_infer.empty_env (b true) = bool_ty);
  check "infer duration literal -> number"
    (infer_raw Hm_infer.empty_env (ELit (LitDuration (5.0, "s"), dl)) = num);

  (* ── binop / not / if constraint generation ─────────────────────────── *)
  Printf.printf "-- binop / not / if --\n";
  check "1 + 2 : number"
    (infer_solved Hm_infer.empty_env (EBinop (OpAdd, n 1.0, n 2.0, dl)) = num);
  check "1 < 2 : boolean"
    (infer_solved Hm_infer.empty_env (EBinop (OpLt, n 1.0, n 2.0, dl)) = bool_ty);
  check "1 == 2 : boolean (equality is homogeneous & solvable)"
    (infer_solved Hm_infer.empty_env (EBinop (OpEq, n 1.0, n 2.0, dl)) = bool_ty);
  check "true and false : boolean"
    (infer_solved Hm_infer.empty_env (EBinop (OpAnd, b true, b false, dl)) = bool_ty);
  check "not true : boolean"
    (infer_solved Hm_infer.empty_env (ENot (b true, dl)) = bool_ty);
  check "if true then 1 else 2 : number"
    (infer_solved Hm_infer.empty_env (EIfThenElse (b true, n 1.0, n 2.0, dl)) = num);

  (* ── constraint-solving FAILURES (Infer_error wrapping) ─────────────── *)
  Printf.printf "-- solve failures --\n";
  check "1 == \"x\" -> UnifyFailed (number vs text, homogeneous eq)"
    (raises_infer
       (function Hm_infer.UnifyFailed (UMismatch _, _, _) -> true | _ -> false)
       (fun () -> infer_solved Hm_infer.empty_env (EBinop (OpEq, n 1.0, s "x", dl))));
  check "not 1 -> UnifyFailed (number vs boolean)"
    (raises_infer
       (function Hm_infer.UnifyFailed (UMismatch _, _, _) -> true | _ -> false)
       (fun () -> infer_solved Hm_infer.empty_env (ENot (n 1.0, dl))));
  check "if 1 then 2 else 3 -> UnifyFailed (cond number vs boolean)"
    (raises_infer
       (function Hm_infer.UnifyFailed (UMismatch _, _, _) -> true | _ -> false)
       (fun () -> infer_solved Hm_infer.empty_env (EIfThenElse (n 1.0, n 2.0, n 3.0, dl))));
  check "if true then 1 else \"x\" -> UnifyFailed (branch number vs text)"
    (raises_infer
       (function Hm_infer.UnifyFailed (UMismatch _, _, _) -> true | _ -> false)
       (fun () -> infer_solved Hm_infer.empty_env (EIfThenElse (b true, n 1.0, s "x", dl))));

  (* ── metavar resolution via the solver ──────────────────────────────── *)
  Printf.printf "-- metavar resolution --\n";
  reset_metavars ();
  let a0 = fresh_metavar () in
  let a1 = fresh_metavar () in
  let env_xy = Hm_infer.add_var (Hm_infer.add_var Hm_infer.empty_env "x" a0) "y" a1 in
  (* x + y forces both parameters to number. *)
  let cs = Hm_infer.new_constraints () in
  let tres = Hm_infer.infer_expr env_xy cs (EBinop (OpAdd, var "x", var "y", dl)) in
  let sigma = Hm_infer.solve_constraints cs in
  check "x + y : number (result)" (apply_subst sigma tres = num);
  check "x + y resolves x's metavar to number" (apply_subst sigma a0 = num);
  check "x + y resolves y's metavar to number" (apply_subst sigma a1 = num);

  (* solver-level chain: [a0 = number; a1 = a0]  =>  a1 resolves to number. *)
  reset_metavars ();
  let m0 = fresh_metavar () in
  let m1 = fresh_metavar () in
  let cs2 = Hm_infer.new_constraints () in
  Hm_infer.add_constraint cs2 m0 num dl "seed";
  Hm_infer.add_constraint cs2 m1 m0 dl "chain";
  let sig2 = Hm_infer.solve_constraints cs2 in
  check "solver chain a1 = a0 = number resolves a1 -> number"
    (apply_subst sig2 m1 = num);

  (* solver-level occurs-check surfaces as UnifyFailed (UOccurCheck ...). *)
  check "solver constraint a0 = list a0 -> UnifyFailed (UOccurCheck)"
    (raises_infer
       (function Hm_infer.UnifyFailed (UOccurCheck (_, _), _, _) -> true | _ -> false)
       (fun () ->
          reset_metavars ();
          let z0 = fresh_metavar () in
          let cs3 = Hm_infer.new_constraints () in
          Hm_infer.add_constraint cs3 z0 (TyList z0) dl "occurs";
          Hm_infer.solve_constraints cs3));

  (* ── application inference ───────────────────────────────────────────── *)
  Printf.printf "-- application --\n";
  (* case (a): applying a local variable as a function forces its type to an
     arrow whose domain is the arg type. *)
  reset_metavars ();
  let f0 = fresh_metavar () in
  let env_f = Hm_infer.add_var (Hm_infer.add_var Hm_infer.empty_env "f" f0) "k" num in
  let csf = Hm_infer.new_constraints () in
  let _ = Hm_infer.infer_expr env_f csf (ECall ("f", [var "k"], dl)) in
  let sigf = Hm_infer.solve_constraints csf in
  check "applying param f to a number forces f : number -> _"
    (match apply_subst sigf f0 with
     | TyArrow (TyPrim "number", _) -> true | _ -> false);

  (* case (c): stdlib builtin, correct arity, returns its (unknown) result. *)
  check "__stream_map with 2 args -> unknown result (stdlib sig)"
    (infer_raw Hm_infer.empty_env (ECall ("__stream_map", [n 1.0; n 2.0], dl))
     = TyPrim "unknown");
  check "__stream_map with 1 arg -> ArityMismatch(2,1)"
    (raises_infer
       (function
        | Hm_infer.ArityMismatch ("__stream_map", 2, 1, _) -> true | _ -> false)
       (fun () -> infer_raw Hm_infer.empty_env (ECall ("__stream_map", [n 1.0], dl))));
  check "free variable -> UnknownVar"
    (raises_infer
       (function Hm_infer.UnknownVar ("nope", _) -> true | _ -> false)
       (fun () -> infer_raw Hm_infer.empty_env (var "nope")));

  (* ── program-level inference (known answers) ────────────────────────── *)
  Printf.printf "-- infer_program --\n";
  let ret_of prog =
    match Hm_infer.infer_program prog with
    | [ TopFun fn' ] -> fn'.fn_return
    | _ -> None
  in
  let param_of prog =
    match Hm_infer.infer_program prog with
    | [ TopFun fn' ] -> (match fn'.fn_params with [ p ] -> Some p.param_ty | _ -> None)
    | _ -> None
  in
  (* RETURN inference: fn_return None, body returns x+1 -> number. *)
  let g = mkfun "g"
      [ { param_name = "x"; param_ty = num } ] None
      [ SReturn (EBinop (OpAdd, var "x", n 1.0, dl), dl) ] in
  check "infer_program: fn_return None of (x+1) inferred as number"
    (ret_of [ TopFun g ] = Some num);

  (* let-binding threads through: let y = x+1; return y -> number. *)
  let h = mkfun "h"
      [ { param_name = "x"; param_ty = num } ] None
      [ SLet ("y", EBinop (OpAdd, var "x", n 1.0, dl), dl);
        SReturn (var "y", dl) ] in
  check "infer_program: let y = x+1; return y inferred as number"
    (ret_of [ TopFun h ] = Some num);

  (* multi-param: a + b with both annotated number, return inferred number. *)
  let add2 = mkfun "add2"
      [ { param_name = "a"; param_ty = num }; { param_name = "b"; param_ty = num } ]
      None
      [ SReturn (EBinop (OpAdd, var "a", var "b", dl), dl) ] in
  check "infer_program: multi-param a+b return inferred number"
    (ret_of [ TopFun add2 ] = Some num);

  (* graceful bail-out: body references an unknown var -> inference throws
     UnknownVar -> infer_program leaves the fn UNCHANGED (param stays "_"). *)
  let bad = mkfun "bad"
      [ { param_name = "x"; param_ty = TyUser "_" } ] None
      [ SReturn (var "undefined_here", dl) ] in
  check "infer_program: on inference error the fn is left unchanged (param stays \"_\")"
    (param_of [ TopFun bad ] = Some (TyUser "_"));

  Printf.printf "\n%d passed, %d failed\n" !pass !fails;
  if !fails = 0 then exit 0 else exit 1
