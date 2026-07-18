(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* naturality_coqcheck.ml
 *
 * Formal proof via Coq.
 *
 * Strategy: for each nat_transform eta : F => G with arithmetic LHS/RHS
 * (extracted and normalized by the symbolic checker), generate a Coq .v file:
 *
 *   Require Import Reals.
 *   Open Scope R_scope.
 *
 *   Theorem naturality_<NT>_<N> : forall x : R, <LHS> = <RHS>.
 *   Proof. intros. ring. Qed.
 *
 * We invoke coqc; if the proof is type-checked by the Coq kernel:
 * PROVEN_BY_COQ — a formal guarantee.
 *
 * Qualitative difference from the Z3 backend:
 *   - via Z3: a decision procedure, internally uncertified
 *   - via Coq: a proof object, certified by the Coq kernel
 *
 * Honest upfront about what it does and does not do:
 *
 *   + Polynomial arithmetic closed by the `ring` tactic
 *   + Distributivity, commutativity, associativity, squared binomials
 *   + A proof object certified by the kernel
 *
 *   - Not transcendental arithmetic (sqrt, log, exp): `ring` does not close
 *   - Only pure mono-parameter funs (single-variable theorems)
 *   - If `ring` does not close, emits the .v file as a "handoff" for a manual
 *     proof or more powerful tactics (lra, field, nra), left to future
 *     extensions
 *   - Coq must be installed on the system
 *
 * Output: a .v file written to /tmp/yon_coq_<NT>_<N>.v, plus a stderr info
 * message PROVEN_BY_COQ / HANDOFF_<file>.v. *)

module S = Surface_ast

type coq_result =
  | Coq_proven of string             (* file .v compilato OK *)
  | Coq_handoff of string * string   (* file .v, ragione di fallback *)
  | Coq_unsupported of string

(* Translate a Surface expr to Coq Real arithmetic syntax. Supports only:
 *   - LitNumber: as `IZR n` for integers, `(IZR n / IZR d)` for rationals when
 *                possible, otherwise a notation literal
 *   - EVar: variable name
 *   - EBinop +, -, *, /
 *
 * The free variables are collected into a set; they are introduced by the
 * Coq `forall`. *)
let rec to_coq (vars : (string, unit) Hashtbl.t) (e : S.expr) : string option =
  match e with
  | S.ELit (S.LitNumber n, _) ->
      (* Coq Reals: for small integers use IZR; for floats, check whether they
       * are integral and if so use (k%R). Honest limit: for non-integer
       * literals, Coq may not normalize them with `ring`. *)
      if Float.is_integer n && Float.abs n < 1e9 then
        let i = int_of_float n in
        if i >= 0 then Some (Printf.sprintf "(%d)%%R" i)
        else Some (Printf.sprintf "(- %d)%%R" (-i))
      else
        (* A generic real: pass it as a string; ring will not close it, but we
         * generate the file anyway *)
        Some (Printf.sprintf "(%g)%%R" n)
  | S.EVar (name, _) ->
      Hashtbl.replace vars name ();
      Some name
  | S.EParen (inner, _) -> to_coq vars inner
  | S.EBinop (op, l, r, _) ->
      let coq_op = match op with
        | S.OpAdd -> Some "+"
        | S.OpSub -> Some "-"
        | S.OpMul -> Some "*"
        | S.OpDiv -> Some "/"
        | _ -> None
      in
      (match coq_op with
       | None -> None
       | Some opstr ->
           (match to_coq vars l, to_coq vars r with
            | Some ls, Some rs ->
                Some (Printf.sprintf "(%s %s %s)" ls opstr rs)
            | _ -> None))
  | _ -> None

(* Build the complete Coq program. *)
let make_coq_program (theorem_name : string) (lhs : S.expr) (rhs : S.expr) : string option =
  let vars = Hashtbl.create 4 in
  match to_coq vars lhs, to_coq vars rhs with
  | Some lhs_coq, Some rhs_coq ->
      let var_list = Hashtbl.fold (fun n () acc -> n :: acc) vars [] in
      let forall_clause = match var_list with
        | [] -> ""
        | vs -> Printf.sprintf "forall %s : R, "
                  (String.concat " " vs) in
      let program =
        "Require Import Reals.\n"
        ^ "Open Scope R_scope.\n\n"
        ^ Printf.sprintf "Theorem %s : %s%s = %s.\n"
            theorem_name forall_clause lhs_coq rhs_coq
        ^ "Proof. intros. ring. Qed.\n"
      in
      Some program
  | _ -> None

(* Invoke coqc on a file. Returns (rc, output). *)
let run_coqc (filename : string) : int * string =
  let tmp_out = Filename.temp_file "yon_coq_" ".out" in
  let cmd = Printf.sprintf "coqc %s > %s 2>&1"
              (Filename.quote filename) (Filename.quote tmp_out) in
  let rc = Sys.command cmd in
  let ic = open_in tmp_out in
  let buf = Buffer.create 256 in
  (try
    while true do Buffer.add_channel buf ic 4096 done
  with End_of_file -> ());
  close_in ic;
  Sys.remove tmp_out;
  (rc, Buffer.contents buf)

let check ~theorem_name (lhs : S.expr) (rhs : S.expr) : coq_result =
  match make_coq_program theorem_name lhs rhs with
  | None -> Coq_unsupported "expr outside the Coq arithmetic subset"
  | Some program ->
      let filename = Printf.sprintf "/tmp/yon_coq_%s.v" theorem_name in
      let oc = open_out filename in
      output_string oc program;
      close_out oc;
      let (rc, output) = run_coqc filename in
      if rc = 0 then Coq_proven filename
      else
        Coq_handoff (filename,
          Printf.sprintf "coqc exit %d (likely: `ring` tactic insufficient). Output: %s"
            rc (String.trim output))
