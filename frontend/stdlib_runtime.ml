(* stdlib_runtime.ml — concrete runtime for the Yon standard library.
 *
 * Each stdlib place is realized as:
 *   - A storage backend (OCaml mutable structure indexed by an integer id)
 *   - Operations that read/write the storage and return encoded Yon Core values
 *
 * Operations are hooked into Builtins.try_reduce_builtin so that
 * surface Yon programs can invoke List.cons, Map.get, Space.set, etc.
 * via the standard qualified-call syntax.
 *
 * The id-based indirection lets us model mutable state inside the
 * pure Yon Core: a Space value is a Var "__space_<id>" that the
 * runtime maps to a ref cell. Operations resolve the id, mutate the
 * cell, and return the new value's encoding.
 *)

open Ast
open Builtins

(* ─── Counters and stores ──────────────────────────────────────────── *)

(* Each stdlib structure has its own integer-id store. We use Hashtbl
 * because we need O(1) lookup by id and the prototype doesn't care
 * about persistence. *)

let next_id : int ref = ref 0

let fresh_id () : int =
  let n = !next_id in
  incr next_id;
  n

(* ─── List runtime ─────────────────────────────────────────────────── *)

(* A list is stored as an int -> term list mapping. Operations: empty,
 * cons, head, tail, length, get_at, append. *)

let list_store : (int, term list) Hashtbl.t = Hashtbl.create 64

let encode_list (id : int) : term = Var (Printf.sprintf "__list_%d" id)

let decode_list_id (t : term) : int option =
  match t with
  | Var name when String.length name > 7 && String.sub name 0 7 = "__list_" ->
      (try Some (int_of_string (String.sub name 7 (String.length name - 7)))
       with _ -> None)
  | _ -> None

let list_empty () : term =
  let id = fresh_id () in
  Hashtbl.add list_store id [];
  encode_list id

let list_cons (head : term) (rest : term) : term option =
  match decode_list_id rest with
  | None -> None
  | Some id ->
      let existing = try Hashtbl.find list_store id with Not_found -> [] in
      let new_id = fresh_id () in
      Hashtbl.add list_store new_id (head :: existing);
      Some (encode_list new_id)

let list_head (lst : term) : term option =
  match decode_list_id lst with
  | None -> None
  | Some id ->
      (match Hashtbl.find_opt list_store id with
       | Some (h :: _) -> Some h
       | _ -> None)

let list_tail (lst : term) : term option =
  match decode_list_id lst with
  | None -> None
  | Some id ->
      (match Hashtbl.find_opt list_store id with
       | Some (_ :: t) ->
           let new_id = fresh_id () in
           Hashtbl.add list_store new_id t;
           Some (encode_list new_id)
       | _ -> None)

let list_length (lst : term) : term option =
  match decode_list_id lst with
  | None -> None
  | Some id ->
      (match Hashtbl.find_opt list_store id with
       | Some items -> Some (encode_number (float_of_int (List.length items)))
       | None -> None)

let list_is_empty (lst : term) : term option =
  match decode_list_id lst with
  | None -> None
  | Some id ->
      (match Hashtbl.find_opt list_store id with
       | Some items -> Some (encode_bool (items = []))
       | None -> None)

(* Append two lists. *)
let list_append (a : term) (b : term) : term option =
  match decode_list_id a, decode_list_id b with
  | Some ida, Some idb ->
      let la = try Hashtbl.find list_store ida with Not_found -> [] in
      let lb = try Hashtbl.find list_store idb with Not_found -> [] in
      let new_id = fresh_id () in
      Hashtbl.add list_store new_id (la @ lb);
      Some (encode_list new_id)
  | _ -> None

(* ─── Map runtime ──────────────────────────────────────────────────── *)

(* A Map is stored as a Hashtbl of term -> term, indexed by id.
 * Keys and values are encoded Yon terms (strings, numbers, or
 * arbitrary terms). *)

let map_store : (int, (term, term) Hashtbl.t) Hashtbl.t = Hashtbl.create 64

let encode_map (id : int) : term = Var (Printf.sprintf "__map_%d" id)

let decode_map_id (t : term) : int option =
  match t with
  | Var name when String.length name > 6 && String.sub name 0 6 = "__map_" ->
      (try Some (int_of_string (String.sub name 6 (String.length name - 6)))
       with _ -> None)
  | _ -> None

let map_empty () : term =
  let id = fresh_id () in
  Hashtbl.add map_store id (Hashtbl.create 16);
  encode_map id

let map_set (m : term) (k : term) (v : term) : term option =
  match decode_map_id m with
  | None -> None
  | Some id ->
      let new_id = fresh_id () in
      let original = try Hashtbl.find map_store id
                     with Not_found -> Hashtbl.create 16 in
      let new_tbl = Hashtbl.copy original in
      Hashtbl.replace new_tbl k v;
      Hashtbl.add map_store new_id new_tbl;
      Some (encode_map new_id)

let map_get (m : term) (k : term) : term option =
  match decode_map_id m with
  | None -> None
  | Some id ->
      (match Hashtbl.find_opt map_store id with
       | None -> None
       | Some tbl ->
           (match Hashtbl.find_opt tbl k with
            | Some v -> Some v
            | None -> Some (Var "__absent")))

let map_has (m : term) (k : term) : term option =
  match decode_map_id m with
  | None -> None
  | Some id ->
      (match Hashtbl.find_opt map_store id with
       | None -> None
       | Some tbl -> Some (encode_bool (Hashtbl.mem tbl k)))

let map_size (m : term) : term option =
  match decode_map_id m with
  | None -> None
  | Some id ->
      (match Hashtbl.find_opt map_store id with
       | None -> None
       | Some tbl -> Some (encode_number (float_of_int (Hashtbl.length tbl))))

(* ─── Space runtime ────────────────────────────────────────────────── *)

(* A Space is a mutable reference cell. Unlike List/Map (which are
 * persistent in the sense that each operation produces a new id),
 * Space is genuinely mutable: set/get modify the cell in place.
 *
 * This is the kernel-level primitive for state in Yon. The functional
 * surface (let-binding, becomes) compiles to Space operations.
 *
 * World-indexed Space (Yoneda multi-tenancy realization):
 * 
 * A Space is allocated relative to a world tag. The same surface code
 * `new Space initial_value` evaluated in two different world contexts
 * (e.g., two different tenants, two different regions) produces TWO
 * DIFFERENT spaces with independent state. This realizes the topos-
 * theoretic intuition: a Space is a section of a sheaf, and sections
 * over disjoint world tags are independent.
 *
 * Implementation: every Space carries a (world_tag, id) pair. The
 * world_tag is read from a global ref `current_world_tag` that the
 * reducer updates when entering a `with R of P { ... }` block.
 *)

(* The current world tag. None means "global" (terminal object of the
 * topos: a Space allocated at global is shared across all worlds). *)
let current_world_tag : string option ref = ref None

let set_current_world_tag (tag : string option) : unit =
  current_world_tag := tag

let get_current_world_tag () : string option = !current_world_tag

(* Space store keyed by (world_tag_or_empty, fresh_id). Two spaces with
 * the same fresh_id but different world tags are independent. *)
let space_store : (string * int, term ref) Hashtbl.t = Hashtbl.create 64

(* Reset for tests. *)
let reset_space_store () =
  Hashtbl.reset space_store;
  current_world_tag := None

let world_tag_of_opt = function
  | None -> "__global"
  | Some t -> t

let encode_space (world : string) (id : int) : term =
  Var (Printf.sprintf "__space_%s_%d" world id)

let decode_space_id (t : term) : (string * int) option =
  match t with
  | Var name when String.length name > 8 && String.sub name 0 8 = "__space_" ->
      let rest = String.sub name 8 (String.length name - 8) in
      (* rest = "<world>_<id>". Find LAST underscore to split. *)
      (try
        let last_us = String.rindex rest '_' in
        let world = String.sub rest 0 last_us in
        let id_str = String.sub rest (last_us+1) (String.length rest - last_us - 1) in
        Some (world, int_of_string id_str)
      with _ -> None)
  | _ -> None

let space_new (init : term) : term =
  let world = world_tag_of_opt !current_world_tag in
  let id = fresh_id () in
  Hashtbl.add space_store (world, id) (ref init);
  encode_space world id

let space_get (sp : term) : term option =
  match decode_space_id sp with
  | None -> None
  | Some key ->
      (match Hashtbl.find_opt space_store key with
       | Some cell -> Some !cell
       | None -> None)

let space_set (sp : term) (v : term) : term option =
  match decode_space_id sp with
  | None -> None
  | Some key ->
      (match Hashtbl.find_opt space_store key with
       | Some cell -> cell := v; Some Unit
       | None -> None)

(* ─── Stream runtime (P8 #87) ──────────────────────────────────────── *)

(* A Stream is an in-memory FIFO buffer identified by an integer stream id.
 * Stream.make(target_heap) -> the encoded stream id as Var "__stream_<id>"
 * Stream.send(s, v) -> 0
 * Stream.recv(s) -> v (FIFO order), or -1 if empty. *)

let stream_store : (int, term Queue.t) Hashtbl.t = Hashtbl.create 8
let stream_counter = ref 0

let encode_stream_id (id : int) : term =
  encode_number (float_of_int id)

let decode_stream_id (t : term) : int option =
  match decode_number t with
  | Some f -> Some (int_of_float f)
  | None -> None

let stream_make (_target_heap : term) : term =
  let id = !stream_counter in
  incr stream_counter;
  Hashtbl.add stream_store id (Queue.create ());
  encode_stream_id id

let stream_send (sid : term) (v : term) : term option =
  match decode_stream_id sid with
  | None -> None
  | Some id ->
      (match Hashtbl.find_opt stream_store id with
       | Some q -> Queue.add v q; Some (encode_number 0.0)
       | None -> None)

let stream_recv (sid : term) : term option =
  match decode_stream_id sid with
  | None -> None
  | Some id ->
      (match Hashtbl.find_opt stream_store id with
       | Some q when not (Queue.is_empty q) ->
           Some (Queue.pop q)
       | _ -> Some (encode_number (-1.0)))

(* ─── Lattice runtime ──────────────────────────────────────────────── *)

(* Lattice of n dimensions of T: stored as a sparse Hashtbl keyed by
 * coordinate tuples. The Dense reduction would use a flat array; for
 * the prototype Sparse is sufficient.
 *
 * Coordinate tuples are represented as comma-separated strings since
 * OCaml Hashtbl on tuples requires care with hashing.
 *)

type lattice = {
  cells : (string, term) Hashtbl.t;
  default : term;
  dimensions : int;
}

let lattice_store : (int, lattice) Hashtbl.t = Hashtbl.create 64

let encode_lattice (id : int) : term = Var (Printf.sprintf "__lattice_%d" id)

let decode_lattice_id (t : term) : int option =
  match t with
  | Var name when String.length name > 10 && String.sub name 0 10 = "__lattice_" ->
      (try Some (int_of_string (String.sub name 10 (String.length name - 10)))
       with _ -> None)
  | _ -> None

(* Build a coordinate key from a list of integer indices. *)
let coord_key (indices : int list) : string =
  String.concat "," (List.map string_of_int indices)

(* Create a lattice with n dimensions and a default value. *)
let lattice_new (dims : int) (default : term) : term =
  let id = fresh_id () in
  let lat = {
    cells = Hashtbl.create 64;
    default;
    dimensions = dims;
  } in
  Hashtbl.add lattice_store id lat;
  encode_lattice id

(* Read a cell at the given coordinates. *)
let lattice_get (lat_term : term) (coords : int list) : term option =
  match decode_lattice_id lat_term with
  | None -> None
  | Some id ->
      (match Hashtbl.find_opt lattice_store id with
       | None -> None
       | Some lat ->
           if List.length coords <> lat.dimensions then None
           else
             let key = coord_key coords in
             match Hashtbl.find_opt lat.cells key with
             | Some v -> Some v
             | None -> Some lat.default)

(* Write to a cell (mutating). *)
let lattice_set (lat_term : term) (coords : int list) (v : term) : term option =
  match decode_lattice_id lat_term with
  | None -> None
  | Some id ->
      (match Hashtbl.find_opt lattice_store id with
       | None -> None
       | Some lat ->
           if List.length coords <> lat.dimensions then None
           else
             let key = coord_key coords in
             Hashtbl.replace lat.cells key v;
             Some Unit)

(* SCT-style cluster collapse: identify all cells in a cluster and
 * share their domain. This is the operational realization of
 * Theorem 1's structural component. *)
let lattice_union_cells (lat_term : term)
                        (cells_a : int list)
                        (cells_b : int list)
                        (combined_value : term) : term option =
  match decode_lattice_id lat_term with
  | None -> None
  | Some id ->
      (match Hashtbl.find_opt lattice_store id with
       | None -> None
       | Some lat ->
           let key_a = coord_key cells_a in
           let key_b = coord_key cells_b in
           Hashtbl.replace lat.cells key_a combined_value;
           Hashtbl.replace lat.cells key_b combined_value;
           Some Unit)

(* ─── PerfectMap runtime ───────────────────────────────────────────── *)

(* PerfectMap: like Map but with construction-time key set, enabling
 * O(1) reads without collisions. For the prototype, we implement
 * the Direct reduction: when keys are bounded integers, store in an
 * array.
 *
 * In a real implementation, CHD (compress-hash-displace) would build
 * a perfect hash function at construction; we approximate with a
 * plain Hashtbl but record the construction-time keys so that the
 * "perfect" property could be enforced.
 *)

type perfect_map = {
  pm_table : (term, term) Hashtbl.t;
  pm_keys : term list;        (* construction-time key set *)
}

let pmap_store : (int, perfect_map) Hashtbl.t = Hashtbl.create 64

let encode_pmap (id : int) : term = Var (Printf.sprintf "__pmap_%d" id)

let decode_pmap_id (t : term) : int option =
  match t with
  | Var name when String.length name > 7 && String.sub name 0 7 = "__pmap_" ->
      (try Some (int_of_string (String.sub name 7 (String.length name - 7)))
       with _ -> None)
  | _ -> None

(* Build a PerfectMap from a list of (key, value) pairs. The keys must
 * all be distinct; we check this and return None if violated. *)
let pmap_build (entries : (term * term) list) : term option =
  let keys = List.map fst entries in
  let unique = List.sort_uniq compare keys in
  if List.length unique <> List.length keys then None
  else
    let tbl = Hashtbl.create (List.length entries * 2) in
    List.iter (fun (k, v) -> Hashtbl.add tbl k v) entries;
    let pm = { pm_table = tbl; pm_keys = keys } in
    let id = fresh_id () in
    Hashtbl.add pmap_store id pm;
    Some (encode_pmap id)

let pmap_get (m : term) (k : term) : term option =
  match decode_pmap_id m with
  | None -> None
  | Some id ->
      (match Hashtbl.find_opt pmap_store id with
       | None -> None
       | Some pm ->
           match Hashtbl.find_opt pm.pm_table k with
           | Some v -> Some v
           | None -> Some (Var "__absent"))

let pmap_keys (m : term) : term option =
  match decode_pmap_id m with
  | None -> None
  | Some id ->
      (match Hashtbl.find_opt pmap_store id with
       | None -> None
       | Some pm ->
           (* Build a list out of the keys. *)
           let lst_id = fresh_id () in
           Hashtbl.add list_store lst_id pm.pm_keys;
           Some (encode_list lst_id))

let pmap_size (m : term) : term option =
  match decode_pmap_id m with
  | None -> None
  | Some id ->
      (match Hashtbl.find_opt pmap_store id with
       | None -> None
       | Some pm -> Some (encode_number (float_of_int (List.length pm.pm_keys))))

(* ─── Hook into Builtins.try_reduce_builtin ────────────────────────── *)

(* We expose a try_reduce_stdlib function that the main evaluator
 * calls after Builtins.try_reduce_builtin returns None. It handles
 * qualified calls of the form Place__operation(args). *)

(* Decode a decoded-number list of indices from a term. The argument
 * is expected to be a list-encoded term whose elements are encoded
 * numbers. *)
let decode_int_coords (t : term) : int list option =
  match decode_list_id t with
  | None ->
      (* Single number: treat as 1-D coordinate. *)
      (match decode_number t with
       | Some n -> Some [int_of_float n]
       | None -> None)
  | Some id ->
      (match Hashtbl.find_opt list_store id with
       | None -> None
       | Some elements ->
           let coords = List.filter_map decode_number elements in
           if List.length coords = List.length elements
           then Some (List.map int_of_float coords)
           else None)

let try_reduce_stdlib (t : term) : term option =
  match t with
  (* List operations *)
  | App (Var "List__empty", _) ->
      Some (list_empty ())
  | App (App (Var "List__cons", h), rest) ->
      list_cons h rest
  | App (Var "List__head", lst) ->
      list_head lst
  | App (Var "List__tail", lst) ->
      list_tail lst
  | App (Var "List__length", lst) ->
      list_length lst
  | App (Var "List__is_empty", lst) ->
      list_is_empty lst
  | App (App (Var "List__append", a), b) ->
      list_append a b

  (* Map operations *)
  | App (Var "Map__empty", _) ->
      Some (map_empty ())
  | App (App (App (Var "Map__set", m), k), v) ->
      map_set m k v
  | App (App (Var "Map__get", m), k) ->
      map_get m k
  | App (App (Var "Map__has", m), k) ->
      map_has m k
  | App (Var "Map__size", m) ->
      map_size m

  (* Space operations *)
  | App (Var "Space__new", init) ->
      Some (space_new init)
  | App (Var "Space__make", init) ->   (* alias to avoid `new` keyword clash *)
      Some (space_new init)
  | App (Var "Space__get", sp) ->
      space_get sp
  | App (App (Var "Space__set", sp), v) ->
      space_set sp v

  (* Stream operations (P8 #87) *)
  | App (Var "Stream__make", target_heap) ->
      Some (stream_make target_heap)
  | App (App (Var "Stream__send", sid), v) ->
      stream_send sid v
  | App (Var "Stream__recv", sid) ->
      stream_recv sid

  (* Lattice operations.
     Lattice__new(dims, default): create a new lattice.
     Lattice__get(lat, coord_list): read a cell.
     Lattice__set(lat, coord_list, value): write a cell. *)
  | App (App (Var "Lattice__new", dims_t), default) ->
      (match decode_number dims_t with
       | Some d -> Some (lattice_new (int_of_float d) default)
       | None -> None)
  | App (App (Var "Lattice__get", lat), coords) ->
      (match decode_int_coords coords with
       | Some cs -> lattice_get lat cs
       | None -> None)
  | App (App (App (Var "Lattice__set", lat), coords), v) ->
      (match decode_int_coords coords with
       | Some cs -> lattice_set lat cs v
       | None -> None)

  (* PerfectMap operations.
     We expose PerfectMap__build only with a list-of-pairs encoded as
     two lists (keys + values) for simplicity. *)
  | App (App (Var "PerfectMap__build_from", keys_lst), values_lst) ->
      (match decode_list_id keys_lst, decode_list_id values_lst with
       | Some kid, Some vid ->
           let keys = try Hashtbl.find list_store kid with Not_found -> [] in
           let vals = try Hashtbl.find list_store vid with Not_found -> [] in
           if List.length keys = List.length vals then
             pmap_build (List.combine keys vals)
           else None
       | _ -> None)
  | App (App (Var "PerfectMap__get", m), k) ->
      pmap_get m k
  | App (Var "PerfectMap__keys", m) ->
      pmap_keys m
  | App (Var "PerfectMap__size", m) ->
      pmap_size m

  | _ -> None

(* ─── Register stdlib operations in a type environment ────────────── *)

(* This is the type-checker side: declare stdlib places + operations
 * so that surface programs can reference them.
 *
 * Each stdlib place is registered as a place-with-effects whose
 * operations correspond to the runtime hooks above. The actual
 * implementations are in the runtime; the type checker only sees
 * the signatures.
 *)

(* We don't directly modify Tyenv here to avoid a dependency cycle;
 * the registration is done lazily in main.ml when the test harness
 * builds the environment. *)

let stdlib_signatures : (string * (string * Surface_ast.ty list * Surface_ast.ty) list) list =
  let open Surface_ast in
  let tnum = TyPrim "number" in
  let tbool = TyPrim "boolean" in
  let tunit = TyPrim "unit" in
  let tunk = TyPrim "unknown" in
  let tlist t = TyList t in
  [
    "List", [
      "empty", [tunit], TyList tunk;
      "cons", [tunk; tlist tunk], tlist tunk;
      "head", [tlist tunk], tunk;
      "tail", [tlist tunk], tlist tunk;
      "length", [tlist tunk], tnum;
      "is_empty", [tlist tunk], tbool;
      "append", [tlist tunk; tlist tunk], tlist tunk;
      "reverse", [tlist tunk], tlist tunk;
    ];
    "Map", [
      "empty", [], TyUser "Map";
      "set", [TyUser "Map"; tunk; tunk], TyUser "Map";
      "get", [TyUser "Map"; tunk], tnum;
      "has", [TyUser "Map"; tunk], tbool;
      "size", [TyUser "Map"], tnum;
    ];
    (* HashMap is a real O(1) hash table via a content-addressed directory +
     * xheap. A surface alias of Map, for naming clarity. *)
    "HashMap", [
      "empty", [], TyUser "Map";
      "set", [TyUser "Map"; tunk; tunk], TyUser "Map";
      "get", [TyUser "Map"; tunk], tnum;
      "has", [TyUser "Map"; tunk], tbool;
      "size", [TyUser "Map"], tnum;
      "to_stream", [TyUser "Map"], tlist tunk;
      (* orbital ops dedupli per G_24 orbita *)
      "orbital_set", [TyUser "Map"; tnum; tnum], TyUser "Map";
      "orbital_get", [TyUser "Map"; tnum], tnum;
      (* Pluggable canonicalizer.
       * canon_id: 0=identity, 1=G_24, 2=M_24 weight, 3=Co_0 one-shot,
       *           4=Co_0 BFS bounded, 5=popcount, 6=mod_8 *)
      "orbital_set_with", [TyUser "Map"; tnum; tnum; tnum], TyUser "Map";
      "orbital_get_with", [TyUser "Map"; tnum; tnum], tnum;
    ];
    (* HSH — History Store, Hierarchical. A backward prover with three views:
     * hash (O(1) membership), voyager (witness extraction), merkle (sharing
     * of the H_i levels). *)
    "HSH", [
      "empty", [tnum], tnum;                     (* HSH.empty(e) -> store *)
      "empty_mod", [tnum; tnum], tnum;            (* HSH.empty_mod(e, M) -> store Z_M *)
      "step", [tnum; tnum; tnum], tnum;           (* HSH.step(store, a_i, mod) *)
      "contains", [tnum; tnum; tnum], tbool;      (* HSH.contains(store, level, v) *)
      "witness", [tnum; tnum; tnum], tnum;        (* HSH.witness(store, goal, _) -> bitmask *)
      "shared_levels", [tnum], tnum;              (* # levels with a shared Merkle root *)
      "levels", [tnum], tnum;                     (* # H_i levels *)
    ];
    "HashSet", [
      "empty", [], TyUser "Map";
      "add", [TyUser "Map"; tunk], TyUser "Map";
      "contains", [TyUser "Map"; tunk], tbool;
      "size", [TyUser "Map"], tnum;
      "union", [TyUser "Map"; TyUser "Map"], TyUser "Map";
      "intersect", [TyUser "Map"; TyUser "Map"], TyUser "Map";
      "to_stream", [TyUser "Map"], tlist tunk;
      (* orbital ops *)
      "orbital_add", [TyUser "Map"; tnum], TyUser "Map";
      "orbital_contains", [TyUser "Map"; tnum], tbool;
      (* pluggable *)
      "orbital_add_with", [TyUser "Map"; tnum; tnum], TyUser "Map";
      "orbital_contains_with", [TyUser "Map"; tnum; tnum], tbool;
      (* S_n canon native SAT, usa dimacs_n_vars. *)
      "add_canon_sn", [TyUser "Map"; tnum], TyUser "Map";
      (* Dual-structure wavefront support. *)
      "try_add", [TyUser "Map"; tnum], tnum;
      "try_add_canon_sn", [TyUser "Map"; tnum], tnum;
      (* zero-alloc iteration *)
      "at_bucket", [TyUser "Map"; tnum], tnum;
      "dir_capacity", [tnum], tnum;
    ];
    (* XSet, Set MPHF-backed Leech 24D.
     * Elements: xcoord type-2 (uint32 -> f64). 196560-bit bitmap.
     * Bit-parallel union/intersect operations, ~50x faster than HashSet for
     * medium-sized sets (10K+ elements). *)
    "XSet", [
      "empty", [], TyUser "Map";
      "add", [TyUser "Map"; tnum], TyUser "Map";
      "contains", [TyUser "Map"; tnum], tbool;
      "size", [TyUser "Map"], tnum;
      "union", [TyUser "Map"; TyUser "Map"], TyUser "Map";
      "intersect", [TyUser "Map"; TyUser "Map"], TyUser "Map";
      "to_stream", [TyUser "Map"], tlist tnum;
      (* orbital pluggable *)
      "orbital_add", [TyUser "Map"; tnum; tnum], TyUser "Map";
      "orbital_contains", [TyUser "Map"; tnum; tnum], tbool;
    ];
    (* Merkle DAG as a stdlib place.
     * Surface API: Merkle.{leaf, node2, label, child, equal, to_stream}.
     * Backing: ds_merkle_node_t in xheap content-addressed.
     * to_stream yields LEAVES via DFS left-first. *)
    "Merkle", [
      "leaf", [tnum], TyUser "Merkle";
      "node2", [tnum; TyUser "Merkle"; TyUser "Merkle"], TyUser "Merkle";
      "node2_commutative", [tnum; TyUser "Merkle"; TyUser "Merkle"], TyUser "Merkle";
      "node3", [tnum; TyUser "Merkle"; TyUser "Merkle"; TyUser "Merkle"],
              TyUser "Merkle";
      "node4", [tnum; TyUser "Merkle"; TyUser "Merkle"; TyUser "Merkle";
                TyUser "Merkle"], TyUser "Merkle";
      "label", [TyUser "Merkle"], tnum;
      "child", [TyUser "Merkle"; tnum], TyUser "Merkle";
      "equal", [TyUser "Merkle"; TyUser "Merkle"], tbool;
      "to_stream", [TyUser "Merkle"], tlist tnum;
      (* leaf orbital *)
      "leaf_orbital", [tnum; tnum], TyUser "Merkle";
    ];
    "Leech", [
      "sign_canonical", [tnum; tnum], tnum;
      "syndrome", [tnum], tnum;
      "orbit_id", [tnum], tnum;
      "same_orbit", [tnum; tnum], tbool;
      "m24_orbit", [tnum], tnum;
      "gcode_weight", [tnum], tnum;
      "cocode_weight", [tnum], tnum;
      "xi_apply", [tnum], tnum;
      (* Exact Co_0: a single canonicalizer, zero parameters.
       * co0_canonical(v) and co0_step(v) -> the exact reduce_type2 reduction.
       * The max_iter parameter (which was free) and co0_orbit_size were removed. *)
      "co0_canonical", [tnum], tnum;
      "co0_step", [tnum], tnum;
      "co0_equivalent", [tnum; tnum], tbool;
    ];
    (* VoyagerList as a collection. A Golay (24,12,8) codeword: auto-seal on
     * append, auto-open on get, with error correction up to 3 bits per
     * codeword. *)
    "VoyagerList", [
      "empty", [], TyUser "VoyagerList";
      "append", [TyUser "VoyagerList"; tnum], TyUser "VoyagerList";
      "get", [TyUser "VoyagerList"; tnum], tnum;
      "size", [TyUser "VoyagerList"], tnum;
      "corrupt_at", [TyUser "VoyagerList"; tnum; tnum], TyUser "VoyagerList";
      "to_stream", [TyUser "VoyagerList"], tlist tnum;
    ];
    "Space", [
      "make", [tunk], TyUser "Space";   (* alias for "new" to avoid keyword clash *)
      "new", [tunk], TyUser "Space";
      "get", [TyUser "Space"], tunk;
      "set", [TyUser "Space"; tunk], tunit;
      (* An orbital-indexed Space. Lets one keep "states equivalent by orbit"
       * in a single Space. *)
      "orbital_set", [TyUser "Space"; tnum; tnum; tnum], tunit;
      "orbital_get", [TyUser "Space"; tnum; tnum], tnum;
    ];
    (* The Lattice module was removed (dead code). No example uses it; the
     * example topos_heyt_int_lattice.yon uses the __heyt_int_make builtins
     * directly, not the Lattice surface API. *)
    "PerfectMap", [
      "build_from", [tlist tunk; tlist tunk], TyUser "PerfectMap";
      "get", [TyUser "PerfectMap"; tunk], tunk;
      "keys", [TyUser "PerfectMap"], tlist tunk;
      "size", [TyUser "PerfectMap"], tnum;
    ];
    (* Capability registry MVP. *)
    "Cap", [
      "grant", [tnum], tnum;
      "check", [tnum], tnum;
      "revoke", [tnum], tnum;
    ];
    (* Online schema evolution MVP. *)
    "MoveRegistry", [
      "register_version", [tnum; tnum], tnum;
      "current_version", [tnum], tnum;
    ];
    (* Stdlib base *)
    "Math", [
      "sqrt", [tnum], tnum;
      "abs", [tnum], tnum;
      "floor", [tnum], tnum;
      "ceil", [tnum], tnum;
      "round", [tnum], tnum;
      "min", [tnum; tnum], tnum;
      "max", [tnum; tnum], tnum;
      "pow", [tnum; tnum], tnum;
      "log", [tnum], tnum;
      "exp", [tnum], tnum;
      "sin", [tnum], tnum;
      "cos", [tnum], tnum;
      "pi", [tunit], tnum;
      "e", [tunit], tnum;
      (* per algebra commutativa (ℤ_n, +) e (N⁺, gcd) *)
      "modulo", [tnum; tnum], tnum;
      "gcd", [tnum; tnum], tnum;
      (* math esteso *)
      "lcm", [tnum; tnum], tnum;
      "log2", [tnum], tnum;
      "log10", [tnum], tnum;
      "atan2", [tnum; tnum], tnum;
      "sinh", [tnum], tnum;
      "cosh", [tnum], tnum;
      "tanh", [tnum], tnum;
    ];
    "Magma", [
      (* world Magma: (op_id, generators). Laws VERIFIED, not assumed. *)
      "empty", [tnum], TyUser "Magma";          (* op_id -> magma *)
      "gen", [TyUser "Magma"; tnum], TyUser "Magma";
      "is_commutative", [TyUser "Magma"], tbool;
      "is_associative", [TyUser "Magma"], tbool;
      "identity", [TyUser "Magma"], tnum;
      "closure_size", [TyUser "Magma"], tnum;
      "reachable", [TyUser "Magma"; tnum], tbool;
      "word_push", [TyUser "Magma"; tnum], TyUser "Magma";
      "normal_form", [TyUser "Magma"], tnum;
      "from_catalog", [tnum], TyUser "Magma";        (* catalog id -> place with certified laws *)
      "subsetsum", [TyUser "Magma"; tnum], tbool;      (* is there a subset summing to T? *)
      "subsetsum_mask", [TyUser "Magma"; tnum], tnum;  (* maschera certificato (quali generatori) *)
      "knap_item", [TyUser "Magma"; tnum; tnum], TyUser "Magma";  (* (weight, value) *)
      "knapsack", [TyUser "Magma"; tnum], tnum;          (* max value within capacity *)
      "knapsack_mask", [TyUser "Magma"; tnum], tnum;     (* maschera item selezionati *)
    ];
    "Bits", [
      "band", [tnum; tnum], tnum;
      "bor",  [tnum; tnum], tnum;
      "bxor", [tnum; tnum], tnum;
      "bnot", [tnum], tnum;
      "shl",  [tnum; tnum], tnum;
      "shr",  [tnum; tnum], tnum;
      "popcount", [tnum], tnum;
      (* Bits.fold over set bits. *)
      "fold", [tnum; tnum; tnum], tnum;
      (* 64-bit variants for SAT 2n>32. *)
      "bor_64", [tnum; tnum], tnum;
      "band_64", [tnum; tnum], tnum;
      "bxor_64", [tnum; tnum], tnum;
    ];
    "IO", [
      "print_num", [tnum], tnum;
    ];
    (* stdlib estesa. *)
    "String", [
      "from_int", [tnum], TyUser "String";
      "length",   [TyUser "String"], tnum;
      "concat",   [TyUser "String"; TyUser "String"], TyUser "String";
      "equal",    [TyUser "String"; TyUser "String"], tbool;
      "char_at",  [TyUser "String"; tnum], tnum;
      "print",    [TyUser "String"], tnum;
      (* for DIMACS parser *)
      "parse_number", [TyUser "String"], tnum;
      "substring", [TyUser "String"; tnum; tnum], TyUser "String";
      "find_char", [TyUser "String"; tnum; tnum], tnum;
      "from_char", [tnum], TyUser "String";
    ];
    "File", [
      "read_text", [TyUser "String"], TyUser "String";
      "exists",    [TyUser "String"], tbool;
      (* v1.0 perimeter (2026-06-03): write side *)
      "write_text",  [TyUser "String"; TyUser "String"], tnum;
      "append_text", [TyUser "String"; TyUser "String"], tnum;
    ];
    "Env", [
      "get", [TyUser "String"], TyUser "String";
      "has", [TyUser "String"], tbool;
    ];
    "Args", [
      "count", [tunit], tnum;
      "get",   [tnum], TyUser "String";
    ];
    "DIMACS", [
      (* SATLIB DIMACS primitives. *)
      "uf20_load", [tnum], tnum;
      "uf50_load", [tnum], tnum;
      "n_vars", [tunit], tnum;
      "G", [tunit], tnum;
      "clause", [tnum], tnum;
    ];
    "Time", [
      "now_ms", [tunit], tnum;
      "now_ns", [tunit], tnum;
    ];
    "Random", [
      "seed",  [tnum], tnum;
      "int",   [tunit], tnum;
      "range", [tnum; tnum], tnum;
    ];
    "Crypto", [
      "fnv1a",    [TyUser "String"], tnum;
      "hash_int", [tnum], tnum;
    ];
    (* SAT 3-clause prover.
     * Empirical OR/SAT at the phase transition alpha=4.27.
     * metric_id: 1=|R|, 2=k_active, 3=max_o*1000, 4=avg_o*1000,
     *            5=sum_o*1000, 6=G, 7=R/G^5*10^6 *)
    "SAT", [
      "run_3sat", [tnum; tnum; tnum], tnum;
      (* NOT-literals + filtered satisfiable.
       * filter=1: DPLL retries up to 100 times to guarantee SAT.
       * metric_id: 1=|R|, 2=k, 3=max_o*1000, 4=sum_o*1000, 5=G, 6=sat *)
      "run_3sat_filtered", [tnum; tnum; tnum; tnum], tnum;
      (* Real DIMACS UF20/UF50 via sparse wavefront state-space (HashSet, not
       * bitmap). Limit n_vars >> 24.
       * filepath: TyUser "String" (slot xheap).
       * metric_id: 1=|R|, 2=k, 3=max_o*1000, 4=sum_o*1000, 5=G, 6=n_vars *)
      "run_dimacs", [TyUser "String"; tnum], tnum;
      (* SATLIB UF20/UF50 helper: idx 1..1000.
       * metric_id: 1=|R|, 2=k, 3=max_o*1000, 4=sum_o*1000, 5=G, 6=n_vars *)
      "uf20", [tnum; tnum], tnum;
      "uf50", [tnum; tnum], tnum;
      (* Access the o_i trace of the most recent DIMACS wavefront.
       * round is 1-indexed. Returns o_i * 1000. *)
      "o_at", [tnum], tnum;
      (* random 3-SAT with arbitrary alpha
       * to investigate the c(alpha) dependence in the quasi-poly scaling.
       * Args: n_vars, alpha (G/n), seed, metric_id (same as uf20). *)
      "alpha_3sat", [tnum; tnum; tnum; tnum], tnum;
      (* Orbital wavefront over SATLIB UF20. Canonicalizes each state under S_n
       * (variable permutations) before dedup. |R_orb| <= |R_naive|, often <<
       * for symmetric problems. *)
      "uf20_orbital", [tnum; tnum], tnum;
      "uf50_orbital", [tnum; tnum], tnum;
      (* Leech wavefront via embedding 2n->24 + G_24 syndrome. *)
      "uf20_leech", [tnum; tnum], tnum;
      "uf50_leech", [tnum; tnum], tnum;
      "leech_o_at", [tnum], tnum;
      (* Co_0 wavefront via Conway group BFS. *)
      "uf20_co0", [tnum; tnum], tnum;
      "orbital_o_at", [tnum], tnum;
    ];
    (* Cross-Space streams.
     * Stream.make(target_heap) -> stream_id as number
     * Stream.send(stream_id, value) -> 0 on success
     * Stream.recv(stream_id) -> value (or -1 if empty)
     * Note: we use send/recv to avoid a clash with the EMIT token (reserved
     * for `emit expr` statement effects). *)
    "Stream", [
      "make", [tnum], tnum;
      "send", [tnum; tnum], tnum;
      "recv", [tnum], tnum;
      (* Cross-PROCESS streams over POSIX shared memory (mattone A). Same f64-id
         convention; make_shm(id, create) rendezvous two isolated Space
         processes on a shared region. send_shm/recv_shm cross the boundary. *)
      "make_shm", [tnum; tnum], tnum;
      "send_shm", [tnum; tnum], tnum;
      "recv_shm", [tnum], tnum;
      (* Blocking variants with back-pressure (3): produce waits for room,
         await waits for a value. *)
      "produce_shm", [tnum; tnum], tnum;
      "await_shm", [tnum], tnum;
      "close_shm", [tnum], tnum;
      (* Cross-MACHINE streams over TCP (Strato 4). make_net(id, port, is_server)
         opens the conduit; send_net/recv_net cross the machine boundary with the
         same API as the SHM variants. *)
      "make_net", [tnum; tnum; tnum], tnum;
      "send_net", [tnum; tnum], tnum;
      "recv_net", [tnum], tnum;
      "close_net", [tnum], tnum;
      (* True infinite streams. iterate(f, x0) returns a lazy stream applying f
       * to x0 repeatedly. take(s, n) materializes the first n into a list.
       * sum_take(s, n) = fold(+, 0, take(s, n)) fused.
       *
       * Implemented as compile-time patterns in emit_mlir, no extra runtime.
       * tunk because the types are computed at the call site. *)
      "iterate",  [tunk; tnum], tnum;
      "take",     [tnum; tnum], tlist tnum;
      "sum_take", [tnum; tnum], tnum;
    ];
    (* Seq.* per pipeline deforestata.
     * Internally: Seq is a "lazy iterator" over a list. The map/filter/fold
     * ops are recognized as a complete pattern by emit_mlir and lowered to a
     * single scf.while with no intermediate buffers. f/p/g are top-level
     * function names (tunk = placeholder), NOT first-class functions. *)
    "Seq", [
      "from_list", [tlist tunk], tnum;
      "map",       [tnum; tunk], tnum;
      "filter",    [tnum; tunk], tnum;
      "fold",      [tnum; tnum; tunk], tnum;
      (* generate [0, 1, ..., n-1] as stream. *)
      "range",     [tnum], tnum;
      "range_to_list", [tnum], tlist tnum;
    ];
  ]

(* Lookup a stdlib operation by its qualified name (e.g., "List__cons"). 
 * Returns (param_types, return_type) if found. *)
let lookup_stdlib_signature (qname : string) : (Surface_ast.ty list * Surface_ast.ty) option =
  (* The __stream_* names are fusion stubs handled by emit_mlir as patterns.
     We skip the stdlib lookup and return a stub signature
     (unknown -> ... -> unknown) just for type checking. *)
  let tunk = Surface_ast.TyPrim "unknown" in
  let tnum = Surface_ast.TyPrim "number" in
  (* Idraulica v2: __yon_rpc2_invoke<K>__<Space>(op_selector, arg1..argK).
   * The Space travels nominally in the name; all wire values are numbers. *)
  let rpc2_prefix = "__yon_rpc2_invoke" in
  let rpc2_plen = String.length rpc2_prefix in
  if String.length qname > rpc2_plen + 3
     && String.sub qname 0 rpc2_plen = rpc2_prefix
     && qname.[rpc2_plen] >= '0' && qname.[rpc2_plen] <= '4'
     && String.sub qname (rpc2_plen + 1) 2 = "__" then
    let k = Char.code qname.[rpc2_plen] - Char.code '0' in
    Some (List.init (1 + k) (fun _ -> tnum), tnum)
  else
  if String.length qname > 9 && String.sub qname 0 9 = "__stream_" then begin
    match String.sub qname 9 (String.length qname - 9) with
    | "from_list" -> Some ([Surface_ast.TyList tunk], tunk)
    | "map" -> Some ([tunk; tunk], tunk)
    | "filter" -> Some ([tunk; tunk], tunk)
    | "fold" -> Some ([tunk; tunk; tunk], tunk)
    (* *)
    | "iterate" -> Some ([tunk; tunk], tunk)
    | "take" -> Some ([tunk; tunk], tunk)
    | "sum_take" -> Some ([tunk; tunk], tunk)
    | "to_stream" -> Some ([tunk], tunk)
    | _ -> None
  end else
  match String.index_opt qname '_' with
  | None -> None
  | Some _ ->
      (* qname is "Place__op". Split on "__". *)
      let parts =
        try
          let i = Str.search_forward (Str.regexp "__") qname 0 in
          Some (String.sub qname 0 i,
                String.sub qname (i+2) (String.length qname - i - 2))
        with Not_found -> None
      in
      match parts with
      | None -> None
      | Some (place, op_name) ->
          (match List.assoc_opt place stdlib_signatures with
           | None -> None
           | Some ops ->
               (match List.find_opt (fun (n, _, _) -> n = op_name) ops with
                | Some (_, ptys, rty) -> Some (ptys, rty)
                | None -> None))
