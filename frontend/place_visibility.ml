(* place_visibility.ml — visibility sets for places.
 *
 * For each place P in the program, V(P) is the set of names (fields,
 * operations, related places) that P can observe. A proposition φ
 * mentioning a name x not-in V(P) evaluates to HUnknown at P.
 *
 * Visibility is computed from the place declaration:
 *
 *   - Direct: all fields and operations declared in P
 *   - Transitive: if P has a field of type Q (another place), then
 *     P can observe Q's fields too (via field access)
 *   - World: P can observe all worlds it's parameterized over
 *
 * This is the operational realization of the Yoneda principle:
 * an object is determined by its incoming maps; visibility tracks
 * which incoming maps a place actually possesses.
 *)

open Surface_ast

(* ─── Visibility set ───────────────────────────────────────────────── *)

type visibility = {
  vis_place : string;                  (* the place this visibility describes *)
  vis_fields : string list;            (* directly accessible field names *)
  vis_operations : string list;        (* directly accessible operation names *)
  vis_qualified_ops : string list;     (* qualified Place__op names *)
  vis_related_places : string list;    (* places reachable via fields *)
}

let empty_for (name : string) : visibility = {
  vis_place = name;
  vis_fields = [];
  vis_operations = [];
  vis_qualified_ops = [];
  vis_related_places = [];
}

(* ─── Computing visibility from a place declaration ────────────────── *)

let direct_field_names (pd : place_decl) : string list =
  List.filter_map
    (function
      | FoField f -> Some f.fd_name
      | FoOp _ -> None
      | FoCell _ -> None
      | FoLaw _ -> None)
    pd.pd_members

let direct_operation_names (pd : place_decl) : string list =
  List.filter_map
    (function
      | FoOp op -> Some op.op_name
      | FoField _ -> None
      | FoCell _ -> None
      | FoLaw _ -> None)
    pd.pd_members

(* Find user-place types referenced by a place's fields. *)
let related_places (pd : place_decl) : string list =
  let rec collect_from_ty = function
    | TyUser n -> [n]
    | TyList inner | TyStream (inner, _) -> collect_from_ty inner
    | TyMap (k, v) -> collect_from_ty k @ collect_from_ty v
    | _ -> []
  in
  let from_field = function
    | FoField f -> collect_from_ty f.fd_ty
    | FoOp _ -> []
    | FoCell _ -> []
    | FoLaw _ -> []
  in
  List.concat_map from_field pd.pd_members
  |> List.sort_uniq compare

(* Build the visibility for a single place from its declaration. *)
let from_place_decl (pd : place_decl) : visibility =
  let fields = direct_field_names pd in
  let ops = direct_operation_names pd in
  let qualified = List.map (fun o -> pd.pd_name ^ "__" ^ o) ops in
  let related = related_places pd in
  { vis_place = pd.pd_name;
    vis_fields = fields;
    vis_operations = ops;
    vis_qualified_ops = qualified;
    vis_related_places = related; }

(* ─── Visibility table ─────────────────────────────────────────────── *)

(* Map from place name to its visibility. Constructed once per program. *)

type vis_table = (string * visibility) list

let build_table (places : place_decl list) : vis_table =
  List.map (fun pd -> (pd.pd_name, from_place_decl pd)) places

let lookup (tbl : vis_table) (place_name : string) : visibility option =
  List.assoc_opt place_name tbl

(* ─── Visibility-aware queries ─────────────────────────────────────── *)

(* Does place P see the field/operation/place named n? *)

let sees_field (v : visibility) (field_name : string) : bool =
  List.mem field_name v.vis_fields

let sees_operation (v : visibility) (op_name : string) : bool =
  List.mem op_name v.vis_operations
  || List.mem op_name v.vis_qualified_ops

let sees_place (v : visibility) (place_name : string) : bool =
  place_name = v.vis_place
  || List.mem place_name v.vis_related_places

(* General "does P see this name" query. Used by the Heyting evaluator
 * when checking whether a variable mention is observable from the
 * current place. *)
let sees_name (v : visibility) (n : string) : bool =
  sees_field v n
  || sees_operation v n
  || sees_place v n

(* ─── The "global" place: terminal object of the topos ─────────────── *)

(* When no current place is set (e.g., at top level outside any fun),
 * we use a special "global" visibility that sees everything. This
 * corresponds to the terminal object 1 of the topos: it has the
 * unique map into every object, so it observes the value of every
 * proposition.
 *
 * Operationally: if a value lives at the global place, comparison
 * between it and any other value succeeds (no UNKNOWN can arise from
 * pure visibility). UNKNOWN only arises when computing inside a
 * specific place that does not see one of the operands.
 *)

let global_visibility : visibility = {
  vis_place = "__global";
  vis_fields = [];           (* the global "sees everything" predicate
                                * is handled by sees_name returning true
                                * unconditionally for this special place *)
  vis_operations = [];
  vis_qualified_ops = [];
  vis_related_places = [];
}

let is_global (v : visibility) : bool =
  v.vis_place = "__global"

(* The all-knowing version of sees_name. *)
let sees_name_at (v : visibility) (n : string) : bool =
  if is_global v then true
  else sees_name v n
