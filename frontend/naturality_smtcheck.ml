(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* naturality_smtcheck.ml
 *
 * SMT-backed verification of a naturality square via Z3. Given LHS and RHS
 * (already inlined by the symbolic checker, over one variable `input`), Z3 is
 * asked whether some input makes them differ:
 *
 *   (assert (not (= <LHS> <RHS>)))   (check-sat)
 *
 *   unsat   -> the sides agree on every input: proven
 *   sat     -> an input where they differ: refuted, with Z3's model
 *   unknown -> not decided
 *
 * The values are the ones the program computes with, never an idealization:
 *   - Number is an IEEE double, (_ FloatingPoint 11 53), with +, -, *, /
 *     rounded to nearest-even, as the runtime computes them;
 *   - Int64 is a 64-bit two's-complement integer, (_ BitVec 64), with +, -, *
 *     wrapping; division is left out (it is not total);
 * and two values are the same iff they have the same bits: SMT-LIB `=`,
 * the identity the runtime uses (NaN is one value, +0 and -0 are two). A
 * constant is given by its exact bits, never by a decimal rendering. *)

module S = Surface_ast

type carrier = F64 | I64

type smt_result =
  | Smt_proven                    (* Z3 returns unsat on LHS != RHS *)
  | Smt_disproven of string       (* Z3 returns sat; the string is the counterexample model *)
  | Smt_unknown of string         (* Z3 timeout or does not decide *)
  | Smt_unsupported of string     (* expr not translatable to SMT *)

let sort = function
  | F64 -> "(_ FloatingPoint 11 53)"
  | I64 -> "(_ BitVec 64)"

let bits (n : Int64.t) (width : int) (from : int) : string =
  String.init width (fun i ->
    if Int64.logand (Int64.shift_right_logical n (from - 1 - i)) 1L = 1L then '1' else '0')

(* A literal at its carrier, by its exact bits. *)
let literal (carrier : carrier) (f : float) : string option =
  match carrier with
  | F64 ->
      let b = Int64.bits_of_float f in
      Some (Printf.sprintf "(fp #b%s #b%s #b%s)"
              (bits b 1 64) (bits (Int64.shift_left b 1) 11 64)
              (bits (Int64.shift_left b 12) 52 64))
  | I64 ->
      if Float.is_integer f && f >= -9.223372036854775808e18 && f < 9.223372036854775808e18
      then Some (Printf.sprintf "#b%s" (bits (Int64.of_float f) 64 64))
      else None

let rec to_smt (carrier : carrier) (vars : (string, unit) Hashtbl.t) (e : S.expr)
    : string option =
  match e with
  | S.ELit (S.LitNumber n, _) -> literal carrier n
  | S.EVar (name, _) ->
      Hashtbl.replace vars name ();
      Some name
  | S.EParen (inner, _) -> to_smt carrier vars inner
  | S.EBinop (op, l, r, _) ->
      let smt_op = match carrier, op with
        | F64, S.OpAdd -> Some "fp.add RNE" | F64, S.OpSub -> Some "fp.sub RNE"
        | F64, S.OpMul -> Some "fp.mul RNE" | F64, S.OpDiv -> Some "fp.div RNE"
        | I64, S.OpAdd -> Some "bvadd" | I64, S.OpSub -> Some "bvsub"
        | I64, S.OpMul -> Some "bvmul"
        | _ -> None in
      (match smt_op, to_smt carrier vars l, to_smt carrier vars r with
       | Some o, Some ls, Some rs -> Some (Printf.sprintf "(%s %s %s)" o ls rs)
       | _ -> None)
  | _ -> None

(* The SMT-LIB program: the variables at their sort, the negated equality,
   check-sat, the model. *)
let make_smt_program (carrier : carrier) (lhs : S.expr) (rhs : S.expr) : string option =
  let vars = Hashtbl.create 4 in
  match to_smt carrier vars lhs, to_smt carrier vars rhs with
  | Some lhs_smt, Some rhs_smt ->
      let decls = Hashtbl.fold
        (fun name () acc ->
          Printf.sprintf "(declare-const %s %s)\n" name (sort carrier) :: acc)
        vars [] in
      Some ((match carrier with F64 -> "(set-logic QF_FP)\n" | I64 -> "(set-logic QF_BV)\n")
            ^ String.concat "" decls
            ^ Printf.sprintf "(assert (not (= %s %s)))\n" lhs_smt rhs_smt
            ^ "(check-sat)\n(get-model)\n")
  | _ -> None

(* Run z3 with the formula on stdin, return stdout. 5s timeout. *)
let run_z3 (smt_program : string) : (string, string) result =
  let tmp_in = Filename.temp_file "yon_smt_" ".smt2" in
  let oc = open_out tmp_in in
  output_string oc smt_program;
  close_out oc;
  let tmp_out = Filename.temp_file "yon_smt_" ".out" in
  let cmd = Printf.sprintf "z3 -smt2 -T:5 %s > %s 2>&1"
              (Filename.quote tmp_in) (Filename.quote tmp_out) in
  let rc = Sys.command cmd in
  let ic = open_in tmp_out in
  let buf = Buffer.create 256 in
  (try
    while true do Buffer.add_channel buf ic 4096 done
  with End_of_file -> ());
  close_in ic;
  Sys.remove tmp_in;
  Sys.remove tmp_out;
  let output = Buffer.contents buf in
  if rc <> 0 && rc <> 1 then  (* z3 returns 1 with sat in some modes *)
    Error (Printf.sprintf "z3 exit %d: %s" rc output)
  else
    Ok output

(* Parse z3 output: the first line is "sat", "unsat", or "unknown". *)
let parse_z3_result (output : string) : smt_result =
  let lines = String.split_on_char '\n' output in
  let first = match lines with
    | l :: _ -> String.trim l
    | [] -> "" in
  match first with
  | "unsat" -> Smt_proven
  | "sat" ->
      (* Extract the model (the lines after "sat") *)
      let model_lines = match lines with
        | _ :: rest -> rest
        | [] -> [] in
      let model = String.concat " " model_lines in
      Smt_disproven (String.trim model)
  | "unknown" -> Smt_unknown "z3 returned unknown"
  | _ -> Smt_unknown (Printf.sprintf "z3 output: %s" first)

(* MAIN entry point: given LHS and RHS, decide via Z3. *)
let check ~(carrier : carrier) (lhs : S.expr) (rhs : S.expr) : smt_result =
  match make_smt_program carrier lhs rhs with
  | None -> Smt_unsupported "expr contains constructs outside the SMT arithmetic subset"
  | Some program ->
      (match run_z3 program with
       | Error msg -> Smt_unknown ("z3 invocation failed: " ^ msg)
       | Ok output -> parse_z3_result output)
