(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* call_graph.ml — the one fixed point of the checker over the graph of the calls.
 *
 * The facts the checker computes over the calls of a program (the effects a fun
 * visits, the first thing a fun allocates, the Spaces a fun reaches, the groups a
 * type is generalized over) grow by union along the arcs: the fact of a fun is
 * the union of its own seed and of the facts of the funs it calls. Such a fact is
 * the least fixed point of a distributive system, and the least fixed point is
 * the meet over all paths (Kildall; Nielson, Nielson, Hankin, Principles of
 * Program Analysis, §2.4, §6): every member of a group of mutually recursive funs
 * reaches every other, so on the condensation of the graph, its strongly connected
 * components taken callees first, one pass computes it, with no bound on the
 * number of rounds (Muchnick, Advanced Compiler Design, §19.2.1).
 *
 * A call whose head is not a fun of the program, nor a primitive, is a call
 * through a function value. The value is one of the funs the program names where
 * it does not call them: such a call reaches each of them. The set is one, for the
 * effects, the allocation, the termination and the mobility. *)

module S = Surface_ast

(* The strongly connected components of a graph (Tarjan), the ones a component
   calls first. *)
let condensation (nodes : string list) (succ : string -> string list) : string list list =
  let index = Hashtbl.create 16 and low = Hashtbl.create 16 in
  let on_stack = Hashtbl.create 16 in
  let stack = ref [] and next = ref 0 and groups = ref [] in
  let rec visit v =
    Hashtbl.replace index v !next;
    Hashtbl.replace low v !next;
    incr next;
    stack := v :: !stack;
    Hashtbl.replace on_stack v ();
    List.iter (fun w ->
      if not (Hashtbl.mem index w) then begin
        visit w;
        Hashtbl.replace low v (min (Hashtbl.find low v) (Hashtbl.find low w))
      end else if Hashtbl.mem on_stack w then
        Hashtbl.replace low v (min (Hashtbl.find low v) (Hashtbl.find index w)))
      (succ v);
    if Hashtbl.find low v = Hashtbl.find index v then begin
      let rec pop acc =
        match !stack with
        | [] -> acc
        | w :: rest ->
            stack := rest;
            Hashtbl.remove on_stack w;
            if w = v then w :: acc else pop (w :: acc) in
      groups := pop [] :: !groups
    end in
  List.iter (fun v -> if not (Hashtbl.mem index v) then visit v) nodes;
  List.rev !groups

(* Whether a component is recursive: more than one member, or a member that
   calls itself. *)
let recursive (succ : string -> string list) (group : string list) : bool =
  match group with
  | [v] -> List.mem v (succ v)
  | _ -> true

(* The union of a list into another, the elements in their first order. *)
let union (a : 'a list) (b : 'a list) : 'a list =
  List.fold_left (fun acc x -> if List.mem x acc then acc else acc @ [x]) a b

(* The least fixed point of fact(f) = seed(f) ∪ ⋃ { fact(g) | f -> g }, in one
   pass over the condensation, callees first. *)
let reach (nodes : string list) (succ : string -> string list)
    (seed : string -> 'a list) : (string, 'a list) Hashtbl.t =
  let out = Hashtbl.create 64 in
  List.iter (fun group ->
    let inside v = List.mem v group in
    let fact = List.fold_left (fun acc v ->
        let own = union acc (seed v) in
        List.fold_left (fun acc w ->
            if inside w then acc
            else union acc (Option.value (Hashtbl.find_opt out w) ~default:(seed w)))
          own (succ v)) [] group in
    List.iter (fun v -> Hashtbl.replace out v fact) group)
    (condensation nodes succ);
  out

(* The first witness of a fact that is one thing, not a set (the first thing a
   fun allocates, with the path that leads to it): a fun has its own witness, or
   the witness of a callee, found callees first; inside a component the members
   pass their witness on until each has one, at most once each. *)
let first (nodes : string list) (succ : string -> string list)
    (own : string -> 'w option) (through : string -> 'w -> 'w) : (string, 'w) Hashtbl.t =
  let out = Hashtbl.create 64 in
  List.iter (fun group ->
    List.iter (fun v -> match own v with Some w -> Hashtbl.replace out v w | None -> ()) group;
    let rec settle () =
      let got = List.exists (fun v ->
          if Hashtbl.mem out v then false
          else match List.find_map (fun g ->
              Option.map (through g) (Hashtbl.find_opt out g)) (succ v) with
            | Some w -> Hashtbl.replace out v w; true
            | None -> false) group in
      if got then settle () in
    settle ())
    (condensation nodes succ);
  out

(* The funs of a program named where they are not called: the function values a
   call through a value can reach. *)
let escaping (p : S.program) : string list =
  let funs = Hashtbl.create 64 in
  List.iter (function S.TopFun fd -> Hashtbl.replace funs fd.S.fn_name () | _ -> ()) p;
  let named = ref [] in
  let note n = if Hashtbl.mem funs n && not (List.mem n !named) then named := n :: !named in
  let rec expr (e : S.expr) =
    (match e with
     | S.EVar (n, _) -> note n
     | _ -> ());
    let (es, bs) = S.sub_exprs e in
    (* the head of a call is a call, not a value: its arguments are read *)
    List.iter expr es;
    List.iter stmts bs
  and stmts ss = List.iter stmt ss
  and stmt s =
    List.iter expr (S.stmt_exprs s);
    List.iter stmts (S.sub_stmts s) in
  List.iter (function S.TopFun fd -> stmts fd.S.fn_body | _ -> ()) p;
  List.sort compare !named

(* The names a fun binds itself (its parameters, its bindings, the parameters of
   its lambdas, the names of its patterns): a call whose head is one of them is a
   call through a function value. *)
let local_names (fd : S.fun_decl) : string list =
  let out = ref (List.map (fun p -> p.S.param_name) fd.S.fn_params) in
  let note x = if not (List.mem x !out) then out := x :: !out in
  let rec expr (e : S.expr) =
    (match e with
     | S.ELam (ps, _, _) -> List.iter (fun (x, _) -> note x) ps
     | _ -> ());
    let (es, bs) = S.sub_exprs e in
    List.iter expr es;
    List.iter stmts bs
  and stmts ss = List.iter stmt ss
  and stmt s =
    (match s with
     | S.SLet (x, _, _) -> note x
     | S.SForEvery (_, x, _, _, _) | S.SInSequence (x, _, _, _) -> note x
     | _ -> ());
    List.iter expr (S.stmt_exprs s);
    List.iter stmts (S.sub_stmts s) in
  stmts fd.S.fn_body;
  !out

(* The names a fun calls (the heads of its calls). *)
let called_names (fd : S.fun_decl) : string list =
  let out = ref [] in
  let note x = if not (List.mem x !out) then out := x :: !out in
  let rec expr (e : S.expr) =
    (match e with
     | S.ECall (n, _, _) -> note n
     | S.EApp (S.EVar (n, _), _, _) -> note n
     | _ -> ());
    let (es, bs) = S.sub_exprs e in
    List.iter expr es;
    List.iter stmts bs
  and stmts ss = List.iter stmt ss
  and stmt s =
    (match s with S.SCall (n, _, _) -> note n | _ -> ());
    List.iter expr (S.stmt_exprs s);
    List.iter stmts (S.sub_stmts s) in
  stmts fd.S.fn_body;
  List.rev !out

(* Whether a fun calls a function value: a name it binds itself. *)
let calls_a_value (fd : S.fun_decl) : bool =
  let locals = local_names fd in
  List.exists (fun n -> List.mem n locals) (called_names fd)
