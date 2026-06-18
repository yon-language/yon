(* sheaf.ml — the sheaf predicate for the quotient generator, as a kernel
 * judgement on terms.
 *
 * A world  Q = W / Rel  is a set-quotient, and  canon : W -> Q  is its quotient
 * map (the canonical class of an element). By the universal property of the
 * coequalizer, a field  field : W -> V  descends to Q -- i.e. the place P is a
 * SHEAF for this generator -- exactly when field factors through canon:
 *
 *     field  =  s̄ ∘ canon          for a (unique) s̄ : Q -> V.
 *
 * Equivalently, this is the path branch a set-quotient HIT eliminator demands:
 * field respects Rel, i.e.  canon x ≐ canon y  =>  field x ≐ field y.
 *
 * Rice forbids deciding this for an arbitrary field; we decide the SOUND,
 * syntactically-expressible side, and we decide it CONSTRUCTIVELY -- not by
 * hunting for a diverging pair, but by building s̄:
 *
 *   - introduce a fresh generic point x : W;
 *   - normalize the canonical class  cx := nf (canon x)  and the field value
 *     fx := nf (field x);
 *   - abstract cx out of fx, replacing it by a fresh z : Q;
 *   - if x no longer occurs free, then  fx = s̄ (canon x)  with
 *     s̄ = λz. fx[canon x := z], so field factors -> P is a sheaf here.
 *   - a surviving free x is a read of W finer than Rel preserves -> P is NOT a
 *     sheaf -> static rejection (the "field reads the address, not the class"
 *     failure).
 *
 * This is the runtime content-addressing discipline lifted to compile time: at
 * runtime a value may depend only on its content, never on its pre-dedup heap
 * address (FNV finds, byte-compare decides); here a field may depend on an
 * element only through its canonical class. Same universal property, two
 * regimes -- runtime decides it on data, the compiler proves it on functions.
 *
 * STAGE NOTE. This is the pure kernel engine: it takes canon and field as Core
 * terms and is exercised by an oracle on symbolic terms. Wiring it to the
 * surface -- how `world Q = W / Rel` produces canon, and how a place's fields
 * are presented as W -> V maps -- is a separate, surface-level representation
 * choice and is deliberately not made here. *)

module C = Ast
module S = Set.Make (String)

let fresh_point = "__sheaf_x"
let fresh_class = "__sheaf_z"

(* Replace every subterm alpha-equal to [target] with [replacement]. Sound and
   conservative: we stop at a binder that would capture a variable of target,
   and we leave intact any constructor we don't descend into. An occurrence left
   un-abstracted simply keeps x free, which the caller reads as "does not
   factor" -- a conservative rejection, never a false acceptance. *)
let rec replace_subterm ~(target : C.term) ~(replacement : C.term) (t : C.term) : C.term =
  if C.term_equal t target then replacement
  else
    let r = replace_subterm ~target ~replacement in
    match t with
    | C.App (f, a) -> C.App (r f, r a)
    | C.Lam (y, ty, b) ->
        if S.mem y (C.free_vars target) then t else C.Lam (y, ty, r b)
    | C.Pair (a, b) -> C.Pair (r a, r b)
    | C.Fst a -> C.Fst (r a)
    | C.Snd a -> C.Snd (r a)
    | C.Refl a -> C.Refl (r a)
    | C.Emit a -> C.Emit (r a)
    | other -> other

(* field : W -> V factors through canon : W -> Q  <=>  P is a sheaf for the
   quotient generator. See the module header for the construction. *)
let field_factors_through
      (ctx : Reduce.ctx) ~(canon : C.term) ~(field : C.term) : bool =
  let x = fresh_point in
  let cx = Builtins.reduce_with_builtins ctx (C.App (canon, C.Var x)) in
  let fx = Builtins.reduce_with_builtins ctx (C.App (field, C.Var x)) in
  let abstracted =
    replace_subterm ~target:cx ~replacement:(C.Var fresh_class) fx in
  not (S.mem x (C.free_vars abstracted))
