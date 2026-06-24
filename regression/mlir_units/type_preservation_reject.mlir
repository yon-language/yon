// topos-type-preservation REJECT: the section produced inside reduction @R
// refers to place @Q, but @R operates on place @P -> [TOPOS-E0101].
// Grounded in StructuralPasses.cpp TypePreservationPass.
module {
  topos.world @W {
    topos.place @P in @W attributes {with_effects} {
      topos.field @x : f64
    }
    topos.place @Q in @W attributes {with_effects} {
      topos.field @y : f64
    }
  }
  topos.reduce @R of @P attributes {
    direction = 0 : i32,
    policy = 0 : i32,
    shot_ordering = 0 : i32
  } {
    %s = topos.section @Q() : () -> !topos.section<"Q">
  }
}
