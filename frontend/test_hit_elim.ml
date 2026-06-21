(* test_hit_elim.ml — Tarski HIT eliminator typing, with DEPENDENT path branches.
 *
 * hit_elim(C, [base => v_base, loop => plam i => body], x):
 *   point base : El(C base)
 *   path  loop : plam i => body  with  body : El(C(loop @ i))   (path-over)
 *   result     : El(C x)
 * The line El(C(loop@i)) varies along the interval (uses path application);
 * at the endpoints loop@0 / loop@1 the boundary matches by computation.
 *)

open Surface_ast

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let () =
  Printf.printf "=== Tarski HIT eliminator oracle (dependent path branches) ===\n\n";
  let dl = dummy_loc in
  let ctx = Reduce.empty_ctx in
  let s1 = TyPrim "S1" in
  let motive_ty = TyArrow (s1, TyUniverse 0) in
  let elC_base =
    TyEl (TyTermExpr (EApp (EVar ("C", dl), [EVar ("base", dl)], dl))) in
  (* the loop body must live in El(C(loop @ i)) under the binder i *)
  let elC_loop_i =
    TyEl (TyTermExpr
            (EApp (EVar ("C", dl),
                   [EPathApp (EVar ("loop", dl), DIVar "i", dl)], dl))) in
  let env =
    Tyenv.add_vars Tyenv.empty
      [("C", motive_ty); ("x", s1); ("vb", elC_base); ("vbody", elC_loop_i)] in

  (* dependent loop branch: loop => plam i => vbody *)
  let elim =
    EHITElim (EVar ("C", dl),
              [("base", [], EVar ("vb", dl));
               ("loop", [], EPathAbs ("i", EVar ("vbody", dl), dl))],
              EVar ("x", dl), dl) in
  (match Tycheck.infer env ctx elim with
   | Ok (TyEl (TyTermExpr (EApp (EVar ("C", _), [EVar ("x", _)], _)))) ->
       check "hit_elim S1: dependent loop branch body : El(C(loop@i)), result El(C x)" true
   | Ok other -> check (Printf.sprintf "unexpected result %s" (Tyenv.ty_to_string other)) false
   | Error e -> check (Printf.sprintf "infer failed: %s" (Tycheck.error_to_string e)) false);

  (* non-universe motive: accepted as a non-dependent recursor, result is the
   * codomain. C : S1 -> S1, branches : S1, result : S1. *)
  let env2 = Tyenv.add_vars Tyenv.empty
      [("C", TyArrow (s1, s1)); ("x", s1); ("vb", s1); ("vbody", s1)] in
  (match Tycheck.infer env2 ctx elim with
   | Ok (TyPrim "S1") -> check "non-universe motive: recursor, result = codomain S1" true
   | Ok other -> check (Printf.sprintf "recursor: unexpected %s" (Tyenv.ty_to_string other)) false
   | Error e -> check (Printf.sprintf "recursor: infer failed: %s" (Tycheck.error_to_string e)) false);

  (* loop branch that is NOT a path abstraction is rejected *)
  let elim_bad =
    EHITElim (EVar ("C", dl),
              [("base", [], EVar ("vb", dl));
               ("loop", [], EVar ("vb", dl))],
              EVar ("x", dl), dl) in
  (match Tycheck.infer env ctx elim_bad with
   | Error _ -> check "non-abstraction loop branch rejected" true
   | Ok _ -> check "wrongly accepted non-abstraction loop branch" false);

  (* non-HIT target rejected *)
  let env3 = Tyenv.add_vars Tyenv.empty
      [("C", TyArrow (TyPrim "Widget", TyUniverse 0));
       ("x", TyPrim "Widget"); ("vb", TyPrim "number")] in
  let elim3 =
    EHITElim
      (EVar ("C", dl), [("base", [], EVar ("vb", dl))], EVar ("x", dl), dl)
  in
  (match Tycheck.infer env3 ctx elim3 with
   | Error _ -> check "non-HIT target rejected" true
   | Ok _ -> check "wrongly accepted non-HIT target" false);

  let sum_ab =
    TySum
      [{ v_name = "A"; v_args = [] };
       { v_name = "B"; v_args = [TyPrim "number"] }]
  in
  let sum_ac =
    TySum
      [{ v_name = "A"; v_args = [] };
       { v_name = "C"; v_args = [TyPrim "number"] }]
  in
  check "distinct sum signatures have distinct Core carriers"
    (Desugar.desugar_ty sum_ab <> Desugar.desugar_ty sum_ac);
  let sum_env = Tyenv.add_sum_type Tyenv.empty
      (match sum_ab with TySum variants -> variants | _ -> assert false) in
  (match Tycheck.infer sum_env ctx
           (EHITConstr ("B", [ELit (LitNumber 7., dl)], dl)) with
   | Ok inferred -> check "sum constructor synthesizes its declared sum type"
       (Dispatcher.type_equal sum_env ctx inferred sum_ab)
   | Error e -> check (Printf.sprintf "sum constructor failed: %s"
       (Tycheck.error_to_string e)) false);
  let sum_ab_text =
    TySum
      [{ v_name = "A"; v_args = [] };
       { v_name = "B"; v_args = [TyPrim "text"] }]
  in
  let ambiguous_env =
    match sum_ab, sum_ab_text with
    | TySum first, TySum second ->
        Tyenv.add_sum_type (Tyenv.add_sum_type Tyenv.empty first) second
    | _ -> assert false
  in
  (match Tycheck.check ambiguous_env ctx
           (EHITConstr ("B", [ELit (LitNumber 7., dl)], dl)) sum_ab with
   | Ok () -> check "expected sum disambiguates a shared constructor name" true
   | Error e -> check (Printf.sprintf "sum disambiguation failed: %s"
       (Tycheck.error_to_string e)) false);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
