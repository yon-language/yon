(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* algebra_models.ml — the operations a model takes from its carrier.
 *
 * An algebra may declare its carrier models (`carried by C` in its body):
 * the carrier C is a model, with the machine's operation for each symbol of
 * the algebra (`as "+"` is the machine's sum on C, `as "0"` its zero). A place
 * carried by C that uses the algebra and does not give one of its operations
 * takes it from that model: the place receives the fun of the operation, of
 * the operation's type read on the place, whose body is the machine's
 * operation on the carrier. Inside the house a place is its carrier, so the
 * body is the carrier's own term. A fun the place gives itself is kept: the
 * implementation is its own and the laws are certified on it. An algebra not
 * listed is never taken, whatever the carrier models. *)

module S = Surface_ast

(* The machine's term of a symbol on its arguments, if the symbol has one. *)
let machine_term (symbol : string) (args : S.expr list) (loc : S.location) : S.expr option =
  match symbol, args with
  | "+", [a; b] -> Some (S.EBinop (S.OpAdd, a, b, loc))
  | "-", [a; b] -> Some (S.EBinop (S.OpSub, a, b, loc))
  | "-", [a] -> Some (S.EBinop (S.OpSub, S.ELit (S.LitNumber 0., loc), a, loc))
  | "*", [a; b] -> Some (S.EBinop (S.OpMul, a, b, loc))
  | s, [] when s <> "" && String.for_all (fun c -> c >= '0' && c <= '9') s ->
      Hashtbl.replace S.exact_int_literals (loc.S.file, loc.S.start_line, loc.S.start_col) s;
      Some (S.ELit (S.LitNumber (float_of_string s), loc))
  | _ -> None

let gives (p : S.program) (house : string) (name : string) : bool =
  List.exists (function
    | S.TopFun fd -> (fd.S.fn_home = Some house && fd.S.fn_name = name)
                     || fd.S.fn_name = house ^ "__" ^ name
    | _ -> false) p

(* ─── the derived operations ──────────────────────────────────────────
   A fun in the body of an algebra is a derived operation: a composite of the
   algebra's operations, over its name as the carrier. In a model it is that
   composite interpreted there: the model put for the carrier. Each model that
   does not give the fun itself receives its instance, read again from the
   fun's source with the model's name for the algebra's and every call of an
   operation (or of another derived operation) addressed to the model; the
   instance is a fun of the model, `P.name`, and the algebra keeps no fun of
   its own to run. *)

let is_ident_char c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c = '_'

(* The source of a declaration, by its span. *)
let readable (file : string) : string =
  if Sys.file_exists file then file
  else
    (* a location may carry the working directory before an absolute path
       (`/cwd//abs/path`): the absolute path is the file *)
    let rec find i = if i + 1 >= String.length file then None
      else if file.[i] = '/' && file.[i + 1] = '/' then Some (i + 1) else find (i + 1) in
    match find 0 with
    | Some i -> String.sub file i (String.length file - i)
    | None -> file

let source_of (loc : S.location) : string option =
  try
    let ic = open_in_bin (readable loc.S.file) in
    let n = in_channel_length ic in
    let text = really_input_string ic n in
    close_in ic;
    let lines = String.split_on_char '\n' text in
    let line k = List.nth lines (k - 1) in
    if loc.S.start_line = loc.S.end_line then
      Some (String.sub (line loc.S.start_line) loc.S.start_col (loc.S.end_col - loc.S.start_col))
    else begin
      let b = Buffer.create 256 in
      let first = line loc.S.start_line in
      Buffer.add_string b (String.sub first loc.S.start_col (String.length first - loc.S.start_col));
      for k = loc.S.start_line + 1 to loc.S.end_line - 1 do
        Buffer.add_char b '\n'; Buffer.add_string b (line k)
      done;
      Buffer.add_char b '\n';
      Buffer.add_string b (String.sub (line loc.S.end_line) 0 loc.S.end_col);
      Some (Buffer.contents b)
    end
  with _ -> None

(* The algebra's name replaced by the model's, and each call of a name in
   `calls` (not after a dot, not the name a `fun` declares) addressed to the
   model. *)
let instantiate_text (text : string) (algebra : string) (model : string) (calls : string list) (constants : string list) : string =
  let b = Buffer.create (String.length text + 64) in
  let n = String.length text in
  let rec next_non_space i = if i < n && (text.[i] = ' ' || text.[i] = '\t') then next_non_space (i + 1) else i in
  let last_word = ref "" in
  let rec go i prev_dot =
    if i >= n then ()
    else if is_ident_char text.[i] && not (text.[i] >= '0' && text.[i] <= '9') then begin
      let j = ref i in
      while !j < n && is_ident_char text.[!j] do incr j done;
      let w = String.sub text i (!j - i) in
      let k = next_non_space !j in
      if w = algebra then Buffer.add_string b model
      else if List.mem w calls && not prev_dot && !last_word <> "fun" && (List.mem w constants || (k < n && text.[k] = '(')) then
        Buffer.add_string b (model ^ "." ^ w)
      else Buffer.add_string b w;
      last_word := w;
      go !j false
    end else begin
      Buffer.add_char b text.[i];
      if text.[i] <> ' ' && text.[i] <> '\t' && text.[i] <> '\n' then last_word := "";
      go (i + 1) (text.[i] = '.')
    end in
  go 0 false;
  Buffer.contents b

let parse_instance (file : string) (first_line : int) (text : string) : S.program =
  let lexbuf = Lexing.from_string text in
  Lexing.set_filename lexbuf file;
  lexbuf.Lexing.lex_curr_p <- { lexbuf.Lexing.lex_curr_p with Lexing.pos_lnum = first_line };
  Lexer.reset_statement ();
  Parser_state.reset ();
  let prog = Parser.program Lexer.token lexbuf in
  prog @ Parser_state.drain ()

let derived (p : S.program) (algebra : string) : S.fun_decl list =
  List.filter_map (function
    | S.TopFun fd when fd.S.fn_home = Some algebra -> Some fd | _ -> None) p

let instances (p : S.program) (places : S.place_decl list) : S.top_decl list =
  List.concat_map (fun (pd : S.place_decl) ->
    let algebras = match Hashtbl.find_opt S.place_algebras pd.S.pd_name with Some l -> l | None -> [] in
    List.concat_map (fun a ->
      match List.find_opt (fun (x : S.place_decl) -> x.S.pd_name = a) places with
      | Some apd when Hashtbl.mem S.algebra_places a ->
          let ops = List.filter_map (function S.FoOp o -> Some o.S.op_name | _ -> None) apd.S.pd_members in
          let ds = derived p a in
          let calls = ops @ List.map (fun (fd : S.fun_decl) -> fd.S.fn_name) ds in
          let constants = List.filter_map (function
              | S.FoOp o when o.S.op_params = [] -> Some o.S.op_name
              | _ -> None) apd.S.pd_members in
          List.concat_map (fun (fd : S.fun_decl) ->
            if gives p pd.S.pd_name fd.S.fn_name then []
            else match source_of fd.S.fn_loc with
              | None ->
                  failwith (Printf.sprintf
                    "the derived operation %s of %s could not be read from %s, so %s has no instance of it"
                    fd.S.fn_name a fd.S.fn_loc.S.file pd.S.pd_name)
              | Some text ->
                  let text = String.make fd.S.fn_loc.S.start_col ' '
                             ^ instantiate_text text a pd.S.pd_name calls constants in
                  (* the instance's site: the source of the derived operation,
                     named with its model, so no two instances share a site *)
                  let file = Printf.sprintf "%s (%s.%s in %s)"
                      fd.S.fn_loc.S.file a fd.S.fn_name pd.S.pd_name in
                  List.map (function
                    | S.TopFun g -> S.TopFun { g with S.fn_name = pd.S.pd_name ^ "__" ^ g.S.fn_name }
                    | d -> d)
                    (parse_instance file fd.S.fn_loc.S.start_line text))
            ds
      | _ -> []) algebras) places

(* ─── the signature read whole ────────────────────────────────────────
   `this < B` between algebras: the models of the heir are a subobject of the
   models of B. The heir's signature is B's read with the heir's name for the
   carrier, with what the heir adds. An operation the heir declares again keeps
   its own symbol; a law comes down with the operations it speaks of, so what
   is stated once on a signature holds on each instance below it. *)

let rec read_carrier_ty (from_ : string) (into : string) (t : S.ty) : S.ty =
  let go = read_carrier_ty from_ into in
  match t with
  | S.TyUser x when x = from_ -> S.TyUser into
  | S.TyArrow (a, b) -> S.TyArrow (go a, go b)
  | t -> t

let inherit_member (parent : string) (heir : string) (own : S.field_or_op list) (m : S.field_or_op)
    : S.field_or_op option =
  let read = read_carrier_ty parent heir in
  match m with
  | S.FoOp o ->
      if List.exists (function S.FoOp x -> x.S.op_name = o.S.op_name | _ -> false) own then None
      else Some (S.FoOp { o with
                          S.op_params = List.map (fun (q : S.param) ->
                              { q with S.param_ty = read q.S.param_ty }) o.S.op_params;
                          op_return = Option.map read o.S.op_return })
  | S.FoLaw (law, st) ->
      if List.exists (function S.FoLaw (x, _) -> x = law | _ -> false) own then None
      else begin
        let origin = match Hashtbl.find_opt S.law_origin (parent, law) with
          | Some o -> o | None -> parent in
        Hashtbl.replace S.law_origin (heir, law) origin;
        Some (S.FoLaw (law, Option.map (fun (s : S.law_statement) ->
            { s with S.ls_quants = List.map (fun (q, x, t) -> (q, x, read t)) s.S.ls_quants }) st))
      end
  | _ -> None

let read_signatures (p : S.program) : S.program =
  let algebras = Hashtbl.create 8 in
  List.iter (function
    | S.TopPlace pd when Hashtbl.mem S.algebra_places pd.S.pd_name ->
        Hashtbl.replace algebras pd.S.pd_name pd
    | _ -> ()) p;
  let read = Hashtbl.create 8 in
  let rec whole (seen : string list) (pd : S.place_decl) : S.place_decl =
    match Hashtbl.find_opt read pd.S.pd_name with
    | Some done_ -> done_
    | None ->
        let parent = match pd.S.pd_subcontains with
          | Some b when not (List.mem b seen) -> Hashtbl.find_opt algebras b
          | _ -> None in
        let result = match parent with
          | None -> pd
          | Some parent ->
              let up = whole (pd.S.pd_name :: seen) parent in
              let came_down = List.filter_map
                  (inherit_member up.S.pd_name pd.S.pd_name pd.S.pd_members) up.S.pd_members in
              Hashtbl.replace S.algebra_ancestors pd.S.pd_name
                (up.S.pd_name :: Option.value ~default:[]
                                   (Hashtbl.find_opt S.algebra_ancestors up.S.pd_name));
              let laws = List.filter_map (function S.FoLaw (l, _) -> Some l | _ -> None) came_down in
              { pd with S.pd_members = came_down @ pd.S.pd_members;
                        pd_laws = laws @ pd.S.pd_laws } in
        Hashtbl.replace S.algebra_ops pd.S.pd_name
          (List.filter_map (function S.FoOp o -> Some o.S.op_name | _ -> None) result.S.pd_members);
        Hashtbl.replace read pd.S.pd_name result;
        result in
  List.map (function
    | S.TopPlace pd when Hashtbl.mem S.algebra_places pd.S.pd_name -> S.TopPlace (whole [] pd)
    | d -> d) p

(* ─── a fun whose parameter uses a signature ──────────────────────────
   `fun f<T uses Monoid>(xs: List<T>): T`. An instance of T is a model, and a
   model of a signature is its arrows: the fun receives them after the arguments
   the program writes, `T.op` is the arrow received, and the checker gives them
   at each call, from the model it resolves there. One fun, checked once,
   parametric in T. *)

let dictionary_type (signature : S.place_decl) (t : string) (o : S.operation_decl) : S.ty =
  let read = read_carrier_ty signature.S.pd_name t in
  let ret = match o.S.op_return with Some r -> read r | None -> S.TyUser t in
  List.fold_right (fun (q : S.param) acc -> S.TyArrow (read q.S.param_ty, acc)) o.S.op_params ret

let elaborate_bounded (p : S.program) : S.program =
  let places = List.filter_map (function
      | S.TopPlace pd when Hashtbl.mem S.algebra_places pd.S.pd_name -> Some (pd.S.pd_name, pd)
      | _ -> None) p in
  let a_law x = List.exists (fun (_, (pd : S.place_decl)) ->
      List.exists (function S.FoLaw (l, _) -> l = x | _ -> false) pd.S.pd_members) places in
  List.map (function
    | S.TopFun fd when Hashtbl.mem S.fun_bounds (S.site_of fd.S.fn_loc) ->
        let bounds = Hashtbl.find S.fun_bounds (S.site_of fd.S.fn_loc) in
        (* the bound that names no algebra is refused at each call, by the checker *)
        let known = List.filter_map (fun (t, a) ->
            Option.map (fun pd -> (t, a, pd)) (List.assoc_opt a places)) bounds in
        let ops_of (pd : S.place_decl) = List.filter_map (function
            | S.FoOp o -> Some o | _ -> None) pd.S.pd_members in
        let asked = ref [] in
        let rewrite (e : S.expr) : S.expr option =
          let member t x =
            List.exists (fun (t', _, pd) -> t' = t
              && List.exists (fun (o : S.operation_decl) -> o.S.op_name = x) (ops_of pd)) known in
          match e with
          | S.ECall (f, args, l) ->
              (match String.index_opt f '_' with
               | Some i when i + 1 < String.length f && f.[i + 1] = '_' ->
                   let t = String.sub f 0 i
                   and x = String.sub f (i + 2) (String.length f - i - 2) in
                   if member t x then
                     Some (S.ECall (S.bound_param t x, args, l))
                   else None
               | _ -> None)
          | S.EField (S.EVar (t, _), x, l) when member t x -> Some (S.EVar (S.bound_param t x, l))
          | S.EField (S.EVar (t, _), x, l)
            when List.exists (fun (t', _, _) -> t' = t) known && a_law x ->
              if not (List.mem (t, x) !asked) then asked := !asked @ [(t, x)];
              Some (S.EVar (S.bound_param t x, l))
          | _ -> None in
        (* the arguments of an arrow received are read again too *)
        let rec rewrite_deep (e : S.expr) : S.expr option =
          match rewrite e with
          | Some (S.ECall (f, args, l)) ->
              Some (S.ECall (f, List.map (Method_sugar.map_expr rewrite_deep) args, l))
          | r -> r in
        let body = List.map (Method_sugar.map_stmt rewrite_deep) fd.S.fn_body in
        let dictionary = List.concat_map (fun (t, _, pd) ->
            List.map (fun (o : S.operation_decl) ->
                { S.param_name = S.bound_param t o.S.op_name;
                  param_ty = dictionary_type pd t o }) (ops_of pd)
            @ List.filter_map (fun (t', x) ->
                if t' = t then Some { S.param_name = S.bound_param t x; param_ty = S.TyPrim "boolean" }
                else None) !asked) known in
        let info = {
          S.bf_written = List.length fd.S.fn_params;
          bf_tparams = fd.S.fn_type_params;
          bf_bounds = List.map (fun (t, a) ->
              (t, a,
               match List.find_opt (fun (t', _, _) -> t' = t) known with
               | Some (_, _, pd) ->
                   List.map (fun (o : S.operation_decl) -> S.BoundOp o.S.op_name) (ops_of pd)
                   @ List.filter_map (fun (t', x) -> if t' = t then Some (S.BoundLaw x) else None) !asked
               | None -> [])) bounds } in
        Hashtbl.replace S.bounded_funs
          (match fd.S.fn_home with Some h -> h ^ "__" ^ fd.S.fn_name | None -> fd.S.fn_name) info;
        S.TopFun { fd with S.fn_params = fd.S.fn_params @ dictionary; fn_body = body }
    | d -> d) p

let complete (p : S.program) : S.program =
  let space_of = S.space_of_file in
  let p = read_signatures p in
  let places = List.filter_map (function S.TopPlace pd -> Some pd | _ -> None) p in
  let find a = List.find_opt (fun (pd : S.place_decl) -> pd.S.pd_name = a) places in
  let added = ref [] in
  List.iter (fun (pd : S.place_decl) ->
    match pd.S.pd_fusion, Hashtbl.find_opt S.place_algebras pd.S.pd_name with
    | Some carrier, Some algebras ->
        List.iter (fun a ->
          match find a, Hashtbl.find_opt S.carrier_models a with
          | Some apd, Some models
            when List.exists (fun (c, _, _) -> c = carrier) models
                 (* an internal instance is its carrier inside its Space only:
                    outside, the carrier is opaque, and no model there takes
                    the machine's operations from it *)
                 && (not (Hashtbl.mem S.internal_carrier_sites
                            (apd.S.pd_loc.S.file, apd.S.pd_loc.S.start_line,
                             apd.S.pd_loc.S.start_col))
                     || space_of pd.S.pd_loc.S.file = space_of apd.S.pd_loc.S.file) ->
              (* the site of the fun is the `carried by` line of the algebra
                 (a prelude site when the algebra is the prelude's), one
                 column per place and operation *)
              let (_, _, mloc) = List.find (fun (c, _, _) -> c = carrier) models in
              let named (o : S.operation_decl) = S.model_fun pd.S.pd_name a o.S.op_name in
              let ops = List.filter_map (function S.FoOp o -> Some o | _ -> None) apd.S.pd_members in
              if ops <> [] && List.for_all (fun o -> not (gives p pd.S.pd_name (named o))) ops then
                Hashtbl.replace S.carrier_taken (pd.S.pd_name, a) ();
              List.iteri (fun i m ->
                match m with
                | S.FoOp o when not (gives p pd.S.pd_name (named o)) ->
                    let col = 1000 + (Hashtbl.hash (pd.S.pd_name, a) land 0xfff) * 64 + i in
                    let loc = { mloc with S.start_col = col; end_col = col + 1;
                                          end_line = mloc.S.start_line } in
                    let read t = match t with
                      | S.TyUser x when x = a -> S.TyUser pd.S.pd_name | t -> t in
                    let params = List.map (fun (q : S.param) ->
                        { q with S.param_ty = read q.S.param_ty }) o.S.op_params in
                    let args = List.map (fun (q : S.param) -> S.EVar (q.S.param_name, loc)) params in
                    (match o.S.op_symbol with
                     | Some sym ->
                         (match machine_term sym args loc with
                          | Some body ->
                              if params = [] then
                                Hashtbl.replace S.bare_nullary_decls
                                  (loc.S.file, loc.S.start_line, loc.S.start_col) ();
                              added := S.TopFun {
                                  S.fn_name = named o;
                                  fn_type_params = [];
                                  fn_params = params;
                                  fn_return = Some (match o.S.op_return with
                                                    | Some t -> read t
                                                    | None -> S.TyUser pd.S.pd_name);
                                  fn_on_error = None;
                                  fn_home = Some pd.S.pd_name;
                                  fn_visits = [];
                                  fn_internal = false;
                                  fn_given = false;
                                  fn_body = [S.SReturn (body, loc)];
                                  fn_loc = loc } :: !added
                          | None -> ())
                     | None -> ())
                | _ -> ()) apd.S.pd_members
          | _ -> ()) algebras
    | _ -> ()) places;
  let completed = p @ List.rev !added in
  (* the derived operations: an instance in each model; the algebra keeps none *)
  let inst = instances completed places in
  (* an instance on a carrier is a model of itself: its operations are the
     machine's of the carrier, funs of its house, the one access to its values
     where the carrier is opaque *)
  let own = List.concat_map (fun (apd : S.place_decl) ->
      let a = apd.S.pd_name in
      match Hashtbl.find_opt S.carrier_models a, apd.S.pd_fusion with
      | Some [(c, _, mloc)], Some c' when c = c' ->
          List.concat (List.mapi (fun i m ->
            match m with
            | S.FoOp o ->
                let col = 2000 + (Hashtbl.hash a land 0xfff) * 64 + i in
                let loc = { mloc with S.start_col = col; end_col = col + 1;
                                      end_line = mloc.S.start_line } in
                let args = List.map (fun (q : S.param) -> S.EVar (q.S.param_name, loc)) o.S.op_params in
                (match o.S.op_symbol with
                 | Some sym ->
                     (match machine_term sym args loc with
                      | Some body ->
                          if o.S.op_params = [] then
                            Hashtbl.replace S.bare_nullary_decls
                              (loc.S.file, loc.S.start_line, loc.S.start_col) ();
                          [S.TopFun {
                              S.fn_name = S.model_fun a a o.S.op_name;
                              fn_type_params = [];
                              fn_params = o.S.op_params;
                              fn_return = Some (Option.value ~default:(S.TyUser a) o.S.op_return);
                              fn_on_error = None;
                              fn_home = Some a;
                              fn_visits = [];
                              fn_internal = false;
                              fn_given = false;
                              fn_body = [S.SReturn (body, loc)];
                              fn_loc = loc }]
                      | None -> [])
                 | None -> [])
            | _ -> []) apd.S.pd_members)
      | _ -> []) (List.filter (fun (pd : S.place_decl) -> Hashtbl.mem S.algebra_places pd.S.pd_name) places) in
  List.filter (function
    | S.TopFun fd -> (match fd.S.fn_home with
                      | Some h -> not (Hashtbl.mem S.algebra_places h) | None -> true)
    | _ -> true) completed
  @ inst @ own
  |> elaborate_bounded
