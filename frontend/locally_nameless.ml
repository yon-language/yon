(* locally_nameless.ml — de Bruijn migration, stadio 2.
 *
 * The three arithmetic primitives of a locally-nameless representation
 * (Charguéraud, "The Locally Nameless Representation"):
 *
 *   shift d c t   — add d to every BVar index >= cutoff c. The cutoff
 *                   distinguishes indices bound INSIDE t (left alone) from
 *                   indices pointing OUT of t (shifted). Used to lift a term
 *                   when it is moved under extra binders.
 *
 *   open_term u t — instantiate the variable bound by the nearest enclosing
 *                   binder (BVar 0) with the term u, decrementing deeper free
 *                   indices. This is what you do when you ENTER a binder:
 *                   (Lam body) applied to u becomes open_term u body.
 *
 *   close_term x t — abstract the free name x: turn every FVar x into the
 *                    BVar of the right depth. This is what you do when you
 *                    BUILD a binder out of a term with a free variable.
 *
 * The whole point: a free name (FVar / legacy Var) lives in a different
 * namespace from a bound index (BVar), so no FVar can ever be captured by a
 * binder. open/close are exact inverses (the round-trip the oracle checks).
 *
 * Binder arity. The only term-variable binder this stage handles is Lam
 * (depth +1). Scope and With carry Space / reduction NAMES, not term-variable
 * binders, so the cutoff does NOT grow under them (verified against subst.ml).
 * J (motive is a 3-argument Pi, typing still prototype) and Reduction (n-ary
 * handler binders) have non-trivial / deferred binding arity, so the traversal
 * fails LOUDLY on them rather than silently mishandling depth; they are
 * completed when those constructs migrate. Nothing in stadio 2 feeds them a
 * J or Reduction (the oracle builds Lam terms only).
 *)

open Ast

(* shift indices >= c by d *)
let rec shift (d : int) (c : int) (t : term) : term =
  match t with
  | BVar i -> if i >= c then BVar (i + d) else BVar i
  | Var _ | FVar _ -> t                       (* free names carry no index *)
  | Lam (n, ty, b) -> Lam (n, ty, shift d (c + 1) b)
  | App (f, a) -> App (shift d c f, shift d c a)
  | Pair (a, b) -> Pair (shift d c a, shift d c b)
  | Fst e -> Fst (shift d c e)
  | Snd e -> Snd (shift d c e)
  | Emit e -> Emit (shift d c e)
  | Refl e -> Refl (shift d c e)
  | StreamCons (h, k) -> StreamCons (shift d c h, shift d c k)
  | Scope (s, b) -> Scope (s, shift d c b)    (* scope name: not a term binder *)
  | With (r, b) -> With (r, shift d c b)      (* reduction name: not a term binder *)
  | Place _ | Unit -> t                       (* closed *)
  | J _ ->
      failwith "locally_nameless.shift: J binder arity not yet handled \
                (stadio 2 covers Lam; J needs full bidirectional typing)"
  | Reduction _ ->
      failwith "locally_nameless.shift: Reduction handler binders not yet handled \
                (stadio 2 covers Lam)"

(* open: replace BVar k (the binder we are entering) with u *)
let rec open_rec (k : int) (u : term) (t : term) : term =
  match t with
  | BVar i ->
      if i = k then shift k 0 u                (* this index is our binder: instantiate, lifted past k descents *)
      else if i > k then BVar (i - 1)          (* index pointing further out: one binder removed *)
      else BVar i                              (* bound deeper inside: untouched *)
  | Var _ | FVar _ -> t
  | Lam (n, ty, b) -> Lam (n, ty, open_rec (k + 1) u b)
  | App (f, a) -> App (open_rec k u f, open_rec k u a)
  | Pair (a, b) -> Pair (open_rec k u a, open_rec k u b)
  | Fst e -> Fst (open_rec k u e)
  | Snd e -> Snd (open_rec k u e)
  | Emit e -> Emit (open_rec k u e)
  | Refl e -> Refl (open_rec k u e)
  | StreamCons (h, kk) -> StreamCons (open_rec k u h, open_rec k u kk)
  | Scope (s, b) -> Scope (s, open_rec k u b)
  | With (r, b) -> With (r, open_rec k u b)
  | Place _ | Unit -> t
  | J _ ->
      failwith "locally_nameless.open: J binder arity not yet handled (stadio 2 covers Lam)"
  | Reduction _ ->
      failwith "locally_nameless.open: Reduction handler binders not yet handled (stadio 2 covers Lam)"

let open_term (u : term) (t : term) : term = open_rec 0 u t

(* close: abstract the free name x into BVar k *)
let rec close_rec (k : int) (x : string) (t : term) : term =
  match t with
  | FVar y -> if y = x then BVar k else t
  | Var y  -> if y = x then BVar k else t      (* legacy free name, eased during migration *)
  | BVar i -> if i >= k then BVar (i + 1) else BVar i  (* make room for the new binder *)
  | Lam (n, ty, b) -> Lam (n, ty, close_rec (k + 1) x b)
  | App (f, a) -> App (close_rec k x f, close_rec k x a)
  | Pair (a, b) -> Pair (close_rec k x a, close_rec k x b)
  | Fst e -> Fst (close_rec k x e)
  | Snd e -> Snd (close_rec k x e)
  | Emit e -> Emit (close_rec k x e)
  | Refl e -> Refl (close_rec k x e)
  | StreamCons (h, kk) -> StreamCons (close_rec k x h, close_rec k x kk)
  | Scope (s, b) -> Scope (s, close_rec k x b)
  | With (r, b) -> With (r, close_rec k x b)
  | Place _ | Unit -> t
  | J _ ->
      failwith "locally_nameless.close: J binder arity not yet handled (stadio 2 covers Lam)"
  | Reduction _ ->
      failwith "locally_nameless.close: Reduction handler binders not yet handled (stadio 2 covers Lam)"

let close_term (x : string) (t : term) : term = close_rec 0 x t
