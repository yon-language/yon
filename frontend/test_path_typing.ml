(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_path_typing.ml — precise surface typing of path operators.
 *
 * concat/inv compute the correct endpoints on STRUCTURED identity types
 * (Id A x y), and a non-composable concat is a CLEAN type error.  Checked
 * end-to-end through Tycheck.infer, the way a user actually writes them:
 * refl(a) : Id(A,a,a) (the ERefl node already tracks real endpoints), and
 * annotated variables p : Id(A,a,b).
 *
 * A path between types is Id(Type, A, B), its endpoints the codes of A and B:
 * transport reads its target from the path's type, whatever form the path
 * has; a path whose endpoints are not known types is refused. path_app has
 * the path's carrier type, unglue gives back the base its glue recorded. *)

open Surface_ast

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let () =
  Printf.printf "=== Path-operator precise typing (Task 0-A: concat / inv) ===\n\n";
  let dl = dummy_loc in
  let ctx = Reduce.empty_ctx in
  let num = TyPrim "number" in
  let tt s = TyTermExpr (EVar (s, dl)) in
  (* points a,b,c,x : number and paths between them *)
  let txt = TyPrim "text" in
  let pab = TyId (num, tt "a", tt "b") in   (* p  : Id(number, a, b) *)
  let qbc = TyId (num, tt "b", tt "c") in   (* q  : Id(number, b, c) *)
  let qxc = TyId (num, tt "x", tt "c") in   (* q' : Id(number, x, c)  (start != b) *)
  let ptxt = TyId (txt, tt "s", tt "t") in  (* pt : Id(text, s, t)  (wrong carrier for f) *)
  let equiv_nt = Cubical_bindings.mk_equiv_ty num txt in  (* e : Equiv number text *)
  let env = Tyenv.add_vars Tyenv.empty
      [("a", num); ("b", num); ("c", num); ("x", num); ("s", txt); ("t", txt);
       ("p", pab); ("q", qbc); ("q2", qxc); ("pt", ptxt);
       ("f", TyArrow (num, num)); ("e", equiv_nt)] in

  (* inv(p) : Id(number, b, a) — endpoints swapped *)
  (match Tycheck.infer env ctx (ECall ("inv", [EVar ("p", dl)], dl)) with
   | Ok (TyId (TyPrim "number", TyTermExpr (EVar ("b", _)), TyTermExpr (EVar ("a", _)))) ->
       check "inv(p : Id(number,a,b)) : Id(number,b,a)" true
   | Ok other -> check (Printf.sprintf "inv: unexpected %s" (Tyenv.ty_to_string other)) false
   | Error e -> check (Printf.sprintf "inv: infer failed: %s" (Tycheck.error_to_string e)) false);

  (* inv(refl(a)) : Id(number, a, a) — refl endpoints preserved under swap *)
  (match Tycheck.infer env ctx (ECall ("inv", [ERefl (EVar ("a", dl), dl)], dl)) with
   | Ok (TyId (TyPrim "number", TyTermExpr (EVar ("a", _)), TyTermExpr (EVar ("a", _)))) ->
       check "inv(refl(a)) : Id(number,a,a)" true
   | _ -> check "inv(refl(a)) : Id(number,a,a)" false);

  (* concat(p,q) : Id(number, a, c) — composes at the shared midpoint b *)
  (match Tycheck.infer env ctx (ECall ("concat", [EVar ("p", dl); EVar ("q", dl)], dl)) with
   | Ok (TyId (TyPrim "number", TyTermExpr (EVar ("a", _)), TyTermExpr (EVar ("c", _)))) ->
       check "concat(p:Id(a,b), q:Id(b,c)) : Id(number,a,c)" true
   | Ok other -> check (Printf.sprintf "concat: unexpected %s" (Tyenv.ty_to_string other)) false
   | Error e -> check (Printf.sprintf "concat: infer failed: %s" (Tycheck.error_to_string e)) false);

  (* MISTYPED: concat(p:Id(a,b), q':Id(x,c)) — b != x must be rejected CLEAN *)
  (match Tycheck.infer env ctx (ECall ("concat", [EVar ("p", dl); EVar ("q2", dl)], dl)) with
   | Error _ ->
       check "concat(Id(a,b), Id(x,c)) REJECTED (endpoints don't meet)" true
   | Ok other ->
       check (Printf.sprintf "concat mismatch WRONGLY accepted: %s" (Tyenv.ty_to_string other)) false);

  (* ap(f, refl(a)) : Id(number, f(a), f(a)) — endpoints are f applied to a *)
  (match Tycheck.infer env ctx
           (ECall ("ap", [EVar ("f", dl); ERefl (EVar ("a", dl), dl)], dl)) with
   | Ok (TyId (TyPrim "number",
               TyTermExpr (EApp (EVar ("f", _), [EVar ("a", _)], _)),
               TyTermExpr (EApp (EVar ("f", _), [EVar ("a", _)], _)))) ->
       check "ap(f:Number->number, refl(a)) : Id(number, f(a), f(a))" true
   | Ok other -> check (Printf.sprintf "ap: unexpected %s" (Tyenv.ty_to_string other)) false
   | Error e -> check (Printf.sprintf "ap: infer failed: %s" (Tycheck.error_to_string e)) false);

  (* MISTYPED: ap(f:Number->number, pt:Id(text,s,t)) — domain != carrier, reject *)
  (match Tycheck.infer env ctx
           (ECall ("ap", [EVar ("f", dl); EVar ("pt", dl)], dl)) with
   | Error _ ->
       check "ap(number->number, Id(text,..)) REJECTED (domain != carrier)" true
   | Ok other ->
       check (Printf.sprintf "ap domain-mismatch WRONGLY accepted: %s" (Tyenv.ty_to_string other)) false);

  (* transport(ua(e), a) : Text — univalence maps the source (number) to B (text) *)
  (match Tycheck.infer env ctx
           (ECall ("transport", [ECall ("ua", [EVar ("e", dl)], dl); EVar ("a", dl)], dl)) with
   | Ok (TyPrim "text") ->
       check "transport(ua(e:Equiv number text), a:number) : Text" true
   | Ok other -> check (Printf.sprintf "transport: unexpected %s" (Tyenv.ty_to_string other)) false
   | Error e -> check (Printf.sprintf "transport: infer failed: %s" (Tycheck.error_to_string e)) false);

  (* MISTYPED: transport(ua(e), s:text) — source must be number (A), reject *)
  (match Tycheck.infer env ctx
           (ECall ("transport", [ECall ("ua", [EVar ("e", dl)], dl); EVar ("s", dl)], dl)) with
   | Error _ ->
       check "transport(ua(e), text-value) REJECTED (source != A)" true
   | Ok other ->
       check (Printf.sprintf "transport source-mismatch WRONGLY accepted: %s" (Tyenv.ty_to_string other)) false);

  (* a NAMED universe path: the target is read from its type *)
  let env_u = Tyenv.add_vars env
      [("u", TyId (TyUniverse 0, tt "number", tt "text")); ("p", TyUser "Path")] in
  (match Tycheck.infer env_u ctx (ECall ("transport", [EVar ("u", dl); EVar ("a", dl)], dl)) with
   | Ok (TyPrim "text") -> check "transport(u : Id(Type, Number, Text), a) : Text" true
   | Ok other -> check (Printf.sprintf "transport along u: unexpected %s" (Tyenv.ty_to_string other)) false
   | Error e -> check (Printf.sprintf "transport along u: infer failed: %s" (Tycheck.error_to_string e)) false);
  (* a path without known endpoints carries no target: refused *)
  (match Tycheck.infer env_u ctx (ECall ("transport", [EVar ("p", dl); EVar ("a", dl)], dl)) with
   | Error _ -> check "transport(p : Path, a) REJECTED (no endpoints)" true
   | Ok other -> check (Printf.sprintf "transport along a bare Path WRONGLY typed %s" (Tyenv.ty_to_string other)) false);

  (* path_app has the carrier type of the path *)
  (match Cubical_bindings.check_call "path_app" [TyId (num, tt "a", tt "b"); TyPrim "unknown"] with
   | Ok t when t = num -> check "path_app(p : Id(number, a, b), i) : number" true
   | Ok other -> check (Printf.sprintf "path_app: unexpected %s" (Tyenv.ty_to_string other)) false
   | Error m -> check ("path_app: " ^ m) false);
  (match Cubical_bindings.check_call "path_app" [num; TyPrim "unknown"] with
   | Error _ -> check "path_app on a non-path REJECTED" true
   | Ok _ -> check "path_app on a non-path WRONGLY accepted" false);

  (* glue records its base; unglue gives it back *)
  (match Cubical_bindings.check_call "glue" [TyPrim "unknown"; num] with
   | Ok (TyApp ("Glue", [b])) when b = num ->
       (match Cubical_bindings.check_call "unglue" [TyApp ("Glue", [num])] with
        | Ok t when t = num -> check "unglue(glue(t, a : number)) : number" true
        | _ -> check "unglue does not give back the glue's base" false)
   | _ -> check "glue does not record its base" false);
  (match Cubical_bindings.check_call "unglue" [num] with
   | Error _ -> check "unglue on a non-glued value REJECTED" true
   | Ok _ -> check "unglue on a non-glued value WRONGLY accepted" false);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
