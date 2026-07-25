(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* tyenv.ml — type environment for the Yon type checker.
 *
 * Tracks term variables, place/world/reduction/fun declarations, and
 * operation signatures. Functional (persistent): extension does not
 * mutate the original env.
 *
 * Used by both the Cubical and CATT_R_Yon fragments through the
 * dispatcher. Type variables for the cubical layer are tracked as
 * separate "interval variables" since they live in a different
 * sort (the interval I).
 *)

open Surface_ast

(* ─── Cubical interval variables ───────────────────────────────────── *)

type interval_var = string

(* ─── Function signatures ──────────────────────────────────────────── *)

type fun_sig = {
  fs_params : (string * ty) list;
  fs_return : ty;
  fs_visits : string list;
  fs_partial : bool;
}

(* ─── Operation signatures ─────────────────────────────────────────── *)

type op_sig = {
  os_place : string;
  os_op_name : string;
  os_params : (string * ty) list;
  os_return : ty;
}

(* ─── The environment ──────────────────────────────────────────────── *)

type env = {
  vars : (string * ty) list;
  (* Structural sum signatures visible in the program. Each sum is the
     point-only HIT determined by its ordered constructor list. *)
  sum_types : variant list list;
  (* Named sum types (`inductive Tree = ...`): the name -> its ordered constructor
     list. Distinct from [sum_types] (anonymous inline sums) because the name is
     what lets a constructor argument refer to the type it defines. *)
  named_sums : (string * variant list) list;
  intervals : interval_var list;
  places : (string * place_decl) list;
  worlds : (string * world_decl) list;
  reductions : (string * reduction_decl) list;
  funs : (string * fun_sig) list;
  (* delta-rules: the desugared CORE body of each user function — the
   * rewrite rule used by definitional equality, distinct from `funs`
   * (its type signature). A function's *meaning*, not its *type*. Holds
   * Ast.term (Core), unlike the surface-typed fields above. Populated
   * once, side-effect-free; consumed by the kernel reducer's delta-step
   * (only for SCT-certified functions). *)
  delta : (string * Ast.term) list;
  ops : (string * op_sig) list;
  current_effects : string list;
  active_handlers : string list;
  (* Place pairs transportable only while checking a geometric morphism's
   * pull/push bodies. This is scoped typing evidence, not global subtyping. *)
  transport_pairs : (string * string) list;
  (* The spaces declared in the program, filled by register_decl. Used to
     validate the binding `topos T at S`. *)
  declared_spaces : string list;
  (* The morphisms declared in the program, filled by register_decl. Used to
     validate `nat_transform Name from F to G { ... }`, where F and G must be
     existing morphisms. *)
  declared_morphs : string list;
  (* Places SYNTHESIZED from payload arms (place refactor, prima pietra):
     real places for identity/injection/world, but with no user-written
     declaration — construction of their sections lands with the mediatrice
     step, so `new` on them is rejected (transitional). *)
  synthetic_places : string list;
  (* The full morph_decls, so we can read mp_source/mp_target while validating
     a nat_transform. *)
  morph_decls : (string * morph_decl) list;
  (* view_decls, for looking up a view name to its vw_of (the place). *)
  view_decls : (string * view_decl) list;
  (* topos_decls for topos-name -> tp_objects lookup, used to derive the target
   * place of m(x) when m: TyMorphHandle. *)
  topos_decls : (string * topos_decl) list;
}

let empty : env = {
  vars = [];
  sum_types = [];
  named_sums = [];
  intervals = [];
  places = [];
  worlds = [];
  reductions = [];
  funs = [];
  delta = [];
  ops = [];
  current_effects = [];
  active_handlers = [];
  transport_pairs = [];
  declared_spaces = [];
  declared_morphs = [];
  synthetic_places = [];
  morph_decls = [];
  view_decls = [];
  topos_decls = [];
}

let lookup_var (env : env) (x : string) : ty option =
  List.assoc_opt x env.vars

let lookup_place (env : env) (name : string) : place_decl option =
  List.assoc_opt name env.places

(* The data fields of a place (dropping ops/cells/laws). Used both for
   structural subtyping and for recognizing the terminal object. *)
let place_fields (pd : place_decl) : field_decl list =
  List.filter_map
    (function FoField f -> Some f | FoOp _ | FoCell _ | FoLaw _ -> None)
    pd.pd_members

(* Terminal object 1 (derived, not a primitive): a place with no data fields.
   Its unique inhabitant is the empty tuple `()`; for every place A there is a
   unique map `!_A : A -> 1`. We recognize 1 by its shape (zero fields) rather
   than adding a TyUnit former, keeping the core AST untouched. *)
let place_is_terminal (pd : place_decl) : bool =
  place_fields pd = []

(* Is the named place the terminal object of its world? *)
let name_is_terminal (env : env) (name : string) : bool =
  match lookup_place env name with
  | Some pd -> place_is_terminal pd
  | None -> false

(* ─── Place subtyping (row polymorphism) ─────────────────────────── *)

(* Structural width subtyping for places (rows):
 *   p_sub  <:_w  p_super
 *   ⟺   forall (name, ty) in fields(p_super).
 *          exists (name, ty') in fields(p_sub). ty == ty' (or ty' is "unknown")
 *
 * In words: p_sub has at least all the fields of p_super, with
 * compatible types. p_sub may have additional fields ("row variable").
 *
 * Uses a coarse type-equality check (no env/ctx access at this layer)
 * to avoid importing Tycheck/Dispatcher. Sufficient for nominal +
 * structural matching of basic types and place references. *)

let simple_ty_compatible (t1 : ty) (t2 : ty) : bool =
  (* Coarse equality: any "unknown" matches; same constructor + same
   * name/payload. This is intentionally permissive because the full
   * structural check happens in Dispatcher.type_equal. *)
  let is_unknown = function
    | TyPrim "unknown" | TyUser "unknown" -> true
    | _ -> false in
  (* "boolean" and "proposition" are the same semantic object (the Heyting
   * algebra Omega, the subobject classifier). The name "boolean" survives as a
   * syntactic alias. Semantically: t : boolean <=> t : proposition. *)
  let is_omega = function
    | TyPrim "boolean" | TyPrim "proposition" -> true
    | _ -> false in
  (* String fusion (2026-06-03): "text" and "String" are the same semantic
   * object — sections of the builtin String place (runtime: an xheap handle).
   * "text" survives as the primitive-family alias. *)
  let is_text = function
    | TyPrim "text" | TyUser "String" -> true
    | _ -> false in
  if is_unknown t1 || is_unknown t2 then true
  else if is_omega t1 && is_omega t2 then true
  else if is_text t1 && is_text t2 then true
  else
    match t1, t2 with
    | TyPrim n1, TyPrim n2 -> n1 = n2
    | TyPrim n1, TyPrimIn (n2, _) | TyPrimIn (n1, _), TyPrim n2 -> n1 = n2
    | TyPrim n1, TyUser n2 | TyUser n1, TyPrim n2 -> n1 = n2
    | TyUser n1, TyUser n2 -> n1 = n2
    | TyPrimIn (n1, _), TyPrimIn (n2, _) -> n1 = n2
    | _ -> t1 = t2

(* Declared place substitution. A value of [p_sub] is usable where [p_super]
 * is expected exactly when the reflexive-transitive [subcontains] chain says
 * so. The visited set makes malformed declaration cycles fail closed. *)
let place_subcontains (env : env) (p_sub : string) (p_super : string) : bool =
  let rec walk visited current =
    if current = p_super then true
    else if List.mem current visited then false
    else
      match lookup_place env current with
      | Some pd ->
          (match pd.pd_subcontains with
           | Some parent -> walk (current :: visited) parent
           | None -> false)
      | None -> false
  in
  walk [] p_sub

let with_transport_pair (env : env) (left : string) (right : string) : env =
  { env with transport_pairs = (left, right) :: env.transport_pairs }

let place_transportable (env : env) (left : string) (right : string) : bool =
  List.exists
    (fun (a, b) ->
       (a = left && b = right) || (a = right && b = left))
    env.transport_pairs

let lookup_world (env : env) (name : string) : world_decl option =
  List.assoc_opt name env.worlds

let lookup_reduction (env : env) (name : string) : reduction_decl option =
  List.assoc_opt name env.reductions

let lookup_fun (env : env) (name : string) : fun_sig option =
  List.assoc_opt name env.funs

(* Purity predicate over surface expressions. A call is pure iff the callee
 * declares no effects (fs_visits = []); unknown callees are conservatively
 * effectful. Lives here (not in Tycheck) because it needs only the env and
 * surface types — keeping it low lets Desugar consult it without a module
 * cycle through Tycheck. *)
let rec is_pure_expr (env : env) (e : expr) : bool =
  match e with
  | ELit _ | EVar _ -> true
  | EField (e1, _, _) | EParen (e1, _) | EFst (e1, _) | ESnd (e1, _)
  | ENot (e1, _) | ERefl (e1, _) -> is_pure_expr env e1
  | EBinop (_, a, b, _) | EPair (a, b, _) | EComposeWith (a, b, _) ->
      is_pure_expr env a && is_pure_expr env b
  | EApp (head, args, _) ->
      is_pure_expr env head && List.for_all (is_pure_expr env) args
  | EJ (a, b, c, _) ->
      is_pure_expr env a && is_pure_expr env b && is_pure_expr env c
  | EIfThenElse (c, t, el, _) ->
      is_pure_expr env c && is_pure_expr env t && is_pure_expr env el
  | ECall (name, args, _) ->
      (match lookup_fun env name with
       | Some fs -> fs.fs_visits = [] && List.for_all (is_pure_expr env) args
       | None -> false)
  (* A data constructor and its eliminator are effect-free: `hit(ctor, args)` is
     pure iff its arguments are, and `match`/`hit_elim` is pure iff its scrutinee
     and every branch body are. Recognizing them as pure lets the definitional-
     equality checker desugar and reduce inductive computations (e.g. a
     round-trip g(f(c)) on a constructor c), which the dependent eliminator needs
     to discharge coherences between distinct inductive types. *)
  | EHITConstr (_, args, _) -> List.for_all (is_pure_expr env) args
  | EHITElim (motive, branches, scrut, _) ->
      is_pure_expr env motive && is_pure_expr env scrut
      && List.for_all (fun (_, _, body) -> is_pure_expr env body) branches
  | ENew _ | ENewIn _ | EIn _ | EAll _
  | EMoveLam _ | EReductionLam _ | EMorphLam _ | EFunctorLam _ | EViewLam _
  | ELam _ | EPullback _ | EPushout _ | EPullbackVal _ -> false
  | _ -> false

(* Recognize the terminal object 1: a `TyUser p` whose place has no data
 * fields. Lives here for the same layering reason as is_pure_expr. *)
let is_terminal_ty (env : env) (t : ty) : bool =
  match t with
  | TyUser name -> name_is_terminal env name
  | _ -> false

let lookup_op (env : env) (qualified : string) : op_sig option =
  List.assoc_opt qualified env.ops

let is_interval_var (env : env) (i : string) : bool =
  List.mem i env.intervals

let lookup_op_unqualified (env : env) (op_name : string) : op_sig list =
  List.filter_map
    (fun (_key, sig_) ->
       if sig_.os_op_name = op_name then Some sig_ else None)
    env.ops

let add_var (env : env) (x : string) (t : ty) : env =
  { env with vars = (x, t) :: env.vars }

let add_vars (env : env) (bindings : (string * ty) list) : env =
  { env with vars = bindings @ env.vars }

let add_sum_type (env : env) (variants : variant list) : env =
  if List.exists (( = ) variants) env.sum_types then env
  else { env with sum_types = variants :: env.sum_types }

let lookup_sum_constructor (env : env) (name : string)
    : (variant list * variant) list =
  List.filter_map
    (fun variants ->
       match List.find_opt (fun v -> v.v_name = name) variants with
       | Some variant -> Some (variants, variant)
       | None -> None)
    env.sum_types

(* A named sum registers its constructors (so hit/match resolve them) and its
   name (so `TyUser name` resolves to its variants, including recursively). *)
let add_named_sum (env : env) (name : string) (variants : variant list) : env =
  let env = add_sum_type env variants in
  { env with named_sums = (name, variants) :: env.named_sums }

let lookup_named_sum (env : env) (name : string) : variant list option =
  List.assoc_opt name env.named_sums

(* The name of the named sum a constructor belongs to, if any. Constructor names
   are unique across sums, so this is unambiguous. *)
let named_sum_of_ctor (env : env) (ctor : string) : (string * variant list) option =
  List.find_opt
    (fun (_, variants) -> List.exists (fun v -> v.v_name = ctor) variants)
    env.named_sums

let add_interval (env : env) (i : interval_var) : env =
  { env with intervals = i :: env.intervals }

let add_synthetic_marker (env : env) (name : string) : env =
  { env with synthetic_places = name :: env.synthetic_places }

let is_synthetic_place (env : env) (name : string) : bool =
  List.mem name env.synthetic_places

let add_place (env : env) (pd : place_decl) : env =
  let env = { env with places = (pd.pd_name, pd) :: env.places } in
  (* If an operation of the place instantiates a catalog algebra (op_algebra),
   * register the function <P>_instantiate : () -> Magma. This is the function
   * the AlgebraVerifier pass generates; the type checker must know it because
   * `verify P` calls it. *)
  let has_algebra =
    List.exists (function FoOp o -> o.op_algebra <> None | _ -> false) pd.pd_members
  in
  let env =
    if has_algebra then
      { env with funs =
          (pd.pd_name ^ "_instantiate",
           { fs_params = []; fs_return = TyUser "Magma"; fs_visits = []; fs_partial = false })
          :: env.funs }
    else env
  in
  List.fold_left
    (fun env fo ->
       match fo with
       | FoOp op ->
           let key = pd.pd_name ^ "__" ^ op.op_name in
           let sig_ = {
             os_place = pd.pd_name;
             os_op_name = op.op_name;
             os_params = List.map (fun p -> (p.param_name, p.param_ty))
                                  op.op_params;
             os_return = (match op.op_return with
                          | Some t -> t
                          | None -> TyPrim "unit");
           } in
           { env with ops = (key, sig_) :: env.ops }
       | FoField _ -> env
       | FoCell _ -> env
       | FoLaw _ -> env)
    env pd.pd_members

let add_world (env : env) (wd : world_decl) : env =
  { env with worlds = (wd.wd_name, wd) :: env.worlds }

let add_reduction (env : env) (rd : reduction_decl) : env =
  { env with reductions = (rd.rd_name, rd) :: env.reductions }

(* *)
let add_view (env : env) (vd : view_decl) : env =
  { env with view_decls = (vd.vw_name, vd) :: env.view_decls }

let lookup_view (env : env) (name : string) : view_decl option =
  List.assoc_opt name env.view_decls

let lookup_morph_decl (env : env) (name : string) : morph_decl option =
  List.assoc_opt name env.morph_decls

(* *)
let add_topos (env : env) (td : topos_decl) : env =
  { env with topos_decls = (td.tp_name, td) :: env.topos_decls }

let lookup_topos (env : env) (name : string) : topos_decl option =
  List.assoc_opt name env.topos_decls

(* Find the first place inside a topos. Used to derive the target place of
 * m(x) when m : morph from S1 to S2 (target topos S2). *)
let first_place_in_topos (env : env) (topos_name : string) : place_decl option =
  match lookup_topos env topos_name with
  | Some td ->
      (match td.tp_objects with
       | pd :: _ -> Some pd
       | [] -> None)
  | None -> None

(* Multi-place lookup.
 * For a morph from S1 to S2 with src: SourcePlace, find the target place
 * inside S2 whose on_object accepts SourcePlace as a param.
 *
 * Find a match via the registered morph_decls: for each morph of the topos
 * (source = S1, target = S2), the mp_on_object indicates how a specific source
 * place maps to a specific target place.
 *
 * Fallback: if no specific morph matches, the first place of the target. *)
let find_target_place_for_source
    (env : env) (source_topos : string) (target_topos : string)
    (source_place : string) : place_decl option =
  let matching_morphs = List.filter_map (fun (_, mp) ->
    if mp.mp_source = source_topos && mp.mp_target = target_topos then
      (* Find on_object with a first parameter of type SourcePlace *)
      match mp.mp_on_object with
      | Some fd ->
          (match fd.fn_params with
           | { param_ty = TyUser pname; _ } :: _ when pname = source_place ->
               (match fd.fn_return with
                | Some (TyUser ret_pname) -> Some ret_pname
                | _ -> None)
           | _ -> None)
      | None -> None
    else None
  ) env.morph_decls in
  match matching_morphs with
  | ret_pname :: _ -> lookup_place env ret_pname
  | [] -> first_place_in_topos env target_topos  (* fallback *)

let add_fun (env : env) (name : string) (sig_ : fun_sig) : env =
  { env with funs = (name, sig_) :: env.funs }

(* Register a delta-rule: the desugared CORE body of a user function.
 * Additive and pure — does not desugar here; the caller supplies an
 * already-produced Ast.term. Consumed by the kernel reducer's delta-step
 * once SCT (sct.ml) has certified the function terminates. *)
let add_delta (env : env) (name : string) (body : Ast.term) : env =
  { env with delta = (name, body) :: env.delta }

(* Look up a delta-rule body by function name. None = no rewrite rule
 * (e.g. a builtin, or a function not captured): the reducer leaves the
 * call opaque, sound. *)
let lookup_delta (env : env) (name : string) : Ast.term option =
  List.assoc_opt name env.delta

(* Compute the "surface tag" of a type. Two incompatible representations
 * (TyPrim "number" vs TyUser "number") collapse to the same tag. Used
 * by the dispatcher to find structural matches. *)
let rec type_tag (t : ty) : string =
  match t with
  | TyWire sp -> "wire to " ^ sp
  | TySubscription (sp, _) -> "subscription to " ^ sp
  | TyPrim n | TyPrimIn (n, _) -> n
  | TyUser n -> n
  | TyApp (n, _) -> n   (* type application collapses to its head for tag purposes *)
  | TyVar n -> n
  | TyMetaVar n -> Printf.sprintf "alpha%d" n
  | TyUniverse n -> Printf.sprintf "Type_%d" n
  | TyList inner -> "list_" ^ type_tag inner
  | TyMap (k, v) -> "map_" ^ type_tag k ^ "_" ^ type_tag v
  | TyStream inner -> "stream_" ^ type_tag inner
  | TyPi (_, _, _) -> "Pi"
  | TySigma (_, _, _) -> "Sigma"
  | TyId (a, _, _) -> "Id_" ^ type_tag a
  | TyPathP ((_, a), _, _) -> "PathP_" ^ type_tag a
  | TyEl (TyTermExpr e) -> "El_" ^ ty_term_to_name e
  | TySum variants | TySumIn (variants, _) ->
      let frame s = string_of_int (String.length s) ^ ":" ^ s in
      let variant_tag v =
        frame v.v_name
        ^ string_of_int (List.length v.v_args) ^ "["
        ^ String.concat "" (List.map (fun arg -> frame (type_tag arg)) v.v_args)
        ^ "]"
      in
      let signature =
        string_of_int (List.length variants) ^ "__"
        ^ String.concat "" (List.map variant_tag variants)
      in
      "sum_" ^ Digest.to_hex (Digest.string signature)
  | TyHeytInt n -> "heyt_int_" ^ string_of_int n
  | TyArrow (a, b) -> "arrow_" ^ type_tag a ^ "_" ^ type_tag b
  | TyMoveHandle (w1, w2) ->
      let s = function Some n -> n | None -> "ANY" in
      "movehandle_" ^ s w1 ^ "_" ^ s w2
  | TyReductionHandle p ->
      let s = function Some n -> n | None -> "ANY" in
      "reductionhandle_" ^ s p
  | TyMorphHandle (s1, s2) ->
      let s = function Some n -> n | None -> "ANY" in
      "morphhandle_" ^ s s1 ^ "_" ^ s s2
  | TyViewHandle p ->
      let s = function Some n -> n | None -> "ANY" in
      "viewhandle_" ^ s p

let set_effects (env : env) (effects : string list) : env =
  { env with current_effects = effects }

let activate_handler (env : env) (reduction_name : string) : env =
  { env with active_handlers = reduction_name :: env.active_handlers }

let with_builtins (env : env) : env =
  let output_op_decl = {
    op_name = "print";
    op_params = [{ param_name = "s"; param_ty = TyUser "String" }];
    op_return = Some (TyPrim "unit");
    op_functorial = false;
    op_algebra = None;
    op_loc = dummy_loc;
  } in
  let output_place = {
    pd_name = "Output";
    pd_type_params = [];
    pd_arms = [];
    pd_world = "__Builtin";
    pd_members = [FoOp output_op_decl];
    pd_over = None;
    pd_laws = [];
    pd_subcontains = None;
    pd_is_error = false;
    pd_on_error = None;
    pd_loc = dummy_loc;
  } in
  let console_reduction = {
    rd_name = "__Console";
    rd_of = "Output";
    rd_multi_shot = false;
    rd_clauses = [];
    rd_direction = RdForward;
    rd_lawful = false;
    rd_shot_ordering = OrdSequential;
    rd_type_params = [];
    rd_invertible = false;
    rd_fold_name = None;
    rd_loc = dummy_loc;
  } in
  (* Coercion builtins boolean ↔ proposition.
   * to_prop : boolean -> proposition  (total, canonical injection)
   * to_bool : proposition -> boolean  (partial: present->true, absent->false,
   *                                    unknown lifts to indeterminate at runtime) *)
  let to_prop_sig = {
    fs_params = [("b", TyPrim "boolean")];
    fs_return = TyPrim "proposition";
    fs_visits = [];
    fs_partial = false;
  } in
  let to_bool_sig = {
    fs_params = [("p", TyPrim "proposition")];
    fs_return = TyPrim "boolean";
    fs_visits = [];
    fs_partial = false;
  } in
  (* Decidable. Makes explicit in the type system WHERE the classical boolean
   * fragment of an intuitionistic logic is used.
   * decide : proposition -> Decidable   (total on the type; at runtime it fails
   *          on HUnknown -> the point where the programmer asserts
   *          decidability, made visible instead of implicit in to_bool).
   * to_bool_dec : Decidable -> boolean  (total: a Decidable is already decided). *)
  let decide_sig = {
    fs_params = [("p", TyPrim "proposition")];
    fs_return = TyPrim "Decidable";
    fs_visits = [];
    fs_partial = false;
  } in
  let to_bool_dec_sig = {
    fs_params = [("d", TyPrim "Decidable")];
    fs_return = TyPrim "boolean";
    fs_visits = [];
    fs_partial = false;
  } in
  env
  |> (fun e -> add_place e output_place)
  |> (fun e -> add_reduction e console_reduction)
  |> (fun e -> add_fun e "to_prop" to_prop_sig)
  |> (fun e -> add_fun e "to_bool" to_bool_sig)
  |> (fun e -> add_fun e "decide" decide_sig)
  |> (fun e -> add_fun e "to_bool_dec" to_bool_dec_sig)

let rec ty_to_string (t : ty) : string =
  match t with
  | TyWire sp -> "wire to " ^ sp
  | TySubscription (sp, _) -> "subscription to " ^ sp
  | TyPrim n -> n
  | TyPrimIn (n, ws) -> n ^ " in " ^ String.concat ", " ws
  | TyUser n -> n
  | TyApp (n, args) -> n ^ "<" ^ String.concat ", " (List.map ty_to_string args) ^ ">"
  | TyVar n -> n
  | TyMetaVar n -> Printf.sprintf "alpha%d" n
  | TyUniverse 0 -> "Type"
  | TyUniverse n -> Printf.sprintf "Type_%d" n
  | TyPi (x, a, b) ->
      Printf.sprintf "Pi(%s : %s). %s" x (ty_to_string a) (ty_to_string b)
  | TySigma (x, a, b) ->
      Printf.sprintf "Sigma(%s : %s). %s" x (ty_to_string a) (ty_to_string b)
  | TyId (a, x, y) ->
      let ts = function TyTermExpr e -> ty_term_to_name e in
      Printf.sprintf "Id_%s(%s, %s)" (ty_to_string a) (ts x) (ts y)
  | TyPathP ((i, a), x, y) ->
      let ts = function TyTermExpr e -> ty_term_to_name e in
      Printf.sprintf "PathP(<%s> %s, %s, %s)" i (ty_to_string a) (ts x) (ts y)
  | TyEl (TyTermExpr e) -> Printf.sprintf "El(%s)" (ty_term_to_name e)
  | TyList inner -> "list of " ^ ty_to_string inner
  | TyMap (k, v) -> "map of " ^ ty_to_string k ^ " to " ^ ty_to_string v
  | TyStream inner -> "stream of " ^ ty_to_string inner
  | TySum variants ->
      String.concat " | " (List.map variant_to_string variants)
  | TySumIn (variants, ws) ->
      String.concat " | " (List.map variant_to_string variants)
      ^ " in " ^ String.concat ", " ws
  | TyHeytInt n -> Printf.sprintf "heyt_int<%d>" n
  | TyArrow (a, b) -> Printf.sprintf "%s -> %s" (ty_to_string a) (ty_to_string b)
  | TyMoveHandle (w1, w2) ->
      let s = function Some n -> n | None -> "?" in
      Printf.sprintf "move from %s to %s" (s w1) (s w2)
  | TyReductionHandle p ->
      let s = function Some n -> n | None -> "?" in
      Printf.sprintf "reduction of %s" (s p)
  | TyMorphHandle (s1, s2) ->
      let s = function Some n -> n | None -> "?" in
      Printf.sprintf "morph from %s to %s" (s s1) (s s2)
  | TyViewHandle p ->
      let s = function Some n -> n | None -> "?" in
      Printf.sprintf "view of %s" (s p)

and variant_to_string (v : variant) : string =
  match v.v_args with
  | [] -> v.v_name
  | args -> v.v_name ^ "(" ^ String.concat ", " (List.map ty_to_string args) ^ ")"

let loc_to_string (l : location) : string =
  Printf.sprintf "line %d, col %d" l.start_line l.start_col
