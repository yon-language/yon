(* test_cubical_surface.ml — oracle for the surface cubical apparatus.
 *
 * Stage 1: path application (p @ i).
 *   - p @ i, with p : Id(A, x, y), is a point of the carrier A.
 *   - applying @ to a non-path is rejected.
 * The exact endpoint (refl-beta: refl(t)@i = t) is decided by reduction in
 * the core; this oracle pins the surface *typing* rule.
 *)

open Surface_ast

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let () =
  Printf.printf "=== Surface cubical apparatus oracle (stage 1: path application) ===\n\n";
  let dl = dummy_loc in
  let ctx = Reduce.empty_ctx in
  let num = TyPrim "number" in

  (* p : Id(number, a, b) ; p @ I0 must be number (carrier) *)
  let path_ty =
    TyId (num, TyTermExpr (EVar ("a", dl)), TyTermExpr (EVar ("b", dl))) in
  let env = Tyenv.add_vars Tyenv.empty [("p", path_ty); ("n", num)] in

  (match Tycheck.infer env ctx (EPathApp (EVar ("p", dl), DI0, dl)) with
   | Ok (TyPrim "number") -> check "p @ I0 : carrier (number)" true
   | Ok other -> check (Printf.sprintf "p @ I0: unexpected %s" (Tyenv.ty_to_string other)) false
   | Error e -> check (Printf.sprintf "p @ I0: infer failed: %s" (Tycheck.error_to_string e)) false);

  (match Tycheck.infer env ctx (EPathApp (EVar ("p", dl), DI1, dl)) with
   | Ok (TyPrim "number") -> check "p @ I1 : carrier (number)" true
   | _ -> check "p @ I1 : carrier (number)" false);

  (match Tycheck.infer env ctx (EPathApp (EVar ("p", dl), DIVar "i", dl)) with
   | Ok (TyPrim "number") -> check "p @ i : carrier (number)" true
   | _ -> check "p @ i : carrier (number)" false);

  (* path abstraction: plam i => e : a path; non-dependent typing yields TyId *)
  (match Tycheck.infer env ctx (EPathAbs ("i", EVar ("n", dl), dl)) with
   | Ok (TyId (TyPrim "number", _, _)) -> check "plam i => n : Id(number, _, _)" true
   | Ok other -> check (Printf.sprintf "plam: unexpected %s" (Tyenv.ty_to_string other)) false
   | Error e -> check (Printf.sprintf "plam: infer failed: %s" (Tycheck.error_to_string e)) false);

  (* applying @ to a non-path is rejected *)
  (match Tycheck.infer env ctx (EPathApp (EVar ("n", dl), DI0, dl)) with
   | Error _ -> check "n @ I0 rejected (n is not a path)" true
   | Ok _ -> check "n @ I0 wrongly accepted" false);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
