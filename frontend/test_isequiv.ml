(* test_isequiv.ml — soundness gate: ua/Glue require a genuine equivalence.
 *
 * The hole this closes: previously `ua` accepted any argument (it ignored the
 * type), so a bare function could be presented as an equivalence and used to
 * assert A ~= B for non-equivalent A, B — a path to inconsistency. Now:
 *   - ua requires its argument to be an Equiv;
 *   - an Equiv can only be built with equiv(f, g, eta, eps): forward map,
 *     inverse, and the two homotopies (structure, not a bare function).
 * The checker verifies the SHAPES; full coherence of eta/eps is dependent
 * checking, the next grade — but the bare-function hole is closed.
 *)

open Surface_ast

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let () =
  Printf.printf "=== isEquiv soundness gate oracle ===\n\n";
  let fn = TyArrow (TyPrim "number", TyPrim "number") in
  let pth = TyUser "Path" in

  (* ua requires an Equiv *)
  let r_ua_ok = Cubical_bindings.infer_ua [TyUser "Equiv"] in
  check "ua(Equiv) accepted" (r_ua_ok.Cubical_bindings.errors = []);

  let r_ua_fn = Cubical_bindings.infer_ua [fn] in
  check "ua(bare function) REJECTED" (r_ua_fn.Cubical_bindings.errors <> []);

  let r_ua_num = Cubical_bindings.infer_ua [TyPrim "number"] in
  check "ua(number) REJECTED" (r_ua_num.Cubical_bindings.errors <> []);

  (* equiv requires the full structure (f, g, eta, eps) with right shapes *)
  let r_eq_ok = Cubical_bindings.infer_equiv [fn; fn; pth; pth] in
  check "equiv(f, g, eta, eps) accepted" (r_eq_ok.Cubical_bindings.errors = []);

  let r_eq_nofwd = Cubical_bindings.infer_equiv [TyPrim "number"; fn; pth; pth] in
  check "equiv with non-function forward map REJECTED"
    (r_eq_nofwd.Cubical_bindings.errors <> []);

  let r_eq_noinv = Cubical_bindings.infer_equiv [fn; TyPrim "number"; pth; pth] in
  check "equiv with non-function inverse REJECTED"
    (r_eq_noinv.Cubical_bindings.errors <> []);

  let r_eq_nohtpy = Cubical_bindings.infer_equiv [fn; fn; TyPrim "number"; pth] in
  check "equiv with non-path homotopy REJECTED"
    (r_eq_nohtpy.Cubical_bindings.errors <> []);

  let r_eq_arity = Cubical_bindings.infer_equiv [fn; fn] in
  check "equiv with wrong arity REJECTED" (r_eq_arity.Cubical_bindings.errors <> []);

  (* ── FULL COHERENCE: eta/eps must connect the right endpoints ────────
   * Verified through Tycheck.infer on equiv(f, g, eta, eps): the checker
   * builds the expected dependent types
   *   eta : forall a. Id(A, g(f a), a)     eps : forall b. Id(B, f(g b), b)
   * from the actual terms f, g and checks the supplied homotopies against
   * them. A homotopy with the WRONG endpoints is rejected. *)
  let dl = dummy_loc in
  let ctx = Reduce.empty_ctx in
  let num = TyPrim "number" in
  let fnt = TyArrow (num, num) in
  let gfa = EApp (EVar ("g", dl), [EApp (EVar ("f", dl), [EVar ("__eq_a", dl)], dl)], dl) in
  let eta_good = TyPi ("__eq_a", num, TyId (num, TyTermExpr gfa, TyTermExpr (EVar ("__eq_a", dl)))) in
  let fgb = EApp (EVar ("f", dl), [EApp (EVar ("g", dl), [EVar ("__eq_b", dl)], dl)], dl) in
  let eps_good = TyPi ("__eq_b", num, TyId (num, TyTermExpr fgb, TyTermExpr (EVar ("__eq_b", dl)))) in
  let call = ECall ("equiv", [EVar ("f", dl); EVar ("g", dl); EVar ("eta", dl); EVar ("eps", dl)], dl) in

  let env_good = Tyenv.add_vars Tyenv.empty
      [("f", fnt); ("g", fnt); ("eta", eta_good); ("eps", eps_good)] in
  (match Tycheck.infer env_good ctx call with
   | Ok (TyUser "Equiv") -> check "equiv with CORRECT coherences accepted" true
   | Ok other -> check (Printf.sprintf "coherence: unexpected %s" (Tyenv.ty_to_string other)) false
   | Error e -> check (Printf.sprintf "coherence: good rejected: %s" (Tycheck.error_to_string e)) false);

  (* eta with WRONG endpoints: Id(num, a, a) instead of Id(num, g(f a), a) *)
  let eta_bad = TyPi ("__eq_a", num, TyId (num, TyTermExpr (EVar ("__eq_a", dl)), TyTermExpr (EVar ("__eq_a", dl)))) in
  let env_bad = Tyenv.add_vars Tyenv.empty
      [("f", fnt); ("g", fnt); ("eta", eta_bad); ("eps", eps_good)] in
  (match Tycheck.infer env_bad ctx call with
   | Error _ -> check "equiv with WRONG eta coherence REJECTED" true
   | Ok _ -> check "LEAK: wrong eta coherence accepted" false);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
