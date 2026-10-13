(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* tail_position.ml — a `return` is the value of its body.
 *
 * A function is an arrow, and its value is the value of its body. A `return`
 * names that value, so it stands where the body ends: in tail position. A
 * `return` anywhere else would be a non-local jump out of the body, and Yon
 * has none (book, ch. 19). The rule, by structure:
 *
 *   - in a body, the tail is its last statement;
 *   - a `when … otherwise` in tail position is one case analysis (a
 *     copairing): the tail of each branch is the tail of the body;
 *   - a `when` without `otherwise` is a decision for its effects: its branches
 *     never hold the tail, nor do the bodies of loops, `forces`, `forever`,
 *     `repeat` and `produce` statements, nor any statement before the last;
 *   - a block that is itself a value — the body of a function, of a reduction
 *     clause, of `spawn { … }` and `produce { … }` in expression position —
 *     has a tail of its own.
 *
 * The walk is exhaustive over statements and expressions: a new form fails to
 * compile here until it is classified. Types are not walked: a term in type
 * position is checked, never run as a body. *)

module S = Surface_ast

let rec body (acc : S.location list ref) (stmts : S.stmt list) : unit =
  let n = List.length stmts in
  List.iteri (fun i s -> stmt acc ~tail:(i = n - 1) s) stmts

and inner (acc : S.location list ref) (stmts : S.stmt list) : unit =
  List.iter (stmt acc ~tail:false) stmts

and branches acc ~tail (stmts : S.stmt list) : unit =
  if tail then body acc stmts else inner acc stmts

and stmt (acc : S.location list ref) ~(tail : bool) (s : S.stmt) : unit =
  match s with
  | S.SReturn (e, loc) ->
      if not tail then acc := loc :: !acc;
      expr acc e
  | S.SLet (_, e, _) | S.SEmit (e, _) | S.SPromote (e, _) -> expr acc e
  | S.SAssignHolds (_, e, _) | S.SAssignBecomes (_, e, _) -> expr acc e
  | S.SCall (_, args, _) -> List.iter (expr acc) args
  | S.SNew (_, fas, _) | S.SNewIn (_, _, fas, _) -> fields acc fas
  | S.SWhen (c, b, elifs, other, _) ->
      cond acc c;
      (* only a complete case analysis passes the tail to its branches *)
      let complete = tail && other <> None in
      branches acc ~tail:complete b;
      List.iter (fun (c', b') -> cond acc c'; branches acc ~tail:complete b') elifs;
      (match other with Some o -> branches acc ~tail:complete o | None -> ())
  | S.SForEvery (_, _, e, b, _) | S.SInSequence (_, e, b, _) ->
      expr acc e; inner acc b
  | S.SRepeat (_, b, other, _) ->
      inner acc b; (match other with Some o -> inner acc o | None -> ())
  | S.SForever (b, _) | S.SProduce (b, _) -> inner acc b
  | S.SScope (_, b, e, _) -> inner acc b; expr acc e
  | S.SForces (_, c, b, _) -> cond acc c; inner acc b
  | S.SIter (e, b, _) | S.SWhile (e, b, _) -> expr acc e; inner acc b
  | S.SDrop _ -> ()

and fields acc (fas : S.field_assignment list) : unit =
  List.iter (fun (fa : S.field_assignment) -> expr acc fa.S.fa_value) fas

and cond acc (c : S.condition) : unit =
  match c with
  | S.CondExpr e | S.CondIs (e, _) | S.CondIsNot (e, _) -> expr acc e
  | S.CondAnd (a, b) | S.CondOr (a, b) -> cond acc a; cond acc b

and expr (acc : S.location list ref) (e : S.expr) : unit =
  let ex = expr acc in
  match e with
  | S.ELit _ | S.EVar _ | S.EWireTo _ | S.EPullback _ | S.EPushout _ -> ()
  | S.EField (x, _, _) | S.EPathApp (x, _, _) | S.EPathAbs (_, x, _)
  | S.EParen (x, _) | S.EIn (x, _, _) | S.ERefl (x, _) | S.EFst (x, _)
  | S.ESnd (x, _) | S.ENot (x, _) | S.EQuote (_, x, _) -> ex x
  | S.ECall (_, xs, _) | S.EHITConstr (_, xs, _) -> List.iter ex xs
  | S.EApp (f, xs, _) -> ex f; List.iter ex xs
  | S.EHITElim (x, arms, m, _) ->
      ex x; List.iter (fun (_, _, b) -> ex b) arms; ex m
  | S.EProduce (b, _) -> body acc b
  | S.ESpawn (n, b, _) -> (match n with Some x -> ex x | None -> ()); body acc b
  | S.ENew (_, fas, _) | S.ENewIn (_, _, fas, _) -> fields acc fas
  | S.EBinop (_, a, b, _) | S.EPair (a, b, _) | S.EComposeWith (a, b, _) -> ex a; ex b
  | S.EAll (_, c, _) -> cond acc c
  | S.EJ (a, b, c, _) | S.EElMatch (a, b, c, _) | S.EIfThenElse (a, b, c, _) ->
      ex a; ex b; ex c
  | S.EPullbackVal (_, _, a, b, _) -> ex a; ex b
  | S.ELam (_, b, _) | S.EMoveLam (_, b, _, _, _) | S.EReductionLam (_, b, _, _)
  | S.EMorphLam (_, b, _, _, _) | S.EFunctorLam (_, b, _, _, _, _)
  | S.EViewLam (_, b, _, _) -> ex b

let fun_body acc (fd : S.fun_decl) = body acc fd.S.fn_body

let top acc (d : S.top_decl) : unit =
  match d with
  | S.TopFun fd -> fun_body acc fd
  | S.TopReduction rd ->
      List.iter (function
        | S.RcOn (_, _, b, _) -> body acc b
        | S.RcLet (_, e, _) -> expr acc e) rd.S.rd_clauses
  | S.TopGeomMorphism gm ->
      Option.iter (fun_body acc) gm.S.gm_pull;
      Option.iter (fun_body acc) gm.S.gm_push
  | S.TopMorph mp -> Option.iter (fun_body acc) mp.S.mp_on_object
  | S.TopFunctor ft -> expr acc ft.S.ft_body
  | S.TopLet (_, e, _) -> expr acc e
  | S.TopView vw ->
      List.iter (function S.VShowAs (_, e) -> expr acc e
                        | S.VShowSimple _ | S.VShowLabel _ -> ()) vw.S.vw_items
  | S.TopTopos tp ->
      List.iter (fun (pr : S.prop_decl) -> Option.iter (expr acc) pr.S.pr_body_opt)
        tp.S.tp_props
  | S.TopPlace pd ->
      List.iter (function
        | S.FoCell c -> expr acc c.S.cell_src; expr acc c.S.cell_tgt
        | S.FoField _ | S.FoOp _ | S.FoLaw _ -> ()) pd.S.pd_members
  | S.TopWorld _ | S.TopSpace _ | S.TopMove _ | S.TopOperation _
  | S.TopReductionCompose _ | S.TopNatTransform _ | S.TopImport _
  | S.TopImportSym _ | S.TopImportFrom _ -> ()

(* A body ends in a value when its last statement is a `return`, or a
   `when … otherwise` each of whose branches ends in a value. *)
let rec ends_in_return (stmts : S.stmt list) : bool =
  match List.rev stmts with
  | S.SReturn _ :: _ -> true
  | S.SWhen (_, b, elifs, Some o, _) :: _ ->
      ends_in_return b && ends_in_return o
      && List.for_all (fun (_, b') -> ends_in_return b') elifs
  | _ -> false

(* The misplaced returns of a program, in source order. *)
let check (prog : S.program) : S.location list =
  let acc = ref [] in
  List.iter (top acc) prog;
  List.rev !acc
