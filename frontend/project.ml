(* project.ml — the canonical project loader and whole-program diagnostic pass.
 *
 * The LSP and (later) the driver share this: load a package (its files + the
 * manifest + the place->Space census) and run the whole-program / project-context
 * semantic checks, returning canonical Diagnostics. One source of truth for "what
 * a project's diagnostics are", so the editor and the compiler cannot disagree.
 *
 * The CHECK LOGIC is reused verbatim from the pure functions the driver already
 * calls (Space_liveness.check_drops and the Manifest.check_ family), so there is
 * no duplicated logic; this module unifies only the loading and orchestration.
 * `overrides` lets
 * the LSP substitute an open buffer's unsaved text for its file on disk.
 *)

module S = Surface_ast

type file_info = {
  fi_space : string;      (* the file's Space (directory); "" = project root *)
  fi_path  : string;
  fi_prog  : S.program;   (* its parsed, drained declarations *)
}

type loaded = {
  root        : string;                       (* the package root (holds yon.toml) *)
  declared    : string list;                 (* Spaces declared in the manifest *)
  place_space : (string, string) Hashtbl.t;  (* place name -> its Space (directory) *)
  merged      : S.program;                    (* all files, merged *)
  space_nodes : S.program;                    (* filesystem-derived TopSpace decls (one per directory) *)
  files       : file_info list;               (* per-file, for the layout/boundary/entry checks *)
  wm          : Manifest.world_map option;    (* the manifest (worlds), if any *)
  place_acc   : (string * string * string) list;  (* (place name, file, Space) *)
  main_files  : string list;                  (* files that define `fun main` *)
  entry_name  : string;                       (* the entrypoint place name (default "Entry") *)
}

let parse_text ?(file : string = "") (src : string) : S.program =
  let lexbuf = Lexing.from_string src in
  (* Stamp the file onto every location parsed from this buffer, so a
     whole-program diagnostic (drop, boundary) can be attributed to the exact file
     it came from -- not by matching (line, col), which two files can share. *)
  Lexing.set_filename lexbuf file;
  Parser_state.reset ();
  let p = Parser.program Lexer.token lexbuf in
  p @ Parser_state.drain ()

let read_file (fn : string) : string =
  let ic = open_in fn in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic; s

(* Walk up from a file to the nearest directory carrying a yon.toml. None if the
 * file is not inside a package (the LSP then stays in single-file mode). *)
let root_of_file (path : string) : string option =
  let rec up dir =
    if Sys.file_exists (Filename.concat dir Package_layout.manifest_name) then Some dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then None else up parent
  in
  try up (Filename.dirname path) with _ -> None

(* Load a project. A file with an override uses that in-memory text instead of
 * disk; a file that fails to read or parse contributes nothing (the open file's
 * own parse error is reported through the LSP's single-file path). *)
let load ~(root : string) ?(overrides : (string * string) list = []) () : loaded =
  let wm =
    let mpath = Filename.concat root Package_layout.manifest_name in
    if Sys.file_exists mpath then
      (try Some (Manifest.parse_file mpath) with Manifest.Manifest_error _ -> None)
    else None
  in
  let declared = match wm with
    | Some wm ->
        List.sort compare (Hashtbl.fold (fun k _ acc -> k :: acc) wm.Manifest.space_world [])
    | None -> []
  in
  let files =
    List.filter_map
      (fun (u : Package_layout.unit_loc) ->
         let text =
           match List.assoc_opt u.Package_layout.ul_path overrides with
           | Some t -> Some t
           | None -> (try Some (read_file u.Package_layout.ul_path) with _ -> None)
         in
         match text with
         | None -> None
         | Some t ->
             (try Some { fi_space = u.Package_layout.ul_space;
                         fi_path = u.Package_layout.ul_path;
                         fi_prog = parse_text ~file:u.Package_layout.ul_path t }
              with _ -> None))
      (Package_layout.layout ~root)
  in
  let merged = List.concat_map (fun f -> f.fi_prog) files in
  let place_space : (string, string) Hashtbl.t = Hashtbl.create 32 in
  let place_acc = ref [] and main_files = ref [] in
  List.iter
    (fun f ->
       List.iter
         (function
           | S.TopPlace pd ->
               if f.fi_space <> "" then Hashtbl.replace place_space pd.S.pd_name f.fi_space;
               place_acc := (pd.S.pd_name, f.fi_path, f.fi_space) :: !place_acc
           | S.TopFun fd when fd.S.fn_name = "main" -> main_files := f.fi_path :: !main_files
           | _ -> ())
         f.fi_prog)
    files;
  let entry_name =
    match wm with Some w -> (match w.Manifest.pkg_entry with Some e -> e | None -> "Entry")
                | None -> "Entry"
  in
  { root; declared; place_space; merged;
    space_nodes = Package_layout.space_decls ~root;
    files; wm;
    place_acc = !place_acc; main_files = !main_files; entry_name }

(* ---- the whole-program diagnostic pass ---- *)

let drop_diags (l : loaded) : Error_codes.t list =
  List.map
    (fun (e : Space_liveness.drop_error) ->
       let dl = e.Space_liveness.de_drop in
       (* Message text is canonical here and matches the driver byte-for-byte,
          including the drop-site location inline: to_cli prints only the message,
          not the range, so the site must live in the text to reach the CLI. *)
       match e.Space_liveness.de_fault with
       | Space_liveness.Unknown_space ->
           Error_codes.make ~range:dl Error_codes.Drop_unknown_space
             (Printf.sprintf
                "unknown Space %s at %d:%d (not a declared Space in any world)"
                e.Space_liveness.de_space
                dl.Surface_ast.start_line dl.Surface_ast.start_col)
       | Space_liveness.Still_live arc ->
           Error_codes.make ~range:dl Error_codes.Drop_still_live
             (Printf.sprintf
                "cannot drop Space %s at %d:%d: an arc toward it is still \
                 reachable downstream (at %d:%d)"
                e.Space_liveness.de_space
                dl.Surface_ast.start_line dl.Surface_ast.start_col
                arc.Surface_ast.start_line arc.Surface_ast.start_col))
    (Space_liveness.check_drops ~declared:l.declared ~place_space:l.place_space l.merged)

(* One-topos-per-space: count the topos DECLARATIONS per Space over the whole
 * project (a file with two toposes counts two), matching the driver's per-file
 * topos tally exactly. *)
let topos_layout_diags (l : loaded) : Error_codes.t list =
  let count sp =
    List.fold_left
      (fun n f ->
         if f.fi_space = sp then
           n + List.length
                 (List.filter (function S.TopTopos _ -> true | _ -> false) f.fi_prog)
         else n)
      0 l.files
  in
  (* Over the FILESYSTEM spaces (the directories on disk), exactly as the driver:
     an on-disk space with the wrong topos count is flagged whether or not the
     toml lists it. *)
  let fs_spaces =
    List.filter_map (function S.TopSpace sd -> Some sd.S.sd_name | _ -> None)
      l.space_nodes in
  Manifest.check_one_topos_per_space ~topos_count_of_space:count fs_spaces
  |> List.map (Error_codes.make Error_codes.Topos_layout)

(* File-layout rules (basename = place name, one place per file, a topos must
 * live in Topos.yon, ...). The driver renders these under the SAME prefix and
 * code as the topos-per-space rule (E4001, "TOPOS LAYOUT ERROR"), so check_all
 * matches it -- the differential gate pins that they agree. *)
let file_layout_diags (l : loaded) : Error_codes.t list =
  List.concat_map
    (fun f ->
       if f.fi_space = "" then []   (* the layout rules apply to Space files *)
       else
         let basename = Filename.remove_extension (Filename.basename f.fi_path) in
         let place_names =
           List.filter_map (function S.TopPlace pd -> Some pd.S.pd_name | _ -> None) f.fi_prog in
         let has_topos = List.exists (function S.TopTopos _ -> true | _ -> false) f.fi_prog in
         Manifest.check_file_layout ~basename ~place_names ~has_topos
         |> List.map (Error_codes.make Error_codes.Topos_layout))
    l.files

(* Wire boundary: an import may only reach a Space in the sender's own world.
 * Mirrors the driver exactly: the GLOBAL orphan-space check (a Space in no world)
 * over the whole program, plus the PER-FILE target checks (a wire reaching a
 * Space in another world). The global check reads TopSpace nodes, which live only
 * in the filesystem-derived space decls (never in a .yon file), so it runs on
 * `space_nodes` -- the same nodes the driver prepends before check_program; running
 * it on `merged` would silently never fire (case D would be blind). *)
let boundary_diags (l : loaded) : Error_codes.t list =
  match l.wm with
  | None -> []
  | Some wm ->
      let mk (loc, msg) =
        let full =
          if loc.S.start_line > 0 then
            Printf.sprintf "%d:%d: %s" loc.S.start_line loc.S.start_col msg
          else msg in
        Error_codes.make ~range:loc Error_codes.Wire_boundary full in
      let global = Manifest.check_program wm l.space_nodes in
      let per_file =
        List.concat_map
          (fun f ->
             let sender_world = Manifest.world_of_space wm f.fi_space in
             Manifest.check_targets wm ~sender_world (Manifest.import_targets f.fi_prog))
          l.files in
      List.map mk (global @ per_file)

(* Entrypoint: the place `Entry` (or [package] entry) declared once, in the root,
 * in the file that defines main. Mirrors the driver's inline rule. *)
let entrypoint_diags (l : loaded) : Error_codes.t list =
  match l.wm with
  | None -> []
  | Some _ ->
      let en = l.entry_name in
      let mk msg = [ Error_codes.make Error_codes.Entrypoint msg ] in
      (match List.filter (fun (n, _, _) -> n = en) l.place_acc with
       | [] ->
           mk (Printf.sprintf
                 "the project declares no entrypoint: add `place %s` in the project \
                  root, in the file that defines main" en)
       | [ (_, file, sp) ] ->
           if sp <> "" then
             mk (Printf.sprintf
                   "the entrypoint place `%s` must live in the project root, not in \
                    space `%s`" en sp)
           else if not (List.mem file l.main_files) then
             mk (Printf.sprintf
                   "the entrypoint place `%s` must contain main: its file defines no \
                    `fun main`" en)
           else []
       | entries ->
           mk (Printf.sprintf
                 "the entrypoint place `%s` must be unique; it is declared %d times"
                 en (List.length entries)))

(* Every project-context diagnostic, from one place. The Space-semantic classes
 * (drop, boundary) are the crown jewels -- diagnostics no other language server
 * can give, from the communication graph; the layout/entrypoint classes guard the
 * project's structure. *)
let check_all (l : loaded) : Error_codes.t list =
  drop_diags l @ boundary_diags l @ topos_layout_diags l
  @ file_layout_diags l @ entrypoint_diags l

(* ---- whole-program type check ---- *)

(* Load the SIGNATURES of every module named in a cross-Space import (the import is
 * nominal; the code lives in another process). Resolution mirrors the driver:
 * sibling <module>.yon, else yon_modules/<module>/*.yon, relative to the root. The
 * subscriber's reference to a remote producer then type-checks. *)
let load_remote_signatures (l : loaded) : unit =
  List.iter
    (function
      | S.TopImportFrom (m, _, _, _) ->
          let candidates =
            let sib = Filename.concat l.root (m ^ ".yon") in
            if Sys.file_exists sib then [ sib ]
            else
              let dir = Filename.concat (Filename.concat l.root "yon_modules") m in
              if Sys.file_exists dir && Sys.is_directory dir then
                Sys.readdir dir |> Array.to_list
                |> List.filter (fun f -> Filename.check_suffix f ".yon")
                |> List.map (Filename.concat dir)
              else []
          in
          List.iter
            (fun fn ->
               try
                 List.iter
                   (function
                     | S.TopFun fd ->
                         Tycheck.register_remote_signature
                           (m ^ "::" ^ fd.S.fn_name) fd.S.fn_return;
                         Tycheck.register_remote_signature
                           fd.S.fn_name fd.S.fn_return
                     | _ -> ())
                   (parse_text ~file:fn (read_file fn))
               with _ -> ())
            candidates
      | _ -> ())
    l.merged

(* Transform the merged program up to (but not including) the type check, exactly
 * as the compiler driver does before Tycheck.check_program: prepend the toml worlds
 * and the filesystem spaces, strip the entrypoint container, fill each topos's
 * filesystem structure, bind every unannotated place to its space's world, and
 * expand views. Type-checking the WHOLE program (not one buffer) is what lets a
 * cross-file reference resolve -- a place/type/function defined in a sibling file is
 * present here. The codegen-only rewrites (lower_cross_space, mangle) are omitted:
 * they do not change what type-checks in a package (no `::` names, symbols still
 * local), and skipping them keeps type-error messages in surface names. *)
let prepare_for_typecheck (l : loaded) : S.program =
  match l.wm with
  | None -> l.merged
  | Some wm ->
      load_remote_signatures l;
      let prog = Manifest.world_decls wm @ l.space_nodes @ l.merged in
      let prog = Manifest.remove_entrypoint_container ~entry_name:l.entry_name prog in
      (* topos name -> space, and space -> its place decls, from the per-file facts *)
      let ts_tbl : (string, string) Hashtbl.t = Hashtbl.create 16 in
      let ps_tbl : (string, S.place_decl list) Hashtbl.t = Hashtbl.create 16 in
      List.iter
        (fun f ->
           if f.fi_space <> "" then
             List.iter
               (function
                 | S.TopTopos td -> Hashtbl.replace ts_tbl td.S.tp_name f.fi_space
                 | S.TopPlace pd ->
                     let prev = match Hashtbl.find_opt ps_tbl f.fi_space with
                       | Some xs -> xs | None -> [] in
                     Hashtbl.replace ps_tbl f.fi_space (prev @ [pd])
                 | _ -> ())
               f.fi_prog)
        l.files;
      let prog =
        Manifest.assign_topos_structure
          ~space_of_topos:(fun tn -> Hashtbl.find_opt ts_tbl tn)
          ~places_of_space:(fun sp -> match Hashtbl.find_opt ps_tbl sp with
                                      | Some xs -> xs | None -> [])
          ~world_of_space:(Manifest.world_of_space wm)
          prog in
      let world_of_place n =
        match Hashtbl.find_opt l.place_space n with
        | Some sp -> Manifest.world_of_space wm sp
        | None -> None in
      let prog =
        Manifest.assign_place_worlds
          ~world_of_space:(Manifest.world_of_space wm) world_of_place prog in
      Desugar.expand_views prog

(* Whole-program type errors as canonical diagnostics. Each carries the file its
 * location was stamped with, so a caller (the LSP) can attribute it to the file
 * that owns it. *)
let typecheck_diags (l : loaded) : Error_codes.t list =
  let cr = Tycheck.check_program (prepare_for_typecheck l) in
  List.map
    (fun (e : Tycheck.type_error) ->
       Error_codes.make ~range:e.Tycheck.err_loc Error_codes.Type_check
         e.Tycheck.err_msg)
    cr.Tycheck.cr_errors
