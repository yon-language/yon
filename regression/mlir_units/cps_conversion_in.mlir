// cps-conversion IN: two CHAINED `topos.apply_move` where the intermediate
// section (%a) has exactly ONE use (the second apply_move). CPSConversion.cpp
// findChain() requires: second.getSource() == first.getResult() AND
// first.getResult().hasOneUse(), with chain length >= 2. The chain is rewritten
// into a `topos.scope_with_yield` whose body holds the (cloned) apply_moves and
// a `topos.scope_yield`, and the enclosing func gains a `topos.cps_converted`
// unit attr (CPSConversion.cpp lines 89-119, 174-175).
//
// Op syntax grounded in TopOps.td: SectionOp (line 369), ApplyMoveOp (line 490,
// `$move $source : functional-type(operands, results)`), and copied from
// move_composition_in.mlir. @m is an identity move @P->@P so MoveOp::verify and
// ApplyMoveOp::verify both pass (place and move resolve in-module).
module {
  topos.world @W {
    topos.place @P in @W attributes {with_effects} {
      topos.field @x : f64
    }
  }
  topos.move @m from @P to @P
  func.func @f() -> !topos.section<"P"> {
    %s = topos.section @P() : () -> !topos.section<"P">
    %a = topos.apply_move @m %s : (!topos.section<"P">) -> !topos.section<"P">
    %b = topos.apply_move @m %a : (!topos.section<"P">) -> !topos.section<"P">
    return %b : !topos.section<"P">
  }
}
