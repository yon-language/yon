// lower-topos-extensions IN: `topos.canonical_subplace` is a compile-time-only
// (verifier-layer) declaration with no runtime semantics; the F5a "erase"
// family removes it. After the pass NO `topos.canonical_subplace` op remains.
// Grounded in LowerToposExtensions.cpp: CanonicalSubplaceOp is in
// target.addIllegalOp<...> and matched by EraseOp<CanonicalSubplaceOp>
// (rewriter.eraseOp) under applyPartialConversion. The classifier (a
// topos.heyt proposition) is an unlisted op left untouched by the partial
// conversion. op-verify is satisfied (parent place @P exists; classifier is a
// proposition — TopOps.cpp:2407).
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
