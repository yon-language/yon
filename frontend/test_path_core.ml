(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_path_core.ml — oracle: paths are core-kernel citizens that compute.
 *
 * Builds paths as CORE terms (Ast.PLam / PApp / Transp) and checks that the
 * kernel normalizer (Builtins.reduce_with_builtins, which bridges to the
 * cubical engine) identifies paths equal after reduction without being
 * syntactically identical.
 *)

open Ast

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let nf t = Builtins.reduce_with_builtins Reduce.empty_ctx t

let () =
  Printf.printf "=== core-path computation oracle ===\n\n";

  let a = Var "a" in
  (* p = (<i> a) @ 0 and q = (<i> a) @ 1 : different applications of the same
   * constant path, not syntactically identical. *)
  let p = PApp (PLam ("i", a), I0) in
  let q = PApp (PLam ("i", a), I1) in

  check "p and q are NOT syntactically identical"
    (not (term_equal_env [] p q));

  check "(<i> a) @ 0  reduces to  a"
    (term_equal_env [] (nf p) a);

  check "(<i> a) @ 1  reduces to  a"
    (term_equal_env [] (nf q) a);

  check "p = q after reduction (non-trivial path equality in the core)"
    (term_equal_env [] (nf p) (nf q));

  (* transport along a CONSTANT type line is the identity: transp (<i> A) t = t *)
  let v = Var "v" in
  let tr = Transp (("i", TyPlace "number"), v) in
  check "transp (<i> number) v  reduces to  v (constant transport)"
    (term_equal_env [] (nf tr) v);

  (* hcomp with no sides reduces to the base — comp computes via the bridge *)
  let b = Var "b" in
  let hc = HComp (TyPlace "number", [], [], b) in
  check "hcomp with no sides  reduces to  base"
    (term_equal_env [] (nf hc) b);

  (* transport along a Path TYPE is structured, not constant: the bridge exposes
   * TyId as CTPath, so the engine turns transp into a composition (a path),
   * never mistaking it for the identity. *)
  let pth = Var "p" in
  let path_line = TyId (TyPlace "A", Var "x", Var "y") in
  let trp = Transp (("i", path_line), pth) in
  check "transp along a Path reduces to a path abstraction (structured, not constant)"
    (match nf trp with PLam _ -> true | _ -> false);

  (* Glue citizens through the bridge: unglue(glue v) computes back to v.
   * Exercises GlueElem/Unglue core constructors -> CGlueElem/CUnglue engine
   * -> normalization -> back to the core term. *)
  let v = Var "v" in
  let ug = Unglue (GlueElem ([], Var "t_on_phi", v)) in
  check "unglue(glue [phi|->t] a) reduces to a"
    (term_equal_env [] (nf ug) v);

  (* equivalence convention: e = Pair (f, (g, (eta, eps))), forward map = Fst e.
   * For the identity equivalence (f = id) the forward map applied to a point
   * computes to that point — the quasi-inverse Pair layout is sound. *)
  let idfun = Lam ("x", TyPlace "A", Var "x") in
  let h = Refl (Var "x") in
  let equiv_id = Pair (idfun, Pair (idfun, Pair (h, h))) in
  let fwd_applied = App (Fst equiv_id, Var "w") in
  check "equivalence forward (Fst) of identity equiv, applied, computes to the point"
    (term_equal_env [] (nf fwd_applied) (Var "w"));

  (* Univalence as a reduction rule: transport along a Glue type applies the
   * equivalence map that MEDIATES the two ends of the line — in the CCHM
   * direction.  For the line
   *     Glue [(i=1) ↦ (T, e)] A ,   e : T ≃ A ,
   * the type is A at i=0 and T at i=1, so transp (i:0→1) maps A → T, which is
   * the INVERSE map e.g = Fst (Snd e); the forward e.f = Fst e goes T → A, the
   * wrong way (and is ill-typed on a : A).  This is exactly the CCHM
   * fibre-correction centre t1' = e.g(a1) (Cohen–Coquand–Huber–Mörtberg 2018,
   * §6.2).  [The earlier placeholder applied Fst e unconditionally — the
   * forward map — which happened to agree only when T = A and e = id; these two
   * checks now pin the real per-face direction of the transp-Glue rule.] *)
  let e = Var "e" in
  let glue_ty = TyGlue (TyPlace "A", [[("i", true)]], [(TyPlace "T", e)]) in
  let tr_glue = Transp (("i", glue_ty), Var "t") in
  check "transp along Glue [i=1↦(T,e)] A applies the INVERSE map e.g : A→T"
    (term_equal_env [] (nf tr_glue) (App (Fst (Snd e), Var "t")));

  (* With CCore the equivalence Pair can be written INLINE in the Glue and still
   * cross the engine opaquely: transp uses the inverse (Fst (Snd _)), and when
   * that inverse is the identity the whole thing computes to the point. *)
  let equiv_inline =
    Pair (Var "f",
          Pair (Lam ("x", TyPlace "A", Var "x"),
                Pair (Refl (Var "x"), Refl (Var "x")))) in
  let glue_inline = TyGlue (TyPlace "A", [[("i", true)]], [(TyPlace "T", equiv_inline)]) in
  let tr_inline = Transp (("i", glue_inline), Var "t") in
  check "transp along Glue with INLINE equivalence Pair computes (CCore lift)"
    (term_equal_env [] (nf tr_inline) (Var "t"));

  (* hcomp at a non-degenerate Glue: the CCHM homogeneous rule redistributes
   * the composition into the T-component and the A-component (it no longer
   * stays a stuck whole-Glue hcomp), and unglue commutes into an hcomp in A. *)
  let a_ty = TyPlace "A" and t_ty = TyPlace "T" in
  let gphi = [[("i", true)]] in
  let glue_ty = TyGlue (a_ty, gphi, [(t_ty, Var "e")]) in
  let base_g = GlueElem (gphi, Var "t0", Var "a0") in
  let side_g = ("j", [("psi", true)], GlueElem (gphi, Var "tj", Var "aj")) in
  let hc_glue = HComp (glue_ty, [[("psi", true)]], [side_g], base_g) in
  check "hcomp at non-degenerate Glue redistributes to a glue-elem (not stuck)"
    (match nf hc_glue with GlueElem _ -> true | _ -> false);
  check "unglue(hcomp Glue) commutes into an hcomp in the base A"
    (match nf (Unglue hc_glue) with HComp _ -> true | _ -> false);

  (* comp at a non-degenerate Glue (constant type) computes via the homogeneous
   * rule — no longer a stuck CComp. *)
  let comp_glue = Comp (glue_ty, [[("psi", true)]], [side_g], base_g) in
  check "comp at non-degenerate Glue computes (= hcomp-Glue, not stuck)"
    (match nf comp_glue with GlueElem _ -> true | _ -> false);

  (* ── vetrina: S1 ≃ S1 via ua, transport computes ──────────────────── *)
  (* e : S1 ≃ S1 the identity equivalence (Pair (f,(g,(eta,eps))), f=g=id).
   * ua(e) is the Glue [i=1 ↦ (S1, e)] S1; transporting a point along it
   * applies the mediating map (the inverse e.g : A→T), and for the identity
   * (f=g=id) it computes to the point. *)
  let s1 = TyPlace "S1" in
  let id_s1 = Lam ("z", s1, Var "z") in
  let e_s1 = Pair (id_s1, Pair (id_s1, Pair (Refl (Var "z"), Refl (Var "z")))) in
  let ua_e = TyGlue (s1, [[("i", true)]], [(s1, e_s1)]) in
  let transported = Transp (("i", ua_e), Var "x") in
  check "vetrina: transp along ua(id : S1 ≃ S1) computes to the point"
    (term_equal_env [] (nf transported) (Var "x"));

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
