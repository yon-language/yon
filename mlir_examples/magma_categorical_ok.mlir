module {
  topos.world @Alg {
    topos.place @AddPlace in @Alg attributes {with_effects, law_commutative, law_associative, law_monotone} {
      topos.operation @add([f64, f64]) -> f64 attributes {algebra = "Additive"} {
      }
    }
  }
}
