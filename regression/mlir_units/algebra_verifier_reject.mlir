// algebra-verifier REJECT: 'Bogus' is not in the certified catalog.
// AlgebraVerifier.cpp emits a plain error:
//   algebra 'Bogus' is not in the certified catalog
// (no [TOPOS-Exxxx] code for this pass).
module {
  topos.world @Alg {
    topos.place @BadPlace in @Alg attributes {with_effects} {
      topos.operation @op([f64, f64]) -> f64 attributes {algebra = "Bogus"} {
      }
    }
  }
}
