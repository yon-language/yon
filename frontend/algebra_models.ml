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

let complete (p : S.program) : S.program =
  let places = List.filter_map (function S.TopPlace pd -> Some pd | _ -> None) p in
  let find a = List.find_opt (fun (pd : S.place_decl) -> pd.S.pd_name = a) places in
  let added = ref [] in
  List.iter (fun (pd : S.place_decl) ->
    match pd.S.pd_fusion, Hashtbl.find_opt S.place_algebras pd.S.pd_name with
    | Some carrier, Some algebras ->
        List.iter (fun a ->
          match find a, Hashtbl.find_opt S.carrier_models a with
          | Some apd, Some models
            when List.exists (fun (c, _, _) -> c = carrier) models ->
              (* the site of the fun is the `carried by` line of the algebra
                 (a prelude site when the algebra is the prelude's), one
                 column per place and operation *)
              let (_, _, mloc) = List.find (fun (c, _, _) -> c = carrier) models in
              List.iteri (fun i m ->
                match m with
                | S.FoOp o when not (gives p pd.S.pd_name o.S.op_name) ->
                    let col = 1000 + (Hashtbl.hash pd.S.pd_name land 0xfff) * 64 + i in
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
                              added := S.TopFun {
                                  S.fn_name = o.S.op_name;
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
  p @ List.rev !added
