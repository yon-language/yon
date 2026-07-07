(* carrier.ml — the runtime VALUE carrier of a place.
 *
 * Yon's one ontology is the place (an object, a presheaf Site -> Type). The
 * `carrier` functor is the DERIVED runtime realization of a place: how an
 * inhabitant of that place is laid out as data. It is target-agnostic — an
 * abstract algebra of runtime representations (`Carrier.t`) — and the emit
 * backend is a mere printer from `Carrier.t` into the target syntax (today
 * MLIR; tomorrow WASM or native C, by swapping only `to_mlir`).
 *
 * PARTIALITY. A place-qua-object that has no runtime value (a code, the
 * universe, a bare type-level former) has NO carrier: [of_core_ty] raises
 * [NoCarrier]. That partiality is meant to coincide with the erasure frontier
 * — such terms should already have been erased before emit. If the erasure
 * ever leaks one, the carrier computation stops here rather than inventing a
 * fallback type or emitting corrupt MLIR.
 *
 * SCHEMA vs CARRIER. This module is the value carrier only. The *schema* (a
 * type's declaration MLIR — opaque cells for Id/PathP, etc.) is a separate
 * concern that stays in emit (`emit_ty`); it is not fused here.
 *
 * STAGE 1 (this file) is behavior-preserving: [of_core_ty]/[to_mlir] reproduce
 * exactly what `emit_mlir.core_ty_to_mlir_simple` did before, validated by a
 * textual diff of the emitted MLIR over the example corpus. In particular the
 * the universe/code cases ([TyType], [TyDirUniverse]) raise [NoCarrier]:
 * they have no runtime value and are erased upstream by type_erase before emit.
 * If one ever leaks here, the carrier stops rather than inventing a token. *)

module C = Ast

(* Scalar register widths, target-agnostic. *)
type width =
  | W_f64 | W_f32
  | W_i1 | W_i8 | W_i16 | W_i32 | W_i64

(* The abstract algebra of runtime value layouts. *)
type t =
  | Scalar of width            (* a machine scalar (f64, i1, i32, ...) *)
  | Proposition                (* Omega, the subobject classifier carrier *)
  | Section of string          (* an inhabitant of a named place: a section handle *)
  | Arrow of t list * t        (* a function value: flattened (args) -> ret signature *)
  | Struct of t list           (* a structural product (dependent pair, non-comprehension) *)
  | Opaque                     (* a pointer-sized opaque handle, no inspectable payload *)
  | Boxed                      (* the UNIFORM carrier of a genuinely value-dependent El:
                                  a FAT POINTER {payload-ptr, i64 type-tag}. One single
                                  layout every stuck-El instance shares, so a function
                                  over `El(stuck)` compiles ONCE regardless of which
                                  concrete type the code computes to at runtime.

                                  SOUNDNESS. The box is SELF-DESCRIBING: the i64 tag
                                  records what the payload pointer points at, so no bit
                                  pattern is ever reinterpreted as the wrong type. It is
                                  the polymorphic-box discipline of OCaml/Java `Object`
                                  or a Rust `dyn Any`: a value carried as a box can only
                                  be observed through a tag-checked unbox, never by a
                                  raw reinterpret. Memory-safety: the payload pointer is
                                  either null (no payload) or a heap cell owned by the
                                  runtime; the carrier itself allocates nothing and reads
                                  nothing — it only fixes the ABI shape. Uniformity is
                                  what buys the soundness of "compile once": since every
                                  value-dependent El has THIS carrier, the calling
                                  convention is identical across instances, so no caller
                                  and callee can ever disagree on the layout.

                                  This is the ONLY carrier that is honestly opaque about
                                  its payload TYPE (the tag defers that to runtime) while
                                  being fully concrete about its LAYOUT (16 bytes: ptr +
                                  i64). Distinct from `Opaque` (a bare untagged handle,
                                  no payload discipline) precisely because the tag is the
                                  seat of soundness for value-dependent decoding. *)

(* A place that has no runtime value (a code / universe / bare type-level
   former) has no carrier. Carries the offending Core type so the caller can
   produce a positioned, faithful diagnostic. *)
exception NoCarrier of C.ty

(* Single home for the primitive-place classification: a primitive place is a
   place whose name is one of these, and its carrier is fixed here. This is the
   one table both functors read — the value carrier (of_core_ty below) and the
   schema printer (emit's prim_to_mlir aliases it). Complete over all machine
   widths. *)
let prim_carrier (name : string) : t option =
  match name with
  | "number" | "money" | "text" | "f64" | "unknown" -> Some (Scalar W_f64)
  | "boolean" | "unit" | "i1" -> Some (Scalar W_i1)
  | "i8" -> Some (Scalar W_i8)
  | "i16" -> Some (Scalar W_i16)
  | "i32" -> Some (Scalar W_i32)
  | "i64" -> Some (Scalar W_i64)
  | "f32" -> Some (Scalar W_f32)
  | "proposition" -> Some Proposition
  (* a bare "arrow" is the single-argument function pointer (f64) -> f64 *)
  | "arrow" -> Some (Arrow ([Scalar W_f64], Scalar W_f64))
  | _ -> None

(* A name is primitive exactly when prim_carrier assigns it a carrier. One
   source of truth for the primitive set; emit aliases this. *)
let is_prim_name (name : string) : bool = prim_carrier name <> None

(* The code a place-of-paths El decodes to, as far as the place layer sees it:
   a named place (section) or an opaque handle. Shared by both functors. *)
let el_target (c : C.term) : [ `Named of string | `Opaque ] =
  match c with
  | C.Place pd -> `Named pd.C.p_name
  | C.Var name -> `Named name
  | _ -> `Opaque

let core_is_isprop_fibre (carrier : C.ty) (fibre : C.ty) : bool =
  match fibre with
  | C.TyPi (_, c1, C.TyPi (_, c2, C.TyId (c3, _, _))) ->
      c1 = carrier && c2 = carrier && c3 = carrier
  | _ -> false

let core_is_comprehension (ty : C.ty) : bool =
  match ty with
  | C.TySigma (_, carrier, fibre) -> core_is_isprop_fibre carrier fibre
  | _ -> false

(* The carrier functor: a Core type (place-qua-object) -> its runtime layout. *)
let rec of_core_ty (ty : C.ty) : t =
  match ty with
  | C.TyPlace name ->
      (* a primitive place gets its fixed carrier; any other named place is a
         section handle. *)
      (match prim_carrier name with Some c -> c | None -> Section name)
  | (C.TyArrow (_, _) | C.TyPi (_, _, _)) as ta ->
      (* a curried arrow a -> b -> c (or a dependent Pi, whose dependency is
         erased at runtime) flattens to one signature (a, b) -> c;
         the flattening is a printing detail over one structural carrier. *)
      let rec uncurry params u =
        match u with
        | C.TyArrow (a, b) -> uncurry (a :: params) b
        | C.TyPi (_, a, b) -> uncurry (a :: params) b
        | other -> (List.rev params, other)
      in
      let (params, ret) = uncurry [] ta in
      Arrow (List.map of_core_ty params, of_core_ty ret)
  | C.TySigma (_, a, b) ->
      (* comprehension subobject -> carrier alone (proof is zero-bit);
         generic dependent pair -> honest two-field struct. *)
      if core_is_comprehension ty then of_core_ty a
      else Struct [of_core_ty a; of_core_ty b]
  | C.TyDirUniverse _ -> raise (NoCarrier ty)  (* universe: no runtime value (erased upstream) *)
  | C.TyEl c ->
      (* El(c) degrades to the carrier the code DENOTES. The code has already been
         reduced to Δ-normal form upstream (El_normalize, the conversion rule
         El(c) ≡ El(nf_Δ c)), so a code that computes to a name is a bare Var/Place
         here: it decodes to the carrier of THAT place — a primitive to its scalar,
         a section to its handle — via the same functor (never a blind Section, so
         `El(Fam x)` that computed to `number` gets number's scalar layout).

         COMPUTED case (`Named n`): UNCHANGED. This is the A1 path — the code
         reduced to a concrete named type and decodes to that place's exact
         carrier. Byte-for-byte identical to before; pinned by
         test_dependent_carrier.py.

         STUCK case (`Opaque`): a code that stays stuck under Δ because it
         genuinely depends on a runtime value (a non-constant family applied to a
         free variable, or an `El(v)` for a runtime-chosen code v). Such a type has
         no SINGLE concrete layout — different runtime values yield different
         types. But it DOES have a single UNIFORM layout: the boxed carrier, a fat
         pointer {payload-ptr, i64 tag} shared by every instance. So instead of the
         old clean-but-incomplete `NoCarrier` failure, we lower it to `Boxed`: the
         value-dependent El now COMPILES, uniformly, and soundly (the tag defers
         the concrete type to runtime; see the `Boxed` doc above). *)
      (match el_target c with
       | `Named n -> of_core_ty (C.TyPlace n)
       | `Opaque -> Boxed)
  | C.TyId (a, _, _) ->
      (* a path value lowers to its erased witness, which carries the endpoint
         type: refl(x) is operationally x. Equality stays the reducer's job. *)
      of_core_ty a
  | C.TyType _ -> raise (NoCarrier ty)          (* a code/type: no runtime value (erased upstream) *)
  | C.TyStream _ -> Scalar W_f64        (* a stream value at runtime is its id (f64) *)
  | C.TyGlue (a, _, _) -> of_core_ty a
      (* Glue [phi |-> (T,e)] A carries A's layout: the equivalence is erased;
         univalence computes in the reducer, not in the runtime layout. *)
  | C.TyPathP ((_, a), _, _) -> of_core_ty a
      (* a dependent path lowers to the carrier of its fibre, like TyId: the
         path value is operationally its witness. *)

let width_to_mlir = function
  | W_f64 -> "f64"
  | W_f32 -> "f32"
  | W_i1 -> "i1"
  | W_i8 -> "i8"
  | W_i16 -> "i16"
  | W_i32 -> "i32"
  | W_i64 -> "i64"

(* The MLIR printer: Carrier.t -> target syntax. The ONLY target-specific part;
   a WASM/C backend swaps this function and nothing else. *)
let rec to_mlir (c : t) : string =
  match c with
  | Scalar w -> width_to_mlir w
  | Proposition -> "!topos.proposition"
  | Section name -> Printf.sprintf "!topos.section<\"%s\">" name
  | Arrow (args, ret) ->
      Printf.sprintf "(%s) -> %s"
        (String.concat ", " (List.map to_mlir args))
        (to_mlir ret)
  | Struct elms ->
      Printf.sprintf "!llvm.struct<(%s)>"
        (String.concat ", " (List.map to_mlir elms))
  | Opaque -> "!llvm.ptr"
  | Boxed ->
      (* the uniform value-dependent-El box: a fat pointer, {payload-ptr, i64 tag}.
         16 bytes, one shape for every stuck El — a function over `El(stuck)` takes
         and returns exactly this, compiled once. The tag (i64) names, at runtime,
         what the payload pointer points at; the payload pointer is null for the
         no-payload case and a runtime-owned heap cell otherwise. Concrete LAYOUT,
         deferred payload TYPE — that split is the seat of the soundness argument in
         the `Boxed` constructor's doc. *)
      "!llvm.struct<(ptr, i64)>"
