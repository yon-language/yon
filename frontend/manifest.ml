(* manifest.ml — reads the [world.<Name>] sections of yon.toml and enforces
   the wire boundary they declare.

   A world is a module declared in the manifest: it lists the spaces that
   belong to it. Spaces within the same world may wire to each other; a wire
   crossing a world boundary is rejected at compile time. The manifest is the
   sole source of the space -> world assignment; the surface grammar is not
   touched (a place still declares "place P in W", a space is still a heap,
   a wire is still "wire to S" / "be s holds X.stream").

   Only the [world.*] sections are parsed here. The other sections
   ([package], [dependencies], [runtime]) are read elsewhere (the yonc
   wrapper) and ignored by this module. The parser is deliberately small: it
   understands "[world.<Name>]" headers and a "spaces = [ ... ]" array of
   double-quoted names. It is not a general TOML parser. *)

open Surface_ast

(* The categorical structure of a world, as declared in [world.<Name>]: its
   objects (Code is X) and at most one construction (= A+B, = A*B, W / R,
   subset of V). All empty = a trivial world over its objects. *)
type world_struct = {
  ws_objects   : string list;
  ws_coproduct : string list;
  ws_product   : string list;
  ws_quotient  : (string * string) option;
  ws_subset_of : string option;
}

let empty_struct = {
  ws_objects = []; ws_coproduct = []; ws_product = [];
  ws_quotient = None; ws_subset_of = None;
}

(* space -> world, world -> spaces (declaration order), world -> its structure. *)
type world_map = {
  space_world  : (string, string) Hashtbl.t;
  world_spaces : (string, string list) Hashtbl.t;
  wstructs     : (string, world_struct) Hashtbl.t;
}

(* A problem in the [world] sections. The manifest has no .yon source
   locations, so the message names the manifest concern in plain words. *)
exception Manifest_error of string

let empty_world_map () = {
  space_world  = Hashtbl.create 16;
  world_spaces = Hashtbl.create 8;
  wstructs     = Hashtbl.create 8;
}

(* ─── small string helpers ─────────────────────────────────────────── *)

let strip_comment (line : string) : string =
  match String.index_opt line '#' with
  | Some i -> String.sub line 0 i
  | None   -> line

let trim s = String.trim s

(* "[world.Commerce]" -> Some "Commerce"; "[package]" -> None; any other
   header -> None. The world name is whatever follows "world." up to "]". *)
let world_header (line : string) : string option =
  let l = trim line in
  let n = String.length l in
  if n >= 2 && l.[0] = '[' && l.[n-1] = ']' then begin
    let inner = String.sub l 1 (n - 2) in            (* e.g. "world.Commerce" *)
    let prefix = "world." in
    let plen = String.length prefix in
    if String.length inner > plen
       && String.sub inner 0 plen = prefix
    then begin
      let name = trim (String.sub inner plen (String.length inner - plen)) in
      if name = "" then
        raise (Manifest_error
          "yon.toml: a [world.<Name>] section is missing its name")
      else Some name
    end else None
  end else None

(* Is this line some other "[...]" section header (so a world section ends)? *)
let is_section_header (line : string) : bool =
  let l = trim line in
  let n = String.length l in
  n >= 2 && l.[0] = '[' && l.[n-1] = ']'

(* Extract the double-quoted tokens from a "spaces = [ \"A\", \"B\" ]" value.
   Returns the list of names. Accepts the array on a single line. *)
let parse_spaces_value (rhs : string) : string list =
  let names = ref [] in
  let buf = Buffer.create 16 in
  let in_quote = ref false in
  String.iter (fun c ->
    if !in_quote then begin
      if c = '"' then begin
        names := Buffer.contents buf :: !names;
        Buffer.clear buf;
        in_quote := false
      end else Buffer.add_char buf c
    end else if c = '"' then in_quote := true
  ) rhs;
  if !in_quote then
    raise (Manifest_error
      "yon.toml: unterminated string in a [world] spaces list");
  List.rev !names

(* ─── parse ─────────────────────────────────────────────────────────── *)

(* Parse the [world.*] sections from the manifest text. Raises Manifest_error
   on a malformed world header, an unterminated spaces list, or a space that
   is claimed by two worlds (case A). *)
let parse_string (text : string) : world_map =
  let wm = empty_world_map () in
  let current = ref None in                          (* current world, if any *)
  let lines = String.split_on_char '\n' text in
  List.iter (fun raw ->
    let line = trim (strip_comment raw) in
    if line = "" then ()
    else begin
      match world_header line with
      | Some w ->
          current := Some w;
          if not (Hashtbl.mem wm.world_spaces w) then
            Hashtbl.replace wm.world_spaces w [];
          if not (Hashtbl.mem wm.wstructs w) then
            Hashtbl.replace wm.wstructs w empty_struct
      | None ->
          if is_section_header line then current := None    (* left [world.*] *)
          else begin
            match !current with
            | None -> ()                             (* a line outside a world *)
            | Some w ->
                (* inside a [world.<w>] section: look for "spaces = [...]" *)
                (match String.index_opt line '=' with
                 | Some i ->
                     let key = trim (String.sub line 0 i) in
                     let rhs =
                       String.sub line (i + 1) (String.length line - i - 1) in
                     let upd f =
                       let s = match Hashtbl.find_opt wm.wstructs w with
                         | Some s -> s | None -> empty_struct in
                       Hashtbl.replace wm.wstructs w (f s)
                     in
                     (match key with
                      | "spaces" ->
                          let names = parse_spaces_value rhs in
                          List.iter (fun sp ->
                            (match Hashtbl.find_opt wm.space_world sp with
                             | Some w' when w' <> w ->
                                 raise (Manifest_error (Printf.sprintf
                                   "yon.toml: space '%s' is declared in two \
                                    worlds ('%s' and '%s'); a space belongs to \
                                    exactly one world" sp w' w))
                             | _ -> ());
                            Hashtbl.replace wm.space_world sp w
                          ) names;
                          let prev =
                            match Hashtbl.find_opt wm.world_spaces w with
                            | Some l -> l | None -> [] in
                          Hashtbl.replace wm.world_spaces w (prev @ names)
                      | "objects" ->
                          upd (fun s -> { s with ws_objects = parse_spaces_value rhs })
                      | "coproduct" ->
                          upd (fun s -> { s with ws_coproduct = parse_spaces_value rhs })
                      | "product" ->
                          upd (fun s -> { s with ws_product = parse_spaces_value rhs })
                      | "quotient" ->
                          (match parse_spaces_value rhs with
                           | [base; rel] ->
                               upd (fun s -> { s with ws_quotient = Some (base, rel) })
                           | _ ->
                               raise (Manifest_error (Printf.sprintf
                                 "yon.toml: world '%s' quotient must be a pair \
                                  [Base, Relation]" w)))
                      | "subset_of" ->
                          (match parse_spaces_value rhs with
                           | [v] -> upd (fun s -> { s with ws_subset_of = Some v })
                           | _ ->
                               raise (Manifest_error (Printf.sprintf
                                 "yon.toml: world '%s' subset_of must be a \
                                  single \"Parent\"" w)))
                      | _ -> ())
                 | None -> ())
          end
    end
  ) lines;
  wm

let parse_file (path : string) : world_map =
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  parse_string s

(* ─── queries ───────────────────────────────────────────────────────── *)

let world_of_space (wm : world_map) (sp : string) : string option =
  Hashtbl.find_opt wm.space_world sp

let is_empty (wm : world_map) : bool =
  Hashtbl.length wm.space_world = 0

(* ── synthesise the explicit world declaration the parser accepts ───── *)

(* Render a world's [world.<Name>] structure as the surface text parser and
   tycheck already accept. At most one construction applies (coproduct >
   product > quotient > subset); with none, the world is the trivial site
   over its objects, each rendered "Code is <obj>". This is how a
   manifest-declared world reaches the existing front-end unchanged. *)
let world_decl_text (name : string) (ws : world_struct) : string =
  match ws.ws_coproduct, ws.ws_product, ws.ws_quotient, ws.ws_subset_of with
  | (_ :: _ as cs), _, _, _ ->
      Printf.sprintf "world %s = %s" name (String.concat " + " cs)
  | _, (_ :: _ as ps), _, _ ->
      Printf.sprintf "world %s = %s" name (String.concat " * " ps)
  | _, _, Some (base, rel), _ ->
      Printf.sprintf "world %s = %s / %s" name base rel
  | _, _, _, Some parent ->
      Printf.sprintf "world %s subset of %s" name parent
  | [], [], None, None ->
      let body =
        String.concat " "
          (List.map (fun o -> Printf.sprintf "Code is %s" o) ws.ws_objects) in
      Printf.sprintf "world %s { %s }" name body

(* Every manifest-declared world, one declaration per line, name-sorted for a
   stable reconstruction. *)
let all_world_decls (wm : world_map) : string =
  Hashtbl.fold (fun name ws acc -> (name, ws) :: acc) wm.wstructs []
  |> List.sort (fun (a, _) (b, _) -> compare a b)
  |> List.map (fun (name, ws) -> world_decl_text name ws)
  |> String.concat "\n"

(* The spaces a world groups, in declaration order. *)
let spaces_of_world (wm : world_map) (w : string) : string list =
  match Hashtbl.find_opt wm.world_spaces w with Some l -> l | None -> []

(* ─── boundary check over a program ─────────────────────────────────── *)

(* The mailbox name is the bare space name; "wire to S" and "be s holds X.s"
   both name the target space directly. The sender space, when the package
   declares it via "init Name as Space", is that name. *)

let sender_spaces (p : program) : string list =
  List.filter_map (function
    | TopSpaceInit (name, _) -> Some name
    | _ -> None) p

(* Wire targets reached through "be s holds X.stream" (TopImportFrom: the
   third field is the target space) together with their source location. *)
let import_targets (p : program) : (string * location) list =
  List.filter_map (function
    | TopImportFrom (_, _, sp, loc) -> Some (sp, loc)
    | _ -> None) p

(* Spaces the program declares with "space S ..." (TopSpace). *)
let declared_spaces (p : program) : string list =
  List.filter_map (function
    | TopSpace sd -> Some sd.sd_name
    | _ -> None) p

(* Run the boundary checks. Returns a list of (location, message) errors; an
   empty list means the program respects the world boundaries. The manifest
   itself (case A) is enforced at parse time and raises before this runs. *)
let check_program (wm : world_map) (p : program) : (location * string) list =
  if is_empty wm then []                       (* no [world] declared: opt-in *)
  else begin
    let errors = ref [] in
    let add loc msg = errors := (loc, msg) :: !errors in

    (* The sender world: the world of the space the package initialises. If
       the package does not declare its own space, the cross-boundary case (C)
       cannot be decided here and only the target cases (B) apply. *)
    let sender_world =
      match sender_spaces p with
      | s :: _ -> world_of_space wm s
      | []     -> None
    in

    (* Case D: a declared/initialised space that belongs to no world. *)
    List.iter (fun s ->
      if world_of_space wm s = None then
        add dummy_loc (Printf.sprintf
          "space '%s' is initialised by this package but is not listed in any \
           [world.<Name>] in yon.toml; every space must belong to exactly one \
           world" s)
    ) (sender_spaces p);
    List.iter (fun s ->
      if world_of_space wm s = None then
        add dummy_loc (Printf.sprintf
          "space '%s' is declared but is not listed in any [world.<Name>] in \
           yon.toml; every space must belong to exactly one world" s)
    ) (declared_spaces p);

    (* Cases B and C, per wire target. *)
    List.iter (fun (target, loc) ->
      match world_of_space wm target with
      | None ->
          (* Case B: the wire names a space no world declares. *)
          add loc (Printf.sprintf
            "wire target space '%s' is not listed in any [world.<Name>] in \
             yon.toml" target)
      | Some tw ->
          (* Case C: a wire crossing the sender's world boundary. *)
          (match sender_world with
           | Some sw when sw <> tw ->
               add loc (Printf.sprintf
                 "wire crosses a world boundary: this package lives in world \
                  '%s' but space '%s' belongs to world '%s'; spaces in \
                  different worlds cannot wire to each other (use a geometric \
                  morphism to cross worlds)" sw target tw)
           | _ -> ())
    ) (import_targets p);

    List.rev !errors
  end
