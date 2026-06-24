// topos-type-preservation ACCEPT: the section produced inside the reduction
// body refers to the SAME place (@P) the reduction operates on. Grounded in
// StructuralPasses.cpp TypePreservationPass (compares SectionOp.place against
// ReduceOp.of_place) and emit_mlir.ml topos.reduce attribute form.
module {
  topos.world @W {
    topos.place @P in @W attributes {with_effects} {
      topos.field @x : f64
    }
  }
  topos.reduce @R of @P attributes {
    direction = 0 : i32,
    policy = 0 : i32,
    shot_ordering = 0 : i32
  } {
    %s = topos.section @P() : () -> !topos.section<"P">
  }
}
