(* linter.ml — the Yon linter, as a shared library.
 *
 * Complementary to the type checker: the tycheck REJECTS ill-typed programs; the
 * linter only WARNS about code that is well-typed but suspicious. It never rejects.
 * Each warning is a canonical Error_codes.t carrying a stable Wxxx code and a full
 * location, so the `yon_lint` CLI and the language server (which surfaces them as
 * Warning diagnostics) share one implementation and cannot disagree.
 *
 * Rules (purely syntactic; reuse the parser + the free-variable collector):
 *   W1001 dead-function   : a top-level fun never reached from `main`
 *   W1002 unused-binding  : `be x holds e` whose x is never used afterwards
 *   W1003 unused-param    : a function parameter never used in the body
 *   W3001 unused-import   : an `import ... from S` whose symbol is never used --
 *                           a dead Space dependency (a communication arc with no
 *                           traffic), the linter's one Space-aware rule.
 *)

module S = Surface_ast
module E = Error_codes

(* ─── name collection over statements (reuses Desugar.free_vars_in_expr) ─── *)

let names_in_expr (e : S.expr) : string list = Desugar.free_vars_in_expr [] e

let rec names_used_in_stmts (stmts : S.stmt list) : string list =
  List.concat_map names_used_in_stmt stmts

and names_used_in_stmt (s : S.stmt) : string list =
  match s with
  | S.SLet (_, e, _) -> names_in_expr e
  | S.SAssignHolds (_, e, _) | S.SAssignBecomes (_, e, _) -> names_in_expr e
  | S.SReturn (e, _) | S.SEmit (e, _) | S.SPromote (e, _) -> names_in_expr e
  | S.SCall (name, args, _) -> name :: List.concat_map names_in_expr args
  | S.SNew (_, fas, _) | S.SNewIn (_, _, fas, _) ->
      List.concat_map (fun fa -> names_in_expr fa.S.fa_value) fas
  | S.SWhen (_, body, branches, otherwise, _) ->
      names_used_in_stmts body
      @ List.concat_map (fun (_, b) -> names_used_in_stmts b) branches
      @ (match otherwise with Some o -> names_used_in_stmts o | None -> [])
  | S.SForEvery (_, _, e, body, _) -> names_in_expr e @ names_used_in_stmts body
  | S.SInSequence (_, e, body, _) -> names_in_expr e @ names_used_in_stmts body
  | S.SIter (e, body, _) | S.SWhile (e, body, _) ->
      names_in_expr e @ names_used_in_stmts body
  | S.SForces (_, _, body, _) -> names_used_in_stmts body
  | S.SScope (_, body, _, _) | S.SProduce (body, _) | S.SForever (body, _) ->
      names_used_in_stmts body
  | S.SRepeat (_, body, other, _) ->
      names_used_in_stmts body
      @ (match other with Some o -> names_used_in_stmts o | None -> [])
  | _ -> []

(* ─── rules ───────────────────────────────────────────────────────────── *)

(* W1002 unused-binding: a `be x holds e` whose x never appears later. A leading
 * underscore marks an intentional discard and is exempt. *)
let rec unused_bindings (stmts : S.stmt list) : E.t list =
  match stmts with
  | [] -> []
  | S.SLet (x, _, loc) :: rest ->
      let here =
        if List.mem x (names_used_in_stmts rest)
           || String.length x = 0 || x.[0] = '_' then []
        else [ E.make ~range:loc E.Lint_unused_binding
                 (Printf.sprintf "binding '%s' is never used" x) ]
      in
      here @ unused_bindings rest
  | _ :: rest -> unused_bindings rest

(* W1003 unused-param: a parameter never used in the body ('_' exempt). *)
let unused_params (fn : S.fun_decl) : E.t list =
  let used = names_used_in_stmts fn.S.fn_body in
  List.filter_map (fun (p : S.param) ->
    if List.mem p.S.param_name used
       || (String.length p.S.param_name > 0 && p.S.param_name.[0] = '_')
    then None
    else Some (E.make ~range:fn.S.fn_loc E.Lint_unused_param
                 (Printf.sprintf "parameter '%s' of '%s' is never used"
                    p.S.param_name fn.S.fn_name)))
    fn.S.fn_params

(* Every function name USED anywhere in the program: not just from `fun` bodies,
 * but from morph / geomorph / reduction / topology / functor bodies and
 * nat-transform targets. In Yon a Space's functions are its API, invoked
 * cross-Space (a subscriber calls a producer, a morph maps an object), NOT from a
 * single entry `main` -- so "reachable from main" would wrongly call a producer
 * dead. The right notion is "referenced nowhere". *)
let used_function_names (prog : S.program) : string list =
  List.concat_map
    (function
      | S.TopFun f -> names_used_in_stmts f.S.fn_body
      | S.TopGeomMorphism gm ->
          (match gm.S.gm_pull with Some fd -> names_used_in_stmts fd.S.fn_body | None -> [])
          @ (match gm.S.gm_push with Some fd -> names_used_in_stmts fd.S.fn_body | None -> [])
      | S.TopMorph mp ->
          (match mp.S.mp_on_object with Some fd -> names_used_in_stmts fd.S.fn_body | None -> [])
      | S.TopReduction rd ->
          List.concat_map
            (function
              | S.RcOn (_, _, body, _) -> names_used_in_stmts body
              | S.RcLet (_, e, _) -> names_in_expr e)
            rd.S.rd_clauses
      | S.TopTopology tp -> names_used_in_stmts tp.S.tp_body
      | S.TopFunctor ft -> names_in_expr ft.S.ft_body
      | S.TopNatTransform nt -> List.map snd nt.S.nt_via_bindings
      | _ -> [])
    prog

(* W1001 dead-function: a top-level fun referenced nowhere in the program
 * (`main` and a leading-underscore name are exempt). *)
let dead_functions (prog : S.program) : E.t list =
  let used = used_function_names prog in
  List.filter_map
    (function
      | S.TopFun f ->
          if f.S.fn_name = "main" || List.mem f.S.fn_name used
             || (String.length f.S.fn_name > 0 && f.S.fn_name.[0] = '_')
          then None
          else Some (E.make ~range:f.S.fn_loc E.Lint_dead_function
                       (Printf.sprintf "function '%s' is never used" f.S.fn_name))
      | _ -> None)
    prog

(* W3001 unused-import: an `import <m>::<name> from <S>` whose symbol never appears
 * in any function body -- a Space dependency with no traffic. Conservative: it
 * collects uses from every function body and matches both the bare and the
 * qualified name, so a used import is never flagged. *)
let unused_imports (prog : S.program) : E.t list =
  let used =
    List.concat_map
      (function S.TopFun f -> names_used_in_stmts f.S.fn_body | _ -> [])
      prog in
  List.filter_map
    (function
      | S.TopImportFrom (m, name, sp, loc) ->
          if List.mem name used || List.mem (m ^ "::" ^ name) used then None
          else Some (E.make ~range:loc E.Lint_unused_import
                       (Printf.sprintf
                          "import '%s' from Space %s is never used" name sp))
      | _ -> None)
    prog

(* ─── driver ───────────────────────────────────────────────────────────── *)

let lint_program (prog : S.program) : E.t list =
  let funs = List.filter_map (function S.TopFun f -> Some f | _ -> None) prog in
  dead_functions prog
  @ List.concat_map unused_params funs
  @ List.concat_map (fun f -> unused_bindings f.S.fn_body) funs
  @ unused_imports prog
