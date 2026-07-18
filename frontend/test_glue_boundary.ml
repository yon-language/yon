(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_glue_boundary.ml — the CCHM boundary-equation ORACLE for composition
 * (comp/hcomp) at a Glue type.
 *
 * The existing test_glue.ml only checks that comp/hcomp *reduce* (don't stay
 * stuck) and that the outer adjacency (face-active) rule fires. It does NOT
 * check that composition at a NON-DEGENERATE, MULTI-FACE Glue type
 *
 *     Glue [ psi_1 |-> (T_1, e_1), psi_2 |-> (T_2, e_2) ] A
 *
 * satisfies the two CCHM defining equations:
 *
 *   (F)  face equation:  on each face psi_k of the Glue's partial system, the
 *        result agrees definitionally with the k-th partial component — in
 *        particular the coherence patch on psi_k must use the k-th equivalence
 *        e_k (and the k-th type T_k), NOT the first pair for every face.
 *
 *   (B)  base / endpoint equation: with an always-false outer system the comp
 *        is the base; the T-component of the result is the hcomp of the
 *        T-parts in the per-face type T_k; unglue of the result is its
 *        A-component.
 *
 * These are exactly the equations the single-first-pair code
 *   `(t_ty, equiv) :: _`  in reduce_hcomp/reduce_comp violated: it used
 * (T_1, e_1) for EVERY face of the system, so restricting the result to the
 * second glue face psi_2 still produced e_1 instead of e_2.
 *
 * This file is the oracle for the multi-face fix. Do not weaken it.
 *)

open Surface_ast
open Cubical

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

(* Does the cterm t mention the marker __equiv_fwd applied to equiv `e`? *)
let rec mentions_fwd_of (e : cterm) (t : cterm) : bool =
  match t with
  | CHITConstr ("__equiv_fwd", eq :: _) when cterm_syntactic_equal eq e -> true
  | CHITConstr (_, args) -> List.exists (mentions_fwd_of e) args
  | CGlueElem (_, a, b) -> mentions_fwd_of e a || mentions_fwd_of e b
  | CUnglue a -> mentions_fwd_of e a
  | CPathLam (_, b) -> mentions_fwd_of e b
  | CPathApp (p, _) -> mentions_fwd_of e p
  | CComp (_, _, sides, base) | CHComp (_, _, sides, base) ->
      List.exists (fun (_, _, u) -> mentions_fwd_of e u) sides
      || mentions_fwd_of e base
  | CTransport (_, a) -> mentions_fwd_of e a
  | _ -> false

let () =
  Printf.printf "=== CCHM Glue boundary-equation oracle (multi-face comp/hcomp) ===\n\n";

  (* A NON-degenerate Glue with TWO faces and two DISTINCT, NON-identity
     equivalences.
       A            = base type
       psi_1 = (i=0),  T_1, e_1
       psi_2 = (i=1),  T_2, e_2
     (This is precisely the ua-shape system, but with a non-identity e_2 so the
      two faces are genuinely distinguishable.) *)
  let a   = CTBase (TyPrim "A") in
  let t1t = CTBase (TyPrim "T1") in
  let t2t = CTBase (TyPrim "T2") in
  let e1  = CVar "e1" in
  let e2  = CVar "e2" in
  let gphi    = [ [("i", false)] ; [("i", true)] ] in          (* psi_1 | psi_2 *)
  let partial = [ (t1t, e1) ; (t2t, e2) ] in
  let gty = CTGlue (a, gphi, partial) in

  (* A glue-elem element of gty (t-part and a-part are symbolic). *)
  let mk_glue tp ap = CGlueElem (gphi, CVar tp, CVar ap) in
  let u  = mk_glue "tj" "aj" in
  let u0 = mk_glue "t0" "a0" in

  (* The composition under test: hcomp along a FRESH dimension k, with a single
     outer side on the face (k=1). k is independent of i, so restricting to a
     glue face psi_k (i=0 / i=1) leaves the k-system intact. *)
  let hc = CHComp (gty, [[("k", true)]], [("s", [("k", true)], u)], u0) in
  let hc_nf = normalize_cterm hc in

  (* comp at a CONSTANT (i-independent) Glue type shares the hcomp path. *)
  let cp = CComp (gty, [[("k", true)]], [("s", [("k", true)], u)], u0) in
  let cp_nf = normalize_cterm cp in

  (* ── (0) the result is a glue-elem carrying the FULL glue system ─────── *)
  check "hcomp-Glue result is a glue-elem"
    (match hc_nf with CGlueElem _ -> true | _ -> false);
  check "comp-Glue (constant type) result is a glue-elem"
    (match cp_nf with CGlueElem _ -> true | _ -> false);

  (* ── (F) FACE EQUATION on psi_2 = (i=1): must use the 2nd equivalence e2 ──
     Restricting the composite to the second glue face makes the Glue type
     definitionally T_2 with equivalence e_2. The A-component's coherence patch
     on that face must therefore be built from e_2, not e_1.  The single-pair
     bug produced e_1 here. *)
  let hc_at_psi2 = normalize_cterm (subst_interval_in_cterm "i" I1 hc) in
  check "hcomp-Glue face psi_2 (i=1): coherence uses e2"
    (mentions_fwd_of e2 hc_at_psi2);
  check "hcomp-Glue face psi_2 (i=1): coherence does NOT use e1"
    (not (mentions_fwd_of e1 hc_at_psi2));

  (* ── (F) FACE EQUATION on psi_1 = (i=0): must use the 1st equivalence e1 ── *)
  let hc_at_psi1 = normalize_cterm (subst_interval_in_cterm "i" I0 hc) in
  check "hcomp-Glue face psi_1 (i=0): coherence uses e1"
    (mentions_fwd_of e1 hc_at_psi1);
  check "hcomp-Glue face psi_1 (i=0): coherence does NOT use e2"
    (not (mentions_fwd_of e2 hc_at_psi1));

  (* the two faces must be genuinely DIFFERENT after restriction (a single-pair
     implementation makes them identical) *)
  check "hcomp-Glue: face psi_1 and face psi_2 restrictions differ"
    (not (cterm_syntactic_equal hc_at_psi1 hc_at_psi2));

  (* comp at the constant Glue type obeys the same per-face equations *)
  let cp_at_psi2 = normalize_cterm (subst_interval_in_cterm "i" I1 cp) in
  let cp_at_psi1 = normalize_cterm (subst_interval_in_cterm "i" I0 cp) in
  check "comp-Glue face psi_2 (i=1): coherence uses e2, not e1"
    (mentions_fwd_of e2 cp_at_psi2 && not (mentions_fwd_of e1 cp_at_psi2));
  check "comp-Glue face psi_1 (i=0): coherence uses e1, not e2"
    (mentions_fwd_of e1 cp_at_psi1 && not (mentions_fwd_of e2 cp_at_psi1));

  (* ── (B) the whole system e1..e2 is preserved in the un-restricted term ──
     Before restriction, the composite mentions BOTH equivalences (one coherence
     side per glue face). The single-pair bug mentions only e1. *)
  check "hcomp-Glue (unrestricted) mentions e1"
    (mentions_fwd_of e1 hc_nf);
  check "hcomp-Glue (unrestricted) mentions e2"
    (mentions_fwd_of e2 hc_nf);

  (* ── (F) OUTER adjacency: restrict to the outer active face k=1 = side u ── *)
  check "hcomp-Glue outer face k=1: result = the side u"
    (cterm_syntactic_equal (normalize_cterm (subst_interval_in_cterm "k" I1 hc)) u);
  check "comp-Glue outer face k=1: result = the side u"
    (cterm_syntactic_equal (normalize_cterm (subst_interval_in_cterm "k" I1 cp)) u);

  (* ── (B) BASE equation: empty outer system => the base u0 ─────────────── *)
  check "hcomp-Glue base equation: empty phi => u0"
    (cterm_syntactic_equal (normalize_cterm (CHComp (gty, [], [], u0))) u0);
  check "comp-Glue base equation: empty phi => u0"
    (cterm_syntactic_equal (normalize_cterm (CComp (gty, [], [], u0))) u0);

  (* ── (B) T-component of the result is the hcomp of the T-parts ──────────
     unglue picks the A-component; the T-part is the first slot of the glue-elem
     and must be an hcomp whose base is the t-part of u0. *)
  check "hcomp-Glue: T-component is a composite whose base is the t-part of u0"
    (match hc_nf with
     | CGlueElem (_, tcomp, _) ->
         (match normalize_cterm tcomp with
          | CHComp (_, _, _, base) -> cterm_syntactic_equal base (CVar "t0")
          | _ -> false)
     | _ -> false);

  (* ── (B) unglue of the result is exactly its A-component ─────────────── *)
  check "hcomp-Glue: unglue(result) = the A-component (a-part)"
    (match hc_nf with
     | CGlueElem (_, _, acomp) ->
         cterm_syntactic_equal (normalize_cterm (CUnglue hc_nf)) (normalize_cterm acomp)
     | _ -> false);

  (* ── THREE faces: guard against an accidental "handle first two" fix ──── *)
  let t3t = CTBase (TyPrim "T3") in
  let e3  = CVar "e3" in
  let gphi3 = [ [("j", false)] ; [("j", true)] ; [("m", true)] ] in
  let partial3 = [ (t1t, e1) ; (t2t, e2) ; (t3t, e3) ] in
  let gty3 = CTGlue (a, gphi3, partial3) in
  let mk3 tp ap = CGlueElem (gphi3, CVar tp, CVar ap) in
  let hc3 = CHComp (gty3, [[("k", true)]],
                    [("s", [("k", true)], mk3 "tj" "aj")], mk3 "t0" "a0") in
  (* face psi_3 = (m=1): coherence must use e3, and neither e1 nor e2. *)
  let hc3_at_psi3 = normalize_cterm (subst_interval_in_cterm "m" I1 hc3) in
  check "3-face hcomp-Glue face psi_3 (m=1): coherence uses e3"
    (mentions_fwd_of e3 hc3_at_psi3);
  check "3-face hcomp-Glue face psi_3 (m=1): coherence uses NEITHER e1 NOR e2"
    (not (mentions_fwd_of e1 hc3_at_psi3) && not (mentions_fwd_of e2 hc3_at_psi3));
  (* whole system carries all three equivalences *)
  let hc3_nf = normalize_cterm hc3 in
  check "3-face hcomp-Glue (unrestricted) mentions all of e1, e2, e3"
    (mentions_fwd_of e1 hc3_nf && mentions_fwd_of e2 hc3_nf && mentions_fwd_of e3 hc3_nf);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
