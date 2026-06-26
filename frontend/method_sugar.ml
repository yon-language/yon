(* Method-call sugar normalization (surface AST pass, run BEFORE tycheck).
 *
 * Lets a tracked collection handle be updated method-style:
 *
 *     be s holds XSimplex.empty()
 *     s.add(p1, p2)            -- sugar for: be s holds XSimplex.add(s, p1, p2)
 *     s.add(p1, p3)
 *
 * `s.method(args)` as a statement, when `s` is a binding whose place is known,
 * rewrites to an immutable shadowing re-binding `be s holds Place.method(s, args)`.
 * No types, no storage, no mutation: `s` is not mutated, only re-bound. Both the
 * typechecker and the desugar then see only the explicit form.
 *
 * The owning place P is read from the head of the binding expression:
 *     be s holds XSimplex.empty()  ->  ECall("XSimplex__empty", _)  ->  "XSimplex"
 * An alias `be t holds s` inherits s's place. Provenance is SCOPED, not global:
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
      (* s.method(args)  ->  be s holds Place.method(s, args)  [shadowing] *)
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

let normalize_program (p : S.program) : S.program =
  List.map (function
    | S.TopFun fn -> S.TopFun (normalize_fun fn)
    | other -> other) p
