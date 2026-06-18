(* test_world_site.ml — oracle: the world reified as a site C(W), and get_J
 * reading the Grothendieck topology off its CONSTRUCTION. Fixes the LOGIC of
 * the generated topology, not merely that it compiles:
 *   - bare world           -> trivial J (Sh = PSh; every place a sheaf vacuously)
 *   - coproduct/quotient/subset -> exactly one covering generator each
 *   - join                 -> union of generators, order- and
 *                             multiplicity-insensitive (join in the lattice)
 *   - same_topology        -> coarser than world_equal (ignores objects) *)

open Ast

let pass = ref 0
let fail = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fail; Printf.printf "  [FAIL] %s\n" name)

let mk name objs gens = { w_name = name; w_objects = objs; w_generators = gens }

let () =
  Printf.printf "=== world-as-site C(W) / get_J oracle ===\n\n";

  (* 1. bare world: no construction -> trivial topology, Sh = PSh *)
  let base = mk "Ledger" ["Code"] [] in
  check "bare world has trivial J (no generators)" (Site.get_J base = []);
  check "bare world is_trivial (Sh = PSh)" (Site.is_trivial base);

  (* 2. coproduct world: one disjoint-covering generator *)
  let copro = mk "Either" [] [GenCoproduct ["A"; "B"]] in
  check "coproduct: exactly one generator" (List.length (Site.get_J copro) = 1);
  check "coproduct is NOT trivial" (not (Site.is_trivial copro));
  check "coproduct generator is the disjoint cover {A,B}"
    (Site.get_J copro = [GenCoproduct ["A"; "B"]]);

  (* 3. quotient world: the R-classes cover *)
  let quot = mk "Anon" ["User"] [GenQuotient ("User", "SameCohort")] in
  check "quotient: one quotient-covering generator"
    (Site.get_J quot = [GenQuotient ("User", "SameCohort")]);
  check "quotient is NOT trivial" (not (Site.is_trivial quot));

  (* 4. subset world: dense inclusion generates a cover *)
  let sub = mk "EU" [] [GenSubset "Region"] in
  check "subset: one dense-inclusion generator"
    (Site.get_J sub = [GenSubset "Region"]);

  (* 5. join: several constructions -> all generators; topology is order- and
     multiplicity-insensitive (join in the complete lattice of topologies) *)
  let j1 = mk "W" [] [GenCoproduct ["A"; "B"]; GenSubset "V"] in
  let j2 = mk "W" [] [GenSubset "V"; GenCoproduct ["A"; "B"]] in
  check "join carries all generators" (List.length (Site.get_J j1) = 2);
  check "join is order-insensitive as a topology" (Site.same_topology j1 j2);
  let j3 = mk "W" [] [GenCoproduct ["A"; "B"]; GenCoproduct ["A"; "B"]; GenSubset "V"] in
  check "join is idempotent (duplicate generator = same J)"
    (Site.same_topology j1 j3);

  (* 6. same_topology is coarser than world_equal: same J, different objects *)
  let a = mk "W" ["x"] [GenSubset "V"] in
  let b = mk "W" ["y"] [GenSubset "V"] in
  check "same_topology ignores objects (coarser than world_equal)"
    (Site.same_topology a b && not (world_equal a b));

  (* ─── desugar: surface world -> Core site C(W), J read off the construction ─ *)
  let dummy = Surface_ast.dummy_loc in
  let mk_world ?(places=[]) ?(product=[]) ?(coproduct=[]) ?(coeq=None)
               ?(quotient=None) ?(subset=None) name : Surface_ast.world_decl =
    { Surface_ast.wd_name = name; wd_places = places;
      wd_product_of = product; wd_coproduct_of = coproduct;
      wd_coequalizer_of = coeq; wd_quotient_of = quotient;
      wd_subset_of = subset; wd_loc = dummy } in
  let wp name : Surface_ast.world_place =
    { Surface_ast.wp_name = name;
      wp_descriptor = Surface_ast.PdIdList ["X"]; wp_loc = dummy } in
  let dsg = Desugar.desugar_world_decl in

  let d_base = dsg (mk_world ~places:[wp "Code"] "Ledger") in
  check "desugar bare world { Code is X }: trivial J" (Site.get_J d_base = []);
  check "desugar bare world: objects = inhabitants" (d_base.w_objects = ["Code"]);

  let d_copro = dsg (mk_world ~coproduct:["A"; "B"] "Either") in
  check "desugar world = A + B: GenCoproduct [A;B]"
    (Site.get_J d_copro = [GenCoproduct ["A"; "B"]]);

  let d_quot = dsg (mk_world ~quotient:(Some ("User", "SameCohort")) "Anon") in
  check "desugar world = User / SameCohort: GenQuotient (User, SameCohort)"
    (Site.get_J d_quot = [GenQuotient ("User", "SameCohort")]);

  let d_sub = dsg (mk_world ~subset:(Some "Region") "EU") in
  check "desugar world subset of Region: GenSubset Region"
    (Site.get_J d_sub = [GenSubset "Region"]);

  let d_prod = dsg (mk_world ~product:["A"; "B"] "Prod") in
  check "desugar world = A * B: NO generator (product is a limit, not a cover)"
    (Site.get_J d_prod = []);
  check "desugar product: objects = the factors" (d_prod.w_objects = ["A"; "B"]);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
