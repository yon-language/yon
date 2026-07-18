(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_pretty.ml — oracle for the Core pretty-printer (pretty.ml).
 *
 * pretty.ml is a pure Core-AST -> string printer used for debug/inspection. Each
 * constructor has a fixed rendering; this pins them as known-answer. Covers
 * pp_ty, pp_interval, pp_term, pp_op_sig, pp_handler, pp_compact. The World /
 * Place / Reduction / Comp / HComp / GlueElem / Glue cases need heavy records or
 * face systems and are exercised through the corpus instead (see AUDIT.md). *)

open Ast

let pass = ref 0
let fails = ref 0
let check name got want =
  if got = want then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fails;
        Printf.printf "  [FAIL] %s: got %S want %S\n" name got want)

let () =
  Printf.printf "=== pretty-printer (pretty.ml) oracle ===\n\n";
  let a = TyPlace "A" and b = TyPlace "B" in

  (* ── pp_ty ────────────────────────────────────────────────────────── *)
  check "ty: Type_0"       (Pretty.pp_ty (TyType 0)) "Type";
  check "ty: Type_n"       (Pretty.pp_ty (TyType 3)) "Type_3";
  check "ty: arrow"        (Pretty.pp_ty (TyArrow (a, b))) "(A -> B)";
  check "ty: pi"           (Pretty.pp_ty (TyPi ("x", a, b))) "Pi(x : A). B";
  check "ty: sigma"        (Pretty.pp_ty (TySigma ("x", a, b))) "Sigma(x : A). B";
  check "ty: id"           (Pretty.pp_ty (TyId (a, Var "x", Var "y"))) "Id_A";
  check "ty: place"        (Pretty.pp_ty (TyPlace "Order")) "Order";
  check "ty: stream"       (Pretty.pp_ty (TyStream (TyPlace "T"))) "stream of T";
  check "ty: dir universe" (Pretty.pp_ty (TyDirUniverse 2)) "U_omega_2";
  check "ty: el"           (Pretty.pp_ty (TyEl (Var "c"))) "El(...)";
  check "ty: pathp"        (Pretty.pp_ty (TyPathP (("i", a), Var "x", Var "y"))) "PathP(<i> A)";

  (* ── pp_interval ──────────────────────────────────────────────────── *)
  check "iv: I0"   (Pretty.pp_interval I0) "0";
  check "iv: I1"   (Pretty.pp_interval I1) "1";
  check "iv: var"  (Pretty.pp_interval (IVar "i")) "i";
  check "iv: min"  (Pretty.pp_interval (IMin (I0, I1))) "(0 /\\ 1)";
  check "iv: max"  (Pretty.pp_interval (IMax (I0, I1))) "(0 \\/ 1)";
  check "iv: neg"  (Pretty.pp_interval (INeg I0)) "~0";

  (* ── pp_term ──────────────────────────────────────────────────────── *)
  check "tm: var"        (Pretty.pp_term (Var "x")) "x";
  check "tm: lam"        (Pretty.pp_term (Lam ("x", a, Var "x"))) "lambdax:A. x";
  check "tm: app"        (Pretty.pp_term (App (Var "f", Var "a"))) "(f a)";
  check "tm: scope"      (Pretty.pp_term (Scope ("S", Var "x"))) "\xe2\x9f\xa8x\xe2\x9f\xa9_S";
  check "tm: emit"       (Pretty.pp_term (Emit (Var "x"))) "emit x";
  check "tm: refl"       (Pretty.pp_term (Refl (Var "x"))) "refl(x)";
  check "tm: J"          (Pretty.pp_term (J ("x", a, Var "c", Var "d", Var "p", Var "b")))
                         "J[x:A. c, d, p, b]";
  check "tm: pair"       (Pretty.pp_term (Pair (Var "a", Var "b"))) "(a, b)";
  check "tm: fst"        (Pretty.pp_term (Fst (Var "p"))) "fst p";
  check "tm: snd"        (Pretty.pp_term (Snd (Var "p"))) "snd p";
  check "tm: streamcons" (Pretty.pp_term (StreamCons (Var "h", Var "k"))) "h :: k";
  check "tm: unit"       (Pretty.pp_term Unit) "()";
  check "tm: plam"       (Pretty.pp_term (PLam ("i", Var "x"))) "<i> x";
  check "tm: papp"       (Pretty.pp_term (PApp (Var "p", I0))) "(p @ 0)";
  check "tm: transp"     (Pretty.pp_term (Transp (("i", a), Var "t"))) "transp <i>A t";
  check "tm: unglue"     (Pretty.pp_term (Unglue (Var "g"))) "unglue(g)";
  check "tm: hitconstr nullary" (Pretty.pp_term (HITConstr ("base", []))) "base()";
  check "tm: hitconstr arg"     (Pretty.pp_term (HITConstr ("merid", [Var "a"]))) "merid(a)";
  check "tm: hitelim no-binder"
    (Pretty.pp_term (HITElim ([("base", [], Var "b")], Var "s")))
    "hit_elim([base => b], s)";
  check "tm: hitelim binder"
    (Pretty.pp_term (HITElim ([("merid", ["a"], Var "b")], Var "s")))
    "hit_elim([merid(a) => b], s)";

  (* ── pp_op_sig / pp_handler ───────────────────────────────────────── *)
  check "op_sig"
    (Pretty.pp_op_sig
       { op_name = "deposit"; op_params = [ ("amt", TyPlace "N") ];
         op_return = TyPlace "Bool"; op_algebra = None })
    "operation deposit(amt: N): Bool";
  check "handler"
    (Pretty.pp_handler
       { hc_op = "deposit"; hc_params = [ ("amt", TyPlace "N") ]; hc_body = Var "x" })
    "on deposit(amt: N) \xe2\x86\xa6 x";

  (* ── pp_compact (delegates to pp_term for newline-free terms) ─────── *)
  check "compact" (Pretty.pp_compact (App (Var "f", Var "a"))) "(f a)";

  Printf.printf "\n%d passed, %d failed\n" !pass !fails;
  if !fails > 0 then exit 1
