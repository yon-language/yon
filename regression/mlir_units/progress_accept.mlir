// topos-progress ACCEPT: there is no topos.apply_move in the module, so the
// ProgressPass walk visits nothing and the pass succeeds. (A topos.move
// declaration alone is not applied, so no progress obligation arises.)
// Grounded in StructuralPasses.cpp ProgressPass (walks ApplyMoveOp only).
module {
  topos.world @W {
    topos.place @P in @W attributes {with_effects} {
      topos.field @x : f64
    }
  }
  topos.move @M from @P to @P
}
