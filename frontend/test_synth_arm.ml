(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_synth_arm.ml — oracle for the prima pietra of the sezione cantiere:
   a coproduct arm with a positional payload IS a place (extensivity: every
   arm is a subobject). The synthesis names its projections (`_1`, `_2`, ...,
   fixed convention); it is PURE (no env: it also serves the pre-env world
   inference) and preserves the nominal self-reference (never expands). *)

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

let fields pd =
  List.filter_map (function FoField f -> Some (f.fd_name, f.fd_ty) | _ -> None)
    pd.pd_members

let () =
  Printf.printf "=== synth_place_of_arm oracle (prima pietra) ===\n\n";

  let tree = mk_place "Tree" ~arms:[] in

  (* Leaf(number): one projection, type number *)
  let leaf = Tycheck.synth_place_of_arm tree
               { v_name = "Leaf"; v_args = [ TyPrim "number" ] } in
  check "Leaf(number) -> one projection _1 : number"
    (fields leaf = [ ("_1", TyPrim "number") ] && leaf.pd_name = "Leaf");

  (* Node(Tree, Tree): two projections, self-reference PRESERVED nominally *)
  let node = Tycheck.synth_place_of_arm tree
               { v_name = "Node"; v_args = [ TyUser "Tree"; TyUser "Tree" ] } in
  check "Node(Tree, Tree) -> _1/_2 both TyUser Tree (never expanded)"
    (fields node = [ ("_1", TyUser "Tree"); ("_2", TyUser "Tree") ]);

  (* determinism: same variant -> identical places *)
  let node2 = Tycheck.synth_place_of_arm tree
                { v_name = "Node"; v_args = [ TyUser "Tree"; TyUser "Tree" ] } in
  check "determinism: two syntheses of the same variant are identical"
    (node = node2);

  (* the synthetic inherits the union's world *)
  let sited = mk_place "U" ~world:"W" in
  let arm = Tycheck.synth_place_of_arm sited
              { v_name = "A"; v_args = [ TyPrim "number" ] } in
  check "the synthetic inherits the union's world"
    (arm.pd_world = "W");

  (* ---- resolution: payload arms now resolve (with the union in hand) ---- *)
  let lookup_none = fun _ -> None in
  check "arity 0 does NOT pass through synthesis (bare constructor path)"
    (Tycheck.arm_resolves_with lookup_none ~union:tree
       { v_name = "Red"; v_args = [] } = None);

  check "payload arm resolves to the synthetic place"
    (match Tycheck.arm_resolves_with lookup_none ~union:tree
             { v_name = "Node"; v_args = [ TyUser "Tree"; TyUser "Tree" ] } with
     | Some pd -> pd.pd_name = "Node"
     | None -> false);

  check "no union in hand -> a payload arm cannot synthesize"
    (Tycheck.arm_resolves_with lookup_none
       { v_name = "Node"; v_args = [ TyUser "Tree" ] } = None);

  check "head colliding with a user place -> None (never a silent pick)"
    (let lookup n = if n = "Node" then Some (mk_place "Node") else None in
     Tycheck.arm_resolves_with lookup ~union:tree
       { v_name = "Node"; v_args = [ TyUser "Tree" ] } = None);

  (* ---- the injection rides subcontains, ALSO for payload arms ---- *)
  let register prog =
    let env = List.fold_left Tycheck.register_decl Tyenv.empty prog in
    Tycheck.resolve_arm_injections env prog
  in
  let env =
    register
      [ TopPlace (mk_place "List"
          ~arms:[ { v_name = "Nil"; v_args = [] };
                  { v_name = "Cons";
                    v_args = [ TyPrim "number"; TyUser "List" ] } ]) ]
  in
  check "Cons(number, List) is injected: place_subcontains Cons List"
    (Tyenv.place_subcontains env "Cons" "List");
  check "the synthetic is marked (new on it is rejected until the mediatrice)"
    (Tyenv.is_synthetic_place env "Cons");
  check "Nil (bare, no user place) is NOT injected (unchanged path)"
    (not (Tyenv.place_subcontains env "Nil" "List"));

  (* ---- rule (f) outcome UNCHANGED: arm_site_of does not consume payloads ---- *)
  let constant_union =
    mk_place "List"
      ~arms:[ { v_name = "Nil"; v_args = [] };
              { v_name = "Cons"; v_args = [ TyPrim "number"; TyUser "List" ] } ] in
  check "arm_site_of on a payload union stays Constant (extension is a later step)"
    (Tycheck.arm_site_of lookup_none constant_union = Tycheck.Constant);

  (* ---- cross-union duplicate: the second same-named payload arm does NOT
     silently mis-resolve — arm_resolves_with sees the first synthetic as a
     collision and yields None (the loud reject lives in check_decl). ---- *)
  let env2 =
    register
      [ TopPlace (mk_place "A"
          ~arms:[ { v_name = "Ok"; v_args = [ TyPrim "number" ] } ]) ]
  in
  check "second union's same-named payload arm does not resolve (collision)"
    (Tycheck.arm_resolves_with
       (fun n -> Tyenv.lookup_place env2 n)
       ~union:(mk_place "B")
       { v_name = "Ok"; v_args = [ TyPrim "number" ] } = None);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  exit (if !fail = 0 then 0 else 1)
