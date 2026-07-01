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
  (* Filesystem-derived topos structure (Agent M). Captured per file at
     parse-assembly time, where the file's space tag (ul_space) is still known;
     the merged program below no longer carries per-file origin. *)
  let places_by_space = ref [] in  (* (space, place_decl) for every project TopPlace *)
  let topos_space = ref [] in      (* (topos_name, space) for every TopTopos file *)
  let topos_count = ref [] in      (* (space, n) topos-file count per space *)
  (* Agent ENF: mandatory file-layout violations, collected per file in the
     loop below (project mode only). One message per rule violation; printed and
     exit-3'd after the loop, matching the check_one_topos_per_space convention.
     Collecting here (not from the merged program) keeps per-file origin —
     filename/decls are in scope in the per-file parse. *)
  let layout_errs = ref [] in
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
               (* Filesystem-derived topos structure (Agent M): in this same
                  pass capture, per space, (a) the full place_decl of every
                  TopPlace — these become the topos's tp_objects — and (b) each
                  TopTopos's name->space binding plus a per-space topos-file
                  count (for one-topos-per-space enforcement). sp is "" for root
                  files, which belong to no space/topos. *)
               let local_topos_in_file = ref 0 in
               List.iter (function
                 | Surface_ast.TopPlace pd ->
                     place_acc := (pd.Surface_ast.pd_name, filename, sp) :: !place_acc;
                     if sp <> "" then
                       places_by_space := (sp, pd) :: !places_by_space
                 | Surface_ast.TopTopos td ->
                     if sp <> "" then begin
                       topos_space := (td.Surface_ast.tp_name, sp) :: !topos_space;
                       incr local_topos_in_file
                     end
                 | Surface_ast.TopFun fd when fd.Surface_ast.fn_name = "main" ->
                     main_files := filename :: !main_files
                 | _ -> ()) decls;
               if sp <> "" && !local_topos_in_file > 0 then
                 topos_count := (sp, !local_topos_in_file) :: !topos_count;
               (* Agent ENF: mandatory file-layout checks. Gather this file's
                  per-file facts (basename, declared place names, whether it
                  declares a topos) HERE, where filename + decls are in scope,
                  and run them through Manifest.check_file_layout. Applies to
                  every project file (root and space files alike): the basename
                  is the filename without ".yon"; the rules themselves exempt
                  zero-place files. Project mode only (this whole branch is
                  gated on project_wm = Some wm). *)
               let basename =
                 Filename.remove_extension (Filename.basename filename) in
               let file_place_names =
                 List.filter_map (function
                   | Surface_ast.TopPlace pd -> Some pd.Surface_ast.pd_name
                   | _ -> None) decls in
               let file_has_topos =
                 List.exists (function
                   | Surface_ast.TopTopos _ -> true
                   | _ -> false) decls in
               layout_errs :=
                 Manifest.check_file_layout ~basename
                   ~place_names:file_place_names ~has_topos:file_has_topos
                 @ !layout_errs;
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
      | Lexer.Lexer_error msg ->
          Printf.eprintf "Lexer error in %s: %s\n" filename msg;
          exit 2
    ) all_sources
  in
  (* Agent ENF: mandatory file-layout enforcement. The per-file loop above has
     now populated layout_errs (it ran eagerly: List.concat_map forces every
     element). Project mode only: layout_errs is only ever appended to inside
     the `project_wm = Some wm` branch, so for a single-file `EMIT some.yon`
     (project_wm = None) it stays empty and this is vacuous — the negative-test
     harness runs single files and is exempt. Collect ALL violations across the
     project's files, print them, exit 3 — matching check_one_topos_per_space. *)
  (match List.rev !layout_errs with
   | [] -> ()
   | errs ->
       List.iter (fun m -> Printf.eprintf "TOPOS LAYOUT ERROR: %s\n" m) errs;
       exit 3);
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
  let project_entry_name =
    match project_wm with
    | None -> None
    | Some wm ->
        Some (match wm.Manifest.pkg_entry with Some e -> e | None -> "Entry")
  in
  (match project_wm, project_entry_name with
   | None, _ -> ()
   | Some _, Some entry_name ->
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
                 `fun main`" entry_name))
   | Some _, None -> assert false);
  (* Entry is a validated package container, not a site object. Keeping it as
     TopPlace would force a root world in multi-world packages and would emit a
     fictitious topos.place. main remains as the actual executable entry. *)
  let prog =
    match project_entry_name with
    | Some entry_name ->
        Manifest.remove_entrypoint_container ~entry_name prog
    | None -> prog
  in
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
  (* Filesystem-derived topos structure (Agent M). The parser now produces every
     topos with tp_objects=[], tp_at_space=None, tp_world=None; FILL those from
     the package layout before assign_place_worlds (which reads tp_world /
     tp_at_space to world the inner objects). Project mode only. Names are
     unqualified here (local module, no "::"), so they survived mangle_decls
     intact — same assumption assign_place_worlds already relies on. The maps
     were built per file at parse-assembly time, where each file's space tag was
     still known. Enforce one-topos-per-space first, before populating. *)
  let prog =
    match project_wm with
    | Some wm ->
        (* one topos per space (mandatory): every declared space must hold
           exactly one topos file. space_decls gives the declared spaces. *)
        let declared_spaces =
          Package_layout.space_decls ~root:path
          |> List.filter_map (function
               | Surface_ast.TopSpace sd -> Some sd.Surface_ast.sd_name
               | _ -> None)
        in
        (* per-space topos-file count, summed across that space's files *)
        let count_tbl : (string, int) Hashtbl.t = Hashtbl.create 16 in
        List.iter (fun (sp, n) ->
          let prev = match Hashtbl.find_opt count_tbl sp with Some k -> k | None -> 0 in
          Hashtbl.replace count_tbl sp (prev + n)) !topos_count;
        let topos_count_of_space sp =
          match Hashtbl.find_opt count_tbl sp with Some k -> k | None -> 0 in
        (match Manifest.check_one_topos_per_space ~topos_count_of_space declared_spaces with
         | [] -> ()
         | errs ->
             List.iter (fun m -> Printf.eprintf "TOPOS LAYOUT ERROR: %s\n" m) errs;
             exit 3);
        (* topos_name -> space *)
        let ts_tbl : (string, string) Hashtbl.t = Hashtbl.create 16 in
        List.iter (fun (tn, sp) -> Hashtbl.replace ts_tbl tn sp) !topos_space;
        let space_of_topos tn = Hashtbl.find_opt ts_tbl tn in
        (* space -> place_decl list (objects), in source order *)
        let ps_tbl : (string, Surface_ast.place_decl list) Hashtbl.t =
          Hashtbl.create 16 in
        List.iter (fun (sp, pd) ->
          let prev = match Hashtbl.find_opt ps_tbl sp with Some l -> l | None -> [] in
          Hashtbl.replace ps_tbl sp (prev @ [pd])) (List.rev !places_by_space);
        let places_of_space sp =
          match Hashtbl.find_opt ps_tbl sp with Some l -> l | None -> [] in
        Manifest.assign_topos_structure
          ~space_of_topos ~places_of_space
          ~world_of_space:(Manifest.world_of_space wm)
          prog
    | None -> prog
  in
  (* The place inherits its space's world (filesystem -> toml): bind each
     unannotated place to the world of its directory before type-checking, so a
     multi-world project resolves structurally instead of relying on the
     unique-world heuristic (which cannot disambiguate across worlds). Project
     mode only; each file is re-parsed alone to find the place names it
     declares and the space (directory) it lives in. *)
  let prog =
    match project_wm with
    | Some wm ->
        let pw : (string, string) Hashtbl.t = Hashtbl.create 16 in
        List.iter (fun (n, w) ->
          match Hashtbl.find_opt pw n with
          | Some w' when w' <> w ->
              (* Bare-name keying would silently bind BOTH places named [n] to the
                 last world written, so one place gets checked against the wrong
                 sheaf condition. A place name resolves to a single world; reject
                 the cross-world clash loudly (place symbols aren't space-qualified
                 downstream either, so two same-named places can't coexist). *)
              Printf.eprintf
                "place '%s' is declared in two different worlds ('%s' and '%s'); \
                 a place name must resolve to a single world — rename or move one.\n"
                n w' w;
              exit 6
          | _ -> Hashtbl.replace pw n w) !pw_pairs;
        Manifest.assign_place_worlds
          ~world_of_space:(Manifest.world_of_space wm)
          (fun n -> Hashtbl.find_opt pw n) prog
    | None -> prog
  in
  (* Expand views only after filesystem world assignment. The synthetic view
     place copies its source place's world; expanding earlier would freeze
     __INFER and orphan the view in multi-world projects. *)
  let prog = Desugar.expand_views prog in
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
