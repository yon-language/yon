(* hm_infer.ml — full Algorithm W for Yon
 *
 * Constraint generation profonda + solve via Ty_subst.
 *
 * Builds a mapping `var -> ty` for each variable (param, let-binding) and
 * for each expression of the body, generating equality
 * constraints and solving them with unify.
 *
 * Three modes of use:
 *   1. infer_fun_decl fn -> a fun_decl with resolved types (substitutes
 *      param_ty TyUser "_" or TyMetaVar and fn_return None with the inferred
 *      types). Idempotent if already annotated.
 *   2. infer_program p -> the whole program with all funs updated.
 *   3. typecheck_expr env e -> the resulting ty or an error (for use by other
 *      passes).
 *
 * Honest limits:
 *   - No generalization of internal let-bindings (let-polymorphism); only at
 *     the level of top-level fun_decl.
 *   - Recursion: each fun is assumed with its partial signature before the
 *     walk of the body. No Mycroft-Tofte fixpoint.
 *   - Stdlib: uses Stdlib_runtime.lookup_stdlib_signature to obtain the types
 *     of the builtins (List.cons, Map.get, etc.).
 *)

open Surface_ast
open Ty_subst

(* ─── Errori ──────────────────────────────────────────────────────────── *)

type infer_error =
  | UnifyFailed of unify_error * location * string
      (* unify_error, location, contesto descrittivo *)
  | UnknownVar of string * location
  | UnknownFun of string * location
  | ArityMismatch of string * int * int * location
      (* fname, expected, got, loc *)

exception Infer_error of infer_error

(* ─── Environment locale per inference ────────────────────────────────── *)

(* The local env tracks:
 *   - var_types: local variables (param, let) -> ty (may contain metavars)
 *   - fun_types: top-level functions -> type scheme
 *   - stdlib: builtin lookup via Stdlib_runtime *)
type env = {
  var_types : (string * ty) list;
  fun_types : (string * scheme) list;
}

let empty_env = { var_types = []; fun_types = [] }

let add_var env x t = { env with var_types = (x, t) :: env.var_types }
let add_fun env f s = { env with fun_types = (f, s) :: env.fun_types }

let lookup_var env x = List.assoc_opt x env.var_types
let lookup_fun env f = List.assoc_opt f env.fun_types

(* ─── Constraint storage ──────────────────────────────────────────────── *)

(* Accumulates type-equality constraints during the walk, solved together at
 * the end of the fun_decl inference. *)
type constraint_set = {
  mutable constraints : (ty * ty * location * string) list;
}

let new_constraints () = { constraints = [] }

let add_constraint cs a b loc ctx =
  cs.constraints <- (a, b, loc, ctx) :: cs.constraints

(* Solve all the accumulated constraints. Returns the final substitution.
 * Strategy: fold with unify, propagating the substitution incrementally. *)
let solve_constraints (cs : constraint_set) : subst =
  List.fold_left (fun sigma (a, b, loc, ctx) ->
    let a' = apply_subst sigma a in
    let b' = apply_subst sigma b in
    match try_unify a' b' with
    | Ok s -> compose_subst s sigma
    | Error e -> raise (Infer_error (UnifyFailed (e, loc, ctx)))
  ) empty_subst (List.rev cs.constraints)

(* ─── Infer expression ────────────────────────────────────────────────── *)

let num = TyPrim "number"
let bool_ty = TyPrim "boolean"
let txt = TyPrim "text"

let rec infer_expr (env : env) (cs : constraint_set) (e : expr) : ty =
  match e with
  | ELit (LitNumber _, _) -> num
  | ELit (LitString _, _) -> txt
  | ELit (LitBool _, _) -> bool_ty
  | ELit (LitDuration _, _) -> num
  | EVar (x, loc) ->
      (match lookup_var env x with
       | Some t -> t
       | None ->
           (* It may be a reference to a top-level function passed as a value
            * (e.g. apply(inc, 5), where inc is a function used as an argument).
            * We build the TyArrow from the scheme. *)
           (match lookup_fun env x with
            | Some sch -> instantiate sch
            | None -> raise (Infer_error (UnknownVar (x, loc)))))
  | EParen (inner, _) -> infer_expr env cs inner
  | EBinop (op, a, b, loc) ->
      let ta = infer_expr env cs a in
      let tb = infer_expr env cs b in
      (match op with
       | OpAdd | OpSub | OpMul | OpDiv | OpMod ->
           add_constraint cs ta num loc "binop LHS expects number";
           add_constraint cs tb num loc "binop RHS expects number";
           num
       | OpEq | OpNeq ->
           add_constraint cs ta tb loc "equality requires same type";
           bool_ty
       | OpLt | OpGt | OpLeq | OpGeq ->
           add_constraint cs ta num loc "comparison LHS expects number";
           add_constraint cs tb num loc "comparison RHS expects number";
           bool_ty
       | OpAnd | OpOr ->
           add_constraint cs ta bool_ty loc "logical LHS expects boolean";
           add_constraint cs tb bool_ty loc "logical RHS expects boolean";
           bool_ty)
  | ENot (inner, loc) ->
      let t = infer_expr env cs inner in
      add_constraint cs t bool_ty loc "not expects boolean";
      bool_ty
  | EIfThenElse (cond, then_e, else_e, loc) ->
      let tc = infer_expr env cs cond in
      add_constraint cs tc bool_ty loc "if condition must be boolean";
      let tt = infer_expr env cs then_e in
      let te = infer_expr env cs else_e in
      add_constraint cs tt te loc "if branches must have same type";
      tt
  | ECall (fname, args, loc) ->
      (* Three cases:
       *   (a) fname is a local variable of type TyArrow -> direct application
       *   (b) fname is a top-level fun -> instantiate the scheme, unify
       *   (c) fname is a stdlib builtin -> look it up in Stdlib_runtime *)
      let arg_tys = List.map (infer_expr env cs) args in
      let result_ty = fresh_metavar () in
      (match lookup_var env fname with
       | Some var_ty ->
           (* Case (a): application of a function parameter *)
           let expected_ty = build_arrow_chain arg_tys result_ty in
           add_constraint cs var_ty expected_ty loc
             (Printf.sprintf "applying %s as function" fname);
           result_ty
       | None ->
           (match lookup_fun env fname with
            | Some sch ->
                (* Caso (b): fun top-level, monomorfizza via instantiate *)
                let inst_ty = instantiate sch in
                let expected_ty = build_arrow_chain arg_tys result_ty in
                add_constraint cs inst_ty expected_ty loc
                  (Printf.sprintf "call to %s" fname);
                result_ty
            | None ->
                (* Case (c): stdlib lookup. If missing, an error. *)
                match Stdlib_runtime.lookup_stdlib_signature fname with
                | Some (param_tys, ret_ty) ->
                    if List.length param_tys <> List.length arg_tys then
                      raise (Infer_error
                        (ArityMismatch (fname, List.length param_tys,
                                        List.length arg_tys, loc)));
                    List.iter2 (fun got expected ->
                      (* For generic stdlib (TyUser n with n in type_params),
                       * generate a fresh meta-variable; for concrete ones,
                       * unify directly. *)
                      add_constraint cs got expected loc
                        (Printf.sprintf "stdlib %s arg" fname)
                    ) arg_tys param_tys;
                    ret_ty
                | None ->
                    (* Graceful fallback: return a fresh meta-variable. The
                     * downstream tycheck will catch the error with a more
                     * informative message. *)
                    fresh_metavar ()))
  | _ ->
      (* All the other constructs (ENew, EField, EAll, EPullbackPack, ...) are
       * not yet handled by full HM. Return a fresh meta-variable as a graceful
       * fallback; the downstream tycheck verifies them. *)
      fresh_metavar ()

(* build_arrow_chain [a; b; c] r = a -> b -> c -> r (right-assoc) *)
and build_arrow_chain (args : ty list) (ret : ty) : ty =
  match args with
  | [] -> ret
  | t :: rest -> TyArrow (t, build_arrow_chain rest ret)

(* ─── Infer stmt body ─────────────────────────────────────────────────── *)

(* Scan the body of a function, collecting the types of the lets and the
 * returns. Returns the updated env plus the return type (if any) as a union of
 * meta-variables (one per return statement, constrained to be equal). *)
let rec infer_stmts (env : env) (cs : constraint_set) (return_ty : ty)
                    (stmts : stmt list) : env =
  List.fold_left (fun env s -> infer_stmt env cs return_ty s) env stmts

and infer_stmt (env : env) (cs : constraint_set) (return_ty : ty)
               (s : stmt) : env =
  match s with
  | SLet (name, e, _) ->
      let t = infer_expr env cs e in
      add_var env name t
  | SAssignHolds (_, e, _) | SAssignBecomes (_, e, _) ->
      let _ = infer_expr env cs e in env
  | SReturn (e, loc) ->
      let t = infer_expr env cs e in
      add_constraint cs t return_ty loc "return type";
      env
  | SCall (fname, args, loc) ->
      (* Treat SCall as an ECall, discarding the result *)
      let _ = infer_expr env cs (ECall (fname, args, loc)) in env
  | SWhen (c, body, alts, otherwise, loc) ->
      infer_condition env cs c loc;
      let _ = infer_stmts env cs return_ty body in
      List.iter (fun (alt_c, alt_body) ->
        infer_condition env cs alt_c loc;
        let _ = infer_stmts env cs return_ty alt_body in ()
      ) alts;
      (match otherwise with
       | Some os -> let _ = infer_stmts env cs return_ty os in ()
       | None -> ());
      env
  | SIter (n, body, loc) ->
      let tn = infer_expr env cs n in
      add_constraint cs tn num loc "iter count must be number";
      let _ = infer_stmts env cs return_ty body in env
  | SWhile (c, body, loc) ->
      let tc = infer_expr env cs c in
      add_constraint cs tc bool_ty loc "while condition must be boolean";
      let _ = infer_stmts env cs return_ty body in env
  | SForever (body, _) ->
      let _ = infer_stmts env cs return_ty body in env
  | _ ->
      (* Other statements (SNew, SForEvery, etc.) are not handled here;
       * the env is unchanged. They are caught by the main type checker. *)
      env

(* Infer a condition (CondExpr | CondIs | CondAnd | CondOr) and constrain the
 * sub-expression to boolean where appropriate. Returns unit because all
 * conditions are semantically boolean. *)
and infer_condition (env : env) (cs : constraint_set)
                    (c : condition) (loc : location) : unit =
  match c with
  | CondExpr e ->
      let t = infer_expr env cs e in
      add_constraint cs t bool_ty loc "condition must be boolean"
  | CondIs (e, _) | CondIsNot (e, _) ->
      (* "e is pattern" — the sub-expression may have any type (proposition,
       * sum, etc.). We add no constraint. *)
      let _ = infer_expr env cs e in ()
  | CondAnd (c1, c2) | CondOr (c1, c2) ->
      infer_condition env cs c1 loc;
      infer_condition env cs c2 loc

(* ─── Infer fun_decl ──────────────────────────────────────────────────── *)

(* Replace residual (unresolved) meta-variables with TyPrim "unknown", for
 * compatibility with the downstream tycheck which does not know meta-vars. *)
let rec metavar_to_unknown (t : ty) : ty =
  match t with
  | TyMetaVar _ -> TyPrim "unknown"
  | TyList inner -> TyList (metavar_to_unknown inner)
  | TyMap (k, v) -> TyMap (metavar_to_unknown k, metavar_to_unknown v)
  | TyStream inner -> TyStream (metavar_to_unknown inner)
  | TyArrow (a, b) -> TyArrow (metavar_to_unknown a, metavar_to_unknown b)
  | TyPi (x, a, b) -> TyPi (x, metavar_to_unknown a, metavar_to_unknown b)
  | TySigma (x, a, b) -> TySigma (x, metavar_to_unknown a, metavar_to_unknown b)
  | TyId (a, x, y) -> TyId (metavar_to_unknown a, x, y)
  | _ -> t

(* Pre-step: build the initial fun_types from the whole program, treating each
 * fun_decl as an open scheme. The "_" and None are replaced with fresh
 * meta-variables; explicit annotations are kept. *)
let build_initial_fun_env (p : program) : env =
  List.fold_left (fun env top ->
    match top with
    | TopFun fn ->
        let param_tys = List.map (fun p ->
          match p.param_ty with
          | TyUser "_" -> fresh_metavar ()
          | t -> t
        ) fn.fn_params in
        let ret_ty = match fn.fn_return with
          | Some t -> t
          | None -> fresh_metavar ()
        in
        let fn_ty = build_arrow_chain param_tys ret_ty in
        (* An open scheme: no quantification (it will be generalized later). *)
        let sch = { bound = []; body = fn_ty } in
        add_fun env fn.fn_name sch
    | _ -> env
  ) empty_env p

(* infer_fun_decl: update fn with inferred types. A parameter type stays
 * unchanged if already annotated; "_" -> inferred type; fn_return None ->
 * inferred type. *)
let infer_fun_decl (env0 : env) (fn : fun_decl) : fun_decl =
  let cs = new_constraints () in
  (* Build the local env with the parameters. For a "_" parameter, use the
   * meta-variable already placed in env0's fun_types. *)
  let fn_sch = match lookup_fun env0 fn.fn_name with
    | Some s -> s
    | None -> failwith ("hm_infer: fun " ^ fn.fn_name ^ " not in env")
  in
  (* Decompose fn_sch.body as an arrow chain -> extract param_tys + ret_ty *)
  let rec decompose t n =
    if n = 0 then ([], t)
    else match t with
      | TyArrow (a, b) ->
          let (rest, ret) = decompose b (n - 1) in
          (a :: rest, ret)
      | _ -> failwith "hm_infer: fun signature not arrow chain"
  in
  let n_params = List.length fn.fn_params in
  let (init_param_tys, init_ret_ty) = decompose fn_sch.body n_params in
  let local_env = List.fold_left2 (fun env p t ->
    add_var env p.param_name t
  ) env0 fn.fn_params init_param_tys in
  (* Walk the body *)
  let _ = infer_stmts local_env cs init_ret_ty fn.fn_body in
  (* Solve constraints *)
  let sigma = solve_constraints cs in
  (* Apply the final substitution to the parameter types and the return *)
  let final_param_tys = List.map (apply_subst sigma) init_param_tys in
  let final_ret_ty = apply_subst sigma init_ret_ty in
  (* Substitute in the fn only where there was a "_" or None *)
  let new_params = List.map2 (fun p inferred ->
    match p.param_ty with
    | TyUser "_" -> { p with param_ty = metavar_to_unknown inferred }
    | _ -> p
  ) fn.fn_params final_param_tys in
  let new_return = match fn.fn_return with
    | Some t -> Some t
    | None -> Some (metavar_to_unknown final_ret_ty)
  in
  { fn with fn_params = new_params; fn_return = new_return }

(* ─── Top-level: infer_program ────────────────────────────────────────── *)

let infer_program (p : program) : program =
  reset_metavars ();
  let env0 = build_initial_fun_env p in
  List.map (function
    | TopFun fn ->
        (try TopFun (infer_fun_decl env0 fn)
         with Infer_error _ ->
           (* On an HM error, leave the fn unchanged; the downstream tycheck
            * will produce a clearer message. *)
           TopFun fn)
    | other -> other
  ) p
