(* test_naturality_bridges.ml — oracle for the Coq and SMT naturality bridges.
 *
 * naturality_coqcheck.ml and naturality_smtcheck.ml translate an arithmetic
 * naturality obligation (LHS = RHS over the reals) into a Coq .v program / an
 * SMT-LIB formula, then hand it to an external prover (coqc / z3).
 *
 * The TRANSLATION is pure and decidable and gets known-answer coverage here:
 * to_coq / make_coq_program, to_smt / make_smt_program, parse_z3_result, and the
 * Unsupported entry branch (reachable with no external tool). The two external
 * invocations (run_coqc, run_z3, via Sys.command) are the only lines left
 * uncovered by design: they require coqc / z3 on PATH, an external-world boundary
 * kept out of CI (see AUDIT.md). Each check is two-sided where a reject exists. *)

open Surface_ast

let pass = ref 0
let fails = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fails; Printf.printf "  [FAIL] %s\n" name)

let l = dummy_loc
let num n = ELit (LitNumber n, l)
let var s = EVar (s, l)
let add a b = EBinop (OpAdd, a, b, l)
let mul a b = EBinop (OpMul, a, b, l)
let modop a b = EBinop (OpMod, a, b, l)
let call s args = ECall (s, args, l)
let h () = Hashtbl.create 4

let contains hay needle =
  let hl = String.length hay and nl = String.length needle in
  let rec go i =
    if i + nl > hl then false
    else if String.sub hay i nl = needle then true
    else go (i + 1)
  in
  nl = 0 || go 0

let () =
  let module C = Naturality_coqcheck in
  let module Z = Naturality_smtcheck in
  Printf.printf "=== naturality bridges (coq/smt translation) oracle ===\n\n";

  (* ── Coq translation: to_coq (pure) ─────────────────────────────────── *)
  check "coq: integer literal 3 -> (3)%R"
    (C.to_coq (h ()) (num 3.0) = Some "(3)%R");
  check "coq: negative literal -2 -> (- 2)%R"
    (C.to_coq (h ()) (num (-2.0)) = Some "(- 2)%R");
  check "coq: var x -> x"
    (C.to_coq (h ()) (var "x") = Some "x");
  check "coq: x + 3 -> (x + (3)%R)"
    (C.to_coq (h ()) (add (var "x") (num 3.0)) = Some "(x + (3)%R)");
  check "coq: 2 * (x + 3) nests"
    (C.to_coq (h ()) (mul (num 2.0) (add (var "x") (num 3.0)))
       = Some "((2)%R * (x + (3)%R))");
  check "coq: unsupported op (mod) -> None"
    (C.to_coq (h ()) (modop (var "x") (num 2.0)) = None);
  check "coq: unsupported expr (call) -> None"
    (C.to_coq (h ()) (call "f" [ var "x" ]) = None);

  (* ── Coq program builder + Unsupported entry ────────────────────────── *)
  (match C.make_coq_program "nat_t" (add (var "x") (num 1.0)) (add (num 1.0) (var "x")) with
   | None -> check "coq: make_coq_program on arithmetic -> Some" false
   | Some prog ->
       check "coq: program imports Reals" (contains prog "Require Import Reals.");
       check "coq: program quantifies forall x : R" (contains prog "forall x : R");
       check "coq: program closes with ring" (contains prog "Proof. intros. ring. Qed."));
  check "coq: make_coq_program on non-arith lhs -> None"
    (C.make_coq_program "t" (call "f" []) (num 1.0) = None);
  check "coq: check on unsupported expr -> Coq_unsupported (no coqc)"
    (match C.check ~theorem_name:"t" (call "f" []) (num 1.0) with
     | C.Coq_unsupported _ -> true | _ -> false);

  (* ── SMT translation: to_smt (pure) ─────────────────────────────────── *)
  check "smt: integer literal 3 -> 3"
    (Z.to_smt (h ()) (num 3.0) = Some "3");
  check "smt: negative literal -2 -> (- 2)"
    (Z.to_smt (h ()) (num (-2.0)) = Some "(- 2)");
  check "smt: var x -> x"
    (Z.to_smt (h ()) (var "x") = Some "x");
  check "smt: x + 3 -> prefix (+ x 3)"
    (Z.to_smt (h ()) (add (var "x") (num 3.0)) = Some "(+ x 3)");
  check "smt: unsupported op (mod) -> None"
    (Z.to_smt (h ()) (modop (var "x") (num 2.0)) = None);
  check "smt: unsupported expr (call) -> None"
    (Z.to_smt (h ()) (call "f" [ var "x" ]) = None);

  (* ── SMT program builder + Unsupported entry ────────────────────────── *)
  (match Z.make_smt_program (add (var "x") (num 1.0)) (add (num 1.0) (var "x")) with
   | None -> check "smt: make_smt_program on arithmetic -> Some" false
   | Some prog ->
       check "smt: program sets QF_NRA" (contains prog "(set-logic QF_NRA)");
       check "smt: program declares x : Real" (contains prog "(declare-const x Real)");
       check "smt: program asserts the negated equation"
         (contains prog "(assert (not (= (+ x 1) (+ 1 x))))"));
  check "smt: make_smt_program on non-arith -> None"
    (Z.make_smt_program (call "f" []) (num 1.0) = None);
  check "smt: check on unsupported expr -> Smt_unsupported (no z3)"
    (match Z.check (call "f" []) (num 1.0) with
     | Z.Smt_unsupported _ -> true | _ -> false);

  (* ── SMT output parsing: parse_z3_result (pure, all four verdicts) ───── *)
  check "smt: parse unsat -> Proven"
    (match Z.parse_z3_result "unsat\n" with Z.Smt_proven -> true | _ -> false);
  check "smt: parse sat + model -> Disproven"
    (match Z.parse_z3_result "sat\n(model (define-fun x () Real 1.0))" with
     | Z.Smt_disproven _ -> true | _ -> false);
  check "smt: parse unknown -> Unknown"
    (match Z.parse_z3_result "unknown\n" with Z.Smt_unknown _ -> true | _ -> false);
  check "smt: parse garbage -> Unknown"
    (match Z.parse_z3_result "gibberish" with Z.Smt_unknown _ -> true | _ -> false);

  Printf.printf "\n%d passed, %d failed\n" !pass !fails;
  if !fails > 0 then exit 1
