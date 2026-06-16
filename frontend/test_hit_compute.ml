(* test_hit_compute.ml — HIT computation end-to-end in the core.
 *
 * With Ast.HITConstr a first-class core term and the bridge wired both ways,
 * the HIT eliminator's beta now computes from Ast through the cubical engine
 * and back:
 *   hit_elim([base => vb, loop => vl], base)  ~>  vb
 *   hit_elim([base => vb, loop => vl], loop)  ~>  vl
 * This is the gap the roadmap's point 3 left open (of_cterm could not lower a
 * HIT constructor); it is now closed.
 *)

open Ast

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let () =
  Printf.printf "=== HIT computation oracle (eliminator beta on a constructor) ===\n\n";
  let ctx = Reduce.empty_ctx in

  (* point constructor: hit_elim(.., base) reduces to the base branch *)
  let elim_base =
    HITElim ([("base", Var "vb"); ("loop", Var "vl")], HITConstr ("base", [])) in
  let r_base = Builtins.reduce_with_builtins ctx elim_base in
  check "hit_elim([base=>vb, loop=>vl], base) = vb" (r_base = Var "vb");

  (* path constructor: hit_elim(.., loop) reduces to the loop branch *)
  let elim_loop =
    HITElim ([("base", Var "vb"); ("loop", Var "vl")], HITConstr ("loop", [])) in
  let r_loop = Builtins.reduce_with_builtins ctx elim_loop in
  check "hit_elim([base=>vb, loop=>vl], loop) = vl" (r_loop = Var "vl");

  (* bridge round-trip: of_cterm (to_cterm (HITConstr ..)) = HITConstr .. *)
  let c = HITConstr ("merid", [Var "a"]) in
  let rt = Builtins.of_cterm (Builtins.to_cterm c) in
  check "bridge round-trip on HITConstr(merid, [a])" (rt = c);

  (* a HIT constructor is inert (a value): it does not reduce on its own *)
  let base_val = Builtins.reduce_with_builtins ctx (HITConstr ("base", [])) in
  check "HITConstr base is a value (no reduction)" (base_val = HITConstr ("base", []));

  (* S1 ~= S1: transporting a HIT point through ua lands back in the core.
   * The transp-Glue rule (univalence-as-computation) yields __equiv_fwd(e, base);
   * of_cterm now lowers the base point — the gap that previously blocked the
   * S1~S1 transport from reducing end-to-end. (Marker caveat from test_glue
   * applies: forward map modelled as a marker. isEquiv is gated structurally
   * in the surface typing now, so this path is reachable only via a real Equiv.) *)
  let ua_on_base =
    Cubical.CHITConstr ("__equiv_fwd",
                        [Cubical.CInhabitant (Cubical.CVar "e");
                         Cubical.CHITConstr ("base", [])]) in
  let lowered = Builtins.of_cterm ua_on_base in
  check "ua transport of base lowers to App(Fst e, base) (S1~S1 gap closed)"
    (match lowered with App (Fst _, HITConstr ("base", [])) -> true | _ -> false);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
