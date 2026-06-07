(* move_engine.ml — execution engine for `move` declarations.
 *
 * A move declaration specifies how to transport values between worlds:
 *
 *   Form A (mapping):
 *     move M from W1 to W2 {
 *       field_a maps to field_b by fn1
 *       field_c converts to field_d by fn2
 *       field_e aggregates to field_f by fn3
 *     }
 *
 *   Form B (merge):
 *     move M unifies W1, W2 {
 *       share field_x
 *       conflict_on field_y resolves to fn4
 *     }
 *
 * At runtime, a move can be applied to instances of places in the
 * source world(s) to produce instances in the target world.
 *
 * This module:
 *   - Stores move declarations indexed by name
 *   - Stores mapping functions (registered as user-defined funs)
 *   - Applies a move to a record instance to produce a transformed
 *     record
 *)

open Surface_ast

(* ─── Record runtime representation ────────────────────────────────── *)

(* A record is stored as a Hashtbl of field_name -> encoded_term,
 * indexed by an integer id. The id is wrapped in a Var to make
 * records first-class Yon Core terms. *)

type record = {
  rec_place : string;                     (* the place this record instances *)
  rec_fields : (string, Ast.term) Hashtbl.t;
}

let record_store : (int, record) Hashtbl.t = Hashtbl.create 64
let next_record_id : int ref = ref 0

let fresh_record_id () : int =
  let n = !next_record_id in
  incr next_record_id;
  n

let encode_record (id : int) : Ast.term =
  Ast.Var (Printf.sprintf "__rec_%d" id)

let decode_record_id (t : Ast.term) : int option =
  match t with
  | Ast.Var name when String.length name > 6 && String.sub name 0 6 = "__rec_" ->
      (try Some (int_of_string (String.sub name 6 (String.length name - 6)))
       with _ -> None)
  | _ -> None

let new_record (place : string) (fields : (string * Ast.term) list) : Ast.term =
  let id = fresh_record_id () in
  let tbl = Hashtbl.create (List.length fields * 2) in
  List.iter (fun (k, v) -> Hashtbl.add tbl k v) fields;
  Hashtbl.add record_store id { rec_place = place; rec_fields = tbl };
  encode_record id

let get_record (t : Ast.term) : record option =
  match decode_record_id t with
  | None -> None
  | Some id -> Hashtbl.find_opt record_store id

let get_field (t : Ast.term) (fld : string) : Ast.term option =
  match get_record t with
  | None -> None
  | Some r -> Hashtbl.find_opt r.rec_fields fld

(* ─── Move registry ────────────────────────────────────────────────── *)

(* Move declarations indexed by name. *)
let move_store : (string, move_decl) Hashtbl.t = Hashtbl.create 16

let register_move (md : move_decl) : unit =
  Hashtbl.replace move_store md.mv_name md

let lookup_move (name : string) : move_decl option =
  Hashtbl.find_opt move_store name

(* ─── User function registry ───────────────────────────────────────── *)

(* The mapping functions referenced by `by fn1`, `by fn2`, etc.
 * are user-defined funs. We need a way to invoke them by name when
 * applying a move. We store them as Ast.term (typically a lambda)
 * keyed by name. *)

let user_fun_store : (string, Ast.term) Hashtbl.t = Hashtbl.create 32

let register_user_fun (name : string) (body : Ast.term) : unit =
  Hashtbl.replace user_fun_store name body

let lookup_user_fun (name : string) : Ast.term option =
  Hashtbl.find_opt user_fun_store name

(* ─── Move application: Form A (mapping) ───────────────────────────── *)

(* Apply a mapping move M from W1 to W2 to a record r of a place in W1.
 *
 * For each mapping in the move body:
 *   - field_a maps to field_b by fn1: target.field_b = fn1(source.field_a)
 *   - field_a converts to field_b by fn2: same as maps (semantic distinction
 *                                          is left to the user's intent)
 *   - field_a aggregates to field_b by fn3: target.field_b = fn3(source.field_a)
 *                                          (also same operationally)
 *
 * The result is a fresh record in the target world. *)

let apply_mapping_move
    (md : move_decl)
    (source : Ast.term)
    (target_place : string)
    (apply_fn : Ast.term -> Ast.term -> Ast.term) : Ast.term option =
  match md.mv_body with
  | MoveMerge _ -> None  (* wrong form *)
  | MoveMapping mappings ->
      match get_record source with
      | None -> None
      | Some _src_rec ->
          let target_fields = List.filter_map
            (fun m ->
               match get_field source m.m_from with
               | None -> None
               | Some src_value ->
                   match lookup_user_fun m.m_by with
                   | None ->
                       (* No fn registered: pass through unchanged *)
                       Some (m.m_to, src_value)
                   | Some fn ->
                       let result = apply_fn fn src_value in
                       Some (m.m_to, result))
            mappings
          in
          Some (new_record target_place target_fields)

(* ─── Move application: Form B (merge) ─────────────────────────────── *)

(* Apply a merge move M unifies W1, W2 to two records.
 * - share field_x: the field appears in both with the same value;
 *   we copy from the first.
 * - conflict_on field_y resolves to fn4: when both have field_y with
 *   different values, call fn4 to resolve. *)

let apply_merge_move
    (md : move_decl)
    (source1 : Ast.term)
    (source2 : Ast.term)
    (target_place : string)
    (apply_fn2 : Ast.term -> Ast.term -> Ast.term -> Ast.term) : Ast.term option =
  match md.mv_body with
  | MoveMapping _ -> None
  | MoveMerge mg ->
      match get_record source1, get_record source2 with
      | Some r1, Some r2 ->
          let merged_fields = Hashtbl.create 16 in
          (* Shared fields: take from r1 (assumed equal between r1 and r2). *)
          List.iter
            (fun shared ->
               match Hashtbl.find_opt r1.rec_fields shared with
               | Some v -> Hashtbl.replace merged_fields shared v
               | None ->
                   match Hashtbl.find_opt r2.rec_fields shared with
                   | Some v -> Hashtbl.replace merged_fields shared v
                   | None -> ())
            mg.merge_shares;
          (* All fields from r1 not yet processed: copy. *)
          Hashtbl.iter
            (fun k v ->
               if not (Hashtbl.mem merged_fields k) then
                 Hashtbl.replace merged_fields k v)
            r1.rec_fields;
          (* All fields from r2: if collision, apply resolver. *)
          Hashtbl.iter
            (fun k v ->
               match Hashtbl.find_opt merged_fields k with
               | None -> Hashtbl.replace merged_fields k v
               | Some v1 ->
                   if v <> v1 then
                     match List.assoc_opt k mg.merge_conflicts with
                     | Some resolver_name ->
                         (match lookup_user_fun resolver_name with
                          | Some fn ->
                              let resolved = apply_fn2 fn v1 v in
                              Hashtbl.replace merged_fields k resolved
                          | None ->
                              (* No resolver registered: keep r1's value *)
                              ())
                     | None -> ()
                     (* No conflict_on declared: keep r1's value *))
            r2.rec_fields;
          let id = fresh_record_id () in
          Hashtbl.add record_store id {
            rec_place = target_place;
            rec_fields = merged_fields;
          };
          Some (encode_record id)
      | _ -> None

(* ─── Runtime hooks ────────────────────────────────────────────────── *)

(* Engine integrates with builtins by recognizing two calls:
 *
 *   Move__apply(move_name, source)  ->  the result of Form A
 *   Move__merge(move_name, s1, s2)  ->  the result of Form B
 *   Record__field(record, fld)       ->  field access
 *   Record__set(record, fld, val)    ->  field update (persistent)
 *   Record__new(place_name, fields)  ->  construct a new record
 *
 * The apply_fn parameters are wired up to a kernel reducer.
 *)

(* The kernel reducer is passed in by the main entry point. Because
 * Move_engine doesn't depend on Builtins directly (to avoid cycles),
 * we store the kernel reducer as a mutable function reference set at
 * startup. *)

let kernel_reducer : (Ast.term -> Ast.term -> Ast.term) ref =
  ref (fun _f _a -> Ast.Unit)

let set_kernel_reducer
    (f : Ast.term -> Ast.term -> Ast.term) : unit =
  kernel_reducer := f

let kernel_apply_2
    (fn : Ast.term) (a : Ast.term) (b : Ast.term) : Ast.term =
  (* Apply a binary function: fn a b *)
  let partial = !kernel_reducer fn a in
  !kernel_reducer partial b

