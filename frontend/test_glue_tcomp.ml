(* test_glue_tcomp.ml — the T-component (fiber) of hcomp at a type-VARYING,
 * multi-face Glue restricts to the correct PER-FACE composite: on psi_k the fiber
 * must be the composition IN T_k. Before the per-face fix, reduce_hcomp composed
 * the fiber once in T_1, so restricting the result to psi_2 read T_1's rule where
 * psi_2 genuinely lives in T_2 (exhibited: t1 == T1-composite, != T2-composite).
 * This pins the fix. Distinct T_1 = CTBase, T_2 = CTPath -> different reduction
 * rules, so a per-face error is observable in the restricted fiber. *)

open Cubical

let ok = ref 0 and bad = ref 0
let check l c = if c then incr ok else (incr bad; Printf.printf "  [FAIL] %s\n" l)

(* restrict a cterm to a glue face by forcing dimension i, then normalize:
   subst_interval_in_face drops the satisfied atom -> the face becomes [] (active)
   and the face-active rule fires that side. *)
let restr r v = normalize_cterm (subst_interval_in_cterm "i" r v)

let () =
  let a   = CTBase (TyPrim "A") in
  let t1t = CTBase (TyPrim "T1") in                            (* psi_1 fiber: base rule *)
  let t2t = CTPath (CTBase (TyPrim "B"), CVar "x", CVar "y") in (* psi_2 fiber: PATH rule *)
  let e1  = CVar "e1" and e2 = CVar "e2" in
  let gphi    = [ [("i", false)] ; [("i", true)] ] in          (* psi_1=(i=0) | psi_2=(i=1) *)
  let partial = [ (t1t, e1) ; (t2t, e2) ] in
  let gty = CTGlue (a, gphi, partial) in
  let mk tp ap = CGlueElem (gphi, CVar tp, CVar ap) in
  let u  = mk "tj" "aj" and u0 = mk "t0" "a0" in
  let phi = [ [("k", true)] ] in
  let sides = [ ("s", [("k", true)], u) ] in

  let tpart v = match v with CGlueElem (_, t, _) -> t | _ -> v in
  let t_sides = List.map (fun (nm, f, x) -> (nm, f, tpart x)) sides in
  let t0 = tpart u0 in
  let t1_ref = reduce_hcomp t1t phi t_sides t0 in              (* composite in T_1 *)
  let t2_ref = reduce_hcomp t2t phi t_sides t0 in              (* composite in T_2 *)

  (match reduce_hcomp gty phi sides u0 with
   | CGlueElem (_, t1, _) ->
       check "T-component restricts to the T1-composite on psi_1 (i=0)"
         (cterm_syntactic_equal (restr I0 t1) (restr I0 t1_ref));
       check "T-component restricts to the T2-composite on psi_2 (i=1) [per-face fix]"
         (cterm_syntactic_equal (restr I1 t1) (restr I1 t2_ref));
       (* and the two per-face fibers are genuinely DIFFERENT (else the test is vacuous) *)
       check "the two per-face fibers are distinguishable (T1 rule != T2 rule)"
         (not (cterm_syntactic_equal (restr I0 t1_ref) (restr I1 t2_ref)))
   | _ -> check "result is a glue-elem" false);

  (* ── THREE faces with THREE distinct-rule fibers — guard against a fix that
       only handles the first two faces. psi_3 = (m=0), fiber in T_3 = a distinct
       Path type. Restrict over m to reach it. ── *)
  let t3t = CTPath (CTBase (TyPrim "C"), CVar "u", CVar "v") in
  let e3  = CVar "e3" in
  let gphi3    = [ [("i", false)] ; [("i", true)] ; [("m", false)] ] in
  let partial3 = [ (t1t, e1) ; (t2t, e2) ; (t3t, e3) ] in
  let gty3 = CTGlue (a, gphi3, partial3) in
  let mk3 tp ap = CGlueElem (gphi3, CVar tp, CVar ap) in
  let u3 = mk3 "tj" "aj" and u03 = mk3 "t0" "a0" in
  let sides3 = [ ("s", [("k", true)], u3) ] in
  let t_sides3 = List.map (fun (nm, f, x) -> (nm, f, tpart x)) sides3 in
  let t0_3 = tpart u03 in
  let restr_m r v = normalize_cterm (subst_interval_in_cterm "m" r v) in
  let t3_ref = reduce_hcomp t3t phi t_sides3 t0_3 in
  (match reduce_hcomp gty3 phi sides3 u03 with
   | CGlueElem (_, t1, _) ->
       check "3-face: T-component restricts to the T3-composite on psi_3 (m=0)"
         (cterm_syntactic_equal (restr_m I0 t1) (restr_m I0 t3_ref))
   | _ -> check "3-face result is a glue-elem" false);

  Printf.printf "GLUE T-COMPONENT per-face: %d ok | %d FAIL\n" !ok !bad;
  if !bad > 0 then exit 1 else exit 0
