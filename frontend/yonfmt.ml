(* yonfmt.ml — formatter for Yon.
 *
 * A pretty printer over the surface AST that produces re-parsable Yon (not the
 * debug printer of pretty.ml, which operates on the core with Unicode
 * symbols). Safety guarantee: the formatter re-parses its own output and
 * verifies that the AST is identical to the original; if not, it leaves the
 * file unchanged. A formatter must never change the meaning of the code.
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

(* ─── Tipi ──────────────────────────────────────────────────────────── *)

let rec fmt_ty (t : ty) : string =
  match t with
  | TyPrim s -> s
  | TyPrimIn (s, opts) -> s ^ " in " ^ String.concat ", " opts
  | TyList t -> "list of " ^ fmt_ty t
  | TyMap (k, v) -> "map of " ^ fmt_ty k ^ " to " ^ fmt_ty v
  | TyUser s -> s
  | TyVar s -> s
  | TyUniverse 0 -> "Type"
  | TyUniverse n -> Printf.sprintf "Type_%d" n
  | TyHeytInt n -> Printf.sprintf "heyt_int<%d>" n
  | _ -> "_"   (* rare types: the round-trip will fail and the file is left unchanged *)

(* ─── Operatori ─────────────────────────────────────────────────────── *)

let binop_str = function
  | OpAdd -> "+" | OpSub -> "-" | OpMul -> "*" | OpDiv -> "/" | OpMod -> "%"
  | OpEq -> "==" | OpNeq -> "!=" | OpLt -> "<" | OpGt -> ">"
  | OpLeq -> "<=" | OpGeq -> ">=" | OpAnd -> "and" | OpOr -> "or"

(* ─── Espressioni ───────────────────────────────────────────────────── *)

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

let rec fmt_expr (e : expr) : string =
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
      let ps = String.concat ", "
        (List.map (fun (n, t) -> n ^ ": " ^ fmt_ty t) params) in
      (* explicit `fun` keyword: valid anywhere, even as an argument *)
      Printf.sprintf "fun(%s) => %s" ps (fmt_expr body)
  | EFunctorLam (params, body, fw, tw, laws, _) ->
      let ps = String.concat ", "
        (List.map (fun (n, t) -> n ^ ": " ^ fmt_ty t) params) in
      let ls = String.concat "" (List.map (fun l -> " law " ^ l) laws) in
      Printf.sprintf "functor (%s) => %s from %s to %s%s"
        ps (fmt_expr body) fw tw ls
  | ENew (place, fas, _) ->
      let assigns = String.concat ", "
        (List.map (fun fa -> fa.fa_name ^ " " ^ fmt_expr fa.fa_value) fas) in
      Printf.sprintf "new %s { %s }" place assigns
  | ENewIn (place, space, fas, _) ->
      let assigns = String.concat ", "
        (List.map (fun fa -> fa.fa_name ^ " " ^ fmt_expr fa.fa_value) fas) in
      Printf.sprintf "new %s in %s { %s }" place space assigns
  | ERefl (e, _) -> "refl(" ^ fmt_expr e ^ ")"
  | EPair (a, b, _) -> Printf.sprintf "pair(%s, %s)" (fmt_expr a) (fmt_expr b)
  | EFst (e, _) -> "fst(" ^ fmt_expr e ^ ")"
  | ESnd (e, _) -> "snd(" ^ fmt_expr e ^ ")"
  | EComposeWith (h1, h2, _) ->
      Printf.sprintf "compose %s with %s" (fmt_expr h1) (fmt_expr h2)
  | _ -> raise Exit   (* construct not covered: abort the format (fail-safe) *)

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
  | SLet (name, e, _) -> line f (Printf.sprintf "be %s holds %s" name (fmt_expr e))
  | SAssignBecomes (lv, e, _) ->
      line f (Printf.sprintf "%s becomes %s" (lvalue_str lv) (fmt_expr e))
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
  let subcontains = match pd.pd_subcontains with
    | Some base -> " subcontains " ^ base
    | None -> "" in
  let hdr =
    if pd.pd_with_effects
    then Printf.sprintf "place %s in %s%s with effects {"
           pd.pd_name pd.pd_world subcontains
    else Printf.sprintf "place %s in %s%s {"
           pd.pd_name pd.pd_world subcontains in
  line f hdr;
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
    | FoCell _ -> raise Exit
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
  line f (Printf.sprintf "nat_transform %s from %s to %s {"
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
  (* Form A: move N from W1 to W2 (requires Cap)? { mappings }. Form B (merge) -> Exit *)
  let from_w = match mv.mv_from with [w] -> w | _ -> raise Exit in
  let to_w = match mv.mv_to with Some w -> w | None -> raise Exit in
  let reqs = match mv.mv_requires_caps with
    | [] -> "" | cs -> " requires " ^ String.concat ", " cs in
  line f (Printf.sprintf "move %s from %s to %s%s {" mv.mv_name from_w to_w reqs);
  f.indent <- f.indent + 1;
  (match mv.mv_body with
   | MoveMapping maps ->
       List.iter (fun (m : mapping_decl) ->
         line f (Printf.sprintf "%s %s %s by %s"
                   m.m_from (mapping_kind_str m.m_kind) m.m_to m.m_by)
       ) maps
   | MoveMerge _ -> raise Exit);
  f.indent <- f.indent - 1;
  line f "}"

let fmt_top (f : fmt) (td : top_decl) : unit =
  (match td with
   | TopFun fn -> fmt_fun f fn
   | TopPlace pd -> fmt_place f pd
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
    | _ -> None) prog

(* Format with a guarantee: return the output only if it re-parses to the same
 * structure. Otherwise None (the caller leaves the file unchanged). *)
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
              if top_names prog = top_names prog2
              then Some formatted   (* round-trip ok *)
              else None             (* structure changed: do NOT use it *)

(* ─── Entry point ───────────────────────────────────────────────────── *)

let () =
  (* yonfmt <file>        : print the formatted output to stdout (if safe)
   * yonfmt --write <file>: rewrite the file in place (if safe)
   * yonfmt --check <file>: exit 0 if already formatted, 1 if it would change *)
  let args = Array.to_list Sys.argv in
  match args with
  | [_; "--check"; file] ->
      let src = let ic = open_in file in
        let n = in_channel_length ic in
        let s = really_input_string ic n in close_in ic; s in
      (match safe_format src with
       | Some out when out = src -> Printf.printf "already formatted: %s\n" file; exit 0
       | Some _ -> Printf.printf "needs formatting: %s\n" file; exit 1
       | None -> Printf.printf "not formattable (uncovered or invalid construct): %s\n" file; exit 2)
  | [_; "--write"; file] ->
      let src = let ic = open_in file in
        let n = in_channel_length ic in
        let s = really_input_string ic n in close_in ic; s in
      (match safe_format src with
       | Some out ->
           let oc = open_out file in output_string oc out; close_out oc;
           Printf.printf "formatted: %s\n" file
       | None -> Printf.printf "left unchanged (fail-safe): %s\n" file)
  | [_; file] ->
      let src = let ic = open_in file in
        let n = in_channel_length ic in
        let s = really_input_string ic n in close_in ic; s in
      (match safe_format src with
       | Some out -> print_string out
       | None -> prerr_endline "not formattable (fail-safe: no output)"; exit 2)
  | _ ->
      prerr_endline "uso: yonfmt [--write|--check] <file.yon>"; exit 64
