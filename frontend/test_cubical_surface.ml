(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
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

  (* A constant path records its real endpoints, not placeholders. *)
  (match Tycheck.infer env ctx (EPathAbs ("i", EVar ("n", dl), dl)) with
   | Ok (TyId (TyPrim "number",
                  TyTermExpr (EVar ("n", _)),
                  TyTermExpr (EVar ("n", _)))) ->
       check "plam i => n : Id(number, n, n)" true
   | Ok other -> check (Printf.sprintf "plam: unexpected %s" (Tyenv.ty_to_string other)) false
   | Error e -> check (Printf.sprintf "plam: infer failed: %s" (Tycheck.error_to_string e)) false);

  let varying =
    EPathAbs ("i", EPathApp (EVar ("p", dl), DIVar "i", dl), dl) in
  (match Tycheck.infer env ctx varying with
   | Ok (TyId (TyPrim "number",
                  TyTermExpr (EPathApp (EVar ("p", _), DI0, _)),
                  TyTermExpr (EPathApp (EVar ("p", _), DI1, _)))) ->
       check "plam i => p @ i records p @ I0 and p @ I1" true
   | _ -> check "plam i => p @ i has incorrect endpoints" false);

  (* applying @ to a non-path is rejected *)
  (match Tycheck.infer env ctx (EPathApp (EVar ("n", dl), DI0, dl)) with
   | Error _ -> check "n @ I0 rejected (n is not a path)" true
   | Ok _ -> check "n @ I0 wrongly accepted" false);

  (* Stage 3a: primitive type names are universe codes, and constant-line
     transport is lowered to a genuine Core Transp node. *)
  (match Tycheck.infer env ctx (ERefl (EVar ("number", dl), dl)) with
   | Ok (TyId (TyUniverse 0,
                  TyTermExpr (EVar ("number", _)),
                  TyTermExpr (EVar ("number", _)))) ->
       check "refl(number) is a path in Type_0" true
   | Ok other ->
       check (Printf.sprintf "refl(number): unexpected %s"
                (Tyenv.ty_to_string other)) false
   | Error e ->
       check (Printf.sprintf "refl(number): infer failed: %s"
                (Tycheck.error_to_string e)) false);

  let transport_refl =
    ECall ("transport", [ERefl (EVar ("number", dl), dl); ELit (LitNumber 5.0, dl)], dl) in
  (match Tycheck.infer env ctx transport_refl with
   | Ok (TyPrim "number") -> check "transport(refl(number), 5) : Number" true
   | _ -> check "transport(refl(number), 5) has wrong type" false);
  (match Desugar.desugar_expr transport_refl with
   | Ast.Transp (("__ti", Ast.TyPlace "number"), _) ->
       check "transport(refl(number), 5) lowers to Ast.Transp" true
   | _ -> check "transport(refl(number), 5) bypassed Ast.Transp" false);

  let transport_ua_id =
    ECall
      ("transport", [ECall ("ua", [ECall ("idEquiv", [EVar ("number", dl)], dl)], dl);
        ELit (LitNumber 5.0, dl)], dl) in
  (match Tycheck.infer env ctx transport_ua_id with
   | Ok (TyPrim "number") ->
       check "transport(ua(idEquiv(number)), 5) : Number" true
   | _ -> check "transport(ua(idEquiv(number)), 5) has wrong type" false);
  let ua_core = Desugar.desugar_expr transport_ua_id in
  (match ua_core with
   | Ast.Transp
       (("__ua_i",
         Ast.TyGlue
           (Ast.TyPlace "number", _,
            [(Ast.TyPlace "number", _); (Ast.TyPlace "number", _)])), _) ->
       check "ua(idEquiv(number)) transport lowers to a Glue line" true
   | _ -> check "ua(idEquiv(number)) transport lost its Glue line" false);
  let five_core = Desugar.desugar_expr (ELit (LitNumber 5.0, dl)) in
  check "transport along ua(idEquiv(number)) computes via Glue forward map"
    (Ast.term_equal_env []
       (Builtins.reduce_with_builtins Reduce.empty_ctx ua_core)
       five_core);

  (* Stage 3d convincing, Fix C: a syntactic equiv carries its actual forward
     map into Glue.  Typechecking the homotopies is intentionally a separate
     gate (Fix B); this oracle isolates the lowering contract. *)
  let unary_num : Tyenv.fun_sig = {
    fs_params = [("n", num)]; fs_return = num;
    fs_visits = []} in
  let desugar_env =
    Tyenv.empty
    |> fun e -> Tyenv.add_fun e "succ" unary_num
    |> fun e -> Tyenv.add_fun e "pred" unary_num in
  ignore (Desugar.desugar_program ~env:(Some desugar_env) []);
  let refl_lam name =
    ELam ([(name, num)], ERefl (EVar (name, dl), dl), dl) in
  let equiv_expr =
    ECall ("equiv", [EVar ("succ", dl); EVar ("pred", dl);
            refl_lam "a"; refl_lam "b"], dl) in
  let transport_ua_equiv =
    ECall ("transport", [ECall ("ua", [equiv_expr], dl); ELit (LitNumber 10.0, dl)], dl) in
  let ua_equiv_core = Desugar.desugar_expr transport_ua_equiv in
  (match ua_equiv_core with
   | Ast.Transp
       (("__ua_i",
         Ast.TyGlue
           (Ast.TyPlace "number", _,
            [(Ast.TyPlace "number",
              Ast.Pair (Ast.Var "succ",
                Ast.Pair (Ast.Var "pred", Ast.Pair (_, _))));
             (Ast.TyPlace "number", _)])), _) ->
       check "ua(equiv(succ,pred,...)) carries canonical Pair in Glue" true
   | _ -> check "ua(equiv(...)) lost its forward map or Glue line" false);
  (match Builtins.reduce_with_builtins Reduce.empty_ctx ua_equiv_core with
   | Ast.App (Ast.Var "succ", _) ->
       check "Glue transport reduces to the supplied forward map succ" true
   | _ -> check "Glue transport did not expose equiv's forward map" false);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
