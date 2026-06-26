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
  mutable pkg_entry : string option;   (* [package] entry = "<Place>" *)
}

(* A problem in the [world] sections. The manifest has no .yon source
   locations, so the message names the manifest concern in plain words. *)
exception Manifest_error of string

let empty_world_map () = {
  space_world  = Hashtbl.create 16;
  world_spaces = Hashtbl.create 8;
  wstructs     = Hashtbl.create 8;
  pkg_entry    = None;
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
  let in_package = ref false in                      (* inside [package] *)
  let lines = String.split_on_char '\n' text in
  List.iter (fun raw ->
    let line = trim (strip_comment raw) in
    if line = "" then ()
    else begin
      match world_header line with
      | Some w ->
          current := Some w; in_package := false;
          if not (Hashtbl.mem wm.world_spaces w) then
            Hashtbl.replace wm.world_spaces w [];
          if not (Hashtbl.mem wm.wstructs w) then
            Hashtbl.replace wm.wstructs w empty_struct
      | None ->
          if is_section_header line then begin
            current := None;                          (* left [world.*] *)
            in_package := (line = "[package]")
          end
          else if !in_package then begin
            (* inside [package]: pick up `entry = "<Space>"` *)
            match String.index_opt line '=' with
            | Some i when trim (String.sub line 0 i) = "entry" ->
                let rhs =
                  String.sub line (i + 1) (String.length line - i - 1) in
                (match parse_spaces_value rhs with
                 | [v] -> wm.pkg_entry <- Some v
                 | _ ->
                     raise (Manifest_error
                       "yon.toml: [package] entry must be a single \"<Place>\""))
            | _ -> ()
          end
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
  (* open_in / really_input_string raise Sys_error if yon.toml is a directory,
     unreadable, or removed after the existence check. Re-raise as the typed
     Manifest_error so the driver's existing handler reports it cleanly instead
     of crashing with a raw Sys_error. *)
  let ic =
    try open_in path
    with Sys_error msg ->
      raise (Manifest_error (Printf.sprintf "cannot read manifest '%s': %s" path msg))
  in
  match
    (try
       let n = in_channel_length ic in
       let s = really_input_string ic n in
       close_in ic; s
     with Sys_error msg ->
       (try close_in ic with _ -> ());
       raise (Manifest_error (Printf.sprintf "cannot read manifest '%s': %s" path msg)))
  with s -> parse_string s

(* ─── queries ───────────────────────────────────────────────────────── *)

let world_of_space (wm : world_map) (sp : string) : string option =
  Hashtbl.find_opt wm.space_world sp

let is_empty (wm : world_map) : bool =
  Hashtbl.length wm.space_world = 0

(* ── build the world declarations as native AST nodes ───────────────── *)

(* A world's [world.<Name>] structure as a world_decl record. Every declared
   construction is carried through INDEPENDENTLY: desugar_world_decl emits one
   site generator per non-empty field, and the sheaf checker consumes each.
   (Previously this collapsed to AT MOST ONE by a priority order coproduct >
   product > quotient > subset, silently dropping the others -- so a world with
   both a coproduct and a quotient lost its quotient generator and the
   quotient's Rel-invariance sheaf condition was NEVER checked, a vacuous-check
   soundness hole. The world_decl record has a separate field per construction
   precisely so all can coexist; the manifest now matches desugar instead of
   diverging from it.) With no construction, the world is the trivial site over
   its objects, each an `is` world_place named "Code". Built directly on the
   AST -- no surface text, no re-parse. *)
let world_decl_of (name : string) (ws : world_struct) : world_decl =
  let base = {
    wd_name = name; wd_places = [];
    wd_product_of = []; wd_coproduct_of = [];
    wd_coequalizer_of = None; wd_quotient_of = None; wd_subset_of = None;
    wd_loc = dummy_loc;
  } in
  let has_construction =
    ws.ws_coproduct <> [] || ws.ws_product <> []
    || ws.ws_quotient <> None || ws.ws_subset_of <> None in
  if has_construction then
    { base with
      wd_coproduct_of = ws.ws_coproduct;
      wd_product_of   = ws.ws_product;
      wd_quotient_of  = ws.ws_quotient;
      wd_subset_of    = ws.ws_subset_of }
  else
    let places =
      List.map (fun o ->
        { wp_name = "Code"; wp_descriptor = PdIdList [o]; wp_loc = dummy_loc })
        ws.ws_objects in
    { base with wd_places = places }

(* Every manifest-declared world as a TopWorld decl, name-sorted for stability. *)
let world_decls (wm : world_map) : top_decl list =
  Hashtbl.fold (fun name ws acc -> (name, ws) :: acc) wm.wstructs []
  |> List.sort (fun (a, _) (b, _) -> compare a b)
  |> List.map (fun (name, ws) -> TopWorld (world_decl_of name ws))

(* The spaces a world groups, in declaration order. *)
let spaces_of_world (wm : world_map) (w : string) : string list =
  match Hashtbl.find_opt wm.world_spaces w with Some l -> l | None -> []

(* ─── boundary check over a program ─────────────────────────────────── *)

(* The mailbox name is the bare space name; "wire to S" and "be s holds X.s"
   both name the target space directly. A package's own space is now derived
   from the filesystem (directory = space, via package_layout), so there is no
   longer a surface `init Name as Space` declaration to read. *)

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
(* Case B + C for one sender. Each wire target must be a space some world
   declares (B); when the sending place's world is known, the target must lie
   in that same world (C). The sender is the place that holds the wire, and a
   place's world is the world of its space (its directory, via the toml). *)
let check_targets (wm : world_map) ~(sender_world : string option)
    (targets : (string * location) list) : (location * string) list =
  if is_empty wm then []                       (* no [world] declared: opt-in *)
  else
  List.filter_map (fun (target, loc) ->
    match world_of_space wm target with
    | None ->
        Some (loc, Printf.sprintf
          "wire target space '%s' is not listed in any [world.<Name>] in \
           yon.toml" target)
    | Some tw ->
        (match sender_world with
         | Some sw when sw <> tw ->
             Some (loc, Printf.sprintf
               "wire crosses a world boundary: the sending place lives in \
                world '%s' but space '%s' belongs to world '%s'; spaces in \
                different worlds cannot wire to each other (use a geometric \
                morphism to cross worlds)" sw target tw)
         | _ -> None)
  ) targets

(* Case D: a declared or initialised space that belongs to no world. The
   per-target cases (B, C) are checked per file by the driver, where the
   sending place's space -- hence its world -- is known. With no [world]
   declared the manifest is opt-in and nothing is constrained. *)
(* The place inherits the world of its space. A place declared in a file that
   sits in a space directory takes that space's world (from the toml). This
   rewrites the AST before type-checking: an unannotated place (pd_world =
   "__INFER") whose name the filesystem maps to a world is bound to it, so the
   place->space->world chain is resolved structurally rather than left to the
   unique-world heuristic (which cannot disambiguate across several worlds).
   A place already annotated, or one the map does not know, is left untouched. *)
let assign_place_worlds
    ?(world_of_space : string -> string option = fun _ -> None)
    (world_of_place : string -> string option) (p : program) : program =
  List.map (function
    | TopPlace pd when pd.pd_world = "__INFER" ->
        (match world_of_place pd.pd_name with
         | Some w -> TopPlace { pd with pd_world = w }
         | None -> TopPlace pd)
    | TopTopos td ->
        (* A topos gives its inline objects a world when they carry none (under
           the toml+filesystem model the inner places have no `in W`). Two
           residences, resolved here before tycheck, just like bare places:
             - `topos T in W`      -> the objects' world is W.
             - `topos T at Space`  -> the objects reside at Space, whose world
               comes from the toml ([world.X] spaces=[...]); resolve it via
               world_of_space. Without this the inner places stay __INFER and
               fail "refers to unknown world __INFER" (only the `in W` branch
               was handled before). *)
        let objs = List.map (fun pd ->
          if pd.pd_world = "__INFER" then
            (match td.tp_world with
             | Some w -> { pd with pd_world = w }
             | None ->
                 (match td.tp_at_space with
                  | Some sp ->
                      (match world_of_space sp with
                       | Some w -> { pd with pd_world = w }
                       | None -> pd)
                  | None -> pd))
          else pd) td.tp_objects in
        TopTopos { td with tp_objects = objs }
    | other -> other
  ) p

(* ─── filesystem-derived topos structure ────────────────────────────── *)

(* A topos now DERIVES its structure from the package layout instead of inline
   surface syntax. The parser produces every `topos_decl` with tp_objects = [],
   tp_at_space = None, tp_world = None; this pass FILLS those fields from the
   filesystem before tycheck/desugar/emit run. The record shape is UNCHANGED —
   downstream reads the same fields; we just populate them in the driver.

   For each `TopTopos td`:
     - tp_at_space <- Some space   (the space whose directory holds the topos file)
     - tp_objects  <- places_of_space space   (every TopPlace in that space)
     - tp_world    <- world_of_space space     (the space's world from yon.toml)

   The three callbacks are built by the driver at parse-assembly time, where the
   per-file space tag (ul_space) is still known (the merged program no longer
   carries per-file origin). Filling is purely additive: every existing consumer
   (tyenv.first_place_in_topos, tycheck TopTopos, assign_place_worlds, desugar)
   already tolerates an empty list, so a topos whose space is unknown is left as
   the parser produced it. *)
let assign_topos_structure
    ~(space_of_topos : string -> string option)
    ~(places_of_space : string -> place_decl list)
    ~(world_of_space : string -> string option)
    (p : program) : program =
  List.map (function
    | TopTopos td ->
        (match space_of_topos td.tp_name with
         | Some space ->
             (* tp_objects intentionally LEFT EMPTY. The space's places are
                already standalone TopPlace decls, type-checked and desugared
                independently; copying them into the topos here caused DOUBLE
                registration — a place with a `fun` member (e.g. Reading.samples)
                got its method declared twice -> compile error. The topos's
                categorical objects ARE the space's place-files; no downstream
                pass needs them duplicated. We still touch places_of_space so the
                labeled argument stays used. *)
             let _space_places = places_of_space space in
             TopTopos { td with
               tp_at_space = Some space;
               tp_world    = world_of_space space }
         | None ->
             (* space origin unknown for this topos: leave the parser's empty
                fields as-is (additive — downstream tolerates []). *)
             TopTopos td)
    | other -> other
  ) p

(* ONE topos per space (mandatory). `topos_count_of_space` maps a space name to
   the number of topos FILES the package layout found in that space's directory.
   `spaces` is every space the project declares (the directories holding .yon).
   A space with 0 or >1 topos files is a structural error: with the filesystem
   driving the ontology, each space is exactly one topos. Returns a list of
   human-readable messages (empty = ok); the driver prints them and exits non
   zero, matching the existing manifest/entrypoint diagnostics. *)
let check_one_topos_per_space
    ~(topos_count_of_space : string -> int)
    (spaces : string list) : string list =
  List.filter_map (fun sp ->
    let n = topos_count_of_space sp in
    if n = 1 then None
    else if n = 0 then
      Some (Printf.sprintf
        "space '%s' declares no topos: every space must contain exactly one \
         topos file (got 0)" sp)
    else
      Some (Printf.sprintf
        "space '%s' declares %d topos files: every space must contain exactly \
         one topos (got %d)" sp n n)
  ) spaces

(* The project entrypoint place is filesystem/package metadata: the driver has
   already proved that it is unique, lives at the package root, and shares its
   file with [main].  It is not an object of any declared world, so after that
   validation it must not enter world inference or Core place emission. *)
let remove_entrypoint_container ~(entry_name : string) (p : program) : program =
  List.filter (function
    | TopPlace pd when pd.pd_name = entry_name -> false
    | _ -> true)
    p

let check_program (wm : world_map) (p : program) : (location * string) list =
  if is_empty wm then []
  else
    List.filter_map (fun s ->
      if world_of_space wm s = None then
        Some (dummy_loc, Printf.sprintf
          "space '%s' is declared but is not listed in any [world.<Name>] in \
           yon.toml; every space must belong to exactly one world" s)
      else None
    ) (declared_spaces p)
