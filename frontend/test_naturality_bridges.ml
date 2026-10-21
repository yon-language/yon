(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_naturality_bridges.ml — oracle for the SMT naturality bridge.
 *
 * naturality_smtcheck.ml translates a naturality obligation (LHS = RHS over
 * one input) into an SMT-LIB formula over the values the program computes
 * with — IEEE doubles for Number, 64-bit bitvectors for Int64, constants by
 * their exact bits, identity by bits — then hands it to z3.
 *
 * The TRANSLATION is pure and decidable and gets known-answer coverage here:
 * to_smt / make_smt_program / literal, parse_z3_result, and the Unsupported
 * entry branch (reachable with no external tool). The external invocation
 * (run_z3, via Sys.command) needs z3 on PATH. Each check is two-sided where a
 * reject exists. *)

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
  let module Z = Naturality_smtcheck in
  Printf.printf "=== naturality bridge (smt translation) oracle ===\n\n";

  (* ── literals by their exact bits ──────────────────────────────────── *)
  check "smt f64: 1.0 -> (fp #b0 #b01111111111 #b0...0)"
    (Z.literal Z.F64 1.0 = Some ("(fp #b0 #b01111111111 #b" ^ String.make 52 '0' ^ ")"));
  check "smt f64: -0.0 keeps its sign bit"
    (Z.literal Z.F64 (-0.0) = Some ("(fp #b1 #b00000000000 #b" ^ String.make 52 '0' ^ ")"));
  check "smt f64: 3.14159265 and 3.1415926 are two constants"
    (Z.literal Z.F64 3.14159265 <> Z.literal Z.F64 3.1415926);
  check "smt i64: 5 -> 64-bit two's complement"
    (Z.literal Z.I64 5.0 = Some ("#b" ^ String.make 61 '0' ^ "101"));
  check "smt i64: -1 -> all ones"
    (Z.literal Z.I64 (-1.0) = Some ("#b" ^ String.make 64 '1'));
  check "smt i64: a fraction is not an Int64 -> None"
    (Z.literal Z.I64 2.5 = None);

  (* ── to_smt (pure) ──────────────────────────────────────────────────── *)
  check "smt: var x -> x"
    (Z.to_smt Z.F64 (h ()) (var "x") = Some "x");
  check "smt f64: x + 3 -> (fp.add RNE x <3>)"
    (match Z.to_smt Z.F64 (h ()) (add (var "x") (num 3.0)) with
     | Some s -> contains s "(fp.add RNE x (fp " | None -> false);
  check "smt i64: x * 2 -> (bvmul x <2>)"
    (match Z.to_smt Z.I64 (h ()) (mul (var "x") (num 2.0)) with
     | Some s -> contains s "(bvmul x #b" | None -> false);
  check "smt: unsupported op (mod) -> None"
    (Z.to_smt Z.F64 (h ()) (modop (var "x") (num 2.0)) = None);
  check "smt: unsupported expr (call) -> None"
    (Z.to_smt Z.F64 (h ()) (call "f" [ var "x" ]) = None);

  (* ── SMT program builder + Unsupported entry ────────────────────────── *)
  (match Z.make_smt_program Z.F64 (add (var "x") (num 1.0)) (add (num 1.0) (var "x")) with
   | None -> check "smt: make_smt_program on arithmetic -> Some" false
   | Some prog ->
       check "smt f64: program sets QF_FP" (contains prog "(set-logic QF_FP)");
       check "smt f64: x is an IEEE double"
         (contains prog "(declare-const x (_ FloatingPoint 11 53))");
       check "smt: program asserts the negated equation by identity"
         (contains prog "(assert (not (= (fp.add RNE x ");
       check "smt: no real arithmetic" (not (contains prog "Real")));
  (match Z.make_smt_program Z.I64 (add (var "x") (num 1.0)) (add (num 1.0) (var "x")) with
   | None -> check "smt i64: make_smt_program on arithmetic -> Some" false
   | Some prog ->
       check "smt i64: program sets QF_BV" (contains prog "(set-logic QF_BV)");
       check "smt i64: x is a 64-bit vector" (contains prog "(declare-const x (_ BitVec 64))"));
  check "smt: make_smt_program on non-arith -> None"
    (Z.make_smt_program Z.F64 (call "f" []) (num 1.0) = None);
  check "smt: check on unsupported expr -> Smt_unsupported (no z3)"
    (match Z.check ~carrier:Z.F64 (call "f" []) (num 1.0) with
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
