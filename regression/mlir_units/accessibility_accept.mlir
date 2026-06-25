// accessibility ACCEPT-ONLY smoke: a normal world with a single place. The
// AccessibilityPass (StructuralPasses.cpp lines 361-381, W0503) only emits a
// WARNING when a world exceeds the heuristic threshold of 1024 places, and it
// NEVER signals pass failure ("This is a warning-only pass"). We assert exit 0
// only; we do NOT require the warning (that would need a >1024-place world,
// impractical as a fixture). Accept-only.
//
// Op syntax grounded in TopOps.td WorldOp/PlaceOp and copied from
// giraud_check_accept.mlir.
module {
  topos.world @W {
    topos.place @P in @W attributes {with_effects} {
      topos.field @x : f64
    }
  }
}
