(* yon_lint.ml — linter for Yon.
 *
 * Complementary to the type checker: the tycheck REJECTS ill-typed programs
 * (errors, e.g. TOPOS-E1110/E1111 cross-space leakage). The linter only WARNS
 * about code that is well-typed but suspicious. It never rejects; it reports.
 *
 * Rules (all purely syntactic, reusing the frontend parser + free-variable
 * collector — no re-typecheck needed):
 *   L1 dead-function   : a top-level fun never reached from `main`
 *   L2 unused-binding  : `be x holds e` whose x is never used afterwards
 *   L3 unused-param    : a function parameter never used in the body
 *
 * Output: one line per warning `path:line: [Ln] message`. Exit 0 (lint is
 * advisory). With --strict, exit 1 if any warning is emitted. *)

module S = Surface_ast

(* ─── name collection over statements (reuses Desugar.free_vars_in_expr) ─── *)

(* All variable names USED in an expression (free names, given bound vars). *)
let names_in_expr (e : S.expr) : string list =
  Desugar.free_vars_in_expr [] e

(* Walk a statement list and collect every variable name used (read). Bindings
 * introduced by `be x holds` are NOT counted as uses; their RHS is. *)
let rec names_used_in_stmts (stmts : S.stmt list) : string list =
  List.concat_map names_used_in_stmt stmts

and names_used_in_stmt (s : S.stmt) : string list =
  match s with
  | S.SLet (_, e, _) -> names_in_expr e
  | S.SAssignHolds (_, e, _) | S.SAssignBecomes (_, e, _) -> names_in_expr e
  | S.SReturn (e, _) | S.SEmit (e, _) -> names_in_expr e
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
  | _ -> []

(* ─── warnings ─────────────────────────────────────────────────────────── *)

type warning = { line : int; code : string; msg : string }

(* L2 unused-binding: a `be x holds e` whose x never appears later in the body.
 * Scans within each function body. *)
let rec unused_bindings (stmts : S.stmt list) : warning list =
  match stmts with
  | [] -> []
  | S.SLet (x, _, loc) :: rest ->
      let used_later = List.mem x (names_used_in_stmts rest) in
      let here =
        if used_later || String.length x = 0 || x.[0] = '_' then []
        else [{ line = loc.S.start_line; code = "L2";
                msg = Printf.sprintf "binding '%s' is never used" x }]
      in
      here @ unused_bindings rest
  | _ :: rest -> unused_bindings rest

(* L3 unused-param: a parameter never used in the function body. *)
let unused_params (fn : S.fun_decl) : warning list =
  let used = names_used_in_stmts fn.S.fn_body in
  List.filter_map (fun (p : S.param) ->
    if List.mem p.S.param_name used
       || (String.length p.S.param_name > 0 && p.S.param_name.[0] = '_')
    then None
    else Some { line = fn.S.fn_loc.S.start_line; code = "L3";
                msg = Printf.sprintf "parameter '%s' of '%s' is never used"
                        p.S.param_name fn.S.fn_name })
    fn.S.fn_params

(* L1 dead-function: a top-level fun never reached transitively from `main`.
 * Reachability over the call graph (function name appears in another's body). *)
let dead_functions (funs : S.fun_decl list) : warning list =
  let names = List.map (fun f -> f.S.fn_name) funs in
  let calls_of (fn : S.fun_decl) : string list =
    List.filter (fun n -> List.mem n names) (names_used_in_stmts fn.S.fn_body)
  in
  let find name = List.find_opt (fun f -> f.S.fn_name = name) funs in
  (* transitive closure from main *)
  let rec reach seen frontier =
    match frontier with
    | [] -> seen
    | n :: rest ->
        if List.mem n seen then reach seen rest
        else
          let more = match find n with Some f -> calls_of f | None -> [] in
          reach (n :: seen) (more @ rest)
  in
  let reachable = if List.mem "main" names then reach [] ["main"] else names in
  List.filter_map (fun (f : S.fun_decl) ->
    if List.mem f.S.fn_name reachable || f.S.fn_name = "main" then None
    else Some { line = f.S.fn_loc.S.start_line; code = "L1";
                msg = Printf.sprintf "function '%s' is never reached from main"
                        f.S.fn_name })
    funs

(* ─── driver ───────────────────────────────────────────────────────────── *)

let lint_program (prog : S.program) : warning list =
  let funs = List.filter_map (function S.TopFun f -> Some f | _ -> None) prog in
  dead_functions funs
  @ List.concat_map unused_params funs
  @ List.concat_map (fun f -> unused_bindings f.S.fn_body) funs

let parse (source : string) : S.program option =
  let lexbuf = Lexing.from_string source in
  try Some (Parser.program Lexer.token lexbuf) with _ -> None

let () =
  let args = Array.to_list Sys.argv in
  let strict, file =
    match args with
    | [_; "--strict"; f] -> (true, Some f)
    | [_; f] -> (false, Some f)
    | _ -> (false, None)
  in
  match file with
  | None -> prerr_endline "uso: yon_lint [--strict] <file.yon>"; exit 64
  | Some path ->
      let ic = open_in path in
      let n = in_channel_length ic in
      let src = really_input_string ic n in
      close_in ic;
      (match parse src with
       | None -> Printf.eprintf "%s: parse error (run the compiler for details)\n" path; exit 65
       | Some prog ->
           let ws = lint_program prog in
           let ws = List.sort (fun a b -> compare a.line b.line) ws in
           List.iter (fun w ->
             Printf.printf "%s:%d: [%s] %s\n" path w.line w.code w.msg) ws;
           if ws = [] then Printf.printf "%s: no lint warnings\n" path;
           if strict && ws <> [] then exit 1 else exit 0)
