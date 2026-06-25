(* test_prop_eval.ml — oracle for the Ω proposition EVALUATOR (prop_eval.ml).
 *
 * test_heyting (and the heyting oracle) already pin the *algebra*
 * (h_and/h_or/h_not tables). Here we pin the EVALUATOR that *applies*
 * that algebra to surface expressions under a place's visibility:
 *
 *   eval_expr_at      : eval_ctx -> expr -> Heyting.heyt_value
 *   eval_condition_at : eval_ctx -> condition -> Heyting.heyt_value
 *   resolve_to_heyt   : eval_ctx -> expr -> Heyting.heyt_value
 *
 * Grounded on source (frontend/, read in full before writing):
 *   - heyting.ml:27-30   type heyt_value = HPresent | HAbsent | HUnknown
 *   - heyting.ml:141-142 from_bool true=HPresent, false=HAbsent
 *   - heyting.ml:84-88   h_not: present->absent, absent->present, unknown->unknown
 *   - prop_eval.ml:42-59 eval_ctx + make_ctx (table, current, bindings, reducer)
 *   - prop_eval.ml:250   eval_expr_at; :252 ELit(LitBool b) -> from_bool b
 *   - prop_eval.ml:278-279 comparison ops flow through eval_comparison
 *   - prop_eval.ml:256-263 EVar: invisible name -> HUnknown
 *   - prop_eval.ml:281-282 ECall("__heyt_not",[e]) -> h_not (eval e)
 *   - prop_eval.ml:283-287 conservative default arm -> HUnknown
 *   - place_visibility.ml:137-145 global_visibility (sees everything)
 *   - place_visibility.ml:31-37 empty_for (a place that sees NO names)
 *   - surface_ast.ml:121-134 literal / binop; :24 dummy_loc
 *
 * The simplest callable entry point is eval_expr_at with a hand-built
 * eval_ctx: an empty vis_table, a visibility, no bindings, and an
 * identity reducer. The reducer is only forced inside eval_comparison
 * when BOTH sides are visible (prop_eval.ml:197-198); we keep it total
 * (fun t -> t) so it never raises.
 *)

open Surface_ast

let pass = ref 0
let fails = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fails; Printf.printf "  [FAIL] %s\n" name)

(* ── helpers: build surface exprs ─────────────────────────────────── *)
let lit_bool b = ELit (LitBool b, dummy_loc)
let lit_num n = ELit (LitNumber n, dummy_loc)
let var x = EVar (x, dummy_loc)
let lt a b = EBinop (OpLt, a, b, dummy_loc)
let band a b = EBinop (OpAnd, a, b, dummy_loc)
let bor a b = EBinop (OpOr, a, b, dummy_loc)
let heyt_not e = ECall ("__heyt_not", [e], dummy_loc)

(* identity reducer — total, never raises *)
let id_reducer (t : Ast.term) : Ast.term = t

(* a context whose current place is GLOBAL: sees every name
 * (place_visibility.ml:151-153 sees_name_at returns true when global). *)
let ctx_global =
  Prop_eval.make_ctx
    []                                   (* empty vis_table *)
    Place_visibility.global_visibility   (* global: sees everything *)
    []                                   (* no local bindings *)
    id_reducer

(* a context whose current place is a NON-global place that sees NO
 * names (empty_for). A name that is in global_state but unseen here is
 * NOT visible -> HUnknown. We also give global_state so the visibility
 * check (prop_eval.ml:256-261) takes the "in global_state but not seen"
 * branch rather than the "not in global_state at global" branch. *)
let ctx_blind_with_state state =
  Prop_eval.make_ctx_with_global_state
    []
    (Place_visibility.empty_for "P")     (* a place that sees nothing *)
    []                                   (* no local bindings *)
    state                                (* visibility-checked names *)
    id_reducer

open Heyting

let () =
  Printf.printf "=== prop_eval (Omega proposition evaluator) oracle ===\n\n";

  (* ── 1. KNOWN-ANSWER: literal present / absent ─────────────────── *)
  (* eval_expr_at on ELit(LitBool true) = from_bool true = HPresent
   * (prop_eval.ml:252). *)
  check "eval `true` -> HPresent"
    (Prop_eval.eval_expr_at ctx_global (lit_bool true) = HPresent);
  check "eval `false` -> HAbsent"
    (Prop_eval.eval_expr_at ctx_global (lit_bool false) = HAbsent);

  (* ── 2. KNOWN-ANSWER: comparison on literals (the evaluator path) ─ *)
  (* eval_comparison resolves both literal operands and applies the op,
   * then from_bool (prop_eval.ml:223-233). Both sides are literals, so
   * all_visible is trivially true (no names). *)
  check "eval `1 < 2` -> HPresent"
    (Prop_eval.eval_expr_at ctx_global (lt (lit_num 1.0) (lit_num 2.0)) = HPresent);
  check "eval `2 < 1` -> HAbsent"
    (Prop_eval.eval_expr_at ctx_global (lt (lit_num 2.0) (lit_num 1.0)) = HAbsent);

  (* ── 3. Heyting AND/OR composition through the evaluator ────────── *)
  (* These exercise eval_expr_at's EBinop(OpAnd/OpOr) arms wiring the
   * algebra (prop_eval.ml:274-277), not the algebra in isolation. *)
  check "eval `true and false` -> HAbsent"
    (Prop_eval.eval_expr_at ctx_global (band (lit_bool true) (lit_bool false)) = HAbsent);
  check "eval `false or true` -> HPresent"
    (Prop_eval.eval_expr_at ctx_global (bor (lit_bool false) (lit_bool true)) = HPresent);

  (* ── 4. THE LOAD-BEARING INTUITIONISTIC FACT ───────────────────── *)
  (* A name NOT in V(P) -> HUnknown (NOT HAbsent). x is in global_state
   * but the place "P" sees nothing, so the visibility check fails and
   * eval_expr_at returns HUnknown (prop_eval.ml:256-263). *)
  let state_x = [ ("x", Builtins.encode_bool true) ] in
  check "invisible name `x` (not in V(P)) -> HUnknown (NOT HAbsent)"
    (Prop_eval.eval_expr_at (ctx_blind_with_state state_x) (var "x") = HUnknown);
  (* Sanity: the SAME name IS HPresent at the global place, proving the
   * HUnknown above is caused by visibility, not by a decode failure. *)
  check "same name `x` at global place -> HPresent (visibility, not decode)"
    (Prop_eval.eval_expr_at
       (Prop_eval.make_ctx [] Place_visibility.global_visibility state_x id_reducer)
       (var "x") = HPresent);

  (* ── 5. neg(unknown) = unknown (the intuitionistic point) ───────── *)
  (* __heyt_not over an invisible name: h_not HUnknown = HUnknown
   * (prop_eval.ml:281-282 + heyting.ml:88). Negating "I don't know"
   * does not produce an assertion. *)
  check "not(invisible) -> HUnknown (neg of unknown is unknown)"
    (Prop_eval.eval_expr_at (ctx_blind_with_state state_x) (heyt_not (var "x")) = HUnknown);
  (* and neg flips known values, to show the not-arm is really wired *)
  check "not(true) -> HAbsent"
    (Prop_eval.eval_expr_at ctx_global (heyt_not (lit_bool true)) = HAbsent);

  (* ── 6. AND short-circuit with an invisible operand ────────────── *)
  (* false and unknown: HAbsent absorbs (heyting.ml:53) -> HAbsent.
   * unknown alone stays unknown -> conservative, never a false present. *)
  check "`false and <invisible>` -> HAbsent (absent absorbs)"
    (Prop_eval.eval_expr_at (ctx_blind_with_state state_x)
       (band (lit_bool false) (var "x")) = HAbsent);
  check "`true and <invisible>` -> HUnknown (no false positive)"
    (Prop_eval.eval_expr_at (ctx_blind_with_state state_x)
       (band (lit_bool true) (var "x")) = HUnknown);

  (* ── 7. CONSERVATIVE DEFAULT: non-prop expr -> HUnknown ─────────── *)
  (* A field access is not a proposition-yielding form; the `| _` arm
   * (prop_eval.ml:283-287) must return HUnknown, never HPresent. *)
  check "non-proposition expr (field access) -> HUnknown (conservative default)"
    (Prop_eval.eval_expr_at ctx_global
       (EField (lit_num 1.0, "f", dummy_loc)) = HUnknown);

  (* ── 8. eval_condition_at: CondExpr delegates; CondAnd composes ──── *)
  check "condition CondExpr(true) -> HPresent"
    (Prop_eval.eval_condition_at ctx_global (CondExpr (lit_bool true)) = HPresent);
  check "condition CondAnd(true, false) -> HAbsent"
    (Prop_eval.eval_condition_at ctx_global
       (CondAnd (CondExpr (lit_bool true), CondExpr (lit_bool false))) = HAbsent);
  (* CondIsNot wraps eval_is_pattern in h_not; for an invisible expr the
   * pattern test is HUnknown and h_not HUnknown = HUnknown
   * (prop_eval.ml:298-299, :312). *)
  check "condition `x is not present` with invisible x -> HUnknown"
    (Prop_eval.eval_condition_at (ctx_blind_with_state state_x)
       (CondIsNot (var "x", PatPresent)) = HUnknown);

  (* ── 9. resolve_to_heyt: invisible -> HUnknown; literal -> HPresent *)
  check "resolve_to_heyt on invisible name -> HUnknown"
    (Prop_eval.resolve_to_heyt (ctx_blind_with_state state_x) (var "x") = HUnknown);
  check "resolve_to_heyt on a literal -> HPresent"
    (Prop_eval.resolve_to_heyt ctx_global (lit_num 7.0) = HPresent);

  Printf.printf "\n%d passed, %d failed\n" !pass !fails;
  if !fails = 0 then exit 0 else exit 1
