(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* core_wf.ml — wire the dependent Core checker (core_check.ml) into the compile
 * pipeline as a well-formedness GATE over the dependent-type fragment.
 *
 * WHY. The pipeline type-checks the SURFACE (tycheck.ml) and then lowers to Core,
 * but the Core IR — what emit actually consumes, and what A1's El(Fam x)
 * normalization rewrites — was never re-checked by the kernel's dependent checker.
 * core_check was test-only (15 hand-built oracle terms). This pass runs it on the
 * REAL desugared program: the kernel re-certifies every dependent type the surface
 * elaboration produced. It is the "kernel re-checks the elaborator" discipline of
 * Lean/Coq, scoped to the fragment core_check covers (Pi/Sigma/Id/El over the
 * dependent-lambda core), which is exactly where A1 lives.
 *
 * SAFE GATE. core_check does NOT cover the full runtime IR (Place, Emit, streams,
 * cubical formers, numeric literals). Running it naively would false-reject every
 * real program. So it distinguishes `Type_error (in-fragment and ILL-formed -> we
 * REJECT the program) from `Skipped (a construct outside the fragment -> we SKIP,
 * never a rejection). A well-formed program therefore compiles whether its types
 * are certified or skipped; only a genuinely ill-formed dependent type stops it.
 *
 * WHEN. Run right after desugar and BEFORE El_normalize, so the codes certified are
 * the ORIGINAL ones the user wrote (El(Fam x)), not the already-computed carriers —
 * we certify that the family really produces a universe code before we trust its
 * reduction. *)

open Ast

(* Primitive type names double as level-0 codes: `number : Type_0`. Seeding them
   lets El of a code that mentions a primitive infer its universe. *)
let prim_codes = [ "number"; "money"; "text"; "boolean"; "unit" ]

type report = { certified : int; skipped : int; bodies_checked : int; bodies_skipped : int }

(* Peel a function's top-level lambda chain into its (binder, type) parameters. *)
let peel_params (body : term) : (string * ty) list =
  let rec go acc = function
    | Lam (x, ty, b) -> go ((x, ty) :: acc) b
    | _ -> List.rev acc
  in
  go [] body

(* Peel the lambda chain, returning the innermost (non-lambda) body. *)
let rec peel_body : term -> term = function
  | Lam (_, _, b) -> peel_body b
  | t -> t

(* ── Certified delta-rules for delta-aware conversion ────────────────────────
   The kernel checker's definitional equality unfolds user function definitions
   (Core_check.cctx). We may only offer the SN-safe, PURE subset as delta-rules:

   PURITY. A delta-rule is unfolded during conversion by the R_Yon/beta reducer,
   which is only a sound equality on the PURE dependent core (Var/Lam/App/Fst/
   Snd/Pair/Refl/J/StreamCons/Unit + cubical + arithmetic). A body that mentions
   a RUNTIME former (Place / Reduction / World / Scope / Emit) is effectful: its
   Core term is not a value the reducer can substitute for the call without
   changing meaning. Such a function is left OPAQUE (never unfolded) — sound,
   possibly incomplete. This mirrors Desugar.delta_rule_of_fun, which likewise
   admits only pure single-return bodies into env.delta; we re-derive the set
   here from [dr] alone (the emitter passes only the desugar_result to the gate).

   TERMINATION (SN). Even a pure body may recurse. We certify termination with
   the SAME Size-Change gate the dispatcher uses (Sct.certify): only functions
   whose recursion descends on the subterm order are kept, so unfolding reaches
   a normal form in finitely many steps and the fuel bound is a conservative
   incompleteness cap, never a source of unsoundness or divergence. *)
let rec is_pure_body (t : term) : bool =
  match t with
  (* runtime / effectful formers: NEVER unfold a body that contains one *)
  | Place _ | Reduction _ | World _ | Scope _ | Emit _ -> false
  | Var _ | Unit -> true
  | Lam (_, _, b) -> is_pure_body b
  | App (f, a) -> is_pure_body f && is_pure_body a
  | Refl e | Fst e | Snd e | Unglue e -> is_pure_body e
  | Pair (a, b) | StreamCons (a, b) -> is_pure_body a && is_pure_body b
  | J (_, _, c, d, p, a) ->
      is_pure_body c && is_pure_body d && is_pure_body p && is_pure_body a
  | PLam (_, b) -> is_pure_body b
  | PApp (p, _) -> is_pure_body p
  | Transp (_, b) -> is_pure_body b
  | Comp (_, _, sys, base) | HComp (_, _, sys, base) ->
      List.for_all (fun (_, _, e) -> is_pure_body e) sys && is_pure_body base
  | GlueElem (_, a, b) -> is_pure_body a && is_pure_body b
  | HITElim (branches, scrut) ->
      List.for_all (fun (_, _, b) -> is_pure_body b) branches && is_pure_body scrut
  | HITConstr (_, args) -> List.for_all is_pure_body args

let certified_deltas (dr : Desugar.desugar_result) : (string * term) list =
  (* Keep only the PURE bodies as delta-candidates. *)
  let pure =
    List.filter (fun (_, body) -> is_pure_body (peel_body body))
      dr.Desugar.functions
  in
  (* Certify termination over the pure candidates (subterm order). *)
  let fundefs =
    List.map
      (fun (name, body) ->
         let params = List.map fst (peel_params body) in
         Sct.{ name; params; body = peel_body body })
      pure
  in
  let certified = Sct.certify fundefs in
  List.filter (fun (name, _) -> List.mem name certified) pure

(* A function's declared type as a Pi-chain over its parameters. Only functions
   whose return type is known (fn_ret_hints) get a signature; one that is missing is
   simply absent from the global context, so a code that mentions it degrades to a
   SKIP (unbound), never a false rejection. *)
let global_ctx (dr : Desugar.desugar_result) : Core_check.tctx =
  let sig_of (name, body) =
    match List.assoc_opt name dr.Desugar.fn_ret_hints with
    | Some ret ->
        let params = peel_params body in
        Some (name, List.fold_right (fun (x, t) acc -> TyPi (x, t, acc)) params ret)
    | None -> None
  in
  List.map (fun p -> (p, TyType 0)) prim_codes
  @ List.filter_map sig_of dr.Desugar.functions

let certify_program (dr : Desugar.desugar_result) : (report, string) result =
  let g0 = global_ctx dr in
  (* Delta-aware conversion context: the certified, pure, SN-safe subset of the
     program's own function definitions. Threaded into every certify_ty and every
     body check so definitional equality unfolds those calls. *)
  let cc = Core_check.cctx_of_deltas (certified_deltas dr) in
  let certn = ref 0 and skipn = ref 0 and errs = ref [] in
  let bchk = ref 0 and bskip = ref 0 and bwarn = ref [] in
  let certify g ty =
    match Core_check.certify_ty ~cc g ty with
    | `Ok -> incr certn
    | `Skipped _ -> incr skipn
    | `Type_error m -> errs := m :: !errs
  in
  (* Walk a term, threading term-level value binders into the context and certifying
     every embedded type annotation. sort_of itself recurses into a type's own
     Pi/Sigma/Id binders, so here we only thread Lam binders. *)
  let rec wt (g : Core_check.tctx) (t : term) : unit =
    match t with
    | Lam (x, dom, body) -> certify g dom; wt ((x, dom) :: g) body
    | App (f, a) -> wt g f; wt g a
    | Scope (_, b) -> wt g b
    | Emit e -> wt g e
    | Refl e -> wt g e
    | J (_, ty, c, d, p, a) -> certify g ty; List.iter (wt g) [ c; d; p; a ]
    | Pair (a, b) -> wt g a; wt g b
    | Fst a -> wt g a
    | Snd a -> wt g a
    | StreamCons (a, b) -> wt g a; wt g b
    | PLam (_, b) -> wt g b
    | PApp (p, _) -> wt g p
    | Transp ((_, ty), b) -> certify g ty; wt g b
    | Comp (ty, _, sys, base) ->
        certify g ty; List.iter (fun (_, _, e) -> wt g e) sys; wt g base
    | HComp (ty, _, sys, base) ->
        certify g ty; List.iter (fun (_, _, e) -> wt g e) sys; wt g base
    | GlueElem (_, a, b) -> wt g a; wt g b
    | Unglue e -> wt g e
    | HITElim (branches, scrut) ->
        List.iter (fun (_, _, body) -> wt g body) branches; wt g scrut
    | HITConstr (_, args) -> List.iter (wt g) args
    | Var _ | Unit | Place _ | Reduction _ | World _ -> ()
  in
  List.iter (fun (_, b) -> wt g0 b) dr.Desugar.functions;
  (match dr.Desugar.main with Some m -> wt g0 m | None -> ());
  (* Also certify each declared return type (a family's `Type_0`, or a function
     returning El(...)), which is not a Lam binder. *)
  List.iter (fun (_, ret) -> certify g0 ret) dr.Desugar.fn_ret_hints;

  (* ── Term-checking pass ────────────────────────────────────────────────────
     Beyond certifying that every dependent TYPE is well-formed, kernel-CHECK
     each function BODY against its declared type. The declared type is the same
     Pi-chain global_ctx builds from the parameters + fn_ret_hints; a function
     whose return type is unknown (no hint) has no signature, so its body is not
     checked (it cannot be, soundly).

     SAFE POLICY, identical to the type gate. certify_term returns:
       `Ok           — the body kernel-checks: count it (bodies_checked);
       `Skipped      — the body (or its declared type) touches a construct out
                       of the fragment — a runtime former (Place/Emit/stream/
                       cubical), an unseeded top-level name, or a term with no
                       inference rule: count it (bodies_skipped), NEVER reject.
                       Most corpus bodies use runtime constructs, so most SKIP —
                       that is expected and correct;
       `Type_error   — `Core_check.check returned a clean `false`. This is NOT a
                       reliable rejection: it cannot be distinguished from checker
                       INCOMPLETENESS (a valid body the fragment does not cover,
                       e.g. a desugar-synthesized `__functor_inline_*` lambda). So it
                       is treated as ADVISORY — recorded and counted as skipped,
                       NEVER a compile error. The sound hard reject stays with the
                       TYPE well-formedness pass (sort_of), where `false` is
                       unambiguous. Promote body checking to fatal only once the
                       fragment is complete enough for `false` to mean ill-typed.

     We build the body's declared Pi-type from peel_params + the return hint,
     matching global_ctx, and check the WHOLE curried lambda against it (check's
     Lam rule peels the binders in lock-step). We check under g0 so a call to a
     sibling function resolves to its signature (or SKIPs as unbound). *)
  List.iter
    (fun (name, body) ->
       match List.assoc_opt name dr.Desugar.fn_ret_hints with
       | None -> ()  (* no declared return type: not soundly checkable *)
       | Some ret ->
           let params = peel_params body in
           let decl_ty =
             List.fold_right (fun (x, t) acc -> TyPi (x, t, acc)) params ret
           in
           (match Core_check.certify_term ~cc g0 body decl_ty with
            | `Ok -> incr bchk
            | `Skipped _ -> incr bskip
            | `Type_error m ->
                (* ADVISORY, never fatal. `Core_check.check returning a clean `false`
                   does NOT distinguish "genuinely ill-typed" from "the checker cannot
                   verify this body" — and desugaring emits synthesized bodies
                   (`__functor_inline_*`, `__arg_lam_inline_*`, curried inlinings) whose
                   valid Core the fragment does not cover, which surface as exactly that
                   ambiguous `false`. Rejecting on it false-rejects valid programs. So a
                   body that does not check is RECORDED and SKIPPED, not a compile error.
                   The sound hard gate is the TYPE well-formedness pass above (`errs`),
                   whose `sort_of` reject is unambiguous (e.g. El of a non-code). Term
                   checking stays advisory until the checker's fragment is complete
                   enough to make a body `false` a reliable rejection. *)
                incr bskip;
                bwarn := (name, m) :: !bwarn))
    dr.Desugar.functions;

  (* Report the term-checking counts under the same YON_CORE_WF flag the emitter
     uses for the type-certification line (the emitter's fixed log prints only
     certified/skipped types; this adds the body counts without touching it). The
     advisory list surfaces bodies the checker could not verify — visible, not silent,
     but non-fatal. *)
  if (try Sys.getenv "YON_CORE_WF" = "1" with Not_found -> false) then begin
    Printf.eprintf "[core-wf] %d function bodies kernel-checked, %d skipped (out of fragment)\n"
      !bchk !bskip;
    if !bwarn <> [] then
      Printf.eprintf "[core-wf] %d bodies unverified (advisory, not rejected): %s\n"
        (List.length !bwarn)
        (String.concat ", " (List.rev_map fst !bwarn))
  end;

  if !errs = [] then
    Ok { certified = !certn; skipped = !skipn;
         bodies_checked = !bchk; bodies_skipped = !bskip }
  else Error (String.concat "; " (List.rev !errs))
