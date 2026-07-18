(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
open Ast

let pass = ref 0
let fail = ref 0

let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let () =
  Printf.printf "=== Core bidirectional checker oracle ===\n\n";

  let u0 = TyDirUniverse 0 in
  let el x = TyEl (Var x) in

  let poly_id =
    Lam ("A", u0, Lam ("x", el "A", Var "x"))
  in
  let poly_id_ty =
    TyPi ("A", u0, TyArrow (el "A", el "A"))
  in
  check "polymorphic identity over Tarski object codes"
    (Core_check.check_closed poly_id poly_id_ty);

  let refl_tm =
    Lam ("A", u0, Lam ("a", el "A", Refl (Var "a")))
  in
  let refl_ty =
    TyPi ("A", u0,
      TyPi ("a", el "A", TyId (el "A", Var "a", Var "a")))
  in
  check "Refl infers and checks at the dependent Id type"
    (Core_check.check_closed refl_tm refl_ty);

  let sigma_ab = TySigma ("_", el "A", el "B") in
  let fst_tm =
    Lam ("A", u0,
      Lam ("B", u0,
        Lam ("p", sigma_ab, Fst (Var "p"))))
  in
  let fst_ty =
    TyPi ("A", u0,
      TyPi ("B", u0, TyArrow (sigma_ab, el "A")))
  in
  check "Sigma first projection checks"
    (Core_check.check_closed fst_tm fst_ty);

  let snd_tm =
    Lam ("A", u0,
      Lam ("B", u0,
        Lam ("p", sigma_ab, Snd (Var "p"))))
  in
  let snd_ty =
    TyPi ("A", u0,
      TyPi ("B", u0, TyArrow (sigma_ab, el "B")))
  in
  check "Sigma second projection checks"
    (Core_check.check_closed snd_tm snd_ty);

  let pair_tm =
    Lam ("A", u0,
      Lam ("B", u0,
        Lam ("a", el "A",
          Lam ("b", el "B", Pair (Var "a", Var "b")))))
  in
  let pair_ty =
    TyPi ("A", u0,
      TyPi ("B", u0,
        TyPi ("a", el "A",
          TyPi ("b", el "B", sigma_ab))))
  in
  check "Pair checks against Sigma in analysis mode"
    (Core_check.check_closed pair_tm pair_ty);

  let code_id = Lam ("z", u0, Var "z") in
  let reduced_el_a = TyEl (App (code_id, Var "A")) in
  let conversion_tm =
    Lam ("A", u0, Lam ("x", reduced_el_a, Var "x"))
  in
  check "conversion normalizes a beta-redex inside El"
    (Core_check.check_closed conversion_tm poly_id_ty);

  let pi_x =
    TyPi ("x", TyPlace "A",
      TyId (TyPlace "A", Var "x", Var "x"))
  in
  let pi_y =
    TyPi ("y", TyPlace "A",
      TyId (TyPlace "A", Var "y", Var "y"))
  in
  let sigma_x = TySigma ("x", TyPlace "A", TyEl (Var "x")) in
  let sigma_y = TySigma ("y", TyPlace "A", TyEl (Var "y")) in
  check "Pi and Sigma conversion is alpha-aware in dependent codomains"
    (Core_check.ty_conv [] pi_x pi_y
     && Core_check.ty_conv [] sigma_x sigma_y);

  let arrow_a = TyArrow (TyPlace "A", TyPlace "B") in
  let pi_a = TyPi ("x", TyPlace "A", TyPlace "B") in
  let dependent_pi =
    TyPi ("_", TyPlace "A", TyEl (Var "_"))
  in
  let capture_arrow =
    TyArrow (TyPlace "A", TyEl (Var "_"))
  in
  check "Arrow converts only to a non-dependent Pi"
    (Core_check.ty_conv [] arrow_a pi_a
     && Core_check.ty_conv [] pi_a arrow_a
     && not (Core_check.ty_conv [] dependent_pi capture_arrow)
     && not (Core_check.ty_conv [] capture_arrow dependent_pi));

  check "unbound variable is rejected"
    (Core_check.infer_closed (Var "missing") = None);

  check "applying a non-function is rejected"
    (Core_check.infer_closed
       (Lam ("A", u0, App (Var "A", Var "A"))) = None);

  let wrong_id_ty =
    TyPi ("A", u0,
      TyPi ("B", u0, TyArrow (el "A", el "B")))
  in
  let two_code_id =
    Lam ("A", u0,
      Lam ("B", u0,
        Lam ("x", el "A", Var "x")))
  in
  check "identity cannot be claimed at El(A) -> El(B)"
    (not (Core_check.check_closed two_code_id wrong_id_ty));

  check "universe hierarchy is strict: Type_0 inhabits Type_1, not Type_0"
    (Core_check.sort_of [] (TyType 0) = 1
     && not (Core_check.ty_conv [] (TyType 0) (TyType 1)));

  check "negative universe levels are rejected"
    (try
       let _ = Core_check.sort_of [] (TyType (-1)) in
       false
     with Core_check.Check_error _ -> true);

  let id_ty x y = TyId (el "A", Var x, Var y) in
  let motive_ty =
    TyPi ("x", el "A",
      TyPi ("y", el "A",
        TyPi ("q", id_ty "x" "y", u0)))
  in
  let diag_ty =
    TyPi ("z", el "A",
      TyEl (App (App (App (Var "C", Var "z"), Var "z"),
              Refl (Var "z"))))
  in
  let j_witness =
    Lam ("A", u0,
      Lam ("C", motive_ty,
        Lam ("d", diag_ty,
          Lam ("a", el "A",
            J ("_", el "A", Var "C", Var "d",
               Refl (Var "a"), Var "a")))))
  in
  let j_witness_ty =
    TyPi ("A", u0,
      TyPi ("C", motive_ty,
        TyPi ("d", diag_ty,
          TyPi ("a", el "A",
            TyEl (App (App (App (Var "C", Var "a"), Var "a"),
                    Refl (Var "a")))))))
  in
  check "J (Martin-Lof) types the generic path-induction witness (typed O6 shape)"
    (Core_check.check_closed j_witness j_witness_ty);

  check "no bogus inhabitant of Pi(A:U). El A"
    (not (Core_check.check_closed
       (Lam ("A", u0, Var "A"))
       (TyPi ("A", u0, el "A"))));

  (* ── Delta-aware conversion (step 1) ──────────────────────────────────────
     A body whose declared codomain is `El(idcode A)` equals `El A` ONLY after
     unfolding the certified delta `idcode = \z:U0. z`. Without deltas the code
     `idcode A` is stuck (idcode unbound in the empty reducer) and conversion
     FAILS; with the certified delta threaded into the checker's reducer it
     reduces to `A` and the body checks. This is exactly the definitional
     equality gap the delta-threading closes. *)
  let idcode_deltas = [ ("idcode", Lam ("z", u0, Var "z")) ] in
  let cc_delta = Core_check.cctx_of_deltas idcode_deltas in
  let delta_body = Lam ("A", u0, Lam ("x", el "A", Var "x")) in
  let delta_ty =
    TyPi ("A", u0, TyArrow (el "A", TyEl (App (Var "idcode", Var "A"))))
  in
  check "conversion is INCOMPLETE without the delta (idcode stuck)"
    (not (Core_check.check_closed delta_body delta_ty));
  check "delta-aware conversion unfolds a certified definition (El(idcode A) = El A)"
    (Core_check.check_closed ~cc:cc_delta delta_body delta_ty);
  (* SN safety: the same context is a strict extension — the delta-free witnesses
     still check under it (unfolding never blocks a term that needed no unfold). *)
  check "delta context is a conservative extension (poly-id still checks)"
    (Core_check.check_closed ~cc:cc_delta poly_id poly_id_ty);

  (* Numeric-literal seeding (step 2). A literal is encoded as a Var whose name
     starts with __num_ ; it must infer as the primitive number type
     (TyPlace number) rather than raising Unsupported on an unbound __num_ name. *)
  check "a numeric literal infers as the number type"
    (Core_check.infer_closed (Var "__num_42") = Some (TyPlace "number"));
  check "a non-__num_ unbound name is still a coverage gap, not seeded"
    (Core_check.infer_closed (Var "__not_a_num") = None);

  (* ── Term-checking gate (step 3) ──────────────────────────────────────────
     certify_term is the gate primitive core_wf uses to CHECK a body against its
     declared type. It must (b) CERTIFY a well-typed pure-dependent body, and
     (c) REJECT an ill-typed one with `Type_error (a clean structural
     non-inhabitation), NOT silently skip it. *)
  let good_body = Lam ("A", u0, Lam ("x", el "A", Var "x")) in
  let good_ty = TyPi ("A", u0, TyArrow (el "A", el "A")) in
  check "(b) certify_term CERTIFIES a well-typed pure-dependent body"
    (Core_check.certify_term [] good_body good_ty = `Ok);

  let ill_body = Lam ("A", u0, Lam ("B", u0, Lam ("x", el "A", Var "x"))) in
  let ill_ty = TyPi ("A", u0, TyPi ("B", u0, TyArrow (el "A", el "B"))) in
  check "(c) certify_term REJECTS an ill-typed body with Type_error (not Skipped)"
    (match Core_check.certify_term [] ill_body ill_ty with
     | `Type_error _ -> true
     | `Ok | `Skipped _ -> false);

  (* An out-of-fragment body (an unseeded runtime name) must SKIP, never reject:
     the SOUND-over-COMPLETE bias the gate depends on. *)
  check "certify_term SKIPS a body that mentions an unseeded name"
    (match Core_check.certify_term []
             (Lam ("x", TyPlace "number", App (Var "Space__get", Var "x")))
             (TyArrow (TyPlace "number", TyPlace "number")) with
     | `Skipped _ -> true
     | `Ok | `Type_error _ -> false);

  (* A body that is definitionally equal to a literal only after delta-unfolding
     + beta computation is CERTIFIED once normalized: `(\z.z) __num_7 : number`. *)
  check "certify_term certifies a body up to beta/delta normalization"
    (Core_check.certify_term ~cc:cc_delta []
       (App (Lam ("z", TyPlace "number", Var "z"), Var "__num_7"))
       (TyPlace "number") = `Ok);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
