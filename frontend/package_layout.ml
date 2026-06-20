(* package_layout.ml — the filesystem IS the declaration.
 *
 * A Yon program is a directory tree. The path carries the ontology the surface
 * keywords used to carry:
 *   - a sub-directory of the package root is a WORLD (its name is the world's);
 *   - a .yon file inside a world-directory is a SPACE (its basename);
 *   - a file directly under the root is a space in the ROOT world;
 *   - the conventional file `world.yon` in a world-directory carries only what
 *     the path cannot say: the world's inhabitants (`Code is Order`) or its
 *     construction (`= A + B`, `/ Rel`, `subset of R`).
 *
 * This module is the DEDUCTION + RECONSTRUCTION: it walks the tree, derives
 * (world, space) from each path, and rebuilds the explicit declarative form the
 * existing parser already accepts -- `world W { ... }`, `space S in W`, then the
 * file body. That explicit form stays the canonical kernel target; the tree is
 * a notation that desugars onto it.
 *
 * STAGE NOTE. Pure layout->text step, exercised on a tiny src/ fixture and
 * checked to PARSE with today's parser. It does NOT touch the driver, the
 * parser, or the corpus -- those follow once this is solid. The place<->world
 * binding (a place inherits its directory's world) is left to the existing
 * __INFER path and is not forced here. *)

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

(* walk the tree, deterministic order, skipping yon_modules (explicit deps). *)
let rec walk (dir : string) : string list =
  Sys.readdir dir |> Array.to_list |> List.sort compare
  |> List.concat_map (fun e ->
       let full = Filename.concat dir e in
       if Sys.is_directory full then
         (if e = "yon_modules" then [] else walk full)
       else if Filename.check_suffix e ".yon" then [full] else [])

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
