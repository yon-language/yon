(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_heyting.ml — certifies that the three-value prop fragment is a genuine
 * Heyting algebra (the Gödel G3 chain), not Kleene/Łukasiewicz.
 *
 * The decisive axiom is the adjunction (residuation) that DEFINES Heyting
 * implication: for all a, b, c
 *     a /\ c <= b   iff   c <= (a -> b)
 * We check it exhaustively over all 27 triples. We also check neg a = a -> bot,
 * the failure of double-negation elimination, and the failure of the excluded
 * middle — the two ways Heyting departs from classical/De Morgan logic. *)

open Heyting

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let all = [HAbsent; HUnknown; HPresent]

(* order from the lattice join: x <= y  iff  x \/ y = y *)
let leq x y = (h_or x y = y)

let () =
  Printf.printf "=== Heyting algebra oracle (Gödel G3 chain) ===\n\n";

  (* 1. Adjunction / residuation over all 27 triples: this is THE Heyting law *)
  let adj_ok = ref true in
  List.iter (fun a -> List.iter (fun b -> List.iter (fun c ->
    let lhs = leq (h_and a c) b in
    let rhs = leq c (h_imp a b) in
    if lhs <> rhs then adj_ok := false
  ) all) all) all;
  check "adjunction  a /\\ c <= b  <=>  c <= (a -> b)  over all 27 triples" !adj_ok;

  (* 2. Reflexivity a -> a = present (top) for every a — fails under Kleene at unknown *)
  check "a -> a = present for all a (a->a = top)"
    (List.for_all (fun a -> h_imp a a = HPresent) all);

  (* 3. neg a = a -> bot (negation is the pseudo-complement into absent) *)
  check "neg a = a -> absent for all a"
    (List.for_all (fun a -> h_not a = h_imp a HAbsent) all);

  (* 4. The Heyting-specific value: neg unknown = absent (not unknown) *)
  check "neg unknown = absent (regular, not involutive)" (h_not HUnknown = HAbsent);

  (* 5. Double negation does NOT eliminate: neg neg unknown = present > unknown *)
  check "neg neg unknown = present (DNE fails)" (h_not (h_not HUnknown) = HPresent);
  check "neg neg a >= a for all a (regularity)"
    (List.for_all (fun a -> leq a (h_not (h_not a))) all);

  (* 6. Excluded middle fails at unknown: unknown \/ neg unknown = unknown <> present *)
  check "excluded middle fails: unknown \\/ neg unknown <> present"
    (h_or HUnknown (h_not HUnknown) <> HPresent);

  (* 7. NOT Kleene: an involutive negation would give neg unknown = unknown *)
  check "not Kleene: neg unknown <> unknown" (h_not HUnknown <> HUnknown);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
