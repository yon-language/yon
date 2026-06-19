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

(* Reconstruct the explicit declarative text the existing parser accepts.
   The worlds come from the manifest; each space is a directory; each place
   is a file. The space->world membership is NOT re-emitted here: it lives in
   the manifest ([world.W] spaces = [...]), the single source of truth, so a
   space is declared bare as `space S`. Files directly under the root (the
   entrypoint area, e.g. Main.yon) are emitted last, outside any space. *)
let reconstruct ~(root : string) ~(wm : Manifest.world_map) : string =
  let units = layout ~root in
  let buf = Buffer.create 1024 in
  (* 1. the worlds, materialised from the manifest *)
  let wd = Manifest.all_world_decls wm in
  if wd <> "" then (Buffer.add_string buf wd; Buffer.add_char buf '\n');
  (* 2. each space (a directory), declared bare, then the place files it holds *)
  let spaces =
    List.sort_uniq compare
      (List.filter_map (fun u ->
         if u.ul_space = "" then None else Some u.ul_space) units) in
  List.iter (fun s ->
    Buffer.add_string buf (Printf.sprintf "space %s\n" s);
    List.iter (fun u ->
      if u.ul_space = s then begin
        Buffer.add_string buf (read_file u.ul_path);
        Buffer.add_char buf '\n'
      end) units
  ) spaces;
  (* 3. files directly under the root (entrypoint area: Main.yon, ...) *)
  List.iter (fun u ->
    if u.ul_space = "" then begin
      Buffer.add_string buf (read_file u.ul_path);
      Buffer.add_char buf '\n'
    end) units;
  Buffer.contents buf

(* A package is a directory carrying the manifest yon.toml at its root. Its
   presence marks the project root (Cargo/Go model): yonc on the directory
   compiles the whole project, yonc on a single .yon compiles just that file. *)
let manifest_name = "yon.toml"
let is_project ~(dir : string) : bool =
  Sys.file_exists (Filename.concat dir manifest_name)

(* Project source: reconstruct the explicit form the parser accepts from the
   project tree rooted at the package directory. Directory = space, file =
   place; the worlds and the space->world membership come from the manifest
   (wm). No src/ convention: the package root IS the source tree. *)
let project_source ~(root : string) ~(wm : Manifest.world_map) : string =
  reconstruct ~root ~wm
