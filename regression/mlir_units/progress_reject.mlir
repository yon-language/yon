// topos-progress REJECT: topos.apply_move @M applies a declared move whose
// declaration carries no body region (MoveOp is a pure declaration), so
// applying it produces no computation step -> [TOPOS-E0102].
// Grounded in StructuralPasses.cpp ProgressPass: it resolves the MoveOp by
// name and, finding no non-empty body region, emits E0102.
module {
  topos.world @W {
    topos.place @P in @W attributes {with_effects} {
      topos.field @x : f64
    }
  }
  topos.move @M from @P to @P
  func.func @f() -> !topos.section<"P"> {
    %s = topos.section @P() : () -> !topos.section<"P">
    %r = topos.apply_move @M %s : (!topos.section<"P">) -> !topos.section<"P">
    return %r : !topos.section<"P">
  }
}
