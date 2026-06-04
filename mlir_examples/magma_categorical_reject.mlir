module {
  topos.world @Alg {
    topos.place @MinPlace in @Alg attributes {with_effects, law_monotone} {
      topos.operation @min([f64, f64]) -> f64 attributes {algebra = "TropicalMin"} {
      }
    }
  }
}
