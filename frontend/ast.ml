(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* ast.ml — abstract syntax tree for Yon Core
 *
 * Implements the six primitives + two derived constructs specified in
 * Yon Core §2:
 *   1. Variable                  — x
 *   2. Lambda abstraction        — lambdax:T.t
 *   3. Application               — t u
 *   4. Place                     — [P : Site -> Type]
 *   5. Reduction                 — {R : P -> handler}
 *   6. Scope                     — ⟨t⟩_S
 * plus derived:
 *   - with R in t                — handler activation
 *   - emit t                     — stream emission
 *
 * Variables use a string-name representation here for clarity.
 * For production-grade work, de Bruijn indices avoid alpha-renaming
 * issues; we'll switch later if needed. For the prototype, names
 * suffice and make debugging traceable.
 *)

(* Types in Yon Core kernel — the small dependent type theory used
 * for the operational semantics.
 *
 * Yon Core §2 (extended for HoTT):
 *   T, U ::= Type_n                            universe of level n
 *         |  Pi(x:T). U                         dependent function
 *         |  Sigma(x:T). U                         dependent pair
 *         |  Id_T(t, u)                        identity (path) type
 *         |  T -> U                             non-dependent arrow (Pi with unused binder)
 *         |  P                                 named place
 *         |  stream T                          stream
 *         |  text | number | boolean | ...     base types
 *
 * Universe levels are Russell-predicative: Type_n : Type_{n+1}.
 * Cumulativity is admitted at the type-checker level (Type_n <: Type_{n+1}).
 *)
type ty =
  | TyType of int                              (* Type_n : Type_{n+1} *)
  | TyArrow of ty * ty                         (* T -> U (non-dep) *)
  | TyPi of string * ty * ty                   (* Pi(x:T). U(x) *)
  | TySigma of string * ty * ty                (* Sigma(x:T). U(x) *)
  | TyId of ty * term * term                   (* Id_T(t, u) — path equality *)
  | TyDirUniverse of int                       (* U_omega level n: directed object
                                                  classifier, Tarski-style. Its
                                                  inhabitants are CODES (terms),
                                                  not types; decode with TyEl.
                                                  Lives as an object in CaTT's
                                                  globular tower, so directed
                                                  1-cells between codes are CaTT
                                                  cells (no new Id primitive). *)
  | TyEl of term                               (* El(c): decode a code term c : U_omega
                                                  into the Core type it names.
                                                  Tarski decoding. ty depends on a
                                                  term, exactly as TyId already does. *)
  | TyPlace of string                          (* a named place, e.g. Order *)
  | TyStream of ty                             (* stream of T *)
  | TyGlue of ty * face_formula * (ty * term) list  (* Glue [phi |-> (T, e)] A *)
  | TyPathP of (string * ty) * term * term     (* PathP (<i> A) x y : dependent path; i binds in A, x:A0, y:A1 *)

(* Operations on a place-with-effects: name + parameter types + return type.
 *)
and op_sig = {
  op_name : string;
  op_params : (string * ty) list;
  op_return : ty;
  op_algebra : string option;   (* catalog algebra, if present *)
}

(* A handler clause: when this operation is invoked, run this body
 * with these formal parameters bound. *)
and handler_clause = {
  hc_op : string;                   (* operation name being handled *)
  hc_params : (string * ty) list;
  hc_body : term;
}

and interval =
  | I0
  | I1
  | IVar of string
  | IMin of interval * interval
  | IMax of interval * interval
  | INeg of interval

and face_atom = string * bool
and face = face_atom list
and face_formula = face list

and term =
  | Var of string
  (* Locally-nameless (de Bruijn) migration is SUSPENDED: the BVar/FVar
   * constructors and their shift/open/close machinery live in
   * locally_nameless.ml, kept out of the build until the migration is wired
   * into the pipeline. The kernel term type stays on the legacy `Var`. *)
  | Lam of string * ty * term
  | App of term * term
  | Place of place_decl
  | Reduction of reduction_decl
  | World of world_decl                        (* a reified site C(W): its
                                                  objects and the generators of
                                                  its Grothendieck topology J *)
  | Scope of string * term
  | Emit of term
  | Refl of term
  | J of string * ty * term * term * term * term
  | Pair of term * term
  | Fst of term
  | Snd of term
  | StreamCons of term * term
  | Unit
  | PLam of string * term            (* <i> t — path abstraction *)
  | PApp of term * interval          (* p @ r — path application *)
  | Transp of (string * ty) * term   (* transport along type line <i>A *)
  | Comp of ty * face_formula * (string * face * term) list * term
  | HComp of ty * face_formula * (string * face * term) list * term
  | GlueElem of face_formula * term * term  (* glue [phi |-> t] a *)
  | Unglue of term                          (* unglue projector *)
  | HITElim of (string * string list * term) list * term
      (* generic HIT eliminator: constructor, payload binders, branch body *)
  | HITConstr of string * term list         (* HIT constructor application:
                                               base, loop, north, merid x, ... *)

and place_decl = {
  p_name : string;
  p_site : ty;
  p_fields : (string * ty) list;
  p_operations : op_sig list;
  p_laws : string list;          (* algebraic laws declared on the place *)
}

and reduction_decl = {
  r_name : string;
  r_target : string;
  r_handlers : handler_clause list;
  r_multi_shot : bool;
  r_fold_name : string option;       (* canonical fold name, declared explicitly via `fold "..."` (no longer inferred) *)
}

(* A generator of the Grothendieck topology J on the site C(W). Each way of
 * BUILDING a world contributes one covering generator; J(W) is the join of
 * these in the (complete) lattice of topologies. A bare world (only objects,
 * no construction) has NO generators: J is trivial, Sh = PSh, every place is
 * vacuously a sheaf. The categorical PRODUCT (a limit, not a colimit) is
 * intentionally NOT a generator — only colimit-style constructions cover. *)
and site_generator =
  | GenCoproduct of string list                (* world C = A + B + ... : the
                                                  injections cover disjointly *)
  | GenQuotient of string * string             (* world Q = W / Rel : the R-classes
                                                  cover W (quotient topology) *)
  | GenCoequalizer of string * string * string (* world Q = coeq(f,g : A -> B) *)
  | GenSubset of string                        (* world S subset of V : the dense
                                                  inclusion S ↪ V generates a cover *)

(* A reified site C(W): the world as a first-class Core citizen, alongside
 * place_decl. Its objects are the world's inhabitants (the carriers of C(W));
 * its topology J is given intensionally by its generators (get_J reads them).
 * A place living in W is a presheaf on this site; "P is a sheaf" is then a
 * predicate of P against w_generators (the Yoneda continuity condition). *)
and world_decl = {
  w_name : string;
  w_objects : string list;           (* the inhabitants of W = objects of C(W) *)
  w_generators : site_generator list;(* the generators of the topology J(W) *)
}

(* For testing and debugging, define a way to make terms readable.
 * The pretty-printer lives in pretty.ml; here we just need
 * structural equality for tests.
 *
 * de Bruijn migration, stadio 3: term_equal is now ALPHA-EQUIVALENCE. A
 * renaming environment threads pairs (name-in-t1, name-in-t2) of the binders
 * crossed so far, innermost first. At a bound Var the comparison is by DEPTH in
 * that environment — the depth is exactly the de Bruijn index — so two terms
 * that differ only in bound names compare equal: (fun x. x) = (fun y. y).
 * Free variables (not in the env) compare by name; BVar by index; FVar by name.
 * Scope/With names are Space/reduction labels (semantically meaningful, not
 * alpha-renameable) so they stay literal. Lam binders are made alpha; the J
 * motive and TyPi/TySigma binders are compared literally for now (conservative:
 * no false identifications) until their binding arity is pinned down with full
 * bidirectional typing — the env is still threaded through their subterms so
 * alpha works for any Lam nested inside them. *)
(* Identity registry of the CORE place decls that came from prelude files.
   Site-keyed by construction (physical identity, not name): a user place
   sharing a prelude place's name is a DIFFERENT decl and is never caught
   by this list. Reset by Desugar at each program entry. *)
let prelude_place_decls : place_decl list ref = ref []

let var_alpha env x y =
  let rec ldepth l i = match l with
    | [] -> None | (a, _) :: r -> if a = x then Some i else ldepth r (i + 1) in
  let rec rdepth l i = match l with
    | [] -> None | (_, b) :: r -> if b = y then Some i else rdepth r (i + 1) in
  match ldepth env 0, rdepth env 0 with
  | Some i, Some j -> i = j          (* both bound: alpha iff same de Bruijn depth *)
  | None, None -> x = y              (* both free: by name *)
  | _ -> false                       (* one bound, one free: distinct *)

let rec interval_equal i1 i2 =
  match i1, i2 with
  | I0, I0 | I1, I1 -> true
  | IVar a, IVar b -> a = b
  | IMin (a1, b1), IMin (a2, b2)
  | IMax (a1, b1), IMax (a2, b2) ->
      interval_equal a1 a2 && interval_equal b1 b2
  | INeg a, INeg b -> interval_equal a b
  | _ -> false

let rec term_equal_env env t1 t2 =
  match t1, t2 with
  | Var x, Var y -> var_alpha env x y
  | Lam (x, tx, b1), Lam (y, ty', b2) ->
      ty_equal_env env tx ty' && term_equal_env ((x, y) :: env) b1 b2
  | App (f1, a1), App (f2, a2) ->
      term_equal_env env f1 f2 && term_equal_env env a1 a2
  | Place p1, Place p2 -> place_equal p1 p2
  | Reduction r1, Reduction r2 -> reduction_equal r1 r2
  | World w1, World w2 -> world_equal w1 w2
  | Scope (s1, b1), Scope (s2, b2) -> s1 = s2 && term_equal_env env b1 b2
  | Emit t1', Emit t2' -> term_equal_env env t1' t2'
  | Refl t1', Refl t2' -> term_equal_env env t1' t2'
  | J (x1, a1, c1, d1, p1, b1), J (x2, a2, c2, d2, p2, b2) ->
      x1 = x2 && ty_equal_env env a1 a2
      && term_equal_env env c1 c2 && term_equal_env env d1 d2
      && term_equal_env env p1 p2 && term_equal_env env b1 b2
  | Pair (a1, b1), Pair (a2, b2) ->
      term_equal_env env a1 a2 && term_equal_env env b1 b2
  | Fst t1', Fst t2' -> term_equal_env env t1' t2'
  | Snd t1', Snd t2' -> term_equal_env env t1' t2'
  | StreamCons (h1, k1), StreamCons (h2, k2) ->
      term_equal_env env h1 h2 && term_equal_env env k1 k2
  | Unit, Unit -> true
  | PLam (i1, b1), PLam (i2, b2) ->
      i1 = i2 && term_equal_env env b1 b2
  | PApp (p1, r1), PApp (p2, r2) ->
      term_equal_env env p1 p2 && interval_equal r1 r2
  | Transp ((i1, a1), b1), Transp ((i2, a2), b2) ->
      i1 = i2 && ty_equal_env env a1 a2 && term_equal_env env b1 b2
  | Comp (a1, p1, s1, b1), Comp (a2, p2, s2, b2)
  | HComp (a1, p1, s1, b1), HComp (a2, p2, s2, b2) ->
      ty_equal_env env a1 a2 && p1 = p2
      && List.length s1 = List.length s2
      && List.for_all2
           (fun (i1, f1, t1) (i2, f2, t2) ->
             i1 = i2 && f1 = f2 && term_equal_env env t1 t2)
           s1 s2
      && term_equal_env env b1 b2
  | GlueElem (p1, t1, a1), GlueElem (p2, t2, a2) ->
      p1 = p2 && term_equal_env env t1 t2 && term_equal_env env a1 a2
  | Unglue a, Unglue b -> term_equal_env env a b
  | HITElim (br1, s1), HITElim (br2, s2) ->
      List.length br1 = List.length br2
      && List.for_all2
           (fun (n1, vs1, b1) (n2, vs2, b2) ->
             n1 = n2 && List.length vs1 = List.length vs2
             && term_equal_env (List.combine vs1 vs2 @ env) b1 b2) br1 br2
      && term_equal_env env s1 s2
  | HITConstr (n1, a1), HITConstr (n2, a2) ->
      n1 = n2 && List.length a1 = List.length a2
      && List.for_all2 (term_equal_env env) a1 a2
  | _ -> false

and ty_equal_env env t1 t2 =
  match t1, t2 with
  | TyType n1, TyType n2 -> n1 = n2
  | TyArrow (a1, b1), TyArrow (a2, b2) ->
      ty_equal_env env a1 a2 && ty_equal_env env b1 b2
  | TyPi (x1, a1, b1), TyPi (x2, a2, b2) ->
      x1 = x2 && ty_equal_env env a1 a2 && ty_equal_env env b1 b2
  | TySigma (x1, a1, b1), TySigma (x2, a2, b2) ->
      x1 = x2 && ty_equal_env env a1 a2 && ty_equal_env env b1 b2
  | TyId (a1, x1, y1), TyId (a2, x2, y2) ->
      ty_equal_env env a1 a2 && term_equal_env env x1 x2 && term_equal_env env y1 y2
  | TyDirUniverse n1, TyDirUniverse n2 -> n1 = n2
  | TyEl c1, TyEl c2 -> term_equal_env env c1 c2
  | TyPlace n1, TyPlace n2 -> n1 = n2
  | TyStream t1', TyStream t2' -> ty_equal_env env t1' t2'
  | _ -> false

and term_equal t1 t2 = term_equal_env [] t1 t2
and ty_equal t1 t2 = ty_equal_env [] t1 t2

and place_equal p1 p2 =
  p1.p_name = p2.p_name
  && ty_equal p1.p_site p2.p_site
  && List.length p1.p_fields = List.length p2.p_fields
  && List.for_all2
       (fun (n1, t1) (n2, t2) -> n1 = n2 && ty_equal t1 t2)
       p1.p_fields p2.p_fields
  && List.length p1.p_operations = List.length p2.p_operations
  && List.for_all2 op_sig_equal p1.p_operations p2.p_operations

and op_sig_equal o1 o2 =
  o1.op_name = o2.op_name
  && List.length o1.op_params = List.length o2.op_params
  && List.for_all2
       (fun (n1, t1) (n2, t2) -> n1 = n2 && ty_equal t1 t2)
       o1.op_params o2.op_params
  && ty_equal o1.op_return o2.op_return

and reduction_equal r1 r2 =
  r1.r_name = r2.r_name
  && r1.r_target = r2.r_target
  && r1.r_multi_shot = r2.r_multi_shot
  && List.length r1.r_handlers = List.length r2.r_handlers
  && List.for_all2 handler_equal r1.r_handlers r2.r_handlers

and handler_equal h1 h2 =
  h1.hc_op = h2.hc_op
  && List.length h1.hc_params = List.length h2.hc_params
  && List.for_all2
       (fun (n1, t1) (n2, t2) -> n1 = n2 && ty_equal t1 t2)
       h1.hc_params h2.hc_params
  && term_equal h1.hc_body h2.hc_body

and world_equal w1 w2 =
  w1.w_name = w2.w_name
  && w1.w_objects = w2.w_objects
  && w1.w_generators = w2.w_generators

(* Free variables of a term. Used by substitution to detect capture.
 *)
let rec free_vars t =
  let module S = Set.Make (String) in
  match t with
  | Var x -> S.singleton x
  | Lam (x, _, b) -> S.remove x (free_vars b)
  | App (f, a) -> S.union (free_vars f) (free_vars a)
  | Place _ -> S.empty
  | World _ -> S.empty
  | Reduction r ->
      List.fold_left
        (fun acc h ->
          let bound = List.map fst h.hc_params in
          let body_fv = free_vars h.hc_body in
          let body_fv' = List.fold_left (fun s b -> S.remove b s) body_fv bound in
          S.union acc body_fv')
        S.empty r.r_handlers
  | Scope (_, b) -> free_vars b
  | Emit t' -> free_vars t'
  | Refl t' -> free_vars t'
  | J (_x, _a, c, d, p, b) ->
      (* The binder x is for the motive C; not bound in the other args
       * at this level. free_vars conservatively unions everything. *)
      S.union (free_vars c)
        (S.union (free_vars d) (S.union (free_vars p) (free_vars b)))
  | Pair (a, b) -> S.union (free_vars a) (free_vars b)
  | Fst t' -> free_vars t'
  | Snd t' -> free_vars t'
  | StreamCons (h, k) -> S.union (free_vars h) (free_vars k)
  | Unit -> S.empty
  | PLam (_i, t') -> free_vars t'
  | PApp (p, _r) -> free_vars p
  | Transp ((_i, _a), t') -> free_vars t'
  | Comp (_, _, sides, base) | HComp (_, _, sides, base) ->
      List.fold_left (fun acc (_, _, t') -> S.union acc (free_vars t'))
        (free_vars base) sides
  | GlueElem (_, t', a') -> S.union (free_vars t') (free_vars a')
  | Unglue t' -> free_vars t'
  | HITElim (branches, scrut) ->
      List.fold_left (fun acc (_, vars, b) ->
        let fv = List.fold_left (fun s v -> S.remove v s) (free_vars b) vars in
        S.union acc fv)
        (free_vars scrut) branches
  | HITConstr (_, args) ->
      List.fold_left (fun acc a -> S.union acc (free_vars a)) S.empty args

(* Generate a fresh variable not in a given set.
 * Used by substitution for alpha-renaming on the fly.
 *)
let fresh_var =
  let counter = ref 0 in
  fun avoid_set ->
    let module S = Set.Make (String) in
    let rec try_name n =
      let candidate = Printf.sprintf "_fresh_%d" n in
      if S.mem candidate avoid_set then try_name (n + 1)
      else (
        counter := n + 1;
        candidate)
    in
    try_name !counter
