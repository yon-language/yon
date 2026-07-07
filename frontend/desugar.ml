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
let produce_counter = ref 0
let spawn_counter = ref 0
(* Forward reference: desugar_expr (earlier rec group) reaches the
   produce-block desugaring defined in the statement group below. *)
let produce_block_ref : (S.stmt list -> C.term) ref =
  ref (fun _ -> failwith "[desugar] produce_block_ref not initialized")
let spawn_block_ref : (S.expr option -> S.stmt list -> C.term) ref =
  ref (fun _ _ -> failwith "[desugar] spawn_block_ref not initialized")
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
      (* A value method call `recv.f(args)` is parsed as f(recv, args): the
         receiver is a plain first argument, captured by the args walk below.
         Module-qualified calls (Seq__fold) and builtins (__band) carry no
         receiver variable. No name parsing is needed. *)
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
  (* General application — e.g. a method call `recv.fold(init, lam)` parses as
     EApp(EField(recv,"fold"), [init; lam]). Before this case fell through to
     `| _ -> []`, the receiver and arguments of a nested combinator call inside
     a lambda body were invisible to capture analysis: an outer lambda whose
     body contained `ys.fold(...)` never captured `ys`, so the lifted function
     crashed at emit with "variable 'ys' not in scope". Traversing EApp threads
     the capture through every nesting level. Over-approximation is safe: the
     caller intersects the result with `current_locals`, so non-local names
     (top-level functions, handles) are filtered out. *)
  | S.EApp (f, args, _) ->
      free_vars_in_expr bound f @ List.concat_map (free_vars_in_expr bound) args
  | S.ENot (sub, _) -> free_vars_in_expr bound sub
  | S.EIn (sub, _, _) -> free_vars_in_expr bound sub
  | S.ERefl (sub, _) -> free_vars_in_expr bound sub
  | S.EPair (a, b, _) ->
      free_vars_in_expr bound a @ free_vars_in_expr bound b
  | S.EFst (sub, _) | S.ESnd (sub, _) -> free_vars_in_expr bound sub
  | S.ESpawn (Some e, _, _) -> free_vars_in_expr bound e
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
  | S.TyUser "String" -> C.TyPlace "text"
  | S.TyPrim n | S.TyPrimIn (n, _) ->
      (match n with
       | "text" | "number" | "boolean" | "money" -> C.TyPlace n
       | other -> C.TyPlace other)
  | (S.TySum _ | S.TySumIn _) as sum_ty ->
      (* A surface sum is the point-only HIT determined by its constructors.
         Its Core carrier is content-addressed by that signature instead of
         collapsing every distinct sum to the old nominal stub "sum". *)
      C.TyPlace (Tyenv.type_tag sum_ty)
  | S.TyList inner -> C.TyPlace ("list_of_" ^ ty_name inner)
  | S.TyMap (_, _) -> C.TyPlace "map"
  | S.TyStream inner -> C.TyStream (desugar_ty inner)
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
  | S.TyPathP ((i, a), _, _) ->
      (* dependent path; the line A binds i. Endpoints dropped to Unit at IR
       * level, like TyId; populated by the cubical primitives. *)
      C.TyPathP ((i, desugar_ty a), C.Unit, C.Unit)
  | S.TyHeytInt _n ->
      (* TyHeytInt<N> is opaque to the core AST for now; the real MLIR
         lowering to tuple<i64, i64> comes later. *)
      C.TyPlace "heyt_int"
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
      C.TyPlace "move_handle"
  | S.TyReductionHandle _po ->
      (* TyReductionHandle is lowered to an opaque string in the Core (the
       * reduction name is resolved at the call site via inlining). *)
      C.TyPlace "reduction_handle"
  | S.TyMorphHandle (_s1, _s2) ->
      (* TyMorphHandle is lowered to an opaque string in the Core. *)
      C.TyPlace "morph_handle"
  | S.TyViewHandle _p ->
      (* TyViewHandle is lowered to an opaque string in the Core. *)
      C.TyPlace "view_handle"
  | S.TyWire _ ->
      (* Wire handle: opaque runtime handle in the Core. *)
      C.TyPlace "wire_handle"
  | S.TySubscription (_, _inner) ->
      (* Subscription handle: opaque; the stream element type is recovered at
       * the await site, not carried by the lowered handle. *)
      C.TyPlace "subscription_handle"
  | S.TyEl (S.TyTermExpr (S.EVar (cname, _))) ->
      (* simple code: a bare name decodes to its carrier (legacy behaviour);
       * defensive fallback if it does not decode. *)
      (match Catt_r_yon.el_decode (Catt_r_yon.TmVar cname) with
       | Some carrier -> desugar_ty carrier
       | None -> C.TyPlace ("El_" ^ cname))
  | S.TyEl (S.TyTermExpr e) ->
      (* applied / structured Tarski code: lower the term natively and keep it
       * as El(term) — exactly the Ast world where subst_term_in_ty operates. *)
      C.TyEl (desugar_expr e)

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
  | S.TyPathP _ -> "PathP"
  | S.TyList _ -> "list"
  | S.TyMap _ -> "map"
  | S.TyStream _ -> "stream"
  | (S.TySum _ | S.TySumIn _) as sum_ty -> Tyenv.type_tag sum_ty
  | S.TyHeytInt n -> Printf.sprintf "heyt_int_%d" n
  | S.TyArrow _ -> "arrow"
  | S.TyMoveHandle _ -> "move_handle"
  | S.TyReductionHandle _ -> "reduction_handle"
  | S.TyMorphHandle _ -> "morph_handle"
  | S.TyViewHandle _ -> "view_handle"
  | S.TyWire _ -> "wire_handle"
  | S.TySubscription _ -> "subscription_handle"
  | S.TyEl c -> (match c with S.TyTermExpr e -> "El_" ^ S.ty_term_to_name e)

(* ─── Helper: build a chain of lambda applications ─────────────────── *)

(* curry_apply f [a;b;c] = App(App(App(f, a), b), c) *)
and curry_apply f args =
  match args with
  | [] -> f
  | a :: rest -> curry_apply (C.App (f, a)) rest

(* curry_lam [(x,T);(y,U)] body = Lam("x", T, Lam("y", U, body)) *)
and curry_lam params body =
  match params with
  | [] -> body
  | (n, t) :: rest -> C.Lam (n, t, curry_lam rest body)

(* Decode the surface fragment that denotes a type code.  Stage 3a only needs
   nominal codes; structured and computed universe paths are handled when the
   general ua transport lowering is introduced. *)
and expr_as_ty (e : S.expr) : C.ty option =
  match e with
  | S.EVar (name, _) -> Some (C.TyPlace name)
  | S.EParen (inner, _) -> expr_as_ty inner
  | _ -> None

and identity_equiv (carrier : C.ty) : C.term =
  let x = "__id_x" in
  let id = C.Lam (x, carrier, C.Var x) in
  let h = C.Lam (x, carrier, C.Refl (C.Var x)) in
  C.Pair (id, C.Pair (id, C.Pair (h, h)))

and ua_identity_line (carrier : C.ty) : string * C.ty =
  let i = "__ua_i" in
  let equiv = identity_equiv carrier in
  (i,
   C.TyGlue
     (carrier,
      [[(i, false)]; [(i, true)]],
      [(carrier, equiv); (carrier, identity_equiv carrier)]))

and equivalence_term (f : S.expr) (g : S.expr)
    (eta : S.expr) (eps : S.expr) : C.term =
  C.Pair
    (desugar_expr f,
     C.Pair
       (desugar_expr g,
        C.Pair (desugar_expr eta, desugar_expr eps)))

and forward_carriers (f : S.expr) : (C.ty * C.ty) option =
  match f, !current_env with
  | S.EVar (name, _), Some env ->
      (match Tyenv.lookup_fun env name with
       | Some fs ->
           (match fs.Tyenv.fs_params with
            | (_, source) :: _ ->
                Some (desugar_ty source, desugar_ty fs.Tyenv.fs_return)
            | [] -> None)
       | None -> None)
  | _ -> None

and ua_equiv_line (source : C.ty) (target : C.ty)
    (equiv : C.term) : string * C.ty =
  let i = "__ua_i" in
  (i,
   C.TyGlue
     (target,
      [[(i, false)]; [(i, true)]],
      [(source, equiv); (target, identity_equiv target)]))

and type_line_of_expr (line : S.expr) : (string * C.ty) option =
  match line with
  | S.ERefl (type_code, _) ->
      Option.map (fun carrier -> ("__comp_i", carrier))
        (expr_as_ty type_code)
  | S.ECall ("ua", [S.ECall ("idEquiv", [type_code], _)], _) ->
      Option.map ua_identity_line (expr_as_ty type_code)
  | S.ECall ("ua", [S.ECall ("equiv", [f; g; eta; eps], _)], _) ->
      (match forward_carriers f with
       | Some (source, target) ->
           Some (ua_equiv_line source target (equivalence_term f g eta eps))
       | None -> None)
  | S.EParen (inner, _) -> type_line_of_expr inner
  | _ -> None

and decode_composition_system (clauses : S.expr list)
    : (C.face_formula * (string * C.face * C.term) list) option =
  let decode_clause = function
    | S.ECall (tag,
        [S.EVar (face_var, _); S.EPathAbs (binder, body, _)], _)
      when tag = "__hcomp_side_i0" || tag = "__hcomp_side_i1" ->
        let face = [(face_var, tag = "__hcomp_side_i1")] in
        Some (face, (binder, face, desugar_expr body))
    | _ -> None
  in
  let decoded = List.filter_map decode_clause clauses in
  if List.length decoded <> List.length clauses then None
  else Some (List.map fst decoded, List.map snd decoded)

(* ─── Expression translation ───────────────────────────────────────── *)

and desugar_expr (e : S.expr) : C.term =
  match e with
  | S.ELit (lit, _) -> desugar_literal lit
  (* Bare `psh_id` (no call parens) is the polymorphic presheaf identity id_A:
   * lower it to the reserved kernel marker `__id` so (F-id) fires. The call
   * form psh_id() is handled in the S.ECall arm. *)
  | S.EVar ("psh_id", _) -> C.Var "__id"
  | S.EVar (x, _) -> C.Var x
  | S.EApp (f, args, _) ->
      curry_apply (desugar_expr f) (List.map desugar_expr args)
  | S.EHITElim (_motive, branches, x, _) ->
      C.HITElim
        (List.map (fun (n, vars, e) -> (n, vars, desugar_expr e)) branches,
         desugar_expr x)
  | S.EPathApp (p, d, _) ->
      let i = (match d with S.DI0 -> C.I0 | S.DI1 -> C.I1 | S.DIVar s -> C.IVar s) in
      C.PApp (desugar_expr p, i)
  | S.EPathAbs (i, e, _) -> C.PLam (i, desugar_expr e)
  | S.EHITConstr (ctor, args, _) -> C.HITConstr (ctor, List.map desugar_expr args)
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
  | S.ECall ("__hcomp_surface",
      [S.EVar (type_name, _); S.ECall ("__hcomp_system", clauses, _); base], _) ->
      let carrier = C.TyPlace type_name in
      (match decode_composition_system clauses with
       | Some (phi, sides) -> C.HComp (carrier, phi, sides, desugar_expr base)
       | None -> failwith "[desugar] malformed hcomp partial system")
  | S.ECall ("__comp_surface",
      [line; S.ECall ("__hcomp_system", clauses, _); base], _) ->
      (match type_line_of_expr line, decode_composition_system clauses with
       | Some (_binder, line_ty), Some (phi, sides) ->
           C.Comp (line_ty, phi, sides, desugar_expr base)
       | None, _ -> failwith "[desugar] comp type-line is not a supported refl/ua path"
       | _, None -> failwith "[desugar] malformed comp partial system")
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
  | S.ECall ("transport", [S.ERefl (type_code, _); value], _) ->
      (* Constant type-line transport is a real cubical term.  Its reduction
         goes through Builtins.try_cubical/Cubical.reduce_transport, where a
         CTBase line computes to the supplied value.  Non-static paths retain
         the existing surface fallback until Stage 3d lowers ua/Glue lines. *)
      (match expr_as_ty type_code with
       | Some line_ty -> C.Transp (("__ti", line_ty), desugar_expr value)
       | None ->
           curry_apply (C.Var "transport")
             [desugar_expr (S.ERefl (type_code, S.dummy_loc));
              desugar_expr value])
  | S.ECall
      ("transport",
       [S.ECall ("ua", [S.ECall ("idEquiv", [type_code], _)], _); value], _) ->
      (* The endpoints are syntactically recoverable for idEquiv(T), so retain
         the full universe line as TyGlue instead of the lossy __type_glue tag
         used by Cubical.ua's standalone type-as-term prototype.  Transport
         then crosses the cubical bridge and computes by the Glue forward map. *)
      (match expr_as_ty type_code with
       | Some carrier -> C.Transp (ua_identity_line carrier, desugar_expr value)
       | None ->
           curry_apply (C.Var "transport")
             [desugar_expr
                (S.ECall
                   ("ua", [S.ECall ("idEquiv", [type_code], S.dummy_loc)],
                    S.dummy_loc));
              desugar_expr value])
  | S.ECall
      ("transport",
       [S.ECall
          ("ua", [S.ECall ("equiv", [f; g; eta; eps], _)], _);
        value], _) ->
      let equiv = equivalence_term f g eta eps in
      (match forward_carriers f with
       | Some (source, target) ->
           C.Transp (ua_equiv_line source target equiv, desugar_expr value)
       | None ->
           curry_apply (C.Var "transport")
             [curry_apply (C.Var "ua")
                [curry_apply (C.Var "equiv")
                   (List.map desugar_expr [f; g; eta; eps])];
              desugar_expr value])
  | S.ECall ("equiv", [f; g; eta; eps], _) ->
      equivalence_term f g eta eps
  (* ── Presheaf arrow-action + composition (A1.2 / A1.3, surface half) ──
   * The kernel (reduce.ml try_functoriality) recognises the arrow action of an
   * abstract presheaf and its two functoriality laws on the exact reserved-Var
   * markers `__psh_map` / `__compose` / `__id`. These surface forms — plain
   * function-call syntax with reserved head names, so NO new grammar and no new
   * menhir conflict — lower to precisely those markers, so the delta-rules fire
   * on desugared programs:
   *   psh_map(F, f)     ==  F(f)     ⟶ App(App(Var "__psh_map", <F>), <f>)
   *   psh_compose(g, f) ==  g ∘ f    ⟶ App(App(Var "__compose", <g>), <f>)
   *   psh_id / psh_id() ==  id       ⟶ Var "__id"
   * (The chosen spelling mirrors the existing __-tagged builtins __band /
   * __hcomp_surface: reserved names threaded through S.ECall, not new tokens.) *)
  | S.ECall ("psh_map", [ff; f], _) ->
      C.App (C.App (C.Var "__psh_map", desugar_expr ff), desugar_expr f)
  | S.ECall ("psh_compose", [g; f], _) ->
      C.App (C.App (C.Var "__compose", desugar_expr g), desugar_expr f)
  | S.ECall ("psh_id", [], _) ->
      C.Var "__id"
  | S.ECall (name, args, loc) ->
      (* Rename Seq -> __stream_. The "Seq" prefix is removed from the internal
       * naming. The surface still accepts Seq.X as a deprecated alias
       * (auto-mapped). *)
      let (name', args') =
        (* Auto-wrap: la funzione di fold/map/filter passata per NOME nudo
         * (`Seq.fold(s,0,g)`) viene avvolta in una lambda inline
         * `fun(__sf0,..) => g(__sf0,..)` — cioè esattamente la forma suggerita
         * `fun(a,b)=>g(a,b)`. Senza, l'emitter falliva con un'eccezione OCaml
         * invece di accettare la funzione per nome. Le lambda gia' inline
         * (non-EVar) passano intatte. *)
        let stream_fn_arity = function
          | "fold" -> 2 | "map" | "filter" -> 1 | _ -> 0 in
        let wrap_fn (arity : int) (args : S.expr list) : S.expr list =
          if arity = 0 then args
          else match List.rev args with
            | S.EVar (n, vloc) :: rest_rev ->
                let ps = List.init arity
                    (fun i -> (Printf.sprintf "__sf%d" i, S.TyPrim "unknown")) in
                let call_args = List.map (fun (pn, _) -> S.EVar (pn, vloc)) ps in
                List.rev (S.ELam (ps, S.ECall (n, call_args, vloc), vloc) :: rest_rev)
            | _ -> args
        in
        let try_chain_rewrite () =
          try
            let idx = Str.search_forward (Str.regexp "__") name 0 in
            let prefix = String.sub name 0 idx in
            let suffix = String.sub name (idx + 2) (String.length name - idx - 2) in
            let is_method = (suffix = "map" || suffix = "filter"
                          || suffix = "fold" || suffix = "take"
                          || suffix = "sum_take" || suffix = "to_stream"
                          || suffix = "for_every") in
            let is_lower = String.length prefix > 0
              && let c = prefix.[0] in c >= 'a' && c <= 'z'
            in
            if is_method && is_lower then
              Some ("__stream_" ^ suffix,
                    wrap_fn (stream_fn_arity suffix) (S.EVar (prefix, loc) :: args))
            else
              None
          with Not_found -> None
        in
        match name with
        | "map" -> ("__stream_map", wrap_fn 1 args)
        | "filter" -> ("__stream_filter", wrap_fn 1 args)
        | "fold" -> ("__stream_fold", wrap_fn 2 args)
        | "for_every" -> ("__stream_for_every", args)
        (* The Stream.X prefix is removed. iterate/take/sum_take become bare
         * builtins; to_stream is a semantic no-op (the list is already a
         * stream). *)
        | "iterate" -> ("__stream_iterate", args)
        | "take" -> ("__stream_take", args)
        | "sum_take" -> ("__stream_sum_take", args)
        | "to_stream" -> ("__stream_to_stream", args)
        (* Backward-compat: Seq.X e Stream.X surface syntax. *)
        | "Seq__map" -> ("__stream_map", wrap_fn 1 args)
        | "Seq__filter" -> ("__stream_filter", wrap_fn 1 args)
        | "Seq__fold" -> ("__stream_fold", wrap_fn 2 args)
        | "Seq__from_list" -> ("__stream_from_list", args)
        (* Seq.range(n) desugara a stream da list. *)
        | "Seq__range" ->
            let list_call = S.ECall ("Seq__range_to_list", args, S.dummy_loc) in
            ("__stream_from_list", [list_call])
        (* Wire: the cross-Space channel family. Surface Wire.X maps to
           the runtime Stream__X symbols (the C names stay; renaming the
           runtime stack is Idraulica v2 territory). The old Stream.X
           channel spellings are rejected with guidance: Stream is the
           sequence (map/filter/fold), Wire is the transport. *)
        | "Wire__make" -> ("Stream__make", args)
        | "Wire__send" -> ("Stream__send", args)
        | "Wire__recv" -> ("Stream__recv", args)
        | "Wire__close" -> ("Stream__close", args)
        | "Wire__make_shm" -> ("Stream__make_shm", args)
        | "Wire__make_shm_sized" -> ("Stream__make_shm_sized", args)
        | "Wire__send_shm" -> ("Stream__send_shm", args)
        | "Wire__recv_shm" -> ("Stream__recv_shm", args)
        | "Wire__produce_shm" -> ("Stream__produce_shm", args)
        | "Wire__await_shm" -> ("Stream__await_shm", args)
        | "Wire__close_shm" -> ("Stream__close_shm", args)
        | "Wire__make_net" -> ("Stream__make_net", args)
        | "Wire__send_net" -> ("Stream__send_net", args)
        | "Wire__recv_net" -> ("Stream__recv_net", args)
        | "Wire__close_net" -> ("Stream__close_net", args)
        | ("Stream__make" | "Stream__send" | "Stream__recv"
          | "Stream__make_shm" | "Stream__send_shm" | "Stream__recv_shm"
          | "Stream__produce_shm" | "Stream__await_shm" | "Stream__close_shm"
          | "Stream__make_net" | "Stream__send_net" | "Stream__recv_net"
          | "Stream__close_net") as old_name ->
            let op = String.sub old_name 8 (String.length old_name - 8) in
            failwith (Printf.sprintf
              "[desugar] Stream.%s was renamed: the channel family lives under Wire (use Wire.%s). Stream is the sequence: map, filter, fold." op op)
        | "Stream__iterate" -> ("__stream_iterate", args)
        | "Stream__take" -> ("__stream_take", args)
        | "Stream__sum_take" -> ("__stream_sum_take", args)
        | _ ->
            (match try_chain_rewrite () with
             | Some (n, a) -> (n, a)
             | None -> (name, args))
      in
      let args_terms = List.map desugar_expr args' in
      (* A zero-argument CALL is not the same surface as a bare name:
         f() means "call now", f means "pass by name". The bare C.Var
         erased that difference and the emitter re-executed the call at
         every use of the bound result (the re-execution bug family).
         Mark the call with a Unit application; the emitter resolves
         App(Var f, Unit) to one func.call for user functions and
         degrades to the old bare-Var behavior for builtins. *)
      (match args_terms with
       | [] -> C.App (C.Var name', C.Unit)
       | _ -> curry_apply (C.Var name') args_terms)
  | S.EProduce (body, _) ->
      !produce_block_ref body
  | S.ESpawn (count, body, _) ->
      !spawn_block_ref count body
  | S.EWireTo (_, _) ->
      (* the wire handle is compile-time identity: the Space name lives
         in the type (TyWire); the runtime value is inert *)
      desugar_expr (S.ELit (S.LitNumber 0.0, S.dummy_loc))
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
  | S.EQuote (_c, a, _) ->
      (* quote(c, a) lowers to a. *)
      desugar_expr a
  | S.EElMatch (target, _ret, body, _) ->
      (* el_match lowers to (body target); ret is dropped. *)
      C.App (desugar_expr body, desugar_expr target)
  | S.EJ (c, d, p, _) ->
      (* Surface ind_path(C, d, p) desugars to kernel J.
       * The motive binder name is synthesized; the carrier type is
       * elaborated later by the type checker. For runtime, J fires
       * the beta-rule J(C, d, refl(a), a) = d(a). The basepoint is
       * projected from the path itself when the path is refl in
       * evidence (the only form the emitter accepts today: a J stuck
       * on a non-refl path is rejected, the runtime never decides
       * path equality); Unit stays as the placeholder otherwise. *)
      let p_core = desugar_expr p in
      let basepoint = match p_core with
        | C.Refl a -> a
        | _ -> C.Unit in
      C.J ("_motive_x", C.TyType 0,
           desugar_expr c, desugar_expr d,
           p_core, basepoint)
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
  (* Compound statements: the substitution must reach nested bodies
     (a lambda bound before a while and called inside it, e.g. the
     stream-method drain lowering). *)
  | S.SWhile (c, b, loc) ->
      S.SWhile (goe c, List.map (subst_var_in_stmt old_n new_n) b, loc)
  | S.SIter (n, b, loc) ->
      S.SIter (goe n, List.map (subst_var_in_stmt old_n new_n) b, loc)
  | S.SForEvery (k, x, e, b, loc) ->
      S.SForEvery (k, x, goe e,
                   (if x = old_n then b
                    else List.map (subst_var_in_stmt old_n new_n) b), loc)
  | S.SInSequence (x, e, b, loc) ->
      S.SInSequence (x, goe e,
                     (if x = old_n then b
                      else List.map (subst_var_in_stmt old_n new_n) b), loc)
  | S.SScope (n, b, r, loc) ->
      S.SScope (n, List.map (subst_var_in_stmt old_n new_n) b, goe r, loc)
  | S.SProduce (b, loc) ->
      S.SProduce (List.map (subst_var_in_stmt old_n new_n) b, loc)
  | S.SForever (b, loc) ->
      S.SForever (List.map (subst_var_in_stmt old_n new_n) b, loc)
  | S.SRepeat (n, b, oth, loc) ->
      S.SRepeat (n, List.map (subst_var_in_stmt old_n new_n) b,
                 (match oth with
                  | None -> None
                  | Some o -> Some (List.map (subst_var_in_stmt old_n new_n) o)), loc)
  | S.SWhen (c, b, elifs, oth, loc) ->
      S.SWhen (subst_var_in_cond old_n new_n c,
               List.map (subst_var_in_stmt old_n new_n) b,
               List.map (fun (c2, b2) ->
                 (subst_var_in_cond old_n new_n c2,
                  List.map (subst_var_in_stmt old_n new_n) b2)) elifs,
               (match oth with
                | None -> None
                | Some o -> Some (List.map (subst_var_in_stmt old_n new_n) o)), loc)
  | _ -> s

and subst_var_in_cond (old_n : string) (new_n : string) (c : S.condition) : S.condition =
  let goe = subst_var_in_expr old_n new_n in
  match c with
  | S.CondExpr e -> S.CondExpr (goe e)
  | S.CondIs (e, p) -> S.CondIs (goe e, p)
  | S.CondIsNot (e, p) -> S.CondIsNot (goe e, p)
  | S.CondAnd (a, b) -> S.CondAnd (subst_var_in_cond old_n new_n a,
                                   subst_var_in_cond old_n new_n b)
  | S.CondOr (a, b) -> S.CondOr (subst_var_in_cond old_n new_n a,
                                 subst_var_in_cond old_n new_n b)

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
    | _ -> S.dummy_loc
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
      C.App (C.Lam (name, C.TyPlace "unit", rest_term), value_term)
  | stmt :: rest ->
      let stmt_term = desugar_stmt_or_return stmt in
      let rest_term = desugar_stmts_with_locals locals rest in
      C.App (C.Lam ("_", C.TyPlace "unit", rest_term), stmt_term)

and desugar_stmt_or_return (s : S.stmt) : C.term =
  match s with
  | S.SReturn (e, _) -> desugar_expr e
  | other -> desugar_stmt other

and desugar_produce_block (body : S.stmt list) : C.term =
  (* produce { ... }: the block creates a stream on the local heap,
     every `emit e` inside it becomes a send into that stream, and the
     value of the block is the stream id. Pure desugar over the live
     Stream API (Stream__make / Stream__send): no new emitter code.
     Nested produce blocks are rewritten innermost-first by recursion,
     so each rewrite only consumes its own Emit nodes; an `emit`
     outside any produce stays a bare C.Emit and is rejected later. *)
  let body_term = desugar_stmts body in
  incr produce_counter;
  let sid = Printf.sprintf "__produce_s%d" !produce_counter in
  let rec rw (t : C.term) : C.term =
    match t with
    | C.Emit e ->
        C.App (C.App (C.Var "Stream__send", C.Var sid), rw e)
    | C.Var _ | C.Unit | C.Place _ | C.Reduction _ | C.World _ -> t
    | C.Lam (x, ty, b) -> C.Lam (x, ty, rw b)
    | C.App (f, a) -> C.App (rw f, rw a)
    | C.Scope (n, b) -> C.Scope (n, rw b)
    | C.Refl e -> C.Refl (rw e)
    | C.J (x, ty, a, b, c, d) -> C.J (x, ty, rw a, rw b, rw c, rw d)
    | C.Pair (a, b) -> C.Pair (rw a, rw b)
    | C.Fst e -> C.Fst (rw e)
    | C.Snd e -> C.Snd (rw e)
    | C.StreamCons (a, b) -> C.StreamCons (rw a, rw b)
    | C.PLam (i, b) -> C.PLam (i, rw b)
    | C.PApp (p, r) -> C.PApp (rw p, r)
    | C.Transp (i, b) -> C.Transp (i, rw b)
    | C.Comp (ty, phi, sides, base) ->
        C.Comp (ty, phi, List.map (fun (j, fc, t) -> (j, fc, rw t)) sides, rw base)
    | C.HComp (ty, phi, sides, base) ->
        C.HComp (ty, phi, List.map (fun (j, fc, t) -> (j, fc, rw t)) sides, rw base)
    | C.GlueElem (phi, t, a) -> C.GlueElem (phi, rw t, rw a)
    | C.Unglue t -> C.Unglue (rw t)
    | C.HITElim (branches, scrut) ->
        C.HITElim (List.map (fun (n, vs, b) -> (n, vs, rw b)) branches, rw scrut)
    | C.HITConstr (n, args) -> C.HITConstr (n, List.map rw args)
  in
  let body' = rw body_term in
  (* (lam sid. (lam _. (lam __c. sid) (Stream__close sid)) body')
       (Stream__make 0)
     The close is STRUCTURAL: when the block ends nobody can write any
     more, by construction, so the wire closes itself. Queued values
     stay readable; a drained closed wire answers recv with the EOF
     sentinel (the fused pipelines' end marker). *)
  C.App (C.Lam (sid, C.TyPlace "number",
           C.App (C.Lam ("_", C.TyPlace "number",
                    C.App (C.Lam ("__c", C.TyPlace "number", C.Var sid),
                           C.App (C.Var "Stream__close", C.Var sid))),
                  body')),
         C.App (C.Var "Stream__make", Builtins.encode_number 0.0))

and desugar_spawn_block (count : S.expr option) (body : S.stmt list) : C.term =
  (* spawn { B } / spawn in N parallel { B }: fork N isolated replicas; each
     `promote e` becomes Spawn__promote(ch, e); spawn_index becomes
     Spawn__index(ch); the child runs the body then Spawn__child_exit(ch); the
     parent joins the promoted values into a stream, which is the value of the
     block. Built over the f64 facade verified in step 4b-i.

         (lam ch.
            __if_expr( Spawn__role(ch) == 1.0,
                       <body'> ; Spawn__child_exit(ch),     -- child
                       Spawn__join_stream(ch) ))            -- parent
         (Spawn__open N)

     Like produce, the body is rewritten innermost-first by recursion, so this
     rewrite only consumes its own Emit nodes (promotes). *)
  let body_term = desugar_stmts body in
  incr spawn_counter;
  let ch = Printf.sprintf "__spawn_ch%d" !spawn_counter in
  let rec rw (t : C.term) : C.term =
    match t with
    | C.Emit e ->
        (* a promote inside this spawn body *)
        C.App (C.App (C.Var "Spawn__promote", C.Var ch), rw e)
    | C.Var "spawn_index" ->
        C.App (C.Var "Spawn__index", C.Var ch)
    | C.Var _ | C.Unit | C.Place _ | C.Reduction _ | C.World _ -> t
    | C.Lam (x, ty, b) -> C.Lam (x, ty, rw b)
    | C.App (f, a) -> C.App (rw f, rw a)
    | C.Scope (n, b) -> C.Scope (n, rw b)
    | C.Refl e -> C.Refl (rw e)
    | C.J (x, ty, a, b, c, d) -> C.J (x, ty, rw a, rw b, rw c, rw d)
    | C.Pair (a, b) -> C.Pair (rw a, rw b)
    | C.Fst e -> C.Fst (rw e)
    | C.Snd e -> C.Snd (rw e)
    | C.StreamCons (a, b) -> C.StreamCons (rw a, rw b)
    | C.PLam (i, b) -> C.PLam (i, rw b)
    | C.PApp (p, r) -> C.PApp (rw p, r)
    | C.Transp (i, b) -> C.Transp (i, rw b)
    | C.Comp (ty, phi, sides, base) ->
        C.Comp (ty, phi, List.map (fun (j, fc, t) -> (j, fc, rw t)) sides, rw base)
    | C.HComp (ty, phi, sides, base) ->
        C.HComp (ty, phi, List.map (fun (j, fc, t) -> (j, fc, rw t)) sides, rw base)
    | C.GlueElem (phi, t, a) -> C.GlueElem (phi, rw t, rw a)
    | C.Unglue t -> C.Unglue (rw t)
    | C.HITElim (branches, scrut) ->
        C.HITElim (List.map (fun (n, vs, b) -> (n, vs, rw b)) branches, rw scrut)
    | C.HITConstr (n, args) -> C.HITConstr (n, List.map rw args)
  in
  let body' = rw body_term in
  (* child: run body' (for its promotes), then exit; sequence via (lam _. exit) body' *)
  let child =
    C.App (C.Lam ("_", C.TyPlace "number",
             C.App (C.Var "Spawn__child_exit", C.Var ch)),
           body') in
  let parent = C.App (C.Var "Spawn__join_stream", C.Var ch) in
  (* condition as i1: Spawn__role(ch) == 1.0 (1.0 = child, 0.0 = parent) *)
  let cond =
    C.App (C.App (C.Var "__eq", C.App (C.Var "Spawn__role", C.Var ch)),
           Builtins.encode_number 1.0) in
  let n_term =
    match count with
    | Some e -> desugar_expr e
    | None -> Builtins.encode_number 1.0 in
  C.App (C.Lam (ch, C.TyPlace "number",
           curry_apply (C.Var "__if_expr") [cond; child; parent]),
         C.App (C.Var "Spawn__open", n_term))

and desugar_stmt (s : S.stmt) : C.term =
  match s with
  | S.SLet (_name, e, _) ->
      (* "be x holds e; rest" — but we handle this in the sequence
         translation; here we just produce the value of e. The binding
         is established by the surrounding lambda. *)
      desugar_expr e
  | S.SAssignHolds (_lv, e, _) -> desugar_expr e
  | S.SDrop (x, _) ->
      (* drop X: reclaim Space X. The emitter recognizes the __drop_space_ prefix
         and lowers this to yon_rt_drop_space(yon_rt_lookup_space("X")). X is a
         declared Space (guaranteed upstream by Space_liveness.check_drops), so
         the yon_space_str_<X> global the space bootstrap emits is present. *)
      C.Var ("__drop_space_" ^ x)
  | S.SAssignBecomes (lv, e, _) ->
      (* "x.f = new_value" -> Space.update_here(id_of(x), x with f := new_value) *)
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
      let body_lam = C.Lam (x, C.TyPlace "unit", desugar_stmts body) in
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
      C.Scope (scope_name, C.App (C.Lam ("_", C.TyPlace "unit", ret_term), body_term))
  | S.SProduce (body, _) ->
      desugar_produce_block body
  | S.SEmit (e, _) ->
      C.Emit (desugar_expr e)
  | S.SPromote (e, _) ->
      (* Inside a spawn body (tycheck guarantees this), promote is "emit onto
       * the spawn's collection". We reuse the C.Emit marker: desugar_spawn_block
       * rewrites these into Spawn__promote(ch, _), exactly as produce rewrites
       * them into Stream__send. *)
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
      let body_lam = C.Lam ("_idx", C.TyPlace "unit", body_term) in
      curry_apply (C.Var "__iter_n") [n_term; body_lam]
  | S.SWhile (cond_expr, body, _) ->
      (* while cond do { body }: a general loop that may not terminate.
         Lowered as __while_loop(cond_thunk, body_thunk), a flat scf.while with
         the condition re-evaluated each turn. *)
      let cond_term = desugar_expr cond_expr in
      let body_term = desugar_stmts body in
      let cond_thunk = C.Lam ("_", C.TyPlace "unit", cond_term) in
      let body_thunk = C.Lam ("_", C.TyPlace "unit", body_term) in
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
  let body_lam = C.Lam (x, C.TyPlace "unit", desugar_stmts body) in
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
                            | None -> C.TyPlace "unit");
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

(* desugar_world_decl: reify a surface world into the Core site C(W). The
 * topology J is read off the CONSTRUCTION (Stage 1 of the Yoneda rebuild made
 * the world a Core citizen; here TopWorld stops being no-op and fills it):
 *
 *   world C = A + B        -> GenCoproduct [A; B]   (disjoint cover)
 *   world Q = W / Rel      -> GenQuotient (W, Rel)  (the R-classes cover)
 *   world Q = coeq(a,b,c)  -> GenCoequalizer (a,b,c)
 *   world S subset of V    -> GenSubset V           (dense inclusion)
 *   world P = A * B        -> NO generator (product is a limit, not a cover)
 *   world W { Code is X }  -> no generator (bare site: J trivial, Sh = PSh)
 *
 * Objects of C(W): the inhabitants if the world is declared with braces; else
 * the factors named by the construction. Generators only ever come from the
 * covering (colimit) constructions; the product contributes objects, not J. *)
let desugar_world_decl (wd : S.world_decl) : C.world_decl =
  let generators =
    let g = [] in
    let g = if wd.S.wd_coproduct_of <> []
            then C.GenCoproduct wd.S.wd_coproduct_of :: g else g in
    let g = match wd.S.wd_quotient_of with
            | Some (b, r) -> C.GenQuotient (b, r) :: g | None -> g in
    let g = match wd.S.wd_coequalizer_of with
            | Some (a, b, c) -> C.GenCoequalizer (a, b, c) :: g | None -> g in
    let g = match wd.S.wd_subset_of with
            | Some p -> C.GenSubset p :: g | None -> g in
    (* wd_product_of intentionally contributes NO generator. *)
    List.rev g
  in
  let objects =
    if wd.S.wd_places <> []
    then List.map (fun (wp : S.world_place) -> wp.S.wp_name) wd.S.wd_places
    else
      wd.S.wd_product_of
      @ wd.S.wd_coproduct_of
      @ (match wd.S.wd_quotient_of with Some (b, _) -> [b] | None -> [])
      @ (match wd.S.wd_subset_of with Some p -> [p] | None -> [])
  in
  { C.w_name = wd.S.wd_name;
    C.w_objects = objects;
    C.w_generators = generators }

(* ===================================================================
 * v1.0 surface sugar lowering (2026-06-04).
 *
 * for every / in sequence over / repeat at most / forever are lowered
 * STRUCTURALLY onto the verified primitives: while, iter and Space cells
 * (the one mutation mechanism of 1.0). `x = e` promotes the binding
 * of x to a Space cell: `be x holds e0` -> `be x holds Space.make(e0)`,
 * every read of x -> `Space.get(x)`, every `x = e` -> `Space.set(x, e)`.
 * The promotion is uniform per function (every binding of a becomes-target
 * name allocates a cell), which makes it shadowing-safe; lambda parameters
 * shadow as usual and are excluded inside their bodies.
 * =================================================================== *)

module V1SS = Set.Make (String)

let v1_ctr = ref 0
let v1_fresh p = incr v1_ctr; Printf.sprintf "__v1_%s_%d" p !v1_ctr
let v1_call name args = S.ECall (name, args, S.dummy_loc)
let v1_num n = S.ELit (S.LitNumber n, S.dummy_loc)

(* A `s.fold(...)` on a produce/emit STREAM (marked in stream_method_table by its call
   site) lowers to STATEMENTS (a Stream__recv drain into an accumulator cell), so it only
   works as a bare statement or the direct RHS of `be x holds` / `return` (the cases in
   v1_lower_stmt). In any NESTED position — an operand of `+`, a call argument — it would
   fall through to the Seq/list fold and read the stream handle as a list, yielding 0. This
   pass lifts each such nested fold to `be __sf holds s.fold(...)` (which then hits the
   correct statement lowering) and leaves a variable in its place. Only the common
   transparent wrappers are walked; an unwalked constructor keeps today's behaviour. *)
let is_stream_fold_call = function
  | S.ECall ("fold", [S.EVar _; _; _], eloc) ->
      Hashtbl.mem S.stream_method_table (eloc.S.start_line, eloc.S.start_col)
  | _ -> false

(* v1_hoist_operand: a bare stream fold in a sub-position IS hoisted to a fresh binding.
   v1_hoist_expr: recurse into transparent wrappers; a bare fold at the TOP is left in
   place for v1_lower_stmt's direct `return` / `be holds` cases to lower. *)
let rec v1_hoist_operand (e : S.expr) : S.stmt list * S.expr =
  if is_stream_fold_call e then
    let t = v1_fresh "sf" in
    let l = S.dummy_loc in
    ([S.SLet (t, e, l)], S.EVar (t, l))
  else v1_hoist_expr e
and v1_hoist_expr (e : S.expr) : S.stmt list * S.expr =
  match e with
  | S.EBinop (op, a, b, l) ->
      let (pa, a') = v1_hoist_operand a in
      let (pb, b') = v1_hoist_operand b in
      (pa @ pb, S.EBinop (op, a', b', l))
  | S.EParen (a, l) -> let (p, a') = v1_hoist_expr a in (p, S.EParen (a', l))
  | S.ENot (a, l) -> let (p, a') = v1_hoist_operand a in (p, S.ENot (a', l))
  | S.EIfThenElse (c, t, f, l) ->
      let (pc, c') = v1_hoist_operand c in
      let (pt, t') = v1_hoist_operand t in
      let (pf, f') = v1_hoist_operand f in
      (pc @ pt @ pf, S.EIfThenElse (c', t', f', l))
  | S.ECall (f, args, l) when not (is_stream_fold_call e) ->
      let (ps, args') = List.split (List.map v1_hoist_operand args) in
      (List.concat ps, S.ECall (f, args', l))
  | S.EApp (h, args, l) ->
      let (ps, args') = List.split (List.map v1_hoist_operand args) in
      (List.concat ps, S.EApp (h, args', l))
  | _ -> ([], e)

(* Lift nested stream folds out of a statement, returning the prelude bindings plus the
   rewritten statement; None when there is nothing nested to hoist (a bare top-level fold
   is left for the direct cases). *)
let v1_try_hoist_stmt (st : S.stmt) : S.stmt list option =
  let wrap pre rebuilt = if pre = [] then None else Some (pre @ [rebuilt]) in
  match st with
  | S.SReturn (e, l) -> let (pre, e') = v1_hoist_expr e in wrap pre (S.SReturn (e', l))
  | S.SLet (x, e, l) -> let (pre, e') = v1_hoist_expr e in wrap pre (S.SLet (x, e', l))
  | S.SCall (name, args, l) when name <> "fold" && name <> "for_every" ->
      let (ps, args') = List.split (List.map v1_hoist_operand args) in
      wrap (List.concat ps) (S.SCall (name, args', l))
  | _ -> None

(* ---- pass 1: structural loop lowering (stmt -> stmt list) ---- *)
let rec v1_lower_stmt (st : S.stmt) : S.stmt list =
  let body ss = List.concat_map v1_lower_stmt ss in
  match v1_try_hoist_stmt st with
  | Some stmts -> List.concat_map v1_lower_stmt stmts
  | None ->
  match st with
  | S.SForever (b, loc) ->
      [S.SWhile (S.ELit (S.LitBool true, loc), body b, loc)]
  | S.SRepeat (n, b, oth, loc) ->
      (* v1.0 semantics: the body runs exactly N times; the otherwise block
         (if present) runs afterwards. A success-based early exit is a
         post-1.0 protocol. *)
      S.SIter (v1_num (float_of_int n), body b, loc)
      :: (match oth with None -> [] | Some o -> body o)
  | S.SForEvery (_kind, x, e, b, loc)
    when Hashtbl.mem S.stream_foreach_table (loc.S.start_line, loc.S.start_col) ->
      (* STREAM collection (registered by the tycheck): drain the wire
         until the structural-close sentinel instead of walking list
         cells. Same cell technique as v1_lower_foreach below. *)
      v1_lower_foreach_stream x e (body b) loc
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
  | S.SProduce (b, loc) -> [S.SProduce (body b, loc)]
  | S.SForces (stg, c, b, loc) -> [S.SForces (stg, c, body b, loc)]
  | S.SCall ("for_every", [S.EVar (recv, _); f], loc)
    when Hashtbl.mem S.stream_method_table (loc.S.start_line, loc.S.start_col) ->
      v1_lower_stream_for_every recv f loc
  | S.SLet (x, S.ECall ("for_every", [S.EVar (recv, _); f], eloc), loc)
    when Hashtbl.mem S.stream_method_table (eloc.S.start_line, eloc.S.start_col) ->
      v1_lower_stream_for_every recv f loc
      @ [S.SLet (x, v1_num 0.0, loc)]
  | S.SCall ("fold", [S.EVar (recv, _); init; f], loc)
    when Hashtbl.mem S.stream_method_table (loc.S.start_line, loc.S.start_col) ->
      fst (v1_lower_stream_fold recv init f loc)
  | S.SLet (x, S.ECall ("fold", [S.EVar (recv, _); init; f], eloc), loc)
    when Hashtbl.mem S.stream_method_table (eloc.S.start_line, eloc.S.start_col) ->
      let (stmts, result) = v1_lower_stream_fold recv init f loc in
      stmts @ [S.SLet (x, result, loc)]
  | S.SReturn (S.ECall ("fold", [S.EVar (recv, _); init; f], eloc), loc)
    when Hashtbl.mem S.stream_method_table (eloc.S.start_line, eloc.S.start_col) ->
      (* `return s.fold(...)`: a stream fold drains via Stream__recv into an
         accumulator cell, which needs statement context. Hoist the drain (the
         same lowering as `be x holds s.fold(...)`) and return its result.
         Without this the fold fell through to the Seq/list fold, which read the
         stream handle as a list and yielded 0. *)
      let (stmts, result) = v1_lower_stream_fold recv init f loc in
      stmts @ [S.SReturn (result, loc)]
  | S.SLet (sub, S.ECall ("awaits", [S.EVar _; S.EVar _], eloc), loc)
    when Hashtbl.mem S.awaits_site_table (eloc.S.start_line, eloc.S.start_col) ->
      (* be sub holds w.awaits(producer): create the shm channel
         (creator side, id = the producer's dispatch selector, nominal
         by construction), send the reserved-selector subscription
         request (the server pump runs the producer and forwards over
         the channel), bind the subscription handle to the channel. *)
      let (sp, sel, chan, n_bytes) =
        Hashtbl.find S.awaits_site_table (eloc.S.start_line, eloc.S.start_col) in
      let l = S.dummy_loc in
      let make_chan =
        if n_bytes > 0 then
          (* place element: a dense byte ring (slot_size 0 selects it); the
             frame is self-delimiting, so the channel needs no per-element size. *)
          S.SLet (v1_fresh "sub_mk",
                  v1_call "Wire__make_shm_sized"
                    [v1_num (float_of_int chan); v1_num 1.0;
                     v1_num 0.0], loc)
        else
          S.SLet (v1_fresh "sub_mk",
                  v1_call "Wire__make_shm"
                    [v1_num (float_of_int chan); v1_num 1.0], loc)
      in
      [ make_chan;
        S.SLet (v1_fresh "sub_rq",
                S.ECall (Printf.sprintf "__yon_rpc2_invoke3__%s" sp,
                         [v1_num 4294967295.0;
                          v1_num (float_of_int sel);
                          v1_num (float_of_int chan);
                          v1_num (float_of_int n_bytes)], l), loc);
        S.SLet (sub, v1_num (float_of_int chan), loc) ]
  | S.SLet (x, S.EField (S.EVar (sub, _), "stream", floc), loc)
    when Hashtbl.mem S.substream_site_table (floc.S.start_line, floc.S.start_col) ->
      (* be s holds sub.stream: drain the completed channel into a
         structurally closed local stream; the methods work unchanged.
         N>0 means the channel carries place DTOs: drain N-byte frames and
         rebuild each place in the consumer's own heap. N=0 is the scalar
         drain. *)
      let n_bytes =
        Hashtbl.find S.substream_site_table (floc.S.start_line, floc.S.start_col) in
      if n_bytes > 0 then
        [ S.SLet (x,
                  v1_call "Wire__subscription_stream_dto"
                    [S.EVar (sub, S.dummy_loc); v1_num (float_of_int n_bytes)], loc) ]
      else
        [ S.SLet (x, v1_call "Wire__subscription_stream" [S.EVar (sub, S.dummy_loc)], loc) ]
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

and v1_lower_foreach_stream x e b loc =
  (* The wire is its own cursor: recv both reads and advances, so the
     only state is a cell holding the current value. Loop shape:
       w = e; cur = cell(recv w);
       while get(cur) != EOF { x = get(cur); body; set(cur, recv w) }
     The EOF sentinel is the structural close of the producer; the body
     never runs on it. Wire__recv (not Stream__recv) so the internal
     call passes the rename map, not the guidance error. *)
  let w = v1_fresh "wire" in
  let cur = v1_fresh "wcur" in
  let l = S.dummy_loc in
  let getcur () = v1_call "Space__get" [S.EVar (cur, l)] in
  let recv () = v1_call "Wire__recv" [S.EVar (w, l)] in
  [ S.SLet (w, e, loc);
    S.SLet (cur, v1_call "Space__make" [recv ()], loc);
    S.SWhile (
      S.EBinop (S.OpNeq, getcur (), v1_num 4294967295.0, l),
      S.SLet (x, getcur (), loc)
      :: b
      @ [ S.SLet (v1_fresh "adv",
                  v1_call "Space__set" [S.EVar (cur, l); recv ()], loc) ],
      loc) ]

and v1_lower_stream_for_every recv f loc =
  (* s.for_every(f): drain the stream, calling f on each value. The
     lambda is bound once to a name (the let-position lifting handles
     both inline and named forms); state, if any, threads through fold
     instead: capture-and-mutate is not closure semantics we offer. *)
  let fn = v1_fresh "fe_f" in
  let w = v1_fresh "fe_w" in
  let cur = v1_fresh "fe_cur" in
  let l = S.dummy_loc in
  let getcur () = v1_call "Space__get" [S.EVar (cur, l)] in
  let recvw () = v1_call "Wire__recv" [S.EVar (w, l)] in
  [ S.SLet (fn, f, loc);
    S.SLet (w, S.EVar (recv, l), loc);
    S.SLet (cur, v1_call "Space__make" [recvw ()], loc);
    S.SWhile (
      S.EBinop (S.OpNeq, getcur (), v1_num 4294967295.0, l),
      [ S.SLet (v1_fresh "fe_r", S.ECall (fn, [getcur ()], l), loc);
        S.SLet (v1_fresh "adv",
                v1_call "Space__set" [S.EVar (cur, l); recvw ()], loc) ],
      loc) ]

and v1_lower_stream_fold recv init f loc =
  (* s.fold(init, f): drain with an accumulator cell; per element
     acc = f(acc, v). Returns (stmts, result_expr). *)
  let fn = v1_fresh "fl_f" in
  let w = v1_fresh "fl_w" in
  let cur = v1_fresh "fl_cur" in
  let acc = v1_fresh "fl_acc" in
  let l = S.dummy_loc in
  let getcur () = v1_call "Space__get" [S.EVar (cur, l)] in
  let getacc () = v1_call "Space__get" [S.EVar (acc, l)] in
  let recvw () = v1_call "Wire__recv" [S.EVar (w, l)] in
  ([ S.SLet (fn, f, loc);
     S.SLet (w, S.EVar (recv, l), loc);
     S.SLet (acc, v1_call "Space__make" [init], loc);
     S.SLet (cur, v1_call "Space__make" [recvw ()], loc);
     S.SWhile (
       S.EBinop (S.OpNeq, getcur (), v1_num 4294967295.0, l),
       [ S.SLet (v1_fresh "fl_set",
                 v1_call "Space__set"
                   [S.EVar (acc, l); S.ECall (fn, [getacc (); getcur ()], l)], loc);
         S.SLet (v1_fresh "adv",
                 v1_call "Space__set" [S.EVar (cur, l); recvw ()], loc) ],
       loc) ],
   getacc ())

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
  | S.SProduce (b, _) | S.SForces (_, _, b, _)
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
  | S.EApp (f, args, loc) -> S.EApp (r f, List.map r args, loc)
  | S.EHITElim (c, branches, x, loc) ->
      S.EHITElim
        (r c, List.map (fun (n, vs, e) -> (n, vs, r e)) branches, r x, loc)
  | S.EPathApp (p, d, loc) -> S.EPathApp (r p, d, loc)
  | S.EPathAbs (i, e, loc) -> S.EPathAbs (i, r e, loc)
  | S.EHITConstr (ctor, args, loc) -> S.EHITConstr (ctor, List.map r args, loc)
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
  | S.EProduce (b, loc) -> S.EProduce (v1_cell_stmts cells b, loc)
  | S.ESpawn (count, b, loc) ->
      S.ESpawn ((match count with Some e -> Some (r e) | None -> None),
                v1_cell_stmts cells b, loc)
  | S.EWireTo _ -> e
  | S.EComposeWith (a, b, loc) -> S.EComposeWith (r a, r b, loc)
  | S.EQuote (c, a, loc) -> S.EQuote (c, r a, loc)
  | S.EElMatch (tgt, ret, bod, loc) -> S.EElMatch (r tgt, r ret, r bod, loc)

and v1_cell_cond cells (c : S.condition) : S.condition =
  match c with
  | S.CondExpr e -> S.CondExpr (v1_cell_expr cells e)
  | S.CondIs (e, p) -> S.CondIs (v1_cell_expr cells e, p)
  | S.CondIsNot (e, p) -> S.CondIsNot (v1_cell_expr cells e, p)
  | S.CondAnd (a, b) -> S.CondAnd (v1_cell_cond cells a, v1_cell_cond cells b)
  | S.CondOr (a, b) -> S.CondOr (v1_cell_cond cells a, v1_cell_cond cells b)

and v1_cell_stmts cells ss = List.map (v1_cell_stmt cells) ss
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
      failwith ("[desugar v1.0] `x.f = e` is not implemented: place " ^
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
  | S.SProduce (b, loc) -> S.SProduce (rb b, loc)
  | S.SEmit (e, loc) -> S.SEmit (re e, loc)
  | S.SPromote (e, loc) -> S.SPromote (re e, loc)
  | S.SForces (stg, c, b, loc) -> S.SForces (stg, v1_cell_cond cells c, rb b, loc)
  | S.SForever (b, loc) -> S.SForever (rb b, loc)
  | S.SForEvery (k, x, e, b, loc) -> S.SForEvery (k, x, re e, rb b, loc)
  | S.SInSequence (x, e, b, loc) -> S.SInSequence (x, re e, rb b, loc)
  | S.SDrop _ -> st
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

(* Run a thunk with every mutable desugar-state ref snapshotted and restored,
 * so a desugaring done outside the main pass (e.g. during type-checking, for
 * definitional equality) cannot perturb lambda-lifting counters or the
 * synthesized-function accumulators. *)
let with_saved_state (f : unit -> 'a) : 'a =
  let s_counter = !synth_counter and s_moves = !synth_moves
  and s_reductions = !synth_reductions and s_morphs = !synth_morphs
  and s_funs = !synth_funs and s_compose = !compose_synth_bodies
  and s_fun_sigs = !user_fun_sigs and s_handles = !handle_bindings
  and s_topos = !topos_to_first_place and s_locals = !current_locals_ref
  and s_produce = !produce_counter and s_spawn = !spawn_counter in
  let restore () =
    synth_counter := s_counter; synth_moves := s_moves;
    synth_reductions := s_reductions; synth_morphs := s_morphs;
    synth_funs := s_funs; compose_synth_bodies := s_compose;
    user_fun_sigs := s_fun_sigs; handle_bindings := s_handles;
    topos_to_first_place := s_topos; current_locals_ref := s_locals;
    produce_counter := s_produce; spawn_counter := s_spawn
  in
  Fun.protect ~finally:restore f

(* Side-effect-free desugaring of a PURE surface expression to Core. Returns
 * None for effectful/lift-requiring expressions (sound: the caller then has
 * no Core term to normalize and treats the comparison conservatively). Used
 * by the definitional-equality endpoint conversion. *)
let desugar_expr_pure (env : Tyenv.env) (e : S.expr) : C.term option =
  with_saved_state (fun () ->
    if Tyenv.is_pure_expr env e then Some (desugar_expr e) else None)

(* Build the delta-rule of a user function: its body as a CURRIED LAMBDA in
 * Core, so that unfolding f(args) is just beta on (lambda params. body) args.
 *
 * Side-effect-free (with_saved_state). The Core term used in definitional
 * equality is therefore the *same* term the function denotes at runtime:
 * identity by behaviour (Yoneda), not a parallel surface heuristic.
 *
 * Returns None unless the body is a single pure `return e`. Anything effectful
 * or lift-requiring (move/morph/produce/spawn) yields no delta-rule, so the
 * equality judgment leaves such calls opaque — sound. No fuel, no heuristics,
 * no magic numbers. *)
let delta_rule_of_fun (env : Tyenv.env) (fn : S.fun_decl) : C.term option =
  with_saved_state (fun () ->
    match fn.S.fn_body with
    | [ S.SReturn (rexpr, _) ] when Tyenv.is_pure_expr env rexpr ->
        let params =
          List.map
            (fun (p : S.param) -> (p.S.param_name, desugar_ty p.S.param_ty))
            fn.S.fn_params
        in
        Some (curry_lam params (desugar_expr rexpr))
    | _ -> None)

(* Process a top-level declaration, updating the desugar_result. *)
let rec process_top_decl (res : desugar_result) (td : S.top_decl) : desugar_result =
  match td with
  | S.TopImport _ -> res   (* import resolved physically pre-parse; no-op *)
  | S.TopImportSym _ -> res   (* selective import: handled in 4b *)
  | S.TopImportFrom (_, _, sp, _) ->
      if List.mem sp res.space_imports then res
      else { res with space_imports = sp :: res.space_imports }
  | S.TopWorld wd ->
      (* Reify the world as the Core site C(W) and register it: a place will
       * find its site via p_site, and the sheaf predicate reads J off the
       * world's generators. No longer no-op metadata. *)
      let core_wd = desugar_world_decl wd in
      { res with ctx = Reduce.declare_world res.ctx core_wd }
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
        | Some e, Some ret when Tyenv.is_terminal_ty e ret ->
            (match fn.S.fn_body with
             | [ S.SReturn (rexpr, _) ] when Tyenv.is_pure_expr e rexpr ->
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
      (* A topos `T in W` gives its objects world W when they don't name one.
         Under toml-only the inner places carry no `in W`, so without this they
         would stay __INFER (no world) and fail the checks. *)
      let res_with_objs = List.fold_left
        (fun acc obj ->
           let obj =
             if obj.S.pd_world = "__INFER" then
               (match td.S.tp_world with
                | Some w -> { obj with S.pd_world = w }
                | None -> obj)
             else obj in
           process_top_decl acc (S.TopPlace obj))
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
       *   be usd holds LiftEU(eu)
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
  | S.SProduce (body, loc) -> S.SProduce (stmts body, loc)
  | S.SEmit (e, loc) -> S.SEmit (rewrite_expr m e, loc)
  | S.SPromote (e, loc) -> S.SPromote (rewrite_expr m e, loc)
  | S.SForces (stage, c, body, loc) ->
      S.SForces (stage, rewrite_condition m c, stmts body, loc)
  | S.SIter (n_e, body, loc) ->
      S.SIter (rewrite_expr m n_e, stmts body, loc)
  | S.SWhile (c_e, body, loc) ->
      S.SWhile (rewrite_expr m c_e, stmts body, loc)
  | S.SDrop _ -> s

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

let rec rewrite_view_fields fields e =
  let r = rewrite_view_fields fields in
  match e with
  | S.EVar (n, loc) when List.mem_assoc n fields ->
      S.EField (S.EVar ("__view_s", loc), n, loc)
  | S.EBinop (op, a, b, loc) -> S.EBinop (op, r a, r b, loc)
  | S.EParen (e1, loc) -> S.EParen (r e1, loc)
  | S.ECall (n, args, loc) -> S.ECall (n, List.map r args, loc)
  | S.EField (e1, f, loc) -> S.EField (r e1, f, loc)
  | other -> other

(* View declaration lowering: each
   `view V of P { show ... }` expands into a synthetic record place V
   (one field per show clause) plus a constructor function V(s: P): V
   building the record, so `V(x)` and `r.field` just work through the
   existing machinery. `show f as "label"` keeps the field; the label
   is presentation metadata. The inline view lambda path is untouched. *)
let expand_views (p : S.program) : S.program =
let place_info = List.filter_map (function
    | S.TopPlace pd ->
        let fields = List.filter_map (function
          | S.FoField fd -> Some (fd.S.fd_name, fd.S.fd_ty)
          | _ -> None) pd.S.pd_members in
        Some (pd.S.pd_name, (pd.S.pd_world, fields))
    | _ -> None) p in
  let already_expanded view_name =
    List.exists (function
      | S.TopPlace pd -> pd.S.pd_name = view_name
      | _ -> false) p
    && List.exists (function
      | S.TopFun fd -> fd.S.fn_name = view_name
      | _ -> false) p
  in
  List.concat_map (function
    | S.TopView vd ->
        if already_expanded vd.S.vw_name then [S.TopView vd]
        else (match List.assoc_opt vd.S.vw_of place_info with
         | None -> [S.TopView vd]   (* unknown target: tycheck reports *)
         | Some (world, fields) ->
             let loc = vd.S.vw_loc in
             let num = S.TyPrim "number" in
             let shown = List.map (function
               | S.VShowSimple f | S.VShowLabel (f, _) ->
                   let ty = match List.assoc_opt f fields with
                     | Some t -> t | None -> num in
                   (f, ty,
                    S.EField (S.EVar ("__view_s", loc), f, loc))
               | S.VShowAs (f, e) -> (f, num, rewrite_view_fields fields e)
             ) vd.S.vw_items in
             let synth_place : S.place_decl = {
               S.pd_name = vd.S.vw_name;
               pd_world = world;
               pd_with_effects = false;
               pd_members = List.map (fun (f, ty, _) ->
                 S.FoField { S.fd_name = f; fd_ty = ty; fd_loc = loc }) shown;
               pd_over = None;
               pd_laws = [];
               pd_subcontains = None;
               pd_is_error = false;
               pd_on_error = None;
               pd_loc = loc } in
             let assigns = List.map (fun (f, _, e) ->
               { S.fa_name = f; fa_value = e; fa_loc = loc }) shown in
             let synth_fun : S.fun_decl = {
               S.fn_name = vd.S.vw_name;
               fn_type_params = [];
               fn_params = [ { S.param_name = "__view_s";
                               param_ty = S.TyUser vd.S.vw_of } ];
               fn_return = Some (S.TyUser vd.S.vw_name);
               fn_visits = [];
               fn_partial = false;
               fn_internal = false;
               fn_body = [ S.SReturn
                 (S.ENew (vd.S.vw_name, assigns, loc), loc) ];
               fn_loc = loc } in
             [S.TopView vd; S.TopPlace synth_place; S.TopFun synth_fun])
    | d -> [d]) p

let () = produce_block_ref := desugar_produce_block
let () = spawn_block_ref := desugar_spawn_block

let desugar_program ?(env : Tyenv.env option = None)
    ?(place_to_space : (string * string) list = []) (p : S.program) : desugar_result =
  (* The optional [env] is the typed environment from Tycheck (cr_env). The
     terminal absorber (B.3) consults it to collapse a pure, terminal-returning
     function body to the unique inhabitant `()`. When None the absorber stays
     inert, so behavior is identical to before. *)
  let p = Method_sugar.normalize_program p in  (* method-call sugar; idempotent *)
  current_env := env;
  (* Pre-rewriting that propagates tp_at_space to the `new P { ... }`
   * expressions inside functions. *)
  reset_synth ();  (* reset the accumulator of handle lambdas *)
  (* The place->space membership for the at_space routing. In project mode the
     driver passes it from the filesystem census (a place lives in the Space of
     its directory, ul_space): the single source of truth, read directly, never
     laundered through tp_objects (which assign_topos_structure leaves empty on
     purpose to avoid double registration). The tp_objects-derived map remains as
     the fallback for callers with no census (single-file, eval, fuzz): there it
     is empty and the rewrite is a no-op, which is correct because without a
     project there is no Space directory to route to. *)
  let place_to_space =
    match place_to_space with
    | [] -> build_place_to_space_map p
    | m -> m
  in
  let p = List.map (rewrite_top_decl place_to_space) p in
  let p = expand_views p in
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
   *     be lhs holds <eta>__<obj>(F__N(input))
   *     be rhs holds G__N(<eta>__<obj>(input))
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
   *     be i0 holds __check_naturality_<η>__<N>(seed)
   *     be i1 holds __check_naturality_<η>__<N>(seed + 1)
   *     be i2 holds __check_naturality_<η>__<N>(seed * 2)
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
  (* Traversata ESAUSTIVA su expr/stmt: true se `pred` vale su QUALSIASI
   * sotto-espressione, ovunque — dentro loop, when, lambda, produce, spawn,
   * scope, condizioni. Sostituisce i due walker parziali che saltavano il
   * controllo di flusso e gli expr annidati (bug confermato: `floor`/synth
   * builtin dentro un loop non veniva rilevato → "unknown function 'floor'").
   * Niente `_ -> false`: il match è esaustivo, così l'aggiunta di un nuovo
   * costruttore in surface_ast forza un aggiornamento qui invece di reintrodurre
   * silenziosamente il buco. *)
  let rec expr_any (pred : S.expr -> bool) (e : S.expr) : bool =
    pred e ||
    (let go = expr_any pred in
     match e with
     | S.ELit _ | S.EVar _ | S.EWireTo _ | S.EPullback _ | S.EPushout _ -> false
     | S.EField (e,_,_) | S.EParen (e,_) | S.ENot (e,_) | S.ERefl (e,_)
     | S.EFst (e,_) | S.ESnd (e,_) | S.EPathAbs (_,e,_) | S.EPathApp (e,_,_)
     | S.EIn (e,_,_) | S.EQuote (_,e,_) | S.ELam (_,e,_)
     | S.EMoveLam (_,e,_,_,_) | S.EReductionLam (_,e,_,_)
     | S.EMorphLam (_,e,_,_,_) | S.EFunctorLam (_,e,_,_,_,_)
     | S.EViewLam (_,e,_,_) -> go e
     | S.ECall (_,args,_) | S.EHITConstr (_,args,_) -> List.exists go args
     | S.EApp (h,args,_) -> go h || List.exists go args
     | S.EBinop (_,a,b,_) | S.EPair (a,b,_) | S.EComposeWith (a,b,_)
     | S.EPullbackVal (_,_,a,b,_) -> go a || go b
     | S.EJ (a,b,c,_) | S.EElMatch (a,b,c,_) | S.EIfThenElse (a,b,c,_) ->
         go a || go b || go c
     | S.EHITElim (scrut, branches, last, _) ->
         go scrut || List.exists (fun (_,_,be) -> go be) branches || go last
     | S.EProduce (ss,_) -> stmts_any pred ss
     | S.ESpawn (eo, ss, _) ->
         (match eo with Some e -> go e | None -> false) || stmts_any pred ss
     | S.ENew (_, fas, _) | S.ENewIn (_,_,fas,_) ->
         List.exists (fun fa -> go fa.S.fa_value) fas
     | S.EAll (_, c, _) -> cond_any pred c)
  and cond_any (pred : S.expr -> bool) (c : S.condition) : bool =
    match c with
    | S.CondExpr e | S.CondIs (e,_) | S.CondIsNot (e,_) -> expr_any pred e
    | S.CondAnd (a,b) | S.CondOr (a,b) -> cond_any pred a || cond_any pred b
  and stmt_any (pred : S.expr -> bool) (s : S.stmt) : bool =
    let go = expr_any pred in
    let gos = stmts_any pred in
    match s with
    | S.SLet (_,e,_) | S.SReturn (e,_) | S.SEmit (e,_) | S.SPromote (e,_)
    | S.SAssignHolds (_,e,_) | S.SAssignBecomes (_,e,_) -> go e
    | S.SCall (_,args,_) -> List.exists go args
    | S.SNew (_, fas, _) | S.SNewIn (_,_,fas,_) ->
        List.exists (fun fa -> go fa.S.fa_value) fas
    | S.SWhen (c, ss, branches, oth, _) ->
        cond_any pred c || gos ss
        || List.exists (fun (c2, ss2) -> cond_any pred c2 || gos ss2) branches
        || (match oth with Some ss3 -> gos ss3 | None -> false)
    | S.SForEvery (_,_, e, ss, _) | S.SInSequence (_, e, ss, _)
    | S.SIter (e, ss, _) | S.SWhile (e, ss, _) -> go e || gos ss
    | S.SRepeat (_, ss, oth, _) ->
        gos ss || (match oth with Some s2 -> gos s2 | None -> false)
    | S.SForever (ss,_) | S.SProduce (ss,_) -> gos ss
    | S.SScope (_, ss, e, _) -> gos ss || go e
    | S.SForces (_, c, ss, _) -> cond_any pred c || gos ss
    | S.SDrop _ -> false
  and stmts_any (pred : S.expr -> bool) (ss : S.stmt list) : bool =
    List.exists (stmt_any pred) ss
  in
  let fn_body_any (pred : S.expr -> bool) (fd : S.fun_decl) : bool =
    stmts_any pred fd.S.fn_body
  in
  let pred_pb = function
    | S.EPullbackVal _ -> true
    | S.ECall ("__pullback_pack", _, _) -> true
    | _ -> false
  in
  let needs_pullback_builtins =
    List.exists (function S.TopFun fd -> fn_body_any pred_pb fd | _ -> false) p
  in
  (* Detection of shift/floor/pow2 builtins: cerca call a `floor`/`__shl`/
   * `__shr`/`__pow2` ovunque nel corpo (loop/when/lambda inclusi). *)
  let prog_uses_name (name : string) : bool =
    let pred = function S.ECall (n,_,_) when n = name -> true | _ -> false in
    List.exists (function S.TopFun fd -> fn_body_any pred fd | _ -> false) p
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
    | C.Scope (_, b) | C.Emit b
    | C.Fst b | C.Snd b | C.Refl b -> free_names acc b
    | C.Pair (a, b) | C.StreamCons (a, b) -> free_names (free_names acc a) b
    | C.J (_, _, a, b, c, d) ->
        free_names (free_names (free_names (free_names acc a) b) c) d
    | C.Place _ | C.Reduction _ | C.World _ | C.Unit -> acc
    | C.PLam (_, b) -> free_names acc b
    | C.PApp (p, _) -> free_names acc p
    | C.Transp (_, b) -> free_names acc b
    | C.Comp (_, _, sides, base) | C.HComp (_, _, sides, base) ->
        List.fold_left (fun a (_, _, t) -> free_names a t) (free_names acc base) sides
    | C.GlueElem (_, t, a) -> free_names (free_names acc t) a
    | C.Unglue t -> free_names acc t
    | C.HITElim (branches, scrut) ->
        List.fold_left
          (fun acc (_, vars, b) ->
             let inner = free_names [] b in
             List.fold_left
               (fun a n ->
                  if List.mem n vars || List.mem n a then a else n :: a)
               acc inner)
          (free_names acc scrut) branches
    | C.HITConstr (_, args) -> List.fold_left free_names acc args
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
             else C.App (C.Lam (name, C.TyPlace "fun", body), fn_term))
          main_body
          res.functions
      in
      { res with main = Some wrapped }
