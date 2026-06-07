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
    fn_visits = [];
    fn_partial = false; fn_internal = false;
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
    fn_visits = [];
    fn_partial = false; fn_internal = false;
    fn_body = [Surface_ast.SReturn (body, loc)];
    fn_loc = loc;
  } in
  synth_decls := (Surface_ast.TopFun fd) :: !synth_decls;
  name

let drain () : Surface_ast.top_decl list =
  let r = List.rev !synth_decls in
  synth_decls := [];
  inline_counter := 0;
  r
