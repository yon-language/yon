(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* Method-call sugar normalization (surface AST pass, run BEFORE tycheck).
 *
 * Lets a tracked collection handle be updated method-style:
 *
 *     s := XSimplex.empty()
 *     s.add(p1, p2)            -- sugar for: s := XSimplex.add(s, p1, p2)
 *     s.add(p1, p3)
 *
 * `s.method(args)` as a statement, when `s` is a binding whose place is known,
 * rewrites to an immutable shadowing re-binding `s := Place.method(s, args)`.
 * No types, no storage, no mutation: `s` is not mutated, only re-bound. Both the
 * typechecker and the desugar then see only the explicit form.
 *
 * The owning place P is read from the head of the binding expression:
 *     s := XSimplex.empty()  ->  ECall("XSimplex__empty", _)  ->  "XSimplex"
 * An alias `t := s` inherits s's place. Provenance is SCOPED, not global:
 * it rides by value through the statement list and into nested bodies as the
 * lexical environment, so two `s` in two isolated Spaces never interfere. A
 * binding with no known place leaves `s.method(...)` untouched -- it fails
 * downstream as it does today, with no silent magic. *)

module S = Surface_ast

(* binding name -> originating place *)
type prov = (string * string) list

(* Read the place from the head of a bound expression, or inherit via alias. *)
let place_of_binding (e : S.expr) (prov : prov) : string option =
  match e with
  | S.ECall (qname, _, _) ->
      (try
         let idx = Str.search_forward (Str.regexp "__") qname 0 in
         let prefix = String.sub qname 0 idx in
         (* Only Uppercase-led heads are place modules; lowercase heads are the
            stream UFCS chain, handled in the desugar. *)
         if String.length prefix > 0 && prefix.[0] >= 'A' && prefix.[0] <= 'Z'
         then Some prefix else None
       with Not_found -> None)
  | S.EVar (other, _) -> (try Some (List.assoc other prov) with Not_found -> None)
  | _ -> None

(* Split a parser-formed `obj__fld` call name at the first `__`. *)
let split_method_name (name : string) : (string * string) option =
  try
    let idx = Str.search_forward (Str.regexp "__") name 0 in
    let obj = String.sub name 0 idx in
    let fld = String.sub name (idx + 2) (String.length name - idx - 2) in
    if String.length obj > 0 && String.length fld > 0 then Some (obj, fld) else None
  with Not_found -> None

let update_prov (prov : prov) (name : string) (e : S.expr) : prov =
  match place_of_binding e prov with
  | Some p -> (name, p) :: List.remove_assoc name prov
  | None   -> List.remove_assoc name prov

let rec norm_stmts (prov : prov) (stmts : S.stmt list) : S.stmt list =
  match stmts with
  | [] -> []
  | S.SLet (name, e, loc) :: rest ->
      let prov' = update_prov prov name e in
      S.SLet (name, e, loc) :: norm_stmts prov' rest
  | S.SCall (name, args, loc) :: rest
      when (match split_method_name name with
            | Some (obj, _) -> List.mem_assoc obj prov
            | None -> false) ->
      let (obj, fld) = match split_method_name name with
        | Some pair -> pair | None -> assert false in
      let place = List.assoc obj prov in
      (* s.method(args)  ->  s := Place.method(s, args)  [shadowing] *)
      let call = S.ECall (place ^ "__" ^ fld, S.EVar (obj, loc) :: args, loc) in
      (* shadowing keeps the same place, so prov is unchanged for the rest *)
      S.SLet (obj, call, loc) :: norm_stmts prov rest
  | s :: rest ->
      norm_nested prov s :: norm_stmts prov rest

(* Recurse into nested bodies, inheriting the outer provenance as the lexical
 * environment; additions inside a body do not escape it (functional threading). *)
and norm_nested (prov : prov) (s : S.stmt) : S.stmt =
  match s with
  | S.SIter (n, b, loc)           -> S.SIter (n, norm_stmts prov b, loc)
  | S.SWhile (c, b, loc)          -> S.SWhile (c, norm_stmts prov b, loc)
  | S.SForEvery (k, x, e, b, loc) -> S.SForEvery (k, x, e, norm_stmts prov b, loc)
  | S.SInSequence (x, e, b, loc)  -> S.SInSequence (x, e, norm_stmts prov b, loc)
  | S.SScope (n, b, r, loc)       -> S.SScope (n, norm_stmts prov b, r, loc)
  | S.SProduce (b, loc)           -> S.SProduce (norm_stmts prov b, loc)
  | S.SForever (b, loc)           -> S.SForever (norm_stmts prov b, loc)
  | S.SRepeat (n, b, oth, loc)    ->
      S.SRepeat (n, norm_stmts prov b,
                 (match oth with Some o -> Some (norm_stmts prov o) | None -> None), loc)
  | S.SForces (nm, c, b, loc)     -> S.SForces (nm, c, norm_stmts prov b, loc)
  | S.SWhen (c, b, elifs, oth, loc) ->
      S.SWhen (c, norm_stmts prov b,
               List.map (fun (cc, bb) -> (cc, norm_stmts prov bb)) elifs,
               (match oth with Some o -> Some (norm_stmts prov o) | None -> None), loc)
  | other -> other

let normalize_fun (fn : S.fun_decl) : S.fun_decl =
  { fn with S.fn_body = norm_stmts [] fn.S.fn_body }

(* The name of a nullary fun, or of a nullary operation, is its value: a point 1 -> X. *)
let rec map_expr (f : S.expr -> S.expr option) (e : S.expr) : S.expr =
  match f e with
  | Some e' -> e'
  | None ->
      let r = map_expr f in
      let rs = map_stmt f in
      match e with
      | S.ELit _ | S.EVar _ | S.EWireTo _ | S.EAll _ | S.EPullback _ | S.EPushout _ -> e
      | S.EField (o, n, l) -> S.EField (r o, n, l)
      | S.ECall (n, a, l) -> S.ECall (n, List.map r a, l)
      | S.EApp (g, a, l) -> S.EApp (r g, List.map r a, l)
      | S.EHITElim (m, br, x, l) ->
          S.EHITElim (r m, List.map (fun (c, p, b) -> (c, p, r b)) br, r x, l)
      | S.EPathApp (x, d, l) -> S.EPathApp (r x, d, l)
      | S.EPathAbs (i, b, l) -> S.EPathAbs (i, r b, l)
      | S.EHITConstr (c, a, l) -> S.EHITConstr (c, List.map r a, l)
      | S.EProduce (b, l) -> S.EProduce (List.map rs b, l)
      | S.ESpawn (n, b, l) -> S.ESpawn (Option.map r n, List.map rs b, l)
      | S.ENew (n, fas, l) ->
          S.ENew (n, List.map (fun fa -> { fa with S.fa_value = r fa.S.fa_value }) fas, l)
      | S.ENewIn (n, sp, fas, l) ->
          S.ENewIn (n, sp, List.map (fun fa -> { fa with S.fa_value = r fa.S.fa_value }) fas, l)
      | S.EBinop (o, a, b, l) -> S.EBinop (o, r a, r b, l)
      | S.EParen (x, l) -> S.EParen (r x, l)
      | S.EIn (x, c, l) -> S.EIn (r x, c, l)
      | S.ERefl (x, l) -> S.ERefl (r x, l)
      | S.EPair (a, b, l) -> S.EPair (r a, r b, l)
      | S.EFst (x, l) -> S.EFst (r x, l)
      | S.ESnd (x, l) -> S.ESnd (r x, l)
      | S.EJ (a, b, c, l) -> S.EJ (r a, r b, r c, l)
      | S.EQuote (c, x, l) -> S.EQuote (c, r x, l)
      | S.EElMatch (a, b, c, l) -> S.EElMatch (r a, r b, r c, l)
      | S.EPullbackVal (g, h, a, b, l) -> S.EPullbackVal (g, h, r a, r b, l)
      | S.ENot (x, l) -> S.ENot (r x, l)
      | S.EIfThenElse (a, b, c, l) -> S.EIfThenElse (r a, r b, r c, l)
      | S.ELam (p, b, l) -> S.ELam (p, r b, l)
      | S.EMoveLam (p, b, a, c, l) -> S.EMoveLam (p, r b, a, c, l)
      | S.EReductionLam (p, b, a, l) -> S.EReductionLam (p, r b, a, l)
      | S.EMorphLam (p, b, a, c, l) -> S.EMorphLam (p, r b, a, c, l)
      | S.EFunctorLam (p, b, a, c, d, l) -> S.EFunctorLam (p, r b, a, c, d, l)
      | S.EViewLam (p, b, a, l) -> S.EViewLam (p, r b, a, l)
      | S.EComposeWith (a, b, l) -> S.EComposeWith (r a, r b, l)

and map_cond f (c : S.condition) : S.condition =
  match c with
  | S.CondExpr e -> S.CondExpr (map_expr f e)
  | S.CondIs (e, t) -> S.CondIs (map_expr f e, t)
  | S.CondIsNot (e, t) -> S.CondIsNot (map_expr f e, t)
  | S.CondAnd (a, b) -> S.CondAnd (map_cond f a, map_cond f b)
  | S.CondOr (a, b) -> S.CondOr (map_cond f a, map_cond f b)

and map_stmt f (s : S.stmt) : S.stmt =
  let r = map_expr f in
  let rs = List.map (map_stmt f) in
  let fas = List.map (fun fa -> { fa with S.fa_value = r fa.S.fa_value }) in
  match s with
  | S.SLet (n, e, l) -> S.SLet (n, r e, l)
  | S.SAssignHolds (v, e, l) -> S.SAssignHolds (v, r e, l)
  | S.SAssignBecomes (v, e, l) -> S.SAssignBecomes (v, r e, l)
  | S.SReturn (e, l) -> S.SReturn (r e, l)
  | S.SCall (n, a, l) -> S.SCall (n, List.map r a, l)
  | S.SNew (n, a, l) -> S.SNew (n, fas a, l)
  | S.SNewIn (n, sp, a, l) -> S.SNewIn (n, sp, fas a, l)
  | S.SWhen (c, b, alts, oth, l) ->
      S.SWhen (map_cond f c, rs b,
               List.map (fun (ac, ab) -> (map_cond f ac, rs ab)) alts, Option.map rs oth, l)
  | S.SForEvery (k, x, e, b, l) -> S.SForEvery (k, x, r e, rs b, l)
  | S.SInSequence (x, e, b, l) -> S.SInSequence (x, r e, rs b, l)
  | S.SRepeat (n, b, o, l) -> S.SRepeat (n, rs b, Option.map rs o, l)
  | S.SForever (b, l) -> S.SForever (rs b, l)
  | S.SScope (n, b, e, l) -> S.SScope (n, rs b, r e, l)
  | S.SProduce (b, l) -> S.SProduce (rs b, l)
  | S.SEmit (e, l) -> S.SEmit (r e, l)
  | S.SPromote (e, l) -> S.SPromote (r e, l)
  | S.SForces (n, c, b, l) -> S.SForces (n, map_cond f c, rs b, l)
  | S.SIter (e, b, l) -> S.SIter (r e, rs b, l)
  | S.SWhile (e, b, l) -> S.SWhile (r e, rs b, l)
  | S.SDrop _ -> s

let rec map_type_terms f (t : S.ty) : S.ty =
  let term = function S.TyTermExpr e -> S.TyTermExpr (map_expr f e) in
  match t with
  | S.TyId (a, x, y) -> S.TyId (a, term x, term y)
  | S.TyPi (x, a, b) -> S.TyPi (x, map_type_terms f a, map_type_terms f b)
  | S.TySigma (x, a, b) -> S.TySigma (x, map_type_terms f a, map_type_terms f b)
  | S.TyArrow (a, b) -> S.TyArrow (map_type_terms f a, map_type_terms f b)
  | t -> t

(* The names a body binds: a name it binds is that binder, not a nullary fun. *)
let bound_names (fn : S.fun_decl) : (string, unit) Hashtbl.t =
  let bound = Hashtbl.create 16 in
  let add x = Hashtbl.replace bound x () in
  List.iter (fun (pm : S.param) -> add pm.S.param_name) fn.S.fn_params;
  let note (e : S.expr) =
    (match e with
     | S.ELam (ps, _, _) -> List.iter (fun (x, _) -> add x) ps
     | S.EPathAbs (i, _, _) -> add i
     | S.EHITElim (_, br, _, _) ->
         List.iter (fun (_, p, _) ->
             match p with
             | S.PatVars vs -> List.iter add vs
             | S.PatWitness w -> add w
             | S.PatFields fs -> List.iter (fun (_, b) -> add b) fs) br
     | _ -> ());
    None in
  let rec stmt (s : S.stmt) =
    (match s with
     | S.SLet (x, _, _) | S.SForEvery (_, x, _, _, _) | S.SInSequence (x, _, _, _) -> add x
     | _ -> ());
    ignore (map_stmt note s);
    List.iter (List.iter stmt) (S.sub_stmts s) in
  List.iter stmt fn.S.fn_body;
  bound

let base_name home name =
  let pfx = home ^ "__" in
  if String.starts_with ~prefix:pfx name
  then String.sub name (String.length pfx) (String.length name - String.length pfx)
  else name

let nullary_points (p : S.program) : S.program =
  let global = Hashtbl.create 64 and housed = Hashtbl.create 64 in
  List.iter (fun n -> Hashtbl.replace global n ()) ["XTower__depth"; "Args__count"];
  List.iter (function
    | S.TopFun fd when fd.S.fn_params = [] ->
        (match fd.S.fn_home with
         | Some h ->
             Hashtbl.replace housed (h, base_name h fd.S.fn_name) ();
             Hashtbl.replace global (h ^ "__" ^ base_name h fd.S.fn_name) ()
         | None -> Hashtbl.replace global fd.S.fn_name ())
    | S.TopPlace pd ->
        List.iter (function
          | S.FoOp o when o.S.op_params = [] ->
              Hashtbl.replace housed (pd.S.pd_name, o.S.op_name) ();
              Hashtbl.replace global (pd.S.pd_name ^ "__" ^ o.S.op_name) ();
              Hashtbl.replace S.nullary_operations (pd.S.pd_name ^ "__" ^ o.S.op_name) ()
          | _ -> ()) pd.S.pd_members
    | _ -> ()) p;
  (* a model takes the constants of its algebras *)
  let constants_of a =
    List.concat_map (function
      | S.TopPlace pd when pd.S.pd_name = a ->
          List.filter_map (function
            | S.FoOp o when o.S.op_params = [] -> Some o.S.op_name
            | _ -> None) pd.S.pd_members
      | _ -> []) p in
  List.iter (function
    | S.TopPlace pd ->
        List.iter (fun a ->
          List.iter (fun c ->
            Hashtbl.replace housed (pd.S.pd_name, c) ();
            Hashtbl.replace global (pd.S.pd_name ^ "__" ^ c) ();
            Hashtbl.replace S.nullary_operations (pd.S.pd_name ^ "__" ^ c) ())
            (constants_of a))
          (Option.value ~default:[] (Hashtbl.find_opt S.place_algebras pd.S.pd_name))
    | _ -> ()) p;
  let mark (l : S.location) n =
    Hashtbl.replace S.bare_nullary_sites (l.S.file, l.S.start_line, l.S.start_col, n) () in
  let rewrite ~(home : string option) ~(bound : string -> bool) (e : S.expr) : S.expr option =
    match e with
    (* a subscription names its producer: the name is the arrow, not its value *)
    | S.ECall ("awaits", _, _) -> Some e
    | S.EVar (x, l) when not (bound x) ->
        (match home with
         | Some h when Hashtbl.mem housed (h, x) ->
             let n = h ^ "__" ^ x in mark l n; Some (S.ECall (n, [], l))
         | _ ->
             if Hashtbl.mem global x then (mark l x; Some (S.ECall (x, [], l))) else None)
    | S.EField (S.EVar (m, _), f, l) when not (bound m) && Hashtbl.mem global (m ^ "__" ^ f) ->
        let n = m ^ "__" ^ f in mark l n; Some (S.ECall (n, [], l))
    | _ -> None in
  List.map (function
    | S.TopFun fn ->
        let names = bound_names fn in
        let f = rewrite ~home:fn.S.fn_home ~bound:(Hashtbl.mem names) in
        S.TopFun { fn with
          S.fn_body = List.map (map_stmt f) fn.S.fn_body;
          S.fn_return = Option.map (map_type_terms f) fn.S.fn_return;
          S.fn_params = List.map (fun (pm : S.param) ->
              { pm with S.param_ty = map_type_terms f pm.S.param_ty }) fn.S.fn_params }
    | S.TopPlace pd ->
        S.TopPlace { pd with S.pd_members = List.map (function
            | S.FoLaw (n, Some st) ->
                let vars = List.map (fun (_, x, _) -> x) st.S.ls_quants in
                let f = rewrite ~home:(Some pd.S.pd_name) ~bound:(fun x -> List.mem x vars) in
                S.FoLaw (n, Some { st with S.ls_body = map_expr f st.S.ls_body })
            | m -> m) pd.S.pd_members }
    | d -> d) p

let normalize_program (p : S.program) : S.program =
  let p = nullary_points p in
  List.map (function
    | S.TopFun fn -> S.TopFun (normalize_fun fn)
    | other -> other) p

(* Overload resolution by receiver type (method dispatch). A method is an arrow
   indexed by its domain object (Yoneda). When a function name is shared by
   several top-level funs, qualify each with the place of its first parameter:
   `area(s: Square)` becomes `Square__area`, matching the qualified-call form
   `Square.area` the parser already produces. Unique names (main, plain helpers)
   are untouched, so every downstream pass stays on unique names (no crash, no
   shadow). NAME-ONLY: the body is never rewritten, so two methods with identical
   bodies keep identical content and still content-address to the same value.
   Call sites stay bare and are resolved to the qualified target by the receiver
   type during checking (Surface_ast.method_resolutions). Pure and idempotent
   after the first application (a qualified name is no longer shared), so both
   Tycheck and Desugar can apply it and agree on the same names. *)
let first_param_place (fd : S.fun_decl) : string option =
  match fd.S.fn_params with
  | p :: _ -> (match p.S.param_ty with S.TyUser pl -> Some pl | _ -> None)
  | [] -> None

(* ─── Qualified naming: THE HOUSE GIVES THE NAME ───
   A fun hoisted from `place P { ... }` carries fn_home = Some P and its
   canonical name is P__name (the same mangling the receiver dispatch and
   the dot-call already speak: `P.name(args)` parses to `P__name(args)`).
   The BARE name stays valid INSIDE the house: sibling calls in a homed
   fun's body are rewritten to the qualified name (the sibling wins over a
   global homonym — same rule as bare points). Outside the house the bare
   name simply does not exist. Idempotent: an already-prefixed name is left
   alone. Collisions (same house, same name) surface as genuine duplicates
   downstream, loudly. *)
let qualify_homes (p : S.program) : S.program =
  (* home -> set of its fun names (pre-rename) *)
  let home_funs : (string, string list) Hashtbl.t = Hashtbl.create 16 in
  List.iter (function
    | S.TopFun fd ->
        (match fd.S.fn_home with
         | Some h ->
             (* store the BASE name: on a rerun the fun is already
                Home__name, and collecting that as a sibling would rewrite
                calls to Home__Home__name — idempotence lives here. *)
             let pfx = h ^ "__" in
             let base =
               if String.length fd.S.fn_name > String.length pfx
                  && String.sub fd.S.fn_name 0 (String.length pfx) = pfx
               then String.sub fd.S.fn_name (String.length pfx)
                      (String.length fd.S.fn_name - String.length pfx)
               else fd.S.fn_name in
             let prev = Option.value ~default:[] (Hashtbl.find_opt home_funs h) in
             Hashtbl.replace home_funs h (base :: prev)
         | None -> ())
    | _ -> ()) p;
  let qual h n = h ^ "__" ^ n in
  let rec rw_expr (sibs : string list) (h : string) (e : S.expr) : S.expr =
    let r = rw_expr sibs h in
    match e with
    | S.ECall (n, args, l) when List.mem n sibs ->
        S.ECall (qual h n, List.map r args, l)
    | S.ECall (n, args, l) -> S.ECall (n, List.map r args, l)
    | S.EApp (f, args, l) -> S.EApp (r f, List.map r args, l)
    | S.EBinop (op, a, b, l) -> S.EBinop (op, r a, r b, l)
    | S.EParen (x, l) -> S.EParen (r x, l)
    | S.EIfThenElse (c, a, b, l) -> S.EIfThenElse (r c, r a, r b, l)
    | S.EField (o, f, l) -> S.EField (r o, f, l)
    | S.ERefl (x, l) -> S.ERefl (r x, l)
    | S.EPathAbs (i, b, l) -> S.EPathAbs (i, r b, l)
    | S.EPathApp (x, d, l) -> S.EPathApp (r x, d, l)
    | S.EHITConstr (c, args, l) -> S.EHITConstr (c, List.map r args, l)
    | S.EHITElim (m, brs, x, l) ->
        S.EHITElim (r m, List.map (fun (c, pt, b) -> (c, pt, r b)) brs, r x, l)
    | S.ELam (ps, b, l) -> S.ELam (ps, r b, l)
    | S.ENew (n, fas, l) ->
        S.ENew (n, List.map (fun fa -> { fa with S.fa_value = r fa.S.fa_value }) fas, l)
    | S.EPair (a, b, l) -> S.EPair (r a, r b, l)
    | S.EFst (x, l) -> S.EFst (r x, l)
    | S.ESnd (x, l) -> S.ESnd (r x, l)
    | S.ENot (x, l) -> S.ENot (r x, l)
    | other -> other
  in
  let rec rw_stmt sibs h (st : S.stmt) : S.stmt =
    match st with
    | S.SLet (n, e, l) -> S.SLet (n, rw_expr sibs h e, l)
    | S.SReturn (e, l) -> S.SReturn (rw_expr sibs h e, l)
    | S.SCall (n, args, l) when List.mem n sibs ->
        S.SCall (h ^ "__" ^ n, List.map (rw_expr sibs h) args, l)
    | S.SCall (n, args, l) -> S.SCall (n, List.map (rw_expr sibs h) args, l)
    | S.SAssignHolds (lv, e, l) -> S.SAssignHolds (lv, rw_expr sibs h e, l)
    | S.SAssignBecomes (lv, e, l) -> S.SAssignBecomes (lv, rw_expr sibs h e, l)
    | S.SIter (n, body, l) -> S.SIter (rw_expr sibs h n, List.map (rw_stmt sibs h) body, l)
    | S.SWhile (c, body, l) ->
        S.SWhile (rw_expr sibs h c, List.map (rw_stmt sibs h) body, l)
    | S.SForever (body, l) -> S.SForever (List.map (rw_stmt sibs h) body, l)
    | S.SForEvery (k, v, e, body, l) ->
        S.SForEvery (k, v, rw_expr sibs h e, List.map (rw_stmt sibs h) body, l)
    | other -> other
  in
  (* the ONE walk, applied to every expression carrier of every housed form.
     A non-fun form finds its house by SITE (arrow_home_sites, filled by
     retag_home at parse); its bare sibling calls are rewritten exactly like
     a fun body's. Idempotent: a rewritten call is no longer in sibs.
     Name-references (move `by f`, nat `via`) are names, not expressions —
     move resolves through the handler lookup and stays untouched. *)
  let house_of (loc : S.location) : string option =
    Hashtbl.find_opt Surface_ast.arrow_home_sites
      (loc.S.file, loc.S.start_line, loc.S.start_col) in
  let in_house loc (f : string list -> string -> 'a) (dflt : 'a) : 'a =
    match house_of loc with
    | None -> dflt
    | Some h ->
        let sibs = Option.value ~default:[] (Hashtbl.find_opt home_funs h) in
        if sibs = [] then dflt else f sibs h in
  let rw_fd sibs h (fd : S.fun_decl) : S.fun_decl =
    { fd with S.fn_body = List.map (rw_stmt sibs h) fd.S.fn_body } in
  List.map (function
    | S.TopFun fd when fd.S.fn_home <> None ->
        let h = Option.get fd.S.fn_home in
        let sibs = Option.value ~default:[] (Hashtbl.find_opt home_funs h) in
        let already =
          let pfx = h ^ "__" in
          String.length fd.S.fn_name >= String.length pfx
          && String.sub fd.S.fn_name 0 (String.length pfx) = pfx in
        let fd = if already then fd
          else { fd with S.fn_name = qual h fd.S.fn_name } in
        S.TopFun { fd with S.fn_body = List.map (rw_stmt sibs h) fd.S.fn_body }
    | S.TopView vd ->
        in_house vd.S.vw_loc (fun sibs h ->
          S.TopView { vd with S.vw_items =
            List.map (function
              | S.VShowAs (n, e) -> S.VShowAs (n, rw_expr sibs h e)
              | it -> it) vd.S.vw_items })
          (S.TopView vd)
    | S.TopReduction rd ->
        in_house rd.S.rd_loc (fun sibs h ->
          S.TopReduction { rd with S.rd_clauses =
            List.map (function
              | S.RcOn (op, ps, body, l) ->
                  S.RcOn (op, ps, List.map (rw_stmt sibs h) body, l)
              | S.RcLet (n, e, l) -> S.RcLet (n, rw_expr sibs h e, l))
              rd.S.rd_clauses })
          (S.TopReduction rd)
    | S.TopMorph mp ->
        in_house mp.S.mp_loc (fun sibs h ->
          S.TopMorph { mp with S.mp_on_object =
            Option.map (rw_fd sibs h) mp.S.mp_on_object })
          (S.TopMorph mp)
    | S.TopGeomMorphism gm ->
        in_house gm.S.gm_loc (fun sibs h ->
          S.TopGeomMorphism { gm with
            S.gm_pull = Option.map (rw_fd sibs h) gm.S.gm_pull;
            S.gm_push = Option.map (rw_fd sibs h) gm.S.gm_push })
          (S.TopGeomMorphism gm)
    | S.TopFunctor ft ->
        in_house ft.S.ft_loc (fun sibs h ->
          S.TopFunctor { ft with S.ft_body = rw_expr sibs h ft.S.ft_body })
          (S.TopFunctor ft)
    | d -> d) p

let qualify_overloads (p : S.program) : S.program =
  let names = List.filter_map (function S.TopFun fd -> Some fd.S.fn_name | _ -> None) p in
  let shared n = List.length (List.filter (String.equal n) names) > 1 in
  List.map (function
    | S.TopFun fd when shared fd.S.fn_name ->
        (match first_param_place fd with
         | Some pl -> S.TopFun { fd with S.fn_name = pl ^ "__" ^ fd.S.fn_name }
         | None -> S.TopFun fd)  (* not a method: left to the duplicate check *)
    | d -> d) p
