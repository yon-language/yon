(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* naturality_smtcheck.ml
 *
 * SMT-backed verification of naturality via Z3.
 *
 * Strategy: given LHS = eta(F__N(x)) and RHS = G__N(eta(x)) as surface AST
 * terms (already inlined by the symbolic checker), generate an SMT-LIB
 * formula:
 *
 *   (declare-const x Real)
 *   (assert (not (= <LHS_smt> <RHS_smt>)))
 *   (check-sat)
 *
 * - unsat   -> LHS = RHS for all x: PROVEN
 * - sat     -> there is an x with LHS != RHS: DISPROVEN (Z3 can give a model)
 * - unknown -> the solver does not decide
 *
 * Honest upfront about what it does and does not do:
 *
 *   + Distributivity: 2*(x+3) = 2*x+6 -> UNSAT on (LHS!=RHS) -> PROVEN
 *   + Linear and non-linear rational arithmetic: x*x != x*x+1
 *   + Concrete counterexamples on DISPROVEN
 *
 *   - Only arithmetic expressions (Real). No control flow, no strings, no
 *     complex booleans, no recursion.
 *   - Z3 timeout fixed at 5 seconds
 *   - Only pure mono-parameter funs (we reuse the symbolic checker inlining)
 *   - unknown from Z3 = INCONCLUSIVE (not a disproof)
 *
 * Output: stderr info messages PROVEN / DISPROVEN_BY_SMT(model) / UNKNOWN. *)

module S = Surface_ast

type smt_result =
  | Smt_proven                    (* Z3 returns unsat on LHS != RHS *)
  | Smt_disproven of string       (* Z3 returns sat; the string is the counterexample model *)
  | Smt_unknown of string         (* Z3 timeout or does not decide *)
  | Smt_unsupported of string     (* expr not translatable to SMT *)

(* Translate a Surface expr to an SMT-LIB string. Supports only:
 *   - LitNumber (Real literal)
 *   - EVar (variable, declared as Real)
 *   - EBinop (+, -, *, /)
 *   - EParen
 *
 * Returns Some smt_str if translatable, None otherwise.
 *
 * The free variables are collected into a set for declare-const. *)
let rec to_smt (vars : (string, unit) Hashtbl.t) (e : S.expr) : string option =
  match e with
  | S.ELit (S.LitNumber n, _) ->
      (* Z3 SMT-LIB: numbers negativi richiedono parentesi extra *)
      if n < 0.0 then Some (Printf.sprintf "(- %g)" (-. n))
      else Some (Printf.sprintf "%g" n)
  | S.EVar (name, _) ->
      Hashtbl.replace vars name ();
      Some name
  | S.EParen (inner, _) -> to_smt vars inner
  | S.EBinop (op, l, r, _) ->
      let smt_op = match op with
        | S.OpAdd -> Some "+"
        | S.OpSub -> Some "-"
        | S.OpMul -> Some "*"
        | S.OpDiv -> Some "/"
        | _ -> None  (* mod, lt/gt/eq/and/or not in the arithmetic subset *)
      in
      (match smt_op with
       | None -> None
       | Some opstr ->
           (match to_smt vars l, to_smt vars r with
            | Some ls, Some rs ->
                Some (Printf.sprintf "(%s %s %s)" opstr ls rs)
            | _ -> None))
  | _ -> None

(* Generate the SMT-LIB program: declare-const for all variables, assert
 * (not (= LHS RHS)), check-sat, optional get-model. *)
let make_smt_program (lhs : S.expr) (rhs : S.expr) : string option =
  let vars = Hashtbl.create 4 in
  match to_smt vars lhs, to_smt vars rhs with
  | Some lhs_smt, Some rhs_smt ->
      let decls = Hashtbl.fold
        (fun name () acc ->
          Printf.sprintf "(declare-const %s Real)\n" name :: acc)
        vars [] in
      let program =
        "(set-logic QF_NRA)\n"   (* nonlinear real arithmetic *)
        ^ String.concat "" decls
        ^ Printf.sprintf "(assert (not (= %s %s)))\n" lhs_smt rhs_smt
        ^ "(check-sat)\n"
        ^ "(get-model)\n"
      in
      Some program
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
let check (lhs : S.expr) (rhs : S.expr) : smt_result =
  match make_smt_program lhs rhs with
  | None -> Smt_unsupported "expr contains constructs outside the SMT arithmetic subset"
  | Some program ->
      (match run_z3 program with
       | Error msg -> Smt_unknown ("z3 invocation failed: " ^ msg)
       | Ok output -> parse_z3_result output)
