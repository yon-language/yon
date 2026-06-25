// simpson6 ACCEPT-ONLY smoke: a `topos.from_site` whose topology RESOLVES.
//
// Note on why this is accept-only: FromSiteOp::verify (TopOps.cpp lines
// 2299-2329) already rejects a from_site whose topology is missing/not a
// topos.topology, emitting E0279 (and E0273 for a missing base category) at
// OP-VERIFY time, before Simpson6Pass ever runs. So Simpson6Pass' own E0502
// branch (StructuralPasses.cpp lines 320-336) is structurally unreachable from
// textual MLIR. The useful smoke is the converse: a from_site that DOES verify
// and DOES resolve its topology -> Simpson6Pass walks it, finds the topology via
// SymbolTable::lookupSymbolIn, and accepts -> exit 0.
//
// Op syntax grounded in TopOps.td: WorldOp/PlaceOp, TopologyOp (line 1536,
// `$sym_name `of` $of_place`; of_place must exist per TopologyOp::verify), and
// FromSiteOp (line 1985, `$sym_name `from` $base_category `,` $topology` +
// SizedRegion<1> NoTerminator body, here an empty block).
module {
  // Base category: a world acting as the underlying small category.
  topos.world @C {
    topos.place @P in @C attributes {with_effects} {
      topos.field @x : f64
    }
  }
  // The coverage (Lawvere-Tierney topology) on a declared place.
  topos.topology @J of @P
  // Sheaves over the site (C, J): topology @J resolves, so both
  // FromSiteOp::verify and Simpson6Pass accept.
  // SizedRegion<1>+NoTerminator: the custom `{ }` parses as 0 blocks and trips
  // the op verifier, so use the generic form with an explicit empty block ^bb0.
  "topos.from_site"() ({
  ^bb0:
  }) {base_category = @C, sym_name = "Sh", topology = @J} : () -> ()
}
