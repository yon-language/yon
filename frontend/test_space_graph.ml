(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_space_graph.ml  -  proof harness and self-verifying oracle for the static
   Space graph and the downstream-reachability (reclaim) analysis.

   No argument: runs as an oracle in the test_*.exe family (exit 0 on success). It
   checks the graph properties AND the downstream-reachability pins, including the
   loop back-edge rule, the sequential case, the inter-procedural transitive case,
   and the scope case. Self-describing: a function named *_illegal must have its
   `drop` point rejected (the Space is still downstream), *_legal must be accepted.

   One .yon file: prints the edges edges_of_file collects (both families).
   A project directory: prints the graph dump plus the per-function transitive
   arc-set and any `be drop_<Space> holds ...` probe verdicts. *)

module S = Surface_ast

let read_file fn =
  let ic = open_in fn in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic; s

(* Parse a source string to a program, draining the arrows lifted from place
   bodies (a form-C `fun main`, etc.), exactly as the driver does per file. *)
let parse_src (src : string) : S.program =
  let lexbuf = Lexing.from_string src in
  Parser_state.reset ();
  let p = Parser.program Lexer.token lexbuf in
  p @ Parser_state.drain ()

let parse_file path =
  Lexing.from_string (read_file path) |> ignore;   (* keep the read explicit *)
  parse_src (read_file path)

let ends_with (s : string) (suf : string) : bool =
  let ls = String.length s and lf = String.length suf in
  ls >= lf && String.sub s (ls - lf) lf = suf

(* Every `be drop_<Space> holds ...` marker in a statement tree: a probe point
   where we would drop <Space>. Recurses into every nested block. *)
let rec markers (stmts : S.stmt list) : (string * S.location) list =
  List.concat_map (fun s -> match s with
    | S.SLet (n, _, l) when String.length n > 5 && String.sub n 0 5 = "drop_" ->
        [ (String.sub n 5 (String.length n - 5), l) ]
    | S.SWhile (_, b, _) | S.SIter (_, b, _)
    | S.SForEvery (_, _, _, b, _) | S.SInSequence (_, _, b, _)
    | S.SForever (b, _) | S.SProduce (b, _)
    | S.SScope (_, b, _, _) | S.SForces (_, _, b, _) -> markers b
    | S.SRepeat (_, b, oth, _) ->
        markers b @ (match oth with Some o -> markers o | None -> [])
    | S.SWhen (_, b, elifs, oth, _) ->
        markers b @ List.concat_map (fun (_, bb) -> markers bb) elifs
        @ (match oth with Some o -> markers o | None -> [])
    | _ -> []) stmts

let single (file : string) (src_space : string) =
  let edges = Space_graph.edges_of_file ~src_space (parse_file file) in
  Printf.printf "%s  (src=%s):  %d edge(s)\n" file src_space (List.length edges);
  List.iter (fun (e : Space_graph.edge) ->
      Printf.printf "  %s -> %s  [%s]\n"
        (Space_graph.node_label e.Space_graph.src) e.Space_graph.dst
        (Space_graph.kind_label e.Space_graph.kind))
    edges

let project (root : string) =
  let declared =
    let mpath = Filename.concat root "yon.toml" in
    if Sys.file_exists mpath then
      let wm = Manifest.parse_file mpath in
      List.sort compare
        (Hashtbl.fold (fun k _ acc -> k :: acc) wm.Manifest.space_world [])
    else []
  in
  let per_file =
    List.map
      (fun (u : Package_layout.unit_loc) ->
         (u.Package_layout.ul_space, parse_file u.Package_layout.ul_path))
      (Package_layout.layout ~root)
  in
  let edges =
    List.concat_map (fun (sp, prog) -> Space_graph.edges_of_file ~src_space:sp prog) per_file
  in
  print_string (Space_graph.dump ~declared (Space_graph.build ~declared edges));
  let merged = List.concat_map snd per_file in
  let place_space =
    let h = Hashtbl.create 32 in
    List.iter (fun (sp, prog) ->
      if sp <> "" then
        List.iter (function
          | S.TopPlace pd -> Hashtbl.replace h pd.S.pd_name sp
          | _ -> ()) prog) per_file;
    h
  in
  let tarcs = Space_liveness.transitive_arcs ~place_space merged in
  print_string "\nper-function transitive Space arc-set (liveness):\n";
  Hashtbl.fold (fun f arcs acc -> (f, arcs) :: acc) tarcs []
  |> List.sort compare
  |> List.iter (fun (f, arcs) ->
         Printf.printf "  %s -> {%s}\n" f
           (if arcs = [] then "(none)" else String.concat ", " arcs));
  let imap = Space_liveness.import_map merged in
  Hashtbl.iter (fun p s -> Hashtbl.replace imap p s) place_space;
  let ftab = Space_liveness.func_table merged in
  let any = ref false in
  Hashtbl.iter (fun fname fd ->
      List.iter (fun (x, loc) ->
          if not !any then (print_string "\ndrop probes (downstream check):\n"; any := true);
          let ds = Space_liveness.downstream_arcs ~imap ~ftab ~tarcs
                     fd.S.fn_body loc in
          Printf.printf "  %s:%d  drop %s  ->  %s\n"
            fname loc.S.start_line x
            (if not (List.mem x ds) then "LEGAL (not downstream)"
             else "ILLEGAL (still downstream: " ^ String.concat "," ds ^ ")"))
        (markers fd.S.fn_body))
    ftab

(* ---- the self-verifying oracle ---- *)

(* Graph pins: the reference topology, checked in memory. In particular an
   import-only Space is NOT isolated (the degree sums wire AND import). *)
let graph_selftest () : string list =
  let open Space_graph in
  let e src dst kind = { src; dst; kind; loc = S.dummy_loc } in
  let edges = [ e "" "A" Wire; e "A" "B" Wire; e "B" "A" Wire; e "" "D" Import ] in
  let g = build ~declared:[ "A"; "B"; "C"; "D" ] edges in
  let iso = isolated g in
  List.filter_map (fun (name, ok) -> if ok then None else Some name) [
    "graph: isolated recognizes C",        List.mem "C" iso;
    "graph: import-only D not isolated",    not (List.mem "D" iso);
    "graph: in-degree sums the import arc", in_degree g "D" >= 1;
    "graph: cycle A<->B detected",          find_cycle g <> None;
  ]

(* Downstream pins: the reclaim analysis, checked on parsed source. Each function
   named *_illegal must reject its drop (Space still downstream); *_legal must
   accept it. One per shape, control-flow AND arc-family:
     control-flow: back-edge (loop), sequential, transitive (level-2 call), scope;
     arc families:  wire, import, mangled cross-space call (apply_move/morph in S),
                    place creation (new P at a topos-at-space), awaits subscription.
   The arc-family pins are the completeness audit: every way a named Space's heap
   is touched must be an arc, or the automatic reclaim (and this drop check) would
   miss a live use. *)
let downstream_src = "\
import svc::a_op from A\n\
fun helper(): Number { be w holds wire to space A  return 0 }\n\
fun loop_illegal(): Number {\n\
  be i holds 0\n\
  while i < 3 do { be w holds wire to space A  be drop_A holds 0  i = i + 1 }\n\
  return 0\n\
}\n\
fun loop_legal(): Number {\n\
  be i holds 0\n\
  while i < 3 do { be w holds wire to space A  i = i + 1 }\n\
  be drop_A holds 0\n\
  return 0\n\
}\n\
fun seq_illegal(): Number { be drop_A holds 0  be w holds wire to space A  return 0 }\n\
fun seq_legal(): Number { be w holds wire to space A  be drop_A holds 0  return 0 }\n\
fun trans_illegal(): Number { be drop_A holds 0  be r holds helper()  return r }\n\
fun trans_legal(): Number { be r holds helper()  be drop_A holds 0  return r }\n\
fun scope_illegal(): Number { be drop_A holds 0  scope S { be w holds wire to space A }  return 0 }\n\
fun scope_legal(): Number { scope S { be w holds wire to space A }  be drop_A holds 0  return 0 }\n\
fun import_illegal(): Number { be drop_A holds 0  be r holds a_op(5)  return r }\n\
fun import_legal(): Number { be r holds a_op(5)  be drop_A holds 0  return r }\n\
fun move_illegal(): Number { be drop_A holds 0  be r holds apply_move(0) in A  return r }\n\
fun move_legal(): Number { be r holds apply_move(0) in A  be drop_A holds 0  return r }\n\
fun morph_illegal(): Number { be drop_A holds 0  be r holds tr(0) in A  return r }\n\
fun morph_legal(): Number { be r holds tr(0) in A  be drop_A holds 0  return r }\n\
fun place_illegal(): Number { be drop_A holds 0  be r holds .-> P { v 0 }  return r }\n\
fun place_legal(): Number { be r holds .-> P { v 0 }  be y holds r.v  be drop_A holds 0  return y }\n\
fun awaits_illegal(): Number { be drop_A holds 0  be sub holds w.awaits(prod)  return 0 }\n\
fun awaits_legal(): Number { be sub holds w.awaits(prod)  be drop_A holds 0  return 0 }\n\
fun handle_illegal(): Number { be p holds .-> P { v 0 }  be drop_A holds 0  be y holds p.v  return y }\n\
fun handle_legal(): Number { be p holds .-> P { v 0 }  be y holds p.v  be drop_A holds 0  return y }\n\
fun alias_illegal(): Number { be p holds .-> P { v 0 }  be q holds p  be drop_A holds 0  be y holds q.v  return y }\n"

let downstream_selftest () : string list =
  let prog = parse_src downstream_src in
  (* The place P created by place_* lives in Space A (the place->space binding the
     driver reads from the filesystem; constructed here for the parse-only pin). *)
  let place_space = Hashtbl.create 4 in
  Hashtbl.replace place_space "P" "A";
  (* Mimic tycheck for the awaits_* pin: register every `w.awaits(_)` call site in
     the global table as reaching Space A, keyed by the SAME loc names_expr sees. *)
  List.iter (function
    | S.TopFun fd ->
        List.iter (fun (n, l) ->
          if n = "awaits" then
            Hashtbl.replace S.awaits_site_table (l.S.start_line, l.S.start_col)
              ("A", 0, 0, 0))
          (Space_liveness.names_used_in_fun fd)
    | _ -> ()) prog;
  let imap = Space_liveness.import_map prog in
  Hashtbl.iter (fun p s -> Hashtbl.replace imap p s) place_space;
  let ftab = Space_liveness.func_table prog in
  let tarcs = Space_liveness.transitive_arcs ~place_space prog in
  let fails = ref [] in
  Hashtbl.iter (fun fname fd ->
      List.iter (fun (x, loc) ->
          let ds = Space_liveness.downstream_arcs ~imap ~ftab ~tarcs fd.S.fn_body loc in
          let legal = not (List.mem x ds) in
          let want_legal = ends_with fname "_legal" in
          let want_illegal = ends_with fname "_illegal" in
          if (want_legal || want_illegal) && legal <> want_legal then
            fails := Printf.sprintf "downstream: %s expected %s, got %s"
                       fname (if want_legal then "LEGAL" else "ILLEGAL")
                       (if legal then "LEGAL" else "ILLEGAL") :: !fails)
        (markers fd.S.fn_body))
    ftab;
  !fails

(* The `drop X` construct, wired end to end: parse REAL `drop` statements and run
   the whole-program check. A misplaced drop (an arc to X is still downstream)
   must be flagged WITH the downstream arc site; a well-placed drop must pass.
   This pins parser -> check; the loop / scope / transitive predicate is pinned
   separately by downstream_selftest, and is not re-verified here. *)
let drop_construct_src = "\
fun drop_ok(): Number { be w holds wire to space A  drop A  return 0 }\n\
fun drop_early(): Number {\n\
  drop A\n\
  be w holds wire to space A\n\
  return 0\n\
}\n"

let drop_construct_selftest () : string list =
  let prog = parse_src drop_construct_src in
  (* A is a declared Space here, so both drops pass the existence check and the
     reachability check is what decides legality. *)
  let errs = Space_liveness.check_drops ~declared:[ "A" ]
              ~place_space:(Hashtbl.create 1) prog in
  let fails = ref [] in
  let fail m = fails := m :: !fails in
  (match errs with
   | [ e ] ->
       if e.Space_liveness.de_space <> "A" then
         fail (Printf.sprintf "drop-construct: flagged Space %s, expected A"
                 e.Space_liveness.de_space);
       (match e.Space_liveness.de_fault with
        | Space_liveness.Still_live arc ->
            (* the site must land on the downstream arc, strictly after the drop *)
            if not (arc.S.start_line > e.Space_liveness.de_drop.S.start_line) then
              fail "drop-construct: arc site is not downstream of the drop"
        | Space_liveness.Unknown_space ->
            fail "drop-construct: A is declared but was reported unknown")
   | _ ->
       fail (Printf.sprintf "drop-construct: expected exactly 1 illegal drop, got %d"
               (List.length errs)));
  !fails

(* The domain half of the construct: `drop X` for an undeclared X is an
   unknown-Space error, NOT silently legal. A typo has no arc toward the
   misspelling, so the reachability check alone would wave it through; existence
   is validated first. A is declared, Zeta is not. *)
let drop_existence_src = "\
fun main(): Number { drop Zeta  return 0 }\n"

let drop_existence_selftest () : string list =
  let prog = parse_src drop_existence_src in
  match Space_liveness.check_drops ~declared:[ "A" ]
          ~place_space:(Hashtbl.create 1) prog with
  | [ e ] when e.Space_liveness.de_space = "Zeta"
            && (match e.Space_liveness.de_fault with
                | Space_liveness.Unknown_space -> true | _ -> false) -> []
  | [] -> [ "drop-existence: drop Zeta (undeclared) was accepted; the existence \
             check is missing" ]
  | _ -> [ "drop-existence: drop Zeta produced the wrong Space or fault" ]

(* The automatic reclaim (the mechanism): auto_reclaim_main_body inserts an SDrop
   for each Space at its last use. main touches A (wire) then does unrelated work,
   so A dies before the end and a reclaim must be inserted. This pins the analysis
   (the insertion point) independently of the runtime counter. *)
let auto_reclaim_src = "\
fun main(): Number { be w holds wire to space A  be x holds 1  return x }\n"

let auto_reclaim_selftest () : string list =
  let prog = parse_src auto_reclaim_src in
  let imap = Space_liveness.import_map prog in
  let ftab = Space_liveness.func_table prog in
  let tarcs = Space_liveness.transitive_arcs ~place_space:(Hashtbl.create 1) prog in
  let main_body =
    match List.find_opt
            (function S.TopFun fd -> fd.S.fn_name = "main" | _ -> false) prog with
    | Some (S.TopFun fd) -> fd.S.fn_body
    | _ -> [] in
  let body' =
    Space_liveness.auto_reclaim_main_body ~imap ~ftab ~tarcs [ "A" ] main_body in
  let has_drop_a = List.exists (function S.SDrop ("A", _) -> true | _ -> false) body' in
  if has_drop_a && List.length body' > List.length main_body then []
  else [ "auto-reclaim: expected an inserted SDrop(A) at A's last use" ]

let selftest () =
  let fails =
    graph_selftest () @ downstream_selftest () @ drop_construct_selftest ()
    @ drop_existence_selftest () @ auto_reclaim_selftest () in
  if fails = [] then (print_string "space_graph selftest OK\n"; exit 0)
  else begin
    List.iter (fun f -> Printf.eprintf "space_graph selftest FAILED: %s\n" f) fails;
    exit 1
  end

let () =
  if Array.length Sys.argv < 2 then selftest ()
  else
    let arg = Sys.argv.(1) in
    if Sys.is_directory arg then project arg
    else single arg (if Array.length Sys.argv > 2 then Sys.argv.(2) else "entry")
