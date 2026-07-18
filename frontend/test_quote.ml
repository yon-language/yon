(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_quote.ml — oracle for the B eliminator of El (quote intro + match elim).
 *
 * Architecture chosen (aligned with CaTT / HoTT / Yoneda): the eliminator binds
 * the CARRIER, never the raw code. Modeled here as el_elim, which applies the
 * branch to carrier(c) = el_decode c. The coherence property — the very thing
 * that makes subject reduction hold — is the negative test Antonio asked for:
 * two codes with the same carrier but different syntax (here, differing only in
 * the witness, which el_decode ignores) yield the SAME result for ANY branch.
 * No branch can observe the raw code, so none can separate two codes that the
 * per-carrier conversion (el_equal) declares equal.
 *
 * This fixes the engine. The surface syntax (TyEl / quote / match) is the next
 * step and carries its own representation choices.
 *)

open Surface_ast
open Catt_r_yon

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

(* The B eliminator, as a model: the branch is a function of the CARRIER only. *)
let el_elim (branch : Surface_ast.ty -> 'a) (c : term) : 'a option =
  match el_decode c with
  | Some carrier -> Some (branch carrier)
  | None -> None

let () =
  Printf.printf "=== El eliminator (B: binds carrier, not code) coherence oracle ===\n\n";

  let a = TmVar "A" in
  let b = TmVar "B" in

  (* two codes: same endpoints, DIFFERENT witness -> same carrier, different code *)
  let c1 = dir_incl_intro a b (TmVar "w1") in
  let c2 = dir_incl_intro a b (TmId (TmVar "w2", CellStar)) in
  (* a third code with a DIFFERENT carrier *)
  let c3 = dir_incl_intro a (TmVar "C") (TmVar "w3") in

  (* (1) positive: the eliminator applies the branch to the carrier *)
  check "el_elim id (quote c1) = Some carrier(c1) = TyArrow(A,B)"
    (el_elim (fun t -> t) c1 = Some (TyArrow (TyPrim "A", TyPrim "B")));

  (* (2) COHERENCE (the negative test): c1 and c2 are carrier-equal but
     code-different. The identity branch is the most indiscreet branch possible —
     it returns whatever it is given. If even the identity cannot tell c1 from c2,
     no branch can: subject reduction is safe. *)
  check "coherence: el_elim id c1 = el_elim id c2 (carrier-equal, code-different)"
    (el_elim (fun t -> t) c1 = el_elim (fun t -> t) c2);

  (* (3) coherence holds for an arbitrary observing branch as well *)
  let observe t = Some t in
  check "coherence under an arbitrary branch"
    (el_elim observe c1 = el_elim observe c2);

  (* (4) sanity: the eliminator is NOT constant — different carriers differ *)
  check "el_elim id c1 <> el_elim id c3 (different carrier)"
    (el_elim (fun t -> t) c1 <> el_elim (fun t -> t) c3);

  (* (5) an undecoded code yields None: the match has no canonical redex to fire
     on, so it is stuck (no invented carrier) — same discipline as J on non-refl *)
  let bogus = TmCoh ([("a", CellStar)], CellStar, [("a", TmVar "z")]) in
  check "el_elim on an undecoded code = None (stuck, no invented carrier)"
    (el_elim (fun t -> t) bogus = None);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
