(* desugar.ml — translation from surface Yon (Surface_ast) to Yon Core (Ast).
 *
 * Follows the translation table of yon-core-calculus-v0-1.md §7.
 *
 * This is the first version: handles the constructs needed to run small
 * programs (place declarations, fun bodies, with blocks, basic control
 * flow, base expressions). More advanced constructs (move, view, HIT,
 * cubical types, streams with backpressure) translate to placeholder
 * Core terms; they evaluate but their semantics is incomplete until the
 * interpreter is extended.
 *)

module S = Surface_ast
module C = Ast

(* Accumulator for the synthetic functions generated when an inline handle
   lambda is lifted to top level. Filled by desugar_expr when it meets an
   EMoveLam/EReductionLam/EMorphLam, drained by desugar_program into TopFun
   declarations plus the matching TopMove/TopReduction/TopMorph. *)
let synth_counter : int ref = ref 0
let fresh_synth_name (prefix : string) : string =
  incr synth_counter;
  Printf.sprintf "__%s_inline_%d" prefix !synth_counter

(* The synthetic declarations to emit at the end of the program, one list per
   handle kind: move, reduction, and morph each have a different surface decl. *)
let synth_moves : S.move_decl list ref = ref []
let synth_reductions : S.reduction_decl list ref = ref []
let synth_morphs : S.morph_decl list ref = ref []
let synth_funs : S.fun_decl list ref = ref []

(* The bodies of the compose synthetic functions. The synth funs created from
 * S.EComposeWith have a placeholder surface fn_body (return 0); the real
 * C.term body (h2(h1(x))) is filled in here and substituted by
 * process_top_decl. *)
let compose_synth_bodies : (string * C.term) list ref = ref []

(* A registry of user function signatures (parameter types + return type).
 * Filled in process_top_decl for S.TopFun. Consulted by analyze_handle in
 * EComposeWith to derive the types of
 * compose <fun_named_with_section_types> with <...>. *)
let user_fun_sigs : (string * (S.ty list * S.ty)) list ref = ref []

(* The typed environment (Tycheck cr_env), set by desugar_program from its
   optional ~env. Consulted by the terminal absorber (B.3) in the TopFun case
   to recognize a terminal return type and to check body purity. None outside
   the three type-checked driver paths, in which case the absorber stays inert
   (degrades to current behavior). *)
let current_env : Tyenv.env option ref = ref None

(* Local bindings name -> handle-lambda. Filled by the statement desugar when a
 * name is bound to an EFunctorLam/EMoveLam/EMorphLam/etc. Consulted by
 * analyze_handle in compose: `compose f with g` with f, g local resolves the
 * names to the lambdas and reuses the inline lowering. This is not a hack: it
 * is the binding resolution, exactly as for ordinary functions. *)
let handle_bindings : (string * S.expr) list ref = ref []

(* Mapping from topos name to its first place. Filled in process_top_decl for
 * S.TopTopos. Consulted by EMorphLam to choose the correct return type: for
 * `morph from T1 to T2`, the first place of T2 is the actual target. *)
let topos_to_first_place : (string * string) list ref = ref []

(* A global tracker of the current locals, used when lifting an S.ELam in
 * argument position (a bare lambda) to compute the capture. Updated by
 * desugar_stmts_with_locals at each level. *)
let current_locals_ref : string list ref = ref []

(* Closure capture: find the free variables in a surface expression, excluding
 * shadowing binders. Used when lifting an S.ELam in argument position. *)
let rec free_vars_in_expr (bound : string list) (e : S.expr) : string list =
  match e with
  | S.EVar (n, _) when not (List.mem n bound) -> [n]
  | S.EVar _ | S.ELit _ -> []
  | S.ECall (n, args, _) ->
      let base = if List.mem n bound then [] else [n] in
      base @ List.concat_map (free_vars_in_expr bound) args
  | S.EField (sub, _, _) -> free_vars_in_expr bound sub
  | S.ENew (_, fas, _) | S.ENewIn (_, _, fas, _) ->
      List.concat_map (fun fa -> free_vars_in_expr bound fa.S.fa_value) fas
  | S.EBinop (_, a, b, _) ->
      free_vars_in_expr bound a @ free_vars_in_expr bound b
  | S.EParen (sub, _) -> free_vars_in_expr bound sub
  | S.EIfThenElse (c, t, el, _) ->
      free_vars_in_expr bound c
      @ free_vars_in_expr bound t
      @ free_vars_in_expr bound el
  | S.ELam (params, body, _) ->
      let bound' = bound @ List.map fst params in
      free_vars_in_expr bound' body
  | S.EMoveLam (params, body, _, _, _)
  | S.EMorphLam (params, body, _, _, _) ->
      let bound' = bound @ List.map fst params in
      free_vars_in_expr bound' body
  | S.EFunctorLam (params, body, _, _, _, _) ->
      let bound' = bound @ List.map fst params in
      free_vars_in_expr bound' body
  | S.EReductionLam (params, body, _, _) ->
      let bound' = bound @ List.map fst params in
      free_vars_in_expr bound' body
  | S.EViewLam (params, body, _, _) ->
      let bound' = bound @ List.map fst params in
      free_vars_in_expr bound' body
  | S.EComposeWith (h1, h2, _) ->
      free_vars_in_expr bound h1 @ free_vars_in_expr bound h2
  | _ -> []

let uniq_strs (xs : string list) : string list =
  let seen = Hashtbl.create 8 in
  List.filter (fun x ->
    if Hashtbl.mem seen x then false
    else begin Hashtbl.add seen x (); true end
  ) xs

let reset_synth () =
  synth_counter := 0;
  synth_moves := [];
  synth_reductions := [];
  synth_morphs := [];
  synth_funs := [];
  compose_synth_bodies := [];
  user_fun_sigs := [];
  handle_bindings := [];
  topos_to_first_place := []

(* ─── Type translation ─────────────────────────────────────────────── *)

let rec desugar_ty (t : S.ty) : C.ty =
  match t with
  (* String fusion (2026-06-04): normalize the nominal face "String" to the
     primitive "text" ONCE, here, so every downstream layer (specialization,
     emit_ty, layouts, __new constructors) sees the already-fused type.
     Fixing this at the emit layer instead caused signature/call splits
     (the monomorphizer keyed on the divergent type strings). *)
  | S.TyUser "String" -> C.TyBase "text"
  | S.TyPrim n | S.TyPrimIn (n, _) ->
      (match n with
       | "text" | "number" | "boolean" | "money" -> C.TyBase n
       | other -> C.TyBase other)
  | S.TySum _ | S.TySumIn _ ->
      (* Sum types compile to base types in the prototype; a full
         translation would unfold into tagged unions. *)
      C.TyBase "sum"
  | S.TyList inner -> C.TyBase ("list_of_" ^ ty_name inner)
  | S.TyMap (_, _) -> C.TyBase "map"
  | S.TyStream (inner, _mods) -> C.TyStream (desugar_ty inner)
  | S.TyUser n -> C.TyPlace n
  | S.TyVar n -> C.TyPlace n   (* type vars compile to opaque place at IR level *)
  | S.TyMetaVar n -> C.TyPlace (Printf.sprintf "alpha%d" n)  (* HM meta-var, same lowering *)
  | S.TyUniverse n -> C.TyType n
  | S.TyPi (x, a, b) -> C.TyPi (x, desugar_ty a, desugar_ty b)
  | S.TySigma (x, a, b) -> C.TySigma (x, desugar_ty a, desugar_ty b)
  | S.TyId (a, _, _) ->
      (* Id types carry term endpoints; at the IR level we drop them
       * for representation purposes (the kernel keeps them as TyId
       * with actual terms, populated only by HoTT primitives). *)
      C.TyId (desugar_ty a, C.Unit, C.Unit)
  | S.TyHeytInt _n ->
      (* TyHeytInt<N> is opaque to the core AST for now; the real MLIR
         lowering to tuple<i64, i64> comes later. *)
      C.TyBase "heyt_int"
  | S.TyArrow (a, b) ->
      (* preservo
       * struttura nested TyArrow per supportare signature multi-arg
       * MLIR. core_ty_to_mlir_simple uncurries the TyArrow into a flat sig.
       *
       * Example: number -> number -> number -> TyArrow(f64, TyArrow(f64,
       * f64)) -> MLIR (f64, f64) -> f64. *)
      C.TyArrow (desugar_ty a, desugar_ty b)
  | S.TyMoveHandle (_w1, _w2) ->
      (* TyMoveHandle is lowered to an opaque string in the Core (the move name
       * is resolved at the call site via inlining). *)
      C.TyBase "move_handle"
  | S.TyReductionHandle _po ->
      (* TyReductionHandle is lowered to an opaque string in the Core (the
       * reduction name is resolved at the call site via inlining). *)
      C.TyBase "reduction_handle"
  | S.TyMorphHandle (_s1, _s2) ->
      (* TyMorphHandle is lowered to an opaque string in the Core. *)
      C.TyBase "morph_handle"
  | S.TyViewHandle _p ->
      (* TyViewHandle is lowered to an opaque string in the Core. *)
      C.TyBase "view_handle"

and ty_name (t : S.ty) : string =
  match t with
  | S.TyPrim n | S.TyPrimIn (n, _) -> n
  | S.TyUser n -> n
  | S.TyVar n -> n
  | S.TyMetaVar n -> Printf.sprintf "alpha%d" n
  | S.TyUniverse 0 -> "Type"
  | S.TyUniverse n -> Printf.sprintf "Type_%d" n
  | S.TyPi (x, _, _) -> "Pi_" ^ x
  | S.TySigma (x, _, _) -> "Sigma_" ^ x
  | S.TyId _ -> "Id"
  | S.TyList _ -> "list"
  | S.TyMap _ -> "map"
  | S.TyStream _ -> "stream"
  | S.TySum _ | S.TySumIn _ -> "sum"
  | S.TyHeytInt n -> Printf.sprintf "heyt_int_%d" n
  | S.TyArrow _ -> "arrow"
  | S.TyMoveHandle _ -> "move_handle"
  | S.TyReductionHandle _ -> "reduction_handle"
  | S.TyMorphHandle _ -> "morph_handle"
  | S.TyViewHandle _ -> "view_handle"

(* ─── Helper: build a chain of lambda applications ─────────────────── *)

(* curry_apply f [a;b;c] = App(App(App(f, a), b), c) *)
let rec curry_apply f args =
  match args with
  | [] -> f
  | a :: rest -> curry_apply (C.App (f, a)) rest

(* curry_lam [(x,T);(y,U)] body = Lam("x", T, Lam("y", U, body)) *)
let rec curry_lam params body =
  match params with
  | [] -> body
  | (n, t) :: rest -> C.Lam (n, t, curry_lam rest body)

(* ─── Expression translation ───────────────────────────────────────── *)

let rec desugar_expr (e : S.expr) : C.term =
  match e with
  | S.ELit (lit, _) -> desugar_literal lit
  | S.EVar (x, _) -> C.Var x
  | S.EField (obj, fld, _) ->
      (* "obj.field" translates to a projection function applied to obj.
         In Core we model this as application of a named projection. *)
      let obj' = desugar_expr obj in
      C.App (C.Var ("__field_" ^ fld), obj')
  | S.ECall ("directed_cell", args, _) ->
      (* Debt 2: surface inspection of the directed cell generated for a
         geom_morphism. Resolves at compile time to whether a cell is registered
         for the named morphism (the cell is a compile-time artifact; alpha keeps
         it a runtime no-op, so the observable value is a plain boolean). *)
      let name_of = function
        | S.EVar (n, _) -> Some n
        | S.ELit (S.LitString n, _) -> Some n
        | _ -> None
      in
      let exists =
        match args with
        | a :: _ ->
            (match name_of a with
             | Some n -> (match Catt_r_yon.lookup_geom_cell n with
                          | Some _ -> true | None -> false)
             | None -> false)
        | [] -> false
      in
      Builtins.encode_bool exists
  | S.ECall ("coerce_incl", args, _) ->
      (* B.2: directed transport along the inclusion cell. Under (alpha) the
         subobject is represented by its carrier, so transporting a value along
         m_f : c_P -> c_Q is the identity on the carrier at runtime — the proof
         (the witness) carries no computational content and evaporates. We lower
         to the value alone. The cell/witness semantics live in the CaTT reducer
         (parts 80-82); this surface form is the no-op transport (decree rule 4). *)
      (match args with
       | v :: _proof :: _ -> desugar_expr v
       | [v] -> desugar_expr v
       | [] -> C.Unit)
  | S.ECall ("apply_move", [S.EVar (vname, _); arg], _)
    when Move_engine.lookup_move vname = None
         && (match List.assoc_opt vname !handle_bindings with
             | Some (S.EMoveLam _) -> true | _ -> false) ->
      (* v1.0 (2026-06-04): apply_move on a LOCAL move-lambda binding.
       * The binding already holds the lifted function (__move_inline_N), so
       * the application is the direct call m(arg) — the same binding
       * resolution analyze_handle uses for compose. Declared moves keep the
       * registered apply_move dispatch below. *)
      C.App (C.Var vname, desugar_expr arg)
  | S.ECall (name, args, loc) ->
      (* Rename Seq -> __stream_. The "Seq" prefix is removed from the internal
       * naming. The surface still accepts Seq.X as a deprecated alias
       * (auto-mapped). *)
      let (name', args') =
        let try_chain_rewrite () =
          try
            let idx = Str.search_forward (Str.regexp "__") name 0 in
            let prefix = String.sub name 0 idx in
            let suffix = String.sub name (idx + 2) (String.length name - idx - 2) in
            let is_method = (suffix = "map" || suffix = "filter"
                          || suffix = "fold" || suffix = "take"
                          || suffix = "sum_take" || suffix = "to_stream") in
            let is_lower = String.length prefix > 0
              && let c = prefix.[0] in c >= 'a' && c <= 'z'
            in
            if is_method && is_lower then
              Some ("__stream_" ^ suffix, S.EVar (prefix, loc) :: args)
            else
              None
          with Not_found -> None
        in
        match name with
        | "map" -> ("__stream_map", args)
        | "filter" -> ("__stream_filter", args)
        | "fold" -> ("__stream_fold", args)
        (* The Stream.X prefix is removed. iterate/take/sum_take become bare
         * builtins; to_stream is a semantic no-op (the list is already a
         * stream). *)
        | "iterate" -> ("__stream_iterate", args)
        | "take" -> ("__stream_take", args)
        | "sum_take" -> ("__stream_sum_take", args)
        | "to_stream" -> ("__stream_to_stream", args)
        (* Backward-compat: Seq.X e Stream.X surface syntax. *)
        | "Seq__map" -> ("__stream_map", args)
        | "Seq__filter" -> ("__stream_filter", args)
        | "Seq__fold" -> ("__stream_fold", args)
        | "Seq__from_list" -> ("__stream_from_list", args)
        (* Seq.range(n) desugara a stream da list. *)
        | "Seq__range" ->
            let list_call = S.ECall ("Seq__range_to_list", args, S.dummy_loc) in
            ("__stream_from_list", [list_call])
        | "Stream__iterate" -> ("__stream_iterate", args)
        | "Stream__take" -> ("__stream_take", args)
        | "Stream__sum_take" -> ("__stream_sum_take", args)
        | _ ->
            (match try_chain_rewrite () with
             | Some (n, a) -> (n, a)
             | None -> (name, args))
      in
      let args_terms = List.map desugar_expr args' in
      curry_apply (C.Var name') args_terms
  | S.ENew (place_name, fas, _) ->
      (* new P { f1 e1, f2 e2 } translates to a constructor call with
         field values as arguments in declared order. *)
      let arg_terms = List.map (fun fa -> desugar_expr fa.S.fa_value) fas in
      curry_apply (C.Var ("__new_" ^ place_name)) arg_terms
  | S.ENewIn (place_name, space_name, fas, _) ->
      (* new P in Space { ... } desugars to __new_in_<Space>_<Place>(args).
       * The emitter recognizes the "__new_in_" prefix and emits the
       * yon_rt_new call with the heap id resolved from the space registry. *)
      let arg_terms = List.map (fun fa -> desugar_expr fa.S.fa_value) fas in
      curry_apply (C.Var ("__new_in_" ^ space_name ^ "_" ^ place_name)) arg_terms
  | S.EBinop (op, e1, e2, _) ->
      let op_name = binop_name op in
      curry_apply (C.Var op_name) [desugar_expr e1; desugar_expr e2]
  | S.EParen (e, _) -> desugar_expr e
  | S.EAll (place_name, _cond, _) ->
      (* "all P where c" — placeholder for the prototype *)
      C.App (C.Var "__all", C.Var place_name)
  | S.EIn (e, ctx, _) ->
      C.App (C.App (C.Var "__in", desugar_expr e), C.Var ctx)
  | S.ERefl (e, _) ->
      C.Refl (desugar_expr e)
  | S.EPair (a, b, _) ->
      C.Pair (desugar_expr a, desugar_expr b)
  | S.EFst (p, _) ->
      C.Fst (desugar_expr p)
  | S.ESnd (p, _) ->
      C.Snd (desugar_expr p)
  | S.EJ (c, d, p, _) ->
      (* Surface ind_path(C, d, p) desugars to kernel J.
       * The motive binder name is synthesized; the carrier type is
       * elaborated later by the type checker. For runtime, J fires
       * the beta-rule J(C, d, refl(a), a) = d(a). The basepoint is
       * extracted from the path (the kernel keeps it as a separate
       * arg; for surface we project it from the path itself, using
       * Unit as a placeholder that gets refined at type-check time. *)
      C.J ("_motive_x", C.TyType 0,
           desugar_expr c, desugar_expr d,
           desugar_expr p, C.Unit)
  | S.EPullback (_f, _g, _loc) ->
      Builtins.encode_number 0.0
  | S.EPullbackVal (_f, _g, _a, _b, _loc) ->
      (* The runtime universal pullback.
       * The real lowering happens by expanding to an ECall of a synthetic
       * function `__pullback_<f>_<g>` (see desugar_program). Here we default
       * to Unit because the expansion must be done at program level (to
       * generate the synth function separately). *)
      Builtins.encode_number 0.0
  | S.EPushout (_f, _g, _loc) ->
      Builtins.encode_number 0.0
  | S.ENot (e, _loc) ->
      (* Unary not. Lowered to ECall("__bool_not", [e]), a primitive that
       * emit_mlir recognizes as an arith.xori with the constant true. *)
      let e' = desugar_expr e in
      C.App (C.Var "__bool_not", e')
  | S.EIfThenElse (c, a, b, _loc) ->
      (* if/then/else expression.
       * Lowering: __if_expr(cond, then, else) -> scf.if with yield. *)
      curry_apply (C.Var "__if_expr")
        [desugar_expr c; desugar_expr a; desugar_expr b]
  | S.ELam (params, body, _loc) ->
      (* An inline lambda in an arbitrary position (i.e. NOT in a let body).
       * Canonical example:
       *   Stream.iterate(fun(x: number) => x + 1, 0)
       *
       * Strategy: lift to a synthetic top-level fun.
       *   1. Compute the free vars of the body (excluding the lambda params)
       *   2. Intersect with `current_locals` to get captured
       *   3. Generate __arg_lam_inline_N with captured + params as params
       *   4. Return a Var of the synth fun (a function pointer for dynamic HOF)
       *
       * Accepted trade-off:
       *   - Capture requires `current_locals` kept up to date by the caller
       *     (see current_locals_ref updated by desugar_stmts_with_locals)
       *   - For captured != [], the caller must inject the captured args at the
       *     call site manually. The bare arg-lam form does NOT inject
       *     automatically (that would be runtime closure semantics).
       *
       * Capture is supported only if the higher-order builtin caller knows
       * how to propagate the captured variables (Stream.iterate/take/sum_take
       * with compile-time lambda fusion already do this via pattern
       * matching). *)
      let synth_name = fresh_synth_name "arg_lam" in
      let lam_param_names = List.map fst params in
      let free_in_body = free_vars_in_expr lam_param_names body in
      let locals = !current_locals_ref in
      let captured =
        uniq_strs (List.filter (fun v -> List.mem v locals) free_in_body)
      in
      let cap_params = List.map (fun c ->
        { S.param_name = c; S.param_ty = S.TyPrim "unknown" }
      ) captured in
      let _loc_unused = _loc in
      let synth_fd : S.fun_decl = {
        S.fn_name = synth_name;
        S.fn_type_params = [];
        S.fn_params = cap_params @
          List.map (fun (n, t) -> { S.param_name = n; S.param_ty = t }) params;
        S.fn_return = Some (S.TyPrim "number");
        S.fn_visits = [];
        S.fn_partial = false; fn_internal = false;
        S.fn_body = [S.SReturn (body, _loc)];
        S.fn_loc = _loc;
      } in
      synth_funs := synth_fd :: !synth_funs;
      if captured = [] then
        C.Var synth_name
      else
        (* There are captured variables: apply the captured args at the call
         * site. We return a C.App chain (synth_name captured), producing a
         * partially applied closure. This works for single-argument
         * higher-order functions (sum_take/iterate); multi-argument ones need
         * a check. *)
        List.fold_left (fun acc c -> C.App (acc, C.Var c))
          (C.Var synth_name) captured(* 3 inline handle lambdas.
   * Strategy: lift to a synthetic top-level fun with the naming convention
   * `__move_inline_N`, `__reduction_inline_N`, `__morph_inline_N`. The prefix
   * is recognized by the type checker to derive the right handle type. *)
  | S.EMoveLam (params, body, from_p, to_p, loc) ->
      let name = fresh_synth_name "move" in
      let ret_ty = S.TyUser to_p in
      let _ = from_p in
      let synth_fd : S.fun_decl = {
        S.fn_name = name;
        S.fn_type_params = [];
        S.fn_params = List.map (fun (n, t) -> { S.param_name = n; S.param_ty = t }) params;
        S.fn_return = Some ret_ty;
        S.fn_visits = [];
        S.fn_partial = false; fn_internal = false;
        S.fn_body = [S.SReturn (body, loc)];
        S.fn_loc = loc;
      } in
      synth_funs := synth_fd :: !synth_funs;
      C.Var name
  | S.EReductionLam (params, body, of_p, loc) ->
      let name = fresh_synth_name "reduction" in
      let _ = of_p in
      let synth_fd : S.fun_decl = {
        S.fn_name = name;
        S.fn_type_params = [];
        S.fn_params = List.map (fun (n, t) -> { S.param_name = n; S.param_ty = t }) params;
        S.fn_return = Some (S.TyPrim "number");
        S.fn_visits = [];
        S.fn_partial = false; fn_internal = false;
        S.fn_body = [S.SReturn (body, loc)];
        S.fn_loc = loc;
      } in
      synth_funs := synth_fd :: !synth_funs;
      C.Var name
  | S.EMorphLam (params, body, from_s, to_s, loc) ->
      let name = fresh_synth_name "morph" in
      let _ = from_s in
      (* For `morph from T1 to T2`, the ret type of the lifted fun is the
       * first place of T2 (= the actual target place), NOT the topos name.
       * Look up in the topos_to_first_place registry
       * filled during TopTopos. If not found (an external or undeclared
       * topos), fall back to TyUser to_s. *)
      let ret_ty =
        match List.assoc_opt to_s !topos_to_first_place with
        | Some place_name -> S.TyUser place_name
        | None -> S.TyUser to_s
      in
      let synth_fd : S.fun_decl = {
        S.fn_name = name;
        S.fn_type_params = [];
        S.fn_params = List.map (fun (n, t) -> { S.param_name = n; S.param_ty = t }) params;
        S.fn_return = Some ret_ty;
        S.fn_visits = [];
        S.fn_partial = false; fn_internal = false;
        S.fn_body = [S.SReturn (body, loc)];
        S.fn_loc = loc;
      } in
      synth_funs := synth_fd :: !synth_funs;
      C.Var name
  | S.EFunctorLam (params, body, from_w, to_w, _laws, loc) ->
      (* A functor-lambda is a map W -> V. We desugar it like an EMorphLam, by
         synthesizing a lifted function. The functor laws (identity,
         composition) were already verified by the type checker; what remains
         here is only the computational translation. *)
      let name = fresh_synth_name "functor" in
      let _ = from_w in
      let ret_ty =
        match List.assoc_opt to_w !topos_to_first_place with
        | Some place_name -> S.TyUser place_name
        | None -> S.TyUser to_w
      in
      let synth_fd : S.fun_decl = {
        S.fn_name = name;
        S.fn_type_params = [];
        S.fn_params = List.map (fun (n, t) -> { S.param_name = n; S.param_ty = t }) params;
        S.fn_return = Some ret_ty;
        S.fn_visits = [];
        S.fn_partial = false; fn_internal = false;
        S.fn_body = [S.SReturn (body, loc)];
        S.fn_loc = loc;
      } in
      synth_funs := synth_fd :: !synth_funs;
      C.Var name
  | S.EViewLam (params, body, of_p, loc) ->
      (* EViewLam is lifted like EReductionLam. A view is a projection
         P -> number (or T), so the return type defaults to number. of_p is the
         source place, verified by the type checker. *)
      let name = fresh_synth_name "view" in
      let _ = of_p in
      let synth_fd : S.fun_decl = {
        S.fn_name = name;
        S.fn_type_params = [];
        S.fn_params = List.map (fun (n, t) -> { S.param_name = n; S.param_ty = t }) params;
        S.fn_return = Some (S.TyPrim "number");
        S.fn_visits = [];
        S.fn_partial = false; fn_internal = false;
        S.fn_body = [S.SReturn (body, loc)];
        S.fn_loc = loc;
      } in
      synth_funs := synth_fd :: !synth_funs;
      C.Var name
  | S.EComposeWith (h1, h2, loc) ->
      (* Handle composition. `compose h1 with h2` becomes a synthetic function
         computing h2(h1(x)). The dispatch is handle-aware: if h1 or h2 is the
         name of a move, we emit (apply_move name x) with the move's source and
         target as the parameter and return types; otherwise (a fun/view/
         reduction lambda) it is a direct call with number as the typical
         parameter and return type. The result is a synthetic function
         __compose_inline_N that chains the two. *)
      let name = fresh_synth_name "compose" in
      (* Given a handle, return (source_ty, target_ty, app_builder):
         source_ty is its input type, target_ty its output type, and
         app_builder takes a C.term argument and produces the C.term that
         applies the handle to it. *)
      let rec analyze_handle (h : S.expr) :
            S.ty * S.ty * (C.term -> C.term) =
        match h with
        | S.EParen (inner, _) -> analyze_handle inner
        | S.EVar (vname, _)
          when Move_engine.lookup_move vname <> None ->
            (* a globally registered move name: dispatch through apply_move *)
            let md = match Move_engine.lookup_move vname with
              | Some m -> m | None -> assert false in
            let src_ty = match md.S.mv_from with
              | [p] -> S.TyUser p
              | _ -> S.TyPrim "number" in
            let tgt_ty = match md.S.mv_to with
              | Some p -> S.TyUser p
              | None -> S.TyPrim "number" in
            let builder = fun arg ->
              C.App (C.App (C.Var "apply_move", C.Var vname), arg) in
            (src_ty, tgt_ty, builder)
        | S.EMoveLam (params, _body, from_p, to_p, _) ->
            (* Inline move lambda: input = from_p, output = to_p. The normal
               lifting produces __move_inline_N with signature (P) -> Q; the
               lambda's first parameter is the move's source. *)
            let _ = params in
            let h_term = desugar_expr h in
            (S.TyUser from_p, S.TyUser to_p,
             fun arg -> C.App (h_term, arg))
        | S.EMorphLam (_params, _body, from_s, to_s, _) ->
            (* Inline morph lambda: input and output are sections. The
               pre-lift produces __morph_inline_N with the right signature from
               the EMorphLam desugar, which handles the parameters itself. We
               let the lambda's first parameter declare the source place; for
               the target we fall back to number when we cannot derive the
               place. In practice the call h_term(arg) propagates the type
               correctly for the single call. *)
            let _ = (from_s, to_s) in
            let h_term = desugar_expr h in
            let src_ty =
              match _params with
              | (_, t) :: _ -> t
              | [] -> S.TyPrim "number"
            in
            (* Target type defaults to number; the backend reads the real one
               from the MLIR of __morph_inline_N via fn_ret_mlir. *)
            (src_ty, S.TyPrim "number",
             fun arg -> C.App (h_term, arg))
        | S.EFunctorLam (params, _body, from_w, to_w, _laws, _) ->
            (* Inline functor-lambda inside a composition. Input is the first
               parameter (the domain), output is to_w. The functor-lambda
               already desugars to a lifted function; here we apply it like any
               other handle. *)
            let _ = (from_w, to_w) in
            let h_term = desugar_expr h in
            let src_ty = match params with (_, t) :: _ -> t | [] -> S.TyPrim "number" in
            (src_ty, S.TyUser to_w, fun arg -> C.App (h_term, arg))
        | S.EViewLam (_params, _body, of_p, _) ->
            let h_term = desugar_expr h in
            (S.TyUser of_p, S.TyPrim "number",
             fun arg -> C.App (h_term, arg))
        | S.EReductionLam (_params, _body, of_p, _) ->
            (* Reduction inline: input = of_p, output = number (eliminator). *)
            let h_term = desugar_expr h in
            (S.TyUser of_p, S.TyPrim "number",
             fun arg -> C.App (h_term, arg))
        | S.EVar (vname, _)
          when List.mem_assoc vname !user_fun_sigs ->
            (* A user-defined fun: derive source/target from the signature.
             * For a single-argument fun: param[0] = source, ret = target. *)
            let (ptys, rty) = List.assoc vname !user_fun_sigs in
            let src = match ptys with
              | [t] -> t
              | _ -> S.TyPrim "number" in
            let builder = fun arg -> C.App (C.Var vname, arg) in
            (src, rty, builder)
        | S.EVar (vname, _)
          when Move_engine.lookup_move vname = None
               && List.mem_assoc vname !handle_bindings ->
            (* A local binding to a handle-lambda (`be f holds functor ...`).
             * We resolve the name to the lambda and recurse: `compose f with g`
             * becomes the composition of the lambdas, reusing the inline
             * lowering. A binding resolution, not a hack. *)
            analyze_handle (List.assoc vname !handle_bindings)
        | _ ->
            (* fun lambda inline / EVar di fun named / other:
             * default number->number. *)
            let h_term = desugar_expr h in
            (S.TyPrim "number", S.TyPrim "number",
             fun arg -> C.App (h_term, arg))
      in
      let (h1_src, _h1_tgt, h1_apply) = analyze_handle h1 in
      let (_h2_src, h2_tgt, h2_apply) = analyze_handle h2 in
      let x_param_name = "__compose_x" in
      let inner = h1_apply (C.Var x_param_name) in
      let outer = h2_apply inner in
      let synth_fd : S.fun_decl = {
        S.fn_name = name;
        S.fn_type_params = [];
        S.fn_params = [{ S.param_name = x_param_name;
                         S.param_ty = h1_src }];
        S.fn_return = Some h2_tgt;
        S.fn_visits = [];
        S.fn_partial = false; fn_internal = false;
        S.fn_body = [S.SReturn (S.ELit (S.LitNumber 0.0, loc), loc)];
        S.fn_loc = loc;
      } in
      synth_funs := synth_fd :: !synth_funs;
      compose_synth_bodies :=
        (name, C.Lam (x_param_name, desugar_ty h1_src, outer))
        :: !compose_synth_bodies;
      C.Var name

and desugar_literal (l : S.literal) : C.term =
  match l with
  | S.LitNumber n -> Builtins.encode_number n
  | S.LitString s -> Builtins.encode_string s
  (* LitBool is encoded as a classic bool symbol for compatibility with the i1
   * flow. Semantically the type is proposition (see tycheck.ml and tyenv
   * simple_ty_compatible), but the value at the MLIR level is i1.
   *
   * Note: prop_eval.ml already evaluates LitBool via Heyting.from_bool on the
   * interpreter side, independently of this encoding. *)
  | S.LitBool b -> Builtins.encode_bool b
  | S.LitDuration (n, u) ->
      (* v1.0 (2026-06-04): a duration IS a number of milliseconds. 100ms=100,
         5s=5000, 2min=120000, 1h=3.6e6, 3d=2.592e8, 1y=3.1536e10 (365d). *)
      let factor = match u with
        | "ms" -> 1.0 | "s" -> 1000.0 | "min" -> 60000.0
        | "h" -> 3600000.0 | "d" -> 86400000.0 | "y" -> 31536000000.0
        | other -> failwith ("[desugar] unknown duration unit: " ^ other) in
      Builtins.encode_number (n *. factor)
  | S.LitCurrency (n, c) ->
      C.Var (Printf.sprintf "__cur_%g_%s" n c)
  | S.LitHeytPresent -> Heyting.encode_heyt Heyting.HPresent
  | S.LitHeytAbsent  -> Heyting.encode_heyt Heyting.HAbsent
  | S.LitHeytUnknown -> Heyting.encode_heyt Heyting.HUnknown

and binop_name (op : S.binop) : string =
  match op with
  | S.OpAdd -> "__add" | S.OpSub -> "__sub" | S.OpMul -> "__mul"
  | S.OpDiv -> "__div" | S.OpMod -> "__mod"
  | S.OpLt -> "__lt" | S.OpGt -> "__gt"
  | S.OpLeq -> "__leq" | S.OpGeq -> "__geq"
  | S.OpEq -> "__eq" | S.OpNeq -> "__neq"
  | S.OpAnd -> "__and" | S.OpOr -> "__or"

(* free_vars_in_expr + uniq_strs are defined above desugar_expr. *)


(* Substitute a variable name in a surface expr/stmt. Used when lifting a
 * let-bound lambda to a synthetic top-level fun: it renames the uses of the
 * let-name. *)
let rec subst_var_in_expr (old_n : string) (new_n : string) (e : S.expr) : S.expr =
  let go = subst_var_in_expr old_n new_n in
  match e with
  | S.EVar (n, loc) when n = old_n -> S.EVar (new_n, loc)
  | S.EVar _ | S.ELit _ -> e
  | S.ECall (n, args, loc) ->
      let n' = if n = old_n then new_n else n in
      S.ECall (n', List.map go args, loc)
  | S.EField (sub, f, loc) -> S.EField (go sub, f, loc)
  | S.ENew (n, fas, loc) ->
      S.ENew (n, List.map (fun fa ->
        { fa with S.fa_value = go fa.S.fa_value }) fas, loc)
  | S.ENewIn (n, sp, fas, loc) ->
      S.ENewIn (n, sp, List.map (fun fa ->
        { fa with S.fa_value = go fa.S.fa_value }) fas, loc)
  | S.EBinop (op, a, b, loc) -> S.EBinop (op, go a, go b, loc)
  | S.EParen (sub, loc) -> S.EParen (go sub, loc)
  | S.EIfThenElse (c, t, el, loc) -> S.EIfThenElse (go c, go t, go el, loc)
  | S.ELam (params, body, loc) ->
      (* Shadowing: if old_n is a parameter of the lambda, do not substitute inside. *)
      let shadowed = List.exists (fun (p, _) -> p = old_n) params in
      if shadowed then e
      else S.ELam (params, go body, loc)
  | _ -> e  (* other cases: pass through, do not recurse *)

and subst_var_in_stmt (old_n : string) (new_n : string) (s : S.stmt) : S.stmt =
  let goe = subst_var_in_expr old_n new_n in
  match s with
  | S.SLet (n, e, loc) ->
      if n = old_n then S.SLet (n, goe e, loc)  (* the new binding shadows *)
      else S.SLet (n, goe e, loc)
  | S.SAssignHolds (lv, e, loc) -> S.SAssignHolds (lv, goe e, loc)
  | S.SAssignBecomes (lv, e, loc) -> S.SAssignBecomes (lv, goe e, loc)
  | S.SReturn (e, loc) -> S.SReturn (goe e, loc)
  | S.SCall (n, args, loc) ->
      let n' = if n = old_n then new_n else n in
      S.SCall (n', List.map goe args, loc)
  | _ -> s

(* Rewrite the uses of `old_n` (a let-bound lambda with capture) into calls to
 * the synthetic fun `new_n` with the captured args prepended.
 *
 * - `old_n(args)` -> `new_n(cap1, cap2, ..., args)`
 * - `old_n` (bare, as the argument of a higher-order function): a wrapper
 *   closure (skipped for now, since it would need currying for use as a
 *   function pointer). Only the direct call is handled. *)
let rec inject_captured_args (old_n : string) (new_n : string)
    (captured : string list) (loc_default : S.location) (e : S.expr) : S.expr =
  let go = inject_captured_args old_n new_n captured loc_default in
  match e with
  | S.ECall (n, args, loc) when n = old_n ->
      let cap_exprs = List.map (fun c -> S.EVar (c, loc)) captured in
      S.ECall (new_n, cap_exprs @ List.map go args, loc)
  | S.ECall (n, args, loc) -> S.ECall (n, List.map go args, loc)
  | S.EVar _ | S.ELit _ -> e
  | S.EField (sub, f, loc) -> S.EField (go sub, f, loc)
  | S.ENew (n, fas, loc) ->
      S.ENew (n, List.map (fun fa ->
        { fa with S.fa_value = go fa.S.fa_value }) fas, loc)
  | S.ENewIn (n, sp, fas, loc) ->
      S.ENewIn (n, sp, List.map (fun fa ->
        { fa with S.fa_value = go fa.S.fa_value }) fas, loc)
  | S.EBinop (op, a, b, loc) -> S.EBinop (op, go a, go b, loc)
  | S.EParen (sub, loc) -> S.EParen (go sub, loc)
  | S.EIfThenElse (c, t, el, loc) -> S.EIfThenElse (go c, go t, go el, loc)
  | S.ELam (params, body, loc) ->
      let shadowed = List.exists (fun (p, _) -> p = old_n) params in
      if shadowed then e
      else S.ELam (params, go body, loc)
  | _ -> e

and inject_captured_args_in_stmt (old_n : string) (new_n : string)
    (captured : string list) (s : S.stmt) : S.stmt =
  let loc = match s with
    | S.SLet (_, _, l) | S.SAssignHolds (_, _, l) | S.SAssignBecomes (_, _, l)
    | S.SReturn (_, l) | S.SCall (_, _, l) -> l
    | _ -> { start_line = 0; start_col = 0; end_line = 0; end_col = 0 }
  in
  let goe = inject_captured_args old_n new_n captured loc in
  match s with
  | S.SLet (n, e, l) -> S.SLet (n, goe e, l)
  | S.SAssignHolds (lv, e, l) -> S.SAssignHolds (lv, goe e, l)
  | S.SAssignBecomes (lv, e, l) -> S.SAssignBecomes (lv, goe e, l)
  | S.SReturn (e, l) -> S.SReturn (goe e, l)
  | S.SCall (n, args, l) when n = old_n ->
      let cap_exprs = List.map (fun c -> S.EVar (c, l)) captured in
      S.SCall (new_n, cap_exprs @ List.map goe args, l)
  | S.SCall (n, args, l) -> S.SCall (n, List.map goe args, l)
  | _ -> s

(* ─── Statement sequence translation ───────────────────────────────── *)

(* A statement list is translated to a chain of let bindings and
 * applications, ending in Unit (or the value of a return statement).
 *
 * For simplicity in the prototype, we translate each stmt to a Core
 * term and sequence them via dummy lambda applications:
 *   stmts = s1; s2; s3; return e
 * becomes
 *   (lambda_:_. (lambda_:_. (lambda_:_. e) s3) s2) s1
 *
 * This preserves evaluation order without introducing new Core
 * constructs.
 *)
let rec desugar_stmts (stmts : S.stmt list) : C.term =
  desugar_stmts_with_locals [] stmts

and desugar_stmts_with_locals (locals : string list) (stmts : S.stmt list) : C.term =
  current_locals_ref := locals;  (* aggiorna tracker per arg-lam capture *)
  match stmts with
  | [] -> C.Unit
  | [single] -> desugar_stmt_or_return single
  (* Closure capture: a let-binding of a lambda with possible capture of local
   * variables.
   *
   * Algorithm:
   * 1. Compute the free vars of the lambda body (excluding the lambda params)
   * 2. Intersect with `locals` to get `captured` (vars in scope referenced
   *    inside the lambda)
   * 3. Synthetic fun: __let_lam_inline_N(<captured>..., <params>...)
   * 4. Rewrite each use `id(args)` -> `synth_name(captured @ args)`
   *
   * If `captured = []`, it is the no-capture case. *)
  | S.SLet (name, S.ELam (params, body, lam_loc), let_loc) :: rest ->
      let synth_name = fresh_synth_name "let_lam" in
      let lam_param_names = List.map fst params in
      let free_in_body = free_vars_in_expr lam_param_names body in
      let captured =
        uniq_strs (List.filter (fun v -> List.mem v locals) free_in_body)
      in
      (* Captured params: type TyPrim "unknown" (HM-light), tycheck
       * li raffina osservando i call-site. *)
      let cap_params = List.map (fun c ->
        { S.param_name = c; S.param_ty = S.TyPrim "unknown" }
      ) captured in
      let synth_fd : S.fun_decl = {
        S.fn_name = synth_name;
        S.fn_type_params = [];
        S.fn_params = cap_params @
          List.map (fun (n, t) -> { S.param_name = n; S.param_ty = t }) params;
        S.fn_return = Some (S.TyPrim "number");
        S.fn_visits = [];
        S.fn_partial = false; fn_internal = false;
        S.fn_body = [S.SReturn (body, lam_loc)];
        S.fn_loc = lam_loc;
      } in
      synth_funs := synth_fd :: !synth_funs;
      let _ = let_loc in
      let rest_rewritten =
        if captured = [] then
          List.map (subst_var_in_stmt name synth_name) rest
        else
          List.map (inject_captured_args_in_stmt name synth_name captured) rest
      in
      desugar_stmts_with_locals (name :: locals) rest_rewritten
  | S.SLet (name, e, _) :: rest ->
      (* If the value is a handle-lambda, record the binding name -> lambda so
         that `compose name with ...` can resolve it. *)
      (match e with
       | S.EFunctorLam _ | S.EMoveLam _ | S.EMorphLam _
       | S.EReductionLam _ | S.EViewLam _ ->
           handle_bindings := (name, e) :: !handle_bindings
       | _ -> ());
      let value_term = desugar_expr e in
      let rest_term = desugar_stmts_with_locals (name :: locals) rest in
      C.App (C.Lam (name, C.TyBase "unit", rest_term), value_term)
  | stmt :: rest ->
      let stmt_term = desugar_stmt_or_return stmt in
      let rest_term = desugar_stmts_with_locals locals rest in
      C.App (C.Lam ("_", C.TyBase "unit", rest_term), stmt_term)

and desugar_stmt_or_return (s : S.stmt) : C.term =
  match s with
  | S.SReturn (e, _) -> desugar_expr e
  | other -> desugar_stmt other

and desugar_stmt (s : S.stmt) : C.term =
  match s with
  | S.SLet (_name, e, _) ->
      (* "let x holds e; rest" — but we handle this in the sequence
         translation; here we just produce the value of e. The binding
         is established by the surrounding lambda. *)
      desugar_expr e
  | S.SAssignHolds (_lv, e, _) -> desugar_expr e
  | S.SAssignBecomes (lv, e, _) ->
      (* "x.f becomes new_value" -> Space.update_here(id_of(x), x with f := new_value) *)
      let new_val = desugar_expr e in
      let target = match lv with
        | S.LVar x -> C.Var x
        | S.LField (x, _f) -> C.Var x in
      curry_apply (C.Var "__space_update_here") [target; new_val]
  | S.SReturn (e, _) -> desugar_expr e
  | S.SCall (name, args, _) ->
      let args' = List.map desugar_expr args in
      curry_apply (C.Var name) args'
  | S.SNew (name, fas, _) ->
      let args = List.map (fun fa -> desugar_expr fa.S.fa_value) fas in
      curry_apply (C.Var ("__new_" ^ name)) args
  | S.SNewIn (name, space_name, fas, _) ->
      let args = List.map (fun fa -> desugar_expr fa.S.fa_value) fas in
      curry_apply (C.Var ("__new_in_" ^ space_name ^ "_" ^ name)) args
  | S.SWhen (c, body, elifs, otherwise, _) ->
      desugar_when c body elifs otherwise
  | S.SForEvery (kind, x, e, body, _) ->
      desugar_for_every kind x e body
  | S.SInSequence (x, e, body, _) ->
      (* in_sequence over x in xs { body } — foldl style *)
      let body_lam = C.Lam (x, C.TyBase "unit", desugar_stmts body) in
      curry_apply (C.Var "__foldl") [body_lam; desugar_expr e]
  | S.SRepeat (n, body, _otherwise, _) ->
      let body_term = desugar_stmts body in
      curry_apply (C.Var "__repeat") [C.Var (string_of_int n); body_term]
  | S.SForever (body, _) ->
      let body_term = desugar_stmts body in
      C.App (C.Var "__forever", body_term)
  | S.SScope (name, body, ret_expr, _) ->
      let scope_name = match name with Some n -> n | None -> "_anon" in
      let body_term = desugar_stmts body in
      let ret_term = desugar_expr ret_expr in
      C.Scope (scope_name, C.App (C.Lam ("_", C.TyBase "unit", ret_term), body_term))
  | S.SWith (r, _of_place, body, _) ->
      let body_term = desugar_stmts body in
      C.With (r, body_term)
  | S.SProduce (body, _) ->
      (* produce { ... } — collects emitted values into a stream *)
      let body_term = desugar_stmts body in
      C.App (C.Var "__produce", body_term)
  | S.SEmit (e, _) ->
      C.Emit (desugar_expr e)
  | S.SForces (stage, cond, body, _) ->
      (* Kripke-Joyal forcing (now with semantics, not ignored): "stage forces
       * cond" builds a directed cell stage -> c_cond into the forced sub-object,
       * registered for compile-time membership (stage_forces). Existence of the
       * cell IS the forcing (user's answer: existence suffices, compile-time).
       * The body still runs; alpha keeps the cell a silicon no-op. The cond code
       * and witness are named from the condition's syntactic shape. *)
      let cond_code =
        match cond with
        | S.CondExpr (S.EVar (n, _)) -> Catt_r_yon.TmVar ("c_" ^ n)
        | S.CondIs (_, S.PatVar n) -> Catt_r_yon.TmVar ("c_" ^ n)
        | S.CondIs (_, S.PatType _) -> Catt_r_yon.TmVar "c_typed"
        | _ -> Catt_r_yon.TmVar "c_cond"
      in
      let _forcing_cell =
        Catt_r_yon.force_stage stage cond_code
          (Catt_r_yon.TmVar ("__forces_" ^ stage))
      in
      desugar_stmts body
  | S.SIter (n_expr, body, _) ->
      (* iter N do { body }: a bounded loop. Lowered to __iter_n(N,
       * body_lambda), recognized by emit as an scf.for. Note: the body_lambda
       * does not receive an index here; the body is repeated N times. *)
      let n_term = desugar_expr n_expr in
      let body_term = desugar_stmts body in
      let body_lam = C.Lam ("_idx", C.TyBase "unit", body_term) in
      curry_apply (C.Var "__iter_n") [n_term; body_lam]
  | S.SWhile (cond_expr, body, _) ->
      (* while cond do { body }: a general loop that may not terminate.
         Lowered as __while_loop(cond_thunk, body_thunk), a flat scf.while with
         the condition re-evaluated each turn. *)
      let cond_term = desugar_expr cond_expr in
      let body_term = desugar_stmts body in
      let cond_thunk = C.Lam ("_", C.TyBase "unit", cond_term) in
      let body_thunk = C.Lam ("_", C.TyBase "unit", body_term) in
      curry_apply (C.Var "__while_loop") [cond_thunk; body_thunk]

and desugar_when c body elifs otherwise =
  (* "when c1 { b1 } when c2 { b2 } ... otherwise { b }"
     translates to nested if-then-else.
     We model "if c then b else b'" as application of an __if combinator. *)
  let body_term = desugar_stmts body in
  let else_term =
    match elifs with
    | [] ->
        (match otherwise with
         | Some other_stmts -> desugar_stmts other_stmts
         | None -> C.Unit)
    | (c2, b2) :: rest ->
        desugar_when c2 b2 rest otherwise
  in
  let cond_term = desugar_condition c in
  curry_apply (C.Var "__if") [cond_term; body_term; else_term]

and desugar_for_every kind x e body =
  let body_lam = C.Lam (x, C.TyBase "unit", desugar_stmts body) in
  let combinator = match kind with
    | S.ForParallel -> "__for_every"
    | S.ForWhenHere -> "__for_every_stream"
  in
  curry_apply (C.Var combinator) [body_lam; desugar_expr e]

and desugar_condition (c : S.condition) : C.term =
  match c with
  | S.CondExpr e -> desugar_expr e
  | S.CondIs (e, p) ->
      curry_apply (C.Var "__is") [desugar_expr e; desugar_pattern p]
  | S.CondIsNot (e, p) ->
      (* x is not p == Heyting negation of (x is p). Reuses the __is
       * runtime path and the topos.heyt_not lowering; __is_not had no
       * runtime emission (it only existed as constant folding). *)
      C.App (C.Var "__heyt_not",
             curry_apply (C.Var "__is") [desugar_expr e; desugar_pattern p])
  | S.CondAnd (c1, c2) ->
      curry_apply (C.Var "__and") [desugar_condition c1; desugar_condition c2]
  | S.CondOr (c1, c2) ->
      curry_apply (C.Var "__or") [desugar_condition c1; desugar_condition c2]

and desugar_pattern (p : S.pattern) : C.term =
  match p with
  | S.PatVar x -> C.Var x
  | S.PatLit l -> desugar_literal l
  | S.PatType _ -> C.Var "__pat_type"
  (* Heyting pattern markers: these are kernel sentinels recognized
   * by the __is operator at runtime. They are distinct from the
   * Heyting value encodings (heyt-prefixed) which represent computed
   * values, not pattern queries. *)
  | S.PatPresent -> C.Var "__pat_present"
  | S.PatAbsent -> C.Var "__pat_absent"
  | S.PatUnknown -> C.Var "__pat_unknown"

(* ─── Top-level declaration translation ────────────────────────────── *)

(* A program is desugared to a sequence of Core declarations + a main
 * entry term. For each declaration we produce a binding context.
 *
 * Approach: the program is processed into a Ctx (Reduce.ctx) of places
 * and reductions, plus a list of function bindings. The "main" entry,
 * if present, becomes the term to evaluate.
 *)

type desugar_result = {
  ctx : Reduce.ctx;
  functions : (string * C.term) list;
  (* name -> declared return type (from the surface AST). Used by
     emit_mlir.extract_func_sig so that the return type is not lost for
     higher-order functions (those with a handle parameter), where inferring it
     from the body fails. *)
  fn_ret_hints : (string * C.ty) list;
  main : C.term option;
  (* The spaces declared in the program, passed to the emitter so it can
     generate yon_rt_register_space at startup. *)
  spaces : S.space_decl list;
  space_init_name : string option;  (* Some name if `init Name as Space` present *)
  space_imports : string list;      (* Space names imported via `import f from Space` *)
  internal_funs : string list;      (* names of `internal fun`s: not exported cross-Space *)
  (* Surface reduction declarations indexed by name. Kept separate from
     ctx.reductions (which are core.reduction_decl) because the surface
     reduction carries information that does not survive desugaring. *)
  reductions_surface : (string * S.reduction_decl) list;
  (* Geometric morphisms declared in the program. The emitter generates the
     yon_rt_register_geom_morphism calls at startup to fill the runtime
     registry used by derive_coordination_from_gm. *)
  geom_morphisms : S.geom_morphism_decl list;
  (* The morphism-to-morphism maps declared inside
     `morph X from A to B { on_morphism N via M }`. For each morph name, the
     list of pairs (src_op_name, tgt_op_name). Kept for future automatic
     dispatch of cross-topos operations. *)
  morphism_maps : (string * (string * string) list) list;
  (* The morphisms declared in the program, accumulated for post-processing in
     desugar_program: for each morph M and each space S we synthesize a mangled
     function __morph_in_<S>__<M> that applies the morph and announces the
     cross-space op (begin_cross_space_op when geometric morphisms are
     registered). *)
  morphs : S.morph_decl list;
  (* The topoi declared in the program. The emitter uses them to derive the
     source space of a morph through the explicit binding `topos T at S`,
     without the same-name heuristic. *)
  toposes : S.topos_decl list;
  (* The nat_transforms declared in the program, accumulated for
     post-processing in desugar_program: for each binding (obj, tgt) we
     synthesize a wrapper <NatTransform>__<obj> that invokes tgt (a fun or a
     reduction clause). *)
  nat_transforms : S.nat_transform_decl list;
}

let empty_result : desugar_result = {
  ctx = Reduce.empty_ctx;
  functions = [];
  fn_ret_hints = [];
  main = None;
  spaces = [];
  space_init_name = None;
  space_imports = [];
  internal_funs = [];
  reductions_surface = [];
  geom_morphisms = [];
  morphism_maps = [];
  morphs = [];
  toposes = [];
  nat_transforms = [];
}

let desugar_place_decl (pd : S.place_decl) : C.place_decl =
  (* Convert surface place_decl to Core place_decl.
     Fields and operations are extracted from the unified members list. *)
  let fields, ops = List.fold_right
    (fun fo (fs, os) ->
       match fo with
       | S.FoField f -> ((f.S.fd_name, desugar_ty f.S.fd_ty) :: fs, os)
       | S.FoOp o ->
           let op_sig = {
             C.op_name = o.S.op_name;
             C.op_algebra = o.S.op_algebra;
             C.op_params = List.map (fun p -> (p.S.param_name, desugar_ty p.S.param_ty)) o.S.op_params;
             C.op_return = (match o.S.op_return with
                            | Some t -> desugar_ty t
                            | None -> C.TyBase "unit");
           } in
           (fs, op_sig :: os)
       | S.FoCell _ ->
           (* cell declarations are metadata for the
            * type-checker and CATT_R_Yon kernel. They don't
            * produce Core place fields or operations. *)
           (fs, os)
       | S.FoLaw _ -> (fs, os))
    pd.S.pd_members ([], [])
  in
  { C.p_name = pd.S.pd_name;
    C.p_laws = pd.S.pd_laws;
    C.p_site = C.TyPlace pd.S.pd_world;
    C.p_fields = fields;
    C.p_operations = ops; }

let desugar_reduction_decl (rd : S.reduction_decl) : C.reduction_decl =
  let handlers = List.filter_map
    (fun rc ->
       match rc with
       | S.RcOn (op_name, params, body, _) ->
           let params' = List.map
             (fun p -> (p.S.param_name, desugar_ty p.S.param_ty))
             params in
           let body_term = desugar_stmts body in
           Some { C.hc_op = op_name;
                  C.hc_params = params';
                  C.hc_body = body_term; }
       | S.RcLet _ -> None  (* state lets handled separately *))
    rd.S.rd_clauses
  in
  { C.r_name = rd.S.rd_name;
    C.r_target = rd.S.rd_of;
    C.r_handlers = handlers;
    C.r_multi_shot = rd.S.rd_multi_shot;
    C.r_fold_name = rd.S.rd_fold_name; }

(* ===================================================================
 * v1.0 surface sugar lowering (2026-06-04).
 *
 * for every / in sequence over / repeat at most / forever are lowered
 * STRUCTURALLY onto the verified primitives: while, iter and Space cells
 * (the one mutation mechanism of 1.0). `x becomes e` promotes the binding
 * of x to a Space cell: `be x holds e0` -> `be x holds Space.make(e0)`,
 * every read of x -> `Space.get(x)`, every becomes -> `Space.set(x, e)`.
 * The promotion is uniform per function (every binding of a becomes-target
 * name allocates a cell), which makes it shadowing-safe; lambda parameters
 * shadow as usual and are excluded inside their bodies.
 * =================================================================== *)

module V1SS = Set.Make (String)

let v1_ctr = ref 0
let v1_fresh p = incr v1_ctr; Printf.sprintf "__v1_%s_%d" p !v1_ctr
let v1_call name args = S.ECall (name, args, S.dummy_loc)
let v1_num n = S.ELit (S.LitNumber n, S.dummy_loc)

(* ---- pass 1: structural loop lowering (stmt -> stmt list) ---- *)
let rec v1_lower_stmt (st : S.stmt) : S.stmt list =
  let body ss = List.concat_map v1_lower_stmt ss in
  match st with
  | S.SForever (b, loc) ->
      [S.SWhile (S.ELit (S.LitBool true, loc), body b, loc)]
  | S.SRepeat (n, b, oth, loc) ->
      (* v1.0 semantics: the body runs exactly N times; the otherwise block
         (if present) runs afterwards. A success-based early exit is a
         post-1.0 protocol. *)
      S.SIter (v1_num (float_of_int n), body b, loc)
      :: (match oth with None -> [] | Some o -> body o)
  | S.SForEvery (_kind, x, e, b, loc) ->
      (* 1.0 executes both for-every kinds SEQUENTIALLY over a List;
         parallelism (and the `when here` space filter) are declared
         intent, not yet a runtime distinction. *)
      v1_lower_foreach x e (body b) loc
  | S.SInSequence (x, e, b, loc) ->
      v1_lower_foreach x e (body b) loc
  | S.SWhen (c, b, elifs, oth, loc) ->
      [S.SWhen (c, body b,
                List.map (fun (c2, b2) -> (c2, body b2)) elifs,
                (match oth with None -> None | Some o -> Some (body o)), loc)]
  | S.SIter (n, b, loc) -> [S.SIter (n, body b, loc)]
  | S.SWhile (c, b, loc) -> [S.SWhile (c, body b, loc)]
  | S.SScope (n, b, r, loc) -> [S.SScope (n, body b, r, loc)]
  | S.SWith (r, p, b, loc) -> [S.SWith (r, p, body b, loc)]
  | S.SProduce (b, loc) -> [S.SProduce (body b, loc)]
  | S.SForces (stg, c, b, loc) -> [S.SForces (stg, c, body b, loc)]
  | other -> [other]

and v1_lower_foreach x e b loc =
  let cur = v1_fresh "cur" in
  let getcur () = v1_call "Space__get" [S.EVar (cur, S.dummy_loc)] in
  [ S.SLet (cur, v1_call "Space__make" [e], loc);
    S.SWhile (
      S.EBinop (S.OpGt, v1_call "List__length" [getcur ()], v1_num 0.0,
                S.dummy_loc),
      S.SLet (x, v1_call "List__head" [getcur ()], loc)
      :: b
      @ [ S.SLet (v1_fresh "adv",
                  v1_call "Space__set"
                    [S.EVar (cur, S.dummy_loc);
                     v1_call "List__tail" [getcur ()]], loc) ],
      loc) ]

(* ---- pass 2: becomes promotion ---- *)
let rec v1_targets_stmts acc ss = List.fold_left v1_targets_stmt acc ss
and v1_targets_stmt acc st =
  match st with
  | S.SAssignBecomes (S.LVar x, _, _) -> V1SS.add x acc
  | S.SAssignBecomes (S.LField _, _, _) -> acc
  | S.SWhen (_, b, elifs, oth, _) ->
      let acc = v1_targets_stmts acc b in
      let acc = List.fold_left (fun a (_, b2) -> v1_targets_stmts a b2) acc elifs in
      (match oth with None -> acc | Some o -> v1_targets_stmts acc o)
  | S.SIter (_, b, _) | S.SWhile (_, b, _) | S.SScope (_, b, _, _)
  | S.SWith (_, _, b, _) | S.SProduce (b, _) | S.SForces (_, _, b, _)
  | S.SForever (b, _) -> v1_targets_stmts acc b
  | S.SForEvery (_, _, _, b, _) | S.SInSequence (_, _, b, _) ->
      v1_targets_stmts acc b
  | S.SRepeat (_, b, oth, _) ->
      let acc = v1_targets_stmts acc b in
      (match oth with None -> acc | Some o -> v1_targets_stmts acc o)
  | _ -> acc

let rec v1_cell_expr cells (e : S.expr) : S.expr =
  let r = v1_cell_expr cells in
  match e with
  | S.EVar (x, loc) when V1SS.mem x cells ->
      v1_call "Space__get" [S.EVar (x, loc)]
  | S.EVar _ | S.ELit _ | S.EPullback _ | S.EPushout _ -> e
  | S.EField (o, f, loc) -> S.EField (r o, f, loc)
  | S.ECall (n, args, loc) -> S.ECall (n, List.map r args, loc)
  | S.ENew (n, fas, loc) ->
      S.ENew (n, List.map (fun fa -> { fa with S.fa_value = r fa.S.fa_value }) fas, loc)
  | S.ENewIn (n, sp, fas, loc) ->
      S.ENewIn (n, sp, List.map (fun fa -> { fa with S.fa_value = r fa.S.fa_value }) fas, loc)
  | S.EBinop (op, a, b, loc) -> S.EBinop (op, r a, r b, loc)
  | S.EParen (x, loc) -> S.EParen (r x, loc)
  | S.EAll (n, c, loc) -> S.EAll (n, v1_cell_cond cells c, loc)
  | S.EIn (x, ctx, loc) -> S.EIn (r x, ctx, loc)
  | S.ERefl (x, loc) -> S.ERefl (r x, loc)
  | S.EPair (a, b, loc) -> S.EPair (r a, r b, loc)
  | S.EFst (x, loc) -> S.EFst (r x, loc)
  | S.ESnd (x, loc) -> S.ESnd (r x, loc)
  | S.EJ (a, b, c, loc) -> S.EJ (r a, r b, r c, loc)
  | S.EPullbackVal (f, g, a, b, loc) -> S.EPullbackVal (f, g, r a, r b, loc)
  | S.ENot (x, loc) -> S.ENot (r x, loc)
  | S.EIfThenElse (c, t, el, loc) -> S.EIfThenElse (r c, r t, r el, loc)
  | S.ELam (ps, b, loc) ->
      let inner = List.fold_left (fun a (n, _) -> V1SS.remove n a) cells ps in
      S.ELam (ps, v1_cell_expr inner b, loc)
  | S.EMoveLam (ps, b, p1, p2, loc) ->
      let inner = List.fold_left (fun a (n, _) -> V1SS.remove n a) cells ps in
      S.EMoveLam (ps, v1_cell_expr inner b, p1, p2, loc)
  | S.EReductionLam (ps, b, pl, loc) ->
      let inner = List.fold_left (fun a (n, _) -> V1SS.remove n a) cells ps in
      S.EReductionLam (ps, v1_cell_expr inner b, pl, loc)
  | S.EMorphLam (ps, b, s1, s2, loc) ->
      let inner = List.fold_left (fun a (n, _) -> V1SS.remove n a) cells ps in
      S.EMorphLam (ps, v1_cell_expr inner b, s1, s2, loc)
  | S.EFunctorLam (ps, b, w1, w2, laws, loc) ->
      let inner = List.fold_left (fun a (n, _) -> V1SS.remove n a) cells ps in
      S.EFunctorLam (ps, v1_cell_expr inner b, w1, w2, laws, loc)
  | S.EViewLam (ps, b, pl, loc) ->
      let inner = List.fold_left (fun a (n, _) -> V1SS.remove n a) cells ps in
      S.EViewLam (ps, v1_cell_expr inner b, pl, loc)
  | S.EComposeWith (a, b, loc) -> S.EComposeWith (r a, r b, loc)

and v1_cell_cond cells (c : S.condition) : S.condition =
  match c with
  | S.CondExpr e -> S.CondExpr (v1_cell_expr cells e)
  | S.CondIs (e, p) -> S.CondIs (v1_cell_expr cells e, p)
  | S.CondIsNot (e, p) -> S.CondIsNot (v1_cell_expr cells e, p)
  | S.CondAnd (a, b) -> S.CondAnd (v1_cell_cond cells a, v1_cell_cond cells b)
  | S.CondOr (a, b) -> S.CondOr (v1_cell_cond cells a, v1_cell_cond cells b)

let rec v1_cell_stmts cells ss = List.map (v1_cell_stmt cells) ss
and v1_cell_stmt cells st =
  let re = v1_cell_expr cells in
  let rb = v1_cell_stmts cells in
  match st with
  | S.SLet (x, e, loc) when V1SS.mem x cells ->
      S.SLet (x, v1_call "Space__make" [re e], loc)
  | S.SLet (x, e, loc) -> S.SLet (x, re e, loc)
  | S.SAssignBecomes (S.LVar x, e, loc) when V1SS.mem x cells ->
      S.SCall ("Space__set", [S.EVar (x, S.dummy_loc); re e], loc)
  | S.SAssignBecomes (S.LField _, _, _) ->
      failwith ("[desugar v1.0] `x.f becomes e` is not implemented: place " ^
                "sections are immutable; mutate through Space cells.")
  | S.SAssignBecomes (lv, e, loc) -> S.SAssignBecomes (lv, re e, loc)
  | S.SAssignHolds (lv, e, loc) -> S.SAssignHolds (lv, re e, loc)
  | S.SReturn (e, loc) -> S.SReturn (re e, loc)
  | S.SCall (n, args, loc) -> S.SCall (n, List.map re args, loc)
  | S.SNew (n, fas, loc) ->
      S.SNew (n, List.map (fun fa -> { fa with S.fa_value = re fa.S.fa_value }) fas, loc)
  | S.SNewIn (n, sp, fas, loc) ->
      S.SNewIn (n, sp, List.map (fun fa -> { fa with S.fa_value = re fa.S.fa_value }) fas, loc)
  | S.SWhen (c, b, elifs, oth, loc) ->
      S.SWhen (v1_cell_cond cells c, rb b,
               List.map (fun (c2, b2) -> (v1_cell_cond cells c2, rb b2)) elifs,
               (match oth with None -> None | Some o -> Some (rb o)), loc)
  | S.SIter (n, b, loc) -> S.SIter (re n, rb b, loc)
  | S.SWhile (c, b, loc) -> S.SWhile (re c, rb b, loc)
  | S.SScope (n, b, r, loc) -> S.SScope (n, rb b, re r, loc)
  | S.SWith (r2, p, b, loc) -> S.SWith (r2, p, rb b, loc)
  | S.SProduce (b, loc) -> S.SProduce (rb b, loc)
  | S.SEmit (e, loc) -> S.SEmit (re e, loc)
  | S.SForces (stg, c, b, loc) -> S.SForces (stg, v1_cell_cond cells c, rb b, loc)
  | S.SForever (b, loc) -> S.SForever (rb b, loc)
  | S.SForEvery (k, x, e, b, loc) -> S.SForEvery (k, x, re e, rb b, loc)
  | S.SInSequence (x, e, b, loc) -> S.SInSequence (x, re e, rb b, loc)
  | S.SRepeat (n, b, oth, loc) ->
      S.SRepeat (n, rb b, (match oth with None -> None | Some o -> Some (rb o)), loc)

(* Per-function entry point: loop lowering, then cell promotion (including
 * the prologue that promotes becomes-target PARAMETERS to cells). *)
let v1_lower_body (params : string list) (body : S.stmt list) : S.stmt list =
  let body1 = List.concat_map v1_lower_stmt body in
  let cells = v1_targets_stmts V1SS.empty body1 in
  if V1SS.is_empty cells then body1
  else begin
    let body2 = v1_cell_stmts cells body1 in
    let prologue =
      List.filter_map
        (fun p ->
           if V1SS.mem p cells then
             Some (S.SLet (p, v1_call "Space__make" [S.EVar (p, S.dummy_loc)],
                           S.dummy_loc))
           else None)
        params in
    prologue @ body2
  end

let desugar_fun_decl (fn : S.fun_decl) : string * C.term =
  let params = List.map
    (fun p -> (p.S.param_name, desugar_ty p.S.param_ty))
    fn.S.fn_params in
  (* The function's parameters must be in the initial `locals`, otherwise
     lifted lambdas in the body would not capture them. Without this, a
     function like `fun f(R: Space) { ... fold(fun(a,b) => Space.set(R, ...)) }`
     would fail with "variable R not in scope". *)
  let param_names = List.map (fun p -> p.S.param_name) fn.S.fn_params in
  (* v1.0 sugar: loops + becomes lowering BEFORE Core desugaring. *)
  let lowered_body = v1_lower_body param_names fn.S.fn_body in
  let body = desugar_stmts_with_locals param_names lowered_body in
  let lam = curry_lam params body in
  (fn.S.fn_name, lam)

(* Process a top-level declaration, updating the desugar_result. *)
let rec process_top_decl (res : desugar_result) (td : S.top_decl) : desugar_result =
  match td with
  | S.TopImport _ -> res   (* import resolved physically pre-parse; no-op *)
  | S.TopImportSym _ -> res   (* selective import: handled in 4b *)
  | S.TopImportFrom (_, _, sp, _) ->
      if List.mem sp res.space_imports then res
      else { res with space_imports = sp :: res.space_imports }
  | S.TopSpaceInit (name, _) -> { res with space_init_name = Some name }
  | S.TopWorld _wd ->
      (* World declarations don't produce Core terms; they're metadata.
         A future version may track them in the context. *)
      res
  | S.TopPlace pd ->
      let core_pd = desugar_place_decl pd in
      { res with ctx = Reduce.declare_place res.ctx core_pd }
  | S.TopFun fn ->
      let res = if fn.S.fn_internal
                then { res with internal_funs = fn.S.fn_name :: res.internal_funs }
                else res in
      let (name, term) = desugar_fun_decl fn in
      (* Terminal absorber (B.3), pure branch only.
         If we have the typed env, the declared return type is the terminal
         object 1 (a fieldless place), and the body is the canonical collapsible
         form `{ return e }` with e pure, then the unique map !_A : A -> 1 lets
         us replace the whole computation by the unique inhabitant (). We keep
         the parameters (so arity/calling convention is unchanged) and only
         replace the body with C.Unit. Effectful bodies are deliberately left
         untouched (that is the B.4 Kleisli branch, which needs the reducer's
         effect tracking aligned first). *)
      let term =
        match !current_env, fn.S.fn_return with
        | Some e, Some ret when Tycheck.is_terminal_ty e ret ->
            (match fn.S.fn_body with
             | [ S.SReturn (rexpr, _) ] when Tycheck.is_pure_expr e rexpr ->
                 (* rebuild the lambda with the same params but a Unit body *)
                 let params =
                   List.map (fun p -> (p.S.param_name, desugar_ty p.S.param_ty))
                     fn.S.fn_params
                 in
                 curry_lam params C.Unit
             | _ -> term)
        | _ -> term
      in
      (* Register the function in Move_engine's user-fun registry so
       * that moves can invoke it as a mapping handler. *)
      Move_engine.register_user_fun name term;
      (* Save the declared return type for emit_mlir. *)
      let ret_hint_pair =
        match fn.S.fn_return with
        | Some t -> [(name, desugar_ty t)]
        | None -> []
      in
      (* registry per analyze_handle (compose). *)
      let param_tys = List.map (fun p -> p.S.param_ty) fn.S.fn_params in
      let ret_ty = match fn.S.fn_return with
        | Some t -> t
        | None -> S.TyPrim "number" in
      user_fun_sigs := (name, (param_tys, ret_ty)) :: !user_fun_sigs;
      let result = { res with
        functions = (name, term) :: res.functions;
        fn_ret_hints = ret_hint_pair @ res.fn_ret_hints;
      } in
      if name = "main" then
        let main_term =
          if fn.S.fn_params = [] then term
          else C.App (term, C.Unit)
        in
        { result with main = Some main_term }
      else result
  | S.TopMove md ->
      (* Register the move declaration so __apply_move can find it. *)
      Move_engine.register_move md;
      res
  | S.TopView _ -> res
  | S.TopReduction rd ->
      let core_rd = desugar_reduction_decl rd in
      (* Also save the surface_ast reduction in res.reductions_surface so the
       * emitter can map it. *)
      { res with
        ctx = Reduce.declare_reduction res.ctx core_rd;
        reductions_surface = (rd.S.rd_name, rd) :: res.reductions_surface }
  | S.TopOperation _ -> res
  | S.TopLet _ -> res
  | S.TopGeomMorphism gm ->
      (* Thesis #3 bridge + Opzione 1: a geometric morphism IS a directed
       * inclusion cell, and its witness is extracted from the body of f^*
       * (gm_pull). We desugar the pull's return expression to a Core term and
       * hand it to cell_of_geom_morphism_with_witness, so the cell carries real
       * geometry (e.g. a Refl return collapses the cell to an identity) rather
       * than a named placeholder. Falls back to the named form if there is no
       * pull body to extract from. The cell is interned; alpha keeps it a
       * silicon no-op, so emitted code is unchanged. *)
      let _cell =
        let c =
          match gm.S.gm_pull with
          | Some f_star ->
              (match f_star.S.fn_body with
               | [] -> Catt_r_yon.cell_of_geom_morphism gm
               | body ->
                   let core_body = desugar_stmts body in
                   Catt_r_yon.cell_of_geom_morphism_with_witness gm core_body)
          | None -> Catt_r_yon.cell_of_geom_morphism gm
        in
        (* Debt 2: register the cell by morphism name so surface code can
         * inspect it via the `directed_cell` builtin. *)
        Catt_r_yon.register_geom_cell gm.S.gm_name c;
        (* Incremental loop: record whether this cell is unchanged vs the
         * persisted graph (skippable). Side-effect only (stats); the result is
         * available to a caller that loaded a previous graph. *)
        ignore (Catt_r_yon.incremental_unchanged gm.S.gm_name c);
        c
      in
      { res with geom_morphisms = gm :: res.geom_morphisms }
  | S.TopPullback _ | S.TopPushout _ ->
      (* universal-construction declarations are metadata for
       * the topos kernel. *)
      res
  | S.TopTopology _ ->
      (* Lawvere-Tierney topology is metadata for the topos
       * kernel; runtime sheafification happens when the topology is
       * applied. *)
      res
  | S.TopReductionCompose _ ->
      (* reduction composition is metadata for the runtime;
       * actual composition is performed at handler-installation time. *)
      res
  | S.TopSpace sd ->
      (* A space declaration. Recorded in the result for propagation to the
       * emitter, which generates the yon_rt_register_space call at the startup
       * of main. *)
      { res with spaces = sd :: res.spaces }
  | S.TopTopos td ->
      (* topos T raggruppa objects +
       * morphisms + props. *)
      (* registry topos -> first place for EMorphLam ret type resolution. *)
      (match td.S.tp_objects with
       | pd :: _ ->
           topos_to_first_place :=
             (td.S.tp_name, pd.S.pd_name) :: !topos_to_first_place
       | [] -> ());
      let res_with_objs = List.fold_left
        (fun acc obj -> process_top_decl acc (S.TopPlace obj))
        res
        td.S.tp_objects
      in
      (* Accumulate the topos itself for the emit. tp_at_space is the explicit
       * binding to its residence space, used to derive the two heap_ids in the
       * synthesis of __morph_in_<S>__<M> without heuristics. *)
      let res_with_topos =
        { res_with_objs with toposes = td :: res_with_objs.toposes } in
      let res_with_morphs = List.fold_left
        (fun acc op -> process_top_decl acc (S.TopOperation op))
        res_with_topos
        td.S.tp_morphisms
      in
      (* Props with a body become fun_decls with return type proposition.
       * Abstract props (without a body) stay metadata. The body is a Heyting
       * expression (evaluated on the semantics side via prop_eval). *)
      List.fold_left
        (fun acc (pr : S.prop_decl) ->
          match pr.pr_body_opt with
          | None -> acc  (* abstract: no lowering *)
          | Some body ->
              let params : S.param list = List.map
                (fun (n, t) -> { S.param_name = n; S.param_ty = t }) pr.pr_params in
              let fn : S.fun_decl = {
                fn_name = pr.pr_name;
                fn_type_params = [];
                fn_params = params;
                fn_return = Some (S.TyPrim "proposition");
                fn_visits = [];
                fn_partial = false; fn_internal = false;
                fn_body = [ S.SReturn (body, pr.pr_loc) ];
                fn_loc = pr.pr_loc;
              } in
              process_top_decl acc (S.TopFun fn))
        res_with_morphs
        td.S.tp_props
  | S.TopMorph mp ->
      (* The operational lowering of a morph.
       *
       * Full lowering:
       *   morph LiftEU from Account to AccountUSD {
       *     on_object(s: State): USDState { ... }
       *     on_morphism N via M
       *   }
       * desugara a:
       *   fun LiftEU(s: State): USDState { ... }        // short alias
       *   fun LiftEU__on_object(s: State): USDState { ... }  // canonical
       *   fun LiftEU__<N>(args): TgtRet { return M(args) }   // one wrapper
       *                                                       per on_morphism
       *
       * The short alias `LiftEU` lets user code write
       *   let usd holds LiftEU(eu)
       * directly, without exposing the compiler's synthesis.
       *
       * The `LiftEU__<N>` wrappers realize the static dispatch of the
       * on_morphism clauses: calling `LiftEU__deposit_eu(...)` makes the
       * program invoke `deposit_global(...)` as declared by the `via`. This
       * honors the categorical binding without requiring dynamic dispatch
       * (which would need runtime tables and operation declarations with full
       * bodies). *)
      let res' = match mp.S.mp_on_object with
        | None -> res
        | Some fd ->
            let short_name = mp.S.mp_name in
            let long_name = mp.S.mp_name ^ "__on_object" in
            let fd_short = { fd with S.fn_name = short_name } in
            let fd_long = { fd with S.fn_name = long_name } in
            let res_with_short = process_top_decl res (S.TopFun fd_short) in
            process_top_decl res_with_short (S.TopFun fd_long)
      in
      (* The on_morphism wrappers are synthesized in the post-processing of
       * desugar_program, where we have the whole program to derive the
       * signature of m_tgt (a fun or a reduction clause). *)
      { res' with
        morphism_maps = (mp.S.mp_name, mp.S.mp_on_morphism_map) :: res'.morphism_maps;
        morphs = mp :: res'.morphs }
  | S.TopNatTransform nt ->
      (* Accumulate for post-processing. The `<NatTransform>__<obj>` wrappers
       * are synthesized in desugar_program with a dynamic signature, as for
       * on_morphism. *)
      { res with nat_transforms = nt :: res.nat_transforms }
  | S.TopFunctor ft ->
      (* For lowering, a top-level functor generates a lifted function
         F(params) -> body. Its categorical identity (the entry in morph_decls)
         is already registered by the type checker; what remains here is the
         computational translation, which reuses process_top_decl on an
         equivalent TopFun. *)
      let fn : S.fun_decl = {
        S.fn_name = ft.S.ft_name;
        S.fn_type_params = [];
        S.fn_params = List.map (fun (n, t) ->
          { S.param_name = n; S.param_ty = t }) ft.S.ft_params;
        S.fn_return = Some (S.TyUser ft.S.ft_to_world);
        S.fn_visits = [];
        S.fn_partial = false; fn_internal = false;
        S.fn_body = [S.SReturn (ft.S.ft_body, ft.S.ft_loc)];
        S.fn_loc = ft.S.ft_loc;
      } in
      process_top_decl res (S.TopFun fn)

(* A pre-desugar rewriting that propagates the binding `topos T at S` to the
 * `new P { ... }` expressions inside.
 *
 * Rule: for every place P belonging to a topos T with tp_at_space =
 * Some space_name, each `new P { ... }` (the form without `in`) is rewritten
 * to `new P in space_name { ... }`. Forms with an explicit `in` are left
 * intact (the user can always override). This way the binding declared on the
 * topos propagates automatically to the instances.
 *
 * Implemented as a recursive fold over expr and stmt, preserving locations
 * and other fields.
 *)
let build_place_to_space_map (p : S.program) : (string * string) list =
  List.fold_left (fun acc td ->
    match td with
    | S.TopTopos topos ->
        (match topos.S.tp_at_space with
         | None -> acc
         | Some space_name ->
             List.fold_left (fun acc' (pd : S.place_decl) ->
               (pd.S.pd_name, space_name) :: acc'
             ) acc topos.S.tp_objects)
    | _ -> acc
  ) [] p

let rec rewrite_expr (m : (string * string) list) (e : S.expr) : S.expr =
  match e with
  | S.ENew (place_name, fas, loc) ->
      let fas' = List.map (fun fa ->
        { fa with S.fa_value = rewrite_expr m fa.S.fa_value }) fas in
      (match List.assoc_opt place_name m with
       | Some space_name -> S.ENewIn (place_name, space_name, fas', loc)
       | None -> S.ENew (place_name, fas', loc))
  | S.ENewIn (place_name, space_name, fas, loc) ->
      let fas' = List.map (fun fa ->
        { fa with S.fa_value = rewrite_expr m fa.S.fa_value }) fas in
      S.ENewIn (place_name, space_name, fas', loc)
  | S.ECall (n, args, loc) ->
      S.ECall (n, List.map (rewrite_expr m) args, loc)
  | S.EBinop (op, a, b, loc) ->
      S.EBinop (op, rewrite_expr m a, rewrite_expr m b, loc)
  | S.EParen (e, loc) -> S.EParen (rewrite_expr m e, loc)
  | S.EField (obj, fld, loc) -> S.EField (rewrite_expr m obj, fld, loc)
  | S.EPair (a, b, loc) -> S.EPair (rewrite_expr m a, rewrite_expr m b, loc)
  | S.EFst (e, loc) -> S.EFst (rewrite_expr m e, loc)
  | S.ESnd (e, loc) -> S.ESnd (rewrite_expr m e, loc)
  | S.EJ (a, b, c, loc) ->
      S.EJ (rewrite_expr m a, rewrite_expr m b, rewrite_expr m c, loc)
  | S.ERefl (e, loc) -> S.ERefl (rewrite_expr m e, loc)
  | S.EIn (e, ctx, loc) -> S.EIn (rewrite_expr m e, ctx, loc)
  | S.EPullbackVal (f, g, a, b, loc) ->
      (* Rewrite EPullbackVal to a call to `__pullback_pack` (a builtin fun
       * synthesized in desugar_program).
       *   pullback(f, g, a, b) -> __pullback_pack(f(a), g(b), a, b)
       * The body of __pullback_pack checks fa==gb and encodes (a,b) as
       * a*1048576 + b (20-bit packing). *)
      let a' = rewrite_expr m a in
      let b' = rewrite_expr m b in
      S.ECall ("__pullback_pack",
        [S.ECall (f, [a'], loc);
         S.ECall (g, [b'], loc);
         a'; b'],
        loc)
  | _ -> e  (* literals, EVar, EAll, ecc.: pass-through *)

(* Rewrite a condition for the tp_at_space propagation. Conditions contain
 * expressions that may in turn contain `new P { ... }`. *)
let rec rewrite_condition (m : (string * string) list) (c : S.condition) : S.condition =
  match c with
  | S.CondExpr e -> S.CondExpr (rewrite_expr m e)
  | S.CondIs (e, p) -> S.CondIs (rewrite_expr m e, p)
  | S.CondIsNot (e, p) -> S.CondIsNot (rewrite_expr m e, p)
  | S.CondAnd (a, b) -> S.CondAnd (rewrite_condition m a, rewrite_condition m b)
  | S.CondOr (a, b) -> S.CondOr (rewrite_condition m a, rewrite_condition m b)

(* Complete rewriting of statements. Every form containing an expr or
 * sub-statement is traversed recursively to propagate
 * `new P { ... }` -> `new P in S { ... }`. *)
let rec rewrite_stmt (m : (string * string) list) (s : S.stmt) : S.stmt =
  let stmts = List.map (rewrite_stmt m) in
  match s with
  | S.SLet (n, e, loc) -> S.SLet (n, rewrite_expr m e, loc)
  | S.SAssignHolds (lv, e, loc) -> S.SAssignHolds (lv, rewrite_expr m e, loc)
  | S.SAssignBecomes (lv, e, loc) -> S.SAssignBecomes (lv, rewrite_expr m e, loc)
  | S.SReturn (e, loc) -> S.SReturn (rewrite_expr m e, loc)
  | S.SCall (n, args, loc) -> S.SCall (n, List.map (rewrite_expr m) args, loc)
  | S.SNew (n, fas, loc) ->
      let fas' = List.map (fun fa ->
        { fa with S.fa_value = rewrite_expr m fa.S.fa_value }) fas in
      (* For SNew, apply the topos.at_space binding-propagation rule. *)
      (match List.assoc_opt n m with
       | Some space_name -> S.SNewIn (n, space_name, fas', loc)
       | None -> S.SNew (n, fas', loc))
  | S.SNewIn (n, sp, fas, loc) ->
      let fas' = List.map (fun fa ->
        { fa with S.fa_value = rewrite_expr m fa.S.fa_value }) fas in
      S.SNewIn (n, sp, fas', loc)
  | S.SWhen (c, body, branches, otherwise_opt, loc) ->
      let branches' = List.map (fun (bc, bs) ->
        (rewrite_condition m bc, stmts bs)) branches in
      let otherwise' = Option.map stmts otherwise_opt in
      S.SWhen (rewrite_condition m c, stmts body, branches', otherwise', loc)
  | S.SForEvery (k, n, e, body, loc) ->
      S.SForEvery (k, n, rewrite_expr m e, stmts body, loc)
  | S.SInSequence (n, e, body, loc) ->
      S.SInSequence (n, rewrite_expr m e, stmts body, loc)
  | S.SRepeat (n, body, otherwise_opt, loc) ->
      S.SRepeat (n, stmts body, Option.map stmts otherwise_opt, loc)
  | S.SForever (body, loc) -> S.SForever (stmts body, loc)
  | S.SScope (name_opt, body, e, loc) ->
      S.SScope (name_opt, stmts body, rewrite_expr m e, loc)
  | S.SWith (r, p_opt, body, loc) ->
      S.SWith (r, p_opt, stmts body, loc)
  | S.SProduce (body, loc) -> S.SProduce (stmts body, loc)
  | S.SEmit (e, loc) -> S.SEmit (rewrite_expr m e, loc)
  | S.SForces (stage, c, body, loc) ->
      S.SForces (stage, rewrite_condition m c, stmts body, loc)
  | S.SIter (n_e, body, loc) ->
      S.SIter (rewrite_expr m n_e, stmts body, loc)
  | S.SWhile (c_e, body, loc) ->
      S.SWhile (rewrite_expr m c_e, stmts body, loc)

let rewrite_top_decl (m : (string * string) list) (td : S.top_decl) : S.top_decl =
  match td with
  | S.TopFun fd ->
      S.TopFun { fd with S.fn_body = List.map (rewrite_stmt m) fd.S.fn_body }
  | S.TopMorph mp ->
      (* The on_object body must be rewritten because it contains `new P
         { ... }` expressions internal to the morph (for example a
         return new USDState { ... }). *)
      let mp' = match mp.S.mp_on_object with
        | None -> mp
        | Some fd ->
            let fd' = { fd with S.fn_body = List.map (rewrite_stmt m) fd.S.fn_body } in
            { mp with S.mp_on_object = Some fd' }
      in
      S.TopMorph mp'
  | S.TopReduction rd ->
      (* RcOn clauses have a body stmt list — recursive rewriting. *)
      let clauses' = List.map (function
        | S.RcOn (n, ps, body, loc) ->
            S.RcOn (n, ps, List.map (rewrite_stmt m) body, loc)
        | S.RcLet (n, e, loc) ->
            S.RcLet (n, rewrite_expr m e, loc)
      ) rd.S.rd_clauses in
      S.TopReduction { rd with S.rd_clauses = clauses' }
  | _ -> td  (* topos block: the fold expands the objects into separate
              * place_decls and the operations into TopOperation; the forms with
              * a stmt body are rewritten to their real position after expansion
              * (where applicable). *)

let desugar_program ?(env : Tyenv.env option = None) (p : S.program) : desugar_result =
  (* The optional [env] is the typed environment from Tycheck (cr_env). The
     terminal absorber (B.3) consults it to collapse a pure, terminal-returning
     function body to the unique inhabitant `()`. When None the absorber stays
     inert, so behavior is identical to before. *)
  current_env := env;
  (* Pre-rewriting that propagates tp_at_space to the `new P { ... }`
   * expressions inside functions. *)
  reset_synth ();  (* reset the accumulator of handle lambdas *)
  let place_to_space = build_place_to_space_map p in
  let p = List.map (rewrite_top_decl place_to_space) p in
  (* The first fold collects synth_funs into the global refs (filled by
   * desugar_expr for each EMoveLam/EReductionLam/EMorphLam). We then add them
   * to the program as TopFun declarations and re-process. *)
  let res = List.fold_left process_top_decl empty_result p in
  (* process_top_decl over the synth_funs may generate more of them (a lambda
   * nested in a lambda). Iterate until synth_funs stabilizes. *)
  let processed_synth_names = ref [] in
  let rec process_synth_until_stable res =
    let pending = List.filter (fun fd ->
      not (List.mem fd.S.fn_name !processed_synth_names)
    ) !synth_funs in
    match pending with
    | [] -> res
    | new_synth ->
        processed_synth_names :=
          List.map (fun fd -> fd.S.fn_name) new_synth @ !processed_synth_names;
        let synth_top_funs = List.map (fun fd -> S.TopFun fd) new_synth in
        let res' = List.fold_left process_top_decl res synth_top_funs in
        process_synth_until_stable res'
  in
  let res = process_synth_until_stable res in
  (* Replace the placeholder bodies of the compose synth functions with the
     real C.term body, h2(h1(x)). *)
  let res =
    if !compose_synth_bodies = [] then res
    else begin
      let bodies = !compose_synth_bodies in
      let new_functions = List.map (fun (n, body) ->
        match List.assoc_opt n bodies with
        | Some real_body -> (n, real_body)
        | None -> (n, body)
      ) res.functions in
      { res with functions = new_functions }
    end
  in
  compose_synth_bodies := [];
  let p = p @ List.map (fun fd -> S.TopFun fd) !synth_funs in
  (* An index of the fun_decls by name, extracted from the whole program.
   * Needed to synthesize the on_morphism wrappers with a dynamic signature:
   * the wrapper inherits params and return type from the target M when M is a
   * function. *)
  let fun_decl_index : (string * S.fun_decl) list =
    List.filter_map (function
      | S.TopFun fd -> Some (fd.S.fn_name, fd)
      | _ -> None
    ) p
  in
  (* Index of the reductions by name. The RcOn clauses carry the list
   * of params; the return type of a reduction clause is not declared
   * explicitly, so it defaults to number. *)
  let reduction_index : (string * S.reduction_decl) list =
    List.filter_map (function
      | S.TopReduction rd -> Some (rd.S.rd_name, rd)
      | _ -> None
    ) p
  in
  (* Symbolic equation check of naturality.
   *
   * We build LHS = eta(F__N(x)) and RHS = G__N(eta(x)) as surface AST terms,
   * normalize (inline + constant folding + elementary algebra), and compare
   * alpha-equivalently.
   *
   * A positive result (Proven) = naturality holds for every input (modulo the
   * soundness of normalization). A negative result (Inconclusive) = not
   * determined; this does not disprove, runtime checks are needed for that.
   *
   * Output: stderr info messages, not error/warning. The runtime verification
   * stays valid; this adds a static guarantee when it can.
   *
   * Declared limits:
   *   - Only pure single-parameter functions with body { return e } (the
   *     synthesized wrappers have this shape)
   *   - No reduction clauses (opaque)
   *   - No algebraic commutativity (2*x != x*2 syntactically)
   *   - No recursion *)
  let () =
    (* Build an extended fun_idx that includes the virtual wrappers F__N, G__N,
     * eta__obj as surface bodies reconstructed on the fly. Each virtual
     * wrapper has the form:
     *   - if the target is a fun: fun F__N(x) { return target(x) }
     *   - if the target is a reduction R with a clause `on N(p) { return e }`:
     *     fun F__N(p) { return e }  // inlining the clause
     * The reduction is inlined to overcome the "opaque reduction" limit. *)
    let synth_wrapper_decl (morph_name : string) (n_src : string) (m_tgt : string) : S.fun_decl option =
      match List.assoc_opt m_tgt fun_decl_index with
      | Some target_fd ->
          let param = match target_fd.S.fn_params with
            | p :: _ -> p
            | [] -> {S.param_name = "x"; param_ty = S.TyPrim "number"}
          in
          let body : S.stmt list = [
            S.SReturn (
              S.ECall (m_tgt,
                [S.EVar (param.S.param_name, S.dummy_loc)],
                S.dummy_loc),
              S.dummy_loc)
          ] in
          Some {
            S.fn_name = morph_name ^ "__" ^ n_src;
            fn_type_params = [];
            fn_params = [param];
            fn_return = target_fd.S.fn_return;
            fn_visits = [];
            fn_partial = false; fn_internal = false;
            fn_body = body;
            fn_loc = S.dummy_loc;
          }
      | None ->
          (* The target may be a reduction. We inline the clause with a
           * matching name if it has the form
           *   on N(p) { return e } *)
          (match List.assoc_opt m_tgt reduction_index with
           | Some rd ->
               let clause = List.find_opt (function
                 | S.RcOn (cname, _, _, _) -> cname = n_src
                 | _ -> false
               ) rd.S.rd_clauses in
               (match clause with
                | Some (S.RcOn (_, params, body_stmts, _)) ->
                    (match params, body_stmts with
                     | [param], [S.SReturn (body_expr, _)] ->
                         (* Direct inline: the wrapper body is the clause
                          * body. *)
                         Some {
                           S.fn_name = morph_name ^ "__" ^ n_src;
                           fn_type_params = [];
                           fn_params = [param];
                           fn_return = Some (S.TyPrim "number");
                           fn_visits = [];
                           fn_partial = false; fn_internal = false;
                           fn_body = [S.SReturn (body_expr, S.dummy_loc)];
                           fn_loc = S.dummy_loc;
                         }
                     | _ -> None)
                | _ -> None)
           | None -> None)
    in
    let all_morphs = List.filter_map (function
      | S.TopMorph mp -> Some mp | _ -> None) p in
    let all_nats = List.filter_map (function
      | S.TopNatTransform nt -> Some nt | _ -> None) p in
    (* For each morph, synthesize the virtual wrappers and add to fun_idx *)
    let wrapper_decls = List.concat_map (fun (mp : S.morph_decl) ->
      List.filter_map (fun (n_src, m_tgt) ->
        synth_wrapper_decl mp.S.mp_name n_src m_tgt
      ) mp.S.mp_on_morphism_map
    ) all_morphs in
    let nat_wrapper_decls = List.concat_map (fun (nt : S.nat_transform_decl) ->
      List.filter_map (fun (obj, tgt) ->
        synth_wrapper_decl nt.S.nt_name obj tgt
      ) nt.S.nt_via_bindings
    ) all_nats in
    let extended_idx =
      fun_decl_index
      @ List.map (fun (fd : S.fun_decl) -> (fd.S.fn_name, fd)) wrapper_decls
      @ List.map (fun (fd : S.fun_decl) -> (fd.S.fn_name, fd)) nat_wrapper_decls
    in
    (* For each nat_transform, for each common morphism, run the check *)
    List.iter (fun (nt : S.nat_transform_decl) ->
      let src_opt = List.find_opt
        (fun (mp : S.morph_decl) -> mp.S.mp_name = nt.S.nt_source_morph)
        all_morphs in
      let tgt_opt = List.find_opt
        (fun (mp : S.morph_decl) -> mp.S.mp_name = nt.S.nt_target_morph)
        all_morphs in
      match src_opt, tgt_opt with
      | Some src, Some tgt ->
          let src_morphisms = List.map fst src.S.mp_on_morphism_map in
          let tgt_morphisms = List.map fst tgt.S.mp_on_morphism_map in
          let common = List.filter
            (fun n -> List.mem n tgt_morphisms) src_morphisms in
          (* For each binding and each common morphism *)
          List.iter (fun (obj, _tgt_eta) ->
            let eta_name = nt.S.nt_name ^ "__" ^ obj in
            List.iter (fun n_common ->
              let f_n_name = src.S.mp_name ^ "__" ^ n_common in
              let g_n_name = tgt.S.mp_name ^ "__" ^ n_common in
              let result = Naturality_symcheck.check
                extended_idx eta_name f_n_name g_n_name "input" in
              (match result with
               | Naturality_symcheck.Proven ->
                   Printf.eprintf
                     "[symcheck F2c] naturality of %s at %s (via %s): PROVEN\n"
                     nt.S.nt_name n_common obj
               | Naturality_symcheck.Inconclusive _msg ->
                   (* This does not mean "naturality fails". It means "we
                      could not normalize the two sides to a syntactic match".
                      The runtime checks F2a/F2b may still find evidence.
                      If YON_F2D=1, escalate to the Z3 SMT solver; if YON_F3=1,
                      escalate to Coq. The two are independent and opt-in. F2d
                      gives a decision-procedure guarantee (Z3, not internally
                      certified); F3 gives a proof-object guarantee (checked by
                      the Coq kernel). *)
                   let f2d_enabled =
                     try Sys.getenv "YON_F2D" = "1" with Not_found -> false in
                   let f3_enabled =
                     try Sys.getenv "YON_F3" = "1" with Not_found -> false in
                   if not f2d_enabled && not f3_enabled then
                     Printf.eprintf
                       "[symcheck F2c] naturality of %s at %s (via %s): INCONCLUSIVE (use F2a/F2b runtime, or YON_F2D=1 for SMT, or YON_F3=1 for Coq proof)\n"
                       nt.S.nt_name n_common obj
                   else begin
                     let (lhs_norm, rhs_norm) =
                       Naturality_symcheck.build_normalized_lhs_rhs
                         extended_idx eta_name f_n_name g_n_name "input" in
                     if f2d_enabled then
                       (match Naturality_smtcheck.check lhs_norm rhs_norm with
                        | Naturality_smtcheck.Smt_proven ->
                            Printf.eprintf
                              "[smtcheck F2d via z3] naturality of %s at %s (via %s): PROVEN_BY_SMT\n"
                              nt.S.nt_name n_common obj
                        | Naturality_smtcheck.Smt_disproven model ->
                            Printf.eprintf
                              "[smtcheck F2d via z3] naturality of %s at %s (via %s): DISPROVEN_BY_SMT\n  counterexample model: %s\n"
                              nt.S.nt_name n_common obj model
                        | Naturality_smtcheck.Smt_unknown reason ->
                            Printf.eprintf
                              "[smtcheck F2d via z3] naturality of %s at %s (via %s): UNKNOWN (%s)\n"
                              nt.S.nt_name n_common obj reason
                        | Naturality_smtcheck.Smt_unsupported reason ->
                            Printf.eprintf
                              "[smtcheck F2d via z3] naturality of %s at %s (via %s): UNSUPPORTED (%s)\n"
                              nt.S.nt_name n_common obj reason);
                     if f3_enabled then begin
                       let theorem_name =
                         "naturality_" ^ nt.S.nt_name ^ "_" ^ n_common ^ "_via_" ^ obj in
                       match Naturality_coqcheck.check ~theorem_name lhs_norm rhs_norm with
                       | Naturality_coqcheck.Coq_proven file ->
                           Printf.eprintf
                             "[coqcheck F3 via coqc] naturality of %s at %s (via %s): PROVEN_BY_COQ\n  proof object in %s\n"
                             nt.S.nt_name n_common obj file
                       | Naturality_coqcheck.Coq_handoff (file, reason) ->
                           Printf.eprintf
                             "[coqcheck F3 via coqc] naturality of %s at %s (via %s): HANDOFF (proof not auto-closed)\n  file emitted: %s\n  reason: %s\n"
                             nt.S.nt_name n_common obj file reason
                       | Naturality_coqcheck.Coq_unsupported reason ->
                           Printf.eprintf
                             "[coqcheck F3 via coqc] naturality of %s at %s (via %s): UNSUPPORTED (%s)\n"
                             nt.S.nt_name n_common obj reason
                     end
                   end)
            ) common
          ) nt.S.nt_via_bindings
      | _ -> ()
    ) all_nats
  in
  (* Post-processing of the on_morphism wrappers with a dynamic signature.
   *
   * For each morph M with on_morphism N via T, we synthesize
   *   fun <M>__<N>(arg1: t1, ..., argk: tk): ret_ty {
   *     return T_call(arg1, ..., argk)
   *   }
   * where (params, ret_ty) are derived from the signature of T:
   *   - T fun: copies fn_params + fn_return
   *   - T reduction with a clause `on N(p1, ..., pk) { ... }`: copies the
   *     clause params, ret_ty = number (conservative default)
   *
   * The call_target is:
   *   - T if T is a fun
   *   - T__N if T is a reduction (clause lowering naming) *)
  let res_with_wrappers =
    List.fold_left (fun acc (mp : S.morph_decl) ->
      List.fold_left (fun acc2 (n_src, m_tgt) ->
        let wrapper_name = mp.S.mp_name ^ "__" ^ n_src in
        let (params, ret_ty, call_target) =
          match List.assoc_opt m_tgt fun_decl_index with
          | Some fd ->
              (* (a) the target is a fun: inherit its full signature *)
              let rt = match fd.S.fn_return with
                | Some t -> t
                | None -> S.TyPrim "number"
              in
              (fd.S.fn_params, rt, m_tgt)
          | None ->
              match List.assoc_opt m_tgt reduction_index with
              | Some rd ->
                  (* (b) the target is a reduction: find the clause with a matching name *)
                  let clause_params = List.find_map (function
                    | S.RcOn (cname, ps, _, _) when cname = n_src -> Some ps
                    | _ -> None
                  ) rd.S.rd_clauses in
                  (match clause_params with
                   | Some ps -> (ps, S.TyPrim "number", m_tgt ^ "__" ^ n_src)
                   | None ->
                       (* The type checker would already have rejected this;
                          fall back to a number->number pass-through. *)
                       ([{S.param_name = "x"; param_ty = S.TyPrim "number"}],
                        S.TyPrim "number",
                        m_tgt ^ "__" ^ n_src))
              | None ->
                  (* The type checker would have rejected this (M is neither a
                     fun nor a reduction); fall back to keep the pipeline live. *)
                  ([{S.param_name = "x"; param_ty = S.TyPrim "number"}],
                   S.TyPrim "number",
                   m_tgt)
        in
        let arg_exprs = List.map (fun (p : S.param) ->
          S.EVar (p.S.param_name, mp.S.mp_loc)
        ) params in
        let body : S.stmt list = [
          S.SReturn (
            S.ECall (call_target, arg_exprs, mp.S.mp_loc),
            mp.S.mp_loc)
        ] in
        let wrapper_fd : S.fun_decl = {
          S.fn_name = wrapper_name;
          fn_type_params = [];
          fn_params = params;
          fn_return = Some ret_ty;
          fn_visits = [];
          fn_partial = false; fn_internal = false;
          fn_body = body;
          fn_loc = mp.S.mp_loc;
        } in
        process_top_decl acc2 (S.TopFun wrapper_fd)
      ) acc mp.S.mp_on_morphism_map
    ) res res.morphs
  in
  let res = res_with_wrappers in
  (* post-processing wrapper nat_transform.
   * For each nat_transform eta with `for each X by Y`, synthesize
   *   fun <η>__<X>(arg1: t1, ..., argk: tk): ret_ty {
   *     return Y_call(arg1, ..., argk)
   *   }
   * where (params, ret_ty, call_target) are derived as for on_morphism via M.
   * We reuse the already-built fun_decl_index/reduction_index. *)
  let res_with_nat_wrappers =
    List.fold_left (fun acc (nt : S.nat_transform_decl) ->
      List.fold_left (fun acc2 (obj, tgt) ->
        let wrapper_name = nt.S.nt_name ^ "__" ^ obj in
        let (params, ret_ty, call_target) =
          match List.assoc_opt tgt fun_decl_index with
          | Some fd ->
              let rt = match fd.S.fn_return with
                | Some t -> t
                | None -> S.TyPrim "number"
              in
              (fd.S.fn_params, rt, tgt)
          | None ->
              match List.assoc_opt tgt reduction_index with
              | Some rd ->
                  let clause_params = List.find_map (function
                    | S.RcOn (cname, ps, _, _) when cname = obj -> Some ps
                    | _ -> None
                  ) rd.S.rd_clauses in
                  (match clause_params with
                   | Some ps -> (ps, S.TyPrim "number", tgt ^ "__" ^ obj)
                   | None ->
                       ([{S.param_name = "x"; param_ty = S.TyPrim "number"}],
                        S.TyPrim "number",
                        tgt ^ "__" ^ obj))
              | None ->
                  ([{S.param_name = "x"; param_ty = S.TyPrim "number"}],
                   S.TyPrim "number",
                   tgt)
        in
        let arg_exprs = List.map (fun (p : S.param) ->
          S.EVar (p.S.param_name, nt.S.nt_loc)
        ) params in
        let body : S.stmt list = [
          S.SReturn (
            S.ECall (call_target, arg_exprs, nt.S.nt_loc),
            nt.S.nt_loc)
        ] in
        let wrapper_fd : S.fun_decl = {
          S.fn_name = wrapper_name;
          fn_type_params = [];
          fn_params = params;
          fn_return = Some ret_ty;
          fn_visits = [];
          fn_partial = false; fn_internal = false;
          fn_body = body;
          fn_loc = nt.S.nt_loc;
        } in
        process_top_decl acc2 (S.TopFun wrapper_fd)
      ) acc nt.S.nt_via_bindings
    ) res res.nat_transforms
  in
  let res = res_with_nat_wrappers in
  (* Automatic runtime naturality assertion.
   *
   * For each nat_transform eta : F => G with exactly one binding
   * `for each obj by handler`, and for each morphism N common to the
   * mp_on_morphism_map of F and G, we synthesize a function
   *   fun __check_naturality_<eta>__<N>(input: number): number {
   *     let lhs holds <eta>__<obj>(F__N(input))
   *     let rhs holds G__N(<eta>__<obj>(input))
   *     when lhs - rhs == 0 { return 1 }
   *     otherwise { return 0 }
   *   }
   *
   * The user can call __check_naturality_<eta>__<N>(input) to check the
   * equation on a sample input.
   *
   * Honest upfront: this does NOT prove universal naturality. It checks only
   * for the inputs passed. The symbolic (F2c) or formal (F3) verification is
   * left open. The check is honest as a "categorical smoke test": if lhs != rhs
   * on a concrete input, naturality does not hold; if they are equal, it is a
   * hint (not a proof) of correctness.
   *
   * Skip when:
   *  - nt_via_bindings has 0 or >1 binding (we do not know which component to
   *    use for X vs Y without further inference)
   *  - the mp_on_morphism_map have no morphisms in common *)
  let res_with_naturality_checks =
    List.fold_left (fun acc (nt : S.nat_transform_decl) ->
      (* Multi-binding: for each component (obj, _) of nt_via_bindings, generate
       * a separate check that uses that component as eta_X = eta_Y.
       *
       * Documented limit: for each component we use the single component for
       * both eta_X and eta_Y. The true naturality case where X != Y (the
       * morphism N goes from object X to a distinct object Y, with distinct
       * components eta_X and eta_Y) is NOT covered. A natural extension, but it
       * requires inferring the source/target object of N. *)
      match nt.S.nt_via_bindings with
      | [] -> acc  (* no binding: nothing to check *)
      | bindings ->
          let src_opt = List.find_opt
            (fun (mp : S.morph_decl) -> mp.S.mp_name = nt.S.nt_source_morph)
            res.morphs in
          let tgt_opt = List.find_opt
            (fun (mp : S.morph_decl) -> mp.S.mp_name = nt.S.nt_target_morph)
            res.morphs in
          (match src_opt, tgt_opt with
           | Some src, Some tgt ->
               let src_morphisms = List.map fst src.S.mp_on_morphism_map in
               let tgt_morphisms = List.map fst tgt.S.mp_on_morphism_map in
               let common = List.filter
                 (fun n -> List.mem n tgt_morphisms) src_morphisms in
               (* Multi-binding: for each component (obj, _), synthesize
                * separate checks that use that component as eta. Names: with a
                * single binding the name stays `__check_naturality_<NT>__<N>`;
                * with several bindings it becomes
                * `__check_naturality_<NT>__<N>__via_<obj>`. *)
               let many = (match bindings with [_] -> false | _ -> true) in
               List.fold_left (fun acc_b (obj, _) ->
                 List.fold_left (fun acc2 n_common ->
                   let check_name =
                     if many then
                       "__check_naturality_" ^ nt.S.nt_name ^ "__" ^ n_common
                       ^ "__via_" ^ obj
                     else
                       "__check_naturality_" ^ nt.S.nt_name ^ "__" ^ n_common in
                   let eta_name = nt.S.nt_name ^ "__" ^ obj in
                   let f_n_name = src.S.mp_name ^ "__" ^ n_common in
                   let g_n_name = tgt.S.mp_name ^ "__" ^ n_common in
                   let loc = nt.S.nt_loc in
                   let input_var = S.EVar ("input", loc) in
                   let body : S.stmt list = [
                     S.SLet ("f_applied",
                       S.ECall (f_n_name, [input_var], loc), loc);
                     S.SLet ("lhs",
                       S.ECall (eta_name,
                         [S.EVar ("f_applied", loc)], loc), loc);
                     S.SLet ("eta_applied",
                       S.ECall (eta_name, [input_var], loc), loc);
                     S.SLet ("rhs",
                       S.ECall (g_n_name,
                         [S.EVar ("eta_applied", loc)], loc), loc);
                     S.SWhen (
                       S.CondExpr (
                         S.EBinop (S.OpEq,
                           S.EVar ("lhs", loc),
                           S.EVar ("rhs", loc),
                           loc)),
                       [S.SReturn (S.ELit (S.LitNumber 1.0, loc), loc)],
                       [],
                       Some [S.SReturn (S.ELit (S.LitNumber 0.0, loc), loc)],
                       loc)
                   ] in
                   let check_fd : S.fun_decl = {
                     S.fn_name = check_name;
                     fn_type_params = [];
                     fn_params = [{S.param_name = "input";
                                   param_ty = S.TyPrim "number"}];
                     fn_return = Some (S.TyPrim "number");
                     fn_visits = [];
                     fn_partial = false; fn_internal = false;
                     fn_body = body;
                     fn_loc = loc;
                   } in
                   process_top_decl acc2 (S.TopFun check_fd)
                 ) acc_b common
               ) acc bindings
           | _ -> acc)
    ) res res.nat_transforms
  in
  let res = res_with_naturality_checks in
  (* Property-based testing of naturality.
   *
   * For each nat_transform for which a `__check_naturality_<eta>__<N>` was
   * synthesized, we also synthesize
   *   fun __check_naturality_<η>__<N>_pbt(seed: number): number {
   *     let i0 holds __check_naturality_<η>__<N>(seed)
   *     let i1 holds __check_naturality_<η>__<N>(seed + 1)
   *     let i2 holds __check_naturality_<η>__<N>(seed * 2)
   *     ...
   *     return i0 * i1 * i2 * ... * i9
   *   }
   *
   * Honest upfront: 10 deterministic inputs derived from the seed. This is not
   * genuine randomness (reproducible given the seed) and does no shrinking. It
   * catches more bugs than the single input.
   *
   * Convention: return value 1 = all inputs pass, 0 = at least one fails. A
   * product of booleans-as-numbers. *)
  let res_with_pbt =
    List.fold_left (fun acc (nt : S.nat_transform_decl) ->
      match nt.S.nt_via_bindings with
      | [] -> acc
      | bindings ->
          let src_opt = List.find_opt
            (fun (mp : S.morph_decl) -> mp.S.mp_name = nt.S.nt_source_morph)
            res.morphs in
          let tgt_opt = List.find_opt
            (fun (mp : S.morph_decl) -> mp.S.mp_name = nt.S.nt_target_morph)
            res.morphs in
          (match src_opt, tgt_opt with
           | Some src, Some tgt ->
               let src_morphisms = List.map fst src.S.mp_on_morphism_map in
               let tgt_morphisms = List.map fst tgt.S.mp_on_morphism_map in
               let common = List.filter
                 (fun n -> List.mem n tgt_morphisms) src_morphisms in
               let many = (match bindings with [_] -> false | _ -> true) in
               List.fold_left (fun acc_b (obj, _) ->
                 List.fold_left (fun acc2 n_common ->
                   let check_base =
                     if many then
                       "__check_naturality_" ^ nt.S.nt_name ^ "__" ^ n_common
                       ^ "__via_" ^ obj
                     else
                       "__check_naturality_" ^ nt.S.nt_name ^ "__" ^ n_common in
                   let pbt_name = check_base ^ "_pbt" in
                   let loc = nt.S.nt_loc in
                   let seed = S.EVar ("seed", loc) in
                   let mk_lit n = S.ELit (S.LitNumber n, loc) in
                   let plus a b = S.EBinop (S.OpAdd, a, b, loc) in
                   let mul a b = S.EBinop (S.OpMul, a, b, loc) in
                   let sub a b = S.EBinop (S.OpSub, a, b, loc) in
                   let inputs = [
                     seed;
                     plus seed (mk_lit 1.0);
                     mul seed (mk_lit 2.0);
                     sub seed (mk_lit 1.0);
                     plus (mul seed (mk_lit 3.0)) (mk_lit 7.0);
                     mul seed (mk_lit 5.0);
                     plus seed (mk_lit 13.0);
                     sub (mul seed (mk_lit 2.0)) (mk_lit 3.0);
                     plus seed (mk_lit 100.0);
                     mul seed (mk_lit 11.0);
                   ] in
                   let let_stmts = List.mapi (fun k e ->
                     let name = "i" ^ string_of_int k in
                     S.SLet (name, S.ECall (check_base, [e], loc), loc)
                   ) inputs in
                   let product_expr =
                     let i k = S.EVar ("i" ^ string_of_int k, loc) in
                     List.fold_left (fun acc_e k -> mul acc_e (i k))
                       (i 0)
                       [1; 2; 3; 4; 5; 6; 7; 8; 9]
                   in
                   let body : S.stmt list =
                     let_stmts @ [S.SReturn (product_expr, loc)]
                   in
                   let pbt_fd : S.fun_decl = {
                     S.fn_name = pbt_name;
                     fn_type_params = [];
                     fn_params = [{S.param_name = "seed";
                                   param_ty = S.TyPrim "number"}];
                     fn_return = Some (S.TyPrim "number");
                     fn_visits = [];
                     fn_partial = false; fn_internal = false;
                     fn_body = body;
                     fn_loc = loc;
                   } in
                   process_top_decl acc2 (S.TopFun pbt_fd)
                 ) acc_b common
               ) acc bindings
           | _ -> acc)
    ) res res.nat_transforms
  in
  let res = res_with_pbt in
  (* The runtime universal pullback. Detection: scan the original surface
   * program (pre-desugar) for EPullbackVal. If present, synthesize
   * __pullback_pack, _pi1, _pi2. *)
  let rec walk_surface_expr_for_pb (e : S.expr) : bool =
    match e with
    | S.EPullbackVal _ -> true
    | S.ECall ("__pullback_pack", _, _) -> true
    | S.ECall (_, args, _) -> List.exists walk_surface_expr_for_pb args
    | S.EBinop (_, a, b, _) -> walk_surface_expr_for_pb a || walk_surface_expr_for_pb b
    | S.EParen (e, _) -> walk_surface_expr_for_pb e
    | S.EField (e, _, _) -> walk_surface_expr_for_pb e
    | S.ENew (_, fas, _) | S.ENewIn (_, _, fas, _) ->
        List.exists (fun fa -> walk_surface_expr_for_pb fa.S.fa_value) fas
    | _ -> false
  in
  let walk_stmt_for_pb (s : S.stmt) : bool =
    match s with
    | S.SLet (_, e, _) | S.SReturn (e, _) -> walk_surface_expr_for_pb e
    | S.SCall (_, args, _) -> List.exists walk_surface_expr_for_pb args
    | _ -> false
  in
  let needs_pullback_builtins =
    List.exists (function
      | S.TopFun fd -> List.exists walk_stmt_for_pb fd.S.fn_body
      | _ -> false
    ) p
  in
  (* Detection of shift/floor/pow2 builtins. Look for calls to the funs
   * `floor`, `__shl`, `__shr`, `__pow2`. *)
  let rec walk_for_name (name : string) (e : S.expr) : bool =
    match e with
    | S.ECall (n, _, _) when n = name -> true
    | S.ECall (_, args, _) -> List.exists (walk_for_name name) args
    | S.EBinop (_, a, b, _) -> walk_for_name name a || walk_for_name name b
    | S.EParen (e, _) -> walk_for_name name e
    | S.EField (e, _, _) -> walk_for_name name e
    | S.ENew (_, fas, _) | S.ENewIn (_, _, fas, _) ->
        List.exists (fun fa -> walk_for_name name fa.S.fa_value) fas
    | _ -> false
  in
  let walk_stmts_for_name (name : string) (ss : S.stmt list) : bool =
    let walk_stmt s = match s with
      | S.SLet (_, e, _) | S.SReturn (e, _) -> walk_for_name name e
      | S.SCall (_, args, _) -> List.exists (walk_for_name name) args
      | _ -> false
    in
    List.exists walk_stmt ss
  in
  let prog_uses_name (name : string) : bool =
    List.exists (function
      | S.TopFun fd -> walk_stmts_for_name name fd.S.fn_body
      | _ -> false
    ) p
  in
  let needs_floor = prog_uses_name "floor" in
  let needs_pow2 = prog_uses_name "__pow2" in
  let needs_shl = prog_uses_name "__shl" in
  let needs_shr = prog_uses_name "__shr" in
  (* Dipendenze transitive:
   *   __shl ⊃ __pow2
   *   __shr ⊃ __pow2, floor
   *   pullback (via __pullback_pi1) ⊃ floor *)
  let needs_pow2 = needs_pow2 || needs_shl || needs_shr in
  let needs_floor = needs_floor || needs_shr || needs_pullback_builtins in
  let res =
    if not needs_pullback_builtins then res
    else
      let loc = S.dummy_loc in
      let num x = S.ELit (S.LitNumber x, loc) in
      let var n = S.EVar (n, loc) in
      let eq a b = S.CondExpr (S.EBinop (S.OpEq, a, b, loc)) in
      let mk_param n = {S.param_name = n; param_ty = S.TyPrim "number"} in
      (* pullback needs floor. Insert floor before the pullback to guarantee
       * the registration order. Skip if already present to avoid
       * duplicates. *)
      let floor_already_present =
        List.exists (fun (n, _) -> n = "floor") res.functions in
      let res =
        if floor_already_present then res
        else
          let body = [S.SReturn (
            S.EBinop (S.OpSub, var "x",
              S.EBinop (S.OpMod, var "x", num 1.0, loc), loc), loc)] in
          let fd : S.fun_decl = {
            S.fn_name = "floor"; fn_type_params = [];
            fn_params = [mk_param "x"];
            fn_return = Some (S.TyPrim "number");
            fn_visits = []; fn_partial = false; fn_internal = false;
            fn_body = body; fn_loc = loc } in
          process_top_decl res (S.TopFun fd)
      in
      (* The pullback packing, encoded with decimal slots.
       *
       * The full universal property of a pullback (a compatible pair plus the
       * projections pi1, pi2 and the factoring map) would need runtime struct
       * allocation. Instead we encode a pair of small non-negative integers
       * into one number, which is enough for the constraint check and the
       * projections:
       *   __pullback_pack(fa, gb, a, b):
       *     if fa == gb: return a * 1000 + b   (decimal packing)
       *     else:        return -1             (a sentinel: the square does
       *                                         not commute)
       *   __pullback_pi1(p): return floor(p / 1000)
       *   __pullback_pi2(p): return p % 1000
       *
       * Honest limit: each slot holds [0, 1000), so a and b must be
       * non-negative integers below 1000. A wider range needs a larger base
       * (10^6, say); f64's exact mantissa caps the total around 10^15. *)
      let pack_body = [
        S.SWhen (
          eq (var "fa") (var "gb"),
          [S.SReturn (
            S.EBinop (S.OpAdd,
              S.EBinop (S.OpMul, var "a", num 1000.0, loc),
              var "b", loc),
            loc)],
          [],
          Some [S.SReturn (
            S.EBinop (S.OpSub, num 0.0, num 1.0, loc),
            loc)],
          loc)
      ] in
      let pack_fd : S.fun_decl = {
        S.fn_name = "__pullback_pack";
        fn_type_params = [];
        fn_params = [mk_param "fa"; mk_param "gb"; mk_param "a"; mk_param "b"];
        fn_return = Some (S.TyPrim "number");
        fn_visits = [];
        fn_partial = false; fn_internal = false;
        fn_body = pack_body;
        fn_loc = loc;
      } in
      (* __pullback_pi1(p): return floor(p / 1000) *)
      let pi1_body = [
        S.SReturn (
          S.ECall ("floor",
            [S.EBinop (S.OpDiv, var "p", num 1000.0, loc)],
            loc),
          loc)
      ] in
      let pi1_fd : S.fun_decl = {
        S.fn_name = "__pullback_pi1";
        fn_type_params = [];
        fn_params = [mk_param "p"];
        fn_return = Some (S.TyPrim "number");
        fn_visits = [];
        fn_partial = false; fn_internal = false;
        fn_body = pi1_body;
        fn_loc = loc;
      } in
      (* __pullback_pi2(p): return p % 1000 *)
      let pi2_body = [
        S.SReturn (
          S.EBinop (S.OpMod, var "p", num 1000.0, loc),
          loc)
      ] in
      let pi2_fd : S.fun_decl = {
        S.fn_name = "__pullback_pi2";
        fn_type_params = [];
        fn_params = [mk_param "p"];
        fn_return = Some (S.TyPrim "number");
        fn_visits = [];
        fn_partial = false; fn_internal = false;
        fn_body = pi2_body;
        fn_loc = loc;
      } in
      let res = process_top_decl res (S.TopFun pack_fd) in
      let res = process_top_decl res (S.TopFun pi1_fd) in
      process_top_decl res (S.TopFun pi2_fd)
  in
  (* Synthesize the builtins floor / __pow2 / __shl / __shr as pure arithmetic
   * funs. Operation: float-based, no bit-level cast.
   *
   * floor(x):    x - x % 1
   * __pow2(n):   recursive 2*pow2(n-1), base n<=0 -> 1
   * __shl(a,n):  a * pow2(n)
   * __shr(a,n):  floor(a / pow2(n))
   *
   * Honest upfront: __shl/__shr are "arithmetic shifts via multiplication", not
   * bit-level. For non-integer a or negative n, the behavior may diverge from
   * the bit shifts. Documented. *)
  let res =
    let loc = S.dummy_loc in
    let num x = S.ELit (S.LitNumber x, loc) in
    let var n = S.EVar (n, loc) in
    let _plus a b = S.EBinop (S.OpAdd, a, b, loc) in
    let minus a b = S.EBinop (S.OpSub, a, b, loc) in
    let mul a b = S.EBinop (S.OpMul, a, b, loc) in
    let div a b = S.EBinop (S.OpDiv, a, b, loc) in
    let modop a b = S.EBinop (S.OpMod, a, b, loc) in
    let leq a b = S.CondExpr (S.EBinop (S.OpLeq, a, b, loc)) in
    let mk_param n = {S.param_name = n; param_ty = S.TyPrim "number"} in
    let res = if not needs_floor then res
      else if List.exists (fun (n, _) -> n = "floor") res.functions then res
      else
        (* fun floor(x): number { return x - (x % 1) } *)
        let body = [S.SReturn (minus (var "x") (modop (var "x") (num 1.0)), loc)] in
        let fd : S.fun_decl = {
          S.fn_name = "floor"; fn_type_params = [];
          fn_params = [mk_param "x"];
          fn_return = Some (S.TyPrim "number");
          fn_visits = []; fn_partial = false; fn_internal = false;
          fn_body = body; fn_loc = loc } in
        process_top_decl res (S.TopFun fd)
    in
    let res = if not needs_pow2 then res
      else
        (* fun __pow2(n): number {
         *   when n <= 0 { return 1 } otherwise { return 2 * __pow2(n - 1) }
         * } *)
        let body = [
          S.SWhen (
            leq (var "n") (num 0.0),
            [S.SReturn (num 1.0, loc)],
            [],
            Some [S.SReturn (
              mul (num 2.0)
                  (S.ECall ("__pow2", [minus (var "n") (num 1.0)], loc)),
              loc)],
            loc)
        ] in
        let fd : S.fun_decl = {
          S.fn_name = "__pow2"; fn_type_params = [];
          fn_params = [mk_param "n"];
          fn_return = Some (S.TyPrim "number");
          fn_visits = []; fn_partial = false; fn_internal = false;
          fn_body = body; fn_loc = loc } in
        process_top_decl res (S.TopFun fd)
    in
    let res = if not needs_shl then res
      else
        (* fun __shl(a, n): number { return a * __pow2(n) } *)
        let body = [S.SReturn (
          mul (var "a") (S.ECall ("__pow2", [var "n"], loc)),
          loc)] in
        let fd : S.fun_decl = {
          S.fn_name = "__shl"; fn_type_params = [];
          fn_params = [mk_param "a"; mk_param "n"];
          fn_return = Some (S.TyPrim "number");
          fn_visits = []; fn_partial = false; fn_internal = false;
          fn_body = body; fn_loc = loc } in
        process_top_decl res (S.TopFun fd)
    in
    let res = if not needs_shr then res
      else
        (* fun __shr(a, n): number { return floor(a / __pow2(n)) }
         * Requires both __pow2 and floor. *)
        let body = [S.SReturn (
          S.ECall ("floor",
            [div (var "a") (S.ECall ("__pow2", [var "n"], loc))],
            loc),
          loc)] in
        let fd : S.fun_decl = {
          S.fn_name = "__shr"; fn_type_params = [];
          fn_params = [mk_param "a"; mk_param "n"];
          fn_return = Some (S.TyPrim "number");
          fn_visits = []; fn_partial = false; fn_internal = false;
          fn_body = body; fn_loc = loc } in
        process_top_decl res (S.TopFun fd)
    in
    res
  in
  (* Post-processing. For each morph M and each space S in the program, we
   * synthesize a function
   *   fun __morph_in_<S>__<M>(x: SrcTy): TgtTy {
   *     return M(x)
   *   }
   * This lets the syntax `M(x) in S` be lowered to a standard runtime call,
   * with the target space name preserved in the function name for future
   * extensions (cross-space announcement, dispatch coordination via gm).
   *
   * Note: for now the body is a simple call to M. The runtime announcement
   * of begin_cross_space_op via geom_morphism can be added as extra body
   * later. *)
  let res_with_morph_in_S =
    List.fold_left (fun acc (mp : S.morph_decl) ->
      match mp.S.mp_on_object with
      | None -> acc
      | Some fd ->
          let arg_name = match fd.S.fn_params with
            | p :: _ -> p.S.param_name
            | [] -> "x" in
          let body : S.stmt list = [
            S.SReturn (
              S.ECall (mp.S.mp_name,
                       [S.EVar (arg_name, mp.S.mp_loc)],
                       mp.S.mp_loc),
              mp.S.mp_loc)
          ] in
          (* Synthesize three variants of the mangled function for each morph:
           *   1. __morph_in_<S>__<M> for every declared space S
           *   2. __morph_in_<T>__<M> for every topos T with tp_at_space
           *      = Some <S> declared. This way the syntax
           *        `LiftEU(eu) in AccountUSD`
           *      works with T = the topos name (resolved via tp_at_space to
           *      its space). *)
          let synth_for_name target_name =
            let mangled = "__morph_in_" ^ target_name ^ "__" ^ mp.S.mp_name in
            let synth_fd : S.fun_decl = {
              S.fn_name = mangled;
              fn_type_params = [];
              fn_params = fd.S.fn_params;
              fn_return = fd.S.fn_return;
              fn_visits = [];
              fn_partial = false; fn_internal = false;
              fn_body = body;
              fn_loc = mp.S.mp_loc;
            } in
            synth_fd
          in
          (* The variant for each space *)
          let acc_with_spaces = List.fold_left (fun acc2 (sd : S.space_decl) ->
            process_top_decl acc2 (S.TopFun (synth_for_name sd.S.sd_name))
          ) acc res.spaces in
          (* One variant per topos that declares an at_space. Skip when the
             topos name coincides with an already-processed space, to avoid
             duplicates. *)
          List.fold_left (fun acc2 (td : S.topos_decl) ->
            match td.S.tp_at_space with
            | None -> acc2
            | Some _ ->
                let space_names = List.map
                  (fun (sd : S.space_decl) -> sd.S.sd_name) res.spaces in
                if List.mem td.S.tp_name space_names then acc2  (* already covered *)
                else
                  process_top_decl acc2 (S.TopFun (synth_for_name td.S.tp_name))
          ) acc_with_spaces res.toposes
    ) res res.morphs
  in
  (* Synthesize the `in S` variants for the nat_transform wrappers
     <NT>__<obj> as well. This enables the syntax
       Upgrade__USDState(x) in AccountUSD
     which announces the cross-space op to the runtime when the component of
     the nat_transform is applied in the target topos. It reuses the
     fun_decl_index / reduction_index built above to derive the wrapper's
     signature. *)
  let res_with_morph_in_S =
    List.fold_left (fun acc (nt : S.nat_transform_decl) ->
      List.fold_left (fun acc2 (obj, tgt) ->
        let wrapper_short = nt.S.nt_name ^ "__" ^ obj in
        let (params, ret_ty_opt) =
          match List.assoc_opt tgt fun_decl_index with
          | Some fd -> (fd.S.fn_params, fd.S.fn_return)
          | None ->
              match List.assoc_opt tgt reduction_index with
              | Some rd ->
                  let clause_params = List.find_map (function
                    | S.RcOn (cname, ps, _, _) when cname = obj -> Some ps
                    | _ -> None
                  ) rd.S.rd_clauses in
                  (match clause_params with
                   | Some ps -> (ps, Some (S.TyPrim "number"))
                   | None ->
                       ([{S.param_name = "x"; param_ty = S.TyPrim "number"}],
                        Some (S.TyPrim "number")))
              | None ->
                  ([{S.param_name = "x"; param_ty = S.TyPrim "number"}],
                   Some (S.TyPrim "number"))
        in
        let arg_exprs = List.map (fun (p : S.param) ->
          S.EVar (p.S.param_name, nt.S.nt_loc)
        ) params in
        let body : S.stmt list = [
          S.SReturn (
            S.ECall (wrapper_short, arg_exprs, nt.S.nt_loc),
            nt.S.nt_loc)
        ] in
        let synth_for_target target_name =
          let mangled = "__morph_in_" ^ target_name ^ "__" ^ wrapper_short in
          { S.fn_name = mangled;
            fn_type_params = [];
            fn_params = params;
            fn_return = ret_ty_opt;
            fn_visits = [];
            fn_partial = false; fn_internal = false;
            fn_body = body;
            fn_loc = nt.S.nt_loc }
        in
        let acc_with_spaces = List.fold_left (fun acc3 (sd : S.space_decl) ->
          process_top_decl acc3 (S.TopFun (synth_for_target sd.S.sd_name))
        ) acc2 res.spaces in
        List.fold_left (fun acc3 (td : S.topos_decl) ->
          match td.S.tp_at_space with
          | None -> acc3
          | Some _ ->
              let space_names = List.map
                (fun (sd : S.space_decl) -> sd.S.sd_name) res.spaces in
              if List.mem td.S.tp_name space_names then acc3
              else
                process_top_decl acc3 (S.TopFun (synth_for_target td.S.tp_name))
        ) acc_with_spaces res.toposes
      ) acc nt.S.nt_via_bindings
    ) res_with_morph_in_S res.nat_transforms
  in
  (* Ordering of the functions for extract_func_sig (which processes
   * List.rev res.functions): we want each function to see in `funcs_so_far`
   * all the ones it calls. The `__morph_in_*` are
   * synthesized after main, so they are at the head of
   * res_with_morph_in_S.functions. main is a bit further down (it was
   * inserted during the fold over the top_decls). The `__morph` syntheses
   * call `LiftEU` (itself synthesized by the lowering of the morph), which is
   * further down still.
   *
   * Strategy: extract the `__morph_in_*` and re-insert them right after main.
   * Result: order [synth_morph_in_S, main, others...] -> List.rev ->
   * [..., main, synth_morph_in_S] -> the fold processes `others` first, then
   * `main`, then `synth_morph_in_S`. Crash: the synth calls LiftEU which was in
   * `others` — OK. But main calls `__morph` which is not yet processed.
   *
   * Inversion: synth at the tail of the list. List.rev -> at the head.
   * Process: synth -> others -> main. synth calls LiftEU not yet in
   * funcs_so_far. Crashes the other way.
   *
   * Soluzione definitiva: synth tra main e others.
   *   Lista: [main, synth_morph, others...]
   *   List.rev: [...others, synth_morph, main]
   *   Fold: others -> synth_morph (sees LiftEU in others) -> main (sees synth in funcs).
   * Extract main and synth from the list, then compose in the desired order. *)
  (* Identify the wrappers synthesized for the `on_morphism N via M` bindings.
   * They are named `<morph_name>__<N>` and depend on M (which is in `others`).
   * They must be processed after others in the extract_func_sig fold, so they
   * come before the others in the list (List.rev puts them after). Same
   * pattern as the `__morph_in_*`. *)
  let wrapper_names =
    let morph_wraps = List.concat_map (fun (mname, bindings) ->
      List.map (fun (n_src, _) -> mname ^ "__" ^ n_src) bindings
    ) res_with_morph_in_S.morphism_maps in
    let nat_wraps = List.concat_map (fun (nt : S.nat_transform_decl) ->
      List.map (fun (obj, _) -> nt.S.nt_name ^ "__" ^ obj) nt.S.nt_via_bindings
    ) res_with_morph_in_S.nat_transforms in
    morph_wraps @ nat_wraps
  in
  let is_wrapper n = List.mem n wrapper_names in
  let is_naturality_check n =
    String.length n >= 19
    && String.sub n 0 19 = "__check_naturality_"
  in
  (* synth_builtins are functions synthesized by the desugar to provide stdlib
   * operations (floor, __pow2, __shl, __shr, __pullback_pack/pi1/pi2). They
   * must be processed before the user functions that call them. We put them at
   * the tail of the final list, so after List.rev they are at the head and are
   * processed first in the fold. *)
  let is_synth_builtin n =
    n = "floor" || n = "__pow2" || n = "__shl" || n = "__shr"
    || n = "__pullback_pack" || n = "__pullback_pi1" || n = "__pullback_pi2"
  in
  let synth_morph_in_S = List.filter
    (fun (n, _) ->
      String.length n >= 11 && String.sub n 0 11 = "__morph_in_")
    res_with_morph_in_S.functions in
  let on_morphism_wrappers = List.filter
    (fun (n, _) -> is_wrapper n)
    res_with_morph_in_S.functions in
  let naturality_checks = List.filter
    (fun (n, _) -> is_naturality_check n)
    res_with_morph_in_S.functions in
  let synth_builtins = List.filter
    (fun (n, _) -> is_synth_builtin n)
    res_with_morph_in_S.functions in
  let non_synth = List.filter
    (fun (n, _) ->
      not (String.length n >= 11 && String.sub n 0 11 = "__morph_in_") &&
      not (is_wrapper n) &&
      not (is_naturality_check n) &&
      not (is_synth_builtin n))
    res_with_morph_in_S.functions in
  let main_entry = List.filter (fun (n, _) -> n = "main") non_synth in
  let others = List.filter (fun (n, _) -> n <> "main") non_synth in
  (* Final order (head -> tail):
   *   main, synth_morph_in_S, naturality_checks, on_morphism_wrappers, others, synth_builtins
   * After List.rev:
   *   synth_builtins, others, on_morphism_wrappers, naturality_checks, synth_morph_in_S, main
   * Fold process:
   *   synth_builtins (no dep on user funs) -> others (see builtins in funcs)
   *                  -> wrappers -> checks -> synth_morph -> main. *)
  let reordered =
    main_entry @ synth_morph_in_S @ naturality_checks @ on_morphism_wrappers
    @ others @ synth_builtins in
  let res = { res_with_morph_in_S with functions = reordered } in
  (* Collect the free variable names occurring in a Core term. Used to compute
   * which functions main actually reaches: only those are wrapped into main's
   * scope, so unreferenced functions do NOT get their bodies emitted inside
   * @main (they remain separate func.func, emitted once). *)
  let rec free_names (acc : string list) (t : C.term) : string list =
    match t with
    | C.Var n -> if List.mem n acc then acc else n :: acc
    | C.Lam (x, _, b) ->
        (* x is bound inside b: collect from b, then drop x. *)
        let inner = free_names [] b in
        List.fold_left (fun a n -> if n = x || List.mem n a then a else n :: a)
          acc inner
    | C.App (f, a) -> free_names (free_names acc f) a
    | C.Scope (_, b) | C.With (_, b) | C.Emit b
    | C.Fst b | C.Snd b | C.Refl b -> free_names acc b
    | C.Pair (a, b) | C.StreamCons (a, b) -> free_names (free_names acc a) b
    | C.J (_, _, a, b, c, d) ->
        free_names (free_names (free_names (free_names acc a) b) c) d
    | C.Place _ | C.Reduction _ | C.Unit -> acc
  in
  (* Transitive closure: starting from main's free names, pull in the free names
   * of each reached function, until fixpoint. *)
  let fn_table = res.functions in
  let reachable_from (start : C.term) : string list =
    let rec fix (seen : string list) (frontier : string list) : string list =
      match frontier with
      | [] -> seen
      | name :: rest ->
          if List.mem name seen then fix seen rest
          else
            let seen' = name :: seen in
            let more =
              match List.assoc_opt name fn_table with
              | Some body -> free_names [] body
              | None -> []
            in
            fix seen' (more @ rest)
    in
    fix [] (free_names [] start)
  in
  match res.main with
  | None -> res
  | Some main_body ->
      let reach = reachable_from main_body in
      let wrapped =
        List.fold_left
          (fun body (name, fn_term) ->
             (* Wrap a function into main's scope only if main reaches it. This
              * keeps the interpreter working (reached functions are in scope)
              * while preventing dead functions from being inlined into @main in
              * the compiled output. *)
             if name = "main" then body
             else if not (List.mem name reach) then body
             else C.App (C.Lam (name, C.TyBase "fun", body), fn_term))
          main_body
          res.functions
      in
      { res with main = Some wrapped }
