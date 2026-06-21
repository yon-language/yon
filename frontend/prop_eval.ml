(* prop_eval.ml — place-aware evaluation of propositions.
 *
 * This module is the operational core of the topos integration: it
 * evaluates expressions and conditions of type "proposition" by
 * inspecting the current place's visibility set. A name not in the
 * visibility set causes the proposition to evaluate to HUnknown,
 * propagating through Heyting operators.
 *
 * The evaluator is used at runtime by the SWhen statement (to choose
 * branches), by the EAll comprehension (to filter), and by any
 * boolean-like context. It is NOT used during type checking — type
 * checking proceeds as usual on the surface AST, and propositions
 * carry their place-relative semantics only at evaluation time.
 *
 * Three evaluation modes:
 *
 *   1. eval_expr_at: evaluate an expr in a given visibility,
 *      returning a Heyting value. Comparisons, equality, and `is`
 *      patterns all flow through here.
 *
 *   2. eval_condition_at: evaluate a surface `condition` in a given
 *      visibility, applying Heyting AND/OR to compose atoms.
 *
 *   3. with_place: a combinator that wraps an evaluation context with
 *      a specific current place.
 *)

open Surface_ast

(* ─── The evaluation context ───────────────────────────────────────── *)

(* The context bundles:
 *   - The kernel reducer (for evaluating subexpressions to terms)
 *   - The visibility table (for all known places)
 *   - The current place's visibility (or global)
 *   - Local bindings: parameters, let-bindings. Always visible.
 *   - Global state: topos-wide values subject to visibility check.
 *     A proposition mentioning a name in global_state evaluates to
 *     HUnknown if the current place doesn't see that name.
 *)

type eval_ctx = {
  ec_table : Place_visibility.vis_table;
  ec_current : Place_visibility.visibility;
  ec_bindings : (string * Ast.term) list;     (* always-visible scope *)
  ec_global_state : (string * Ast.term) list; (* visibility-checked *)
  ec_reducer : Ast.term -> Ast.term;
}

let make_ctx
    (table : Place_visibility.vis_table)
    (current : Place_visibility.visibility)
    (bindings : (string * Ast.term) list)
    (reducer : Ast.term -> Ast.term) : eval_ctx =
  { ec_table = table;
    ec_current = current;
    ec_bindings = bindings;
    ec_global_state = [];
    ec_reducer = reducer; }

let make_ctx_with_global_state
    (table : Place_visibility.vis_table)
    (current : Place_visibility.visibility)
    (bindings : (string * Ast.term) list)
    (global_state : (string * Ast.term) list)
    (reducer : Ast.term -> Ast.term) : eval_ctx =
  { ec_table = table;
    ec_current = current;
    ec_bindings = bindings;
    ec_global_state = global_state;
    ec_reducer = reducer; }

(* Switch to evaluating at a different place. Returns a new context
 * with the place's visibility installed. If the place is unknown,
 * falls back to global visibility (errs on the side of "seeing too
 * much" rather than too little). *)
let with_place (ctx : eval_ctx) (place_name : string) : eval_ctx =
  let new_vis = match Place_visibility.lookup ctx.ec_table place_name with
    | Some v -> v
    | None -> ctx.ec_current   (* unknown place: keep current *)
  in
  { ctx with ec_current = new_vis }

(* Switch to global place: evaluator sees everything. Used at the
 * top-level scope outside any function. *)
let with_global (ctx : eval_ctx) : eval_ctx =
  { ctx with ec_current = Place_visibility.global_visibility }

(* ─── Helper: lookup a binding ─────────────────────────────────────── *)

let lookup_binding (ctx : eval_ctx) (name : string) : Ast.term option =
  match List.assoc_opt name ctx.ec_bindings with
  | Some v -> Some v
  | None -> List.assoc_opt name ctx.ec_global_state

(* ─── Visibility check for an expression ───────────────────────────── *)

(* Given an expression, collect the names it mentions. If any name is
 * not in the current visibility, the expression as a whole becomes
 * "unobservable" from this place — its propositional value is
 * HUnknown.
 *
 * Names that count: variables (EVar) and field accesses (EField).
 * Literals, calls to pure functions, and operator applications do
 * not introduce new visibility constraints (they propagate from
 * their subexpressions).
 *)
let rec collect_names (e : expr) : string list =
  match e with
  | ELit _ -> []
  | EVar (x, _) -> [x]
  | EField (obj, fld, _) -> fld :: collect_names obj
  | ECall (name, args, _) ->
      name :: List.concat_map collect_names args
  | ENew (place_name, fas, _) ->
      place_name :: List.concat_map (fun fa -> collect_names fa.fa_value) fas
  | ENewIn (place_name, _space, fas, _) ->
      place_name :: List.concat_map (fun fa -> collect_names fa.fa_value) fas
  | EBinop (_, a, b, _) -> collect_names a @ collect_names b
  | EApp (f, args, _) -> collect_names f @ List.concat_map collect_names args
  | EHITElim (c, branches, x, _) ->
      collect_names c
      @ List.concat_map (fun (_, vars, e) ->
          List.filter (fun n -> not (List.mem n vars)) (collect_names e)) branches
      @ collect_names x
  | EPathApp (p, _, _) -> collect_names p
  | EPathAbs (_, e, _) -> collect_names e
  | EHITConstr (_, args, _) -> List.concat_map collect_names args
  | EParen (inner, _) -> collect_names inner
  | EAll (place_name, _, _) -> [place_name]
  | EIn (inner, _, _) -> collect_names inner
  | ERefl (e, _) -> collect_names e
  | EPair (a, b, _) -> collect_names a @ collect_names b
  | EFst (p, _) | ESnd (p, _) -> collect_names p
  | EJ (c, d, p, _) -> collect_names c @ collect_names d @ collect_names p
  | EPullback (_, _, _) | EPushout (_, _, _) -> []
  | EPullbackVal (_, _, a, b, _) -> collect_names a @ collect_names b
  | ENot (e, _) -> collect_names e
  | EIfThenElse (c, a, b, _) -> collect_names c @ collect_names a @ collect_names b
  | ELam (_params, body, _) ->
      (* Inline lambda. The free vars of the body minus the parameter names;
       * for now we return only the body (an over-approximation). *)
      collect_names body
  | EMoveLam (_, body, _, _, _)
  | EReductionLam (_, body, _, _) ->
      collect_names body
  | EFunctorLam (_, body, _, _, _, _) ->
      collect_names body
  | EMorphLam (_, body, _, _, _) ->
      collect_names body  (* handle lambda *)
  | EViewLam (_, body, _, _) ->
      collect_names body  (* 5o handle lambda *)
  | EProduce (_, _) | EWireTo (_, _) ->
      []  (* no referable names inside *)
  | EComposeWith (h1, h2, _) ->
      (* compose h1 with h2 — entrambe le sub-expr *)
      collect_names h1 @ collect_names h2
  | ESpawn (count, _body, _) ->
      (match count with Some e -> collect_names e | None -> [])
  | EQuote (_c, a, _) -> collect_names a
  | EElMatch (target, ret, body, _) ->
      collect_names target @ collect_names ret @ collect_names body

(* Are all names mentioned in this expression visible from the current
 * place? A name is visible if:
 *   - It's a local binding (parameter, let): always OK
 *   - The current place's visibility set includes it: OK
 *   - It's in global state but the place doesn't see it: NOT visible
 *)
let all_visible (ctx : eval_ctx) (e : expr) : bool =
  let names = collect_names e in
  List.for_all (fun n ->
    (* Local binding always wins. *)
    List.mem_assoc n ctx.ec_bindings
    (* Otherwise check visibility against the current place. *)
    || (List.mem_assoc n ctx.ec_global_state
        && Place_visibility.sees_name_at ctx.ec_current n)
    (* Names not in either are treated as visible only at global. *)
    || (Place_visibility.is_global ctx.ec_current
        && not (List.mem_assoc n ctx.ec_global_state)))
    names

(* ─── Evaluating an atomic comparison ──────────────────────────────── *)

(* Given a binary comparison (==, !=, <, >, <=, >=), evaluate it.
 * If either operand mentions an invisible name, return HUnknown. *)

let eval_comparison
    (ctx : eval_ctx)
    (op : binop)
    (lhs : expr) (rhs : expr) : Heyting.heyt_value =
  if not (all_visible ctx lhs) || not (all_visible ctx rhs) then
    Heyting.HUnknown
  else
    (* Both sides visible: compute by reducing each side to a term
     * and comparing the resulting encoded values. *)
    let _lhs_term = ctx.ec_reducer (Ast.Var "_lhs_placeholder") in
    let _rhs_term = ctx.ec_reducer (Ast.Var "_rhs_placeholder") in
    (* For the prototype, we delegate to a simple lookup: bindings
     * carry encoded terms, so we evaluate by binding. A full impl
     * would translate the surface expr to Yon Core and run the
     * kernel. *)
    let resolve e =
      match e with
      | ELit (LitNumber n, _) -> Some (`Num n)
      | ELit (LitString s, _) -> Some (`Str s)
      | ELit (LitBool b, _) -> Some (`Bool b)
      | EVar (x, _) ->
          (match lookup_binding ctx x with
           | Some t ->
               (match Builtins.decode_number t with
                | Some n -> Some (`Num n)
                | None ->
                    match Builtins.decode_string t with
                    | Some s -> Some (`Str s)
                    | None ->
                        match Builtins.decode_bool t with
                        | Some b -> Some (`Bool b)
                        | None -> None)
           | None -> None)
      | _ -> None
    in
    match resolve lhs, resolve rhs with
    | Some (`Num a), Some (`Num b) ->
        let result = (match op with
          | OpEq -> a = b
          | OpNeq -> a <> b
          | OpLt -> a < b
          | OpGt -> a > b
          | OpLeq -> a <= b
          | OpGeq -> a >= b
          | _ -> false) in
        Heyting.from_bool result
    | Some (`Str a), Some (`Str b) ->
        let result = (match op with
          | OpEq -> a = b
          | OpNeq -> a <> b
          | _ -> false) in
        Heyting.from_bool result
    | Some (`Bool a), Some (`Bool b) ->
        let result = (match op with
          | OpEq -> a = b
          | OpNeq -> a <> b
          | _ -> false) in
        Heyting.from_bool result
    | _ -> Heyting.HUnknown   (* couldn't resolve: treat as unknown *)

(* ─── Evaluating an expression as a proposition ────────────────────── *)

let rec eval_expr_at (ctx : eval_ctx) (e : expr) : Heyting.heyt_value =
  match e with
  | ELit (LitBool b, _) -> Heyting.from_bool b
  | EVar (x, _) ->
      (* Visibility check: local always OK, global_state subject to
       * current place's visibility. *)
      let visible =
        List.mem_assoc x ctx.ec_bindings
        || (List.mem_assoc x ctx.ec_global_state
            && Place_visibility.sees_name_at ctx.ec_current x)
        || (Place_visibility.is_global ctx.ec_current
            && not (List.mem_assoc x ctx.ec_global_state))
      in
      if not visible then Heyting.HUnknown
      else
        (match lookup_binding ctx x with
         | None -> Heyting.HUnknown
         | Some t ->
             match Heyting.decode_heyt t with
             | Some v -> v
             | None ->
                 match Builtins.decode_bool t with
                 | Some b -> Heyting.from_bool b
                 | None -> Heyting.HUnknown)
  | EBinop (OpAnd, a, b, _) ->
      Heyting.h_and (eval_expr_at ctx a) (eval_expr_at ctx b)
  | EBinop (OpOr, a, b, _) ->
      Heyting.h_or (eval_expr_at ctx a) (eval_expr_at ctx b)
  | EBinop ((OpEq | OpNeq | OpLt | OpGt | OpLeq | OpGeq) as op, a, b, _) ->
      eval_comparison ctx op a b
  | EParen (inner, _) -> eval_expr_at ctx inner
  | ECall ("__heyt_not", [inner], _) ->
      Heyting.h_not (eval_expr_at ctx inner)
  | _ ->
      (* Other expressions (calls, field access, arithmetic) are not
       * proposition-yielding in surface syntax. We conservatively
       * return HUnknown — they shouldn't appear in a condition. *)
      Heyting.HUnknown

(* ─── Evaluating a full condition ──────────────────────────────────── *)

(* A condition combines an expr with optional pattern-matching atoms.
 * Heyting semantics applies throughout. *)

let rec eval_condition_at (ctx : eval_ctx) (c : condition) : Heyting.heyt_value =
  match c with
  | CondExpr e -> eval_expr_at ctx e
  | CondIs (e, p) -> eval_is_pattern ctx e p false
  | CondIsNot (e, p) ->
      Heyting.h_not (eval_is_pattern ctx e p false)
  | CondAnd (c1, c2) ->
      Heyting.h_and (eval_condition_at ctx c1) (eval_condition_at ctx c2)
  | CondOr (c1, c2) ->
      Heyting.h_or (eval_condition_at ctx c1) (eval_condition_at ctx c2)

(* The `is` pattern test. The Heyting tri-values (present, absent,
 * unknown) appear as patterns; matching against one of them queries
 * the place's view of the value. *)
and eval_is_pattern (ctx : eval_ctx) (e : expr) (p : pattern)
                    (_negated : bool) : Heyting.heyt_value =
  (* First check visibility: if the expression's names are not visible,
   * the answer to "is e present" is unknown. *)
  if not (all_visible ctx e) then Heyting.HUnknown
  else
    match p with
    | PatPresent ->
        (* Is the value present? It is present iff we can resolve it
         * to a concrete encoded value (or to HPresent). *)
        (match resolve_to_heyt ctx e with
         | Heyting.HPresent | Heyting.HAbsent -> Heyting.HPresent
         | Heyting.HUnknown -> Heyting.HAbsent)
        (* "is present" is itself present when we know the answer
         * (whether positive or negative); it's absent when we don't.
         * This pivot is the operational realization of the Heyting
         * semantics for the predicate "x has a definite value". *)
    | PatAbsent ->
        (* Is the value absent? Symmetric. *)
        (match resolve_to_heyt ctx e with
         | Heyting.HAbsent -> Heyting.HPresent
         | Heyting.HPresent -> Heyting.HAbsent
         | Heyting.HUnknown -> Heyting.HUnknown)
    | PatUnknown ->
        (* Is the value unknown? *)
        (match resolve_to_heyt ctx e with
         | Heyting.HUnknown -> Heyting.HPresent
         | _ -> Heyting.HAbsent)
    | PatVar _ ->
        (* Variable patterns always match: produce HPresent. *)
        Heyting.HPresent
    | PatLit l ->
        (* Literal patterns: compare the expression's value to the
         * literal. This is an equality check, place-aware. *)
        eval_comparison ctx OpEq e (ELit (l, dummy_loc))
    | PatType _ ->
        (* Type-pattern matching: at runtime, we don't carry type
         * tags on values in the prototype, so we conservatively say
         * HPresent (pattern matches structurally). *)
        Heyting.HPresent

(* Resolve an expression to a Heyting value, respecting visibility. *)
and resolve_to_heyt (ctx : eval_ctx) (e : expr) : Heyting.heyt_value =
  if not (all_visible ctx e) then Heyting.HUnknown
  else
    match e with
    | EVar (x, _) ->
        (match lookup_binding ctx x with
         | Some t ->
             (match Heyting.decode_heyt t with
              | Some v -> v
              | None -> Heyting.HPresent)  (* visible & bound: present *)
         | None -> Heyting.HUnknown)
    | ELit _ -> Heyting.HPresent
    | _ -> eval_expr_at ctx e
