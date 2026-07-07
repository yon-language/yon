(* test_functoriality.ml — oracle for the abstract-presheaf functoriality
 * conversion rules (A1.2 arrow action + A1.3 functoriality laws) added to
 * reduce.ml.
 *
 * Representation (reserved-Var encoding, no new AST constructor):
 *   id_A       ==  Var "__id"
 *   g ∘ f      ==  __compose g f   == App(App(Var "__compose", g), f)
 *   F(f)       ==  __psh_map F f   == App(App(Var "__psh_map", F), f)
 *
 * Laws under test (directed kernel conversions):
 *   (F-id)    F(id)    ⟶ id
 *   (F-comp)  F(g ∘ f) ⟶ F(f) ∘ F(g)          (contravariant swap)
 *
 * We use TWO oracles, exactly as the metatheory-fuzz suite does:
 *   • Reduce.normalize (pure R_Yon kernel), and
 *   • Builtins.reduce_with_builtins (the full reducer the fuzz harness trusts),
 * and compare with term_equal_env (alpha-equivalence). A law is only accepted
 * when BOTH oracles agree, so the rules can never be an artifact of one path. *)

open Ast

let pass = ref 0
let fails = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fails; Printf.printf "  [FAIL] %s\n" name)

let ctx = Reduce.empty_ctx

(* both oracles must agree that `t` normalizes to `expected` *)
let normalizes_to t expected =
  let nf_kernel  = Reduce.normalize ctx t in
  let nf_full    = Builtins.reduce_with_builtins ~fuel:5000 ctx t in
  term_equal_env [] nf_kernel expected
  && term_equal_env [] nf_full expected

(* both oracles must agree that `a` and `b` share a normal form *)
let normalize_equal a b =
  let ka = Reduce.normalize ctx a and kb = Reduce.normalize ctx b in
  let fa = Builtins.reduce_with_builtins ~fuel:5000 ctx a in
  let fb = Builtins.reduce_with_builtins ~fuel:5000 ctx b in
  term_equal_env [] ka kb && term_equal_env [] fa fb
  (* and the two oracles agree with each other on the common nf *)
  && term_equal_env [] ka fa

(* smart constructors mirroring reduce.ml's encoding *)
let id_       = Var "__id"
let compose g f = App (App (Var "__compose", g), f)
let fmap ff f   = App (App (Var "__psh_map", ff), f)

let () =
  Printf.printf "=== presheaf functoriality (A1.2/A1.3) oracle ===\n\n";

  (* Abstract symbols: F is an OPAQUE presheaf (a bare Var — the whole point:
   * it is NOT a lambda the reducer can unfold), f, g, h are opaque morphisms. *)
  let ff = Var "F" in
  let f = Var "f" and g = Var "g" and h = Var "h" in

  (* ── (F-id): F(id) ⟶ id ─────────────────────────────────────────── *)
  check "(F-id)  F(id) = id"
    (normalizes_to (fmap ff id_) id_);

  (* the identity law holds for a CONCRETE presheaf head too (opacity of F):
   * the rule reads only the morphism slot, F may be any term. *)
  check "(F-id)  (λx.x)(id) = id   [concrete F head, still fires on morph slot]"
    (normalizes_to (fmap (Lam ("x", TyType 0, Var "x")) id_) id_);

  (* ── (F-comp): F(g ∘ f) ⟶ F(f) ∘ F(g) (contravariant) ───────────── *)
  check "(F-comp)  F(g ∘ f) = F(f) ∘ F(g)"
    (normalizes_to (fmap ff (compose g f)) (compose (fmap ff f) (fmap ff g)));

  (* The two ways of writing the pulled-back composite agree — the headline
   * A1.3 property: F(f) ∘ F(g) and F(g ∘ f) normalize to the SAME term. *)
  check "confluent:  F(g ∘ f)  ≡  F(f) ∘ F(g)   (both normal forms equal)"
    (normalize_equal (fmap ff (compose g f)) (compose (fmap ff f) (fmap ff g)));

  (* ── contravariance is REAL: F(g∘f) must NOT equal F(g)∘F(f) ──────── *)
  check "contravariance:  F(g ∘ f)  ≠  F(g) ∘ F(f)   (order is swapped)"
    (not (normalize_equal (fmap ff (compose g f))
                          (compose (fmap ff g) (fmap ff f))));

  (* ── functoriality composes: F(id ∘ f) = F(f) ────────────────────────
   * F(id ∘ f) --F-comp--> F(f) ∘ F(id) --F-id--> F(f) ∘ id.
   * With id represented as the reserved symbol (no η for the opaque __id),
   * the honest normal form is `F(f) ∘ id`; we assert the reducer reaches
   * exactly that, chaining BOTH rules in one normalization. *)
  check "chain:  F(id ∘ f)  = F(f) ∘ id   [(F-comp) then (F-id)]"
    (normalizes_to (fmap ff (compose id_ f)) (compose (fmap ff f) id_));

  (* symmetric side: F(f ∘ id) = id ∘ F(f) *)
  check "chain:  F(f ∘ id)  = id ∘ F(f)   [(F-comp) then (F-id)]"
    (normalizes_to (fmap ff (compose f id_)) (compose id_ (fmap ff f)));

  (* ── nested composite (functoriality distributes through associativity) ─
   * F((h ∘ g) ∘ f) and F(h ∘ (g ∘ f)) both expand; check the fully-pulled
   * form against the left-nested spelling. Contravariantly,
   *   F((h∘g)∘f) = F(f) ∘ F(h∘g) = F(f) ∘ (F(g) ∘ F(h)). *)
  check "nested:  F((h ∘ g) ∘ f) = F(f) ∘ (F(g) ∘ F(h))"
    (normalizes_to
       (fmap ff (compose (compose h g) f))
       (compose (fmap ff f) (compose (fmap ff g) (fmap ff h))));

  (* ── GUARD: the rules never fire outside the __psh_map shape ─────────
   * A plain application `g f` (head not __psh_map) is left untouched, and a
   * __compose that is not under a __psh_map is inert (no presheaf pullback
   * to distribute). Both must be normal forms already. *)
  check "guard: plain (g f) is untouched by functoriality"
    (normalizes_to (App (g, f)) (App (g, f)));
  check "guard: a bare `g ∘ f` (not under F) is inert"
    (normalizes_to (compose g f) (compose g f));
  (* and __psh_map on a NEUTRAL morphism (a bare opaque var, not id/compose)
   * is itself neutral: F(f) stays F(f) — the arrow action of an abstract
   * presheaf on an abstract arrow is a legitimate stuck-free normal form. *)
  check "guard: F(f) on an opaque morphism is a normal form"
    (normalizes_to (fmap ff f) (fmap ff f));

  (* ── idempotence / determinism: normalizing twice is stable ─────────── *)
  let t = fmap ff (compose (compose h g) f) in
  let nf = Reduce.normalize ctx t in
  check "idempotent: nf is stable under a second normalization"
    (term_equal_env [] nf (Reduce.normalize ctx nf));

  Printf.printf "\n%d passed, %d failed\n" !pass !fails;
  if !fails = 0 then exit 0 else exit 1
