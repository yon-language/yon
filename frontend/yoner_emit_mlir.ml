(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
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
  (* Additive, static-only: `--dump-space-graph` prints the inter-Space
     communication graph (wire and import arcs, from the source) and exits before
     emission. It never changes what the compiler emits. *)
  let dump_space_graph = Array.exists (fun a -> a = "--dump-space-graph") argv in
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
           Printf.eprintf "%s\n" (Error_codes.to_cli (Error_codes.make Error_codes.Manifest msg)); exit 3)
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
  (* Project mode: collect each place's world while the file is parsed below --
     no second parse. The place->world map needs the space (directory) of the
     file; key it by the same canon path as `loaded`. *)
  let pw_pairs = ref [] in
  let space_edges = ref [] in (* static Space graph: wire and import arcs, tagged by source Space *)
  let place_acc = ref [] in   (* (place_name, file, space) for every project place *)
  let main_files = ref [] in  (* files that define `fun main` *)
  (* Filesystem-derived topos structure (Agent M). Captured per file at
     parse-assembly time, where the file's space tag (ul_space) is still known;
     the merged program below no longer carries per-file origin. *)
  let places_by_space = ref [] in  (* (space, place_decl) for every project TopPlace *)
  let topos_space = ref [] in      (* (topos_name, space) for every TopTopos file *)
  (* Per-file record for the shared project diagnostic pass (Project.check_all):
     the file's Space (directory), path, and drained decls -- exactly what the
     module's loader would produce, but built from THIS parse so there is no
     second read. Project mode only (populated in the branch below). *)
  let files_acc = ref [] in
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
               (* Static Space graph: collect this file's wire and import arcs,
                  tagged with its Space (sp; "" for a root/entry file). `decls`
                  is synth @ p, so arrows lifted from a place body (a form-C
                  `fun main`) are covered too. Accumulation only, no emit change. *)
               space_edges :=
                 Space_graph.edges_of_file ~src_space:sp decls @ !space_edges;
               (* entrypoint collection: every project file (root included).
                  Record each declared place (name, file, space) and whether the
                  file defines `main`, so the Entry constraints below can be
                  checked on the whole project. *)
               (* Filesystem-derived topos structure (Agent M): in this same
                  pass capture, per space, (a) the full place_decl of every
                  TopPlace — these become the topos's tp_objects — and (b) each
                  TopTopos's name->space binding. sp is "" for root files, which
                  belong to no space/topos. The file-layout / topos-count /
                  boundary facts are no longer tallied here: Project.check_all
                  derives them from `files_acc` below, in one place. *)
               List.iter (function
                 | Surface_ast.TopPlace pd ->
                     place_acc := (pd.Surface_ast.pd_name, filename, sp) :: !place_acc;
                     if sp <> "" then
                       places_by_space := (sp, pd) :: !places_by_space
                 | Surface_ast.TopTopos td ->
                     if sp <> "" then
                       topos_space := (td.Surface_ast.tp_name, sp) :: !topos_space
                 | Surface_ast.TopFun fd when fd.Surface_ast.fn_name = "main" ->
                     main_files := filename :: !main_files
                 | _ -> ()) decls;
               (* Capture the file for Project.check_all (drop / boundary / topos /
                  layout / entrypoint), built from this same parse. sp is "" for
                  root files, which the pass treats as space-less. *)
               files_acc :=
                 { Project.fi_space = sp; fi_path = filename; fi_prog = decls }
                 :: !files_acc;
               (* place->world: bind each place in a world-bearing space to that
                  world (root files inherit no world). The wire-boundary targets
                  are re-derived by Project.check_all from files_acc. *)
               (match Manifest.world_of_space wm sp with
                | Some w ->
                    List.iter (function
                      | Surface_ast.TopPlace pd ->
                          pw_pairs := (pd.Surface_ast.pd_name, w) :: !pw_pairs
                      | _ -> ()) decls
                | None -> ())
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
          Printf.eprintf "%s\n" (Error_codes.to_cli (Error_codes.make Error_codes.Parse_syntax
            (Printf.sprintf "%s:%d:%d" p.pos_fname p.pos_lnum (p.pos_cnum - p.pos_bol))));
          exit 2
      | Failure msg ->
          Printf.eprintf "%s\n" (Error_codes.to_cli (Error_codes.make Error_codes.Parse_syntax
            (Printf.sprintf "%s: %s" filename msg)));
          exit 2
      | Lexer.Lexer_error msg ->
          Printf.eprintf "%s\n" (Error_codes.to_cli (Error_codes.make Error_codes.Lex_bad_token
            (Printf.sprintf "%s: %s" filename msg)));
          exit 2
    ) all_sources
  in
  (* Static Space graph dump (additive, before emission). Build the graph from
     the arcs collected per file above and print it, then stop. Never emits. *)
  (if dump_space_graph then begin
    let declared = match project_wm with
      | Some wm ->
          List.sort compare
            (Hashtbl.fold (fun k _ acc -> k :: acc) wm.Manifest.space_world [])
      | None -> []
    in
    let g = Space_graph.build ~declared (List.rev !space_edges) in
    print_string (Space_graph.dump ~declared g);
    exit 0
  end);
  (* Static drop check: every `drop X` must have no arc toward X reachable
   * downstream (Space_liveness.check_drops) -- the same criterion the automatic
   * reclaim uses, so a drop can never fire earlier than reclaim would. An early
   * drop is a use-after-reclaim and is rejected here, citing the offending
   * downstream arc.
   *
   * This runs on the PRE-LOWERING surface program: imports are still
   * TopImportFrom and calls are still raw, so import arcs and transitive call
   * arcs are visible to the analysis. It MUST stay before
   * Module_prefix.lower_cross_space (below), which rewrites cross-Space calls
   * into remote invokes and consumes the import decls -- after that the arcs are
   * invisible and every drop would look legal. Whole-program: the transitive
   * case crosses files via calls/imports, and `prog` is the merged program.
   * Reuses the exit-3 semantic-error channel. *)
  (* Existence census: the declared Spaces are the keys of the manifest's
     space->world map (the source of truth, includes isolated declared Spaces
     that appear in no arc). In single-file mode there is no world, so no Space
     exists and any `drop` is an unknown-Space error. *)
  let declared_spaces =
    match project_wm with
    | Some wm ->
        List.sort compare
          (Hashtbl.fold (fun k _ acc -> k :: acc) wm.Manifest.space_world [])
    | None -> []
  in
  (* Place->Space census: a place P in directory D/ belongs to Space D (the same
     binding the tp_at_space rewrite propagates to `new P {}`). Built from the
     per-file place accumulation, so `new P` downstream of a drop counts as an arc
     toward P's Space. *)
  let place_space =
    let h = Hashtbl.create 32 in
    List.iter (fun (sp, pd) ->
      if sp <> "" then Hashtbl.replace h pd.Surface_ast.pd_name sp) !places_by_space;
    h
  in
  (* Whole-program project diagnostics, from the SAME orchestration the language
     server runs (Project.check_all): drop, wire boundary, one-topos-per-space,
     file layout, entrypoint. Converging here is what makes the compiler and the
     editor incapable of disagreeing -- one function decides "what a project's
     diagnostics are". The `loaded` is built from THIS parse (no second read): the
     merged pre-lowering program, the filesystem space census, and the per-file
     facts the loop above accumulated. Show-all: every violation is printed, then
     exit 3 (the shared semantic-error channel). Must stay before
     Module_prefix.lower_cross_space (below): the drop analysis needs the raw
     import/call arcs, gone after lowering. *)
  let loaded : Project.loaded =
    { Project.root = path;
      declared = declared_spaces;
      place_space;
      merged = prog;
      space_nodes =
        (match project_wm with
         | Some _ -> Package_layout.space_decls ~root:path
         | None -> []);
      files = List.rev !files_acc;
      wm = project_wm;
      place_acc = !place_acc;
      main_files = !main_files;
      entry_name =
        (match project_wm with
         | Some wm -> (match wm.Manifest.pkg_entry with Some e -> e | None -> "Entry")
         | None -> "Entry") }
  in
  (match Project.check_all loaded with
   | [] -> ()
   | diags ->
       List.iter (fun d -> Printf.eprintf "%s\n" (Error_codes.to_cli d)) diags;
       exit 3);
  (* Automatic reclaim at last-use (the mechanism `drop X` is the checked
     assertion of): insert an SDrop for each Space at its global last use in the
     entry's main. Runs AFTER check_drops (the inserted drops are legal by
     construction, at the point where the Space leaves downstream_arcs) and BEFORE
     lowering, so the same drop emission handles them. Sound because the arc set
     is complete (the audit): no read of a reclaimed Space can follow.
     The reclaimable set is the OWNED (directory-backed) Spaces, not every declared
     Space: only those have a local heap and a `yon_space_str_<X>` global. A remote
     Space merely wired/imported (e.g. a subscriber's producer) is left to the
     owner and to process exit -- reclaiming its local receive view is a later
     precision gain, and referencing its missing global would fail emission. *)
  let owned_spaces =
    match project_wm with
    | Some _ ->
        List.filter_map
          (function Surface_ast.TopSpace sd -> Some sd.Surface_ast.sd_name | _ -> None)
          (Package_layout.space_decls ~root:path)
    | None -> []
  in
  let prog =
    Space_liveness.auto_reclaim_program ~declared:owned_spaces ~place_space prog in
  (* File layout, one-topos-per-space, boundary and entrypoint were all decided
     above by Project.check_all; nothing to re-check here. *)
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
  (* The entrypoint's four conditions were validated by Project.check_all above;
     here we only need its NAME to strip the container below. *)
  let project_entry_name =
    match project_wm with
    | None -> None
    | Some wm ->
        Some (match wm.Manifest.pkg_entry with Some e -> e | None -> "Entry")
  in
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
        (* one-topos-per-space was already enforced by Project.check_all above, so
           assign_topos_structure runs on a validated layout (exactly one topos per
           space). *)
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
  (* Lower the Id-proposition sugar (Same / bare clear) before check + desugar. *)
  let prog = Tycheck.elaborate_id_sugar prog in
  let cr = Tycheck.check_program prog in
  if cr.Tycheck.cr_errors <> [] then begin
    List.iter (fun e ->
      Printf.eprintf "%s\n" (Error_codes.to_cli
        (Error_codes.make Error_codes.Type_check (Tycheck.error_to_string e))))
      cr.Tycheck.cr_errors;
    exit 3
  end;
  (* The world-boundary checks (orphan spaces + per-wire targets) were decided by
     Project.check_all above, before any lowering consumed the import arcs. *)
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
  (* Route `new P { }` to P's Space: pass the filesystem census (place -> its
     directory's Space, the same place_space the drop check uses) to the at_space
     rewrite. Reading the census directly keeps one source of truth; tp_objects
     stays empty (its double-registration hazard never arises). *)
  let desugared =
    Desugar.desugar_program ~env:(Some cr.Tycheck.cr_env)
      ~place_to_space:(Hashtbl.fold (fun k v acc -> (k, v) :: acc) place_space [])
      prog in
  (* Kernel re-check: the dependent Core checker certifies the well-formedness of
     every dependent type the surface elaboration produced, over the ORIGINAL codes
     (before El_normalize computes them away). A genuine ill-formed dependent type is
     rejected here; constructs outside the checker's fragment are skipped, so a
     well-formed program always passes. *)
  (match Core_wf.certify_program desugared with
   | Ok r ->
       if (try Sys.getenv "YON_CORE_WF" = "1" with Not_found -> false) then
         Printf.eprintf "[core-wf] %d dependent types certified, %d skipped (out of fragment)\n"
           r.Core_wf.certified r.Core_wf.skipped
   | Error msg ->
       Printf.eprintf "%s\n" (Error_codes.to_cli (Error_codes.make Error_codes.Type_check
         (Printf.sprintf
            "kernel re-check rejected a lowered dependent type: %s. The surface \
             type-checked but its Core lowering is not well-formed under the \
             dependent checker — this is a desugaring/normalization soundness bug." msg)));
       exit 3);
  (* Conversion rule El(c) ≡ El(nf_Δ c): reduce every El code to its Δ-normal form
     under the certified deltas, so a computed-codomain dependent type `El(Fam x)`
     computes to a concrete carrier before the pure carrier functor sees it. The
     kernel/R_Yon reducer does the work; the carrier stays a functor on normal
     forms. *)
  let desugared =
    El_normalize.normalize_result
      (Dispatcher.certified_deltas cr.Tycheck.cr_env) desugared in
  (* Erase type-level (universe-typed) parameters before codegen: a type
     argument is a compile-time citizen and must not reach the carrier/backend
     as runtime data. Coordinated drop of binders and matching call arguments;
     this keeps the carrier functor within its domain (no TyType reaches emit). *)
  let desugared =
    try Type_erase.erase desugared
    with Type_erase.Higher_order_type_param fname ->
      Printf.eprintf "%s\n" (Error_codes.to_cli (Error_codes.make Error_codes.Type_check
        (Printf.sprintf
           "function `%s` has type parameters and is used outside a direct call \
            (passed as a value, aliased, or partially applied). Higher-order \
            type-argument erasure is not lowered, so this is rejected at compile \
            time rather than miscompiled." fname)));
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
  (* Space death-watch (1.2): hand the STATIC inter-Space graph to the emitter so
     emit_space_bootstrap can arm each watched Space with
     yon_rt_space_expect_inputs(id, in_degree). Built from the SAME per-file arc
     collection (space_edges) and declared-Space census (declared_spaces) that
     Space_graph.dump / --dump-space-graph consumes — one source of truth, no
     re-derivation. Same one-line-setter plumbing as set_views_list below. *)
  Emit_mlir.set_space_graph
    (Space_graph.build ~declared:declared_spaces (List.rev !space_edges));
  (* Extract the view decls from the program and propagate them to
   * emit_program via a global setter. *)
  Emit_mlir.set_views_list (List.filter_map (function
    | Surface_ast.TopView vd -> Some (vd.Surface_ast.vw_name, vd.Surface_ast.vw_of)
    | _ -> None
  ) prog);
  let mlir_output =
    try Emit_mlir.emit_program desugared
    with Emit_mlir.Cubical_stuck msg ->
      (* A cubical value with no runtime representation reached codegen. The
         surface checker is permissive (monomorphic, does not track path-ness),
         so it accepts terms like `inv` of a scalar point that only exist at
         compile time. Reject cleanly on the semantic-error channel (E2001)
         rather than crashing with a Fatal exception. *)
      Printf.eprintf "%s\n" (Error_codes.to_cli (Error_codes.make Error_codes.Type_check
        (Printf.sprintf
           "this cubical term has no runtime value and cannot be lowered: %s \
            It is a compile-time-only citizen (a path/homotopy value in a \
            position that must produce a number)." msg)));
      exit 3
  in
  print_string mlir_output
