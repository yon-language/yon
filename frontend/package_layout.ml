(* package_layout.ml — the filesystem IS the declaration.
 *
 * A Yon program is a directory tree. The path carries the ontology the surface
 * keywords used to carry. The LIVE rule is in `space_of`/`place_of` below:
 *   - a .yon FILE is a PLACE: its basename is the place name (`Rex.yon` -> Rex);
 *     one place per file, no `place` keyword in the body (commit "no 'place'");
 *   - a DIRECTORY under the root is a SPACE: the first path segment
 *     (`paddocks/Rex.yon` -> space `paddocks`);
 *   - a file directly under the root belongs to no space — the entrypoint area
 *     (e.g. Entry.yon);
 *   - a WORLD is declared in `yon.toml` (`[world.Name]`, with objects/spaces),
 *     not as a directory and not as an inline keyword; the inline `topos Name
 *     where { ... }` lives in the conventional `Topos.yon` inside a space-dir.
 *
 * This module is the DEDUCTION: it walks the tree and derives (space, place)
 * from each path; world membership comes from the manifest (sd_world = None
 * here). It IS wired into the live emit driver (yoner_emit_mlir.ml calls
 * Package_layout.layout / is_project / space_decls) and is exercised by
 * test_world_site.ml.
 *
 * WARNING — comment archaeology. Earlier strata of THIS header said "dir =
 * world, file = space" and "does NOT touch the driver". Both are STALE. The
 * code (space_of / place_of) and yoner_emit_mlir's call sites are the truth.
 * Trust the code, not a header comment. *)

type unit_loc = {
  ul_space : string;     (* "" = a file directly under the project root *)
  ul_path  : string;
}

(* The space a file belongs to: the first path segment under the root, i.e.
   the directory it sits in (directory = space). A file directly under the
   root belongs to no space (ul_space = ""): the entrypoint area, e.g.
   Main.yon. *)
let space_of ~(root : string) ~(path : string) : string =
  let r = if Filename.check_suffix root "/" then root else root ^ "/" in
  let rel =
    if String.length path >= String.length r
       && String.sub path 0 (String.length r) = r
    then String.sub path (String.length r) (String.length path - String.length r)
    else Filename.basename path
  in
  match String.split_on_char '/' rel with
  | dir :: _ :: _ -> dir          (* root/<dir>/file.yon -> space <dir> *)
  | _ -> ""                       (* root/file.yon       -> no space (root) *)

(* The place a file declares is its basename (informative; the place's real
   name is whatever the file's `place P` body says). *)
let place_of ~(path : string) : string =
  Filename.remove_extension (Filename.basename path)

(* walk the tree, deterministic order, skipping yon_modules (explicit deps).
   Both Sys.readdir and Sys.is_directory raise Sys_error on an unreadable
   directory or a broken symlink; guard each so a malformed project tree yields
   a skip-with-warning instead of an uncaught crash. *)
let rec walk (dir : string) : string list =
  let entries =
    try Sys.readdir dir |> Array.to_list |> List.sort compare
    with Sys_error msg ->
      Printf.eprintf
        "[yon] warning: cannot read directory '%s' (%s) — skipped\n" dir msg;
      []
  in
  entries |> List.concat_map (fun e ->
       let full = Filename.concat dir e in
       match (try Some (Sys.is_directory full) with Sys_error _ -> None) with
       | None -> []                                   (* broken symlink / unreadable: skip *)
       | Some true -> if e = "yon_modules" then [] else walk full
       | Some false -> if Filename.check_suffix e ".yon" then [full] else [])

let layout ~(root : string) : unit_loc list =
  walk root
  |> List.map (fun p -> { ul_space = space_of ~root ~path:p; ul_path = p })

let read_file fn =
  let ic = open_in fn in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic; s

(* The project's spaces as native TopSpace decls: one per directory that holds
   .yon files. The space->world membership is NOT set here (sd_world = None):
   it lives in the manifest. Files directly under the root belong to no space
   and contribute none. The worlds (TopWorld) come from Manifest.world_decls;
   the place files are parsed as themselves -- nothing is rendered as text. *)
let space_decls ~(root : string) : Surface_ast.top_decl list =
  layout ~root
  |> List.filter_map (fun u -> if u.ul_space = "" then None else Some u.ul_space)
  |> List.sort_uniq compare
  |> List.map (fun s ->
       Surface_ast.TopSpace
         { Surface_ast.sd_name = s; sd_world = None; sd_fold = None;
           sd_loc = Surface_ast.dummy_loc })

(* A package is a directory carrying the manifest yon.toml at its root. Its
   presence marks the project root (Cargo/Go model): yonc on the directory
   compiles the whole project, yonc on a single .yon compiles just that file. *)
let manifest_name = "yon.toml"
let is_project ~(dir : string) : bool =
  Sys.file_exists (Filename.concat dir manifest_name)
