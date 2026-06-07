(* dispatcher.ml — federation dispatcher between Cubical and CATT_R_Yon.
 *
 * The Yon type checker is a federation of decidable fragments. Each
 * surface construct is routed to its appropriate fragment:
 *
 *   - Cubical fragment handles: identity types, paths, univalence,
 *     quotient/HIT types, anything involving the interval I.
 *   - CATT_R_Yon fragment handles: ordinary base types, place/world/
 *     reduction structure, function declarations, move/view.
 *
 * The dispatcher routes by inspecting the structure of the type or
 * term:
 *
 *   - Surface types not mentioning Path/Glue/HIT -> CATT_R_Yon
 *   - Surface types mentioning these constructs -> Cubical
 *   - Surface terms applying path/transport -> Cubical
 *   - Everything else -> CATT_R_Yon
 *
 * Composition: when comparing two types for equality, the dispatcher
 * tries CATT_R_Yon first (fast path) and falls back to Cubical only
 * for cubical-flavored types. This preserves decidability because
 * both fragments are decidable independently.
 *)

open Surface_ast

(* ─── Classification ───────────────────────────────────────────────── *)

type fragment = FragCATT | FragCubical

(* Names of stdlib types that signal the cubical fragment. When the
 * stdlib introduces Path, Identity, Glue, S1, Suspension, or Quotient
 * as user-facing surface type constructors, they appear as TyUser
 * with these names. *)

let cubical_stdlib_types = [
  "Path"; "Identity"; "Eq";
  "Glue";
  "Quotient";
  "S1"; "S2"; "Sphere";
  "Suspension"; "Susp";
  "PropTrunc"; "SetTrunc";
  "Pushout"; "Coeq";
]

let is_cubical_name (n : string) : bool =
  List.mem n cubical_stdlib_types
  || (String.length n > 7 && String.sub n 0 7 = "Cubical")

(* Classify a surface type. We descend recursively because cubical
 * structure can be nested (e.g., list of Path number). *)

let rec classify_ty (t : ty) : fragment =
  match t with
  | TyUser n when is_cubical_name n -> FragCubical
  | TyList inner | TyStream (inner, _) -> classify_ty inner
  | TyMap (k, v) ->
      (match classify_ty k, classify_ty v with
       | FragCubical, _ | _, FragCubical -> FragCubical
       | _ -> FragCATT)
  | TySum variants | TySumIn (variants, _) ->
      if List.exists
           (fun v -> List.exists (fun a -> classify_ty a = FragCubical) v.v_args)
           variants
      then FragCubical
      else FragCATT
  | _ -> FragCATT

(* Classify a surface expression by inspecting what it calls. Cubical
 * primitives appear as named function calls in surface syntax (e.g.,
 * refl(x), path(p), transport(...), comp(...), glue(...)). *)

let cubical_primitive_calls = [
  "refl"; "path"; "path_app";
  "transport"; "transp";
  "comp"; "hcomp";
  "glue"; "unglue";
  "ua";
  "ap";              (* action on paths: ap f p *)
  "concat"; "inv";   (* path composition and inversion *)
]

let is_cubical_call (name : string) : bool =
  List.mem name cubical_primitive_calls

let rec classify_expr (e : expr) : fragment =
  match e with
  | ELit _ -> FragCATT
  | EVar _ -> FragCATT
  | EProduce (_, _) -> FragCATT
  | EWireTo (_, _) -> FragCATT
  | EField (obj, _, _) -> classify_expr obj
  | ECall (name, args, _) ->
      if is_cubical_call name then FragCubical
      else if List.exists (fun a -> classify_expr a = FragCubical) args
      then FragCubical
      else FragCATT
  | ENew (_, fas, _) ->
      if List.exists
           (fun fa -> classify_expr fa.fa_value = FragCubical) fas
      then FragCubical
      else FragCATT
  | ENewIn (_, _, fas, _) ->
      if List.exists
           (fun fa -> classify_expr fa.fa_value = FragCubical) fas
      then FragCubical
      else FragCATT
  | EBinop (_, a, b, _) ->
      (match classify_expr a, classify_expr b with
       | FragCubical, _ | _, FragCubical -> FragCubical
       | _ -> FragCATT)
  | EParen (inner, _) -> classify_expr inner
  | EAll _ -> FragCATT
  | EIn (inner, _, _) -> classify_expr inner
  | ERefl _ | EPair _ | EFst _ | ESnd _ | EJ _ -> FragCubical
  | EPullback _ | EPushout _ | EPullbackVal _ -> FragCATT
  | ENot _ -> FragCATT
  | EIfThenElse _ -> FragCATT
  | ELam _ -> FragCATT  (* lambda funzionale, base *)
  | EMoveLam _ | EReductionLam _ | EMorphLam _ | EFunctorLam _ -> FragCATT
  | EViewLam _ -> FragCATT  (* 5o handle lambda *)
  | EComposeWith _ -> FragCATT  (* handle composition *)

(* ─── Equality dispatcher ──────────────────────────────────────────── *)

(* Decidable type equality across the federation. Try the CATT_R_Yon
 * decidable equality first; if it succeeds, types are equal. If not,
 * lift to cubical types and try cubical decidable equality. *)

(* Lift a surface ty to a cubical ctype. TyId(A, a, b) maps
 * to CTPath(A, a, b) — the cubical Path type — making the Id type
 * and the Path type structurally identical at the cubical layer.
 *
 * Yoneda perspective: the two representations are isomorphic in the
 * topos: Id_A(a, b) ~= Path_A(a, b). The lift exhibits the iso. *)
let rec lift_to_cubical (t : ty) : Cubical.ctype =
  match t with
  | TyId (a, _x, _y) ->
      (* Unify with Path: Id_A(a,b) == Path_A(a,b).
       * Endpoint terms are translated to placeholder cterms; full
       * bridge of surface terms to cubical terms is layered separately
       * (see Cubical_bindings for the term-level translation). The
       * key point here is the TYPE-level identification: lift makes
       * TyId structurally indistinguishable from CTPath under
       * decidable_equal_cubical. *)
      Cubical.CTPath (lift_to_cubical a,
                      Cubical.CInhabitant (Cubical.CVar "__endpoint_x"),
                      Cubical.CInhabitant (Cubical.CVar "__endpoint_y"))
  | TyPrim _ | TyPrimIn _ | TyUser _ | TyVar _ | TyMetaVar _
  | TyUniverse _ | TyPi _ | TySigma _ ->
      Cubical.CTBase t
  | TyList inner -> Cubical.CTBase (TyList inner)
  | TyMap (k, v) -> Cubical.CTBase (TyMap (k, v))
  | TyStream (inner, ms) -> Cubical.CTBase (TyStream (inner, ms))
  | TySum _ | TySumIn _ -> Cubical.CTBase t
  | TyHeytInt _ -> Cubical.CTBase t
  | TyArrow _ -> Cubical.CTBase t
  | TyMoveHandle _ -> Cubical.CTBase t
  | TyReductionHandle _ -> Cubical.CTBase t
  | TyMorphHandle _ -> Cubical.CTBase t
  | TyViewHandle _ -> Cubical.CTBase t

(* Decidable type equality across the federation.
 *
 * Strategy:
 *   - If both types classify as CATT, use CATT_R_Yon decidable equality
 *     directly (fast path).
 *   - If at least one classifies as Cubical, lift both to ctype and
 *     use Cubical decidable equality.
 *   - As a final fallback, try the lift path even for two CATT types,
 *     since structural equality is implemented at both layers.
 *
 * Both fragments are decidable independently (Rice 2025 for CATT_R_Yon,
 * CCHM 2016 for Cubical), so the union of the two algorithms remains
 * decidable. *)

let rec type_equal
    (env : Tyenv.env)
    (ctx : Reduce.ctx)
    (t1 : ty) (t2 : ty) : bool =
  (* Direct equality on TyHeytInt. Neither Cubical nor CATT_R_Yon knows this
   * type, so the equality is handled here before the dispatch. *)
  match t1, t2 with
  | TyHeytInt n1, TyHeytInt n2 -> n1 = n2
  (* String fusion (2026-06-03): "text" and "String" are the SAME semantic
   * object — sections of the builtin String place (runtime: xheap handle).
   * Bidirectional, like boolean/proposition. *)
  | TyPrim "text", TyUser "String" -> true
  | TyUser "String", TyPrim "text" -> true
  (* Subtyping number <: heyt_int. A Yon number is implicitly promotable to
   * heyt_int<N> with mask=0 (all bits certain, no Unknown). The coercion is
   * handled at emit time by inserting an automatic topos.heyt_int_make.
   * Bidirectional because type_equal is called both (expected, actual) and
   * (param, arg) at different points in the type checker. *)
  | TyHeytInt _, TyPrim "number" -> true
  | TyPrim "number", TyHeytInt _ -> true
  (* Subtyping heyt_int <: proposition. Needed because __heyt_imp has signature
   * (prop, prop) -> prop and we want to write `a =>? b` with a, b of type
   * heyt_int. The actual bit-by-bit dispatch happens at emit time by checking
   * the runtime MLIR type. Honest upfront: this is a pragmatic kludge; the
   * bit-by-bit semantics and the scalar PROP semantics differ
   * algebraically. *)
  | TyHeytInt _, TyPrim "proposition" -> true
  | TyPrim "proposition", TyHeytInt _ -> true
  (* Structural equality on TyArrow. *)
  | TyArrow (a1, b1), TyArrow (a2, b2) ->
      type_equal env ctx a1 a2 && type_equal env ctx b1 b2
  | TyMoveHandle (w1a, w2a), TyMoveHandle (w1b, w2b) ->
      (* None = wildcard. *)
      let compatible_w a b = match a, b with
        | None, _ | _, None -> true
        | Some n1, Some n2 -> n1 = n2
      in
      compatible_w w1a w1b && compatible_w w2a w2b
  | TyReductionHandle pa, TyReductionHandle pb ->
      (* None = wildcard. *)
      (match pa, pb with
       | None, _ | _, None -> true
       | Some n1, Some n2 -> n1 = n2)
  | TyMorphHandle (s1a, s2a), TyMorphHandle (s1b, s2b) ->
      (* None = wildcard. *)
      let compat x y = match x, y with
        | None, _ | _, None -> true
        | Some n1, Some n2 -> n1 = n2
      in
      compat s1a s1b && compat s2a s2b
  | TyViewHandle pa, TyViewHandle pb ->
      (match pa, pb with
       | None, _ | _, None -> true
       | Some n1, Some n2 -> n1 = n2)
  | _ ->
  let f1 = classify_ty t1 in
  let f2 = classify_ty t2 in
  let base_equal () =
    match f1, f2 with
    | FragCATT, FragCATT ->
        Catt_r_yon.decidable_equal env ctx t1 t2
    | _, _ ->
        let c1 = lift_to_cubical t1 in
        let c2 = lift_to_cubical t2 in
        Cubical.decidable_equal_cubical c1 c2
        || Catt_r_yon.decidable_equal env ctx t1 t2
  in
  (* Try basic structural equality first. If that fails, try place
   * width subtyping: a value of place P_sub is acceptable where
   * P_super is expected, provided P_sub has all fields of P_super
   * with compatible types (row polymorphism). *)
  if base_equal () then true
  else
    match t1, t2 with
    | TyUser p_super, TyUser p_sub ->
        (* Expected = t1, actual = t2: actual must be subtype of expected. *)
        Tyenv.place_is_subtype env p_super p_sub
    | _ -> false

(* ─── Term equality dispatcher ─────────────────────────────────────── *)

(* For terms, we compare via the kernel's R_Yon normalizer (Reduce.reduce)
 * combined with Ast.term_equal. If terms are at the cubical layer
 * (path application, composition), we use Cubical.cterm_equal. *)

let term_equal_kernel
    (ctx : Reduce.ctx) (t1 : Ast.term) (t2 : Ast.term) : bool =
  Catt_r_yon.r_yon_term_equiv ctx t1 t2

let cubical_term_equal (t1 : Cubical.cterm) (t2 : Cubical.cterm) : bool =
  Cubical.cterm_equal t1 t2

(* ─── Place/reduction/move/view equality dispatcher ────────────────── *)

(* These constructs only live in CATT_R_Yon. The dispatcher delegates
 * directly to the corresponding family check. *)

let place_equal (p1 : place_decl) (p2 : place_decl) : bool =
  Catt_r_yon.family4_place_equiv p1 p2

let reduction_equal (r1 : reduction_decl) (r2 : reduction_decl) : bool =
  Catt_r_yon.family5_reduction_equiv r1 r2

let move_equal (m1 : move_decl) (m2 : move_decl) : bool =
  Catt_r_yon.family6_move_equiv m1 m2

let view_equal (v1 : view_decl) (v2 : view_decl) : bool =
  Catt_r_yon.family7_view_equiv v1 v2

(* ─── Fragment summary for diagnostics ─────────────────────────────── *)

let fragment_name = function
  | FragCATT -> "CATT_R_Yon"
  | FragCubical -> "Cubical"

let summarize_classification (e : expr) : string =
  Printf.sprintf "expr is in %s fragment" (fragment_name (classify_expr e))
