(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_arm_resolve.ml — oracle for place-refactor stage 1.

   1b: `arm_resolves_to_place` — a coproduct arm whose head names a place
   declared in this same program IS that place; payload or unknown head
   stays a positional constructor.

   1c: registering `place U { this > P :U Q }` records the injection P -> U
   on the SAME machinery `subcontains` rides: Tyenv.place_subcontains (the
   pd_subcontains chain walk) reports it, with no new api. *)

open Surface_ast

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let mk_place ?(subc = None) ?(arms = []) name : place_decl =
  { pd_name = name; pd_type_params = []; pd_arms = arms; pd_world = "__INFER";
    pd_with_effects = false; pd_members = []; pd_over = None; pd_laws = [];
    pd_subcontains = subc; pd_is_error = false; pd_on_error = None;
    pd_loc = dummy_loc }

let () =
  Printf.printf "=== arm_resolves_to_place oracle (place refactor stage 1) ===\n\n";

  (* ---- 1b: the resolver ---- *)
  let env = Tyenv.add_place Tyenv.empty (mk_place "P") in

  check "declared place + empty payload -> Some"
    (match Tycheck.arm_resolves_to_place env { v_name = "P"; v_args = [] } with
     | Some pd -> pd.pd_name = "P"
     | None -> false);

  check "unknown head -> None"
    (Tycheck.arm_resolves_to_place env { v_name = "Ghost"; v_args = [] } = None);

  check "colliding head but non-empty payload -> None"
    (Tycheck.arm_resolves_to_place env
       { v_name = "P"; v_args = [ TyPrim "number" ] } = None);

  check "empty env -> None"
    (Tycheck.arm_resolves_to_place Tyenv.empty
       { v_name = "P"; v_args = [] } = None);

  (* ---- 1c: the injection rides the subcontains chain (second pass) ---- *)
  let register prog =
    let env = List.fold_left Tycheck.register_decl Tyenv.empty prog in
    Tycheck.resolve_arm_injections env prog
  in
  let prog_env =
    register
      [ TopPlace (mk_place "P");
        TopPlace (mk_place "U" ~arms:[ { v_name = "P"; v_args = [] };
                                       { v_name = "Q"; v_args = [] } ]) ]
  in
  check "P is an arm of U: place_subcontains P U (same api as subcontains)"
    (Tyenv.place_subcontains prog_env "P" "U");

  check "Q does not resolve (no place Q): no subsumption Q -> U"
    (not (Tyenv.place_subcontains prog_env "Q" "U"));

  check "no phantom subsumption toward an unrelated name"
    (not (Tyenv.place_subcontains prog_env "P" "V"));

  (* stage 3: declaration order must not matter — union BEFORE its arm place *)
  let reversed =
    register
      [ TopPlace (mk_place "U" ~arms:[ { v_name = "P"; v_args = [] } ]);
        TopPlace (mk_place "P") ]
  in
  check "union declared before its arm place still resolves (second pass)"
    (Tyenv.place_subcontains reversed "P" "U");

  (* a declared chain is NOT overwritten (first wins) *)
  let chained =
    register
      [ TopPlace (mk_place ~subc:(Some "Base") "P");
        TopPlace (mk_place "Base");
        TopPlace (mk_place "U" ~arms:[ { v_name = "P"; v_args = [] } ]) ]
  in
  check "an arm already in a declared subcontains chain keeps its chain"
    (Tyenv.place_subcontains chained "P" "Base"
     && not (Tyenv.place_subcontains chained "P" "U"));

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  exit (if !fail = 0 then 0 else 1)
