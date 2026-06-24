// algebra-verifier ACCEPT: 'Additive' is in the certified catalog and IS
// monotone, so a place declaring law_monotone passes. Grounded in
// AlgebraVerifier.cpp kCatalog (Additive -> commutative,associative,monotone)
// and mlir_examples/magma_categorical_ok.mlir.
module {
  topos.world @Alg {
    topos.place @AddPlace in @Alg attributes {with_effects, law_commutative, law_associative, law_monotone} {
      topos.operation @add([f64, f64]) -> f64 attributes {algebra = "Additive"} {
      }
    }
  }
}
