(* test_glue.ml — oracle for the task-3 surface: Glue, univalence-as-computation,
 * and the HIT scaffold. Measures honestly what already reduces vs. what is a
 * placeholder.
 *
 * Key honest caveat: the univalence computation rule reduces transp along a Glue
 * to the forward map of the equivalence, but models that application as the
 * marker CHITConstr "__equiv_fwd" [e; t] — there is no first-class App at this
 * layer, so it is a canonical *form*, not a genuine semantic application. And,
  * isEquiv now has a STRUCTURAL GATE in the surface typing (cubical_bindings:
 * ua/equiv require the equivalence structure f, g, eta, eps, not a bare
 * function). The engine here computes the forward map under that gate.
 *)

open Surface_ast
open Cubical

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let () =
  Printf.printf "=== Glue / univalence / HIT oracle (task 3 surface) ===\n\n";

  let x = CVar "x" in
  let y = CVar "y" in
  let t = CVar "t" in
  let e = CVar "e" in
  let a = CTBase (TyPrim "A") in
  let tT = CTBase (TyPrim "T") in

  (* (1) univalence-as-computation: transp along Glue [(i=0) -> (T,e)] A applied
     to t reduces to the equivalence forward-map marker on t *)
  let glue_ty = CTGlue (a, [[("i", false)]], [(tT, e)]) in
  check "transp (Glue [(T,e)] A) t  reduces to  __equiv_fwd(e, t)"
    (cterm_equal (CTransport (("i", glue_ty), t))
                 (CHITConstr ("__equiv_fwd", [e; t])));

  (* (2) transp along a Glue with NO partial equivalence is the identity *)
  check "transp (Glue [] A) t  =  t"
    (cterm_equal (CTransport (("i", CTGlue (a, [], [])), t)) t);

  (* (3) Glue extensionality: unglue (glue [phi|->t] a) = a *)
  check "unglue (glue [phi|->t] a)  =  a"
    (cterm_equal (CUnglue (CGlueElem ([], t, t))) t);

  (* (4) transp along a Path type reduces (to a comp under a path-abstraction),
     i.e. it does not stay a stuck CTransport *)
  let tr_path =
    normalize_cterm
      (CTransport (("i", CTPath (a, x, y)), CPathLam ("m", x))) in
  check "transp at Path type reduces (not a stuck CTransport)"
    (match tr_path with CTransport _ -> false | _ -> true);

  (* (5) HIT scaffold: arity lookup on an S^1 signature (base : point, loop : path) *)
  let s1 = {
    hit_name = "S1";
    hit_points = [("base", [])];
    hit_paths  = [("loop", [], CHITConstr ("base", []), CHITConstr ("base", []))];
  } in
  check "S1 scaffold: arity(base) = Some 0"
    (hit_constructor_arity s1 "base" = Some 0);
  check "S1 scaffold: arity(loop) = Some 0   (no params)"
    (hit_constructor_arity s1 "loop" = Some 0);
  check "S1 scaffold: arity(unknown) = None"
    (hit_constructor_arity s1 "nope" = None);

  (* ── boundary blindaggio: face-active (adjacency) rule ─────────────── *)

  (* (6) hcomp adjacency: hcomp A [k=1 |-> u] u0 restricted to k=1 reduces to u *)
  let u = CVar "u" and u0 = CVar "u0" in
  let hc = CHComp (a, [[("k", true)]], [("s", [("k", true)], u)], u0) in
  check "hcomp adjacency: restriction to the active face gives the side"
    (cterm_syntactic_equal (normalize_cterm (subst_interval_in_cterm "k" I1 hc)) u);

  (* (7) hcomp with a contradicted face: the side drops, result is the base *)
  check "hcomp adjacency: restriction to a contradicting face gives the base"
    (cterm_syntactic_equal (normalize_cterm (subst_interval_in_cterm "k" I0 hc)) u0);

  (* (8) hcomp-Glue adjacency: restricting to the active face yields the side
     glue-elem unchanged — the redistribution respects the boundary *)
  let gphi = [[("i", true)]] in
  let glue_ty = CTGlue (a, gphi, [(tT, e)]) in
  let ug  = CGlueElem (gphi, CVar "tj", CVar "aj") in
  let ug0 = CGlueElem (gphi, CVar "t0", CVar "a0") in
  let hcg = CHComp (glue_ty, [[("k", true)]], [("s", [("k", true)], ug)], ug0) in
  check "hcomp-Glue adjacency: restriction to active face gives the side glue-elem"
    (cterm_syntactic_equal (normalize_cterm (subst_interval_in_cterm "k" I1 hcg)) ug);

  (* (9) comp-Glue (= hcomp-Glue at constant type) obeys the same adjacency *)
  let cpg = CComp (glue_ty, [[("k", true)]], [("s", [("k", true)], ug)], ug0) in
  check "comp-Glue adjacency: restriction to active face gives the side glue-elem"
    (cterm_syntactic_equal (normalize_cterm (subst_interval_in_cterm "k" I1 cpg)) ug);

  (* ── muro 3: the GENERIC HIT eliminator, S1 as one instance ────────── *)
  let b = CVar "b" in
  let lpath = CPathLam ("i", CPathApp (CVar "q", IVar "i")) in
  let elim sc = CHITElim ([("base", b); ("loop", lpath)], sc) in

  check "S1: loop@0 = base"
    (cterm_equal (CPathApp (CHITConstr ("loop", []), I0)) (CHITConstr ("base", [])));
  check "S1: loop@1 = base"
    (cterm_equal (CPathApp (CHITConstr ("loop", []), I1)) (CHITConstr ("base", [])));
  check "generic elim (S1): at base = b"
    (cterm_equal (elim (CHITConstr ("base", []))) b);
  check "generic elim (S1): at loop@r computes to l@r"
    (cterm_equal (elim (CPathApp (CHITConstr ("loop", []), IVar "r")))
                 (CPathApp (lpath, IVar "r")));
  check "generic elim (S1) coherence: at loop@0 = b"
    (cterm_equal (elim (CPathApp (CHITConstr ("loop", []), I0))) b);

  (* same eliminator, different HIT: Quotient — point ctor with an argument.
     elim {inj |-> f} (inj a) defers (f a) to the core via the __app marker. *)
  check "generic elim (Quotient): inj a fires the inj branch, applies f to a"
    (cterm_syntactic_equal
       (normalize_cterm (CHITElim ([("inj", CVar "f")], CHITConstr ("inj", [CVar "a"]))))
       (CHITConstr ("__app", [CVar "f"; CVar "a"])));

  (* same eliminator, Suspension — a parametric PATH ctor: merid x @ r = (m x)@r *)
  check "generic elim (Suspension): merid x @ r computes to (m x)@r"
    (cterm_syntactic_equal
       (normalize_cterm
          (CHITElim ([("merid", CVar "m")],
                     CPathApp (CHITConstr ("merid", [CVar "x"]), IVar "r"))))
       (CPathApp (CHITConstr ("__app", [CVar "m"; CVar "x"]), IVar "r")));

  (* same eliminator, S2 — a 2-DIMENSIONAL path ctor: surf @ r @ s = (case)@r@s *)
  check "generic elim (S2): surf @ r @ s computes to (case)@r@s (2-dim path)"
    (cterm_syntactic_equal
       (normalize_cterm
          (CHITElim ([("surf", CVar "sf")],
                     CPathApp (CPathApp (CHITConstr ("surf", []), IVar "r"), IVar "s"))))
       (CPathApp (CPathApp (CVar "sf", IVar "r"), IVar "s")));

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
