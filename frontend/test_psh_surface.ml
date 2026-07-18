(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_psh_surface.ml — end-to-end oracle for the SURFACE half of the abstract
 * presheaf arrow action (A1.2 / A1.3). The kernel conversion rules live in
 * reduce.ml (try_functoriality) and are pinned by test_functoriality.ml at the
 * CORE level. This oracle drives them THROUGH THE FRONTEND: it starts from
 * hand-built Surface_ast programs, desugars them (desugar.ml), and checks that
 *
 *   (1) the surface forms lower to the EXACT kernel markers
 *       __psh_map / __compose / __id, so the delta-rules fire, and
 *   (2) the type checker (tycheck.ml) assigns the contravariant arrow-action
 *       type F(f) : F(B) -> F(A).
 *
 * Chosen surface spelling (reuses the existing call/var productions — no new
 * grammar, no new menhir conflict):
 *   psh_map(F, f)     ==  F(f)
 *   psh_compose(g, f) ==  g ∘ f
 *   psh_id            ==  id_A   (bare, or the call form psh_id())
 *
 * Desugar target (reduce.ml's encoding):
 *   psh_map(F, f)     ⟶ App(App(Var "__psh_map", <F>), <f>)
 *   psh_compose(g, f) ⟶ App(App(Var "__compose", <g>), <f>)
 *   psh_id            ⟶ Var "__id"
 *)

module S = Surface_ast
open Ast

let pass = ref 0
let fails = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fails; Printf.printf "  [FAIL] %s\n" name)

let dl = S.dummy_loc
let rctx = Reduce.empty_ctx

(* ── surface smart constructors ──────────────────────────────────────── *)
let s_var x        = S.EVar (x, dl)
let s_psh_id       = S.EVar ("psh_id", dl)              (* bare id_A *)
let s_psh_id_call  = S.ECall ("psh_id", [], dl)         (* call form *)
let s_map ff f     = S.ECall ("psh_map", [ff; f], dl)   (* F(f) *)
let s_comp g f     = S.ECall ("psh_compose", [g; f], dl)(* g ∘ f *)

(* ── core (kernel-encoding) smart constructors ───────────────────────── *)
let k_id           = Var "__id"
let k_map ff f     = App (App (Var "__psh_map", ff), f)
let k_comp g f     = App (App (Var "__compose", g), f)

(* desugar a surface expr, then normalize with the pure R_Yon kernel. *)
let nf (e : S.expr) : term = Reduce.normalize rctx (Desugar.desugar_expr e)
(* desugar only (no reduction) — pins the raw lowering. *)
let lower (e : S.expr) : term = Desugar.desugar_expr e

let () =
  Printf.printf "=== presheaf arrow-action SURFACE oracle (A1.2/A1.3) ===\n\n";

  (* opaque symbols on the SURFACE: F a presheaf name, f g h morphism names. *)
  let ff = s_var "F" and f = s_var "f" and g = s_var "g" and h = s_var "h" in

  (* ── (0) the surface lowers to the exact kernel markers ─────────────── *)
  check "lower: psh_id  ⟶  __id"
    (term_equal_env [] (lower s_psh_id) k_id);
  check "lower: psh_id()  ⟶  __id"
    (term_equal_env [] (lower s_psh_id_call) k_id);
  check "lower: psh_map(F, f)  ⟶  __psh_map F f"
    (term_equal_env [] (lower (s_map ff f)) (k_map (Var "F") (Var "f")));
  check "lower: psh_compose(g, f)  ⟶  __compose g f"
    (term_equal_env [] (lower (s_comp g f)) (k_comp (Var "g") (Var "f")));

  (* ── (1) surface F(id) desugars + reduces to id ─────────────────────── *)
  check "(F-id)  surface psh_map(F, psh_id)  ⟶*  __id"
    (term_equal_env [] (nf (s_map ff s_psh_id)) k_id);
  check "(F-id)  surface psh_map(F, psh_id())  ⟶*  __id"
    (term_equal_env [] (nf (s_map ff s_psh_id_call)) k_id);

  (* ── (2) surface F(g ∘ f) desugars + reduces to F(f) ∘ F(g) ──────────
   * The RHS is itself written in the surface and normalized, so the test
   * compares two surface programs through the full frontend + kernel. *)
  check "(F-comp)  surface psh_map(F, psh_compose(g, f))  ⟶*  psh_compose(psh_map(F,f), psh_map(F,g))"
    (term_equal_env []
       (nf (s_map ff (s_comp g f)))
       (nf (s_comp (s_map ff f) (s_map ff g))));

  (* the normal form is EXACTLY the contravariant pullback (checked against the
   * bare kernel encoding, not just against another surface spelling). *)
  check "(F-comp)  normal form is __compose (__psh_map F f) (__psh_map F g)"
    (term_equal_env []
       (nf (s_map ff (s_comp g f)))
       (k_comp (k_map (Var "F") (Var "f")) (k_map (Var "F") (Var "g"))));

  (* contravariance is real on the surface: F(g∘f) ≠ F(g)∘F(f). *)
  check "contravariance:  surface F(g∘f)  ≠  F(g)∘F(f)"
    (not (term_equal_env []
            (nf (s_map ff (s_comp g f)))
            (nf (s_comp (s_map ff g) (s_map ff f)))));

  (* nested composite through the surface + kernel. *)
  check "nested:  surface F((h∘g)∘f)  ⟶*  F(f) ∘ (F(g) ∘ F(h))"
    (term_equal_env []
       (nf (s_map ff (s_comp (s_comp h g) f)))
       (k_comp (k_map (Var "F") (Var "f"))
               (k_comp (k_map (Var "F") (Var "g")) (k_map (Var "F") (Var "h")))));

  (* ── (3) the TYPING rule: F(f) : F(B) -> F(A) (contravariant) ─────────
   * env: f : A -> B, g : B -> C. Objects A, B, C are nominal user types.
   * F is a presheaf name in scope (typed as a value; its exact type is
   * irrelevant to the arrow-action rule, which reads only f's arrow type). *)
  let tarrow a b = S.TyArrow (S.TyUser a, S.TyUser b) in
  let tenv =
    Tyenv.add_vars Tyenv.empty
      [ ("F", S.TyPrim "number");           (* opaque presheaf handle *)
        ("f", tarrow "A" "B");
        ("g", tarrow "B" "C") ]
  in
  let infer e = Tycheck.infer tenv rctx e in

  (* Structurally read the object action El(F X): match El(TyTermExpr(EApp(F,[X])))
   * and return the presheaf-name and object-name pair. ty_to_string is NOT
   * usable here — it collapses EApp to "_code", so it cannot tell El(F A) from
   * El(F B). We inspect the AST directly. *)
  let el_obj (t : S.ty) : (string * string) option =
    match t with
    | S.TyEl (S.TyTermExpr (S.EApp (S.EVar (fn, _), [S.EVar (obj, _)], _))) ->
        Some (fn, obj)
    | _ -> None
  in

  (* psh_id : X -> X (polymorphic identity). *)
  check "type:  psh_id : X -> X"
    (match infer s_psh_id with
     | Ok (S.TyArrow (S.TyVar a, S.TyVar b)) -> a = b
     | _ -> false);

  (* psh_map(F, f) : El(F B) -> El(F A)  — the CONTRAVARIANT arrow action.
   * f : A -> B, so domain must be F(B) and codomain F(A). We assert the object
   * NAMES structurally: dom carries B, cod carries A, both under presheaf F. *)
  check "type:  psh_map(F, f) : El(F B) -> El(F A)   [contravariant]"
    (match infer (s_map ff f) with
     | Ok (S.TyArrow (dom, cod)) ->
         (match el_obj dom, el_obj cod with
          | Some ("F", "B"), Some ("F", "A") -> true   (* B in domain, A in codomain *)
          | _ -> false)
     | _ -> false);

  (* the direction is NOT the covariant one (dom = F(A), cod = F(B)). *)
  check "type:  psh_map(F, f) is NOT F(A) -> F(B) (covariance rejected)"
    (match infer (s_map ff f) with
     | Ok (S.TyArrow (dom, cod)) ->
         not (match el_obj dom, el_obj cod with
              | Some ("F", "A"), Some ("F", "B") -> true
              | _ -> false)
     | _ -> false);

  (* psh_compose(g, f) : A -> C  for g : B -> C, f : A -> B. *)
  check "type:  psh_compose(g, f) : A -> C"
    (match infer (s_comp g f) with
     | Ok (S.TyArrow (S.TyUser "A", S.TyUser "C")) -> true
     | _ -> false);

  (* CONSERVATIVITY: psh_map on a non-arrow morphism degrades to `unknown`,
   * never a false reject (SOUND-FIRST). Here `F` (a number) is not an arrow. *)
  check "conservative:  psh_map(F, F) with F non-arrow ⟶ unknown (no false reject)"
    (match infer (s_map ff ff) with
     | Ok (S.TyPrim "unknown") -> true
     | _ -> false);

  Printf.printf "\n%d passed, %d failed\n" !pass !fails;
  if !fails = 0 then exit 0 else exit 1
