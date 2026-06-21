(* ty_subst.ml — Algorithm W foundations for Yon HM type inference
 *
 * Sources:
 *   - Damas-Milner 1982, "Principal type-schemes for functional programs"
 *   - Robinson 1965, "A machine-oriented logic based on the resolution principle"
 *   - Pierce 2002, TAPL ch.22 (Type Reconstruction)
 *
 * What it does:
 *   - Fresh tyvars a0, a1, a2, ... via a global counter
 *   - Substitution map [a |-> T]
 *   - apply_subst: applies a substitution to a type
 *   - unify: attempts bidirectional unification of two types, returns a
 *     substitution (Most General Unifier, Robinson 1965) or an error
 *   - occur_check: prevents a = list of a (infinite type)
 *   - generalize: env, ty -> type_scheme (forall a. T)
 *   - instantiate: type_scheme -> fresh ty (for each call site)
 *
 * Declared limits:
 *   - Does not handle polymorphic recursion (requires a Mycroft-Tofte fixpoint)
 *   - Does not handle row polymorphism (for record extension)
 *   - Works on surface ty; CATT_R_Yon rewrites stay in the dispatcher
 *)

open Surface_ast

(* ─── Fresh tyvar generation ─────────────────────────────────────────── *)

let metavar_counter = ref 0

let reset_metavars () = metavar_counter := 0

let fresh_metavar () : ty =
  let n = !metavar_counter in
  incr metavar_counter;
  TyMetaVar n

(* ─── Substitution ───────────────────────────────────────────────────── *)

(* A substitution is a finite map from meta-variable id to type.
 * Representation: association list (simple, efficient for small n). *)
type subst = (int * ty) list

let empty_subst : subst = []

(* apply_subst sigma t: apply sigma to t, replacing each TyMetaVar n
 * present in sigma with the associated type.
 *
 * Idempotence: we assume sigma is already idempotent
 * (apply_subst sigma (sigma applied to t) = sigma applied to t).
 * This is guaranteed if sigma is built only via compose_subst. *)
let rec apply_subst (sigma : subst) (t : ty) : ty =
  match t with
  | TyMetaVar n ->
      (match List.assoc_opt n sigma with
       | Some t' -> apply_subst sigma t'  (* segui catene transitive *)
       | None -> t)
  | TyList inner -> TyList (apply_subst sigma inner)
  | TyMap (k, v) -> TyMap (apply_subst sigma k, apply_subst sigma v)
  | TyStream inner -> TyStream (apply_subst sigma inner)
  | TyPi (x, a, b) -> TyPi (x, apply_subst sigma a, apply_subst sigma b)
  | TySigma (x, a, b) -> TySigma (x, apply_subst sigma a, apply_subst sigma b)
  | TyId (a, x, y) -> TyId (apply_subst sigma a, x, y)
  | TyPathP ((i, a), x, y) -> TyPathP ((i, apply_subst sigma a), x, y)
  | TyArrow (a, b) -> TyArrow (apply_subst sigma a, apply_subst sigma b)
  | TyMoveHandle (_, _) -> t   (* move handles contain no meta-variables *)
  | TyReductionHandle _ -> t   (* reduction handles contain no meta-variables *)
  | TyMorphHandle (_, _) -> t  (* morph handles do not contain metavars *)
  | TyViewHandle _ -> t        (* view handles do not contain metavars *)
  | TyWire _ -> t              (* wire handle carries only a Space name *)
  | TySubscription (sp, inner) -> TySubscription (sp, apply_subst sigma inner)
  | TySum variants ->
      TySum (List.map (fun v ->
        { v with v_args = List.map (apply_subst sigma) v.v_args }) variants)
  | TySumIn (variants, ws) ->
      TySumIn (List.map (fun v ->
        { v with v_args = List.map (apply_subst sigma) v.v_args }) variants, ws)
  | TyPrim _ | TyPrimIn _ | TyUser _ | TyVar _
  | TyUniverse _ | TyHeytInt _ | TyEl _ -> t

(* compose_subst sigma1 sigma2: equivalent to "apply sigma1 after sigma2".
 * Result: { x |-> sigma1(t) | (x,t) in sigma2 } union { (x,t) in sigma1 | x not in dom(sigma2) }
 *
 * Important: sigma1 is applied to the RHS of sigma2 as well, not only to
 * outside types. This guarantees idempotence of the result. *)
let compose_subst (sigma1 : subst) (sigma2 : subst) : subst =
  let sigma2_applied =
    List.map (fun (x, t) -> (x, apply_subst sigma1 t)) sigma2
  in
  let dom2 = List.map fst sigma2 in
  let sigma1_filtered =
    List.filter (fun (x, _) -> not (List.mem x dom2)) sigma1
  in
  sigma2_applied @ sigma1_filtered

(* ─── Free meta-variables ────────────────────────────────────────────── *)

let rec free_metavars (t : ty) : int list =
  match t with
  | TyMetaVar n -> [n]
  | TyList inner -> free_metavars inner
  | TyMap (k, v) -> free_metavars k @ free_metavars v
  | TyStream inner -> free_metavars inner
  | TyPi (_, a, b) | TySigma (_, a, b) -> free_metavars a @ free_metavars b
  | TyId (a, _, _) -> free_metavars a
  | TyPathP ((_, a), _, _) -> free_metavars a
  | TyArrow (a, b) -> free_metavars a @ free_metavars b
  | TyMoveHandle (_, _) -> []
  | TyReductionHandle _ -> []
  | TyMorphHandle (_, _) -> []
  | TyViewHandle _ -> []
  | TyWire _ -> []
  | TySubscription (_, inner) -> free_metavars inner
  | TySum variants | TySumIn (variants, _) ->
      List.concat_map (fun v -> List.concat_map free_metavars v.v_args) variants
  | TyPrim _ | TyPrimIn _ | TyUser _ | TyVar _
  | TyUniverse _ | TyHeytInt _ | TyEl _ -> []

let uniq (xs : 'a list) : 'a list =
  List.fold_left (fun acc x -> if List.mem x acc then acc else x :: acc) [] xs

(* ─── Occur check ────────────────────────────────────────────────────── *)

(* occur_check n t: returns true if TyMetaVar n occurs (free) in t.
 * Needed to avoid cyclic unifications like alpha = list of alpha that would
 * create infinite types. *)
let occur_check (n : int) (t : ty) : bool =
  List.mem n (free_metavars t)

(* ─── Unification (Robinson 1965) ────────────────────────────────────── *)

type unify_error =
  | UMismatch of ty * ty
  | UOccurCheck of int * ty

exception Unify_failure of unify_error

let unify_error_to_string = function
  | UMismatch (a, b) ->
      Printf.sprintf "type mismatch: cannot unify %s with %s"
        (Tyenv.ty_to_string a) (Tyenv.ty_to_string b)
  | UOccurCheck (n, t) ->
      Printf.sprintf "occur check failed: alpha%d would occur in %s (infinite type)"
        n (Tyenv.ty_to_string t)

(* unify a b: returns the most general unifier sigma such that
 * apply_subst sigma a = apply_subst sigma b. *)
let rec unify (a : ty) (b : ty) : subst =
  match a, b with
  | TyMetaVar n, TyMetaVar m when n = m -> empty_subst
  | TyMetaVar n, t | t, TyMetaVar n ->
      if occur_check n t then
        raise (Unify_failure (UOccurCheck (n, t)))
      else [(n, t)]
  (* TyVar (a generic binder) unifies with anything, but does NOT generate a
   * substitution, because TyVar is an existential placeholder (a forall
   * parameter in an explicit signature), not a meta-variable. *)
  | TyVar _, _ | _, TyVar _ -> empty_subst
  (* Primitive types: strict equality of name *)
  | TyPrim n1, TyPrim n2 when n1 = n2 -> empty_subst
  (* "unknown" unifies with anything (a generic placeholder) *)
  | TyPrim "unknown", _ | _, TyPrim "unknown" -> empty_subst
  | TyPrimIn (n1, ws1), TyPrimIn (n2, ws2)
      when n1 = n2 && ws1 = ws2 -> empty_subst
  | TyUser n1, TyUser n2 when n1 = n2 -> empty_subst
  | TyList a1, TyList a2 -> unify a1 a2
  | TyMap (k1, v1), TyMap (k2, v2) ->
      let s1 = unify k1 k2 in
      let s2 = unify (apply_subst s1 v1) (apply_subst s1 v2) in
      compose_subst s2 s1
  | TyStream i1, TyStream i2 -> unify i1 i2
  | TyPi (_, a1, b1), TyPi (_, a2, b2)
  | TySigma (_, a1, b1), TySigma (_, a2, b2) ->
      let s1 = unify a1 a2 in
      let s2 = unify (apply_subst s1 b1) (apply_subst s1 b2) in
      compose_subst s2 s1
  | TyUniverse n1, TyUniverse n2 when n1 = n2 -> empty_subst
  | TyHeytInt n1, TyHeytInt n2 when n1 = n2 -> empty_subst
  | TyArrow (a1, b1), TyArrow (a2, b2) ->
      let s1 = unify a1 a2 in
      let s2 = unify (apply_subst s1 b1) (apply_subst s1 b2) in
      compose_subst s2 s1
  | TyMoveHandle (w1a, w2a), TyMoveHandle (w1b, w2b) ->
      (* None unifies with any world (wildcard). *)
      let compatible_w a b = match a, b with
        | None, _ | _, None -> true
        | Some n1, Some n2 -> n1 = n2
      in
      if compatible_w w1a w1b && compatible_w w2a w2b then empty_subst
      else raise (Unify_failure (UMismatch (a, b)))
  | TyReductionHandle pa, TyReductionHandle pb ->
      let compatible_p x y = match x, y with
        | None, _ | _, None -> true
        | Some n1, Some n2 -> n1 = n2
      in
      if compatible_p pa pb then empty_subst
      else raise (Unify_failure (UMismatch (a, b)))
  | TyMorphHandle (s1a, s2a), TyMorphHandle (s1b, s2b) ->
      let compat x y = match x, y with
        | None, _ | _, None -> true
        | Some n1, Some n2 -> n1 = n2
      in
      if compat s1a s1b && compat s2a s2b then empty_subst
      else raise (Unify_failure (UMismatch (a, b)))
  | TyViewHandle pa, TyViewHandle pb ->
      let compat x y = match x, y with
        | None, _ | _, None -> true
        | Some n1, Some n2 -> n1 = n2
      in
      if compat pa pb then empty_subst
      else raise (Unify_failure (UMismatch (a, b)))
  | _ -> raise (Unify_failure (UMismatch (a, b)))

(* Safe variant: returns a Result *)
let try_unify (a : ty) (b : ty) : (subst, unify_error) result =
  try Ok (unify a b)
  with Unify_failure e -> Error e

(* ─── Type schemes (generalization/instantiation) ────────────────────── *)

(* A type scheme is forall a1, ..., an. T.
 * The meta-variables in `bound` are universally quantified. *)
type scheme = {
  bound : int list;   (* quantified meta-var ids *)
  body : ty;
}

(* generalize env_metavars t: produce a scheme where every meta-variable of t
 * that is not free in the environment is quantified. *)
let generalize (env_metavars : int list) (t : ty) : scheme =
  let t_fms = uniq (free_metavars t) in
  let bound = List.filter (fun n -> not (List.mem n env_metavars)) t_fms in
  { bound; body = t }

(* instantiate s: takes a scheme forall a1,...,an. T and produces T[a_i |-> b_i]
 * with b_i fresh. Each call site of a polymorphic fun produces different fresh
 * meta-variables, allowing local monomorphization. *)
let instantiate (s : scheme) : ty =
  let fresh_subst : subst =
    List.map (fun n -> (n, fresh_metavar ())) s.bound
  in
  apply_subst fresh_subst s.body

(* ─── Pretty-printing ────────────────────────────────────────────────── *)

