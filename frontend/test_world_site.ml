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

  (* ─── filesystem layout: folder = world, file = space (deduce + reconstruct) ─
   * Build a tiny src/ fixture, check the path->（world,space) deduction, and
   * check the reconstructed explicit text PARSES with today's parser. *)
  Random.self_init ();
  let root = Filename.concat (Filename.get_temp_dir_name ())
               (Printf.sprintf "yon_layout_%d" (Random.bits ())) in
  let cdir = Filename.concat root "Commerce" in
  Sys.mkdir root 0o755; Sys.mkdir cdir 0o755;
  let write p s = let oc = open_out p in output_string oc s; close_out oc in
  write (Filename.concat root "main.yon") "fun main(): number { return 0 }\n";
  write (Filename.concat cdir "world.yon") "Code is Order\n";
  write (Filename.concat cdir "Orders.yon") "place Order { id text }\n";

  let units = Package_layout.layout ~root in
  let find sp = List.find_opt (fun u -> u.Package_layout.ul_space = sp) units in
  check "layout: main.yon is a space in the ROOT world"
    (match find "main" with Some u -> u.Package_layout.ul_world = "" | None -> false);
  check "layout: Orders.yon is space Orders in world Commerce"
    (match find "Orders" with Some u -> u.Package_layout.ul_world = "Commerce" | None -> false);
  check "layout: world.yon is flagged as the world header file of Commerce"
    (match find "world" with
     | Some u -> u.Package_layout.ul_is_world && u.Package_layout.ul_world = "Commerce"
     | None -> false);

  let txt = Package_layout.reconstruct ~root in
  let has re_s = try ignore (Str.search_forward (Str.regexp re_s) txt 0); true
                 with Not_found -> false in
  check "reconstruct: emits the world header `world Commerce { Code is Order }`"
    (has "world Commerce { Code is Order }");
  check "reconstruct: emits `space Orders in Commerce`"
    (has "space Orders in Commerce");
  check "reconstruct: the rebuilt explicit text PARSES with today's parser"
    (try ignore (Parser.program Lexer.token (Lexing.from_string txt)); true
     with _ -> false);

  (try
     Sys.remove (Filename.concat root "main.yon");
     Sys.remove (Filename.concat cdir "world.yon");
     Sys.remove (Filename.concat cdir "Orders.yon");
     Sys.rmdir cdir; Sys.rmdir root
   with _ -> ());

  (* ─── sheaf predicate: a field is a sheaf section iff it factors through canon ─
   * canon : W -> Q models the quotient map (the Rel-class of an element). Here
   * canon is symbolic. A field is a valid section of the quotient sheaf iff it
   * reads its argument only through canon -- the salary counterexample, live. *)
  let sctx = Reduce.empty_ctx in
  let cohort u = App (Var "cohort", u) in
  let canon = Lam ("u", TyPlace "User", cohort (Var "u")) in
  let ff = Sheaf.field_factors_through sctx in

  let salary_good = Lam ("u", TyPlace "User", App (Var "scale", cohort (Var "u"))) in
  check "sheaf: salary = f(cohort u) factors through canon -> sheaf"
    (ff ~canon ~field:salary_good);

  let salary_bad = Lam ("u", TyPlace "User", App (Var "base_salary", Var "u")) in
  check "sheaf: salary reading u directly does NOT factor -> rejected"
    (not (ff ~canon ~field:salary_bad));

  let salary_const = Lam ("u", TyPlace "User", Builtins.encode_number 1000.0) in
  check "sheaf: a constant field factors trivially -> sheaf"
    (ff ~canon ~field:salary_const);

  let salary_mixed = Lam ("u", TyPlace "User",
    App (App (Var "combine", cohort (Var "u")), Var "u")) in
  check "sheaf: a field using u both via canon AND directly does NOT factor"
    (not (ff ~canon ~field:salary_mixed));

  let canon_id = Lam ("u", TyPlace "User", Var "u") in
  check "sheaf: identity canon (trivial Rel) accepts every field (Sh = PSh)"
    (ff ~canon:canon_id ~field:salary_bad);

  let canon_total = Lam ("u", TyPlace "User", Builtins.encode_number 0.0) in
  check "sheaf: total Rel (constant canon) rejects a non-constant field"
    (not (ff ~canon:canon_total ~field:salary_good));
  check "sheaf: total Rel accepts a constant field"
    (ff ~canon:canon_total ~field:salary_const);

  (* ─── aggancio: violazioni di fascio di un place su un world-quoziente ─────
   * world Q = W / rel: rel è un campo di W (canon = fun u -> u.rel); ogni campo
   * del place deve fattorizzare -> i campi che non fattorizzano sono violazioni. *)
  check "quotient_violations: salary & age violate, cohort (the rel) does not"
    (List.sort compare
       (Sheaf.quotient_violations sctx ~world:"User" ~rel_field:"cohort"
          ~fields:["cohort"; "salary"; "age"]) = ["age"; "salary"]);
  check "quotient_violations: a place with only the relation field is a sheaf"
    (Sheaf.quotient_violations sctx ~world:"User" ~rel_field:"cohort"
       ~fields:["cohort"] = []);

  let site_q = { w_name = "Anon"; w_objects = ["User"];
                 w_generators = [GenQuotient ("User", "cohort")] } in
  let pl = { p_name = "Profile"; p_site = TyPlace "Anon";
             p_fields = [("cohort", TyPlace "number"); ("salary", TyPlace "number")];
             p_operations = []; p_laws = [] } in
  check "place_violations: a place on User/cohort flags salary as non-invariant"
    (Sheaf.place_violations sctx site_q pl = ["salary"]);
  let site_triv = { w_name = "Plain"; w_objects = []; w_generators = [] } in
  check "place_violations: no quotient generator -> no constraint (empty)"
    (Sheaf.place_violations sctx site_triv pl = []);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
