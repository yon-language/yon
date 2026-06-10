(* test_ln.ml — oracle for the locally-nameless primitives (stadio 2).
 * Round-trip (close then open = id), instantiation, and capture-safety, on
 * nested Lam terms built by hand. Standalone:
 *   ocamlc ast.ml locally_nameless.ml test_ln.ml -o /tmp/tln
 *)

open Ast
open Locally_nameless

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let num = TyBase "number"

let () =
  Printf.printf "=== locally-nameless primitives oracle (stadio 2) ===\n\n";

  (* round-trip: close x then open (FVar x) recovers the original *)
  let rt name body =
    let t = open_term (FVar "x") (close_term "x" body) in
    check name (term_equal t body)
  in
  rt "round-trip: bare free name"
    (FVar "x");
  rt "round-trip: under one binder  (fun y. x y)"
    (Lam ("y", num, App (FVar "x", BVar 0)));
  rt "round-trip: under two binders (fun y. fun z. x (y z))"
    (Lam ("y", num, Lam ("z", num, App (FVar "x", App (BVar 1, BVar 0)))));
  rt "round-trip: free name appears twice"
    (Lam ("y", num, App (App (FVar "x", BVar 0), FVar "x")));

  (* open instantiates BVar 0 with the argument *)
  check "instantiate: open a (#0 f) = (a f)"
    (term_equal
       (open_term (FVar "a") (App (BVar 0, FVar "f")))
       (App (FVar "a", FVar "f")));

  (* CAPTURE-SAFETY (the whole point): opening with a free name y into a body
     that has an inner binder must NOT let the inner binder capture y. *)
  let opened =
    open_term (FVar "y") (Lam ("z", num, App (BVar 1, BVar 0))) in
  check "no capture: open y into (fun z. #1 #0) = (fun z. y #0), y stays free"
    (term_equal opened (Lam ("z", num, App (FVar "y", BVar 0))));

  (* close of an absent name is the identity *)
  check "close of absent name is identity"
    (term_equal (close_term "q" (Lam ("y", num, App (FVar "x", BVar 0))))
       (Lam ("y", num, App (FVar "x", BVar 0))));

  (* alpha payoff, made concrete: two source-distinct binder names abstract to
     the SAME locally-nameless body. The BODIES of (fun a. a) and (fun b. b)
     both close to #0 — identical, independent of the source name. (term_equal
     on the whole Lam still compares binder names; that is stadio 3's job.) *)
  let body_a = close_term "a" (FVar "a") in
  let body_b = close_term "b" (FVar "b") in
  check "alpha payoff: bodies of (fun a. a) and (fun b. b) both close to #0"
    (term_equal body_a body_b && term_equal body_a (BVar 0));

  Printf.printf "\n=== %d passed, %d failed ===\n" !pass !fail;
  if !fail > 0 then exit 1
