(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* eval_runner.ml — run a .yon file through the OCaml interpreter and print the
 * final numeric value.
 *
 * Used by the cross-validation phase to compare the interpreter's semantics
 * with the native binary produced by the MLIR pipeline.
 *
 * Exit-code convention (mirroring the compiler's convention in emit_main):
 *   - number  -> arrotondato a int e modulo 256
 *   - boolean -> 0 (false) o 1 (true)
 *   - proposition -> 0 (present) | 1 (absent) | 2 (unknown)
 *   - text / section -> 0 (success placeholder)
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
 * run, together with the place->space census the desugar needs and the merged
 * source text (for the imperative/effectful refusal check below).
 *
 * This mirrors the driver's project assembly (yoner_emit_mlir.ml) but keeps only
 * the transforms the evaluator needs -- no codegen (no cross-space lowering, no
 * space graph, no auto-reclaim). Every transform is the SAME library function the
 * driver calls (Manifest / Package_layout / Desugar / Tycheck), so each step stays
 * single-sourced; this is a subset of the driver, not a reimplementation of it. *)
let assemble_project (root : string)
    : Surface_ast.program * (string * string) list * string =
  let wm = Manifest.parse_file (Filename.concat root Package_layout.manifest_name) in
  let units = Package_layout.layout ~root in
  let place_to_space = ref [] in
  let pw_pairs = ref [] in       (* (place name, world of its space) *)
  let sources = ref [] in
  let merged =
    List.concat_map (fun (u : Package_layout.unit_loc) ->
      let src = read_file u.Package_layout.ul_path in
      sources := src :: !sources;
      let lexbuf = Lexing.from_string src in
      Lexing.set_filename lexbuf u.Package_layout.ul_path;
      Parser_state.reset ();
      let p = Parser.program Lexer.token lexbuf in
      (* place-member funs live inside `place Entry { ... }`; the parser stages
         them into Parser_state, drained here into top-level decls -- the same
         lift the driver performs. *)
      let decls = Parser_state.drain () @ p in
      let sp = u.Package_layout.ul_space in
      List.iter (function
        | Surface_ast.TopPlace pd ->
            if sp <> "" then
              place_to_space := (pd.Surface_ast.pd_name, sp) :: !place_to_space;
            (match Manifest.world_of_space wm sp with
             | Some w -> pw_pairs := (pd.Surface_ast.pd_name, w) :: !pw_pairs
             | None -> ())
        | _ -> ()) decls;
      decls
    ) units
  in
  (* Prepend the toml worlds and the filesystem spaces (neither lives in a .yon
     file), then drop the Entry package container: it is a validated marker, not a
     runnable place, and keeping it would demand a world it has none of. *)
  let entry_name =
    match wm.Manifest.pkg_entry with Some e -> e | None -> "Entry" in
  let prog = Manifest.world_decls wm @ Package_layout.space_decls ~root @ merged in
  let prog = Manifest.remove_entrypoint_container ~entry_name prog in
  (* Bind each place to the world of its directory (filesystem -> toml), so a
     place resolves structurally instead of via the single-world heuristic. *)
  let pw : (string, string) Hashtbl.t = Hashtbl.create 16 in
  List.iter (fun (n, w) -> Hashtbl.replace pw n w) !pw_pairs;
  let prog =
    Manifest.assign_place_worlds
      ~world_of_space:(Manifest.world_of_space wm)
      (fun n -> Hashtbl.find_opt pw n) prog in
  let prog = Desugar.expand_views prog in
  let prog = Tycheck.elaborate_id_sugar prog in
  (prog, List.rev !place_to_space, String.concat "\n" (List.rev !sources))

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
       * loops do not iterate, Space mutations and stream sends do not take effect, so it
       * would return a WRONG value SILENTLY. Reject such programs rather than lie: if the
       * source uses one of these constructs, exit with a distinct EVAL-INCOMPLETE code
       * instead of a value the evaluator cannot vouch for. (Line comments stripped first;
       * a keyword left in a block comment only over-refuses, which is safe.) *)
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
      let dr = Desugar.desugar_program ~env:(Some cr.Tycheck.cr_env)
                 ~place_to_space prog in
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
