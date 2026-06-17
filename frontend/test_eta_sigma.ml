(* test_eta_sigma.ml — oracle: eta-Sigma (surjective pairing) makes the binary
 * products of Syn(Yon) STRICT. The kernel contracts Pair(Fst t, Snd t) ~> t on
 * a NEUTRAL t, so the pairing mediator is unique (Syn(Yon) formalization sec.12:
 * "i prodotti di Syn(Yon) sono prodotti in senso stretto"). Built as CORE terms
 * and checked through the kernel normalizer, like test_path_core. *)

open Ast

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let nf t = Builtins.reduce_with_builtins Reduce.empty_ctx t

let () =
  Printf.printf "=== eta-Sigma (surjective pairing) oracle ===\n\n";

  let s = Var "s" in
  let eta = Pair (Fst s, Snd s) in

  check "Pair(Fst s, Snd s) is NOT syntactically s"
    (not (term_equal_env [] eta s));

  check "eta-Sigma contracts on a neutral term: Pair(Fst s, Snd s) ~> s"
    (term_equal_env [] (nf eta) s);

  check "mediator uniqueness: nf(Pair(Fst s, Snd s)) = nf(s)"
    (term_equal_env [] (nf eta) (nf s));

  (* a pair of projections of DIFFERENT subjects must NOT contract *)
  let t = Var "t" in
  let mixed = Pair (Fst s, Snd t) in
  check "no spurious contraction: Pair(Fst s, Snd t) does not reduce to s or t"
    (not (term_equal_env [] (nf mixed) s)
     && not (term_equal_env [] (nf mixed) t));

  (* the projection betas still hold *)
  let a = Var "a" and b = Var "b" in
  check "beta-fst preserved: Fst(Pair(a,b)) = a"
    (term_equal_env [] (nf (Fst (Pair (a, b)))) a);
  check "beta-snd preserved: Snd(Pair(a,b)) = b"
    (term_equal_env [] (nf (Snd (Pair (a, b)))) b);

  (* confluence: on a concrete pair both routes land on Pair(a,b) *)
  let pab = Pair (a, b) in
  check "confluent: Pair(Fst(a,b), Snd(a,b)) = Pair(a,b)"
    (term_equal_env [] (nf (Pair (Fst pab, Snd pab))) pab);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
