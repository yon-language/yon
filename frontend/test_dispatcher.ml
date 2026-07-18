(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_dispatcher.ml — ORACLE: equality + directional subtype known-answer.
 *
 * Pins the type-equality dispatcher (Dispatcher.type_equal) and the
 * directional-subtype fix (Dispatcher.subtype), both on hand-built surface
 * types. Known-answer: each check fixes a true/false verdict.
 *
 * Grounded on:
 *   - dispatcher.ml:301 type_equal : env -> ctx -> ty -> ty -> bool
 *   - dispatcher.ml:402 subtype : env -> ctx -> sub:ty -> super:ty -> bool
 *       sound one-way promotions (dispatcher.ml:404-407):
 *         number      <: heyt_int<N>
 *         heyt_int<N> <: proposition
 *         number      <: proposition
 *   - dispatcher.ml:308  TyHeytInt n1 = TyHeytInt n2  iff  n1 = n2
 *   - dispatcher.ml:312  text <-> TyUser "String"  (string fusion)
 *   - tyenv.ml:89 empty, tyenv.ml:467 with_builtins (env construction,
 *     same as Tycheck.check_program at tycheck.ml:4204)
 *   - reduce.ml:47 empty_ctx
 *)

open Surface_ast

let pass = ref 0
let fails = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fails; Printf.printf "  [FAIL] %s\n" name)

let env = Tyenv.with_builtins Tyenv.empty
let ctx = Reduce.empty_ctx

let eq t1 t2 = Dispatcher.type_equal env ctx t1 t2
let sub ~sub:s ~super:p = Dispatcher.subtype env ctx ~sub:s ~super:p

let num = TyPrim "number"
let txt = TyPrim "text"
let prop = TyPrim "proposition"

let () =
  Printf.printf "=== Dispatcher equality / subtype oracle ===\n\n";

  (* ── type_equal: primitives ─────────────────────────────────────── *)
  check "type_equal number number = true" (eq num num);
  check "type_equal number text = false" (not (eq num txt));

  (* ── type_equal: TyHeytInt parametric equality ──────────────────── *)
  check "type_equal heyt_int<8> heyt_int<8> = true"
    (eq (TyHeytInt 8) (TyHeytInt 8));
  check "type_equal heyt_int<8> heyt_int<16> = false"
    (not (eq (TyHeytInt 8) (TyHeytInt 16)));

  (* ── type_equal: text / String fusion (bidirectional) ───────────── *)
  check "type_equal text (TyUser \"String\") = true (fusion)"
    (eq txt (TyUser "String"));
  check "type_equal (TyUser \"String\") text = true (fusion, reverse)"
    (eq (TyUser "String") txt);

  (* ── subtype: the directional fix ───────────────────────────────── *)
  (* number promotes to heyt_int (mask=0: every bit certain). *)
  check "subtype ~sub:number ~super:heyt_int<8> = true (promotion)"
    (sub ~sub:num ~super:(TyHeytInt 8));
  (* the REVERSE is the unsound direction, now rejected. *)
  check "subtype ~sub:heyt_int<8> ~super:number = false (unsound, rejected)"
    (not (sub ~sub:(TyHeytInt 8) ~super:num));
  (* subtype on equal types is true (reflexive via type_equal). *)
  check "subtype on equal types (number, number) = true"
    (sub ~sub:num ~super:num);
  (* heyt_int promotes to proposition. *)
  check "subtype ~sub:heyt_int<8> ~super:proposition = true (promotion)"
    (sub ~sub:(TyHeytInt 8) ~super:prop);

  Printf.printf "\n%d passed, %d failed\n" !pass !fails;
  if !fails = 0 then exit 0 else exit 1
