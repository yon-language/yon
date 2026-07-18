(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* leech_theta.ml — the arithmetic oracle of the Leech lattice.
 *
 * Theta_Leech = E_12 - (65520/691) * Delta, a modular form of weight 12.
 * Coefficient of q^n (n >= 1):
 *     N(n) = (65520/691) * (sigma_11(n) - tau(n))
 * where N(n) is the number of lattice vectors of norm 2n, and N(0) = 1.
 *
 * This lives in the COMPILER on purpose. The counts are theorems, computed
 * once at compile time, never recomputed at runtime. theta_coeff 2 = 196560
 * is the kissing number and the exact capacity of the type-2 arena; it is
 * meant to become a static invariant that the runtime is checked against
 * (a _Static_assert bridge), so a drift in the MPHF fails the build, not a
 * run.
 *
 * Integers are OCaml native (63-bit). The load-bearing value
 * theta_coeff 2 = 196560 and every coefficient up to the small n we verify
 * fit comfortably; large n would need arbitrary precision (not required). *)

(* d^11, by repeated multiplication (exponent is fixed and tiny). *)
let pow11 (m : int) : int =
  let r = ref 1 in
  for _ = 1 to 11 do r := !r * m done;
  !r

(* sigma_11(n) = sum of d^11 over the divisors d of n. O(sqrt n). *)
let sigma11 (n : int) : int =
  let acc = ref 0 in
  let d = ref 1 in
  while !d * !d <= n do
    if n mod !d = 0 then begin
      acc := !acc + pow11 !d;
      let co = n / !d in
      if co <> !d then acc := !acc + pow11 co
    end;
    incr d
  done;
  !acc

(* tau(n): Ramanujan's tau, the q^n coefficient of
 *     Delta = q * prod_{k>=1} (1 - q^k)^24.
 * We expand prod_{k>=1} (1 - q^k)^24 as a power series; tau(n) is then the
 * coefficient of q^(n-1) in that product. Returns coeff.(m) for m = 0..deg. *)
let tau_series (deg : int) : int array =
  let coeff = Array.make (deg + 1) 0 in
  coeff.(0) <- 1;
  (* signed binomials: binom24.(j) = (-1)^j * C(24, j), j = 0..24 *)
  let binom24 = Array.make 25 0 in
  let c = ref 1 in
  for j = 0 to 24 do
    binom24.(j) <- (if j land 1 = 0 then !c else - !c);
    c := !c * (24 - j) / (j + 1)
  done;
  (* multiply in (1 - q^k)^24 = sum_j binom24.(j) * q^(k*j), for each k *)
  for k = 1 to deg do
    let next = Array.make (deg + 1) 0 in
    for a = 0 to deg do
      if coeff.(a) <> 0 then begin
        let j = ref 0 in
        while k * !j <= deg - a && !j <= 24 do
          let idx = a + k * !j in
          next.(idx) <- next.(idx) + coeff.(a) * binom24.(!j);
          incr j
        done
      end
    done;
    Array.blit next 0 coeff 0 (deg + 1)
  done;
  coeff

(* theta_coeff n = N(n) = number of Leech vectors of norm 2n.
 * N(0) = 1; for n >= 1, (65520/691)(sigma11 n - tau n). The result is an
 * integer by Ramanujan's congruence tau(n) = sigma11(n) (mod 691); we assert
 * that divisibility loudly rather than trusting it silently. *)
let theta_coeff (n : int) : int =
  if n < 0 then
    failwith (Printf.sprintf "[leech_theta] theta_coeff: negative index %d" n)
  else if n = 0 then 1
  else begin
    let series = tau_series (n - 1) in
    let tau_n = series.(n - 1) in
    let diff = sigma11 n - tau_n in
    if diff mod 691 <> 0 then
      failwith (Printf.sprintf
        "[leech_theta] Ramanujan congruence broken at n=%d: 691 does not \
         divide sigma11 - tau (got %d)" n diff);
    65520 * diff / 691
  end

(* The kissing number: vectors of norm 4. The exact capacity of the type-2
 * arena, exposed as a compile-time constant the runtime can be sized and
 * checked against. *)
let type2_count : int = theta_coeff 2
