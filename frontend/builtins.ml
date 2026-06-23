(* builtins.ml — built-in primitives for executable Yon programs.
 *
 * This module provides:
 *   - Concrete numeric, boolean, and string values as Core terms.
 *   - Built-in operations (__add, __sub, __mul, __lt, __eq, __if) that
 *     reduce as expected when applied to concrete values.
 *   - An "Output" place + "Console" reduction that captures emitted
 *     strings into an observable buffer.
 *
 * The encoding strategy: concrete values are encoded as Core terms
 * with a recognizable variable name pattern:
 *
 *   number 42       ->  Var "__num_42"
 *   string "hello"  ->  Var "__str_hello"
 *   bool true       ->  Var "__bool_true"
 *
 * Operations are evaluated by inspecting these patterns when they
 * appear as arguments. This is a "shallow" semantics — sufficient for
 * the first prototype, replaceable with a proper value layer later.
 *)

open Ast

(* ─── Concrete value encoding ──────────────────────────────────────── *)

(* Shortest decimal string that round-trips to the SAME IEEE double. encode and
 * decode must be mutual inverses on every finite double — a faithful key, not a
 * lossy display. The old code used %g (6 significant digits, so 1.0/.3.0 became
 * 0.333333) and int_of_float (which overflows past 2^62 for large integer-valued
 * floats); both broke encode∘decode = id. We pick the least precision in
 * {15,16,17} that round-trips: 15 keeps common decimals pretty (0.1 -> "0.1",
 * 5.0 -> "5"), higher precision kicks in only when needed (1/3). No int cast, so
 * no overflow. Caller (with_numbers) guards finiteness, so n is always finite. *)
let float_to_yon_string (n : float) : string =
  let try_prec p =
    let s = Printf.sprintf "%.*g" p n in
    if float_of_string s = n then Some s else None
  in
  match try_prec 15 with
  | Some s -> s
  | None -> (match try_prec 16 with
             | Some s -> s
             | None -> Printf.sprintf "%.17g" n)

let encode_number (n : float) : term =
  Var ("__num_" ^ float_to_yon_string n)

let encode_string (s : string) : term =
  Var (Printf.sprintf "__str_%s" s)

let encode_bool (b : bool) : term =
  Var (if b then "__bool_true" else "__bool_false")

(* Decode a value back to its concrete form, if possible. *)

let decode_number (t : term) : float option =
  match t with
  | Var name when String.length name > 6 && String.sub name 0 6 = "__num_" ->
      (try Some (float_of_string (String.sub name 6 (String.length name - 6)))
       with _ -> None)
  | _ -> None

let decode_bool (t : term) : bool option =
  match t with
  | Var "__bool_true" -> Some true
  | Var "__bool_false" -> Some false
  | _ -> None

let decode_string (t : term) : string option =
  match t with
  | Var name when String.length name >= 6 && String.sub name 0 6 = "__str_" ->
      Some (String.sub name 6 (String.length name - 6))   (* >= 6: la stringa vuota e' "__str_" *)
  | _ -> None

(* ─── Observable output buffer ─────────────────────────────────────── *)

(* Module-level mutable buffer where Console.print writes its output.
 * Tests can read this buffer to verify what a program produced. *)

let output_buffer : Buffer.t = Buffer.create 256

let reset_output () = Buffer.clear output_buffer

let get_output () : string = Buffer.contents output_buffer

let append_output (s : string) =
  Buffer.add_string output_buffer s;
  Buffer.add_char output_buffer '\n'

(* ─── Built-in arithmetic and comparison reductions ────────────────── *)

(* We model each built-in as a "synthetic" place with an operation,
 * and a reduction that handles it concretely. The desugarer emits
 * calls like __add(x, y), which the evaluator dispatches.
 *
 * Strategy: when the reducer sees App(App(Var "__add", a), b) where
 * both a and b are decodable numbers, it produces the encoded result.
 * This requires hooking into the reduction step.
 *
 * For the prototype, we expose a helper function evaluate_builtin
 * that the main evaluator can call after a fixed point on R_Yon.
 *)

let rec try_eval_binop (op : string) (a : term) (b : term) : term option =
  let with_numbers f =
    match decode_number a, decode_number b with
    | Some x, Some y ->
        let r = f x y in
        (* Stay stuck on a non-finite result (overflow to Inf, 0/0-style NaN)
         * rather than encoding a poison value that would silently corrupt every
         * downstream comparison and emit an invalid MLIR literal. *)
        if Float.is_finite r then Some (encode_number r) else None
    | _ -> None
  in
  let with_number_to_bool f =
    match decode_number a, decode_number b with
    | Some x, Some y -> Some (encode_bool (f x y))
    | _ -> None
  in
  let with_bools f =
    match decode_bool a, decode_bool b with
    | Some x, Some y -> Some (encode_bool (f x y))
    | _ -> None
  in
  match op with
  | "__add" -> with_numbers ( +. )
  | "__sub" -> with_numbers ( -. )
  | "__mul" -> with_numbers ( *. )
  | "__div" ->
      (match decode_number a, decode_number b with
       | Some _, Some 0.0 -> None  (* division by zero — stuck *)
       | Some x, Some y -> Some (encode_number (x /. y))
       | _ -> None)
  | "__mod" ->
      (match decode_number a, decode_number b with
       | Some _, Some 0.0 -> None  (* modulo by zero — stuck, like __div (no NaN leak) *)
       | Some x, Some y -> Some (encode_number (Float.rem x y))
       | _ -> None)
  | "__lt"  -> with_number_to_bool ( < )
  | "__gt"  -> with_number_to_bool ( > )
  | "__leq" -> with_number_to_bool ( <= )
  | "__geq" -> with_number_to_bool ( >= )
  | "__eq"  ->
      (* equality on multiple types *)
      (match decode_number a, decode_number b with
       | Some x, Some y -> Some (encode_bool (x = y))
       | _ ->
         match decode_bool a, decode_bool b with
         | Some x, Some y -> Some (encode_bool (x = y))
         | _ ->
           match decode_string a, decode_string b with
           | Some x, Some y -> Some (encode_bool (x = y))
           | _ -> None)
  | "__neq" ->
      (match try_eval_binop "__eq" a b with
       | Some (Var "__bool_true") -> Some (encode_bool false)
       | Some (Var "__bool_false") -> Some (encode_bool true)
       | _ -> None)
  | "__and" -> with_bools ( && )
  | "__or"  -> with_bools ( || )
  | _ -> None

(* Try to evaluate a built-in if-then-else.
 *
 * Heyting-aware: when the condition is a Heyting tri-value, we use
 * the "strict-then" semantics:
 *
 *   - HPresent -> take the then-branch
 *   - HAbsent  -> take the else-branch
 *   - HUnknown -> take the else-branch (conservative: don't run code
 *                whose precondition is not definitely satisfied)
 *
 * This preserves the intuitionistic reading: a then-branch fires only
 * when the condition is *provably* present. Lacking evidence (unknown)
 * is treated the same as lacking truth (absent) for branch selection.
 *
 * Programs that need to explicitly handle the unknown case use the
 * pattern `when x is unknown { ... }` which compiles to a separate
 * test branch upstream of __if.
 *)
let try_eval_if (cond : term) (then_branch : term) (else_branch : term) : term option =
  (* Try Heyting first. *)
  match Heyting.decode_heyt cond with
  | Some Heyting.HPresent -> Some then_branch
  | Some Heyting.HAbsent | Some Heyting.HUnknown -> Some else_branch
  | None ->
      (* Fall back to Boolean. *)
      match decode_bool cond with
      | Some true -> Some then_branch
      | Some false -> Some else_branch
      | None -> None

(* ─── The Console reduction (built-in) ────────────────────────────── *)

(* The print operation: when invoked with a string argument, append
 * it to the output buffer. The handler body returns Unit. *)

(* The print handler body invokes a builtin __effect_print which has
 * the actual side effect (writing to the output buffer). The parameter
 * `s` of the handler is substituted into this body when the handler
 * fires. This way, the side effect runs naturally as part of normal
 * reduction without bypassing the effect handler dispatch. *)
let print_handler_body : term = App (Var "__effect_print", Var "s")

let console_reduction : reduction_decl = {
  r_name = "__Console";
  r_target = "Output";
  r_multi_shot = false;
  r_fold_name = None;
  r_handlers = [
    { hc_op = "print";
      hc_params = [("s", TyPlace "text")];
      hc_body = print_handler_body; }
  ];
}

let output_place : place_decl = {
  p_name = "Output";
  p_site = TyPlace "world";
  p_fields = [];
  p_operations = [
    { op_name = "print";
      op_params = [("s", TyPlace "text")];
      op_return = TyPlace "unit"; op_algebra = None; }
  ];
  p_laws = [];
}

(* ─── Context augmented with built-ins ─────────────────────────────── *)

(* Table mapping place names to their field name list, in declared order.
 * Populated by with_builtins so that __field_X projections can resolve
 * the right index of a __new_P record. *)
let place_fields_table : (string, string list) Hashtbl.t = Hashtbl.create 16

(* Reset for tests. *)
let register_place_fields (name : string) (fields : string list) : unit =
  Hashtbl.replace place_fields_table name fields

let lookup_place_fields (name : string) : string list option =
  Hashtbl.find_opt place_fields_table name

let with_builtins (ctx : Reduce.ctx) : Reduce.ctx =
  let ctx = Reduce.declare_place ctx output_place in
  let ctx = Reduce.declare_reduction ctx console_reduction in
  (* Populate place_fields_table from the ctx's declared places. *)
  List.iter (fun (name, pd) ->
    let fnames = List.map fst pd.p_fields in
    register_place_fields name fnames)
    ctx.places;
  ctx

(* ─── Hook into the evaluator ──────────────────────────────────────── *)

(* The evaluator calls this after each reduction step. If the term
 * matches a built-in pattern, we reduce it concretely.
 *
 * Patterns recognized:
 *   App(App(Var "__op", a), b)      — binary operation
 *   App(App(App(Var "__if", c), t), e)  — if-then-else
 *   App(App(Var "Output__print", s), _) — print to buffer
 *)

let rec try_reduce_builtin (t : term) : term option =
  match t with
  | App (App (Var op, a), b)
      when String.length op > 2 && String.sub op 0 2 = "__"
        && not (String.length op > 7 && String.sub op 0 7 = "__heyt_")
        && not (String.length op > 6 && String.sub op 0 6 = "__new_")
        && not (String.length op > 16
                && String.sub op 0 16 = "__apply_move_in_") ->
      (* Also exclude __apply_move_in_<S> from the generic binary-op pattern,
       * otherwise it would be caught before the specific apply_move pattern
       * below. *)
      (* Try recursing on a and b first to ensure they are evaluated. *)
      let a' = match try_reduce_builtin a with Some v -> v | None -> a in
      let b' = match try_reduce_builtin b with Some v -> v | None -> b in
      (* Special-case __is for Heyting pattern matching. `is not` never
         reaches here: it desugars to __heyt_not(__is ...) (desugar.ml). *)
      (match op, a', b' with
       | "__is", value, Var "__pat_present" ->
           Some (Heyting.encode_heyt
             (match Heyting.decode_heyt value with
              | Some Heyting.HPresent -> Heyting.HPresent
              | Some Heyting.HAbsent  -> Heyting.HAbsent
              | Some Heyting.HUnknown -> Heyting.HAbsent
                  (* is-present at unknown: not provably present *)
              | None ->
                  (* Non-Heyting value: it's "present" if we have it. *)
                  Heyting.HPresent))
       | "__is", value, Var "__pat_absent" ->
           Some (Heyting.encode_heyt
             (match Heyting.decode_heyt value with
              | Some Heyting.HAbsent -> Heyting.HPresent
              | Some Heyting.HPresent -> Heyting.HAbsent
              | Some Heyting.HUnknown -> Heyting.HUnknown
              | None -> Heyting.HAbsent))
       | "__is", value, Var "__pat_unknown" ->
           Some (Heyting.encode_heyt
             (match Heyting.decode_heyt value with
              | Some Heyting.HUnknown -> Heyting.HPresent
              | _ -> Heyting.HAbsent))
       (* AND/OR over Heyting: bridge __and/__or to Heyting operators
        * when arguments decode to Heyting values. *)
       | "__and", _, _ ->
           (match Heyting.decode_heyt a', Heyting.decode_heyt b' with
            | Some va, Some vb -> Some (Heyting.encode_heyt (Heyting.h_and va vb))
            | _ ->
                (* Fall back to Boolean and. *)
                match decode_bool a', decode_bool b' with
                | Some x, Some y -> Some (encode_bool (x && y))
                | _ -> try_eval_binop op a' b')
       | "__or", _, _ ->
           (match Heyting.decode_heyt a', Heyting.decode_heyt b' with
            | Some va, Some vb -> Some (Heyting.encode_heyt (Heyting.h_or va vb))
            | _ ->
                match decode_bool a', decode_bool b' with
                | Some x, Some y -> Some (encode_bool (x || y))
                | _ -> try_eval_binop op a' b')
       | _ ->
           try_eval_binop op a' b')
  | App (App (App (Var "__if", cond), tbr), ebr) ->
      let cond' = match try_reduce_builtin cond with Some v -> v | None -> cond in
      try_eval_if cond' tbr ebr
  | App (App (Var "Output__print", s), _unit) ->
      let s' = match try_reduce_builtin s with Some v -> v | None -> s in
      (match decode_string s' with
       | Some str ->
           append_output str;
           Some Unit
       | None -> None)
  | App (Var name, arg) when String.length name > 8
                            && String.sub name 0 8 = "__field_" ->
      (* Field projection: __field_<fname> applied to a __new_<Place> record.
       * The record is encoded as curried application:
       *   App(App(...App(Var "__new_P", v1), v2)..., vn)
       * We uncurry, look up the place's field list, and select by index. *)
      let arg' = match try_reduce_builtin arg with Some v -> v | None -> arg in
      let field_name = String.sub name 8 (String.length name - 8) in
      let rec uncurry t acc =
        match t with
        | App (f, a) -> uncurry f (a :: acc)
        | Var v -> Some (v, acc)
        | _ -> None
      in
      (match uncurry arg' [] with
       | Some (head, args) when String.length head > 6
                              && String.sub head 0 6 = "__new_" ->
           (* __new_in_<Space>_<Place> is equivalent to __new_<Place> for the
            * interpreter semantics (the space is runtime metadata, it does not
            * change the fields). *)
           let raw_place = String.sub head 6 (String.length head - 6) in
           let place_name =
             if String.length raw_place > 3
                && String.sub raw_place 0 3 = "in_" then
               (* Strip "in_<Space>_": find the first "_" after "in_" and take
                * the rest. If the split fails, fall back. *)
               let after_in = String.sub raw_place 3 (String.length raw_place - 3) in
               (try
                  let underscore = String.index after_in '_' in
                  String.sub after_in (underscore + 1)
                    (String.length after_in - underscore - 1)
                with Not_found -> raw_place)
             else raw_place
           in
           (match lookup_place_fields place_name with
            | Some fnames ->
                let rec find_idx i = function
                  | [] -> None
                  | f :: _ when f = field_name -> Some i
                  | _ :: rest -> find_idx (i+1) rest
                in
                (match find_idx 0 fnames with
                 | Some i when i < List.length args -> Some (List.nth args i)
                 | _ -> None)
            | None -> None)
       | _ -> None)
  | App (Var "__not", arg) ->
      let arg' = match try_reduce_builtin arg with Some v -> v | None -> arg in
      (match Heyting.decode_heyt arg' with
       | Some h -> Some (Heyting.encode_heyt (Heyting.h_not h))
       | None ->
           match decode_bool arg' with
           | Some b -> Some (encode_bool (not b))
           | None -> None)
  | App (Var "to_prop", arg) ->
      (* boolean -> proposition coercion.
       * Canonical injection: true ↦ present, false ↦ absent.
       * If arg is already a heyt value, identity. *)
      let arg' = match try_reduce_builtin arg with Some v -> v | None -> arg in
      (match Heyting.decode_heyt arg' with
       | Some _ -> Some arg'  (* already a proposition *)
       | None ->
           match decode_bool arg' with
           | Some true -> Some (Heyting.encode_heyt Heyting.HPresent)
           | Some false -> Some (Heyting.encode_heyt Heyting.HAbsent)
           | None -> None)
  | App (Var "to_bool", arg) ->
      (* proposition -> boolean coercion.
       * Partial: present ↦ true, absent ↦ false, unknown is a
       * runtime indeterminate — we map to false (conservative,
       * makes downstream conditionals act as if the property is
       * not established). A future refinement could fail explicitly
       * or return a triple-valued boolean. *)
      let arg' = match try_reduce_builtin arg with Some v -> v | None -> arg in
      (match decode_bool arg' with
       | Some _ -> Some arg'  (* already a boolean *)
       | None ->
           match Heyting.decode_heyt arg' with
           | Some Heyting.HPresent -> Some (encode_bool true)
           | Some Heyting.HAbsent -> Some (encode_bool false)
           | Some Heyting.HUnknown -> Some (encode_bool false)
           | None -> None)
  | App (Var "decide", arg) ->
      (* proposition -> Decidable. An assertion of decidability: the value must
       * be decided (present/absent). On HUnknown it fails explicitly: this is
       * where the programmer declares "this proposition is decidable", made
       * visible instead of silently coerced. The Decidable is represented by
       * the Heyting value itself (already decided). *)
      let arg' = match try_reduce_builtin arg with Some v -> v | None -> arg in
      (match decode_bool arg' with
       | Some _ -> Some arg'   (* already decided (boolean) *)
       | None ->
           match Heyting.decode_heyt arg' with
           | Some Heyting.HPresent -> Some (Heyting.encode_heyt Heyting.HPresent)
           | Some Heyting.HAbsent  -> Some (Heyting.encode_heyt Heyting.HAbsent)
           | Some Heyting.HUnknown ->
               failwith "decide: proposition is HUnknown — not decidable; \
                         cannot collapse to boolean (intuitionistic guard)"
           | None -> None)
  | App (Var "to_bool_dec", arg) ->
      (* Decidable -> boolean. Total: a Decidable is already decided (decide has
       * already excluded HUnknown). No silent loss. *)
      let arg' = match try_reduce_builtin arg with Some v -> v | None -> arg in
      (match decode_bool arg' with
       | Some _ -> Some arg'
       | None ->
           match Heyting.decode_heyt arg' with
           | Some Heyting.HPresent -> Some (encode_bool true)
           | Some Heyting.HAbsent  -> Some (encode_bool false)
           | Some Heyting.HUnknown ->
               failwith "to_bool_dec: received HUnknown — Decidable invariant \
                         violated (decide should have caught this)"
           | None -> None)
  | App (App (Var fname, Var move_name), source)
    when fname = "apply_move"
      || (String.length fname > 16
          && String.sub fname 0 16 = "__apply_move_in_") ->
      (* Apply a move declared with `move M from P to Q { ... }`.
       *
       * __apply_move_in_<S> is equivalent to apply_move for the interpreter
       * semantics (the space is runtime metadata, it does not change the
       * computed value).
       *
       * Adapter: the surface representation of a place value is the
       * curried application `__new_P v1 v2 ... vn`. We extract the
       * field list from place_fields_table, look up the move, apply
       * each mapping by name, and produce `__new_Q v1' ... vm'`.
       *)
      let source' = match try_reduce_builtin source with
        | Some v -> v | None -> source in
      (* Uncurry source to get (head, args). *)
      let rec uncurry t acc =
        match t with
        | App (f, a) -> uncurry f (a :: acc)
        | Var v -> Some (v, acc)
        | _ -> None
      in
      (match uncurry source' [] with
       | Some (head, args) when String.length head > 6
                              && String.sub head 0 6 = "__new_" ->
           let raw_place = String.sub head 6 (String.length head - 6) in
           let src_place =
             if String.length raw_place > 3
                && String.sub raw_place 0 3 = "in_" then
               let after_in = String.sub raw_place 3 (String.length raw_place - 3) in
               (try
                  let underscore = String.index after_in '_' in
                  String.sub after_in (underscore + 1)
                    (String.length after_in - underscore - 1)
                with Not_found -> raw_place)
             else raw_place
           in
           (match lookup_place_fields src_place,
                  Move_engine.lookup_move move_name with
            | Some src_fields, Some md ->
                (* Pair field names with arg values. *)
                let field_values =
                  try List.combine src_fields args
                  with Invalid_argument _ -> []
                in
                (match md.mv_body with
                 | Surface_ast.MoveMapping mappings ->
                     let target_place =
                       match md.mv_to with
                       | Some t -> t | None -> src_place in
                     (* Apply each mapping: lookup user fn, apply it to
                      * the corresponding source field's value. *)
                     let new_values = List.filter_map
                       (fun m ->
                          let open Surface_ast in
                          match List.assoc_opt m.m_from field_values with
                          | None -> None
                          | Some src_val ->
                              (* Call user-defined fn m.m_by on src_val.
                               * Look it up in Move_engine's user fun
                               * registry. If not registered, pass-through. *)
                              match Move_engine.lookup_user_fun m.m_by with
                              | None -> Some (m.m_to, src_val)
                              | Some fn_term ->
                                  (* Apply fn_term to src_val. Need the
                                   * full reduce hook to drive evaluation. *)
                                  let call = App (fn_term, src_val) in
                                  let result =
                                    try (!Reduce.full_reduce_hook)
                                          Reduce.empty_ctx call
                                    with _ -> call
                                  in
                                  Some (m.m_to, result))
                       mappings
                     in
                     (* Build __new_<target_place> v1 v2 ... vm in the
                      * order of the target place's field declarations. *)
                     (match lookup_place_fields target_place with
                      | None -> None
                      | Some tgt_field_names ->
                          let ordered = List.map
                            (fun fn ->
                               match List.assoc_opt fn new_values with
                               | Some v -> v
                               | None -> Unit)
                            tgt_field_names
                          in
                          let head_t = Var ("__new_" ^ target_place) in
                          let result_term = List.fold_left
                            (fun acc v -> App (acc, v)) head_t ordered
                          in
                          Some result_term)
                 | Surface_ast.MoveMerge _ ->
                     (* Merge form not yet wired through surface; skip *)
                     None)
            | _ -> None)
       | _ -> None)
  | App (Var "refl", arg) ->
      (* refl(a) : Path A a a — at runtime, the witness for a path of
       * a to itself reduces to the argument itself. Operationally,
       * refl is the identity coercion: it's the trivial element of
       * the equality type, with no computational content. *)
      let arg' = match try_reduce_builtin arg with Some v -> v | None -> arg in
      Some arg'
  | App (App (Var "transport", _path), value) ->
      (* transport(p, x) : the path moves x along p. By regularity, if
       * p is refl (the trivial path), transport is the identity. In
       * the prototype we treat transport conservatively as identity:
       * the result is the original value. Full transport semantics
       * (substituting along a non-trivial path) requires interval
       * variable evaluation, which we defer. *)
      let value' = match try_reduce_builtin value with Some v -> v | None -> value in
      Some value'
  | App (App (Var "transp", _path), value) ->
      let value' = match try_reduce_builtin value with Some v -> v | None -> value in
      Some value'
  | App (App (Var "concat", _p1), _p2) ->
      (* Path concatenation: at the witness level, the concatenated
       * path is itself a witness; we mark it as the inert witness
       * since we have no path value to expose. *)
      Some (Var "__coh_witness")
  | App (Var "inv", _path) ->
      (* Path inversion: also a witness; inert. *)
      Some (Var "__coh_witness")
  | App (App (Var "ap", _f), p) ->
      (* Action on paths: ap f p produces a new path. We treat the
       * result conservatively as the input path's witness. *)
      let p' = match try_reduce_builtin p with Some v -> v | None -> p in
      Some p'
  | App (App (Var "path_app", p), _i) ->
      (* Path applied at an interval point: returns the path's value
       * at that point. For refl-like paths we have no interval
       * variation, so we return the witness. *)
      let p' = match try_reduce_builtin p with Some v -> v | None -> p in
      Some p'
  | App (Var "__effect_print", arg) ->
      (* The actual output side effect: invoked by the __Console.print
       * handler body after handler dispatch substitutes the argument. *)
      (match decode_string arg with
       | Some str -> append_output str; Some Unit
       | None -> None)
  | App (Var name, arg) when String.length name > 7 && String.sub name 0 7 = "Output_" ->
      (* Output__print called with single arg (no unit) — direct path
       * when the call is not wrapped in a with-handler block. *)
      (match decode_string arg with
       | Some str ->
           append_output str;
           Some Unit
       | None -> None)
  | _ ->
      (* Fall through to additional hooks. First try Heyting, then
       * stdlib runtime hooks for List/Map/Space/etc. *)
      (match !heyting_hook t with
       | Some r -> Some r
       | None -> !stdlib_hook t)

(* A pluggable hook for Heyting reduction (and, or, not, imp).
 * Registered by main.ml at startup with Heyting.try_reduce_heyt. *)
and heyting_hook : (term -> term option) ref = ref (fun _ -> None)

(* A pluggable hook for additional reduction strategies (e.g., the
 * stdlib runtime). Initially a no-op; main.ml registers
 * Stdlib_runtime.try_reduce_stdlib here at startup. *)
and stdlib_hook : (term -> term option) ref = ref (fun _ -> None)

(* ─── Top-level evaluator with builtin hooks ───────────────────────── *)

(* This is the primary entry point for evaluating Yon programs.
 *
 * Strategy: at each step, first try a builtin reduction. If none
 * applies, delegate to the standard Reduce.step. Continue until the
 * term reaches a normal form (no reduction possible) or fuel is
 * exhausted.
 *
 * The two reducers cooperate: Reduce.step handles alpha/beta/η/scope/with,
 * while try_reduce_builtin handles arithmetic, comparisons, and the
 * Output.print side effect. Both can reduce nested subterms.
 *)

(* Apply try_reduce_builtin recursively into a term — replaces all
 * fully-saturated builtin calls with their values, in one pass. *)
let rec deep_reduce_builtin (t : term) : term =
  let t' = match try_reduce_builtin t with
    | Some v -> v
    | None -> t
  in
  match t' with
  | App (f, a) ->
      let f' = deep_reduce_builtin f in
      let a' = deep_reduce_builtin a in
      let result = App (f', a') in
      (match try_reduce_builtin result with
       | Some v -> v
       | None -> result)
  | Lam (x, ty, body) -> Lam (x, ty, deep_reduce_builtin body)
  | Scope (s, body) -> Scope (s, deep_reduce_builtin body)
  | With (r, body) -> With (r, deep_reduce_builtin body)
  | Emit body -> Emit (deep_reduce_builtin body)
  | StreamCons (h, k) -> StreamCons (deep_reduce_builtin h, deep_reduce_builtin k)
  | other -> other

(* ─── Cubical bridge ──────────────────────────────────────────────────
 * Path/transport are core kernel terms; their head reductions are computed
 * by the cubical engine. Translate the path skeleton to cterm, normalize
 * there, translate back. Core terms the engine cannot represent are caught
 * and the term is left stuck (try/with -> None), never silently mangled. *)

let rec to_cinterval (r : interval) : Cubical.interval =
  match r with
  | I0 -> Cubical.I0
  | I1 -> Cubical.I1
  | IVar i -> Cubical.IVar i
  | IMin (a, b) -> Cubical.IMin (to_cinterval a, to_cinterval b)
  | IMax (a, b) -> Cubical.IMax (to_cinterval a, to_cinterval b)
  | INeg a -> Cubical.INeg (to_cinterval a)

let rec of_cinterval (r : Cubical.interval) : interval =
  match r with
  | Cubical.I0 -> I0
  | Cubical.I1 -> I1
  | Cubical.IVar i -> IVar i
  | Cubical.IMin (a, b) -> IMin (of_cinterval a, of_cinterval b)
  | Cubical.IMax (a, b) -> IMax (of_cinterval a, of_cinterval b)
  | Cubical.INeg a -> INeg (of_cinterval a)

let rec ast_ty_to_surface (a : ty) : Surface_ast.ty =
  match a with
  | TyPlace n ->
      (* A primitive place (number/text/...) maps to a surface primitive; any
         other place maps to a user type. Primitiveness is a property of the
         name now that TyBase is gone (a primitive is a place whose name is
         primitive). *)
      if Carrier.is_prim_name n then Surface_ast.TyPrim n
      else Surface_ast.TyUser n
  | TyType n -> Surface_ast.TyUniverse n
  | TyStream t -> Surface_ast.TyStream (ast_ty_to_surface t)
  | TyArrow (x, y) -> Surface_ast.TyArrow (ast_ty_to_surface x, ast_ty_to_surface y)
  | TyPi (x, p, q) -> Surface_ast.TyPi (x, ast_ty_to_surface p, ast_ty_to_surface q)
  | TySigma (x, p, q) -> Surface_ast.TySigma (x, ast_ty_to_surface p, ast_ty_to_surface q)
  | _ -> failwith "[cubical bridge] core type not convertible (transport on this type not wired)"

let rec surface_ty_to_ast (a : Surface_ast.ty) : ty =
  match a with
  | Surface_ast.TyPrim n -> TyPlace n
  | Surface_ast.TyUser n -> TyPlace n
  | Surface_ast.TyUniverse n -> TyType n
  | Surface_ast.TyStream t -> TyStream (surface_ty_to_ast t)
  | Surface_ast.TyArrow (x, y) -> TyArrow (surface_ty_to_ast x, surface_ty_to_ast y)
  | Surface_ast.TyPi (x, p, q) -> TyPi (x, surface_ty_to_ast p, surface_ty_to_ast q)
  | Surface_ast.TySigma (x, p, q) -> TySigma (x, surface_ty_to_ast p, surface_ty_to_ast q)
  | _ -> failwith "[cubical bridge] surface type not convertible back to core"

let rec to_cterm (t : term) : Cubical.cterm =
  match t with
  | PLam (i, b) -> Cubical.CPathLam (i, to_cterm b)
  | PApp (p, r) -> Cubical.CPathApp (to_cterm p, to_cinterval r)
  | Transp ((i, a), b) -> Cubical.CTransport ((i, to_ctype a), to_cterm b)
  | Comp (a, phi, sides, base) ->
      Cubical.CComp (to_ctype a, phi,
                     List.map (fun (j, f, t') -> (j, f, to_cterm t')) sides,
                     to_cterm base)
  | HComp (a, phi, sides, base) ->
      Cubical.CHComp (to_ctype a, phi,
                      List.map (fun (j, f, t') -> (j, f, to_cterm t')) sides,
                      to_cterm base)
  | GlueElem (phi, t', a') -> Cubical.CGlueElem (phi, to_cterm t', to_cterm a')
  | Unglue t' -> Cubical.CUnglue (to_cterm t')
  | HITElim (branches, scrut) ->
      Cubical.CHITElim
        (List.map (fun (n, vs, b) -> (n, vs, to_cterm b)) branches,
         to_cterm scrut)
  | HITConstr (n, args) -> Cubical.CHITConstr (n, List.map to_cterm args)
  | Var x -> Cubical.CInhabitant (Cubical.CVar x)
  | t -> Cubical.CCore t
      (* opaque lift: any non-cubical core term (equivalence Pair, lambdas,
       * projections, applications) crosses the engine intact and is unfolded
       * by of_cterm on the way back. *)

and to_ctype (a : ty) : Cubical.ctype =
  match a with
  | TyId (carrier, x, y) ->
      (* the structured case: a Path/Id type, whose endpoints may mention the
       * interval variable, so the engine sees the dependence. *)
      Cubical.CTPath (to_ctype carrier, to_cterm x, to_cterm y)
  | TyGlue (a, phi, pairs) ->
      Cubical.CTGlue (to_ctype a, phi,
                      List.map (fun (t', e) -> (to_ctype t', to_cterm e)) pairs)
  | TyPathP ((i, a), x, y) ->
      Cubical.CTPathP ((i, to_ctype a), to_cterm x, to_cterm y)
  | _ -> Cubical.CTBase (ast_ty_to_surface a)

and of_cterm (c : Cubical.cterm) : term =
  match c with
  | Cubical.CPathLam (i, b) -> PLam (i, of_cterm b)
  | Cubical.CPathApp (p, r) -> PApp (of_cterm p, of_cinterval r)
  | Cubical.CTransport ((i, ct), b) -> Transp ((i, of_ctype ct), of_cterm b)
  | Cubical.CComp (ct, phi, sides, base) ->
      Comp (of_ctype ct, phi,
            List.map (fun (j, f, t') -> (j, f, of_cterm t')) sides,
            of_cterm base)
  | Cubical.CHComp (ct, phi, sides, base) ->
      HComp (of_ctype ct, phi,
             List.map (fun (j, f, t') -> (j, f, of_cterm t')) sides,
             of_cterm base)
  | Cubical.CGlueElem (phi, t', a') -> GlueElem (phi, of_cterm t', of_cterm a')
  | Cubical.CUnglue t' -> Unglue (of_cterm t')
  | Cubical.CHITConstr ("__app", [f; a]) -> App (of_cterm f, of_cterm a)
  | Cubical.CHITConstr ("__equiv_fwd", [e; t']) ->
      (* equivalence = Pair (f, (g, (eta, eps))) in the core; the forward map is
       * Fst e. The engine has no first-class App/Fst at its layer, so it emits
       * the marker and the projection + application happen in the core. *)
      App (Fst (of_cterm e), of_cterm t')
  | Cubical.CHITConstr ("__equiv_bwd", [e; t']) ->
      (* backward map g = Fst (Snd e) of the quasi-inverse Pair *)
      App (Fst (Snd (of_cterm e)), of_cterm t')
  | Cubical.CHITConstr (name, args) ->
      (* generic HIT constructor: base, loop, north, merid x, ... — now a
       * first-class core term, no longer stuck at the bridge. *)
      HITConstr (name, List.map of_cterm args)
  | Cubical.CHITElim (branches, scrut) ->
      HITElim
        (List.map (fun (n, vs, b) -> (n, vs, of_cterm b)) branches,
         of_cterm scrut)
  | Cubical.CCore t -> t
  | Cubical.CInhabitant (Cubical.CVar x) -> Var x
  | Cubical.CVar x -> Var x
  | _ -> failwith "[cubical bridge] cterm not lowerable to a core term"

and of_ctype (ct : Cubical.ctype) : ty =
  match ct with
  | Cubical.CTBase a -> surface_ty_to_ast a
  | Cubical.CTPath (c, x, y) -> TyId (of_ctype c, of_cterm x, of_cterm y)
  | Cubical.CTGlue (a, phi, pairs) ->
      TyGlue (of_ctype a, phi,
              List.map (fun (t', e) -> (of_ctype t', of_cterm e)) pairs)
  | Cubical.CTPathP ((i, ct), x, y) ->
      TyPathP ((i, of_ctype ct), of_cterm x, of_cterm y)
  | _ -> failwith "[cubical bridge] ctype not lowerable to a core type"

let try_cubical (t : term) : term option =
  match t with
  | PApp _ | Transp _ | Comp _ | HComp _ | GlueElem _ | Unglue _ | HITElim _ ->
      (try
         let t' = of_cterm (Cubical.normalize_cterm (to_cterm t)) in
         if term_equal_env [] t' t then None else Some t'
       with _ -> None)
  | _ -> None

let rec reduce_with_builtins ?(fuel = 1000) (ctx : Reduce.ctx) (t : term) : term =
  if fuel <= 0 then t
  else
    (* Try builtin reductions first (arithmetic, conditionals, Output). *)
    match try_reduce_builtin t with
    | Some t' -> reduce_with_builtins ~fuel:(fuel - 1) ctx t'
    | None ->
        (* Try standard reduction (R_Yon kernel). *)
        match Reduce.step ctx t with
        | Some t' -> reduce_with_builtins ~fuel:(fuel - 1) ctx t'
        | None ->
            (* Path/transport: reduce via the cubical engine bridge. *)
            match try_cubical t with
            | Some t' -> reduce_with_builtins ~fuel:(fuel - 1) ctx t'
            | None ->
            (* No more reductions possible at the head. Try ONE pass of
             * pure (non-side-effectful) deep builtin reduction, then stop.
             * Side-effectful operations (Space, Lattice, Map, Output) are
             * NOT deep-reduced: they must fire only in their natural
             * sequence, never in arbitrary subterm positions. *)
            let t' = deep_reduce_pure t in
            if t' = t then t  (* truly stuck *)
            else reduce_with_builtins ~fuel:(fuel - 1) ctx t'

(* Like deep_reduce_builtin but skips side-effectful operations. *)
and deep_reduce_pure (t : term) : term =
  let is_effectful_head t =
    let rec head_of = function
      | App (f, _) -> head_of f
      | Var v -> Some v
      | _ -> None
    in
    match head_of t with
    | Some name ->
        let prefix p =
          String.length name >= String.length p
          && String.sub name 0 (String.length p) = p
        in
        prefix "Space__"
        || prefix "PerfectMap__" || prefix "Output__"
        (* Note: List__, Map__ are pure functional (each op creates a
         * new id; no in-place mutation), so they CAN be deep-reduced.
         * Only Space, PerfectMap, Output have mutable state
         * and must follow strict reduction order.
         *
         * Note: Stream__ has mutable state (the stream queue), but we leave it
         * deep-reducible because the CBV order of Reduce.step cannot bring it
         * under stdlib_hook. The side effect is contained: each send produces
         * an idempotent effect in the interpreter's queue store; reduce does
         * not duplicate calls. *) 
    | None -> false
  in
  if is_effectful_head t then t
  else
    let t' = match try_reduce_builtin t with
      | Some v -> v
      | None ->
          (* Try stdlib_hook too before returning unchanged. try_reduce_builtin
           * does not know the stdlib builtins (List, Map, Stream, etc.); those
           * arrive via the stdlib_hook mounted at startup. Without this
           * fallback, expressions like Stream__send(s, v) stay stuck in
           * deep_reduce_pure. *)
          (match !stdlib_hook t with Some v -> v | None -> t)
    in
    match t' with
    | App (f, a) ->
        let f' = deep_reduce_pure f in
        let a' = deep_reduce_pure a in
        let result = App (f', a') in
        (match try_reduce_builtin result with
         | Some v when not (is_effectful_head result) -> v
         | _ ->
             (* Likewise: try stdlib_hook before returning. *)
             (match !stdlib_hook result with
              | Some v -> v
              | None -> result))
    | Lam (x, ty, body) -> Lam (x, ty, deep_reduce_pure body)
    | Scope (s, body) -> Scope (s, deep_reduce_pure body)
    | With (r, body) -> With (r, deep_reduce_pure body)
    | Emit body -> Emit (deep_reduce_pure body)
    | StreamCons (h, k) -> StreamCons (deep_reduce_pure h, deep_reduce_pure k)
    | (PApp _ | Transp _ | Comp _ | HComp _
      | GlueElem _ | Unglue _ | HITElim _) as ct ->
        (match try_cubical ct with
         | Some v -> deep_reduce_pure v
         | None -> ct)
    | other -> other
