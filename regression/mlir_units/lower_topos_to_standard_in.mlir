// lower-topos-to-standard IN: a Heyting AND over standard proposition values.
// This pass is a real lowering: !topos.proposition -> i8, and topos.heyt /
// topos.heyt_and are replaced by arith ops (arith.constant / arith.cmpi /
// arith.select). After the pass NO `topos.heyt` op remains and `arith.` ops
// appear. Grounded in LowerToposToStandard.cpp LowerHeytConstOp / LowerHeytAndOp.
module {
  func.func @f() -> !topos.proposition {
    %a = topos.heyt true : !topos.proposition
    %b = topos.heyt unknown : !topos.proposition
    %r = topos.heyt_and %a, %b : !topos.proposition
    return %r : !topos.proposition
  }
}
