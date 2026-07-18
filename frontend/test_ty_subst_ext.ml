(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_ty_subst_ext.ml — ORACLE (extension): Algorithm-W substitution core.
 *
 * test_ty_subst.ml already pins: fresh gen, apply_subst on metavar/list,
 * occur_check, base + constructor unify, occur-during-unify, compose_subst,
 * and one generalize/instantiate round. This file ADDS, adversarially:
 *
 *   - Pi/Sigma/Arrow STRUCTURE preservation under apply_subst (binder kept,
 *     domain AND codomain substituted).
 *   - Substitution in dependent codomains (Pi/Sigma), and the DELIBERATE
 *     LIMITS: apply_subst does NOT descend into TyId/TyPathP endpoint terms,
 *     and treats TyEl as opaque. free_metavars agrees with that.
 *   - Capture-freedom: a substituted TyVar whose name equals a Pi term-binder
 *     is NOT captured (term-binders and type-vars are disjoint namespaces).
 *   - apply_subst chases metavar CHAINS transitively; idempotence of a
 *     compose-built substitution.
 *   - unify: Pi<->Sigma is a MISMATCH; shared-metavar consistency in TyMap;
 *     "unknown" is a wildcard; and the limits — unify has NO arm for
 *     TyId / TyEl / TySum, so even identical ones MISMATCH.
 *   - generalize respects env-free metavars; instantiate freshens only bound
 *     vars and keeps env-free ones; monomorphic scheme instantiates to itself.
 *   - compose_subst substitutes sigma1 into sigma2's RHS and keeps unshadowed
 *     sigma1 bindings.
 *
 * Grounded on ty_subst.ml: apply_subst:51, compose_subst:85, free_metavars:97,
 * occur_check:126, unify:147, try_unify:222, generalize:237, instantiate:245.
 *)

open Surface_ast
open Ty_subst

let num = TyPrim "number"
let txt = TyPrim "text"

let pass = ref 0
let fails = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fails; Printf.printf "  [FAIL] %s\n" name)

let dl = dummy_loc
let tm x = TyTermExpr (EVar (x, dl))
(* sorted free-metavars, so we compare as sets regardless of traversal order *)
let fmv t = List.sort compare (uniq (free_metavars t))

let () =
  Printf.printf "=== Ty_subst core oracle (ext) ===\n\n";

  (* ── structure preservation + dependent codomains ───────────────────── *)
  Printf.printf "-- structure preservation --\n";
  check "apply into Pi: binder kept, domain+codomain substituted"
    (apply_subst [(0, num)] (TyPi ("x", TyMetaVar 0, TyList (TyMetaVar 0)))
     = TyPi ("x", num, TyList num));
  check "apply into Sigma: binder kept, both sides substituted"
    (apply_subst [(0, num)] (TySigma ("p", TyMetaVar 0, TyMap (TyMetaVar 0, txt)))
     = TySigma ("p", num, TyMap (num, txt)));
  check "apply into Arrow: both positions substituted"
    (apply_subst [(0, num); (1, txt)] (TyArrow (TyMetaVar 0, TyMetaVar 1))
     = TyArrow (num, txt));

  (* ── capture-freedom (disjoint namespaces) ──────────────────────────── *)
  Printf.printf "-- capture-freedom --\n";
  check "subst TyVar \"x\" under Pi binder \"x\" is NOT captured (disjoint namespaces)"
    (apply_subst [(0, TyVar "x")] (TyPi ("x", TyMetaVar 0, TyMetaVar 0))
     = TyPi ("x", TyVar "x", TyVar "x"));

  (* ── DELIBERATE LIMITS: TyId/TyPathP endpoints + TyEl opacity ───────── *)
  Printf.printf "-- substitution limits (endpoints / El) --\n";
  check "apply into TyId substitutes carrier, leaves endpoint terms intact"
    (apply_subst [(0, num)] (TyId (TyMetaVar 0, tm "a", tm "b"))
     = TyId (num, tm "a", tm "b"));
  check "apply into TyPathP substitutes carrier line, leaves endpoints intact"
    (apply_subst [(0, num)] (TyPathP (("i", TyMetaVar 0), tm "x", tm "y"))
     = TyPathP (("i", num), tm "x", tm "y"));
  check "apply on TyEl is identity (El code is opaque to subst)"
    (apply_subst [(0, num)] (TyEl (tm "c")) = TyEl (tm "c"));

  (* ── free_metavars agrees with apply_subst's reach ──────────────────── *)
  Printf.printf "-- free_metavars reach --\n";
  check "fmv(TyId(a0, a, b)) = [0]  (endpoint terms invisible)"
    (fmv (TyId (TyMetaVar 0, tm "a", tm "b")) = [0]);
  check "fmv(TyEl c) = []  (El opaque)"
    (fmv (TyEl (tm "c")) = []);
  check "fmv(Pi(x, a0, a1)) = [0;1]"
    (fmv (TyPi ("x", TyMetaVar 0, TyMetaVar 1)) = [0; 1]);
  check "fmv(Arrow(a0, list a1)) = [0;1]"
    (fmv (TyArrow (TyMetaVar 0, TyList (TyMetaVar 1))) = [0; 1]);
  check "fmv(TySum[C a0 a2]) = [0;2]"
    (fmv (TySum [ { v_name = "C"; v_args = [ TyMetaVar 0; TyMetaVar 2 ] } ]) = [0; 2]);

  (* ── chain following + idempotence ──────────────────────────────────── *)
  Printf.printf "-- chains + idempotence --\n";
  check "apply chases chains: [0->a1; 1->number] on a0 = number"
    (apply_subst [(0, TyMetaVar 1); (1, num)] (TyMetaVar 0) = num);
  let sig_idem = compose_subst [(1, num)] [(0, TyMetaVar 1)] in
  check "compose-built subst is idempotent on a metavar"
    (apply_subst sig_idem (TyMetaVar 0)
     = apply_subst sig_idem (apply_subst sig_idem (TyMetaVar 0)));
  let big = TyPi ("x", TyMetaVar 0, TyArrow (TyMetaVar 1, TyMetaVar 0)) in
  let once = apply_subst sig_idem big in
  check "compose-built subst is idempotent on a compound type"
    (apply_subst sig_idem once = once);
  check "  (and that compound resolves fully to number)"
    (once = TyPi ("x", num, TyArrow (num, num)));

  (* ── unify: structure, shared vars, and the limit arms ──────────────── *)
  Printf.printf "-- unify structure + limits --\n";
  check "unify Pi(a0,a1) Pi(number,text) binds a0->number, a1->text (binders ignored)"
    (match try_unify (TyPi ("x", TyMetaVar 0, TyMetaVar 1)) (TyPi ("y", num, txt)) with
     | Ok s -> apply_subst s (TyMetaVar 0) = num && apply_subst s (TyMetaVar 1) = txt
     | Error _ -> false);
  check "unify Sigma(a0,a1) Sigma(number,text) binds both"
    (match try_unify (TySigma ("x", TyMetaVar 0, TyMetaVar 1)) (TySigma ("y", num, txt)) with
     | Ok s -> apply_subst s (TyMetaVar 0) = num && apply_subst s (TyMetaVar 1) = txt
     | Error _ -> false);
  check "unify Pi vs Sigma -> mismatch (no cross arm)"
    (match try_unify (TyPi ("x", num, num)) (TySigma ("x", num, num)) with
     | Error (UMismatch _) -> true | _ -> false);
  check "unify Arrow(num,text) Arrow(num,num) -> mismatch (codomain differs)"
    (match try_unify (TyArrow (num, txt)) (TyArrow (num, num)) with
     | Error (UMismatch _) -> true | _ -> false);
  check "unify map(a0,a0) map(number,number) -> a0 = number (shared var consistent)"
    (match try_unify (TyMap (TyMetaVar 0, TyMetaVar 0)) (TyMap (num, num)) with
     | Ok s -> apply_subst s (TyMetaVar 0) = num | Error _ -> false);
  check "unify map(a0,a0) map(number,text) -> mismatch (shared var conflict)"
    (match try_unify (TyMap (TyMetaVar 0, TyMetaVar 0)) (TyMap (num, txt)) with
     | Error (UMismatch _) -> true | _ -> false);
  check "unify unknown (list number) -> ok empty (unknown is a wildcard)"
    (try_unify (TyPrim "unknown") (TyList num) = Ok []);
  check "unify TyUser P TyUser P -> ok empty"
    (try_unify (TyUser "P") (TyUser "P") = Ok []);
  check "unify TyUser P TyUser Q -> mismatch"
    (match try_unify (TyUser "P") (TyUser "Q") with
     | Error (UMismatch _) -> true | _ -> false);
  (* LIMITS: unify has no arm for these constructors -> mismatch even when
     structurally identical (HM is first-order; dependent types never reach
     unify in the live pipeline). *)
  check "unify identical TyId -> mismatch (no TyId arm in unify)"
    (match try_unify (TyId (num, tm "a", tm "a")) (TyId (num, tm "a", tm "a")) with
     | Error (UMismatch _) -> true | _ -> false);
  check "unify identical TyEl -> mismatch (no TyEl arm)"
    (match try_unify (TyEl (tm "c")) (TyEl (tm "c")) with
     | Error (UMismatch _) -> true | _ -> false);
  check "unify identical TySum -> mismatch (no TySum arm, though apply_subst has one)"
    (let s = TySum [ { v_name = "C"; v_args = [ num ] } ] in
     match try_unify s s with Error (UMismatch _) -> true | _ -> false);

  (* ── generalize / instantiate ───────────────────────────────────────── *)
  Printf.printf "-- generalize / instantiate --\n";
  (* env-free metavar 0 stays; only 1 is generalized. *)
  let sch = generalize [0] (TyArrow (TyMetaVar 0, TyMetaVar 1)) in
  check "generalize [0] over (a0->a1) binds only a1"
    (List.sort compare sch.bound = [1]);
  reset_metavars ();
  let _ = fresh_metavar () in  (* alpha0 *)
  let _ = fresh_metavar () in  (* alpha1 *)
  let inst = instantiate sch in
  check "instantiate keeps env-free a0 in the domain"
    (match inst with TyArrow (TyMetaVar 0, _) -> true | _ -> false);
  check "instantiate freshens the bound a1 (domain <> codomain metavar)"
    (match inst with
     | TyArrow (TyMetaVar 0, TyMetaVar k) -> k <> 0 && k <> 1 | _ -> false);
  (* two instantiations of a fully-quantified scheme give disjoint fresh vars. *)
  let sch2 = generalize [] (TyArrow (TyMetaVar 0, TyMetaVar 1)) in
  check "generalize [] quantifies all metavars"
    (List.sort compare sch2.bound = [0; 1]);
  let i1 = instantiate sch2 and i2 = instantiate sch2 in
  check "two instantiations are distinct (fresh each time)" (i1 <> i2);
  check "instantiate preserves the arrow structure"
    (match i1 with TyArrow (_, _) -> true | _ -> false);
  check "instantiate of a monomorphic scheme (bound=[]) is the body itself"
    (instantiate { bound = []; body = num } = num);

  (* ── compose_subst RHS substitution ─────────────────────────────────── *)
  Printf.printf "-- compose_subst --\n";
  let comp = compose_subst [(1, num)] [(0, TyList (TyMetaVar 1))] in
  check "compose applies sigma1 into sigma2's RHS: a0 -> list number"
    (apply_subst comp (TyMetaVar 0) = TyList num);
  check "compose keeps unshadowed sigma1 binding: a1 -> number"
    (apply_subst comp (TyMetaVar 1) = num);

  Printf.printf "\n%d passed, %d failed\n" !pass !fails;
  if !fails = 0 then exit 0 else exit 1
