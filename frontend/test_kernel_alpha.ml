(* test_kernel_alpha.ml — oracle for the de Bruijn migration.
 *
 * Asserts the CORRECT behaviour of the type-theory kernel on binder handling.
 * It is RED on the current string-name kernel and must turn GREEN once
 * variables move to de Bruijn indices. It also empirically settles two claims
 * from the HN review (omega/lambdas) so we fix real bugs, not imagined ones.
 *
 * Build (standalone, excluded from the dune executables):
 *   ocamlc ast.ml subst.ml test_kernel_alpha.ml -o /tmp/tka
 *)

open Ast

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let num = TyPlace "number"

let () =
  Printf.printf "=== kernel binder oracle (target: de Bruijn) ===\n\n";

  (* (1) THE REAL BUG: term_equal must be alpha-equivalence.
     fun x. x  and  fun y. y  are the same function. A dependent type-checker
     compares types (which carry terms) up to alpha; a name-sensitive equality
     produces spurious type errors. *)
  let id_x = Lam ("x", num, Var "x") in
  let id_y = Lam ("y", num, Var "y") in
  check "alpha-equivalence: (fun x. x) == (fun y. y)" (term_equal id_x id_y);

  (* nested alpha-variants *)
  let k_xy = Lam ("x", num, Lam ("y", num, Var "x")) in
  let k_ab = Lam ("a", num, Lam ("b", num, Var "a")) in
  check "alpha-equivalence (nested): (fun x.fun y.x) == (fun a.fun b.a)"
    (term_equal k_xy k_ab);

  (* a genuine inequality must stay false: fun x.fun y.x  <>  fun x.fun y.y *)
  let k_xy2 = Lam ("x", num, Lam ("y", num, Var "x")) in
  let k_yy  = Lam ("x", num, Lam ("y", num, Var "y")) in
  check "distinct terms stay distinct: (fun x.fun y.x) <> (fun x.fun y.y)"
    (not (term_equal k_xy2 k_yy));

  (* (2) CLAIM CHECK (omega): does subst capture in the canonical case?
     (fun x. fun y. x) y  ==>  must NOT become  fun y. y.
     We compute subst x:=(Var y) into (fun y. x) and assert the body still
     refers to the OUTER y, i.e. the result is alpha-equal to (fun z. y). *)
  let body = Lam ("y", num, Var "x") in
  let result = Subst.subst "x" (Var "y") body in
  let captured = term_equal result (Lam ("y", num, Var "y")) in
  check "no capture in subst: (fun x.fun y.x) y does NOT become (fun y.y)"
    (not captured);
  (match result with
   | Lam (binder, _, Var v) ->
       Printf.printf "        (subst gave: fun %s. %s — body refers to outer y: %b)\n"
         binder v (v = "y")
   | _ -> Printf.printf "        (subst gave an unexpected shape)\n");

  (* (3) CLAIM CHECK (omega): is Scope a term-variable binder?
     If it is NOT (scope name lives in a separate namespace), then the Scope
     case of subst missing a capture check is not a bug. Substituting x:=(Var s)
     into <x>_s yields <Var s>_s; we just record the shape for the report. *)
  let sc = Scope ("s", Var "x") in
  let sc' = Subst.subst "x" (Var "s") sc in
  (match sc' with
   | Scope (lbl, Var v) ->
       Printf.printf "        (scope probe: <%s>_%s ; scope label and term var share text: %b)\n"
         v lbl (v = lbl)
   | _ -> ());

  Printf.printf "\n=== %d passed, %d failed ===\n" !pass !fail;
  if !fail > 0 then exit 1
