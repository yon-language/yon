(* pretty.ml — pretty printer for Yon Core
 *
 * Produces readable surface-Yon-style output from internal AST.
 * Used for debugging reductions and inspecting intermediate states.
 *)

open Ast

let rec pp_ty t =
  match t with
  | TyType 0 -> "Type"
  | TyType n -> Printf.sprintf "Type_%d" n
  | TyArrow (a, b) -> Printf.sprintf "(%s -> %s)" (pp_ty a) (pp_ty b)
  | TyPi (x, a, b) ->
      Printf.sprintf "Pi(%s : %s). %s" x (pp_ty a) (pp_ty b)
  | TySigma (x, a, b) ->
      Printf.sprintf "Sigma(%s : %s). %s" x (pp_ty a) (pp_ty b)
  | TyId (a, _, _) ->
      Printf.sprintf "Id_%s" (pp_ty a)
  | TyPlace n -> n
  | TyStream t' -> Printf.sprintf "stream of %s" (pp_ty t')
  | TyDirUniverse n -> Printf.sprintf "U_omega_%d" n
  | TyEl _ -> "El(...)"
  | TyGlue (a, _, _) -> Printf.sprintf "Glue(%s)" (pp_ty a)
  | TyPathP ((i, a), _, _) -> Printf.sprintf "PathP(<%s> %s)" i (pp_ty a)

let pp_op_sig op =
  let params_str =
    String.concat ", "
      (List.map (fun (n, t) -> Printf.sprintf "%s: %s" n (pp_ty t)) op.op_params)
  in
  Printf.sprintf "operation %s(%s): %s" op.op_name params_str (pp_ty op.op_return)

let rec pp_interval = function
  | I0 -> "0"
  | I1 -> "1"
  | IVar i -> i
  | IMin (a, b) -> Printf.sprintf "(%s /\\ %s)" (pp_interval a) (pp_interval b)
  | IMax (a, b) -> Printf.sprintf "(%s \\/ %s)" (pp_interval a) (pp_interval b)
  | INeg a -> Printf.sprintf "~%s" (pp_interval a)

let rec pp_term ?(indent = 0) t =
  let prefix = String.make indent ' ' in
  match t with
  | Var x -> x
  | Lam (x, ty, body) ->
      Printf.sprintf "lambda%s:%s. %s" x (pp_ty ty) (pp_term ~indent body)
  | App (f, a) ->
      Printf.sprintf "(%s %s)" (pp_term ~indent f) (pp_term ~indent a)
  | Place p ->
      let fields_str =
        if p.p_fields = [] then ""
        else
          "\n" ^ prefix ^ "  "
          ^ String.concat
              ("\n" ^ prefix ^ "  ")
              (List.map (fun (n, t) -> Printf.sprintf "%s %s" n (pp_ty t)) p.p_fields)
      in
      let ops_str =
        if p.p_operations = [] then ""
        else
          "\n" ^ prefix ^ "  "
          ^ String.concat ("\n" ^ prefix ^ "  ") (List.map pp_op_sig p.p_operations)
      in
      let effects_marker = if p.p_operations = [] then "" else " with effects" in
      Printf.sprintf "place %s : %s%s {%s%s\n%s}" p.p_name (pp_ty p.p_site)
        effects_marker fields_str ops_str prefix
  | Reduction r ->
      let multi_str = if r.r_multi_shot then " with multi_shot" else "" in
      let handlers_str =
        String.concat
          ("\n" ^ prefix ^ "  ")
          (List.map (pp_handler ~indent:(indent + 2)) r.r_handlers)
      in
      Printf.sprintf "reduction %s of %s%s {\n%s  %s\n%s}" r.r_name r.r_target
        multi_str prefix handlers_str prefix
  | Scope (s, body) ->
      Printf.sprintf "⟨%s⟩_%s" (pp_term ~indent body) s
  | With (r, body) ->
      Printf.sprintf "with %s in %s" r (pp_term ~indent body)
  | Emit t' -> Printf.sprintf "emit %s" (pp_term ~indent t')
  | Refl t' -> Printf.sprintf "refl(%s)" (pp_term ~indent t')
  | J (x, ty, c, d, p, b) ->
      Printf.sprintf "J[%s:%s. %s, %s, %s, %s]"
        x (pp_ty ty) (pp_term ~indent c) (pp_term ~indent d)
        (pp_term ~indent p) (pp_term ~indent b)
  | Pair (a, b) ->
      Printf.sprintf "(%s, %s)" (pp_term ~indent a) (pp_term ~indent b)
  | Fst t' -> Printf.sprintf "fst %s" (pp_term ~indent t')
  | Snd t' -> Printf.sprintf "snd %s" (pp_term ~indent t')
  | StreamCons (h, k) ->
      Printf.sprintf "%s :: %s" (pp_term ~indent h) (pp_term ~indent k)
  | Unit -> "()"
  | PLam (i, t') -> Printf.sprintf "<%s> %s" i (pp_term ~indent t')
  | PApp (p, r) -> Printf.sprintf "(%s @ %s)" (pp_term ~indent p) (pp_interval r)
  | Transp ((i, a), t') ->
      Printf.sprintf "transp <%s>%s %s" i (pp_ty a) (pp_term ~indent t')
  | Comp (_, _, _, base) -> Printf.sprintf "comp[..] %s" (pp_term ~indent base)
  | HComp (_, _, _, base) -> Printf.sprintf "hcomp[..] %s" (pp_term ~indent base)
  | GlueElem (_, t', a') -> Printf.sprintf "glue(%s, %s)" (pp_term ~indent t') (pp_term ~indent a')
  | Unglue t' -> Printf.sprintf "unglue(%s)" (pp_term ~indent t')
  | HITElim (branches, scrut) ->
      Printf.sprintf "hit_elim([%s], %s)"
        (String.concat "; "
           (List.map (fun (n, b) -> Printf.sprintf "%s => %s" n (pp_term ~indent b)) branches))
        (pp_term ~indent scrut)
  | HITConstr (n, args) ->
      Printf.sprintf "%s(%s)" n (String.concat ", " (List.map (pp_term ~indent) args))

and pp_handler ?(indent = 0) h =
  let _ = indent in
  let params_str =
    String.concat ", "
      (List.map (fun (n, t) -> Printf.sprintf "%s: %s" n (pp_ty t)) h.hc_params)
  in
  Printf.sprintf "on %s(%s) ↦ %s" h.hc_op params_str (pp_term h.hc_body)

(* Compact representation for one-line debug output. *)
let pp_compact t =
  let s = pp_term t in
  (* Replace newlines with " | " for one-line display *)
  String.map (fun c -> if c = '\n' then ' ' else c) s
