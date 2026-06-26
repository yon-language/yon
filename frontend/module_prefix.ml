(* module_prefix.ml — namespace prefixing for imported modules (Strato 2).
 *
 * When a package M is pulled in via `import "M"`, every top-level function it
 * defines is renamed M::f, and every *internal* call to one of M's own
 * functions is rewritten to the qualified name. Calls to names NOT defined in M
 * (builtins like Map/List/print, or names from yet another module) are left
 * untouched. The local project code (module "") is never prefixed.
 *
 * This gives every dependency its own namespace: dependency `geometria` exposes
 * `geometria::scale`, which cannot collide with the project's own `scale`.
 *)

module S = Surface_ast

let qualify (m : string) (name : string) : string = m ^ "::" ^ name

(* Collect the names of all functions defined at top level in this module's
 * declarations. Only these get prefixed (definitions and internal calls). *)
let local_fun_names (decls : S.top_decl list) : string list =
  List.filter_map (function
    | S.TopFun fn -> Some fn.S.fn_name
    | _ -> None) decls

(* ─── expression / statement rewriting ─────────────────────────────────── *)

(* rename: a name -> its possibly-qualified form (identity if not local). *)
let rec rw_expr (rename : string -> string) (e : S.expr) : S.expr =
  let r = rw_expr rename in
  match e with
  | S.ELit _ -> e
  | S.EVar (n, l) -> S.EVar (rename n, l)
  | S.EField (e1, f, l) -> S.EField (r e1, f, l)
  | S.ECall (n, args, l) -> S.ECall (rename n, List.map r args, l)
  | S.ENew (p, fas, l) -> S.ENew (p, rw_fas rename fas, l)
  | S.ENewIn (p, sp, fas, l) -> S.ENewIn (p, sp, rw_fas rename fas, l)
  | S.EBinop (op, a, b, l) -> S.EBinop (op, r a, r b, l)
  | S.EParen (e1, l) -> S.EParen (r e1, l)
  | S.EAll (_, _, _) -> e
  | S.EIn (e1, c, l) -> S.EIn (r e1, c, l)
  | S.ERefl (e1, l) -> S.ERefl (r e1, l)
  | S.EPair (a, b, l) -> S.EPair (r a, r b, l)
  | S.EFst (e1, l) -> S.EFst (r e1, l)
  | S.ESnd (e1, l) -> S.ESnd (r e1, l)
  | S.EJ (a, b, c, l) -> S.EJ (r a, r b, r c, l)
  | S.ENot (e1, l) -> S.ENot (r e1, l)
  | S.EIfThenElse (c, a, b, l) -> S.EIfThenElse (r c, r a, r b, l)
  | S.ELam (ps, body, l) -> S.ELam (ps, r body, l)
  | S.EMoveLam (ps, b, p1, p2, l) -> S.EMoveLam (ps, r b, p1, p2, l)
  | S.EReductionLam (ps, b, pl, l) -> S.EReductionLam (ps, r b, pl, l)
  | S.EMorphLam (ps, b, s1, s2, l) -> S.EMorphLam (ps, r b, s1, s2, l)
  | S.EFunctorLam (ps, b, w1, w2, laws, l) -> S.EFunctorLam (ps, r b, w1, w2, laws, l)
  | S.EViewLam (ps, b, pl, l) -> S.EViewLam (ps, r b, pl, l)
  | S.EComposeWith (a, b, l) -> S.EComposeWith (r a, r b, l)
  | S.EPullbackVal (f, g, a, b, l) -> S.EPullbackVal (f, g, r a, r b, l)
  (* Previously dropped by `_ -> e`: a call inside any of these (esp. a
   * produce/spawn EXPRESSION block or a categorical-lambda body in an imported
   * module) was left un-namespaced → wrong-target binding on collision, or the
   * `internal` visibility check was bypassed. Now exhaustive (no `_`), so a new
   * constructor forces a compile error instead of a silent leak. *)
  | S.EApp (h, args, l) -> S.EApp (r h, List.map r args, l)
  | S.EHITElim (scrut, branches, ret, l) ->
      S.EHITElim (r scrut, List.map (fun (n, vs, b) -> (n, vs, r b)) branches, r ret, l)
  | S.EHITConstr (n, args, l) -> S.EHITConstr (n, List.map r args, l)
  | S.EPathApp (e1, d, l) -> S.EPathApp (r e1, d, l)
  | S.EPathAbs (i, e1, l) -> S.EPathAbs (i, r e1, l)
  | S.EQuote (c, e1, l) -> S.EQuote (c, r e1, l)
  | S.EElMatch (t, ret, body, l) -> S.EElMatch (r t, r ret, r body, l)
  | S.EProduce (body, l) -> S.EProduce (List.map (rw_stmt rename) body, l)
  | S.ESpawn (count, body, l) ->
      S.ESpawn ((match count with Some c -> Some (r c) | None -> None),
                List.map (rw_stmt rename) body, l)
  (* Leaves / names resolved elsewhere: wire handle, pullback/pushout
   * scaffolding. (EAll is handled above.) *)
  | S.EWireTo _ | S.EPullback _ | S.EPushout _ -> e

and rw_fas rename fas =
  List.map (fun (fa : S.field_assignment) ->
    { fa with S.fa_value = rw_expr rename fa.S.fa_value }) fas

and rw_stmt (rename : string -> string) (s : S.stmt) : S.stmt =
  let re = rw_expr rename in
  let rs = List.map (rw_stmt rename) in
  match s with
  | S.SLet (x, e, l) -> S.SLet (x, re e, l)
  | S.SAssignHolds (lv, e, l) -> S.SAssignHolds (lv, re e, l)
  | S.SAssignBecomes (lv, e, l) -> S.SAssignBecomes (lv, re e, l)
  | S.SReturn (e, l) -> S.SReturn (re e, l)
  | S.SCall (n, args, l) -> S.SCall (rename n, List.map re args, l)
  | S.SNew (p, fas, l) -> S.SNew (p, rw_fas rename fas, l)
  | S.SNewIn (p, sp, fas, l) -> S.SNewIn (p, sp, rw_fas rename fas, l)
  | S.SWhen (c, body, branches, otherwise, l) ->
      S.SWhen (c, rs body,
               List.map (fun (cc, b) -> (cc, rs b)) branches,
               (match otherwise with Some o -> Some (rs o) | None -> None), l)
  | S.SForEvery (k, x, e, body, l) -> S.SForEvery (k, x, re e, rs body, l)
  | S.SInSequence (x, e, body, l) -> S.SInSequence (x, re e, rs body, l)
  | S.SRepeat (n, body, otherwise, l) ->
      S.SRepeat (n, rs body,
                 (match otherwise with Some o -> Some (rs o) | None -> None), l)
  | S.SForever (body, l) -> S.SForever (rs body, l)
  | S.SScope (so, body, e, l) -> S.SScope (so, rs body, re e, l)
  | S.SProduce (body, l) -> S.SProduce (rs body, l)
  | S.SEmit (e, l) -> S.SEmit (re e, l)
  | S.SPromote (e, l) -> S.SPromote (re e, l)
  | S.SForces (st, c, body, l) -> S.SForces (st, c, rs body, l)
  | S.SIter (e, body, l) -> S.SIter (re e, rs body, l)
  | S.SWhile (e, body, l) -> S.SWhile (re e, rs body, l)

(* ─── top-level ────────────────────────────────────────────────────────── *)

(* Names declared `internal` in a module are NOT exported. We collect their
 * qualified form so an external reference can be rejected (visibility check). *)
let internal_qualified_names (modname : string) (decls : S.top_decl list) : string list =
  List.filter_map (function
    | S.TopFun fn when fn.S.fn_internal -> Some (qualify modname fn.S.fn_name)
    | _ -> None) decls

(* Visibility check: collect every qualified name referenced in a function body
 * that belongs to a DIFFERENT module, and reject it if it is internal. A
 * reference belongs to module M if it has the form "M::...". A function defined
 * in module M (its own name starts with "M::") may freely use M's internals. *)
let module_of (qname : string) : string option =
  match List.rev (Str.split_delim (Str.regexp_string "::") qname) with
  | _ :: (_ :: _ as rest) -> Some (String.concat "::" (List.rev rest))
  | _ -> None

let rec refs_in_expr (e : S.expr) : string list =
  let r = refs_in_expr in
  match e with
  | S.EVar (n, _) -> if String.length n > 0 then [n] else []
  | S.ECall (n, args, _) ->
      (if String.length n > 0 then [n] else []) @ List.concat_map r args
  | S.EApp (h, args, _) -> r h @ List.concat_map r args
  | S.EField (e1, _, _) | S.EParen (e1, _) | S.ERefl (e1, _)
  | S.EFst (e1, _) | S.ESnd (e1, _) | S.ENot (e1, _) | S.ELam (_, e1, _)
  | S.EIn (e1, _, _) | S.EMoveLam (_, e1, _, _, _) | S.EReductionLam (_, e1, _, _)
  | S.EMorphLam (_, e1, _, _, _) | S.EFunctorLam (_, e1, _, _, _, _)
  | S.EViewLam (_, e1, _, _) | S.EPathApp (e1, _, _) | S.EPathAbs (_, e1, _)
  | S.EQuote (_, e1, _) -> r e1
  | S.EBinop (_, a, b, _) | S.EPair (a, b, _) | S.EComposeWith (a, b, _) -> r a @ r b
  | S.EJ (a, b, c, _) | S.EIfThenElse (a, b, c, _)
  | S.EElMatch (a, b, c, _) -> r a @ r b @ r c
  | S.EPullbackVal (_, _, a, b, _) -> r a @ r b
  | S.EHITElim (scrut, branches, ret, _) ->
      r scrut @ List.concat_map (fun (_, _, b) -> r b) branches @ r ret
  | S.EHITConstr (_, args, _) -> List.concat_map r args
  | S.ENew (_, fas, _) | S.ENewIn (_, _, fas, _) ->
      List.concat_map (fun (fa : S.field_assignment) -> r fa.S.fa_value) fas
  | S.EProduce (body, _) -> List.concat_map refs_in_stmt body
  | S.ESpawn (count, body, _) ->
      (match count with Some c -> r c | None -> []) @ List.concat_map refs_in_stmt body
  | S.EAll (_, c, _) -> refs_in_cond c
  | S.ELit _ | S.EWireTo _ | S.EPullback _ | S.EPushout _ -> []

and refs_in_cond (c : S.condition) : string list =
  match c with
  | S.CondExpr e | S.CondIs (e, _) | S.CondIsNot (e, _) -> refs_in_expr e
  | S.CondAnd (a, b) | S.CondOr (a, b) -> refs_in_cond a @ refs_in_cond b

and refs_in_stmt (s : S.stmt) : string list =
  let re = refs_in_expr and rs = List.concat_map refs_in_stmt in
  match s with
  | S.SLet (_, e, _) | S.SAssignHolds (_, e, _) | S.SAssignBecomes (_, e, _)
  | S.SReturn (e, _) | S.SEmit (e, _) -> re e
  | S.SPromote (e, _) -> re e
  | S.SCall (n, args, _) -> n :: List.concat_map re args
  | S.SNew (_, fas, _) | S.SNewIn (_, _, fas, _) ->
      List.concat_map (fun (fa : S.field_assignment) -> re fa.S.fa_value) fas
  | S.SWhen (c, b, brs, ow, _) ->
      refs_in_cond c @ rs b
      @ List.concat_map (fun (cc, x) -> refs_in_cond cc @ rs x) brs
      @ (match ow with Some o -> rs o | None -> [])
  | S.SForEvery (_, _, e, b, _) | S.SInSequence (_, e, b, _)
  | S.SIter (e, b, _) | S.SWhile (e, b, _) -> re e @ rs b
  | S.SScope (_, b, e, _) -> rs b @ re e
  | S.SForces (_, c, b, _) -> refs_in_cond c @ rs b
  | S.SForever (b, _) | S.SProduce (b, _) -> rs b
  | S.SRepeat (_, b, ow, _) -> rs b @ (match ow with Some o -> rs o | None -> [])

let check_visibility (internals : string list) (decls : S.top_decl list) : unit =
  if internals = [] then ()
  else List.iter (function
    | S.TopFun fn ->
        let owner = module_of fn.S.fn_name in  (* the module this fun belongs to, if any *)
        List.iter (fun used ->
          if List.mem used internals && module_of used <> owner then begin
            Printf.eprintf
              "visibility error: '%s' is internal to its module and cannot be \
               used from outside.\n" used;
            exit 6
          end) (List.concat_map refs_in_stmt fn.S.fn_body)
    | _ -> ()) decls

(* ─── cross-Space lowering (cross-package RPC, increment 1) ────────────── *)

(* FNV-1a, identical to the C runtime, so frontend-computed hashes match. *)
let fnv1a (s : string) : int =
  let h = ref 2166136261 in
  String.iter (fun c ->
    h := !h lxor (Char.code c);
    h := (!h * 16777619) land 0xffffffff) s;
  !h

let op_selector (name : string) : int = (fnv1a name) land 0x7fffff

(* Rewrite every call to a name imported `from Space` into a runtime RPC call.
 * Idraulica v2 (decision 1): the channel identity is the NOMINAL Space name,
 * carried in a synthetic callable name the emitter expands:
 *   geometria::rotate(x)  -->  __yon_rpc2_invoke1__Measures(<op_sel>, x)
 * which emit_mlir lowers to
 *   yon_rt_rpc2_invoke_named(&"Measures", <op_sel>, x).
 * No hash%64 stream id: zero collisions by construction. Only number
 * arguments cross the boundary; arity 0-4. *)
let lower_cross_space (decls : S.top_decl list) : S.top_decl list =
  (* map: local-callable-name -> (Space, op-name). The local name is the bare
   * operation name `n` (e.g. "rotate") or its qualified "mod::n". *)
  let remote =
    List.concat_map (function
      | S.TopImportFrom (m, n, sp, _) ->
          [ (n, (sp, n)); (qualify m n, (sp, n)) ]
      | _ -> []) decls
  in
  if remote = [] then decls
  else
    let l = S.dummy_loc in
    let mk_num k = S.ELit (S.LitNumber (float_of_int k), l) in
    let invoke_name k sp =
      if k > 4 then begin
        Printf.eprintf
          "error: cross-Space call with %d arguments — at most 4 number \
           arguments are supported across a Space boundary\n" k;
        exit 7
      end;
      Printf.sprintf "__yon_rpc2_invoke%d__%s" k sp
    in
    let rec rwe (e : S.expr) : S.expr =
      match e with
      | S.ECall (name, args, _) when List.mem_assoc name remote ->
          let (sp, op) = List.assoc name remote in
          S.ECall (invoke_name (List.length args) sp,
                   mk_num (op_selector op) :: List.map rwe args, l)
      | S.ECall (n, args, ll) -> S.ECall (n, List.map rwe args, ll)
      | S.EBinop (op, a, b, ll) -> S.EBinop (op, rwe a, rwe b, ll)
      | S.EParen (x, ll) -> S.EParen (rwe x, ll)
      | S.EIfThenElse (c, a, b, ll) -> S.EIfThenElse (rwe c, rwe a, rwe b, ll)
      (* 2026-06-04: the traversal was incomplete — remote calls inside
         nested bodies (loops, when branches, lambdas, field values) were
         never rewritten and reached tycheck as unknown names. Completed. *)
      | S.ENot (x, ll) -> S.ENot (rwe x, ll)
      | S.EField (o, f, ll) -> S.EField (rwe o, f, ll)
      | S.ENew (n, fas, ll) ->
          S.ENew (n, List.map (fun fa -> { fa with S.fa_value = rwe fa.S.fa_value }) fas, ll)
      | S.ENewIn (n, sp, fas, ll) ->
          S.ENewIn (n, sp, List.map (fun fa -> { fa with S.fa_value = rwe fa.S.fa_value }) fas, ll)
      | S.EPair (a, b, ll) -> S.EPair (rwe a, rwe b, ll)
      | S.EFst (x, ll) -> S.EFst (rwe x, ll)
      | S.ESnd (x, ll) -> S.ESnd (rwe x, ll)
      | S.ERefl (x, ll) -> S.ERefl (rwe x, ll)
      | S.EJ (a, b, c, ll) -> S.EJ (rwe a, rwe b, rwe c, ll)
      | S.EIn (x, ctx, ll) -> S.EIn (rwe x, ctx, ll)
      | S.ELam (ps, b, ll) -> S.ELam (ps, rwe b, ll)
      | S.EMoveLam (ps, b, p1, p2, ll) -> S.EMoveLam (ps, rwe b, p1, p2, ll)
      | S.EReductionLam (ps, b, pl, ll) -> S.EReductionLam (ps, rwe b, pl, ll)
      | S.EMorphLam (ps, b, s1, s2, ll) -> S.EMorphLam (ps, rwe b, s1, s2, ll)
      | S.EFunctorLam (ps, b, w1, w2, laws, ll) -> S.EFunctorLam (ps, rwe b, w1, w2, laws, ll)
      | S.EViewLam (ps, b, pl, ll) -> S.EViewLam (ps, rwe b, pl, ll)
      | S.EComposeWith (a, b, ll) -> S.EComposeWith (rwe a, rwe b, ll)
      | S.EProduce (b, ll) -> S.EProduce (List.map rws b, ll)
      | S.ESpawn (count, b, ll) ->
          S.ESpawn ((match count with Some e -> Some (rwe e) | None -> None),
                    List.map rws b, ll)
      | S.EWireTo _ -> e
      | S.EAll (n, c, ll) -> S.EAll (n, rwc c, ll)
      | other -> other
    and rwc (c : S.condition) : S.condition =
      match c with
      | S.CondExpr e -> S.CondExpr (rwe e)
      | S.CondIs (e, p) -> S.CondIs (rwe e, p)
      | S.CondIsNot (e, p) -> S.CondIsNot (rwe e, p)
      | S.CondAnd (a, b) -> S.CondAnd (rwc a, rwc b)
      | S.CondOr (a, b) -> S.CondOr (rwc a, rwc b)
    and rws (s : S.stmt) : S.stmt =
      let rb = List.map rws in
      match s with
      | S.SReturn (e, ll) -> S.SReturn (rwe e, ll)
      | S.SLet (x, e, ll) -> S.SLet (x, rwe e, ll)
      | S.SCall (name, args, ll) when List.mem_assoc name remote ->
          let (sp, op) = List.assoc name remote in
          S.SCall (invoke_name (List.length args) sp,
                   mk_num (op_selector op) :: List.map rwe args, ll)
      | S.SCall (n, args, ll) -> S.SCall (n, List.map rwe args, ll)
      | S.SAssignHolds (lv, e, ll) -> S.SAssignHolds (lv, rwe e, ll)
      | S.SAssignBecomes (lv, e, ll) -> S.SAssignBecomes (lv, rwe e, ll)
      | S.SEmit (e, ll) -> S.SEmit (rwe e, ll)
      | S.SPromote (e, ll) -> S.SPromote (rwe e, ll)
      | S.SNew (n, fas, ll) ->
          S.SNew (n, List.map (fun fa -> { fa with S.fa_value = rwe fa.S.fa_value }) fas, ll)
      | S.SNewIn (n, sp, fas, ll) ->
          S.SNewIn (n, sp, List.map (fun fa -> { fa with S.fa_value = rwe fa.S.fa_value }) fas, ll)
      | S.SWhen (c, b, elifs, oth, ll) ->
          S.SWhen (rwc c, rb b,
                   List.map (fun (c2, b2) -> (rwc c2, rb b2)) elifs,
                   (match oth with None -> None | Some o -> Some (rb o)), ll)
      | S.SIter (n, b, ll) -> S.SIter (rwe n, rb b, ll)
      | S.SWhile (c, b, ll) -> S.SWhile (rwe c, rb b, ll)
      | S.SForever (b, ll) -> S.SForever (rb b, ll)
      | S.SForEvery (k, x, e, b, ll) -> S.SForEvery (k, x, rwe e, rb b, ll)
      | S.SInSequence (x, e, b, ll) -> S.SInSequence (x, rwe e, rb b, ll)
      | S.SRepeat (n, b, oth, ll) ->
          S.SRepeat (n, rb b, (match oth with None -> None | Some o -> Some (rb o)), ll)
      | S.SScope (n, b, r, ll) -> S.SScope (n, rb b, rwe r, ll)
      | S.SProduce (b, ll) -> S.SProduce (rb b, ll)
      | S.SForces (stg, c, b, ll) -> S.SForces (stg, rwc c, rb b, ll)
    in
    List.map (function
      | S.TopFun fn -> S.TopFun { fn with fn_body = List.map rws fn.S.fn_body }
      | other -> other) decls

let prefix_decls (modname : string) (decls : S.top_decl list) : S.top_decl list =
  let locals = local_fun_names decls in
  let rename n = if List.mem n locals then qualify modname n else n in
  List.map (function
    | S.TopFun fn ->
        S.TopFun { fn with
          S.fn_name = qualify modname fn.S.fn_name;
          S.fn_body = List.map (rw_stmt rename) fn.S.fn_body }
    | other -> other) decls

(* Mangling: turn qualified names "a::b" into a valid identifier "a_NS_b".
 * Applied to the whole program AFTER conflict detection (which wants to see
 * the readable :: form), so that MLIR symbol names are valid. *)
let mangle_sep = "_NS_"
let mangle_name (n : string) : string =
  Str.global_replace (Str.regexp_string "::") mangle_sep n

let mangle_decls (decls : S.top_decl list) : S.top_decl list =
  (* rename every name (qualified or not — non-qualified names are unchanged
   * since they contain no "::"). Reuse the same rewriters with mangle_name. *)
  List.map (fun d -> match d with
    | S.TopFun fn ->
        S.TopFun { fn with
          S.fn_name = mangle_name fn.S.fn_name;
          S.fn_body = List.map (rw_stmt mangle_name) fn.S.fn_body }
    | other -> other) decls

(* Selective import with alias (Strato 4b). For each `import M::name [as alias]`,
 * the local name (alias if present, else `name`) is rewritten to the qualified
 * `M::name` everywhere in the program. So `geo_scale(...)` -> `geometria::scale(...)`,
 * which Strato 2 has already materialized as a real symbol. *)
let resolve_aliases (decls : S.top_decl list) : S.top_decl list =
  (* Names defined locally as functions (after Strato 2, imported modules carry
   * "::" in their names, so a plain unqualified TopFun name is a local one). *)
  let local_funs =
    List.filter_map (function
      | S.TopFun fn when not (Str.string_match (Str.regexp ".*::") fn.S.fn_name 0) ->
          Some fn.S.fn_name
      | _ -> None) decls
  in
  (* Conflict detection (4c): a selective import WITHOUT alias whose local name
   * collides with a locally-defined function is ambiguous — require an alias. *)
  List.iter (function
    | S.TopImportSym (m, name, None, _) when List.mem name local_funs ->
        Printf.eprintf
          "import error: '%s' is ambiguous — it is defined locally and also \
           imported from '%s'.\n\
           \      use an alias: import %s::%s as <alias>\n"
          name m m name;
        exit 5
    | _ -> ()) decls;
  let alias_map =
    List.filter_map (function
      | S.TopImportSym (m, name, alias_opt, _) ->
          let local = match alias_opt with Some a -> a | None -> name in
          Some (local, qualify m name)
      | _ -> None) decls
  in
  if alias_map = [] then decls
  else
    let rename n = match List.assoc_opt n alias_map with Some q -> q | None -> n in
    List.map (function
      | S.TopFun fn ->
          S.TopFun { fn with fn_body = List.map (rw_stmt rename) fn.S.fn_body }
      | other -> other) decls
