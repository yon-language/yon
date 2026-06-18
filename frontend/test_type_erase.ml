(* test_type_erase.ml — oracle for the type-argument erasure pass.
 *
 * (1) BASE ERASURE is coordinated: a universe-typed binder is dropped from a
 *     function's lambda chain, and the matching argument is dropped at the
 *     direct call site (binder index i <-> spine position i).
 * (2) HIGHER-ORDER use of a type-parametric function (used as a value, not a
 *     direct call) is REJECTED cleanly via [Higher_order_type_param] — a typed
 *     compile-time rejection on the canonical channel (exit 3 upstream), NOT a
 *     raw [failwith]. This encodes the 2026-06-17 decree: a well-typed term
 *     with no realizable lowering is refused, never crashed on.
 *
 * The front-end (tycheck) already forbids passing a type-parametric function
 * as a value, so this pass is a defensive second net; the oracle exercises it
 * directly on hand-built Core, below the type-checker. *)

open Ast

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let () =
  Printf.printf "=== type_erase oracle ===\n\n";

  (* id : Type_0 -> number -> number, a universe-typed parameter at index 0. *)
  let id_body = Lam ("t", TyType 0, Lam ("x", TyPlace "number", Var "x")) in

  check "universe_positions finds the type param at index 0"
    (Type_erase.universe_positions id_body = [0]);

  (* drop_binders removes the universe binder, keeps the value binder. *)
  let dropped = Type_erase.drop_binders [0] id_body in
  check "drop_binders removes the universe binder, keeps the value binder"
    (match dropped with Lam ("x", _, Var "x") -> true | _ -> false);

  let positions_of f = if f = "id" then Some [0] else None in

  (* A DIRECT call id(T, v) drops the type argument: id(T, v) ~> id(v). *)
  let five = Builtins.encode_number 5.0 in
  let direct = App (App (Var "id", Var "SomeType"), five) in
  let erased = Type_erase.rewrite positions_of direct in
  check "direct call drops the type argument (id(T,v) ~> id(v))"
    (match erased with
     | App (Var "id", n) -> term_equal n five
     | _ -> false);

  (* A HIGHER-ORDER use (id passed as a value) is rejected cleanly. *)
  let ho = App (App (Var "use", Var "id"), five) in
  let clean_reject =
    try let _ = Type_erase.rewrite positions_of ho in false
    with
    | Type_erase.Higher_order_type_param "id" -> true
    | Failure _ -> false   (* a raw failwith would be the OLD, bad behaviour *)
    | _ -> false
  in
  check "higher-order use rejected via Higher_order_type_param (not failwith)"
    clean_reject;

  (* A non-type-parametric function is left untouched as a value. *)
  let plain = App (App (Var "use", Var "other"), five) in
  let kept =
    try term_equal (Type_erase.rewrite positions_of plain) plain
    with _ -> false
  in
  check "non-type-parametric function survives as a value" kept;

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
