(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* space_graph.ml  -  the STATIC inter-Space communication graph.

   A node is a Space: a Space is a project directory, and the project root (the
   entrypoint area) is the node "". A directed edge  src -> dst  means: code that
   lives in Space `src` opens a declared, statically named channel toward Space
   `dst`. There are TWO edge families, both named in the source text, both known
   at compile time:

     Import   import mod::name from Space D    (TopImportFrom: cross-package RPC)
     Wire     wire to space D                   (EWireTo: the transport)

   This module builds ONLY the static topology (which arcs can exist). WHEN an
   arc closes (EOF) is runtime state and is out of scope: the 1.2 death-watch
   observes that, the compiler does not. The isolated-Space reclaimability
   corollary rests on BOTH families at once: a Space reached only by an import is
   NOT isolated, so any in/out-degree computation must sum Wire and Import alike.
   `kind` is carried for the dump and diagnostics, never for the degree.

   The wire walk is EXHAUSTIVE on purpose: no wildcard over expr / stmt /
   top_decl. A new constructor makes this file fail to compile rather than
   silently drop a wire that lives in the new position. That silent drop is the
   false green the syntax triangle taught us to forbid: here the type checker is
   the net. `import_targets` (Manifest) already extracts the import family, so the
   only genuinely new collection is the recursive EWireTo walk below. *)

module S = Surface_ast

type edge_kind = Wire | Import

type edge = {
  src  : string;          (* source Space; "" is the project root / entry *)
  dst  : string;          (* target Space, named in the source text *)
  kind : edge_kind;
  loc  : S.location;
}

(* ---- the recursive EWireTo collection, expr / stmt / condition ---- *)

let rec wires_expr (e : S.expr) : (string * S.location) list =
  match e with
  | S.EWireTo (sp, loc) -> [ (sp, loc) ]
  | S.ELit _ | S.EVar _ -> []
  | S.EField (a, _, _) | S.EParen (a, _) | S.ENot (a, _)
  | S.ERefl (a, _) | S.EFst (a, _) | S.ESnd (a, _)
  | S.EPathApp (a, _, _) | S.EPathAbs (_, a, _) | S.EIn (a, _, _)
  | S.ELam (_, a, _) | S.EMoveLam (_, a, _, _, _)
  | S.EReductionLam (_, a, _, _) | S.EMorphLam (_, a, _, _, _)
  | S.EFunctorLam (_, a, _, _, _, _) | S.EViewLam (_, a, _, _) -> wires_expr a
  | S.ECall (_, args, _) | S.EHITConstr (_, args, _) ->
      List.concat_map wires_expr args
  | S.EApp (h, args, _) -> wires_expr h @ List.concat_map wires_expr args
  | S.EBinop (_, a, b, _) | S.EPair (a, b, _) | S.EComposeWith (a, b, _) ->
      wires_expr a @ wires_expr b
  | S.EIfThenElse (a, b, c, _) | S.EJ (a, b, c, _) | S.EElMatch (a, b, c, _) ->
      wires_expr a @ wires_expr b @ wires_expr c
  | S.EPullbackVal (_, _, a, b, _) -> wires_expr a @ wires_expr b
  | S.EQuote (S.TyTermExpr t, a, _) -> wires_expr t @ wires_expr a
  | S.EHITElim (e0, branches, x, _) ->
      wires_expr e0
      @ List.concat_map (fun (_, _, be) -> wires_expr be) branches
      @ wires_expr x
  | S.EProduce (body, _) -> List.concat_map wires_stmt body
  | S.ESpawn (eo, body, _) ->
      (match eo with Some e0 -> wires_expr e0 | None -> [])
      @ List.concat_map wires_stmt body
  | S.ENew (_, fas, _) | S.ENewIn (_, _, fas, _) ->
      List.concat_map (fun fa -> wires_expr fa.S.fa_value) fas
  | S.EAll (_, c, _) -> wires_cond c
  | S.EPullback _ | S.EPushout _ -> []

and wires_stmt (s : S.stmt) : (string * S.location) list =
  match s with
  | S.SLet (_, e, _) | S.SAssignHolds (_, e, _) | S.SAssignBecomes (_, e, _)
  | S.SReturn (e, _) | S.SEmit (e, _) | S.SPromote (e, _) -> wires_expr e
  | S.SCall (_, args, _) -> List.concat_map wires_expr args
  | S.SNew (_, fas, _) | S.SNewIn (_, _, fas, _) ->
      List.concat_map (fun fa -> wires_expr fa.S.fa_value) fas
  | S.SWhen (c, body, elifs, oth, _) ->
      wires_cond c
      @ List.concat_map wires_stmt body
      @ List.concat_map (fun (c2, b2) -> wires_cond c2 @ List.concat_map wires_stmt b2) elifs
      @ (match oth with Some b -> List.concat_map wires_stmt b | None -> [])
  | S.SForEvery (_, _, e, body, _) | S.SInSequence (_, e, body, _)
  | S.SIter (e, body, _) | S.SWhile (e, body, _) ->
      wires_expr e @ List.concat_map wires_stmt body
  | S.SRepeat (_, body, oth, _) ->
      List.concat_map wires_stmt body
      @ (match oth with Some b -> List.concat_map wires_stmt b | None -> [])
  | S.SForever (body, _) | S.SProduce (body, _) -> List.concat_map wires_stmt body
  | S.SScope (_, body, e, _) -> List.concat_map wires_stmt body @ wires_expr e
  | S.SForces (_, c, body, _) -> wires_cond c @ List.concat_map wires_stmt body
  | S.SDrop (_, _) -> []                          (* drop is not a wire/import arc *)

and wires_cond (c : S.condition) : (string * S.location) list =
  match c with
  | S.CondExpr e | S.CondIs (e, _) | S.CondIsNot (e, _) -> wires_expr e
  | S.CondAnd (a, b) | S.CondOr (a, b) -> wires_cond a @ wires_cond b

let wires_fun (fd : S.fun_decl) : (string * S.location) list =
  List.concat_map wires_stmt fd.S.fn_body

(* Every top-level declaration that carries executable expr / stmt bodies where a
   wire can live. Exhaustive: a new top_decl constructor forces a decision here. *)
let wires_topdecl (td : S.top_decl) : (string * S.location) list =
  match td with
  | S.TopFun fd -> wires_fun fd
  | S.TopType _ -> []   (* a named sum declares no wires *)
  | S.TopLet (_, e, _) -> wires_expr e
  | S.TopReduction rd ->
      List.concat_map (function
          | S.RcOn (_, _, body, _) -> List.concat_map wires_stmt body
          | S.RcLet (_, e, _) -> wires_expr e)
        rd.S.rd_clauses
  | S.TopFunctor ft -> wires_expr ft.S.ft_body
  | S.TopTopology tp -> List.concat_map wires_stmt tp.S.tp_body
  | S.TopGeomMorphism gm ->
      (match gm.S.gm_pull with Some fd -> wires_fun fd | None -> [])
      @ (match gm.S.gm_push with Some fd -> wires_fun fd | None -> [])
  | S.TopView vw ->
      List.concat_map (function
          | S.VShowAs (_, e) -> wires_expr e
          | S.VShowSimple _ | S.VShowLabel _ -> []) vw.S.vw_items
  | S.TopNatTransform nt ->
      List.concat_map (fun (_, fd) -> wires_fun fd) nt.S.nt_components
  | S.TopPlace pd ->
      List.concat_map (function
          | S.FoCell cd -> wires_expr cd.S.cell_src @ wires_expr cd.S.cell_tgt
          | S.FoField _ | S.FoOp _ | S.FoLaw _ -> []) pd.S.pd_members
  (* declarations with no wire-bearing body: signatures, name-mappings, metadata *)
  | S.TopMove _ | S.TopMorph _ | S.TopOperation _
  | S.TopWorld _ | S.TopSpace _ | S.TopTopos _
  | S.TopPullback _ | S.TopPushout _ | S.TopReductionCompose _
  | S.TopImport _ | S.TopImportSym _ | S.TopImportFrom _ -> []

(* ---- the one-pass extraction: both families, one source Space ---- *)

(* Every edge whose SOURCE is `src_space` ("" = the project root / entry), from
   one file's declarations. Imports reuse Manifest.import_targets (already the
   frontend's import extractor); wires are the recursive walk above. Both are
   tagged with the same src_space and kept distinguishable only by `kind`. *)
let edges_of_file ~(src_space : string) (prog : S.program) : edge list =
  let import_edges =
    List.map
      (fun (dst, loc) -> { src = src_space; dst; kind = Import; loc })
      (Manifest.import_targets prog)
  in
  let wire_edges =
    List.concat_map
      (fun td ->
         List.map
           (fun (dst, loc) -> { src = src_space; dst; kind = Wire; loc })
           (wires_topdecl td))
      prog
  in
  import_edges @ wire_edges

(* ---- the graph and its static properties ---- *)

type graph = {
  nodes : string list;      (* every Space node; "" is the project root / entry *)
  edges : edge list;        (* wire and import together *)
}

(* Nodes are the declared Spaces (from the manifest), plus the entry root "",
   plus every Space actually named as a source or a target. A named target that
   is not a declared Space stays a node here and is reported by
   `unresolved_targets`; it is not silently dropped. *)
let build ~(declared : string list) (edges : edge list) : graph =
  let ns =
    "" :: declared
    @ List.concat_map (fun e -> [ e.src; e.dst ]) edges
  in
  { nodes = List.sort_uniq compare ns; edges }

(* Degree counts BOTH families. This is the load-bearing line: a Space reached
   only by an import must have in_degree >= 1, hence must NOT be isolated. If a
   future edit filtered `kind` here, an import-only Space would look reclaimable,
   which is the exact soundness hole this pass exists to prevent. *)
let in_degree (g : graph) (n : string) : int =
  List.length (List.filter (fun e -> e.dst = n) g.edges)

let out_degree (g : graph) (n : string) : int =
  List.length (List.filter (fun e -> e.src = n) g.edges)

(* Isolated = no communication at all (in = out = 0), summing wire and import.
   These are the ONLY Spaces the compiler can call reclaimable at end of work
   without a runtime death-watch. A sink (in > 0, out = 0) is reclaimable only
   once its incoming arcs close, which is dynamic and belongs to 1.2. *)
let isolated (g : graph) : string list =
  List.filter (fun n -> in_degree g n = 0 && out_degree g n = 0) g.nodes

let succ (g : graph) (n : string) : string list =
  List.sort_uniq compare
    (List.filter_map (fun e -> if e.src = n then Some e.dst else None) g.edges)

let reachable_from (g : graph) (start : string) : string list =
  let seen = Hashtbl.create 16 in
  let rec go n =
    if not (Hashtbl.mem seen n) then begin
      Hashtbl.replace seen n ();
      List.iter go (succ g n)
    end
  in
  go start;
  List.sort compare (Hashtbl.fold (fun k () acc -> k :: acc) seen [])

(* Spaces no path from the entry root reaches. A Space the program never opens a
   channel toward (directly or transitively) is unreachable from the root. *)
let unreachable_from_entry (g : graph) : string list =
  let r = reachable_from g "" in
  List.filter (fun n -> n <> "" && not (List.mem n r)) g.nodes

(* A directed cycle, if one exists, as the node sequence n -> ... -> n. Standard
   DFS with an on-path set; `path` holds the ancestors, most recent first. *)
let find_cycle (g : graph) : string list option =
  let state = Hashtbl.create 16 in      (* n -> `Gray (on path) | `Black (done) *)
  let witness = ref None in
  let rec visit (path : string list) (n : string) =
    if !witness <> None then ()
    else match Hashtbl.find_opt state n with
      | Some `Black -> ()
      | Some `Gray ->
          let rec upto = function
            | x :: _ when x = n -> [ x ]
            | x :: rest -> x :: upto rest
            | [] -> []
          in
          witness := Some (List.rev (upto path) @ [ n ])
      | None ->
          Hashtbl.replace state n `Gray;
          List.iter (fun m -> visit (n :: path) m) (succ g n);
          Hashtbl.replace state n `Black
  in
  List.iter
    (fun n -> if !witness = None && Hashtbl.find_opt state n <> Some `Black
              then visit [] n)
    g.nodes;
  !witness

(* Targets named in the text that are not a declared Space: a wire or import to
   a name the manifest does not know. Reported honestly, never invented away. *)
let unresolved_targets ~(declared : string list) (g : graph) : edge list =
  List.filter (fun e -> not (List.mem e.dst declared)) g.edges

(* ---- the inspectable dump (fed to --dump-space-graph and the gate) ---- *)

let node_label n = if n = "" then "<root>" else n
let kind_label = function Wire -> "wire" | Import -> "import"

let dump ~(declared : string list) (g : graph) : string =
  let b = Buffer.create 256 in
  let p fmt = Printf.ksprintf (fun s -> Buffer.add_string b s; Buffer.add_char b '\n') fmt in
  p "Space communication graph (static: wire and import arcs, from the source)";
  p "";
  p "nodes (%d):" (List.length g.nodes);
  List.iter (fun n -> p "  %s" (node_label n)) g.nodes;
  p "edges (%d):" (List.length g.edges);
  List.iter
    (fun e -> p "  %s -> %s  [%s]" (node_label e.src) (node_label e.dst) (kind_label e.kind))
    (List.sort compare g.edges);
  let iso = isolated g in
  p "isolated (static-reclaimable): %s"
    (if iso = [] then "(none)" else String.concat ", " (List.map node_label iso));
  let unr = unreachable_from_entry g in
  p "unreachable from <root>: %s"
    (if unr = [] then "(none)" else String.concat ", " (List.map node_label unr));
  (match find_cycle g with
   | None -> p "cycles: acyclic"
   | Some c -> p "cycles: %s" (String.concat " -> " (List.map node_label c)));
  let unres = unresolved_targets ~declared g in
  p "unresolved targets (named but not a declared Space): %s"
    (if unres = [] then "(none)"
     else String.concat ", "
            (List.map (fun e -> Printf.sprintf "%s->%s" (node_label e.src) e.dst) unres));
  Buffer.contents b
