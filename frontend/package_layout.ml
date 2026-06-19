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
  ul_world : string;     (* "" = the root world *)
  ul_space : string;
  ul_path  : string;
  ul_is_world : bool;    (* the conventional world.yon header file *)
}

(* world of a file path relative to the package root: the first path segment
   under root, or "" for a file directly under root (the root world). *)
let world_of ~(root : string) ~(path : string) : string =
  let r = if Filename.check_suffix root "/" then root else root ^ "/" in
  let rel =
    if String.length path >= String.length r
       && String.sub path 0 (String.length r) = r
    then String.sub path (String.length r) (String.length path - String.length r)
    else Filename.basename path
  in
  match String.split_on_char '/' rel with
  | dir :: _ :: _ -> dir          (* root/<dir>/.../file.yon -> world <dir> *)
  | _ -> ""                       (* root/file.yon          -> root world  *)

let space_of ~(path : string) : string =
  Filename.remove_extension (Filename.basename path)

let is_world_file ~(path : string) : bool = space_of ~path = "world"

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
  |> List.map (fun p ->
       { ul_world = world_of ~root ~path:p;
         ul_space = space_of ~path:p;
         ul_path  = p;
         ul_is_world = is_world_file ~path:p })

let read_file fn =
  let ic = open_in fn in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic; s

(* a world.yon body becomes a world header in the right surface form:
     starts with '=' or '/'  -> construction (= A + B, / Rel)
     starts with "subset"     -> subset of R
     otherwise                -> `world W { <inhabitants> }`
     empty / absent           -> `world W { }` *)
let world_header (w : string) (body : string option) : string =
  match body with
  | None -> Printf.sprintf "world %s { }" w
  | Some b ->
      let t = String.trim b in
      if t = "" then Printf.sprintf "world %s { }" w
      else if t.[0] = '=' || t.[0] = '/' then Printf.sprintf "world %s %s" w t
      else if String.length t >= 6 && String.sub t 0 6 = "subset"
      then Printf.sprintf "world %s %s" w t
      else Printf.sprintf "world %s { %s }" w t

(* reconstruct the explicit declarative text the existing parser accepts. *)
let reconstruct ~(root : string) : string =
  let units = layout ~root in
  let worlds = List.sort_uniq compare (List.map (fun u -> u.ul_world) units) in
  let buf = Buffer.create 1024 in
  List.iter (fun w ->
    let wunits = List.filter (fun u -> u.ul_world = w) units in
    if w <> "" then begin
      let body =
        match List.find_opt (fun u -> u.ul_is_world) wunits with
        | Some u -> Some (read_file u.ul_path) | None -> None in
      Buffer.add_string buf (world_header w body);
      Buffer.add_char buf '\n'
    end;
    List.iter (fun u ->
      if not u.ul_is_world then begin
        if w <> "" then
          Buffer.add_string buf (Printf.sprintf "space %s in %s\n" u.ul_space w);
        Buffer.add_string buf (read_file u.ul_path);
        Buffer.add_char buf '\n'
      end) wunits)
    worlds;
  Buffer.contents buf

(* A package is a directory carrying the manifest yon.toml at its root. Its
   presence marks the project root (Cargo/Go model): yonc on the directory
   compiles the whole project, yonc on a single .yon compiles just that file. *)
let manifest_name = "yon.toml"
let is_project ~(dir : string) : bool =
  Sys.file_exists (Filename.concat dir manifest_name)

(* The sources of a project live under src/, where directory = world and
   file = space (filesystem as declaration). *)
let src_dir ~(root : string) : string = Filename.concat root "src"

(* Project source: reconstruct the explicit form the parser accepts from the
   src/ tree, deducing world/space from the path. No fallback -- a project
   whose src/ is missing is a hard error, surfaced by the caller before this
   is reached. *)
let project_source ~(root : string) : string =
  reconstruct ~root:(src_dir ~root)
