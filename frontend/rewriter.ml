(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* rewriter.ml — the tool of the migrations: it changes only the nodes of one form and keeps every
 * other byte of the text, comments included.
 *
 * A rule names the nodes it rewrites (`select`), the tree each becomes (`transform`) and how the
 * new node is written (`print`). A rule writes only the syntax of the node itself: the text of each
 * child is taken from the source as it was written (`print` receives the function that gives it),
 * so a child keeps its spelling, its layout and its comments. The rewriter finds the selected nodes
 * by their constructor, outermost first, cuts the text of each by its span, writes the new node in
 * its place, and leaves the rest of the text as it was. A child with no text of its own (a node the
 * parser made up) refuses the rewrite.
 *
 * The oracle is the whole tree: the text after the rewrite must read as the program before with
 * the rule applied to its selected nodes, and nothing else (Ast_compare, equal but for positions
 * and grouping parentheses). A node whose span is wrong rewrites the wrong part of the text, and
 * the tree says so; then the file is left as it was. *)

module S = Surface_ast

type rule = {
  name : string;
  select : S.expr -> bool;
  transform : S.expr -> S.expr;
  print : text -> S.expr -> string;
}

(* what a rule may read of the source: the text of a child, and the text between two children (the
   syntax of the node itself, with its spaces and line breaks) *)
and text = {
  source : S.expr -> string;
  between : S.expr -> S.expr -> string;
}

let loc_of_expr (e : S.expr) : S.location = S.location_of_expr e

(* the offset of a 1-based line and a 0-based byte column *)
let offsets (text : string) : int array =
  let starts = ref [0] in
  String.iteri (fun i c -> if c = '\n' then starts := (i + 1) :: !starts) text;
  Array.of_list (List.rev !starts)

let offset lines (l : int) (c : int) = lines.(l - 1) + c

(* every selected node of the program, outermost first (a selected node is not searched inside) *)
let selected (rule : rule) (p : S.program) : S.expr list =
  let found = ref [] in
  let pick e = if rule.select e then (found := e :: !found; Some e) else None in
  List.iter (function
    | S.TopFun fd -> List.iter (fun st -> ignore (Method_sugar.map_stmt pick st)) fd.S.fn_body
    | _ -> ()) p;
  List.rev !found

(* the program with the rule applied to its selected nodes *)
let applied (rule : rule) (p : S.program) : S.program =
  let tr e = if rule.select e then Some (rule.transform e) else None in
  List.map (function
    | S.TopFun fd -> S.TopFun { fd with S.fn_body = List.map (Method_sugar.map_stmt tr) fd.S.fn_body }
    | d -> d) p

exception No_text of S.expr

type outcome =
  | Unchanged                          (* no node of the form *)
  | Rewritten of string * int          (* the new text, and how many nodes *)
  | Refused of string                  (* the oracle said no: why *)

let rewrite (rule : rule) (text : string) : outcome =
  match Formatter.parse text with
  | None -> Refused "the text does not parse"
  | Some before ->
      let nodes = selected rule before in
      if nodes = [] then Unchanged
      else begin
        let lines = offsets text in
        let span_of (e : S.expr) =
          let l = loc_of_expr e in
          if l.S.start_line < 1 || l.S.end_line < l.S.start_line || l.S.end_line > Array.length lines
          then raise (No_text e);
          let s = offset lines l.S.start_line l.S.start_col and t = offset lines l.S.end_line l.S.end_col in
          if s >= t || t > String.length text then raise (No_text e);
          (s, t) in
        let source_of e = let (s, t) = span_of e in String.sub text s (t - s) in
        let between a b =
          let (_, t) = span_of a and (s, _) = span_of b in
          if s < t then raise (No_text b);
          String.sub text t (s - t) in
        let tx = { source = source_of; between } in
        let spans = List.map (fun e ->
          let (s, t) = span_of e in
          (s, t, rule.print tx (rule.transform e))) nodes in
        let spans = List.sort (fun (a, _, _) (b, _, _) -> compare a b) spans in
        let buf = Buffer.create (String.length text) in
        let at = List.fold_left (fun at (s, e, w) ->
          if s < at then raise Exit;
          Buffer.add_string buf (String.sub text at (s - at)); Buffer.add_string buf w; e) 0 spans in
        Buffer.add_string buf (String.sub text at (String.length text - at));
        let after = Buffer.contents buf in
        let expected = applied rule before in
        match Formatter.parse after with
        | None -> Refused "the rewritten text does not parse"
        | Some got ->
            (match Ast_compare.first_difference expected got with
             | None -> Rewritten (after, List.length nodes)
             | Some (l1, l2, what) ->
                 Refused (Printf.sprintf "the rewritten text is another program: expected %d:%d, got %d:%d: %s"
                            l1.S.start_line l1.S.start_col l2.S.start_line l2.S.start_col what))
      end

let rewrite (rule : rule) (text : string) : outcome =
  try rewrite rule text with
  | Exit -> Refused "two selected nodes overlap"
  | No_text e ->
      let l = loc_of_expr e in
      Refused (Printf.sprintf "a node at %d:%d has no text of its own (made up by the parser)"
                 l.S.start_line l.S.start_col)

let binop_symbol : S.binop -> string = function
  | S.OpAdd -> "+" | S.OpSub -> "-" | S.OpMul -> "*" | S.OpDiv -> "/" | S.OpMod -> "%"
  | S.OpLt -> "<" | S.OpGt -> ">" | S.OpLeq -> "<=" | S.OpGeq -> ">=" | S.OpEq -> "==" | S.OpNeq -> "!="
  | S.OpAnd -> "&&" | S.OpOr -> "||"

(* The rules. A step of the migration adds its own; the one here writes every binary operation of
   arithmetic and comparison again from its parts, the operands and the text between them as they
   were written: the same tree and the same text, the test of the tool. A rule that changes a sign
   replaces the sign inside `between` and keeps its spaces. *)
let rules : rule list = [
  { name = "reprint-binop";
    select = (function
      | S.EBinop ((S.OpAdd | S.OpSub | S.OpMul | S.OpDiv | S.OpMod | S.OpLt | S.OpGt | S.OpLeq
                  | S.OpGeq | S.OpEq | S.OpNeq), _, _, _) -> true
      | _ -> false);
    transform = (fun e -> e);
    print = (fun tx -> function
      | S.EBinop (_, a, b, _) -> tx.source a ^ tx.between a b ^ tx.source b
      | e -> tx.source e) };
  (* one space on each side of the sign of an operation written on one line: the same tree, a
     change of the text only inside the node *)
  { name = "space-binop";
    select = (function
      | S.EBinop ((S.OpAdd | S.OpSub | S.OpMul | S.OpDiv | S.OpMod | S.OpLt | S.OpGt | S.OpLeq
                  | S.OpGeq | S.OpEq | S.OpNeq), _, _, _) -> true
      | _ -> false);
    transform = (fun e -> e);
    print = (fun tx -> function
      | S.EBinop (op, a, b, _) ->
          let g = tx.between a b in
          if String.contains g '\n' || String.contains g '/' then tx.source a ^ g ^ tx.source b
          else tx.source a ^ " " ^ binop_symbol op ^ " " ^ tx.source b
      | e -> tx.source e) };
  (* a rule that says it keeps the tree and swaps the operands: it exists to prove that the oracle
     refuses a rewrite that is another program *)
  { name = "test-swap-operands";
    select = (function S.EBinop (S.OpSub, _, _, _) -> true | _ -> false);
    transform = (fun e -> e);
    print = (fun tx -> function
      | S.EBinop (_, a, b, _) -> tx.source b ^ tx.between a b ^ tx.source a
      | e -> tx.source e) };
]
