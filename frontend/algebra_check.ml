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
  lr_given : bool;            (* the model is declared an axiom (`is given`) *)
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
let short_name (f : string) : string =
  match String.rindex_opt f '_' with
  | Some i when i > 0 && f.[i - 1] = '_' -> String.sub f (i + 1) (String.length f - i - 1)
  | _ -> f

(* The funs of a house as a resolver: a call of one of them is its body, with
   the arguments for the parameters. *)
let house_resolver (funs : (string * S.fun_decl) list) (f : string) (args : S.expr list)
    : S.expr option =
  match List.assoc_opt (short_name f) funs with
  | Some fd ->
      (match returned fd with
       | Some body when List.length fd.S.fn_params = List.length args ->
           Some (subst (List.map2 (fun (p : S.param) a -> (p.S.param_name, a)) fd.S.fn_params args) body)
       | _ -> raise (Not_modelled ("fun " ^ short_name f ^ ", whose body is not one returned value")))
  | None -> None

(* The statement on the model: the algebra's operators become its
   operations, and each call is replaced by what the resolver gives for it,
   until only the carrier's own terms remain. *)
let unfold (algebra_ops : S.operation_decl list)
    (resolve : string -> S.expr list -> S.expr option) (e : S.expr) : S.expr =
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
         | Some sym when depth = 0
                         && List.exists (fun (op : S.operation_decl) -> op.S.op_symbol = Some sym) algebra_ops ->
             let op = List.find (fun (op : S.operation_decl) -> op.S.op_symbol = Some sym) algebra_ops in
             g (S.ECall (op.S.op_name, [a; b], l))
         | _ -> S.EBinop (o, g a, g b, l))
    | S.ECall (("__heyt_and" | "__heyt_or" | "__heyt_imp" | "__heyt_not") as f, args, l) ->
        S.ECall (f, List.map g args, l)
    | S.ECall (f, args, _) ->
        let args = List.map g args in
        (match resolve f args with
         | Some body -> go (depth + 1) body
         | None -> raise (Not_modelled ("a call of " ^ f)))
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
  match all (List.map (fun (q, x, _) -> (q, x)) st.S.ls_quants) [] with
  | Ok true -> Law_check.Proven (Printf.sprintf "every assignment of the %d arms" (List.length arms))
  | Ok false -> Law_check.Refuted "the statement is false"
  | Error w -> Law_check.Refuted w

(* ─── a machine carrier: z3 over its values ──────────────────────────── *)

(* The machine values the solver models: a 64-bit two's-complement word,
   whose sum and product wrap, and an IEEE double, rounded to nearest-even;
   two values are the same iff they have the same bits. *)
type machine = Word | Double

let machine_of_carrier = function
  | "i64" -> Some Word
  | "f64" -> Some Double
  | _ -> None

let sort = function Word -> "(_ BitVec 64)" | Double -> "(_ FloatingPoint 11 53)"

let rec to_term (m : machine) (e : S.expr) : string =
  let t = to_term m in
  match m, e with
  | _, S.EVar (x, _) -> "|" ^ x ^ "|"
  | _, S.EParen (a, _) -> t a
  | Word, S.ELit (S.LitNumber n, _) when Float.is_integer n ->
      if n >= 0. then Printf.sprintf "(_ bv%Lu 64)" (Int64.of_float n)
      else Printf.sprintf "(bvneg (_ bv%Lu 64))" (Int64.of_float (-. n))
  | Double, S.ELit (S.LitNumber n, _) ->
      (match Naturality_smtcheck.literal Naturality_smtcheck.F64 n with
       | Some l -> l | None -> raise (Not_modelled "a literal"))
  | Word, S.EBinop (S.OpAdd, a, b, _) -> Printf.sprintf "(bvadd %s %s)" (t a) (t b)
  | Word, S.EBinop (S.OpSub, a, b, _) -> Printf.sprintf "(bvsub %s %s)" (t a) (t b)
  | Word, S.EBinop (S.OpMul, a, b, _) -> Printf.sprintf "(bvmul %s %s)" (t a) (t b)
  | Double, S.EBinop (S.OpAdd, a, b, _) -> Printf.sprintf "(fp.add RNE %s %s)" (t a) (t b)
  | Double, S.EBinop (S.OpSub, a, b, _) -> Printf.sprintf "(fp.sub RNE %s %s)" (t a) (t b)
  | Double, S.EBinop (S.OpMul, a, b, _) -> Printf.sprintf "(fp.mul RNE %s %s)" (t a) (t b)
  | _, S.EIfThenElse (c, a, b, _) -> Printf.sprintf "(ite %s %s %s)" (to_prop m c) (t a) (t b)
  | _ -> raise (Not_modelled "a term outside the machine fragment")

and to_prop (m : machine) (e : S.expr) : string =
  let t = to_term m and p = to_prop m in
  let cmp w d a b = Printf.sprintf "(%s %s %s)" (match m with Word -> w | Double -> d) (t a) (t b) in
  match e with
  | S.EBinop (S.OpEq, a, b, _) -> Printf.sprintf "(= %s %s)" (t a) (t b)
  | S.EBinop (S.OpNeq, a, b, _) -> Printf.sprintf "(not (= %s %s))" (t a) (t b)
  | S.EBinop (S.OpLt, a, b, _) -> cmp "bvslt" "fp.lt" a b
  | S.EBinop (S.OpGt, a, b, _) -> cmp "bvsgt" "fp.gt" a b
  | S.EBinop (S.OpLeq, a, b, _) -> cmp "bvsle" "fp.leq" a b
  | S.EBinop (S.OpGeq, a, b, _) -> cmp "bvsge" "fp.geq" a b
  | S.EBinop (S.OpAnd, a, b, _) | S.ECall ("__heyt_and", [a; b], _) ->
      Printf.sprintf "(and %s %s)" (p a) (p b)
  | S.EBinop (S.OpOr, a, b, _) | S.ECall ("__heyt_or", [a; b], _) ->
      Printf.sprintf "(or %s %s)" (p a) (p b)
  | S.ECall ("__heyt_imp", [a; b], _) -> Printf.sprintf "(=> %s %s)" (p a) (p b)
  | S.ENot (a, _) | S.ECall ("__heyt_not", [a], _) -> Printf.sprintf "(not %s)" (p a)
  | S.EParen (a, _) -> p a
  | _ -> raise (Not_modelled "a proposition outside the machine fragment")

(* The first line of z3's model of a variable, `x = value`, for the
   counterexample. *)
let model_of (out : string) : string =
  let flat = String.concat " " (List.map String.trim (String.split_on_char '\n' out)) in
  match String.index_opt flat '(' with
  | Some i -> String.sub flat i (String.length flat - i)
  | None -> flat

(* ─── the machine's own arithmetic, on fixed candidates ───────────────── *)

(* A value of the machine: a word, or a double, compared by its bits. *)
type mvalue = W of int64 | D of float

let candidates = function
  | Word -> List.map (fun x -> W x)
              [0L; 1L; -1L; 2L; Int64.max_int; Int64.min_int; 4294967296L; 3L]
  | Double -> List.map (fun x -> D x)
                [0.0; -0.0; 1.0; -1.0; 0.1; 0.2; 0.3; 1e16; 1e308; nan; infinity]

let rec mterm (env : (string * mvalue) list) (e : S.expr) : mvalue =
  let t = mterm env in
  match e with
  | S.EVar (x, _) -> (match List.assoc_opt x env with Some v -> v | None -> raise (Not_modelled x))
  | S.EParen (a, _) -> t a
  | S.ELit (S.LitNumber n, _) ->
      (match env with (_, D _) :: _ -> D n | _ -> W (Int64.of_float n))
  | S.EBinop (o, a, b, _) ->
      (match o, t a, t b with
       | S.OpAdd, W x, W y -> W (Int64.add x y)
       | S.OpSub, W x, W y -> W (Int64.sub x y)
       | S.OpMul, W x, W y -> W (Int64.mul x y)
       | S.OpAdd, D x, D y -> D (x +. y)
       | S.OpSub, D x, D y -> D (x -. y)
       | S.OpMul, D x, D y -> D (x *. y)
       | _ -> raise (Not_modelled "a term outside the machine fragment"))
  | S.EIfThenElse (c, a, b, _) -> if mprop env c then t a else t b
  | _ -> raise (Not_modelled "a term outside the machine fragment")

and mprop (env : (string * mvalue) list) (e : S.expr) : bool =
  let same a b = match a, b with
    | W x, W y -> Int64.equal x y
    (* the same value iff the same bits; every NaN is the one NaN *)
    | D x, D y -> (Float.is_nan x && Float.is_nan y) || Int64.equal (Int64.bits_of_float x) (Int64.bits_of_float y)
    | _ -> false in
  let p = mprop env in
  match e with
  | S.EBinop (S.OpEq, a, b, _) -> same (mterm env a) (mterm env b)
  | S.EBinop (S.OpNeq, a, b, _) -> not (same (mterm env a) (mterm env b))
  | S.EBinop (S.OpAnd, a, b, _) | S.ECall ("__heyt_and", [a; b], _) -> p a && p b
  | S.EBinop (S.OpOr, a, b, _) | S.ECall ("__heyt_or", [a; b], _) -> p a || p b
  | S.ECall ("__heyt_imp", [a; b], _) -> (not (p a)) || p b
  | S.ENot (a, _) | S.ECall ("__heyt_not", [a], _) -> not (p a)
  | S.EParen (a, _) -> p a
  | _ -> raise (Not_modelled "a proposition outside the machine fragment")

let show = function
  | W x -> Int64.to_string x
  | D x -> Printf.sprintf "%h (%g)" x x

(* An assignment of candidates where a statement with only ∀ is false: a
   counterexample in the machine's own arithmetic. *)
let search (m : machine) (st : S.law_statement) (body : S.expr) : string option =
  let rec go vars env =
    match vars with
    | [] -> if mprop env body then None
            else Some (String.concat ", " (List.rev_map (fun (x, v) -> x ^ " = " ^ show v) env))
    | x :: rest ->
        List.fold_left (fun acc v -> match acc with Some _ -> acc | None -> go rest ((x, v) :: env))
          None (candidates m) in
  go (List.map (fun (_, x, _) -> x) st.S.ls_quants) []

let decide_machine (m : machine) (st : S.law_statement) (body : S.expr) : Law_check.verdict =
  let all_forall = List.for_all (fun (q, _, _) -> q = S.Forall) st.S.ls_quants in
  match (if all_forall then search m st body else None) with
  | Some cex -> Law_check.Refuted (Printf.sprintf "in the arithmetic of %s, at %s"
                                     (match m with Word -> "64-bit words" | Double -> "IEEE doubles") cex)
  | None ->
  let all_forall = List.for_all (fun (q, _, _) -> q = S.Forall) st.S.ls_quants in
  let program =
    if all_forall then
      String.concat "" (List.map (fun (_, x, _) ->
          Printf.sprintf "(declare-const |%s| %s)\n" x (sort m)) st.S.ls_quants)
      ^ Printf.sprintf "(assert (not %s))\n(check-sat)\n(get-model)\n" (to_prop m body)
    else
      let formula = List.fold_right (fun (q, x, _) acc ->
          Printf.sprintf "(%s ((|%s| %s)) %s)"
            (match q with S.Forall -> "forall" | S.Exists -> "exists") x (sort m) acc)
          st.S.ls_quants (to_prop m body) in
      Printf.sprintf "(assert (not %s))\n(check-sat)\n" formula in
  if not (Law_check.z3_available ()) then Law_check.Unknown "z3 is not installed"
  else
    match Naturality_smtcheck.run_z3 program with
    | Error e -> Law_check.Unknown e
    | Ok out ->
        let lines = String.split_on_char '\n' out in
        let what = match m with Word -> "64-bit words" | Double -> "IEEE doubles" in
        (match String.trim (List.hd lines) with
         | "unsat" -> Law_check.Proven ("z3, over " ^ what)
         | "sat" ->
             let rest = String.concat "\n" (List.tl lines) in
             Law_check.Refuted (Printf.sprintf "z3 finds %s where it is false%s" what
                                  (if all_forall then ": " ^ model_of rest else ""))
         | r -> Law_check.Unknown ("z3 answers " ^ r))

(* ─── the models of the program ──────────────────────────────────────── *)

let laws_of (apd : S.place_decl) =
  List.filter_map (function S.FoLaw (law, Some st) -> Some (law, st) | _ -> None) apd.S.pd_members

let ops_of (apd : S.place_decl) =
  List.filter_map (function S.FoOp o -> Some o | _ -> None) apd.S.pd_members

(* A place that uses an algebra: its laws read on the place's funs. *)
let check_models (p : S.program) (ps : (string * S.place_decl) list) : law_result list =
  List.concat_map (fun (pname, (pd : S.place_decl)) ->
    let algebras = match Hashtbl.find_opt S.place_algebras pname with Some l -> l | None -> [] in
    let funs = house_funs p pname in
    List.concat_map (fun a ->
      match List.assoc_opt a ps with
      | Some apd when Hashtbl.mem S.algebra_places a ->
          let ops = ops_of apd in
          (* a model that does not give every operation is refused by the
             checker of models; its laws are not read on it *)
          if not (List.for_all (fun (o : S.operation_decl) -> List.mem_assoc o.S.op_name funs) ops)
          then [] else
          List.map (fun (law, st) ->
            let verdict =
              try
                let body = unfold ops (house_resolver funs) st.S.ls_body in
                let nullary = pd.S.pd_arms <> []
                  && List.for_all (fun (v : S.variant) -> v.S.v_args = []) pd.S.pd_arms in
                let internal = Hashtbl.mem S.internal_carrier_sites
                    (pd.S.pd_loc.S.file, pd.S.pd_loc.S.start_line, pd.S.pd_loc.S.start_col) in
                if nullary && pd.S.pd_fusion = None then
                  decide_finite (List.map (fun (v : S.variant) -> v.S.v_name) pd.S.pd_arms) st body
                else
                  match pd.S.pd_fusion with
                  | Some c when internal && machine_of_carrier c <> None ->
                      (match machine_of_carrier c with
                       | Some m -> decide_machine m st body
                       | None -> assert false)
                  | _ ->
                      Law_check.Unknown (Printf.sprintf
                        "%s is neither a finite place of arms nor a machine word carried internally (i64, f64)"
                        pname)
              with Not_modelled why -> Law_check.Unknown ("the statement on " ^ pname ^ " contains " ^ why)
            in
            { lr_place = pname; lr_algebra = a; lr_law = law; lr_loc = pd.S.pd_loc;
              lr_given = false; lr_verdict = verdict }) (laws_of apd)
      | _ -> []) algebras) ps

(* The carrier models an algebra declares (`carried by C`): its laws read on
   the machine's operation of each symbol. *)
let check_carriers (ps : (string * S.place_decl) list) : law_result list =
  List.concat_map (fun (a, (apd : S.place_decl)) ->
    match Hashtbl.find_opt S.carrier_models a with
    | None -> []
    | Some models ->
        let ops = ops_of apd in
        List.concat_map (fun (c, given, loc) ->
          let resolve f args =
            match List.find_opt (fun (o : S.operation_decl) -> o.S.op_name = short_name f) ops with
            | Some o ->
                (match o.S.op_symbol with
                 | Some sym ->
                     (match Algebra_models.machine_term sym args loc with
                      | Some t -> Some t
                      | None -> raise (Not_modelled ("the operation " ^ o.S.op_name ^ ", whose symbol " ^ sym ^ " the machine has no operation for")))
                 | None -> raise (Not_modelled ("the operation " ^ o.S.op_name ^ ", which has no symbol")))
            | None -> None in
          List.map (fun (law, st) ->
            let verdict =
              match machine_of_carrier c with
              | None -> Law_check.Unknown (Printf.sprintf "the machine of %s is not modelled (i64, f64 are)" c)
              | Some m ->
                  (try decide_machine m st (unfold ops resolve st.S.ls_body)
                   with Not_modelled why -> Law_check.Unknown ("the statement on " ^ c ^ " contains " ^ why))
            in
            { lr_place = "the carrier " ^ c; lr_algebra = a; lr_law = law; lr_loc = loc;
              lr_given = given; lr_verdict = verdict }) (laws_of apd)) models) ps

let check (p : S.program) : law_result list =
  let ps = places p in
  check_carriers ps @ check_models p ps
