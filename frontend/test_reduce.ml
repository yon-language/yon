(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_reduce.ml — oracle for the R_Yon kernel reducer (reduce.ml), each rule
 * exercised in isolation through the public API (step / reduce / try_eta /
 * is_value). Terms are built as CORE terms and compared with term_equal_env,
 * the alpha-equivalence used by the rest of the kernel test-suite.
 *)

open Ast

let pass = ref 0
let fails = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fails; Printf.printf "  [FAIL] %s\n" name)

let ctx = Reduce.empty_ctx
let ty  = TyPlace "A"

let () =
  Printf.printf "=== R_Yon reducer (reduce.ml) oracle ===\n\n";

  (* ── beta in one step: (lambda x. x) a  ~>  a ─────────────────────── *)
  let a = Var "a" in
  let id_app = App (Lam ("x", ty, Var "x"), a) in
  check "beta: (lambda x. x) a  =  a (reduce)"
    (term_equal_env [] (Reduce.reduce ctx id_app) a);
  check "beta: step takes exactly one step to a"
    (match Reduce.step ctx id_app with
     | Some t' -> term_equal_env [] t' a
     | None -> false);

  (* ── eta: lambda x. (f x) ~> f when x not in FV(f) ───────────────── *)
  let f = Var "f" in
  check "eta fires: lambda x. (f x) -> Some f  (x not free in f)"
    (match Reduce.try_eta (Lam ("x", ty, App (f, Var "x"))) with
     | Some t' -> term_equal_env [] t' f
     | None -> false);
  (* x occurs in the function position: eta must NOT fire (would capture). *)
  check "eta blocked: lambda x. (x x) -> None  (x free in head)"
    (Reduce.try_eta (Lam ("x", ty, App (Var "x", Var "x"))) = None);
  (* wrong shape: not an eta redex at all. *)
  check "eta non-redex: lambda x. (f y) -> None"
    (Reduce.try_eta (Lam ("x", ty, App (f, Var "y"))) = None);

  (* ── is_value ─────────────────────────────────────────────────────── *)
  check "is_value: Lam is a value"
    (Reduce.is_value (Lam ("x", ty, Var "x")));
  check "is_value: encoded number Var \"__num_5\" is a value"
    (Reduce.is_value (Var "__num_5"));
  check "is_value: a beta-redex App is NOT a value"
    (not (Reduce.is_value id_app));
  check "is_value: a bare free Var is NOT a value"
    (not (Reduce.is_value (Var "x")));

  (* ── multi-step: a redex needing >1 step normalizes to the value ──── *)
  (* (lambda x. lambda y. x) p q  ~>  (lambda y. p) q  ~>  p          *)
  let p = Var "p" and q = Var "q" in
  let k = Lam ("x", ty, Lam ("y", ty, Var "x")) in
  let kpq = App (App (k, p), q) in
  check "multi-step: (lambda x y. x) p q  =  p"
    (term_equal_env [] (Reduce.reduce ctx kpq) p);

  (* ── confluence on a small term: both projection routes agree ─────── *)
  (* On Pair(a,b): Fst -> a, Snd -> b; reassembling and projecting lands
   * back on the components, independent of order. *)
  let pa = Var "u" and pb = Var "v" in
  let pair = Pair (pa, pb) in
  check "confluent: Fst(Pair(u,v)) normalizes to u"
    (term_equal_env [] (Reduce.reduce ctx (Fst pair)) pa);
  check "confluent: Snd(Pair(u,v)) normalizes to v"
    (term_equal_env [] (Reduce.reduce ctx (Snd pair)) pb);

  Printf.printf "\n%d passed, %d failed\n" !pass !fails;
  if !fails = 0 then exit 0 else exit 1
