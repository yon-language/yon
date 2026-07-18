(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_sheaf.ml — ORACLE for the sheaf descent judgement (sheafification
 * soundness gate). See sheaf.ml header: a field : W -> V is accepted iff it
 * FACTORS through the quotient map canon : W -> Q, i.e. it is determined by the
 * relation Rel and never reads the finer element identity ("the address").
 *
 * The gate (sheaf.ml:88-95 field_factors_through):
 *   - x  := fresh point "#sheaf-point"
 *   - cx := nf (canon x),  fx := nf (field x)
 *   - abstract cx out of fx (replace with fresh #sheaf-class)
 *   - factors  <=>  x no longer free in the abstracted body.
 *
 * Grounded on:
 *   sheaf.ml:62-65   quotient_canon ~rel ~domain  = Lam(#sheaf-arg, domain,
 *                       App(Var "__field_rel", Var #sheaf-arg))
 *   sheaf.ml:88-95   field_factors_through (ctx) ~canon ~field : bool
 *   sheaf.ml:106-111 field_map ~world ~field_name = Lam("u", TyPlace world,
 *                       App(Var "__field_<name>", Var "u"))
 *   sheaf.ml:116-123 quotient_violations
 *   sheaf.ml:141-152 place_violations (ctx) site pd : string list
 *   reduce.ml:31-55  Reduce.ctx / Reduce.empty_ctx (used as the reduction ctx)
 *   builtins.ml:208  beta: App (Lam (x,_,body), arg) reduces — so canon x and
 *                    field x beta-normalize to their projection bodies.
 *   ast.ml:89-122    term: Var, Lam, App ; ast.ml:55 TyPlace of string
 *   ast.ml:317-322   free_vars (Var x = singleton x; abstraction removes binder)
 *)

module C = Ast

let pass = ref 0
let fails = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fails; Printf.printf "  [FAIL] %s\n" name)

let () =
  Printf.printf "=== sheaf descent (field_factors_through) oracle ===\n\n";

  let ctx = Reduce.empty_ctx in
  let world = "Account" in
  (* canon = quotient map for the relation field "class". canon x beta-reduces
   * to  __field_class x  (the canonical class of x). *)
  let canon = Sheaf.quotient_canon ~rel:"class" ~domain:(C.TyPlace world) in

  (* (A1) FACTORING: the field IS the relation projection. Then field x = canon x
   * exactly, the abstraction replaces the whole body, x disappears -> ACCEPT. *)
  let field_rel = Sheaf.field_map ~world ~field_name:"class" in
  check "factor: relation projection itself factors (accept)"
    (Sheaf.field_factors_through ctx ~canon ~field:field_rel = true);

  (* (A2) FACTORING: a CONSTANT field never reads x at all -> trivially factors. *)
  let field_const = C.Lam ("u", C.TyPlace world, C.Var "k") in
  check "factor: constant field factors (accept)"
    (Sheaf.field_factors_through ctx ~canon ~field:field_const = true);

  (* (B) NON-FACTORING: the field reads a DIFFERENT, finer key than the relation
   * — the element's own "address", not its class. field x = __field_address x,
   * which is never alpha-equal to canon x = __field_class x, so the abstraction
   * does not fire and x stays free -> REJECT (the sheaf violation). *)
  let field_addr = Sheaf.field_map ~world ~field_name:"address" in
  check "non-factor: address-reading field is rejected (reject)"
    (Sheaf.field_factors_through ctx ~canon ~field:field_addr = false);

  (* (C) quotient_violations: over fields [class; address], only the finer
   * "address" breaks descent; the relation field "class" factors through
   * itself. Pins the list-level gate. *)
  let viols =
    Sheaf.quotient_violations ctx ~world ~rel_field:"class"
      ~fields:["class"; "address"] in
  check "quotient_violations isolates the non-factoring field"
    (viols = ["address"]);
  check "quotient_violations keeps the relation field (factors through itself)"
    (not (List.mem "class" viols));

  (* (D) place_violations smoke test: a world WITHOUT a quotient generator
   * imposes no field-level condition (sheaf.ml:141-152: None -> []). *)
  let site_no_quotient : C.world_decl =
    { C.w_name = world; C.w_objects = []; C.w_generators = [] } in
  let pd : C.place_decl =
    { C.p_name = "P"; C.p_site = C.TyPlace world;
      C.p_fields = ["class", C.TyPlace world; "address", C.TyPlace world];
      C.p_operations = []; C.p_laws = [] } in
  check "place_violations: non-quotient world has no field reject ([])"
    (Sheaf.place_violations ctx site_no_quotient pd = []);

  (* (E) place_violations on a world WITH a quotient generator W/class: the
   * place's "address" field is the descent violation, "class" is not. *)
  let site_quotient : C.world_decl =
    { C.w_name = world; C.w_objects = [];
      C.w_generators = [C.GenQuotient (world, "class")] } in
  let pv = Sheaf.place_violations ctx site_quotient pd in
  check "place_violations: quotient world flags the address field"
    (List.mem "address" pv && not (List.mem "class" pv));

  Printf.printf "\n%d passed, %d failed\n" !pass !fails;
  if !fails = 0 then exit 0 else exit 1
