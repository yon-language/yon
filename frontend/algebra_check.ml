(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* algebra_check.ml — the certification of the laws of an algebra on each of
 * its models.
 *
 * A place that uses an algebra is a model of it: each law of the algebra,
 * stated over the algebra's own name, is read on the place, with the place's
 * funs for the algebra's operations. Each fun is unfolded to the terms of its
 * carrier, and the statement is decided:
 *   - on a finite carrier (a place of nullary arms), by evaluating the
 *     statement at every assignment of arms to its variables;
 *   - on a 64-bit word carried internally (the ring Z/2^64, whose sum and
 *     product wrap), by z3 over 64-bit bitvectors;
 *   - anything else is not decided.
 * The verdict is the one of the declared laws: proven, refuted (with a
 * counterexample), or unknown, which is not certified. *)

module S = Surface_ast

type law_result = {
  lr_place : string;
  lr_algebra : string;
  lr_law : string;
  lr_loc : S.location;
  lr_verdict : Law_check.verdict;
}

exception Not_modelled of string

let places (p : S.program) : (string * S.place_decl) list =
  List.filter_map (function S.TopPlace pd -> Some (pd.S.pd_name, pd) | _ -> None) p

(* The funs of a house, by their name in it. *)
let house_funs (p : S.program) (house : string) : (string * S.fun_decl) list =
  let prefix = house ^ "__" in
  let lp = String.length prefix in
  List.filter_map (function
    | S.TopFun fd when fd.S.fn_home = Some house -> Some (fd.S.fn_name, fd)
    | S.TopFun fd when String.length fd.S.fn_name > lp
                       && String.sub fd.S.fn_name 0 lp = prefix ->
        Some (String.sub fd.S.fn_name lp (String.length fd.S.fn_name - lp), fd)
    | _ -> None) p

(* The single expression a fun returns, when its body is one. *)
let returned (fd : S.fun_decl) : S.expr option =
  match fd.S.fn_body with
  | [S.SReturn (e, _)] -> Some e
  | _ -> None

let rec subst (env : (string * S.expr) list) (e : S.expr) : S.expr =
  let s = subst env in
  match e with
  | S.EVar (x, _) -> (match List.assoc_opt x env with Some v -> v | None -> e)
  | S.EParen (a, l) -> S.EParen (s a, l)
  | S.EBinop (o, a, b, l) -> S.EBinop (o, s a, s b, l)
  | S.ECall (f, args, l) -> S.ECall (f, List.map s args, l)
  | S.EIfThenElse (c, a, b, l) -> S.EIfThenElse (s c, s a, s b, l)
  | S.ENot (a, l) -> S.ENot (s a, l)
  | S.EHITElim (m, branches, x, l) ->
      S.EHITElim (m, List.map (fun (c, pat, b) -> (c, pat, s b)) branches, s x, l)
  | _ -> e

(* The statement on the model: the algebra's operators and operations become
   the house's funs, and every fun of the house is unfolded to its body,
   until only the carrier's own terms remain. *)
let unfold (algebra_ops : S.operation_decl list) (funs : (string * S.fun_decl) list)
    (e : S.expr) : S.expr =
  let sym_of = function
    | S.OpAdd -> Some "+" | S.OpSub -> Some "-" | S.OpMul -> Some "*"
    | S.OpDiv -> Some "/" | S.OpMod -> Some "%" | _ -> None in
  let rec go depth e =
    if depth > 32 then raise (Not_modelled "a fun of the house that does not unfold");
    let g = go depth in
    match e with
    | S.EParen (a, _) -> g a
    | S.EBinop (o, a, b, l) ->
        (match sym_of o with
         | Some sym when List.exists (fun (op : S.operation_decl) -> op.S.op_symbol = Some sym) algebra_ops
                         && depth = 0 ->
             let op = List.find (fun (op : S.operation_decl) -> op.S.op_symbol = Some sym) algebra_ops in
             g (S.ECall (op.S.op_name, [a; b], l))
         | _ -> S.EBinop (o, g a, g b, l))
    | S.ECall (f, args, l) ->
        let short = match String.rindex_opt f '_' with
          | Some i when i > 0 && f.[i - 1] = '_' -> String.sub f (i + 1) (String.length f - i - 1)
          | _ -> f in
        (match List.assoc_opt short funs with
         | Some fd ->
             (match returned fd with
              | Some body ->
                  let env = List.map2 (fun (p : S.param) a -> (p.S.param_name, g a))
                      fd.S.fn_params args in
                  go (depth + 1) (subst env body)
              | None -> raise (Not_modelled ("fun " ^ short ^ ", whose body is not one returned value")))
         | None ->
             (match f with
              | "__heyt_and" | "__heyt_or" | "__heyt_imp" | "__heyt_not" ->
                  S.ECall (f, List.map g args, l)
              | _ -> raise (Not_modelled ("a call of " ^ f))))
    | S.EIfThenElse (c, a, b, l) -> S.EIfThenElse (g c, g a, g b, l)
    | S.ENot (a, l) -> S.ENot (g a, l)
    | S.EHITElim (m, branches, x, l) ->
        S.EHITElim (m, List.map (fun (c, pat, b) -> (c, pat, g b)) branches, g x, l)
    | S.EVar _ | S.ELit _ -> e
    | _ -> raise (Not_modelled "a form outside the modelled fragment")
  in
  go 0 e

(* ─── a finite carrier: every assignment of arms ─────────────────────── *)

type value = Arm of string | Truth of bool

let rec eval (arms : string list) (env : (string * value) list) (e : S.expr) : value =
  let ev = eval arms env in
  let truth e = match ev e with Truth b -> b | Arm _ -> raise (Not_modelled "an arm where a truth was due") in
  match e with
  | S.EVar (x, _) ->
      (match List.assoc_opt x env with
       | Some v -> v
       | None when List.mem x arms -> Arm x
       | None -> raise (Not_modelled ("the name " ^ x)))
  | S.ELit (S.LitBool b, _) -> Truth b
  | S.EBinop (S.OpEq, a, b, _) -> Truth (ev a = ev b)
  | S.EBinop (S.OpNeq, a, b, _) -> Truth (ev a <> ev b)
  | S.EBinop (S.OpAnd, a, b, _) -> Truth (truth a && truth b)
  | S.EBinop (S.OpOr, a, b, _) -> Truth (truth a || truth b)
  | S.ENot (a, _) -> Truth (not (truth a))
  | S.ECall ("__heyt_and", [a; b], _) -> Truth (truth a && truth b)
  | S.ECall ("__heyt_or", [a; b], _) -> Truth (truth a || truth b)
  | S.ECall ("__heyt_imp", [a; b], _) -> Truth ((not (truth a)) || truth b)
  | S.ECall ("__heyt_not", [a], _) -> Truth (not (truth a))
  | S.EIfThenElse (c, a, b, _) -> if truth c then ev a else ev b
  | S.EHITElim (S.EVar ("__match", _), branches, x, _) ->
      (match ev x with
       | Arm a ->
           (match List.find_opt (fun (c, _, _) -> c = a || c = "_") branches with
            | Some (_, _, b) -> ev b
            | None -> raise (Not_modelled "a match without the arm"))
       | Truth _ -> raise (Not_modelled "a match on a truth"))
  | _ -> raise (Not_modelled "a form outside the modelled fragment")

let decide_finite (arms : string list) (st : S.law_statement) (body : S.expr) : Law_check.verdict =
  let rec all qs env =
    match qs with
    | [] -> (match eval arms env body with Truth b -> Ok b
                                          | Arm _ -> raise (Not_modelled "a statement that is no truth"))
    | (q, x) :: rest ->
        let results = List.map (fun a -> (a, all rest ((x, Arm a) :: env))) arms in
        (match q with
         | S.Forall ->
             (match List.find_opt (fun (_, r) -> r <> Ok true) results with
              | None -> Ok true
              | Some (a, Ok false) -> Error (Printf.sprintf "%s = %s" x a)
              | Some (a, Error w) -> Error (Printf.sprintf "%s = %s, %s" x a w)
              | Some (_, Ok true) -> Ok true)
         | S.Exists ->
             if List.exists (fun (_, r) -> r = Ok true) results then Ok true
             else Error (Printf.sprintf "no %s makes it true" x))
  in
  match all st.S.ls_quants [] with
  | Ok true -> Law_check.Proven (Printf.sprintf "every assignment of the %d arms" (List.length arms))
  | Ok false -> Law_check.Refuted "the statement is false"
  | Error w -> Law_check.Refuted w

(* ─── a 64-bit word: z3 over bitvectors ──────────────────────────────── *)

let bv_literal (f : float) : string =
  Printf.sprintf "(_ bv%Lu 64)" (Int64.of_float f)

let rec to_bv (e : S.expr) : string =
  match e with
  | S.EVar (x, _) -> "|" ^ x ^ "|"
  | S.ELit (S.LitNumber n, _) when Float.is_integer n ->
      if n >= 0. then bv_literal n else Printf.sprintf "(bvneg %s)" (bv_literal (-. n))
  | S.EBinop (S.OpAdd, a, b, _) -> Printf.sprintf "(bvadd %s %s)" (to_bv a) (to_bv b)
  | S.EBinop (S.OpSub, a, b, _) -> Printf.sprintf "(bvsub %s %s)" (to_bv a) (to_bv b)
  | S.EBinop (S.OpMul, a, b, _) -> Printf.sprintf "(bvmul %s %s)" (to_bv a) (to_bv b)
  | S.EIfThenElse (c, a, b, _) -> Printf.sprintf "(ite %s %s %s)" (to_prop c) (to_bv a) (to_bv b)
  | _ -> raise (Not_modelled "a term outside the bitvector fragment")

and to_prop (e : S.expr) : string =
  match e with
  | S.EBinop (S.OpEq, a, b, _) -> Printf.sprintf "(= %s %s)" (to_bv a) (to_bv b)
  | S.EBinop (S.OpNeq, a, b, _) -> Printf.sprintf "(not (= %s %s))" (to_bv a) (to_bv b)
  | S.EBinop (S.OpLt, a, b, _) -> Printf.sprintf "(bvslt %s %s)" (to_bv a) (to_bv b)
  | S.EBinop (S.OpGt, a, b, _) -> Printf.sprintf "(bvsgt %s %s)" (to_bv a) (to_bv b)
  | S.EBinop (S.OpLeq, a, b, _) -> Printf.sprintf "(bvsle %s %s)" (to_bv a) (to_bv b)
  | S.EBinop (S.OpGeq, a, b, _) -> Printf.sprintf "(bvsge %s %s)" (to_bv a) (to_bv b)
  | S.EBinop (S.OpAnd, a, b, _) | S.ECall ("__heyt_and", [a; b], _) ->
      Printf.sprintf "(and %s %s)" (to_prop a) (to_prop b)
  | S.EBinop (S.OpOr, a, b, _) | S.ECall ("__heyt_or", [a; b], _) ->
      Printf.sprintf "(or %s %s)" (to_prop a) (to_prop b)
  | S.ECall ("__heyt_imp", [a; b], _) -> Printf.sprintf "(=> %s %s)" (to_prop a) (to_prop b)
  | S.ENot (a, _) | S.ECall ("__heyt_not", [a], _) -> Printf.sprintf "(not %s)" (to_prop a)
  | S.EParen (a, _) -> to_prop a
  | _ -> raise (Not_modelled "a proposition outside the bitvector fragment")

let decide_word (st : S.law_statement) (body : S.expr) : Law_check.verdict =
  let formula =
    List.fold_right (fun (q, x) acc ->
      Printf.sprintf "(%s ((|%s| (_ BitVec 64))) %s)"
        (match q with S.Forall -> "forall" | S.Exists -> "exists") x acc)
      st.S.ls_quants (to_prop body) in
  let program = Printf.sprintf "(assert (not %s))\n(check-sat)\n" formula in
  if not (Law_check.z3_available ()) then Law_check.Unknown "z3 is not installed"
  else
    match Naturality_smtcheck.run_z3 program with
    | Error e -> Law_check.Unknown e
    | Ok out ->
        (match String.trim (List.hd (String.split_on_char '\n' out)) with
         | "unsat" -> Law_check.Proven "z3, over 64-bit words"
         | "sat" -> Law_check.Refuted "z3 finds 64-bit words where it is false"
         | r -> Law_check.Unknown ("z3 answers " ^ r))

(* ─── the models of the program ──────────────────────────────────────── *)

let check (p : S.program) : law_result list =
  let ps = places p in
  List.concat_map (fun (pname, (pd : S.place_decl)) ->
    let algebras = match Hashtbl.find_opt S.place_algebras pname with Some l -> l | None -> [] in
    let funs = house_funs p pname in
    List.concat_map (fun a ->
      match List.assoc_opt a ps with
      | Some apd when Hashtbl.mem S.algebra_places a ->
          let ops = List.filter_map (function S.FoOp o -> Some o | _ -> None) apd.S.pd_members in
          (* a model that does not give every operation is refused by the
             checker of models; its laws are not read on it *)
          if not (List.for_all (fun (o : S.operation_decl) -> List.mem_assoc o.S.op_name funs) ops)
          then [] else
          List.filter_map (function
            | S.FoLaw (law, Some st) ->
                let verdict =
                  try
                    let body = unfold ops funs st.S.ls_body in
                    let nullary = pd.S.pd_arms <> []
                      && List.for_all (fun (v : S.variant) -> v.S.v_args = []) pd.S.pd_arms in
                    if nullary && pd.S.pd_fusion = None then
                      decide_finite (List.map (fun (v : S.variant) -> v.S.v_name) pd.S.pd_arms) st body
                    else if pd.S.pd_fusion = Some "i64"
                            && Hashtbl.mem S.internal_carrier_sites
                                 (pd.S.pd_loc.S.file, pd.S.pd_loc.S.start_line,
                                  pd.S.pd_loc.S.start_col) then
                      decide_word st body
                    else
                      Law_check.Unknown (Printf.sprintf
                        "%s is neither a finite place of arms nor a 64-bit word carried internally"
                        pname)
                  with Not_modelled why -> Law_check.Unknown ("the statement on " ^ pname ^ " contains " ^ why)
                in
                Some { lr_place = pname; lr_algebra = a; lr_law = law;
                       lr_loc = pd.S.pd_loc; lr_verdict = verdict }
            | _ -> None) apd.S.pd_members
      | _ -> []) algebras) ps
