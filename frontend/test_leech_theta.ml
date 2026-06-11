(* test_leech_theta.ml — oracle for the Leech arithmetic (Ramanujan theta).
 *
 * Verifies that sigma_11 and tau reproduce the exact lattice vector counts:
 * the kissing number 196560 and the next shells, each a theorem. If this is
 * green, the compiler's notion of the Leech is arithmetically correct, and
 * theta_coeff 2 is a trustworthy invariant to size the arena by.
 *
 * Standalone:
 *   ocamlc leech_theta.ml test_leech_theta.ml -o /tmp/ttheta && /tmp/ttheta
 *)

open Leech_theta

let pass = ref 0
let fail = ref 0
let check name got want =
  if got = want then (incr pass; Printf.printf "  [PASS] %-28s = %d\n" name got)
  else (incr fail; Printf.printf "  [FAIL] %-28s: got %d, want %d\n" name got want)

let () =
  Printf.printf "=== Leech theta oracle (Ramanujan, weight 12) ===\n\n";

  (* N(n) = number of vectors of norm 2n — exact theorems *)
  check "N(0) [zero vector]"     (theta_coeff 0) 1;
  check "N(1) [norm 2: none]"    (theta_coeff 1) 0;
  check "N(2) [norm 4: kissing]" (theta_coeff 2) 196560;
  check "N(3) [norm 6]"          (theta_coeff 3) 16773120;
  check "N(4) [norm 8]"          (theta_coeff 4) 398034000;
  check "N(5) [norm 10]"         (theta_coeff 5) 4629381120;
  check "N(6) [norm 12]"         (theta_coeff 6) 34417656000;

  (* the load-bearing constant the arena is sized by *)
  check "type2_count [capacity]" type2_count 196560;

  (* sigma_11 spot checks (1 + 2^11 = 2049) *)
  check "sigma11(1)"             (sigma11 1) 1;
  check "sigma11(2)"             (sigma11 2) 2049;
  check "sigma11(3)"             (sigma11 3) 177148;

  Printf.printf "\n  %d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
