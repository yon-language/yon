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

  (* ─── filesystem layout: folder = space, file = place; world from the toml ─
   * Build a tiny fixture (a Space directory holding a place file, plus a
   * Main file under the root), check the path->space deduction, and check the
   * reconstructed explicit text PARSES. The world is materialised from the
   * manifest; the space is declared bare (membership lives in the toml). *)
  Random.self_init ();
  let root = Filename.concat (Filename.get_temp_dir_name ())
               (Printf.sprintf "yon_layout_%d" (Random.bits ())) in
  let odir = Filename.concat root "Orders" in
  Sys.mkdir root 0o755; Sys.mkdir odir 0o755;
  let write p s = let oc = open_out p in output_string oc s; close_out oc in
  write (Filename.concat root "Main.yon") "fun main(): number { return 0 }\n";
  write (Filename.concat odir "Order.yon") "place Order { id text }\n";

  let units = Package_layout.layout ~root in
  let find_path base =
    List.find_opt (fun u ->
      Filename.basename u.Package_layout.ul_path = base) units in
  check "layout: Order.yon is a place in space Orders (directory = space)"
    (match find_path "Order.yon" with
     | Some u -> u.Package_layout.ul_space = "Orders" | None -> false);
  check "layout: Main.yon is under the root, in no space"
    (match find_path "Main.yon" with
     | Some u -> u.Package_layout.ul_space = "" | None -> false);

  let wm_fix = Manifest.parse_string
    "[world.Commerce]\nspaces = [\"Orders\"]\nobjects = [\"Order\"]\n" in
  let txt = Package_layout.reconstruct ~root ~wm:wm_fix in
  let has re_s = try ignore (Str.search_forward (Str.regexp re_s) txt 0); true
                 with Not_found -> false in
  check "reconstruct: materialises the world from the toml (`world Commerce`)"
    (has "world Commerce { Code is Order }");
  check "reconstruct: declares the space bare (`space Orders`)"
    (has "space Orders");
  check "reconstruct: does NOT re-emit membership (`space Orders in ...`)"
    (not (has "space Orders in"));
  check "reconstruct: keeps the place body (`place Order`)"
    (has "place Order");
  check "reconstruct: the rebuilt explicit text PARSES with today's parser"
    (try ignore (Parser.program Lexer.token (Lexing.from_string txt)); true
     with _ -> false);

  (try
     Sys.remove (Filename.concat root "Main.yon");
     Sys.remove (Filename.concat odir "Order.yon");
     Sys.rmdir odir; Sys.rmdir root
   with _ -> ());

  (* ─── project mode: yon.toml marks the root; the tree compiles via the
   * reconstruct path (dir = space, file = place, world from the toml). This is
   * the binding that connects package_layout to the real driver pipeline. *)
  let proot = Filename.concat (Filename.get_temp_dir_name ())
                (Printf.sprintf "yon_proj_%d" (Random.bits ())) in
  let pcom = Filename.concat proot "Orders" in
  Sys.mkdir proot 0o755; Sys.mkdir pcom 0o755;
  let writep p s = let oc = open_out p in output_string oc s; close_out oc in
  writep (Filename.concat proot "yon.toml")
    "[package]\nname = \"shop\"\n\n[world.Commerce]\nspaces = [\"Orders\"]\nobjects = [\"Order\"]\n";
  writep (Filename.concat proot "Main.yon") "fun main(): number { return 0 }\n";
  writep (Filename.concat pcom "Order.yon") "place Order { id text }\n";
  check "project: yon.toml marks the directory as a project root"
    (Package_layout.is_project ~dir:proot);
  let pwm = Manifest.parse_file (Filename.concat proot "yon.toml") in
  let psrc_txt = Package_layout.project_source ~root:proot ~wm:pwm in
  let phas re_s = try ignore (Str.search_forward (Str.regexp re_s) psrc_txt 0); true
                  with Not_found -> false in
  check "project: reconstructs the world from the toml (`world Commerce`)"
    (phas "world Commerce");
  check "project: reconstructs the space bare (`space Orders`)"
    (phas "space Orders" && not (phas "space Orders in"));
  check "project: the reconstructed project source PARSES with today's parser"
    (try ignore (Parser.program Lexer.token (Lexing.from_string psrc_txt)); true
     with _ -> false);
  (try
     Sys.remove (Filename.concat proot "yon.toml");
     Sys.remove (Filename.concat proot "Main.yon");
     Sys.remove (Filename.concat pcom "Order.yon");
     Sys.rmdir pcom; Sys.rmdir proot
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

  (* coproduct/subset are vacuous on a place's fields (no field-level reject):
     a disjoint cover glues freely; a dense subset is unique extension. Only the
     quotient constrains fields. These confirm the closure is intentional. *)
  let site_copro = { w_name = "Either"; w_objects = ["A"; "B"];
                     w_generators = [GenCoproduct ["A"; "B"]] } in
  check "place_violations: coproduct world imposes nothing on fields (vacuous)"
    (Sheaf.place_violations sctx site_copro pl = []);
  let site_sub = { w_name = "EU"; w_objects = ["Region"];
                   w_generators = [GenSubset "Region"] } in
  check "place_violations: subset world imposes nothing on fields (vacuous)"
    (Sheaf.place_violations sctx site_sub pl = []);

  (* ── manifest [world] parsing + wire-boundary checks ─────────────────
     A world is a module declared in yon.toml listing the spaces that may
     wire to each other. The four error cases the compiler must catch:
     A) a space in two worlds, B) a wire to a space in no world,
     C) a wire crossing a world boundary, D) a space in no world. *)
  Printf.printf "\n=== manifest [world] / wire boundary ===\n\n";

  let toml_ok =
    "[package]\nname = \"shop\"\n\n\
     [world.Commerce]\nspaces = [\"Orders\", \"Billing\"]\n\n\
     [world.Analytics]\nspaces = [\"Reports\"]\n" in
  let wm = Manifest.parse_string toml_ok in
  check "manifest: Orders -> Commerce"
    (Manifest.world_of_space wm "Orders" = Some "Commerce");
  check "manifest: Billing -> Commerce"
    (Manifest.world_of_space wm "Billing" = Some "Commerce");
  check "manifest: Reports -> Analytics"
    (Manifest.world_of_space wm "Reports" = Some "Analytics");
  check "manifest: an unlisted space maps to no world"
    (Manifest.world_of_space wm "Ghost" = None);
  check "manifest: [package]/[world] split is honoured (not is_empty)"
    (not (Manifest.is_empty wm));

  (* Case A: a space claimed by two worlds is rejected at parse time. *)
  let toml_dup =
    "[world.Commerce]\nspaces = [\"Orders\"]\n\
     [world.Analytics]\nspaces = [\"Orders\"]\n" in
  let raised_a =
    try let _ = Manifest.parse_string toml_dup in false
    with Manifest.Manifest_error _ -> true in
  check "manifest A: a space in two worlds is rejected at parse" raised_a;

  let imp m n sp = Surface_ast.TopImportFrom (m, n, sp, Surface_ast.dummy_loc) in
  let init s = Surface_ast.TopSpaceInit (s, Surface_ast.dummy_loc) in

  (* Happy path: sender Orders (Commerce) wires to Billing (Commerce). *)
  let prog_ok = [ init "Orders"; imp "Billing" "stream" "Billing" ] in
  check "boundary: intra-world wire is accepted (no error)"
    (Manifest.check_program wm prog_ok = []);

  (* Case C: sender Orders (Commerce) wires to Reports (Analytics). *)
  let prog_c = [ init "Orders"; imp "Reports" "stream" "Reports" ] in
  check "boundary C: cross-world wire is rejected"
    (List.length (Manifest.check_program wm prog_c) = 1);

  (* Case B: a wire to a space no world declares. *)
  let prog_b = [ init "Orders"; imp "Ghost" "stream" "Ghost" ] in
  check "boundary B: wire to a space in no world is rejected"
    (List.length (Manifest.check_program wm prog_b) = 1);

  (* Case D: the package initialises a space that belongs to no world. *)
  let prog_d = [ init "Lonely" ] in
  check "boundary D: an initialised space in no world is rejected"
    (List.length (Manifest.check_program wm prog_d) = 1);

  (* Opt-in: with no [world] declared at all, nothing is constrained. *)
  let wm_empty = Manifest.parse_string "[package]\nname = \"x\"\n" in
  check "boundary: no [world] declared -> checks are vacuous"
    (Manifest.check_program wm_empty prog_c = []);

  (* world structure -> explicit surface form: must equal the expected text
     AND parse with today's grammar. *)
  let parses s =
    try ignore (Parser.program Lexer.token (Lexing.from_string s)); true
    with _ -> false in
  let ws_of toml w =
    let m = Manifest.parse_string toml in
    match Hashtbl.find_opt m.Manifest.wstructs w with
    | Some s -> s | None -> Manifest.empty_struct in

  let cop = Manifest.world_decl_text "Either"
              (ws_of "[world.Either]\ncoproduct = [\"A\", \"B\"]\n" "Either") in
  check "synth coproduct = world Either = A + B" (cop = "world Either = A + B");
  check "synth coproduct parses" (parses cop);

  let prod = Manifest.world_decl_text "Pair"
               (ws_of "[world.Pair]\nproduct = [\"A\", \"B\"]\n" "Pair") in
  check "synth product = world Pair = A * B" (prod = "world Pair = A * B");
  check "synth product parses" (parses prod);

  let quo = Manifest.world_decl_text "Cohort"
              (ws_of "[world.Cohort]\nquotient = [\"User\", \"SameCohort\"]\n" "Cohort") in
  check "synth quotient = world Cohort = User / SameCohort"
    (quo = "world Cohort = User / SameCohort");
  check "synth quotient parses" (parses quo);

  let sub = Manifest.world_decl_text "EU"
              (ws_of "[world.EU]\nsubset_of = \"Region\"\n" "EU") in
  check "synth subset = world EU subset of Region"
    (sub = "world EU subset of Region");
  check "synth subset parses" (parses sub);

  let obj = Manifest.world_decl_text "Commerce"
              (ws_of "[world.Commerce]\nobjects = [\"Order\", \"Invoice\"]\n" "Commerce") in
  check "synth objects = world Commerce { Code is Order Code is Invoice }"
    (obj = "world Commerce { Code is Order Code is Invoice }");
  check "synth objects parses" (parses obj);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
