(* inline_seq.ml — a let-inline pass for stream fusion preservation
 *
 * Problem solved: when the user writes
 *   let a holds Seq.from_list(l)
 *   let b holds a.map(fun(x) => x * x)
 *   let r holds b.fold(0, fun(a, b) => a + b)
 * the emit fusion pattern does NOT recognize the pipeline because `a` and `b`
 * are opaque bindings, not a tree `Seq.from_list(l).map(...)`.
 *
 * In the Core IR, `let x = v in body` is represented as
 * `App (Lam (x, ty, body), v)`. The pass recognizes this form and, if `v` is a
 * Seq.* pipeline AND x appears at most once in body, substitutes `x` with `v`
 * in the body, eliminating the binding.
 *
 * Preservation: 0 occurrences -> eliminated. 1 occurrence -> inlined. > 1
 * occurrences -> left intact (no code duplication).
 *)

open Ast

(* Count the occurrences of a variable in a term. Does not descend below a
 * binder that shadows the variable. *)
let rec count_occurrences (x : string) (t : term) : int =
  match t with
  | Var y -> if x = y then 1 else 0
  | Lam (y, _, body) ->
      if x = y then 0  (* shadowed *)
      else count_occurrences x body
  | App (f, a) -> count_occurrences x f + count_occurrences x a
  | Scope (_, body) -> count_occurrences x body
  | With (_, body) -> count_occurrences x body
  | Emit e -> count_occurrences x e
  | Refl e -> count_occurrences x e
  | J (_y, _ty, mot, dval, p, e) ->
      count_occurrences x mot + count_occurrences x dval +
      count_occurrences x p + count_occurrences x e
  | Pair (a, b) -> count_occurrences x a + count_occurrences x b
  | Fst e | Snd e -> count_occurrences x e
  | StreamCons (h, t) -> count_occurrences x h + count_occurrences x t
  | Place _ | Reduction _ | Unit -> 0

(* Recognize whether a term is a Seq.* pipeline (from_list/map/filter or a
 * wrapper of them). *)
let rec is_seq_pipeline (t : term) : bool =
  match t with
  | App (Var "__stream_from_list", _) -> true
  | App (App (Var "__stream_map", inner), _) -> is_seq_pipeline inner
  | App (App (Var "__stream_filter", inner), _) -> is_seq_pipeline inner
  (* Include __stream_iterate for fusion with sum_take/take when the iter
   * function is an inline or lifted lambda (C.Var). *)
  | App (App (Var "__stream_iterate", _), _) -> true
  | _ -> false

(* Inline pass: walk the term, replacing variables bound to Seq.* expressions
 * with their definitions when they appear at most once in the body.
 *
 * Recognizes the pattern `let x = v in body` as
 * `App (Lam (x, _, body), v)`. *)
let rec inline_seq_lets (t : term) : term =
  match t with
  (* Pattern let: App (Lam (x, ty, body), v) *)
  | App (Lam (x, ty, body), value) ->
      let value' = inline_seq_lets value in
      let body' = inline_seq_lets body in
      if is_seq_pipeline value' && count_occurrences x body' <= 1 then
        Subst.subst x value' body'
      else
        App (Lam (x, ty, body'), value')
  | App (f, a) -> App (inline_seq_lets f, inline_seq_lets a)
  | Lam (y, ty, body) -> Lam (y, ty, inline_seq_lets body)
  | Scope (n, body) -> Scope (n, inline_seq_lets body)
  | With (r, body) -> With (r, inline_seq_lets body)
  | Emit e -> Emit (inline_seq_lets e)
  | Refl e -> Refl (inline_seq_lets e)
  | J (y, ty, mot, dval, p, e) ->
      J (y, ty, inline_seq_lets mot, inline_seq_lets dval,
         inline_seq_lets p, inline_seq_lets e)
  | Pair (a, b) -> Pair (inline_seq_lets a, inline_seq_lets b)
  | Fst e -> Fst (inline_seq_lets e)
  | Snd e -> Snd (inline_seq_lets e)
  | StreamCons (h, tl) -> StreamCons (inline_seq_lets h, inline_seq_lets tl)
  | Var _ | Place _ | Reduction _ | Unit -> t
