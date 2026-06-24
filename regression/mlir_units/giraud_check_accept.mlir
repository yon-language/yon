// topos-giraud-check ACCEPT: world @W contains at least one place, satisfying
// Giraud's small-generating-family requirement. Grounded in StructuralPasses.cpp
// GiraudCheckPass (rejects worlds with zero topos.place).
module {
  topos.world @W {
    topos.place @P in @W attributes {with_effects} {
      topos.field @x : f64
    }
  }
}
