(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_el.ml — oracle for derived-El decode (CaTT codes -> carrier types).
 *
 * Asserts the chosen model: El is DERIVED (no new primitive). A 0-cell site
 * code decodes to its nominal carrier; a directed 1-cell (a geom morphism)
 * decodes to the arrow between the carriers of its endpoints; the witness does
 * not affect the carrier; an unrecognized coherence stays undecoded (None) —
 * El never invents a carrier. Equality of El codes rests on the existing
 * decidable (R_Yon) equality, exercised separately by the dispatcher/cubical.
 *
 * Built as a dune executable (added to the names list).
 *)

open Surface_ast
open Catt_r_yon

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let () =
  Printf.printf "=== derived-El decode oracle (CaTT code -> carrier) ===\n\n";

  let site_c = TmVar "C" in
  let site_d = TmVar "D" in
  let w = TmVar "__w" in

  (* (1) a 0-cell site code decodes to its nominal carrier *)
  check "El(site C) = TyPrim C"
    (el_decode site_c = Some (TyPrim "C"));

  (* (2) a directed 1-cell (geom morphism C ->* D) decodes to the arrow C -> D *)
  let cell_cd = dir_incl_intro site_c site_d w in
  check "El(C ->* D) = TyArrow(TyPrim C, TyPrim D)"
    (el_decode cell_cd = Some (TyArrow (TyPrim "C", TyPrim "D")));

  (* (3) the witness does not affect the carrier: El depends only on endpoints *)
  let cell_cd' = dir_incl_intro site_c site_d (TmId (TmVar "x", CellStar)) in
  check "El ignores the witness (same carrier for different witnesses)"
    (el_decode cell_cd = el_decode cell_cd');

  (* (4) an unrecognized coherence stays undecoded: no invented carrier *)
  let bogus = TmCoh ([("a", CellStar)], CellStar, [("a", TmVar "z")]) in
  check "El(unknown coherence) = None"
    (el_decode bogus = None);

  (* (5) the decode is pointwise on the recognized 1-cell *)
  check "El well-defined on endpoints"
    (match el_decode cell_cd with
     | Some (TyArrow (TyPrim a, TyPrim b)) -> a = "C" && b = "D"
     | _ -> false);

  (* (6) end-to-end: a geom morphism's CaTT code decodes to El(src) -> El(tgt),
     which is exactly the coherence the checker now enforces on TopGeomMorphism *)
  let gm = {
    gm_name = "f"; gm_source_site = "EU"; gm_target_site = "US";
    gm_pull = None; gm_push = None;
    gm_adjunction = false; gm_f_star_exact = false; gm_f_lower_star_exact = false;
    gm_loc = dummy_loc;
  } in
  check "El(code of geom EU->US) = TyArrow(TyPrim EU, TyPrim US)"
    (el_decode (cell_of_geom_morphism gm) = Some (TyArrow (TyPrim "EU", TyPrim "US")));

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
