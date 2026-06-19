(* yoner_emit_mlir.ml — executable that emits the MLIR Topos dialect from a Yon
 * source file.
 *
 * Usage:
 *   yoner_emit_mlir path/to/file.yon > out.mlir
 *
 * Pipeline:
 *   1. Lex + parse the Yon source
 *   2. Type check (Tycheck.check_program)
 *   3. Desugar to the Yon Core IR (Desugar.desugar_program)
 *   4. Emit the MLIR Topos dialect (Emit_mlir.emit_program)
 *
 * The output can be passed to topos-opt for validation:
 *   ./yoner_emit_mlir bank.yon | topos-opt
 *)

let () =
  let argv = Sys.argv in
  if Array.length argv < 2 then begin
    Printf.eprintf "Usage: %s <file.yon | directory>\n" argv.(0);
    exit 1
  end;
  let path = argv.(1) in
  (* A package is a directory. If `path` is a directory, all the .yon files in
   * it (recursively, e.g. under src/) share one scope (concatenated into a
   * single program). yon_modules/ is skipped here: dependencies are pulled in
   * explicitly via `import`, not by directory concatenation. If `path` is a
   * file, the classic behavior applies. *)
  let rec walk_yon (dir : string) : string list =
    Sys.readdir dir
    |> Array.to_list
    |> List.sort compare   (* deterministic order *)
    |> List.concat_map (fun entry ->
         let full = Filename.concat dir entry in
         if Sys.is_directory full then
           (if entry = "yon_modules" then [] else walk_yon full)
         else if Filename.check_suffix entry ".yon" then [full]
         else [])
  in
  let yon_files =
    if Sys.file_exists path && Sys.is_directory path then walk_yon path
    else [path]
  in
  let read_file fn =
    let ic = open_in fn in
    let s = really_input_string ic (in_channel_length ic) in
    close_in ic; s in
  (* Resolution of `import "path"`. A line `import "X"` brings the package X (a
   * directory) into scope. X is resolved as:
   *   - "./sub" or "../sub": relative to the current file's directory
   *   - "host/user/repo": a git dependency, looked up in ./yon_modules/<repo>
   * Imported files are loaded transitively (with a cycle guard). The import
   * lines are removed from the source before parsing. *)
  let import_re = Str.regexp "^[ \t]*import[ \t]+\"\\([^\"]*\\)\"[ \t]*$" in
  let strip_imports (src : string) : string * string list =
    let lines = String.split_on_char '\n' src in
    let imports = ref [] in
    let kept = List.map (fun line ->
      if Str.string_match import_re line 0 then begin
        imports := Str.matched_group 1 line :: !imports;
        ""  (* remove the import line, keep the line number *)
      end else line
    ) lines in
    (String.concat "\n" kept, List.rev !imports)
  in
  let dir_of f = if Sys.is_directory f then f else Filename.dirname f in
  let resolve_import (base_dir : string) (spec : string) : string list =
    let target =
      if String.length spec >= 2 && (String.sub spec 0 2 = "./"
         || (String.length spec >= 3 && String.sub spec 0 3 = "../"))
      then Filename.concat base_dir spec               (* relativo *)
      else
        (* git dependency: ./yon_modules/<last segment> *)
        let segs = String.split_on_char '/' spec in
        let repo = List.nth segs (List.length segs - 1) in
        Filename.concat (Filename.concat base_dir "yon_modules") repo
    in
    if Sys.file_exists target && Sys.is_directory target then
      Sys.readdir target |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".yon")
      |> List.sort compare
      |> List.map (fun f -> Filename.concat target f)
    else if Sys.file_exists target then [target]
    else begin
      Printf.eprintf "unresolved import: \"%s\" (searched in %s)\n" spec target;
      exit 4
    end
  in
  (* transitive collection of the files, with import-stripped sources.
   * Each file is tagged with its MODULE: "" for the local project files
   * (passed on the command line), or the dependency name (last segment of the
   * import spec) for files pulled in via `import "dep"`. The module name is
   * used to prefix the file's top-level declarations (Strato 2: namespaces). *)
  let module_name_of_spec (spec : string) : string =
    (* "./sub" -> "sub"; "host/user/repo" -> "repo"; "geometria" -> "geometria" *)
    let segs = String.split_on_char '/' spec
               |> List.filter (fun s -> s <> "" && s <> "." && s <> "..") in
    match List.rev segs with
    | last :: _ -> Filename.remove_extension last
    | [] -> spec
  in
  let loaded : (string, string * string) Hashtbl.t = Hashtbl.create 16 in
  let canon_path fn = try Filename.concat (Sys.getcwd ()) fn with _ -> fn in
  let rec load modname fn =
    let canon = canon_path fn in
    if Hashtbl.mem loaded canon then ()
    else begin
      let raw = read_file fn in
      let (stripped, imports) = strip_imports raw in
      Hashtbl.replace loaded canon (modname, stripped);
      List.iter (fun spec ->
        let files = resolve_import (dir_of fn) spec in
        let m = module_name_of_spec spec in
        List.iter (load m) files
      ) imports
    end
  in
  (* Project mode (filesystem as declaration): a directory carrying yon.toml is
   * a package: the directory IS the source tree. Each .yon file is parsed as
   * itself (no text reconstruction); the worlds come from the toml as AST
   * nodes and each directory becomes a space, both prepended below. A
   * directory WITHOUT yon.toml and the single-file path keep classic behavior. *)
  let is_project_dir =
    Sys.file_exists path && Sys.is_directory path
    && Package_layout.is_project ~dir:path
  in
  let project_wm =
    if is_project_dir then begin
      let manifest_path = Filename.concat path Package_layout.manifest_name in
      if Sys.file_exists manifest_path then
        (try Some (Manifest.parse_file manifest_path)
         with Manifest.Manifest_error msg ->
           Printf.eprintf "MANIFEST ERROR: %s\n" msg; exit 3)
      else None
    end else None
  in
  if is_project_dir then
    (* load every .yon under the package root; each is parsed on its own by the
       common path below, contributing its own top_decls. *)
    List.iter (fun u -> load "" u.Package_layout.ul_path)
      (Package_layout.layout ~root:path)
  else
    List.iter (load "") yon_files;
  (* The order: imported files (dependencies) first, main files after. We use
   * the reverse insertion order: the leaves loaded first. *)
  let all_sources = Hashtbl.fold (fun fn (m, src) acc -> (fn, m, src) :: acc) loaded [] in
  let all_sources = List.sort (fun (a,_,_) (b,_,_) -> compare a b) all_sources in
  (* parse each file (import-stripped source), accumulate the top_decls,
   * prefixing each imported module's declarations with `module::`. *)
  let internals = ref [] in
  (* Project mode: collect each place's world and each file's wire targets while
     the file is parsed below -- no second parse. The place->world map needs the
     space (directory) of the file; key it by the same canon path as `loaded`. *)
  let pw_pairs = ref [] in
  let wire_errs = ref [] in
  let place_acc = ref [] in   (* (place_name, file, space) for every project place *)
  let main_files = ref [] in  (* files that define `fun main` *)
  let space_of_path =
    match project_wm with
    | Some _ ->
        let t = Hashtbl.create 16 in
        List.iter (fun u ->
          Hashtbl.replace t (canon_path u.Package_layout.ul_path)
            u.Package_layout.ul_space)
          (Package_layout.layout ~root:path);
        t
    | None -> Hashtbl.create 1
  in
  let prog =
    List.concat_map (fun (filename, modname, src) ->
      let lexbuf = Lexing.from_string src in
      Lexing.set_filename lexbuf filename;
      try
        Parser_state.reset ();
        let p = Parser.program Lexer.token lexbuf in
        let synth = Parser_state.drain () in
        let decls = synth @ p in
        if modname = "" then begin
          (match project_wm with
           | Some wm when Hashtbl.mem space_of_path filename ->
               let sp = Hashtbl.find space_of_path filename in
               (* entrypoint collection: every project file (root included).
                  Record each declared place (name, file, space) and whether the
                  file defines `main`, so the Entry constraints below can be
                  checked on the whole project. *)
               List.iter (function
                 | Surface_ast.TopPlace pd ->
                     place_acc := (pd.Surface_ast.pd_name, filename, sp) :: !place_acc
                 | Surface_ast.TopFun fd when fd.Surface_ast.fn_name = "main" ->
                     main_files := filename :: !main_files
                 | _ -> ()) decls;
               (* place->world + wire boundary: only for files whose space is
                  in a world (root files inherit no world). *)
               let sender_world = Manifest.world_of_space wm sp in
               (match sender_world with
                | Some w ->
                    List.iter (function
                      | Surface_ast.TopPlace pd ->
                          pw_pairs := (pd.Surface_ast.pd_name, w) :: !pw_pairs
                      | _ -> ()) decls
                | None -> ());
               wire_errs :=
                 Manifest.check_targets wm ~sender_world
                   (Manifest.import_targets decls) @ !wire_errs
           | _ -> ());
          decls
        end
        else begin
          internals := Module_prefix.internal_qualified_names modname decls @ !internals;
          Module_prefix.prefix_decls modname decls
        end
      with
      | Parser.Error ->
          let p = lexbuf.lex_curr_p in
          Printf.eprintf "Parse error at %s:%d:%d\n" p.pos_fname
            p.pos_lnum (p.pos_cnum - p.pos_bol);
          exit 2
      | Failure msg ->
          Printf.eprintf "Lex/parse failure in %s: %s\n" filename msg;
          exit 2
    ) all_sources
  in
  (* In project mode the worlds and spaces are not in any .yon file: the worlds
     come from the toml (as native TopWorld nodes) and each directory is a
     space (a native TopSpace). Prepend them to the parsed place files -- no
     text, no re-parse. *)
  let prog =
    match project_wm with
    | Some wm ->
        Manifest.world_decls wm @ Package_layout.space_decls ~root:path @ prog
    | None -> prog
  in
  (* The entrypoint is the place `Entry`: declared once, in the project root,
     and the file that declares it carries `main`. The name defaults to "Entry"
     and may be set by [package] entry. In project mode these four conditions
     are enforced; outside project mode `main` keeps its top-level meaning. *)
  (match project_wm with
   | None -> ()
   | Some wm ->
       let entry_name = match wm.Manifest.pkg_entry with Some e -> e | None -> "Entry" in
       let entries = List.filter (fun (n, _, _) -> n = entry_name) !place_acc in
       let fail msg = Printf.eprintf "ENTRYPOINT ERROR: %s\n" msg; exit 3 in
       (match entries with
        | [] ->
            fail (Printf.sprintf
              "the project declares no entrypoint: add `place %s` in the project \
               root, in the file that defines main" entry_name)
        | _ :: _ :: _ ->
            fail (Printf.sprintf
              "the entrypoint place `%s` must be unique; it is declared %d times"
              entry_name (List.length entries))
        | [ (_, file, sp) ] ->
            if sp <> "" then
              fail (Printf.sprintf
                "the entrypoint place `%s` must live in the project root, not in \
                 space `%s`" entry_name sp)
            else if not (List.mem file !main_files) then
              fail (Printf.sprintf
                "the entrypoint place `%s` must contain main: its file defines no \
                 `fun main`" entry_name)));
  (* Resolve selective-import aliases (geo_scale -> geometria::scale), then
   * mangle qualified names (a::b -> a_NS_b) so MLIR symbols are valid. *)
  (* Wire subscriptions: load the SIGNATURES of every module named in a
     cross-Space import (the import is nominal, the code lives in the
     other process; the producer check needs the declared return type).
     Resolution: sibling <module>.yon, then yon_modules/<module>/. *)
  List.iter (function
    | Surface_ast.TopImportFrom (m, _, _, _) ->
        let base = Filename.dirname (List.hd yon_files) in
        let candidates =
          let sib = Filename.concat base (m ^ ".yon") in
          if Sys.file_exists sib then [sib]
          else
            let dir = Filename.concat (Filename.concat base "yon_modules") m in
            if Sys.file_exists dir && Sys.is_directory dir then
              Sys.readdir dir |> Array.to_list
              |> List.filter (fun f -> Filename.check_suffix f ".yon")
              |> List.map (Filename.concat dir)
            else []
        in
        List.iter (fun fn ->
          try
            let raw = read_file fn in
            let (stripped, _) = strip_imports raw in
            let lexbuf = Lexing.from_string stripped in
            Lexing.set_filename lexbuf fn;
            Parser_state.reset ();
            let p = Parser.program Lexer.token lexbuf in
            let _ = Parser_state.drain () in
            List.iter (function
              | Surface_ast.TopFun fd ->
                  Tycheck.register_remote_signature
                    (m ^ "::" ^ fd.Surface_ast.fn_name) fd.Surface_ast.fn_return;
                  Tycheck.register_remote_signature
                    fd.Surface_ast.fn_name fd.Surface_ast.fn_return
              | _ -> ()) p
          with _ -> ()) candidates
    | _ -> ()) prog;
  let prog = Module_prefix.lower_cross_space prog in
  let prog = Module_prefix.resolve_aliases prog in
  Module_prefix.check_visibility !internals prog;
  let prog = Module_prefix.mangle_decls prog in
  (* View declarations expand to synthetic place + constructor BEFORE
     tycheck, so the view name resolves as a normal function. *)
  let prog = Desugar.expand_views prog in
  (* The place inherits its space's world (filesystem -> toml): bind each
     unannotated place to the world of its directory before type-checking, so a
     multi-world project resolves structurally instead of relying on the
     unique-world heuristic (which cannot disambiguate across worlds). Project
     mode only; each file is re-parsed alone to find the place names it
     declares and the space (directory) it lives in. *)
  let prog =
    match project_wm with
    | Some _ ->
        let pw : (string, string) Hashtbl.t = Hashtbl.create 16 in
        List.iter (fun (n, w) -> Hashtbl.replace pw n w) !pw_pairs;
        Manifest.assign_place_worlds (fun n -> Hashtbl.find_opt pw n) prog
    | None -> prog
  in
  let cr = Tycheck.check_program prog in
  if cr.Tycheck.cr_errors <> [] then begin
    List.iter (fun e ->
      Printf.eprintf "TYPE ERROR: %s\n" (Tycheck.error_to_string e))
      cr.Tycheck.cr_errors;
    exit 3
  end;
  (* World boundary (yon.toml [world] sections): a wire may only reach a space
   * in the sender's own world. Project mode only -- the manifest lives at the
   * project root. Reuses the parsed program and the same exit-3 channel as
   * type errors. Opt-in: with no [world] declared, the checks are vacuous. *)
  (match project_wm with
   | None -> ()
   | Some wm ->
      (* D (orphan spaces) is global, from the whole program; B + C were
         collected per file during parsing (wire_errs). No second parse. *)
      (match Manifest.check_program wm prog @ List.rev !wire_errs with
       | [] -> ()
       | errs ->
           List.iter (fun (loc, msg) ->
             if loc.Surface_ast.start_line > 0 then
               Printf.eprintf "WORLD BOUNDARY ERROR: %d:%d: %s\n"
                 loc.Surface_ast.start_line loc.Surface_ast.start_col msg
             else
               Printf.eprintf "WORLD BOUNDARY ERROR: %s\n" msg
           ) errs;
           exit 3));
  (* Propagate the inferred place->world binding to codegen. check_program runs
   * infer_place_worlds to resolve each unannotated place's world (e.g. Order in
   * Commerce via `Code is Order` in the world), but keeps that rewrite internal
   * -- the desugar otherwise sees the original __INFER marker, which the backend
   * maps to __Default. Re-running the pass here is idempotent (the tycheck above
   * already validated it: a real inference failure exited at cr_errors), so the
   * Error arm is unreachable and kept only to stay total. With this, a place in
   * a world-bearing folder lands in that world instead of __Default. *)
  let prog =
    match Tycheck.infer_place_worlds prog with
    | Ok p -> p
    | Error _ -> prog
  in
  let desugared = Desugar.desugar_program ~env:(Some cr.Tycheck.cr_env) prog in
  (* Erase type-level (universe-typed) parameters before codegen: a type
     argument is a compile-time citizen and must not reach the carrier/backend
     as runtime data. Coordinated drop of binders and matching call arguments;
     this keeps the carrier functor within its domain (no TyType reaches emit). *)
  let desugared =
    try Type_erase.erase desugared
    with Type_erase.Higher_order_type_param fname ->
      Printf.eprintf
        "TYPE ERROR: function `%s` has type parameters and is used outside a \
         direct call (passed as a value, aliased, or partially applied). \
         Higher-order type-argument erasure is not lowered, so this is \
         rejected at compile time rather than miscompiled.\n" fname;
      exit 3
  in
  (* TEMP DIAGNOSTIC: dump the Core IR under YON_DUMP_CORE=1 *)
  (try if Sys.getenv "YON_DUMP_CORE" = "1" then begin
    List.iter (fun (name, body) ->
      Printf.eprintf "=== %s ===\n%s\n" name (Pretty.pp_term body))
      desugared.Desugar.functions;
    (match desugared.Desugar.main with
     | Some m -> Printf.eprintf "=== main ===\n%s\n" (Pretty.pp_term m)
     | None -> ())
  end with Not_found -> ());
  (* Extract the view decls from the program and propagate them to
   * emit_program via a global setter. *)
  Emit_mlir.set_views_list (List.filter_map (function
    | Surface_ast.TopView vd -> Some (vd.Surface_ast.vw_name, vd.Surface_ast.vw_of)
    | _ -> None
  ) prog);
  let mlir_output = Emit_mlir.emit_program desugared in
  print_string mlir_output
