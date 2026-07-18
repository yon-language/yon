(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_transp_glue.ml — the CCHM boundary-equation ORACLE for TRANSPORT at a
 * Glue type (transp = comp with the empty system; Cohen–Coquand–Huber–Mörtberg
 * 2018, §6.2).  Companion to test_glue_boundary.ml, which pins the analogous
 * equations for comp/hcomp at a Glue.
 *
 * The rule under test (reduce_transport, CTGlue case), for
 *     transp^i (Glue [ φ ↦ (T_k, e_k)_k ] A) t0 ,   i : 0 → 1 ,   e_k : T_k ≃ A :
 *
 *   (1) a0 = unglue^{i:=0} t0    — on a start face φ_k taut at i=0 this is the
 *                                  forward map e_k.f(t0); off the extent it is
 *                                  the identity / the glue-elem's base part.
 *   (2) a1 = transp^i A a0.
 *   (3/4) per glue face φ_k the corrected fibre is e_k.g(a1)  (centre of the
 *         contractible fibre of e_k.f over a1).
 *   (6) result = glue [ φ[i:=1] ↦ t1' ] a1 ; on a target face φ_k taut at i=1
 *         the glue degenerates to that face's fibre e_k.g(a1).
 *
 * VERIFIED here (structural boundary/adjacency equations):
 *   • DIRECTION.  A single face at (i=1) transports by the INVERSE e.g (A→T);
 *     a single face at (i=0) transports by the FORWARD e.f (T→A).
 *   • ua ANCHOR.  Glue [(i=0)↦(A,e),(i=1)↦(B,id)] B ⇒ start-forward e.f(t)
 *     wrapped by the target inverse id.g (which β-collapses to identity in the
 *     core — the transport_ua_succ.yon anchor checks the arithmetic collapse).
 *   • PER-FACE.  A genuine two-face system with DISTINCT e1, e2 restricts to
 *     e1.g(a1) on the first face and e2.g(a1) on the second — every face is
 *     handled, never "just the first pair".
 *   • BASE EQUATION.  unglue(result) = transp^i A (unglue t0).
 *
 * RESIDUAL (honestly NOT verified / not enforced): the fibre-correction
 * coherence ω_k : e_k.f(t1'_k) ~ a1 (CCHM step 5, the comp^j A [φ↦ω] a1
 * adjustment of the base along ω).  This prototype keeps a1' = a1 un-adjusted
 * (so the base boundary above is EXACT) and takes the fibre centre e_k.g(a1)
 * WITHOUT the ε-homotopy filler.  The single equation that is therefore left
 * open is  a1 = e_k.f(t1'_k)  on φ_k.  It is the same class of residual the
 * hcomp-Glue coherence patch carries; it needs a genuine ε filler (available as
 * the __equiv_eps marker) and is out of scope for the decidable prototype.
 *)

open Surface_ast
open Cubical

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let nf = normalize_cterm
(* restrict a term to a face by driving a dimension to an endpoint, then nf *)
let at dim endpoint t = nf (subst_interval_in_cterm dim endpoint t)

let fwd e x = CHITConstr ("__equiv_fwd", [e; x])
let bwd e x = CHITConstr ("__equiv_bwd", [e; x])

let () =
  Printf.printf "=== CCHM transp-at-Glue boundary oracle ===\n\n";

  let a  = CTBase (TyPrim "A") in
  let tT = CTBase (TyPrim "T") in
  let e  = CVar "e" in
  let t  = CVar "t" in

  (* ─── (C) DIRECTION: single-face endpoint shapes ──────────────────────── *)

  (* Glue [(i=1) ↦ (T,e)] A : type A at i=0, T at i=1 ⇒ transp (0→1) maps A→T,
     the INVERSE e.g.  (The old placeholder applied the forward e.f here.) *)
  let g_i1 = CTGlue (a, [[("i", true)]], [(tT, e)]) in
  check "single face (i=1): transp = e.g  (inverse map A→T)"
    (cterm_syntactic_equal (nf (CTransport (("i", g_i1), t))) (bwd e t));

  (* Glue [(i=0) ↦ (T,e)] A : type T at i=0, A at i=1 ⇒ transp maps T→A,
     the FORWARD e.f, drawn from the start-face unglue. *)
  let g_i0 = CTGlue (a, [[("i", false)]], [(tT, e)]) in
  check "single face (i=0): transp = e.f  (forward map T→A, from start unglue)"
    (cterm_syntactic_equal (nf (CTransport (("i", g_i0), t))) (fwd e t));

  (* the two single-face directions genuinely differ (forward vs inverse) *)
  check "single-face i=0 and i=1 shapes transport in OPPOSITE directions"
    (not (cterm_syntactic_equal
            (nf (CTransport (("i", g_i0), t)))
            (nf (CTransport (("i", g_i1), t)))));

  (* ─── (A) ua ANCHOR shape: Glue [(i=0)↦(A,e), (i=1)↦(B,id)] B ──────────── *)
  (* start face (i=0) taut ⇒ a0 = e.f(t); B constant ⇒ a1 = a0; target face
     (i=1) taut ⇒ result = idb.g(a1).  At the cubical layer that is
     bwd(idb, fwd(e,t)); a REAL identity equiv's .g β-collapses to the identity
     in the core, so end-to-end this is e.f(t) — the transport_ua_succ anchor. *)
  let b   = CTBase (TyPrim "B") in
  let idb = CVar "idb" in
  let ua_glue = CTGlue (b, [[("i", false)]; [("i", true)]], [(a, e); (b, idb)]) in
  let ua_res  = nf (CTransport (("i", ua_glue), t)) in
  check "ua: transp = idb.g ( e.f(t) )  (start-forward, target-inverse)"
    (cterm_syntactic_equal ua_res (bwd idb (fwd e t)));
  (* the univalence content — the forward map of the START equiv on t — is there *)
  let rec has_fwd_of_e = function
    | CHITConstr ("__equiv_fwd", eq :: x :: _) ->
        cterm_syntactic_equal eq e && cterm_syntactic_equal x t
    | CHITConstr (_, args) -> List.exists has_fwd_of_e args
    | CGlueElem (_, u, v) -> has_fwd_of_e u || has_fwd_of_e v
    | CUnglue u -> has_fwd_of_e u
    | _ -> false in
  check "ua: result carries e.f(t) (forward map of the START face = ua content)"
    (has_fwd_of_e ua_res);

  (* ─── (B) GENERIC multi-face Glue, NON-endpoint faces ─────────────────── *)
  (* Faces (j=0),(k=0) on dimensions independent of the transport dim i, with
     two DISTINCT equivalences e1,e2.  No endpoint collapse ⇒ transp yields a
     genuine glue-elem.  b0 = unglue(input); A constant ⇒ a1 = b0. *)
  let t1 = CTBase (TyPrim "T1") in
  let t2 = CTBase (TyPrim "T2") in
  let e1 = CVar "e1" and e2 = CVar "e2" in
  let gphi     = [ [("j", false)]; [("k", false)] ] in
  let gpartial = [ (t1, e1); (t2, e2) ] in
  let gty   = CTGlue (a, gphi, gpartial) in
  let input = CGlueElem (gphi, CVar "s0", CVar "b0") in
  let res   = nf (CTransport (("i", gty), input)) in
  let a1    = CVar "b0" in

  check "generic multi-face: transp result is a glue-elem"
    (match res with CGlueElem _ -> true | _ -> false);

  (* BASE EQUATION: unglue(result) = transp^i A (unglue input) *)
  check "generic: unglue(result) = transp A (unglue input)   [base equation]"
    (cterm_syntactic_equal
       (nf (CUnglue res))
       (nf (reduce_transport ("i", a) (unglue input))));

  (* PER-FACE FIBRE: restricting to (j=0) gives e1.g(a1); to (k=0) gives
     e2.g(a1).  A "first-pair" rule would give e1 on BOTH. *)
  let fib = match res with CGlueElem (_, f, _) -> f | _ -> res in
  check "generic face (j=0): fibre = e1.g(a1)"
    (cterm_syntactic_equal (at "j" I0 fib) (nf (bwd e1 a1)));
  check "generic face (k=0): fibre = e2.g(a1)   [2nd equiv, NOT the first pair]"
    (cterm_syntactic_equal (at "k" I0 fib) (nf (bwd e2 a1)));
  check "generic: the two faces give DIFFERENT fibres (per-face, not first-pair)"
    (not (cterm_syntactic_equal (at "j" I0 fib) (at "k" I0 fib)));

  (* THREE faces — guard against an accidental "handle first two" shortcut. *)
  let t3 = CTBase (TyPrim "T3") in
  let e3 = CVar "e3" in
  let gphi3     = [ [("j", false)]; [("k", false)]; [("m", false)] ] in
  let gpartial3 = [ (t1, e1); (t2, e2); (t3, e3) ] in
  let gty3   = CTGlue (a, gphi3, gpartial3) in
  let input3 = CGlueElem (gphi3, CVar "s0", CVar "b0") in
  let res3   = nf (CTransport (("i", gty3), input3)) in
  let fib3   = match res3 with CGlueElem (_, f, _) -> f | _ -> res3 in
  check "3-face generic: face (m=0) fibre = e3.g(a1)   (NEITHER e1 NOR e2)"
    (cterm_syntactic_equal (at "m" I0 fib3) (nf (bwd e3 a1)));
  check "3-face generic: faces (j=0),(k=0),(m=0) are pairwise DISTINCT"
    (not (cterm_syntactic_equal (at "j" I0 fib3) (at "k" I0 fib3))
     && not (cterm_syntactic_equal (at "k" I0 fib3) (at "m" I0 fib3))
     && not (cterm_syntactic_equal (at "j" I0 fib3) (at "m" I0 fib3)));

  (* ─── (D) DEGENERATE Glue (no partial system) = its base type A ────────── *)
  let deg = CTGlue (a, [], []) in
  check "degenerate Glue (no faces): transp = transp in base A = t (A constant)"
    (cterm_syntactic_equal (nf (CTransport (("i", deg), t))) t);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
