(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_sct.ml — oracle for the Size-Change Termination gate (block 1.6).
 *
 * Subterm order only. Verifies the four roadmap acceptance cases plus a
 * mutual-recursion case. Standalone:
 *   ocamlc ast.ml sct.ml test_sct.ml -o /tmp/tsct && /tmp/tsct
 *)

open Ast

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let _num = TyPlace "number"   (* kept for reference; underscore silences unused-value *)

(* helper to build a fundef *)
let fn name params body : Sct.fundef = { Sct.name; params; body }

(* a HITElim with a nil-like base branch and a cons-like branch that binds
 * head/tail and runs `callee` on the tail (a strict subterm of the
 * scrutinee `scrut_var`). *)
let list_rec scrut_var callee =
  HITElim
    ( [ ("nil", [], Unit);
        ("cons", ["h"; "t"], App (Var callee, Var "t")) ],
      Var scrut_var )

let () =
  Printf.printf "=== Size-Change Termination gate oracle (block 1.6) ===\n\n";

  (* 1. Non-recursive: f(x) = x. No call, no cycle -> certified vacuously.
   *    (This is the shape of the inverse-pair endpoints: g(f a) reduces.) *)
  let f_id = fn "id" ["x"] (Var "x") in
  check "non-recursive  id(x)=x                  -> CERTIFIED"
    (Sct.certifies [f_id] "id");

  (* 2. Structural recursion on a subterm: len recurses on the cons tail,
   *    a strict subterm of the scrutinee -> certified, normalizes. *)
  let f_len = fn "len" ["xs"] (list_rec "xs" "len") in
  check "structural     len(xs)=..len(tail)..    -> CERTIFIED"
    (Sct.certifies [f_len] "len");

  (* 3. Numeric recursion: pow2 recurses on a computed argument (pred n),
   *    NOT a structural subterm. No subterm edge -> NOT certified. This is
   *    the conservative-sound refusal of numeric descent on float `number`. *)
  let f_pow2 =
    fn "pow2" ["n"] (App (Var "pow2", App (Var "pred", Var "n")))
  in
  check "numeric        pow2(n)=..pow2(pred n)..  -> NOT certified"
    (not (Sct.certifies [f_pow2] "pow2"));

  (* 4. Non-terminating: loop recurses on the same argument unchanged.
   *    Self-edge is non-strict -> NOT certified, never unfolded, no loop. *)
  let f_loop = fn "loop" ["x"] (App (Var "loop", Var "x")) in
  check "non-terminating loop(x)=loop(x)          -> NOT certified"
    (not (Sct.certifies [f_loop] "loop"));

  (* 5. Mutual structural recursion: ping/pong each recurse on the other's
   *    tail. The closure builds the idempotent ping->ping (and pong->pong)
   *    with a strict self-loop -> both certified. *)
  let f_ping = fn "ping" ["xs"] (list_rec "xs" "pong") in
  let f_pong = fn "pong" ["ys"] (list_rec "ys" "ping") in
  let grp = [f_ping; f_pong] in
  check "mutual struct  ping/pong on tails        -> BOTH certified"
    (Sct.certifies grp "ping" && Sct.certifies grp "pong");

  (* A projection is no smaller than the pair it reads, for the normalization
     of open terms: f(p) = g(f(snd p)) with g opaque unfolds without end on a
     neutral p, so it is NOT certified; the same recursion on the tail of a
     list a match binds is (case 2). *)
  let f_snd = fn "fsnd" ["p"] (App (Var "g", App (Var "fsnd", Snd (Var "p")))) in
  check "projection     f(p)=g(f(snd p))          -> NOT certified"
    (not (Sct.certifies [f_snd] "fsnd"));
  let f_fst = fn "ffst" ["p"] (App (Var "ffst", Fst (Fst (Var "p")))) in
  check "projection     f(p)=f(fst (fst p))       -> NOT certified"
    (not (Sct.certifies [f_fst] "ffst"));

  (* 6. A call through a function value (Lee, Jones, Ben-Amram, Def. 4):
   *    apply(k, y) = k(y) and f(x) = apply(f, x). f is named as a value, so
   *    the call k(y) can be f: an empty graph from apply to f closes the
   *    cycle f -> apply -> f with no descent -> neither is certified (before,
   *    apply had no graph and both were certified, and f does not terminate). *)
  let f_apply = fn "apply" ["k"; "y"] (App (Var "k", Var "y")) in
  let f_f = fn "f" ["x"] (App (App (Var "apply", Var "f"), Var "x")) in
  let grp = [f_apply; f_f] in
  check "value call     f(x)=apply(f, x)          -> NEITHER certified"
    (not (Sct.certifies grp "f") && not (Sct.certifies grp "apply"));

  (* 7. The same apply with a fun that is never named as a value: nothing
   *    escapes, the call k(y) reaches no fun of the group, len stays
   *    certified and so does apply. *)
  let grp = [f_apply; f_len] in
  check "value call     with no fun as a value    -> apply and len certified"
    (Sct.certifies grp "apply" && Sct.certifies grp "len");

  (* 8. A structural recursion that passes itself as a value only to a
   *    non-recursive fun: map(xs) = cons(apply(map, ..)...). It now has a
   *    cycle map -> apply -> map with no descent -> not certified: the
   *    certificate cannot see that apply calls its argument on a subterm. *)
  let f_map = fn "map" ["xs"]
      (HITElim ([ ("nil", [], Unit);
                  ("cons", ["h"; "t"], App (App (Var "apply", Var "map"), Var "t")) ],
                Var "xs")) in
  let grp = [f_apply; f_map] in
  check "value call     map through apply          -> NOT certified"
    (not (Sct.certifies grp "map"));

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
