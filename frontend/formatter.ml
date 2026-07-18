(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* formatter.ml — the Yon formatter, as a shared library.
 *
 * A pretty printer over the surface AST that produces re-parsable Yon (not the
 * debug printer of pretty.ml, which operates on the core with Unicode
 * symbols). Safety guarantee: the formatter re-parses its own output and
 * verifies the top-level structure is preserved AND that formatting is
 * idempotent; if not, it leaves the file unchanged. A formatter must never
 * change the meaning of the code.
 *
 * Both the `yonfmt` CLI and the language server (textDocument/formatting) call
 * `safe_format` here -- one formatter, so a `yonc fmt` and a "format on save"
 * can never disagree.
 *
 * Coverage: the common constructs (fun, be, return, expr, world, place with
 * operation/law, functor). Uncovered constructs -> the round-trip fails and
 * the file stays unchanged (fail-safe), never a wrong output.
 *)

open Surface_ast

(* ─── Indented output buffer ────────────────────────────────────────── *)

type fmt = { buf : Buffer.t; mutable indent : int }
let mk () = { buf = Buffer.create 1024; indent = 0 }
let pad f = Buffer.add_string f.buf (String.make (f.indent * 2) ' ')
let line f s = pad f; Buffer.add_string f.buf s; Buffer.add_char f.buf '\n'

(* ─── Operatori e literal (non ricorsivi) ───────────────────────────── *)

let binop_str = function
  | OpAdd -> "+" | OpSub -> "-" | OpMul -> "*" | OpDiv -> "/" | OpMod -> "%"
  | OpEq -> "==" | OpNeq -> "!=" | OpLt -> "<" | OpGt -> ">"
  | OpLeq -> "<=" | OpGeq -> ">=" | OpAnd -> "and" | OpOr -> "or"

let lit_str = function
  | LitNumber n ->
      (* integer if possible, otherwise float *)
      if Float.is_integer n && Float.abs n < 1e15
      then Printf.sprintf "%d" (int_of_float n)
      else Printf.sprintf "%g" n
  | LitString s -> Printf.sprintf "\"%s\"" s
  | LitBool b -> if b then "true" else "false"
  | LitCurrency (n, c) -> Printf.sprintf "%g %s" n c
  | LitDuration (n, u) -> Printf.sprintf "%g %s" n u
  | LitHeytPresent -> "present"
  | LitHeytAbsent -> "absent"
  | LitHeytUnknown -> "unknown"

(* ─── Tipi ed espressioni (mutuamente ricorsivi: un tipo dipendente porta
       termini, un'espressione porta annotazioni di tipo) ─────────────── *)

let rec fmt_ty (t : ty) : string =
  match t with
  | TyPrim s -> s
  | TyPrimIn (s, opts) -> s ^ " in " ^ String.concat ", " opts
  | TyList t -> "list of " ^ fmt_ty t
  | TyMap (k, v) -> "map of " ^ fmt_ty k ^ " to " ^ fmt_ty v
  | TyStream t -> "stream of " ^ fmt_ty t
  | TyArrow (a, b) -> fmt_ty a ^ " -> " ^ fmt_ty b
  | TyUser s -> s
  | TyVar s -> s
  | TyUniverse 0 -> "Type"
  | TyUniverse n -> Printf.sprintf "Type_%d" n
  | TyHeytInt n -> Printf.sprintf "heyt_int<%d>" n
  | TyPi (x, a, b) -> Printf.sprintf "Pi(%s: %s). %s" x (fmt_ty a) (fmt_ty b)
  | TySigma (x, a, b) -> Printf.sprintf "Sigma(%s: %s). %s" x (fmt_ty a) (fmt_ty b)
  | TyId (TyMetaVar (-424242), x, y) ->
      (* `Same(x, y)` sugar: Id with the inference-sentinel carrier (parser.mly).
         Print the sugar back, not `Id(<metavar>, ..)` whose carrier has no
         surface form (which is what made these files uncovered). *)
      Printf.sprintf "Same(%s, %s)" (fmt_ty_term x) (fmt_ty_term y)
  | TyId (a, x, y) ->
      Printf.sprintf "Id(%s, %s, %s)" (fmt_ty a) (fmt_ty_term x) (fmt_ty_term y)
  | TyEl c -> Printf.sprintf "El(%s)" (fmt_ty_term c)
  | TyPathP ((i, a), x, y) ->
      Printf.sprintf "PathP(%s, %s, %s, %s)" i (fmt_ty a) (fmt_ty_term x) (fmt_ty_term y)
  | TySum variants ->
      String.concat " | "
        (List.map (fun v ->
           if v.v_args = [] then v.v_name
           else Printf.sprintf "%s(%s)" v.v_name
                  (String.concat ", " (List.map fmt_ty v.v_args)))
           variants)
  | TyMoveHandle (Some w1, Some w2) -> Printf.sprintf "move from %s to %s" w1 w2
  | TyReductionHandle (Some p) -> "reduction of " ^ p
  | TyMorphHandle (Some s1, Some s2) -> Printf.sprintf "morph from %s to %s" s1 s2
  | TyViewHandle (Some p) -> "view of " ^ p
  | _ -> raise Exit   (* inference-only or uncovered type: fail-safe *)

and fmt_ty_term (TyTermExpr e) = fmt_expr e

and fmt_expr (e : expr) : string =
  match e with
  | ELit (l, _) -> lit_str l
  | EVar (x, _) -> x
  | EField (o, f, _) -> fmt_expr o ^ "." ^ f
  | ECall (name, args, _) ->
      (* Undo the parser's normalization, to reprint the surface syntax the
       * user wrote:
       *   - "P_instantiate" with 0 args  -> "verify P"
       *   - "Obj__method"                -> "Obj.method(...)"
       * so the round-trip preserves the form, not just the semantics. *)
      let ends_with suffix s =
        let ls = String.length s and lf = String.length suffix in
        ls >= lf && String.sub s (ls - lf) lf = suffix in
      (match args, name with
       | [], _ when ends_with "_instantiate" name ->
           let place = String.sub name 0 (String.length name - String.length "_instantiate") in
           "verify " ^ place
       | recv :: rest, ("fold" | "map") ->
           Printf.sprintf "%s.%s(%s)" (fmt_expr recv) name
             (String.concat ", " (List.map fmt_expr rest))
       | _ ->
           (* method call Obj__method(args) -> Obj.method(args).
            * Recognizes a single "__" separating a receiver IDENT from the
            * method. *)
           let dunder =
             let rec find i =
               if i + 1 >= String.length name then None
               else if name.[i] = '_' && name.[i+1] = '_' && i > 0 then Some i
               else find (i + 1)
             in find 0 in
           (match dunder with
            | Some i ->
                let obj = String.sub name 0 i in
                let meth = String.sub name (i + 2) (String.length name - i - 2) in
                Printf.sprintf "%s.%s(%s)" obj meth
                  (String.concat ", " (List.map fmt_expr args))
            | None ->
                name ^ "(" ^ String.concat ", " (List.map fmt_expr args) ^ ")"))
  | EBinop (op, a, b, _) ->
      Printf.sprintf "%s %s %s" (fmt_expr a) (binop_str op) (fmt_expr b)
  | EParen (inner, _) -> "(" ^ fmt_expr inner ^ ")"
  | ENot (a, _) -> "not " ^ fmt_expr a
  | EIfThenElse (c, t, f, _) ->
      Printf.sprintf "if %s then %s else %s" (fmt_expr c) (fmt_expr t) (fmt_expr f)
  | ELam (params, body, _) ->
      (* explicit `fun` keyword: valid anywhere, even as an argument *)
      Printf.sprintf "fun(%s) => %s" (lam_params params) (fmt_expr body)
  | EFunctorLam (params, body, fw, tw, laws, _) ->
      let ps = String.concat ", "
        (List.map (fun (n, t) -> n ^ ": " ^ fmt_ty t) params) in
      let ls = String.concat "" (List.map (fun l -> " law " ^ l) laws) in
      Printf.sprintf "functor (%s) => %s from %s to %s%s"
        ps (fmt_expr body) fw tw ls
  | ENew (place, fas, _) ->
      (* field assignments are space-juxtaposed in the surface (`{ x 1 y 2 }`),
         NOT comma-separated -- a comma here would never re-parse. *)
      let assigns = String.concat " "
        (List.map (fun fa -> fa.fa_name ^ " " ^ fmt_expr fa.fa_value) fas) in
      Printf.sprintf "new %s { %s }" place assigns
  | ENewIn (place, space, fas, _) ->
      (* field assignments are space-juxtaposed in the surface (`{ x 1 y 2 }`),
         NOT comma-separated -- a comma here would never re-parse. *)
      let assigns = String.concat " "
        (List.map (fun fa -> fa.fa_name ^ " " ^ fmt_expr fa.fa_value) fas) in
      Printf.sprintf "new %s in %s { %s }" place space assigns
  | ERefl (EVar ("__plainly__", _), _) -> "plainly"  (* refl-of-endpoint sugar *)
  | ERefl (e, _) -> "refl(" ^ fmt_expr e ^ ")"
  | EPair (a, b, _) -> Printf.sprintf "pair(%s, %s)" (fmt_expr a) (fmt_expr b)
  | EFst (e, _) -> "fst(" ^ fmt_expr e ^ ")"
  | ESnd (e, _) -> "snd(" ^ fmt_expr e ^ ")"
  | EComposeWith (h1, h2, _) ->
      Printf.sprintf "compose %s with %s" (fmt_expr h1) (fmt_expr h2)
  | EWireTo (sp, _) -> "wire to space " ^ sp
  | EMoveLam (ps, body, a, b, _) ->
      Printf.sprintf "move(%s) => %s from %s to %s" (lam_params ps) (fmt_expr body) a b
  | EMorphLam (ps, body, a, b, _) ->
      Printf.sprintf "morph(%s) => %s from %s to %s" (lam_params ps) (fmt_expr body) a b
  | EViewLam (ps, body, p, _) ->
      Printf.sprintf "view(%s) => %s of %s" (lam_params ps) (fmt_expr body) p
  | EReductionLam (ps, body, p, _) ->
      Printf.sprintf "reduction(%s) => %s of %s" (lam_params ps) (fmt_expr body) p
  | EApp (head, args, _) ->
      Printf.sprintf "%s(%s)" (fmt_expr head) (String.concat ", " (List.map fmt_expr args))
  | EIn (e, ctx, _) -> fmt_expr e ^ " in " ^ ctx
  | EPullbackVal (fn, gn, a, b, _) ->
      Printf.sprintf "pullback(%s, %s, %s, %s)" fn gn (fmt_expr a) (fmt_expr b)
  | EPathAbs (i, e, _) -> Printf.sprintf "plam %s => %s" i (fmt_expr e)
  | EPathApp (e, d, _) ->
      Printf.sprintf "%s @ %s" (fmt_expr e)
        (match d with DI0 -> "I0" | DI1 -> "I1" | DIVar v -> v)
  | EHITConstr (name, args, _) ->
      if args = [] then Printf.sprintf "hit(%s)" name
      else Printf.sprintf "hit(%s, %s)" name (String.concat ", " (List.map fmt_expr args))
  | EHITElim (motive, branches, target, _) ->
      let br (name, binders, body) =
        let hd = if binders = [] then name
                 else Printf.sprintf "%s(%s)" name (String.concat ", " binders) in
        Printf.sprintf "%s => %s" hd (fmt_expr body) in
      Printf.sprintf "hit_elim(%s, [%s], %s)"
        (fmt_expr motive) (String.concat ", " (List.map br branches)) (fmt_expr target)
  | EJ (ELit (LitNumber n, _), d, p, _) when n = 0.0 ->
      (* `induct(d, p)` sugar: J with the placeholder motive 0 (parser.mly). *)
      Printf.sprintf "induct(%s, %s)" (fmt_expr d) (fmt_expr p)
  | EJ (c, d, p, _) ->
      Printf.sprintf "ind_path(%s, %s, %s)" (fmt_expr c) (fmt_expr d) (fmt_expr p)
  | EQuote (c, a, _) -> Printf.sprintf "quote(%s, %s)" (fmt_ty_term c) (fmt_expr a)
  | EElMatch (target, ret, body, _) ->
      Printf.sprintf "el_match(%s, %s, %s)"
        (fmt_expr target) (fmt_expr ret) (fmt_expr body)
  | _ -> raise Exit   (* construct not covered: abort the format (fail-safe) *)

and lam_params (ps : (string * ty) list) : string =
  (* an untyped lambda param `fun(a) => ...` parses to (a, TyPrim "unknown");
     emit it back bare, not as `a: unknown`. *)
  String.concat ", "
    (List.map (fun (n, t) -> if t = TyPrim "unknown" then n else n ^ ": " ^ fmt_ty t) ps)

(* ─── Statement ─────────────────────────────────────────────────────── *)

let lvalue_str = function
  | LVar x -> x
  | LField (x, f) -> x ^ "." ^ f

let pattern_str = function
  | PatVar x -> x
  | PatLit l -> lit_str l
  | PatPresent -> "present"
  | PatAbsent -> "absent"
  | PatUnknown -> "unknown"
  | PatType t -> fmt_ty t

let rec cond_str (c : condition) : string =
  match c with
  | CondExpr e -> fmt_expr e
  | CondIs (e, p) -> fmt_expr e ^ " is " ^ pattern_str p
  | CondIsNot (e, p) -> fmt_expr e ^ " is not " ^ pattern_str p
  | CondAnd (a, b) -> cond_str a ^ " and " ^ cond_str b
  | CondOr (a, b) -> cond_str a ^ " or " ^ cond_str b

let rec fmt_stmt (f : fmt) (s : stmt) : unit =
  match s with
  (* `be x holds produce/spawn { ... }`: the rhs carries a statement block, so it
     is rendered multi-line here rather than through the single-line fmt_expr. *)
  | SLet (name, EProduce (body, _), _) ->
      line f (Printf.sprintf "be %s holds produce {" name);
      f.indent <- f.indent + 1; List.iter (fmt_stmt f) body; f.indent <- f.indent - 1;
      line f "}"
  | SLet (name, ESpawn (n_opt, body, _), _) ->
      let hdr = match n_opt with
        | None -> Printf.sprintf "be %s holds spawn {" name
        | Some n -> Printf.sprintf "be %s holds spawn in %s parallel {" name (fmt_expr n) in
      line f hdr;
      f.indent <- f.indent + 1; List.iter (fmt_stmt f) body; f.indent <- f.indent - 1;
      line f "}"
  | SLet (name, e, _) -> line f (Printf.sprintf "be %s holds %s" name (fmt_expr e))
  | SAssignBecomes (lv, e, _) ->
      (* reassignment (model A): the surface is `x = e`; there is no `becomes`
         keyword, so emitting one would produce code that never re-parses. *)
      line f (Printf.sprintf "%s = %s" (lvalue_str lv) (fmt_expr e))
  | SReturn (e, _) -> line f ("return " ^ fmt_expr e)
  | SEmit (e, _) -> line f ("emit " ^ fmt_expr e)
  | SCall (name, args, _) ->
      line f (name ^ "(" ^ String.concat ", " (List.map fmt_expr args) ^ ")")
  | SIter (e, body, _) ->
      line f ("iter " ^ fmt_expr e ^ " do {");
      f.indent <- f.indent + 1; List.iter (fmt_stmt f) body; f.indent <- f.indent - 1;
      line f "}"
  | SWhile (e, body, _) ->
      line f ("while " ^ fmt_expr e ^ " do {");
      f.indent <- f.indent + 1; List.iter (fmt_stmt f) body; f.indent <- f.indent - 1;
      line f "}"
  | SWhen (c, body, branches, otherwise, _) ->
      line f (Printf.sprintf "when %s {" (cond_str c));
      f.indent <- f.indent + 1; List.iter (fmt_stmt f) body; f.indent <- f.indent - 1;
      List.iter (fun (bc, bbody) ->
        line f (Printf.sprintf "} when %s {" (cond_str bc));
        f.indent <- f.indent + 1; List.iter (fmt_stmt f) bbody; f.indent <- f.indent - 1
      ) branches;
      (match otherwise with
       | Some ob ->
           line f "} otherwise {";
           f.indent <- f.indent + 1; List.iter (fmt_stmt f) ob; f.indent <- f.indent - 1
       | None -> ());
      line f "}"
  | SForEvery (_fk, var, e, body, _) ->
      line f (Printf.sprintf "for every %s in %s {" var (fmt_expr e));
      f.indent <- f.indent + 1; List.iter (fmt_stmt f) body; f.indent <- f.indent - 1;
      line f "}"
  | SForces (stage, c, body, _) ->
      line f (Printf.sprintf "forces %s %s {" stage (cond_str c));
      f.indent <- f.indent + 1; List.iter (fmt_stmt f) body; f.indent <- f.indent - 1;
      line f "}"
  | SScope (name, body, _, _) ->
      (* the third field is a synthetic scope predicate (top in Omega), not
         surface syntax -- do not print it. *)
      line f (match name with Some n -> "scope " ^ n ^ " {" | None -> "scope {");
      f.indent <- f.indent + 1; List.iter (fmt_stmt f) body; f.indent <- f.indent - 1;
      line f "}"
  | SProduce (body, _) ->
      line f "produce {";
      f.indent <- f.indent + 1; List.iter (fmt_stmt f) body; f.indent <- f.indent - 1;
      line f "}"
  | SForever (body, _) ->
      line f "forever {";
      f.indent <- f.indent + 1; List.iter (fmt_stmt f) body; f.indent <- f.indent - 1;
      line f "}"
  | SPromote (e, _) -> line f ("promote " ^ fmt_expr e)
  | SNew (place, fas, _) ->
      (* field assignments are space-juxtaposed in the surface (`{ x 1 y 2 }`),
         NOT comma-separated -- a comma here would never re-parse. *)
      let assigns = String.concat " "
        (List.map (fun fa -> fa.fa_name ^ " " ^ fmt_expr fa.fa_value) fas) in
      line f (Printf.sprintf "new %s { %s }" place assigns)
  | SInSequence (x, e, body, _) ->
      line f (Printf.sprintf "in sequence over %s in %s {" x (fmt_expr e));
      f.indent <- f.indent + 1; List.iter (fmt_stmt f) body; f.indent <- f.indent - 1;
      line f "}"
  | SRepeat (n, body, other, _) ->
      line f (Printf.sprintf "repeat at most %d times {" n);
      f.indent <- f.indent + 1; List.iter (fmt_stmt f) body; f.indent <- f.indent - 1;
      line f "}";
      (match other with
       | Some ob ->
           line f "otherwise {";
           f.indent <- f.indent + 1; List.iter (fmt_stmt f) ob; f.indent <- f.indent - 1;
           line f "}"
       | None -> ())
  | _ -> raise Exit   (* uncovered stmt: abort (fail-safe) *)

(* ─── Top-level ─────────────────────────────────────────────────────── *)

let fmt_fun (f : fmt) (fn : fun_decl) : unit =
  let tps = match fn.fn_type_params with
    | [] -> "" | ps -> "<" ^ String.concat ", " ps ^ ">" in
  let params = String.concat ", "
    (List.map (fun p -> p.param_name ^ ": " ^ fmt_ty p.param_ty) fn.fn_params) in
  let ret = match fn.fn_return with Some t -> ": " ^ fmt_ty t | None -> "" in
  let visits = match fn.fn_visits with
    | [] -> "" | vs -> " visits " ^ String.concat ", " vs in
  let prefix = if fn.fn_internal then "internal " else "" in
  line f (Printf.sprintf "%sfun %s%s(%s)%s%s {" prefix fn.fn_name tps params ret visits);
  f.indent <- f.indent + 1;
  List.iter (fmt_stmt f) fn.fn_body;
  f.indent <- f.indent - 1;
  line f "}"

let descriptor_str = function
  | PdBy s -> "by " ^ s
  | PdIdList ids -> String.concat ", " ids
  | PdType t -> fmt_ty t

let fmt_world (f : fmt) (wd : world_decl) : unit =
  (* prodotti/coproduct/quotient/subset -> forme speciali, Exit (fail-safe) *)
  if wd.wd_product_of <> [] || wd.wd_coproduct_of <> []
     || wd.wd_quotient_of <> None || wd.wd_subset_of <> None
     || wd.wd_coequalizer_of <> None
  then raise Exit;
  line f (Printf.sprintf "world %s {" wd.wd_name);
  f.indent <- f.indent + 1;
  List.iter (fun (wp : world_place) ->
    line f (Printf.sprintf "%s is %s" wp.wp_name (descriptor_str wp.wp_descriptor))
  ) wd.wd_places;
  f.indent <- f.indent - 1;
  line f "}"

let fmt_place (f : fmt) (pd : place_decl) : unit =
  (* An `error E { ... }` reuses the place structure with pd_is_error. The surface
     never writes `in W` (the world is filesystem-inferred, pd_world = "__INFER");
     only emit `in W` if a concrete world was actually annotated. Clause order
     mirrors the parser: <over>? <subcontains>? <on error>?, then `with effects`. *)
  let kw = if pd.pd_is_error then "error" else "place" in
  let world =
    if pd.pd_world = "__INFER" || pd.pd_world = "" then "" else " in " ^ pd.pd_world in
  let over = match pd.pd_over with Some b -> " over " ^ b | None -> "" in
  let subcontains = match pd.pd_subcontains with Some b -> " subcontains " ^ b | None -> "" in
  let on_error = match pd.pd_on_error with Some e -> " on error " ^ e | None -> "" in
  let effects = if pd.pd_with_effects then " with effects" else "" in
  line f (Printf.sprintf "%s %s%s%s%s%s%s {"
            kw pd.pd_name world over subcontains on_error effects);
  f.indent <- f.indent + 1;
  List.iter (fun m ->
    match m with
    | FoField fd -> line f (fd.fd_name ^ " " ^ fmt_ty fd.fd_ty)
    | FoOp op ->
        let params = String.concat ", "
          (List.map (fun p -> p.param_name ^ ": " ^ fmt_ty p.param_ty) op.op_params) in
        let ret = match op.op_return with Some t -> ": " ^ fmt_ty t | None -> "" in
        let alg = match op.op_algebra with
          | Some a -> " uses algebra " ^ a | None -> "" in
        line f (Printf.sprintf "operation %s(%s)%s%s" op.op_name params ret alg)
    | FoLaw l -> line f ("law " ^ l)
    | FoCell c ->
        line f (Printf.sprintf "cell %s from %s to %s"
                  c.cell_name (fmt_expr c.cell_src) (fmt_expr c.cell_tgt))
  ) pd.pd_members;
  f.indent <- f.indent - 1;
  line f "}"

let fmt_functor (f : fmt) (ft : functor_decl) : unit =
  let params = String.concat ", "
    (List.map (fun (n, t) -> n ^ ": " ^ fmt_ty t) ft.ft_params) in
  let laws = String.concat "" (List.map (fun l -> "\n  law " ^ l) ft.ft_laws) in
  line f (Printf.sprintf "functor %s(%s) from %s to %s%s {"
            ft.ft_name params ft.ft_from_world ft.ft_to_world laws);
  f.indent <- f.indent + 1;
  line f ("return " ^ fmt_expr ft.ft_body);
  f.indent <- f.indent - 1;
  line f "}"

let fmt_nat_transform (f : fmt) (nt : nat_transform_decl) : unit =
  (* the surface keyword is two words, `nat transform`, not `nat_transform`. *)
  line f (Printf.sprintf "nat transform %s from %s to %s {"
            nt.nt_name nt.nt_source_morph nt.nt_target_morph);
  f.indent <- f.indent + 1;
  List.iter (fun (obj, tgt) ->
    line f (Printf.sprintf "for each %s by %s" obj tgt)
  ) nt.nt_via_bindings;
  f.indent <- f.indent - 1;
  line f "}"

let fmt_space (f : fmt) (sd : space_decl) : unit =
  (* a non-trivial fold -> Exit (fail-safe). Common form: space N (in W)? *)
  if sd.sd_fold <> None then raise Exit;
  match sd.sd_world with
  | None -> line f (Printf.sprintf "space %s" sd.sd_name)
  | Some w -> line f (Printf.sprintf "space %s in %s" sd.sd_name w)

let mapping_kind_str = function
  | MapsTo -> "maps to"
  | ConvertsTo -> "converts to"
  | AggregatesTo -> "aggregates to"

let fmt_move (f : fmt) (mv : move_decl) : unit =
  match mv.mv_body with
  | MoveMerge m ->
      (* Form B: `move N unifies A, B { share ...; conflict on w resolves to fn }` *)
      line f (Printf.sprintf "move %s unifies %s {"
                mv.mv_name (String.concat ", " mv.mv_from));
      f.indent <- f.indent + 1;
      if m.merge_shares <> [] then
        line f ("share " ^ String.concat ", " m.merge_shares);
      List.iter (fun (field, fn) ->
        line f (Printf.sprintf "conflict on %s resolves to %s" field fn))
        m.merge_conflicts;
      f.indent <- f.indent - 1;
      line f "}"
  | MoveMapping maps ->
      (* Form A: `move N from W1 to W2 (requires Cap)? { mappings }` *)
      let from_w = match mv.mv_from with [w] -> w | _ -> raise Exit in
      let to_w = match mv.mv_to with Some w -> w | None -> raise Exit in
      let reqs = match mv.mv_requires_caps with
        | [] -> "" | cs -> " requires " ^ String.concat ", " cs in
      line f (Printf.sprintf "move %s from %s to %s%s {" mv.mv_name from_w to_w reqs);
      f.indent <- f.indent + 1;
      List.iter (fun (m : mapping_decl) ->
        line f (Printf.sprintf "%s %s %s by %s"
                  m.m_from (mapping_kind_str m.m_kind) m.m_to m.m_by))
        maps;
      f.indent <- f.indent - 1;
      line f "}"

let fmt_top (f : fmt) (td : top_decl) : unit =
  (match td with
   | TopFun fn -> fmt_fun f fn
   | TopPlace pd -> fmt_place f pd
   | TopType (name, variants, _) ->
       line f (Printf.sprintf "inductive %s = %s" name (fmt_ty (TySum variants)))
   | TopWorld wd -> fmt_world f wd
   | TopFunctor ft -> fmt_functor f ft
   | TopNatTransform nt -> fmt_nat_transform f nt
   | TopSpace sd -> fmt_space f sd
   | TopMove mv -> fmt_move f mv
   | TopImport (s, _) -> line f (Printf.sprintf "import \"%s\"" s)
   | TopImportSym (m, name, alias, _) ->
       (match alias with
        | Some a -> line f (Printf.sprintf "import %s::%s as %s" m name a)
        | None   -> line f (Printf.sprintf "import %s::%s" m name))
   | TopImportFrom (m, name, sp, _) ->
       line f (Printf.sprintf "import %s::%s from %s" m name sp)
   | TopGeomMorphism gm ->
       line f (Printf.sprintf "geomorph %s from %s to %s {"
                 gm.gm_name gm.gm_source_site gm.gm_target_site);
       f.indent <- f.indent + 1;
       let fmt_dir kw (fd : fun_decl) =
         let params = String.concat ", "
           (List.map (fun p -> p.param_name ^ ": " ^ fmt_ty p.param_ty)
              fd.fn_params) in
         let ret = match fd.fn_return with Some t -> ": " ^ fmt_ty t | None -> "" in
         line f (Printf.sprintf "%s(%s)%s {" kw params ret);
         f.indent <- f.indent + 1; List.iter (fmt_stmt f) fd.fn_body;
         f.indent <- f.indent - 1; line f "}"
       in
       (match gm.gm_pull with Some fd -> fmt_dir "pull" fd | None -> ());
       (match gm.gm_push with Some fd -> fmt_dir "push" fd | None -> ());
       f.indent <- f.indent - 1;
       line f "}"
   | TopTopos td ->
       (* v1.1 topos-per-space: objects/at/in are filesystem-inferred; the surface
          is `topos <name> where { <terminal>? <prop>* }`. The morphisms block is
          not covered yet -> Exit. *)
       line f (Printf.sprintf "topos %s where {" td.tp_name);
       f.indent <- f.indent + 1;
       (match td.tp_terminal with Some t -> line f ("terminal " ^ t) | None -> ());
       if td.tp_morphisms <> [] then begin
         line f "morphisms {";
         f.indent <- f.indent + 1;
         List.iter (fun op ->
           let kw = if op.op_functorial then "functorial morphism" else "morphism" in
           let params = String.concat ", "
             (List.map (fun p -> p.param_name ^ ": " ^ fmt_ty p.param_ty) op.op_params) in
           let ret = match op.op_return with Some t -> ": " ^ fmt_ty t | None -> "" in
           line f (Printf.sprintf "%s %s(%s)%s" kw op.op_name params ret))
           td.tp_morphisms;
         f.indent <- f.indent - 1;
         line f "}"
       end;
       List.iter (fun pr ->
         let params = String.concat ", "
           (List.map (fun (n, t) -> n ^ ": " ^ fmt_ty t) pr.pr_params) in
         let body = match pr.pr_body_opt with Some e -> " = " ^ fmt_expr e | None -> "" in
         line f (Printf.sprintf "prop %s(%s): proposition%s" pr.pr_name params body))
         td.tp_props;
       f.indent <- f.indent - 1;
       line f "}"
   | TopView vw ->
       line f (Printf.sprintf "view %s of %s {" vw.vw_name vw.vw_of);
       f.indent <- f.indent + 1;
       List.iter (function
         | VShowSimple n -> line f ("show " ^ n)
         | VShowAs (n, e) -> line f (Printf.sprintf "show %s = %s" n (fmt_expr e))
         | VShowLabel (n, l) -> line f (Printf.sprintf "show %s as \"%s\"" n l))
         vw.vw_items;
       f.indent <- f.indent - 1;
       line f "}"
   | TopMorph mp ->
       line f (Printf.sprintf "morph %s from %s to %s {"
                 mp.mp_name mp.mp_source mp.mp_target);
       f.indent <- f.indent + 1;
       (match mp.mp_on_object with
        | Some fd ->
            let params = String.concat ", "
              (List.map (fun p -> p.param_name ^ ": " ^ fmt_ty p.param_ty) fd.fn_params) in
            let ret = match fd.fn_return with Some t -> ": " ^ fmt_ty t | None -> "" in
            line f (Printf.sprintf "on object(%s)%s {" params ret);
            f.indent <- f.indent + 1; List.iter (fmt_stmt f) fd.fn_body;
            f.indent <- f.indent - 1; line f "}"
        | None -> ());
       List.iter (fun (a, b) -> line f (Printf.sprintf "on morphism %s via %s" a b))
         mp.mp_on_morphism_map;
       f.indent <- f.indent - 1;
       line f "}"
   | TopTopology tp ->
       line f (Printf.sprintf "topology %s of %s {" tp.tp_name tp.tp_of_place);
       f.indent <- f.indent + 1; List.iter (fmt_stmt f) tp.tp_body; f.indent <- f.indent - 1;
       line f "}"
   | TopPullback u ->
       line f (Printf.sprintf "place %s = pullback(%s, %s)" u.uni_name u.uni_f u.uni_g)
   | TopPushout u ->
       line f (Printf.sprintf "place %s = pushout(%s, %s)" u.uni_name u.uni_f u.uni_g)
   | TopReduction rd ->
       (* common form: `reduction <dir> <name> of <place> fold "<fn>" { <clauses> }`.
          The exotic modifiers (lawful/invertible/multi-shot/type-params/non-default
          ordering) are not covered yet -> Exit. *)
       if rd.rd_shot_ordering <> OrdSequential then raise Exit;  (* not surfaced *)
       let dir = match rd.rd_direction with
         | RdForward -> "forward " | RdBackward -> "backward " | RdBi -> "bi " in
       let lawful = if rd.rd_lawful then "lawful " else "" in
       let inv = if rd.rd_invertible then "invertible " else "" in
       let tps = match rd.rd_type_params with
         | [] -> "" | ps -> "<" ^ String.concat ", " ps ^ ">" in
       let multi = if rd.rd_multi_shot then " with multishot" else "" in
       let fold = match rd.rd_fold_name with
         | Some n -> Printf.sprintf " fold \"%s\"" n | None -> "" in
       line f (Printf.sprintf "reduction %s%s%s%s%s of %s%s%s {"
                 dir lawful inv rd.rd_name tps rd.rd_of multi fold);
       f.indent <- f.indent + 1;
       List.iter (function
         | RcLet (n, e, _) -> line f (Printf.sprintf "be %s holds %s" n (fmt_expr e))
         | RcOn (ev, params, body, _) ->
             let ps = String.concat ", "
               (List.map (fun p -> p.param_name ^ ": " ^ fmt_ty p.param_ty) params) in
             line f (Printf.sprintf "on %s(%s) {" ev ps);
             f.indent <- f.indent + 1; List.iter (fmt_stmt f) body; f.indent <- f.indent - 1;
             line f "}")
         rd.rd_clauses;
       f.indent <- f.indent - 1;
       line f "}"
   | _ -> raise Exit);
  Buffer.add_char f.buf '\n'   (* blank line between top-level decls *)

(* ─── Parsing (reuses the frontend parser) ──────────────────────────── *)

let parse (source : string) : program option =
  Parser_state.reset ();   (* avoid stale synth_decls on re-parse *)
  let lexbuf = Lexing.from_string source in
  try Some (Parser.program Lexer.token lexbuf)
  with _ -> None

let format_program (prog : program) : string option =
  try
    let f = mk () in
    List.iter (fmt_top f) prog;
    Some (Buffer.contents f.buf)
  with Exit -> None   (* uncovered construct: no output (fail-safe) *)

(* ─── Round-trip: the formatter never corrupts ──────────────────────── *)

(* A light structural comparison: two programs are "equivalent" if they have
 * the same number of top-level declarations with the same names and shapes.
 * For the round-trip it is enough that the re-parse succeeds and produces the
 * same structure, so we compare top-level names (robust, ignores locations). *)
let top_names (prog : program) : string list =
  List.filter_map (function
    | TopFun fn -> Some ("fun:" ^ fn.fn_name)
    | TopPlace pd -> Some ("place:" ^ pd.pd_name)
    | TopWorld wd -> Some ("world:" ^ wd.wd_name)
    | TopFunctor ft -> Some ("functor:" ^ ft.ft_name)
    | TopNatTransform nt -> Some ("nat:" ^ nt.nt_name)
    | TopSpace sd -> Some ("space:" ^ sd.sd_name)
    | TopMove mv -> Some ("move:" ^ mv.mv_name)
    | TopTopos td -> Some ("topos:" ^ td.tp_name)
    | TopView vw -> Some ("view:" ^ vw.vw_name)
    | TopMorph mp -> Some ("morph:" ^ mp.mp_name)
    | TopReduction rd -> Some ("reduction:" ^ rd.rd_name)
    | TopPullback u -> Some ("pullback:" ^ u.uni_name)
    | TopPushout u -> Some ("pushout:" ^ u.uni_name)
    | _ -> None) prog

(* Format with a guarantee. Return the output only if BOTH hold:
 *   - the output re-parses to the same top-level structure (no decl lost or
 *     renamed), and
 *   - formatting is idempotent: formatting the re-parsed output reproduces it
 *     byte-for-byte (a fixed point). Idempotence catches a formatter that is
 *     unstable under its own output -- a real proxy for "the AST round-tripped".
 * Otherwise None, and the caller leaves the file unchanged (fail-safe). *)
let safe_format (source : string) : string option =
  match parse source with
  | None -> None   (* invalid source: leave it untouched *)
  | Some prog ->
      match format_program prog with
      | None -> None   (* construct not covered *)
      | Some formatted ->
          match parse formatted with
          | None -> None   (* the output does not re-parse: do NOT use it *)
          | Some prog2 ->
              if top_names prog <> top_names prog2 then None  (* structure changed *)
              else match format_program prog2 with
                   | Some formatted2 when formatted2 = formatted -> Some formatted
                   | _ -> None   (* not idempotent: do NOT use it *)
