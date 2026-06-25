// topos-localisation-decomp ACCEPT: an attested geometric morphism whose
// source and target worlds are BOTH defined earlier in module order. The
// localisation-decomposition check (module-order scan) is satisfied, so the
// pass succeeds. Grounded in StructuralPasses.cpp LocalisationDecompPass
// (scans top-level ops in order; for a GeomMorphismOp with
// getProperBaseChangeAttested(), both source_site and target_site must already
// be in the `seen` set).
module {
  topos.world @A {
    topos.place @PA in @A attributes {with_effects} {
      topos.field @x : f64
    }
  }
  topos.world @B {
    topos.place @PB in @B attributes {with_effects} {
      topos.field @y : f64
    }
  }
  topos.geom_morphism @g from @A to @B attributes {proper_base_change_attested}
}
