(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
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
 * The pure kernel engine takes canon and field as Core terms. Surface views
 * over quotient worlds are wired to it by Tycheck.check_view_decl. *)

module C = Ast
module S = Set.Make (String)

(* SOUNDNESS — il punto generico vive in un namespace RIGIDO, disgiunto per
 * costruzione da ogni binder.
 *
 * Il gate decide "field fattorizza" testando che il punto generico non sia più
 * libero dopo l'astrazione. La correttezza richiede che NESSUN binder in field
 * possa chiamarsi come il punto: altrimenti `free_vars`, facendo `S.remove y`
 * sul `Lam (y,…)`, rimuoverebbe un'occorrenza-leak del punto, trasformando un
 * leak in una FALSA ACCETTAZIONE (cattura di nome).
 *
 * I binder — lambda utente e ogni nome sintetico (__lam_N, __field_, __stream_,
 * …) — sono identificatori sull'alfabeto [A-Za-z0-9_] (lexer.mll: alpha/alnum).
 * Questi nomi contengono '#', che il lexer non può MAI emettere. Quindi nessun
 * `Lam`/`HITElim`/`Reduction` potrà mai legare un nome così → nessuna cattura,
 * per costruzione. È la garanzia che la migrazione FVar/BVar (sospesa) darebbe
 * strutturalmente; qui si ottiene tramite l'alfabeto.
 *
 * (Prima: il nome fisso "__sheaf_x" ERA un identificatore utente valido →
 *  `fun(__sheaf_x) => self.address` poteva catturare il punto e leakare.) *)
let fresh_point = "#sheaf-point"
let fresh_class = "#sheaf-class"
let canon_arg   = "#sheaf-arg"

let quotient_canon ~(rel : string) ~(domain : C.ty) : C.term =
  C.Lam (canon_arg, domain,
    C.App (C.Var ("__field_" ^ rel), C.Var canon_arg))

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

(* ─── Surface binding: a place on a quotient world ──────────────────────────
 * In  world Q = W / Rel  the relation Rel is a FIELD of W -- the canonicalizing
 * key -- and the quotient map is its projection:  canon = fun u -> u.Rel. A
 * surface field access  u.f  desugars to  __field_f u  (desugar.ml), so a field
 * of the place, seen as the map W -> V it denotes, is  fun u -> __field_f u. The
 * place is a sheaf for the quotient generator iff every field factors through
 * canon, i.e. is determined by Rel. The non-factoring fields are the
 * violations. *)

let proj (field_name : string) (u : C.term) : C.term =
  C.App (C.Var ("__field_" ^ field_name), u)

(* a field of the place as the map W -> V it denotes *)
let field_map ~(world : string) ~(field_name : string) : C.term =
  C.Lam ("u", C.TyPlace world, proj field_name (C.Var "u"))

(* the fields that BREAK the sheaf condition for  world W / rel_field: those not
   invariant under the relation. [] means the place is a sheaf for this
   generator. The relation field itself trivially factors (through itself). *)
let quotient_violations
      (ctx : Reduce.ctx) ~(world : string) ~(rel_field : string)
      ~(fields : string list) : string list =
  let canon = quotient_canon ~rel:rel_field ~domain:(C.TyPlace world) in
  List.filter
    (fun f -> not (field_factors_through ctx ~canon
                     ~field:(field_map ~world ~field_name:f)))
    fields

(* the sheaf violations of a place given the reified site: if the place's world
   carries a quotient generator W / rel, every field must factor through the rel
   projection. [] if the world has no quotient generator, or no violations.

   WHY ONLY THE QUOTIENT. Of the three covering generators, only the quotient
   imposes a condition expressible as a constraint on a place's fields:
   - quotient W / Rel: canon identifies elements, so a field must be Rel-invariant
     (factor through canon). Real content -> checked here.
   - coproduct A + B: a DISJOINT cover, no overlap, so sections glue freely; the
     sheaf condition P(A+B) = P(A) x P(B) puts NO constraint on a single place's
     fields. Vacuous on fields.
   - subset S < V (dense): the condition P(V) = P(S) is unique EXTENSION from a
     dense part, not a factorization of fields; with total field projections it
     imposes nothing on a single place's fields. Vacuous on fields.
   So place_violations returns [] for a non-quotient world BY DESIGN, not by
   omission: there is genuinely no field-level reject to raise for those two. *)
let place_violations
      (ctx : Reduce.ctx) (site : C.world_decl) (pd : C.place_decl) : string list =
  match
    List.find_map
      (function C.GenQuotient (base, rel) -> Some (base, rel) | _ -> None)
      site.C.w_generators
  with
  | None -> []
  | Some (base, rel_field) ->
      quotient_violations ctx ~world:base ~rel_field
        ~fields:(List.map fst pd.C.p_fields)
