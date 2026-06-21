open Ast

type tctx = (string * ty) list

exception Check_error of string

let rctx = Reduce.empty_ctx

(* Unified conversion reducer. The checker's definitional equality uses the SAME
 * engine as the evaluator, so conversion now includes cubical computation
 * (transport / Glue / hcomp) and builtin arithmetic, not only beta/eta/J.
 * reduce_with_builtins is a strict superset of Reduce.reduce (it falls back to
 * Reduce.step), so the non-cubical fragment — Yoneda/J/eta witnesses — is
 * unchanged; the fuel bound gives conservative incompleteness, never
 * unsoundness. This removes the two-reducers split (one canonical conversion). *)
let reduce_full (t : term) : term = Builtins.reduce_with_builtins rctx t

let rec norm_ty (t : ty) : ty =
  match t with
  | TyType _ | TyDirUniverse _ | TyPlace _ -> t
  | TyArrow (a, b) -> TyArrow (norm_ty a, norm_ty b)
  | TyPi (x, a, b) -> TyPi (x, norm_ty a, norm_ty b)
  | TySigma (x, a, b) -> TySigma (x, norm_ty a, norm_ty b)
  | TyId (a, t1, t2) ->
      TyId (norm_ty a, reduce_full t1, reduce_full t2)
  | TyEl c -> TyEl (reduce_full c)
  | TyStream a -> TyStream (norm_ty a)
  | other -> other

let rec ty_conv (env : (string * string) list) (a : ty) (b : ty) : bool =
  match norm_ty a, norm_ty b with
  | TyType n, TyType m -> n = m
  | TyDirUniverse n, TyDirUniverse m -> n = m
  | TyPlace p, TyPlace q -> p = q
  | TyArrow (a1, b1), TyArrow (a2, b2) ->
      ty_conv env a1 a2 && ty_conv env b1 b2
  | TyArrow (a1, b1), TyPi (x, a2, b2) ->
      let probe = Pair (Unit, Unit) in
      let b2_probe = Subst.subst_term_in_ty x probe b2 in
      ty_conv env a1 a2
      && ty_conv env b2 b2_probe
      && ty_conv env b1 b2
  | TyPi (x, a1, b1), TyArrow (a2, b2) ->
      let probe = Pair (Unit, Unit) in
      let b1_probe = Subst.subst_term_in_ty x probe b1 in
      ty_conv env a1 a2
      && ty_conv env b1 b1_probe
      && ty_conv env b1 b2
  | TyPi (x, a1, b1), TyPi (y, a2, b2) ->
      ty_conv env a1 a2 && ty_conv ((x, y) :: env) b1 b2
  | TySigma (x, a1, b1), TySigma (y, a2, b2) ->
      ty_conv env a1 a2 && ty_conv ((x, y) :: env) b1 b2
  | TyId (t1, a1, b1), TyId (t2, a2, b2) ->
      ty_conv env t1 t2
      && term_equal_env env a1 a2
      && term_equal_env env b1 b2
  | TyEl c1, TyEl c2 -> term_equal_env env c1 c2
  | TyStream a1, TyStream a2 -> ty_conv env a1 a2
  | _ -> false

let rec sort_of (g : tctx) (t : ty) : int =
  match t with
  | TyType n ->
      if n < 0 then raise (Check_error "negative universe level") else n + 1
  | TyDirUniverse n ->
      if n < 0 then raise (Check_error "negative directed-universe level")
      else n + 1
  | TyPlace _ -> 0
  | TyArrow (a, b) -> max (sort_of g a) (sort_of g b)
  | TyPi (x, a, b) -> max (sort_of g a) (sort_of ((x, a) :: g) b)
  | TySigma (x, a, b) -> max (sort_of g a) (sort_of ((x, a) :: g) b)
  | TyId (a, t1, t2) ->
      let n = sort_of g a in
      if check g t1 a && check g t2 a then n
      else raise (Check_error "Id endpoints not of the carrier type")
  | TyEl c ->
      (match norm_ty (infer g c) with
       | TyDirUniverse n -> n
       | _ -> raise (Check_error "El of a non-code"))
  | _ -> raise (Check_error "sort_of: unsupported type")

and infer (g : tctx) (tm : term) : ty =
  match tm with
  | Var x ->
      (match List.assoc_opt x g with
       | Some t -> t
       | None -> raise (Check_error ("unbound " ^ x)))
  | Lam (x, dom, body) ->
      let _ = sort_of g dom in
      let cod = infer ((x, dom) :: g) body in
      TyPi (x, dom, cod)
  | App (f, a) ->
      (match norm_ty (infer g f) with
       | TyArrow (dom, cod) ->
           if check g a dom then cod
           else raise (Check_error "arg/dom mismatch")
       | TyPi (x, dom, cod) ->
           if check g a dom then Subst.subst_term_in_ty x a cod
           else raise (Check_error "arg/dom mismatch")
       | _ -> raise (Check_error "applying a non-function"))
  | Fst p ->
      (match norm_ty (infer g p) with
       | TySigma (_, a, _) -> a
       | _ -> raise (Check_error "fst of non-sigma"))
  | Snd p ->
      (match norm_ty (infer g p) with
       | TySigma (x, _, b) -> Subst.subst_term_in_ty x (Fst p) b
       | _ -> raise (Check_error "snd of non-sigma"))
  | Refl t ->
      let a = infer g t in
      TyId (a, t, t)
  | J (_x, ty_a, c, d, p, b) ->
      (match norm_ty (infer g p) with
       | TyId (ty_p, a_near, b_far) ->
           if not (ty_conv [] ty_p ty_a) then
             raise (Check_error "J: path carrier mismatch");
           if not (term_equal_env []
                     (reduce_full b_far) (reduce_full b)) then
             raise (Check_error "J: path far-endpoint mismatch");
           let z = Ast.fresh_var (Ast.free_vars c) in
           let diag_ty =
             TyPi (z, ty_a,
               TyEl (App (App (App (c, Var z), Var z), Refl (Var z))))
           in
           if not (check g d diag_ty) then
             raise (Check_error "J: diagonal base type mismatch");
           let far_code = App (App (App (c, a_near), b), p) in
           (match norm_ty (infer g far_code) with
            | TyDirUniverse _ -> TyEl far_code
            | _ -> raise (Check_error "J: motive does not land in a universe"))
       | _ -> raise (Check_error "J: path argument is not an Id type"))
  | Pair _ -> raise (Check_error "Pair needs a checking type (Sigma)")
  | _ -> raise (Check_error "infer: unsupported term")

and check (g : tctx) (tm : term) (expected : ty) : bool =
  match tm with
  | Pair (a, b) ->
      (match norm_ty expected with
       | TySigma (x, ta, tb) ->
           check g a ta && check g b (Subst.subst_term_in_ty x a tb)
       | _ -> false)
  | Lam (x, dom, body) ->
      (match norm_ty expected with
       | TyArrow (d2, cod) ->
           ty_conv [] dom d2 && check ((x, dom) :: g) body cod
       | TyPi (y, d2, cod) ->
           let cod' = Subst.subst_term_in_ty y (Var x) cod in
           ty_conv [] dom d2 && check ((x, dom) :: g) body cod'
       | _ -> false)
  | _ ->
      (try ty_conv [] (infer g tm) expected with Check_error _ -> false)

let check_closed (tm : term) (expected : ty) : bool =
  try
    let _ = sort_of [] expected in
    check [] tm expected
  with Check_error _ -> false

let infer_closed (tm : term) : ty option =
  try Some (infer [] tm) with Check_error _ -> None
