(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* Global parser state for lifting inline lambdas. Used by parser.mly to
 * accumulate synthetic top-level declarations (e.g. for `by fun(...)` in a
 * move conversion). *)

let inline_counter = ref 0
let synth_decls : Surface_ast.top_decl list ref = ref []

let fresh_inline_name (kind : string) : string =
  incr inline_counter;
  Printf.sprintf "__%s_inline_p_%d" kind !inline_counter

let reset () =
  inline_counter := 0;
  synth_decls := []

(* Emit a synthetic top-level declaration. Used to lift the arrows declared
   inside a place body (fun/move/functor/geom_morphism/nat_transform/view/
   reduction) to the top level: a place groups them syntactically, but the
   front-end downstream sees them as ordinary top-level declarations. *)
let push_decl (d : Surface_ast.top_decl) : unit =
  synth_decls := d :: !synth_decls

(* Add a synthetic fun to the pool. The synthetic fun wraps a lambda passed as
 * a `by`. *)
let lift_inline_block_lambda_to_fun
    (params : (string * Surface_ast.ty) list)
    (body : Surface_ast.stmt list)
    (loc : Surface_ast.location) : string =
  (* Block-bodied inline lambda: fun(v) => { stmts }. Lifted like the
     expression form; an effectful body falls through to return 0. *)
  let name = fresh_inline_name "blk" in
  let fn_params = List.map (fun (n, t) ->
    { Surface_ast.param_name = n; param_ty = t }
  ) params in
  let fd : Surface_ast.fun_decl = {
    fn_name = name;
    fn_type_params = [];
    fn_params = fn_params;
    fn_return = Some (TyPrim "number");
    fn_on_error = None; fn_visits = []; fn_internal = false; fn_given = false; fn_home = None;
    fn_body = body @ [Surface_ast.SReturn
                        (Surface_ast.ELit (Surface_ast.LitNumber 0.0, loc), loc)];
    fn_loc = loc;
  } in
  synth_decls := (Surface_ast.TopFun fd) :: !synth_decls;
  name

let lift_inline_lambda_to_fun
    (params : (string * Surface_ast.ty) list)
    (body : Surface_ast.expr)
    (loc : Surface_ast.location) : string =
  let name = fresh_inline_name "by" in
  let fn_params = List.map (fun (n, t) ->
    { Surface_ast.param_name = n; param_ty = t }
  ) params in
  let fd : Surface_ast.fun_decl = {
    fn_name = name;
    fn_type_params = [];
    fn_params = fn_params;
    fn_return = Some (TyPrim "number");
    fn_on_error = None; fn_visits = []; fn_internal = false; fn_given = false; fn_home = None;
    fn_body = [Surface_ast.SReturn (body, loc)];
    fn_loc = loc;
  } in
  synth_decls := (Surface_ast.TopFun fd) :: !synth_decls;
  name

(* qualified naming (the house gives the name): the place_decl action, which
   KNOWS its own name and how many arrows its body hoisted (the PbiArrow
   markers), retags the LAST [n] hoisted funs with fn_home = Some house.
   Order is preserved by push_decl, so the suffix is exactly this body's. *)
let retag_home (house : string) (n : int) : unit =
  let site (loc : Surface_ast.location) =
    (loc.Surface_ast.file, loc.Surface_ast.start_line,
     loc.Surface_ast.start_col) in
  let record (loc : Surface_ast.location) =
    (* containment rule: the non-fun arrow remembers its house BY SITE *)
    Hashtbl.replace Surface_ast.arrow_home_sites (site loc) house in
  (* topography, for EVERY form and EVERY house (Entry included): the
     formatter reprints the arrow inside the house that hosted it. *)
  let written (loc : Surface_ast.location) =
    Hashtbl.replace Surface_ast.arrow_written_in (site loc) house in
  if n > 0 then
    synth_decls := List.mapi (fun i d ->
      (* push_decl PREPENDS: this body's hoisted arrows are the FIRST n *)
      if i < n then
        match d with
        | Surface_ast.TopFun fd ->
            written fd.Surface_ast.fn_loc;
            if fd.Surface_ast.fn_home = None && house <> "Entry"
            then Surface_ast.TopFun { fd with Surface_ast.fn_home = Some house }
            else d
        (* i due fatti sono DIVERSI e si registrano separatamente:
           `written` è topografia (dove la freccia era scritta — sempre,
           Entry inclusa, e serve al formatter per rimetterla in casa);
           `record` è la regola di contenimento, da cui Entry è esente. *)
        | Surface_ast.TopMorph mp ->
            written mp.Surface_ast.mp_loc;
            if house <> "Entry" then record mp.Surface_ast.mp_loc; d
        | Surface_ast.TopView vd ->
            written vd.Surface_ast.vw_loc;
            if house <> "Entry" then record vd.Surface_ast.vw_loc; d
        | Surface_ast.TopMove mv ->
            written mv.Surface_ast.mv_loc;
            if house <> "Entry" then record mv.Surface_ast.mv_loc; d
        | Surface_ast.TopFunctor ft ->
            written ft.Surface_ast.ft_loc;
            if house <> "Entry" then record ft.Surface_ast.ft_loc; d
        | Surface_ast.TopGeomMorphism gm ->
            written gm.Surface_ast.gm_loc;
            if house <> "Entry" then record gm.Surface_ast.gm_loc; d
        | Surface_ast.TopNatTransform nt ->
            written nt.Surface_ast.nt_loc;
            if house <> "Entry" then record nt.Surface_ast.nt_loc; d
        | Surface_ast.TopReduction rd ->
            written rd.Surface_ast.rd_loc;
            if house <> "Entry" then record rd.Surface_ast.rd_loc; d
        | other -> other
      else d) !synth_decls

let drain () : Surface_ast.top_decl list =
  let r = List.rev !synth_decls in
  synth_decls := [];
  inline_counter := 0;
  r
