(* test_path.ml — oracle for non-trivial cubical path equality.
 *
 * A *computational* cubical kernel (vs. one "dead on paper") recognizes two
 * paths written differently as equal after reduction. cterm_equal normalizes
 * both sides (path beta, transport, comp) and compares up to alpha. This oracle
 * exhibits such pairs, pins a sanity bound (distinct variables not equal), and
 * checks type-level Path equality after endpoint reduction.
 *
 * Built as a dune executable (added to the names list).
 *)

open Surface_ast
open Cubical

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let () =
  Printf.printf "=== non-trivial cubical path equality oracle ===\n\n";

  let x = CVar "x" in
  let y = CVar "y" in

  (* (1) path beta at 1: (<i> x) @ 1  reduces to  x *)
  check "(<i> x) @ 1  =  x"
    (cterm_equal (CPathApp (CPathLam ("i", x), I1)) x);

  (* (2) path beta at 0: (<i> x) @ 0  =  x *)
  check "(<i> x) @ 0  =  x"
    (cterm_equal (CPathApp (CPathLam ("i", x), I0)) x);

  (* (3) alpha: the bound interval name is irrelevant *)
  check "<i> x  =  <j> x   (alpha)"
    (cterm_equal (CPathLam ("i", x)) (CPathLam ("j", x)));

  (* (4) transport along a CONSTANT type is the identity: transp (const A) x = x *)
  check "transp (const A) x  =  x"
    (cterm_equal (CTransport (("i", CTBase (TyPrim "A")), x)) x);

  (* (5) nested rewrite: (<i> ((<j> x) @ 0)) @ 1  =  x   (two beta steps) *)
  check "(<i> ((<j> x) @ 0)) @ 1  =  x   (two beta steps)"
    (cterm_equal
       (CPathApp (CPathLam ("i", CPathApp (CPathLam ("j", x), I0)), I1)) x);

  (* (6) SANITY: distinct variables are not equal *)
  check "x  !=  y"
    (not (cterm_equal x y));

  (* (7) TYPE-level: Path A x ((<i> x)@1)  =  Path A x x via decidable_equal_cubical *)
  let a = CTBase (TyPrim "A") in
  check "Path A x ((<i>x)@1)  =  Path A x x   (type eq after endpoint reduction)"
    (decidable_equal_cubical
       (CTPath (a, x, CPathApp (CPathLam ("i", x), I1)))
       (CTPath (a, x, x)));

  (* (8) comp with empty phi reduces to the base: comp A [bot] [] u0 = u0 *)
  let u0 = CVar "u0" in
  check "comp A [bot] [] u0  =  u0   (empty disjunction = base)"
    (cterm_equal (CComp (a, [], [], u0)) u0);

  (* (9) hcomp with empty phi reduces to the base *)
  check "hcomp A [bot] [] u0  =  u0"
    (cterm_equal (CHComp (a, [], [], u0)) u0);

  (* (10) comp at a Path type reduces to a path-abstraction (not a stuck CComp) *)
  let comp_path =
    normalize_cterm
      (CComp (CTPath (a, x, y), [[("k", true)]],
              [("s", [("k", true)], y)], CPathLam ("m", x))) in
  check "comp at Path type reduces (not a stuck CComp)"
    (match comp_path with CComp _ -> false | _ -> true);

  (* (11) comp at a NON-degenerate Glue now COMPUTES: the homogeneous rule
     redistributes into a glue-elem (T-part and A-part) via the forward map,
     no isEquiv needed. It no longer stays a stuck CComp. *)
  let glue_nd = CTGlue (a, [[("k", true)]], [(a, CVar "e")]) in
  let comp_glue =
    normalize_cterm
      (CComp (glue_nd, [[("k", true)]], [("s", [("k", true)], x)], u0)) in
  check "comp at non-degenerate Glue computes to a glue-elem (not stuck)"
    (match comp_glue with CGlueElem _ -> true | _ -> false);

  (* (12) PathP — the DEPENDENT path type. comp at PathP computes to a
     path-abstraction (dependent analogue of oracle 10, not a stuck CComp). *)
  let pathp = CTPathP (("i", a), x, y) in
  let comp_pathp =
    normalize_cterm
      (CComp (pathp, [[("k", true)]], [("s", [("k", true)], CVar "u")], u0)) in
  check "comp at PathP computes to a path-abstraction (not stuck)"
    (match comp_pathp with CPathLam _ -> true | _ -> false);

  (* (13) PathP boundary via transport: transp <i> (PathP (<j> A) x y) p must
     respect the endpoints — result @ 0 = x and result @ 1 = y. *)
  let transp_pathp = CTransport (("i", CTPathP (("j", a), x, y)), CVar "p") in
  check "transp at PathP: boundary @ 0 = left endpoint x"
    (cterm_equal (normalize_cterm (CPathApp (transp_pathp, I0))) x);
  check "transp at PathP: boundary @ 1 = right endpoint y"
    (cterm_equal (normalize_cterm (CPathApp (transp_pathp, I1))) y);

  (* (14) PathP alpha: the dependent-path binder name is irrelevant *)
  check "PathP (<i> A) x y  =  PathP (<j> A) x y   (alpha)"
    (decidable_equal_cubical
       (CTPathP (("i", a), x, y)) (CTPathP (("j", a), x, y)));

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
