// topos-internal-lang ACCEPT: the classifier of the canonical subplace is
// produced by a Heyting op (`topos.heyt`), which is in the pass's whitelist of
// proposition-building ops, so the internal-language consistency check passes.
// Grounded in StructuralPasses.cpp InternalLanguageConsistencyPass (accepts a
// classifier whose defining op name is topos.heyt / heyt_and / heyt_or /
// heyt_not / heyt_implies / forces / path / dep_proposition / or_intro /
// exists_intro). canonical_subplace assembly + verifier: TopOps.td:2050,
// TopOps.cpp:2407 (parent place must exist; classifier must be a proposition).
module {
  topos.world @W {
    topos.place @P in @W attributes {with_effects} {
      topos.field @x : f64
    }
  }
  func.func @f() {
    %c = topos.heyt true : !topos.proposition
    topos.canonical_subplace @S of @P by %c : !topos.proposition
    return
  }
}
