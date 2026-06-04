(* test_ty_subst.ml — Unit test per Ty_subst (Algorithm W foundations) *)

open Surface_ast
open Ty_subst

let num = TyPrim "number"
let txt = TyPrim "text"

let pass_count = ref 0
let fail_count = ref 0

let test name cond =
  if cond then begin
    incr pass_count;
    Printf.printf "  ✓ %s\n" name
  end else begin
    incr fail_count;
    Printf.printf "  ✗ %s FAILED\n" name
  end

let () =
  Printf.printf "=== Ty_subst unit tests ===\n\n";

  (* Test 1: fresh_metavar produce id distinti *)
  Printf.printf "Test 1: fresh meta-var generation\n";
  reset_metavars ();
  let a = fresh_metavar () in
  let b = fresh_metavar () in
  test "fresh produces TyMetaVar" (match a with TyMetaVar _ -> true | _ -> false);
  test "fresh ids are distinct" (a <> b);

  (* Test 2: apply_subst *)
  Printf.printf "\nTest 2: apply_subst\n";
  reset_metavars ();
  let v0 = fresh_metavar () in
  let _v1 = fresh_metavar () in
  let sigma = [(0, num)] in
  test "apply on TyMetaVar 0 -> number" (apply_subst sigma v0 = num);
  test "apply on TyMetaVar 1 -> unchanged"
    (apply_subst sigma (TyMetaVar 1) = TyMetaVar 1);
  test "apply on TyList(TyMetaVar 0) -> TyList number"
    (apply_subst sigma (TyList v0) = TyList num);

  (* Test 3: occur_check *)
  Printf.printf "\nTest 3: occur_check\n";
  test "occur 0 in alpha0 -> true" (occur_check 0 (TyMetaVar 0));
  test "occur 0 in alpha1 -> false" (not (occur_check 0 (TyMetaVar 1)));
  test "occur 0 in list of alpha0 -> true" (occur_check 0 (TyList (TyMetaVar 0)));
  test "occur 0 in number -> false" (not (occur_check 0 num));

  (* Test 4: unify base *)
  Printf.printf "\nTest 4: unify base cases\n";
  reset_metavars ();
  let _ = fresh_metavar () in  (* alpha0 *)
  test "unify number number -> empty subst"
    (try_unify num num = Ok []);
  test "unify number text -> error"
    (match try_unify num txt with Error (UMismatch _) -> true | _ -> false);
  test "unify alpha0 number -> [0 ↦ number]"
    (match try_unify (TyMetaVar 0) num with
     | Ok [(0, TyPrim "number")] -> true | _ -> false);
  test "unify number alpha0 -> [0 ↦ number] (symmetric)"
    (match try_unify num (TyMetaVar 0) with
     | Ok [(0, TyPrim "number")] -> true | _ -> false);

  (* Test 5: unify constructors *)
  Printf.printf "\nTest 5: unify with constructors\n";
  test "unify list of number, list of number -> empty"
    (try_unify (TyList num) (TyList num) = Ok []);
  test "unify list of alpha0, list of number -> [0 ↦ number]"
    (match try_unify (TyList (TyMetaVar 0)) (TyList num) with
     | Ok [(0, TyPrim "number")] -> true | _ -> false);
  test "unify list of number, list of text -> error"
    (match try_unify (TyList num) (TyList txt) with
     | Error (UMismatch _) -> true | _ -> false);
  test "unify map of alpha0 to alpha1, map of number to text -> both bound"
    (match try_unify (TyMap (TyMetaVar 0, TyMetaVar 1))
                     (TyMap (num, txt)) with
     | Ok sigma ->
         apply_subst sigma (TyMetaVar 0) = num &&
         apply_subst sigma (TyMetaVar 1) = txt
     | _ -> false);

  (* Test 6: occur check during unify *)
  Printf.printf "\nTest 6: occur check during unify\n";
  test "unify alpha0 with list of alpha0 -> occur check error"
    (match try_unify (TyMetaVar 0) (TyList (TyMetaVar 0)) with
     | Error (UOccurCheck (0, _)) -> true | _ -> false);

  (* Test 7: compose_subst *)
  Printf.printf "\nTest 7: compose_subst\n";
  let s1 = [(0, num)] in
  let s2 = [(1, TyMetaVar 0)] in
  let composed = compose_subst s1 s2 in
  (* After composition: a1 must resolve to number (via a0 -> number) *)
  test "compose: alpha1 -> number via alpha0"
    (apply_subst composed (TyMetaVar 1) = num);
  test "compose: alpha0 -> number (preserved)"
    (apply_subst composed (TyMetaVar 0) = num);

  (* Test 8: generalize/instantiate *)
  Printf.printf "\nTest 8: generalize/instantiate\n";
  reset_metavars ();
  let _ = fresh_metavar () in  (* alpha0 *)
  let _ = fresh_metavar () in  (* alpha1 *)
  let t = TyPi ("x", TyMetaVar 0, TyMetaVar 0) in  (* alpha0 -> alpha0 (id) *)
  let s = generalize [] t in
  test "generalize binds free metavars" (List.length s.bound = 1);
  test "generalize body unchanged" (s.body = t);
  let inst1 = instantiate s in
  let inst2 = instantiate s in
  test "instantiate produces fresh metavars" (inst1 <> inst2);
  test "instantiate preserves Pi structure"
    (match inst1 with TyPi (_, _, _) -> true | _ -> false);

  Printf.printf "\n--- %d/%d tests passed ---\n"
    !pass_count (!pass_count + !fail_count);
  if !fail_count > 0 then exit 1
