(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* el_normalize.ml — the CATT / R_Yon conversion rule  El(c) ≡ El(nf_Δ c)  applied
 * to every type annotation in the Core, once, just before the carrier functor
 * lowers types to runtime layout.
 *
 * WHY. A computed-codomain dependent type — `El(Fam x)`, where `Fam : A -> U_omega`
 * is a Tarski code family — reaches the Core as `TyEl (App (Fam, x))`: an APPLIED
 * code, not a bare name. The carrier functor (carrier.ml) is a pure functor on
 * normal forms with no delta context, so it cannot unfold `Fam` and would reject
 * the type. This pass normalizes each El code under the certified deltas Δ — the
 * SN-safe function-unfolding rules, i.e. the functoriality / computation laws of
 * the family read as delta-conversion — so that `El(Fam x)` computes to `El(number)`
 * and then decodes to that carrier.
 *
 * This is the SAME reducer the definitional-equality checker uses for conversion
 * (`Builtins.reduce_with_builtins`, the strict superset of `Reduce.normalize` that
 * also runs cubical computation and builtin arithmetic), driven by the SAME
 * certified deltas the dispatcher uses (`Dispatcher.certified_deltas`). It is NOT a
 * parallel surface inliner: the conversion lives in the kernel/R_Yon layer, and the
 * carrier stays a pure functor that only ever sees a normal form.
 *
 * A code that genuinely depends on a runtime value (a non-constant family applied
 * to a free variable) stays STUCK under Δ; the pass leaves it as `TyEl (stuck)` and
 * the carrier rejects it cleanly downstream — honest, because such a type has no
 * single runtime layout. *)

open Ast

let normalize_result (deltas : (string * term) list)
    (r : Desugar.desugar_result) : Desugar.desugar_result =
  let dctx = { Reduce.empty_ctx with Reduce.deltas } in
  (* reduce ONE El code to its Δ-normal form. Everything else in the type/term is
   * only traversed structurally; no term is otherwise evaluated. *)
  let reduce_code (c : term) : term = Builtins.reduce_with_builtins dctx c in
  let rec nt (ty : ty) : ty =
    match ty with
    | TyEl c -> TyEl (reduce_code c)
    | TyArrow (a, b) -> TyArrow (nt a, nt b)
    | TyPi (x, a, b) -> TyPi (x, nt a, nt b)
    | TySigma (x, a, b) -> TySigma (x, nt a, nt b)
    | TyId (a, t1, t2) -> TyId (nt a, ntm t1, ntm t2)
    | TyStream a -> TyStream (nt a)
    | TyGlue (a, phi, sys) ->
        TyGlue (nt a, phi, List.map (fun (t, e) -> (nt t, ntm e)) sys)
    | TyPathP ((i, a), t1, t2) -> TyPathP ((i, nt a), ntm t1, ntm t2)
    | (TyType _ | TyDirUniverse _ | TyPlace _) as t -> t
  and ntm (t : term) : term =
    match t with
    | Lam (x, ty, b) -> Lam (x, nt ty, ntm b)
    | App (f, a) -> App (ntm f, ntm a)
    | Scope (s, b) -> Scope (s, ntm b)
    | Emit e -> Emit (ntm e)
    | Refl e -> Refl (ntm e)
    | J (x, ty, c, d, p, a) -> J (x, nt ty, ntm c, ntm d, ntm p, ntm a)
    | Pair (a, b) -> Pair (ntm a, ntm b)
    | Fst a -> Fst (ntm a)
    | Snd a -> Snd (ntm a)
    | StreamCons (a, b) -> StreamCons (ntm a, ntm b)
    | PLam (i, b) -> PLam (i, ntm b)
    | PApp (p, r') -> PApp (ntm p, r')
    | Transp ((i, ty), b) -> Transp ((i, nt ty), ntm b)
    | Comp (ty, phi, sys, base) ->
        Comp (nt ty, phi, List.map (fun (n, f, e) -> (n, f, ntm e)) sys, ntm base)
    | HComp (ty, phi, sys, base) ->
        HComp (nt ty, phi, List.map (fun (n, f, e) -> (n, f, ntm e)) sys, ntm base)
    | GlueElem (phi, t1, t2) -> GlueElem (phi, ntm t1, ntm t2)
    | Unglue e -> Unglue (ntm e)
    | HITElim (branches, scrut) ->
        HITElim (List.map (fun (c, bs, body) -> (c, bs, ntm body)) branches, ntm scrut)
    | HITConstr (c, args) -> HITConstr (c, List.map ntm args)
    | Place pd -> Place (npd pd)
    | (Var _ | Unit | Reduction _ | World _) as leaf -> leaf
  and npd (pd : place_decl) : place_decl =
    { pd with
      p_site = nt pd.p_site;
      p_fields = List.map (fun (n, t) -> (n, nt t)) pd.p_fields;
      p_operations = List.map nop pd.p_operations }
  and nop (o : op_sig) : op_sig =
    { o with
      op_params = List.map (fun (n, t) -> (n, nt t)) o.op_params;
      op_return = nt o.op_return }
  in
  { r with
    Desugar.functions = List.map (fun (n, b) -> (n, ntm b)) r.Desugar.functions;
    Desugar.fn_ret_hints = List.map (fun (n, t) -> (n, nt t)) r.Desugar.fn_ret_hints;
    Desugar.main = Option.map ntm r.Desugar.main }
