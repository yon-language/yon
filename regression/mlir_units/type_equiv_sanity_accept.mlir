// type-equiv-sanity ACCEPT-ONLY smoke: a well-formed module with two sections
// of the SAME place. Because !topos.section<"P"> is a uniqued MLIR type, the two
// section results carry the IDENTICAL Type pointer, so TypeEquivSanityPass'
// `it->second != t` branch (StructuralPasses.cpp lines 184-193, E0103) can never
// fire from textual MLIR. There is therefore NO reject fixture: this pass is
// exercised as accept-only -> exit 0.
//
// Op syntax grounded in TopOps.td SectionOp (line 369) and copied from
// move_composition_in.mlir / type_preservation_accept.mlir.
module {
  topos.world @W {
    topos.place @P in @W attributes {with_effects} {
      topos.field @x : f64
    }
  }
  func.func @f() -> !topos.section<"P"> {
    %s1 = topos.section @P() : () -> !topos.section<"P">
    %s2 = topos.section @P() : () -> !topos.section<"P">
    return %s1 : !topos.section<"P">
  }
}
