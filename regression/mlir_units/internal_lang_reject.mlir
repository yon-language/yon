// topos-internal-lang REJECT: the classifier of the canonical subplace is a
// genuine !topos.proposition value, but it is produced by `topos.heyt_from_i8`,
// which is NOT a Heyting/proposition-building op in the pass's whitelist ->
// [TOPOS-E0505]. The op-level CanonicalSubplaceOp::verify is satisfied (parent
// place @P exists; classifier type is !topos.proposition — TopOps.cpp:2407), so
// parsing + op-verification pass; only the pass trips.
// Grounded in StructuralPasses.cpp InternalLanguageConsistencyPass (E0505 when
// the classifier's defining op name is none of the whitelisted ops).
// topos.heyt_from_i8 produces a proposition (TopOps.td Topos_HeytFromI8Op,
// assembly `$value attr-dict : type(results)`).
module {
  topos.world @W {
    topos.place @P in @W attributes {with_effects} {
      topos.field @x : f64
    }
  }
  func.func @f() {
    %i = arith.constant 0 : i8
    %c = topos.heyt_from_i8 %i : !topos.proposition
    topos.canonical_subplace @S of @P by %c : !topos.proposition
    return
  }
}
