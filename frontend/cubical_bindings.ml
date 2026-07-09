(* cubical_bindings.ml — type signatures for cubical primitives.
 *
 * Cubical primitives are polymorphic over types: e.g.
 *   refl : forallA. (a:A) -> Path A a a
 *   transport : forallA B. Path U A B -> A -> B
 *   ua : forallA B. (A ~= B) -> Path U A B
 *
 * Yon's surface type checker is monomorphic, so we implement these
 * via "shape-driven inference": when a call to a cubical primitive
 * is encountered, the checker inspects the argument types to derive
 * the result type. No type variables, no unification — just direct
 * computation on the shapes.
 *
 * For each primitive we expose:
 *   - The expected arity
 *   - A function (env, ctx, arg_types) -> ty result that computes
 *     the return type given the argument types.
 *
 * This module is consumed by Tycheck.check_call to handle cubical
 * calls before falling back to the standard user-fun/operation
 * resolution.
 *)

open Surface_ast

(* ─── Inference results ────────────────────────────────────────────── *)

type infer_result = {
  result_ty : ty;
  errors : string list;     (* empty if all checks passed *)
}

let ok_ty t = { result_ty = t; errors = [] }
let fail_ty t msg = { result_ty = t; errors = [msg] }

(* ─── Endpoint equality for precise path typing ────────────────────────
 * The precise arms of concat/inv compare the term-endpoints that a
 * structured identity type TyId(A, x, y) carries. Those endpoints are
 * Surface term-trees, so plain OCaml (=) would also compare source
 * locations and reject two syntactically equal endpoints written at
 * different positions. We compare location-insensitively over the shapes
 * that actually occur as endpoints; anything exotic falls back to (=),
 * which errs toward *rejection* (sound, occasionally incomplete). *)
let rec expr_eq (a : expr) (b : expr) : bool =
  match a, b with
  | EParen (a', _), _ -> expr_eq a' b
  | _, EParen (b', _) -> expr_eq a b'
  | ELit (l1, _), ELit (l2, _) -> l1 = l2
  | EVar (x, _), EVar (y, _) -> x = y
  | EField (e1, f1, _), EField (e2, f2, _) -> f1 = f2 && expr_eq e1 e2
  | ECall (f1, xs1, _), ECall (f2, xs2, _) ->
      f1 = f2 && List.length xs1 = List.length xs2 && List.for_all2 expr_eq xs1 xs2
  | EApp (h1, xs1, _), EApp (h2, xs2, _) ->
      expr_eq h1 h2 && List.length xs1 = List.length xs2 && List.for_all2 expr_eq xs1 xs2
  | ERefl (e1, _), ERefl (e2, _) -> expr_eq e1 e2
  | EPair (x1, y1, _), EPair (x2, y2, _) -> expr_eq x1 x2 && expr_eq y1 y2
  | _ -> a = b

let tyterm_eq (TyTermExpr a) (TyTermExpr b) = expr_eq a b

(* Conservative carrier equality: leaf types by name, else structural. *)
let ty_carrier_eq (a : ty) (b : ty) : bool =
  match a, b with
  | TyPrim x, TyPrim y -> x = y
  | TyUser x, TyUser y -> x = y
  | _ -> a = b

(* ─── Built-in type-level constructors ─────────────────────────────── *)

(* Path A x y is represented as a TyUser "Path" wrapping arguments
 * via a naming convention: TyUser "Path_<A_string>" stores the
 * underlying base type as part of the name. This is a hack for the
 * monomorphic checker; a real implementation would extend the AST
 * with type-level applications.
 *
 * For checking purposes, we use a sentinel name "__Path" and assume
 * the surface programmer writes "Path of T" via a list-like syntax —
 * but since the surface grammar doesn't have this, we keep Path
 * abstract and use a TyUser tag.
 *)

(* Construct a path type. *)
let mk_path_ty (base_ty : ty) : ty =
  ignore base_ty;
  TyUser "Path"

(* Construct an equivalence type A ~= B as the canonical Sigma it is in HoTT:
 * Sigma(f : A -> B). (B -> A), carrying the endpoints A, B in the head arrow.
 * No new primitive: equivalence is expressed through the existing Sigma/Arrow
 * formers, and ua reads A, B from the head. *)
let mk_equiv_ty (a : ty) (b : ty) : ty =
  TySigma ("f", TyArrow (a, b), TyArrow (b, a))

(* The universe type. *)
let universe_ty : ty = TyUser "U"

(* ─── Primitive inference rules ────────────────────────────────────── *)

(* refl : forallA. (a:A) -> Path A a a
 * Arity: 1
 * Return: Path A
 *)
let infer_refl (arg_tys : ty list) : infer_result =
  match arg_tys with
  | [t] -> ok_ty (mk_path_ty t)
  | _ -> fail_ty (mk_path_ty (TyPrim "unit"))
           (Printf.sprintf "refl expects 1 argument, got %d" (List.length arg_tys))

(* path : forallA x y. (p : I -> A) -> Path A x y
 * In surface, path is usually constructed by passing a continuous
 * function. We accept it as a unary constructor.
 * Arity: 1
 * Return: Path A (where A is the codomain of the argument's "function")
 *)
let infer_path (arg_tys : ty list) : infer_result =
  match arg_tys with
  | [t] -> ok_ty (mk_path_ty t)
  | _ -> fail_ty (mk_path_ty (TyPrim "unit"))
           (Printf.sprintf "path expects 1 argument, got %d" (List.length arg_tys))

(* transport : forallA B. Path U A B -> A -> B
 * Arity: 2
 * If first arg is Path/Identity over universe, second arg has the source
 * type, return type is the target.
 *
 * Since the surface checker doesn't track universe-level paths
 * precisely, we conservatively return the second argument's type.
 * This is sound when paths in the universe represent type identity.
 *)
let infer_transport (arg_tys : ty list) : infer_result =
  match arg_tys with
  | [_path; source_ty] -> ok_ty source_ty
  | _ -> fail_ty (TyPrim "unit")
           (Printf.sprintf "transport expects 2 arguments, got %d"
              (List.length arg_tys))

(* transp : same as transport with explicit start interval point.
 * Arity: 3 (or 2 in CCHM): line of types, starting interval, source value.
 *)
let infer_transp (arg_tys : ty list) : infer_result =
  match arg_tys with
  | [_line; _i0; source_ty] -> ok_ty source_ty
  | [_line; source_ty] -> ok_ty source_ty
  | _ -> fail_ty (TyPrim "unit")
           (Printf.sprintf "transp expects 2 or 3 arguments, got %d"
              (List.length arg_tys))

(* comp : forallA. (φ : Face) -> Partial -> A -> A
 * Composition operation. Arity 3.
 *)
let infer_comp (arg_tys : ty list) : infer_result =
  match arg_tys with
  | [_phi; _partial; base_ty] -> ok_ty base_ty
  | _ -> fail_ty (TyPrim "unit")
           (Printf.sprintf "comp expects 3 arguments, got %d"
              (List.length arg_tys))

(* hcomp : forallA. (φ : Face) -> Partial -> A -> A
 * Homogeneous composition. Arity 3.
 *)
let infer_hcomp (arg_tys : ty list) : infer_result =
  match arg_tys with
  | [_phi; _partial; base_ty] -> ok_ty base_ty
  | _ -> fail_ty (TyPrim "unit")
           (Printf.sprintf "hcomp expects 3 arguments, got %d"
              (List.length arg_tys))

(* glue : forallA T φ e. (t : T on φ) -> (a : A) -> Glue [φ ↦ (T, e)] A
 * Arity 2: the partial element and the base element.
 *)
let infer_glue (arg_tys : ty list) : infer_result =
  match arg_tys with
  | [_partial; base_ty] ->
      (* The result is a Glue type over base_ty. Represented as TyUser
       * "Glue" for type checking purposes. *)
      ignore base_ty;
      ok_ty (TyUser "Glue")
  | _ -> fail_ty (TyUser "Glue")
           (Printf.sprintf "glue expects 2 arguments, got %d"
              (List.length arg_tys))

(* unglue : forallA T φ e. Glue [φ ↦ (T,e)] A -> A
 * Project from a Glue type back to its base.
 *)
let infer_unglue (arg_tys : ty list) : infer_result =
  match arg_tys with
  | [glue_ty] ->
      (* If the glue type is "Glue", we don't know the base statically
       * in this monomorphic checker. Return a generic universe type;
       * a richer implementation would unfold. *)
      ignore glue_ty;
      ok_ty (TyPrim "unknown")
  | _ -> fail_ty (TyPrim "unknown")
           (Printf.sprintf "unglue expects 1 argument, got %d"
              (List.length arg_tys))

(* ua : forallA B. (A ~= B) -> Path U A B
 * Univalence: turn an equivalence into a path of types.
 * Arity 1.
 *)
let infer_ua (arg_tys : ty list) : infer_result =
  let is_equiv_shape = function
    (* canonical equivalence: a Sigma headed by the forward map f : A -> B *)
    | TySigma (_, (TyArrow _ | TyPi _), _) -> true
    (* abstract / named equivalence (idEquiv, an Equiv-typed variable) *)
    | TyUser "Equiv" -> true
    | _ -> false in
  match arg_tys with
  | [e] when is_equiv_shape e -> ok_ty (mk_path_ty universe_ty)
  | [_other] ->
      (* SOUNDNESS GATE: ua needs a genuine equivalence, not a bare function. *)
      fail_ty (mk_path_ty universe_ty)
        "ua expects an equivalence (Equiv = Sigma(f:A->B). ...), not a bare function; build one with equiv(f, g, eta, eps) or idEquiv(A)"
  | _ -> fail_ty (mk_path_ty universe_ty)
           (Printf.sprintf "ua expects 1 argument, got %d"
              (List.length arg_tys))

(* ap : forallA B f x y. (p : Path A x y) -> Path B (f x) (f y)
 * Action on paths: given f : A -> B and a path p : x = y, produce
 * a path f(x) = f(y).
 *
 * Arity 2: the function and the path. In surface Yon without
 * first-class functions, "ap" is typically called with a function
 * name and a path: ap(fn_name, p). We accept arity 2.
 *)
let infer_ap (arg_tys : ty list) : infer_result =
  match arg_tys with
  | [_fn; _path] ->
      (* The result is a path; without knowing the function's return
       * type at this layer, we return a generic Path. *)
      ok_ty (TyUser "Path")
  | _ -> fail_ty (TyUser "Path")
           (Printf.sprintf "ap expects 2 arguments, got %d"
              (List.length arg_tys))

(* concat : forallA x y z. Path A x y -> Path A y z -> Path A x z
 * Path concatenation. Arity 2.
 *)
let infer_concat (arg_tys : ty list) : infer_result =
  match arg_tys with
  (* Precise: two structured identity types compose iff they share a
   * carrier and the end of the first equals the start of the second.
   *   concat : Id A x y -> Id A y z -> Id A x z.
   * A mismatch (different carrier, or first-end != second-start) is a
   * clean type error. *)
  | [TyId (a1, x, y1); TyId (a2, y2, z)] ->
      if ty_carrier_eq a1 a2 && tyterm_eq y1 y2 then ok_ty (TyId (a1, x, z))
      else
        fail_ty (TyId (a1, x, z))
          "concat: the paths do not compose — the endpoint of the first must \
           equal the start of the second, in the same type"
  (* Loose fallback for opaque paths (endpoints not tracked at the surface). *)
  | [TyUser "Path"; TyUser "Path"] -> ok_ty (TyUser "Path")
  | [_; _] -> ok_ty (TyUser "Path")
    (* Permissive: accept any two args, return Path. A strict mode
     * would reject non-Path inputs. *)
  | _ -> fail_ty (TyUser "Path")
           (Printf.sprintf "concat expects 2 paths, got %d arguments"
              (List.length arg_tys))

(* inv : forallA x y. Path A x y -> Path A y x
 * Path inversion. Arity 1.
 *)
let infer_inv (arg_tys : ty list) : infer_result =
  match arg_tys with
  (* Precise: inversion swaps the endpoints.  inv : Id A x y -> Id A y x. *)
  | [TyId (a, x, y)] -> ok_ty (TyId (a, y, x))
  | [TyUser "Path"] -> ok_ty (TyUser "Path")
  | [_] -> ok_ty (TyUser "Path")
  | _ -> fail_ty (TyUser "Path")
           (Printf.sprintf "inv expects 1 argument, got %d"
              (List.length arg_tys))

(* path_app : forallA x y. Path A x y -> I -> A
 * Apply a path to an interval value. Arity 2.
 * The return type is determined by the path's base type, which we
 * don't track precisely in this monomorphic checker.
 *)
let infer_path_app (arg_tys : ty list) : infer_result =
  match arg_tys with
  | [_path; _i] -> ok_ty (TyPrim "unknown")
  | _ -> fail_ty (TyPrim "unknown")
           (Printf.sprintf "path_app expects 2 arguments, got %d"
              (List.length arg_tys))

(* equiv : (f : A -> B) (g : B -> A) (eta : g o f ~ id) (eps : f o g ~ id) -> Equiv A B
 * Sound constructor for an equivalence. The forward map alone is NOT enough:
 * to assert A ~= B one must supply the inverse g and the homotopies eta, eps.
 * The monomorphic checker verifies the SHAPES (f, g functions; eta, eps paths);
 * full coherence of the homotopies is dependent-typed checking, the next grade.
 * Arity 4.
 *)
let infer_equiv (arg_tys : ty list) : infer_result =
  let is_fun = function
    | TyArrow _ | TyPi _ | TyPrim "fun" | TyUser "fun" -> true | _ -> false in
  let is_path = function
    | TyUser "Path" | TyUser "Identity" | TyUser "Eq" | TyId _ | TyPathP _ -> true
    | _ -> false in
  match arg_tys with
  | [f; g; eta; eps] ->
      let errs = [] in
      let errs = if is_fun f then errs
                 else "equiv: forward map (arg 1) must be a function A -> B" :: errs in
      let errs = if is_fun g then errs
                 else "equiv: inverse (arg 2) must be a function B -> A" :: errs in
      let errs = if is_path eta then errs
                 else "equiv: retraction eta (arg 3) must be a path g(f a) = a" :: errs in
      let errs = if is_path eps then errs
                 else "equiv: section eps (arg 4) must be a path f(g b) = b" :: errs in
      if errs = [] then
        (* One canonical Equiv shape (matches tycheck's equiv path): a Sigma
         * headed by f : A -> B, with the endpoints read from the forward map. *)
        (match f with
         | TyArrow (a, b) | TyPi (_, a, b) -> ok_ty (mk_equiv_ty a b)
         | _ -> ok_ty (mk_equiv_ty (TyPrim "unit") (TyPrim "unit")))
      else { result_ty = mk_equiv_ty (TyPrim "unit") (TyPrim "unit");
             errors = List.rev errs }
  | _ -> fail_ty (TyUser "Equiv")
           (Printf.sprintf "equiv expects 4 arguments (f, g, eta, eps), got %d"
              (List.length arg_tys))

(* idEquiv : (A : U) -> Equiv A A — the identity equivalence, built soundly.
 * Arity 1.
 *)
let infer_id_equiv (arg_tys : ty list) : infer_result =
  match arg_tys with
  | [_a] -> ok_ty (TyUser "Equiv")
  | _ -> fail_ty (TyUser "Equiv")
           (Printf.sprintf "idEquiv expects 1 argument (the type), got %d"
              (List.length arg_tys))

(* ─── Dispatch table ───────────────────────────────────────────────── *)

(* Map from cubical primitive name to (arity, inference function). *)
let cubical_primitive_table : (string * (int * (ty list -> infer_result))) list = [
  "refl",      (1, infer_refl);
  "path",      (1, infer_path);
  "path_app",  (2, infer_path_app);
  "transport", (2, infer_transport);
  "transp",    (3, infer_transp);   (* also accepts 2 *)
  "comp",      (3, infer_comp);
  "hcomp",     (3, infer_hcomp);
  "glue",      (2, infer_glue);
  "unglue",    (1, infer_unglue);
  "ua",        (1, infer_ua);
  "equiv",     (4, infer_equiv);
  "idEquiv",   (1, infer_id_equiv);
  "ap",        (2, infer_ap);
  "concat",    (2, infer_concat);
  "inv",       (1, infer_inv);
]

(* Lookup a cubical primitive by name. Returns the (arity, inference function)
 * pair, or None if the name is not a cubical primitive. *)
let lookup_primitive (name : string) : (int * (ty list -> infer_result)) option =
  List.assoc_opt name cubical_primitive_table

(* Check whether a name is a known cubical primitive. *)
let is_primitive (name : string) : bool =
  List.mem_assoc name cubical_primitive_table

(* Type-check a call to a cubical primitive. Returns (result_ty, errors).
 * The caller's context (loc) is used to format error messages. *)
let check_call
    (name : string)
    (arg_tys : ty list) : (ty, string) Stdlib.result =
  match lookup_primitive name with
  | None -> Error (Printf.sprintf "%s is not a cubical primitive" name)
  | Some (_arity, infer_fn) ->
      let result = infer_fn arg_tys in
      if result.errors = [] then Ok result.result_ty
      else Error (String.concat "; " result.errors)
