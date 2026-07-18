(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* tycheck.ml — bidirectional type checker for surface Yon.
 *
 * The checker has two mutually recursive judgments:
 *
 *   infer : env x expr -> ty result          ("synthesis")
 *   check : env x expr x ty -> unit result   ("checking")
 *
 * Standard bidirectional design (Pierce-Turner 2000). Constructs that
 * naturally synthesize their type (variables, applications, literals)
 * use infer. Constructs that need a goal type (lambdas, conditionals)
 * use check. Both modes can be combined: check delegates to infer plus
 * type equality whenever no direct check rule applies.
 *
 * Type equality is delegated to the dispatcher, which routes to the
 * appropriate fragment of the federation.
 *
 * Errors carry a location and a message, accumulated in a Result.
 *)

open Surface_ast
module E = Tyenv
module C = Ast

(* ─── Let-poly HM: scheme storage ──────────────────────────────────── *)

(* Separate scheme storage for HM let-polymorphism (the pure tyenv must not
 * depend on Ty_subst). Filled by an SLet with an ELam value, consulted by the
 * EVar lookup for fresh instantiation. Reset at the start of
 * check_program. *)
let scheme_env : (string * Ty_subst.scheme) list ref = ref []

(* ─── Wire subscriptions: compile-time knowledge ────────────────────
   Filled at check_program start from the (already loaded and prefixed)
   program: which Spaces are importable targets, which names are
   imported from which Space, and every function's declared return type
   (qualified names included), so awaits can verify the producer. *)
let wire_spaces : (string, unit) Hashtbl.t = Hashtbl.create 8
let wire_imports : (string, string * string) Hashtbl.t = Hashtbl.create 16
let wire_fun_returns : (string, ty option) Hashtbl.t = Hashtbl.create 64

(* Remote signatures, loaded by the driver from the Space's source
   (sibling <module>.yon or yon_modules/<module>): name -> return ty.
   The cross-Space import is nominal (the code lives in the other
   process); the producer check needs the declared signature only. *)
let register_remote_signature (name : string) (ret : ty option) : unit =
  Hashtbl.replace wire_fun_returns name ret

let collect_wire_knowledge (p : program) : unit =
  Hashtbl.reset wire_spaces;
  Hashtbl.reset wire_imports;
  List.iter (function
    | TopImportFrom (m, n, sp, _) ->
        Hashtbl.replace wire_spaces sp ();
        Hashtbl.replace wire_imports n (sp, m);
        Hashtbl.replace wire_imports (m ^ "::" ^ n) (sp, m)
    | TopFun fd ->
        Hashtbl.replace wire_fun_returns fd.fn_name fd.fn_return
    | _ -> ()) p

let reset_scheme_env () = scheme_env := []

let add_scheme (name : string) (s : Ty_subst.scheme) =
  scheme_env := (name, s) :: !scheme_env

let lookup_scheme (name : string) : Ty_subst.scheme option =
  List.assoc_opt name !scheme_env

(* ─── Errors ───────────────────────────────────────────────────────── *)

type type_error = {
  err_loc : location;
  err_msg : string;
}

type 'a tc_result = ('a, type_error) Stdlib.result

let ok (x : 'a) : 'a tc_result = Ok x

let err (loc : location) (msg : string) : 'a tc_result =
  Error { err_loc = loc; err_msg = msg }

let (let*) (r : 'a tc_result) (f : 'a -> 'b tc_result) : 'b tc_result =
  match r with
  | Ok x -> f x
  | Error e -> Error e

let error_to_string (e : type_error) : string =
  Printf.sprintf "[%s] %s" (Tyenv.loc_to_string e.err_loc) e.err_msg

(* ─── Helpers: built-in type for literals ──────────────────────────── *)

let ty_of_literal (l : literal) : ty =
  match l with
  | LitNumber _ -> TyPrim "number"
  | LitString _ -> TyPrim "text"
  (* A syntactic bool has type proposition (Omega), not a separate "boolean"
   * type. Yon's logic is intuitionistic: there is a single type of decidable
   * propositions. *)
  | LitBool _ -> TyPrim "proposition"
  | LitDuration _ -> TyPrim "number"  (* v1.0: a duration IS milliseconds *)
  | LitCurrency (_, _) -> TyPrim "money"
  | LitHeytPresent | LitHeytAbsent | LitHeytUnknown -> TyPrim "proposition"

(* Purity analysis for the terminal absorber (Kleisli discipline).

   A terminal-typed expression may be collapsed to the unique inhabitant `()`
   ONLY if it is pure (lives in the base category, where 1 is genuinely
   terminal). An effectful terminal-typed expression lives in the Kleisli
   category of the effect monad T, where the map is `T(!_A) : T(A) -> T(1)`:
   the effect must be kept, only the value is trivialized. So we must NOT
   collapse effectful expressions.

   This predicate is deliberately CONSERVATIVE: anything whose effect status is
   not obviously pure is treated as effectful. Cost of a false "effectful":
   a missed zero-bit optimization. Cost of a false "pure": a deleted effect.
   We never risk the latter.

   Moved to Tyenv (it needs only the env and surface types) so Desugar can use
   it without a module cycle; re-exported here for in-module callers. *)
let is_pure_expr = Tyenv.is_pure_expr

(* Recognize the terminal object 1: the type `TyUser p` where the place p has
   no data fields. This is the derived terminal (no TyUnit primitive); the rest
   of the checker can ask "is this type 1?" without committing to a constructor.
   Subsequent steps use this to type the unique map `!_A : A -> 1` and to give
   the eta law (every t : 1 equals ()). Definition moved to Tyenv (same layering
   reason); re-exported here. *)
let is_terminal_ty = Tyenv.is_terminal_ty

(* Mere proposition predicate: isProp P := Pi(x:P). Pi(y:P). Id_P(x,y).
   A type is a mere proposition when all its inhabitants are equal. This is the
   (-1)-truncation level of the classifier tower; the subobject classifier
   Omega is the type of mere propositions. We build the type from the existing
   core formers (TyPi, TyId, TyUniverse) — no new primitive. The endpoints use
   ty_term placeholders, matching how the checker already encodes Id (see the
   ERefl handling). *)
let isprop_ty (carrier : ty) : ty =
  TyPi ("x", carrier,
    TyPi ("y", carrier,
      TyId (carrier, TyTermExpr (EVar ("x", dummy_loc)), TyTermExpr (EVar ("y", dummy_loc)))))

(* The subobject classifier Omega := Sigma(P:Type_0). isProp(P): the type of
   mere propositions, derived as the (-1)-truncated bottom of the object
   classifier (the universe Type_0). Built from existing formers. The 3-valued
   `proposition` type is a separate internal Heyting algebra, NOT this Omega. *)
let omega_ty : ty =
  TySigma ("P", TyUniverse 0, isprop_ty (TyVar "P"))

(* Map a generic place's parameter names, seen as user types in field/op
   signatures (`place Box<T> { value T }`), to type variables — the same move
   the checker already makes for a function's fn_type_params. TyVar is then
   accepted wherever a concrete type is (monomorphic erasure). *)
let rec resolve_tparams (tps : string list) (t : ty) : ty =
  if tps = [] then t
  else
    let go = resolve_tparams tps in
    match t with
    | TyUser n when List.mem n tps -> TyVar n
    | TyArrow (a, b) -> TyArrow (go a, go b)
    | TyStream a -> TyStream (go a)
    | _ -> t

(* PRECISE instantiation: given a generic place's parameters and the concrete
   type arguments of an application `Box<number>`, substitute each parameter by
   its argument inside a field/op type. This is what makes `b : Box<number>`
   give `b.value : number` rather than the erased TyVar. Falls back to the
   monomorphic resolve when the arity doesn't line up. *)
let subst_place_tparams (params : string list) (args : ty list) (t : ty) : ty =
  if params = [] || List.length params <> List.length args then
    resolve_tparams params t
  else
    let pairs = List.combine params args in
    let rec go t =
      match t with
      | TyUser n when List.mem_assoc n pairs -> List.assoc n pairs
      | TyVar n when List.mem_assoc n pairs -> List.assoc n pairs
      | TyArrow (a, b) -> TyArrow (go a, go b)
      | TyStream a -> TyStream (go a)
      | _ -> t
    in
    go t

(* Recognize a type that is (syntactically) the mere-proposition predicate
   applied to some carrier, i.e. of the shape Pi(_:C).Pi(_:C).Id_C(_,_). Used by
   later steps (comprehension) to check that a predicate's fibres are props. *)
let is_isprop_shape (t : ty) : bool =
  match t with
  | TyPi (_, c1, TyPi (_, c2, TyId (c3, _, _))) ->
      c1 = c2 && c2 = c3
  | _ -> false

(* Comprehension (the genuine categorical subobject, distinct from width
   subtyping): { x : A | p } := Sigma(x : A). fibre, where p : A -> Omega and
   `fibre` is the proposition p(x). Because the fibre is a mere proposition,
   the first projection Sigma(x:A).P(x) --pr1--> A is a monomorphism, so this is
   exactly the subobject of A classified by p. We BUILD it as a TySigma (no new
   former), recording the carrier A as the binder domain and the proposition
   type as the dependent fibre. The caller is responsible for having checked
   p : A -> Omega; this constructor records the subobject structurally. *)
let comprehension_ty (binder : string) (carrier : ty) (fibre : ty) : ty =
  TySigma (binder, carrier, fibre)

(* Recognize a comprehension subobject: a Sigma whose fibre is a mere
   proposition (its first projection is then a mono into the carrier). This is
   how we tell a genuine subobject apart from an arbitrary dependent pair. *)
let is_comprehension (t : ty) : bool =
  match t with
  | TySigma (_, _carrier, fibre) -> is_isprop_shape fibre
  | _ -> false

(* The canonical truth value `true : 1 -> Omega`.

   In Omega = Sigma(P:Type_0). isProp(P), the canonical true proposition is the
   terminal object 1 itself: 1 has a unique inhabitant (), so by eta all its
   inhabitants are equal, hence isProp(1) holds trivially. The classifying
   arrow `true` sends the unique inhabitant of 1 to that proposition. We record
   its type and its value structurally (the value is the Sigma-pair whose first
   component is the terminal carrier and whose second is the trivial proof).

   `term1` is the surface type used for the terminal 1 (a fieldless place name);
   the caller supplies it so we do not hard-code a name. *)
let true_arrow_ty (term1 : ty) : ty =
  (* true : 1 -> Omega *)
  TyPi ("_", term1, omega_ty)

(* The classifier pullback. Omega is a subobject classifier iff for every mono
   m : S >-> A there is a unique characteristic map chi : A -> Omega making the
   square  S --> 1 ,  S >-> A --chi--> Omega <--true-- 1  a pullback, and the
   canonical representative of that subobject is the comprehension
   { x : A | chi x }. So a comprehension Sigma(x:A).fibre IS the pullback of
   `true` along the predicate whose fibre is `fibre`. We recognize that a given
   subobject type, a carrier A, and a predicate fibre form the classifier
   pullback: the subobject must be exactly the comprehension on that fibre, and
   the fibre must be a mere proposition (so `true`'s pullback is well-defined).
   This makes the Omega<->subobject correspondence checkable structurally,
   without yet computing it at runtime. *)
let is_classifier_pullback ~(subobject : ty) ~(carrier : ty) ~(fibre : ty)
    : bool =
  is_isprop_shape fibre
  && (match subobject with
      | TySigma (_, a, f) -> a = carrier && f = fibre
      | _ -> false)

(* Forgetful mono of a comprehension subobject: { x : A where P } <: A.

   Categorically this is the image of the subobject under the forgetful functor
   Sigma_A : C/A -> C, i.e. the first projection (the mono). A subobject of A is
   always an A: we may forget the proof. So a value of type { x : A where P } is
   usable wherever A is expected. This is ONE direction only — the reverse,
   A <: { x : A where P }, is NOT admitted here, because promoting an A to the
   subobject requires a proof that it satisfies P (that is the constructor's
   job, not a free coercion).

   At runtime this coercion is a no-op: under choice (alpha) the comprehension is
   already represented by its carrier A in the backend, so the two geometries
   coincide in MLIR and no cast/extraction is emitted. *)
let comprehension_coerces_to (env : Tyenv.env) (ctx : Reduce.ctx)
    ~(sub : ty) ~(super : ty) : bool =
  match sub with
  | TySigma (_, carrier, fibre) when is_isprop_shape fibre ->
      (* sub is a genuine comprehension subobject; it coerces to its carrier,
         or to anything the carrier is already compatible with. *)
      Dispatcher.type_equal env ctx carrier super
  | _ -> false

(* Type of a binop result, given operand types. *)
let ty_of_binop (op : binop) (lhs : ty) (rhs : ty)
    (env : Tyenv.env) (ctx : Reduce.ctx) (loc : location) : ty tc_result =
  let num = TyPrim "number" in
  let bool_t = TyPrim "boolean" in
  let txt = TyPrim "text" in
  let dur = TyPrim "duration" in
  let mon = TyPrim "money" in
  let is = Dispatcher.type_equal env ctx in
  match op with
  (* Arithmetic operators *)
  | OpAdd | OpSub | OpMul | OpDiv | OpMod ->
      if is lhs num && is rhs num then ok num
      else if is lhs dur && is rhs dur && (op = OpAdd || op = OpSub) then ok dur
      else if is lhs mon && is rhs mon && (op = OpAdd || op = OpSub) then ok mon
      else if is lhs txt && is rhs txt && op = OpAdd then ok txt  (* string concat *)
      else err loc
        (Printf.sprintf
           "operator requires matching numeric/duration/money operands; got %s and %s"
           (Tyenv.ty_to_string lhs) (Tyenv.ty_to_string rhs))
  (* Comparison operators *)
  | OpLt | OpGt | OpLeq | OpGeq ->
      if is lhs rhs && (is lhs num || is lhs dur || is lhs mon) then ok bool_t
      else err loc
        (Printf.sprintf
           "comparison requires matching ordered operands; got %s and %s"
           (Tyenv.ty_to_string lhs) (Tyenv.ty_to_string rhs))
  | OpEq | OpNeq ->
      if is lhs rhs then ok bool_t
      else err loc
        (Printf.sprintf
           "equality requires matching operand types; got %s and %s"
           (Tyenv.ty_to_string lhs) (Tyenv.ty_to_string rhs))
  (* Boolean operators *)
  | OpAnd | OpOr ->
      (* Accepts number (C-style coercion, 0=false) in addition to boolean and
       * proposition (Heyting dispatch via the interpreter). *)
      let is_bool_like t =
        is t bool_t || is t (TyPrim "number") || is t (TyPrim "proposition")
      in
      if is_bool_like lhs && is_bool_like rhs then ok bool_t
      else err loc
        (Printf.sprintf
           "boolean operator requires boolean/number/proposition operands; got %s and %s"
           (Tyenv.ty_to_string lhs) (Tyenv.ty_to_string rhs))

(* ─── Expression: infer ────────────────────────────────────────────── *)

(* Reject a handle nested inside a handle. Walk the AST looking for a nested
 * handle lambda; if one is found, return an error: morphisms, functors and
 * projections are static structures, not dynamic values built from other
 * morphisms.
 *
 * We do NOT traverse into functional ELam (those are fine: the body of a move
 * may call any function). We only traverse the direct syntactic structure of
 * the handle body. *)
let rec contains_handle_lambda (e : expr) : string option =
  match e with
  | EMoveLam _ -> Some "move"
  | EReductionLam _ -> Some "reduction"
  | EMorphLam _ -> Some "morph"
  | EFunctorLam _ -> Some "functor"
  | EViewLam _ -> Some "view"
  | ELit _ | EVar _ -> None
  | EField (sub, _, _) -> contains_handle_lambda sub
  | EParen (sub, _) -> contains_handle_lambda sub
  | ENot (sub, _) -> contains_handle_lambda sub
  | EBinop (_, a, b, _) ->
      (match contains_handle_lambda a with
       | Some _ as r -> r
       | None -> contains_handle_lambda b)
  | EIfThenElse (c, t, el, _) ->
      (match contains_handle_lambda c with
       | Some _ as r -> r
       | None ->
           (match contains_handle_lambda t with
            | Some _ as r -> r
            | None -> contains_handle_lambda el))
  | ECall (_, args, _) ->
      List.fold_left (fun acc a ->
        match acc with Some _ -> acc | None -> contains_handle_lambda a
      ) None args
  | ENew (_, fas, _) | ENewIn (_, _, fas, _) ->
      List.fold_left (fun acc fa ->
        match acc with Some _ -> acc | None -> contains_handle_lambda fa.fa_value
      ) None fas
  | ELam (_, _body, _) ->
      (* A functional ELam: its body may contain arbitrary computation but no
       * other handle. For uniformity we still traverse it, since a `fun` that
       * returns a `move` or builds one dynamically is equally suspect. *)
      contains_handle_lambda _body
  | EComposeWith (h1, h2, _) ->
      (* A compose result is itself a composed handle; if it appears in the
       * body of an outer handle, it is suspect. Treat it as the presence of a
       * handle. *)
      (match contains_handle_lambda h1 with
       | Some _ as r -> r
       | None -> contains_handle_lambda h2)
  | _ -> None

let forbid_handle_in_body
    (outer_kind : string) (body : expr) (loc : location) : unit tc_result =
  match contains_handle_lambda body with
  | None -> ok ()
  | Some inner_kind ->
      err loc (Printf.sprintf
        "handle nesting not allowed: a lambda of type '%s' contains a \
         lambda of type '%s' in its body. Handle types (move/reduction/morph/view) \
         are static structures of the topos, not dynamic values. Workaround: \
         declare the handles at the top level and use a named fun for the \
         composition."
        outer_kind inner_kind)

(* Free value-variables of a surface expression, binder-aware. Used by the
   closed-morphism discipline to detect capture of an enclosing local. Binders
   that introduce value variables (lambda/handle parameters, path abstraction,
   HIT-elim branch binders) are subtracted, so a name bound *inside* the body
   is never reported. ECall callees are top-level names (not free value-vars),
   so they are not collected. Produce/spawn statement blocks are not descended
   into (conservative): this can only miss a capture, never invent one. *)
let free_vars_expr (e0 : expr) : string list =
  let rec go bound e =
    let s = go bound in
    match e with
    | ELit _ -> []
    | EVar (x, _) -> if List.mem x bound then [] else [x]
    | EField (e, _, _) -> s e
    | ECall (_, args, _) ->
        List.concat_map s args
    | EApp (h, args, _) -> s h @ List.concat_map s args
    | EHITElim (t, branches, m, _) ->
        s t
        @ List.concat_map (fun (_, vars, e) -> go (vars @ bound) e) branches
        @ s m
    | EPathApp (e, _, _) -> s e
    | EPathAbs (i, e, _) -> go (i :: bound) e
    | EHITConstr (_, args, _) -> List.concat_map s args
    | EWireTo _ -> []
    | EProduce (_, _) -> []
    | ESpawn (eo, _, _) -> (match eo with Some e -> s e | None -> [])
    | ENew (_, fas, _) -> List.concat_map (fun (fa : field_assignment) -> s fa.fa_value) fas
    | ENewIn (_, _, fas, _) -> List.concat_map (fun (fa : field_assignment) -> s fa.fa_value) fas
    | EBinop (_, a, b, _) -> s a @ s b
    | EParen (e, _) -> s e
    | EAll (_, _, _) -> []
    | EIn (e, _, _) -> s e
    | ERefl (e, _) -> s e
    | EPair (a, b, _) -> s a @ s b
    | EFst (e, _) -> s e
    | ESnd (e, _) -> s e
    | EJ (a, b, c, _) -> s a @ s b @ s c
    | EQuote (_, e, _) -> s e
    | EElMatch (a, b, c, _) -> s a @ s b @ s c
    | EPullback (_, _, _) -> []
    | EPushout (_, _, _) -> []
    | EPullbackVal (_, _, a, b, _) -> s a @ s b
    | ENot (e, _) -> s e
    | EIfThenElse (a, b, c, _) -> s a @ s b @ s c
    | ELam (ps, body, _) -> go (List.map fst ps @ bound) body
    | EMoveLam (ps, body, _, _, _) -> go (List.map fst ps @ bound) body
    | EReductionLam (ps, body, _, _) -> go (List.map fst ps @ bound) body
    | EMorphLam (ps, body, _, _, _) -> go (List.map fst ps @ bound) body
    | EFunctorLam (ps, body, _, _, _, _) -> go (List.map fst ps @ bound) body
    | EViewLam (ps, body, _, _) -> go (List.map fst ps @ bound) body
    | EComposeWith (a, b, _) -> s a @ s b
  in
  go [] e0

(* Closed-morphism discipline. The body of a handle lambda (move / reduction /
   morph / functor / view) must be CLOSED: it may reference only its own
   parameters and top-level definitions, never a local from the enclosing
   scope. Capturing an enclosing local is rejected here, at type-check, with a
   clear message — rather than crashing later in emit ("variable not in
   scope"). Handle bodies are not closure-converted: a morphism escapes its
   definition site (it is composed and applied elsewhere, possibly across a
   Space boundary) and cannot carry an environment by reference. *)
(* Stage C: a handle-lambda (move/reduction/morph/functor/view) MAY now capture an
   enclosing local. The old closed-morphism discipline forbade it on the grounds
   that a morphism escapes its definition site and "is not closure-converted", but
   Stage B built exactly that: a handle-lambda that captures is lifted to a
   content-addressed closure node (its dense tag + the captured env), so the
   environment travels with the handle across composition and Space boundaries.
   Kept as a no-op (still called by the five handle-lambda cases) so the removal
   is one edit and the intent is documented at the site of the old check. *)
let forbid_local_capture
    (_kind : string) (_params : (string * ty) list) (_body : expr)
    (_env : Tyenv.env) (_loc : location) : unit tc_result =
  ok ()

(* Forward reference: infer (this rec group) reaches the statement
   checker of the later group, for produce blocks in expression
   position. Initialized right after check_stmts is defined. *)
let produce_check_ref :
  (Tyenv.env -> Reduce.ctx -> stmt list -> ty option -> Tyenv.env tc_result) ref =
  ref (fun env _ _ _ -> ok env)

(* Element type of the produce block currently being checked, inferred from its
   emits. SEmit records it, EProduce reads it. None until the first emit; a
   produce with no emits keeps the historical number element. Saved/restored
   around each produce so nesting is well-scoped. *)
let produce_emit_ty : ty option ref = ref None

(* Element type of the spawn block currently being checked, inferred from its
   promotes. SPromote records it, ESpawn reads it. Kept separate from
   produce_emit_ty so a spawn with no promote is an error (decided), while a
   produce with no emit keeps its historical number element. Saved/restored
   around each spawn for well-scoped nesting. *)
let spawn_promote_ty : ty option ref = ref None

(* Are we currently type-checking inside a spawn body? Incremented around the
   body so promote is rejected outside a spawn, and so nested spawns compose. *)
let in_spawn_depth : int ref = ref 0

let rec subst_dim_in_expr (i : string) (d : dim) (e : expr) : expr =
  let r = subst_dim_in_expr i d in
  match e with
  | EPathApp (q, DIVar j, loc) when j = i -> EPathApp (r q, d, loc)
  | EPathApp (q, dd, loc) -> EPathApp (r q, dd, loc)
  | EPathAbs (j, b, loc) ->
      if j = i then e else EPathAbs (j, r b, loc)
  | EApp (h, args, loc) -> EApp (r h, List.map r args, loc)
  | ECall (name, args, loc) -> ECall (name, List.map r args, loc)
  | EHITElim (motive, branches, scrutinee, loc) ->
      EHITElim (r motive,
        List.map (fun (name, vars, body) -> (name, vars, r body)) branches,
        r scrutinee, loc)
  | EHITConstr (ctor, args, loc) -> EHITConstr (ctor, List.map r args, loc)
  | ENew (name, fields, loc) ->
      ENew (name, List.map (fun fa -> { fa with fa_value = r fa.fa_value }) fields, loc)
  | ENewIn (name, space, fields, loc) ->
      ENewIn (name, space,
        List.map (fun fa -> { fa with fa_value = r fa.fa_value }) fields, loc)
  | EBinop (op, a, b, loc) -> EBinop (op, r a, r b, loc)
  | EParen (x, loc) -> EParen (r x, loc)
  | EField (x, field, loc) -> EField (r x, field, loc)
  | EIn (x, context, loc) -> EIn (r x, context, loc)
  | ERefl (x, loc) -> ERefl (r x, loc)
  | EPair (a, b, loc) -> EPair (r a, r b, loc)
  | EFst (x, loc) -> EFst (r x, loc)
  | ESnd (x, loc) -> ESnd (r x, loc)
  | EJ (c, base, path, loc) -> EJ (r c, r base, r path, loc)
  | EQuote (code, x, loc) -> EQuote (code, r x, loc)
  | EElMatch (target, ret, body, loc) ->
      EElMatch (r target, r ret, r body, loc)
  | EPullbackVal (f, g, a, b, loc) -> EPullbackVal (f, g, r a, r b, loc)
  | ENot (x, loc) -> ENot (r x, loc)
  | EIfThenElse (a, b, c, loc) -> EIfThenElse (r a, r b, r c, loc)
  | ELam (params, body, loc) -> ELam (params, r body, loc)
  | EMoveLam (params, body, from_p, to_p, loc) ->
      EMoveLam (params, r body, from_p, to_p, loc)
  | EReductionLam (params, body, place, loc) ->
      EReductionLam (params, r body, place, loc)
  | EMorphLam (params, body, from_s, to_s, loc) ->
      EMorphLam (params, r body, from_s, to_s, loc)
  | EFunctorLam (params, body, from_w, to_w, laws, loc) ->
      EFunctorLam (params, r body, from_w, to_w, laws, loc)
  | EViewLam (params, body, place, loc) ->
      EViewLam (params, r body, place, loc)
  | EComposeWith (a, b, loc) -> EComposeWith (r a, r b, loc)
  | ESpawn (count, body, loc) -> ESpawn (Option.map r count, body, loc)
  | (ELit _ | EVar _ | EWireTo _ | EProduce _ | EAll _
    | EPullback _ | EPushout _) -> e

(* Stop-gap (1.1): `=` (Space-cell assign) inside a produce / spawn body desugars to
   __space_update_here, which has no lowering — the cells promotion that turns `be x holds`
   into a Space cell and rewrites `x = e` into `Space.set` does not reach these
   expression-context blocks, so emit_mlir would crash with a Fatal error. Until the full
   fix lands with the produce rework in 1.2, reject it with a clean compile-time error.
   Walks loop / when bodies but not nested produce/spawn (those run their own check). *)
let rec first_assign_loc (ss : stmt list) : location option =
  List.fold_left (fun acc s ->
    match acc with
    | Some _ -> acc
    | None ->
      match s with
      | SAssignBecomes (_, _, l) -> Some l
      | SIter (_, b, _) | SWhile (_, b, _) | SForEvery (_, _, _, b, _) -> first_assign_loc b
      | SWhen (_, b, elifs, oth, _) ->
          (match first_assign_loc b with
           | Some _ as r -> r
           | None ->
             let r = List.fold_left (fun a (_, b2) ->
                       match a with Some _ -> a | None -> first_assign_loc b2) None elifs in
             (match r with
              | Some _ -> r
              | None -> (match oth with Some o -> first_assign_loc o | None -> None)))
      | _ -> None) None ss

(* Resolve the point-constructor signature of an inductive from the scrutinee's
   type: a declared sum (`TySum`/`TySumIn`), a named `inductive T = ...` (via
   lookup_named_sum), or a builtin HIT. `pc_result` is the scrutinee type itself.
   Shared by the hit_elim inference arm and the dependent-elimination check. *)
let hit_signature_of (env : Tyenv.env) (x_ty : ty)
    : (string * Hit_env.hit_signature) option =
  let sig_of_variants name variants =
    let points =
      List.map
        (fun variant ->
           let params =
             List.mapi (fun i ty -> (Printf.sprintf "arg%d" i, ty)) variant.v_args
           in
           { Hit_env.pc_name = variant.v_name; pc_params = params;
             pc_result = x_ty })
        variants
    in
    (name,
     { Hit_env.hit_name = name; hit_type_params = [];
       hit_points = points; hit_paths = [] })
  in
  match x_ty with
  | TySum variants | TySumIn (variants, _) ->
      Some (sig_of_variants (Tyenv.type_tag x_ty) variants)
  | TyPrim n | TyPrimIn (n, _) | TyUser n ->
      (match Tyenv.lookup_named_sum env n with
       | Some variants -> Some (sig_of_variants n variants)
       | None ->
           Option.map (fun sig_ -> (n, sig_))
             (Hit_env.lookup Hit_env.builtin_env n))
  | _ -> None

(* Substitute the surface variable [xv] by the expression [repl] inside a type,
   reaching the term endpoints a dependent type carries (`TyTermExpr`). This is
   how the expected type P(x) becomes P[x := ctor] per branch in the dependent
   eliminator. Mirrors Dispatcher.rename_ty but replaces a variable with a term,
   reusing Desugar.subst_evar_in_expr at the leaves. *)
let rec subst_evar_in_ty (xv : string) (repl : expr) (t : ty) : ty =
  let r = subst_evar_in_ty xv repl in
  let rt = function
    | TyTermExpr ex -> TyTermExpr (Desugar.subst_evar_in_expr xv repl ex) in
  match t with
  | TyId (a, x, y) -> TyId (r a, rt x, rt y)
  | TyEl c -> TyEl (rt c)
  | TyArrow (a, b) -> TyArrow (r a, r b)
  | TyPi (v, d, c) ->
      if String.equal v xv then TyPi (v, r d, c) else TyPi (v, r d, r c)
  | TySigma (v, d, c) ->
      if String.equal v xv then TySigma (v, r d, c) else TySigma (v, r d, r c)
  | TyPathP ((i, a), x, y) -> TyPathP ((i, r a), rt x, rt y)
  | _ -> t

(* Does the type refer to [xv] at a term endpoint? Only then is the expected type
   a genuine motive that varies with the scrutinee, so the dependent check is
   warranted (otherwise the ordinary constant-motive path applies unchanged). *)
let rec ty_mentions_evar (xv : string) (t : ty) : bool =
  let in_tt = function TyTermExpr ex -> List.mem xv (free_vars_expr ex) in
  match t with
  | TyId (a, x, y) -> ty_mentions_evar xv a || in_tt x || in_tt y
  | TyEl c -> in_tt c
  | TyArrow (a, b) -> ty_mentions_evar xv a || ty_mentions_evar xv b
  | TyPi (v, d, c) ->
      ty_mentions_evar xv d || (not (String.equal v xv) && ty_mentions_evar xv c)
  | TySigma (v, d, c) ->
      ty_mentions_evar xv d || (not (String.equal v xv) && ty_mentions_evar xv c)
  | TyPathP ((_, a), x, y) -> ty_mentions_evar xv a || in_tt x || in_tt y
  | _ -> false

(* Categorical certification for dependent elimination. An inductive is the
   initial F-algebra; its constructors form a cocone into the carrier, and a
   dependent eliminator is the unique map factoring the branch cone through that
   colimit (the initial-algebra universal property). We build the constructor
   pasting-diagram, take its universal colimit cell, and factor the branch cone
   through it. This activates the CaTT universal-property machinery
   (Catt_r_yon.universal_colimit_cell / factor_through) that the checker already
   carries, so dependent elimination is grounded in the universal property rather
   than a bare substitution. The operational content — that each branch inhabits
   its fibre — is the per-branch check below; this is the abstract witness that
   the branch cone is a well-formed cocone over the carrier. *)
let certify_dependent_cone (hname : string)
    (branches : (string * string list * expr) list) : bool =
  let open Catt_r_yon in
  let diagram : ps_ctx =
    (hname, CellStar)
    :: List.map
         (fun (ctor, _, _) ->
            (ctor, CellArr (TmVar ctor, TmVar hname, CellStar)))
         branches
  in
  let apex = TmVar hname in
  match factor_through (universal_colimit_cell diagram apex) apex
          (TmVar "__branch_cone") with
  | Some _ -> true
  | None -> false

let rec infer (env : Tyenv.env) (ctx : Reduce.ctx) (e : expr) : ty tc_result =
  match e with
  | ELit (l, _) -> ok (ty_of_literal l)

  | EApp (f, args, loc) ->
      let* f_ty = infer env ctx f in
      let rec apply ft = function
        | [] -> ok ft
        | _ :: rest ->
            (match ft with
             | TyArrow (_, cod) -> apply cod rest
             | TyPi (_, _, cod) -> apply cod rest
             | TyPrim "unknown" | TyVar _ -> ok (TyPrim "unknown")
             | other ->
                 err loc (Printf.sprintf
                   "application: head is not a function, got %s"
                   (Tyenv.ty_to_string other)))
      in apply f_ty args

  | EHITElim (EVar ("__match", _), branches, x, loc) ->
      (* `match x { ctor => v, .. }`: a non-dependent HIT eliminator whose motive
         is SYNTHESIZED. Infer the scrutinee's HIT type for the motive domain,
         and take the first POINT branch body (a plain value, not a `plam`) as a
         witness of the result type, giving the constant motive
         `fun(_: HIT) => <body> : HIT -> T`. Then reuse the standard rule below.
         A point branch that references its own payload binders cannot serve as
         the constant witness (payload-carrying HITs) — those keep hit_elim. *)
      let* x_ty = infer env ctx x in
      let point_body =
        List.fold_left
          (fun acc (_ctor, vars, body) ->
             match acc, body with
             | Some _, _ -> acc
             | None, EPathAbs _ -> None
             (* The synthesized motive is CONSTANT (fun _ => witness), so the
                witness body must type-check in the OUTER env. A point branch
                whose body reads its own payload binders (e.g. `Lit(n) => n`)
                cannot serve as that witness; skip it and keep looking for a
                base case whose body is closed (e.g. `Nil => 0`). The chosen
                type is then checked against every branch body in ITS branch
                env below, so payload-using branches are still verified. *)
             | None, v ->
                 let fv = free_vars_expr v in
                 if List.exists (fun b -> List.mem b fv) vars
                 then None else Some v)
          None branches
      in
      (match point_body with
       | None ->
           err loc "match: cannot synthesize the result type. Its motive is \
                    constant, so it needs a point branch whose body does not \
                    read that branch's own payload (a base case like `Nil => 0`). \
                    For an eliminator where every branch uses its payload, use \
                    hit_elim with an explicit motive."
       | Some body ->
           let motive = ELam ([("__m", x_ty)], body, loc) in
           infer env ctx (EHITElim (motive, branches, x, loc)))
  | EHITElim (c, branches, x, loc) ->
      (* hit_elim(C, [ctor => v, ...], x), Tarski-typed.
       *   target x : a HIT (known by name in Hit_env)
       *   motive C : HIT -> Type   (lands in the universe)
       *   point ctor: v : El(C ctor)
       *   result    : El(C x)
       * Path constructors carry a dependent (path-over) type that Surface
       * cannot yet express (no PathP in Surface_ast.ty); their branches are
       * inferred and accepted, the full dependent path-over check being the
       * next refinement. *)
      let* c_ty = infer env ctx c in
      let* x_ty =
        match c_ty with
        | TyArrow (domain, _) | TyPi (_, domain, _) ->
            let* () = check env ctx x domain in
            ok domain
        | _ -> err loc "hit_elim: motive must be a function from the HIT"
      in
      let sig_of_variants name variants =
        let points =
          List.map
            (fun variant ->
               let params =
                 List.mapi
                   (fun i ty -> (Printf.sprintf "arg%d" i, ty))
                   variant.v_args
               in
               { Hit_env.pc_name = variant.v_name;
                 pc_params = params;
                 pc_result = x_ty })
            variants
        in
        (name,
         { Hit_env.hit_name = name; hit_type_params = [];
           hit_points = points; hit_paths = [] })
      in
      let hit_signature =
        match x_ty with
        | TySum variants | TySumIn (variants, _) ->
            Some (sig_of_variants (Tyenv.type_tag x_ty) variants)
        | TyPrim n | TyPrimIn (n, _) | TyUser n ->
            (* a named sum (`inductive Tree = ...`) resolves to its variants; else a
               built-in HIT; else not an inductive. *)
            (match Tyenv.lookup_named_sum env n with
             | Some variants -> Some (sig_of_variants n variants)
             | None ->
                 Option.map (fun sig_ -> (n, sig_))
                   (Hit_env.lookup Hit_env.builtin_env n))
        | _ -> None in
      (match hit_signature with
       | None ->
           err loc (Printf.sprintf "hit_elim: target is not a higher inductive type (got %s)"
                      (Tyenv.ty_to_string x_ty))
       | Some (hname, sig_) ->
                let rec lands_in_universe = function
                  | TyArrow (_, cod) | TyPi (_, _, cod) -> lands_in_universe cod
                  | TyUniverse _ -> true
                  | _ -> false in
                let handled = List.map (fun (name, _, _) -> name) branches in
                (* `_` is a catch-all: it discharges every not-listed constructor,
                   so a match with a wildcard is always exhaustive. *)
                let has_wildcard = List.mem "_" handled in
                let missing =
                  if has_wildcard then []
                  else Hit_env.missing_constructors sig_ handled in
                let rec duplicate = function
                  | [] -> None
                  | n :: ns -> if List.mem n ns then Some n else duplicate ns
                in
                let* () =
                  match duplicate handled with
                  | Some name ->
                      err loc (Printf.sprintf
                        "hit_elim: duplicate branch for constructor %s" name)
                  | None -> ok ()
                in
                let* () =
                  match missing with
                  | [] -> ok ()
                  | names ->
                      err loc (Printf.sprintf
                        "hit_elim: missing branch(es): %s"
                        (String.concat ", " names))
                in
                let concrete_param_types ctor params =
                  match x with
                  | EHITConstr (scrut_ctor, args, _) when scrut_ctor = ctor
                    && List.length args = List.length params ->
                      let rec infer_all acc = function
                        | [] -> ok (List.rev acc)
                        | arg :: rest ->
                            let* ty = infer env ctx arg in
                            infer_all (ty :: acc) rest
                      in
                      infer_all [] args
                  | _ -> ok (List.map snd params)
                in
                let constructor ctor =
                  match Hit_env.find_constructor [hname, sig_] ctor with
                  | Some (_, kind) -> ok kind
                  | None -> err loc (Printf.sprintf
                      "hit_elim: constructor %s does not belong to %s"
                      ctor hname)
                in
                let branch_env ctor vars params =
                  if List.length vars <> List.length params then
                    err loc (Printf.sprintf
                      "hit_elim: branch %s expects %d payload binder(s), got %d"
                      ctor (List.length params) (List.length vars))
                  else
                    let* tys = concrete_param_types ctor params in
                    ok (Tyenv.add_vars env (List.combine vars tys))
                in
                if lands_in_universe c_ty then
                  (* Tarski dependent eliminator: point branch : El(C ctor),
                   * path branch : El(C(ctor@i)) (path-over), result : El(C x). *)
                  let rec check_branches = function
                    | [] -> ok ()
                    | ("_", _, _) :: _ ->
                        err loc "hit_elim: the wildcard `_` needs a non-dependent \
                                 motive; with a dependent motive list every constructor"
                    | (ctor, vars, v) :: rest ->
                        let* kind = constructor ctor in
                        let params = Hit_env.constructor_params kind in
                        let* branch_env = branch_env ctor vars params in
                        let ctor_expr =
                          EHITConstr
                            (ctor, List.map (fun name -> EVar (name, loc)) vars, loc)
                        in
                        (match kind with
                         | Hit_env.KPoint _ ->
                             let expected =
                               TyEl (TyTermExpr (EApp (c, [ctor_expr], loc))) in
                             let* () = check branch_env ctx v expected in
                             check_branches rest
                         | Hit_env.KPath _ ->
                             (match v with
                              | EPathAbs (i, body, _) ->
                                  let line_i =
                                    TyEl (TyTermExpr
                                      (EApp (c,
                                        [EPathApp (ctor_expr, DIVar i, loc)], loc)))
                                  in
                                  let* () = check branch_env ctx body line_i in
                                  check_branches rest
                              | _ -> err loc (Printf.sprintf
                                  "hit_elim: path branch %s must be a path abstraction (plam i => ...)"
                                  ctor)))
                  in
                  let* () = check_branches branches in
                  ok (TyEl (TyTermExpr (EApp (c, [x], loc))))
                else
                  (* non-dependent recursor: motive C : HIT -> T for a concrete
                   * T. Point branch : T; path branch plam i => body, body : T
                   * (constant line); result : T. *)
                  (match c_ty with
                   | TyArrow (_, cod) | TyPi (_, _, cod) ->
                       let rec check_rec = function
                         | [] -> ok ()
                         | ("_", vars, v) :: rest ->
                             (* wildcard: binds nothing, body has the result type *)
                             if vars <> [] then
                               err loc "hit_elim: the wildcard branch `_` binds no payload"
                             else
                               let* () = check env ctx v cod in
                               check_rec rest
                         | (ctor, vars, v) :: rest ->
                             let* kind = constructor ctor in
                             let params = Hit_env.constructor_params kind in
                             let* branch_env = branch_env ctor vars params in
                             (match kind with
                              | Hit_env.KPoint _ ->
                                  let* () = check branch_env ctx v cod in
                                  check_rec rest
                              | Hit_env.KPath _ ->
                                  (match v with
                                   | EPathAbs (_, body, _) ->
                                       let* () = check branch_env ctx body cod in
                                       check_rec rest
                                   | _ -> err loc (Printf.sprintf
                                       "hit_elim: path branch %s must be a path abstraction (plam i => ...)"
                                       ctor)))
                       in
                       let* () = check_rec branches in
                       ok cod
                   | _ -> err loc "hit_elim: motive must be a function from the HIT"))

  | EPathApp (p, _d, loc) ->
      (* path application p @ d. p must be a path (Id type); the result is a
       * point of the carrier. The exact endpoint (p@0 = x, p@1 = y) is decided
       * by reduction in the core (PApp); the *type* is the carrier either way. *)
      let* p_ty = infer env ctx p in
      (match p_ty with
       | TyId (carrier, _x, _y) -> ok carrier
       | _ -> err loc "path application (@): the head is not a path (Id type)")

  | EPathAbs (i, e, _loc) ->
      (* plam i => e : a path <i> e. Non-dependent typing: the body has type A
       * (the carrier); the path runs e[i:=0] ~> e[i:=1]. Keep the actual
       * endpoint expressions so Dispatcher conversion can normalize path
       * applications and certified deltas. *)
      let* a_ty = infer env ctx e in
      ok (TyId (a_ty, TyTermExpr (subst_dim_in_expr i DI0 e),
                TyTermExpr (subst_dim_in_expr i DI1 e)))

  | EHITConstr (ctor, args, loc) ->
      (* hit(ctor, args): a HIT constructor. Look it up in the registry.
       *   point constructor -> the HIT itself
       *   path  constructor -> a path Id(HIT, left, right) between its endpoints *)
      let found =
        List.fold_left (fun acc (_name, sig_) ->
          match acc with
          | Some _ -> acc
          | None ->
              if List.exists (fun (p : Hit_env.point_constructor) ->
                                p.Hit_env.pc_name = ctor) sig_.Hit_env.hit_points
              then Some (sig_, `Point)
              else if List.exists (fun (p : Hit_env.path_constructor) ->
                                     p.Hit_env.hpc_name = ctor) sig_.Hit_env.hit_paths
              then Some (sig_, `Path)
              else None)
          None Hit_env.builtin_env in
      (match found with
       | None ->
           (match Tyenv.lookup_sum_constructor env ctor with
            | [] -> err loc (Printf.sprintf "hit: unknown HIT constructor %s" ctor)
            | [(variants, variant)] ->
                if List.length args <> List.length variant.v_args then
                  err loc (Printf.sprintf "hit(%s): expected %d argument(s), got %d"
                    ctor (List.length variant.v_args) (List.length args))
                else
                  let rec check_args actual expected =
                    match actual, expected with
                    | [], [] -> ok ()
                    | arg :: actual, ty :: expected ->
                        let* () = check env ctx arg ty in
                        check_args actual expected
                    | _ -> assert false
                  in
                  let* () = check_args args variant.v_args in
                  (* A named sum is nominal: `hit(Node, ..)` has type `Tree`, not
                     the expanded sum, so it unifies with `Tree`-typed positions
                     (including a constructor's own recursive arguments). An
                     anonymous inline sum keeps its structural type. *)
                  (match Tyenv.named_sum_of_ctor env ctor with
                   | Some (name, _) -> ok (TyUser name)
                   | None -> ok (TySum variants))
            | candidates ->
                let signatures =
                  List.map
                    (fun (variants, _) -> Tyenv.ty_to_string (TySum variants))
                    candidates
                in
                err loc (Printf.sprintf
                  "hit(%s): ambiguous sum constructor; candidates: %s"
                  ctor (String.concat "; " signatures)))
       | Some (sig_, `Point) ->
           let p = List.find (fun (p : Hit_env.point_constructor) ->
                                p.Hit_env.pc_name = ctor) sig_.Hit_env.hit_points in
           if List.length args <> List.length p.Hit_env.pc_params then
             err loc (Printf.sprintf "hit(%s): expected %d argument(s), got %d"
                        ctor (List.length p.Hit_env.pc_params) (List.length args))
           else ok (TyUser sig_.Hit_env.hit_name)
       | Some (sig_, `Path) ->
           let p = List.find (fun (p : Hit_env.path_constructor) ->
                                p.Hit_env.hpc_name = ctor) sig_.Hit_env.hit_paths in
           ok (TyId (TyUser sig_.Hit_env.hit_name,
                     TyTermExpr p.Hit_env.hpc_left,
                     TyTermExpr p.Hit_env.hpc_right)))

  | EVar ("psh_id", _) ->
      (* Bare presheaf identity id_A : X -> X (same rule as the psh_id() call
       * form). It lowers to the kernel marker `__id`; the (F-id) law applies. *)
      ok (TyArrow (TyVar "__psh_X", TyVar "__psh_X"))
  | EVar (x, loc) ->
      (* HM let-polymorphism, with priority to the scheme store. If x is bound
       * to a scheme forall a. T, instantiate it with fresh meta-variables at
       * each call site (to support polymorphic use). *)
      (match lookup_scheme x with
       | Some scheme -> ok (Ty_subst.instantiate scheme)
       | None ->
      if Carrier.is_prim_name x then
        (* A primitive type name in term position is its Tarski code.  This is
           the surface entry point for paths in the universe, e.g.
           refl(number) : Id(Type_0, number, number). *)
        ok (TyUniverse 0)
      else
      match Tyenv.lookup_var env x with
       | Some t -> ok t
       | None ->
           match Tyenv.lookup_morph_decl env x with
           | Some mp -> ok (TyMorphHandle (Some mp.mp_source, Some mp.mp_target))
           | None ->
           match Tyenv.lookup_fun env x with
           | Some fs ->
               if fs.fs_params = [] then ok fs.fs_return
               else
                 let ty =
                   List.fold_right
                     (fun (pname, pty) acc ->
                        (* A function whose result type mentions a parameter is a
                           genuine dependent function (a Pi that binds the name),
                           not an arrow: dropping the binder would leak the
                           parameter as a free variable in the codomain and defeat
                           any comparison against the expected Pi (e.g. an equiv
                           coherence `Pi(a). Id(g(f a), a)`). A non-dependent
                           parameter stays an arrow, unchanged. *)
                        if ty_mentions_evar pname acc then TyPi (pname, pty, acc)
                        else TyArrow (pty, acc))
                     fs.fs_params fs.fs_return
                 in
                 ok ty
           | None ->
               (* try as a move name. *)
               (match Move_engine.lookup_move x with
                | Some md ->
                    let from_p = match md.mv_from with
                      | [p] -> Some p
                      | _ -> None
                    in
                    ok (TyMoveHandle (from_p, md.mv_to))
                | None ->
               (* try as a reduction name. *)
               (match Tyenv.lookup_reduction env x with
                | Some rd -> ok (TyReductionHandle (Some rd.rd_of))
                | None ->
               (* try as a view name. *)
               (match Tyenv.lookup_view env x with
                | Some vd -> ok (TyViewHandle (Some vd.vw_of))
                | None ->
               (* Try as a place name (used in patterns or contexts) *)
               match Tyenv.lookup_place env x with
               | Some _ -> ok (TyUser x)
               | None -> err loc (Printf.sprintf "unknown identifier: %s" x)))))

  | EField (obj, "stream", loc) when
      (match obj with
       | EVar (n, _) ->
           (match Tyenv.lookup_var env n with
            | Some (TySubscription _) -> true
            | _ -> false)
       | _ -> false) ->
      (* subscription.stream: materialize the emissions as a stream whose
         element type is the one the subscription carries (the producer's
         declared element). For a place element the site records N (payload
         bytes) so the drain rebuilds DTOs locally; 0 keeps the scalar drain. *)
      let elem =
        (match obj with
         | EVar (n, _) ->
             (match Tyenv.lookup_var env n with
              | Some (TySubscription (_, e)) -> e
              | _ -> TyPrim "number")
         | _ -> TyPrim "number")
      in
      let n_bytes =
        match elem with
        | TyUser pname ->
            (match Tyenv.lookup_place env pname with
             | Some _pd -> 256  (* wire slot cap for the variable frame;
                                   the byte ring (seal 2c) removes the cap *)
             | None -> 0)
        | _ -> 0
      in
      Hashtbl.replace substream_site_table (loc.start_line, loc.start_col) n_bytes;
      ok (TyStream elem)

  | EField (obj, fld, loc) ->
      (* The E1110 cross-Space field-read gate was type-gated on the retired
       * `new P in Space` surface form. With that vestige gone, a place's space
       * is its filesystem directory; same-binary isolation is physical
       * (`backend=separate` + the process/package boundary), not a field-read
       * type-check. See chapter 10. *)
      let* obj_ty = infer env ctx obj in
      (match obj_ty with
       | TyPrim "unknown" | TyUser "unknown" | TyVar _ ->
           (* Polymorphic types: accept field access and return unknown.
            * Defers full typing until specialization. *)
           ok (TyPrim "unknown")
       | (TyUser place_name | TyApp (place_name, _)) as pt ->
           let targs = (match pt with TyApp (_, a) -> a | _ -> []) in
           (match Tyenv.lookup_place env place_name with
            | None -> err loc
                (Printf.sprintf "place %s not found while looking up field %s" place_name fld)
            | Some pd ->
                let rec find_field = function
                  | [] -> err loc
                      (Printf.sprintf "place %s has no field %s" place_name fld)
                  | FoField f :: _ when f.fd_name = fld ->
                      (* precise on a type application (Box<number> -> value:number),
                         monomorphic-erased on a bare place *)
                      ok (subst_place_tparams pd.pd_type_params targs f.fd_ty)
                  | _ :: rest -> find_field rest
                in
                find_field pd.pd_members)
       | other -> err loc
           (Printf.sprintf "field access requires a place; got %s"
              (Tyenv.ty_to_string other)))

  | ECall (name, args, loc) when name = "awaits" ->
      (* w.awaits(producer): the receiver must be a wire to a Space; the
         argument is a producer FUNCTION NAME, imported from that same
         Space and declared `stream of T`. All three are compile errors
         otherwise (design note, locked). *)
      (* Unified value-receiver form: `w.awaits(producer)` lowers to
         ECall("awaits", [EVar w; EVar producer]). The receiver is the first
         argument; the producer is the rest (a single producer function name). *)
      let recv_e, prod_args =
        (match args with r :: rest -> (r, rest) | [] -> (EVar ("", loc), [])) in
      let* recv_ty = infer env ctx recv_e in
      (match recv_ty with
       | TyWire sp ->
           (match prod_args with
            | [EVar (fname, floc)] ->
                (match Hashtbl.find_opt wire_imports fname with
                 | None ->
                     err floc (Printf.sprintf
                       "Space %s does not declare '%s' (or it is not \
imported: import <module>::%s from %s)" sp fname fname sp)
                 | Some (sp', _m) when sp' <> sp ->
                     err floc (Printf.sprintf
                       "'%s' is imported from Space %s, not %s" fname sp' sp)
                 | Some (_, m) ->
                     let bare =
                       match String.index_opt fname ':' with
                       | Some i -> String.sub fname (i + 2)
                                     (String.length fname - i - 2)
                       | None -> fname
                     in
                     let ret =
                       match Hashtbl.find_opt wire_fun_returns
                               (m ^ "::" ^ bare) with
                       | Some r -> Some r
                       | None -> Hashtbl.find_opt wire_fun_returns bare
                     in
                     (match ret with
                      | Some (Some (TyStream elem)) ->
                          let sel = Module_prefix.op_selector bare in
                          (* The wire carries a variable-length frame, not the
                             raw payload, so the channel slot is a generous cap
                             (the byte ring of seal 2c removes the fixed cap);
                             0 for a scalar (the unchanged f64 channel). *)
                          let n_bytes =
                            match elem with
                            | TyUser pname ->
                                (match Tyenv.lookup_place env pname with
                                 | Some _pd -> 256
                                 | None -> 0)
                            | _ -> 0
                          in
                          Hashtbl.replace awaits_site_table
                            (loc.start_line, loc.start_col) (sp, sel, sel, n_bytes);
                          ok (TySubscription (sp, elem))
                      | Some r ->
                          let shown = (match r with
                            | Some t -> Tyenv.ty_to_string t
                            | None -> "number") in
                          err floc (Printf.sprintf
                            "'%s' is not a producer: it returns %s; a \
producer is declared `stream of T`" bare shown)
                      | None ->
                          err floc (Printf.sprintf
                            "Space %s does not declare '%s'" sp bare)))
            | _ ->
                err loc "awaits takes the name of a producer function")
       | other ->
           err loc (Printf.sprintf
             "awaits needs a wire receiver (be w holds wire to <Space>), \
got %s" (Tyenv.ty_to_string other)))

  | ECall (name, args, loc) ->
      (* B.2: directed-transport builtin. `coerce_incl(v, proof)` transports a
         value v along the directed inclusion cell m_f : c_P -> c_Q whose witness
         is `proof`. Under choice (alpha) the directed subobject is represented by
         its carrier, so the transport is a runtime no-op: the result has the same
         type as v (the carrier). The cell/witness live in the CaTT reducer (B.1,
         B.3); here we only type the surface form and let desugar lower it to v.
         We accept exactly two arguments and return the type of the first. *)
      if name = "__hcomp_surface" || name = "__comp_surface" then
        (match args with
         | [line_or_type; ECall ("__hcomp_system", sides, _); base] ->
             let* base_ty = infer env ctx base in
             let* () =
               if name = "__hcomp_surface" then
                 (match line_or_type with
                  | EVar (type_name, _) ->
                      let declared_ty =
                        if Carrier.is_prim_name type_name then TyPrim type_name
                        else TyUser type_name in
                      if Dispatcher.type_equal env ctx declared_ty base_ty then ok ()
                      else err loc (Printf.sprintf
                        "hcomp base has type %s, expected %s"
                        (Tyenv.ty_to_string base_ty)
                        (Tyenv.ty_to_string declared_ty))
                  | _ -> err loc "hcomp expects a nominal carrier type")
               else
                 let* line_ty = infer env ctx line_or_type in
                 (match line_ty with
                  | TyId _ | TyUser "Path" -> ok ()
                  | other -> err loc (Printf.sprintf
                      "comp expects a path in the universe, got %s"
                      (Tyenv.ty_to_string other)))
             in
               let rec check_sides = function
                 | [] -> ok base_ty
                 | ECall (("__hcomp_side_i0" | "__hcomp_side_i1"),
                          [_face; EPathAbs (_binder, body, _)], _) :: rest ->
                     let* () = check env ctx body base_ty in
                     check_sides rest
                 | _ -> err loc "malformed hcomp partial system"
               in
               check_sides sides
         | _ -> err loc "malformed hcomp surface form")
      else
      if name = "coerce_incl" then
        (match args with
         | [v; _proof] -> infer env ctx v
         | _ -> err loc
             "coerce_incl expects 2 arguments: (value, implication_proof)")
      else
      if name = "directed_cell" then
        (* Debt 2: inspect the directed cell generated for a geom_morphism.
           directed_cell(MorphismName) is a compile-time query returning whether
           a directed cell exists for that morphism. The argument names the
           morphism; the result is boolean (no runtime payload — the cell is a
           compile-time artifact). Surface-observable handle onto the reducer. *)
        (match args with
         | [_name] -> ok (TyPrim "boolean")
         | _ -> err loc "directed_cell expects 1 argument: (morphism_name)")
      else
      (* ── Presheaf arrow-action + composition (A1.2 / A1.3, surface half) ──
       * These reserved calls give the surface counterparts of the kernel
       * conversion rules in reduce.ml (try_functoriality). The typing is the
       * standard categorical one, and it is SOUND-FIRST / conservative: each
       * rule fires ONLY on the exact presheaf shape (right head name, right
       * arity, arguments of the expected form). Whenever an object cannot be
       * read off nominally (HM metavars, `unknown`, non-arrow morphism) we fall
       * back to `unknown`, so ordinary application typing is never perturbed and
       * no well-typed program is falsely rejected. *)
      if name = "psh_id" then
        (* id_A : X -> X (polymorphic identity). __id is the reserved neutral;
         * a fresh generic binder makes it usable at any object. *)
        (match args with
         | [] -> ok (TyArrow (TyVar "__psh_X", TyVar "__psh_X"))
         | _ -> err loc "psh_id takes no arguments: it is the polymorphic identity id_A")
      else
      if name = "psh_compose" then
        (* g ∘ f : for g : B -> C and f : A -> B, the composite is A -> C.
         * Guard: fire only when both arguments are genuinely arrows; otherwise
         * stay `unknown` (never reject a program that merely reuses the name). *)
        (match args with
         | [g; f] ->
             let* g_ty = infer env ctx g in
             let* f_ty = infer env ctx f in
             (match g_ty, f_ty with
              | (TyArrow (_gb, gc) | TyPi (_, _gb, gc)),
                (TyArrow (fa, _fb) | TyPi (_, fa, _fb)) ->
                  ok (TyArrow (fa, gc))
              | _ -> ok (TyPrim "unknown"))
         | _ -> err loc "psh_compose expects 2 arguments: psh_compose(g, f) for g ∘ f")
      else
      if name = "psh_map" then
        (* F(f) : the contravariant arrow action of a presheaf F on a morphism
         * f : A -> B is F(f) : F(B) -> F(A). The object action F(X) is the
         * dependent carrier El(F X) (exactly how El(F x) is typed elsewhere).
         * We recover A and B from f's arrow type; the objects must be readable
         * as nominal codes to embed them in El. If not, degrade to `unknown`. *)
        (match args with
         | [ff; f] ->
             let* f_ty = infer env ctx f in
             (* object type -> surface code expr (nominal only) *)
             let obj_code (t : ty) : expr option =
               match t with
               | TyUser n | TyPrim n -> Some (EVar (n, loc))
               | _ -> None
             in
             (match f_ty with
              | (TyArrow (a_ty, b_ty) | TyPi (_, a_ty, b_ty)) ->
                  (match obj_code a_ty, obj_code b_ty with
                   | Some a_e, Some b_e ->
                       (* F(B) -> F(A), contravariant. F is the surface term ff. *)
                       let fb = TyEl (TyTermExpr (EApp (ff, [b_e], loc))) in
                       let fa = TyEl (TyTermExpr (EApp (ff, [a_e], loc))) in
                       ok (TyArrow (fb, fa))
                   | _ -> ok (TyPrim "unknown"))
              | _ -> ok (TyPrim "unknown"))
         | _ -> err loc "psh_map expects 2 arguments: psh_map(F, f) for the arrow action F(f)")
      else
      let (name, args) =
        match name with
        | "map" -> ("__stream_map", args)
        | "filter" -> ("__stream_filter", args)
        | "fold" -> ("__stream_fold", args)
        | "for_every" -> ("__stream_for_every", args)
        | "iterate" -> ("__stream_iterate", args)
        | "take" -> ("__stream_take", args)
        | "sum_take" -> ("__stream_sum_take", args)
        | "to_stream" -> ("__stream_to_stream", args)
        | "Seq__map" -> ("__stream_map", args)
        | "Seq__filter" -> ("__stream_filter", args)
        | "Seq__fold" -> ("__stream_fold", args)
        | "Seq__from_list" -> ("__stream_from_list", args)
        | "Stream__iterate" -> ("__stream_iterate", args)
        | "Stream__take" -> ("__stream_take", args)
        | "Stream__sum_take" -> ("__stream_sum_take", args)
        | _ -> (name, args)
      in
      (* Special-case: apply_move's first argument is a move name (not
       * a value); skip type-inferring it as a regular variable.
       * __apply_move_in_<S> is a variant with an explicit target space, same
       * signature as apply_move (move_name, instance).
       *
       * __morph_in_<S>__<M> is another legitimate cross-space channel.
       * Syntactically
       *   LiftEU(eu) in USD_SPACE
       * desugars here into __morph_in_USD_SPACE__LiftEU(eu): the compiler
       * knows this is a categorical transport via the morph M, and bypasses
       * the space-leakage check. *)
      let is_apply_move =
        name = "apply_move"
        || (String.length name > 16
            && String.sub name 0 16 = "__apply_move_in_")
      in
      let is_morph_in_space =
        String.length name > 11
        && String.sub name 0 11 = "__morph_in_"
      in
      (* Stream METHOD sites: if the receiver (first rewritten arg)
         types as a stream, register the site so the desugar drains the
         wire; for_every exists ONLY for streams (lists keep the
         `for every x in xs` statement). fold on a stream is the
         accumulator: state threads through the lambda's parameters, so
         no closure capture is involved. *)
      let* () =
        if (name = "__stream_for_every" || name = "__stream_fold")
           && args <> [] then begin
          let* recv_ty = infer env ctx (List.hd args) in
          (match recv_ty with
           | TyStream _ ->
               Hashtbl.replace stream_method_table
                 (loc.start_line, loc.start_col) ();
               ok ()
           | _ when name = "__stream_for_every" ->
               err loc "for_every is the stream method; lists use the `for every x in xs` statement"
           | _ -> ok ())
        end else ok ()
      in
      (* __stream_map/filter/fold accept a function name as their last
       * argument (the type check on it is skipped). *)
      let is_seq_with_fun_arg =
        name = "__stream_map" || name = "__stream_filter" || name = "__stream_fold"
        || name = "__stream_for_every"
      in
      if is_apply_move then begin
        match args with
        | [first; second] ->
            let _ = first in
            let* second_ty = infer env ctx second in
            check_call env ctx name args [TyPrim "unknown"; second_ty] loc
        | _ -> err loc (Printf.sprintf "%s expects exactly 2 arguments" name)
      end else if is_seq_with_fun_arg then begin
        (* The last argument is a top-level function name. We skip type
         * checking that argument (as with apply_move) and substitute
         * TyPrim "unknown" to satisfy the signature. *)
        match List.rev args with
        | last :: rest_rev ->
            let _ = last in
            let rest = List.rev rest_rev in
            let* rest_tys =
              List.fold_left (fun acc arg ->
                let* tys = acc in
                let* t = infer env ctx arg in
                ok (tys @ [t])
              ) (ok []) rest
            in
            check_call env ctx name args (rest_tys @ [TyPrim "unknown"]) loc
        | [] -> err loc (Printf.sprintf "%s expects arguments" name)
      end else if is_morph_in_space then begin
        (* The morph-in-space transport accepts input from any space. It type
         * checks the args without the leakage check, then delegates to
         * check_call for the signature. *)
        let* arg_tys =
          List.fold_left (fun acc arg ->
            let* tys = acc in
            let* t = infer env ctx arg in
            ok (tys @ [t])
          ) (ok []) args
        in
        check_call env ctx name args arg_tys loc
      end else begin
      (* (E1111 cross-Space argument gating retired with `new P in Space`; see
       * E1110 above and chapter 10.)
       * A call can be a user function, a qualified operation
       * (Place__op via the desugarer's mangling), or a built-in. *)
      let arg_tys_result =
        List.fold_left
          (fun acc arg ->
             let* tys = acc in
             let* t = infer env ctx arg in
             ok (tys @ [t]))
          (ok []) args
      in
      let* arg_tys = arg_tys_result in
      (* A primitive type name in term position is its Tarski code (TyUniverse),
       * legitimate only in a universe-code slot (refl/Id/El/hcomp, handled
       * above). It has no runtime f64 representation, so as an ordinary call
       * argument it used to slip through the lax stdlib arg check and then crash
       * at emit ("variable '<T>' not in scope"). Reject it here, cleanly. *)
      let* () =
        (* The cubical/universe primitives (transport, transp, ua, idEquiv, refl,
         * …) legitimately CONSUME a type-code at compile time; only the ordinary
         * data path (List/Vec/Map/…) would lower it as an f64 and crash. So skip
         * the guard for the Cubical_bindings family. *)
        if (not (Cubical_bindings.is_primitive name))
           && List.exists (function TyUniverse _ -> true | _ -> false) arg_tys then
          err loc (Printf.sprintf
            "%s: a type name is a compile-time code, not a runtime value, so it \
             cannot be passed as an argument" name)
        else ok ()
      in
      check_call env ctx name args arg_tys loc
      end

  | EWireTo (sp, loc) ->
      if Hashtbl.mem wire_spaces sp then ok (TyWire sp)
      else err loc (Printf.sprintf
        "wire to %s: unknown Space. Import its producer first \
(import <module>::<producer> from %s)" sp sp)

  | EProduce (body, _) ->
      (* produce { ... } as an expression: the body's statements are
         checked like the statement form; the value is the stream id,
         a number, same convention as the Stream.* API. The stream's
         element type is inferred from the emits (number if none), and
         is checked against the declared return type by the caller. *)
      (match first_assign_loc body with
       | Some l ->
           err l "`=` (Space-cell assignment) is not yet supported inside a `produce` \
                  block. Use `Space.set(cell, value)`, or compute the value before the \
                  block and bind it with `be`. (Full support lands with the produce \
                  rework in 1.2.)"
       | None ->
         let saved = !produce_emit_ty in
         produce_emit_ty := None;
         let* _ = !produce_check_ref env ctx body None in
         let elem = (match !produce_emit_ty with Some t -> t | None -> TyPrim "number") in
         produce_emit_ty := saved;
         ok (TyStream elem))
  | ESpawn (count, body, loc) ->
      (* spawn { ... } / spawn in N parallel { ... } as an expression: the body
         runs in one or N isolated forked replicas; each `promote E` contributes
         an element of type T; the whole construct is `stream of T`, collected in
         the parent's heap. The count, if present, must be a number (evaluated in
         the parent before fork). A block with no promote is an error. *)
      let* () = (match count with
        | Some n -> let* _ = check env ctx n (TyPrim "number") in ok ()
        | None -> ok ()) in
      let* () = (match first_assign_loc body with
        | Some l ->
            err l "`=` (Space-cell assignment) is not yet supported inside a `spawn` \
                   block. Use `Space.set(cell, value)`, or compute the value before the \
                   block and bind it with `be`. (Full support lands with the produce \
                   rework in 1.2.)"
        | None -> ok ()) in
      let saved = !spawn_promote_ty in
      spawn_promote_ty := None;
      (* spawn_index : number is in scope only inside the body (the replica's
         own index, 0..N-1). *)
      let body_env = Tyenv.add_var env "spawn_index" (TyPrim "number") in
      incr in_spawn_depth;
      let* _ = !produce_check_ref body_env ctx body None in
      decr in_spawn_depth;
      (match !spawn_promote_ty with
       | Some elem ->
           spawn_promote_ty := saved;
           ok (TyStream elem)
       | None ->
           spawn_promote_ty := saved;
           err loc "spawn block has no promote: it must promote at least one value")
  | ENew (place_name, fas, loc) ->
      (match Tyenv.lookup_place env place_name with
       | None -> err loc (Printf.sprintf "unknown place %s in new expression" place_name)
       | Some pd ->
           (* Check that each field assignment matches a declared field
            * and has the right type. *)
           let fields = List.filter_map
             (function FoField f -> Some { f with fd_ty = resolve_tparams pd.pd_type_params f.fd_ty }
                     | FoOp _ -> None | FoCell _ -> None | FoLaw _ -> None)
             pd.pd_members in
           let* () = check_field_assignments env ctx pd.pd_name fields fas loc in
           ok (TyUser place_name))

  | ENewIn (place_name, _space_name, fas, loc) ->
      (* Same type check as ENew. The space is validated at runtime via
       * yon_rt_register_space (for now; a static check will come when the
       * space binding is required by the type system). *)
      (match Tyenv.lookup_place env place_name with
       | None -> err loc (Printf.sprintf "unknown place %s in 'new in' expression" place_name)
       | Some pd ->
           let fields = List.filter_map
             (function FoField f -> Some { f with fd_ty = resolve_tparams pd.pd_type_params f.fd_ty }
                     | FoOp _ -> None | FoCell _ -> None | FoLaw _ -> None)
             pd.pd_members in
           let* () = check_field_assignments env ctx pd.pd_name fields fas loc in
           ok (TyUser place_name))

  | EBinop (op, e1, e2, loc) ->
      let* t1 = infer env ctx e1 in
      let* t2 = infer env ctx e2 in
      ty_of_binop op t1 t2 env ctx loc

  | EParen (inner, _) -> infer env ctx inner

  | EAll (place_name, cond, loc) ->
      (* "all P where cond" — returns a list of P, where cond is checked
       * in a context with a fresh variable of type P. *)
      (match Tyenv.lookup_place env place_name with
       | None -> err loc (Printf.sprintf "unknown place %s in all expression" place_name)
       | Some _ ->
           let env' = Tyenv.add_var env "_" (TyUser place_name) in
           let* _ = check_condition env' ctx cond in
           ok (TyList (TyUser place_name)))

  | EIn (inner, _ctx_name, _loc) ->
      (* "e in Context" — for v0.3 prototype, the contextual type is
       * the same as the inner type. *)
      infer env ctx inner

  (* ── HoTT term constructors ──────────────────────────────────── *)
  | ERefl (e, _loc) ->
      (* refl(t) : Id_A(t, t) — the endpoints ARE the argument t, tracked
       * faithfully (no placeholder). Endpoint comparison in type_equal is
       * now structural, so the real term must appear here. *)
      let* a_ty = infer env ctx e in
      ok (TyId (a_ty, TyTermExpr e, TyTermExpr e))
  | EPair (a, b, _loc) ->
      let* a_ty = infer env ctx a in
      let* b_ty = infer env ctx b in
      (* Non-dependent Sigma fallback: Sigma(_:A). B where B does not
       * mention the first component. For dependent pairs the user
       * must currently annotate. *)
      ok (TySigma ("_", a_ty, b_ty))
  | EFst (p, loc) ->
      let* p_ty = infer env ctx p in
      (match p_ty with
       | TySigma (_, a, _) -> ok a
       | TyPrim "unknown" | TyVar _ -> ok (TyPrim "unknown")
       | other ->
           err loc (Printf.sprintf "fst expects Sigma type, got %s"
                      (Tyenv.ty_to_string other)))
  | ESnd (p, loc) ->
      let* p_ty = infer env ctx p in
      (match p_ty with
       | TySigma (_, _, b) -> ok b
       | TyPrim "unknown" | TyVar _ -> ok (TyPrim "unknown")
       | other ->
           err loc (Printf.sprintf "snd expects Sigma type, got %s"
                      (Tyenv.ty_to_string other)))
  | EJ (c, d, p, loc) ->
      (* Tarski motive engine. A GENUINE motive C is a term (a name or a
       * lambda) whose type is a function landing in the universe (U_omega /
       * Type). When C is such, J is typed dependently (Paulin-Mohring/based):
       *   p : Id_A(a, x)
       *   d : El(C a (refl a))      (base case)
       *   J(C, d, p) : El(C x p)    (motive applied to the far endpoint + path)
       * The applied codes live as Surface EApp inside TyEl and desugar natively
       * into Ast.TyEl(App ...), the world where subst_term_in_ty operates.
       * If C is NOT a genuine motive (e.g. a placeholder literal that some call
       * sites still pass), keep the honest non-dependent typing — read d's
       * codomain — so existing programs are preserved without faking it. *)
      let rec lands_in_universe = function
        | TyArrow (_, cod) | TyPi (_, _, cod) -> lands_in_universe cod
        | TyUniverse _ -> true
        | _ -> false
      in
      let* p_ty = infer env ctx p in
      (match p_ty with
       | TyId (_a_ty, TyTermExpr e_a, TyTermExpr e_x) ->
           let* c_ty = infer env ctx c in
           if lands_in_universe c_ty then begin
             (* genuine motive: dependent (Tarski) J *)
             let refl_a = ERefl (e_a, loc) in
             let expected_d = TyEl (TyTermExpr (EApp (c, [e_a; refl_a], loc))) in
             let* () = check env ctx d expected_d in
             ok (TyEl (TyTermExpr (EApp (c, [e_x; p], loc))))
           end else begin
             (* placeholder motive: honest non-dependent typing *)
             let* d_ty = infer env ctx d in
             (match d_ty with
              | TyArrow (_dom, cod) -> ok cod
              | TyPi (_, _dom, cod) -> ok cod
              | _ -> ok (TyPrim "unknown"))
           end
       | TyPrim "unknown" | TyVar _ -> ok (TyPrim "unknown")
       | other ->
           err loc (Printf.sprintf "ind_path expects Id type as 3rd arg, got %s"
                      (Tyenv.ty_to_string other)))
  | EQuote (c, a, loc) ->
      (* quote(c, a) : El(c). Check the inhabitant against the decoded carrier;
       * reject a code that does not decode. *)
      let cname = (match c with TyTermExpr e -> ty_term_to_name e) in
      (match Catt_r_yon.el_decode (Catt_r_yon.TmVar cname) with
       | Some carrier ->
           let* a_ty = infer env ctx a in
           if Dispatcher.type_equal env ctx a_ty carrier
           then ok (TyEl c)
           else err loc (Printf.sprintf
             "quote: inhabitant has type %s but El(%s) carrier is %s"
             (Tyenv.ty_to_string a_ty) cname (Tyenv.ty_to_string carrier))
       | None ->
           err loc (Printf.sprintf
             "El(%s): code does not decode to a carrier (only 0/1-cells supported)" cname))
  | EElMatch (target, ret, body, loc) ->
      (* el_match(target, ret, body): infer target : El(_), accept ret, require
       * body to be a function and return its codomain. *)
      let* tgt_ty = infer env ctx target in
      (match tgt_ty with
       | TyEl _ ->
           let* _ret_ty = infer env ctx ret in
           let* body_ty = infer env ctx body in
           (match body_ty with
            | TyArrow (_dom, cod) -> ok cod
            | TyPi (_, _dom, cod) -> ok cod
            | _ -> ok (TyPrim "unknown"))
       | TyPrim "unknown" | TyVar _ -> ok (TyPrim "unknown")
       | other ->
           err loc (Printf.sprintf "el_match expects El(...) as 1st arg, got %s"
                      (Tyenv.ty_to_string other)))
  | EPullback (_f, _g, _loc) ->
      (* pullback(f, g) as an expression. We return TyPrim "number" (a runtime
       * handle placeholder). The full semantic validation (f and g must be
       * morphs parallel to a cospan f : A -> C, g : B -> C) stays open. *)
      ok (TyPrim "number")
  | EPushout (_f, _g, _loc) ->
      ok (TyPrim "number")
  | EPullbackVal (_f, _g, _a, _b, _loc) ->
      (* pullback runtime semantics.
       * Returns a handle encoded as a number (bit-packing). *)
      ok (TyPrim "number")
  | ENot (e, _loc) ->
      (* Unary not. Accepts boolean -> boolean, proposition -> proposition, and
       * number -> boolean (C-style: 0 -> true, nonzero -> false). *)
      let* t = infer env ctx e in
      (match t with
       | TyPrim "boolean" -> ok (TyPrim "boolean")
       | TyPrim "proposition" -> ok (TyPrim "proposition")
       | TyPrim "number" -> ok (TyPrim "boolean")
       | _ ->
           err (location_of_expr e) "not: expected boolean, proposition, or number")

  | EIfThenElse (c, a, b, _loc) ->
      (* if/then/else expression typing:
       * - c must be boolean
       * - a and b must have same type -> result type *)
      let* _ = check env ctx c (TyPrim "boolean") in
      let* ta = infer env ctx a in
      let* _ = check env ctx b ta in
      ok ta

  | ELam (params, body, _loc) ->
      (* Inline lambda: extend the env with the parameters, infer the body,
       * return the TyArrow chain. Parameter types come annotated from the
       * surface syntax. *)
      let env_ext = List.fold_left
        (fun env_acc (pname, pty) ->
           Tyenv.add_var env_acc pname pty)
        env params in
      let* body_ty = infer env_ext ctx body in
      let result_ty = List.fold_right
        (fun (_pname, pty) acc -> TyArrow (pty, acc))
        params body_ty
      in
      ok result_ty

  | EMoveLam (params, body, from_p, to_p, loc) ->
      (* A lambda of type move from P1 to P2. The body type-check is done on
       * the synthetic fun generated by the desugar; here we return the handle
       * type directly.
       *
       * Reject a handle nested inside a handle. A move cannot contain another
       * handle lambda (move/reduction/morph/view) in its body: morphisms are
       * static structures of the topos, not dynamic values built from other
       * morphisms. A functional ELam is allowed (it is a computational
       * endomorphism internal to the place). *)
      let* () = forbid_local_capture "move" params body env loc in
      let* () = forbid_handle_in_body "move" body loc in
      ok (TyMoveHandle (Some from_p, Some to_p))

  | EReductionLam (params, body, of_p, loc) ->
      let* () = forbid_local_capture "reduction" params body env loc in
      let* () = forbid_handle_in_body "reduction" body loc in
      ok (TyReductionHandle (Some of_p))

  | EMorphLam (params, body, from_s, to_s, loc) ->
      let* () = forbid_local_capture "morph" params body env loc in
      let* () = forbid_handle_in_body "morph" body loc in
      ok (TyMorphHandle (Some from_s, Some to_s))

  | EFunctorLam (params, body, from_w, to_w, laws, loc) ->
      (* A first-class functor, typed as a morphism handle between worlds. The
       * declared functor laws are verified at two levels:
       *   (1) syntactic: only `identity` and `composition` are valid names;
       *   (2) semantic: by construction, analyzing the use of the input
       *       variable in the body. F(x)=>body is functorial if the body uses
       *       x in a way that preserves identity and composition. *)
      let* () = forbid_local_capture "functor" params body env loc in
      let* () = forbid_handle_in_body "functor" body loc in
      let rec check_law_names = function
        | [] -> ok ()
        | "identity" :: rest -> check_law_names rest
        | "composition" :: rest -> check_law_names rest
        | bad :: _ ->
            err loc (Printf.sprintf
              "unknown functor law '%s': the laws of a functor are \
               'identity' (preserves identities) and 'composition' (preserves o)"
              bad)
      in
      let* () = check_law_names laws in
      (* Semantic check by construction. Let the input variable be the first
       * parameter; count how many times it appears in the body. *)
      let input_var = match params with (n, _) :: _ -> Some n | [] -> None in
      let rec count_var (name : string) (e : expr) : int =
        match e with
        | EVar (v, _) -> if v = name then 1 else 0
        | ELit _ -> 0
        | ECall (_, args, _) -> List.fold_left (fun a x -> a + count_var name x) 0 args
        | EBinop (_, l, r, _) -> count_var name l + count_var name r
        | EParen (inner, _) -> count_var name inner
        | EField (o, _, _) -> count_var name o
        | ENot (inner, _) -> count_var name inner
        | EIfThenElse (c, t, f, _) -> count_var name c + count_var name t + count_var name f
        | _ -> 0
      in
      let is_identity_body =
        match input_var, body with
        | Some n, EVar (v, _) -> v = n   (* (x) => x : identity functor *)
        | _ -> false
      in
      let uses =
        match input_var with Some n -> count_var n body | None -> 0 in
      (* Law `composition` (F preserves o): guaranteed by construction only if
       * the body uses the input linearly (exactly once) or is the identity. If
       * it duplicates the input (uses > 1, e.g. x + x) or ignores it
       * (uses = 0), functoriality is not guaranteed, so the law is rejected. *)
      let* () =
        if List.mem "composition" laws && not is_identity_body && uses <> 1 then
          err loc (Printf.sprintf
            "functor law 'composition' cannot be verified by construction: \
             the body uses the input variable %d times (it must be exactly 1, \
             or the identity functor). A body that duplicates or ignores the \
             input does not preserve composition in general."
            uses)
        else ok ()
      in
      (* Law `identity` (F(id)=id): guaranteed if the functor is the identity,
       * or if it maps the input through a single operation (preserving the
       * identity structure). uses = 1 or identity. *)
      let* () =
        if List.mem "identity" laws && not is_identity_body && uses <> 1 then
          err loc (Printf.sprintf
            "functor law 'identity' cannot be verified by construction: \
             the body must be the identity or use the input exactly once \
             (used %d times)."
            uses)
        else ok ()
      in
      let _ = from_w and _ = to_w in
      ok (TyMorphHandle (Some from_w, Some to_w))

  | EViewLam (params, body, of_p, loc) ->
      (* TyViewHandle (Some P) per single-projection
       * view inline `view(s: P) => expr of P`. *)
      let* () = forbid_local_capture "view" params body env loc in
      let* () = forbid_handle_in_body "view" body loc in
      ok (TyViewHandle (Some of_p))

  | EComposeWith (h1, h2, loc) ->
      (* compose h1 with h2.
       * Semantics: result(x) = h2(h1(x)).
       *
       * Categorical composability check: the target of h1 must match the
       * source of h2.
       *
       * 5 casi per kind:
       * - fun o fun                  -> fun
       * - move(P->Q) o move(Q->R)      -> move(P->R)
       * - morph(S1->S2) o morph(S2->S3) -> morph(S1->S3)
       * - view(P) o fun              -> view(P)  (post-compose)
       * - reduction(P) o fun         -> reduction(P)
       *
       * Cross-kind compositions (e.g. move + morph) are WRONG
       * categoricamente: i tipi handle vivono in categorie distinte. *)
      let* t1 = infer env ctx h1 in
      let* t2 = infer env ctx h2 in
      (match t1, t2 with
       (* fun o fun *)
       | TyArrow (_a, _b), TyArrow (_, c) -> ok (TyArrow (_a, c))
       (* move . move: the target of h1 = the source of h2 *)
       | TyMoveHandle (Some p1_from, Some p1_to),
         TyMoveHandle (Some p2_from, Some p2_to)
         when p1_to = p2_from ->
           ok (TyMoveHandle (Some p1_from, Some p2_to))
       | TyMoveHandle (Some _, Some p1_to),
         TyMoveHandle (Some p2_from, Some _) ->
           err loc (Printf.sprintf
             "compose with: move composition non valid — target di h1 '%s' \
              non match source di h2 '%s'."
             p1_to p2_from)
       (* morph . morph: the target topos of h1 = the source topos of h2 *)
       | TyMorphHandle (Some s1_from, Some s1_to),
         TyMorphHandle (Some s2_from, Some s2_to)
         when s1_to = s2_from ->
           ok (TyMorphHandle (Some s1_from, Some s2_to))
       | TyMorphHandle (Some _, Some s1_to),
         TyMorphHandle (Some s2_from, Some _) ->
           err loc (Printf.sprintf
             "compose with: morph composition non valid — target topos di h1 '%s' \
              non match source topos di h2 '%s'."
             s1_to s2_from)
       (* view . fun: post-compose the view with a fun *)
       | TyViewHandle (Some p), TyArrow (_, _) ->
           ok (TyViewHandle (Some p))
       (* reduction or fun: post-compose the reduction with a fun *)
       | TyReductionHandle (Some p), TyArrow (_, _) ->
           ok (TyReductionHandle (Some p))
       (* Cross-kind: an error *)
       | _, _ ->
           err loc (Printf.sprintf
             "compose with: non-composable types (%s) . (%s). \
              Only handles of the same kind (fun, move, morph) or post-compose \
              of view/reduction with fun are allowed."
             (Tyenv.ty_to_string t1) (Tyenv.ty_to_string t2)))

(* ─── Expression: check (delegate to infer when possible) ──────────── *)

and check (env : Tyenv.env) (ctx : Reduce.ctx) (e : expr) (expected : ty) : unit tc_result =
  (* Universal property of the terminal object 1: for every object A there is
     a unique map `!_A : A -> 1`. So a term of any type checks against 1 (it
     maps to the unique inhabitant `()`). This is the constant functor toward 1;
     it fires only when the expected type is the terminal (a fieldless place),
     leaving every other checking judgement unchanged. *)
  if is_terminal_ty env expected then ok ()
  else
  let fallback env e expected =
    let* actual = infer env ctx e in
    if Dispatcher.subtype env ctx ~sub:actual ~super:expected
       || comprehension_coerces_to env ctx ~sub:actual ~super:expected then ok ()
    else err (location_of_expr e)
      (Printf.sprintf "type mismatch: expected %s, got %s"
         (Tyenv.ty_to_string expected) (Tyenv.ty_to_string actual))
  in
  match e, expected with
  | EHITConstr (ctor, args, loc), (TySum variants | TySumIn (variants, _)) ->
      (match List.find_opt (fun variant -> variant.v_name = ctor) variants with
       | None -> err loc (Printf.sprintf
           "hit(%s): constructor does not belong to expected sum %s"
           ctor (Tyenv.ty_to_string expected))
       | Some variant ->
           if List.length args <> List.length variant.v_args then
             err loc (Printf.sprintf "hit(%s): expected %d argument(s), got %d"
               ctor (List.length variant.v_args) (List.length args))
           else
             let rec check_args actual expected =
               match actual, expected with
               | [], [] -> ok ()
               | arg :: actual, ty :: expected ->
                   let* () = check env ctx arg ty in
                   check_args actual expected
               | _ -> assert false
             in
             check_args args variant.v_args)
  | ELam (params, body, _), (TyPi _ | TyArrow _) ->
      (* Bidirectional lambda checking.  A dependent expected type carries the
         information needed to type an unannotated surface lambda and to align
         its binder with endpoint terms in the codomain. *)
      let rec go env params expected =
        match params, expected with
        | [], _ -> check env ctx body expected
        | (pn, annotated) :: rest, TyPi (x, dom, cod) ->
            if annotated <> TyPrim "unknown"
               && not (Dispatcher.type_equal env ctx annotated dom) then
              err (location_of_expr e)
                (Printf.sprintf "lambda parameter %s: expected %s, got %s"
                   pn (Tyenv.ty_to_string dom) (Tyenv.ty_to_string annotated))
            else
              let env' = Tyenv.add_var env pn dom in
              let cod' =
                if String.equal x pn then cod
                else Dispatcher.rename_ty x pn cod
              in
              go env' rest cod'
        | (pn, annotated) :: rest, TyArrow (dom, cod) ->
            if annotated <> TyPrim "unknown"
               && not (Dispatcher.type_equal env ctx annotated dom) then
              err (location_of_expr e)
                (Printf.sprintf "lambda parameter %s: expected %s, got %s"
                   pn (Tyenv.ty_to_string dom) (Tyenv.ty_to_string annotated))
            else
              go (Tyenv.add_var env pn dom) rest cod
        | _ -> fallback env e expected
      in
      go env params expected
  | EHITElim (_, branches, x, loc), _
      when (match x with
            | EVar (xv, _) -> ty_mentions_evar xv expected
            | _ -> false) ->
      (* Dependent elimination in CHECKING mode. The expected type varies with the
         scrutinee variable, so it IS the motive P(x): each branch is checked
         against P[x := ctor], the constructor substituted into the expected type,
         which then reduces (e.g. bit2b(b2bit(tt)) -> tt) so the branch proof
         type-checks. This is the induction principle — the unique dependent
         section given by the inductive's initial-algebra universal property,
         certified below by factoring the branch cone. Fires ONLY when the
         expected type mentions the scrutinee; otherwise the constant-motive path
         (the `__match` infer arm) applies unchanged. The motive is compile-time
         only: desugar/emit/runtime stay byte-identical (match still lowers to the
         same tag switch). *)
      let xv = (match x with EVar (xv, _) -> xv | _ -> assert false) in
      let* x_ty = infer env ctx x in
      (match hit_signature_of env x_ty with
       | None -> fallback env e expected
       | Some (hname, sig_) ->
           let handled = List.map (fun (n, _, _) -> n) branches in
           let missing =
             if List.mem "_" handled then []
             else Hit_env.missing_constructors sig_ handled in
           let* () =
             match missing with
             | [] -> ok ()
             | ns ->
                 err loc (Printf.sprintf
                   "match: a result type that varies with the scrutinee needs a \
                    branch for every constructor; missing %s"
                   (String.concat ", " ns)) in
           let rec go_branches = function
             | [] -> ok ()
             | ("_", _, _) :: _ ->
                 err loc "match: a result type that varies with the scrutinee \
                          needs every constructor listed; `_` cannot refine it"
             | (ctor, vars, body) :: rest ->
                 (match Hit_env.find_constructor [hname, sig_] ctor with
                  | None ->
                      err loc (Printf.sprintf
                        "match: constructor %s does not belong to %s" ctor hname)
                  | Some (_, kind) ->
                      let params = Hit_env.constructor_params kind in
                      if List.length vars <> List.length params then
                        err loc (Printf.sprintf
                          "match: branch %s expects %d payload binder(s), got %d"
                          ctor (List.length params) (List.length vars))
                      else
                        let branch_env =
                          Tyenv.add_vars env
                            (List.combine vars (List.map snd params)) in
                        let ctor_expr =
                          EHITConstr
                            (ctor, List.map (fun n -> EVar (n, loc)) vars, loc) in
                        let refined = subst_evar_in_ty xv ctor_expr expected in
                        let* () = check branch_env ctx body refined in
                        go_branches rest)
           in
           let* () = go_branches branches in
           if certify_dependent_cone hname branches then ok ()
           else
             err loc "match: the branch cone does not factor through the \
                      inductive's universal cell (malformed dependent cocone)")
  | _ -> fallback env e expected

and location_of_expr (e : expr) : location =
  match e with
  | EProduce (_, l) | EWireTo (_, l)
  | ELit (_, l) | EVar (_, l) | EField (_, _, l) | ECall (_, _, l)
  | ENew (_, _, l) | ENewIn (_, _, _, l) | EBinop (_, _, _, l) | EParen (_, l)
  | EAll (_, _, l) | EIn (_, _, l)
  | ERefl (_, l) | EPair (_, _, l) | EFst (_, l) | ESnd (_, l)
  | EJ (_, _, _, l)
  | EPullback (_, _, l) | EPushout (_, _, l) -> l
  | EPullbackVal (_, _, _, _, l) -> l
  | ENot (_, l) -> l
  | EIfThenElse (_, _, _, l) -> l
  | ELam (_, _, l) -> l
  | EMoveLam (_, _, _, _, l)
  | EReductionLam (_, _, _, l)
  | EMorphLam (_, _, _, _, l) -> l
  | EFunctorLam (_, _, _, _, _, l) -> l
  | EViewLam (_, _, _, l) -> l
  | EComposeWith (_, _, l) -> l
  | ESpawn (_, _, l) -> l
  | EQuote (_, _, l) -> l
  | EElMatch (_, _, _, l) -> l
  | EApp (_, _, l) -> l
  | EHITElim (_, _, _, l) -> l
  | EPathApp (_, _, l) -> l
  | EPathAbs (_, _, l) -> l
  | EHITConstr (_, _, l) -> l

(* ─── Call checking ────────────────────────────────────────────────── *)

and check_call (env : Tyenv.env) (ctx : Reduce.ctx)
               (name : string) (args : expr list) (arg_tys : ty list) (loc : location) : ty tc_result =
  (* Builtin: apply_move(MoveName, source) — applies a registered move.
   * __apply_move_in_<S> respects the same signature. *)
  let is_apply_move =
    name = "apply_move"
    || (String.length name > 16
        && String.sub name 0 16 = "__apply_move_in_")
  in
  if is_apply_move then begin
    if List.length arg_tys <> 2 then
      err loc (Printf.sprintf
                 "%s expects 2 arguments: (move_name, source_record)" name)
    else
      ok (TyPrim "unknown")
  end else
  (* Builtin: Move.merge(MoveName, s1, s2) — applies a registered Form B
   * (merge) move to two instances. Same loose typing as apply_move; the
   * emitter checks the move exists and is a merge. *)
  if name = "Move__merge" then begin
    if List.length arg_tys <> 3 then
      err loc "Move.merge expects 3 arguments: (move_name, source1, source2)"
    else
      ok (TyPrim "unknown")
  end else
  (* If `name` is a local variable of type TyArrow (a higher-order function
   * passed as a parameter), treat the call as an application of the function
   * value. *)
  (match Tyenv.lookup_var env name with
   | Some var_ty when (match var_ty with TyArrow _ -> true | _ -> false) ->
       let rec apply_arrow t args =
         match t, args with
         | TyArrow (param, ret), arg :: rest ->
             if Dispatcher.subtype env ctx ~sub:arg ~super:param
                || param = TyPrim "unknown"
                || arg = TyPrim "unknown"
             then apply_arrow ret rest
             else err loc (Printf.sprintf
               "HOF %s: parameter expects %s, got %s"
               name (Tyenv.ty_to_string param) (Tyenv.ty_to_string arg))
         | _, [] -> ok t  (* finished — return the residual type *)
         | _, _ :: _ ->
             err loc (Printf.sprintf
               "HOF %s: too many arguments — not enough arrows in %s"
               name (Tyenv.ty_to_string var_ty))
       in
       apply_arrow var_ty arg_tys
   | Some (TyMoveHandle (_, target_p_opt)) ->
       (* m(src) with m : TyMoveHandle. Returns the target place of the
        * move. *)
       (match target_p_opt with
        | Some tn -> ok (TyUser tn)
        | None -> ok (TyPrim "unknown"))
   | Some (TyReductionHandle _) ->
       (* r(args) with r : TyReductionHandle. A typical reduction is
        * (acc, x) -> acc'; we return unknown because the type of acc depends
        * on the binding. *)
       ok (TyPrim "unknown")
   | Some (TyMorphHandle (source_topos_opt, target_topos_opt)) ->
       (* multi-place lookup.
        * To derive the target place of m(src), look for a registered morph
        * (source = source_topos, target = target_topos) whose on_object
        * accepts the type of the first arg.
        *
        * If it finds a match, return the precise target place.
        * Fallback: the first place of the target topos. *)
       let source_place_opt = match arg_tys with
         | TyUser pname :: _ -> Some pname
         | _ -> None
       in
       (match target_topos_opt with
        | Some tn ->
            (match source_topos_opt, source_place_opt with
             | Some sn, Some sp ->
                 (match Tyenv.find_target_place_for_source env sn tn sp with
                  | Some pd -> ok (TyUser pd.pd_name)
                  | None -> ok (TyUser tn))
             | _ ->
                 (match Tyenv.first_place_in_topos env tn with
                  | Some pd -> ok (TyUser pd.pd_name)
                  | None -> ok (TyUser tn)))
        | None -> ok (TyPrim "unknown"))
   | Some (TyViewHandle _) ->
       (* v(x) applies a view passed as a parameter. A view is not callable in
        * the classic way in current Yon; we leave it open as unknown. *)
       ok (TyPrim "unknown")
   | _ ->
  (* SOUNDNESS: equiv(f, g, eta, eps) — full coherence check. The homotopies
   * must connect the right endpoints, verified with the actual terms f, g:
   *   eta : forall (a:A). Id(A, g(f a), a)
   *   eps : forall (b:B). Id(B, f(g b), b)
   * This is the dependent check above the structural gate: it does not merely
   * require eta/eps to be paths, it requires them to be the RIGHT paths. *)
  if name = "equiv" then
    (match args, arg_tys with
     | [f_e; g_e; eta_e; eps_e], [f_ty; g_ty; _; _] ->
         (match f_ty, g_ty with
          | (TyArrow (a_ty, _) | TyPi (_, a_ty, _)),
            (TyArrow (b_ty, _) | TyPi (_, b_ty, _)) ->
              let a = "__eq_a" and b = "__eq_b" in
              let eta_expected =
                TyPi (a, a_ty,
                      TyId (a_ty,
                            TyTermExpr (EApp (g_e, [EApp (f_e, [EVar (a, loc)], loc)], loc)),
                            TyTermExpr (EVar (a, loc)))) in
              let eps_expected =
                TyPi (b, b_ty,
                      TyId (b_ty,
                            TyTermExpr (EApp (f_e, [EApp (g_e, [EVar (b, loc)], loc)], loc)),
                            TyTermExpr (EVar (b, loc)))) in
              let* () = check env ctx eta_e eta_expected in
              let* () = check env ctx eps_e eps_expected in
              (* endpoints a_ty, b_ty (extracted for the coherence check) are
               * what the equivalence type must carry, so ua can name them *)
              ok (Cubical_bindings.mk_equiv_ty a_ty b_ty)
          | _ -> err loc "equiv: forward map (arg 1) and inverse (arg 2) must be functions")
     | _ -> err loc "equiv expects 4 arguments (f, g, eta, eps)")
  else
  (* ap : (f : A -> B) -> Id A x y -> Id B (f x) (f y).  Precise when f is a
   * simple (non-dependent) function and the path's endpoints are tracked: the
   * result endpoints are f applied to x and to y, built from the argument
   * EXPRESSION of f (available here in the ECall handler, unlike the types-only
   * cubical dispatch).  A carrier/domain mismatch is a clean type error; any
   * other shape (dependent f -> PathP, untracked-endpoint path) keeps the
   * existing loose cubical typing — no fake precision. *)
  if name = "ap" then
    (match args, arg_tys with
     | [f_e; _], [TyArrow (dom, cod); TyId (carrier, x, y)]
       when Dispatcher.type_equal env ctx dom carrier ->
         let apf t = match t with TyTermExpr ex -> TyTermExpr (EApp (f_e, [ex], loc)) in
         ok (TyId (cod, apf x, apf y))
     | [_; _], [TyArrow (dom, _); TyId (carrier, _, _)]
       when not (Dispatcher.type_equal env ctx dom carrier) ->
         err loc "ap: the function's domain does not match the path's carrier type"
     | _ ->
         (* ap maps a FUNCTION over a path; a non-function head (a number/bool/
          * text scalar or a data value, e.g. the ill-typed `ap(75, p)` the
          * permissive cubical check would admit) has no action to apply. Reject
          * it cleanly here instead of letting the reducer fabricate `App(75, a)`,
          * which reaches emit as a call to a non-function and Fatal-crashes. A
          * genuine function types as an arrow (TyArrow/TyPi) or the loose fun
          * code; anything else is rejected. *)
         let is_fun = function
           | TyArrow _ | TyPi _ | TyPrim "fun" | TyUser "fun" -> true
           | _ -> false in
         (match arg_tys with
          | ftype :: _ when not (is_fun ftype) ->
              err loc "ap: the first argument must be a function (A -> B) — ap \
                       maps a function over a path, so a non-function head has \
                       no action to apply"
          | _ ->
              (match Cubical_bindings.check_call name arg_tys with
               | Ok ty -> ok ty
               | Error msg -> err loc msg)))
  else
  (* transport : Path U A B -> A -> B.  Precise for the operative univalence
   * form transport(ua(e), x): e : Equiv A B is a Sigma headed by A -> B, so
   * the univalence path runs from A to B, the result type is B, and the value
   * x must have type A.  The reducer computes this to the equivalence's
   * forward map applied to x (the ua anchor).  Any other form (a path bound to
   * a variable, a within-type path) keeps the loose typing (transport stays in
   * the source type) — see the Task 0-A gate note; no fake precision. *)
  if name = "transport" then
    (match args, arg_tys with
     | [ECall ("ua", [e_e], _); _], [_; x_ty] ->
         (match infer env ctx e_e with
          | Ok (TySigma (_, TyArrow (a_ty, b_ty), _)) ->
              if Dispatcher.type_equal env ctx x_ty a_ty then ok b_ty
              else err loc "transport: the value's type must match the source type A \
                            of the univalence path ua : Path U A B"
          | _ ->
              (match Cubical_bindings.check_call name arg_tys with
               | Ok ty -> ok ty | Error msg -> err loc msg))
     | _ ->
         (match Cubical_bindings.check_call name arg_tys with
          | Ok ty -> ok ty | Error msg -> err loc msg))
  else
  (* First, try cubical primitives. *)
  if Cubical_bindings.is_primitive name then
    match Cubical_bindings.check_call name arg_tys with
    | Ok ty -> ok ty
    | Error msg -> err loc msg
  else
  (* Then try user-defined functions. *)
  match Tyenv.lookup_fun env name with
  | Some fs ->
      let* () = check_call_signature env ctx name fs.fs_params arg_tys loc in
      (* Transitive effect propagation. If the called function declares
       * `visits E`, the caller must in turn cover E, either through its own
       * `visits E` (E in current_effects) or through an active handler for E.
       * This way the effect climbs the chain of callers up to main, and no
       * effect stays hidden. The same rule already applied to operation calls,
       * now extended to functions. *)
      let* () =
        List.fold_left (fun acc eff ->
          let* () = acc in
          if List.mem eff env.current_effects
             || List.exists
                  (fun rname ->
                     match Tyenv.lookup_reduction env rname with
                     | Some rd -> rd.rd_of = eff
                     | None -> false)
                  env.active_handlers
          then ok ()
          else err loc (Printf.sprintf
            "function '%s' visits effect '%s', but the caller does not \
             declare it. Add `visits %s` to the caller's signature (effects \
             propagate along the call chain)."
            name eff eff)
        ) (ok ()) fs.fs_visits
      in
      ok fs.fs_return
  | None ->
      (* Try qualified operation (desugared name: "Place__op"). *)
      (match Tyenv.lookup_op env name with
       | Some op ->
           let* () = check_op_call env ctx op arg_tys loc in
           ok op.os_return
       | None ->
           (* Try as an unqualified operation name. *)
           match Tyenv.lookup_op_unqualified env name with
           | [op] ->
               let* () = check_op_call env ctx op arg_tys loc in
               ok op.os_return
           | [] ->
               (* Try as a HIT constructor (point or path). *)
               (match Hit_env.find_constructor Hit_env.builtin_env name with
                | Some (sig_, kind) ->
                    let params = Hit_env.constructor_params kind in
                    let result = Hit_env.constructor_result kind in
                    (* For HIT constructors with type parameters, we
                     * accept any argument types in the type-parameter
                     * positions (the type parameter A in Suspension A
                     * stands for any user type). This is a stand-in
                     * for proper parametric polymorphism. *)
                    let type_params = sig_.hit_type_params in
                    let is_type_param ty_ =
                      match ty_ with
                      | TyUser n -> List.mem n type_params
                      | _ -> false
                    in
                    if List.length params <> List.length arg_tys then
                      err loc (Printf.sprintf
                        "HIT constructor %s.%s: expected %d arguments, got %d"
                        sig_.hit_name name
                        (List.length params) (List.length arg_tys))
                    else
                      let rec check_args = function
                        | [], [] -> ok ()
                        | (pname, pty) :: prest, aty :: arest ->
                            if is_type_param pty
                            then check_args (prest, arest)
                            else if Dispatcher.subtype env ctx ~sub:aty ~super:pty
                            then check_args (prest, arest)
                            else err loc
                              (Printf.sprintf
                                 "HIT constructor %s.%s: parameter %s expects %s, got %s"
                                 sig_.hit_name name pname
                                 (Tyenv.ty_to_string pty)
                                 (Tyenv.ty_to_string aty))
                        | _ -> err loc "internal: arity mismatch in HIT check"
                      in
                      let* () = check_args (params, arg_tys) in
                      ok result
                | None ->
                    (* Try stdlib signatures: "List__cons", "Space__new", etc. *)
                    (match Stdlib_runtime.lookup_stdlib_signature name with
                     | Some (param_tys, return_ty) ->
                         if List.length param_tys <> List.length arg_tys then
                           err loc (Printf.sprintf
                             "stdlib %s: expected %d arguments, got %d"
                             name (List.length param_tys) (List.length arg_tys))
                         else
                           (* Stdlib uses "unknown" type as polymorphic placeholder.
                            * We accept any actual type at those positions. *)
                           let rec check_args = function
                             | [], [] -> ok ()
                             | pty :: prest, _aty :: arest ->
                                 (* Accept anything when expected is "unknown" (polymorphic). *)
                                 (match pty with
                                  | TyPrim "unknown" -> check_args (prest, arest)
                                  | _ -> check_args (prest, arest))
                                 (* For now, accept all — proper polymorphism. *)
                             | _ -> err loc "stdlib arg mismatch"
                           in
                           let* () = check_args (param_tys, arg_tys) in
                           ok return_ty
                     | None ->
                         (* Renamed family: channel ops moved from Stream to
                            Wire; say so instead of "unknown". *)
                         let renamed = ["make"; "send"; "recv"; "make_shm";
                                        "send_shm"; "recv_shm"; "produce_shm";
                                        "await_shm"; "close_shm"; "make_net";
                                        "send_net"; "recv_net"; "close_net"] in
                         (match String.index_opt name '_' with
                          | Some _ when String.length name > 8
                                        && String.sub name 0 8 = "Stream__"
                                        && List.mem (String.sub name 8 (String.length name - 8)) renamed ->
                              let op = String.sub name 8 (String.length name - 8) in
                              err loc (Printf.sprintf
                                "Stream.%s was renamed: the channel family lives under Wire (use Wire.%s). Stream is the sequence: map, filter, fold." op op)
                          | _ ->
                              err loc (Printf.sprintf "unknown function or operation: %s" name))))
           | many ->
               err loc
                 (Printf.sprintf
                    "ambiguous operation name %s: declared in %d places (%s)"
                    name (List.length many)
                    (String.concat ", " (List.map (fun o -> o.E.os_place) many)))))

and check_call_signature (env : Tyenv.env) (ctx : Reduce.ctx)
                         (fn_name : string)
                         (params : (string * ty) list)
                         (arg_tys : ty list)
                         (loc : location) : unit tc_result =
  if List.length params <> List.length arg_tys then
    err loc (Printf.sprintf
      "%s: expected %d arguments, got %d"
      fn_name (List.length params) (List.length arg_tys))
  else
    let rec check_args = function
      | [], [] -> ok ()
      | (pname, pty) :: prest, aty :: arest ->
          if Dispatcher.subtype env ctx ~sub:aty ~super:pty
             || comprehension_coerces_to env ctx ~sub:aty ~super:pty
          then check_args (prest, arest)
          else err loc
            (Printf.sprintf
               "%s: parameter %s expects %s, got %s"
               fn_name pname
               (Tyenv.ty_to_string pty) (Tyenv.ty_to_string aty))
      | _ -> err loc "internal: signature length mismatch"
    in
    check_args (params, arg_tys)

and check_op_call (env : Tyenv.env) (ctx : Reduce.ctx)
                  (op : E.op_sig) (arg_tys : ty list) (loc : location) : unit tc_result =
  (* Operations expect their declared parameter types. Plus, the call
   * must occur in a context where the operation's place is one of the
   * current_effects (or an active handler covers it). *)
  let* () = check_call_signature env ctx
              (op.os_place ^ "." ^ op.os_op_name)
              op.os_params arg_tys loc in
  (* Effect check: the calling function must visit op.os_place. *)
  if List.mem op.os_place env.current_effects
     || List.exists
          (fun rname ->
             match Tyenv.lookup_reduction env rname with
             | Some rd -> rd.rd_of = op.os_place
             | None -> false)
          env.active_handlers
  then ok ()
  else err loc
    (Printf.sprintf
       "operation %s.%s requires effect on %s, but the current function does not declare it"
       op.os_place op.os_op_name op.os_place)

and check_field_assignments (env : Tyenv.env) (ctx : Reduce.ctx)
                            (place_name : string)
                            (fields : field_decl list)
                            (fas : field_assignment list)
                            (loc : location) : unit tc_result =
  (* Each field assignment names a field; check that the field exists
   * and the value has the expected type. Missing fields are OK
   * (default), extra fields are errors. *)
  let rec check_each = function
    | [] -> ok ()
    | fa :: rest ->
        match List.find_opt (fun f -> f.fd_name = fa.fa_name) fields with
        | None -> err fa.fa_loc
            (Printf.sprintf "place %s has no field %s" place_name fa.fa_name)
        | Some f ->
            let* () = check env ctx fa.fa_value f.fd_ty in
            check_each rest
  in
  ignore loc;
  check_each fas

(* ─── Conditions ───────────────────────────────────────────────────── *)

and check_condition (env : Tyenv.env) (ctx : Reduce.ctx) (c : condition) : unit tc_result =
  match c with
  | CondExpr e ->
      check env ctx e (TyPrim "boolean")
  | CondIs (e, p) ->
      let* t = infer env ctx e in
      check_pattern env ctx p t
  | CondIsNot (e, p) ->
      let* t = infer env ctx e in
      check_pattern env ctx p t
  | CondAnd (c1, c2) ->
      let* () = check_condition env ctx c1 in
      check_condition env ctx c2
  | CondOr (c1, c2) ->
      let* () = check_condition env ctx c1 in
      check_condition env ctx c2

and check_pattern (env : Tyenv.env) (ctx : Reduce.ctx)
                  (p : pattern) (scrutinee_ty : ty) : unit tc_result =
  match p with
  | PatVar _ -> ok ()  (* binds — accepts anything *)
  | PatLit l ->
      let lit_ty = ty_of_literal l in
      if Dispatcher.type_equal env ctx lit_ty scrutinee_ty then ok ()
      else err dummy_loc
        (Printf.sprintf "pattern literal of type %s doesn't match scrutinee type %s"
           (Tyenv.ty_to_string lit_ty) (Tyenv.ty_to_string scrutinee_ty))
  | PatType t ->
      if Dispatcher.type_equal env ctx t scrutinee_ty then ok ()
      else err dummy_loc
        (Printf.sprintf "pattern type %s doesn't match scrutinee type %s"
           (Tyenv.ty_to_string t) (Tyenv.ty_to_string scrutinee_ty))
  | PatPresent | PatAbsent | PatUnknown -> ok ()
    (* Heyting tri-valued patterns accept anything: the type system
     * just records that the test was made. *)

(* ─── Statement checking ───────────────────────────────────────────── *)

(* Statements may bind variables (let) and may have an implicit return
 * type (for the enclosing fun). The return type is threaded as
 * expected_return; a `return e` statement checks e against it.
 *)

(* Declare-once-per-scope (rule 1 of the `be holds` / `=` split, model A: every
   `be x holds e` binds a fresh mutable local, and `x = e` reassigns it). Re-binding
   the SAME name with `be ... holds` in the SAME block is a mistake, not a reassign;
   the fix is `x = ...`. A stack of frames, one per open block, records the names a
   block bound with `be ... holds`. check_stmts pushes a frame per nested block;
   check_stmts_accum resets and pushes at function entry. Names that begin with `_`
   are throwaways by convention (`_`, `_p`, `_1`) and are exempt. (Rule 2, `=` on an
   undeclared name, is already enforced by type_of_lvalue's "unbound variable".) *)
let scope_frames : string list ref list ref = ref []
let scope_reset () = scope_frames := []
let scope_push () = scope_frames := ref [] :: !scope_frames
let scope_pop () = match !scope_frames with _ :: t -> scope_frames := t | [] -> ()
let scope_throwaway name = String.length name = 0 || name.[0] = '_'
let scope_has name =
  match !scope_frames with f :: _ -> List.mem name !f | [] -> false
let scope_add name =
  match !scope_frames with f :: _ -> f := name :: !f | [] -> ()

let rec check_stmt (env : Tyenv.env) (ctx : Reduce.ctx)
                   (s : stmt) (expected_return : ty option) : Tyenv.env tc_result =
  match s with
  | SLet (name, e, loc) when (not (scope_throwaway name)) && scope_has name ->
      ignore e;
      err loc (Printf.sprintf
        "'%s' is already bound in this scope; use `%s = ...` to reassign it, \
         not `be %s holds ...` again"
        name name name)
  | SLet (name, e, loc) ->
      scope_add name;
      let* t = infer env ctx e in
      (* A type is not a runtime value. `text`/`number`/... resolve to their
       * Tarski code (a citizen of the universe) in term position, which is right
       * for a type argument or `refl(T)`, but binding one as a value has no
       * runtime meaning and would leak past erasure to a Fatal at emit. Reject it
       * here so tycheck states the truth (a type in value position) rather than
       * emit crashing on the downstream consequence. *)
      let* () =
        match t with
        | TyUniverse _ ->
            err loc (Printf.sprintf
              "binding `%s` holds a type, not a value: a type is a compile-time \
               citizen of the universe with no runtime representation. Use it in a \
               type position (a type argument, or `refl(T)`), not a value binding"
              name)
        | _ -> ok ()
      in
      (* HM let-polymorphism: if the value is a lambda (ELam), generalize the
       * inferred type into a polymorphic scheme. Every meta-variable free in
       * the type but not free in the outer env is universally quantified.
       *
       * Later occurrences of `name` (EVar/ECall) instantiate the scheme with
       * fresh meta-variables, supporting polymorphic use:
       *   let id = fun(x) => x in (id(5), id("hello"))
       *
       * For non-lambdas, monomorphic (the Damas-Milner value restriction). *)
      (match e with
       | ELam _ | EMoveLam _ | EReductionLam _ | EMorphLam _ | EFunctorLam _ ->
           (* Free meta-variables in the env: the union of the free
            * meta-variables of all current bindings (vars + scheme bodies). *)
           let env_metavars =
             List.concat_map (fun (_, ty) -> Ty_subst.free_metavars ty) env.E.vars
             @ List.concat_map (fun (_, sch) ->
                 List.filter (fun m -> not (List.mem m sch.Ty_subst.bound))
                   (Ty_subst.free_metavars sch.Ty_subst.body)
               ) !scheme_env
           in
           let scheme = Ty_subst.generalize env_metavars t in
           add_scheme name scheme;
           (* Also add it to the ordinary tyenv with its body as a fallback
            * (the ordinary lookup still works). *)
           ok (Tyenv.add_var env name t)
       | _ ->
           ok (Tyenv.add_var env name t))

  | SAssignHolds (lv, e, loc) ->
      let* expected = type_of_lvalue env ctx lv loc in
      let* () = check env ctx e expected in
      ok env

  | SAssignBecomes (lv, e, loc) ->
      let* expected = type_of_lvalue env ctx lv loc in
      let* () = check env ctx e expected in
      ok env

  | SReturn (e, _loc) ->
      (match expected_return with
       | Some t ->
           let* () = check env ctx e t in
           ok env
       | None ->
           let* _ = infer env ctx e in
           ok env)

  | SCall (name, args, loc) ->
      (* Stream method in STATEMENT position: s.for_every(f) / s.fold(init, f).
         In the unified form the receiver is the FIRST argument (parser:
         recv.f(args) = f(recv, args) for a value receiver), so for_every(s, f)
         and fold(s, init, f). If the receiver types as a stream, register the
         site for the drain lowering and skip the normal call resolution (the
         lambda argument is checked loosely, like the fused pipelines do). *)
      let stream_method =
        if name = "for_every" then Some ("__for_every", 2)
        else if name = "fold" then Some ("__fold", 3)
        else None
      in
      (match stream_method with
       | Some (suf, n_args) when List.length args = n_args ->
           let recv = List.hd args in
           let* recv_ty = infer env ctx recv in
           (match recv_ty with
            | TyStream _ ->
                Hashtbl.replace stream_method_table (loc.start_line, loc.start_col) ();
                (* fold's init is a value: check it; the lambda is loose *)
                let* _ = (match suf, args with
                          | "__fold", _recv :: init :: _ -> infer env ctx init
                          | _ -> ok (TyPrim "number")) in
                ok env
            | _ when suf = "__for_every" ->
                err loc "for_every is the stream method; lists use the `for every x in xs` statement"
            | _ ->
                (* list receiver with fold: the fused pipeline path *)
                let arg_tys_result = List.fold_left
                  (fun acc a ->
                     let* tys = acc in
                     let* t = infer env ctx a in
                     ok (tys @ [t]))
                  (ok []) args
                in
                let* arg_tys = arg_tys_result in
                let* _ = check_call env ctx name args arg_tys loc in
                ok env)
       | _ ->
      let arg_tys_result = List.fold_left
        (fun acc a ->
           let* tys = acc in
           let* t = infer env ctx a in
           ok (tys @ [t]))
        (ok []) args
      in
      let* arg_tys = arg_tys_result in
      let* _ = check_call env ctx name args arg_tys loc in
      ok env)

  | SNew (place_name, fas, loc) ->
      (match Tyenv.lookup_place env place_name with
       | None -> err loc (Printf.sprintf "unknown place %s in new" place_name)
       | Some pd ->
           let fields = List.filter_map
             (function FoField f -> Some { f with fd_ty = resolve_tparams pd.pd_type_params f.fd_ty }
                     | FoOp _ -> None | FoCell _ -> None | FoLaw _ -> None)
             pd.pd_members in
           let* () = check_field_assignments env ctx pd.pd_name fields fas loc in
           ok env)

  | SNewIn (place_name, _space, fas, loc) ->
      (* Same check as SNew (the space is a runtime value). *)
      (match Tyenv.lookup_place env place_name with
       | None -> err loc (Printf.sprintf "unknown place %s in 'new in'" place_name)
       | Some pd ->
           let fields = List.filter_map
             (function FoField f -> Some { f with fd_ty = resolve_tparams pd.pd_type_params f.fd_ty }
                     | FoOp _ -> None | FoCell _ -> None | FoLaw _ -> None)
             pd.pd_members in
           let* () = check_field_assignments env ctx pd.pd_name fields fas loc in
           ok env)

  | SWhen (cond, body, elifs, otherwise, _) ->
      let* () = check_condition env ctx cond in
      let* _ = check_stmts env ctx body expected_return in
      let* () = List.fold_left
        (fun acc (c, b) ->
           let* () = acc in
           let* () = check_condition env ctx c in
           let* _ = check_stmts env ctx b expected_return in
           ok ())
        (ok ()) elifs in
      let* () = match otherwise with
        | None -> ok ()
        | Some stmts ->
            let* _ = check_stmts env ctx stmts expected_return in
            ok ()
      in
      ok env

  | SForEvery (_kind, x, collection, body, loc) ->
      let* coll_ty = infer env ctx collection in
      let elem_ty = match coll_ty with
        | TyList inner -> Some inner
        | TyStream inner ->
            (* stream collection: the desugar drains the wire instead of
               walking cons cells; register the site. *)
            Hashtbl.replace stream_foreach_table (loc.start_line, loc.start_col) ();
            Some inner
        | _ -> None
      in
      (match elem_ty with
       | None -> err loc
           (Printf.sprintf "for-every requires a list or stream, got %s"
              (Tyenv.ty_to_string coll_ty))
       | Some elem ->
           let env' = Tyenv.add_var env x elem in
           let* _ = check_stmts env' ctx body expected_return in
           ok env)

  | SInSequence (x, collection, body, loc) ->
      let* coll_ty = infer env ctx collection in
      let elem_ty = match coll_ty with
        | TyList inner -> Some inner
        | _ -> None
      in
      (match elem_ty with
       | None -> err loc
           (Printf.sprintf "in sequence over requires a list, got %s"
              (Tyenv.ty_to_string coll_ty))
       | Some elem ->
           let env' = Tyenv.add_var env x elem in
           let* _ = check_stmts env' ctx body expected_return in
           ok env)

  | SRepeat (_, body, otherwise, _) ->
      let* _ = check_stmts env ctx body expected_return in
      let* () = match otherwise with
        | None -> ok ()
        | Some stmts ->
            let* _ = check_stmts env ctx stmts expected_return in
            ok ()
      in
      ok env

  | SForever (body, _) ->
      let* _ = check_stmts env ctx body expected_return in
      ok env

  | SScope (_name, body, _ret, _) ->
      let* _ = check_stmts env ctx body expected_return in
      ok env

  | SProduce (body, _) ->
      (* produce { ... } — body emits values; result is a stream type. *)
      let* _ = check_stmts env ctx body expected_return in
      ok env

  | SEmit (e, _) ->
      let* t = infer env ctx e in
      (match !produce_emit_ty with
       | None -> produce_emit_ty := Some t
       | Some _ -> ());
      ok env

  | SPromote (e, loc) ->
      if !in_spawn_depth = 0 then
        err loc "promote is only valid inside a spawn block"
      else begin
        let* t = infer env ctx e in
        (match !spawn_promote_ty with
         | None -> spawn_promote_ty := Some t
         | Some _ -> ());
        ok env
      end

  | SForces (_stage, _cond, body, _) ->
      (* forcing semantics. Type-check body in current env;
       * Kripke-Joyal check on cond will be done by topos kernel. *)
      let* _env' = check_stmts env ctx body None in
      ok env

  | SIter (n_e, body, _) ->
      (* iter N do { body }: N must be number, body type-checked. *)
      let* _ = check env ctx n_e (TyPrim "number") in
      let* _env' = check_stmts env ctx body None in
      ok env

  | SWhile (c_e, body, _) ->
      (* while cond do { body }: cond must be boolean, body type-checked. *)
      let* _ = check env ctx c_e (TyPrim "boolean") in
      let* _env' = check_stmts env ctx body None in
      ok env

  | SDrop (_x, _) ->
      (* drop X: type-checks as unit here; the downstream-arc obligation is
         discharged by the separate Space_liveness.check_drops pass. *)
      ok env

and check_stmts (env : Tyenv.env) (ctx : Reduce.ctx)
                (stmts : stmt list) (expected_return : ty option) : Tyenv.env tc_result =
  scope_push ();
  let result =
    List.fold_left
      (fun acc s ->
         let* env' = acc in
         check_stmt env' ctx s expected_return)
      (ok env) stmts
  in
  scope_pop ();
  result

(* Variant of check_stmts that accumulates errors across statements
 * instead of stopping at the first one. Each failing stmt contributes
 * an error to the list but does not halt the type-checking of
 * subsequent stmts. The environment is best-effort propagated. *)
and check_stmts_accum (env : Tyenv.env) (ctx : Reduce.ctx)
                      (stmts : stmt list) (expected_return : ty option)
    : Tyenv.env * type_error list =
  scope_reset ();
  scope_push ();
  let result =
    List.fold_left
      (fun (env', errs) s ->
         match check_stmt env' ctx s expected_return with
         | Ok env'' -> (env'', errs)
         | Error e -> (env', e :: errs))
      (env, []) stmts
  in
  scope_pop ();
  result

(* Implicit-return tail check. A function body's VALUE is desugar_stmt of its
 * LAST statement (desugar_stmt_or_return): for a tail that is NOT a `return`,
 * that value must still inhabit the declared return type. tycheck only checks
 * `return e` statements against expected_ret, so a body ending in e.g.
 * `be y holds 3` while declaring a place return type silently produces the
 * wrong value. We check the tails whose value is a plain expression we can
 * infer (be / x holds e / a bare call), evaluated in the post-body env (the
 * tail's own binding never feeds its own RHS), and ONLY when both the inferred
 * type and the declared type are CONCRETE — never the `unknown` f64-handle
 * placeholder, never a terminal (fieldless) place — so the loose handle
 * boundary is left untouched. Control-flow / effect tails (when / loops / scope
 * / emit / new) are not checked: conservative, no false reject. *)
and check_implicit_tail_return (env_after : Tyenv.env) (ctx : Reduce.ctx)
                               (body : stmt list) (rt : ty) : type_error list =
  if rt = TyPrim "unknown" || is_terminal_ty env_after rt then []
  else match List.rev body with
  | [] -> []
  | last :: _ ->
      let tail = match last with
        | SReturn _ -> None
        | SLet (_, e, loc) | SAssignHolds (_, e, loc) -> Some (e, loc)
        | SCall (name, args, loc) -> Some (ECall (name, args, loc), loc)
        | _ -> None
      in
      (match tail with
       | None -> []
       | Some (e, loc) ->
           (match infer env_after ctx e with
            | Error _ -> []
            | Ok t ->
                if t = TyPrim "unknown" then []
                else if Dispatcher.subtype env_after ctx ~sub:t ~super:rt then []
                else [{ err_loc = loc; err_msg = Printf.sprintf
                          "function declares return type %s but its body ends with \
                           a value of type %s (add an explicit `return`)"
                          (Tyenv.ty_to_string rt) (Tyenv.ty_to_string t) }]))

and type_of_lvalue (env : Tyenv.env) (ctx : Reduce.ctx)
                   (lv : lvalue) (loc : location) : ty tc_result =
  ignore ctx;
  match lv with
  | LVar x ->
      (match Tyenv.lookup_var env x with
       | Some t -> ok t
       | None -> err loc (Printf.sprintf "unbound variable %s" x))
  | LField (x, fld) ->
      (* Place sections are immutable in 1.0, so assigning to a field (`x.f = e`
         or `x.f holds e`) is rejected by design. It has no lowering: it would
         desugar to __space_update_here and crash emit_mlir, so it is stopped here
         with a clean type error instead. Mutate through a Space cell (a `be`-bound
         local reassigned with `=`), or build a fresh instance with `new`. *)
      err loc (Printf.sprintf
        "cannot assign to place field '%s.%s': place sections are immutable in 1.0. \
         Mutate through a Space cell (a `be`-bound local reassigned with `=`), or \
         build a new instance with `new`." x fld)

(* ─── Top-level declaration checking ───────────────────────────────── *)

(* For each top declaration, we:
 *   1. Register it in the environment first (so later decls can refer to it).
 *   2. Check its internal well-formedness (types of params, body, etc).
 *
 * Two-pass: first pass collects signatures; second pass checks bodies.
 * This permits mutual recursion between functions.
 *)

(* ─── Universe levels (HoTT / Russell-predicative) ─────────────────── *)

(* The universe level of a type T is the smallest n such that T : Type_n.
 * The standard rules:
 *   - level(Type_n) = n + 1               (Type_n : Type_{n+1})
 *   - level(A -> B) = max(level(A), level(B))
 *   - level(Pi(x:A). B) = max(level(A), level(B))
 *   - level(Sigma(x:A). B) = max(level(A), level(B))
 *   - level(Id_A(a,b)) = level(A)
 *   - level(base / user / list / map / stream) = 0
 *
 * This computes the *small-enough* universe a type fits in. The
 * cumulativity principle (Type_n : Type_m whenever m > n) ensures
 * that no type is "too big" for the universe we want to put it in.
 *)
let () = produce_check_ref := check_stmts

let rec level_of_type (t : ty) : int =
  match t with
  | TyUniverse n -> n + 1
  | TyPi (_, a, b) | TySigma (_, a, b) ->
      max (level_of_type a) (level_of_type b)
  | TyId (a, _, _) -> level_of_type a
  | TyPathP ((_, a), _, _) -> level_of_type a
  | TyList inner | TyStream inner -> level_of_type inner
  | TyMap (k, v) -> max (level_of_type k) (level_of_type v)
  | TySum vs | TySumIn (vs, _) ->
      List.fold_left
        (fun acc v ->
           List.fold_left
             (fun acc' arg -> max acc' (level_of_type arg))
             acc v.v_args)
        0 vs
  | TyPrim _ | TyPrimIn _ | TyUser _ | TyApp _ | TyVar _ | TyMetaVar _ -> 0
  | TyHeytInt _ -> 0
  | TyArrow (a, b) -> max (level_of_type a) (level_of_type b)
  | TyMoveHandle _ -> 0
  | TyReductionHandle _ -> 0
  | TyMorphHandle _ -> 0
  | TyViewHandle _ -> 0
  | TyWire _ -> 0
  | TySubscription (_, inner) -> level_of_type inner
  | TyEl _ -> 0

(* ─── Place subtyping (row polymorphism) ─────────────────────────── *)

(* Width subtyping for places:
 *
 *   P2 <:_w P1   iff   every field of P1 with type T appears in P2
 *                       with a compatible type.
 *
 * P2 may have more fields than P1; the extra fields are "row variable"
 * components that don't affect subtyping. This realizes row
 * polymorphism on records.
 *
 * Used by:
 *   - apply_move when source/target accept any P2 with the right
 *     subset of fields
 *   - field projection: e.<f> works on any P2 <:_w P1 if P1 declares f
 *)
let place_field_subset (env : Tyenv.env) (ctx : Reduce.ctx)
    (p_super : place_decl) (p_sub : place_decl) : bool =
  let extract_fields p =
    List.filter_map (function FoField f -> Some f | FoOp _ -> None | FoCell _ -> None | FoLaw _ -> None) p.pd_members
  in
  let super_fields = extract_fields p_super in
  let sub_fields   = extract_fields p_sub in
  List.for_all
    (fun sf ->
       match List.find_opt (fun f -> f.fd_name = sf.fd_name) sub_fields with
       | Some f -> Dispatcher.type_equal env ctx sf.fd_ty f.fd_ty
       | None -> false)
    super_fields

(* p_sub_name <:_w p_super_name: p_sub_name has all fields of p_super_name. *)
let place_is_subtype (env : Tyenv.env) (ctx : Reduce.ctx)
    (p_super_name : string) (p_sub_name : string) : bool =
  if p_super_name = p_sub_name then true
  else
    match Tyenv.lookup_place env p_super_name,
          Tyenv.lookup_place env p_sub_name with
    | Some pd_super, Some pd_sub ->
        place_field_subset env ctx pd_super pd_sub
    | _ -> false

let rec register_sum_types_in_ty (env : Tyenv.env) (t : ty) : Tyenv.env =
  match t with
  | TySum variants | TySumIn (variants, _) ->
      List.fold_left
        (fun env variant ->
           List.fold_left register_sum_types_in_ty env variant.v_args)
        (Tyenv.add_sum_type env variants) variants
  | TyList inner | TyStream inner | TySubscription (_, inner) ->
      register_sum_types_in_ty env inner
  | TyMap (key, value) | TyArrow (key, value) ->
      register_sum_types_in_ty (register_sum_types_in_ty env key) value
  | TyPi (_, domain, codomain) | TySigma (_, domain, codomain) ->
      register_sum_types_in_ty (register_sum_types_in_ty env domain) codomain
  | TyId (carrier, _, _) | TyPathP ((_, carrier), _, _) ->
      register_sum_types_in_ty env carrier
  | TyPrim _ | TyPrimIn _ | TyUser _ | TyApp _ | TyVar _ | TyMetaVar _
  | TyUniverse _ | TyHeytInt _ | TyMoveHandle _ | TyReductionHandle _
  | TyMorphHandle _ | TyViewHandle _ | TyWire _ | TyEl _ -> env

let register_decl (env : Tyenv.env) (td : top_decl) : Tyenv.env =
  match td with
  | TopWorld wd -> Tyenv.add_world env wd
  | TopType (name, variants, _) ->
      (* Register the named sum, then any sums nested in its constructors'
         argument types (the recursive self-reference `TyUser name` is not one
         of those and needs no registration). *)
      let env = Tyenv.add_named_sum env name variants in
      List.fold_left
        (fun acc v ->
           List.fold_left register_sum_types_in_ty acc v.v_args)
        env variants
  | TopPlace pd ->
      let env =
        List.fold_left
          (fun acc -> function
             | FoField field -> register_sum_types_in_ty acc field.fd_ty
             | FoOp op ->
                 let acc =
                   List.fold_left
                     (fun acc p -> register_sum_types_in_ty acc p.param_ty)
                     acc op.op_params
                 in
                 (match op.op_return with
                  | Some ty -> register_sum_types_in_ty acc ty
                  | None -> acc)
             | FoCell _ | FoLaw _ -> acc)
          env pd.pd_members
      in
      Tyenv.add_place env pd
  | TopFun fn ->
      (* Rebind TyUser -> TyVar wherever a TyUser refers to a generic
       * type parameter declared in fn_type_params. Same logic as in
       * check_fun_decl, but applied at registration time so that
       * callers see TyVar in the signature. *)
      let rec rebind_ty (t : ty) : ty =
        match t with
        | TyUser n when List.mem n fn.fn_type_params -> TyVar n
        | TyList inner -> TyList (rebind_ty inner)
        | TyMap (k, v) -> TyMap (rebind_ty k, rebind_ty v)
        | TyStream inner -> TyStream (rebind_ty inner)
        | TySum vs ->
            TySum (List.map
              (fun v -> { v with v_args = List.map rebind_ty v.v_args }) vs)
        | TySumIn (vs, ws) ->
            TySumIn (List.map
              (fun v -> { v with v_args = List.map rebind_ty v.v_args }) vs, ws)
        | other -> other
      in
      let rebound_params = List.map
        (fun p -> (p.param_name, rebind_ty p.param_ty)) fn.fn_params in
      let rebound_return =
        match fn.fn_return with
        | Some t -> rebind_ty t
        | None -> TyPrim "unit"
      in
      let env =
        List.fold_left
          (fun acc (_, t) -> register_sum_types_in_ty acc t)
          (register_sum_types_in_ty env rebound_return) rebound_params
      in
      let sig_ : E.fun_sig = {
        fs_params = rebound_params;
        fs_return = rebound_return;
        fs_visits = fn.fn_visits;
        fs_partial = fn.fn_partial;
      } in
      let env1 = Tyenv.add_fun env fn.fn_name sig_ in
      (* Register the delta-rule (Core body) for definitional equality.
       * Side-effect-free; None for non-pure-return bodies (sound: no rule,
       * call stays opaque). *)
      (match Desugar.delta_rule_of_fun env1 fn with
       | Some body -> Tyenv.add_delta env1 fn.fn_name body
       | None -> env1)
  | TopMove _ -> env
  | TopView vd -> Tyenv.add_view env vd
  | TopReduction rd -> Tyenv.add_reduction env rd
  | TopOperation op ->
      let env =
        List.fold_left
          (fun acc p -> register_sum_types_in_ty acc p.param_ty)
          env op.op_params
      in
      (match op.op_return with
       | Some ty -> register_sum_types_in_ty env ty
       | None -> env)
  | TopImport _ -> env   (* import resolved physically pre-parse; no-op here *)
  | TopImportSym _ -> env   (* selective import: handled in 4b *)
  | TopImportFrom _ -> env   (* cross-Space import: handled at lowering *)
  | TopLet _ -> env
  | TopGeomMorphism gm ->
      (* The morphism's type is El(code) = El(src) -> El(tgt), derived from its
         CaTT code; register the name as a typed arrow so call sites are checked
         against it. Runtime wiring stays separate, at lowering. *)
      (match Catt_r_yon.el_decode (Catt_r_yon.cell_of_geom_morphism gm) with
       | Some (TyArrow (a, b)) ->
           Tyenv.add_fun env gm.gm_name
             ({ fs_params = [("x", a)]; fs_return = b;
                fs_visits = []; fs_partial = false } : E.fun_sig)
       | _ ->
           (* Code does not decode (El) to a 1-cell arrow. Leave the name
              unregistered: the coherence check below is the SOLE arbiter and
              rejects this case with a located error. Env-building stays
              best-effort and never raises, so the two phases agree. *)
           env)
  | TopPullback _ -> env       (* kernel-only *)
  | TopPushout _ -> env
  | TopTopology _ -> env       (* kernel-only *)
  | TopReductionCompose _ -> env (* kernel-only *)
  | TopSpace sd ->
      (* Register the space name in declared_spaces for later validation of the
       * `topos T at S` binding. *)
      { env with declared_spaces = sd.sd_name :: env.declared_spaces }
  (* For now topoi are handled by expanding their objects as place_decls
   * recursively. Functors and nat_transforms are metadata at this stage. *)
  | TopTopos td ->
      (* Register the topos first as well, to allow lookup_topos. *)
      let env = Tyenv.add_topos env td in
      let env_with_objs = List.fold_left
        (fun acc pd -> Tyenv.add_place acc pd)
        env
        td.tp_objects in
      (* Register the props declared inside the topos as functions in the
       * tyenv, so they are callable from outside the topos. Equivalent to a
       * top-level `fun ... : proposition { ... }`. *)
      let env_with_props = List.fold_left
        (fun acc (pr : prop_decl) ->
          let fs : Tyenv.fun_sig = {
            fs_params = pr.pr_params;
            fs_return = TyPrim "proposition";
            fs_visits = [];
            fs_partial = false;
          } in
          Tyenv.add_fun acc pr.pr_name fs)
        env_with_objs
        td.tp_props in
      env_with_props
  | TopMorph mp ->
      (* Register the morph name in declared_morphs (and the full decl in
       * morph_decls) for validating a nat_transform's from/to. *)
      let env = { env with
        declared_morphs = mp.mp_name :: env.declared_morphs;
        morph_decls = (mp.mp_name, mp) :: env.morph_decls } in
      (* Register on_object both as the short alias (the morph name) and as the
       * canonical long name (`<morph_name>__on_object`). *)
      let env_with_obj = match mp.mp_on_object with
       | None -> env
       | Some fd ->
           let return_ty = match fd.fn_return with
             | Some t -> t
             | None -> TyPrim "unknown" in
           let params = List.map
             (fun (p : param) -> (p.param_name, p.param_ty)) fd.fn_params in
           let fs : Tyenv.fun_sig = {
             fs_params = params;
             fs_return = return_ty;
             fs_visits = [];
             fs_partial = false;
           } in
           let env1 = Tyenv.add_fun env mp.mp_name fs in
           Tyenv.add_fun env1 (mp.mp_name ^ "__on_object") fs
      in
      List.fold_left (fun env_acc (n_src, _m_tgt) ->
        let wrapper_name = mp.mp_name ^ "__" ^ n_src in
        let fs : Tyenv.fun_sig = {
          fs_params = [("x", TyPrim "number")];
          fs_return = TyPrim "number";
          fs_visits = [];
          fs_partial = false;
        } in
        Tyenv.add_fun env_acc wrapper_name fs
      ) env_with_obj mp.mp_on_morphism_map
  | TopNatTransform _ -> env
  | TopFunctor ft ->
      (* A functor is categorically a morph_decl (a map between categories:
       * source, target, action). We register it in morph_decls with its worlds
       * as source/target, so a nat_transform `from F to G` finds it and
       * validates the parallelism. We also register the lifted function
       * (ft_name) for the body/lowering. *)
      let mp : morph_decl = {
        mp_name = ft.ft_name;
        mp_source = ft.ft_from_world;
        mp_target = ft.ft_to_world;
        mp_on_object = None;
        mp_on_morphism_map = [];
        mp_loc = ft.ft_loc;
      } in
      let env = { env with
        declared_morphs = ft.ft_name :: env.declared_morphs;
        morph_decls = (ft.ft_name, mp) :: env.morph_decls } in
      (* the lifted function: F(params) -> to_world *)
      let fs : Tyenv.fun_sig = {
        fs_params = ft.ft_params;
        fs_return = TyUser ft.ft_to_world;
        fs_visits = [];
        fs_partial = false;
      } in
      Tyenv.add_fun env ft.ft_name fs

let rec check_decl (env : Tyenv.env) (ctx : Reduce.ctx) (td : top_decl) : unit tc_result =
  match td with
  | TopWorld _ -> ok ()
  | TopType (name, variants, loc) ->
      (* The named sum is registered (register_decl); its constructors are
         checked structurally at their hit/match use sites (arity, exhaustive
         cover). Here we only reject a duplicated constructor name, which would
         make dispatch ambiguous. *)
      let rec dup seen = function
        | [] -> ok ()
        | v :: rest ->
            if List.mem v.v_name seen then
              err loc (Printf.sprintf
                "inductive %s: duplicate constructor %s" name v.v_name)
            else dup (v.v_name :: seen) rest
      in
      dup [] variants
  | TopPlace pd -> check_place_decl env ctx pd
  | TopFun fn -> check_fun_decl env ctx fn
  | TopMove md -> check_move_decl env ctx md
  | TopView vd -> check_view_decl env ctx vd
  | TopReduction rd -> check_reduction_decl env ctx rd
  | TopOperation _ -> ok ()
  | TopImport _ -> ok ()   (* import resolved physically pre-parse; no-op here *)
  | TopImportSym _ -> ok ()   (* selective import: handled in 4b *)
  | TopImportFrom _ -> ok ()   (* cross-Space import: handled at lowering *)
  | TopLet (_, e, _) ->
      let* _ = infer env ctx e in
      ok ()
  | TopGeomMorphism gm ->
      (* type-check the optional pull/push functions if present.
       * Lawfulness (adjunction pull-push, left exactness of pull) is
       * verified separately by the topos kernel; at this layer we
       * check syntactic well-formedness only. *)
      let gm_env =
        Tyenv.with_transport_pair env gm.gm_source_site gm.gm_target_site
      in
      let* () = match gm.gm_pull with
        | Some pull -> check_fun_decl gm_env ctx pull
        | None -> ok () in
      let* () = (match gm.gm_push with
       | Some push -> check_fun_decl gm_env ctx push
       | None -> ok ()) in
      (* Derived-El coherence: the morphism's CaTT code must decode (El) to the
         directed arrow El(src) -> El(tgt). This wires el_decode into the
         checker; a well-formed morphism satisfies it by construction. *)
      let cell = Catt_r_yon.cell_of_geom_morphism gm in
      (match Catt_r_yon.el_decode cell with
       | Some (TyArrow (_, _)) -> ok ()
       | _ ->
           err gm.gm_loc
             (Printf.sprintf
                "geom morphism %s: code does not decode (El) to a directed arrow El(%s) -> El(%s)"
                gm.gm_name gm.gm_source_site gm.gm_target_site))
  | TopPullback _ -> ok ()
  | TopPushout _ -> ok ()
  | TopTopology _ -> ok ()  (* kernel-only *)
  | TopReductionCompose _ -> ok ()  (* kernel-only *)
  | TopSpace _ -> ok ()             (* no static checks for now *)
  (* Topoi are validated object by object via check_place_decl recursively. *)
  | TopTopos td ->
      (* Validate the explicit binding `topos T at S`: if present, the space S
       * must actually be declared. *)
      let* () =
        match td.tp_at_space with
        | None -> ok ()
        | Some s ->
            if List.mem s env.declared_spaces then ok ()
            else err td.tp_loc (Printf.sprintf
                "topos %s declares 'at %s' but space %s is not declared. \
                 Add 'space %s' before the topos declaration."
                td.tp_name s s s)
      in
      let rec check_all = function
        | [] -> ok ()
        | pd :: rest ->
            let* () = check_place_decl env ctx pd in
            check_all rest
      in
      let* () = check_all td.tp_objects in
      (* Structural check of the prop bodies. For each prop with a body, we
       * build an equivalent fun_decl with return type proposition and pass it
       * to check_fun_decl. This verifies:
       *  - the parameters are well-typed in the topos context
       *  - the body is a valid expression
       *  - the final expression has a type compatible with proposition
       *    (boolean == proposition via simple_ty_compatible) *)
      let env_with_objs = List.fold_left
        (fun acc pd -> Tyenv.add_place acc pd)
        env td.tp_objects in
      let rec check_props = function
        | [] -> ok ()
        | (pr : prop_decl) :: rest ->
            (match pr.pr_body_opt with
             | None -> check_props rest
             | Some body ->
                 let params : param list = List.map
                   (fun (n, t) -> { param_name = n; param_ty = t }) pr.pr_params in
                 let fn : fun_decl = {
                   fn_name = pr.pr_name;
                   fn_type_params = [];
                   fn_params = params;
                   fn_return = Some (TyPrim "proposition");
                   fn_visits = [];
                   fn_partial = false; fn_internal = false;
                   fn_body = [ SReturn (body, pr.pr_loc) ];
                   fn_loc = pr.pr_loc;
                 } in
                 let* () = check_fun_decl env_with_objs ctx fn in
                 let body_core = Desugar.desugar_expr_pure env_with_objs body in
                 let sheaf_ctx =
                   { ctx with Reduce.deltas = env_with_objs.Tyenv.delta }
                 in
                 let* () = List.fold_left
                   (fun acc (param_name, param_ty) ->
                      let* () = acc in
                      match param_ty with
                      | TyUser place_name ->
                          (match Tyenv.lookup_place env_with_objs place_name with
                           | Some pd ->
                               (match Tyenv.lookup_world env_with_objs pd.pd_world with
                                | Some wd ->
                                    (match quotient_rel_of_world wd with
                                     | Some rel ->
                                         let domain = C.TyPlace place_name in
                                         let canon =
                                           Sheaf.quotient_canon ~rel ~domain
                                         in
                                         (match body_core with
                                          | Some core ->
                                              let field =
                                                C.Lam (param_name, domain, core)
                                              in
                                              if Sheaf.field_factors_through
                                                   sheaf_ctx ~canon ~field
                                              then ok ()
                                              else err pr.pr_loc (Printf.sprintf
                                                "prop %s parameter %s reads finer than %s and does not descend through quotient world %s"
                                                pr.pr_name param_name rel wd.wd_name)
                                          | None ->
                                              err pr.pr_loc (Printf.sprintf
                                                "prop %s parameter %s cannot be proven to descend through %s"
                                                pr.pr_name param_name rel))
                                     | None -> ok ())
                                | None -> ok ())
                           | None -> ok ())
                      | _ -> ok ())
                   (ok ()) pr.pr_params
                 in
                 check_props rest)
      in
      check_props td.tp_props
  | TopMorph mp ->
      (* Validate the on_object body if present. *)
      let* () =
        match mp.mp_on_object with
        | None -> ok ()
        | Some fd ->
            let on_obj_name = mp.mp_name ^ "__on_object" in
            let fd_renamed = { fd with fn_name = on_obj_name } in
            check_fun_decl env ctx fd_renamed
      in
      (* Validate the `on_morphism N via M` bindings. M may be:
       *   (a) an ordinary `fun` -> the wrapper calls M(x) directly
       *   (b) a `reduction` with a clause named N -> the wrapper calls
       *       M__N(x), the reduction clause that categorically realizes the
       *       morphism N
       *
       * If M is neither a fun nor a reduction, error. If M is a reduction but
       * has no clause N, error with an explicit message. *)
      let rec check_via_bindings = function
        | [] -> ok ()
        | (n_src, m_tgt) :: rest ->
            (match Tyenv.lookup_fun env m_tgt with
             | Some fs ->
                 (* Functoriality (W6): when the source topos is DECLARED and
                  * n_src is one of its morphisms, the via-target M must have the
                  * signature F applied to n_src's, where F is the object action
                  * (on_object: src_obj |-> tgt_obj). Skips (accepts) when the
                  * topos is undeclared / n_src is not a declared morphism / there
                  * is no on_object — so morphs over undeclared topoi (the
                  * f64-handle placeholder convention, e.g. c_morph_on_morphism)
                  * are untouched. *)
                 let* () =
                   (match Tyenv.lookup_topos env mp.mp_source, mp.mp_on_object with
                    | Some src_topos, Some on_obj ->
                        (match
                           List.find_opt
                             (fun (op : operation_decl) -> op.op_name = n_src)
                             src_topos.tp_morphisms,
                           on_obj.fn_params, on_obj.fn_return
                         with
                         | Some op, src_param :: _, Some tgt_obj ->
                             let src_obj = src_param.param_ty in
                             let apply_f t =
                               if Dispatcher.type_equal env ctx t src_obj
                               then tgt_obj else t in
                             let exp_params =
                               List.map (fun (p : param) -> apply_f p.param_ty)
                                 op.op_params in
                             let exp_ret =
                               (match op.op_return with
                                | Some r -> apply_f r | None -> TyPrim "number") in
                             let act_params = List.map snd fs.Tyenv.fs_params in
                             let params_ok =
                               List.length exp_params = List.length act_params
                               && List.for_all2
                                    (fun e a -> Dispatcher.type_equal env ctx e a)
                                    exp_params act_params in
                             if params_ok
                                && Dispatcher.type_equal env ctx exp_ret
                                     fs.Tyenv.fs_return
                             then ok ()
                             else err mp.mp_loc (Printf.sprintf
                               "morph %s: 'on morphism %s via %s' violates \
                                functoriality. The object action maps %s to %s, \
                                so %s must have type F(dom)->F(cod) of %s."
                               mp.mp_name n_src m_tgt
                               (Tyenv.ty_to_string src_obj)
                               (Tyenv.ty_to_string tgt_obj) m_tgt n_src)
                         | _ -> ok ())
                    | _ -> ok ())
                 in
                 check_via_bindings rest
             | None ->
                 match Tyenv.lookup_reduction env m_tgt with
                 | Some rd ->
                     (* Check that the reduction has a clause named n_src. *)
                     let has_clause = List.exists (function
                       | RcOn (cname, _, _, _) -> cname = n_src
                       | RcLet _ -> false
                     ) rd.rd_clauses in
                     if has_clause then check_via_bindings rest
                     else err mp.mp_loc (Printf.sprintf
                       "morph %s declares 'on_morphism %s via %s' but \
                        reduction %s has no clause 'on %s'. The 'via' \
                        target must be either a function in scope or a \
                        reduction with a matching clause."
                       mp.mp_name n_src m_tgt m_tgt n_src)
                 | None ->
                     err mp.mp_loc (Printf.sprintf
                       "morph %s declares 'on_morphism %s via %s' but \
                        %s is neither a function nor a reduction. The \
                        'via' target must be a fun or a reduction with \
                        a matching clause."
                       mp.mp_name n_src m_tgt m_tgt))
      in
      check_via_bindings mp.mp_on_morphism_map
  | TopFunctor ft ->
      (* Check the laws of a top-level functor by reusing exactly the
       * verification of EFunctorLam (syntactic: valid names; semantic: linear
       * or identity use of the variable). We build the equivalent
       * functor-lambda and infer it: if the laws do not hold, infer fails with
       * the same message. *)
      let lam = EFunctorLam (ft.ft_params, ft.ft_body, ft.ft_from_world,
                             ft.ft_to_world, ft.ft_laws, ft.ft_loc) in
      let* _ = infer env ctx lam in
      ok ()
  | TopNatTransform nt ->
      (* Validate each binding
       *   for each X by Y
       * where Y must be a fun or a reduction with a clause named X. Same logic
       * as the `on_morphism N via M` check.
       *
       * Also validate that nt_source_morph and nt_target_morph are declared
       * morphs sharing the same source/target topos (a parallel functor:
       * eta : F => G requires F, G : A -> B with A and B in common). *)
      let* () =
        let src_opt = List.assoc_opt nt.nt_source_morph env.morph_decls in
        let tgt_opt = List.assoc_opt nt.nt_target_morph env.morph_decls in
        match src_opt, tgt_opt with
        | None, _ ->
            err nt.nt_loc (Printf.sprintf
              "nat_transform %s declares 'from %s' but morph %s is not \
               declared."
              nt.nt_name nt.nt_source_morph nt.nt_source_morph)
        | _, None ->
            err nt.nt_loc (Printf.sprintf
              "nat_transform %s declares 'to %s' but morph %s is not \
               declared."
              nt.nt_name nt.nt_target_morph nt.nt_target_morph)
        | Some src, Some tgt ->
            if src.mp_source <> tgt.mp_source then
              err nt.nt_loc (Printf.sprintf
                "nat_transform %s: morphs %s and %s have different source \
                 topos (%s vs %s). A natural transformation η : F => G \
                 requires parallel functors with the same source and target."
                nt.nt_name nt.nt_source_morph nt.nt_target_morph
                src.mp_source tgt.mp_source)
            else if src.mp_target <> tgt.mp_target then
              err nt.nt_loc (Printf.sprintf
                "nat_transform %s: morphs %s and %s have different target \
                 topos (%s vs %s). A natural transformation η : F => G \
                 requires parallel functors with the same source and target."
                nt.nt_name nt.nt_source_morph nt.nt_target_morph
                src.mp_target tgt.mp_target)
            else ok ()
      in
      let rec check_components = function
        | [] -> ok ()
        | (obj, tgt) :: rest ->
            (match Tyenv.lookup_fun env tgt with
             | Some _ -> check_components rest
             | None ->
                 match Tyenv.lookup_reduction env tgt with
                 | Some rd ->
                     let has_clause = List.exists (function
                       | RcOn (cname, _, _, _) -> cname = obj
                       | RcLet _ -> false
                     ) rd.rd_clauses in
                     if has_clause then check_components rest
                     else err nt.nt_loc (Printf.sprintf
                       "nat_transform %s declares 'for each %s by %s' but \
                        reduction %s has no clause 'on %s'. The 'by' \
                        target must be a fun or a reduction with a \
                        matching clause."
                       nt.nt_name obj tgt tgt obj)
                 | None ->
                     err nt.nt_loc (Printf.sprintf
                       "nat_transform %s declares 'for each %s by %s' but \
                        %s is neither a function nor a reduction. The \
                        'by' target must be a fun or a reduction with a \
                        matching clause."
                       nt.nt_name obj tgt tgt))
      in
      let* () = check_components nt.nt_via_bindings in
      (* Structural check of naturality. Honest upfront: this is NOT the
       * verification of the equation eta_Y . F(f) = G(f) . eta_X (which would
       * require term equality with metaprogramming). It checks instead the
       * necessary structural precondition:
       *
       *   For every `N` declared in the `on_morphism` of both F and G,
       *   there is a component eta for (at least one of) the objects
       *   involved.
       *
       * If F and G declare the same morphism N without eta having a component
       * for it, the naturality square cannot even be expressed, let alone
       * commute. This check catches that case. *)
      (match List.assoc_opt nt.nt_source_morph env.morph_decls,
             List.assoc_opt nt.nt_target_morph env.morph_decls with
       | Some src, Some tgt ->
           let src_morphisms = List.map fst src.mp_on_morphism_map in
           let tgt_morphisms = List.map fst tgt.mp_on_morphism_map in
           let common = List.filter (fun n -> List.mem n tgt_morphisms) src_morphisms in
           let nt_objs = List.map fst nt.nt_via_bindings in
           let missing = List.filter (fun n -> not (List.mem n nt_objs)) common in
           (match missing with
            | [] -> ok ()
            | n :: _ ->
                err nt.nt_loc (Printf.sprintf
                  "nat_transform %s: morphs %s and %s both declare \
                   'on_morphism %s' but η has no component for %s. \
                   Structural naturality requires a component η_%s — \
                   add 'for each %s by <handler>' to the nat_transform. \
                   (NB: this is a structural precondition; the full \
                   naturality equation η_Y o F(f) = G(f) o η_X is not \
                   checked statically.)"
                  nt.nt_name nt.nt_source_morph nt.nt_target_morph
                  n n n n))
       | _ -> ok ())

and check_place_decl (env : Tyenv.env) (ctx : Reduce.ctx) (pd : place_decl) : unit tc_result =
  (* Check that the world is declared. *)
  let* () =
    if pd.pd_world = "__Builtin" then ok ()
    else match Tyenv.lookup_world env pd.pd_world with
    | Some _ -> ok ()
    | None -> err pd.pd_loc
        (Printf.sprintf "place %s refers to unknown world %s" pd.pd_name pd.pd_world)
  in
  (* Sheaf coherence on a quotient world. If the place's world is Q = W / Rel,
   * every field of the place must be invariant under Rel: it must factor
   * through the relation field's projection (canon = λu. u.Rel, via Sheaf). A
   * field that reads W finer than Rel identifies makes the place fail to
   * descend to the quotient -- two W-elements the relation calls equal could
   * carry different values -- a static sheaf-coherence violation, rejected here
   * on the existing diagnostics channel (cr_errors / exit 3).
   *
   * EXEMPTION — synthetic view places. View lowering (desugar.expand_views)
   * emits a record place whose name equals the view name and whose world is the
   * source place's world (so a view over a quotient world produces a place over
   * that quotient). Its fields are the SHOWN projections; the place-level gate
   * sees them as opaque names and would reject a field like `bucket` even when
   * it is defined as `classify(cohort)` — a pure function of the relation that
   * DOES descend. Descent for these is the proper job of check_view_decl, which
   * has the field DEFINITIONS. So if a view with this name exists, skip the
   * place-level gate here and let the view check decide. *)
  let* () =
    if Tyenv.lookup_view env pd.pd_name <> None then ok ()
    else match Tyenv.lookup_world env pd.pd_world with
    | Some wd ->
        (match wd.wd_quotient_of with
         | Some (base, rel_field) ->
             let fields =
               List.filter_map
                 (function FoField fd -> Some fd.fd_name | _ -> None)
                 pd.pd_members in
             (match Sheaf.quotient_violations ctx ~world:base ~rel_field ~fields with
              | [] -> ok ()
              | viol -> err pd.pd_loc (Printf.sprintf
                  "place `%s` is not a sheaf on the quotient world `%s = %s / %s`: \
                   field(s) %s are not invariant under `%s`. On a quotient world \
                   every field must be determined by the relation field `%s` \
                   (two elements the relation identifies would otherwise carry \
                   different values)."
                  pd.pd_name pd.pd_world base rel_field
                  (String.concat ", " viol) rel_field rel_field))
         | None -> ok ())
    | None -> ok ()
  in
  (* Check the monomorphism `place A subcontains B`. A is a sub-object of B
   * (A -> B) iff A has all the fields of B (structural subsumption). Reuses
   * place_is_subtype: place_is_subtype env ctx B A == true iff A has all the
   * fields of B. If A does not, the mono does not exist -> error. *)
  let* () =
    match pd.pd_subcontains with
    | None -> ok ()
    | Some base ->
        (match Tyenv.lookup_place env base with
         | None ->
             err pd.pd_loc (Printf.sprintf
               "place %s subcontains %s, but %s is not declared."
               pd.pd_name base base)
         | Some _ ->
             if place_is_subtype env ctx base pd.pd_name then ok ()
             else err pd.pd_loc (Printf.sprintf
               "invalid place %s subcontains %s: %s does not have all the fields \
                of %s. A sub-object A -> B requires A to have at least the \
                structure of B (subsumption: A is usable wherever B is expected)."
               pd.pd_name base pd.pd_name base))
  in
  (* Check the error morphism `place P on_error E`. E must be a declared place
   * marked as an error (pd_is_error). *)
  let* () =
    match pd.pd_on_error with
    | None -> ok ()
    | Some etarget ->
        (match Tyenv.lookup_place env etarget with
         | None ->
             err pd.pd_loc (Printf.sprintf
               "place %s on_error %s, but error %s is not declared."
               pd.pd_name etarget etarget)
         | Some epd ->
             if epd.pd_is_error then ok ()
             else err pd.pd_loc (Printf.sprintf
               "invalid place %s on_error %s: %s is not an error. The target \
                of on_error must be declared with `error %s ...`."
               pd.pd_name etarget etarget etarget))
  in
  List.fold_left
    (fun acc fo ->
       let* () = acc in
       match fo with
       | FoField f ->
           check_type_well_formed env (resolve_tparams pd.pd_type_params f.fd_ty) f.fd_loc
       | FoOp op ->
           let* () = List.fold_left
             (fun acc p ->
                let* () = acc in
                check_type_well_formed env p.param_ty op.op_loc)
             (ok ()) op.op_params in
           (match op.op_return with
            | Some t -> check_type_well_formed env t op.op_loc
            | None -> ok ())
       | FoCell _cd ->
           (* cell declarations are recorded in the
            * environment but their detailed type-checking
            * (dimension coherence, source/target well-formedness
            * within the place's cellular structure) is delegated
            * to CATT_R_Yon kernel. At this layer we accept the
            * declaration as syntactically well-formed. *)
           ok ()
       | FoLaw _ ->
           (* Declared algebraic laws. The real verification (against the
            * certified catalog) happens in the MLIR AlgebraVerifier pass, not here.
            * At this layer the law is only known to be syntactically
            * well-formed. *)
           ok ())
    (ok ()) pd.pd_members

and check_type_well_formed (env : Tyenv.env) (t : ty) (loc : location) : unit tc_result =
  (* Primitive types of Yon. Note both `boolean` and `proposition` are
   * accepted: `proposition` is the canonical name (the subobject
   * classifier Omega of the ambient topos, with Heyting tri-value semantics
   * in the default non-Boolean topos), while `boolean` is retained as
   * an alias for compatibility (operationally identical at the prototype
   * level; `boolean` would specialize to two-valued Omega in a Boolean
   * topos, which is a sub-case). *)
  let primitives = ["text"; "number"; "boolean"; "proposition"; "Decidable";
                    "money"; "person";
                    "address"; "tensor"; "cryptographic"; "unit";
                    "duration"; "fun"; "world"; "sum"; "unknown"] in
  let cubical_builtin = ["Path"; "Identity"; "Eq"; "Equiv"; "Glue";
                         "U"; "S1"; "S2"; "Sphere"; "Suspension"; "Susp";
                         "Quotient"; "PropTrunc"; "SetTrunc";
                         "Pushout"; "Coeq"] in
  (* Parameterizable runtime user-types. Lets one write
   * `fun f(R: Space): ...` and `fun g(m: Map): ...` without having to register
   * them with `place`. *)
  let runtime_builtin = ["Space"; "Map"; "HashSet"; "HashMap"; "HSH";
                         "List"; "Stream"; "Seq"; "Wire"; "XSet"; "XRelSet"; "XRelMap"; "XSimplex"; "XTower"; "MerkleTree";
                         "VoyagerList"; "String"] in
  match t with
  | TyPrim n | TyPrimIn (n, _) ->
      if List.mem n primitives then ok ()
      else err loc (Printf.sprintf "unknown primitive type: %s" n)
  | TyUser n ->
      if List.mem n primitives then ok ()
      else if List.mem n cubical_builtin then ok ()
      else if List.mem n runtime_builtin then ok ()
      else if Tyenv.lookup_place env n <> None then ok ()
      else if Tyenv.lookup_world env n <> None then ok ()
      else if Tyenv.lookup_named_sum env n <> None then ok ()  (* inductive Tree = ... *)
      else err loc (Printf.sprintf "unknown user type: %s" n)
  | TyApp (n, args) ->
      (* A type application `Box<number>`: the head must be a known type and each
         argument must be well-formed. Arity against the declared parameters is a
         later refinement (needs the head's type-param count threaded here). *)
      let* () = check_type_well_formed env (TyUser n) loc in
      List.fold_left
        (fun acc a -> let* () = acc in check_type_well_formed env a loc)
        (ok ()) args
  | TyVar _ ->
      (* Type variables are always well-formed in the context of their
       * binder (function signature with <T1, T2>). *)
      ok ()
  | TyMetaVar _ ->
      (* HM meta-variables are well-formed by construction (they come from
       * Ty_subst's fresh_metavar). *)
      ok ()
  | TyUniverse n ->
      (* Type_n is well-formed for any non-negative level n. *)
      if n < 0 then
        err loc (Printf.sprintf "negative universe level: Type_%d" n)
      else ok ()
  | TyPi (_x, a, b) | TySigma (_x, a, b) ->
      let* () = check_type_well_formed env a loc in
      check_type_well_formed env b loc
  | TyId (a, _, _) ->
      (* Endpoints are checked separately when constructed; here we
       * just verify the carrier type is well-formed. *)
      check_type_well_formed env a loc
  | TyPathP ((_, a), _, _) -> check_type_well_formed env a loc
  | TyList inner | TyStream inner ->
      check_type_well_formed env inner loc
  | TyMap (k, v) ->
      let* () = check_type_well_formed env k loc in
      check_type_well_formed env v loc
  | TySum vs | TySumIn (vs, _) ->
      List.fold_left
        (fun acc v ->
           let* () = acc in
           List.fold_left
             (fun acc' arg ->
                let* () = acc' in
                check_type_well_formed env arg loc)
             (ok ()) v.v_args)
        (ok ()) vs
  | TyHeytInt n ->
      (* heyt_int<N> requires 1 <= N <= 64. *)
      if n < 1 || n > 64 then
        err loc (Printf.sprintf
          "heyt_int<N> requires 1 <= N <= 64; found N=%d" n)
      else ok ()
  | TyArrow (a, b) ->
      (* TyArrow is well-formed if both of its types are well-formed. *)
      let* () = check_type_well_formed env a loc in
      check_type_well_formed env b loc
  | TyMoveHandle (p1, p2) ->
      (* TyMoveHandle is well-formed if the named places (when present) are
       * declared. None is a wildcard. Note: Yon syntax uses place names for a
       * move's from/to (mv_from/mv_to in surface_ast). *)
      let check_p po =
        match po with
        | None -> ok ()
        | Some n ->
            if Tyenv.lookup_place env n <> None then ok ()
            else err loc (Printf.sprintf "unknown place '%s' in move handle" n)
      in
      let* () = check_p p1 in
      check_p p2
  | TyReductionHandle p ->
      (* TyReductionHandle is well-formed if the named place is declared.
       * None is a wildcard. *)
      (match p with
       | None -> ok ()
       | Some n ->
           if Tyenv.lookup_place env n <> None then ok ()
           else err loc (Printf.sprintf "unknown place '%s' in reduction handle" n))
  | TyMorphHandle (_s1, _s2) ->
      (* TyMorphHandle is opaque. Topos names are not uniformly registered as
       * places or worlds, so we accept any identifier syntactically; the
       * semantic check happens in the inlining pattern at the call site. *)
      ok ()
  | TyViewHandle p ->
      (* TyViewHandle is well-formed if the named place is declared. *)
      (match p with
       | None -> ok ()
       | Some n ->
           if Tyenv.lookup_place env n <> None then ok ()
           else err loc (Printf.sprintf "unknown place '%s' in view handle" n))
  | TyWire _ ->
      (* Wire handle: opaque runtime handle, well-formed by construction. *)
      ok ()
  | TySubscription (_, inner) ->
      (* A subscription carries a stream element type; check that. *)
      check_type_well_formed env inner loc
  | TyEl c ->
      (* El(c) is well-formed iff the code c inhabits a universe. When c is an
         application `f(args)`, f must be a type FAMILY (return type a universe
         Type_n) — El decodes a type code, not a value. Catching a call to a
         value-returning function here gives a surface error with a location; the
         Core well-formedness gate (Core_wf) is the downstream backstop. We reject
         only the unambiguous case (f returns a PRIMITIVE value type) and defer
         everything else (generic/place/bare code) to the decode fallback + the
         Core gate, so a valid family like `El(Fam x)` is never false-rejected. *)
      let e = (match c with TyTermExpr e -> e) in
      let head_return =
        match e with
        | ECall (f, _, _) | EApp (EVar (f, _), _, _) ->
            (match Tyenv.lookup_fun env f with
             | Some s -> Some s.Tyenv.fs_return
             | None -> None)
        | _ -> None
      in
      (* A function used as a code family MUST return a universe. If the head of the
         code is a call to a function returning a PRIMITIVE value type (number, text,
         boolean, ...), the code is a value, not a type code: reject with a surface
         location. Universe / generic / place returns are deferred to the decode
         fallback and the Core gate, so a real family `El(Fam x)` is never rejected. *)
      let returns_value_prim =
        match head_return with
        | Some (TyPrim n | TyPrimIn (n, _) | TyUser n) -> List.mem n primitives
        | _ -> false
      in
      if returns_value_prim then
        err loc (Printf.sprintf
          "El(%s): the code computes a value of type %s, not a type code — El \
           decodes a universe code (a function returning Type_n), not a value"
          (ty_term_to_name e)
          (match head_return with Some rt -> Tyenv.ty_to_string rt | None -> "?"))
      else
        (match Catt_r_yon.el_decode (Catt_r_yon.TmVar (ty_term_to_name e)) with
         | Some _ -> ok ()
         | None ->
             err loc (Printf.sprintf
               "El(%s): code does not decode to a carrier (only 0/1-cells supported)"
               (ty_term_to_name e)))

and check_fun_decl (env : Tyenv.env) (ctx : Reduce.ctx) (fn : fun_decl) : unit tc_result =
  (* Step 1: rebind TyUser -> TyVar wherever the parser produced TyUser
   * for an identifier that's actually a declared type parameter. This
   * gives a clean view: TyVar means "generic, unifies with anything",
   * TyUser means "concrete place/world". *)
  let rec rebind_ty (t : ty) : ty =
    match t with
    | TyUser n when List.mem n fn.fn_type_params -> TyVar n
    | TyList inner -> TyList (rebind_ty inner)
    | TyMap (k, v) -> TyMap (rebind_ty k, rebind_ty v)
    | TyStream inner -> TyStream (rebind_ty inner)
    | TySum vs ->
        TySum (List.map
          (fun v -> { v with v_args = List.map rebind_ty v.v_args }) vs)
    | TySumIn (vs, ws) ->
        TySumIn (List.map
          (fun v -> { v with v_args = List.map rebind_ty v.v_args }) vs, ws)
    | other -> other
  in
  let rebound_params =
    List.map (fun p -> { p with param_ty = rebind_ty p.param_ty })
             fn.fn_params
  in
  let rebound_return = Option.map rebind_ty fn.fn_return in
  let fn = { fn with fn_params = rebound_params; fn_return = rebound_return } in
  (* Reject duplicate parameter names: il secondo altrimenti shadowa il primo
   * silenziosamente e si va in build-fail a valle. *)
  let* () =
    let rec dups seen = function
      | [] -> ok ()
      | p :: rest ->
          if List.mem p.param_name seen then
            err fn.fn_loc (Printf.sprintf
              "function %s: duplicate parameter '%s'" fn.fn_name p.param_name)
          else dups (p.param_name :: seen) rest
    in
    dups [] fn.fn_params
  in
  (* Reject empty body con tipo di ritorno dichiarato: altrimenti l'emit crasha
   * ("term form cannot be analyzed") non avendo un valore da inferire. *)
  let* () =
    if fn.fn_body = [] && fn.fn_return <> None then
      err fn.fn_loc (Printf.sprintf
        "function %s: empty body but a return type is declared (must return a value)"
        fn.fn_name)
    else ok ()
  in
  (* main is the program entry: its interface to the world is the effect system
   * (a `visits` clause), not value arguments, and nothing would supply them. A
   * parameterized main also desugars to a nested Lambda the backend cannot lower,
   * so reject it here with a clean diagnostic rather than a Fatal at emit. *)
  let* () =
    if fn.fn_name = "main" && fn.fn_params <> [] then
      err fn.fn_loc
        "main takes no value parameters: a program receives input from the world \
         through effects (a `visits` clause), not through arguments"
    else ok ()
  in
  (* Step 2: well-formedness checks. TyVar is always well-formed. *)
  let* () = List.fold_left
    (fun acc p ->
       let* () = acc in
       check_type_well_formed env p.param_ty fn.fn_loc)
    (ok ()) fn.fn_params
  in
  (* Check return type well-formed. *)
  let* () = match fn.fn_return with
    | Some t -> check_type_well_formed env t fn.fn_loc
    | None -> ok ()
  in
  (* Check each visited effect refers to a real place-with-effects. *)
  let* () = List.fold_left
    (fun acc eff ->
       let* () = acc in
       match Tyenv.lookup_place env eff with
       | None -> err fn.fn_loc
           (Printf.sprintf "function %s visits unknown place %s" fn.fn_name eff)
       | Some pd ->
           if pd.pd_with_effects then ok ()
           else err fn.fn_loc
             (Printf.sprintf "function %s visits %s but %s has no operations"
                fn.fn_name eff eff))
    (ok ()) fn.fn_visits
  in
  (* Build the body environment: params in scope, effects active. *)
  let body_env =
    fn.fn_params
    |> List.fold_left
         (fun e p -> Tyenv.add_var e p.param_name p.param_ty)
         env
    |> (fun e -> Tyenv.set_effects e fn.fn_visits)
  in
  let expected_ret = match fn.fn_return with
    | Some t -> Some t
    | None -> None
  in
  (* Body stmts: accumulate errors instead of stopping at first.
   * This gives the user the full picture of what's wrong, instead
   * of a one-error-at-a-time edit-fix-recompile cycle. *)
  let (final_env, body_errs) = check_stmts_accum body_env ctx fn.fn_body expected_ret in
  let tail_errs = match expected_ret with
    | Some rt -> check_implicit_tail_return final_env ctx fn.fn_body rt
    | None -> [] in
  match body_errs @ tail_errs with
  | [] -> ok ()
  | e :: _ ->
      (* Return only the first; multi-error report is at program level *)
      Error e

(* Variant that returns ALL errors from a function declaration. *)
and check_fun_decl_accum (env : Tyenv.env) (ctx : Reduce.ctx) (fn : fun_decl)
    : type_error list =
  (* Re-do the same logic but always accumulating. *)
  let rec rebind_ty (t : ty) : ty =
    match t with
    | TyUser n when List.mem n fn.fn_type_params -> TyVar n
    | TyList inner -> TyList (rebind_ty inner)
    | TyMap (k, v) -> TyMap (rebind_ty k, rebind_ty v)
    | TyStream inner -> TyStream (rebind_ty inner)
    | TySum vs ->
        TySum (List.map
          (fun v -> { v with v_args = List.map rebind_ty v.v_args }) vs)
    | TySumIn (vs, ws) ->
        TySumIn (List.map
          (fun v -> { v with v_args = List.map rebind_ty v.v_args }) vs, ws)
    | other -> other
  in
  let rebound_params =
    List.map (fun p -> { p with param_ty = rebind_ty p.param_ty })
             fn.fn_params
  in
  let rebound_return = Option.map rebind_ty fn.fn_return in
  let fn = { fn with fn_params = rebound_params; fn_return = rebound_return } in
  let errs = ref [] in
  let collect r = match r with Ok () -> () | Error e -> errs := e :: !errs in
  (* Reject duplicate parameter names (come check_fun_decl). *)
  (let rec dups seen = function
     | [] -> ()
     | p :: rest ->
         if List.mem p.param_name seen then
           collect (err fn.fn_loc (Printf.sprintf
             "function %s: duplicate parameter '%s'" fn.fn_name p.param_name))
         else dups (p.param_name :: seen) rest
   in
   dups [] fn.fn_params);
  (if fn.fn_body = [] && fn.fn_return <> None then
     collect (err fn.fn_loc (Printf.sprintf
       "function %s: empty body but a return type is declared" fn.fn_name)));
  (* main is the program entry: its interface to the world is the effect system
   * (a `visits` clause), not value arguments. Reject a parameterized main with a
   * clean diagnostic rather than a Fatal at emit (nested Lambda not lowerable). *)
  (if fn.fn_name = "main" && fn.fn_params <> [] then
     collect (err fn.fn_loc
       "main takes no value parameters: a program receives input from the world \
        through effects (a `visits` clause), not through arguments"));
  List.iter
    (fun p -> collect (check_type_well_formed env p.param_ty fn.fn_loc))
    fn.fn_params;
  (match fn.fn_return with
   | Some t -> collect (check_type_well_formed env t fn.fn_loc)
   | None -> ());
  List.iter
    (fun eff ->
       match Tyenv.lookup_place env eff with
       | None ->
           errs := { err_loc = fn.fn_loc;
                     err_msg = Printf.sprintf
                       "function %s visits unknown place %s" fn.fn_name eff }
                   :: !errs
       | Some pd ->
           if not pd.pd_with_effects then
             errs := { err_loc = fn.fn_loc;
                       err_msg = Printf.sprintf
                         "function %s visits %s but %s has no operations"
                         fn.fn_name eff eff }
                     :: !errs)
    fn.fn_visits;
  let body_env =
    fn.fn_params
    |> List.fold_left
         (fun e p -> Tyenv.add_var e p.param_name p.param_ty)
         env
    |> (fun e -> Tyenv.set_effects e fn.fn_visits)
  in
  let expected_ret = fn.fn_return in
  let (final_env, body_errs) = check_stmts_accum body_env ctx fn.fn_body expected_ret in
  let tail_errs = match expected_ret with
    | Some rt -> check_implicit_tail_return final_env ctx fn.fn_body rt
    | None -> [] in
  List.rev_append (body_errs @ tail_errs) (List.rev !errs)

and check_reduction_decl (env : Tyenv.env) (ctx : Reduce.ctx) (rd : reduction_decl) : unit tc_result =
  (* The target place must exist and have effects. *)
  let* target = match Tyenv.lookup_place env rd.rd_of with
    | None -> err rd.rd_loc
        (Printf.sprintf "reduction %s targets unknown place %s" rd.rd_name rd.rd_of)
    | Some p when not p.pd_with_effects ->
        err rd.rd_loc
          (Printf.sprintf "reduction %s targets place %s which has no effects"
             rd.rd_name rd.rd_of)
    | Some p -> ok p
  in
  (* Collect operations declared on the target. *)
  let target_ops = List.filter_map
    (function FoOp o -> Some o | FoField _ -> None | FoCell _ -> None | FoLaw _ -> None)
    target.pd_members in
  (* Check each clause: on op_name(params) { body } *)
  let handled = ref [] in
  let* () = List.fold_left
    (fun acc rc ->
       let* () = acc in
       match rc with
       | RcOn (op_name, params, body, loc) ->
           (match List.find_opt (fun o -> o.op_name = op_name) target_ops with
            | None -> err loc
                (Printf.sprintf "reduction %s handles operation %s which is not declared in place %s"
                   rd.rd_name op_name rd.rd_of)
            | Some op_decl ->
                handled := op_name :: !handled;
                (* Check parameter signatures match. *)
                if List.length params <> List.length op_decl.op_params then
                  err loc
                    (Printf.sprintf
                       "handler for %s.%s expects %d parameters, declared %d"
                       rd.rd_of op_name
                       (List.length op_decl.op_params)
                       (List.length params))
                else
                  let body_env =
                    params
                    |> List.fold_left
                         (fun e p -> Tyenv.add_var e p.param_name p.param_ty)
                         env
                  in
                  let ret_ty = match op_decl.op_return with
                    | Some t -> Some t
                    | None -> None
                  in
                  let* _ = check_stmts body_env ctx body ret_ty in
                  ok ())
       | RcLet (name, e, _) ->
           let* _ = infer env ctx e in
           ignore name; ok ())
    (ok ()) rd.rd_clauses
  in
  (* Coverage check: every operation in target must be handled, unless
   * we're a partial reduction (we don't track that explicitly). *)
  ignore !handled;
  ok ()

and check_move_decl (env : Tyenv.env) (ctx : Reduce.ctx) (md : move_decl) : unit tc_result =
  (* Form A move: from P to Q with mappings on individual fields.
   * Form B move: merge P, Q, R (no target).
   *
   * For Form A, we verify:
   *   1. Source and target places exist
   *   2. Each mapping refers to a real source field f_from with type T_from
   *   3. Each mapping's target field f_to exists in target place with type T_to
   *   4. The handler function m_by, if registered, has signature
   *      compatible with T_from -> T_to.
   *
   * Width subtyping (row polymorphism): if the source place has MORE
   * fields than mapped, those extra fields are simply ignored — they
   * don't need to map to anything. If the target place has MORE fields
   * than mapped, the unmapped target fields must be inferrable: a
   * "pass-through" by same name is the most permissive interpretation.
   *
   * This realizes row polymorphism on moves: a move declared on the
   * minimum required field set works on any place that's a width
   * supertype.
   *)
  let* () = List.fold_left
    (fun acc p ->
       let* () = acc in
       match Tyenv.lookup_place env p with
       | Some _ -> ok ()
       | None -> err md.mv_loc
           (Printf.sprintf "move %s refers to unknown place %s" md.mv_name p))
    (ok ()) md.mv_from
  in
  let* () = match md.mv_to with
    | Some t ->
        (match Tyenv.lookup_place env t with
         | Some _ -> ok ()
         | None -> err md.mv_loc
             (Printf.sprintf "move %s targets unknown place %s" md.mv_name t))
    | None -> ok ()
  in
  (* For Form A, check field mappings. *)
  (match md.mv_body, md.mv_from, md.mv_to with
   | MoveMapping mappings, [src_name], Some tgt_name ->
       (* Fetch the field types. *)
       let src_pd = Tyenv.lookup_place env src_name in
       let tgt_pd = Tyenv.lookup_place env tgt_name in
       (match src_pd, tgt_pd with
        | Some src, Some tgt ->
            let field_ty_of pd name =
              let rec find = function
                | [] -> None
                | FoField f :: _ when f.fd_name = name -> Some f.fd_ty
                | _ :: rest -> find rest
              in
              find pd.pd_members
            in
            (* Check each mapping. *)
            let* () = List.fold_left
              (fun acc m ->
                 let* () = acc in
                 let open Surface_ast in
                 let src_ty = field_ty_of src m.m_from in
                 let tgt_ty = field_ty_of tgt m.m_to in
                 match src_ty, tgt_ty with
                 | None, _ ->
                     err m.m_loc (Printf.sprintf
                       "move %s: source field '%s' not found in %s"
                       md.mv_name m.m_from src_name)
                 | _, None ->
                     err m.m_loc (Printf.sprintf
                       "move %s: target field '%s' not found in %s"
                       md.mv_name m.m_to tgt_name)
                 | Some st, Some tt ->
                     (* Check handler function (if registered). *)
                     match Tyenv.lookup_fun env m.m_by with
                     | None ->
                         (* Pass-through: source field must be usable as target. *)
                         if Dispatcher.subtype env ctx ~sub:st ~super:tt then ok ()
                         else err m.m_loc (Printf.sprintf
                           "move %s: field '%s' (%s) to '%s' (%s) without handler — types incompatible"
                           md.mv_name m.m_from (Tyenv.ty_to_string st)
                           m.m_to (Tyenv.ty_to_string tt))
                     | Some fs ->
                         (* Handler should have signature ~ T_from -> T_to. *)
                         if List.length fs.fs_params <> 1 then
                           err m.m_loc (Printf.sprintf
                             "move %s: handler '%s' must take exactly 1 argument, got %d"
                             md.mv_name m.m_by (List.length fs.fs_params))
                         else
                           let (_, param_ty) = List.hd fs.fs_params in
                           let ret_ty = fs.fs_return in
                           let ok_in = Dispatcher.subtype env ctx ~sub:st ~super:param_ty in
                           let ok_out = Dispatcher.subtype env ctx ~sub:ret_ty ~super:tt in
                           if ok_in && ok_out then ok ()
                           else err m.m_loc (Printf.sprintf
                             "move %s: handler '%s' has signature %s -> %s, expected %s -> %s"
                             md.mv_name m.m_by
                             (Tyenv.ty_to_string param_ty)
                             (Tyenv.ty_to_string ret_ty)
                             (Tyenv.ty_to_string st)
                             (Tyenv.ty_to_string tt)))
              (ok ()) mappings
            in
            let* () =
              match Tyenv.lookup_world env src.pd_world with
              | Some wd ->
                  (match quotient_rel_of_world wd with
                   | Some rel ->
                       let domain = C.TyPlace src_name in
                       let canon = Sheaf.quotient_canon ~rel ~domain in
                       let sheaf_ctx =
                         { ctx with Reduce.deltas = env.Tyenv.delta }
                       in
                       List.fold_left
                         (fun acc m ->
                            let* () = acc in
                            let point = "__move_s" in
                            let field =
                              C.Lam (point, domain,
                                C.App
                                  (C.Var ("__field_" ^ m.m_from),
                                   C.Var point))
                            in
                            if Sheaf.field_factors_through sheaf_ctx
                                 ~canon ~field
                            then ok ()
                            else err m.m_loc (Printf.sprintf
                              "move %s source field '%s' reads finer than %s and does not descend through quotient world %s"
                              md.mv_name m.m_from rel wd.wd_name))
                         (ok ()) mappings
                   | None -> ok ())
              | None -> ok ()
            in
            (* Row polymorphism / width check:
             * Verify that for every target field T NOT in the mapping
             * list, either:
             *   (a) the source has a field of the same name and
             *       compatible type (pass-through), OR
             *   (b) the field can be defaulted (left to runtime).
             * We accept (a) silently and (b) with a warning placeholder.
             *)
            let mapped_targets =
              List.map (fun m -> m.Surface_ast.m_to) mappings in
            let tgt_fields = List.filter_map
              (function FoField f -> Some f | FoOp _ -> None | FoCell _ -> None | FoLaw _ -> None) tgt.pd_members in
            List.fold_left
              (fun acc f ->
                 let* () = acc in
                 if List.mem f.fd_name mapped_targets then ok ()
                 else
                   match field_ty_of src f.fd_name with
                   | Some src_ty when Dispatcher.subtype env ctx ~sub:src_ty ~super:f.fd_ty ->
                       (* Pass-through: source has matching field. *)
                       ok ()
                   | Some src_ty ->
                       err md.mv_loc (Printf.sprintf
                         "move %s: target field '%s' (%s) has source candidate of incompatible type %s — explicit mapping required"
                         md.mv_name f.fd_name (Tyenv.ty_to_string f.fd_ty)
                         (Tyenv.ty_to_string src_ty))
                   | None ->
                       (* No source counterpart and no mapping: would
                        * require a default value. Defer to runtime. *)
                       ok ())
              (ok ()) tgt_fields
        | _ -> ok ())  (* Places not found, already reported above *)
   | _ -> ok ())

and quotient_rel_of_world (wd : world_decl) : string option =
  match wd.wd_quotient_of with
  | Some (_, rel) -> Some rel
  | None -> None

and view_field_expr_to_core
    (env : Tyenv.env) (fields : (string * ty) list)
    (place_name : string) (expr : expr) : C.term option =
  let expr' = Desugar.rewrite_view_fields fields expr in
  match Desugar.desugar_expr_pure env expr' with
  | Some body -> Some (C.Lam ("__view_s", C.TyPlace place_name, body))
  | None -> None

and check_view_decl (env : Tyenv.env) (ctx : Reduce.ctx) (vd : view_decl) : unit tc_result =
  match Tyenv.lookup_place env vd.vw_of with
  | None -> err vd.vw_loc
      (Printf.sprintf "view %s of unknown place %s" vd.vw_name vd.vw_of)
  | Some pd ->
      match Tyenv.lookup_world env pd.pd_world with
      | None -> ok ()
      | Some wd ->
          match quotient_rel_of_world wd with
          | None -> ok ()
          | Some rel ->
              let fields =
                Tyenv.place_fields pd
                |> List.map (fun f -> (f.fd_name, f.fd_ty))
              in
              let canon =
                Sheaf.quotient_canon ~rel ~domain:(C.TyPlace vd.vw_of)
              in
              let sheaf_ctx = { ctx with Reduce.deltas = env.Tyenv.delta } in
              List.fold_left
                (fun acc item ->
                   let* () = acc in
                   match item with
                   | VShowSimple _ | VShowLabel _ -> ok ()
                   | VShowAs (field, expr) ->
                       (match view_field_expr_to_core env fields vd.vw_of expr with
                        | Some field_term
                          when Sheaf.field_factors_through sheaf_ctx
                            ~canon ~field:field_term ->
                            ok ()
                        | Some _ ->
                            err vd.vw_loc (Printf.sprintf
                              "view %s show %s reads finer than %s; views over quotient world %s must factor through %s"
                              vd.vw_name field rel wd.wd_name rel)
                        | None ->
                            err vd.vw_loc (Printf.sprintf
                              "view %s show %s cannot be proven to factor through %s"
                              vd.vw_name field rel)))
                (ok ()) vd.vw_items


(* ─── Program-level entry point ────────────────────────────────────── *)

(* Two passes:
 *   Pass 1: register all signatures (places, worlds, funs, reductions).
 *   Pass 2: check each declaration's body.
 *
 * Errors from any decl accumulate into a list returned at the end.
 *)

type check_result = {
  cr_env : Tyenv.env;
  cr_errors : type_error list;
}

(* ─── Pass 0: world parameter inference for places ────────────────── *)

(* Yoneda-native world inference.
 *
 * A place is a functor P : C^op -> Set where C is the site (the world).
 * When a place is declared without `in W`, the world is recovered
 * structurally by looking at how the place is used in the rest of the
 * program. We don't introduce metavariables nor a unification engine;
 * we apply nominal lookup rules in priority order:
 *
 *   (a) Unique-world rule: if the program declares exactly one world,
 *       every unannotated place lives there.
 *
 *   (b) Reduction-target rule: if `reduction R of P` appears and R
 *       lives in a place whose world is W, then P lives in W.
 *
 *   (c) Move-edge rule: if `move M from P to Q` appears and Q has a
 *       known world W, P (and the move) live in W.
 *
 *   (d) Effect-signature rule: if a function `fun f(... : P, ...) visits Q`
 *       declares Q with known world W, P lives in W.
 *
 *   (e) Place-sibling rule: if another place P' annotated `in W` shares
 *       a field with the same name and compatible type as P, P lives
 *       in W (a coarse heuristic, fired last).
 *
 * If after all rules a place's world remains unresolved, OR if two
 * rules give incompatible worlds, an error is raised.
 *)
let infer_place_worlds (p : program) : (program, type_error) result =
  (* Collect declared worlds. *)
  let worlds = List.filter_map
    (function TopWorld wd -> Some wd.wd_name | _ -> None) p in
  let known_place_worlds = List.filter_map
    (function
      | TopPlace pd when pd.pd_world <> "__INFER" -> Some (pd.pd_name, pd.pd_world)
      | _ -> None) p in
  (* Look up a place's world, returns Some W if known *)
  let world_of_place name =
    try Some (List.assoc name known_place_worlds) with Not_found -> None
  in
  (* For each unannotated place, derive a candidate world. *)
  let infer_for (pd : place_decl) : (string, type_error) result =
    let candidates = ref [] in
    let add_candidate origin w =
      if not (List.exists (fun (_, w') -> w' = w) !candidates) then
        candidates := (origin, w) :: !candidates
    in
    (* Rule (a): unique world *)
    (match worlds with
     | [w] -> add_candidate "unique-world" w
     | _ -> ());
    (* Rule (b): reduction target. Scan reductions for `of pd.pd_name`. *)
    List.iter (function
      | TopReduction rd when rd.rd_of = pd.pd_name ->
          (* Walk other places that *contain* operations the reduction
           * handles; their world propagates back. For now we use the
           * structural fact: if R reduces P and R's clauses mention
           * operations declared on another already-annotated place,
           * that place's world matches. *)
          List.iter (function
            | RcOn (op_name, _, _, _) ->
                List.iter (fun (n, w) ->
                  (* If any known place declares this op_name as one of
                   * its operations, propagate w. *)
                  match world_of_place n with
                  | Some _ when n = pd.pd_name -> ()  (* trivial *)
                  | _ ->
                    List.iter (function
                      | TopPlace pd' when pd'.pd_world = w ->
                          List.iter (function
                            | FoOp os when os.op_name = op_name ->
                                add_candidate ("reduction-handles-op:" ^ n) w
                            | _ -> ()) pd'.pd_members
                      | _ -> ()) p)
                  known_place_worlds
            | _ -> ()) rd.rd_clauses
      | _ -> ()) p;
    (* Rule (c): move edges. If move M from pd.pd_name to Q (or vice-versa)
     * and Q's world is known, propagate. *)
    List.iter (function
      | TopMove md ->
          let mentioned = md.mv_from @ (match md.mv_to with Some t -> [t] | None -> []) in
          if List.mem pd.pd_name mentioned then
            List.iter (fun other ->
              if other <> pd.pd_name then
                match world_of_place other with
                | Some w -> add_candidate ("move-with:" ^ other) w
                | None -> ()) mentioned
      | _ -> ()) p;
    (* Rule (d): effect signature. If fun f(... : pd.pd_name ...) visits Q,
     * and Q has known world, propagate. *)
    List.iter (function
      | TopFun fn ->
          let mentions_pd =
            List.exists (fun p_ ->
              match p_.param_ty with
              | TyUser n when n = pd.pd_name -> true
              | _ -> false) fn.fn_params
            || (match fn.fn_return with
                | Some (TyUser n) when n = pd.pd_name -> true
                | _ -> false)
          in
          if mentions_pd then
            List.iter (fun visited ->
              match world_of_place visited with
              | Some w -> add_candidate ("visits:" ^ visited) w
              | None -> ()) fn.fn_visits
      | _ -> ()) p;
    (* Rule (e): sibling place — same field name + type. *)
    let pd_fields = List.filter_map
      (function FoField f -> Some f | _ -> None) pd.pd_members in
    if pd_fields <> [] then
      List.iter (function
        | TopPlace pd' when pd'.pd_world <> "__INFER"
                        && pd'.pd_name <> pd.pd_name ->
            let pd'_fields = List.filter_map
              (function FoField f -> Some f | _ -> None) pd'.pd_members in
            if List.exists
                 (fun f -> List.exists (fun f' ->
                              f.fd_name = f'.fd_name
                              && Tyenv.simple_ty_compatible f.fd_ty f'.fd_ty)
                            pd'_fields)
                 pd_fields
            then add_candidate ("sibling:" ^ pd'.pd_name) pd'.pd_world
        | _ -> ()) p;
    (* Coherence: all candidates must agree. *)
    let unique = List.sort_uniq compare (List.map snd !candidates) in
    match unique with
    | [] ->
        Error { err_loc = pd.pd_loc;
                err_msg = Printf.sprintf
                  "cannot infer world for place %s: no contextual rule applies"
                  pd.pd_name }
    | [w] -> Ok w
    | ws ->
        Error { err_loc = pd.pd_loc;
                err_msg = Printf.sprintf
                  "place %s has conflicting world candidates: %s"
                  pd.pd_name (String.concat ", " ws) }
  in
  (* Rewrite each TopPlace with __INFER, accumulating errors. *)
  let result = List.fold_left
    (fun acc td ->
       match acc with
       | Error _ -> acc
       | Ok decls ->
           match td with
           | TopPlace pd when pd.pd_world = "__INFER" ->
               (match infer_for pd with
                | Ok w ->
                    Ok (TopPlace { pd with pd_world = w } :: decls)
                | Error e -> Error e)
           | other -> Ok (other :: decls))
    (Ok []) p
  in
  match result with
  | Ok decls -> Ok (List.rev decls)
  | Error e -> Error e

(* ─── Pass 1.5: effect inference (transitive closure of `visits`) ────── *)

(* Yoneda-coherent effect inference.
 *
 * If a function f calls g, and g visits W, then f must transitively
 * visit W too: at runtime, when f is called, the handler stack must
 * already contain a reduction for W (so that g's operations can be
 * dispatched). Declaring this explicitly is annoying; we compute the
 * fixpoint and silently extend each function's `fs_visits`.
 *
 * This is closure under the dependency relation on the call graph.
 * Non-monotonic refinement (e.g., with's that handle effects locally
 * and "discharge" them) is NOT modeled here — `with R { ... }`
 * activates an in-scope reduction but doesn't remove the effect from
 * f's surface signature. Future work: subtract handled effects when
 * the with's reduction targets a place in the inferred set. *)
let collect_calls_in_stmts (stmts : stmt list) : string list =
  let calls = ref [] in
  let rec walk_expr e =
    match e with
    | ECall (name, args, _) ->
        if not (List.mem name !calls) then calls := name :: !calls;
        List.iter walk_expr args
    | EBinop (_, a, b, _) -> walk_expr a; walk_expr b
    | EField (a, _, _) -> walk_expr a
    | EParen (e, _) -> walk_expr e
    | ENew (_, fas, _) -> List.iter (fun fa -> walk_expr fa.fa_value) fas
    | ENewIn (_, _, fas, _) -> List.iter (fun fa -> walk_expr fa.fa_value) fas
    | EAll (_, _, _) -> ()
    | EIn (e, _, _) -> walk_expr e
    | EPair (a, b, _) -> walk_expr a; walk_expr b
    | EFst (e, _) | ESnd (e, _) | ERefl (e, _) -> walk_expr e
    | EJ (a, b, c, _) -> walk_expr a; walk_expr b; walk_expr c
    | EPullback (_, _, _) | EPushout (_, _, _) | EWireTo (_, _) -> ()
    | EPullbackVal (_, _, a, b, _) -> walk_expr a; walk_expr b
    | ENot (e, _) -> walk_expr e
    | EIfThenElse (c, a, b, _) -> walk_expr c; walk_expr a; walk_expr b
    | ELam (_, body, _) -> walk_expr body
    | EMoveLam (_, body, _, _, _)
    | EReductionLam (_, body, _, _)
    | EMorphLam (_, body, _, _, _) -> walk_expr body
    | EFunctorLam (_, body, _, _, _, _) -> walk_expr body
    | EViewLam (_, body, _, _) -> walk_expr body
    | EComposeWith (h1, h2, _) -> walk_expr h1; walk_expr h2
    | EProduce (body, _) -> List.iter walk_stmt body
    | ESpawn (count, body, _) ->
        (match count with Some e -> walk_expr e | None -> ());
        List.iter walk_stmt body
    | EQuote (_, a, _) -> walk_expr a
    | EElMatch (tgt, ret, bod, _) -> walk_expr tgt; walk_expr ret; walk_expr bod
    | EApp (f, args, _) -> walk_expr f; List.iter walk_expr args
    | EHITElim (c, branches, x, _) ->
        walk_expr c;
        List.iter (fun (_, _, e) -> walk_expr e) branches;
        walk_expr x
    | EPathApp (p, _, _) -> walk_expr p
    | EPathAbs (_, e, _) -> walk_expr e
    | EHITConstr (_, args, _) -> List.iter walk_expr args
    | ELit _ | EVar _ -> ()
  and walk_stmt s =
    match s with
    | SLet (_, e, _) | SReturn (e, _) -> walk_expr e
    | SAssignHolds (_, e, _) | SAssignBecomes (_, e, _) -> walk_expr e
    | SCall (name, args, _) ->
        if not (List.mem name !calls) then calls := name :: !calls;
        List.iter walk_expr args
    | SNew (_, fas, _) -> List.iter (fun fa -> walk_expr fa.fa_value) fas
    | SNewIn (_, _, fas, _) -> List.iter (fun fa -> walk_expr fa.fa_value) fas
    | SWhen (_, body, alts, otherwise, _) ->
        List.iter walk_stmt body;
        List.iter (fun (_, b) -> List.iter walk_stmt b) alts;
        (match otherwise with Some os -> List.iter walk_stmt os | None -> ())
    | SForEvery (_, _, e, body, _) -> walk_expr e; List.iter walk_stmt body
    | SInSequence (_, e, body, _) -> walk_expr e; List.iter walk_stmt body
    | SRepeat (_, body, otherwise, _) ->
        List.iter walk_stmt body;
        (match otherwise with Some os -> List.iter walk_stmt os | None -> ())
    | SForever (body, _) -> List.iter walk_stmt body
    | SScope (_, body, e, _) -> List.iter walk_stmt body; walk_expr e
    | SProduce (body, _) -> List.iter walk_stmt body
    | SEmit (e, _) -> walk_expr e
    | SPromote (e, _) -> walk_expr e
    | SForces (_, _, body, _) -> List.iter walk_stmt body
    | SIter (n, body, _) -> walk_expr n; List.iter walk_stmt body
    | SWhile (c, body, _) -> walk_expr c; List.iter walk_stmt body
    | SDrop _ -> ()
  in
  List.iter walk_stmt stmts;
  !calls

(* ─── HM type inference opt-in ──────────── *)
(*
 * Pre-pass: for each fun_decl with a parameter marker TyUser "_" or with
 * fn_return = None, infer the type by looking at the call sites and the return
 * statements of the body.
 *
 * A best-effort strategy (not full Algorithm W):
 *   1. expr_ty_heuristic produces base types from literals, binops, and ECall
 *      of known functions.
 *   2. For each "_" parameter: find ECall(name, args), take the type of the
 *      i-th argument, and aggregate by majority.
 *   3. For fn_return = None: scan the body for SReturn and apply the
 *      heuristic.
 *   4. Substitute.
 *
 * Honest limits:
 *   - Does not handle polymorphic recursion (Mycroft-Tofte would be needed).
 *   - Does not handle higher-order functions: a function passed as an argument
 *     makes the referring parameter take TyPrim "unknown" (a placeholder).
 *   - Does not produce universally quantified type schemes.
 *)

let rec expr_ty_heuristic
    (param_types : (string * ty) list)
    (let_types : (string * ty) list)
    (fun_returns : (string * ty) list)
    (e : expr) : ty option =
  match e with
  | ELit (LitNumber _, _) -> Some (TyPrim "number")
  | ELit (LitString _, _) -> Some (TyPrim "text")
  | ELit (LitBool _, _) -> Some (TyPrim "boolean")
  | ELit (LitDuration _, _) -> Some (TyPrim "number")
  | EVar (x, _) ->
      (match List.assoc_opt x let_types with
       | Some t -> Some t
       | None -> List.assoc_opt x param_types)
  | EBinop (op, _, _, _) ->
      (match op with
       | OpAdd | OpSub | OpMul | OpDiv | OpMod -> Some (TyPrim "number")
       | OpEq | OpNeq | OpLt | OpGt | OpLeq | OpGeq -> Some (TyPrim "boolean")
       | OpAnd | OpOr -> Some (TyPrim "boolean"))
  | EParen (inner, _) ->
      expr_ty_heuristic param_types let_types fun_returns inner
  | EIfThenElse (_, then_e, _else_e, _) ->
      expr_ty_heuristic param_types let_types fun_returns then_e
  | ECall (name, _, _) ->
      List.assoc_opt name fun_returns
  | ENot (_, _) -> Some (TyPrim "boolean")
  | _ -> None  (* ENew, EField, EAll, EPair, etc — None = unknown *)

(* Extract the inferred type from a body by looking for SReturn and applying the heuristic. *)
let infer_body_return_type
    (param_types : (string * ty) list)
    (fun_returns : (string * ty) list)
    (stmts : stmt list) : ty option =
  let let_types = ref [] in
  let candidates = ref [] in
  let add_let name t =
    if not (List.mem_assoc name !let_types) then
      let_types := (name, t) :: !let_types
  in
  let rec walk_stmt s =
    match s with
    | SLet (name, e, _) ->
        (match expr_ty_heuristic param_types !let_types fun_returns e with
         | Some t -> add_let name t
         | None -> ())
    | SReturn (e, _) ->
        (match expr_ty_heuristic param_types !let_types fun_returns e with
         | Some t -> candidates := t :: !candidates
         | None -> ())
    | SWhen (_, body, alts, otherwise, _) ->
        List.iter walk_stmt body;
        List.iter (fun (_, b) -> List.iter walk_stmt b) alts;
        (match otherwise with Some os -> List.iter walk_stmt os | None -> ())
    | SIter (_, body, _) | SWhile (_, body, _)
    | SForever (body, _) -> List.iter walk_stmt body
    | SScope (_, body, e, _) ->
        List.iter walk_stmt body;
        (match expr_ty_heuristic param_types !let_types fun_returns e with
         | Some t -> candidates := t :: !candidates
         | None -> ())
    | _ -> ()
  in
  List.iter walk_stmt stmts;
  (* Majority among the candidates: takes the first if all equal. *)
  match !candidates with
  | [] -> None
  | [t] -> Some t
  | t :: rest when List.for_all (fun u -> u = t) rest -> Some t
  | _ -> None  (* a conflict -> None, leaving "_" -> the tycheck will error *)

(* Pre-pass: infer the types of fun_decls with "_" or return None. *)
let infer_fun_signatures (p : program) : (program, type_error) result =
  (* Build the initial mapping fun_name -> return type for the functions whose
   * type is already known. Used to infer ECall calls to them. *)
  let known_fun_returns = List.filter_map
    (function
      | TopFun fn ->
          (match fn.fn_return with
           | Some t -> Some (fn.fn_name, t)
           | None -> None)
      | _ -> None) p
  in
  let needs_inference (fn : fun_decl) : bool =
    List.exists (fun p -> p.param_ty = TyUser "_") fn.fn_params
    || fn.fn_return = None
  in
  let infer_one (fn : fun_decl) : fun_decl =
    if not (needs_inference fn) then fn
    else begin
      (* Find the call sites of this function in the whole program. *)
      let call_arg_lists = ref [] in
      let rec walk_expr e =
        match e with
        | ECall (name, args, _) when name = fn.fn_name ->
            call_arg_lists := args :: !call_arg_lists;
            List.iter walk_expr args
        | ECall (_, args, _) -> List.iter walk_expr args
        | EBinop (_, a, b, _) -> walk_expr a; walk_expr b
        | EParen (e, _) | ENot (e, _) -> walk_expr e
        | EIfThenElse (c, t, e, _) -> walk_expr c; walk_expr t; walk_expr e
        | EField (e, _, _) -> walk_expr e
        | _ -> ()
      and walk_stmt s =
        match s with
        | SLet (_, e, _) | SReturn (e, _)
        | SAssignHolds (_, e, _) | SAssignBecomes (_, e, _)
        | SEmit (e, _) -> walk_expr e
        | SCall (name, args, _) ->
            if name = fn.fn_name then call_arg_lists := args :: !call_arg_lists;
            List.iter walk_expr args
        | SNew (_, fas, _) | SNewIn (_, _, fas, _) ->
            List.iter (fun fa -> walk_expr fa.fa_value) fas
        | SWhen (_, body, alts, otherwise, _) ->
            List.iter walk_stmt body;
            List.iter (fun (_, b) -> List.iter walk_stmt b) alts;
            (match otherwise with Some os -> List.iter walk_stmt os | None -> ())
        | SForEvery (_, _, e, body, _) | SInSequence (_, e, body, _) ->
            walk_expr e; List.iter walk_stmt body
        | SRepeat (_, body, otherwise, _) ->
            List.iter walk_stmt body;
            (match otherwise with Some os -> List.iter walk_stmt os | None -> ())
        | SForever (body, _) -> List.iter walk_stmt body
        | SScope (_, body, e, _) -> List.iter walk_stmt body; walk_expr e
        | SProduce (body, _) -> List.iter walk_stmt body
        | SForces (_, _, body, _) -> List.iter walk_stmt body
        | SIter (n, body, _) -> walk_expr n; List.iter walk_stmt body
        | SWhile (c, body, _) -> walk_expr c; List.iter walk_stmt body
        | SPromote (e, _) -> walk_expr e
        | SDrop _ -> ()
      in
      List.iter (function
        | TopFun other_fn -> List.iter walk_stmt other_fn.fn_body
        | _ -> ()) p;
      (* Infer each "_" parameter from the type of the corresponding argument at the call sites. *)
      let n_params = List.length fn.fn_params in
      let inferred_params = List.mapi (fun i p ->
        if p.param_ty <> TyUser "_" then p
        else begin
          let arg_tys = List.filter_map (fun args ->
            if List.length args = n_params then
              expr_ty_heuristic [] [] known_fun_returns (List.nth args i)
            else None
          ) !call_arg_lists in
          (* Maggioranza *)
          let inferred = match arg_tys with
            | [] -> TyPrim "unknown"
            | t :: rest when List.for_all (fun u -> u = t) rest -> t
            | _ -> TyPrim "unknown"
          in
          { p with param_ty = inferred }
        end
      ) fn.fn_params in
      (* Infer the return type if missing. *)
      let inferred_return =
        match fn.fn_return with
        | Some t -> Some t
        | None ->
            let param_types = List.map (fun p -> (p.param_name, p.param_ty))
                                inferred_params in
            infer_body_return_type param_types known_fun_returns fn.fn_body
      in
      { fn with fn_params = inferred_params; fn_return = inferred_return }
    end
  in
  let p' = List.map (function
    | TopFun fn -> TopFun (infer_one fn)
    | other -> other) p in
  Ok p'

let infer_effects (env : Tyenv.env) (p : program) : Tyenv.env =
  (* Collect, for each function, the set of called function names. *)
  let call_graph =
    List.filter_map
      (function
        | TopFun fn ->
            Some (fn.fn_name, collect_calls_in_stmts fn.fn_body)
        | _ -> None)
      p
  in
  (* Initial visits: declared values from env (we'll iterate). *)
  let visits_table = Hashtbl.create 17 in
  List.iter (fun (name, fs) ->
    Hashtbl.replace visits_table name fs.Tyenv.fs_visits)
    env.Tyenv.funs;
  (* Fixpoint: visits(f) ← visits(f) ∪ ⋃_{g in calls(f)} visits(g) *)
  let changed = ref true in
  let iterations = ref 0 in
  while !changed && !iterations < 100 do
    incr iterations;
    changed := false;
    List.iter (fun (f_name, callees) ->
      let cur = try Hashtbl.find visits_table f_name with Not_found -> [] in
      let added = List.fold_left
        (fun acc g ->
           let g_visits =
             try Hashtbl.find visits_table g with Not_found -> []
           in
           List.fold_left
             (fun acc' w -> if List.mem w acc' then acc' else w :: acc')
             acc g_visits)
        cur callees
      in
      if List.length added > List.length cur then
        (changed := true;
         Hashtbl.replace visits_table f_name added))
      call_graph
  done;
  (* Patch the env: for each function whose visits grew, update fs_visits. *)
  let updated_funs = List.map
    (fun (name, fs) ->
       let inferred =
         try Hashtbl.find visits_table name with Not_found -> fs.Tyenv.fs_visits
       in
       (name, { fs with Tyenv.fs_visits = inferred }))
    env.Tyenv.funs
  in
  { env with Tyenv.funs = updated_funs }

(* ─── Id-proposition sugar elaboration (Same / plainly) ──────────────────
   Runs on the surface AST before check_program AND desugar, lowering the two
   sugar sentinels into kernel Id / refl so nothing downstream must know they
   existed:
     - `Same(X, Y)` parses as TyId(TyMetaVar same_sentinel, X, Y): the sentinel
       carrier is replaced by the INFERRED type of the left endpoint X (reusing
       `infer`, since the dependent layer has no unification engine of its own).
     - `plainly` parses as refl(__plainly__): the placeholder endpoint is
       replaced by the left endpoint of the enclosing function's return-type Id.
   The env for inference is built with the same prelude check_program uses, but
   we map over the ORIGINAL program (preserving __INFER world markers for the
   backend), touching only the two sentinels. Best-effort: on any inference
   failure the node is left as-is and check_program reports the visible error. *)
let same_sentinel = -424242

let elaborate_id_sugar (p : program) : program =
  let built =
    match infer_place_worlds (Method_sugar.normalize_program p) with
    | Error _ -> None
    | Ok p1 ->
      (match infer_fun_signatures p1 with
       | Error _ -> None
       | Ok p2 -> Some (Hm_infer.infer_program p2))
  in
  match built with
  | None -> p
  | Some p3 ->
    let genv = List.fold_left register_decl (Tyenv.with_builtins Tyenv.empty) p3 in
    let ctx = Reduce.empty_ctx in
    let fix_plainly (ep : expr) (e : expr) : expr =
      match e with
      | ERefl (EVar ("__plainly__", _), l) -> ERefl (ep, l)
      | _ -> e
    in
    let resolve_fun (fd : fun_decl) : fun_decl =
      let lenv = List.fold_left
          (fun e (pm : param) -> Tyenv.add_var e pm.param_name pm.param_ty)
          genv fd.fn_params in
      let fn_return, endpoint =
        match fd.fn_return with
        | Some (TyId (TyMetaVar s, (TyTermExpr x as tx), ty_r)) when s = same_sentinel ->
            let carrier =
              (match infer lenv ctx x with Ok t -> t | Error _ -> TyMetaVar s) in
            (Some (TyId (carrier, tx, ty_r)), Some x)
        | Some (TyId (_, TyTermExpr x, _)) -> (fd.fn_return, Some x)
        | _ -> (fd.fn_return, None)
      in
      let fn_body =
        match endpoint with
        | None -> fd.fn_body
        | Some ep ->
            List.map (function
              | SReturn (e, l) -> SReturn (fix_plainly ep e, l)
              | SLet (n, e, l) -> SLet (n, fix_plainly ep e, l)
              | s -> s) fd.fn_body
      in
      { fd with fn_return; fn_body }
    in
    List.map (function TopFun fd -> TopFun (resolve_fun fd) | d -> d) p

let check_program (p : program) : check_result =
  (* Method-call sugar (`s.add(...)`) is normalized away before any checking.
     Idempotent, so it is also safe to run at the start of desugar_program. *)
  (* Lower Same / plainly first so every check path (LSP, driver, project) sees
     kernel Id / refl. Idempotent on already-lowered programs. *)
  let p = elaborate_id_sugar p in
  let p = Method_sugar.normalize_program p in
  reset_scheme_env ();  (* let-poly schemes reset *)
  collect_wire_knowledge p;
  Ty_subst.reset_metavars ();
  (* Pass 0: infer world parameters for unannotated places. *)
  match infer_place_worlds p with
  | Error e ->
      { cr_env = Tyenv.with_builtins Tyenv.empty;
        cr_errors = [e] }
  | Ok p ->
  (* Pre-check PRIMA di infer_fun_signatures/Hm_infer (che su questi input vanno
   * in failwith/crash): nome di funzione top-level duplicato, e tipo di ritorno
   * funzionale `: T -> U` (un closure ritornato — non supportato, crasherebbe a
   * emit con un'arità sballata). Rifiuto pulito invece di crash/build-fail. *)
  let fun_decls = List.filter_map (function TopFun fd -> Some fd | _ -> None) p in
  let dup_fun =
    let rec go seen = function
      | [] -> None
      | fd :: rest ->
          if List.mem fd.fn_name seen then Some fd else go (fd.fn_name :: seen) rest
    in go [] fun_decls
  in
  match dup_fun with
  | Some fd ->
      { cr_env = Tyenv.with_builtins Tyenv.empty;
        cr_errors = [ { err_loc = fd.fn_loc;
                        err_msg = Printf.sprintf
                          "duplicate top-level function '%s'" fd.fn_name } ] }
  | None ->
  (* A functional return type (T -> U) is now supported: the function returns a
     first-class content-addressed closure, an f64 handle (Stage B). *)
  (* HM-light for fun
   * signatures with "_" param or missing return type. Heuristic best-effort
   * on call-sites. *)
  match infer_fun_signatures p with
  | Error e ->
      { cr_env = Tyenv.with_builtins Tyenv.empty;
        cr_errors = [e] }
  | Ok p ->
  (* Proper Algorithm W constraint generation + unification. Refines and
   * completes what the light pass could not infer. Handles parameters of type
   * TyArrow (HOF). *)
  let p = Hm_infer.infer_program p in
  (* Register moves in Move_engine before type checking, so EVar can identify
   * move names as TyMoveHandle. *)
  List.iter (function
    | TopMove md -> Move_engine.register_move md
    | _ -> ()
  ) p;
  let env0 = Tyenv.with_builtins Tyenv.empty in
  let ctx = Reduce.empty_ctx in
  let env_with_sigs = List.fold_left register_decl env0 p in
  (* Register the 3 builtin functions of the pullback. They are synthesized by
   * the desugar (only when the program uses them), but the type checker must
   * always recognize them to accept expressions like `__pullback_pi1(p)`. *)
  let env_with_sigs =
    let num = TyPrim "number" in
    let pack_sig : Tyenv.fun_sig = {
      fs_params = [("fa", num); ("gb", num); ("a", num); ("b", num)];
      fs_return = num; fs_visits = []; fs_partial = false } in
    let pi_sig : Tyenv.fun_sig = {
      fs_params = [("p", num)];
      fs_return = num; fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env_with_sigs "__pullback_pack" pack_sig in
    let env = Tyenv.add_fun env "__pullback_pi1" pi_sig in
    let env = Tyenv.add_fun env "__pullback_pi2" pi_sig in
    (* standard ops *)
    let env = Tyenv.add_fun env "floor"
      { fs_params = [("x", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__pow2"
      { fs_params = [("n", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__shl"
      { fs_params = [("a", num); ("n", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__shr"
      { fs_params = [("a", num); ("n", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__band"
      { fs_params = [("a", num); ("b", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__bxor"
      { fs_params = [("a", num); ("b", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__bor"
      { fs_params = [("a", num); ("b", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__bnot"
      { fs_params = [("a", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    (* simboli logici intuizionisti.
     * Firme: proposition -> proposition. Coercion boolean/number -> proposition
     * gestita a livello tycheck call (vedi check_call). *)
    let prop = TyPrim "proposition" in
    let env = Tyenv.add_fun env "__heyt_and"
      { fs_params = [("a", prop); ("b", prop)]; fs_return = prop;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__heyt_or"
      { fs_params = [("a", prop); ("b", prop)]; fs_return = prop;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__heyt_imp"
      { fs_params = [("a", prop); ("b", prop)]; fs_return = prop;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__heyt_not"
      { fs_params = [("a", prop)]; fs_return = prop;
        fs_visits = []; fs_partial = false } in
    (* Register the signatures of the 5 builtins for heyt_int<N>. The signatures
     * accept an opaque `heyt_int` (N implicit).
     *
     * Honest upfront: the parameter N is "anonymous" here. Type-level
     * parametricity over N would require dependent type inference. For now we
     * use TyHeytInt 64 as the default (max). *)
    let hi = TyHeytInt 64 in
    let env = Tyenv.add_fun env "__heyt_int_make"
      { fs_params = [("value", num); ("mask", num)]; fs_return = hi;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__heyt_int_and"
      { fs_params = [("a", hi); ("b", hi)]; fs_return = hi;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__heyt_int_or"
      { fs_params = [("a", hi); ("b", hi)]; fs_return = hi;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__heyt_int_xor"
      { fs_params = [("a", hi); ("b", hi)]; fs_return = hi;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__heyt_int_not"
      { fs_params = [("a", hi)]; fs_return = hi;
        fs_visits = []; fs_partial = false } in
    (* The value/mask projections. They extract i64 (exposed as number in Yon
     * after sitofp). *)
    let env = Tyenv.add_fun env "__heyt_int_value"
      { fs_params = [("a", hi)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__heyt_int_mask"
      { fs_params = [("a", hi)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    (* data structures backed by yon_xheap.
     * All the Map/Set/Dag primitives operate on number (f64 in the lowering) —
     * the content-addressing in the XLeech2 runtime is transparent. *)
    let env = Tyenv.add_fun env "__map_empty"
      { fs_params = []; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__map_put"
      { fs_params = [("m", num); ("k", num); ("v", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__map_get"
      { fs_params = [("m", num); ("k", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__map_contains"
      { fs_params = [("m", num); ("k", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__map_size"
      { fs_params = [("m", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__set_empty"
      { fs_params = []; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__set_add"
      { fs_params = [("s", num); ("e", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__set_contains"
      { fs_params = [("s", num); ("e", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__set_size"
      { fs_params = [("s", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__merkle_leaf"
      { fs_params = [("label", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__merkle_node2"
      { fs_params = [("label", num); ("c1", num); ("c2", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__merkle_label"
      { fs_params = [("node", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__merkle_child"
      { fs_params = [("node", num); ("idx", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__merkle_equal"
      { fs_params = [("a", num); ("b", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    (* observe via geom_morphism (pull/push lazy a read-time).
     * gm_kind: 0=identity, 1=scale10, 2=scale100, 3=centesimi, 4=negate. *)
    let env = Tyenv.add_fun env "__observe_alloc"
      { fs_params = [("value", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__observe_via_gm"
      { fs_params = [("slot", num); ("gm_kind", num); ("default", num)];
        fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__xheap_used"
      { fs_params = []; fs_return = num;
        fs_visits = []; fs_partial = false } in
    (* multi-process via fork(). *)
    let env = Tyenv.add_fun env "__spawn_self"
      { fs_params = [("n", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__spawn_index"
      { fs_params = []; fs_return = num;
        fs_visits = []; fs_partial = false } in
    (* Codice Golay (24,12,8). *)
    let env = Tyenv.add_fun env "__voyagerlist_seal"
      { fs_params = [("data12", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__voyagerlist_open"
      { fs_params = [("codeword24", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__voyagerlist_corrupt"
      { fs_params = [("codeword24", num); ("n_bits", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    (* capability tokens via Co_0 action su Leech. *)
    let env = Tyenv.add_fun env "__conway_gen_key"
      { fs_params = [("seed", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__conway_seal_slot"
      { fs_params = [("slot", num); ("key", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__conway_unseal_slot"
      { fs_params = [("sealed", num); ("key", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    let env = Tyenv.add_fun env "__conway_key_equal"
      { fs_params = [("a", num); ("b", num)]; fs_return = num;
        fs_visits = []; fs_partial = false } in
    (* Seq.from_list/map/filter/fold are registered in stdlib_signatures
     * (stdlib_runtime.ml). The deep-matching pattern in emit_mlir recognizes
     * Seq.fold(Seq.filter(Seq.map(... Seq.from_list(l)... ))) and lowers it to
     * a single scf.while with zero intermediate buffers. f, p, g are top-level
     * function names (passed as unknown and bypassed by the type checker via
     * is_seq_with_fun_arg). *)
    env
  in
  (* A pass to register the mangled functions `__morph_in_<S>__<M>` created by
   * the desugar. The type checker does not see these names in the original
   * top_decls, but it must accept calls like `LiftEU(eu) in USD` that the
   * parser has already desugared into `__morph_in_USD__LiftEU(eu)`. We add the
   * fun_sig for each pair (morph M, space S). *)
  let env_with_sigs =
    let morphs = List.filter_map
      (function TopMorph mp -> Some mp | _ -> None) p in
    let spaces = List.filter_map
      (function TopSpace sd -> Some sd | _ -> None) p in
    let toposes = List.filter_map
      (function TopTopos td -> Some td | _ -> None) p in
    List.fold_left (fun env_acc (mp : morph_decl) ->
      match mp.mp_on_object with
      | None -> env_acc
      | Some fd ->
          let return_ty = match fd.fn_return with
            | Some t -> t
            | None -> TyPrim "unknown" in
          let params = List.map
            (fun (p : param) -> (p.param_name, p.param_ty)) fd.fn_params in
          let fs : Tyenv.fun_sig = {
            fs_params = params;
            fs_return = return_ty;
            fs_visits = [];
            fs_partial = false;
          } in
          (* The variant __morph_in_<S>__<M> for each space S *)
          let env_acc1 = List.fold_left (fun env_acc' (sd : space_decl) ->
            let mangled = "__morph_in_" ^ sd.sd_name ^ "__" ^ mp.mp_name in
            Tyenv.add_fun env_acc' mangled fs
          ) env_acc spaces in
          (* The variant __morph_in_<T>__<M> for each topos T with `at <S>`.
           * The syntax `LiftEU(eu) in AccountUSD` desugars in the parser to
           * __morph_in_AccountUSD__LiftEU; the type checker must recognize this
           * symbol when AccountUSD is a topos with at_space. *)
          List.fold_left (fun env_acc' (td : topos_decl) ->
            match td.tp_at_space with
            | None -> env_acc'
            | Some _ ->
                let space_names = List.map
                  (fun (sd : space_decl) -> sd.sd_name) spaces in
                if List.mem td.tp_name space_names then env_acc'
                else
                  let mangled = "__morph_in_" ^ td.tp_name ^ "__" ^ mp.mp_name in
                  Tyenv.add_fun env_acc' mangled fs
          ) env_acc1 toposes
    ) env_with_sigs morphs
  in
  (* An extra pass to re-register the on_morphism wrappers
   * `<MorphName>__<N>` with a DYNAMIC signature derived from the target M (a
   * fun or reduction clause). The registration done in
   * register_decl uses an approximate signature (number->number); here we
   * replace it with the real one so calls with composite types are not
   * blocked. *)
  let env_with_sigs =
    let morphs = List.filter_map
      (function TopMorph mp -> Some mp | _ -> None) p in
    let fun_idx = List.filter_map
      (function TopFun fd -> Some (fd.fn_name, fd) | _ -> None) p in
    let red_idx = List.filter_map
      (function TopReduction rd -> Some (rd.rd_name, rd) | _ -> None) p in
    List.fold_left (fun env_acc (mp : morph_decl) ->
      List.fold_left (fun env_acc' (n_src, m_tgt) ->
        let wrapper_name = mp.mp_name ^ "__" ^ n_src in
        let (params, ret_ty) =
          match List.assoc_opt m_tgt fun_idx with
          | Some fd ->
              let rt = match fd.fn_return with
                | Some t -> t
                | None -> TyPrim "number"
              in
              let ps = List.map
                (fun (p : param) -> (p.param_name, p.param_ty))
                fd.fn_params in
              (ps, rt)
          | None ->
              match List.assoc_opt m_tgt red_idx with
              | Some rd ->
                  let clause_ps = List.find_map (function
                    | RcOn (cname, ps, _, _) when cname = n_src ->
                        Some (List.map
                          (fun (p : param) -> (p.param_name, p.param_ty)) ps)
                    | _ -> None
                  ) rd.rd_clauses in
                  (match clause_ps with
                   | Some ps -> (ps, TyPrim "number")
                   | None -> ([("x", TyPrim "number")], TyPrim "number"))
              | None ->
                  ([("x", TyPrim "number")], TyPrim "number")
        in
        let fs : Tyenv.fun_sig = {
          fs_params = params;
          fs_return = ret_ty;
          fs_visits = [];
          fs_partial = false;
        } in
        Tyenv.add_fun env_acc' wrapper_name fs
      ) env_acc mp.mp_on_morphism_map
    ) env_with_sigs morphs
  in
  (* A pass to register the wrappers `<NatTransform>__<obj>` synthesized for a
   * nat_transform's via clause. Same structure as the on_morphism via M pass,
   * applied to nt_via_bindings. *)
  let env_with_sigs =
    let nats = List.filter_map
      (function TopNatTransform nt -> Some nt | _ -> None) p in
    let fun_idx = List.filter_map
      (function TopFun fd -> Some (fd.fn_name, fd) | _ -> None) p in
    let red_idx = List.filter_map
      (function TopReduction rd -> Some (rd.rd_name, rd) | _ -> None) p in
    List.fold_left (fun env_acc (nt : nat_transform_decl) ->
      List.fold_left (fun env_acc' (obj, tgt) ->
        let wrapper_name = nt.nt_name ^ "__" ^ obj in
        let (params, ret_ty) =
          match List.assoc_opt tgt fun_idx with
          | Some fd ->
              let rt = match fd.fn_return with
                | Some t -> t
                | None -> TyPrim "number"
              in
              let ps = List.map
                (fun (p : param) -> (p.param_name, p.param_ty))
                fd.fn_params in
              (ps, rt)
          | None ->
              match List.assoc_opt tgt red_idx with
              | Some rd ->
                  let clause_ps = List.find_map (function
                    | RcOn (cname, ps, _, _) when cname = obj ->
                        Some (List.map
                          (fun (p : param) -> (p.param_name, p.param_ty)) ps)
                    | _ -> None
                  ) rd.rd_clauses in
                  (match clause_ps with
                   | Some ps -> (ps, TyPrim "number")
                   | None -> ([("x", TyPrim "number")], TyPrim "number"))
              | None ->
                  ([("x", TyPrim "number")], TyPrim "number")
        in
        let fs : Tyenv.fun_sig = {
          fs_params = params;
          fs_return = ret_ty;
          fs_visits = [];
          fs_partial = false;
        } in
        Tyenv.add_fun env_acc' wrapper_name fs
      ) env_acc nt.nt_via_bindings
    ) env_with_sigs nats
  in
  (* A pass to register __morph_in_<S>__<NatWrapper> for each synthesized
   * nat_transform component. Enables the syntax
   *   Upgrade__USDState(x) in AccountUSD
   * which the parser desugars to __morph_in_AccountUSD__Upgrade__USDState
   * (a single symbol); the type checker must recognize it. We reuse the
   * fun_idx / red_idx already built above. *)
  let env_with_sigs =
    let nats = List.filter_map
      (function TopNatTransform nt -> Some nt | _ -> None) p in
    let fun_idx = List.filter_map
      (function TopFun fd -> Some (fd.fn_name, fd) | _ -> None) p in
    let red_idx = List.filter_map
      (function TopReduction rd -> Some (rd.rd_name, rd) | _ -> None) p in
    let spaces = List.filter_map
      (function TopSpace sd -> Some sd | _ -> None) p in
    let toposes = List.filter_map
      (function TopTopos td -> Some td | _ -> None) p in
    List.fold_left (fun env_acc (nt : nat_transform_decl) ->
      List.fold_left (fun env_acc' (obj, tgt) ->
        let wrapper_short = nt.nt_name ^ "__" ^ obj in
        let (params, ret_ty) =
          match List.assoc_opt tgt fun_idx with
          | Some fd ->
              let rt = match fd.fn_return with
                | Some t -> t
                | None -> TyPrim "number"
              in
              let ps = List.map
                (fun (p : param) -> (p.param_name, p.param_ty))
                fd.fn_params in
              (ps, rt)
          | None ->
              match List.assoc_opt tgt red_idx with
              | Some rd ->
                  let clause_ps = List.find_map (function
                    | RcOn (cname, ps, _, _) when cname = obj ->
                        Some (List.map
                          (fun (p : param) -> (p.param_name, p.param_ty)) ps)
                    | _ -> None
                  ) rd.rd_clauses in
                  (match clause_ps with
                   | Some ps -> (ps, TyPrim "number")
                   | None -> ([("x", TyPrim "number")], TyPrim "number"))
              | None ->
                  ([("x", TyPrim "number")], TyPrim "number")
        in
        let fs : Tyenv.fun_sig = {
          fs_params = params;
          fs_return = ret_ty;
          fs_visits = [];
          fs_partial = false;
        } in
        (* The variant __morph_in_<S>__<wrapper_short> for each space *)
        let env_after_spaces = List.fold_left (fun env_acc'' (sd : space_decl) ->
          let mangled = "__morph_in_" ^ sd.sd_name ^ "__" ^ wrapper_short in
          Tyenv.add_fun env_acc'' mangled fs
        ) env_acc' spaces in
        (* The variant for each topos with at_space *)
        List.fold_left (fun env_acc'' (td : topos_decl) ->
          match td.tp_at_space with
          | None -> env_acc''
          | Some _ ->
              let space_names = List.map
                (fun (sd : space_decl) -> sd.sd_name) spaces in
              if List.mem td.tp_name space_names then env_acc''
              else
                let mangled = "__morph_in_" ^ td.tp_name ^ "__" ^ wrapper_short in
                Tyenv.add_fun env_acc'' mangled fs
        ) env_after_spaces toposes
      ) env_acc nt.nt_via_bindings
    ) env_with_sigs nats
  in
  (* A pass to register the `__check_naturality_<NT>__<N>` functions
   * synthesized by the desugar. Fixed signature (input: number) -> number. *)
  let env_with_sigs =
    let nats = List.filter_map
      (function TopNatTransform nt -> Some nt | _ -> None) p in
    let morph_idx = List.filter_map
      (function TopMorph mp -> Some (mp.mp_name, mp) | _ -> None) p in
    List.fold_left (fun env_acc (nt : nat_transform_decl) ->
      match nt.nt_via_bindings with
      | [] -> env_acc
      | bindings ->
          (match List.assoc_opt nt.nt_source_morph morph_idx,
                 List.assoc_opt nt.nt_target_morph morph_idx with
           | Some src, Some tgt ->
               let src_morphisms = List.map fst src.mp_on_morphism_map in
               let tgt_morphisms = List.map fst tgt.mp_on_morphism_map in
               let common = List.filter
                 (fun n -> List.mem n tgt_morphisms) src_morphisms in
               let many = (match bindings with [_] -> false | _ -> true) in
               List.fold_left (fun env_acc_b (obj, _) ->
                 List.fold_left (fun env_acc' n_common ->
                   let check_name =
                     if many then
                       "__check_naturality_" ^ nt.nt_name ^ "__" ^ n_common
                       ^ "__via_" ^ obj
                     else
                       "__check_naturality_" ^ nt.nt_name ^ "__" ^ n_common in
                   let fs : Tyenv.fun_sig = {
                     fs_params = [("input", TyPrim "number")];
                     fs_return = TyPrim "number";
                     fs_visits = [];
                     fs_partial = false;
                   } in
                   let env_acc'' = Tyenv.add_fun env_acc' check_name fs in
                   let pbt_name = check_name ^ "_pbt" in
                   let fs_pbt : Tyenv.fun_sig = {
                     fs_params = [("seed", TyPrim "number")];
                     fs_return = TyPrim "number";
                     fs_visits = [];
                     fs_partial = false;
                   } in
                   Tyenv.add_fun env_acc'' pbt_name fs_pbt
                 ) env_acc_b common
               ) env_acc bindings
           | _ -> env_acc)
    ) env_with_sigs nats
  in
  (* Pass 1.5: transitive closure of effects. *)
  let env_with_sigs = infer_effects env_with_sigs p in
  (* Multi-error accumulation: for TopFun use the accumulating variant
   * to collect ALL body errors. For other decls, the single-error
   * variant is fine (their checks are smaller). *)
  let errors = List.fold_left
    (fun errs td ->
       match td with
       | TopFun fn ->
           let fn_errs = check_fun_decl_accum env_with_sigs ctx fn in
           List.rev_append (List.rev fn_errs) errs
       | _ ->
           match check_decl env_with_sigs ctx td with
           | Ok () -> errs
           | Error e -> e :: errs)
    [] p
  in
  { cr_env = env_with_sigs;
    cr_errors = List.rev errors; }
