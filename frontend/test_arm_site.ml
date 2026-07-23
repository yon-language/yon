(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_arm_site.ml — oracle for the world-guard rule (f).

   The site of a place with arms is DERIVED from its arms: the common world
   of the arms that resolve to placed objects. No arm resolves -> Constant
   (a constant presheaf, Bool = 1+1). One shared world -> Sited. Two worlds
   -> Incoherent (a coproduct across topoi needs a geometric morphism). *)

open Surface_ast

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let mk_place ?(world = "__INFER") ?(arms = []) name : place_decl =
  { pd_name = name; pd_type_params = []; pd_arms = arms; pd_world = world;
    pd_members = []; pd_over = None; pd_laws = [];
    pd_subcontains = None; pd_is_error = false; pd_on_error = None;
    pd_loc = dummy_loc }

let arm n = { v_name = n; v_args = [] }

let () =
  Printf.printf "=== arm_site_of oracle (world-guard rule (f)) ===\n\n";

  let placed = [ mk_place ~world:"W" "P"; mk_place ~world:"W" "Q";
                 mk_place ~world:"V" "R" ] in
  let lookup n = List.find_opt (fun pd -> pd.pd_name = n) placed in

  check "union of two bare constructors -> Constant"
    (Tycheck.arm_site_of lookup (mk_place "U" ~arms:[ arm "tt"; arm "ff" ])
     = Tycheck.Constant);

  check "union of two places in the same world -> Sited W"
    (Tycheck.arm_site_of lookup (mk_place "U" ~arms:[ arm "P"; arm "Q" ])
     = Tycheck.Sited "W");

  check "union of places in different worlds -> Incoherent"
    (match Tycheck.arm_site_of lookup
             (mk_place "U" ~arms:[ arm "P"; arm "R" ]) with
     | Tycheck.Incoherent ("W", "V") -> true
     | _ -> false);

  check "constant + placed arm -> Sited W (the constant does not contribute)"
    (Tycheck.arm_site_of lookup (mk_place "U" ~arms:[ arm "tt"; arm "P" ])
     = Tycheck.Sited "W");

  check "an arm whose world is still __INFER does not contribute"
    (let lookup2 n =
       if n = "S" then Some (mk_place "S") else lookup n in
     Tycheck.arm_site_of lookup2 (mk_place "U" ~arms:[ arm "S" ])
     = Tycheck.Constant);

  check "payload arm never contributes (positional payloads carry no world yet)"
    (Tycheck.arm_site_of lookup
       (mk_place "U" ~arms:[ { v_name = "P"; v_args = [ TyPrim "number" ] } ])
     = Tycheck.Constant);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  exit (if !fail = 0 then 0 else 1)
