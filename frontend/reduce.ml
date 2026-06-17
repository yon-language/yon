(* reduce.ml — operational semantics + the R_Yon reduction system
 *
 * This file implements:
 *
 * (A) Small-step operational semantics from Yon Core Section 3.1:
 *     beta-reduction, scope-enter, scope-exit, with-handle, with-return, emit.
 *
 * (B) The seven families of R_Yon from Yon Core §4:
 *     1. Alpha-renaming (implicit in Subst, no explicit rule needed)
 *     2. Beta-reduction (Family 2 = operational beta; treated as equality)
 *     3. Eta-equivalence
 *     4. Place equivalence
 *     5. Reduction equivalence
 *     6. Move equivalence (omitted in this prototype — surface-only construct)
 *     7. View equivalence (omitted in this prototype — surface-only construct)
 *
 * The dispatcher specified in v0.3 §6.4.1 orders reductions:
 *     structural (Families 4-7) -> cubical -> computational (Families 1-3)
 * For this prototype, we have Families 1-5, no cubical layer yet, so the
 * dispatcher is: Family 4 + 5 first (place/reduction equivalence), then
 * beta+eta. This gives deterministic, terminating reduction.
 *)

open Ast

(* ─── A small environment of declared places/reductions ────────────── *)

(* A program context: globally declared places and reductions plus
 * an active stack of handler bindings (the "with R in ..." chain).
 *)
type ctx = {
  places : (string * place_decl) list;
  reductions : (string * reduction_decl) list;
  active_handlers : (string * reduction_decl) list;  (* stack, top first *)
  current_place : string option;   (* current place for proposition evaluation *)
  visibility_table : (string * string list) list;  (* place_name -> visible names *)
  (* delta-rules: SCT-certified function definitions, name -> Core body
   * (a curried lambda). The reducer unfolds f to its body alongside beta.
   * Only certified-terminating rules are placed here, so normalization
   * needs no fuel. Empty for evaluation contexts that don't want unfolding. *)
  deltas : (string * term) list;
}

let empty_ctx = {
  places = [];
  reductions = [];
  active_handlers = [];
  current_place = None;
  visibility_table = [];
  deltas = [];
}

(* World-tag setter: a hook the reducer calls when entering/leaving a
 * `with R of P { ... }` block. *)
let world_tag_setter : (string option -> unit) ref = ref (fun _ -> ())

(* Hook to fully reduce a term using all available reduction strategies
 * (including builtins/stdlib). Registered by main.ml. Used when the
 * reducer needs to force a side-effectful argument before beta. *)
let full_reduce_hook : (ctx -> term -> term) ref = ref (fun _ t -> t)

(* Switch to a different current place. Returns a new ctx. *)
let with_current_place (ctx : ctx) (place : string) : ctx =
  { ctx with current_place = Some place }

(* Pop the current place (e.g., when exiting a function). *)
let pop_current_place (ctx : ctx) : ctx =
  { ctx with current_place = None }

(* Register the visibility set for a place. *)
let register_visibility (ctx : ctx) (place : string) (visible : string list) : ctx =
  { ctx with visibility_table = (place, visible) :: ctx.visibility_table }

(* Lookup visibility for a place. Returns None if not registered. *)
let lookup_visibility (ctx : ctx) (place : string) : string list option =
  List.assoc_opt place ctx.visibility_table

let declare_place ctx p = { ctx with places = (p.p_name, p) :: ctx.places }
let declare_reduction ctx r = { ctx with reductions = (r.r_name, r) :: ctx.reductions }

(* ─── Value predicate ──────────────────────────────────────────────── *)

(* A term is a value when no further reduction applies.
 * Yon Core Section 3.3: values are lambdas, places, reductions, place_values,
 * stream values, and Unit.
 *)
let is_value t =
  match t with
  | Lam _ -> true
  | Place _ -> true
  | Reduction _ -> true
  | StreamCons _ -> true
  | Unit -> true
  | Var v ->
      (* Encoded primitive values are stored as Var with a tag prefix.
       * These are values, not free variables:
       *   __num_<n>, __str_<s>, __bool_<b>, __heyt_<p>, __dur_<n>_<u>
       *)
      let starts_with prefix =
        String.length v >= String.length prefix
        && String.sub v 0 (String.length prefix) = prefix
      in
      starts_with "__num_" || starts_with "__str_"
      || starts_with "__bool_" || starts_with "__heyt_"
      || starts_with "__dur_" || starts_with "__space_"
      || starts_with "__list_" || starts_with "__map_"
      || starts_with "__pmap_"
      || starts_with "__coh_"
  | App _ ->
      (* Check if the outermost App is a constructor application
       * __new_P v1 v2 ... by uncurrying the head. *)
      let rec head_of = function
        | App (f, _) -> head_of f
        | Var v -> Some v
        | _ -> None
      in
      (match head_of t with
       | Some head ->
           let starts_with prefix =
             String.length head >= String.length prefix
             && String.sub head 0 (String.length prefix) = prefix
           in
           starts_with "__new_"
       | None -> false)
  | Scope _ -> false
  | With _ -> false
  | Emit _ -> false
  | Refl _ -> true       (* refl(t) is a canonical witness — a value *)
  | Pair _ -> true       (* (a, b) is a value when components are values *)
  | J _ -> false         (* J is an eliminator: it reduces *)
  | Fst _ -> false       (* projections reduce *)
  | Snd _ -> false
  | PLam _ -> true       (* <i> t is a canonical path value *)
  | PApp _ -> false      (* path application reduces *)
  | Transp _ -> false    (* transport reduces *)
  | Comp _ | HComp _ -> false  (* composition reduces *)
  | GlueElem _ -> true         (* glue-elem is a value *)
  | Unglue _ -> false          (* unglue reduces *)
  | HITElim _ -> false         (* reduces via the cubical engine *)
  | HITConstr _ -> true        (* a HIT constructor is a value *)

(* ─── Family 4: Place equivalence ──────────────────────────────────── *)

(* Two places are equal under R_Yon Family 4 if their signatures match.
 * "Signature" = name, site, fields, operations. This is what
 * Ast.place_equal already computes.
 *
 * Family 4 is idempotent: applying it produces a canonical representative.
 * Since we identify by name + signature, the canonical form is the
 * place with that signature; no transformation needed beyond confirmation.
 *)
let family4_equivalent p1 p2 = place_equal p1 p2

(* ─── Family 5: Reduction equivalence ──────────────────────────────── *)

(* Two reductions are equal under Family 5 if their handler bodies are
 * beta-eta equivalent pointwise. For the prototype we check syntactic
 * equality (modulo our subst which is alpha-aware); a full implementation
 * would normalize each body with Families 2-3 and then compare.
 *)
let family5_equivalent r1 r2 = reduction_equal r1 r2

(* ─── Family 3: Eta-equivalence ────────────────────────────────────── *)

(* η-reduction: lambdax:T. (f x) -> f, provided x not-in FV(f).
 *
 * We apply eta as a rewriting rule: detect the pattern, rewrite if safe.
 *)
let try_eta t =
  match t with
  | Lam (x, _, App (f, Var y)) when x = y ->
      let module S = Set.Make (String) in
      if not (S.mem x (free_vars f)) then Some f else None
  | _ -> None

(* ─── Family 2: Beta-reduction (operational) ───────────────────────── *)

(* beta-redex: ((lambdax:T.body) arg) -> body[x ↦ arg]
 *)
(* Side-effectful operations whose result must be forced before
 * substitution into the body, even if the bound variable is unused.
 * Lazy substitution would silently drop the effect.
 *)
let rec has_side_effect t =
  match t with
  | App (Var name, _) | App (App (Var name, _), _)
  | App (App (App (Var name, _), _), _) ->
      let prefix p =
        String.length name >= String.length p
        && String.sub name 0 (String.length p) = p
      in
      prefix "Space__"
      || prefix "PerfectMap__" || prefix "Output__"
      || prefix "Stream__"
      (* List__, Map__ are pure: each op produces a new id without
       * mutating state, so they don't need strict ordering.
       * Stream__ has side effects (a mutable queue) and must be reduced before
       * the beta step, otherwise the lazy substitution of
       * `_ holds Stream.send(...)` loses the call. *)
  | App (f, _) -> has_side_effect f
  | _ -> false

let try_beta t =
  match t with
  | App (Lam (x, _, body), arg) ->
      if has_side_effect arg && not (is_value arg) then
        None
      else
        Some (Subst.subst x arg body)
  | _ -> None

(* ─── Scope-exit ───────────────────────────────────────────────────── *)

(* When a scope body has reduced to a value, the scope itself reduces
 * to that value (pushforward). The runtime is responsible for dropping
 * other sub-Space contents, but for the AST-level reducer there's
 * nothing else to do: only the return value escapes.
 *)
let try_scope_exit t =
  match t with
  | Scope (_, v) when is_value v -> Some v
  | _ -> None

(* ─── With-return ──────────────────────────────────────────────────── *)

(* When a with-block body is a value (no more operations to handle),
 * the with-block reduces to that value.
 *)
let try_with_return t =
  match t with
  | With (_, v) when is_value v -> Some v
  | _ -> None

(* ─── Operation dispatch (with-handle) ─────────────────────────────── *)

(* If the body of a `with R in ...` block makes a call to an operation
 * that R handles, replace the call with the handler body.
 *
 * For the prototype, we detect "operation call" syntactically as
 * "App (Var op_name, ...)" inside the with block, where op_name
 * matches a handler clause of R.
 *
 * In a full implementation, the elaborator from surface Yon would
 * mark operation calls explicitly. Here we use a lookup against the
 * active handlers stack.
 *)
let lookup_handler ctx op_name =
  (* Handlers register clauses by unqualified op name (e.g., "print"),
   * but dispatched calls often use the qualified form (e.g., "Output__print").
   * Try the exact name first, then strip the "<Place>__" prefix. *)
  let strip_qualifier name =
    try
      let i = Str.search_forward (Str.regexp "__") name 0 in
      Some (String.sub name (i+2) (String.length name - i - 2))
    with Not_found -> None
  in
  let names =
    op_name :: (match strip_qualifier op_name with
                | Some n -> [n]
                | None -> [])
  in
  let rec find = function
    | [] -> None
    | (_, r) :: rest ->
        (try
           let h = List.find (fun h -> List.mem h.hc_op names) r.r_handlers in
           Some (r, h)
         with Not_found -> find rest)
  in
  find ctx.active_handlers

(* Try to handle an operation call inside the active handler stack.
 * Returns Some (handler_body_with_substituted_args) if a handler is found.
 *)
let try_op_handle ctx op_name args =
  match lookup_handler ctx op_name with
  | Some (_, h) ->
      if List.length args <> List.length h.hc_params then None
      else
        let body =
          List.fold_left2
            (fun b (param_name, _) arg -> Subst.subst param_name arg b)
            h.hc_body h.hc_params args
        in
        Some body
  | None -> None

(* Decompose an application into (head, [args]).
 * (f a b c) -> (f, [a; b; c])
 *)
let rec uncurry t =
  match t with
  | App (f, a) ->
      let head, args = uncurry f in
      (head, args @ [ a ])
  | _ -> (t, [])

(* ─── The small-step reducer ───────────────────────────────────────── *)

(* One step of reduction. Returns Some t' if a step was taken, None if
 * the term is a normal form (or stuck).
 *
 * Dispatcher order (per v0.3 §6.4.1 and Yon Core §8.2):
 *   1. Structural reductions first (Family 4/5) — handled at construction
 *      since we identify places/reductions by signature; no in-term rules.
 *   2. Cubical reductions — omitted in this prototype.
 *   3. Computational reductions — beta, eta, scope-exit, with-return,
 *      with-handle, emit.
 *)
let rec step ctx t =
  match t with
  (* Computational reductions on the term head. *)
  | App _ ->
      (* Try beta first; if not a beta-redex, ...
       * Call-by-value: when f is a Lam (body waiting for arg), reduce
       * the arg first, NOT the body. This ensures side effects in the
       * arg run before the body is even attempted. *)
      (match try_beta t with
       | Some t' -> Some t'
       | None ->
           (* Check whether this is an operation call we can handle. *)
           let head, args = uncurry t in
           (match head with
            | Var op_name when (match try_op_handle ctx op_name args with
                                | Some _ -> true | None -> false) ->
                try_op_handle ctx op_name args
            | _ ->
                (* Reduce the argument position first when the function
                 * is a Lam (CBV); otherwise reduce function first. *)
                (match t with
                 | App (Lam _ as f, a) ->
                     (* CBV: reduce arg before body. If arg has side
                      * effects but Reduce.step can't progress it
                      * (because it needs stdlib builtins), invoke the
                      * full_reduce_hook to drive arg to a value. *)
                     (match step ctx a with
                      | Some a' -> Some (App (f, a'))
                      | None ->
                          (* arg stuck under Reduce.step. Try full
                           * reduce (which knows about stdlib). *)
                          let a' = !full_reduce_hook ctx a in
                          if a' <> a then Some (App (f, a'))
                          else
                            (* Try reducing inside the Lam body as last
                             * resort (likely produces no progress, but
                             * keeps semantics consistent). *)
                            match step ctx f with
                            | Some f' -> Some (App (f', a))
                            | None -> None)
                 | App (f, a) ->
                     (* Non-Lam head: reduce function first, then arg. *)
                     (match step ctx f with
                      | Some f' -> Some (App (f', a))
                      | None ->
                          (match step ctx a with
                           | Some a' -> Some (App (f, a'))
                           | None -> None))
                 | _ -> None)))

  | Lam (x, ty, body) ->
      (* Apply eta if applicable. *)
      (match try_eta t with
       | Some t' -> Some t'
       | None ->
           (* Otherwise, reduce inside the body (under the binder). *)
           (match step ctx body with
            | Some body' -> Some (Lam (x, ty, body'))
            | None -> None))

  | Scope (s, body) ->
      (match try_scope_exit t with
       | Some t' -> Some t'
       | None ->
           (* Reduce inside the scope. *)
           (match step ctx body with
            | Some body' -> Some (Scope (s, body'))
            | None -> None))

  | With (r_name, body) ->
      (match try_with_return t with
       | Some t' -> Some t'
       | None ->
           (* Activate r and reduce body. The current place becomes the
            * reduction's target place: a `with R of P { ... }` enters
            * the place P for proposition evaluation. Also notify the
            * world-tag setter so Space allocations get the right tag. *)
           (match List.assoc_opt r_name ctx.reductions with
            | None -> None  (* unknown reduction; stuck *)
            | Some r ->
                let previous_tag = ctx.current_place in
                !world_tag_setter (Some r.r_target);
                let ctx' = {
                  ctx with
                  active_handlers = (r_name, r) :: ctx.active_handlers;
                  current_place = Some r.r_target;
                } in
                let result = step ctx' body in
                (* Restore previous tag after the inner step. *)
                !world_tag_setter previous_tag;
                match result with
                | Some body' -> Some (With (r_name, body'))
                | None -> None))

  | Emit t' ->
      (* If inner term reduces, propagate; otherwise emit is a leaf node. *)
      (match step ctx t' with
       | Some t'' -> Some (Emit t'')
       | None -> None)

  | StreamCons (h, k) ->
      (* Reduce head first, then continuation. *)
      (match step ctx h with
       | Some h' -> Some (StreamCons (h', k))
       | None ->
           (match step ctx k with
            | Some k' -> Some (StreamCons (h, k'))
            | None -> None))

  (* ── HoTT reductions ───────────────────────────────────────────── *)
  | Refl t' ->
      (* refl reduces inside its argument; refl itself is canonical. *)
      (match step ctx t' with
       | Some t'' -> Some (Refl t'')
       | None -> None)

  | J (x, ty, c, d, p, b) ->
      (* J-eliminator (path induction).
       *
       * Computation rule:
       *   J(C, d, refl(a), a) == d(a)
       * That is: when the path is refl, J collapses to the diagonal
       * applied at the basepoint.
       *
       * If the path p is not yet refl, reduce p and the basepoint b
       * first. If neither makes progress, the J term is stuck (waiting
       * for its arguments to canonicalize). *)
      (match p with
       | Refl _ ->
           (* J(C, d, refl(a), a) == d a *)
           Some (App (d, b))
       | _ ->
           match step ctx p with
           | Some p' -> Some (J (x, ty, c, d, p', b))
           | None ->
               match step ctx b with
               | Some b' -> Some (J (x, ty, c, d, p, b'))
               | None ->
                   match step ctx c with
                   | Some c' -> Some (J (x, ty, c', d, p, b))
                   | None ->
                       match step ctx d with
                       | Some d' -> Some (J (x, ty, c, d', p, b))
                       | None -> None)

  | Pair (a, b) ->
      (* eta-Sigma (surjective pairing), as a CONTRACTION: Pair(Fst t, Snd t) ~> t
         when the two projections are of the same term (up to alpha). Strictly
         size-decreasing — t is smaller than Pair(Fst t, Snd t) — so the
         termination of the deterministic strategy is preserved. This makes the
         binary products of Syn(Yon) STRICT (the pairing mediator is unique),
         not merely weak. Checked BEFORE reducing the components so it fires on a
         neutral t (e.g. a variable), which is the case that matters. *)
      (match a, b with
       | Fst t1, Snd t2 when term_equal t1 t2 -> Some t1
       | _ ->
      (* Reduce components left-to-right. *)
      (match step ctx a with
       | Some a' -> Some (Pair (a', b))
       | None ->
           match step ctx b with
           | Some b' -> Some (Pair (a, b'))
           | None -> None))

  | Fst t' ->
      (* Sigma first projection. beta-rule: fst (a, b) == a. *)
      (match t' with
       | Pair (a, _) -> Some a
       | _ ->
           match step ctx t' with
           | Some t'' -> Some (Fst t'')
           | None -> None)

  | Snd t' ->
      (* Sigma second projection. beta-rule: snd (a, b) == b. *)
      (match t' with
       | Pair (_, b) -> Some b
       | _ ->
           match step ctx t' with
           | Some t'' -> Some (Snd t'')
           | None -> None)

  | PLam (i, t') ->
      (match step ctx t' with Some t'' -> Some (PLam (i, t'')) | None -> None)
  | PApp (Refl t, _) -> Some t   (* refl-beta: refl(t) @ i = t for every i *)
  | PApp (p, r) ->
      (match step ctx p with Some p' -> Some (PApp (p', r)) | None -> None)
  | Transp ((i, a), t') ->
      (match step ctx t' with Some t'' -> Some (Transp ((i, a), t'')) | None -> None)
  | Comp (ty, phi, sides, base) ->
      (match step ctx base with Some b' -> Some (Comp (ty, phi, sides, b')) | None -> None)
  | HComp (ty, phi, sides, base) ->
      (match step ctx base with Some b' -> Some (HComp (ty, phi, sides, b')) | None -> None)
  | GlueElem (phi, t', a') ->
      (match step ctx t' with
       | Some t'' -> Some (GlueElem (phi, t'', a'))
       | None ->
           (match step ctx a' with
            | Some a'' -> Some (GlueElem (phi, t', a''))
            | None -> None))
  | Unglue t' -> (match step ctx t' with Some t'' -> Some (Unglue t'') | None -> None)
  | HITElim (branches, scrut) ->
      (match step ctx scrut with
       | Some scrut' -> Some (HITElim (branches, scrut'))
       | None -> None)
  | HITConstr _ -> None        (* value: no head reduction *)
  | Var f when List.mem_assoc f ctx.deltas ->
      (* delta-step: unfold a certified function to its Core body. Beta then
       * drives any application; SCT certification guarantees this terminates,
       * so no fuel is needed. *)
      Some (List.assoc f ctx.deltas)
  | Var _ | Place _ | Reduction _ | Unit -> None

(* ─── Multi-step reduction ─────────────────────────────────────────── *)

(* Reduce to normal form. NO FUEL, no step cap, no magic number.
 *
 * On the conversion path every delta-rule in ctx is SCT-certified and beta on
 * well-typed terms terminates, so a normal form is reached in finitely many
 * steps by THEOREM. On the evaluation path ctx.deltas is empty (no unfolding)
 * and reduction follows the term's own beta-structure. The old `fuel = 1000`
 * crutch silently returned a non-normal term on overrun (unsound); removing it
 * means reduction is either a true normal form or it does not return — honest. *)
let rec reduce ctx t =
  match step ctx t with
  | Some t' -> reduce ctx t'
  | None -> t

(* normalize = reduce; the name marks intent on the definitional-equality path. *)
let normalize = reduce

(* Big-step evaluation: reduce to a value or get stuck. *)
let eval ctx t =
  let result = reduce ctx t in
  if is_value result || (match result with Var _ -> true | _ -> false) then result
  else result  (* return whatever we got; caller can inspect *)
