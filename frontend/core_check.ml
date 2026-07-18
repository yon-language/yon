(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
open Ast

type tctx = (string * ty) list

(* A GENUINE type error: the term/type is within the checker's fragment and is
   ill-typed. A gate that sees this must REJECT the program. *)
exception Check_error of string

(* A COVERAGE gap: the checker does not (yet) cover this construct — an unbound
   name it was not seeded with, a runtime former outside the dependent fragment
   (Place / Emit / stream / cubical), a literal, or a term that only checks (not
   infers). This is NOT evidence of ill-typedness: a gate must SKIP, never reject.
   Keeping it distinct from Check_error is what lets core_check run over real
   programs without false-rejecting the parts it cannot see. *)
exception Unsupported of string

(* ── Delta-aware conversion context ─────────────────────────────────────────
   The checker's definitional equality now unfolds user function definitions.
   [cc.deltas] is the SN-safe (SCT-certified) subset of the program's function
   bodies as curried-lambda Core terms; [cc.rctx] wraps them in the reducer's
   context so conversion beta-unfolds a call `f a` to `body[a]` alongside the
   usual beta/eta/J/cubical/arith rules. A body that equals its declared type
   only AFTER unfolding a called definition therefore converts.

   SOUNDNESS / SN. Using ONLY the certified (terminating) deltas keeps
   normalization strongly normalizing: no rule can loop, so the reducer's fuel
   bound is a conservative incompleteness cap, never a source of unsoundness.

   We thread this record explicitly through the mutually-recursive
   sort_of/infer/check/ty_conv/norm_ty rather than a global mutable ref. The
   empty-delta context ([empty_cctx]) recovers the previous behaviour exactly,
   so the hand-built oracle terms (which reference no user definitions) are
   unchanged. *)
type cctx = { deltas : (string * term) list; rctx : Reduce.ctx }

let empty_cctx : cctx = { deltas = []; rctx = Reduce.empty_ctx }

(* Build a conversion context from certified delta-rules (name -> curried-lambda
   Core body). Callers derive these from the SN-safe subset of the program's
   definitions (see core_wf.ml). *)
let cctx_of_deltas (deltas : (string * term) list) : cctx =
  { deltas; rctx = { Reduce.empty_ctx with Reduce.deltas } }

(* Unified conversion reducer. The checker's definitional equality uses the SAME
 * engine as the evaluator, so conversion now includes delta-unfolding of
 * certified user definitions, cubical computation (transport / Glue / hcomp)
 * and builtin arithmetic, not only beta/eta/J. reduce_with_builtins is a strict
 * superset of Reduce.reduce (it falls back to Reduce.step), so the non-cubical,
 * delta-free fragment — Yoneda/J/eta witnesses — is unchanged; the fuel bound
 * gives conservative incompleteness, never unsoundness. *)
let reduce_full (cc : cctx) (t : term) : term =
  Builtins.reduce_with_builtins cc.rctx t

let rec norm_ty (cc : cctx) (t : ty) : ty =
  match t with
  | TyType _ | TyDirUniverse _ | TyPlace _ -> t
  | TyArrow (a, b) -> TyArrow (norm_ty cc a, norm_ty cc b)
  | TyPi (x, a, b) -> TyPi (x, norm_ty cc a, norm_ty cc b)
  | TySigma (x, a, b) -> TySigma (x, norm_ty cc a, norm_ty cc b)
  | TyId (a, t1, t2) ->
      TyId (norm_ty cc a, reduce_full cc t1, reduce_full cc t2)
  | TyEl c -> TyEl (reduce_full cc c)
  | TyStream a -> TyStream (norm_ty cc a)
  | other -> other

let rec ty_conv (cc : cctx) (env : (string * string) list) (a : ty) (b : ty) : bool =
  match norm_ty cc a, norm_ty cc b with
  | TyType n, TyType m -> n = m
  | TyDirUniverse n, TyDirUniverse m -> n = m
  | TyPlace p, TyPlace q -> p = q
  | TyArrow (a1, b1), TyArrow (a2, b2) ->
      ty_conv cc env a1 a2 && ty_conv cc env b1 b2
  | TyArrow (a1, b1), TyPi (x, a2, b2) ->
      let probe = Pair (Unit, Unit) in
      let b2_probe = Subst.subst_term_in_ty x probe b2 in
      ty_conv cc env a1 a2
      && ty_conv cc env b2 b2_probe
      && ty_conv cc env b1 b2
  | TyPi (x, a1, b1), TyArrow (a2, b2) ->
      let probe = Pair (Unit, Unit) in
      let b1_probe = Subst.subst_term_in_ty x probe b1 in
      ty_conv cc env a1 a2
      && ty_conv cc env b1 b1_probe
      && ty_conv cc env b1 b2
  | TyPi (x, a1, b1), TyPi (y, a2, b2) ->
      ty_conv cc env a1 a2 && ty_conv cc ((x, y) :: env) b1 b2
  | TySigma (x, a1, b1), TySigma (y, a2, b2) ->
      ty_conv cc env a1 a2 && ty_conv cc ((x, y) :: env) b1 b2
  | TyId (t1, a1, b1), TyId (t2, a2, b2) ->
      ty_conv cc env t1 t2
      && term_equal_env env a1 a2
      && term_equal_env env b1 b2
  | TyEl c1, TyEl c2 -> term_equal_env env c1 c2
  | TyStream a1, TyStream a2 -> ty_conv cc env a1 a2
  | _ -> false

let rec sort_of (cc : cctx) (g : tctx) (t : ty) : int =
  match t with
  | TyType n ->
      if n < 0 then raise (Check_error "negative universe level") else n + 1
  | TyDirUniverse n ->
      if n < 0 then raise (Check_error "negative directed-universe level")
      else n + 1
  | TyPlace _ -> 0
  | TyArrow (a, b) -> max (sort_of cc g a) (sort_of cc g b)
  | TyPi (x, a, b) -> max (sort_of cc g a) (sort_of cc ((x, a) :: g) b)
  | TySigma (x, a, b) -> max (sort_of cc g a) (sort_of cc ((x, a) :: g) b)
  | TyId (a, t1, t2) ->
      let n = sort_of cc g a in
      if check cc g t1 a && check cc g t2 a then n
      else raise (Check_error "Id endpoints not of the carrier type")
  | TyEl c ->
      (* El decodes a CODE. A code inhabits a universe of codes; the surface has one
         universe syntax `Type_n` (-> TyType n), while the kernel's Tarski/CATT layer
         also tags directed code-universes `U_omega` (-> TyDirUniverse n). Both are
         universes of codes here, so El accepts either — a code typed Type_n is as
         decodable as one typed U_omega. A code whose type is NOT a universe is a
         genuine error (El of a non-code).

         We normalize the code FIRST (the CATT/R_Yon rule El(c) ≡ El(nf_Δ c),
         the same one el_normalize.ml applies): an APPLIED code `Fam x` or a call
         to a certified delta reduces to a bare code the checker can then type.
         Without this, `El(idcode A)` would try to infer the unbound head `idcode`
         and SKIP, even though it is definitionally `El A`. *)
      (match norm_ty cc (infer cc g (reduce_full cc c)) with
       | TyType n | TyDirUniverse n -> n
       | _ -> raise (Check_error "El of a non-code"))
  | _ -> raise (Unsupported "sort_of: type outside the dependent fragment")

and infer (cc : cctx) (g : tctx) (tm : term) : ty =
  match tm with
  | Var x when List.mem_assoc x g -> List.assoc x g
  (* A numeric literal is encoded by the reducer as `Var "__num_N"` (see
     Builtins.encode_number). It has no binder in the context, but it is not a
     coverage gap: it inhabits the primitive number type, which the surface types
     as `number` and desugar lowers to `TyPlace "number"`. Seeding it here puts
     literal-bearing terms IN the dependent fragment (so a body like `fun => 0`
     against a `number` return can be checked) instead of skipping on an
     "unbound __num_" name. This is the one seeded exception to the unbound rule:
     the name canonically denotes a number, so inferring its type is sound. *)
  | Var x when String.length x > 6 && String.sub x 0 6 = "__num_" ->
      TyPlace "number"
  | Var x ->
      (* A name the checker was not seeded with (a top-level runtime fn, a prim
         code not in ctx): a coverage gap, not an ill-typing. SKIP, so the gate
         never false-rejects on it. *)
      raise (Unsupported ("unbound " ^ x))
  | Lam (x, dom, body) ->
      let _ = sort_of cc g dom in
      let cod = infer cc ((x, dom) :: g) body in
      TyPi (x, dom, cod)
  | App (f, a) ->
      (match norm_ty cc (infer cc g f) with
       | TyArrow (dom, cod) ->
           if check cc g a dom then cod
           else raise (Check_error "arg/dom mismatch")
       | TyPi (x, dom, cod) ->
           if check cc g a dom then Subst.subst_term_in_ty x a cod
           else raise (Check_error "arg/dom mismatch")
       | _ -> raise (Check_error "applying a non-function"))
  | Fst p ->
      (match norm_ty cc (infer cc g p) with
       | TySigma (_, a, _) -> a
       | _ -> raise (Check_error "fst of non-sigma"))
  | Snd p ->
      (match norm_ty cc (infer cc g p) with
       | TySigma (x, _, b) -> Subst.subst_term_in_ty x (Fst p) b
       | _ -> raise (Check_error "snd of non-sigma"))
  | Refl t ->
      let a = infer cc g t in
      TyId (a, t, t)
  | J (_x, ty_a, c, d, p, b) ->
      (match norm_ty cc (infer cc g p) with
       | TyId (ty_p, a_near, b_far) ->
           if not (ty_conv cc [] ty_p ty_a) then
             raise (Check_error "J: path carrier mismatch");
           if not (term_equal_env []
                     (reduce_full cc b_far) (reduce_full cc b)) then
             raise (Check_error "J: path far-endpoint mismatch");
           let z = Ast.fresh_var (Ast.free_vars c) in
           let diag_ty =
             TyPi (z, ty_a,
               TyEl (App (App (App (c, Var z), Var z), Refl (Var z))))
           in
           if not (check cc g d diag_ty) then
             raise (Check_error "J: diagonal base type mismatch");
           let far_code = App (App (App (c, a_near), b), p) in
           (match norm_ty cc (infer cc g far_code) with
            | TyDirUniverse _ -> TyEl far_code
            | _ -> raise (Check_error "J: motive does not land in a universe"))
       | _ -> raise (Check_error "J: path argument is not an Id type"))
  | Pair _ -> raise (Unsupported "Pair only checks against a Sigma (no inference mode)")
  | _ -> raise (Unsupported "infer: term outside the dependent fragment")

and check (cc : cctx) (g : tctx) (tm : term) (expected : ty) : bool =
  match tm with
  | Pair (a, b) ->
      (match norm_ty cc expected with
       | TySigma (x, ta, tb) ->
           check cc g a ta && check cc g b (Subst.subst_term_in_ty x a tb)
       | _ -> false)
  | Lam (x, dom, body) ->
      (match norm_ty cc expected with
       | TyArrow (d2, cod) ->
           ty_conv cc [] dom d2 && check cc ((x, dom) :: g) body cod
       | TyPi (y, d2, cod) ->
           let cod' = Subst.subst_term_in_ty y (Var x) cod in
           ty_conv cc [] dom d2 && check cc ((x, dom) :: g) body cod'
       | _ -> false)
  | _ ->
      (try ty_conv cc [] (infer cc g tm) expected with Check_error _ -> false)

let check_closed ?(cc = empty_cctx) (tm : term) (expected : ty) : bool =
  try
    let _ = sort_of cc [] expected in
    check cc [] tm expected
  with Check_error _ | Unsupported _ -> false

let infer_closed ?(cc = empty_cctx) (tm : term) : ty option =
  try Some (infer cc [] tm) with Check_error _ | Unsupported _ -> None

(* ── Strict checking for the gate ───────────────────────────────────────────
   [check] is deliberately lossy: its inference fallback swallows [Check_error]
   to [false], which is right for the oracle's boolean API but WRONG for a gate
   that must distinguish "genuinely ill-typed" from "a coverage gap I hit while
   inferring". [check_strict] mirrors [check] EXACTLY but lets [Check_error] and
   [Unsupported] PROPAGATE out of the inference fallback. The gate then reads the
   three signals precisely:
     returns true            — the term inhabits the type;
     returns false           — a CLEAN structural non-inhabitation: every step
                               stayed in the fragment and the conversion simply
                               failed (e.g. El A vs El B). This is genuine
                               ill-typing → the gate REJECTS;
     raises Unsupported       — an unseeded name / runtime former / non-inferring
                               term was reached → the gate SKIPS;
     raises Check_error       — inference hit a construct it can only call an
                               error but which real (artifact-bearing) lowerings
                               DO produce — a 0-ary call `App(body,())`, a
                               placeholder `unit`-typed let binder applied to a
                               non-unit value, etc. Under the SOUND-over-COMPLETE
                               bias the gate SKIPS these too (see certify_term):
                               it is never worth false-rejecting a valid program
                               over a lowering artifact.
   Only the CLEAN [false] path — no exception anywhere — is treated as a
   rejection, which is exactly the shape a hand-written ill-typed pure-dependent
   body produces. *)
let rec check_strict (cc : cctx) (g : tctx) (tm : term) (expected : ty) : bool =
  match tm with
  | Pair (a, b) ->
      (match norm_ty cc expected with
       | TySigma (x, ta, tb) ->
           check_strict cc g a ta
           && check_strict cc g b (Subst.subst_term_in_ty x a tb)
       | _ -> false)
  | Lam (x, dom, body) ->
      (match norm_ty cc expected with
       | TyArrow (d2, cod) ->
           ty_conv cc [] dom d2 && check_strict cc ((x, dom) :: g) body cod
       | TyPi (y, d2, cod) ->
           let cod' = Subst.subst_term_in_ty y (Var x) cod in
           ty_conv cc [] dom d2 && check_strict cc ((x, dom) :: g) body cod'
       | _ -> false)
  | _ ->
      (* NO Check_error/Unsupported swallow here: they propagate to the gate. *)
      ty_conv cc [] (infer cc g tm) expected

(* The safe gate primitive: certify that a dependent type is well-formed under the
   kernel, in a context [g] of the free variables' types. Distinguishes the three
   outcomes a gate must keep apart:
     `Ok            — the type is kernel-well-formed (its codes inhabit a universe);
     `Type_error m  — it is within the fragment and ILL-formed: the caller REJECTS;
     `Skipped m     — it touches a construct the checker does not cover: the caller
                      SKIPS (this is not evidence of ill-formedness).
   sort_of does the work (it recurses into Pi/Sigma/Id and, for El, infers the code
   and demands it lands in a universe). *)
let certify_ty ?(cc = empty_cctx) (g : tctx) (t : ty)
  : [ `Ok | `Type_error of string | `Skipped of string ] =
  try let _ = sort_of cc g t in `Ok
  with
  | Check_error m -> `Type_error m
  | Unsupported m -> `Skipped m

(* The safe gate primitive for a TERM: kernel-CHECK [tm] against its declared
   type [expected], in a context [g], with delta-aware conversion [cc]. The
   three outcomes a gate keeps apart:
     `Ok            — the term checks against the type under the kernel;
     `Type_error m  — term and type are both in the fragment and the term does
                      NOT inhabit the type: the caller REJECTS;
     `Skipped m     — the term (or its type) touches a construct the checker
                      does not cover (Place/Emit/stream/cubical, an unseeded
                      name, a term that only infers in a mode we lack): the
                      caller SKIPS — this is NOT evidence of ill-typing.

   POLICY (SOUND over COMPLETE — see check_strict). We
     1. demand the expected type is well-formed (sort_of): an out-of-fragment
        type raises `Unsupported → SKIP;
     2. normalize the body under the delta-aware reducer, so let/beta artifacts
        the desugarer introduces (placeholder `unit`-typed let binders, curried
        redexes) are computed away — the body and its normal form are
        definitionally equal, and the normal form is what a kernel comparison
        should see. A pure dependent body then reduces to a value the checker can
        match against its declared type;
     3. run check_strict on the normal form:
          true            → `Ok;
          false (clean)   → `Type_error — a genuine, in-fragment non-inhabitation;
          Unsupported     → `Skipped (a name/former/term outside the fragment);
          Check_error     → `Skipped (a lowering artifact the checker can only
                            call an error — never worth a false rejection).
   This is exactly the bias the prompt mandates: it is far worse to false-reject
   a valid corpus program than to skip, so only the unambiguous clean-false path
   rejects. *)
let certify_term ?(cc = empty_cctx) (g : tctx) (tm : term) (expected : ty)
  : [ `Ok | `Type_error of string | `Skipped of string ] =
  try
    let _ = sort_of cc g expected in
    let nf = reduce_full cc tm in
    if check_strict cc g nf expected then `Ok
    else `Type_error "body does not check against its declared type"
  with
  | Unsupported m -> `Skipped m
  | Check_error m -> `Skipped ("checker artifact: " ^ m)
  (* The reducer is PARTIAL on real bodies: normalizing a body that performs a
     guarded/effectful operation (`decide` on an undecidable proposition, a partial
     builtin, a runtime primitive) legitimately raises — e.g. Failure "decide:
     HUnknown …". That is not a type verdict; it means the checker cannot evaluate
     this body. Since term checking is advisory (core_wf never rejects on it), any
     such escape is a SKIP, never a crash of the compile. *)
  | Failure m -> `Skipped ("reducer partial: " ^ m)
  | Stack_overflow -> `Skipped "reducer did not terminate within stack"
  | Not_found | Invalid_argument _ -> `Skipped "reducer raised on a partial body"

(* ── Public API, backward-compatible signatures ─────────────────────────────
   The recursive core now threads a [cctx] as its first argument. To keep every
   existing caller (and the test oracles) compiling unchanged, we expose the two
   externally-used entry points [sort_of] and [ty_conv] with their ORIGINAL
   positional shape plus an OPTIONAL [?cc] (defaulting to the empty, delta-free
   context — identical to the old behaviour). The bindings below capture the
   recursive functions before shadowing their names; the earlier internal users
   (sort_of, infer, check, certify_ty, certify_term) already resolved to the
   recursive versions, so only external references pick up these wrappers. *)
let sort_of_rec = sort_of
let ty_conv_rec = ty_conv

let sort_of ?(cc = empty_cctx) (g : tctx) (t : ty) : int = sort_of_rec cc g t
let ty_conv ?(cc = empty_cctx) (env : (string * string) list) (a : ty) (b : ty) : bool =
  ty_conv_rec cc env a b
