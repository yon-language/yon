// topos-localisation-decomp REJECT: an attested geometric morphism declared
// BEFORE its source/target worlds in module order -> [TOPOS-E0504]. The
// op-level GeomMorphismOp::verify only requires the worlds to *exist* anywhere
// in the module (SymbolTable lookup, order-independent — TopOps.cpp:1809), so
// parsing + op-verification pass; only the pass's module-order scan trips.
// Grounded in StructuralPasses.cpp LocalisationDecompPass (E0504 when a
// proper_base_change_attested GeomMorphismOp precedes its worlds in the
// top-level operation order).
module {
  topos.geom_morphism @g from @A to @B attributes {proper_base_change_attested}
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
}
