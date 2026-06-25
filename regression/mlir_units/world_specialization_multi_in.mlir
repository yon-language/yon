// world-specialization MULTI: the module has TWO topos.world ops, so the pass
// bails out (worlds.size() != 1) and marks NOTHING. After the pass NO
// `topos.static_world` attribute appears anywhere. Grounded in
// WorldSpecialization.cpp (early return when worlds.size() != 1).
module {
  topos.world @W1 {
    topos.place @P1 in @W1 attributes {with_effects} {
      topos.field @x : f64
    }
  }
  topos.world @W2 {
    topos.place @P2 in @W2 attributes {with_effects} {
      topos.field @y : f64
    }
  }
}
