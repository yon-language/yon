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
  let tr = Transp (("i", TyBase "number"), v) in
  check "transp (<i> number) v  reduces to  v (constant transport)"
    (term_equal_env [] (nf tr) v);

  (* hcomp with no sides reduces to the base — comp computes via the bridge *)
  let b = Var "b" in
  let hc = HComp (TyBase "number", [], [], b) in
  check "hcomp with no sides  reduces to  base"
    (term_equal_env [] (nf hc) b);

  (* transport along a Path TYPE is structured, not constant: the bridge exposes
   * TyId as CTPath, so the engine turns transp into a composition (a path),
   * never mistaking it for the identity. *)
  let pth = Var "p" in
  let path_line = TyId (TyBase "A", Var "x", Var "y") in
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
  let idfun = Lam ("x", TyBase "A", Var "x") in
  let h = Refl (Var "x") in
  let equiv_id = Pair (idfun, Pair (idfun, Pair (h, h))) in
  let fwd_applied = App (Fst equiv_id, Var "w") in
  check "equivalence forward (Fst) of identity equiv, applied, computes to the point"
    (term_equal_env [] (nf fwd_applied) (Var "w"));

  (* Univalence as a reduction rule: transport along a Glue type applies the
   * forward map of the partial equivalence. With the equivalence referred by
   * name e, transp reduces to (Fst e) applied to the point — the computational
   * content of ua. Composed with the case above (forward of the identity equiv
   * computes to the point), this is univalence computing end-to-end. *)
  let e = Var "e" in
  let glue_ty = TyGlue (TyBase "A", [[("i", true)]], [(TyBase "T", e)]) in
  let tr_glue = Transp (("i", glue_ty), Var "t") in
  check "transp along Glue applies the equivalence forward map (univalence computes)"
    (term_equal_env [] (nf tr_glue) (App (Fst e, Var "t")));

  (* With CCore the equivalence Pair can be written INLINE in the Glue and still
   * cross the engine opaquely: transp applies the forward map (Fst), and for
   * the identity equivalence the whole thing computes to the point. *)
  let equiv_inline =
    Pair (Lam ("x", TyBase "T", Var "x"),
          Pair (Var "g", Pair (Refl (Var "x"), Refl (Var "x")))) in
  let glue_inline = TyGlue (TyBase "A", [[("i", true)]], [(TyBase "T", equiv_inline)]) in
  let tr_inline = Transp (("i", glue_inline), Var "t") in
  check "transp along Glue with INLINE equivalence Pair computes (CCore lift)"
    (term_equal_env [] (nf tr_inline) (Var "t"));

  (* hcomp at a non-degenerate Glue: the CCHM homogeneous rule redistributes
   * the composition into the T-component and the A-component (it no longer
   * stays a stuck whole-Glue hcomp), and unglue commutes into an hcomp in A. *)
  let a_ty = TyBase "A" and t_ty = TyBase "T" in
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
   * applies the forward map, and for the identity it computes to the point. *)
  let s1 = TyPlace "S1" in
  let id_s1 = Lam ("z", s1, Var "z") in
  let e_s1 = Pair (id_s1, Pair (id_s1, Pair (Refl (Var "z"), Refl (Var "z")))) in
  let ua_e = TyGlue (s1, [[("i", true)]], [(s1, e_s1)]) in
  let transported = Transp (("i", ua_e), Var "x") in
  check "vetrina: transp along ua(id : S1 ≃ S1) computes to the point"
    (term_equal_env [] (nf transported) (Var "x"));

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
