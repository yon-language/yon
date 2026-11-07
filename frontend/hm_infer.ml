(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
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
 *   - Recursion is monomorphic: a group of mutually recursive funs is inferred
 *     together, one type for each inside the group, and generalized after it.
 *     No Mycroft-Tofte fixpoint.
 *   - Stdlib: uses Stdlib_runtime.lookup_stdlib_signature to obtain the types
 *     of the builtins (List.cons, HashMap.get).
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
let rec solve_pair (sigma : subst) (a : ty) (b : ty) loc ctx : subst =
  let a = apply_subst sigma a and b = apply_subst sigma b in
  match a, b with
  (* Two paths: the carriers agree. Their ends are terms, and the checker compares
     terms by conversion; a carrier not resolved yet (the negative sentinel) it
     reads off the left end. Ty_subst.unify keeps no path arm of its own. *)
  | TyId (TyMetaVar n, _, _), TyId _ when n < 0 -> sigma
  | TyId _, TyId (TyMetaVar n, _, _) when n < 0 -> sigma
  | TyId (a1, _, _), TyId (a2, _, _) -> solve_pair sigma a1 a2 loc ctx
  | TyArrow (a1, b1), TyArrow (a2, b2) ->
      solve_pair (solve_pair sigma a1 a2 loc ctx) b1 b2 loc ctx
  | _ ->
      match try_unify a b with
      | Ok s -> compose_subst s sigma
      | Error e -> raise (Infer_error (UnifyFailed (e, loc, ctx)))

let solve_constraints (cs : constraint_set) : subst =
  List.fold_left (fun sigma (a, b, loc, ctx) -> solve_pair sigma a b loc ctx)
    empty_subst (List.rev cs.constraints)

(* A name read by the inference: which funs a body depends on. *)
let reads : string list ref = ref []
let note_read (name : string) : unit = reads := name :: !reads

(* The names of the parameters of a fun, for a path type over them. *)
let param_names : (string, string list) Hashtbl.t = Hashtbl.create 16

(* A fused face is its carrier. *)
let normalize (t : ty) : ty =
  map_leaves (function
    | TyUser "Text" -> Some (TyPrim "text")
    | TyUser u -> Option.map (fun p -> TyPrim p) (prim_of_face u)
    | _ -> None) t

(* A path type in the signature of a fun is over its parameters: at a call they
   are the arguments, all at once, since an argument may name a parameter. *)
let at_arguments (fname : string) (args : expr list) (t : ty) : ty =
  match Hashtbl.find_opt param_names fname with
  | Some ps when List.length ps = List.length args ->
      let held = List.mapi (fun i p -> (p, Printf.sprintf "__arg_%d" i)) ps in
      let at (TyTermExpr e) =
        let e = List.fold_left (fun e (p, h) ->
            Desugar.subst_evar_in_expr p (EVar (h, dummy_loc)) e) e held in
        TyTermExpr (List.fold_left2 (fun e (_, h) a ->
            Desugar.subst_evar_in_expr h a e) e held args) in
      map_leaves (function
        | TyId (a, x, y) -> Some (TyId (a, at x, at y))
        | _ -> None) t
  | _ -> t

(* ─── Infer expression ────────────────────────────────────────────────── *)

let num = TyPrim "number"
let bool_ty = TyPrim "boolean"
let txt = TyPrim "text"

let open_world = ref false

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
           (note_read x;
            match lookup_fun env x with
            | Some sch -> instantiate sch
            (* a bare point or a place: the checker reads it *)
            | None when !open_world -> fresh_metavar ()
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
           (note_read fname;
            match lookup_fun env fname with
            | Some sch ->
                (* Caso (b): fun top-level, monomorfizza via instantiate *)
                let inst_ty = at_arguments fname args (instantiate sch) in
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
                      add_constraint cs got (normalize expected) loc
                        (Printf.sprintf "stdlib %s arg" fname)
                    ) arg_tys param_tys;
                    normalize ret_ty
                | None ->
                    (* Graceful fallback: return a fresh meta-variable. The
                     * downstream tycheck will catch the error with a more
                     * informative message. *)
                    fresh_metavar ()))
  | _ ->
      (* All the other constructs (ENew, EField, EAll, EPullbackPack, ...) are
       * not handled by full HM. Return a fresh meta-variable as a graceful
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

(* What is left of a RETURN type no use fixes, for the downstream tycheck, which
 * does not know meta-vars. A parameter never comes here: it is a type or a type
 * variable. *)
let rec metavar_to_unknown (t : ty) : ty =
  match t with
  | TyMetaVar _ -> TyPrim "unknown"
  | TyApp ("List", [inner]) -> TyApp ("List", [metavar_to_unknown inner])
  | TyMap (k, v) -> TyMap (metavar_to_unknown k, metavar_to_unknown v)
  | TyChannel inner -> TyChannel (metavar_to_unknown inner)
  | TyArrow (a, b) -> TyArrow (metavar_to_unknown a, metavar_to_unknown b)
  | TyPi (x, a, b) -> TyPi (x, metavar_to_unknown a, metavar_to_unknown b)
  | TySigma (x, a, b) -> TySigma (x, metavar_to_unknown a, metavar_to_unknown b)
  | TyId (a, x, y) -> TyId (metavar_to_unknown a, x, y)
  | _ -> t

let is_open (fn : fun_decl) : bool =
  List.exists (fun p -> p.param_ty = TyUser "_") fn.fn_params

let needs_inference (fn : fun_decl) : bool =
  is_open fn || fn.fn_return = None

(* The signature of a fun as the bodies read it. A fun fully written is a closed
 * scheme, its type parameters quantified. A fun to infer has its unknowns, open
 * until its group is done. *)
let initial_scheme (fn : fun_decl) : scheme =
  let tparams = List.map (fun v -> (v, fresh_metavar ())) fn.fn_type_params in
  let of_decl t =
    normalize (map_leaves (function
      | TyUser v when List.mem_assoc v tparams -> Some (List.assoc v tparams)
      | _ -> None) t) in
  let param_tys = List.map (fun p ->
    match p.param_ty with
    | TyUser "_" -> fresh_metavar ()
    | t -> of_decl t) fn.fn_params in
  let ret_ty = match fn.fn_return with
    | Some t -> of_decl t
    | None -> fresh_metavar () in
  let body = build_arrow_chain param_tys ret_ty in
  { bound = List.filter_map (function (_, TyMetaVar n) -> Some n | _ -> None) tparams; body }

let rec decompose t n =
  if n = 0 then ([], t)
  else match t with
    | TyArrow (a, b) ->
        let (rest, ret) = decompose b (n - 1) in
        (a :: rest, ret)
    | _ -> failwith "hm_infer: fun signature not arrow chain"

let walk_body (env : env) (cs : constraint_set) (fn : fun_decl) (sch : scheme) : unit =
  let (param_tys, ret_ty) = decompose sch.body (List.length fn.fn_params) in
  let local_env = List.fold_left2 (fun env p t ->
    add_var env p.param_name t) env fn.fn_params param_tys in
  ignore (infer_stmts local_env cs ret_ty fn.fn_body)

(* The groups of mutually recursive funs, the ones a group calls first (Tarjan). *)
let recursive_groups (funs : string list) (calls : string -> string list) : string list list =
  let index = Hashtbl.create 16 and low = Hashtbl.create 16 in
  let on_stack = Hashtbl.create 16 in
  let stack = ref [] and next = ref 0 and groups = ref [] in
  let rec visit v =
    Hashtbl.replace index v !next;
    Hashtbl.replace low v !next;
    incr next;
    stack := v :: !stack;
    Hashtbl.replace on_stack v ();
    List.iter (fun w ->
      if not (Hashtbl.mem index w) then begin
        visit w;
        Hashtbl.replace low v (min (Hashtbl.find low v) (Hashtbl.find low w))
      end else if Hashtbl.mem on_stack w then
        Hashtbl.replace low v (min (Hashtbl.find low v) (Hashtbl.find index w)))
      (calls v);
    if Hashtbl.find low v = Hashtbl.find index v then begin
      let rec pop acc =
        match !stack with
        | [] -> acc
        | w :: rest ->
            stack := rest;
            Hashtbl.remove on_stack w;
            if w = v then w :: acc else pop (w :: acc) in
      groups := pop [] :: !groups
    end in
  List.iter (fun v -> if not (Hashtbl.mem index v) then visit v) funs;
  List.rev !groups

(* Generalization, for a fun of a group already solved: each unknown still free
 * in its parameters is a type parameter, exactly as if the fun were written with
 * <T>. At top level no unknown is free in the environment: what an earlier group
 * fixed is closed, and an open one of this group is free only in this group. *)
let type_param_names (taken : string -> bool) (fn : fun_decl) (n : int) : string list =
  let rec go i acc k =
    if k = 0 then List.rev acc
    else
      let name = if i = 1 then "T" else Printf.sprintf "T%d" i in
      if taken name || List.mem name fn.fn_type_params then go (i + 1) acc k
      else go (i + 1) (name :: acc) (k - 1) in
  go 1 [] n

let generalized (taken : string -> bool) (sigma : subst) (fn : fun_decl) (sch : scheme)
    : fun_decl * scheme =
  let (param_tys, ret_ty) = decompose (apply_subst sigma sch.body) (List.length fn.fn_params) in
  let open_params = List.concat (List.map2 (fun p t ->
      if p.param_ty = TyUser "_" then free_metavars t else []) fn.fn_params param_tys) in
  let free = List.filter (fun n -> n >= 0) (List.sort_uniq compare open_params) in
  let names = List.combine free (type_param_names taken fn (List.length free)) in
  let named t = map_leaves (function
    | TyMetaVar n when List.mem_assoc n names -> Some (TyUser (List.assoc n names))
    | _ -> None) t in
  let fn_params = List.map2 (fun p t ->
    if p.param_ty = TyUser "_" then { p with param_ty = named t } else p) fn.fn_params param_tys in
  let fn_return = match fn.fn_return with
    | Some t -> Some t
    | None -> Some (metavar_to_unknown (named ret_ty)) in
  ({ fn with fn_params; fn_return;
             fn_type_params = fn.fn_type_params @ List.map snd names },
   { bound = free; body = apply_subst sigma sch.body })

(* ─── Top-level: infer_program ────────────────────────────────────────── *)

(* A parameter without annotation whose uses do not agree: the checker reports
   these, the fun is left as it was. *)
let parameter_errors : (location * string) list ref = ref []

let infer_program (p : program) : program =
  reset_metavars ();
  parameter_errors := [];
  Hashtbl.reset param_names;
  open_world := true;
  let funs = List.filter_map (function TopFun fn -> Some fn | _ -> None) p in
  List.iter (fun fn ->
    Hashtbl.replace param_names fn.fn_name (List.map (fun q -> q.param_name) fn.fn_params)) funs;
  let taken name =
    List.exists (function
      | TopPlace pd -> pd.pd_name = name
      | _ -> false) p in
  let env = ref (List.fold_left (fun env fn ->
    add_fun env fn.fn_name (initial_scheme fn)) empty_env funs) in
  let to_infer = List.filter needs_inference funs in
  let find name = List.find_opt (fun fn -> fn.fn_name = name) to_infer in
  (* which of the funs to infer a body reads *)
  let calls name =
    match find name with
    | None -> []
    | Some fn ->
        reads := [];
        (try walk_body !env (new_constraints ()) fn (Option.get (lookup_fun !env name))
         with Infer_error _ -> ());
        List.filter (fun w -> find w <> None) (List.sort_uniq compare !reads) in
  let results = Hashtbl.create 16 in
  List.iter (fun group ->
    let group_funs = List.filter_map find group in
    let scheme_of fn = Option.get (lookup_fun !env fn.fn_name) in
    let cs = new_constraints () in
    match
      List.iter (fun fn -> walk_body !env cs fn (scheme_of fn)) group_funs;
      solve_constraints cs
    with
    | sigma ->
        List.iter (fun fn ->
          let (fn', sch) = generalized taken sigma fn (scheme_of fn) in
          Hashtbl.replace results fn.fn_name fn';
          env := add_fun !env fn.fn_name sch) group_funs
    | exception Infer_error why ->
        (* the fun stays as it was; a parameter without annotation is refused *)
        List.iter (fun fn ->
          if is_open fn then begin
            let detail = match why with
              | UnifyFailed (e, _, ctx) ->
                  Printf.sprintf "%s: %s" ctx (unify_error_to_string e)
              | ArityMismatch (f, want, got, _) ->
                  Printf.sprintf "%s expects %d arguments, got %d" f want got
              | UnknownVar (x, _) | UnknownFun (x, _) -> "unknown name " ^ x in
            let unannotated = List.filter_map (fun q ->
                if q.param_ty = TyUser "_" then Some q.param_name else None) fn.fn_params in
            parameter_errors := (fn.fn_loc, Printf.sprintf
              "fun %s: the uses of its parameter%s without annotation (%s) do not agree: %s: \
               annotate the parameter"
              fn.fn_name
              (if List.length unannotated > 1 then "s" else "")
              (String.concat ", " unannotated) detail) :: !parameter_errors
          end) group_funs)
    (recursive_groups (List.map (fun fn -> fn.fn_name) to_infer) calls);
  open_world := false;
  parameter_errors := List.rev !parameter_errors;
  List.map (function
    | TopFun fn ->
        (match Hashtbl.find_opt results fn.fn_name with
         | Some fn' when needs_inference fn -> TopFun fn'
         | _ -> TopFun fn)
    | other -> other) p
