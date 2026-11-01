(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* prop_quantifiers.ml — the quantifiers of a prop, over a finite place.
 *
 * A prop is a proposition the program computes: its value is an element of
 * Omega. A quantifier of a prop carries its type, `∀x : T`.
 * Over a place of nullary arms the quantifier is the finite meet (∀) or join
 * (∃) in Omega of the statement at each arm, so the prop is that conjunction
 * or disjunction, exactly. Over any other type there is no finite meet the
 * program can compute: the prop keeps its quantifier, and the checker refuses
 * it with the reason. *)

module S = Surface_ast

let rec occurs (x : string) (e : S.expr) : bool =
  match e with
  | S.EVar (y, _) -> x = y
  | _ ->
      (* a block of statements is not read here: its variable may be there *)
      let (es, blocks) = S.sub_exprs e in
      List.exists (occurs x) es || blocks <> []

let rec subst (x : string) (v : S.expr) (e : S.expr) : S.expr =
  let s = subst x v in
  match e with
  | S.EVar (y, _) when y = x -> v
  | S.EParen (a, l) -> S.EParen (s a, l)
  | S.EBinop (o, a, b, l) -> S.EBinop (o, s a, s b, l)
  | S.ECall (f, args, l) -> S.ECall (f, List.map s args, l)
  | S.EIfThenElse (c, a, b, l) -> S.EIfThenElse (s c, s a, s b, l)
  | S.ENot (a, l) -> S.ENot (s a, l)
  | S.EField (a, f, l) -> S.EField (s a, f, l)
  | S.EHITElim (m, branches, sc, l) ->
      S.EHITElim (m, List.map (fun (c, pat, b) -> (c, pat, s b)) branches, s sc, l)
  | _ -> e

(* The arms of a finite place: a place of nullary arms. *)
let arms_of (places : S.place_decl list) (t : S.ty) : string list option =
  match t with
  | S.TyUser n ->
      (match List.find_opt (fun (pd : S.place_decl) -> pd.S.pd_name = n) places with
       | Some pd when pd.S.pd_arms <> []
                      && List.for_all (fun (v : S.variant) -> v.S.v_args = []) pd.S.pd_arms ->
           Some (List.map (fun (v : S.variant) -> v.S.v_name) pd.S.pd_arms)
       | _ -> None)
  | _ -> None

(* The statement with its quantifiers expanded from the innermost out; the
   quantifiers left are those whose type is not finite, or whose variable the
   substitution cannot reach. *)
let expand_prop (places : S.place_decl list) (pr : S.prop_decl) : S.prop_decl =
  match pr.S.pr_body_opt with
  | None -> pr
  | Some body ->
      let l = pr.S.pr_loc in
      let rec go qs body =
        match qs with
        | [] -> ([], body)
        | (k, x, t) :: rest ->
            let (left, inner) = go rest body in
            if left <> [] then ((k, x, t) :: left, inner)
            else
              match arms_of places t with
              | Some (a0 :: arms) ->
                  let cases = List.map (fun a -> subst x (S.EVar (a, l)) inner) (a0 :: arms) in
                  if List.exists (occurs x) cases then ([(k, x, t)], inner)
                  else
                    let op = match k with S.Forall -> "__heyt_and" | S.Exists -> "__heyt_or" in
                    ([], List.fold_left (fun acc c -> S.ECall (op, [acc; c], l))
                           (List.hd cases) (List.tl cases))
              | _ -> ([(k, x, t)], inner)
      in
      let (left, body') = go pr.S.pr_quants body in
      { pr with S.pr_quants = left; pr_body_opt = Some body' }

let expand (p : S.program) : S.program =
  let places = List.filter_map (function S.TopPlace pd -> Some pd | _ -> None) p in
  List.map (function
    | S.TopTopos td ->
        let places = td.S.tp_objects @ places in
        S.TopTopos { td with S.tp_props = List.map (expand_prop places) td.S.tp_props }
    | d -> d) p
