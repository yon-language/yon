(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* eval_runner.ml — run a .yon file through the OCaml interpreter and print the
 * final numeric value.
 *
 * Used by the cross-validation phase to compare the interpreter's semantics
 * with the native binary produced by the MLIR pipeline.
 *
 * Exit code: the numeric value extracted from the final term
 *   (deep_extract), taken modulo 256 into 0..255; when no numeric
 *   value can be extracted, 0.
 *
 * Output stdout: a single line with "EXIT <n>".
 * Stderr: debug trace if the --trace flag is passed.
 *)

open Ast

(* Extract the numeric value from the final term.
 * Numeric literals are encoded as Var "__num_N" by the desugar. *)
let try_extract_number (t : term) : float option =
  match t with
  | Var s when String.length s > 6 && String.sub s 0 6 = "__num_" ->
      let nstr = String.sub s 6 (String.length s - 6) in
      (try Some (float_of_string nstr) with _ -> None)
  | _ -> None

(* Heyting/proposition encoding: __heyt_present|absent|unknown. *)
let try_extract_heyt (t : term) : int option =
  match t with
  | Var "__heyt_present" -> Some 0
  | Var "__heyt_absent"  -> Some 1
  | Var "__heyt_unknown" -> Some 2
  | _ -> None

(* Boolean: __bool_true | __bool_false. *)
let try_extract_bool (t : term) : int option =
  match t with
  | Var "__bool_true"  -> Some 1
  | Var "__bool_false" -> Some 0
  | _ -> None

(* Recursively search the term for an extractable atomic value.
 * Useful when main returns a Pair or another structure but the value of
 * interest is the first numeric one. *)
let rec deep_extract (t : term) : int option =
  match try_extract_number t with
  | Some f -> Some (int_of_float f)
  | None ->
      match try_extract_heyt t with
      | Some n -> Some n
      | None ->
          match try_extract_bool t with
          | Some n -> Some n
          | None ->
              (* Try the children for Pair, App, etc. *)
              match t with
              | Pair (a, b) ->
                  (match deep_extract a with
                   | Some _ as r -> r
                   | None -> deep_extract b)
              | App (f, _) -> deep_extract f
              | Fst x | Snd x -> deep_extract x
              | _ -> None

let usage () : 'a =
  Printf.eprintf "Usage: eval_runner [--trace] <file.yon>\n";
  exit 2

(* Inline parse function (not exported from Main). *)
let parse_string (source : string) : (Surface_ast.program, string) result =
  let lexbuf = Lexing.from_string source in
  try
    Ok (Parser.program Lexer.token lexbuf)
  with
  | Parser.Error ->
      let p = lexbuf.Lexing.lex_curr_p in
      Error (Printf.sprintf "Parse error at line %d, column %d"
               p.Lexing.pos_lnum
               (p.Lexing.pos_cnum - p.Lexing.pos_bol))
  | Failure m -> Error ("Lex error: " ^ m)
  | Lexer.Lexer_error msg -> Error ("Lexer error: " ^ msg)

let read_file (fn : string) : string =
  let ic = open_in fn in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic; s

(* Assemble a project DIRECTORY into a surface program the pure interpreter can
 * run, with the source text of the user files (for the imperative/effectful
 * refusal check below). No codegen: no cross-space lowering, no space graph,
 * no auto-reclaim. *)
let assemble_project (root : string)
    : Surface_ast.program * (string * string) list * string =
  (* The SAME assembly the language server and the checker run (Project.load,
     Project.prepare_for_typecheck): the prelude rides in, so the oracle sees
     the language the compiler sees, the library included. *)
  let l = Project.load ~root () in
  Project.record_file_spaces l;
  let prog = Project.prepare_for_typecheck l in
  let prog = Tycheck.elaborate_id_sugar prog in
  (* the text kept here is the USER sources only, for the check on the source
     text; the funs of the prelude main reaches are checked on the program
     itself (unfaithful_reached), since the reducer unfolds them too *)
  let prelude = List.map fst (Project.prelude_sources ()) in
  let user =
    List.filter (fun (f : Project.file_info) -> not (List.mem f.Project.fi_path prelude))
      l.Project.files in
  (prog, [], String.concat "\n" (List.map (fun (f : Project.file_info) ->
                                    read_file f.Project.fi_path) user))

(* The funs main reaches through its calls, over the whole program, and the
 * first of them whose body holds what the pure interpreter does not run, with
 * the reason: a loop, a producer, a spawn, a wire; or a cell written inside a
 * block, which the reducer writes in the block only, so the value after it is
 * the old one. A fun of a house carries its qualified name (Home__f); a bare
 * call inside the house reaches it too. *)
let unfaithful_reached (prog : Surface_ast.program) : (string * string) option =
  let open Surface_ast in
  let funs = Hashtbl.create 256 in
  List.iter (function TopFun fd -> Hashtbl.replace funs fd.fn_name fd | _ -> ()) prog;
  let rec names_e acc e =
    let acc = match e with
      | ECall (n, _, _) | EVar (n, _) -> n :: acc
      | _ -> acc in
    let (es, bs) = sub_exprs e in
    List.fold_left names_ss (List.fold_left names_e acc es) bs
  and names_s acc s =
    let acc = match s with SCall (n, _, _) -> n :: acc | _ -> acc in
    List.fold_left names_ss (List.fold_left names_e acc (stmt_exprs s)) (sub_stmts s)
  and names_ss acc ss = List.fold_left names_s acc ss in
  let rec unfaithful_e e =
    (match e with EProduce _ | ESpawn _ | EWireTo _ -> true | _ -> false)
    || (let (es, bs) = sub_exprs e in
        List.exists unfaithful_e es || List.exists unfaithful_ss bs)
  and unfaithful_s s =
    (match s with
     | SWhile _ | SIter _ | SForEvery _ | SInSequence _ | SRepeat _ | SForever _
     | SProduce _ | SEmit _ | SPromote _ -> true
     | _ -> false)
    || List.exists unfaithful_e (stmt_exprs s)
    || List.exists unfaithful_ss (sub_stmts s)
  and unfaithful_ss ss = List.exists unfaithful_s ss in
  let rec writes_ss ss =
    List.exists (fun s ->
        (match s with SAssignHolds _ | SAssignBecomes _ -> true | _ -> false)
        || List.exists writes_ss (sub_stmts s)) ss in
  let rec written_in_block ss =
    List.exists (fun s ->
        List.exists writes_ss (sub_stmts s) || List.exists written_in_block (sub_stmts s)) ss in
  let resolve (caller : fun_decl) n =
    (* the house first, as a bare name inside it is read *)
    let in_house = match caller.fn_home with
      | Some h -> Hashtbl.find_opt funs (h ^ "__" ^ n)
      | None -> None in
    match in_house with
    | Some fd -> Some fd
    | None -> Hashtbl.find_opt funs n in
  let seen = Hashtbl.create 64 in
  let rec visit (fd : fun_decl) =
    let key = fd.fn_name in
    if Hashtbl.mem seen key then None
    else begin
      Hashtbl.replace seen key ();
      if unfaithful_ss fd.fn_body then
        Some (key, "uses an imperative/effectful construct (loop / produce / spawn / wire)")
      else if written_in_block fd.fn_body then
        Some (key, "writes a cell inside a block, and the pure interpreter keeps that write \
                    inside the block, so it would read the old value after it")
      else
        List.fold_left (fun found n ->
            match found with
            | Some _ -> found
            | None ->
                (match resolve fd n with Some g -> visit g | None -> None))
          None (List.rev (names_ss [] fd.fn_body))
    end in
  let mains = List.filter_map (function
      | TopFun fd when fd.fn_name = "main" -> Some fd | _ -> None) prog in
  List.fold_left (fun found m -> match found with Some _ -> found | None -> visit m)
    None mains

let () =
  let args = Array.to_list Sys.argv in
  let (trace, filename) =
    match args with
    | _ :: "--trace" :: [f] -> (true, f)
    | _ :: [f] -> (false, f)
    | _ -> usage ()
  in
  (* A directory carrying yon.toml is a project: assemble it the way the driver
     does (subset). A plain .yon file keeps the classic single-file path. *)
  let is_project =
    (try Sys.is_directory filename with Sys_error _ -> false)
    && Package_layout.is_project ~dir:filename
  in
  let parsed : (Surface_ast.program * (string * string) list * string, string) result =
    if is_project then
      (try
         let (prog, pts, src) = assemble_project filename in
         Ok (prog, pts, src)
       with
       | Parser.Error -> Error "Parse error in project"
       | Manifest.Manifest_error m -> Error ("Manifest error: " ^ m)
       | Failure m -> Error ("Lex/assembly error: " ^ m)
       | Sys_error m -> Error ("File error: " ^ m))
    else
      let source =
        try read_file filename
        with Sys_error e ->
          Printf.eprintf "FILE ERROR: %s\n" e; exit 2
      in
      (match parse_string source with
       | Error e -> Error e
       | Ok prog -> Ok (prog, [], source))
  in
  match parsed with
  | Error e ->
      Printf.eprintf "PARSE ERROR: %s\n" e;
      exit 3
  | Ok (prog, place_to_space, source) ->
      (* Type check first; if errors, abort. *)
      let cr = Tycheck.check_program prog in
      if cr.cr_errors <> [] then begin
        List.iter (fun err ->
          Printf.eprintf "TYPE ERROR: %s\n" (Tycheck.error_to_string err))
          cr.cr_errors;
        exit 4
      end;
      (* The pure evaluator does NOT faithfully run the imperative / effectful layer:
       * loops do not iterate, writes of cells and stream sends do not take effect, so it
       * would return a WRONG value SILENTLY. Reject such programs rather than lie: if the
       * source uses one of these constructs, exit with a distinct EVAL-INCOMPLETE code
       * instead of a value the evaluator cannot vouch for. (Line comments stripped first;
       * a keyword left in a block comment only over-refuses, which is safe.) *)
      (* A cell written inside a `scope` is a write through a captured handle at
       * runtime, and it is seen after the block. In the kernel a cell write is a
       * new binding of its name, and a binding made inside the block does not
       * leave it: the reducer would read the value from before the block.
       * Refuse rather than return it. Every block of every statement is
       * visited (Surface_ast.sub_stmts), at any depth. *)
      let open Surface_ast in
      let rec writes_cell (ss : stmt list) =
        List.exists (fun s ->
          (match s with SAssignHolds _ | SAssignBecomes _ -> true | _ -> false)
          || List.exists writes_cell (sub_stmts s)) ss in
      let rec scope_writes_cell (ss : stmt list) =
        List.exists (fun s ->
          (match s with SScope (_, b, _, _) -> writes_cell b | _ -> false)
          || List.exists scope_writes_cell (sub_stmts s)) ss in
      if List.exists (function
           | TopFun fd -> scope_writes_cell fd.fn_body
           | _ -> false) prog
      then begin
        Printf.eprintf
          "EVAL INCOMPLETE: a cell is written inside a `scope`; the pure \
           interpreter binds the new value inside the block only, so it would \
           read the old value after it; refusing to emit a value rather than \
           return a wrong one.\n";
        print_string "EVAL INCOMPLETE\n";
        exit 6
      end;
      (* The same holds for every fun main reaches, the prelude's included: the
       * reducer unfolds a library fun as it unfolds the program's own, so a
       * loop in its body is evaluated as wrongly. Follow the calls from main
       * over the whole program and refuse at the first fun whose body holds
       * a construct the pure interpreter does not run. *)
      (match unfaithful_reached prog with
       | Some (f, why) ->
           Printf.eprintf
             "EVAL INCOMPLETE: main reaches `%s`, whose body %s; refusing to emit a value \
              rather than return a wrong one.\n" f why;
           print_string "EVAL INCOMPLETE\n";
           exit 6
       | None -> ());
      let no_line_comments = Str.global_replace (Str.regexp "//[^\n]*") "" source in
      let unfaithful =
        Str.regexp "\\b\\(iter\\|while\\|every\\|sequence\\|repeat\\|forever\\|produce\\|emit\\|spawn\\|promote\\|wire\\)\\b" in
      (try
         let _ = Str.search_forward unfaithful no_line_comments 0 in
         Printf.eprintf
           "EVAL INCOMPLETE: the program uses an imperative/effectful construct (loop / \
            produce / spawn / wire) that the pure interpreter does not faithfully evaluate; \
            refusing to emit a value rather than return a wrong one.\n";
         print_string "EVAL INCOMPLETE\n";
         exit 6
       with Not_found -> ());
      let dr =
        try Desugar.desugar_program ~env:(Some cr.Tycheck.cr_env) ~place_to_space prog
        with
        | Desugar.Path_not_known msg ->
            Printf.eprintf "EVAL INCOMPLETE: %s\n" msg;
            print_string "EVAL INCOMPLETE\n";
            exit 6
 in
      (* Mount all the needed hooks, the same configuration as run_example.
       * Without them the stdlib (List/Map/Stream/Heyting) stays stuck and the
       * eval does not reproduce the compiler's semantics. *)
      Builtins.heyting_hook := Heyting.try_reduce_heyt;
      Builtins.stdlib_hook := Stdlib_runtime.try_reduce_stdlib;
      Reduce.world_tag_setter := Stdlib_runtime.set_current_world_tag;
      Reduce.full_reduce_hook :=
        (fun ctx t -> Builtins.reduce_with_builtins ctx t);
      (match dr.main with
       | None ->
           Printf.eprintf "NO MAIN\n"; exit 5
       | Some term ->
           let ctx = Builtins.with_builtins dr.ctx in
           let final = Builtins.reduce_with_builtins ~fuel:10000 ctx term in
           if trace then
             Printf.eprintf "FINAL TERM: %s\n" (Pretty.pp_compact final);
           match deep_extract final with
           | Some n ->
               (* Convert to exit code (0-255). *)
               let exit_code =
                 let m = ((n mod 256) + 256) mod 256 in
                 m
               in
               Printf.printf "EXIT %d\n" exit_code
           | None ->
               (* no extractable numeric value: assume 0
                * (matching the compiler convention for text/section
                * returns). *)
               if trace then
                 Printf.eprintf "[no extractable value, assuming 0]\n";
               Printf.printf "EXIT 0\n")
