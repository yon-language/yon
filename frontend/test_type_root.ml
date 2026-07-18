(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_type_root.ml — oracle for the Fase 1 / Step 1 type_root (standalone).
 * Checks the identity function on real surface types, Nominal_type. Not wired into
 * the compile path; exits nonzero on any failure. *)

open Surface_ast
module TR = Type_root
module TE = Tyenv

let num = TyPrim "number"
let v n args = { v_name = n; v_args = args }

(* an env with the named inductives under test *)
let env =
  let e = TE.empty in
  let e = TE.add_named_sum e "Bool" [v "True" []; v "False" []] in
  let e = TE.add_named_sum e "OnOff" [v "On" []; v "Off" []] in        (* Bool's structure, other name *)
  let e = TE.add_named_sum e "Bit" [v "Zero" []; v "One" []] in         (* equivalent to Bool *)
  let e = TE.add_named_sum e "Expr" [v "ENum" [num]] in
  let e = TE.add_named_sum e "List" [v "Nil" []; v "Cons" [num; TyUser "List"]] in   (* recursion *)
  let e = TE.add_named_sum e "P1" [v "Pair" [num; num]] in
  let e = TE.add_named_sum e "P2" [v "Pair" [num; TyUser "Expr"]] in    (* nested inductive *)
  (* Seq: List's exact structure AND constructor names, only the TYPE name differs.
     Under Nominal_type it must be DISTINCT from List (the defining property of the
     chosen mode; Nominal_ctor would collide them). *)
  let e = TE.add_named_sum e "Seq" [v "Nil" []; v "Cons" [num; TyUser "Seq"]] in
  e

(* two ANONYMOUS sums differing ONLY in constructor order (no type name to confound) *)
let anon_ab = TySum [v "A" [num]; v "B" []]
let anon_ba = TySum [v "B" []; v "A" [num]]

let fails = ref 0
let root name = TR.type_root env (TyUser name)
let check desc cond =
  if cond then Printf.printf "  ok   %s\n" desc
  else (incr fails; Printf.printf "  FAIL %s\n" desc)
let some_eq a b = match a, b with Some x, Some y -> Int64.equal x y | _ -> false
let both_some a b = match a, b with Some _, Some _ -> true | _ -> false

let () =
  Printf.printf "=== type_root (Nominal_type, standalone) ===\n";

  (* determinism: same definition -> same root, always *)
  check "determinism: root(List) is stable" (some_eq (root "List") (root "List"));

  (* Nominal_type keeps equivalent-but-distinct types apart (T2 / univalence):
     Bool, OnOff, Bit share structure but have distinct type names -> distinct roots.
     This is what leaves the equivalence Bool ~ Bit a path (ua), not a definitional
     identity. *)
  check "Bool != OnOff (same shape, different name)" (not (some_eq (root "Bool") (root "OnOff")));
  check "Bool != Bit  (equivalent, T2)"              (not (some_eq (root "Bool") (root "Bit")));

  (* recursion resolves (de Bruijn), and a nested inductive changes the root *)
  check "List has a root (recursion resolved)" (root "List" <> None);
  check "P1(num,num) != P2(num,Expr) (nested)" (not (some_eq (root "P1") (root "P2")));
  check "P1, P2 both in Zona 1"                (both_some (root "P1") (root "P2"));

  (* the defining property of Nominal_type: same structure + same ctor names, only
     the type name differs -> distinct (Nominal_ctor would collide these) *)
  check "List != Seq (Nominal_type: type name counts)" (not (some_eq (root "List") (root "Seq")));

  (* order screw, on anonymous sums (no type name to confound) *)
  check "TySum [A|B] != [B|A] (order is significant)"
    (not (some_eq (TR.type_root env anon_ab) (TR.type_root env anon_ba)));

  (* a primitive is a Zona-1 leaf *)
  check "number has a root (primitive)" (TR.type_root env num <> None);

  (* Partiality (the Zona-1 frontier): no runtime value -> no root *)
  check "TyUniverse -> None (partiality)"   (TR.type_root env (TyUniverse 0) = None);
  check "TyVar 'a'  -> None (type var)"      (TR.type_root env (TyVar "a") = None);
  check "TyUser unknown -> None"             (TR.type_root env (TyUser "Nope") = None);

  (* the root shares the value hash space: it is a plain uint64 from FNV *)
  (match root "Bool" with
   | Some r -> Printf.printf "  (root(Bool) = %016Lx)\n" r
   | None -> incr fails; Printf.printf "  FAIL Bool without a root\n");

  if !fails = 0 then (Printf.printf "PASS type_root: all ok\n"; exit 0)
  else (Printf.printf "FAIL type_root: %d failed\n" !fails; exit 1)
