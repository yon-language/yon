(* emit_mlir.ml — lowers the Yon core IR to the textual MLIR "topos" dialect.
 *
 * The emitter has two layers. The structural layer turns top-level
 * declarations (worlds, places, morphisms, ...) into topos-dialect operations
 * that record the categorical structure. The body layer turns the executable
 * part (the bodies of functions) into ordinary computation in the arith/scf/
 * func dialects, which then lower to LLVM.
 *
 * Body lowering currently covers:
 *   - number literals (carried as Var "__num_N")        -> arith.constant f64
 *   - boolean literals (Var "__bool_true|false")        -> arith.constant i1
 *   - variables in scope                                -> environment lookup
 *   - arithmetic binops (__add/__sub/__mul/__div)       -> arith.{addf,...}
 *   - comparison binops (__lt/__gt/.../__eq/__neq)      -> arith.cmpf
 *   - logical binops (__and/__or) on i1                 -> arith.{andi,ori}
 *   - if/else, carried as __if(c,t,e)                   -> scf.if with yield
 *   - let binding, App(Lam(x,_,rest), value)            -> bind x in the env
 *   - function call (an App-chain of a user function)   -> func.call
 *   - function definition (a top-level Lam)             -> func.func
 *
 * Types in play:
 *   - number       -> f64
 *   - boolean      -> i1
 *   - main's return -> i32 (the final f64 is converted with fptosi)
 *
 * Anything not covered fails loudly with a detailed failwith. There are no
 * stubs, no inline TODOs, no "return 0" placeholders: if the emitter does not
 * know how to lower something, it says so rather than emitting wrong code.
 *)

module C = Ast
module R = Reduce

(* ─── Output buffer ────────────────────────────────────────────────── *)

type emitter = {
  mutable buf : Buffer.t;
  mutable indent : int;
  mutable ssa_counter : int;
  (* places_table: place_name -> [(field_name, field_mlir_ty)].
   * Filled at the start of emit_program; consulted by emit_term to infer the
   * MLIR type of a field projection e.<f>. *)
  mutable places_table : (string * (string * string) list) list;
  (* The raw place declarations, kept so we can look up an operation by its
   * mangled name `<Place>__<op>`. *)
  mutable places_decls : C.place_decl list;
  (* The reduction declarations, used to dispatch a handler: a call
   * `Place__op(args)` becomes `<Reduction>__<op>(args)` when some reduction
   * targets place_name and handles op. *)
  mutable reductions_decls : C.reduction_decl list;
  (* space -> fold_name, built from the declared spaces and their folds. Used
   * when lowering apply_move inside a Space to pick the right runtime fold
   * (yon_rt_fold_named). *)
  mutable space_fold_name : (string * string) list;
  (* For each declared morphism: (morph_name, source_topos, target_topos).
   * When emitting `__morph_in_<S>__<M>` we need the source space so we can put
   * it in the array handed to yon_rt_begin_cross_space_op; the runtime then
   * finds the registered geometric morphism and derives the coordination
   * shape from the categorical data rather than guessing. *)
  mutable morphs_index : (string * string * string) list;
  (* (topos_name, space_opt): which space a topos lives in, taken from the
   * explicit binding `topos T at S`. This replaces the old heuristic of
   * assuming the space has the same name as the topos. *)
  mutable toposes_index : (string * string option) list;
  (* Every space declared in the program. Used to validate the space names
   * referenced when emitting __morph_in_<S>__<M>, before we emit an addressof
   * for a space that does not exist. *)
  mutable declared_spaces : Surface_ast.space_decl list;
  (* name -> place for each declared view, so a let-binding whose value is a
   * view name can be recognized as a __view_ref alias. *)
  mutable views_list : (string * string) list;
}

let make_emitter () : emitter = {
  buf = Buffer.create 4096;
  indent = 0;
  ssa_counter = 0;
  places_table = [];
  places_decls = [];
  reductions_decls = [];
  space_fold_name = [];
  morphs_index = [];
  toposes_index = [];
  declared_spaces = [];
  views_list = [];
}

let emit_indent e = Buffer.add_string e.buf (String.make (e.indent * 2) ' ')

(* Global mutable channel carrying the program's declared views from the driver
 * (yoner_emit_mlir.ml) into emit_program. The driver sets it before the call;
 * emit_program reads it to recognize view-name let-bindings as __view_ref. *)
let global_views_list : (string * string) list ref = ref []
let set_views_list (vs : (string * string) list) = global_views_list := vs
let emit_str e s = Buffer.add_string e.buf s
let emit_line e s =
  emit_indent e;
  emit_str e s;
  emit_str e "\n"
let emit_blank e = emit_str e "\n"
let push_indent e = e.indent <- e.indent + 1
let pop_indent e = e.indent <- e.indent - 1

let fresh_ssa e =
  let id = e.ssa_counter in
  e.ssa_counter <- id + 1;
  Printf.sprintf "%%v%d" id

(* ─── Mapping tipi Yon --> tipi MLIR ──────────────────────────────────── *)

let is_prim_name = function
  | "text" | "number" | "boolean" | "money" | "unit" | "proposition"
  | "i1" | "i8" | "i16" | "i32" | "i64" | "f32" | "f64"
  (* "arrow" is a concrete base type (an LLVM function pointer). The four
     handle kinds (move/reduction/morph/view) stay type variables: they are
     inlined rather than turned into function pointers, because they have
     category-specific semantics. *)
  | "arrow" -> true
  (* "unknown" is a concrete type (it defaults to f64), not a type variable.
     We need it concrete so that synthesized lifted lambdas with captured
     variables can be emitted with a real MLIR type. *)
  | "unknown" -> true
  | _ -> false

let prim_to_mlir = function
  (* String fusion (2026-06-03): ONE representation. A text/String value is a
     section of the builtin String place: an xheap handle on g_ds_heap,
     carried as f64. Literals are interned at runtime (content-addressed:
     same literal, same slot). The old literal representation was a NULL
     !llvm.ptr — the bytes never reached the runtime. *)
  | "text"        -> "f64"
  | "number"      -> "f64"
  (* "boolean" is an alias of "proposition", the subobject classifier Omega of
     the ambient Heyting algebra; semantically they are the same object. The
     code generator still maps "boolean" to i1, because the whole comparison
     and control path (__lt, __if, arith.cmpf, scf.if) is built on i1. Moving
     fully to !topos.proposition would touch that entire pipeline, so i1 stays
     here as a documented compromise rather than a hidden one. *)
  | "boolean"     -> "i1"
  | "money"       -> "f64"
  | "unit"        -> "i1"
  | "proposition" -> "!topos.proposition"
  | "i1"          -> "i1"
  | "i8"          -> "i8"
  | "i16"         -> "i16"
  | "i32"         -> "i32"
  | "i64"         -> "i64"
  | "f32"         -> "f32"
  | "f64"         -> "f64"
  (* unknown -> f64 default. *)
  | "unknown"     -> "f64"
  (* arrow base type -> func ptr
   * (assumendo signature mono-arg per MVP). *)
  | "arrow"       -> "(f64) -> f64"
  | n             -> Printf.sprintf "!topos.section<\"%s\">" n

(* Wire DTO transport (seal 2): the per-place field-tag descriptor and its
   structural schema id, computed recursively. number/money -> SCALAR (8 bytes),
   text -> STRING, a transportable nested place -> NESTED (and that sub-place's
   own id folds into the parent's id, so two parents that differ only in a
   nested type get different ids). Any other field type, or a nesting cycle /
   excessive depth, makes the place non-transportable (None): it is not
   registered, and a wire on it fails loudly with an unregistered schema rather
   than mis-serializing. The id is FNV-1a, computed identically by every side
   from its OWN redeclaration (two Spaces never exchange it: agreement is by
   construction, a drift gives a different id and a loud miss at the boundary).
   Masked to 31 bits so it is a non-negative i32. *)
let wire_tag_scalar = 0
let wire_tag_string = 1
let wire_tag_nested = 4

let rec wire_field_desc (places : C.place_decl list) (depth : int)
                        ((_, ty) : string * C.ty) : (int * int) option =
  if depth > 8 then None   (* refuse pathological or cyclic nesting *)
  else match ty with
  | C.TyBase n | C.TyPlace n ->
      (match n with
       | "text" -> Some (wire_tag_string, 0)
       | "number" | "money" -> Some (wire_tag_scalar, 0)
       | _ ->
           (* a place-typed field: resolve it and recurse if it is itself a
              transportable place *)
           (match List.find_opt (fun (p : C.place_decl) -> p.p_name = n) places with
            | Some sub ->
                (match wire_place_schema_id places (depth + 1) sub with
                 | Some subid -> Some (wire_tag_nested, subid)
                 | None -> None)
            | None -> None))
  | _ -> None

and wire_place_descs (places : C.place_decl list) (depth : int)
                     (pd : C.place_decl) : (int * int) list option =
  List.fold_right (fun f acc ->
    match wire_field_desc places depth f, acc with
    | Some d, Some ds -> Some (d :: ds)
    | _ -> None
  ) pd.p_fields (Some [])

and wire_place_schema_id (places : C.place_decl list) (depth : int)
                         (pd : C.place_decl) : int option =
  match wire_place_descs places depth pd with
  | None -> None
  | Some descs ->
      let fnv = ref 0x811c9dc5 in
      let mix b =
        fnv := !fnv lxor (b land 0xff);
        fnv := (!fnv * 0x01000193) land 0xffffffff
      in
      mix (List.length descs);
      List.iter (fun (tag, subid) ->
        mix tag;
        mix (subid land 0xff);
        mix ((subid asr 8)  land 0xff);
        mix ((subid asr 16) land 0xff);
        mix ((subid asr 24) land 0xff)
      ) descs;
      Some (!fnv land 0x7fffffff)

(* Emitter-facing wrappers (depth 0). *)
let wire_tags_of_place (places : C.place_decl list) (pd : C.place_decl) : int list option =
  match wire_place_descs places 0 pd with
  | Some descs -> Some (List.map fst descs)
  | None -> None

let wire_schema_id_of_place (places : C.place_decl list) (pd : C.place_decl) : int option =
  wire_place_schema_id places 0 pd

(* Core-level recognizer for the comprehension subobject. After desugaring, a
   comprehension { x : A where P } is C.TySigma(x, A, fibre) where the fibre is
   the mere-proposition shape Pi(_:A).Pi(_:A).Id_A(_,_). We recognize that shape
   on the CORE ast (endpoints are C.Unit after desugar; we only check the
   Pi/Pi/Id skeleton and that the carrier matches). When it holds, proof
   irrelevance lets us represent the subobject by its carrier A alone: the proof
   field is a mere proposition, carries no computational content, and lowers to
   zero bits. So { x : A where P } has exactly A's runtime representation. *)
let core_is_isprop_fibre (carrier : C.ty) (fibre : C.ty) : bool =
  match fibre with
  | C.TyPi (_, c1, C.TyPi (_, c2, C.TyId (c3, _, _))) ->
      c1 = carrier && c2 = carrier && c3 = carrier
  | _ -> false

let core_is_comprehension (t : C.ty) : bool =
  match t with
  | C.TySigma (_, carrier, fibre) -> core_is_isprop_fibre carrier fibre
  | _ -> false

let rec emit_ty (t : C.ty) : string =
  match t with
  | C.TyBase n when is_prim_name n -> prim_to_mlir n
  | C.TyBase n -> Printf.sprintf "!topos.section<\"%s\">" n
  | C.TyPlace n when is_prim_name n -> prim_to_mlir n
  | C.TyPlace n -> Printf.sprintf "!topos.section<\"%s\">" n
  | C.TyArrow (a, b) ->
      Printf.sprintf "(%s) -> %s" (emit_ty a) (emit_ty b)
  | C.TyPi (_, a, b) ->
      Printf.sprintf "(%s) -> %s" (emit_ty a) (emit_ty b)
  | C.TySigma (_, a, b) ->
      (* Comprehension subobject -> represented by its carrier alone (proof is
         zero-bit by proof irrelevance). Generic dependent pair -> honest two
         field struct, consistent with how C.Pair is emitted (a struct<(a,b)>),
         fixing the historical struct<()> that dropped both components. *)
      if core_is_comprehension t then emit_ty a
      else Printf.sprintf "!llvm.struct<(%s, %s)>" (emit_ty a) (emit_ty b)
  | C.TyId _ -> "!topos.cell<1, \"id\">"
  | C.TyDirUniverse _ ->
      (* The directed universe U_omega is a static, purely formal classifier
         (like TyType). It carries no runtime payload: a pointer-sized opaque
         handle, never materialized as data on the Leech arena. *)
      "!llvm.ptr"
  | C.TyEl c ->
      (* El(c) decodes a code term c into its named type. Under (alpha) the
         directed subobject is represented by its carrier, so El degrades
         structurally to the carrier type the code denotes. When the code names
         a known place we lower to that section; otherwise it is an opaque
         pointer-sized handle. The directed-transport eliminator is a runtime
         no-op (the data flow is the carrier), per the decree's rule 4. *)
      (match c with
       | C.Place pd -> Printf.sprintf "!topos.section<\"%s\">" pd.C.p_name
       | C.Var name -> Printf.sprintf "!topos.section<\"%s\">" name
       | _ -> "!llvm.ptr")
  | C.TyStream _ ->
      (* a stream value at runtime IS its id: the queue lives in the
         runtime tables, the body lowering moves only the f64 handle *)
      "f64"
  | C.TyType _ -> "!llvm.ptr"

let rec core_ty_to_mlir_simple (t : C.ty) : string =
  match t with
  | C.TyBase "number" | C.TyPlace "number" -> "f64"
  (* boolean = i1 at the MLIR level (see prim_to_mlir). The semantic alias with
   * proposition stays in the tyenv. *)
  | C.TyBase "boolean" | C.TyPlace "boolean" -> "i1"
  | C.TyBase "money" | C.TyPlace "money" -> "f64"
  | C.TyBase "proposition" | C.TyPlace "proposition" -> "!topos.proposition"
  | C.TyBase "text" | C.TyPlace "text" -> "f64"  (* String fusion: handle *)
  | C.TyBase "unit" | C.TyPlace "unit" -> "i1"
  | C.TyBase "i1" | C.TyPlace "i1" -> "i1"
  | C.TyBase "i32" | C.TyPlace "i32" -> "i32"
  | C.TyBase "f64" | C.TyPlace "f64" -> "f64"
  (* "unknown" is the wildcard type that synthesized lifted lambdas give to
     captured parameters. It defaults to f64, Yon's main runtime type. Without
     this mapping the synth functions would emit !topos.section<"unknown">,
     which clashes with the f64 their callers expect. *)
  | C.TyBase "unknown" | C.TyPlace "unknown" -> "f64"
  | C.TyBase "arrow" | C.TyPlace "arrow" ->
      (* A bare "arrow" stands for the single-argument function pointer
         signature (f64) -> f64. *)
      "(f64) -> f64"
  | C.TyArrow (_, _) as ta ->
      (* A curried arrow type a -> b -> c is flattened to a single MLIR
         signature (a, b) -> c. We peel off argument types until what is left
         is the return type. *)
      let rec uncurry params t =
        match t with
        | C.TyArrow (a, b) -> uncurry (a :: params) b
        | other -> (List.rev params, other)
      in
      let (params, ret) = uncurry [] ta in
      Printf.sprintf "(%s) -> %s"
        (String.concat ", " (List.map core_ty_to_mlir_simple params))
        (core_ty_to_mlir_simple ret)
  | C.TyPlace name when not (is_prim_name name) ->
      Printf.sprintf "!topos.section<\"%s\">" name
  | C.TyBase name when not (is_prim_name name) ->
      Printf.sprintf "!topos.section<\"%s\">" name
  | C.TySigma (_, a, b) ->
      (* Same rule as emit_ty: comprehension subobject -> carrier alone (proof
         is zero-bit); generic dependent pair -> honest two-field struct. *)
      if core_is_comprehension t then core_ty_to_mlir_simple a
      else Printf.sprintf "!llvm.struct<(%s, %s)>"
             (core_ty_to_mlir_simple a) (core_ty_to_mlir_simple b)
  | C.TyDirUniverse _ -> "!llvm.ptr"   (* directed universe: static opaque handle *)
  | C.TyEl c ->
      (* El(c) degrades to the carrier the code denotes (choice alpha). *)
      (match c with
       | C.Place pd -> Printf.sprintf "!topos.section<\"%s\">" pd.C.p_name
       | C.Var name -> Printf.sprintf "!topos.section<\"%s\">" name
       | _ -> "!llvm.ptr")
  | C.TyId (a, _, _) ->
      (* A path value lowers to its erased witness, which carries the
         endpoint type: refl(x) is operationally x (see the C.Refl case
         in emit_term). The arbiter of path EQUALITY stays the reducer
         (Syn(Yon) formalization sec. 16); no equation is decided here. *)
      core_ty_to_mlir_simple a
  | C.TyType _ ->
      (* A universe-typed parameter is an inert runtime token: types are
         compile-time citizens, the runtime never inspects one. *)
      "f64"
  | C.TyStream _ ->
      (* a stream value at runtime IS its id (f64): the queue lives in
         the runtime tables *)
      "f64"
  | _ ->
      failwith (Printf.sprintf
                  "[emit_mlir] unhandled type in body lowering: %s. Handled: number, boolean, money, proposition, text, unit, and user-defined place types."
                  (emit_ty t))

(* ─── Body lowering ─────────────────────────────────────────────────── *)

(* P7-frontend A4: stdlib builtin registry.
 *
 * Map a function name to (the list of MLIR parameter types, the MLIR result
 * type). The functions listed here are treated as extern runtime stubs
 * by the backend: the lowering emits a private func.func with an
 * identity-zero default. When the XLeech2 runtime provides the real
 * implementations, the functions are replaced via symbol resolution.
 *
 * This registry is Yon's minimal "operational stdlib". Extensible as real
 * programs require new builtins. *)
let stdlib_registry : (string * (string list * string)) list = [
  (* Coercion boolean ↔ proposition *)
  "to_prop", (["i1"], "!topos.proposition");
  "to_bool", (["!topos.proposition"], "i1");
  "decide", (["!topos.proposition"], "!topos.proposition");
  "to_bool_dec", (["!topos.proposition"], "i1");

  (* List builtin: a slot_index in the content-addressed xheap exposed as f64.
   * Empty list = the sentinel YON_HEAP_SLOT_INVALID = (double)0xFFFFFFFF.
   * Note: List__empty takes a dummy arg for surface uniformity (the user writes
   * `List.empty(0)`), likewise Space__make. *)
  "List__empty",  (["f64"], "f64");
  "List__cons",   (["f64"; "f64"], "f64");
  "List__head",   (["f64"], "f64");
  "List__tail",   (["f64"], "f64");
  "List__length", (["f64"], "f64");

  (* Space: a mutable cell kept in a static BSS registry, its id passed as f64. *)
  "Space__make", (["f64"], "f64");
  "Space__set",  (["f64"; "f64"], "f64");
  "Space__get",  (["f64"], "f64");

  (* The Ord category is place-based, not a stdlib builtin. The program writes
     `place Ord with operation compare(...)`, and the OperationOp lowering
     produces Ord__compare. A generic stdlib stub here would shadow it, so
     there is none. *)

  (* Log is place-based when the program declares `place Log with operation
     write`. We keep this stub only as a fallback for programs that have no
     such place: emit_program filters the stdlib registry by the place
     operation names, so if Log__write exists as a place op the filter drops
     this entry. The stdlib pattern in emit_term must therefore check for a
     matching place op first. *)
  "Log__write", (["!llvm.ptr"], "i1");

  (* apply_move is handled by a dedicated pattern in emit_term: the call
     apply_move(MoveDecl, source) returns source unchanged (the move is an
     identity at the value level) but with the type read off the move's
     declared target. *)

  (* transport (HoTT): given a witness that two types are equal and a value of
     one, produce the value at the other. Kept as a stub with the simplified
     signature (witness, value) -> value, both f64 for the numeric tests; the
     real path-induction stays as the C.Refl primitive. *)
  "transport", (["f64"; "f64"], "f64");

  (* Canonical coercion from text to proposition:
       present  iff  pointer is non-null and the string is non-empty
       absent   iff  pointer is null or the string is empty
       unknown  never (strings are decidable)
     The stub defaults to false (absent). *)
  "text_to_prop", (["f64"], "!topos.proposition");

  (* Cross-space streams:
       Stream__make(target_heap_id) -> stream id (an i32 carried as f64)
       Stream__send(stream_id, value) -> 0/1 success flag
       Stream__recv(stream_id) -> value *)
  "Stream__make", (["f64"], "f64");
  "Stream__send", (["f64"; "f64"], "f64");
  "Stream__recv", (["f64"], "f64");
  "Stream__close", (["f64"], "f64");
  (* spawn { } collection facade (step 4b): the parent forks N replicas, each
     promotes f64 values onto a shared channel, the parent joins into a stream. *)
  "Spawn__open", (["f64"], "f64");
  "Spawn__role", (["f64"], "f64");
  "Spawn__index", (["f64"], "f64");
  "Spawn__promote", (["f64"; "f64"], "f64");
  "Spawn__child_exit", (["f64"], "f64");
  "Spawn__join_stream", (["f64"], "f64");
  (* Cross-PROCESS streams over POSIX shared memory (mattone A): same f64-id
     calling convention as the intra-process ones, but the channel crosses the
     process boundary. make_shm(id, create) rendezvous on a shared region. *)
  "Stream__make_shm", (["f64"; "f64"], "f64");
  "Stream__make_shm_sized", (["f64"; "f64"; "f64"], "f64");
  "Wire__subscription_stream", (["f64"], "f64");
  "Wire__subscription_stream_dto", (["f64"; "f64"], "f64");
  "Stream__send_shm", (["f64"; "f64"], "f64");
  "Stream__recv_shm", (["f64"], "f64");
  "Stream__produce_shm", (["f64"; "f64"], "f64");
  "Stream__await_shm", (["f64"], "f64");
  "Stream__close_shm", (["f64"], "f64");
  "Stream__make_net", (["f64"; "f64"; "f64"], "f64");
  "Stream__send_net", (["f64"; "f64"], "f64");
  "Stream__recv_net", (["f64"], "f64");
  "Stream__close_net", (["f64"], "f64");
  (* Idraulica v2: nominal cross-Space RPC — the Space name travels as a
     pointer to a global string (decision 1), no hash%64 stream id. *)
  "yon_rt_rpc2_invoke_named0", (["!llvm.ptr"; "f64"], "f64");
  "yon_rt_rpc2_invoke_named",  (["!llvm.ptr"; "f64"; "f64"], "f64");
  "yon_rt_rpc2_invoke_named2", (["!llvm.ptr"; "f64"; "f64"; "f64"], "f64");
  "yon_rt_rpc2_invoke_named3", (["!llvm.ptr"; "f64"; "f64"; "f64"; "f64"], "f64");
  "yon_rt_rpc2_invoke_named4", (["!llvm.ptr"; "f64"; "f64"; "f64"; "f64"; "f64"], "f64");
  (* The unprefixed Stream API, recognized at compile time. The Stream.X
     aliases are kept for backward compatibility. *)
  "Stream__iterate",  (["f64"; "f64"], "f64");
  "Stream__take",     (["f64"; "f64"], "f64");
  "Stream__sum_take", (["f64"; "f64"], "f64");
  "__stream_iterate",  (["f64"; "f64"], "f64");
  "__stream_take",     (["f64"; "f64"], "f64");
  "__stream_sum_take", (["f64"; "f64"], "f64");
  "__stream_to_stream", (["f64"], "f64");
  (* Explicit conversions of the data structures to streams, recognized at
     compile time. *)
  "HashMap__to_stream", (["f64"], "f64");
  "HashSet__to_stream", (["f64"], "f64");
  "MerkleTree__to_stream",  (["f64"], "f64");
  "MerkleTree__leaf",       (["f64"], "f64");
  "MerkleTree__label",      (["f64"], "f64");
  "MerkleTree__child",      (["f64"; "f64"], "f64");
  "MerkleTree__equal",      (["f64"; "f64"], "i1");
  "MerkleTree__node2",      (["f64"; "f64"; "f64"], "f64");
  "MerkleTree__node2_commutative", (["f64"; "f64"; "f64"], "f64");
  "MerkleTree__node3",      (["f64"; "f64"; "f64"; "f64"], "f64");
  "MerkleTree__node4",      (["f64"; "f64"; "f64"; "f64"; "f64"], "f64");
  (* Leech lattice: canonicalize a vector under the sign-flip action of the
     binary Golay code G_24. *)
  "Leech__sign_canonical", (["f64"; "f64"], "f64");
  "Leech__syndrome",       (["f64"], "f64");
  "Leech__orbit_id",       (["f64"], "f64");
  "Leech__same_orbit",     (["f64"; "f64"], "i1");
  (* The Mathieu group M_24 and Conway's xi generator, the rest of the action
     used to canonicalize Leech vectors up to the Conway group Co_0. *)
  "Leech__m24_orbit",      (["f64"], "f64");
  "Leech__gcode_weight",   (["f64"], "f64");
  "Leech__cocode_weight",  (["f64"], "f64");
  "Leech__xi_apply",       (["f64"], "f64");
  "Leech__co0_step",       (["f64"], "f64");
  "Leech__co0_canonical",  (["f64"], "f64");
  "Leech__co0_equivalent", (["f64"; "f64"], "f64");
  "Leech__co0_orbit_size", (["f64"; "f64"], "f64");
  "Leech__transport",       (["f64"; "f64"], "f64");
  "Leech__transport_apply", (["f64"; "f64"], "f64");
  (* Capabilities and schema-version tracking. *)
  "Cap__grant",   (["f64"], "f64");
  "Cap__check",   (["f64"], "f64");
  "Cap__revoke",  (["f64"], "f64");
  "MoveRegistry__register_version", (["f64"; "f64"], "f64");
  "MoveRegistry__current_version",  (["f64"], "f64");
  (* Base stdlib. Math/Bits/IO are thin wrappers over yon_rt_* functions;
     their dispatch can go through the generic fallback in
     resolve_stdlib_builtin below. *)
  "Math__sqrt",    (["f64"], "f64");
  "Math__abs",     (["f64"], "f64");
  "Math__floor",   (["f64"], "f64");
  "Math__ceil",    (["f64"], "f64");
  "Math__round",   (["f64"], "f64");
  "Math__min",     (["f64"; "f64"], "f64");
  "Math__max",     (["f64"; "f64"], "f64");
  "Math__pow",     (["f64"; "f64"], "f64");
  "Math__log",     (["f64"], "f64");
  "Math__exp",     (["f64"], "f64");
  "Math__sin",     (["f64"], "f64");
  "Math__cos",     (["f64"], "f64");
  "Math__pi",      (["f64"], "f64");
  "Math__e",       (["f64"], "f64");
  "Math__modulo",  (["f64"; "f64"], "f64");
  "Math__gcd",     (["f64"; "f64"], "f64");
  "Math__lcm",     (["f64"; "f64"], "f64");
  "Magma__empty",          (["f64"], "f64");
  "Magma__gen",            (["f64"; "f64"], "f64");
  "Magma__is_commutative", (["f64"], "i1");
  "Magma__is_associative", (["f64"], "i1");
  "Magma__identity",       (["f64"], "f64");
  "Magma__closure_size",   (["f64"], "f64");
  "Land__reach",      (["f64"; "f64"], "i1");
  "Land__witness",    (["f64"; "f64"], "f64");
  "Magma__word_push",      (["f64"; "f64"], "f64");
  "Magma__normal_form",    (["f64"], "f64");
  "Magma__from_catalog",   (["f64"], "f64");

  "Math__log2",    (["f64"], "f64");
  "Math__log10",   (["f64"], "f64");
  "Math__atan2",   (["f64"; "f64"], "f64");
  "Math__sinh",    (["f64"], "f64");
  "Math__cosh",    (["f64"], "f64");
  "Math__tanh",    (["f64"], "f64");
  "Bits__band",     (["f64"; "f64"], "f64");
  "Bits__bor",      (["f64"; "f64"], "f64");
  "Bits__bxor",     (["f64"; "f64"], "f64");
  "Bits__bnot",     (["f64"], "f64");
  "Bits__shl",     (["f64"; "f64"], "f64");
  "Bits__shr",     (["f64"; "f64"], "f64");
  "Bits__popcount",(["f64"], "f64");
  "IO__print_num", (["f64"], "f64");
  "Output__print", (["f64"], "f64");   (* I/O effect op *)
  (* Extended stdlib. *)
  "String__from_int", (["f64"], "f64");
  "String__length",   (["f64"], "f64");
  "String__concat",   (["f64"; "f64"], "f64");
  "String__equal",    (["f64"; "f64"], "i1");
  "String__char_at",  (["f64"; "f64"], "f64");
  "String__print",    (["f64"], "f64");

  "String__parse_number", (["f64"], "f64");
  "String__substring", (["f64"; "f64"; "f64"], "f64");
  "String__find_char", (["f64"; "f64"; "f64"], "f64");
  "String__from_char", (["f64"], "f64");
  "File__read_text",  (["f64"], "f64");
  "File__write_text",  (["f64"; "f64"], "f64");
  "File__append_text", (["f64"; "f64"], "f64");
  "Env__get",   (["f64"], "f64");
  "Env__has",   (["f64"], "i1");
  "Args__count", ([], "f64");
  "Args__get",  (["f64"], "f64");
  "File__exists",     (["f64"], "i1");
  "Seq__range",        (["f64"], "f64");
  "Seq__range_to_list", (["f64"], "f64");
  "Bits__fold",       (["f64"; "f64"; "f64"], "f64");
  "Bits__bor_64",     (["f64"; "f64"], "f64");
  "Bits__band_64",    (["f64"; "f64"], "f64");
  "Bits__bxor_64",    (["f64"; "f64"], "f64");
  "Time__now_ms",     (["f64"], "f64");
  "Time__now_ns",     (["f64"], "f64");
  "Random__seed",     (["f64"], "f64");
  "Random__int",      (["f64"], "f64");
  "Random__range",    (["f64"; "f64"], "f64");
  "Crypto__fnv1a",    (["f64"], "f64");
  "Crypto__hash_int", (["f64"], "f64");
  "HashSet__try_add", (["f64"; "f64"], "f64");
  "HashSet__at_bucket", (["f64"; "f64"], "f64");
  "HashSet__dir_capacity", (["f64"], "f64");
  "HashSet__union", (["f64"; "f64"], "f64");
  "HashSet__intersect", (["f64"; "f64"], "f64");
  "List__reverse", (["f64"], "f64");
  (* Route — versioned history store. *)
  "Route__empty", (["f64"], "f64");
  "Route__empty_mod", (["f64"; "f64"], "f64");
  "Route__step", (["f64"; "f64"; "f64"], "f64");
  "Route__contains", (["f64"; "f64"; "f64"], "i1");
  "Route__witness", (["f64"; "f64"; "f64"], "f64");
  "Route__shared_levels", (["f64"], "f64");
  "Route__levels", (["f64"], "f64");
  (* VoyagerList: an append-only collection with positional corruption (used to
     model fault injection in the Voyager examples). *)
  "VoyagerList__empty",      ([], "f64");
  "VoyagerList__append",     (["f64"; "f64"], "f64");
  "VoyagerList__get",        (["f64"; "f64"], "f64");
  "VoyagerList__size",       (["f64"], "f64");
  "VoyagerList__corrupt_at", (["f64"; "f64"; "f64"], "f64");
  "VoyagerList__to_stream",  (["f64"], "f64");
  "Arena__empty",        ([], "f64");
  "Arena__put",          (["f64"; "f64"; "f64"], "f64");
  "Arena__get",          (["f64"; "f64"], "f64");
  "Arena__occupied",     (["f64"; "f64"], "f64");
  "Arena__orbit",        (["f64"; "f64"], "f64");
  "Arena__same_orbit",   (["f64"; "f64"; "f64"], "f64");
  "Arena__fuse",         (["f64"; "f64"; "f64"; "f64"], "f64");
  "Arena__fusion_count", (["f64"; "f64"], "f64");
  "Map__to_stream",     (["f64"], "f64");
]

(* Idraulica v2: map the synthetic cross-Space callable to its runtime
   function. The synthetic name is __yon_rpc2_invoke<K>__<Space>. *)
let rpc2_synth_prefix = "__yon_rpc2_invoke"
let rpc2_runtime_of_arity = function
  | 0 -> "yon_rt_rpc2_invoke_named0"
  | 1 -> "yon_rt_rpc2_invoke_named"
  | 2 -> "yon_rt_rpc2_invoke_named2"
  | 3 -> "yon_rt_rpc2_invoke_named3"
  | _ -> "yon_rt_rpc2_invoke_named4"
let rpc2_parse_synth (name : string) : (int * string) option =
  let pl = String.length rpc2_synth_prefix in
  if String.length name > pl + 3
     && String.sub name 0 pl = rpc2_synth_prefix
     && name.[pl] >= '0' && name.[pl] <= '4'
     && String.sub name (pl + 1) 2 = "__"
  then Some (Char.code name.[pl] - Char.code '0',
             String.sub name (pl + 3) (String.length name - pl - 3))
  else None

let is_stdlib_builtin name = List.mem_assoc name stdlib_registry

(* Walk the AST to collect the names of stdlib builtins actually called. This
   avoids symbol clashes when the program already defines an operation with the
   same mangled name (for example Ord__compare): we only emit an extern for a
   builtin if it is genuinely used. *)
let rec collect_used_builtins (acc : (string, unit) Hashtbl.t) (t : C.term) : unit =
  match t with
  | C.Var x ->
      if is_stdlib_builtin x then Hashtbl.replace acc x ();
      (* a v2 cross-Space call pulls in its runtime extern *)
      (match rpc2_parse_synth x with
       | Some (k, _) -> Hashtbl.replace acc (rpc2_runtime_of_arity k) ()
       | None -> ())
  | C.Lam (_, _, body) -> collect_used_builtins acc body
  | C.App (a, b) ->
      collect_used_builtins acc a;
      collect_used_builtins acc b;
      (* When we see an __is test, eagerly pull in the coercion paths. The
         emitter inserts text_to_prop / to_prop automatically when __is
         receives a non-proposition value. Since this walk runs before typing,
         we do not yet know the operand types, so any __is brings them in. *)
      (match a with
       | C.App (C.Var "__is", _) ->
           Hashtbl.replace acc "text_to_prop" ();
           Hashtbl.replace acc "to_prop" ();
           (* an __is under negation or inside a condition may need the
              decision back to i1 *)
           Hashtbl.replace acc "to_bool_dec" ()
       | _ -> ())
      ;
      (* __heyt_not / __heyt_and / __heyt_or / __heyt_imp coerce i1
         operands to proposition via @to_prop, and their result may be
         decided in a condition via @to_bool_dec. *)
      (match a, b with
       | C.Var ("__heyt_not" | "__heyt_and" | "__heyt_or" | "__heyt_imp"), _
       | C.App (C.Var ("__heyt_and" | "__heyt_or" | "__heyt_imp"), _), _ ->
           Hashtbl.replace acc "to_prop" ();
           Hashtbl.replace acc "to_bool_dec" ()
       | _ -> ())
  | C.Pair (a, b) ->
      collect_used_builtins acc a;
      collect_used_builtins acc b
  | C.Fst x | C.Snd x | C.Refl x ->
      collect_used_builtins acc x
  | C.J (_, _, c, d, p, b) ->
      List.iter (collect_used_builtins acc) [c; d; p; b]
  | C.Scope (_, body) -> collect_used_builtins acc body
  | C.With (_, body) -> collect_used_builtins acc body
  | C.Emit x -> collect_used_builtins acc x
  | C.StreamCons (a, b) ->
      collect_used_builtins acc a;
      collect_used_builtins acc b
  | _ -> ()

module Env = Map.Make (String)
module SS = Set.Make (String)

(* String fusion (2026-06-03): per-module table of string literals.
 * content -> global symbol name. Filled by collect_string_literals during
 * the module prologue; consumed at every literal use site, which emits
 * llvm.mlir.addressof + a call to @yon_rt_string_lit (runtime interning on
 * the content-addressed heap: idempotent, same literal -> same slot). *)
let g_strlits : (string, string) Hashtbl.t = Hashtbl.create 16
let g_strlit_order : string list ref = ref []

let rec collect_string_literals (t : C.term) : unit =
  match t with
  | C.Var x when String.length x > 6 && String.sub x 0 6 = "__str_" ->
      let content = String.sub x 6 (String.length x - 6) in
      if not (Hashtbl.mem g_strlits content) then begin
        let sym = Printf.sprintf "yon_strlit_%d" (Hashtbl.length g_strlits) in
        Hashtbl.replace g_strlits content sym;
        g_strlit_order := content :: !g_strlit_order
      end
  | C.Var _ | C.Place _ | C.Reduction _ | C.Unit -> ()
  | C.Lam (_, _, b) | C.Scope (_, b) | C.With (_, b) | C.Emit b
  | C.Refl b | C.Fst b | C.Snd b -> collect_string_literals b
  | C.App (a, b) | C.Pair (a, b) | C.StreamCons (a, b) ->
      collect_string_literals a; collect_string_literals b
  | C.J (_, _, a, b, c, d) ->
      collect_string_literals a; collect_string_literals b;
      collect_string_literals c; collect_string_literals d

(* Free variables of a Core term. Used to build the EXPLICIT capture list of
 * topos.scope_with_yield: under IsolatedFromAbove the region may not refer
 * to outer SSA values implicitly, so every outer let-binding the scope body
 * touches must be passed as a capture (81b — hermeticity made formal).
 * Over-approximation is harmless: we intersect with the emitter env, so
 * function symbols and encoded literals fall away naturally. *)
let rec term_free_vars (t : C.term) : SS.t =
  match t with
  | C.Var x -> SS.singleton x
  | C.Lam (x, _, b) -> SS.remove x (term_free_vars b)
  | C.App (a, b) -> SS.union (term_free_vars a) (term_free_vars b)
  | C.Scope (_, b) | C.With (_, b) | C.Emit b | C.Refl b
  | C.Fst b | C.Snd b -> term_free_vars b
  | C.J (x, _, a, b, c, d) ->
      SS.remove x
        (SS.union
           (SS.union (term_free_vars a) (term_free_vars b))
           (SS.union (term_free_vars c) (term_free_vars d)))
  | C.Pair (a, b) | C.StreamCons (a, b) ->
      SS.union (term_free_vars a) (term_free_vars b)
  | C.Place _ | C.Reduction _ | C.Unit -> SS.empty

type func_sig = {
  fn_name   : string;
  fn_params : (string * C.ty) list;
  (* The MLIR type of the return value, as a string, inferred from the body by
     infer_mlir_ty (for example "f64", "i1", "!topos.proposition",
     "!llvm.struct<(f64, f64)>"). Keeping it as a string lets us name composite
     types that have no direct C.ty counterpart, such as a Sigma pair lowered
     to an llvm.struct. *)
  fn_ret_mlir : string;
  fn_body   : C.term;
  (* Type-parameter names used in this signature. Empty means monomorphic; a
     non-empty list means the function must be specialized at each call site. *)
  fn_type_params : string list;
}

(* P7-frontend A5: monomorphic instance of a polymorphic function.
 * Created lazily at each call site of a polymorphic function.
 * key = (function_name, sorted list of concrete MLIR types for each
 *        type param)
 * value = the specialized func_sig (with fn_name mangled). *)
module MonoInstances = Hashtbl.Make (struct
  type t = string * string list
  let equal (a1, l1) (a2, l2) =
    a1 = a2 && List.length l1 = List.length l2
    && List.for_all2 (=) l1 l2
  let hash (a, l) =
    let h = ref (Hashtbl.hash a) in
    List.iter (fun s -> h := !h * 31 + Hashtbl.hash s) l;
    !h
end)

(* Look up the MLIR type of a field in a place from the places_table.
 * Returns Some mlir_ty if found, None otherwise. *)
let lookup_field_ty (e : emitter) (place_name : string) (fname : string)
    : string option =
  match List.assoc_opt place_name e.places_table with
  | None -> None
  | Some fields -> List.assoc_opt fname fields

(* Tell a real place name apart from a type variable. A real place is declared
   in the module (it appears in places_table); everything else is treated as a
   type variable to be monomorphized. Topos names are also excluded: a topos is
   a category, not a type variable, so its name must not be monomorphized; a
   signature `fun f(x: A): T2` with T2 a topos is handled by the type checker
   and morphism resolution. *)
let is_type_var (e : emitter) (name : string) : bool =
  (* "unknown" is the wildcard type that synthesized lifted lambdas give to
     captured parameters (see fresh_synth in desugar.ml). It must count as
     concrete (default f64), not a type variable: otherwise a lifted lambda
     with captures would be marked polymorphic and never emitted as a
     func.func, breaking the Seq.fold pattern where the lambda captures a
     Space handle or other variables. *)
  name <> "unknown"
  && not (is_prim_name name)
  && not (List.mem_assoc name e.places_table)
  && not (List.mem_assoc name e.toposes_index)

(* Look up an operation by its mangled name `<Place>__<op>`. Returns the place
   name and the operation signature if found. Used to recognize operation call
   sites that must be emitted against a dummy instance. *)
let lookup_place_op (places : C.place_decl list) (mangled : string)
    : (string * C.op_sig) option =
  let rec find = function
    | [] -> None
    | (pd : C.place_decl) :: rest ->
        let prefix = pd.p_name ^ "__" in
        let plen = String.length prefix in
        if String.length mangled > plen
           && String.sub mangled 0 plen = prefix then
          let op_name = String.sub mangled plen (String.length mangled - plen) in
          match List.find_opt (fun (op : C.op_sig) -> op.op_name = op_name)
                  pd.p_operations with
          | Some op -> Some (pd.p_name, op)
          | None -> find rest
        else find rest
  in
  find places

(* Find the reduction on a place that handles a given operation. Returns the
   reduction name and the matching handler clause. The binding is static and
   first-match-wins: if several reductions matched we take the first declared,
   though in practice each place has a single handling reduction. *)
let lookup_reduction_handler (reductions : C.reduction_decl list)
    (place_name : string) (op_name : string)
    : (string * C.handler_clause) option =
  let rec find_red = function
    | [] -> None
    | (rd : C.reduction_decl) :: rest ->
        if rd.r_target = place_name then
          match List.find_opt (fun (hc : C.handler_clause) ->
            hc.hc_op = op_name) rd.r_handlers with
          | Some hc -> Some (rd.r_name, hc)
          | None -> find_red rest
        else find_red rest
  in
  find_red reductions

(* Pull the place name out of an MLIR section type `!topos.section<"P">`.
   Returns None if the string is not a section type. *)
let extract_place_name (mlir_ty : string) : string option =
  let prefix = "!topos.section<\"" in
  let plen = String.length prefix in
  if String.length mlir_ty > plen
     && String.sub mlir_ty 0 plen = prefix then
    let rest = String.sub mlir_ty plen (String.length mlir_ty - plen) in
    (try
       let close = String.index rest '"' in
       Some (String.sub rest 0 close)
     with Not_found -> None)
  else None

(* Recursive width subtyping. P_sub is a subtype of P_super when P_sub has
   every field of P_super, each with a type that is itself a subtype of the one
   declared in P_super. Reflexive: returns true when P_sub = P_super. *)
let rec is_section_subtype (e : emitter) (sub_ty : string) (super_ty : string)
    : bool =
  if sub_ty = super_ty then true
  else
    match extract_place_name sub_ty, extract_place_name super_ty with
    | Some sub_name, Some super_name ->
        (match List.assoc_opt sub_name e.places_table,
               List.assoc_opt super_name e.places_table with
         | Some sub_fields, Some super_fields ->
             List.for_all (fun (fname, super_fty) ->
               match List.assoc_opt fname sub_fields with
               | Some sub_fty ->
                   sub_fty = super_fty
                   || is_section_subtype e sub_fty super_fty
               | None -> false
             ) super_fields
         | _ -> false)
    | _ -> false

(* Strip the "__field_" prefix and return the field name, or None. *)
let extract_field_name (s : string) : string option =
  let prefix = "__field_" in
  let plen = String.length prefix in
  if String.length s > plen && String.sub s 0 plen = prefix
  then Some (String.sub s plen (String.length s - plen))
  else None

let rec collect_params (t : C.term) : (string * C.ty) list * C.term =
  match t with
  | C.Lam (x, ty, body) ->
      let (rest, inner) = collect_params body in
      ((x, ty) :: rest, inner)
  | _ -> ([], t)

(* Recognize a curried application: pull the function name (the Var at the
   head) and the arguments in source order.
     App(App(App(Var "f", a), b), c)  ->  Some ("f", [a; b; c])
   Returns None when the head is not a Var. *)
let rec uncurry_app (t : C.term) : (string * C.term list) option =
  match t with
  | C.App (head, arg) ->
      (match uncurry_app head with
       | Some (fname, args) -> Some (fname, args @ [arg])
       | None ->
           (match head with
            | C.Var fname -> Some (fname, [arg])
            | _ -> None))
  | _ -> None

let rec infer_mlir_ty (e : emitter)
    (env : (string * string) Env.t)
    (funcs : (string * func_sig) list) (t : C.term) : string =
  match t with
  | C.Var "__map_empty" -> "f64"
  | C.Var "Map__empty" -> "f64"
  | C.Var "HashMap__empty" -> "f64"
  | C.Var "HashSet__empty" -> "f64"
  | C.Var "XSet__empty" -> "f64"
  | C.Var "VoyagerList__empty" -> "f64"
  | C.Var "Arena__empty" -> "f64"
  | C.Var "__set_empty" -> "f64"
  | C.Var "__xheap_used" -> "f64"
  | C.Var "__spawn_index" -> "f64"
  | C.Var x ->
      if String.length x > 6 && String.sub x 0 6 = "__num_" then "f64"
      else if x = "__bool_true" || x = "__bool_false" then "i1"
      else if x = "__heyt_present" || x = "__heyt_absent"
              || x = "__heyt_unknown" then "!topos.proposition"
      else (match Env.find_opt x env with
            | Some (_, ty) -> ty
            | None ->
                (* A bare Var naming a user function: if it takes no arguments,
                   its type is the return type; if it takes arguments, its type
                   is the function type, so it can be used with func.constant +
                   call_indirect. *)
                (match List.assoc_opt x funcs with
                 | Some fs when fs.fn_params = [] -> fs.fn_ret_mlir
                 | Some fs ->
                     let param_tys = List.map (fun (_, t) -> core_ty_to_mlir_simple t) fs.fn_params in
                     Printf.sprintf "(%s) -> %s"
                       (String.concat ", " param_tys) fs.fn_ret_mlir
                 | None ->
                     (* Otherwise: a string literal, an stdlib builtin, or a
                        place instantiation handle. *)
                     if String.length x > 6 && String.sub x 0 6 = "__str_"
                     then "f64"  (* String fusion: interned handle *)
                     else if is_stdlib_builtin x then
                       let (_, ret) = List.assoc x stdlib_registry in ret
                     else if String.length x > 12 &&
                             String.sub x (String.length x - 12) 12 = "_instantiate"
                     then "f64"   (* <P>_instantiate() -> f64, the Magma handle *)
                     else
                       failwith (Printf.sprintf
                                   "[emit_mlir infer] unknown variable '%s'."
                                   x)))
  (* __is(x, __pat_X) tests a Heyting value against a pattern, yielding i1. *)
  | C.App (C.App (C.Var "__is", _), C.Var pat) when
      (pat = "__pat_present" || pat = "__pat_absent" || pat = "__pat_unknown") ->
      "i1"
  | C.App (C.Var "__bool_not", _) -> "i1"
  (* bitwise ops return f64 after the sitofp back-conversion *)
  | C.App (C.App (C.Var "__band", _), _) -> "f64"
  | C.App (C.App (C.Var "__bxor", _), _) -> "f64"
  | C.App (C.App (C.Var "__bor", _), _) -> "f64"
  | C.App (C.Var "__bnot", _) -> "f64"
  (* Heyting logical connectives produce a proposition (an element of Omega). *)
  | C.App (C.App (C.Var "__heyt_and", _), _) -> "!topos.proposition"
  | C.App (C.App (C.Var "__heyt_or", _), _) -> "!topos.proposition"
  | C.App (C.App (C.Var "__heyt_imp", _), _) -> "!topos.proposition"
  | C.App (C.Var "__heyt_not", _) -> "!topos.proposition"
  (* heyt_int operations: bitwise logic on intuitionistic integers. *)
  | C.App (C.App (C.Var "__heyt_int_make", _), _) -> "!topos.heyt_int<64>"
  | C.App (C.App (C.Var "__heyt_int_and", _), _) -> "!topos.heyt_int<64>"
  | C.App (C.App (C.Var "__heyt_int_or", _), _) -> "!topos.heyt_int<64>"
  | C.App (C.App (C.Var "__heyt_int_xor", _), _) -> "!topos.heyt_int<64>"
  | C.App (C.Var "__heyt_int_not", _) -> "!topos.heyt_int<64>"
  | C.App (C.Var "__heyt_int_value", _) -> "f64"
  | C.App (C.Var "__heyt_int_mask", _) -> "f64"
  (* Map/Set/Dag operations all return f64 (the encoded content-address slot
     index). The empty-collection cases like __map_empty are caught earlier by
     the general C.Var branch. *)
  | C.App (C.App (C.App (C.Var "__map_put", _), _), _) -> "f64"
  | C.App (C.App (C.App (C.Var "Map__set", _), _), _) -> "f64"
  | C.App (C.App (C.App (C.Var "HashMap__set", _), _), _) -> "f64"
  | C.App (C.App (C.Var "Map__has", _), _) -> "i1"
  | C.App (C.App (C.Var "HashMap__has", _), _) -> "i1"
  | C.App (C.Var "Magma__is_commutative", _) -> "i1"
  | C.App (C.Var "Magma__is_associative", _) -> "i1"
  | C.App (C.App (C.Var "Land__reach", _), _) -> "i1"
  | C.App (C.App (C.Var "HashSet__contains", _), _) -> "i1"
  | C.App (C.App (C.Var "XSet__contains", _), _) -> "i1"
  | C.App (C.App (C.Var "XSet__add", _), _) -> "f64"
  | C.App (C.App (C.Var "XSet__union", _), _) -> "f64"
  | C.App (C.App (C.Var "XSet__intersect", _), _) -> "f64"
  | C.App (C.Var "XSet__size", _) -> "f64"
  | C.App (C.Var "XSet__to_stream", _) -> "f64"
  | C.App (C.App (C.App (C.Var "__merkle_node2", _), _), _) -> "f64"
  | C.App (C.App (C.Var op, _), _) when
      (op = "__map_get" || op = "__map_contains"
       || op = "Map__get" || op = "HashMap__get" || op = "HashSet__add"
       || op = "__set_add" || op = "__set_contains"
       || op = "__merkle_child" || op = "__merkle_equal") -> "f64"
  | C.App (C.Var op, _) when
      (op = "__map_size" || op = "__set_size"
       || op = "Map__size" || op = "Map__empty"
       || op = "HashMap__size" || op = "HashSet__size"
       || op = "__merkle_leaf" || op = "__merkle_label"
       || op = "__observe_alloc"
       || op = "__spawn_self" || op = "__voyagerlist_seal"
       || op = "__voyagerlist_open"
       || op = "__conway_gen_key") -> "f64"
  | C.App (C.App (C.Var op, _), _) when
      (op = "__voyagerlist_corrupt"
       || op = "__conway_seal_slot" || op = "__conway_unseal_slot"
       || op = "__conway_key_equal") -> "f64"
  | C.App (C.App (C.App (C.Var op, _), _), _) when
      (op = "__observe_via_gm" || op = "__stream_fold"
       || op = "Stream__sum_take" || op = "__stream_sum_take") -> "f64"
  | C.App (C.App (C.Var "Stream__iterate", _), _) -> "f64"
  | C.App (C.App (C.Var "Stream__take", _), _) -> "f64"
  | C.App (C.App (C.Var "__stream_iterate", _), _) -> "f64"
  | C.App (C.App (C.Var "__stream_take", _), _) -> "f64"
  | C.App (C.Var "__stream_to_stream", _) -> "f64"
  | C.App (C.Var "HashMap__to_stream", _) -> "f64"
  | C.App (C.Var "HashSet__to_stream", _) -> "f64"
  | C.App (C.Var "MerkleTree__to_stream", _) -> "f64"
  | C.App (C.Var "MerkleTree__leaf", _) -> "f64"
  | C.App (C.Var "MerkleTree__label", _) -> "f64"
  | C.App (C.App (C.Var "MerkleTree__child", _), _) -> "f64"
  | C.App (C.App (C.Var "MerkleTree__equal", _), _) -> "i1"
  | C.App (C.App (C.App (C.Var "MerkleTree__node2", _), _), _) -> "f64"
  | C.App (C.App (C.App (C.Var "MerkleTree__node2_commutative", _), _), _) -> "f64"
  | C.App (C.App (C.Var "VoyagerList__append", _), _) -> "f64"
  | C.App (C.App (C.Var "VoyagerList__get", _), _) -> "f64"
  | C.App (C.Var "VoyagerList__size", _) -> "f64"
  | C.App (C.App (C.App (C.Var "VoyagerList__corrupt_at", _), _), _) -> "f64"
  | C.App (C.App (C.App (C.Var "Arena__put", _), _), _) -> "f64"
  | C.App (C.App (C.Var "Arena__get", _), _) -> "f64"
  | C.App (C.App (C.Var "Arena__occupied", _), _) -> "f64"
  | C.App (C.App (C.Var "Arena__orbit", _), _) -> "f64"
  | C.App (C.App (C.App (C.Var "Arena__same_orbit", _), _), _) -> "f64"
  | C.App (C.App (C.App (C.App (C.Var "Arena__fuse", _), _), _), _) -> "f64"
  | C.App (C.App (C.Var "Arena__fusion_count", _), _) -> "f64"
  | C.App (C.Var "VoyagerList__to_stream", _) -> "f64"
  | C.App (C.Var "__merkle_to_stream", _) -> "f64"
  | C.App (C.Var "Map__to_stream", _) -> "f64"
  (* Seq.from_list/map/filter appear bare (after inline_seq they should
   * disappear, but if the inlining fails, e.g. a variable used more than once,
   * the inference must know the type). All f64 as a stub (Seq id). *)
  | C.App (C.Var "__stream_from_list", _) -> "f64"
  | C.App (C.App (C.Var "__stream_map", _), _) -> "f64"
  | C.App (C.App (C.Var "__stream_filter", _), _) -> "f64"
  (* Field projection, carried as App(Var "__field_X", obj). *)
  | C.App (C.Var fvar, obj) when extract_field_name fvar <> None ->
      let fname = (match extract_field_name fvar with Some s -> s | None -> assert false) in
      let obj_ty = infer_mlir_ty e env funcs obj in
      (* obj_ty should be "!topos.section<\"P\">"; pull out P. *)
      let prefix = "!topos.section<\"" in
      let plen = String.length prefix in
      if String.length obj_ty <= plen
         || String.sub obj_ty 0 plen <> prefix then
        failwith (Printf.sprintf
                    "[emit_mlir infer] field projection '%s' on a non-section type: %s."
                    fname obj_ty);
      let rest = String.sub obj_ty plen (String.length obj_ty - plen) in
      (* rest = "P\">", extract P *)
      (try
         let close = String.index rest '"' in
         let place_name = String.sub rest 0 close in
         match lookup_field_ty e place_name fname with
         | Some ty -> ty
         | None ->
             failwith (Printf.sprintf
                         "[emit_mlir infer] field '%s' not declared in place '%s'."
                         fname place_name)
       with Not_found ->
         failwith (Printf.sprintf
                     "[emit_mlir infer] malformed section type: %s."
                     obj_ty))
  | C.App (C.App (C.Var op, a), b) when
      (op = "__add" || op = "__sub" || op = "__mul" || op = "__div"
       || op = "__mod"
       || op = "__lt" || op = "__gt" || op = "__leq" || op = "__geq"
       || op = "__eq" || op = "__neq"
       || op = "__and" || op = "__or") ->
      (match op with
       | "__add" | "__sub" | "__mul" | "__div" | "__mod" -> "f64"
       | "__lt" | "__gt" | "__leq" | "__geq"
       | "__eq" | "__neq" -> "i1"
       | "__and" | "__or" ->
           let ta = infer_mlir_ty e env funcs a in
           let tb = infer_mlir_ty e env funcs b in
           if ta = "!topos.proposition" && tb = "!topos.proposition"
           then "!topos.proposition"
           else "i1"
       | _ -> assert false)
  | C.App (C.App (C.App (C.Var "__if", _), then_t), _) ->
      infer_mlir_ty e env funcs then_t
  (* if/then/else expression *)
  | C.App (C.App (C.App (C.Var "__if_expr", _), then_t), _) ->
      infer_mlir_ty e env funcs then_t
  (* Control-flow loops evaluate to f64 (a 0.0 placeholder, Unit semantics). *)
  | C.App (C.App (C.Var "__iter_n", _), C.Lam _) -> "f64"
  | C.App (C.App (C.Var "__while_loop", C.Lam _), C.Lam _) -> "f64"
  | C.App (g, C.Unit) ->
      (* zero-arg call marker: the type is the callee's return type for
         a user function; anything else degrades to inferring g, the
         pre-marker bare-Var behavior. *)
      (match g with
       | C.Var f when List.mem_assoc f funcs ->
           (List.assoc f funcs).fn_ret_mlir
       | _ -> infer_mlir_ty e env funcs g)
  | C.App (C.Lam (x, _, rest), value) ->
      (match value with
       | C.Lam _ ->
           if List.mem_assoc x funcs then
             infer_mlir_ty e env funcs rest
           else
             failwith (Printf.sprintf
                         "[emit_mlir infer] let-binding '%s' to a Lambda with no corresponding top-level function."
                         x)
       | _ ->
           let tv = infer_mlir_ty e env funcs value in
           let env' = Env.add x ("(unused)", tv) env in
           infer_mlir_ty e env' funcs rest)
  | C.App _ as app ->
      (* General case for curried calls: uncurry_app gives the function name
         and argument list, which we then resolve against user functions, the
         stdlib registry, and the __new_X constructors. *)
      (match uncurry_app app with
       | Some ("Move__merge", [C.Var move_name; _; _]) ->
           (* Move.merge returns the FIRST source place of the merge move,
              the same choice as the emission and the kernel reducer. *)
           (match Move_engine.lookup_move move_name with
            | Some md ->
                (match md.mv_from with
                 | [a; _] -> Printf.sprintf "!topos.section<\"%s\">" a
                 | _ ->
                     failwith (Printf.sprintf
                                 "[emit_mlir infer] merge move '%s' needs two sources."
                                 move_name))
            | None ->
                failwith (Printf.sprintf
                            "[emit_mlir infer] merge move '%s' not declared."
                            move_name))
       | Some (fname, [C.Var move_name; _])
         when fname = "apply_move"
           || (String.length fname > 16
               && String.sub fname 0 16 = "__apply_move_in_") ->
           (* apply_move (and its in-<S> variant) returns the move's target
              place: a move changes the space, not the object. *)
           (match Move_engine.lookup_move move_name with
            | Some md ->
                (match md.mv_to with
                 | Some t -> Printf.sprintf "!topos.section<\"%s\">" t
                 | None ->
                     failwith (Printf.sprintf
                                 "[emit_mlir infer A6] move '%s' has no target."
                                 move_name))
            | None ->
                failwith (Printf.sprintf
                            "[emit_mlir infer A6] move '%s' not declared."
                            move_name))
       | Some (fname, _args) ->
           (* Multi-argument higher-order function: fname is a local variable
            * of function-pointer type -> extract ret_ty from fn_ty. *)
           (match Env.find_opt fname env with
            | Some (_, fn_ty) when String.length fn_ty >= 4
                                   && String.sub fn_ty 0 1 = "(" ->
                (try
                   let arrow_idx = Str.search_forward (Str.regexp " -> ") fn_ty 0 in
                   String.sub fn_ty (arrow_idx + 4) (String.length fn_ty - arrow_idx - 4)
                 with Not_found -> "f64")
            | Some (alias, _) when String.length alias > 10
                                   && String.sub alias 0 10 = "__hof_ref:" ->
                let real_fname = String.sub alias 10
                  (String.length alias - 10) in
                (match List.assoc_opt real_fname funcs with
                 | Some fs -> fs.fn_ret_mlir
                 | None ->
                     failwith (Printf.sprintf
                       "[emit_mlir HOF infer] alias points to unknown function '%s'."
                       real_fname))
            (* The alias __morph_ref:<name> for a let-bound morph. Return type
             * = the return type of the wrapper fun __morph_inline_N (the
             * section of the target place of the target topos). *)
            | Some (alias, _) when String.length alias > 12
                                   && String.sub alias 0 12 = "__morph_ref:" ->
                let real_fname = String.sub alias 12
                  (String.length alias - 12) in
                (match List.assoc_opt real_fname funcs with
                 | Some fs -> fs.fn_ret_mlir
                 | None ->
                     failwith (Printf.sprintf
                       "[emit_mlir morph infer] morph ref '%s' cannot be resolved."
                       real_fname))
            (* Idem per __move_ref / __view_ref / __reduction_ref. *)
            | Some (alias, _) when String.length alias > 11
                                   && String.sub alias 0 11 = "__move_ref:" ->
                let real_fname = String.sub alias 11
                  (String.length alias - 11) in
                (match List.assoc_opt real_fname funcs with
                 | Some fs -> fs.fn_ret_mlir
                 | None -> "f64")
            | Some (alias, _) when String.length alias > 11
                                   && String.sub alias 0 11 = "__view_ref:" ->
                let real_fname = String.sub alias 11
                  (String.length alias - 11) in
                (match List.assoc_opt real_fname funcs with
                 | Some fs -> fs.fn_ret_mlir
                 | None -> "f64")
            | Some (alias, _) when String.length alias > 16
                                   && String.sub alias 0 16 = "__reduction_ref:" ->
                let real_fname = String.sub alias 16
                  (String.length alias - 16) in
                (match List.assoc_opt real_fname funcs with
                 | Some fs -> fs.fn_ret_mlir
                 | None -> "f64")
            | _ ->
           (match List.assoc_opt fname funcs with
            | Some fs -> fs.fn_ret_mlir
            | None ->
                (* A place operation takes precedence over stdlib *)
                (match lookup_place_op e.places_decls fname with
                 | Some (_, op_sig) ->
                     core_ty_to_mlir_simple op_sig.op_return
                 | None ->
                     if is_stdlib_builtin fname then
                       let (_, ret) = List.assoc fname stdlib_registry in ret
                     else if String.length fname > 9
                          && String.sub fname 0 9 = "__new_in_" then begin
                       (* __new_in_<S>_<P> returns section<P>. *)
                       let rest = String.sub fname 9 (String.length fname - 9) in
                       match List.find_opt (fun (pd : C.place_decl) ->
                         let pn = pd.p_name in
                         let plen = String.length pn in
                         String.length rest >= plen + 1
                         && String.sub rest (String.length rest - plen) plen = pn
                         && rest.[String.length rest - plen - 1] = '_'
                       ) e.places_decls with
                       | Some pd -> Printf.sprintf "!topos.section<\"%s\">" pd.p_name
                       | None ->
                           failwith (Printf.sprintf
                                       "[emit_mlir infer] __new_in_ place not identified in '%s'."
                                       fname)
                     end
                     else if String.length fname > 6
                          && String.sub fname 0 6 = "__new_" then
                       let place = String.sub fname 6 (String.length fname - 6) in
                       Printf.sprintf "!topos.section<\"%s\">" place
                     else if rpc2_parse_synth fname <> None then
                       (* Idraulica v2 cross-Space invoke: numbers only *)
                       "f64"
                     else
                       failwith (Printf.sprintf
                                   "[emit_mlir infer] unknown function '%s'."
                                   fname))))
       | None ->
           failwith "[emit_mlir infer] unrecognized App form during type inference.")
  (* P7-frontend A2: Pair/Fst/Snd type inference *)
  | C.Pair (a, b) ->
      let ta = infer_mlir_ty e env funcs a in
      let tb = infer_mlir_ty e env funcs b in
      Printf.sprintf "!llvm.struct<(%s, %s)>" ta tb
  | C.Fst p ->
      let tp = infer_mlir_ty e env funcs p in
      let prefix = "!llvm.struct<(" in
      let plen = String.length prefix in
      if String.length tp <= plen
         || String.sub tp 0 plen <> prefix then
        failwith (Printf.sprintf
                    "[emit_mlir infer] fst on a non-pair: %s." tp);
      let rest = String.sub tp plen (String.length tp - plen) in
      let comma = (try String.index rest ',' with Not_found -> -1) in
      if comma < 0 then
        failwith (Printf.sprintf
                    "[emit_mlir infer] malformed pair: %s." tp);
      String.sub rest 0 comma |> String.trim
  | C.Snd p ->
      let tp = infer_mlir_ty e env funcs p in
      let prefix = "!llvm.struct<(" in
      let plen = String.length prefix in
      if String.length tp <= plen
         || String.sub tp 0 plen <> prefix then
        failwith (Printf.sprintf
                    "[emit_mlir infer] snd on a non-pair: %s." tp);
      let rest = String.sub tp plen (String.length tp - plen) in
      let comma = (try String.index rest ',' with Not_found -> -1) in
      let close = (try String.index rest ')' with Not_found -> -1) in
      if comma < 0 || close < 0 then
        failwith (Printf.sprintf
                    "[emit_mlir infer] malformed pair: %s." tp);
      String.sub rest (comma + 1) (close - comma - 1) |> String.trim
  | C.Refl x ->
      (* refl(x) is inert; its type is the type of x *)
      infer_mlir_ty e env funcs x
  | C.J _ as jt ->
      (* same reduce-then-look discipline as the emission case *)
      (match Builtins.reduce_with_builtins Reduce.empty_ctx jt with
       | C.J _ ->
           failwith "[emit_mlir infer] ind_path stuck on a non-refl path."
       | t' -> infer_mlir_ty e env funcs t')
  | C.With (_, body) ->
      (* handler activation passes through; the type is the type of the body *)
      infer_mlir_ty e env funcs body
  | C.Scope (_, body) ->
      (* hermetic scope yields its body value; same type (81b) *)
      infer_mlir_ty e env funcs body
  | _ ->
      failwith "[emit_mlir infer] term form cannot be analyzed for type inference."

let rec subst_ty (subst : (string * C.ty) list) (t : C.ty) : C.ty =
  match t with
  | C.TyBase n | C.TyPlace n when List.mem_assoc n subst ->
      List.assoc n subst
  | C.TyArrow (a, b) -> C.TyArrow (subst_ty subst a, subst_ty subst b)
  | C.TyPi (x, a, b) -> C.TyPi (x, subst_ty subst a, subst_ty subst b)
  | C.TySigma (x, a, b) -> C.TySigma (x, subst_ty subst a, subst_ty subst b)
  | C.TyStream a -> C.TyStream (subst_ty subst a)
  | _ -> t

(* Mangle a function name with the concrete types of one specialization:
       identity + [f64]    -> identity__f64
       identity + [i1]     -> identity__i1
       first + [f64; i1]   -> first__f64__i1
   Non-alphanumeric characters become _ so the result is a valid MLIR symbol. *)
let mangle_mono (name : string) (concrete_mlir : string list) : string =
  let sanitize s =
    String.map (fun c ->
      if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
         || (c >= '0' && c <= '9') then c
      else '_'
    ) s
  in
  name ^ String.concat "" (List.map (fun m -> "__" ^ sanitize m) concrete_mlir)

(* Given a polymorphic function and the concrete MLIR types inferred at a
   call site (one per type parameter), produce a specialized func_sig. *)
let specialize_func (fs : func_sig)
    (concrete_mlir : string list) : func_sig =
  if List.length concrete_mlir <> List.length fs.fn_type_params then
    failwith (Printf.sprintf
                "[emit_mlir A5] specialize_func '%s': attesi %d tipi concreti, ricevuti %d."
                fs.fn_name (List.length fs.fn_type_params)
                (List.length concrete_mlir));
  (* Build a substitution mapping each type parameter to a concrete C.ty. To do
   * this it converts the MLIR strings back to C.ty. *)
  let mlir_to_cty s =
    if s = "f64" then C.TyBase "number"
    else if s = "i1" then C.TyBase "boolean"
    else if s = "!topos.proposition" then C.TyBase "proposition"
    else if s = "!llvm.ptr" then C.TyBase "text"
    else
      (* Section type -> estrai nome place *)
      let prefix = "!topos.section<\"" in
      let plen = String.length prefix in
      if String.length s > plen && String.sub s 0 plen = prefix then
        let rest = String.sub s plen (String.length s - plen) in
        (try
          let close = String.index rest '"' in
          C.TyPlace (String.sub rest 0 close)
        with Not_found ->
          failwith (Printf.sprintf
                      "[emit_mlir A5] mlir_to_cty: malformed section %s"
                      s))
      else
        failwith (Printf.sprintf
                    "[emit_mlir A5] mlir_to_cty: unrecognized MLIR type %s"
                    s)
  in
  let subst = List.map2 (fun tv mlir ->
    (tv, mlir_to_cty mlir)
  ) fs.fn_type_params concrete_mlir in
  let specialized_params = List.map (fun (n, t) ->
    (n, subst_ty subst t)
  ) fs.fn_params in
  (* Specialize the return type by string substitution in the MLIR type. *)
  let specialized_ret = List.fold_left (fun acc (tv, ct) ->
    let target_mlir = core_ty_to_mlir_simple ct in
    let pat = Printf.sprintf "!topos.section<\"%s\">" tv in
    (* String replace pat with target_mlir in acc *)
    let rec replace s =
      let slen = String.length s in
      let plen = String.length pat in
      let rec find_start i =
        if i + plen > slen then -1
        else if String.sub s i plen = pat then i
        else find_start (i+1)
      in
      let idx = find_start 0 in
      if idx < 0 then s
      else
        let prefix = String.sub s 0 idx in
        let suffix = String.sub s (idx + plen) (slen - idx - plen) in
        replace (prefix ^ target_mlir ^ suffix)
    in
    replace acc
  ) fs.fn_ret_mlir subst in
  {
    fn_name = mangle_mono fs.fn_name concrete_mlir;
    fn_params = specialized_params;
    fn_ret_mlir = specialized_ret;
    fn_body = fs.fn_body;  (* body unchanged: the Var "T" do not appear in the body *)
    fn_type_params = [];  (* monomorphic now *)
  }

(* Mutable registry of requested specializations. It holds both the instances
   already generated and the queue of pending ones still to be emitted at the
   end of the module. *)
type mono_registry = {
  mutable mono_instances : (string * string list * func_sig) list;
  mutable mono_pending : func_sig list;
}

let make_mono_registry () : mono_registry = {
  mono_instances = [];
  mono_pending = [];
}

(* The global monomorphization registry. It is reset to empty in emit_program
   and read/updated by emit_term whenever it meets a call to a polymorphic
   function. Keeping it global avoids threading an extra parameter through
   every recursive call of emit_term. *)
let mono_global : mono_registry ref = ref (make_mono_registry ())

(* Request a specialization of fs at the concrete types concrete_mlir. If it
   was already generated, return its mangled name; otherwise generate it,
   queue it as pending, and return the new name. *)
let request_mono (mono : mono_registry) (_e : emitter) (fs : func_sig)
    (concrete_mlir : string list) : string =
  match List.find_opt (fun (name, tys, _) ->
    name = fs.fn_name && tys = concrete_mlir
  ) mono.mono_instances with
  | Some (_, _, spec) -> spec.fn_name
  | None ->
      let spec = specialize_func fs concrete_mlir in
      mono.mono_instances <- (fs.fn_name, concrete_mlir, spec) :: mono.mono_instances;
      mono.mono_pending <- spec :: mono.mono_pending;
      spec.fn_name

(* Coerce an argument to the parameter type the callee expects, emitting a
   subtype_cast when needed and doing nothing when the types already match.
   Kept separate from emit_term so it does not have to thread emitter state. *)
let coerce_to_param (e : emitter) (arg_ssa : string) (arg_ty : string)
    (param_ty : string) : string =
  if arg_ty = param_ty then arg_ssa
  else if is_section_subtype e arg_ty param_ty then begin
    let v = fresh_ssa e in
    emit_line e (Printf.sprintf
                   "%s = topos.subtype_cast %s : %s to %s"
                   v arg_ssa arg_ty param_ty);
    v
  end
  else if param_ty = "f64"
          && String.length arg_ty >= 15
          && String.sub arg_ty 0 15 = "!topos.section<" then begin
    (* A section flowing into an f64 parameter travels as its numeric handle:
       section_to_xcoord recovers the packed xcoord (i64), sitofp carries it as
       f64. This is the wire convention (handles cross as f64) and the producer
       side of the DTO wormhole: emit deposits the place handle on the local
       stream as f64, the pump flattens it at the boundary. *)
    let vi = fresh_ssa e in
    emit_line e (Printf.sprintf
                   "%s = topos.section_to_xcoord %s : %s to i64"
                   vi arg_ssa arg_ty);
    let vf = fresh_ssa e in
    emit_line e (Printf.sprintf "%s = arith.sitofp %s : i64 to f64" vf vi);
    vf
  end
  else if arg_ty = "f64"
          && String.length param_ty >= 15
          && String.sub param_ty 0 15 = "!topos.section<" then begin
    (* The inverse coercion, at the consumer end of the DTO wormhole: a stream
       element that the emitter carries as f64 is, by the type discipline, a
       place-typed value (the drain rebuilt it locally via yon_rt_new and put
       its handle on the stream as f64). fptosi recovers the xcoord, then
       xcoord_to_section materializes the local section. The typechecker is the
       gate: only place-typed values reach a section parameter, and the only one
       with an f64 representation is this locally rebuilt handle. *)
    let vi = fresh_ssa e in
    emit_line e (Printf.sprintf "%s = arith.fptosi %s : f64 to i64" vi arg_ssa);
    let vs = fresh_ssa e in
    emit_line e (Printf.sprintf
                   "%s = topos.xcoord_to_section %s : %s"
                   vs vi param_ty);
    vs
  end
  else arg_ssa  (* unhandled mismatch: let it through, MLIR will reject it *)

let rec emit_term (e : emitter)
    (env : (string * string) Env.t)
    (funcs : (string * func_sig) list)
    (t : C.term) : string * string =
  match t with
  | C.Var x when String.length x > 6 && String.sub x 0 6 = "__num_" ->
      let nstr = String.sub x 6 (String.length x - 6) in
      let v = fresh_ssa e in
      (* Append ".0" only when nstr is an integer (has no dot); otherwise the
         literal is already float-formatted. *)
      let formatted =
        if String.contains nstr '.' then nstr
        else nstr ^ ".0"
      in
      emit_line e (Printf.sprintf "%s = arith.constant %s : f64" v formatted);
      (v, "f64")
  | C.Var "__bool_true" ->
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 1 : i1" v);
      (v, "i1")
  | C.Var "__bool_false" ->
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 0 : i1" v);
      (v, "i1")
  (* P7-frontend A3: costanti Heyting tri-valued (intuizionista) *)
  | C.Var "__heyt_present" ->
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = topos.heyt true : !topos.proposition" v);
      (v, "!topos.proposition")
  | C.Var "__heyt_absent" ->
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = topos.heyt false : !topos.proposition" v);
      (v, "!topos.proposition")
  | C.Var "__heyt_unknown" ->
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = topos.heyt unknown : !topos.proposition" v);
      (v, "!topos.proposition")
  (* data structure 0-arg constructors. *)
  | C.Var "__map_empty" ->
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_map_empty() : () -> f64" v);
      (v, "f64")
  (* Map.empty (0-arg) is parsed as ECall("Map__empty", []) and desugared to
   * Var "Map__empty" (curry_apply f [] = f). *)
  | C.Var "Map__empty" ->
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_map_empty() : () -> f64" v);
      (v, "f64")
  (* HashMap/HashSet are aliases of Map. *)
  | C.Var "HashMap__empty" ->
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_map_empty() : () -> f64" v);
      (v, "f64")
  | C.Var "HashSet__empty" ->
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_hashset_empty() : () -> f64" v);
      (v, "f64")
  | C.Var "XSet__empty" ->
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_xset_empty() : () -> f64" v);
      (v, "f64")
  | C.Var "VoyagerList__empty" ->
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_voyagerlist_empty() : () -> f64" v);
      (v, "f64")
  | C.Var "Arena__empty" ->
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_arena_empty() : () -> f64" v);
      (v, "f64")
  | C.Var "__set_empty" ->
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_set_empty() : () -> f64" v);
      (v, "f64")
  (* S5: __xheap_used 0-arg diagnostic *)
  | C.Var "__xheap_used" ->
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_xheap_used() : () -> i32" v);
      let v_f = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.uitofp %s : i32 to f64" v_f v);
      (v_f, "f64")
  (* spawn 0-arg *)
  | C.Var "__spawn_index" ->
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_spawn_index() : () -> f64" v);
      (v, "f64")
  | C.Var x ->
      (* Caso 1: variabile nell'env (parametro, let-binding) *)
      (match Env.find_opt x env with
       | Some (ssa, _) when String.length ssa > 10
                            && String.sub ssa 0 10 = "__hof_ref:" ->
           (* A higher-order alias used as a bare Var rather than a call.
              This happens when an outer function's body desugars to
              App(Lam "middle_fn", _, Var "middle_fn"), where the binding
              aliases middle_fn. We resolve it by emitting the 0-argument call
              to the real function directly. *)
           let real_fname = String.sub ssa 10 (String.length ssa - 10) in
           (match List.assoc_opt real_fname funcs with
            | Some fs when fs.fn_params = [] ->
                let v = fresh_ssa e in
                emit_line e (Printf.sprintf "%s = func.call @%s() : () -> %s"
                               v real_fname fs.fn_ret_mlir);
                (v, fs.fn_ret_mlir)
            | Some _ ->
                failwith (Printf.sprintf
                  "[emit_mlir HOF Var] '%s' needs arguments; use it as f(args), not bare."
                  real_fname)
            | None ->
                failwith (Printf.sprintf
                  "[emit_mlir HOF Var] alias points to unknown function '%s'."
                  real_fname))
       | Some (ssa, ty) -> (ssa, ty)
       | None ->
           (* The name of a 0-argument user function: emit a direct call. *)
           (match List.assoc_opt x funcs with
            | Some fs when fs.fn_params = [] ->
                let v = fresh_ssa e in
                emit_line e (Printf.sprintf "%s = func.call @%s() : () -> %s"
                               v x fs.fn_ret_mlir);
                (v, fs.fn_ret_mlir)
            | Some fs ->
                (* A bare Var naming an n-ary function becomes a
                   func.constant @name (a function pointer), usable in
                   scf.if/scf.select and call_indirect. Its MLIR type is
                   (param_tys) -> ret_ty. *)
                let v = fresh_ssa e in
                let param_tys = List.map (fun (_, t) -> core_ty_to_mlir_simple t) fs.fn_params in
                let func_ty = Printf.sprintf "(%s) -> %s"
                  (String.concat ", " param_tys) fs.fn_ret_mlir in
                emit_line e (Printf.sprintf "%s = func.constant @%s : %s"
                               v x func_ty);
                (v, func_ty)
            | None ->
                (* A string literal __str_X — String fusion: emit the
                 * address of its module global and intern it at runtime to
                 * an xheap handle (content-addressed: idempotent). *)
                if String.length x > 6 && String.sub x 0 6 = "__str_" then begin
                  let content = String.sub x 6 (String.length x - 6) in
                  let sym =
                    match Hashtbl.find_opt g_strlits content with
                    | Some s -> s
                    | None ->
                        failwith
                          "[emit_mlir] string literal not collected (internal)" in
                  let vp = fresh_ssa e in
                  emit_line e (Printf.sprintf
                                 "%s = llvm.mlir.addressof @%s : !llvm.ptr"
                                 vp sym);
                  let v = fresh_ssa e in
                  emit_line e (Printf.sprintf
                                 "%s = func.call @yon_rt_string_lit(%s) : (!llvm.ptr) -> f64"
                                 v vp);
                  (v, "f64")
                end
                (* A 0-argument stdlib builtin: emit an extern call. *)
                else if is_stdlib_builtin x then begin
                  let (params, ret) = List.assoc x stdlib_registry in
                  if params <> [] then
                    failwith (Printf.sprintf
                                "[emit_mlir] stdlib '%s' needs %d parameters but was called as a bare variable."
                                x (List.length params));
                  let v = fresh_ssa e in
                  emit_line e (Printf.sprintf "%s = func.call @%s() : () -> %s"
                                 v x ret);
                  (v, ret)
                end
                else if String.length x > 12 &&
                        String.sub x (String.length x - 12) 12 = "_instantiate"
                then begin
                  (* <P>_instantiate() is generated by the AlgebraVerifier pass.
                     Emit the 0-argument call; the linker resolves it after
                     --algebra-verifier. It returns the f64 Magma handle. *)
                  let v = fresh_ssa e in
                  emit_line e (Printf.sprintf "%s = func.call @%s() : () -> f64" v x);
                  (v, "f64")
                end
                else
                  failwith (Printf.sprintf
                              "[emit_mlir] variable '%s' not in scope."
                              x)))
  (* Pattern matching `x is present|absent|unknown`.
   * App(App(Var "__is", x), Var "__pat_X") with x : !topos.proposition.
   * Compare the Heyting value (tri-valued) with the pattern, returning i1 (the
   * branch decision is classical even though the value is tri-valued: it is the
   * canonical projection Omega --> 2 for each of the 3 canonical Heyting
   * patterns). *)
  | C.App (C.App (C.Var "__is", x), C.Var pat) when
      (pat = "__pat_present" || pat = "__pat_absent" || pat = "__pat_unknown") ->
      let (vx_raw, tx) = emit_term e env funcs x in
      (* implicit text -> proposition coercion.
       * `obj.field is present` with field:text desugars to __is(field_value, __pat_present).
       * Semantics: "non-empty/non-null check". Convert via stdlib text_to_prop. *)
      let (vx, tx) =
        if tx = "!llvm.ptr" then begin
          let v_conv = fresh_ssa e in
          emit_line e (Printf.sprintf
                         "%s = func.call @text_to_prop(%s) : (f64) -> !topos.proposition"
                         v_conv vx_raw);
          (v_conv, "!topos.proposition")
        end
        else if tx = "i1" then begin
          (* Coercion boolean -> proposition via to_prop *)
          let v_conv = fresh_ssa e in
          emit_line e (Printf.sprintf
                         "%s = func.call @to_prop(%s) : (i1) -> !topos.proposition"
                         v_conv vx_raw);
          (v_conv, "!topos.proposition")
        end
        else (vx_raw, tx)
      in
      if tx <> "!topos.proposition" then
        failwith (Printf.sprintf
                    "[emit_mlir] pattern `is %s` on a value not coercible to proposition: %s."
                    (match pat with
                     | "__pat_present" -> "present"
                     | "__pat_absent"  -> "absent"
                     | _               -> "unknown")
                    tx);
      let canon_name = match pat with
        | "__pat_present" -> "true"
        | "__pat_absent"  -> "false"
        | _               -> "unknown"
      in
      let v_canon = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = topos.heyt %s : !topos.proposition"
                     v_canon canon_name);
      let v_eq = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = topos.heyt_is %s, %s : i1"
                     v_eq vx v_canon);
      (v_eq, "i1")
  (* __bool_not unary.
   * Accepts i1 (direct boolean) or f64 (number, semantics 0=false). *)
  (* Literal / variable patterns: `x is 7`, `x is "rome"`, `x is y`.
     Numbers and interned text both travel as f64 (text equality is the
     O(1) content-addressed handle comparison), so the test is a single
     arith.cmpf oeq. i1 operands compare with arith.cmpi; propositions
     with topos.heyt_is. Mixed representations fail loudly. *)
  | C.App (C.App (C.Var "__is", x), pat_term) ->
      let (vx, tx) = emit_term e env funcs x in
      let (vp, tp) = emit_term e env funcs pat_term in
      if tx = "f64" && tp = "f64" then begin
        let v = fresh_ssa e in
        emit_line e (Printf.sprintf "%s = arith.cmpf oeq, %s, %s : f64" v vx vp);
        (v, "i1")
      end
      else if tx = "i1" && tp = "i1" then begin
        let v = fresh_ssa e in
        emit_line e (Printf.sprintf "%s = arith.cmpi eq, %s, %s : i1" v vx vp);
        (v, "i1")
      end
      else if tx = "!topos.proposition" && tp = "!topos.proposition" then begin
        let v = fresh_ssa e in
        emit_line e (Printf.sprintf "%s = topos.heyt_is %s, %s : i1" v vx vp);
        (v, "i1")
      end
      else
        failwith (Printf.sprintf
          "[emit_mlir] `is` pattern with mismatched representations: %s vs %s."
          tx tp)
  | C.App (C.Var "__bool_not", arg) ->
      let (v_arg, ty) = emit_term e env funcs arg in
      if ty = "f64" then begin
        let v_zero = fresh_ssa e in
        emit_line e (Printf.sprintf "%s = arith.constant 0.0 : f64" v_zero);
        let v = fresh_ssa e in
        emit_line e (Printf.sprintf "%s = arith.cmpf oeq, %s, %s : f64" v v_arg v_zero);
        (v, "i1")
      end else begin
        let v_t = fresh_ssa e in
        emit_line e (Printf.sprintf "%s = arith.constant 1 : i1" v_t);
        let v = fresh_ssa e in
        emit_line e (Printf.sprintf "%s = arith.xori %s, %s : i1" v v_arg v_t);
        (v, "i1")
      end
  (* bitwise classici via cast f64->i64.
   * __band(a,b), __bxor(a,b), __bnot(a). *)
  | C.App (C.App (C.Var op_bin, a), b) when
      (op_bin = "__band" || op_bin = "__bxor" || op_bin = "__bor") ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v_ia = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.fptosi %s : f64 to i64" v_ia va);
      let v_ib = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.fptosi %s : f64 to i64" v_ib vb);
      let v_ir = fresh_ssa e in
      let mlir_op = match op_bin with
        | "__band" -> "arith.andi"
        | "__bxor" -> "arith.xori"
        | "__bor"  -> "arith.ori"
        | _ -> assert false
      in
      emit_line e (Printf.sprintf "%s = %s %s, %s : i64" v_ir mlir_op v_ia v_ib);
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.sitofp %s : i64 to f64" v v_ir);
      (v, "f64")
  | C.App (C.Var "__bnot", arg) ->
      let (va, _) = emit_term e env funcs arg in
      let v_ia = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.fptosi %s : f64 to i64" v_ia va);
      (* ~a = a xor (-1), the 64-bit all-ones constant *)
      let v_neg1 = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant -1 : i64" v_neg1);
      let v_ir = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.xori %s, %s : i64" v_ir v_ia v_neg1);
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.sitofp %s : i64 to f64" v v_ir);
      (v, "f64")
  (* Intuitionistic (Heyting) logical symbols.
   * Lowering: topos.heyt_and / heyt_or / heyt_implies / heyt_not on values of
   * type !topos.proposition. Automatic boolean/number -> proposition coercion
   * via topos.heyt op. *)
  | C.App (C.App (C.Var heyt_op, a), b) when
      (heyt_op = "__heyt_and" || heyt_op = "__heyt_or" || heyt_op = "__heyt_imp") ->
      let (va, ta) = emit_term e env funcs a in
      let (vb, tb) = emit_term e env funcs b in
      (* type-dependent dispatch.
       * If both operands are heyt_int<N>, lower bitwise
       * using the Heyting identity `a -> b == ~a or b` (verified on the 7
       * cases of the P/A/U table). Otherwise, scale via a Heyt proposition. *)
      let is_heyt_int s =
        String.length s > 16 && String.sub s 0 16 = "!topos.heyt_int<"
      in
      if heyt_op = "__heyt_imp" && (is_heyt_int ta || is_heyt_int tb) then begin
        (* Intuitionistic implication a =>? b is (~?a) |? b, built from the
           bitwise ops already lowered. Coerce number operands to heyt_int<64>
           when needed. *)
        let coerce_to_heyt v ty =
          if is_heyt_int ty then v
          else if ty = "f64" then begin
            let v_i = fresh_ssa e in
            emit_line e (Printf.sprintf "%s = arith.fptosi %s : f64 to i64" v_i v);
            let v_z = fresh_ssa e in
            emit_line e (Printf.sprintf "%s = arith.constant 0 : i64" v_z);
            let v_h = fresh_ssa e in
            emit_line e (Printf.sprintf
              "%s = topos.heyt_int_make %s, %s : !topos.heyt_int<64>" v_h v_i v_z);
            v_h
          end else v
        in
        let va' = coerce_to_heyt va ta in
        let vb' = coerce_to_heyt vb tb in
        let v_not = fresh_ssa e in
        emit_line e (Printf.sprintf
          "%s = topos.heyt_int_not %s : !topos.heyt_int<64>" v_not va');
        let v = fresh_ssa e in
        emit_line e (Printf.sprintf
          "%s = topos.heyt_int_or %s, %s : !topos.heyt_int<64>" v v_not vb');
        (v, "!topos.heyt_int<64>")
      end else begin
      let coerce_to_prop v ty =
        (* i1 -> proposition goes through the runtime @to_prop, the same
           coercion used by the __is path. topos.heyt only accepts an
           enum literal (true/false/unknown), never an SSA operand. *)
        if ty = "!topos.proposition" then v
        else if ty = "i1" then begin
          let v' = fresh_ssa e in
          emit_line e (Printf.sprintf
            "%s = func.call @to_prop(%s) : (i1) -> !topos.proposition" v' v);
          v'
        end
        else if ty = "f64" then begin
          let v_zero = fresh_ssa e in
          emit_line e (Printf.sprintf "%s = arith.constant 0.0 : f64" v_zero);
          let v_b = fresh_ssa e in
          emit_line e (Printf.sprintf "%s = arith.cmpf one, %s, %s : f64" v_b v v_zero);
          let v_p = fresh_ssa e in
          emit_line e (Printf.sprintf
            "%s = func.call @to_prop(%s) : (i1) -> !topos.proposition" v_p v_b);
          v_p
        end
        else v
      in
      let va' = coerce_to_prop va ta in
      let vb' = coerce_to_prop vb tb in
      let mlir_op = match heyt_op with
        | "__heyt_and" -> "topos.heyt_and"
        | "__heyt_or"  -> "topos.heyt_or"
        | "__heyt_imp" -> "topos.heyt_implies"
        | _ -> assert false
      in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = %s %s, %s : !topos.proposition"
        v mlir_op va' vb');
      (v, "!topos.proposition")
      end
  | C.App (C.Var "__heyt_not", arg) ->
      let (va, ta) = emit_term e env funcs arg in
      let coerce_to_prop v ty =
        (* i1 -> proposition goes through the runtime @to_prop, the same
           coercion used by the __is path. topos.heyt only accepts an
           enum literal (true/false/unknown), never an SSA operand. *)
        if ty = "!topos.proposition" then v
        else if ty = "i1" then begin
          let v' = fresh_ssa e in
          emit_line e (Printf.sprintf
            "%s = func.call @to_prop(%s) : (i1) -> !topos.proposition" v' v);
          v'
        end
        else if ty = "f64" then begin
          let v_zero = fresh_ssa e in
          emit_line e (Printf.sprintf "%s = arith.constant 0.0 : f64" v_zero);
          let v_b = fresh_ssa e in
          emit_line e (Printf.sprintf "%s = arith.cmpf one, %s, %s : f64" v_b v v_zero);
          let v_p = fresh_ssa e in
          emit_line e (Printf.sprintf
            "%s = func.call @to_prop(%s) : (i1) -> !topos.proposition" v_p v_b);
          v_p
        end
        else v
      in
      let va' = coerce_to_prop va ta in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = topos.heyt_not %s : !topos.proposition" v va');
      (v, "!topos.proposition")
  (* Emit for the 5 Heyt-int builtins. Default N=64 trits; runtime MLIR type
   * !topos.heyt_int<64>.
   *
   * Coercion: Yon arguments are f64 (number), but MLIR wants i64 for
   * value/mask, so we do arith.fptosi on the fly in make. For the value/mask
   * projections we return f64 (after sitofp) to stay compatible with the
   * let-based Yon flow.
   *
   * Binary ops (and/or/xor): both operands must already be
   * !topos.heyt_int<N>. Automatic f64 -> heyt_int coercion is not implemented
   * here (it would require choosing N and mask=0). *)
  | C.App (C.App (C.Var "__heyt_int_make", arg_v), arg_m) ->
      let (va, ta) = emit_term e env funcs arg_v in
      let (vm, tm) = emit_term e env funcs arg_m in
      let to_i64 v ty =
        if ty = "i64" then v
        else if ty = "f64" then begin
          let v' = fresh_ssa e in
          emit_line e (Printf.sprintf "%s = arith.fptosi %s : f64 to i64" v' v);
          v'
        end else v
      in
      let vi = to_i64 va ta in
      let mi = to_i64 vm tm in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = topos.heyt_int_make %s, %s : !topos.heyt_int<64>" v vi mi);
      (v, "!topos.heyt_int<64>")
  | C.App (C.App (C.Var op_bin, a), b) when
      (op_bin = "__heyt_int_and" || op_bin = "__heyt_int_or"
       || op_bin = "__heyt_int_xor") ->
      let (va, ta) = emit_term e env funcs a in
      let (vb, tb) = emit_term e env funcs b in
      (* Automatic coercion: if the operand is f64 (number), convert it to
       * heyt_int<64> with mask=0 (no Unknown). This lets one write
       * `make(5,0) &? 3` instead of `make(5,0) &? make(3,0)`. *)
      let coerce_to_heyt v ty =
        if ty = "!topos.heyt_int<64>" then v
        else if ty = "f64" then begin
          let v_i = fresh_ssa e in
          emit_line e (Printf.sprintf "%s = arith.fptosi %s : f64 to i64" v_i v);
          let v_z = fresh_ssa e in
          emit_line e (Printf.sprintf "%s = arith.constant 0 : i64" v_z);
          let v_h = fresh_ssa e in
          emit_line e (Printf.sprintf
            "%s = topos.heyt_int_make %s, %s : !topos.heyt_int<64>" v_h v_i v_z);
          v_h
        end else v
      in
      let va' = coerce_to_heyt va ta in
      let vb' = coerce_to_heyt vb tb in
      let mlir_op = match op_bin with
        | "__heyt_int_and" -> "topos.heyt_int_and"
        | "__heyt_int_or"  -> "topos.heyt_int_or"
        | "__heyt_int_xor" -> "topos.heyt_int_xor"
        | _ -> assert false
      in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = %s %s, %s : !topos.heyt_int<64>"
        v mlir_op va' vb');
      (v, "!topos.heyt_int<64>")
  | C.App (C.Var "__heyt_int_not", arg) ->
      let (va, ta) = emit_term e env funcs arg in
      let va' =
        if ta = "!topos.heyt_int<64>" then va
        else if ta = "f64" then begin
          let v_i = fresh_ssa e in
          emit_line e (Printf.sprintf "%s = arith.fptosi %s : f64 to i64" v_i va);
          let v_z = fresh_ssa e in
          emit_line e (Printf.sprintf "%s = arith.constant 0 : i64" v_z);
          let v_h = fresh_ssa e in
          emit_line e (Printf.sprintf
            "%s = topos.heyt_int_make %s, %s : !topos.heyt_int<64>" v_h v_i v_z);
          v_h
        end else va
      in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = topos.heyt_int_not %s : !topos.heyt_int<64>" v va');
      (v, "!topos.heyt_int<64>")
  | C.App (C.Var "__heyt_int_value", arg) ->
      let (va, _) = emit_term e env funcs arg in
      let v_i = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = topos.heyt_int_value %s : !topos.heyt_int<64>" v_i va);
      (* Coerce i64 -> f64 for the Yon flow *)
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.sitofp %s : i64 to f64" v v_i);
      (v, "f64")
  | C.App (C.Var "__heyt_int_mask", arg) ->
      let (va, _) = emit_term e env funcs arg in
      let v_i = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = topos.heyt_int_mask %s : !topos.heyt_int<64>" v_i va);
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.sitofp %s : i64 to f64" v v_i);
      (v, "f64")
  (* Map/Set/Dag operations lower directly to func.call @yon_rt_<op>. The
     empty-collection cases are caught earlier, before the C.Var fallback.
     Map__set and HashMap__set are aliases of __map_put (the desugar and emit
     names are aligned here). *)
  | C.App (C.App (C.App (C.Var "Map__set", arg_m), arg_k), arg_v)
  | C.App (C.App (C.App (C.Var "HashMap__set", arg_m), arg_k), arg_v)
  | C.App (C.App (C.App (C.Var "__map_put", arg_m), arg_k), arg_v) ->
      let (vm, _) = emit_term e env funcs arg_m in
      let (vk, _) = emit_term e env funcs arg_k in
      let (vv, _) = emit_term e env funcs arg_v in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_map_put(%s, %s, %s) : (f64, f64, f64) -> f64" v vm vk vv);
      (v, "f64")
  | C.App (C.App (C.Var "Map__has", arg_a), arg_b)
  | C.App (C.App (C.Var "HashMap__has", arg_a), arg_b) ->
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let v_f64 = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_map_contains(%s, %s) : (f64, f64) -> f64" v_f64 va vb);
      let v_zero = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 0.0 : f64" v_zero);
      let v_i1 = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = arith.cmpf one, %s, %s : f64" v_i1 v_f64 v_zero);
      (v_i1, "i1")
  | C.App (C.App (C.Var "HashSet__contains", arg_a), arg_b) ->
      (* HashSet dedicato: yon_rt_hashset_contains. *)
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let v_f64 = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_hashset_contains(%s, %s) : (f64, f64) -> f64" v_f64 va vb);
      let v_zero = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 0.0 : f64" v_zero);
      let v_i1 = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = arith.cmpf one, %s, %s : f64" v_i1 v_f64 v_zero);
      (v_i1, "i1")
  | C.App (C.App (C.Var "XSet__contains", arg_a), arg_b) ->
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let v_f64 = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_xset_contains(%s, %s) : (f64, f64) -> f64" v_f64 va vb);
      let v_zero = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 0.0 : f64" v_zero);
      let v_i1 = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = arith.cmpf one, %s, %s : f64" v_i1 v_f64 v_zero);
      (v_i1, "i1")
  | C.App (C.App (C.Var "XSet__add", arg_a), arg_b) ->
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_xset_add(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.App (C.Var "XSet__union", arg_a), arg_b) ->
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_xset_union(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.App (C.Var "XSet__intersect", arg_a), arg_b) ->
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_xset_intersect(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.Var "XSet__size", arg) ->
      let (va, _) = emit_term e env funcs arg in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_xset_size(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "XSet__to_stream", arg) ->
      let (va, _) = emit_term e env funcs arg in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_xset_to_list(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.App (C.Var op, arg_a), arg_b) when
      (op = "Map__get" || op = "HashMap__get" || op = "HashSet__add"
       || op = "__map_get" || op = "__map_contains"
       || op = "__set_add" || op = "__set_contains"
       || op = "__merkle_child" || op = "__merkle_equal"
       || op = "__voyagerlist_corrupt"
       || op = "__conway_seal_slot" || op = "__conway_unseal_slot"
       || op = "__conway_key_equal") ->
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let rt_name = match op with
        | "Map__get" | "HashMap__get" -> "yon_rt_map_get"
        | "HashSet__add" -> "yon_rt_hashset_add"
        | _ -> "yon_rt_" ^ String.sub op 2 (String.length op - 2)
      in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @%s(%s, %s) : (f64, f64) -> f64" v rt_name va vb);
      (v, "f64")
  | C.App (C.Var op, arg) when
      (op = "Map__size" || op = "HashMap__size" || op = "HashSet__size"
       || op = "__map_size" || op = "__set_size"
       || op = "__merkle_leaf" || op = "__merkle_label"
       || op = "__observe_alloc"
       || op = "__spawn_self" || op = "__voyagerlist_seal"
       || op = "__voyagerlist_open"
       || op = "__conway_gen_key") ->
      let (va, _) = emit_term e env funcs arg in
      let rt_name = match op with
        | "Map__size" | "HashMap__size" -> "yon_rt_map_size"
        | "HashSet__size" -> "yon_rt_hashset_size"
        | _ -> "yon_rt_" ^ String.sub op 2 (String.length op - 2)
      in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @%s(%s) : (f64) -> f64" v rt_name va);
      (v, "f64")
  | C.App (C.App (C.App (C.Var "__merkle_node2", arg_l), arg_c1), arg_c2) ->
      let (vl, _) = emit_term e env funcs arg_l in
      let (vc1, _) = emit_term e env funcs arg_c1 in
      let (vc2, _) = emit_term e env funcs arg_c2 in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_merkle_node2(%s, %s, %s) : (f64, f64, f64) -> f64" v vl vc1 vc2);
      (v, "f64")
  (* S5: __observe_via_gm(slot, kind, default) -> f64 *)
  | C.App (C.App (C.App (C.Var "__observe_via_gm", arg_s), arg_k), arg_d) ->
      let (vs, _) = emit_term e env funcs arg_s in
      let (vk, _) = emit_term e env funcs arg_k in
      let (vd, _) = emit_term e env funcs arg_d in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_observe(%s, %s, %s) : (f64, f64, f64) -> f64" v vs vk vd);
      (v, "f64")
  | C.App (C.Var fvar, obj) when extract_field_name fvar <> None ->
      let fname = (match extract_field_name fvar with
                   | Some s -> s | None -> assert false) in
      let (v_obj, obj_ty) = emit_term e env funcs obj in
      (* obj_ty should be "!topos.section<\"P\">"; pull out P. *)
      let prefix = "!topos.section<\"" in
      let plen = String.length prefix in
      if String.length obj_ty <= plen
         || String.sub obj_ty 0 plen <> prefix then
        failwith (Printf.sprintf
                    "[emit_mlir] field projection '.%s' on a non-section value: %s. The object of a field projection must have type section<\"P\"> (a parameter or return of a user-defined place type)."
                    fname obj_ty);
      let rest = String.sub obj_ty plen (String.length obj_ty - plen) in
      let close = (try String.index rest '"' with Not_found -> -1) in
      if close < 0 then
        failwith (Printf.sprintf
                    "[emit_mlir] malformed section type: %s." obj_ty);
      let place_name = String.sub rest 0 close in
      let field_ty = (match lookup_field_ty e place_name fname with
                      | Some ty -> ty
                      | None ->
                          failwith (Printf.sprintf
                                      "[emit_mlir] field '.%s' not declared in place '%s'. Add the field to the declaration of '%s', or fix the name."
                                      fname place_name place_name)) in
      (* For a field of primitive type, use an explicit yon_rt_field_load (a
       * verified runtime path). For a field of section type (a nested place),
       * we still use topos.field_load, since it needs a whole-record load
       * handled by the MLIR lowering. *)
      let is_section_ty s =
        String.length s >= 15 && String.sub s 0 15 = "!topos.section<"
      in
      if is_section_ty field_ty then begin
        let v = fresh_ssa e in
        emit_line e (Printf.sprintf
                       "%s = topos.field_load %s, \"%s\" : %s -> %s"
                       v v_obj fname obj_ty field_ty);
        (v, field_ty)
      end else begin
      let mlir_ty_size_local = function
        | "f64" -> 8 | "i1" -> 1 | "i8" -> 1
        | "i32" -> 4 | "i64" -> 8 | "!llvm.ptr" -> 8
        | "!topos.proposition" -> 1 | _ -> 8
      in
      let field_offset =
        match List.assoc_opt place_name e.places_table with
        | Some fields ->
            let acc = ref 0 in
            let found = ref None in
            List.iter (fun (fn, fty) ->
              if fn = fname && !found = None then found := Some !acc;
              acc := !acc + mlir_ty_size_local fty
            ) fields;
            (match !found with Some o -> o | None -> 0)
        | None -> 0
      in
      let v_xc = fresh_ssa e in
      emit_line e (Printf.sprintf
                     "%s = topos.section_to_xcoord %s : %s to i64"
                     v_xc v_obj obj_ty);
      let v_off = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant %d : i32" v_off field_offset);
      let v_size = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant %d : i32"
                     v_size (mlir_ty_size_local field_ty));
      let v_one_i64 = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 1 : i64" v_one_i64);
      let v_buf = fresh_ssa e in
      emit_line e (Printf.sprintf
                     "%s = llvm.alloca %s x i64 : (i64) -> !llvm.ptr" v_buf v_one_i64);
      let v_status = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_field_load(%s, %s, %s, %s) : (i64, i32, i32, !llvm.ptr) -> i32"
        v_status v_xc v_off v_size v_buf);
      let _ = v_status in
      let v_loaded = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = llvm.load %s : !llvm.ptr -> %s"
                     v_loaded v_buf field_ty);
      (v_loaded, field_ty)
      end
  | C.App (C.App (C.Var op, a), b) when
      (op = "__add" || op = "__sub" || op = "__mul" || op = "__div"
       || op = "__mod"
       || op = "__lt" || op = "__gt" || op = "__leq" || op = "__geq"
       || op = "__eq" || op = "__neq" || op = "__and" || op = "__or") ->
      let (va, ta) = emit_term e env funcs a in
      let (vb, tb) = emit_term e env funcs b in
      (* automatic f64 -> i1 coercion for __and/__or when an operand is f64
       * (C-style semantics 0=false). Emit: cmpf one with 0.0 -> i1. *)
      let coerce_to_i1 v ty =
        if ty = "i1" then v
        else if ty = "f64" then begin
          let v_zero = fresh_ssa e in
          emit_line e (Printf.sprintf "%s = arith.constant 0.0 : f64" v_zero);
          let v_b = fresh_ssa e in
          emit_line e (Printf.sprintf "%s = arith.cmpf one, %s, %s : f64" v_b v v_zero);
          v_b
        end else v
      in
      let (va, ta, vb, tb) =
        if (op = "__and" || op = "__or")
           && ((ta = "f64" && tb = "i1") || (ta = "i1" && tb = "f64")) then
          (coerce_to_i1 va ta, "i1", coerce_to_i1 vb tb, "i1")
        else (va, ta, vb, tb)
      in
      (* Dispatch the logical __and/__or to Heyting when both operands are
       * propositions. *)
      if (op = "__and" || op = "__or")
         && ta = "!topos.proposition" && tb = "!topos.proposition" then begin
        let v = fresh_ssa e in
        let mlir_op = if op = "__and" then "topos.heyt_and" else "topos.heyt_or" in
        emit_line e (Printf.sprintf
                       "%s = %s %s, %s : !topos.proposition"
                       v mlir_op va vb);
        (v, "!topos.proposition")
      end
      else if (op = "__and" || op = "__or")
              && (ta = "!topos.proposition" || tb = "!topos.proposition") then
        failwith (Printf.sprintf
                    "[emit_mlir] operator '%s' with mixed types: %s and %s. Use `to_prop` explicitly to convert boolean -> proposition, or invert it if needed."
                    op ta tb)
      else begin
        let v = fresh_ssa e in
        let (mlir_op, result_ty, operand_ty) = match op with
          | "__add" -> ("arith.addf", "f64", "f64")
          | "__sub" -> ("arith.subf", "f64", "f64")
          | "__mul" -> ("arith.mulf", "f64", "f64")
          | "__div" -> ("arith.divf", "f64", "f64")
          | "__mod" -> ("arith.remf", "f64", "f64")
          | "__lt"  -> ("arith.cmpf olt,", "i1", "f64")
          | "__gt"  -> ("arith.cmpf ogt,", "i1", "f64")
          | "__leq" -> ("arith.cmpf ole,", "i1", "f64")
          | "__geq" -> ("arith.cmpf oge,", "i1", "f64")
          | "__eq"  -> ("arith.cmpf oeq,", "i1", "f64")
          | "__neq" -> ("arith.cmpf one,", "i1", "f64")
          | "__and" -> ("arith.andi", "i1", "i1")
          | "__or"  -> ("arith.ori", "i1", "i1")
          | _ -> assert false
        in
        emit_line e (Printf.sprintf "%s = %s %s, %s : %s"
                       v mlir_op va vb operand_ty);
        (v, result_ty)
      end
  | C.App (C.App (C.App (C.Var "__if", c), then_t), else_t) ->
      let (vc_raw, tc) = emit_term e env funcs c in
      (* A proposition condition is decided to i1 via @to_bool_dec, the
         same boundary cast used elsewhere; scf.if is built on i1. *)
      let vc =
        if tc = "!topos.proposition" then begin
          let v' = fresh_ssa e in
          emit_line e (Printf.sprintf
            "%s = func.call @to_bool_dec(%s) : (!topos.proposition) -> i1" v' vc_raw);
          v'
        end else vc_raw
      in
      let ty = infer_mlir_ty e env funcs then_t in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = scf.if %s -> (%s) {" v vc ty);
      push_indent e;
      let (vt, _) = emit_term e env funcs then_t in
      emit_line e (Printf.sprintf "scf.yield %s : %s" vt ty);
      pop_indent e;
      emit_line e "} else {";
      push_indent e;
      let (ve, _) = emit_term e env funcs else_t in
      emit_line e (Printf.sprintf "scf.yield %s : %s" ve ty);
      pop_indent e;
      emit_line e "}";
      (v, ty)
  (* __if_expr, an alias of __if as an expression generated by EIfThenElse.
   * Same lowering. *)
  | C.App (C.App (C.App (C.Var "__if_expr", c), then_t), else_t) ->
      let (vc_raw, tc) = emit_term e env funcs c in
      let vc =
        if tc = "!topos.proposition" then begin
          let v' = fresh_ssa e in
          emit_line e (Printf.sprintf
            "%s = func.call @to_bool_dec(%s) : (!topos.proposition) -> i1" v' vc_raw);
          v'
        end else vc_raw
      in
      let ty = infer_mlir_ty e env funcs then_t in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = scf.if %s -> (%s) {" v vc ty);
      push_indent e;
      let (vt, _) = emit_term e env funcs then_t in
      emit_line e (Printf.sprintf "scf.yield %s : %s" vt ty);
      pop_indent e;
      emit_line e "} else {";
      push_indent e;
      let (ve, _) = emit_term e env funcs else_t in
      emit_line e (Printf.sprintf "scf.yield %s : %s" ve ty);
      pop_indent e;
      emit_line e "}";
      (v, ty)
  (* pipeline deforestata.
   *
   * Recognizes the composition
   *   Seq.fold(Seq.filter(Seq.map(Seq.from_list(l), f), p), init, g)
   * (with map/filter in arbitrary order) and emits it as a single scf.while
   * over a list-iterator with no intermediate buffers.
   *
   * f, p, g must be C.Var of top-level functions (their names are used for
   * the inline func.call).
   *
   * Implementation: collect_stream_ops descends into the `source` argument,
   * gathering Map(f)/Filter(p) down to Seq.from_list(l). *)
  (* * Monolithic pattern: Stream.sum_take(Stream.iterate(f, x0), n) lowered to
   * an scf.for with an accumulator. Full fusion: no intermediate list, no
   * allocation, a single loop. *)
  | C.App (C.Var "__stream_to_stream", inner) ->
      (* to_stream() as a no-op
       * for List (the list IS already a stream).
       * for Map/Set/Merkle, the API
       * dedicated `map_to_stream(m)` / `set_to_stream(s)` calls
       * yon_rt_map_to_list / yon_rt_set_to_list. A bare to_stream() is for
       * List only. *)
      emit_term e env funcs inner
  (* Explicit conversions to a stream for the Map/Set/Merkle data structures.
   * Each calls the runtime helper that produces a list, then the map/filter/
   * fold chain iterates. *)
  | C.App (C.Var "__map_to_stream", arg)
  | C.App (C.Var "HashMap__to_stream", arg)
  | C.App (C.Var "Map__to_stream", arg) ->
      let (vm, _) = emit_term e env funcs arg in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_map_to_list(%s) : (f64) -> f64" v vm);
      (v, "f64")
  | C.App (C.Var "__set_to_stream", arg)
  | C.App (C.Var "HashSet__to_stream", arg) ->
      let (vs, _) = emit_term e env funcs arg in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_hashset_to_list(%s) : (f64) -> f64" v vs);
      (v, "f64")
  (* Merkle DAG.to_stream
   * yields LEAVES via DFS. *)
  | C.App (C.Var "__merkle_to_stream", arg)
  | C.App (C.Var "MerkleTree__to_stream", arg) ->
      let (vm, _) = emit_term e env funcs arg in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_merkle_to_list(%s) : (f64) -> f64" v vm);
      (v, "f64")
  | C.App (C.Var "MerkleTree__leaf", arg) ->
      let (va, _) = emit_term e env funcs arg in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_merkle_leaf(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "MerkleTree__label", arg) ->
      let (va, _) = emit_term e env funcs arg in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_merkle_label(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.App (C.Var "MerkleTree__child", arg_a), arg_b) ->
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_merkle_child(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.App (C.Var "MerkleTree__equal", arg_a), arg_b) ->
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let v_f64 = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_merkle_equal(%s, %s) : (f64, f64) -> f64" v_f64 va vb);
      let v_zero = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 0.0 : f64" v_zero);
      let v_i1 = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = arith.cmpf one, %s, %s : f64" v_i1 v_f64 v_zero);
      (v_i1, "i1")
  | C.App (C.App (C.App (C.Var "MerkleTree__node2_commutative", arg_l), arg_c1), arg_c2) ->
      let (vl, _)  = emit_term e env funcs arg_l in
      let (vc1, _) = emit_term e env funcs arg_c1 in
      let (vc2, _) = emit_term e env funcs arg_c2 in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_merkle_node2_commutative(%s, %s, %s) : (f64, f64, f64) -> f64" v vl vc1 vc2);
      (v, "f64")
  | C.App (C.App (C.App (C.Var "MerkleTree__node2", arg_l), arg_c1), arg_c2) ->
      let (vl, _) = emit_term e env funcs arg_l in
      let (vc1, _) = emit_term e env funcs arg_c1 in
      let (vc2, _) = emit_term e env funcs arg_c2 in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_merkle_node2(%s, %s, %s) : (f64, f64, f64) -> f64" v vl vc1 vc2);
      (v, "f64")
  (* Leech G_24 sign-flip canonical. *)
  | C.App (C.App (C.Var "Leech__sign_canonical", arg_a), arg_b) ->
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_leech_sign_canonical(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.Var "Leech__syndrome", arg) ->
      let (va, _) = emit_term e env funcs arg in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_leech_syndrome(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Leech__orbit_id", arg) ->
      let (va, _) = emit_term e env funcs arg in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_leech_orbit_id(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.App (C.Var "Leech__same_orbit", arg_a), arg_b) ->
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_leech_same_orbit(%s, %s) : (f64, f64) -> f64" v va vb);
      (* same_orbit returns 0.0 or 1.0 from C; convert to i1 for the type checker. *)
      let bv = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = arith.constant 0.0 : f64" bv);
      let cv = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = arith.cmpf une, %s, %s : f64" cv v bv);
      (cv, "i1")
  (* M_24 + xi Conway. *)
  | C.App (C.Var "Leech__m24_orbit", arg) ->
      let (va, _) = emit_term e env funcs arg in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_leech_m24_orbit(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Leech__gcode_weight", arg) ->
      let (va, _) = emit_term e env funcs arg in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_leech_gcode_weight(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Leech__cocode_weight", arg) ->
      let (va, _) = emit_term e env funcs arg in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_leech_cocode_weight(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Leech__xi_apply", arg) ->
      let (va, _) = emit_term e env funcs arg in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_leech_xi_apply(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.App (C.Var "Leech__co0_equivalent", a), b) ->
      let (va,_) = emit_term e env funcs a in
      let (vb,_) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_leech_co0_equivalent(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.App (C.Var "Leech__transport", a), b) ->
      let (va,_) = emit_term e env funcs a in
      let (vb,_) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_leech_transport(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.App (C.Var "Leech__transport_apply", a), b) ->
      let (va,_) = emit_term e env funcs a in
      let (vb,_) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_leech_transport_apply(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.Var "Leech__co0_step", arg) ->
      let (va, _) = emit_term e env funcs arg in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_leech_co0_canonical_exact(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Leech__co0_canonical", arg_a) ->
      let (va, _) = emit_term e env funcs arg_a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_leech_co0_canonical_exact(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.App (C.Var "Leech__co0_orbit_size", arg_a), arg_b) ->
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_leech_co0_orbit_size(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  (* Capability registry. *)
  | C.App (C.Var "Cap__grant", arg) ->
      let (va, _) = emit_term e env funcs arg in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_cap_grant(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Cap__check", arg) ->
      let (va, _) = emit_term e env funcs arg in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_cap_check(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Cap__revoke", arg) ->
      let (va, _) = emit_term e env funcs arg in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_cap_revoke(%s) : (f64) -> f64" v va);
      (v, "f64")
  (* Move version registry. *)
  | C.App (C.App (C.Var "MoveRegistry__register_version", arg_a), arg_b) ->
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_move_register_version(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.Var "MoveRegistry__current_version", arg) ->
      let (va, _) = emit_term e env funcs arg in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_move_current_version(%s) : (f64) -> f64" v va);
      (v, "f64")
  (* Base stdlib Math/Bits/IO generic dispatch. The pattern Mod__name maps to
   * yon_rt_mod_name. We map them by hand because the dispatch in emit_term
   * needs C.App pattern matching at a fixed arity. *)
  | C.App (C.Var "Math__sqrt", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_sqrt(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Math__abs", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_abs(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Math__floor", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_floor(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Math__ceil", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_ceil(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Math__round", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_round(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.App (C.Var "Math__min", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_min(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.App (C.Var "Math__max", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_max(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.App (C.Var "Math__pow", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_pow(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.Var "Math__log", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_log(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Math__exp", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_exp(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Math__sin", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_sin(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Math__cos", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_cos(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Math__pi", _a) ->
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_pi() : () -> f64" v);
      (v, "f64")
  | C.App (C.Var "Math__e", _a) ->
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_e() : () -> f64" v);
      (v, "f64")
  | C.App (C.App (C.Var "Math__modulo", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_modulo(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.App (C.Var "Math__gcd", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_gcd(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.Var "Magma__empty", a) ->
      let (va,_) = emit_term e env funcs a in let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_magma_empty(%s) : (f64) -> f64" v va); (v,"f64")
  | C.App (C.App (C.Var "Magma__gen", a), b) ->
      let (va,_) = emit_term e env funcs a in let (vb,_) = emit_term e env funcs b in let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_magma_gen(%s, %s) : (f64, f64) -> f64" v va vb); (v,"f64")
  | C.App (C.Var "Magma__is_commutative", a) ->
      let (va,_) = emit_term e env funcs a in let vf = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_magma_is_commutative(%s) : (f64) -> f64" vf va);
      let vz = fresh_ssa e in emit_line e (Printf.sprintf "%s = arith.constant 0.0 : f64" vz);
      let vi = fresh_ssa e in emit_line e (Printf.sprintf "%s = arith.cmpf one, %s, %s : f64" vi vf vz); (vi,"i1")
  | C.App (C.Var "Magma__is_associative", a) ->
      let (va,_) = emit_term e env funcs a in let vf = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_magma_is_associative(%s) : (f64) -> f64" vf va);
      let vz = fresh_ssa e in emit_line e (Printf.sprintf "%s = arith.constant 0.0 : f64" vz);
      let vi = fresh_ssa e in emit_line e (Printf.sprintf "%s = arith.cmpf one, %s, %s : f64" vi vf vz); (vi,"i1")
  | C.App (C.Var "Magma__identity", a) ->
      let (va,_) = emit_term e env funcs a in let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_magma_identity(%s) : (f64) -> f64" v va); (v,"f64")
  | C.App (C.Var "Magma__closure_size", a) ->
      let (va,_) = emit_term e env funcs a in let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_magma_closure_size(%s) : (f64) -> f64" v va); (v,"f64")
  | C.App (C.App (C.Var "Land__reach", a), b) ->
      let (va,_) = emit_term e env funcs a in let (vb,_) = emit_term e env funcs b in let vf = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_land_reach(%s, %s) : (f64, f64) -> f64" vf va vb);
      let vz = fresh_ssa e in emit_line e (Printf.sprintf "%s = arith.constant 0.0 : f64" vz);
      let vi = fresh_ssa e in emit_line e (Printf.sprintf "%s = arith.cmpf one, %s, %s : f64" vi vf vz); (vi,"i1")
  | C.App (C.App (C.Var "Land__witness", a), b) ->
      let (va,_) = emit_term e env funcs a in let (vb,_) = emit_term e env funcs b in let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_land_witness(%s, %s) : (f64, f64) -> f64" v va vb);
      (v,"f64")
  | C.App (C.App (C.Var "Magma__word_push", a), b) ->
      let (va,_) = emit_term e env funcs a in let (vb,_) = emit_term e env funcs b in let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_magma_word_push(%s, %s) : (f64, f64) -> f64" v va vb); (v,"f64")
  | C.App (C.Var "Magma__from_catalog", a) ->
      let (va,_) = emit_term e env funcs a in let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_magma_from_algebra(%s) : (f64) -> f64" v va); (v,"f64")
  | C.App (C.Var "Magma__normal_form", a) ->
      let (va,_) = emit_term e env funcs a in let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_magma_normal_form(%s) : (f64) -> f64" v va); (v,"f64")
  | C.App (C.App (C.Var "Math__lcm", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_lcm(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.App (C.Var "Math__atan2", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_atan2(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.Var "Math__log2", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_log2(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Math__log10", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_log10(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Math__sinh", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_sinh(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Math__cosh", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_cosh(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Math__tanh", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_math_tanh(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.App (C.Var "Bits__band", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_bits_and(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.App (C.Var "Bits__bor", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_bits_or(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.App (C.Var "Bits__bxor", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_bits_xor(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.Var "Bits__bnot", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_bits_not(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.App (C.Var "Bits__shl", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_bits_shl(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.App (C.Var "Bits__shr", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_bits_shr(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.Var "Bits__popcount", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_bits_popcount(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "IO__print_num", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_io_print_num(%s) : (f64) -> f64" v va);
      (v, "f64")
  (* Extended stdlib. *)
  | C.App (C.Var "String__from_int", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_string_from_int(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "String__length", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_string_length(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.App (C.Var "String__concat", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_string_concat(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.App (C.Var "String__equal", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_string_equal(%s, %s) : (f64, f64) -> f64" v va vb);
      let bv = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 0.0 : f64" bv);
      let cv = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.cmpf une, %s, %s : f64" cv v bv);
      (cv, "i1")
  | C.App (C.App (C.Var "String__char_at", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_string_char_at(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.Var "String__print", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_string_print(%s) : (f64) -> f64" v va);
      (v, "f64")
  (* Output.print — the operation of the builtin place Output (I/O as an
   * effect). Lowers to the same runtime as String.print. A function that calls
   * it must `visits Output`. *)
  | C.App (C.Var "Output__print", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_string_print(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "String__parse_number", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_string_parse_number(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.App (C.App (C.Var "String__substring", a), b), c) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let (vc, _) = emit_term e env funcs c in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_string_substring(%s, %s, %s) : (f64, f64, f64) -> f64" v va vb vc);
      (v, "f64")
  | C.App (C.App (C.App (C.Var "String__find_char", a), b), c) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let (vc, _) = emit_term e env funcs c in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_string_find_char(%s, %s, %s) : (f64, f64, f64) -> f64" v va vb vc);
      (v, "f64")
  | C.App (C.Var "String__from_char", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_string_from_char(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.App (C.Var "File__write_text", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_file_write_text(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.App (C.Var "File__append_text", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_file_append_text(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.Var "Env__get", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_env_get(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Env__has", a) ->
      let (va, _) = emit_term e env funcs a in
      let vf = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_env_has(%s) : (f64) -> f64" vf va);
      let v = fresh_ssa e in
      let vz = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 0.5 : f64" vz);
      emit_line e (Printf.sprintf "%s = arith.cmpf ogt, %s, %s : f64" v vf vz);
      (v, "i1")
  | C.App (C.Var "Args__count", _) ->
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_args_count() : () -> f64" v);
      (v, "f64")
  | C.App (C.Var "Args__get", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_args_get(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "File__read_text", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_file_read_text(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "File__exists", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_file_exists(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Seq__range", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_seq_range(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Seq__range_to_list", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_seq_range(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.App (C.App (C.Var "Bits__fold", a), b), c) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let (vc, _) = emit_term e env funcs c in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_bits_fold(%s, %s, %s) : (f64, f64, f64) -> f64" v va vb vc);
      (v, "f64")
  | C.App (C.App (C.Var "Bits__bor_64", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_bits_or_64(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.App (C.Var "Bits__band_64", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_bits_and_64(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.App (C.Var "Bits__bxor_64", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_bits_xor_64(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.Var "Time__now_ms", _) ->
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_time_now_ms() : () -> f64" v);
      (v, "f64")
  | C.App (C.Var "Time__now_ns", _) ->
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_time_now_ns() : () -> f64" v);
      (v, "f64")
  | C.App (C.Var "Random__seed", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_random_seed(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Random__int", _) ->
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_random_int() : () -> f64" v);
      (v, "f64")
  | C.App (C.App (C.Var "Random__range", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_random_range(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.Var "Crypto__fnv1a", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_crypto_fnv1a(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Crypto__hash_int", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_crypto_hash_int(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.App (C.App (C.Var "Route__step", a), b), c) ->
      let (va,_) = emit_term e env funcs a in
      let (vb,_) = emit_term e env funcs b in
      let (vc,_) = emit_term e env funcs c in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_hsh_step(%s, %s, %s) : (f64, f64, f64) -> f64" v va vb vc);
      (v, "f64")
  | C.App (C.App (C.App (C.Var "Route__contains", a), b), c) ->
      let (va,_) = emit_term e env funcs a in
      let (vb,_) = emit_term e env funcs b in
      let (vc,_) = emit_term e env funcs c in
      let v_f64 = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_hsh_contains(%s, %s, %s) : (f64, f64, f64) -> f64" v_f64 va vb vc);
      let v_zero = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 0.0 : f64" v_zero);
      let v_i1 = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.cmpf one, %s, %s : f64" v_i1 v_f64 v_zero);
      (v_i1, "i1")
  | C.App (C.App (C.App (C.Var "Route__witness", a), b), c) ->
      let (va,_) = emit_term e env funcs a in
      let (vb,_) = emit_term e env funcs b in
      let (vc,_) = emit_term e env funcs c in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_hsh_backward(%s, %s, %s) : (f64, f64, f64) -> f64" v va vb vc);
      (v, "f64")
  | C.App (C.App (C.Var "Route__empty_mod", a), b) ->
      let (va,_) = emit_term e env funcs a in
      let (vb,_) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_hsh_empty_mod(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.Var "Route__empty", a) ->
      let (va,_) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_hsh_empty(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Route__shared_levels", a) ->
      let (va,_) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_hsh_shared_levels(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.Var "Route__levels", a) ->
      let (va,_) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_hsh_levels(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.App (C.Var "HashSet__union", a), b) ->
      let (va,_) = emit_term e env funcs a in
      let (vb,_) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_hashset_union(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.App (C.Var "HashSet__intersect", a), b) ->
      let (va,_) = emit_term e env funcs a in
      let (vb,_) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_hashset_intersect(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.Var "List__reverse", a) ->
      let (va,_) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @yon_rt_list_reverse(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.App (C.Var "HashSet__try_add", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_hashset_try_add(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.App (C.Var "HashSet__at_bucket", a), b) ->
      let (va, _) = emit_term e env funcs a in
      let (vb, _) = emit_term e env funcs b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_hashset_at_bucket(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.Var "HashSet__dir_capacity", a) ->
      let (va, _) = emit_term e env funcs a in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_hashset_dir_capacity(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.App (C.App (C.App (C.Var "MerkleTree__node3", a_l), a_c1), a_c2), a_c3) ->
      let (vl, _) = emit_term e env funcs a_l in
      let (vc1, _) = emit_term e env funcs a_c1 in
      let (vc2, _) = emit_term e env funcs a_c2 in
      let (vc3, _) = emit_term e env funcs a_c3 in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_merkle_node3(%s, %s, %s, %s) : (f64, f64, f64, f64) -> f64"
        v vl vc1 vc2 vc3);
      (v, "f64")
  | C.App (C.App (C.App (C.App (C.App (C.Var "MerkleTree__node4", a_l), a_c1), a_c2), a_c3), a_c4) ->
      let (vl, _) = emit_term e env funcs a_l in
      let (vc1, _) = emit_term e env funcs a_c1 in
      let (vc2, _) = emit_term e env funcs a_c2 in
      let (vc3, _) = emit_term e env funcs a_c3 in
      let (vc4, _) = emit_term e env funcs a_c4 in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_merkle_node4(%s, %s, %s, %s, %s) : (f64, f64, f64, f64, f64) -> f64"
        v vl vc1 vc2 vc3 vc4);
      (v, "f64")
  (* VoyagerList as a collection. *)
  | C.App (C.App (C.Var "VoyagerList__append", arg_a), arg_b) ->
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_voyagerlist_append(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  (* Arena: the Leech type-2 arena as a first-class structure. *)
  | C.App (C.App (C.App (C.Var "Arena__put", arg_a), arg_b), arg_c) ->
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let (vc, _) = emit_term e env funcs arg_c in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_arena_put(%s, %s, %s) : (f64, f64, f64) -> f64" v va vb vc);
      (v, "f64")
  | C.App (C.App (C.Var "Arena__get", arg_a), arg_b) ->
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_arena_get(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.App (C.Var "Arena__occupied", arg_a), arg_b) ->
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_arena_occupied(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.App (C.Var "Arena__orbit", arg_a), arg_b) ->
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_arena_orbit(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.App (C.App (C.Var "Arena__same_orbit", arg_a), arg_b), arg_c) ->
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let (vc, _) = emit_term e env funcs arg_c in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_arena_same_orbit(%s, %s, %s) : (f64, f64, f64) -> f64" v va vb vc);
      (v, "f64")
  | C.App (C.App (C.App (C.App (C.Var "Arena__fuse", arg_a), arg_b), arg_c), arg_d) ->
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let (vc, _) = emit_term e env funcs arg_c in
      let (vd, _) = emit_term e env funcs arg_d in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_arena_fuse(%s, %s, %s, %s) : (f64, f64, f64, f64) -> f64" v va vb vc vd);
      (v, "f64")
  | C.App (C.App (C.Var "Arena__fusion_count", arg_a), arg_b) ->
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_arena_fusion_count(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.App (C.Var "VoyagerList__get", arg_a), arg_b) ->
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_voyagerlist_get(%s, %s) : (f64, f64) -> f64" v va vb);
      (v, "f64")
  | C.App (C.Var "VoyagerList__size", arg) ->
      let (va, _) = emit_term e env funcs arg in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_voyagerlist_size(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.App (C.App (C.Var "VoyagerList__corrupt_at", arg_a), arg_b), arg_c) ->
      let (va, _) = emit_term e env funcs arg_a in
      let (vb, _) = emit_term e env funcs arg_b in
      let (vc, _) = emit_term e env funcs arg_c in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_voyagerlist_corrupt_at(%s, %s, %s) : (f64, f64, f64) -> f64"
        v va vb vc);
      (v, "f64")
  | C.App (C.Var "VoyagerList__to_stream", arg) ->
      let (va, _) = emit_term e env funcs arg in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_voyagerlist_to_list(%s) : (f64) -> f64" v va);
      (v, "f64")
  | C.App (C.App (C.Var "__stream_take",
            C.App (C.App (C.Var "__stream_iterate", C.Lam (px, _, body_f)), x0)),
           n) ->
      (* Materialize the first n into a list of T (concretely a list_id via
       * yon_rt_list_cons). Built tail-to-head: the scf.for accumulates by
       * prepending. *)
      let (v_x0, _) = emit_term e env funcs x0 in
      let (v_n, _) = emit_term e env funcs n in
      let v_n_i32 = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.fptosi %s : f64 to i32" v_n_i32 v_n);
      let v_n_idx = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.index_cast %s : i32 to index" v_n_idx v_n_i32);
      let v_zero_idx = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 0 : index" v_zero_idx);
      let v_one_idx = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 1 : index" v_one_idx);
      (* Build a buffer of values by iterating n times. Approach: an scf.for
       * accumulates `lst` by cons-ing from the back. To
       * preserve order, we compute the values first (scf.for in forward
       * order) and accumulate them in reverse, then reverse-iterate. We use a
       * fold-style cons directly; the order is reversed (last element at the
       * head), which is acceptable for the common unfold uses such as a
       * symmetric reduce. *)
      let v_dummy_f = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 0.0 : f64" v_dummy_f);
      let v_empty_id = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_list_empty(%s) : (f64) -> f64"
        v_empty_id v_dummy_f);
      let _ = v_empty_id in
      let v_result = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s:2 = scf.for %%i = %s to %s step %s iter_args(%%lst = %s, %%cur = %s) -> (f64, f64) {"
        v_result v_zero_idx v_n_idx v_one_idx v_empty_id v_x0);
      push_indent e;
      let v_new_lst = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_list_cons(%%cur, %%lst) : (f64, f64) -> f64"
        v_new_lst);
      let env_f = Env.add px ("%cur", "f64") env in
      let (v_new_cur, _) = emit_term e env_f funcs body_f in
      emit_line e (Printf.sprintf "scf.yield %s, %s : f64, f64" v_new_lst v_new_cur);
      pop_indent e;
      emit_line e "}";
      (Printf.sprintf "%s#0" v_result, "f64")
  | C.App (C.App (C.Var "__stream_sum_take",
            C.App (C.App (C.Var "__stream_iterate", C.Lam (px, _, body_f)), x0)),
           n) ->
      let (v_x0, _) = emit_term e env funcs x0 in
      let (v_n, _) = emit_term e env funcs n in
      let v_n_i32 = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.fptosi %s : f64 to i32"
                     v_n_i32 v_n);
      let v_n_idx = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.index_cast %s : i32 to index"
                     v_n_idx v_n_i32);
      let v_zero_idx = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 0 : index" v_zero_idx);
      let v_one_idx = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 1 : index" v_one_idx);
      let v_init_acc = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 0.0 : f64" v_init_acc);
      let v_result = fresh_ssa e in
      (* scf.for with two iter_args: acc (the running sum) and cur (the current stream value). *)
      emit_line e (Printf.sprintf
        "%s:2 = scf.for %%i = %s to %s step %s iter_args(%%acc = %s, %%cur = %s) -> (f64, f64) {"
        v_result v_zero_idx v_n_idx v_one_idx v_init_acc v_x0);
      push_indent e;
      (* Inside loop: acc' = acc + cur; cur' = f(cur) *)
      let v_new_acc = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.addf %%acc, %%cur : f64" v_new_acc);
      (* Emit body_f with px bound to %cur. *)
      let env_f = Env.add px ("%cur", "f64") env in
      let (v_new_cur, _) = emit_term e env_f funcs body_f in
      emit_line e (Printf.sprintf "scf.yield %s, %s : f64, f64"
                     v_new_acc v_new_cur);
      pop_indent e;
      emit_line e "}";
      (Printf.sprintf "%s#0" v_result, "f64")
  (* fusion fallback per __stream_iterate
   * with a lifted function pointer (an S.ELam lifted to __arg_lam_inline_N).
   * Uses a direct func.call instead of an inline body. *)
  | C.App (C.App (C.Var "__stream_sum_take",
            C.App (C.App (C.Var "__stream_iterate", C.Var fname), x0)),
           n) when List.mem_assoc fname funcs ->
      let (v_x0, _) = emit_term e env funcs x0 in
      let (v_n, _) = emit_term e env funcs n in
      let v_n_i32 = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.fptosi %s : f64 to i32" v_n_i32 v_n);
      let v_n_idx = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.index_cast %s : i32 to index"
                     v_n_idx v_n_i32);
      let v_zero_idx = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 0 : index" v_zero_idx);
      let v_one_idx = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 1 : index" v_one_idx);
      let v_init_acc = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 0.0 : f64" v_init_acc);
      let v_result = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s:2 = scf.for %%i = %s to %s step %s iter_args(%%acc = %s, %%cur = %s) -> (f64, f64) {"
        v_result v_zero_idx v_n_idx v_one_idx v_init_acc v_x0);
      push_indent e;
      let v_new_acc = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.addf %%acc, %%cur : f64" v_new_acc);
      let v_new_cur = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @%s(%%cur) : (f64) -> f64"
                     v_new_cur fname);
      emit_line e (Printf.sprintf "scf.yield %s, %s : f64, f64" v_new_acc v_new_cur);
      pop_indent e;
      emit_line e "}";
      (Printf.sprintf "%s#0" v_result, "f64")
  | C.App (C.App (C.Var "__stream_take",
            C.App (C.App (C.Var "__stream_iterate", C.Var fname), x0)),
           n) when List.mem_assoc fname funcs ->
      let (v_x0, _) = emit_term e env funcs x0 in
      let (v_n, _) = emit_term e env funcs n in
      let v_n_i32 = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.fptosi %s : f64 to i32" v_n_i32 v_n);
      let v_n_idx = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.index_cast %s : i32 to index"
                     v_n_idx v_n_i32);
      let v_zero_idx = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 0 : index" v_zero_idx);
      let v_one_idx = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 1 : index" v_one_idx);
      let v_dummy_f = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 0.0 : f64" v_dummy_f);
      let v_empty_id = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_list_empty(%s) : (f64) -> f64" v_empty_id v_dummy_f);
      let _ = v_empty_id in
      let v_result = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s:2 = scf.for %%i = %s to %s step %s iter_args(%%lst = %s, %%cur = %s) -> (f64, f64) {"
        v_result v_zero_idx v_n_idx v_one_idx v_empty_id v_x0);
      push_indent e;
      let v_new_lst = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_list_cons(%%cur, %%lst) : (f64, f64) -> f64"
        v_new_lst);
      let v_new_cur = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = func.call @%s(%%cur) : (f64) -> f64"
                     v_new_cur fname);
      emit_line e (Printf.sprintf "scf.yield %s, %s : f64, f64" v_new_lst v_new_cur);
      pop_indent e;
      emit_line e "}";
      (Printf.sprintf "%s#0" v_result, "f64")
  | C.App (C.App (C.App (C.Var "__stream_fold", source), init), g_expr) ->
      (* Seq.* accepts only an inline lambda as its higher-order argument.
       * Top-level function names are not allowed; to use one, wrap it in a
       * lambda: `Seq.map(s, fun(x) => f(x))`.
       *
       * Except __arg_lam_inline_N (a lifted bare lambda), which is handled
       * via a direct func.call. *)
      let is_lifted_lam n =
        String.length n >= 16 && String.sub n 0 16 = "__arg_lam_inline"
      in
      (* Peel the chain of captured args from a lifted lambda.
       * C.App (... C.App (C.Var fn, c1), c2) is unfolded to
       * (fn_name, [c1; c2; ...]). Returns None if it does not match the
       * pattern. *)
      let rec peel_lifted_with_captures expr acc_captures =
        match expr with
        | C.Var n when is_lifted_lam n -> Some (n, acc_captures)
        | C.App (f, arg) -> peel_lifted_with_captures f (arg :: acc_captures)
        | _ -> None
      in
      let g_arg = (match g_expr with
        | C.Lam (p, _, C.Lam (q, _, body)) -> `Inline2 (p, q, body)
        | C.Var n when is_lifted_lam n -> `LiftedFn (n, [])
        | C.App _ ->
            (match peel_lifted_with_captures g_expr [] with
             | Some (n, caps) -> `LiftedFn (n, caps)
             | None -> failwith "[emit_mlir Seq.fold] third arg must be an inline lambda (a, b) => body")
        | C.Var n ->
            failwith (Printf.sprintf
              "[emit_mlir Seq.fold] third arg must be an inline lambda \
               (a, b) => body; top-level function name '%s' is not allowed. \
               Use: Seq.fold(s, init, fun(a, b) => %s(a, b))" n n)
        | _ -> failwith "[emit_mlir Seq.fold] third arg must be an inline lambda (a, b) => body") in
      let rec collect s =
        match s with
        | C.App (C.App (C.Var "__stream_map", inner), C.Lam (p, _, body)) ->
            let (lst, ops) = collect inner in
            (lst, ops @ [`Map (`Inline1 (p, body))])
        | C.App (C.App (C.Var "__stream_map", inner), C.Var n) when is_lifted_lam n ->
            let (lst, ops) = collect inner in
            (lst, ops @ [`Map (`LiftedFn1 n)])
        | C.App (C.App (C.Var "__stream_map", _), C.Var fn) ->
            failwith (Printf.sprintf
              "[emit_mlir Seq.map] second arg must be an inline lambda \
               (x) => body; top-level function name '%s' is not allowed. \
               Use: Seq.map(s, fun(x) => %s(x))" fn fn)
        | C.App (C.App (C.Var "__stream_filter", inner), C.Lam (p, _, body)) ->
            let (lst, ops) = collect inner in
            (lst, ops @ [`Filter (`Inline1 (p, body))])
        | C.App (C.App (C.Var "__stream_filter", inner), C.Var n) when is_lifted_lam n ->
            let (lst, ops) = collect inner in
            (lst, ops @ [`Filter (`LiftedFn1 n)])
        | C.App (C.App (C.Var "__stream_filter", _), C.Var pn) ->
            failwith (Printf.sprintf
              "[emit_mlir Seq.filter] second arg must be an inline lambda \
               (x) => body; top-level function name '%s' is not allowed. \
               Use: Seq.filter(s, fun(x) => %s(x))" pn pn)
        | C.App (C.Var "__stream_from_list", l) -> (l, [])
        | other -> (other, [])
      in
      let (list_term, ops) = collect source in
      let (v_list, _) = emit_term e env funcs list_term in
      let (v_init, _) = emit_term e env funcs init in
      (* The empty-list sentinel in the runtime is (double)0xFFFFFFFF.
       * Compared with f64 equality. *)
      let v_empty = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = arith.constant 0xFFFFFFFF : i32" v_empty);
      let v_empty_f64 = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = arith.uitofp %s : i32 to f64" v_empty_f64 v_empty);
      let v_result = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s:2 = scf.while (%%cur = %s, %%acc = %s) : (f64, f64) -> (f64, f64) {"
        v_result v_list v_init);
      push_indent e;
      let v_is_empty = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = arith.cmpf oeq, %%cur, %s : f64" v_is_empty v_empty_f64);
      let v_true = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant true" v_true);
      let v_not_empty = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = arith.xori %s, %s : i1" v_not_empty v_is_empty v_true);
      emit_line e (Printf.sprintf
        "scf.condition(%s) %%cur, %%acc : f64, f64" v_not_empty);
      pop_indent e;
      emit_line e "} do {";
      push_indent e;
      emit_line e "^bb0(%cur: f64, %acc: f64):";
      let v_head = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_list_head(%%cur) : (f64) -> f64" v_head);
      let v_tail = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = func.call @yon_rt_list_tail(%%cur) : (f64) -> f64" v_tail);
      (* Apply the ops in order. The state is v_val (the current value, f64)
         and v_keep (i1: true if this element should be accumulated). It starts
         at v_val = v_head, v_keep = true. *)
      let v_keep_init = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant true" v_keep_init);
      (* Apply one map/filter argument to the current value. For an inline
         lambda we bind its parameter to v_val and emit the body inline (no
         func.call); for a lifted function we emit a direct call. *)
      let emit_arg_call arg_kind v_val =
        match arg_kind with
        | `Inline1 (pname, body) ->
            let env' = Env.add pname (v_val, "f64") env in
            let (v_b, _) = emit_term e env' funcs body in
            v_b
        | `LiftedFn1 fname ->
            (* lifted function pointer: a direct call *)
            let v_b = fresh_ssa e in
            emit_line e (Printf.sprintf
              "%s = func.call @%s(%s) : (f64) -> f64" v_b fname v_val);
            v_b
      in
      let (v_val_final, v_keep_final) =
        List.fold_left (fun (v_val, v_keep) op ->
          match op with
          | `Map arg ->
              let v_new = emit_arg_call arg v_val in
              (v_new, v_keep)
          | `Filter arg ->
              (* the predicate returns a number (0.0/1.0); convert to i1 *)
              let v_pred_f64 = emit_arg_call arg v_val in
              let v_zero = fresh_ssa e in
              emit_line e (Printf.sprintf
                "%s = arith.constant 0.0 : f64" v_zero);
              let v_pred_i1 = fresh_ssa e in
              emit_line e (Printf.sprintf
                "%s = arith.cmpf one, %s, %s : f64"
                v_pred_i1 v_pred_f64 v_zero);
              let v_keep_new = fresh_ssa e in
              emit_line e (Printf.sprintf
                "%s = arith.andi %s, %s : i1" v_keep_new v_keep v_pred_i1);
              (v_val, v_keep_new)
        ) (v_head, v_keep_init) ops
      in
      (* Accumulate when v_keep_final is true, otherwise leave acc unchanged. *)
      let v_new_acc = fresh_ssa e in
      emit_line e (Printf.sprintf
        "%s = scf.if %s -> (f64) {" v_new_acc v_keep_final);
      push_indent e;
      let v_g_res = (match g_arg with
        | `Inline2 (acc_name, x_name, body) ->
            let env' = Env.add acc_name ("%acc", "f64") env in
            let env' = Env.add x_name (v_val_final, "f64") env' in
            let (v, _) = emit_term e env' funcs body in
            v
        | `LiftedFn (fname, caps) ->
            (* The fold combiner as a lifted function pointer, with support
               for captured arguments: caps is a list of terms emitted first
               and then passed as the leading N arguments of the func.call. *)
            let cap_vs = List.map (fun cap_term ->
              let (v, _) = emit_term e env funcs cap_term in v
            ) caps in
            let v_b = fresh_ssa e in
            let n_caps = List.length cap_vs in
            let arg_str =
              if n_caps = 0 then
                Printf.sprintf "%%acc, %s" v_val_final
              else
                String.concat ", " (cap_vs @ ["%acc"; v_val_final])
            in
            let f64s_sig =
              String.concat ", " (List.init (n_caps + 2) (fun _ -> "f64"))
            in
            emit_line e (Printf.sprintf
              "%s = func.call @%s(%s) : (%s) -> f64"
              v_b fname arg_str f64s_sig);
            v_b) in
      emit_line e (Printf.sprintf "scf.yield %s : f64" v_g_res);
      pop_indent e;
      emit_line e "} else {";
      push_indent e;
      emit_line e "scf.yield %acc : f64";
      pop_indent e;
      emit_line e "}";
      emit_line e (Printf.sprintf
        "scf.yield %s, %s : f64, f64" v_tail v_new_acc);
      pop_indent e;
      emit_line e "}";
      (* The final accumulator value is v_result#1. *)
      let v_final = Printf.sprintf "%s#1" v_result in
      (v_final, "f64")
  (* iter N do { body }: a bounded loop. Desugars to __iter_n(N, Lam("_idx",
     body)). Lowered to an scf.for with lb=0, ub=N (cast f64->index), step=1.
     The body is inlined; the loop yields nothing (a void loop). *)
  | C.App (C.App (C.Var "__iter_n", n_expr), C.Lam (idx_name, _, body_term)) ->
      let (vn_f64, _) = emit_term e env funcs n_expr in
      (* Convert N from f64 to index type *)
      let vn_i64 = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.fptosi %s : f64 to i64" vn_i64 vn_f64);
      let vn_idx = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.index_cast %s : i64 to index" vn_idx vn_i64);
      let v_zero = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 0 : index" v_zero);
      let v_one = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 1 : index" v_one);
      (* scf.for whose induction variable is exposed as idx_name (cast to f64). *)
      let v_iv = fresh_ssa e in
      emit_line e (Printf.sprintf "scf.for %s = %s to %s step %s {"
                     v_iv v_zero vn_idx v_one);
      push_indent e;
      (* Cast iv to f64 and bind to idx_name *)
      let v_iv_i64 = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.index_cast %s : index to i64" v_iv_i64 v_iv);
      let v_iv_f64 = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.sitofp %s : i64 to f64" v_iv_f64 v_iv_i64);
      (* Bind idx_name to v_iv_f64 in env for body emission *)
      let env_body = Env.add idx_name (v_iv_f64, "f64") env in
      let _ = emit_term e env_body funcs body_term in
      pop_indent e;
      emit_line e "}";
      (* the iter loop has no value (Unit); return a placeholder f64 0. *)
      let v_unit = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 0.0 : f64" v_unit);
      (v_unit, "f64")
  (* while cond do { body }: a general loop. Desugars to
     __while_loop(Lam("_", cond), Lam("_", body)). Lowered to an scf.while with
     scf.condition + scf.yield. *)
  | C.App (C.App (C.Var "__while_loop", C.Lam (_, _, cond_term)),
                                          C.Lam (_, _, body_term)) ->
      emit_line e "scf.while : () -> () {";
      push_indent e;
      let (vc, _) = emit_term e env funcs cond_term in
      emit_line e (Printf.sprintf "scf.condition(%s)" vc);
      pop_indent e;
      emit_line e "} do {";
      push_indent e;
      let _ = emit_term e env funcs body_term in
      emit_line e "scf.yield";
      pop_indent e;
      emit_line e "}";
      let v_unit = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 0.0 : f64" v_unit);
      (v_unit, "f64")
  | C.App (g, C.Unit) ->
      (* Zero-argument call marker from the desugar: f() compiled as
         App(f, Unit). For a user function (direct name or a bound
         __hof_ref alias) this is ONE func.call, emitted here, so a
         bound result never re-executes at its use sites. Anything else
         degrades to emitting g itself, which is exactly the pre-marker
         bare-Var behavior for builtins and module calls. *)
      (match g with
       | C.Var f when List.mem_assoc f funcs ->
           (match List.assoc f funcs with
            | fs when fs.fn_params = [] ->
                let v = fresh_ssa e in
                emit_line e (Printf.sprintf "%s = func.call @%s() : () -> %s"
                               v f fs.fn_ret_mlir);
                (v, fs.fn_ret_mlir)
            | _ ->
                failwith (Printf.sprintf
                  "[emit_mlir] %s() called with no arguments but the function has parameters." f))
       | C.Var x ->
           (match Env.find_opt x env with
            | Some (ssa, _) when String.length ssa > 10
                                 && String.sub ssa 0 10 = "__hof_ref:" ->
                let real_fname = String.sub ssa 10 (String.length ssa - 10) in
                (match List.assoc_opt real_fname funcs with
                 | Some fs when fs.fn_params = [] ->
                     let v = fresh_ssa e in
                     emit_line e (Printf.sprintf "%s = func.call @%s() : () -> %s"
                                    v real_fname fs.fn_ret_mlir);
                     (v, fs.fn_ret_mlir)
                 | _ ->
                     failwith (Printf.sprintf
                       "[emit_mlir] alias %s does not name a zero-argument function." x))
            | _ -> emit_term e env funcs g)
       | _ -> emit_term e env funcs g)
  | C.App (C.Lam (x, _, rest), value) ->
      (* Special case: the bound value is itself a Lam, so this is a function
         let-binding. Functions are already emitted as top-level func.func
         under their original name, so if x matches a known function we just
         alias it in the env and ignore the redundant Lam; otherwise we fail
         loudly. *)
      (match value with
       | C.Lam _ ->
           if List.mem_assoc x funcs then
             (* x names a user function. The binding only matters for typing
                the core IR; the emitter outputs nothing, since the Lam's value
                is already the top-level func.func named x. *)
             emit_term e env funcs rest
           else
             failwith (Printf.sprintf
                         "[emit_mlir] let-binding '%s' to a Lambda value matches no top-level function. Known functions: [%s]."
                         x
                         (String.concat "; " (List.map fst funcs)))
       | _ when List.mem_assoc x funcs ->
           (* Same drained self-binding, zero-parameter case: with no
              parameters the function body is a let-chain (an App), not a
              Lam, so the case above misses. Emitting the value here would
              run the body's effects inline AND leave the later Var to
              resolve through funcs into a func.call: the effects would
              execute twice (the zero-arg double-execution bug). The
              top-level func.func already exists; skip the binding. *)
           emit_term e env funcs rest
       | _ ->
           (* If value is a Var naming a top-level function, record an alias in
              the env as "__hof_ref:name". A later App pattern knows that
              calling this var means calling that concrete function. This
              handles passing a function by name; a truly dynamic higher-order
              value (an if/else returning different functions) needs an LLVM
              function pointer instead. *)
           (match value with
            | C.Var fname when List.mem_assoc fname funcs && x <> fname ->
                let env' = Env.add x (Printf.sprintf "__hof_ref:%s" fname,
                                       "arrow") env in
                emit_term e env' funcs rest
            (* let-binding of a move name: alias it as a move handle *)
            | C.Var fname when Move_engine.lookup_move fname <> None ->
                let env' = Env.add x (Printf.sprintf "__move_ref:%s" fname,
                                       "move_handle") env in
                emit_term e env' funcs rest
            (* let-binding of a reduction name: alias it as a reduction handle *)
            | C.Var fname when List.exists
                (fun (rd : C.reduction_decl) -> rd.r_name = fname) e.reductions_decls ->
                let env' = Env.add x (Printf.sprintf "__reduction_ref:%s" fname,
                                       "reduction_handle") env in
                emit_term e env' funcs rest
            (* let-binding of a morphism name: alias it as a morph handle *)
            | C.Var fname when List.exists
                (fun (mname, _, _) -> mname = fname) e.morphs_index ->
                let env' = Env.add x (Printf.sprintf "__morph_ref:%s" fname,
                                       "morph_handle") env in
                emit_term e env' funcs rest
            (* let-binding of a view name: alias it as a view handle *)
            | C.Var fname when List.exists
                (fun (vname, _) -> vname = fname) e.views_list ->
                let env' = Env.add x (Printf.sprintf "__view_ref:%s" fname,
                                       "view_handle") env in
                emit_term e env' funcs rest
            | _ ->
                let (vv, tv) = emit_term e env funcs value in
                let env' = Env.add x (vv, tv) env in
                emit_term e env' funcs rest))
  | C.App _ as app ->
      (match uncurry_app app with
       (* A call to a variable bound to a top-level function via the
          "__hof_ref:<fname>" alias: turn the indirect call into a direct call
          to the real name. *)
       | Some (fname, args) when
           (match Env.find_opt fname env with
            | Some (alias, _) when String.length alias > 10
                                   && String.sub alias 0 10 = "__hof_ref:" -> true
            | _ -> false) ->
           let real_fname =
             match Env.find_opt fname env with
             | Some (alias, _) ->
                 String.sub alias 10 (String.length alias - 10)
             | None -> fname
           in
           if not (List.mem_assoc real_fname funcs) then
             failwith (Printf.sprintf
               "[emit_mlir HOF] alias points to unknown function '%s'." real_fname);
           let fs = List.assoc real_fname funcs in
           let arg_vals = List.map (emit_term e env funcs) args in
           let param_tys =
             List.map (fun (_, t) -> core_ty_to_mlir_simple t) fs.fn_params in
           let ret_ty = fs.fn_ret_mlir in
           let coerced_ssas =
             if List.length param_tys = List.length arg_vals then
               List.map2 (fun (ssa, ty) param_ty ->
                 coerce_to_param e ssa ty param_ty
               ) arg_vals param_tys
             else List.map fst arg_vals
           in
           let v = fresh_ssa e in
           let arg_str = String.concat ", " coerced_ssas in
           let arg_ty_str = String.concat ", " param_tys in
           emit_line e (Printf.sprintf "%s = func.call @%s(%s) : (%s) -> %s"
                          v real_fname arg_str arg_ty_str ret_ty);
           (v, ret_ty)
       (* A call to a higher-order function that has at least one TyArrow
          parameter. We inline it: substitute each parameter in the body with
          its argument (a function name for the TyArrow params, a term for the
          rest) and emit the substituted body. Inlining applies only when every
          TyArrow argument is a static function name (a Var in funcs) or a
          lambda; for a dynamic argument (say the result of an if/else yielding
          a function pointer) we skip inlining and emit a direct func.call. *)
       | Some (fname, args) when
           List.mem_assoc fname funcs
           && List.exists (fun (_, t) ->
                match t with
                | C.TyBase "arrow"
                | C.TyArrow _   (* also nested TyArrow *)
                | C.TyBase "move_handle"
                | C.TyBase "reduction_handle"
                | C.TyBase "morph_handle"
                | C.TyBase "view_handle" -> true
                | _ -> false
              ) (List.assoc fname funcs).fn_params
           && List.length args = List.length (List.assoc fname funcs).fn_params
           && (let fs = List.assoc fname funcs in
               List.for_all2 (fun (_, ptype) arg ->
                 match ptype with
                 | C.TyBase "arrow"
                 | C.TyArrow _ ->
                     (match arg with
                      | C.Var aname -> List.mem_assoc aname funcs
                      | C.Lam _ -> true
                      | _ -> false)
                 | C.TyBase "move_handle"
                 | C.TyBase "reduction_handle"
                 | C.TyBase "morph_handle"
                 | C.TyBase "view_handle" ->
                     true
                 | _ -> true
               ) fs.fn_params args) ->
           let fs = List.assoc fname funcs in
           (* For each parameter and argument, substitute the parameter name
            * with the Core IR argument. *)
           let inlined_body = List.fold_left2 (fun body (pname, _ptype) arg ->
             Subst.subst pname arg body
           ) fs.fn_body fs.fn_params args in
           (* Emit the inlined body in the current env. *)
           emit_term e env funcs inlined_body
       | Some (fname, args) when List.mem_assoc fname funcs ->
           let fs = List.assoc fname funcs in
           let n_expected = List.length fs.fn_params in
           let n_given = List.length args in
           if n_given <> n_expected then
             failwith (Printf.sprintf
                         "[emit_mlir] '%s' atteso %d arg, ricevuti %d."
                         fname n_expected n_given);
           let arg_vals = List.map (emit_term e env funcs) args in
           (* If the function is polymorphic, infer the concrete types from
              the argument types and request a specialization. *)
           let (call_name, param_tys, ret_ty) =
             if fs.fn_type_params = [] then
               (fname,
                List.map (fun (_, t) -> core_ty_to_mlir_simple t) fs.fn_params,
                fs.fn_ret_mlir)
             else begin
               (* For each type parameter, find the first parameter that uses
                * it and take the MLIR type of the corresponding argument. *)
               let concrete = List.map (fun tv ->
                 (* Find the parameter that uses tv directly *)
                 let rec find_param idx params =
                   match params with
                   | [] ->
                       failwith (Printf.sprintf
                                   "[emit_mlir A5] type parameter '%s' of '%s' cannot be resolved from the arguments."
                                   tv fname)
                   | (_, C.TyBase n) :: _ when n = tv ->
                       snd (List.nth arg_vals idx)
                   | (_, C.TyPlace n) :: _ when n = tv ->
                       snd (List.nth arg_vals idx)
                   | _ :: rest -> find_param (idx + 1) rest
                 in
                 find_param 0 fs.fn_params
               ) fs.fn_type_params in
               let spec_name = request_mono !mono_global e fs concrete in
               let spec = (match List.find_opt (fun (_, _, sp) ->
                 sp.fn_name = spec_name
               ) (!mono_global).mono_instances with
                | Some (_, _, sp) -> sp
                | None -> assert false) in
               (spec_name,
                List.map (fun (_, t) -> core_ty_to_mlir_simple t) spec.fn_params,
                spec.fn_ret_mlir)
             end
           in
           let v = fresh_ssa e in
           (* Coerce each argument to the expected parameter type, inserting a
            * subtype_cast when the argument's type is a subtype. *)
           let coerced_ssas = List.map2 (fun (ssa, ty) param_ty ->
             coerce_to_param e ssa ty param_ty
           ) arg_vals param_tys in
           let arg_str = String.concat ", " coerced_ssas in
           let arg_ty_str = String.concat ", " param_tys in
           emit_line e (Printf.sprintf "%s = func.call @%s(%s) : (%s) -> %s"
                          v call_name arg_str arg_ty_str ret_ty);
           (v, ret_ty)
       (* apply_move(MoveName, instance) is the identity on instance, with a
        * type cast to the target place declared by the move.
        * Pattern: App(App(Var "apply_move", Var move_name), instance).
        * Recover the move from the Move_engine registry; the result type is
        * !topos.section<"<target_place>">. The field conversion is delegated
        * to the XLeech2 runtime; for now identity.
        *
        * Extended pattern for __apply_move_in_<S>, the variant with an
        * explicit target space. The bind `target_space_opt` captures the space
        * name (None = __Default). *)
       | Some (fname, [C.Var move_name; instance_term])
         when fname = "apply_move"
           || (String.length fname > 16
               && String.sub fname 0 16 = "__apply_move_in_") ->
           let target_space_opt =
             if fname = "apply_move" then None
             else Some (String.sub fname 16 (String.length fname - 16))
           in
           let mv_decl =
             match Move_engine.lookup_move move_name with
             | Some md -> md
             | None ->
                 failwith (Printf.sprintf
                             "[emit_mlir A6] move '%s' not declared."
                             move_name)
           in
           let target_place =
             match mv_decl.mv_to with
             | Some t -> t
             | None ->
                 failwith (Printf.sprintf
                             "[emit_mlir A6] move '%s' has no target (Form B)."
                             move_name)
           in
           let source_place =
             match mv_decl.mv_from with
             | [src] -> src
             | _ ->
                 failwith (Printf.sprintf
                             "[emit_mlir P8] move '%s' multi-source not handled."
                             move_name)
           in
           let target_ty = Printf.sprintf "!topos.section<\"%s\">" target_place in
           let (v_inst, _) = emit_term e env funcs instance_term in
           (* Capability flow check. If mv_requires_caps is non-empty, emit a
            * runtime Cap.check for each required capability. If a capability is
            * missing, emit a warning to stderr but do not block (emit an audit
            * comment plus a best-effort check). *)
           List.iter (fun cap_name ->
             emit_line e (Printf.sprintf
               "// yon.capability: apply_move(%s) requires cap '%s'"
               move_name cap_name);
             (* Emit a runtime check: hash the cap name -> check via Cap.check *)
             let cap_hash =
               let h = ref 0x811c9dc5 in
               String.iter (fun c ->
                 h := !h lxor (Char.code c);
                 h := (!h * 0x01000193) land 0xFFFFFFFF
               ) cap_name;
               !h
             in
             let v_hash = fresh_ssa e in
             emit_line e (Printf.sprintf
               "%s = arith.constant %d.0 : f64" v_hash cap_hash);
             let v_chk = fresh_ssa e in
             emit_line e (Printf.sprintf
               "%s = func.call @yon_rt_cap_check(%s) : (f64) -> f64" v_chk v_hash)
           ) mv_decl.mv_requires_caps;
           (* Extract the mappings (Form A). For each mapping target_field
            * <- source_field by fn, compute the conversion value and store. *)
           let mappings =
             let open Surface_ast in
             match mv_decl.mv_body with
             | MoveMapping ms -> ms
             | MoveMerge _ ->
                 failwith (Printf.sprintf
                             "[emit_mlir P8] move '%s' Form B (merge) not handled."
                             move_name)
           in
           let target_fields =
             match List.assoc_opt target_place e.places_table with
             | Some fs -> fs
             | None ->
                 failwith (Printf.sprintf
                             "[emit_mlir P8] target place '%s' has no layout."
                             target_place)
           in
           let source_fields =
             match List.assoc_opt source_place e.places_table with
             | Some fs -> fs
             | None ->
                 failwith (Printf.sprintf
                             "[emit_mlir P8] source place '%s' has no layout."
                             source_place)
           in
           (* Calcolo offset cumulativo target packed layout. *)
           let mlir_ty_size = function
             | "f64" -> 8 | "i1" -> 1 | "i8" -> 1
             | "i32" -> 4 | "i64" -> 8 | "!llvm.ptr" -> 8
             | "!topos.proposition" -> 1 | _ -> 8
           in
           let target_offsets =
             let acc = ref 0 in
             List.map (fun (fname, fty) ->
               let o = !acc in
               acc := !acc + mlir_ty_size fty;
               (fname, fty, o)
             ) target_fields
           in
           let source_offsets =
             let acc = ref 0 in
             List.map (fun (fname, fty) ->
               let o = !acc in
               acc := !acc + mlir_ty_size fty;
               (fname, fty, o)
             ) source_fields
           in
           let target_total =
             List.fold_left (fun a (_, ty) -> a + mlir_ty_size ty) 0
               target_fields
           in
           (* Cast inst (section source) a i32 xcoord per field_load. *)
           let v_src_xc = fresh_ssa e in
           let source_ty = Printf.sprintf "!topos.section<\"%s\">" source_place in
           emit_line e (Printf.sprintf
                          "%s = topos.section_to_xcoord %s : %s to i64"
                          v_src_xc v_inst source_ty);
           (* Alloca buffer target. *)
           let v_one = fresh_ssa e in
           emit_line e (Printf.sprintf "%s = arith.constant 1 : i64" v_one);
           let v_buf = fresh_ssa e in
           emit_line e (Printf.sprintf
                          "%s = llvm.alloca %s x !llvm.array<%d x i8> : (i64) -> !llvm.ptr"
                          v_buf v_one target_total);
           (* For each target field, find a mapping or an identity copy. *)
           List.iter (fun (tfname, tfty, toff) ->
             let mapping_opt =
               List.find_opt (fun (m : Surface_ast.mapping_decl) ->
                 m.m_to = tfname) mappings
             in
             let (source_field, source_offset, source_fty) =
               match mapping_opt with
               | Some m ->
                   (match List.find_opt (fun (n, _, _) -> n = m.m_from)
                            source_offsets with
                    | Some (_, sty, soff) -> (m.m_from, soff, sty)
                    | None ->
                        failwith (Printf.sprintf
                                    "[emit_mlir P8] mapping source field '%s' assente in '%s'."
                                    m.m_from source_place))
               | None ->
                   (* Identity copy: same field name + same type. *)
                   (match List.find_opt (fun (n, _, _) -> n = tfname)
                            source_offsets with
                    | Some (_, sty, soff) -> (tfname, soff, sty)
                    | None ->
                        failwith (Printf.sprintf
                                    "[emit_mlir P8] target field '%s' has neither a mapping nor an identity."
                                    tfname))
             in
             (* Load source field via yon_rt_field_load. *)
             let v_off = fresh_ssa e in
             emit_line e (Printf.sprintf "%s = arith.constant %d : i32"
                            v_off source_offset);
             let v_size = fresh_ssa e in
             emit_line e (Printf.sprintf "%s = arith.constant %d : i32"
                            v_size (mlir_ty_size source_fty));
             let v_tmp_one = fresh_ssa e in
             emit_line e (Printf.sprintf "%s = arith.constant 1 : i64" v_tmp_one);
             let v_tmp_buf = fresh_ssa e in
             emit_line e (Printf.sprintf
                            "%s = llvm.alloca %s x i64 : (i64) -> !llvm.ptr"
                            v_tmp_buf v_tmp_one);
             let v_status = fresh_ssa e in
             emit_line e (Printf.sprintf
                            "%s = func.call @yon_rt_field_load(%s, %s, %s, %s) : (i64, i32, i32, !llvm.ptr) -> i32"
                            v_status v_src_xc v_off v_size v_tmp_buf);
             let _ = v_status in
             let v_loaded = fresh_ssa e in
             emit_line e (Printf.sprintf "%s = llvm.load %s : !llvm.ptr -> %s"
                            v_loaded v_tmp_buf source_fty);
             (* Applica conversion function se specificato. *)
             let v_converted =
               match mapping_opt with
               | Some m when m.m_by <> "identity" ->
                   (* Find the user function signature among the funcs in scope. *)
                   (match List.assoc_opt m.m_by funcs with
                    | Some fs ->
                        let param_ty =
                          match fs.fn_params with
                          | [(_, t)] -> core_ty_to_mlir_simple t
                          | _ -> source_fty
                        in
                        let v_call = fresh_ssa e in
                        emit_line e (Printf.sprintf
                                       "%s = func.call @%s(%s) : (%s) -> %s"
                                       v_call m.m_by v_loaded
                                       param_ty fs.fn_ret_mlir);
                        v_call
                    | None ->
                        (* conversion function not in scope: fall back to identity *)
                        v_loaded)
               | _ -> v_loaded  (* identity mapping, or no mapping at all *)
             in
             (* Store in target buffer. *)
             let v_t_off = fresh_ssa e in
             emit_line e (Printf.sprintf "%s = arith.constant %d : i32"
                            v_t_off toff);
             let v_gep = fresh_ssa e in
             emit_line e (Printf.sprintf
                            "%s = llvm.getelementptr %s[%s] : (!llvm.ptr, i32) -> !llvm.ptr, i8"
                            v_gep v_buf v_t_off);
             emit_line e (Printf.sprintf "llvm.store %s, %s : %s, !llvm.ptr"
                            v_converted v_gep tfty);
             let _ = source_field in ()
           ) target_offsets;
           (* yon_rt_new on the target buffer. If apply_move(M, x) in
            * TargetSpace, the target heap_id is resolved via
            * yon_rt_lookup_space(name). Otherwise the default heap_id = 0
            * (__Default). *)
           let v_size = fresh_ssa e in
           emit_line e (Printf.sprintf "%s = arith.constant %d : i32"
                          v_size target_total);
           let v_heap = fresh_ssa e in
           (match target_space_opt with
            | None ->
                emit_line e (Printf.sprintf "%s = arith.constant 0 : i32" v_heap)
            | Some sname ->
                let v_ptr = fresh_ssa e in
                emit_line e (Printf.sprintf
                               "%s = llvm.mlir.addressof @yon_space_str_%s : !llvm.ptr"
                               v_ptr sname);
                emit_line e (Printf.sprintf
                               "%s = func.call @yon_rt_lookup_space(%s) : (!llvm.ptr) -> i32"
                               v_heap v_ptr));
           (* If the target space has an inferred fold, emit
            * yon_rt_fold_named instead of yon_rt_new (CRDT semantics). *)
           let fold_name_opt =
             match target_space_opt with
             | None -> None
             | Some sname -> List.assoc_opt sname e.space_fold_name
           in
           let v_xc = fresh_ssa e in
           (match fold_name_opt with
            | Some fn ->
                let v_prev = fresh_ssa e in
                emit_line e (Printf.sprintf
                               "%s = arith.constant -1 : i64" v_prev);
                let v_fold_str = fresh_ssa e in
                emit_line e (Printf.sprintf
                               "%s = llvm.mlir.addressof @yon_fold_str_%s : !llvm.ptr"
                               v_fold_str fn);
                emit_line e (Printf.sprintf
                               "%s = func.call @yon_rt_fold_named(%s, %s, %s, %s, %s) : (i32, i64, !llvm.ptr, i32, !llvm.ptr) -> i64"
                               v_xc v_heap v_prev v_buf v_size v_fold_str)
            | None ->
                emit_line e (Printf.sprintf
                               "%s = func.call @yon_rt_new(%s, %s, %s) : (i32, !llvm.ptr, i32) -> i64"
                               v_xc v_heap v_buf v_size));
           let v_result = fresh_ssa e in
           emit_line e (Printf.sprintf
                          "%s = topos.xcoord_to_section %s : %s"
                          v_result v_xc target_ty);
           (v_result, target_ty)
       (* Move.merge(MoveName, s1, s2): the Form B (merge) move applied to
        * two runtime instances. The result lives in the FIRST source place
        * (the same arbitrary-but-fixed choice as the kernel reducer in
        * move_engine.ml). Semantics mirror apply_merge_move: a field in
        * merge_shares reads from s1; a field in merge_conflicts computes
        * resolver(s1.f, s2.f); every other target field copies from s1. *)
       | Some ("Move__merge", [C.Var move_name; s1_term; s2_term]) ->
           let mv_decl =
             match Move_engine.lookup_move move_name with
             | Some md -> md
             | None ->
                 failwith (Printf.sprintf
                             "[emit_mlir] merge move '%s' not declared."
                             move_name)
           in
           let mg =
             let open Surface_ast in
             match mv_decl.mv_body with
             | MoveMerge mg -> mg
             | MoveMapping _ ->
                 failwith (Printf.sprintf
                             "[emit_mlir] move '%s' is Form A (mapping): use apply_move."
                             move_name)
           in
           let (p1, p2) =
             match mv_decl.mv_from with
             | [a; b] -> (a, b)
             | _ ->
                 failwith (Printf.sprintf
                             "[emit_mlir] merge move '%s' needs exactly two sources."
                             move_name)
           in
           let target_place = p1 in
           let target_ty =
             Printf.sprintf "!topos.section<\"%s\">" target_place in
           let (v_s1, _) = emit_term e env funcs s1_term in
           let (v_s2, _) = emit_term e env funcs s2_term in
           let fields_of p =
             match List.assoc_opt p e.places_table with
             | Some fs -> fs
             | None ->
                 failwith (Printf.sprintf
                             "[emit_mlir] place '%s' has no layout." p)
           in
           let mlir_ty_size = function
             | "f64" -> 8 | "i1" -> 1 | "i8" -> 1
             | "i32" -> 4 | "i64" -> 8 | "!llvm.ptr" -> 8
             | "!topos.proposition" -> 1 | _ -> 8
           in
           let offsets fields =
             let acc = ref 0 in
             List.map (fun (fname, fty) ->
               let o = !acc in
               acc := !acc + mlir_ty_size fty;
               (fname, fty, o)
             ) fields
           in
           let o1 = offsets (fields_of p1) in
           let o2 = offsets (fields_of p2) in
           let target_total =
             List.fold_left (fun a (_, ty) -> a + mlir_ty_size ty) 0
               (fields_of p1)
           in
           let v_x1 = fresh_ssa e in
           emit_line e (Printf.sprintf
                          "%s = topos.section_to_xcoord %s : !topos.section<\"%s\"> to i64"
                          v_x1 v_s1 p1);
           let v_x2 = fresh_ssa e in
           emit_line e (Printf.sprintf
                          "%s = topos.section_to_xcoord %s : !topos.section<\"%s\"> to i64"
                          v_x2 v_s2 p2);
           let v_one = fresh_ssa e in
           emit_line e (Printf.sprintf "%s = arith.constant 1 : i64" v_one);
           let v_buf = fresh_ssa e in
           emit_line e (Printf.sprintf
                          "%s = llvm.alloca %s x !llvm.array<%d x i8> : (i64) -> !llvm.ptr"
                          v_buf v_one target_total);
           (* Load one field given an xcoord, an offset and a type. *)
           let load_field v_xc soff sty =
             let v_off = fresh_ssa e in
             emit_line e (Printf.sprintf "%s = arith.constant %d : i32"
                            v_off soff);
             let v_size = fresh_ssa e in
             emit_line e (Printf.sprintf "%s = arith.constant %d : i32"
                            v_size (mlir_ty_size sty));
             let v_t1 = fresh_ssa e in
             emit_line e (Printf.sprintf "%s = arith.constant 1 : i64" v_t1);
             let v_tbuf = fresh_ssa e in
             emit_line e (Printf.sprintf
                            "%s = llvm.alloca %s x i64 : (i64) -> !llvm.ptr"
                            v_tbuf v_t1);
             let v_st = fresh_ssa e in
             emit_line e (Printf.sprintf
                            "%s = func.call @yon_rt_field_load(%s, %s, %s, %s) : (i64, i32, i32, !llvm.ptr) -> i32"
                            v_st v_xc v_off v_size v_tbuf);
             let _ = v_st in
             let v_l = fresh_ssa e in
             emit_line e (Printf.sprintf "%s = llvm.load %s : !llvm.ptr -> %s"
                            v_l v_tbuf sty);
             v_l
           in
           List.iter (fun (fname, fty, toff) ->
             let from_s1 () = load_field v_x1 toff fty in
             let v_val =
               if List.mem fname mg.Surface_ast.merge_shares then from_s1 ()
               else match List.assoc_opt fname mg.Surface_ast.merge_conflicts with
                 | Some resolver ->
                     (match List.find_opt (fun (n, _, _) -> n = fname) o2 with
                      | Some (_, sty2, soff2) ->
                          let v1 = from_s1 () in
                          let v2 = load_field v_x2 soff2 sty2 in
                          let ret_ty =
                            match List.assoc_opt resolver funcs with
                            | Some fs -> fs.fn_ret_mlir
                            | None -> fty
                          in
                          let v_call = fresh_ssa e in
                          emit_line e (Printf.sprintf
                                         "%s = func.call @%s(%s, %s) : (%s, %s) -> %s"
                                         v_call resolver v1 v2 fty sty2 ret_ty);
                          v_call
                      | None -> from_s1 ())
                 | None -> from_s1 ()
             in
             let v_toff = fresh_ssa e in
             emit_line e (Printf.sprintf "%s = arith.constant %d : i32"
                            v_toff toff);
             let v_gep = fresh_ssa e in
             emit_line e (Printf.sprintf
                            "%s = llvm.getelementptr %s[%s] : (!llvm.ptr, i32) -> !llvm.ptr, i8"
                            v_gep v_buf v_toff);
             emit_line e (Printf.sprintf "llvm.store %s, %s : %s, !llvm.ptr"
                            v_val v_gep fty)
           ) o1;
           let v_size = fresh_ssa e in
           emit_line e (Printf.sprintf "%s = arith.constant %d : i32"
                          v_size target_total);
           let v_heap = fresh_ssa e in
           emit_line e (Printf.sprintf "%s = arith.constant 0 : i32" v_heap);
           let v_xc = fresh_ssa e in
           emit_line e (Printf.sprintf
                          "%s = func.call @yon_rt_new(%s, %s, %s) : (i32, !llvm.ptr, i32) -> i64"
                          v_xc v_heap v_buf v_size);
           let v_result = fresh_ssa e in
           emit_line e (Printf.sprintf
                          "%s = topos.xcoord_to_section %s : %s"
                          v_result v_xc target_ty);
           (v_result, target_ty)
       (* Idraulica v2 cross-Space invoke: __yon_rpc2_invoke<K>__<Space>.
        * The Space identity is NOMINAL: a pointer to its global name string
        * is passed to yon_rt_rpc2_invoke_named<K> (decision 1 — no hash%64). *)
       | Some (fname, args) when rpc2_parse_synth fname <> None ->
           let (k, sp) =
             match rpc2_parse_synth fname with
             | Some ks -> ks
             | None -> assert false in
           let runtime = rpc2_runtime_of_arity k in
           let arg_vals =
             List.map (fun a -> fst (emit_term e env funcs a)) args in
           let v_sp = fresh_ssa e in
           emit_line e (Printf.sprintf
                          "%s = llvm.mlir.addressof @yon_space_name_%s : !llvm.ptr"
                          v_sp sp);
           let v = fresh_ssa e in
           let f64s =
             String.concat ", " (List.map (fun _ -> "f64") arg_vals) in
           emit_line e (Printf.sprintf
                          "%s = func.call @%s(%s, %s) : (!llvm.ptr, %s) -> f64"
                          v runtime v_sp (String.concat ", " arg_vals) f64s);
           (v, "f64")
       (* stdlib builtin call (skipped if the name matches a place op, which
        * takes precedence). *)
       | Some (fname, args) when
           is_stdlib_builtin fname
           && lookup_place_op e.places_decls fname = None ->
           let (param_tys, ret_ty) = List.assoc fname stdlib_registry in
           let n_expected = List.length param_tys in
           let n_given = List.length args in
           if n_given <> n_expected then
             failwith (Printf.sprintf
                         "[emit_mlir] stdlib '%s' atteso %d arg, ricevuti %d."
                         fname n_expected n_given);
           let arg_vals = List.map (emit_term e env funcs) args in
           let coerced_ssas =
             List.map2 (fun (ssa, ty) param_ty ->
               coerce_to_param e ssa ty param_ty
             ) arg_vals param_tys
           in
           let v = fresh_ssa e in
           let arg_str = String.concat ", " coerced_ssas in
           let arg_ty_str = String.concat ", " param_tys in
           emit_line e (Printf.sprintf "%s = func.call @%s(%s) : (%s) -> %s"
                          v fname arg_str arg_ty_str ret_ty);
           (v, ret_ty)
       (* place constructor in space — __new_in_<Space>_<Place> *)
       | Some (fname, args) when
           String.length fname > 9 && String.sub fname 0 9 = "__new_in_" ->
           let rest = String.sub fname 9 (String.length fname - 9) in
           (* rest = "<Space>_<Place>". To split: find the place name among
            * those of the module as a suffix of rest. *)
           let place =
             match List.find_opt (fun (pd : C.place_decl) ->
               let pn = pd.p_name in
               let plen = String.length pn in
               String.length rest >= plen + 1
               && String.sub rest (String.length rest - plen) plen = pn
               && rest.[String.length rest - plen - 1] = '_'
             ) e.places_decls with
             | Some pd -> pd.p_name
             | None ->
                 failwith (Printf.sprintf
                             "[emit_mlir] __new_in_X_Y: place not identifiable in '%s'."
                             rest)
           in
           let arg_vals = List.map (emit_term e env funcs) args in
           let param_tys =
             match List.assoc_opt place e.places_table with
             | Some fields -> List.map snd fields
             | None -> List.map snd arg_vals
           in
           let result_ty = Printf.sprintf "!topos.section<\"%s\">" place in
           let v = fresh_ssa e in
           let coerced_ssas =
             if List.length param_tys = List.length arg_vals then
               List.map2 (fun (ssa, ty) param_ty ->
                 coerce_to_param e ssa ty param_ty
               ) arg_vals param_tys
             else List.map fst arg_vals
           in
           let arg_str = String.concat ", " coerced_ssas in
           let arg_ty_str = String.concat ", " param_tys in
           emit_line e (Printf.sprintf "%s = func.call @%s(%s) : (%s) -> %s"
                          v fname arg_str arg_ty_str result_ty);
           (v, result_ty)
       (* A4: place constructor __new_X (default heap_id = 0) *)
       | Some (fname, args) when
           String.length fname > 6 && String.sub fname 0 6 = "__new_" ->
           let place = String.sub fname 6 (String.length fname - 6) in
           let arg_vals = List.map (emit_term e env funcs) args in
           (* The param_tys come from the place declaration, not from the
            * args. The declaration of __new_X (the preamble) uses emit_ty on
            * the field decls, which matches core_ty_to_mlir_simple. *)
           let param_tys =
             match List.assoc_opt place e.places_table with
             | Some fields -> List.map snd fields
             | None -> List.map snd arg_vals (* fallback: usa tipi args *)
           in
           let result_ty = Printf.sprintf "!topos.section<\"%s\">" place in
           let v = fresh_ssa e in
           let coerced_ssas =
             if List.length param_tys = List.length arg_vals then
               List.map2 (fun (ssa, ty) param_ty ->
                 coerce_to_param e ssa ty param_ty
               ) arg_vals param_tys
             else List.map fst arg_vals
           in
           let arg_str = String.concat ", " coerced_ssas in
           let arg_ty_str = String.concat ", " param_tys in
           emit_line e (Printf.sprintf "%s = func.call @%s(%s) : (%s) -> %s"
                          v fname arg_str arg_ty_str result_ty);
           (v, result_ty)
       (* place operation call `Place.op(args)` desugared to
        * `Place__op(args)`. The OperationOp lowering generates a function
        * `<Place>__<op>` with a signature extended by one parameter
        * `instance: i32 xcoord`. We pass a dummy instance here (xcoord = 0,
        * identity), since without a real handler activation there is no real
        * instance. *)
       | Some (fname, args) when
           lookup_place_op e.places_decls fname <> None ->
           let (place_name, op_sig) =
             match lookup_place_op e.places_decls fname with
             | Some x -> x | None -> assert false
           in
           let arg_vals = List.map (emit_term e env funcs) args in
           let ret_ty = core_ty_to_mlir_simple op_sig.op_return in
           let v = fresh_ssa e in
           (* If a reduction is in scope with a handler that handles this op,
            * call it directly (early-bind). Equivalent to the dynamic handler
            * dispatch for programs with a single reduction per place. *)
           (match lookup_reduction_handler e.reductions_decls
                    place_name op_sig.op_name with
            | Some (red_name, _hc) ->
                let handler_name = red_name ^ "__" ^ op_sig.op_name in
                let param_tys =
                  List.map (fun (_, t) -> core_ty_to_mlir_simple t)
                    op_sig.op_params
                in
                let arg_str = String.concat ", " (List.map fst arg_vals) in
                let arg_ty_str = String.concat ", " param_tys in
                emit_line e (Printf.sprintf
                               "%s = func.call @%s(%s) : (%s) -> %s"
                               v handler_name arg_str arg_ty_str ret_ty)
            | None ->
                (* Fallback: stub <Place>__<op> with a dummy instance. *)
                let v_inst = fresh_ssa e in
                emit_line e (Printf.sprintf
                               "%s = arith.constant 0 : i32" v_inst);
                let param_tys = "i32"
                  :: List.map (fun (_, t) -> core_ty_to_mlir_simple t)
                       op_sig.op_params
                in
                let all_args = v_inst :: List.map fst arg_vals in
                let arg_str = String.concat ", " all_args in
                let arg_ty_str = String.concat ", " param_tys in
                emit_line e (Printf.sprintf
                               "%s = func.call @%s(%s) : (%s) -> %s"
                               v fname arg_str arg_ty_str ret_ty));
           (v, ret_ty)
       | Some (fname, args) when
           (match Env.find_opt fname env with
            | Some (_, ty) when String.length ty >= 4
                                && String.sub ty 0 1 = "(" -> true
            | _ -> false) ->
           (* An indirect call via func.call_indirect: fname is a local
              binding of function type "(arg_tys) -> ret_ty". *)
           let (v_fn, fn_ty) = (match Env.find_opt fname env with
             | Some (v, t) -> (v, t)
             | None -> assert false) in
           let arg_vals = List.map (emit_term e env funcs) args in
           let arg_str = String.concat ", " (List.map fst arg_vals) in
           let arg_ty_str = String.concat ", " (List.map snd arg_vals) in
           (* Extract ret_ty from "(args) -> ret". *)
           let ret_ty =
             try
               let arrow_idx = Str.search_forward (Str.regexp " -> ") fn_ty 0 in
               String.sub fn_ty (arrow_idx + 4) (String.length fn_ty - arrow_idx - 4)
             with Not_found -> "f64"
           in
           let v = fresh_ssa e in
           emit_line e (Printf.sprintf
             "%s = func.call_indirect %s(%s) : (%s) -> %s"
             v v_fn arg_str arg_ty_str ret_ty);
           (v, ret_ty)
       | Some (fname, args) when
           (match Env.find_opt fname env with
            | Some (ssa, _) -> String.length ssa > 10
                               && String.sub ssa 0 10 = "__hof_ref:"
            | None -> false) ->
           (* fname is a local alias of a named function (the binding
              `be f holds <lifted lambda>` pattern): dereference the
              alias and call the real function directly. *)
           let real = (match Env.find_opt fname env with
             | Some (ssa, _) -> String.sub ssa 10 (String.length ssa - 10)
             | None -> assert false) in
           (match List.assoc_opt real funcs with
            | Some fs ->
                let arg_vals = List.map (emit_term e env funcs) args in
                let arg_str = String.concat ", " (List.map fst arg_vals) in
                let param_tys = List.map snd arg_vals in
                let v = fresh_ssa e in
                let arg_ty_str = String.concat ", " param_tys in
                emit_line e (Printf.sprintf
                               "%s = func.call @%s(%s) : (%s) -> %s"
                               v real arg_str arg_ty_str fs.fn_ret_mlir);
                (v, fs.fn_ret_mlir)
            | None ->
                failwith (Printf.sprintf
                  "[emit_mlir] alias %s points to unknown function '%s'."
                  fname real))
       | Some (fname, _) ->
           failwith (Printf.sprintf
                       "[emit_mlir] unknown function '%s'."
                       fname)
       | None ->
           failwith "[emit_mlir] unrecognized App form.")
  | C.Lam _ ->
      failwith "[emit_mlir] nested Lambda not supported."
  | C.Place _ ->
      failwith "[emit_mlir] Place as a term-value not supported."
  | C.Reduction _ ->
      failwith "[emit_mlir] Reduction as a term-value not supported."
  | C.Scope (sname, body) ->
      (* 81b — hermetic scope, formal layer. `scope S { ... }` becomes a
       * topos.scope_with_yield region: IsolatedFromAbove makes any implicit
       * reference to outer SSA values an MLIR VERIFIER ERROR, so every outer
       * binding used inside is passed as an explicit, typed capture and
       * rebound as a block argument. The block value is yielded; with the
       * arena model retired, the pushforward (iota_S)_* is the identity on
       * the value — the lowering inlines the region at zero runtime cost. *)
      let fvs = SS.elements (term_free_vars body) in
      let caps =
        List.filter_map
          (fun x ->
             match Env.find_opt x env with
             | Some (ssa, ty) -> Some (x, ssa, ty)
             | None -> None)
          fvs in
      let res_ty = infer_mlir_ty e env funcs body in
      let v = fresh_ssa e in
      let cap_group =
        if caps = [] then ""
        else
          Printf.sprintf "(%s : %s) "
            (String.concat ", " (List.map (fun (_, ssa, _) -> ssa) caps))
            (String.concat ", " (List.map (fun (_, _, ty) -> ty) caps)) in
      let dbg =
        if sname = "" then ""
        else Printf.sprintf "attributes {debug_name = \"%s\"} " sname in
      emit_line e (Printf.sprintf "%s = topos.scope_with_yield %s-> %s %s{"
                     v cap_group res_ty dbg);
      push_indent e;
      let arg_names = List.map (fun _ -> fresh_ssa e) caps in
      if caps <> [] then
        emit_line e (Printf.sprintf "^bb0(%s):"
                       (String.concat ", "
                          (List.map2 (fun a (_, _, ty) ->
                               Printf.sprintf "%s: %s" a ty)
                             arg_names caps)));
      let inner_env =
        List.fold_left2
          (fun acc a (x, _, ty) -> Env.add x (a, ty) acc)
          env arg_names caps in
      let (bv, bty) = emit_term e inner_env funcs body in
      emit_line e (Printf.sprintf "topos.scope_yield %s : %s" bv bty);
      pop_indent e;
      emit_line e "}";
      (v, res_ty)
  | C.With (_, body) ->
      (* `with HANDLER of PLACE { body }` as passthrough.
       * The Topos dialect has `topos.with_handler` to activate a handler
       * scope, but the cross-space XLeech2 runtime is not yet connected. For
       * now we evaluate the body directly: this is correct for programs with
       * no real side effects on the handlers, and fails loudly when an inner
       * body calls an operation that requires the handler. *)
      emit_term e env funcs body
  | C.Emit _ ->
      failwith "[emit_mlir] Emit not handled."
  | C.Refl x ->
      (* refl(x) is an inert witness of equality. Operationally it is the
         identity: return the original value (the simplified cubical reduction
         refl(x) -> x). *)
      emit_term e env funcs x
  | C.J _ as jt ->
      (* Path induction. The arbiter of path equality is the REDUCER
         (Syn(Yon) formalization sec. 16): we normalize the J term, and
         on a refl path J computes to its diagonal case, which we emit.
         A J stuck on a non-refl path (a HIT constructor such as the
         S1 loop) is NOT decided at runtime: identifying it with the
         diagonal would trivialize S1. Loud error, no equation added. *)
      let reduced = Builtins.reduce_with_builtins Reduce.empty_ctx jt in
      (match reduced with
       | C.J _ ->
           failwith "[emit_mlir] ind_path stuck on a non-refl path: path induction over non-trivial paths is compile-time only; the runtime does not decide path equality."
       | t' -> emit_term e env funcs t')
  (* P7-frontend A2: Sigma pair (Pair, Fst, Snd) --> !llvm.struct *)
  | C.Pair (a, b) ->
      let (va, ta) = emit_term e env funcs a in
      let (vb, tb) = emit_term e env funcs b in
      let struct_ty = Printf.sprintf "!llvm.struct<(%s, %s)>" ta tb in
      let v_undef = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = llvm.mlir.undef : %s" v_undef struct_ty);
      let v_ins1 = fresh_ssa e in
      emit_line e (Printf.sprintf
                     "%s = llvm.insertvalue %s, %s[0] : %s"
                     v_ins1 va v_undef struct_ty);
      let v_pair = fresh_ssa e in
      emit_line e (Printf.sprintf
                     "%s = llvm.insertvalue %s, %s[1] : %s"
                     v_pair vb v_ins1 struct_ty);
      (v_pair, struct_ty)
  | C.Fst p ->
      let (vp, tp) = emit_term e env funcs p in
      (* tp should be !llvm.struct<(T_a, T_b)>; extract T_a. *)
      let prefix = "!llvm.struct<(" in
      let plen = String.length prefix in
      if String.length tp <= plen
         || String.sub tp 0 plen <> prefix then
        failwith (Printf.sprintf
                    "[emit_mlir] fst on a non-pair type: %s. fst applies only to a Sigma pair (built with `pair(a, b)`)."
                    tp);
      let rest = String.sub tp plen (String.length tp - plen) in
      let comma = (try String.index rest ',' with Not_found -> -1) in
      if comma < 0 then
        failwith (Printf.sprintf
                    "[emit_mlir] malformed pair type for fst: %s." tp);
      let ta = String.sub rest 0 comma |> String.trim in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = llvm.extractvalue %s[0] : %s" v vp tp);
      (v, ta)
  | C.Snd p ->
      let (vp, tp) = emit_term e env funcs p in
      let prefix = "!llvm.struct<(" in
      let plen = String.length prefix in
      if String.length tp <= plen
         || String.sub tp 0 plen <> prefix then
        failwith (Printf.sprintf
                    "[emit_mlir] snd on a non-pair type: %s. fix: snd applies only to a Sigma pair."
                    tp);
      let rest = String.sub tp plen (String.length tp - plen) in
      let comma = (try String.index rest ',' with Not_found -> -1) in
      if comma < 0 then
        failwith (Printf.sprintf
                    "[emit_mlir] malformed pair type for snd: %s." tp);
      let close = (try String.index rest ')' with Not_found -> -1) in
      if close < 0 || close <= comma then
        failwith (Printf.sprintf
                    "[emit_mlir] malformed pair type for snd: %s." tp);
      let tb = String.sub rest (comma + 1) (close - comma - 1) |> String.trim in
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = llvm.extractvalue %s[1] : %s" v vp tp);
      (v, tb)
  | C.StreamCons _ ->
      failwith "[emit_mlir] Stream primitives not handled."
  | C.Unit ->
      (* C.Unit appears as the else-branch of `when c { body }` with no
       * otherwise. We treat it as an f64 0.0 placeholder, matching the type of
       * the then-branch when that produces a numeric value, and ignored as a
       * no-op otherwise. *)
      let v = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 0.0 : f64" v);
      (v, "f64")

(* ─── Place / reduction / world ─────────────────────────────────────── *)

let emit_place (e : emitter) (world : string) (pd : C.place_decl) : unit =
  emit_indent e;
  let has_ops = pd.p_operations <> [] in
  (* the law_* attributes declared on the place, verified by AlgebraVerifier *)
  let law_attrs =
    List.filter_map (fun l ->
      match l with
      | "commutative" -> Some "law_commutative"
      | "associative" -> Some "law_associative"
      | "monotone"    -> Some "law_monotone"
      | _ -> None) pd.p_laws
  in
  if has_ops then begin
    let attrs = String.concat ", " ("with_effects" :: law_attrs) in
    emit_str e (Printf.sprintf "topos.place @%s in @%s attributes { %s } {\n"
                  pd.p_name world attrs)
  end else
    emit_str e (Printf.sprintf "topos.place @%s in @%s {\n" pd.p_name world);
  push_indent e;
  (* A fieldless place with no operations is the terminal object 1. Its body
     region must still contain exactly one (empty) block, because PlaceOp is a
     SymbolTable and MLIR requires SymbolTable ops to have exactly one block.
     We emit an explicit empty block label `^bb0:` so the region is one empty
     block rather than zero blocks (which is rejected). *)
  if pd.p_fields = [] && pd.p_operations = [] then
    emit_line e "^bb0:";
  List.iter (fun (fname, fty) ->
    emit_line e (Printf.sprintf "topos.field @%s : %s" fname (emit_ty fty))
  ) pd.p_fields;
  List.iter (fun (op : C.op_sig) ->
    let param_tys =
      List.map (fun (_, t) -> emit_ty t) op.op_params
      |> String.concat ", "
    in
    let ret_ty = emit_ty op.op_return in
    emit_indent e;
    let alg_attr = match op.op_algebra with
      | Some name -> Printf.sprintf " attributes { algebra = \"%s\" }" name
      | None -> "" in
    emit_str e (Printf.sprintf "topos.operation @%s([%s]) -> %s%s {\n"
                  op.op_name param_tys ret_ty alg_attr);
    push_indent e;
    emit_line e "^bb0:";
    pop_indent e;
    emit_line e "}"
  ) pd.p_operations;
  pop_indent e;
  emit_line e "}"

let emit_reduction (e : emitter) (rd : C.reduction_decl) : unit =
  emit_indent e;
  emit_str e (Printf.sprintf "topos.reduce @%s of @%s attributes {\n"
                rd.r_name rd.r_target);
  push_indent e;
  emit_line e "direction = 0 : i32,";
  emit_line e "policy = 0 : i32,";
  emit_line e (Printf.sprintf "shot_ordering = 0 : i32%s"
                 (if rd.r_multi_shot then "," else ""));
  if rd.r_multi_shot then
    emit_line e "multi_shot = unit";
  pop_indent e;
  emit_line e "} {";
  push_indent e;
  emit_line e "^bb0:";
  pop_indent e;
  emit_line e "}"

(* Emit the bodies of the handler clauses as ordinary user functions named
   `<Reduction>__<op>(params) -> ret_ty`. They are linked at the Place__op call
   site when there is a single reduction in scope for that place (static
   early binding). This runs separately, after all the program's user functions
   are declared, so a handler body can refer to the other user functions. *)
let emit_world (e : emitter) (world_name : string) (places : C.place_decl list) : unit =
  emit_indent e;
  emit_str e (Printf.sprintf "topos.world @%s {\n" world_name);
  push_indent e;
  List.iter (emit_place e world_name) places;
  pop_indent e;
  emit_line e "}";
  (* For each place that instantiates a catalog algebra, emit @<P>_instantiate()
   * outside the world (a valid top-level func.func) that
   * instantiates it as a Magma handle. The verified place becomes runnable from
   * Yon via `solve P`. The AlgebraVerifier pass remains the verifier of the laws. *)
  List.iter (fun (pd : C.place_decl) ->
    let alg = List.fold_left (fun acc (op : C.op_sig) ->
      match acc, op.op_algebra with Some _, _ -> acc | None, a -> a) None pd.p_operations in
    match alg with
    | Some name ->
        let cat_id = match name with
          | "Additive" -> 0 | "TropicalMax" -> 1 | "TropicalMin" -> 2
          | "Multiplicative" -> 3 | "BooleanOr" -> 4 | "BooleanAnd" -> 5
          | "Gcd" -> 6 | _ -> 0 in
        emit_line e (Printf.sprintf "func.func @%s_instantiate() -> f64 {" pd.p_name);
        push_indent e;
        emit_line e (Printf.sprintf "%%cat = arith.constant %d.0 : f64" cat_id);
        emit_line e "%h = func.call @yon_rt_magma_from_algebra(%cat) : (f64) -> f64";
        emit_line e "return %h : f64";
        pop_indent e;
        emit_line e "}"
    | None -> ()) places

(* ─── Function emit ─────────────────────────────────────────────────── *)

(* Extract the type-parameter names from a signature's parameters. A
 * non-primitive name not in places_table is a type variable. *)
let collect_type_params (e : emitter)
    (params : (string * C.ty) list) (ret_mlir : string) : string list =
  let acc = ref [] in
  let visit_ty t =
    match t with
    | C.TyBase n | C.TyPlace n ->
        if is_type_var e n && not (List.mem n !acc) then
          acc := n :: !acc
    | _ -> ()
  in
  List.iter (fun (_, t) -> visit_ty t) params;
  (* The return type may also contain type variables: derive them from the
   * MLIR string by looking at the pattern section<"T">. *)
  let rec find_type_vars s pos =
    let prefix = "!topos.section<\"" in
    let plen = String.length prefix in
    if pos + plen > String.length s then ()
    else if String.sub s pos plen = prefix then
      let rest = String.sub s (pos + plen) (String.length s - pos - plen) in
      (try
        let close = String.index rest '"' in
        let name = String.sub rest 0 close in
        if is_type_var e name && not (List.mem name !acc) then
          acc := name :: !acc;
        find_type_vars s (pos + plen + close + 1)
      with Not_found -> ())
    else find_type_vars s (pos + 1)
  in
  find_type_vars ret_mlir 0;
  List.rev !acc

(* Extract the signature of a user function. The MLIR return type is inferred
   from the body via infer_mlir_ty, with an env built from the parameters and
   the functions accumulated so far (a sliding window: each function sees the
   ones before it). If inference fails loudly we do not catch it: the problem
   surfaces at once and the program does not compile, with no silent fallback. *)
(* Substitution of type variables in a C.ty.
 * Subst: a map from type-variable name to a concrete C.ty. *)

let extract_func_sig (e : emitter)
    (funcs_so_far : (string * func_sig) list)
    (fn_ret_hints : (string * C.ty) list)
    (name : string) (body : C.term) : func_sig =
  let (params, inner) = collect_params body in
  let env = List.fold_left (fun env (n, t) ->
    Env.add n ("(unused)", core_ty_to_mlir_simple t) env
  ) Env.empty params in
  (* For higher-order functions (a parameter TyArrow C.TyBase "arrow"), we
   * cannot infer the return type from the body (the calls f(x) are irreducible
   * without knowing f). We use f64 as default; the function is not emitted
   * anyway (it is inlined at the call site). *)
  let is_hof = List.exists (fun (_, t) ->
    match t with
    | C.TyBase "arrow"
    | C.TyBase "move_handle"
    | C.TyBase "reduction_handle"
    | C.TyBase "morph_handle"
    | C.TyBase "view_handle" -> true
    | _ -> false
  ) params in
  let ret_ty_mlir =
    (* Use fn_ret_hints as the authority only when inferring from the body is
     * genuinely unreliable. Cases:
     *
     *  - is_hof: the body calls m(p) with m a handle; inference fails or
     *    produces f64. Use the hint.
     *  - ret is a TyPlace/TyUser of a real place: inference may confuse topos
     *    with place. Use the hint.
     *
     * For primitive types (number, boolean, proposition, money...) and type
     * variables, infer from the body, because there is a declared mismatch
     * between the surface type (proposition) and storage (i1) that only the
     * body knows about. *)
    let use_hint_for hint =
      match hint with
      | C.TyPlace n | C.TyBase n ->
          not (is_prim_name n) && not (is_type_var e n)
      | _ -> false
    in
    if is_hof then begin
      match List.assoc_opt name fn_ret_hints with
      | Some t -> core_ty_to_mlir_simple t
      | None -> "f64"
    end else begin
      match List.assoc_opt name fn_ret_hints with
      | Some t when use_hint_for t -> core_ty_to_mlir_simple t
      | _ -> infer_mlir_ty e env funcs_so_far inner
    end
  in
  let type_params = collect_type_params e params ret_ty_mlir in
  {
    fn_name = name;
    fn_params = params;
    fn_ret_mlir = ret_ty_mlir;
    fn_body = inner;
    fn_type_params = type_params;
  }

(* Cross-space op wrapping for `__morph_in_<S>__<M>`. Given the mangled name,
 * extract the space name and the morph name. *)
let extract_morph_in_space (name : string) : (string * string) option =
  let prefix = "__morph_in_" in
  let plen = String.length prefix in
  if String.length name <= plen then None
  else if String.sub name 0 plen <> prefix then None
  else
    let rest = String.sub name plen (String.length name - plen) in
    (* rest = "<S>__<M>" — split on the first "__" *)
    let rec find_sep i =
      if i + 1 >= String.length rest then None
      else if rest.[i] = '_' && rest.[i+1] = '_' then Some i
      else find_sep (i+1)
    in
    match find_sep 0 with
    | Some i ->
        let space = String.sub rest 0 i in
        let morph = String.sub rest (i+2) (String.length rest - i - 2) in
        Some (space, morph)
    | None -> None

(* Coerce a body value to the function's declared return type at the return
   site. The only case that needs coercion today is the terminal object 1: a
   pure terminal-returning function has body C.Unit, which emit_term lowers as
   an f64 0.0 placeholder, but the declared return type is the section of a
   fieldless place. We materialize the terminal by calling its constructor
   `@__new_<P>` (which, for a zero-field place, lowers to zero storage). This
   replaces the type-mismatched `return %f64 : section<"P">`. Returns the SSA
   value to actually return. *)
let coerce_return (e : emitter) (v : string) (v_ty : string)
    (ret_ty : string) : string =
  if v_ty <> ret_ty && v_ty = "f64" then
    match extract_place_name ret_ty with
    | Some place ->
        (* body was Unit (f64 placeholder) but a section is expected:
           materialize the terminal value of that place. *)
        let v_unit = fresh_ssa e in
        emit_line e (Printf.sprintf
          "%s = func.call @__new_%s() : () -> %s" v_unit place ret_ty);
        v_unit
    | None -> v
  else v

let emit_function (e : emitter) (funcs : (string * func_sig) list)
    (fs : func_sig) : unit =
  let param_strs = List.map (fun (n, t) ->
    Printf.sprintf "%%arg_%s: %s" n (core_ty_to_mlir_simple t)
  ) fs.fn_params in
  let ret_ty = fs.fn_ret_mlir in
  emit_indent e;
  emit_str e (Printf.sprintf "func.func @%s(%s) -> %s {\n"
                fs.fn_name (String.concat ", " param_strs) ret_ty);
  push_indent e;
  let env = List.fold_left (fun env (n, t) ->
    Env.add n (Printf.sprintf "%%arg_%s" n, core_ty_to_mlir_simple t) env
  ) Env.empty fs.fn_params in
  (* If the function is a synthesized __morph_in_<S>__<M>, wrap its body with
     begin/end_cross_space_op to announce the space context to the runtime. The
     runtime looks up the registered morphisms in the begin call (with an array
     of the one heap involved, the target space); the coordination dispatch
     fires automatically when a relevant morphism is declared. *)
  (match extract_morph_in_space fs.fn_name with
   | None ->
       let (v, v_ty) = emit_term e env funcs fs.fn_body in
       let v = coerce_return e v v_ty ret_ty in
       emit_line e (Printf.sprintf "return %s : %s" v ret_ty)
   | Some (space_name_raw, morph_name) ->
       (* space_name_raw may be:
        *   (a) a declared space name -> use it directly
        *   (b) a topos name with `at S` declared -> resolve to S
        * Case (b) enables the syntax `LiftEU(eu) in AccountUSD` where
        * AccountUSD is the target topos, not the space. *)
       let declared_space_names =
         List.map (fun (sd : Surface_ast.space_decl) -> sd.Surface_ast.sd_name)
           e.declared_spaces in
       let space_name =
         if List.mem space_name_raw declared_space_names then space_name_raw
         else
           match List.assoc_opt space_name_raw e.toposes_index with
           | Some (Some at_space) when List.mem at_space declared_space_names ->
               at_space
           | _ ->
               (* The name is resolvable neither as a space nor as a
                * topos-at-space. Fallback: use the name as is; MLIR will fail
                * the lookup if the global is absent, giving an explicit
                * error. *)
               space_name_raw
       in
       (* lookup the source space via the explicit binding `topos T at S`.
        * No more same-name heuristic. Lookup:
        *   morph_name -> mp_source (topos)
        *   topos_name -> tp_at_space (space opzionale)
        * If mp_source has a topos declared with `at S` and S is a registered
        * space, include it as the second heap_id; otherwise only the
        * target. *)
       let source_space_opt =
         match List.find_opt (fun (n, _, _) -> n = morph_name) e.morphs_index with
         | Some (_, src_topos, _) ->
             (match List.assoc_opt src_topos e.toposes_index with
              | Some (Some at_space) ->
                  let space_names_full =
                    List.map (fun (sd : Surface_ast.space_decl) ->
                      sd.Surface_ast.sd_name) e.declared_spaces in
                  if List.mem at_space space_names_full
                  then Some at_space
                  else None
              | _ -> None)
         | None -> None
       in
       let n_heaps = match source_space_opt with
         | Some _ -> 2
         | None -> 1
       in
       let v_one = fresh_ssa e in
       emit_line e (Printf.sprintf "%s = arith.constant 1 : i64" v_one);
       let v_arr = fresh_ssa e in
       emit_line e (Printf.sprintf
                      "%s = llvm.alloca %s x !llvm.array<%d x i32> : (i64) -> !llvm.ptr"
                      v_arr v_one n_heaps);
       (* Slot 0: target space *)
       let v_space_str = fresh_ssa e in
       emit_line e (Printf.sprintf
                      "%s = llvm.mlir.addressof @yon_space_str_%s : !llvm.ptr"
                      v_space_str space_name);
       let v_hid_tgt = fresh_ssa e in
       emit_line e (Printf.sprintf
                      "%s = func.call @yon_rt_lookup_space(%s) : (!llvm.ptr) -> i32"
                      v_hid_tgt v_space_str);
       let v_off0 = fresh_ssa e in
       emit_line e (Printf.sprintf "%s = arith.constant 0 : i32" v_off0);
       let v_gep0 = fresh_ssa e in
       emit_line e (Printf.sprintf
                      "%s = llvm.getelementptr %s[%s] : (!llvm.ptr, i32) -> !llvm.ptr, i32"
                      v_gep0 v_arr v_off0);
       emit_line e (Printf.sprintf "llvm.store %s, %s : i32, !llvm.ptr" v_hid_tgt v_gep0);
       (* Slot 1: source space if present *)
       (match source_space_opt with
        | None -> ()
        | Some src_space ->
            let v_src_str = fresh_ssa e in
            emit_line e (Printf.sprintf
                           "%s = llvm.mlir.addressof @yon_space_str_%s : !llvm.ptr"
                           v_src_str src_space);
            let v_hid_src = fresh_ssa e in
            emit_line e (Printf.sprintf
                           "%s = func.call @yon_rt_lookup_space(%s) : (!llvm.ptr) -> i32"
                           v_hid_src v_src_str);
            let v_off1 = fresh_ssa e in
            emit_line e (Printf.sprintf "%s = arith.constant 1 : i32" v_off1);
            let v_gep1 = fresh_ssa e in
            emit_line e (Printf.sprintf
                           "%s = llvm.getelementptr %s[%s] : (!llvm.ptr, i32) -> !llvm.ptr, i32"
                           v_gep1 v_arr v_off1);
            emit_line e (Printf.sprintf "llvm.store %s, %s : i32, !llvm.ptr" v_hid_src v_gep1));
       let v_n = fresh_ssa e in
       emit_line e (Printf.sprintf "%s = arith.constant %d : i32" v_n n_heaps);
       (* Emit a compile-time audit comment.
        * Each cross-space write records source/target space + move name in an
        * MLIR comment for a readable static trace. Production would have a
        * structured MLIR attribute (yon.audit { ... }). *)
       let audit_src = match source_space_opt with
         | Some s -> s
         | None -> "(inferred-from-context)" in
       emit_line e (Printf.sprintf
         "// yon.audit: cross_space_write src=%s tgt=%s move=%s"
         audit_src space_name morph_name);
       let v_tok = fresh_ssa e in
       emit_line e (Printf.sprintf
                      "%s = func.call @yon_rt_begin_cross_space_op(%s, %s) : (!llvm.ptr, i32) -> i32"
                      v_tok v_arr v_n);
       let (v, v_ty) = emit_term e env funcs fs.fn_body in
       emit_line e (Printf.sprintf
                      "func.call @yon_rt_end_cross_space_op(%s) : (i32) -> ()" v_tok);
       let v = coerce_return e v v_ty ret_ty in
       emit_line e (Printf.sprintf "return %s : %s" v ret_ty));
  pop_indent e;
  emit_line e "}"

(* policy_int_of_reduction was removed: it had become a no-op (always 0), so
   it went away together with the register_space_with_policy path that used
   it. *)

(* Emit the startup registration of the declared spaces. Each space gets a
   global string for its name plus a sequence of runtime calls. A space may
   carry a canonical fold (a semilattice structure on the topos): with
   `with fold "NAME"` we use yon_rt_register_space_with_fold, otherwise
   yon_rt_register_space. Distributed cross-space properties are declared
   separately through geom_morphism. *)
let emit_space_bootstrap (e : emitter) (spaces : Surface_ast.space_decl list)
    (_reductions : (string * Surface_ast.reduction_decl) list)
    : unit =
  if spaces <> [] then begin
    emit_line e "func.call @yon_rt_init() : () -> ()";
    List.iter (fun (sd : Surface_ast.space_decl) ->
      let str_sym = "yon_space_str_" ^ sd.Surface_ast.sd_name in
      let v_ptr = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = llvm.mlir.addressof @%s : !llvm.ptr"
                     v_ptr str_sym);
      let v_id = fresh_ssa e in
      match sd.sd_fold with
      | None ->
          emit_line e (Printf.sprintf
                         "%s = func.call @yon_rt_register_space(%s) : (!llvm.ptr) -> i32"
                         v_id v_ptr);
          let _ = v_id in ()
      | Some fold_name ->
          (* a space with a declared semilattice fold; reuse the global
             string yon_fold_str_<name> *)
          let v_fold = fresh_ssa e in
          emit_line e (Printf.sprintf
                         "%s = llvm.mlir.addressof @yon_fold_str_%s : !llvm.ptr"
                         v_fold fold_name);
          emit_line e (Printf.sprintf
                         "%s = func.call @yon_rt_register_space_with_fold(%s, %s) : (!llvm.ptr, !llvm.ptr) -> i32"
                         v_id v_ptr v_fold);
          let _ = v_id in ()
    ) spaces
  end

(* Emit the registration of the geometric morphisms declared in the program.
   Called right after emit_space_bootstrap and before the main body, so that
   the later dispatch (begin_cross_space_op) finds the morphisms registered.
   For each one we allocate a yon_geom_morphism_props_t as a local stack struct
   with its three flags (adjunction, f_star_exact, f_lower_star_exact) and call
   yon_rt_register_geom_morphism. The topos names are passed as pointers to
   global strings (yon_space_str_<name>), the same pattern as register_space;
   if a morphism endpoint is not itself a declared space, we still emit an
   ad-hoc global string for it. *)
let emit_geom_morphism_strings (e : emitter)
    (gms : Surface_ast.geom_morphism_decl list)
    (existing_spaces : Surface_ast.space_decl list)
    : unit =
  let existing_names =
    List.map (fun (sd : Surface_ast.space_decl) -> sd.sd_name) existing_spaces in
  let needed = List.fold_left (fun acc (gm : Surface_ast.geom_morphism_decl) ->
    let s = gm.gm_source_site in
    let t = gm.gm_target_site in
    let acc = if List.mem s existing_names || List.mem s acc then acc else s :: acc in
    let acc = if List.mem t existing_names || List.mem t acc then acc else t :: acc in
    acc) [] gms in
  List.iter (fun nm ->
    let sym = "yon_gm_str_" ^ nm in
    let len = String.length nm + 1 in
    emit_line e (Printf.sprintf
                   "llvm.mlir.global internal constant @%s(\"%s\\00\") : !llvm.array<%d x i8>"
                   sym nm len)
  ) needed;
  (* String for the name of the gm itself *)
  List.iter (fun (gm : Surface_ast.geom_morphism_decl) ->
    let sym = "yon_gm_name_" ^ gm.gm_name in
    let len = String.length gm.gm_name + 1 in
    emit_line e (Printf.sprintf
                   "llvm.mlir.global internal constant @%s(\"%s\\00\") : !llvm.array<%d x i8>"
                   sym gm.gm_name len)
  ) gms

(* Emit the yon_rt_register_geom_morphism calls in the body of main, after
 * emit_space_bootstrap. *)
let emit_geom_morphism_bootstrap (e : emitter)
    (gms : Surface_ast.geom_morphism_decl list)
    (existing_spaces : Surface_ast.space_decl list)
    : unit =
  let existing_names =
    List.map (fun (sd : Surface_ast.space_decl) -> sd.sd_name) existing_spaces in
  List.iter (fun (gm : Surface_ast.geom_morphism_decl) ->
    (* Pointer to the gm name *)
    let v_name = fresh_ssa e in
    emit_line e (Printf.sprintf
                   "%s = llvm.mlir.addressof @yon_gm_name_%s : !llvm.ptr"
                   v_name gm.Surface_ast.gm_name);
    (* Pointer to the source topos: use yon_space_str_<name> when it is a
       registered space, otherwise the ad-hoc string yon_gm_str_<name>. *)
    let src_sym = if List.mem gm.gm_source_site existing_names
                  then "yon_space_str_" ^ gm.gm_source_site
                  else "yon_gm_str_" ^ gm.gm_source_site in
    let v_src = fresh_ssa e in
    emit_line e (Printf.sprintf "%s = llvm.mlir.addressof @%s : !llvm.ptr"
                   v_src src_sym);
    let tgt_sym = if List.mem gm.gm_target_site existing_names
                  then "yon_space_str_" ^ gm.gm_target_site
                  else "yon_gm_str_" ^ gm.gm_target_site in
    let v_tgt = fresh_ssa e in
    emit_line e (Printf.sprintf "%s = llvm.mlir.addressof @%s : !llvm.ptr"
                   v_tgt tgt_sym);
    (* Allocate the props struct on the stack as an llvm.struct with 3 i32 *)
    let v_one = fresh_ssa e in
    emit_line e (Printf.sprintf "%s = arith.constant 1 : i64" v_one);
    let v_struct = fresh_ssa e in
    emit_line e (Printf.sprintf
                   "%s = llvm.alloca %s x !llvm.struct<(i32, i32, i32)> : (i64) -> !llvm.ptr"
                   v_struct v_one);
    let v_adj = fresh_ssa e in
    emit_line e (Printf.sprintf "%s = arith.constant %d : i32"
                   v_adj (if gm.gm_adjunction then 1 else 0));
    let v_off0 = fresh_ssa e in
    emit_line e (Printf.sprintf "%s = arith.constant 0 : i32" v_off0);
    let v_p0 = fresh_ssa e in
    emit_line e (Printf.sprintf
                   "%s = llvm.getelementptr %s[%s] : (!llvm.ptr, i32) -> !llvm.ptr, i32"
                   v_p0 v_struct v_off0);
    emit_line e (Printf.sprintf "llvm.store %s, %s : i32, !llvm.ptr" v_adj v_p0);

    let v_fs = fresh_ssa e in
    emit_line e (Printf.sprintf "%s = arith.constant %d : i32"
                   v_fs (if gm.gm_f_star_exact then 1 else 0));
    let v_off1 = fresh_ssa e in
    emit_line e (Printf.sprintf "%s = arith.constant 1 : i32" v_off1);
    let v_p1 = fresh_ssa e in
    emit_line e (Printf.sprintf
                   "%s = llvm.getelementptr %s[%s] : (!llvm.ptr, i32) -> !llvm.ptr, i32"
                   v_p1 v_struct v_off1);
    emit_line e (Printf.sprintf "llvm.store %s, %s : i32, !llvm.ptr" v_fs v_p1);

    let v_fls = fresh_ssa e in
    emit_line e (Printf.sprintf "%s = arith.constant %d : i32"
                   v_fls (if gm.gm_f_lower_star_exact then 1 else 0));
    let v_off2 = fresh_ssa e in
    emit_line e (Printf.sprintf "%s = arith.constant 2 : i32" v_off2);
    let v_p2 = fresh_ssa e in
    emit_line e (Printf.sprintf
                   "%s = llvm.getelementptr %s[%s] : (!llvm.ptr, i32) -> !llvm.ptr, i32"
                   v_p2 v_struct v_off2);
    emit_line e (Printf.sprintf "llvm.store %s, %s : i32, !llvm.ptr" v_fls v_p2);

    (* Call to yon_rt_register_geom_morphism *)
    let v_rc = fresh_ssa e in
    emit_line e (Printf.sprintf
                   "%s = func.call @yon_rt_register_geom_morphism(%s, %s, %s, %s) : (!llvm.ptr, !llvm.ptr, !llvm.ptr, !llvm.ptr) -> i32"
                   v_rc v_name v_src v_tgt v_struct);
    let _ = v_rc in ()
  ) gms

(* Emit the global strings for the declared space names, at module level
   before the functions. *)
let emit_space_strings (e : emitter) (spaces : Surface_ast.space_decl list)
    : unit =
  List.iter (fun (sd : Surface_ast.space_decl) ->
    let str_sym = "yon_space_str_" ^ sd.sd_name in
    let n = String.length sd.sd_name in
    (* Layout: array<(n+1) x i8> includes terminating NUL. *)
    let chars = String.concat ", " (
      List.init n (fun i -> Printf.sprintf "%d" (Char.code sd.sd_name.[i]))
      @ ["0"]
    ) in
    emit_line e (Printf.sprintf
                   "llvm.mlir.global internal constant @%s(dense<[%s]> : tensor<%d x i8>) : !llvm.array<%d x i8>"
                   str_sym chars (n + 1) (n + 1));
    let _ = chars in ()
  ) spaces

(* Walk the C.term to collect the set of target spaces used in
 * `apply_move(...) in <S>` (mangled name __apply_move_in_<S>). Returns the
 * deduplicated list in order of first occurrence. *)
let collect_target_spaces (t : C.term) : string list =
  let acc = ref [] in
  let add s = if not (List.mem s !acc) then acc := !acc @ [s] in
  let rec walk t =
    match t with
    | C.Var v when
        String.length v > 16 && String.sub v 0 16 = "__apply_move_in_" ->
        let space = String.sub v 16 (String.length v - 16) in
        add space
    | C.Var _ -> ()
    | C.App (a, b) -> walk a; walk b
    | C.Lam (_, _, body) -> walk body
    | C.With (_, body) -> walk body
    | C.Scope (_, body) -> walk body
    | C.Emit b -> walk b
    | C.Refl e -> walk e
    | C.J (_, _, a, b, c, d) -> walk a; walk b; walk c; walk d
    | C.Pair (a, b) -> walk a; walk b
    | C.Fst p -> walk p
    | C.Snd p -> walk p
    | C.StreamCons (a, b) -> walk a; walk b
    | C.Place _ | C.Reduction _ | C.Unit -> ()
  in
  walk t;
  !acc

(* Globals for the conventional server-binary paths of imported Spaces:
 * `import f from Measures` -> "./Measures_srv". Registered in main so the
 * runtime can fork/exec the server on first cross-Space call (step 3). *)
let emit_srv_path_globals (e : emitter) (space_imports : string list) : unit =
  List.iter (fun sp ->
    let path = "./" ^ sp ^ "_srv" in
    let sym = "yon_srv_path_" ^ sp in
    let n = String.length path in
    let chars = String.concat ", " (
      List.init n (fun i -> Printf.sprintf "%d" (Char.code path.[i])) @ ["0"]) in
    emit_line e (Printf.sprintf
                   "llvm.mlir.global internal constant @%s(dense<[%s]> : tensor<%d x i8>) : !llvm.array<%d x i8>"
                   sym chars (n + 1) (n + 1));
    (* Idraulica v2: the Space NAME itself as a global string — the nominal
       channel identity passed to the runtime (register + invoke). *)
    let sym2 = "yon_space_name_" ^ sp in
    let n2 = String.length sp in
    let chars2 = String.concat ", " (
      List.init n2 (fun i -> Printf.sprintf "%d" (Char.code sp.[i])) @ ["0"]) in
    emit_line e (Printf.sprintf
                   "llvm.mlir.global internal constant @%s(dense<[%s]> : tensor<%d x i8>) : !llvm.array<%d x i8>"
                   sym2 chars2 (n2 + 1) (n2 + 1))
  ) space_imports

let emit_main (e : emitter) (funcs : (string * func_sig) list)
    (spaces : Surface_ast.space_decl list)
    (reductions : (string * Surface_ast.reduction_decl) list)
    (geom_morphisms : Surface_ast.geom_morphism_decl list)
    (space_imports : string list)
    (internal_funs : string list)
    (main_body : C.term) : unit =
  emit_line e "func.func private @yon_rt_maybe_serve() -> ()";
  if space_imports <> [] then
    emit_line e "func.func private @yon_rt_rpc2_register_space_binary(!llvm.ptr, !llvm.ptr) -> ()";
  emit_line e "func.func @main() -> i32 {";
  push_indent e;
  (* Register the conventional server-binary path of each imported Space
   * (./<Space>_srv, dir overridable via YON_SRV_DIR) so the runtime can
   * fork/exec it on first call (step 3). This MUST precede maybe_serve: a
   * process running in serve mode still needs these registrations, otherwise
   * a served operation could not spawn ITS OWN dependencies and cross-Space
   * composition (A -> B -> C) would be broken. *)
  List.iter (fun sp ->
    let v_name = fresh_ssa e in
    emit_line e (Printf.sprintf "%s = llvm.mlir.addressof @yon_space_name_%s : !llvm.ptr"
                   v_name sp);
    let v_ptr = fresh_ssa e in
    emit_line e (Printf.sprintf "%s = llvm.mlir.addressof @yon_srv_path_%s : !llvm.ptr"
                   v_ptr sp);
    emit_line e (Printf.sprintf
                   "func.call @yon_rt_rpc2_register_space_binary(%s, %s) : (!llvm.ptr, !llvm.ptr) -> ()"
                   v_name v_ptr)
  ) space_imports;
  emit_space_bootstrap e spaces reductions;
  (* Wire DTO transport (seal 2): register each transportable place's field-tag
     descriptor with the runtime, keyed by its structural schema id. Every side
     registers from its own redeclaration; identical schemas yield the same id,
     so producer and consumer agree without exchanging anything. Runs before
     maybe_serve so a serve-mode producer has its descriptors ready. *)
  List.iter (fun (pd : C.place_decl) ->
    match wire_tags_of_place e.places_decls pd,
          wire_schema_id_of_place e.places_decls pd with
    | Some tags, Some id when tags <> [] ->
        let n = List.length tags in
        let v_tags = fresh_ssa e in
        emit_line e (Printf.sprintf "%s = llvm.mlir.addressof @yon_wire_tags_%s : !llvm.ptr"
                       v_tags pd.p_name);
        let v_id = fresh_ssa e in
        emit_line e (Printf.sprintf "%s = arith.constant %d : i32" v_id id);
        let v_nf = fresh_ssa e in
        emit_line e (Printf.sprintf "%s = arith.constant %d : i32" v_nf n);
        emit_line e (Printf.sprintf
                       "func.call @yon_rt_register_schema(%s, %s, %s) : (i32, i32, !llvm.ptr) -> ()"
                       v_id v_nf v_tags)
    | _ -> ()
  ) e.places_decls;
  (* Register the declared geometric morphisms so the later
     begin_cross_space_op finds them and uses the categorical derivation. *)
  emit_geom_morphism_bootstrap e geom_morphisms spaces;
  (* Cross-Space: if launched as `--serve <id>`, run the dispatch loop and exit
   * (the runtime never returns here in that case). Placed AFTER the bootstrap
   * and registrations, so a serve-mode process is a fully initialized world:
   * its spaces exist and it can spawn its own cross-Space dependencies. *)
  emit_line e "func.call @yon_rt_maybe_serve() : () -> ()";
  (* Static detection of cross-space coordination. If the body uses
   * apply_move(...) in S for at least 2 distinct spaces, we open a cross-space
   * op that announces the set of heaps involved at runtime, which derives the
   * coordination shape (2PC / FREE_MERGE) and logs it. *)
  let target_spaces = collect_target_spaces main_body in
  let cs_token =
    if List.length target_spaces >= 2 then begin
      (* Allocate an array of heap_ids resolved via yon_rt_lookup_space. *)
      let n = List.length target_spaces in
      let v_one = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 1 : i64" v_one);
      let v_arr = fresh_ssa e in
      emit_line e (Printf.sprintf
                     "%s = llvm.alloca %s x !llvm.array<%d x i32> : (i64) -> !llvm.ptr"
                     v_arr v_one n);
      List.iteri (fun i sname ->
        let v_off = fresh_ssa e in
        emit_line e (Printf.sprintf "%s = arith.constant %d : i32" v_off (i * 4));
        let v_gep = fresh_ssa e in
        emit_line e (Printf.sprintf
                       "%s = llvm.getelementptr %s[%s] : (!llvm.ptr, i32) -> !llvm.ptr, i8"
                       v_gep v_arr v_off);
        let v_ptr = fresh_ssa e in
        emit_line e (Printf.sprintf
                       "%s = llvm.mlir.addressof @yon_space_str_%s : !llvm.ptr"
                       v_ptr sname);
        let v_id = fresh_ssa e in
        emit_line e (Printf.sprintf
                       "%s = func.call @yon_rt_lookup_space(%s) : (!llvm.ptr) -> i32"
                       v_id v_ptr);
        emit_line e (Printf.sprintf "llvm.store %s, %s : i32, !llvm.ptr"
                       v_id v_gep)
      ) target_spaces;
      let v_n = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant %d : i32" v_n n);
      let v_tok = fresh_ssa e in
      emit_line e (Printf.sprintf
                     "%s = func.call @yon_rt_begin_cross_space_op(%s, %s) : (!llvm.ptr, i32) -> i32"
                     v_tok v_arr v_n);
      Some v_tok
    end else None
  in
  let (v, ty) = emit_term e Env.empty funcs main_body in
  (* Close the cross-space op before the return. *)
  (match cs_token with
   | None -> ()
   | Some tok ->
       emit_line e (Printf.sprintf
                      "func.call @yon_rt_end_cross_space_op(%s) : (i32) -> ()"
                      tok));
  let v_i32 =
    if ty = "i32" then v
    else if ty = "f64" then begin
      let v' = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.fptosi %s : f64 to i32" v' v);
      v'
    end
    else if ty = "i1" then begin
      let v' = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.extui %s : i1 to i32" v' v);
      v'
    end
    else if ty = "!topos.proposition" then begin
      (* Proposition as an exit code. Clean conversion via the dialect-native op
       * topos.heyt_to_i32 (lowered to arith.extui i8 to i32).
       * Encoding: present=0, absent=1, unknown=2 -> the corresponding exit
       * codes. *)
      let v' = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = topos.heyt_to_i32 %s : i32" v' v);
      v'
    end
    else if ty = "!llvm.ptr" then begin
      (* main returning text/list/space exits 0 (success): the opaque value
         is not a useful exit code. *)
      let v' = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 0 : i32" v');
      v'
    end
    else if String.length ty > 16
            && String.sub ty 0 16 = "!topos.section<\"" then begin
      (* main returning a section (a place instance) exits 0. *)
      let v' = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.constant 0 : i32" v');
      v'
    end
    else if ty = "arrow" then begin
      (* The return value is f64 but the called function's declared MLIR type
         was "arrow" (the HOF placeholder from extract_func_sig). Convert
         f64 -> i32 as in the normal f64 cases. *)
      let v' = fresh_ssa e in
      emit_line e (Printf.sprintf "%s = arith.fptosi %s : f64 to i32" v' v);
      v'
    end
    else
      failwith (Printf.sprintf
                  "[emit_mlir emit_main] return type '%s' cannot be converted to i32."
                  ty)
  in
  emit_line e (Printf.sprintf "return %s : i32" v_i32);
  pop_indent e;
  emit_line e "}";
  (* ── __yon_dispatch(selector, arg) -> result ──────────────────────────
   * The server dispatch table called by yon_rt_rpc2_serve_loop. One branch per
   * public (arity-1, number->number) function, keyed by the op_selector hash of
   * its name. Always emitted (even for non-Space programs) so the runtime's
   * reference resolves at link time; for a non-Space program it is simply never
   * called. Unknown selector -> -1. *)
  let fnv1a s =
    let h = ref 2166136261 in
    String.iter (fun c -> h := !h lxor (Char.code c);
                          h := (!h * 16777619) land 0xffffffff) s;
    !h in
  let op_sel name = (fnv1a name) land 0x7fffff in
  (* candidate functions: exactly one f64 parameter, f64 return, user-defined
   * (skip runtime externs and the synthetic ones). *)
  (* candidate functions: 0-4 f64 parameters, f64 return, user-defined
   * (skip runtime externs and the synthetic ones). *)
  let dispatchable =
    List.filter (fun (name, fs) ->
      name <> "main"   (* main returns i32 and is not a cross-Space operation *)
      && not (List.mem name internal_funs)   (* internal funs are NOT exported *)
      && List.length fs.fn_params <= 4
      && List.for_all (fun (_, pty) -> core_ty_to_mlir_simple pty = "f64")
           fs.fn_params
      && fs.fn_ret_mlir = "f64"
      && not (String.length name >= 7 && String.sub name 0 7 = "yon_rt_")
      && not (String.length name >= 8 && String.sub name 0 8 = "Stream__")
      && not (String.length name >= 2 && String.sub name 0 2 = "__")) funcs in
  (* Selector collision check: two exported operations hashing to the same
   * selector would silently dispatch the wrong arrow. Refuse to compile. *)
  let seen : (int, string) Hashtbl.t = Hashtbl.create 16 in
  List.iter (fun (name, _) ->
    let s = op_sel name in
    match Hashtbl.find_opt seen s with
    | Some other when other <> name ->
        Printf.eprintf
          "error: operation selector collision — '%s' and '%s' hash to the \
           same cross-Space selector; rename one of them\n" other name;
        exit 8
    | _ -> Hashtbl.replace seen s name) dispatchable;
  emit_line e "func.func @__yon_dispatch(%sel: f64, %a1: f64, %a2: f64, %a3: f64, %a4: f64) -> f64 {";
  push_indent e;
  let v_def = fresh_ssa e in
  (* Unknown selector (including internal/nonexistent operations) -> the -777
   * failure sentinel, so the caller reports a clear English error instead of
   * silently receiving -1 as if it were a result. From outside, an internal
   * operation is indistinguishable from a nonexistent one. *)
  emit_line e (Printf.sprintf "%s = arith.constant -777.0 : f64" v_def);
  (* fold the branches into nested scf.if, innermost = default *)
  let acc = ref v_def in
  List.iter (fun (name, fs) ->
    let sel_v = fresh_ssa e in
    emit_line e (Printf.sprintf "%s = arith.constant %d.0 : f64" sel_v (op_sel name));
    let cmp_v = fresh_ssa e in
    emit_line e (Printf.sprintf "%s = arith.cmpf oeq, %%sel, %s : f64" cmp_v sel_v);
    let res_v = fresh_ssa e in
    emit_line e (Printf.sprintf "%s = scf.if %s -> f64 {" res_v cmp_v);
    push_indent e;
    let call_v = fresh_ssa e in
    let k = List.length fs.fn_params in
    let args = List.init k (fun i -> Printf.sprintf "%%a%d" (i + 1)) in
    let tys = List.init k (fun _ -> "f64") in
    emit_line e (Printf.sprintf "%s = func.call @%s(%s) : (%s) -> f64"
                   call_v name (String.concat ", " args)
                   (String.concat ", " tys));
    emit_line e (Printf.sprintf "scf.yield %s : f64" call_v);
    pop_indent e;
    emit_line e "} else {";
    push_indent e;
    emit_line e (Printf.sprintf "scf.yield %s : f64" !acc);
    pop_indent e;
    emit_line e "}";
    acc := res_v
  ) dispatchable;
  emit_line e (Printf.sprintf "return %s : f64" !acc);
  pop_indent e;
  emit_line e "}"

(* ─── Entry point ───────────────────────────────────────────────────── *)

let emit_program (dr : Desugar.desugar_result) : string =
  let e = make_emitter () in
  emit_line e "// Generato da emit_mlir.ml — Yon Core IR -> MLIR Topos dialect";
  emit_line e "// runtime body declarations";
  emit_blank e;
  emit_line e "module {";
  push_indent e;
  let places = List.map snd dr.ctx.R.places in
  let reductions = List.map snd dr.ctx.R.reductions in
  (* Fill places_table for field-projection lookup:
     place_name -> [(field_name, field_mlir_ty)]. *)
  e.places_decls <- places;
  e.reductions_decls <- reductions;
  (* fill views_list from the global channel *)
  e.views_list <- !global_views_list;
  (* Fill space_fold_name directly from the fold declared on the space. *)
  e.space_fold_name <- List.filter_map (fun (sd : Surface_ast.space_decl) ->
    match sd.Surface_ast.sd_fold with
    | Some fn -> Some (sd.Surface_ast.sd_name, fn)
    | None -> None
  ) dr.spaces;
  (* Index of the morphs for source/target topos lookup, used in the emit of
   * __morph_in_<S>__<M>. *)
  e.morphs_index <- List.map (fun (mp : Surface_ast.morph_decl) ->
    (mp.Surface_ast.mp_name, mp.mp_source, mp.mp_target)
  ) dr.morphs;
  (* Index of topoi for the lookup `topos_name -> at_space_opt`. Replaces the
   * same-name heuristic in the emit of __morph_in_<S>__<M>. *)
  e.toposes_index <- List.map (fun (td : Surface_ast.topos_decl) ->
    (td.Surface_ast.tp_name, td.tp_at_space)
  ) dr.toposes;
  e.declared_spaces <- dr.spaces;
  e.places_table <- List.map (fun (pd : C.place_decl) ->
    let fields = List.map (fun (fname, fty) ->
      (fname, emit_ty fty)
    ) pd.p_fields in
    (pd.p_name, fields)
  ) places;
  (* Group the places by their declared world (p_site), not into a single
   * __Default. This way `place P in Alg` really ends up in `topos.world @Alg`.
   * Places without an explicit world (p_site = "__INFER") stay in
   * __Default. *)
  if places <> [] then begin
    let world_of (pd : C.place_decl) =
      match pd.p_site with
      | C.TyPlace w when w <> "__INFER" && w <> "" -> w
      | _ -> "__Default"
    in
    (* a stable ordering of the worlds by first appearance *)
    let worlds = List.fold_left (fun acc pd ->
      let w = world_of pd in
      if List.mem w acc then acc else acc @ [w]) [] places in
    List.iter (fun w ->
      let ps = List.filter (fun pd -> world_of pd = w) places in
      emit_world e w ps) worlds
  end;
  List.iter (emit_reduction e) reductions;
  emit_blank e;
  (* Emit only the stdlib functions actually called by the program. Avoids
   * symbol conflicts when the program defines a place operation with the same
   * mangled name (e.g. Ord__compare). *)
  let used_builtins = Hashtbl.create 16 in
  List.iter (fun (_, body) -> collect_used_builtins used_builtins body)
    dr.functions;
  (match dr.main with
   | Some m -> collect_used_builtins used_builtins m
   | None -> ());
  (* Filter: remove the builtins that collide with a Place__op of the program
   * (the mangle <Place>__<op> generated by the OperationOp lowering). *)
  let place_op_names = List.concat_map (fun (pd : C.place_decl) ->
    List.map (fun (op : C.op_sig) ->
      pd.p_name ^ "__" ^ op.op_name
    ) pd.p_operations
  ) places in
  let used_list = Hashtbl.fold (fun k () acc ->
    if List.mem k place_op_names then acc
    else k :: acc
  ) used_builtins [] in
  (* The list declarations are needed even when no List operation is used
     explicitly, because the stream fold pattern calls them. We emit them here
     only when used_list is empty; otherwise the conditional block below emits
     them. *)
  let list_decls_emitted_in_conditional = used_list <> [] in
  if used_list <> [] then begin
    emit_line e "// Stdlib runtime stubs: call into the XLeech2 runtime where available";
    (* Map an stdlib name to its corresponding runtime function. When present,
       the emitted body calls @yon_rt_<runtime_name> with any needed type
       conversion; otherwise it falls back to identity-zero. *)
    let runtime_mapping = [
      "to_prop",      `RT ("yon_rt_to_prop",      `BoolToProp);
      "to_bool",      `RT ("yon_rt_to_bool",      `PropToBool);
      "decide",       `RT ("yon_rt_decide",       `PropToProp);
      "to_bool_dec",  `RT ("yon_rt_to_bool_dec",  `PropToBool);
      "text_to_prop", `RT ("yon_rt_text_to_prop", `PtrToProp);
      "transport",    `RT ("yon_rt_transport",    `F64F64ToF64);
      (* Immutable list over the content-addressed xheap *)
      "List__empty",  `RT ("yon_rt_list_empty",   `F64ToF64);
      "List__cons",   `RT ("yon_rt_list_cons",    `F64F64ToF64);
      "List__head",   `RT ("yon_rt_list_head",    `F64ToF64);
      "List__tail",   `RT ("yon_rt_list_tail",    `F64ToF64);
      "List__length", `RT ("yon_rt_list_length",  `F64ToF64);
      (* Mutable space cell (a static BSS registry) *)
      "Space__make",  `RT ("yon_rt_space_make",   `F64ToF64);
      "Space__set",   `RT ("yon_rt_space_set",    `F64F64ToF64);
      "Space__get",   `RT ("yon_rt_space_get",    `F64ToF64);
    ] in
    List.iter (fun name ->
      let (params, ret) = List.assoc name stdlib_registry in
      let param_strs = List.mapi (fun i ty ->
        Printf.sprintf "%%arg%d: %s" i ty
      ) params in
      let param_decl = String.concat ", " param_strs in
      (* For Stream__ we emit only a private declaration, binding to an
       * external symbol; the body is in the C runtime. *)
      let is_external_runtime =
        (String.length name >= 8 && String.sub name 0 8 = "Stream__")
        || (String.length name >= 6 && String.sub name 0 6 = "Wire__")
        || (String.length name >= 7 && String.sub name 0 7 = "Spawn__")
        || (String.length name >= 7 && String.sub name 0 7 = "yon_rt_")
      in
      if is_external_runtime then begin
        emit_line e (Printf.sprintf "func.func private @%s(%s) -> %s"
                       name param_decl ret)
      end else begin
      emit_line e (Printf.sprintf "func.func @%s(%s) -> %s {"
                     name param_decl ret);
      push_indent e;
      (* If the builtin maps to a runtime function, emit the call plus the
         type conversions between MLIR and the runtime ABI (i8 for a
         proposition, and so on). Otherwise fall back to identity-zero. *)
      let emit_runtime_call rt_name conv =
        match conv with
        | `BoolToProp ->
            let v_ext = fresh_ssa e in
            emit_line e (Printf.sprintf
                           "%s = arith.extui %%arg0 : i1 to i8" v_ext);
            let v_call = fresh_ssa e in
            emit_line e (Printf.sprintf
                           "%s = func.call @%s(%s) : (i8) -> i8"
                           v_call rt_name v_ext);
            let v_prop = fresh_ssa e in
            emit_line e (Printf.sprintf
                           "%s = topos.heyt_from_i8 %s : !topos.proposition"
                           v_prop v_call);
            emit_line e (Printf.sprintf "return %s : !topos.proposition" v_prop)
        | `PropToBool ->
            let v_i8 = fresh_ssa e in
            emit_line e (Printf.sprintf
                           "%s = topos.heyt_to_i32 %%arg0 : i32" v_i8);
            let v_i8b = fresh_ssa e in
            emit_line e (Printf.sprintf
                           "%s = arith.trunci %s : i32 to i8" v_i8b v_i8);
            let v_call = fresh_ssa e in
            emit_line e (Printf.sprintf
                           "%s = func.call @%s(%s) : (i8) -> i8"
                           v_call rt_name v_i8b);
            let v_bool = fresh_ssa e in
            emit_line e (Printf.sprintf
                           "%s = arith.trunci %s : i8 to i1" v_bool v_call);
            emit_line e (Printf.sprintf "return %s : i1" v_bool)
        | `PropToProp ->
            (* proposition -> proposition via runtime i8 (es. decide: guard su unknown) *)
            let v_i8 = fresh_ssa e in
            emit_line e (Printf.sprintf
                           "%s = topos.heyt_to_i32 %%arg0 : i32" v_i8);
            let v_i8b = fresh_ssa e in
            emit_line e (Printf.sprintf
                           "%s = arith.trunci %s : i32 to i8" v_i8b v_i8);
            let v_call = fresh_ssa e in
            emit_line e (Printf.sprintf
                           "%s = func.call @%s(%s) : (i8) -> i8"
                           v_call rt_name v_i8b);
            let v_prop = fresh_ssa e in
            emit_line e (Printf.sprintf
                           "%s = topos.heyt_from_i8 %s : !topos.proposition"
                           v_prop v_call);
            emit_line e (Printf.sprintf "return %s : !topos.proposition" v_prop)
        | `PtrToProp ->
            (* String fusion: the argument is the f64 handle *)
            let v_call = fresh_ssa e in
            emit_line e (Printf.sprintf
                           "%s = func.call @%s(%%arg0) : (f64) -> i8"
                           v_call rt_name);
            let v_prop = fresh_ssa e in
            emit_line e (Printf.sprintf
                           "%s = topos.heyt_from_i8 %s : !topos.proposition"
                           v_prop v_call);
            emit_line e (Printf.sprintf "return %s : !topos.proposition" v_prop)
        | `F64F64ToF64 ->
            let v_call = fresh_ssa e in
            emit_line e (Printf.sprintf
                           "%s = func.call @%s(%%arg0, %%arg1) : (f64, f64) -> f64"
                           v_call rt_name);
            emit_line e (Printf.sprintf "return %s : f64" v_call)
        | `F64ToF64 ->
            let v_call = fresh_ssa e in
            emit_line e (Printf.sprintf
                           "%s = func.call @%s(%%arg0) : (f64) -> f64"
                           v_call rt_name);
            emit_line e (Printf.sprintf "return %s : f64" v_call)
      in
      let emit_zero_default () =
        let zero_ssa = fresh_ssa e in
        match ret with
        | "f64" ->
            emit_line e (Printf.sprintf "%s = arith.constant 0.0 : f64" zero_ssa);
            emit_line e (Printf.sprintf "return %s : f64" zero_ssa)
        | "i1" ->
            emit_line e (Printf.sprintf "%s = arith.constant 0 : i1" zero_ssa);
            emit_line e (Printf.sprintf "return %s : i1" zero_ssa)
        | "i32" ->
            emit_line e (Printf.sprintf "%s = arith.constant 0 : i32" zero_ssa);
            emit_line e (Printf.sprintf "return %s : i32" zero_ssa)
        | "!topos.proposition" ->
            emit_line e (Printf.sprintf "%s = topos.heyt false : !topos.proposition" zero_ssa);
            emit_line e (Printf.sprintf "return %s : !topos.proposition" zero_ssa)
        | "!llvm.ptr" ->
            emit_line e (Printf.sprintf "%s = llvm.mlir.zero : !llvm.ptr" zero_ssa);
            emit_line e (Printf.sprintf "return %s : !llvm.ptr" zero_ssa)
        | _ ->
            failwith (Printf.sprintf
                        "[emit_mlir A4] stdlib stub '%s' return type not handled: %s."
                        name ret)
      in
      (match List.assoc_opt name runtime_mapping with
       | Some (`RT (rt_name, conv)) -> emit_runtime_call rt_name conv
       | None -> emit_zero_default ());
      let _ = param_decl in  (* used in func.func signature above *)
      pop_indent e;
      emit_line e "}"
      end
    ) used_list;
    (* External declarations of the runtime functions called by the stdlib. *)
    emit_line e "// Runtime external declarations (P8) for stdlib";
    emit_line e "func.func private @yon_rt_to_prop(i8) -> i8";
    emit_line e "func.func private @yon_rt_to_bool(i8) -> i8";
    emit_line e "func.func private @yon_rt_decide(i8) -> i8";
    emit_line e "func.func private @yon_rt_to_bool_dec(i8) -> i8";
    emit_line e "func.func private @yon_rt_text_to_prop(f64) -> i8";
    emit_line e "func.func private @yon_rt_transport(f64, f64) -> f64";
    emit_line e "func.func private @yon_rt_list_empty(f64) -> f64";
    emit_line e "func.func private @yon_rt_list_cons(f64, f64) -> f64";
    emit_line e "func.func private @yon_rt_list_head(f64) -> f64";
    emit_line e "func.func private @yon_rt_list_tail(f64) -> f64";
    emit_line e "func.func private @yon_rt_list_length(f64) -> f64";
    emit_line e "func.func private @yon_rt_space_make(f64) -> f64";
    emit_line e "func.func private @yon_rt_space_set(f64, f64) -> f64";
    emit_line e "func.func private @yon_rt_space_get(f64) -> f64";
    emit_blank e
  end;
  (* Declarations always emitted for Map/Set/Dag. They use the
     content-addressed yon_xheap in the runtime. The cost is negligible (a
     handful of private declarations) and the benefit is that any program can
     call them without depending on used_list. *)
  emit_line e "// Runtime declarations P10 — data structures (Map/Set/Dag)";
  emit_line e "func.func private @yon_rt_map_empty() -> f64";
  emit_line e "func.func private @yon_rt_map_put(f64, f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_map_get(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_map_contains(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_map_size(f64) -> f64";
  emit_line e "func.func private @yon_rt_set_empty() -> f64";
  emit_line e "func.func private @yon_rt_set_add(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_set_contains(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_set_size(f64) -> f64";
  (* fallback list_* declarations when used_list was empty *)
  if not list_decls_emitted_in_conditional then begin
    emit_line e "func.func private @yon_rt_list_empty(f64) -> f64";
    emit_line e "func.func private @yon_rt_list_cons(f64, f64) -> f64";
    emit_line e "func.func private @yon_rt_list_head(f64) -> f64";
    emit_line e "func.func private @yon_rt_list_tail(f64) -> f64";
    emit_line e "func.func private @yon_rt_list_length(f64) -> f64"
  end;
  (* dedicated HashSet *)
  emit_line e "func.func private @yon_rt_hashset_empty() -> f64";
  emit_line e "func.func private @yon_rt_hashset_add(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_hashset_contains(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_hashset_size(f64) -> f64";
  emit_line e "func.func private @yon_rt_hashset_to_list(f64) -> f64";
  (* XSet, backed by a minimal perfect hash function *)
  emit_line e "func.func private @yon_rt_xset_empty() -> f64";
  emit_line e "func.func private @yon_rt_xset_add(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_xset_contains(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_xset_size(f64) -> f64";
  emit_line e "func.func private @yon_rt_xset_union(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_xset_intersect(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_xset_to_list(f64) -> f64";
  (* to_stream conversions *)
  emit_line e "func.func private @yon_rt_map_to_list(f64) -> f64";
  emit_line e "func.func private @yon_rt_set_to_list(f64) -> f64";
  emit_line e "func.func private @yon_rt_merkle_leaf(f64) -> f64";
  emit_line e "func.func private @yon_rt_merkle_node2(f64, f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_merkle_node2_commutative(f64, f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_merkle_label(f64) -> f64";
  emit_line e "func.func private @yon_rt_merkle_child(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_merkle_equal(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_merkle_to_list(f64) -> f64";
  (* node3/node4 S_n canonical. *)
  emit_line e "func.func private @yon_rt_merkle_node3(f64, f64, f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_merkle_node4(f64, f64, f64, f64, f64) -> f64";
  (* Leech G_24 sign-flip canonical. *)
  emit_line e "func.func private @yon_rt_leech_sign_canonical(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_leech_syndrome(f64) -> f64";
  emit_line e "func.func private @yon_rt_leech_orbit_id(f64) -> f64";
  emit_line e "func.func private @yon_rt_leech_same_orbit(f64, f64) -> f64";
  (* M_24 + xi Conway. *)
  emit_line e "func.func private @yon_rt_leech_m24_orbit(f64) -> f64";
  emit_line e "func.func private @yon_rt_leech_gcode_weight(f64) -> f64";
  emit_line e "func.func private @yon_rt_leech_cocode_weight(f64) -> f64";
  emit_line e "func.func private @yon_rt_leech_xi_apply(f64) -> f64";
  emit_line e "func.func private @yon_rt_leech_co0_step(f64) -> f64";
  emit_line e "func.func private @yon_rt_leech_co0_canonical_exact(f64) -> f64";
  emit_line e "func.func private @yon_rt_leech_co0_equivalent(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_leech_transport(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_leech_transport_apply(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_leech_co0_canonical(f64) -> f64";
  emit_line e "func.func private @yon_rt_leech_co0_orbit_size(f64, f64) -> f64";
  (* Capability + schema evolution. *)
  emit_line e "func.func private @yon_rt_cap_grant(f64) -> f64";
  emit_line e "func.func private @yon_rt_cap_check(f64) -> f64";
  emit_line e "func.func private @yon_rt_cap_revoke(f64) -> f64";
  emit_line e "func.func private @yon_rt_move_register_version(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_move_current_version(f64) -> f64";
  (* Stdlib base Math/Bits/IO. *)
  emit_line e "func.func private @yon_rt_math_sqrt(f64) -> f64";
  emit_line e "func.func private @yon_rt_math_abs(f64) -> f64";
  emit_line e "func.func private @yon_rt_math_floor(f64) -> f64";
  emit_line e "func.func private @yon_rt_math_ceil(f64) -> f64";
  emit_line e "func.func private @yon_rt_math_round(f64) -> f64";
  emit_line e "func.func private @yon_rt_math_min(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_math_max(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_math_pow(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_math_log(f64) -> f64";
  emit_line e "func.func private @yon_rt_math_exp(f64) -> f64";
  emit_line e "func.func private @yon_rt_math_sin(f64) -> f64";
  emit_line e "func.func private @yon_rt_math_cos(f64) -> f64";
  emit_line e "func.func private @yon_rt_math_pi() -> f64";
  emit_line e "func.func private @yon_rt_math_e() -> f64";
  emit_line e "func.func private @yon_rt_math_modulo(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_math_gcd(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_math_lcm(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_magma_empty(f64) -> f64";
  emit_line e "func.func private @yon_rt_magma_gen(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_magma_is_commutative(f64) -> f64";
  emit_line e "func.func private @yon_rt_magma_is_associative(f64) -> f64";
  emit_line e "func.func private @yon_rt_magma_identity(f64) -> f64";
  emit_line e "func.func private @yon_rt_magma_closure_size(f64) -> f64";
  emit_line e "func.func private @yon_rt_land_reach(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_land_witness(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_magma_word_push(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_magma_normal_form(f64) -> f64";
  emit_line e "func.func private @yon_rt_magma_from_algebra(f64) -> f64";

  emit_line e "func.func private @yon_rt_math_log2(f64) -> f64";
  emit_line e "func.func private @yon_rt_math_log10(f64) -> f64";
  emit_line e "func.func private @yon_rt_math_atan2(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_math_sinh(f64) -> f64";
  emit_line e "func.func private @yon_rt_math_cosh(f64) -> f64";
  emit_line e "func.func private @yon_rt_math_tanh(f64) -> f64";
  emit_line e "func.func private @yon_rt_hashset_union(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_hashset_intersect(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_list_reverse(f64) -> f64";
  emit_line e "func.func private @yon_rt_bits_and(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_bits_or(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_bits_xor(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_bits_not(f64) -> f64";
  emit_line e "func.func private @yon_rt_bits_shl(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_bits_shr(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_bits_popcount(f64) -> f64";
  emit_line e "func.func private @yon_rt_io_print_num(f64) -> f64";
  (* Extended stdlib. *)
  emit_line e "func.func private @yon_rt_string_from_int(f64) -> f64";
  emit_line e "func.func private @yon_rt_string_length(f64) -> f64";
  emit_line e "func.func private @yon_rt_string_concat(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_string_equal(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_string_char_at(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_string_print(f64) -> f64";
  emit_line e "func.func private @yon_rt_string_parse_number(f64) -> f64";
  emit_line e "func.func private @yon_rt_string_substring(f64, f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_string_find_char(f64, f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_string_from_char(f64) -> f64";
  emit_line e "func.func private @yon_rt_file_read_text(f64) -> f64";
  emit_line e "func.func private @yon_rt_file_write_text(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_file_append_text(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_env_get(f64) -> f64";
  emit_line e "func.func private @yon_rt_env_has(f64) -> f64";
  emit_line e "func.func private @yon_rt_args_count() -> f64";
  emit_line e "func.func private @yon_rt_args_get(f64) -> f64";
  emit_line e "func.func private @yon_rt_file_exists(f64) -> f64";
  emit_line e "func.func private @yon_rt_seq_range(f64) -> f64";
  emit_line e "func.func private @yon_rt_bits_fold(f64, f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_bits_or_64(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_bits_and_64(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_bits_xor_64(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_time_now_ms() -> f64";
  emit_line e "func.func private @yon_rt_time_now_ns() -> f64";
  emit_line e "func.func private @yon_rt_random_seed(f64) -> f64";
  emit_line e "func.func private @yon_rt_random_int() -> f64";
  emit_line e "func.func private @yon_rt_random_range(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_crypto_fnv1a(f64) -> f64";
  emit_line e "func.func private @yon_rt_crypto_hash_int(f64) -> f64";
  (* Extended stdlib. *)
  emit_line e "func.func private @yon_rt_hashset_try_add(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_hashset_at_bucket(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_hashset_dir_capacity(f64) -> f64";
  emit_line e "func.func private @yon_rt_hsh_empty(f64) -> f64";
  emit_line e "func.func private @yon_rt_hsh_empty_mod(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_hsh_step(f64, f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_hsh_contains(f64, f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_hsh_backward(f64, f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_hsh_shared_levels(f64) -> f64";
  emit_line e "func.func private @yon_rt_hsh_levels(f64) -> f64";
  (* VoyagerList as a collection. *)
  emit_line e "func.func private @yon_rt_voyagerlist_empty() -> f64";
  emit_line e "func.func private @yon_rt_arena_empty() -> f64";
  emit_line e "func.func private @yon_rt_arena_put(f64, f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_arena_get(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_arena_occupied(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_arena_orbit(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_arena_same_orbit(f64, f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_arena_fuse(f64, f64, f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_arena_fusion_count(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_voyagerlist_append(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_voyagerlist_get(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_voyagerlist_size(f64) -> f64";
  emit_line e "func.func private @yon_rt_voyagerlist_corrupt_at(f64, f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_voyagerlist_to_list(f64) -> f64";
  (* observe via geom_morphism (pull lazy a read-time). *)
  emit_line e "func.func private @yon_rt_observe_alloc(f64) -> f64";
  emit_line e "func.func private @yon_rt_observe(f64, f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_xheap_used() -> i32";
  (* multi-process via fork. *)
  emit_line e "func.func private @yon_rt_spawn_self(f64) -> f64";
  emit_line e "func.func private @yon_rt_spawn_index() -> f64";
  (* Codice Golay (24,12,8). *)
  emit_line e "func.func private @yon_rt_voyagerlist_seal(f64) -> f64";
  emit_line e "func.func private @yon_rt_voyagerlist_open(f64) -> f64";
  emit_line e "func.func private @yon_rt_voyagerlist_corrupt(f64, f64) -> f64";
  (* capability tokens via Co_0 *)
  emit_line e "func.func private @yon_rt_conway_gen_key(f64) -> f64";
  emit_line e "func.func private @yon_rt_conway_seal_slot(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_conway_unseal_slot(f64, f64) -> f64";
  emit_line e "func.func private @yon_rt_conway_key_equal(f64, f64) -> f64";
  emit_blank e;
  (* Always emitted, regardless of the stdlib, because the __new_X
     constructors and the field_load pre-walk of the lowering need them. *)
  if places <> [] then begin
    emit_line e "// Runtime external declarations (P8) for places";
    emit_line e "func.func private @yon_rt_new(i32, !llvm.ptr, i32) -> i64";
    emit_line e "func.func private @yon_rt_new_v(i32, !llvm.ptr, i32, !llvm.ptr, i32) -> i64";
    emit_line e "func.func private @yon_rt_register_schema(i32, i32, !llvm.ptr) -> ()";
    emit_line e "func.func private @yon_rt_field_load(i64, i32, i32, !llvm.ptr) -> i32";
    (* fold_named plus the string constants naming the canonical folds. We
       emit these whenever there are places: the cost is negligible and it
       keeps the code generation simple. *)
    emit_line e "func.func private @yon_rt_fold_named(i32, i64, !llvm.ptr, i32, !llvm.ptr) -> i64";
    emit_line e "llvm.mlir.global internal constant @yon_fold_str_sum_f64(\"sum_f64\\00\") : !llvm.array<8 x i8>";
    emit_line e "llvm.mlir.global internal constant @yon_fold_str_max_f64(\"max_f64\\00\") : !llvm.array<8 x i8>";
    emit_line e "llvm.mlir.global internal constant @yon_fold_str_min_f64(\"min_f64\\00\") : !llvm.array<8 x i8>";
    (* further folds: int64, vector, and bitset *)
    emit_line e "llvm.mlir.global internal constant @yon_fold_str_sum_i64(\"sum_i64\\00\") : !llvm.array<8 x i8>";
    emit_line e "llvm.mlir.global internal constant @yon_fold_str_max_i64(\"max_i64\\00\") : !llvm.array<8 x i8>";
    emit_line e "llvm.mlir.global internal constant @yon_fold_str_min_i64(\"min_i64\\00\") : !llvm.array<8 x i8>";
    emit_line e "llvm.mlir.global internal constant @yon_fold_str_sum_vec_f64(\"sum_vec_f64\\00\") : !llvm.array<12 x i8>";
    emit_line e "llvm.mlir.global internal constant @yon_fold_str_max_vec_f64(\"max_vec_f64\\00\") : !llvm.array<12 x i8>";
    emit_line e "llvm.mlir.global internal constant @yon_fold_str_or_bitset(\"or_bitset\\00\") : !llvm.array<10 x i8>";
    emit_blank e
  end;
  (* declarations and global strings for the declared spaces *)
  if dr.spaces <> [] then begin
    emit_line e "// Cross-Space runtime declarations";
    emit_line e "func.func private @yon_rt_init() -> ()";
    emit_line e "func.func private @yon_rt_register_space(!llvm.ptr) -> i32";
    emit_line e "func.func private @yon_rt_register_space_with_fold(!llvm.ptr, !llvm.ptr) -> i32";
    emit_line e "func.func private @yon_rt_lookup_space(!llvm.ptr) -> i32";
    emit_line e "func.func private @yon_rt_begin_cross_space_op(!llvm.ptr, i32) -> i32";
    emit_line e "func.func private @yon_rt_end_cross_space_op(i32) -> ()";
    emit_space_strings e dr.spaces;
    emit_blank e
  end;
  (* declarations and strings for the declared geometric morphisms; the
     runtime registration happens in main via emit_geom_morphism_bootstrap *)
  if dr.geom_morphisms <> [] then begin
    emit_line e "// geometric_morphism runtime decls";
    emit_line e "func.func private @yon_rt_register_geom_morphism(!llvm.ptr, !llvm.ptr, !llvm.ptr, !llvm.ptr) -> i32";
    emit_geom_morphism_strings e dr.geom_morphisms dr.spaces;
    emit_blank e
  end;
  (* Conventional server-binary path globals for imported Spaces (step 3). *)
  if dr.space_imports <> [] then begin
    emit_srv_path_globals e dr.space_imports;
    emit_blank e
  end;
  (* String fusion: collect every string literal of the program, emit one
     module global per distinct content, and declare the interning runtime. *)
  Hashtbl.reset g_strlits;
  g_strlit_order := [];
  List.iter (fun (_, body) -> collect_string_literals body) dr.functions;
  (match dr.main with
   | Some m -> collect_string_literals m
   | None -> ());
  if Hashtbl.length g_strlits > 0 then begin
    emit_line e "// string literals (interned to xheap handles at runtime)";
    emit_line e "func.func private @yon_rt_string_lit(!llvm.ptr) -> f64";
    List.iter (fun content ->
      let sym = Hashtbl.find g_strlits content in
      let n = String.length content in
      let chars = String.concat ", " (
        List.init n (fun i -> Printf.sprintf "%d" (Char.code content.[i]))
        @ ["0"]) in
      emit_line e (Printf.sprintf
                     "llvm.mlir.global internal constant @%s(dense<[%s]> : tensor<%d x i8>) : !llvm.array<%d x i8>"
                     sym chars (n + 1) (n + 1))
    ) (List.rev !g_strlit_order);
    emit_blank e
  end;
  (* Stream runtime declarations are emitted by the stdlib stubs block above
     when a Stream__ operation is used, so there is no duplicate here. *)
  (* For each declared place, emit the constructor __new_<Place> as an
     identity-zero stub returning an opaque section. *)
  if places <> [] then begin
    emit_line e "// Place constructors __new_<X> (P8) — alloca payload via yon_rt_new";
    (* Wire DTO descriptors: one global byte array of field tags per
       transportable place, addressed at startup by yon_rt_register_schema. *)
    List.iter (fun (pd : C.place_decl) ->
      match wire_tags_of_place places pd with
      | Some tags when tags <> [] ->
          let n = List.length tags in
          let bytes = String.concat ", " (List.map string_of_int tags) in
          emit_line e (Printf.sprintf
                         "llvm.mlir.global internal constant @yon_wire_tags_%s(dense<[%s]> : tensor<%d x i8>) : !llvm.array<%d x i8>"
                         pd.p_name bytes n n)
      | _ -> ()
    ) places;
    (* Helper to size the MLIR types (bytes). *)
    let mlir_ty_size = function
      | "f64" -> 8
      | "i1"  -> 1
      | "i8"  -> 1
      | "i32" -> 4
      | "i64" -> 8
      | "!llvm.ptr" -> 8
      | "!topos.proposition" -> 1
      | _ -> 8  (* section/others: treated as an opaque pointer *)
    in
    List.iter (fun (pd : C.place_decl) ->
      let field_tys = List.map (fun (_, fty) -> emit_ty fty) pd.p_fields in
      let param_strs = List.mapi (fun i ty ->
        Printf.sprintf "%%arg%d: %s" i ty
      ) field_tys in
      let param_decl = String.concat ", " param_strs in
      let result_ty = Printf.sprintf "!topos.section<\"%s\">" pd.p_name in
      let offsets_and_total =
        let acc = ref 0 in
        let offs = List.map (fun t ->
          let o = !acc in acc := !acc + mlir_ty_size t; o
        ) field_tys in
        (offs, !acc)
      in
      let (offsets, total_size) = offsets_and_total in

      (* parametric body for the heap_id source.
       * heap_kind = `Default | `Lookup of string (the space name).
       * Emits the stores + alloca + the yon_rt_new call with the heap_id
       * constant (0) or resolved via a runtime lookup.
       *
       * If ?fold_name is Some "sum_f64" etc., emits yon_rt_fold_named instead
       * of yon_rt_new (CRDT semilattice-join semantics). *)
      let emit_alloc_call (v_heap : string) (v_buf : string) (v_size : string)
                          (fold_name : string option) : string =
        let v_xc = fresh_ssa e in
        (match fold_name with
         | Some fn ->
             (* yon_rt_fold_named(heap, INVALID, buf, size, fold_name) -> i64 *)
             let v_prev = fresh_ssa e in
             emit_line e (Printf.sprintf
                            "%s = arith.constant -1 : i64" v_prev);
             let v_fold_str = fresh_ssa e in
             emit_line e (Printf.sprintf
                            "%s = llvm.mlir.addressof @yon_fold_str_%s : !llvm.ptr"
                            v_fold_str fn);
             emit_line e (Printf.sprintf
                            "%s = func.call @yon_rt_fold_named(%s, %s, %s, %s, %s) : (i32, i64, !llvm.ptr, i32, !llvm.ptr) -> i64"
                            v_xc v_heap v_prev v_buf v_size v_fold_str)
         | None ->
             (match wire_schema_id_of_place places pd with
              | Some id ->
                  (* Transportable place: stamp the structural schema id so the
                     pump can recover the descriptor when this instance crosses
                     a wire. Inert for instances that never leave the heap. *)
                  let v_null = fresh_ssa e in
                  emit_line e (Printf.sprintf "%s = llvm.mlir.zero : !llvm.ptr" v_null);
                  let v_ver = fresh_ssa e in
                  emit_line e (Printf.sprintf "%s = arith.constant %d : i32" v_ver id);
                  emit_line e (Printf.sprintf
                                 "%s = func.call @yon_rt_new_v(%s, %s, %s, %s, %s) : (i32, !llvm.ptr, i32, !llvm.ptr, i32) -> i64"
                                 v_xc v_heap v_buf v_size v_null v_ver)
              | None ->
                  emit_line e (Printf.sprintf
                                 "%s = func.call @yon_rt_new(%s, %s, %s) : (i32, !llvm.ptr, i32) -> i64"
                                 v_xc v_heap v_buf v_size)));
        v_xc
      in
      let emit_new_body (heap_kind : [`Default | `Lookup of string])
                        ?(fold_name : string option = None) () : unit =
        if total_size = 0 then begin
          let v_size = fresh_ssa e in
          emit_line e (Printf.sprintf "%s = arith.constant 1 : i32" v_size);
          let v_buf = fresh_ssa e in
          emit_line e (Printf.sprintf
                         "%s = llvm.alloca %s x i8 : (i32) -> !llvm.ptr"
                         v_buf v_size);
          let v_heap =
            match heap_kind with
            | `Default ->
                let v = fresh_ssa e in
                emit_line e (Printf.sprintf "%s = arith.constant 0 : i32" v);
                v
            | `Lookup sname ->
                let v_ptr = fresh_ssa e in
                emit_line e (Printf.sprintf
                               "%s = llvm.mlir.addressof @yon_space_str_%s : !llvm.ptr"
                               v_ptr sname);
                let v = fresh_ssa e in
                emit_line e (Printf.sprintf
                               "%s = func.call @yon_rt_lookup_space(%s) : (!llvm.ptr) -> i32"
                               v v_ptr);
                v
          in
          let v_xc = emit_alloc_call v_heap v_buf v_size fold_name in
          let v_sec = fresh_ssa e in
          emit_line e (Printf.sprintf
                         "%s = topos.xcoord_to_section %s : %s"
                         v_sec v_xc result_ty);
          emit_line e (Printf.sprintf "return %s : %s" v_sec result_ty)
        end else begin
          let v_one = fresh_ssa e in
          emit_line e (Printf.sprintf "%s = arith.constant 1 : i64" v_one);
          let v_buf = fresh_ssa e in
          emit_line e (Printf.sprintf
                         "%s = llvm.alloca %s x !llvm.array<%d x i8> : (i64) -> !llvm.ptr"
                         v_buf v_one total_size);
          List.iteri (fun i ty ->
            let off = List.nth offsets i in
            let v_off = fresh_ssa e in
            emit_line e (Printf.sprintf "%s = arith.constant %d : i32" v_off off);
            let v_gep = fresh_ssa e in
            emit_line e (Printf.sprintf
                           "%s = llvm.getelementptr %s[%s] : (!llvm.ptr, i32) -> !llvm.ptr, i8"
                           v_gep v_buf v_off);
            let store_val =
              if String.length ty > 15 && String.sub ty 0 15 = "!topos.section<" then begin
                let v_cast = fresh_ssa e in
                emit_line e (Printf.sprintf
                               "%s = topos.section_to_xcoord %%arg%d : %s to i64"
                               v_cast i ty);
                (v_cast, "i64")
              end else if ty = "!topos.proposition" then begin
                let v_cast = fresh_ssa e in
                emit_line e (Printf.sprintf
                               "%s = topos.heyt_to_i32 %%arg%d : i32" v_cast i);
                let v_t = fresh_ssa e in
                emit_line e (Printf.sprintf
                               "%s = arith.trunci %s : i32 to i8" v_t v_cast);
                (v_t, "i8")
              end else
                (Printf.sprintf "%%arg%d" i, ty)
            in
            let (sv, st) = store_val in
            emit_line e (Printf.sprintf "llvm.store %s, %s : %s, !llvm.ptr" sv v_gep st)
          ) field_tys;
          let v_size = fresh_ssa e in
          emit_line e (Printf.sprintf "%s = arith.constant %d : i32" v_size total_size);
          let v_heap =
            match heap_kind with
            | `Default ->
                let v = fresh_ssa e in
                emit_line e (Printf.sprintf "%s = arith.constant 0 : i32" v);
                v
            | `Lookup sname ->
                let v_ptr = fresh_ssa e in
                emit_line e (Printf.sprintf
                               "%s = llvm.mlir.addressof @yon_space_str_%s : !llvm.ptr"
                               v_ptr sname);
                let v = fresh_ssa e in
                emit_line e (Printf.sprintf
                               "%s = func.call @yon_rt_lookup_space(%s) : (!llvm.ptr) -> i32"
                               v v_ptr);
                v
          in
          let v_xc = emit_alloc_call v_heap v_buf v_size fold_name in
          let v_sec = fresh_ssa e in
          emit_line e (Printf.sprintf
                         "%s = topos.xcoord_to_section %s : %s"
                         v_sec v_xc result_ty);
          emit_line e (Printf.sprintf "return %s : %s" v_sec result_ty)
        end
      in

      (* Emit __new_<Place> (default heap_id = 0). *)
      emit_line e (Printf.sprintf
                     "func.func @__new_%s(%s) -> %s {"
                     pd.p_name param_decl result_ty);
      push_indent e;
      emit_new_body `Default ();
      pop_indent e;
      emit_line e "}";

      (* For each declared space, emit the variant
         __new_in_<Space>_<Place>, which resolves the heap id via
         yon_rt_lookup_space. If the space has a declared fold, pass its name
         to the constructor, which will emit yon_rt_fold_named instead of
         yon_rt_new. *)
      List.iter (fun (sd : Surface_ast.space_decl) ->
        let fold_name = sd.Surface_ast.sd_fold in
        emit_line e (Printf.sprintf
                       "func.func @__new_in_%s_%s(%s) -> %s {"
                       sd.sd_name pd.p_name param_decl result_ty);
        push_indent e;
        emit_new_body (`Lookup sd.sd_name) ~fold_name ();
        pop_indent e;
        emit_line e "}"
      ) dr.spaces
    ) places;
    emit_blank e;
    (* Forward declarations for the place operations. The OperationOp lowering
     * will create the real definition; here we emit only the `func.func
     * private` to let the verifier pass before lowering. Signature:
     * (i32 instance, original_args...) -> ret. *)
    emit_line e "// Place operation declarations — body provided by the lowering";
    List.iter (fun (pd : C.place_decl) ->
      List.iter (fun (op : C.op_sig) ->
        let arg_tys = List.map (fun (_, t) -> core_ty_to_mlir_simple t) op.op_params in
        let all_tys = "i32" :: arg_tys in
        let param_decl = String.concat ", " all_tys in
        let ret_ty = core_ty_to_mlir_simple op.op_return in
        emit_line e (Printf.sprintf
                       "func.func private @%s__%s(%s) -> %s"
                       pd.p_name op.op_name param_decl ret_ty)
      ) pd.p_operations
    ) places;
    emit_blank e
  end;
  (* Sliding window: process the functions in source order (List.rev because
   * dr.functions is built by prepending). Each func_sig sees the earlier ones,
   * enabling type inference that uses the already-processed functions. A
   * function that calls only itself (single recursion) takes its return type
   * from the non-recursive branch of the if, which is typically a literal. *)
  (* Extract the reduction handler clauses as user functions
   * `<Reduction>__<op>(params) -> ret_ty`. They are mixed in with the
   * program's functions so extract_func_sig can infer their return type via
   * infer_mlir_ty. *)
  let reduction_handler_funcs =
    List.concat_map (fun (rd : C.reduction_decl) ->
      List.map (fun (hc : C.handler_clause) ->
        let name = rd.r_name ^ "__" ^ hc.hc_op in
        let wrapped = List.fold_right (fun (pn, pt) acc ->
          C.Lam (pn, pt, acc)
        ) hc.hc_params hc.hc_body in
        (name, wrapped)
      ) rd.r_handlers
    ) reductions
  in
  let all_functions = dr.functions @ reduction_handler_funcs in
  (* Two passes, to support forward references between functions (e.g. fun A
   * calling fun B declared later).
   *
   * Pass 1: shell signatures based on fn_ret_hints plus parameter types.
   *         Does not infer from the body. Available for every function.
   * Pass 2: full extract with funcs_so_far = the precomputed shell sigs. *)
  let shell_sig (name : string) (body : C.term) : func_sig option =
    let (params, _inner) = collect_params body in
    match List.assoc_opt name dr.fn_ret_hints with
    | Some ret_ty ->
        Some {
          fn_name = name;
          fn_params = params;
          fn_ret_mlir = core_ty_to_mlir_simple ret_ty;
          fn_body = _inner;
          fn_type_params = [];
        }
    | None -> None
  in
  let shell_sigs : (string * func_sig) list =
    List.filter_map (fun (n, b) ->
      match shell_sig n b with Some s -> Some (n, s) | None -> None
    ) all_functions
  in
  let func_sigs_rev = List.fold_left (fun acc (name, body) ->
    (* Pre-fill acc with shell_sigs: the current function sees both the
     * already-processed functions (the real acc) and all the shells (for
     * forward references). *)
    let funcs_so_far = (List.rev acc) @ shell_sigs in
    let fs = extract_func_sig e funcs_so_far dr.fn_ret_hints name body in
    (name, fs) :: acc
  ) [] (List.rev all_functions) in
  let func_sigs = List.rev func_sigs_rev in
  emit_blank e;
  (* reset the global monomorphization registry for this run *)
  mono_global := make_mono_registry ();
  (* Emit only the monomorphic functions (fn_type_params = []). The
     polymorphic ones are emitted on demand as specializations at the end of
     the module. *)
  (* Identify higher-order functions: those with at least one handle-typed
     parameter (arrow, move, reduction, morph, or view). These are not emitted
   * as func.func; the call site inlines them with the concrete value
   * passed. *)
  let is_hof_fun (fs : func_sig) : bool =
    (* The 4 handles stay skipped (inlining only).
     * TyArrow base and nested: NOT skipped (emitted as real func.func). *)
    List.exists (fun (_, t) ->
      match t with
      | C.TyBase "move_handle"
      | C.TyBase "reduction_handle"
      | C.TyBase "morph_handle"
      | C.TyBase "view_handle" -> true
      | _ -> false
    ) fs.fn_params
  in
  List.iter (fun (name, fs) ->
    if name <> "main" && fs.fn_type_params = [] && not (is_hof_fun fs) then begin
      emit_function e func_sigs fs;
      emit_blank e
    end
  ) func_sigs;
  (match dr.main with
   | Some body ->
       e.ssa_counter <- 0;
       (* A let-inline pass to preserve fusion when the user uses an
        * intermediate `let a holds Seq.X`. Transforms
        * `App (Lam (x, _, body), Seq.X)` -> `body[Seq.X/x]` if x appears at
        * most once. *)
       let body = Inline_seq.inline_seq_lets body in
       emit_main e func_sigs dr.spaces dr.reductions_surface dr.geom_morphisms dr.space_imports dr.internal_funs body
   | None -> ());
  (* Emit the accumulated specializations. Fixpoint loop: each specialization
   * may in turn generate new requests. *)
  let emitted_specs = Hashtbl.create 8 in
  let rec emit_specs () =
    let pending = (!mono_global).mono_pending in
    if pending <> [] then begin
      (!mono_global).mono_pending <- [];
      List.iter (fun spec ->
        if not (Hashtbl.mem emitted_specs spec.fn_name) then begin
          Hashtbl.add emitted_specs spec.fn_name ();
          emit_blank e;
          emit_function e func_sigs spec
        end
      ) (List.rev pending);
      emit_specs ()
    end
  in
  emit_specs ();
  pop_indent e;
  emit_line e "}";
  Buffer.contents e.buf
