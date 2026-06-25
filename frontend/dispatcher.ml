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
  | TyList inner | TyStream inner -> classify_ty inner
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
  | EApp _ -> FragCATT  (* general application *)
  | EHITElim _ -> FragCubical  (* HIT eliminator *)
  | EPathApp _ -> FragCubical  (* path application p @ i *)
  | EPathAbs _ -> FragCubical  (* path abstraction plam i => e *)
  | EHITConstr _ -> FragCubical  (* HIT constructor hit(...) *)
  | EMoveLam _ | EReductionLam _ | EMorphLam _ | EFunctorLam _ -> FragCATT
  | EViewLam _ -> FragCATT  (* 5o handle lambda *)
  | EComposeWith _ -> FragCATT  (* handle composition *)
  | ESpawn _ -> FragCATT
  | EQuote _ | EElMatch _ -> FragCubical

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
  | TyPathP ((i, a), _, _) ->
      Cubical.CTPathP ((i, lift_to_cubical a),
                       Cubical.CInhabitant (Cubical.CVar "__endpoint_x"),
                       Cubical.CInhabitant (Cubical.CVar "__endpoint_y"))
  | TyPrim _ | TyPrimIn _ | TyUser _ | TyVar _ | TyMetaVar _
  | TyUniverse _ | TyPi _ | TySigma _ ->
      Cubical.CTBase t
  | TyList inner -> Cubical.CTBase (TyList inner)
  | TyMap (k, v) -> Cubical.CTBase (TyMap (k, v))
  | TyStream inner -> Cubical.CTBase (TyStream inner)
  | TySum _ | TySumIn _ -> Cubical.CTBase t
  | TyHeytInt _ -> Cubical.CTBase t
  | TyArrow _ -> Cubical.CTBase t
  | TyMoveHandle _ -> Cubical.CTBase t
  | TyReductionHandle _ -> Cubical.CTBase t
  | TyMorphHandle _ -> Cubical.CTBase t
  | TyViewHandle _ -> Cubical.CTBase t
  | TyWire _ | TySubscription _ | TyEl _ -> Cubical.CTBase t

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

(* Alpha-renaming of a free variable inside an expression / type, so that
 * dependent types (TyPi / TyId) can be compared up to the bound-variable
 * name. Needed by the equiv coherence check below. *)
let rec rename_evar (old_n : string) (new_n : string) (e : expr) : expr =
  let r = rename_evar old_n new_n in
  match e with
  | EVar (n, loc) -> if String.equal n old_n then EVar (new_n, loc) else e
  | EApp (h, args, loc) -> EApp (r h, List.map r args, loc)
  | ECall (n, args, loc) -> ECall (n, List.map r args, loc)
  | EField (obj, fld, loc) -> EField (r obj, fld, loc)
  | EBinop (op, l, ri, loc) -> EBinop (op, r l, r ri, loc)
  | EParen (inner, loc) -> EParen (r inner, loc)
  | _ -> e

let rename_ty_term (old_n : string) (new_n : string) (tt : ty_term) : ty_term =
  match tt with TyTermExpr ex -> TyTermExpr (rename_evar old_n new_n ex)

let rec rename_ty (old_n : string) (new_n : string) (t : ty) : ty =
  let r = rename_ty old_n new_n in
  let rt = rename_ty_term old_n new_n in
  match t with
  | TyId (a, x, y) -> TyId (r a, rt x, rt y)
  | TyEl c -> TyEl (rt c)
  | TyArrow (a, b) -> TyArrow (r a, r b)
  | TyPi (v, d, c) ->
      if String.equal v old_n then TyPi (v, r d, c) else TyPi (v, r d, r c)
  | TySigma (v, d, c) ->
      if String.equal v old_n then TySigma (v, r d, c) else TySigma (v, r d, r c)
  | TyPathP ((i, a), x, y) -> TyPathP ((i, r a), rt x, rt y)
  | _ -> t

(* Index of user function declarations (with bodies), populated by the type
 * checker at registration time. Used to compare path endpoints UP TO
 * normalization: a call g(f a) is inlined/folded so it can match a when f, g
 * are inverse. Empty when comparison happens outside program registration
 * (e.g. unit-test oracles), in which case we fall back to syntactic equality. *)
(* SCT-certified delta-rules from the environment, in the form the reducer
 * expects (name -> curried-lambda Core body). Only certified-terminating
 * functions are included, so kernel normalization with these needs no fuel
 * and no step cap. *)
let certified_deltas (env : Tyenv.env) : (string * Ast.term) list =
  let peel t =
    let rec go acc = function
      | Ast.Lam (x, _, b) -> go (x :: acc) b
      | other -> (List.rev acc, other)
    in
    go [] t
  in
  let fundefs =
    List.map
      (fun (name, lam) ->
         let params, body = peel lam in
         Sct.{ name; params; body })
      env.Tyenv.delta
  in
  let certified = Sct.certify fundefs in
  List.filter (fun (name, _) -> List.mem name certified) env.Tyenv.delta

(* Reify only the closed arithmetic fragment left after certified delta
 * unfolding.  Returning [None] for every other Core constructor keeps the
 * ring fallback conservative: it can prove polynomial identities, never
 * reinterpret an arbitrary kernel term as arithmetic. *)
let rec arith_of_ast (t : Ast.term) : Surface_ast.expr option =
  let module S = Surface_ast in
  let loc = S.dummy_loc in
  let binop op a b =
    match arith_of_ast a, arith_of_ast b with
    | Some a', Some b' -> Some (S.EBinop (op, a', b', loc))
    | _ -> None
  in
  match t with
  | Ast.App (Ast.App (Ast.Var "__add", a), b) -> binop S.OpAdd a b
  | Ast.App (Ast.App (Ast.Var "__sub", a), b) -> binop S.OpSub a b
  | Ast.App (Ast.App (Ast.Var "__mul", a), b) -> binop S.OpMul a b
  | Ast.App (Ast.App (Ast.Var "__div", a), b) -> binop S.OpDiv a b
  | Ast.Var name when String.length name > 6
                       && String.sub name 0 6 = "__num_" ->
      (try
         let suffix = String.sub name 6 (String.length name - 6) in
         Some (S.ELit (S.LitNumber (float_of_string suffix), loc))
       with Failure _ -> None)
  | Ast.Var name -> Some (S.EVar (name, loc))
  | _ -> None

(* Endpoint equality: two path endpoints are equal iff their underlying
 * expressions are syntactically equal, or become equal after KERNEL
 * normalization with delta-conversion. The delta-rules are the SCT-certified
 * function definitions from the environment; normalization is fuel-free
 * because certification guarantees termination. This replaces the old surface
 * inliner (Naturality_symcheck.normalize with its magic-number cap of 50) and
 * the global surface_fun_idx ref: one normalizer (the kernel), no parallel
 * surface path, no cap. *)
let ty_term_equal
    (env : Tyenv.env) (ctx : Reduce.ctx) (t1 : ty_term) (t2 : ty_term) : bool =
  match t1, t2 with
  | TyTermExpr e1, TyTermExpr e2 ->
      if Naturality_symcheck.expr_equal e1 e2 then true
      else
        (match Desugar.desugar_expr_pure env e1,
               Desugar.desugar_expr_pure env e2 with
         | Some c1, Some c2 ->
             let dctx = { ctx with Reduce.deltas = certified_deltas env } in
             let nf1 = Reduce.normalize dctx c1 in
             let nf2 = Reduce.normalize dctx c2 in
             if Ast.term_equal nf1 nf2 then true
             else
               (match arith_of_ast nf1, arith_of_ast nf2 with
                | Some a1, Some a2 ->
                    Naturality_symcheck.ring_equal a1 a2 = Some true
                | _ -> false)
         | _ -> false)

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
  (* NB: the one-way PROMOTIONS  number <: heyt_int  and  heyt_int <: proposition
   * used to live here as SYMMETRIC arms, which unsoundly also accepted the
   * reverse (a heyt_int where a number is expected, a prop where a heyt_int is
   * expected). type_equal is now strict equality; the directional promotions
   * moved to `subtype` below and are applied only at value-flow sites
   * (argument passing, return, assignment, field store). *)
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
  | TyEl c1, TyEl c2 ->
      (* El(c1) = El(c2) iff the decoded carriers are equal. *)
      let nm c = (match c with Surface_ast.TyTermExpr e -> Surface_ast.ty_term_to_name e) in
      Catt_r_yon.el_equal env ctx
        (Catt_r_yon.TmVar (nm c1)) (Catt_r_yon.TmVar (nm c2))
  | TyId (a1, x1, y1), TyId (a2, x2, y2) ->
      (* Identity types are equal iff the carriers AND both endpoints match.
       * This is what makes equiv's coherence check non-vacuous: the type
       * g(f a) = a is NOT the same as a = a. Previously TyId fell through to
       * lift_to_cubical, which discards the endpoints — so any two paths over
       * the same carrier compared equal, and the coherence check was empty. *)
      type_equal env ctx a1 a2
      && ty_term_equal env ctx x1 x2 && ty_term_equal env ctx y1 y2
  | TyPathP ((i1, a1), x1, y1), TyPathP ((i2, a2), x2, y2) ->
      (* Same soundness reason as the TyId arm above: a path from p to q is NOT
       * the same type as a path from p to r, so the carrier AND both endpoints
       * must match. Without this arm TyPathP fell through to lift_to_cubical,
       * which discards the endpoints (replacing them with the fixed placeholders
       * __endpoint_x/_y at L156), so any two PathP over the same carrier
       * compared equal — the exact endpoint-blind hole TyId had before e44e5f9.
       *
       * Difference from TyId: PathP binds an interval variable i in the carrier
       * line (i. A), so the carriers are compared UP TO the bound interval-name,
       * as TyPi does for its bound variable (rename_ty below). The endpoints
       * x, y live at the i=0/i=1 boundary, OUTSIDE the i-binding, so they carry
       * no free i and are compared directly — exactly like TyId. *)
      let a2' = if String.equal i1 i2 then a2 else rename_ty i2 i1 a2 in
      type_equal env ctx a1 a2'
      && ty_term_equal env ctx x1 x2 && ty_term_equal env ctx y1 y2
  | TyPi (v1, d1, c1), TyPi (v2, d2, c2) ->
      (* Dependent function types, compared up to the bound variable name. *)
      type_equal env ctx d1 d2
      && (let c2' = if String.equal v1 v2 then c2 else rename_ty v2 v1 c2 in
          type_equal env ctx c1 c2')
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
  (* Try basic equality first. If that fails, place substitution follows only
   * the declared [subcontains] chain; structural field coincidence does not
   * create an implicit inclusion. *)
  if base_equal () then true
  else
    match t1, t2 with
    | TyUser p_super, TyUser p_sub ->
        (* Expected = t1, actual = t2: actual must declare inclusion in expected. *)
        Tyenv.place_subcontains env p_sub p_super
        || Tyenv.place_transportable env p_sub p_super
    | _ -> false

(* ─── Directional subtyping  sub <: super ──────────────────────────────
 * `subtype ~sub ~super` holds when a value of type [sub] may be used where a
 * value of type [super] is expected. It is EQUALITY (via type_equal, whose
 * place arm is already directional with t1=super, t2=sub — hence the argument
 * order below) OR a sound one-way PROMOTION:
 *     number      <: heyt_int<N>   (mask=0: every bit certain; coerced at emit)
 *     heyt_int<N> <: proposition   (bit-by-bit lowered to scalar PROP at emit)
 *     number      <: proposition   (by transitivity)
 * These promotions previously lived as SYMMETRIC arms in type_equal, which
 * unsoundly accepted the reverse direction (a heyt_int where a number is
 * expected). Routing them through this directional relation, used only at
 * value-flow sites, removes that hole while keeping the legitimate coercions.
 * CATT/HoTT conversion (type_equal's dispatch) is untouched. *)
let subtype (env : Tyenv.env) (ctx : Reduce.ctx) ~(sub : ty) ~(super : ty) : bool =
  type_equal env ctx super sub
  || (match sub, super with
      | TyPrim "number", TyHeytInt _ -> true
      | TyHeytInt _, TyPrim "proposition" -> true
      | TyPrim "number", TyPrim "proposition" -> true
      | _ -> false)

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
 * directly to the corresponding per-construct equality check. *)

let place_equal (p1 : place_decl) (p2 : place_decl) : bool =
  Catt_r_yon.structural_place_equiv p1 p2

let reduction_equal (r1 : reduction_decl) (r2 : reduction_decl) : bool =
  Catt_r_yon.reduction_equiv r1 r2

let move_equal (m1 : move_decl) (m2 : move_decl) : bool =
  Catt_r_yon.move_equiv m1 m2

let view_equal (v1 : view_decl) (v2 : view_decl) : bool =
  Catt_r_yon.view_equiv v1 v2

(* ─── Fragment summary for diagnostics ─────────────────────────────── *)

let fragment_name = function
  | FragCATT -> "CATT_R_Yon"
  | FragCubical -> "Cubical"

let summarize_classification (e : expr) : string =
  Printf.sprintf "expr is in %s fragment" (fragment_name (classify_expr e))
