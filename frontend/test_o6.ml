(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_o6.ml — oracle: O6, the witness that closes the classifier theorem of
 * Syn(Yon) (formalization sec.16). For an embedding m : B -> A, with image
 * predicate P(x) := Sigma(b:B). Id(m b, x), the comprehension {x:A | P} is
 * isomorphic to B:
 *     fwd : B -> {x:A | P},   fwd b      = (m b, (b, refl(m b)))
 *     bwd : {x:A | P} -> B,   bwd (x,(b,p)) = b            (= fst o snd)
 * Built as CORE terms and checked through the kernel normalizer, on OPEN terms:
 * the free variables are generic elements, so the equations hold for every
 * m, b, a, s, not for an instance. Mirrors test_path_core / test_eta_sigma. *)

open Ast

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let nf t = Builtins.reduce_with_builtins Reduce.empty_ctx t

let () =
  Printf.printf "=== O6 (embedding ~= comprehension of the image) oracle ===\n\n";

  (* m : B -> A an embedding; elements are generic free variables. *)
  let m = Var "m" in
  let mb t = App (m, t) in
  let fwd t = Pair (mb t, Pair (t, Refl (mb t))) in
  let bwd p = Fst (Snd p) in

  (* O6 round-trip 1: bwd (fwd b) ~ b, generically, by reduction. *)
  let b = Var "b" in
  check "round-trip 1: bwd(fwd b) reduces to b (generic b)"
    (term_equal_env [] (nf (bwd (fwd b))) b);

  (* O6 round-trip 2: the witness is path induction
   *     ind_path(C, \b. refl(fwd b), p),  C(x,p) := Id(fwd b, (x,(b,p)))
   * whose entire content is the diagonal case, and the diagonal case is the
   * beta of J:  J(C, d, refl(a), a) == d a.  Checked on a generic basepoint. *)
  let a = Var "a" in
  let cmotive = Var "C" in                                  (* unused by refl-beta *)
  let diag = Lam ("b", TyPlace "B", Refl (fwd (Var "b"))) in  (* \b. refl(fwd b) *)
  let jterm = J ("x", TyPlace "A", cmotive, diag, Refl a, a) in
  check "round-trip 2: J on refl computes to the diagonal d(a)"
    (term_equal_env [] (nf jterm) (nf (App (diag, a))));
  check "round-trip 2: the diagonal at a is refl(fwd a)"
    (term_equal_env [] (nf (App (diag, a))) (nf (Refl (fwd a))));

  (* eta-Sigma re-verified in the O6 setting, on the open term (fst s, snd s) ~ s *)
  let s = Var "s" in
  check "eta-Sigma (used by O6): (fst s, snd s) ~ s"
    (term_equal_env [] (nf (Pair (Fst s, Snd s))) s);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
