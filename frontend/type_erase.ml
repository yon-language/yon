(* type_erase.ml — runtime erasure of type-level (universe-typed) parameters.
 *
 * Places are the one ontology; a place-qua-object (a code, type : Type) has no
 * runtime carrier. A function parameter of type Type is a TYPE ARGUMENT: it is
 * a compile-time citizen, resolved during type-checking, and must not survive
 * into the runtime calling convention. This pass erases such parameters so the
 * backend (and the carrier functor) never has to realize a type as data.
 *
 * The erasure is COORDINATED, which is the whole point: dropping a universe
 * binder from a function's definition WITHOUT dropping the matching argument at
 * its call sites would desynchronize arity and silently miscompile. So this is
 * a single Core->Core pass that does both:
 *   - drops universe-typed binders from each function's top-level lambda chain;
 *   - drops the arguments at those positions from every direct application of
 *     that function (depth-i binder <-> spine-position-i argument; Core curries
 *     uniformly, so the indexing stays aligned across def and call).
 *
 * SOUNDNESS GUARD. A function that has type parameters is only handled when it
 * appears as the head of a direct application. Any OTHER occurrence of its name
 * (passed as a value, aliased through a let, used higher-order) would leave the
 * erased arity unmatched, so the pass REJECTS it loudly rather than emit wrong
 * code. This keeps the transform sound; lifting the restriction (full
 * higher-order erasure) is a later step. The rejection is a hard failure here
 * because the emit phase has no errors-as-values channel yet; routing it to a
 * positioned compile-time diagnostic waits on that separate piece. *)

module C = Ast

(* A function with type parameters used OUTSIDE a direct call (passed as a
   value, aliased, or partially applied) cannot have its type arguments erased
   coherently yet — higher-order erasure is not lowered. Per the 2026-06-17
   decree ("reject at compile time, not failwith"), this is a clean
   compile-time rejection on the canonical error channel (exit 3): a well-typed
   term with no realizable lowering is refused with a diagnostic, never
   crashed on with a raw failwith. Carries the offending function name. *)
exception Higher_order_type_param of string

(* Is this binder type a universe (a code / type-level classifier)? *)
let is_universe_ty (t : C.ty) : bool =
  match t with
  | C.TyType _ -> true
  | _ -> false

(* Positions (0-based) of universe-typed binders in a function's top-level
   lambda chain — its erasable type parameters. *)
let universe_positions (fn_body : C.term) : int list =
  let rec go i acc t =
    match t with
    | C.Lam (_, ty, b) ->
        let acc = if is_universe_ty ty then i :: acc else acc in
        go (i + 1) acc b
    | _ -> List.rev acc
  in
  go 0 [] fn_body

(* Drop the binders at [positions] from the top-level lambda chain. The bodies
   of the kept binders are left to the application rewrite below. *)
let drop_binders (positions : int list) (fn_body : C.term) : C.term =
  let rec go i t =
    match t with
    | C.Lam (x, ty, b) ->
        let b' = go (i + 1) b in
        if List.mem i positions then b' else C.Lam (x, ty, b')
    | other -> other
  in
  go 0 fn_body

(* Rewrite a term, dropping type-arguments at every direct application of a
   function that has universe positions, and guarding non-applied uses. *)
let rewrite (positions_of : string -> int list option) (t0 : C.term) : C.term =
  let rec go (t : C.term) : C.term =
    match t with
    | C.App _ ->
        (* peel the application spine into (head, args-left-to-right) *)
        let rec peel acc t =
          match t with C.App (f, a) -> peel (a :: acc) f | h -> (h, acc)
        in
        let (head, args) = peel [] t in
        (match head with
         | C.Var f ->
             (match positions_of f with
              | Some ps ->
                  let kept =
                    List.filteri (fun i _ -> not (List.mem i ps)) args in
                  List.fold_left (fun acc a -> C.App (acc, go a)) (C.Var f) kept
              | None ->
                  List.fold_left (fun acc a -> C.App (acc, go a)) (go head) args)
         | _ ->
             List.fold_left (fun acc a -> C.App (acc, go a)) (go head) args)
    | C.Var x ->
        (match positions_of x with
         | Some _ ->
             raise (Higher_order_type_param x)
         | None -> t)
    | C.Lam (x, ty, b) -> C.Lam (x, ty, go b)
    | C.Place _ -> t
    | C.Reduction r ->
        C.Reduction { r with
          C.r_handlers =
            List.map (fun h -> { h with C.hc_body = go h.C.hc_body })
              r.C.r_handlers }
    | C.Scope (s, b) -> C.Scope (s, go b)
    | C.With (s, b) -> C.With (s, go b)
    | C.Emit t' -> C.Emit (go t')
    | C.Refl t' -> C.Refl (go t')
    | C.J (x, a, c, d, p, b) -> C.J (x, a, go c, go d, go p, go b)
    | C.Pair (a, b) -> C.Pair (go a, go b)
    | C.Fst t' -> C.Fst (go t')
    | C.Snd t' -> C.Snd (go t')
    | C.StreamCons (h, k) -> C.StreamCons (go h, go k)
    | C.Unit -> t
    | C.PLam (i, t') -> C.PLam (i, go t')
    | C.PApp (p, r) -> C.PApp (go p, r)
    | C.Transp ((i, a), t') -> C.Transp ((i, a), go t')
    | C.Comp (ty, ff, sides, base) ->
        C.Comp (ty, ff, List.map (fun (s, f, t') -> (s, f, go t')) sides, go base)
    | C.HComp (ty, ff, sides, base) ->
        C.HComp (ty, ff, List.map (fun (s, f, t') -> (s, f, go t')) sides, go base)
    | C.GlueElem (ff, t', a') -> C.GlueElem (ff, go t', go a')
    | C.Unglue t' -> C.Unglue (go t')
    | C.HITElim (branches, scrut) ->
        C.HITElim (List.map (fun (n, b) -> (n, go b)) branches, go scrut)
    | C.HITConstr (n, args) -> C.HITConstr (n, List.map go args)
  in
  go t0

(* The pass over a whole program. *)
let erase (dr : Desugar.desugar_result) : Desugar.desugar_result =
  let sigs =
    List.map (fun (name, body) -> (name, universe_positions body))
      dr.Desugar.functions
  in
  let positions_of f =
    match List.assoc_opt f sigs with
    | Some ps when ps <> [] -> Some ps
    | _ -> None
  in
  let erase_fn (name, body) =
    let ps = match List.assoc_opt name sigs with Some p -> p | None -> [] in
    (name, rewrite positions_of (drop_binders ps body))
  in
  { dr with
    Desugar.functions = List.map erase_fn dr.Desugar.functions;
    Desugar.main = Option.map (rewrite positions_of) dr.Desugar.main }
